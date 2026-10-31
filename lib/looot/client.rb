# frozen_string_literal: true

require "json"
require "securerandom"
require "uri"

module Looot
  # Client for the looot REST API.
  #
  #   looot = Looot::Client.new                 # token from LOOOT_TOKEN
  #   looot.balance.available                   # => 94.63
  #   run = looot.run_job("people.email.find", { firstName: "Jane", lastName: "Doe", domain: "example.com" },
  #                       fallback: true, wait: 20)
  #   run.status                                # => "completed"
  #
  # Every method returns a Looot::Model. Non-2xx answers raise Looot::LoootError.
  # A failed run is returned, never raised: read run.status, run.outcome and run.error.
  class Client
    # Routes that are free and public. They never carry the Authorization header.
    PUBLIC_PATHS = [%r{\A/v1/catalog/overview\z}, %r{\A/v1/public-catalog\z}, %r{\A/v1/public-catalog/[^/]+\z}].freeze
    MAX_RETRY_WAIT = 30
    AGENT_MAX_LENGTH = 64

    attr_reader :base_url, :timeout, :max_retries, :agent

    # token:       bearer token. Defaults to LOOOT_TOKEN, then LOOOT_API_KEY. "" means no token.
    # api_key:     alias for token.
    # base_url:    defaults to https://api.looot.ai.
    # timeout:     seconds per request, default 75.
    # max_retries: automatic retries for 429, retryable 503 codes and network errors, default 2. 0 turns them off.
    # agent:       your app or agent name, sent as X-Looot-Agent (64 characters at most).
    # transport:   object with call(method:, url:, headers:, body:, timeout:) returning a Looot::Response.
    # sleeper:     callable that waits a number of seconds, for tests.
    def initialize(token: nil, api_key: nil, base_url: DEFAULT_BASE_URL, timeout: DEFAULT_TIMEOUT,
                   max_retries: DEFAULT_MAX_RETRIES, agent: nil, transport: nil, sleeper: nil)
      given = token.nil? ? api_key : token
      @token = given.nil? ? env_token : given.to_s.strip
      @base_url = base_url.to_s.sub(%r{/+\z}, "")
      @timeout = timeout
      @max_retries = Integer(max_retries)
      @agent = agent && agent.to_s[0, AGENT_MAX_LENGTH]
      @transport = transport || NetHttpTransport.new
      @sleeper = sleeper || ->(seconds) { sleep(seconds) }
    end

    # True when a token is set. The token itself is never exposed.
    def token?
      !@token.nil? && !@token.empty?
    end

    def inspect
      "#<#{self.class.name} base_url=#{base_url.inspect} token=#{token? ? '[set]' : '[none]'} timeout=#{timeout}>"
    end
    alias to_s inspect

    # ---- free, no token ----

    # GET /v1/catalog/overview. Categories, platforms and jobs with counts and cheapest prices.
    # depth: "summary", "platforms", "jobs" or "full". topic returns matching jobs (25 at most).
    def catalog_overview(depth: nil, category: nil, platform: nil, topic: nil)
      CatalogOverview.new(get("/v1/catalog/overview", depth: depth, category: category, platform: platform, topic: topic))
    end

    # GET /v1/public-catalog. capability is the job id with underscores: "people_email_verify".
    def public_catalog(q: nil, text: nil, capability: nil, category: nil, provider: nil, operation_id: nil,
                       limit: nil, cursor: nil)
      PublicCatalogPage.new(get("/v1/public-catalog", q: q, text: text, capability: capability, category: category,
                                                      provider: provider, operationId: operation_id, limit: limit,
                                                      cursor: cursor))
    end

    # GET /v1/public-catalog/{catalogItemId}.
    def public_catalog_item(catalog_item_id)
      CatalogItem.new(get("/v1/public-catalog/#{segment(catalog_item_id)}"))
    end

    # POST /v1/public-catalog/compare with 2 to 20 catalog item ids.
    def compare_public_catalog(catalog_item_ids)
      CatalogComparison.new(post("/v1/public-catalog/compare", { catalogItemIds: Array(catalog_item_ids) }))
    end

    # ---- free, token ----

    # GET /v1/catalog/search. capability is the job id with dots: "people.email.find".
    # prefer: "cheapest", "reliable", "fastest" or "balanced".
    def search(q = nil, limit: nil, offset: nil, category: nil, platform: nil, provider: nil, capability: nil,
               keyless: nil, verified: nil, mock: nil, max_price_micros: nil, prefer: nil)
      SearchResult.new(get("/v1/catalog/search", q: q, limit: limit, offset: offset, category: category,
                                                 platform: platform, provider: provider, capability: capability,
                                                 keyless: keyless, verified: verified, mock: mock,
                                                 maxPriceMicros: max_price_micros, prefer: prefer))
    end

    # GET /v1/operations/{endpointId}. Input schema, price formula and the most a run can cost.
    # Takes an endpoint id, not job:<id>. Named inspect_endpoint because Ruby's inspect is taken.
    def inspect_endpoint(endpoint_id)
      Operation.new(get("/v1/operations/#{segment(endpoint_id)}"))
    end
    alias operation inspect_endpoint

    # GET /v1/discover. Up to 5 candidates for a plain-words task.
    def discover(query = nil, **params)
      DiscoverResult.new(get("/v1/discover", query: query, **camel_keys(params)))
    end

    # GET /v1/catalog/endpoints. Cursor-paged listing; facets: true adds counts.
    def catalog_endpoints(limit: nil, cursor: nil, category: nil, platform: nil, provider: nil, capability: nil,
                          keyless: nil, verified: nil, max_price_micros: nil, facets: nil)
      CatalogEndpointsPage.new(get("/v1/catalog/endpoints", limit: limit, cursor: cursor, category: category,
                                                            platform: platform, provider: provider,
                                                            capability: capability, keyless: keyless,
                                                            verified: verified, maxPriceMicros: max_price_micros,
                                                            facets: facets))
    end

    # ---- paid ----

    # POST /v1/runs. Paid. Holds the estimate, runs, settles.
    #
    # A returned run is not success: check run.status and run.error.
    # idempotency_key is generated as sdk-<uuid> when omitted. Build your own from your record
    # ("lead-4821-email") so a crashed worker replays instead of paying twice.
    # wait is seconds (0 to 60) or true for 20; without it the run comes back queued.
    # fallback is true or a hash: enabled, maxAttempts, maxCostUsd, prefer, exclude, stopAtFirstMiss.
    def run(endpoint_id, input = {}, idempotency_key: nil, wait: nil, fallback: nil, output: nil)
      body = { endpointId: endpoint_id, input: input, idempotencyKey: idempotency_key || self.class.new_idempotency_key }
      body[:fallback] = fallback.is_a?(Hash) ? camel_keys(fallback) : fallback unless fallback.nil?
      body[:output] = output unless output.nil?
      Run.new(request("POST", "/v1/runs", query: { wait: wait }, body: body))
    end

    # POST /v1/runs with endpointId "job:<job>". Paid. looot picks the provider.
    #
    # prefer goes into fallback.prefer, which turns fallback on. Without prefer and fallback,
    # a job run does not fall back. Never invent a job id: take it from catalog_overview or a
    # search row's capability.
    def run_job(job, input = {}, prefer: nil, fallback: nil, wait: nil, idempotency_key: nil, output: nil)
      fb = fallback
      unless prefer.nil?
        fb = fallback.is_a?(Hash) ? camel_keys(fallback).merge(prefer: prefer) : { prefer: prefer }
      end
      run("job:#{job}", input, idempotency_key: idempotency_key, wait: wait, fallback: fb, output: output)
    end

    # ---- runs ----

    # GET /v1/runs/{runId}. fields keeps dotted paths of result; max_items caps every list.
    def get_run(run_id, fields: nil, max_items: nil)
      fields = fields.join(",") if fields.is_a?(Array)
      Run.new(get("/v1/runs/#{segment(run_id)}", fields: fields, max_items: max_items))
    end

    # GET /v1/runs. Newest first. include_result returns full run records.
    def list_runs(status: nil, capability: nil, limit: nil, cursor: nil, include_result: nil)
      RunList.new(get("/v1/runs", status: status, capability: capability, limit: limit, cursor: cursor,
                                  includeResult: include_result))
    end

    # POST /v1/runs/{runId}/cancel. Returns the run as it stands; a settled run comes back unchanged.
    def cancel_run(run_id)
      Run.new(request("POST", "/v1/runs/#{segment(run_id)}/cancel"))
    end

    # GET /v1/runs/{runId}/attempts. Every attempt with status, latency, receipt and cost.
    def run_attempts(run_id)
      AttemptList.new(get("/v1/runs/#{segment(run_id)}/attempts"))
    end

    # Polls get_run until the status is terminal. Starts at interval seconds and backs off to
    # max_interval. Raises LoootError code "timeout" past timeout seconds.
    def wait_for_run(run_id, timeout: 120, interval: 1, max_interval: 5, clock: nil)
      clock ||= -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      deadline = clock.call + timeout
      delay = interval
      loop do
        current = get_run(run_id)
        return current if current.terminal?

        if clock.call + delay > deadline
          raise LoootError.new("run #{run_id} is still #{current.status} after #{timeout}s",
                               status: 0, code: "timeout", retryable: true)
        end
        @sleeper.call(delay)
        delay = [delay * 2, max_interval].min
      end
    end

    # ---- money and account ----

    # GET /v1/balance. Reading the balance never opens a payment session.
    def balance
      Balance.new(get("/v1/balance"))
    end

    # GET /v1/top-ups.
    def list_top_ups
      TopUpList.new(get("/v1/top-ups"))
    end

    # GET /v1/ledger.
    def ledger(limit: nil, cursor: nil)
      Ledger.new(get("/v1/ledger", limit: limit, cursor: cursor))
    end

    # GET /v1/whoami.
    def whoami
      Whoami.new(get("/v1/whoami"))
    end

    # POST /v1/capability-requests. Ask looot for a missing provider or job.
    def capability_request(title:, description:, desired_inputs: [], desired_outputs: [], idempotency_key: nil)
      CapabilityRequest.new(post("/v1/capability-requests", {
                                   title: title, description: description, desiredInputs: desired_inputs,
                                   desiredOutputs: desired_outputs,
                                   idempotencyKey: idempotency_key || self.class.new_idempotency_key
                                 }))
    end

    # Downloads a run's file. Pass the run or its result.media.downloadPath. Returns the bytes.
    def download_media(run_or_path)
      path = run_or_path.is_a?(Run) ? run_or_path.download_path : run_or_path.to_s
      raise ArgumentError, "this run has no result.media.downloadPath" if path.nil? || path.empty?

      if path.start_with?("http://", "https://")
        base = URI.parse(@base_url)
        target = URI.parse(path)
        unless target.host == base.host && target.scheme == base.scheme
          raise ArgumentError, "download URL host #{target.host} is not #{base.host}; the token is only sent to the API host"
        end

        path = target.request_uri
      end
      request("GET", path, raw: true)
    end

    # ---- iterators ----

    # Every run, following nextCursor. Returns an Enumerator of RunSummary.
    def each_run(**params, &block)
      paginate(block) { |cursor| page = list_runs(**params, cursor: cursor); [page.runs, page.next_cursor] }
    end

    # Every public catalog item, following nextCursor. Returns an Enumerator of CatalogItem.
    def each_public_catalog_item(**params, &block)
      paginate(block) { |cursor| page = public_catalog(**params, cursor: cursor); [page.items, page.next_cursor] }
    end

    # Every search row, following nextOffset. Returns an Enumerator of SearchRow.
    def each_search_result(q = nil, **params, &block)
      paginate(block) { |offset| page = search(q, **params, offset: offset); [page.endpoints, page.next_offset] }
    end

    # A new idempotency key: sdk-<uuid v4>.
    def self.new_idempotency_key
      "sdk-#{SecureRandom.uuid}"
    end

    # looot-ruby/<version> ruby/<ruby version>
    def self.user_agent
      "looot-ruby/#{VERSION} ruby/#{RUBY_VERSION}"
    end

    private

    def env_token
      [ENV["LOOOT_TOKEN"], ENV["LOOOT_API_KEY"]].map { |value| value.to_s.strip }.find { |value| !value.empty? }
    end

    def get(path, **query)
      request("GET", path, query: query)
    end

    def post(path, body)
      request("POST", path, body: body)
    end

    def request(method, path, query: {}, body: nil, raw: false)
      public_route = PUBLIC_PATHS.any? { |pattern| pattern.match?(path) }
      if !public_route && !token?
        raise LoootError.new("#{method} #{path} needs a token: set LOOOT_TOKEN or pass token",
                             status: 401, code: "missing_token")
      end

      url = build_url(path, query)
      headers = build_headers(public_route, !body.nil?)
      payload = body.nil? ? nil : JSON.generate(body)
      attempt = 0
      loop do
        begin
          response = @transport.call(method: method, url: url, headers: headers, body: payload, timeout: @timeout)
        rescue TransportError => e
          raise LoootError.new(e.message, status: 0, code: e.kind == :timeout ? "timeout" : "network_error",
                                          retryable: true) unless attempt < @max_retries

          attempt += 1
          @sleeper.call(backoff(attempt, nil))
          next
        end
        return decode_success(response, raw) if response.status.between?(200, 299)

        error = LoootError.from_response(method: method, path: path, status: response.status,
                                         body: decode(response.body), headers: response.headers || {})
        raise error unless attempt < @max_retries && auto_retry?(error)

        attempt += 1
        @sleeper.call(backoff(attempt, error.retry_after_seconds))
      end
    end

    # 429 and the retryable 503 codes. Never another 4xx, never a 500.
    def auto_retry?(error)
      return true if error.status == 429
      return error.code != "billing_unavailable" && error.retryable? if error.status == 503

      false
    end

    def backoff(attempt, retry_after)
      return [retry_after, MAX_RETRY_WAIT].min if retry_after

      [0.5 * (2**(attempt - 1)), MAX_RETRY_WAIT].min + (rand * 0.25)
    end

    def build_url(path, query)
      clean = query.each_with_object({}) do |(key, value), out|
        next if value.nil?

        out[key.to_s] = [true, false].include?(value) ? value.to_s : value
      end
      url = "#{@base_url}#{path}"
      clean.empty? ? url : "#{url}?#{URI.encode_www_form(clean)}"
    end

    def build_headers(public_route, has_body)
      headers = { "Accept" => "application/json", "User-Agent" => self.class.user_agent }
      headers["Content-Type"] = "application/json" if has_body
      headers["Authorization"] = "Bearer #{@token}" if !public_route && token?
      headers["X-Looot-Agent"] = @agent if @agent && !@agent.empty?
      headers
    end

    def decode_success(response, raw)
      return response.body if raw

      decoded = decode(response.body)
      return {} if decoded.nil?

      decoded.is_a?(Hash) ? decoded : { "value" => decoded }
    end

    def decode(text)
      return nil if text.nil? || text.empty?

      JSON.parse(text)
    rescue JSON::ParserError
      text
    end

    # Percent-encodes one path segment, so "a/b" or "job:x" cannot change the path.
    def segment(value)
      value.to_s.b.gsub(/[^A-Za-z0-9\-._~]/) { |char| format("%%%02X", char.ord) }
    end

    def camel_keys(hash)
      hash.each_with_object({}) do |(key, value), out|
        name = key.to_s.gsub(/_([a-z\d])/) { Regexp.last_match(1).upcase }
        out[name.to_sym] = value
      end
    end

    def paginate(block, &fetch)
      enum = Enumerator.new do |yielder|
        cursor = nil
        loop do
          rows, cursor = fetch.call(cursor)
          Array(rows).each { |row| yielder << row }
          break if cursor.nil?
        end
      end
      block ? enum.each(&block) : enum
    end
  end
end

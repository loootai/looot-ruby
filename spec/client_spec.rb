# frozen_string_literal: true

RSpec.describe Looot::Client do
  base = SpecHelpers::BASE

  describe "free public routes" do
    it "catalog_overview hits /v1/catalog/overview, sends topic and no Authorization" do
      stub = stub_request(:get, "#{base}/v1/catalog/overview")
             .with(query: { "topic" => "email" })
             .to_return(json({ "topic" => "email", "matchCount" => 74, "truncated" => true,
                               "jobs" => [{ "id" => "people.email.find", "cheapestPerCall" => 0.003598 }] }))
      overview = client.catalog_overview(topic: "email")
      expect(stub).to have_been_requested
      expect(WebMock).not_to have_requested(:get, /overview/).with(headers: { "Authorization" => /.*/ })
      expect(overview).to be_a(Looot::CatalogOverview)
      expect(overview.match_count).to eq(74)
      expect(overview.jobs.first).to be_a(Looot::OverviewJob)
      expect(overview.jobs.first.id).to eq("people.email.find")
      expect(overview.jobs.first.cheapest_per_call).to eq(0.003598)
    end

    it "catalog_overview works with no token at all" do
      stub_request(:get, "#{base}/v1/catalog/overview").to_return(json({ "totals" => { "jobs" => 3 } }))
      expect(Looot::Client.new(token: "").catalog_overview.totals).to eq({ "jobs" => 3 })
    end

    it "public_catalog maps operation_id and drops unset params" do
      stub = stub_request(:get, "#{base}/v1/public-catalog")
             .with(query: { "capability" => "people_email_verify", "limit" => "1", "operationId" => "op-1" })
             .to_return(json({ "items" => [{ "catalogItemId" => "anysite-api-emails-verify",
                                             "price" => { "state" => "known", "amountMicros" => 143_880 },
                                             "parameters" => [{ "name" => "email", "required" => true }] }],
                               "nextCursor" => "abc" }))
      page = client.public_catalog(capability: "people_email_verify", limit: 1, operation_id: "op-1")
      expect(stub).to have_been_requested
      expect(WebMock).not_to have_requested(:get, /public-catalog/).with(headers: { "Authorization" => /.*/ })
      item = page.items.first
      expect(item.catalog_item_id).to eq("anysite-api-emails-verify")
      expect(item.price).to be_known
      expect(item.price.amount_micros).to eq(143_880)
      expect(item.parameters.first.name).to eq("email")
      expect(page.next_cursor).to eq("abc")
    end

    it "public_catalog_item encodes the id and sends no token" do
      stub = stub_request(:get, "#{base}/v1/public-catalog/icypeas-email-verify")
             .to_return(json({ "catalogItemId" => "icypeas-email-verify", "providerId" => "icypeas" }))
      item = client.public_catalog_item("icypeas-email-verify")
      expect(stub).to have_been_requested
      expect(WebMock).not_to have_requested(:get, /public-catalog/).with(headers: { "Authorization" => /.*/ })
      expect(item.provider_id).to eq("icypeas")
    end

    it "compare_public_catalog posts catalogItemIds with no token" do
      stub = stub_request(:post, "#{base}/v1/public-catalog/compare")
             .with(body: { "catalogItemIds" => %w[a b] }, headers: { "Content-Type" => "application/json" })
             .to_return(json({ "items" => [{ "catalogItemId" => "a" }, { "catalogItemId" => "b" }] }))
      result = Looot::Client.new(token: "").compare_public_catalog(%w[a b])
      expect(stub).to have_been_requested
      expect(result.items.map(&:catalog_item_id)).to eq(%w[a b])
    end
  end

  describe "token routes" do
    it "search sends the bearer token, maps prefer, maxPriceMicros, keyless=true and drops unset params" do
      stub = stub_request(:get, "#{base}/v1/catalog/search")
             .with(query: { "q" => "verify an email", "prefer" => "cheapest", "maxPriceMicros" => "5000",
                            "keyless" => "true", "verified" => "false" },
                   headers: { "Authorization" => "Bearer #{SpecHelpers::TOKEN}" })
             .to_return(json({ "query" => "verify an email", "total" => 7, "nextOffset" => 5,
                               "endpoints" => [{ "endpointId" => "icypeas-email-verify",
                                                 "capability" => "people.email.verify",
                                                 "estimatedPrice" => 0.0019, "access" => "runs_now",
                                                 "costPerSuccessUsd" => 0.0021,
                                                 "works" => { "rate" => 0.97, "p50Ms" => 380 } }] }))
      result = client.search("verify an email", prefer: "cheapest", max_price_micros: 5000, keyless: true,
                                                verified: false, limit: nil)
      expect(stub).to have_been_requested
      row = result.endpoints.first
      expect(result.total).to eq(7)
      expect(result.next_offset).to eq(5)
      expect(row.endpoint_id).to eq("icypeas-email-verify")
      expect(row.cost_per_success_usd).to eq(0.0021)
      expect(row.works.p50_ms).to eq(380)
    end

    it "a token route with no token raises missing_token and sends nothing" do
      expect { Looot::Client.new.balance }.to raise_error(Looot::LoootError) { |error|
        expect(error.status).to eq(401)
        expect(error.code).to eq("missing_token")
        expect(error.message).to eq("GET /v1/balance needs a token: set LOOOT_TOKEN or pass token")
        expect(error).not_to be_retryable
      }
      expect(WebMock).not_to have_requested(:any, /api\.looot\.ai/)
    end

    it "an explicit empty token does not fall back to LOOOT_TOKEN" do
      ENV["LOOOT_TOKEN"] = "from-env"
      expect { Looot::Client.new(token: "").balance }.to raise_error(Looot::LoootError, /needs a token/)
    end

    it "reads LOOOT_TOKEN, trimmed, then LOOOT_API_KEY" do
      ENV["LOOOT_TOKEN"] = "  env-token  "
      stub = stub_request(:get, "#{base}/v1/balance").with(headers: { "Authorization" => "Bearer env-token" })
                                                    .to_return(json({ "available" => 1 }))
      Looot::Client.new.balance
      expect(stub).to have_been_requested

      ENV.delete("LOOOT_TOKEN")
      ENV["LOOOT_API_KEY"] = "key-token"
      stub2 = stub_request(:get, "#{base}/v1/balance").with(headers: { "Authorization" => "Bearer key-token" })
                                                     .to_return(json({ "available" => 1 }))
      Looot::Client.new.balance
      expect(stub2).to have_been_requested
    end

    it "accepts api_key: as an alias for token:" do
      stub = stub_request(:get, "#{base}/v1/whoami").with(headers: { "Authorization" => "Bearer abc" })
                                                   .to_return(json({ "organization" => { "slug" => "acme" } }))
      expect(Looot::Client.new(api_key: "abc").whoami.organization).to eq({ "slug" => "acme" })
      expect(stub).to have_been_requested
    end

    it "inspect_endpoint encodes the endpoint id" do
      stub = stub_request(:get, "#{base}/v1/operations/icypeas-email-verify")
             .to_return(json({ "endpoint" => { "id" => "icypeas-email-verify", "effectClassification" => "read" },
                               "inputSchema" => { "type" => "object" }, "estimatedMaxCost" => 0.0019 }))
      operation = client.inspect_endpoint("icypeas-email-verify")
      expect(stub).to have_been_requested
      expect(operation.input_schema).to eq({ "type" => "object" })
      expect(operation.estimated_max_cost).to eq(0.0019)
      expect(operation).not_to be_effectful
    end

    it "discover sends query and camelCases extra params" do
      stub = stub_request(:get, "#{base}/v1/discover").with(query: { "query" => "find a work email", "maxResults" => "3" })
                                                     .to_return(json({ "candidates" => [{ "endpointId" => "x" }], "meta" => {} }))
      expect(client.discover("find a work email", max_results: 3).candidates.size).to eq(1)
      expect(stub).to have_been_requested
    end

    it "catalog_endpoints passes cursor, facets and maxPriceMicros" do
      stub = stub_request(:get, "#{base}/v1/catalog/endpoints")
             .with(query: { "cursor" => "c1", "facets" => "true", "maxPriceMicros" => "100", "limit" => "50" })
             .to_return(json({ "endpoints" => [], "nextCursor" => nil, "facets" => { "category" => {} } }))
      page = client.catalog_endpoints(cursor: "c1", facets: true, max_price_micros: 100, limit: 50)
      expect(stub).to have_been_requested
      expect(page.next_cursor).to be_nil
    end
  end

  describe "runs" do
    it "run_job posts job:<id>, puts wait=20 in the query and merges prefer into fallback" do
      stub = stub_request(:post, "#{base}/v1/runs").with(query: { "wait" => "20" })
                                                  .to_return(json({ "runId" => "run_1", "status" => "completed", "outcome" => "hit",
                                                                    "route" => { "servedBy" => "icypeas-email-verify", "chargedUsd" => 0.0019,
                                                                                 "attempts" => [{ "n" => 1, "endpointId" => "icypeas-email-verify", "ms" => 380 }] },
                                                                    "requestedJob" => { "pickedEndpointId" => "icypeas-email-verify" } }, status: 201))
      run = client.run_job("people.email.verify", { email: "jane.doe@example.com" }, prefer: "cheapest",
                                                                                     fallback: { max_attempts: 3 }, wait: 20)
      expect(stub).to have_been_requested
      sent = nil
      expect(WebMock).to(have_requested(:post, "#{base}/v1/runs?wait=20").with { |req| sent = body_of(req) })
      expect(sent["endpointId"]).to eq("job:people.email.verify")
      expect(sent["input"]).to eq({ "email" => "jane.doe@example.com" })
      expect(sent["fallback"]).to eq({ "maxAttempts" => 3, "prefer" => "cheapest" })
      expect(sent).not_to have_key("wait")
      expect(sent["idempotencyKey"]).to match(/\Asdk-[0-9a-f-]{36}\z/)
      expect(run).to be_success
      expect(run.route.served_by).to eq("icypeas-email-verify")
      expect(run.route.attempts.first.ms).to eq(380)
      expect(run.requested_job.picked_endpoint_id).to eq("icypeas-email-verify")
    end

    it "run_job with prefer and fallback: true sends { prefer }" do
      stub_request(:post, "#{base}/v1/runs").to_return(json({ "runId" => "run_2", "status" => "queued" }, status: 201))
      client.run_job("people.email.find", { firstName: "Jane" }, prefer: "reliable", fallback: true)
      expect(WebMock).to(have_requested(:post, "#{base}/v1/runs").with { |req| body_of(req)["fallback"] == { "prefer" => "reliable" } })
    end

    it "run_job without prefer or fallback sends no fallback key, and passes output through" do
      stub_request(:post, "#{base}/v1/runs").to_return(json({ "runId" => "run_3", "status" => "queued" }, status: 201))
      client.run_job("company.enrich", { domain: "example.com" }, output: { "pin" => "x" }, idempotency_key: "lead-1")
      expect(WebMock).to(have_requested(:post, "#{base}/v1/runs").with do |req|
        body = body_of(req)
        !body.key?("fallback") && body["output"] == { "pin" => "x" } && body["idempotencyKey"] == "lead-1"
      end)
    end

    it "run with fallback: true sends true and no wait query when wait is nil" do
      stub_request(:post, "#{base}/v1/runs").to_return(json({ "runId" => "run_4", "status" => "queued" }, status: 201))
      client.run_job("people.email.find", { firstName: "Jane", lastName: "Doe", domain: "example.com" }, fallback: true)
      expect(WebMock).to(have_requested(:post, "#{base}/v1/runs").with { |req| body_of(req)["fallback"] == true })
    end

    it "run keeps an explicit fallback object and generates an sdk- idempotency key" do
      stub = stub_request(:post, "#{base}/v1/runs").with(query: { "wait" => "20" }, headers: { "Content-Type" => "application/json" })
                                                  .to_return(json({ "runId" => "run_000028", "status" => "completed",
                                                                    "actualCost" => 0.0019, "error" => nil }, status: 201))
      run = client.run("icypeas-email-verify", { email: "jane.doe@example.com" }, wait: 20,
                                                                                  fallback: { "maxAttempts" => 2, "maxCostUsd" => 0.05 })
      expect(stub).to have_been_requested
      expect(WebMock).to(have_requested(:post, "#{base}/v1/runs?wait=20").with do |req|
        body = body_of(req)
        body["fallback"] == { "maxAttempts" => 2, "maxCostUsd" => 0.05 } && body["idempotencyKey"].start_with?("sdk-")
      end)
      expect(run.actual_cost).to eq(0.0019)
      expect(run.error).to be_nil
    end

    it "generates a different key for each run" do
      keys = []
      stub_request(:post, "#{base}/v1/runs").to_return do |req|
        keys << body_of(req)["idempotencyKey"]
        json({ "status" => "queued" }, status: 201)
      end
      2.times { client.run("x", {}) }
      expect(keys.uniq.size).to eq(2)
    end

    it "a 201 with status failed comes back as a run, not an error" do
      stub_request(:post, "#{base}/v1/runs").to_return(json({
                                                              "runId" => "run_9", "status" => "failed", "outcome" => "error", "actualCost" => 0,
                                                              "result" => { "code" => "no_supply_for_job" },
                                                              "error" => { "code" => "validation_error", "message" => "No provider supplies this job.",
                                                                           "whoseError" => "customer", "retryable" => false,
                                                                           "retryHint" => "Pick a job from catalog_overview." }
                                                            }, status: 201))
      run = client.run_job("made.up.job", {})
      expect(run).to be_a(Looot::Run)
      expect(run).to be_failed
      expect(run).not_to be_success
      expect(run).to be_terminal
      expect(run.error.code).to eq("validation_error")
      expect(run.error.retry_hint).to eq("Pick a job from catalog_overview.")
      expect(run.error).not_to be_retryable
      expect(run["result"]["code"]).to eq("no_supply_for_job")
    end

    it "get_run encodes path segments: a/b becomes a%2Fb" do
      stub = stub_request(:get, "#{base}/v1/runs/a%2Fb").to_return(json({ "runId" => "a/b", "status" => "running" }))
      expect(client.get_run("a/b").status).to eq("running")
      expect(stub).to have_been_requested
    end

    it "get_run sends fields and max_items" do
      stub = stub_request(:get, "#{base}/v1/runs/run_1").with(query: { "fields" => "a.b,c", "max_items" => "10" })
                                                       .to_return(json({ "runId" => "run_1", "trimmed" => true,
                                                                         "pricing" => { "finalChargeMicros" => 1900 } }))
      run = client.get_run("run_1", fields: ["a.b", "c"], max_items: 10)
      expect(stub).to have_been_requested
      expect(run.trimmed).to be(true)
      expect(run.final_charge_micros).to eq(1900)
    end

    it "list_runs maps include_result and returns summaries" do
      stub = stub_request(:get, "#{base}/v1/runs").with(query: { "status" => "completed", "limit" => "5", "includeResult" => "false" })
                                                 .to_return(json({ "nextCursor" => "run_x",
                                                                   "runs" => [{ "runId" => "run_a", "providerId" => "linkup", "actualCost" => 0.005 }] }))
      list = client.list_runs(status: "completed", limit: 5, include_result: false)
      expect(stub).to have_been_requested
      expect(list.runs.first.provider_id).to eq("linkup")
      expect(list.next_cursor).to eq("run_x")
    end

    it "each_run follows nextCursor until null" do
      stub_request(:get, "#{base}/v1/runs").with(query: { "limit" => "1" })
                                          .to_return(json({ "runs" => [{ "runId" => "r1" }], "nextCursor" => "c2" }))
      stub_request(:get, "#{base}/v1/runs").with(query: { "limit" => "1", "cursor" => "c2" })
                                          .to_return(json({ "runs" => [{ "runId" => "r2" }], "nextCursor" => nil }))
      expect(client.each_run(limit: 1).map(&:run_id)).to eq(%w[r1 r2])
    end

    it "each_public_catalog_item and each_search_result follow their page tokens" do
      stub_request(:get, "#{base}/v1/public-catalog").to_return(json({ "items" => [{ "catalogItemId" => "i1" }], "nextCursor" => "n" }))
      stub_request(:get, "#{base}/v1/public-catalog").with(query: { "cursor" => "n" })
                                                    .to_return(json({ "items" => [{ "catalogItemId" => "i2" }], "nextCursor" => nil }))
      expect(client.each_public_catalog_item.map(&:catalog_item_id)).to eq(%w[i1 i2])

      stub_request(:get, "#{base}/v1/catalog/search").with(query: { "q" => "x" })
                                                    .to_return(json({ "endpoints" => [{ "endpointId" => "e1" }], "nextOffset" => 1 }))
      stub_request(:get, "#{base}/v1/catalog/search").with(query: { "q" => "x", "offset" => "1" })
                                                    .to_return(json({ "endpoints" => [{ "endpointId" => "e2" }], "nextOffset" => nil }))
      expect(client.each_search_result("x").map(&:endpoint_id)).to eq(%w[e1 e2])
    end

    it "cancel_run posts with no body and returns the run" do
      stub = stub_request(:post, "#{base}/v1/runs/run_000028/cancel").to_return(json({ "status" => "stopped" }))
      expect(client.cancel_run("run_000028").status).to eq("stopped")
      expect(stub).to have_been_requested
      expect(WebMock).not_to have_requested(:post, /cancel/).with(headers: { "Content-Type" => "application/json" })
    end

    it "run_attempts returns typed attempts" do
      stub_request(:get, "#{base}/v1/runs/run_000028/attempts")
        .to_return(json({ "attempts" => [{ "providerId" => "hunter", "status" => "succeeded", "costMicros" => 12_250 }] }))
      attempt = client.run_attempts("run_000028").attempts.first
      expect(attempt.provider_id).to eq("hunter")
      expect(attempt.cost_micros).to eq(12_250)
    end

    it "wait_for_run polls until a terminal status and backs off" do
      stub_request(:get, "#{base}/v1/runs/run_1").to_return(json({ "status" => "queued" }), json({ "status" => "running" }),
                                                           json({ "status" => "completed" }))
      waits = []
      looot = Looot::Client.new(token: "t", sleeper: ->(s) { waits << s })
      expect(looot.wait_for_run("run_1").status).to eq("completed")
      expect(waits).to eq([1, 2])
    end

    it "wait_for_run raises a timeout error past the deadline" do
      stub_request(:get, "#{base}/v1/runs/run_1").to_return(json({ "status" => "running" }))
      now = 0.0
      looot = Looot::Client.new(token: "t", sleeper: ->(s) { now += s })
      expect { looot.wait_for_run("run_1", timeout: 3, clock: -> { now }) }
        .to raise_error(Looot::LoootError) { |e| expect(e.code).to eq("timeout") }
    end

    it "download_media sends the token to the API host and returns bytes" do
      stub = stub_request(:get, "#{base}/v1/media-downloads/run_1/m1")
             .with(headers: { "Authorization" => "Bearer #{SpecHelpers::TOKEN}" })
             .to_return(status: 200, body: "PNGDATA", headers: { "Content-Type" => "image/png" })
      run = Looot::Run.new({ "result" => { "media" => { "downloadPath" => "/v1/media-downloads/run_1/m1" } } })
      expect(client.download_media(run)).to eq("PNGDATA")
      expect(stub).to have_been_requested
    end

    it "download_media refuses another host so the token stays with the API" do
      expect { client.download_media("https://evil.example.com/x") }.to raise_error(ArgumentError, /not api.looot.ai/)
    end
  end

  describe "money and account" do
    it "balance returns typed amounts and the top-up link" do
      stub_request(:get, "#{base}/v1/balance").to_return(json({
                                                                "workspaceId" => "ws_1", "currency" => "USD", "available" => 94.628918, "reserved" => 0,
                                                                "topUpLink" => { "minimumUsd" => 5, "suggestedUsd" => 5, "checkoutUrl" => nil,
                                                                                 "dashboardUrl" => "https://looot.ai/usage?top_up=1",
                                                                                 "reason" => "balance_sufficient" }
                                                              }))
      balance = client.balance
      expect(balance.available).to eq(94.628918)
      expect(balance.top_up_link.minimum_usd).to eq(5)
      expect(balance.top_up_link.url).to eq("https://looot.ai/usage?top_up=1")
      expect(balance.covers?(0.0019)).to be(true)
      expect(balance.covers?(100)).to be(false)
    end

    it "list_top_ups, ledger and whoami hit their routes" do
      stub_request(:get, "#{base}/v1/top-ups").to_return(json({ "topUps" => [{ "id" => "tu_1" }] }))
      stub_request(:get, "#{base}/v1/ledger").with(query: { "limit" => "2" })
                                            .to_return(json({ "entries" => [{ "kind" => "top_up" }], "nextCursor" => nil }))
      stub_request(:get, "#{base}/v1/whoami").to_return(json({ "organization" => { "slug" => "acme" } }))
      expect(client.list_top_ups.top_ups.size).to eq(1)
      expect(client.ledger(limit: 2).entries.first["kind"]).to eq("top_up")
      expect(client.whoami.organization["slug"]).to eq("acme")
    end

    it "capability_request posts camelCase fields and an idempotency key" do
      stub_request(:post, "#{base}/v1/capability-requests").to_return(json({ "requestId" => "cr_1", "status" => "open" }, status: 201))
      result = client.capability_request(title: "Find a phone from LinkedIn", description: "Need mobile numbers",
                                         desired_inputs: ["linkedinUrl"], desired_outputs: ["phone"])
      expect(result.status).to eq("open")
      expect(WebMock).to(have_requested(:post, "#{base}/v1/capability-requests").with do |req|
        body = body_of(req)
        body["desiredInputs"] == ["linkedinUrl"] && body["idempotencyKey"].start_with?("sdk-")
      end)
    end
  end

  describe "headers and configuration" do
    it "sends Accept and User-Agent, no Content-Type on GET, and X-Looot-Agent only when set" do
      stub_request(:get, "#{base}/v1/balance").to_return(json({}))
      client.balance
      expect(WebMock).to(have_requested(:get, "#{base}/v1/balance").with do |req|
        req.headers["Accept"] == "application/json" &&
          req.headers["User-Agent"] == "looot-ruby/#{Looot::VERSION} ruby/#{RUBY_VERSION}" &&
          !req.headers.key?("Content-Type") && !req.headers.key?("X-Looot-Agent")
      end)

      client(agent: "x" * 80).balance
      expect(WebMock).to(have_requested(:get, "#{base}/v1/balance").with { |req| req.headers["X-Looot-Agent"] == "x" * 64 })
    end

    it "strips trailing slashes from base_url" do
      stub = stub_request(:get, "http://localhost:8787/v1/balance").to_return(json({ "available" => 2 }))
      expect(client(base_url: "http://localhost:8787//").balance.available).to eq(2)
      expect(stub).to have_been_requested
    end

    it "never shows the token in inspect" do
      looot = Looot::Client.new(token: "secret-value-123")
      expect(looot.inspect).not_to include("secret-value-123")
      expect(looot.to_s).to include("[set]")
    end

    it "passes the timeout to a custom transport" do
      seen = {}
      transport = Object.new
      transport.define_singleton_method(:call) do |method:, url:, headers:, body:, timeout:|
        seen.merge!(method: method, url: url, timeout: timeout, auth: headers["Authorization"], body: body)
        Looot::Response.new(status: 200, headers: {}, body: '{"available":3}')
      end
      looot = Looot::Client.new(token: "t", timeout: 12, transport: transport)
      expect(looot.balance.available).to eq(3)
      expect(seen).to include(method: "GET", url: "https://api.looot.ai/v1/balance", timeout: 12, auth: "Bearer t", body: nil)
    end

    it "keeps unknown response keys reachable" do
      stub_request(:get, "#{base}/v1/runs/r").to_return(json({ "runId" => "r", "brandNewField" => { "x" => 1 } }))
      run = client.get_run("r")
      expect(run["brandNewField"]).to eq({ "x" => 1 })
      expect(run.dig(:brandNewField, "x")).to eq(1)
      expect(run.to_h.keys).to include("brandNewField")
    end

    it "Looot.new builds a client" do
      expect(Looot.new(token: "t")).to be_a(Looot::Client)
    end
  end
end

RSpec.describe "README quickstart" do
  base = SpecHelpers::BASE

  it "checks the balance, then runs people.email.find with fallback true" do
    ENV["LOOOT_TOKEN"] = "env-token"
    stub_request(:get, "#{base}/v1/balance").to_return(json({ "available" => 10, "topUpLink" => { "dashboardUrl" => "https://looot.ai/usage?top_up=1" } }))
    stub_request(:post, "#{base}/v1/runs").with(query: { "wait" => "20" }).to_return(json({
                                                                                          "runId" => "run_1", "status" => "completed", "outcome" => "hit", "result" => { "email" => "jane.doe@example.com" },
                                                                                          "actualCost" => 0.01, "error" => nil
                                                                                        }, status: 201))
    looot = Looot::Client.new
    expect(looot.balance.available).to be_positive
    run = looot.run_job("people.email.find", { firstName: "Jane", lastName: "Doe", domain: "example.com" },
                        fallback: true, wait: 20, idempotency_key: "lead-4821-email")
    expect(run).to be_success
    expect(WebMock).to(have_requested(:post, "#{base}/v1/runs?wait=20").with do |req|
      body = JSON.parse(req.body)
      body == { "endpointId" => "job:people.email.find",
                "input" => { "firstName" => "Jane", "lastName" => "Doe", "domain" => "example.com" },
                "idempotencyKey" => "lead-4821-email", "fallback" => true }
    end)
  end
end

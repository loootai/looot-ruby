# frozen_string_literal: true

module Looot
  # Base class for every response object.
  #
  # A model wraps the decoded JSON hash. Typed readers cover the fields the
  # contract names; every other key stays reachable with model["someKey"],
  # model.to_h and model.dig, because the gateway adds fields over time.
  class Model
    class << self
      # Declares a reader. `type` is a Model subclass, or [Model subclass] for a list.
      def field(name, key = nil, type = nil)
        key ||= camelize(name.to_s)
        fields[name] = key
        define_method(name) { coerce(@data[key], type) }
      end

      def fields
        @fields ||= superclass.respond_to?(:fields) ? superclass.fields.dup : {}
      end

      # Wraps a hash, returns nil and other values as they are.
      def wrap(value)
        value.is_a?(Hash) ? new(value) : value
      end

      private

      def camelize(name)
        head, *rest = name.sub(/\?\z/, "").split("_")
        head + rest.map(&:capitalize).join
      end
    end

    def initialize(data = {})
      @data = data.is_a?(Hash) ? data : {}
    end

    # Raw access by wire key: run["runId"].
    def [](key)
      @data[key.to_s]
    end

    def key?(key)
      @data.key?(key.to_s)
    end

    def dig(*keys)
      @data.dig(*keys.map { |k| k.is_a?(Symbol) ? k.to_s : k })
    end

    # The decoded JSON, every key kept.
    def to_h
      @data
    end
    alias to_hash to_h

    def ==(other)
      other.class == self.class && other.to_h == to_h
    end

    def inspect
      shown = self.class.fields.keys.first(6).map { |name| "#{name}=#{public_send(name).inspect}" }
      "#<#{self.class.name} #{shown.join(' ')}>"
    end

    private

    def coerce(value, type)
      case type
      when Array then value.is_a?(Array) ? value.map { |item| type.first.wrap(item) } : value
      when Class then type.wrap(value)
      else value
      end
    end
  end

  # Run lifecycle values. The gateway may add more, so treat status as a string.
  module RunStatus
    QUEUED = "queued"
    RUNNING = "running"
    PENDING_PROVIDER = "pending_provider"
    COMPLETED = "completed"
    FAILED = "failed"
    BLOCKED = "blocked"
    STOPPED = "stopped"
    RECONCILIATION_PENDING = "reconciliation_pending"
    # Statuses that do not change any more (reconciliation_pending is terminal for polling).
    TERMINAL = [COMPLETED, FAILED, BLOCKED, STOPPED, RECONCILIATION_PENDING].freeze
  end

  # Was the answer any good. A completed run can be a miss.
  module RunOutcome
    HIT = "hit"
    WEAK = "weak"
    MISS = "miss"
    ERROR = "error"
    REJECTED = "rejected"
    SKIPPED = "skipped"
    PENDING = "pending"
  end

  # How search and fallback rank providers.
  module Prefer
    BALANCED = "balanced"
    CHEAPEST = "cheapest"
    RELIABLE = "reliable"
    FASTEST = "fastest"
    ALL = [BALANCED, CHEAPEST, RELIABLE, FASTEST].freeze
  end

  # The error object on a failed or blocked run.
  class RunError < Model
    field :code
    field :message
    field :request_id
    field :provider_status
    field :whose_error
    field :retryable
    field :retry_hint

    def retryable?
      self["retryable"] == true
    end
  end

  # One provider tried on a fallback route.
  class RouteAttempt < Model
    field :n
    field :endpoint_id
    field :provider
    field :outcome
    field :status
    field :charged_usd, "chargedUsd"
    field :billed
    field :ms
    field :reason
    field :verdict
  end

  # A provider the route did not try, and why.
  class RouteSkip < Model
    field :endpoint_id
    field :provider_id
    field :code
    field :reason
  end

  # The fallback route a run took.
  class Route < Model
    field :served_by
    field :outcome
    field :charged_usd, "chargedUsd"
    field :capped
    field :attempts, nil, [RouteAttempt]
    field :skipped, nil, [RouteSkip]
    field :summary
  end

  # What a job run asked for and which endpoint looot picked.
  class RequestedJob < Model
    field :id
    field :job
    field :prefer
    field :picked_endpoint_id
    field :reason
    field :skipped
  end

  # Mapped fields for a job run. Absent when it does not apply.
  class Normalized < Model
    field :job
    field :endpoint_id
    field :fields
    field :missing
    field :ambiguous
    field :unmapped
    field :provider_values
    field :verdict
    field :verdict_reason
    field :map_verified
  end

  # A run, as POST /v1/runs and GET /v1/runs/{runId} return it.
  class Run < Model
    field :run_id
    field :status
    field :endpoint_id
    field :outcome
    field :outcome_reason
    field :result
    field :normalized, nil, Normalized
    field :estimated_cost
    field :actual_cost
    field :pricing
    field :reservation_id
    field :error, nil, RunError
    field :replayed
    field :requested_job, nil, RequestedJob
    field :route, nil, Route
    field :next_steps
    field :provider_text
    field :trimmed

    # Final charge in millionths of a dollar, when settled.
    def final_charge_micros
      dig("pricing", "finalChargeMicros")
    end

    def terminal?
      RunStatus::TERMINAL.include?(status)
    end

    # Completed with no error. A completed run can still be a miss: read outcome.
    def success?
      status == RunStatus::COMPLETED && self["error"].nil?
    end

    def failed?
      [RunStatus::FAILED, RunStatus::BLOCKED].include?(status)
    end

    def replayed?
      self["replayed"] == true
    end

    # result.media.downloadPath, for a run that produced a file.
    def download_path
      dig("result", "media", "downloadPath")
    end
  end

  # One row of GET /v1/runs.
  class RunSummary < Model
    field :run_id
    field :endpoint_id
    field :job
    field :provider_id
    field :status
    field :provider_response_status
    field :created_at
    field :completed_at
    field :actual_cost
    field :error, nil, RunError
    field :result_bytes
    field :served_endpoint_id
    field :served_provider_id
  end

  # GET /v1/runs.
  class RunList < Model
    field :runs, nil, [RunSummary]
    field :next_cursor
  end

  # One attempt of a run.
  class Attempt < Model
    field :attempt_id
    field :provider_id
    field :status
    field :provider_response_status
    field :latency_ms
    field :receipt_id
    field :cost_micros
  end

  # GET /v1/runs/{runId}/attempts.
  class AttemptList < Model
    field :attempts, nil, [Attempt]
  end

  # Where the user adds credits. Show checkout_url when set, else dashboard_url.
  class TopUpLink < Model
    field :minimum_usd, "minimumUsd"
    field :suggested_usd, "suggestedUsd"
    field :checkout_url
    field :dashboard_url
    field :message
    field :reason

    # checkoutUrl when a Stripe session is open, else dashboardUrl.
    def url
      checkout_url || dashboard_url
    end
  end

  # GET /v1/balance. Amounts are USD.
  class Balance < Model
    field :workspace_id
    field :currency
    field :available
    field :reserved
    field :holds
    field :trial_credit_micros
    field :recent_spend_micros
    field :top_up_link, nil, TopUpLink

    # True when available covers the given USD estimate.
    def covers?(estimate_usd)
      available.is_a?(Numeric) && estimate_usd.is_a?(Numeric) && available >= estimate_usd
    end
  end

  # How well an endpoint has worked lately.
  class Works < Model
    field :rate
    field :runs
    field :p50_ms, "p50Ms"
    field :thin
  end

  # One row of GET /v1/catalog/search.
  class SearchRow < Model
    field :endpoint_id
    field :provider
    field :name
    field :capability
    field :source_capability
    field :category
    field :access
    field :estimated_price
    field :price_basis
    field :cost_per_success_usd, "costPerSuccessUsd"
    field :works, nil, Works
    field :async
    field :credential
    field :job
  end

  # GET /v1/catalog/search. REST names the list `endpoints`.
  class SearchResult < Model
    field :query
    field :total
    field :endpoints, nil, [SearchRow]
    field :next_offset
    field :prefer
    field :warnings
    field :price_hint
  end

  # One job in the catalog overview. Prices are USD and nullable.
  class OverviewJob < Model
    field :id
    field :title
    field :category
    field :platform
    field :provider_count
    field :endpoint_count
    field :runnable_count
    field :cheapest_per_call
    field :cheapest_per_result
  end

  # GET /v1/catalog/overview.
  class CatalogOverview < Model
    field :revision
    field :built_at
    field :depth
    field :totals
    field :categories
    field :topic
    field :match_count
    field :truncated
    field :jobs, nil, [OverviewJob]
  end

  # Price of a public catalog item: state "known" with amountMicros, or "unknown" / "uncomputable".
  class CatalogPrice < Model
    field :state
    field :amount_micros
    field :currency
    field :unit
    field :effective_at
    field :reason

    def known?
      state == "known"
    end
  end

  # A parameter of a public catalog item.
  class CatalogParameter < Model
    field :name
    field :location
    field :required
    field :description
  end

  # One item of the public catalog.
  class CatalogItem < Model
    field :catalog_item_id
    field :revision
    field :provider_id
    field :operation_id
    field :title
    field :description
    field :categories
    field :capabilities
    field :parameters, nil, [CatalogParameter]
    field :price, nil, CatalogPrice
    field :verification
    field :published_at
    field :item_digest
    field :provenance_tier
  end

  # GET /v1/public-catalog.
  class PublicCatalogPage < Model
    field :items, nil, [CatalogItem]
    field :catalog_digest
    field :next_cursor
    field :unsupplied_jobs
    field :warnings
  end

  # POST /v1/public-catalog/compare.
  class CatalogComparison < Model
    field :items, nil, [CatalogItem]
  end

  # GET /v1/operations/{endpointId}.
  class Operation < Model
    field :endpoint
    field :estimated_max_cost
    field :price_range
    field :input_schema
    field :request_binding
    field :ui_schema
    field :output_format
    field :usage_hints

    # endpoint.effectClassification == "effectful" marks a write action.
    def effectful?
      dig("endpoint", "effectClassification") == "effectful"
    end
  end

  # GET /v1/discover: up to 5 candidates.
  class DiscoverResult < Model
    field :candidates
    field :meta
  end

  # GET /v1/catalog/endpoints.
  class CatalogEndpointsPage < Model
    field :endpoints
    field :next_cursor
    field :facets
  end

  # GET /v1/whoami.
  class Whoami < Model
    field :organization
  end

  # GET /v1/top-ups.
  class TopUpList < Model
    field :top_ups
  end

  # GET /v1/ledger.
  class Ledger < Model
    field :entries
    field :next_cursor
  end

  # POST /v1/capability-requests.
  class CapabilityRequest < Model
    field :request_id
    field :title
    field :description
    field :status
  end
end

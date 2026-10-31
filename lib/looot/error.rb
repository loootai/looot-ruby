# frozen_string_literal: true

module Looot
  # Raised for every non-2xx answer, for a token route called without a token
  # (code "missing_token"), and for network failures (status 0).
  #
  # A run that failed is not an error: run and run_job return it, and you read
  # run.status, run.outcome and run.error.
  class LoootError < StandardError
    # 503 codes that clear up on their own. billing_unavailable does not.
    RETRYABLE_503_CODES = %w[catalog_loading storage_busy storage_uncertain runtime_bridge_timeout].freeze

    attr_reader :status, :code, :request_id, :body, :retry_after_seconds, :top_up, :retry_hint, :whose_error, :details

    def initialize(message, status:, code:, request_id: nil, body: nil, retryable: nil,
                   retry_after_seconds: nil, top_up: nil, retry_hint: nil, whose_error: nil, details: nil)
      super(message)
      @status = status
      @code = code
      @request_id = request_id
      @body = body
      @retryable = retryable.nil? ? self.class.retryable_for(status, code) : retryable
      @retry_after_seconds = retry_after_seconds
      @top_up = top_up
      @retry_hint = retry_hint
      @whose_error = whose_error
      @details = details
    end

    # True when the same request may succeed later. Read from the body when the
    # gateway sends it, else from the contract table.
    def retryable?
      @retryable
    end
    alias retryable retryable?

    # The 402 body's topUp.checkoutUrl, when Stripe already has a session open.
    def checkout_url
      top_up && top_up["checkoutUrl"]
    end

    # The 402 body's topUp.dashboardUrl, where the user can always add credits.
    def dashboard_url
      top_up && top_up["dashboardUrl"]
    end

    def to_h
      {
        status: status, code: code, message: message, request_id: request_id,
        retryable: retryable?, retry_after_seconds: retry_after_seconds, retry_hint: retry_hint
      }
    end

    def inspect
      "#<#{self.class.name} status=#{status} code=#{code.inspect} request_id=#{request_id.inspect} message=#{message.inspect}>"
    end

    # The contract's retry table for an HTTP status and error code.
    def self.retryable_for(status, code)
      case status
      when 0, 429, 500 then true
      when 503 then code != "billing_unavailable"
      else false
      end
    end

    # Builds the error from a decoded response. Used by the client.
    def self.from_response(method:, path:, status:, body:, headers:)
      envelope = body.is_a?(Hash) && body["error"].is_a?(Hash) ? body["error"] : {}
      code = string_or_nil(envelope["code"]) || "http_#{status}"
      message = string_or_nil(envelope["message"]) || "#{method} #{path} failed with HTTP #{status}"
      request_id = string_or_nil(envelope["requestId"]) || headers["x-request-id"]
      retryable = [true, false].include?(envelope["retryable"]) ? envelope["retryable"] : nil
      retry_after = body.is_a?(Hash) ? body["retryAfterSeconds"] : nil
      retry_after ||= envelope["retryAfterSeconds"]
      retry_after ||= parse_retry_after(headers["retry-after"])
      top_up = body.is_a?(Hash) && body["topUp"].is_a?(Hash) ? body["topUp"] : nil
      new(message, status: status, code: code, request_id: request_id, body: body, retryable: retryable,
                   retry_after_seconds: retry_after.is_a?(Numeric) ? retry_after : nil, top_up: top_up,
                   retry_hint: string_or_nil(envelope["retryHint"]), whose_error: string_or_nil(envelope["whoseError"]),
                   details: envelope["details"])
    end

    def self.string_or_nil(value)
      value.is_a?(String) && !value.empty? ? value : nil
    end

    def self.parse_retry_after(value)
      return nil if value.nil?

      Float(value.to_s.strip)
    rescue ArgumentError
      nil
    end
    private_class_method :string_or_nil, :parse_retry_after
  end

  # Short alias: Looot::Error is Looot::LoootError.
  Error = LoootError
end

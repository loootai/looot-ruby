# frozen_string_literal: true

module Looot
  # The version of this gem, sent in the User-Agent header.
  VERSION = "0.1.0"

  # The looot REST API. Every route lives under /v1/.
  DEFAULT_BASE_URL = "https://api.looot.ai"

  # Per-request timeout in seconds, long enough for a run with wait: 60.
  DEFAULT_TIMEOUT = 75

  # Automatic retries for 429, retryable 503 codes and network errors.
  DEFAULT_MAX_RETRIES = 2
end

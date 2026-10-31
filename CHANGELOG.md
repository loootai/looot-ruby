# Changelog

## 0.1.0 (unreleased)

First release.

- `Looot::Client` with the 12 core methods: `catalog_overview`, `public_catalog`, `public_catalog_item`,
  `search`, `inspect_endpoint`, `run`, `run_job`, `get_run`, `list_runs`, `cancel_run`, `run_attempts`
  and `balance`.
- Extended methods: `discover`, `catalog_endpoints`, `compare_public_catalog`, `whoami`, `list_top_ups`,
  `ledger`, `capability_request` and `download_media`.
- Helpers: `wait_for_run`, `each_run`, `each_public_catalog_item`, `each_search_result`.
- Response models with typed readers. Unknown keys stay reachable with `model["key"]` and `to_h`.
- `Looot::LoootError` with `status`, `code`, `request_id`, `retryable?`, `retry_hint`,
  `retry_after_seconds` and the 402 `top_up` links. Network failures raise it with status 0.
- Automatic retries for 429, retryable 503 codes and network errors, 2 by default, with the same
  idempotency key.
- `User-Agent: looot-ruby/0.1.0 ruby/<version>` and an optional `X-Looot-Agent`.
- No runtime dependencies. Uses `net/http` from the standard library.

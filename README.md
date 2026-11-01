# looot-ruby

The official Ruby SDK for [looot](https://looot.ai). Search the looot catalog, price an endpoint,
run a job with fallback across providers, read your runs and check your balance.

It has no runtime dependencies. It uses `net/http` from the Ruby standard library and needs Ruby 3.2 or newer.

## Install

The gem is not on RubyGems.org yet. Install it from GitHub in a Gemfile:

```ruby
gem "looot", git: "https://github.com/loootai/looot-ruby", branch: "main"
```

After the first RubyGems release, `gem install looot` or `gem "looot", "~> 0.1"` will work too.

## Quickstart

Get a token at [looot.ai](https://looot.ai) and export it as `LOOOT_TOKEN`. This finds a work email
with the `people.email.find` job. Check the balance before a paid run.

```ruby
require "looot"

looot = Looot::Client.new # reads LOOOT_TOKEN
balance = looot.balance
abort "Add credits: #{balance.top_up_link.url}" unless balance.available.positive?

run = looot.run_job("people.email.find", { firstName: "Jane", lastName: "Doe", domain: "example.com" },
                    fallback: true, wait: 20, idempotency_key: "lead-4821-email")
puts run.success? ? run.result : "#{run.status}: #{run.error&.retry_hint}"
puts "charged $#{run.actual_cost}"
```

`fallback: true` lets looot try the next provider when one misses. The idempotency key comes from
your own record, so a crashed worker that runs this again gets the first run back instead of
paying twice. Leave it out and the SDK generates `sdk-<uuid>`.

## Configuration

```ruby
Looot::Client.new(
  token: "...",                        # default: LOOOT_TOKEN, then LOOOT_API_KEY
  base_url: "https://api.looot.ai",    # default
  timeout: 75,                         # seconds per request, enough for wait: 60
  max_retries: 2,                      # 429, retryable 503 codes and network errors; 0 turns it off
  agent: "my-app"                      # sent as X-Looot-Agent, for usage analytics only
)
```

`api_key:` works as an alias for `token:`. Passing `token: ""` means no token: the SDK does not
fall back to the environment. Free public routes never send the token.

Retries reuse the same idempotency key, so a retried run never charges twice. The SDK never
retries another 4xx, a 500 or `billing_unavailable`. It waits for `Retry-After` when the gateway
sends it, at most 30 seconds.

## Methods

| Method | HTTP | Token | Cost |
| --- | --- | --- | --- |
| `catalog_overview(depth:, category:, platform:, topic:)` | `GET /v1/catalog/overview` | no | free |
| `public_catalog(q:, capability:, category:, provider:, operation_id:, limit:, cursor:)` | `GET /v1/public-catalog` | no | free |
| `public_catalog_item(id)` | `GET /v1/public-catalog/{id}` | no | free |
| `compare_public_catalog(ids)` | `POST /v1/public-catalog/compare` | no | free |
| `search(q, capability:, prefer:, max_price_micros:, keyless:, limit:, offset:, ...)` | `GET /v1/catalog/search` | `catalog.read` | free |
| `inspect_endpoint(endpoint_id)` | `GET /v1/operations/{endpointId}` | yes | free |
| `discover(query)` | `GET /v1/discover` | `catalog.read` | free |
| `catalog_endpoints(cursor:, facets:, ...)` | `GET /v1/catalog/endpoints` | `catalog.read` | free |
| `run(endpoint_id, input, wait:, fallback:, idempotency_key:, output:)` | `POST /v1/runs` | `runs.execute` | paid |
| `run_job(job, input, prefer:, fallback:, wait:, idempotency_key:, output:)` | `POST /v1/runs` with `job:<id>` | `runs.execute` | paid |
| `get_run(run_id, fields:, max_items:)` | `GET /v1/runs/{runId}` | `runs.read` | free |
| `list_runs(status:, capability:, limit:, cursor:, include_result:)` | `GET /v1/runs` | `runs.read` | free |
| `cancel_run(run_id)` | `POST /v1/runs/{runId}/cancel` | `runs.execute` | free |
| `run_attempts(run_id)` | `GET /v1/runs/{runId}/attempts` | `runs.read` | free |
| `wait_for_run(run_id, timeout:)` | polls `GET /v1/runs/{runId}` | `runs.read` | free |
| `balance` | `GET /v1/balance` | `usage.read` | free |
| `list_top_ups` | `GET /v1/top-ups` | `usage.read` | free |
| `ledger(limit:, cursor:)` | `GET /v1/ledger` | `usage.read` | free |
| `whoami` | `GET /v1/whoami` | `organizations.read` | free |
| `capability_request(title:, description:, ...)` | `POST /v1/capability-requests` | yes | free |
| `download_media(run)` | `GET <result.media.downloadPath>` | yes | free |

`inspect_endpoint` is the contract's `inspect`. Ruby already uses `inspect` on every object, so the
SDK names it `inspect_endpoint` (alias `operation`).

`each_run`, `each_public_catalog_item` and `each_search_result` return an Enumerator that follows
`nextCursor` or `nextOffset` until the last page.

Argument names are snake_case in Ruby and camelCase on the wire: `max_price_micros:` sends
`maxPriceMicros`. Fallback hashes are converted the same way: `{ max_attempts: 2, max_cost_usd: 0.05 }`
sends `{ "maxAttempts": 2, "maxCostUsd": 0.05 }`.

## Responses

Every method returns a model with readers for the documented fields (`run.status`,
`run.route.attempts`, `balance.top_up_link.dashboard_url`). The gateway adds fields over time, so
every other key stays reachable with `run["someKey"]`, `run.dig(...)` and `run.to_h`.

## A failed run is not an exception

`run` and `run_job` return the run even when it failed. Read `status`, `outcome` and `error`:

```ruby
run = looot.run_job("people.email.verify", { email: "jane.doe@example.com" }, prefer: "cheapest", wait: 20)
case run.status
when "completed" then puts run.outcome # "hit", "weak" or "miss". A miss is a normal answer.
when "failed", "blocked" then puts run.error.retry_hint
else run = looot.wait_for_run(run.run_id)
end
```

`run.error.retryable?` means a new run with a new idempotency key may succeed. The same key only
replays the settled failure.

## Errors

Every non-2xx answer raises `Looot::LoootError` (also `Looot::Error`):

```ruby
begin
  looot.run_job("people.email.find", input, fallback: true)
rescue Looot::LoootError => e
  e.status      # 402
  e.code        # "insufficient_balance"
  e.request_id  # "req_..."
  e.retryable?  # false
  e.retry_hint  # set when the gateway sends one
  e.checkout_url || e.dashboard_url # where to add credits, on a 402
end
```

A token route called with no token raises `code: "missing_token"` and sends nothing. A timeout or
a connection failure raises with `status: 0` and `code: "timeout"` or `"network_error"`.

After a 402, add credits and run again with a new idempotency key.

## Tests

```sh
bundle install
bundle exec rspec
```

Tests mock HTTP with WebMock and never call a paid route. `LOOOT_LIVE=1 bundle exec rspec spec/live_spec.rb`
reads two free public routes.

## Links

- Docs: [docs.looot.ai](https://docs.looot.ai)
- API reference: [docs.looot.ai/reference](https://docs.looot.ai/reference)
- Run errors: [docs.looot.ai/errors/run-errors](https://docs.looot.ai/errors/run-errors)
- Other SDKs: [looot-js](https://github.com/loootai/looot-js), [looot-python](https://github.com/loootai/looot-python)

## License

MIT

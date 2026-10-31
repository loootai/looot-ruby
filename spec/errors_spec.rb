# frozen_string_literal: true

RSpec.describe "errors and retries" do
  base = SpecHelpers::BASE

  it "a 402 becomes LoootError with status, code, requestId and typed topUp" do
    stub_request(:post, "#{base}/v1/runs").to_return(json({
                                                            "error" => { "code" => "insufficient_balance", "message" => "Add credits to run this.", "requestId" => "req_1" },
                                                            "topUp" => { "checkoutUrl" => "https://checkout.stripe.com/c/x", "dashboardUrl" => "https://looot.ai/usage?top_up=1" }
                                                          }, status: 402))
    expect { client.run_job("people.email.find", { firstName: "Jane" }) }.to raise_error(Looot::LoootError) { |error|
      expect(error.status).to eq(402)
      expect(error.code).to eq("insufficient_balance")
      expect(error.request_id).to eq("req_1")
      expect(error.message).to eq("Add credits to run this.")
      expect(error).not_to be_retryable
      expect(error.checkout_url).to eq("https://checkout.stripe.com/c/x")
      expect(error.dashboard_url).to eq("https://looot.ai/usage?top_up=1")
      expect(error.body["error"]["code"]).to eq("insufficient_balance")
    }
    expect(WebMock).to have_requested(:post, "#{base}/v1/runs").once
  end

  it "falls back to http_<status>, a built message and the x-request-id header" do
    stub_request(:get, "#{base}/v1/balance").to_return(status: 502, body: "<html>bad gateway</html>",
                                                      headers: { "x-request-id" => "req_hdr" })
    expect { client.balance }.to raise_error(Looot::LoootError) { |error|
      expect(error.status).to eq(502)
      expect(error.code).to eq("http_502")
      expect(error.message).to eq("GET /v1/balance failed with HTTP 502")
      expect(error.request_id).to eq("req_hdr")
      expect(error.body).to eq("<html>bad gateway</html>")
    }
  end

  it "reads retryable and retryHint from the body when present" do
    stub_request(:get, "#{base}/v1/balance").to_return(json({ "error" => { "code" => "forbidden", "message" => "no", "requestId" => "r",
                                                                         "retryable" => false, "retryHint" => "Add the usage.read scope." } },
                                                           status: 403))
    expect { client.balance }.to raise_error(Looot::LoootError) { |error|
      expect(error.retry_hint).to eq("Add the usage.read scope.")
      expect(error).not_to be_retryable
    }
  end

  it "does not retry a 4xx other than 429" do
    stub_request(:post, "#{base}/v1/runs").to_return(json({ "error" => { "code" => "idempotency_conflict", "message" => "m" } }, status: 409))
    expect { client.run("x", {}, idempotency_key: "k") }.to raise_error(Looot::LoootError, "m")
    expect(WebMock).to have_requested(:post, "#{base}/v1/runs").once
  end

  it "retries a 429 with the same idempotency key, waiting retry-after" do
    keys = []
    stub_request(:post, "#{base}/v1/runs").to_return(
      lambda { |req|
        keys << body_of(req)["idempotencyKey"]
        json({ "error" => { "code" => "too_many_inflight_runs", "message" => "slow down" } }, status: 429, headers: { "Retry-After" => "3" })
      },
      lambda { |req|
        keys << body_of(req)["idempotencyKey"]
        json({ "runId" => "run_1", "status" => "queued" }, status: 201)
      }
    )
    waits = []
    looot = Looot::Client.new(token: "t", sleeper: ->(s) { waits << s })
    expect(looot.run("x", {}).status).to eq("queued")
    expect(keys.size).to eq(2)
    expect(keys.uniq.size).to eq(1)
    expect(waits).to eq([3.0])
  end

  it "caps the wait at 30 s and gives up after max_retries" do
    stub_request(:get, "#{base}/v1/balance").to_return(json({ "error" => { "code" => "catalog_loading", "message" => "loading" },
                                                             "retryAfterSeconds" => 120 }, status: 503))
    waits = []
    looot = Looot::Client.new(token: "t", sleeper: ->(s) { waits << s })
    expect { looot.balance }.to raise_error(Looot::LoootError) { |e|
      expect(e.code).to eq("catalog_loading")
      expect(e.retry_after_seconds).to eq(120)
      expect(e).to be_retryable
    }
    expect(waits).to eq([30, 30])
    expect(WebMock).to have_requested(:get, "#{base}/v1/balance").times(3)
  end

  it "does not retry 503 billing_unavailable or a 500" do
    stub_request(:get, "#{base}/v1/balance").to_return(json({ "error" => { "code" => "billing_unavailable", "message" => "x" } }, status: 503))
    expect { client.balance }.to raise_error(Looot::LoootError) { |e| expect(e).not_to be_retryable }
    stub_request(:get, "#{base}/v1/ledger").to_return(json({ "error" => { "code" => "internal_error", "message" => "x" } }, status: 500))
    expect { client.ledger }.to raise_error(Looot::LoootError) { |e| expect(e).to be_retryable }
    expect(WebMock).to have_requested(:get, "#{base}/v1/balance").once
    expect(WebMock).to have_requested(:get, "#{base}/v1/ledger").once
  end

  it "max_retries: 0 turns retries off" do
    stub_request(:get, "#{base}/v1/balance").to_return(json({ "error" => { "code" => "rate_limit_exceeded", "message" => "x" } }, status: 429))
    expect { client(max_retries: 0).balance }.to raise_error(Looot::LoootError) { |e| expect(e.code).to eq("rate_limit_exceeded") }
    expect(WebMock).to have_requested(:get, "#{base}/v1/balance").once
  end

  it "a timeout becomes LoootError status 0 code timeout, retried then raised" do
    stub_request(:get, "#{base}/v1/balance").to_timeout
    expect { client.balance }.to raise_error(Looot::LoootError) { |e|
      expect(e.status).to eq(0)
      expect(e.code).to eq("timeout")
      expect(e).to be_retryable
    }
    expect(WebMock).to have_requested(:get, "#{base}/v1/balance").times(3)
  end

  it "a connection failure becomes code network_error and can recover" do
    stub_request(:get, "#{base}/v1/balance").to_raise(SocketError.new("getaddrinfo failed")).then.to_return(json({ "available" => 7 }))
    expect(client.balance.available).to eq(7)
    stub_request(:get, "#{base}/v1/whoami").to_raise(Errno::ECONNREFUSED)
    expect { client(max_retries: 0).whoami }.to raise_error(Looot::LoootError) { |e| expect(e.code).to eq("network_error") }
  end

  it "never puts the token in an error message or inspect" do
    stub_request(:get, "#{base}/v1/balance").to_return(json({ "error" => { "code" => "unauthorized", "message" => "bad token" } }, status: 401))
    expect { client.balance }.to raise_error(Looot::LoootError) { |e|
      expect(e.message).not_to include(SpecHelpers::TOKEN)
      expect(e.inspect).not_to include(SpecHelpers::TOKEN)
      expect(e.to_h.values.join).not_to include(SpecHelpers::TOKEN)
    }
  end

  it "Looot::Error is the same class" do
    expect(Looot::Error).to be(Looot::LoootError)
  end
end

RSpec.describe Looot::Model do
  it "accepts unknown status values without crashing" do
    run = Looot::Run.new({ "status" => "brand_new_status" })
    expect(run.status).to eq("brand_new_status")
    expect(run).not_to be_terminal
    expect(run).not_to be_success
  end

  it "treats reconciliation_pending as terminal for polling" do
    expect(Looot::Run.new({ "status" => "reconciliation_pending" })).to be_terminal
  end

  it "normalized is nil when absent" do
    expect(Looot::Run.new({ "status" => "completed" }).normalized).to be_nil
  end

  it "compares by data" do
    expect(Looot::Run.new({ "a" => 1 })).to eq(Looot::Run.new({ "a" => 1 }))
  end
end

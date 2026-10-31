# frozen_string_literal: true

require "json"
require "webmock/rspec"
require "looot"

# Tests never touch the network. The live spec opts back in with LOOOT_LIVE=1.
WebMock.disable_net_connect!

module SpecHelpers
  BASE = "https://api.looot.ai"
  # A fake token for tests. It has no real format on purpose.
  TOKEN = "test-token-not-real"

  def client(**options)
    Looot::Client.new(token: TOKEN, sleeper: ->(_seconds) {}, **options)
  end

  def json(body, status: 200, headers: {})
    { status: status, body: JSON.generate(body), headers: { "Content-Type" => "application/json" }.merge(headers) }
  end

  def body_of(request)
    JSON.parse(request.body)
  end
end

RSpec.configure do |config|
  config.include SpecHelpers
  config.disable_monkey_patching!
  config.order = :random
  config.around do |example|
    saved = ENV.to_h.slice("LOOOT_TOKEN", "LOOOT_API_KEY")
    ENV.delete("LOOOT_TOKEN")
    ENV.delete("LOOOT_API_KEY")
    example.run
  ensure
    ENV.delete("LOOOT_TOKEN")
    ENV.delete("LOOOT_API_KEY")
    saved.each { |key, value| ENV[key] = value }
  end
end

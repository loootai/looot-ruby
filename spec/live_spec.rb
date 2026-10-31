# frozen_string_literal: true

# Opt-in live checks against the free public routes only. Never a paid route.
#   LOOOT_LIVE=1 bundle exec rspec spec/live_spec.rb
RSpec.describe "live free routes", if: ENV["LOOOT_LIVE"] == "1" do
  before { WebMock.allow_net_connect! }
  after { WebMock.disable_net_connect! }

  it "reads the catalog overview" do
    overview = Looot::Client.new(token: "").catalog_overview(topic: "email")
    expect(overview.jobs).not_to be_empty
  end

  it "reads one page of the public catalog" do
    page = Looot::Client.new(token: "").public_catalog(capability: "people_email_verify", limit: 1)
    expect(page.items.size).to be <= 1
  end
end

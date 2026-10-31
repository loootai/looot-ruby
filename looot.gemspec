# frozen_string_literal: true

require_relative "lib/looot/version"

Gem::Specification.new do |spec|
  spec.name = "looot"
  spec.version = Looot::VERSION
  spec.authors = ["looot"]
  spec.summary = "Official Ruby SDK for looot: search, price and run data jobs across many providers from one API."
  spec.description = "Ruby client for the looot REST API. Search the catalog, inspect an endpoint, run a job " \
                     "with fallback, read runs and check the balance. No runtime dependencies."
  spec.homepage = "https://looot.ai"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata = {
    "homepage_uri" => "https://looot.ai",
    "source_code_uri" => "https://github.com/loootai/looot-ruby",
    "changelog_uri" => "https://github.com/loootai/looot-ruby/blob/main/CHANGELOG.md",
    "documentation_uri" => "https://docs.looot.ai",
    "bug_tracker_uri" => "https://github.com/loootai/looot-ruby/issues",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir["lib/**/*.rb", "sig/**/*.rbs", "README.md", "CHANGELOG.md", "LICENSE"]
  spec.require_paths = ["lib"]
end

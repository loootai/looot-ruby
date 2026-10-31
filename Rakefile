# frozen_string_literal: true

# bundler/gem_tasks adds build and release. The release workflow runs `rake release`
# through rubygems/release-gem, so this line must stay.
require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)
task default: :spec

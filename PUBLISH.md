# Publishing looot to RubyGems.org

The release workflow (`.github/workflows/release.yml`) publishes with RubyGems trusted publishing.
GitHub Actions gets a short-lived token over OIDC, so no RubyGems API key lives in this repo.

The gem name `looot` was free on RubyGems.org on 2026-10-31 (`GET /api/v1/gems/looot.json` answered 404).

## One-time setup (Walid)

1. Sign in or sign up at https://rubygems.org with the looot account and turn on MFA.
2. Go to https://rubygems.org/profile/oidc/pending_trusted_publishers/new and add a pending trusted publisher:
   - Gem name: `looot`
   - Repository owner: `loootai`
   - Repository name: `looot-ruby`
   - Workflow filename: `release.yml`
   - Environment: `release`
   A pending publisher reserves the setup for a gem that does not exist yet. The first publish
   creates the gem and turns it into a normal trusted publisher.
3. In GitHub, open loootai/looot-ruby, Settings, Environments, and create an environment named
   `release`. Optional: add yourself as a required reviewer so every publish waits for your click.
4. GitHub Actions must be on for the repo (Settings, Actions, General).

## Each release

1. Set the version in `lib/looot/version.rb` and move the CHANGELOG entry out of "unreleased".
2. Commit to `main`, then tag and push:

   ```sh
   git tag v0.1.0
   git push origin v0.1.0
   ```

3. The workflow checks the tag matches `Looot::VERSION`, runs the tests, then `rubygems/release-gem`
   runs `bundle exec rake release`. That task comes from `require "bundler/gem_tasks"` in the
   Rakefile. It builds the gem into `pkg/`, skips the git push because the tag already exists, and
   pushes the gem. Check https://rubygems.org/gems/looot afterwards.

## If trusted publishing is not set up

The workflow fails at the "Configure trusted publishing credentials" step and nothing is published. Fix the publisher settings in step 2
(the workflow filename and environment must match exactly) and re-run the job.

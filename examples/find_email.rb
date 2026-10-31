# frozen_string_literal: true

# Finds a work email with the people.email.find job. Paid: it spends credits.
#   LOOOT_TOKEN=... ruby -Ilib examples/find_email.rb Jane Doe example.com
require "looot"

first, last, domain = ARGV
abort "usage: find_email.rb FIRST LAST DOMAIN" unless domain

looot = Looot::Client.new(agent: "looot-ruby example")
balance = looot.balance
abort "Add credits first: #{balance.top_up_link.url}" unless balance.available.to_f.positive?

run = looot.run_job("people.email.find", { firstName: first, lastName: last, domain: domain },
                    fallback: true, wait: 20, idempotency_key: "example-#{first}-#{last}-#{domain}".downcase)
run = looot.wait_for_run(run.run_id) unless run.terminal?

if run.success?
  puts "#{run.outcome}: #{run.result.inspect}"
else
  puts "#{run.status}: #{run.error&.code} #{run.error&.retry_hint}"
end
puts "charged $#{run.actual_cost}"

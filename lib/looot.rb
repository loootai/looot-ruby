# frozen_string_literal: true

require_relative "looot/version"
require_relative "looot/error"
require_relative "looot/models"
require_relative "looot/transport"
require_relative "looot/client"

# Official Ruby SDK for looot (https://looot.ai). Start with Looot::Client.new.
module Looot
  # Shortcut for Looot::Client.new(**options).
  def self.new(**options)
    Client.new(**options)
  end
end

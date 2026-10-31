# frozen_string_literal: true

require "net/http"
require "openssl"
require "uri"

module Looot
  # What a transport returns. Header names are lowercase.
  Response = Struct.new(:status, :headers, :body, keyword_init: true)

  # Raised by a transport when the request never got an HTTP answer.
  class TransportError < StandardError
    attr_reader :kind

    def initialize(message, kind:)
      super(message)
      @kind = kind
    end
  end

  # The default transport, over Net::HTTP from the standard library.
  #
  # Any object with `call(method:, url:, headers:, body:, timeout:)` that returns a
  # Looot::Response can replace it (pass `transport:` to Looot::Client.new).
  class NetHttpTransport
    TIMEOUT_ERRORS = [Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, Timeout::Error].freeze
    NETWORK_ERRORS = [SocketError, IOError, EOFError, SystemCallError, OpenSSL::SSL::SSLError].freeze

    def call(method:, url:, headers:, body:, timeout:)
      uri = URI.parse(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = timeout
      http.read_timeout = timeout
      http.write_timeout = timeout
      request = build_request(method, uri, headers, body)
      response = http.start { |conn| conn.request(request) }
      Response.new(status: response.code.to_i, headers: lowercase_headers(response), body: response.body.to_s)
    rescue *TIMEOUT_ERRORS => e
      raise TransportError.new("#{method} #{uri&.path} timed out after #{timeout}s (#{e.class})", kind: :timeout)
    rescue *NETWORK_ERRORS => e
      raise TransportError.new("#{method} #{uri&.path} could not reach the server (#{e.class}: #{e.message})", kind: :network)
    end

    private

    def build_request(method, uri, headers, body)
      klass = case method
              when "GET" then Net::HTTP::Get
              when "POST" then Net::HTTP::Post
              else raise ArgumentError, "unsupported method #{method}"
              end
      request = klass.new(uri.request_uri)
      # Net::HTTP adds its own Accept-Encoding and User-Agent unless we set them.
      headers.each { |name, value| request[name] = value }
      request.body = body if body
      request
    end

    def lowercase_headers(response)
      response.each_header.to_h { |name, value| [name.downcase, value] }
    end
  end
end

# frozen_string_literal: true

# Point the app at an isolated Redis database *before* it's required, so the
# lazily-built connection uses the test DB. Defaults to db 15 on localhost;
# override with REDIS_URL (CI points this at the `redis` service).
ENV["REDIS_URL"] ||= "redis://localhost:6379/15"
ENV["RACK_ENV"] = "test"

require "rspec"
require "rack/test"
require "redis"

require_relative "../app"
require_relative "../lib/rate_limiter"

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.order = :defined

  # Start every example from an empty window.
  config.before(:each) do
    redis = Redis.new(url: ENV.fetch("REDIS_URL"))
    redis.flushdb
    redis.close
  end
end

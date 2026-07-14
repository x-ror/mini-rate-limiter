# frozen_string_literal: true

require "sinatra/base"
require "json"
require "redis"

require_relative "lib/rate_limiter"

# HTTP surface for the rate limiter. Kept thin on purpose: parse the request,
# delegate to RateLimiter, shape a JSON response.
class App < Sinatra::Base
  configure do
    set :show_exceptions, false
    set :raise_errors, false
    disable :dump_errors
  end

  # A single shared Redis connection / limiter per process. Both are built
  # lazily so the app boots even if Redis isn't reachable yet (e.g. during
  # container start-up) and only fails when a request actually needs it.
  class << self
    def redis
      @redis ||= Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0"))
    end

    def limiter
      @limiter ||= RateLimiter.new(
        redis: redis,
        limit: Integer(ENV.fetch("RATE_LIMIT", "60")),
        window_ms: Integer(ENV.fetch("RATE_WINDOW_MS", "60000"))
      )
    end
  end

  helpers do
    def json(code, payload)
      status code
      content_type :json
      JSON.generate(payload)
    end

    # Prefer the explicit header; also accept a bearer token as a convenience.
    def request_token
      header = request.env["HTTP_X_API_TOKEN"]
      return header unless header.nil? || header.empty?

      auth = request.env["HTTP_AUTHORIZATION"]
      auth&.sub(/\ABearer\s+/i, "")
    end
  end

  # Liveness/readiness probe. Reports Redis connectivity too, since the service
  # is useless without it.
  get "/health" do
    redis_ok =
      begin
        self.class.redis.ping == "PONG"
      rescue StandardError
        false
      end

    json(redis_ok ? 200 : 503, status: redis_ok ? "ok" : "degraded", redis: redis_ok)
  end

  # Record a request for the caller's token.
  post "/track" do
    token = request_token
    if token.nil? || token.empty?
      halt json(400,
        error: "missing_token",
        message: "Provide an API token via the X-Api-Token header.")
    end

    result = self.class.limiter.track(token)

    if result.allowed
      json(200,
        token: token,
        count: result.count,
        limit: result.limit,
        remaining: result.remaining)
    else
      headers "Retry-After" => result.retry_after.to_s
      json(429,
        error: "rate_limit_exceeded",
        message: "Rate limit of #{result.limit} requests per minute exceeded.",
        limit: result.limit,
        count: result.count,
        remaining: 0,
        retry_after: result.retry_after)
    end
  end

  # Report the current window for a token without recording a request.
  get "/stats/:token" do
    result = self.class.limiter.stats(params["token"])
    json(200,
      token: params["token"],
      count: result.count,
      limit: result.limit,
      remaining: result.remaining)
  end

  # If Redis is unreachable mid-request, fail clearly rather than 500-ing.
  error Redis::BaseError do
    json(503,
      error: "storage_unavailable",
      message: "The rate-limit store is temporarily unavailable.")
  end

  error do
    json(500, error: "internal_error", message: "Something went wrong.")
  end
end

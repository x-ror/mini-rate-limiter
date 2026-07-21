# frozen_string_literal: true

require "securerandom"

# Sliding-window rate limiter backed by Redis.
#
# Each token gets its own Redis sorted set (ZSET). Every recorded request is a
# member of that set, scored by the timestamp (in milliseconds) at which it
# happened. On each call we:
#
#   1. drop members older than `window_ms` (they've slid out of the window),
#   2. count what's left,
#   3. record the new request only if we're still under the limit.
#
# Steps 1-3 run inside a single Lua script so the whole "check and record" is
# atomic — two concurrent requests for the same token can't both read a count
# of 59 and each decide they're allowed. That race is the classic bug in a
# naive ZCARD-then-ZADD implementation, and Redis executes a script without
# interleaving other commands, which closes it.
#
# Thread-safety: a single Redis client is not safe to share across Puma
# threads (concurrent use corrupts the socket protocol). Pass either a raw
# Redis client (tests / single-threaded use) or a ConnectionPool of clients
# (production under Puma). Multi-command work always runs while holding one
# checked-out connection.
class RateLimiter
  # Value object returned by #track and #stats.
  Result = Struct.new(:allowed, :count, :limit, :retry_after, keyword_init: true) do
    # Requests still available in the current window (never negative).
    def remaining
      [limit - count, 0].max
    end
  end

  # KEYS[1] = the token's ZSET key
  # ARGV[1] = now (ms), ARGV[2] = window (ms), ARGV[3] = limit, ARGV[4] = member
  # Returns { allowed (1/0), count, retry_after_ms }
  TRACK_SCRIPT = <<~LUA
    local key    = KEYS[1]
    local now    = tonumber(ARGV[1])
    local window = tonumber(ARGV[2])
    local limit  = tonumber(ARGV[3])
    local member = ARGV[4]

    -- Evict everything older than the sliding window.
    redis.call('ZREMRANGEBYSCORE', key, 0, now - window)

    local count = redis.call('ZCARD', key)

    if count < limit then
      redis.call('ZADD', key, now, member)
      -- Let the key expire on its own once the window has fully passed.
      redis.call('PEXPIRE', key, window)
      return { 1, count + 1, 0 }
    end

    -- Over the limit: the client can retry once the oldest request in the
    -- window slides out, i.e. at (oldest_score + window).
    local oldest = redis.call('ZRANGE', key, 0, 0, 'WITHSCORES')
    local retry_after = window
    if oldest[2] then
      retry_after = (tonumber(oldest[2]) + window) - now
      if retry_after < 0 then retry_after = 0 end
    end
    redis.call('PEXPIRE', key, window)
    return { 0, count, retry_after }
  LUA

  # `redis` may be a Redis client or a ConnectionPool. Both implement #with
  # (redis-rb yields itself; ConnectionPool checks out a dedicated socket),
  # so the same call path is safe under Puma's multi-threaded mode.
  def initialize(redis:, limit: 60, window_ms: 60_000, namespace: "ratelimit")
    @redis = redis
    @limit = limit
    @window_ms = window_ms
    @namespace = namespace
  end

  # Record a request for `token` and report whether it was allowed.
  def track(token)
    now = now_ms
    member = "#{now}-#{SecureRandom.hex(6)}"

    allowed, count, retry_after_ms = @redis.with do |conn|
      conn.eval(
        TRACK_SCRIPT,
        keys: [key_for(token)],
        argv: [now, @window_ms, @limit, member]
      )
    end

    Result.new(
      allowed: allowed == 1,
      count: count,
      limit: @limit,
      retry_after: allowed == 1 ? nil : ms_to_retry_seconds(retry_after_ms)
    )
  end

  # Read-only snapshot of the current window for `token`. Does not record a
  # request. Trims expired members first so the count is accurate.
  def stats(token)
    key = key_for(token)
    results = @redis.with do |conn|
      conn.multi do |t|
        t.zremrangebyscore(key, 0, now_ms - @window_ms)
        t.zcard(key)
      end
    end

    Result.new(allowed: nil, count: results.last, limit: @limit, retry_after: nil)
  end

  private

  def key_for(token)
    "#{@namespace}:#{token}"
  end

  def now_ms
    (Time.now.to_f * 1000).to_i
  end

  # HTTP's Retry-After is expressed in whole seconds; round up so we never tell
  # a client to retry before the window has actually freed a slot, and never
  # return 0 for a rejected request.
  def ms_to_retry_seconds(ms)
    [(ms / 1000.0).ceil, 1].max
  end
end

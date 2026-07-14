# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe RateLimiter do
  let(:redis) { Redis.new(url: ENV.fetch("REDIS_URL")) }
  let(:token) { "unit-token" }

  after { redis.close }

  describe "#track — the 60/61 boundary" do
    subject(:limiter) { described_class.new(redis: redis, limit: 60, window_ms: 60_000) }

    it "counts up and stays allowed for the first 60 requests" do
      results = Array.new(60) { limiter.track(token) }

      expect(results.map(&:count)).to eq((1..60).to_a)
      expect(results).to all(have_attributes(allowed: true))
      expect(results.last.remaining).to eq(0)
      expect(results.last.retry_after).to be_nil
    end

    it "rejects the 61st request in the same window" do
      60.times { limiter.track(token) }

      rejected = limiter.track(token)

      expect(rejected.allowed).to be(false)
      expect(rejected.count).to eq(60)        # count is not incremented past the limit
      expect(rejected.remaining).to eq(0)
      expect(rejected.retry_after).to be_a(Integer).and be > 0
    end

    it "keeps rejecting while the window is full but never over-counts" do
      60.times { limiter.track(token) }

      5.times do
        r = limiter.track(token)
        expect(r.allowed).to be(false)
        expect(r.count).to eq(60)
      end
    end

    it "isolates counts per token" do
      60.times { limiter.track("token-a") }

      other = limiter.track("token-b")
      expect(other.allowed).to be(true)
      expect(other.count).to eq(1)
    end
  end

  describe "#track — sliding window" do
    # Tiny window so the test doesn't have to wait a real minute.
    subject(:limiter) { described_class.new(redis: redis, limit: 3, window_ms: 200) }

    it "frees capacity once old requests slide out of the window" do
      3.times { limiter.track(token) }
      expect(limiter.track(token).allowed).to be(false)

      sleep 0.25 # let the whole 200ms window pass

      allowed = limiter.track(token)
      expect(allowed.allowed).to be(true)
      expect(allowed.count).to eq(1)
    end
  end

  describe "#stats" do
    subject(:limiter) { described_class.new(redis: redis, limit: 60, window_ms: 60_000) }

    it "reports count and remaining without recording a request" do
      10.times { limiter.track(token) }

      first = limiter.stats(token)
      expect(first.count).to eq(10)
      expect(first.remaining).to eq(50)

      # Calling stats again must not have changed the count.
      expect(limiter.stats(token).count).to eq(10)
    end

    it "reports a full quota for an unseen token" do
      stats = limiter.stats("never-seen")
      expect(stats.count).to eq(0)
      expect(stats.remaining).to eq(60)
    end
  end
end

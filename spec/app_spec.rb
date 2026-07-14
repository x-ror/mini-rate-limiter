# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe App do
  include Rack::Test::Methods

  def app
    App
  end

  def track(token)
    header "X-Api-Token", token
    post "/track"
  end

  describe "GET /health" do
    it "reports ok when Redis is reachable" do
      get "/health"
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)).to include("status" => "ok", "redis" => true)
    end
  end

  describe "POST /track" do
    it "requires a token" do
      post "/track"
      expect(last_response.status).to eq(400)
      expect(JSON.parse(last_response.body)["error"]).to eq("missing_token")
    end

    it "returns 200 with the running count within the limit" do
      track("api-token")
      expect(last_response.status).to eq(200)

      body = JSON.parse(last_response.body)
      expect(body).to include("count" => 1, "limit" => 60, "remaining" => 59)
    end

    it "allows the 60th request and rejects the 61st" do
      59.times { track("api-token") }

      # 60th — still allowed, quota exhausted.
      track("api-token")
      expect(last_response.status).to eq(200)
      sixtieth = JSON.parse(last_response.body)
      expect(sixtieth["count"]).to eq(60)
      expect(sixtieth["remaining"]).to eq(0)

      # 61st — rejected.
      track("api-token")
      expect(last_response.status).to eq(429)
      expect(last_response.headers["Retry-After"]).to match(/\A\d+\z/)
      expect(last_response.headers["Retry-After"].to_i).to be > 0

      body = JSON.parse(last_response.body)
      expect(body["error"]).to eq("rate_limit_exceeded")
      expect(body["remaining"]).to eq(0)
      expect(body["retry_after"]).to be > 0
    end
  end

  describe "GET /stats/:token" do
    it "returns the current count and remaining quota" do
      3.times { track("stats-token") }

      get "/stats/stats-token"
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)).to include(
        "token" => "stats-token", "count" => 3, "limit" => 60, "remaining" => 57
      )
    end

    it "does not record a request of its own" do
      track("stats-token")
      get "/stats/stats-token"
      get "/stats/stats-token"
      expect(JSON.parse(last_response.body)["count"]).to eq(1)
    end
  end
end

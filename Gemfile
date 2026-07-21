# frozen_string_literal: true

source "https://rubygems.org"

gem "sinatra", "~> 4.1"         # HTTP routing
gem "puma", "~> 6.4"            # app server (multi-threaded)
gem "redis", "~> 5.3"           # counter storage
gem "connection_pool", "~> 3.0" # one Redis socket per Puma thread
gem "rackup", "~> 2.2"          # `run` DSL / rackup CLI for Rack 3

group :development, :test do
  gem "rspec", "~> 3.13"
  gem "rack-test", "~> 2.1"
end

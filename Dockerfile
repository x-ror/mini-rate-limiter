FROM ruby:4.0-slim

ENV BUNDLE_WITHOUT="development:test" \
    BUNDLE_FROZEN="true" \
    RACK_ENV="production"

WORKDIR /app

# Install gems first so this layer is cached across source-only changes.
# build-essential is only needed to compile native gems (puma); purge it
# afterwards to keep the runtime image small.
COPY Gemfile Gemfile.lock ./
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential \
 && gem install bundler \
 && bundle install \
 && apt-get purge -y --auto-remove build-essential \
 && rm -rf /var/lib/apt/lists/*

COPY . .

EXPOSE 4567

# Healthcheck using only the Ruby stdlib (no curl/wget in the slim image).
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=5 \
  CMD ruby -e "require 'net/http'; exit(Net::HTTP.get_response(URI('http://127.0.0.1:4567/health')).code == '200' ? 0 : 1)" || exit 1

CMD ["bundle", "exec", "puma", "config.ru", "--bind", "tcp://0.0.0.0:4567"]

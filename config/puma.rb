# frozen_string_literal: true

# Puma is multi-threaded by default. Redis clients are *not* thread-safe, so
# App.redis_pool is sized to PUMA_MAX_THREADS (see app.rb). Keep these in sync:
# if you raise max threads without raising REDIS_POOL_SIZE, requests will queue
# (or time out) waiting for a free Redis socket.

max_threads = Integer(ENV.fetch("PUMA_MAX_THREADS", "5"))
min_threads = Integer(ENV.fetch("PUMA_MIN_THREADS", max_threads.to_s))

threads min_threads, max_threads

port ENV.fetch("PORT", "4567")
environment ENV.fetch("RACK_ENV", "production")

# Single process is enough for this service; scale out with more containers
# rather than workers (each worker would need its own Redis pool anyway).
workers Integer(ENV.fetch("WEB_CONCURRENCY", "0"))

# Allow long enough for Redis pool checkout under brief contention.
worker_timeout Integer(ENV.fetch("PUMA_WORKER_TIMEOUT", "60"))

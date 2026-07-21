# Mini Rate-Limited Request Tracker

A small HTTP service that tracks and rate-limits incoming requests per API token,
backed by Redis and fronted by an nginx reverse proxy. Each token is allowed
**60 requests per minute**; requests over the limit are rejected with `429` and a
`Retry-After` header.

```
client ──▶ nginx (:8080) ──▶ Sinatra app (:4567) ──▶ Redis
             edge proxy         rate-limit logic       counters
```

## Run it

Everything comes up with a single command:

```bash
docker compose up --build
```

That starts three containers — `redis`, the Ruby `app`, and `nginx`. The app is
**only reachable through nginx**, so all requests below go to port `8080`.

```bash
# Record a request (within the limit -> 200)
curl -i -X POST -H "X-Api-Token: my-token" http://localhost:8080/track

# Check a token's current window
curl -s http://localhost:8080/stats/my-token

# Watch it trip the limit (the 61st request in a minute -> 429)
for i in $(seq 1 61); do
  curl -s -o /dev/null -w "%{http_code}\n" -X POST -H "X-Api-Token: my-token" \
    http://localhost:8080/track
done
```

## API

| Method | Path            | Description |
|--------|-----------------|-------------|
| `POST` | `/track`        | Record a request for the token in the `X-Api-Token` header. |
| `GET`  | `/stats/:token` | Current count and remaining quota for a token (read-only). |
| `GET`  | `/health`       | Liveness probe; also reports Redis connectivity. |

**`POST /track`** — token via the `X-Api-Token` header (a `Authorization: Bearer <token>`
header is also accepted).

Within the limit → `200`:
```json
{ "token": "my-token", "count": 12, "limit": 60, "remaining": 48 }
```

Over the limit → `429`, with a `Retry-After` header (seconds):
```json
{ "error": "rate_limit_exceeded", "message": "Rate limit of 60 requests per minute exceeded.",
  "limit": 60, "count": 60, "remaining": 0, "retry_after": 43 }
```

Missing token → `400 { "error": "missing_token", ... }`.

**`GET /stats/:token`** → `200 { "token": "my-token", "count": 12, "limit": 60, "remaining": 48 }`.

## Design decisions

### Sliding window, not fixed window
I chose a **sliding window log** over a fixed window. A fixed window (a per-minute
counter with `INCR` + `EXPIRE`) is simpler, but it allows a burst of up to *2×* the
limit across a window boundary: 60 requests at `12:00:59` and 60 more at `12:01:00`
both pass because they land in different buckets. A sliding window judges each
request against the trailing 60 seconds, so the limit actually holds at any instant.

The data model is one Redis **sorted set (ZSET) per token**. Each request is a member
scored by its timestamp (ms). On every call we:

1. `ZREMRANGEBYSCORE` — drop members older than the window,
2. `ZCARD` — count what remains,
3. `ZADD` — record the new request, but only if we're still under the limit.

`Retry-After` is computed from the oldest request still in the window: the client can
try again at `oldest_timestamp + window`.

### Atomicity via a Lua script
Steps 1–3 above are **one Lua script** (`EVAL`), not three round-trips. If they ran as
separate commands, two concurrent requests for the same token could both read a count
of 59 and both decide they're allowed — letting 61 through. Redis runs a script to
completion without interleaving other commands, which closes that race. This is the
main correctness decision in the project, so the rate-limiter lives in one small,
well-commented class (`lib/rate_limiter.rb`) with the script inline.

### nginx at the edge (the bonus)
nginx does two useful things beyond plain proxying:
- forwards the real client identity via `X-Real-IP` and `X-Forwarded-For` (without
  this the app would only ever see nginx's container IP), and
- adds an `X-Proxied-By: nginx-edge` response header so callers can confirm the
  request actually traversed the proxy.

### Small stuff
- Keys expire (`PEXPIRE window`) so idle tokens don't linger in Redis.
- Redis runs with persistence off — these counters are ephemeral by nature.
- Health, limit, and window are configurable via env (`RATE_LIMIT`,
  `RATE_WINDOW_MS`, `REDIS_URL`), which is also what makes the boundary easy to test.
- **Thread-safe Redis under Puma.** redis-rb clients are not safe to share across
  threads (concurrent use corrupts the socket / RESP stream). The app keeps a
  `ConnectionPool` of Redis clients sized to `PUMA_MAX_THREADS` /
  `REDIS_POOL_SIZE`, and every limiter command runs inside `pool.with` so each
  Puma thread holds a dedicated connection for the duration of the call.

## Tests

The suite (RSpec) runs against a **real Redis** — the same Lua script that runs in
production — so the boundary behaviour is genuinely exercised, not mocked.

- `spec/rate_limiter_spec.rb` — the 60th request passes, the 61st is rejected, the
  count never exceeds the limit, tokens are isolated, and capacity is freed once
  requests slide out of the window.
- `spec/app_spec.rb` — the same boundary over HTTP, plus `Retry-After`, `/stats`,
  `/health`, and the missing-token path.

Run them locally (needs a Redis on `localhost:6379`):

```bash
bundle install
REDIS_URL=redis://localhost:6379/15 bundle exec rspec
```

GitHub Actions (`.github/workflows/ci.yml`) builds the Docker image, then runs the
suite against a Redis service container on every push and pull request.

## Tradeoffs I'd revisit with more time

- **Memory at scale.** A sliding-window *log* stores one ZSET member per request, so a
  hot token costs O(limit) memory. At high request volumes I'd switch to a
  **sliding-window counter** (two adjacent fixed buckets, weighted by overlap) — O(1)
  per token, at the cost of being a small approximation.
- **Per-token limits.** The limit is one global value today. Real API tiers vary per
  client, so I'd load limits from config/DB keyed by token, and treat unknown tokens
  as unauthorized rather than as a fresh bucket.
- **Standard rate-limit headers on every response** (`X-RateLimit-Limit/Remaining/Reset`),
  not just on the `429`.
- **Defense in depth at the edge.** nginx `limit_req` could shed obvious floods before
  they reach Ruby; I left it out to keep a single source of truth for the counting.
- **Leaner image.** A multi-stage Docker build would drop the compiler from the runtime
  image. (CI already caches the bundle via `ruby/setup-ruby`.)
- **Observability.** Counters for allow/deny per token and Redis latency would be the
  first thing I'd want in production.

## Project layout

```
app.rb                 Sinatra app: routing + JSON + Redis connection pool
lib/rate_limiter.rb    Redis sliding-window limiter (the Lua script lives here)
config/puma.rb         Puma threads (keep in sync with REDIS_POOL_SIZE)
config.ru              Rack entrypoint
nginx/nginx.conf       Reverse proxy config
spec/                  RSpec suite (unit + HTTP + multi-thread pool)
Dockerfile             App image
docker-compose.yml     app + redis + nginx
.github/workflows/    GitHub Actions: build image, run tests against a Redis service
```

## AI tools used

Ruby isn't my day-to-day language, so I leaned on **Claude Code** (the agentic CLI) to
move quickly in an unfamiliar stack — scaffolding the Sinatra app, drafting the Lua
script and the Redis data model, and wiring up the Dockerfile, compose file, nginx
config, and RSpec suite. I drove the design decisions (sliding window, atomicity,
what to test) and reviewed everything it produced.

**What it got right and saved me time:** the Redis sorted-set mechanics. The
`ZREMRANGEBYSCORE → ZCARD → ZADD` sequence, computing `Retry-After` from the oldest
member's score, and the `PEXPIRE`-on-idle detail were correct out of the gate — that's
exactly the fiddly, easy-to-get-subtly-wrong part I'd have spent the most time on in a
language I don't write daily. It also got the compose `depends_on: service_healthy`
ordering right so the stack starts cleanly.

**What it got wrong and how I caught it:** the toolchain. My local Ruby is 4.0, and the
generated `Gemfile.lock` carried a bundler version and `CHECKSUMS` section that a
Ruby 3.3 Docker image (my first choice of base image) couldn't consume — the container
build would have failed with a bundler-version error. I caught it by actually reading
the lockfile's `BUNDLED WITH` stanza instead of trusting it, and fixed it by pinning
one Ruby version across dev, Docker, and CI so the lockfile is consistent everywhere.
The lesson that generalizes: the agent is good at the code and weak at the seams
between environments, so those are the parts worth verifying by hand.

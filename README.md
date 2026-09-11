# camada-ruby-example

A Sinatra app wired with [`camada`](../camada-ruby) against a locally running edge-analyst.
This is the hand-test bench for the Ruby SDK, the twin of [`camada-python-example`](../camada-python-example).

## Setup

1. Terminal A — `cd ../camada/edge-analyst && npm run dev` (analyst on :8787), then
   `npm run seed` in a second terminal. Note the printed `CAMADA_KEY`.
2. Here: `cp .env.example .env` (paste the key if it differs), `bundle install`, then
   `bundle exec puma -b tcp://127.0.0.1:3004 config.ru` → http://localhost:3004.
   The Gemfile points `camada` at the sibling checkout `../camada-ruby` (a path gem).

The whole install is one line in `config.ru`: `use Camada::Rack` before `run App`. camada is the
outermost middleware, so it answers (block, challenge, beacon) before Sinatra routes, and stamps
`x-rid` and the `_sfp` cookie on everything Sinatra answers.

**Never `request.ip`.** `Rack::Request#ip` trusts `X-Forwarded-For` from anyone, which is exactly
the spoof camada refuses; the middleware reads `env["REMOTE_ADDR"]` and applies your trusted-proxy
rules (`CAMADA_TRUSTED_PROXY`, or the tenant config) itself. If your app needs the client ip, read
it from `env["camada"]["ip"]` after the middleware ran.

## Hand test (what to look for)

1. Browse `http://localhost:3004` — the page renders; devtools → Network shows
   `/_cam/b.js?r=<uuid>` (200, JavaScript) and ~2 s later `POST /_cam/fp` (204). The document
   response carries an `x-rid` header and sets the `_sfp` cookie.
2. Click/type before the beacon fires — the `/_cam/fp` payload's `input` counters are non-zero.
3. `curl -i http://localhost:3004/ -H 'X-Forwarded-For: 203.0.113.66'` → **403** with
   `x-block-reason: rule` and `x-block-rule: builtin:block` (the seed blocks that IP as an entry
   of the built-in block list on snapshot v5). The very first request after boot answers **200**
   instead — see below.
4. Fail three logins (`demo@example.com` / anything wrong) via `/login-form`, then run an
   analysis (`curl -s -X POST -H 'authorization: Bearer dev' 'http://localhost:8787/admin/run?tenant=acme&minutes=10'`) —
   events include `login_failed` rows with a hashed `uid`; your raw email appears nowhere.
5. Kill the analyst (Ctrl-C in terminal A) and reload the page + `curl localhost:3004/api/data` —
   everything still answers 200; the app's terminal shows at most one
   `[camada] suppressed error` line a minute. That is fail-open.
6. Restart this app with `CAMADA_DISABLED=1` — no `x-rid` header, no `/_cam/b.js` requests:
   the kill switch bypasses the SDK entirely.

## The first request after boot is cold

The middleware builds one engine lazily, on the first request through it. That build starts the
snapshot poll on a thread and never blocks, so the request that triggered it is matched against
an empty snapshot and falls open: a `curl` from the blocked IP right after boot gets `200` with
an `x-rid`, and requests keep passing until that first poll lands — a few hundred milliseconds
against a local analyst (snapshot-size and network bound), then `403`.
`node scripts/e2e-sdk-ruby.mjs` in `../camada/edge-analyst` makes that first request itself
and asserts both answers.

If request 1 must be enforced, warm the engine at boot (in `config.ru`, before `run App`) by
waiting for the boot poll:

```ruby
engine = Camada.default          # builds the engine; the boot poll is already running on its thread
if engine.snap                   # nil when CAMADA_KEY is unset or CAMADA_DISABLED=1
  probe = Camada::Snapshot::MatchInput.new(ip: "0.0.0.0")
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
  while engine.snap.verdict(probe).reason == "cold" && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    sleep 0.01                   # bounded: an unreachable analyst leaves it cold, and the app still fails open
  end
end
```

`snap.refresh` is not the warm-up: the boot poll holds the single-in-flight lock, so a
synchronous `refresh` called right after `Camada.default` returns at once and the engine is
still cold. Under Puma cluster mode the engine is built per worker (or re-armed after the fork
when `preload_app!` built it in the master), so warm it in `on_worker_boot` there.

## Challenge (SDK-04)

`/challenge-me` forces the first-party proof-of-work challenge, whatever the snapshot says — the
same page camada serves automatically for a `challenge` verdict.

1. Browse `http://localhost:3004/challenge-me` — "Checking your browser" appears, the inline
   solver hunts a SHA-256 with 16 leading zero bits (tens of milliseconds), the hidden form
   posts to `/__camada/challenge`, and the browser lands on "Challenge passed". Devtools shows
   the `_cch` cookie (`HttpOnly`, `SameSite=Lax`, one hour); reload and the page renders at once.
2. `curl -i http://localhost:3004/challenge-me -H 'accept: text/html' -H 'sec-fetch-dest: document'`
   → **403** with `x-camada-challenge: 1` and the page in the body.
3. Without an HTML `Accept` (an API client, an image, a fetch) the answer is
   `403 {"error":"challenge_required"}` instead — a status a client can act on rather than a
   page it cannot solve.
4. The events tell the two apart: a served challenge ships `st: 403, blk: "challenge"`, a passed
   one ships `st: 200, ch: 1`.

The nonce and the cookie are bound to the client IP, so camada serves no challenge to a request
it cannot identify (no trusted-proxy config and no socket address). Clear `_cch` — or open a
private window — to see the check again.

## Tests

`bundle exec rubocop && bundle exec rspec` — the routes (through `config.ru` itself) against an
engine whose analyst URL is a closed port (cold, fail open; the challenge needs no snapshot),
plus a guard that `Gemfile.lock` records the sibling SDK's current version (re-run `bundle lock`
after bumping `camada-ruby`).

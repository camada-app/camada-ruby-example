# frozen_string_literal: true

# camada-ruby-example: a small Sinatra app wired with camada against a local edge-analyst.
# Setup: cp .env.example .env (paste the CAMADA_KEY printed by `npm run seed`), bundle install,
# bundle exec puma -b tcp://127.0.0.1:3004 config.ru. The middleware is mounted in config.ru
# (`use Camada::Rack`) — that line is the whole install; the engine builds itself on the first request.
require "json"
require "sinatra/base"
require "camada"

# minimal .env loader so the example has zero extra dependencies
begin
  File.foreach(File.expand_path(".env", __dir__)) do |line|
    m = line.strip.match(/\A([A-Z_]+)=(.*)\z/)
    ENV[m[1]] ||= m[2] if m
  end
rescue SystemCallError
  # no .env: rely on the environment
end

class App < Sinatra::Base
  set :logging, false

  helpers do
    # Every page carries the first-party beacon tag: `env` is the Rack env camada annotated.
    def page(title, body, status = 200)
      halt status, { "content-type" => "text/html; charset=utf-8" }, <<~HTML
        <!doctype html>
        <html><head><meta charset="utf-8"><title>#{title}</title>#{Camada.script_tag(env)}</head>
        <body style="font-family: system-ui; max-width: 40rem; margin: 3rem auto">
        <nav><a href="/">home</a> · <a href="/pricing">pricing</a> · <a href="/login-form">login</a> · <a href="/challenge-me">challenge</a></nav>
        <h1>#{title}</h1>#{body}</body></html>
      HTML
    end
  end

  get "/" do
    page("camada example shop", <<~HTML)
      <p>Every request here is captured by camada; the beacon below fingerprints this browser first-party.</p>
      <p><button onclick="fetch('/api/data').then(r=>r.json()).then(d=>alert(JSON.stringify(d)))">call the API</button></p>
    HTML
  end

  get "/pricing" do
    page("Pricing", "<p>Free while unreleased.</p>")
  end

  get "/login-form" do
    page("Log in", <<~HTML)
      <form method="post" action="/login">
        <input name="user" placeholder="email"> <input name="pass" type="password"> <button>go</button>
      </form>
    HTML
  end

  post "/login" do
    # read the form through Rack (Sinatra's params): a body that is not UTF-8 is scrubbed, not a 500
    user = params["user"].to_s.scrub
    ok = user == "demo@example.com" && params["pass"] == "demo"
    Camada.track(env, ok ? "login_succeeded" : "login_failed", user: user) # uid is HMAC-hashed in the SDK
    page(ok ? "Welcome" : "Nope", "<p>login #{ok ? 'succeeded' : 'failed'}</p>", ok ? 200 : 401)
  end

  get "/api/data" do
    content_type :json
    JSON.generate({ "ok" => true, "at" => (Time.now.to_f * 1000).to_i })
  end

  # SDK-04 demo: force the challenge for this route, whatever the snapshot says. In production
  # the same page is served automatically for a `challenge` verdict. Once solved, the `_cch`
  # cookie is good for an hour and this route renders normally.
  get "/challenge-me" do
    answer = Camada.serve_challenge(env)
    halt(*answer) if answer
    page("Challenge passed", <<~HTML)
      <p>The <code>_cch</code> cookie is set for an hour. Clear it (or open a private window) to see the check again.</p>
    HTML
  end

  not_found do
    page("404", "<p>Nothing here.</p>", 404)
  end
end

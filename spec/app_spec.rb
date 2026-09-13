# frozen_string_literal: true

require "rack/builder"
require "socket"
require "camada"

BLOCKED_IP = "203.0.113.66"
CAMADA_VARS = %w[CAMADA_KEY CAMADA_INGEST_URL CAMADA_SNAPSHOT_URL CAMADA_TRUSTED_PROXY CAMADA_DISABLED].freeze
BROWSER = { "HTTP_X_FORWARDED_FOR" => "198.51.100.7", "HTTP_ACCEPT" => "text/html", "HTTP_SEC_FETCH_DEST" => "document" }.freeze
ROOT = File.expand_path("..", __dir__)

# The example against a configured engine that can never load a snapshot: the analyst URL is a
# closed port, so every request runs cold and falls open, and the routes the app gates itself
# (challenge) still work because the challenge kit needs no snapshot.
RSpec.describe "camada-ruby-example" do
  include Rack::Test::Methods

  def closed_port
    s = TCPServer.new("127.0.0.1", 0)
    port = s.addr[1]
    s.close
    port
  end

  # config.ru is the app under test — `use Camada::Rack; run App` is the lesson.
  def app
    @app ||= Rack::Builder.parse_file(File.join(ROOT, "config.ru"))
  end

  before do
    dead = "http://127.0.0.1:#{closed_port}"
    @saved = ENV.to_h.slice(*CAMADA_VARS)
    ENV["CAMADA_KEY"] = "tok-example.snap-example"
    ENV["CAMADA_INGEST_URL"] = dead
    ENV["CAMADA_SNAPSHOT_URL"] = "#{dead}/snapshot"
    ENV["CAMADA_TRUSTED_PROXY"] = "hops:1"
    ENV.delete("CAMADA_DISABLED")
    Camada.reset! # the lazy first-request build, as in production
  end

  after do
    Camada.reset!
    CAMADA_VARS.each { |k| ENV.delete(k) }
    @saved.each { |k, v| ENV[k] = v }
  end

  it "renders the pages with the first-party beacon" do
    get "/"
    expect(last_response.status).to eq(200)
    expect(last_response.headers["set-cookie"].to_s).to start_with("_sfp=")
    ["/", "/pricing", "/login-form"].each do |path|
      get path
      expect(last_response.status).to eq(200)
      rid = last_response.headers["x-rid"]
      expect(rid).to match(/\A[0-9a-f-]{36}\z/)
      expect(last_response.body).to include("/_cam/b.js?r=#{rid}")
    end
    get "/_cam/b.js"
    expect(last_response.headers["content-type"]).to eq("application/javascript")
  end

  it "answers json from the api" do
    get "/api/data"
    expect(last_response.status).to eq(200)
    expect(JSON.parse(last_response.body)["ok"]).to be(true)
  end

  it "reports the login outcome" do
    post "/login", { "user" => "demo@example.com", "pass" => "nope" }
    expect(last_response.status).to eq(401)
    expect(last_response.body).to include("login failed")
    post "/login", { "user" => "demo@example.com", "pass" => "demo" }
    expect(last_response.status).to eq(200)
    expect(last_response.body).to include("login succeeded")
    # a body that is not UTF-8 is a failed login, not a 500
    post "/login", "user=\xff&pass=x".b, { "CONTENT_TYPE" => "application/x-www-form-urlencoded" }
    expect(last_response.status).to eq(401)
  end

  it "builds its own engine per test from this test's env" do
    expect(Camada.instance_variable_get(:@default)).to be_nil
    get "/"
    engine = Camada.default
    expect(engine.env).not_to be_nil
    expect(engine.env.snapshot_url).to eq(ENV.fetch("CAMADA_SNAPSHOT_URL"))
  end

  it "falls open on a cold snapshot" do
    get "/", {}, { "HTTP_X_FORWARDED_FOR" => BLOCKED_IP }
    expect(last_response.status).to eq(200)
    expect(last_response.headers).not_to have_key("x-block-reason")
    expect(last_response.headers).to have_key("x-rid")
  end

  it "serves the challenge page to a browser on /challenge-me" do
    get "/challenge-me", {}, BROWSER
    expect(last_response.status).to eq(403)
    expect(last_response.headers["x-camada-challenge"]).to eq("1")
    expect(last_response.headers["content-type"]).to start_with("text/html")
    expect(last_response.body).to include("/__camada/challenge")
  end

  it "answers json to an api client on /challenge-me" do
    get "/challenge-me", {}, { "HTTP_X_FORWARDED_FOR" => "198.51.100.7" }
    expect(last_response.status).to eq(403)
    expect(JSON.parse(last_response.body)).to eq({ "error" => "challenge_required" })
  end

  it "renders the 404 page for an unknown path" do
    get "/nope"
    expect(last_response.status).to eq(404)
    expect(last_response.body).to include("Nothing here")
    expect(last_response.headers).to have_key("x-rid")
  end

  it "bypasses the SDK under the kill switch" do
    ENV["CAMADA_DISABLED"] = "1"
    get "/_cam/b.js"
    expect(last_response.status).to eq(404)
    expect(last_response.headers).not_to have_key("x-rid")
  end

  it "records the sibling SDK version in Gemfile.lock" do
    # Gemfile.lock pins the path gem's version the way package-lock.json pins a file: dep; re-lock after a bump.
    version_rb = File.expand_path("../camada-ruby/lib/camada/version.rb", ROOT)
    raise "no camada-ruby checkout beside this repo (#{version_rb})" unless File.exist?(version_rb)

    shipped = File.read(version_rb)[/^\s*VERSION = "([^"]+)"/m, 1]
    locked = File.read(File.join(ROOT, "Gemfile.lock"))[%r{^PATH\n  remote: \.\./camada-ruby\n  specs:\n    camada \(([^)]+)\)}m, 1]
    expect(locked).to eq(shipped), "Gemfile.lock is behind camada-ruby: run `bundle lock`"
  end
end

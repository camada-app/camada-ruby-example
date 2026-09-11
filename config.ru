# frozen_string_literal: true

require_relative "app"

use Camada::Rack # ← the one-line install: camada answers before Sinatra routes, else stamps and captures
run App

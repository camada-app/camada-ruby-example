# frozen_string_literal: true

ENV["RACK_ENV"] = "test"
require "rack/test"

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
end

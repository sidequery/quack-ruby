require "minitest/autorun"
require "quack"

module LiveConnection
  def setup
    super
    skip "set QUACK_TEST_URI to run live integration tests" unless ENV["QUACK_TEST_URI"]
    @connection = Quack.connect(ENV.fetch("QUACK_TEST_URI"), auth_token: ENV.fetch("QUACK_TEST_TOKEN", "quack-ruby-test"))
  end
  def teardown
    @connection&.close if @connection&.connected?
    super
  end
end

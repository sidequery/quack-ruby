require_relative "test_helper"
require "socket"

class ThreadingTest < Minitest::Test
  def test_native_network_wait_releases_gvl_and_obeys_timeout
    server = TCPServer.new("127.0.0.1", 0)
    uri = "http://127.0.0.1:#{server.addr[1]}"
    ticks = 0
    running = true
    ticker = Thread.new { while running; ticks += 1; sleep 0.005; end }
    assert_raises(Quack::TimeoutError) { Quack.connect(uri, timeout: 0.2) }
    assert_operator ticks, :>=, 5
  ensure
    running = false
    ticker&.join
    server&.close
  end
end

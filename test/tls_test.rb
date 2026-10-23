require_relative "test_helper"

class TLSTest < Minitest::Test
  def test_certificate_pinning_and_normal_verification
    skip "run script/test for TLS integration" unless ENV["QUACK_TEST_TLS_URI"]
    uri = ENV.fetch("QUACK_TEST_TLS_URI")
    options = {auth_token: "quack-ruby-test", timeout: 2, ssl_fingerprint: ENV.fetch("QUACK_TEST_TLS_FINGERPRINT")}
    Quack.connect(uri, **options) { |connection| assert_equal [42], connection.values("select 42") }
    assert_raises(Quack::ConnectionError) { Quack.connect(uri, auth_token: "quack-ruby-test", timeout: 2) }
    assert_raises(Quack::ConnectionError) { Quack.connect(uri, **options.merge(ssl_fingerprint: "00" * 32)) }
    assert_raises(Quack::ProtocolError) { Quack.connect(uri, **options.merge(ssl: false)) }
  end
end

require "minitest/autorun"
require "quack"

if ENV["QUACK_TEST_INSTALLED"]
  spec = Gem.loaded_specs.fetch("quack-ruby")
  raise "expected an installed native gem" if spec.platform.to_s == "ruby"
  ruby_abi = RUBY_VERSION[/\A\d+\.\d+/]
  extension = File.join(spec.full_gem_path, "lib/quack/#{ruby_abi}/quack_native")
  raise "native extension was not loaded from the installed gem" unless $LOADED_FEATURES.any? { |path| path.start_with?("#{extension}.") }
end

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

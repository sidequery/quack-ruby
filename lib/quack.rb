require "date"
require "time"
require "bigdecimal"
require "json"
require "rbconfig"

ruby_abi = RUBY_VERSION[/\A\d+\.\d+/]
native_extension = "quack/#{ruby_abi}/quack_native"
if File.file?(File.join(__dir__, "#{native_extension}.#{RbConfig::CONFIG.fetch('DLEXT')}"))
  require native_extension
else
  require "quack/quack_native"
end
require_relative "quack/types"
require_relative "quack/logical_types"
require_relative "quack/codec"
require_relative "quack/variant"
require_relative "quack/sql"
require_relative "quack/result"
require_relative "quack/connection"

module Quack
  VERSION = "0.1.0"

  def self.connect(uri, **options)
    connection = Connection.new(uri, **options)
    return connection unless block_given?
    begin
      yield connection
    ensure
      connection.close
    end
  end
end

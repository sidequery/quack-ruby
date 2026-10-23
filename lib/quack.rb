require "date"
require "time"
require "bigdecimal"
require "json"
require "quack/quack_native"
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

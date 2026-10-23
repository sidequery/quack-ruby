module Quack
  # Preserve the SQL timestamp kind as well as Ruby's nanosecond-precision instant.
  # Time equality/arithmetic continue to use Ruby's standard behavior.
  class Timestamp < Time
    attr_reader :duckdb_type

    def self.from(value, type)
      seconds = value.is_a?(DateTime) ? (value.new_offset(0) - DateTime.new(1970, 1, 1)) * 86_400 : value.to_r
      at(seconds).utc.tap { |time| time.instance_variable_set(:@duckdb_type, String(type).freeze) }
    end

    def getutc
      super.tap { |time| time.instance_variable_set(:@duckdb_type, duckdb_type) }
    end

    def getlocal(*args)
      super.tap { |time| time.instance_variable_set(:@duckdb_type, duckdb_type) }
    end

    def +(seconds) = self.class.from(super, duckdb_type)
    def -(other)
      result = super
      result.is_a?(Time) ? self.class.from(result, duckdb_type) : result
    end
  end

  BitString = Data.define(:bits) do
    def initialize(bits:)
      bits = String(bits)
      raise ArgumentError, "BIT values need at least one 0 or 1 bit" unless bits.match?(/\A[01]+\z/)
      super(bits: bits.dup.freeze)
    end
    def to_s = bits
  end

  # Standard WKB is a lossless geometry value, including empty/Z/M geometries.
  Geometry = Data.define(:wkb, :crs) do
    def initialize(wkb:, crs: nil)
      super(wkb: String(wkb).b.freeze, crs: crs&.dup&.freeze)
    end
  end

  Map = Data.define(:entries, :key_type, :value_type) do
    include Enumerable
    def initialize(entries:, key_type: nil, value_type: nil)
      super(entries: entries.to_h.freeze, key_type: key_type, value_type: value_type)
    end
    def each(&block) = entries.each(&block)
    def [](key) = entries[key]
    def to_h = entries.dup
    def ==(other) = other.is_a?(Map) && entries == other.entries
    alias eql? ==
    def hash = [self.class, entries].hash
  end

  Union = Data.define(:tag, :value, :members) do
    def initialize(tag:, value:, members: nil)
      super(tag: String(tag).freeze, value: value, members: members)
    end
    def ==(other) = other.is_a?(Union) && tag == other.tag && value == other.value
    alias eql? ==
    def hash = [self.class, tag, value].hash
  end

  Tuple = Data.define(:values) do
    def initialize(values:)
      super(values: values.to_a.freeze)
    end
    def [](index) = values[index]
    def to_a = values.dup
  end
end

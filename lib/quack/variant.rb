module Quack
  # A logical, typed tree. Node types preserve distinctions such as UBIGINT,
  # BLOB versus VARCHAR, and timestamp units inside heterogeneous containers.
  class Variant
    Node = Data.define(:type, :value)
    attr_reader :node

    INTEGER_TYPES = {3 => ["TINYINT", 1], 4 => ["SMALLINT", 2], 5 => ["INTEGER", 4], 6 => ["BIGINT", 8], 7 => ["HUGEINT", 16],
                     8 => ["UTINYINT", 1], 9 => ["USMALLINT", 2], 10 => ["UINTEGER", 4], 11 => ["UBIGINT", 8], 12 => ["UHUGEINT", 16]}.freeze
    TEMPORAL_TYPES = {20 => ["TIME", "Micros"], 21 => ["TIME_NS", "Nanos"],
                      22 => ["TIMESTAMP_S", "Seconds"], 23 => ["TIMESTAMP_MS", "Millis"],
                      24 => ["TIMESTAMP", "Micros"], 25 => ["TIMESTAMP_NS", "Nanos"],
                      27 => ["TIMESTAMPTZ", "Micros"], 34 => ["TIMESTAMPTZ_NS", "Nanos"]}.freeze
    STRING_TYPES = {16 => "VARCHAR", 17 => "BLOB", 31 => "BIGNUM", 32 => "BIT", 33 => "GEOMETRY"}.freeze

    def initialize(value, type: nil)
      @node = value.is_a?(Node) ? value : self.class.make_node(value, type)
      self.class.validate_node(@node)
      freeze
    end

    def type = node.type
    def value = self.class.unwrap(node)
    def ==(other) = other.is_a?(Variant) && node == other.node
    alias eql? ==
    def hash = [self.class, node].hash

    def self.unwrap(node)
      case node.type
      when "OBJECT" then node.value.transform_values { |child| unwrap(child) }
      when "ARRAY" then node.value.map { |child| unwrap(child) }
      else node.value
      end
    end

    def self.make_node(value, type = nil)
      return value.node if value.is_a?(Variant)
      return value if value.is_a?(Node)
      type ||= case value
      when nil then "NULL"
      when true, false then "BOOLEAN"
      when Integer then (-(2**63)...2**63).cover?(value) ? "BIGINT" : "BIGNUM"
      when Float then "DOUBLE"
      when BigDecimal
        text = value.to_s("F").sub(/\.0\z/, "")
        integer, fraction = text.delete_prefix("-").split(".")
        scale = fraction.to_s.length
        "DECIMAL(#{[integer.sub(/\A0+/, '').length + scale, 1].max},#{scale})"
      when String then value.encoding == Encoding::BINARY ? "BLOB" : "VARCHAR"
      when Timestamp then value.duckdb_type
      when Time, DateTime then "TIMESTAMP_NS"
      when Date then "DATE"
      when TimeOfDay then value.utc_offset.nil? ? "TIME_NS" : "TIMETZ"
      when Interval then "INTERVAL"
      when InfiniteTemporal then value.type
      when BitString then "BIT"
      when Geometry then "GEOMETRY"
      when Array, Tuple then "ARRAY"
      when Hash then "OBJECT"
      else raise TypeError, "unsupported VARIANT value #{value.class}"
      end
      type = String(type).upcase.freeze
      children = case type
      when "ARRAY" then (value.is_a?(Tuple) ? value.values : value).map { |child| make_node(child) }.freeze
      when "OBJECT" then value.to_h.to_h { |key, child| [String(key).freeze, make_node(child)] }.freeze
      else value
      end
      Node.new(type, children)
    end

    def self.validate_node(node, depth = 0)
      raise ArgumentError, "VARIANT nesting exceeds 256 levels" if depth > 256
      type = node.type
      # Node is public; validate its names even when constructed directly.
      valid = ["NULL", "BOOLEAN", "FLOAT", "DOUBLE", "UUID", "DATE", "TIMETZ", "INTERVAL", "OBJECT", "ARRAY"] + INTEGER_TYPES.values.map(&:first) + TEMPORAL_TYPES.values.map(&:first) + STRING_TYPES.values
      unless valid.include?(type) || type.match?(/\ADECIMAL\((?:[1-9]|[12][0-9]|3[0-8]),(?:[0-9]|[12][0-9]|3[0-8])\)\z/)
        raise ArgumentError, "unsupported VARIANT type #{type}"
      end
      case type
      when "ARRAY" then node.value.each { |child| validate_node(child, depth + 1) }
      when "OBJECT" then node.value.each_value { |child| validate_node(child, depth + 1) }
      when "BOOLEAN"
        raise TypeError, "VARIANT BOOLEAN must be true or false" unless node.value == true || node.value == false
      end
    end

    class Reader
      def initialize(data, offset)
        @data, @offset = data, Integer(offset)
        raise ProtocolError, "invalid VARIANT byte offset" unless (0..data.bytesize).cover?(@offset)
      end
      def bytes(count)
        raise ProtocolError, "truncated VARIANT payload" if count.negative? || @offset + count > @data.bytesize
        result = @data.byteslice(@offset, count)
        @offset += count
        result
      end
      def uint(count) = bytes(count).bytes.reverse.reduce(0) { |value, byte| (value << 8) | byte }
      def int(count)
        value = uint(count)
        value >= 2**(count * 8 - 1) ? value - 2**(count * 8) : value
      end
      def varint
        result = 0
        5.times do |index|
          byte = uint(1)
          result |= (byte & 127) << (index * 7)
          return result if byte < 128 && result < 2**32
        end
        raise ProtocolError, "invalid VARIANT varint"
      end
    end

    def self.from_physical(physical)
      decode_node = lambda do |index, ancestors|
        raise ProtocolError, "cyclic or excessively nested VARIANT" if ancestors.include?(index) || ancestors.length > 256
        item = physical.fetch("values").fetch(index)
        id = item.fetch("type_id")
        reader = Reader.new(physical.fetch("data"), item.fetch("byte_offset"))
        type, value = if INTEGER_TYPES.key?(id)
          name, size = INTEGER_TYPES.fetch(id)
          [name, name.start_with?("U") ? reader.uint(size) : reader.int(size)]
        elsif TEMPORAL_TYPES.key?(id)
          name, unit = TEMPORAL_TYPES.fetch(id)
          raw = reader.int(8)
          converted = if name.start_with?("TIME") && !name.start_with?("TIMESTAMP") && !name.start_with?("TIMESTAMPTZ")
            Quack.__time(raw, unit)
          else
            timestamp = Quack.__timestamp(raw, unit, name.start_with?("TIMESTAMPTZ"))
            timestamp.is_a?(InfiniteTemporal) ? timestamp : Timestamp.from(timestamp, name)
          end
          [name, converted]
        elsif STRING_TYPES.key?(id)
          name = STRING_TYPES.fetch(id)
          data = reader.bytes(reader.varint)
          converted = case name
          when "VARCHAR"
            text = data.dup.force_encoding(Encoding::UTF_8)
            raise ProtocolError, "invalid VARIANT UTF-8" unless text.valid_encoding?
            text
          when "BIGNUM" then Codec.decode_bignum(data)
          when "BIT" then Codec.decode_bit(data)
          when "GEOMETRY" then Geometry.new(data)
          else data.b
          end
          [name, converted]
        else
          case id
          when 0 then ["NULL", nil]
          when 1, 2 then ["BOOLEAN", id == 1]
          when 13 then ["FLOAT", reader.bytes(4).unpack1("e")]
          when 14 then ["DOUBLE", reader.bytes(8).unpack1("E")]
          when 15
            width, scale = reader.varint, reader.varint
            raise ProtocolError, "invalid VARIANT decimal metadata" unless (1..38).cover?(width) && scale <= width
            size = width <= 4 ? 2 : width <= 9 ? 4 : width <= 18 ? 8 : 16
            integer = reader.int(size)
            digits = integer.abs.to_s.rjust(scale + 1, "0")
            text = scale.zero? ? digits : "#{digits[0...-scale]}.#{digits[-scale..]}"
            ["DECIMAL(#{width},#{scale})", BigDecimal(integer.negative? ? "-#{text}" : text)]
          when 18
            hex = (reader.uint(16) ^ (1 << 127)).to_s(16).rjust(32, "0")
            ["UUID", [hex[0, 8], hex[8, 4], hex[12, 4], hex[16, 4], hex[20, 12]].join("-")]
          when 19 then ["DATE", Quack.__date(reader.int(4))]
          when 26 then ["TIMETZ", Quack.__time_tz(reader.int(8))]
          when 28 then ["INTERVAL", Interval.new(reader.int(4), reader.int(4), reader.int(8))]
          when 29, 30
            count = reader.varint
            first = count.zero? ? 0 : reader.varint
            children = physical.fetch("children")
            raise ProtocolError, "invalid VARIANT child range" if first + count > children.length
            items = children.slice(first, count).map do |child|
              node = decode_node.call(child.fetch("values_index"), ancestors + [index])
              id == 29 ? [physical.fetch("keys").fetch(child.fetch("keys_index")), node] : node
            end
            [id == 29 ? "OBJECT" : "ARRAY", id == 29 ? items.to_h.freeze : items.freeze]
          else raise UnsupportedTypeError, "unsupported VARIANT logical type #{id}"
          end
        end
        Node.new(type, value)
      end
      node = decode_node.call(0, [])
      node.type == "NULL" ? nil : new(node)
    rescue KeyError, IndexError, TypeError => error
      raise ProtocolError, "invalid VARIANT structure: #{error.message}"
    end

    def to_sql
      self.class.validate_node(node)
      self.class.node_sql(node)
    end

    def self.node_sql(node)
      case node.type
      when "NULL" then "('null'::JSON)::VARIANT"
      when "ARRAY" then "[#{node.value.map { |child| node_sql(child) }.join(', ')}]::VARIANT"
      when "OBJECT"
        return "('{}'::JSON)::VARIANT" if node.value.empty?
        "{#{node.value.map { |key, child| "#{SQL.literal(key)}: #{node_sql(child)}" }.join(', ')}}::VARIANT"
      else
        literal = node.type.start_with?("TIMESTAMP") || node.type.start_with?("TIMESTAMPTZ") ? SQL.timestamp_literal(node.value, node.type) : SQL.literal(node.value)
        "((#{literal})::#{node.type})::VARIANT"
      end
    end

    def self.varint(value)
      raise RangeError, "VARIANT length out of range" unless (0...2**32).cover?(value)
      bytes = []
      loop do
        byte = value & 127
        value >>= 7
        bytes << (value.zero? ? byte : byte | 128)
        break if value.zero?
      end
      bytes.pack("C*")
    end

    def self.integer_bytes(value, size, signed: true)
      range = signed ? (-(2**(size * 8 - 1))...2**(size * 8 - 1)) : (0...2**(size * 8))
      raise RangeError, "VARIANT integer out of range" unless value.is_a?(Integer) && range.cover?(value)
      Array.new(size) { |index| (value >> (index * 8)) & 255 }.pack("C*")
    end

    def to_physical
      keys = []
      visit_keys = lambda do |node|
        case node.type
        when "OBJECT"
          keys.concat(node.value.keys)
          node.value.each_value { |child| visit_keys.call(child) }
        when "ARRAY" then node.value.each { |child| visit_keys.call(child) }
        end
      end
      visit_keys.call(node)
      keys = keys.uniq.sort
      key_indices = keys.each_with_index.to_h
      physical = {"keys" => keys, "children" => [], "values" => [], "data" => +"".b}
      encode = lambda do |node|
        index = physical.fetch("values").length
        physical.fetch("values") << nil
        type, value = node.type, node.value
        id, bytes = if (entry = INTEGER_TYPES.find { |_id, (name, _size)| name == type })
          [entry.first, self.class.integer_bytes(value, entry.last.last, signed: !type.start_with?("U"))]
        elsif (entry = TEMPORAL_TYPES.find { |_id, (name, _unit)| name == type })
          spec = {"id" => Codec::SQL_NAMES.key(type) || type.capitalize}
          spec["id"] = "Timestamp" if type == "TIMESTAMP"
          packed = Codec.pack(value, spec)
          [entry.first, self.class.integer_bytes(packed[1], 8)]
        elsif (entry = STRING_TYPES.find { |_id, name| name == type })
          payload = case type
          when "BIGNUM" then Codec.encode_bignum(value)
          when "BIT" then Codec.encode_bit(value)
          when "GEOMETRY" then value.wkb
          else String(value).b
          end
          [entry.first, self.class.varint(payload.bytesize) + payload]
        else
          case type
          when "NULL" then [0, "".b]
          when "BOOLEAN" then [value ? 1 : 2, "".b]
          when "FLOAT" then [13, [value].pack("e")]
          when "DOUBLE" then [14, [value].pack("E")]
          when /\ADECIMAL\((\d+),(\d+)\)\z/
            width, scale = Regexp.last_match.captures.map(&:to_i)
            packed = Codec.pack(value, {"id" => "Decimal", "width" => width, "scale" => scale})
            integer = (BigDecimal(packed[1]) * 10**scale).to_i
            size = width <= 4 ? 2 : width <= 9 ? 4 : width <= 18 ? 8 : 16
            [15, self.class.varint(width) + self.class.varint(scale) + self.class.integer_bytes(integer, size)]
          when "UUID"
            hex = String(value).delete("-")
            raise ArgumentError, "invalid VARIANT UUID" unless hex.match?(/\A[0-9a-fA-F]{32}\z/)
            [18, self.class.integer_bytes(hex.to_i(16) ^ (1 << 127), 16, signed: false)]
          when "DATE"
            [19, self.class.integer_bytes(Codec.pack(value, {"id" => "Date"})[1], 4)]
          when "TIMETZ"
            [26, self.class.integer_bytes(Codec.pack(value, {"id" => "TimeTz"})[1], 8)]
          when "INTERVAL"
            [28, self.class.integer_bytes(value.months, 4) + self.class.integer_bytes(value.days, 4) + self.class.integer_bytes(value.microseconds, 8)]
          when "OBJECT", "ARRAY"
            children = type == "OBJECT" ? value.to_a : value.map { |child| [nil, child] }
            first = physical.fetch("children").length
            physical.fetch("children").concat(Array.new(children.length))
            children.each_with_index do |(key, child), offset|
              physical.fetch("children")[first + offset] = {"keys_index" => key && key_indices.fetch(key), "values_index" => encode.call(child)}
            end
            [type == "OBJECT" ? 29 : 30, self.class.varint(children.length) + (children.empty? ? "".b : self.class.varint(first))]
          else raise ArgumentError, "unsupported VARIANT type #{type}"
          end
        end
        physical.fetch("values")[index] = {"type_id" => id, "byte_offset" => physical.fetch("data").bytesize}
        physical.fetch("data") << bytes
        index
      end
      encode.call(node)
      physical
    end
  end
end

module Quack
  # DuckDB's logical metadata drives both directions, including nested values.
  module Codec
    module_function

    SQL_NAMES = {
      "TimestampSec" => "TIMESTAMP_S", "TimestampMs" => "TIMESTAMP_MS",
      "TimestampNs" => "TIMESTAMP_NS", "TimestampTz" => "TIMESTAMPTZ",
      "TimestampTzNs" => "TIMESTAMPTZ_NS", "TimeNs" => "TIME_NS",
      "TimeTz" => "TIMETZ", "SqlNull" => "INTEGER"
    }.freeze
    INTEGER_BITS = {"TinyInt" => 8, "SmallInt" => 16, "Integer" => 32, "BigInt" => 64, "HugeInt" => 128,
                    "UTinyInt" => 8, "USmallInt" => 16, "UInteger" => 32, "UBigInt" => 64, "UHugeInt" => 128}.freeze

    def copy(value)
      case value
      when Array then value.map { |item| copy(item) }
      when Hash then value.to_h { |key, item| [copy(key), copy(item)] }
      when Map then Map.new(copy(value.entries), value.key_type, value.value_type)
      when Union then Union.new(value.tag, copy(value.value), value.members)
      when Tuple then Tuple.new(copy(value.values))
      when Variant then Variant.new(copy(value.node))
      when Variant::Node then Variant::Node.new(value.type.dup, copy(value.value))
      when String, Time then value.dup
      else value
      end
    end

    def sql_type(type)
      id = type.fetch("id")
      return "JSON" if type["alias"]&.casecmp?("JSON")
      case id
      when "Decimal" then "DECIMAL(#{type.fetch('width')},#{type.fetch('scale')})"
      when "List" then "#{sql_type(type.fetch('child'))}[]"
      when "Array" then "#{sql_type(type.fetch('child'))}[#{type.fetch('size')}]"
      when "Map"
        children = type.fetch("child").fetch("children")
        "MAP(#{children.map { |child| sql_type(child.fetch('type')) }.join(', ')})"
      when "Struct", "Tuple", "Union"
        children = type.fetch("children")
        children = children.drop(1) if id == "Union"
        fields = children.map do |child|
          name = child.fetch("name")
          "#{name.empty? ? '' : SQL.identifier(name) + ' '}#{sql_type(child.fetch('type'))}"
        end
        "#{id.upcase}(#{fields.join(', ')})"
      when "Enum" then "ENUM (#{type.fetch('values').map { |value| SQL.literal(value) }.join(', ')})"
      when "Geometry"
        type["crs"] ? "GEOMETRY(#{SQL.literal(type.fetch('crs'))})" : "GEOMETRY"
      else SQL_NAMES.fetch(id, id.upcase)
      end
    end

    # cast_to_type binds its second argument's type without evaluating it. A
    # typed expression also represents query-only unnamed v1 STRUCTs, whose
    # typeof() spelling cannot be parsed as an explicit SQL type declaration.
    def type_expression(type)
      case type.fetch("id")
      when "Struct", "Tuple"
        children = type.fetch("children")
        if type.fetch("id") == "Tuple" || children.all? { |child| child.fetch("name").empty? }
          "row(#{children.map { |child| type_expression(child.fetch('type')) }.join(', ')})"
        else
          "{#{children.map { |child| "#{SQL.literal(child.fetch('name'))}: #{type_expression(child.fetch('type'))}" }.join(', ')}}"
        end
      when "List" then "[#{type_expression(type.fetch('child'))}]"
      when "Array" then "array_value(#{Array.new(type.fetch('size'), type_expression(type.fetch('child'))).join(', ')})"
      when "Map"
        key_type, value_type = type.fetch("child").fetch("children").map { |child| child.fetch("type") }
        "map([#{type_expression(key_type)}][0:0], [#{type_expression(value_type)}][0:0])"
      else "NULL::#{sql_type(type)}"
      end
    end

    def decode(value, type)
      return nil if value.nil?
      id = type.fetch("id")
      case id
      when "BigNum" then decode_bignum(value)
      when "Bit" then decode_bit(value)
      when "Geometry" then Geometry.new(value, type["crs"])
      when "List", "Array" then value.map { |item| decode(item, type.fetch("child")) }
      when "Map"
        fields = type.fetch("child").fetch("children")
        Map.new(value.to_h { |pair| [decode(pair.fetch('key'), fields[0].fetch('type')), decode(pair.fetch('value'), fields[1].fetch('type'))] }, fields[0].fetch("type"), fields[1].fetch("type"))
      when "Union"
        members = type.fetch("children").drop(1).to_h { |child| [child.fetch("name"), child.fetch("type")] }
        tag = members.keys.fetch(value.fetch(""))
        Union.new(tag, decode(value.fetch(tag), members.fetch(tag)), members)
      when "Variant" then Variant.from_physical(value)
      when "Struct", "Tuple"
        children = type.fetch("children")
        if id == "Tuple" || children.all? { |child| child.fetch("name").empty? }
          Tuple.new(children.each_with_index.map { |child, index| decode(value.fetch(index.to_s), child.fetch("type")) })
        else
          children.to_h { |child| [child.fetch("name"), decode(value.fetch(child.fetch("name")), child.fetch("type"))] }
        end
      when /\ATimestamp/
        value.is_a?(InfiniteTemporal) ? InfiniteTemporal.new(sql_type(type), value.sign) : Timestamp.from(value, sql_type(type))
      else value
      end
    end

    def pack(value, type)
      return ["null"] if value.nil?
      id = type.fetch("id")
      if type["alias"]&.casecmp?("JSON")
        text = value.is_a?(String) ? value : JSON.generate(value)
        JSON.parse(text) # Validate without changing whitespace or numeric text.
        return ["string", text]
      end
      if INTEGER_BITS.key?(id)
        raise TypeError, "#{id} append value must be an Integer" unless value.is_a?(Integer)
        bits = INTEGER_BITS.fetch(id)
        unsigned = id.start_with?("U")
        range = unsigned ? (0...2**bits) : (-(2**(bits - 1))...2**(bits - 1))
        raise RangeError, "#{value} is out of range for #{id}" unless range.cover?(value)
        return ["int", value.to_s]
      end
      case id
      when "BigNum" then ["bytes", encode_bignum(value)]
      when "Bit" then ["bytes", encode_bit(value)]
      when "Geometry"
        raise TypeError, "GEOMETRY append value must be a Quack::Geometry" unless value.is_a?(Geometry)
        ["bytes", value.wkb]
      when "Decimal"
        number = BigDecimal(value.to_s)
        raise ArgumentError, "non-finite decimal append value" unless number.finite?
        scale = type.fetch("scale")
        scaled = number * 10**scale
        raise RangeError, "decimal exceeds destination scale" unless scaled.frac.zero?
        raise RangeError, "decimal exceeds destination precision" unless scaled.abs < 10**type.fetch("width")
        ["decimal", number.to_s("F"), type.fetch("width"), scale]
      when "Time", "TimeNs", "TimeTz"
        raise TypeError, "#{id} append value must be a Quack::TimeOfDay" unless value.is_a?(TimeOfDay)
        raise RangeError, "time of day out of range" unless (0..86_400_000_000_000).cover?(value.nanoseconds)
        if id == "TimeTz"
          raise ArgumentError, "TIMETZ needs a UTC offset" if value.utc_offset.nil?
          raise RangeError, "TIMETZ offset out of range" unless (-57_599..57_599).cover?(value.utc_offset)
          require_microseconds(value.nanoseconds)
          bits = (value.nanoseconds / 1000 << 24) | (57_599 - value.utc_offset)
          ["timetz", bits >= 2**63 ? bits - 2**64 : bits]
        else
          raise ArgumentError, "timezone offset requires a TIMETZ column" unless value.utc_offset.nil?
          require_microseconds(value.nanoseconds) if id == "Time"
          ["time", id == "Time" ? value.nanoseconds / 1000 : value.nanoseconds, id == "Time" ? "Micros" : "Nanos"]
        end
      when /\ATimestamp/
        units = {"TimestampSec" => [1, "Seconds"], "TimestampMs" => [1000, "Millis"], "TimestampNs" => [1_000_000_000, "Nanos"], "TimestampTzNs" => [1_000_000_000, "Nanos"]}
        divisor, unit = units.fetch(id, [1_000_000, "Micros"])
        count = if value.is_a?(InfiniteTemporal)
          value.sign.negative? ? -(2**63 - 1) : 2**63 - 1
        else
          seconds = value.is_a?(DateTime) ? (value.new_offset(0) - DateTime.new(1970, 1, 1)) * 86_400 : value.to_r
          scaled = seconds * divisor
          raise RangeError, "timestamp exceeds destination precision" unless scaled.denominator == 1
          raise RangeError, "timestamp out of range" unless (-(2**63 - 2)..2**63 - 2).cover?(scaled)
          scaled.to_i
        end
        ["timestamp", count, unit, %w[TimestampTz TimestampTzNs].include?(id)]
      when "Date"
        days = value.is_a?(InfiniteTemporal) ? value.sign * (2**31 - 1) : (Date.iso8601(value.iso8601, Date::GREGORIAN) - Date.new(1970, 1, 1, Date::GREGORIAN)).to_i
        raise RangeError, "date out of range" unless (-(2**31 - 1)..2**31 - 1).cover?(days)
        ["date", days]
      when "List", "Array"
        raise TypeError, "#{id} append value must be an Array" unless value.is_a?(Array)
        raise ArgumentError, "fixed array length mismatch" if id == "Array" && value.length != type.fetch("size")
        ["list", value.map { |item| pack(item, type.fetch("child")) }]
      when "Map"
        entries = value.is_a?(Map) ? value.entries : value
        raise TypeError, "MAP append value must be a Quack::Map or Hash" unless entries.is_a?(Hash)
        raise ArgumentError, "MAP keys cannot be NULL" if entries.key?(nil)
        fields = type.fetch("child").fetch("children")
        ["list", entries.map { |key, item| ["struct", {"key" => pack(key, fields[0].fetch("type")), "value" => pack(item, fields[1].fetch("type"))}] }]
      when "Union"
        raise TypeError, "UNION append value must be a Quack::Union" unless value.is_a?(Union)
        children = type.fetch("children").drop(1)
        index = children.index { |child| child.fetch("name") == value.tag }
        raise ArgumentError, "unknown UNION member #{value.tag}" unless index
        fields = {"" => ["int", index.to_s]}
        children.each { |child| fields[child.fetch("name")] = child.fetch("name") == value.tag ? pack(value.value, child.fetch("type")) : ["null"] }
        ["struct", fields]
      when "Variant"
        variant = value.is_a?(Variant) ? value : Variant.new(value)
        pack(variant.to_physical, {"id" => "Struct", "children" => type.fetch("children")})
      when "Struct", "Tuple"
        children = type.fetch("children")
        unnamed = id == "Tuple" || children.all? { |child| child.fetch("name").empty? }
        if unnamed
          values = value.is_a?(Tuple) ? value.values : value
          raise ArgumentError, "tuple length mismatch" unless values.is_a?(Array) && values.length == children.length
          ["struct", children.each_with_index.to_h { |child, index| [index.to_s, pack(values[index], child.fetch("type"))] }]
        else
          raise TypeError, "STRUCT append value must be a Hash" unless value.is_a?(Hash)
          fields = value.transform_keys(&:to_s)
          raise ArgumentError, "STRUCT field names mismatch" unless fields.keys.sort == children.map { |child| child.fetch("name") }.sort
          ["struct", children.to_h { |child| [child.fetch("name"), pack(fields.fetch(child.fetch("name")), child.fetch("type"))] }]
        end
      when "Boolean"
        raise TypeError, "BOOLEAN append value must be true or false" unless value == true || value == false
        ["bool", value]
      when "Float", "Double"
        number = Float(value)
        raise RangeError, "value exceeds #{id} range" if number.infinite? && value.respond_to?(:finite?) && value.finite?
        raise RangeError, "value exceeds FLOAT range" if id == "Float" && number.finite? && number.abs > 3.4028234663852886e38
        ["double", number]
      when "Enum"
        raise ArgumentError, "unknown ENUM value" unless type.fetch("values").include?(value)
        ["string", value]
      when "Varchar", "Char", "Uuid"
        raise TypeError, "#{id} append value must be a String" unless value.is_a?(String)
        text = value.encode(Encoding::UTF_8)
        raise EncodingError, "invalid UTF-8 text" unless text.valid_encoding?
        ["string", text]
      when "Blob"
        raise TypeError, "BLOB append value must be a String" unless value.is_a?(String)
        ["bytes", value.b]
      when "Interval"
        raise TypeError, "INTERVAL append value must be a Quack::Interval" unless value.is_a?(Interval)
        ["interval", value.months, value.days, value.microseconds]
      else raise UnsupportedTypeError, "unsupported append logical type #{id}"
      end
    end

    def require_microseconds(nanoseconds)
      raise RangeError, "value exceeds microsecond precision" unless (nanoseconds % 1000).zero?
    end

    def decode_bignum(bytes)
      # DuckDB stores a three-byte length header and big-endian magnitude;
      # negative values complement every byte, including the header.
      bytes = bytes.bytes
      raise ProtocolError, "invalid BIGNUM payload" if bytes.length < 4
      negative = bytes[0] < 128
      bytes.map! { |byte| byte ^ 255 } if negative
      length = ((bytes[0] & 127) << 16) | (bytes[1] << 8) | bytes[2]
      raise ProtocolError, "invalid BIGNUM length" unless length == bytes.length - 3
      magnitude = bytes.drop(3).pack("C*").unpack1("H*").to_i(16)
      negative ? -magnitude : magnitude
    end

    def encode_bignum(value)
      raise TypeError, "BIGNUM append value must be an Integer" unless value.is_a?(Integer)
      hex = value.abs.to_s(16)
      bytes = [hex.length.odd? ? "0#{hex}" : hex].pack("H*")
      raise RangeError, "BIGNUM payload exceeds 23-bit length" if bytes.bytesize >= 2**23
      bytes = [bytes.bytesize | 0x800000].pack("N").byteslice(1, 3) + bytes
      value.negative? ? bytes.bytes.map { |byte| byte ^ 255 }.pack("C*") : bytes
    end

    def decode_bit(bytes)
      padding = bytes.getbyte(0)
      raise ProtocolError, "invalid BIT payload" unless padding && padding < 8 && bytes.bytesize > 1
      BitString.new(bytes.byteslice(1..).unpack1("B*").byteslice(padding..))
    end

    def encode_bit(value)
      value = BitString.new(value) unless value.is_a?(BitString)
      padding = (8 - value.bits.length % 8) % 8
      [padding].pack("C") + ["1" * padding + value.bits].pack("B*")
    end
  end
end

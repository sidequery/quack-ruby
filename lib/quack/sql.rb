require "strscan"

module Quack
  module SQL
    module_function

    def identifier(name)
      '"' + String(name).gsub('"', '""') + '"'
    end

    def identifier_parts(name)
      scanner = StringScanner.new(String(name))
      parts = []
      until scanner.eos?
        if scanner.scan(/"/)
          part = +""
          closed = false
          until scanner.eos?
            char = scanner.getch
            if char == '"'
              if scanner.scan(/"/) then part << '"'
              else closed = true; break
              end
            else part << char
            end
          end
          raise ArgumentError, "unterminated quoted identifier" unless closed
        else
          part = scanner.scan(/[^."]+/)
        end
        raise ArgumentError, "invalid qualified identifier" if part.nil? || part.empty?
        parts << part
        break if scanner.eos?
        raise ArgumentError, "invalid qualified identifier" unless scanner.scan(/\./) && !scanner.eos?
      end
      raise ArgumentError, "expected one to three identifier parts" unless (1..3).cover?(parts.length)
      parts
    end

    def literal(value)
      case value
      when nil then "NULL"
      when true then "TRUE"
      when false then "FALSE"
      when Integer
        return "'#{value}'::BIGNUM" unless (-(2**127)...2**128).cover?(value)
        value.negative? ? "(#{value})" : value.to_s
      when BigDecimal
        raise ArgumentError, "non-finite decimal parameter" unless value.finite?
        text = value.to_s("F").sub(/\.0\z/, "")
        integer, fraction = text.delete_prefix("-").split(".")
        scale = fraction.to_s.length
        width = [integer.sub(/\A0+/, "").length + scale, 1].max
        raise RangeError, "DuckDB decimals support at most 38 digits" if width > 38
        "'#{text}'::DECIMAL(#{width},#{scale})"
      when Float
        return "'NaN'::DOUBLE" if value.nan?
        return value.positive? ? "'Infinity'::DOUBLE" : "'-Infinity'::DOUBLE" if value.infinite?
        "'#{value}'::DOUBLE"
      when String
        if value.encoding == Encoding::BINARY
          "from_hex('#{value.unpack1('H*')}')"
        else
          text = value.encode(Encoding::UTF_8)
          text.include?("\0") ? "decode(from_hex('#{text.unpack1('H*')}'))" : "'#{text.gsub("'", "''")}'"
        end
      when Timestamp then timestamp_literal(value, value.duckdb_type)
      when Time, DateTime
        fraction = value.is_a?(DateTime) ? value.sec_fraction : value.to_r % 1
        timestamp_literal(value, ((fraction * 1_000_000) % 1).zero? ? "TIMESTAMPTZ" : "TIMESTAMP_NS")
      when Date then "DATE '#{value.iso8601}'"
      when TimeOfDay
        type = if value.utc_offset
          "TIMETZ"
        elsif (value.nanoseconds % 1000).zero?
          "TIME"
        else
          "TIME_NS"
        end
        "#{type} '#{value}'"
      when Interval then "INTERVAL '#{Integer(value.months)} months #{Integer(value.days)} days #{Integer(value.microseconds)} microseconds'"
      when InfiniteTemporal
        type = (%w[DATE] + TIMESTAMP_TYPES).include?(value.type) ? value.type : raise(ArgumentError, "invalid temporal type")
        "#{type} '#{value.sign.negative? ? '-' : ''}infinity'"
      when BitString then "#{literal(value.bits)}::BIT"
      when Geometry
        geometry = "ST_GeomFromWKB(#{literal(value.wkb)})"
        value.crs ? "#{geometry}::GEOMETRY(#{literal(value.crs)})" : geometry
      when Map
        expression = "map([#{value.entries.keys.map { |key| literal(key) }.join(', ')}], [#{value.entries.values.map { |item| literal(item) }.join(', ')}])"
        if value.key_type && value.value_type
          seed = "map([#{Codec.type_expression(value.key_type)}][0:0], [#{Codec.type_expression(value.value_type)}][0:0])"
          "cast_to_type(#{expression}, #{seed})"
        else expression
        end
      when Union
        active = literal(value.value)
        active = "(#{active})::#{Codec.sql_type(value.members.fetch(value.tag))}" if value.members
        expression = "union_value(#{identifier(value.tag)} := #{active})"
        if value.members
          "#{expression}::UNION(#{value.members.map { |name, type| "#{identifier(name)} #{Codec.sql_type(type)}" }.join(', ')})"
        else expression
        end
      when Tuple then "row(#{value.values.map { |item| literal(item) }.join(', ')})"
      when Variant then value.to_sql
      when Array then "[#{value.map { |v| literal(v) }.join(', ')}]"
      when Hash then "{#{value.map { |key, v| "#{literal(String(key))}: #{literal(v)}" }.join(', ')}}"
      else raise TypeError, "unsupported Quack parameter type: #{value.class}"
      end
    end

    TIMESTAMP_TYPES = %w[TIMESTAMP_S TIMESTAMP_MS TIMESTAMP TIMESTAMP_NS TIMESTAMPTZ TIMESTAMPTZ_NS].freeze

    def timestamp_literal(value, type)
      raise ArgumentError, "invalid timestamp type" unless TIMESTAMP_TYPES.include?(type)
      return "#{type} '#{value.sign.negative? ? '-' : ''}infinity'" if value.is_a?(InfiniteTemporal)
      Codec.pack(value, {"id" => Codec::SQL_NAMES.key(type) || "Timestamp"})
      utc = value.is_a?(DateTime) ? value.new_offset(0).new_start(Date::GREGORIAN) : value.getutc
      suffix = type.start_with?("TIMESTAMPTZ") ? "+00" : ""
      "#{type} '#{utc.strftime('%Y-%m-%d %H:%M:%S.%N')}#{suffix}'"
    end

    # Parameter substitution is client-side. The lexer preserves UTF-8, quoted
    # identifiers/strings, dollar strings, and nested comments verbatim.
    def bind(sql, parameters = nil)
      return String(sql) if parameters.nil?
      unless parameters.is_a?(Array) || parameters.is_a?(Hash)
        raise ArgumentError, "parameters must be an Array or Hash"
      end
      named = parameters.is_a?(Hash)
      parameters = parameters.transform_keys(&:to_s) if named
      scanner = StringScanner.new(String(sql))
      output = +""
      index = 0
      until scanner.eos?
        if (token = scanner.scan(/--[^\n]*(?:\n|\z)/))
          output << token
        elsif scanner.scan(%r{/\*})
          output << "/*"
          depth = 1
          until scanner.eos? || depth.zero?
            if scanner.scan(%r{/\*}) then output << "/*"; depth += 1
            elsif scanner.scan(%r{\*/}) then output << "*/"; depth -= 1
            else output << scanner.getch
            end
          end
        elsif (start = scanner.scan(/(?:\b[Ee])?'|"/))
          output << start
          quote = start[-1]
          escaped = start.length > 1
          until scanner.eos?
            char = scanner.getch
            output << char
            if escaped && char == "\\"
              output << scanner.getch unless scanner.eos?
            elsif char == quote
              if scanner.peek(1) == quote then output << scanner.getch
              else break
              end
            end
          end
        elsif (delimiter = scanner.scan(/\$(?:[A-Za-z_][A-Za-z_0-9]*)?\$/))
          output << delimiter
          output << (scanner.scan_until(/#{Regexp.escape(delimiter)}/) || scanner.rest.tap { scanner.terminate })
        elsif (cast = scanner.scan(/::/))
          output << cast
        elsif named && (placeholder = scanner.scan(/:[A-Za-z_][A-Za-z_0-9]*/))
          name = placeholder.delete_prefix(":")
          raise ArgumentError, "missing parameter :#{name}" unless parameters.key?(name)
          output << literal(parameters.fetch(name))
        elsif !named && scanner.scan(/\?/)
          raise ArgumentError, "more placeholders than parameters" if index >= parameters.length
          output << literal(parameters[index])
          index += 1
        else
          output << scanner.getch
        end
      end
      raise ArgumentError, "#{index} placeholders for #{parameters.length} parameters" if !named && index != parameters.length
      output
    end
  end
end

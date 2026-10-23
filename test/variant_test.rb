require_relative "test_helper"
require_relative "type_cases"

class VariantTest < Minitest::Test
  include LiveConnection

  QuackTypeCases::CASES.each do |name, type, expression, _expected|
    define_method("test_variant_#{name}_sql_and_native_roundtrip") do
      skip "TIMESTAMPTZ_NS requires DuckDB 2" if type == "TIMESTAMPTZ_NS" && ENV.fetch("QUACK_TEST_VERSION").start_with?("1.")
      value = @connection.values("select ((#{expression})::#{type})::VARIANT").first
      assert_equal [value], @connection.values("select ?", [value])
      @connection.execute("create temp table variant_values (v VARIANT)")
      if @connection.info.fetch("quack_version") == 1
        @connection.append_rows("variant_values", [{v: value}, {v: nil}], batch_size: 1)
      else
        @connection.execute("insert into variant_values values (?), (NULL)", [value])
      end
      assert_equal [value, nil], @connection.values("select v from variant_values")
    end
  end

  def test_heterogeneous_nested_containers_and_empty_values
    value = Quack::Variant.new({"object" => {}, "array" => [], "null" => nil,
      "items" => [Quack::Variant.new(2**100, type: "UHUGEINT"), Quack::Variant.new("\x00\xff".b), Quack::Variant.new(BigDecimal("123.123456789012345678"), type: "DECIMAL(38,18)")]})
    assert_equal value, @connection.values("select ?", [value]).first
    if @connection.info.fetch("quack_version") == 1
      @connection.execute("create temp table nested_variant_values (v VARIANT)")
      @connection.append_rows("nested_variant_values", [{v: value}])
      assert_equal [value], @connection.values("select v from nested_variant_values")
    end
  end
end

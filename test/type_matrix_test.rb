require_relative "test_helper"
require_relative "type_cases"

class TypeMatrixTest < Minitest::Test
  include LiveConnection

  CASES = QuackTypeCases::CASES

  CASES.each do |name, type, expression, expected|
    define_method("test_read_#{name}_and_null") do
      skip "TIMESTAMPTZ_NS requires DuckDB 2" if type == "TIMESTAMPTZ_NS" && ENV.fetch("QUACK_TEST_VERSION").start_with?("1.")
      sql = "select v from (values (0, (#{expression})::#{type}), (1, NULL::#{type})) t(i,v) order by i"
      assert_equal [[expected], [nil]], @connection.query(sql).rows
      assert_equal [], @connection.query("select (#{expression})::#{type} as v where false").rows
    end
    define_method("test_parameter_roundtrip_#{name}") do
      skip "TIMESTAMPTZ_NS requires DuckDB 2" if type == "TIMESTAMPTZ_NS" && ENV.fetch("QUACK_TEST_VERSION").start_with?("1.")
      @connection.execute("SET TimeZone = 'UTC'") if expected.is_a?(Time)
      assert_equal [[expected], [nil]], @connection.query("select v from (values (0, ?::#{type}), (1, ?::#{type})) t(i,v) order by i", [expected, nil]).rows
    end
  end

  def test_map_parameters
    assert_equal [[Quack::Map.new({"a" => 1, "b" => nil})]], @connection.query("select map(?::VARCHAR[], ?::INTEGER[])", [["a", "b"], [1, nil]]).rows
  end

  def test_bit_padding_boundaries
    %w[0 1 0000000 11111111 000000000 1010101011110000].each do |bits|
      value = @connection.values("select ?::BIT", [Quack::BitString.new(bits)]).first
      assert_equal bits, value.bits
    end
  end

  def test_union_tags_and_null_member_are_distinct_from_sql_null
    values = @connection.values("select v from (values (0, union_value(i := 42)::UNION(i INTEGER, s VARCHAR)), (1, union_value(s := 'hi')::UNION(i INTEGER, s VARCHAR)), (2, union_value(i := NULL::INTEGER)::UNION(i INTEGER, s VARCHAR)), (3, NULL::UNION(i INTEGER, s VARCHAR))) t(i,v) order by i")
    assert_equal [Quack::Union.new("i", 42), Quack::Union.new("s", "hi"), Quack::Union.new("i", nil), nil], values
    values.each { |value| assert_equal [value], @connection.values("select ?::UNION(i INTEGER, s VARCHAR)", [value]) }
  end

  def test_variant_nested_values_and_null_are_distinct_from_sql_null
    value = @connection.values(%q(select {'x': [1, NULL, 3], 'text': 'é', 'amount': 1.230::DECIMAL(8,3)}::VARIANT)).first
    assert_equal({"x" => [1, nil, 3], "text" => "é", "amount" => BigDecimal("1.23")}, value.value)
    assert_equal value, @connection.values("select ?::VARIANT", [value]).first
    null = Quack::Variant.new(nil)
    assert_equal [nil, nil], @connection.values("select v from (values (0, ?::VARIANT), (1, NULL::VARIANT)) t(i,v) order by i", [null])
  end

  def test_geometry_wkb_roundtrip
    expected = ["0101000000000000000000f03f0000000000000040"].pack("H*")
    value = @connection.values("select 'POINT (1 2)'::GEOMETRY").first
    assert_equal expected, value.wkb
    assert_equal [value], @connection.values("select ?", [value])
  end

  def test_bignum_arbitrary_precision_and_nesting
    [0, 1, -1, 2**128, -(2**128), 10**1000 + 123].each do |number|
      assert_equal [number], @connection.values("select ?::BIGNUM", [number])
      assert_equal [[number, nil]], @connection.values("select [?::BIGNUM, NULL]", [number])
      assert_equal [{"x" => number}], @connection.values("select {'x': ?::BIGNUM}", [number])
    end
  end

  def test_unnamed_tuple_roundtrip_without_losing_fields
    value = @connection.values("select row(42, 'é', NULL::INTEGER)").first
    assert_equal Quack::Tuple.new([42, "é", nil]), value
    assert_equal [value], @connection.values("select ?", [value])
  end

  def test_nonfinite_floats
    %w[FLOAT DOUBLE].each do |type|
      values = @connection.query("select 'NaN'::#{type}, 'Infinity'::#{type}, '-Infinity'::#{type}").rows.first
      assert values[0].nan?
      assert_equal Float::INFINITY, values[1]
      assert_equal(-Float::INFINITY, values[2])
    end
  end
end

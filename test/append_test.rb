require_relative "test_helper"
require_relative "type_cases"

class AppendTest < Minitest::Test
  include LiveConnection

  QuackTypeCases::CASES.each do |name, type, _expression, expected|
    next if type == "TIMESTAMPTZ_NS" # This type does not exist in the v1 server.
    define_method("test_v1_append_#{name}_null_and_batches") do
      skip "native append is a v1 protocol operation" unless @connection.info.fetch("quack_version") == 1
      @connection.execute("create temp table append_values (v #{type})")
      @connection.append_rows("append_values", [{v: expected}, {v: nil}, {v: expected}], batch_size: 2)
      assert_equal [[expected], [nil], [expected]], @connection.query("select v from append_values").rows
    end
  end

  def test_v1_append_all_null_empty_lists_and_destination_metadata
    skip "native append is a v1 protocol operation" unless @connection.info.fetch("quack_version") == 1
    @connection.execute('create temp table append_nested ("MixedCase" STRUCT("FieldCase" INTEGER[], empty VARCHAR), v DECIMAL(38,0))')
    rows = [{"v" => BigDecimal("12345678901234567890123456789012345678"), "MixedCase" => {"FieldCase" => [], "empty" => nil}}, {"MixedCase" => nil, "v" => nil}]
    @connection.append_rows("append_nested", rows, batch_size: 1)
    assert_equal [[rows[0]["MixedCase"], rows[0]["v"]], [nil, nil]], @connection.query("select * from append_nested").rows
  end

  def test_v1_append_tuple_fields
    skip "native append is a v1 protocol operation" unless @connection.info.fetch("quack_version") == 1
    @connection.execute("create temp table append_tuple as select row(1,'x') v where false")
    tuple = Quack::Tuple.new([42, "é"])
    error = assert_raises(Quack::ServerError) { @connection.append_rows("append_tuple", [{v: tuple}, {v: nil}]) }
    assert_includes error.message, "A table cannot be created from an unnamed struct"
    assert_equal [0], @connection.values("select count(*) from append_tuple")
  end

  def test_v1_append_nonfinite_numbers_and_temporal_edges
    skip "native append is a v1 protocol operation" unless @connection.info.fetch("quack_version") == 1
    @connection.execute("create temp table append_edges (f FLOAT, d DOUBLE, n BIGNUM, day DATE, ts TIMESTAMP_NS, tod TIME, tz TIMETZ)")
    positive = {f: Float::NAN, d: Float::INFINITY, n: 0, day: Quack::InfiniteTemporal.new("DATE", 1), ts: Quack::InfiniteTemporal.new("TIMESTAMP_NS", 1), tod: Quack::TimeOfDay.new(86_400_000_000_000, nil), tz: Quack::TimeOfDay.new(0, -57_599)}
    negative = {f: -Float::INFINITY, d: -Float::INFINITY, n: -(10**1000 + 123), day: Quack::InfiniteTemporal.new("DATE", -1), ts: Quack::InfiniteTemporal.new("TIMESTAMP_NS", -1), tod: Quack::TimeOfDay.new(0, nil), tz: Quack::TimeOfDay.new(86_400_000_000_000, 57_599)}
    @connection.append_rows("append_edges", [positive, negative], batch_size: 1)
    rows = @connection.query("select * from append_edges").rows
    assert rows[0][0].nan?
    assert_equal positive.values.drop(1), rows[0].drop(1)
    assert_equal negative.values, rows[1]
  end

  def test_v1_append_nested_logical_types_and_union_null_member
    skip "native append is a v1 protocol operation" unless @connection.info.fetch("quack_version") == 1
    @connection.execute("create temp table append_logical (m MAP(INTEGER, HUGEINT[]), u UNION(i INTEGER, s VARCHAR), nested STRUCT(b BIT, n BIGNUM)[], v VARIANT[])")
    first = {m: Quack::Map.new({1 => [2**100, nil], 2 => []}), u: Quack::Union.new("i", nil), nested: [{"b" => Quack::BitString.new("01"), "n" => -(10**100)}, nil], v: [Quack::Variant.new({"x" => [1, nil, "é"]}), nil]}
    second = {m: Quack::Map.new({}), u: Quack::Union.new("s", "é"), nested: [], v: []}
    @connection.append_rows("append_logical", [first, second], batch_size: 1)
    assert_equal [first.values, second.values], @connection.query("select * from append_logical").rows
  end

  def test_v1_append_explicit_nested_types_and_case_sensitive_fields
    skip "native append is a v1 protocol operation" unless @connection.info.fetch("quack_version") == 1
    @connection.execute('create temp table append_explicit (v STRUCT("FieldCase" INTEGER[2], s VARCHAR))')
    value = {"FieldCase" => [1, nil], "s" => "é"}
    @connection.append_rows("append_explicit", [{v: value}], columns: {v: 'STRUCT("FieldCase" INTEGER[2], s VARCHAR)'})
    assert_equal [value], @connection.values("select v from append_explicit")
  end

  def test_v1_append_explicit_column_order_and_qualified_table
    skip "native append is a v1 protocol operation" unless @connection.info.fetch("quack_version") == 1
    @connection.execute('create temp table "append.dot" (a INTEGER, b INTEGER)')
    @connection.append_rows('main."append.dot"', [{b: 2, a: 1}], columns: {b: "INTEGER", a: "INTEGER"})
    assert_equal [[1, 2]], @connection.query('select * from "append.dot"').rows
  end

  def test_v1_append_invalid_values_are_rejected_before_writing_any_batch
    skip "native append is a v1 protocol operation" unless @connection.info.fetch("quack_version") == 1
    {"TINYINT" => [1, 128], "UTINYINT" => [1, -1], "DECIMAL(4,2)" => [BigDecimal("1.23"), BigDecimal("1.234")], "FLOAT" => [1.0, 1e100], "INTEGER[2]" => [[1, 2], [1]], "TIME" => [Quack::TimeOfDay.new(1000, nil), Quack::TimeOfDay.new(1001, nil)]}.each do |type, values|
      @connection.execute("create or replace temp table append_invalid (v #{type})")
      assert_raises(RangeError, ArgumentError) { @connection.append_rows("append_invalid", values.map { |value| {v: value} }, batch_size: 1) }
      assert_equal [0], @connection.values("select count(*) from append_invalid")
    end
  end
end

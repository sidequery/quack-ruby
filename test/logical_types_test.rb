require_relative "test_helper"

class LogicalTypesTest < Minitest::Test
  include LiveConnection

  def test_typed_timestamp_survives_time_operations_and_binding
    value = @connection.values("select TIMESTAMP_NS '2026-10-23 01:02:03.123456789'").first
    [value.getutc, value.getlocal("+05:30"), value + 1, value - 1].each do |time|
      assert_equal "TIMESTAMP_NS", time.duckdb_type
      result = @connection.values("select ?", [time]).first
      assert_equal time, result
      assert_equal "TIMESTAMP_NS", result.duckdb_type
    end
    assert_raises(RangeError) { @connection.values("select ?", [Quack::Timestamp.from(value, "TIMESTAMP")]) }
  end

  def test_nested_tuple_map_and_empty_map_sql_roundtrips
    ["map([1], [row(42,'é')])", "map([]::INTEGER[], []::VARCHAR[])", "map([row(1,'x')][0:0], [42][0:0])"].each do |expression|
      value = @connection.values("select #{expression}").first
      assert_equal [value], @connection.values("select ?", [value])
    end
  end

  def test_geometry_dimensions_collections_empty_values_and_crs
    ["POINT Z (1 2 3)", "POINT M (1 2 3)", "POINT ZM (1 2 3 4)", "LINESTRING EMPTY", "GEOMETRYCOLLECTION (POINT (1 2), LINESTRING (0 0, 1 1))"].each do |wkt|
      value = @connection.values("select ?::GEOMETRY", [wkt]).first
      assert_equal [value], @connection.values("select ?", [value])
      if @connection.info.fetch("quack_version") == 1
        @connection.execute("create or replace temp table geometry_values (v GEOMETRY)")
        @connection.append_rows("geometry_values", [{v: value}])
        assert_equal [value], @connection.values("select v from geometry_values")
      end
    end
    crs = 'GEOGCRS["Quack test",ID["LOCAL","Q1"]]'
    value = @connection.values("select 'POINT (1 2)'::GEOMETRY(#{Quack::SQL.literal(crs)})").first
    assert_equal crs, value.crs
    assert_equal [value], @connection.values("select ?", [value])
    if @connection.info.fetch("quack_version") == 1
      @connection.execute("create temp table geometry_crs_values (v GEOMETRY(#{Quack::SQL.literal(crs)}))")
      @connection.append_rows("geometry_crs_values", [{v: value}])
      assert_equal [value], @connection.values("select v from geometry_crs_values")
    end
  end

  def test_variant_rejects_invalid_public_node_type
    assert_raises(ArgumentError) { Quack::Variant.new(Quack::Variant::Node.new("INTEGER); SELECT 1; --", 1)) }
    assert_raises(ArgumentError) { Quack::BitString.new("") }
  end

  def test_float_parameters_keep_float_type_and_negative_zero
    values = @connection.query("select ?, ?, ?", [1.5, -0.0, Float::MIN]).rows.first
    assert_instance_of Float, values[0]
    assert_equal 1.5, values[0]
    assert_equal(-Float::INFINITY, 1.0 / values[1])
    assert_equal Float::MIN, values[2]
  end

  def test_datetime_calendar_and_offset_match_native_append
    [Date::JULIAN, Date::GREGORIAN].each do |calendar|
      value = DateTime.new(1500, 1, 1, 12, 34, Rational(56123456, 1_000_000), "+05:30", calendar)
      expected = Time.at((value.new_offset(0) - DateTime.new(1970, 1, 1)) * 86_400).utc
      assert_equal [expected], @connection.values("select ?::TIMESTAMPTZ", [value])
      if @connection.info.fetch("quack_version") == 1
        @connection.execute("create or replace temp table datetime_values (v TIMESTAMPTZ)")
        @connection.append_rows("datetime_values", [{v: value}])
        assert_equal [expected], @connection.values("select v from datetime_values")
      end
    end
  end
end

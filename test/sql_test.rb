require_relative "test_helper"

class SQLTest < Minitest::Test
  def test_quotes_comments_and_unicode
    sql = "select 'é ?' a, \"?\", $$?$$, $body$:name ?$body$, E'can\\'t ?' /* ? /* ? */ ? */ , ? -- ?\n"
    assert_equal sql.sub(", ? --", ", 'héllo''世界' --"), Quack::SQL.bind(sql, ["héllo'世界"])
  end
  def test_named_params_and_casts
    assert_equal "select 42::BIGINT, ':x'", Quack::SQL.bind("select :x::BIGINT, ':x'", x: 42)
    assert_raises(ArgumentError) { Quack::SQL.bind("select :missing", {}) }
    assert_raises(ArgumentError) { Quack::SQL.bind("select ?", []) }
    assert_raises(ArgumentError) { Quack::SQL.bind("select 1", [2]) }
  end
  def test_exact_types
    assert_equal "12345678901234567890123456789012345678", Quack::SQL.literal(12345678901234567890123456789012345678)
    assert_equal "'123.000000000000000001'::DECIMAL(21,18)", Quack::SQL.literal(BigDecimal("123.000000000000000001"))
    assert_includes Quack::SQL.literal(Time.at(Rational(1234567890123456789, 1_000_000_000)).utc), "123456789"
    assert_equal "from_hex('00ff')", Quack::SQL.literal("\x00\xff".b)
    assert_equal "decode(from_hex('610062'))", Quack::SQL.literal("a\0b")
  end
  def test_identifier_parts
    assert_equal ["catalog", "schema", "a.b"], Quack::SQL.identifier_parts('catalog.schema."a.b"')
    assert_equal ['a"b'], Quack::SQL.identifier_parts('"a""b"')
    ["", "foo.", ".foo", '"foo', "a.b.c.d"].each { |name| assert_raises(ArgumentError) { Quack::SQL.identifier_parts(name) } }
  end
end

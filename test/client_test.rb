require_relative "test_helper"

class ClientTest < Minitest::Test
  include LiveConnection

  def test_protocol_and_unicode_parameters
    assert_includes [1, 3], @connection.info.fetch("quack_version")
    if ENV["QUACK_TEST_VERSION"]
      assert_equal ENV["QUACK_TEST_VERSION"].start_with?("1.") ? 1 : 3, @connection.info.fetch("quack_version")
    end
    assert_equal [{"answer" => 42, "greeting" => "héllo 世界"}], @connection.query("select :x::bigint answer, :greeting greeting", x: 42, greeting: "héllo 世界").to_a
    assert_equal "? ?", @connection.first('select $$? ?$$ as "value", ? n', [1])["value"]
    assert_equal "a\0b", @connection.values("select ?", ["a\0b"]).first
  end

  def test_native_values_and_duplicate_column_names
    result = @connection.query(<<~SQL)
      select 170141183460469231731687303715884105727::hugeint signed,
             340282366920938463463374607431768211455::uhugeint unsigned,
             123.000000000000000001::decimal(38,18) amount,
             date '2026-10-23' as "day", timestamp_ns '2026-10-23 01:02:03.123456789' ts,
             from_hex('00ff') bytes, [1, NULL, 3] items, {'name': 'é'} as "object",
             interval '2 months 3 days 4 microseconds' duration,
             time '24:00:00' tod, NULL empty
    SQL
    row = result.first
    assert_equal 2**127 - 1, row["signed"]
    assert_equal 2**128 - 1, row["unsigned"]
    assert_equal BigDecimal("123.000000000000000001"), row["amount"]
    assert_equal Date.new(2026, 10, 23), row["day"]
    assert_equal 123456789, row["ts"].nsec
    assert_equal "\x00\xff".b, row["bytes"]
    assert_equal Encoding::BINARY, row["bytes"].encoding
    assert_equal [1, nil, 3], row["items"]
    assert_equal({"name" => "é"}, row["object"])
    assert_equal Quack::Interval.new(2, 3, 4), row["duration"]
    assert_equal "24:00:00", row["tod"].to_s
    assert_nil row["empty"]
    duplicate = @connection.query("select 1 x, 2 x")
    assert_equal ["x", "x"], duplicate.columns
    assert_equal [[1, 2]], duplicate.rows
  end

  def test_streaming_early_close_and_admission
    stream = @connection.stream("select i from range(10000) t(i)")
    assert_raises(Quack::BusyError) { @connection.query("select 1") }
    assert_equal({"i" => 0}, stream.first)
    assert stream.closed?
    assert_equal [42], @connection.values("select 42")
    old_stream = @connection.stream("select 1")
    old_stream.to_a
    new_stream = @connection.stream("select 2")
    old_stream.close
    GC.start
    assert_raises(Quack::BusyError) { @connection.query("select 3") }
    assert_equal [[2]], new_stream.each_row.to_a
    assert_equal 10000, @connection.stream("select i from range(10000) t(i)").each_row.count
  end

  def test_transactions_and_session_state
    @connection.execute("create temp table ruby_session (i integer)")
    assert_raises(RuntimeError) do
      @connection.transaction { |c| c.execute("insert into ruby_session values (?)", [1]); raise "rollback" }
    end
    assert_equal [0], @connection.values("select count(*) from ruby_session")
    @connection.transaction { |c| c.execute("insert into ruby_session values (2)") }
    assert_equal [2], @connection.values("select i from ruby_session")
  end

  def test_errors_authentication_and_explicit_reconnect
    assert_raises(Quack::ServerError) { @connection.query("select * from definitely_missing_ruby_table") }
    assert_equal [1], @connection.values("select 1")
    assert_raises(Quack::Error) { Quack.connect(ENV.fetch("QUACK_TEST_URI"), auth_token: "wrong", timeout: 2) }
    statement = @connection.prepare('select ? as "value"')
    assert_equal [42], statement.query([42]).rows.first
    @connection.close
    refute @connection.connected?
    assert_raises(Quack::ConnectionError) { @connection.query("select 1") }
    @connection.reconnect
    assert_equal [1], @connection.values("select 1")
  end

  def test_append_rows_protocol_capabilities
    @connection.execute("create temp table ruby_append (i bigint, label varchar, amount decimal(20,6))")
    rows = [{i: 2**60, label: "é", amount: BigDecimal("42.123456")}, {i: 2, label: nil, amount: nil}]
    options = {columns: {i: "BIGINT", label: "VARCHAR", amount: "DECIMAL(20,6)"}, batch_size: 1}
    if @connection.info.fetch("quack_version") == 3
      assert_raises(Quack::UnsupportedTypeError) { @connection.append_rows("ruby_append", rows, **options) }
      assert_equal [0], @connection.values("select count(*) from ruby_append")
    else
      @connection.append_rows("ruby_append", rows, **options)
      assert_equal [[2, nil, nil], [2**60, "é", BigDecimal("42.123456")]], @connection.query("select * from ruby_append order by i").rows
    end
  end

  def test_time_zones_infinities_and_typed_parameters
    row = @connection.query("select timetz '12:34:56.123456+05:30' as tod, date 'infinity' as d, timestamp '-infinity' as ts").first
    assert_equal "12:34:56.123456+05:30:00", row.fetch("tod").to_s
    assert_equal Quack::InfiniteTemporal.new("DATE", 1), row.fetch("d")
    assert_equal Quack::InfiniteTemporal.new("TIMESTAMP", -1), row.fetch("ts")
    assert_equal [Time.at(Rational(123456789, 1_000_000)).utc], @connection.values("select ?::timestamptz", [Time.at(Rational(123456789, 1_000_000)).utc])
    assert_equal [[1, 2]], @connection.values("select ?::integer[]", [[1, 2]])
    assert_equal "1500-01-01", @connection.values("select date '1500-01-01'").first.iso8601
  end

  def test_fork_rejects_inherited_connection_and_allows_reconnect
    skip "fork unavailable" unless Process.respond_to?(:fork)
    read, write = IO.pipe
    pid = fork do
      read.close
      begin
        inherited_error = begin @connection.query("select 1"); false; rescue Quack::ForkError; true; end
        @connection.reconnect
        ok = inherited_error && @connection.values("select 42") == [42]
        @connection.close
        GC.start
        write.write(ok ? "ok" : "failed")
      rescue Exception => e
        write.write("#{e.class}: #{e.message}")
      ensure
        write.close
      end
      exit! 0
    end
    write.close
    assert_equal "ok", read.read
    Process.wait(pid)
    read.close
    assert_equal [42], @connection.values("select 42")
  end
end

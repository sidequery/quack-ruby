# quack-ruby

A direct Ruby client for DuckDB's Quack remote protocol. It uses Magnus and a
packaged, patched [quack_protocol 0.4.1](https://github.com/bnjjj/quack_protocol_rs)
over HTTP(S). The client does not embed DuckDB or use ADBC.

Supports DuckDB 1.5.5 / protocol v1 and DuckDB 2.0.0 / protocol v3. For Rails,
use [activerecord-quack-adapter](https://github.com/sidequery/activerecord-quack-adapter).

## Install

The gems are available from source; no RubyGems release or precompiled binaries
have been published. Add to your Gemfile:

```ruby
gem "quack", github: "sidequery/quack-ruby", branch: "main"
```

Requires Ruby >= 3.2, Rust >= 1.85, a C toolchain, Ruby development headers and
libclang. Bundler compiles the native extension when installing from Git.
With Boxington installed, use `CARGO=mbx bundle install`.

For a checkout:

```sh
bundle install
CARGO=mbx bundle exec rake compile
```

A Quack server must already be running. Provision databases on that server.
The client initializes its session timezone to UTC, also after reconnect.

## Usage

```ruby
require "quack"

Quack.connect(ENV.fetch("QUACK_URI"), auth_token: ENV.fetch("QUACK_TOKEN"), timeout: 30) do |connection|
  result = connection.query("select 42 as answer")
end
```

For a parameterized query, choose positional or named parameters:

```ruby
connection = Quack.connect(ENV.fetch("QUACK_URI"), auth_token: ENV.fetch("QUACK_TOKEN"))
begin
  result = connection.query("select ?::bigint as answer", [42])
  result.columns # => ["answer"]
  result.rows    # => [[42]]
  result.to_a    # => [{"answer" => 42}]

  connection.first("select :answer::bigint as answer", answer: 42)
  connection.one("select 42 as answer") # Requires exactly one row.
  connection.values("select 42")      # => [42]
  connection.execute("create temp table scratch (id integer)")

  connection.stream("select i from range(1000000) t(i)") do |stream|
    stream.each { |row| puts row.fetch("i") }
    # each_row yields arrays; each_batch yields arrays of row arrays.
  end

  statement = connection.prepare("select ?::bigint as answer")
  statement.query([42])
  connection.transaction { |c| c.execute("insert into scratch values (?)", [1]) }
  connection.info # Negotiated protocol version and server metadata.
ensure
  connection.close
end
```

Parameters/templates use client-side SQL substitution, not server-side bind
messages or a server statement cache. Quoting supports Unicode, binary strings,
NUL text, exact decimals/integers, temporal values, lists and structs. The lexer
preserves SQL strings, quoted identifiers, escaped strings, dollar-quoted
strings and nested comments. Identifiers must be quoted separately with
`Quack::SQL.identifier`.

`query` materializes all rows. `stream` fetches chunks on demand; block iteration
closes results even on early exit or exceptions. When keeping an unconsumed
stream, close it explicitly. A session permits one active result; an overlapping
operation raises `Quack::BusyError` rather than waiting indefinitely. Use a
connection per concurrent worker or an ordinary Ruby connection pool.
Duplicate result column names are preserved in `rows`; hash enumeration keeps
the last value for a repeated name.

Result conversions:

| DuckDB value | Ruby value |
| --- | --- |
| Signed/unsigned integers, including 128-bit and BIGNUM | `Integer`, without precision loss |
| Decimal | `BigDecimal` |
| Boolean, floating point, text, NULL | `true`/`false`, `Float`, `String`, `nil` |
| BLOB / other byte payloads | Binary-encoded `String` |
| Date | Proleptic Gregorian `Date` |
| Timestamp | `Quack::Timestamp < Time`, retaining SQL units, timezone kind and nanoseconds |
| Time / time with offset | `Quack::TimeOfDay` (supports `24:00:00`) |
| Interval | `Quack::Interval(months, days, microseconds)` |
| Infinite date/timestamp | `Quack::InfiniteTemporal` |
| List/array, struct | `Array`, string-keyed `Hash` |
| JSON, UUID, ENUM | `String` (Rails casts JSON to Ruby objects) |
| MAP | `Quack::Map`, with `entries`, `[]`, `each`, `to_h` |
| BIT | `Quack::BitString(bits)`, a string of logical 0/1 bits |
| GEOMETRY | `Quack::Geometry(wkb, crs)`, standard WKB and optional CRS |
| UNION | `Quack::Union(tag, value, members)`; tag distinguishes a NULL member from SQL NULL |
| VARIANT | `Quack::Variant`, with a typed `node` tree and logical Ruby `value` |
| TUPLE / unnamed STRUCT | `Quack::Tuple(values)`, preserving every ordinal field |

These logical values support SQL parameters, model assignment and native v1
append, including values nested in lists, arrays and structs. BIGNUM decoding,
DuckDB 2.0 type IDs and unnamed field handling are fixed in the packaged crate;
no separate fork download is needed to build the gem.

Read timestamps retain their SQL kind when rebound. Construct one explicitly
with `Quack::Timestamp.from(time, "TIMESTAMP_NS")` or, on DuckDB 2.0,
`Quack::Timestamp.from(time, "TIMESTAMPTZ_NS")`. Plain `Time`/`DateTime` values
use TIMESTAMPTZ when microseconds suffice and TIMESTAMP_NS when nanoseconds are
needed. Connections initialize `TimeZone = 'UTC'`, including after reconnect.
Subsequent explicit timezone changes follow DuckDB's normal cast semantics.
Values beyond a destination's precision are rejected by native append rather
than silently truncated. Rails writes preserve nine fractional digits.

`Quack::Variant.new({"items" => [1, nil, "é"]})` builds a heterogeneous value.
Use `Quack::Variant.new(value, type: "UBIGINT")` to specify a scalar type.
`variant.value` returns a Ruby tree; `variant.node` preserves each nested scalar
type. Assign a new Variant to edit it. DuckDB normalizes a root VARIANT null to
SQL NULL (`nil`); nulls inside containers remain nested nodes. Geometry uses
standard WKB rather than a client geometry engine, preserving Z/M, empty values,
collections and CRS metadata.

All storable public type families are exercised on the supported server versions.
DuckDB 1.5 cannot persist unnamed STRUCT/ROW tuples (even regular SQL INSERT fails);
their query/parameter roundtrips work, and tuple persistence is tested on 2.0.
TIMESTAMPTZ_NS is a DuckDB 2.0 type and is unavailable on 1.5. Internal/binder-only
types and types supplied by optional server extensions are not universal targets.

For protocol v1 only, the native append path is exposed:

```ruby
connection.append_rows("events", [{id: 1, name: "signup"}],
  columns: {id: "BIGINT", name: "VARCHAR"}, batch_size: 1024)
```

Append resolves destination metadata from the server, including nested types,
all-null columns, empty lists, ENUM dictionaries, case-sensitive field names and
array sizes. Optional `columns` accepts full DuckDB SQL type declarations and
must name every destination column; hash order does not change column placement.
Rows must have exactly those names. Values are checked against destination
integer ranges, decimal scale/precision and temporal units before sending any
batch. Native SEND_DATA carries the values; append does not fall back to INSERT.
Schema-qualified table names and a `schema:` option are supported in the current
catalog. Select another catalog with `USE` before appending.
Append batches are separate operations; wrap them in a transaction if atomicity
is required.

## Lifecycle and protocol limits

- v3 is preferred, with v1 fallback on a rejected handshake. Require v3 by
  setting both protocol-version bounds to 3.
- Native v3 SEND_DATA is unavailable in the underlying transport. `append_rows`
  raises `Quack::UnsupportedTypeError` on v3; SQL INSERT works on both versions.
- Sessions retain temp tables, settings and transactions. Statements are never
  replayed after a failure. Reconnect explicitly; session state is lost.
- Native network waits release the GVL but block the calling thread. They do
  not integrate with a Fiber scheduler. HTTP timeouts bound waits; there is no
  server-side cancellation API. Thread interrupts arrive when a call returns.
- Connections cannot cross forks. Create them after forking, or explicitly
  reconnect in the child. Close explicitly for deterministic cleanup; GC
  performs a bounded best-effort disconnect.
- One session permits one active result. Close or consume it before another
  operation. Use a connection per concurrent worker.
- Nested transactions/savepoints are unavailable. Append batches are separate
  operations; wrap them in a transaction when atomicity is needed.
- Errors inherit from `Quack::Error`: ConnectionError, TimeoutError, ServerError,
  ProtocolError, UnsupportedTypeError, ProxyError, BusyError and ForkError.

## Development

```sh
CARGO=mbx bundle exec rake compile
script/test
cargo fmt --manifest-path ext/quack/Cargo.toml --check
cargo fmt --manifest-path ext/quack/vendor/quack_protocol/Cargo.toml --check
mbx clippy --manifest-path ext/quack/Cargo.toml -- -D warnings
bundle exec rake package
```

`script/test` uses uv to start disposable DuckDB 1.5.5 and 2.0.0 servers, run
the integration suite and stop them. Use `DUCKDB_TEST_VERSIONS=2.0.0 script/test`
for one server version. `bundle exec rake test` without a server runs local
checks and explicitly skips integration cases.

Tests cover all storable public type families, nested logical values, exact
integers/decimals, nonfinite floats and negative zero, timestamp units/TZ,
geometry dimensions/CRS, typed NULLs, empty results, parameter rebinding,
streaming, auth/TLS, timeouts, GVL release, fork/reconnect and native v1 append.
The append matrix includes batches, all-null/empty nested values, column
ordering and rejection of invalid values before any batch is written. VARIANT
leaf families also run through SQL and native v1 append. Tests distinguish
server-version restrictions from client support.

CI is configured for Linux/macOS and Ruby 3.2, 3.3 and 3.4 using Boxington.
Source gems build at installation time. No publication/release job is enabled.

## License

MIT. The vendored Rust crate retains its own license and provenance in
`ext/quack/vendor/quack_protocol/`. The type codecs follow DuckDB's public
[BIGNUM](https://github.com/duckdb/duckdb/blob/v2.0.0/src/common/types/bignum.cpp),
[BIT](https://github.com/duckdb/duckdb/blob/v2.0.0/src/common/types/bit.cpp) and
[VARIANT](https://github.com/duckdb/duckdb/blob/v2.0.0/src/include/duckdb/common/types/variant_visitor.hpp)
formats; DuckDB's MIT notice is included in LICENSE-DuckDB.

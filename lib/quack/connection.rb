module Quack
  class Connection
    OPTIONS = %w[auth_token ssl ssl_fingerprint timeout heartbeat_timeout headers client_id client_platform client_duckdb_version min_supported_quack_version max_supported_quack_version].freeze

    def initialize(uri, **options)
      @uri = String(uri).dup.freeze
      @options = options.transform_keys(&:to_s)
      unknown = @options.keys - OPTIONS
      raise ArgumentError, "unknown connection options: #{unknown.join(', ')}" unless unknown.empty?
      @options = @options.reject { |_key, value| value.nil? }
      open_native
      @pid = Process.pid
      @in_transaction = false
    end
    def inspect = "#<#{self.class} connected=#{connected?}>"
    def info = @native.info
    def connected? = @native.connected?
    def stream(sql, parameters = nil)
      result = Stream.new(@native.query(SQL.bind(sql, parameters)))
      return result unless block_given?
      begin
        yield result
      ensure
        result.close
      end
    end
    def query(sql, parameters = nil) = stream(sql, parameters) { |result| result.to_result }
    def execute(sql, parameters = nil) = query(sql, parameters).affected_rows
    def first(sql, parameters = nil) = query(sql, parameters).first
    def one(sql, parameters = nil)
      result = query(sql, parameters)
      raise Error, "expected one row, got #{result.rows.length}" unless result.rows.length == 1
      result.first
    end
    def values(sql, parameters = nil) = query(sql, parameters).rows.map(&:first)
    def prepare(sql) = Statement.new(self, String(sql).dup.freeze)
    def append_rows(table, rows, schema: nil, columns: nil, batch_size: 1024)
      raise ArgumentError, "batch_size must be a positive Integer" unless batch_size.is_a?(Integer) && batch_size.positive?
      unless info.fetch("quack_version") == 1
        raise UnsupportedTypeError, "Quack v3 SEND_DATA is not implemented by quack_protocol; use SQL INSERT or insert_all"
      end
      return nil if rows.empty?
      table_parts = SQL.identifier_parts(table)
      raise UnsupportedTypeError, "v1 append uses the current catalog; select it with USE before appending" if table_parts.length == 3
      if table_parts.length == 2 && schema && String(schema) != table_parts[0]
        raise ArgumentError, "conflicting append schema names"
      end
      table_parts.unshift(String(schema)) if schema && table_parts.length == 1
      target = table_parts.map { |part| SQL.identifier(part) }.join(".")
      destination_sql = "select * from #{target} where false"
      destination = query(destination_sql).column_metadata
      schema_sql = if columns
        definitions = columns.transform_keys(&:to_s)
        unless definitions.keys.sort == destination.map { |column| column.fetch("name") }.sort
          raise ArgumentError, "explicit append types must name every destination column"
        end
        "select #{destination.map { |column| name = column.fetch('name'); "NULL::#{definitions.fetch(name)} AS #{SQL.identifier(name)}" }.join(', ')} where false"
      else
        destination_sql
      end
      metadata = columns ? query(schema_sql).column_metadata : destination
      expected = metadata.map { |column| column.fetch("name") }.sort
      packed = rows.map do |row|
        raise ArgumentError, "each row must be a Hash" unless row.is_a?(Hash)
        values = row.transform_keys(&:to_s)
        raise ArgumentError, "append rows must have the destination column names: #{expected.join(', ')}" unless values.keys.sort == expected
        metadata.to_h { |column| [column.fetch("name"), Quack.__pack(values.fetch(column.fetch("name")), column.fetch("duckdb_type"))] }
      end
      @native.append_rows(table_parts.last, table_parts.length == 2 ? table_parts.first : nil, packed, schema_sql, batch_size)
      nil
    end
    def close = @native.close
    alias disconnect close
    def reconnect
      close if @pid == Process.pid && connected?
      open_native
      @pid = Process.pid
      @in_transaction = false
      self
    end
    def transaction
      raise Error, "nested transactions/savepoints are not supported" if @in_transaction
      execute("BEGIN TRANSACTION")
      @in_transaction = true
      committed = false
      begin
        value = yield self
        execute("COMMIT")
        committed = true
        value
      ensure
        unless committed
          begin
            execute("ROLLBACK") if connected?
          rescue Error
            # Preserve the original failure; a transport failure never authorizes replay.
          end
        end
        @in_transaction = false
      end
    end

    private

    def open_native
      @native = NativeConnection.new(@uri, @options)
      begin
        # Ruby timestamps are UTC values. Make implicit timestamp/TZ casts
        # consistent with Rails and independent of the server host timezone.
        @native.query("SET TimeZone = 'UTC'").close
      rescue Exception
        begin
          @native.close
        rescue Error
          # Preserve the configuration failure rather than a cleanup failure.
        end
        raise
      end
    end
  end

  # Reusable client-side SQL template; Quack's prepare request carries SQL text.
  class Statement
    def initialize(connection, sql)
      @connection, @sql = connection, sql
    end
    def query(parameters = nil) = @connection.query(@sql, parameters)
    def execute(parameters = nil) = @connection.execute(@sql, parameters)
    def stream(parameters = nil, &block) = @connection.stream(@sql, parameters, &block)
  end
end

module Quack
  class Result
    include Enumerable
    attr_reader :columns, :rows, :column_metadata

    def initialize(metadata, rows)
      @column_metadata = metadata.freeze
      @columns = metadata.map { |col| col.fetch("name") }.freeze
      @rows = rows
    end
    def each
      return enum_for(__method__) unless block_given?
      rows.each { |row| yield columns.zip(row).to_h }
      self
    end
    def affected_rows
      columns == ["Count"] && rows.first&.first.is_a?(Integer) ? rows.first.first : 0
    end
  end

  class Stream
    include Enumerable
    attr_reader :column_metadata, :columns

    def initialize(native)
      @native = native
      @column_metadata = native.columns.freeze
      @columns = column_metadata.map { |col| col.fetch("name") }.freeze
      @closed = false
    end
    def each_batch
      return enum_for(__method__) unless block_given?
      begin
        while (batch = @native.next_batch)
          batch.each do |row|
            row.each_index { |index| row[index] = Codec.decode(row[index], column_metadata[index].fetch("duckdb_type")) }
          end
          yield batch
        end
      ensure
        close
      end
      self
    end
    def each_row
      return enum_for(__method__) unless block_given?
      each_batch { |batch| batch.each { |row| yield row } }
      self
    end
    def each
      return enum_for(__method__) unless block_given?
      each_row { |row| yield columns.zip(row).to_h }
      self
    end
    def close
      return if @closed
      @native.close
      @closed = true
      nil
    end
    def closed? = @closed
    def to_result = Result.new(column_metadata, each_row.to_a)
  end
end

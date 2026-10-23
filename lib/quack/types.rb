module Quack
  # Time-of-day can represent 24:00:00 and nanoseconds without inventing a date.
  TimeOfDay = Data.define(:nanoseconds, :utc_offset) do
    def to_s
      seconds, fraction = nanoseconds.divmod(1_000_000_000)
      hours, seconds = seconds.divmod(3600)
      minutes, seconds = seconds.divmod(60)
      text = format("%02d:%02d:%02d", hours, minutes, seconds)
      text += ".#{format('%09d', fraction).sub(/0+\z/, '')}" unless fraction.zero?
      unless utc_offset.nil?
        offset = utc_offset.abs
        text += format("%s%02d:%02d:%02d", utc_offset.negative? ? "-" : "+", offset / 3600, offset / 60 % 60, offset % 60)
      end
      text
    end
  end
  Interval = Data.define(:months, :days, :microseconds)
  InfiniteTemporal = Data.define(:type, :sign)

  def self.__decimal(text) = BigDecimal(text)
  def self.__date(days)
    return InfiniteTemporal.new("DATE", days.negative? ? -1 : 1) if [2**31 - 1, -(2**31 - 1)].include?(days)
    Date.new(1970, 1, 1, Date::GREGORIAN) + days
  end
  def self.__time(value, unit) = TimeOfDay.new(unit == "Micros" ? value * 1000 : value, nil)
  def self.__time_tz(bits)
    unsigned = bits & ((1 << 64) - 1)
    # DuckDB packs microseconds into the high 40 bits and a biased UTC offset
    # (16 hours minus one second minus offset seconds) into the low 24 bits.
    TimeOfDay.new((unsigned >> 24) * 1000, 57_599 - (unsigned & 0xffffff))
  end
  def self.__timestamp(value, unit, timezone_utc)
    return InfiniteTemporal.new(timezone_utc ? "TIMESTAMPTZ" : "TIMESTAMP", value.negative? ? -1 : 1) if [2**63 - 1, -(2**63 - 1)].include?(value)
    divisor = {"Seconds" => 1, "Millis" => 1000, "Micros" => 1_000_000, "Nanos" => 1_000_000_000}.fetch(unit)
    Time.at(Rational(value, divisor)).utc
  end
  def self.__interval(months, days, micros) = Interval.new(months, days, micros)

  def self.__pack(value, type) = Codec.pack(value, type)
end

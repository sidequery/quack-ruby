use chrono::NaiveDate;

use crate::errors::{QuackError, Result};
use crate::vector::{
    DateValue, DecimalValue, IntervalValue, TimeTzValue, TimeUnit, TimeValue, TimestampUnit,
    TimestampValue, Value,
};

pub fn decimal_value(value: impl ToString, width: u64, scale: u64) -> Result<Value> {
    Ok(Value::Decimal(DecimalValue {
        value: parse_decimal_value(&value.to_string(), scale)?,
        width,
        scale,
    }))
}

pub fn date_value(days: i32) -> Value {
    Value::Date(DateValue { days })
}

pub fn date_from_iso_date(value: &str) -> Result<Value> {
    let date = NaiveDate::parse_from_str(value, "%Y-%m-%d")
        .map_err(|_| QuackError::protocol(format!("invalid ISO date {value}")))?;
    let epoch = NaiveDate::from_ymd_opt(1970, 1, 1).expect("valid epoch");
    Ok(date_value((date - epoch).num_days() as i32))
}

pub fn time_value(value: i64, unit: TimeUnit) -> Value {
    Value::Time(TimeValue { unit, value })
}

pub fn time_tz_value(bits: i64) -> Value {
    Value::TimeTz(TimeTzValue { bits })
}

pub fn timestamp_value(value: i64, unit: TimestampUnit, timezone_utc: bool) -> Value {
    Value::Timestamp(TimestampValue {
        unit,
        value,
        timezone_utc,
    })
}

pub fn interval_value(months: i32, days: i32, micros: i64) -> Value {
    Value::Interval(IntervalValue {
        months,
        days,
        micros,
    })
}

fn parse_decimal_value(value: &str, scale: u64) -> Result<i128> {
    let text = value.trim();
    let negative = text.starts_with('-');
    let unsigned = text.strip_prefix(['-', '+']).unwrap_or(text);
    let (integer, fraction) = unsigned.split_once('.').unwrap_or((unsigned, ""));
    if !integer.bytes().all(|byte| byte.is_ascii_digit())
        || !fraction.bytes().all(|byte| byte.is_ascii_digit())
    {
        return Err(QuackError::protocol(format!(
            "invalid decimal value {value}"
        )));
    }
    let mut padded_fraction = fraction.to_string();
    while padded_fraction.len() < scale as usize {
        padded_fraction.push('0');
    }
    padded_fraction.truncate(scale as usize);
    let unscaled = format!(
        "{}{}",
        if integer.is_empty() { "0" } else { integer },
        padded_fraction
    )
    .parse::<i128>()
    .map_err(|_| QuackError::protocol(format!("invalid decimal value {value}")))?;
    Ok(if negative { -unscaled } else { unscaled })
}

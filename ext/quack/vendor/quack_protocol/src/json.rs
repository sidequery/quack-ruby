use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use serde_json::{Map, Number, Value as JsonValue, json};

use crate::errors::{QuackError, Result};
use crate::vector::{Row, TimeUnit, TimestampUnit, Value, decimal_to_string};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BigIntJsonMode {
    String,
    Number,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BytesJsonMode {
    Base64,
    Hex,
    Array,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TaggedJsonMode {
    Default,
    Tagged,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct JsonOptions {
    pub bigint: BigIntJsonMode,
    pub bytes: BytesJsonMode,
    pub decimal: TaggedJsonMode,
    pub date: TaggedJsonMode,
    pub time: TaggedJsonMode,
    pub timestamp: TaggedJsonMode,
}

impl Default for JsonOptions {
    fn default() -> Self {
        Self {
            bigint: BigIntJsonMode::String,
            bytes: BytesJsonMode::Base64,
            decimal: TaggedJsonMode::Default,
            date: TaggedJsonMode::Default,
            time: TaggedJsonMode::Default,
            timestamp: TaggedJsonMode::Default,
        }
    }
}

pub fn to_json_value(value: &Value, options: JsonOptions) -> Result<JsonValue> {
    Ok(match value {
        Value::Null => JsonValue::Null,
        Value::Bool(value) => JsonValue::Bool(*value),
        Value::Int(value) => bigint_to_json(*value as i128, options.bigint)?,
        Value::UInt(value) => unsigned_bigint_to_json(*value as u128, options.bigint)?,
        Value::HugeInt(value) => bigint_to_json(*value, options.bigint)?,
        Value::UHugeInt(value) => unsigned_bigint_to_json(*value, options.bigint)?,
        Value::Float(value) => Number::from_f64(*value as f64)
            .map(JsonValue::Number)
            .unwrap_or(JsonValue::Null),
        Value::Double(value) => Number::from_f64(*value)
            .map(JsonValue::Number)
            .unwrap_or(JsonValue::Null),
        Value::String(value) => JsonValue::String(value.clone()),
        Value::Bytes(value) => bytes_to_json(value, options.bytes),
        Value::Decimal(value) => match options.decimal {
            TaggedJsonMode::Tagged => json!({
                "kind": "decimal",
                "value": value.value.to_string(),
                "width": value.width,
                "scale": value.scale
            }),
            TaggedJsonMode::Default => JsonValue::String(decimal_to_string(value)),
        },
        Value::Date(value) => match options.date {
            TaggedJsonMode::Tagged => json!({ "kind": "date", "days": value.days }),
            TaggedJsonMode::Default => JsonValue::String(date_to_iso(value.days)),
        },
        Value::Time(value) => match options.time {
            TaggedJsonMode::Tagged => json!({
                "kind": "time",
                "unit": match value.unit { TimeUnit::Micros => "micros", TimeUnit::Nanos => "nanos" },
                "value": value.value.to_string()
            }),
            TaggedJsonMode::Default => JsonValue::String(time_to_string(value.value, value.unit)),
        },
        Value::TimeTz(value) => json!({ "kind": "time_tz", "bits": value.bits.to_string() }),
        Value::Timestamp(value) => match options.timestamp {
            TaggedJsonMode::Tagged => {
                let unit = match value.unit {
                    TimestampUnit::Seconds => "seconds",
                    TimestampUnit::Millis => "millis",
                    TimestampUnit::Micros => "micros",
                    TimestampUnit::Nanos => "nanos",
                };
                if value.timezone_utc {
                    json!({ "kind": "timestamp", "unit": unit, "value": value.value.to_string(), "timezone": "utc" })
                } else {
                    json!({ "kind": "timestamp", "unit": unit, "value": value.value.to_string() })
                }
            }
            TaggedJsonMode::Default => {
                JsonValue::String(timestamp_to_iso(value.value, value.unit)?)
            }
        },
        Value::Interval(value) => json!({
            "kind": "interval",
            "months": value.months,
            "days": value.days,
            "micros": value.micros.to_string()
        }),
        Value::List(values) => JsonValue::Array(
            values
                .iter()
                .map(|value| to_json_value(value, options))
                .collect::<Result<Vec<_>>>()?,
        ),
        Value::Struct(row) => {
            let mut object = Map::new();
            for (key, value) in row {
                object.insert(key.clone(), to_json_value(value, options)?);
            }
            JsonValue::Object(object)
        }
    })
}

pub fn to_json_row(row: &Row, options: JsonOptions) -> Result<JsonValue> {
    let mut object = Map::new();
    for (key, value) in row {
        object.insert(key.clone(), to_json_value(value, options)?);
    }
    Ok(JsonValue::Object(object))
}

pub fn to_json_rows(rows: &[Row], options: JsonOptions) -> Result<Vec<JsonValue>> {
    rows.iter().map(|row| to_json_row(row, options)).collect()
}

fn bigint_to_json(value: i128, mode: BigIntJsonMode) -> Result<JsonValue> {
    match mode {
        BigIntJsonMode::String => Ok(JsonValue::String(value.to_string())),
        BigIntJsonMode::Number => i64::try_from(value)
            .ok()
            .map(Number::from)
            .map(JsonValue::Number)
            .ok_or_else(|| {
                QuackError::protocol(format!("bigint value {value} exceeds JSON number range"))
            }),
    }
}

fn unsigned_bigint_to_json(value: u128, mode: BigIntJsonMode) -> Result<JsonValue> {
    match mode {
        BigIntJsonMode::String => Ok(JsonValue::String(value.to_string())),
        BigIntJsonMode::Number => u64::try_from(value)
            .ok()
            .map(|value| JsonValue::Number(Number::from(value)))
            .ok_or_else(|| {
                QuackError::protocol(format!("bigint value {value} exceeds JSON number range"))
            }),
    }
}

fn bytes_to_json(value: &[u8], mode: BytesJsonMode) -> JsonValue {
    match mode {
        BytesJsonMode::Base64 => JsonValue::String(STANDARD.encode(value)),
        BytesJsonMode::Hex => {
            JsonValue::String(value.iter().map(|byte| format!("{byte:02x}")).collect())
        }
        BytesJsonMode::Array => JsonValue::Array(value.iter().map(|byte| json!(byte)).collect()),
    }
}

fn date_to_iso(days: i32) -> String {
    let epoch = chrono::NaiveDate::from_ymd_opt(1970, 1, 1).expect("valid epoch");
    (epoch + chrono::Duration::days(days as i64))
        .format("%Y-%m-%d")
        .to_string()
}

fn time_to_string(value: i64, unit: TimeUnit) -> String {
    let nanos = match unit {
        TimeUnit::Micros => value as i128 * 1_000,
        TimeUnit::Nanos => value as i128,
    };
    let total_seconds = nanos.div_euclid(1_000_000_000);
    let fraction = nanos.rem_euclid(1_000_000_000);
    let hours = total_seconds / 3_600;
    let minutes = (total_seconds % 3_600) / 60;
    let seconds = total_seconds % 60;
    let fraction_text = if fraction == 0 {
        String::new()
    } else {
        format!(".{:09}", fraction)
            .trim_end_matches('0')
            .to_string()
    };
    format!("{hours:02}:{minutes:02}:{seconds:02}{fraction_text}")
}

fn timestamp_to_iso(value: i64, unit: TimestampUnit) -> Result<String> {
    let nanos = match unit {
        TimestampUnit::Seconds => value as i128 * 1_000_000_000,
        TimestampUnit::Millis => value as i128 * 1_000_000,
        TimestampUnit::Micros => value as i128 * 1_000,
        TimestampUnit::Nanos => value as i128,
    };
    let seconds = nanos.div_euclid(1_000_000_000);
    let fraction = nanos.rem_euclid(1_000_000_000);
    let datetime = chrono::DateTime::from_timestamp(seconds as i64, fraction as u32)
        .ok_or_else(|| QuackError::protocol(format!("timestamp value {value} is outside range")))?;
    let fraction_text = if fraction == 0 {
        String::new()
    } else {
        format!(".{:09}", fraction)
            .trim_end_matches('0')
            .to_string()
    };
    Ok(format!(
        "{}{}Z",
        datetime.format("%Y-%m-%dT%H:%M:%S"),
        fraction_text
    ))
}

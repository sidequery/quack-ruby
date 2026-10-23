use indexmap::IndexMap;

use crate::errors::{QuackError, Result};
use crate::logical_types::{
    ChildType, LogicalType, LogicalTypeId, LogicalTypes, get_child_type, get_struct_children,
    struct_child_key,
};
use crate::vector::{DataChunk, DecodedVector, TimeUnit, TimestampUnit, Value, VectorType};

#[derive(Clone, Debug, PartialEq)]
pub struct ColumnInput {
    pub name: Option<String>,
    pub logical_type: LogicalType,
    pub values: Vec<Value>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ColumnDefinition {
    pub name: String,
    pub logical_type: LogicalType,
}

pub fn column(
    logical_type: LogicalType,
    values: impl IntoIterator<Item = Value>,
    name: impl Into<Option<String>>,
) -> ColumnInput {
    ColumnInput {
        name: name.into(),
        logical_type,
        values: values.into_iter().collect(),
    }
}

pub fn data_chunk(columns: Vec<ColumnInput>) -> Result<DataChunk> {
    if columns.is_empty() {
        return Err(QuackError::protocol(
            "a Quack DataChunk must contain at least one column",
        ));
    }
    let row_count = columns[0].values.len();
    let mut types = Vec::with_capacity(columns.len());
    let mut decoded_columns = Vec::with_capacity(columns.len());
    let mut names = Vec::with_capacity(columns.len());

    for (index, input) in columns.into_iter().enumerate() {
        if input.values.len() != row_count {
            return Err(QuackError::protocol(format!(
                "column {index} has {} values, expected {row_count}",
                input.values.len()
            )));
        }
        names.push(input.name.unwrap_or_else(|| format!("column{index}")));
        types.push(input.logical_type.clone());
        decoded_columns.push(DecodedVector {
            logical_type: input.logical_type,
            vector_type: VectorType::Flat,
            values: input.values,
        });
    }

    Ok(DataChunk {
        row_count,
        types,
        columns: decoded_columns,
        column_names: Some(names),
    })
}

pub fn data_chunk_from_rows(
    rows: &[IndexMap<String, Value>],
    columns: Option<Vec<ColumnDefinition>>,
) -> Result<DataChunk> {
    let definitions = match columns {
        Some(columns) => columns,
        None => infer_column_definitions(rows)?,
    };
    let inputs = definitions
        .iter()
        .map(|definition| {
            let values = rows
                .iter()
                .map(|row| {
                    normalize_append_value(
                        row.get(&definition.name).cloned().unwrap_or(Value::Null),
                        &definition.logical_type,
                    )
                })
                .collect::<Result<Vec<_>>>()?;
            Ok(ColumnInput {
                name: Some(definition.name.clone()),
                logical_type: definition.logical_type.clone(),
                values,
            })
        })
        .collect::<Result<Vec<_>>>()?;
    data_chunk(inputs)
}

fn infer_column_definitions(rows: &[IndexMap<String, Value>]) -> Result<Vec<ColumnDefinition>> {
    let first = rows.first().ok_or_else(|| {
        QuackError::protocol("cannot infer append row columns from an empty row set")
    })?;
    first
        .keys()
        .map(|name| {
            Ok(ColumnDefinition {
                name: name.clone(),
                logical_type: infer_logical_type(
                    &rows
                        .iter()
                        .map(|row| row.get(name).cloned().unwrap_or(Value::Null))
                        .collect::<Vec<_>>(),
                )?,
            })
        })
        .collect()
}

fn infer_logical_type(values: &[Value]) -> Result<LogicalType> {
    let value = values
        .iter()
        .find(|value| !value.is_null())
        .ok_or_else(|| QuackError::protocol("cannot infer logical type from only null values"))?;
    Ok(match value {
        Value::Null => unreachable!(),
        Value::Bool(_) => LogicalTypes::boolean(),
        Value::Int(value) if *value >= i32::MIN as i64 && *value <= i32::MAX as i64 => {
            LogicalTypes::integer()
        }
        Value::Int(_) => LogicalTypes::bigint(),
        Value::UInt(value) if *value <= u32::MAX as u64 => LogicalTypes::uinteger(),
        Value::UInt(_) => LogicalTypes::ubigint(),
        Value::HugeInt(_) => LogicalTypes::hugeint(),
        Value::UHugeInt(_) => LogicalTypes::uhugeint(),
        Value::Float(_) => LogicalTypes::float(),
        Value::Double(_) => LogicalTypes::double(),
        Value::String(_) => LogicalTypes::varchar(),
        Value::Bytes(_) => LogicalTypes::blob(),
        Value::Decimal(value) => LogicalTypes::decimal(value.width, value.scale),
        Value::Date(_) => LogicalTypes::date(),
        Value::Time(value) => match value.unit {
            TimeUnit::Micros => LogicalTypes::time(),
            TimeUnit::Nanos => LogicalTypes::time_ns(),
        },
        Value::TimeTz(_) => LogicalTypes::time_tz(),
        Value::Timestamp(value) => match value.unit {
            TimestampUnit::Seconds => LogicalTypes::timestamp_seconds(),
            TimestampUnit::Millis => LogicalTypes::timestamp_millis(),
            TimestampUnit::Micros if value.timezone_utc => LogicalTypes::timestamp_tz(),
            TimestampUnit::Micros => LogicalTypes::timestamp(),
            TimestampUnit::Nanos => LogicalTypes::timestamp_nanos(),
        },
        Value::Interval(_) => LogicalTypes::interval(),
        Value::List(items) => LogicalTypes::list(infer_logical_type(items)?),
        Value::Struct(row) => LogicalTypes::r#struct(
            row.keys()
                .map(|name| {
                    let child_values = values
                        .iter()
                        .map(|value| match value {
                            Value::Struct(row) => row.get(name).cloned().unwrap_or(Value::Null),
                            _ => Value::Null,
                        })
                        .collect::<Vec<_>>();
                    Ok(ChildType {
                        name: name.clone(),
                        logical_type: infer_logical_type(&child_values)?,
                    })
                })
                .collect::<Result<Vec<_>>>()?,
        ),
    })
}

fn normalize_append_value(value: Value, logical_type: &LogicalType) -> Result<Value> {
    if value.is_null() {
        return Ok(Value::Null);
    }
    match value {
        Value::List(values)
            if matches!(
                logical_type.id,
                LogicalTypeId::List | LogicalTypeId::Map | LogicalTypeId::Array
            ) =>
        {
            let child_type = get_child_type(logical_type)?;
            Ok(Value::List(
                values
                    .into_iter()
                    .map(|value| normalize_append_value(value, child_type))
                    .collect::<Result<Vec<_>>>()?,
            ))
        }
        Value::Struct(row)
            if matches!(
                logical_type.id,
                LogicalTypeId::Struct | LogicalTypeId::Tuple
            ) =>
        {
            let children = get_struct_children(logical_type)?;
            let mut normalized = IndexMap::new();
            for (index, child) in children.iter().enumerate() {
                let key = struct_child_key(logical_type, index, child);
                normalized.insert(
                    key.clone(),
                    normalize_append_value(
                        row.get(&key).cloned().unwrap_or(Value::Null),
                        &child.logical_type,
                    )?,
                );
            }
            Ok(Value::Struct(normalized))
        }
        other => Ok(other),
    }
}

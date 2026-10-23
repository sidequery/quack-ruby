use futures_util::{StreamExt, stream::BoxStream};
use magnus::{Error, IntoValue, RArray, RHash, RModule, Ruby, Value, function, method, prelude::*};
use quack_protocol::{
    ColumnDefinition, DataChunk, ExtraTypeInfo, LogicalType, QuackClient, QuackClientOptions,
    QuackError, Row, Value as QValue,
};
use std::{
    ffi::c_void,
    mem::ManuallyDrop,
    panic::{AssertUnwindSafe, catch_unwind},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};
use tokio::runtime::Runtime;

// Ruby unwinding is contained by protect; Rust unwinding is contained by the
// callback. No Ruby value or API is touched while the GVL is released.
fn without_gvl<T: Send, F: FnOnce() -> T + Send>(ruby: &Ruby, operation: F) -> Result<T, Error> {
    struct Call<F, T> {
        operation: Option<F>,
        result: Option<std::thread::Result<T>>,
    }
    unsafe extern "C" fn run<F: FnOnce() -> T, T>(data: *mut c_void) -> *mut c_void {
        let call = unsafe { &mut *data.cast::<Call<F, T>>() };
        call.result = Some(catch_unwind(AssertUnwindSafe(|| {
            (call.operation.take().unwrap())()
        })));
        std::ptr::null_mut()
    }
    let mut call = Call {
        operation: Some(operation),
        result: None,
    };
    magnus::rb_sys::protect(|| {
        unsafe {
            rb_sys::rb_thread_call_without_gvl(
                Some(run::<F, T>),
                (&mut call as *mut Call<F, T>).cast(),
                None,
                std::ptr::null_mut(),
            );
        }
        0
    })?;
    match call.result {
        Some(Ok(value)) => Ok(value),
        _ => Err(Error::new(
            ruby.exception_runtime_error(),
            "native Quack operation panicked",
        )),
    }
}
fn error(ruby: &Ruby, name: &str, message: impl Into<String>) -> Error {
    let class = ruby
        .class_object()
        .const_get::<_, RModule>("Quack")
        .unwrap()
        .const_get(name)
        .unwrap();
    Error::new(class, message.into())
}
fn protocol_error(ruby: &Ruby, err: QuackError) -> Error {
    let name = match &err {
        QuackError::Http(e) if e.is_timeout() => "TimeoutError",
        QuackError::Http(_) | QuackError::Url(_) => "ConnectionError",
        QuackError::Server(_) => "ServerError",
        QuackError::UnsupportedType(_) => "UnsupportedTypeError",
        QuackError::Proxy(_) => "ProxyError",
        _ => "ProtocolError",
    };
    error(ruby, name, err.to_string())
}
struct Session {
    client: QuackClient,
    runtime: Option<Runtime>,
    active: AtomicBool,
    fatal: AtomicBool,
}
struct Admission<'a> {
    active: &'a AtomicBool,
    release: bool,
}
impl Drop for Admission<'_> {
    fn drop(&mut self) {
        if self.release {
            self.active.store(false, Ordering::Release);
        }
    }
}
impl Session {
    fn runtime(&self) -> &Runtime {
        self.runtime.as_ref().unwrap()
    }
    fn check(&self, ruby: &Ruby) -> Result<(), Error> {
        if self.fatal.load(Ordering::Acquire) || !self.client.is_connected() {
            return Err(error(
                ruby,
                "ConnectionError",
                "connection is closed or failed; reconnect explicitly",
            ));
        }
        Ok(())
    }
    fn admit(&self, ruby: &Ruby) -> Result<Admission<'_>, Error> {
        if self.active.swap(true, Ordering::AcqRel) {
            return Err(error(
                ruby,
                "BusyError",
                "consume or close the active result before another operation",
            ));
        }
        Ok(Admission {
            active: &self.active,
            release: true,
        })
    }
    fn map<T>(&self, ruby: &Ruby, result: Result<T, QuackError>) -> Result<T, Error> {
        result.map_err(|err| {
            if err.is_connection_fatal() {
                self.fatal.store(true, Ordering::Release);
            }
            protocol_error(ruby, err)
        })
    }
}
impl Drop for Session {
    fn drop(&mut self) {
        if let Some(runtime) = self.runtime.take() {
            // GC must not block Ruby. The cleanup thread owns the runtime until
            // a bounded DISCONNECT completes. Explicit #close reports errors.
            struct CleanupRuntime(Option<Runtime>);
            impl Drop for CleanupRuntime {
                fn drop(&mut self) {
                    if let Some(runtime) = self.0.take() {
                        runtime.shutdown_background();
                    }
                }
            }
            let runtime = CleanupRuntime(Some(runtime));
            let client = self.client.clone();
            let _ = std::thread::Builder::new()
                .name("quack-cleanup".into())
                .spawn(move || {
                    runtime.0.as_ref().unwrap().block_on(async {
                        let _ =
                            tokio::time::timeout(Duration::from_secs(2), client.disconnect()).await;
                    });
                });
        }
    }
}
#[magnus::wrap(class = "Quack::NativeConnection", free_immediately, size)]
struct NativeConnection {
    session: ManuallyDrop<Arc<Session>>,
    pid: u32,
}
impl Drop for NativeConnection {
    fn drop(&mut self) {
        // A fork inherits Tokio's locks but not its worker threads. Never touch
        // or destroy inherited runtime state in the child process.
        if self.pid == std::process::id() {
            unsafe {
                ManuallyDrop::drop(&mut self.session);
            }
        }
    }
}
impl NativeConnection {
    fn check_pid(&self, ruby: &Ruby) -> Result<(), Error> {
        if self.pid != std::process::id() {
            return Err(error(
                ruby,
                "ForkError",
                "Quack connections cannot cross fork; reconnect in the child",
            ));
        }
        Ok(())
    }
    fn connect(ruby: &Ruby, uri: String, options: RHash) -> Result<Self, Error> {
        let mut opts = QuackClientOptions {
            auth_token: options.lookup("auth_token")?,
            ssl_fingerprint: options.lookup("ssl_fingerprint")?,
            ssl: options.lookup("ssl")?,
            client_id: options.lookup("client_id")?,
            client_duckdb_version: options.lookup("client_duckdb_version")?,
            client_platform: options.lookup("client_platform")?,
            min_supported_quack_version: options.lookup("min_supported_quack_version")?,
            max_supported_quack_version: options.lookup("max_supported_quack_version")?,
            ..Default::default()
        };
        for key in ["timeout", "heartbeat_timeout"] {
            if let Some(seconds) = options.lookup::<_, Option<f64>>(key)? {
                if !seconds.is_finite() || seconds <= 0.0 {
                    return Err(Error::new(
                        ruby.exception_arg_error(),
                        format!("{key} must be a positive finite number"),
                    ));
                }
                let duration = Duration::try_from_secs_f64(seconds)
                    .map_err(|_| Error::new(ruby.exception_arg_error(), "duration out of range"))?;
                if key == "timeout" {
                    opts.timeout = Some(duration);
                } else {
                    opts.heartbeat_timeout = Some(duration);
                }
            }
        }
        if let Some(headers) = options.lookup::<_, Option<RHash>>("headers")? {
            headers.foreach(|key: String, value: String| {
                opts.headers.push((key, value));
                Ok(magnus::r_hash::ForEach::Continue)
            })?;
        }
        let (runtime, client) = without_gvl(ruby, move || {
            let runtime = tokio::runtime::Builder::new_multi_thread()
                .worker_threads(1)
                .enable_all()
                .build()
                .map_err(|e| QuackError::Protocol(e.to_string()))?;
            let client = runtime.block_on(QuackClient::connect(&uri, opts))?;
            Ok::<_, QuackError>((runtime, client))
        })?
        .map_err(|e| protocol_error(ruby, e))?;
        Ok(Self {
            session: ManuallyDrop::new(Arc::new(Session {
                client,
                runtime: Some(runtime),
                active: AtomicBool::new(false),
                fatal: AtomicBool::new(false),
            })),
            pid: std::process::id(),
        })
    }
    fn connected(&self) -> bool {
        self.pid == std::process::id()
            && !self.session.fatal.load(Ordering::Acquire)
            && self.session.client.is_connected()
    }
    fn info(&self) -> Result<RHash, Error> {
        let ruby = &Ruby::get().unwrap();
        self.check_pid(ruby)?;
        let hash = ruby.hash_new();
        if let Some(info) = &self.session.client.info {
            hash.aset("quack_version", info.quack_version)?;
            hash.aset("server_version", info.server_duckdb_version.clone())?;
            hash.aset("server_platform", info.server_platform.clone())?;
            hash.aset(
                "heartbeat_timeout",
                info.heartbeat_timeout.map(|v| v.as_secs_f64()),
            )?;
        }
        Ok(hash)
    }
    fn query(&self, sql: String) -> Result<NativeStream, Error> {
        let ruby = &Ruby::get().unwrap();
        self.check_pid(ruby)?;
        self.session.check(ruby)?;
        let mut admission = self.session.admit(ruby)?;
        let result = without_gvl(ruby, || {
            self.session
                .runtime()
                .block_on(self.session.client.query(&sql, None))
        })?;
        let (columns, stream) = self.session.map(ruby, result)?.into_chunks();
        let stream = NativeStream {
            session: ManuallyDrop::new(Arc::clone(&self.session)),
            stream: ManuallyDrop::new(Mutex::new(Some(stream))),
            columns,
            pid: self.pid,
            closed: AtomicBool::new(false),
        };
        admission.release = false;
        Ok(stream)
    }
    fn append_rows(
        &self,
        table: String,
        schema: Option<String>,
        rows: RArray,
        schema_sql: String,
        batch_size: usize,
    ) -> Result<(), Error> {
        let ruby = &Ruby::get().unwrap();
        self.check_pid(ruby)?;
        self.session.check(ruby)?;
        if self
            .session
            .client
            .info
            .as_ref()
            .and_then(|info| info.quack_version)
            != Some(1)
        {
            return Err(error(
                ruby,
                "UnsupportedTypeError",
                "Quack v3 SEND_DATA is not implemented by quack_protocol; use SQL INSERT or insert_all",
            ));
        }
        if batch_size == 0 {
            return Err(Error::new(
                ruby.exception_arg_error(),
                "batch_size must be positive",
            ));
        }
        let mut owned_rows = Vec::with_capacity(rows.len());
        for index in 0..rows.len() {
            let row: RHash = rows.entry(index as isize)?;
            let mut owned = Row::new();
            row.foreach(|key: String, value: RArray| {
                owned.insert(key, from_packed(ruby, value)?);
                Ok(magnus::r_hash::ForEach::Continue)
            })?;
            owned_rows.push(owned);
        }
        let _admission = self.session.admit(ruby)?;
        let result = without_gvl(ruby, || {
            self.session.runtime().block_on(async {
                // Resolve complete nested/ENUM/UNION metadata using DuckDB's
                // parser, including user-defined types and case-sensitive names.
                let (columns, stream) = self
                    .session
                    .client
                    .query(&schema_sql, None)
                    .await?
                    .into_chunks();
                drop(stream);
                self.session
                    .client
                    .append_rows(table, schema, &owned_rows, Some(columns), Some(batch_size))
                    .await
            })
        })?;
        self.session.map(ruby, result)
    }
    fn close(&self) -> Result<(), Error> {
        let ruby = &Ruby::get().unwrap();
        self.check_pid(ruby)?;
        let _admission = self.session.admit(ruby)?;
        let result = without_gvl(ruby, || {
            self.session
                .runtime()
                .block_on(self.session.client.disconnect())
        })?;
        self.session.map(ruby, result)
    }
}
type ChunkStream = BoxStream<'static, Result<DataChunk, QuackError>>;

#[magnus::wrap(class = "Quack::NativeStream", free_immediately, size)]
struct NativeStream {
    session: ManuallyDrop<Arc<Session>>,
    stream: ManuallyDrop<Mutex<Option<ChunkStream>>>,
    columns: Vec<ColumnDefinition>,
    pid: u32,
    closed: AtomicBool,
}
impl NativeStream {
    fn columns(&self) -> Result<RArray, Error> {
        let ruby = &Ruby::get().unwrap();
        let array = ruby.ary_new();
        for col in &self.columns {
            let hash = ruby.hash_new();
            hash.aset("name", col.name.as_str())?;
            hash.aset("type", format!("{:?}", col.logical_type.id))?;
            hash.aset("logical_type", format!("{:?}", col.logical_type))?;
            hash.aset("duckdb_type", type_metadata(ruby, &col.logical_type)?)?;
            if let Some(info) = &col.logical_type.type_info {
                hash.aset("alias", info.alias())?;
                if let ExtraTypeInfo::Decimal { width, scale, .. } = info {
                    hash.aset("precision", *width)?;
                    hash.aset("scale", *scale)?;
                }
            }
            array.push(hash)?;
        }
        Ok(array)
    }
    fn close(&self) -> Result<(), Error> {
        let ruby = &Ruby::get().unwrap();
        if self.pid != std::process::id() {
            return Err(error(
                ruby,
                "ForkError",
                "result belongs to the parent process",
            ));
        }
        if self.closed.load(Ordering::Acquire) {
            return Ok(());
        }
        let mut stream = self
            .stream
            .try_lock()
            .map_err(|_| error(ruby, "BusyError", "result is being read by another thread"))?;
        stream.take();
        self.closed.store(true, Ordering::Release);
        self.session.active.store(false, Ordering::Release);
        Ok(())
    }
    fn next_batch(&self) -> Result<Option<RArray>, Error> {
        let ruby = &Ruby::get().unwrap();
        if self.pid != std::process::id() {
            return Err(error(
                ruby,
                "ForkError",
                "result belongs to the parent process",
            ));
        }
        if self.closed.load(Ordering::Acquire) {
            return Ok(None);
        }
        let result = without_gvl(ruby, || {
            let mut guard = self.stream.try_lock().map_err(|_| ())?;
            let next = match guard.as_mut() {
                Some(stream) => self.session.runtime().block_on(stream.next()),
                None => None,
            };
            if next.is_none() || next.as_ref().is_some_and(Result::is_err) {
                guard.take();
                self.closed.store(true, Ordering::Release);
                self.session.active.store(false, Ordering::Release);
            }
            Ok::<_, ()>(next)
        })?
        .map_err(|_| error(ruby, "BusyError", "result is being read by another thread"))?;
        match result {
            None => Ok(None),
            Some(result) => {
                let chunk = self.session.map(ruby, result)?;
                let rows = ruby.ary_new_capa(chunk.row_count);
                for row_index in 0..chunk.row_count {
                    let row = ruby.ary_new_capa(self.columns.len());
                    for col_index in 0..self.columns.len() {
                        let value = &chunk
                            .column_values(col_index)
                            .ok_or_else(|| error(ruby, "ProtocolError", "missing chunk column"))?
                            [row_index];
                        row.push(to_ruby(ruby, value)?)?;
                    }
                    rows.push(row)?;
                }
                Ok(Some(rows))
            }
        }
    }
}
impl Drop for NativeStream {
    fn drop(&mut self) {
        if self.pid == std::process::id() {
            // An old finished stream must not clear the next query's flag.
            if !self.closed.load(Ordering::Acquire) {
                self.session.active.store(false, Ordering::Release);
            }
            unsafe {
                ManuallyDrop::drop(&mut self.stream);
                ManuallyDrop::drop(&mut self.session);
            }
        }
    }
}
fn type_metadata(ruby: &Ruby, logical_type: &LogicalType) -> Result<RHash, Error> {
    let metadata = ruby.hash_new();
    metadata.aset("id", format!("{:?}", logical_type.id))?;
    if let Some(info) = &logical_type.type_info {
        metadata.aset("alias", info.alias())?;
        match info {
            ExtraTypeInfo::Decimal { width, scale, .. } => {
                metadata.aset("width", *width)?;
                metadata.aset("scale", *scale)?;
            }
            ExtraTypeInfo::List { child_type, .. } | ExtraTypeInfo::Array { child_type, .. } => {
                metadata.aset("child", type_metadata(ruby, child_type)?)?;
                if let ExtraTypeInfo::Array { size, .. } = info {
                    metadata.aset("size", *size)?;
                }
            }
            ExtraTypeInfo::Struct { child_types, .. } => {
                let children = ruby.ary_new();
                for child in child_types {
                    let entry = ruby.hash_new();
                    entry.aset("name", child.name.as_str())?;
                    entry.aset("type", type_metadata(ruby, &child.logical_type)?)?;
                    children.push(entry)?;
                }
                metadata.aset("children", children)?;
            }
            ExtraTypeInfo::Enum { values, .. } => {
                metadata.aset("values", values.clone())?;
            }
            ExtraTypeInfo::Geo { crs, .. } => {
                metadata.aset("crs", crs.definition.as_deref())?;
            }
            _ => {}
        }
    }
    Ok(metadata)
}

fn to_ruby(ruby: &Ruby, value: &QValue) -> Result<Value, Error> {
    let module: RModule = ruby.class_object().const_get("Quack")?;
    Ok(match value {
        QValue::Null => ruby.qnil().as_value(),
        QValue::Bool(v) => (*v).into_value_with(ruby),
        QValue::Int(v) => ruby.integer_from_i64(*v).as_value(),
        QValue::UInt(v) => ruby.integer_from_u64(*v).as_value(),
        QValue::HugeInt(v) => ruby.integer_from_i128(*v).as_value(),
        QValue::UHugeInt(v) => ruby.integer_from_u128(*v).as_value(),
        QValue::Float(v) => (*v as f64).into_value_with(ruby),
        QValue::Double(v) => (*v).into_value_with(ruby),
        QValue::String(v) => ruby.str_new(v).as_value(),
        QValue::Bytes(v) => ruby.str_from_slice(v).as_value(),
        QValue::Decimal(v) => {
            module.funcall("__decimal", (quack_protocol::decimal_to_string(v),))?
        }
        QValue::Date(v) => module.funcall("__date", (v.days,))?,
        QValue::Time(v) => module.funcall("__time", (v.value, format!("{:?}", v.unit)))?,
        QValue::TimeTz(v) => module.funcall("__time_tz", (v.bits,))?,
        QValue::Timestamp(v) => module.funcall(
            "__timestamp",
            (v.value, format!("{:?}", v.unit), v.timezone_utc),
        )?,
        QValue::Interval(v) => module.funcall("__interval", (v.months, v.days, v.micros))?,
        QValue::List(values) => {
            let out = ruby.ary_new_capa(values.len());
            for value in values {
                out.push(to_ruby(ruby, value)?)?;
            }
            out.as_value()
        }
        QValue::Struct(values) => {
            let out = ruby.hash_new();
            for (key, value) in values {
                out.aset(key.as_str(), to_ruby(ruby, value)?)?;
            }
            out.as_value()
        }
    })
}
#[magnus::init(name = "quack_native")]
fn init(ruby: &Ruby) -> Result<(), Error> {
    let module = ruby.define_module("Quack")?;
    let base = module.define_error("Error", ruby.exception_standard_error())?;
    for name in [
        "ConnectionError",
        "TimeoutError",
        "ServerError",
        "ProtocolError",
        "UnsupportedTypeError",
        "ProxyError",
        "BusyError",
        "ForkError",
    ] {
        module.define_error(name, base)?;
    }
    let connection = module.define_class("NativeConnection", ruby.class_object())?;
    connection.define_singleton_method("new", function!(NativeConnection::connect, 2))?;
    connection.define_method("query", method!(NativeConnection::query, 1))?;
    connection.define_method("append_rows", method!(NativeConnection::append_rows, 5))?;
    connection.define_method("close", method!(NativeConnection::close, 0))?;
    connection.define_method("connected?", method!(NativeConnection::connected, 0))?;
    connection.define_method("info", method!(NativeConnection::info, 0))?;
    let stream = module.define_class("NativeStream", ruby.class_object())?;
    stream.define_method("columns", method!(NativeStream::columns, 0))?;
    stream.define_method("next_batch", method!(NativeStream::next_batch, 0))?;
    stream.define_method("close", method!(NativeStream::close, 0))?;
    Ok(())
}

fn from_packed(ruby: &Ruby, value: RArray) -> Result<QValue, Error> {
    let tag: String = value.entry(0)?;
    let invalid = || Error::new(ruby.exception_arg_error(), "append value is out of range");
    Ok(match tag.as_str() {
        "null" => QValue::Null,
        "bool" => QValue::Bool(value.entry(1)?),
        "int" => {
            let text: String = value.entry(1)?;
            if let Ok(number) = text.parse::<i64>() {
                QValue::Int(number)
            } else if let Ok(number) = text.parse::<i128>() {
                QValue::HugeInt(number)
            } else {
                QValue::UHugeInt(text.parse().map_err(|_| invalid())?)
            }
        }
        "double" => QValue::Double(value.entry(1)?),
        "string" => QValue::String(value.entry(1)?),
        "bytes" => {
            let bytes: magnus::RString = value.entry(1)?;
            QValue::Bytes(unsafe { bytes.as_slice() }.to_vec())
        }
        "decimal" => quack_protocol::decimal_value(
            value.entry::<String>(1)?,
            value.entry(2)?,
            value.entry(3)?,
        )
        .map_err(|e| protocol_error(ruby, e))?,
        "date" => quack_protocol::date_value(value.entry(1)?),
        "time" => quack_protocol::time_value(
            value.entry(1)?,
            match value.entry::<String>(2)?.as_str() {
                "Micros" => quack_protocol::TimeUnit::Micros,
                _ => quack_protocol::TimeUnit::Nanos,
            },
        ),
        "timetz" => quack_protocol::time_tz_value(value.entry(1)?),
        "timestamp" => quack_protocol::timestamp_value(
            value.entry(1)?,
            match value.entry::<String>(2)?.as_str() {
                "Seconds" => quack_protocol::TimestampUnit::Seconds,
                "Millis" => quack_protocol::TimestampUnit::Millis,
                "Micros" => quack_protocol::TimestampUnit::Micros,
                _ => quack_protocol::TimestampUnit::Nanos,
            },
            value.entry(3)?,
        ),
        "interval" => {
            quack_protocol::interval_value(value.entry(1)?, value.entry(2)?, value.entry(3)?)
        }
        "list" => {
            let array: RArray = value.entry(1)?;
            let mut values = Vec::with_capacity(array.len());
            for i in 0..array.len() {
                values.push(from_packed(ruby, array.entry(i as isize)?)?);
            }
            QValue::List(values)
        }
        "struct" => {
            let hash: RHash = value.entry(1)?;
            let mut values = Row::new();
            hash.foreach(|key: String, value: RArray| {
                values.insert(key, from_packed(ruby, value)?);
                Ok(magnus::r_hash::ForEach::Continue)
            })?;
            QValue::Struct(values)
        }
        _ => {
            return Err(error(
                ruby,
                "UnsupportedTypeError",
                format!("unsupported append value {tag}"),
            ));
        }
    })
}

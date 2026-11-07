//! A thin C ABI over the cmux SDK's daemon client (cmux-tui/bindings/rust),
//! the one client the `cmux` CLI uses too, so the macOS app reaches the
//! daemon through the same code: `cmux_sdk_call` is
//! [`cmux::Client::call`], `cmux_sdk_subscribe` / `cmux_sdk_next` /
//! `cmux_sdk_cancel` are [`cmux::Client::subscribe`] and its stream, and
//! `cmux_sdk_command` is the older command lines' generic call
//! ([`cmux::raw::Client::request_raw_reply`]). No logic of its own: JSON in,
//! JSON out (include/cmux_sdk_ffi.h says the shapes).
//!
//! Every function catches a panic (it returns `ERR_PANIC`), takes no global
//! state, and may run on any thread; one client handle may be used from
//! several threads at once (calls on it are serialized by the SDK).

use std::ffi::{CStr, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::Duration;

use cmux::raw::{Client as RawClient, ClientConfig as RawConfig};
use cmux::{
    CallKind, Error, MutationOptions, ResourceStream, StreamCancellation, StreamEndReason,
    StreamPoll,
};
use serde_json::{Map, Value, json};

/// The ABI version `cmux_sdk_ffi_abi_version` returns; bump it when a type
/// or function changes.
pub const ABI_VERSION: u32 = 1;

pub const OK: i32 = 0;
pub const ERR_NULL: i32 = -1;
pub const ERR_INVALID: i32 = -2;
pub const ERR_PANIC: i32 = -4;

pub const KIND_READ: i32 = 0;
pub const KIND_MUTATION: i32 = 1;

/// A reply buffer owned by the caller: free it with `cmux_sdk_bytes_free`.
#[repr(C)]
pub struct CmuxSdkBytes {
    pub ptr: *mut u8,
    pub len: usize,
}

/// One daemon connection: the `cmux.protocol/2` client, and the older
/// command lines' client, opened on the first `cmux_sdk_command`.
pub struct CmuxSdkClient {
    client: cmux::Client,
    raw: Mutex<Option<RawClient>>,
    socket: PathBuf,
    timeout: Duration,
}

/// One stream opened with `cmux_sdk_subscribe`.
pub struct CmuxSdkStream {
    stream: Mutex<ResourceStream>,
    cancellation: StreamCancellation,
}

#[unsafe(no_mangle)]
pub extern "C" fn cmux_sdk_ffi_abi_version() -> u32 {
    ABI_VERSION
}

/// Connects to the daemon socket at `socket_path` (UTF-8, NUL-terminated).
/// `timeout_ms` bounds the connect and each request (0 is the SDK's 10 s).
/// On success `*out_client` is the handle and `*out` is empty; on a failure
/// `*out_client` is NULL and `*out` holds the error envelope.
///
/// # Safety
/// `socket_path` is NULL or a NUL-terminated string; `out_client` and `out`
/// are NULL or valid for writes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_sdk_connect(
    socket_path: *const c_char,
    timeout_ms: u32,
    out_client: *mut *mut CmuxSdkClient,
    out: *mut CmuxSdkBytes,
) -> i32 {
    guard(|| {
        if out_client.is_null() || out.is_null() {
            return ERR_NULL;
        }
        // SAFETY: both checked non-null; the caller passes writable pointers.
        unsafe {
            *out_client = std::ptr::null_mut();
            *out = empty();
        }
        // SAFETY: the caller passes NULL or a NUL-terminated string.
        let Some(path) = (unsafe { text(socket_path) }) else { return ERR_INVALID };
        let timeout = match timeout_ms {
            0 => Duration::from_secs(10),
            ms => Duration::from_millis(u64::from(ms)),
        };
        let socket = PathBuf::from(path);
        let config = cmux::Config::from_socket_path(&socket).with_timeout(timeout);
        match cmux::Client::connect(config) {
            Ok(client) => {
                let handle = CmuxSdkClient { client, raw: Mutex::new(None), socket, timeout };
                // SAFETY: checked non-null above.
                unsafe { *out_client = Box::into_raw(Box::new(handle)) };
            }
            // SAFETY: checked non-null above.
            Err(error) => unsafe { *out = bytes(&failure(&error)) },
        }
        OK
    })
}

/// Closes the client's connections and frees it. NULL is a no-op.
///
/// # Safety
/// `client` is NULL or a handle from `cmux_sdk_connect`, not used after.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_sdk_close(client: *mut CmuxSdkClient) {
    let _ = guard(|| {
        if client.is_null() {
            return OK;
        }
        // SAFETY: the caller gives up a handle from cmux_sdk_connect.
        let client = unsafe { Box::from_raw(client) };
        let _ = client.client.close();
        OK
    });
}

/// One `cmux.protocol/2` request for `operation`: `kind` is `KIND_READ` or
/// `KIND_MUTATION`, a mutation's `idempotency_key` is required (reuse it to
/// retry an unknown outcome), and `params` is a JSON object (or empty for
/// none), sent as given. `*out` is the result envelope.
///
/// # Safety
/// `client` is a live handle; `operation` and `idempotency_key` are NULL or
/// NUL-terminated; `params` points to `params_len` readable bytes (or is
/// NULL with 0); `out` is valid for writes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_sdk_call(
    client: *const CmuxSdkClient,
    operation: *const c_char,
    kind: i32,
    idempotency_key: *const c_char,
    params: *const u8,
    params_len: usize,
    out: *mut CmuxSdkBytes,
) -> i32 {
    guard(|| {
        // SAFETY: per this function's contract.
        let Some((client, out)) = (unsafe { handle_and_out(client, out) }) else { return ERR_NULL };
        // SAFETY: per this function's contract.
        let (Some(operation), Some(params)) =
            (unsafe { text(operation) }, unsafe { json_object(params, params_len) })
        else {
            return ERR_INVALID;
        };
        // SAFETY: per this function's contract.
        let key = unsafe { text(idempotency_key) };
        let kind = match (kind, key) {
            (KIND_READ, None) => CallKind::Read,
            (KIND_MUTATION, Some(key)) => match MutationOptions::new(key) {
                Ok(options) => CallKind::Mutation(options),
                Err(error) => {
                    *out = bytes(&failure(&error));
                    return OK;
                }
            },
            _ => return ERR_INVALID,
        };
        *out = bytes(&envelope(client.client.call(operation, kind, params)));
        OK
    })
}

/// One older command line (`cmd`) with `params` (a JSON object, or empty).
/// `*out` is the result envelope: `result` is the reply's `data`; a refusal's
/// `error` has the reply's `error_code` as `code`, its `error` as `message`
/// and the whole reply as `details` (a cloud refusal's `reason` included).
///
/// # Safety
/// As `cmux_sdk_call`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_sdk_command(
    client: *const CmuxSdkClient,
    command: *const c_char,
    params: *const u8,
    params_len: usize,
    out: *mut CmuxSdkBytes,
) -> i32 {
    guard(|| {
        // SAFETY: per this function's contract.
        let Some((client, out)) = (unsafe { handle_and_out(client, out) }) else { return ERR_NULL };
        // SAFETY: per this function's contract.
        let (Some(command), Some(Value::Object(mut body))) =
            (unsafe { text(command) }, unsafe { json_object(params, params_len) })
        else {
            return ERR_INVALID;
        };
        body.insert("cmd".into(), json!(command));
        *out = bytes(&client.command(body));
        OK
    })
}

/// Opens the stream `operation` with `params` (a JSON object, or empty) on
/// its own connection. On success `*out_stream` is the stream and `*out` is
/// empty; on a refusal `*out_stream` is NULL and `*out` the error envelope.
///
/// # Safety
/// As `cmux_sdk_call`; `out_stream` is valid for writes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_sdk_subscribe(
    client: *const CmuxSdkClient,
    operation: *const c_char,
    params: *const u8,
    params_len: usize,
    out_stream: *mut *mut CmuxSdkStream,
    out: *mut CmuxSdkBytes,
) -> i32 {
    guard(|| {
        if out_stream.is_null() {
            return ERR_NULL;
        }
        // SAFETY: checked non-null; the caller passes a writable pointer.
        unsafe { *out_stream = std::ptr::null_mut() };
        // SAFETY: per this function's contract.
        let Some((client, out)) = (unsafe { handle_and_out(client, out) }) else { return ERR_NULL };
        // SAFETY: per this function's contract.
        let (Some(operation), Some(params)) =
            (unsafe { text(operation) }, unsafe { json_object(params, params_len) })
        else {
            return ERR_INVALID;
        };
        match client.client.subscribe(operation, params) {
            Ok(stream) => {
                let cancellation = stream.cancellation();
                let stream = CmuxSdkStream { stream: Mutex::new(stream), cancellation };
                // SAFETY: checked non-null above.
                unsafe { *out_stream = Box::into_raw(Box::new(stream)) };
            }
            Err(error) => *out = bytes(&failure(&error)),
        }
        OK
    })
}

/// The stream's next event within `timeout_ms` (0 waits without a bound):
/// `{"item": {"sequence", "cursor", "value"}}`, `{"end": {"reason", ...}}`
/// once it ended, `{"timed_out": true}` with the stream still open, or an
/// error envelope.
///
/// # Safety
/// `stream` is a live stream handle; `out` is valid for writes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_sdk_next(
    stream: *const CmuxSdkStream,
    timeout_ms: u32,
    out: *mut CmuxSdkBytes,
) -> i32 {
    guard(|| {
        // SAFETY: per this function's contract.
        let Some((stream, out)) = (unsafe { handle_and_out(stream, out) }) else { return ERR_NULL };
        let Ok(mut stream) = stream.stream.lock() else { return ERR_PANIC };
        let polled = match timeout_ms {
            0 => stream.recv().map(|item| item.map_or(StreamPoll::End, StreamPoll::Item)),
            ms => stream.recv_timeout(Duration::from_millis(u64::from(ms))),
        };
        let reply = match polled {
            Ok(StreamPoll::Item(item)) => json!({"item": {
                "sequence": item.sequence,
                "cursor": item.cursor.map(|c| json!({"generation": c.generation, "revision": c.revision.to_string()})),
                "value": item.value,
            }}),
            Ok(StreamPoll::End) => json!({"end": end_json(&stream)}),
            Ok(StreamPoll::TimedOut) => json!({"timed_out": true}),
            Err(error) => failure(&error),
        };
        *out = bytes(&reply);
        OK
    })
}

/// Asks the daemon to end the stream; returns at once and may run while
/// another thread waits in `cmux_sdk_next`, which then reports the end.
///
/// # Safety
/// `stream` is NULL or a live stream handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_sdk_cancel(stream: *const CmuxSdkStream) -> i32 {
    guard(|| {
        // SAFETY: the caller passes NULL or a live handle.
        let Some(stream) = (unsafe { stream.as_ref() }) else { return ERR_NULL };
        let _ = stream.cancellation.cancel();
        OK
    })
}

/// Frees a stream, closing its connection. NULL is a no-op.
///
/// # Safety
/// `stream` is NULL or a stream handle no other thread still uses.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_sdk_stream_free(stream: *mut CmuxSdkStream) {
    let _ = guard(|| {
        if !stream.is_null() {
            // SAFETY: the caller gives up a handle from cmux_sdk_subscribe.
            drop(unsafe { Box::from_raw(stream) });
        }
        OK
    });
}

/// Frees a buffer a function wrote. An empty one is a no-op.
///
/// # Safety
/// `bytes` came from this library and is freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_sdk_bytes_free(bytes: CmuxSdkBytes) {
    if bytes.ptr.is_null() {
        return;
    }
    // SAFETY: built by `bytes()` from a boxed slice of exactly `len` bytes.
    drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(bytes.ptr, bytes.len)) });
}

impl CmuxSdkClient {
    fn command(&self, body: Map<String, Value>) -> Value {
        let Ok(mut raw) = self.raw.lock() else {
            return failure(&Error::Connection("command connection lock poisoned".into()));
        };
        if raw.is_none() {
            let config = RawConfig::from_socket_path(&self.socket).with_timeout(self.timeout);
            match RawClient::connect(config) {
                Ok(client) => *raw = Some(client),
                Err(error) => return failure(&error),
            }
        }
        let Some(client) = raw.as_mut() else { return failure(&Error::Closed) };
        match client.request_raw_reply(body) {
            Ok(reply) if reply.get("ok").and_then(Value::as_bool) == Some(true) => {
                json!({"ok": true, "result": reply.get("data").cloned().unwrap_or(Value::Null)})
            }
            Ok(reply) => {
                let text = |key: &str| reply.get(key).and_then(Value::as_str).unwrap_or("");
                let code = match text("error_code") {
                    "" => "command.failed",
                    code => code,
                };
                json!({"ok": false, "error": {"code": code, "message": text("error"),
                       "details": reply.clone()}})
            }
            Err(error) => {
                // A transport failure leaves the connection unusable; the
                // next command opens a new one.
                *raw = None;
                failure(&error)
            }
        }
    }
}

fn envelope(result: cmux::Result<Value>) -> Value {
    match result {
        Ok(result) => json!({"ok": true, "result": result}),
        Err(error) => failure(&error),
    }
}

/// An SDK error as the ABI's error envelope:
/// `{"ok": false, "error": {"code", "message", "details"?, "retryable"?,
/// "idempotency_key"?}}`.
fn failure(error: &Error) -> Value {
    let mut fields = Map::new();
    let code = match error {
        Error::Protocol { code, details, retryable, .. } => {
            fields.insert("details".into(), details.clone());
            fields.insert("retryable".into(), json!(retryable));
            code.clone()
        }
        Error::MutationTransport { idempotency_key, .. } => {
            fields.insert("idempotency_key".into(), json!(idempotency_key));
            "mutation.transport".into()
        }
        Error::Timeout(_) => "timeout".into(),
        Error::Cancelled(_) => "cancelled".into(),
        Error::Closed => "closed".into(),
        Error::Connection(_) | Error::ConnectionIo { .. } => "connection".into(),
        Error::InvalidArgument(_) => "invalid_argument".into(),
        other => other.error_code().unwrap_or("sdk").to_owned(),
    };
    fields.insert("code".into(), json!(code));
    fields.insert("message".into(), json!(error.to_string()));
    json!({"ok": false, "error": fields})
}

fn end_json(stream: &ResourceStream) -> Value {
    let Some(end) = stream.end() else { return json!({"reason": "closed"}) };
    let reason = match end.reason {
        StreamEndReason::Completed => "completed",
        StreamEndReason::Canceled => "canceled",
        StreamEndReason::Closed => "closed",
        StreamEndReason::Gap => "gap",
        StreamEndReason::Error => "error",
    };
    json!({"reason": reason, "recovery": end.recovery})
}

fn guard(body: impl FnOnce() -> i32) -> i32 {
    catch_unwind(AssertUnwindSafe(body)).unwrap_or(ERR_PANIC)
}

fn empty() -> CmuxSdkBytes {
    CmuxSdkBytes { ptr: std::ptr::null_mut(), len: 0 }
}

fn bytes(value: &Value) -> CmuxSdkBytes {
    let boxed = value.to_string().into_bytes().into_boxed_slice();
    let len = boxed.len();
    CmuxSdkBytes { ptr: Box::into_raw(boxed).cast::<u8>(), len }
}

/// # Safety
/// `pointer` is NULL or a NUL-terminated string that outlives the call.
unsafe fn text<'a>(pointer: *const c_char) -> Option<&'a str> {
    if pointer.is_null() {
        return None;
    }
    // SAFETY: per this function's contract.
    unsafe { CStr::from_ptr(pointer) }.to_str().ok()
}

/// A JSON object from `len` bytes at `pointer` (none is an empty object);
/// `None` when the bytes are not one.
///
/// # Safety
/// `pointer` is NULL with 0, or points to `len` readable bytes.
unsafe fn json_object(pointer: *const u8, len: usize) -> Option<Value> {
    if len == 0 {
        return Some(Value::Object(Map::new()));
    }
    if pointer.is_null() {
        return None;
    }
    // SAFETY: per this function's contract.
    let slice = unsafe { std::slice::from_raw_parts(pointer, len) };
    match serde_json::from_slice(slice).ok()? {
        Value::Object(map) => Some(Value::Object(map)),
        _ => None,
    }
}

/// # Safety
/// `handle` is NULL or live; `out` is NULL or valid for writes.
unsafe fn handle_and_out<'a, T>(
    handle: *const T,
    out: *mut CmuxSdkBytes,
) -> Option<(&'a T, &'a mut CmuxSdkBytes)> {
    if out.is_null() {
        return None;
    }
    // SAFETY: per this function's contract.
    let out = unsafe { &mut *out };
    *out = empty();
    // SAFETY: per this function's contract.
    Some((unsafe { handle.as_ref() }?, out))
}

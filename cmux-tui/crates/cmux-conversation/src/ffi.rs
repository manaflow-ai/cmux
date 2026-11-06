//! The C ABI of the app's conversation client rules ([`crate::app`]) for the
//! macOS app (`include/cmux_conversation_ffi.h`, Swift module
//! `CCmuxConversationFFI`), linked into the app through cmux-app-ffi.
//!
//! Two entry points, each an op name and a JSON request object in and one
//! JSON reply object out: [`cmux_conversation_call`] for the stateless
//! rules, and [`cmux_conversation_session_call`] on a session handle (one
//! open conversation's mirror and intent log, [`crate::session`]). A rule that refuses its
//! input answers `{"error": "<code>"}` with [`OK`]; the return codes are for
//! a call the ABI itself cannot run. None of these is per frame: they run
//! once per page, per chunk or per decoded run step.
//!
//! Every function may run on any thread at once (a session's state is under
//! its own lock) and none unwinds
//! across the boundary ([`ERR_PANIC`]). A reply buffer
//! ([`CmuxConversationBytes`]) belongs to the caller, who frees it with
//! [`cmux_conversation_bytes_free`].

use serde_json::{Map, Value, json};
use std::ffi::{CStr, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::Mutex;

use crate::session::Session;

/// Bumped on any change to a type, a function or an op in the header.
pub const ABI_VERSION: u32 = 1;
pub const OK: i32 = 0;
pub const ERR_NULL: i32 = -1;
/// The request is not UTF-8 JSON object text.
pub const ERR_INVALID: i32 = -2;
/// The op is not one of the header's.
pub const ERR_UNKNOWN_OP: i32 = -3;
pub const ERR_PANIC: i32 = -4;

/// One JSON op on a parsed request: the reply object, or a return code.
pub fn call(op: &str, request: &Value) -> Result<Value, i32> {
    match crate::app::call(op, request) {
        None => Err(ERR_UNKNOWN_OP),
        Some(Ok(reply)) => Ok(reply),
        Some(Err(reject)) => Ok(json!({ "error": reject.code() })),
    }
}

/// One JSON op on a session.
pub fn session_call(session: &mut Session, op: &str, request: &Value) -> Result<Value, i32> {
    match session.call(op, request) {
        None => Err(ERR_UNKNOWN_OP),
        Some(Ok(reply)) => Ok(reply),
        Some(Err(_)) => Ok(json!({ "error": "invalid" })),
    }
}

/// The opaque session handle (`CmuxConversationSession *`).
pub struct CmuxConversationSession {
    session: Mutex<Session>,
}

/// A reply buffer the caller frees with [`cmux_conversation_bytes_free`];
/// `ptr` is null when `len` is 0.
#[repr(C)]
#[derive(Debug)]
pub struct CmuxConversationBytes {
    pub ptr: *mut u8,
    pub len: usize,
}

impl CmuxConversationBytes {
    fn from_vec(bytes: Vec<u8>) -> Self {
        if bytes.is_empty() {
            return Self { ptr: std::ptr::null_mut(), len: 0 };
        }
        let boxed = bytes.into_boxed_slice();
        let len = boxed.len();
        Self { ptr: Box::into_raw(boxed).cast::<u8>(), len }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn cmux_conversation_abi_version() -> u32 {
    ABI_VERSION
}

/// Frees a reply buffer. An empty one (null `ptr`) is ignored.
///
/// # Safety
///
/// `bytes` came from this library and is freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_conversation_bytes_free(bytes: CmuxConversationBytes) {
    if !bytes.ptr.is_null() {
        let slice = std::ptr::slice_from_raw_parts_mut(bytes.ptr, bytes.len);
        // SAFETY: `ptr` and `len` are a boxed slice this library gave out.
        drop(unsafe { Box::from_raw(slice) });
    }
}

/// One JSON op (`op`, a NUL-terminated name; `request`, a JSON object, or
/// empty for `{}`): its reply object in `out`. On any code but [`OK`]
/// nothing is written to `out`.
///
/// # Safety
///
/// `op` is a NUL-terminated string; `request` with its length is readable
/// (or null with length 0); `out` is writable.
/// Parses the request, runs `body` and writes its reply to `out`.
///
/// # Safety
///
/// As [`cmux_conversation_call`].
unsafe fn run(
    op: *const c_char,
    request: *const u8,
    request_len: usize,
    out: *mut CmuxConversationBytes,
    body: impl FnOnce(&str, &Value) -> Result<Value, i32>,
) -> i32 {
    if op.is_null() || out.is_null() || (request.is_null() && request_len != 0) {
        return ERR_NULL;
    }
    catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: a NUL-terminated string from the caller.
        let Ok(op) = unsafe { CStr::from_ptr(op) }.to_str() else { return ERR_INVALID };
        let bytes: &[u8] = if request_len == 0 {
            &[]
        } else {
            // SAFETY: the caller guarantees `request_len` readable bytes at `request`.
            unsafe { std::slice::from_raw_parts(request, request_len) }
        };
        let request = if bytes.is_empty() {
            Value::Object(Map::new())
        } else {
            match serde_json::from_slice::<Value>(bytes) {
                Ok(value @ Value::Object(_)) => value,
                _ => return ERR_INVALID,
            }
        };
        match body(op, &request) {
            Ok(reply) => {
                let Ok(bytes) = serde_json::to_vec(&reply) else { return ERR_INVALID };
                // SAFETY: `out` checked non-null.
                unsafe { *out = CmuxConversationBytes::from_vec(bytes) };
                OK
            }
            Err(code) => code,
        }
    }))
    .unwrap_or(ERR_PANIC)
}

/// One stateless JSON op (`op`, a NUL-terminated name; `request`, a JSON
/// object, or empty for `{}`): its reply object in `out`. On any code but
/// [`OK`] nothing is written to `out`.
///
/// # Safety
///
/// `op` is a NUL-terminated string; `request` with its length is readable
/// (or null with length 0); `out` is writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_conversation_call(
    op: *const c_char,
    request: *const u8,
    request_len: usize,
    out: *mut CmuxConversationBytes,
) -> i32 {
    // SAFETY: the caller's pointer rules.
    unsafe { run(op, request, request_len, out, call) }
}

/// A new session (one open conversation) keeping its newest `tail_limit`
/// confirmed messages (0: the default, 400). Free it with
/// [`cmux_conversation_session_free`].
#[unsafe(no_mangle)]
pub extern "C" fn cmux_conversation_session_new(tail_limit: u32) -> *mut CmuxConversationSession {
    let limit = (tail_limit > 0).then_some(tail_limit as usize);
    Box::into_raw(Box::new(CmuxConversationSession { session: Mutex::new(Session::new(limit)) }))
}

/// Frees a session from [`cmux_conversation_session_new`]. Null is ignored.
///
/// # Safety
///
/// `session` is null or a live handle, not used afterwards by any thread.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_conversation_session_free(session: *mut CmuxConversationSession) {
    if !session.is_null() {
        // SAFETY: the caller hands back a handle from `cmux_conversation_session_new` once.
        drop(unsafe { Box::from_raw(session) });
    }
}

/// One JSON op on a session, as [`cmux_conversation_call`]. A null session
/// answers [`ERR_NULL`].
///
/// # Safety
///
/// `session` is a live handle; the other pointers as [`cmux_conversation_call`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_conversation_session_call(
    session: *const CmuxConversationSession,
    op: *const c_char,
    request: *const u8,
    request_len: usize,
    out: *mut CmuxConversationBytes,
) -> i32 {
    if session.is_null() {
        return ERR_NULL;
    }
    // SAFETY: a live handle.
    let handle = unsafe { &(*session).session };
    // SAFETY: the caller's pointer rules.
    unsafe {
        run(op, request, request_len, out, |op, request| {
            // A panic inside an op poisons the lock; the state is still whole
            // (every op writes it last), so the session goes on.
            let mut session = handle.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            session_call(&mut session, op, request)
        })
    }
}

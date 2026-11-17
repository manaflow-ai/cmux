//! The C ABI of the health model for the macOS app
//! (`include/cmux_health.h`, Swift module `CCmuxHealthFFI`), linked into the
//! app through cmux-app-ffi.
//!
//! - `cmux_health_new` / `cmux_health_free`: one model per app.
//! - `cmux_health_call`: one JSON op on it ([`crate::ops::call`]).
//!
//! Every function may run on any thread; a handle is used by one thread at a
//! time (the app holds it under its own lock). None unwinds across the
//! boundary. A reply buffer belongs to the caller, who frees it with
//! `cmux_health_bytes_free`.

use crate::model::Health;
use crate::ops::{OpError, call};
use serde_json::{Map, Value};
use std::ffi::{CStr, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};

/// Bumped on any change to a type, a function or an op.
pub const CMUX_HEALTH_ABI_VERSION: u32 = 1;
pub const CMUX_HEALTH_OK: i32 = 0;
/// A null pointer where one is required.
pub const CMUX_HEALTH_ERR_NULL: i32 = -1;
/// Not UTF-8, or not the JSON the op takes.
pub const CMUX_HEALTH_ERR_INVALID: i32 = -2;
/// The op is not one of the header's.
pub const CMUX_HEALTH_ERR_UNKNOWN_OP: i32 = -3;
/// A panic inside, caught.
pub const CMUX_HEALTH_ERR_PANIC: i32 = -4;

/// A reply buffer owned by the caller (JSON, UTF-8). `ptr` is null when
/// `len` is 0.
#[repr(C)]
pub struct CmuxHealthBytes {
    pub ptr: *mut u8,
    pub len: usize,
}

impl CmuxHealthBytes {
    fn from_vec(bytes: Vec<u8>) -> Self {
        if bytes.is_empty() {
            return Self { ptr: std::ptr::null_mut(), len: 0 };
        }
        let boxed = bytes.into_boxed_slice();
        let len = boxed.len();
        Self { ptr: Box::into_raw(boxed).cast::<u8>(), len }
    }
}

/// One health model.
pub struct CmuxHealth {
    health: Health,
}

/// `CMUX_HEALTH_ABI_VERSION`.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_health_abi_version() -> u32 {
    CMUX_HEALTH_ABI_VERSION
}

/// A new model with the contract's defaults. Free it with `cmux_health_free`.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_health_new() -> *mut CmuxHealth {
    Box::into_raw(Box::new(CmuxHealth { health: Health::new() }))
}

/// Frees a model. Null is ignored.
///
/// # Safety
///
/// `health` is null or a live handle, not used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_health_free(health: *mut CmuxHealth) {
    if !health.is_null() {
        // SAFETY: from `cmux_health_new`, freed once.
        drop(unsafe { Box::from_raw(health) });
    }
}

/// Frees a reply buffer. A null `ptr` is ignored.
///
/// # Safety
///
/// `bytes` came from this library and is freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_health_bytes_free(bytes: CmuxHealthBytes) {
    if bytes.ptr.is_null() {
        return;
    }
    // SAFETY: built by `from_vec` from a boxed slice of `len` bytes.
    drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(bytes.ptr, bytes.len)) });
}

/// Runs one JSON op on `health`: `op` (NUL-terminated) on `request` (a JSON
/// object, UTF-8; empty means `{}`); `*out` gets the reply's JSON.
///
/// # Safety
///
/// `health` is a live handle used by one thread at a time; `op` is a
/// NUL-terminated string; `request` with its length is readable; `out` is
/// writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_health_call(
    health: *mut CmuxHealth,
    op: *const c_char,
    request_ptr: *const u8,
    request_len: usize,
    out: *mut CmuxHealthBytes,
) -> i32 {
    if health.is_null() || op.is_null() || out.is_null() {
        return CMUX_HEALTH_ERR_NULL;
    }
    if request_ptr.is_null() && request_len != 0 {
        return CMUX_HEALTH_ERR_NULL;
    }
    let body = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: a NUL-terminated string from the caller.
        let Ok(op) = unsafe { CStr::from_ptr(op) }.to_str() else {
            return CMUX_HEALTH_ERR_INVALID;
        };
        let bytes: &[u8] = if request_len == 0 {
            &[]
        } else {
            // SAFETY: the caller's pointer is readable for `request_len` bytes.
            unsafe { std::slice::from_raw_parts(request_ptr, request_len) }
        };
        let request = if bytes.is_empty() {
            Value::Object(Map::new())
        } else {
            match serde_json::from_slice::<Value>(bytes) {
                Ok(value @ Value::Object(_)) => value,
                _ => return CMUX_HEALTH_ERR_INVALID,
            }
        };
        // SAFETY: a live handle, one thread at a time.
        let health = unsafe { &mut (*health).health };
        let reply = match call(health, op, &request) {
            Ok(reply) => reply,
            Err(OpError::Unknown) => return CMUX_HEALTH_ERR_UNKNOWN_OP,
            Err(OpError::Invalid) => return CMUX_HEALTH_ERR_INVALID,
        };
        let Ok(bytes) = serde_json::to_vec(&reply) else { return CMUX_HEALTH_ERR_INVALID };
        // SAFETY: `out` checked non-null and writable.
        unsafe { *out = CmuxHealthBytes::from_vec(bytes) };
        CMUX_HEALTH_OK
    }));
    body.unwrap_or(CMUX_HEALTH_ERR_PANIC)
}

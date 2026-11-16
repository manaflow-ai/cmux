//! The C ABI of the pre-warm record for the macOS app
//! (`include/cmux_update_prewarm.h`), linked into the app through
//! cmux-app-ffi.
//!
//! - `cmux_update_prewarm_call`: one JSON op ([`crate::ops::call`]).
//!
//! Every function may run on any thread. None unwinds across the boundary.
//! A reply buffer belongs to the caller, who frees it with
//! `cmux_update_prewarm_bytes_free`.

use crate::ops::{OpError, call};
use serde_json::{Map, Value};
use std::ffi::{CStr, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};

/// Bumped on any change to a type, a function or an op.
pub const CMUX_UPDATE_PREWARM_ABI_VERSION: u32 = 1;
pub const CMUX_UPDATE_PREWARM_OK: i32 = 0;
/// A null pointer where one is required.
pub const CMUX_UPDATE_PREWARM_ERR_NULL: i32 = -1;
/// Not UTF-8, or not the JSON the op takes.
pub const CMUX_UPDATE_PREWARM_ERR_INVALID: i32 = -2;
/// The op is not one of the header's.
pub const CMUX_UPDATE_PREWARM_ERR_UNKNOWN_OP: i32 = -3;
/// A panic inside, caught.
pub const CMUX_UPDATE_PREWARM_ERR_PANIC: i32 = -4;

/// A reply buffer owned by the caller (JSON, UTF-8). `ptr` is null when
/// `len` is 0.
#[repr(C)]
pub struct CmuxUpdatePrewarmBytes {
    pub ptr: *mut u8,
    pub len: usize,
}

impl CmuxUpdatePrewarmBytes {
    fn from_vec(bytes: Vec<u8>) -> Self {
        if bytes.is_empty() {
            return Self { ptr: std::ptr::null_mut(), len: 0 };
        }
        let boxed = bytes.into_boxed_slice();
        let len = boxed.len();
        Self { ptr: Box::into_raw(boxed).cast::<u8>(), len }
    }
}

fn guarded(body: impl FnOnce() -> i32) -> i32 {
    catch_unwind(AssertUnwindSafe(body)).unwrap_or(CMUX_UPDATE_PREWARM_ERR_PANIC)
}

/// The bytes at `ptr` (empty when `len` is 0); none for a null pointer with a length.
unsafe fn input<'a>(ptr: *const u8, len: usize) -> Option<&'a [u8]> {
    if len == 0 {
        return Some(&[]);
    }
    if ptr.is_null() {
        return None;
    }
    // SAFETY: the caller's pointer is readable for `len` bytes.
    Some(unsafe { std::slice::from_raw_parts(ptr, len) })
}

/// The request object (`{}` when empty).
fn request(bytes: &[u8]) -> Result<Value, i32> {
    if bytes.is_empty() {
        return Ok(Value::Object(Map::new()));
    }
    match serde_json::from_slice::<Value>(bytes) {
        Ok(value @ Value::Object(_)) => Ok(value),
        _ => Err(CMUX_UPDATE_PREWARM_ERR_INVALID),
    }
}

/// Writes `value`'s JSON to `out`.
unsafe fn give(out: *mut CmuxUpdatePrewarmBytes, value: &Value) -> i32 {
    let Ok(bytes) = serde_json::to_vec(value) else { return CMUX_UPDATE_PREWARM_ERR_INVALID };
    // SAFETY: `out` is writable (checked non-null by every caller).
    unsafe { *out = CmuxUpdatePrewarmBytes::from_vec(bytes) };
    CMUX_UPDATE_PREWARM_OK
}

fn op_code(error: OpError) -> i32 {
    match error {
        OpError::Unknown => CMUX_UPDATE_PREWARM_ERR_UNKNOWN_OP,
        OpError::Invalid => CMUX_UPDATE_PREWARM_ERR_INVALID,
    }
}

/// `CMUX_UPDATE_PREWARM_ABI_VERSION`.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_update_prewarm_abi_version() -> u32 {
    CMUX_UPDATE_PREWARM_ABI_VERSION
}

/// Frees a reply buffer. A null `ptr` is ignored.
///
/// # Safety
///
/// `bytes` came from this library and is freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_update_prewarm_bytes_free(bytes: CmuxUpdatePrewarmBytes) {
    if bytes.ptr.is_null() {
        return;
    }
    // SAFETY: built by `from_vec` from a boxed slice of `len` bytes.
    drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(bytes.ptr, bytes.len)) });
}

/// Runs one JSON op: `op` (NUL-terminated) on `request` (a JSON object,
/// UTF-8; empty means `{}`); `*out` gets the reply's JSON.
///
/// # Safety
///
/// `op` is a NUL-terminated string; `request` with its length is readable;
/// `out` is writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_update_prewarm_call(
    op: *const c_char,
    request_ptr: *const u8,
    request_len: usize,
    out: *mut CmuxUpdatePrewarmBytes,
) -> i32 {
    if op.is_null() || out.is_null() {
        return CMUX_UPDATE_PREWARM_ERR_NULL;
    }
    guarded(|| {
        // SAFETY: a NUL-terminated string from the caller.
        let Ok(op) = unsafe { CStr::from_ptr(op) }.to_str() else {
            return CMUX_UPDATE_PREWARM_ERR_INVALID;
        };
        // SAFETY: the caller's pointer rules.
        let Some(bytes) = (unsafe { input(request_ptr, request_len) }) else {
            return CMUX_UPDATE_PREWARM_ERR_NULL;
        };
        let request = match request(bytes) {
            Ok(request) => request,
            Err(code) => return code,
        };
        match call(op, &request) {
            // SAFETY: `out` checked non-null.
            Ok(value) => unsafe { give(out, &value) },
            Err(error) => op_code(error),
        }
    })
}

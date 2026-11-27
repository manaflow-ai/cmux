//! cmux-next.json's reads for the macOS app (`include/cmux_settings.h`, Swift
//! module `CCmuxSettingsFFI`): the JSON ops of `cmux_config::app_ops`, so the
//! app's settings parse, validation and defaults are cmux-config's, the
//! same code the daemon and the CLI read the file with.

use serde_json::Value;
use std::ffi::{CStr, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};

use cmux_config::app_ops::{self, OpError};

/// Bumped on any change to a type, a function or an op.
pub const CMUX_SETTINGS_ABI_VERSION: u32 = 1;
/// The op ran; `*out` holds its reply.
pub const CMUX_SETTINGS_OK: i32 = 0;
/// A null pointer where one is required.
pub const CMUX_SETTINGS_ERR_NULL: i32 = -1;
/// Not UTF-8, or not the JSON the op takes.
pub const CMUX_SETTINGS_ERR_INVALID: i32 = -2;
/// The op is not one of cmux_config::app_ops's.
pub const CMUX_SETTINGS_ERR_UNKNOWN_OP: i32 = -3;
/// A panic inside, caught.
pub const CMUX_SETTINGS_ERR_PANIC: i32 = -4;

/// A reply buffer owned by the caller (JSON, UTF-8). `ptr` is null when `len`
/// is 0.
#[repr(C)]
pub struct CmuxSettingsBytes {
    pub ptr: *mut u8,
    pub len: usize,
}

/// `CMUX_SETTINGS_ABI_VERSION`.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_settings_abi_version() -> u32 {
    CMUX_SETTINGS_ABI_VERSION
}

/// Runs one JSON op: `op` (NUL-terminated, such as `jsonc.parse`) on
/// `request` (a JSON object, UTF-8); `*out` gets the reply's JSON, which the
/// caller frees with `cmux_settings_bytes_free`.
///
/// # Safety
///
/// `op` is a NUL-terminated string; `request_ptr` with `request_len` is
/// readable; `out` is writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_settings_call(
    op: *const c_char,
    request_ptr: *const u8,
    request_len: usize,
    out: *mut CmuxSettingsBytes,
) -> i32 {
    if op.is_null() || out.is_null() || (request_ptr.is_null() && request_len != 0) {
        return CMUX_SETTINGS_ERR_NULL;
    }
    let result = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: a NUL-terminated string from the caller.
        let Ok(op) = unsafe { CStr::from_ptr(op) }.to_str() else {
            return Err(CMUX_SETTINGS_ERR_INVALID);
        };
        let bytes: &[u8] = if request_len == 0 {
            &[]
        } else {
            // SAFETY: readable for `request_len` bytes per the contract.
            unsafe { std::slice::from_raw_parts(request_ptr, request_len) }
        };
        let request = match serde_json::from_slice::<Value>(bytes) {
            Ok(value @ Value::Object(_)) => value,
            _ => return Err(CMUX_SETTINGS_ERR_INVALID),
        };
        match app_ops::call(op, &request) {
            Ok(reply) => Ok(serde_json::to_vec(&reply).unwrap_or_default()),
            Err(OpError::Unknown) => Err(CMUX_SETTINGS_ERR_UNKNOWN_OP),
            Err(OpError::Invalid(_)) => Err(CMUX_SETTINGS_ERR_INVALID),
        }
    }));
    let reply = match result {
        Ok(Ok(reply)) => reply,
        Ok(Err(code)) => return code,
        Err(_) => return CMUX_SETTINGS_ERR_PANIC,
    };
    let boxed = reply.into_boxed_slice();
    let len = boxed.len();
    let ptr = if len == 0 { std::ptr::null_mut() } else { Box::into_raw(boxed).cast::<u8>() };
    // SAFETY: `out` is writable per the contract.
    unsafe { out.write(CmuxSettingsBytes { ptr, len }) };
    CMUX_SETTINGS_OK
}

/// Frees a reply buffer. A null `ptr` is ignored.
///
/// # Safety
///
/// `bytes` came from `cmux_settings_call` and is freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_settings_bytes_free(bytes: CmuxSettingsBytes) {
    if bytes.ptr.is_null() {
        return;
    }
    // SAFETY: a boxed slice of `len` bytes from `cmux_settings_call`.
    drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(bytes.ptr, bytes.len)) });
}

#[cfg(test)]
#[path = "settings_tests.rs"]
mod tests;

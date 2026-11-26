//! C ABI of the screen stream's rules (`include/cmux_rd_screen.h`): the
//! `screen_*` JSON ops of `cmux_rd_screen::json`, for a process that runs a
//! screen stream host outside the app (cmux Remote's Screen Sharing worker,
//! cmux-vnc-host). They open `libcmux_rd_screen.dylib` and hand it to
//! Packages/Shared/CmuxVNCWebRTC's `ScreenRules`; the app answers the same
//! ops through cmux-layout-reducer-ffi and the phone through
//! cmux-mobile-link-ffi, all three calling `cmux_rd_screen::json::respond`.
//!
//! The call has `cmux_layout_reducer_json`'s shape, so one Swift caller fits
//! both: the answer is copied into the caller's buffer, and a buffer too small
//! gives `ERR_BUFFER` with the length it needs in `output_len`.

use std::ffi::{CStr, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};

pub const ABI_VERSION: u32 = 1;
pub const OK: i32 = 0;
pub const ERR_NULL: i32 = -1;
pub const ERR_INVALID: i32 = -2;
pub const ERR_BUFFER: i32 = -3;
pub const ERR_PANIC: i32 = -4;
/// No `screen_*` op of that name.
pub const ERR_UNKNOWN: i32 = -5;

#[unsafe(no_mangle)]
pub extern "C" fn cmux_rd_screen_abi_version() -> u32 {
    ABI_VERSION
}

/// Answers one `screen_*` op. See the checked-in header for the pointer rules.
///
/// # Safety
///
/// `request` points to `request_len` readable bytes (or is null with length
/// 0), `operation` is a NUL-terminated C string, `output` points to
/// `output_capacity` writable bytes (or is null with capacity 0) and
/// `output_len` is writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_screen_json(
    request: *const u8,
    request_len: usize,
    operation: *const c_char,
    output: *mut u8,
    output_capacity: usize,
    output_len: *mut usize,
) -> i32 {
    if operation.is_null() || output_len.is_null() || (request.is_null() && request_len != 0) {
        return ERR_NULL;
    }
    let request: &[u8] = if request_len == 0 {
        &[]
    } else {
        // SAFETY: non-null and `request_len` readable bytes, per the caller.
        unsafe { std::slice::from_raw_parts(request, request_len) }
    };
    // SAFETY: a NUL-terminated C string owned by the caller.
    let operation = unsafe { CStr::from_ptr(operation) };
    let answer = match catch_unwind(AssertUnwindSafe(|| answer(operation, request))) {
        Ok(Ok(bytes)) => bytes,
        Ok(Err(code)) => return code,
        Err(_) => return ERR_PANIC,
    };
    // SAFETY: checked non-null above; writable per the caller.
    unsafe { *output_len = answer.len() };
    if answer.len() > output_capacity {
        return ERR_BUFFER;
    }
    if output.is_null() {
        return ERR_NULL;
    }
    // SAFETY: the caller provided `output_capacity` writable bytes.
    unsafe { std::ptr::copy_nonoverlapping(answer.as_ptr(), output, answer.len()) };
    OK
}

fn answer(operation: &CStr, request: &[u8]) -> Result<Vec<u8>, i32> {
    use cmux_rd_screen::json::{self, JsonError};
    let operation = operation.to_str().map_err(|_| ERR_INVALID)?;
    let answer = json::respond(operation, request).map_err(|error| match error {
        JsonError::UnknownOperation(_) => ERR_UNKNOWN,
        JsonError::Invalid(_) => ERR_INVALID,
    })?;
    serde_json::to_vec(&answer).map_err(|_| ERR_INVALID)
}

#[cfg(test)]
#[path = "tests.rs"]
mod tests;

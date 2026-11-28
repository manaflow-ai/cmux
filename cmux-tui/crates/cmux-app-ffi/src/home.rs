//! The Mac Home, chat list and Chief rules for the app (`include/cmux_home.h`,
//! Swift module `CCmuxHomeFFI`): the JSON ops of `cmux_home_rules`
//! (`AREA.NAME`, such as `inbox.sections`), so what Home shows and decides is
//! Rust the other platforms share, and the Swift stays the view.

use std::ffi::{CStr, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};

use cmux_home_rules::OpError;

/// Bumped on any change to a type, a function or an op.
pub const CMUX_HOME_ABI_VERSION: u32 = 1;
/// The op ran; `*out` holds its reply.
pub const CMUX_HOME_OK: i32 = 0;
/// A null pointer where one is required.
pub const CMUX_HOME_ERR_NULL: i32 = -1;
/// Not UTF-8, or not the JSON the op takes.
pub const CMUX_HOME_ERR_INVALID: i32 = -2;
/// The op is not one of cmux_home_rules's.
pub const CMUX_HOME_ERR_UNKNOWN_OP: i32 = -3;
/// A panic inside, caught.
pub const CMUX_HOME_ERR_PANIC: i32 = -4;

/// A reply buffer owned by the caller (JSON, UTF-8). `ptr` is null when `len`
/// is 0.
#[repr(C)]
pub struct CmuxHomeBytes {
    pub ptr: *mut u8,
    pub len: usize,
}

/// `CMUX_HOME_ABI_VERSION`.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_home_abi_version() -> u32 {
    CMUX_HOME_ABI_VERSION
}

/// Runs one JSON op: `op` (NUL-terminated, such as `inbox.sections`) on
/// `request` (a JSON object, UTF-8); `*out` gets the reply's JSON, which the
/// caller frees with `cmux_home_bytes_free`.
///
/// # Safety
///
/// `op` is a NUL-terminated string; `request_ptr` with `request_len` is
/// readable; `out` is writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_home_call(
    op: *const c_char,
    request_ptr: *const u8,
    request_len: usize,
    out: *mut CmuxHomeBytes,
) -> i32 {
    if op.is_null() || out.is_null() || (request_ptr.is_null() && request_len != 0) {
        return CMUX_HOME_ERR_NULL;
    }
    let result = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: a NUL-terminated string from the caller.
        let Ok(op) = unsafe { CStr::from_ptr(op) }.to_str() else {
            return Err(CMUX_HOME_ERR_INVALID);
        };
        let bytes: &[u8] = if request_len == 0 {
            &[]
        } else {
            // SAFETY: readable for `request_len` bytes per the contract.
            unsafe { std::slice::from_raw_parts(request_ptr, request_len) }
        };
        // Bytes in, bytes out: the per-conversation and per-page ops read and write no `Value` tree.
        match cmux_home_rules::call_json(op, bytes) {
            Ok(reply) => Ok(reply),
            Err(OpError::Unknown) => Err(CMUX_HOME_ERR_UNKNOWN_OP),
            Err(OpError::Invalid(_)) => Err(CMUX_HOME_ERR_INVALID),
        }
    }));
    let reply = match result {
        Ok(Ok(reply)) => reply,
        Ok(Err(code)) => return code,
        Err(_) => return CMUX_HOME_ERR_PANIC,
    };
    let boxed = reply.into_boxed_slice();
    let len = boxed.len();
    let ptr = if len == 0 { std::ptr::null_mut() } else { Box::into_raw(boxed).cast::<u8>() };
    // SAFETY: `out` is writable per the contract.
    unsafe { out.write(CmuxHomeBytes { ptr, len }) };
    CMUX_HOME_OK
}

/// Frees a reply buffer. A null `ptr` is ignored.
///
/// # Safety
///
/// `bytes` came from `cmux_home_call` and is freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_home_bytes_free(bytes: CmuxHomeBytes) {
    if bytes.ptr.is_null() {
        return;
    }
    // SAFETY: a boxed slice of `len` bytes from `cmux_home_call`.
    drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(bytes.ptr, bytes.len)) });
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;
    use std::ffi::CString;

    fn call(op: &str, request: &str) -> (i32, Option<Value>) {
        let op = CString::new(op).unwrap();
        let mut out = CmuxHomeBytes { ptr: std::ptr::null_mut(), len: 0 };
        // SAFETY: valid pointers for the call.
        let status =
            unsafe { cmux_home_call(op.as_ptr(), request.as_ptr(), request.len(), &mut out) };
        if status != CMUX_HOME_OK {
            return (status, None);
        }
        // SAFETY: the reply buffer the call wrote.
        let reply = unsafe { std::slice::from_raw_parts(out.ptr, out.len) };
        let value = serde_json::from_slice(reply).ok();
        // SAFETY: freed once.
        unsafe { cmux_home_bytes_free(out) };
        (status, value)
    }

    #[test]
    fn ops_list_answers() {
        let (status, reply) = call("ops.list", "{}");
        assert_eq!(status, CMUX_HOME_OK);
        let names: Vec<String> = serde_json::from_value(reply.unwrap()).unwrap();
        assert_eq!(names, cmux_home_rules::ops::op_names());
    }

    #[test]
    fn bad_calls_answer_their_codes() {
        assert_eq!(call("nope", "{}").0, CMUX_HOME_ERR_UNKNOWN_OP);
        assert_eq!(call("inbox.nope", "{}").0, CMUX_HOME_ERR_UNKNOWN_OP);
        assert_eq!(call("ops.list", "[]").0, CMUX_HOME_ERR_INVALID);
        assert_eq!(call("ops.list", "{").0, CMUX_HOME_ERR_INVALID);
    }
}

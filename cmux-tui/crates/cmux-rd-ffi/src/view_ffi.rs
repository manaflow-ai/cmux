//! C ABI of the viewer's rules (`CmuxRdView`, `view/`): one JSON request in,
//! one JSON result out. Every op is pure (state in, next state out); the
//! handle only owns the result bytes, which stay valid until the next call on
//! the same handle. Panics are caught; a panic poisons the handle.

use std::panic::{AssertUnwindSafe, catch_unwind};

use crate::{CMUX_RD_ERR_INVALID, CMUX_RD_ERR_NULL, CMUX_RD_ERR_PANIC, CMUX_RD_OK, bytes_in};

/// The opaque rules handle (`CmuxRdView`).
#[derive(Debug, Default)]
pub struct CmuxRdView {
    result: Vec<u8>,
    poisoned: bool,
}

/// Creates a handle; NULL only when allocation fails.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_rd_view_new() -> *mut CmuxRdView {
    catch_unwind(|| Box::into_raw(Box::<CmuxRdView>::default())).unwrap_or(std::ptr::null_mut())
}

/// Frees a handle; NULL is ignored.
///
/// # Safety
/// `view` is NULL or came from [`cmux_rd_view_new`] and is not used again.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_view_free(view: *mut CmuxRdView) {
    if view.is_null() {
        return;
    }
    // SAFETY: guaranteed by the caller; the box is dropped exactly once.
    let owned = unsafe { Box::from_raw(view) };
    let _ = catch_unwind(AssertUnwindSafe(move || drop(owned)));
}

/// Runs one request (`{"op": ..., ...}`). On `CMUX_RD_OK`, `*result` points
/// at the result JSON until the next call on this handle.
/// `CMUX_RD_ERR_INVALID` when `json` is not a request.
///
/// # Safety
/// `view` is NULL or valid and not used concurrently; `json` is readable for
/// `json_len` bytes; `result` and `result_len` are NULL or writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_view_call(
    view: *mut CmuxRdView,
    json: *const u8,
    json_len: usize,
    result: *mut *const u8,
    result_len: *mut usize,
) -> i32 {
    if result.is_null() || result_len.is_null() {
        return CMUX_RD_ERR_NULL;
    }
    // SAFETY: the caller passes NULL or a live handle, used by one thread.
    let Some(handle) = (unsafe { view.as_mut() }) else { return CMUX_RD_ERR_NULL };
    if handle.poisoned {
        return CMUX_RD_ERR_PANIC;
    }
    // SAFETY: readable for `json_len` bytes by contract.
    let Some(input) = (unsafe { bytes_in(json, json_len) }) else { return CMUX_RD_ERR_NULL };
    let outcome = catch_unwind(AssertUnwindSafe(|| match crate::view::call(input) {
        Ok(value) => {
            handle.result = value.to_string().into_bytes();
            CMUX_RD_OK
        }
        Err(_) => CMUX_RD_ERR_INVALID,
    }));
    let code = match outcome {
        Ok(code) => code,
        Err(_) => {
            handle.poisoned = true;
            return CMUX_RD_ERR_PANIC;
        }
    };
    if code == CMUX_RD_OK {
        // SAFETY: both checked non-NULL; writable by contract.
        unsafe {
            *result = handle.result.as_ptr();
            *result_len = handle.result.len();
        }
    }
    code
}

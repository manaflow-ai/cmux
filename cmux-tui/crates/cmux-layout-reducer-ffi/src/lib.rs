//! Narrow C ABI for `cmux-layout-reducer::sidebar_drop`.

use cmux_layout_reducer::sidebar_drop;
use std::panic::{AssertUnwindSafe, catch_unwind};

pub const ABI_VERSION: u32 = 1;
pub const OK: i32 = 0;
pub const ERR_NULL: i32 = -1;
pub const ERR_INVALID: i32 = -2;
pub const ERR_BUFFER: i32 = -3;
pub const ERR_PANIC: i32 = -4;

unsafe fn input<'a>(ptr: *const u8, len: usize) -> Option<&'a [u8]> {
    if len == 0 {
        return Some(&[]);
    }
    if ptr.is_null() {
        return None;
    }
    // SAFETY: guaranteed by the C caller.
    Some(unsafe { std::slice::from_raw_parts(ptr, len) })
}

unsafe fn write_output(
    bytes: &[u8],
    output: *mut u8,
    capacity: usize,
    output_len: *mut usize,
) -> i32 {
    if output_len.is_null() {
        return ERR_NULL;
    }
    // SAFETY: checked non-null and writable by the C caller.
    unsafe { *output_len = bytes.len() };
    if bytes.len() > capacity {
        return ERR_BUFFER;
    }
    if bytes.is_empty() {
        return OK;
    }
    if output.is_null() {
        return ERR_NULL;
    }
    // SAFETY: the caller provided at least `capacity` writable bytes.
    unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), output, bytes.len()) };
    OK
}

#[unsafe(no_mangle)]
pub extern "C" fn cmux_layout_reducer_ffi_abi_version() -> u32 {
    ABI_VERSION
}

/// Resolves one JSON request. See the checked-in header for the pointer rules.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_layout_reducer_json(
    request: *const u8,
    request_len: usize,
    operation: *const std::ffi::c_char,
    output: *mut u8,
    output_capacity: usize,
    output_len: *mut usize,
) -> i32 {
    let Some(request) = (unsafe { input(request, request_len) }) else { return ERR_NULL };
    if operation.is_null() {
        return ERR_NULL;
    }
    // SAFETY: operation is a NUL-terminated C string owned by the caller.
    let operation = unsafe { std::ffi::CStr::from_ptr(operation) }.to_bytes();
    let result = catch_unwind(AssertUnwindSafe(|| {
        let response = match operation {
            b"base_y" => {
                #[derive(serde::Deserialize)]
                struct BaseY {
                    display_y: f64,
                    gap_y: Option<f64>,
                    gap_height: f64,
                }
                let request: BaseY = serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&sidebar_drop::base_y(
                    request.display_y,
                    request.gap_y,
                    request.gap_height,
                ))
                .map_err(|_| ERR_INVALID)?
            }
            b"resolve" => {
                let request: sidebar_drop::Request =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&sidebar_drop::resolve(&request)).map_err(|_| ERR_INVALID)?
            }
            b"tab_drop" => {
                let request: sidebar_drop::TabRequest =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&sidebar_drop::resolve_tab_drop(&request))
                    .map_err(|_| ERR_INVALID)?
            }
            b"tab_refusal" => {
                let request: sidebar_drop::TabRequest =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&sidebar_drop::tab_drop_refusal(&request))
                    .map_err(|_| ERR_INVALID)?
            }
            _ => return Err(ERR_INVALID),
        };
        Ok(response)
    }));
    match result {
        Ok(Ok(response)) => unsafe { write_output(&response, output, output_capacity, output_len) },
        Ok(Err(code)) => code,
        Err(_) => ERR_PANIC,
    }
}

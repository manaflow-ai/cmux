//! The C ABI of the palette ranker (`include/cmux_palette_ranker.h`), linked into the macOS app
//! through cmux-app-ffi.
//!
//! A host creates one ranker, installs each entry snapshot once per version, then sends one
//! JSON request per keystroke. The response (ranked sections JSON, or an error message) stays
//! owned by the ranker until its next call or until it is freed.

use crate::{Entry, RankRequest, Ranker};
use cmux_ffi_guard::ffi_boundary;

pub const ABI_VERSION: u32 = 1;
pub const OK: i32 = 0;
pub const ERR_NULL: i32 = -1;
pub const ERR_INVALID: i32 = -2;
pub const ERR_NOT_INSTALLED: i32 = -3;
pub const ERR_PANIC: i32 = -4;

/// The opaque ranker handle.
pub struct CmuxPaletteRanker {
    ranker: Ranker,
    response: Vec<u8>,
}

unsafe fn input<'a>(ptr: *const u8, len: usize) -> Option<&'a [u8]> {
    if len == 0 {
        return Some(&[]);
    }
    if ptr.is_null() {
        return None;
    }
    // SAFETY: the C caller guarantees `len` readable bytes at `ptr`.
    Some(unsafe { std::slice::from_raw_parts(ptr, len) })
}

#[unsafe(no_mangle)]
pub extern "C" fn cmux_palette_ranker_abi_version() -> u32 {
    // ffi-nopanic: returns a constant.
    ABI_VERSION
}

/// Creates a ranker. Free it with [`cmux_palette_ranker_free`].
#[unsafe(no_mangle)]
pub extern "C" fn cmux_palette_ranker_new() -> *mut CmuxPaletteRanker {
    ffi_boundary("cmux_palette_ranker_new", std::ptr::null_mut(), || {
        Box::into_raw(Box::new(CmuxPaletteRanker { ranker: Ranker::new(), response: Vec::new() }))
    })
}

/// Frees a ranker from [`cmux_palette_ranker_new`]. Null is ignored.
///
/// # Safety
///
/// `ranker` is null or a live handle from `cmux_palette_ranker_new`, not used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_palette_ranker_free(ranker: *mut CmuxPaletteRanker) {
    ffi_boundary("cmux_palette_ranker_free", (), || {
        if !ranker.is_null() {
            // SAFETY: the caller hands back a handle from `cmux_palette_ranker_new` once.
            drop(unsafe { Box::from_raw(ranker) });
        }
    });
}

/// Installs a JSON array of entries for `version`.
///
/// # Safety
///
/// `ranker` is a live handle; `entries` points to `entries_len` readable bytes (or is null with
/// length 0).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_palette_ranker_install(
    ranker: *mut CmuxPaletteRanker,
    version: i64,
    entries: *const u8,
    entries_len: usize,
) -> i32 {
    ffi_boundary("cmux_palette_ranker_install", ERR_PANIC, || {
        if ranker.is_null() {
            return ERR_NULL;
        }
        let Some(entries) = (unsafe { input(entries, entries_len) }) else { return ERR_NULL };
        // SAFETY: a live handle, used by one caller at a time.
        let handle = unsafe { &mut *ranker };
        match serde_json::from_slice::<Vec<Entry>>(entries) {
            Ok(entries) => {
                handle.ranker.install(version, entries);
                OK
            }
            Err(_) => ERR_INVALID,
        }
    })
}

/// Ranks one JSON request. On `OK` the response is the ranked sections JSON; on an error it is a
/// message, except `ERR_NULL`, which leaves a null response of length 0 (or writes nothing when
/// an out pointer is null). `*response`/`*response_len` stay valid until the next call on this
/// ranker. A handle is not thread-safe: one caller at a time.
///
/// # Safety
///
/// `ranker` is a live handle; `request` points to `request_len` readable bytes; `response` and
/// `response_len` are writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_palette_ranker_rank(
    ranker: *mut CmuxPaletteRanker,
    request: *const u8,
    request_len: usize,
    response: *mut *const u8,
    response_len: *mut usize,
) -> i32 {
    ffi_boundary("cmux_palette_ranker_rank", None, || {
        if response.is_null() || response_len.is_null() {
            return Some(ERR_NULL);
        }
        // SAFETY: both out pointers were checked non-null and are writable by the caller.
        unsafe {
            *response = std::ptr::null();
            *response_len = 0;
        }
        if ranker.is_null() {
            return Some(ERR_NULL);
        }
        let Some(request) = (unsafe { input(request, request_len) }) else { return Some(ERR_NULL) };
        // SAFETY: a live handle, used by one caller at a time.
        let handle = unsafe { &mut *ranker };
        let (code, bytes) = rank_response(&mut handle.ranker, request);
        // SAFETY: both out pointers were checked non-null and are writable by the caller.
        Some(unsafe { handle.respond(code, bytes, response, response_len) })
    })
    .unwrap_or_else(|| {
        // SAFETY: `ranker` is null or a live handle used by one caller.
        match unsafe { ranker.as_mut() } {
            Some(handle) if !response.is_null() && !response_len.is_null() => {
                let message = b"palette ranker panicked".to_vec();
                // SAFETY: both out pointers are non-null and writable by the caller.
                unsafe { handle.respond(ERR_PANIC, message, response, response_len) }
            }
            _ => ERR_PANIC,
        }
    })
}

/// The code and response bytes of one rank request.
fn rank_response(ranker: &mut Ranker, request: &[u8]) -> (i32, Vec<u8>) {
    let request: RankRequest = match serde_json::from_slice(request) {
        Ok(request) => request,
        Err(error) => return (ERR_INVALID, error.to_string().into_bytes()),
    };
    match ranker.rank(&request) {
        Ok(sections) => match serde_json::to_vec(&sections) {
            Ok(bytes) => (OK, bytes),
            Err(error) => (ERR_INVALID, error.to_string().into_bytes()),
        },
        Err(error) => (ERR_NOT_INSTALLED, error.to_string().into_bytes()),
    }
}

impl CmuxPaletteRanker {
    /// Keeps `bytes` as the response and points the caller's outs at it.
    ///
    /// # Safety
    ///
    /// `response` and `response_len` are non-null and writable.
    unsafe fn respond(
        &mut self,
        code: i32,
        bytes: Vec<u8>,
        response: *mut *const u8,
        response_len: *mut usize,
    ) -> i32 {
        self.response = bytes;
        // SAFETY: guaranteed by the caller.
        unsafe {
            *response = self.response.as_ptr();
            *response_len = self.response.len();
        }
        code
    }
}

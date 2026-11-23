//! The C ABI of the action catalog (`include/cmux_action_catalog.h`), linked into the macOS
//! app through cmux-app-ffi.
//!
//! The app asks once at launch for the catalog in its language and decodes the JSON
//! ([`crate::json::catalog`]). Each language's text is built once and kept for the life of the
//! process (at most one per [`crate::LOCALES`] entry), so the returned bytes never move.

use std::collections::HashMap;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::{Mutex, OnceLock};

pub const ABI_VERSION: u32 = 1;
pub const OK: i32 = 0;
pub const ERR_NULL: i32 = -1;
pub const ERR_INVALID: i32 = -2;
pub const ERR_PANIC: i32 = -4;

fn cache() -> &'static Mutex<HashMap<usize, &'static str>> {
    static CACHE: OnceLock<Mutex<HashMap<usize, &'static str>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

/// The catalog JSON for the language at `index`, built once.
fn catalog_text(index: usize) -> &'static str {
    let mut cache = cache().lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    cache.entry(index).or_insert_with(|| Box::leak(crate::json::catalog(index).into_boxed_str()))
}

#[unsafe(no_mangle)]
pub extern "C" fn cmux_action_catalog_abi_version() -> u32 {
    ABI_VERSION
}

/// Writes the catalog JSON for `locale` (a BCP 47 tag such as `ja` or `pt-BR`, UTF-8, not
/// NUL-terminated; empty for English) to `*json`/`*json_len`. The bytes are UTF-8, owned by
/// the library and valid for the life of the process.
///
/// # Safety
///
/// `locale` points to `locale_len` readable bytes (or is null with length 0); `json` and
/// `json_len` are writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_action_catalog_json(
    locale: *const u8,
    locale_len: usize,
    json: *mut *const u8,
    json_len: *mut usize,
) -> i32 {
    if json.is_null() || json_len.is_null() || (locale.is_null() && locale_len != 0) {
        return ERR_NULL;
    }
    let tag = if locale_len == 0 {
        String::new()
    } else {
        // SAFETY: the caller guarantees `locale_len` readable bytes at `locale`.
        let bytes = unsafe { std::slice::from_raw_parts(locale, locale_len) };
        String::from_utf8_lossy(bytes).into_owned()
    };
    let result =
        catch_unwind(AssertUnwindSafe(|| catalog_text(crate::strings::locale_index(&tag))));
    match result {
        Ok(text) => {
            // SAFETY: both out pointers were checked non-null and are writable by the caller.
            unsafe {
                *json = text.as_ptr();
                *json_len = text.len();
            }
            OK
        }
        Err(_) => ERR_PANIC,
    }
}

/// Answers one cmux-next link request (`crate::deep_link::call`): `request` is a JSON object
/// (`{"op": "read", "url": …, "scheme": …}`), the reply its JSON value (null when the URL names
/// no link). The reply is allocated here; free it with `cmux_deep_link_free`.
///
/// Returns `ERR_INVALID` when the request is not JSON or names an unknown op or field.
///
/// # Safety
///
/// `request` points to `request_len` readable bytes (or is null with length 0); `reply` and
/// `reply_len` are writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_deep_link_call(
    request: *const u8,
    request_len: usize,
    reply: *mut *mut u8,
    reply_len: *mut usize,
) -> i32 {
    if reply.is_null() || reply_len.is_null() || (request.is_null() && request_len != 0) {
        return ERR_NULL;
    }
    let bytes: &[u8] = if request_len == 0 {
        &[]
    } else {
        // SAFETY: the caller guarantees `request_len` readable bytes at `request`.
        unsafe { std::slice::from_raw_parts(request, request_len) }
    };
    let result = catch_unwind(AssertUnwindSafe(|| {
        let value: serde_json::Value = serde_json::from_slice(bytes).map_err(|e| e.to_string())?;
        crate::deep_link::call(&value).map(|answer| answer.to_string())
    }));
    match result {
        Ok(Ok(text)) => {
            let boxed = text.into_bytes().into_boxed_slice();
            let len = boxed.len();
            let ptr = Box::into_raw(boxed).cast::<u8>();
            // SAFETY: both out pointers were checked non-null and are writable by the caller.
            unsafe {
                *reply = ptr;
                *reply_len = len;
            }
            OK
        }
        Ok(Err(_)) => ERR_INVALID,
        Err(_) => ERR_PANIC,
    }
}

/// Frees a reply `cmux_deep_link_call` returned. Null is a no-op.
///
/// # Safety
///
/// `reply` and `reply_len` are exactly what one successful `cmux_deep_link_call` wrote, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_deep_link_free(reply: *mut u8, reply_len: usize) {
    if reply.is_null() {
        return;
    }
    // SAFETY: the caller passes back the boxed slice `cmux_deep_link_call` leaked, once.
    drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(reply, reply_len)) });
}

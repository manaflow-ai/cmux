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

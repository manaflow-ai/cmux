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

/// The answer to one JSON request (`{"op": …}`), as JSON: `menu_bar_items` (`state`, `locale`,
/// `bound`), `menu_bar_action_ids`, `profile_menu` (`locale`), `when_parse` (`text`) and
/// `when_text` (`clause`). An unknown op or a request that is not JSON gets `{"error": …}`.
pub fn call(request: &[u8]) -> String {
    let Ok(request) = serde_json::from_slice::<serde_json::Value>(request) else {
        return serde_json::json!({ "error": "the request is not JSON" }).to_string();
    };
    let locale = || request.get("locale").and_then(|v| v.as_str()).unwrap_or("");
    let reply = match request.get("op").and_then(|v| v.as_str()).unwrap_or("") {
        "menu_bar_items" => crate::status_menus::menu_bar_reply(&request),
        "menu_bar_action_ids" => {
            serde_json::json!({ "ids": crate::status_menus::MENU_BAR_ACTION_IDS })
        }
        "profile_menu" => {
            crate::status_menus::profile_menu(&crate::status_menus::Strings::new(locale()))
        }
        "when_parse" => crate::when_clause::parse_reply(
            request.get("text").and_then(|v| v.as_str()).unwrap_or(""),
        ),
        "when_text" => crate::when_clause::text_reply(
            request.get("clause").unwrap_or(&serde_json::Value::Null),
        ),
        op => serde_json::json!({ "error": format!("unknown op {op:?}") }),
    };
    reply.to_string()
}

/// Answers the JSON request at `request`/`request_len` ([`call`]): writes the reply's UTF-8
/// bytes to `*reply`/`*reply_len`, which the caller frees with
/// `cmux_action_catalog_reply_free`.
///
/// # Safety
///
/// `request` points to `request_len` readable bytes (or is null with length 0); `reply` and
/// `reply_len` are writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_action_catalog_call(
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
    match catch_unwind(AssertUnwindSafe(|| call(bytes))) {
        Ok(text) => {
            let boxed = text.into_bytes().into_boxed_slice();
            let len = boxed.len();
            // SAFETY: both out pointers were checked non-null and are writable by the caller.
            unsafe {
                *reply_len = len;
                *reply = Box::into_raw(boxed).cast::<u8>();
            }
            OK
        }
        Err(_) => ERR_PANIC,
    }
}

/// Frees a reply of `cmux_action_catalog_call`.
///
/// # Safety
///
/// `reply`/`reply_len` are exactly what one `cmux_action_catalog_call` wrote, freed once (or
/// `reply` is null).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_action_catalog_reply_free(reply: *mut u8, reply_len: usize) {
    if reply.is_null() {
        return;
    }
    // SAFETY: the pointer and length are a boxed slice `cmux_action_catalog_call` leaked.
    drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(reply, reply_len)) });
}

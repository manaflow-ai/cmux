//! The app's bookmark mirror (`cmux_bookmark_mirror_*`): one handle per app,
//! used from one thread at a time. It keeps each profile's confirmed and
//! shown trees in Rust, so an edit costs only what it changes
//! (cmux-bookmarks-core `mirror`, layer-ownership.md V-11).

use cmux_bookmarks_core::mirror::Mirror;
use std::ffi::{CStr, CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};

/// The C handle.
pub struct BookmarkMirror(Mirror);

/// A new mirror whose local ids come from `seed`. Free it with
/// `cmux_bookmark_mirror_free`.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_bookmark_mirror_new(seed: u64) -> *mut BookmarkMirror {
    Box::into_raw(Box::new(BookmarkMirror(Mirror::new(seed))))
}

/// # Safety
///
/// `mirror` is null or a pointer from `cmux_bookmark_mirror_new` that was not
/// freed yet.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_bookmark_mirror_free(mirror: *mut BookmarkMirror) {
    if !mirror.is_null() {
        // SAFETY: the pointer came from Box::into_raw and is freed once.
        drop(unsafe { Box::from_raw(mirror) });
    }
}

/// Frees a string `cmux_bookmark_mirror_call` returned.
///
/// # Safety
///
/// `text` is null or a string from `cmux_bookmark_mirror_call` that was not
/// freed yet.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_bookmark_mirror_string_free(text: *mut c_char) {
    if !text.is_null() {
        // SAFETY: the pointer came from CString::into_raw and is freed once.
        drop(unsafe { CString::from_raw(text) });
    }
}

/// Runs one call (`load`, `apply`, `settle`, `reject`, `view`, `forget`):
/// JSON in, a newly allocated NUL-terminated JSON string out. Null only for a
/// null handle or call name, or a null input pointer with a non-zero length.
///
/// # Safety
///
/// `mirror` is a live mirror, `call` a NUL-terminated C string, and `json`
/// points to `json_len` readable bytes (or is null with length 0). Free the
/// result with `cmux_bookmark_mirror_string_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_bookmark_mirror_call(
    mirror: *mut BookmarkMirror,
    call: *const c_char,
    json: *const u8,
    json_len: usize,
) -> *mut c_char {
    if mirror.is_null() || call.is_null() {
        return std::ptr::null_mut();
    }
    let Some(bytes) = (unsafe { crate::input(json, json_len) }) else {
        return std::ptr::null_mut();
    };
    // SAFETY: a NUL-terminated C string owned by the caller.
    let name = unsafe { CStr::from_ptr(call) }.to_string_lossy();
    // SAFETY: a live mirror from cmux_bookmark_mirror_new, used by one thread.
    let mirror = unsafe { &mut *mirror };
    let value = catch_unwind(AssertUnwindSafe(|| {
        let _ = (&mirror.0, &name, bytes);
        serde_json::json!({"error": "not wired"})
    }))
    .unwrap_or_else(|_| serde_json::json!({"error": "panic"}));
    let text = serde_json::to_string(&value).unwrap_or_else(|_| "{}".into());
    CString::new(text).map_or(std::ptr::null_mut(), CString::into_raw)
}

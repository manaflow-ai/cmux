//! Narrow C ABI for `cmux-layout-reducer`'s sidebar drop resolver
//! (`sidebar_drop`) and sidebar section layout reducer (`sidebar_layout`),
//! plus `cmux-tasks-core`'s optimistic Tasks preview (`tasks_preview`),
//! `cmux-focus-core`'s per-key rules (`focus_type_ahead`,
//! `focus_child_window_key`) and agent cursor visibility
//! (`agent_cursor_visibility`), the window focus machine (`cmux_focus_*`,
//! [`focus`]: a handle per window, typed events and replies, no JSON),
//! and the sidebar document mirror (`cmux_sidebar_mirror_*`, [`sidebar_mirror`]).

use cmux_layout_reducer::{sidebar_drag, sidebar_drop, sidebar_layout};
use std::ffi::{CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};

pub mod focus;
pub mod sidebar_mirror;
pub mod typed;
use sidebar_mirror::Mirror;

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
///
/// # Safety
///
/// `request` points to `request_len` readable bytes (or is null with length
/// 0), `operation` is a NUL-terminated C string, `output` points to
/// `output_capacity` writable bytes (or is null with capacity 0) and
/// `output_len` is writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_layout_reducer_json(
    request: *const u8,
    request_len: usize,
    operation: *const c_char,
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
            b"resolve_drag" => {
                let request: sidebar_drag::DragRequest =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&sidebar_drag::resolve_drag(&request))
                    .map_err(|_| ERR_INVALID)?
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
            b"sidebar_layout_reduce" => {
                let request: sidebar_layout::Request =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&sidebar_layout::respond(&request)).map_err(|_| ERR_INVALID)?
            }
            b"tasks_preview" => {
                let request: cmux_tasks_core::preview::Request =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&cmux_tasks_core::preview::respond(&request))
                    .map_err(|_| ERR_INVALID)?
            }
            b"focus_type_ahead" => {
                let request: cmux_focus_core::wire::TypeAheadRequest =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&cmux_focus_core::wire::type_ahead(&request))
                    .map_err(|_| ERR_INVALID)?
            }
            b"focus_child_window_key" => {
                let request: cmux_focus_core::wire::ChildWindowKeyRequest =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&cmux_focus_core::wire::child_window_key(&request))
                    .map_err(|_| ERR_INVALID)?
            }
            b"agent_cursor_visibility" => {
                let request: cmux_focus_core::wire::AgentCursorVisibilityRequest =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&cmux_focus_core::wire::agent_cursor_visibility(&request))
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

/// A new sidebar mirror. Free it with `cmux_sidebar_mirror_free`.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_sidebar_mirror_new() -> *mut Mirror {
    Box::into_raw(Box::new(Mirror::new()))
}

/// # Safety
///
/// `mirror` is null or a pointer from `cmux_sidebar_mirror_new` that was not
/// freed yet.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_sidebar_mirror_free(mirror: *mut Mirror) {
    if !mirror.is_null() {
        // SAFETY: the pointer came from Box::into_raw and is freed once.
        drop(unsafe { Box::from_raw(mirror) });
    }
}

/// Frees a string a `cmux_sidebar_mirror_*` call returned.
///
/// # Safety
///
/// `text` is null or a string from a `cmux_sidebar_mirror_*` call that was
/// not freed yet.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_sidebar_mirror_string_free(text: *mut c_char) {
    if !text.is_null() {
        // SAFETY: the pointer came from CString::into_raw and is freed once.
        drop(unsafe { CString::from_raw(text) });
    }
}

/// Run one mirror call: JSON in, a newly allocated NUL-terminated JSON
/// string out (null only for a null mirror or input pointer).
unsafe fn mirror_call(
    mirror: *mut Mirror,
    json: *const u8,
    json_len: usize,
    call: fn(&mut Mirror, &[u8]) -> serde_json::Value,
) -> *mut c_char {
    if mirror.is_null() {
        return std::ptr::null_mut();
    }
    let Some(bytes) = (unsafe { input(json, json_len) }) else { return std::ptr::null_mut() };
    // SAFETY: a live mirror from cmux_sidebar_mirror_new, used by one thread.
    let mirror = unsafe { &mut *mirror };
    let value = catch_unwind(AssertUnwindSafe(|| call(mirror, bytes)))
        .unwrap_or_else(|_| serde_json::json!({"error": "panic"}));
    let text = serde_json::to_string(&value).unwrap_or_else(|_| "{}".into());
    CString::new(text).map_or(std::ptr::null_mut(), CString::into_raw)
}

macro_rules! mirror_entry {
    ($(#[$doc:meta])* $name:ident => $method:ident) => {
        $(#[$doc])*
        ///
        /// # Safety
        ///
        /// `mirror` is a live mirror, `json` points to `json_len` readable
        /// bytes (or is null with length 0). Free the result with
        /// `cmux_sidebar_mirror_string_free`.
        #[unsafe(no_mangle)]
        pub unsafe extern "C" fn $name(
            mirror: *mut Mirror,
            json: *const u8,
            json_len: usize,
        ) -> *mut c_char {
            unsafe { mirror_call(mirror, json, json_len, Mirror::$method) }
        }
    };
}

mirror_entry!(
    /// The confirmed document from `sidebar.get`.
    cmux_sidebar_mirror_load => load
);
mirror_entry!(
    /// One echoed `session.events` batch; drops the matching pending intent.
    cmux_sidebar_mirror_apply_batch => apply_batch
);
mirror_entry!(
    /// One optimistic intent: `{"ok":true,"inverse":[...]}` or `{"refusal":...}`.
    cmux_sidebar_mirror_apply_intent => apply_intent
);
mirror_entry!(
    /// The flat rows of a view request.
    cmux_sidebar_mirror_view => view
);
mirror_entry!(
    /// The acceptance table of a drag over the rows of the last view.
    cmux_sidebar_mirror_drag_begin => drag_begin
);

/// Run one typed mirror call: JSON in, a pointer to a reply the mirror owns
/// (valid until the next typed call on it, or its free); null for a null
/// mirror or input pointer, or a panic.
unsafe fn typed_call<T>(
    mirror: *mut Mirror,
    json: *const u8,
    json_len: usize,
    call: fn(&mut Mirror, &[u8]) -> *const T,
) -> *const T {
    if mirror.is_null() {
        return std::ptr::null();
    }
    let Some(bytes) = (unsafe { input(json, json_len) }) else { return std::ptr::null() };
    // SAFETY: a live mirror from cmux_sidebar_mirror_new, used by one thread.
    let mirror = unsafe { &mut *mirror };
    catch_unwind(AssertUnwindSafe(|| call(mirror, bytes))).unwrap_or(std::ptr::null())
}

macro_rules! typed_entry {
    ($(#[$doc:meta])* $name:ident => $method:ident -> $reply:ty) => {
        $(#[$doc])*
        ///
        /// # Safety
        ///
        /// `mirror` is a live mirror, `json` points to `json_len` readable
        /// bytes (or is null with length 0). The reply belongs to the
        /// mirror: read it before the next typed call; never free it.
        #[unsafe(no_mangle)]
        pub unsafe extern "C" fn $name(
            mirror: *mut Mirror,
            json: *const u8,
            json_len: usize,
        ) -> *const $reply {
            unsafe { typed_call(mirror, json, json_len, Mirror::$method) }
        }
    };
}

typed_entry!(
    /// `load` with a typed status.
    cmux_sidebar_mirror_load_typed => load_typed -> typed::CReply
);
typed_entry!(
    /// `apply_batch` with a typed status.
    cmux_sidebar_mirror_apply_batch_typed => apply_batch_typed -> typed::CReply
);
typed_entry!(
    /// `apply_intent` with a typed status and the stamped ops (JSON bytes).
    cmux_sidebar_mirror_apply_intent_typed => apply_intent_typed -> typed::CReply
);
typed_entry!(
    /// `view` as fixed-size rows and one string table.
    cmux_sidebar_mirror_view_typed => view_typed -> typed::CRows
);
typed_entry!(
    /// `drag_begin` as fixed-size entries and one string table.
    cmux_sidebar_mirror_drag_begin_typed => drag_begin_typed -> typed::CAcceptanceTable
);

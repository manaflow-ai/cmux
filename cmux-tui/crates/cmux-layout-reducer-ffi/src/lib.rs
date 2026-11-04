//! Narrow C ABI for `cmux-layout-reducer`'s sidebar drop resolver
//! (`sidebar_drop`) and sidebar section layout reducer (`sidebar_layout`),
//! plus `cmux-tasks-core`'s optimistic Tasks preview (`tasks_preview`),
//! the group hover card's summary (`group_hover_summary`),
//! `cmux-bookmarks-core`'s optimistic bookmark tree (`bookmarks_apply`: the
//! confirmed listing with the pending ops applied by the daemon's rules),
//! `cmux-cloud-start-core`'s Cloud start decisions (`cloud_harness_login`,
//! one call that reads the harness and both probes' output; `cloud_start_*`:
//! the refusal, the account checks and the folder a start may copy;
//! `cloud_folder_too_broad`, `cloud_vm_kind`, `cloud_login_fingerprint`;
//! `cloud_ask_answer`, `cloud_ask_first`: who may answer an agent's Cloud ask; and
//! `cloud_harness_login_provider`, `cloud_guest_kind`, `cloud_guest_kind_probe`,
//! kept for an app pinned before `cloud_harness_login` read them itself),
//! `cmux-cloud-config`'s rules (`cloud_config_*`: which Cloud a build talks to;
//! `cloud_auth_*`: the auth rules around the app's Keychain I/O;
//! `cloud_vm_agent_key_*`: the VM agent-key mint's request and answer),
//! `cmux-focus-core`'s per-key rules (`focus_type_ahead`,
//! `focus_child_window_key`), agent cursor visibility
//! (`agent_cursor_visibility`) and input invariants (`focus_input_world`,
//! `focus_input_step`, `focus_debug_window`), the window focus machine
//! (`cmux_focus_*`, [`focus`]: a handle per window, typed events and
//! replies, no JSON), the close successor rules (`cmux_close_focus_*`,
//! [`close_focus`]: typed, one call per close), agent cursor visibility for
//! the app (`cmux_agent_cursor_visibility`, [`agent_cursor`]: typed, no JSON,
//! per input event and per motion frame),
//! the sidebar document mirror (`cmux_sidebar_mirror_*`, [`sidebar_mirror`]),
//! the sidebar row face (`cmux_sidebar_face_*`, [`sidebar_face`]: typed
//! requests and replies, no JSON), and the column scroll reducer
//! (`cmux_scroll_*`, [`scroll`]: a handle per scrolling strip, typed events
//! per scroll event and frame).

use cmux_layout_reducer::{sidebar_drag, sidebar_drop, sidebar_layout};
use std::ffi::{CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};

pub mod agent_cursor;
pub mod close_focus;
mod cloud_config;
pub mod focus;
mod imessage;
pub mod input;
pub mod scroll;
pub mod sidebar_face;
pub mod sidebar_mirror;
pub mod tab_drag;
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
            b"imessage" => imessage::respond(request)?,
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
            b"group_hover_summary" => {
                let request: cmux_layout_reducer::group_hover_summary::Request =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&cmux_layout_reducer::group_hover_summary::summarize(&request))
                    .map_err(|_| ERR_INVALID)?
            }
            b"tasks_preview" => {
                let request: cmux_tasks_core::preview::Request =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&cmux_tasks_core::preview::respond(&request))
                    .map_err(|_| ERR_INVALID)?
            }
            b"bookmarks_apply" => {
                let request: cmux_bookmarks_core::preview::Request =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&cmux_bookmarks_core::preview::respond(request))
                    .map_err(|_| ERR_INVALID)?
            }
            b"cloud_harness_login" => {
                use cmux_cloud_start_core::harness_login;
                let request: harness_login::Inputs =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&harness_login::decide(&request)).map_err(|_| ERR_INVALID)?
            }
            b"cloud_start_refusal" => {
                #[derive(serde::Deserialize)]
                #[serde(rename_all = "camelCase")]
                struct Request {
                    cloud_disabled: bool,
                    signed_in: bool,
                }
                let request: Request = serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                let refusal = cmux_cloud_start_core::start::refusal(
                    request.cloud_disabled,
                    request.signed_in,
                );
                serde_json::to_vec(&serde_json::json!({ "refusal": refusal }))
                    .map_err(|_| ERR_INVALID)?
            }
            b"cloud_ask_answer" => {
                use cmux_cloud_start_core::ask;
                #[derive(serde::Deserialize)]
                #[serde(rename_all = "camelCase")]
                struct Request {
                    #[serde(default)]
                    origin: Option<String>,
                    #[serde(default)]
                    agent_session: Option<String>,
                    delegated: bool,
                    selection: String,
                }
                let request: Request = serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                let caller =
                    ask::caller(request.origin.as_deref(), request.agent_session.as_deref());
                let choice = ask::choice(&request.selection);
                let verdict = choice.map(|choice| ask::answer(caller, request.delegated, choice));
                serde_json::to_vec(&serde_json::json!({
                    "caller": caller, "choice": choice, "verdict": verdict,
                }))
                .map_err(|_| ERR_INVALID)?
            }
            b"cloud_ask_first" => {
                #[derive(serde::Deserialize)]
                struct Request {
                    delegated: bool,
                }
                let request: Request = serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                let asks = cmux_cloud_start_core::ask::agent_asks_first(request.delegated);
                serde_json::to_vec(&serde_json::json!({ "asks": asks })).map_err(|_| ERR_INVALID)?
            }
            b"cloud_start_account_text" => {
                #[derive(serde::Deserialize)]
                struct Request {
                    account: Vec<Option<String>>,
                }
                let request: Request = serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                let text = cmux_cloud_start_core::start::account_text(&request.account);
                serde_json::to_vec(&serde_json::json!({ "text": text })).map_err(|_| ERR_INVALID)?
            }
            b"cloud_start_check_account" => {
                #[derive(serde::Deserialize)]
                #[serde(rename_all = "camelCase")]
                struct Request {
                    asked: Vec<Option<String>>,
                    now: Vec<Option<String>>,
                    list_current: bool,
                }
                let request: Request = serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                let check = cmux_cloud_start_core::start::check_account(
                    &request.asked,
                    &request.now,
                    request.list_current,
                );
                serde_json::to_vec(&serde_json::json!({ "check": check }))
                    .map_err(|_| ERR_INVALID)?
            }
            b"cloud_start_uploads" => {
                let request: cmux_cloud_start_core::start::Folder =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                let uploads = cmux_cloud_start_core::start::uploads(&request);
                serde_json::to_vec(&serde_json::json!({ "uploads": uploads }))
                    .map_err(|_| ERR_INVALID)?
            }
            b"cloud_folder_too_broad" => {
                #[derive(serde::Deserialize)]
                struct Request {
                    root: String,
                    home: String,
                }
                let request: Request = serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                let too_broad =
                    cmux_cloud_start_core::start::too_broad(&request.root, &request.home);
                serde_json::to_vec(&serde_json::json!({ "tooBroad": too_broad }))
                    .map_err(|_| ERR_INVALID)?
            }
            b"cloud_vm_kind" => {
                #[derive(serde::Deserialize)]
                #[serde(rename_all = "camelCase")]
                struct Request {
                    #[serde(default)]
                    vm_kind: Option<String>,
                }
                let request: Request = serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&cmux_cloud_start_core::vm_kind::read(
                    request.vm_kind.as_deref(),
                ))
                .map_err(|_| ERR_INVALID)?
            }
            b"cloud_login_fingerprint" => {
                #[derive(serde::Deserialize)]
                struct Request {
                    token: Vec<u8>,
                }
                let request: Request = serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                let fingerprint = cmux_cloud_start_core::machine_login::fingerprint(&request.token);
                serde_json::to_vec(&serde_json::json!({ "fingerprint": fingerprint }))
                    .map_err(|_| ERR_INVALID)?
            }
            b"cloud_harness_login_provider" => {
                #[derive(serde::Deserialize)]
                struct Request {
                    harness: Option<String>,
                }
                let request: Request = serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                let provider = cmux_cloud_start_core::harness_login::login_provider(
                    request.harness.as_deref(),
                );
                serde_json::to_vec(&serde_json::json!({ "provider": provider }))
                    .map_err(|_| ERR_INVALID)?
            }
            b"cloud_guest_kind" => {
                #[derive(serde::Deserialize)]
                struct Request {
                    stdout: String,
                }
                let request: Request = serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                let kind = cmux_cloud_start_core::harness_login::guest_kind(&request.stdout);
                serde_json::to_vec(&serde_json::json!({ "kind": kind })).map_err(|_| ERR_INVALID)?
            }
            b"cloud_guest_kind_probe" => serde_json::to_vec(&serde_json::json!({
                "probe": cmux_cloud_start_core::harness_login::GUEST_KIND_PROBE
            }))
            .map_err(|_| ERR_INVALID)?,
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
            b"focus_input_world" => {
                let request: cmux_focus_core::invariants::Observation =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&cmux_focus_core::wire::input_world(&request))
                    .map_err(|_| ERR_INVALID)?
            }
            b"focus_input_step" => {
                let request: cmux_focus_core::wire::InputStepRequest =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&cmux_focus_core::wire::input_step(&request))
                    .map_err(|_| ERR_INVALID)?
            }
            b"focus_debug_window" => {
                let request: cmux_focus_core::wire::DebugWindowRequest =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&cmux_focus_core::wire::debug_window(&request))
                    .map_err(|_| ERR_INVALID)?
            }
            b"agent_cursor_visibility" => {
                let request: cmux_focus_core::wire::AgentCursorVisibilityRequest =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&cmux_focus_core::wire::agent_cursor_visibility(&request))
                    .map_err(|_| ERR_INVALID)?
            }
            operation if cloud_config::handles(operation) => {
                cloud_config::respond(operation, request)?
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

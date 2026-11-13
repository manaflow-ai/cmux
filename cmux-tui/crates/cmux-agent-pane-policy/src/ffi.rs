//! The C ABI of the pane policy for the macOS app
//! (`include/cmux_agent_pane_policy.h`, Swift module
//! `CCmuxAgentPanePolicyFFI`), linked into the app through cmux-app-ffi.
//!
//! One handle per pane connection ([`Pane`]) holds the state the rules read:
//! the pane's session scope ([`PaneSessions`]) and the permission options and
//! questions the daemon sent ([`PermissionOptions`]). The host feeds it each
//! daemon frame it parsed ([`Pane::observe`]) and what the pane sent (the
//! `sent` op), and runs [`Pane::check`] on every page frame: one call, one
//! JSON reply, in the layout of `tests/cases/check.json`'s `expect`:
//!
//! - `{"refuse": "<code>", "method": m|null, "id": raw|null, "spend": ticket|null}`;
//! - `{"frame": {checked object}, "facts": {...}}` ([`Facts::to_json`]).
//!
//! The host sends a fresh serialization of `frame`, never the page's bytes.
//!
//! The host also says which gesture of the person it holds ([`Gesture`],
//! [`cmux_agent_pane_policy_check_gesture`]): an answer method (`policy.json`
//! `click_only`) that needs a gesture passes on a click only. The check
//! without that argument ([`cmux_agent_pane_policy_check`]) holds no gesture,
//! so it refuses each such frame.
//!
//! What the host decides with its own state (tickets, the click's intent, the
//! folder check on disk) it asks the same rules for, through the JSON ops
//! ([`Pane::call`], [`call`]): the pick of a method and params that came as
//! no frame, the digest an intent holds a question's answers by, a prompt's
//! own id, whether an option is a known allow, and the folder keys.
//!
//! Every function may run on any thread at once (the state is under locks)
//! and none unwinds across the boundary ([`ERR_PANIC`]). A reply buffer
//! ([`CmuxAgentPaneBytes`]) belongs to the caller, who frees it with
//! [`cmux_agent_pane_policy_bytes_free`].

use crate::canonical::canonical_digest;
use crate::check::{Checked, FrameState, GesturePick, PaneScope, check_frame, own_prompt_id};
use crate::data::policy;
use crate::error::Refusal;
use crate::frame::{RefusalNote, raw_id, refusal_frame_noted};
use crate::gesture::{Gesture, PermissionOptions};
use crate::reply::filtered_reply;
use crate::sessions::PaneSessions;
use serde_json::{Map, Value, json};
use std::collections::BTreeSet;
use std::ffi::{CStr, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};

/// Bumped on any change to a type, a function or an op in the header.
pub const ABI_VERSION: u32 = 3;
pub const OK: i32 = 0;
/// `filter_reply`: the method has no reply shape; the host relays the reply as it is.
pub const NO_SHAPE: i32 = 1;
pub const ERR_NULL: i32 = -1;
pub const ERR_INVALID: i32 = -2;
/// The op is not one of the header's.
pub const ERR_UNKNOWN_OP: i32 = -3;
pub const ERR_PANIC: i32 = -4;

/// The inputs of one page frame's check that are not the pane's state.
#[derive(Clone, Copy, Debug, Default)]
pub struct CheckInput<'a> {
    /// The connection's first frame.
    pub first: bool,
    /// The connection is a chat on another machine (no local session starts).
    pub remote_wire: bool,
    /// The LocalApp token for the first frame, if any.
    pub token: Option<&'a str>,
    /// The daemon's mode field names (P1), when known.
    pub mode_fields: Option<&'a BTreeSet<String>>,
    /// The person's gesture the host holds; the default is none, which
    /// refuses every click-only frame that needs a gesture.
    pub gesture: Gesture,
}

/// One pane connection's policy state (the safe core of the C handle).
#[derive(Default)]
pub struct Pane {
    sessions: PaneSessions,
    options: PermissionOptions,
}

impl Pane {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn sessions(&self) -> &PaneSessions {
        &self.sessions
    }

    pub fn options(&self) -> &PermissionOptions {
        &self.options
    }

    /// The full check of one page frame ([`check_frame`]) on this pane's
    /// state, as the reply JSON (see the module docs).
    pub fn check(&self, text: &str, input: &CheckInput<'_>) -> Value {
        let state = FrameState {
            is_first: input.first,
            local_app_token: input.token,
            mode_fields: input.mode_fields,
            remote_wire: input.remote_wire,
            gesture: input.gesture,
            scope: &self.sessions,
            options: &self.options,
        };
        checked_json(check_frame(text, &state))
    }

    /// A daemon frame the host parsed (its id already the page's; `reply_to`:
    /// the request a reply answers). The host's duplicate-key check ran
    /// before: a frame it closed the connection on never comes here. Text
    /// that is not one JSON object is ignored, so nothing is learned from it
    /// (every rule then stays at its deny).
    pub fn observe(&self, text: &str, reply_to: Option<&str>, remote_wire: bool) {
        let Ok(Value::Object(object)) = serde_json::from_str::<Value>(text) else { return };
        self.options.observe(&object, reply_to);
        self.sessions.observe(&object);
        if remote_wire {
            self.sessions.observe_tab_session(&object, reply_to);
        }
    }

    /// One JSON op on this pane (see [`call`] for the ops that need none).
    pub fn call(&self, op: &str, request: &Value) -> Result<Value, i32> {
        let text = |key: &str| request.get(key).and_then(Value::as_str);
        match op {
            "add" => {
                self.sessions.add(text("session").ok_or(ERR_INVALID)?);
                Ok(json!({}))
            }
            "sent" => {
                let owned = request.get("owned").and_then(Value::as_bool).unwrap_or(false);
                self.sessions.sent(
                    text("method").ok_or(ERR_INVALID)?,
                    text("id"),
                    text("handoff"),
                    owned,
                );
                Ok(json!({}))
            }
            "contains" => {
                Ok(json!({"contains": self.sessions.contains(text("session").ok_or(ERR_INVALID)?)}))
            }
            "is_unstarted" => Ok(json!({"unstarted": self.sessions.is_unstarted()})),
            "question_keys" => {
                let keys = self.options.question_keys(text("permission").ok_or(ERR_INVALID)?);
                Ok(json!({"keys": keys}))
            }
            "is_deny" => {
                let deny = self.options.is_deny(
                    text("permission").ok_or(ERR_INVALID)?,
                    text("option").ok_or(ERR_INVALID)?,
                );
                Ok(json!({"deny": deny}))
            }
            "is_known_allow" => {
                let allow = self.options.is_known_allow(
                    text("permission").ok_or(ERR_INVALID)?,
                    text("option").ok_or(ERR_INVALID)?,
                );
                Ok(json!({"allow": allow}))
            }
            other => call(other, request),
        }
    }
}

/// The JSON ops that need no pane:
///
/// - `policy`: the data the host reads once (`initialize`,
///   `maximum_frame_bytes`, `gesture_ticket_key`, `reply_shape_methods`,
///   `question_answers`, `starting`, `handoff_records`, `path_keys`,
///   `click_only`, `click_window_ms`).
/// - `refusal_frame` `{id, code, method?, root_requested?, detail?, reason?}`:
///   `{"frame": text}`, the error frame answering a refused request
///   ([`RefusalNote`] for `detail` and `reason`).
/// - `raw_id` `{value}`: `{"id": raw|null}`, a JSON-RPC id as raw JSON.
/// - `pick` `{method?, params?}`: `{"pick": {"method": m|null, "params":
///   {..}|null}}`, the pick a gesture ticket is bound to ([`GesturePick`]) for
///   a method and params the host has outside a frame check (a page op, a
///   seeded prompt). `params` null: no match.
/// - `own_prompt_id` `{id}`: `{"id": text}`, a prompt's id without a hand-off
///   turn's label ([`own_prompt_id`]).
/// - `canonical_digest` `{value}`: `{"digest": hex|null}`, the sha256 of the
///   value's canonical JSON ([`canonical_digest`]); null when it has none.
pub fn call(op: &str, request: &Value) -> Result<Value, i32> {
    let text = |key: &str| request.get(key).and_then(Value::as_str);
    match op {
        "policy" => Ok(policy_json()),
        "refusal_frame" => {
            let refusal = text("code").and_then(Refusal::from_code).ok_or(ERR_INVALID)?;
            let root = request.get("root_requested").and_then(Value::as_bool).unwrap_or(false);
            let note = RefusalNote { detail: text("detail"), reason: text("reason") };
            let id = text("id").ok_or(ERR_INVALID)?;
            Ok(json!({"frame": refusal_frame_noted(id, refusal, text("method"), root, note)}))
        }
        "raw_id" => Ok(json!({"id": request.get("value").and_then(raw_id)})),
        "pick" => {
            let method = match request.get("method") {
                None | Some(Value::Null) => None,
                Some(Value::String(method)) => Some(method.as_str()),
                Some(_) => return Err(ERR_INVALID),
            };
            let empty = Map::new();
            let params = match request.get("params") {
                None | Some(Value::Null) => &empty,
                Some(Value::Object(params)) => params,
                Some(_) => return Err(ERR_INVALID),
            };
            Ok(json!({"pick": GesturePick::new(method, params).to_json()}))
        }
        "own_prompt_id" => Ok(json!({"id": own_prompt_id(text("id").ok_or(ERR_INVALID)?)})),
        "canonical_digest" => {
            let value = request.get("value").ok_or(ERR_INVALID)?;
            Ok(json!({"digest": canonical_digest(value)}))
        }
        // A pane's own op without a pane.
        op if PANE_OPS.contains(&op) => Err(ERR_NULL),
        _ => Err(ERR_UNKNOWN_OP),
    }
}

/// The ops of [`Pane::call`]: without a pane they answer [`ERR_NULL`].
pub const PANE_OPS: [&str; 7] =
    ["add", "sent", "contains", "is_unstarted", "question_keys", "is_deny", "is_known_allow"];

/// The `policy` op's reply.
pub fn policy_json() -> Value {
    let p = policy();
    let answers = &p.question_answers;
    json!({
        "initialize": p.initialize,
        "maximum_frame_bytes": p.maximum_frame_bytes,
        "gesture_ticket_key": p.gesture_ticket_key,
        "reply_shape_methods": p.reply_shapes.keys().collect::<Vec<_>>(),
        "question_answers": {
            "method": answers.method,
            "param": answers.param,
            "maximum_items": answers.maximum_items,
            "maximum_list_strings": answers.maximum_list_strings,
            "maximum_value_bytes": answers.maximum_value_bytes,
            "annotations_param": answers.annotations_param,
            "maximum_annotation_bytes": answers.maximum_annotation_bytes,
        },
        "starting": crate::sessions::STARTING,
        "handoff_records": crate::sessions::HANDOFF_RECORDS,
        "path_keys": p.path_keys,
        "click_only": p.click_only,
        "click_window_ms": p.click_window_ms,
    })
}

/// A daemon reply to `method`, cut to the method's reply shape and given the
/// page's id; None when the method has no shape or the reply is not one JSON
/// object.
pub fn filter_reply(method: &str, reply: &str, page_id: &str) -> Option<String> {
    let shape = policy().reply_shapes.get(method)?;
    let Ok(Value::Object(object)) = serde_json::from_str::<Value>(reply) else { return None };
    Some(filtered_reply(&object, shape, page_id))
}

/// [`Checked`] as the check reply JSON (see the module docs).
pub fn checked_json(checked: Checked) -> Value {
    match checked {
        Checked::Refuse { refused, spend } => json!({
            "refuse": refused.refusal.code(),
            "method": refused.method,
            "id": refused.request_id,
            "spend": spend,
        }),
        Checked::Frame { frame, facts } => {
            json!({"frame": Value::Object(frame), "facts": facts.to_json()})
        }
    }
}

// ---- The C ABI ----

/// The opaque handle (`CmuxAgentPanePolicy *`).
pub struct CmuxAgentPanePolicy {
    pane: Pane,
}

/// A reply buffer the caller frees with [`cmux_agent_pane_policy_bytes_free`];
/// `ptr` is null when `len` is 0.
#[repr(C)]
#[derive(Debug)]
pub struct CmuxAgentPaneBytes {
    pub ptr: *mut u8,
    pub len: usize,
}

impl CmuxAgentPaneBytes {
    const EMPTY: Self = Self { ptr: std::ptr::null_mut(), len: 0 };

    fn from_vec(bytes: Vec<u8>) -> Self {
        if bytes.is_empty() {
            return Self::EMPTY;
        }
        let boxed = bytes.into_boxed_slice();
        let len = boxed.len();
        Self { ptr: Box::into_raw(boxed).cast::<u8>(), len }
    }
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

/// UTF-8 text at `ptr`, or None (null, or not UTF-8).
unsafe fn text<'a>(ptr: *const u8, len: usize) -> Option<&'a str> {
    // SAFETY: forwarded from the caller.
    std::str::from_utf8(unsafe { input(ptr, len) }?).ok()
}

/// Text that may be absent: null is None, anything else must be UTF-8.
unsafe fn optional_text<'a>(ptr: *const u8, len: usize) -> Result<Option<&'a str>, i32> {
    if ptr.is_null() {
        return Ok(None);
    }
    // SAFETY: forwarded from the caller.
    unsafe { text(ptr, len) }.map(Some).ok_or(ERR_INVALID)
}

/// Writes `value`'s JSON to `out`.
unsafe fn give(out: *mut CmuxAgentPaneBytes, value: &Value) -> i32 {
    let Ok(bytes) = serde_json::to_vec(value) else { return ERR_INVALID };
    // SAFETY: `out` is writable (checked non-null by every caller).
    unsafe { give_bytes(out, bytes) }
}

unsafe fn give_bytes(out: *mut CmuxAgentPaneBytes, bytes: Vec<u8>) -> i32 {
    // SAFETY: `out` is writable (checked non-null by every caller).
    unsafe { *out = CmuxAgentPaneBytes::from_vec(bytes) };
    OK
}

/// Runs `body`, mapping a panic to [`ERR_PANIC`].
fn guarded(body: impl FnOnce() -> i32) -> i32 {
    catch_unwind(AssertUnwindSafe(body)).unwrap_or(ERR_PANIC)
}

#[unsafe(no_mangle)]
pub extern "C" fn cmux_agent_pane_policy_abi_version() -> u32 {
    ABI_VERSION
}

/// A new pane handle. Free it with [`cmux_agent_pane_policy_free`].
#[unsafe(no_mangle)]
pub extern "C" fn cmux_agent_pane_policy_new() -> *mut CmuxAgentPanePolicy {
    Box::into_raw(Box::new(CmuxAgentPanePolicy { pane: Pane::new() }))
}

/// Frees a handle from [`cmux_agent_pane_policy_new`]. Null is ignored.
///
/// # Safety
///
/// `pane` is null or a live handle, not used afterwards by any thread.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_agent_pane_policy_free(pane: *mut CmuxAgentPanePolicy) {
    if !pane.is_null() {
        // SAFETY: the caller hands back a handle from `cmux_agent_pane_policy_new` once.
        drop(unsafe { Box::from_raw(pane) });
    }
}

/// Frees a reply buffer. An empty one (null `ptr`) is ignored.
///
/// # Safety
///
/// `bytes` came from this library and is freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_agent_pane_policy_bytes_free(bytes: CmuxAgentPaneBytes) {
    if !bytes.ptr.is_null() {
        let slice = std::ptr::slice_from_raw_parts_mut(bytes.ptr, bytes.len);
        // SAFETY: `ptr` and `len` are a boxed slice this library gave out.
        drop(unsafe { Box::from_raw(slice) });
    }
}

/// The arguments of one check as the C caller gave them.
struct RawCheck {
    text_ptr: *const u8,
    text_len: usize,
    first: bool,
    remote_wire: bool,
    /// None: a number that is no gesture.
    gesture: Option<Gesture>,
    token: *const u8,
    token_len: usize,
    mode_fields: *const u8,
    mode_fields_len: usize,
}

/// The body of the two check functions.
///
/// # Safety
///
/// As [`cmux_agent_pane_policy_check_gesture`].
unsafe fn check_raw(
    pane: *const CmuxAgentPanePolicy,
    raw: &RawCheck,
    out: *mut CmuxAgentPaneBytes,
) -> i32 {
    if pane.is_null() || out.is_null() {
        return ERR_NULL;
    }
    guarded(|| {
        let Some(gesture) = raw.gesture else { return ERR_INVALID };
        // SAFETY: the caller's pointer rules.
        let Some(frame) = (unsafe { text(raw.text_ptr, raw.text_len) }) else { return ERR_INVALID };
        // SAFETY: as above.
        let token = match unsafe { optional_text(raw.token, raw.token_len) } {
            Ok(token) => token,
            Err(code) => return code,
        };
        // SAFETY: as above.
        let modes = match unsafe { optional_text(raw.mode_fields, raw.mode_fields_len) } {
            Ok(None) => None,
            Ok(Some(json)) => match serde_json::from_str::<BTreeSet<String>>(json) {
                Ok(set) => Some(set),
                Err(_) => return ERR_INVALID,
            },
            Err(code) => return code,
        };
        let input = CheckInput {
            first: raw.first,
            remote_wire: raw.remote_wire,
            token,
            mode_fields: modes.as_ref(),
            gesture,
        };
        // SAFETY: a live handle; the pane's state is under its own locks.
        let pane = unsafe { &(*pane).pane };
        // SAFETY: `out` checked non-null.
        unsafe { give(out, &pane.check(frame, &input)) }
    })
}

/// The full check of one page frame (`text`, UTF-8) on the pane's state:
/// the check reply JSON in `out` (see the module docs). `token`: the
/// LocalApp token (null: none). `mode_fields`: a JSON array of the daemon's
/// mode field names (null: not known). `ERR_INVALID` when an input is not
/// UTF-8 or `mode_fields` is not an array of strings; the host refuses the
/// frame then.
///
/// This function holds no gesture ([`Gesture::None`]): it refuses every
/// click-only frame that needs a gesture (`transport.gesture_required`). A
/// host that relays answers calls [`cmux_agent_pane_policy_check_gesture`].
///
/// # Safety
///
/// `pane` is a live handle; each pointer with its length is readable (or
/// null); `out` is writable.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn cmux_agent_pane_policy_check(
    pane: *const CmuxAgentPanePolicy,
    text_ptr: *const u8,
    text_len: usize,
    first: bool,
    remote_wire: bool,
    token: *const u8,
    token_len: usize,
    mode_fields: *const u8,
    mode_fields_len: usize,
    out: *mut CmuxAgentPaneBytes,
) -> i32 {
    let raw = RawCheck {
        text_ptr,
        text_len,
        first,
        remote_wire,
        gesture: Some(Gesture::None),
        token,
        token_len,
        mode_fields,
        mode_fields_len,
    };
    // SAFETY: forwarded from the caller.
    unsafe { check_raw(pane, &raw, out) }
}

/// [`cmux_agent_pane_policy_check`] with the person's gesture the host
/// holds: `gesture` 0 none, 1 key, 2 click ([`Gesture`], which says what a
/// host may call a click). Any other number is `ERR_INVALID`; the host
/// refuses the frame then.
///
/// # Safety
///
/// `pane` is a live handle; each pointer with its length is readable (or
/// null); `out` is writable.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn cmux_agent_pane_policy_check_gesture(
    pane: *const CmuxAgentPanePolicy,
    text_ptr: *const u8,
    text_len: usize,
    first: bool,
    remote_wire: bool,
    gesture: u8,
    token: *const u8,
    token_len: usize,
    mode_fields: *const u8,
    mode_fields_len: usize,
    out: *mut CmuxAgentPaneBytes,
) -> i32 {
    let raw = RawCheck {
        text_ptr,
        text_len,
        first,
        remote_wire,
        gesture: Gesture::from_abi(gesture),
        token,
        token_len,
        mode_fields,
        mode_fields_len,
    };
    // SAFETY: forwarded from the caller.
    unsafe { check_raw(pane, &raw, out) }
}

/// Feeds one parsed daemon frame (`text`, UTF-8) to the pane's state
/// ([`Pane::observe`]). `reply_to`: the request a reply answers (null: none).
///
/// # Safety
///
/// `pane` is a live handle; each pointer with its length is readable (or null).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_agent_pane_policy_observe(
    pane: *const CmuxAgentPanePolicy,
    text_ptr: *const u8,
    text_len: usize,
    reply_to: *const u8,
    reply_to_len: usize,
    remote_wire: bool,
) -> i32 {
    if pane.is_null() {
        return ERR_NULL;
    }
    guarded(|| {
        // SAFETY: the caller's pointer rules.
        let Some(frame) = (unsafe { text(text_ptr, text_len) }) else { return ERR_INVALID };
        // SAFETY: as above.
        let reply_to = match unsafe { optional_text(reply_to, reply_to_len) } {
            Ok(reply_to) => reply_to,
            Err(code) => return code,
        };
        // SAFETY: a live handle.
        unsafe { &(*pane).pane }.observe(frame, reply_to, remote_wire);
        OK
    })
}

/// A daemon reply to `method` cut to its reply shape with the page's id
/// (`page_id`, raw JSON): [`OK`] and the reply text in `out`, or
/// [`NO_SHAPE`] (nothing written) when the method has no shape or the reply
/// is not one JSON object.
///
/// # Safety
///
/// Each pointer with its length is readable; `out` is writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_agent_pane_policy_filter_reply(
    method: *const u8,
    method_len: usize,
    reply: *const u8,
    reply_len: usize,
    page_id: *const u8,
    page_id_len: usize,
    out: *mut CmuxAgentPaneBytes,
) -> i32 {
    if out.is_null() {
        return ERR_NULL;
    }
    guarded(|| {
        // SAFETY: the caller's pointer rules.
        let (Some(method), Some(reply), Some(page_id)) = (unsafe {
            (text(method, method_len), text(reply, reply_len), text(page_id, page_id_len))
        }) else {
            return ERR_INVALID;
        };
        match filter_reply(method, reply, page_id) {
            // SAFETY: `out` checked non-null.
            Some(filtered) => unsafe { give_bytes(out, filtered.into_bytes()) },
            None => NO_SHAPE,
        }
    })
}

/// One JSON op (`op`, a NUL-terminated name; `request`, a JSON object or
/// empty for `{}`): its reply JSON in `out`. `pane` may be null for the ops
/// of [`call`]; the others refuse it with [`ERR_NULL`].
///
/// # Safety
///
/// `pane` is null or a live handle; `op` is a NUL-terminated string;
/// `request` with its length is readable; `out` is writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_agent_pane_policy_call(
    pane: *const CmuxAgentPanePolicy,
    op: *const c_char,
    request: *const u8,
    request_len: usize,
    out: *mut CmuxAgentPaneBytes,
) -> i32 {
    if op.is_null() || out.is_null() {
        return ERR_NULL;
    }
    guarded(|| {
        // SAFETY: a NUL-terminated string from the caller.
        let Ok(op) = unsafe { CStr::from_ptr(op) }.to_str() else { return ERR_INVALID };
        // SAFETY: the caller's pointer rules.
        let Some(bytes) = (unsafe { input(request, request_len) }) else { return ERR_NULL };
        let request = if bytes.is_empty() {
            Value::Object(Map::new())
        } else {
            match serde_json::from_slice::<Value>(bytes) {
                Ok(value @ Value::Object(_)) => value,
                _ => return ERR_INVALID,
            }
        };
        let reply = if pane.is_null() {
            call(op, &request)
        } else {
            // SAFETY: a live handle.
            unsafe { &(*pane).pane }.call(op, &request)
        };
        match reply {
            // SAFETY: `out` checked non-null.
            Ok(value) => unsafe { give(out, &value) },
            Err(code) => code,
        }
    })
}

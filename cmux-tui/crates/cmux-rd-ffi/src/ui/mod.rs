//! The Mac Screen and cmux Remote UI rules (`cmux_rd_ui_call`): what the
//! Swift views ask and show, decided here. Stateless JSON in, JSON out, no
//! I/O, no clock (a caller passes `now_ms`). One module per Swift area, so
//! each moves on its own:
//!
//! - `remote`: `CmuxRemote/` (sharing setup steps, the share consent, the
//!   `remote.confirm` request, Computer Use activity, the status lines).
//! - `toolbar`, `buttons`, `pane`, `pages`: the viewer chrome's enable and
//!   label rules and layout math (`MacScreenToolbar`, `MacScreenButtons`,
//!   `MacScreenPane`, `MacScreenPages`).
//! - `actions`, `card`, `home_sharing`, `viewer_look`: `MacScreenActions`,
//!   `MacScreenCardView`, `MacScreenHomeView+Sharing`, `MacScreenViewerLook+*`.
//!
//! A request is `{"op": "<area>.<name>", "args": {...}}`; the answer is
//! `{"ok": <value>}` or `{"err": "<why>"}`. Strings shown to the person stay
//! localized in Swift: an answer names which string (a key), never its words.

mod actions;
mod buttons;
mod card;
mod home_sharing;
mod pages;
mod pane;
pub(crate) mod remote;
mod toolbar;
mod viewer_look;

use std::panic::{AssertUnwindSafe, catch_unwind};

use serde_json::{Value, json};

use crate::{CMUX_RD_ERR_NULL, CMUX_RD_ERR_PANIC, CMUX_RD_OK, bytes_in};

/// What one area answers: `None` when it has no such op.
pub(crate) type Answer = Option<Result<Value, String>>;

/// Answers one request (the C entry's body, also used by tests).
pub fn call(request: &[u8]) -> Value {
    let request: Value = match serde_json::from_slice(request) {
        Ok(value) => value,
        Err(error) => return json!({"err": format!("not JSON: {error}")}),
    };
    let Some(op) = request.get("op").and_then(Value::as_str) else {
        return json!({"err": "no op"});
    };
    let args = request.get("args").cloned().unwrap_or(Value::Null);
    let (area, name) = op.split_once('.').unwrap_or((op, ""));
    let answer = match area {
        "remote" => remote::handle(name, &args),
        "toolbar" => toolbar::handle(name, &args),
        "buttons" => buttons::handle(name, &args),
        "pane" => pane::handle(name, &args),
        "pages" => pages::handle(name, &args),
        "actions" => actions::handle(name, &args),
        "card" => card::handle(name, &args),
        "homeSharing" => home_sharing::handle(name, &args),
        "viewerLook" => viewer_look::handle(name, &args),
        _ => None,
    };
    match answer {
        Some(Ok(value)) => json!({"ok": value}),
        Some(Err(why)) => json!({"err": why}),
        None => json!({"err": format!("unknown op {op}")}),
    }
}

/// Decodes `args` into `T`, or says why not.
pub(crate) fn args<T: serde::de::DeserializeOwned>(args: &Value) -> Result<T, String> {
    serde_json::from_value(args.clone()).map_err(|error| format!("bad args: {error}"))
}

/// Encodes an answer.
pub(crate) fn answer<T: serde::Serialize>(value: &T) -> Result<Value, String> {
    serde_json::to_value(value).map_err(|error| error.to_string())
}

/// Answers one request. On `CMUX_RD_OK`, `*out` and `*out_len` hold the
/// answer JSON, which the caller frees with [`cmux_rd_ui_free`].
///
/// # Safety
/// `json` is readable for `json_len` bytes; `out` and `out_len` are NULL or writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_ui_call(
    json: *const u8,
    json_len: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    if out.is_null() || out_len.is_null() {
        return CMUX_RD_ERR_NULL;
    }
    // SAFETY: readable for `json_len` bytes by contract.
    let Some(request) = (unsafe { bytes_in(json, json_len) }) else { return CMUX_RD_ERR_NULL };
    let Ok(bytes) = catch_unwind(AssertUnwindSafe(|| call(request).to_string().into_bytes()))
    else {
        return CMUX_RD_ERR_PANIC;
    };
    let mut boxed = bytes.into_boxed_slice();
    let len = boxed.len();
    let ptr = boxed.as_mut_ptr();
    std::mem::forget(boxed);
    // SAFETY: both checked non-NULL; writable by contract.
    unsafe {
        *out = ptr;
        *out_len = len;
    }
    CMUX_RD_OK
}

/// Frees an answer of [`cmux_rd_ui_call`]; NULL is ignored.
///
/// # Safety
/// `ptr` and `len` came from one [`cmux_rd_ui_call`] and are not used again.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_ui_free(ptr: *mut u8, len: usize) {
    if ptr.is_null() {
        return;
    }
    // SAFETY: the pointer and length of a boxed slice made by `cmux_rd_ui_call`.
    drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len)) });
}

#[cfg(test)]
mod tests;

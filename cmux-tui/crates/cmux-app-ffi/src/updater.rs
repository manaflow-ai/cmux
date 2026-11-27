//! The macOS app updater's decisions (`include/cmux_updater.h`, Swift module
//! `CCmuxUpdaterFFI`): JSON ops the app's CmuxNextUpdater calls instead of
//! deciding in Swift. The ops (`call`):
//!
//! - `update_flow.handle` `{flow, event, preferences}` → `{flow, effects}`: the
//!   install gate over Sparkle's flow (src/updater/update_flow.rs).
//! - `update_flow.card` `{flow, downloadsAutomatically}` → the notice card's
//!   kind, or null.
//! - `update_flow.footer_pill` `{flow, silent}` → the footer pill's kind, or null.
//! - `staged_prewarm.scan` `{installations, bundleIdentifier, build}` → the
//!   newest staged bundle of that build and its runs (`{bundle, runs}`), or
//!   null (src/updater/staged_prewarm.rs). Blocking: reads folders.
//! - `staged_prewarm.read_pages` `{root}` → `{files, pages}`: every page under
//!   `root` read once. Blocking.
//! - `staged_prewarm.describe_exit` `{executable, status}` → the update log's
//!   word for a run's exit.
//! - `staged_prewarm.write_marker` / `staged_prewarm.consume_marker`
//!   `{build, marker}` → whether it was written / named `build` and was taken.
//! - `rollback.decide`, `rollback.previous`: which kept build going back picks,
//!   or why it refuses (src/updater/rollback.rs).
//! - `web_updates.read_pointer`, `web_updates.tree_digest`,
//!   `web_updates.archive_digest`: a web update's pointer, tree and archive
//!   checks (src/updater/web_updates.rs).

use serde::Deserialize;
use serde_json::{Value, json};
use std::ffi::{CStr, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};

/// cbindgen:ignore
pub mod rollback;
/// cbindgen:ignore
pub mod staged_prewarm;
/// cbindgen:ignore
pub mod update_flow;
/// cbindgen:ignore
pub mod web_updates;

/// Bumped on any change to a type, a function or an op.
pub const CMUX_UPDATER_ABI_VERSION: u32 = 4;
/// The op ran; `*out` holds its reply.
pub const CMUX_UPDATER_OK: i32 = 0;
/// A null pointer where one is required.
pub const CMUX_UPDATER_ERR_NULL: i32 = -1;
/// Not UTF-8, or not the JSON the op takes.
pub const CMUX_UPDATER_ERR_INVALID: i32 = -2;
/// The op is not one of the updater's.
pub const CMUX_UPDATER_ERR_UNKNOWN_OP: i32 = -3;
/// A panic inside, caught.
pub const CMUX_UPDATER_ERR_PANIC: i32 = -4;

/// A reply buffer owned by the caller (JSON, UTF-8). `ptr` is null when `len`
/// is 0.
#[repr(C)]
pub struct CmuxUpdaterBytes {
    pub ptr: *mut u8,
    pub len: usize,
}

/// Why an op answered no reply.
#[derive(Debug, PartialEq, Eq)]
pub enum OpError {
    Unknown,
    Invalid(String),
}

fn de<T: for<'a> Deserialize<'a>>(request: &Value) -> Result<T, OpError> {
    T::deserialize(request).map_err(|e| OpError::Invalid(e.to_string()))
}

/// One op on its JSON request.
pub fn call(op: &str, request: &Value) -> Result<Value, OpError> {
    use update_flow::{Event, Flow, Preferences};
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Handle {
        flow: Flow,
        event: Event,
        #[serde(default)]
        preferences: Preferences,
    }
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Card {
        flow: Flow,
        downloads_automatically: bool,
    }
    #[derive(Deserialize)]
    struct Pill {
        flow: Flow,
        silent: bool,
    }
    #[derive(Deserialize)]
    struct Root {
        root: std::path::PathBuf,
    }
    #[derive(Deserialize)]
    struct Exit {
        executable: std::path::PathBuf,
        status: i32,
    }
    #[derive(Deserialize)]
    struct Marker {
        build: String,
        marker: std::path::PathBuf,
    }
    match op {
        "staged_prewarm.scan" => Ok(json!(staged_prewarm::scan(&de(request)?))),
        "staged_prewarm.read_pages" => {
            let Root { root } = de(request)?;
            Ok(json!(staged_prewarm::read_pages(&root)))
        }
        "staged_prewarm.describe_exit" => {
            let Exit { executable, status } = de(request)?;
            Ok(json!(staged_prewarm::describe_exit(&executable, status)))
        }
        "staged_prewarm.write_marker" => {
            let Marker { build, marker } = de(request)?;
            Ok(json!(staged_prewarm::write_marker(&build, &marker)))
        }
        "staged_prewarm.consume_marker" => {
            let Marker { build, marker } = de(request)?;
            Ok(json!(staged_prewarm::consume_marker(&build, &marker)))
        }
        "update_flow.handle" => {
            let Handle { mut flow, event, preferences } = de(request)?;
            let effects = flow.handle(event, preferences);
            Ok(json!({ "flow": flow, "effects": effects }))
        }
        "update_flow.card" => {
            let Card { flow, downloads_automatically } = de(request)?;
            Ok(json!(flow.card(downloads_automatically)))
        }
        "update_flow.footer_pill" => {
            let Pill { flow, silent } = de(request)?;
            Ok(json!(flow.footer_pill(silent)))
        }
        op if op.starts_with("rollback.") => rollback::call(op, request),
        op if op.starts_with("web_updates.") => web_updates::call(op, request),
        _ => Err(OpError::Unknown),
    }
}

/// `CMUX_UPDATER_ABI_VERSION`.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_updater_abi_version() -> u32 {
    CMUX_UPDATER_ABI_VERSION
}

/// Runs one JSON op: `op` (NUL-terminated, such as `update_flow.handle`) on
/// `request` (a JSON object, UTF-8); `*out` gets the reply's JSON, which the
/// caller frees with `cmux_updater_bytes_free`.
///
/// # Safety
///
/// `op` is a NUL-terminated string; `request_ptr` with `request_len` is
/// readable; `out` is writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_updater_call(
    op: *const c_char,
    request_ptr: *const u8,
    request_len: usize,
    out: *mut CmuxUpdaterBytes,
) -> i32 {
    if op.is_null() || out.is_null() || (request_ptr.is_null() && request_len != 0) {
        return CMUX_UPDATER_ERR_NULL;
    }
    let result = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: a NUL-terminated string from the caller.
        let Ok(op) = unsafe { CStr::from_ptr(op) }.to_str() else {
            return Err(CMUX_UPDATER_ERR_INVALID);
        };
        let bytes: &[u8] = if request_len == 0 {
            &[]
        } else {
            // SAFETY: readable for `request_len` bytes per the contract.
            unsafe { std::slice::from_raw_parts(request_ptr, request_len) }
        };
        let request = match serde_json::from_slice::<Value>(bytes) {
            Ok(value @ Value::Object(_)) => value,
            _ => return Err(CMUX_UPDATER_ERR_INVALID),
        };
        match call(op, &request) {
            Ok(reply) => Ok(serde_json::to_vec(&reply).unwrap_or_default()),
            Err(OpError::Unknown) => Err(CMUX_UPDATER_ERR_UNKNOWN_OP),
            Err(OpError::Invalid(_)) => Err(CMUX_UPDATER_ERR_INVALID),
        }
    }));
    let reply = match result {
        Ok(Ok(reply)) => reply,
        Ok(Err(code)) => return code,
        Err(_) => return CMUX_UPDATER_ERR_PANIC,
    };
    let boxed = reply.into_boxed_slice();
    let len = boxed.len();
    let ptr = if len == 0 { std::ptr::null_mut() } else { Box::into_raw(boxed).cast::<u8>() };
    // SAFETY: `out` is writable per the contract.
    unsafe { out.write(CmuxUpdaterBytes { ptr, len }) };
    CMUX_UPDATER_OK
}

/// Frees a reply buffer. A null `ptr` is ignored.
///
/// # Safety
///
/// `bytes` came from `cmux_updater_call` and is freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_updater_bytes_free(bytes: CmuxUpdaterBytes) {
    if bytes.ptr.is_null() {
        return;
    }
    // SAFETY: a boxed slice of `len` bytes from `cmux_updater_call`.
    drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(bytes.ptr, bytes.len)) });
}

#[cfg(test)]
#[path = "updater_tests.rs"]
mod tests;

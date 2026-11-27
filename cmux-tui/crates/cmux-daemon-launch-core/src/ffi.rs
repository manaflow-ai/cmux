//! The C ABI of the daemon launch rules for the macOS app
//! (`include/cmux_daemon_launch.h`, Swift module `CCmuxDaemonLaunchFFI`),
//! linked into the app through cmux-app-ffi.
//!
//! - `cmux_daemon_launch_call`: one JSON op ([`crate::ops::call`]).
//! - `cmux_daemon_launch_login_env_accept`: the login shell's raw output
//!   (NUL-separated, maybe not UTF-8) to its environment.
//! - `cmux_daemon_launch_lines_*`: a child's stderr cut into lines.
//! - `cmux_daemon_launch_watch_*`: the unresponsive-owner watch's state.
//!
//! Every function may run on any thread; a handle is used by one thread at a
//! time (the app holds it under its own lock). None unwinds across the
//! boundary. A reply buffer belongs to the caller, who frees it with
//! `cmux_daemon_launch_bytes_free`.

use crate::failure::EnsureKind;
use crate::lines::Lines;
use crate::ops::{OpError, call};
use crate::watch::{Policy, Watch};
use serde_json::{Map, Value, json};
use std::ffi::{CStr, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};

/// Bumped on any change to a type, a function or an op.
pub const CMUX_DAEMON_LAUNCH_ABI_VERSION: u32 = 1;
pub const CMUX_DAEMON_LAUNCH_OK: i32 = 0;
/// A null pointer where one is required.
pub const CMUX_DAEMON_LAUNCH_ERR_NULL: i32 = -1;
/// Not UTF-8, or not the JSON the op takes.
pub const CMUX_DAEMON_LAUNCH_ERR_INVALID: i32 = -2;
/// The op is not one of the header's.
pub const CMUX_DAEMON_LAUNCH_ERR_UNKNOWN_OP: i32 = -3;
/// A panic inside, caught.
pub const CMUX_DAEMON_LAUNCH_ERR_PANIC: i32 = -4;

/// A reply buffer owned by the caller (JSON, UTF-8). `ptr` is null when
/// `len` is 0.
#[repr(C)]
pub struct CmuxDaemonLaunchBytes {
    pub ptr: *mut u8,
    pub len: usize,
}

impl CmuxDaemonLaunchBytes {
    fn from_vec(bytes: Vec<u8>) -> Self {
        if bytes.is_empty() {
            return Self { ptr: std::ptr::null_mut(), len: 0 };
        }
        let boxed = bytes.into_boxed_slice();
        let len = boxed.len();
        Self { ptr: Box::into_raw(boxed).cast::<u8>(), len }
    }
}

/// A child's stderr line splitter.
pub struct CmuxDaemonLaunchLines {
    lines: Lines,
}

/// One unresponsive-owner watch.
pub struct CmuxDaemonLaunchWatch {
    watch: Watch,
}

fn guarded(body: impl FnOnce() -> i32) -> i32 {
    catch_unwind(AssertUnwindSafe(body)).unwrap_or(CMUX_DAEMON_LAUNCH_ERR_PANIC)
}

/// The bytes at `ptr` (empty when `len` is 0); none for a null pointer with a length.
unsafe fn input<'a>(ptr: *const u8, len: usize) -> Option<&'a [u8]> {
    if len == 0 {
        return Some(&[]);
    }
    if ptr.is_null() {
        return None;
    }
    // SAFETY: the caller's pointer is readable for `len` bytes.
    Some(unsafe { std::slice::from_raw_parts(ptr, len) })
}

/// The request object (`{}` when empty).
fn request(bytes: &[u8]) -> Result<Value, i32> {
    if bytes.is_empty() {
        return Ok(Value::Object(Map::new()));
    }
    match serde_json::from_slice::<Value>(bytes) {
        Ok(value @ Value::Object(_)) => Ok(value),
        _ => Err(CMUX_DAEMON_LAUNCH_ERR_INVALID),
    }
}

/// Writes `value`'s JSON to `out`.
unsafe fn give(out: *mut CmuxDaemonLaunchBytes, value: &Value) -> i32 {
    let Ok(bytes) = serde_json::to_vec(value) else { return CMUX_DAEMON_LAUNCH_ERR_INVALID };
    // SAFETY: `out` is writable (checked non-null by every caller).
    unsafe { *out = CmuxDaemonLaunchBytes::from_vec(bytes) };
    CMUX_DAEMON_LAUNCH_OK
}

fn op_code(error: OpError) -> i32 {
    match error {
        OpError::Unknown => CMUX_DAEMON_LAUNCH_ERR_UNKNOWN_OP,
        OpError::Invalid => CMUX_DAEMON_LAUNCH_ERR_INVALID,
    }
}

/// `CMUX_DAEMON_LAUNCH_ABI_VERSION`.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_daemon_launch_abi_version() -> u32 {
    CMUX_DAEMON_LAUNCH_ABI_VERSION
}

/// Frees a reply buffer. A null `ptr` is ignored.
///
/// # Safety
///
/// `bytes` came from this library and is freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_daemon_launch_bytes_free(bytes: CmuxDaemonLaunchBytes) {
    if bytes.ptr.is_null() {
        return;
    }
    // SAFETY: built by `from_vec` from a boxed slice of `len` bytes.
    drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(bytes.ptr, bytes.len)) });
}

/// Runs one JSON op: `op` (NUL-terminated) on `request` (a JSON object,
/// UTF-8; empty means `{}`); `*out` gets the reply's JSON.
///
/// # Safety
///
/// `op` is a NUL-terminated string; `request` with its length is readable;
/// `out` is writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_daemon_launch_call(
    op: *const c_char,
    request_ptr: *const u8,
    request_len: usize,
    out: *mut CmuxDaemonLaunchBytes,
) -> i32 {
    if op.is_null() || out.is_null() {
        return CMUX_DAEMON_LAUNCH_ERR_NULL;
    }
    guarded(|| {
        // SAFETY: a NUL-terminated string from the caller.
        let Ok(op) = unsafe { CStr::from_ptr(op) }.to_str() else {
            return CMUX_DAEMON_LAUNCH_ERR_INVALID;
        };
        // SAFETY: the caller's pointer rules.
        let Some(bytes) = (unsafe { input(request_ptr, request_len) }) else {
            return CMUX_DAEMON_LAUNCH_ERR_NULL;
        };
        let request = match request(bytes) {
            Ok(request) => request,
            Err(code) => return code,
        };
        match call(op, &request) {
            // SAFETY: `out` checked non-null.
            Ok(value) => unsafe { give(out, &value) },
            Err(error) => op_code(error),
        }
    })
}

/// The login shell's capture (`status` and its raw stdout): `*out` gets the
/// environment object, or `null` when the capture is not one the app keeps.
///
/// # Safety
///
/// `output` with its length is readable; `out` is writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_daemon_launch_login_env_accept(
    status: i32,
    output: *const u8,
    output_len: usize,
    out: *mut CmuxDaemonLaunchBytes,
) -> i32 {
    if out.is_null() {
        return CMUX_DAEMON_LAUNCH_ERR_NULL;
    }
    guarded(|| {
        // SAFETY: the caller's pointer rules.
        let Some(bytes) = (unsafe { input(output, output_len) }) else {
            return CMUX_DAEMON_LAUNCH_ERR_NULL;
        };
        let env = crate::login_env::accept(status, bytes);
        let value = serde_json::to_value(env).unwrap_or(Value::Null);
        // SAFETY: `out` checked non-null.
        unsafe { give(out, &value) }
    })
}

/// A new stderr line splitter. Free it with `cmux_daemon_launch_lines_free`.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_daemon_launch_lines_new() -> *mut CmuxDaemonLaunchLines {
    Box::into_raw(Box::new(CmuxDaemonLaunchLines { lines: Lines::new() }))
}

/// Frees a splitter. Null is ignored.
///
/// # Safety
///
/// `lines` is null or a live handle, not used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_daemon_launch_lines_free(lines: *mut CmuxDaemonLaunchLines) {
    if !lines.is_null() {
        // SAFETY: from `cmux_daemon_launch_lines_new`, freed once.
        drop(unsafe { Box::from_raw(lines) });
    }
}

/// Adds stderr bytes; `*out` gets the JSON array of the lines they complete.
/// `finish` true: the child exited, the last line without a newline too,
/// and nothing after it.
///
/// # Safety
///
/// `lines` is a live handle used by one thread at a time; `bytes` with its
/// length is readable; `out` is writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_daemon_launch_lines_push(
    lines: *mut CmuxDaemonLaunchLines,
    bytes: *const u8,
    bytes_len: usize,
    finish: bool,
    out: *mut CmuxDaemonLaunchBytes,
) -> i32 {
    if lines.is_null() || out.is_null() {
        return CMUX_DAEMON_LAUNCH_ERR_NULL;
    }
    guarded(|| {
        // SAFETY: the caller's pointer rules.
        let Some(bytes) = (unsafe { input(bytes, bytes_len) }) else {
            return CMUX_DAEMON_LAUNCH_ERR_NULL;
        };
        // SAFETY: a live handle, one thread at a time.
        let splitter = unsafe { &mut (*lines).lines };
        let mut done = splitter.push(bytes);
        if finish {
            done.extend(splitter.finish());
        }
        // SAFETY: `out` checked non-null.
        unsafe { give(out, &json!(done)) }
    })
}

/// A new watch with `policy` (JSON `{"sustainedMs", "stuckEnsures",
/// "perLaunch"}`; empty: the standard policy). Null on invalid JSON.
///
/// # Safety
///
/// `policy` with its length is readable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_daemon_launch_watch_new(
    policy: *const u8,
    policy_len: usize,
) -> *mut CmuxDaemonLaunchWatch {
    let made = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: the caller's pointer rules.
        let bytes = unsafe { input(policy, policy_len) }?;
        let policy =
            if bytes.is_empty() { Policy::STANDARD } else { serde_json::from_slice(bytes).ok()? };
        Some(Box::into_raw(Box::new(CmuxDaemonLaunchWatch { watch: Watch::new(policy) })))
    }));
    made.ok().flatten().unwrap_or(std::ptr::null_mut())
}

/// Frees a watch. Null is ignored.
///
/// # Safety
///
/// `watch` is null or a live handle, not used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_daemon_launch_watch_free(watch: *mut CmuxDaemonLaunchWatch) {
    if !watch.is_null() {
        // SAFETY: from `cmux_daemon_launch_watch_new`, freed once.
        drop(unsafe { Box::from_raw(watch) });
    }
}

/// One watch op (`note`, `window_passed`, `evaluate`, `claim`, `finish`,
/// `stop`, `replace_count`) on `request` (JSON); `*out` gets its reply.
///
/// # Safety
///
/// `watch` is a live handle used by one thread at a time; `op` is a
/// NUL-terminated string; `request` with its length is readable; `out` is
/// writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_daemon_launch_watch_call(
    watch: *mut CmuxDaemonLaunchWatch,
    op: *const c_char,
    request_ptr: *const u8,
    request_len: usize,
    out: *mut CmuxDaemonLaunchBytes,
) -> i32 {
    if watch.is_null() || op.is_null() || out.is_null() {
        return CMUX_DAEMON_LAUNCH_ERR_NULL;
    }
    guarded(|| {
        // SAFETY: a NUL-terminated string from the caller.
        let Ok(op) = unsafe { CStr::from_ptr(op) }.to_str() else {
            return CMUX_DAEMON_LAUNCH_ERR_INVALID;
        };
        // SAFETY: the caller's pointer rules.
        let Some(bytes) = (unsafe { input(request_ptr, request_len) }) else {
            return CMUX_DAEMON_LAUNCH_ERR_NULL;
        };
        let request = match request(bytes) {
            Ok(request) => request,
            Err(code) => return code,
        };
        // SAFETY: a live handle, one thread at a time.
        let watch = unsafe { &mut (*watch).watch };
        match watch_call(watch, op, &request) {
            // SAFETY: `out` checked non-null.
            Ok(value) => unsafe { give(out, &value) },
            Err(error) => op_code(error),
        }
    })
}

/// The watch ops, for the C ABI and the tests.
pub fn watch_call(watch: &mut Watch, op: &str, request: &Value) -> Result<Value, OpError> {
    let enabled = request.get("enabled").and_then(Value::as_bool).unwrap_or(false);
    let streak = request.get("streak").and_then(Value::as_u64);
    let owner = request.get("owner").and_then(Value::as_i64).and_then(|o| i32::try_from(o).ok());
    let value = |effects| serde_json::to_value(effects).map_err(|_| OpError::Invalid);
    match op {
        "note" => {
            let ensure: EnsureKind =
                serde_json::from_value(request.get("ensure").cloned().unwrap_or(Value::Null))
                    .map_err(|_| OpError::Invalid)?;
            value(watch.note(ensure, enabled))
        }
        "window_passed" => value(watch.window_passed(streak.ok_or(OpError::Invalid)?, enabled)),
        "evaluate" => serde_json::to_value(watch.evaluate(enabled)).map_err(|_| OpError::Invalid),
        "claim" => {
            let (yes, effects) = watch.claim(streak.ok_or(OpError::Invalid)?, owner, enabled);
            let mut reply = value(effects)?;
            if let Value::Object(map) = &mut reply {
                map.insert("yes".into(), Value::Bool(yes));
            }
            Ok(reply)
        }
        "finish" => {
            watch.finish(streak.ok_or(OpError::Invalid)?, owner);
            Ok(json!({}))
        }
        "stop" => value(watch.stop()),
        "replace_count" => Ok(json!(watch.replace_count())),
        _ => Err(OpError::Unknown),
    }
}

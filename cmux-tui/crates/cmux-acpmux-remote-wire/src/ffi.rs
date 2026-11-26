//! The C ABI of the remote chat wire for the macOS app (`include/cmux_acpmux_remote_wire.h`),
//! linked into the app through cmux-app-ffi.
//!
//! One wire per remote chat. Every call takes UTF-8 text and returns a JSON text the caller frees
//! with `cmux_acpmux_remote_wire_string_free`: `{"accepted":bool,"effects":[...]}` for a frame,
//! a JSON array of effects for the other inputs. A null wire or text returns null. A wire is used by
//! one thread at a time. No function unwinds across the boundary.

use crate::wire::{Config, Event, Failure, Wire};
use std::ffi::{CStr, CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};

/// Bumped on any change to a type or a function.
pub const CMUX_ACPMUX_REMOTE_WIRE_ABI_VERSION: u32 = 1;

/// One remote chat's wire.
pub struct CmuxAcpmuxRemoteWire {
    inner: Wire,
}

fn guard<T>(fallback: T, body: impl FnOnce() -> T) -> T {
    catch_unwind(AssertUnwindSafe(body)).unwrap_or(fallback)
}

fn text<'a>(raw: *const c_char) -> Option<&'a str> {
    // SAFETY: caller contract: null or a NUL-terminated string that lives through the call.
    if raw.is_null() {
        return None;
    }
    // SAFETY: non-null, and the caller's contract makes it a NUL-terminated string.
    unsafe { CStr::from_ptr(raw) }.to_str().ok()
}

fn out(json: String) -> *mut c_char {
    CString::new(json).map_or(std::ptr::null_mut(), CString::into_raw)
}

fn effects(list: &[crate::wire::Effect]) -> *mut c_char {
    serde_json::to_string(list).map_or(std::ptr::null_mut(), out)
}

/// The ABI version of this library.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_acpmux_remote_wire_abi_version() -> u32 {
    CMUX_ACPMUX_REMOTE_WIRE_ABI_VERSION
}

/// A new wire from its configuration (a JSON object; absent keys take their defaults), or null when
/// the text is not one. Free it with `cmux_acpmux_remote_wire_free`.
///
/// # Safety
/// `config` is null or a NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_acpmux_remote_wire_new(
    config: *const c_char,
) -> *mut CmuxAcpmuxRemoteWire {
    let Some(config) = text(config).and_then(|t| serde_json::from_str::<Config>(t).ok()) else {
        return std::ptr::null_mut();
    };
    guard(std::ptr::null_mut(), || {
        Box::into_raw(Box::new(CmuxAcpmuxRemoteWire { inner: Wire::new(config) }))
    })
}

/// Frees a wire; null does nothing.
///
/// # Safety
/// `wire` is null or from `cmux_acpmux_remote_wire_new`, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_acpmux_remote_wire_free(wire: *mut CmuxAcpmuxRemoteWire) {
    if !wire.is_null() {
        // SAFETY: from `Box::into_raw` in `cmux_acpmux_remote_wire_new`, freed once.
        drop(unsafe { Box::from_raw(wire) });
    }
}

/// Frees a text this library returned; null does nothing.
///
/// # Safety
/// `string` is null or returned by this library, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_acpmux_remote_wire_string_free(string: *mut c_char) {
    if !string.is_null() {
        // SAFETY: from `CString::into_raw` in this library, freed once.
        drop(unsafe { CString::from_raw(string) });
    }
}

/// One page frame: `{"accepted":bool,"effects":[...]}`.
///
/// # Safety
/// `wire` is null or live and used by no other thread; `frame` is null or a NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_acpmux_remote_wire_frame(
    wire: *mut CmuxAcpmuxRemoteWire,
    frame: *const c_char,
) -> *mut c_char {
    // SAFETY: caller contract.
    let (Some(wire), Some(frame)) = (unsafe { wire.as_mut() }, text(frame)) else {
        return std::ptr::null_mut();
    };
    guard(std::ptr::null_mut(), || {
        serde_json::to_string(&wire.inner.frame(frame)).map_or(std::ptr::null_mut(), out)
    })
}

/// One daemon push (`{"kind":"record"|"permission"|"changed"|"presence"|"closed",...}`): an array
/// of effects.
///
/// # Safety
/// As `cmux_acpmux_remote_wire_frame`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_acpmux_remote_wire_event(
    wire: *mut CmuxAcpmuxRemoteWire,
    event: *const c_char,
) -> *mut c_char {
    // SAFETY: caller contract.
    let (Some(wire), Some(event)) = (unsafe { wire.as_mut() }, text(event)) else {
        return std::ptr::null_mut();
    };
    let Ok(event) = serde_json::from_str::<Event>(event) else { return std::ptr::null_mut() };
    guard(std::ptr::null_mut(), || effects(&wire.inner.event(event)))
}

/// The page's path ended: an array of effects.
///
/// # Safety
/// `wire` is null or live and used by no other thread.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_acpmux_remote_wire_cancel(
    wire: *mut CmuxAcpmuxRemoteWire,
) -> *mut c_char {
    // SAFETY: caller contract.
    let Some(wire) = (unsafe { wire.as_mut() }) else { return std::ptr::null_mut() };
    guard(std::ptr::null_mut(), || effects(&wire.inner.cancel()))
}

/// The answer of the call `task` asked for: `ok` with the daemon's JSON as `body`, or not `ok` with a
/// failure object (`{"code","message","folder","facts"}`) as `body`. An array of effects.
///
/// # Safety
/// As `cmux_acpmux_remote_wire_frame`, with `body`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_acpmux_remote_wire_done(
    wire: *mut CmuxAcpmuxRemoteWire,
    task: u64,
    ok: bool,
    body: *const c_char,
) -> *mut c_char {
    // SAFETY: caller contract.
    let (Some(wire), Some(body)) = (unsafe { wire.as_mut() }, text(body)) else {
        return std::ptr::null_mut();
    };
    let outcome = if ok {
        Ok(body.to_owned())
    } else {
        Err(serde_json::from_str::<Failure>(body).unwrap_or_default())
    };
    guard(std::ptr::null_mut(), || effects(&wire.inner.done(task, outcome)))
}

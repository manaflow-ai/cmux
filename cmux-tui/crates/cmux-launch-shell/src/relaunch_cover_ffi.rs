//! The C ABI of the relaunch cover (include/cmux_launch_shell.h): the old process writes the
//! manifest at quit, the new process takes it once, plans, and keeps one `Reveal` per launch.
//! Plans and steps cross as JSON (a handful per launch, never on a hot path); the app frees every
//! returned string with `cmux_relaunch_cover_string_free`.
use std::ffi::{CStr, CString, c_char};
use std::path::Path;

use crate::ffi::CmuxLaunchShellDisplay;
use crate::plan::{Display, Frame};
use crate::relaunch_cover::{
    CoverManifest, CoverNow, CoverPlan, CoverReason, Reveal, RevealStep, SwapStyle, clear_images,
    cover_plan, take, write,
};

unsafe fn c_str<'a>(p: *const c_char) -> Option<&'a str> {
    if p.is_null() { None } else { unsafe { CStr::from_ptr(p) }.to_str().ok() }
}

fn c_string(s: String) -> *mut c_char {
    CString::new(s).map_or(std::ptr::null_mut(), CString::into_raw)
}

fn steps_json(steps: &[RevealStep]) -> *mut c_char {
    c_string(serde_json::to_string(steps).unwrap_or_else(|_| "[]".into()))
}

/// Frees a string this module returned. Null does nothing.
///
/// # Safety
/// `s` is null or a pointer a `cmux_relaunch_cover_*` function returned, not yet freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_relaunch_cover_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(unsafe { CString::from_raw(s) });
    }
}

/// Writes `manifest_json` (a `CoverManifest`) into `dir` atomically, after the app wrote the
/// pictures there. False when it is not a well-formed manifest or the write failed.
///
/// # Safety
/// Both arguments are null or NUL-terminated strings.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_relaunch_cover_write(
    dir: *const c_char,
    manifest_json: *const c_char,
) -> bool {
    let (Some(dir), Some(json)) = (unsafe { c_str(dir) }, unsafe { c_str(manifest_json) }) else {
        return false;
    };
    CoverManifest::from_json(json).is_some_and(|m| write(Path::new(dir), &m).is_ok())
}

/// Takes the manifest in `dir` (it is removed whatever it held) and returns the plan as JSON
/// (`CoverPlan`: `reason`, `failed_window`, `windows` front first). `restoring_json` is a JSON
/// array of the window ids this launch opens. When the plan does not show, the pictures are
/// removed at once; when it shows, the app calls `cmux_relaunch_cover_clear` once every cover is
/// gone. Null only for a null or non-UTF-8 argument.
///
/// # Safety
/// `dir` and `restoring_json` are null or NUL-terminated strings; `displays` is valid for reads
/// of `display_count` displays (or null with a count of 0).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_relaunch_cover_take_plan(
    dir: *const c_char,
    now_ms: u64,
    max_age_ms: u64,
    displays: *const CmuxLaunchShellDisplay,
    display_count: usize,
    restoring_json: *const c_char,
) -> *mut c_char {
    let (Some(dir), Some(restoring)) = (unsafe { c_str(dir) }, unsafe { c_str(restoring_json) })
    else {
        return std::ptr::null_mut();
    };
    let displays: Vec<Display> = if displays.is_null() || display_count == 0 {
        Vec::new()
    } else {
        unsafe { std::slice::from_raw_parts(displays, display_count) }
            .iter()
            .map(|d| Display {
                frame: Frame { x: d.x, y: d.y, width: d.width, height: d.height },
                scale: d.scale,
            })
            .collect()
    };
    let restoring: Vec<String> = serde_json::from_str(restoring).unwrap_or_default();
    let restoring: Vec<&str> = restoring.iter().map(String::as_str).collect();
    let dir = Path::new(dir);
    let manifest = take(dir);
    let now = CoverNow { now_ms, max_age_ms, displays: &displays, restoring: &restoring };
    let plan = cover_plan(manifest.as_ref(), dir, &now);
    if plan.reason != CoverReason::Show
        && let Some(m) = &manifest
    {
        clear_images(dir, m);
    }
    c_string(plan.to_json())
}

/// Removes every picture the plan named (the covers are all gone).
///
/// # Safety
/// `dir` and `plan_json` are null or NUL-terminated strings.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_relaunch_cover_clear(dir: *const c_char, plan_json: *const c_char) {
    let (Some(dir), Some(plan)) = (unsafe { c_str(dir) }, unsafe { c_str(plan_json) }) else {
        return;
    };
    let Ok(plan) = serde_json::from_str::<serde_json::Value>(plan) else { return };
    let dir = Path::new(dir);
    for path in
        plan["windows"].as_array().into_iter().flatten().filter_map(|w| w["image_path"].as_str())
    {
        let path = Path::new(path);
        // Only files inside the cover folder.
        if path.parent() == Some(dir) {
            let _ = std::fs::remove_file(path);
        }
    }
}

/// A launch's reveal bookkeeping for the plan `plan_json` (what `take_plan` returned), in style
/// `style` (0 instant, 1 crossfade, 2 progressive; anything else crossfade), the windows put on
/// screen at `opened_ms`. Null when the plan is not readable or does not show.
///
/// # Safety
/// `plan_json` is null or a NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_relaunch_cover_reveal_new(
    plan_json: *const c_char,
    style: u8,
    opened_ms: u64,
) -> *mut Reveal {
    let Some(json) = (unsafe { c_str(plan_json) }) else { return std::ptr::null_mut() };
    let Some(plan) = plan_from_json(json) else { return std::ptr::null_mut() };
    Box::into_raw(Box::new(Reveal::new(SwapStyle::from_u8(style), &plan, opened_ms)))
}

fn plan_from_json(json: &str) -> Option<CoverPlan> {
    use crate::relaunch_cover::{CoverSurface, PlannedWindow, Rect};
    let v: serde_json::Value = serde_json::from_str(json).ok()?;
    if v["reason"].as_str()? != "show" {
        return None;
    }
    let windows = v["windows"]
        .as_array()?
        .iter()
        .map(|w| {
            Some(PlannedWindow {
                id: w["id"].as_str()?.to_owned(),
                frame: serde_json::from_value::<Rect>(w["frame"].clone()).ok()?,
                order: u32::try_from(w["order"].as_u64()?).ok()?,
                key: w["key"].as_bool()?,
                image_path: w["image_path"].as_str()?.into(),
                surfaces: serde_json::from_value::<Vec<CoverSurface>>(w["surfaces"].clone())
                    .ok()?,
            })
        })
        .collect::<Option<Vec<_>>>()?;
    Some(CoverPlan { reason: CoverReason::Show, failed_window: None, windows })
}

/// Frees a reveal. Null does nothing.
///
/// # Safety
/// `reveal` is null or a pointer `cmux_relaunch_cover_reveal_new` returned, not yet freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_relaunch_cover_reveal_free(reveal: *mut Reveal) {
    if !reveal.is_null() {
        drop(unsafe { Box::from_raw(reveal) });
    }
}

/// The steps for windows with nothing to wait for (JSON array of `RevealStep`).
///
/// # Safety
/// `reveal` is null or a live pointer from `cmux_relaunch_cover_reveal_new`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_relaunch_cover_reveal_start(reveal: *mut Reveal) -> *mut c_char {
    let Some(r) = (unsafe { reveal.as_mut() }) else { return std::ptr::null_mut() };
    steps_json(&r.start())
}

/// A surface drew its live content; the steps it releases (JSON array).
///
/// # Safety
/// `reveal` is null or a live pointer from `cmux_relaunch_cover_reveal_new`; `window` and
/// `surface` are null or NUL-terminated strings.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_relaunch_cover_reveal_surface_ready(
    reveal: *mut Reveal,
    window: *const c_char,
    surface: *const c_char,
    now_ms: u64,
) -> *mut c_char {
    let (Some(r), Some(window), Some(surface)) =
        (unsafe { reveal.as_mut() }, unsafe { c_str(window) }, unsafe { c_str(surface) })
    else {
        return std::ptr::null_mut();
    };
    steps_json(&r.surface_ready(window, surface, now_ms))
}

/// The live window does not match its picture; the step that takes it (JSON array).
///
/// # Safety
/// As `cmux_relaunch_cover_reveal_surface_ready`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_relaunch_cover_reveal_mismatch(
    reveal: *mut Reveal,
    window: *const c_char,
) -> *mut c_char {
    let (Some(r), Some(window)) = (unsafe { reveal.as_mut() }, unsafe { c_str(window) }) else {
        return std::ptr::null_mut();
    };
    steps_json(&r.mismatch(window))
}

/// The steps due at `now_ms` (the deadline), JSON array; `next_deadline_ms` gets when to call
/// again (0 when every cover is gone).
///
/// # Safety
/// `reveal` is null or a live pointer from `cmux_relaunch_cover_reveal_new`; `next_deadline_ms`
/// is null or valid for one write.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_relaunch_cover_reveal_tick(
    reveal: *mut Reveal,
    now_ms: u64,
    next_deadline_ms: *mut u64,
) -> *mut c_char {
    let Some(r) = (unsafe { reveal.as_mut() }) else { return std::ptr::null_mut() };
    let steps = r.tick(now_ms);
    if let Some(out) = unsafe { next_deadline_ms.as_mut() } {
        *out = r.next_deadline_ms().unwrap_or(0);
    }
    steps_json(&steps)
}

#[cfg(test)]
#[path = "relaunch_cover_ffi_tests.rs"]
mod tests;

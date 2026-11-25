//! `list_displays` on macOS: the active CoreGraphics displays. Ids are
//! CGDirectDisplayIDs in decimal, the ids `capture::display` and the worker's
//! ScreenCaptureKit capture (SCDisplay.displayID) take. Geometry only: none of
//! these calls needs a grant or shows a prompt.

use super::sys::{CGDisplayBounds, CGMainDisplayID, CGRect};
use crate::desktop::{DResult, DesktopError, Rect};
use crate::displays::Display;

type CGDisplayModeRef = *mut std::ffi::c_void;

#[link(name = "CoreGraphics", kind = "framework")]
unsafe extern "C" {
    fn CGGetActiveDisplayList(max: u32, displays: *mut u32, count: *mut u32) -> i32;
    fn CGDisplayIsBuiltin(display: u32) -> u32;
    fn CGDisplayCopyDisplayMode(display: u32) -> CGDisplayModeRef;
    fn CGDisplayModeGetWidth(mode: CGDisplayModeRef) -> usize;
    fn CGDisplayModeGetPixelWidth(mode: CGDisplayModeRef) -> usize;
    fn CGDisplayModeRelease(mode: CGDisplayModeRef);
}

/// More displays than any Mac drives.
const MAX_DISPLAYS: usize = 32;

pub fn list() -> DResult<Vec<Display>> {
    let mut ids = [0u32; MAX_DISPLAYS];
    let mut count = 0u32;
    // SAFETY: `ids` holds MAX_DISPLAYS entries and CG writes at most that many.
    let err = unsafe { CGGetActiveDisplayList(MAX_DISPLAYS as u32, ids.as_mut_ptr(), &mut count) };
    if err != 0 {
        return Err(DesktopError::Failed(format!("CGGetActiveDisplayList failed ({err})")));
    }
    // SAFETY: no arguments.
    let main = unsafe { CGMainDisplayID() };
    Ok(ids[..(count as usize).min(MAX_DISPLAYS)]
        .iter()
        .map(|&id| {
            // SAFETY: plain value call.
            let b: CGRect = unsafe { CGDisplayBounds(id) };
            Display {
                id: id.to_string(),
                frame: Rect {
                    x: b.origin.x,
                    y: b.origin.y,
                    width: b.size.width,
                    height: b.size.height,
                },
                scale: scale(id, b.size.width),
                main: id == main,
                // SAFETY: plain value call.
                builtin: Some(unsafe { CGDisplayIsBuiltin(id) } != 0),
                // macOS has no public call that says a display is virtual.
                is_virtual: None,
            }
        })
        .collect())
}

/// Pixels per point of the display's current mode (2 on Retina).
fn scale(id: u32, points_wide: f64) -> f64 {
    // SAFETY: the mode is +1 or null; released below.
    let mode = unsafe { CGDisplayCopyDisplayMode(id) };
    if mode.is_null() {
        return 1.0;
    }
    // SAFETY: mode is a live CGDisplayMode.
    let (pixels, points) =
        unsafe { (CGDisplayModeGetPixelWidth(mode), CGDisplayModeGetWidth(mode)) };
    // SAFETY: balances the copy above.
    unsafe { CGDisplayModeRelease(mode) };
    let points = if points > 0 { points as f64 } else { points_wide };
    if pixels == 0 || points <= 0.0 { 1.0 } else { pixels as f64 / points }
}

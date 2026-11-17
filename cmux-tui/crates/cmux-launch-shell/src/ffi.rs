//! The C ABI the app's stage-0 window calls (include/cmux_launch_shell.h): one plan read before
//! the window is made, one disposition per input event while it is up.
use std::ffi::{CStr, c_char};
use std::path::Path;

use crate::{
    Appearance, Display, Frame, InputKind, Now, Reason, input_disposition, plan, saved_windows,
};

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct CmuxLaunchShellDisplay {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
    pub scale: f64,
}

#[repr(C)]
pub struct CmuxLaunchShellNow {
    /// NUL-terminated UTF-8: the running app's build.
    pub build: *const c_char,
    /// 0 light, 1 dark: the system's appearance now.
    pub appearance: u8,
    pub displays: *const CmuxLaunchShellDisplay,
    pub display_count: usize,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct CmuxLaunchShellPlan {
    pub frame_x: f64,
    pub frame_y: f64,
    pub frame_width: f64,
    pub frame_height: f64,
    pub background_rgba: [u8; 4],
    pub bar_rgba: [u8; 4],
    pub appearance: u8,
    /// `Reason` (0 image, 1 no record, 2 no windows, 3 build, 4 layout, 5 scale, 6 appearance,
    /// 7 image unreadable, 8 image size, 9 full screen, 10 old record).
    pub reason: u8,
    pub shows_window: bool,
    /// No saved frame: the app's default frame.
    pub uses_default_frame: bool,
    pub window_id: [c_char; 65],
    /// Empty unless `reason` is 0.
    pub image_path: [c_char; 1025],
}

impl Default for CmuxLaunchShellPlan {
    fn default() -> Self {
        Self {
            frame_x: 0.0,
            frame_y: 0.0,
            frame_width: 0.0,
            frame_height: 0.0,
            background_rgba: [0; 4],
            bar_rgba: [0; 4],
            appearance: 0,
            reason: Reason::NoRecord as u8,
            shows_window: false,
            uses_default_frame: false,
            window_id: [0; 65],
            image_path: [0; 1025],
        }
    }
}

unsafe fn c_str<'a>(p: *const c_char) -> Option<&'a str> {
    if p.is_null() { None } else { unsafe { CStr::from_ptr(p) }.to_str().ok() }
}

fn copy_c(dst: &mut [c_char], s: &str) -> bool {
    if s.len() >= dst.len() || s.contains('\0') {
        return false;
    }
    for (d, b) in dst.iter_mut().zip(s.bytes()) {
        *d = b as c_char;
    }
    dst[s.len()] = 0;
    true
}

/// Fills `out` with stage 0's plan from the launch record at `record_path` and the image store
/// at `image_dir`. False only for a null `out` or `now`, or a non-UTF-8 argument; a missing or
/// unreadable record is a plan (`reason` 1), not a failure. A plan whose id or path does not fit
/// its field comes back without the image (`reason` 7).
///
/// # Safety
/// `record_path`, `image_dir` and `now.build` are null or NUL-terminated strings; `now.displays`
/// is valid for reads of `now.display_count` displays (or null with a count of 0); `out` is null
/// or valid for writes of one `CmuxLaunchShellPlan`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_launch_shell_plan(
    record_path: *const c_char,
    image_dir: *const c_char,
    now: *const CmuxLaunchShellNow,
    out: *mut CmuxLaunchShellPlan,
) -> bool {
    if out.is_null() || now.is_null() {
        return false;
    }
    let o = unsafe { &mut *out };
    *o = CmuxLaunchShellPlan::default();
    let now = unsafe { &*now };
    let (Some(build), Some(record_path), Some(image_dir)) =
        (unsafe { c_str(now.build) }, unsafe { c_str(record_path) }, unsafe { c_str(image_dir) })
    else {
        return false;
    };
    let displays: Vec<Display> = if now.displays.is_null() || now.display_count == 0 {
        Vec::new()
    } else {
        unsafe { std::slice::from_raw_parts(now.displays, now.display_count) }
            .iter()
            .map(|d| Display {
                frame: Frame { x: d.x, y: d.y, width: d.width, height: d.height },
                scale: d.scale,
            })
            .collect()
    };
    let now = Now { build, appearance: Appearance::from_u8(now.appearance), displays: &displays };
    let windows = cmux_launch_record::LaunchRecord::read(record_path).map(|r| saved_windows(&r));
    let plan = plan(windows.as_deref(), Path::new(image_dir), &now);
    let mut reason = plan.reason;
    if let Some(w) = &plan.window {
        if !copy_c(&mut o.window_id, &w.id) {
            *o = CmuxLaunchShellPlan { reason: Reason::NoWindows as u8, ..Default::default() };
            return true;
        }
        (o.frame_x, o.frame_y, o.frame_width, o.frame_height) =
            (w.frame.x, w.frame.y, w.frame.width, w.frame.height);
        (o.background_rgba, o.bar_rgba, o.appearance) =
            (w.background_rgba, w.bar_rgba, w.appearance as u8);
    }
    if let Some(path) = &plan.image
        && !path.to_str().is_some_and(|p| copy_c(&mut o.image_path, p))
    {
        o.image_path[0] = 0;
        reason = Reason::ImageUnreadable;
    }
    o.reason = reason as u8;
    o.shows_window = reason.shows_window();
    o.uses_default_frame = reason.uses_default_frame();
    true
}

/// What the stage-0 window does with an event of `kind` (`InputKind`) when `held` events are held:
/// 0 pass to AppKit, 1 hold, 2 hold and swap now.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_launch_shell_input_disposition(kind: u8, held: usize) -> u8 {
    input_disposition(InputKind::from_u8(kind), held) as u8
}

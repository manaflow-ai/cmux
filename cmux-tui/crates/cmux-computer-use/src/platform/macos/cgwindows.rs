//! Top-level windows from the window server (`CGWindowListCopyWindowInfo`).

use super::sys::*;
use crate::desktop::Rect;

const LIST_ON_SCREEN_ONLY: u32 = 1 << 0;
const LIST_INCLUDING_WINDOW: u32 = 1 << 3;
const LIST_EXCLUDE_DESKTOP: u32 = 1 << 4;

/// One window server entry.
#[derive(Clone, Debug)]
pub struct CgWindow {
    pub id: u32,
    pub pid: i32,
    pub layer: i64,
    pub frame: Rect,
    pub title: String,
    pub on_screen: bool,
    pub alpha: f64,
}

impl CgWindow {
    /// A normal app window an agent can use: layer 0, visible size, not
    /// fully transparent.
    pub fn is_app_window(&self) -> bool {
        self.layer == 0 && self.frame.width >= 2.0 && self.frame.height >= 2.0 && self.alpha > 0.0
    }
}

fn parse(d: &Cf) -> Option<CgWindow> {
    let num = |k: &str| d.get(k).and_then(|v| v.as_f64());
    let id = d.get("kCGWindowNumber")?.as_i64()? as u32;
    let pid = d.get("kCGWindowOwnerPID")?.as_i64()? as i32;
    let bounds = d.get("kCGWindowBounds")?;
    let b = |k: &str| bounds.get(k).and_then(|v| v.as_f64()).unwrap_or(0.0);
    Some(CgWindow {
        id,
        pid,
        layer: d.get("kCGWindowLayer").and_then(|v| v.as_i64()).unwrap_or(0),
        frame: Rect { x: b("X"), y: b("Y"), width: b("Width"), height: b("Height") },
        title: d.get("kCGWindowName").and_then(|v| v.as_string()).unwrap_or_default(),
        on_screen: num("kCGWindowIsOnscreen").is_some_and(|v| v != 0.0),
        alpha: num("kCGWindowAlpha").unwrap_or(1.0),
    })
}

fn list(option: u32, relative_to: u32) -> Vec<CgWindow> {
    // SAFETY: returns a +1 CFArray of CFDictionaries (or null).
    let Some(array) = Cf::created(unsafe { CGWindowListCopyWindowInfo(option, relative_to) })
    else {
        return Vec::new();
    };
    array.items().iter().filter_map(parse).collect()
}

/// On-screen windows, front to back.
pub fn on_screen() -> Vec<CgWindow> {
    list(LIST_ON_SCREEN_ONLY | LIST_EXCLUDE_DESKTOP, 0)
}

/// Every window the window server knows (on-screen first, front to back,
/// then the rest).
pub fn all() -> Vec<CgWindow> {
    // kCGWindowListOptionAll is 0: no on-screen filter.
    list(LIST_EXCLUDE_DESKTOP, 0)
}

/// One window by id.
pub fn by_id(id: u32) -> Option<CgWindow> {
    list(LIST_INCLUDING_WINDOW, id).into_iter().find(|w| w.id == id)
}

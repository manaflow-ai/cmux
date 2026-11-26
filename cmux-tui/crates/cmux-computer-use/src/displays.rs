//! `list_displays`: the displays a `screenshot` can name, so a script picks one
//! by id instead of guessing (docs/computer-use/README.md).
//!
//! An id is the exact string `screenshot`'s `display` argument takes: the
//! decimal CGDirectDisplayID on macOS, the RandR monitor name (or `root`) on
//! X11, the output name on wlroots. Geometry only, no pixels, so the tool is a
//! Discover call: no grant and no prompt, and it answers while the screen is
//! locked.

use serde::{Deserialize, Serialize};
use serde_json::json;

use crate::desktop::{DResult, Desktop, Rect};

/// One display, in the desktop's global coordinates (points on macOS).
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Display {
    pub id: String,
    pub frame: Rect,
    /// Pixels per point.
    pub scale: f64,
    pub main: bool,
    /// The OS says the display is built in (a laptop panel). Absent when the
    /// OS does not say.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub builtin: Option<bool>,
    /// The OS says the display is virtual (Xvfb, a headless or VNC screen).
    /// Absent when the OS does not say.
    #[serde(rename = "virtual", default, skip_serializing_if = "Option::is_none")]
    pub is_virtual: Option<bool>,
}

/// The tool body: `{"displays":[...]}` with the main display first.
pub fn list(desktop: &dyn Desktop) -> DResult<serde_json::Value> {
    let mut displays = desktop.displays()?;
    // Stable order: main first, then by origin.
    displays.sort_by(|a, b| {
        b.main
            .cmp(&a.main)
            .then(a.frame.x.total_cmp(&b.frame.x))
            .then(a.frame.y.total_cmp(&b.frame.y))
    });
    Ok(json!({ "displays": displays }))
}

#[cfg(test)]
#[path = "displays_tests.rs"]
mod tests;

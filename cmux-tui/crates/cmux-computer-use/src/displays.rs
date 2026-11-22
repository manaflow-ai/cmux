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
mod tests {
    use super::*;
    use crate::desktop::CaptureTarget;
    use crate::desktop::fake::FakeDesktop;

    #[test]
    fn the_fake_desktop_lists_the_display_it_captures() {
        let desktop = FakeDesktop::standard();
        let body = list(&desktop).unwrap();
        let displays = body["displays"].as_array().unwrap();
        assert_eq!(displays.len(), 1);
        let d = &displays[0];
        assert_eq!(d["main"], true);
        assert_eq!(d["virtual"], true);
        let id = d["id"].as_str().unwrap().to_string();
        // The id round-trips into a capture of the same size.
        let frame = desktop.capture(&CaptureTarget::Display(Some(id))).unwrap();
        let scale = d["scale"].as_f64().unwrap();
        assert_eq!(scale, frame.scale);
        assert_eq!(d["frame"]["width"].as_f64().unwrap() * scale, f64::from(frame.width));
        assert_eq!(d["frame"]["height"].as_f64().unwrap() * scale, f64::from(frame.height));
    }

    #[test]
    fn main_sorts_first_and_unknown_fields_are_left_out() {
        let a = Display {
            id: "b".into(),
            frame: Rect { x: -1920.0, y: 0.0, width: 1920.0, height: 1080.0 },
            scale: 1.0,
            main: false,
            builtin: None,
            is_virtual: None,
        };
        let v = serde_json::to_value(&a).unwrap();
        assert!(v.get("builtin").is_none() && v.get("virtual").is_none());
        let mut list = [a.clone(), Display { id: "m".into(), main: true, ..a }];
        list.sort_by_key(|d| std::cmp::Reverse(d.main));
        assert_eq!(list[0].id, "m");
    }
}

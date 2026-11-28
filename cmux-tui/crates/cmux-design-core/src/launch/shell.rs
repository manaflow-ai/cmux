//! `LaunchShell`'s pure parts (LaunchShell.swift): the image key's build part, the held input's
//! kind, stage 0's frame and its colors. The window, images and replay stay in Swift.

use serde::{Deserialize, Serialize};

/// `LaunchShell.backstop` (seconds).
pub const BACKSTOP_SECONDS: f64 = 5.;
/// `LaunchShell.bareBound` (ms).
pub const BARE_BOUND_MS: f64 = 1_500.;
/// `LaunchShellPaths.record(in:)`'s file name.
pub const RECORD_FILE: &str = "launch-record.bin";
/// `LaunchShellPaths.images(in:)`'s directory name.
pub const IMAGES_DIR: &str = "launch-images";

/// `LaunchShellPaths.build(info:)`: `CFBundleVersion+CMUXCommit`, only ASCII letters, digits and
/// `.+_-`, at most 128; `unknown` when nothing is left.
pub fn build_key(version: Option<&str>, commit: Option<&str>) -> String {
    let raw = [version, commit].into_iter().flatten().collect::<Vec<_>>().join("+");
    let kept: String = raw
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || ".+_-".contains(*c))
        .take(128)
        .collect();
    if kept.is_empty() { "unknown".into() } else { kept }
}

/// `LaunchShellReplay.kind(_:)`: the Rust `InputKind` of an `NSEvent.EventType` raw value.
pub fn replay_kind(event_type: u64) -> u8 {
    match event_type {
        10 => 1,         // keyDown
        11 => 2,         // keyUp
        12 => 3,         // flagsChanged
        1 | 3 | 25 => 4, // left, right, other mouseDown
        2 | 4 | 26 => 5, // mouseUp
        6 | 7 | 27 => 6, // mouseDragged
        22 => 7,         // scrollWheel
        5 | 8 | 9 => 8,  // mouseMoved, mouseEntered, mouseExited
        _ => 0,
    }
}

/// A rect: x, y, width, height.
pub type Rect = [f64; 4];

/// `CGRect.integral`.
pub fn integral(r: Rect) -> Rect {
    let (x0, y0) = (r[0].floor(), r[1].floor());
    [x0, y0, (r[0] + r[2]).ceil() - x0, (r[1] + r[3]).ceil() - y0]
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct FrameRequest {
    pub uses_default_frame: bool,
    pub plan_frame: Rect,
    pub cached_frame: Option<Rect>,
    /// `NSScreen.main?.visibleFrame`.
    pub visible: Option<Rect>,
}

/// `Prepared.init`'s frame: the plan's, or the cached front window's, or 1100 x 720 centered.
pub fn frame(r: &FrameRequest) -> Rect {
    if !r.uses_default_frame {
        return r.plan_frame;
    }
    if let Some(cached) = r.cached_frame {
        return cached;
    }
    let v = r.visible.unwrap_or([0., 0., 1440., 900.]);
    let (mid_x, mid_y) = (v[0] + v[2] / 2., v[1] + v[3] / 2.);
    integral([mid_x - 550., mid_y - 360., 1100., 720.])
}

/// `Prepared.init`'s color: sRGB components in 0...1, an alpha of 0 is opaque.
pub fn color(rgba: [u8; 4]) -> [f64; 4] {
    let c = |v: u8| f64::from(v) / 255.;
    [c(rgba[0]), c(rgba[1]), c(rgba[2]), if rgba[3] == 0 { 1. } else { c(rgba[3]) }]
}

/// `Prepared.imagePath`: drawn only when the plan's reason is 0 and a path is set.
pub fn image_path(reason: u8, path: &str) -> Option<String> {
    (reason == 0 && !path.is_empty()).then(|| path.to_string())
}

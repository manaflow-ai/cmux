//! Live (extension-style) wallpapers' app-side rules (Swift `LiveWallpaper`,
//! `LiveWallpaperFrame.still`, `BackdropLiveView.HoldReason`): a checked manifest's defaults, the
//! source digest that tells two builds apart, the still frame a poster draws, and the scheduler's
//! hold reason names.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// The wallpaper FFI's ABI this app speaks.
pub const ABI_VERSION: u32 = 4;

const HOLD_REASONS: [&str; 13] = [
    "",
    "occluded",
    "covered",
    "minimized",
    "app-hidden",
    "screens-asleep",
    "session-inactive",
    "low-power",
    "thermal",
    "reduce-motion",
    "animations-off",
    "too-heavy",
    "idle",
];

/// A scheduler hold reason's name; the number itself for one this app doesn't know.
pub fn hold_reason_name(reason: u8) -> String {
    HOLD_REASONS.get(usize::from(reason)).map_or_else(|| reason.to_string(), |n| n.to_string())
}

/// FNV-1a over a wallpaper's source; 0 for none.
pub fn digest(source: Option<&[u8]>) -> u64 {
    let Some(bytes) = source else { return 0 };
    bytes.iter().fold(0xcbf2_9ce4_8422_2325_u64, |hash, &b| {
        (hash ^ u64::from(b)).wrapping_mul(0x0000_0100_0000_01b3)
    })
}

/// A live wallpaper as the app keeps it, from its checked manifest.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Manifest {
    pub id: String,
    pub name: String,
    pub summary: String,
    pub fps: u32,
    pub scale: f32,
    pub interactive: bool,
    pub idle_after: f64,
    pub params: Vec<f32>,
    pub still_time: f32,
    pub still_pointer: [f32; 2],
}

/// The checked manifest (JSON) read with the app's defaults; nil without a non-empty id.
pub fn manifest(object: &Value) -> Option<Manifest> {
    let id = object.get("id")?.as_str().filter(|id| !id.is_empty())?.to_string();
    let number = |key: &str| object.get(key).and_then(Value::as_f64);
    let still = object.get("still");
    let pointer: Vec<f32> = still
        .and_then(|s| s.get("pointer"))
        .and_then(Value::as_array)
        .map(|p| p.iter().filter_map(Value::as_f64).map(|v| v as f32).collect())
        .unwrap_or_default();
    let params = object
        .get("params")
        .and_then(Value::as_array)
        .map(|params| {
            params
                .iter()
                .take(8)
                .map(|p| p.get("default").and_then(Value::as_f64).unwrap_or(0.0) as f32)
                .collect()
        })
        .unwrap_or_default();
    Some(Manifest {
        name: object.get("name").and_then(Value::as_str).unwrap_or(&id).to_string(),
        summary: object.get("description").and_then(Value::as_str).unwrap_or_default().to_string(),
        fps: number("fps").map_or(30, |v| v as u32),
        scale: number("scale").map_or(1.0, |v| v as f32),
        interactive: object.get("interactive").and_then(Value::as_bool).unwrap_or(true),
        idle_after: number("idle_after").unwrap_or(20.0),
        params,
        still_time: still.and_then(|s| s.get("time")).and_then(Value::as_f64).unwrap_or(0.0) as f32,
        still_pointer: [
            pointer.first().copied().unwrap_or(0.5),
            pointer.get(1).copied().unwrap_or(0.5),
        ],
        id,
    })
}

/// The frame inputs a still (a poster) draws with; the colors are added by the app.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StillFrame {
    pub time: f32,
    pub width: f32,
    pub height: f32,
    pub pixels_per_point: f32,
    pub seed: f32,
    pub pointer: [f32; 2],
    pub presence: f32,
    pub since_moved: f32,
    pub still: bool,
    pub params: Vec<f32>,
}

/// `LiveWallpaperFrame.still`: the manifest's still moment at `width` by `height` pixels.
pub fn still(manifest: &Manifest, width: u32, height: u32) -> StillFrame {
    let (w, h) = (width as f32, height as f32);
    StillFrame {
        time: manifest.still_time,
        width: w,
        height: h,
        pixels_per_point: 1.0,
        seed: 0.5,
        pointer: [manifest.still_pointer[0] * w, manifest.still_pointer[1] * h],
        presence: 1.0,
        since_moved: 10.0,
        still: true,
        params: manifest.params.clone(),
    }
}

/// `stillKey`: the poster cache key, `id|digest hex|colors key`.
pub fn still_key(id: &str, digest: u64, colors_key: &str) -> String {
    format!("{id}|{digest:x}|{colors_key}")
}

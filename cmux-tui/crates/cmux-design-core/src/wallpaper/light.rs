//! The wallpaper light's pure parts (Swift `WallpaperLightField`): a window's rect in its
//! container's top-left space, and the CSS variables a page's style becomes.

use super::placement::Rect;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// How long a moved window waits before its light is restyled.
pub const SETTLE_SECONDS: f64 = 0.15;

/// A rect measured in its container: top-left origin, and the container's diagonal.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Geometry {
    pub rect: Rect,
    pub diagonal: f64,
}

/// `rect` (bottom-left screen points) in `container`; nil for a container without area.
pub fn geometry(rect: Rect, container: Rect) -> Option<Geometry> {
    if !(container.width > 0.0 && container.height > 0.0) {
        return None;
    }
    Some(Geometry {
        rect: Rect {
            x: rect.x - container.x,
            y: container.max_y() - rect.max_y(),
            width: rect.width,
            height: rect.height,
        },
        diagonal: (container.width * container.width + container.height * container.height).sqrt(),
    })
}

/// An sRGB color, 0 to 1.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Rgb {
    pub red: f64,
    pub green: f64,
    pub blue: f64,
}

/// A page's light: the field's colors and the style computed for the window.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PageLight {
    pub rim: Rgb,
    pub bloom: Rgb,
    pub tint: Rgb,
    pub dx: f64,
    pub dy: f64,
    pub rim_alpha: f64,
    pub bloom_alpha: f64,
    pub tint_share: f64,
}

/// The page's CSS variables (`--wl-*`): numbers to 3 places, colors as `color(srgb r g b)`.
pub fn css(light: &PageLight) -> BTreeMap<String, String> {
    let number = |v: f64| format!("{v:.3}");
    let color = |c: Rgb| {
        format!(
            "color(srgb {} {} {})",
            number(c.red.clamp(0.0, 1.0)),
            number(c.green.clamp(0.0, 1.0)),
            number(c.blue.clamp(0.0, 1.0))
        )
    };
    [
        ("--wl-dx", number(light.dx)),
        ("--wl-dy", number(light.dy)),
        ("--wl-rim", color(light.rim)),
        ("--wl-rim-alpha", number(light.rim_alpha)),
        ("--wl-bloom", color(light.bloom)),
        ("--wl-bloom-alpha", number(light.bloom_alpha)),
        ("--wl-tint", color(light.tint)),
        ("--wl-tint-share", number(light.tint_share)),
    ]
    .into_iter()
    .map(|(k, v)| (k.to_string(), v))
    .collect()
}

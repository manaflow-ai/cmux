//! `SurfaceBackgrounds.compensatedFill`: a surface color drawn over the window's tint so the
//! result reads as the color at its own opacity.

use super::run;
use crate::ops::OpResult;
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// `ThemeRGB`: channels and alpha in 0...1.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Rgb {
    pub red: f64,
    pub green: f64,
    pub blue: f64,
    #[serde(default = "one")]
    pub alpha: f64,
}

fn one() -> f64 {
    1.0
}

impl Rgb {
    pub const fn new(red: f64, green: f64, blue: f64, alpha: f64) -> Self {
        Self { red, green, blue, alpha }
    }
    fn with_alpha(self, alpha: f64) -> Self {
        Self { alpha, ..self }
    }
}

/// `compensatedFill(_:opacity:sheet:windowTint:)`: the fill `F` at alpha `x` over the tint
/// `windowTint * sheet` that composes to `opacity * ground`; the alpha rises to the least that
/// keeps every channel in gamut. At or under the window's tint (or an opaque window): `ground` at `opacity`.
pub fn compensated_fill(ground: Rgb, opacity: f64, sheet: Rgb, window_tint: f64) -> Rgb {
    if !(window_tint < 1.0 && opacity > window_tint) {
        return ground.with_alpha(opacity);
    }
    let pairs = [(ground.red, sheet.red), (ground.green, sheet.green), (ground.blue, sheet.blue)];
    let mut x = (opacity - window_tint) / (1.0 - window_tint);
    for (g, s) in pairs {
        let under = window_tint * s;
        if under > 0.0 {
            x = x.max(1.0 - opacity * g / under);
        }
        if under < 1.0 {
            x = x.max((opacity * g - under) / (1.0 - under));
        }
    }
    x = x.min(1.0);
    let channel =
        |(g, s): (f64, f64)| ((opacity * g - (1.0 - x) * window_tint * s) / x).clamp(0.0, 1.0);
    Rgb::new(channel(pairs[0]), channel(pairs[1]), channel(pairs[2]), x)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FillRequest {
    ground: Rgb,
    opacity: f64,
    sheet: Rgb,
    window_tint: f64,
}

/// `window.compensatedFill` `{ground, opacity, sheet, windowTint}` → [`Rgb`].
pub(super) fn op_compensated_fill(request: &Value) -> OpResult {
    run(request, |r: FillRequest| compensated_fill(r.ground, r.opacity, r.sheet, r.window_tint))
}

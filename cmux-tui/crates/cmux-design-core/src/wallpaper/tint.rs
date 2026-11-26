//! The desktop picture's color the window's theme tint leans toward (Swift `WallpaperTint`,
//! `appearance.wallpaperTint`): only the hue comes from the picture; the theme's brightness and
//! alpha stay, and a strongly colored theme keeps its color. The app decodes the picture into a
//! small premultiplied RGBA buffer; [`mean`] and [`bands`] read it.

use serde::{Deserialize, Serialize};

/// How far a neutral theme tint moves toward the picture's hue.
pub const STRENGTH: f64 = 0.5;
/// The most saturation the picture brings.
pub const SATURATION_CAP: f64 = 0.5;
/// A theme tint this saturated (HSB) or more keeps its color.
pub const THEME_SATURATION_LIMIT: f64 = 0.6;

/// An sRGB color, 0...1, with alpha.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Rgba {
    pub red: f64,
    pub green: f64,
    pub blue: f64,
    #[serde(default = "one")]
    pub alpha: f64,
}

fn one() -> f64 {
    1.0
}

/// The picture's mean color, clamped to 0...1.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Tint {
    pub red: f64,
    pub green: f64,
    pub blue: f64,
}

impl Tint {
    pub fn new(red: f64, green: f64, blue: f64) -> Self {
        let unit = |v: f64| v.clamp(0.0, 1.0);
        Self { red: unit(red), green: unit(green), blue: unit(blue) }
    }

    /// `theme` leaned toward this color: the picture's hue, at most [`SATURATION_CAP`] of its
    /// saturation, at `theme`'s brightness, mixed in by [`STRENGTH`] scaled down as `theme` is
    /// more saturated. Alpha is kept.
    pub fn blended(&self, theme: Rgba) -> Rgba {
        let (_, theme_saturation, theme_brightness) = hsb(theme.red, theme.green, theme.blue);
        let amount = STRENGTH * (1.0 - theme_saturation / THEME_SATURATION_LIMIT).max(0.0);
        if amount <= 0.0 {
            return theme;
        }
        let (hue, saturation, _) = hsb(self.red, self.green, self.blue);
        let (r, g, b) = rgb(hue, saturation.min(SATURATION_CAP), theme_brightness);
        let mix = |from: f64, to: f64| from + (to - from) * amount;
        Rgba {
            red: mix(theme.red, r),
            green: mix(theme.green, g),
            blue: mix(theme.blue, b),
            alpha: theme.alpha,
        }
    }
}

/// AppKit's `getHue(_:saturation:brightness:alpha:)`: hue 0..<1.
pub fn hsb(r: f64, g: f64, b: f64) -> (f64, f64, f64) {
    let max = r.max(g).max(b);
    let min = r.min(g).min(b);
    let delta = max - min;
    let saturation = if max > 0.0 { delta / max } else { 0.0 };
    if delta <= 0.0 {
        return (0.0, saturation, max);
    }
    let sector = if max == r {
        (g - b) / delta
    } else if max == g {
        2.0 + (b - r) / delta
    } else {
        4.0 + (r - g) / delta
    };
    let hue = (sector / 6.0).rem_euclid(1.0);
    (hue, saturation, max)
}

/// `NSColor(hue:saturation:brightness:)` in sRGB.
pub fn rgb(hue: f64, saturation: f64, brightness: f64) -> (f64, f64, f64) {
    if saturation <= 0.0 {
        return (brightness, brightness, brightness);
    }
    let h = hue.rem_euclid(1.0) * 6.0;
    let sector = h.floor();
    let f = h - sector;
    let p = brightness * (1.0 - saturation);
    let q = brightness * (1.0 - saturation * f);
    let t = brightness * (1.0 - saturation * (1.0 - f));
    match sector as i64 {
        0 => (brightness, t, p),
        1 => (q, brightness, p),
        2 => (p, brightness, t),
        3 => (p, q, brightness),
        4 => (t, p, brightness),
        _ => (brightness, p, q),
    }
}

/// What the window shows behind its glass, for [`tint`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Shown {
    /// No art: the desktop shows through.
    None,
    /// The Desktop Wallpaper background (the desktop itself).
    Desktop,
    /// Other art.
    Art,
}

/// The tint a window shows: `theme` leaned toward `wallpaper` when the setting is on, the window
/// is not opaque and shows the desktop; otherwise `theme`.
pub fn tint(
    theme: Rgba,
    wallpaper: Option<Tint>,
    enabled: bool,
    opaque: bool,
    shown: Shown,
) -> Rgba {
    match wallpaper {
        Some(w) if enabled && !opaque && shown != Shown::Art => w.blended(theme),
        _ => theme,
    }
}

fn mean_of(pixels: &[u8]) -> Option<Tint> {
    let mut sums = [0.0_f64; 4];
    for pixel in pixels.chunks_exact(4) {
        for (sum, byte) in sums.iter_mut().zip(pixel) {
            *sum += f64::from(*byte);
        }
    }
    // Premultiplied: dividing by the summed alpha gives the mean of the opaque color.
    (sums[3] > 0.0).then(|| Tint::new(sums[0] / sums[3], sums[1] / sums[3], sums[2] / sums[3]))
}

/// The mean color of a premultiplied RGBA buffer (Swift `average(of:)` reads a 16 by 16 copy);
/// nil with no alpha.
pub fn mean(pixels: &[u8]) -> Option<Tint> {
    mean_of(pixels)
}

/// The mean color of each row of a premultiplied RGBA buffer `width` pixels wide, top first
/// (Swift `bands(of:count:)` draws a 16-wide, `count`-tall copy); rows with no alpha are dropped.
pub fn bands(pixels: &[u8], width: usize) -> Vec<Tint> {
    if width == 0 {
        return Vec::new();
    }
    pixels.chunks_exact(width * 4).filter_map(mean_of).collect()
}

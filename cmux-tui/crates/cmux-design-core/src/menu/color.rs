//! The colour math the menu rules need: CmuxTheme `ThemeRGB` (clamped 0...1 components, WCAG
//! contrast, linear mix, compositing) and WebTheme's `css(_:)`.
//!
//! The same math lives in cmux-theme-tokens `Rgb`; this crate takes no dependency on it, so the
//! few lines are here, value for value with the Swift.

use serde::{Deserialize, Serialize};

/// CmuxTheme `ThemeRGB`: 0...1 components, clamped on the way in.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", from = "RawRgb")]
pub struct ThemeRgb {
    pub red: f64,
    pub green: f64,
    pub blue: f64,
    pub alpha: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawRgb {
    red: f64,
    green: f64,
    blue: f64,
    #[serde(default = "one")]
    alpha: f64,
}

fn one() -> f64 {
    1.0
}

impl From<RawRgb> for ThemeRgb {
    fn from(raw: RawRgb) -> Self {
        ThemeRgb::new(raw.red, raw.green, raw.blue, raw.alpha)
    }
}

fn clamp(value: f64) -> f64 {
    value.clamp(0.0, 1.0)
}

impl ThemeRgb {
    /// `ThemeRGB(red:green:blue:alpha:)`: components clamped to 0...1.
    pub fn new(red: f64, green: f64, blue: f64, alpha: f64) -> Self {
        ThemeRgb { red: clamp(red), green: clamp(green), blue: clamp(blue), alpha: clamp(alpha) }
    }

    /// `ThemeRGB(hex:alpha:)`.
    pub fn hex(hex: u32, alpha: f64) -> Self {
        let channel = |shift: u32| f64::from((hex >> shift) & 0xFF) / 255.0;
        ThemeRgb::new(channel(16), channel(8), channel(0), alpha)
    }

    /// Opaque white.
    pub const WHITE: ThemeRgb = ThemeRgb { red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0 };
    /// Opaque black.
    pub const BLACK: ThemeRgb = ThemeRgb { red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0 };

    /// WCAG 2 relative luminance of the opaque colour.
    pub fn relative_luminance(self) -> f64 {
        fn linear(c: f64) -> f64 {
            if c <= 0.04045 { c / 12.92 } else { ((c + 0.055) / 1.055).powf(2.4) }
        }
        0.2126 * linear(self.red) + 0.7152 * linear(self.green) + 0.0722 * linear(self.blue)
    }

    /// WCAG 2 contrast ratio between two opaque colours (1...21).
    pub fn contrast(self, other: ThemeRgb) -> f64 {
        let (a, b) = (self.relative_luminance(), other.relative_luminance());
        (a.max(b) + 0.05) / (a.min(b) + 0.05)
    }

    /// Linear sRGB mix toward `other` by `fraction` (clamped); alpha is kept.
    pub fn mixed(self, other: ThemeRgb, fraction: f64) -> ThemeRgb {
        let t = clamp(fraction);
        ThemeRgb::new(
            self.red + (other.red - self.red) * t,
            self.green + (other.green - self.green) * t,
            self.blue + (other.blue - self.blue) * t,
            self.alpha,
        )
    }

    /// This colour at opacity `alpha`.
    pub fn with_alpha(self, alpha: f64) -> ThemeRgb {
        ThemeRgb::new(self.red, self.green, self.blue, alpha)
    }

    /// The opaque colour seen when this one is painted over `base`.
    pub fn composited(self, base: ThemeRgb) -> ThemeRgb {
        base.mixed(self.with_alpha(1.0), self.alpha).with_alpha(1.0)
    }
}

/// Swift's `Double.description` for the values the menu writes: a whole number keeps its `.0`.
pub fn swift_double(value: f64) -> String {
    if value.is_finite() && value == value.trunc() && value.abs() < 1e16 {
        format!("{value:.1}")
    } else {
        format!("{value}")
    }
}

/// WebTheme `cssAlpha`: the 8-bit alpha the native layer draws, written to 3 decimals.
pub fn css_alpha(alpha: f64) -> f64 {
    ((alpha * 255.0).round() / 255.0 * 1000.0).round() / 1000.0
}

/// WebTheme `css(_:)`: `rgba(r, g, b, a)` with 0-255 channels.
pub fn css(color: ThemeRgb) -> String {
    let channel = |value: f64| (value * 255.0).round() as i64;
    format!(
        "rgba({}, {}, {}, {})",
        channel(color.red),
        channel(color.green),
        channel(color.blue),
        swift_double(css_alpha(color.alpha))
    )
}

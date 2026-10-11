//! `Rgb`: an sRGB color as plain values (port of cmux-next `ThemeRGB`).

/// An sRGB color, components 0...1 (clamped). `#[repr(C)]` so a C caller can
/// read token structs directly.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Default)]
pub struct Rgb {
    pub r: f64,
    pub g: f64,
    pub b: f64,
    /// Opacity, 0...1.
    pub a: f64,
}

fn clamp(v: f64) -> f64 {
    v.clamp(0.0, 1.0)
}

impl Rgb {
    pub const BLACK: Rgb = Rgb { r: 0.0, g: 0.0, b: 0.0, a: 1.0 };
    pub const WHITE: Rgb = Rgb { r: 1.0, g: 1.0, b: 1.0, a: 1.0 };

    /// A color from 0...1 components; values outside the range are clamped.
    pub fn new(r: f64, g: f64, b: f64, a: f64) -> Self {
        Rgb { r: clamp(r), g: clamp(g), b: clamp(b), a: clamp(a) }
    }

    /// An opaque color from `0xRRGGBB`.
    pub const fn hex(hex: u32) -> Self {
        Rgb {
            r: ((hex >> 16) & 0xff) as f64 / 255.0,
            g: ((hex >> 8) & 0xff) as f64 / 255.0,
            b: (hex & 0xff) as f64 / 255.0,
            a: 1.0,
        }
    }

    /// `0xRRGGBB` of the color (alpha dropped), rounded per channel.
    pub fn to_hex(self) -> u32 {
        let c = |v: f64| (v * 255.0).round() as u32;
        (c(self.r) << 16) | (c(self.g) << 8) | c(self.b)
    }

    /// `0xRRGGBBAA`, rounded per channel (the format `gpui::rgba` takes).
    pub fn to_rgba_u32(self) -> u32 {
        (self.to_hex() << 8) | (self.a * 255.0).round() as u32
    }

    /// `#RRGGBB`, with `@alpha` appended when translucent (as Swift prints it).
    pub fn describe(self) -> String {
        let hex = format!("#{:06X}", self.to_hex());
        if self.a < 1.0 { format!("{hex}@{:.2}", self.a) } else { hex }
    }

    /// WCAG 2 relative luminance of the opaque color.
    pub fn relative_luminance(self) -> f64 {
        fn linear(c: f64) -> f64 {
            if c <= 0.04045 { c / 12.92 } else { ((c + 0.055) / 1.055).powf(2.4) }
        }
        0.2126 * linear(self.r) + 0.7152 * linear(self.g) + 0.0722 * linear(self.b)
    }

    /// WCAG 2 contrast ratio between two opaque colors (1...21).
    pub fn contrast(self, other: Rgb) -> f64 {
        let (a, b) = (self.relative_luminance(), other.relative_luminance());
        (a.max(b) + 0.05) / (a.min(b) + 0.05)
    }

    /// Linear sRGB mix: `fraction` 0 is self, 1 is `other`. Alpha is kept.
    pub fn mixed(self, other: Rgb, fraction: f64) -> Rgb {
        let t = clamp(fraction);
        Rgb::new(
            self.r + (other.r - self.r) * t,
            self.g + (other.g - self.g) * t,
            self.b + (other.b - self.b) * t,
            self.a,
        )
    }

    /// The same color at opacity `alpha`.
    pub fn with_alpha(self, alpha: f64) -> Rgb {
        Rgb::new(self.r, self.g, self.b, alpha)
    }

    /// The opaque color seen when this (possibly translucent) color is
    /// painted over `base` (whose own opacity is ignored).
    pub fn composited(self, base: Rgb) -> Rgb {
        base.mixed(self.with_alpha(1.0), self.a).with_alpha(1.0)
    }
}

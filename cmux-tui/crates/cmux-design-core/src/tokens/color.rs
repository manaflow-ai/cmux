//! The colour a token op reads and writes: sRGB components 0...1 plus opacity, as Swift's
//! `ThemeRGB`. The math is `cmux_theme_tokens::Rgb` (the same port), so mixes, alpha,
//! compositing and luminance match the app exactly.

pub use cmux_theme_tokens::Rgb;
use serde::{Deserialize, Serialize};

/// A colour on the wire: `{"r":..,"g":..,"b":..,"a":..}` (`a` defaults to 1).
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Color {
    pub r: f64,
    pub g: f64,
    pub b: f64,
    #[serde(default = "opaque")]
    pub a: f64,
}

fn opaque() -> f64 {
    1.0
}

impl From<Rgb> for Color {
    fn from(c: Rgb) -> Self {
        Color { r: c.r, g: c.g, b: c.b, a: c.a }
    }
}

impl From<Color> for Rgb {
    fn from(c: Color) -> Self {
        Rgb::new(c.r, c.g, c.b, c.a)
    }
}

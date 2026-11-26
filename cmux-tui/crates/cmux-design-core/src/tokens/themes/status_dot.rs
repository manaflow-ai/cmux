//! Status dots (`StatusDotHue.swift`, `ThemeTokens+StatusDotHue.swift`): a hue per meaning, its
//! lightness moved per theme until it reaches 3:1 on the rows it sits on.

use crate::tokens::color::Rgb;
use cmux_theme_tokens::{MINIMUM_MARK_CONTRAST, ThemeTokens, readable_over};
use serde::{Deserialize, Serialize};

/// A status mark whose hue means one thing in every row (Swift `StatusDotHue`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum StatusDotHue {
    /// Unread or new (`systemBlue`).
    Unread,
    /// Needs attention; in a theme, the theme's yellow (`ThemeTokens.attention`).
    Attention,
    /// Failed or stopped with an error (`systemRed`).
    Error,
    /// The notification blue (rgb 57 130 245).
    Notification,
}

/// An opaque colour from 8-bit components (Swift `ThemeRGB(r:g:b:)`).
fn rgb8(r: u8, g: u8, b: u8) -> Rgb {
    Rgb::new(f64::from(r) / 255.0, f64::from(g) / 255.0, f64::from(b) / 255.0, 1.0)
}

impl StatusDotHue {
    /// Every case, in Swift's `allCases` order.
    pub const ALL: [StatusDotHue; 4] =
        [Self::Unread, Self::Attention, Self::Error, Self::Notification];

    /// The mark's starting colour in a light or dark theme: the system colour's value.
    pub fn hue(self, is_dark: bool) -> Rgb {
        match self {
            Self::Unread => {
                if is_dark {
                    rgb8(10, 132, 255)
                } else {
                    rgb8(0, 122, 255)
                }
            }
            Self::Attention => {
                if is_dark {
                    rgb8(255, 214, 10)
                } else {
                    rgb8(255, 204, 0)
                }
            }
            Self::Error => {
                if is_dark {
                    rgb8(255, 69, 58)
                } else {
                    rgb8(255, 59, 48)
                }
            }
            Self::Notification => rgb8(57, 130, 245),
        }
    }
}

/// `color` mixed toward `pole` in 2% steps until it reaches 3:1 over every surface (or `pole`).
/// Swift's private `readableDot`; the same walk as `cmux_theme_tokens::readable_over` at 3:1.
pub fn readable_dot(color: Rgb, surfaces: &[Rgb], pole: Rgb) -> Rgb {
    readable_over(color, surfaces, pole, MINIMUM_MARK_CONTRAST)
}

/// The rows a status dot must read on: the bare row, the selected row, the pressed row.
pub fn status_dot_rows(tokens: &ThemeTokens) -> [Rgb; 3] {
    let row = tokens.window_background.with_alpha(1.0);
    [row, tokens.selection_fill.composited(row), tokens.pressed_fill.composited(row)]
}

/// `mark`'s opaque colour in this theme (Swift `ThemeTokens.statusDot(_:)`).
pub fn status_dot(tokens: &ThemeTokens, mark: StatusDotHue) -> Rgb {
    let rows = status_dot_rows(tokens);
    let start = match mark {
        StatusDotHue::Attention => tokens.attention.with_alpha(1.0),
        _ => mark.hue(tokens.is_dark),
    };
    let pole = if rows[0].relative_luminance() < 0.18 { Rgb::WHITE } else { Rgb::BLACK };
    readable_dot(start, &rows, pole)
}

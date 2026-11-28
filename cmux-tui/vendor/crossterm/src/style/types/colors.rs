use crate::style::{Color, Colored};

/// Represents, optionally, a foreground and/or a background color.
///
/// It can be applied using the `SetColors` command.
///
/// It can also be created from a [Colored](enum.Colored.html) value or a tuple of
/// `(Color, Color)` in the order `(foreground, background)`.
///
/// The [then](#method.then) method can be used to combine `Colors` values.
///
/// For example:
/// ```no_run
/// use crossterm::style::{Color, Colors, Colored};
///
/// // An example color, loaded from a config, file in ANSI format.
/// let config_color = "38;2;23;147;209";
///
/// // Default to green text on a black background.
/// let default_colors = Colors::new(Color::Green, Color::Black);
/// // Load a colored value from a config and override the default colors
/// let colors = match Colored::parse_ansi(config_color) {
///     Some(colored) => default_colors.then(&colored.into()),
///     None => default_colors,
/// };
/// ```
///
/// See [Color](enum.Color.html).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Colors {
    pub foreground: Option<Color>,
    pub background: Option<Color>,
}

impl Colors {
    /// Returns a new `Color` which, when applied, has the same effect as applying `self` and *then*
    /// `other`.
    pub fn then(&self, other: &Colors) -> Colors {
        Colors {
            foreground: other.foreground.or(self.foreground),
            background: other.background.or(self.background),
        }
    }
}

impl Colors {
    pub fn new(foreground: Color, background: Color) -> Colors {
        Colors { foreground: Some(foreground), background: Some(background) }
    }
}

impl From<Colored> for Colors {
    fn from(colored: Colored) -> Colors {
        match colored {
            Colored::ForegroundColor(color) => Colors { foreground: Some(color), background: None },
            Colored::BackgroundColor(color) => Colors { foreground: None, background: Some(color) },
            Colored::UnderlineColor(color) => Colors { foreground: None, background: Some(color) },
        }
    }
}

#[cfg(test)]
#[path = "colors_tests.rs"]
mod tests;

use parking_lot::Once;
use std::fmt::{self, Formatter};
use std::sync::atomic::{AtomicBool, Ordering};

#[cfg(feature = "serde")]
use serde::{Deserialize, Serialize};

use crate::style::{parse_next_u8, Color};

/// Represents a foreground or background color.
///
/// This can be converted to a [Colors](struct.Colors.html) by calling `into()` and applied
/// using the [SetColors](struct.SetColors.html) command.
#[cfg_attr(feature = "serde", derive(Serialize, Deserialize))]
#[derive(Copy, Clone, Debug, PartialEq, Eq, Ord, PartialOrd, Hash)]
pub enum Colored {
    /// A foreground color.
    ForegroundColor(Color),
    /// A background color.
    BackgroundColor(Color),
    /// An underline color.
    /// Important: doesn't work on windows 10 or lower.
    UnderlineColor(Color),
}

static ANSI_COLOR_DISABLED: AtomicBool = AtomicBool::new(false);
static INITIALIZER: Once = Once::new();

impl Colored {
    /// Parse an ANSI foreground or background color.
    /// This is the string that would appear within an `ESC [ <str> m` escape sequence, as found in
    /// various configuration files.
    ///
    /// # Examples
    ///
    /// ```
    /// use crossterm::style::{Colored::{self, ForegroundColor, BackgroundColor}, Color};
    ///
    /// assert_eq!(Colored::parse_ansi("38;5;0"), Some(ForegroundColor(Color::Black)));
    /// assert_eq!(Colored::parse_ansi("38;5;26"), Some(ForegroundColor(Color::AnsiValue(26))));
    /// assert_eq!(Colored::parse_ansi("48;2;50;60;70"), Some(BackgroundColor(Color::Rgb { r: 50, g: 60, b: 70 })));
    /// assert_eq!(Colored::parse_ansi("49"), Some(BackgroundColor(Color::Reset)));
    /// assert_eq!(Colored::parse_ansi("invalid color"), None);
    /// ```
    ///
    /// Currently, 3/4 bit color values aren't supported so return `None`.
    ///
    /// See also: [`Color::parse_ansi`].
    pub fn parse_ansi(ansi: &str) -> Option<Self> {
        use Colored::{BackgroundColor, ForegroundColor, UnderlineColor};

        let values = &mut ansi.split(';');

        let output = match parse_next_u8(values)? {
            38 => return Color::parse_ansi_iter(values).map(ForegroundColor),
            48 => return Color::parse_ansi_iter(values).map(BackgroundColor),
            58 => return Color::parse_ansi_iter(values).map(UnderlineColor),

            39 => ForegroundColor(Color::Reset),
            49 => BackgroundColor(Color::Reset),
            59 => UnderlineColor(Color::Reset),

            _ => return None,
        };

        if values.next().is_some() {
            return None;
        }

        Some(output)
    }

    /// Checks whether ansi color sequences are disabled by setting of NO_COLOR
    /// in environment as per <https://no-color.org/>
    pub fn ansi_color_disabled() -> bool {
        !std::env::var("NO_COLOR").unwrap_or("".to_string()).is_empty()
    }

    pub fn ansi_color_disabled_memoized() -> bool {
        INITIALIZER.call_once(|| {
            ANSI_COLOR_DISABLED.store(Self::ansi_color_disabled(), Ordering::SeqCst);
        });

        ANSI_COLOR_DISABLED.load(Ordering::SeqCst)
    }

    pub fn set_ansi_color_disabled(val: bool) {
        // Force the one-time initializer to run.
        _ = Self::ansi_color_disabled_memoized();
        ANSI_COLOR_DISABLED.store(val, Ordering::SeqCst);
    }
}

impl fmt::Display for Colored {
    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {
        let color;

        if Self::ansi_color_disabled_memoized() {
            return Ok(());
        }

        match *self {
            Colored::ForegroundColor(new_color) => {
                if new_color == Color::Reset {
                    return f.write_str("39");
                } else {
                    f.write_str("38;")?;
                    color = new_color;
                }
            }
            Colored::BackgroundColor(new_color) => {
                if new_color == Color::Reset {
                    return f.write_str("49");
                } else {
                    f.write_str("48;")?;
                    color = new_color;
                }
            }
            Colored::UnderlineColor(new_color) => {
                if new_color == Color::Reset {
                    return f.write_str("59");
                } else {
                    f.write_str("58;")?;
                    color = new_color;
                }
            }
        }

        match color {
            Color::Black => f.write_str("5;0"),
            Color::DarkGrey => f.write_str("5;8"),
            Color::Red => f.write_str("5;9"),
            Color::DarkRed => f.write_str("5;1"),
            Color::Green => f.write_str("5;10"),
            Color::DarkGreen => f.write_str("5;2"),
            Color::Yellow => f.write_str("5;11"),
            Color::DarkYellow => f.write_str("5;3"),
            Color::Blue => f.write_str("5;12"),
            Color::DarkBlue => f.write_str("5;4"),
            Color::Magenta => f.write_str("5;13"),
            Color::DarkMagenta => f.write_str("5;5"),
            Color::Cyan => f.write_str("5;14"),
            Color::DarkCyan => f.write_str("5;6"),
            Color::White => f.write_str("5;15"),
            Color::Grey => f.write_str("5;7"),
            Color::Rgb { r, g, b } => write!(f, "2;{r};{g};{b}"),
            Color::AnsiValue(val) => write!(f, "5;{val}"),
            _ => Ok(()),
        }
    }
}

#[cfg(test)]
#[path = "colored_tests.rs"]
mod tests;

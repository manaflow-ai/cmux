//! The settings files tools keep their save folder in (Swift `ScreenshotSettingsFileFormat`).

/// A settings file's format.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SettingsFormat {
    /// `key=value` lines (Flameshot's `flameshot.ini`); sections are ignored.
    Ini,
    /// A JSON object (Kap's `config.json`).
    Json,
}

impl SettingsFormat {
    /// The format of a C ABI raw value (1 ini, 2 json).
    pub const fn from_raw(raw: u32) -> Option<Self> {
        match raw {
            1 => Some(Self::Ini),
            2 => Some(Self::Json),
            _ => None,
        }
    }

    /// The string value of `key` in `text`, or None when missing, empty (ini) or not a string (json).
    pub fn value(self, key: &str, text: &str) -> Option<String> {
        match self {
            Self::Ini => text
                .split(is_newline)
                .filter(|line| !line.is_empty())
                .find_map(|line| {
                    // Swift's split drops empty pieces: "=x" has no key, "k=" no value.
                    let line = line.trim_start_matches('=');
                    let (name, value) = line.split_once('=')?;
                    if value.is_empty() || name.trim_matches(is_space) != key {
                        return None;
                    }
                    Some(value.trim_matches(is_space))
                })
                .filter(|value| !value.is_empty())
                .map(str::to_owned),
            Self::Json => match serde_json::from_str::<serde_json::Value>(text).ok()? {
                serde_json::Value::Object(map) => map.get(key)?.as_str().map(str::to_owned),
                _ => None,
            },
        }
    }
}

/// Swift's `Character.isNewline`.
fn is_newline(c: char) -> bool {
    matches!(c, '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

/// Foundation's `.whitespaces`: tab and the space separators.
fn is_space(c: char) -> bool {
    c == '\t' || (c.is_whitespace() && !is_newline(c))
}

#[cfg(test)]
#[path = "settings_tests.rs"]
mod tests;

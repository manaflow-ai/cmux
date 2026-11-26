//! iTerm2's profiles from its preferences file (`New Bookmarks`), and each profile's colors as
//! Ghostty theme lines, the form cmux keeps a theme in (`ITermProfiles`).

use plist::{Dictionary, Value};
use serde::{Deserialize, Serialize};

/// The largest iTerm2 preferences file read.
pub const MAXIMUM_PREFERENCES_BYTES: usize = 16 * 1024 * 1024;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Profile {
    pub name: String,
    /// iTerm2's default profile (`Default Bookmark Guid`).
    pub is_default: bool,
    /// `palette = N=#rrggbb`, `background = #rrggbb`, ... (colors only, nothing a theme may not set).
    pub theme_lines: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Profiles {
    pub profiles: Vec<Profile>,
}

/// iTerm2's color keys and the Ghostty key each becomes.
const COLOR_KEYS: [(&str, &str); 7] = [
    ("Background Color", "background"),
    ("Foreground Color", "foreground"),
    ("Cursor Color", "cursor-color"),
    ("Cursor Text Color", "cursor-text"),
    ("Selection Color", "selection-background"),
    ("Selected Text Color", "selection-foreground"),
    ("Bold Color", "bold-color"),
];

impl Profiles {
    /// None when `data` is not a property list (binary or XML) with profiles.
    pub fn read(data: &[u8]) -> Option<Profiles> {
        let root = Value::from_reader(std::io::Cursor::new(data)).ok()?;
        let root = root.as_dictionary()?;
        let bookmarks = root.get("New Bookmarks")?.as_array()?;
        let default_guid = root.get("Default Bookmark Guid").and_then(Value::as_string);
        let profiles = bookmarks
            .iter()
            .filter_map(|bookmark| {
                let bookmark = bookmark.as_dictionary()?;
                let name = bookmark.get("Name")?.as_string()?.trim();
                if name.is_empty() {
                    return None;
                }
                let guid = bookmark.get("Guid").and_then(Value::as_string);
                Some(Profile {
                    name: name.to_owned(),
                    is_default: default_guid.is_some() && guid == default_guid,
                    theme_lines: theme_lines(bookmark),
                })
            })
            .collect();
        Some(Profiles { profiles })
    }

    /// The default profile, else the first.
    pub fn preferred(&self) -> Option<&Profile> {
        self.profiles.iter().find(|profile| profile.is_default).or_else(|| self.profiles.first())
    }
}

fn theme_lines(bookmark: &Dictionary) -> Vec<String> {
    // A profile with separate light and dark colors keeps the plain keys empty; the dark set stands in.
    let color =
        |key: &str| hex(bookmark.get(key)).or_else(|| hex(bookmark.get(&format!("{key} (Dark)"))));
    let mut lines: Vec<String> = (0..16)
        .filter_map(|index| {
            color(&format!("Ansi {index} Color")).map(|hex| format!("palette = {index}={hex}"))
        })
        .collect();
    lines.extend(
        COLOR_KEYS
            .iter()
            .filter_map(|(iterm, ghostty)| color(iterm).map(|hex| format!("{ghostty} = {hex}"))),
    );
    lines
}

/// `{Red Component, Green Component, Blue Component}` (0...1) as `#rrggbb`.
fn hex(value: Option<&Value>) -> Option<String> {
    let color = value?.as_dictionary()?;
    let channel = |key: &str| -> Option<u8> {
        let number = match color.get(key)? {
            Value::Real(real) => *real,
            Value::Integer(integer) => integer
                .as_signed()
                .map(|n| n as f64)
                .or_else(|| integer.as_unsigned().map(|n| n as f64))?,
            _ => return None,
        };
        // Clamped to 0...1, so the product fits a byte.
        #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
        number.is_finite().then(|| (number.clamp(0.0, 1.0) * 255.0).round() as u8)
    };
    Some(format!(
        "#{:02x}{:02x}{:02x}",
        channel("Red Component")?,
        channel("Green Component")?,
        channel("Blue Component")?
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn color(r: f64, g: f64, b: f64) -> Value {
        let mut color = Dictionary::new();
        color.insert("Red Component".into(), Value::Real(r));
        color.insert("Green Component".into(), Value::Real(g));
        color.insert("Blue Component".into(), Value::Real(b));
        Value::Dictionary(color)
    }

    fn bookmark(entries: Vec<(&str, Value)>) -> Value {
        Value::Dictionary(entries.into_iter().map(|(key, value)| (key.to_owned(), value)).collect())
    }

    fn preferences(binary: bool) -> Vec<u8> {
        let mut root = Dictionary::new();
        root.insert("Default Bookmark Guid".into(), Value::String("B".into()));
        root.insert(
            "New Bookmarks".into(),
            Value::Array(vec![
                bookmark(vec![
                    ("Name", "Work".into()),
                    ("Guid", "A".into()),
                    ("Background Color", color(1.0, 1.0, 1.0)),
                ]),
                bookmark(vec![
                    ("Name", " Default ".into()),
                    ("Guid", "B".into()),
                    ("Background Color", color(0.0, 0.0, 0.0)),
                    ("Ansi 1 Color", color(1.0, 0.0, 0.0)),
                    ("Foreground Color (Dark)", color(0.5, 0.5, 0.5)),
                ]),
                bookmark(vec![("Name", "  ".into())]),
            ]),
        );
        let mut out = Vec::new();
        if binary {
            Value::Dictionary(root).to_writer_binary(&mut out).unwrap();
        } else {
            Value::Dictionary(root).to_writer_xml(&mut out).unwrap();
        }
        out
    }

    #[test]
    fn iterm_profiles_and_their_colors() {
        for binary in [true, false] {
            let profiles = Profiles::read(&preferences(binary)).unwrap();
            assert_eq!(profiles.profiles.len(), 2);
            let preferred = profiles.preferred().unwrap();
            assert_eq!(preferred.name, "Default");
            assert_eq!(
                preferred.theme_lines,
                ["palette = 1=#ff0000", "background = #000000", "foreground = #808080"]
            );
            assert_eq!(profiles.profiles[0].theme_lines, ["background = #ffffff"]);
        }
    }

    #[test]
    fn no_default_means_the_first_and_junk_reads_nothing() {
        let mut root = Dictionary::new();
        root.insert(
            "New Bookmarks".into(),
            Value::Array(vec![bookmark(vec![("Name", "Only".into())])]),
        );
        let mut out = Vec::new();
        Value::Dictionary(root).to_writer_binary(&mut out).unwrap();
        let profiles = Profiles::read(&out).unwrap();
        assert_eq!(
            profiles.preferred().map(|p| (p.name.as_str(), p.is_default)),
            Some(("Only", false))
        );
        assert_eq!(Profiles::read(b"not a plist"), None);
        let mut empty = Vec::new();
        Value::Dictionary(Dictionary::new()).to_writer_binary(&mut empty).unwrap();
        assert_eq!(Profiles::read(&empty), None);
    }

    #[test]
    fn channels_clamp_and_take_integers() {
        let mut color = Dictionary::new();
        color.insert("Red Component".into(), Value::Real(2.0));
        color.insert("Green Component".into(), Value::Integer(0.into()));
        color.insert("Blue Component".into(), Value::Real(-1.0));
        assert_eq!(hex(Some(&Value::Dictionary(color.clone()))).as_deref(), Some("#ff0000"));
        color.remove("Blue Component");
        assert_eq!(hex(Some(&Value::Dictionary(color))), None);
    }
}

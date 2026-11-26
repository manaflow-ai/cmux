//! A theme file's own terminal colors (`"colors"`, a `"ghostty"` block) as
//! `appearance.themeEdits` of the terminal theme it names, and the contrast
//! guard (Swift `ThemeFileOverlay.Reader.readColors`).

use std::collections::{BTreeMap, BTreeSet};

use cmux_theme_tokens::{
    AppTheme, AppToken, GHOSTTY_DEFAULT_PALETTE, Rgb, ThemeAccent, parse_color,
};
use serde_json::{Map, Value};

use super::Reader;
use crate::keypath::key_path;
use crate::text::ThemeSpec;
use crate::value::value_at;

/// One color map: token name to color text.
type ColorMap = BTreeMap<String, String>;

const EDITS_KEY: &str = "appearance.themeEdits";
const THEME_KEY: &str = "appearance.theme";
/// `AppTheme.textMinimum`: text on its background.
const TEXT_MINIMUM: f64 = 4.5;
/// A `colors.light` or `colors.dark` half over a theme that is the same in
/// both appearances.
pub(super) const HALF_NEEDS_PAIR: &str =
    "a light or dark half needs appearance.theme \"light:NAME,dark:NAME\"";

/// The color tokens a theme edit takes (Swift `ThemeEdits.tokens`).
fn is_token(token: &str) -> bool {
    matches!(token, "background" | "foreground" | "cursor" | "selection" | "accent")
        || token.parse::<u8>().is_ok_and(|index| index < 16 && token == index.to_string())
}

/// `#rrggbb` exactly (Swift `ThemeEdits.isColor`).
fn is_color(text: &str) -> bool {
    text.strip_prefix('#')
        .is_some_and(|digits| digits.len() == 6 && digits.chars().all(|c| c.is_ascii_hexdigit()))
}

fn hex(color: Rgb) -> String {
    format!("#{:06x}", color.to_hex())
}

/// A theme file's colors: the plain ones paint every theme it names, and a
/// `"light"` or `"dark"` half paints only that side of `light:X,dark:Y`,
/// over the plain ones, so one file is one look for both appearances.
#[derive(Default)]
struct FileColors {
    shared: BTreeMap<String, String>,
    light: BTreeMap<String, String>,
    dark: BTreeMap<String, String>,
}

impl FileColors {
    fn is_empty(&self) -> bool {
        self.shared.is_empty() && self.light.is_empty() && self.dark.is_empty()
    }
}

pub(super) fn read(reader: &mut Reader<'_>, members: &Map<String, Value>, base: &Value) {
    let edits_path = key_path(EDITS_KEY);
    let own_edits = reader
        .values
        .iter()
        .find(|(path, _)| *path == edits_path)
        .and_then(|(_, value)| value.as_object().cloned())
        .unwrap_or_default();
    let mut colors = FileColors::default();
    if let Some(ghostty) = members.get("ghostty") {
        read_ghostty(reader, ghostty, &mut colors.shared);
    }
    if let Some(value) = members.get("colors") {
        let FileColors { shared, light, dark } = &mut colors;
        read_color_map(reader, value, "colors", shared, Some((light, dark)));
    }
    let mut themes: BTreeSet<String> = own_edits
        .keys()
        .filter_map(|key| key.rsplit_once('/').map(|(theme, _)| theme.to_string()))
        .collect();
    let shown = value_at(base, &edits_path).and_then(Value::as_object).cloned().unwrap_or_default();
    let mut edits = shown.clone();
    edits.extend(own_edits);
    if !colors.is_empty() {
        let theme_path = key_path(THEME_KEY);
        let theme = reader
            .values
            .iter()
            .find(|(path, _)| *path == theme_path)
            .and_then(|(_, value)| value.as_str().map(str::to_string))
            .or_else(|| value_at(base, &theme_path).and_then(Value::as_str).map(str::to_string));
        match theme.as_deref().and_then(ThemeSpec::parse) {
            Some(spec) => {
                // One theme for both appearances has no sides to tell apart:
                // its halves are refused and the plain colors apply.
                let sides = if spec.light == spec.dark {
                    for (half, side) in [("light", &colors.light), ("dark", &colors.dark)] {
                        if !side.is_empty() {
                            reader.refuse(&format!("colors.{half}"), None, HALF_NEEDS_PAIR);
                        }
                    }
                    vec![(spec.light, None)]
                } else {
                    vec![(spec.light, Some(&colors.light)), (spec.dark, Some(&colors.dark))]
                };
                for (name, side) in sides {
                    for (token, color) in colors.shared.iter().chain(side.into_iter().flatten()) {
                        edits.insert(format!("{name}/{token}"), Value::String(color.clone()));
                    }
                    themes.insert(name);
                }
            }
            None => reader.refuse(
                "colors",
                None,
                "colors need appearance.theme: they edit that terminal theme",
            ),
        }
    }
    if themes.is_empty() {
        return;
    }
    for name in &themes {
        guard_contrast(reader, &mut edits, &shown, name);
    }
    reader.values.retain(|(path, _)| *path != edits_path);
    reader.values.push((edits_path, Value::Object(edits)));
}

/// `colors` at `path`: the plain tokens into `colors`, and, at the top
/// (`halves` given), a `"light"` and a `"dark"` map of the same tokens into
/// their halves. A half holds no halves of its own.
fn read_color_map(
    reader: &mut Reader<'_>,
    value: &Value,
    path: &str,
    colors: &mut BTreeMap<String, String>,
    mut halves: Option<(&mut ColorMap, &mut ColorMap)>,
) {
    let Value::Object(entries) = value else {
        return reader.refuse(path, Some(value), "expected an object");
    };
    let mut keys: Vec<&String> = entries.keys().collect();
    keys.sort();
    for token in keys {
        let entry = &entries[token];
        let at = format!("{path}.{token}");
        if token == "palette" {
            match entry.as_array() {
                Some(list) if list.len() <= 16 => {
                    for (index, item) in list.iter().enumerate() {
                        set(reader, path, &index.to_string(), item, colors);
                    }
                }
                _ => reader.refuse(
                    &at,
                    Some(entry),
                    "expected a list of up to 16 \"#RRGGBB\" colors",
                ),
            }
        } else if is_token(token) {
            set(reader, path, token, entry, colors);
        } else if let (Some((light, dark)), "light" | "dark") = (halves.as_mut(), token.as_str()) {
            let half = if token == "light" { &mut **light } else { &mut **dark };
            read_color_map(reader, entry, &at, half, None);
        } else if halves.is_some() {
            reader.refuse(
                &at,
                Some(entry),
                "unknown color; expected background, foreground, cursor, selection, accent, 0 to 15, palette, light or dark",
            );
        } else {
            reader.refuse(
                &at,
                Some(entry),
                "unknown color; expected background, foreground, cursor, selection, accent, 0 to 15 or palette",
            );
        }
    }
}

fn set(
    reader: &mut Reader<'_>,
    path: &str,
    token: &str,
    value: &Value,
    colors: &mut BTreeMap<String, String>,
) {
    match value.as_str() {
        Some(text) if is_color(text) => {
            colors.insert(token.to_string(), text.to_lowercase());
        }
        _ => reader.refuse(&format!("{path}.{token}"), Some(value), "expected \"#RRGGBB\""),
    }
}

/// A Ghostty theme block: a string or a list of `key = value` lines, read as
/// Ghostty theme files are (Swift `ThemeFileColors`): a background and a
/// foreground are required.
fn read_ghostty(reader: &mut Reader<'_>, value: &Value, colors: &mut BTreeMap<String, String>) {
    let text = match value {
        Value::String(text) => Some(text.clone()),
        Value::Array(lines) => {
            Some(lines.iter().filter_map(Value::as_str).collect::<Vec<_>>().join("\n"))
        }
        _ => None,
    };
    let mut read = BTreeMap::new();
    for line in text.as_deref().unwrap_or_default().lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((key, raw)) = line.split_once('=') else { continue };
        let (key, raw) = (key.trim(), raw.trim());
        let token = match key {
            "background" | "foreground" => key.to_string(),
            "cursor-color" => "cursor".to_string(),
            "selection-background" => "selection".to_string(),
            "palette" => {
                let Some((index, color)) = raw.split_once('=') else { continue };
                let Ok(index) = index.trim().parse::<u8>() else { continue };
                if index > 15 {
                    continue;
                }
                if let Some(color) = parse_color(color.trim()) {
                    read.insert(index.to_string(), hex(color));
                }
                continue;
            }
            _ => continue,
        };
        if let Some(color) = parse_color(raw) {
            read.insert(token, hex(color));
        }
    }
    let accent = text.as_deref().and_then(cmux_theme_tokens::theme_file_accent);
    if !read.contains_key("background") || !read.contains_key("foreground") {
        return reader.refuse(
            "ghostty",
            Some(value),
            "expected Ghostty theme lines with a background and a foreground",
        );
    }
    if let Some(accent) = accent {
        read.insert("accent".to_string(), hex(accent));
    }
    colors.extend(read);
}

/// A foreground under 4.5:1 on its background takes the app theme's text
/// color for them (`AppTheme::derive`, the contract every chrome token meets).
/// A pair the settings already show (`shown`, their own edits) stays as it is:
/// a file that copies the settings changes nothing.
fn guard_contrast(
    reader: &mut Reader<'_>,
    edits: &mut Map<String, Value>,
    shown: &Map<String, Value>,
    theme: &str,
) {
    let color = |edits: &Map<String, Value>, token: &str| {
        edits.get(&format!("{theme}/{token}")).and_then(Value::as_str).and_then(parse_color)
    };
    let (Some(background), Some(foreground)) =
        (color(edits, "background"), color(edits, "foreground"))
    else {
        return;
    };
    if color(shown, "background") == Some(background)
        && color(shown, "foreground") == Some(foreground)
    {
        return;
    }
    let ratio = foreground.contrast(background);
    if ratio >= TEXT_MINIMUM {
        return;
    }
    let mut palette = GHOSTTY_DEFAULT_PALETTE;
    for (index, slot) in palette.iter_mut().enumerate() {
        if let Some(edit) = color(edits, &index.to_string()) {
            *slot = edit;
        }
    }
    let fixed = hex(AppTheme::derive(background, foreground, &palette, ThemeAccent::Neutral, None)
        .get(AppToken::Text));
    let written = hex(foreground);
    let rounded = (ratio * 10.0).round() / 10.0;
    reader.correct(
        format!("{theme}'s foreground {written} is {rounded}:1 on its background, so cmux shows {fixed} (4.5:1 or more)"),
        &written,
        "foreground",
    );
    edits.insert(format!("{theme}/foreground"), Value::String(fixed));
}

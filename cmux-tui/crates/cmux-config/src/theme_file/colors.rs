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

const EDITS_KEY: &str = "appearance.themeEdits";
const THEME_KEY: &str = "appearance.theme";
/// `AppTheme.textMinimum`: text on its background.
const TEXT_MINIMUM: f64 = 4.5;

/// The color tokens a theme edit takes (Swift `ThemeEdits.tokens`).
fn is_token(token: &str) -> bool {
    matches!(token, "background" | "foreground" | "cursor" | "selection" | "accent")
        || token.parse::<u8>().is_ok_and(|index| index < 16 && token == index.to_string())
}

/// `#rrggbb` exactly (Swift `ThemeEdits.isColor`).
fn is_color(text: &str) -> bool {
    text.len() == 7 && text.starts_with('#') && text[1..].chars().all(|c| c.is_ascii_hexdigit())
}

fn hex(color: Rgb) -> String {
    format!("#{:06x}", color.to_hex())
}

pub(super) fn read(reader: &mut Reader<'_>, members: &Map<String, Value>, base: &Value) {
    let edits_path = key_path(EDITS_KEY);
    let own_edits = reader
        .values
        .iter()
        .find(|(path, _)| *path == edits_path)
        .and_then(|(_, value)| value.as_object().cloned())
        .unwrap_or_default();
    let mut colors = BTreeMap::new();
    if let Some(ghostty) = members.get("ghostty") {
        read_ghostty(reader, ghostty, &mut colors);
    }
    if let Some(value) = members.get("colors") {
        read_color_map(reader, value, &mut colors);
    }
    let mut themes: BTreeSet<String> = own_edits
        .keys()
        .filter_map(|key| key.rsplit_once('/').map(|(theme, _)| theme.to_string()))
        .collect();
    let mut edits =
        value_at(base, &edits_path).and_then(Value::as_object).cloned().unwrap_or_default();
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
                for name in BTreeSet::from([spec.light, spec.dark]) {
                    for (token, color) in &colors {
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
        guard_contrast(reader, &mut edits, name);
    }
    reader.values.retain(|(path, _)| *path != edits_path);
    reader.values.push((edits_path, Value::Object(edits)));
}

fn read_color_map(reader: &mut Reader<'_>, value: &Value, colors: &mut BTreeMap<String, String>) {
    let Value::Object(entries) = value else {
        return reader.refuse("colors", Some(value), "expected an object");
    };
    let mut keys: Vec<&String> = entries.keys().collect();
    keys.sort();
    for token in keys {
        let entry = &entries[token];
        if token == "palette" {
            match entry.as_array() {
                Some(list) if list.len() <= 16 => {
                    for (index, item) in list.iter().enumerate() {
                        set(reader, &index.to_string(), item, colors);
                    }
                }
                _ => reader.refuse(
                    "colors.palette",
                    Some(entry),
                    "expected a list of up to 16 \"#RRGGBB\" colors",
                ),
            }
        } else if is_token(token) {
            set(reader, token, entry, colors);
        } else {
            reader.refuse(
                &format!("colors.{token}"),
                Some(entry),
                "unknown color; expected background, foreground, cursor, selection, accent, 0 to 15 or palette",
            );
        }
    }
}

fn set(reader: &mut Reader<'_>, token: &str, value: &Value, colors: &mut BTreeMap<String, String>) {
    match value.as_str() {
        Some(text) if is_color(text) => {
            colors.insert(token.to_string(), text.to_lowercase());
        }
        _ => reader.refuse(&format!("colors.{token}"), Some(value), "expected \"#RRGGBB\""),
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
fn guard_contrast(reader: &mut Reader<'_>, edits: &mut Map<String, Value>, theme: &str) {
    let color = |edits: &Map<String, Value>, token: &str| {
        edits.get(&format!("{theme}/{token}")).and_then(Value::as_str).and_then(parse_color)
    };
    let (Some(background), Some(foreground)) =
        (color(edits, "background"), color(edits, "foreground"))
    else {
        return;
    };
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

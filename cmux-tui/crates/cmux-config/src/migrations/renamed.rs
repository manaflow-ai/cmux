//! Keys a newer key replaced while the app still applies the old one when
//! the new key is absent: the port of Swift `RenamedSettingKeys`. Settings
//! reads the old key's value for the new row, and every write or reset of the
//! new row removes the old key, so it never applies again behind it.

use serde_json::Value;

use crate::schema::{Kind, Schema, replaced_by_row, replaced_keys};
use crate::value::value_at;

const BACKGROUND: [&str; 2] = ["appearance", "background"];
const BACKDROP_ART: [&str; 2] = ["appearance", "backdropArt"];
const COMPUTER_USE_ENABLED: [&str; 2] = ["computerUse", "enabled"];

/// Ids of the earlier backdrop set (figure drawings and Met paintings), which
/// a cmux.json written before cx-t2x.7 may still name, and the work that now
/// stands in for each (Swift `BackdropArt.retiredIDs`).
const RETIRED_ART: [(&str, &str); 11] = [
    ("wheat-field-with-cypresses", "van-gogh-wheat-field-cypresses"),
    ("met-sunflowers-436524", "van-gogh-sunflowers"),
    ("met-women-picking-olives-436536", "van-gogh-almond-blossom"),
    ("met-saint-catherine-436908", "raphael-sistine-madonna"),
    ("met-woman-man-casement-436896", "vermeer-pearl-earring"),
    ("nga-degas-halevy-standing-66489", "degas-blue-dancers"),
    ("nga-degas-dancer-from-behind-32137", "degas-green-dancers"),
    ("nga-carpaccio-groups-of-male-figures-73858", "bruegel-fall-rebel-angels"),
    ("nga-perino-del-vaga-figure-studies-57613", "michelangelo-creation-of-adam"),
    ("nga-rubens-battle-of-nude-men-63034", "rubens-st-francis-xavier"),
    ("nga-teniers-market-figures-62615", "bruegel-hunters-snow"),
];

fn owned(path: &[&str]) -> Vec<String> {
    path.iter().map(|part| (*part).to_owned()).collect()
}

/// The old key `path` replaced, if any.
pub fn legacy_path(path: &[String]) -> Option<Vec<String>> {
    // A retired key with `replaced_by` (schemas/settings/retired-keys.json): the
    // Session Info placement, computerUse.mode and the workspace-row toggles among them.
    // A row may replace several (`updates.automatic`): the first, in read order.
    if let Some(replaced) = replaced_by_row(path).next() {
        return Some(replaced.old.clone());
    }
    // `appearance.background` replaced the paintings-only `appearance.backdropArt`.
    (path == BACKGROUND).then(|| owned(&BACKDROP_ART))
}

/// Every renamed row and the old key it replaced, as [`legacy_path`] answers
/// them: the app reads this once rather than asking per row.
pub fn legacy_paths() -> Vec<(Vec<String>, Vec<String>)> {
    let mut out: Vec<(Vec<String>, Vec<String>)> = Vec::new();
    for replaced in replaced_keys() {
        if !out.iter().any(|(row, _)| *row == replaced.row) {
            out.push((replaced.row.clone(), replaced.old.clone()));
        }
    }
    if !out.iter().any(|(row, _)| *row == BACKGROUND) {
        out.push((owned(&BACKGROUND), owned(&BACKDROP_ART)));
    }
    out
}

/// A bundled work by id, a retired id's stand-in, else `none` (Swift
/// `BackdropArt(id:)?.rawValue ?? "none"`).
fn backdrop_art(value: &Value) -> Value {
    let id = value.as_str().unwrap_or_default();
    let schema = Schema::embedded();
    let bundled = schema.row_at(&owned(&BACKDROP_ART)).is_some_and(|row| match &row.kind {
        Kind::Choice(choices) => id != "none" && choices.iter().any(|choice| choice.value == id),
        _ => false,
    });
    if bundled {
        return Value::String(id.to_owned());
    }
    let art = RETIRED_ART.iter().find(|(old, _)| *old == id).map_or("none", |(_, art)| art);
    Value::String(art.to_owned())
}

/// The old key's value as the new row shows it: what the app applies from it.
pub fn legacy_value(path: &[String], root: &Value) -> Option<Value> {
    // As the retired-keys table maps it: the first old key, in read order, whose value it
    // lists (a row may replace several, `updates.automatic`); any other old value is the
    // row's default (Swift `RenamedSettingKeys.legacyValue`).
    let mut replaced = replaced_by_row(path).peekable();
    if replaced.peek().is_some() {
        return replaced.find_map(|replaced| {
            let value = value_at(root, &replaced.old)?;
            // An old `"enabled": false` reads as mode "off" until the person picks a mode.
            if replaced.old == COMPUTER_USE_ENABLED {
                return (value == &Value::Bool(false)).then(|| Value::String("off".to_owned()));
            }
            replaced.read(value).cloned()
        });
    }
    let legacy = legacy_path(path)?;
    let value = value_at(root, &legacy)?;
    if legacy == BACKDROP_ART {
        return Some(backdrop_art(value));
    }
    Some(value.clone())
}

#[cfg(test)]
#[path = "renamed_tests.rs"]
mod tests;

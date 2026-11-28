//! Chrome placement sub-parses and theme file application: Swift
//! `TabShapeSetting`, `GooeyTabsSetting`, `CornerFlushSetting`,
//! `TitleAreaContrastSetting` / `TitleAreaToneSetting` (their `parse`), and
//! `ThemeFileOverlay.applied(to:managed:)` / `density(under:)`.
//!
//! - `chrome_placement.parse` `{root}` answers `{values, diagnostics}`:
//!   `values` holds `tabShape`, `gooeyTabs`, `titleAreaTone`, `titleAreaContrast`
//!   (the schema default for a missing or bad value, a number clamped into its
//!   range) and `cornerFlush` (absent when unset or bad). `diagnostics` are
//!   `{kind: "invalidValue", path, message}`.
//! - `theme.applied` `{values: [{path, value}], root, managed?}` answers `{root}`:
//!   `root` with every value set, except keys a managed layer sets (dotted).
//! - `theme.density_blocked` `{managed}` answers `{blocked}`: a managed layer
//!   sets `appearance.density` or `appearance.customDensity`.
//!
//! Pane toolbar buttons and sidebar surface are `fields.*` ops (not here).

use std::collections::BTreeSet;

use serde_json::{Map, Value, json};

use super::OpError;
use crate::keypath::key_path;
use crate::schema::{Kind, Schema};
use crate::value::{value_at, with_value};

const DENSITY_ROWS: [&str; 2] = ["appearance.density", "appearance.customDensity"];

pub fn call(op: &str, request: &Value) -> Option<Result<Value, OpError>> {
    Some(match op {
        "chrome_placement.parse" => parse(request),
        "theme.applied" => applied(request),
        "theme.density_blocked" => density_blocked(request),
        _ => return None,
    })
}

/// A Double as Swift prints it in a message (`0.0`, `2.0`, `0.65`).
fn swift_double(number: f64) -> String {
    format!("{number:?}")
}

fn invalid(path: &str, message: String) -> Value {
    json!({ "kind": "invalidValue", "path": path, "message": message })
}

/// A choice row's values and default. `appearance.gooeyTabs` is in the schema
/// source (#54349) but not in the checked-in `settings-schema.json` the crate
/// embeds, so its three choices are listed here until that file carries it.
fn choices_of(key: &str) -> (Vec<String>, Option<Value>, Vec<String>) {
    let schema = Schema::embedded();
    match schema.row(key) {
        Some(row) => {
            let Kind::Choice(choices) = &row.kind else {
                return (Vec::new(), None, row.path.clone());
            };
            (
                choices.iter().map(|c| c.value.clone()).collect(),
                row.default.clone(),
                row.path.clone(),
            )
        }
        None if key == "appearance.gooeyTabs" => (
            ["off", "subtle", "full"].map(str::to_owned).to_vec(),
            Some(json!("off")),
            key_path(key),
        ),
        None => (Vec::new(), None, key_path(key)),
    }
}

/// A choice row's value: the choice, else the default (`None` for a bad or
/// missing value when `fallback` is false) plus a diagnostic for a bad one.
fn choice(
    root: &Value,
    key: &str,
    fallback: bool,
    out: &mut Map<String, Value>,
    notes: &mut Vec<Value>,
) {
    let (choices, default, path) = choices_of(key);
    let default = if fallback { default } else { None };
    let Some(value) = value_at(root, &path) else {
        if let Some(default) = default {
            out.insert(key.to_owned(), default);
        }
        return;
    };
    if let Some(text) = value.as_str().filter(|text| choices.iter().any(|c| c == text)) {
        out.insert(key.to_owned(), json!(text));
        return;
    }
    let listed: Vec<String> = choices.iter().map(|c| format!("\"{c}\"")).collect();
    notes.push(invalid(key, format!("expected one of {}", listed.join(", "))));
    if let Some(default) = default {
        out.insert(key.to_owned(), default);
    }
}

fn contrast(root: &Value, out: &mut Map<String, Value>, notes: &mut Vec<Value>) {
    let key = "appearance.titleAreaContrast";
    let Some(row) = Schema::embedded().row(key) else { return };
    let Kind::Number(range) = &row.kind else { return };
    let fallback = row.default.clone().unwrap_or(json!(1.0));
    let Some(value) = value_at(root, &row.path) else {
        out.insert(key.to_owned(), fallback);
        return;
    };
    let expected = format!(
        "expected a number from {} to {}",
        swift_double(range.min),
        swift_double(range.max)
    );
    let Some(number) = value.as_f64().filter(|number| number.is_finite()) else {
        notes.push(invalid(key, expected));
        out.insert(key.to_owned(), fallback);
        return;
    };
    if !(range.min..=range.max).contains(&number) {
        notes.push(invalid(key, format!("{expected}; clamped")));
    }
    out.insert(key.to_owned(), json!(number.clamp(range.min, range.max)));
}

fn parse(request: &Value) -> Result<Value, OpError> {
    let root = request.get("root").ok_or_else(|| OpError::Invalid("expected `root`".to_owned()))?;
    let mut values = Map::new();
    let mut notes = Vec::new();
    // Swift's order: contrast, tone, corner flush, tab shape, gooey tabs.
    contrast(root, &mut values, &mut notes);
    choice(root, "appearance.titleAreaTone", true, &mut values, &mut notes);
    choice(root, "appearance.cornerFlush", false, &mut values, &mut notes);
    choice(root, "appearance.tabShape", true, &mut values, &mut notes);
    choice(root, "appearance.gooeyTabs", true, &mut values, &mut notes);
    Ok(json!({ "values": values, "diagnostics": notes }))
}

fn managed_keys(request: &Value) -> BTreeSet<String> {
    request
        .get("managed")
        .and_then(Value::as_array)
        .map(|keys| keys.iter().filter_map(Value::as_str).map(str::to_owned).collect())
        .unwrap_or_default()
}

fn applied(request: &Value) -> Result<Value, OpError> {
    let root = request.get("root").ok_or_else(|| OpError::Invalid("expected `root`".to_owned()))?;
    let values = request
        .get("values")
        .and_then(Value::as_array)
        .ok_or_else(|| OpError::Invalid("expected `values` of {path, value}".to_owned()))?;
    let managed = managed_keys(request);
    let mut out = root.clone();
    for entry in values {
        let path: Vec<String> = entry
            .get("path")
            .and_then(Value::as_array)
            .map(|parts| parts.iter().filter_map(Value::as_str).map(str::to_owned).collect())
            .ok_or_else(|| OpError::Invalid("expected a `path` list".to_owned()))?;
        let value = entry
            .get("value")
            .cloned()
            .ok_or_else(|| OpError::Invalid("expected a `value`".to_owned()))?;
        let id = path.join(".");
        let is_managed = managed.iter().any(|key| {
            *key == id || id.starts_with(&format!("{key}.")) || key.starts_with(&format!("{id}."))
        });
        if !is_managed {
            out = with_value(&out, value, &path);
        }
    }
    Ok(json!({ "root": out }))
}

fn density_blocked(request: &Value) -> Result<Value, OpError> {
    let managed = managed_keys(request);
    let blocked = managed.iter().any(|key| {
        DENSITY_ROWS.iter().any(|row| *row == key || row.starts_with(&format!("{key}.")))
    });
    Ok(json!({ "blocked": blocked }))
}

#[cfg(test)]
#[path = "chrome_theme_tests.rs"]
mod tests;

//! The app menu's Customizations submenu (Swift
//! `SettingsSchema.quickToggleGroups`; Leo 2026-11-22, ask-931361017e: "some
//! sort of checklist to be able to toggle through customizations", "as few
//! clicks as reasonable"), as an op. The app keeps the menu and the guarded
//! flip; which switches it lists is decided here, from the schema.
//!
//! - `quick_toggles.groups` `{developer_tools?}` answers `{groups: [{title:
//!   {key, text}, rows: [dotted]}]}`: Experiments (every `experiments.*`
//!   switch), then Labs (every `labs.*` switch and every other switch of the
//!   Labs group, such as `customize.fromTheApp`), in schema order. Only on/off
//!   rows the palette lists in this build, so a new schema row shows up with
//!   no other edit; an empty group is left out.

use std::sync::OnceLock;

use serde_json::{Value, json};

use super::OpError;
use crate::schema::{Kind, Row, Schema};

const EXPERIMENTS: (&str, &str) = ("settings.group.experiments", "Experiments");
const LABS: (&str, &str) = ("settings.group.labs", "Labs");
/// Settings > Development: only in a build with developer tools.
const DEVELOPMENT_SECTION: &str = "development";

/// The ops this area answers; `None` for an op of another area.
pub fn call(op: &str, request: &Value) -> Option<Result<Value, OpError>> {
    Some(match op {
        "quick_toggles.groups" => {
            let developer_tools =
                request.get("developer_tools").and_then(Value::as_bool).unwrap_or(false);
            Ok(json!({ "groups": groups_cached(developer_tools) }))
        }
        _ => return None,
    })
}

/// The palette lists `row` in a build with (`developer_tools`, DEV and
/// NIGHTLY) or without developer tools (Swift `isPaletteListed`): the export's
/// palette surface offers it, and Settings > Development exists only with
/// them.
pub fn is_palette_listed(row: &Row, developer_tools: bool) -> bool {
    (developer_tools || row.section != DEVELOPMENT_SECTION)
        && row.raw().pointer("/surfaces/palette/offered").and_then(Value::as_bool).unwrap_or(false)
}

/// The groups of `schema`'s switches, as `quick_toggles.groups` answers them.
pub fn groups(schema: &Schema, developer_tools: bool) -> Vec<Value> {
    let mut experiments = Vec::new();
    let mut labs = Vec::new();
    for row in &schema.rows {
        let head = row.path.first().map(String::as_str);
        let in_experiments = head == Some("experiments");
        let in_labs =
            !in_experiments && (head == Some("labs") || row.group.key.as_deref() == Some(LABS.0));
        // The cheap checks first: the palette surface is read from the row's exported text.
        if !(in_experiments || in_labs)
            || !matches!(row.kind, Kind::Toggle)
            || !is_palette_listed(row, developer_tools)
        {
            continue;
        }
        if in_experiments { &mut experiments } else { &mut labs }.push(row.key.clone());
    }
    [(EXPERIMENTS, experiments), (LABS, labs)]
        .into_iter()
        .filter(|(_, rows)| !rows.is_empty())
        .map(|((key, text), rows)| json!({ "title": { "key": key, "text": text }, "rows": rows }))
        .collect()
}

/// The embedded schema's groups, read once per build kind: the menu asks on
/// every open.
fn groups_cached(developer_tools: bool) -> Value {
    static WITH_DEVELOPER_TOOLS: OnceLock<Value> = OnceLock::new();
    static WITHOUT_DEVELOPER_TOOLS: OnceLock<Value> = OnceLock::new();
    let cache = if developer_tools { &WITH_DEVELOPER_TOOLS } else { &WITHOUT_DEVELOPER_TOOLS };
    cache.get_or_init(|| Value::Array(groups(Schema::embedded(), developer_tools))).clone()
}

#[cfg(test)]
mod tests;

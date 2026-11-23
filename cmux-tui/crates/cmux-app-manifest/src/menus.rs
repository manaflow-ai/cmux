//! `contributes.menus`: rows an app adds to cmux's own right-click menus
//! (a sidebar workspace row, a tab, a terminal). Each row runs one of the
//! app's own catalog ops through `apps-run`, with the right-clicked object
//! as `args.target`. The shell lists them after its built-in rows, in one
//! group per menu, so an app never reorders or hides a built-in row.

use crate::issue::Issue;
use serde_json::Value;
use std::collections::HashSet;

/// The menus an app can add rows to (the schema's `menuItem.target` enum;
/// a test keeps the two equal). Chat-area menus are not offered.
pub const MENU_TARGETS: &[&str] = &["workspace", "tab", "terminal"];

fn rows(m: &Value) -> impl Iterator<Item = (usize, &Value)> {
    m.pointer("/contributes/menus").and_then(Value::as_array).into_iter().flatten().enumerate()
}

pub(crate) fn check(m: &Value, out: &mut Vec<Issue>) {
    let mut ids = HashSet::new();
    for (i, row) in rows(m) {
        let at = format!("/contributes/menus/{i}");
        let id = row["id"].as_str().unwrap_or_default();
        if !ids.insert(id) {
            out.push(Issue::error(
                format!("{at}/id"),
                "menus.duplicate",
                format!("{id} is declared twice"),
            ));
        }
    }
}

/// A menu row runs an op of the app's own catalog (`validate_package`):
/// `apps-run` runs nothing else.
pub(crate) fn check_ops(m: &Value, catalog: &Value, out: &mut Vec<Issue>) {
    let family = catalog["family"].as_str().unwrap_or_default();
    let names: HashSet<&str> = catalog["operations"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|o| o["name"].as_str())
        .collect();
    for (i, row) in rows(m) {
        let at = format!("/contributes/menus/{i}/op");
        let op = row["op"].as_str().unwrap_or_default();
        if !op.starts_with(&format!("{family}.")) {
            out.push(Issue::error(
                at,
                "menus.foreignOp",
                format!("{op} is not an op of the app's own family {family}"),
            ));
        } else if !names.contains(op) {
            out.push(Issue::error(
                at,
                "menus.unknownOp",
                format!("{op} is not in the app's catalog"),
            ));
        }
    }
}

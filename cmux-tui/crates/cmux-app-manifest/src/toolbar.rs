//! `contributes.toolbarItems` (titlebar-area.md 3, app-platform.md 17):
//! buttons, menu buttons and small app views in the top-left toolbar band.
//! App items always follow the built-in items, so none sits left of the
//! sidebar toggle; the toggle cannot be removed or overridden.

use crate::issue::Issue;
use serde_json::Value;
use std::collections::HashSet;

/// Built-in toolbar items an app can offer an alternative for (the user
/// picks it in Settings). The sidebar toggle is fixed.
pub const OVERRIDABLE_TOOLBAR_ITEMS: &[&str] = &["nav.back", "nav.forward"];
/// The sidebar toggle: fixed frame, never removed or overridden (R68).
pub const SIDEBAR_TOGGLE_ITEM: &str = "sidebar.toggle";
/// App items the shell shows before the overflow menu.
pub const TOOLBAR_VISIBLE_APP_ITEMS: usize = 3;

pub(crate) fn check(m: &Value, out: &mut Vec<Issue>) {
    let mut ids = HashSet::new();
    for (i, item) in m
        .pointer("/contributes/toolbarItems")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .enumerate()
    {
        let at = format!("/contributes/toolbarItems/{i}");
        let id = item["id"].as_str().unwrap_or_default();
        if !ids.insert(id) {
            out.push(Issue::error(
                format!("{at}/id"),
                "toolbar.duplicate",
                format!("{id} is declared twice"),
            ));
        }
        if item["kind"] == "view" && m.pointer("/runtime/web").is_none() {
            out.push(Issue::error(
                format!("{at}/kind"),
                "toolbar.viewNeedsWeb",
                "a toolbar view is rendered by the app's page: declare runtime.web",
            ));
        }
        let Some(target) = item["overrides"].as_str() else { continue };
        let at = format!("{at}/overrides");
        if target == SIDEBAR_TOGGLE_ITEM {
            out.push(Issue::error(
                at,
                "toolbar.toggleFixed",
                "the sidebar toggle cannot be overridden",
            ));
        } else if !OVERRIDABLE_TOOLBAR_ITEMS.contains(&target) {
            out.push(Issue::error(
                at,
                "toolbar.overrideUnknown",
                format!("{target} is not a built-in toolbar item"),
            ));
        } else if item["kind"] != "button" {
            out.push(Issue::error(
                at,
                "toolbar.overrideKind",
                "only a button can be an alternative for a built-in item",
            ));
        }
    }
}

/// Toolbar actions that name an op of the app's own catalog family must
/// exist in the fragment (`validate_package`).
pub(crate) fn check_ops(m: &Value, catalog: &Value, out: &mut Vec<Issue>) {
    let family = catalog["family"].as_str().unwrap_or_default();
    let names: HashSet<&str> = catalog["operations"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|o| o["name"].as_str())
        .collect();
    for (i, item) in m
        .pointer("/contributes/toolbarItems")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .enumerate()
    {
        let actions = item
            .get("action")
            .into_iter()
            .map(|a| (format!("/contributes/toolbarItems/{i}/action/op"), a))
            .chain(item["items"].as_array().into_iter().flatten().enumerate().map(
                move |(j, entry)| {
                    (format!("/contributes/toolbarItems/{i}/items/{j}/action/op"), &entry["action"])
                },
            ));
        for (at, action) in actions {
            let op = action["op"].as_str().unwrap_or_default();
            if op.split('.').next() == Some(family) && !names.contains(op) {
                out.push(Issue::error(
                    at,
                    "toolbar.unknownOp",
                    format!("{op} is not in the app's catalog"),
                ));
            }
        }
    }
}

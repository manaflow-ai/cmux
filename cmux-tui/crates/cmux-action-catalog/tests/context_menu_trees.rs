//! The right-click menus Rust builds (`context_menus::menus`) are the ones the app's Swift catalog
//! built: `plans/cmux-next/action-surfaces.json` `context_menus` is the Swift catalog's export
//! (`ContextMenuCatalog.exportObject`), row for row, so this compares the old table with the new
//! one before the Swift copy goes.

use cmux_action_catalog::context_menus::{self, Entry};
use serde_json::{Value, json};
use std::path::Path;

fn surfaces() -> Value {
    // affected-reads: plans/cmux-next/action-surfaces.json
    let path =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../plans/cmux-next/action-surfaces.json");
    serde_json::from_str(&std::fs::read_to_string(&path).expect("action-surfaces.json"))
        .expect("json")
}

/// The export's rows reduced to their shape: kind, id or folder, children.
fn exported(rows: &Value) -> Vec<Value> {
    rows.as_array()
        .expect("entries")
        .iter()
        .map(|row| match row["kind"].as_str().expect("kind") {
            "separator" => json!("-"),
            "action" => json!({ "action": row["id"] }),
            "choices" => json!({ "choices": row["id"] }),
            "submenu" => json!({ "submenu": row["id"], "children": exported(&row["children"]) }),
            "folder" => json!({ "folder": row["folder"], "children": exported(&row["children"]) }),
            other => panic!("unexpected kind {other}"),
        })
        .collect()
}

const MARKERS: &str = "tests/awaiting-repin";

fn marked(list: &str) -> Vec<String> {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join(MARKERS).join(list);
    std::fs::read_dir(&dir)
        .map(|entries| entries.filter_map(|e| e.ok()?.file_name().into_string().ok()).collect())
        .unwrap_or_default()
}

/// The rows the pinned app FFI (which wrote the export) does not place as this crate does yet:
/// actions it lacks or still has, and actions whose `/surfacePlan/contextMenus` changed. Both
/// sides leave them out; the re-pin deletes their markers.
fn awaiting_repin() -> Vec<String> {
    let mut ids = marked("actions");
    ids.extend(marked("removal"));
    let fields = Path::new(env!("CARGO_MANIFEST_DIR")).join(MARKERS).join("fields");
    for id in marked("fields") {
        let text = std::fs::read_to_string(fields.join(&id)).unwrap_or_default();
        if text.lines().any(|line| line.trim_start().starts_with("/surfacePlan/contextMenus")) {
            ids.push(id);
        }
    }
    ids
}

/// `rows` without the `hidden` ids, a folder or submenu left with no row dropped, and one
/// separator between sections with none at the ends.
fn without(rows: &[Value], hidden: &[String]) -> Vec<Value> {
    let mut result: Vec<Value> = Vec::new();
    for row in rows {
        if row == "-" {
            if result.last().is_some_and(|last| last != "-") {
                result.push(row.clone());
            }
            continue;
        }
        let id = ["action", "choices", "submenu"].iter().find_map(|k| row[*k].as_str());
        if id.is_some_and(|id| hidden.iter().any(|h| h == id)) {
            continue;
        }
        let mut row = row.clone();
        if let Some(children) = row.get("children").and_then(Value::as_array) {
            let kept = without(children, hidden);
            if row.get("folder").is_some() && kept.is_empty() {
                continue;
            }
            row["children"] = Value::Array(kept);
        }
        result.push(row);
    }
    while result.last().is_some_and(|last| last == "-") {
        result.pop();
    }
    result
}

fn export_name(context: &str) -> &str {
    if context == "profile" { "space" } else { context }
}

#[test]
fn rust_menus_match_the_swift_export() {
    let surfaces = surfaces();
    let swift = surfaces["context_menus"].as_object().expect("context_menus");
    let menus = context_menus::menus();
    let hidden = awaiting_repin();
    let mut rust_names = Vec::new();
    for menu in &menus {
        if menu.entries.is_empty() {
            continue;
        }
        let name = export_name(menu.context);
        rust_names.push(name.to_owned());
        let old = without(
            &exported(
                &swift.get(name).unwrap_or_else(|| panic!("{name} missing from the Swift export"))
                    ["entries"],
            ),
            &hidden,
        );
        let new = without(&context_menus::entries_json(&menu.entries), &hidden);
        assert_eq!(new, old, "menu {name} differs from the Swift export");
    }
    let mut swift_names: Vec<String> = swift.keys().cloned().collect();
    rust_names.sort();
    swift_names.sort();
    assert_eq!(rust_names, swift_names);
}

/// The several-rows workspace menu (ContextMenuEssentials.selectionMenus), as the Swift catalog
/// built it at 0dd535e42f5 (ContextMenuShapeTests pins the same rows).
#[test]
fn workspace_selection_menu_keeps_its_rows() {
    let menu = context_menus::menus()
        .into_iter()
        .find(|m| m.context == "workspaceRow")
        .expect("workspaceRow");
    let selection = menu.selection.expect("selection menu");
    let ids = context_menus::referenced_ids(&selection);
    for id in [
        "palette.workspaceColor",
        "workspace.newBelow",
        "groupSelectedWorkspaces",
        "workspace.duplicate",
        "palette.toggleWorkspacePin",
        "workspace.toggleArchive",
        "closeWorkspace",
        "palette.closeOtherWorkspaces",
        "palette.closeWorkspacesBelow",
        "reopenClosedWorkspace",
    ] {
        assert!(ids.contains(&id), "{id} missing from the selection menu: {selection:?}");
    }
    assert_eq!(selection.last(), Some(&Entry::Action("reopenClosedWorkspace")));
}

/// A debug-build-only action places itself in no menu, so Release and Debug builds share one tree.
#[test]
fn debug_only_actions_have_no_placement() {
    for action in cmux_action_catalog::actions() {
        if action.is_debug_only {
            assert!(
                action.surface_plan.context_menus.is_empty(),
                "{} is debug-only with a placement",
                action.id
            );
        }
    }
}

#[test]
fn catalog_json_carries_the_trees() {
    let catalog: Value =
        serde_json::from_str(&cmux_action_catalog::json::catalog(0)).expect("catalog");
    assert!(catalog["context_menu_trees"]["workspaceRow"]["selection"].is_array());
    assert_eq!(
        catalog["context_menu_choice_trailers"]["moveWorkspaceToGroup"],
        "workspace.moveToNewGroup"
    );
}

/// The key tiers the app's `ActionKeyTier.defaultTier` gave at 0dd535e42f5, for a sample of each
/// rule: listed system and navigation ids, a content id with no focus fact, a content focus fact.
#[test]
fn key_tiers_keep_their_defaults() {
    use cmux_action_catalog::key_tiers::default_tier;
    let tier = |id: &str| default_tier(cmux_action_catalog::find(id).expect(id));
    assert_eq!(tier("quit"), "system");
    assert_eq!(tier("commandPalette"), "system");
    assert_eq!(tier("focusBrowserAddressBar"), "navigation");
    assert_eq!(tier("toggleBrowserDeveloperTools"), "content");
    for action in cmux_action_catalog::actions() {
        if action.requires.contains(&"terminalFocused")
            && !cmux_action_catalog::key_tiers::SYSTEM_ACTIONS.contains(&action.id)
            && !cmux_action_catalog::key_tiers::NAVIGATION_ACTIONS.contains(&action.id)
        {
            assert_eq!(default_tier(action), "content", "{}", action.id);
        }
    }
}

/// The catalog's hand-built menu list is the export's `context_menus_not_exported`, in order.
#[test]
fn hand_built_menus_match_the_export() {
    let catalog: Value =
        serde_json::from_str(&cmux_action_catalog::json::catalog(0)).expect("catalog");
    assert_eq!(catalog["hand_built_menus"], surfaces()["context_menus_not_exported"]);
}

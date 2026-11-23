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

fn export_name(context: &str) -> &str {
    if context == "profile" { "space" } else { context }
}

#[test]
fn rust_menus_match_the_swift_export() {
    let surfaces = surfaces();
    let swift = surfaces["context_menus"].as_object().expect("context_menus");
    let menus = context_menus::menus();
    let mut rust_names = Vec::new();
    for menu in &menus {
        if menu.entries.is_empty() {
            continue;
        }
        let name = export_name(menu.context);
        rust_names.push(name.to_owned());
        let old = exported(
            &swift.get(name).unwrap_or_else(|| panic!("{name} missing from the Swift export"))["entries"],
        );
        let new = context_menus::entries_json(&menu.entries);
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

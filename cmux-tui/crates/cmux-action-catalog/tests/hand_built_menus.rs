//! Every row of a hand-built menu is a command palette row (cmux#51026). Leo, 2026-11-08
//! (cmuxterm-hq goals/palette-all-actions.md): every CLI and menu action has a palette entry.
//!
//! - Each row of [`hand_built_menus::MENUS`] names a registered action the palette offers (or a
//!   family's member, whose family row stands in), each context is a registry right-click menu.
//! - The menus are the ones the app exports as `context_menus_not_exported`, from the same source
//!   files: a new hand-built menu fails here until its rows are listed.
//! - `scripts/cmux-next/palette-coverage.py` reads the same `MENUS` list from the source file, so
//!   no generated copy is committed.

use cmux_action_catalog::hand_built_menus::{self, HandBuiltMenu, MENUS};
use cmux_action_catalog::{Decision, find};
use serde_json::Value;
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

const SURFACES: &str = "plans/cmux-next/action-surfaces.json";
/// Palette exemptions whose own row stands in for the action (palette-coverage.py's FAMILY).
const STANDS_IN: &[&str] = &["familyMember", "duplicateOfDefault", "secondaryEngine"];

fn repo() -> PathBuf {
    // affected-reads: plans/cmux-next/action-surfaces.json Packages/macOS/CmuxNext/Sources
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..")
}

fn read_json(path: &str) -> Value {
    let text = std::fs::read_to_string(repo().join(path)).unwrap_or_else(|e| panic!("{path}: {e}"));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("{path}: {e}"))
}

/// Why `id` is no palette row a hand-built menu row may name, or None when it is one.
fn not_a_palette_row(id: &str) -> Option<String> {
    let Some(action) = find(id) else { return Some(format!("{id} is no registered action")) };
    if action.id != id {
        return Some(format!("{id} is a legacy alias: name {}", action.id));
    }
    match action.surface_plan.palette {
        Decision::Offered => None,
        Decision::Exempt(reason) if STANDS_IN.contains(&reason) => None,
        Decision::Exempt(reason) => Some(format!("{id} is not in the palette ({reason})")),
    }
}

fn problems(menus: &[HandBuiltMenu], contexts: &BTreeSet<String>) -> Vec<String> {
    let mut out = Vec::new();
    let mut names = BTreeSet::new();
    for menu in menus {
        if !names.insert(menu.name) {
            out.push(format!("{}: listed twice", menu.name));
        }
        if menu.rows.is_empty() && menu.contexts.is_empty() && menu.pointer_rows.is_none() {
            out.push(format!("{}: no rows, no registry menu and no pointer rows", menu.name));
        }
        let mut seen = BTreeSet::new();
        for row in menu.rows {
            if !seen.insert(*row) {
                out.push(format!("{}: row {row} listed twice", menu.name));
            }
            if let Some(why) = not_a_palette_row(row) {
                out.push(format!("{}: {why}", menu.name));
            }
        }
        for context in menu.contexts {
            if !contexts.contains(*context) {
                out.push(format!("{}: {context} is no registry right-click menu", menu.name));
            }
        }
        if menu.pointer_rows.is_some_and(|why| why.trim().is_empty()) {
            out.push(format!("{}: pointer_rows says nothing", menu.name));
        }
    }
    out
}

/// The registry right-click menus: every placement's context, as the export names them.
fn registry_contexts() -> BTreeSet<String> {
    let surfaces = read_json(SURFACES);
    surfaces["context_menus"].as_object().expect("context_menus").keys().cloned().collect()
}

#[test]
fn every_row_of_a_hand_built_menu_is_a_palette_row() {
    let found = problems(MENUS, &registry_contexts());
    assert!(found.is_empty(), "hand_built_menus.rs:\n  {}", found.join("\n  "));
}

#[test]
fn a_row_naming_no_registered_action_fails() {
    let contexts: BTreeSet<String> = ["browserPage".to_owned()].into();
    let unknown = HandBuiltMenu {
        name: "m",
        source: "M.swift",
        rows: &["no.such.action"],
        contexts: &[],
        pointer_rows: None,
    };
    assert_eq!(problems(&[unknown], &contexts), ["m: no.such.action is no registered action"]);
    let off_palette = HandBuiltMenu {
        rows: &["browserZoomIn", "browserZoomIn"],
        contexts: &["nowhere"],
        ..unknown
    };
    assert_eq!(
        problems(&[off_palette], &contexts),
        ["m: row browserZoomIn listed twice", "m: nowhere is no registry right-click menu"]
    );
    let good = HandBuiltMenu { rows: &["browserReload"], contexts: &["browserPage"], ..unknown };
    assert!(problems(&[good], &contexts).is_empty());
}

#[test]
fn the_app_exports_the_same_hand_built_menus() {
    let surfaces = read_json(SURFACES);
    let exported: Vec<(String, String)> = surfaces["context_menus_not_exported"]
        .as_array()
        .expect("context_menus_not_exported")
        .iter()
        .map(|m| {
            (
                m["name"].as_str().unwrap_or("").to_owned(),
                m["source"].as_str().unwrap_or("").to_owned(),
            )
        })
        .collect();
    let listed: Vec<(String, String)> =
        MENUS.iter().map(|m| (m.name.to_owned(), m.source.to_owned())).collect();
    assert_eq!(
        listed, exported,
        "hand_built_menus::MENUS must list the app's context_menus_not_exported (ContextMenuCatalog.exportHandBuiltMenus), in order, with the same sources"
    );
    for menu in MENUS {
        let path = repo().join("Packages/macOS/CmuxNext/Sources").join(menu.source);
        assert!(path.is_file(), "{}: {} is not a file", menu.name, menu.source);
        assert!(hand_built_menus::find(menu.name) == Some(menu));
    }
}

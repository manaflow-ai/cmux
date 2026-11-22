//! Sidebar looks: every shipped look is public settings on the shared grid,
//! fills only unset keys, and the default draws cmux's own sidebar.

use std::path::Path;

use serde_json::{Value, json};

use super::*;
use crate::keypath::key_path;
use crate::schema::Kind;

fn schema() -> &'static Schema {
    Schema::embedded()
}

fn at<'a>(root: &'a Value, dotted: &str) -> Option<&'a Value> {
    value_at(root, &key_path(dotted))
}

#[test]
fn every_shipped_look_is_public_grid_settings_and_reads_whole() {
    for name in LOOKS.iter().filter(|name| **name != DEFAULT) {
        let look = SidebarLook::shipped(name, schema(), &Domains::default())
            .unwrap_or_else(|| panic!("{name} has a file"));
        assert!(look.problems.is_empty(), "{name}: {:?}", look.problems);
        assert!(!look.values.is_empty(), "{name} sets something");
        for (path, _) in &look.values {
            let key = dotted(path);
            assert!(GRID_KEYS.contains(&key.as_str()), "{name}: {key} is off the grid");
            assert!(schema().row(&key).is_some(), "{name}: {key} is a public setting");
        }
    }
}

#[test]
fn the_shipped_files_are_the_ones_in_resources() {
    let folder = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../Resources").join(FOLDER_NAME);
    let mut on_disk: Vec<String> = std::fs::read_dir(&folder)
        .expect("Resources/sidebar-looks")
        .flatten()
        .filter_map(|entry| entry.path().file_stem().and_then(|s| s.to_str()).map(str::to_string))
        .collect();
    on_disk.sort();
    let mut shipped: Vec<String> = SHIPPED.iter().map(|(name, _)| (*name).to_string()).collect();
    shipped.sort();
    assert_eq!(on_disk, shipped);
    let mut looks: Vec<String> =
        LOOKS.iter().filter(|n| **n != DEFAULT).map(|n| (*n).to_string()).collect();
    looks.sort();
    assert_eq!(looks, shipped, "every look but cmux has a file");
}

#[test]
fn the_setting_offers_every_look_and_defaults_to_cmux() {
    let row = schema().row(SETTING_KEY).expect("sidebar.look is a setting");
    assert_eq!(row.default, Some(json!(DEFAULT)));
    let Kind::Choice(choices) = &row.kind else { panic!("sidebar.look is a choice") };
    let values: Vec<&str> = choices.iter().map(|choice| choice.value.as_str()).collect();
    assert_eq!(values, LOOKS.to_vec());
}

#[test]
fn the_default_look_fills_nothing() {
    let root = json!({"sidebar": {"look": "cmux"}});
    assert_eq!(filled(&root, schema(), &Domains::default()), root);
    let unset = json!({"sidebar": {"density": "compact"}});
    assert_eq!(filled(&unset, schema(), &Domains::default()), unset);
    let unknown = json!({"sidebar": {"look": "nope"}});
    assert_eq!(filled(&unknown, schema(), &Domains::default()), unknown);
}

#[test]
fn a_look_fills_only_what_the_person_leaves_unset() {
    let root = json!({"sidebar": {"look": "studio", "groupBy": "none", "showTimestamps": false}});
    let out = filled(&root, schema(), &Domains::default());
    assert_eq!(at(&out, "sidebar.groupBy"), Some(&json!("none")), "the person's grouping wins");
    assert_eq!(at(&out, "sidebar.showTimestamps"), Some(&json!(false)), "the person's off wins");
    assert_eq!(
        at(&out, "sidebar.detailedStatusIcons"),
        Some(&json!(true)),
        "the look fills the rest"
    );
    assert_eq!(at(&out, "sidebar.look"), Some(&json!("studio")));
}

#[test]
fn a_look_never_sets_row_height_width_or_motion() {
    // The keys that move the pane or a row: none may be on the grid list.
    for key in [
        "sidebar.density",
        "sidebar.textSize",
        "sidebar.style",
        "sidebar.side",
        "sidebar.minimal",
        "sidebar.workspacesAsTabs",
        "appearance.density",
        "appearance.metrics.sidebarWidth",
        "appearance.metrics.sidebarRowHeight",
        "appearance.metrics.titlebarHeight",
        "appearance.metrics.tabStripHeight",
        "appearance.statusIndicator.animation",
        "ui.animation",
        "sidebar.workspaceRow.branch",
        "sidebar.workspaceRow.directory",
        "sidebar.workspaceRow.lastActivity",
    ] {
        assert!(!GRID_KEYS.contains(&key), "{key} changes the grid");
    }
    let look = SidebarLook::read(
        "mine",
        r#"{"sidebar.density": "expanded", "appearance.metrics.sidebarWidth": 400, "sidebar.groupBy": "folder"}"#,
        schema(),
        &Domains::default(),
    );
    assert_eq!(look.values.len(), 1, "only the grid key applies: {:?}", look.values);
    assert_eq!(look.problems.len(), 2, "{:?}", look.problems);
}

#[test]
fn a_look_reads_nested_or_dotted_and_drops_refused_values() {
    let look = SidebarLook::read(
        "mine",
        r#"// a look
        { "name": "Mine", "sidebar": { "groupBy": "folder" }, "sidebar.showTimestamps": "yes", "nope.key": 1 }"#,
        schema(),
        &Domains::default(),
    );
    assert_eq!(look.values, vec![(key_path("sidebar.groupBy"), json!("folder"))]);
    assert_eq!(look.problems.len(), 2, "{:?}", look.problems);
}

#[test]
fn switching_looks_back_and_forth_returns_the_same_settings() {
    let base = json!({"sidebar": {"density": "comfortable"}});
    let with = |look: &str| {
        let mut root = base.clone();
        root = with_value(&root, json!(look), &key_path(SETTING_KEY));
        filled(&root, schema(), &Domains::default())
    };
    let first = with("codex");
    for look in ["claude", "studio", "cmux", "codex"] {
        let _ = with(look);
    }
    assert_eq!(with("codex"), first, "a look is a pure function of the file");
    for look in LOOKS {
        assert_eq!(
            at(&with(look), "sidebar.density"),
            Some(&json!("comfortable")),
            "{look} keeps the density"
        );
    }
}

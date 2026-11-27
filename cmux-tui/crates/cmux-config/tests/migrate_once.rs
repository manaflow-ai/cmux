//! A key cmux renamed moves to its new name in the person's own file the
//! first time an owner opens it, and never again: the ledger
//! (`<state dir>/settings/migrations.json`) records each rename it ran.

use std::path::{Path, PathBuf};

use cmux_config::managed::FixedManagedReader;
use cmux_config::migrations::once::{Ledger, ledger_path};
use cmux_config::{ConfigStore, ManagedPreferences, Target};
use serde_json::{Value, json};

const OLD: &str = "sidebar.showCounts";
const NEW: &str = "sidebar.workspaceRow.tabCount";

struct Dirs(PathBuf);

impl Dirs {
    fn new(name: &str) -> Dirs {
        let root =
            std::env::temp_dir().join(format!("cmux-migrate-once-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("state")).unwrap();
        Dirs(root)
    }
    fn config(&self) -> PathBuf {
        self.0.join("cmux-next.json")
    }
    fn state(&self) -> PathBuf {
        self.0.join("state")
    }
    fn open(&self) -> ConfigStore {
        let reader = Box::new(FixedManagedReader(ManagedPreferences::default()));
        ConfigStore::open(self.config(), None, Some(self.state()), reader)
    }
    fn file(&self) -> Value {
        serde_json::from_str(&std::fs::read_to_string(self.config()).unwrap()).unwrap()
    }
}

impl Drop for Dirs {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn at<'a>(root: &'a Value, dotted: &str) -> Option<&'a Value> {
    dotted.split('.').try_fold(root, |value, key| value.get(key))
}

fn ledger(state: &Path) -> Ledger {
    Ledger::read(state)
}

#[test]
fn misplaced_debug_tunables_are_removed_only_from_the_shared_settings() {
    let dirs = Dirs::new("debug-tunables");
    std::fs::write(
        dirs.config(),
        r#"{
            "status": { "working": "shimmer" },
            "tunable": { "diagnostics": { "focusLog": true, "foucusLog": false } },
            // Keep my language
            "app": { "language": "en" },
        }"#,
    )
    .unwrap();
    let support = dirs.0.join("Library/Application Support/cmux-next");
    let builds = [("builds/test-dev", "breathe", true), ("nightly", "spinner", false)];
    let mut originals = Vec::new();
    for (build, working, focus_log) in builds {
        let dir = support.join(build);
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("debug-tunables.json");
        let text = json!({
            "version": 1, "values": { "status.working": working, "diagnostics.focusLog": focus_log }
        })
        .to_string();
        std::fs::write(&file, &text).unwrap();
        originals.push((file, text));
    }

    // A per-build daemon gets its state directory beside its debug-tunables.json.
    let dev_state = support.join("builds/test-dev/tui");
    std::fs::create_dir(&dev_state).unwrap();
    drop(ConfigStore::open(
        dirs.config(),
        None,
        Some(dev_state),
        Box::new(FixedManagedReader::default()),
    ));
    let text = std::fs::read_to_string(dirs.config()).unwrap();
    let root = cmux_config::jsonc::parse(&text).unwrap();
    assert_eq!(at(&root, "status.working"), None);
    assert_eq!(at(&root, "tunable.diagnostics.focusLog"), None);
    assert_eq!(at(&root, "tunable.diagnostics.foucusLog"), Some(&json!(false)));
    assert!(text.contains("// Keep my language"));
    assert_eq!(at(&root, "app.language"), Some(&json!("en")));
    for (file, original) in originals {
        assert_eq!(std::fs::read_to_string(file).unwrap(), original);
    }
}

#[test]
fn a_renamed_key_moves_in_the_file_once_and_is_recorded() {
    let dirs = Dirs::new("moves");
    std::fs::write(
        dirs.config(),
        r#"{ "sidebar": { "showCounts": true }, "app": { "language": "en" } }"#,
    )
    .unwrap();

    let store = dirs.open();
    let file = dirs.file();
    assert_eq!(at(&file, NEW), Some(&json!(true)), "the value is under its new name");
    assert_eq!(at(&file, OLD), None, "the old key is gone");
    assert_eq!(at(&file, "app.language"), Some(&json!("en")), "the rest of the file is kept");
    let recorded = ledger(&dirs.state());
    assert!(recorded.applied["rename:sidebar.showCounts"].moved);
    assert!(ledger_path(&dirs.state()).is_file());
    assert_eq!(
        store.state().effective().root.pointer("/sidebar/workspaceRow/tabCount"),
        Some(&json!(true))
    );
    drop(store);

    // The person pastes the old spelling back: the owner reads it through the table,
    // and does not rewrite the file a second time.
    let pasted = r#"{ "sidebar": { "showCounts": false } }"#;
    std::fs::write(dirs.config(), pasted).unwrap();
    let store = dirs.open();
    assert_eq!(std::fs::read_to_string(dirs.config()).unwrap(), pasted);
    let row = store.state().get(&Target::Key(NEW.to_string())).row.expect("the row");
    assert_eq!(row.value, Some(json!(false)), "the row reads the old key through the table");
}

#[test]
fn a_rename_the_file_never_named_is_recorded_without_touching_the_file() {
    let dirs = Dirs::new("absent");
    let text = r#"{ "app": { "language": "en" } }"#;
    std::fs::write(dirs.config(), text).unwrap();
    drop(dirs.open());
    assert_eq!(std::fs::read_to_string(dirs.config()).unwrap(), text);
    let recorded = ledger(&dirs.state());
    assert!(!recorded.applied["rename:sidebar.showCounts"].moved);
    assert!(recorded.applied.len() >= 3, "every rename in the table is recorded");
}

#[test]
fn a_broken_file_records_nothing_so_the_next_open_tries_again() {
    let dirs = Dirs::new("broken");
    std::fs::write(dirs.config(), r#"{ "sidebar": { "showCounts": true "#).unwrap();
    drop(dirs.open());
    assert!(!ledger_path(&dirs.state()).exists());
    std::fs::write(dirs.config(), r#"{ "sidebar": { "showCounts": true } }"#).unwrap();
    drop(dirs.open());
    assert_eq!(at(&dirs.file(), NEW), Some(&json!(true)));
}

#[test]
fn a_new_key_already_set_wins_and_the_old_one_is_removed() {
    let dirs = Dirs::new("both");
    let text = r#"{ "sidebar": { "showCounts": true, "workspaceRow": { "tabCount": false } } }"#;
    std::fs::write(dirs.config(), text).unwrap();
    drop(dirs.open());
    assert_eq!(dirs.file(), json!({ "sidebar": { "workspaceRow": { "tabCount": false } } }));
    assert!(ledger(&dirs.state()).applied["rename:sidebar.showCounts"].moved);
}

#[test]
fn the_computer_use_opt_out_survives_a_rename() {
    let dirs = Dirs::new("computer-use");
    std::fs::write(dirs.config(), r#"{ "computerUse": { "enabled": false } }"#).unwrap();
    let store = dirs.open();
    assert_eq!(dirs.file(), json!({ "computerUse": { "mode": "off" } }));
    assert_eq!(at(&store.state().effective().root, "computerUse.mode"), Some(&json!("off")));
}

#[test]
fn dotted_removals_keep_dormant_renames_and_unrelated_siblings() {
    let dirs = Dirs::new("dotted");
    let old = json!({
        "remote.ultraMode": true,
        "tabs.terminalFirst": true,
        "tunable.diagnostics": { "focusLog": true, "other": false },
        "unrelated.key": 3
    });
    std::fs::write(dirs.config(), old.to_string()).unwrap();
    drop(dirs.open());
    assert_eq!(
        dirs.file(),
        json!({
            "remote.ultraMode": true,
            "tunable.diagnostics": { "other": false },
            "unrelated.key": 3
        })
    );
}

#[test]
fn a_rename_preserves_a_conflicting_parent() {
    let dirs = Dirs::new("conflicting-parent");
    let text = r#"{ "sidebar": { "workspaceRow": "unexpected", "showCounts": true } }"#;
    std::fs::write(dirs.config(), text).unwrap();
    drop(dirs.open());
    assert_eq!(std::fs::read_to_string(dirs.config()).unwrap(), text);
}

#[test]
fn an_inactive_dotted_mode_cannot_enable_computer_use_during_migration() {
    let dirs = Dirs::new("dotted-mode");
    let text = r#"{ "computerUse": { "enabled": false }, "computerUse.mode": "fullAccess" }"#;
    std::fs::write(dirs.config(), text).unwrap();
    let store = dirs.open();
    assert_eq!(std::fs::read_to_string(dirs.config()).unwrap(), text);
    let row = store.state().get(&Target::Key("computerUse.mode".to_owned())).row.unwrap();
    assert_eq!(row.value, Some(json!("off")));
}

#[test]
fn the_app_can_still_migrate_hidden_tab_buttons_to_pinned_buttons() {
    let dirs = Dirs::new("pane-buttons");
    let text = r#"{ "tabs": { "hiddenButtons": ["splitDown"] } }"#;
    std::fs::write(dirs.config(), text).unwrap();
    drop(dirs.open());
    assert_eq!(std::fs::read_to_string(dirs.config()).unwrap(), text);
}

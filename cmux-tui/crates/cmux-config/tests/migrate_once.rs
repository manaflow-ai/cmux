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
fn a_new_key_already_set_wins_and_the_old_one_is_left_to_the_table() {
    let dirs = Dirs::new("both");
    let text = r#"{ "sidebar": { "showCounts": true, "workspaceRow": { "tabCount": false } } }"#;
    std::fs::write(dirs.config(), text).unwrap();
    drop(dirs.open());
    assert_eq!(std::fs::read_to_string(dirs.config()).unwrap(), text);
    assert!(!ledger(&dirs.state()).applied["rename:sidebar.showCounts"].moved);
}

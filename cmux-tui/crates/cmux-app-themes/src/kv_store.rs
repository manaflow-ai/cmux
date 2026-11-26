//! The app-local JSON string maps (Swift `TerminalThemeStore` and
//! `WorkspaceBackgroundStore`: `terminal-themes.json`,
//! `workspace-backgrounds.json`, the appearance scopes): how a read file
//! classifies, how a load merges with values set before it, when a change
//! writes, and which entries a machine's tree prunes. The app reads, moves,
//! writes and removes the file.

use std::collections::{BTreeMap, BTreeSet};

use serde::Serialize;

/// What the app found at the store's path.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum File<'a> {
    /// No file.
    Missing,
    /// A file the app could not read.
    Unreadable,
    /// The file's bytes as UTF-8 (None: not UTF-8).
    Read(Option<&'a str>),
}

/// A read file, classified.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Classified {
    /// Its string entries.
    pub entries: BTreeMap<String, String>,
    /// False when the file is a JSON object some of whose entries are not
    /// strings (a newer format), or could not be read: it is kept unchanged.
    pub complete: bool,
    /// The file is no JSON object at all (a damaged write): move it aside to
    /// `<name>.corrupt` (`<name>.corrupt-<uuid>` when that exists, never over
    /// it). It reads as empty; when the move fails, also incomplete.
    pub move_aside: bool,
}

/// Classifies the file at the store's path.
pub fn classify(file: File<'_>) -> Classified {
    let empty =
        |complete, move_aside| Classified { entries: BTreeMap::new(), complete, move_aside };
    let text = match file {
        File::Missing => return empty(true, false),
        File::Unreadable => return empty(false, false),
        File::Read(text) => text,
    };
    let Some(serde_json::Value::Object(object)) =
        text.and_then(|text| serde_json::from_str(text).ok())
    else {
        return empty(true, true);
    };
    let entries: BTreeMap<String, String> = object
        .iter()
        .filter_map(|(key, value)| value.as_str().map(|value| (key.clone(), value.to_owned())))
        .collect();
    let complete = entries.len() == object.len();
    Classified { entries, complete, move_aside: false }
}

/// After a load: the loaded entries under the ones set before the load (those
/// win), and whether the file is kept as is (changes stay in memory).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Loaded {
    pub entries: BTreeMap<String, String>,
    pub keeps_file: bool,
}

pub fn load(
    loaded: BTreeMap<String, String>,
    current: BTreeMap<String, String>,
    complete: bool,
) -> Loaded {
    let mut entries = loaded;
    entries.extend(current);
    Loaded { entries, keeps_file: !complete }
}

/// What a change does to the file.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Save {
    /// Nothing: no file (memory only), or the file is kept.
    Skip,
    /// Wait for the load, then save, so a partial set never lands over the saved one.
    AfterLoad,
    /// Write the entries.
    Write,
    /// Remove the file (no entries).
    Remove,
}

pub fn save(has_file: bool, keeps_file: bool, is_loaded: bool, is_empty: bool) -> Save {
    if !has_file || keeps_file {
        Save::Skip
    } else if !is_loaded {
        Save::AfterLoad
    } else if is_empty {
        Save::Remove
    } else {
        Save::Write
    }
}

/// The entries the app may move into personal state: none from a kept file
/// (clearing its entries cannot reach the file, so every launch would migrate
/// them again, over newer picks).
pub fn migratable(
    entries: &BTreeMap<String, String>,
    keeps_file: bool,
) -> BTreeMap<String, String> {
    if keeps_file { BTreeMap::new() } else { entries.clone() }
}

/// `<machine>:<tab id>`, a terminal theme's key.
pub fn terminal_key(machine: &str, tab: &str) -> String {
    format!("{machine}:{tab}")
}

/// `<session>/<workspace id>`, a workspace background's key.
pub fn workspace_key(session: &str, workspace: &str) -> String {
    format!("{session}/{workspace}")
}

/// The keys of `machine`'s terminals that are not in `live_tabs`, in order.
pub fn stale_keys<'a>(
    keys: impl IntoIterator<Item = &'a str>,
    machine: &str,
    live_tabs: &BTreeSet<String>,
) -> Vec<String> {
    let prefix = format!("{machine}:");
    keys.into_iter()
        .filter(|key| key.strip_prefix(&prefix).is_some_and(|tab| !live_tabs.contains(tab)))
        .map(str::to_owned)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn map(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
        pairs.iter().map(|(key, value)| ((*key).to_owned(), (*value).to_owned())).collect()
    }

    #[test]
    fn a_missing_file_is_empty_and_complete() {
        assert_eq!(
            classify(File::Missing),
            Classified { entries: map(&[]), complete: true, move_aside: false }
        );
    }

    #[test]
    fn an_unreadable_file_is_kept() {
        assert_eq!(
            classify(File::Unreadable),
            Classified { entries: map(&[]), complete: false, move_aside: false }
        );
    }

    #[test]
    fn a_file_that_is_no_json_object_moves_aside() {
        for text in [Some("{"), Some("[1]"), Some("\"x\""), Some("3"), Some(""), None] {
            assert_eq!(
                classify(File::Read(text)),
                Classified { entries: map(&[]), complete: true, move_aside: true }
            );
        }
    }

    #[test]
    fn a_json_object_keeps_its_strings_and_is_incomplete_with_others() {
        assert_eq!(
            classify(File::Read(Some(r#"{"m:a":"Nord","m:b":"Dracula"}"#))),
            Classified {
                entries: map(&[("m:a", "Nord"), ("m:b", "Dracula")]),
                complete: true,
                move_aside: false
            }
        );
        assert_eq!(
            classify(File::Read(Some(r#"{"m:a":"Nord","m:b":{"v":2},"m:c":3}"#))),
            Classified { entries: map(&[("m:a", "Nord")]), complete: false, move_aside: false }
        );
    }

    #[test]
    fn a_value_set_before_the_load_wins() {
        let loaded = load(map(&[("a", "old"), ("b", "kept")]), map(&[("a", "new")]), true);
        assert_eq!(
            loaded,
            Loaded { entries: map(&[("a", "new"), ("b", "kept")]), keeps_file: false }
        );
        assert!(load(map(&[]), map(&[]), false).keeps_file);
    }

    #[test]
    fn a_save_waits_for_the_load_skips_a_kept_file_and_removes_an_empty_one() {
        assert_eq!(save(false, false, true, false), Save::Skip);
        assert_eq!(save(true, true, true, false), Save::Skip);
        assert_eq!(save(true, true, false, false), Save::Skip);
        assert_eq!(save(true, false, false, false), Save::AfterLoad);
        assert_eq!(save(true, false, true, false), Save::Write);
        assert_eq!(save(true, false, true, true), Save::Remove);
    }

    #[test]
    fn a_kept_file_migrates_nothing() {
        let entries = map(&[("m:a", "Nord")]);
        assert_eq!(migratable(&entries, false), entries);
        assert!(migratable(&entries, true).is_empty());
    }

    #[test]
    fn keys() {
        assert_eq!(terminal_key("mac", "tab-1"), "mac:tab-1");
        assert_eq!(workspace_key("session", "ws"), "session/ws");
    }

    #[test]
    fn prune_drops_only_that_machines_closed_terminals() {
        let live: BTreeSet<String> = ["t1".to_owned()].into();
        let keys = ["mac:t1", "mac:t2", "other:t2", "mac2:t3", "mac:"];
        assert_eq!(stale_keys(keys, "mac", &live), vec!["mac:t2".to_owned(), "mac:".to_owned()]);
        assert!(stale_keys(["mac:t1"], "mac", &live).is_empty());
    }
}

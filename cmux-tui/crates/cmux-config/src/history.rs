//! The settings history: every published change of the settings file, by
//! any writer (the Settings page, the palette, the `cmux` CLI, MCP agents,
//! recipes, a hand edit), so a person or an agent can always get back
//! (`settings.undo`, `settings.restore`). The owner appends one JSON line per
//! change to `<state_dir>/settings-history.jsonl`; no state directory, no
//! history.
//!
//! The entry, the trimming and the undo pick are pure; [`HistoryLog`] does
//! the file IO.

use std::collections::HashSet;
use std::io::Write as _;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::fsio::write_atomic;

/// Entries kept: reads return at most this many, newest first.
pub const HISTORY_CAPACITY: usize = 100;

/// The file name inside the state directory.
pub const HISTORY_FILE: &str = "settings-history.jsonl";

/// The settings file's text as this owner last saw it parse, beside the
/// history: a change made while no owner ran (or through a file that did not
/// parse) is recorded against it, so an undo takes back only that change.
pub const LAST_TEXT_FILE: &str = "settings-history.last";

/// One published change of the settings file.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HistoryEntry {
    /// The revision the change produced.
    pub revision: u64,
    /// When, in unix milliseconds.
    pub at: u64,
    /// Who changed it (`user`, `cli`, `mcp`, ..., `file` for a hand edit).
    pub origin: String,
    /// The dotted keys whose effective or file value changed.
    pub keys: Vec<String>,
    /// The whole file text before the change: what a restore writes back.
    pub before: String,
    /// The revision this change undid (`settings.undo`), if it was an undo.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub undoes: Option<u64>,
}

impl HistoryEntry {
    /// The entry as `settings.history` lists it: without `before` (a file's
    /// text is the restore's input, not the listing's).
    pub fn summary_json(&self) -> Value {
        let mut summary = json!({
            "revision": self.revision.to_string(),
            "at": self.at.to_string(),
            "origin": self.origin,
            "keys": self.keys,
        });
        if let (Some(undoes), Some(members)) = (self.undoes, summary.as_object_mut()) {
            members.insert("undoes".to_string(), Value::String(undoes.to_string()));
        }
        summary
    }
}

/// Entries from the file text, oldest first. A line that does not parse (a
/// write cut short) is skipped.
pub fn parse(text: &str) -> Vec<HistoryEntry> {
    text.lines()
        .filter(|line| !line.trim().is_empty())
        .filter_map(|line| serde_json::from_str(line).ok())
        .collect()
}

/// The newest `capacity` of `entries` (oldest first).
pub fn trim(entries: &[HistoryEntry], capacity: usize) -> &[HistoryEntry] {
    entries.get(entries.len().saturating_sub(capacity)..).unwrap_or(entries)
}

/// The entry `settings.undo` takes back, from `entries` oldest first: the
/// newest one that is not itself an undo and that no undo took back yet.
/// Repeated undo so walks back one change at a time, and a change made after
/// an undo is undone first. An entry whose `before` is already the file's
/// text (`current`) would change nothing and is passed over.
pub fn undo_pick<'a>(entries: &'a [HistoryEntry], current: &str) -> Option<&'a HistoryEntry> {
    let undone: HashSet<u64> = entries.iter().filter_map(|entry| entry.undoes).collect();
    entries.iter().rev().find(|entry| {
        entry.undoes.is_none() && !undone.contains(&entry.revision) && entry.before != current
    })
}

/// The entry that produced `revision`.
pub fn find(entries: &[HistoryEntry], revision: u64) -> Option<&HistoryEntry> {
    entries.iter().rev().find(|entry| entry.revision == revision)
}

/// The history file of one owner. Appends a line per change; the file is
/// rewritten (atomically) to the newest [`HISTORY_CAPACITY`] entries once it
/// holds twice as many, so an append costs the same however long the owner
/// runs and a rewrite of up to 100 file texts happens once per 100 changes,
/// not on every change.
#[derive(Debug)]
pub struct HistoryLog {
    path: PathBuf,
    /// Lines in the file, counted on the first append.
    lines: Option<usize>,
}

impl HistoryLog {
    pub fn new(state_dir: &Path) -> HistoryLog {
        HistoryLog { path: state_dir.join(HISTORY_FILE), lines: None }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    fn last_text_path(&self) -> PathBuf {
        self.path.with_file_name(LAST_TEXT_FILE)
    }

    /// The newest revision the history holds, if any.
    pub fn newest_revision(&self) -> Option<u64> {
        self.read().iter().map(|entry| entry.revision).max()
    }

    /// The file text saved by [`HistoryLog::save_last_text`], if any.
    pub fn last_text(&self) -> Option<String> {
        std::fs::read_to_string(self.last_text_path()).ok()
    }

    /// Saves the text the settings file parses with now. Best effort: a
    /// failed save only makes the next start's catch-up record nothing.
    pub fn save_last_text(&self, text: &str) {
        let path = self.last_text_path();
        if std::fs::read_to_string(&path).is_ok_and(|saved| saved == text) {
            return;
        }
        if let Some(directory) = path.parent() {
            let _ = std::fs::create_dir_all(directory);
        }
        if std::fs::symlink_metadata(&path).is_err() {
            let _ = private_options().write(true).create_new(true).open(&path);
        }
        let _ = write_atomic(&path, text.as_bytes());
    }

    /// The newest [`HISTORY_CAPACITY`] entries, oldest first.
    pub fn read(&self) -> Vec<HistoryEntry> {
        let text = std::fs::read_to_string(&self.path).unwrap_or_default();
        let entries = parse(&text);
        trim(&entries, HISTORY_CAPACITY).to_vec()
    }

    /// Appends `entry`. Best effort, like the cold-start cache: a failed
    /// append loses one recovery point, never the write it records.
    pub fn append(&mut self, entry: &HistoryEntry) {
        let Ok(mut line) = serde_json::to_string(entry) else { return };
        line.push('\n');
        if let Some(directory) = self.path.parent() {
            let _ = std::fs::create_dir_all(directory);
        }
        let count = match self.lines {
            Some(count) => count,
            None => std::fs::read_to_string(&self.path)
                .map(|text| text.lines().filter(|line| !line.trim().is_empty()).count())
                .unwrap_or(0),
        };
        let appended = private_options()
            .create(true)
            .append(true)
            .open(&self.path)
            .and_then(|mut file| file.write_all(line.as_bytes()));
        if appended.is_err() {
            self.lines = None;
            return;
        }
        let count = count + 1;
        self.lines = Some(count);
        if count >= HISTORY_CAPACITY * 2 {
            self.rewrite();
        }
    }

    /// Rewrites the file to the newest [`HISTORY_CAPACITY`] entries.
    fn rewrite(&mut self) {
        let kept = self.read();
        let mut text = String::new();
        for entry in &kept {
            if let Ok(line) = serde_json::to_string(entry) {
                text.push_str(&line);
                text.push('\n');
            }
        }
        self.lines = match write_atomic(&self.path, text.as_bytes()) {
            Ok(()) => Some(kept.len()),
            Err(_) => None,
        };
    }
}

/// Open options for a history file: owner-only on unix, since the file holds
/// whole settings texts. `write_atomic` keeps these bits on a rewrite.
fn private_options() -> std::fs::OpenOptions {
    #[allow(unused_mut, reason = "only unix sets the mode")]
    let mut options = std::fs::OpenOptions::new();
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt as _;
        options.mode(0o600);
    }
    options
}

/// Unix milliseconds now.
pub fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX))
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(revision: u64, before: &str, undoes: Option<u64>) -> HistoryEntry {
        HistoryEntry {
            revision,
            at: revision * 10,
            origin: "cli".to_string(),
            keys: vec!["editor.tabSize".to_string()],
            before: before.to_string(),
            undoes,
        }
    }

    #[test]
    fn trim_keeps_the_newest_entries() {
        let entries: Vec<_> = (1..=5).map(|revision| entry(revision, "", None)).collect();
        let kept: Vec<u64> = trim(&entries, 3).iter().map(|entry| entry.revision).collect();
        assert_eq!(kept, vec![3, 4, 5]);
        assert_eq!(trim(&entries, 10).len(), 5);
        assert!(trim(&[], 3).is_empty());
    }

    #[test]
    fn parse_skips_a_line_cut_short() {
        let line = serde_json::to_string(&entry(4, "{}", Some(2))).unwrap();
        let text = format!("{line}\n{{\"revision\": 5, \"at\"\n\n{line}\n");
        let parsed = parse(&text);
        assert_eq!(parsed.len(), 2);
        assert_eq!(parsed[0], entry(4, "{}", Some(2)));
        let plain = serde_json::to_string(&entry(1, "", None)).unwrap();
        assert!(!plain.contains("undoes"), "{plain}");
    }

    /// Undo walks back: the newest change, then the one before, skipping
    /// undo entries and the changes they undid.
    #[test]
    fn undo_pick_walks_back_one_change_at_a_time() {
        let mut entries = vec![entry(1, "a", None), entry(2, "b", None), entry(3, "c", None)];
        assert_eq!(undo_pick(&entries, "d").map(|entry| entry.revision), Some(3));
        entries.push(entry(4, "d", Some(3)));
        assert_eq!(undo_pick(&entries, "c").map(|entry| entry.revision), Some(2));
        entries.push(entry(5, "c", Some(2)));
        assert_eq!(undo_pick(&entries, "b").map(|entry| entry.revision), Some(1));
        entries.push(entry(6, "b", Some(1)));
        assert_eq!(undo_pick(&entries, "a"), None, "nothing left to undo");
    }

    /// A change after an undo is undone first; then the walk goes on.
    #[test]
    fn undo_pick_takes_a_new_change_first() {
        let entries = vec![
            entry(1, "a", None),
            entry(2, "b", None),
            entry(3, "c", Some(2)),
            entry(4, "b", None),
        ];
        assert_eq!(undo_pick(&entries, "e").map(|entry| entry.revision), Some(4));
        let mut entries = entries;
        entries.push(entry(5, "e", Some(4)));
        assert_eq!(undo_pick(&entries, "b").map(|entry| entry.revision), Some(1));
    }

    #[test]
    fn undo_pick_passes_over_a_change_that_would_change_nothing() {
        let entries = vec![entry(1, "a", None), entry(2, "same", None)];
        assert_eq!(undo_pick(&entries, "same").map(|entry| entry.revision), Some(1));
        assert_eq!(undo_pick(&[], "x"), None);
    }

    #[test]
    fn find_names_the_entry_of_a_revision() {
        let entries = vec![entry(1, "a", None), entry(2, "b", None)];
        assert_eq!(find(&entries, 2).map(|entry| entry.before.as_str()), Some("b"));
        assert_eq!(find(&entries, 9), None);
    }

    #[test]
    fn the_summary_leaves_the_file_text_out() {
        let summary = entry(7, "{\"secret\": 1}", Some(6)).summary_json();
        assert_eq!(
            summary,
            json!({"revision": "7", "at": "70", "origin": "cli", "keys": ["editor.tabSize"], "undoes": "6"})
        );
        assert_eq!(entry(7, "", None).summary_json().get("undoes"), None);
    }
}

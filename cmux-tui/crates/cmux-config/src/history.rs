//! The settings history: every published change of the settings file, by
//! any writer (the Settings page, the palette, the `cmux` CLI, MCP agents,
//! recipes, a hand edit), so a person or an agent can always get back
//! (`settings.undo`, `settings.restore`). The owner appends one JSON line per
//! change to `<state_dir>/settings-history-<file>.jsonl`, where `<file>` names
//! the settings file (a hash of its path): an owner opened on another
//! settings file never undoes or restores this one's texts over it. No state
//! directory, no history.
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

/// The history's file name inside the state directory, for the settings
/// file at `config_path`.
pub fn history_file_name(config_path: &Path) -> String {
    format!("settings-history-{}.jsonl", path_key(config_path))
}

/// The settings file's text as this owner last saw it parse, beside the
/// history: a change made while no owner ran (or through a file that did not
/// parse) is recorded against it, so an undo takes back only that change.
pub fn last_text_file_name(config_path: &Path) -> String {
    format!("settings-history-{}.last", path_key(config_path))
}

/// 16 hex digits of FNV-1a over the path's bytes: stable across builds and
/// runs (std's hasher is not), short enough for a file name.
fn path_key(config_path: &Path) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in config_path.as_os_str().as_encoded_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0100_0000_01b3);
    }
    format!("{hash:016x}")
}

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
    last_text_path: PathBuf,
    /// Lines in the file, counted on the first append.
    lines: Option<usize>,
}

impl HistoryLog {
    /// The history of the settings file at `config_path` (absolute).
    pub fn new(state_dir: &Path, config_path: &Path) -> HistoryLog {
        HistoryLog {
            path: state_dir.join(history_file_name(config_path)),
            last_text_path: state_dir.join(last_text_file_name(config_path)),
            lines: None,
        }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    fn last_text_path(&self) -> PathBuf {
        self.last_text_path.clone()
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
            None => {
                let text = std::fs::read_to_string(&self.path).unwrap_or_default();
                // A line cut short (a crash, a failed write) ends the file
                // without its newline: start on a line of our own, or both
                // lines would be lost to `parse`.
                if !text.is_empty() && !text.ends_with('\n') {
                    line.insert(0, '\n');
                }
                text.lines().filter(|line| !line.trim().is_empty()).count()
            }
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
#[path = "history_tests.rs"]
mod tests;

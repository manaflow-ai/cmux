use std::collections::HashMap;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::adapters;
use crate::entry::{AdapterKind, ChatEntry};
use crate::stamp::FileState;

/// One store root for one adapter. The index's own type: the BYOH profile
/// loader maps a harness profile's `sessions` block onto it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AdapterConfig {
    pub kind: AdapterKind,
    pub root: PathBuf,
    /// Newest files first, at most this many per root and scan.
    pub max_files: usize,
}

impl AdapterConfig {
    /// A bound for a runaway store, not a page size: one `~/.claude/projects` root commonly holds
    /// thousands of chats, and the New Tab's All chats pages must reach all of them (cx-dh2q:
    /// 2000 cut a 5000-chat root). Unchanged files cost only a stat on later scans (`prior`).
    pub const DEFAULT_MAX_FILES: usize = 20_000;

    pub fn new(kind: AdapterKind, root: impl Into<PathBuf>) -> Self {
        Self { kind, root: root.into(), max_files: Self::DEFAULT_MAX_FILES }
    }
}

/// The result of reading one session file.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FileRead {
    /// None when the file is not a chat (sidechain, subagent, empty, foreign).
    pub entry: Option<ChatEntry>,
    pub state: FileState,
}

/// Everything one root holds now.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RootScan {
    pub entries: Vec<ChatEntry>,
    /// Read state per session file (empty for database stores).
    pub files: Vec<(PathBuf, FileState)>,
    /// Files that failed to read; they are left out, never fatal.
    pub skipped: usize,
    /// True when the entries came from a database query (Codex state DB,
    /// OpenCode): session file events then do not apply, store events do.
    pub database: bool,
}

/// Reads one session file of a file-per-chat store. `prev` is the state from
/// the last read; only bytes after it are folded when the file only grew.
pub fn read_file(kind: AdapterKind, path: &Path, prev: Option<&FileState>) -> io::Result<FileRead> {
    adapters::read_file(kind, path, prev)
}

/// Reads a whole root: the database query for database stores, else the
/// newest `max_files` session files. A missing root is empty, not an error.
pub fn scan_root(
    config: &AdapterConfig,
    prior: &HashMap<PathBuf, FileState>,
) -> io::Result<RootScan> {
    if !config.root.is_dir() {
        return Ok(RootScan::default());
    }
    if let Some(entries) = adapters::read_store(config.kind, &config.root)? {
        return Ok(RootScan { entries, files: Vec::new(), skipped: 0, database: true });
    }
    let mut files: Vec<(PathBuf, i64)> = adapters::list_files(config.kind, &config.root)?
        .into_iter()
        .filter_map(|path| {
            let meta = fs::metadata(&path).ok()?;
            Some((path, crate::stamp::FileStamp::of(&meta).mtime_ms))
        })
        .collect();
    files.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    files.truncate(config.max_files);
    let mut scan = RootScan::default();
    for (path, _) in files {
        match read_file(config.kind, &path, prior.get(&path)) {
            Ok(read) => {
                if let Some(entry) = read.entry {
                    scan.entries.push(entry);
                }
                scan.files.push((path, read.state));
            }
            Err(_) => scan.skipped += 1,
        }
    }
    adapters::finish_scan(config.kind, &config.root, &mut scan.entries);
    Ok(scan)
}

/// The Chief's own harness sessions are not person chats (cx-eb0m): its turns run in
/// `$MUX_HOME/optchat/session` and its compactors in `$TMPDIR/optchat-compact-<home id>/slot-<k>`
/// (Native/OptChat/optchat-chief/README.md, file layout). On a harness that ignores the
/// session's own config dir their transcripts land in the person's store, titled with the Chief's
/// prompt markup (`0+1|user: …`, `</chat>`). `ChatIndex::merge` applies it, so every path
/// (full scan, watcher update, cache) is covered. Only the exact shapes match: the folder ends in
/// `optchat/session`, or in `optchat-compact-<id>/slot-<k>` or `optchat-compact-<id>/shared`.
/// Whether `entry` is a person's chat that All chats lists. Not: the Chief's own sessions; the
/// harness probes acpmux runs at start in its own `<acpmux home>/unattended` folder (one empty
/// session per harness, listed as ten "New chat · unattended" rows, Lawrence 2026-10-11); and any
/// session with no user message (no title from a prompt, no messages).
pub(crate) fn is_person_chat(entry: &ChatEntry) -> bool {
    if is_chief_session(entry) || is_probe_session(entry) {
        return false;
    }
    !(entry.title.is_none() && entry.message_count == Some(0))
}

/// acpmux's model probes run in `<acpmux home>/unattended` (`protected_folders::unattended_cwd`:
/// `~/.acpmux/unattended`, `~/.acpmux/builds/<key>/unattended`, or `<temp>/acpmux-unattended`), a
/// folder no person works in.
fn is_probe_session(entry: &ChatEntry) -> bool {
    let Some(cwd) = entry.cwd.as_deref() else { return false };
    let parts: Vec<&str> =
        cwd.trim_end_matches('/').split('/').filter(|part| !part.is_empty()).collect();
    // The fallback when the acpmux home is guarded: `<temp dir>/acpmux-unattended`.
    parts.last() == Some(&"acpmux-unattended")
        || (parts.last() == Some(&"unattended")
            && parts.iter().any(|part| part.starts_with(".acpmux")))
}

pub(crate) fn is_chief_session(entry: &ChatEntry) -> bool {
    // Any tag's or home's Chief (`$MUX_HOME` differs per tag and per isolated home): its turn
    // folder anywhere under an `optchat/session` pair, its compactor slots, and its prompt markup
    // as the title when the folder was not recorded (nxdog92: 89 such rows from other homes).
    if entry.title.as_deref().is_some_and(is_chief_markup) {
        return true;
    }
    let Some(cwd) = entry.cwd.as_deref() else { return false };
    let parts: Vec<&str> =
        cwd.trim_end_matches('/').split('/').filter(|part| !part.is_empty()).collect();
    if parts.windows(2).any(|pair| pair == ["optchat", "session"]) {
        return true;
    }
    match parts.as_slice() {
        [.., compact, slot] => {
            compact.starts_with("optchat-compact-")
                && (*slot == "shared" || slot.starts_with("slot-"))
        }
        _ => false,
    }
}

/// The Chief's prompt markup as a first line: `<n>+<m>|user: …` (its rendered message index) or a
/// bare `<chat>` / `</chat>` block tag. A person's prompt does not start this way.
fn is_chief_markup(title: &str) -> bool {
    let title = title.trim();
    if title == "<chat>" || title == "</chat>" || title.starts_with("<chat>") {
        return true;
    }
    let Some((index, rest)) = title.split_once('|') else { return false };
    let Some((a, b)) = index.split_once('+') else { return false };
    !a.is_empty()
        && !b.is_empty()
        && a.chars().all(|c| c.is_ascii_digit())
        && b.chars().all(|c| c.is_ascii_digit())
        && (rest.starts_with("user:") || rest.starts_with("assistant:"))
}

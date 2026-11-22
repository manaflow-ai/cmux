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
    pub const DEFAULT_MAX_FILES: usize = 2000;

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

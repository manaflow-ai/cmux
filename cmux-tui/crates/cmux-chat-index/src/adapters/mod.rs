//! One module per built-in store format. File-per-chat stores implement
//! `list` + `read`; database stores implement `read_store`.

use std::io;
use std::path::{Path, PathBuf};

use crate::entry::{AdapterKind, ChatEntry};
use crate::scan::FileRead;
use crate::stamp::FileState;

pub(crate) fn list_files(kind: AdapterKind, root: &Path) -> io::Result<Vec<PathBuf>> {
    let _ = (kind, root);
    Ok(Vec::new())
}

pub(crate) fn read_file(kind: AdapterKind, path: &Path, prev: Option<&FileState>) -> io::Result<FileRead> {
    let _ = (kind, path, prev);
    Ok(FileRead { entry: None, state: FileState::default() })
}

/// Some(entries) when `root` is a database store (Codex with a state DB,
/// OpenCode); None to scan session files instead.
pub(crate) fn read_store(kind: AdapterKind, root: &Path) -> io::Result<Option<Vec<ChatEntry>>> {
    let _ = (kind, root);
    Ok(None)
}

/// Root-level data applied after the file reads (Codex session index names).
pub(crate) fn finish_scan(kind: AdapterKind, root: &Path, entries: &mut [ChatEntry]) {
    let _ = (kind, root, entries);
}

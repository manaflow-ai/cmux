//! One module per built-in store format. File-per-chat stores implement
//! `list` + `read`; database stores implement `read_store`.

mod amp;
mod claude;
mod codex;
mod cursor;
mod gemini;
mod opencode;
mod pi;

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use crate::entry::{AdapterKind, ChatEntry};
use crate::scan::FileRead;
use crate::stamp::{FileStamp, FileState};

pub(crate) fn list_files(kind: AdapterKind, root: &Path) -> io::Result<Vec<PathBuf>> {
    match kind {
        AdapterKind::ClaudeCode => claude::list(root),
        AdapterKind::Codex => codex::list(root),
        AdapterKind::Pi => pi::list(root),
        AdapterKind::Gemini => gemini::list(root),
        AdapterKind::CursorAgent => cursor::list(root),
        AdapterKind::Amp => amp::list(root),
        AdapterKind::OpenCode => Ok(Vec::new()),
    }
}

pub(crate) fn read_file(
    kind: AdapterKind,
    path: &Path,
    prev: Option<&FileState>,
) -> io::Result<FileRead> {
    let stamp = FileStamp::of(&fs::metadata(path)?);
    match kind {
        AdapterKind::ClaudeCode => claude::read(path, stamp, prev),
        AdapterKind::Codex => codex::read(path, stamp, prev),
        AdapterKind::Pi => pi::read(path, stamp, prev),
        AdapterKind::Gemini => whole(gemini::read(path, stamp), stamp),
        AdapterKind::CursorAgent => whole(cursor::read(path, stamp), stamp),
        AdapterKind::Amp => whole(amp::read(path, stamp), stamp),
        AdapterKind::OpenCode => {
            Err(io::Error::new(io::ErrorKind::InvalidInput, "opencode is a database store"))
        }
    }
}

/// Some(entries) when `root` is a database store (Codex with a state DB,
/// OpenCode); None to scan session files instead.
pub(crate) fn read_store(kind: AdapterKind, root: &Path) -> io::Result<Option<Vec<ChatEntry>>> {
    match kind {
        AdapterKind::Codex => codex::read_store(root),
        AdapterKind::OpenCode => opencode::read_store(root).map(Some),
        _ => Ok(None),
    }
}

/// Root-level data applied after the file reads (Codex session index names).
pub(crate) fn finish_scan(kind: AdapterKind, root: &Path, entries: &mut [ChatEntry]) {
    if kind == AdapterKind::Codex {
        codex::apply_session_index(root, entries);
    }
}

/// State for a store whose files are parsed whole on each change.
fn whole(entry: io::Result<Option<ChatEntry>>, stamp: FileStamp) -> io::Result<FileRead> {
    Ok(FileRead {
        entry: entry?,
        state: FileState { stamp, offset: stamp.size, ..FileState::default() },
    })
}

/// Plain files with `extension` directly inside each subdirectory of `root`
/// (`<root>/<group>/<file>`), the layout Claude Code and Pi share.
fn files_one_level_down(root: &Path, keep: impl Fn(&str) -> bool) -> io::Result<Vec<PathBuf>> {
    let mut out = Vec::new();
    for group in fs::read_dir(root)?.flatten() {
        if !group.file_type().is_ok_and(|kind| kind.is_dir()) {
            continue;
        }
        let Ok(children) = fs::read_dir(group.path()) else { continue };
        for child in children.flatten() {
            let name = child.file_name();
            if child.file_type().is_ok_and(|kind| kind.is_file())
                && name.to_str().is_some_and(&keep)
            {
                out.push(child.path());
            }
        }
    }
    Ok(out)
}

fn file_stem(path: &Path) -> Option<String> {
    path.file_stem().and_then(|stem| stem.to_str()).map(str::to_owned)
}

fn argv(parts: &[&str]) -> Vec<String> {
    parts.iter().map(|part| (*part).to_owned()).collect()
}

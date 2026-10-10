//! One module per built-in store format. File-per-chat stores implement
//! `list` + `read`; database stores implement `read_store`.

mod amp;
mod auggie;
mod claude;
mod codex;
mod continue_dev;
mod copilot;
mod crush;
mod cursor;
mod droid;
mod gemini;
mod goose;
mod grok;
mod grok_cli;
mod kimi;
mod opencode;
mod openhands;
mod pi;
mod qwen;
mod vscode_tasks;

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use crate::entry::{AdapterKind, ChatEntry};
use crate::scan::FileRead;
use crate::stamp::{FileStamp, FileState};

/// Crush project data dirs listed in a global `projects.json`.
pub(crate) fn crush_project_dirs(index: &Path) -> Vec<PathBuf> {
    crush::project_data_dirs(index)
}

// Adapter contract. File-per-chat stores: `list(root)` and either
// `read(path, stamp, prev) -> FileRead` (incremental JSONL) or
// `read(path, stamp) -> Option<ChatEntry>` (parsed whole). Database and
// index stores: `read_store(root) -> Vec<ChatEntry>`. Every module has
// `classify(parts)` over the path components below the root.

pub(crate) fn list_files(kind: AdapterKind, root: &Path) -> io::Result<Vec<PathBuf>> {
    match kind {
        AdapterKind::ClaudeCode => claude::list(root),
        AdapterKind::Codex => codex::list(root),
        AdapterKind::Pi => pi::list(root),
        AdapterKind::Gemini => gemini::list(root),
        AdapterKind::CursorAgent => cursor::list(root),
        AdapterKind::Amp => amp::list(root),
        AdapterKind::QwenCode => qwen::list(root),
        AdapterKind::CopilotCli => copilot::list(root),
        AdapterKind::Grok => grok::list(root),
        AdapterKind::KimiCli => kimi::list_cli(root),
        AdapterKind::KimiCode => kimi::list_code(root),
        AdapterKind::Droid => droid::list(root),
        AdapterKind::Auggie => auggie::list(root),
        AdapterKind::OpenHands => openhands::list(root),
        AdapterKind::OpenCode
        | AdapterKind::Kilo
        | AdapterKind::GrokCli
        | AdapterKind::Goose
        | AdapterKind::Cline
        | AdapterKind::RooCode
        | AdapterKind::KiloCode
        | AdapterKind::Crush
        | AdapterKind::Continue => Ok(Vec::new()),
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
        AdapterKind::QwenCode => qwen::read(path, stamp, prev),
        AdapterKind::CopilotCli => copilot::read(path, stamp, prev),
        AdapterKind::Grok => whole(grok::read(path, stamp), stamp),
        AdapterKind::KimiCli => kimi::read_cli(path, stamp, prev),
        AdapterKind::KimiCode => whole(kimi::read_code(path, stamp), stamp),
        AdapterKind::Droid => droid::read(path, stamp, prev),
        AdapterKind::Auggie => whole(auggie::read(path, stamp), stamp),
        AdapterKind::OpenHands => whole(openhands::read(path, stamp), stamp),
        AdapterKind::OpenCode
        | AdapterKind::Kilo
        | AdapterKind::GrokCli
        | AdapterKind::Goose
        | AdapterKind::Cline
        | AdapterKind::RooCode
        | AdapterKind::KiloCode
        | AdapterKind::Crush
        | AdapterKind::Continue => {
            Err(io::Error::new(io::ErrorKind::InvalidInput, "a database or index store"))
        }
    }
}

/// Some(entries) when `root` is a database store (Codex with a state DB,
/// OpenCode); None to scan session files instead.
pub(crate) fn read_store(kind: AdapterKind, root: &Path) -> io::Result<Option<Vec<ChatEntry>>> {
    let entries = match kind {
        AdapterKind::Codex => return codex::read_store(root),
        AdapterKind::OpenCode => opencode::read_store(root, opencode::Flavor::OpenCode)?,
        AdapterKind::Kilo => opencode::read_store(root, opencode::Flavor::Kilo)?,
        AdapterKind::GrokCli => grok_cli::read_store(root)?,
        AdapterKind::Goose => goose::read_store(root)?,
        AdapterKind::Cline | AdapterKind::RooCode | AdapterKind::KiloCode => {
            vscode_tasks::read_store(kind, root)?
        }
        AdapterKind::Crush => crush::read_store(root)?,
        AdapterKind::Continue => continue_dev::read_store(root)?,
        _ => return Ok(None),
    };
    Ok(Some(entries))
}

/// Root-level data applied after the file reads: Codex session index
/// names, Kimi folders from the work-dir index, Claude's pre-JSONL SQLite
/// store, Gemini chats that only `logs.json` remembers.
pub(crate) fn finish_scan(kind: AdapterKind, root: &Path, entries: &mut Vec<ChatEntry>) {
    match kind {
        AdapterKind::Codex => codex::apply_session_index(root, entries),
        AdapterKind::KimiCli => kimi::finish_cli(root, entries),
        AdapterKind::KimiCode => kimi::finish_code(root, entries),
        AdapterKind::ClaudeCode => claude::add_legacy_store(root, entries),
        AdapterKind::Gemini | AdapterKind::QwenCode => {
            gemini::add_logged_sessions(kind, root, entries);
        }
        _ => {}
    }
}

/// The root-level data one re-read session file needs (a watcher event):
/// names and folders from root indexes, never whole-root additions.
pub(crate) fn finish_file(kind: AdapterKind, root: &Path, entries: &mut Vec<ChatEntry>) {
    match kind {
        AdapterKind::Codex => codex::apply_session_index(root, entries),
        AdapterKind::KimiCli => kimi::finish_cli(root, entries),
        AdapterKind::KimiCode => kimi::finish_code(root, entries),
        _ => {}
    }
}

/// What a changed path under a root means to the index.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PathRole {
    /// One chat's file: read it (incrementally) or drop it when gone.
    Session,
    /// A store-wide file (state DB, WAL, session index): scan the root again.
    Store,
    /// Not chat data (subagents, caches, blobs).
    Ignore,
}

pub fn classify_path(kind: AdapterKind, root: &Path, path: &Path) -> PathRole {
    let Ok(rel) = path.strip_prefix(root) else { return PathRole::Ignore };
    let parts: Vec<&str> = rel.iter().filter_map(|part| part.to_str()).collect();
    if parts.is_empty() {
        return PathRole::Ignore;
    }
    match kind {
        AdapterKind::ClaudeCode => claude::classify(&parts),
        AdapterKind::Codex => codex::classify(&parts),
        AdapterKind::OpenCode => opencode::classify(&parts, opencode::Flavor::OpenCode),
        AdapterKind::Kilo => opencode::classify(&parts, opencode::Flavor::Kilo),
        AdapterKind::Pi => pi::classify(&parts),
        AdapterKind::Gemini => gemini::classify(&parts),
        AdapterKind::CursorAgent => cursor::classify(&parts),
        AdapterKind::Amp => amp::classify(&parts),
        AdapterKind::QwenCode => qwen::classify(&parts),
        AdapterKind::CopilotCli => copilot::classify(&parts),
        AdapterKind::Grok => grok::classify(&parts),
        AdapterKind::GrokCli => grok_cli::classify(&parts),
        AdapterKind::KimiCli => kimi::classify_cli(&parts),
        AdapterKind::KimiCode => kimi::classify_code(&parts),
        AdapterKind::Goose => goose::classify(&parts),
        AdapterKind::Droid => droid::classify(&parts),
        AdapterKind::Cline | AdapterKind::RooCode | AdapterKind::KiloCode => {
            vscode_tasks::classify(&parts)
        }
        AdapterKind::Crush => crush::classify(&parts),
        AdapterKind::Auggie => auggie::classify(&parts),
        AdapterKind::Continue => continue_dev::classify(&parts),
        AdapterKind::OpenHands => openhands::classify(&parts),
    }
}

/// `Session` when `session` holds, else `Store` when `store` holds, else `Ignore`.
pub(crate) fn role(session: bool, store: bool) -> PathRole {
    if session {
        PathRole::Session
    } else if store {
        PathRole::Store
    } else {
        PathRole::Ignore
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

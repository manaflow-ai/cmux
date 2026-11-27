//! The folder a remote-origin Claude Code session may be created in.
//!
//! A remote chain's Claude Code at a `vmBoundary` runs with
//! `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` (`remote_sandbox.rs`; a sandboxed one
//! turns it off, and the check below holds for both), and in that mode
//! Claude creates empty placeholder
//! files in its working folder at every start: `package.json`, the npm, yarn
//! and pnpm lockfiles, `bunfig.toml`, `.npmrc`, `.yarnrc*`, `.gitmodules`,
//! the `.env*` files and `node_modules/.bin`. In a folder that holds
//! checkouts (a projects folder, a home), the empty `package.json` becomes
//! the parent workspace of every checkout below it, and workspace-aware
//! tools there (formatters, package managers) fail to parse it.
//!
//! So a new remote-origin Claude session runs in a git work tree (the stubs
//! land beside the repository's own files, where git shows them), or in a
//! scratch folder inside the system temporary folder (never that folder
//! itself, and never a remote chain's own `acpmux-remote-*` folder). That is
//! the scratch the remote sandbox (`remote_sandbox::refused_folder`) also
//! accepts; it refuses top-level dot folders in the home directory, so
//! `~/.cache` is no scratch here. The per-chat folder acpmux itself makes for a
//! peer's chat that names no folder (`~/chats/<name>`, `server/remote_guard.rs`
//! `peer_scratch`) is scratch too: a leaf folder made for that chat, marked by
//! acpmux, holding no `.git` below it, so the stubs land above no checkout
//! (`new --machine auto` with a brief and no `--cwd` was refused in its own
//! default folder). It lasts across reboots, where the temporary folder does
//! not. Anything else is refused with the cause and both ways out.
//!
//! Checked when the session is created, on the machine it runs on (the only
//! one that can read the folder). A session that already exists is never
//! re-checked: its respawn, resume and transfer keep working as before.

use std::path::Path;

use serde_json::json;

use crate::rpc::RpcError;

/// What decides whether a new session's folder is checked.
#[derive(Clone, Copy)]
pub(super) struct NewSession {
    /// Started over a remote connection (`remote_origin`): the remote chain.
    pub remote: bool,
    /// The trigger bridge's fixed-id chat (`server/trigger_chat.rs`), which keeps its own folder rule.
    pub trigger: bool,
    pub kind: crate::config::HarnessKind,
}

/// The check for a new session: only a remote chain's Claude Code (the one
/// `remote_sandbox.rs` runs in scrub mode) has its folder checked; a local
/// session, another harness and a trigger chat are unchanged.
pub(super) fn admit_new(
    new: NewSession,
    cwd: &Path,
    tmp: &Path,
    home: Option<&Path>,
) -> Result<(), RpcError> {
    if !new.remote || new.trigger || new.kind != crate::config::HarnessKind::ClaudeStdio {
        return Ok(());
    }
    check(cwd, tmp, home)
}

/// Ok when `cwd` is inside a git work tree, a scratch folder or acpmux's own
/// per-chat folder (module docs); else the refusal. `tmp` is the system
/// temporary folder, `home` the home directory.
pub(super) fn check(cwd: &Path, tmp: &Path, home: Option<&Path>) -> Result<(), RpcError> {
    let real = std::fs::canonicalize(cwd).unwrap_or_else(|_| cwd.to_path_buf());
    let tmp = std::fs::canonicalize(tmp).unwrap_or_else(|_| tmp.to_path_buf());
    let home = home.map(|h| std::fs::canonicalize(h).unwrap_or_else(|_| h.to_path_buf()));
    if in_work_tree(&real)
        || scratch(&real, &tmp)
        || home.is_some_and(|home| chat_folder(&real, &home))
    {
        return Ok(());
    }
    let suggestion = format!(
        "a checkout, or a scratch folder named after the lane such as {}",
        tmp.join("<lane>-tmp").display()
    );
    Err(RpcError::invalid_params(format!(
        "a remote Claude session needs a git checkout or a scratch folder as its working folder: \
         Claude creates empty placeholder files (package.json, lockfiles, .env*) in its working \
         folder, and {} isn't a checkout. Start it in {suggestion}.",
        cwd.display()
    ))
    .with_data(json!({"reason": "remote.cwd_not_checkout", "cwd": cwd})))
}

/// Whether `dir` or a folder above it holds `.git` (a folder, or the file a
/// linked worktree or submodule has).
fn in_work_tree(dir: &Path) -> bool {
    dir.ancestors().any(|d| d.join(".git").symlink_metadata().is_ok())
}

/// Whether `dir` sits strictly below the temporary folder and outside every
/// remote chain's own `acpmux-remote-*` folder (as `refused_folder` has it).
fn scratch(dir: &Path, tmp: &Path) -> bool {
    let Ok(rest) = dir.strip_prefix(tmp) else { return false };
    match rest.components().next() {
        None => false,
        Some(first) => !first.as_os_str().to_string_lossy().starts_with("acpmux-remote-"),
    }
}

/// Whether `dir` is a per-chat folder acpmux made for a peer's chat with no
/// folder: a real folder directly in `<home>/chats`, holding acpmux's marker
/// (`trust::AGENT_HOME_MARKER`) as a regular file, with no `.git` anywhere
/// below it. A folder too large to look through is no chat folder.
fn chat_folder(dir: &Path, home: &Path) -> bool {
    if dir.parent() != Some(home.join("chats").as_path()) {
        return false;
    }
    let folder = std::fs::symlink_metadata(dir).is_ok_and(|m| m.file_type().is_dir());
    let marker = std::fs::symlink_metadata(dir.join(crate::trust::AGENT_HOME_MARKER))
        .is_ok_and(|m| m.file_type().is_file());
    folder && marker && holds_no_checkout(dir, CHAT_FOLDER_ENTRIES)
}

/// How many entries [`holds_no_checkout`] reads before it gives up (and refuses).
const CHAT_FOLDER_ENTRIES: usize = 20_000;

/// Whether no folder below `dir` holds `.git`, reading at most `budget`
/// entries and following no symlink. Unreadable or over budget: false.
fn holds_no_checkout(dir: &Path, mut budget: usize) -> bool {
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&d) else { return false };
        for entry in entries {
            let Ok(entry) = entry else { return false };
            if budget == 0 {
                return false;
            }
            budget -= 1;
            if entry.file_name() == ".git" {
                return false;
            }
            if entry.file_type().is_ok_and(|t| t.is_dir()) {
                stack.push(entry.path());
            }
        }
    }
    true
}

#[cfg(test)]
#[path = "remote_cwd_tests.rs"]
mod tests;

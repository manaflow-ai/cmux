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
//! `~/.cache` is no scratch here. Anything else is refused with the cause and
//! both ways out.
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
pub(super) fn admit_new(new: NewSession, cwd: &Path, tmp: &Path) -> Result<(), RpcError> {
    if !new.remote || new.trigger || new.kind != crate::config::HarnessKind::ClaudeStdio {
        return Ok(());
    }
    check(cwd, tmp)
}

/// Ok when `cwd` is inside a git work tree or a scratch folder (module
/// docs); else the refusal. `tmp` is the system temporary folder.
pub(super) fn check(cwd: &Path, tmp: &Path) -> Result<(), RpcError> {
    let real = std::fs::canonicalize(cwd).unwrap_or_else(|_| cwd.to_path_buf());
    let tmp = std::fs::canonicalize(tmp).unwrap_or_else(|_| tmp.to_path_buf());
    if in_work_tree(&real) || scratch(&real, &tmp) {
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

#[cfg(test)]
mod tests;

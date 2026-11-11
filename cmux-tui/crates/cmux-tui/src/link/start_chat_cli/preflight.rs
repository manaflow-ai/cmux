//! `cmux link start-chat preflight --local FOLDER`: whether a Cloud chat may start from `FOLDER`
//! at all, asked before any machine or lease is made for it (the App's `CloudStartChat`). A folder
//! in git goes on (a seed clones it; the copy it may fall back to is counted then). A plain folder
//! is counted as its copy would be ([`size_cap::check_plain`]), stopping at the first limit; one
//! past a limit is refused with [`size_cap::CODE`], the folder as the person reads it, and the git
//! working copies right inside it (`repos`), so the card offers each as the chat's folder instead.
//!
//! Leo, 2026-11-10, on a Cloud start from `~/Projects` (a parent of many repositories, 20 GB) that
//! made a machine, then failed its copy with a Retry that could only fail again: "then there's
//! this limit" and "did you guys not test these".

use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use super::super::sync_cli::{self, size_cap};

/// The most repositories a refusal names.
pub(super) const MAX_REPOS: usize = 24;
/// The most entries read in one folder while looking for repositories: a folder of thousands of
/// entries is never read whole.
const MAX_ENTRIES: usize = 2_000;

/// One git working copy inside the refused folder.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Repo {
    /// Its path below the folder (`cmux`, `work/api`).
    pub name: String,
    /// Its absolute path on this Mac.
    pub path: PathBuf,
}

/// The answer for `local`: `{"ok":true}`, or the refusal with the repositories inside it.
pub(super) fn run(local: &str) -> Value {
    let folder = Path::new(local);
    if !folder.is_absolute() {
        return super::refused("usage.invalid", "--local must be an absolute folder");
    }
    match check(folder) {
        Ok(()) => json!({"ok": true}),
        Err(refusal) => refusal,
    }
}

/// [`run`]'s check: Err is the refusal's JSON.
pub(super) fn check(folder: &Path) -> Result<(), Value> {
    // A folder that is gone or unreadable is the pane's and the copy's to report.
    let Ok(folder) = std::fs::canonicalize(folder) else { return Ok(()) };
    if sync_cli::in_git(&folder) {
        return Ok(());
    }
    let Err(large) = size_cap::check_plain(&folder) else { return Ok(()) };
    let (repos, more) = child_repos(&folder, MAX_REPOS);
    let listed: Vec<Value> = repos
        .iter()
        .map(|repo| json!({"name": repo.name, "path": repo.path.to_string_lossy()}))
        .collect();
    Err(json!({
        "ok": false,
        "error": large.to_string(),
        "error_code": size_cap::CODE,
        "folder": size_cap::shown(&folder),
        "bytes": large.bytes,
        "files": large.files,
        "repos": listed,
        "repos_more": more,
    }))
}

/// The git working copies directly in `folder`, and one level further down (`work/api`), by name,
/// at most `limit`, and whether there were more. Only `.git` is looked for: no folder below a
/// repository or two levels down is read, hidden folders are skipped and symlinks never followed,
/// and at most [`MAX_ENTRIES`] entries of any one folder are read.
pub(super) fn child_repos(folder: &Path, limit: usize) -> (Vec<Repo>, bool) {
    let mut found = Vec::new();
    let mut more = false;
    let children = folders_in(folder);
    let mut plain = Vec::new();
    for child in children {
        if is_repo(&child) {
            push(&mut found, &mut more, folder, child, limit);
        } else {
            plain.push(child);
        }
    }
    for child in plain {
        if more {
            break;
        }
        for grandchild in folders_in(&child) {
            if is_repo(&grandchild) {
                push(&mut found, &mut more, folder, grandchild, limit);
            }
        }
    }
    found.sort_by(|a, b| a.name.cmp(&b.name));
    (found, more)
}

fn push(found: &mut Vec<Repo>, more: &mut bool, folder: &Path, path: PathBuf, limit: usize) {
    if found.len() >= limit {
        *more = true;
        return;
    }
    let name = path.strip_prefix(folder).map_or_else(|_| path.display().to_string(), |rest| rest.display().to_string());
    found.push(Repo { name, path });
}

/// The visible folders right in `folder` (no symlinks), by name, at most [`MAX_ENTRIES`] read.
fn folders_in(folder: &Path) -> Vec<PathBuf> {
    let Ok(entries) = std::fs::read_dir(folder) else { return Vec::new() };
    let mut folders: Vec<PathBuf> = entries
        .take(MAX_ENTRIES)
        .filter_map(Result::ok)
        .filter(|entry| !entry.file_name().to_string_lossy().starts_with('.'))
        .filter(|entry| entry.file_type().is_ok_and(|kind| kind.is_dir()))
        .map(|entry| entry.path())
        .collect();
    folders.sort();
    folders
}

/// Whether `folder` is a working copy's top: it holds `.git` (a folder, or a worktree's file).
fn is_repo(folder: &Path) -> bool {
    std::fs::symlink_metadata(folder.join(".git")).is_ok()
}

#[cfg(test)]
#[path = "preflight_tests.rs"]
mod tests;

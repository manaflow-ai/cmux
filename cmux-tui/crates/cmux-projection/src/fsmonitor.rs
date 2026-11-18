//! git's fsmonitor hook (protocol v2) answered from a projection's change set (RFD 0007, hard case 2
//! and open question 4): the lower layer is the Mac's manifest and never changes while it is
//! mounted, so everything that changed in the folder since the mount is in the upper layer or its
//! whiteouts. `git status` then checks only those paths instead of every file of the working tree,
//! which over the mount is one `lstat` through FUSE each.
//!
//! The token names the manifest (`cache/manifest-id`): while it stays, the answer is every path
//! the upper layer holds or the whiteouts name below the repository, a superset of what changed
//! since any earlier token of the same mount, which git accepts. A token of another manifest, or
//! none, is answered `/` (everything), so git scans once and records ours.
//!
//! git runs the hook in the repository's working tree; the hook finds its projection by the
//! mount point each projection's state records ([`MOUNT_POINT_FILE`]).

use std::fs;
use std::os::unix::ffi::OsStrExt as _;
use std::path::{Path, PathBuf};

/// The file in a projection's state folder naming where it is mounted.
pub const MOUNT_POINT_FILE: &str = "mount-point";
/// The token's prefix.
const TOKEN_PREFIX: &str = "cmux-projection:";

/// The hook's answer for the repository at `worktree` with git's `token`, finding its projection
/// among the state folders in `projections`. Not in a projection, or its state unreadable: the
/// answer that makes git scan everything.
#[must_use]
pub fn hook(projections: &Path, worktree: &Path, token: &str) -> Vec<u8> {
    let worktree = fs::canonicalize(worktree).unwrap_or_else(|_| worktree.to_path_buf());
    let found = fs::read_dir(projections).ok().and_then(|states| {
        states.filter_map(Result::ok).find_map(|state| {
            let state = state.path();
            let at = fs::read(state.join(MOUNT_POINT_FILE)).ok()?;
            let at = PathBuf::from(std::ffi::OsStr::from_bytes(&at));
            let below = worktree.strip_prefix(&at).ok()?;
            Some((state, below.to_str()?.to_owned()))
        })
    });
    match found {
        Some((state, prefix)) => answer(&state, &prefix, token).unwrap_or_else(|_| everything("")),
        None => everything(""),
    }
}

/// The hook's answer for the repository `prefix` (relative to the projected folder, empty for the
/// folder itself) of the projection whose state is `state`.
pub fn answer(state: &Path, prefix: &str, token: &str) -> std::io::Result<Vec<u8>> {
    let id = fs::read_to_string(state.join("cache").join("manifest-id"))?;
    let ours = format!("{TOKEN_PREFIX}{}", id.trim());
    if token != ours {
        return Ok(everything(&ours));
    }
    let mut out = Vec::with_capacity(ours.len() + 1);
    out.extend_from_slice(ours.as_bytes());
    out.push(0);
    let upper = state.join("upper");
    let top = if prefix.is_empty() { upper } else { upper.join(prefix) };
    walk(&top, "", &mut out)?;
    let whiteouts = fs::read_to_string(state.join("whiteouts")).unwrap_or_default();
    for path in whiteouts.lines().filter(|line| !line.is_empty()) {
        let Some(relative) = below(prefix, path) else { continue };
        if relative.is_empty() || is_git_dir(relative) {
            continue;
        }
        // A whiteout may hide a folder: both spellings, so git drops what was under it too.
        push(&mut out, relative);
        push(&mut out, &format!("{relative}/"));
    }
    Ok(out)
}

/// `token`, then `/`: everything may have changed.
fn everything(token: &str) -> Vec<u8> {
    let mut out = token.as_bytes().to_vec();
    out.push(0);
    out.extend_from_slice(b"/\0");
    out
}

fn push(out: &mut Vec<u8>, path: &str) {
    out.extend_from_slice(path.as_bytes());
    out.push(0);
}

/// `path` relative to `prefix`, when it is below it.
fn below<'a>(prefix: &str, path: &'a str) -> Option<&'a str> {
    if prefix.is_empty() {
        return Some(path);
    }
    path.strip_prefix(prefix)?.strip_prefix('/')
}

/// Whether `relative` is in a `.git` folder: this repository's own, or a nested one's, which git
/// never reads as working tree files either.
fn is_git_dir(relative: &str) -> bool {
    relative.split('/').any(|name| name == ".git")
}

/// Every file and link below `dir`, `relative` naming `dir` itself.
fn walk(dir: &Path, relative: &str, out: &mut Vec<u8>) -> std::io::Result<()> {
    let entries = match fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error),
    };
    for entry in entries {
        let entry = entry?;
        let Some(name) = entry.file_name().to_str().map(str::to_owned) else { continue };
        let path = if relative.is_empty() { name } else { format!("{relative}/{name}") };
        if is_git_dir(&path) {
            continue;
        }
        // A folder in the upper layer is only where a changed file sits (a copy up makes the
        // folders above it): its files are named, never the folder, which git would take as
        // "everything below changed".
        if entry.file_type()?.is_dir() {
            walk(&entry.path(), &path, out)?;
        } else {
            push(out, &path);
        }
    }
    Ok(())
}

#[cfg(test)]
#[path = "fsmonitor_tests.rs"]
mod tests;

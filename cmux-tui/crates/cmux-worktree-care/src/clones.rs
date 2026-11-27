//! Plain clones a lane left behind (a `.git` folder, not a linked
//! worktree): the one family whose content can be unique. Before one goes,
//! its work is checked and archived:
//!
//! - uncommitted, untracked or ignored changes: the clone stays (this archive keeps
//!   commits, not loose files);
//! - commits on no remote branch: kept in a bundle in the archive store
//!   (`clones/<id>.bundle`), verified, before the folder goes;
//! - nothing of its own: nothing to keep.
//!
//! Anything git cannot answer keeps the clone.

use std::path::{Path, PathBuf};
use std::time::Duration;

use crate::store::Store;

const LIMIT: Duration = Duration::from_secs(60);

/// Ignored folders that are build output, rebuilt from the sources: a clone
/// holding only these ignored files may go.
const REBUILT: &[&str] = &[
    "target",
    "node_modules",
    ".build",
    "build",
    "dist",
    ".next",
    "__pycache__",
    "DerivedData",
    ".gradle",
    ".venv",
    "venv",
    ".turbo",
    ".cache",
    ".DS_Store",
];

/// What `git bundle` keeps: every local branch and tag, minus what remotes
/// have (a detached `HEAD` keeps the clone, see [`work`]).
const LOCAL_ONLY: &[&str] = &["--branches", "--tags", "--not", "--remotes"];

/// The first ignored path in `git status --ignored` output that is not
/// build output, if any.
fn ignored_local_file(status: &[u8]) -> Option<String> {
    String::from_utf8_lossy(status).lines().find_map(|line| {
        let path = line.strip_prefix("!! ")?;
        let path = path.trim_matches('"');
        let rebuilt =
            path.split('/').filter(|part| !part.is_empty()).any(|part| REBUILT.contains(&part));
        (!rebuilt).then(|| path.to_string())
    })
}

/// What a clone holds that no remote has.
#[derive(Debug, PartialEq, Eq)]
pub enum Work {
    /// Everything is on a remote.
    Pushed,
    /// Local-only commits: this many.
    Unpushed(usize),
}

/// What is in `clone` that would be lost, or why it cannot be said or must stay.
pub fn work(clone: &Path) -> Result<Work, String> {
    let status =
        crate::git::user_git(clone, &["status", "--porcelain=v1", "-uall", "--ignored"], LIMIT)?;
    if !status.is_empty() {
        return Err("it has uncommitted, untracked or ignored changes".into());
    }
    // Ignored files are local too (`.env`, secrets, notes): only build
    // output may go with the clone.
    let ignored = crate::git::user_git(
        clone,
        &["status", "--porcelain=v1", "--ignored=matching", "-unormal"],
        LIMIT,
    )?;
    if let Some(path) = ignored_local_file(&ignored) {
        return Err(format!("it has ignored local files ({path})"));
    }
    // Its linked worktrees would lose their repository.
    let worktrees = crate::git::user_git(clone, &["worktree", "list", "--porcelain"], LIMIT)?;
    let linked =
        String::from_utf8_lossy(&worktrees).lines().filter(|l| l.starts_with("worktree ")).count();
    if linked > 1 {
        return Err("it has linked worktrees".into());
    }
    // A stash is work too.
    let stash = crate::git::user_git(clone, &["stash", "list"], LIMIT)?;
    if !stash.is_empty() {
        return Err("it has a stash".into());
    }
    let remotes = crate::git::user_git(clone, &["remote"], LIMIT)?;
    if remotes.is_empty() {
        return Err("it has no remote to compare with".into());
    }
    // Other worktrees and submodules may keep their only index or object
    // database under this clone's .git; a branch bundle does not save those.
    let worktrees = crate::git::user_git(clone, &["worktree", "list", "--porcelain", "-z"], LIMIT)?;
    if worktrees.split(|byte| *byte == 0).filter(|field| field.starts_with(b"worktree ")).count()
        != 1
    {
        return Err("it owns linked worktrees or their registration is unreadable".into());
    }
    match std::fs::symlink_metadata(clone.join(".git/modules")) {
        Ok(_) => return Err("it has a submodule object store".into()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(format!("cannot inspect submodule object stores: {error}")),
    }
    // Bundles below retain branches and tags, not a detached HEAD.
    crate::git::user_git(clone, &["symbolic-ref", "--quiet", "HEAD"], LIMIT)
        .map_err(|_| "its HEAD is detached or unreadable; it stays".to_string())?;
    let ahead = crate::git::user_git(
        clone,
        &["rev-list", "--branches", "--tags", "--not", "--remotes"],
        LIMIT,
    )?;
    let count = String::from_utf8_lossy(&ahead).lines().filter(|l| !l.trim().is_empty()).count();
    Ok(if count == 0 { Work::Pushed } else { Work::Unpushed(count) })
}

/// References captured around archival, to detect work committed during it.
pub(crate) fn references(clone: &Path) -> Result<Vec<u8>, String> {
    crate::git::user_git(clone, &["show-ref", "--head"], LIMIT)
}

/// Keeps the clone's local-only commits in a verified bundle; the archive id,
/// or `None` when there was nothing to keep.
pub fn archive(clone: &Path, store: &Store, now_ms: u64) -> Result<Option<String>, String> {
    match work(clone)? {
        Work::Pushed => Ok(None),
        Work::Unpushed(_) => {
            let id = format!("clone-{}", crate::store::new_id(now_ms, clone));
            let folder: PathBuf = store.dir.join("clones");
            std::fs::create_dir_all(&folder).map_err(|e| format!("{}: {e}", folder.display()))?;
            let bundle = folder.join(format!("{id}.bundle"));
            let target = bundle.to_string_lossy().into_owned();
            let mut create = vec!["bundle", "create", target.as_str()];
            create.extend_from_slice(LOCAL_ONLY);
            let made = crate::git::user_git(clone, &create, Duration::from_secs(600));
            let checked = made
                .and_then(|_| crate::git::user_git(clone, &["bundle", "verify", &target], LIMIT));
            if let Err(error) = checked {
                let _ = std::fs::remove_file(&bundle);
                return Err(format!("could not archive its commits: {error}"));
            }
            let note = folder.join(format!("{id}.txt"));
            let _ = std::fs::write(&note, format!("{}\n", clone.display()));
            Ok(Some(id))
        }
    }
}

#[cfg(test)]
#[path = "clones_tests.rs"]
mod tests;

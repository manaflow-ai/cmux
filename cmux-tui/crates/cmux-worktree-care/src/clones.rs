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
            let made = crate::git::user_git(
                clone,
                &["bundle", "create", &target, "--branches", "--tags", "--not", "--remotes"],
                Duration::from_secs(600),
            );
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
mod tests {
    use super::*;
    use crate::store::care_tests::scratch;

    fn git(dir: &Path, args: &[&str]) {
        let out = std::process::Command::new("git")
            .args(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"])
            .args(args)
            .current_dir(dir)
            .output()
            .unwrap();
        assert!(out.status.success(), "{args:?}: {}", String::from_utf8_lossy(&out.stderr));
    }

    fn clone_pair(name: &str) -> (PathBuf, PathBuf) {
        let base = scratch(name);
        let origin = base.join("origin");
        std::fs::create_dir_all(&origin).unwrap();
        git(&origin, &["init", "-q", "-b", "main"]);
        std::fs::write(origin.join("a"), "1").unwrap();
        git(&origin, &["add", "a"]);
        git(&origin, &["commit", "-q", "-m", "one"]);
        let clone = base.join("clone");
        git(&base, &["clone", "-q", "origin", "clone"]);
        (base, clone)
    }

    #[test]
    fn a_pushed_clean_clone_has_nothing_to_keep() {
        let (base, clone) = clone_pair("clone-pushed");
        let store = Store::open(base.join("store")).unwrap();
        assert_eq!(work(&clone).unwrap(), Work::Pushed);
        assert_eq!(archive(&clone, &store, 1).unwrap(), None);
    }

    #[test]
    fn local_commits_are_bundled_and_verified_before_anything_goes() {
        let (base, clone) = clone_pair("clone-unpushed");
        std::fs::write(clone.join("b"), "2").unwrap();
        git(&clone, &["add", "b"]);
        git(&clone, &["commit", "-q", "-m", "local"]);
        let store = Store::open(base.join("store")).unwrap();
        assert_eq!(work(&clone).unwrap(), Work::Unpushed(1));
        let id = archive(&clone, &store, 5).unwrap().expect("archived");
        let bundle = store.dir.join("clones").join(format!("{id}.bundle"));
        assert!(bundle.exists());
        crate::git::user_git(&clone, &["bundle", "verify", &bundle.to_string_lossy()], LIMIT)
            .unwrap();
    }

    #[test]
    fn detached_commits_keep_the_clone() {
        let (base, clone) = clone_pair("clone-detached-preserve");
        git(&clone, &["checkout", "--detach", "-q"]);
        std::fs::write(clone.join("a"), "detached work").unwrap();
        git(&clone, &["commit", "-qam", "detached"]);
        let store = Store::open(base.join("store")).unwrap();
        assert!(work(&clone).is_err());
        assert!(archive(&clone, &store, 1).is_err());
    }

    #[test]
    fn ignored_local_data_keeps_the_clone() {
        let (base, clone) = clone_pair("clone-ignored-preserve");
        std::fs::write(clone.join(".git/info/exclude"), ".env\nlocal-db/\n").unwrap();
        std::fs::create_dir_all(clone.join("local-db")).unwrap();
        std::fs::write(clone.join("local-db/data"), "local data").unwrap();
        std::fs::write(clone.join(".env"), "local config").unwrap();
        let store = Store::open(base.join("store")).unwrap();
        assert!(work(&clone).is_err());
        assert!(archive(&clone, &store, 1).is_err());
    }

    #[test]
    fn linked_worktree_data_keeps_the_common_clone() {
        let (base, clone) = clone_pair("clone-linked-preserve");
        git(&clone, &["worktree", "add", "-qb", "linked", "../linked"]);
        let linked = base.join("linked");
        std::fs::write(linked.join("a"), "staged only").unwrap();
        git(&linked, &["add", "a"]);
        std::fs::write(linked.join("a"), "1").unwrap();
        let store = Store::open(base.join("store")).unwrap();
        assert!(work(&clone).is_err());
        assert!(archive(&clone, &store, 1).is_err());
    }

    #[test]
    fn submodule_object_stores_keep_the_clone() {
        let (base, clone) = clone_pair("clone-modules-preserve");
        std::fs::create_dir_all(clone.join(".git/modules/local")).unwrap();
        let store = Store::open(base.join("store")).unwrap();
        assert!(work(&clone).is_err());
        assert!(archive(&clone, &store, 1).is_err());
    }

    #[test]
    fn dirty_stashed_or_remoteless_clones_are_kept() {
        let (base, clone) = clone_pair("clone-dirty");
        std::fs::write(clone.join("loose"), "x").unwrap();
        assert!(work(&clone).unwrap_err().contains("uncommitted"));
        let store = Store::open(base.join("store")).unwrap();
        assert!(archive(&clone, &store, 1).is_err());
        let alone = base.join("alone");
        std::fs::create_dir_all(&alone).unwrap();
        git(&alone, &["init", "-q"]);
        assert!(work(&alone).unwrap_err().contains("no remote"));
    }
}

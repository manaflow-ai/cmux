//! Plain clones a lane left behind (a `.git` folder, not a linked
//! worktree): the one family whose content can be unique. Before one goes,
//! its work is checked and archived:
//!
//! - uncommitted, untracked or ignored local files (a `.env`, notes; build
//!   output such as `target/` or `node_modules/` aside): the clone stays
//!   (this archive keeps commits, not loose files);
//! - linked worktrees of its own: the clone stays (they would lose their
//!   repository);
//! - commits on no remote branch, a detached `HEAD` included: kept in a bundle in the archive store
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

/// What `git rev-list` and `git bundle` read: every local ref and `HEAD`
/// (a detached checkout's commits are on no branch), minus what remotes have.
const LOCAL_ONLY: &[&str] = &["HEAD", "--branches", "--tags", "--not", "--remotes"];

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
    let status = crate::git::user_git(clone, &["status", "--porcelain=v1", "-uall"], LIMIT)?;
    if !status.is_empty() {
        return Err("it has uncommitted or untracked changes".into());
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
    let mut rev_list = vec!["rev-list"];
    rev_list.extend_from_slice(LOCAL_ONLY);
    let ahead = crate::git::user_git(clone, &rev_list, LIMIT)?;
    let count = String::from_utf8_lossy(&ahead).lines().filter(|l| !l.trim().is_empty()).count();
    Ok(if count == 0 { Work::Pushed } else { Work::Unpushed(count) })
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

    #[test]
    fn ignored_local_files_keep_the_clone_but_build_output_does_not() {
        let (_base, clone) = clone_pair("clone-ignored");
        std::fs::write(clone.join(".gitignore"), ".env\ntarget/\nnode_modules/\n").unwrap();
        git(&clone, &["add", ".gitignore"]);
        git(&clone, &["commit", "-q", "-m", "ignore"]);
        git(&clone, &["push", "-q", "origin", "HEAD:main"]);
        std::fs::create_dir_all(clone.join("target/debug")).unwrap();
        std::fs::write(clone.join("target/debug/bin"), "x").unwrap();
        std::fs::create_dir_all(clone.join("node_modules/pkg")).unwrap();
        std::fs::write(clone.join("node_modules/pkg/i.js"), "x").unwrap();
        assert_eq!(work(&clone).unwrap(), Work::Pushed);
        std::fs::write(clone.join(".env"), "SECRET=1").unwrap();
        let error = work(&clone).unwrap_err();
        assert!(error.contains("ignored local files") && error.contains(".env"), "{error}");
    }

    #[test]
    fn a_detached_commit_is_counted_and_bundled() {
        let (base, clone) = clone_pair("clone-detached");
        git(&clone, &["checkout", "-q", "--detach"]);
        std::fs::write(clone.join("d"), "3").unwrap();
        git(&clone, &["add", "d"]);
        git(&clone, &["commit", "-q", "-m", "detached"]);
        assert_eq!(work(&clone).unwrap(), Work::Unpushed(1));
        let store = Store::open(base.join("store")).unwrap();
        let id = archive(&clone, &store, 7).unwrap().expect("archived");
        let bundle = store.dir.join("clones").join(format!("{id}.bundle"));
        let heads = crate::git::user_git(
            &clone,
            &["bundle", "list-heads", &bundle.to_string_lossy()],
            LIMIT,
        )
        .unwrap();
        let head = crate::git::user_git(&clone, &["rev-parse", "HEAD"], LIMIT).unwrap();
        let head = String::from_utf8_lossy(&head).trim().to_string();
        assert!(String::from_utf8_lossy(&heads).contains(&head));
    }

    #[test]
    fn a_clone_with_linked_worktrees_is_kept() {
        let (base, clone) = clone_pair("clone-linked");
        let linked = base.join("linked");
        git(&clone, &["worktree", "add", "-q", "-b", "side", &linked.to_string_lossy()]);
        assert!(work(&clone).unwrap_err().contains("linked worktrees"));
    }
}

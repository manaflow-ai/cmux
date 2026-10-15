//! A folder's git branch and HEAD commit, which session/new and session/fork
//! record in the session's meta (hq#1920: a session joins the pull request it
//! produced). Read from the repository's own files, never a git process, so
//! it costs a few small reads and cannot hang on a git that waits for input.
//!
//! The lookup finds `.git` in the folder or above it, follows a linked
//! worktree's or submodule's `gitdir:` file and its `commondir`, and resolves
//! HEAD through a loose ref, else `packed-refs`. Anything it cannot read
//! leaves that part `None`; it never fails the session.

use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};

/// The git state of a folder at one moment.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct GitState {
    /// The checked-out branch, without `refs/heads/`: `None` on a detached
    /// HEAD or outside a repository.
    pub branch: Option<String>,
    /// The full HEAD commit: `None` outside a repository or on a branch with
    /// no commit yet.
    pub head: Option<String>,
}

/// Symbolic refs followed before giving up (a ref that names a ref).
const MAX_REF_DEPTH: usize = 5;

impl GitState {
    /// The git state of `dir`, the folder a session runs in.
    pub fn read(dir: &Path) -> Self {
        let Some(git_dir) = find_git_dir(dir) else {
            return Self::default();
        };
        let common = common_dir(&git_dir);
        let Some(head) = read_trimmed(&git_dir.join("HEAD")) else {
            return Self::default();
        };
        let Some(name) = head.strip_prefix("ref: ").map(str::trim) else {
            return Self { branch: None, head: is_object_id(&head).then_some(head) };
        };
        // A reftable repository keeps refs out of files; its HEAD names this
        // placeholder. Its branch and commit are unreadable here.
        if name == "refs/heads/.invalid" {
            return Self::default();
        }
        Self {
            branch: name.strip_prefix("refs/heads/").map(str::to_owned),
            head: resolve_ref(&git_dir, &common, name, 0),
        }
    }
}

/// The repository's git directory for `dir`: the nearest `.git` folder at or
/// above it, or where the nearest `.git` file (`gitdir: <path>`) points.
fn find_git_dir(dir: &Path) -> Option<PathBuf> {
    for folder in dir.ancestors() {
        let dot_git = folder.join(".git");
        if dot_git.is_dir() {
            return Some(dot_git);
        }
        if dot_git.is_file() {
            let text = read_trimmed(&dot_git)?;
            let target = text.strip_prefix("gitdir:")?.trim();
            return Some(folder.join(target));
        }
    }
    None
}

/// Where the shared refs live: a linked worktree's `commondir`, else the
/// git directory itself.
fn common_dir(git_dir: &Path) -> PathBuf {
    match read_trimmed(&git_dir.join("commondir")) {
        Some(common) => git_dir.join(common),
        None => git_dir.to_path_buf(),
    }
}

/// The commit `name` points to: its loose ref in the worktree's git
/// directory or the shared one, else its `packed-refs` line.
fn resolve_ref(git_dir: &Path, common: &Path, name: &str, depth: usize) -> Option<String> {
    if depth > MAX_REF_DEPTH || name.split('/').any(|part| part.is_empty() || part == "..") {
        return None;
    }
    let loose = read_trimmed(&git_dir.join(name)).or_else(|| read_trimmed(&common.join(name)));
    if let Some(text) = loose {
        return match text.strip_prefix("ref: ") {
            Some(next) => resolve_ref(git_dir, common, next.trim(), depth + 1),
            None => is_object_id(&text).then_some(text),
        };
    }
    let packed = std::fs::File::open(common.join("packed-refs")).ok()?;
    BufReader::new(packed).lines().map_while(Result::ok).find_map(|line| {
        let (id, ref_name) = line.split_once(' ')?;
        (ref_name.trim() == name && is_object_id(id)).then(|| id.to_owned())
    })
}

/// A SHA-1 or SHA-256 object id in git's lowercase hex.
fn is_object_id(text: &str) -> bool {
    matches!(text.len(), 40 | 64) && text.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

fn read_trimmed(path: &Path) -> Option<String> {
    let text = std::fs::read_to_string(path).ok()?;
    let text = text.trim();
    (!text.is_empty()).then(|| text.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;

    /// A fresh folder for one test, canonical (macOS's temp dir is a symlink).
    fn scratch(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("acpmux-git-state-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::canonicalize(dir).unwrap()
    }

    fn git(dir: &Path, args: &[&str]) -> String {
        let out = Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(["-c", "user.name=acpmux", "-c", "user.email=acpmux@example.com"])
            .args(["-c", "commit.gpgsign=false"])
            .args(args)
            .env_remove("GIT_DIR")
            .env_remove("GIT_WORK_TREE")
            .output()
            .unwrap();
        assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
        String::from_utf8_lossy(&out.stdout).trim().to_owned()
    }

    #[test]
    fn git_state_reads_a_subfolder_of_a_repository() {
        let dir = scratch("sub");
        git(&dir, &["init", "-q"]);
        git(&dir, &["checkout", "-q", "-b", "topic"]);
        git(&dir, &["commit", "-q", "--allow-empty", "-m", "init"]);
        let head = git(&dir, &["rev-parse", "HEAD"]);
        std::fs::create_dir_all(dir.join("a/b")).unwrap();
        let state = GitState::read(&dir.join("a/b"));
        assert_eq!(state, GitState { branch: Some("topic".into()), head: Some(head) });
    }

    #[test]
    fn git_state_reads_a_linked_worktree_with_packed_refs() {
        let dir = scratch("worktree");
        let main = dir.join("main");
        std::fs::create_dir_all(&main).unwrap();
        git(&main, &["init", "-q"]);
        git(&main, &["commit", "-q", "--allow-empty", "-m", "init"]);
        let linked = dir.join("linked");
        git(&main, &["worktree", "add", "-q", "-b", "side", linked.to_str().unwrap()]);
        git(&main, &["pack-refs", "--all"]);
        let head = git(&linked, &["rev-parse", "HEAD"]);
        let state = GitState::read(&linked);
        assert_eq!(state, GitState { branch: Some("side".into()), head: Some(head) });
    }

    #[test]
    fn git_state_of_a_branch_with_no_commit_has_no_head() {
        let dir = scratch("unborn");
        git(&dir, &["init", "-q"]);
        git(&dir, &["checkout", "-q", "-b", "fresh"]);
        let state = GitState::read(&dir);
        assert_eq!(state, GitState { branch: Some("fresh".into()), head: None });
    }
}

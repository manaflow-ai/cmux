//! A folder's git branch and HEAD commit, which session/new and session/fork
//! record in the session's meta (hq#1920: a session joins the pull request it
//! produced). Read from the repository's own files, never a git process, so
//! it costs a few small reads and cannot hang on a git that waits for input.
//!
//! The lookup finds `.git` in the folder or above it, follows a linked
//! worktree's or submodule's `gitdir:` file and its `commondir`, and resolves
//! HEAD through a loose ref, else `packed-refs`. Anything it cannot read
//! leaves that part `None`; it never fails the session.

use serde::{Deserialize, Serialize};
use std::fs::File;
use std::io::{BufRead, BufReader, Read};
use std::path::{Path, PathBuf};

/// Where a session's folder came from in git (`SessionMeta::worktree`; `hub/worktree_care/revive.rs`).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct WorktreeOrigin {
    pub cwd: PathBuf,
    pub root: PathBuf,
    pub common_dir: PathBuf,
    /// The branch checked out there: `None` on a detached HEAD, which comes back at `head`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub branch: Option<String>,
    /// Its commit then: a worktree whose branch is gone comes back there.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub head: Option<String>,
}

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
/// The most read of HEAD, a ref, `gitdir` or `commondir` (each one line).
const MAX_SMALL_FILE: u64 = 4 * 1024;
/// The most read of `packed-refs`.
const MAX_PACKED_REFS: u64 = 16 * 1024 * 1024;
/// The longest ref name taken as a branch.
const MAX_REF_NAME: usize = 1024;

impl GitState {
    /// The git state of `dir`, the folder a session runs in.
    pub fn read(dir: &Path) -> Self {
        // The physical folder, as git sees it: a symlinked folder walked by
        // name would miss its repository. A missing folder has no state.
        let Ok(dir) = std::fs::canonicalize(dir) else {
            return Self::default();
        };
        if !dir.is_dir() {
            return Self::default();
        }
        let Some(git_dir) = find_git_dir(&dir) else {
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
        // placeholder. Its branch and commit are unreadable here, as are a
        // name git would refuse (it is stored and shown to clients).
        if name == "refs/heads/.invalid" || !is_ref_name(name) {
            return Self::default();
        }
        Self {
            branch: name.strip_prefix("refs/heads/").map(str::to_owned),
            head: resolve_ref(&git_dir, &common, name, 0),
        }
    }
}

/// The linked worktree `dir` is in, canonical: its top folder and the repository's common git
/// directory, which outlives the worktree (`hub/worktree_care/revive.rs` adds it back from there).
/// `None` outside a repository, in a main checkout (its git directory goes with it) or in a
/// submodule.
pub fn linked_worktree(dir: &Path) -> Option<(PathBuf, PathBuf)> {
    let dir = std::fs::canonicalize(dir).ok()?;
    let top = dir.ancestors().find(|folder| folder.join(".git").exists())?;
    let dot_git = top.join(".git");
    if dot_git.is_dir() {
        return None;
    }
    let text = read_trimmed(&dot_git)?;
    let git_dir = top.join(text.strip_prefix("gitdir:")?.trim());
    let common = read_trimmed(&git_dir.join("commondir"))?;
    Some((top.to_path_buf(), std::fs::canonicalize(git_dir.join(common)).ok()?))
}

/// The folder holding `dir`'s HEAD file (its worktree's git directory, a
/// linked worktree's under `.git/worktrees/`), resolved as FSEvents reports
/// it, for a watch that sees a checkout (`hub/git_watch.rs`). `None` outside
/// a repository.
pub fn head_dir(dir: &Path) -> Option<PathBuf> {
    let dir = std::fs::canonicalize(dir).ok()?;
    std::fs::canonicalize(find_git_dir(&dir)?).ok()
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
    if depth > MAX_REF_DEPTH || !is_ref_name(name) {
        return None;
    }
    let loose = read_trimmed(&git_dir.join(name)).or_else(|| read_trimmed(&common.join(name)));
    if let Some(text) = loose {
        return match text.strip_prefix("ref: ") {
            Some(next) => resolve_ref(git_dir, common, next.trim(), depth + 1),
            None => is_object_id(&text).then_some(text),
        };
    }
    let packed = open_file(&common.join("packed-refs"))?.take(MAX_PACKED_REFS);
    BufReader::new(packed).lines().map_while(Result::ok).find_map(|line| {
        let (id, ref_name) = line.split_once(' ')?;
        (ref_name.trim() == name && is_object_id(id)).then(|| id.to_owned())
    })
}

/// A SHA-1 or SHA-256 object id in git's lowercase hex.
fn is_object_id(text: &str) -> bool {
    matches!(text.len(), 40 | 64) && text.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

/// A ref name git would accept as a path under the git directory: relative,
/// no empty, `.` or `..` part on either separator, no control characters.
fn is_ref_name(name: &str) -> bool {
    name.len() <= MAX_REF_NAME
        && !name.chars().any(char::is_control)
        && name.split(['/', '\\']).all(|part| !matches!(part, "" | "." | ".."))
        && !name.contains(':')
}

/// `path` opened for reading only when it is a regular file: a FIFO or a
/// device (a planted `.git` file or ref) would block or never end. Opened
/// without blocking, then checked on the open handle, so a swap between the
/// check and the open cannot slip one through.
fn open_file(path: &Path) -> Option<File> {
    let mut options = std::fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NONBLOCK);
    }
    let file = options.open(path).ok()?;
    file.metadata().ok()?.is_file().then_some(file)
}

fn read_trimmed(path: &Path) -> Option<String> {
    let mut text = String::new();
    open_file(path)?.take(MAX_SMALL_FILE).read_to_string(&mut text).ok()?;
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
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env_remove("GIT_DIR")
            .env_remove("GIT_WORK_TREE")
            .env_remove("GIT_COMMON_DIR")
            .env_remove("GIT_INDEX_FILE")
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

    /// A repository at `dir` on `branch` with one commit; returns that commit.
    fn repo(dir: &Path, branch: &str) -> String {
        git(dir, &["init", "-q"]);
        git(dir, &["checkout", "-q", "-b", branch]);
        git(dir, &["commit", "-q", "--allow-empty", "-m", "init"]);
        git(dir, &["rev-parse", "HEAD"])
    }

    #[cfg(unix)]
    #[test]
    fn git_state_follows_a_symlinked_folder_to_its_repository() {
        let dir = scratch("symlink");
        let main = dir.join("repo");
        std::fs::create_dir_all(main.join("sub")).unwrap();
        let head = repo(&main, "linked");
        let link = dir.join("link");
        std::os::unix::fs::symlink(main.join("sub"), &link).unwrap();
        let state = GitState::read(&link);
        assert_eq!(state, GitState { branch: Some("linked".into()), head: Some(head) });
    }

    #[test]
    fn a_linked_worktree_names_its_top_folder_and_common_git_dir() {
        let dir = scratch("linked-origin");
        let (main, linked) = (dir.join("main"), dir.join("wt"));
        std::fs::create_dir_all(&main).unwrap();
        repo(&main, "trunk");
        git(&main, &["worktree", "add", "-q", "-b", "side", linked.to_str().unwrap()]);
        std::fs::create_dir_all(linked.join("sub")).unwrap();
        let common = std::fs::canonicalize(main.join(".git")).unwrap();
        assert_eq!(linked_worktree(&linked), Some((linked.clone(), common.clone())));
        assert_eq!(linked_worktree(&linked.join("sub")), Some((linked, common)));
        // A main checkout's git directory goes with it: nothing to add back.
        assert_eq!(linked_worktree(&main), None);
        assert_eq!(linked_worktree(&dir.join("gone")), None);
    }

    #[test]
    fn git_state_of_a_missing_folder_is_empty() {
        let dir = scratch("missing");
        repo(&dir, "topic");
        assert_eq!(GitState::read(&dir.join("gone")), GitState::default());
    }

    #[test]
    fn git_state_drops_a_branch_name_git_would_refuse() {
        let dir = scratch("badref");
        repo(&dir, "topic");
        for name in ["refs/heads/../../x", "refs/heads/a\u{1b}[31mb", "refs/heads/a\\..\\b"] {
            std::fs::write(dir.join(".git/HEAD"), format!("ref: {name}\n")).unwrap();
            assert_eq!(GitState::read(&dir).branch, None, "{name:?}");
        }
    }

    /// A HEAD that is a FIFO (or a device) is skipped, not read: reading it
    /// would block session/new forever.
    #[cfg(unix)]
    #[test]
    fn git_state_skips_a_head_that_is_not_a_regular_file() {
        let dir = scratch("fifo");
        repo(&dir, "topic");
        let head = dir.join(".git/HEAD");
        std::fs::remove_file(&head).unwrap();
        let path = std::ffi::CString::new(head.to_str().unwrap()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0);
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || tx.send(GitState::read(&dir)).unwrap());
        let state =
            rx.recv_timeout(std::time::Duration::from_secs(5)).expect("read hung on a FIFO");
        assert_eq!(state, GitState::default());
    }
}

use super::*;
use std::process::Command;

/// A fresh folder for one test, canonical (macOS's temp dir is a symlink).
fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("acpmux-git-state-{}-{name}", std::process::id()));
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
fn origin_repo_reads_the_origin_remote_of_a_checkout_and_its_worktrees() {
    let dir = scratch("origin");
    repo(&dir, "main");
    git(&dir, &["remote", "add", "upstream", "https://github.com/other/fork.git"]);
    git(&dir, &["remote", "add", "origin", "git@github.com:acme/widgets.git"]);
    let sub = dir.join("src");
    std::fs::create_dir_all(&sub).unwrap();
    assert_eq!(origin_repo(&sub).as_deref(), Some("acme/widgets"));
    let linked = dir.with_extension("linked");
    git(&dir, &["worktree", "add", "-b", "side", linked.to_str().unwrap()]);
    assert_eq!(origin_repo(&linked).as_deref(), Some("acme/widgets"));
    assert_eq!(github_repo("https://github.com/o/n/").as_deref(), Some("o/n"));
    assert_eq!(github_repo("ssh://git@github.com/o/n.git").as_deref(), Some("o/n"));
    assert!(github_repo("https://gitlab.com/o/n").is_none());
    assert!(origin_repo(&std::env::temp_dir().join("no-such-acpmux-dir")).is_none());
    let _ = std::fs::remove_dir_all(&dir);
    let _ = std::fs::remove_dir_all(&linked);
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
    let state = rx.recv_timeout(std::time::Duration::from_secs(5)).expect("read hung on a FIFO");
    assert_eq!(state, GitState::default());
}

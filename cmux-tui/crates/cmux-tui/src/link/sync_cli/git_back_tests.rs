use std::fs;
use std::path::Path;
use std::process::Command;
use std::time::{Duration, Instant};

use super::*;

fn git(folder: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .arg("-C")
        .arg(folder)
        .args(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"])
        .args(args)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .output()
        .unwrap();
    assert!(output.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&output.stderr));
    String::from_utf8(output.stdout).unwrap().trim().to_owned()
}

/// A repository on `main` at its first commit, with a second commit (the
/// machine's) in its object store: a plan that moves the branch to it and
/// stages its tree.
fn repo_and_plan() -> (tempfile::TempDir, GitPlan, String) {
    let dir = tempfile::tempdir().unwrap();
    let folder = dir.path();
    git(folder, &["init", "-q", "-b", "main"]);
    fs::write(folder.join("a.txt"), "one\n").unwrap();
    git(folder, &["add", "a.txt"]);
    git(folder, &["commit", "-q", "-m", "first"]);
    let first = git(folder, &["rev-parse", "HEAD"]);
    fs::write(folder.join("a.txt"), "two\n").unwrap();
    git(folder, &["add", "a.txt"]);
    git(folder, &["commit", "-q", "-m", "the machine's"]);
    let theirs = git(folder, &["rev-parse", "HEAD"]);
    git(folder, &["reset", "-q", "--hard", &first]);
    let local = base_of(folder).unwrap();
    let plan = GitPlan {
        quarantine: folder.join("unused"),
        local: local.clone(),
        head: Some(theirs.clone()),
        staged: Some(theirs.clone()),
        settled: local,
    };
    (dir, plan, theirs)
}

/// Holds `lock` (a file in `.git`) as this Mac's own git would, for `held`.
fn hold(folder: &Path, lock: &str, held: Duration) -> std::thread::JoinHandle<()> {
    let path = folder.join(".git").join(lock);
    fs::write(&path, "").unwrap();
    std::thread::spawn(move || {
        std::thread::sleep(held);
        fs::remove_file(path).unwrap();
    })
}

/// Bring Back while this Mac's git holds the index for a moment (a `git
/// status`, `add` or `commit` beside the pull): the pull waits for it, then
/// stages the machine's changes. It failed at once ("Unable to create
/// .git/index.lock: File exists") and undid the whole pull.
#[test]
fn a_pull_waits_for_the_index_this_macs_git_holds() {
    let (dir, plan, theirs) = repo_and_plan();
    let released = hold(dir.path(), "index.lock", Duration::from_millis(600));
    assert!(plan.commit(dir.path()).unwrap());
    released.join().unwrap();
    assert_eq!(git(dir.path(), &["rev-parse", "HEAD"]), theirs);
    assert_eq!(git(dir.path(), &["show", ":a.txt"]), "two");
}

/// The same for the branch's own lock (a `git commit` moving it): git waited
/// only 100 ms for it.
#[test]
fn a_pull_waits_for_the_branch_this_macs_git_holds() {
    let (dir, plan, theirs) = repo_and_plan();
    let released = hold(dir.path(), "refs/heads/main.lock", Duration::from_millis(600));
    assert!(plan.commit(dir.path()).unwrap());
    released.join().unwrap();
    assert_eq!(git(dir.path(), &["rev-parse", "HEAD"]), theirs);
}

/// A lock that stays (a git that crashed and left it): the pull fails within
/// the wait and leaves the branch where it was.
#[test]
fn a_lock_that_stays_fails_the_pull_and_moves_nothing() {
    let (dir, plan, _) = repo_and_plan();
    let before = git(dir.path(), &["rev-parse", "HEAD"]);
    fs::write(dir.path().join(".git/index.lock"), "").unwrap();
    let started = Instant::now();
    assert!(plan.commit(dir.path()).is_err());
    assert!(started.elapsed() < Duration::from_secs(15));
    assert_eq!(git(dir.path(), &["rev-parse", "HEAD"]), before);
}

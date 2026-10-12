//! `cmux git commit` and `cmux git push` through a real daemon: the session
//! host commits and pushes in a real repository with a local bare remote.
#![cfg(unix)]

use super::*;

fn git(dir: &std::path::Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .env("GIT_TERMINAL_PROMPT", "0")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "git {args:?} failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}

fn git_cli(server: &HeadlessServer, cwd: &std::path::Path, args: &[&str]) -> Output {
    Command::new(bin())
        .current_dir(cwd)
        .args(["--json", "--socket"])
        .arg(&server.socket)
        .arg("git")
        .args(args)
        .env("LC_ALL", "C")
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .output()
        .unwrap()
}

#[test]
fn git_commit_and_push_run_in_the_repository_through_a_real_daemon() {
    let server = HeadlessServer::start("git-write");
    let root = std::env::temp_dir().join(format!(
        "cmux-git-write-{}-{:x}",
        std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
    ));
    let repo = root.join("repo");
    let remote = root.join("remote.git");
    fs::create_dir_all(&repo).unwrap();
    git(&root, &["init", "-q", "--bare", remote.to_str().unwrap()]);
    git(&repo, &["init", "-q", "-b", "main"]);
    git(&repo, &["config", "user.name", "cmux test"]);
    git(&repo, &["config", "user.email", "cmux@example.invalid"]);
    git(&repo, &["config", "commit.gpgsign", "false"]);
    fs::write(repo.join("a.txt"), "one\n").unwrap();
    git(&repo, &["add", "a.txt"]);
    git(&repo, &["commit", "-q", "-m", "first"]);
    git(&repo, &["remote", "add", "origin", remote.to_str().unwrap()]);

    // Nothing to commit is refused and makes no commit.
    let empty = git_cli(&server, &repo, &["commit", "--message", "nothing", "--all"]);
    assert!(!empty.status.success(), "{}", String::from_utf8_lossy(&empty.stdout));
    let reason = String::from_utf8_lossy(&empty.stderr).to_string();
    assert!(reason.contains("nothing_to_commit"), "{reason}");
    assert_eq!(git(&repo, &["rev-list", "--count", "HEAD"]), "1");

    // A path outside the repository is refused.
    fs::write(repo.join("a.txt"), "outside\n").unwrap();
    let outside = git_cli(&server, &repo, &["commit", "--message", "escape", "../remote.git"]);
    assert!(!outside.status.success(), "a path outside the repository was accepted");
    assert_eq!(git(&repo, &["rev-list", "--count", "HEAD"]), "1");
    git(&repo, &["checkout", "-q", "--", "a.txt"]);

    // --all commits the tracked change; a new file stays out without
    // --include-untracked.
    fs::write(repo.join("a.txt"), "two\n").unwrap();
    fs::write(repo.join("new.txt"), "new\n").unwrap();
    let key = ["--idempotency-key", "commit-second"];
    let args = ["commit", "--message", "second", "--all", key[0], key[1]];
    let committed = git_cli(&server, &repo, &args);
    assert_success(&committed);
    // A retry with the same key replays the first result: no second commit.
    fs::write(repo.join("a.txt"), "three\n").unwrap();
    let replayed = git_cli(&server, &repo, &args);
    assert_success(&replayed);
    assert_eq!(
        json_output(&replayed)["replayed"],
        true,
        "{}",
        String::from_utf8_lossy(&replayed.stdout)
    );
    assert_eq!(git(&repo, &["rev-list", "--count", "HEAD"]), "2");
    fs::write(repo.join("a.txt"), "two\n").unwrap();
    assert_eq!(git(&repo, &["log", "-1", "--format=%s"]), "second");
    assert_eq!(git(&repo, &["show", "HEAD:a.txt"]), "two");
    assert_eq!(git(&repo, &["status", "--porcelain"]), "?? new.txt");

    // Push creates and tracks the upstream.
    let pushed = git_cli(&server, &repo, &["push", "--set-upstream"]);
    assert_success(&pushed);
    assert_eq!(git(&remote, &["rev-parse", "refs/heads/main"]), git(&repo, &["rev-parse", "HEAD"]));
    assert_eq!(git(&repo, &["rev-parse", "--abbrev-ref", "main@{upstream}"]), "origin/main");

    // A push the remote would have to force is refused.
    git(&repo, &["commit", "-q", "--amend", "-m", "second, amended"]);
    let refused = git_cli(&server, &repo, &["push"]);
    assert!(!refused.status.success(), "a non-fast-forward push was accepted");
    assert_ne!(git(&remote, &["rev-parse", "refs/heads/main"]), git(&repo, &["rev-parse", "HEAD"]));
    let _ = fs::remove_dir_all(root);
}

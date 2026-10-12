//! `cmux git worktree create` through a real daemon: the session host makes
//! a chat's worktree on a new branch beside the user's checkout, which it
//! leaves untouched.
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
fn git_worktree_create_makes_a_branch_worktree_and_leaves_the_checkout_alone() {
    let root = std::env::temp_dir().join(format!(
        "cmux-git-worktree-{}-{:x}",
        std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
    ));
    let home = root.join("home");
    let repo = root.join("project");
    fs::create_dir_all(&home).unwrap();
    fs::create_dir_all(&repo).unwrap();
    let server = HeadlessServer::start_with_options(
        "git-worktree",
        None,
        None,
        &[("HOME", home.to_str().unwrap())],
    );
    git(&repo, &["init", "-q", "-b", "main"]);
    git(&repo, &["config", "user.name", "cmux test"]);
    git(&repo, &["config", "user.email", "cmux@example.invalid"]);
    git(&repo, &["config", "commit.gpgsign", "false"]);
    fs::write(repo.join("a.txt"), "one\n").unwrap();
    git(&repo, &["add", "a.txt"]);
    git(&repo, &["commit", "-q", "-m", "first"]);
    let base = git(&repo, &["rev-parse", "HEAD"]);
    // The user's uncommitted work stays in their checkout.
    fs::write(repo.join("a.txt"), "dirty\n").unwrap();

    let args = ["worktree", "create", "--name", "Fix login!", "--idempotency-key", "wt-one"];
    let created = git_cli(&server, &repo, &args);
    assert_success(&created);
    let value = json_output(&created)["value"].clone();
    let worktree = home.join(".cmux/worktrees/project/fix-login");
    assert_eq!(value["root"], worktree.to_str().unwrap(), "{value}");
    assert_eq!(value["branch"], "cmux/fix-login", "{value}");
    assert_eq!(value["base"], "main", "{value}");
    assert_eq!(value["base_commit"], base.as_str(), "{value}");
    assert_eq!(value["main_root"], fs::canonicalize(&repo).unwrap().to_str().unwrap());
    assert_eq!(git(&worktree, &["rev-parse", "--abbrev-ref", "HEAD"]), "cmux/fix-login");
    assert_eq!(git(&worktree, &["rev-parse", "HEAD"]), base);
    assert_eq!(fs::read_to_string(worktree.join("a.txt")).unwrap(), "one\n");
    assert_eq!(git(&repo, &["config", "--get", "branch.cmux/fix-login.cmuxBase"]), "main");
    assert_eq!(git(&repo, &["rev-parse", "--abbrev-ref", "HEAD"]), "main");
    assert_eq!(fs::read_to_string(repo.join("a.txt")).unwrap(), "dirty\n");

    // A retry with the same key replays the first result: no second worktree.
    let replayed = git_cli(&server, &repo, &args);
    assert_success(&replayed);
    assert_eq!(json_output(&replayed)["replayed"], true);
    assert_eq!(json_output(&replayed)["value"]["root"], worktree.to_str().unwrap());
    let listed = git(&repo, &["worktree", "list", "--porcelain"]);
    assert_eq!(listed.matches("worktree ").count(), 2, "{listed}");

    // The same name again gets the next free one; one made from inside a
    // worktree branches from that worktree's branch and sits beside it.
    let again = ["worktree", "create", "--name", "fix login", "--idempotency-key", "wt-two"];
    let second = git_cli(&server, &worktree, &again);
    assert_success(&second);
    let value = json_output(&second)["value"].clone();
    assert_eq!(value["branch"], "cmux/fix-login-2", "{value}");
    assert_eq!(value["base"], "cmux/fix-login", "{value}");
    assert_eq!(value["root"], home.join(".cmux/worktrees/project/fix-login-2").to_str().unwrap());

    // Without a name it picks one; a base that names nothing is refused.
    let unnamed = git_cli(&server, &repo, &["worktree", "create", "--idempotency-key", "wt-three"]);
    assert_success(&unnamed);
    let branch = json_output(&unnamed)["value"]["branch"].as_str().unwrap().to_string();
    assert!(branch.starts_with("cmux/chat-"), "{branch}");
    let missing = ["worktree", "create", "--base", "nope", "--idempotency-key", "wt-four"];
    let refused = git_cli(&server, &repo, &missing);
    assert!(!refused.status.success(), "a missing base was accepted");
    let reason = String::from_utf8_lossy(&refused.stderr).to_string();
    assert!(reason.contains("base_not_found"), "{reason}");
    let _ = fs::remove_dir_all(root);
}

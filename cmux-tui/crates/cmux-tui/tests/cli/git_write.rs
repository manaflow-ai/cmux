//! `cmux git commit`, `cmux git push` and `cmux git worktree
//! create|apply|remove` through a real daemon: the session host commits and
//! pushes in a real repository with a local bare remote, makes a chat's
//! worktree on a new branch beside the user's checkout, which it leaves
//! untouched, applies that worktree's work back to the checkout as
//! uncommitted changes, and removes the worktree without losing work.
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
    let missing_remote = git_cli(&server, &repo, &["push"]);
    assert!(!missing_remote.status.success());
    assert!(String::from_utf8_lossy(&missing_remote.stderr).contains("no_remote"));
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

    // Create PR pushes even an already-published branch. A configured
    // same-branch refspec must not make that ordinary push fail.
    git(&repo, &["config", "remote.origin.push", "refs/heads/main:refs/heads/main"]);
    assert_success(&git_cli(&server, &repo, &["push"]));

    // A push the remote would have to force is refused.
    git(&repo, &["commit", "-q", "--amend", "-m", "second, amended"]);
    let refused = git_cli(&server, &repo, &["push"]);
    assert!(!refused.status.success(), "a non-fast-forward push was accepted");
    assert_ne!(git(&remote, &["rev-parse", "refs/heads/main"]), git(&repo, &["rev-parse", "HEAD"]));
    // A fresh branch also uses the repository's sole remote when it is not origin.
    git(&repo, &["config", "--unset-all", "remote.origin.push"]);
    git(&repo, &["remote", "rename", "origin", "publish"]);
    git(&repo, &["checkout", "-q", "-b", "feature"]);
    let fresh = git_cli(&server, &repo, &["push"]);
    assert_success(&fresh);
    assert_eq!(git(&repo, &["rev-parse", "--abbrev-ref", "feature@{upstream}"]), "publish/feature");
    assert_eq!(
        git(&remote, &["rev-parse", "refs/heads/feature"]),
        git(&repo, &["rev-parse", "HEAD"])
    );

    // A differently named upstream is ambiguous: it may be a renamed branch,
    // or the base a fresh feature branched from. Never update it implicitly.
    git(&repo, &["push", "publish", "feature:published"]);
    git(&repo, &["checkout", "-q", "-b", "local-feature", "feature"]);
    git(&repo, &["branch", "--set-upstream-to=publish/published"]);
    fs::write(repo.join("a.txt"), "renamed branch\n").unwrap();
    git(&repo, &["commit", "-q", "-am", "local change"]);
    let published = git_cli(&server, &repo, &["push"]);
    assert!(!published.status.success());
    assert!(String::from_utf8_lossy(&published.stderr).contains("upstream_mismatch"));
    assert_eq!(
        git(&remote, &["rev-parse", "refs/heads/published"]),
        git(&repo, &["rev-parse", "feature"])
    );
    assert_eq!(
        git(&repo, &["rev-parse", "--abbrev-ref", "local-feature@{upstream}"]),
        "publish/published"
    );

    git(&repo, &["checkout", "-q", "-b", "fresh-from-main", "publish/main"]);
    git(&repo, &["config", "push.default", "simple"]);
    let base = git(&remote, &["rev-parse", "refs/heads/main"]);
    git(&repo, &["commit", "-q", "--allow-empty", "-m", "feature work"]);
    let refused = git_cli(&server, &repo, &["push"]);
    assert!(!refused.status.success());
    assert!(String::from_utf8_lossy(&refused.stderr).contains("upstream_mismatch"));
    assert_eq!(git(&remote, &["rev-parse", "refs/heads/main"]), base);
    assert_eq!(git(&remote, &["branch", "--list", "fresh-from-main"]), "");
    // Explicitly choosing the same-named destination creates the feature
    // branch and updates its tracking config without touching main.
    assert_success(&git_cli(&server, &repo, &["push", "--set-upstream"]));
    assert_eq!(git(&remote, &["rev-parse", "refs/heads/main"]), base);
    assert_eq!(
        git(&remote, &["rev-parse", "refs/heads/fresh-from-main"]),
        git(&repo, &["rev-parse", "HEAD"])
    );
    assert_eq!(
        git(&repo, &["rev-parse", "--abbrev-ref", "fresh-from-main@{upstream}"]),
        "publish/fresh-from-main"
    );
    // A separate push remote is a deliberate triangular setup. It receives
    // the local feature name even when the branch tracks the base elsewhere.
    let fork = root.join("fork.git");
    git(&root, &["init", "-q", "--bare", fork.to_str().unwrap()]);
    git(&repo, &["remote", "add", "fork", fork.to_str().unwrap()]);
    git(&repo, &["checkout", "-q", "-b", "fork-feature", "publish/main"]);
    git(&repo, &["config", "branch.fork-feature.pushRemote", "fork"]);
    git(&repo, &["commit", "-q", "--allow-empty", "-m", "fork feature work"]);
    assert_success(&git_cli(&server, &repo, &["push"]));
    assert_eq!(git(&remote, &["rev-parse", "refs/heads/main"]), base);
    assert_eq!(git(&fork, &["branch", "--list", "main"]), "");
    assert_eq!(
        git(&fork, &["rev-parse", "refs/heads/fork-feature"]),
        git(&repo, &["rev-parse", "HEAD"])
    );
    let _ = fs::remove_dir_all(root);
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

#[test]
fn a_worktree_chats_status_and_branch_diff_follow_its_recorded_base() {
    let root = std::env::temp_dir().join(format!(
        "cmux-git-worktree-base-{}-{:x}",
        std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
    ));
    let home = root.join("home");
    let repo = root.join("project");
    fs::create_dir_all(&home).unwrap();
    fs::create_dir_all(&repo).unwrap();
    let server = HeadlessServer::start_with_options(
        "git-worktree-base",
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
    // A feature branch a commit past main: the chat branches from it.
    git(&repo, &["checkout", "-q", "-b", "feature"]);
    fs::write(repo.join("f.txt"), "feature\n").unwrap();
    git(&repo, &["add", "f.txt"]);
    git(&repo, &["commit", "-q", "-m", "feature"]);
    git(&repo, &["checkout", "-q", "main"]);

    let args =
        ["worktree", "create", "--name", "chat", "--base", "feature", "--idempotency-key", "b1"];
    let created = git_cli(&server, &repo, &args);
    assert_success(&created);
    let worktree = home.join(".cmux/worktrees/project/chat");
    fs::write(worktree.join("w.txt"), "work\n").unwrap();
    git(&worktree, &["add", "w.txt"]);
    git(&worktree, &["commit", "-q", "-m", "work"]);

    // The worktree's status names the checkout it belongs to and the base it was made from.
    let status = git_cli(&server, &worktree, &["status"]);
    assert_success(&status);
    let status = json_output(&status);
    assert_eq!(status["branch"], "cmux/chat", "{status}");
    assert_eq!(status["base"], "feature", "{status}");
    let main = fs::canonicalize(&repo).unwrap();
    assert_eq!(status["worktree"]["main_root"], main.to_str().unwrap(), "{status}");

    // Its branch diff starts where the chat started: only the chat's own work.
    let diff = git_cli(&server, &worktree, &["diff", "--scope", "branch"]);
    assert_success(&diff);
    let diff = json_output(&diff);
    let paths: Vec<&str> =
        diff["files"].as_array().unwrap().iter().filter_map(|file| file["path"].as_str()).collect();
    assert_eq!(paths, ["w.txt"], "{diff}");

    // The main checkout is no linked worktree and keeps its own base.
    let status = json_output(&git_cli(&server, &repo, &["status"]));
    assert!(status.get("worktree").is_none(), "{status}");
    assert_eq!(status["base"], "main", "{status}");

    // A base past a branch (`feature~1`) is no branch: the chat keeps the commit it named then,
    // even after the branch moves on.
    let first = git(&repo, &["rev-parse", "feature~1"]);
    let args =
        ["worktree", "create", "--name", "past", "--base", "feature~1", "--idempotency-key", "b2"];
    assert_success(&git_cli(&server, &repo, &args));
    git(&repo, &["checkout", "-q", "feature"]);
    fs::write(repo.join("g.txt"), "more\n").unwrap();
    git(&repo, &["add", "g.txt"]);
    git(&repo, &["commit", "-q", "-m", "more"]);
    let past = home.join(".cmux/worktrees/project/past");
    let status = json_output(&git_cli(&server, &past, &["status"]));
    assert_eq!(status["base"], first.trim(), "{status}");
    let _ = fs::remove_dir_all(root);
}

#[test]
fn a_worktree_chats_work_applies_to_the_main_checkout_as_uncommitted_changes() {
    let root = std::env::temp_dir().join(format!(
        "cmux-git-worktree-apply-{}-{:x}",
        std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
    ));
    let home = root.join("home");
    let repo = root.join("project");
    fs::create_dir_all(&home).unwrap();
    fs::create_dir_all(&repo).unwrap();
    let server = HeadlessServer::start_with_options(
        "git-worktree-apply",
        None,
        None,
        &[("HOME", home.to_str().unwrap())],
    );
    git(&repo, &["init", "-q", "-b", "main"]);
    git(&repo, &["config", "user.name", "cmux test"]);
    git(&repo, &["config", "user.email", "cmux@example.invalid"]);
    git(&repo, &["config", "commit.gpgsign", "false"]);
    fs::write(repo.join("a.txt"), "one\n").unwrap();
    fs::write(repo.join("gone.txt"), "old\n").unwrap();
    git(&repo, &["add", "a.txt", "gone.txt"]);
    git(&repo, &["commit", "-q", "-m", "first"]);
    let head = git(&repo, &["rev-parse", "HEAD"]);
    // The user's own diff and apply settings change nothing about what lands.
    git(&repo, &["config", "diff.noprefix", "true"]);
    git(&repo, &["config", "apply.whitespace", "error"]);

    let args = ["worktree", "create", "--name", "chat", "--idempotency-key", "c1"];
    assert_success(&git_cli(&server, &repo, &args));
    let worktree = home.join(".cmux/worktrees/project/chat");
    // The chat's work: a commit, an uncommitted edit, a deletion and a new file it never added.
    fs::write(worktree.join("a.txt"), "two\n").unwrap();
    git(&worktree, &["commit", "-q", "-am", "work"]);
    fs::write(worktree.join("a.txt"), "three\n").unwrap();
    fs::remove_file(worktree.join("gone.txt")).unwrap();
    fs::write(worktree.join("new.txt"), "new\n").unwrap();
    fs::create_dir_all(worktree.join("src/lib")).unwrap();
    fs::write(worktree.join("src/lib/new.rs"), "fn f() {} \n").unwrap();

    let apply = ["worktree", "apply", "--idempotency-key", "a1"];
    let applied = git_cli(&server, &worktree, &apply);
    assert_success(&applied);
    let value = json_output(&applied);
    assert_eq!(value["replayed"], false, "{value}");
    let main = fs::canonicalize(&repo).unwrap();
    assert_eq!(value["value"]["main_root"], main.to_str().unwrap(), "{value}");
    let mut files: Vec<&str> = value["value"]["files"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|file| file.as_str())
        .collect();
    files.sort_unstable();
    assert_eq!(files, ["a.txt", "gone.txt", "new.txt", "src/lib/new.rs"], "{value}");

    // The main checkout has the chat's work as changes of its own: HEAD and the index stay.
    assert_eq!(fs::read_to_string(repo.join("a.txt")).unwrap(), "three\n");
    assert!(!repo.join("gone.txt").exists());
    assert_eq!(fs::read_to_string(repo.join("new.txt")).unwrap(), "new\n");
    assert_eq!(fs::read_to_string(repo.join("src/lib/new.rs")).unwrap(), "fn f() {} \n");
    assert_eq!(git(&repo, &["rev-parse", "HEAD"]), head);
    assert_eq!(git(&repo, &["diff", "--cached", "--name-only"]), "");
    // The worktree is as the chat left it: its new file is still its own, never added.
    assert_eq!(git(&worktree, &["status", "--porcelain", "--", "new.txt"]), "?? new.txt");

    // A lost reply's retry replays; it does not apply twice.
    let again = json_output(&git_cli(&server, &worktree, &apply));
    assert_eq!(again["replayed"], true, "{again}");
    assert_eq!(fs::read_to_string(repo.join("a.txt")).unwrap(), "three\n");

    // A main checkout with its own changes to those files is refused and left as it was.
    git(&repo, &["checkout", "-q", "--", "."]);
    fs::remove_file(repo.join("new.txt")).unwrap();
    fs::remove_dir_all(repo.join("src")).unwrap();
    fs::write(repo.join("a.txt"), "mine\n").unwrap();
    let args = ["worktree", "apply", "--idempotency-key", "a2"];
    let refused = git_cli(&server, &worktree, &args);
    assert!(!refused.status.success(), "an apply over the user's own edits was accepted");
    let reason = String::from_utf8_lossy(&refused.stderr).to_string();
    assert!(reason.contains("main_checkout_changed"), "{reason}");
    assert_eq!(fs::read_to_string(repo.join("a.txt")).unwrap(), "mine\n");
    assert!(repo.join("gone.txt").exists());
    assert!(!repo.join("new.txt").exists());

    // The main checkout itself has no worktree to apply.
    let args = ["worktree", "apply", "--idempotency-key", "a3"];
    let refused = git_cli(&server, &repo, &args);
    assert!(!refused.status.success(), "the main checkout applied to itself");
    let reason = String::from_utf8_lossy(&refused.stderr).to_string();
    assert!(reason.contains("not_a_worktree"), "{reason}");
    let _ = fs::remove_dir_all(root);
}

#[test]
fn removing_a_worktree_chat_keeps_unsaved_work_unless_told_to_discard_it() {
    let root = std::env::temp_dir().join(format!(
        "cmux-git-worktree-remove-{}-{:x}",
        std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
    ));
    let home = root.join("home");
    let repo = root.join("project");
    fs::create_dir_all(&home).unwrap();
    fs::create_dir_all(&repo).unwrap();
    let server = HeadlessServer::start_with_options(
        "git-worktree-remove",
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
    let create = |name: &str, key: &str| {
        let args = ["worktree", "create", "--name", name, "--idempotency-key", key];
        assert_success(&git_cli(&server, &repo, &args));
        home.join(".cmux/worktrees/project").join(name)
    };
    let reason = |output: &Output| String::from_utf8_lossy(&output.stderr).to_string();

    // A chat's worktree with a commit of its own and a file it never added.
    let worktree = create("chat", "c1");
    fs::write(worktree.join("a.txt"), "two\n").unwrap();
    git(&worktree, &["commit", "-q", "-am", "work"]);
    fs::write(worktree.join("notes.txt"), "draft\n").unwrap();

    // Its uncommitted work keeps it.
    let refused = git_cli(&server, &worktree, &["worktree", "remove", "--idempotency-key", "r1"]);
    assert!(!refused.status.success(), "a worktree with uncommitted work was removed");
    assert!(reason(&refused).contains("uncommitted_changes"), "{}", reason(&refused));
    assert!(worktree.join("notes.txt").exists());

    // So does a commit that is on no remote and not on its base.
    fs::remove_file(worktree.join("notes.txt")).unwrap();
    let refused = git_cli(&server, &worktree, &["worktree", "remove", "--idempotency-key", "r2"]);
    assert!(!refused.status.success(), "a worktree with unpushed commits was removed");
    assert!(reason(&refused).contains("unpushed_commits"), "{}", reason(&refused));
    assert!(worktree.exists());

    // Told to discard it, the worktree, its branch and its recorded base go; the checkout stays.
    let args = ["worktree", "remove", "--discard", "--idempotency-key", "r3"];
    let removed = git_cli(&server, &worktree, &args);
    assert_success(&removed);
    let value = json_output(&removed);
    assert_eq!(value["value"]["branch"], "cmux/chat", "{value}");
    assert_eq!(value["value"]["branch_deleted"], true, "{value}");
    assert!(!worktree.exists());
    let branches = git(&repo, &["branch", "--list", "cmux/chat"]);
    assert_eq!(branches, "");
    let listed = git(&repo, &["worktree", "list", "--porcelain"]);
    assert!(!listed.contains("cmux/chat"), "{listed}");
    let config = Command::new("git")
        .arg("-C")
        .arg(&repo)
        .args(["config", "--get", "branch.cmux/chat.cmuxBase"])
        .output()
        .unwrap();
    assert!(!config.status.success(), "the recorded base outlived its branch");
    assert_eq!(fs::read_to_string(repo.join("a.txt")).unwrap(), "one\n");

    // A worktree with nothing of its own goes without asking.
    let clean = create("clean", "c2");
    let args = ["worktree", "remove", "--idempotency-key", "r4"];
    assert_success(&git_cli(&server, &clean, &args));
    assert!(!clean.exists());
    assert_eq!(git(&repo, &["branch", "--list", "cmux/clean"]), "");

    // Commits on a detached HEAD live only there: they keep it too.
    let detached = create("detached", "c3");
    git(&detached, &["checkout", "-q", "--detach"]);
    fs::write(detached.join("a.txt"), "three\n").unwrap();
    git(&detached, &["commit", "-q", "-am", "detached work"]);
    let args = ["worktree", "remove", "--idempotency-key", "r6"];
    let refused = git_cli(&server, &detached, &args);
    assert!(!refused.status.success(), "a detached HEAD's commits were removed");
    assert!(reason(&refused).contains("unpushed_commits"), "{}", reason(&refused));
    assert!(detached.exists());

    // The main checkout is no worktree to remove.
    let args = ["worktree", "remove", "--discard", "--idempotency-key", "r5"];
    let refused = git_cli(&server, &repo, &args);
    assert!(!refused.status.success(), "the main checkout was removed");
    assert!(reason(&refused).contains("not_a_worktree"), "{}", reason(&refused));
    assert!(repo.join("a.txt").exists());
    let _ = fs::remove_dir_all(root);
}

/// Sets `path`'s modification time far in the past, so git hashes it again
/// (through its clean filter) instead of trusting the index.
fn make_stat_dirty(path: &std::path::Path) {
    let old = UNIX_EPOCH + Duration::from_secs(978_307_200);
    fs::File::options().write(true).open(path).and_then(|file| file.set_modified(old)).unwrap();
}

#[test]
fn applying_a_worktree_runs_no_clean_filter_from_the_main_checkouts_config() {
    let root = std::env::temp_dir().join(format!(
        "cmux-git-worktree-apply-filter-{}-{:x}",
        std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
    ));
    let home = root.join("home");
    let repo = root.join("project");
    let marker = root.join("marker");
    fs::create_dir_all(&home).unwrap();
    fs::create_dir_all(&repo).unwrap();
    let server = HeadlessServer::start_with_options(
        "git-worktree-apply-filter",
        None,
        None,
        &[("HOME", home.to_str().unwrap())],
    );
    git(&repo, &["init", "-q", "-b", "main"]);
    git(&repo, &["config", "user.name", "cmux test"]);
    git(&repo, &["config", "user.email", "cmux@example.invalid"]);
    git(&repo, &["config", "commit.gpgsign", "false"]);
    fs::write(repo.join(".gitattributes"), "b.txt filter=m\n").unwrap();
    fs::write(repo.join("a.txt"), "one\n").unwrap();
    fs::write(repo.join("b.txt"), "kept\n").unwrap();
    git(&repo, &["add", "."]);
    git(&repo, &["commit", "-q", "-m", "first"]);
    let args = ["worktree", "create", "--name", "chat", "--idempotency-key", "c1"];
    assert_success(&git_cli(&server, &repo, &args));
    let worktree = home.join(".cmux/worktrees/project/chat");
    fs::write(worktree.join("a.txt"), "two\n").unwrap();

    // The main checkout's own clean filter (not the worktree's), and a file
    // there git must hash again.
    git(&repo, &["config", "extensions.worktreeConfig", "true"]);
    let clean = format!("touch '{}'; cat", marker.display());
    git(&repo, &["config", "--worktree", "filter.m.clean", clean.as_str()]);
    make_stat_dirty(&repo.join("b.txt"));

    let applied = git_cli(&server, &worktree, &["worktree", "apply", "--idempotency-key", "a1"]);
    assert_success(&applied);
    assert_eq!(fs::read_to_string(repo.join("a.txt")).unwrap(), "two\n");
    assert!(!marker.exists(), "checking the main checkout ran its clean filter");
    let _ = fs::remove_dir_all(root);
}

/// Git trusts a file's stat data only when the file changed before the index
/// was written; a change made in the index's own second ("racy git") is
/// hashed again. So an edit of the same size, made in the second the
/// worktree's index was written, must still be applied when the apply comes
/// a second later (the base red at 09c48ed811e: under the full suite's load
/// the apply came later and found "no changes since main").
#[test]
fn an_edit_in_the_second_the_worktree_was_made_is_applied_a_second_later() {
    let root = std::env::temp_dir().join(format!(
        "cmux-git-worktree-apply-racy-{}-{:x}",
        std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
    ));
    let home = root.join("home");
    let repo = root.join("project");
    fs::create_dir_all(&home).unwrap();
    fs::create_dir_all(&repo).unwrap();
    let server = HeadlessServer::start_with_options(
        "git-worktree-apply-racy",
        None,
        None,
        &[("HOME", home.to_str().unwrap())],
    );
    git(&repo, &["init", "-q", "-b", "main"]);
    git(&repo, &["config", "user.name", "cmux test"]);
    git(&repo, &["config", "user.email", "cmux@example.invalid"]);
    git(&repo, &["config", "commit.gpgsign", "false"]);
    fs::write(repo.join("a.txt"), "one\n").unwrap();
    git(&repo, &["add", "."]);
    git(&repo, &["commit", "-q", "-m", "first"]);

    // The worktree and the edit in one wall-clock second (tried again in the
    // next second when the host was too slow for that).
    let second = || SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs();
    let made = (0..10).find_map(|attempt| {
        let into_second = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().subsec_millis();
        std::thread::sleep(Duration::from_millis(u64::from(1_050 - into_second)));
        let started = second();
        let name = format!("chat{attempt}");
        let key = format!("c{attempt}");
        let args =
            ["worktree", "create", "--name", name.as_str(), "--idempotency-key", key.as_str()];
        assert_success(&git_cli(&server, &repo, &args));
        let worktree = home.join(".cmux/worktrees/project").join(&name);
        fs::write(worktree.join("a.txt"), "two\n").unwrap();
        (second() == started).then_some(worktree)
    });
    let worktree = made.expect("no try made the worktree and its edit in one second");
    std::thread::sleep(Duration::from_millis(1_200));

    let applied = git_cli(&server, &worktree, &["worktree", "apply", "--idempotency-key", "a1"]);
    assert_success(&applied);
    assert_eq!(fs::read_to_string(repo.join("a.txt")).unwrap(), "two\n");
    let _ = fs::remove_dir_all(root);
}

/// A worktree whose index has no write bit (mode 0444; git reads it, and the
/// apply only copies it) still applies: the copy gets the index's time
/// without being opened for writing.
#[test]
fn a_worktree_whose_index_is_read_only_still_applies() {
    let root = std::env::temp_dir().join(format!(
        "cmux-git-worktree-apply-readonly-{}-{:x}",
        std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
    ));
    let home = root.join("home");
    let repo = root.join("project");
    fs::create_dir_all(&home).unwrap();
    fs::create_dir_all(&repo).unwrap();
    // Root writes through any mode, so there the test proves nothing.
    let probe = root.join("probe");
    fs::write(&probe, "").unwrap();
    if fs::metadata(&probe).unwrap().uid() == 0 {
        eprintln!("skipped: running as root, a 0444 file is writable");
        let _ = fs::remove_dir_all(root);
        return;
    }
    let server = HeadlessServer::start_with_options(
        "git-worktree-apply-readonly",
        None,
        None,
        &[("HOME", home.to_str().unwrap())],
    );
    git(&repo, &["init", "-q", "-b", "main"]);
    git(&repo, &["config", "user.name", "cmux test"]);
    git(&repo, &["config", "user.email", "cmux@example.invalid"]);
    git(&repo, &["config", "commit.gpgsign", "false"]);
    fs::write(repo.join("a.txt"), "one\n").unwrap();
    git(&repo, &["add", "."]);
    git(&repo, &["commit", "-q", "-m", "first"]);
    let args = ["worktree", "create", "--name", "chat", "--idempotency-key", "c1"];
    assert_success(&git_cli(&server, &repo, &args));
    let worktree = home.join(".cmux/worktrees/project/chat");
    fs::write(worktree.join("a.txt"), "two, longer\n").unwrap();
    let git_dir = PathBuf::from(git(&worktree, &["rev-parse", "--absolute-git-dir"]));
    let index = git_dir.join("index");
    fs::set_permissions(&index, fs::Permissions::from_mode(0o444)).unwrap();

    let applied = git_cli(&server, &worktree, &["worktree", "apply", "--idempotency-key", "a1"]);
    assert_success(&applied);
    assert_eq!(fs::read_to_string(repo.join("a.txt")).unwrap(), "two, longer\n");
    let _ = fs::remove_dir_all(root);
}

#[test]
fn the_worktree_remove_guard_runs_no_clean_filter_from_a_submodules_config() {
    let root = std::env::temp_dir().join(format!(
        "cmux-git-worktree-remove-submodule-{}-{:x}",
        std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
    ));
    let home = root.join("home");
    let repo = root.join("project");
    let library = root.join("library");
    let marker = root.join("marker");
    fs::create_dir_all(&home).unwrap();
    fs::create_dir_all(&repo).unwrap();
    fs::create_dir_all(&library).unwrap();
    let server = HeadlessServer::start_with_options(
        "git-worktree-remove-submodule",
        None,
        None,
        &[("HOME", home.to_str().unwrap())],
    );
    for dir in [&repo, &library] {
        git(dir, &["init", "-q", "-b", "main"]);
        git(dir, &["config", "user.name", "cmux test"]);
        git(dir, &["config", "user.email", "cmux@example.invalid"]);
        git(dir, &["config", "commit.gpgsign", "false"]);
    }
    fs::write(library.join(".gitattributes"), "* filter=s\n").unwrap();
    fs::write(library.join("f.txt"), "one\n").unwrap();
    git(&library, &["add", "."]);
    git(&library, &["commit", "-q", "-m", "library"]);
    fs::write(repo.join("a.txt"), "one\n").unwrap();
    git(&repo, &["add", "a.txt"]);
    git(&repo, &["commit", "-q", "-m", "first"]);
    let args = ["worktree", "create", "--name", "chat", "--idempotency-key", "c1"];
    assert_success(&git_cli(&server, &repo, &args));
    let worktree = home.join(".cmux/worktrees/project/chat");
    let source = library.to_str().unwrap();
    git(&worktree, &["-c", "protocol.file.allow=always", "submodule", "add", "-q", source, "sub"]);
    git(&worktree, &["commit", "-q", "-m", "add the submodule"]);
    // The submodule's own clean filter, and a file there git must hash again.
    let clean = format!("touch '{}'; cat", marker.display());
    git(&worktree.join("sub"), &["config", "filter.s.clean", clean.as_str()]);
    make_stat_dirty(&worktree.join("sub/f.txt"));
    fs::write(worktree.join("notes.txt"), "draft\n").unwrap();

    let refused = git_cli(&server, &worktree, &["worktree", "remove", "--idempotency-key", "r1"]);
    assert!(!refused.status.success(), "a worktree with uncommitted work was removed");
    let reason = String::from_utf8_lossy(&refused.stderr).to_string();
    assert!(reason.contains("uncommitted_changes"), "{reason}");
    assert!(!marker.exists(), "the remove guard ran the submodule's clean filter");

    // A real change inside the submodule still keeps the worktree.
    fs::remove_file(worktree.join("notes.txt")).unwrap();
    fs::write(worktree.join("sub/f.txt"), "changed\n").unwrap();
    let refused = git_cli(&server, &worktree, &["worktree", "remove", "--idempotency-key", "r2"]);
    assert!(!refused.status.success(), "a worktree with a changed submodule was removed");
    let reason = String::from_utf8_lossy(&refused.stderr).to_string();
    assert!(reason.contains("uncommitted_changes"), "{reason}");
    let _ = fs::remove_dir_all(root);
}

/// Reads `git worktree setup` in `worktree` until its setup is done.
fn finished_setup(server: &HeadlessServer, worktree: &std::path::Path) -> serde_json::Value {
    let deadline = Instant::now() + Duration::from_secs(60);
    loop {
        let read = git_cli(server, worktree, &["worktree", "setup"]);
        assert_success(&read);
        let value = json_output(&read);
        let state = value["run"]["state"].as_str().unwrap_or_default().to_string();
        if !matches!(state.as_str(), "copying" | "running") {
            return value;
        }
        assert!(Instant::now() < deadline, "setup never finished: {value}");
        std::thread::sleep(Duration::from_millis(100));
    }
}

#[test]
fn a_new_worktree_copies_its_include_files_and_runs_the_projects_setup_and_teardown() {
    let root = std::env::temp_dir().join(format!(
        "cmux-git-worktree-setup-{}-{:x}",
        std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
    ));
    let home = root.join("home");
    let repo = root.join("project");
    fs::create_dir_all(&home).unwrap();
    fs::create_dir_all(repo.join(".cmux")).unwrap();
    let server = HeadlessServer::start_with_options(
        "git-worktree-setup",
        None,
        None,
        &[("HOME", home.to_str().unwrap())],
    );
    git(&repo, &["init", "-q", "-b", "main"]);
    git(&repo, &["config", "user.name", "cmux test"]);
    git(&repo, &["config", "user.email", "cmux@example.invalid"]);
    git(&repo, &["config", "commit.gpgsign", "false"]);
    fs::write(repo.join(".gitignore"), ".env\nsetup-ran.txt\n").unwrap();
    fs::write(repo.join(".worktreeinclude"), ".env\n").unwrap();
    fs::write(
        repo.join(".cmux/worktree.toml"),
        concat!(
            "setup = 'printf \"%s %s %s\" \"$CMUX_WORKSPACE_NAME\" \"$CMUX_PORT\" ",
            "\"$CONDUCTOR_ROOT_PATH\" > setup-ran.txt; echo hello-from-setup'\n",
            "teardown = 'echo bye > \"$CMUX_ROOT_PATH/teardown-ran.txt\"; echo left > leftover.txt'\n",
        ),
    )
    .unwrap();
    git(&repo, &["add", "."]);
    git(&repo, &["commit", "-q", "-m", "first"]);
    fs::write(repo.join(".env"), "SECRET=1\n").unwrap();
    let main = fs::canonicalize(&repo).unwrap();

    // The reply comes before setup runs; the read follows it to the end.
    let args = ["worktree", "create", "--name", "chat", "--idempotency-key", "s1"];
    let created = git_cli(&server, &repo, &args);
    assert_success(&created);
    let value = json_output(&created)["value"].clone();
    assert_eq!(value["setup"]["state"], "copying", "{value}");
    let port = value["setup"]["port"].as_u64().expect("a port");
    assert!(port >= 40_000, "{value}");
    let worktree = home.join(".cmux/worktrees/project/chat");
    let read = finished_setup(&server, &worktree);
    assert_eq!(read["run"]["state"], "succeeded", "{read}");
    assert_eq!(read["run"]["exit_code"], 0, "{read}");
    assert_eq!(read["run"]["include"]["copied"], 1, "{read}");
    assert!(read["run"]["output"].as_str().unwrap().contains("hello-from-setup"), "{read}");
    assert_eq!(
        read["recipe"]["files"],
        serde_json::json!([".worktreeinclude", ".cmux/worktree.toml"])
    );
    assert_eq!(fs::read_to_string(worktree.join(".env")).unwrap(), "SECRET=1\n");
    let ran = fs::read_to_string(worktree.join("setup-ran.txt")).unwrap();
    assert_eq!(ran, format!("chat {port} {}", main.display()));

    // Reading on from where the last read ended returns only what is new.
    let end = read["run"]["output_end"].as_str().unwrap().to_string();
    let more = git_cli(&server, &worktree, &["worktree", "setup", "--since", &end]);
    assert_eq!(json_output(&more)["run"]["output"], "", "{}", json_output(&more));

    // A second worktree gets other ports.
    let other = git_cli(
        &server,
        &repo,
        &["worktree", "create", "--name", "other", "--idempotency-key", "s2"],
    );
    assert_success(&other);
    let other_port = json_output(&other)["value"]["setup"]["port"].as_u64().unwrap();
    assert_ne!(other_port, port);
    finished_setup(&server, &home.join(".cmux/worktrees/project/other"));

    // Removing it runs the teardown first; what the teardown leaves there goes too.
    let removed = git_cli(
        &server,
        &repo,
        &["worktree", "remove", "--path", worktree.to_str().unwrap(), "--idempotency-key", "s3"],
    );
    assert_success(&removed);
    let value = json_output(&removed)["value"].clone();
    assert_eq!(value["teardown"]["state"], "succeeded", "{value}");
    assert_eq!(fs::read_to_string(repo.join("teardown-ran.txt")).unwrap(), "bye\n");
    assert!(!worktree.exists());

    // A failing setup keeps the worktree and says how it failed.
    fs::write(repo.join(".cmux/worktree.toml"), "setup = 'echo broke; exit 3'\n").unwrap();
    let failing = git_cli(
        &server,
        &repo,
        &["worktree", "create", "--name", "bad", "--idempotency-key", "s4"],
    );
    assert_success(&failing);
    let bad = home.join(".cmux/worktrees/project/bad");
    let read = finished_setup(&server, &bad);
    assert_eq!(read["run"]["state"], "failed", "{read}");
    assert_eq!(read["run"]["exit_code"], 3, "{read}");
    assert!(read["run"]["output"].as_str().unwrap().contains("broke"), "{read}");
    assert!(bad.join(".git").exists());
    let _ = fs::remove_dir_all(root);
}

/// Bench round 5 T10 (W6-E): `workspace create --worktree` then `close
/// --remove-worktree` left the empty project folder
/// `~/.cmux/worktrees.noindex/<repo>/`, and create said `~/.cmux/worktrees/…`
/// while the removal said `~/.cmux/worktrees.noindex/…`. Removing a
/// project's last worktree removes its empty folder, a folder that still
/// holds another worktree stays, and the removal names the path create
/// gave. The test makes the macOS layout (`worktrees` a link to
/// `worktrees.noindex`) itself, so it holds on every unix host.
#[test]
fn w6e_removing_the_last_worktree_removes_the_empty_project_folder_and_names_the_created_path() {
    let root = std::env::temp_dir().join(format!(
        "cmux-w6e-worktree-tidy-{}-{:x}",
        std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
    ));
    let home = root.join("home");
    let repo = root.join("project");
    let real = home.join(".cmux/worktrees.noindex");
    fs::create_dir_all(&real).unwrap();
    symlink("worktrees.noindex", home.join(".cmux/worktrees")).unwrap();
    fs::create_dir_all(&repo).unwrap();
    let server = HeadlessServer::start_with_options(
        "w6e-worktree-tidy",
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
    let project = home.join(".cmux/worktrees/project");
    let create = |name: &str, key: &str| {
        let args = ["worktree", "create", "--name", name, "--idempotency-key", key];
        let output = git_cli(&server, &repo, &args);
        assert_success(&output);
        let created = json_output(&output);
        let path = project.join(name);
        assert_eq!(created["value"]["root"], path.to_str().unwrap(), "{created}");
        path
    };
    let remove = |worktree: &std::path::Path, key: &str| {
        let output = git_cli(&server, worktree, &["worktree", "remove", "--idempotency-key", key]);
        assert_success(&output);
        json_output(&output)
    };

    let first = create("first", "c1");
    let second = create("second", "c2");
    let removed = remove(&first, "r1");
    assert_eq!(removed["value"]["root"], first.to_str().unwrap(), "{removed}");
    assert!(!first.exists(), "{removed}");
    assert!(real.join("project").is_dir(), "the project folder went while it held a worktree");

    let removed = remove(&second, "r2");
    assert_eq!(removed["value"]["root"], second.to_str().unwrap(), "{removed}");
    assert!(!real.join("project").exists(), "the empty project folder stayed: {removed}");
    assert!(real.is_dir(), "the worktree root itself must stay");
    assert!(home.join(".cmux/worktrees").is_dir(), "the worktree root link must stay");
    let _ = fs::remove_dir_all(root);
}

/// Bench round 6 N5 (W7-F): `--branch` names the worktree's branch instead of
/// `cmux/<name>`; removing it deletes a branch the create made and keeps one
/// that was there before, and a refusal for unsaved work names `--discard`.
/// The test makes the macOS layout (`worktrees` a link to
/// `worktrees.noindex`) itself, so the printed path holds on every unix host.
#[test]
fn w7f_a_worktree_on_a_named_branch_goes_with_it_and_a_refusal_names_discard() {
    let root = std::env::temp_dir().join(format!(
        "cmux-w7f-worktree-branch-{}-{:x}",
        std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
    ));
    let home = root.join("home");
    let repo = root.join("project");
    fs::create_dir_all(home.join(".cmux/worktrees.noindex")).unwrap();
    symlink("worktrees.noindex", home.join(".cmux/worktrees")).unwrap();
    fs::create_dir_all(&repo).unwrap();
    let server = HeadlessServer::start_with_options(
        "w7f-worktree-branch",
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
    let said = |output: &Output| {
        format!(
            "{}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        )
    };

    // A new branch, named as given.
    let args = ["worktree", "create", "--name", "login", "--branch", "feat/login"];
    let created = git_cli(&server, &repo, &[&args[..], &["--idempotency-key", "c1"]].concat());
    assert_success(&created);
    let value = json_output(&created);
    let worktree = home.join(".cmux/worktrees/project/login");
    assert_eq!(value["value"]["branch"], "feat/login", "{value}");
    assert_eq!(value["value"]["new_branch"], true, "{value}");
    assert_eq!(value["value"]["root"], worktree.to_str().unwrap(), "{value}");
    assert_eq!(git(&worktree, &["symbolic-ref", "--short", "HEAD"]), "feat/login");

    // Unsaved work keeps it, and the refusal says how to remove it anyway.
    fs::write(worktree.join("notes.txt"), "draft\n").unwrap();
    let refused = git_cli(&server, &worktree, &["worktree", "remove", "--idempotency-key", "r1"]);
    assert!(!refused.status.success(), "a worktree with uncommitted work was removed");
    assert!(said(&refused).contains("uncommitted_changes"), "{}", said(&refused));
    assert!(said(&refused).contains("--discard"), "{}", said(&refused));
    assert!(worktree.join("notes.txt").exists());

    // --discard removes it with the branch the create made, and the empty project folder.
    let args = ["worktree", "remove", "--discard", "--idempotency-key", "r2"];
    let removed = git_cli(&server, &worktree, &args);
    assert_success(&removed);
    let value = json_output(&removed);
    assert_eq!(value["value"]["branch"], "feat/login", "{value}");
    assert_eq!(value["value"]["branch_deleted"], true, "{value}");
    assert_eq!(value["value"]["root"], worktree.to_str().unwrap(), "{value}");
    assert!(!worktree.exists());
    assert_eq!(git(&repo, &["branch", "--list", "feat/login"]), "");
    assert!(!home.join(".cmux/worktrees.noindex/project").exists(), "{value}");

    // A branch that was there before is checked out as it is, and stays.
    git(&repo, &["branch", "keep-me"]);
    let args = ["worktree", "create", "--name", "kept", "--branch", "keep-me"];
    let created = git_cli(&server, &repo, &[&args[..], &["--idempotency-key", "c2"]].concat());
    assert_success(&created);
    let value = json_output(&created);
    assert_eq!(value["value"]["branch"], "keep-me", "{value}");
    assert_eq!(value["value"]["new_branch"], false, "{value}");
    let kept = home.join(".cmux/worktrees/project/kept");
    let removed = git_cli(&server, &kept, &["worktree", "remove", "--idempotency-key", "r3"]);
    assert_success(&removed);
    let value = json_output(&removed);
    assert_eq!(value["value"]["branch_deleted"], false, "{value}");
    assert_eq!(git(&repo, &["branch", "--list", "keep-me"]), "keep-me");

    // A name git refuses for a branch is refused before anything is made.
    let args = ["worktree", "create", "--name", "bad", "--branch", "a..b"];
    let refused = git_cli(&server, &repo, &[&args[..], &["--idempotency-key", "c3"]].concat());
    assert!(!refused.status.success(), "{}", said(&refused));
    assert!(!home.join(".cmux/worktrees/project/bad").exists());
    let _ = fs::remove_dir_all(root);
}

/// W7-F: the worktree parts of `cmux git --help` and `cmux workspace --help`
/// name `--branch` and `--discard`, in English and in Japanese.
#[test]
fn w7f_worktree_help_names_branch_and_discard_in_english_and_japanese() {
    let help = |scope: &str, lang: &str| {
        let output = Command::new(bin())
            .args([scope, "--help"])
            .env("LC_ALL", lang)
            .env("LC_MESSAGES", lang)
            .env("LANG", lang)
            .output()
            .unwrap();
        assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
        String::from_utf8(output.stdout).unwrap()
    };
    let english = help("git", "C");
    assert!(english.contains("--branch <branch> names the branch"), "{english}");
    assert!(english.contains("the refusal names --discard"), "{english}");
    let japanese = help("git", "ja_JP.UTF-8");
    assert!(japanese.contains("--branch <branch> でブランチを指定できます"), "{japanese}");
    assert!(japanese.contains("--discard を\n示します"), "{japanese}");
    assert!(!japanese.contains("--branch <branch> names the branch"), "{japanese}");
    let english = help("workspace", "C");
    assert!(english.contains("(or on --branch\n<branch>"), "{english}");
    let japanese = help("workspace", "ja_JP.UTF-8");
    assert!(japanese.contains("(--branch <branch> なら"), "{japanese}");
}

/// W7-F (lead decision 2026-11-11): `cmux git --help` and `cmux workspace
/// --help` are Japanese in a Japanese locale, all of them, not only their
/// worktree paragraphs; the command lines stay as they are typed.
#[test]
fn w7f_git_and_workspace_help_are_all_japanese_in_a_japanese_locale() {
    let help = |scope: &str, lang: &str| {
        let output = Command::new(bin())
            .args([scope, "--help"])
            .env("LC_ALL", lang)
            .env("LC_MESSAGES", lang)
            .env("LANG", lang)
            .output()
            .unwrap();
        assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
        String::from_utf8(output.stdout).unwrap()
    };
    let english = help("git", "C");
    let japanese = help("git", "ja_JP.UTF-8");
    for prose in [
        "status prints the branch",
        "branches lists local branches",
        "commit and push run git as in your terminal",
        "comments are the diff page's review comments",
        "Without one, the current directory.",
    ] {
        assert!(english.contains(prose), "{prose}: {english}");
        assert!(!japanese.contains(prose), "{prose} is still English: {japanese}");
    }
    assert!(japanese.contains("  cmux git worktree remove [TARGET] [--discard]"), "{japanese}");
    assert!(japanese.contains("コミットとプッシュ"), "{japanese}");
    let english = help("workspace", "C");
    let japanese = help("workspace", "ja_JP.UTF-8");
    for prose in [
        "close with --others, --to-right, --to-left or --all closes",
        "<selector> is an id",
        "Workspace groups and rooms are",
    ] {
        assert!(english.contains(prose), "{prose}: {english}");
        assert!(!japanese.contains(prose), "{prose} is still English: {japanese}");
    }
    assert!(japanese.contains("  cmux workspace <selector> close --remove-worktree [--discard]"));
    assert!(japanese.contains("セレクター"), "{japanese}");
}

/// `git_cli` from `cwd` as a shell in it would run it: `PWD` is the folder as
/// the person typed it (a link), the process's directory is what it resolves to.
fn git_cli_typed(server: &HeadlessServer, typed: &std::path::Path, args: &[&str]) -> Output {
    Command::new(bin())
        .current_dir(typed)
        .env("PWD", typed)
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

/// W7-F path rule (lead decision 2026-11-11): cmux prints the folders the
/// person typed, not what their links resolve to. The repository is reached
/// through a link (`link -> real`, as `/tmp -> /private/tmp` on macOS); the
/// main checkout and the worktree are printed under the link in create,
/// status, apply and remove, and `worktree apply` still finds the main
/// checkout and applies there.
#[test]
fn w7f_main_root_is_printed_as_typed_and_apply_still_finds_the_main_checkout() {
    let root = std::env::temp_dir().join(format!(
        "cmux-w7f-typed-{}-{:x}",
        std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
    ));
    let real = root.join("real");
    fs::create_dir_all(real.join("home/.cmux/worktrees")).unwrap();
    fs::create_dir_all(real.join("project")).unwrap();
    let link = root.join("link");
    symlink(&real, &link).unwrap();
    let home = link.join("home");
    let repo = link.join("project");
    let server = HeadlessServer::start_with_options(
        "w7f-typed-path",
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
    let typed_repo = repo.to_str().unwrap();

    let created = git_cli_typed(
        &server,
        &repo,
        &["worktree", "create", "--name", "chat", "--idempotency-key", "c1"],
    );
    assert_success(&created);
    let value = json_output(&created)["value"].clone();
    let worktree = home.join(".cmux/worktrees/project/chat");
    assert_eq!(value["main_root"], typed_repo, "create: {value}");
    assert_eq!(value["root"], worktree.to_str().unwrap(), "create: {value}");

    let status = git_cli_typed(&server, &worktree, &["status"]);
    assert_success(&status);
    let status = json_output(&status);
    assert_eq!(status["worktree"]["main_root"], typed_repo, "status: {status}");

    fs::write(worktree.join("a.txt"), "two\n").unwrap();
    let applied =
        git_cli_typed(&server, &worktree, &["worktree", "apply", "--idempotency-key", "a1"]);
    assert_success(&applied);
    let value = json_output(&applied)["value"].clone();
    assert_eq!(value["main_root"], typed_repo, "apply: {value}");
    assert_eq!(fs::read_to_string(repo.join("a.txt")).unwrap(), "two\n", "apply: {value}");

    git(&repo, &["checkout", "-q", "--", "a.txt"]);
    let removed = git_cli_typed(
        &server,
        &worktree,
        &["worktree", "remove", "--discard", "--idempotency-key", "r1"],
    );
    assert_success(&removed);
    let value = json_output(&removed)["value"].clone();
    assert_eq!(value["main_root"], typed_repo, "remove: {value}");
    assert_eq!(value["root"], worktree.to_str().unwrap(), "remove: {value}");
    assert!(!worktree.exists());
    let _ = fs::remove_dir_all(&root);
}

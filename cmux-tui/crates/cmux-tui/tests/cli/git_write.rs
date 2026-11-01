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

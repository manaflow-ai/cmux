//! Bench round 6 N5 (W7-F): an agent's worktree on a branch the caller names
//! (`acpmux new --worktree REPO --branch NAME` sends
//! `_meta.acpmux.worktree.branch`), and `acpmux worktree remove`, which
//! removes it with the branch cmux made, refuses unsaved work with a message
//! that names `--discard`, takes either spelling of the folder
//! (`~/.cmux/worktrees` or the `worktrees.noindex` folder it links to) and
//! removes the empty project folder after the last worktree. `worktree list
//! --only` takes the link spelling too, and prints it.
//!
//! The test makes the macOS layout (`.cmux/worktrees` a link to
//! `.cmux/worktrees.noindex`) itself, so it holds on every unix host. One
//! test function: HOME is read from this process's environment.

#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::process::Output;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE]}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

async fn call(hub: &Arc<Hub>, m: &str, params: Value) -> Value {
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, mut out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
    in_tx.send(Message::request(1, m, params).to_line()).await.unwrap();
    loop {
        let line =
            tokio::time::timeout(Duration::from_secs(30), out_rx.recv()).await.unwrap().unwrap();
        let v: Value = serde_json::from_str(&line).unwrap();
        if v.get("id") == Some(&json!(1)) {
            return v;
        }
    }
}

fn git(dir: &Path, args: &[&str]) -> String {
    let out = std::process::Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "init.defaultBranch=main"])
        .args(["-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"])
        .args(args)
        .output()
        .unwrap();
    assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
    String::from_utf8_lossy(&out.stdout).trim().to_owned()
}

/// `acpmux <args>` with the hermetic environment and `home` as HOME.
fn acpmux(scratch: &Path, home: &Path, args: &[&str]) -> Output {
    daemon_env::acpmux(scratch).env("HOME", home).args(args).output().unwrap()
}

/// `acpmux <args>` as [`acpmux`] does, in the locale `lang`.
fn acpmux_in(scratch: &Path, home: &Path, lang: &str, args: &[&str]) -> Output {
    daemon_env::acpmux(scratch)
        .env("HOME", home)
        .env("LC_ALL", lang)
        .env("LANG", lang)
        .args(args)
        .output()
        .unwrap()
}

fn said(output: &Output) -> String {
    format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    )
}

fn new_params(repo: &Path, name: &str, worktree: Value) -> Value {
    json!({"cwd": repo, "mcpServers": [],
        "_meta": {"acpmux": {"name": name, "worktree": worktree}}})
}

#[tokio::test]
async fn w7f_a_named_branch_worktree_is_removed_with_its_branch_and_refuses_unsaved_work() {
    let root = std::env::temp_dir().join(format!("acpmux-w7f-wt-{}", uuid::Uuid::now_v7()));
    let home = root.join("home");
    let noindex = home.join(".cmux/worktrees.noindex");
    std::fs::create_dir_all(&noindex).unwrap();
    std::os::unix::fs::symlink("worktrees.noindex", home.join(".cmux/worktrees")).unwrap();
    // SAFETY: the only test in this binary; set before any session starts.
    unsafe {
        std::env::set_var("HOME", &home);
        std::env::set_var("ACPMUX_HOME", root.join("acpmux"));
        std::env::set_var("CMUX_NEXT_CONFIG_FILE", root.join("cmux-next.json"));
    }
    let scratch = root.join("cli");
    std::fs::create_dir_all(&scratch).unwrap();
    let repo = root.join("proj");
    std::fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "-q"]);
    git(&repo, &["commit", "-q", "--allow-empty", "-m", "first"]);
    let hub = hub();

    // The branch is the one named, not cmux/<name>.
    let named = call(
        &hub,
        "session/new",
        new_params(&repo, "r6a", json!({"name": "r6a", "branch": "r6a"})),
    )
    .await;
    let w = &named["result"]["_meta"]["acpmux"]["worktree"];
    let wt_a: PathBuf = home.join(".cmux/worktrees/proj/r6a");
    assert_eq!(w["branch"], "r6a", "{named}");
    assert_eq!(w["root"], json!(wt_a), "{named}");
    assert_eq!(git(&wt_a, &["symbolic-ref", "--short", "HEAD"]), "r6a");
    let plain = call(&hub, "session/new", new_params(&repo, "r6b", json!({"name": "r6b"}))).await;
    assert_eq!(plain["result"]["_meta"]["acpmux"]["worktree"]["branch"], "cmux/r6b", "{plain}");
    let wt_b = home.join(".cmux/worktrees/proj/r6b");

    // `worktree list --only` takes the link spelling, and prints it.
    let link_a = wt_a.to_str().unwrap();
    let repo_root = repo.to_str().unwrap();
    let listed = acpmux(
        &scratch,
        &home,
        &["worktree", "list", "--root", repo_root, "--only", link_a, "--all", "--json"],
    );
    assert!(listed.status.success(), "{}", said(&listed));
    let report: Value = serde_json::from_slice(&listed.stdout).unwrap();
    let items = report["items"].as_array().cloned().unwrap_or_default();
    assert_eq!(items.len(), 1, "{report}");
    assert_eq!(items[0]["path"], link_a, "{report}");

    // Unsaved work keeps it; the refusal names --discard and changes nothing.
    std::fs::write(wt_a.join("notes.txt"), "draft\n").unwrap();
    let refused = acpmux(&scratch, &home, &["worktree", "remove", "r6a"]);
    assert_eq!(refused.status.code(), Some(1), "{}", said(&refused));
    assert!(said(&refused).contains("uncommitted"), "{}", said(&refused));
    assert!(said(&refused).contains("--discard"), "{}", said(&refused));
    assert!(wt_a.join("notes.txt").exists());
    // In a Japanese locale the refusal is Japanese, and still names --discard.
    let japanese = acpmux_in(&scratch, &home, "ja_JP.UTF-8", &["worktree", "remove", "r6a"]);
    assert_eq!(japanese.status.code(), Some(1), "{}", said(&japanese));
    assert!(said(&japanese).contains("コミットされていない変更"), "{}", said(&japanese));
    assert!(said(&japanese).contains("--discard"), "{}", said(&japanese));
    let bad = ["new", "-n", "r6x", "--worktree", repo_root, "--branch", "a..b", "-d", "hi"];
    let bad_ja = acpmux_in(&scratch, &home, "ja_JP.UTF-8", &bad);
    assert!(!bad_ja.status.success(), "{}", said(&bad_ja));
    assert!(said(&bad_ja).contains("ブランチ名"), "{}", said(&bad_ja));
    let bad_en = acpmux(&scratch, &home, &bad);
    assert!(said(&bad_en).contains("is no branch name"), "{}", said(&bad_en));
    assert!(wt_a.join("notes.txt").exists());

    // --discard removes it and the branch cmux made; the project folder stays for r6b.
    let removed = acpmux(&scratch, &home, &["worktree", "remove", "r6a", "--discard", "--json"]);
    assert!(removed.status.success(), "{}", said(&removed));
    let value: Value = serde_json::from_slice(&removed.stdout).unwrap();
    assert_eq!(value["root"], link_a, "{value}");
    assert_eq!(value["branchDeleted"], true, "{value}");
    // The main checkout as it was typed (on macOS the temp folder is a link into /private).
    assert_eq!(value["mainRoot"], repo_root, "{value}");
    assert!(!wt_a.exists());
    assert_eq!(git(&repo, &["branch", "--list", "r6a"]), "");
    assert!(noindex.join("proj").is_dir());

    // The resolved spelling names the same worktree; the last one takes the empty project folder.
    let real_b = noindex.join("proj/r6b");
    let removed = acpmux(&scratch, &home, &["worktree", "remove", real_b.to_str().unwrap()]);
    assert!(removed.status.success(), "{}", said(&removed));
    assert!(!wt_b.exists());
    assert_eq!(git(&repo, &["branch", "--list", "cmux/r6b"]), "");
    assert!(!noindex.join("proj").exists(), "{}", said(&removed));
    assert!(noindex.is_dir(), "the worktree root must stay");

    // The main checkout is never removed.
    let refused = acpmux(&scratch, &home, &["worktree", "remove", repo_root, "--discard"]);
    assert!(!refused.status.success(), "{}", said(&refused));
    assert!(said(&refused).contains("main checkout"), "{}", said(&refused));
    assert!(repo.join(".git").exists());

    // Review finding 1: a branch the person made, even a `cmux/...` one an
    // earlier worktree marked, stays with its commit after `--discard`.
    for (name, branch) in [("r6d", "cmux/mine"), ("r6e", "cmux/stale")] {
        git(&repo, &["checkout", "-q", "-b", branch]);
        git(&repo, &["commit", "-q", "--allow-empty", "-m", "only on my branch"]);
        let commit = git(&repo, &["rev-parse", "HEAD"]);
        git(&repo, &["checkout", "-q", "-"]);
        if branch == "cmux/stale" {
            git(&repo, &["config", &format!("branch.{branch}.cmuxCreated"), "true"]);
        }
        let mine = call(
            &hub,
            "session/new",
            new_params(&repo, name, json!({"name": name, "branch": branch})),
        )
        .await;
        assert_eq!(mine["result"]["_meta"]["acpmux"]["worktree"]["branch"], branch, "{mine}");
        let removed = acpmux(&scratch, &home, &["worktree", "remove", name, "--discard", "--json"]);
        assert!(removed.status.success(), "{}", said(&removed));
        let value: Value = serde_json::from_slice(&removed.stdout).unwrap();
        assert_eq!(value["branchDeleted"], false, "{branch}: {value}");
        assert_eq!(git(&repo, &["rev-parse", branch]), commit, "{branch} lost its commit");
    }

    // Review finding 3: a relative TARGET is taken against the folder as the
    // shell typed it ($PWD), so mainRoot keeps that spelling (here a link).
    let plain = call(&hub, "session/new", new_params(&repo, "r6f", json!({"name": "r6f"}))).await;
    assert!(plain["result"].is_object(), "{plain}");
    let alias = std::env::temp_dir().join(format!("acpmux-w7f-alias-{}", uuid::Uuid::now_v7()));
    std::os::unix::fs::symlink(&root, &alias).unwrap();
    let typed = alias.join("home/.cmux/worktrees/proj");
    let removed = daemon_env::acpmux(&scratch)
        .env("HOME", &home)
        .env("PWD", &typed)
        .current_dir(&typed)
        .args(["worktree", "remove", "./r6f", "--json"])
        .output()
        .unwrap();
    assert!(removed.status.success(), "{}", said(&removed));
    let value: Value = serde_json::from_slice(&removed.stdout).unwrap();
    assert_eq!(value["mainRoot"], json!(alias.join("proj")), "{value}");
    let _ = std::fs::remove_file(&alias);

    // Review finding 4: in a Japanese locale `worktree remove --help` describes
    // the command and its arguments in Japanese, and a folder outside git says so.
    let help = acpmux_in(&scratch, &home, "ja_JP.UTF-8", &["worktree", "remove", "--help"]);
    assert!(help.status.success(), "{}", said(&help));
    for english in ["Remove one worktree now", "The worktree's folder", "Remove it even with"] {
        assert!(!said(&help).contains(english), "{english} is still English: {}", said(&help));
    }
    assert!(said(&help).contains("ワークツリーを 1 つ"), "{}", said(&help));
    assert!(said(&help).contains("セッション名"), "{}", said(&help));
    let help_en = acpmux(&scratch, &home, &["worktree", "remove", "--help"]);
    assert!(said(&help_en).contains("Remove one worktree now"), "{}", said(&help_en));
    let outside = scratch.to_str().unwrap();
    let not_git = acpmux_in(&scratch, &home, "ja_JP.UTF-8", &["worktree", "remove", outside]);
    assert!(!not_git.status.success(), "{}", said(&not_git));
    assert!(said(&not_git).contains("git リポジトリ"), "{}", said(&not_git));
    let not_git_en = acpmux(&scratch, &home, &["worktree", "remove", outside]);
    assert!(said(&not_git_en).contains("not in a git repository"), "{}", said(&not_git_en));
    let _ = std::fs::remove_dir_all(&root);
}

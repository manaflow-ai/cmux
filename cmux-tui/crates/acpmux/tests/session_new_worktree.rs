//! `session/new` with `_meta.acpmux.worktree` (`server/new_worktree.rs`,
//! what `acpmux new --worktree` sends): the session starts in the named
//! worktree of its cwd's repository, made the first time and the same one
//! after; only the local unix socket may ask for one.
//!
//! Stand-in agents (fake_agent.py). One test function: HOME is read from
//! this process's environment.

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
use std::path::Path;
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

async fn call(hub: &Arc<Hub>, origin: Origin, m: &str, params: Value) -> Value {
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, mut out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
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

fn new_params(repo: &Path, name: &str, worktree: Value) -> Value {
    json!({"cwd": repo, "mcpServers": [],
        "_meta": {"acpmux": {"name": name, "worktree": worktree}}})
}

#[tokio::test]
async fn a_named_worktree_is_made_once_and_reused_by_the_next_start() {
    let root = std::env::temp_dir().join(format!("acpmux-newwt-{}", uuid::Uuid::now_v7()));
    let home = root.join("home");
    std::fs::create_dir_all(&home).unwrap();
    // SAFETY: the only test in this binary; set before any session starts.
    unsafe {
        std::env::set_var("HOME", &home);
        std::env::set_var("ACPMUX_HOME", root.join("acpmux"));
        std::env::set_var("CMUX_NEXT_CONFIG_FILE", root.join("cmux-next.json"));
    }
    let repo = root.join("proj");
    std::fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "-q"]);
    git(&repo, &["commit", "-q", "--allow-empty", "-m", "first"]);
    git(&repo, &["branch", "next"]);
    let hub = hub();

    let first = call(
        &hub,
        Origin::Local,
        "session/new",
        new_params(&repo, "lane-a", json!({"name": "lane-a", "base": "next"})),
    )
    .await;
    let w = &first["result"]["_meta"]["acpmux"]["worktree"];
    let wt = home.join(".cmux/worktrees/proj/lane-a");
    assert_eq!(w["root"], json!(wt), "{first}");
    assert_eq!(w["branch"], "cmux/lane-a");
    assert_eq!(w["base"], "next");
    assert_eq!(w["reused"], Value::Null);
    assert_eq!(first["result"]["_meta"]["acpmux"]["cwd"], json!(wt));

    // A second start naming the same worktree is given it, not a copy.
    let second = call(
        &hub,
        Origin::Local,
        "session/new",
        new_params(&repo, "lane-a2", json!({"name": "lane-a"})),
    )
    .await;
    let w = &second["result"]["_meta"]["acpmux"]["worktree"];
    assert_eq!(w["root"], json!(wt), "{second}");
    assert_eq!(w["reused"], "worktree");
    assert!(!home.join(".cmux/worktrees/proj/lane-a-2").exists());

    // No worktree for a WebSocket client or a peer, and no git run for them.
    for origin in [Origin::Web, Origin::Peer] {
        let r = call(
            &hub,
            origin,
            "session/new",
            new_params(&repo, "lane-b", json!({"name": "lane-b"})),
        )
        .await;
        assert!(r.get("error").is_some(), "{r}");
    }
    assert!(!home.join(".cmux/worktrees/proj/lane-b").exists());

    // A base that is no commit fails before any session starts.
    let bad = call(
        &hub,
        Origin::Local,
        "session/new",
        new_params(&repo, "lane-c", json!({"name": "lane-c", "base": "nope"})),
    )
    .await;
    assert!(bad["error"]["message"].as_str().unwrap_or_default().contains("no commit"), "{bad}");
    let _ = std::fs::remove_dir_all(&root);
}

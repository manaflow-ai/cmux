//! A sub-session start is a new session: this host's admission (`hub/admission.rs`)
//! checks it before its worktree is made. A disk-floor warning never refuses it.
//!
//! Stand-in agents (fake_agent.py). One test function: HOME is read from this
//! process's environment.

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
const START: &str = "_acpmux/subsession/start";

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

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    fn new(hub: &Arc<Hub>) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
        Client(in_tx, out_rx, 0)
    }

    async fn as_session(hub: &Arc<Hub>, id: &str) -> Self {
        let mut c = Self::new(hub);
        let token = acpmux::hub::person::caller_token(id);
        let params = json!({"protocolVersion": 1,
            "_meta": {"acpmux": {"callerSession": {"sessionId": id, "token": token}}}});
        let r = c.call("initialize", params).await;
        assert!(r.get("error").is_none(), "{r}");
        c
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .unwrap()
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return v;
            }
        }
    }
}

fn git(dir: &Path, args: &[&str]) {
    let out = std::process::Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "init.defaultBranch=main"])
        .args(["-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"])
        .args(args)
        .output()
        .unwrap();
    assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
}

#[tokio::test]
async fn an_under_floor_child_start_makes_its_worktree_without_force_admit() {
    let root = std::env::temp_dir().join(format!("acpmux-admsub-{}", uuid::Uuid::now_v7()));
    let home = root.join("home");
    std::fs::create_dir_all(&home).unwrap();
    // SAFETY: the only test in this binary; set before any session starts.
    unsafe {
        std::env::set_var("HOME", &home);
        std::env::set_var("ACPMUX_HOME", root.join("acpmux"));
        std::env::set_var("CMUX_NEXT_CONFIG_FILE", root.join("cmux-next.json"));
        std::env::remove_var("FLEET_REGISTRY");
    }
    let repo = root.join("shop");
    std::fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "-q"]);
    git(&repo, &["commit", "-q", "--allow-empty", "-m", "first"]);

    let hub = hub();
    let mut app = Client::new(&hub);
    let new = json!({"cwd": repo, "mcpServers": [], "_meta": {"acpmux": {"harness": "fake"}}});
    let r = app.call("session/new", new).await;
    let parent = r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned();
    let mut p = Client::as_session(&hub, &parent).await;

    // A floor is advisory: an ordinary child starts in its requested worktree.
    let flag = home.join(".cache/worktree-reclaim/under-floor");
    std::fs::create_dir_all(flag.parent().unwrap()).unwrap();
    std::fs::write(&flag, "").unwrap();
    let child =
        p.call(START, json!({"prompt": "echo child", "name": "Child", "worktree": true})).await;
    assert!(child.get("error").is_none(), "the floor never refuses a child: {child}");
    let worktrees = home.join(".cmux/worktrees");
    let wt = child["result"]["worktree"]["root"].as_str().unwrap_or_default();
    assert!(wt.starts_with(&*worktrees.to_string_lossy()), "{child}");
    assert!(Path::new(wt).is_dir(), "the child runs in its worktree: {child}");

    let _ = std::fs::remove_dir_all(&root);
}

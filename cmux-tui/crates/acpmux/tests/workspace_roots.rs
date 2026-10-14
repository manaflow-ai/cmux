//! A remote (Web) connection may start a session in the folder of a
//! workspace the person's app lists (`_acpmux/workspace_roots_set`, the
//! person only, memory only): what a phone needs to open an agent chat in
//! one of the person's own workspaces. The roots keep `remote_guard`'s
//! guards: `/`, the home folder and its ancestors never count, symlinks and
//! `..` resolve first, and anything else stays refused.

// Unix only until the Windows port runs the daemon (cmux::local_socket).
#![cfg(unix)]

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const KEY: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

fn dir(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("awr-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(d.join("project")).unwrap();
    std::fs::create_dir_all(d.join("elsewhere")).unwrap();
    std::fs::canonicalize(&d).unwrap()
}

/// No webRoots: only known projects and the person's workspace folders count.
fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fclaude": {"argv": ["python3", FAKE], "family": "claude"}},
        "defaultHarness": "fclaude",
        "permissionPolicy": "ask",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    fn new(hub: &Arc<Hub>, origin: Origin) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
        Client(in_tx, out_rx, 0)
    }

    async fn person(hub: &Arc<Hub>) -> Self {
        let _ = hub.person.install_spawn_key(KEY);
        let mut c = Self::new(hub, Origin::Local);
        let r = c.call("initialize", json!({"protocolVersion": 1})).await;
        let challenge = &r["result"]["_meta"]["acpmux"]["personChallenge"];
        let (nonce, conn) =
            (challenge["nonce"].as_str().unwrap(), challenge["connection"].as_str().unwrap());
        let proof = acpmux::hub::person::person_proof(
            KEY,
            acpmux::hub::person::TRANSPORT_UNIX,
            nonce,
            conn,
        )
        .unwrap();
        let r = c.call("_acpmux/person_prove", json!({"proof": proof})).await;
        assert!(r.get("error").is_none(), "{r}");
        c
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(20), self.1.recv())
                .await
                .unwrap()
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return v;
            }
        }
    }

    async fn new_session(&mut self, cwd: &Path) -> Value {
        self.call("session/new", json!({"cwd": cwd, "mcpServers": []})).await
    }
}

fn refused_outside(r: &Value) -> bool {
    r["error"]["message"]
        .as_str()
        .is_some_and(|m| m.contains("known project or a configured webRoots"))
}

#[tokio::test]
async fn a_web_session_may_start_in_a_workspace_folder_the_person_set() {
    let d = dir("set");
    let hub = hub();
    let mut web = Client::new(&hub, Origin::Web);
    web.call("initialize", json!({"protocolVersion": 1})).await;
    // Before: the workspace folder is no known project.
    assert!(refused_outside(&web.new_session(&d.join("project")).await));

    // Only the person sets the folders.
    let r = web.call("_acpmux/workspace_roots_set", json!({"roots": [d.join("project")]})).await;
    assert!(r.get("error").is_some(), "{r}");
    let mut app = Client::person(&hub).await;
    let r = app.call("_acpmux/workspace_roots_set", json!({"roots": ["relative"]})).await;
    assert!(r.get("error").is_some(), "{r}");
    // `/` and home are dropped by the guard even when listed.
    let home = dirs::home_dir().unwrap();
    let r = app
        .call("_acpmux/workspace_roots_set", json!({"roots": [d.join("project"), "/", home]}))
        .await;
    assert_eq!(r["result"]["count"], 3, "{r}");

    // After: the workspace folder and a folder in it start; elsewhere stays refused,
    // and a symlink out of the workspace resolves before the check.
    let started = web.new_session(&d.join("project")).await;
    assert!(started["result"]["sessionId"].is_string(), "{started}");
    std::fs::create_dir_all(d.join("project/src")).unwrap();
    assert!(web.new_session(&d.join("project/src")).await["result"]["sessionId"].is_string());
    assert!(refused_outside(&web.new_session(&d.join("elsewhere")).await));
    std::os::unix::fs::symlink(d.join("elsewhere"), d.join("project/out")).unwrap();
    assert!(refused_outside(&web.new_session(&d.join("project/out")).await));
    assert!(refused_outside(&web.new_session(&d.join("project/../elsewhere")).await));

    // Cleared: refused again.
    app.call("_acpmux/workspace_roots_set", json!({"roots": []})).await;
    std::fs::create_dir_all(d.join("project2")).unwrap();
    assert!(refused_outside(&web.new_session(&d.join("project2")).await));
}

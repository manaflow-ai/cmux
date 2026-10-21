//! `sessions.allowFullAccess` off while a parent chat is still in full access
//! (it got there before the setting changed): the parent's agent can still
//! start a child, and the child does not inherit full access. Its own test
//! binary: it sets CMUX_NEXT_CONFIG_FILE, which every start reads.

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

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    fn new(hub: &Arc<Hub>) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
        Client(in_tx, out_rx, 0)
    }

    /// The connection an agent's tools open: `initialize` with its caller token.
    async fn as_session(hub: &Arc<Hub>, id: &str) -> Self {
        let mut c = Self::new(hub);
        let token = acpmux::hub::person::caller_token(id);
        let r = c
            .call(
                "initialize",
                json!({"protocolVersion": 1,
                       "_meta": {"acpmux": {"callerSession": {"sessionId": id, "token": token}}}}),
            )
            .await;
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

    async fn ok(&mut self, m: &str, params: Value) -> Value {
        let r = self.call(m, params).await;
        assert!(r.get("error").is_none(), "{m}: {r}");
        r["result"].clone()
    }

    async fn mode(&mut self, id: &str) -> Option<String> {
        let r = self.ok("_acpmux/info", json!({"sessionId": id})).await;
        r["modes"]["currentModeId"].as_str().map(str::to_owned)
    }
}

#[tokio::test]
async fn a_full_access_parent_starts_a_child_outside_full_access_while_it_is_off() {
    let _ = &HERMETIC;
    let root = std::env::temp_dir().join(format!("acpmux-fa-subsessions-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    let settings = root.join("cmux-next.json");
    std::fs::write(&settings, r#"{"sessions": {"allowFullAccess": true}}"#).unwrap();
    // SAFETY: the only test in this binary; set before any session starts.
    unsafe {
        std::env::set_var("CMUX_NEXT_CONFIG_FILE", &settings);
        std::env::set_var("ACPMUX_HOME", root.join("home"));
    }
    let hub = hub();
    let mut app = Client::new(&hub);
    let new = json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"harness": "fake"}}});
    let parent = app.ok("session/new", new).await["sessionId"].as_str().unwrap().to_owned();
    // The parent's harness puts itself in full access while that is allowed.
    app.ok(
        "session/prompt",
        json!({"sessionId": parent, "prompt": [{"type": "text", "text": "set-mode: yolo"}]}),
    )
    .await;
    assert_eq!(app.mode(&parent).await.as_deref(), Some("yolo"));

    // The person turns full access off; the parent stays where it is.
    std::fs::write(&settings, r#"{"sessions": {"allowFullAccess": false}}"#).unwrap();
    let mut p = Client::as_session(&hub, &parent).await;
    let r = p.call("_acpmux/subsession/start", json!({"prompt": "echo child"})).await;
    assert!(r.get("error").is_none(), "the child starts: {r}");
    let child = r["result"]["sessionId"].as_str().unwrap().to_owned();
    assert_ne!(app.mode(&child).await.as_deref(), Some("yolo"), "the child is not in full access");
}

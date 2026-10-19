//! The MCP servers a chat's harness says it loaded (cx-ncc.105): every
//! session summary carries `mcpServers`, `{name, status}` per server, from
//! what the harness itself reports (Claude Code's system/init). A server the
//! user's own config turned off was not loaded and is left out. A harness
//! that reports nothing (an ACP agent) has `mcpServers: null`: acpmux never
//! reads a config file to guess them.
//!
//! One test function: cmux's tools are read from this process's
//! environment, which every test of a binary shares.

// Unix only until the Windows port runs the daemon (cmux::local_socket).
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
const FAKE_CLAUDE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");

fn hub() -> Arc<Hub> {
    // Two servers loaded, one of them failed, and one the user turned off.
    let init = json!({
        "mcp_servers": [
            {"name": "github", "status": "connected"},
            {"name": "linear", "status": "failed"},
            {"name": "off", "status": "disabled"},
        ],
    });
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {
            "fake": {"argv": ["python3", FAKE]},
            "fakeclaude": {"argv": ["python3", FAKE_CLAUDE], "kind": "claude-stdio",
                           "env": {"FAKE_CLAUDE_INIT": init.to_string()}},
        },
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

fn client(hub: &Arc<Hub>) -> Client {
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
    Client(in_tx, out_rx, 0)
}

impl Client {
    async fn next(&mut self) -> Value {
        let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
            .await
            .expect("no message")
            .unwrap();
        serde_json::from_str(&line).unwrap()
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let v = self.next().await;
            if v.get("id") == Some(&json!(id)) {
                assert!(v.get("error").is_none(), "{m}: {v}");
                return v["result"].clone();
            }
        }
    }

    async fn new_session(&mut self, harness: &str) -> String {
        let params = json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"harness": harness}}});
        self.call("session/new", params).await["sessionId"].as_str().unwrap().to_owned()
    }

    /// The session of the first `_acpmux/session_changed` of `kind` for `session`.
    async fn changed(&mut self, session: &str, kind: &str) -> Value {
        loop {
            let v = self.next().await;
            if v["method"] == "_acpmux/session_changed"
                && v["params"]["sessionId"] == session
                && v["params"]["kind"] == kind
            {
                return v["params"]["session"].clone();
            }
        }
    }
}

#[tokio::test]
async fn session_summary_lists_the_mcp_servers_the_harness_loaded() {
    let root = std::env::temp_dir().join(format!("acpmux-mcp-servers-it-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    // SAFETY: the only test in this binary; set before any session starts.
    unsafe {
        std::env::set_var("ACPMUX_HOME", root.join("home"));
        std::env::set_var("ACPMUX_AGENT_TOOLS", "0");
    }
    let hub = hub();
    let mut local = client(&hub);
    let mut watcher = client(&hub);
    local.call("initialize", json!({"protocolVersion": 1})).await;
    watcher.call("_acpmux/watch", json!({"enabled": true})).await;

    // An ACP agent reports no MCP servers: none are listed, none guessed.
    let acp = local.new_session("fake").await;
    let info = local.call("_acpmux/info", json!({"sessionId": acp})).await;
    assert_eq!(info["mcpServers"], Value::Null, "{info}");

    // Claude Code's system/init: the two servers it loaded, failed or not.
    let claude = local.new_session("fakeclaude").await;
    let prompt = json!({"sessionId": claude, "prompt": [{"type": "text", "text": "hi"}]});
    local.call("session/prompt", prompt).await;
    let loaded = json!([
        {"name": "github", "status": "connected"},
        {"name": "linear", "status": "failed"},
    ]);
    let info = local.call("_acpmux/info", json!({"sessionId": claude})).await;
    assert_eq!(info["mcpServers"], loaded, "{info}");
    // A watching pane hears them in the summary its change carries.
    let changed = watcher.changed(&claude, "tools").await;
    assert_eq!(changed["mcpServers"], loaded, "{changed}");
    // The attach the pane opens a chat with carries them too.
    let attach = local.call("_acpmux/attach", json!({"sessionId": claude})).await;
    assert_eq!(attach["session"]["mcpServers"], loaded, "{attach}");

    let _ = std::fs::remove_dir_all(&root);
}

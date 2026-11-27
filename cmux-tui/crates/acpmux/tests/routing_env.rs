//! A Hermes session's MCP servers carry the session's routing env inline (`agent_tools::with_routing_env`):
//! Hermes starts a stdio MCP server with only a few safe variables plus the entry's own env, so
//! the cmux server could not reach the session's daemon (cmux-ci step 20724a44bada). Only the
//! routing names go inline, never a token; other harnesses inherit the env and get nothing extra.
//!
//! One test function: the tools are read from this process's environment.

#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
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
const SOCK: &str = "/tmp/acpmux-test-routing/cmux.sock";
const TOKEN: &str = "routing-test-secret-token-value";

fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {
            "fake": {"argv": ["python3", FAKE], "env": {"CMUX_TUI_SOCKET": SOCK}},
            "fakehermes": {"argv": ["python3", FAKE], "family": "hermes",
                "env": {"CMUX_TUI_SOCKET": SOCK, "CMUX_LINK_TOKEN": TOKEN, "OPENAI_API_KEY": TOKEN}},
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

fn client(hub: &Arc<Hub>, origin: Origin) -> Client {
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
    Client(in_tx, out_rx, 0)
}

impl Client {
    async fn call_text(&mut self, m: &str, params: Value) -> (Value, String) {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        let mut text = String::new();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .unwrap()
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return (v, text);
            }
            if let Some(t) = v.pointer("/params/update/content/text").and_then(Value::as_str) {
                text.push_str(t);
            }
        }
    }

    async fn new_session(&mut self, harness: &str) -> String {
        self.new_session_with(json!({"harness": harness})).await
    }

    async fn new_session_with(&mut self, meta: Value) -> String {
        let params =
            json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": meta}});
        let (reply, _) = self.call_text("session/new", params).await;
        assert!(reply.get("error").is_none(), "{reply}");
        reply["result"]["sessionId"].as_str().unwrap().to_owned()
    }

    /// The agent's answer to one prompt.
    async fn ask(&mut self, session: &str, text: &str) -> String {
        let prompt = json!({"sessionId": session, "prompt": [{"type": "text", "text": text}]});
        let (reply, said) = self.call_text("session/prompt", prompt).await;
        assert!(reply.get("error").is_none(), "{reply}");
        said
    }
}

fn fake_bin(dir: &Path, name: &str) -> std::path::PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let path = dir.join(name);
    std::fs::write(&path, "#!/bin/sh\nexit 0\n").unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    path
}

#[tokio::test]
async fn a_hermes_session_gets_the_routing_env_and_no_token() {
    let _ = &HERMETIC;
    let root = std::env::temp_dir().join(format!("acpmux-routing-env-it-{}", uuid::Uuid::now_v7()));
    let bin = root.join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    fake_bin(&bin, "cmux");
    let cmux_json = root.join("cmux-next.json");
    std::fs::write(&cmux_json, r#"{"agents": {"chats": {"enabled": true}}}"#).unwrap();
    // SAFETY: the only test in this binary; set before any session starts.
    unsafe {
        std::env::set_var("CMUX_AGENT_TOOLS_BIN_DIR", &bin);
        std::env::set_var("CMUX_NEXT_CONFIG_FILE", &cmux_json);
        std::env::set_var("ACPMUX_HOME", root.join("home"));
        std::env::remove_var("ACPMUX_AGENT_TOOLS");
    }
    let hub = hub();
    let mut local = client(&hub, Origin::Local);

    let id = local.new_session("fakehermes").await;
    let hermes: Value = serde_json::from_str(&local.ask(&id, "mcp").await).unwrap();
    let stdio: Vec<&Value> =
        hermes.as_array().into_iter().flatten().filter(|s| s.get("command").is_some()).collect();
    assert!(!stdio.is_empty(), "a Hermes session gets stdio MCP servers: {hermes}");
    for server in &stdio {
        let env = server["env"].as_array().cloned().unwrap_or_default();
        assert!(
            env.iter().any(|e| e["name"] == "CMUX_TUI_SOCKET" && e["value"] == SOCK),
            "each stdio server names the session socket: {server}"
        );
    }
    let text = hermes.to_string();
    assert!(!text.contains(TOKEN), "no token or key value goes inline: {hermes}");
    assert!(!text.contains("CMUX_LINK_TOKEN") && !text.contains("OPENAI_API_KEY"), "{hermes}");

    let id = local.new_session("fake").await;
    let plain: Value = serde_json::from_str(&local.ask(&id, "mcp").await).unwrap();
    assert!(
        !plain.to_string().contains(SOCK),
        "another harness gets no inline routing env: {plain}"
    );
}

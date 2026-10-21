//! A host crash leaves the Computer Use helper v2's `endpoint.json` behind
//! (cx-zgk0): the cmux app writes it while its helper runs and removes it on
//! a clean stop, but a SIGKILL removes nothing, and this daemon outlives the
//! app. Every new agent session then got `acpmux cua-mcp` pointed at a dead
//! socket, and its tool calls failed until the next helper start.
//!
//! A stand-in helper process serves the socket and is the `pid` the
//! endpoint names. While it runs, a new session gets the v2 bridge. After a
//! SIGKILL of that exact pid, the next new session gets the legacy
//! `cmux-cua mcp` server and the stale file is gone.
//!
//! One test function: the tools are read from this process's environment,
//! which every test of a binary shares.

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
use std::io::{BufRead, BufReader};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

/// A helper stand-in: listens on argv[1], says `ready`, drops every peer.
const HELPER: &str = "import socket, sys
s = socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])
s.listen(16)
print('ready', flush=True)
while True:
    c, _ = s.accept()
    c.close()
";

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

    /// The MCP servers a new local session's agent got in `session/new`.
    async fn new_session_servers(&mut self) -> Value {
        let params = json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"harness": "fake"}}});
        let (reply, _) = self.call_text("session/new", params).await;
        assert!(reply.get("error").is_none(), "{reply}");
        let id = reply["result"]["sessionId"].as_str().unwrap().to_owned();
        let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "mcp"}]});
        let (reply, said) = self.call_text("session/prompt", prompt).await;
        assert!(reply.get("error").is_none(), "{reply}");
        serde_json::from_str(&said).unwrap()
    }
}

/// Starts the stand-in helper on `socket` and waits for its `ready` line.
fn start_helper(socket: &Path) -> Child {
    let mut child = Command::new("python3")
        .arg("-c")
        .arg(HELPER)
        .arg(socket)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut line = String::new();
    BufReader::new(child.stdout.take().unwrap()).read_line(&mut line).unwrap();
    assert_eq!(line.trim(), "ready");
    child
}

#[tokio::test]
async fn a_new_session_after_a_host_crash_gets_the_legacy_server_not_the_dead_helper() {
    let root = PathBuf::from("/tmp").join(format!("acpx-stale-{}", uuid::Uuid::now_v7().simple()));
    let bin = root.join("bin");
    let endpoint_dir = root.join("v2");
    std::fs::create_dir_all(&bin).unwrap();
    std::fs::create_dir_all(&endpoint_dir).unwrap();
    std::fs::set_permissions(&endpoint_dir, std::fs::Permissions::from_mode(0o700)).unwrap();
    let cua = bin.join("cmux-cua");
    std::fs::write(&cua, "#!/bin/sh\nexit 0\n").unwrap();
    std::fs::set_permissions(&cua, std::fs::Permissions::from_mode(0o755)).unwrap();
    let cmux_json = root.join("cmux.json");
    std::fs::write(&cmux_json, "{}").unwrap();
    // SAFETY: the only test in this binary; set before any session starts.
    unsafe {
        std::env::set_var("CMUX_AGENT_TOOLS_BIN_DIR", &bin);
        std::env::set_var("CMUX_NEXT_CONFIG_FILE", &cmux_json);
        std::env::set_var("ACPMUX_HOME", root.join("home"));
        std::env::set_var("CMUX_NEXT_CUA_V2_DIR", &endpoint_dir);
        std::env::remove_var("ACPMUX_AGENT_TOOLS");
    }

    let socket = endpoint_dir.join("h.sock");
    let mut helper = start_helper(&socket);
    let endpoint = endpoint_dir.join("endpoint.json");
    let body = json!({"protocol": 1, "socket": socket, "secret": "00ff", "pid": helper.id()});
    std::fs::write(&endpoint, format!("{body}\n")).unwrap();
    std::fs::set_permissions(&endpoint, std::fs::Permissions::from_mode(0o600)).unwrap();

    let hub = hub();
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
    let mut client = Client(in_tx, out_rx, 0);

    // The helper runs: the session's computer use server is the v2 bridge.
    let servers = client.new_session_servers().await;
    assert_eq!(servers[0]["name"], "cmux-cua", "{servers}");
    assert_eq!(servers[0]["args"], json!(["cua-mcp"]), "{servers}");

    // The host crashes: SIGKILL of the exact helper pid this test started.
    helper.kill().unwrap();
    helper.wait().unwrap();
    assert!(endpoint.is_file(), "a SIGKILL leaves endpoint.json behind");

    // The next session gets the legacy server, and the stale file is gone.
    let servers = client.new_session_servers().await;
    assert_eq!(servers[0]["name"], "cmux-cua", "{servers}");
    assert_eq!(servers[0]["command"], json!(cua), "{servers}");
    assert!(!endpoint.exists(), "the stale endpoint.json stayed");

    let _ = std::fs::remove_dir_all(&root);
}

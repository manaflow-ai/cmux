//! Per-workspace displays (cx-ncc.5) and Computer Use. A client names the
//! session's workspace in `_meta.acpmux.workspaceId` on `session/new` (and
//! may on `session/fork`), or only in the session env's `CMUX_WORKSPACE_ID`;
//! two different ids in one request are refused. When this daemon runs with
//! `CMUX_AGENT_DISPLAYS=per-workspace` (a Linux cloud machine with one X
//! display per workspace), no session gets the Computer Use server: the
//! machine's one worker drives the machine's desktop, never a workspace's own
//! display, so fail closed. With the mode off every session gets it.
//!
//! One test function: the mode and the tools are read from this process's
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
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const FAKE_CLAUDE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");
const WS_A: &str = "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d";
const WS_B: &str = "11111111-2222-4333-8444-555555555555";

fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {
            "fake": {"argv": ["python3", FAKE]},
            "fakeclaude": {"argv": ["python3", FAKE_CLAUDE], "kind": "claude-stdio"},
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

    /// `session/new` with `meta` as `_meta.acpmux`: the reply.
    async fn new_reply(&mut self, meta: Value) -> Value {
        let params =
            json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": meta}});
        self.call_text("session/new", params).await.0
    }

    async fn new_session(&mut self, harness: &str, workspace: Option<&str>) -> String {
        let mut meta = json!({"harness": harness});
        if let Some(ws) = workspace {
            meta["workspaceId"] = json!(ws);
        }
        let reply = self.new_reply(meta).await;
        assert!(reply.get("error").is_none(), "{reply}");
        reply["result"]["sessionId"].as_str().unwrap().to_owned()
    }

    /// `session/fork` of `parent` with `meta` as `_meta.acpmux`: the reply.
    async fn fork_reply(&mut self, parent: &str, meta: Value) -> Value {
        let params = json!({"sessionId": parent, "mcpServers": [], "_meta": {"acpmux": meta}});
        self.call_text("session/fork", params).await.0
    }

    async fn fork(&mut self, parent: &str, workspace: Option<&str>) -> String {
        let meta = workspace.map_or_else(|| json!({}), |ws| json!({"workspaceId": ws}));
        let reply = self.fork_reply(parent, meta).await;
        assert!(reply.get("error").is_none(), "{reply}");
        reply["result"]["sessionId"].as_str().unwrap().to_owned()
    }

    async fn ask(&mut self, session: &str, text: &str) -> String {
        let prompt = json!({"sessionId": session, "prompt": [{"type": "text", "text": text}]});
        let (reply, said) = self.call_text("session/prompt", prompt).await;
        assert!(reply.get("error").is_none(), "{reply}");
        said
    }

    /// The `mcpServers` the ACP harness of `session` was given.
    async fn servers(&mut self, session: &str) -> Value {
        serde_json::from_str(&self.ask(session, "mcp").await).unwrap()
    }

    /// The Claude Code MCP config of `session` (its `--mcp-config` file).
    async fn claude_config(&mut self, session: &str) -> Value {
        let argv: Vec<String> = serde_json::from_str(&self.ask(session, "hi").await).unwrap();
        let at = argv.iter().position(|a| a == "--mcp-config").expect("--mcp-config");
        let mut config: Value =
            serde_json::from_str(&std::fs::read_to_string(&argv[at + 1]).unwrap()).unwrap();
        // The servers the cmux server runs behind its code mode, by name.
        let upstreams = config["mcpServers"]["cmux"]["env"]["CMUX_MCP_UPSTREAMS"]
            .as_str()
            .map(|text| serde_json::from_str::<Value>(text).unwrap());
        for upstream in upstreams.iter().flat_map(|u| u.as_array().unwrap().clone()) {
            let name = upstream["name"].as_str().unwrap().to_owned();
            config["mcpServers"][name] = upstream;
        }
        config
    }
}

/// An ACP `mcpServers` list with the servers the cmux server runs behind its
/// code mode (`CMUX_MCP_UPSTREAMS`) listed after it, in the same shape.
fn flat(servers: &Value) -> Vec<Value> {
    let mut out = Vec::new();
    for server in servers.as_array().expect("mcpServers is a list") {
        out.push(server.clone());
        let env = server["env"].as_array().cloned().unwrap_or_default();
        let Some(upstreams) = env.iter().find(|e| e["name"] == "CMUX_MCP_UPSTREAMS") else {
            continue;
        };
        let upstreams: Value = serde_json::from_str(upstreams["value"].as_str().unwrap()).unwrap();
        for upstream in upstreams.as_array().unwrap() {
            let env: Vec<Value> = upstream["env"]
                .as_object()
                .unwrap()
                .iter()
                .map(|(k, v)| json!({"name": k, "value": v}))
                .collect();
            out.push(json!({"name": upstream["name"], "command": upstream["command"],
                "args": upstream["args"], "env": env}));
        }
    }
    out
}

fn names(servers: &Value) -> Vec<String> {
    flat(servers).iter().filter_map(|s| s["name"].as_str().map(str::to_owned)).collect()
}

const CU: &str = "cmux-computer-use";

fn has_cu(servers: &Value) -> bool {
    names(servers).iter().any(|n| n == CU)
}

fn reason(reply: &Value) -> String {
    reply.pointer("/error/data/reason").and_then(Value::as_str).unwrap_or_default().to_owned()
}

fn fake_bin(dir: &Path, name: &str) -> PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let path = dir.join(name);
    std::fs::write(&path, "#!/bin/sh\nexit 0\n").unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    path
}

#[tokio::test]
async fn per_workspace_mode_gives_no_session_computer_use() {
    let root = std::env::temp_dir().join(format!("acpmux-displays-it-{}", uuid::Uuid::now_v7()));
    let bin = root.join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    fake_bin(&bin, "cmux");
    let cmux_json = root.join("cmux-next.json");
    std::fs::write(&cmux_json, "{}").unwrap();
    let home = root.join("home");
    // SAFETY: the only test in this binary; set before any session starts.
    unsafe {
        std::env::set_var("CMUX_AGENT_TOOLS_BIN_DIR", &bin);
        std::env::set_var("CMUX_NEXT_CONFIG_FILE", &cmux_json);
        std::env::set_var("ACPMUX_HOME", &home);
        for key in [
            "ACPMUX_AGENT_TOOLS",
            "ACPMUX_SECRET_TOOLS",
            "ACPMUX_OFFER_TOOLS",
            "CMUX_AGENT_DISPLAYS",
        ] {
            std::env::remove_var(key);
        }
    }
    let first = hub();
    let mut local = client(&first);

    // A malformed workspace id is refused, whatever the mode.
    for bad in [json!("not-a-workspace"), json!(format!("{WS_A}\n")), json!(7), json!("")] {
        let reply = local.new_reply(json!({"harness": "fake", "workspaceId": bad})).await;
        assert_eq!(reason(&reply), "workspace.value_refused", "{bad}: {reply}");
    }

    // Mode off: every session gets Computer Use, with or without a workspace.
    let with_ws = local.new_session("fake", Some(WS_A)).await;
    let servers = local.servers(&with_ws).await;
    assert!(has_cu(&servers), "mode off: {servers}");
    let without = local.new_session("fake", None).await;
    assert!(has_cu(&local.servers(&without).await));

    // SAFETY: as above; no session is starting concurrently.
    unsafe { std::env::set_var("CMUX_AGENT_DISPLAYS", "per-workspace") };

    // Per-workspace displays: no session gets it; the rest of the tools stay.
    for workspace in [Some(WS_A), Some(WS_B), None] {
        let id = local.new_session("fake", workspace).await;
        let servers = local.servers(&id).await;
        assert!(!has_cu(&servers), "{workspace:?}: {servers}");
        assert!(names(&servers).iter().any(|n| n == "cmux"), "the cmux server stays: {servers}");
    }
    // A workspace named only by the session env's CMUX_WORKSPACE_ID (the
    // Chief's subagents, uppercase) is accepted; two different ones are not.
    let env_a = json!({"CMUX_WORKSPACE_ID": WS_A.to_uppercase()});
    for meta in [
        json!({"harness": "fake", "env": env_a}),
        json!({"harness": "fake", "workspaceId": WS_A, "env": env_a}),
    ] {
        let reply = local.new_reply(meta.clone()).await;
        assert!(reply.get("error").is_none(), "{meta}: {reply}");
    }
    let env_b = json!({"CMUX_WORKSPACE_ID": WS_B});
    let reply =
        local.new_reply(json!({"harness": "fake", "workspaceId": WS_A, "env": env_b})).await;
    assert_eq!(reason(&reply), "workspace.mismatch", "{reply}");
    let a = local.new_session("fake", Some(WS_A)).await;
    let leaked = local.ask(&a, "env: ACPMUX_AGENT_WORKSPACE").await;
    assert_eq!(leaked, "ACPMUX_AGENT_WORKSPACE=", "the harness env carries no private key");
    let reply = local.fork_reply(&a, json!({"workspaceId": WS_A, "env": env_b})).await;
    assert_eq!(reason(&reply), "workspace.mismatch", "{reply}");
    let fork = local.fork(&a, Some(WS_B)).await;
    assert!(!has_cu(&local.servers(&fork).await));

    // Claude Code: none in its --mcp-config either.
    let claude = local.new_session("fakeclaude", Some(WS_B)).await;
    let config = local.claude_config(&claude).await;
    assert!(config["mcpServers"].get(CU).is_none(), "{config}");
    assert!(config["mcpServers"].get("cmux").is_some(), "{config}");

    let _ = std::fs::remove_dir_all(&root);
}

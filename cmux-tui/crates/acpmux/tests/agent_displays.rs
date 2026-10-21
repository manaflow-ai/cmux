//! One X display per cmux workspace for computer use (cx-ncc.5). A client
//! names the session's workspace in `_meta.acpmux.workspaceId` on
//! `session/new` (and may on `session/fork`), or only in the session env's
//! `CMUX_WORKSPACE_ID`; two different ids in one request are refused. When
//! this daemon runs with `CMUX_AGENT_DISPLAYS=per-workspace` (a Linux cloud
//! machine), the session's `cmux-cua` MCP server gets `CMUX_CUA_DISPLAY=:N`,
//! one N per workspace from 100 up, kept across restarts. A session without
//! a workspace gets no `cmux-cua` server at all, so it can never drive the
//! shared display. With the mode off nothing changes.
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
const WS_C: &str = "66666666-7777-4888-9999-aaaaaaaaaaaa";

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

/// `CMUX_CUA_DISPLAY` of the `cmux-cua` server in an ACP `mcpServers` list
/// (None: the server has no such key). Panics without a `cmux-cua` server.
fn display(servers: &Value) -> Option<String> {
    let list = flat(servers);
    let cua = list
        .iter()
        .find(|s| s["name"] == "cmux-cua")
        .unwrap_or_else(|| panic!("no cmux-cua server: {servers}"));
    cua["env"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|e| e["name"] == "CMUX_CUA_DISPLAY")
        .and_then(|e| e["value"].as_str().map(str::to_owned))
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
async fn per_workspace_mode_gives_each_workspace_its_own_display_and_none_without_one() {
    let root = std::env::temp_dir().join(format!("acpmux-displays-it-{}", uuid::Uuid::now_v7()));
    let bin = root.join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    fake_bin(&bin, "cmux-cua");
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
            "CMUX_NEXT_CUA_V2_DIR",
            "CMUX_NEXT_CUA_SOCKET",
            "CMUX_CUA_DISPLAY",
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

    // Mode off: the computer use server as before, no display, no state file.
    let with_ws = local.new_session("fake", Some(WS_A)).await;
    let servers = local.servers(&with_ws).await;
    assert_eq!(display(&servers), None, "mode off sets no display: {servers}");
    let without = local.new_session("fake", None).await;
    let servers = local.servers(&without).await;
    assert_eq!(display(&servers), None, "mode off sets no display: {servers}");
    assert!(!home.join("agent-displays").exists(), "mode off allocates nothing");

    // SAFETY: as above; no session is starting concurrently.
    unsafe { std::env::set_var("CMUX_AGENT_DISPLAYS", "per-workspace") };

    // Two workspaces: two displays, from the base up.
    let a = local.new_session("fake", Some(WS_A)).await;
    let a_display = display(&local.servers(&a).await).expect("workspace A has a display");
    assert_eq!(a_display, ":100", "the first workspace gets the base display");
    let b = local.new_session("fake", Some(WS_B)).await;
    let b_display = display(&local.servers(&b).await).expect("workspace B has a display");
    assert_ne!(a_display, b_display, "two workspaces never share a display");
    // The same workspace (in either case) keeps its display.
    let a2 = local.new_session("fake", Some(WS_A.to_uppercase().as_str())).await;
    assert_eq!(display(&local.servers(&a2).await).as_deref(), Some(a_display.as_str()));
    // A workspace named only by the session env's CMUX_WORKSPACE_ID (the
    // Chief's subagents, uppercase) is the session's workspace too.
    let env_a = json!({"CMUX_WORKSPACE_ID": WS_A.to_uppercase()});
    for meta in [
        json!({"harness": "fake", "env": env_a}),
        json!({"harness": "fake", "workspaceId": null, "env": env_a}),
        // Both, the same id in another case: accepted.
        json!({"harness": "fake", "workspaceId": WS_A, "env": env_a}),
    ] {
        let reply = local.new_reply(meta.clone()).await;
        assert!(reply.get("error").is_none(), "{meta}: {reply}");
        let id = reply["result"]["sessionId"].as_str().unwrap().to_owned();
        let servers = local.servers(&id).await;
        assert_eq!(display(&servers).as_deref(), Some(a_display.as_str()), "{meta}: {servers}");
    }
    // Two different workspaces in one request: refused.
    let env_b = json!({"CMUX_WORKSPACE_ID": WS_B});
    let reply =
        local.new_reply(json!({"harness": "fake", "workspaceId": WS_A, "env": env_b})).await;
    assert_eq!(reason(&reply), "workspace.mismatch", "{reply}");
    // The workspace reaches the computer use server only, not the harness.
    let leaked = local.ask(&a, "env: ACPMUX_AGENT_WORKSPACE").await;
    assert_eq!(leaked, "ACPMUX_AGENT_WORKSPACE=", "the harness env carries no private key");

    // No workspace: no computer use server, the rest of the tools stay.
    let none = local.new_session("fake", None).await;
    let servers = local.servers(&none).await;
    let listed = names(&servers);
    assert!(!listed.iter().any(|n| n == "cmux-cua"), "no workspace, no cmux-cua: {servers}");
    assert!(listed.iter().any(|n| n == "cmux"), "the cmux server stays: {servers}");

    // A fork keeps its parent's workspace unless the fork names another.
    let fork_a = local.fork(&a, None).await;
    assert_eq!(display(&local.servers(&fork_a).await).as_deref(), Some(a_display.as_str()));
    let fork_b = local.fork(&a, Some(WS_B)).await;
    assert_eq!(display(&local.servers(&fork_b).await).as_deref(), Some(b_display.as_str()));
    // A fork naming its workspace in env only takes it over its parent's.
    let reply =
        local.fork_reply(&a, json!({"env": {"CMUX_WORKSPACE_ID": WS_B.to_uppercase()}})).await;
    assert!(reply.get("error").is_none(), "{reply}");
    let fork_env = reply["result"]["sessionId"].as_str().unwrap().to_owned();
    assert_eq!(display(&local.servers(&fork_env).await).as_deref(), Some(b_display.as_str()));
    let reply = local.fork_reply(&a, json!({"workspaceId": WS_A, "env": env_b})).await;
    assert_eq!(reason(&reply), "workspace.mismatch", "{reply}");

    // Claude Code: the same display in its --mcp-config; none without a workspace.
    let claude = local.new_session("fakeclaude", Some(WS_B)).await;
    let config = local.claude_config(&claude).await;
    assert_eq!(
        config["mcpServers"]["cmux-cua"]["env"]["CMUX_CUA_DISPLAY"],
        json!(b_display),
        "{config}"
    );
    let claude_none = local.new_session("fakeclaude", None).await;
    let config = local.claude_config(&claude_none).await;
    assert!(config["mcpServers"].get("cmux-cua").is_none(), "{config}");
    assert!(config["mcpServers"].get("cmux").is_some(), "{config}");

    // The allocations are a 0600 file that a restarted daemon reads again.
    let files: Vec<PathBuf> = std::fs::read_dir(home.join("agent-displays"))
        .unwrap()
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x == "json"))
        .collect();
    assert_eq!(files.len(), 1, "{files:?}");
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&files[0]).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600, "{}", files[0].display());
    }
    let restarted = hub();
    let mut again = client(&restarted);
    let b_again = again.new_session("fake", Some(WS_B)).await;
    assert_eq!(display(&again.servers(&b_again).await).as_deref(), Some(b_display.as_str()));
    let c = again.new_session("fake", Some(WS_C)).await;
    let c_display = display(&again.servers(&c).await).expect("workspace C has a display");
    assert!(c_display != a_display && c_display != b_display, "{c_display}");

    let _ = std::fs::remove_dir_all(&root);
}

//! Every local session acpmux starts gets cmux's browser and computer use
//! tools and skills (`agent_tools.rs`): an ACP harness sees the `cmux-cua`
//! and `cmux` (browser REPL) MCP servers in its `session/new`, Claude Code is
//! spawned with them in `--mcp-config` and with the `cmux` skills plugin.
//! (A remote origin gets none: `agent_tools_tests.rs`.)
//!
//! One test function: the tools are read from this process's environment,
//! which every test of a binary shares.

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

fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {
            "fake": {"argv": ["python3", FAKE]},
            "fakeclaude": {"argv": ["python3", FAKE_CLAUDE], "kind": "claude-stdio"},
            "fakecodex": {"argv": ["python3", FAKE], "family": "codex"},
            "fakeclaude-nosearch": {"argv": ["python3", FAKE_CLAUDE], "kind": "claude-stdio",
                "env": {"ENABLE_TOOL_SEARCH": "false"}},
            // Another provider, as the `cmux` profile's open-source model router.
            "fakeclaude-router": {"argv": ["python3", FAKE_CLAUDE], "kind": "claude-stdio",
                "env": {"ANTHROPIC_BASE_URL": "http://127.0.0.1:9/router"}},
            "fakecodex-router": {"argv": ["python3", FAKE], "family": "codex",
                "env": {"OPENAI_BASE_URL": "http://127.0.0.1:9/v1"}},
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

fn fake_bin(dir: &Path, name: &str) -> PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let path = dir.join(name);
    std::fs::write(&path, "#!/bin/sh\nexit 0\n").unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    path
}

#[tokio::test]
async fn local_sessions_get_the_browser_and_cua_tools_and_skills() {
    let root = std::env::temp_dir().join(format!("acpmux-agent-tools-it-{}", uuid::Uuid::now_v7()));
    let bin = root.join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    let cua = fake_bin(&bin, "cmux-cua");
    let cmux = fake_bin(&bin, "cmux");
    // Agent memory is off until cmux.json turns it on (asserted below).
    let chief = fake_bin(&bin, "optchat-chief");
    // A settings file that does not mention MCP: every agent chat still gets
    // the cmux MCP server (cx-wx93i: on by default, `mcp.enabled: false` is off).
    let cmux_json = root.join("cmux-next.json");
    std::fs::write(&cmux_json, r#"{"agents": {"chats": {"enabled": true}}}"#).unwrap();
    // SAFETY: the only test in this binary; set before any session starts.
    unsafe {
        std::env::set_var("CMUX_AGENT_TOOLS_BIN_DIR", &bin);
        std::env::set_var("CMUX_NEXT_CONFIG_FILE", &cmux_json);
        std::env::set_var("ACPMUX_HOME", root.join("home"));
        std::env::remove_var("ACPMUX_AGENT_TOOLS");
        std::env::set_var("ACPMUX_SECRET_TOOLS", "1");
        std::env::set_var("ACPMUX_OFFER_TOOLS", "1");
    }
    let hub = hub();

    // An ACP harness: the servers in session/new, the secret tools (cx-ncc.42)
    // and the offer tool (cx-807da) for this session on this daemon's socket.
    let mut local = client(&hub, Origin::Local);
    let id = local.new_session("fake").await;
    let servers: Value = serde_json::from_str(&local.ask(&id, "mcp").await).unwrap();
    let names: Vec<&str> = servers
        .as_array()
        .expect("mcpServers is a list")
        .iter()
        .filter_map(|s| s["name"].as_str())
        .collect();
    assert_eq!(
        names,
        ["cmux-cua", "cmux-secrets", "cmux-sessions", "cmux-subsessions", "cmux"],
        "{servers}"
    );
    assert_eq!(servers[0]["command"], json!(cua), "{servers}");
    assert_eq!(servers[1]["args"], json!(["secret-mcp"]), "{servers}");
    let secret_env = servers[1]["env"].to_string();
    assert!(secret_env.contains("ACPMUX_SECRET_SESSION") && secret_env.contains(&id), "{servers}");
    assert_eq!(servers[2]["args"], json!(["offer-mcp"]), "{servers}");
    let offer_env = servers[2]["env"].to_string();
    assert!(offer_env.contains("ACPMUX_OFFER_SESSION") && offer_env.contains(&id), "{servers}");
    // Sub-sessions (`subsession_mcp.rs`), on by default: the server acts as
    // this session with its caller token, on this daemon's socket only.
    assert_eq!(servers[3]["args"], json!(["subsession-mcp"]), "{servers}");
    let sub_env = servers[3]["env"].to_string();
    for key in ["ACPMUX_SESSION_ID", "ACPMUX_SESSION_TOKEN", "ACPMUX_SESSION_TOKEN_SOCKET"] {
        assert!(sub_env.contains(key), "{key}: {servers}");
    }
    assert!(sub_env.contains(&id), "{servers}");
    assert_eq!(servers[4]["args"], json!(["mcp", "serve"]), "{servers}");
    // No allowlist: the cmux server speaks code mode.
    assert!(!servers[4]["env"].to_string().contains("CMUX_MCP_TOOLS"), "{servers}");

    // A client cannot set the list on its session: only a preset (the
    // Chief's turns, `chief_builtin_presets.rs`) does.
    let params = json!({"cwd": std::env::temp_dir(), "mcpServers": [],
        "_meta": {"acpmux": {"harness": "fake", "env": {"CMUX_MCP_TOOLS": "render"}}}});
    let (refused, _) = local.call_text("session/new", params).await;
    assert_eq!(refused["error"]["data"]["reason"], "env.key_refused", "{refused}");

    // A harness with its own tool search (Codex; Claude Code below) gets
    // every cmux tool and loads what a turn needs; the rest get code mode.
    let cmux_args = |list: &Value| {
        list.as_array().unwrap().iter().find(|s| s["name"] == "cmux").unwrap()["args"].clone()
    };
    assert_eq!(cmux_args(&servers), json!(["mcp", "serve"]), "code mode: {servers}");
    let codex = local.new_session("fakecodex").await;
    let listed: Value = serde_json::from_str(&local.ask(&codex, "mcp").await).unwrap();
    assert_eq!(cmux_args(&listed), json!(["mcp", "serve", "--all-tools"]), "{listed}");

    // Claude Code: the same servers in --mcp-config, the skills as a plugin,
    // every cmux tool, and its tool search on (it turns it off behind a
    // router by itself).
    let id = local.new_session("fakeclaude").await;
    assert_eq!(local.ask(&id, "env: ENABLE_TOOL_SEARCH").await, "ENABLE_TOOL_SEARCH=true");
    let argv: Vec<String> = serde_json::from_str(&local.ask(&id, "hi").await).unwrap();
    let at = argv.iter().position(|a| a == "--mcp-config").expect("--mcp-config");
    // The config is a 0600 file, so the socket token stays out of argv.
    let config_path = PathBuf::from(&argv[at + 1]);
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&config_path).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600, "{}", config_path.display());
    }
    let config: Value =
        serde_json::from_str(&std::fs::read_to_string(&config_path).unwrap()).unwrap();
    assert_eq!(config["mcpServers"]["cmux-cua"]["command"], json!(cua), "{config}");
    assert_eq!(config["mcpServers"]["cmux"]["command"], json!(cmux), "{config}");
    assert_eq!(config["mcpServers"]["cmux"]["args"], json!(["mcp", "serve", "--all-tools"]));
    // Fail safe: a Claude Code whose profile turns tool search off keeps it
    // off and gets code mode, never every schema in every turn.
    let off = local.new_session("fakeclaude-nosearch").await;
    assert_eq!(local.ask(&off, "env: ENABLE_TOOL_SEARCH").await, "ENABLE_TOOL_SEARCH=false");
    let off_argv: Vec<String> = serde_json::from_str(&local.ask(&off, "hi").await).unwrap();
    let at = off_argv.iter().position(|a| a == "--mcp-config").expect("--mcp-config");
    let off_config: Value =
        serde_json::from_str(&std::fs::read_to_string(&off_argv[at + 1]).unwrap()).unwrap();
    assert_eq!(off_config["mcpServers"]["cmux"]["args"], json!(["mcp", "serve"]), "{off_config}");
    // Fail safe: a session sent to another provider gets code mode and no
    // forced tool search (that provider may not forward deferred tools).
    let routed = local.new_session("fakeclaude-router").await;
    assert_eq!(local.ask(&routed, "env: ENABLE_TOOL_SEARCH").await, "ENABLE_TOOL_SEARCH=");
    let routed_argv: Vec<String> = serde_json::from_str(&local.ask(&routed, "hi").await).unwrap();
    let at = routed_argv.iter().position(|a| a == "--mcp-config").expect("--mcp-config");
    let routed_config: Value =
        serde_json::from_str(&std::fs::read_to_string(&routed_argv[at + 1]).unwrap()).unwrap();
    assert_eq!(routed_config["mcpServers"]["cmux"]["args"], json!(["mcp", "serve"]));
    let codex_routed = local.new_session("fakecodex-router").await;
    let listed: Value = serde_json::from_str(&local.ask(&codex_routed, "mcp").await).unwrap();
    assert_eq!(cmux_args(&listed), json!(["mcp", "serve"]), "{listed}");
    assert_eq!(config["mcpServers"]["cmux-sessions"]["args"], json!(["offer-mcp"]), "{config}");
    assert!(!argv.iter().any(|a| a == "--strict-mcp-config"), "the user's servers stay: {argv:?}");
    let at = argv.iter().position(|a| a == "--plugin-dir").expect("--plugin-dir");
    let plugin = PathBuf::from(&argv[at + 1]);
    let browser = std::fs::read_to_string(plugin.join("skills/cmux-browser/SKILL.md")).unwrap();
    assert!(browser.contains("name: cmux-browser"), "{browser}");
    assert!(plugin.join("skills/cmux-browser/references/repl-guide.md").is_file());
    let cua_skill = std::fs::read_to_string(plugin.join("skills/cmux-cua/SKILL.md")).unwrap();
    assert!(cua_skill.contains("disable-model-invocation: true"), "the consent rule stays");
    // The acpmux CLI guide, pointing at the sub-session tools first.
    let acpmux_skill = std::fs::read_to_string(plugin.join("skills/acpmux/SKILL.md")).unwrap();
    assert!(acpmux_skill.contains("name: acpmux"), "{acpmux_skill}");
    assert!(acpmux_skill.contains("cmux-subsessions") && acpmux_skill.contains("start_session"));
    let manifest: Value = serde_json::from_str(
        &std::fs::read_to_string(plugin.join(".claude-plugin/plugin.json")).unwrap(),
    )
    .unwrap();
    assert_eq!(manifest["name"], "cmux");

    // `agents.memory.enabled` adds the memory server for the next session,
    // with the session as its provenance.
    std::fs::write(&cmux_json, r#"{"agents": {"memory": {"enabled": true}}}"#).unwrap();
    let id = local.new_session("fake").await;
    let servers: Value = serde_json::from_str(&local.ask(&id, "mcp").await).unwrap();
    let memory = servers
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["name"] == "cmux-agent-memory")
        .unwrap_or_else(|| panic!("{servers}"));
    assert_eq!(memory["command"], json!(chief), "{servers}");
    assert_eq!(memory["args"], json!(["agent-memory", "mcp"]), "{servers}");
    assert!(memory["env"].to_string().contains(&id), "{servers}");

    // The switch turns it off for the next session.
    // SAFETY: as above; no session is starting concurrently.
    unsafe { std::env::set_var("ACPMUX_AGENT_TOOLS", "0") };
    let id = local.new_session("fake").await;
    assert_eq!(local.ask(&id, "mcp").await, "[]");

    let _ = std::fs::remove_dir_all(&root);
}

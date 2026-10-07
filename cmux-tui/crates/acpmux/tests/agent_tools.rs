//! Every local session acpmux starts gets cmux's browser and computer use
//! tools and skills (`agent_tools.rs`): an ACP harness sees the `cmux-cua`
//! and `cmux` (browser REPL) MCP servers in its `session/new`, Claude Code is
//! spawned with them in `--mcp-config` and with the `cmux` skills plugin.
//! (A remote origin gets none: `agent_tools_tests.rs`.)
//!
//! One test function: the tools are read from this process's environment,
//! which every test of a binary shares.

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
        let params = json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"harness": harness}}});
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
    let cmux_json = root.join("cmux.json");
    std::fs::write(&cmux_json, r#"{"mcp": {"enabled": true}}"#).unwrap();
    // SAFETY: the only test in this binary; set before any session starts.
    unsafe {
        std::env::set_var("CMUX_AGENT_TOOLS_BIN_DIR", &bin);
        std::env::set_var("CMUX_NEXT_CONFIG_FILE", &cmux_json);
        std::env::set_var("ACPMUX_HOME", root.join("home"));
        std::env::remove_var("ACPMUX_AGENT_TOOLS");
    }
    let hub = hub();

    // An ACP harness: both servers in session/new.
    let mut local = client(&hub, Origin::Local);
    let id = local.new_session("fake").await;
    let servers: Value = serde_json::from_str(&local.ask(&id, "mcp").await).unwrap();
    let names: Vec<&str> = servers
        .as_array()
        .expect("mcpServers is a list")
        .iter()
        .filter_map(|s| s["name"].as_str())
        .collect();
    assert_eq!(names, ["cmux-cua", "cmux"], "{servers}");
    assert_eq!(servers[0]["command"], json!(cua), "{servers}");
    assert_eq!(servers[1]["args"], json!(["mcp", "serve"]), "{servers}");

    // Claude Code: the same servers in --mcp-config, the skills as a plugin.
    let id = local.new_session("fakeclaude").await;
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
    assert!(!argv.iter().any(|a| a == "--strict-mcp-config"), "the user's servers stay: {argv:?}");
    let at = argv.iter().position(|a| a == "--plugin-dir").expect("--plugin-dir");
    let plugin = PathBuf::from(&argv[at + 1]);
    let browser = std::fs::read_to_string(plugin.join("skills/cmux-browser/SKILL.md")).unwrap();
    assert!(browser.contains("name: cmux-browser"), "{browser}");
    assert!(plugin.join("skills/cmux-browser/references/repl-guide.md").is_file());
    let cua_skill = std::fs::read_to_string(plugin.join("skills/cmux-cua/SKILL.md")).unwrap();
    assert!(cua_skill.contains("disable-model-invocation: true"), "the consent rule stays");
    let manifest: Value = serde_json::from_str(
        &std::fs::read_to_string(plugin.join(".claude-plugin/plugin.json")).unwrap(),
    )
    .unwrap();
    assert_eq!(manifest["name"], "cmux");

    // The switch turns it off for the next session.
    // SAFETY: as above; no session is starting concurrently.
    unsafe { std::env::set_var("ACPMUX_AGENT_TOOLS", "0") };
    let id = local.new_session("fake").await;
    assert_eq!(local.ask(&id, "mcp").await, "[]");

    let _ = std::fs::remove_dir_all(&root);
}

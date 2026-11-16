//! An acpmux daemon started in a cmux-tui terminal inherits that terminal's
//! Claude Code plugin folder (`CLAUDE_CODE_PLUGIN_DIRS`), whose hooks report
//! to the terminal. Its agents run in no terminal: they must not get the
//! cmux-tui plugin, and they keep every other plugin folder. A profile that
//! names its own folders keeps them as written.
//!
//! One test function: the daemon's environment is this process's, which
//! every test of a binary shares.

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
const PLUGIN_DIRS: &str = "CLAUDE_CODE_PLUGIN_DIRS";

fn hub(own: &str) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {
            "fake": {"argv": ["python3", FAKE]},
            "fake-own-plugins": {"argv": ["python3", FAKE], "env": {PLUGIN_DIRS: own}},
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

impl Client {
    fn new(hub: &Arc<Hub>) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
        Client(in_tx, out_rx, 0)
    }

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

    /// The `CLAUDE_CODE_PLUGIN_DIRS` a new session of `harness` started with.
    async fn plugin_dirs(&mut self, harness: &str) -> String {
        let params = json!({"cwd": std::env::temp_dir(), "mcpServers": [],
            "_meta": {"acpmux": {"harness": harness}}});
        let (reply, _) = self.call_text("session/new", params).await;
        assert!(reply.get("error").is_none(), "{reply}");
        let session = reply["result"]["sessionId"].as_str().unwrap().to_owned();
        let prompt = json!({"sessionId": session,
            "prompt": [{"type": "text", "text": format!("env: {PLUGIN_DIRS}")}]});
        let (reply, said) = self.call_text("session/prompt", prompt).await;
        assert!(reply.get("error").is_none(), "{reply}");
        said.strip_prefix(&format!("{PLUGIN_DIRS}=")).unwrap_or(&said).to_owned()
    }
}

#[tokio::test]
async fn any_launcher_agents_do_not_inherit_the_cmux_tui_claude_plugin() {
    let root = std::env::temp_dir().join(format!("acpmux-plugin-dirs-{}", uuid::Uuid::now_v7()));
    // The plugin folder of a cmux-tui build (found by its place), a cmux-tui
    // plugin elsewhere (found by its manifest), and the person's own.
    let build = root.join("data/cmux-tui/builds/0123abcd/claude-plugin");
    let named = root.join("named");
    std::fs::create_dir_all(named.join(".claude-plugin")).unwrap();
    std::fs::write(named.join(".claude-plugin/plugin.json"), r#"{"name": "cmux-tui"}"#).unwrap();
    let mine = root.join("mine");
    let join = |folders: &[&Path]| std::env::join_paths(folders).unwrap().into_string().unwrap();
    let own = join(&[&build, &mine]);
    // SAFETY: the only test in this binary; set before any session starts.
    unsafe {
        std::env::set_var("ACPMUX_HOME", root.join("home"));
        std::env::set_var("ACPMUX_AGENT_TOOLS", "0");
        std::env::set_var(PLUGIN_DIRS, join(&[&build, &mine, &named]));
    }
    let hub = hub(&own);
    let mut local = Client::new(&hub);
    assert_eq!(local.plugin_dirs("fake").await, join(&[&mine]));
    // A profile's own value is its own, cmux-tui folders included.
    assert_eq!(local.plugin_dirs("fake-own-plugins").await, own);
    // Only cmux-tui plugins inherited: the agent gets no value.
    // SAFETY: as above; no session is starting concurrently.
    unsafe { std::env::set_var(PLUGIN_DIRS, join(&[&build, &named])) };
    assert_eq!(local.plugin_dirs("fake").await, "");
    let _ = std::fs::remove_dir_all(&root);
}

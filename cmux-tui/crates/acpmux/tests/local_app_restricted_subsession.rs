//! A restricted chat's sub-session (`hub/restricted.rs`, `hub/trust_wait.rs`): with the cmux
//! setting `agents.trust.restrictedChats` on, a restricted chat that starts a Claude Code
//! sub-session in its own folder, which the person answered "Not now" for, gets a restricted
//! sub-session, not a refusal from the folder walk. A folder outside its own that the person did
//! not trust is still refused.
//!
//! One test: the setting is one file in this process's home.

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
use acpmux::trust::Paths;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const CLAUDE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/bin/claude");
const START: &str = "_acpmux/subsession/start";

fn dir(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("arsub-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    for sub in ["work", "other", "home"] {
        std::fs::create_dir_all(d.join(sub)).unwrap();
    }
    std::fs::canonicalize(&d).unwrap()
}

fn hub(d: &Path) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fclaude": {"argv": [CLAUDE], "kind": "claude-stdio"}},
        "defaultHarness": "fclaude",
        "permissionPolicy": "approve-all",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    hub.set_trust_gate(Some(Paths {
        claude_json: d.join("home").join(".claude.json"),
        codex_config: d.join("home").join("config.toml"),
        record: d.join("home").join("trust.json"),
        agent_home: Some(d.join("agent-home")),
        cmux_worktrees: None,
    }));
    hub
}

/// The cmux settings file this process's hub reads (`user_settings.rs`, under HOME).
fn set_restricted_chats(on: bool) {
    let home = PathBuf::from(std::env::var("HOME").expect("HOME"));
    let file = home.join(".config/cmux/cmux-next.json");
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    let doc = json!({"agents": {"trust": {"restrictedChats": on}}});
    std::fs::write(&file, doc.to_string()).unwrap();
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    fn new(hub: &Arc<Hub>, origin: Origin) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
        Client(in_tx, out_rx, 0)
    }

    /// The connection a chat's own tools (or its `cmux` CLI) open: its caller token.
    async fn as_session(hub: &Arc<Hub>, id: &str) -> Self {
        let mut c = Self::new(hub, Origin::Local);
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
            let line = tokio::time::timeout(Duration::from_secs(60), self.1.recv())
                .await
                .unwrap()
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return v;
            }
        }
    }
}

fn reason(v: &Value) -> &str {
    v["error"]["data"]["reason"].as_str().unwrap_or_default()
}

#[tokio::test]
async fn a_restricted_chat_starts_a_restricted_sub_session_in_its_own_folder() {
    let d = dir("restricted");
    let hub = hub(&d);
    let mut app = Client::new(&hub, Origin::LocalApp);
    let (work, other) = (d.join("work"), d.join("other"));
    for folder in [&work, &other] {
        let r = app.call("acp.trust.set", json!({"cwd": folder, "level": "untrusted"})).await;
        assert!(r.get("error").is_none(), "trust.set: {r}");
    }
    set_restricted_chats(true);
    let p = json!({"cwd": work, "mcpServers": [], "_meta": {"acpmux": {"harness": "fclaude"}}});
    let r = app.call("session/new", p).await;
    assert_eq!(r["result"]["_meta"]["acpmux"]["restricted"], json!(true), "{r}");
    let parent = r["result"]["sessionId"].as_str().unwrap().to_owned();

    // Its own folder: a restricted sub-session, no card, no refusal.
    let mut agent = Client::as_session(&hub, &parent).await;
    let started = agent.call(START, json!({"prompt": "hi", "name": "same", "cwd": work})).await;
    assert!(started.get("error").is_none(), "{started}");
    let child = started["result"]["sessionId"].as_str().unwrap();
    assert!(hub.resolve(child).unwrap().meta().restricted, "the sub-session runs restricted");

    // A folder outside its own that the person did not trust is refused, as for any chat.
    let refused = agent.call(START, json!({"prompt": "hi", "name": "out", "cwd": other})).await;
    assert_eq!(reason(&refused), "subsessions.folder_untrusted", "{refused}");

    set_restricted_chats(false);
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&d);
}

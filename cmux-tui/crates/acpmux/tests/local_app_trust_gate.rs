//! The app's agent pane (LocalApp) sends no prompt to an agent while the
//! session's folder has no trust answer: acpmux refuses `session/prompt` with
//! `trust.pending` until the user trusts the folder, and with
//! `trust.untrusted` after "Don't trust". The page cannot get around it: the
//! refusal is in the daemon, on the connection the page uses. The unix socket
//! (the CLI, the TUI) is not gated.

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

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

fn dir(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("atg-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(d.join("work")).unwrap();
    std::fs::create_dir_all(d.join("home")).unwrap();
    std::fs::canonicalize(&d).unwrap()
}

fn paths(d: &Path) -> Paths {
    Paths {
        claude_json: d.join("home").join(".claude.json"),
        codex_config: d.join("home").join("config.toml"),
        record: d.join("home").join("trust.json"),
    }
}

fn hub(d: &Path) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {
            "fclaude": {"argv": ["python3", FAKE], "family": "claude"},
            "fcodex": {"argv": ["python3", FAKE], "family": "codex"},
        },
        "defaultHarness": "fclaude",
        "permissionPolicy": "approve-all",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    hub.set_trust_gate(Some(paths(d)));
    hub
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    fn new(hub: &Arc<Hub>, origin: Origin) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
        Client(in_tx, out_rx, 0)
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(20), self.1.recv())
                .await
                .unwrap()
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return v;
            }
        }
    }

    async fn prompt(&mut self, s: &str, text: &str) -> Value {
        let p = json!({"sessionId": s, "prompt": [{"type": "text", "text": text}]});
        self.call("session/prompt", p).await
    }

    async fn new_session(&mut self, cwd: &Path, harness: &str) -> String {
        let p = json!({"cwd": cwd, "mcpServers": [], "_meta": {"acpmux": {"harness": harness}}});
        let r = self.call("session/new", p).await;
        r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned()
    }

    async fn trust(&mut self, cwd: &Path, level: &str) {
        let r = self.call("acp.trust.set", json!({"cwd": cwd, "level": level})).await;
        assert!(r.get("error").is_none(), "trust.set {level}: {r}");
    }

    /// The prompts the agent took, from the session's own log.
    async fn agent_saw(&mut self, s: &str, text: &str) -> bool {
        let r = self.call("_acpmux/events", json!({"sessionId": s, "limit": 500})).await;
        r.to_string().contains(text)
    }
}

fn reason(v: &Value) -> &str {
    v["error"]["data"]["reason"].as_str().unwrap_or_default()
}

#[tokio::test]
async fn the_local_app_sends_no_prompt_while_the_folders_trust_is_pending() {
    let d = dir("pending");
    let hub = hub(&d);
    let mut app = Client::new(&hub, Origin::LocalApp);
    let work = d.join("work");
    let s = app.new_session(&work, "fclaude").await;

    let r = app.prompt(&s, "secret-before-trust").await;
    assert_eq!(reason(&r), "trust.pending", "{r}");
    assert_eq!(r["error"]["data"]["cwd"], json!(work.to_string_lossy()), "{r}");
    assert!(!app.agent_saw(&s, "secret-before-trust").await, "the agent got the prompt");

    // Don't trust: still no prompt, with its own reason.
    app.trust(&work, "untrusted").await;
    let r = app.prompt(&s, "secret-after-distrust").await;
    assert_eq!(reason(&r), "trust.untrusted", "{r}");
    assert!(!app.agent_saw(&s, "secret-after-distrust").await, "the agent got the prompt");

    // Undo goes back to pending.
    app.trust(&work, "unknown").await;
    assert_eq!(reason(&app.prompt(&s, "again").await), "trust.pending");

    // Trust: the prompt goes.
    app.trust(&work, "trusted").await;
    let r = app.prompt(&s, "hello-after-trust").await;
    assert!(r.get("error").is_none(), "{r}");
    assert!(app.agent_saw(&s, "hello-after-trust").await);
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn the_sessions_own_agent_answers_without_a_decision() {
    let d = dir("harness");
    let hub = hub(&d);
    let mut app = Client::new(&hub, Origin::LocalApp);
    let work = d.join("work");
    // Claude Code accepted its own trust dialog for a parent folder; Codex knows nothing.
    std::fs::write(
        &paths(&d).claude_json,
        json!({"projects": {d.to_string_lossy(): {"hasTrustDialogAccepted": true}}}).to_string(),
    )
    .unwrap();
    let claude = app.new_session(&work, "fclaude").await;
    let r = app.prompt(&claude, "claude-trusted").await;
    assert!(r.get("error").is_none(), "Claude Code's own trust answers: {r}");
    // A Codex session in the same folder still waits for an answer.
    let codex = app.new_session(&work, "fcodex").await;
    assert_eq!(reason(&app.prompt(&codex, "codex-unknown").await), "trust.pending");
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn the_unix_socket_is_not_gated() {
    let d = dir("unix");
    let hub = hub(&d);
    let mut local = Client::new(&hub, Origin::Local);
    let s = local.new_session(&d.join("work"), "fclaude").await;
    let r = local.prompt(&s, "from-the-cli").await;
    assert!(r.get("error").is_none(), "{r}");
    let _ = std::fs::remove_dir_all(&d);
}

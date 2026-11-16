//! A harness CLI that appears after the daemon loaded its catalog serves the next start
//! (hq#12175): a Cloud machine's daemon started with a PATH that had no `claude`, so its
//! catalog had none, and every `cmux-tui acp ensure S -m claude` was refused for the life of
//! the daemon although Claude was installed. A new session's start resolves the harness again.

#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, PermissionPolicy, ProfileSources, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::os::unix::fs::PermissionsExt as _;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE_CLAUDE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");

struct Client {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    next: i64,
}

impl Client {
    fn connect(hub: &Arc<Hub>) -> Self {
        let (tx, in_rx) = mpsc::channel(64);
        let (out_tx, rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::LocalApp));
        Self { tx, rx, next: 0 }
    }

    async fn request(&mut self, m: &str, params: Value) -> Result<Value, String> {
        self.next += 1;
        let id = self.next;
        self.tx.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(60), self.rx.recv())
                .await
                .expect("timeout waiting for response")
                .expect("connection closed");
            if let Message::Response { id: rid, result, error } = Message::parse(&line).unwrap()
                && rid == id
            {
                return match error {
                    Some(e) => Err(e.message),
                    None => Ok(result.unwrap_or(Value::Null)),
                };
            }
        }
    }
}

/// The daemon starts with no `claude` anywhere discovery looks; then Claude Code is installed
/// where its native installer puts it (`~/.local/bin/claude`, which discovery reads beside
/// PATH); then a chat on `claude` starts, with no reload asked for and no restart.
#[tokio::test]
async fn claude_installed_after_the_daemon_loaded_its_catalog_starts_the_next_chat() {
    let home = std::path::PathBuf::from(std::env::var_os("HOME").expect("hermetic HOME"));
    let root = std::env::temp_dir().join(format!("acpmux-rediscover-{}", uuid::Uuid::now_v7()));
    let state = root.join("acpmux");
    let cwd = root.join("work");
    std::fs::create_dir_all(&state).unwrap();
    std::fs::create_dir_all(&cwd).unwrap();
    let claude = home.join(".local/bin/claude");
    assert!(!claude.exists(), "the hermetic HOME holds no claude");

    // The catalog as the daemon loads it at start: config.json, then PATH discovery.
    let path = state.join("config.json");
    Config {
        path: Some(path.clone()),
        profile_sources: ProfileSources::none(),
        permission_policy: PermissionPolicy::ApproveAll,
        ..Config::default()
    }
    .save()
    .unwrap();
    let mut cfg = Config::load_from_with(&path, &ProfileSources::none()).unwrap();
    assert!(cfg.resolve_harness("claude").is_err(), "no claude at the daemon's start");
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, &state).unwrap();
    let hub = Hub::new(cfg, store);
    let mut c = Client::connect(&hub);
    c.request(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "test"}}))
        .await
        .unwrap();
    let new_claude = || {
        json!({"cwd": cwd, "mcpServers": [],
               "_meta": {"acpmux": {"harness": "claude", "name": "after-install"}}})
    };

    // Before the install the start is refused, naming the harness.
    let refused = c.request(method::SESSION_NEW, new_claude()).await.unwrap_err();
    assert!(refused.contains("unknown harness \"claude\""), "{refused}");

    // Claude Code is installed after the daemon started.
    std::fs::create_dir_all(claude.parent().unwrap()).unwrap();
    let script = format!("#!/bin/sh\nexec python3 {} \"$@\"\n", daemon_env::sh_quote(FAKE_CLAUDE));
    std::fs::write(&claude, script).unwrap();
    std::fs::set_permissions(&claude, std::fs::Permissions::from_mode(0o755)).unwrap();

    // The next start finds it.
    let started = c.request(method::SESSION_NEW, new_claude()).await;
    let started = started.unwrap_or_else(|e| panic!("claude did not start after its install: {e}"));
    assert!(started["sessionId"].as_str().is_some(), "{started}");
    assert!(hub.config.read().await.resolve_harness("claude").is_ok());

    let _ = std::fs::remove_file(&claude);
    let _ = std::fs::remove_dir_all(&root);
}

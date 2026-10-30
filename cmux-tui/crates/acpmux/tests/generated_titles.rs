//! Generated chat titles (cx-ncc.91): a session whose harness never titles it
//! (Claude Code's `-p` stream-json has no title event) is titled once, after
//! its first user message, by the configured title command. The tests' command is a
//! fake (`tests/fake_titler.py`): no test reaches a model.

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
const TITLER: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_titler.py");

/// A hub whose title command records each request in `asked`.
fn hub(asked: &Path) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE], "family": "claude"}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all",
        "titles": {"command": ["python3", TITLER, asked]}
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

fn asked_path(name: &str) -> PathBuf {
    let path = std::env::temp_dir().join(format!(
        "acpmux-titles-{name}-{}-{}",
        std::process::id(),
        uuid::Uuid::now_v7()
    ));
    let _ = std::fs::remove_file(&path);
    path
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    fn open(hub: &Arc<Hub>) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
        Self(in_tx, out_rx, 0)
    }

    async fn line(&mut self, within: Duration) -> Option<Value> {
        let line = tokio::time::timeout(within, self.1.recv()).await.ok()??;
        serde_json::from_str(&line).ok()
    }

    async fn call(&mut self, method: &str, params: Value) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, method, params).to_line()).await.unwrap();
        loop {
            let value = self.line(Duration::from_secs(30)).await.expect("no reply");
            if value.get("id") == Some(&json!(id)) {
                assert!(value.get("error").is_none(), "{method}: {value}");
                return value["result"].clone();
            }
        }
    }

    /// Hear every session's `_acpmux/session_changed`, as the app does.
    async fn watch(&mut self) {
        self.call("_acpmux/watch", json!({"enabled": true})).await;
    }

    async fn new_session(&mut self) -> String {
        let created = self
            .call("session/new", json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"harness": "fake"}}}))
            .await;
        created["sessionId"].as_str().unwrap().to_owned()
    }

    async fn prompt(&mut self, session: &str, text: &str) {
        self.call(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": text}]}),
        )
        .await;
    }

    async fn title(&mut self, session: &str) -> Value {
        self.call("_acpmux/info", json!({"sessionId": session})).await["title"].clone()
    }

    /// Wait for the session-changed notification of a `titled` record.
    async fn titled(&mut self, within: Duration) -> Option<Value> {
        let end = tokio::time::Instant::now() + within;
        loop {
            let left = end.saturating_duration_since(tokio::time::Instant::now());
            let value = self.line(left).await?;
            if value.pointer("/params/recordKind") == Some(&json!("titled")) {
                return Some(value);
            }
        }
    }
}

#[tokio::test]
async fn a_chat_its_harness_never_titles_gets_a_short_generated_title_after_its_first_message() {
    let asked = asked_path("generated");
    let hub = hub(&asked);
    let mut client = Client::open(&hub);
    client.watch().await;
    let session = client.new_session().await;

    client.prompt(&session, "Plan a three-dish picnic menu").await;
    let changed = client.titled(Duration::from_secs(15)).await.expect("no titled change");
    assert_eq!(changed.pointer("/params/session/title"), Some(&json!("Three-Dish Picnic Menu")));
    assert_eq!(client.title(&session).await, json!("Three-Dish Picnic Menu"));
    let request = std::fs::read_to_string(&asked).unwrap();
    assert!(request.contains("Plan a three-dish picnic menu"), "{request}");

    // Once per session: a later turn neither asks again nor retitles it.
    client.prompt(&session, "now make it vegetarian").await;
    assert!(client.titled(Duration::from_secs(2)).await.is_none(), "titled twice");
    assert_eq!(std::fs::read_to_string(&asked).unwrap().matches("---").count(), 1);
    assert_eq!(client.title(&session).await, json!("Three-Dish Picnic Menu"));
    let _ = std::fs::remove_file(&asked);
    let _ = std::fs::remove_file(cwd_path(&asked));
}

fn cwd_path(asked: &Path) -> PathBuf {
    PathBuf::from(format!("{}.cwd", asked.display()))
}

/// The title command runs in acpmux's own empty `unattended` folder, never
/// the shared temp dir or the daemon's folder: Claude Code indexes its cwd at
/// start (`rg --files --hidden <cwd>`), and a titler per finished chat that
/// scanned all of `$TMPDIR` pegged the Mac's CPU.
#[tokio::test]
async fn the_title_command_runs_in_an_empty_folder_of_its_own() {
    let asked = asked_path("cwd");
    let hub = hub(&asked);
    let mut client = Client::open(&hub);
    client.watch().await;
    let session = client.new_session().await;

    client.prompt(&session, "Plan a three-dish picnic menu").await;
    client.titled(Duration::from_secs(15)).await.expect("no titled change");
    let cwd = PathBuf::from(std::fs::read_to_string(cwd_path(&asked)).unwrap());
    let name = cwd.file_name().and_then(|n| n.to_str()).unwrap_or_default().to_owned();
    assert!(name.ends_with("unattended"), "title command ran in {}", cwd.display());
    let tmp = std::fs::canonicalize(std::env::temp_dir()).unwrap();
    assert_ne!(std::fs::canonicalize(&cwd).unwrap(), tmp, "title command ran in $TMPDIR");
    let _ = std::fs::remove_file(&asked);
    let _ = std::fs::remove_file(cwd_path(&asked));
}

#[tokio::test]
async fn a_harness_title_wins_and_nothing_is_generated() {
    let asked = asked_path("harness");
    let hub = hub(&asked);
    let mut client = Client::open(&hub);
    client.watch().await;
    let session = client.new_session().await;

    client.prompt(&session, "harness-title: Picnic planning").await;
    assert!(
        client.titled(Duration::from_secs(2)).await.is_none(),
        "generated over a harness title"
    );
    assert_eq!(client.title(&session).await, json!("Picnic planning"));
    assert!(!asked.exists(), "the title command ran for a titled session");
}

/// A chat the person named (at its start, or by a rename before its first reply) keeps that
/// name: no title request goes to a model for it (user 2026-10-20).
#[tokio::test]
async fn a_chat_the_person_named_asks_no_model_for_a_title() {
    let asked = asked_path("named");
    let hub = hub(&asked);
    let mut client = Client::open(&hub);
    client.watch().await;
    let created = client
        .call(
            "session/new",
            json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"harness": "fake", "name": "picnic-plan"}}}),
        )
        .await;
    let named = created["sessionId"].as_str().unwrap().to_owned();
    client.prompt(&named, "Plan a three-dish picnic menu").await;
    assert!(client.titled(Duration::from_secs(3)).await.is_none(), "titled a named chat");

    let renamed = client.new_session().await;
    client.call("_acpmux/rename", json!({"sessionId": renamed, "newName": "menu-ideas"})).await;
    client.prompt(&renamed, "Plan a three-dish picnic menu").await;
    assert!(client.titled(Duration::from_secs(3)).await.is_none(), "titled a renamed chat");
    assert!(!asked.exists(), "the title command ran: {:?}", std::fs::read_to_string(&asked));
}

#[tokio::test]
async fn generated_titles_can_be_disabled_without_removing_the_prompt_placeholder() {
    let asked = asked_path("off");
    let hub = hub(&asked);
    hub.config.write().await.titles.generate = Some(false);
    let mut client = Client::open(&hub);
    client.watch().await;
    let session = client.new_session().await;

    client.prompt(&session, "Plan a three-dish picnic menu").await;
    assert!(client.titled(Duration::from_secs(2)).await.is_none(), "titled while disabled");
    assert_eq!(client.title(&session).await, json!("Plan a three-dish picnic menu"));
    assert!(!asked.exists(), "the title command ran while disabled");
}

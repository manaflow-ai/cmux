//! A session an agent starts inherits its starter's permission policy and mode when the start
//! asks for neither, and never runs wider than its starter (`hub/start_gate.rs`, "Inherit").
//! Covers `session/new` from inside a chat (`acpmux new|run`), a local `_acpmux/dispatch`, and
//! the sub-session start (`start_session`, `acpmux new --parent`). A start with no proven
//! caller (the CLI outside any chat) is unchanged: the daemon default policy and the person's
//! start mode.
//!
//! Leo (2026-10-25): "it shouldn't sub-agents just inherit the bypass permission situation?"

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

/// `fake` and `kin` are two families of the same stand-in; both offer `normal`, `strict` (they
/// ask) and `full-access`. The person's start level is `standard` (the harness's own mode,
/// `normal`), so a child that ends in `full-access` got there by inheriting it.
fn hub() -> Arc<Hub> {
    let _ = &HERMETIC;
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {
            "fake": {"argv": ["python3", FAKE], "env": {"FAKE_FULL_ACCESS": "1"}},
            "kin": {"argv": ["python3", FAKE], "family": "kin", "env": {"FAKE_FULL_ACCESS": "1"}},
        },
        "defaultHarness": "fake",
        "permissionPolicy": "ask",
        "defaultPermissionMode": "standard",
        "webAskingModes": {"fake": ["normal", "strict"], "kin": ["normal", "strict"]},
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    /// The CLI outside any chat: a unix socket connection with no caller.
    fn new(hub: &Arc<Hub>) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
        Client(in_tx, out_rx, 0)
    }

    /// The CLI inside chat `id`: `initialize` with the caller token acpmux gave its agent.
    async fn as_session(hub: &Arc<Hub>, id: &str) -> Self {
        let mut c = Self::new(hub);
        let token = acpmux::hub::person::caller_token(id);
        c.ok(
            "initialize",
            json!({"protocolVersion": 1,
                   "_meta": {"acpmux": {"callerSession": {"sessionId": id, "token": token}}}}),
        )
        .await;
        c
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .expect("an answer in time")
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return v;
            }
        }
    }

    async fn ok(&mut self, m: &str, params: Value) -> Value {
        let r = self.call(m, params).await;
        assert!(r.get("error").is_none(), "{m}: {r}");
        r["result"].clone()
    }

    /// A session's mode and own policy (null: the daemon default).
    async fn level(&mut self, id: &str) -> (String, Value) {
        let r = self.ok("_acpmux/info", json!({"sessionId": id})).await;
        let mode = r["modes"]["currentModeId"].as_str().unwrap_or_default().to_owned();
        (mode, r["policy"].clone())
    }

    async fn prompt(&mut self, id: &str, text: &str) -> Value {
        self.ok(
            "session/prompt",
            json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]}),
        )
        .await
    }
}

fn new_params(meta: Value) -> Value {
    json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": meta}})
}

fn id(v: &Value) -> String {
    v["sessionId"].as_str().expect("a session id").to_owned()
}

/// A starter chat on `fake` with own policy `policy` (none: the daemon default), whose harness
/// then moves itself to `mode` when one is given.
async fn starter(app: &mut Client, policy: Option<&str>, mode: Option<&str>) -> String {
    let mut meta = json!({"harness": "fake"});
    if let Some(p) = policy {
        meta["policy"] = json!(p);
    }
    let parent = id(&app.ok("session/new", new_params(meta)).await);
    if let Some(m) = mode {
        app.prompt(&parent, &format!("set-mode: {m}")).await;
        assert_eq!(app.level(&parent).await.0, m, "the starter runs in {m}");
    }
    parent
}

/// The text a session's last turn replied.
async fn last_reply(app: &mut Client, id: &str) -> String {
    let r = app.ok("_acpmux/info", json!({"sessionId": id})).await;
    r["lastMessage"]["text"].as_str().unwrap_or_default().to_owned()
}

#[tokio::test]
async fn a_full_access_agent_starts_a_child_in_full_access_that_runs_a_command_without_asking() {
    let hub = hub();
    let mut app = Client::new(&hub);
    let parent = starter(&mut app, Some("approve-all"), Some("full-access")).await;
    let mut agent = Client::as_session(&hub, &parent).await;
    // `acpmux new` from the parent's shell, no --policy, no --mode.
    let child = id(&agent.ok("session/new", new_params(json!({"harness": "fake"}))).await);
    assert_eq!(
        app.level(&child).await,
        ("full-access".to_owned(), json!("approve-all")),
        "the child runs its starter's mode and policy"
    );
    // The harness asks before a shell command; the inherited policy answers it.
    app.prompt(&child, "ask: rm f/*; ffmpeg -i reel.mp4 sheet.jpg").await;
    // Answered by the policy, not left waiting for a person (the prompt above returned).
    assert_eq!(last_reply(&mut app, &child).await, "chose yes");
}

#[tokio::test]
async fn a_full_access_agent_starts_a_child_of_another_family_in_that_familys_full_access() {
    let hub = hub();
    let mut app = Client::new(&hub);
    let parent = starter(&mut app, Some("approve-all"), Some("full-access")).await;
    let mut agent = Client::as_session(&hub, &parent).await;
    let child = id(&agent.ok("session/new", new_params(json!({"harness": "kin"}))).await);
    assert_eq!(app.level(&child).await, ("full-access".to_owned(), json!("approve-all")));
}

#[tokio::test]
async fn an_approve_edits_starter_gives_approve_edits_and_an_ask_starter_gives_ask() {
    let hub = hub();
    let mut app = Client::new(&hub);
    for policy in ["approve-edits", "ask"] {
        let parent = starter(&mut app, Some(policy), None).await;
        let (parent_mode, _) = app.level(&parent).await;
        let mut agent = Client::as_session(&hub, &parent).await;
        let child = id(&agent.ok("session/new", new_params(json!({"harness": "fake"}))).await);
        assert_eq!(app.level(&child).await, (parent_mode, json!(policy)), "{policy} starter");
    }
}

#[tokio::test]
async fn an_explicit_wider_mode_from_an_asking_starter_is_refused() {
    let hub = hub();
    let mut app = Client::new(&hub);
    let parent = starter(&mut app, None, Some("strict")).await;
    let mut agent = Client::as_session(&hub, &parent).await;
    let r = agent
        .call("session/new", new_params(json!({"harness": "fake", "mode": "full-access"})))
        .await;
    assert_eq!(r["error"]["data"]["reason"], "permission.person_required", "{r}");
    // With no mode asked, it starts in its starter's.
    let child = id(&agent.ok("session/new", new_params(json!({"harness": "fake"}))).await);
    assert_eq!(app.level(&child).await, ("strict".to_owned(), Value::Null));
}

#[tokio::test]
async fn a_start_with_no_proven_caller_is_unchanged() {
    let hub = hub();
    let mut app = Client::new(&hub);
    let parent = starter(&mut app, Some("approve-all"), Some("full-access")).await;
    // The CLI outside any chat, and one that names the chat with a token that proves nothing.
    let mut cli = Client::new(&hub);
    let plain = id(&cli.ok("session/new", new_params(json!({"harness": "fake"}))).await);
    assert_eq!(app.level(&plain).await, ("normal".to_owned(), Value::Null));
    let mut forged = Client::new(&hub);
    let token = "0".repeat(64);
    forged
        .call(
            "initialize",
            json!({"protocolVersion": 1,
                   "_meta": {"acpmux": {"callerSession": {"sessionId": parent, "token": token}}}}),
        )
        .await;
    let r = forged.call("session/new", new_params(json!({"harness": "fake"}))).await;
    if let Some(s) = r["result"]["sessionId"].as_str() {
        assert_eq!(app.level(s).await, ("normal".to_owned(), Value::Null));
    }
}

#[tokio::test]
async fn a_dispatched_child_inherits_its_starters_mode_and_policy() {
    let hub = hub();
    let mut app = Client::new(&hub);
    let parent = starter(&mut app, Some("approve-all"), Some("full-access")).await;
    let mut agent = Client::as_session(&hub, &parent).await;
    let r = agent
        .ok(
            "_acpmux/dispatch",
            json!({"brief": "echo dispatched", "host": "local", "harness": "fake",
                   "cwd": std::env::temp_dir()}),
        )
        .await;
    let child = r["brief"]["sessionId"].as_str().expect("the brief's session").to_owned();
    assert_eq!(app.level(&child).await, ("full-access".to_owned(), json!("approve-all")));
}

#[tokio::test]
async fn a_sub_session_of_another_family_inherits_its_parents_full_access() {
    let hub = hub();
    let mut app = Client::new(&hub);
    let parent = starter(&mut app, Some("approve-all"), Some("full-access")).await;
    let mut agent = Client::as_session(&hub, &parent).await;
    for harness in ["fake", "kin"] {
        let r = agent
            .ok("_acpmux/subsession/start", json!({"prompt": "echo child", "harness": harness}))
            .await;
        let child = id(&r);
        assert_eq!(
            app.level(&child).await,
            ("full-access".to_owned(), json!("approve-all")),
            "a {harness} child"
        );
    }
}

#[tokio::test]
async fn a_sub_session_of_another_family_under_an_asking_parent_starts_in_its_asking_mode() {
    let hub = hub();
    let mut app = Client::new(&hub);
    let parent = starter(&mut app, None, Some("strict")).await;
    let mut agent = Client::as_session(&hub, &parent).await;
    let r = agent
        .ok("_acpmux/subsession/start", json!({"prompt": "echo child", "harness": "kin"}))
        .await;
    let (mode, policy) = app.level(&id(&r)).await;
    assert!(mode == "normal" || mode == "strict", "an asking mode: {mode}");
    assert_eq!(policy, Value::Null);
}

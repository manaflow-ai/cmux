//! `acpmux new|run --parent SESSION` (`_acpmux/subsession/start {parent}`, `server/subsessions.rs`):
//! a chat's agent starts a child of another harness family from its shell, and the child belongs
//! to that chat the way a `start_session` sub-session does: the parent lists it among its
//! `children`, the child names it as `startedBy`, and the parent's log gets the child's
//! `subsession` records, `started` (running) and `turn_ended` (done or failed, with its typed
//! result) (`hub/subsession_results.rs`). Only the parent's own caller, or the person, names it.

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
const START: &str = "_acpmux/subsession/start";
/// The person key these hubs hold, as a daemon the app started does.
const PERSON_KEY: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

/// Two harnesses of two families: the parent's `lead` (it has a full-access mode) and the
/// child's `coder` (OpenCode's modes).
fn hub() -> Arc<Hub> {
    let fake =
        |family: &str, env: Value| json!({"argv": ["python3", FAKE], "family": family, "env": env});
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {
            "lead": fake("fake", json!({"FAKE_FULL_ACCESS": "1"})),
            "coder": fake("opencode", json!({"FAKE_PLAN_MODE": "1"})),
        },
        "defaultHarness": "lead",
        "permissionPolicy": "approve-all"
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let _ = hub.person.install_spawn_key(PERSON_KEY);
    hub
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    /// A unix socket connection that proves nothing.
    fn open(hub: &Arc<Hub>) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
        Self(in_tx, out_rx, 0)
    }

    /// The app: `initialize`, then the person proof (`hub/person.rs`).
    async fn person(hub: &Arc<Hub>) -> Self {
        let mut c = Self::open(hub);
        let init = c.ok("initialize", json!({"protocolVersion": 1})).await;
        let challenge = &init["_meta"]["acpmux"]["personChallenge"];
        let proof = acpmux::hub::person::person_proof(
            PERSON_KEY,
            acpmux::hub::person::TRANSPORT_UNIX,
            challenge["nonce"].as_str().unwrap(),
            challenge["connection"].as_str().unwrap(),
        )
        .unwrap();
        let proved = c.ok("_acpmux/person_prove", json!({"proof": proof})).await;
        assert_eq!(proved["person"], true, "{proved}");
        c
    }

    /// The acpmux CLI run from session `id`'s shell: `initialize` with its caller token.
    async fn shell_of(hub: &Arc<Hub>, id: &str) -> Self {
        let mut c = Self::open(hub);
        let token = acpmux::hub::person::caller_token(id);
        let caller = json!({"callerSession": {"sessionId": id, "token": token}});
        c.ok("initialize", json!({"protocolVersion": 1, "_meta": {"acpmux": caller}})).await;
        c
    }

    async fn reply(&mut self, method: &str, params: Value) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, method, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .expect("timed out")
                .expect("connection closed");
            let value: Value = serde_json::from_str(&line).unwrap();
            if value.get("id") == Some(&json!(id)) {
                return value;
            }
        }
    }

    async fn ok(&mut self, method: &str, params: Value) -> Value {
        let value = self.reply(method, params).await;
        assert!(value.get("error").is_none(), "{method}: {value}");
        value["result"].clone()
    }

    async fn refused(&mut self, method: &str, params: Value) -> Value {
        let value = self.reply(method, params).await;
        assert!(value.get("error").is_some(), "{method} should be refused: {value}");
        value["error"].clone()
    }

    /// A `lead` chat the person starts, in full access: a child of another family starts
    /// only under a parent in full access (`subsession_guard.rs`).
    async fn lead(&mut self) -> String {
        let new = json!({"cwd": std::env::temp_dir(), "mcpServers": [],
                         "_meta": {"acpmux": {"harness": "lead"}}});
        let id = self.ok("session/new", new).await["sessionId"].as_str().unwrap().to_owned();
        let info = self.ok("_acpmux/info", json!({"sessionId": id})).await;
        if info["modes"]["currentModeId"] != "full-access" {
            let mode = json!({"sessionId": id, "modeId": "full-access"});
            self.ok("session/set_mode", mode).await;
        }
        id
    }

    async fn summary(&mut self, id: &str) -> Value {
        let list = self.ok("_acpmux/sessions", json!({})).await;
        let found = list["sessions"].as_array().unwrap().iter().find(|s| s["sessionId"] == id);
        found.cloned().unwrap_or_else(|| panic!("{id} is not listed: {list}"))
    }
}

/// The `subsession` record `event` of `child` on `parent`'s log, once it is there.
async fn record(hub: &Hub, parent: &str, child: &str, event: &str) -> Value {
    for _ in 0..200 {
        let events = hub.events(parent, 0, 10_000).unwrap();
        let found = events.into_iter().find(|e| {
            e.dir == "mux"
                && e.kind == "subsession"
                && e.msg["event"] == event
                && e.msg["childSessionId"] == child
        });
        if let Some(e) = found {
            return e.msg;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!("no {event} record of {child} on {parent}");
}

#[tokio::test]
async fn a_chat_starts_a_child_of_another_family_from_its_shell() {
    let hub = hub();
    let mut app = Client::person(&hub).await;
    let parent = app.lead().await;
    // Its agent runs `acpmux run --parent $ACPMUX_SESSION_ID -m coder -e high hello`.
    let mut shell = Client::shell_of(&hub, &parent).await;
    let params = json!({"parent": parent, "prompt": "hello", "harness": "coder", "effort": "high"});
    let started = shell.ok(START, params).await;
    let child = started["sessionId"].as_str().unwrap().to_owned();
    assert_eq!(started["harness"], "coder", "{started}");

    // Linked as a sub-session: the parent counts it, the child names its parent.
    assert_eq!(app.summary(&parent).await["children"], 1);
    let row = app.summary(&child).await;
    assert_eq!(row["startedBy"], parent.as_str(), "{row}");
    assert_eq!(row["spawnedBy"], parent.as_str(), "{row}");
    assert_eq!(row["depth"], 1, "{row}");
    assert_eq!(row["harness"], "coder", "{row}");

    let on = record(&hub, &parent, &child, "started").await;
    assert_eq!(on["state"], "running", "{on}");
    assert_eq!(on["startedBy"], parent.as_str(), "{on}");
    assert_eq!(on["harness"], "coder", "{on}");
    assert_eq!(on["effort"], "high", "{on}");
    assert_eq!(on["prompt"], "hello", "{on}");
    assert_eq!(on["depth"], 1, "{on}");
    assert!(on["shortName"].is_string(), "{on}");

    let end = record(&hub, &parent, &child, "turn_ended").await;
    assert_eq!(end["state"], "done", "{end}");
    assert_eq!(end["harness"], "coder", "{end}");
    let result = &end["result"];
    assert_eq!(result["state"], "done", "{end}");
    assert_eq!(result["stopReason"], "end_turn", "{end}");
    assert_eq!(result["reply"], "echo: hello", "{end}");
    assert!(result["turnId"].is_string(), "{end}");
    assert!(result["error"].is_null(), "{end}");
    // One cycle, in order: `started` before its turn's end, each once.
    let cycle = records(&hub, &parent, &child);
    assert_eq!(cycle, ["started", "turn_ended"], "{cycle:?}");

    // A turn that fails says so, with its error.
    let params = json!({"parent": parent, "prompt": "fail-once: x", "harness": "coder"});
    let failing = shell.ok(START, params).await["sessionId"].as_str().unwrap().to_owned();
    let end = record(&hub, &parent, &failing, "turn_ended").await;
    assert_eq!(end["state"], "failed", "{end}");
    assert_eq!(end["result"]["state"], "failed", "{end}");
    assert!(end["result"]["error"].is_string(), "{end}");

    // A turn stopped while it runs ends cancelled.
    let params = json!({"parent": parent, "prompt": "until-cancel", "harness": "coder"});
    let slow = shell.ok(START, params).await["sessionId"].as_str().unwrap().to_owned();
    record(&hub, &parent, &slow, "started").await;
    // Once its agent streams, as the person's Stop.
    for _ in 0..200 {
        let events = hub.events(&slow, 0, 10_000).unwrap();
        if events.iter().any(|e| e.kind == "agent_message_chunk") {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let cancel = Message::notification("session/cancel", json!({"sessionId": slow}));
    app.0.send(cancel.to_line()).await.unwrap();
    let end = record(&hub, &parent, &slow, "turn_ended").await;
    assert_eq!(end["state"], "cancelled", "{end}");
    assert_eq!(end["result"]["stopReason"], "cancelled", "{end}");
    assert_eq!(app.summary(&parent).await["children"], 3);
}

/// The `subsession` events of `child` on `parent`'s log, oldest first.
fn records(hub: &Hub, parent: &str, child: &str) -> Vec<String> {
    let events = hub.events(parent, 0, 10_000).unwrap();
    let ours = events
        .into_iter()
        .filter(|e| e.dir == "mux" && e.kind == "subsession" && e.msg["childSessionId"] == child);
    ours.map(|e| e.msg["event"].as_str().unwrap_or_default().to_owned()).collect()
}

#[tokio::test]
async fn only_the_parents_own_caller_or_the_person_names_it() {
    let hub = hub();
    let mut app = Client::person(&hub).await;
    let parent = app.lead().await;
    let other = app.lead().await;
    let mut shell = Client::shell_of(&hub, &parent).await;

    // A session that is not the caller nor one of its sub-sessions.
    let params = json!({"parent": other, "prompt": "hello", "harness": "coder"});
    let e = shell.refused(START, params.clone()).await;
    assert_eq!(e["data"]["reason"], "subsessions.not_family", "{e}");
    // A connection that proves neither a session nor the person.
    let e = Client::open(&hub).refused(START, params.clone()).await;
    assert_eq!(e["data"]["reason"], "subsessions.caller_required", "{e}");
    assert_eq!(app.summary(&other).await["children"], 0);

    // The person names any chat here.
    let started = app.ok(START, params).await;
    let child = started["sessionId"].as_str().unwrap();
    assert_eq!(app.summary(child).await["startedBy"], other.as_str());
    assert_eq!(app.summary(&other).await["children"], 1);
}

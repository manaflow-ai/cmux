//! The runaway guard for agent-to-agent messages (`hub/agent_pairs.rs`): two sessions that keep
//! messaging each other with no tool call or file change in between, or one that keeps sending
//! the same message, are paused as a pair. A paused pair's messages are held, not delivered, and
//! both transcripts say so; `_acpmux/agent_pair_resume` (or the person prompting either session)
//! delivers them in order. Sessions whose turns do work are never paused, however many messages
//! they exchange: there is no cap per turn.

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
const RESUME: &str = "_acpmux/agent_pair_resume";

fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE], "family": "codex"}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    fn open(hub: &Arc<Hub>) -> Self {
        Self::open_as(hub, Origin::Local)
    }

    fn open_as(hub: &Arc<Hub>, origin: Origin) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
        Self(in_tx, out_rx, 0)
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

    async fn call(&mut self, method: &str, params: Value) -> Value {
        let value = self.reply(method, params).await;
        assert!(value.get("error").is_none(), "{method}: {value}");
        value["result"].clone()
    }

    async fn new_session(&mut self) -> String {
        let new = json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"harness": "fake"}}});
        self.call("session/new", new).await["sessionId"].as_str().unwrap().to_owned()
    }

    /// `from` messages `to` as `cmux agent message` does, and waits for the turn it starts (or
    /// the refusal): the whole `session/prompt` reply.
    async fn message(&mut self, from: &str, to: &str, msg_id: &str, text: &str) -> Value {
        let provenance = json!({"kind": "agent_message", "from": format!("acp:{from}"),
            "fromName": "agent", "to": format!("acp:{to}"), "msgId": msg_id, "threadId": "t-1"});
        let params = json!({"sessionId": to, "prompt": [{"type": "text", "text": text}],
            "_meta": {"acpmux": {"promptId": msg_id, "provenance": provenance}}});
        self.reply("session/prompt", params).await
    }

    async fn records(&mut self, session: &str, kind: &str) -> Vec<Value> {
        let page =
            self.call("_acpmux/events", json!({"sessionId": session, "kinds": [kind]})).await;
        page["events"].as_array().unwrap().iter().map(|e| e["msg"].clone()).collect()
    }

    async fn ran(&mut self, session: &str, prompt_id: &str) -> bool {
        self.records(session, "user_message").await.iter().any(|m| m["promptId"] == prompt_id)
    }

    /// Waits until `session`'s log has a `user_message` for `prompt_id` (a spawned release).
    async fn wait_ran(&mut self, session: &str, prompt_id: &str) {
        let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
        while !self.ran(session, prompt_id).await {
            assert!(tokio::time::Instant::now() < deadline, "{prompt_id} never ran");
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    }
}

fn held(reply: &Value) -> bool {
    reply.pointer("/error/data/reason") == Some(&json!("agent_pair.paused"))
}

/// Six exchanges back and forth whose turns make no tool call: the sixth is held, both
/// transcripts record the pause, and a resume delivers the held message.
#[tokio::test]
async fn sessions_that_message_back_and_forth_without_progress_are_paused() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let (a, b) = (c.new_session().await, c.new_session().await);
    let words = ["what should we do next", "you decide", "no you pick one", "either works for me"];
    for (i, text) in words.iter().chain(["fine by me"].iter()).enumerate() {
        let (from, to) = if i % 2 == 0 { (&a, &b) } else { (&b, &a) };
        let reply = c.message(from, to, &format!("m{i}"), text).await;
        assert!(reply.get("error").is_none(), "exchange {i} was delivered: {reply}");
    }
    // The sixth exchange in a row with no progress trips the guard.
    let sixth = c.message(&b, &a, "m5", "your call then").await;
    assert!(held(&sixth), "the sixth exchange is held: {sixth}");
    let text = sixth.pointer("/error/message").and_then(Value::as_str).unwrap_or("");
    assert!(text.contains("resume"), "the sender reads that the user resumes it: {text}");
    assert!(!c.ran(&a, "m5").await, "a held message does not run");
    for session in [&a, &b] {
        let paused = c.records(session, "agent_pair_paused").await;
        assert_eq!(paused.len(), 1, "{session}: {paused:?}");
        assert_eq!(paused[0]["reason"], "alternating", "{paused:?}");
    }
    let held_records = c.records(&a, "agent_pair_held").await;
    assert_eq!(held_records.len(), 1, "{held_records:?}");
    assert_eq!(held_records[0]["promptId"], "m5", "{held_records:?}");
    // While paused, the pair's later messages are held too, either way.
    let later = c.message(&a, &b, "m6", "ok").await;
    assert!(held(&later), "{later}");

    let resumed = c.call(RESUME, json!({"sessionId": a})).await;
    assert_eq!(resumed["resumed"], 1, "{resumed}");
    assert_eq!(resumed["delivered"], 2, "{resumed}");
    c.wait_ran(&a, "m5").await;
    c.wait_ran(&b, "m6").await;
    for session in [&a, &b] {
        let records = c.records(session, "agent_pair_resumed").await;
        assert_eq!(records.len(), 1, "{session}: {records:?}");
        assert_eq!(records[0]["by"], "request", "{records:?}");
    }
    // A resumed pair starts counting again.
    let after = c.message(&a, &b, "m7", "thanks").await;
    assert!(after.get("error").is_none(), "{after}");
}

/// The same message three times from one sender to one receiver: the third is held.
#[tokio::test]
async fn a_sender_repeating_the_same_message_is_paused() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let (a, b) = (c.new_session().await, c.new_session().await);
    let first = c.message(&a, &b, "r1", "Please check the build, run 1").await;
    assert!(first.get("error").is_none(), "{first}");
    let second = c.message(&a, &b, "r2", "please  check the BUILD, run 2").await;
    assert!(second.get("error").is_none(), "{second}");
    let third = c.message(&a, &b, "r3", "Please check the build, run 3").await;
    assert!(held(&third), "the third near-identical message is held: {third}");
    let paused = c.records(&b, "agent_pair_paused").await;
    assert_eq!(paused.len(), 1, "{paused:?}");
    assert_eq!(paused[0]["reason"], "repeating", "{paused:?}");

    // The person prompting either session resumes the pair and delivers what it held.
    c.call(
        "session/prompt",
        json!({"sessionId": a, "prompt": [{"type": "text", "text": "stop and summarize"}]}),
    )
    .await;
    c.wait_ran(&b, "r3").await;
    let resumed = c.records(&b, "agent_pair_resumed").await;
    assert_eq!(resumed.len(), 1, "{resumed:?}");
    assert_eq!(resumed[0]["by"], "person", "{resumed:?}");
}

/// Two sessions whose turns each make a tool call are never paused, however many messages they
/// exchange and however alike the messages are: there is no cap per turn.
#[tokio::test]
async fn sessions_whose_turns_do_work_are_never_paused() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let (a, b) = (c.new_session().await, c.new_session().await);
    for i in 0..12 {
        let (from, to) = if i % 2 == 0 { (&a, &b) } else { (&b, &a) };
        let reply = c.message(from, to, &format!("w{i}"), "do-work on the next step").await;
        assert!(reply.get("error").is_none(), "exchange {i} was delivered: {reply}");
    }
    assert!(c.records(&a, "agent_pair_paused").await.is_empty());
    assert!(c.records(&b, "agent_pair_paused").await.is_empty());
}

/// The Debug Settings toggle off (`ACPMUX_AGENT_PAIR_GUARD=0`): nothing is paused.
#[tokio::test]
async fn the_guard_turned_off_pauses_nothing() {
    let hub = hub();
    hub.set_agent_pair_guard(acpmux::hub::PairGuard { enabled: false, ..Default::default() });
    let mut c = Client::open(&hub);
    let (a, b) = (c.new_session().await, c.new_session().await);
    for i in 0..8 {
        let (from, to) = if i % 2 == 0 { (&a, &b) } else { (&b, &a) };
        let reply = c.message(from, to, &format!("o{i}"), "same words again").await;
        assert!(reply.get("error").is_none(), "exchange {i} was delivered: {reply}");
    }
    assert!(c.records(&a, "agent_pair_paused").await.is_empty());
}

/// Resuming is the person's on this machine: a remote web client or a peer is refused.
#[tokio::test]
async fn a_remote_client_cannot_resume_a_pair() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let a = c.new_session().await;
    for origin in [Origin::Web, Origin::Peer] {
        let mut remote = Client::open_as(&hub, origin);
        let reply = remote.reply(RESUME, json!({"sessionId": a})).await;
        assert!(reply.get("error").is_some(), "{origin:?}: {reply}");
    }
}

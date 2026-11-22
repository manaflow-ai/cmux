//! `_meta.acpmux.supersede` on `session/prompt` (`acpmux send --supersede KEY`): a prompt that
//! still waits in the queue, from the same sender under the same key, is replaced by the new one.
//! The replaced prompt never runs, not even after a restart; its `session/prompt` answers
//! withdrawn, its `queue_removed` record says `superseded`, and the new prompt's acceptance counts
//! it (`replaced`). A prompt whose turn already started is never replaced, and another sender's or
//! another key's prompt stays queued.

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

fn config() -> Config {
    config_env(json!({}))
}

fn config_env(env: Value) -> Config {
    serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE], "family": "codex", "env": env}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .unwrap()
}

fn hub() -> Arc<Hub> {
    hub_env(json!({}))
}

fn hub_env(env: Value) -> Arc<Hub> {
    let mut cfg = config_env(env);
    cfg.store.mode = StoreMode::Memory;
    // The queue path before the inbox (`hub/inbox.rs`), which these tests cover.
    cfg.agent_inbox = Some(false);
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

/// A hub whose log lives in `dir`, so a second one there is the same daemon restarted.
fn durable_hub(dir: &Path) -> Arc<Hub> {
    let mut cfg = config();
    cfg.store.mode = StoreMode::Local;
    // The queue path before the inbox (`hub/inbox.rs`), which these tests cover.
    cfg.agent_inbox = Some(false);
    let store = acpmux::store::open(&cfg.store, dir).unwrap();
    Hub::new(cfg, store)
}

/// What `acpmux send --from FROM --supersede KEY` sends.
fn prompt(session: &str, prompt_id: &str, text: &str, from: &str, key: Option<&str>) -> Value {
    let mut mux = json!({"promptId": prompt_id, "fromAgent": from});
    if let Some(key) = key {
        mux["supersede"] = json!(key);
    }
    json!({"sessionId": session, "prompt": [{"type": "text", "text": text}], "_meta": {"acpmux": mux}})
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    fn open(hub: &Arc<Hub>) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
        Self(in_tx, out_rx, 0)
    }

    async fn send(&mut self, method: &str, params: Value) -> i64 {
        self.2 += 1;
        self.0.send(Message::request(self.2, method, params).to_line()).await.unwrap();
        self.2
    }

    async fn until(&mut self, pred: impl Fn(&Value) -> bool) -> Value {
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .expect("timed out")
                .expect("connection closed");
            let value: Value = serde_json::from_str(&line).unwrap();
            if pred(&value) {
                return value;
            }
        }
    }

    async fn reply_to(&mut self, id: i64) -> Value {
        self.until(|v| v.get("id") == Some(&json!(id))).await
    }

    async fn call(&mut self, method: &str, params: Value) -> Value {
        let id = self.send(method, params).await;
        let value = self.reply_to(id).await;
        assert!(value.get("error").is_none(), "{method}: {value}");
        value["result"].clone()
    }

    async fn new_session(&mut self) -> String {
        let new = json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"harness": "fake"}}});
        let created = self.call("session/new", new).await;
        created["sessionId"].as_str().unwrap().to_owned()
    }

    async fn records(&mut self, session: &str, kind: &str) -> Vec<Value> {
        let page =
            self.call("_acpmux/events", json!({"sessionId": session, "kinds": [kind]})).await;
        page["events"].as_array().unwrap().iter().map(|e| e["msg"].clone()).collect()
    }

    /// Whether the prompt went to the agent: its own turn, or one it joined (agent messages
    /// waiting together go in as one turn, `digest.rs`).
    async fn ran(&mut self, session: &str, prompt_id: &str) -> bool {
        let own = self.records(session, "user_message").await;
        let joined = self.records(session, "dequeued").await;
        own.iter().any(|m| m["promptId"] == prompt_id)
            || joined.iter().any(|m| m["promptId"] == prompt_id && m["joinedTurnId"].is_string())
    }

    /// Starts an "until-cancel" turn and waits until it runs.
    async fn busy(&mut self, session: &str, key: Option<&str>) -> i64 {
        let params = prompt(session, "p-run", "until-cancel", "lane-a", key);
        let id = self.send("session/prompt", params).await;
        self.until(|v| v.pointer("/params/update/content/text") == Some(&json!("running"))).await;
        id
    }

    /// Sends a prompt and returns its request id and its acceptance.
    async fn accepted(&mut self, params: Value) -> (i64, Value) {
        let prompt_id = params["_meta"]["acpmux"]["promptId"].clone();
        let id = self.send("session/prompt", params).await;
        let accepted = self
            .until(|v| {
                v["method"] == "_acpmux/prompt_accepted" && v["params"]["promptId"] == prompt_id
            })
            .await;
        (id, accepted["params"].clone())
    }

    async fn cancel(&mut self, session: &str) {
        let note = Message::notification("session/cancel", json!({"sessionId": session}));
        self.0.send(note.to_line()).await.unwrap();
    }

    /// Ends the running turn and runs whatever waits, then one more prompt after them all.
    async fn drain(&mut self, session: &str, running: i64) {
        self.cancel(session).await;
        self.reply_to(running).await;
        self.call("session/prompt", prompt(session, "p-after", "after", "person", None)).await;
    }
}

#[tokio::test]
async fn a_queued_prompt_under_the_same_key_is_replaced_and_never_runs() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let session = c.new_session().await;
    let running = c.busy(&session, None).await;
    let (old, first) =
        c.accepted(prompt(&session, "p-old", "order", "lane-a", Some("cause-1b"))).await;
    assert_eq!(first["queued"], true, "{first}");
    assert_eq!(first["replaced"], 0, "{first}");

    let (_, second) =
        c.accepted(prompt(&session, "p-new", "correction", "lane-a", Some("cause-1b"))).await;
    assert_eq!(second["queued"], true, "{second}");
    assert_eq!(second["replaced"], 1, "{second}");
    assert_eq!(second["replacedPromptIds"], json!(["p-old"]), "{second}");
    // The replaced prompt's `session/prompt` answers at once: no turn ran.
    let answered = c.reply_to(old).await;
    assert_eq!(
        answered.pointer("/result/_meta/acpmux/withdrawn"),
        Some(&json!(true)),
        "{answered}"
    );
    let removed = c.records(&session, "queue_removed").await;
    let removed = removed.iter().find(|m| m["promptId"] == "p-old").expect("its queue_removed");
    assert_eq!(removed["reason"], "superseded", "{removed}");
    assert_eq!(removed["supersededBy"], "p-new", "{removed}");

    c.drain(&session, running).await;
    assert!(!c.ran(&session, "p-old").await, "a replaced prompt ran");
    assert!(c.ran(&session, "p-new").await, "the replacement never ran");
}

#[tokio::test]
async fn another_senders_or_another_keys_prompt_stays_queued() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let session = c.new_session().await;
    let running = c.busy(&session, None).await;
    c.accepted(prompt(&session, "p-a", "a's order", "lane-a", Some("k"))).await;
    c.accepted(prompt(&session, "p-b", "b's order", "lane-b", Some("k"))).await;
    c.accepted(prompt(&session, "p-a2", "a's other order", "lane-a", Some("other"))).await;
    c.accepted(prompt(&session, "p-a3", "a's unkeyed note", "lane-a", None)).await;

    let (_, accepted) =
        c.accepted(prompt(&session, "p-fix", "a's correction", "lane-a", Some("k"))).await;
    assert_eq!(accepted["replaced"], 1, "{accepted}");
    assert_eq!(accepted["replacedPromptIds"], json!(["p-a"]), "{accepted}");

    c.drain(&session, running).await;
    assert!(!c.ran(&session, "p-a").await, "the replaced prompt ran");
    for kept in ["p-b", "p-a2", "p-a3", "p-fix"] {
        assert!(c.ran(&session, kept).await, "{kept} never ran");
    }
}

#[tokio::test]
async fn a_prompt_whose_turn_started_is_never_replaced() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let session = c.new_session().await;
    let running = c.busy(&session, Some("k")).await;

    let (_, accepted) =
        c.accepted(prompt(&session, "p-fix", "correction", "lane-a", Some("k"))).await;
    assert_eq!(accepted["queued"], true, "{accepted}");
    assert_eq!(accepted["replaced"], 0, "{accepted}");
    assert!(c.records(&session, "queue_removed").await.is_empty());
    assert!(hub.resolve(&session).unwrap().turn().is_some(), "the running turn stopped");

    c.drain(&session, running).await;
    assert!(c.ran(&session, "p-fix").await, "the correction never ran");
}

#[tokio::test]
async fn a_prompt_queued_before_a_restart_is_still_replaced() {
    let dir = std::env::temp_dir().join(format!("acpmux-supersede-{}", uuid::Uuid::now_v7()));
    let hub = durable_hub(&dir);
    let mut c = Client::open(&hub);
    let session = c.new_session().await;
    c.busy(&session, None).await;
    c.accepted(prompt(&session, "p-old", "order", "lane-a", Some("k"))).await;
    hub.shutdown_all().await;
    drop(c);
    drop(hub);

    // Restored but not yet resumed: it still waits.
    let hub = durable_hub(&dir);
    let mut c = Client::open(&hub);
    let (new, accepted) =
        c.accepted(prompt(&session, "p-new", "correction", "lane-a", Some("k"))).await;
    assert_eq!(accepted["replaced"], 1, "{accepted}");
    // The turn the restart cut goes on first (`restart_resume.rs`), then the replacement.
    hub.resume_queues();
    c.reply_to(new).await;
    c.call("session/prompt", prompt(&session, "p-after", "after", "person", None)).await;
    assert!(!c.ran(&session, "p-old").await, "a restart ran a replaced prompt");
    assert!(c.ran(&session, "p-new").await, "the replacement never ran");
    assert!(c.ran(&session, "p-run~resume-1").await, "the cut turn did not go on");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&dir);
}

/// A restart hands the running turn to the next daemon: its own end, when its agent stops with
/// the shutdown, writes no result, so the next daemon finds it cut and continues it
/// (`restart_resume.rs`) however late it reads the log. Under load that end came before the next
/// daemon read the log, and the cut turn did not go on (the test above, about 1 in 30).
#[tokio::test]
async fn a_turn_a_restart_handed_on_records_no_end_of_its_own() {
    let dir = std::env::temp_dir().join(format!("acpmux-handed-on-{}", uuid::Uuid::now_v7()));
    let hub = durable_hub(&dir);
    let mut c = Client::open(&hub);
    let session = c.new_session().await;
    let running = c.busy(&session, None).await;
    hub.shutdown_all().await;
    // Its prompt answers once its turn's end ran: the order the race let happen, forced.
    c.reply_to(running).await;
    let ends = c.records(&session, "turn_result").await;
    assert!(ends.is_empty(), "the turn the restart handed on wrote an end: {ends:?}");
    drop(c);
    drop(hub);

    let hub = durable_hub(&dir);
    let mut c = Client::open(&hub);
    let queued = c.records(&session, "queued").await;
    assert!(
        queued.iter().any(|m| m["promptId"] == "p-run~resume-1"),
        "the cut turn's continuation was not queued: {queued:?}"
    );
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&dir);
}

/// An agent's report queued before a restart is still that agent's when it runs: its sender's
/// card, not the person's bubble (review of #24939).
#[tokio::test]
async fn a_report_queued_before_a_restart_keeps_its_sender() {
    let dir = std::env::temp_dir().join(format!("acpmux-supersede-{}", uuid::Uuid::now_v7()));
    let hub = durable_hub(&dir);
    let mut c = Client::open(&hub);
    let session = c.new_session().await;
    c.busy(&session, None).await;
    c.accepted(prompt(&session, "p-report", "report", "lane-a", None)).await;
    hub.shutdown_all().await;
    drop(c);
    drop(hub);

    let hub = durable_hub(&dir);
    let mut c = Client::open(&hub);
    hub.resume_queues();
    // It goes in once the restarted daemon is ready (`wait_startup`): wait for its turn.
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
    while !c.ran(&session, "p-report").await {
        assert!(std::time::Instant::now() < deadline, "the report never ran");
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    let ran = c.records(&session, "user_message").await;
    let report = ran.iter().find(|m| m["promptId"] == "p-report").expect("its user_message");
    assert_eq!(report.pointer("/_meta/provenance/fromName"), Some(&json!("lane-a")), "{report}");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn a_key_that_is_not_a_short_string_is_refused() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let session = c.new_session().await;
    for key in [json!(""), json!(7), json!("x".repeat(257))] {
        let mut params = prompt(&session, "p-bad", "text", "lane-a", None);
        params["_meta"]["acpmux"]["supersede"] = key.clone();
        let id = c.send("session/prompt", params).await;
        let value = c.reply_to(id).await;
        assert_eq!(
            value.pointer("/error/data/reason"),
            Some(&json!("supersede.invalid")),
            "{key}: {value}"
        );
    }
}

#[tokio::test]
async fn a_correction_refused_while_the_chat_moves_replaces_nothing() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let session = c.new_session().await;
    c.busy(&session, None).await;
    c.accepted(prompt(&session, "p-old", "order", "lane-a", Some("k"))).await;
    // The move stops the running turn and freezes the queue as it is (`transfer_out.rs`).
    c.call("_acpmux/transfer_begin", json!({"sessionId": session, "interrupt": true})).await;

    let id = c
        .send("session/prompt", prompt(&session, "p-new", "correction", "lane-a", Some("k")))
        .await;
    let refused = c.reply_to(id).await;
    let message = refused.pointer("/error/message").and_then(Value::as_str).unwrap_or_default();
    assert!(message.starts_with("transfer.moving"), "{refused}");
    assert!(
        c.records(&session, "queue_removed").await.is_empty(),
        "a refused correction replaced a prompt"
    );
    let queue = hub.resolve(&session).unwrap().queue();
    assert_eq!(queue.iter().map(|q| q.prompt_id.as_str()).collect::<Vec<_>>(), ["p-old"]);
}

#[tokio::test]
async fn a_steered_correction_replaces_the_queued_order() {
    let hub = hub_env(json!({"FAKE_CLAUDE_STEER": "1"}));
    let mut c = Client::open(&hub);
    let session = c.new_session().await;
    let running = c.busy(&session, None).await;
    let (old, _) = c.accepted(prompt(&session, "p-old", "order", "lane-a", Some("k"))).await;

    let mut steer = prompt(&session, "p-new", "correction", "lane-a", Some("k"));
    steer["_meta"]["acpmux"]["steer"] = json!(true);
    let (_, accepted) = c.accepted(steer).await;
    assert_eq!(accepted["steer"], true, "{accepted}");
    assert_eq!(accepted["replaced"], 1, "{accepted}");
    assert_eq!(accepted["replacedPromptIds"], json!(["p-old"]), "{accepted}");
    let answered = c.reply_to(old).await;
    assert_eq!(
        answered.pointer("/result/_meta/acpmux/withdrawn"),
        Some(&json!(true)),
        "{answered}"
    );

    c.drain(&session, running).await;
    assert!(!c.ran(&session, "p-old").await, "a replaced prompt ran");
}

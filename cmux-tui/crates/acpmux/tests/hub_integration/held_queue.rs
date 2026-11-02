//! A failed turn holds the prompts that waited behind it (`hub/queue.rs` `pause_queue`); the
//! hold is not for hours. The session's own agent or its coordinator resumes them over the unix
//! socket with no prompt id to name, and a send whose agent cannot start does not hold the rest
//! (2026-10-21: a coordinator's chat held 121 prompts that only the app's Resume button let go).

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use acpmux::store::SessionStatus;
use serde_json::{Value, json};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

fn hub() -> Arc<Hub> {
    hub_env(json!({}))
}

fn hub_env(env: Value) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE], "family": "codex", "env": env}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    // The queue path before the inbox (`hub/inbox.rs`), which these tests cover.
    cfg.agent_inbox = Some(false);
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

fn agent_prompt(session: &str, prompt_id: &str, text: &str) -> Value {
    json!({"sessionId": session, "prompt": [{"type": "text", "text": text}],
           "_meta": {"acpmux": {"promptId": prompt_id, "fromAgent": "lane"}}})
}

fn prompt(session: &str, prompt_id: &str, text: &str) -> Value {
    json!({"sessionId": session, "prompt": [{"type": "text", "text": text}],
           "_meta": {"acpmux": {"promptId": prompt_id}}})
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

    async fn reply_to(&mut self, id: i64) -> Value {
        self.until(|v| v.get("id") == Some(&json!(id))).await
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

    async fn call(&mut self, method: &str, params: Value) -> Value {
        let id = self.send(method, params).await;
        let value = self.until(|v| v.get("id") == Some(&json!(id))).await;
        assert!(value.get("error").is_none(), "{method}: {value}");
        value["result"].clone()
    }

    async fn new_session(&mut self) -> String {
        let new = json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"harness": "fake"}}});
        self.call("session/new", new).await["sessionId"].as_str().unwrap().to_owned()
    }

    async fn records(&mut self, session: &str, kind: &str) -> Vec<Value> {
        let page =
            self.call("_acpmux/events", json!({"sessionId": session, "kinds": [kind]})).await;
        page["events"].as_array().unwrap().iter().map(|e| e["msg"].clone()).collect()
    }

    async fn wait_record(&mut self, session: &str, kind: &str, pred: impl Fn(&Value) -> bool) {
        let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
        while !self.records(session, kind).await.iter().any(&pred) {
            assert!(tokio::time::Instant::now() < deadline, "no {kind} record came");
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    }

    async fn queue(&mut self, params: Value) {
        let prompt_id = params["_meta"]["acpmux"]["promptId"].clone();
        self.send("session/prompt", params).await;
        self.until(|v| {
            v["method"] == "_acpmux/prompt_accepted"
                && v["params"]["promptId"] == prompt_id
                && v["params"]["queued"] == true
        })
        .await;
    }

    /// A session whose failed turn holds `p-held`.
    async fn held(&mut self) -> String {
        let session = self.new_session().await;
        self.send("session/prompt", prompt(&session, "p-slow", "slow")).await;
        self.until(|v| v.pointer("/params/update/content/text") == Some(&json!("tick0 "))).await;
        self.queue(prompt(&session, "p-fail", "fail-streamed: boom")).await;
        self.queue(prompt(&session, "p-held", "held-prompt")).await;
        self.wait_record(&session, "queue_paused", |m| m["held"] == json!(["p-held"])).await;
        session
    }

    async fn ran(&mut self, session: &str, prompt_id: &str) {
        self.wait_record(session, "user_message", |m| m["promptId"] == prompt_id).await;
    }
}

#[tokio::test]
async fn the_unix_socket_resumes_a_held_queue_with_no_prompt_id() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let session = c.held().await;

    let resumed = c.call("_acpmux/queue_edit", json!({"sessionId": session, "op": "resume"})).await;
    assert_eq!(resumed["ok"], true, "{resumed}");
    c.ran(&session, "p-held").await;
}

/// A send whose agent cannot start fails alone: the prompt behind it is not held, it gets its own
/// try (2026-10-21: one failed send held a coordinator's chat for hours).
#[tokio::test]
async fn a_send_whose_agent_cannot_start_fails_alone() {
    let dir = std::env::temp_dir().join(format!("hq-auth-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let auth = dir.join("signed-in");
    std::fs::write(&auth, "").unwrap();
    let env =
        json!({"FAKE_AUTH_FILE": auth, "FAKE_LOAD_ERROR": "gone", "FAKE_INIT_DELAY_MS": "500"});
    let hub = hub_env(env);
    let mut c = Client::open(&hub);
    let session = c.new_session().await;
    c.call("session/prompt", prompt(&session, "p-exit", "answer-then-exit")).await;
    let s = hub.resolve(&session).unwrap();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    while s.meta().status != SessionStatus::Disconnected {
        assert!(tokio::time::Instant::now() < deadline, "the agent never exited");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    // Signed out: the agent that exited cannot start again.
    std::fs::remove_file(&auth).unwrap();

    let first = c.send("session/prompt", prompt(&session, "p-a", "a")).await;
    c.until(|v| v["method"] == "_acpmux/prompt_accepted" && v["params"]["promptId"] == "p-a").await;
    let second = c.send("session/prompt", prompt(&session, "p-b", "b")).await;
    let failed = c.reply_to(first).await;
    assert!(failed.get("error").is_some(), "the agent started: {failed}");
    let answered = tokio::time::timeout(Duration::from_secs(20), c.reply_to(second)).await;
    assert!(answered.is_ok(), "the prompt behind the failed send was held");
    assert!(c.records(&session, "queue_paused").await.is_empty(), "a failed send held the queue");
    let _ = std::fs::remove_dir_all(&dir);
}

/// Agent messages that joined a turn whose agent cannot start are not held either: they go back
/// unheld and each gets its own try, not the `autoResumeDelaysMs` wait (10 s at first).
#[tokio::test]
async fn agent_messages_joined_to_a_send_whose_agent_cannot_start_are_not_held() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let session = c.new_session().await;
    c.call("session/prompt", prompt(&session, "p-exit", "answer-then-exit")).await;
    let s = hub.resolve(&session).unwrap();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    while s.meta().status != SessionStatus::Disconnected {
        assert!(tokio::time::Instant::now() < deadline, "the agent never exited");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    // From now on the agent cannot start at all.
    let mut config = hub.config.write().await;
    let fake = config.harnesses.get_mut("fake").unwrap();
    fake.env.insert("FAKE_DIE_AT_START".to_owned(), "cannot start".to_owned());
    fake.env.insert("FAKE_INIT_DELAY_MS".to_owned(), "500".to_owned());
    drop(config);

    // `a-1` starts the agent and fails; `a-2` and `a-3` wait behind it, so `a-3` joins `a-2`'s
    // turn, whose agent cannot start either.
    let first = c.send("session/prompt", agent_prompt(&session, "a-1", "one")).await;
    c.until(|v| v["method"] == "_acpmux/prompt_accepted" && v["params"]["promptId"] == "a-1").await;
    c.queue(agent_prompt(&session, "a-2", "two")).await;
    let third = c.send("session/prompt", agent_prompt(&session, "a-3", "three")).await;
    c.until(|v| v["method"] == "_acpmux/prompt_accepted" && v["params"]["promptId"] == "a-3").await;
    assert!(c.reply_to(first).await.get("error").is_some(), "the agent started");
    // Its own try fails too, at once: held, it would wait out the 10 s retry.
    let answered = tokio::time::timeout(Duration::from_secs(6), c.reply_to(third)).await;
    let joined = c.records(&session, "dequeued").await;
    assert!(
        joined.iter().any(|m| m["promptId"] == "a-3" && m["joinedPromptId"] == "a-2"),
        "a-3 never joined a-2's turn: {joined:?}"
    );
    assert!(answered.is_ok(), "the agent message that joined the failed send was held");
    assert!(c.records(&session, "queue_paused").await.is_empty(), "a failed start held the queue");
}

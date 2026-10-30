//! `_acpmux/prompt_withdraw` at the daemon boundary (cx-55d27, "unsend"): an agent message
//! (named by its provenance `msgId`, or by its `promptId`) that still waits leaves the queue and
//! never runs, not even after a restart (`unsent`); one whose turn runs gets a retraction notice,
//! steered into the turn when the agent steers and queued next when it does not (`retracted`);
//! one whose turn ended changes nothing (`too_late`). Only the unix socket may withdraw.

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
const WITHDRAW: &str = "_acpmux/prompt_withdraw";

fn config(env: Value) -> Config {
    serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE], "family": "codex", "env": env}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .unwrap()
}

fn hub_env(env: Value) -> Arc<Hub> {
    let mut cfg = config(env);
    cfg.store.mode = StoreMode::Memory;
    // The queue path before the inbox (`hub/inbox.rs`), which these tests cover.
    cfg.agent_inbox = Some(false);
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

fn hub() -> Arc<Hub> {
    hub_env(json!({}))
}

/// A hub whose log lives in `dir`, so a second one there is the same daemon restarted.
fn durable_hub(dir: &Path) -> Arc<Hub> {
    let mut cfg = config(json!({}));
    cfg.store.mode = StoreMode::Local;
    // The queue path before the inbox (`hub/inbox.rs`), which these tests cover.
    cfg.agent_inbox = Some(false);
    let store = acpmux::store::open(&cfg.store, dir).unwrap();
    Hub::new(cfg, store)
}

/// What `cmux agent message` sends with message `msg_id` to session `to`.
fn provenance(to: &str, msg_id: &str) -> Value {
    json!({"kind": "agent_message", "from": "acp:sender-1", "fromName": "builder", "to": format!("acp:{to}"),
           "msgId": msg_id, "threadId": "thread-1"})
}

fn prompt(session: &str, prompt_id: &str, text: &str, provenance: Option<&Value>) -> Value {
    let mut mux = json!({"promptId": prompt_id});
    if let Some(p) = provenance {
        mux["provenance"] = p.clone();
    }
    json!({"sessionId": session, "prompt": [{"type": "text", "text": text}], "_meta": {"acpmux": mux}})
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

    async fn reply(&mut self, method: &str, params: Value) -> Value {
        let id = self.send(method, params).await;
        self.reply_to(id).await
    }

    async fn call(&mut self, method: &str, params: Value) -> Value {
        let value = self.reply(method, params).await;
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

    /// The first `kind` record that matches `pred`, waiting for it (a spawned task writes it).
    async fn wait_record(
        &mut self,
        session: &str,
        kind: &str,
        pred: impl Fn(&Value) -> bool,
    ) -> Value {
        let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
        loop {
            if let Some(m) = self.records(session, kind).await.into_iter().find(|m| pred(m)) {
                return m;
            }
            assert!(tokio::time::Instant::now() < deadline, "no {kind} record came");
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    }

    async fn ran(&mut self, session: &str, prompt_id: &str) -> bool {
        self.records(session, "user_message").await.iter().any(|m| m["promptId"] == prompt_id)
    }

    /// Starts an "until-cancel" turn (with `provenance` when given) and waits until it runs.
    async fn busy(&mut self, session: &str, provenance: Option<&Value>) -> i64 {
        let id =
            self.send("session/prompt", prompt(session, "p-run", "until-cancel", provenance)).await;
        self.until(|v| v.pointer("/params/update/content/text") == Some(&json!("running"))).await;
        id
    }

    async fn queue(&mut self, params: Value) -> i64 {
        let prompt_id = params["_meta"]["acpmux"]["promptId"].clone();
        let id = self.send("session/prompt", params).await;
        self.until(|v| {
            v["method"] == "_acpmux/prompt_accepted"
                && v["params"]["promptId"] == prompt_id
                && v["params"]["queued"] == true
        })
        .await;
        id
    }

    async fn cancel(&mut self, session: &str) {
        let note = Message::notification("session/cancel", json!({"sessionId": session}));
        self.0.send(note.to_line()).await.unwrap();
    }

    async fn withdraw(&mut self, session: &str, msg_id: &str) -> Value {
        self.call(WITHDRAW, json!({"sessionId": session, "msgId": msg_id})).await
    }
}

#[tokio::test]
async fn a_queued_message_is_unsent_and_never_runs() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let session = c.new_session().await;
    let running = c.busy(&session, None).await;
    let waiting = c
        .queue(prompt(&session, "p-q", "queued message", Some(&provenance(&session, "msg-1"))))
        .await;

    let first = c.withdraw(&session, "msg-1").await;
    assert_eq!(first["outcome"], "unsent", "{first}");
    assert_eq!(first["promptId"], "p-q", "{first}");
    // Its waiting `session/prompt` answers at once: no turn ran.
    let answered = c.reply_to(waiting).await;
    assert_eq!(
        answered.pointer("/result/_meta/acpmux/withdrawn"),
        Some(&json!(true)),
        "{answered}"
    );
    let removed = c.records(&session, "queue_removed").await;
    let removed = removed.iter().find(|m| m["promptId"] == "p-q").expect("its queue_removed");
    assert_eq!(removed["reason"], "withdrawn", "{removed}");
    // A second withdraw reports the same: it stays unsent.
    let again = c.withdraw(&session, "msg-1").await;
    assert_eq!(again["outcome"], "unsent", "{again}");

    c.cancel(&session).await;
    c.reply_to(running).await;
    c.call("session/prompt", prompt(&session, "p-after", "after", None)).await;
    assert!(!c.ran(&session, "p-q").await, "a withdrawn prompt ran");
    assert_eq!(c.records(&session, "queue_removed").await.len(), 1, "withdrawn twice");
}

#[tokio::test]
async fn a_held_message_is_unsent_by_its_prompt_id() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let session = c.new_session().await;
    c.send("session/prompt", prompt(&session, "p-slow", "slow", None)).await;
    c.until(|v| v.pointer("/params/update/content/text") == Some(&json!("tick0 "))).await;
    c.queue(prompt(&session, "p-f", "fail-streamed: boom", None)).await;
    c.queue(prompt(&session, "p-q", "held message", Some(&provenance(&session, "msg-h")))).await;
    c.wait_record(&session, "queue_paused", |m| m["held"] == json!(["p-q"])).await;

    let params = json!({"sessionId": session, "promptId": "p-q"});
    let withdrawn = c.call(WITHDRAW, params).await;
    assert_eq!(withdrawn["outcome"], "unsent", "{withdrawn}");
    // Nothing is held any more: resuming runs nothing.
    let resume = json!({"sessionId": session, "promptId": "p-q", "op": "resume"});
    let resumed = c.call("_acpmux/queue_edit", resume).await;
    assert_eq!(resumed["ok"], false, "{resumed}");
    c.call("session/prompt", prompt(&session, "p-after", "after", None)).await;
    assert!(!c.ran(&session, "p-q").await, "a withdrawn held prompt ran");
}

#[tokio::test]
async fn a_running_message_of_an_agent_that_steers_is_retracted_by_a_steer() {
    let hub = hub_env(json!({"FAKE_CODEX_STEER": "1"}));
    let mut c = Client::open(&hub);
    let session = c.new_session().await;
    let p = provenance(&session, "msg-s");
    let turn = c.send("session/prompt", prompt(&session, "p-turn", "work", Some(&p))).await;
    c.until(|v| v.pointer("/params/update/content/text") == Some(&json!("turn: work"))).await;

    let retracted = c.withdraw(&session, "msg-s").await;
    assert_eq!(retracted["outcome"], "retracted", "{retracted}");
    assert_eq!(retracted["promptId"], "p-turn", "{retracted}");
    let record = c.wait_record(&session, "prompt_retracted", |m| m["promptId"] == "p-turn").await;
    assert_eq!(record["msgId"], "msg-s", "{record}");
    assert_eq!(record["via"], "steer", "{record}");
    // The notice joins the running turn, which then ends.
    let notice = c
        .wait_record(&session, "user_message", |m| m["steer"] == true && m["promptId"] != "p-turn")
        .await;
    let text = notice["text"].as_str().unwrap_or_default();
    assert!(text.contains("msg-s") && text.contains("withdrawn"), "{notice}");
    let done = c.reply_to(turn).await;
    assert!(done.get("error").is_none(), "{done}");
    // A second withdraw sends no second notice.
    let again = c.withdraw(&session, "msg-s").await;
    assert_eq!(again["outcome"], "retracted", "{again}");
    assert_eq!(c.records(&session, "prompt_retracted").await.len(), 1);
}

#[tokio::test]
async fn a_running_message_of_an_agent_that_cannot_steer_is_retracted_by_the_next_prompt() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let session = c.new_session().await;
    let running = c.busy(&session, Some(&provenance(&session, "msg-r"))).await;
    let other = c.queue(prompt(&session, "p-other", "the person's next", None)).await;

    let retracted = c.withdraw(&session, "msg-r").await;
    assert_eq!(retracted["outcome"], "retracted", "{retracted}");
    assert_eq!(retracted["promptId"], "p-run", "{retracted}");
    let record = c.wait_record(&session, "prompt_retracted", |m| m["promptId"] == "p-run").await;
    assert_eq!(record["via"], "queued", "{record}");

    c.cancel(&session).await;
    c.reply_to(running).await;
    c.reply_to(other).await;
    // The notice ran first, ahead of the prompt queued before it.
    let ran = c.records(&session, "user_message").await;
    let at = |pred: &dyn Fn(&Value) -> bool| ran.iter().position(pred);
    let notice =
        at(&|m| m["text"].as_str().is_some_and(|t| t.contains("msg-r") && t.contains("withdrawn")));
    let notice = notice.unwrap_or_else(|| panic!("no retraction notice ran: {ran:?}"));
    let other = at(&|m| m["promptId"] == "p-other").expect("the person's prompt ran");
    assert!(notice < other, "{ran:?}");
}

#[tokio::test]
async fn an_ended_message_is_too_late() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let session = c.new_session().await;
    let p = provenance(&session, "msg-e");
    c.call("session/prompt", prompt(&session, "p-done", "done", Some(&p))).await;
    let late = c.withdraw(&session, "msg-e").await;
    assert_eq!(late["outcome"], "too_late", "{late}");
    assert!(c.records(&session, "prompt_retracted").await.is_empty());
    assert!(c.records(&session, "queue_removed").await.is_empty());
    assert_eq!(c.records(&session, "user_message").await.len(), 1, "a notice ran");
}

#[tokio::test]
async fn an_unknown_message_is_not_found() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let session = c.new_session().await;
    c.call("session/prompt", prompt(&session, "p-a", "hi", Some(&provenance(&session, "msg-a"))))
        .await;
    for params in [
        json!({"sessionId": session, "msgId": "msg-unknown"}),
        json!({"sessionId": session, "promptId": "p-unknown"}),
    ] {
        let value = c.reply(WITHDRAW, params.clone()).await;
        assert_eq!(
            value.pointer("/error/data/reason"),
            Some(&json!("withdraw.not_found")),
            "{params}: {value}"
        );
    }
}

#[tokio::test]
async fn a_withdraw_from_any_origin_but_the_unix_socket_is_refused() {
    let hub = hub();
    let mut local = Client::open(&hub);
    let session = local.new_session().await;
    let running = local.busy(&session, None).await;
    let waiting =
        local.queue(prompt(&session, "p-q", "queued", Some(&provenance(&session, "msg-o")))).await;
    for (origin, via) in [
        (Origin::Web, None),
        (Origin::LocalApp, None),
        (Origin::Peer, None),
        (Origin::Peer, Some("web")),
    ] {
        let mut remote = Client::open_as(&hub, origin);
        let mut params = json!({"sessionId": session, "msgId": "msg-o"});
        if let Some(via) = via {
            params["_meta"] = json!({"acpmux": {"via": via}});
        }
        let value = remote.reply(WITHDRAW, params).await;
        assert_eq!(
            value.pointer("/error/data/reason"),
            Some(&json!("withdraw.origin_refused")),
            "{origin:?} via {via:?}: {value}"
        );
    }
    assert!(local.records(&session, "queue_removed").await.is_empty(), "a refused withdraw ran");
    local.cancel(&session).await;
    local.reply_to(running).await;
    local.reply_to(waiting).await;
    assert!(local.ran(&session, "p-q").await, "the queued prompt never ran");
}

#[tokio::test]
async fn an_unsent_message_stays_unsent_after_a_restart() {
    let dir = std::env::temp_dir().join(format!("acpmux-withdraw-{}", uuid::Uuid::now_v7()));
    let hub = durable_hub(&dir);
    let mut c = Client::open(&hub);
    let session = c.new_session().await;
    c.busy(&session, None).await;
    c.queue(prompt(&session, "p-q", "queued message", Some(&provenance(&session, "msg-x")))).await;
    c.queue(prompt(&session, "p-kept", "kept", None)).await;
    assert_eq!(c.withdraw(&session, "msg-x").await["outcome"], "unsent");
    hub.shutdown_all().await;
    drop(c);
    drop(hub);

    let hub = durable_hub(&dir);
    hub.resume_queues();
    let mut c = Client::open(&hub);
    // The prompt still queued runs; the withdrawn one does not come back.
    c.wait_record(&session, "user_message", |m| m["promptId"] == "p-kept").await;
    c.call("session/prompt", prompt(&session, "p-after", "after", None)).await;
    assert!(!c.ran(&session, "p-q").await, "a restart ran a withdrawn prompt");
    assert_eq!(c.withdraw(&session, "msg-x").await["outcome"], "unsent");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn a_message_the_person_edited_is_no_longer_the_senders_to_withdraw() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let session = c.new_session().await;
    let running = c.busy(&session, None).await;
    let waiting = c
        .queue(prompt(&session, "p-e", "from builder", Some(&provenance(&session, "msg-ed"))))
        .await;
    let edit = json!({"sessionId": session, "promptId": "p-e", "op": "update", "text": "the person's rewrite"});
    c.call("_acpmux/queue_edit", edit).await;

    let value = c.reply(WITHDRAW, json!({"sessionId": session, "msgId": "msg-ed"})).await;
    assert_eq!(value.pointer("/error/data/reason"), Some(&json!("withdraw.edited")), "{value}");
    c.cancel(&session).await;
    c.reply_to(running).await;
    c.reply_to(waiting).await;
    assert!(c.ran(&session, "p-e").await, "the person's rewrite never ran");
}

#[tokio::test]
async fn a_persons_own_prompt_is_not_a_message_to_withdraw() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let session = c.new_session().await;
    let running = c.busy(&session, None).await;
    let waiting = c.queue(prompt(&session, "p-own", "the person's words", None)).await;

    let value = c.reply(WITHDRAW, json!({"sessionId": session, "promptId": "p-own"})).await;
    assert_eq!(
        value.pointer("/error/data/reason"),
        Some(&json!("withdraw.not_a_message")),
        "{value}"
    );
    c.cancel(&session).await;
    c.reply_to(running).await;
    c.reply_to(waiting).await;
    assert!(c.ran(&session, "p-own").await, "the person's prompt never ran");
}

#[tokio::test]
async fn a_message_sent_now_into_a_turn_that_ended_is_too_late() {
    let hub = hub_env(json!({"FAKE_CODEX_STEER": "1"}));
    let mut c = Client::open(&hub);
    let session = c.new_session().await;
    c.send("session/prompt", prompt(&session, "p-turn", "work", None)).await;
    c.until(|v| v.pointer("/params/update/content/text") == Some(&json!("turn: work"))).await;
    let p = provenance(&session, "msg-now");
    c.queue(prompt(&session, "p-now", "sent now", Some(&p))).await;
    let send_now = json!({"sessionId": session, "promptId": "p-now", "op": "send_now"});
    let sent = c.call("_acpmux/queue_edit", send_now).await;
    assert_eq!(sent["sent"], "steer", "{sent}");
    // Both prompts are answered in either order: wait on the log, not on the replies.
    let steered = c.wait_record(&session, "user_message", |m| m["promptId"] == "p-now").await;
    assert_eq!(steered["steer"], true, "{steered}");
    c.wait_record(&session, "turn_result", |m| m["promptId"] == "p-turn").await;

    let late = c.withdraw(&session, "msg-now").await;
    assert_eq!(late["outcome"], "too_late", "{late}");
    assert!(c.records(&session, "prompt_retracted").await.is_empty());
}

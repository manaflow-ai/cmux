//! A client's `$/cancel_request` of its own running `session/prompt` (review F1 of #41361): the
//! request is answered cancelled at once, and the turn still settles as a finished one does
//! (`Hub::finish_turn`, the prompt's outcome to its waiters). Before, the cancel dropped the
//! prompt's future: the turn stayed "running" for good, every later prompt queued behind it, and a
//! retry of the cancelled prompt id waited forever.

use super::*;
use crate::config::{Config, StoreMode};
use std::time::Duration;

const WAIT: Duration = Duration::from_secs(15);
const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

/// A hub on the stand-in agent.
fn hub() -> Arc<Hub> {
    let cfg = json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE]}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all",
    });
    let mut cfg: Config = serde_json::from_value(cfg).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

pub(super) struct Client {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    seen: Vec<Value>,
}

impl Client {
    pub(super) fn connect(hub: &Arc<Hub>) -> Self {
        let (tx, incoming) = mpsc::channel(64);
        let (output, rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), incoming, output, Origin::Local));
        Self { tx, rx, seen: Vec::new() }
    }

    pub(super) async fn send(&self, msg: Message) {
        self.tx.send(msg.to_line()).await.unwrap();
    }

    fn answer_to(&self, id: i64) -> Option<&Value> {
        self.seen.iter().find(|v| v["id"] == json!(id) && v.get("method").is_none())
    }

    /// Reads until `id` is answered, within `within`; None when it was not.
    pub(super) async fn answer(&mut self, id: i64, within: Duration) -> Option<Value> {
        let deadline = tokio::time::Instant::now() + within;
        while self.answer_to(id).is_none() {
            let line = tokio::time::timeout_at(deadline, self.rx.recv()).await.ok()??;
            self.seen.push(serde_json::from_str(&line).unwrap());
        }
        self.answer_to(id).cloned()
    }

    pub(super) async fn call(&mut self, id: i64, m: &str, params: Value) -> Value {
        self.send(Message::request(id, m, params)).await;
        let what = format!("no answer to {m} {id}");
        self.answer(id, WAIT).await.expect(&what)
    }
}

/// `cond` within [`WAIT`], checked every 20 ms.
pub(super) async fn until(what: &str, mut cond: impl FnMut() -> bool) {
    let deadline = tokio::time::Instant::now() + WAIT;
    while !cond() {
        assert!(tokio::time::Instant::now() < deadline, "{what}");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

pub(super) fn prompt(session: &str, text: &str, prompt_id: &str) -> Value {
    json!({
        "sessionId": session,
        "prompt": [{"type": "text", "text": text}],
        "_meta": {"acpmux": {"promptId": prompt_id}},
    })
}

/// Review F1 of #41361: cancel a running prompt's request, then the session ends idle, the next
/// prompt runs, and a resend of the cancelled prompt id is answered.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_cancelled_prompt_settles_its_turn_and_the_next_prompt_runs() {
    let hub = hub();
    let mut c = Client::connect(&hub);
    let new =
        c.call(1, "session/new", json!({"cwd": std::env::temp_dir(), "mcpServers": []})).await;
    let sid = new["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{new}")).to_owned();
    let s = hub.resolve(&sid).unwrap();

    // A turn that runs until the agent hears a Stop (`fake_agent.py` "until-cancel").
    c.send(Message::request(10, "session/prompt", prompt(&sid, "until-cancel", "p-cancelled")))
        .await;
    let deadline = tokio::time::Instant::now() + WAIT;
    while hub.agent_pending_requests(&sid).await != Some(1) {
        assert!(tokio::time::Instant::now() < deadline, "the prompt never reached its agent");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert!(s.turn().is_some(), "the prompt's turn runs");

    c.send(Message::notification(method::CANCEL_REQUEST, json!({"requestId": 10}))).await;
    let cancelled = c.answer(10, WAIT).await.expect("the cancel answered the prompt");
    assert_eq!(
        cancelled["error"]["code"],
        json!(crate::request_cancel::REQUEST_CANCELLED),
        "{cancelled}"
    );

    // The turn settles as a finished one does: no turn left running.
    until("the cancelled prompt's turn is still running", || s.turn().is_none()).await;

    // The next prompt runs, rather than queueing behind a turn that never ends.
    let next = c.call(11, "session/prompt", prompt(&sid, "hello", "p-next")).await;
    assert_eq!(next["result"]["stopReason"], json!("end_turn"), "{next}");

    // A resend of the cancelled prompt id is answered with that prompt's outcome.
    let mut again = prompt(&sid, "until-cancel", "p-cancelled");
    again["_meta"]["acpmux"]["resend"] = json!(true);
    c.send(Message::request(12, "session/prompt", again)).await;
    let retried = c.answer(12, WAIT).await.expect("the resend of the cancelled prompt waits");
    assert!(
        retried.get("result").is_some() || retried.get("error").is_some(),
        "the resend got an answer: {retried}"
    );
    assert!(s.turn().is_none(), "the resend ran no turn of its own");
    assert_eq!(s.queued(), 0, "nothing waits in the queue");
}

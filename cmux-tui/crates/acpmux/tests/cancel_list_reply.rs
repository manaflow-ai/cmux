//! A client's `$/cancel_request` racing a session list reply (`server/list_reply.rs`), which is
//! sent from inside its request, as the bytes it was serialized to, before the request ends.
//!
//! The race is held at a stage, never timed (`Hub::hold_requests_for_tests`):
//! - **Queued**: the reply is already in the client's queue when the cancel is read. The client
//!   gets the whole list and nothing else for that id: no -32800 after it.
//! - **Built**: the list is built and not queued yet. The client gets -32800 and no list.
//!
//! Either way exactly one terminal answer, every line the client reads is one whole JSON-RPC
//! message (a cancel never lands inside a frame), and nothing for that id follows a -32800.

// Unix only until the Windows port runs the daemon (cmux::local_socket).
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::{Hub, RequestStage};
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{Semaphore, mpsc};

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const WAIT: Duration = Duration::from_secs(30);
/// JSON-RPC's RequestCancelled (LSP).
const REQUEST_CANCELLED: i64 = -32800;
/// Chats in the list.
const CHATS: usize = 6;
/// The list request's id.
const LIST: i64 = 77;

/// Where the list reply for [`LIST`] stops until the test lets it go on.
struct Gate {
    stage: RequestStage,
    reached: Semaphore,
    release: Semaphore,
}

type Held = std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>>;

fn hub(gate: Arc<Gate>) -> Arc<Hub> {
    let _ = HERMETIC;
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE]}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    hub.hold_requests_for_tests(Arc::new(move |stage, _: &str, id: &Value| -> Held {
        let gate = gate.clone();
        let ours = stage == gate.stage && *id == json!(LIST);
        Box::pin(async move {
            if ours {
                gate.reached.add_permits(1);
                gate.release.acquire().await.unwrap().forget();
            }
        })
    }));
    hub
}

/// Every line the client read, parsed: each one whole JSON-RPC message.
struct Client {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    seen: Vec<Value>,
}

impl Client {
    fn connect(hub: &Arc<Hub>) -> Self {
        let (in_tx, in_rx) = mpsc::channel(256);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
        Self { tx: in_tx, rx: out_rx, seen: Vec::new() }
    }

    async fn send(&self, msg: Message) {
        self.tx.send(msg.to_line()).await.unwrap();
    }

    /// One line within `within`, kept; false when none came.
    async fn read(&mut self, within: Duration) -> bool {
        let Ok(Some(line)) = tokio::time::timeout(within, self.rx.recv()).await else {
            return false;
        };
        let v: Value = serde_json::from_str(&line)
            .unwrap_or_else(|e| panic!("a line that is not one whole message ({e}): {line:.200}"));
        assert_eq!(v["jsonrpc"], "2.0", "{line:.200}");
        self.seen.push(v);
        true
    }

    /// The answers (not notifications) to `id`, in order.
    fn answers_to(&self, id: i64) -> Vec<&Value> {
        self.seen.iter().filter(|v| v["id"] == json!(id) && v.get("method").is_none()).collect()
    }

    async fn call(&mut self, id: i64, m: &str, params: Value) -> Value {
        self.send(Message::request(id, m, params)).await;
        let deadline = tokio::time::Instant::now() + WAIT;
        while self.answers_to(id).is_empty() {
            let left = deadline.saturating_duration_since(tokio::time::Instant::now());
            assert!(self.read(left).await, "no answer to {id}");
        }
        self.answers_to(id)[0].clone()
    }

    /// A round trip: the read loop took every line sent before it.
    async fn round_trip(&mut self, id: i64) {
        let v = self.call(id, "_acpmux/unknown", json!({})).await;
        assert_eq!(v["error"]["code"], json!(-32601), "{v}");
    }

    async fn drain(&mut self, quiet: Duration) {
        while self.read(quiet).await {}
    }
}

/// A hub with [`CHATS`] chats, the list request for them held at `stage`, then cancelled there.
/// The client, after the list request's task went on and every line was read.
async fn cancel_at(stage: RequestStage) -> (Client, Vec<String>) {
    let gate = Arc::new(Gate { stage, reached: Semaphore::new(0), release: Semaphore::new(0) });
    let hub = hub(gate.clone());
    let mut c = Client::connect(&hub);
    let mut chats = Vec::new();
    for i in 0..CHATS {
        let new = c
            .call(
                1 + i as i64,
                "session/new",
                json!({"cwd": std::env::temp_dir(), "mcpServers": []}),
            )
            .await;
        assert!(new.get("error").is_none(), "{new}");
        chats.push(new["result"]["sessionId"].as_str().unwrap().to_owned());
    }
    c.send(Message::request(LIST, "_acpmux/sessions", json!({}))).await;
    tokio::time::timeout(WAIT, gate.reached.acquire())
        .await
        .expect("the list reply never reached its hold")
        .unwrap()
        .forget();
    c.send(Message::notification("$/cancel_request", json!({"requestId": LIST}))).await;
    // The read loop took the cancel; then the request goes on, if it still runs.
    c.round_trip(100).await;
    gate.release.add_permits(1);
    c.round_trip(101).await;
    c.drain(Duration::from_millis(300)).await;
    (c, chats)
}

/// The answers to [`LIST`], and that nothing for it follows a -32800.
fn list_answers(c: &Client) -> Vec<&Value> {
    let answers = c.answers_to(LIST);
    let ids: Vec<&Value> = c.seen.iter().map(|v| &v["id"]).collect();
    if let Some(at) = c
        .seen
        .iter()
        .position(|v| v["id"] == json!(LIST) && v["error"]["code"] == json!(REQUEST_CANCELLED))
    {
        let after: Vec<&Value> =
            c.seen[at + 1..].iter().filter(|v| v["id"] == json!(LIST)).collect();
        assert!(after.is_empty(), "frames for the list after its -32800: {after:#?} (ids {ids:?})");
    }
    answers
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cancel_list_reply_a_cancel_after_the_list_is_queued_leaves_the_list_its_one_answer() {
    let (c, chats) = cancel_at(RequestStage::ListQueued).await;
    let answers = list_answers(&c);
    assert_eq!(answers.len(), 1, "one terminal answer, not two: {answers:#?}");
    let list = answers[0];
    assert!(list.get("error").is_none(), "the list it had begun to send: {list:.300}");
    let listed: Vec<&str> = list["result"]["sessions"]
        .as_array()
        .expect("sessions")
        .iter()
        .filter_map(|row| row["sessionId"].as_str())
        .collect();
    for chat in &chats {
        assert!(listed.contains(&chat.as_str()), "{chat} missing from the whole list {listed:?}");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cancel_list_reply_a_cancel_before_the_list_is_queued_sends_no_list() {
    let (c, _) = cancel_at(RequestStage::ListBuilt).await;
    let answers = list_answers(&c);
    assert_eq!(answers.len(), 1, "one terminal answer: {answers:#?}");
    assert_eq!(answers[0]["error"]["code"], json!(REQUEST_CANCELLED), "{:.300}", answers[0]);
}

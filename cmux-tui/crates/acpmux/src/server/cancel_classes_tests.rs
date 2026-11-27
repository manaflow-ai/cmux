//! A client's `$/cancel_request` on every connection class (review F3 of #41285): a read-only
//! machine, a teammate through the carrier, and a trigger connection each had their notifications
//! taken by their own filter before the cancel arm, so a long request of theirs could not be
//! cancelled. Each class here holds an `initialize` (`Hub::hold_requests_for_tests`), cancels it,
//! and must get -32800 at once and exactly one answer.

use super::*;
use crate::config::{Config, StoreMode};
use crate::hub::RequestStage;
use std::time::Duration;
use tokio::sync::Semaphore;

const WAIT: Duration = Duration::from_secs(10);
/// The held request's id.
const HELD: i64 = 5;

tokio::task_local! {
    /// A connection served inside this scope becomes a trigger connection once it has read a
    /// request, as one does while its first `trigger/chat.*` request runs.
    static TRIGGER: TriggerScope;
}

/// Called by the read loop after it registered a request (`in_flight.rs`).
pub(super) fn after_begin(conn: &Conn) {
    if let Ok(admitted) = TRIGGER.try_with(|scope| conn.admit_trigger(scope.clone())) {
        admitted.expect("the test connection becomes a trigger");
    }
}

fn trigger_scope() -> TriggerScope {
    let s = |v: &str| v.to_owned();
    TriggerScope {
        trigger: s("trigger-1"),
        owner: s("user-1"),
        team: s("team-1"),
        machine: s("machine-1"),
        workspace: s("workspace-1"),
        session: s("session-1"),
        delivery: s("delivery-1"),
        prompt_hash: "a".repeat(64),
        cwd: s("/workspace"),
        harness: s("fake"),
        guest_key: format!("sha256:{}", "a".repeat(64)),
    }
}

struct Gate {
    reached: Semaphore,
    release: Semaphore,
}

/// A hub that holds `initialize` [`HELD`] until the test lets it go on.
fn hub(gate: Arc<Gate>) -> Arc<Hub> {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(config, store);
    hub.hold_requests_for_tests(Arc::new(move |stage, m: &str, id: &Value| {
        let gate = gate.clone();
        let ours = stage == RequestStage::Dispatch && m == method::INITIALIZE && *id == json!(HELD);
        let held: std::pin::Pin<Box<dyn Future<Output = ()> + Send>> = Box::pin(async move {
            if ours {
                gate.reached.add_permits(1);
                gate.release.acquire().await.unwrap().forget();
            }
        });
        held
    }));
    hub
}

struct Client {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    seen: Vec<Value>,
}

impl Client {
    async fn send(&self, msg: Message) {
        self.tx.send(msg.to_line()).await.unwrap();
    }

    fn answers_to(&self, id: i64) -> Vec<&Value> {
        self.seen.iter().filter(|v| v["id"] == json!(id) && v.get("method").is_none()).collect()
    }

    /// Reads until `id` is answered; every line read is kept.
    async fn until_answered(&mut self, id: i64) {
        let deadline = tokio::time::Instant::now() + WAIT;
        while self.answers_to(id).is_empty() {
            let line = tokio::time::timeout_at(deadline, self.rx.recv())
                .await
                .unwrap_or_else(|_| panic!("no answer to {id}; read {:#?}", self.seen))
                .expect("the connection ended");
            self.seen.push(serde_json::from_str(&line).unwrap());
        }
    }

    async fn drain(&mut self) {
        while let Ok(Some(line)) =
            tokio::time::timeout(Duration::from_millis(300), self.rx.recv()).await
        {
            self.seen.push(serde_json::from_str(&line).unwrap());
        }
    }
}

/// Serves one connection with `serve`, holds its `initialize`, cancels it, and checks the one
/// answer: -32800, before a later round trip's answer, and nothing more once the hold is let go.
async fn a_held_request_is_cancelled<F>(what: &str, serve: F)
where
    F: FnOnce(Arc<Hub>, mpsc::Receiver<String>, mpsc::Sender<String>) -> BoxedServe,
{
    let gate = Arc::new(Gate { reached: Semaphore::new(0), release: Semaphore::new(0) });
    let hub = hub(gate.clone());
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(1024);
    tokio::spawn(serve(hub.clone(), in_rx, out_tx));
    let mut c = Client { tx: in_tx, rx: out_rx, seen: Vec::new() };
    let hello = json!({"protocolVersion": 1, "clientInfo": {"name": "t"}});
    c.send(Message::request(HELD, method::INITIALIZE, hello)).await;
    tokio::time::timeout(WAIT, gate.reached.acquire())
        .await
        .unwrap_or_else(|_| panic!("{what}: the request never reached its hold"))
        .unwrap()
        .forget();
    c.send(Message::notification(method::CANCEL_REQUEST, json!({"requestId": HELD}))).await;
    // The read loop takes the cancel before this request: its answer comes first.
    c.send(Message::request(6, "_acpmux/unknown", json!({}))).await;
    c.until_answered(6).await;
    let early = c.answers_to(HELD).into_iter().cloned().collect::<Vec<_>>();
    gate.release.add_permits(1);
    c.send(Message::request(7, "_acpmux/unknown", json!({}))).await;
    c.until_answered(7).await;
    c.drain().await;
    assert_eq!(early.len(), 1, "{what}: the cancel was not answered at once: {:#?}", c.seen);
    assert_eq!(
        early[0]["error"]["code"],
        json!(crate::request_cancel::REQUEST_CANCELLED),
        "{what}: {}",
        early[0]
    );
    assert_eq!(c.answers_to(HELD).len(), 1, "{what}: one answer only: {:#?}", c.seen);
    assert_eq!(hub.requests_in_flight(), 0, "{what}: nothing left in flight");
}

type BoxedServe = std::pin::Pin<Box<dyn Future<Output = ()> + Send>>;

#[tokio::test]
async fn cancel_classes_a_read_only_machine_cancels_its_request() {
    a_held_request_is_cancelled("read-only machine", |hub, rx, tx| {
        Box::pin(serve_connection_authed(hub, rx, tx, Origin::Web, ConnAuth::ReadOnlyDevice))
    })
    .await;
}

#[tokio::test]
async fn cancel_classes_a_carrier_teammate_cancels_its_request() {
    let teammate = carrier::Attested {
        role: carrier::Role::Team,
        sub: "u_mate".into(),
        team: Some("t_1".into()),
        chats: vec!["chat-a".into()],
        name: None,
    };
    a_held_request_is_cancelled("carrier teammate", move |hub, rx, tx| {
        Box::pin(carrier::serve_attested(hub, rx, tx, teammate))
    })
    .await;
}

#[tokio::test]
async fn cancel_classes_a_trigger_connection_cancels_its_request() {
    a_held_request_is_cancelled("trigger connection", |hub, rx, tx| {
        Box::pin(TRIGGER.scope(
            trigger_scope(),
            serve_connection_authed(hub, rx, tx, Origin::Web, ConnAuth::ListenerToken),
        ))
    })
    .await;
}

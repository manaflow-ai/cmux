//! A message to another machine's session acks within a second (`hub/outbox.rs`).
//!
//! On 2026-10-21 `acpmux send --no-wait huge-blue/<lane>` from cosmic-gray took 60-120 s and hit
//! `timeout 60` (rc 124) while still delivering. The send waited for `_acpmux/prompt_accepted`,
//! but a peer's acceptance was dropped on the way back (`hub/peers.rs`), and the forwarded
//! `session/prompt` answers only when the target's turn (or a steer's step) ends.
//!
//! Two hubs: B owns the sessions and serves WebSocket; A mirrors B as peer `b`.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, HarnessProfile, PermissionPolicy, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::peer_auth::PeerAuth;
use acpmux::server::{WsAuth, bind_ws, serve_connection, serve_ws_with};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

/// The ack a sender may wait for.
const ACK: Duration = Duration::from_secs(1);
const SEND_QUEUE: &str = "_acpmux/send_queue";
const SEND_STATUS: &str = "_acpmux/send_status";

fn config() -> Config {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut agents = BTreeMap::new();
    agents.insert(
        "fake".to_owned(),
        HarnessProfile {
            kind: Default::default(),
            argv: vec!["python3".into(), fake.into()],
            env: BTreeMap::new(),
            description: None,
            fallback: None,
            family: None,
            models: vec![],
            model: None,
            effort: None,
            policy: None,
        },
    );
    let mut cfg =
        Config { harnesses: agents, default_harness: Some("fake".into()), ..Default::default() };
    cfg.store.mode = StoreMode::Memory;
    cfg.permission_policy = PermissionPolicy::ApproveAll;
    cfg
}

fn hub() -> Arc<Hub> {
    let cfg = config();
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct C {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    next: i64,
}

impl C {
    async fn new(h: Arc<Hub>) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection(h, in_rx, out_tx));
        let mut c = C { tx: in_tx, rx: out_rx, next: 0 };
        c.call(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "t"}}))
            .await
            .unwrap();
        c
    }

    async fn send(&mut self, m: &str, p: Value) -> i64 {
        self.next += 1;
        self.tx.send(Message::request(self.next, m, p).to_line()).await.unwrap();
        self.next
    }

    async fn call(&mut self, m: &str, p: Value) -> Result<Value, String> {
        let id = self.send(m, p).await;
        loop {
            let line = tokio::time::timeout(Duration::from_secs(20), self.rx.recv())
                .await
                .expect("timeout")
                .expect("closed");
            if let Ok(Message::Response { id: rid, result, error }) = Message::parse(&line)
                && rid == id
            {
                return match error {
                    Some(e) => Err(e.message),
                    None => Ok(result.unwrap_or(Value::Null)),
                };
            }
        }
    }

    /// The notification `m` that `pred` takes, within `within`.
    async fn notified(
        &mut self,
        m: &str,
        within: Duration,
        pred: impl Fn(&Value) -> bool,
    ) -> Option<Value> {
        let deadline = tokio::time::Instant::now() + within;
        loop {
            let line = tokio::time::timeout_at(deadline, self.rx.recv()).await.ok()??;
            if let Ok(Message::Notification { method: got, params }) = Message::parse(&line) {
                let p = params.unwrap_or(Value::Null);
                if got == m && pred(&p) {
                    return Some(p);
                }
            }
        }
    }
}

/// B, with a session `name` whose turn runs until cancelled (a lane at work), and A peered to it.
async fn busy_peer(tag: &str, name: &str) -> (Arc<Hub>, Arc<Hub>, String) {
    let b = hub();
    let home = std::env::temp_dir().join(format!("send-async-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    let auth = PeerAuth::create(&home).unwrap();
    let peer_token = std::fs::read_to_string(acpmux::server::peer_auth::token_path(&home)).unwrap();
    let l = bind_ws("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    tokio::spawn(serve_ws_with(
        b.clone(),
        l,
        "tok".into(),
        WsAuth { local_app: None, peer: Some(Arc::new(auth)) },
    ));
    let mut cb = C::new(b.clone()).await;
    let s = cb
        .call(
            method::SESSION_NEW,
            json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": name}}}),
        )
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    cb.send(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "until-cancel"}]}),
    )
    .await;
    cb.notified(method::MUX_EVENT, Duration::from_secs(20), |p| p["kind"] == "turn_started")
        .await
        .expect("B's turn started");
    // Keep B's client: dropping it would not end the turn, but it holds the session attached.
    tokio::spawn(async move {
        let _keep = cb;
        tokio::time::sleep(Duration::from_secs(60)).await;
    });
    let a = hub();
    a.add_peer("b", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), Some(peer_token), true)
        .await
        .unwrap();
    (a, b, id)
}

fn prompt(session: &str, text: &str, prompt_id: &str) -> Value {
    json!({
        "sessionId": session,
        "prompt": [{"type": "text", "text": text}],
        "_meta": {"acpmux": {"promptId": prompt_id}},
    })
}

/// A prompt for a busy peer's session: the sender hears it was taken within a second, not
/// when the target's turn ends.
#[tokio::test]
async fn a_busy_peer_session_acks_a_forwarded_prompt_within_a_second() {
    let (a, _b, _id) = busy_peer("relay", "lane").await;
    let mut ca = C::new(a).await;
    let started = Instant::now();
    ca.send(method::SESSION_PROMPT, prompt("b/lane", "from cosmic-gray", "p-relay")).await;
    let accepted =
        ca.notified(method::MUX_PROMPT_ACCEPTED, ACK, |p| p["promptId"] == "p-relay").await;
    assert!(
        accepted.is_some(),
        "no prompt_accepted within {ACK:?} (waited {:?}): the peer's acceptance never came back",
        started.elapsed()
    );
    assert_eq!(accepted.unwrap()["peer"], "b");
}

/// `send_queue` answers at once with a delivery id; the daemon delivers it, and
/// `send_status` says it was taken by the busy peer session.
#[tokio::test]
async fn send_queue_acks_at_once_and_status_reports_the_delivery() {
    let (a, b, id) = busy_peer("queue", "lane").await;
    let mut ca = C::new(a).await;
    let started = Instant::now();
    let queued = ca
        .call(SEND_QUEUE, json!({"request": prompt("b/lane", "hello", "p-queue")}))
        .await
        .unwrap();
    assert!(started.elapsed() < ACK, "send_queue took {:?}", started.elapsed());
    let delivery = queued["deliveryId"].as_str().expect("a delivery id").to_owned();
    assert_eq!(queued["target"], "b/lane");
    let status =
        ca.call(SEND_STATUS, json!({"deliveryId": delivery, "waitMs": 5000})).await.unwrap();
    assert_eq!(status["status"], "delivered", "{status}");
    assert_eq!(status["accepted"]["promptId"], "p-queue", "{status}");
    // The same prompt id again is the same delivery, and B took it once.
    let again = ca
        .call(SEND_QUEUE, json!({"request": prompt("b/lane", "hello", "p-queue")}))
        .await
        .unwrap();
    assert_eq!(again["deliveryId"], delivery);
    let mut cb = C::new(b).await;
    let info = cb.call(method::MUX_INFO, json!({"sessionId": id})).await.unwrap();
    assert_eq!(info["queued"], 1, "{info}");
}

/// A peer that is down: the message is queued at once and tried again, never refused.
#[tokio::test]
async fn send_queue_to_a_peer_that_is_down_acks_at_once_and_keeps_trying() {
    let a = hub();
    let port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    a.add_peer("gone", &format!("ws://127.0.0.1:{port}"), None, None, true).await.unwrap();
    let mut ca = C::new(a).await;
    let started = Instant::now();
    let queued =
        ca.call(SEND_QUEUE, json!({"request": prompt("gone/lane", "hi", "p-down")})).await.unwrap();
    assert!(started.elapsed() < ACK, "send_queue took {:?}", started.elapsed());
    let delivery = queued["deliveryId"].as_str().unwrap().to_owned();
    let status =
        ca.call(SEND_STATUS, json!({"deliveryId": delivery, "waitMs": 3000})).await.unwrap();
    assert!(matches!(status["status"].as_str(), Some("queued" | "delivering")), "{status}");
    assert!(status["attempts"].as_u64().unwrap_or(0) >= 1, "{status}");
    assert!(status["error"].as_str().is_some_and(|e| e.contains("peer_unreachable")), "{status}");
    // A session nobody has is refused at once.
    let e = ca
        .call(SEND_QUEUE, json!({"request": prompt("nobody", "hi", "p-none")}))
        .await
        .unwrap_err();
    assert!(e.contains("no session"), "{e}");
}

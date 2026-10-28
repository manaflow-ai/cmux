//! The mesh relay against a fake hub (`mesh.rs`, `server/mesh_relay.rs`): a message for a session
//! here is delivered once and acked with its prompt id, even when the hub leases it again; a
//! relayed message runs as a peer's and reads none of this host's peers; control messages go to
//! the hook; and the inbox never calls a failing or impatient hub in a busy loop.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::mesh::{
    Ack, AckState, ControlHook, HubError, InMessage, Kind, MeshHub, Mode, RefuseControl, Sender,
    Target,
};
use acpmux::rpc::Message;
use acpmux::server::mesh_relay::{MeshRelay, RelayOptions, relay_connection};
use acpmux::server::{Origin, serve_connection_with};
use futures::future::BoxFuture;
use serde_json::{Value, json};
use std::collections::VecDeque;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::{Notify, mpsc};

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

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

fn quick() -> RelayOptions {
    RelayOptions {
        inbox_wait: Duration::from_millis(500),
        min_poll_gap: Duration::from_millis(100),
        backoff_first: Duration::from_millis(100),
        backoff_cap: Duration::from_millis(400),
        max_in_flight: 4,
    }
}

fn message(id: &str, to: &str, kind: Kind) -> InMessage {
    InMessage {
        message_id: id.into(),
        kind,
        op: (kind == Kind::Control).then(|| "start".to_owned()),
        mode: Mode::TurnEnd,
        to: Target { name: Some(to.into()), ..Target::default() },
        from: Sender {
            name: Some("lane-a".into()),
            host: Some("gcp-lane".into()),
            daemon_id: Some("inst_a".into()),
            ..Sender::default()
        },
        body: "hello from another machine".into(),
        attempt: 1,
    }
}

/// What the hub holds for one daemon, and what the daemon told it.
#[derive(Default)]
struct State {
    waiting: VecDeque<InMessage>,
    acks: Vec<(String, Ack)>,
    inbox_calls: usize,
}

impl State {
    fn acked(&self, id: &str) -> Vec<Ack> {
        self.acks.iter().filter(|(m, _)| m == id).map(|(_, a)| a.clone()).collect()
    }
}

#[derive(Default)]
struct FakeHub {
    state: Mutex<State>,
    changed: Notify,
    /// Every inbox call fails.
    down: bool,
    /// The inbox answers at once, never long-polling.
    impatient: bool,
}

impl FakeHub {
    fn with<T>(&self, f: impl FnOnce(&mut State) -> T) -> T {
        let out = f(&mut self.state.lock().unwrap());
        self.changed.notify_waiters();
        out
    }

    fn lease(&self, message: InMessage) {
        self.with(|s| s.waiting.push_back(message));
    }

    /// Waits up to 30 s for `done` to hold.
    async fn until(&self, what: &str, done: impl Fn(&State) -> bool) {
        let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
        loop {
            let changed = self.changed.notified();
            if done(&self.state.lock().unwrap()) {
                return;
            }
            if tokio::time::timeout_at(deadline, changed).await.is_err() {
                panic!("timed out waiting for {what}");
            }
        }
    }
}

impl MeshHub for FakeHub {
    fn inbox(&self, wait: Duration, max: usize) -> BoxFuture<'_, Result<Vec<InMessage>, HubError>> {
        Box::pin(async move {
            self.with(|s| s.inbox_calls += 1);
            if self.down {
                return Err(HubError::unavailable("the hub is down"));
            }
            let deadline = tokio::time::Instant::now() + wait;
            loop {
                let changed = self.changed.notified();
                let mut state = self.state.lock().unwrap();
                let leased: Vec<_> = state.waiting.drain(..max.min(state.waiting.len())).collect();
                drop(state);
                if !leased.is_empty() || self.impatient {
                    return Ok(leased);
                }
                if tokio::time::timeout_at(deadline, changed).await.is_err() {
                    return Ok(Vec::new());
                }
            }
        })
    }

    fn ack<'a>(&'a self, id: &'a str, ack: &'a Ack) -> BoxFuture<'a, Result<(), HubError>> {
        Box::pin(async move {
            self.with(|s| s.acks.push((id.to_owned(), ack.clone())));
            Ok(())
        })
    }
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    fn local(hub: &Arc<Hub>) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
        Self(in_tx, out_rx, 0)
    }

    async fn call(&mut self, method: &str, params: Value) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, method, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .unwrap()
                .unwrap();
            let value: Value = serde_json::from_str(&line).unwrap();
            if value.get("id") == Some(&json!(id)) {
                return value;
            }
        }
    }

    async fn new_session(&mut self, name: &str) -> String {
        let meta = json!({"acpmux": {"harness": "fake", "name": name}});
        let params = json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": meta});
        let reply = self.call("session/new", params).await;
        assert!(reply.get("error").is_none(), "{reply}");
        reply["result"]["sessionId"].as_str().unwrap().to_owned()
    }
}

#[tokio::test]
async fn a_message_for_a_session_here_runs_once_and_is_acked_with_its_prompt_id() {
    let hub = hub();
    let mut local = Client::local(&hub);
    let session = local.new_session("dep-land").await;
    let fake = Arc::new(FakeHub::default());
    let relay = MeshRelay::start(&hub, fake.clone(), Arc::new(RefuseControl), quick());

    fake.lease(message("msg-1", "dep-land", Kind::Prompt));
    fake.until("the ack", |s| !s.acked("msg-1").is_empty()).await;
    // Its ack was lost: the hub leases it again, and it is acked again without a second run.
    fake.lease(InMessage { attempt: 2, ..message("msg-1", "dep-land", Kind::Prompt) });
    fake.until("the second ack", |s| s.acked("msg-1").len() == 2).await;
    for ack in fake.with(|s| s.acked("msg-1")) {
        assert_eq!(ack, Ack::delivered("msg-1", Kind::Prompt));
    }
    let mut info = Value::Null;
    for _ in 0..600 {
        info = local.call("_acpmux/info", json!({"sessionId": session})).await;
        if info.pointer("/result/turn").is_none_or(Value::is_null) {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert_eq!(info.pointer("/result/turnCount"), Some(&json!(1)), "ran twice: {info}");
    relay.stop().await;
}

#[tokio::test]
async fn a_relayed_message_reads_no_peer_here_and_is_never_forwarded_to_one() {
    let hub = hub();
    // A peer of this host, down: a local caller learns its name, a relayed request never does.
    hub.add_peer("secret-peer", "ws://127.0.0.1:9", None, None, false).await.unwrap();
    let listed = Client::local(&hub).call("_acpmux/peers", json!({})).await;
    assert!(listed.to_string().contains("secret-peer"), "{listed}");
    let (tx, rx) = relay_connection(&hub);
    let mut relayed = Client(tx, rx, 0);
    relayed.call("initialize", json!({"protocolVersion": 1, "clientCapabilities": {}})).await;
    let listed = relayed.call("_acpmux/peers", json!({})).await;
    assert_eq!(listed.pointer("/result/peers"), Some(&json!([])), "{listed}");

    let fake = Arc::new(FakeHub::default());
    let relay = MeshRelay::start(&hub, fake.clone(), Arc::new(RefuseControl), quick());
    fake.lease(message("msg-2", "secret-peer/lane", Kind::Prompt));
    fake.until("the refusal", |s| !s.acked("msg-2").is_empty()).await;
    let ack = fake.with(|s| s.acked("msg-2").remove(0));
    assert_eq!(ack.state, AckState::Refused);
    assert!(ack.detail.as_deref().is_some_and(|d| d.contains("no session")), "{ack:?}");
    assert!(!format!("{ack:?}").contains("127.0.0.1"), "a peer's address leaked: {ack:?}");
    relay.stop().await;
}

struct Starts(Mutex<Vec<String>>);

impl ControlHook for Starts {
    fn control<'a>(&'a self, _: &'a Arc<Hub>, m: &'a InMessage) -> BoxFuture<'a, Option<Ack>> {
        Box::pin(async move {
            self.0.lock().unwrap().push(m.message_id.clone());
            Some(Ack::delivered(&m.message_id, Some("started".into())))
        })
    }
}

#[tokio::test]
async fn control_messages_go_to_the_hook_and_without_one_are_refused() {
    let hub = hub();
    let fake = Arc::new(FakeHub::default());
    let relay = MeshRelay::start(&hub, fake.clone(), Arc::new(RefuseControl), quick());
    fake.lease(message("c-1", "", Kind::Control));
    fake.until("the refusal", |s| !s.acked("c-1").is_empty()).await;
    assert_eq!(fake.with(|s| s.acked("c-1")[0].state), AckState::Refused);
    relay.stop().await;

    let hook = Arc::new(Starts(Mutex::new(Vec::new())));
    let relay = MeshRelay::start(&hub, fake.clone(), hook.clone(), quick());
    fake.lease(message("c-2", "", Kind::Control));
    fake.until("the ack", |s| !s.acked("c-2").is_empty()).await;
    assert_eq!(fake.with(|s| s.acked("c-2")[0].state), AckState::Delivered);
    assert_eq!(*hook.0.lock().unwrap(), vec!["c-2".to_owned()]);
    relay.stop().await;
}

#[tokio::test]
async fn a_failing_or_impatient_hub_is_never_called_in_a_busy_loop() {
    let down = FakeHub { down: true, ..FakeHub::default() };
    let impatient = FakeHub { impatient: true, ..FakeHub::default() };
    for fake in [down, impatient] {
        let hub = hub();
        let fake = Arc::new(fake);
        let relay = MeshRelay::start(&hub, fake.clone(), Arc::new(RefuseControl), quick());
        tokio::time::sleep(Duration::from_secs(1)).await;
        relay.stop().await;
        let calls = fake.with(|s| s.inbox_calls);
        // 100 ms apart at the least, backing off to 400 ms when it fails: about 10 at most.
        assert!((1..=15).contains(&calls), "{calls} inbox calls in a second");
    }
}

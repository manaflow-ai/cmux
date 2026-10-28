//! The mesh relay against a fake hub (`mesh.rs`, `server/mesh_relay.rs`, `server/mesh_send.rs`):
//! a send to a name no peer has goes through the hub and its receipt reaches delivered with the
//! prompt id; a message for a session here is delivered once, even when the hub leases it again;
//! a relayed message runs as a peer's and reads none of this host's peers; control messages go to
//! the hook; a message for another host or daemon never runs here; the heartbeat lists the
//! sessions here; with no hub nothing changes; no loop calls a failing or impatient hub in a busy
//! loop, and the relay ends when the daemon stops or the mesh hub refuses it.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::mesh::{
    Ack, AckState, ControlHook, Heartbeat, HeartbeatReply, HubError, InMessage, Kind, MeshHub,
    Mode, OutMessage, Receipt, RefuseControl, Sender, Target,
};
use acpmux::rpc::Message;
use acpmux::server::mesh_relay::{MeshRelay, RelayOptions, relay_connection};
use acpmux::server::{Origin, serve_connection_with};
use futures::future::BoxFuture;
use serde_json::{Value, json};
use std::collections::{HashMap, VecDeque};
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
        heartbeat_every: Duration::from_millis(200),
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
    heartbeats: Vec<Heartbeat>,
    /// Idempotency key to message id.
    keys: HashMap<String, String>,
    receipts: HashMap<String, Receipt>,
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
    /// Every call is refused for good (a bad credential).
    refusing: bool,
    /// Only inbox calls are refused for good; heartbeats are taken.
    refusing_inbox: bool,
    /// The inbox long-polls for a minute, far past the test's wait.
    long: bool,
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
            if self.refusing || self.refusing_inbox {
                return Err(HubError::refused("401 mesh.unauthorized"));
            }
            let wait = if self.long { Duration::from_secs(60) } else { wait };
            let deadline = tokio::time::Instant::now() + wait;
            loop {
                let changed = self.changed.notified();
                let leased: Vec<_> = {
                    let mut state = self.state.lock().unwrap();
                    let n = max.min(state.waiting.len());
                    state.waiting.drain(..n).collect()
                };
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
            self.with(|s| {
                s.acks.push((id.to_owned(), ack.clone()));
                if let Some(r) = s.receipts.get_mut(id) {
                    r.state = serde_json::to_value(ack.state).unwrap().as_str().unwrap().into();
                    (r.prompt_id, r.detail) = (ack.prompt_id.clone(), ack.detail.clone());
                    r.acked_at = Some(2000);
                }
            });
            Ok(())
        })
    }

    fn heartbeat<'a>(
        &'a self,
        beat: &'a Heartbeat,
    ) -> BoxFuture<'a, Result<HeartbeatReply, HubError>> {
        Box::pin(async move {
            self.with(|s| s.heartbeats.push(beat.clone()));
            if self.refusing {
                return Err(HubError::refused("401 mesh.unauthorized"));
            }
            Ok(HeartbeatReply { daemon_id: "inst_b".into(), ttl_seconds: 90 })
        })
    }

    /// Routes to the one daemon whose last heartbeat lists the name.
    fn send<'a>(&'a self, m: &'a OutMessage) -> BoxFuture<'a, Result<Receipt, HubError>> {
        Box::pin(async move {
            self.with(|s| {
                if let Some(id) = s.keys.get(&m.idempotency_key) {
                    return Ok(s.receipts[id].clone());
                }
                let listed = s.heartbeats.last().is_some_and(|b| {
                    b.sessions.iter().any(|r| Some(&r.name) == m.to.name.as_ref())
                });
                if !listed {
                    let mut e = HubError::refused("no such recipient");
                    e.code = Some("mesh.unknown_recipient".into());
                    return Err(e);
                }
                let id = format!("msg_{:032x}", s.keys.len() + 1);
                s.keys.insert(m.idempotency_key.clone(), id.clone());
                let receipt = Receipt {
                    message_id: id.clone(),
                    state: "queued".into(),
                    to: m.to.clone(),
                    attempt: 0,
                    prompt_id: None,
                    detail: None,
                    created_at: 1000,
                    leased_until: None,
                    acked_at: None,
                };
                s.receipts.insert(id.clone(), receipt.clone());
                s.waiting.push_back(InMessage {
                    message_id: id,
                    kind: m.kind,
                    op: None,
                    mode: m.mode,
                    // The hub resolved the host: the inbox names only the session.
                    to: Target {
                        session_id: m.to.session_id.clone(),
                        name: m.to.name.clone(),
                        ..Target::default()
                    },
                    from: m.from.clone(),
                    body: m.body.clone(),
                    attempt: 1,
                });
                Ok(receipt)
            })
        })
    }

    fn receipt<'a>(&'a self, id: &'a str) -> BoxFuture<'a, Result<Receipt, HubError>> {
        Box::pin(async move {
            if self.down {
                return Err(HubError::unavailable("the hub is down"));
            }
            let receipts = &self.state.lock().unwrap().receipts;
            receipts.get(id).cloned().ok_or_else(|| HubError::refused("no such message"))
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
        assert_eq!(ack, Ack::delivered("msg-1", None));
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

#[tokio::test]
async fn a_message_for_another_host_or_a_daemon_is_never_given_to_a_session_here_of_its_name() {
    let hub = hub();
    let mut local = Client::local(&hub);
    let session = local.new_session("dep-land").await;
    let fake = Arc::new(FakeHub::default());
    let relay = MeshRelay::start(&hub, fake.clone(), Arc::new(RefuseControl), quick());
    let to = |target: Target| InMessage { to: target, ..message("", "", Kind::Prompt) };
    let named = |host: Option<&str>, daemon: Option<&str>| Target {
        name: Some("dep-land".into()),
        host: host.map(str::to_owned),
        daemon_id: daemon.map(str::to_owned),
        ..Target::default()
    };
    let refused = [
        ("other-host", named(Some("other-host"), None)),
        ("other-daemon", named(None, Some("inst_other"))),
        ("other-prefix", Target { name: Some("other-host/dep-land".into()), ..Target::default() }),
    ];
    for (id, target) in refused {
        fake.lease(InMessage { message_id: id.into(), ..to(target) });
        fake.until(id, |s| !s.acked(id).is_empty()).await;
        assert_eq!(fake.with(|s| s.acked(id)[0].state), AckState::Refused, "{id}");
    }
    // A daemon id is this daemon's only when it is the id the hub gave it.
    let mine = Target { daemon_id: Some("inst_me".into()), ..Target::default() };
    assert!(hub.mesh_for_here(&mine, Some("inst_me")).is_ok());
    assert!(hub.mesh_for_here(&mine, Some("inst_other")).is_err());
    assert!(hub.mesh_for_here(&mine, None).is_err());
    let own = acpmux::pairing::machine_name();
    let mut ran = 0;
    if own != "host" {
        // Its own host, as a field and as a prefix, is this one: those run.
        let mine = [
            ("own-host", named(Some(&own.to_uppercase()), None)),
            ("own-prefix", Target { name: Some(format!("{own}/dep-land")), ..Target::default() }),
        ];
        for (id, target) in mine {
            fake.lease(InMessage { message_id: id.into(), ..to(target) });
            fake.until(id, |s| !s.acked(id).is_empty()).await;
            assert_eq!(fake.with(|s| s.acked(id)[0].clone()), Ack::delivered(id, None), "{id}");
            ran += 1;
        }
    }
    let mut info = Value::Null;
    for _ in 0..600 {
        info = local.call("_acpmux/info", json!({"sessionId": session})).await;
        let idle = info.pointer("/result/turn").is_none_or(Value::is_null);
        if idle && info.pointer("/result/turnCount").and_then(Value::as_u64) >= Some(ran) {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let count = info.pointer("/result/turnCount").and_then(Value::as_u64).unwrap_or(0);
    assert_eq!(count, ran, "a message for elsewhere ran here: {info}");
    relay.stop().await;
}

/// Waits up to 5 s for the relay's loop to end on its own.
async fn ends(relay: &MeshRelay, what: &str) {
    for _ in 0..100 {
        if relay.is_finished() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!("the relay still runs after {what}");
}

#[tokio::test]
async fn the_relay_ends_when_the_daemon_stops_or_the_mesh_hub_refuses_it() {
    // The daemon stops (as `_acpmux/shutdown` does) while the inbox is long-polling an empty
    // inbox: both loops end at once instead of polling on, the heartbeat with an empty one.
    let stopping = hub();
    let fake = Arc::new(FakeHub { long: true, ..FakeHub::default() });
    let relay = MeshRelay::start(&stopping, fake.clone(), Arc::new(RefuseControl), quick());
    fake.until("the first inbox call", |s| s.inbox_calls > 0).await;
    // The stopping flag alone (a signal's path, which notifies nothing) is enough.
    stopping.stop_idle_reaper();
    ends(&relay, "the daemon stops").await;
    let calls = fake.with(|s| (s.inbox_calls, s.heartbeats.len()));
    assert!(fake.with(|s| s.heartbeats.last().is_some_and(|b| b.sessions.is_empty())));
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(fake.with(|s| (s.inbox_calls, s.heartbeats.len())), calls);

    // A refused heartbeat (a bad credential) is not retried, and the inbox, which waits for the
    // hub to name this daemon, never polls: one call in all, then the relay is off.
    let refused = hub();
    let fake = Arc::new(FakeHub { refusing: true, ..FakeHub::default() });
    let relay = MeshRelay::start(&refused, fake.clone(), Arc::new(RefuseControl), quick());
    ends(&relay, "a refused heartbeat").await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(fake.with(|s| (s.inbox_calls, s.heartbeats.len())), (0, 1));
    relay.stop().await;

    // The hub takes heartbeats but refuses the inbox: both loops end, the heartbeat with an
    // empty one, so the address book does not list sessions no message can reach.
    let refused = hub();
    let fake = Arc::new(FakeHub { refusing_inbox: true, ..FakeHub::default() });
    let relay = MeshRelay::start(&refused, fake.clone(), Arc::new(RefuseControl), quick());
    ends(&relay, "a refused inbox").await;
    let beats = fake.with(|s| s.heartbeats.len());
    assert!(fake.with(|s| s.heartbeats.last().is_some_and(|b| b.sessions.is_empty())));
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(fake.with(|s| (s.inbox_calls, s.heartbeats.len())), (1, beats));
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
    // A control for another host or daemon never reaches the hook.
    let elsewhere = [
        ("c-3", Target { host: Some("other-host".into()), ..Target::default() }),
        ("c-4", Target { daemon_id: Some("inst_other".into()), ..Target::default() }),
    ];
    for (id, to) in elsewhere {
        fake.lease(InMessage { message_id: id.into(), to, ..message(id, "", Kind::Control) });
        fake.until(id, |s| !s.acked(id).is_empty()).await;
        assert_eq!(fake.with(|s| s.acked(id)[0].state), AckState::Refused, "{id}");
    }
    // Once a heartbeat reply has named this daemon `inst_b`, a control for `inst_b` is its own.
    // A second heartbeat means the first one's reply has been read.
    fake.until("two heartbeats", |s| s.heartbeats.len() >= 2).await;
    let to = Target { daemon_id: Some("inst_b".into()), ..Target::default() };
    fake.lease(InMessage { message_id: "c-5".into(), to, ..message("c-5", "", Kind::Control) });
    fake.until("c-5", |s| !s.acked("c-5").is_empty()).await;
    assert_eq!(fake.with(|s| s.acked("c-5")[0].state), AckState::Delivered);
    assert_eq!(*hook.0.lock().unwrap(), vec!["c-2".to_owned(), "c-5".to_owned()]);
    relay.stop().await;
}

#[tokio::test]
async fn a_failing_or_impatient_hub_is_never_called_in_a_busy_loop() {
    let down = FakeHub { down: true, ..FakeHub::default() };
    // A backoff that starts at nothing still waits the poll floor between calls.
    let zero = || RelayOptions { backoff_first: Duration::ZERO, ..quick() };
    let impatient = FakeHub { impatient: true, ..FakeHub::default() };
    for fake in [down, impatient] {
        let hub = hub();
        let fake = Arc::new(fake);
        let relay = MeshRelay::start(&hub, fake.clone(), Arc::new(RefuseControl), zero());
        tokio::time::sleep(Duration::from_secs(1)).await;
        relay.stop().await;
        let calls = fake.with(|s| s.inbox_calls);
        // 100 ms apart at the least, even with no backoff: about 10 at most.
        assert!((1..=15).contains(&calls), "{calls} inbox calls in a second");
    }
}

fn send_queue(target: &str, prompt_id: &str) -> Value {
    json!({"request": {
        "sessionId": target,
        "prompt": [{"type": "text", "text": "from another machine"}],
        "_meta": {"acpmux": {"promptId": prompt_id, "steer": false}},
    }})
}

#[tokio::test]
async fn a_send_to_a_name_no_peer_has_goes_through_the_hub_and_is_delivered_with_its_prompt_id() {
    // Host B runs the session and the relay; host A has neither, only the hub.
    let (a, b) = (hub(), hub());
    let session = Client::local(&b).new_session("dep-land").await;
    let fake = Arc::new(FakeHub::default());
    let relay = MeshRelay::start(&b, fake.clone(), Arc::new(RefuseControl), quick());
    fake.until("B's heartbeat", |s| s.heartbeats.iter().any(|h| !h.sessions.is_empty())).await;

    let mut sender = Client::local(&a);
    // With no hub, the send is refused as before.
    let refused = sender.call("_acpmux/send_queue", send_queue("dep-land", "prompt-0001")).await;
    assert_eq!(refused.pointer("/error/data/reason"), Some(&json!("no_session")), "{refused}");
    assert!(fake.with(|s| s.keys.is_empty()), "a send with no hub reached it");

    let _ = a.mesh.set(fake.clone());
    let queued = sender.call("_acpmux/send_queue", send_queue("dep-land", "prompt-0001")).await;
    let delivery = queued.pointer("/result/deliveryId").and_then(Value::as_str).unwrap().to_owned();
    assert!(delivery.starts_with("mesh:msg_"), "{queued}");
    // The same send again is the same message.
    let again = sender.call("_acpmux/send_queue", send_queue("dep-land", "prompt-0001")).await;
    assert_eq!(again.pointer("/result/deliveryId"), Some(&json!(delivery)), "{again}");

    let message = delivery.trim_start_matches("mesh:").to_owned();
    fake.until("delivered", |s| s.receipts[&message].state == "delivered").await;
    let status = sender.call("_acpmux/send_status", json!({"deliveryId": delivery})).await;
    assert_eq!(status.pointer("/result/status"), Some(&json!("delivered")), "{status}");
    assert_eq!(status.pointer("/result/accepted/promptId"), Some(&json!(message)), "{status}");
    // The outbox's status shape: its prompt id and times too.
    assert_eq!(status.pointer("/result/promptId"), Some(&json!(message)), "{status}");
    assert_eq!(status.pointer("/result/createdAt"), Some(&json!(1000)), "{status}");
    assert_eq!(status.pointer("/result/updatedAt"), Some(&json!(2000)), "{status}");
    // An unknown id is no delivery; a hub that does not answer is "ask again", not "unknown".
    let unknown = sender.call("_acpmux/send_status", json!({"deliveryId": "mesh:msg_none"})).await;
    assert_eq!(unknown.pointer("/error/data/reason"), Some(&json!("outbox.unknown")), "{unknown}");
    let lost = hub();
    let _ = lost.mesh.set(Arc::new(FakeHub { down: true, ..FakeHub::default() }));
    let asked =
        Client::local(&lost).call("_acpmux/send_status", json!({"deliveryId": delivery})).await;
    assert_eq!(asked.pointer("/error/data/reason"), Some(&json!("mesh.unavailable")), "{asked}");
    let mut on_b = Client::local(&b);
    let mut info = Value::Null;
    for _ in 0..600 {
        info = on_b.call("_acpmux/info", json!({"sessionId": session})).await;
        let ran = info.pointer("/result/turnCount").and_then(Value::as_u64).unwrap_or(0) > 0;
        if ran && info.pointer("/result/turn").is_none_or(Value::is_null) {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert_eq!(info.pointer("/result/turnCount"), Some(&json!(1)), "{info}");

    // A name the hub does not know is no session, as before.
    let unknown = sender.call("_acpmux/send_queue", send_queue("nobody", "prompt-0002")).await;
    assert_eq!(unknown.pointer("/error/data/reason"), Some(&json!("no_session")), "{unknown}");
    relay.stop().await;
}

#[tokio::test]
async fn the_heartbeat_lists_the_sessions_here_and_a_stop_empties_them() {
    let hub = hub();
    let session = Client::local(&hub).new_session("dep-fleet").await;
    let fake = Arc::new(FakeHub::default());
    let relay = MeshRelay::start(&hub, fake.clone(), Arc::new(RefuseControl), quick());
    fake.until("a heartbeat", |s| !s.heartbeats.is_empty()).await;
    let rows = fake.with(|s| s.heartbeats[0].sessions.clone());
    assert_eq!(rows.len(), 1, "{rows:?}");
    assert_eq!((rows[0].name.as_str(), rows[0].session_id.as_str()), ("dep-fleet", &*session));
    assert_eq!(rows[0].harness, "fake");
    relay.stop().await;
    let last = fake.with(|s| s.heartbeats.last().cloned().unwrap());
    assert!(last.sessions.is_empty(), "the stop sends an empty heartbeat: {last:?}");
}

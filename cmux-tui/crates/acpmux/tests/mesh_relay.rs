//! The mesh relay against a fake hub (`mesh.rs`, `server/mesh_relay.rs`, `server/mesh_send.rs`):
//! a send to a name no peer has goes through the hub and its receipt reaches delivered with the
//! prompt id; a message for a session here is delivered once, even when the hub leases it again;
//! a relayed message runs as a peer's and reads none of this host's peers; control messages go to
//! the hook; a message for another host or daemon never runs here; the heartbeat lists the
//! sessions here; with no hub nothing changes; no loop calls a failing or impatient hub in a busy
//! loop, and the relay ends when the daemon stops; a refusal from the mesh hub only pauses it.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::mesh::{
    Ack, AckState, Capacity, Heartbeat, HeartbeatReply, HubError, InMessage, Kind, MeshHub, Mode,
    OutMessage, Receipt, Sender, SessionRow, Target,
};
use acpmux::mesh_control::{
    Command as ControlCommand, ControlRequest, MeshControlRelay, Recipient, submit,
};
use acpmux::mesh_http::MeshControlFrom;
use acpmux::rpc::Message;
use acpmux::server::mesh_relay::{
    ControlHook, MeshControlHook, MeshRelay, RefuseControl, RelayOptions, relay_connection,
};
use acpmux::server::{Origin, serve_connection_with};
use acpmux::store::{EventRecord, MemoryStore, SessionStatus, Store};
use futures::future::BoxFuture;
use serde_json::{Value, json};
use std::collections::{HashMap, VecDeque};
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::{Notify, mpsc};

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

fn config() -> Config {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE], "family": "codex"}},
        "defaultHarness": "fake",
        // A failed turn's held prompts wait for Resume (`queue.rs` `waits_for_resume`).
        "autoResumeDelaysMs": [],
        "permissionPolicy": "approve-all"
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    cfg
}

fn hub() -> Arc<Hub> {
    let cfg = config();
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
        refused_retry: Duration::from_millis(300),
        max_in_flight: 4,
        on_reconnect: None,
        capacity_every: None,
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
        start_work: None,
        state: None,
        subject: None,
    }
}

/// What the hub holds for one daemon, and what the daemon told it.
#[derive(Default)]
struct State {
    waiting: VecDeque<InMessage>,
    acks: Vec<(String, Ack)>,
    inbox_calls: usize,
    heartbeats: Vec<Heartbeat>,
    /// When each heartbeat came, on tokio's clock.
    beat_at: Vec<tokio::time::Instant>,
    /// Idempotency key to message id.
    keys: HashMap<String, String>,
    receipts: HashMap<String, Receipt>,
    /// Every message posted, as the hub got it.
    sent: Vec<OutMessage>,
    /// Every capacity report, and when it came on tokio's clock.
    capacities: Vec<(Capacity, tokio::time::Instant)>,
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
    /// Every call is refused (a bad credential).
    refusing: bool,
    /// Only inbox calls are refused; heartbeats are taken.
    refusing_inbox: bool,
    /// The heartbeats refused before the hub takes this daemon (a hub deploy, a proxy's 403).
    refused_beats: std::sync::atomic::AtomicUsize,
    /// The inbox long-polls for a minute, far past the test's wait.
    long: bool,
    /// The row TTL a heartbeat reply names (90 s, the hub's old TTL, when unset).
    ttl_seconds: Option<u64>,
    /// Capacity reports are refused (an older hub with no such route).
    refusing_capacity: bool,
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
        self.until_within(Duration::from_secs(30), what, done).await;
    }

    /// Waits up to `limit` for `done` to hold.
    async fn until_within(&self, limit: Duration, what: &str, done: impl Fn(&State) -> bool) {
        let deadline = tokio::time::Instant::now() + limit;
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
            self.with(|s| {
                s.heartbeats.push(beat.clone());
                s.beat_at.push(tokio::time::Instant::now());
            });
            if self.refusing {
                return Err(HubError::refused("401 mesh.unauthorized"));
            }
            let left = std::sync::atomic::Ordering::SeqCst;
            if self.refused_beats.fetch_update(left, left, |n| n.checked_sub(1)).is_ok() {
                return Err(HubError { status: Some(403), ..HubError::refused("403 forbidden") });
            }
            Ok(HeartbeatReply {
                daemon_id: "inst_b".into(),
                ttl_seconds: self.ttl_seconds.unwrap_or(90),
            })
        })
    }

    /// Routes to the one daemon whose last heartbeat lists the name.
    fn send<'a>(&'a self, m: &'a OutMessage) -> BoxFuture<'a, Result<Receipt, HubError>> {
        Box::pin(async move {
            m.validate().map_err(HubError::refused)?;
            self.with(|s| {
                s.sent.push(m.clone());
                if let Some(id) = s.keys.get(&m.idempotency_key) {
                    return Ok(s.receipts[id].clone());
                }
                let listed = (m.kind == Kind::Control
                    && m.to.daemon_id.as_deref() == Some("inst_b"))
                    || s.heartbeats.last().is_some_and(|b| {
                        b.sessions.iter().any(|r| {
                            Some(&r.name) == m.to.name.as_ref()
                                || Some(&r.session_id) == m.to.session_id.as_ref()
                        })
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
                    delivered_at: None,
                    read_at: None,
                    read_by: None,
                    acked_by: None,
                    resolution: None,
                    start_work: None,
                    result: None,
                };
                s.receipts.insert(id.clone(), receipt.clone());
                s.waiting.push_back(InMessage {
                    message_id: id,
                    kind: m.kind,
                    op: m.op.clone(),
                    mode: m.mode,
                    // The hub resolved the host: the inbox names only the session.
                    to: Target {
                        session_id: m.to.session_id.clone(),
                        name: m.to.name.clone(),
                        ..Target::default()
                    },
                    from: Sender { daemon_id: Some("inst_a".into()), ..m.from.clone() },
                    body: m.body.clone(),
                    attempt: 1,
                    start_work: m
                        .to
                        .team_address
                        .as_ref()
                        .map(|_| acpmux::mesh::StartWork::Information),
                    state: Some("queued".into()),
                    subject: None,
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

    fn capacity<'a>(&'a self, report: &'a Capacity) -> BoxFuture<'a, Result<(), HubError>> {
        Box::pin(async move {
            self.with(|s| s.capacities.push((report.clone(), tokio::time::Instant::now())));
            if self.refusing_capacity {
                return Err(HubError { status: Some(404), ..HubError::refused("404") });
            }
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

    // An id that is no plain id (here a credential) is never run, acked (its path) or logged.
    let token_id = "Bearer eyJhbGciOiJIUzI1NiJ9/../ack";
    fake.lease(message(token_id, "dep-land", Kind::Prompt));
    // Canonical sender display metadata does not turn a legacy session target into team traffic.
    let mut legacy = message("msg-1", "dep-land", Kind::Prompt);
    legacy.from.team_address = Some("@member/coordinator".into());
    fake.lease(legacy);
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
    assert!(fake.with(|s| s.acked(token_id).is_empty()), "a malformed id was acked");
    relay.stop().await;
}

/// A relayed message names the session that sent it (`fromSessionId` on its provenance), as its
/// daemon proved it (`mesh_send.rs`), so the queue row opens that chat; the hub's sender record
/// carries no harness, so it names none.
#[tokio::test]
async fn a_relayed_message_names_its_sending_session_for_display() {
    let hub = hub();
    let mut local = Client::local(&hub);
    let session = local.new_session("dep-land").await;
    let fake = Arc::new(FakeHub::default());
    let relay = MeshRelay::start(&hub, fake.clone(), Arc::new(RefuseControl), quick());
    let mut sent = message("msg-from", "dep-land", Kind::Prompt);
    sent.from.session_id = Some("s-remote-1".into());
    fake.lease(sent);
    fake.until("the ack", |s| !s.acked("msg-from").is_empty()).await;
    let mut found = Value::Null;
    for _ in 0..600 {
        let page = local
            .call("_acpmux/events", json!({"sessionId": session, "kinds": ["user_message"]}))
            .await;
        let events = page.pointer("/result/events").and_then(Value::as_array).cloned();
        if let Some(e) = events.into_iter().flatten().find(|e| e["msg"]["promptId"] == "msg-from") {
            found = e["msg"].clone();
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let p = &found["_meta"]["provenance"];
    assert_eq!(p["fromName"], "gcp-lane/lane-a", "{found}");
    assert_eq!(p["fromSessionId"], "s-remote-1", "{found}");
    assert!(p.get("fromHarness").is_none(), "{found}");
    relay.stop().await;
}

/// The provenance of `prompt_id` in `session`, once it is recorded: as the turn's user message,
/// or as an inbox entry, where a relay's message to a chat that did not delegate to it waits
/// (`hub/inbox.rs`), as it does over a peer link.
async fn delivered_provenance(local: &mut Client, session: &str, prompt_id: &str) -> Value {
    for _ in 0..600 {
        let page = local
            .call(
                "_acpmux/events",
                json!({"sessionId": session, "kinds": ["user_message", "inbox"]}),
            )
            .await;
        let events = page.pointer("/result/events").and_then(Value::as_array).cloned();
        if let Some(e) = events.into_iter().flatten().find(|e| e["msg"]["promptId"] == prompt_id) {
            return e["msg"]["_meta"]["provenance"].clone();
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!("{prompt_id} never reached {session}");
}

/// A message no session sent (the lane-gh broker's `acpmux send`, a shell outside acpmux) names
/// the machine the hub proved, verified: it read "a session on HOST (self-declared,
/// unauthenticated)" though the hub had authenticated HOST's daemon, and every receiver asked the
/// sender to confirm. The sending daemon's relay record names the session when it names the same
/// machine; one that names another machine is not believed.
#[tokio::test]
async fn a_relayed_message_no_session_sent_names_the_machine_the_hub_proved_as_verified() {
    let hub = hub();
    let mut local = Client::local(&hub);
    let session = local.new_session("dep-land").await;
    let fake = Arc::new(FakeHub::default());
    let relay = MeshRelay::start(&hub, fake.clone(), Arc::new(RefuseControl), quick());
    let sessionless = |id: &str, relay: Option<Value>| {
        let mut m = message(id, "dep-land", Kind::Prompt);
        m.from.name = None;
        m.from.relay = relay;
        m
    };
    fake.lease(sessionless("msg-bare", None));
    fake.lease(sessionless(
        "msg-relay",
        Some(json!({"by": "lane-gh", "machine": "gcp-lane", "session": "coord"})),
    ));
    fake.lease(sessionless(
        "msg-other",
        Some(json!({"by": "lane-gh", "machine": "elsewhere", "session": "coord"})),
    ));
    for (id, shown) in
        [("msg-bare", "gcp-lane"), ("msg-relay", "gcp-lane/coord"), ("msg-other", "gcp-lane")]
    {
        fake.until("the ack", |s| !s.acked(id).is_empty()).await;
        assert_eq!(fake.with(|s| s.acked(id)), vec![Ack::delivered(id, None)], "{id}");
        let p = delivered_provenance(&mut local, &session, id).await;
        assert_eq!(p["fromName"], shown, "{id}: {p}");
        let record = acpmux::prompt_provenance::sender_record(Some(&p), None, None);
        assert_eq!(record["verification"], "verified", "{id}: {record}");
        assert_eq!(record["authenticated"], true, "{id}: {record}");
        assert_eq!(record["relay"]["machine"], "gcp-lane", "{id}: {record}");
    }
    relay.stop().await;
}

/// A send from no session (a relay on this machine's unix socket) carries its relay record to the
/// hub, so the receiving machine can name the session it came from; a proven session's send
/// carries none, whatever it wrote.
#[tokio::test]
async fn a_send_through_the_hub_from_no_session_carries_its_relay_record() {
    let a = hub();
    let lane = Client::local(&a).new_session("lane-a").await;
    let fake = Arc::new(FakeHub::default());
    let row = SessionRow {
        name: "dep-land".into(),
        session_id: "s-b".into(),
        harness: "fake".into(),
        state: "ready".into(),
        stuck_reason: None,
        team_address: None,
        cwd: None,
        title: None,
        title_source: None,
        name_given: None,
        model: None,
        agent_session_id: None,
        host_build: None,
        handle: None,
        former_names: Vec::new(),
        roles: Vec::new(),
    };
    fake.with(|s| {
        s.heartbeats.push(Heartbeat { host: "b".into(), sessions: vec![row], leaving: false })
    });
    let _ = a.mesh.set(fake.clone());
    let relayed = |id: &str| {
        let mut request = send_queue("dep-land", id);
        request["request"]["_meta"]["acpmux"]["fromRelay"] =
            json!({"by": "lane-gh", "machine": "vm-1", "session": "coord"});
        request
    };
    let mut broker = Client::local(&a);
    broker.call("initialize", json!({"protocolVersion": 1})).await;
    let queued = broker.call("_acpmux/send_queue", relayed("prompt-relay-1")).await;
    assert!(queued.pointer("/result/deliveryId").is_some(), "{queued}");
    let from = fake.with(|s| s.sent.last().unwrap().from.clone());
    assert_eq!(from.session_id, None, "{from:?}");
    assert_eq!(
        from.relay,
        Some(json!({"by": "lane-gh", "machine": "vm-1", "session": "coord"})),
        "{from:?}"
    );

    let mut as_lane = Client::local(&a);
    let token = acpmux::hub::person::caller_token(&lane);
    let caller = json!({"callerSession": {"sessionId": lane, "token": token}});
    as_lane.call("initialize", json!({"protocolVersion": 1, "_meta": {"acpmux": caller}})).await;
    let queued = as_lane.call("_acpmux/send_queue", relayed("prompt-relay-2")).await;
    assert!(queued.pointer("/result/deliveryId").is_some(), "{queued}");
    let from = fake.with(|s| s.sent.last().unwrap().from.clone());
    assert_eq!(from.session_id.as_deref(), Some(lane.as_str()), "{from:?}");
    assert_eq!(from.relay, None, "{from:?}");
}

/// A relayed message's sender claim reaches the chat as the sender's own word: a `checked` it
/// carries is the sending daemon's, which this one cannot confirm, so it is dropped.
#[tokio::test]
async fn a_relayed_message_keeps_its_senders_claim_as_self_reported() {
    let hub = hub();
    let mut local = Client::local(&hub);
    let session = local.new_session("dep-land").await;
    let fake = Arc::new(FakeHub::default());
    let relay = MeshRelay::start(&hub, fake.clone(), Arc::new(RefuseControl), quick());
    let mut sent = message("msg-claim", "dep-land", Kind::Prompt);
    sent.from.claim = Some(json!({
        "harness": "claude-code", "entrypoint": "claude-desktop",
        "checked": {"harness": "claude-code", "app": "Claude.app"},
    }));
    fake.lease(sent);
    fake.until("the ack", |s| !s.acked("msg-claim").is_empty()).await;
    let mut claim = Value::Null;
    for _ in 0..600 {
        let events = hub.events(&session, 0, 1000).unwrap();
        if let Some(e) = events.iter().find(|e| e.kind == "sender_claim") {
            claim = e.msg.clone();
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert_eq!(claim["promptId"], "msg-claim", "{claim}");
    assert_eq!(claim["claimed"]["harness"], "claude-code", "{claim}");
    assert_eq!(claim["claimed"]["entrypoint"], "claude-desktop", "{claim}");
    assert_eq!(claim["claimed"]["selfReported"], true, "{claim}");
    assert!(claim.get("checked").is_none(), "{claim}");
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
    // The prompt ids in the chat's records: a turn's or an inbox item's. Another agent's message
    // to a chat that already ran a turn goes to its inbox, not a turn of its own (`hub/inbox.rs`),
    // so the chat's turn count says nothing about what reached it.
    async fn held(local: &mut Client, session: &str) -> Vec<String> {
        let page = local.call("_acpmux/events", json!({"sessionId": session})).await;
        let mut ids: Vec<String> = page
            .pointer("/result/events")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|e| e["msg"]["promptId"].as_str().map(str::to_owned))
            .collect();
        ids.sort();
        ids.dedup();
        ids
    }
    let own = acpmux::pairing::machine_name();
    let mut ran: Vec<String> = Vec::new();
    if own != "host" {
        // Its own host, as a field and as a prefix, is this one: those reach the chat.
        let mine = [
            ("own-host", named(Some(&own.to_uppercase()), None)),
            ("own-prefix", Target { name: Some(format!("{own}/dep-land")), ..Target::default() }),
        ];
        for (id, target) in mine {
            fake.lease(InMessage { message_id: id.into(), ..to(target) });
            fake.until(id, |s| !s.acked(id).is_empty()).await;
            assert_eq!(fake.with(|s| s.acked(id)[0].clone()), Ack::delivered(id, None), "{id}");
            ran.push(id.to_owned());
        }
    }
    ran.sort();
    let mut got = Vec::new();
    for _ in 0..600 {
        got = held(&mut local, &session).await;
        if got.len() >= ran.len() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert_eq!(got, ran, "a message for elsewhere reached the chat here, or one for here did not");
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
async fn the_relay_ends_when_the_daemon_stops_and_a_refusal_only_pauses_it() {
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

    // A refused heartbeat (a bad credential) is tried again, never sooner than the heartbeat
    // floor (2.5 s, above the test's `refused_retry`), and the inbox, which waits for the hub to
    // name this daemon, never polls; the relay keeps running.
    let refused = hub();
    let fake = Arc::new(FakeHub { refusing: true, ..FakeHub::default() });
    let relay = MeshRelay::start(&refused, fake.clone(), Arc::new(RefuseControl), quick());
    fake.until_within(Duration::from_secs(10), "a second refused heartbeat", |s| {
        s.heartbeats.len() >= 2
    })
    .await;
    assert!(!relay.is_finished(), "a refused heartbeat ended the relay");
    let (inbox_calls, gap) = fake.with(|s| (s.inbox_calls, s.beat_at[1] - s.beat_at[0]));
    assert_eq!(inbox_calls, 0);
    assert!(gap >= Duration::from_millis(2400), "refused heartbeats {gap:?} apart");
    relay.stop().await;

    // The hub takes heartbeats but refuses the inbox: the heartbeat lists no session, so the
    // address book does not list sessions no message can reach, and the inbox is tried again
    // every `refused_retry`.
    let refused = hub();
    let fake = Arc::new(FakeHub { refusing_inbox: true, ..FakeHub::default() });
    let relay = MeshRelay::start(&refused, fake.clone(), Arc::new(RefuseControl), quick());
    fake.until("a second refused inbox", |s| s.inbox_calls >= 2).await;
    assert!(!relay.is_finished(), "a refused inbox ended the relay");
    assert!(fake.with(|s| s.heartbeats.last().is_some_and(|b| b.sessions.is_empty())));
    tokio::time::sleep(Duration::from_millis(1000)).await;
    let calls = fake.with(|s| s.inbox_calls);
    assert!((3..=8).contains(&calls), "{calls} refused inbox calls");
    relay.stop().await;
}

/// The coordinator chats that stopped hearing from other machines: a hub that refused this
/// daemon's heartbeats for a while (a deploy, a proxy's 403) switched its relay off until the
/// daemon restarted. Once the hub takes it again, the sessions here are listed and a message
/// waiting for one is delivered.
#[tokio::test]
async fn a_daemon_the_hub_refused_for_a_while_is_listed_and_delivered_to_again() {
    let hub = hub();
    let mut local = Client::local(&hub);
    local.new_session("coordinator").await;
    let fake = Arc::new(FakeHub { refused_beats: 3.into(), ..FakeHub::default() });
    let relay = MeshRelay::start(&hub, fake.clone(), Arc::new(RefuseControl), quick());
    fake.lease(message("msg-after-refusal", "coordinator", Kind::Prompt));
    fake.until("the message after the refusals", |s| !s.acked("msg-after-refusal").is_empty())
        .await;
    assert_eq!(
        fake.with(|s| s.acked("msg-after-refusal")),
        vec![Ack::delivered("msg-after-refusal", None)]
    );
    assert!(fake.with(|s| s.heartbeats.iter().any(|b| !b.sessions.is_empty())));
    assert!(!relay.is_finished());
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
async fn mesh_control_dispatches_through_peer_requests_and_refuses_unknown_sessions() {
    let hub = hub();
    let dir = tempfile::tempdir().unwrap();
    let message = InMessage {
        message_id: "control-resume-1".into(),
        kind: Kind::Control,
        op: Some("resume".into()),
        mode: Mode::Now,
        to: Target { session_id: Some("missing-session".into()), ..Target::default() },
        body: r#"{"version":1}"#.into(),
        ..message("control-resume-1", "", Kind::Control)
    };
    let hook = MeshControlHook::new(
        vec![MeshControlFrom {
            daemon_id: "inst_a".into(),
            ops: vec!["start".into(), "resume".into(), "stop".into()],
            ..Default::default()
        }],
        Some(dir.path().join("mesh-controls.json")),
    );
    let ack = hook.control(&hub, &message).await.expect("control is acknowledged");
    assert_eq!(ack.state, AckState::Refused);
    assert!(ack.detail.as_deref().is_some_and(|detail| detail.contains("no session")), "{ack:?}");
}

#[tokio::test]
async fn mesh_control_requires_owner_allowlist_and_stamped_daemon_id() {
    let hub = hub();
    let dir = tempfile::tempdir().unwrap();
    let allowed = MeshControlHook::new(
        vec![MeshControlFrom {
            daemon_id: "inst_a".into(),
            ops: vec!["resume".into()],
            ..Default::default()
        }],
        Some(dir.path().join("mesh-controls.json")),
    );
    let base = |op: &str, sender: Option<&str>| InMessage {
        message_id: format!("control-{op}-{}", sender.unwrap_or("missing")),
        kind: Kind::Control,
        op: Some(op.into()),
        mode: Mode::Now,
        to: Target { session_id: Some("missing-session".into()), ..Target::default() },
        from: Sender {
            daemon_id: sender.map(str::to_owned),
            // These are claims and must never make an unlisted sender acceptable.
            name: Some("inst_a".into()),
            host: Some("owner-host".into()),
            ..Sender::default()
        },
        body: r#"{"version":1}"#.into(),
        attempt: 1,
        start_work: None,
        state: None,
        subject: None,
    };

    let ack = allowed.control(&hub, &base("resume", Some("inst_a"))).await.unwrap();
    assert!(ack.detail.as_deref().is_some_and(|detail| detail.contains("no session")), "{ack:?}");
    for (op, sender) in [
        ("resume", None),
        ("resume", Some("")),
        ("resume", Some("other")),
        ("stop", Some("inst_a")),
    ] {
        let ack = allowed.control(&hub, &base(op, sender)).await.unwrap();
        assert_eq!(ack.state, AckState::Refused);
        assert_eq!(ack.detail.as_deref(), Some("mesh.control_not_allowed"));
    }
    let mut unsupported = base("resume", Some("inst_a"));
    unsupported.message_id = "control-unsupported-version".into();
    unsupported.body = r#"{"version":2}"#.into();
    let ack = allowed.control(&hub, &unsupported).await.unwrap();
    assert_eq!(ack.state, AckState::Refused);
    assert_eq!(ack.detail.as_deref(), Some("unsupported control body version"));
    let default = MeshControlHook::new(vec![], None);
    let ack = default.control(&hub, &base("resume", Some("inst_a"))).await.unwrap();
    assert_eq!(ack.detail.as_deref(), Some("mesh.control_not_allowed"));
}

#[tokio::test]
async fn mesh_control_same_user_trusts_only_the_hub_stamped_person_recorded_here() {
    let hub = hub();
    let dir = tempfile::tempdir().unwrap();
    let hook = |entry: Value, own: Option<&'static str>| {
        MeshControlHook::new(
            vec![serde_json::from_value(entry).unwrap()],
            Some(dir.path().join("mesh-controls.json")),
        )
        .with_own_user(Arc::new(move || own.map(str::to_owned)))
    };
    let control = |id: &str, user: Option<&str>| InMessage {
        message_id: id.into(),
        kind: Kind::Control,
        op: Some("resume".into()),
        mode: Mode::Now,
        to: Target { session_id: Some("missing-session".into()), ..Target::default() },
        from: Sender {
            daemon_id: Some("inst_other_machine".into()),
            user: user.map(str::to_owned),
            // Claims a sender makes about itself are never authority.
            name: Some("person-1".into()),
            host: Some("person-1".into()),
            ..Sender::default()
        },
        body: r#"{"version":1}"#.into(),
        attempt: 1,
        start_work: None,
        state: None,
        subject: None,
    };
    let same = hook(json!({"sameUser": true}), Some("person-1"));
    // The same person's other machine passes authorization (the session is then looked up).
    let ack = same.control(&hub, &control("same-user", Some("person-1"))).await.unwrap();
    assert!(ack.detail.as_deref().is_some_and(|detail| detail.contains("no session")), "{ack:?}");
    // Another person, or a sender the hub stamped with no person, is refused.
    for (id, user) in [("other-user", Some("person-2")), ("no-user", None)] {
        let ack = same.control(&hub, &control(id, user)).await.unwrap();
        assert_eq!(ack.detail.as_deref(), Some("mesh.control_not_allowed"), "{id}");
    }
    // A machine that recorded no person grants nothing through `sameUser`.
    let unrecorded = hook(json!({"sameUser": true}), None);
    let ack = unrecorded.control(&hub, &control("unrecorded", Some("person-1"))).await.unwrap();
    assert_eq!(ack.detail.as_deref(), Some("mesh.control_not_allowed"));
    // An explicit empty ops list grants nothing.
    let none = hook(json!({"sameUser": true, "ops": []}), Some("person-1"));
    let ack = none.control(&hub, &control("no-ops", Some("person-1"))).await.unwrap();
    assert_eq!(ack.detail.as_deref(), Some("mesh.control_not_allowed"));
    // An explicit daemonId entry still works alongside, and the person alone never stands in.
    let both = MeshControlHook::new(
        vec![
            MeshControlFrom {
                daemon_id: "inst_other_machine".into(),
                ops: vec!["resume".into()],
                ..Default::default()
            },
            MeshControlFrom { ops: vec!["stop".into()], ..MeshControlFrom::same_user() },
        ],
        Some(dir.path().join("both.json")),
    );
    let ack = both.control(&hub, &control("by-daemon", None)).await.unwrap();
    assert!(ack.detail.as_deref().is_some_and(|detail| detail.contains("no session")), "{ack:?}");
}

#[tokio::test]
async fn mesh_control_rejects_peer_routing_and_replays_a_persisted_ack() {
    let hub = hub();
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("mesh-controls.json");
    let hook = MeshControlHook::new(
        vec![MeshControlFrom {
            daemon_id: "inst_a".into(),
            ops: vec!["start".into(), "resume".into(), "stop".into()],
            ..Default::default()
        }],
        Some(path.clone()),
    );
    let mut routed = message("control-routed", "", Kind::Control);
    routed.body =
        r#"{"version":1,"params":{"cwd":"/tmp","_meta":{"acpmux":{"peer":"other"}}}}"#.into();
    let ack = hook.control(&hub, &routed).await.unwrap();
    assert_eq!(ack.state, AckState::Refused);
    assert!(ack.detail.as_deref().is_some_and(|d| d.contains("cannot forward")));

    let mut duplicate = message("control-persisted", "", Kind::Control);
    duplicate.op = Some("resume".into());
    duplicate.body = r#"{"version":1}"#.into();
    duplicate.to = Target { session_id: Some("missing-session".into()), ..Target::default() };
    let first = hook.control(&hub, &duplicate).await.unwrap();
    let restarted = MeshControlHook::new(
        vec![MeshControlFrom {
            daemon_id: "inst_a".into(),
            ops: vec!["start".into(), "resume".into(), "stop".into()],
            ..Default::default()
        }],
        Some(path),
    );
    let replayed = restarted.control(&hub, &duplicate).await.unwrap();
    assert_eq!(replayed, first);
    for sender in [Some("other"), None] {
        let mut forged = duplicate.clone();
        forged.from.daemon_id = sender.map(str::to_owned);
        let refused = restarted.control(&hub, &forged).await.unwrap();
        assert_eq!(refused.detail.as_deref(), Some("mesh.control_not_allowed"));
    }
}

fn control_allowlist() -> Vec<MeshControlFrom> {
    vec![MeshControlFrom {
        daemon_id: "inst_a".into(),
        ops: ["start", "resume", "stop"].map(str::to_owned).to_vec(),
        ..Default::default()
    }]
}

#[tokio::test]
async fn mesh_controls_start_and_stop_through_shared_sender_and_replay_success() {
    let fake = Arc::new(FakeHub::default());
    let dir = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(dir.path()).unwrap();
    let cwd = root.join("project");
    std::fs::create_dir(&cwd).unwrap();
    // The process uses daemon_env's private HOME and the hub's explicit Config above;
    // only this test's root is authorized, regardless of the runner's own config.
    let mut config = config();
    config.harnesses.get_mut("fake").unwrap().family = None;
    config.web_roots = vec![root.to_string_lossy().into_owned()];
    let unreviewed = Hub::new(config.clone(), Box::new(MemoryStore::default()));
    let mut request = message("start-unreviewed", "", Kind::Control);
    request.body = json!({"version": 1, "params": {"cwd": cwd, "mcpServers": [],
        "_meta":{"acpmux":{"harness":"fake", "name":"unreviewed", "policy":"ask"}}}})
    .to_string();
    let ack = MeshControlHook::new(
        control_allowlist(),
        Some(dir.path().join("unreviewed-controls.json")),
    )
    .control(&unreviewed, &request)
    .await
    .unwrap();
    assert_eq!(ack.state, AckState::Refused, "{ack:?}");
    assert!(
        ack.detail.as_deref().is_some_and(|detail| detail.contains(
            "this harness has no reviewed asking mode for a remote WebSocket connection"
        )),
        "{ack:?}"
    );
    assert!(unreviewed.resolve("unreviewed").is_err());
    unreviewed.shutdown_all().await;
    // Configure the stand-in's actual mode before constructing the successful hub.
    config.web_asking_modes.insert("fake".into(), vec!["normal".into(), "strict".into()]);
    let hub = Hub::new(config, Box::new(MemoryStore::default()));
    let path = dir.path().join("controls.json");
    let hook = Arc::new(MeshControlHook::new(control_allowlist(), Some(path.clone())));
    let relay = MeshRelay::start(&hub, fake.clone(), hook.clone(), quick());
    let sender = MeshControlRelay::new(fake.clone(), Sender::default());
    let outside = tempfile::tempdir().unwrap();
    let params = json!({"cwd": outside.path(), "mcpServers": [],
        "_meta":{"acpmux":{"harness":"fake", "name":"outside-root", "policy":"ask"}}});
    let refused = ControlRequest::new(
        Recipient::Daemon { daemon_id: "inst_b".into() },
        ControlCommand::Start { params: params.as_object().unwrap().clone() },
        "start-outside-root".into(),
    )
    .unwrap();
    let receipt = submit(&sender, &refused).await.unwrap();
    fake.until("cwd refusal", |s| !s.acked(&receipt.message_id).is_empty()).await;
    let ack = fake.with(|s| s.acked(&receipt.message_id)[0].clone());
    assert_eq!(ack.state, AckState::Refused, "{ack:?}");
    assert!(
        ack.detail.as_deref().is_some_and(|detail| {
            detail.contains("cwd is refused") && detail.contains("webRoots")
        }),
        "{ack:?}"
    );
    assert!(hub.resolve("outside-root").is_err());
    for by_name in [false, true] {
        let name = if by_name { "mesh-named" } else { "mesh-id" };
        let params = json!({"cwd": cwd, "mcpServers": [],
            "_meta":{"acpmux":{"harness":"fake", "name":name, "policy":"ask"}}});
        let request = ControlRequest::new(
            Recipient::Daemon { daemon_id: "inst_b".into() },
            ControlCommand::Start { params: params.as_object().unwrap().clone() },
            format!("start-{name}"),
        )
        .unwrap();
        let receipt = submit(&sender, &request).await.unwrap();
        assert_eq!(receipt.state, "queued");
        fake.until("start ack", |s| !s.acked(&receipt.message_id).is_empty()).await;
        let first = fake.with(|s| s.acked(&receipt.message_id)[0].clone());
        assert_eq!(first.state, AckState::Delivered, "{first:?}");
        let session = hub.resolve(name).unwrap();
        assert_eq!(first.detail.as_deref(), Some(session.id.as_str()));
        // Simulate a lost ack and a restarted hook: the successful start must replay, not
        // attempt a second creation (which would fail on the occupied name).
        let posted = fake.with(|s| s.sent.last().unwrap().clone());
        let duplicate = InMessage {
            message_id: receipt.message_id.clone(),
            kind: Kind::Control,
            op: posted.op,
            to: Target::default(),
            from: Sender { daemon_id: Some("inst_a".into()), ..Default::default() },
            body: posted.body,
            mode: posted.mode,
            attempt: 2,
            start_work: None,
            state: None,
            subject: None,
        };
        let restarted = MeshControlHook::new(control_allowlist(), Some(path.clone()));
        assert_eq!(restarted.control(&hub, &duplicate).await.unwrap(), first);
        // Give the fake hub the address-book row explicitly, avoiding a timer race.
        fake.heartbeat(&Heartbeat {
            host: "worker".into(),
            sessions: hub.mesh_rows().await,
            leaving: false,
        })
        .await
        .unwrap();
        let to = if by_name {
            Recipient::Name { name: name.into(), host: None }
        } else {
            Recipient::Session { session_id: session.id.clone() }
        };
        let request =
            ControlRequest::new(to, ControlCommand::Stop, format!("stop-{name}")).unwrap();
        let receipt = submit(&sender, &request).await.unwrap();
        fake.until("stop ack", |s| !s.acked(&receipt.message_id).is_empty()).await;
        assert_eq!(fake.with(|s| s.acked(&receipt.message_id)[0].state), AckState::Delivered);
        assert_eq!(hub.resolve(&session.id).unwrap().meta().status, SessionStatus::Closed);
    }
    relay.stop().await;
    hub.shutdown_all().await;
}

#[tokio::test]
async fn mesh_control_resume_releases_held_queue_by_id_and_name() {
    let seed = hub();
    let mut client = Client::local(&seed);
    let id = client.new_session("held-mesh").await;
    let mut meta = seed.resolve(&id).unwrap().meta();
    let config = seed.config.read().await.clone();
    seed.shutdown_all().await;
    meta.status = SessionStatus::Idle;
    for (by_name, owner_boundary) in [(false, false), (true, false), (false, true), (true, true)] {
        meta.vm_boundary = owner_boundary;
        let store = MemoryStore::default();
        store.save(&meta).unwrap();
        for (seq, kind, msg) in [
            (
                1,
                "queued",
                json!({"turnId":"held-turn", "promptId":"held-prompt", "text":"hello", "control":"peer"}),
            ),
            (2, "queue_paused", json!({"held":["held-prompt"]})),
        ] {
            store
                .append(
                    &id,
                    &EventRecord {
                        seq,
                        at: 1,
                        dir: "mux".into(),
                        kind: kind.into(),
                        msg,
                        host_seq: None,
                    },
                )
                .unwrap();
        }
        let receiver = Hub::new(config.clone(), Box::new(store));
        assert!(receiver.resolve(&id).unwrap().queue_paused());
        let mut resume =
            message(if by_name { "resume-name" } else { "resume-id" }, "", Kind::Control);
        resume.op = Some("resume".into());
        resume.body = r#"{"version":1}"#.into();
        resume.to = if by_name {
            Target { name: Some("held-mesh".into()), ..Default::default() }
        } else {
            Target { session_id: Some(id.clone()), ..Default::default() }
        };
        let ledger_dir = tempfile::tempdir().unwrap();
        let hook = MeshControlHook::new(
            control_allowlist(),
            Some(ledger_dir.path().join("mesh-controls.json")),
        );
        let ack = hook.control(&receiver, &resume).await.unwrap();
        // This hook has an explicit daemon grant, not a same-person grant. Its read may
        // inspect a boundary session, but the subsequent queue write must retain that mark.
        assert_eq!(
            ack.state,
            if owner_boundary { AckState::Refused } else { AckState::Delivered },
            "{ack:?}"
        );
        assert_eq!(receiver.resolve(&id).unwrap().queue_paused(), owner_boundary);
        receiver.shutdown_all().await;
    }
}

#[tokio::test]
async fn mesh_control_memory_store_refuses_before_and_after_restart() {
    let hub = hub();
    let root = tempfile::tempdir().unwrap();
    let cwd = root.path().join("project");
    std::fs::create_dir(&cwd).unwrap();
    {
        let mut config = hub.config.write().await;
        config.web_roots = vec![root.path().to_string_lossy().into_owned()];
        config.web_asking_modes.insert("fake".into(), vec!["normal".into()]);
    }
    let mut control = message("memory-control", "", Kind::Control);
    control.body = json!({
        "version": 1,
        "params": {"cwd": cwd, "mcpServers": [],
            "_meta": {"acpmux": {"harness": "fake", "name": "memory-control", "policy": "ask"}}}
    })
    .to_string();
    let first =
        MeshControlHook::new(control_allowlist(), None).control(&hub, &control).await.unwrap();
    assert_eq!(first.detail.as_deref(), Some("mesh.control_not_durable"));
    let restarted =
        MeshControlHook::new(control_allowlist(), None).control(&hub, &control).await.unwrap();
    assert_eq!(restarted.detail.as_deref(), Some("mesh.control_not_durable"));
    assert!(hub.resolve("memory-control").is_err());
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

    // `HOST/NAME` for a host with no peer link here (a VM only another host reaches) goes to
    // the hub with that host, which routes it by its address book.
    let far =
        sender.call("_acpmux/send_queue", send_queue("fs-peer-1/dep-land", "prompt-0003")).await;
    assert!(
        far.pointer("/result/deliveryId")
            .and_then(Value::as_str)
            .is_some_and(|d| d.starts_with("mesh:")),
        "{far}"
    );
    let to = fake.with(|s| s.sent.last().unwrap().to.clone());
    assert_eq!((to.host.as_deref(), to.name.as_deref()), (Some("fs-peer-1"), Some("dep-land")));
    // `HOST/ID` the same way, by the session's id (a chat just moved there is named so): never
    // looked up here as a name and refused as "no session HOST/ID on this machine".
    let by_id = format!("fs-peer-1/{session}");
    let far = sender.call("_acpmux/send_queue", send_queue(&by_id, "prompt-0006")).await;
    assert!(
        far.pointer("/result/deliveryId")
            .and_then(Value::as_str)
            .is_some_and(|d| d.starts_with("mesh:")),
        "{far}"
    );
    let to = fake.with(|s| s.sent.last().unwrap().to.clone());
    assert_eq!(
        (to.host.as_deref(), to.session_id.as_deref(), to.name.as_deref()),
        (Some("fs-peer-1"), Some(session.as_str()), None),
        "{to:?}"
    );

    // A supersede key cannot cross the hub: the send goes without it and says so, as the
    // sender would have sent it again anyway (cmuxterm-hq
    // docs/findings/2026-11-23-mcp-tool-error-census.md).
    let posted = fake.with(|s| s.sent.len());
    let mut keyed = send_queue("dep-land", "prompt-0004");
    keyed["request"]["_meta"]["acpmux"]["supersede"] = json!("status");
    let keyed = sender.call("_acpmux/send_queue", keyed).await;
    assert_eq!(keyed.pointer("/result/supersedeDropped"), Some(&json!(true)), "{keyed}");
    let said = keyed.pointer("/result/note").and_then(Value::as_str).unwrap_or_default();
    assert!(said.contains("no supersede key"), "{keyed}");
    assert_eq!(fake.with(|s| s.sent.len()), posted + 1, "a keyed send did not reach the hub");
    let posted = posted + 1;
    // A class but result has no field on the hub's message: it goes as the text's first line,
    // and the sender's row says so (`server/mesh_send.rs`, #49350), never as a plain result.
    let mut block = send_queue("dep-land", "prompt-0005");
    block["request"]["_meta"]["acpmux"]["class"] = json!("block");
    let block = sender.call("_acpmux/send_queue", block).await;
    assert_eq!(block.pointer("/result/classInline"), Some(&json!("block")), "{block}");
    let body = fake.with(|s| s.sent.last().unwrap().body.clone());
    assert_eq!(body, "[block]\n\nfrom another machine");
    assert_eq!(fake.with(|s| s.sent.len()), posted + 1, "a classified send did not reach the hub");
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
    // It says it is leaving, so the hub ends this daemon's waiting poll (own-machines e2e run
    // 42071975275: a start leased to the stopped daemon's poll ran 60 s later).
    assert!(last.leaving, "{last:?}");
    let earlier = fake.with(|s| s.heartbeats[0].clone());
    assert!(!earlier.leaving, "{earlier:?}");
    assert!(serde_json::to_value(&earlier).unwrap().get("leaving").is_none(), "omitted when false");
}

/// The heartbeat comes every third of the TTL the hub's reply names, so the hub tunes its liveness
/// window without a daemon release: a 30 s TTL beats every 10 s, a 90 s one every 30 s (capped at
/// `heartbeat_every`), and a reply with no TTL falls back to `heartbeat_every`.
#[tokio::test(start_paused = true)]
async fn the_heartbeat_comes_every_third_of_the_hubs_ttl() {
    for (ttl, every) in [(30, 10), (90, 30), (0, 30)] {
        let hub = hub();
        let fake = Arc::new(FakeHub { ttl_seconds: Some(ttl), ..FakeHub::default() });
        let options = RelayOptions { heartbeat_every: Duration::from_secs(30), ..quick() };
        let relay = MeshRelay::start(&hub, fake.clone(), Arc::new(RefuseControl), options);
        fake.until_within(Duration::from_secs(120), "three heartbeats", |s| s.beat_at.len() >= 3)
            .await;
        relay.stop().await;
        let at = fake.with(|s| s.beat_at.clone());
        for gap in at[..3].windows(2).map(|w| w[1] - w[0]) {
            assert!(
                gap >= Duration::from_secs(every)
                    && gap < Duration::from_secs(every) + Duration::from_millis(500),
                "ttl {ttl}: heartbeats {gap:?} apart, not every {every} s"
            );
        }
    }
}

/// A joined machine reports its free capacity to its team's placement (RFD 0004 step 3): every
/// `capacity_every`, with this daemon's live sessions and no fleet token; a refusal is asked again only after ten
/// minutes and never stops the relay's heartbeat; a relay that is not a joined one reports none.
#[tokio::test(start_paused = true)]
async fn a_joined_relay_reports_its_capacity_and_any_other_reports_none() {
    let hub = hub();
    let fake = Arc::new(FakeHub::default());
    let options = RelayOptions { capacity_every: Some(Duration::from_secs(40)), ..quick() };
    let relay = MeshRelay::start(&hub, fake.clone(), Arc::new(RefuseControl), options);
    fake.until_within(Duration::from_secs(200), "three capacity reports", |s| {
        s.capacities.len() >= 3
    })
    .await;
    relay.stop().await;
    let reports = fake.with(|s| s.capacities.clone());
    for gap in reports[..3].windows(2).map(|w| w[1].1 - w[0].1) {
        assert!(
            gap >= Duration::from_secs(40) && gap < Duration::from_secs(41),
            "reports {gap:?} apart"
        );
    }
    let report = serde_json::to_value(&reports[0].0).unwrap();
    assert_eq!(report["region"], "joined");
    assert_eq!(report["state"], "ready");
    assert_eq!(report["sessions_running"], hub.live_session_count() as u64);
    assert!(report.get("machine_token").is_none());
    assert!(!report["host_id"].as_str().unwrap().is_empty());
    let limits = &report["capabilities"];
    assert!(limits["maxVcpu"].as_f64().unwrap() >= 1.0, "{limits}");
    assert!(["linux", "macos"].contains(&limits["os"].as_str().unwrap()), "{limits}");
    assert!(report["free_vcpu"].as_f64().unwrap() <= limits["maxVcpu"].as_f64().unwrap());
    let after = fake.with(|s| s.capacities.len());
    tokio::time::sleep(Duration::from_secs(120)).await;
    assert_eq!(fake.with(|s| s.capacities.len()), after, "a stopped relay reports nothing");

    // Refused: asked again after ten minutes, not every 40 s; the heartbeat goes on.
    let hub = self::hub();
    let fake = Arc::new(FakeHub { refusing_capacity: true, ..FakeHub::default() });
    let options = RelayOptions { capacity_every: Some(Duration::from_secs(40)), ..quick() };
    let relay = MeshRelay::start(&hub, fake.clone(), Arc::new(RefuseControl), options);
    fake.until_within(Duration::from_secs(1300), "two refused reports", |s| {
        s.capacities.len() >= 2
    })
    .await;
    let (gap, beats) = fake.with(|s| (s.capacities[1].1 - s.capacities[0].1, s.heartbeats.len()));
    assert!(gap >= Duration::from_secs(600), "refused reports {gap:?} apart");
    assert!(beats > 100, "the heartbeat went on: {beats}");
    assert!(!relay.is_finished());
    relay.stop().await;

    // Not joined: no report.
    let hub = self::hub();
    let fake = Arc::new(FakeHub::default());
    let relay = MeshRelay::start(&hub, fake.clone(), Arc::new(RefuseControl), quick());
    fake.until_within(Duration::from_secs(10), "a heartbeat", |s| !s.heartbeats.is_empty()).await;
    tokio::time::sleep(Duration::from_secs(120)).await;
    relay.stop().await;
    assert!(fake.with(|s| s.capacities.is_empty()));
}

/// A session's send through the hub names that session as its sender, whatever `fromAgent` the
/// request claims.
#[tokio::test]
async fn a_send_through_the_hub_names_its_proven_session_not_a_claimed_one() {
    let a = hub();
    let lane = Client::local(&a).new_session("lane-a").await;
    let fake = Arc::new(FakeHub::default());
    let row = SessionRow {
        name: "dep-land".into(),
        session_id: "s-b".into(),
        harness: "fake".into(),
        state: "ready".into(),
        stuck_reason: None,
        team_address: None,
        cwd: None,
        title: None,
        title_source: None,
        name_given: None,
        model: None,
        agent_session_id: None,
        host_build: None,
        handle: None,
        former_names: Vec::new(),
        roles: Vec::new(),
    };
    fake.with(|s| {
        s.heartbeats.push(Heartbeat { host: "b".into(), sessions: vec![row], leaving: false })
    });
    let _ = a.mesh.set(fake.clone());
    let mut as_lane = Client::local(&a);
    let token = acpmux::hub::person::caller_token(&lane);
    let caller = json!({"callerSession": {"sessionId": lane, "token": token}});
    as_lane.call("initialize", json!({"protocolVersion": 1, "_meta": {"acpmux": caller}})).await;
    let mut request = send_queue("dep-land", "prompt-claim-1");
    request["request"]["_meta"]["acpmux"]["fromAgent"] = json!("coordinator");
    let queued = as_lane.call("_acpmux/send_queue", request).await;
    assert!(queued.pointer("/result/deliveryId").is_some(), "{queued}");
    let from = fake.with(|s| s.sent.last().unwrap().from.clone());
    assert_eq!(from.name.as_deref(), Some("lane-a"), "{from:?}");
    assert_eq!(from.session_id.as_deref(), Some(lane.as_str()), "{from:?}");
}

/// The sender of a direct `HOST/NAME` send through the hub reads its own status, though the hub
/// stamps `startWork` on every receipt and team messaging is off; another session does not
/// (2026-11-19: `acpmux send --status mesh:msg_…` answered "team message is not addressed to
/// this session" to the session that sent it).
#[tokio::test]
async fn the_sender_of_a_direct_send_through_the_hub_reads_its_status_and_no_other_session_does() {
    let a = hub();
    let lane = Client::local(&a).new_session("lane-a").await;
    let other = Client::local(&a).new_session("lane-c").await;
    let fake = Arc::new(FakeHub::default());
    let row = SessionRow {
        name: "dep-land".into(),
        session_id: "s-b".into(),
        harness: "fake".into(),
        state: "ready".into(),
        stuck_reason: None,
        team_address: None,
        cwd: None,
        title: None,
        title_source: None,
        name_given: None,
        model: None,
        agent_session_id: None,
        host_build: None,
        handle: None,
        former_names: Vec::new(),
        roles: Vec::new(),
    };
    fake.with(|s| {
        s.heartbeats.push(Heartbeat { host: "b".into(), sessions: vec![row], leaving: false })
    });
    let _ = a.mesh.set(fake.clone());
    let proven = |session: &str| {
        let token = acpmux::hub::person::caller_token(session);
        json!({"protocolVersion": 1,
               "_meta": {"acpmux": {"callerSession": {"sessionId": session, "token": token}}}})
    };
    // As the hub answers every receipt: with its start-work decision.
    let stamp = |delivery: &str| {
        let message = delivery.trim_start_matches("mesh:").to_owned();
        fake.with(|s| {
            s.receipts.get_mut(&message).unwrap().start_work =
                Some(acpmux::mesh::StartWork::Information)
        });
    };
    let mut as_lane = Client::local(&a);
    as_lane.call("initialize", proven(&lane)).await;
    let queued = as_lane.call("_acpmux/send_queue", send_queue("b/dep-land", "prompt-own-1")).await;
    let delivery = queued.pointer("/result/deliveryId").and_then(Value::as_str).unwrap().to_owned();
    stamp(&delivery);
    let status = as_lane.call("_acpmux/send_status", json!({"deliveryId": delivery})).await;
    assert_eq!(status.pointer("/result/status"), Some(&json!("queued")), "{status}");
    assert_eq!(status.pointer("/result/target"), Some(&json!("b/dep-land")), "{status}");
    let mut as_other = Client::local(&a);
    as_other.call("initialize", proven(&other)).await;
    let refused = as_other.call("_acpmux/send_status", json!({"deliveryId": delivery})).await;
    assert!(refused.get("error").is_some(), "another session read it: {refused}");

    // A send from the person's own terminal, no session proven: its status reads the same.
    let mut terminal = Client::local(&a);
    let queued =
        terminal.call("_acpmux/send_queue", send_queue("b/dep-land", "prompt-own-2")).await;
    let delivery = queued.pointer("/result/deliveryId").and_then(Value::as_str).unwrap().to_owned();
    stamp(&delivery);
    let status = terminal.call("_acpmux/send_status", json!({"deliveryId": delivery})).await;
    assert_eq!(status.pointer("/result/status"), Some(&json!("queued")), "{status}");
}

/// A send through the hub carries its sender claim on the wire, so the receiving machine can
/// show where it came from.
#[tokio::test]
async fn a_send_through_the_hub_carries_its_sender_claim() {
    let a = hub();
    let fake = Arc::new(FakeHub::default());
    let row = SessionRow {
        name: "dep-land".into(),
        session_id: "s-b".into(),
        harness: "fake".into(),
        state: "ready".into(),
        stuck_reason: None,
        team_address: None,
        cwd: None,
        title: None,
        title_source: None,
        name_given: None,
        model: None,
        agent_session_id: None,
        host_build: None,
        handle: None,
        former_names: Vec::new(),
        roles: Vec::new(),
    };
    fake.with(|s| {
        s.heartbeats.push(Heartbeat { host: "b".into(), sessions: vec![row], leaving: false })
    });
    let _ = a.mesh.set(fake.clone());
    let mut client = Client::local(&a);
    client.call("initialize", json!({"protocolVersion": 1})).await;
    let mut request = send_queue("dep-land", "prompt-claim-2");
    request["request"]["_meta"]["acpmux"]["senderHarness"] =
        json!({"harness": "claude-code", "entrypoint": "claude-desktop", "bogus": "x"});
    let queued = client.call("_acpmux/send_queue", request).await;
    assert!(queued.pointer("/result/deliveryId").is_some(), "{queued}");
    let from = fake.with(|s| s.sent.last().unwrap().from.clone());
    let claim = from.claim.unwrap_or_default();
    assert_eq!(claim["harness"], "claude-code", "{claim}");
    assert_eq!(claim["entrypoint"], "claude-desktop", "{claim}");
    assert!(claim.get("bogus").is_none() && claim.get("checked").is_none(), "{claim}");
}

#[tokio::test]
async fn team_delivery_refuses_when_disabled_and_only_allowed_starts_an_idle_turn() {
    use acpmux::mesh::StartWork;
    use acpmux::server::mesh_relay::deliver;
    let hub = hub();
    let mut local = Client::local(&hub);
    let session = local.new_session("team-reader").await;
    let mut incoming = message("team-info-1", "team-reader", Kind::Prompt);
    incoming.to.session_id = Some(session.clone());
    incoming.to.team_address = Some("@user_reader/coordinator".into());
    incoming.from.team_address = Some("@user_sender/coordinator".into());
    incoming.mode = Mode::Now;
    assert_eq!(
        deliver(&hub, &incoming, &RefuseControl, None).await.unwrap().state,
        AckState::Refused
    );
    hub.config.write().await.mesh_relay = Some(acpmux::mesh_http::MeshRelayConfig {
        url: "https://hub.invalid".into(),
        token_command: vec!["unused".into()],
        team_messaging: true,
        credential: None,
        control_from: Vec::new(),
    });
    // Missing startWork is information even if mode asks to steer.
    assert_eq!(
        deliver(&hub, &incoming, &RefuseControl, None).await.unwrap().state,
        AckState::Delivered
    );
    let info = local.call("_acpmux/info", json!({"sessionId": session})).await;
    assert_eq!(info.pointer("/result/turnCount"), Some(&json!(0)));
    incoming.message_id = "team-info-2".into();
    incoming.start_work = Some(StartWork::Information);
    assert_eq!(
        deliver(&hub, &incoming, &RefuseControl, None).await.unwrap().state,
        AckState::Delivered
    );
    let info = local.call("_acpmux/info", json!({"sessionId": session})).await;
    assert_eq!(info.pointer("/result/turnCount"), Some(&json!(0)));
    incoming.message_id = "team-allowed-1".into();
    incoming.start_work = Some(StartWork::Allowed);
    assert_eq!(
        deliver(&hub, &incoming, &RefuseControl, None).await.unwrap().state,
        AckState::Delivered
    );
    let done = local
        .call(
            "_acpmux/wait",
            json!({"sessions": [session], "until": ["ready"], "timeoutMs": 20000}),
        )
        .await;
    assert!(done.get("error").is_none(), "{done}");
    let info = local.call("_acpmux/info", json!({"sessionId": session})).await;
    assert_eq!(info.pointer("/result/turnCount"), Some(&json!(1)));
    let events = hub.events(&session, 0, 1000).unwrap();
    assert!(events.iter().any(|event| event.kind == "session/prompt"
        && event.msg.to_string().contains("Team message from @user_sender/coordinator")));
    hub.shutdown_all().await;
}

#[tokio::test]
async fn a_send_right_after_a_start_through_the_hub_reaches_the_new_session() {
    // B is a hub-only machine: A has no peer link to it. Its heartbeat timer is far past the
    // test, so only the start's own heartbeat can put the new session in the hub's book.
    let fake = Arc::new(FakeHub::default());
    let dir = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(dir.path()).unwrap();
    let cwd = root.join("project");
    std::fs::create_dir(&cwd).unwrap();
    let mut config = config();
    config.harnesses.get_mut("fake").unwrap().family = None;
    config.web_roots = vec![root.to_string_lossy().into_owned()];
    config.web_asking_modes.insert("fake".into(), vec!["normal".into(), "strict".into()]);
    let b = Hub::new(config, Box::new(MemoryStore::default()));
    let hook = Arc::new(MeshControlHook::new(control_allowlist(), Some(dir.path().join("c.json"))));
    let options = RelayOptions { heartbeat_every: Duration::from_secs(30), ..quick() };
    let relay = MeshRelay::start(&b, fake.clone(), hook, options);
    fake.until("B's first heartbeat", |s| !s.heartbeats.is_empty()).await;
    let beats = fake.with(|s| s.heartbeats.len());

    let sender = MeshControlRelay::new(fake.clone(), Sender::default());
    let params = json!({"cwd": cwd, "mcpServers": [],
        "_meta":{"acpmux":{"harness":"fake", "name":"own-e2e", "policy":"ask"}}});
    let start = ControlRequest::new(
        Recipient::Daemon { daemon_id: "inst_b".into() },
        ControlCommand::Start { params: params.as_object().unwrap().clone() },
        "start-own-e2e".into(),
    )
    .unwrap();
    let receipt = submit(&sender, &start).await.unwrap();
    fake.until("start ack", |s| !s.acked(&receipt.message_id).is_empty()).await;
    assert_eq!(fake.with(|s| s.acked(&receipt.message_id)[0].state), AckState::Delivered);
    // By the ack the hub has heard of it, long before the 30 s timer.
    fake.with(|s| {
        assert!(s.heartbeats.len() > beats, "no heartbeat after the start");
        assert!(
            s.heartbeats.last().unwrap().sessions.iter().any(|r| r.name == "own-e2e"),
            "the last heartbeat does not list the new session"
        );
    });

    // A's waiting send by name goes through the hub and reaches it.
    let a = hub();
    let _ = a.mesh.set(fake.clone());
    let queued = Client::local(&a)
        .call("_acpmux/send_queue", send_queue("own-e2e-b/own-e2e", "prompt-own-e2e-1"))
        .await;
    let delivery = queued.pointer("/result/deliveryId").and_then(Value::as_str);
    assert!(delivery.is_some_and(|d| d.starts_with("mesh:msg_")), "{queued}");
    let message = delivery.unwrap().trim_start_matches("mesh:").to_owned();
    fake.until("delivered", |s| s.receipts[&message].state == "delivered").await;
    relay.stop().await;
    b.shutdown_all().await;
}

#[cfg(target_os = "linux")]
#[tokio::test]
async fn only_a_same_person_mesh_start_gets_the_full_access_host_profile() {
    let dir = tempfile::tempdir().unwrap();
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE]}},
        "webRoots": [dir.path()], "defaultHarness": "fake", "webAskingModes": {"fake": ["normal", "strict"]},
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let hub = Hub::new(cfg, Box::new(MemoryStore::default()));
    for (name, same_person, policy, boundary, mixed_grant, user) in [
        ("own-full", true, "approve-all", None, false, Some("person-1")),
        ("own-asking", true, "ask", None, false, Some("person-1")),
        ("own-opt-out", true, "approve-all", Some(false), false, Some("person-1")),
        ("team-forged", false, "approve-all", Some(true), false, Some("person-2")),
        ("mixed-other", false, "approve-all", Some(true), true, Some("person-2")),
        ("mixed-missing", false, "approve-all", Some(true), true, None),
        ("mixed-empty", false, "approve-all", Some(true), true, Some("")),
        ("mixed-own", true, "approve-all", None, true, Some("person-1")),
    ] {
        let grant: MeshControlFrom = serde_json::from_value(if mixed_grant {
            json!({"sameUser": true, "daemonId": "inst_a", "ops": ["start"]})
        } else if same_person {
            json!({"sameUser": true})
        } else {
            json!({"daemonId": "inst_a", "ops": ["start"]})
        })
        .unwrap();
        let hook = MeshControlHook::new(vec![grant], Some(dir.path().join(format!("{name}.json"))))
            .with_own_user(Arc::new(|| Some("person-1".into())));
        let mut request = message(name, "", Kind::Control);
        request.from.user = user.map(str::to_owned);
        let mut body = json!({"version": 1, "params": {"cwd": dir.path(), "mcpServers": [],
            "_meta": {"acpmux": {"harness": "fake", "name": name, "policy": policy,
                "via": "peer"}}}});
        if let Some(boundary) = boundary {
            body["params"]["_meta"]["acpmux"]["vmBoundary"] = json!(boundary);
        }
        request.body = body.to_string();
        let ack = hook.control(&hub, &request).await.unwrap();
        assert_eq!(ack.state, AckState::Delivered, "{name}: {ack:?}");
        let session = hub.resolve(ack.detail.as_deref().unwrap()).unwrap();
        assert_eq!(
            session.meta().vm_boundary,
            same_person && policy == "approve-all" && boundary != Some(false),
            "{name}"
        );
    }
    hub.shutdown_all().await;
}

/// A relayed start runs under the owner's grant for its sender (`maxPolicy`): an entry without one
/// holds an approve-all start to `ask` as a remote chain, and only an entry granting approve-all
/// (what `host join` writes for the person's own machines) starts this machine's own chat in the
/// policy it names (cmux#50026).
#[tokio::test]
async fn a_relayed_start_runs_under_the_senders_max_policy() {
    let dir = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(dir.path()).unwrap();
    let cwd = root.join("project");
    std::fs::create_dir(&cwd).unwrap();
    let mut config = config();
    config.harnesses.get_mut("fake").unwrap().family = None;
    config.web_roots = vec![root.to_string_lossy().into_owned()];
    config.web_asking_modes.insert("fake".into(), vec!["normal".into(), "strict".into()]);
    let hub = Hub::new(config, Box::new(MemoryStore::default()));
    let start = |id: &str| {
        let mut request = message(id, "", Kind::Control);
        request.body = json!({"version": 1, "params": {"cwd": cwd, "mcpServers": [],
            "_meta": {"acpmux": {"harness": "fake", "name": id, "policy": "approve-all"}}}})
        .to_string();
        request
    };
    let entry = |extra: Value| {
        let mut entry = json!({"daemonId": "inst_a"});
        entry.as_object_mut().unwrap().extend(extra.as_object().unwrap().clone());
        serde_json::from_value::<MeshControlFrom>(entry).unwrap()
    };
    for (id, extra, policy, remote) in [
        ("capped-default", json!({}), "ask", true),
        ("capped-edits", json!({"maxPolicy": "approve-edits"}), "approve-edits", true),
        ("owner-grant", json!({"maxPolicy": "approve-all"}), "approve-all", false),
    ] {
        let hook =
            MeshControlHook::new(vec![entry(extra)], Some(dir.path().join(format!("{id}.json"))));
        let ack = hook.control(&hub, &start(id)).await.unwrap();
        assert_eq!(ack.state, AckState::Delivered, "{id}: {ack:?}");
        let meta = hub.resolve(id).unwrap().meta();
        assert_eq!(meta.permission_policy.as_deref(), Some(policy), "{id}");
        assert_eq!(meta.remote_origin, remote, "{id}");
    }
    hub.shutdown_all().await;
}

//! A client's `$/cancel_request` across a real peer link (`peer.rs`, `request_cancel.rs`): two
//! hubs in this process, B serving WebSocket and A mirroring B as peer `b`. A client on A asks
//! `_acpmux/info` of `b/lane`; A forwards it to B, whose handler stalls on a hold
//! (`Hub::hold_requests_for_tests`, never timing).
//!
//! - A peer that lists `cancelRequestV2`: the client gets exactly one -32800; A's pending entry
//!   on the link and its own request slot go at once; B hears the cancel on the link and frees its
//!   slot and its stalled work; B's own -32800, which reaches A after A answered, is dropped and
//!   logged on `acpmux::cancel`; the request not cancelled is answered once B lets it go; the
//!   client hears nothing more.
//! - An older peer (one that never listed `cancelRequestV2`): no cancel frame goes on the link,
//!   while A still answers -32800 and frees its own side. When B's stalled work later finishes,
//!   its late answer is dropped at A with the `acpmux::cancel` log, and the client hears nothing
//!   more.
//!
//! - Dual send (review F1 of #41285, `server/dual_requests.rs`): a link whose path is in doubt
//!   sends a request on its path and a copy on a shadow path, one `dualId` on both. The shadow's
//!   copy reaches B first and runs; the link's copy waits on it; the cancel comes on the link
//!   only. Whichever copy runs is stopped, the other never runs, each connection gets one
//!   -32800, and both entries are freed.
//!
//! The first test function sets this process's tracing subscriber, and both of its scenarios
//! read it; the dual-send test reads no log.

// Unix only until the Windows port runs the daemon (cmux::local_socket).
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, HarnessProfile, PermissionPolicy, StoreMode};
use acpmux::hub::{Hub, RequestStage};
use acpmux::rpc::{Message, method};
use acpmux::server::peer_auth::PeerAuth;
use acpmux::server::{WsAuth, bind_ws, serve_connection, serve_ws_with};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::{Semaphore, mpsc};

const WAIT: Duration = Duration::from_secs(30);
/// JSON-RPC's RequestCancelled (LSP).
const REQUEST_CANCELLED: i64 = -32800;
const PERSON_KEY: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

/// Both daemons' log lines, as this process's subscriber writes them.
#[derive(Clone, Default)]
struct Captured(Arc<Mutex<Vec<u8>>>);

impl std::io::Write for Captured {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(buf);
        Ok(buf.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl Captured {
    fn install() -> Self {
        let captured = Self::default();
        let writer = captured.clone();
        let subscriber = tracing_subscriber::fmt()
            .with_env_filter(tracing_subscriber::EnvFilter::new("acpmux::cancel=debug"))
            .with_ansi(false)
            .with_writer(move || writer.clone())
            .finish();
        tracing::subscriber::set_global_default(subscriber).unwrap();
        captured
    }

    /// The late answers A dropped so far (from its peer link).
    fn dropped_late(&self) -> Vec<String> {
        let text = String::from_utf8_lossy(&self.0.lock().unwrap()).into_owned();
        text.lines()
            .filter(|l| l.contains("dropped the late answer to a cancelled request"))
            .filter(|l| l.contains("from=\"peer\"") || l.contains("from=peer"))
            .map(str::to_owned)
            .collect()
    }

    /// Waits (bounded) until `n` late answers were dropped; what was dropped then.
    async fn until_dropped(&self, n: usize) -> Vec<String> {
        let deadline = tokio::time::Instant::now() + WAIT;
        while self.dropped_late().len() < n && tokio::time::Instant::now() < deadline {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        self.dropped_late()
    }
}

/// B's hold: the first `left` `_acpmux/info` requests it serves stall until the test lets them
/// go; later ones (the test's round trips) pass.
struct Stall {
    left: AtomicUsize,
    /// Stalled requests B still serves: one leaves when it is let go or dropped by a cancel.
    active: Arc<AtomicUsize>,
    reached: Semaphore,
    release: Semaphore,
}

/// Counts a stalled request in [`Stall::active`] while B serves it.
struct Serving(Arc<AtomicUsize>);

impl Drop for Serving {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::SeqCst);
    }
}

fn hub() -> Arc<Hub> {
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
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

type Held = std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>>;

/// A client connection: every answer it got, by id, in order.
struct Client {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    answers: Vec<Value>,
}

impl Client {
    async fn connect(h: Arc<Hub>) -> Self {
        let _ = h.person.install_spawn_key(PERSON_KEY);
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection(h, in_rx, out_tx));
        let mut c = Self { tx: in_tx, rx: out_rx, answers: Vec::new() };
        let hello = json!({"protocolVersion": 1, "clientInfo": {"name": "t"}});
        let init = c.call(1, method::INITIALIZE, hello).await;
        let challenge = &init["result"]["_meta"]["acpmux"]["personChallenge"];
        let proof = acpmux::hub::person::person_proof(
            PERSON_KEY,
            acpmux::hub::person::TRANSPORT_UNIX,
            challenge["nonce"].as_str().unwrap(),
            challenge["connection"].as_str().unwrap(),
        )
        .unwrap();
        let proved = c.call(2, "_acpmux/person_prove", json!({"proof": proof})).await;
        assert!(proved.get("error").is_none(), "{proved}");
        c
    }

    async fn send(&self, msg: Message) {
        self.tx.send(msg.to_line()).await.unwrap();
    }

    async fn cancel(&self, id: i64) {
        self.send(Message::notification("$/cancel_request", json!({"requestId": id}))).await;
    }

    /// Reads what came within `within` into `answers` (notifications are left out); false once
    /// nothing more came.
    async fn read(&mut self, within: Duration) -> bool {
        let Ok(Some(line)) = tokio::time::timeout(within, self.rx.recv()).await else {
            return false;
        };
        let v: Value = serde_json::from_str(&line).unwrap();
        if v.get("id").is_some() && v.get("method").is_none() {
            self.answers.push(v);
        }
        true
    }

    /// Every answer to `id` so far.
    fn answers_to(&self, id: i64) -> Vec<Value> {
        self.answers.iter().filter(|v| v["id"] == json!(id)).cloned().collect()
    }

    /// The first answer to `id`, waiting for it.
    async fn answer(&mut self, id: i64) -> Value {
        let deadline = tokio::time::Instant::now() + WAIT;
        while self.answers_to(id).is_empty() {
            let left = deadline.saturating_duration_since(tokio::time::Instant::now());
            assert!(self.read(left).await, "no answer to {id}; answers so far {:#?}", self.answers);
        }
        self.answers_to(id).remove(0)
    }

    async fn call(&mut self, id: i64, m: &str, params: Value) -> Value {
        self.send(Message::request(id, m, params)).await;
        self.answer(id).await
    }

    /// Reads until nothing more comes for `quiet`.
    async fn drain(&mut self, quiet: Duration) {
        while self.read(quiet).await {}
    }
}

struct Scratch(PathBuf);

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

struct Pair {
    a: Arc<Hub>,
    b: Arc<Hub>,
    stall: Arc<Stall>,
    _scratch: Scratch,
}

/// B serves chat `lane` and stalls the first `stalled` `_acpmux/info` requests; A mirrors B as
/// peer `b`.
async fn pair(tag: &str, stalled: usize) -> Pair {
    let _ = HERMETIC;
    let scratch = Scratch(
        std::env::temp_dir().join(format!("amx-cancel-peer-{tag}-{}", uuid::Uuid::new_v4())),
    );
    let home = scratch.0.join("home");
    let b = hub();
    let stall = Arc::new(Stall {
        left: AtomicUsize::new(stalled),
        active: Arc::default(),
        reached: Semaphore::new(0),
        release: Semaphore::new(0),
    });
    let on_b = stall.clone();
    b.hold_requests_for_tests(Arc::new(move |stage, m: &str, _: &Value| -> Held {
        let stall = on_b.clone();
        let ours = stage == RequestStage::Dispatch
            && m == method::MUX_INFO
            && stall
                .left
                .try_update(Ordering::SeqCst, Ordering::SeqCst, |n| n.checked_sub(1))
                .is_ok();
        Box::pin(async move {
            if ours {
                stall.active.fetch_add(1, Ordering::SeqCst);
                let _serving = Serving(stall.active.clone());
                stall.reached.add_permits(1);
                stall.release.acquire().await.unwrap().forget();
            }
        })
    }));
    let auth = PeerAuth::create(&home).unwrap();
    let peer_token = std::fs::read_to_string(acpmux::server::peer_auth::token_path(&home)).unwrap();
    let l = bind_ws("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    let ws_auth = WsAuth { local_app: None, peer: Some(Arc::new(auth)) };
    tokio::spawn(serve_ws_with(b.clone(), l, "tok".into(), ws_auth));
    let mut cb = Client::connect(b.clone()).await;
    let new = cb
        .call(
            3,
            method::SESSION_NEW,
            json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": "lane"}}}),
        )
        .await;
    assert!(new.get("error").is_none(), "{new}");
    let a = hub();
    let url = format!("ws://127.0.0.1:{port}");
    a.add_peer("b", &url, Some("tok".into()), Some(peer_token), true).await.unwrap();
    let peer = a.peer_by_name("b").expect("peer b");
    let mut settled = peer.settled();
    let connected = async {
        while a.peers().into_iter().next().expect("one peer")["state"] != "connected" {
            settled.changed().await.expect("peer gone");
        }
    };
    tokio::time::timeout(Duration::from_secs(60), connected).await.expect("peer b never connected");
    Pair { a, b, stall, _scratch: scratch }
}

impl Pair {
    fn b_active(&self) -> usize {
        self.stall.active.load(Ordering::SeqCst)
    }

    /// The requests in flight on `hub` once its own handshake traffic settled (bounded).
    async fn idle(hub: &Hub) -> usize {
        let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
        while hub.requests_in_flight() > 0 && tokio::time::Instant::now() < deadline {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        hub.requests_in_flight()
    }

    fn info(&self, id: i64) -> Message {
        Message::request(id, method::MUX_INFO, json!({"sessionId": "b/lane"}))
    }

    async fn a_pending(&self) -> usize {
        self.a.peer_by_name("b").expect("peer b").pending_requests().await
    }

    /// Waits (bounded) until B's handler stalls on `n` requests.
    async fn until_stalled(&self, n: usize, client: &mut Client) {
        for _ in 0..n {
            match tokio::time::timeout(WAIT, self.stall.reached.acquire()).await {
                Ok(permit) => permit.unwrap().forget(),
                Err(_) => {
                    client.drain(Duration::from_millis(500)).await;
                    panic!("B's handler never stalled; answers on A: {:#?}", client.answers);
                }
            }
        }
    }

    /// A round trip on the link after everything A queued on it so far: B read every frame
    /// before it, in order, by the time it is answered.
    async fn round_trip(&self, client: &mut Client, id: i64) {
        let info = client.call(id, method::MUX_INFO, json!({"sessionId": "b/lane"})).await;
        assert!(info.get("error").is_none(), "{info}");
    }
}

/// Waits (bounded) until `read` gives `want`; what it gave last.
async fn until<T: PartialEq + std::fmt::Debug, F: std::future::Future<Output = T>>(
    want: T,
    mut read: impl FnMut() -> F,
) -> T {
    let deadline = tokio::time::Instant::now() + WAIT;
    loop {
        let now = read().await;
        if now == want || tokio::time::Instant::now() >= deadline {
            return now;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

fn cancelled(v: &Value) -> bool {
    v["error"]["code"] == json!(REQUEST_CANCELLED)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn cancel_peer_link_reaches_the_peer_and_spares_an_older_peer() {
    let logs = Captured::install();
    cancel_reaches_a_peer_that_takes_it(&logs).await;
    no_cancel_frame_for_an_older_peer(&logs).await;
}

async fn cancel_reaches_a_peer_that_takes_it(logs: &Captured) {
    let p = pair("v2", 3).await;
    let mut ca = Client::connect(p.a.clone()).await;
    let (a_idle, b_idle) = (Pair::idle(&p.a).await, Pair::idle(&p.b).await);
    for id in [11, 12, 13] {
        ca.send(p.info(id)).await;
    }
    p.until_stalled(3, &mut ca).await;
    assert_eq!(p.a_pending().await, 3, "A waits on B for all three");
    assert_eq!(p.a.requests_in_flight(), a_idle + 3);
    assert_eq!(p.b.requests_in_flight(), b_idle + 3);
    assert_eq!(p.b_active(), 3);

    for (n, id) in [11, 12].into_iter().enumerate() {
        ca.cancel(id).await;
        assert!(cancelled(&ca.answer(id).await), "{:?}", ca.answers_to(id));
        assert_eq!(p.a.requests_in_flight(), a_idle + 2 - n, "A's slot is free at once");
        assert_eq!(until(2 - n, || p.a_pending()).await, 2 - n, "A's pending entry is gone");
        // Any cancel frame went on the link before this round trip.
        p.round_trip(&mut ca, 20 + n as i64).await;
        assert_eq!(
            p.b.requests_in_flight(),
            b_idle + 2 - n,
            "B took the cancel and freed the slot"
        );
        assert_eq!(until(2 - n, || async { p.b_active() }).await, 2 - n, "B dropped that work");
        // B answered the cancel on the link too: late at A, dropped and logged.
        let late = logs.until_dropped(n + 1).await;
        assert_eq!(late.len(), n + 1, "{late:#?}");
        assert!(late.iter().all(|l| l.contains(method::MUX_INFO)), "{late:#?}");
    }

    // B lets its stalled work go: only the one not cancelled is still there, and is answered.
    p.stall.release.add_permits(3);
    let done = ca.answer(13).await;
    assert!(done.get("error").is_none(), "the one not cancelled is answered: {done}");
    p.round_trip(&mut ca, 30).await;
    ca.drain(Duration::from_millis(300)).await;
    for id in [11, 12, 13] {
        assert_eq!(ca.answers_to(id).len(), 1, "{id}: {:#?}", ca.answers_to(id));
    }
    assert_eq!(logs.dropped_late().len(), 2, "nothing else came late");
    assert_eq!(p.a_pending().await, 0);
    assert_eq!(p.a.requests_in_flight(), a_idle);
    assert_eq!(until(b_idle, || async { p.b.requests_in_flight() }).await, b_idle);
    eprintln!(
        "peer link: A in flight {} -> {}, B in flight {} -> {}, late answers dropped at A: {}",
        a_idle + 3,
        p.a.requests_in_flight(),
        b_idle + 3,
        p.b.requests_in_flight(),
        logs.dropped_late().len(),
    );
}

async fn no_cancel_frame_for_an_older_peer(logs: &Captured) {
    let p = pair("old", 2).await;
    let peer = p.a.peer_by_name("b").expect("peer b");
    peer.forget_feature_for_tests(acpmux::request_cancel::FEATURE);
    let mut ca = Client::connect(p.a.clone()).await;
    let (a_idle, b_idle) = (Pair::idle(&p.a).await, Pair::idle(&p.b).await);
    let late_before = logs.dropped_late().len();
    for id in [31, 32] {
        ca.send(p.info(id)).await;
    }
    p.until_stalled(2, &mut ca).await;
    assert_eq!(p.a_pending().await, 2);

    ca.cancel(31).await;
    assert!(cancelled(&ca.answer(31).await), "{:?}", ca.answers_to(31));
    assert_eq!(p.a.requests_in_flight(), a_idle + 1, "A's slot is free at once");
    assert_eq!(until(1, || p.a_pending()).await, 1, "A's pending entry is gone");
    // Any cancel frame would have gone on the link before this round trip.
    p.round_trip(&mut ca, 40).await;
    assert_eq!(p.b.requests_in_flight(), b_idle + 2, "B heard no cancel");
    assert_eq!(p.b_active(), 2, "B still serves both");

    // B's stalled work finishes: 31's answer comes late to A, which drops and logs it.
    p.stall.release.add_permits(2);
    assert!(ca.answer(32).await.get("error").is_none());
    let late = logs.until_dropped(late_before + 1).await;
    assert_eq!(late.len(), late_before + 1, "the late answer is logged: {late:#?}");
    p.round_trip(&mut ca, 41).await;
    ca.drain(Duration::from_millis(300)).await;
    assert_eq!(ca.answers_to(31).len(), 1, "nothing more for it: {:#?}", ca.answers_to(31));
    assert_eq!(ca.answers_to(32).len(), 1, "{:#?}", ca.answers_to(32));
    assert_eq!(p.a_pending().await, 0);
    assert_eq!(until(b_idle, || async { p.b.requests_in_flight() }).await, b_idle);
}

/// One of A's two paths to B as B's listener sees it: a WebSocket that presented the peer token,
/// so B serves it as the peer principal (`dual_requests::PEER_LINK`).
type Path_ =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

async fn peer_path(port: u16, peer_token: &str) -> Path_ {
    use tokio_tungstenite::tungstenite::client::IntoClientRequest;
    let mut req = format!("ws://127.0.0.1:{port}").into_client_request().unwrap();
    req.headers_mut().insert("authorization", "Bearer tok".parse().unwrap());
    req.headers_mut().insert(acpmux::server::peer_auth::HEADER, peer_token.trim().parse().unwrap());
    tokio_tungstenite::connect_async(req).await.unwrap().0
}

async fn path_send(ws: &mut Path_, v: Value) {
    use futures_util::SinkExt;
    ws.send(tokio_tungstenite::tungstenite::Message::Text(v.to_string().into())).await.unwrap();
}

/// Every answer to `id` `ws` reads within `within`.
async fn path_answers(ws: &mut Path_, id: i64, within: Duration) -> Vec<Value> {
    use futures_util::StreamExt;
    let mut got = Vec::new();
    let deadline = tokio::time::Instant::now() + within;
    while let Ok(Some(Ok(frame))) = tokio::time::timeout_at(deadline, ws.next()).await {
        if let tokio_tungstenite::tungstenite::Message::Text(text) = frame {
            let v: Value = serde_json::from_str(text.as_str()).unwrap();
            if v.get("method").is_none() && v["id"] == json!(id) {
                got.push(v);
            }
        }
    }
    got
}

/// The first answer to `id` on `ws`, waiting at most `within`.
async fn path_answer(ws: &mut Path_, id: i64, within: Duration) -> Option<Value> {
    use futures_util::StreamExt;
    let deadline = tokio::time::Instant::now() + within;
    while let Ok(Some(Ok(frame))) = tokio::time::timeout_at(deadline, ws.next()).await {
        if let tokio_tungstenite::tungstenite::Message::Text(text) = frame {
            let v: Value = serde_json::from_str(text.as_str()).unwrap();
            if v.get("method").is_none() && v["id"] == json!(id) {
                return Some(v);
            }
        }
    }
    None
}

/// Review F1 of #41285. A's link to B is in doubt, so A sends `_acpmux/stats` (one of the
/// requests sent on two paths, `dual_requests::METHODS`) on the link and a copy on the shadow,
/// both with id 7 and one `dualId`, as `peer_dual.rs` writes them. The shadow's copy reaches B
/// first and stalls in B's handler (a hold, never timing); the link's copy then waits on it.
/// The client cancels: A sends `$/cancel_request` on the link. B must stop the copy that runs
/// (on the other connection), so the stalled work never goes on, and each connection gets
/// exactly one answer, -32800. Both entries are freed. Then the other order: the link's copy
/// runs and is cancelled, and the shadow's copy, arriving after, never starts.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_cancel_stops_the_dual_copy_that_runs_and_the_other_never_starts() {
    let _ = HERMETIC;
    let scratch =
        Scratch(std::env::temp_dir().join(format!("amx-cancel-dual-{}", uuid::Uuid::new_v4())));
    let home = scratch.0.join("home");
    let b = hub();
    // B's handler: every `_acpmux/stats` stalls for good; `ran` counts the copies that reached
    // it, `active` those still stalled there (one leaves when a cancel drops it).
    let ran = Arc::new(AtomicUsize::new(0));
    let active = Arc::new(AtomicUsize::new(0));
    let reached = Arc::new(Semaphore::new(0));
    let (on_ran, on_active, on_reached) = (ran.clone(), active.clone(), reached.clone());
    b.hold_requests_for_tests(Arc::new(move |stage, m: &str, _: &Value| -> Held {
        let ours = stage == RequestStage::Dispatch && m == method::MUX_STATS;
        let (ran, active, reached) = (on_ran.clone(), on_active.clone(), on_reached.clone());
        Box::pin(async move {
            if ours {
                active.fetch_add(1, Ordering::SeqCst);
                let _serving = Serving(active.clone());
                ran.fetch_add(1, Ordering::SeqCst);
                reached.add_permits(1);
                std::future::pending::<()>().await;
            }
        })
    }));
    let auth = PeerAuth::create(&home).unwrap();
    let peer_token = std::fs::read_to_string(acpmux::server::peer_auth::token_path(&home)).unwrap();
    let l = bind_ws("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    let ws_auth = WsAuth { local_app: None, peer: Some(Arc::new(auth)) };
    tokio::spawn(serve_ws_with(b.clone(), l, "tok".into(), ws_auth));
    let mut link = peer_path(port, &peer_token).await;
    let mut shadow = peer_path(port, &peer_token).await;
    let b_idle = Pair::idle(&b).await;
    let stats = |id: i64, dual: &str| {
        json!({"jsonrpc": "2.0", "id": id, "method": method::MUX_STATS,
            "params": {"_meta": {"acpmux": {"dualId": dual}}}})
    };
    let cancel = |id: i64| json!({"jsonrpc": "2.0", "method": method::CANCEL_REQUEST, "params": {"requestId": id}});
    let quiet = Duration::from_millis(500);

    // The shadow's copy first: it runs, and stalls in B's handler.
    let dual = format!("n:1:{}", uuid::Uuid::now_v7());
    path_send(&mut shadow, stats(7, &dual)).await;
    tokio::time::timeout(WAIT, reached.acquire())
        .await
        .expect("B ran the shadow's copy")
        .unwrap()
        .forget();
    // The link's copy: a repeat, waiting on the shadow's. Then the cancel, on the link only.
    path_send(&mut link, stats(7, &dual)).await;
    path_send(&mut link, cancel(7)).await;
    let on_link = path_answer(&mut link, 7, WAIT).await.expect("the link's copy is answered");
    assert!(cancelled(&on_link), "{on_link}");
    let on_shadow = path_answer(&mut shadow, 7, Duration::from_secs(10)).await;
    assert!(
        on_shadow.as_ref().is_some_and(cancelled),
        "the copy that ran is stopped and answered -32800 on its own connection: {on_shadow:?}"
    );
    assert_eq!(until(0, || async { active.load(Ordering::SeqCst) }).await, 0, "its work dropped");
    assert!(path_answers(&mut link, 7, quiet).await.is_empty(), "one answer on the link");
    assert!(path_answers(&mut shadow, 7, quiet).await.is_empty(), "one answer on the shadow");
    assert_eq!(ran.load(Ordering::SeqCst), 1, "only the shadow's copy reached the handler");
    assert_eq!(until(b_idle, || async { b.requests_in_flight() }).await, b_idle, "both freed");

    // The other order: the link's copy runs and is cancelled; the shadow's, arriving after,
    // never starts.
    let dual = format!("n:1:{}", uuid::Uuid::now_v7());
    path_send(&mut link, stats(8, &dual)).await;
    tokio::time::timeout(WAIT, reached.acquire())
        .await
        .expect("B ran the link's copy")
        .unwrap()
        .forget();
    path_send(&mut link, cancel(8)).await;
    assert!(cancelled(&path_answer(&mut link, 8, WAIT).await.expect("answered")));
    path_send(&mut shadow, stats(8, &dual)).await;
    let late = path_answer(&mut shadow, 8, WAIT).await.expect("the late copy is answered");
    assert!(cancelled(&late), "the late copy takes the cancel's answer: {late}");
    assert_eq!(until(0, || async { active.load(Ordering::SeqCst) }).await, 0, "its work dropped");
    assert!(path_answers(&mut link, 8, quiet).await.is_empty());
    assert!(path_answers(&mut shadow, 8, quiet).await.is_empty());
    assert_eq!(ran.load(Ordering::SeqCst), 2, "the shadow's late copy never reached it");
    assert_eq!(until(b_idle, || async { b.requests_in_flight() }).await, b_idle);
}

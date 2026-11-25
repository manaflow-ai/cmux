//! The transport pair matrix's desktop rows (`mac-mac`, `mac-linux`): two real acpmux hubs in one
//! process, A mirroring B as peer `b`, with a chat on B (the fake agent) that A's client reads.
//!
//! Paths:
//! - `direct`: A's peer link is B's WebSocket through a `cmux_fault::shaper::Shaper` (TCP). The
//!   WireGuard path is not driven here (a follow-up; `carrier_faults.rs` has the labs route).
//! - `relay`: A's only way to B is the hub carrier through an in-process `cmux_relay::Relay`,
//!   with the shaper between A and the relay (B reaches the relay unshaped).
//!
//! Conditions (pm/DESIGN.md): `loss` (`lossy-3`), `latency` (`lte`), `handoff` (`5g-lte-handoff`,
//! an address change), `sleep` (`lte`, 60 s of 100 % loss both ways), `failover` (direct rows:
//! the direct path dies and the relay takes over), `long` (a steady chat stream held
//! `PAIRMATRIX_LONG_MINUTES`, then a 5 s blip). `loss` and `latency` are steady links; their
//! `resume_ms` is measured after a 5 s blip in the shaped link.
//!
//! Loads: `idle` (5 sessions of 20 turns, nothing streaming) and `duress` (50 sessions, the
//! measured one at 5,000 turns, and a chat streaming into it while it is measured).
//!
//! Metrics, one `PAIRCELL` JSON line each per run: `ttfc_ms` (A's peer add to A's first rows of
//! B's chat), `resume_ms` (the condition's end to the first content B sent after it reaching A's
//! client), `delta_bytes` (both ways through the shaper from the change to caught-up; `long`:
//! bytes per minute over the hold), `fail` (1: no content within 90 s, or an event lost or
//! duplicated). A failed metric is `null` with an `error`. A cell the code cannot run is one
//! `PAIRCELL-NA` line with its reason. The bench never fails the test on a slow or failed run.
//!
//! `#[ignore]`: run it with
//! `cargo test --release -p acpmux --features hub-carrier --test pair_matrix_desktop -- --ignored
//! --nocapture --test-threads 1`. Env: `PAIRMATRIX_PAIR` (mac-mac), `PAIRMATRIX_N` (5),
//! `PAIRMATRIX_SEED_BASE` (0), `PAIRMATRIX_CONDITIONS`, `PAIRMATRIX_LOADS` (idle,duress),
//! `PAIRMATRIX_PATHS` (direct,relay), `PAIRMATRIX_LONG_MINUTES` (60).
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/). It starts from a cleared
// environment, so the bench's knobs are kept by name or every run takes the defaults.
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in().keep(&[
    "PAIRMATRIX_PAIR",
    "PAIRMATRIX_N",
    "PAIRMATRIX_SEED_BASE",
    "PAIRMATRIX_CONDITIONS",
    "PAIRMATRIX_LOADS",
    "PAIRMATRIX_PATHS",
    "PAIRMATRIX_LONG_MINUTES",
]);

use acpmux::config::{Config, HarnessProfile, PermissionPolicy, StoreMode};
use acpmux::hub::Hub;
use acpmux::hub_carrier::{CarrierAnswer, HubCarrier, HubServe, Tickets, Timings};
use acpmux::rpc::{Message, method};
use acpmux::server::peer_auth::PeerAuth;
use acpmux::server::{WsAuth, bind_ws, serve_connection, serve_ws_with};
use base64::Engine;
use cmux_fault::Trace;
use cmux_fault::shaper::{LinkProfile, ProfileFile, Shaper};
use serde_json::{Value, json};
use std::collections::{BTreeMap, HashSet};
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::{mpsc, oneshot, watch};
use tokio::time::Instant;

const PERSON_KEY: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const FILE: &str = "cmux-tui/crates/acpmux/tests/pair_matrix_desktop.rs";
/// A run that never reached content in this long failed (DESIGN.md).
const CONTENT_BOUND: Duration = Duration::from_secs(90);
/// The blip a steady condition (and `long`) resumes from.
const BLIP: Duration = Duration::from_secs(5);
/// The sleep: 100 % loss both ways.
const SLEEP: Duration = Duration::from_secs(60);
/// After the resume marker arrived: time for a late duplicate to show itself.
const SETTLE: Duration = Duration::from_secs(2);

// --------------------------------------------------------------------------------- env, output

fn env_list(name: &str, default: &[&str]) -> Vec<String> {
    match std::env::var(name) {
        Ok(v) if !v.trim().is_empty() => {
            v.split(',').map(|s| s.trim().to_owned()).filter(|s| !s.is_empty()).collect()
        }
        _ => default.iter().map(|s| (*s).to_owned()).collect(),
    }
}

fn env_u64(name: &str, default: u64) -> u64 {
    std::env::var(name).ok().and_then(|v| v.trim().parse().ok()).unwrap_or(default)
}

fn pair() -> String {
    std::env::var("PAIRMATRIX_PAIR")
        .ok()
        .filter(|p| !p.trim().is_empty())
        .unwrap_or_else(|| "mac-mac".into())
}

/// The fields every line of one cell carries.
#[derive(Clone)]
struct Cell {
    path: String,
    condition: String,
    load: String,
    rig: &'static str,
}

impl Cell {
    fn base(&self) -> serde_json::Map<String, Value> {
        let mut m = serde_json::Map::new();
        m.insert("pair".into(), json!(pair()));
        m.insert("path".into(), json!(self.path));
        m.insert("condition".into(), json!(self.condition));
        m.insert("load".into(), json!(self.load));
        m
    }

    fn tail(&self, m: &mut serde_json::Map<String, Value>) {
        m.insert("host_os".into(), json!(std::env::consts::OS));
        m.insert("rig".into(), json!(format!("{FILE}::{}", self.rig)));
    }

    fn emit(&self, metric: &str, value: Option<f64>, run: u64, seed: u64, error: Option<&str>) {
        let mut m = self.base();
        m.insert("metric".into(), json!(metric));
        m.insert("value".into(), value.map_or(Value::Null, |v| json!(v)));
        m.insert("run".into(), json!(run));
        m.insert("seed".into(), json!(seed));
        self.tail(&mut m);
        if value.is_none() {
            m.insert("error".into(), json!(error.unwrap_or("no value")));
        }
        println!("PAIRCELL {}", Value::Object(m));
    }

    fn na(&self, reason: &str) {
        let mut m = self.base();
        self.tail(&mut m);
        m.insert("reason".into(), json!(reason));
        println!("PAIRCELL-NA {}", Value::Object(m));
    }
}

// ------------------------------------------------------------------------------------ the hubs

fn config() -> Config {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let profile = HarnessProfile {
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
    };
    let mut cfg = Config {
        harnesses: BTreeMap::from([("fake".to_owned(), profile)]),
        default_harness: Some("fake".into()),
        ..Default::default()
    };
    cfg.store.mode = StoreMode::Memory;
    cfg.permission_policy = PermissionPolicy::ApproveAll;
    cfg
}

fn hub() -> Arc<Hub> {
    let cfg = config();
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

/// One line a client read, kept small: a long hold reads hundreds of thousands.
struct Ev {
    at: Instant,
    /// A response's id.
    id: Option<i64>,
    result: Option<Value>,
    error: Option<Value>,
    method: Option<String>,
    seq: Option<u64>,
    chunk: Option<String>,
}

fn chunk_text(v: &Value) -> Option<String> {
    let p = v.get("params")?;
    let update = p.get("update").or_else(|| p.pointer("/msg/params/update"))?;
    (update.get("sessionUpdate")?.as_str()? == "agent_message_chunk")
        .then(|| update.pointer("/content/text")?.as_str().map(str::to_owned))
        .flatten()
}

/// A notification's journal sequence: `_acpmux/event`'s `seq` or a session update's
/// `_meta.acpmux.seq`.
fn journal_seq(m: &str, v: &Value) -> Option<u64> {
    let p = v.get("params")?;
    match m {
        method::MUX_EVENT => p.get("seq")?.as_u64(),
        method::SESSION_UPDATE => p.pointer("/_meta/acpmux/seq")?.as_u64(),
        _ => None,
    }
}

/// An in-process client of a hub. A reader task stamps every line as it arrives.
struct Client {
    tx: mpsc::Sender<String>,
    log: Arc<Mutex<Vec<Ev>>>,
    bell: Arc<watch::Sender<u64>>,
    next: i64,
}

impl Client {
    /// `notes`: keep notifications (A's client); without, only responses (B's drivers).
    async fn new(h: &Arc<Hub>, notes: bool) -> Result<Self, String> {
        let _ = h.person.install_spawn_key(PERSON_KEY);
        let (in_tx, in_rx) = mpsc::channel(256);
        let (out_tx, mut out_rx) = mpsc::channel::<String>(8192);
        tokio::spawn(serve_connection(h.clone(), in_rx, out_tx));
        let log: Arc<Mutex<Vec<Ev>>> = Arc::default();
        let bell = Arc::new(watch::channel(0u64).0);
        let (rlog, rbell) = (log.clone(), bell.clone());
        tokio::spawn(async move {
            while let Some(line) = out_rx.recv().await {
                let at = Instant::now();
                let Ok(v) = serde_json::from_str::<Value>(&line) else { continue };
                let m = v.get("method").and_then(Value::as_str).map(str::to_owned);
                let ev = match &m {
                    None => Ev {
                        at,
                        id: v.get("id").and_then(Value::as_i64),
                        result: v.get("result").cloned(),
                        error: v.get("error").cloned(),
                        method: None,
                        seq: None,
                        chunk: None,
                    },
                    Some(_) if !notes => continue,
                    Some(name) => Ev {
                        at,
                        id: None,
                        result: None,
                        error: None,
                        seq: journal_seq(name, &v),
                        chunk: chunk_text(&v),
                        method: m.clone(),
                    },
                };
                rlog.lock().unwrap().push(ev);
                rbell.send_modify(|n| *n += 1);
            }
        });
        let mut c = Self { tx: in_tx, log, bell, next: 0 };
        let hello = json!({"protocolVersion": 1, "clientInfo": {"name": "pair-matrix"}});
        let init = c.call(method::INITIALIZE, hello, Duration::from_secs(20)).await?;
        let challenge = &init["_meta"]["acpmux"]["personChallenge"];
        let proof = acpmux::hub::person::person_proof(
            PERSON_KEY,
            acpmux::hub::person::TRANSPORT_UNIX,
            challenge["nonce"].as_str().unwrap_or_default(),
            challenge["connection"].as_str().unwrap_or_default(),
        )
        .ok_or_else(|| "person proof: no key".to_string())?;
        c.call("_acpmux/person_prove", json!({"proof": proof}), Duration::from_secs(20)).await?;
        Ok(c)
    }

    async fn send(&mut self, m: &str, p: Value) -> i64 {
        self.next += 1;
        let _ = self.tx.send(Message::request(self.next, m, p).to_line()).await;
        self.next
    }

    fn len(&self) -> usize {
        self.log.lock().unwrap().len()
    }

    /// The first line from `from` on that `f` picks, with its index and arrival.
    async fn find<T>(
        &self,
        from: usize,
        bound: Duration,
        f: impl Fn(&Ev) -> Option<T>,
    ) -> Option<(usize, Instant, T)> {
        let deadline = Instant::now() + bound;
        let mut bell = self.bell.subscribe();
        let mut i = from;
        loop {
            let _ = bell.borrow_and_update();
            {
                let log = self.log.lock().unwrap();
                while i < log.len() {
                    if let Some(t) = f(&log[i]) {
                        return Some((i, log[i].at, t));
                    }
                    i += 1;
                }
            }
            let left = deadline.checked_duration_since(Instant::now())?;
            match tokio::time::timeout(left, bell.changed()).await {
                Ok(Ok(())) => {}
                _ => return None,
            }
        }
    }

    async fn reply(&self, id: i64, bound: Duration) -> Result<Value, String> {
        let got = self
            .find(0, bound, |e| {
                (e.method.is_none() && e.id == Some(id))
                    .then(|| (e.result.clone(), e.error.clone()))
            })
            .await;
        match got {
            None => Err(format!("no answer within {} s", bound.as_secs())),
            Some((_, _, (_, Some(error)))) => Err(error.to_string()),
            Some((_, _, (result, None))) => Ok(result.unwrap_or(Value::Null)),
        }
    }

    async fn call(&mut self, m: &str, p: Value, bound: Duration) -> Result<Value, String> {
        let id = self.send(m, p).await;
        self.reply(id, bound).await.map_err(|e| format!("{m}: {e}"))
    }
}

fn prompt(session: &str, text: &str) -> Value {
    json!({"sessionId": session, "prompt": [{"type": "text", "text": text}]})
}

// ------------------------------------------------------------------------------------- B's side

/// What the B driver is asked to do: send `text` as a turn into the measured session.
type Mark = (String, oneshot::Sender<()>);

/// The stream a load runs into the measured session: one `chunks: N` turn every `every`.
#[derive(Clone, Copy)]
struct Stream {
    every: Duration,
    chunks: u32,
}

/// B: one per load, reused by every path, condition and run (the same seeds for both loads).
struct World {
    load: String,
    b: Arc<Hub>,
    _home: daemon_env::Scratch,
    b_ws: SocketAddr,
    peer_token: String,
    key_a: [u8; 32],
    key_b: [u8; 32],
    relay: SocketAddr,
    _serving: HubServe,
    marks: mpsc::Sender<Mark>,
    stream: Arc<Mutex<Option<Stream>>>,
}

/// The platform's answers for one slot, as `POST /v1/mesh/carrier` gives them.
struct FixedTickets {
    relay: String,
    peers: Vec<String>,
}

#[async_trait::async_trait]
impl Tickets for FixedTickets {
    async fn register(&self) -> Result<CarrierAnswer, String> {
        serde_json::from_value(json!({
            "relay": self.relay, "slot": "own-machine-slot-b", "ticket": "open-register",
            "expires_at": 0, "peers": self.peers,
        }))
        .map_err(|e| e.to_string())
    }

    async fn connect(&self, peer: &str) -> Result<CarrierAnswer, String> {
        if !self.peers.iter().any(|k| k == peer) {
            return Err("machine.not_found".into());
        }
        serde_json::from_value(json!({
            "relay": self.relay, "slot": "own-machine-slot-b", "ticket": "open-connect",
            "expires_at": 0, "peer_key": peer,
        }))
        .map_err(|e| e.to_string())
    }
}

fn random_key() -> [u8; 32] {
    let mut key = [0u8; 32];
    getrandom::fill(&mut key).unwrap();
    key
}

fn public(key: &[u8; 32]) -> String {
    let secret = x25519_dalek::StaticSecret::from(*key);
    base64::engine::general_purpose::STANDARD
        .encode(x25519_dalek::PublicKey::from(&secret).as_bytes())
}

fn timings() -> Timings {
    Timings {
        control: Duration::from_secs(5),
        handshake: Duration::from_secs(5),
        ..Timings::default()
    }
}

async fn new_session(c: &mut Client, name: &str) -> String {
    let p = json!({"cwd": std::env::temp_dir(), "mcpServers": [],
        "_meta": {"acpmux": {"name": name}}});
    let s = c.call(method::SESSION_NEW, p, Duration::from_secs(60)).await.unwrap();
    s["sessionId"].as_str().unwrap().to_owned()
}

/// `turns` sequential turns of about 1 KB each (the seeding `mobile_link_conditions.rs` uses).
async fn seed(c: &mut Client, session: &str, turns: u64) {
    let pad = "lorem ipsum dolor sit amet ".repeat(37);
    let started = Instant::now();
    for n in 0..turns {
        if n > 0 && n % 1000 == 0 {
            eprintln!("pairmatrix: seeding {session} turn {n}/{turns}, {:?}", started.elapsed());
        }
        c.call(method::SESSION_PROMPT, prompt(session, &format!("turn {n}: {pad}")), BOUND_TURN)
            .await
            .unwrap_or_else(|e| panic!("seed turn {n}: {e}"));
    }
}

const BOUND_TURN: Duration = Duration::from_secs(60);

async fn world(load: &str) -> World {
    let (sessions, lane_turns, other_turns) = match load {
        "idle" => (5, 20, 20),
        "duress" => (50, 5_000, 20),
        other => panic!("unknown load {other}"),
    };
    let started = Instant::now();
    let home = daemon_env::Scratch::new("pairmatrix-b");
    let auth = PeerAuth::create(home.path()).unwrap();
    let peer_token =
        std::fs::read_to_string(acpmux::server::peer_auth::token_path(home.path())).unwrap();
    let b = hub();
    let l = bind_ws("127.0.0.1:0").await.unwrap();
    let b_ws = l.local_addr().unwrap();
    let ws_auth = WsAuth { local_app: None, peer: Some(Arc::new(auth)) };
    tokio::spawn(serve_ws_with(b.clone(), l, "tok".into(), ws_auth));

    // The relay, open, in process; B registers on it unshaped and stays for the whole load.
    let relay_listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let relay_addr = relay_listener.local_addr().unwrap();
    let relay = cmux_relay::Relay::new(cmux_relay::RelayConfig {
        allow_open: true,
        ..cmux_relay::RelayConfig::default()
    })
    .unwrap();
    let (relay_listener, router) = relay.server_parts(relay_listener);
    tokio::spawn(async move {
        let _ = axum::serve(relay_listener, router).await;
    });
    let (key_a, key_b) = (random_key(), random_key());
    let tickets_b = Arc::new(FixedTickets {
        relay: format!("relay+ws://{relay_addr}"),
        peers: vec![public(&key_a)],
    });
    let carrier_b = HubCarrier::new(tickets_b, key_b, timings());
    let serving = carrier_b.serve(b_ws);

    // The sessions: `lane` is the measured one; the rest seed in parallel with it.
    let mut c = Client::new(&b, false).await.unwrap();
    let lane = new_session(&mut c, "lane").await;
    let mut others = Vec::new();
    for i in 1..sessions {
        let b = b.clone();
        others.push(tokio::spawn(async move {
            let mut c = Client::new(&b, false).await.unwrap();
            let id = new_session(&mut c, &format!("s{i}")).await;
            seed(&mut c, &id, other_turns).await;
        }));
    }
    seed(&mut c, &lane, lane_turns).await;
    for o in others {
        o.await.unwrap();
    }
    eprintln!(
        "pairmatrix: B {load}: {sessions} sessions, lane {lane_turns} turns, ready in {:?}",
        started.elapsed()
    );

    // The driver: one turn at a time into `lane`, marks first, the load's stream between them.
    let (marks, mut rx) = mpsc::channel::<Mark>(64);
    let stream: Arc<Mutex<Option<Stream>>> = Arc::default();
    let s = stream.clone();
    tokio::spawn(async move {
        loop {
            let streaming = *s.lock().unwrap();
            // The world is gone once its sender is: the driver ends with it.
            let mark = match streaming {
                None => match rx.recv().await {
                    Some(m) => Some(m),
                    None => return,
                },
                Some(st) => match tokio::time::timeout(st.every, rx.recv()).await {
                    Ok(Some(m)) => Some(m),
                    Ok(None) => return,
                    Err(_) => None,
                },
            };
            let text = match &mark {
                Some((text, _)) => text.clone(),
                None => match *s.lock().unwrap() {
                    Some(st) => format!("chunks: {}", st.chunks),
                    None => continue,
                },
            };
            if let Err(e) = c.call(method::SESSION_PROMPT, prompt(&lane, &text), BOUND_TURN).await {
                eprintln!("pairmatrix: B turn {text:?} failed: {e}");
            }
            if let Some((_, done)) = mark {
                let _ = done.send(());
            }
        }
    });
    if load == "duress" {
        // A chat streams into the measured session while it is measured.
        *stream.lock().unwrap() = Some(Stream { every: Duration::from_millis(250), chunks: 20 });
    }
    World {
        load: load.into(),
        b,
        _home: home,
        b_ws,
        peer_token,
        key_a,
        key_b,
        relay: relay_addr,
        _serving: serving,
        marks,
        stream,
    }
}

impl World {
    /// A turn into `lane` that echoes `text`; returns when it is queued (not answered).
    async fn mark(&self, text: &str) {
        let (done, _) = oneshot::channel();
        let _ = self.marks.send((text.to_owned(), done)).await;
    }
}

// ------------------------------------------------------------------------------------- A's side

fn profiles() -> ProfileFile {
    ProfileFile::builtin()
}

fn profile(name: &str) -> LinkProfile {
    profiles().get(name).unwrap_or_else(|| panic!("no profile {name}")).clone()
}

fn condition_profile(condition: &str) -> &'static str {
    match condition {
        "loss" => "lossy-3",
        "handoff" => "5g-lte-handoff",
        _ => "lte",
    }
}

/// A, mirroring B, for one run.
struct Side {
    a: Arc<Hub>,
    /// The shaped link the condition hits (direct: A to B's WebSocket; relay: A to the relay).
    link: Shaper,
    /// Failover's second path: A to the relay, shaped too.
    relay_link: Option<Shaper>,
    _carrier: Option<Arc<HubCarrier>>,
}

impl Side {
    fn bytes(&self) -> u64 {
        let c = self.link.counters();
        let r = self.relay_link.as_ref().map(|s| s.counters());
        c.up_bytes + c.down_bytes + r.map_or(0, |r| r.up_bytes + r.down_bytes)
    }

    fn reset(&self) {
        self.link.reset_counters();
        if let Some(r) = &self.relay_link {
            r.reset_counters();
        }
    }

    fn row(&self) -> Value {
        self.a.peers().into_iter().next().unwrap_or(Value::Null)
    }
}

/// Builds A's links and adds peer `b`; returns before the peer connects.
async fn side(
    w: &World,
    path: &str,
    condition: &str,
    seed: u64,
) -> Result<(Side, Instant), String> {
    let trace = Trace::new();
    let shaped = profile(condition_profile(condition));
    let a = hub();
    let io = |e: std::io::Error| e.to_string();
    let relay_route = |s: &Shaper| format!("relay+ws://{}", s.addr());
    let carrier = |route: String| {
        let tickets = Arc::new(FixedTickets { relay: route, peers: vec![public(&w.key_b)] });
        let carrier = HubCarrier::new(tickets, w.key_a, timings());
        carrier.set_route("b", &public(&w.key_b));
        a.hub_carrier.set(carrier.clone());
        carrier
    };
    let (link, relay_link, kept, url) = match (path, condition) {
        ("direct", "failover") => {
            let link = Shaper::start(w.b_ws, shaped.clone(), seed, &trace).await.map_err(io)?;
            let r = Shaper::start(w.relay, shaped, seed ^ 0x5E1A_7000, &trace).await.map_err(io)?;
            let kept = carrier(relay_route(&r));
            let url = format!("ws://{}", link.addr());
            (link, Some(r), Some(kept), url)
        }
        ("direct", _) => {
            let link = Shaper::start(w.b_ws, shaped, seed, &trace).await.map_err(io)?;
            let url = format!("ws://{}", link.addr());
            (link, None, None, url)
        }
        ("relay", _) => {
            let link = Shaper::start(w.relay, shaped, seed, &trace).await.map_err(io)?;
            let kept = carrier(relay_route(&link));
            // A URL nothing listens on: the carrier is A's only way to B.
            let dead =
                std::net::TcpListener::bind("127.0.0.1:0").map_err(io)?.local_addr().map_err(io)?;
            (link, None, Some(kept), format!("ws://{dead}"))
        }
        (other, _) => return Err(format!("unknown path {other}")),
    };
    let t0 = Instant::now();
    a.add_peer("b", &url, Some("tok".into()), Some(w.peer_token.clone()), false)
        .await
        .map_err(|e| format!("add_peer: {e:?}"))?;
    Ok((Side { a, link, relay_link, _carrier: kept }, t0))
}

/// A's client attached to `b/lane` with its first rows, and when they arrived. A fresh client
/// per attempt, so a retry never leaves a second subscription behind.
async fn first_rows(a: &Arc<Hub>, deadline: Instant) -> Result<(Client, Instant), String> {
    let mut last = String::from("never tried");
    while Instant::now() < deadline {
        let mut c = Client::new(a, true).await?;
        let left = deadline.saturating_duration_since(Instant::now()).min(Duration::from_secs(20));
        let p = json!({"session": "b/lane", "limit": 100});
        match c.call(method::MUX_ATTACH, p, left).await {
            Ok(v) if v["events"].as_array().is_some_and(|e| !e.is_empty()) => {
                return Ok((c, Instant::now()));
            }
            Ok(v) => last = format!("attach answered no rows: {}", trunc(&v.to_string())),
            Err(e) => last = e,
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    Err(format!("no rows of B's chat within {} s: {last}", CONTENT_BOUND.as_secs()))
}

fn trunc(s: &str) -> String {
    s.chars().take(200).collect()
}

/// When A's client saw the echo of `text` (sent from `from` on).
async fn echo_at(c: &Client, from: usize, text: &str, bound: Duration) -> Option<Instant> {
    let want = format!("echo: {text}");
    c.find(from, bound, |e| (e.chunk.as_deref() == Some(want.as_str())).then_some(()))
        .await
        .map(|(_, at, ())| at)
}

/// Exactly once: each mark's echo once, and no journal event twice on A's client.
fn exactly_once(c: &Client, marks: &[String]) -> Result<(), String> {
    let log = c.log.lock().unwrap();
    for m in marks {
        let want = format!("echo: {m}");
        let n = log.iter().filter(|e| e.chunk.as_deref() == Some(want.as_str())).count();
        if n != 1 {
            return Err(format!("mark {m} reached A's client {n} times"));
        }
    }
    let mut seen = HashSet::new();
    for e in log.iter() {
        if let (Some(m), Some(seq)) = (&e.method, e.seq)
            && !seen.insert((m.clone(), seq))
        {
            return Err(format!("{m} seq {seq} reached A's client twice"));
        }
    }
    Ok(())
}

/// One run's numbers; `None` with the run's error.
#[derive(Default)]
struct Numbers {
    ttfc_ms: Option<f64>,
    resume_ms: Option<f64>,
    delta_bytes: Option<f64>,
    error: Option<String>,
}

fn ms(d: Duration) -> f64 {
    (d.as_secs_f64() * 10_000.0).round() / 10.0
}

async fn until<F: Fn(&Value) -> bool>(s: &Side, bound: Duration, f: F) -> bool {
    let deadline = Instant::now() + bound;
    while Instant::now() < deadline {
        if f(&s.row()) {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    false
}

async fn run(
    w: &World,
    path: &str,
    condition: &str,
    run: u64,
    seed: u64,
    hold: Duration,
) -> Numbers {
    let mut n = Numbers::default();
    let tag = format!("pm-{path}-{condition}-{}-{run}", w.load);
    let (s, t0) = match side(w, path, condition, seed).await {
        Ok(v) => v,
        Err(e) => {
            n.error = Some(e);
            return n;
        }
    };
    let result = measure(w, &s, t0, path, condition, &tag, hold, &mut n).await;
    if let Err(e) = result {
        n.error = Some(e);
    }
    let _ = s.a.remove_peer("b").await;
    let _ = s.a.shutdown_all().await;
    n
}

#[allow(clippy::too_many_arguments)]
async fn measure(
    w: &World,
    s: &Side,
    t0: Instant,
    path: &str,
    condition: &str,
    tag: &str,
    hold: Duration,
    n: &mut Numbers,
) -> Result<(), String> {
    let (ca, rows) = first_rows(&s.a, t0 + CONTENT_BOUND).await?;
    n.ttfc_ms = Some(ms(rows - t0));
    let mut marks = Vec::new();

    // Live before the change: a mark sent now reaches A.
    let live = format!("{tag}-live");
    let from = ca.len();
    w.mark(&live).await;
    echo_at(&ca, from, &live, CONTENT_BOUND).await.ok_or("the live mark never reached A")?;
    marks.push(live);

    if path == "direct" && condition == "failover" {
        // The link upgrades to the direct path first (UPGRADE_AFTER 2 probes, 3 s apart).
        let on_direct = until(s, Duration::from_secs(40), |r| r["carrier"] == "direct").await;
        if !on_direct {
            return Err(format!("never on the direct path: {}", trunc(&s.row().to_string())));
        }
    }
    if condition == "long" {
        // The hold: a mark a minute, each must arrive once.
        let started = Instant::now();
        s.reset();
        let mut k = 0;
        while started.elapsed() < hold {
            tokio::time::sleep(Duration::from_secs(60).min(hold.saturating_sub(started.elapsed())))
                .await;
            let m = format!("{tag}-hold-{k}");
            w.mark(&m).await;
            marks.push(m);
            k += 1;
        }
        let minutes = started.elapsed().as_secs_f64() / 60.0;
        n.delta_bytes = Some((s.bytes() as f64 / minutes).round());
    }

    // The change.
    s.reset();
    let start = Instant::now();
    let end = match condition {
        "loss" | "latency" | "long" => s.link.blackout(BLIP),
        "sleep" => s.link.blackout(SLEEP),
        "handoff" => s.link.disrupt().ok_or("5g-lte-handoff has no disruption")?,
        // The direct path dies for good; the relay must take over.
        "failover" => {
            s.link.blackout(Duration::from_secs(3600));
            start
        }
        other => return Err(format!("unknown condition {other}")),
    };
    // A mark during the outage (the change already began): it must arrive once, later.
    if end > start + Duration::from_secs(1) {
        tokio::time::sleep(Duration::from_secs(1)).await;
        let m = format!("{tag}-during");
        w.mark(&m).await;
        marks.push(m);
    }
    tokio::time::sleep_until(end).await;
    let fresh = format!("{tag}-fresh");
    let from = ca.len();
    w.mark(&fresh).await;
    marks.push(fresh.clone());
    let at = echo_at(&ca, from, &fresh, CONTENT_BOUND).await.ok_or_else(|| {
        format!("no fresh content within {} s of the change's end", CONTENT_BOUND.as_secs())
    })?;
    n.resume_ms = Some(ms(at - end));
    if condition != "long" {
        n.delta_bytes = Some(s.bytes() as f64);
    }
    tokio::time::sleep(SETTLE).await;
    exactly_once(&ca, &marks)
}

fn emit(cell: &Cell, run: u64, seed: u64, n: &Numbers) {
    let e = n.error.as_deref();
    cell.emit("ttfc_ms", n.ttfc_ms, run, seed, e);
    cell.emit("resume_ms", n.resume_ms, run, seed, e);
    cell.emit("delta_bytes", n.delta_bytes, run, seed, e);
    cell.emit("fail", Some(if e.is_some() { 1.0 } else { 0.0 }), run, seed, None);
    if let Some(e) = e {
        eprintln!("pairmatrix: {}/{}/{} run {run}: {e}", cell.path, cell.condition, cell.load);
    }
}

/// Why a cell cannot run, `file:line` in the code under test.
fn not_applicable(path: &str, condition: &str) -> Option<&'static str> {
    match (path, condition) {
        ("relay", "failover") => Some(
            "B registers on the relay its first register ticket names and stays there for the \
             life of the serve; no code moves it to a second relay \
             (cmux-tui/crates/acpmux/src/hub_carrier.rs:1161)",
        ),
        _ => None,
    }
}

const ROW_CONDITIONS: &[&str] = &["loss", "latency", "handoff", "sleep", "failover"];

#[tokio::test(flavor = "multi_thread", worker_threads = 8)]
#[ignore = "bench: run with --ignored --nocapture (pm/DESIGN.md)"]
async fn pair_matrix_desktop_row() {
    let _ = HERMETIC;
    let runs = env_u64("PAIRMATRIX_N", 5);
    let seed_base = env_u64("PAIRMATRIX_SEED_BASE", 0);
    let conditions = env_list("PAIRMATRIX_CONDITIONS", ROW_CONDITIONS);
    let loads = env_list("PAIRMATRIX_LOADS", &["idle", "duress"]);
    let paths = env_list("PAIRMATRIX_PATHS", &["direct", "relay"]);
    let conditions: Vec<String> = conditions.into_iter().filter(|c| c != "long").collect();
    if conditions.is_empty() {
        return;
    }
    for load in &loads {
        let w = world(load).await;
        for condition in &conditions {
            for path in &paths {
                let cell = Cell {
                    path: path.clone(),
                    condition: condition.clone(),
                    load: load.clone(),
                    rig: "pair_matrix_desktop_row",
                };
                if let Some(reason) = not_applicable(path, condition) {
                    cell.na(reason);
                    continue;
                }
                for r in 0..runs {
                    let seed = seed_base + r;
                    let bound = CONTENT_BOUND * 3 + SLEEP;
                    let n = match tokio::time::timeout(
                        bound,
                        run(&w, path, condition, r, seed, Duration::ZERO),
                    )
                    .await
                    {
                        Ok(n) => n,
                        Err(_) => Numbers {
                            error: Some(format!("the run took over {} s", bound.as_secs())),
                            ..Numbers::default()
                        },
                    };
                    emit(&cell, r, seed, &n);
                }
            }
        }
        *w.stream.lock().unwrap() = None;
        let _ = w.b.shutdown_all().await;
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 8)]
#[ignore = "bench: run with --ignored --nocapture (pm/DESIGN.md)"]
async fn pair_matrix_desktop_long() {
    let _ = HERMETIC;
    // `--ignored` runs this test with the row test; hold only when `long` was asked for
    // (run 45440984721: conditions without `long` sat 38 min in this hold and timed out).
    if !env_list("PAIRMATRIX_CONDITIONS", &["long"]).iter().any(|c| c == "long") {
        return;
    }
    let minutes = env_u64("PAIRMATRIX_LONG_MINUTES", 60);
    let seed_base = env_u64("PAIRMATRIX_SEED_BASE", 0);
    let loads = env_list("PAIRMATRIX_LOADS", &["idle", "duress"]);
    let paths = env_list("PAIRMATRIX_PATHS", &["direct", "relay"]);
    let label = if minutes >= 60 { "long".to_owned() } else { format!("long-{minutes}m") };
    let hold = Duration::from_secs(minutes * 60);
    let mut worlds = Vec::new();
    for load in &loads {
        let w = world(load).await;
        // A steady chat stream for the whole hold, idle too (the condition is the stream).
        let st = if load == "idle" {
            Stream { every: Duration::from_secs(1), chunks: 5 }
        } else {
            Stream { every: Duration::from_millis(250), chunks: 20 }
        };
        *w.stream.lock().unwrap() = Some(st);
        worlds.push(Arc::new(w));
    }
    // Every (load, path) holds at once: one hold's wall time, not four.
    let mut held = Vec::new();
    for w in &worlds {
        for path in &paths {
            let (w, path, label) = (w.clone(), path.clone(), label.clone());
            held.push(tokio::spawn(async move {
                let seed = seed_base;
                let n = match tokio::time::timeout(
                    hold + CONTENT_BOUND * 3,
                    run(&w, &path, "long", 0, seed, hold),
                )
                .await
                {
                    Ok(n) => n,
                    Err(_) => {
                        Numbers { error: Some("the hold overran".into()), ..Numbers::default() }
                    }
                };
                let cell = Cell {
                    path,
                    condition: label,
                    load: w.load.clone(),
                    rig: "pair_matrix_desktop_long",
                };
                emit(&cell, 0, seed, &n);
            }));
        }
    }
    for h in held {
        let _ = h.await;
    }
}

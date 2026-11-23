//! The agent-chat leg of the mobile network-conditions bench (`scripts/measure/
//! ios-network-conditions.sh`): the iPhone app's chat open, reopen and reconnect against acpmux's
//! WebSocket through `cmux_fault::shaper::Shaper`, a seeded model of the phone's link (LTE, a 5G
//! to LTE handoff, loss, a 30 s elevator, 2G). The phone reaches acpmux through its link's
//! `acpmux` service, a splice to this loopback WebSocket (cmux-next-ios PROTOCOL.md), so the
//! shaper sits where the phone's radio does.
//!
//! The requests mirror cmux-next-ios `AcpmuxHub.swift`: `initialize` and `_acpmux/watch
//! {enabled, limit: 100}` pipelined, then `_acpmux/attach {sessionId, limit: 400, kinds,
//! eventStream, maxBytes: 128 KiB, toolOutputMaxBytes: 64 KiB}`; a prompt is `session/prompt`
//! with a `promptId`, shown as sent when its `user_message` record comes back; a reconnect
//! re-attaches with `afterSeq`. The app's link gives up after 20 s with no inbound frame
//! (keepalive pings every 15 s) and redials at once on a path change, including the path
//! coming back after a blackout.
//!
//! One chat grows to 1x (20 turns of ~1 KB answers), 10x and 100x; for each profile in
//! `NETCOND_PROFILES` (default every built-in one), scale in `NETCOND_SCALES` and run in
//! `NETCOND_RUNS` (default 5; seed = run + `NETCOND_SEED_BASE`) it prints one line per value:
//! `NETCOND {"surface":"chat","profile":"lte@1","phase":"cold","scale":"1x","metric":
//! "first_content_ms","value":123.4,"run":0,"seed":0}`. A measurement that times out prints
//! `null` and a `NETCOND-ERROR` line; it never fails the test. `#[ignore]`: run it with
//! `cargo test -p acpmux --test mobile_link_conditions -- --ignored --nocapture`.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/). It starts from a cleared
// environment, so the bench's knobs are kept by name or every run takes the defaults.
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in().keep(&[
    "NETCOND_PROFILES",
    "NETCOND_PROFILES_FILE",
    "NETCOND_SCALES",
    "NETCOND_RUNS",
    "NETCOND_SEED_BASE",
    "NETCOND_BW_PROFILE",
    "NETCOND_BW_TURNS",
    "NETCOND_BW_SECS",
    "NETCOND_BW_APPS",
]);

#[path = "support/app_ws.rs"]
mod app_ws;

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message as RpcMessage, method};
use acpmux::server::{AGENT_PANE_ORIGIN, Origin, serve_connection_with};
use cmux_fault::Trace;
use cmux_fault::shaper::{Disruption, LinkProfile, ProfileFile, Shaper};
use futures_util::stream::SplitSink;
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::collections::{HashMap, VecDeque};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;
use tokio::time::Instant;
use tokio_tungstenite::tungstenite::{Message, client::IntoClientRequest};

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

// cmux-next-ios AcpmuxHub.swift.
const PAGE_SIZE: u64 = 400;
const OPEN_BYTES: u64 = 128 * 1024;
const TOOL_OUTPUT_MAX_BYTES: u64 = 64 * 1024;
const WATCH_LIMIT: u64 = 100;
const CHAT_KINDS: &[&str] = &[
    "transcript",
    "queue_updated",
    "queue_order",
    "queue_paused",
    "queue_resumed",
    "claude.system.api_retry",
    "bookmarks",
];
const ELEVATION_CAPABILITY: &str = "elevation-cards-v1";
/// The link's keepalive: a ping every 15 s, given up after 20 s with nothing inbound.
const PING_EVERY: Duration = Duration::from_secs(15);
const GIVE_UP_AFTER: Duration = Duration::from_secs(20);
/// No wait is longer.
const BOUND: Duration = Duration::from_secs(90);
/// Turns in 1x.
const BASE_TURNS: u64 = 20;

type Ws = tokio_tungstenite::WebSocketStream<tokio::net::TcpStream>;

// ---------------------------------------------------------------------------------------------
// Output

struct Key<'a> {
    profile: &'a str,
    phase: &'a str,
    scale: &'a str,
    run: u64,
    seed: u64,
}

fn emit(k: &Key, metric: &str, value: Option<f64>) {
    let value = match value {
        Some(v) if v.fract() == 0.0 && v.abs() < 1e15 => format!("{}", v as i64),
        Some(v) => format!("{v:.1}"),
        None => "null".to_owned(),
    };
    println!(
        "NETCOND {{\"surface\":\"chat\",\"profile\":\"{}\",\"phase\":\"{}\",\"scale\":\"{}\",\"metric\":\"{metric}\",\"value\":{value},\"run\":{},\"seed\":{}}}",
        k.profile, k.phase, k.scale, k.run, k.seed
    );
}

fn emit_error(k: &Key, metric: &str, why: &str) {
    println!(
        "NETCOND-ERROR {}",
        json!({"surface": "chat", "profile": k.profile, "phase": k.phase, "scale": k.scale,
               "metric": metric, "run": k.run, "seed": k.seed, "error": why})
    );
}

fn ms(d: Duration) -> f64 {
    (d.as_secs_f64() * 10_000.0).round() / 10.0
}

fn emit_bytes(k: &Key, shaper: &Shaper) {
    let c = shaper.counters();
    emit(k, "bytes_down", Some(c.down_bytes as f64));
    emit(k, "bytes_up", Some(c.up_bytes as f64));
    emit(k, "round_trips", Some(c.up_turns as f64));
}

// ---------------------------------------------------------------------------------------------
// The phone's connection

/// One WebSocket through the shaper: what the app's `AcpmuxConnection` is.
struct Link {
    sink: SplitSink<Ws, Message>,
    /// Every inbound frame with its arrival: `None` for a ping or pong.
    rx: mpsc::UnboundedReceiver<(Instant, Option<Value>)>,
    pending: VecDeque<(Instant, Value)>,
    /// Answers that came while another was awaited: the daemon runs a connection's requests at
    /// once, so a pipelined `_acpmux/watch` may be answered before `initialize` (the app's
    /// `AcpmuxConnection` keeps them by id too, its `answered`).
    answered: HashMap<i64, (Instant, Value)>,
    next: i64,
    last_inbound: Instant,
    capabilities: Vec<String>,
    /// The `timeBreakdownVersion` the last attach reply named; a reattach sends it back so the
    /// daemon leaves out a breakdown this side already holds (the app's AcpmuxSessionSource
    /// keeps it the same way) with `omitTimeBreakdown`, since the phone draws none. `None`
    /// against a daemon that names none: nothing is sent.
    time_breakdown_version: Option<String>,
    /// Every frame either way, by message type (the bytes-per-minute bench reads it).
    tap: Arc<Tap>,
}

enum Next {
    Frame(Instant, Value),
    Silent,
    Closed,
}

impl Link {
    async fn dial(addr: std::net::SocketAddr) -> Result<Self, String> {
        let tcp =
            tokio::net::TcpStream::connect(addr).await.map_err(|e| format!("connect: {e}"))?;
        let _ = tcp.set_nodelay(true);
        let mut req = format!("ws://{addr}/").into_client_request().map_err(|e| e.to_string())?;
        req.headers_mut().insert("authorization", "Bearer tok".parse().unwrap());
        req.headers_mut().insert("origin", AGENT_PANE_ORIGIN.parse().unwrap());
        let (ws, _) = tokio_tungstenite::client_async(req, tcp)
            .await
            .map_err(|e| format!("websocket handshake: {e}"))?;
        let (sink, mut stream) = ws.split();
        let (tx, rx) = mpsc::unbounded_channel();
        let tap = Arc::new(Tap::default());
        let tapped = tap.clone();
        tokio::spawn(async move {
            while let Some(Ok(frame)) = stream.next().await {
                let now = Instant::now();
                tapped.down(&frame);
                let item = match frame {
                    Message::Text(t) => serde_json::from_str::<Value>(&t).ok(),
                    Message::Close(_) => break,
                    _ => None,
                };
                if tx.send((now, item)).is_err() {
                    break;
                }
            }
        });
        Ok(Self {
            sink,
            rx,
            pending: VecDeque::new(),
            answered: HashMap::new(),
            next: 0,
            last_inbound: Instant::now(),
            capabilities: Vec::new(),
            time_breakdown_version: None,
            tap,
        })
    }

    async fn post(&mut self, m: &str, params: Value) -> Result<i64, String> {
        self.next += 1;
        let req = json!({"jsonrpc": "2.0", "id": self.next, "method": m, "params": params});
        let text = req.to_string();
        self.tap.up(self.next, m, text.len());
        self.sink.send(Message::Text(text.into())).await.map_err(|e| format!("send {m}: {e}"))?;
        Ok(self.next)
    }

    async fn ping(&mut self) {
        self.tap.up_ping();
        let _ = self.sink.send(Message::Ping(Vec::new().into())).await;
    }

    /// The next frame from the socket (not from `pending`) before `deadline`.
    async fn frame(&mut self, deadline: Instant) -> Next {
        loop {
            match tokio::time::timeout_at(deadline, self.rx.recv()).await {
                Err(_) => return Next::Silent,
                Ok(None) => return Next::Closed,
                Ok(Some((at, item))) => {
                    self.last_inbound = at;
                    if let Some(v) = item {
                        return Next::Frame(at, v);
                    }
                }
            }
        }
    }

    /// The next notification (`pending` first) before `deadline`.
    async fn notification(&mut self, deadline: Instant) -> Next {
        if let Some((at, v)) = self.pending.pop_front() {
            return Next::Frame(at, v);
        }
        loop {
            match self.frame(deadline).await {
                Next::Frame(at, v) if v.get("method").is_some() => return Next::Frame(at, v),
                // An answer on the way waits for its `answer` read.
                Next::Frame(at, v) => {
                    if let Some(id) = v.get("id").and_then(Value::as_i64) {
                        self.answered.insert(id, (at, v));
                    }
                }
                other => return other,
            }
        }
    }

    /// The answer to `id` and when it came; notifications on the way wait in `pending`, and
    /// answers to other requests in `answered`.
    async fn answer(&mut self, id: i64, deadline: Instant) -> Result<(Instant, Value), String> {
        let answered = |at: Instant, v: Value| match v.get("error") {
            Some(e) => Err(format!("request {id}: {e}")),
            None => Ok((at, v["result"].clone())),
        };
        if let Some((at, v)) = self.answered.remove(&id) {
            return answered(at, v);
        }
        loop {
            match self.frame(deadline).await {
                Next::Frame(at, v) => {
                    if v.get("method").is_some() {
                        self.pending.push_back((at, v));
                    } else if v.get("id") == Some(&json!(id)) {
                        return answered(at, v);
                    } else if let Some(other) = v.get("id").and_then(Value::as_i64) {
                        self.answered.insert(other, (at, v));
                    }
                }
                Next::Silent => return Err(format!("no answer to request {id} in time")),
                Next::Closed => return Err(format!("closed before the answer to request {id}")),
            }
        }
    }

    fn kinds(&self) -> Value {
        let mut kinds: Vec<&str> = CHAT_KINDS.to_vec();
        if self.capabilities.iter().any(|c| c == ELEVATION_CAPABILITY) {
            kinds.extend(["elevation_request", "elevation_decision"]);
        }
        json!(kinds)
    }

    /// The app's connect: `initialize` and the first watch page together, both answered.
    async fn open(
        addr: std::net::SocketAddr,
        token: &str,
        deadline: Instant,
    ) -> Result<Self, String> {
        let mut link = tokio::time::timeout_at(deadline, Self::dial(addr))
            .await
            .map_err(|_| "connect timed out".to_owned())??;
        let init = link
            .post(
                "initialize",
                json!({"protocolVersion": 1, "clientInfo": {"name": "cmux-ios", "version": "1"},
                       "clientCapabilities": {}, "_meta": {"acpmux": {"localAppToken": token}}}),
            )
            .await?;
        let watch =
            link.post("_acpmux/watch", json!({"enabled": true, "limit": WATCH_LIMIT})).await?;
        let (_, init) = link.answer(init, deadline).await?;
        link.capabilities = init
            .pointer("/_meta/acpmux/capabilities")
            .and_then(Value::as_array)
            .map(|a| a.iter().filter_map(Value::as_str).map(str::to_owned).collect())
            .unwrap_or_default();
        link.answer(watch, deadline).await?;
        Ok(link)
    }

    /// The chat's attach; `after` for a reattach. Returns the reply's arrival and the reply.
    async fn attach(
        &mut self,
        session: &str,
        after: Option<u64>,
        deadline: Instant,
    ) -> Result<(Instant, Value), String> {
        let mut params = json!({"sessionId": session, "limit": PAGE_SIZE, "kinds": self.kinds(),
                                "eventStream": true});
        match after {
            None => {
                params["maxBytes"] = json!(OPEN_BYTES);
                params["toolOutputMaxBytes"] = json!(TOOL_OUTPUT_MAX_BYTES);
            }
            Some(after) => params["afterSeq"] = json!(after),
        }
        if let Some(v) = &self.time_breakdown_version {
            params["timeBreakdownVersion"] = json!(v);
            // As the phone does (AcpmuxHub.swift readPages): it draws no breakdown.
            params["omitTimeBreakdown"] = json!(true);
        }
        let id = self.post("_acpmux/attach", params).await?;
        let (at, reply) = self.answer(id, deadline).await?;
        if let Some(v) = reply.get("timeBreakdownVersion").and_then(Value::as_str) {
            self.time_breakdown_version = Some(v.to_owned());
        }
        Ok((at, reply))
    }
}

/// A record's seq in an `_acpmux/event` notification.
fn event_seq(v: &Value) -> Option<u64> {
    if v.get("method").and_then(Value::as_str) != Some(method::MUX_EVENT) {
        return None;
    }
    let p = &v["params"];
    ["seq", "/event/seq", "/record/seq"]
        .iter()
        .find_map(|k| if k.starts_with('/') { p.pointer(k) } else { p.get(*k) })
        .and_then(Value::as_u64)
}

fn rows(reply: &Value) -> Vec<u64> {
    reply["events"]
        .as_array()
        .map(|a| a.iter().filter_map(|e| e["seq"].as_u64()).collect())
        .unwrap_or_default()
}

// ---------------------------------------------------------------------------------------------
// The stand-in agent's chat

fn hub(home: &Path) -> Arc<Hub> {
    acpmux::config::set_home_override(home.to_path_buf());
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

/// An in-process unix-socket-like connection: seeds the chat and starts the agent's streams.
struct Control {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    next: i64,
}

impl Control {
    fn new(hub: &Arc<Hub>) -> Self {
        let (tx, in_rx) = mpsc::channel(64);
        let (out_tx, rx) = mpsc::channel(65536);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
        Self { tx, rx, next: 0 }
    }

    async fn post(&mut self, m: &str, params: Value) -> i64 {
        self.next += 1;
        self.tx.send(RpcMessage::request(self.next, m, params).to_line()).await.unwrap();
        self.next
    }

    async fn answer(&mut self, id: i64, within: Duration) -> Option<Value> {
        let deadline = Instant::now() + within;
        loop {
            let line = tokio::time::timeout_at(deadline, self.rx.recv()).await.ok()??;
            let v: Value = serde_json::from_str(&line).ok()?;
            if v.get("id") == Some(&json!(id)) && v.get("method").is_none() {
                return Some(v);
            }
        }
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        let id = self.post(m, params).await;
        self.answer(id, BOUND).await.unwrap_or_else(|| panic!("{m}: no answer in {BOUND:?}"))
    }

    async fn prompt(&mut self, session: &str, text: &str) -> i64 {
        self.post(
            method::SESSION_PROMPT,
            json!({"sessionId": session, "prompt": [{"type": "text", "text": text}]}),
        )
        .await
    }

    /// Turns of ~1 KB answers (the fake agent echoes the prompt) until the chat holds `turns`.
    async fn seed(&mut self, session: &str, from: u64, turns: u64) {
        let pad = "lorem ipsum dolor sit amet ".repeat(37);
        for n in from..turns {
            let id = self.prompt(session, &format!("turn {n}: {pad}")).await;
            let v = self.answer(id, BOUND).await.unwrap_or_else(|| panic!("seed turn {n} hung"));
            assert!(v.get("error").is_none(), "seed turn {n}: {v}");
        }
    }
}

// ---------------------------------------------------------------------------------------------
// The phases

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

/// Reads (and drops) notifications until the link has been quiet for one round trip, the
/// jitter and two retransmissions (a segment lost twice), or `deadline`.
/// Returns the newest record seq it read, so the app's held copy stays known.
async fn settle(link: &mut Link, profile: &LinkProfile, deadline: Instant) -> u64 {
    let rto = profile.rto_min_ms.max(2 * profile.rtt_ms);
    let quiet = Duration::from_millis(300.max(profile.rtt_ms + profile.jitter_ms + 3 * rto));
    let mut last = 0;
    while let Next::Frame(_, v) = link.notification((Instant::now() + quiet).min(deadline)).await {
        last = last.max(event_seq(&v).unwrap_or(0));
    }
    link.pending.clear();
    last
}

/// Duress: the agent streams (a chunk every 50 ms, about a model's token rate) while the app
/// opens the chat again on the same link; then the app's link drops and it redials with
/// `afterSeq` while the stream runs (`reconnect` first_content_ms, every profile). Returns the
/// redialed link.
#[allow(clippy::too_many_arguments)]
async fn streaming_and_redial(
    shaper: &Shaper,
    control: &mut Control,
    mut link: Link,
    token: &str,
    session: &str,
    profile: &str,
    scale: &str,
    run: u64,
    seed: u64,
) -> Option<Link> {
    let k = Key { profile, phase: "streaming", scale, run, seed };
    // Long enough for the slowest profile's two attaches; cancelled once they are measured.
    let turn = control.prompt(session, "ticking:2400:50").await;
    let deadline = Instant::now() + BOUND;
    let mut last = 0u64;
    let mut live = false;
    while let Next::Frame(_, v) = link.notification(deadline).await {
        if let Some(seq) = event_seq(&v) {
            last = last.max(seq);
            if v.to_string().contains("tick") {
                live = true;
                break;
            }
        }
    }
    let end_turn = |control: &mut Control| {
        let tx = control.tx.clone();
        let session = session.to_owned();
        async move {
            let _ = tx
                .send(
                    RpcMessage::notification(method::SESSION_CANCEL, json!({"sessionId": session}))
                        .to_line(),
                )
                .await;
        }
    };
    if !live {
        for p in ["streaming", "reconnect"] {
            let k = Key { phase: p, ..k };
            emit(&k, "first_content_ms", None);
            emit_error(&k, "first_content_ms", "the agent's stream never reached the phone");
        }
        end_turn(control).await;
        let _ = control.answer(turn, BOUND).await;
        return None;
    }
    shaper.reset_counters();
    let start = Instant::now();
    match link.attach(session, None, start + BOUND).await {
        Ok((at, reply)) if !rows(&reply).is_empty() => {
            emit(&k, "first_content_ms", Some(ms(at - start)));
            emit_bytes(&k, shaper);
            last = last.max(rows(&reply).into_iter().max().unwrap_or(0));
        }
        Ok(_) => {
            emit(&k, "first_content_ms", None);
            emit_error(&k, "first_content_ms", "the attach reply carried no rows");
        }
        Err(e) => {
            emit(&k, "first_content_ms", None);
            emit_error(&k, "first_content_ms", &e);
        }
    }
    // What the app has seen when its link drops.
    for (_, v) in link.pending.drain(..) {
        if let Some(seq) = event_seq(&v) {
            last = last.max(seq);
        }
    }
    while let Ok(Some((_, Some(v)))) = tokio::time::timeout(Duration::ZERO, link.rx.recv()).await {
        if let Some(seq) = event_seq(&v) {
            last = last.max(seq);
        }
    }
    drop(link);

    // The redial: a new connection, attach with afterSeq; first content is the first row or
    // event newer than what the app had.
    let k = Key { phase: "reconnect", ..k };
    shaper.reset_counters();
    let start = Instant::now();
    let deadline = start + BOUND;
    let mut out = None;
    let first = match Link::open(shaper.addr(), token, deadline).await {
        Err(e) => Err(e),
        Ok(mut l) => {
            let got = match l.attach(session, Some(last), deadline).await {
                Ok((at, reply)) if rows(&reply).iter().any(|s| *s > last) => Ok(at),
                Ok(_) => loop {
                    match l.notification(deadline).await {
                        Next::Frame(at, v) if event_seq(&v).is_some_and(|s| s > last) => {
                            break Ok(at);
                        }
                        Next::Frame(..) => {}
                        _ => break Err("nothing newer than afterSeq arrived".to_owned()),
                    }
                },
                Err(e) => Err(e),
            };
            out = Some(l);
            got
        }
    };
    match first {
        Ok(at) => {
            emit(&k, "first_content_ms", Some(ms(at - start)));
            emit_bytes(&k, shaper);
        }
        Err(e) => {
            emit(&k, "first_content_ms", None);
            emit_error(&k, "first_content_ms", &e);
        }
    }
    end_turn(control).await;
    let _ = control.answer(turn, BOUND).await;
    let mut l = out?;
    let _ = settle(&mut l, &shaper.profile(), Instant::now() + BOUND).await;
    Some(l)
}

/// cold, then warm on the same connection; returns the open, watched, attached link.
async fn cold_and_warm(
    shaper: &Shaper,
    token: &str,
    session: &str,
    profile: &str,
    scale: &str,
    run: u64,
    seed: u64,
) -> Option<Link> {
    let k = Key { profile, phase: "cold", scale, run, seed };
    shaper.reset_counters();
    let start = Instant::now();
    let deadline = start + BOUND;
    let mut link = match Link::open(shaper.addr(), token, deadline).await {
        Ok(l) => l,
        Err(e) => {
            for m in ["first_content_ms", "interactive_ms"] {
                emit(&k, m, None);
                emit_error(&k, m, &e);
            }
            return None;
        }
    };
    // The newest record the app holds; the iOS reopen sends it as afterSeq.
    let mut last = 0u64;
    match link.attach(session, None, deadline).await {
        Ok((at, reply)) if !rows(&reply).is_empty() => {
            last = rows(&reply).into_iter().max().unwrap_or(0);
            emit(&k, "first_content_ms", Some(ms(at - start)));
            emit_bytes(&k, shaper);
        }
        Ok(_) => {
            emit(&k, "first_content_ms", None);
            emit_error(&k, "first_content_ms", "the attach reply carried no rows");
        }
        Err(e) => {
            emit(&k, "first_content_ms", None);
            emit_error(&k, "first_content_ms", &e);
            return None;
        }
    }
    // The prompt is shown as sent when its user_message record comes back.
    let prompt_id = format!("netcond-{profile}-{scale}-{run}");
    let sent = link
        .post(
            method::SESSION_PROMPT,
            json!({"sessionId": session, "prompt": [{"type": "text", "text": "ping"}],
                   "_meta": {"acpmux": {"promptId": prompt_id, "steer": false, "resend": false}}}),
        )
        .await;
    let mut shown = None;
    if sent.is_ok() {
        loop {
            match link.notification(deadline).await {
                Next::Frame(at, v) => {
                    last = last.max(event_seq(&v).unwrap_or(0));
                    let p = v["params"].to_string();
                    if v["method"] == method::MUX_EVENT
                        && p.contains("user_message")
                        && p.contains(&prompt_id)
                    {
                        shown = Some(at);
                        break;
                    }
                }
                _ => break,
            }
        }
    }
    match shown {
        Some(at) => emit(&k, "interactive_ms", Some(ms(at - start))),
        None => {
            emit(&k, "interactive_ms", None);
            emit_error(&k, "interactive_ms", "the prompt's user_message never came back");
        }
    }
    // Let the ping's turn finish arriving before the reopen. A fixed pause was shorter than one
    // round trip on a slow link: the turn's tail was still in flight and the warm reply queued
    // behind it (the shaper delivers in order), so warm measured the ping turn too.
    last = last.max(settle(&mut link, &shaper.profile(), deadline).await);

    // Warm is the app's reopen: it draws its own copy first (AcpmuxHub.swift:679) and attaches
    // with afterSeq = the newest record it holds (AcpmuxHub.swift:1730, :1780 at 3492894eabe5). Its first content
    // is local; this measures the attach reply, the point the reopened chat is known current.
    let k = Key { phase: "warm", ..k };
    shaper.reset_counters();
    let start = Instant::now();
    match link.attach(session, Some(last), start + BOUND).await {
        Ok((at, _)) => {
            emit(&k, "first_content_ms", Some(ms(at - start)));
            emit_bytes(&k, shaper);
        }
        Err(e) => {
            emit(&k, "first_content_ms", None);
            emit_error(&k, "first_content_ms", &e);
            return None;
        }
    }
    settle(&mut link, &shaper.profile(), start + BOUND).await;

    // A second reopen with nothing new since the first (warm has a turn before it; this has
    // none): the cost of a reopen when the chat did not move.
    let k = Key { phase: "warm-again", ..k };
    shaper.reset_counters();
    let start = Instant::now();
    match link.attach(session, Some(last), start + BOUND).await {
        Ok((at, _)) => {
            emit(&k, "first_content_ms", Some(ms(at - start)));
            emit_bytes(&k, shaper);
        }
        Err(e) => {
            emit(&k, "first_content_ms", None);
            emit_error(&k, "first_content_ms", &e);
            return None;
        }
    }
    settle(&mut link, &shaper.profile(), start + BOUND).await;

    // For comparison: a reopen that fetches the whole opening page again (afterSeq none).
    let k = Key { phase: "warm-full", ..k };
    shaper.reset_counters();
    let start = Instant::now();
    match link.attach(session, None, start + BOUND).await {
        Ok((at, reply)) if !rows(&reply).is_empty() => {
            emit(&k, "first_content_ms", Some(ms(at - start)));
            emit_bytes(&k, shaper);
        }
        Ok(_) => {
            emit(&k, "first_content_ms", None);
            emit_error(&k, "first_content_ms", "the attach reply carried no rows");
        }
        Err(e) => {
            emit(&k, "first_content_ms", None);
            emit_error(&k, "first_content_ms", &e);
            return None;
        }
    }
    Some(link)
}

/// The app's wait after a path change before it redials (cmux-next-ios
/// LinkController.swift:180 `networkSettle`), so a burst of path updates settles first.
const NETWORK_SETTLE: Duration = Duration::from_millis(150);

/// The agent streams; the link drops (the profile's disruption); the app's policy reconnects.
#[allow(clippy::too_many_arguments)]
async fn reconnect(
    shaper: &Shaper,
    control: &mut Control,
    mut link: Link,
    token: &str,
    session: &str,
    k: &Key<'_>,
    path_back: bool,
) {
    let fail = |why: &str| {
        for m in ["gap_after_link_back_ms", "gap_total_ms"] {
            emit(k, m, None);
            emit_error(k, m, why);
        }
    };
    let disruption = shaper.profile().disruption;
    let path_change = matches!(disruption, Some(Disruption::AddressChange { .. }));
    let dark_ms = match disruption {
        Some(Disruption::Blackout { duration_ms }) => duration_ms,
        Some(Disruption::AddressChange { stall_ms }) => stall_ms[1],
        // The LAN link this bench dials never drops; nothing here rides the internet path yet.
        Some(Disruption::InternetDown) | None => return,
    };
    // A tick each 100 ms, for the dark plus the give-up and the redial.
    let ticks = (dark_ms + 35_000) / 100;
    let turn = control.prompt(session, &format!("ticking:{ticks}:100")).await;
    let start_deadline = Instant::now() + Duration::from_secs(30);
    let mut last = 0u64;
    let mut seen = 0;
    while seen < 3 {
        match link.notification(start_deadline).await {
            Next::Frame(_, v) => {
                if let Some(seq) = event_seq(&v) {
                    last = last.max(seq);
                    if v.to_string().contains("tick") {
                        seen += 1;
                    }
                }
            }
            _ => break,
        }
    }
    if seen == 0 {
        fail("the agent's stream never reached the phone");
        let _ = control.answer(turn, BOUND).await;
        return;
    }
    while let Ok(Some((_, Some(v)))) = tokio::time::timeout(Duration::ZERO, link.rx.recv()).await {
        if let Some(seq) = event_seq(&v) {
            last = last.max(seq);
        }
    }
    link.pending.clear();

    shaper.reset_counters();
    let t0 = Instant::now();
    let Some(back) = shaper.disrupt() else { return };
    let deadline = t0 + BOUND;
    let mut first: Option<Instant> = None;
    let mut old = if path_change { None } else { Some(link) };
    // The old connection, until something new arrives on it or 20 s pass with nothing inbound.
    if let Some(l) = old.as_mut() {
        let mut last_ping = Instant::now();
        loop {
            let give_up = l.last_inbound + GIVE_UP_AFTER;
            let ping_at = last_ping + PING_EVERY;
            let wake = give_up.min(ping_at).min(deadline);
            match l.notification(wake).await {
                Next::Frame(at, v) => {
                    if event_seq(&v).is_some_and(|s| s > last) {
                        first = Some(at);
                        break;
                    }
                }
                Next::Closed => break,
                Next::Silent => {
                    let now = Instant::now();
                    if now >= deadline || now >= l.last_inbound + GIVE_UP_AFTER {
                        break;
                    }
                    if now >= ping_at {
                        l.ping().await;
                        last_ping = now;
                    }
                }
            }
        }
    }
    drop(old);
    // Redial: each try bounded as the app's requests are, until the overall bound. With
    // `path_back` (the path-change row, the app's behaviour), a try still pending when the link
    // comes back is dropped for a new one after `NETWORK_SETTLE`: the app's NWPathMonitor reports
    // the path back (cmux-next-ios NetworkPathMonitor.swift:55, LiveCoordinator.swift:392) and
    // LinkController redials after its settle (LinkController.swift:180, :193). Without it (the
    // harness-dark-dial row on a blackout) the harness's own dial from the dark rides the shaper's
    // SYN backoff (cmux-fault shaper.rs `connect_at`); the app does not do that.
    let mut why = String::from("no reconnect before the bound");
    let mut dialed = None;
    while first.is_none() && Instant::now() < deadline {
        let now = Instant::now();
        let mut attempt = (now + Duration::from_secs(30)).min(deadline);
        let cut = path_back && now < back;
        if cut {
            attempt = attempt.min(back);
        }
        let wait_for_back =
            || tokio::time::sleep_until(if cut { back + NETWORK_SETTLE } else { Instant::now() });
        let mut l = match Link::open(shaper.addr(), token, attempt).await {
            Ok(l) => {
                dialed = Some((now, Instant::now()));
                l
            }
            Err(e) => {
                why = e;
                wait_for_back().await;
                continue;
            }
        };
        match l.attach(session, Some(last), attempt).await {
            Ok((at, reply)) => {
                if rows(&reply).iter().any(|s| *s > last) {
                    first = Some(at);
                    break;
                }
            }
            Err(e) => {
                why = e;
                wait_for_back().await;
                continue;
            }
        }
        loop {
            match l.notification(deadline).await {
                Next::Frame(at, v) => {
                    if event_seq(&v).is_some_and(|s| s > last) {
                        first = Some(at);
                        break;
                    }
                }
                _ => break,
            }
        }
    }
    match first {
        Some(at) => {
            let after = if at >= back { ms(at - back) } else { -ms(back - at) };
            emit(k, "gap_after_link_back_ms", Some(after));
            emit(k, "gap_total_ms", Some(ms(at - t0)));
            // The path-change gap split: the app's fixed settle before its redial, then the rest
            // (the dial, the attach, the first record).
            if k.phase == "path-change" {
                let settle = ms(NETWORK_SETTLE);
                emit(k, "settle_ms", Some(settle));
                emit(k, "gap_after_settle_ms", Some(after - settle));
            }
            // The dial that got through: when it went out against the link's return (negative:
            // in the dark) and how long it took to open.
            if let Some((sent, open)) = dialed {
                let from_back = if sent >= back { ms(sent - back) } else { -ms(back - sent) };
                emit(k, "dial_from_link_back_ms", Some(from_back));
                emit(k, "dial_open_ms", Some(ms(open - sent)));
            }
            emit_bytes(k, shaper);
        }
        None => fail(&why),
    }
    // The stream's turn ends before the next run.
    let _ = control.answer(turn, BOUND).await;
}

/// The daemon runs a connection's requests at once, so the pipelined `_acpmux/watch` may be
/// answered before `initialize` (on a loss-free link, about 1 open in 60 of the bench's). The
/// open reads that order too: it dropped the early watch answer and waited its whole bound for
/// it, a `no answer to request 2` that was never the daemon's. Held: `initialize` runs only
/// once the watch answer is queued and the pump had time to send it.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_open_whose_watch_is_answered_before_initialize_opens() {
    let _ = HERMETIC;
    let scratch = daemon_env::Scratch::new("netcond-order");
    let hub = hub(&scratch.path().join("home"));
    let queued = Arc::new(tokio::sync::Semaphore::new(0));
    let watch_first = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let (q, first) = (queued.clone(), watch_first.clone());
    hub.hold_requests_for_tests(Arc::new(move |stage, m: &str, _: &Value| {
        let (q, first) = (q.clone(), first.clone());
        let m = m.to_owned();
        Box::pin(async move {
            use acpmux::hub::RequestStage;
            use std::sync::atomic::Ordering;
            if stage == RequestStage::ListQueued && m == method::MUX_WATCH {
                q.add_permits(1);
            } else if stage == RequestStage::Dispatch && m == method::INITIALIZE {
                let got = tokio::time::timeout(Duration::from_secs(10), q.acquire()).await;
                first.store(matches!(got, Ok(Ok(_))), Ordering::SeqCst);
                // The pump takes a read lane's answer (initialize's) ahead of queued bulk
                // lines: the watch answer leaves the queue first.
                tokio::time::sleep(Duration::from_millis(300)).await;
            }
        })
    }));
    let listener = app_ws::listen(&hub).await;
    let addr: std::net::SocketAddr =
        listener.url.trim_start_matches("ws://").trim_end_matches('/').parse().unwrap();
    let deadline = Instant::now() + Duration::from_secs(30);
    let link = Link::open(addr, &listener.token, deadline).await;
    assert!(
        watch_first.load(std::sync::atomic::Ordering::SeqCst),
        "the watch answer was not queued before initialize ran"
    );
    if let Err(e) = link {
        panic!("an open whose watch was answered first: {e}");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "the network-conditions bench: run with --ignored --nocapture"]
async fn chat_open_and_reconnect_under_mobile_link_profiles() {
    let scratch = daemon_env::Scratch::new("netcond");
    let hub = hub(&scratch.path().join("home"));
    let listener = app_ws::listen(&hub).await;
    let upstream: std::net::SocketAddr =
        listener.url.trim_start_matches("ws://").trim_end_matches('/').parse().unwrap();
    let file = match std::env::var("NETCOND_PROFILES_FILE") {
        Ok(p) if !p.is_empty() => ProfileFile::load(Path::new(&p)).unwrap(),
        _ => ProfileFile::builtin(),
    };
    let all: Vec<&str> = file.profiles.iter().map(|p| p.name.as_str()).collect();
    let profiles: Vec<LinkProfile> = env_list("NETCOND_PROFILES", &all)
        .iter()
        .map(|n| file.get(n).unwrap_or_else(|| panic!("no link profile {n}")).clone())
        .collect();
    let scales = env_list("NETCOND_SCALES", &["1x", "10x", "100x"]);
    let runs = env_u64("NETCOND_RUNS", 5);
    let seed_base = env_u64("NETCOND_SEED_BASE", 0);

    let mut control = Control::new(&hub);
    let cwd = scratch.path().join("work");
    std::fs::create_dir_all(&cwd).unwrap();
    let made = control
        .call(
            method::SESSION_NEW,
            json!({"cwd": cwd, "mcpServers": [], "_meta": {"acpmux": {"name": "netcond"}}}),
        )
        .await;
    let session =
        made["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{made}")).to_owned();
    let trace = Trace::new();
    let mut turns = 0;
    for scale in &scales {
        let x: u64 =
            scale.trim_end_matches('x').parse().unwrap_or_else(|_| panic!("scale {scale}"));
        let seeded = Instant::now();
        control.seed(&session, turns, BASE_TURNS * x).await;
        turns = turns.max(BASE_TURNS * x);
        eprintln!("netcond: {scale} = {turns} turns, seeded in {:?}", seeded.elapsed());
        for profile in &profiles {
            let name = format!("{}@{}", profile.name, profile.version);
            for run in 0..runs {
                let seed = run + seed_base;
                let shaper = match Shaper::start(upstream, profile.clone(), seed, &trace).await {
                    Ok(s) => s,
                    Err(e) => {
                        let k = Key { profile: &name, phase: "cold", scale, run, seed };
                        emit_error(&k, "first_content_ms", &format!("shaper: {e}"));
                        continue;
                    }
                };
                let Some(link) =
                    cold_and_warm(&shaper, &listener.token, &session, &name, scale, run, seed)
                        .await
                else {
                    continue;
                };
                let Some(link) = streaming_and_redial(
                    &shaper,
                    &mut control,
                    link,
                    &listener.token,
                    &session,
                    &name,
                    scale,
                    run,
                    seed,
                )
                .await
                else {
                    continue;
                };
                if profile.disrupts_lan() {
                    // On a blackout this row is the harness's own dial from the dark, riding the
                    // shaper's SYN backoff: not the app, which redials on the path change (the
                    // path-change row below, the one the targets read).
                    let blackout = matches!(profile.disruption, Some(Disruption::Blackout { .. }));
                    let phase = if blackout { "harness-dark-dial" } else { "reconnect" };
                    let k = Key { profile: &name, phase, scale, run, seed };
                    reconnect(&shaper, &mut control, link, &listener.token, &session, &k, false)
                        .await;
                    // path-change: the same drop, redialing when the path comes back. Only a
                    // blackout differs: an address change redials at once in both rows.
                    if matches!(profile.disruption, Some(Disruption::Blackout { .. })) {
                        let k = Key { profile: &name, phase: "path-change", scale, run, seed };
                        let open = Instant::now() + BOUND;
                        let link = match Link::open(shaper.addr(), &listener.token, open).await {
                            Ok(mut link) => match link.attach(&session, None, open).await {
                                Ok(_) => Some(link),
                                Err(e) => {
                                    emit_error(&k, "gap_after_link_back_ms", &e);
                                    None
                                }
                            },
                            Err(e) => {
                                emit_error(&k, "gap_after_link_back_ms", &e);
                                None
                            }
                        };
                        if let Some(link) = link {
                            reconnect(
                                &shaper,
                                &mut control,
                                link,
                                &listener.token,
                                &session,
                                &k,
                                true,
                            )
                            .await;
                        }
                    }
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Bytes per minute, by message type

/// What one connection carried, both ways, keyed by message type: a request's method up, its
/// reply as `reply:<method>` down, a notification by method (an `_acpmux/event` by its record's
/// kind and `sessionUpdate`). Bytes are the JSON text; `wire_*` add the WebSocket frame header,
/// `link_*` model the phone's link instead (cmux-mobile-link frames, the host's deflate envelope).
#[derive(Default)]
struct Tap {
    inner: std::sync::Mutex<TapInner>,
}

#[derive(Default, Clone)]
struct TapInner {
    methods: std::collections::HashMap<i64, String>,
    down: std::collections::BTreeMap<String, (u64, u64)>,
    up: std::collections::BTreeMap<String, (u64, u64)>,
    link_down: u64,
    link_up: u64,
}

/// cmux-mobile-link `frame.rs`: `u32 length | u32 channel | u8 type`, payloads split at 256 KiB.
const LINK_HEADER: u64 = 9;
const LINK_MAX_PAYLOAD: u64 = 256 * 1024;
/// The phone's link keepalive (`link.rs`): an 8-byte nonce each way every 15 s.
const LINK_PING_BYTES: u64 = LINK_HEADER + 8;
/// The Mac's mobile host deflates acpmux messages from this size (PROTOCOL.md, CMUX-563).
const LINK_DEFLATE_FROM: usize = 16 * 1024;

fn link_frames(payload: u64) -> u64 {
    payload + LINK_HEADER * payload.div_ceil(LINK_MAX_PAYLOAD).max(1)
}

/// A WebSocket frame's header for a payload of `len` (`masked`: client to server).
fn ws_header(len: u64, masked: bool) -> u64 {
    let base = if len < 126 {
        2
    } else if len <= 0xffff {
        4
    } else {
        10
    };
    base + if masked { 4 } else { 0 }
}

/// The first `sessionUpdate` in `v`, a few levels down.
fn session_update(v: &Value, depth: u8) -> Option<&str> {
    match v {
        Value::Object(map) => map.get("sessionUpdate").and_then(Value::as_str).or_else(|| {
            if depth == 0 {
                return None;
            }
            map.values().find_map(|v| session_update(v, depth - 1))
        }),
        _ => None,
    }
}

impl Tap {
    fn add(map: &mut std::collections::BTreeMap<String, (u64, u64)>, key: String, bytes: u64) {
        let slot = map.entry(key).or_default();
        slot.0 += 1;
        slot.1 += bytes;
    }

    fn up(&self, id: i64, method: &str, len: usize) {
        let mut t = self.inner.lock().unwrap();
        t.methods.insert(id, method.to_owned());
        Self::add(&mut t.up, method.to_owned(), len as u64);
        t.link_up += link_frames(len as u64);
    }

    fn up_ping(&self) {
        Self::add(&mut self.inner.lock().unwrap().up, "ws:ping".to_owned(), 0);
    }

    fn down(&self, frame: &Message) {
        let mut t = self.inner.lock().unwrap();
        let (key, len, link) = match frame {
            Message::Text(text) => {
                let v: Value = serde_json::from_str(text).unwrap_or(Value::Null);
                let key = match v.get("method").and_then(Value::as_str) {
                    Some(m) if m == method::MUX_EVENT => {
                        let p = &v["params"];
                        let kind = p["kind"]
                            .as_str()
                            .or_else(|| p.pointer("/event/kind").and_then(Value::as_str))
                            .unwrap_or("?");
                        match session_update(p, 4) {
                            Some(update) => format!("{m}:{kind}/{update}"),
                            None => format!("{m}:{kind}"),
                        }
                    }
                    Some(m) => m.to_owned(),
                    None => match v.get("id").and_then(Value::as_i64) {
                        Some(id) => format!(
                            "reply:{}",
                            t.methods.get(&id).map(String::as_str).unwrap_or("?")
                        ),
                        None => "?".to_owned(),
                    },
                };
                let len = text.len();
                // The host's deflate envelope: 0x00, two u32 lengths, the raw deflate (the zlib
                // stream less its 2-byte header and 4-byte checksum).
                let link = if len >= LINK_DEFLATE_FROM {
                    let raw = acpmux::frame_compress::deflate(text.as_bytes()).len() as u64 - 6;
                    link_frames(9 + raw)
                } else {
                    link_frames(len as u64)
                };
                (key, len as u64, link)
            }
            Message::Binary(b) => {
                ("binary".to_owned(), b.len() as u64, link_frames(b.len() as u64))
            }
            Message::Ping(b) => ("ws:ping".to_owned(), b.len() as u64, 0),
            Message::Pong(b) => ("ws:pong".to_owned(), b.len() as u64, 0),
            _ => return,
        };
        Self::add(&mut t.down, key, len);
        t.link_down += link;
    }

    /// Everything so far, and a fresh start (the request ids stay known).
    fn take(&self) -> TapInner {
        let mut t = self.inner.lock().unwrap();
        let out = t.clone();
        t.down.clear();
        t.up.clear();
        t.link_down = 0;
        t.link_up = 0;
        out
    }
}

/// Which app's requests the bandwidth bench sends.
#[derive(Clone, Copy, PartialEq)]
enum App {
    /// cmux-next-ios `AcpmuxHub.swift` (as `Link::open` and `Link::attach`), over the phone's link.
    Ios,
    /// The macOS agent pane (webviews `direct.ts` `initializeParams`, `sessionPages.ts`
    /// `SESSION_PAGE`, `attachParams.ts` `plainAttach` local with `settled`), a WebSocket.
    Macos,
}

impl App {
    fn name(self) -> &'static str {
        match self {
            App::Ios => "ios",
            App::Macos => "macos",
        }
    }
}

impl Link {
    async fn open_as(
        app: App,
        addr: std::net::SocketAddr,
        token: &str,
        deadline: Instant,
    ) -> Result<Self, String> {
        if app == App::Ios {
            return Self::open(addr, token, deadline).await;
        }
        let mut link = tokio::time::timeout_at(deadline, Self::dial(addr))
            .await
            .map_err(|_| "connect timed out".to_owned())??;
        let init = link
            .post(
                "initialize",
                json!({"protocolVersion": 1,
                       "clientInfo": {"name": "cmux-react-agent-pane", "version": "1"},
                       "clientCapabilities": {},
                       "_meta": {"acpmux": {"peerRowBatches": true, "localAppToken": token}}}),
            )
            .await?;
        let (_, init) = link.answer(init, deadline).await?;
        link.capabilities = init
            .pointer("/_meta/acpmux/capabilities")
            .and_then(Value::as_array)
            .map(|a| a.iter().filter_map(Value::as_str).map(str::to_owned).collect())
            .unwrap_or_default();
        let watch = link.post("_acpmux/watch", json!({"enabled": true, "limit": 200})).await?;
        link.answer(watch, deadline).await?;
        Ok(link)
    }

    async fn attach_as(
        &mut self,
        app: App,
        session: &str,
        deadline: Instant,
    ) -> Result<(Instant, Value), String> {
        if app == App::Ios {
            return self.attach(session, None, deadline).await;
        }
        let settled = self.capabilities.iter().any(|c| c == "settled-attach-v1");
        let mut params = json!({"sessionId": session, "waitLogs": false, "limit": PAGE_SIZE,
            "maxBytes": OPEN_BYTES, "eventStream": true, "visible": true,
            "kinds": ["transcript", "available_commands_update", "usage_update",
                      "config_option_update", "bookmarks", "secret_request", "secret_decision",
                      "subsession", "queue_order", "queue_updated", "prompt_refused",
                      "elevation_request", "elevation_decision", "preset_approval_request",
                      "preset_approval_decision"]});
        if settled {
            params["settled"] = json!(true);
        }
        let id = self.post("_acpmux/attach", params).await?;
        self.answer(id, deadline).await
    }

    /// Reads (and drops) every frame until `until`: the tap counts them.
    async fn drain(&mut self, until: Instant) {
        self.pending.clear();
        while !matches!(self.frame(until).await, Next::Silent | Next::Closed) {}
    }
}

/// One phase's lines: totals per minute each way, the phone's modeled link bytes, and the top
/// consumers (`down:<type>` / `up:<type>`, bytes per minute; `msgs:` their count per minute).
fn emit_rates(k: &Key, t: &TapInner, wire: (u64, u64), secs: f64, app: App, per_min: bool) {
    let scale = if per_min { 60.0 / secs } else { 1.0 };
    let unit = if per_min { "_per_min" } else { "" };
    let rate = |b: u64| Some((b as f64 * scale).round());
    emit(k, &format!("bytes{unit}_down"), rate(wire.1));
    emit(k, &format!("bytes{unit}_up"), rate(wire.0));
    if app == App::Ios {
        let pings = if per_min { (secs / 15.0).floor() as u64 * LINK_PING_BYTES } else { 0 };
        emit(k, &format!("link_bytes{unit}_down"), rate(t.link_down + pings));
        emit(k, &format!("link_bytes{unit}_up"), rate(t.link_up + pings));
    }
    for (way, map) in [("down", &t.down), ("up", &t.up)] {
        let mut rows: Vec<_> = map.iter().collect();
        rows.sort_by(|a, b| b.1.1.cmp(&a.1.1).then(a.0.cmp(b.0)));
        for (name, (n, bytes)) in rows.into_iter().take(5) {
            emit(k, &format!("{way}:{name}"), rate(*bytes));
            emit(k, &format!("msgs_{way}:{name}"), rate(*n));
        }
    }
}

/// What the shaper and the tap saw since the last call.
fn window(shaper: &Shaper, link: &Link) -> (TapInner, (u64, u64)) {
    let c = shaper.counters();
    shaper.reset_counters();
    (link.tap.take(), (c.up_bytes, c.down_bytes))
}

/// Bytes per minute of one chat in each app, through the shaper: the long chat's open, then
/// idle, a streaming turn and a tool-calling turn, each a fixed window. One `NETCOND` line per
/// value, `phase` `bw_open|bw_idle|bw_stream|bw_tools`, `scale` the app. Env:
/// `NETCOND_BW_PROFILE` (lte), `NETCOND_BW_TURNS` (10000 seeded turns), `NETCOND_BW_SECS` (60),
/// `NETCOND_BW_APPS` (ios,macos).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "the bandwidth bench: run with --ignored --nocapture"]
async fn chat_bytes_per_minute() {
    let scratch = daemon_env::Scratch::new("netcond-bw");
    let hub = hub(&scratch.path().join("home"));
    let listener = app_ws::listen(&hub).await;
    let upstream: std::net::SocketAddr =
        listener.url.trim_start_matches("ws://").trim_end_matches('/').parse().unwrap();
    let file = ProfileFile::builtin();
    let profile_name = std::env::var("NETCOND_BW_PROFILE").unwrap_or_else(|_| "lte".to_owned());
    let profile = file.get(&profile_name).unwrap_or_else(|| panic!("no profile {profile_name}"));
    let name = format!("{}@{}", profile.name, profile.version);
    let turns = env_u64("NETCOND_BW_TURNS", 10_000);
    let secs = env_u64("NETCOND_BW_SECS", 60);
    let window_len = Duration::from_secs(secs);

    let mut control = Control::new(&hub);
    let cwd = scratch.path().join("work");
    std::fs::create_dir_all(&cwd).unwrap();
    let made = control
        .call(
            method::SESSION_NEW,
            json!({"cwd": cwd, "mcpServers": [], "_meta": {"acpmux": {"name": "netcond-bw"}}}),
        )
        .await;
    let session =
        made["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{made}")).to_owned();
    let seeded = Instant::now();
    control.seed(&session, 0, turns).await;
    eprintln!("netcond-bw: {turns} turns seeded in {:?}", seeded.elapsed());

    let trace = Trace::new();
    for app_name in env_list("NETCOND_BW_APPS", &["ios", "macos"]) {
        let app = if app_name == "macos" { App::Macos } else { App::Ios };
        let scale = app.name();
        let key = |phase| Key { profile: &name, phase, scale, run: 0, seed: 0 };
        let shaper = Shaper::start(upstream, profile.clone(), 0, &trace).await.unwrap();
        let start = Instant::now();
        let deadline = start + BOUND;
        let mut link = Link::open_as(app, shaper.addr(), &listener.token, deadline).await.unwrap();
        let (at, reply) = link.attach_as(app, &session, deadline).await.unwrap();
        let k = key("bw_open");
        emit(&k, "first_content_ms", Some(ms(at - start)));
        emit(&k, "open_rows", Some(rows(&reply).len() as f64));
        // What the open sends after its reply (a settled view's follow-up, the stream's start).
        link.drain(Instant::now() + Duration::from_secs(2)).await;
        let (t, wire) = window(&shaper, &link);
        emit_rates(&k, &t, wire, 1.0, app, false);

        // Idle: the chat open, nothing happening.
        let t0 = Instant::now();
        link.drain(t0 + window_len).await;
        let (t, wire) = window(&shaper, &link);
        emit_rates(&key("bw_idle"), &t, wire, t0.elapsed().as_secs_f64(), app, true);

        // A streaming answer: a chunk every 50 ms (about a model's token rate), for the window.
        let chunks = secs * 20 + 20;
        let turn = control.prompt(&session, &format!("ticking:{chunks}:50")).await;
        let t0 = Instant::now();
        link.drain(t0 + window_len).await;
        let (t, wire) = window(&shaper, &link);
        emit_rates(&key("bw_stream"), &t, wire, t0.elapsed().as_secs_f64(), app, true);
        let _ = control.answer(turn, BOUND).await;
        link.drain(Instant::now() + Duration::from_secs(1)).await;
        let _ = window(&shaper, &link);

        // A tool-calling turn: a tool call every 100 ms (the fake agent's 60 s turn).
        let turn = control.prompt(&session, "works-through-cancel").await;
        let t0 = Instant::now();
        link.drain(t0 + window_len.min(Duration::from_secs(55))).await;
        let (t, wire) = window(&shaper, &link);
        emit_rates(&key("bw_tools"), &t, wire, t0.elapsed().as_secs_f64(), app, true);
        let _ = control.answer(turn, BOUND).await;
        drop(link);
    }
}

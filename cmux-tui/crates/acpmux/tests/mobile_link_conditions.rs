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
//! (keepalive pings every 15 s) and redials at once on a path change.
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
    "NETCOND_RELAY",
    "NETCOND_SCALES",
    "NETCOND_RUNS",
    "NETCOND_SEED_BASE",
    "NETCOND_BW_PROFILE",
    "NETCOND_BW_TURNS",
    "NETCOND_BW_SECS",
    "NETCOND_BW_APPS",
    "NETCOND_AWAY",
    "NETCOND_LOADS",
    "NETCOND_CHAT_MAX_TURNS",
    "NETCOND_DEBUG",
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
use std::collections::VecDeque;
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
    /// Replies that came before the one being waited on: acpmux may answer a later request of a
    /// burst first, and the phone's connection matches replies by id (`AcpmuxConnection`).
    early: std::collections::HashMap<i64, (Instant, Value)>,
    next: i64,
    last_inbound: Instant,
    capabilities: Vec<String>,
    /// How long `open` took to dial and upgrade the WebSocket, before its first request.
    upgraded: Duration,
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
            early: std::collections::HashMap::new(),
            next: 0,
            last_inbound: Instant::now(),
            capabilities: Vec::new(),
            upgraded: Duration::ZERO,
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
                Next::Frame(..) => continue,
                other => return other,
            }
        }
    }

    /// The answer to `id` and when it came; notifications on the way wait in `pending`.
    async fn answer(&mut self, id: i64, deadline: Instant) -> Result<(Instant, Value), String> {
        let done = |at: Instant, v: Value| match v.get("error") {
            Some(e) => Err(format!("request {id}: {e}")),
            None => Ok((at, v["result"].clone())),
        };
        if let Some((at, v)) = self.early.remove(&id) {
            return done(at, v);
        }
        loop {
            match self.frame(deadline).await {
                Next::Frame(at, v) => {
                    if v.get("method").is_some() {
                        self.pending.push_back((at, v));
                    } else if v.get("id") == Some(&json!(id)) {
                        return done(at, v);
                    } else if let Some(other) = v.get("id").and_then(Value::as_i64) {
                        if std::env::var_os("NETCOND_DEBUG").is_some() {
                            eprintln!("netcond-debug reply {other} came before {id}");
                        }
                        self.early.insert(other, (at, v));
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
        Self::open_with(addr, token, deadline, App::Ios, false).await
    }

    /// The phone's initialize can request compact text chunks and row changes independently.
    async fn open_with(
        addr: std::net::SocketAddr,
        token: &str,
        deadline: Instant,
        app: App,
        delta: bool,
    ) -> Result<Self, String> {
        let mut meta = json!({"localAppToken": token});
        if app == App::IosCompact {
            meta["chunkDeltas"] = json!(true);
        }
        if delta {
            meta["sessionChangedDelta"] = json!(true);
        }
        let dialed = Instant::now();
        let mut link = tokio::time::timeout_at(deadline, Self::dial(addr))
            .await
            .map_err(|_| "connect timed out".to_owned())??;
        link.upgraded = dialed.elapsed();
        let init = link
            .post(
                "initialize",
                json!({"protocolVersion": 1, "clientInfo": {"name": "cmux-ios", "version": "1"},
                       "clientCapabilities": {}, "_meta": {"acpmux": meta}}),
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
        let id = self.post("_acpmux/attach", params).await?;
        self.answer(id, deadline).await
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
        let started = Instant::now();
        for n in from..turns {
            if n > from && n % 500 == 0 {
                eprintln!("netcond: seeding turn {n}/{turns}, {:?} so far", started.elapsed());
            }
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

/// The Cloud machine peer's second hop: `NETCOND_RELAY=<profile>` puts that shaped link between
/// the phone's link and the hub, which then stands for the one a Cloud machine runs (the phone
/// reaches it through the signed-in Mac's relay link). Rows name both hops: `lte@1+relay-80@1`.
fn relay_hop(file: &ProfileFile) -> Option<LinkProfile> {
    let name = std::env::var("NETCOND_RELAY").ok().filter(|name| !name.trim().is_empty())?;
    Some(
        file.get(name.trim())
            .unwrap_or_else(|| panic!("no link profile {name} for NETCOND_RELAY"))
            .clone(),
    )
}

fn env_u64(name: &str, default: u64) -> u64 {
    std::env::var(name).ok().and_then(|v| v.trim().parse().ok()).unwrap_or(default)
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
    match link.attach(session, None, deadline).await {
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
        while let Next::Frame(at, v) = link.notification(deadline).await {
            let p = v["params"].to_string();
            if v["method"] == method::MUX_EVENT
                && p.contains("user_message")
                && p.contains(&prompt_id)
            {
                shown = Some(at);
                break;
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
    // Let the ping's turn end before the reopen.
    tokio::time::sleep(Duration::from_millis(300)).await;
    link.pending.clear();

    let k = Key { phase: "warm", ..k };
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

/// The agent streams; the link drops (the profile's disruption); the app's policy reconnects.
#[allow(clippy::too_many_arguments)]
async fn reconnect(
    shaper: &Shaper,
    control: &mut Control,
    mut link: Link,
    token: &str,
    session: &str,
    k: &Key<'_>,
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
    // Redial: each try bounded as the app's requests are, until the overall bound.
    let mut why = String::from("no reconnect before the bound");
    while first.is_none() && Instant::now() < deadline {
        let attempt = (Instant::now() + Duration::from_secs(30)).min(deadline);
        let mut l = match Link::open(shaper.addr(), token, attempt).await {
            Ok(l) => l,
            Err(e) => {
                why = e;
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
                continue;
            }
        }
        while let Next::Frame(at, v) = l.notification(deadline).await {
            if event_seq(&v).is_some_and(|s| s > last) {
                first = Some(at);
                break;
            }
        }
    }
    match first {
        Some(at) => {
            let after = if at >= back { ms(at - back) } else { -ms(back - at) };
            emit(k, "gap_after_link_back_ms", Some(after));
            emit(k, "gap_total_ms", Some(ms(at - t0)));
            emit_bytes(k, shaper);
        }
        None => fail(&why),
    }
    // The stream's turn ends before the next run.
    let _ = control.answer(turn, BOUND).await;
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
    let relay = relay_hop(&file);
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
            let name = profile.label(relay.as_ref());
            for run in 0..runs {
                let seed = run + seed_base;
                let started =
                    Shaper::start_through(upstream, profile.clone(), relay.as_ref(), seed, &trace);
                let (shaper, _hop) = match started.await {
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
                if profile.disrupts_lan() {
                    let k = Key { profile: &name, phase: "reconnect", scale, run, seed };
                    reconnect(&shaper, &mut control, link, &listener.token, &session, &k).await;
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
    /// When the first text chunk came (`agent_message_chunk` as `_acpmux/event`, or
    /// `_acpmux/chunk`), since the last `take`.
    first_chunk: Option<Instant>,
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
        if t.first_chunk.is_none()
            && (key.ends_with("/agent_message_chunk") || key == method::MUX_CHUNK)
        {
            t.first_chunk = Some(Instant::now());
        }
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
        t.first_chunk = None;
        out
    }
}

/// Which app's requests the bandwidth bench sends.
#[derive(Clone, Copy, PartialEq)]
enum App {
    /// cmux-next-ios `AcpmuxHub.swift` (as `Link::open` and `Link::attach`), over the phone's link.
    Ios,
    /// [`App::Ios`] that asks for compact text chunks (`initialize` `_meta.acpmux.chunkDeltas`,
    /// `server/chunk_deltas.rs`).
    IosCompact,
    /// The macOS agent pane (webviews `direct.ts` `initializeParams`, `sessionPages.ts`
    /// `SESSION_PAGE`, `attachParams.ts` `plainAttach` local with `settled`), a WebSocket.
    Macos,
}

impl App {
    fn name(self) -> &'static str {
        match self {
            App::Ios => "ios",
            App::IosCompact => "ios-compact",
            App::Macos => "macos",
        }
    }
}

impl Link {
    async fn open_as(
        app: App,
        delta: bool,
        addr: std::net::SocketAddr,
        token: &str,
        deadline: Instant,
    ) -> Result<Self, String> {
        if app != App::Macos {
            return Self::open_with(addr, token, deadline, app, delta).await;
        }
        let mut meta = json!({"peerRowBatches": true, "localAppToken": token});
        if delta {
            meta["sessionChangedDelta"] = json!(true);
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
                       "_meta": {"acpmux": meta}}),
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
        if app != App::Macos {
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
    if app != App::Macos {
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
/// `NETCOND_BW_APPS` (ios, ios-compact, macos). The compact phone asks for text chunks.
/// Append `+delta` to any app to request row changes as `_acpmux/session_patch`.
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
    let relay = relay_hop(&file);
    let name = profile.label(relay.as_ref());
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
        let (base, delta) = match app_name.strip_suffix("+delta") {
            Some(base) => (base, true),
            None => (app_name.as_str(), false),
        };
        let app = match base {
            "macos" => App::Macos,
            "ios-compact" => App::IosCompact,
            _ => App::Ios,
        };
        let scale = if delta { app_name.as_str() } else { app.name() };
        let key = |phase| Key { profile: &name, phase, scale, run: 0, seed: 0 };
        let (shaper, _hop) =
            Shaper::start_through(upstream, profile.clone(), relay.as_ref(), 0, &trace)
                .await
                .unwrap();
        let start = Instant::now();
        let deadline = start + BOUND;
        let mut link =
            Link::open_as(app, delta, shaper.addr(), &listener.token, deadline).await.unwrap();
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
        let asked = Instant::now();
        let turn = control.prompt(&session, &format!("ticking:{chunks}:50")).await;
        let t0 = Instant::now();
        link.drain(t0 + window_len).await;
        let (t, wire) = window(&shaper, &link);
        let k = key("bw_stream");
        // The prompt to its first chunk on the phone's side of the link.
        emit(&k, "first_chunk_ms", t.first_chunk.map(|at| ms(at - asked)));
        emit_rates(&k, &t, wire, t0.elapsed().as_secs_f64(), app, true);
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

/// Applies a `_acpmux/session_patch` `patch` to the row held: the client's side of
/// `session-changed-delta-v1` (`server/session_patch.rs`).
fn apply_patch(target: &mut Value, patch: &Value) {
    match patch {
        Value::Object(p) if p.len() == 1 && p.contains_key("$splice") => {
            let args = &p["$splice"];
            let from = args[0].as_u64().unwrap() as usize;
            let keep = args[1].as_u64().unwrap() as usize;
            let held = target.as_array().cloned().unwrap_or_default();
            let mut out = held[from..from + keep].to_vec();
            out.extend(args[2].as_array().unwrap().iter().cloned());
            *target = Value::Array(out);
        }
        Value::Object(p) => {
            if !target.is_object() {
                *target = json!({});
            }
            let obj = target.as_object_mut().unwrap();
            for (k, v) in p {
                if v.is_null() {
                    obj.remove(k);
                } else {
                    apply_patch(obj.entry(k.clone()).or_insert(Value::Null), v);
                }
            }
        }
        other => *target = other.clone(),
    }
}

/// Every row notice `link` hears until `until`: (method, its params, its bytes).
async fn row_notices(link: &mut Link, until: Instant) -> Vec<(String, Value, usize)> {
    let mut out = Vec::new();
    while let Next::Frame(_, v) = link.notification(until).await {
        let m = v["method"].as_str().unwrap_or_default().to_owned();
        if m == method::MUX_SESSION_CHANGED || m == "_acpmux/session_patch" {
            let bytes = v.to_string().len();
            out.push((m, v["params"].clone(), bytes));
        }
    }
    out
}

/// A streaming turn on a 10,000-message chat (`NETCOND_DELTA_TURNS`): a client that asked for
/// patches (`sessionChangedDelta`) hears each row change after the first as a
/// `_acpmux/session_patch` under 2 KB that takes its row to the daemon's; a client that did not
/// still hears every change as the whole row in `session_changed`, with no `rowSeq`.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn session_changed_on_a_long_chat_is_a_small_patch_only_for_a_client_that_asked() {
    let scratch = daemon_env::Scratch::new("netcond-delta");
    let hub = hub(&scratch.path().join("home"));
    let listener = app_ws::listen(&hub).await;
    let addr: std::net::SocketAddr =
        listener.url.trim_start_matches("ws://").trim_end_matches('/').parse().unwrap();
    let mut control = Control::new(&hub);
    let cwd = scratch.path().join("work");
    std::fs::create_dir_all(&cwd).unwrap();
    let made = control
        .call(
            method::SESSION_NEW,
            json!({"cwd": cwd, "mcpServers": [], "_meta": {"acpmux": {"name": "netcond-delta"}}}),
        )
        .await;
    let session = made["result"]["sessionId"].as_str().unwrap().to_owned();
    let turns = env_u64("NETCOND_DELTA_TURNS", 10_000);
    let seeded = Instant::now();
    control.seed(&session, 0, turns).await;
    eprintln!("netcond-delta: {turns} turns seeded in {:?}", seeded.elapsed());

    let deadline = Instant::now() + BOUND;
    let mut old = Link::open(addr, &listener.token, deadline).await.unwrap();
    let mut new = Link::open_with(addr, &listener.token, deadline, App::Ios, true).await.unwrap();
    assert!(
        new.capabilities.iter().any(|c| c == "session-changed-delta-v1"),
        "{:?}",
        new.capabilities
    );
    old.attach(&session, None, deadline).await.unwrap();
    new.attach(&session, None, deadline).await.unwrap();
    // The attach's own row notices, then a turn that streams a chunk every 50 ms for 2 s.
    let settle = Instant::now() + Duration::from_secs(2);
    let (mut old_heard, mut new_heard) =
        tokio::join!(row_notices(&mut old, settle), row_notices(&mut new, settle));
    let turn = control.prompt(&session, "ticking:40:50").await;
    let window = Instant::now() + Duration::from_secs(4);
    let (old_window, new_window) =
        tokio::join!(row_notices(&mut old, window), row_notices(&mut new, window));
    old_heard.extend(old_window);
    new_heard.extend(new_window);
    let _ = control.answer(turn, BOUND).await;

    // The old client: whole rows, as before.
    let whole: Vec<_> = old_heard
        .iter()
        .filter(|(m, p, _)| m == method::MUX_SESSION_CHANGED && p["sessionId"] == session)
        .collect();
    assert!(!whole.is_empty(), "the old client heard no row change");
    assert!(
        old_heard.iter().all(|(m, _, _)| m == method::MUX_SESSION_CHANGED),
        "the old client heard a patch"
    );
    for (_, p, _) in &whole {
        assert!(p["session"].is_object() && p.get("rowSeq").is_none(), "{p}");
    }
    let biggest = whole.iter().map(|(_, _, b)| *b).max().unwrap();
    eprintln!("netcond-delta: old client {} rows, the largest {biggest} bytes", whole.len());

    // The capable client: one whole row, then patches.
    let patches: Vec<_> = new_heard.iter().filter(|(_, p, _)| p["sessionId"] == session).collect();
    assert!(!patches.is_empty(), "the capable client heard no row change");
    let mut held: Option<(u64, Value)> = None;
    let mut sizes = Vec::new();
    for (m, p, bytes) in &patches {
        let row_seq = p["rowSeq"].as_u64().unwrap_or_else(|| panic!("no rowSeq: {p}"));
        if m == method::MUX_SESSION_CHANGED {
            held = Some((row_seq, p["session"].clone()));
            continue;
        }
        sizes.push(*bytes);
        assert!(*bytes < 2048, "a patch of {bytes} bytes on a {turns}-turn chat: {p}");
        let (at, row) =
            held.as_mut().unwrap_or_else(|| panic!("a patch before the whole row: {p}"));
        assert_eq!(p["baseRowSeq"].as_u64(), Some(*at), "{p}");
        apply_patch(row, &p["patch"]);
        *at = row_seq;
    }
    assert!(!sizes.is_empty(), "no patch in the window");
    eprintln!(
        "netcond-delta: capable client {} patches, the largest {} bytes",
        sizes.len(),
        sizes.iter().max().unwrap()
    );
    // Its row is the daemon's: the same as the last whole row the old client heard, field by
    // field for the ones a later read would not move.
    let (_, row) = held.expect("the capable client's first row change is the whole row");
    let last_old = &whole.last().unwrap().1["session"];
    for field in ["sessionId", "lastSeq", "turnCount", "status", "harness", "cwd"] {
        assert_eq!(row[field], last_old[field], "{field}");
    }
    if let Some(spans) = last_old.pointer("/timeBreakdown/spans").and_then(Value::as_array) {
        let held_spans = row.pointer("/timeBreakdown/spans").and_then(Value::as_array);
        assert_eq!(held_spans.map(Vec::len), Some(spans.len()), "timeBreakdown spans");
    }
}

// ---------------------------------------------------------------------------------------------
// Background: the time-away table (Leo, 2026-11-24: "the syncing can arguably happen in the
// background too, so deltas can be sipped and maintained"; cmux-next-ios/design/
// background-delta-sync.md). The phone holds the chat at its newest record and its link closes;
// acpmux gets what a span of time away brings (simulated: the turns are made at once), then the
// link reopens through the shaper and the chat catches up.
//
// Loads: idle, no turns; busy, one agent streaming a turn of ~1 KB (the open bench's turn) every
// BG_BUSY_TURN_EVERY_S, about one record a second. acpmux keeps every record of a chat (its
// journal), so nothing is capped by the host; NETCOND_CHAT_MAX_TURNS caps what one span makes
// (default: none).
//
// Phone forms, phase:
// - before (the phone today, AcpmuxHub.readPages with a gap allowed): initialize and the watch
//   on the new link, then `_acpmux/attach {afterSeq, beforeSeq, maxBytes}` (tail-first); on a
//   gap with `hasMore`, the `_acpmux/events` read after the newest page that tells the two Mac
//   kinds apart, then forward pages while `hasMore`.
// - after (the phone with this change, AcpmuxHub.pipelineAttaches and pageReachesEnd): the
//   attach goes in the same burst as initialize and the watch, with the kinds the last
//   connection named; the chat is current once the page says it reaches the host's `lastSeq`
//   (`pageThrough`), with no confirming read (a reply short of it still gets the read).
// `catch_up_ms` from the dial to the phone holding the host's newest record; `upgrade_ms` the
// WebSocket upgrade alone (the terminal bench's connect has no such leg: its channel rides the
// link), and `resume_ms` the rest, which is what compares with the terminal's rows.
// Rows: surface `chat`, scale `<away>-<load>`.

const BG_BUSY_TURN_EVERY_S: u64 = 2;
/// AcpmuxHub.tailBeforeSeq.
const TAIL_BEFORE_SEQ: u64 = 1_099_511_627_776;

fn bg_away_secs(label: &str) -> u64 {
    let (number, unit) = label.split_at(label.len() - 1);
    let n: u64 = number.parse().unwrap_or_else(|_| panic!("time away {label}: 30s, 10m or 8h"));
    match unit {
        "s" => n,
        "m" => n * 60,
        "h" => n * 3600,
        _ => panic!("time away {label}: 30s, 10m or 8h"),
    }
}

fn page_seqs(reply: &Value) -> Option<u64> {
    let newest = rows(reply).into_iter().max();
    let through = reply["pageThrough"].as_u64();
    newest.max(through)
}

/// NETCOND_DEBUG=1: each read's page on stderr.
fn bg_debug(phase: &str, read: &str, reply: &Value) {
    if std::env::var_os("NETCOND_DEBUG").is_none() {
        return;
    }
    let page = rows(reply);
    eprintln!(
        "netcond-debug {phase} {read}: {} rows {:?}..{:?} hasMore {} pageThrough {} lastSeq {} bytes {}",
        page.len(),
        page.first(),
        page.last(),
        reply["hasMore"],
        reply["pageThrough"],
        reply["lastSeq"],
        reply.to_string().len()
    );
}

/// The chat's catch-up from `after` on a fresh link through `shaper`.
async fn bg_chat_once(
    shaper: &Shaper,
    token: &str,
    session: &str,
    after: u64,
    phase: &str,
    cached: &[String],
) -> Result<(Duration, Duration, u64, bool), String> {
    shaper.reset_counters();
    let start = Instant::now();
    let deadline = start + BOUND;
    let tail = |kinds: Value| {
        json!({"sessionId": session, "limit": PAGE_SIZE, "kinds": kinds,
        "eventStream": true, "afterSeq": after, "beforeSeq": TAIL_BEFORE_SEQ,
        "maxBytes": OPEN_BYTES, "toolOutputMaxBytes": TOOL_OUTPUT_MAX_BYTES,
        // The phone holds a breakdown version from its last attach, so it asks for none
        // (`AcpmuxHub.attachParams`).
        "omitTimeBreakdown": true})
    };
    let (upgrade, mut link, reply) = if phase == "before" {
        let mut link = Link::open(shaper.addr(), token, deadline).await?;
        let upgrade = link.upgraded;
        let id = link.post("_acpmux/attach", tail(link.kinds())).await?;
        let (_, reply) = link.answer(id, deadline).await?;
        (upgrade, link, reply)
    } else {
        // initialize, the watch and the attach in one burst, the attach with the last
        // connection's kinds; acpmux answers them in order.
        let mut link = tokio::time::timeout_at(deadline, Link::dial(shaper.addr()))
            .await
            .map_err(|_| "connect timed out".to_owned())??;
        let upgrade = start.elapsed();
        link.capabilities = cached.to_vec();
        let pipelined = tail(link.kinds());
        let init = link
            .post(
                "initialize",
                json!({"protocolVersion": 1, "clientInfo": {"name": "cmux-ios", "version": "1"},
                       "clientCapabilities": {}, "_meta": {"acpmux": {"localAppToken": token}}}),
            )
            .await?;
        let watch =
            link.post("_acpmux/watch", json!({"enabled": true, "limit": WATCH_LIMIT})).await?;
        let id = link.post("_acpmux/attach", pipelined.clone()).await?;
        let (_, init) = link.answer(init, deadline).await?;
        link.capabilities = init
            .pointer("/_meta/acpmux/capabilities")
            .and_then(Value::as_array)
            .map(|a| a.iter().filter_map(Value::as_str).map(str::to_owned).collect())
            .unwrap_or_default();
        link.answer(watch, deadline).await?;
        let (_, mut reply) = link.answer(id, deadline).await?;
        if tail(link.kinds()) != pipelined {
            // initialize named other kinds: the phone asks again.
            let id = link.post("_acpmux/attach", tail(link.kinds())).await?;
            reply = link.answer(id, deadline).await?.1;
        }
        (upgrade, link, reply)
    };
    let last = reply["lastSeq"].as_u64().ok_or(format!("attach has no lastSeq: {reply}"))?;
    let page = rows(&reply);
    bg_debug(phase, "attach", &reply);
    let mut held = page_seqs(&reply).unwrap_or(0).max(after);
    let mut more = reply["hasMore"] == json!(true);
    let gap = more && page.first().is_some_and(|first| *first > after + 1);
    let hit = !more;
    let mut cursor = page.last().copied();
    let reaches_end = matches!(
        (reply["pageThrough"].as_u64(), reply["lastSeq"].as_u64()),
        (Some(through), Some(last)) if through >= last
    );
    if gap && (phase == "before" || !reaches_end) {
        // The read that tells a tail-first Mac from a forward-only one.
        let newest = page.last().copied().unwrap_or(after);
        let id = link
            .post(
                "_acpmux/events",
                json!({"sessionId": session, "afterSeq": newest,
                "limit": PAGE_SIZE, "kinds": link.kinds()}),
            )
            .await?;
        let (_, next) = link.answer(id, deadline).await?;
        bg_debug(phase, "confirm", &next);
        let events = rows(&next);
        more = !events.is_empty() && next["hasMore"] == json!(true);
        held = held.max(page_seqs(&next).unwrap_or(0));
        cursor = events.last().copied().or(cursor);
    } else if gap {
        // Tail-first: the newest page reaches the host's last record; the rest fills behind.
        more = held < last;
    }
    while more && held < last {
        let Some(from) = cursor else { break };
        let id = link
            .post(
                "_acpmux/events",
                json!({"sessionId": session, "afterSeq": from,
                "limit": PAGE_SIZE, "kinds": link.kinds()}),
            )
            .await?;
        let (_, next) = link.answer(id, deadline).await?;
        bg_debug(phase, "forward", &next);
        let events = rows(&next);
        more = !events.is_empty() && next["hasMore"] == json!(true);
        held = held.max(page_seqs(&next).unwrap_or(0));
        cursor = events.last().copied();
    }
    let took = start.elapsed();
    if std::env::var_os("NETCOND_DEBUG").is_some() {
        // What came down, by message type, against the shaper's count.
        // Each notification, with its biggest session fields, and what lands in the next 1.5 s.
        let show = |when: &str, v: &Value| {
            let mut fields: Vec<(String, usize)> = v["params"]["session"]
                .as_object()
                .map(|m| m.iter().map(|(k, x)| (k.clone(), x.to_string().len())).collect())
                .unwrap_or_default();
            fields.sort_by(|a, b| b.1.cmp(&a.1));
            fields.truncate(6);
            eprintln!(
                "netcond-debug {phase} {when} {} kind {} recordKind {} seq {} bytes {} top {:?}",
                v["method"],
                v["params"]["kind"],
                v["params"]["recordKind"],
                v["params"]["seq"],
                v.to_string().len(),
                fields
            );
        };
        for (_, v) in &link.pending {
            show("held", v);
        }
        let tail_end = Instant::now() + Duration::from_millis(1500);
        while let Next::Frame(_, v) = link.frame(tail_end).await {
            show("late", &v);
        }
        let tapped = link.tap.take();
        let total: u64 = tapped.down.values().map(|(_, b)| b).sum();
        eprintln!(
            "netcond-debug {phase} down: {total} bytes read, {} on the wire, {:?}",
            shaper.counters().down_bytes,
            tapped.down
        );
    }
    if held < last {
        return Err(format!("the phone holds {held}, the host {last}"));
    }
    Ok((took, upgrade, last.saturating_sub(after), hit))
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "the time-away bench: scripts/measure/ios-network-conditions.sh mode=background runs it"]
async fn chat_background_catch_up_after_time_away() {
    let scratch = daemon_env::Scratch::new("netcond-bg");
    let hub = hub(&scratch.path().join("home"));
    let listener = app_ws::listen(&hub).await;
    let upstream: std::net::SocketAddr =
        listener.url.trim_start_matches("ws://").trim_end_matches('/').parse().unwrap();
    let file = match std::env::var("NETCOND_PROFILES_FILE") {
        Ok(p) if !p.is_empty() => ProfileFile::load(Path::new(&p)).unwrap(),
        _ => ProfileFile::builtin(),
    };
    let profiles: Vec<LinkProfile> = env_list("NETCOND_PROFILES", &["good-wifi", "lte", "lossy-3"])
        .iter()
        .map(|n| file.get(n).unwrap_or_else(|| panic!("no link profile {n}")).clone())
        .collect();
    let aways = env_list("NETCOND_AWAY", &["1m", "10m", "1h", "8h"]);
    let loads = env_list("NETCOND_LOADS", &["idle", "busy"]);
    let runs = env_u64("NETCOND_RUNS", 5);
    let seed_base = env_u64("NETCOND_SEED_BASE", 0);
    let max_turns = env_u64("NETCOND_CHAT_MAX_TURNS", u64::MAX);

    let mut control = Control::new(&hub);
    let cwd = scratch.path().join("work");
    std::fs::create_dir_all(&cwd).unwrap();
    let made = control
        .call(
            method::SESSION_NEW,
            json!({"cwd": cwd, "mcpServers": [], "_meta": {"acpmux": {"name": "netcond-bg"}}}),
        )
        .await;
    let session =
        made["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{made}")).to_owned();
    // A chat with history before anything is measured (the open bench's 1x).
    control.seed(&session, 0, BASE_TURNS).await;
    let mut turns = BASE_TURNS;
    println!(
        "NETCOND-FIXTURE background chat: busy = a ~1 KB turn every {BG_BUSY_TURN_EVERY_S} s; \
         idle = none; turns per span capped at {}",
        if max_turns == u64::MAX { "none".to_owned() } else { max_turns.to_string() }
    );
    let trace = Trace::new();
    for load in &loads {
        let busy = load == "busy";
        for away in &aways {
            let secs = bg_away_secs(away);
            let scale = format!("{away}-{load}");
            let span_turns = if busy { (secs / BG_BUSY_TURN_EVERY_S).min(max_turns) } else { 0 };
            for run in 0..runs {
                let seed = seed_base + run;
                // The phone's cursor: the newest record when it left, and the capabilities its
                // last connection to this Mac named.
                let (after, cached) = {
                    let deadline = Instant::now() + BOUND;
                    let probe = async {
                        let mut link = Link::open(upstream, &listener.token, deadline).await?;
                        let (_, reply) = link.attach(&session, None, deadline).await?;
                        let last =
                            reply["lastSeq"].as_u64().ok_or(format!("no lastSeq: {reply}"))?;
                        Ok::<_, String>((last, link.capabilities.clone()))
                    };
                    match probe.await {
                        Ok(found) => found,
                        Err(why) => {
                            println!("NETCOND-ERROR chat {scale} run {run}: cursor: {why}");
                            continue;
                        }
                    }
                };
                let made = Instant::now();
                control.seed(&session, turns, turns + span_turns).await;
                turns += span_turns;
                eprintln!(
                    "netcond: chat {scale} run {run}: {span_turns} turns in {:?}",
                    made.elapsed()
                );
                for profile in &profiles {
                    let name = profile.label(None);
                    let (shaper, _hop) =
                        match Shaper::start_through(upstream, profile.clone(), None, seed, &trace)
                            .await
                        {
                            Ok(s) => s,
                            Err(e) => {
                                println!("NETCOND-ERROR chat {name} {scale}: shaper: {e}");
                                continue;
                            }
                        };
                    for phase in ["before", "after"] {
                        let k = Key { profile: &name, phase, scale: &scale, run, seed };
                        emit(&k, "stale_s", Some(secs as f64));
                        match bg_chat_once(
                            &shaper,
                            &listener.token,
                            &session,
                            after,
                            phase,
                            &cached,
                        )
                        .await
                        {
                            Ok((took, upgrade, behind, hit)) => {
                                emit(&k, "events_behind", Some(behind as f64));
                                emit(&k, "catch_up_ms", Some(ms(took)));
                                emit(&k, "upgrade_ms", Some(ms(upgrade)));
                                emit(&k, "resume_ms", Some(ms(took.saturating_sub(upgrade))));
                                emit_bytes(&k, &shaper);
                                emit(&k, "cursor_hit", Some(f64::from(u8::from(hit))));
                            }
                            Err(why) => {
                                emit(&k, "catch_up_ms", None);
                                emit_error(&k, "catch_up_ms", &why);
                            }
                        }
                    }
                }
            }
        }
    }
}

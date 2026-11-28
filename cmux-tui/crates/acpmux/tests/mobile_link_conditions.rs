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
// environment, so the bench's knobs are kept by name or every run takes the defaults. Every
// NETCOND_ name this file reads is here: `every_bench_knob_survives_the_hermetic_restart` fails
// on one that is not (the send and attach knobs were missing, so `attach_bytes=286107` still
// sent 5 MiB and `n=20 send_rows=idle,lte,duress` still ran 25 sends on five rows).
const KEPT: &[&str] = &[
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
    "NETCOND_DELTA_TURNS",
    "NETCOND_SENDS",
    "NETCOND_SEND_ROWS",
    "NETCOND_SEND_BLACKOUT_MS",
    "NETCOND_SEND_BOUND_S",
    "NETCOND_ATTACH_SENDS",
    "NETCOND_ATTACH_BYTES",
    "NETCOND_ATTACH_ROWS",
    "NETCOND_CANCEL_SENDS",
    "NETCOND_CANCEL_BYTES",
    "NETCOND_CANCEL_AFTER",
    "NETCOND_CANCEL_ROWS",
    "NETCOND_AWAY",
    "NETCOND_LOADS",
    "NETCOND_CHAT_MAX_TURNS",
    "NETCOND_DEBUG",
    "NETCOND_LIST_NS",
    "NETCOND_LIST_CHANGED",
    "NETCOND_LIST_ROWS",
];
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in().keep(KEPT);

/// The process restarts itself with a cleared environment (`daemon_env::enter`), keeping only
/// `KEPT`: a knob read here but not kept silently takes its default in every run.
#[test]
fn every_bench_knob_survives_the_hermetic_restart() {
    let _ = HERMETIC;
    let source = include_str!("mobile_link_conditions.rs");
    let quote = '"';
    let needle = format!("{quote}NETCOND_");
    let mut missing = Vec::new();
    for (at, _) in source.match_indices(needle.as_str()) {
        let rest = &source[at + 1..];
        let len = rest.find(|c: char| !c.is_ascii_uppercase() && c != '_').unwrap_or(rest.len());
        let name = &rest[..len];
        let whole = name.len() > "NETCOND_".len() && rest[len..].starts_with(quote);
        if whole && !KEPT.contains(&name) {
            missing.push(name.to_owned());
        }
    }
    missing.sort();
    missing.dedup();
    assert!(
        missing.is_empty(),
        "read but not kept across the hermetic restart, add to KEPT: {missing:?}"
    );
}

#[path = "support/app_ws.rs"]
mod app_ws;

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message as RpcMessage, method};
use acpmux::server::{AGENT_PANE_ORIGIN, Origin, WS_MAX_MESSAGE_BYTES, serve_connection_with};
use cmux_composer_send::chat::{self, PromptOutbox};
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

/// Legs a row does not run, and why: not a miss and not a failure, so no `NETCOND-ERROR` and no
/// null value (the report reads a null as a send that did not show within its bound).
fn emit_skip(k: &Key, metrics: &[&str], why: &str) {
    println!(
        "NETCOND-SKIP {}",
        json!({"surface": "chat", "profile": k.profile, "phase": k.phase, "scale": k.scale,
               "metrics": metrics, "seed": k.seed, "why": why})
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
    /// The `timeBreakdownVersion` the last attach reply named; a reattach sends it back so the
    /// daemon leaves out a breakdown this side already holds (the app's AcpmuxSessionSource
    /// keeps it the same way) with `omitTimeBreakdown`, since the phone draws none. `None`
    /// against a daemon that names none: nothing is sent.
    time_breakdown_version: Option<String>,
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
                    // A compressed message (frame_compress.rs), for a client that offered it.
                    Message::Binary(b) => acpmux::frame_compress::inflate(&b, 64 << 20)
                        .ok()
                        .and_then(|t| serde_json::from_str::<Value>(&t).ok()),
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
            time_breakdown_version: None,
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
                // An answer on the way waits for its `answer` read.
                Next::Frame(at, v) => {
                    if let Some(id) = v.get("id").and_then(Value::as_i64) {
                        self.early.insert(id, (at, v));
                    }
                }
                other => return other,
            }
        }
    }

    /// The answer to `id` and when it came; notifications on the way wait in `pending`, and
    /// answers to other requests in `early`.
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

    /// The app's connect: `initialize` and the first watch page together, both answered. It asks
    /// for row changes as patches (`_meta.acpmux.sessionChangedDelta`, `session-changed-delta-v1`,
    /// #51376) as a raw-text phone does; a daemon without it ignores the key and sends whole rows.
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
        // The phone draws no time breakdown (`AcpmuxHub.swift` `bind`).
        let mut meta = json!({"localAppToken": token, "omitTimeBreakdown": true});
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

    /// The app's cold open on a first connection to this Mac: `initialize`, the watch and the
    /// chat's opening attach in one burst, the attach with every kind the phone draws (elevation
    /// included: it knows no capabilities yet). An acpmux too old for that many kinds refuses the
    /// attach; the phone then asks again with the kinds `initialize` named (one more round trip,
    /// as before). Returns the open link, the attach reply's arrival and the reply.
    async fn open_pipelined(
        addr: std::net::SocketAddr,
        token: &str,
        session: &str,
        deadline: Instant,
    ) -> Result<(Self, Instant, Value), String> {
        let dialed = Instant::now();
        let mut link = tokio::time::timeout_at(deadline, Self::dial(addr))
            .await
            .map_err(|_| "connect timed out".to_owned())??;
        link.upgraded = dialed.elapsed();
        let mut every: Vec<&str> = CHAT_KINDS.to_vec();
        every.extend(["elevation_request", "elevation_decision"]);
        let meta = json!({"localAppToken": token, "omitTimeBreakdown": true});
        let init = link
            .post(
                "initialize",
                json!({"protocolVersion": 1, "clientInfo": {"name": "cmux-ios", "version": "1"},
                       "clientCapabilities": {}, "_meta": {"acpmux": meta}}),
            )
            .await?;
        let watch =
            link.post("_acpmux/watch", json!({"enabled": true, "limit": WATCH_LIMIT})).await?;
        let attach = link
            .post(
                "_acpmux/attach",
                json!({"sessionId": session, "limit": PAGE_SIZE, "kinds": every,
                       "eventStream": true, "maxBytes": OPEN_BYTES,
                       "toolOutputMaxBytes": TOOL_OUTPUT_MAX_BYTES}),
            )
            .await?;
        let (_, init) = link.answer(init, deadline).await?;
        link.capabilities = init
            .pointer("/_meta/acpmux/capabilities")
            .and_then(Value::as_array)
            .map(|a| a.iter().filter_map(Value::as_str).map(str::to_owned).collect())
            .unwrap_or_default();
        link.answer(watch, deadline).await?;
        let (at, reply) = match link.answer(attach, deadline).await {
            Ok(answered) if link.kinds() == json!(every) => answered,
            // Refused (an older acpmux), or this Mac serves no elevation records: ask again
            // with the kinds `initialize` named.
            _ => link.attach(session, None, deadline).await?,
        };
        if let Some(v) = reply.get("timeBreakdownVersion").and_then(Value::as_str) {
            link.time_breakdown_version = Some(v.to_owned());
        }
        Ok((link, at, reply))
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
///
/// Its reader never stops: a task takes every line the hub writes, keeps the answers and drops
/// the notifications (counted in `dropped`). The hub ends a connection whose reader holds more
/// than its fair share (`outbound.rs` `FAIR_SHARE`, 4 MiB) and takes nothing for
/// `READER_STALL` (10 s). Read only inside `call`, this one took nothing while a row's phone legs
/// ran; at video sizes a row runs for minutes, the hub ended it, and the next row's
/// `session/new` panicked on a closed channel (the idle row at 62 MB, 2026-11-27).
struct Control {
    tx: mpsc::Sender<String>,
    rx: mpsc::UnboundedReceiver<String>,
    dropped: Arc<std::sync::atomic::AtomicU64>,
    next: i64,
}

impl Control {
    fn new(hub: &Arc<Hub>) -> Self {
        let (tx, in_rx) = mpsc::channel(64);
        let (out_tx, mut out_rx) = mpsc::channel::<String>(65536);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
        let (answers, rx) = mpsc::unbounded_channel();
        let dropped = Arc::new(std::sync::atomic::AtomicU64::new(0));
        let counted = dropped.clone();
        tokio::spawn(async move {
            while let Some(line) = out_rx.recv().await {
                let answer = serde_json::from_str::<Value>(&line)
                    .is_ok_and(|v| v.get("id").is_some() && v.get("method").is_none());
                if !answer {
                    counted.fetch_add(line.len() as u64, std::sync::atomic::Ordering::Relaxed);
                } else if answers.send(line).is_err() {
                    break;
                }
            }
        });
        Self { tx, rx, dropped, next: 0 }
    }

    /// The notification bytes the reader took and dropped so far.
    fn dropped_bytes(&self) -> u64 {
        self.dropped.load(std::sync::atomic::Ordering::Relaxed)
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
    // The app's cold open (AcpmuxHub.pipelineAttaches): the chat's attach rides with
    // initialize and the watch, even on a first connection.
    let (mut link, at, reply) =
        match Link::open_pipelined(shaper.addr(), token, session, deadline).await {
            Ok(opened) => opened,
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
    match Ok::<_, String>((at, reply)) {
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
        while let Next::Frame(at, v) = link.notification(deadline).await {
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
        Some(Disruption::AddressChange { stall_ms, .. }) => stall_ms[1],
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
        // A compressed message counts as its type, at the bytes it took on the wire.
        let inflated = match frame {
            Message::Binary(b) => acpmux::frame_compress::inflate(b, 64 << 20).ok(),
            _ => None,
        };
        let text = match (frame, &inflated) {
            (Message::Text(text), _) => Some(text.as_str()),
            (Message::Binary(_), Some(text)) => Some(text.as_str()),
            _ => None,
        };
        let (key, len, link) = match (frame, text) {
            (Message::Text(_) | Message::Binary(_), Some(text)) => {
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
                let len = match frame {
                    Message::Binary(b) => b.len(),
                    _ => text.len(),
                };
                // The host's deflate envelope: 0x00, two u32 lengths, the raw deflate (the zlib
                // stream less its 2-byte header and 4-byte checksum).
                let link = if text.len() >= LINK_DEFLATE_FROM {
                    let raw = acpmux::frame_compress::deflate(text.as_bytes()).len() as u64 - 6;
                    link_frames(9 + raw)
                } else {
                    link_frames(text.len() as u64)
                };
                (key, len as u64, link)
            }
            (Message::Binary(b), None) => {
                ("binary".to_owned(), b.len() as u64, link_frames(b.len() as u64))
            }
            (Message::Ping(b), _) => ("ws:ping".to_owned(), b.len() as u64, 0),
            (Message::Pong(b), _) => ("ws:pong".to_owned(), b.len() as u64, 0),
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
    /// The same pane on its own socket to an acpmux across a network (the `/app/` browser shell,
    /// `direct.ts` `frameCompression`): the macOS requests, and `initialize` asks for zlib frames.
    Browser,
}

impl App {
    fn name(self) -> &'static str {
        match self {
            App::Ios => "ios",
            App::IosCompact => "ios-compact",
            App::Macos => "macos",
            App::Browser => "browser",
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
        let mut params = json!({"protocolVersion": 1,
               "clientInfo": {"name": "cmux-react-agent-pane", "version": "1"},
               "clientCapabilities": {},
               "_meta": {"acpmux": meta}});
        if app == App::Browser {
            params["_meta"]["acpmux"]["compression"] = acpmux::frame_compress::offer();
        }
        let init = link.post("initialize", params).await?;
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
    // Bytes per row change: each `_acpmux/session_changed` (the whole row) or, to a client that
    // asked (#51376), `_acpmux/session_patch` (what changed), the JSON text; the phone's link adds
    // a 9-byte frame header to each, under the 16 KiB deflate threshold. And how many of each came.
    let of = |name: &str| t.down.get(name).copied().unwrap_or((0, 0));
    let (whole, patch) = (of("_acpmux/session_changed"), of("_acpmux/session_patch"));
    let (n, bytes) = (whole.0 + patch.0, whole.1 + patch.1);
    if n > 0 {
        emit(k, "session_changed_msgs", Some(whole.0 as f64));
        emit(k, "session_patch_msgs", Some(patch.0 as f64));
        emit(k, "bytes_per_session_changed", Some((bytes as f64 / n as f64).round()));
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

/// What compressing the open's attach reply costs: the server's zlib (frame_compress.rs `deflate`,
/// level 1) and the client's inflate of it, the median of 21 runs each, per open and per MB of
/// JSON text. `codec_*` lines under `bw_open`; the same text for every app.
fn emit_codec_cpu(k: &Key, reply: &Value) {
    let text = json!({"jsonrpc": "2.0", "id": 3, "result": reply}).to_string();
    let zlib = acpmux::frame_compress::deflate(text.as_bytes());
    let median = |mut runs: Vec<f64>| {
        runs.sort_by(f64::total_cmp);
        runs[runs.len() / 2]
    };
    let time = |f: &dyn Fn()| {
        median(
            (0..21)
                .map(|_| {
                    let t = Instant::now();
                    f();
                    t.elapsed().as_secs_f64() * 1e3
                })
                .collect(),
        )
    };
    let deflate_ms = time(&|| {
        std::hint::black_box(acpmux::frame_compress::deflate(std::hint::black_box(
            text.as_bytes(),
        )));
    });
    let inflate_ms = time(&|| {
        std::hint::black_box(
            acpmux::frame_compress::inflate(std::hint::black_box(&zlib), 64 << 20).ok(),
        );
    });
    let mb = text.len() as f64 / 1e6;
    emit(k, "codec_text_bytes", Some(text.len() as f64));
    emit(k, "codec_zlib_bytes", Some(zlib.len() as f64));
    emit(k, "codec_deflate_us_per_open", Some((deflate_ms * 1000.0).round()));
    emit(k, "codec_inflate_us_per_open", Some((inflate_ms * 1000.0).round()));
    emit(k, "codec_deflate_ms_per_mb", Some((deflate_ms / mb * 100.0).round() / 100.0));
    emit(k, "codec_inflate_ms_per_mb", Some((inflate_ms / mb * 100.0).round() / 100.0));
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
/// `NETCOND_BW_APPS` (ios, ios-compact, macos, browser). The compact phone asks for text chunks.
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
    for app_name in env_list("NETCOND_BW_APPS", &["ios", "macos", "browser"]) {
        let (base, delta) = match app_name.strip_suffix("+delta") {
            Some(base) => (base, true),
            None => (app_name.as_str(), false),
        };
        let app = match base {
            "macos" => App::Macos,
            "ios-compact" => App::IosCompact,
            "browser" => App::Browser,
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
        emit_codec_cpu(&k, &reply);
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
// Send: tap to "visible as sent", with the phone's retry, and what the host applied
//
// Leo, 2026-11-24 (relayed, ask-1124-0818): "i think we can maybe be more optimistic sometimes.
// it is a bit slow on ios." Item 1, the BEFORE: today the app draws a sent bubble when the Mac's
// `user_message` record for that `promptId` reaches the phone (`AgentChatStore.applyEvent`), so
// tap to visible is a full round trip. One send is: tap (the request is written), then the first
// of the record in the event stream or in a re-attach's rows. A send whose connection goes quiet
// (20 s with no inbound frame, pings every 15 s) redials, re-attaches with `afterSeq` and, when
// the record is not there, sends the prompt again with the SAME `promptId` and `resend: true`, as
// `AcpmuxSessionSource.promptFailed` does. After a row the host's own log says what it applied:
// a `promptId` with two `user_message` records is a double send, with none a lost send.
//
// Rows (phase `send`, scale = the row): idle (no shaper), lte, lossy-3, duress (lte, a long chat,
// a second chat streaming, every core spinning), link-down (lte; at each tap the link drops for
// `NETCOND_SEND_BLACKOUT_MS`, default 3000, and comes back). Metrics: `send_visible_ms` (null: not
// visible within the send's bound), `sends`, `double_sends`, `lost_sends`, `retries`.
// Env: `NETCOND_SENDS` (25 per row), `NETCOND_SEND_ROWS` (idle,lte,lossy-3,link-down,duress),
// `NETCOND_SEND_BLACKOUT_MS`, `NETCOND_SEND_BOUND_S` (45), `NETCOND_SEED_BASE`.

/// The longest a send may take to show before it counts as not visible (a miss).
fn send_bound() -> Duration {
    Duration::from_secs(env_u64("NETCOND_SEND_BOUND_S", 45))
}

/// The slowest upload rate an attachment's bound allows for: a quarter of the lte profile's
/// (5 MiB went up in about 6.5 s, 2026-11-27), so a duress row's slower link still fits.
const ATTACH_FLOOR_BYTES_PER_S: u64 = 256 << 10;

/// An attachment send's bound: the send's, or as long as `bytes` take at
/// [`ATTACH_FLOOR_BYTES_PER_S`] when that is longer. A photo (286107 B, 5 MiB) keeps the send's
/// 45 s; 62 MB gets about 236 s, 170 MB about 648 s.
fn attach_bound(bytes: usize) -> Duration {
    send_bound().max(Duration::from_secs((bytes as u64).div_ceil(ATTACH_FLOOR_BYTES_PER_S)))
}

/// The bytes of the text frame `Link::post` writes for this request.
fn request_bytes(m: &str, params: &Value) -> usize {
    json!({"jsonrpc": "2.0", "id": i64::MAX, "method": m, "params": params}).to_string().len()
}

/// Threads that keep every core busy until dropped: the Mac under load.
struct Spin {
    stop: Arc<std::sync::atomic::AtomicBool>,
    threads: Vec<std::thread::JoinHandle<()>>,
}

impl Spin {
    fn start() -> Self {
        let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let cores = std::thread::available_parallelism().map_or(4, usize::from);
        let threads = (0..cores)
            .map(|_| {
                let stop = stop.clone();
                std::thread::spawn(move || {
                    let mut x = 1u64;
                    while !stop.load(std::sync::atomic::Ordering::Relaxed) {
                        for _ in 0..100_000 {
                            x = x
                                .wrapping_mul(6364136223846793005)
                                .wrapping_add(1442695040888963407);
                        }
                        std::hint::black_box(x);
                    }
                })
            })
            .collect();
        Self { stop, threads }
    }
}

impl Drop for Spin {
    fn drop(&mut self) {
        self.stop.store(true, std::sync::atomic::Ordering::Relaxed);
        for thread in self.threads.drain(..) {
            let _ = thread.join();
        }
    }
}

fn is_echo(v: &Value, prompt_id: &str) -> bool {
    if v["method"] != method::MUX_EVENT {
        return false;
    }
    let p = v["params"].to_string();
    p.contains("user_message") && p.contains(&format!("\"{prompt_id}\""))
}

fn reply_has_echo(reply: &Value, prompt_id: &str) -> bool {
    reply["events"].as_array().is_some_and(|events| {
        events.iter().any(|e| {
            let s = e.to_string();
            s.contains("user_message") && s.contains(&format!("\"{prompt_id}\""))
        })
    })
}

fn prompt_params(session: &str, text: &str, prompt_id: &str, resend: bool) -> Value {
    json!({"sessionId": session, "prompt": [{"type": "text", "text": text}],
           "_meta": {"acpmux": {"promptId": prompt_id, "steer": false, "resend": resend}}})
}

/// One send as the phone does it. Returns (visible_ms, retries); the link may be replaced.
#[allow(clippy::too_many_arguments)]
async fn chat_send_once(
    link: &mut Link,
    addr: std::net::SocketAddr,
    token: &str,
    session: &str,
    prompt_id: &str,
    last: &mut u64,
    tap: Instant,
) -> (Option<f64>, u64) {
    let build = |resend: bool| prompt_params(session, "ping", prompt_id, resend);
    let bound = send_bound();
    chat_send_with(link, addr, token, session, prompt_id, last, tap, bound, &build, &mut None).await
}

/// `chat_send_once` with the prompt built by `build(resend)`, not visible past `bound`; `written`
/// gets the ms from the tap to the first write of it returning (the socket took every byte).
#[allow(clippy::too_many_arguments)]
async fn chat_send_with(
    link: &mut Link,
    addr: std::net::SocketAddr,
    token: &str,
    session: &str,
    prompt_id: &str,
    last: &mut u64,
    tap: Instant,
    bound: Duration,
    build: &dyn Fn(bool) -> Value,
    written: &mut Option<f64>,
) -> (Option<f64>, u64) {
    let deadline = tap + bound;
    let mut retries = 0;
    let mut request = link.post(method::SESSION_PROMPT, build(false)).await.ok();
    *written = Some(ms(Instant::now() - tap));
    let mut last_ping = Instant::now();
    loop {
        if request.is_some() {
            let give_up = link.last_inbound + GIVE_UP_AFTER;
            let ping_at = last_ping + PING_EVERY;
            let wake = give_up.min(ping_at).min(deadline);
            match link.notification(wake).await {
                Next::Frame(at, v) => {
                    if let Some(seq) = event_seq(&v) {
                        *last = (*last).max(seq);
                    }
                    // A frame already queued is handed out even past the deadline (timeout_at polls
                    // first): one that came after the bound is a miss, not a value over it.
                    if is_echo(&v, prompt_id) {
                        return (Some(ms(at - tap)).filter(|_| at <= deadline), retries);
                    }
                    continue;
                }
                Next::Closed => {}
                Next::Silent => {
                    let now = Instant::now();
                    if now >= deadline {
                        return (None, retries);
                    }
                    if now < give_up {
                        if now >= ping_at {
                            link.ping().await;
                            last_ping = now;
                        }
                        continue;
                    }
                }
            }
        }
        // The link is gone (closed, or 20 s of nothing): redial, re-attach after what was seen,
        // and send the prompt again under its id when its record is not there.
        let mut redialed = None;
        while Instant::now() < deadline {
            let attempt = (Instant::now() + Duration::from_secs(30)).min(deadline);
            let Ok(mut fresh) = Link::open(addr, token, attempt).await else {
                tokio::time::sleep(Duration::from_millis(200)).await;
                continue;
            };
            match fresh.attach(session, Some(*last), attempt).await {
                Ok((at, reply)) => {
                    for seq in rows(&reply) {
                        *last = (*last).max(seq);
                    }
                    if reply_has_echo(&reply, prompt_id) {
                        *link = fresh;
                        return (Some(ms(at - tap)), retries);
                    }
                    redialed = Some(fresh);
                    break;
                }
                Err(_) => {
                    tokio::time::sleep(Duration::from_millis(200)).await;
                    continue;
                }
            }
        }
        let Some(fresh) = redialed else { return (None, retries) };
        *link = fresh;
        retries += 1;
        request = link.post(method::SESSION_PROMPT, build(true)).await.ok();
        last_ping = Instant::now();
    }
}

/// What the host applied: `user_message` records per promptId after `after`.
async fn applied_prompts(
    addr: std::net::SocketAddr,
    token: &str,
    session: &str,
    after: u64,
    ids: &[String],
) -> Option<Vec<usize>> {
    let deadline = Instant::now() + BOUND;
    let mut link = Link::open(addr, token, deadline).await.ok()?;
    let mut params = json!({"sessionId": session, "limit": 2000, "kinds": ["user_message"],
                            "afterSeq": after});
    params["eventStream"] = json!(false);
    let id = link.post("_acpmux/attach", params).await.ok()?;
    let (_, reply) = link.answer(id, deadline).await.ok()?;
    let events = reply["events"].as_array()?;
    if events.len() >= 2000 {
        return None;
    }
    Some(
        ids.iter()
            .map(|pid| {
                events
                    .iter()
                    .filter(|e| {
                        let s = e.to_string();
                        s.contains("user_message") && s.contains(&format!("\"{pid}\""))
                    })
                    .count()
            })
            .collect(),
    )
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "the send bench: scripts/measure/ios-network-conditions.sh mode=send runs it"]
async fn chat_send_under_link_conditions() {
    let scratch = daemon_env::Scratch::new("netcond-send");
    let hub = hub(&scratch.path().join("home"));
    let listener = app_ws::listen(&hub).await;
    let upstream: std::net::SocketAddr =
        listener.url.trim_start_matches("ws://").trim_end_matches('/').parse().unwrap();
    let file = match std::env::var("NETCOND_PROFILES_FILE") {
        Ok(p) if !p.is_empty() => ProfileFile::load(Path::new(&p)).unwrap(),
        _ => ProfileFile::builtin(),
    };
    let sends = env_u64("NETCOND_SENDS", 25);
    let seed_base = env_u64("NETCOND_SEED_BASE", 0);
    let blackout = Duration::from_millis(env_u64("NETCOND_SEND_BLACKOUT_MS", 3000));
    let rows_wanted =
        env_list("NETCOND_SEND_ROWS", &["idle", "lte", "lossy-3", "link-down", "duress"]);
    let mut control = Control::new(&hub);
    let cwd = scratch.path().join("work");
    std::fs::create_dir_all(&cwd).unwrap();
    let trace = Trace::new();
    for row in &rows_wanted {
        let (profile, loaded, down) = match row.as_str() {
            "idle" => (None, false, false),
            "lte" => (file.get("lte"), false, false),
            "lossy-3" => (file.get("lossy-3"), false, false),
            "duress" => (file.get("lte"), true, false),
            "link-down" => (file.get("lte"), false, true),
            other => panic!("NETCOND_SEND_ROWS: no row {other}"),
        };
        let profile = profile.cloned();
        let label = profile.as_ref().map_or_else(|| "none".to_owned(), |p| p.label(None));
        let made = control
            .call(
                method::SESSION_NEW,
                json!({"cwd": cwd, "mcpServers": [], "_meta": {"acpmux": {"name": format!("send-{row}")}}}),
            )
            .await;
        let session = made["result"]["sessionId"].as_str().unwrap().to_owned();
        // A loaded Mac: a long chat, a second chat streaming 50 words a second into the watch,
        // every core spinning.
        let (_spin, streaming) = if loaded {
            control.seed(&session, 0, 100).await;
            let other = control
                .call(
                    method::SESSION_NEW,
                    json!({"cwd": cwd, "mcpServers": [], "_meta": {"acpmux": {"name": "send-stream"}}}),
                )
                .await;
            let other = other["result"]["sessionId"].as_str().unwrap().to_owned();
            let turn = control.prompt(&other, "ticking:6000:20").await;
            (Some(Spin::start()), Some(turn))
        } else {
            control.seed(&session, 0, BASE_TURNS).await;
            (None, None)
        };
        let _ = streaming;
        let shaper = match &profile {
            Some(p) => match Shaper::start(upstream, p.clone(), seed_base, &trace).await {
                Ok(s) => Some(s),
                Err(e) => {
                    let k =
                        Key { profile: &label, phase: "send", scale: row, run: 0, seed: seed_base };
                    emit_error(&k, "send_visible_ms", &format!("shaper: {e}"));
                    continue;
                }
            },
            None => None,
        };
        let addr = shaper.as_ref().map_or(upstream, Shaper::addr);
        let opened = Instant::now() + BOUND;
        let Ok(mut link) = Link::open(addr, &listener.token, opened).await else {
            let k = Key { profile: &label, phase: "send", scale: row, run: 0, seed: seed_base };
            emit_error(&k, "send_visible_ms", "the phone's first connect failed");
            continue;
        };
        let mut last = 0;
        match link.attach(&session, None, opened).await {
            Ok((_, reply)) => {
                for seq in rows(&reply) {
                    last = last.max(seq);
                }
            }
            Err(e) => {
                let k = Key { profile: &label, phase: "send", scale: row, run: 0, seed: seed_base };
                emit_error(&k, "send_visible_ms", &e);
                continue;
            }
        }
        let start_seq = last;
        let tag = std::process::id();
        let mut ids = Vec::new();
        let mut retries_total = 0;
        for i in 0..sends {
            let prompt_id = format!("send-{row}-{tag}-{i}");
            let k = Key { profile: &label, phase: "send", scale: row, run: i, seed: seed_base + i };
            let tap = Instant::now();
            if down && let Some(s) = &shaper {
                s.blackout(blackout);
            }
            let (visible, retries) = chat_send_once(
                &mut link,
                addr,
                &listener.token,
                &session,
                &prompt_id,
                &mut last,
                tap,
            )
            .await;
            retries_total += retries;
            emit(&k, "send_visible_ms", visible);
            if visible.is_none() {
                emit_error(&k, "send_visible_ms", "the prompt's user_message did not show in time");
            }
            ids.push(prompt_id);
            // The turn ends (the fake agent echoes) before the next tap: a prompt sent into a
            // running turn queues and its record waits for it.
            tokio::time::sleep(Duration::from_millis(400)).await;
            link.pending.clear();
        }
        // What the host holds, read on an unshaped link.
        tokio::time::sleep(Duration::from_millis(500)).await;
        let k = Key { profile: &label, phase: "send", scale: row, run: 0, seed: seed_base };
        match applied_prompts(upstream, &listener.token, &session, start_seq, &ids).await {
            Some(counts) => {
                emit(&k, "sends", Some(sends as f64));
                emit(&k, "double_sends", Some(counts.iter().filter(|c| **c > 1).count() as f64));
                emit(&k, "lost_sends", Some(counts.iter().filter(|c| **c == 0).count() as f64));
                emit(&k, "retries", Some(retries_total as f64));
            }
            None => emit_error(&k, "double_sends", "the host's log could not be read"),
        }
        drop(link);
    }
}

/// A ~5 MB image-sized blob as the phone sends an image: one base64 `image` block in the prompt.
fn image_prompt(session: &str, text: &str, prompt_id: &str, resend: bool, bytes: usize) -> Value {
    use base64::Engine as _;
    let blob: Vec<u8> = (0..bytes).map(|i| (i.wrapping_mul(2654435761) >> 13) as u8).collect();
    let data = base64::engine::general_purpose::STANDARD.encode(blob);
    json!({"sessionId": session,
           "prompt": [{"type": "text", "text": text},
                      {"type": "image", "mimeType": "image/png", "data": data}],
           "_meta": {"acpmux": {"promptId": prompt_id, "steer": false, "resend": resend}}})
}

/// The attachment row: an image send, then a text send tapped at the same instant that the phone
/// holds behind it (its prompt chain writes in order). Phase "attach", scale = the row.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "the send bench: scripts/measure/ios-network-conditions.sh mode=send runs it"]
async fn chat_attach_under_link_conditions() {
    let scratch = daemon_env::Scratch::new("netcond-attach");
    let hub = hub(&scratch.path().join("home"));
    let listener = app_ws::listen(&hub).await;
    let upstream: std::net::SocketAddr =
        listener.url.trim_start_matches("ws://").trim_end_matches('/').parse().unwrap();
    let file = match std::env::var("NETCOND_PROFILES_FILE") {
        Ok(p) if !p.is_empty() => ProfileFile::load(Path::new(&p)).unwrap(),
        _ => ProfileFile::builtin(),
    };
    let sends = env_u64("NETCOND_ATTACH_SENDS", 20);
    let bytes = env_u64("NETCOND_ATTACH_BYTES", 5 << 20) as usize;
    let seed_base = env_u64("NETCOND_SEED_BASE", 0);
    let rows_wanted = env_list("NETCOND_ATTACH_ROWS", &["idle", "lte", "duress"]);
    let mut control = Control::new(&hub);
    let cwd = scratch.path().join("work");
    std::fs::create_dir_all(&cwd).unwrap();
    let trace = Trace::new();
    for row in &rows_wanted {
        // duress: lte with a loaded Mac, as the send bench's row (ask-bb9c69b84e).
        let (profile, loaded) = match row.as_str() {
            "idle" => (None, false),
            "duress" => (file.get("lte").cloned(), true),
            other => (file.get(other).cloned(), false),
        };
        let label = profile.as_ref().map_or_else(|| "none".to_owned(), |p| p.label(None));
        let made = control
            .call(
                method::SESSION_NEW,
                json!({"cwd": cwd, "mcpServers": [], "_meta": {"acpmux": {"name": format!("attach-{row}")}}}),
            )
            .await;
        let session = made["result"]["sessionId"].as_str().unwrap().to_owned();
        // A loaded Mac: a long chat, a second chat streaming 50 words a second, every core spinning.
        let _spin = if loaded {
            control.seed(&session, 0, 100).await;
            let other = control
                .call(
                    method::SESSION_NEW,
                    json!({"cwd": cwd, "mcpServers": [], "_meta": {"acpmux": {"name": "attach-stream"}}}),
                )
                .await;
            let other = other["result"]["sessionId"].as_str().unwrap().to_owned();
            let _ = control.prompt(&other, "ticking:6000:20").await;
            Some(Spin::start())
        } else {
            control.seed(&session, 0, BASE_TURNS).await;
            None
        };
        let shaper = match &profile {
            Some(p) => Shaper::start(upstream, p.clone(), seed_base, &trace).await.ok(),
            None => None,
        };
        let addr = shaper.as_ref().map_or(upstream, Shaper::addr);
        let opened = Instant::now() + BOUND;
        let Ok(mut link) = Link::open(addr, &listener.token, opened).await else { continue };
        let mut last = 0;
        if let Ok((_, reply)) = link.attach(&session, None, opened).await {
            for seq in rows(&reply) {
                last = last.max(seq);
            }
        }
        // The uploader's own connection through the same shaped radio, for the queue leg.
        let mut upload_link = match Link::open(addr, &listener.token, opened).await {
            Ok(mut l) => l.attach(&session, None, opened).await.ok().map(|_| l),
            Err(_) => None,
        };
        let tag = std::process::id();
        // The bound guards each send (tap to its record showing), not the row: a row is `sends`
        // of them back to back, so it may run for `sends` times the bound. A send past it is a
        // miss (a NETCOND-ERROR); the row's line names the slowest and how many missed.
        let bound = attach_bound(bytes);
        let (mut slowest, mut missed) = (0.0_f64, 0_u64);
        let row_started = Instant::now();
        let dropped_before = control.dropped_bytes();
        // The inline legs send the image as base64 in one WebSocket message; past the listener's
        // message cap the server closes the link on it and the send can never show. Those legs
        // are skipped for the row with an error naming the cap; the upload leg still runs.
        let inline = request_bytes(
            method::SESSION_PROMPT,
            &image_prompt(&session, "photo", &format!("img-q-{row}-{tag}-{sends}"), true, bytes),
        );
        let inline_fits = inline <= WS_MAX_MESSAGE_BYTES;
        if !inline_fits {
            let k = Key { profile: &label, phase: "attach", scale: row, run: 0, seed: seed_base };
            let why = format!(
                "skipped: the inline image prompt is {inline} bytes (a {bytes} B image as \
                 base64), over the WebSocket message cap WS_MAX_MESSAGE_BYTES of \
                 {WS_MAX_MESSAGE_BYTES} bytes; only the upload leg runs"
            );
            // One line for the row, not an error per leg: past the cap the phone sends by
            // reference (AcpmuxHub `needsUpload`), so these legs have nothing to measure.
            let legs = [
                "attach_written_ms",
                "attach_visible_ms",
                "text_behind_attach_visible_ms",
                "queue_attach_visible_ms",
                "queue_text_beside_attach_visible_ms",
            ];
            emit_skip(&k, &legs, &why);
        }
        for i in 0..sends {
            let k =
                Key { profile: &label, phase: "attach", scale: row, run: i, seed: seed_base + i };
            if inline_fits {
                inline_legs(
                    &mut link,
                    upload_link.as_mut(),
                    addr,
                    &listener.token,
                    &session,
                    &k,
                    &format!("{row}-{tag}-{i}"),
                    &mut last,
                    bound,
                    bytes,
                )
                .await;
                // As before: a run with no uploader link of its own sends nothing more.
                if upload_link.is_none() {
                    continue;
                }
            }

            // The phone's send by reference (AcpmuxHub `sendPrompt`): the image's bytes go up as
            // an acpmux prompt upload on the one connection, a chunk at a time, and the text,
            // tapped at the same instant, is written as soon as the outbox hands it out: behind
            // at most the chunk already on the wire, not behind the whole image. Its prompt names
            // the upload once the last chunk is in (docs/prompt-uploads.md).
            let image_id = format!("img-u-{row}-{tag}-{i}");
            let text_id = format!("txt-u-{row}-{tag}-{i}");
            let tap = Instant::now();
            let (image, text) =
                upload_leg(&mut link, &session, &image_id, &text_id, &mut last, tap, bytes).await;
            emit(&k, "upload_attach_visible_ms", image);
            emit(&k, "upload_text_beside_attach_visible_ms", text);
            slowest = slowest.max(image.unwrap_or(0.0)).max(text.unwrap_or(0.0));
            missed += u64::from(image.is_none()) + u64::from(text.is_none());
            if image.is_none() {
                emit_error(&k, "upload_attach_visible_ms", "the referenced image did not show");
            }
            if text.is_none() {
                emit_error(&k, "upload_text_beside_attach_visible_ms", "the text did not show");
            }
            tokio::time::sleep(Duration::from_millis(400)).await;
            link.pending.clear();
        }
        eprintln!(
            "netcond: attach row {row}: {sends} runs of {bytes} B in {:?} (no row limit); each upload send's bound {bound:?}, slowest {:.1}s, {missed} over it; the control connection read and dropped {} notification bytes",
            row_started.elapsed(),
            slowest / 1000.0,
            control.dropped_bytes() - dropped_before
        );
    }
}

/// The two inline legs of one attach run: the image as base64 in the prompt, then the text tapped
/// at the same instant behind it; and the same pair through the one Rust send queue, the image on
/// the uploader's own link. `run` names the run's prompt ids.
#[allow(clippy::too_many_arguments)]
async fn inline_legs(
    link: &mut Link,
    upload_link: Option<&mut Link>,
    addr: std::net::SocketAddr,
    token: &str,
    session: &str,
    k: &Key<'_>,
    run: &str,
    last: &mut u64,
    bound: Duration,
    bytes: usize,
) {
    let image_id = format!("img-{run}");
    let text_id = format!("txt-{run}");
    let tap = Instant::now();
    let build = |resend: bool| image_prompt(session, "photo", &image_id, resend, bytes);
    let mut written = None;
    let (visible, _) = chat_send_with(
        link,
        addr,
        token,
        session,
        &image_id,
        last,
        tap,
        bound,
        &build,
        &mut written,
    )
    .await;
    emit(k, "attach_written_ms", written);
    emit(k, "attach_visible_ms", visible);
    if visible.is_none() {
        emit_error(k, "attach_visible_ms", "the image prompt's user_message did not show");
    }
    // The text, tapped at the same instant, goes once the image has been written.
    let text_build = |resend: bool| prompt_params(session, "after", &text_id, resend);
    let (text_visible, _) = chat_send_with(
        link,
        addr,
        token,
        session,
        &text_id,
        last,
        tap,
        bound,
        &text_build,
        &mut None,
    )
    .await;
    emit(k, "text_behind_attach_visible_ms", text_visible);
    if text_visible.is_none() {
        emit_error(k, "text_behind_attach_visible_ms", "the text did not show");
    }
    tokio::time::sleep(Duration::from_millis(400)).await;
    link.pending.clear();

    // The same pair through the one Rust send queue (`cmux_composer_send::chat`): the image's
    // bytes go up beside the queue (the uploader; here the same blob written on a second
    // connection through the same shaped radio), and the text, tapped at the same instant, goes
    // as soon as the queue hands it out. It shares the radio with the upload.
    let Some(upload_link) = upload_link else { return };
    let image_id = format!("img-q-{run}");
    let text_id = format!("txt-q-{run}");
    let tap = Instant::now();
    let mut outbox = PromptOutbox::new(chat::DEFAULT_HOLD, k.seed);
    let std_tap = tap.into_std();
    outbox.set_link(true, std_tap);
    outbox.push(&image_id, "photo", vec![image_id.clone()], false, std_tap, std_tap);
    outbox.push(&text_id, "after", vec![], false, std_tap, std_tap);
    let first = outbox.next_request(std::time::Instant::now()).map(|r| r.id);
    assert_eq!(first.as_deref(), Some(text_id.as_str()), "the text waits on no upload");
    outbox.wrote(&text_id);
    let build = |resend: bool| image_prompt(session, "photo", &image_id, resend, bytes);
    let text_build = |resend: bool| prompt_params(session, "after", &text_id, resend);
    let mut upload_last = *last;
    let (mut upload_written, mut text_written) = (None, None);
    let (upload, text) = tokio::join!(
        chat_send_with(
            upload_link,
            addr,
            token,
            session,
            &image_id,
            &mut upload_last,
            tap,
            bound,
            &build,
            &mut upload_written,
        ),
        chat_send_with(
            link,
            addr,
            token,
            session,
            &text_id,
            last,
            tap,
            bound,
            &text_build,
            &mut text_written,
        ),
    );
    *last = (*last).max(upload_last);
    emit(k, "queue_attach_visible_ms", upload.0);
    emit(k, "queue_text_beside_attach_visible_ms", text.0);
    if upload.0.is_none() {
        emit_error(k, "queue_attach_visible_ms", "the image prompt's user_message did not show");
    }
    if text.0.is_none() {
        emit_error(k, "queue_text_beside_attach_visible_ms", "the text did not show");
    }
    tokio::time::sleep(Duration::from_millis(400)).await;
    link.pending.clear();
    upload_link.pending.clear();
}

/// A photo keeps the send's bound and its inline legs; a video's bound grows with its bytes and
/// its inline prompt is over the WebSocket cap (it skips those legs, naming the cap).
#[test]
fn attach_bound_and_inline_cap_by_size() {
    if std::env::var_os("NETCOND_SEND_BOUND_S").is_some() {
        return;
    }
    let inline = |bytes| {
        request_bytes(method::SESSION_PROMPT, &image_prompt("s", "photo", "p", true, bytes))
    };
    for photo in [286_107, 5 << 20] {
        assert_eq!(attach_bound(photo), send_bound(), "{photo} B keeps the send's bound");
        assert!(inline(photo) <= WS_MAX_MESSAGE_BYTES, "{photo} B goes inline");
    }
    for (video, at_least) in [(62_000_000, 200), (170_000_000, 600)] {
        assert!(attach_bound(video) >= Duration::from_secs(at_least), "{video} B");
        assert!(inline(video) > WS_MAX_MESSAGE_BYTES, "{video} B is over the cap");
    }
}

/// The phone's image bytes in one upload chunk (`file_uploads::CHUNK_BYTES`, AcpmuxHub's).
const UPLOAD_CHUNK: usize = 512 << 10;

/// `Link::post`, given up at `deadline`.
async fn post_by(
    link: &mut Link,
    m: &str,
    params: Value,
    deadline: Instant,
) -> Result<i64, String> {
    tokio::time::timeout_at(deadline, link.post(m, params))
        .await
        .unwrap_or_else(|_| Err(format!("{m}: past the send's bound")))
}

/// One image sent by reference beside a text on the same link, as the phone does it: begin, the
/// first chunk, the text (the outbox hands it out at once: it waits on no upload), the rest of
/// the chunks one in flight, finish, then the prompt naming the upload. Returns the ms from the
/// tap to each one's `user_message` (image, text); None when it did not show in the bound.
async fn upload_leg(
    link: &mut Link,
    session: &str,
    image_id: &str,
    text_id: &str,
    last: &mut u64,
    tap: Instant,
    bytes: usize,
) -> (Option<f64>, Option<f64>) {
    use base64::Engine as _;
    let deadline = tap + attach_bound(bytes);
    let blob: Vec<u8> = (0..bytes).map(|i| (i.wrapping_mul(2654435761) >> 13) as u8).collect();
    let name = "photo.png";
    let begin = json!({"sessionId": session, "fileName": name, "size": bytes, "forPrompt": true});
    let Ok(begin) = post_by(link, method::MUX_FILE_PUT_BEGIN, begin, deadline).await else {
        return (None, None);
    };
    let Ok((_, began)) = link.answer(begin, deadline).await else { return (None, None) };
    let (Some(upload), owner) = (
        began["uploadId"].as_str().map(str::to_owned),
        began["ownerToken"].as_str().map(str::to_owned),
    ) else {
        return (None, None);
    };
    let chunk = |offset: usize| {
        let end = (offset + UPLOAD_CHUNK).min(bytes);
        let data = base64::engine::general_purpose::STANDARD.encode(&blob[offset..end]);
        (end, json!({"sessionId": session, "uploadId": upload, "offset": offset, "data": data}))
    };
    let (mut sent_to, first) = chunk(0);
    let Ok(mut waiting) = post_by(link, method::MUX_FILE_PUT_CHUNK, first, deadline).await else {
        return (None, None);
    };
    // Every write waits at most until the bound too: a write the shaped link holds past it is a
    // miss, not a send that shows later with a value over its bound.
    let text = prompt_params(session, "after", text_id, false);
    if post_by(link, method::SESSION_PROMPT, text, deadline).await.is_err() {
        return (None, None);
    }
    let (mut image, mut text) = (None, None);
    let (mut finish, mut referenced) = (None, None);
    // Notifications that came while the begin's answer was read.
    let early: Vec<(Instant, Value)> = link.pending.drain(..).collect();
    for (at, v) in early {
        if is_echo(&v, text_id) && at <= deadline {
            text = Some(ms(at - tap));
        }
    }
    while image.is_none() || text.is_none() {
        let Next::Frame(at, v) = link.frame(deadline).await else { break };
        if at > deadline {
            break;
        }
        if v.get("method").is_some() {
            if let Some(seq) = event_seq(&v) {
                *last = (*last).max(seq);
            }
            if is_echo(&v, text_id) {
                text = Some(ms(at - tap));
            }
            if is_echo(&v, image_id) {
                image = Some(ms(at - tap));
            }
            continue;
        }
        let id = v.get("id").and_then(Value::as_i64);
        if id.is_some() && id == Some(waiting) && finish.is_none() {
            if v.get("error").is_some() {
                break;
            }
            if sent_to < bytes {
                let (end, next) = chunk(sent_to);
                sent_to = end;
                let Ok(posted) = post_by(link, method::MUX_FILE_PUT_CHUNK, next, deadline).await
                else {
                    break;
                };
                waiting = posted;
            } else {
                let params = json!({"sessionId": session, "uploadId": upload, "fileName": name, "size": bytes});
                let Ok(posted) = post_by(link, method::MUX_FILE_PUT_FINISH, params, deadline).await
                else {
                    break;
                };
                finish = Some(posted);
            }
        } else if id.is_some() && id == finish {
            if v.get("error").is_some() {
                break;
            }
            let mut reference = json!({"uploadId": upload, "fileName": name});
            if let Some(owner) = &owner {
                reference["owned"] = json!(owner);
            }
            let params = json!({"sessionId": session,
                "prompt": [{"type": "text", "text": "photo"},
                           {"type": "image", "name": name, "_meta": {"acpmux": {"upload": reference}}}],
                "_meta": {"acpmux": {"promptId": image_id, "steer": false, "resend": false}}});
            let Ok(posted) = post_by(link, method::SESSION_PROMPT, params, deadline).await else {
                break;
            };
            finish = None;
            referenced = Some(posted);
            waiting = -1;
        } else if id.is_some() && id == referenced && v.get("error").is_some() {
            if std::env::var_os("NETCOND_DEBUG").is_some() {
                eprintln!("netcond-debug the reference prompt was refused: {v}");
            }
            break;
        }
    }
    (image, text)
}

// ---------------------------------------------------------------------------------------------
// Cancel mid-send (Leo, 2026-11-24 08:29Z: "i also couldnt cancel out of the send. i need to be
// able to do that otherwise i cant edit or anything to retry or delete and remove."). The phone
// taps Send on a text with a large attachment (NETCOND_CANCEL_BYTES, 100 MiB), its bytes go up a
// chunk at a time as AcpmuxHub's prompt upload does (one in flight), and once
// NETCOND_CANCEL_AFTER bytes are on the Mac the person taps Stop on the pending bubble: the Rust
// outbox (`PromptOutbox::cancel`) hands the draft back and names the upload to cancel, and the
// phone sends `_acpmux/file_put_cancel` with its owner token. A late chunk for the same upload
// follows (the one a slow uploader still had queued) to check the Mac takes no more bytes.
// Metrics, phase `cancel`, scale = the row (lte, duress: lte with a loaded Mac):
// - `cancel_tap_to_cancelled_ms`: the tap to the Mac's answer to the cancel (the upload gone).
// - `cancel_bytes_after`: bytes the Mac accepted after it answered the cancel (want 0).
// - `cancel_inflight_bytes`: the chunk already on the wire at the tap that the Mac took.
// - `cancel_draft_restored`: 1 when the outbox gave back the draft's text and attachment and
//   named the upload to cancel, else 0.
// Env: `NETCOND_CANCEL_SENDS` (20), `NETCOND_CANCEL_ROWS` (lte,duress).

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "the cancel bench: cargo test -p acpmux --test mobile_link_conditions chat_cancel -- --ignored"]
async fn chat_cancel_mid_upload_under_link_conditions() {
    let scratch = daemon_env::Scratch::new("netcond-cancel");
    let hub = hub(&scratch.path().join("home"));
    let listener = app_ws::listen(&hub).await;
    let upstream: std::net::SocketAddr =
        listener.url.trim_start_matches("ws://").trim_end_matches('/').parse().unwrap();
    let file = match std::env::var("NETCOND_PROFILES_FILE") {
        Ok(p) if !p.is_empty() => ProfileFile::load(Path::new(&p)).unwrap(),
        _ => ProfileFile::builtin(),
    };
    let sends = env_u64("NETCOND_CANCEL_SENDS", 20);
    let bytes = env_u64("NETCOND_CANCEL_BYTES", 100 << 20) as usize;
    let after =
        (env_u64("NETCOND_CANCEL_AFTER", 2 << 20) as usize).min(bytes.saturating_sub(UPLOAD_CHUNK));
    let seed_base = env_u64("NETCOND_SEED_BASE", 0);
    let rows_wanted = env_list("NETCOND_CANCEL_ROWS", &["lte", "duress"]);
    let mut control = Control::new(&hub);
    let cwd = scratch.path().join("work");
    std::fs::create_dir_all(&cwd).unwrap();
    let trace = Trace::new();
    for row in &rows_wanted {
        let (profile, loaded) = match row.as_str() {
            "idle" => (None, false),
            "duress" => (file.get("lte").cloned(), true),
            other => (file.get(other).cloned(), false),
        };
        let label = profile.as_ref().map_or_else(|| "none".to_owned(), |p| p.label(None));
        let made = control
            .call(
                method::SESSION_NEW,
                json!({"cwd": cwd, "mcpServers": [], "_meta": {"acpmux": {"name": format!("cancel-{row}")}}}),
            )
            .await;
        let session = made["result"]["sessionId"].as_str().unwrap().to_owned();
        let _spin = if loaded {
            control.seed(&session, 0, 100).await;
            let other = control
                .call(
                    method::SESSION_NEW,
                    json!({"cwd": cwd, "mcpServers": [], "_meta": {"acpmux": {"name": "cancel-stream"}}}),
                )
                .await;
            let other = other["result"]["sessionId"].as_str().unwrap().to_owned();
            let _ = control.prompt(&other, "ticking:6000:20").await;
            Some(Spin::start())
        } else {
            control.seed(&session, 0, BASE_TURNS).await;
            None
        };
        let shaper = match &profile {
            Some(p) => Shaper::start(upstream, p.clone(), seed_base, &trace).await.ok(),
            None => None,
        };
        let addr = shaper.as_ref().map_or(upstream, Shaper::addr);
        let opened = Instant::now() + BOUND;
        let Ok(mut link) = Link::open(addr, &listener.token, opened).await else {
            let k = Key { profile: &label, phase: "cancel", scale: row, run: 0, seed: seed_base };
            emit_error(&k, "cancel_tap_to_cancelled_ms", "the link did not open");
            continue;
        };
        let _ = link.attach(&session, None, opened).await;
        let tag = std::process::id();
        let row_started = Instant::now();
        for i in 0..sends {
            let k =
                Key { profile: &label, phase: "cancel", scale: row, run: i, seed: seed_base + i };
            match cancel_leg(
                &mut link,
                &session,
                &format!("cancel-{row}-{tag}-{i}"),
                bytes,
                after,
                k.seed,
            )
            .await
            {
                Ok(r) => {
                    emit(&k, "cancel_tap_to_cancelled_ms", Some(r.tap_to_cancelled_ms));
                    emit(&k, "cancel_bytes_after", Some(r.bytes_after as f64));
                    emit(&k, "cancel_inflight_bytes", Some(r.inflight_bytes as f64));
                    emit(&k, "cancel_draft_restored", Some(if r.restored { 1.0 } else { 0.0 }));
                }
                Err(why) => emit_error(&k, "cancel_tap_to_cancelled_ms", &why),
            }
            link.pending.clear();
        }
        eprintln!(
            "netcond: cancel row {row}: {sends} cancels of a {bytes} B upload after {after} B in {:?}",
            row_started.elapsed()
        );
    }
}

struct CancelRun {
    tap_to_cancelled_ms: f64,
    bytes_after: u64,
    inflight_bytes: u64,
    restored: bool,
}

/// The bytes of a synthetic attachment at `[from, to)`, as base64 (made per chunk: a 100 MiB
/// file is never held whole).
fn synthetic_chunk(from: usize, to: usize) -> String {
    use base64::Engine as _;
    let data: Vec<u8> = (from..to).map(|i| (i.wrapping_mul(2654435761) >> 13) as u8).collect();
    base64::engine::general_purpose::STANDARD.encode(data)
}

/// One cancel run: begin, chunks one in flight until `after` bytes are on the Mac, the next chunk
/// posted, then the tap: the outbox's Stop, the Mac's cancel, and a late chunk.
async fn cancel_leg(
    link: &mut Link,
    session: &str,
    prompt_id: &str,
    bytes: usize,
    after: usize,
    seed: u64,
) -> Result<CancelRun, String> {
    let deadline = Instant::now() + attach_bound(after + 2 * UPLOAD_CHUNK) + BOUND;
    let name = "video.mov";
    let begin = json!({"sessionId": session, "fileName": name, "size": bytes, "forPrompt": true});
    let begin = link.post(method::MUX_FILE_PUT_BEGIN, begin).await?;
    let (_, began) = link.answer(begin, deadline).await?;
    let upload = began["uploadId"].as_str().ok_or("begin named no uploadId")?.to_owned();
    let owner = began["ownerToken"].as_str().map(str::to_owned);

    // The tap on Send: the draft goes into the one send queue, waiting on its upload.
    let draft = format!("draft {prompt_id}");
    let mut outbox = PromptOutbox::new(chat::DEFAULT_HOLD, seed);
    let sent_at = std::time::Instant::now();
    outbox.set_link(true, sent_at);
    outbox.push(prompt_id, &draft, vec![upload.clone()], false, sent_at, sent_at);

    let chunk = |offset: usize| {
        let end = (offset + UPLOAD_CHUNK).min(bytes);
        let params = json!({"sessionId": session, "uploadId": upload, "offset": offset,
                            "data": synthetic_chunk(offset, end)});
        (end, params)
    };
    let mut sent_to = 0;
    while sent_to < after {
        let (end, params) = chunk(sent_to);
        let id = link.post(method::MUX_FILE_PUT_CHUNK, params).await?;
        link.answer(id, deadline).await?;
        outbox.upload_progressed(&upload, std::time::Instant::now());
        sent_to = end;
    }
    // The next chunk is on the wire when the person taps Stop.
    let (inflight_end, params) = chunk(sent_to);
    let inflight = link.post(method::MUX_FILE_PUT_CHUNK, params).await?;
    let inflight_len = (inflight_end - sent_to) as u64;

    let tap = Instant::now();
    let restored = match outbox.cancel(prompt_id) {
        Some(chat::CancelStep::Returned(done)) => {
            done.outcome == chat::PromptOutcome::Cancelled
                && done.text == draft
                && done.attachments.iter().any(|a| a.id == upload)
                && done.cancel_uploads.contains(&upload)
                && outbox.pending(std::time::Instant::now()).is_empty()
        }
        _ => false,
    };
    let mut cancel = json!({"sessionId": session, "uploadId": upload});
    if let Some(owner) = &owner {
        cancel["ownerToken"] = json!(owner);
    }
    let cancel = link.post(method::MUX_FILE_PUT_CANCEL, cancel).await?;
    let inflight_bytes =
        if link.answer(inflight, deadline).await.is_ok() { inflight_len } else { 0 };
    let (cancelled_at, _) = link.answer(cancel, deadline).await?;
    let tap_to_cancelled_ms = ms(cancelled_at - tap);

    // A late chunk (and the one after it) for the cancelled upload: the Mac must refuse both.
    let mut bytes_after = 0;
    let mut offset = inflight_end;
    for _ in 0..2 {
        if offset >= bytes {
            break;
        }
        let (end, params) = chunk(offset);
        let id = link.post(method::MUX_FILE_PUT_CHUNK, params).await?;
        if link.answer(id, deadline).await.is_ok() {
            bytes_after += (end - offset) as u64;
        }
        offset = end;
    }
    Ok(CancelRun { tap_to_cancelled_ms, bytes_after, inflight_bytes, restored })
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
            fields.sort_by_key(|f| std::cmp::Reverse(f.1));
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

// ---------------------------------------------------------------------------------------------
// The chat list on a reconnect and a pull to refresh: whole read (before) vs follow (after)
//
// Leo, 2026-11-26: "if im on cellular connection and it's some low tier 5g that bounces to lte or
// i get into an elevator ... i should still be getting things fast and responsive and flowing,
// even on ostensibly infinitely long chats." Contract point 3 (delta sync) for the list stream.
//
// A Mac with N closed chats (`NETCOND_LIST_NS`, default 100,1000,10000). The phone read the whole
// list once (unshaped); then `NETCOND_LIST_CHANGED` (default 1,10) chats are renamed. Each row
// (`NETCOND_LIST_ROWS`: lte, lossy-3, duress = lte with every core spinning) measures, through
// the shaper:
// - `reconnect`: before, the app's `initialize` + `_acpmux/watch {limit: 100}` then the rest in
//   `_acpmux/sessions {cursor, limit: 500}` pages (`AcpmuxHub+SessionPages.swift`); after,
//   `initialize` + `_acpmux/watch {afterSeq, listEpoch, limit: 100}` (`AcpmuxHub+ListFollow.swift`),
//   following again while `more`.
// - `refresh`: on an open link, before `_acpmux/watch {enabled}` and `_acpmux/sessions` pages
//   (`LiveFeed.refresh` via `wholeList`); after one follow from the cursor.
// Metrics (phase `list_reconnect_before|after`, `list_refresh_before|after`, scale `N/changed`):
// `bytes_down`, `round_trips`, `caught_up_ms` (link up, or the refresh asked, to the list held
// whole), `duplicates` (a row twice in one read), `holes` (held rows that differ from the Mac's
// list read afterward, by id and name). The test asserts after costs flat in N (within 1.2x from
// the smallest N to the largest, bytes) and 0 duplicates and holes.

const LATER_PAGE_ROWS: u64 = 500;

fn list_hub(home: &Path, chats: usize) -> Arc<Hub> {
    acpmux::config::set_home_override(home.to_path_buf());
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE], "family": "codex"}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    for i in 0..chats {
        let meta: acpmux::store::SessionMeta = serde_json::from_value(json!({
            "schema": acpmux::store::META_SCHEMA, "id": format!("chat-{i:05}"),
            "name": format!("chat {i}"), "harness": "fake", "cwd": format!("/work/{}", i % 40),
            "status": "idle", "createdAt": i + 1, "updatedAt": i + 1
        }))
        .unwrap();
        store.save(&meta).unwrap();
    }
    Hub::new(cfg, store)
}

/// The phone's list: rows by id, the cursor, and what a read saw twice.
#[derive(Default)]
struct PhoneList {
    rows: std::collections::HashMap<String, Value>,
    seq: Option<u64>,
    epoch: Option<String>,
    duplicates: u64,
}

impl PhoneList {
    fn take(&mut self, rows: &[Value], seen: &mut std::collections::HashSet<String>) {
        for row in rows {
            let Some(id) = row["sessionId"].as_str() else { continue };
            if !seen.insert(id.to_owned()) {
                self.duplicates += 1;
            }
            self.rows.insert(id.to_owned(), row.clone());
        }
    }

    fn rows_of(reply: &Value) -> Vec<Value> {
        reply["sessions"].as_array().cloned().unwrap_or_default()
    }

    /// A whole read: `first` is the watch's reply, then pages on `link`. Rows it does not list go.
    /// `paged`: the watch had a `limit`, so later pages are row pages of [`LATER_PAGE_ROWS`]
    /// (`readRest`); else they are byte pages with only the cursor (`wholeList`).
    async fn whole(
        &mut self,
        link: &mut Link,
        first: Value,
        paged: bool,
        deadline: Instant,
    ) -> Result<(), String> {
        let mut seen = std::collections::HashSet::new();
        let mut next = Vec::new();
        let rows = Self::rows_of(&first);
        self.take(&rows, &mut seen);
        next.extend(rows);
        self.seq = first["listSeq"].as_u64();
        self.epoch = first["listEpoch"].as_str().map(str::to_owned);
        let mut cursor = first["nextCursor"].as_str().map(str::to_owned);
        while let Some(c) = cursor {
            let id = link
                .post(
                    "_acpmux/sessions",
                    if paged {
                        json!({"cursor": c, "limit": LATER_PAGE_ROWS})
                    } else {
                        json!({"cursor": c})
                    },
                )
                .await?;
            let (_, page) = link.answer(id, deadline).await?;
            let rows = Self::rows_of(&page);
            self.take(&rows, &mut seen);
            next.extend(rows);
            cursor = page["nextCursor"].as_str().map(str::to_owned);
        }
        self.rows.retain(|id, _| seen.contains(id));
        Ok(())
    }

    fn follow_params(&self) -> Value {
        json!({"enabled": true, "limit": WATCH_LIMIT, "afterSeq": self.seq, "listEpoch": self.epoch})
    }

    /// Lays a follow reply over the rows; Err when it is not a follow. Returns `more`.
    fn lay(&mut self, reply: &Value) -> Result<bool, String> {
        if reply["follow"] != json!(true) {
            return Err(format!("not a follow: reset={}", reply["reset"]));
        }
        let mut seen = std::collections::HashSet::new();
        self.take(&Self::rows_of(reply), &mut seen);
        for gone in reply["gone"].as_array().into_iter().flatten() {
            if let Some(id) = gone["sessionId"].as_str() {
                self.rows.remove(id);
            }
        }
        self.seq = reply["listSeq"].as_u64().max(self.seq);
        Ok(reply["more"] == json!(true))
    }

    async fn follow(
        &mut self,
        link: &mut Link,
        first: Value,
        deadline: Instant,
    ) -> Result<(), String> {
        let mut more = self.lay(&first)?;
        while more {
            let id = link.post("_acpmux/watch", self.follow_params()).await?;
            let (_, reply) = link.answer(id, deadline).await?;
            more = self.lay(&reply)?;
        }
        Ok(())
    }

    /// Held rows that differ from `truth` by id or name.
    fn holes(&self, truth: &std::collections::HashMap<String, Value>) -> u64 {
        let missing = truth
            .iter()
            .filter(|(id, row)| self.rows.get(*id).map(|r| &r["name"]) != Some(&row["name"]))
            .count();
        let extra = self.rows.keys().filter(|id| !truth.contains_key(*id)).count();
        (missing + extra) as u64
    }
}

/// `initialize` (as the app sends it) and a watch with `watch`, through `addr`.
async fn list_open(
    addr: std::net::SocketAddr,
    token: &str,
    watch: Value,
    deadline: Instant,
) -> Result<(Link, Instant, Value), String> {
    let mut link = tokio::time::timeout_at(deadline, Link::dial(addr))
        .await
        .map_err(|_| "connect timed out".to_owned())??;
    let up = Instant::now();
    let init = link
        .post(
            "initialize",
            json!({"protocolVersion": 1, "clientInfo": {"name": "cmux-ios", "version": "1"},
                   "clientCapabilities": {},
                   "_meta": {"acpmux": {"localAppToken": token, "omitTimeBreakdown": true}}}),
        )
        .await?;
    let watch = link.post("_acpmux/watch", watch).await?;
    let (_, init) = link.answer(init, deadline).await?;
    link.capabilities = init
        .pointer("/_meta/acpmux/capabilities")
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(Value::as_str).map(str::to_owned).collect())
        .unwrap_or_default();
    let (_, reply) = link.answer(watch, deadline).await?;
    Ok((link, up, reply))
}

/// The Mac's whole list, read unshaped.
async fn list_truth(
    addr: std::net::SocketAddr,
    token: &str,
) -> std::collections::HashMap<String, Value> {
    let deadline = Instant::now() + BOUND;
    let (mut link, _, first) =
        list_open(addr, token, json!({"enabled": true, "limit": WATCH_LIMIT}), deadline)
            .await
            .unwrap();
    let mut list = PhoneList::default();
    list.whole(&mut link, first, true, deadline).await.unwrap();
    list.rows
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "the list follow bench: run with --ignored --nocapture"]
async fn chat_list_reconnect_and_refresh_whole_vs_follow() {
    let _ = HERMETIC;
    let file = ProfileFile::builtin();
    let ns: Vec<usize> = env_list("NETCOND_LIST_NS", &["100", "1000", "10000"])
        .iter()
        .map(|n| n.parse().unwrap())
        .collect();
    let changes: Vec<usize> =
        env_list("NETCOND_LIST_CHANGED", &["1", "10"]).iter().map(|n| n.parse().unwrap()).collect();
    let rows_wanted = env_list("NETCOND_LIST_ROWS", &["lte", "lossy-3", "duress"]);
    let trace = Trace::new();
    // (row, changed, phase) -> [(n, bytes_down)]
    let mut after: std::collections::BTreeMap<(String, usize, &str), Vec<(usize, u64)>> =
        Default::default();
    let mut bad = Vec::new();
    for &n in &ns {
        let scratch = daemon_env::Scratch::new("netcond-list");
        let hub = list_hub(&scratch.path().join("home"), n);
        let listener = app_ws::listen(&hub).await;
        let upstream: std::net::SocketAddr =
            listener.url.trim_start_matches("ws://").trim_end_matches('/').parse().unwrap();
        let mut control = Control::new(&hub);
        let mut renamed = 0usize;
        for row in &rows_wanted {
            let (profile, loaded) = match row.as_str() {
                "lte" => (file.get("lte").unwrap().clone(), false),
                "lossy-3" => (file.get("lossy-3").unwrap().clone(), false),
                "duress" => (file.get("lte").unwrap().clone(), true),
                other => panic!("NETCOND_LIST_ROWS: no row {other}"),
            };
            for &k in &changes {
                let scale = format!("{n}/{k}");
                for (phase_before, phase_after, refresh) in [
                    ("list_reconnect_before", "list_reconnect_after", false),
                    ("list_refresh_before", "list_refresh_after", true),
                ] {
                    for (phase, follows) in [(phase_before, false), (phase_after, true)] {
                        let key = Key { profile: row, phase, scale: &scale, run: 0, seed: 0 };
                        // The phone held the whole list (its first connection), unshaped.
                        let deadline = Instant::now() + BOUND * 4;
                        let (mut first, _, page) = list_open(
                            upstream,
                            &listener.token,
                            json!({"enabled": true, "limit": WATCH_LIMIT}),
                            deadline,
                        )
                        .await
                        .unwrap();
                        let mut list = PhoneList::default();
                        list.whole(&mut first, page, true, deadline).await.unwrap();
                        assert!(
                            first.capabilities.iter().any(|c| c == "session-list-follow-v1"),
                            "the daemon follows the list"
                        );
                        drop(first);
                        let shaper =
                            Shaper::start(upstream, profile.clone(), 0, &trace).await.unwrap();
                        let spin = loaded.then(Spin::start);
                        let mut want: Vec<(String, String)> = Vec::new();
                        let measured: Result<(u64, u64, f64), String> = async {
                            let (bytes0, turns0, took);
                            if refresh {
                                // Open through the shaper as the app does (a follow: the hub
                                // held the list), then the chats change, then the refresh.
                                let (mut link, _, reply) = list_open(
                                    shaper.addr(),
                                    &listener.token,
                                    list.follow_params(),
                                    deadline,
                                )
                                .await?;
                                list.follow(&mut link, reply, deadline).await?;
                                for _ in 0..k {
                                    renamed += 1;
                                    let id = format!("chat-{:05}", renamed % n);
                                    let name = format!("renamed-{renamed}");
                                    let answer = control
                                        .call(
                                            method::MUX_RENAME,
                                            json!({"sessionId": id, "newName": name}),
                                        )
                                        .await;
                                    assert!(answer.get("error").is_none(), "rename {id}: {answer}");
                                    want.push((id, name));
                                }
                                // The notices land before the refresh is counted.
                                link.drain(Instant::now() + Duration::from_millis(1500)).await;
                                let c = shaper.counters();
                                (bytes0, turns0) = (c.down_bytes, c.up_turns);
                                let asked = Instant::now();
                                if follows {
                                    let id =
                                        link.post("_acpmux/watch", list.follow_params()).await?;
                                    let (_, reply) = link.answer(id, deadline).await?;
                                    list.follow(&mut link, reply, deadline).await?;
                                } else {
                                    let id = link
                                        .post("_acpmux/watch", json!({"enabled": true}))
                                        .await?;
                                    let (_, reply) = link.answer(id, deadline).await?;
                                    list.whole(&mut link, reply, false, deadline).await?;
                                }
                                took = asked.elapsed();
                            } else {
                                for _ in 0..k {
                                    renamed += 1;
                                    let id = format!("chat-{:05}", renamed % n);
                                    let name = format!("renamed-{renamed}");
                                    let answer = control
                                        .call(
                                            method::MUX_RENAME,
                                            json!({"sessionId": id, "newName": name}),
                                        )
                                        .await;
                                    assert!(answer.get("error").is_none(), "rename {id}: {answer}");
                                    want.push((id, name));
                                }
                                (bytes0, turns0) = (0, 0);
                                let watch = if follows {
                                    list.follow_params()
                                } else {
                                    json!({"enabled": true, "limit": WATCH_LIMIT})
                                };
                                let (mut link, up, reply) =
                                    list_open(shaper.addr(), &listener.token, watch, deadline)
                                        .await?;
                                if follows {
                                    list.follow(&mut link, reply, deadline).await?;
                                } else {
                                    list.whole(&mut link, reply, true, deadline).await?;
                                }
                                took = up.elapsed();
                            }
                            let c = shaper.counters();
                            Ok((c.down_bytes - bytes0, c.up_turns - turns0, ms(took)))
                        }
                        .await;
                        drop(spin);
                        let truth = list_truth(upstream, &listener.token).await;
                        for (id, name) in &want {
                            assert_eq!(truth[id]["name"], json!(name), "the Mac renamed {id}");
                        }
                        match measured {
                            Ok((bytes, turns, ms)) => {
                                let holes = list.holes(&truth);
                                emit(&key, "bytes_down", Some(bytes as f64));
                                emit(&key, "round_trips", Some(turns as f64));
                                emit(&key, "caught_up_ms", Some(ms));
                                emit(&key, "duplicates", Some(list.duplicates as f64));
                                emit(&key, "holes", Some(holes as f64));
                                if list.duplicates > 0 || holes > 0 {
                                    bad.push(format!(
                                        "{row} {phase} {scale}: {} duplicates, {holes} holes",
                                        list.duplicates
                                    ));
                                }
                                if follows {
                                    after
                                        .entry((row.clone(), k, phase))
                                        .or_default()
                                        .push((n, bytes));
                                }
                            }
                            Err(why) => {
                                emit_error(&key, "caught_up_ms", &why);
                                bad.push(format!("{row} {phase} {scale}: {why}"));
                            }
                        }
                    }
                }
            }
        }
    }
    for ((row, k, phase), by_n) in &after {
        let (Some(small), Some(large)) = (by_n.first(), by_n.last()) else { continue };
        if small.0 == large.0 {
            continue;
        }
        let ratio = large.1 as f64 / small.1.max(1) as f64;
        eprintln!(
            "netcond-list: {row} {phase} changed={k}: bytes {} at {} -> {} at {} ({ratio:.2}x)",
            small.1, small.0, large.1, large.0
        );
        if ratio > 1.2 {
            bad.push(format!("{row} {phase} changed={k}: after grew {ratio:.2}x in N"));
        }
    }
    assert!(bad.is_empty(), "{bad:#?}");
}

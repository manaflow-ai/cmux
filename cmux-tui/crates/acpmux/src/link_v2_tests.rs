use super::*;
use crate::rpc::{Message, method};
use acpmux_book::index::Summary;
use acpmux_client::wire::{ListView, Sub};
use acpmux_client::{Change, Client};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::watch;

const WAIT: Duration = Duration::from_secs(20);

/// A small deterministic generator: the random runs replay from their seed.
struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
    fn below(&mut self, n: u64) -> u64 {
        self.next() % n.max(1)
    }
}

fn encoded(kind: u8, payload: &[u8]) -> Vec<u8> {
    let mut out = ((1 + payload.len()) as u32).to_be_bytes().to_vec();
    out.push(kind);
    out.extend_from_slice(payload);
    out
}

#[test]
fn a_frame_line_has_the_documented_form_and_is_read_back_without_a_value() {
    let payload = br#"{"sid":"s","ops":[{"op":"gone","seq":3}]}"#;
    let line = frame_line(3, payload).unwrap();
    assert_eq!(
        line,
        "{\"jsonrpc\":\"2.0\",\"method\":\"_acpmux/v2\",\"params\":{\"kind\":3,\"payload\":{\"sid\":\"s\",\"ops\":[{\"op\":\"gone\",\"seq\":3}]}}}\n"
    );
    assert!(is_frame_line(&line));
    let incoming = parse(&line).unwrap();
    assert_eq!(incoming.kind, 3);
    assert_eq!(incoming.payload, payload);
    // A v1 line is never taken for a frame, and the same method in another shape is no frame.
    assert!(!is_frame_line(&Message::notification(method::MUX_V2, json!({})).to_line()));
    assert!(!is_frame_line(r#"{"jsonrpc":"2.0","id":1,"method":"_acpmux/v2","params":{}}"#));
    // A payload that is not JSON text has no form on a link.
    assert!(frame_line(5, &[0xff, 0x00]).is_err());
    assert!(frame_line(5, b"plain text").is_err());
    assert!(parse(&format!("{PREFIX}3,\"payload\":not json}}}}")).is_none());
}

/// 1,000 frames each way, with the connection, the link writer, the link reader and the
/// connection's reader each stalling at random: every frame arrives once, in order, and the
/// adapter never holds more than one frame toward the peer.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn no_frame_is_lost_or_reordered_across_random_stalls_of_either_end() {
    for seed in [1_u64, 7, 4242] {
        let slot = Slot::new(None);
        let (adapter, mut reader, mut writer) = Adapter::new(slot.clone());
        let frames: Vec<Vec<u8>> = (0..1_000_u32)
            .map(|n| {
                let body = format!("{{\"n\":{n},\"pad\":\"{}\"}}", "x".repeat((n % 97) as usize));
                encoded(3, body.as_bytes())
            })
            .collect();
        // Toward the peer: the connection writes in random chunks; the writer drains with stalls.
        let sent = frames.clone();
        let mut rng = Rng(seed);
        let connection = tokio::spawn(async move {
            let mut rng = Rng(seed ^ 0x9e37);
            let all: Vec<u8> = sent.concat();
            let mut at = 0;
            while at < all.len() {
                let n = (1 + rng.below(300) as usize).min(all.len() - at);
                writer.write_all(&all[at..at + n]).await.unwrap();
                at += n;
                if rng.below(10) == 0 {
                    tokio::task::yield_now().await;
                }
            }
        });
        let mut lines = Vec::new();
        while lines.len() < frames.len() {
            if rng.below(4) == 0 {
                tokio::time::sleep(Duration::from_micros(rng.below(200))).await;
            }
            lines.push(tokio::time::timeout(WAIT, slot.next()).await.expect("a frame line"));
        }
        connection.await.unwrap();
        for (line, frame) in lines.iter().zip(&frames) {
            let incoming = parse(line).unwrap();
            assert_eq!(encoded(incoming.kind, incoming.payload), *frame);
        }
        // From the peer: the link delivers with stalls; the connection reads in random chunks.
        let delivered = frames.clone();
        let link = tokio::spawn(async move {
            let mut rng = Rng(seed ^ 0x51);
            for frame in &delivered {
                let incoming = Incoming { kind: frame[4], payload: &frame[5..] };
                assert!(adapter.deliver(&incoming).await, "a running connection lost a frame");
                if rng.below(5) == 0 {
                    tokio::time::sleep(Duration::from_micros(rng.below(200))).await;
                }
            }
            adapter.close();
        });
        let mut read = Vec::new();
        let mut buf = vec![0_u8; 512];
        loop {
            let want = 1 + rng.below(511) as usize;
            let n =
                tokio::time::timeout(WAIT, reader.read(&mut buf[..want])).await.unwrap().unwrap();
            if n == 0 {
                break;
            }
            read.extend_from_slice(&buf[..n]);
            if rng.below(6) == 0 {
                tokio::time::sleep(Duration::from_micros(rng.below(200))).await;
            }
        }
        link.await.unwrap();
        assert_eq!(read, frames.concat());
    }
}

#[tokio::test]
async fn a_writer_that_stops_leaves_one_frame_in_the_slot_and_the_write_waits() {
    let slot = Slot::new(None);
    let (_adapter, _reader, mut writer) = Adapter::new(slot.clone());
    let first = encoded(3, br#"{"n":1}"#);
    let second = encoded(3, br#"{"n":2}"#);
    writer.write_all(&first).await.unwrap();
    assert!(slot.holds());
    let mut second_write = Box::pin(writer.write_all(&second));
    assert!(
        tokio::time::timeout(Duration::from_millis(50), &mut second_write).await.is_err(),
        "a second frame waits for the slot"
    );
    assert!(parse(&slot.take().unwrap()).unwrap().payload.ends_with(b"1}"));
    tokio::time::timeout(WAIT, second_write).await.unwrap().unwrap();
    assert!(parse(&slot.take().unwrap()).unwrap().payload.ends_with(b"2}"));
}

#[tokio::test]
async fn v1_goes_first_and_a_flood_delays_the_slot_by_at_most_a_burst() {
    let slot = Slot::new(None);
    let (tx, mut rx) = mpsc::channel(4096);
    for n in 0..1_000 {
        tx.send(format!("v1 {n}\n")).await.unwrap();
    }
    let (_adapter, _reader, mut writer) = Adapter::new(slot.clone());
    writer.write_all(&encoded(3, br#"{"n":1}"#)).await.unwrap();
    let mut streak = 0;
    let mut v1_before = 0;
    loop {
        let line = next_line(&mut rx, Some(&slot), &mut streak).await.unwrap();
        if is_frame_line(&line) {
            break;
        }
        v1_before += 1;
    }
    assert!(v1_before >= 1, "a v1 line waiting goes before the frame");
    assert!(v1_before <= V1_BURST as usize, "the frame waited {v1_before} v1 lines");
}

#[tokio::test]
async fn a_new_connection_refuses_the_old_ones_writes_and_drops_its_unsent_frame() {
    let shared = Arc::new(Shared::default());
    let slot = Slot::new(Some(shared.clone()));
    let (_first, _reader, mut old) = Adapter::new(slot.clone());
    old.write_all(&encoded(3, br#"{"old":1}"#)).await.unwrap();
    let (_second, _reader, _new) = Adapter::new(slot.clone());
    assert!(!slot.holds(), "the old connection's frame is not sent after the new hello");
    assert_eq!(shared.counters.stale.load(Ordering::Relaxed), 1);
    assert!(old.write_all(&encoded(3, br#"{"old":2}"#)).await.is_err());
    assert_eq!(shared.counters.held_bytes.load(Ordering::Relaxed), 0);
}

// ---- A link served by the daemon's own serve loop ----

pub(super) fn memory_hub() -> Arc<crate::hub::Hub> {
    let mut config = crate::config::Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    crate::hub::Hub::new(config, store)
}

/// `hub`'s v2 list with `list` and `peers` on, and its writer for the test to drive.
pub(super) fn peers_on(hub: &Arc<crate::hub::Hub>) -> acpmux_core::hub::HubWriter {
    let (core, writer) = acpmux_core::hub::Hub::new(acpmux_book::index::SummaryIndex::new());
    let surfaces = ["list", "peers"].into_iter().map(str::to_owned).collect();
    let v2 = Arc::new(acpmux_core::life::V2::with_surfaces(core, writer, surfaces));
    hub.link_v2.install(v2.clone());
    v2.take_writer().unwrap()
}

pub(super) fn v2_hub(hub: &crate::hub::Hub) -> Arc<acpmux_core::hub::Hub> {
    hub.link_v2.v2().unwrap().hub()
}

pub(super) fn row(origin: &str, id: &str, at: u64, state: &str) -> Summary {
    let mut summary = Summary::new(id);
    summary.origin = origin.into();
    summary.last_activity = at;
    summary.state = state.into();
    summary.harness = "claude".into();
    summary
}

/// The link between a dialer (the test) and the daemon: what the dialer sends, what the
/// daemon's link writer writes, and a switch that stops that writer.
pub(super) struct Wire {
    pub to_daemon: mpsc::Sender<String>,
    pub from_daemon: mpsc::Receiver<String>,
    pub stop_writer: watch::Sender<bool>,
    pub slot: Arc<Slot>,
    pub serving: tokio::task::JoinHandle<()>,
}

pub(super) fn link(hub: &Arc<crate::hub::Hub>) -> Wire {
    link_with(hub, |hub, inbound, out, slot| {
        tokio::spawn(crate::server::serve_peer_link(hub, inbound, out, slot))
    })
}

/// A connection that is not a link: served as a peer, with no slot.
fn not_a_link(hub: &Arc<crate::hub::Hub>) -> Wire {
    link_with(hub, |hub, inbound, out, _slot| {
        tokio::spawn(crate::server::serve_connection_with(
            hub,
            inbound,
            out,
            crate::server::Origin::Peer,
        ))
    })
}

fn link_with(
    hub: &Arc<crate::hub::Hub>,
    serve: impl FnOnce(
        Arc<crate::hub::Hub>,
        mpsc::Receiver<String>,
        mpsc::Sender<String>,
        Arc<Slot>,
    ) -> tokio::task::JoinHandle<()>,
) -> Wire {
    let (to_daemon, inbound) = mpsc::channel(256);
    let (out, mut lines) = mpsc::channel::<String>(4096);
    let (wire, from_daemon) = mpsc::channel(1);
    let slot = Slot::new(Some(hub.link_v2.clone()));
    let (stop_writer, mut stopped) = watch::channel(false);
    let writer_slot = slot.clone();
    tokio::spawn(async move {
        let mut streak = 0;
        loop {
            if stopped.wait_for(|stop| !*stop).await.is_err() {
                break;
            }
            let Some(line) = next_line(&mut lines, Some(&writer_slot), &mut streak).await else {
                break;
            };
            if wire.send(line).await.is_err() {
                break;
            }
        }
    });
    let serving = serve(hub.clone(), inbound, out, slot.clone());
    Wire { to_daemon, from_daemon, stop_writer, slot, serving }
}

pub(super) fn request_frame(request: Value) -> String {
    frame_line(9, request.to_string().as_bytes()).unwrap()
}

fn hello_frame() -> String {
    request_frame(json!({"method":"hello","params":{"clientKind":"peer","protocol":2}}))
}

impl Wire {
    pub async fn send(&self, line: String) {
        self.to_daemon.send(line).await.unwrap();
    }

    /// The next frame the daemon writes, skipping v1 lines into `v1`.
    pub async fn frame(&mut self, v1: &mut Vec<String>) -> (u8, Value) {
        tokio::time::timeout(WAIT, async {
            loop {
                let line = self.from_daemon.recv().await.expect("the link is open");
                if let Some(incoming) = parse(&line).filter(|_| is_frame_line(&line)) {
                    return (incoming.kind, serde_json::from_slice(incoming.payload).unwrap());
                }
                v1.push(line);
            }
        })
        .await
        .expect("a frame comes")
    }

    /// A v1 request's reply, skipping every other line.
    pub async fn call(&mut self, id: u64, m: &str, params: Value) -> Value {
        self.send(Message::request(id, m, params).to_line()).await;
        tokio::time::timeout(WAIT, async {
            loop {
                let line = self.from_daemon.recv().await.expect("the link is open");
                assert!(!is_frame_line(&line) || id != u64::MAX);
                if let Ok(reply) = serde_json::from_str::<Value>(&line)
                    && reply["id"] == id
                {
                    return reply;
                }
            }
        })
        .await
        .expect("the reply comes")
    }
}

fn features(reply: &Value) -> Vec<String> {
    reply
        .pointer("/result/_meta/acpmux/features")
        .and_then(Value::as_array)
        .unwrap()
        .iter()
        .map(|f| f.as_str().unwrap().to_owned())
        .collect()
}

fn initialize() -> Value {
    json!({"protocolVersion": 1, "clientInfo": {"name": crate::peer::CLIENT_NAME, "version": "0"}})
}

#[tokio::test]
async fn list_stream_is_named_only_on_a_link_with_list_and_peers_on() {
    let hub = memory_hub();
    let mut off = link(&hub);
    assert!(
        !features(&off.call(1, method::INITIALIZE, initialize()).await).contains(&FEATURE.into())
    );
    let _writer = peers_on(&hub);
    let mut on = link(&hub);
    assert!(
        features(&on.call(1, method::INITIALIZE, initialize()).await).contains(&FEATURE.into())
    );
    let mut other = not_a_link(&hub);
    let reply = other.call(1, method::INITIALIZE, initialize()).await;
    assert!(!features(&reply).contains(&FEATURE.into()));
    // Only `list` and `peers` together turn it on.
    let lone = memory_hub();
    let (core, writer) = acpmux_core::hub::Hub::new(acpmux_book::index::SummaryIndex::new());
    lone.link_v2.install(Arc::new(acpmux_core::life::V2::new(core, writer)));
    assert!(lone.link_v2.v2().is_none());
}

/// `peers` off, a connection that is not a link, and a link before any `hello`: a frame is
/// dropped and counted, no frame is sent, and v1 answers as before.
#[tokio::test]
async fn a_frame_with_no_connection_is_dropped_and_counted() {
    let sub =
        request_frame(json!({"method":"sub","params":{"sid":"s","stream":"list","view":"live"}}));
    for case in ["peers off", "not a link", "before hello"] {
        let hub = memory_hub();
        let _writer = (case != "peers off").then(|| peers_on(&hub));
        let mut wire = if case == "not a link" { not_a_link(&hub) } else { link(&hub) };
        let first = if case == "before hello" { sub.clone() } else { hello_frame() };
        wire.send(first).await;
        wire.send(sub.clone()).await;
        let reply = wire.call(7, method::MUX_STATUS, json!({})).await;
        assert!(reply.get("result").is_some() || reply.get("error").is_some(), "{case}: {reply}");
        assert!(wire.from_daemon.try_recv().is_err(), "{case}: nothing else is written");
        assert!(!wire.slot.holds(), "{case}: no frame is sent");
        assert_eq!(hub.link_v2.counters.dropped.load(Ordering::Relaxed), 2, "{case}");
        assert_eq!(hub.link_v2.counters.value_parses.load(Ordering::Relaxed), 0, "{case}");
    }
    // The method in another shape is parsed as v1 parses any line, dropped and counted apart.
    let hub = memory_hub();
    let _writer = peers_on(&hub);
    let mut wire = link(&hub);
    wire.send(Message::notification(method::MUX_V2, json!({"kind":9})).to_line()).await;
    wire.call(1, method::MUX_STATUS, json!({})).await;
    assert_eq!(hub.link_v2.counters.value_parses.load(Ordering::Relaxed), 1);
    assert_eq!(hub.link_v2.counters.dropped.load(Ordering::Relaxed), 1);
}

#[tokio::test]
async fn a_second_hello_ends_the_first_connection_and_starts_the_next() {
    let hub = memory_hub();
    let mut writer = peers_on(&hub);
    writer.apply(row("local", "a", 10, "running")).unwrap();
    let mut wire = link(&hub);
    let mut v1 = Vec::new();
    let sub = request_frame(
        json!({"method":"sub","params":{"sid":"s","stream":"list","view":"live","cursor":0}}),
    );
    wire.send(hello_frame()).await;
    assert_eq!(wire.frame(&mut v1).await.0, 1, "the hello reply");
    wire.send(sub.clone()).await;
    let (kind, window) = wire.frame(&mut v1).await;
    assert_eq!(kind, 2, "{window}");
    assert_eq!(window["rows"][0]["chatId"], "a");
    wire.send(hello_frame()).await;
    assert_eq!(wire.frame(&mut v1).await.0, 1, "the next connection's hello reply");
    assert_eq!(hub.link_v2.counters.second_hello.load(Ordering::Relaxed), 1);
    // The same sid again is a new subscription, not a duplicate: the first connection is gone.
    wire.send(sub).await;
    let (kind, window) = wire.frame(&mut v1).await;
    assert_eq!(kind, 2, "{window}");
    assert_eq!(hub.link_v2.counters.dropped.load(Ordering::Relaxed), 0);
}

/// Every request a peer may not make is answered `error` over the link, and a `hello` that
/// claims another kind of client or an identity changes nothing.
#[tokio::test]
async fn each_refusal_arrives_as_an_error_and_a_claimed_role_changes_nothing() {
    let hub = memory_hub();
    let mut writer = peers_on(&hub);
    writer.apply(row("local", "a", 10, "running")).unwrap();
    let mut wire = link(&hub);
    let mut v1 = Vec::new();
    wire.send(request_frame(json!({"method":"hello","params":{
        "clientKind":"local","protocol":2,"identity":"local-person"}})))
        .await;
    assert_eq!(wire.frame(&mut v1).await.0, 1);
    wire.send(request_frame(
        json!({"method":"sub","params":{"sid":"live","stream":"list","view":"live","cursor":0}}),
    ))
    .await;
    assert_eq!(wire.frame(&mut v1).await.0, 2);
    let refused = [
        json!({"method":"sub","params":{"sid":"c","stream":"chat:a"}}),
        json!({"method":"sub","params":{"sid":"c","stream":"status"}}),
        json!({"method":"sub","params":{"sid":"c","stream":"list","view":"all"}}),
        json!({"method":"sub","params":{"sid":"c","stream":"list","view":"folders"}}),
        json!({"method":"sub","params":{"sid":"c","stream":"list"}}),
        json!({"method":"sub","params":{"sid":"c","stream":"list","view":"live","filter":{"origin":"c"}}}),
        json!({"method":"sub","params":{"sid":"c","stream":"list","view":"live",
            "anchor":{"key":{"lastActivity":1,"chatId":"a","origin":"local"},"side":"after"}}}),
        json!({"method":"page","params":{"sid":"live","stream":"list","view":"all"}}),
        json!({"method":"page","params":{"sid":"live","stream":"chat:a","view":"live"}}),
        json!({"method":"page","params":{"sid":"live","stream":"list","view":"live",
            "filter":{"origin":"c"}}}),
        json!({"method":"page","params":{"sid":"live","stream":"list","view":"live",
            "keys":[{"lastActivity":1,"chatId":"a","origin":"c"}]}}),
    ];
    for request in &refused {
        wire.send(request_frame(request.clone())).await;
        let (kind, error) = wire.frame(&mut v1).await;
        assert_eq!(kind, 8, "{request} -> {error}");
        assert!(
            error["message"].as_str().unwrap().contains("not allowed on a peer link"),
            "{error}"
        );
    }
    assert!(v1.is_empty(), "no v1 line answered a frame: {v1:?}");
}

/// The test's dialing end: an adapter over the link and the v2 client on it, whose changes
/// keep a mirror of the live view.
pub(super) struct Dialer {
    pub changes: mpsc::Receiver<Change<Value>>,
    pub mirror: BTreeMap<String, Value>,
    pub cursor: u64,
    pub windows: usize,
    pub ends: usize,
    pub frames: Vec<Value>,
    _tasks: Vec<tokio::task::JoinHandle<()>>,
}

pub(super) fn dial(
    wire: Wire,
    sub: Sub,
) -> (Dialer, watch::Sender<bool>, tokio::task::JoinHandle<()>) {
    let Wire { to_daemon, mut from_daemon, stop_writer, serving, .. } = wire;
    let slot = Slot::new(None);
    let (adapter, reader, writer) = Adapter::new(slot.clone());
    let reading = tokio::spawn(async move {
        while let Some(line) = from_daemon.recv().await {
            if is_frame_line(&line) {
                let Some(frame) = parse(&line) else { break };
                if !adapter.deliver(&frame).await {
                    break;
                }
            }
        }
        adapter.close();
    });
    let writing = tokio::spawn(async move {
        loop {
            let line = slot.next().await;
            if to_daemon.send(line).await.is_err() {
                break;
            }
        }
    });
    let mut client = Client::<Value>::connected_v2();
    client.subscribe(sub).unwrap();
    let (tx, changes) = mpsc::channel(64);
    let driving = tokio::spawn(async move {
        let _ = acpmux_client::tokio_driver::drive(client, reader, writer, tx).await;
    });
    let dialer = Dialer {
        changes,
        mirror: BTreeMap::new(),
        cursor: 0,
        windows: 0,
        ends: 0,
        frames: Vec::new(),
        _tasks: vec![reading, writing, driving],
    };
    (dialer, stop_writer, serving)
}

pub(super) fn live_sub(cursor: u64) -> Sub {
    let mut sub = Sub::new("live", "list").from_cursor(cursor);
    sub.view = Some(ListView::Live);
    sub
}

impl Dialer {
    pub fn apply(&mut self, change: Change<Value>) {
        match change {
            Change::Window(window) => {
                self.windows += 1;
                self.cursor = window.cursor;
                self.mirror = window
                    .rows
                    .into_iter()
                    .map(|row| (row["chatId"].as_str().unwrap().to_owned(), row))
                    .collect();
            }
            Change::Summary { seq, summary, .. } => {
                self.cursor = self.cursor.max(seq);
                let id = summary["chatId"].as_str().unwrap().to_owned();
                if summary["state"] == "closed" {
                    self.mirror.remove(&id);
                } else {
                    self.mirror.insert(id, summary);
                }
            }
            Change::Left { seq, summary, .. } => {
                self.cursor = self.cursor.max(seq);
                self.mirror.remove(summary["chatId"].as_str().unwrap());
            }
            Change::Gone { seq, chat_id, .. } => {
                self.cursor = self.cursor.max(seq);
                self.mirror.remove(&chat_id);
            }
            Change::Origin { seq, .. } => self.cursor = self.cursor.max(seq),
            Change::Page(page) => self.frames.push(serde_json::to_value(page).unwrap()),
            Change::Error { code, .. } => panic!("the link's connection failed: {code}"),
            _ => {}
        }
    }

    /// Takes changes until the mirror equals `expected`.
    pub async fn settle(&mut self, expected: &BTreeMap<String, Value>) {
        let result = tokio::time::timeout(WAIT, async {
            while self.mirror != *expected {
                let change = self.changes.recv().await.expect("the client runs");
                self.apply(change);
            }
        })
        .await;
        assert!(
            result.is_ok(),
            "the mirror never matched: held {:?}, want {:?}",
            self.mirror.keys().collect::<Vec<_>>(),
            expected.keys().collect::<Vec<_>>()
        );
    }
}

/// This machine's live rows in peer form, as a link's client reads them.
pub(super) fn peer_rows(core: &acpmux_core::hub::Hub) -> BTreeMap<String, Value> {
    let mut sub = Sub::new("expected", "list");
    sub.view = Some(ListView::Live);
    sub.window = Some(400);
    let window: acpmux_client::wire::Window<Value> =
        core.peer_window(&sub).unwrap().decode_json().unwrap();
    assert!(!window.has_after, "the test keeps the live view within one window");
    window.rows.into_iter().map(|row| (row["chatId"].as_str().unwrap().to_owned(), row)).collect()
}

/// A linked to B and B to C, in one process: B holds rows and an origin record of C. Over the
/// link, no row of C and no `origin` record reaches A, at a window, a delta, a resume and a page.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn no_row_of_a_third_machine_and_no_origin_record_reaches_a_peer() {
    let hub = memory_hub();
    let mut writer = peers_on(&hub);
    let core = v2_hub(&hub);
    writer.origin("c-machine", acpmux_book::index::OriginState::Connected, 1).unwrap();
    for n in 0..20 {
        writer
            .apply_from(
                acpmux_core::hub::Source::V1,
                row("c-machine", &format!("c-{n}"), 100 + n, "running"),
            )
            .unwrap();
        writer.apply(row("local", &format!("b-{n}"), 200 + n, "running")).unwrap();
    }
    let raw = |wire_frame: &Value| {
        let text = wire_frame.to_string();
        assert!(!text.contains("c-machine"), "C reached A: {text}");
        assert!(!text.contains("\"c-"), "C reached A: {text}");
        assert!(wire_frame.get("origins").and_then(Value::as_array).is_none_or(Vec::is_empty));
    };
    let mut wire = link(&hub);
    let mut v1 = Vec::new();
    wire.send(hello_frame()).await;
    wire.frame(&mut v1).await;
    // A window of five, then pages after it to the end.
    wire.send(request_frame(json!({"method":"sub","params":{
        "sid":"s","stream":"list","view":"live","cursor":0,"window":5}})))
        .await;
    let (kind, window) = wire.frame(&mut v1).await;
    assert_eq!(kind, 2);
    raw(&window);
    let mut after = window["afterKey"].clone();
    let mut local = window["rows"].as_array().unwrap().len();
    while !after.is_null() {
        wire.send(request_frame(json!({"method":"page","params":{
            "sid":"s","stream":"list","view":"live","after":after,"maxBytes":16384}})))
            .await;
        let (kind, page) = wire.frame(&mut v1).await;
        assert_eq!(kind, 4, "{page}");
        raw(&page);
        local += page["rows"].as_array().unwrap().len();
        after = if page["hasAfter"] == true { page["afterKey"].clone() } else { Value::Null };
    }
    assert_eq!(local, 20);
    // Deltas: C's changes and records take no bytes; B's arrive.
    let cursor = window["cursor"].as_u64().unwrap();
    writer.origin("c-machine", acpmux_book::index::OriginState::Down, 2).unwrap();
    writer
        .apply_from(acpmux_core::hub::Source::V1, row("c-machine", "c-0", 900, "running"))
        .unwrap();
    writer.remove_from(acpmux_core::hub::Source::V1, "c-machine", "c-1").unwrap();
    writer.apply(row("local", "b-0", 901, "running")).unwrap();
    let (kind, delta) = wire.frame(&mut v1).await;
    assert_eq!(kind, 3, "{delta}");
    raw(&delta);
    assert_eq!(delta["ops"].as_array().unwrap().len(), 1, "{delta}");
    // A resume from before C's changes: B's op only, then the end.
    wire.send(hello_frame()).await;
    wire.frame(&mut v1).await;
    wire.send(request_frame(json!({"method":"sub","params":{
        "sid":"r","stream":"list","view":"live","cursor":cursor}})))
        .await;
    let (kind, resume) = wire.frame(&mut v1).await;
    assert_eq!(kind, 3, "{resume}");
    raw(&resume);
    assert_eq!(resume["replay"], "end");
    assert_eq!(resume["ops"].as_array().unwrap().len(), 1);
    assert_eq!(peer_rows(&core).len(), 20);
}

/// A link whose writer stops: the adapter holds one frame, the bytes held stay bounded while
/// changes go on, and when the writer returns the mirror equals this machine's live rows.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_writer_that_stops_holds_one_frame_and_the_mirror_is_equal_when_it_returns() {
    let hub = memory_hub();
    let mut writer = peers_on(&hub);
    let core = v2_hub(&hub);
    for n in 0..30 {
        writer.apply(row("local", &format!("chat-{n}"), 10 + n, "running")).unwrap();
    }
    let (mut dialer, stop, _serving) = dial(link(&hub), live_sub(0));
    dialer.settle(&peer_rows(&core)).await;
    stop.send_replace(true);
    let mut most = 0;
    for n in 0..3_000_u64 {
        let id = format!("chat-{}", n % 30);
        writer
            .apply(row("local", &id, 1_000 + n, if n % 11 == 0 { "closed" } else { "running" }))
            .unwrap();
        if n % 100 == 0 {
            tokio::task::yield_now().await;
            most = most.max(hub.link_v2.counters.held_bytes.load(Ordering::Relaxed));
        }
    }
    tokio::time::sleep(Duration::from_millis(100)).await;
    most = most.max(hub.link_v2.counters.held_bytes.load(Ordering::Relaxed));
    // One frame toward the peer in the slot, and at most one from it not yet read.
    assert!(most <= (2 * acpmux_core::wire::MAX_FRAME_BYTES) as u64, "held {most} bytes");
    stop.send_replace(false);
    dialer.settle(&peer_rows(&core)).await;
}

/// 1,000 random runs of changes, closes, deletes, reopens and link drops: after each run the
/// client's mirror equals this machine's live rows in peer form.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn random_runs_leave_the_mirror_equal_to_the_live_rows() {
    let hub = memory_hub();
    let mut writer = peers_on(&hub);
    let core = v2_hub(&hub);
    let mut rng = Rng(0x2026_1114);
    let mut cursor = 0;
    let mut mirror = BTreeMap::new();
    let mut at = 1;
    for run in 0..1_000 {
        let (mut dialer, _stop, serving) = dial(link(&hub), live_sub(cursor));
        dialer.mirror = std::mem::take(&mut mirror);
        dialer.cursor = cursor;
        for _ in 0..rng.below(12) {
            let id = format!("chat-{}", rng.below(16));
            at += 1;
            match rng.below(5) {
                0 | 1 => drop(writer.apply(row("local", &id, at, "running"))),
                2 => drop(writer.apply(row("local", &id, at, "closed"))),
                3 => drop(writer.remove("local", &id)),
                _ => drop(writer.apply(row("local", &id, at, "idle"))),
            }
        }
        dialer.settle(&peer_rows(&core)).await;
        cursor = dialer.cursor;
        mirror = std::mem::take(&mut dialer.mirror);
        // The link drops: the next run dials again from the saved cursor.
        serving.abort();
        if run % 100 == 0 {
            eprintln!("run {run}: {} live rows, cursor {cursor}", mirror.len());
        }
    }
}

/// A recorded run on a link, with `peers` on and off: v1's watch reply, its pushes and the
/// `_acpmux/sessions` replies are equal byte for byte.
#[tokio::test]
async fn v1_replies_and_pushes_on_a_link_are_byte_equal_with_peers_on_and_off() {
    async fn recorded(peers: bool) -> Vec<String> {
        let hub = memory_hub();
        let _writer = peers.then(|| peers_on(&hub));
        let meta = |id: &str| -> crate::store::SessionMeta {
            serde_json::from_value(json!({
                "schema": crate::store::META_SCHEMA, "id": id, "name": id,
                "harness": "fake", "cwd": "/tmp", "status": "idle",
                "createdAt": 1, "updatedAt": 1_000
            }))
            .unwrap()
        };
        hub.insert_test_session(meta("one"));
        hub.insert_test_session(meta("two"));
        let mut wire = link(&hub);
        let mut lines = Vec::new();
        wire.call(1, method::INITIALIZE, initialize()).await;
        lines.push(wire.call(2, method::MUX_WATCH, json!({})).await.to_string());
        lines.push(wire.call(3, method::MUX_SESSIONS, json!({})).await.to_string());
        let session = hub.insert_test_session(meta("three"));
        hub.edit_test_meta(&session, |meta| meta.name = "renamed".into());
        lines.push(wire.call(4, method::MUX_SESSIONS, json!({"limit": 2})).await.to_string());
        // Everything else the link wrote, pushes included, until the last reply.
        while let Ok(line) = wire.from_daemon.try_recv() {
            assert!(!is_frame_line(&line));
            lines.push(line);
        }
        lines
    }
    let off = recorded(false).await;
    let on = recorded(true).await;
    assert!(!off.is_empty());
    assert_eq!(on, off);
}

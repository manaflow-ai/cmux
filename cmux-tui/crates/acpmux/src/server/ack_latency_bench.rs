//! A small reply's latency behind a burst of list traffic on the same connection, and the
//! fixture the reply size detector (`reply_size_tests.rs`) reads: a daemon with 2,000 chats of
//! its own and 4,000 mirrored from two peers, whose whole list is about 30 MB, as one dogfood
//! Mac's was (a 31 MB `_acpmux/watch` reply, near the 32 MB frame cap, 9,208 times in 11
//! days, 2026-11-11). A connection's replies go out in order, so a prompt's acknowledgement
//! queued behind such a list waited for it to be written and parsed, and the pane said "Not sent
//! yet" about a prompt acpmux had taken within milliseconds.
//!
//! The client here is the pane: one reader that parses every line as it comes (the page's
//! `JSON.parse`, on its main thread), and reads a whole list as the pane does (`SessionPager.whole`:
//! `_acpmux/watch {enabled}`, then `_acpmux/sessions {cursor}` while a `nextCursor` comes). While
//! it reads, a small request goes every few milliseconds; each one's latency is from its send to
//! its reply parsed.
//!
//! Only this crate's API from before the fix is used, so the same file measures both sides:
//! `cargo test -p acpmux --release --lib ack_latency_bench -- --ignored --nocapture`.

use crate::config::{Config, StoreMode};
use crate::peer::{Peer, PeerNotice};
use crate::rpc::{Message, method};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::{mpsc, oneshot};

use super::Origin;

/// This daemon's own chats.
pub(super) const OWN: usize = 2_000;
/// The chats each of [`PEERS`] mirrors here.
pub(super) const MIRRORED: usize = 2_000;
pub(super) const PEERS: [&str; 2] = ["box", "lane"];
/// An own chat's title: summaries keep about this much of one.
const TITLE_BYTES: usize = 2_000;
/// The plan text a mirrored row carries: rows of a busy peer are several KB.
const PLAN_BYTES: usize = 5_500;
/// [`hub_with`]'s plan text for a whole list of about 31 MB.
const LARGE_PLAN_BYTES: usize = 6_200;

/// The hub: [`OWN`] chats of its own and [`MIRRORED`] from each of [`PEERS`].
pub(super) async fn hub() -> Arc<crate::hub::Hub> {
    hub_with(PLAN_BYTES).await
}

/// [`hub`] with peer rows of `plan_bytes` of plan text: [`LARGE_PLAN_BYTES`] makes a whole list of
/// about 31 MB, just under the one-reply bound, as the dogfood Mac's was (31,454,601 bytes).
pub(super) async fn hub_with(plan_bytes: usize) -> Arc<crate::hub::Hub> {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    for i in 0..OWN {
        let meta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": format!("own-{i}"), "name": format!("own-{i}"),
            "title": format!("{i} {}", "t".repeat(TITLE_BYTES)), "harness": "fake", "cwd": "/tmp",
            "status": "idle", "createdAt": 1, "updatedAt": i + 1
        }))
        .unwrap();
        store.save(&meta).unwrap();
    }
    let hub = crate::hub::Hub::new(config, store);
    for name in PEERS {
        let (tx, _rx) = mpsc::channel(8);
        let peer = Peer::new(name, "ws://127.0.0.1:9", None, None, tx);
        hub.peers.lock().unwrap().insert(name.to_owned(), peer.clone());
        let rows: Vec<Value> = (0..MIRRORED)
            .map(|i| {
                json!({"sessionId": format!("{name}-chat-{i}"), "name": "lane", "harness": "claude",
                    "cwd": "/work", "status": "idle", "updatedAt": i as u64 + 10,
                    "planStep": "x".repeat(plan_bytes)})
            })
            .collect();
        let mut settled = peer.settled();
        for notice in [PeerNotice::Sessions(rows), PeerNotice::Connected] {
            hub.peer_notices.send((name.to_owned(), peer.generation, notice)).await.unwrap();
        }
        tokio::time::timeout(Duration::from_secs(30), settled.wait_for(|n| *n >= 1))
            .await
            .expect("the hub applies the notices")
            .unwrap();
    }
    assert_eq!(hub.remote_sessions().len(), MIRRORED * PEERS.len());
    hub
}

/// Every session id the hub lists: its own and each peer's.
pub(super) fn every_id() -> HashSet<String> {
    let own = (0..OWN).map(|i| format!("own-{i}"));
    let peers = PEERS.iter().flat_map(|p| (0..MIRRORED).map(move |i| format!("{p}-chat-{i}")));
    own.chain(peers).collect()
}

/// One reply as the client read it: the message and its line's size.
pub(super) type Reply = (Value, usize);

/// A connection whose one reader parses every line as it arrives, as the page does, and hands
/// each reply to whoever asked for it.
pub(super) struct Client {
    input: mpsc::Sender<String>,
    waiting: Arc<std::sync::Mutex<HashMap<u64, oneshot::Sender<Reply>>>>,
    next: std::sync::atomic::AtomicU64,
}

impl Client {
    pub(super) async fn on(hub: &Arc<crate::hub::Hub>, origin: Origin) -> Arc<Self> {
        let (input, incoming) = mpsc::channel(64);
        let (output, mut outgoing) = mpsc::channel::<String>(256);
        tokio::spawn(super::serve_connection_with(hub.clone(), incoming, output, origin));
        let waiting: Arc<std::sync::Mutex<HashMap<u64, oneshot::Sender<Reply>>>> = Arc::default();
        let reader = waiting.clone();
        // The page's main thread: one line at a time, parsed whole before the next is read.
        tokio::task::spawn_blocking(move || {
            while let Some(line) = outgoing.blocking_recv() {
                let Ok(message) = serde_json::from_str::<Value>(&line) else { continue };
                let Some(id) = message.get("id").and_then(Value::as_u64) else { continue };
                if let Some(tx) = reader.lock().unwrap().remove(&id) {
                    let _ = tx.send((message, line.len()));
                }
            }
        });
        let client = Arc::new(Self { input, waiting, next: 0.into() });
        let hello = json!({"protocolVersion": 1, "clientInfo":
            {"name": crate::peer::CLIENT_NAME, "version": "0"}});
        client.call(method::INITIALIZE, hello).await;
        client
    }

    /// The reply to `m {params}`.
    pub(super) async fn call(&self, m: &str, params: Value) -> Reply {
        let id = self.next.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1;
        let (tx, rx) = oneshot::channel();
        self.waiting.lock().unwrap().insert(id, tx);
        self.input.send(Message::request(id, m, params).to_line()).await.unwrap();
        tokio::time::timeout(Duration::from_secs(120), rx)
            .await
            .unwrap_or_else(|_| panic!("{m}: the reply comes"))
            .unwrap()
    }

    /// The whole list from `m {params}` on, then by `_acpmux/sessions {cursor}` while a
    /// `nextCursor` comes, as every whole-list reader follows it: each reply.
    pub(super) async fn whole(&self, m: &str, params: Value) -> Vec<Reply> {
        let mut replies = vec![self.call(m, params).await];
        let mut seen = HashSet::new();
        loop {
            let (reply, _) = replies.last().unwrap();
            assert!(reply.get("error").is_none(), "{m}: {}", reply["error"]);
            let Some(cursor) = reply["result"]["nextCursor"].as_str().map(str::to_owned) else {
                return replies;
            };
            assert!(seen.insert(cursor.clone()), "{m}: the cursor {cursor} came twice");
            replies.push(self.call(method::MUX_SESSIONS, json!({"cursor": cursor})).await);
        }
    }
}

/// The `q`th quantile of `sorted`.
fn quantile(sorted: &[Duration], q: f64) -> Duration {
    let at = ((sorted.len() as f64 - 1.0) * q).round() as usize;
    sorted.get(at).copied().unwrap_or_default()
}

fn ms(d: Duration) -> f64 {
    d.as_secs_f64() * 1000.0
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "bench: run with --ignored --nocapture"]
async fn ack_latency_bench() {
    let hub = hub().await;
    let client = Client::on(&hub, Origin::LocalApp).await;
    // The first list builds the shared snapshot; its cost is not what this measures.
    let _ = client.call(method::MUX_SESSIONS, json!({"limit": 1})).await;
    let reading = Arc::new(std::sync::atomic::AtomicBool::new(true));
    // Small requests every 2 ms while the lists are read: each one's latency.
    let acks = {
        let (client, reading) = (client.clone(), reading.clone());
        tokio::spawn(async move {
            let mut latencies = Vec::new();
            while reading.load(std::sync::atomic::Ordering::SeqCst) {
                let asked = Instant::now();
                let (reply, _) = client.call(method::MUX_DEFAULTS, json!({})).await;
                assert!(reply.get("error").is_none(), "{reply}");
                latencies.push(asked.elapsed());
                tokio::time::sleep(Duration::from_millis(2)).await;
            }
            latencies
        })
    };
    // A burst of list traffic: the whole list read twice back to back (a lagged watch read
    // again at once), as the pane reads it.
    let started = Instant::now();
    let (mut lines, mut largest, mut ids) = (0, 0, HashSet::new());
    for _ in 0..2 {
        for (reply, bytes) in client.whole(method::MUX_WATCH, json!({"enabled": true})).await {
            lines += 1;
            largest = largest.max(bytes);
            for row in reply["result"]["sessions"].as_array().into_iter().flatten() {
                ids.insert(row["sessionId"].as_str().unwrap_or_default().to_owned());
            }
        }
    }
    let lists = started.elapsed();
    reading.store(false, std::sync::atomic::Ordering::SeqCst);
    let mut latencies = acks.await.unwrap();
    latencies.sort_unstable();
    assert_eq!(ids, every_id(), "every row read");
    println!(
        "PERF ack_behind_lists sessions={} list_reads=2 reply_lines={lines} largest_reply_bytes={largest} \
         lists_ms={:.0} acks={} ack_p50_ms={:.2} ack_p99_ms={:.2} ack_max_ms={:.2}",
        ids.len(),
        ms(lists),
        latencies.len(),
        ms(quantile(&latencies, 0.5)),
        ms(quantile(&latencies, 0.99)),
        ms(latencies.last().copied().unwrap_or_default()),
    );
}

/// The pane's socket (`AcpmuxPaneSocket`, `AgentPaneTransport.Limits`): frames wait for the page
/// in a queue of at most this many frames and bytes; one that would pass either closes the socket
/// (1008 "inbound overflow") and the page reconnects after [`PANE_RECONNECT`] (direct.ts
/// `reconnectDelay`, back to 250 ms after each open).
const PANE_QUEUED_FRAMES: usize = 8192;
const PANE_QUEUED_BYTES: usize = 32 << 20;
/// One push to the page holds at most this many frames and bytes (at least one frame).
const PANE_FLUSH_FRAMES: usize = 512;
const PANE_FLUSH_BYTES: usize = 4 << 20;
const PANE_RECONNECT: Duration = Duration::from_millis(250);
/// The page's main-thread time per MB of frames it runs (JSON.parse and the store), and the share
/// of the main thread it gets: the page's was measured 67% busy in long frames (2026-11-11).
const PAGE_MS_PER_MB: f64 = 25.0;
const PAGE_SHARE: f64 = 0.33;
/// Peer rows that change each second while the pane is open (a fleet of running agents): each a
/// `session_changed` of about 7 KB to every watching connection.
const CHANGES_PER_SEC: u64 = 200;
/// How long the page runs nothing else while it draws the chat it opened (a 4,636-turn chat on a
/// cold start), from its first list page on: the frames that come meanwhile wait in the queue.
const PANE_RENDER: Duration = Duration::from_secs(2);

/// What the pane's socket holds for the page, and whether it closed.
#[derive(Default)]
struct PaneQueue {
    frames: std::collections::VecDeque<String>,
    bytes: usize,
    closed: bool,
    /// The most bytes it held with a frame that arrived, against [`PANE_QUEUED_BYTES`].
    peak: usize,
}

/// One connection of the pane: the socket's queue in front of a page that runs a push at a time.
struct Pane {
    input: mpsc::Sender<String>,
    queue: Arc<std::sync::Mutex<PaneQueue>>,
    waiting: Arc<std::sync::Mutex<HashMap<u64, oneshot::Sender<Value>>>>,
    /// Until when the page draws its chat and takes no push.
    busy_until: Arc<std::sync::Mutex<Option<Instant>>>,
    next: std::sync::atomic::AtomicU64,
}

impl Pane {
    async fn open(hub: &Arc<crate::hub::Hub>) -> Arc<Self> {
        let (input, incoming) = mpsc::channel(64);
        let (output, mut outgoing) = mpsc::channel::<String>(1024);
        tokio::spawn(super::serve_connection_with(hub.clone(), incoming, output, Origin::LocalApp));
        let queue: Arc<std::sync::Mutex<PaneQueue>> = Arc::default();
        let waiting: Arc<std::sync::Mutex<HashMap<u64, oneshot::Sender<Value>>>> = Arc::default();
        let closed = Arc::new(tokio::sync::Notify::new());
        let ready = Arc::new(tokio::sync::Notify::new());
        // The socket: each frame joins the queue, or closes it past its bounds.
        let (q, c, r) = (queue.clone(), closed.clone(), ready.clone());
        tokio::spawn(async move {
            while let Some(line) = outgoing.recv().await {
                let mut q = q.lock().unwrap();
                if q.closed {
                    break;
                }
                let held = q.bytes + line.len();
                q.peak = q.peak.max(held);
                if q.frames.len() + 1 > PANE_QUEUED_FRAMES || held > PANE_QUEUED_BYTES {
                    q.closed = true;
                    c.notify_waiters();
                    break;
                }
                q.bytes = held;
                q.frames.push_back(line);
                r.notify_one();
            }
        });
        // The page: one push at a time, as long as its share of the main thread takes to run it.
        let busy_until: Arc<std::sync::Mutex<Option<Instant>>> = Arc::default();
        let (q, w, c, busy) = (queue.clone(), waiting.clone(), closed.clone(), busy_until.clone());
        tokio::spawn(async move {
            loop {
                let busy = *busy.lock().unwrap();
                if let Some(until) = busy.filter(|until| *until > Instant::now()) {
                    tokio::time::sleep_until(until.into()).await;
                }
                let push: Vec<String> = {
                    let mut q = q.lock().unwrap();
                    if q.closed {
                        break;
                    }
                    let (mut push, mut bytes) = (Vec::new(), 0);
                    while let Some(front) = q.frames.front() {
                        if !push.is_empty()
                            && (push.len() >= PANE_FLUSH_FRAMES
                                || bytes + front.len() > PANE_FLUSH_BYTES)
                        {
                            break;
                        }
                        bytes += front.len();
                        let line = q.frames.pop_front().unwrap();
                        q.bytes -= line.len();
                        push.push(line);
                    }
                    push
                };
                if push.is_empty() {
                    tokio::select! {
                        () = ready.notified() => {}
                        () = c.notified() => break,
                        () = tokio::time::sleep(Duration::from_millis(5)) => {}
                    }
                    continue;
                }
                let bytes: usize = push.iter().map(String::len).sum();
                let ms = bytes as f64 / 1e6 * PAGE_MS_PER_MB / PAGE_SHARE;
                tokio::time::sleep(Duration::from_secs_f64(ms / 1000.0)).await;
                for line in push {
                    let Ok(message) = serde_json::from_str::<Value>(&line) else { continue };
                    let Some(id) = message.get("id").and_then(Value::as_u64) else { continue };
                    if let Some(tx) = w.lock().unwrap().remove(&id) {
                        let _ = tx.send(message);
                    }
                }
            }
        });
        Arc::new(Self { input, queue, waiting, busy_until, next: 0.into() })
    }

    fn is_closed(&self) -> bool {
        self.queue.lock().unwrap().closed
    }

    /// The reply to `m {params}` once the page ran it; None when the socket closed first.
    async fn call(&self, m: &str, params: Value) -> Option<Value> {
        let id = self.next.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1;
        let (tx, rx) = oneshot::channel();
        self.waiting.lock().unwrap().insert(id, tx);
        if self.is_closed() {
            return None;
        }
        self.input.send(Message::request(id, m, params).to_line()).await.ok()?;
        let mut rx = rx;
        loop {
            tokio::select! {
                reply = &mut rx => return reply.ok(),
                () = tokio::time::sleep(Duration::from_millis(50)) => {
                    if self.is_closed() {
                        return None;
                    }
                }
            }
        }
    }

    /// The pane's open of a chat older than its first list page (direct.ts `open`): initialize,
    /// the first page (`SessionPager.first`), then the whole list (`settledWhole`), following its
    /// cursor as `SessionPager.whole` does. False when the socket closed on the way.
    async fn open_chat(&self) -> bool {
        let hello = json!({"protocolVersion": 1, "clientInfo": {"name": "pane", "version": "0"}});
        if self.call(method::INITIALIZE, hello).await.is_none() {
            return false;
        }
        let first = json!({"enabled": true, "limit": 200});
        if self.call(method::MUX_WATCH, first).await.is_none() {
            return false;
        }
        // It draws the chat it opened while the rest of the list comes.
        *self.busy_until.lock().unwrap() = Some(Instant::now() + PANE_RENDER);
        let Some(mut page) = self.call(method::MUX_WATCH, json!({"enabled": true})).await else {
            return false;
        };
        while let Some(cursor) = page["result"]["nextCursor"].as_str().map(str::to_owned) {
            match self.call(method::MUX_SESSIONS, json!({"cursor": cursor})).await {
                Some(next) => page = next,
                None => return false,
            }
        }
        true
    }
}

/// Pane reconnects in a window, on a list of about 31 MB (as the dogfood Mac's): a pane that opens
/// a chat older than its first list page reads the whole list; peers' rows change meanwhile; the
/// page gets a third of its main thread. Each time the socket closes on overflow the pane
/// reconnects after 250 ms and opens again, as the page does. Run with
/// `cargo test -p acpmux --release --lib pane_reconnect_bench -- --ignored --nocapture`.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "bench: run with --ignored --nocapture"]
async fn pane_reconnect_bench() {
    let window = Duration::from_secs(
        std::env::var("PANE_WINDOW_SECS").ok().and_then(|s| s.parse().ok()).unwrap_or(120),
    );
    let hub = hub_with(LARGE_PLAN_BYTES).await;
    // The whole list's size, as one reply would hold it.
    let whole = Client::on(&hub, Origin::Local).await;
    let list_bytes: usize = whole
        .whole(method::MUX_SESSIONS, json!({}))
        .await
        .iter()
        .map(|(reply, _)| reply["result"]["sessions"].to_string().len())
        .sum();
    let changing = Arc::new(std::sync::atomic::AtomicBool::new(true));
    let churn = {
        let (hub, changing) = (hub.clone(), changing.clone());
        tokio::spawn(async move {
            let generation = hub.peers.lock().unwrap()[PEERS[0]].generation;
            let every = Duration::from_micros(1_000_000 / CHANGES_PER_SEC);
            let mut n = 0_u64;
            while changing.load(std::sync::atomic::Ordering::SeqCst) {
                let i = n as usize % MIRRORED;
                let row = json!({"sessionId": format!("{}-chat-{i}", PEERS[0]), "name": "lane",
                    "harness": "claude", "cwd": "/work",
                    "status": if n.is_multiple_of(2) { "running" } else { "idle" },
                    "updatedAt": i as u64 + 10, "planStep": "x".repeat(LARGE_PLAN_BYTES)});
                let notice =
                    PeerNotice::SessionChanged { session: row, kind: "status".into(), seq: n };
                let _ = hub.peer_notices.send((PEERS[0].to_owned(), generation, notice)).await;
                n += 1;
                tokio::time::sleep(every).await;
            }
        })
    };
    let started = Instant::now();
    let (mut opens, mut reconnects, mut peak) = (0, 0, 0);
    while started.elapsed() < window {
        let pane = Pane::open(&hub).await;
        opens += 1;
        let opened = pane.open_chat().await;
        if opened {
            // Open: it stays until the socket closes or the window ends.
            while !pane.is_closed() && started.elapsed() < window {
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
        }
        peak = peak.max(pane.queue.lock().unwrap().peak);
        if pane.is_closed() {
            reconnects += 1;
            tokio::time::sleep(PANE_RECONNECT).await;
        }
    }
    changing.store(false, std::sync::atomic::Ordering::SeqCst);
    churn.await.unwrap();
    let per_10_min = reconnects as f64 * 600.0 / started.elapsed().as_secs_f64();
    // How long the page may run nothing (draw a chat) while the largest reply waits in the queue
    // and the changes keep coming, before the queue passes its bound.
    let largest = whole
        .whole(method::MUX_WATCH, json!({"enabled": true}))
        .await
        .iter()
        .map(|(_, bytes)| *bytes)
        .max()
        .unwrap_or(0);
    let change_bytes = 7_000.0 * CHANGES_PER_SEC as f64;
    let tolerated_s = PANE_QUEUED_BYTES.saturating_sub(largest) as f64 / change_bytes;
    println!(
        "PERF pane_reconnects list_bytes={list_bytes} largest_reply_bytes={largest} window_s={:.0} \
         opens={opens} reconnects={reconnects} reconnects_per_10_min={per_10_min:.0} \
         peak_queued_bytes={peak} queue_limit={PANE_QUEUED_BYTES} busy_page_tolerated_s={tolerated_s:.1}",
        started.elapsed().as_secs_f64()
    );
}

//! A small reply's latency behind a burst of list traffic on the same connection, and the
//! fixture the reply size detector (`reply_size_tests.rs`) reads: a daemon with 2,000 chats of
//! its own and 4,000 mirrored from two peers, whose whole list is about 30 MB, as the one on
//! Leo's Mac was (a 31 MB `_acpmux/watch` reply, near the 32 MB frame cap, 9,208 times in 11
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

/// The hub: [`OWN`] chats of its own and [`MIRRORED`] from each of [`PEERS`].
pub(super) async fn hub() -> Arc<crate::hub::Hub> {
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
                    "planStep": "x".repeat(PLAN_BYTES)})
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

//! A record's row is built, and a peer's row parsed, once however many connections watch it
//! (`SharedRow`, `HubEvent::row`): the fan-out tasks send it one after another, and each found the
//! row let go by the one before and built it again (a symbolized sample of a 45-peer host: the
//! build, the parse and the `to_value` were 29% of on-CPU samples under `fanout::send_event`).

use super::acp_list_tests::fleet_hub;
use crate::config::{Config, StoreMode};
use crate::peer::PeerNotice;
use crate::rpc::{Message, method};
use serde_json::{Value, json};
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

fn hub_with_chat(id: &str) -> (Arc<crate::hub::Hub>, Arc<crate::hub::Session>) {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let meta: crate::store::SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": "lane", "harness": "claude",
        "cwd": "/tmp", "status": "running", "createdAt": 1, "updatedAt": 1
    }))
    .unwrap();
    store.save(&meta).unwrap();
    let hub = crate::hub::Hub::new(config, store);
    let session = hub.make_session(meta);
    hub.sessions.lock().unwrap().insert(id.to_owned(), session.clone());
    (hub, session)
}

/// A local connection that watches the list (with tools): its input, kept open, and its lines.
async fn watcher(
    hub: &Arc<crate::hub::Hub>,
    tools: bool,
) -> (mpsc::Sender<String>, mpsc::Receiver<String>) {
    let (input, incoming) = mpsc::channel(8);
    let (output, mut outgoing) = mpsc::channel(65_536);
    tokio::spawn(super::serve_connection_with(hub.clone(), incoming, output, super::Origin::Local));
    let hello = json!({"protocolVersion": 1, "clientInfo": {"name": "row-test", "version": "0"}});
    input.send(Message::request(1, method::INITIALIZE, hello).to_line()).await.unwrap();
    let watch = json!({"enabled": true, "tools": tools, "limit": 1});
    input.send(Message::request(2, method::MUX_WATCH, watch).to_line()).await.unwrap();
    tokio::time::timeout(Duration::from_secs(60), async {
        loop {
            let line: Value = serde_json::from_str(&outgoing.recv().await.unwrap()).unwrap();
            if line["id"] == 2 {
                assert!(line.get("error").is_none(), "{line}");
                return;
            }
        }
    })
    .await
    .expect("the watch answers");
    (input, outgoing)
}

/// Waits until every client has heard a `session_changed` with `seq` (or later).
async fn heard(clients: &mut [mpsc::Receiver<String>], seq: u64) {
    for client in clients {
        tokio::time::timeout(Duration::from_secs(120), async {
            loop {
                let line = client.recv().await.expect("the connection ended");
                if line.contains("_acpmux/session_changed")
                    && serde_json::from_str::<Value>(&line)
                        .is_ok_and(|v| v["params"]["seq"].as_u64() >= Some(seq))
                {
                    return;
                }
            }
        })
        .await
        .expect("every watcher hears the last change");
    }
}

/// 45 watchers hear each of the chat's records: its row is built once per record, not 45 times.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn watchers_of_one_record_build_its_row_once() {
    const WATCHERS: usize = 45;
    const RECORDS: u64 = 20;
    let (hub, session) = hub_with_chat("row-once-chat");
    let mut inputs = Vec::new();
    let mut clients = Vec::new();
    for _ in 0..WATCHERS {
        let (input, outgoing) = watcher(&hub, true).await;
        inputs.push(input);
        clients.push(outgoing);
    }
    let before = hub.watcher_row_builds.load(Ordering::Relaxed);
    for n in 0..RECORDS {
        hub.append(&session, "mux", "status", json!({"status": "running", "n": n}));
    }
    let last = session.meta().last_seq;
    heard(&mut clients, last).await;
    let built = hub.watcher_row_builds.load(Ordering::Relaxed) - before;
    eprintln!("FANOUT-ROW watchers {WATCHERS} records {RECORDS} rows built {built}");
    assert!(built <= RECORDS, "{built} rows built for {RECORDS} records to {WATCHERS} watchers");
}

fn cpu_seconds() -> f64 {
    let mut usage = std::mem::MaybeUninit::<libc::rusage>::zeroed();
    // SAFETY: getrusage fully initializes the supplied rusage structure.
    if unsafe { libc::getrusage(libc::RUSAGE_SELF, usage.as_mut_ptr()) } != 0 {
        return 0.0;
    }
    // SAFETY: getrusage returned success above.
    let usage = unsafe { usage.assume_init() };
    let secs = |t: libc::timeval| t.tv_sec as f64 + t.tv_usec as f64 / 1e6;
    secs(usage.ru_utime) + secs(usage.ru_stime)
}

/// The duress bench: 45 connected watchers (tools on) and one peer's row changing 600 times, each
/// change heard by every watcher. Prints the process CPU and wall time per event.
/// `cargo test -p acpmux --lib -- --ignored --nocapture fanout_45_watchers_peer_rows`
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "a bench: run on a fleet Mac"]
async fn fanout_45_watchers_peer_rows() {
    const WATCHERS: usize = 45;
    const EVENTS: u64 = 600;
    let hub = fleet_hub(2, 50).await;
    let mut inputs = Vec::new();
    let mut clients = Vec::new();
    for _ in 0..WATCHERS {
        let (input, outgoing) = watcher(&hub, true).await;
        inputs.push(input);
        clients.push(outgoing);
    }
    let generation = hub.peers.lock().unwrap()["peer-0"].generation;
    let (cpu0, wall0) = (cpu_seconds(), Instant::now());
    for seq in 1..=EVENTS {
        let changed = json!({"sessionId": "peer-0-chat-0", "name": "chat-0", "harness": "claude",
            "cwd": "/work", "status": "running", "updatedAt": 1_000_000 + seq,
            "tools": [{"id": "tool", "description": "x".repeat(3300)}]});
        let notice = PeerNotice::SessionChanged { session: changed, kind: "status".into(), seq };
        hub.peer_notices.send(("peer-0".into(), generation, notice)).await.unwrap();
    }
    heard(&mut clients, EVENTS).await;
    let (cpu, wall) = (cpu_seconds() - cpu0, wall0.elapsed());
    println!(
        "PERF fanout_45_watchers_peer_rows watchers={WATCHERS} events={EVENTS} cpu_ms_per_event={:.3} wall_ms_per_event={:.3}",
        cpu * 1000.0 / EVENTS as f64,
        wall.as_secs_f64() * 1000.0 / EVENTS as f64
    );
}

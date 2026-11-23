//! A changed row's `_acpmux/session_changed` is built once per record, however many connections
//! watch the list (`hub::SharedRow`). Held only while one watcher sent it, the row was built
//! again by nearly every watching connection: each connection's fan-out task takes the event on
//! its own wake, after the one before had dropped it. On Leo's Mac at load 70 to 185 the daemon
//! had 81 connections and fanned out about 108 events a second, and the fan-out to the last
//! connection took 33 to 79 ms at p95 (`gauges.fanout`, 2026-11-22). Leo, 2026-11-22: "the
//! interactive/visible parts of cmux are not prioritized enough".

use crate::config::{Config, StoreMode};
use crate::rpc::{Message, method};
use serde_json::{Value, json};
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

const WATCHERS: usize = 16;
const CHANGES: usize = 100;
const ROUNDS: usize = 3;

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

/// A local connection watching the list: its input (kept open: a closed request stream ends the
/// fan-out) and its outgoing lines.
async fn watching(hub: &Arc<crate::hub::Hub>) -> (mpsc::Sender<String>, mpsc::Receiver<String>) {
    let (input, incoming) = mpsc::channel(8);
    let (output, mut outgoing) = mpsc::channel(8192);
    tokio::spawn(super::serve_connection_with(hub.clone(), incoming, output, super::Origin::Local));
    let hello =
        json!({"protocolVersion": 1, "clientInfo": {"name": "row-share-test", "version": "0"}});
    input.send(Message::request(1, method::INITIALIZE, hello).to_line()).await.unwrap();
    input
        .send(Message::request(2, method::MUX_WATCH, json!({"enabled": true})).to_line())
        .await
        .unwrap();
    tokio::time::timeout(Duration::from_secs(20), async {
        loop {
            let line = outgoing.recv().await.unwrap();
            let reply: Value = serde_json::from_str(&line).unwrap();
            if reply["id"] == 2 {
                assert!(reply.get("error").is_none(), "{reply}");
                return;
            }
        }
    })
    .await
    .expect("the watch answers");
    (input, outgoing)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_changed_row_is_built_once_for_every_watching_connection() {
    for round in 0..ROUNDS {
        one_round(round).await;
    }
}

async fn one_round(round: usize) {
    let id = "row-share-chat";
    let (hub, session) = hub_with_chat(id);
    let mut inputs = Vec::new();
    let mut clients = Vec::new();
    for _ in 0..WATCHERS {
        let (input, outgoing) = watching(&hub).await;
        inputs.push(input);
        clients.push(outgoing);
    }
    let before = hub.session_row_builds.load(Ordering::Relaxed);
    let started = Instant::now();
    for n in 0..CHANGES {
        hub.append(&session, "mux", "tags", json!({"tags": [format!("t{n}")]}));
    }
    for client in &mut clients {
        let mut got = 0;
        tokio::time::timeout(Duration::from_secs(30), async {
            while got < CHANGES {
                let line = client.recv().await.unwrap();
                if line.contains("\"method\":\"_acpmux/session_changed\"") {
                    let v: Value = serde_json::from_str(&line).unwrap();
                    assert_eq!(v["params"]["sessionId"], json!(id));
                    assert_eq!(v["params"]["session"]["sessionId"], json!(id), "{line}");
                    got += 1;
                }
            }
        })
        .await
        .expect("every change reaches every watching connection");
    }
    let elapsed = started.elapsed();
    let built = hub.session_row_builds.load(Ordering::Relaxed) - before;
    eprintln!(
        "ROW-SHARE round {round} watchers {WATCHERS} changes {CHANGES} rows built {built} \
         per change {:.2} delivered in {:.1} ms",
        built as f64 / CHANGES as f64,
        elapsed.as_secs_f64() * 1e3
    );
    // One build per change when nothing else builds rows in this process; tests beside it share
    // the recent rows, so a few may go before every watcher took them. Per connection it was
    // close to WATCHERS per change.
    assert!(
        built as usize * 4 <= CHANGES * WATCHERS,
        "round {round}: {built} rows built for {CHANGES} changes to {WATCHERS} watchers"
    );
}

/// The rows held for sharing stay bounded however many are built.
#[test]
fn recent_rows_stay_bounded() {
    let cells: Vec<crate::hub::SharedRow> =
        (0..crate::hub::RECENT_ROWS * 3).map(|_| crate::hub::SharedRow::default()).collect();
    let rows: Vec<std::sync::Weak<Value>> = cells
        .iter()
        .map(|cell| {
            Arc::downgrade(&cell.get_or_build(|| Some(json!({"big": "x".repeat(64)}))).unwrap())
        })
        .collect();
    let live = rows.iter().filter(|row| row.strong_count() > 0).count();
    assert!(live <= crate::hub::RECENT_ROWS, "{live} rows held");
}

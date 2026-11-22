//! What one session's change costs the daemon's watchers (Leo 2026-11-04: "never ... acceptable
//! ... linear time growth degradation"): eight `_acpmux/watch` connections, one status record,
//! at 100, 1,000 and 3,000 sessions. Each watcher built the session's row again. Manual:
//! `cargo test -p acpmux --lib update_cost -- --ignored --nocapture --test-threads=1`.

use crate::config::{Config, StoreMode};
use crate::rpc::{Message, method};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

const WATCHERS: usize = 8;
const RECORDS: usize = 50;

fn hub_of(n: usize) -> (Arc<crate::hub::Hub>, Arc<crate::hub::Session>) {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = crate::hub::Hub::new(config, store);
    let mut live = None;
    for i in 0..n {
        let meta: crate::store::SessionMeta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": format!("s-{i:05}"),
            "name": format!("s-{i:05}"), "harness": "claude", "family": "claude", "cwd": "/w",
            "status": if i == 0 { "idle" } else { "closed" }, "createdAt": 1,
            "updatedAt": i + 1, "preview": "A short synthetic reply",
        }))
        .unwrap();
        let session = hub.insert_test_session(meta);
        if i == 0 {
            live = Some(session);
        }
    }
    (hub, live.unwrap())
}

async fn watching(hub: &Arc<crate::hub::Hub>) -> (mpsc::Sender<String>, mpsc::Receiver<String>) {
    let (input, incoming) = mpsc::channel(8);
    let (output, mut outgoing) = mpsc::channel(65_536);
    tokio::spawn(super::serve_connection_with(hub.clone(), incoming, output, super::Origin::Local));
    let hello = json!({"protocolVersion": 1, "clientInfo": {"name": "cost-test", "version": "0"}});
    input.send(Message::request(1, method::INITIALIZE, hello).to_line()).await.unwrap();
    input.send(Message::request(2, method::MUX_WATCH, json!({})).to_line()).await.unwrap();
    tokio::time::timeout(Duration::from_secs(60), async {
        loop {
            let reply: Value = serde_json::from_str(&outgoing.recv().await.unwrap()).unwrap();
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
#[ignore = "manual per-event cost measurement"]
async fn update_cost_watchers_session_changed() {
    for n in [100, 1_000, 3_000] {
        let (hub, live) = hub_of(n);
        let mut inputs = Vec::new();
        let mut clients = Vec::new();
        for _ in 0..WATCHERS {
            let (input, outgoing) = watching(&hub).await;
            inputs.push(input);
            clients.push(outgoing);
        }
        let started = Instant::now();
        for round in 0..RECORDS {
            let status = if round % 2 == 0 { "running" } else { "idle" };
            hub.append(&live, "mux", "status", json!({"status": status}));
        }
        for client in &mut clients {
            let mut got = 0;
            tokio::time::timeout(Duration::from_secs(60), async {
                while got < RECORDS {
                    if client.recv().await.unwrap().contains(method::MUX_SESSION_CHANGED) {
                        got += 1;
                    }
                }
            })
            .await
            .expect("every watcher hears every change");
        }
        let per = started.elapsed().as_secs_f64() * 1e6 / RECORDS as f64;
        eprintln!("UPDATE-COST watchers_session_changed n={n} per_event_us={per:.1}");
        drop(inputs);
    }
}

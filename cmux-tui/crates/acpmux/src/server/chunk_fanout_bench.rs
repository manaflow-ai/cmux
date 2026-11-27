//! What a streamed reply costs the daemon when many clients have its chat open (Leo, 2026-11-25:
//! "you guys should all be trying to optimize the fuck outta things"): 32 connections attached to
//! one chat as event streams, as the app's, the iPhone's and the web pane's are, and 5,000
//! `agent_message_chunk` records appended back to back, each a short token whose record carries
//! the agent's message and a reply segment as a live one does. Each connection's fan-out built
//! the record's `_acpmux/event` params anew and, for a client that asked for compact chunks,
//! copied them again to compare their shape (`chunk_deltas.rs`): three copies of the message per
//! connection per token. Manual, prints one `CHUNK-FANOUT` line per mode:
//! `cargo test --profile gate -p acpmux --lib chunk_fanout -- --ignored --nocapture --test-threads=1`.

use crate::config::{Config, StoreMode};
use crate::rpc::{Message, method};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

const CLIENTS: usize = 32;
const CHUNKS: usize = 5_000;

fn hub() -> (Arc<crate::hub::Hub>, Arc<crate::hub::Session>) {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = crate::hub::Hub::new(config, store);
    let meta: crate::store::SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "chat-bench", "name": "chat-bench",
        "harness": "claude", "family": "claude", "cwd": "/w", "status": "running",
        "createdAt": 1, "updatedAt": 1,
    }))
    .unwrap();
    let session = hub.insert_test_session(meta);
    (hub, session)
}

async fn attached(
    hub: &Arc<crate::hub::Hub>,
    deltas: bool,
) -> (mpsc::Sender<String>, mpsc::Receiver<String>) {
    let (input, incoming) = mpsc::channel(8);
    let (output, mut outgoing) = mpsc::channel(CHUNKS * 2);
    tokio::spawn(super::serve_connection_with(hub.clone(), incoming, output, super::Origin::Local));
    let hello = json!({"protocolVersion": 1, "clientInfo": {"name": "chunk-bench", "version": "0"},
        "_meta": {"acpmux": {"chunkDeltas": deltas}}});
    input.send(Message::request(1, method::INITIALIZE, hello).to_line()).await.unwrap();
    let attach = json!({"sessionId": "chat-bench", "eventStream": true});
    input.send(Message::request(2, method::MUX_ATTACH, attach).to_line()).await.unwrap();
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
    .expect("the attach answers");
    (input, outgoing)
}

fn chunk(i: usize) -> Value {
    json!({"jsonrpc": "2.0", "method": "session/update", "params": {
        "sessionId": "7f3e9a10-55b2-4c8d-a1e6-0b9c8d7e6f5a",
        "update": {"sessionUpdate": "agent_message_chunk",
            "content": {"type": "text", "text": format!(" token{i}")}},
        "_meta": {"acpmux": {"segment": "019a6c1f-0000-7aaa-8bbb-cccccccccccc.k3x9.1"}}}})
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "manual per-chunk fan-out cost measurement"]
async fn chunk_fanout_event_streams() {
    for deltas in [true, false] {
        let (hub, live) = hub();
        let mut inputs = Vec::new();
        let mut clients = Vec::new();
        for _ in 0..CLIENTS {
            let (input, outgoing) = attached(&hub, deltas).await;
            inputs.push(input);
            clients.push(outgoing);
        }
        let chunks: Vec<Value> = (0..CHUNKS).map(chunk).collect();
        let started = Instant::now();
        for msg in chunks {
            hub.append(&live, "in", "session/update", msg);
        }
        let appended = started.elapsed();
        let mut compact = 0;
        for client in &mut clients {
            let mut got = 0;
            tokio::time::timeout(Duration::from_secs(300), async {
                while got < CHUNKS {
                    let line = client.recv().await.unwrap();
                    if line.contains(method::MUX_CHUNK) {
                        compact += 1;
                        got += 1;
                    } else if line.contains("agent_message_chunk") {
                        got += 1;
                    }
                }
            })
            .await
            .expect("every client hears every chunk");
        }
        let total = started.elapsed();
        let per = total.as_secs_f64() * 1e6 / CHUNKS as f64;
        eprintln!(
            "CHUNK-FANOUT deltas={deltas} clients={CLIENTS} chunks={CHUNKS} compact={compact} \
             append_ms={:.1} total_ms={:.1} per_chunk_us={per:.1}",
            appended.as_secs_f64() * 1e3,
            total.as_secs_f64() * 1e3,
        );
        drop(inputs);
    }
}

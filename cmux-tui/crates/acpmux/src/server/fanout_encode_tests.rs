//! A streamed token's `session/update` line is built once, however many connections are attached
//! to its chat (HOT PATH AUDIT area F, row A4, handoff/hot-path-audit/stream/AUDIT.md). Each
//! attached connection copied the record's params, merged its `_meta` and encoded the line again:
//! with the app, a viewer and the TUI attached, three copies and three encodes per token. Measured
//! on the fleet (job 366c5a527e55, 16 chats streaming, 2 clients): token to client p95 2.3-2.9 ms
//! against ~0.3 ms with one chat.

use crate::config::{Config, StoreMode};
use crate::rpc::{Message, method};
use serde_json::{Value, json};
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::Duration;
use tokio::sync::mpsc;

const CONNECTIONS: usize = 4;
const TOKENS: usize = 100;

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

/// A local connection attached to `id`: its input (kept open: a closed request stream ends the
/// fan-out) and its outgoing lines.
async fn attached(
    hub: &Arc<crate::hub::Hub>,
    id: &str,
) -> (mpsc::Sender<String>, mpsc::Receiver<String>) {
    let (input, incoming) = mpsc::channel(8);
    let (output, mut outgoing) = mpsc::channel(4096);
    tokio::spawn(super::serve_connection_with(hub.clone(), incoming, output, super::Origin::Local));
    let hello =
        json!({"protocolVersion": 1, "clientInfo": {"name": "fanout-test", "version": "0"}});
    input.send(Message::request(1, method::INITIALIZE, hello).to_line()).await.unwrap();
    let attach = json!({"sessionId": id, "waitLogs": false, "limit": 0});
    input.send(Message::request(2, method::MUX_ATTACH, attach).to_line()).await.unwrap();
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
    .expect("the attach answers");
    (input, outgoing)
}

fn chunk(id: &str, n: usize) -> Value {
    json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": id,
        "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": format!("w{n} ")}}}})
}

/// Rounds of the whole scenario, each on a fresh hub and fresh connections: a race between the
/// connections that share one line would show in some round.
const ROUNDS: usize = 10;

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_streamed_tokens_line_is_built_once_for_every_attached_connection() {
    for round in 0..ROUNDS {
        one_round(round).await;
    }
}

async fn one_round(round: usize) {
    let id = "fanout-encode-chat";
    let (hub, session) = hub_with_chat(id);
    let mut inputs = Vec::new();
    let mut clients = Vec::new();
    for _ in 0..CONNECTIONS {
        let (input, outgoing) = attached(&hub, id).await;
        inputs.push(input);
        clients.push(outgoing);
    }
    let before = hub.session_update_encodes.load(Ordering::Relaxed);
    for n in 0..TOKENS {
        hub.append(&session, "in", "agent_message_chunk", chunk(id, n));
    }
    // Every connection gets every token, as the same line.
    let mut lines: Vec<Vec<String>> = Vec::new();
    for client in &mut clients {
        let mut got = Vec::new();
        tokio::time::timeout(Duration::from_secs(20), async {
            while got.len() < TOKENS {
                let line = client.recv().await.unwrap();
                if line.contains("\"method\":\"session/update\"") {
                    got.push(line);
                }
            }
        })
        .await
        .expect("every token reaches every attached connection");
        lines.push(got);
    }
    let Some((reference, others)) = lines.split_first() else { panic!("no connection") };
    for other in others {
        assert_eq!(
            other, reference,
            "round {round}: every connection gets the same line per token, in order"
        );
    }
    let texts: Vec<String> = reference
        .iter()
        .map(|line| {
            let v: Value = serde_json::from_str(line).unwrap();
            v.pointer("/params/update/content/text")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_owned()
        })
        .collect();
    let expected: Vec<String> = (0..TOKENS).map(|n| format!("w{n} ")).collect();
    assert_eq!(texts, expected, "round {round}: each token once, in order");
    let first: Value = serde_json::from_str(reference.first().unwrap()).unwrap();
    assert_eq!(first["params"]["sessionId"], json!(id));
    assert_eq!(first["params"]["_meta"]["acpmux"]["kind"], json!("agent_message_chunk"));
    let built = hub.session_update_encodes.load(Ordering::Relaxed) - before;
    eprintln!(
        "FANOUT-ENCODE round {round} connections {CONNECTIONS} tokens {TOKENS} lines built {built}"
    );
    assert_eq!(
        built, TOKENS as u64,
        "round {round}: {built} session/update lines built for {TOKENS} tokens to {CONNECTIONS} connections"
    );
}

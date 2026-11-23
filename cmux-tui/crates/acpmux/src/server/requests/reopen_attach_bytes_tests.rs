//! A reopen's `_acpmux/attach {afterSeq}` (iOS `AcpmuxHub.swift` reopen, the web pane's
//! reconnect) costs what changed since its cursor, not the chat's length. The network-conditions
//! harness (`tests/mobile_link_conditions.rs`, warm phase) measured its reply at ~9.5 KB on a
//! 20-turn chat and ~71.5 KB on a 2,000-turn one with nothing new after the cursor: the reply's
//! `session` detail carries the chat's whole `timeBreakdown` (up to 512 spans, one per turn,
//! `time_breakdown.rs` `MAX_SPANS`), sent again on every reattach.

use crate::config::{Config, StoreMode};
use crate::rpc::{Message, method};
use crate::store::EventRecord;
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

const ID: &str = "reopen-bytes-chat";

/// A chat of `turns` finished turns, each a prompt, its start, one answer chunk and its result,
/// half a second apart so every turn folds to a span. Returns the hub and the newest seq.
fn hub_with_turns(turns: u64) -> (Arc<crate::hub::Hub>, u64) {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let mut meta: crate::store::SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": ID, "name": "reopen", "harness": "claude",
        "cwd": "/tmp", "status": "idle", "createdAt": 3, "updatedAt": 3,
    }))
    .unwrap();
    store.save(&meta).unwrap();
    let mut seq = 0;
    let mut push = |at: u64, dir: &str, kind: &str, msg: Value| {
        seq += 1;
        let rec = EventRecord { seq, at, dir: dir.into(), kind: kind.into(), msg, host_seq: None };
        store.append(ID, &rec).unwrap();
    };
    for turn in 0..turns {
        let at = 1_000_000 + turn * 1_000;
        let (prompt, id) = (format!("p{turn}"), format!("t{turn}"));
        push(at, "mux", "user_message", json!({"text": "go on", "promptId": prompt, "turnId": id}));
        push(at, "mux", "turn_started", json!({"promptId": prompt, "turnId": id}));
        let update = json!({"sessionUpdate": "agent_message_chunk",
                            "content": {"type": "text", "text": "ok"}});
        push(
            at + 10,
            "in",
            "agent_message_chunk",
            json!({"jsonrpc": "2.0", "method": "session/update",
                   "params": {"sessionId": ID, "update": update}}),
        );
        push(
            at + 500,
            "mux",
            "turn_result",
            json!({"status": "completed", "turnId": id, "promptId": prompt}),
        );
    }
    meta.last_seq = seq;
    meta.event_count = seq;
    store.save(&meta).unwrap();
    let hub = crate::hub::Hub::new(config, store);
    let session = hub.make_session(meta);
    hub.sessions.lock().unwrap().insert(ID.to_owned(), session);
    (hub, seq)
}

struct Client {
    input: mpsc::Sender<String>,
    outgoing: mpsc::Receiver<String>,
    next: u64,
}

impl Client {
    async fn connect(hub: &Arc<crate::hub::Hub>) -> Self {
        let (input, incoming) = mpsc::channel(32);
        let (output, outgoing) = mpsc::channel(4096);
        tokio::spawn(super::super::serve_connection_with(
            hub.clone(),
            incoming,
            output,
            super::super::Origin::Local,
        ));
        let mut client = Self { input, outgoing, next: 1 };
        let hello = json!({"protocolVersion": 1, "clientInfo": {"name": "reopen-bytes-test", "version": "0"}});
        let (_, init) = client.call(method::INITIALIZE, hello).await;
        assert!(init.get("error").is_none(), "{init}");
        client
    }

    /// The reply and its size on the wire.
    async fn call(&mut self, m: &str, params: Value) -> (usize, Value) {
        let id = self.next;
        self.next += 1;
        self.input.send(Message::request(id, m, params).to_line()).await.unwrap();
        tokio::time::timeout(Duration::from_secs(20), async {
            loop {
                let line = self.outgoing.recv().await.expect("connection remains open");
                let reply: Value = serde_json::from_str(&line).unwrap();
                if reply["id"] == json!(id) && reply.get("method").is_none() {
                    return (line.len(), reply);
                }
            }
        })
        .await
        .expect("request answers")
    }
}

/// The phone's open, then its reopen with afterSeq = the newest record it holds (the harness's
/// cold and warm phases): the reopen's reply size.
async fn reopen_reply_bytes(turns: u64) -> usize {
    let (hub, last) = hub_with_turns(turns);
    let mut client = Client::connect(&hub).await;
    let open = json!({"sessionId": ID, "limit": 400, "eventStream": true,
                      "maxBytes": 128 * 1024, "toolOutputMaxBytes": 64 * 1024});
    let (_, reply) = client.call(method::MUX_ATTACH, open).await;
    assert!(reply.get("error").is_none(), "{reply}");
    // The open starts the chat's time breakdown in the background; the reopen comes after it.
    let s = hub.resolve(ID).unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    while !hub.session_detail(&s)["timeBreakdown"].is_object() {
        assert!(Instant::now() < deadline, "the time breakdown never seeded");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    let reopen = json!({"sessionId": ID, "limit": 400, "eventStream": true, "afterSeq": last});
    let (bytes, reply) = client.call(method::MUX_ATTACH, reopen).await;
    assert!(reply.get("error").is_none(), "{reply}");
    assert_eq!(reply["result"]["events"], json!([]), "nothing is newer than afterSeq");
    let spans = reply["result"]["session"]["timeBreakdown"]["spans"].as_array().map_or(0, Vec::len);
    eprintln!(
        "reopen afterSeq={last} on {turns} turns: {bytes} bytes, timeBreakdown spans {spans}"
    );
    bytes
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_reopen_with_nothing_new_costs_the_same_on_a_long_chat() {
    let short = reopen_reply_bytes(20).await;
    let long = reopen_reply_bytes(2_000).await;
    assert!(
        long <= short + 4 * 1024,
        "a reopen with nothing after afterSeq grew with the chat's length: {short} bytes at 20 \
         turns, {long} at 2,000"
    );
}

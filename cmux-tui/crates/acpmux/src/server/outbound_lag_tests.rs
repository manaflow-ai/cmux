//! A follower that stops reading while its chat streams costs a small, fixed number of bytes,
//! however much the chat streams, and keeps its connection.
//!
//! Before, each connection's queue held up to 64 MiB of `session/update` lines it would throw away
//! anyway at its next resync, and ended the connection past that: a coordinator-load run (20
//! coordinators) had 107-125 MB in the daemon's outbound queues and 380-579 MB of RSS. Now the
//! queue drops the stream lines it holds once it is past [`super::outbound::LAG_BOUND`] and sends
//! one `_acpmux/lagged` in their place; the follower reads the chat again from its cursor when it
//! reads that note. Replies to its requests are kept.

use crate::config::{Config, StoreMode};
use crate::rpc::{Message, method};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

/// Updates streamed while the follower does not read: about 100 MB of lines.
const UPDATES: usize = 100_000;
/// Each update's text: with its envelope, a line of about 1.1 KB.
const TEXT: usize = 1_000;
/// What the stopped follower may hold, its transport's channel included: 1/16 of the old 64 MiB.
const BOUND: usize = 4 << 20;
/// A daemon's WebSocket output channel (`server/mod.rs`): 4,096 lines.
const CHANNEL: usize = 4096;

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

async fn reply(rx: &mut mpsc::Receiver<String>, id: u64) {
    tokio::time::timeout(Duration::from_secs(20), async {
        loop {
            let line = rx.recv().await.expect("the connection stays open");
            let frame: Value = serde_json::from_str(&line).unwrap();
            if frame["id"] == id {
                assert!(frame.get("error").is_none(), "{frame}");
                return;
            }
        }
    })
    .await
    .expect("a reply");
}

fn chunk(id: &str, n: usize) -> Value {
    let text = format!("lag-delta {n} {}", "x".repeat(TEXT));
    json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": id,
        "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}}}})
}

/// A record's seq in a stream line: a `session/update`'s `_meta`, or an event's own.
fn seq_of(frame: &Value) -> Option<u64> {
    frame
        .pointer("/params/_meta/acpmux/seq")
        .or_else(|| frame.pointer("/params/seq"))
        .and_then(Value::as_u64)
}

async fn a_stopped_follower_costs_bounded_bytes(event_stream: bool) {
    let id = if event_stream { "lag-follower-events" } else { "lag-follower-updates" };
    let name = format!("{id}-client");
    let (hub, session) = hub_with_chat(id);
    let (input, incoming) = mpsc::channel(64);
    let (output, mut rx) = mpsc::channel(CHANNEL);
    tokio::spawn(super::serve_connection_with(hub.clone(), incoming, output, super::Origin::Local));
    let hello = json!({"protocolVersion": 1, "clientInfo": {"name": name, "version": "0"}});
    input.send(Message::request(1, method::INITIALIZE, hello).to_line()).await.unwrap();
    reply(&mut rx, 1).await;
    let attach =
        json!({"sessionId": id, "waitLogs": false, "limit": 0, "eventStream": event_stream});
    input.send(Message::request(2, method::MUX_ATTACH, attach).to_line()).await.unwrap();
    reply(&mut rx, 2).await;
    let conn = super::queue_gauge::live()
        .into_iter()
        .find(|c| *c.name.lock().unwrap() == name)
        .expect("the follower's connection is served");

    // The follower stops reading; the chat streams.
    let mut peak = 0;
    for n in 0..UPDATES {
        hub.append(&session, "in", "agent_message_chunk", chunk(id, n));
        if n == UPDATES / 2 {
            // Requests while it lags: a cheap read and a bulk-lane read.
            input.send(Message::request(3, method::MUX_STATUS, json!({})).to_line()).await.unwrap();
            let events = json!({"sessionId": id, "afterSeq": 0, "limit": 1});
            input.send(Message::request(4, method::MUX_EVENTS, events).to_line()).await.unwrap();
        }
        // Paced, so the hub's event ring (8,192 events) never laps the connection's fan-out:
        // what is measured is the connection's own queue.
        if n % 128 == 0 {
            peak = peak.max(conn.out.gauge().bytes);
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
    }
    tokio::time::sleep(Duration::from_millis(200)).await;
    peak = peak.max(conn.out.gauge().bytes);
    assert!(!conn.out.gauge().overrun, "a lagging follower is never disconnected");

    // It reads again: in order, one resync note where its stream lines were dropped, the replies.
    let (mut slow_notes, mut ring_notes, mut replies) = (0, 0, Vec::new());
    let mut last_seq: Option<u64> = None;
    let mut told_since_gap = false;
    loop {
        let line = match tokio::time::timeout(Duration::from_secs(2), rx.recv()).await {
            Ok(Some(line)) => line,
            Ok(None) => panic!("the follower's connection ended"),
            Err(_) => break,
        };
        let frame: Value = serde_json::from_str(&line).unwrap();
        if frame["method"] == "_acpmux/lagged" {
            if frame["params"]["reason"] == "slow_reader" {
                slow_notes += 1;
            } else {
                ring_notes += 1;
            }
            told_since_gap = true;
            continue;
        }
        if let Some(n) = frame["id"].as_u64() {
            assert!(frame.get("error").is_none(), "{frame}");
            replies.push(n);
            continue;
        }
        if let Some(seq) = seq_of(&frame) {
            if let Some(last) = last_seq
                && seq > last + 1
            {
                assert!(
                    told_since_gap,
                    "records {}..{seq} were dropped with no note before them",
                    last + 1
                );
            }
            last_seq = Some(seq);
            told_since_gap = false;
        }
    }
    eprintln!(
        "OUTBOUND-LAG event_stream={event_stream} updates={UPDATES} peak_queued_bytes={peak} \
         slow_reader_notes={slow_notes} ring_notes={ring_notes} replies={replies:?}"
    );
    assert!(peak <= BOUND, "the stopped follower held {peak} bytes, past {BOUND}");
    assert_eq!(slow_notes, 1, "exactly one resync note for one stretch of not reading");
    replies.sort_unstable();
    assert_eq!(replies, [3, 4], "every request is answered");
    drop(input);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_stopped_update_follower_holds_a_bounded_queue_and_one_resync_note() {
    a_stopped_follower_costs_bounded_bytes(false).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_stopped_event_stream_follower_holds_a_bounded_queue_and_one_resync_note() {
    a_stopped_follower_costs_bounded_bytes(true).await;
}

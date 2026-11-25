//! A follower that falls a lap behind the hub's event ring still gets every record of the chat
//! it follows, once and in order (`stream_cursor.rs`). Before, the fan-out went on from the
//! oldest event left in the ring and sent only `_acpmux/lagged`: the lapped records never came
//! (coord-sim, cmux#47266: 10,697 agent updates missed at 20 coordinators x 10 followers).

use crate::config::{Config, StoreMode};
use crate::rpc::{Message, method};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

/// More than the ring holds (8,192), written while the follower's fan-out cannot run.
const RECORDS: u64 = 12_000;

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

async fn call(
    input: &mpsc::Sender<String>,
    out: &mut mpsc::Receiver<String>,
    id: i64,
    m: &str,
    p: Value,
) -> Value {
    input.send(Message::request(id, m, p).to_line()).await.unwrap();
    tokio::time::timeout(Duration::from_secs(20), async {
        loop {
            let line = out.recv().await.unwrap();
            let reply: Value = serde_json::from_str(&line).unwrap();
            if reply["id"] == id && reply.get("method").is_none() {
                assert!(reply.get("error").is_none(), "{reply}");
                return reply["result"].clone();
            }
        }
    })
    .await
    .expect("the call answers")
}

fn chunk(id: &str, n: u64) -> Value {
    json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": id,
        "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": format!("w{n}")}}}})
}

/// One thread: while the loop below appends, nothing else runs, so the follower's fan-out
/// falls a whole lap behind, as a busy daemon's does.
#[tokio::test(flavor = "current_thread")]
async fn a_follower_a_lap_behind_the_ring_gets_every_record_once_in_order() {
    let id = "lap-chat";
    let (hub, session) = hub_with_chat(id);
    let (input, incoming) = mpsc::channel(8);
    let (output, mut out) = mpsc::channel(1 << 16);
    tokio::spawn(super::serve_connection_with(hub.clone(), incoming, output, super::Origin::Local));
    let hello = json!({"protocolVersion": 1, "clientInfo": {"name": "lap-test", "version": "0"}});
    call(&input, &mut out, 1, method::INITIALIZE, hello).await;
    // Something before the attach: the stream starts after it, never replays it.
    hub.append(&session, "in", "agent_message_chunk", chunk(id, 0));
    let attach = json!({"sessionId": id, "waitLogs": false, "limit": 0, "eventStream": true,
        "kinds": ["transcript"], "visible": true});
    call(&input, &mut out, 2, method::MUX_ATTACH, attach).await;
    let first = session.meta().last_seq + 1;
    for n in 1..=RECORDS {
        hub.append(&session, "in", "agent_message_chunk", chunk(id, n));
    }
    let last = session.meta().last_seq;
    let mut seqs = Vec::new();
    let mut lagged = 0;
    tokio::time::timeout(Duration::from_secs(60), async {
        while seqs.last().copied() != Some(last) {
            let line = out.recv().await.expect("the connection stays open");
            let v: Value = serde_json::from_str(&line).unwrap();
            match v["method"].as_str() {
                Some("_acpmux/lagged") => lagged += 1,
                Some(method::MUX_EVENT) if v["params"]["sessionId"] == id => {
                    seqs.push(v["params"]["seq"].as_u64().unwrap());
                }
                _ => {}
            }
        }
    })
    .await
    .unwrap_or_else(|_| {
        panic!(
            "the follower never got the chat's last record {last}: {} records, the last {:?}",
            seqs.len(),
            seqs.last()
        )
    });
    assert!(lagged > 0, "the follower never fell a lap behind: the test proves nothing");
    let expected: Vec<u64> = (first..=last).collect();
    let missing = expected.iter().filter(|s| !seqs.contains(s)).count();
    let mut sorted = seqs.clone();
    sorted.sort_unstable();
    sorted.dedup();
    assert_eq!(
        seqs.len(),
        sorted.len(),
        "a record came twice ({} records, {} distinct)",
        seqs.len(),
        sorted.len()
    );
    assert_eq!(missing, 0, "{missing} of {} records never came after the lap", expected.len());
    assert_eq!(seqs, expected, "the records came out of order");
}

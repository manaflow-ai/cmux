//! ACP's `session/list` on a daemon that mirrors a fleet: one daemon's list was 5241 rows with
//! tools, 17 MB (2026-10-30), over the 15 MiB message limit, so the whole list came back as
//! `message.too_large`. A list too large for one message goes in pages (ACP's `cursor` and
//! `nextCursor`), each under the limit; one that fits is still sent whole.

use crate::config::{Config, StoreMode};
use crate::peer::{Peer, PeerNotice};
use crate::rpc::{MAX_MESSAGE_BYTES, Message, method};
use serde_json::{Value, json};
use std::collections::HashSet;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

/// A hub mirroring `rows` chats from each of `peers` peers, each with a tool list of about 3.4 KB.
async fn fleet_hub(peers: usize, rows: usize) -> Arc<crate::hub::Hub> {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = crate::hub::Hub::new(config, store);
    for p in 0..peers {
        let name = format!("peer-{p}");
        let (tx, _rx) = mpsc::channel(8);
        let peer = Peer::new(&name, "ws://127.0.0.1:9", None, None, tx);
        hub.peers.lock().unwrap().insert(name.clone(), peer.clone());
        let list = (0..rows)
            .map(|i| {
                json!({"sessionId": format!("{name}-chat-{i}"), "name": format!("chat-{i}"),
                    "harness": "claude", "cwd": "/work", "status": "idle",
                    "updatedAt": (p * rows + i + 1) as u64,
                    "tools": [{"id": "tool", "description": "x".repeat(3300)}]})
            })
            .collect();
        let mut settled = peer.settled();
        for notice in [PeerNotice::Sessions(list), PeerNotice::Connected] {
            hub.peer_notices.send((name.clone(), peer.generation, notice)).await.unwrap();
        }
        tokio::time::timeout(Duration::from_secs(10), settled.wait_for(|n| *n >= 1))
            .await
            .expect("the hub applies the notices")
            .unwrap();
    }
    assert_eq!(hub.remote_sessions().len(), peers * rows);
    hub
}

/// Each `session/list` reply line, following `nextCursor` to the end, on one connection, with
/// how long it took.
async fn acp_pages(hub: &Arc<crate::hub::Hub>) -> Vec<(Value, usize, Duration)> {
    let (input, incoming) = mpsc::channel(8);
    let (output, mut outgoing) = mpsc::channel(8);
    let task = tokio::spawn(super::serve_connection(hub.clone(), incoming, output));
    input
        .send(Message::request(1, method::INITIALIZE, json!({"protocolVersion": 1})).to_line())
        .await
        .unwrap();
    let mut pages = Vec::new();
    let mut params = json!({});
    for id in 2..100 {
        let started = std::time::Instant::now();
        input
            .send(Message::request(id, method::SESSION_LIST, params.clone()).to_line())
            .await
            .unwrap();
        let (reply, bytes) = tokio::time::timeout(Duration::from_secs(30), async {
            loop {
                let line = outgoing.recv().await.unwrap();
                let reply: Value = serde_json::from_str(&line).unwrap();
                if reply["id"] == id {
                    return (reply, line.len());
                }
            }
        })
        .await
        .expect("the page comes");
        assert!(reply.get("error").is_none(), "page {}: {}", pages.len(), reply["error"]);
        let next = reply["result"]["nextCursor"].clone();
        pages.push((reply["result"].clone(), bytes, started.elapsed()));
        if !next.is_string() {
            task.abort();
            return pages;
        }
        params = json!({"cursor": next});
    }
    panic!("the pages never end");
}

#[tokio::test]
async fn a_fleet_sized_acp_list_goes_in_pages_under_the_message_limit() {
    // 25 peers with 210 chats each: 5250 rows, about as many as that daemon listed.
    let hub = fleet_hub(25, 210).await;
    let pages = acp_pages(&hub).await;
    let total: usize = pages.iter().map(|(_, bytes, _)| bytes).sum();
    assert!(total > MAX_MESSAGE_BYTES, "the list is not past the limit: {total} bytes");
    let mut seen = HashSet::new();
    for (page, bytes, _) in &pages {
        assert!(*bytes <= MAX_MESSAGE_BYTES, "a page of {bytes} bytes");
        for row in page["sessions"].as_array().unwrap() {
            assert!(row["_meta"]["acpmux"]["tools"].is_array(), "a row lost its tools: {row}");
            let id = row["sessionId"].as_str().unwrap().to_owned();
            assert!(seen.insert(id.clone()), "{id} came twice");
        }
    }
    assert_eq!(seen.len(), 25 * 210);
    let ms: Vec<u128> = pages.iter().map(|(_, _, took)| took.as_millis()).collect();
    println!("PERF acp_list rows={} bytes={total} pages={} ms={ms:?}", seen.len(), pages.len());
}

#[tokio::test]
async fn an_acp_list_that_fits_is_one_reply_with_no_cursor() {
    let hub = fleet_hub(2, 20).await;
    let pages = acp_pages(&hub).await;
    assert_eq!(pages.len(), 1);
    assert_eq!(pages[0].0["sessions"].as_array().unwrap().len(), 40);
    assert!(pages[0].0.get("nextCursor").is_none(), "{}", pages[0].0["nextCursor"]);
}

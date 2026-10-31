//! Every session list page and session detail fits one message as a whole. On 2026-10-31
//! `acpmux ls` failed on a fleet host with "message too large to send: 16927852 bytes, the
//! limit is 15728640": a page of `limit` rows was cut by count alone, and a reply refused as
//! too large is refused again on every retry. Here the list (and one row of it alone) is past
//! the limit, and every read still lists every id.

use crate::config::{Config, StoreMode};
use crate::peer::{Peer, PeerNotice};
use crate::rpc::{MAX_MESSAGE_BYTES, Message, method};
use serde_json::{Value, json};
use std::collections::HashSet;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const ROWS: usize = 1000;
const BIG: &str = "peer-chat-big";
const LOCAL: &str = "local-long-title";

/// A hub with a chat of its own titled with 16 MiB, and mirroring `ROWS` chats of 20 KB each
/// from its peer, plus one of 16 MiB: the list and that one row are each past the limit.
async fn big_hub() -> Arc<crate::hub::Hub> {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let meta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": LOCAL, "name": LOCAL, "title": "t".repeat(16 << 20),
        "harness": "fake", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1
    }))
    .unwrap();
    store.save(&meta).unwrap();
    let hub = crate::hub::Hub::new(config, store);
    let (tx, _rx) = mpsc::channel(8);
    let peer = Peer::new("box", "ws://127.0.0.1:9", None, None, tx);
    hub.peers.lock().unwrap().insert("box".to_owned(), peer.clone());
    let row = |id: String, at: usize, step: usize| {
        json!({"sessionId": id, "name": "lane", "harness": "claude", "cwd": "/work",
            "status": "idle", "updatedAt": at as u64 + 10, "planStep": "x".repeat(step)})
    };
    let mut list: Vec<Value> =
        (0..ROWS).map(|i| row(format!("peer-chat-{i}"), i, 20_000)).collect();
    list.push(row(BIG.to_owned(), ROWS / 2, 16 << 20));
    let mut settled = peer.settled();
    for notice in [PeerNotice::Sessions(list), PeerNotice::Connected] {
        hub.peer_notices.send(("box".to_owned(), peer.generation, notice)).await.unwrap();
    }
    tokio::time::timeout(Duration::from_secs(10), settled.wait_for(|n| *n >= 1))
        .await
        .expect("the hub applies the notices")
        .unwrap();
    assert_eq!(hub.remote_sessions().len(), ROWS + 1);
    hub
}

/// A connection to `hub` that sends requests and returns each reply with its line's size.
struct Client {
    input: mpsc::Sender<String>,
    outgoing: mpsc::Receiver<String>,
    id: u64,
}

impl Client {
    async fn new(hub: &Arc<crate::hub::Hub>) -> Self {
        let (input, incoming) = mpsc::channel(8);
        let (output, outgoing) = mpsc::channel(8);
        tokio::spawn(super::serve_connection(hub.clone(), incoming, output));
        let mut client = Self { input, outgoing, id: 0 };
        client.call(method::INITIALIZE, json!({"protocolVersion": 1})).await;
        client
    }

    async fn call(&mut self, m: &str, params: Value) -> (Value, usize) {
        self.id += 1;
        let id = self.id;
        self.input.send(Message::request(id, m, params).to_line()).await.unwrap();
        tokio::time::timeout(Duration::from_secs(60), async {
            loop {
                let line = self.outgoing.recv().await.unwrap();
                let reply: Value = serde_json::from_str(&line).unwrap();
                if reply["id"] == id {
                    return (reply, line.len());
                }
            }
        })
        .await
        .expect("the reply comes")
    }

    /// Every `_acpmux/sessions` row for `params`, following `nextCursor`; each reply under the
    /// message limit.
    async fn rows(&mut self, params: Value) -> Vec<Value> {
        let mut rows = Vec::new();
        let mut cursor = Value::Null;
        for page in 0..100 {
            let mut p = params.clone();
            p["cursor"] = cursor;
            let (reply, bytes) = self.call(method::MUX_SESSIONS, p).await;
            assert!(reply.get("error").is_none(), "{params} page {page}: {}", reply["error"]);
            assert!(bytes <= MAX_MESSAGE_BYTES, "{params} page {page}: {bytes} bytes");
            rows.extend(reply["result"]["sessions"].as_array().unwrap().iter().cloned());
            cursor = reply["result"]["nextCursor"].clone();
            if !cursor.is_string() {
                return rows;
            }
        }
        panic!("{params}: the pages never end");
    }
}

#[tokio::test]
async fn a_list_and_a_row_each_past_the_message_limit_still_list_every_id() {
    let hub = big_hub().await;
    let mut client = Client::new(&hub).await;
    // `acpmux ls`'s pages (limit 1000), with tools, and with no limit at all.
    for params in [
        json!({"limit": 1000, "usage": true}),
        json!({"limit": 1000, "withTools": true}),
        json!({}),
        json!({"localOnly": true, "orderBy": "sessionId", "limit": 1000}),
    ] {
        let rows = client.rows(params.clone()).await;
        let ids: HashSet<&str> = rows.iter().filter_map(|r| r["sessionId"].as_str()).collect();
        if params.get("localOnly").is_some() {
            assert_eq!(ids, HashSet::from([LOCAL]), "{params}");
            continue;
        }
        assert_eq!(ids.len(), ROWS + 2, "{params}: {} ids", ids.len());
        let big = rows.iter().find(|r| r["sessionId"] == BIG).unwrap();
        // The row is trimmed, not dropped: its keys stay, and it says what it lost.
        assert_eq!((big["status"].as_str(), big["peer"].as_str()), (Some("idle"), Some("box")));
        assert_eq!(big["cwd"], "/work", "{params}");
        assert!(big["planStep"].as_str().is_some_and(|s| s.len() <= 1 << 10), "{params}");
        assert_eq!(big["omitted"]["reason"], "too_large", "{params}");
        assert_eq!(big["omitted"]["fields"], json!(["planStep"]), "{params}");
        let small = rows.iter().find(|r| r["sessionId"] == "peer-chat-7").unwrap();
        assert_eq!(small["planStep"].as_str().map(str::len), Some(20_000), "{params}");
    }
}

#[tokio::test]
async fn a_session_info_past_the_message_limit_comes_trimmed() {
    let hub = big_hub().await;
    let mut client = Client::new(&hub).await;
    let (reply, bytes) =
        client.call(method::MUX_INFO, json!({"sessionId": LOCAL, "waitLogs": false})).await;
    assert!(reply.get("error").is_none(), "{}", reply["error"]);
    assert!(bytes <= MAX_MESSAGE_BYTES, "{bytes} bytes");
    let detail = &reply["result"];
    assert_eq!((detail["sessionId"].as_str(), detail["cwd"].as_str()), (Some(LOCAL), Some("/tmp")));
    assert!(detail["title"].as_str().is_some_and(|t| t.starts_with('t') && t.len() <= 1 << 10));
    assert!(detail["omitted"]["fields"].as_array().unwrap().contains(&json!("title")));
}

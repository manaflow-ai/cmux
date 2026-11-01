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
    big_hub_with(Vec::new()).await
}

/// [`big_hub`] with `extra` rows from the peer too.
async fn big_hub_with(extra: Vec<Value>) -> Arc<crate::hub::Hub> {
    let extras = extra.len();
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
    list.extend(extra);
    let mut settled = peer.settled();
    for notice in [PeerNotice::Sessions(list), PeerNotice::Connected] {
        hub.peer_notices.send(("box".to_owned(), peer.generation, notice)).await.unwrap();
    }
    tokio::time::timeout(Duration::from_secs(10), settled.wait_for(|n| *n >= 1))
        .await
        .expect("the hub applies the notices")
        .unwrap();
    assert_eq!(hub.remote_sessions().len(), ROWS + 1 + extras);
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
        Self::on(hub, super::Origin::Local).await
    }

    /// A connection of `origin`: a peer's reads its summaries masked (`peer_text.rs`).
    async fn on(hub: &Arc<crate::hub::Hub>, origin: super::Origin) -> Self {
        let (input, incoming) = mpsc::channel(8);
        let (output, outgoing) = mpsc::channel(8);
        tokio::spawn(super::serve_connection_with(hub.clone(), incoming, output, origin));
        let mut client = Self { input, outgoing, id: 0 };
        let hello = json!({"protocolVersion": 1, "clientInfo":
            {"name": crate::peer::CLIENT_NAME, "version": "0"}});
        client.call(method::INITIALIZE, hello).await;
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

/// A fake token the secret scanner masks (`secret_scan_tests.rs`).
fn token(seed: &str) -> String {
    let body: String = "aZ3kQ9mX7pL2vB8nR4tW6yC1dF5gH0jS".chars().cycle().take(36).collect();
    format!("gh{}_{seed}{}", "p", body.get(seed.len()..).unwrap())
}

/// A row trimmed to fit goes to a peer masked: it keeps what masking knows a summary by, and a
/// secret its preview's cut would split is masked before the cut, never left as a head.
#[tokio::test]
async fn a_trimmed_row_still_goes_to_a_peer_masked() {
    let (head, cut) = (token("Head"), token("Cut"));
    // The second starts 20 bytes before the 1 KiB preview ends: the cut would split it.
    let mut prompt = format!("run {head} then ");
    prompt.push_str(&"p".repeat(1004 - prompt.len()));
    prompt.push_str(&cut);
    prompt.push_str(&"q".repeat(16 << 20));
    let row = json!({"sessionId": "secret-chat", "harness": "claude", "lastSeq": 3,
        "cwd": "/work", "status": "idle", "updatedAt": 99_999, "lastPrompt": prompt});
    let hub = big_hub_with(vec![row]).await;
    let mut client = Client::on(&hub, super::Origin::Peer).await;
    for params in [json!({"limit": 1000}), json!({})] {
        let rows = client.rows(params.clone()).await;
        let row = rows.iter().find(|r| r["sessionId"] == "secret-chat").expect("listed");
        assert_eq!(row["lastSeq"], 3, "{params}");
        assert_eq!(row["omitted"]["fields"], json!(["lastPrompt"]), "{params}");
        let shown = row["lastPrompt"].as_str().unwrap();
        assert!(shown.starts_with("run "), "{params}: {shown:.40}");
        for secret in [&head, &cut] {
            let start = secret.get(..12).unwrap();
            assert!(!shown.contains(start), "{params}: {start} in {shown}");
        }
    }
}

//! `_acpmux/sessions {pendingOnly: true}`: only the chats that wait on an ask, read without the
//! list guard. On 2026-11-02 a Mac whose daemon mirrored 8,572 chats from its peers paced each
//! 64-row page of its list 4-9 s, and the app's dialog list (`cmux agents dialog list`, the
//! `agents_dialog_list` and `agents_wait` tools) read every page before it found the one chat
//! with an ask: it timed out at 5 s every time.

use crate::config::{Config, StoreMode};
use crate::peer::{Peer, PeerNotice};
use crate::rpc::{Message, method};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const ROWS: usize = 300;
const LOCAL: &str = "local-idle";

/// A hub with an idle chat of its own and `ROWS` peer chats, of which every 100th waits on an ask.
async fn hub() -> Arc<crate::hub::Hub> {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let meta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": LOCAL, "name": LOCAL, "title": "t",
        "harness": "fake", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1
    }))
    .unwrap();
    store.save(&meta).unwrap();
    let hub = crate::hub::Hub::new(config, store);
    let (tx, _rx) = mpsc::channel(8);
    let peer = Peer::new("box", "ws://127.0.0.1:9", None, None, tx);
    hub.peers.lock().unwrap().insert("box".to_owned(), peer.clone());
    let list: Vec<Value> = (0..ROWS)
        .map(|i| {
            let pending = u64::from(i % 100 == 7);
            json!({"sessionId": format!("peer-chat-{i}"), "name": "lane", "harness": "claude",
                "cwd": "/work", "status": if pending == 1 { "waiting" } else { "idle" },
                "updatedAt": i as u64 + 10, "pendingPermissions": pending,
                "tools": [{"name": "Bash"}]})
        })
        .collect();
    let mut settled = peer.settled();
    for notice in [PeerNotice::Sessions(list), PeerNotice::Connected] {
        hub.peer_notices.send(("box".to_owned(), peer.generation, notice)).await.unwrap();
    }
    tokio::time::timeout(Duration::from_secs(10), settled.wait_for(|n| *n >= 1))
        .await
        .expect("the hub applies the notices")
        .unwrap();
    assert_eq!(hub.remote_sessions().len(), ROWS);
    hub
}

/// One request on a fresh local connection to `hub`, and its reply.
async fn call(hub: &Arc<crate::hub::Hub>, m: &str, params: Value) -> Value {
    let (input, incoming) = mpsc::channel(8);
    let (output, mut outgoing) = mpsc::channel(8);
    tokio::spawn(super::serve_connection_with(hub.clone(), incoming, output, super::Origin::Local));
    let hello = json!({"protocolVersion": 1, "clientInfo":
        {"name": crate::peer::CLIENT_NAME, "version": "0"}});
    input.send(Message::request(1, method::INITIALIZE, hello).to_line()).await.unwrap();
    input.send(Message::request(2, m, params).to_line()).await.unwrap();
    tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            let reply: Value = serde_json::from_str(&outgoing.recv().await.unwrap()).unwrap();
            if reply["id"] == 2 {
                return reply;
            }
        }
    })
    .await
    .expect("the reply comes")
}

#[tokio::test]
async fn a_pending_only_list_holds_only_the_chats_that_wait_on_an_ask() {
    let hub = hub().await;
    let reply = call(&hub, method::MUX_SESSIONS, json!({"pendingOnly": true})).await;
    assert!(reply.get("error").is_none(), "{}", reply["error"]);
    let rows = reply["result"]["sessions"].as_array().unwrap();
    let ids: Vec<&str> = rows.iter().filter_map(|r| r["sessionId"].as_str()).collect();
    // Newest first, the list's order; the idle local chat and the 297 idle peer chats are left out.
    assert_eq!(ids, ["peer-chat-207", "peer-chat-107", "peer-chat-7"]);
    assert!(reply["result"].get("nextCursor").is_none(), "one page: {}", reply["result"]);
    assert!(rows.iter().all(|r| r.get("tools").is_none()), "rows go without tools: {rows:?}");
    assert_eq!(rows[0]["peer"], "box");
}

#[tokio::test]
async fn a_pending_only_list_reads_no_list_snapshot() {
    let hub = hub().await;
    // Every other list waits on the guard's pace; this one never asks it for a build.
    for _ in 0..3 {
        let reply = call(&hub, method::MUX_SESSIONS, json!({"pendingOnly": true})).await;
        assert_eq!(reply["result"]["sessions"].as_array().map(Vec::len), Some(3));
    }
    assert!(hub.list_guard.window().is_zero(), "no list was built for a pending-only read");
}

#[tokio::test]
async fn a_pending_only_list_refuses_other_filters_and_a_watch_refuses_it() {
    let hub = hub().await;
    for other in [json!({"limit": 5}), json!({"localOnly": true}), json!({"withTools": true})] {
        let mut params = other.clone();
        params["pendingOnly"] = json!(true);
        let reply = call(&hub, method::MUX_SESSIONS, params).await;
        assert_eq!(reply["error"]["code"], -32602, "{other}: {reply}");
    }
    let reply = call(&hub, method::MUX_WATCH, json!({"pendingOnly": true})).await;
    assert_eq!(reply["error"]["code"], -32602, "{reply}");
    // `false` is no filter: the whole list.
    let reply = call(&hub, method::MUX_SESSIONS, json!({"pendingOnly": false})).await;
    assert_eq!(reply["result"]["sessions"].as_array().map(Vec::len), Some(ROWS + 1));
}

/// More chats with an ask than fit one page (each with a long name, 1,500 of them, about 2 MB)
/// go in pages of at most `REPLY_PAGE_BYTES`, each with the `nextCursor` of the rest, and the
/// pages hold every one of them once. Before, one reply held them all, up to the message limit.
#[tokio::test]
async fn a_pending_only_list_past_one_page_goes_in_pages() {
    const ASKING: usize = 1_500;
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = crate::hub::Hub::new(config, store);
    let (tx, _rx) = mpsc::channel(8);
    let peer = Peer::new("box", "ws://127.0.0.1:9", None, None, tx);
    hub.peers.lock().unwrap().insert("box".to_owned(), peer.clone());
    let list: Vec<Value> = (0..ASKING)
        .map(|i| {
            json!({"sessionId": format!("asking-{i}"), "name": "n".repeat(1_200),
                "harness": "claude", "cwd": "/work", "status": "waiting",
                "updatedAt": i as u64 + 10, "pendingPermissions": 1})
        })
        .collect();
    let mut settled = peer.settled();
    for notice in [PeerNotice::Sessions(list), PeerNotice::Connected] {
        hub.peer_notices.send(("box".to_owned(), peer.generation, notice)).await.unwrap();
    }
    tokio::time::timeout(Duration::from_secs(10), settled.wait_for(|n| *n >= 1))
        .await
        .expect("the hub applies the notices")
        .unwrap();
    let (mut ids, mut pages, mut params) =
        (std::collections::BTreeSet::new(), 0, json!({"pendingOnly": true}));
    loop {
        let reply = call(&hub, method::MUX_SESSIONS, params.clone()).await;
        assert!(reply.get("error").is_none(), "{}", reply["error"]);
        let bytes = reply.to_string().len();
        assert!(bytes <= crate::rpc::REPLY_PAGE_BYTES, "page {pages}: {bytes} bytes");
        for row in reply["result"]["sessions"].as_array().unwrap() {
            assert!(ids.insert(row["sessionId"].as_str().unwrap().to_owned()), "{row} twice");
        }
        pages += 1;
        match reply["result"]["nextCursor"].as_str() {
            Some(cursor) => params["cursor"] = json!(cursor),
            None => break,
        }
        assert!(pages < 100, "the pages never end");
    }
    assert!(pages > 1, "a list past one page goes in pages");
    assert_eq!(ids.len(), ASKING);
}

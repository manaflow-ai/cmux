//! A peer daemon's link reads only this daemon's own sessions in its `_acpmux/watch` reply.
//! The link drops every mirrored row (`peer.rs` `watch_sessions`), and on one lane VM those rows
//! were 4815 of 5241 (2026-10-30): 17 MB with tools, over the 15 MiB message limit, so every
//! peer's handshake there failed.

use super::super::{Origin, serve_connection_with};
use crate::config::{Config, StoreMode};
use crate::peer::{Peer, PeerNotice};
use crate::rpc::{Message, method};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const OWN: &str = "own-chat";

/// A hub with one chat of its own and one mirrored from its peer `box`.
async fn hub_with_mirrored_row_status(status: &str) -> Arc<crate::hub::Hub> {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let meta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": OWN, "name": OWN,
        "harness": "fake", "cwd": "/tmp", "status": status, "createdAt": 1, "updatedAt": 1
    }))
    .unwrap();
    store.save(&meta).unwrap();
    let hub = crate::hub::Hub::new(config, store);
    let (tx, _rx) = mpsc::channel(8);
    let peer = Peer::new("box", "ws://127.0.0.1:9", None, None, tx);
    hub.peers.lock().unwrap().insert("box".to_owned(), peer.clone());
    let remote_name = if status != "closed" { OWN } else { "lane" };
    let row = json!({"sessionId": "m1", "name": remote_name, "status": "idle", "updatedAt": 5});
    let mut settled = peer.settled();
    for notice in [PeerNotice::sessions_from_values(vec![row]), PeerNotice::Connected] {
        hub.peer_notices.send(("box".to_owned(), peer.generation, notice)).await.unwrap();
    }
    tokio::time::timeout(Duration::from_secs(5), settled.wait_for(|n| *n >= 1))
        .await
        .expect("the hub applies the notices")
        .unwrap();
    assert_eq!(hub.remote_sessions().len(), 1);
    hub
}

async fn hub_with_a_mirrored_row() -> Arc<crate::hub::Hub> {
    hub_with_mirrored_row_status("idle").await
}

/// One resolve request on a connection, including the initialize that establishes its origin.
async fn resolved(hub: &Arc<crate::hub::Hub>, origin: Origin, query: &str) -> Value {
    let (input, incoming) = mpsc::channel(64);
    let (output, mut outgoing) = mpsc::channel(64);
    tokio::spawn(serve_connection_with(hub.clone(), incoming, output, origin));
    for (id, method, params) in [
        (
            1,
            method::INITIALIZE,
            json!({"protocolVersion": 1, "clientInfo": {"name": "test", "version": "0"}}),
        ),
        (2, method::MUX_RESOLVE, json!({"query": query})),
    ] {
        input.send(Message::request(id, method, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(5), outgoing.recv())
                .await
                .unwrap()
                .unwrap();
            let reply: Value = serde_json::from_str(&line).unwrap();
            if reply["id"] == id {
                if id == 1 {
                    assert!(reply.get("error").is_none(), "initialize: {reply}");
                    break;
                }
                return reply;
            }
        }
    }
    unreachable!()
}

/// The `_acpmux/watch` reply's rows on a connection of `origin` named `client`, `tools` or not.
async fn watched(
    hub: &Arc<crate::hub::Hub>,
    origin: Origin,
    client: &str,
    tools: bool,
) -> Vec<Value> {
    let (input, incoming) = mpsc::channel(64);
    let (output, mut outgoing) = mpsc::channel(64);
    tokio::spawn(serve_connection_with(hub.clone(), incoming, output, origin));
    let hello = json!({"protocolVersion": 1, "clientCapabilities": {},
        "clientInfo": {"name": client, "version": "0"}});
    for (id, m, params) in [
        (1, method::INITIALIZE, hello),
        (2, method::MUX_WATCH, json!({"enabled": true, "withTools": tools})),
    ] {
        input.send(Message::request(id, m, params).to_line()).await.unwrap();
        let reply = tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                let line = outgoing.recv().await.unwrap();
                let reply: Value = serde_json::from_str(&line).unwrap();
                if reply["id"] == id {
                    return reply;
                }
            }
        })
        .await
        .unwrap();
        assert!(reply.get("error").is_none(), "{m}: {reply}");
        if m == method::MUX_WATCH {
            return reply["result"]["sessions"].as_array().cloned().unwrap_or_default();
        }
    }
    unreachable!()
}

fn ids(rows: &[Value]) -> Vec<&str> {
    let mut ids: Vec<&str> = rows.iter().filter_map(|r| r["sessionId"].as_str()).collect();
    ids.sort_unstable();
    ids
}

#[tokio::test]
async fn a_peer_link_watch_lists_only_this_daemons_own_sessions() {
    let hub = hub_with_a_mirrored_row().await;
    // A link served as a peer (it proved the peer token), with or without tools.
    assert_eq!(ids(&watched(&hub, Origin::Peer, crate::peer::CLIENT_NAME, true).await), [OWN]);
    assert_eq!(ids(&watched(&hub, Origin::Peer, crate::peer::CLIENT_NAME, false).await), [OWN]);
    // Any other client still reads every session, its peers' too, whatever name it gives:
    // the peer client's name keeps a client out of presence, and filters no data.
    assert_eq!(ids(&watched(&hub, Origin::Web, crate::peer::CLIENT_NAME, true).await), ["m1", OWN]);
    assert_eq!(ids(&watched(&hub, Origin::Local, "cli", true).await), ["m1", OWN]);
}

#[tokio::test]
async fn a_peer_resolve_names_no_machine_in_match_or_refusal() {
    let hub = hub_with_a_mirrored_row().await;
    let machine = crate::pairing::machine_name();

    let match_reply = resolved(&hub, Origin::Peer, OWN).await;
    assert!(match_reply.get("error").is_none(), "{match_reply}");
    let match_text = match_reply.to_string();
    assert!(!match_text.contains(&machine), "peer resolve leaked this machine: {match_reply}");
    assert!(!match_text.contains("box"), "peer resolve leaked a peer name: {match_reply}");

    let refusal = resolved(&hub, Origin::Peer, "no-such-chat").await;
    assert!(refusal.get("error").is_some(), "{refusal}");
    let refusal_text = refusal.to_string();
    assert!(!refusal_text.contains(&machine), "peer refusal leaked this machine: {refusal}");
    assert!(!refusal_text.contains("box"), "peer refusal leaked a peer name: {refusal}");
}

#[tokio::test]
async fn a_closed_local_chat_resolves_through_the_request_with_a_connected_peer() {
    let hub = hub_with_mirrored_row_status("closed").await;
    let reply = resolved(&hub, Origin::Local, OWN).await;
    assert!(reply.get("error").is_none(), "{reply}");
    assert_eq!(reply["result"]["session"]["sessionId"], OWN);
    assert_eq!(reply["result"]["session"]["name"], OWN);
    assert_eq!(reply["result"]["session"]["host"], crate::pairing::machine_name());
}

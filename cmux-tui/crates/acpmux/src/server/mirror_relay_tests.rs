//! Another daemon's link hears no change of a row this daemon mirrors from a peer. The link
//! drops every mirrored row (`peer.rs`), so with 25 peers (one daemon's, 2026-10-30) each change
//! of one peer's chat went out on the 24 other links for nothing, with its tools.

use super::{Origin, serve_connection_with};
use crate::config::{Config, StoreMode};
use crate::peer::{Peer, PeerNotice};
use crate::rpc::{Message, method};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const OWN: &str = "own-chat";

/// A hub with one chat of its own and one (`m1`) mirrored from its peer `box`, and the peer.
async fn hub_with_a_mirrored_row() -> (Arc<crate::hub::Hub>, Arc<Peer>) {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let meta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": OWN, "name": OWN,
        "harness": "fake", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1
    }))
    .unwrap();
    store.save(&meta).unwrap();
    let hub = crate::hub::Hub::new(config, store);
    let (tx, _rx) = mpsc::channel(8);
    let peer = Peer::new("box", "ws://127.0.0.1:9", None, None, tx);
    hub.peers.lock().unwrap().insert("box".to_owned(), peer.clone());
    let row = json!({"sessionId": "m1", "name": "lane", "status": "idle", "updatedAt": 5});
    let mut settled = peer.settled();
    for notice in [PeerNotice::Sessions(vec![row]), PeerNotice::Connected] {
        hub.peer_notices.send(("box".to_owned(), peer.generation, notice)).await.unwrap();
    }
    tokio::time::timeout(Duration::from_secs(5), settled.wait_for(|n| *n >= 1))
        .await
        .expect("the hub applies the notices")
        .unwrap();
    assert_eq!(hub.remote_sessions().len(), 1);
    (hub, peer)
}

/// A connection of `origin` named `client` that watches the list, and its outgoing lines.
async fn watching(
    hub: &Arc<crate::hub::Hub>,
    origin: Origin,
    client: &str,
) -> (mpsc::Sender<String>, mpsc::Receiver<String>) {
    let (input, incoming) = mpsc::channel(64);
    let (output, mut outgoing) = mpsc::channel(64);
    tokio::spawn(serve_connection_with(hub.clone(), incoming, output, origin));
    let hello = json!({"protocolVersion": 1, "clientCapabilities": {},
        "clientInfo": {"name": client, "version": "0"}});
    for (id, m, params) in [
        (1, method::INITIALIZE, hello),
        (2, method::MUX_WATCH, json!({"enabled": true, "withTools": true})),
    ] {
        input.send(Message::request(id, m, params).to_line()).await.unwrap();
        let reply = until(&mut outgoing, |line| line["id"] == id).await;
        assert!(reply.get("error").is_none(), "{m}: {reply}");
    }
    (input, outgoing)
}

/// The next line `outgoing` sends that `stop` takes, and the `session_changed` notices before it.
async fn until_noting(
    outgoing: &mut mpsc::Receiver<String>,
    stop: impl Fn(&Value) -> bool,
) -> (Value, Vec<Value>) {
    let mut changes = Vec::new();
    let line = tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            let line: Value = serde_json::from_str(&outgoing.recv().await.unwrap()).unwrap();
            if stop(&line) {
                return line;
            }
            if line["method"] == method::MUX_SESSION_CHANGED {
                changes.push(line["params"].clone());
            }
        }
    })
    .await
    .expect("the line comes");
    (line, changes)
}

async fn until(outgoing: &mut mpsc::Receiver<String>, stop: impl Fn(&Value) -> bool) -> Value {
    until_noting(outgoing, stop).await.0
}

fn changed(id: &str) -> impl Fn(&Value) -> bool + '_ {
    move |line| line["method"] == method::MUX_SESSION_CHANGED && line["params"]["sessionId"] == id
}

#[tokio::test]
async fn a_peer_link_hears_no_change_of_a_row_mirrored_from_another_peer() {
    let (hub, peer) = hub_with_a_mirrored_row().await;
    let (cli, mut cli_out) = watching(&hub, Origin::Local, "cli").await;
    // A peer's link, served as Peer or (added with the dashboard token) as Web.
    let (_link, mut link_out) = watching(&hub, Origin::Peer, crate::peer::CLIENT_NAME).await;
    let (_web_link, mut web_link_out) = watching(&hub, Origin::Web, crate::peer::CLIENT_NAME).await;

    let row = json!({"sessionId": "m1", "name": "lane", "status": "running", "updatedAt": 6});
    let notice = PeerNotice::SessionChanged { session: row, kind: "status".into(), seq: 7 };
    hub.peer_notices.send(("box".to_owned(), peer.generation, notice)).await.unwrap();
    // A watcher that is not a link hears it, with the peer it is from.
    let heard = until(&mut cli_out, changed("m1")).await;
    assert_eq!(heard["params"]["peer"], "box");

    // Then a change of this daemon's own chat, which every watcher hears after the one before:
    // a link that heard the mirrored row's change heard it first.
    let rename = json!({"sessionId": OWN, "newName": "renamed"});
    cli.send(Message::request(3, method::MUX_RENAME, rename).to_line()).await.unwrap();
    for out in [&mut link_out, &mut web_link_out] {
        let (_, before) = until_noting(out, changed(OWN)).await;
        let mirrored: Vec<&Value> = before.iter().filter(|c| c["sessionId"] == "m1").collect();
        assert!(mirrored.is_empty(), "a link heard a mirrored row's change: {mirrored:?}");
    }
}

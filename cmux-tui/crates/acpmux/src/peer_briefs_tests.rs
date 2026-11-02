//! `_acpmux/briefs` on the unix socket asks every connected peer for its briefs. It asked them
//! one by one, each with the 600 s request budget, and left out a peer whose answer failed
//! without saying so: one stalled peer held the whole list for ten minutes, and a refusing one
//! was simply missing. The peers are now asked at once under one deadline, and each peer left
//! out is named with its error (`peersFailed`).

use super::*;
use tokio_tungstenite::WebSocketStream;
use tokio_tungstenite::tungstenite::{Message as Frame, protocol::Role};

/// How a fake peer answers `_acpmux/briefs`.
#[derive(Clone, Copy)]
enum Briefs {
    Lists(&'static str),
    Refuses,
    Stalls,
}

/// A peer named `name` linked to a fake that answers its handshake with `{}` (no sessions) and
/// `_acpmux/briefs` as `briefs` says; it reads connected when this returns.
async fn linked_peer(name: &str, briefs: Briefs) -> Arc<Peer> {
    let (tx, mut notices) = mpsc::channel(64);
    let peer = Peer::new(name, "ws://127.0.0.1:9", None, None, tx);
    let (ours, theirs) = tokio::io::duplex(1 << 16);
    let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
    let mut server = WebSocketStream::from_raw_socket(theirs, Role::Server, None).await;
    tokio::spawn(async move {
        while let Some(Ok(frame)) = server.next().await {
            let Frame::Text(text) = frame else { continue };
            let msg: Value = serde_json::from_str(&text).unwrap();
            let Some(id) = msg.get("id").cloned() else { continue };
            let reply = match (msg["method"].as_str().unwrap_or_default(), briefs) {
                (m, _) if m == method::MUX_WATCH => Message::ok(id, json!({"sessions": []})),
                (m, Briefs::Lists(brief)) if m == method::MUX_BRIEFS => {
                    Message::ok(id, json!({"briefs": [{"briefId": brief, "status": "done"}]}))
                }
                (m, Briefs::Refuses) if m == method::MUX_BRIEFS => {
                    Message::err(id, RpcError::internal("the brief ledger is unreadable"))
                }
                (m, Briefs::Stalls) if m == method::MUX_BRIEFS => continue,
                _ => Message::ok(id, json!({})),
            };
            let line = reply.to_line();
            if server.send(Frame::Text(line.trim_end().to_owned().into())).await.is_err() {
                return;
            }
        }
    });
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let link = peer.clone();
    tokio::spawn(async move { link.serve(client, &mut out_rx).await });
    loop {
        let (_, _, notice) = notices.recv().await.expect("the link stays open");
        if matches!(notice, PeerNotice::Connected) {
            break;
        }
    }
    // The hub reads nothing else from this channel.
    tokio::spawn(async move { while notices.recv().await.is_some() {} });
    peer
}

/// The `_acpmux/briefs` reply on a unix-socket connection of `hub`.
async fn briefs(hub: &Arc<crate::hub::Hub>) -> Value {
    let (input, incoming) = mpsc::channel(8);
    let (output, mut outgoing) = mpsc::channel(64);
    tokio::spawn(crate::server::serve_connection(hub.clone(), incoming, output));
    input.send(Message::request(1, method::MUX_BRIEFS, json!({})).to_line()).await.unwrap();
    loop {
        let reply: Value = serde_json::from_str(&outgoing.recv().await.unwrap()).unwrap();
        if reply["id"] == 1 {
            assert!(reply.get("error").is_none(), "{reply}");
            return reply["result"].clone();
        }
    }
}

#[tokio::test(start_paused = true)]
async fn briefs_asks_the_peers_at_once_and_names_each_one_left_out() {
    let mut config = crate::config::Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = crate::hub::Hub::new(config, store);
    for (name, how) in [
        ("stalls", Briefs::Stalls),
        ("refuses", Briefs::Refuses),
        ("lists", Briefs::Lists("brief-from-lists")),
    ] {
        let peer = linked_peer(name, how).await;
        hub.peers.lock().unwrap().insert(name.to_owned(), peer);
    }
    assert_eq!(hub.connected_peers().len(), 3);

    let started = tokio::time::Instant::now();
    let reply = briefs(&hub).await;
    let took = started.elapsed();
    assert!(took < Duration::from_secs(30), "the stalled peer held the list for {took:?}");
    let ids: Vec<&str> =
        reply["briefs"].as_array().unwrap().iter().filter_map(|b| b["briefId"].as_str()).collect();
    assert_eq!(ids, ["brief-from-lists"], "{reply}");
    let mut failed: Vec<(String, String)> = reply["peersFailed"]
        .as_array()
        .unwrap_or_else(|| panic!("no peersFailed: {reply}"))
        .iter()
        .map(|f| (f["peer"].as_str().unwrap().to_owned(), f["error"].as_str().unwrap().to_owned()))
        .collect();
    failed.sort();
    assert_eq!(failed.len(), 2, "{failed:?}");
    assert_eq!(failed[0].0, "refuses");
    assert!(failed[0].1.contains("the brief ledger is unreadable"), "{failed:?}");
    assert_eq!(failed[1].0, "stalls");
    assert!(failed[1].1.contains("no answer"), "{failed:?}");
}

use super::*;
use tokio_tungstenite::WebSocketStream;
use tokio_tungstenite::tungstenite::{Message as Frame, protocol::Role};

/// A `session_changed` the peer sends right after its `_acpmux/watch` reply is newer than
/// the reply's list, so it reaches the hub after the list: a purge of a listed session
/// leaves no row behind, where a list that came second put the purged row back.
#[tokio::test]
async fn a_purge_sent_right_after_the_watch_reply_lands_after_its_list() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-po");
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Local;
    let store = crate::store::open(&cfg.store, dir.path()).unwrap();
    let hub = crate::hub::Hub::new(cfg, store);
    let (tx, mut rx) = mpsc::channel(64);
    let peer = Peer::new("box", "ws://127.0.0.1:9", None, None, tx);
    hub.peers.lock().unwrap().insert("box".to_owned(), peer.clone());

    let (ours, theirs) = tokio::io::duplex(1 << 16);
    let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
    let mut server = WebSocketStream::from_raw_socket(theirs, Role::Server, None).await;
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let link = peer.clone();
    let serving = tokio::spawn(async move { link.serve(client, &mut out_rx).await });
    // The peer answers every request; its watch reply lists m1, and the purge of m1
    // follows it in the same write.
    let fake = tokio::spawn(async move {
        let row = json!({"sessionId": "m1", "name": "lane", "status": "idle", "updatedAt": 5});
        while let Some(Ok(frame)) = server.next().await {
            let Frame::Text(text) = frame else { continue };
            let msg: Value = serde_json::from_str(&text).unwrap();
            let Some(id) = msg.get("id").cloned() else { continue };
            let watch = msg["method"] == method::MUX_WATCH;
            let result = if watch { json!({"sessions": [row]}) } else { json!({}) };
            let reply = json!({"jsonrpc": "2.0", "id": id, "result": result});
            if !watch {
                server.send(Frame::Text(reply.to_string().into())).await.unwrap();
                continue;
            }
            let purge = json!({"jsonrpc": "2.0", "method": method::MUX_SESSION_CHANGED,
                    "params": {"kind": "purged", "seq": 2, "session": {"sessionId": "m1"}}});
            server.feed(Frame::Text(reply.to_string().into())).await.unwrap();
            server.send(Frame::Text(purge.to_string().into())).await.unwrap();
        }
    });

    let mut seen = Vec::new();
    let (mut connected, mut purged) = (false, false);
    while !(connected && purged) {
        let (_, _, notice) = tokio::time::timeout(Duration::from_secs(5), rx.recv())
            .await
            .expect("the handshake settles and the purge comes")
            .expect("the link stays open");
        connected |= matches!(notice, PeerNotice::Connected);
        purged |= matches!(&notice, PeerNotice::SessionChanged { kind, .. } if kind == "purged");
        seen.push(notice);
    }
    let at = |want: fn(&PeerNotice) -> bool| seen.iter().position(want).unwrap();
    let list = at(|n| matches!(n, PeerNotice::Sessions(_)));
    let purge = at(|n| matches!(n, PeerNotice::SessionChanged { .. }));
    let ready = at(|n| matches!(n, PeerNotice::Connected));
    assert!(list < purge, "the list came after a newer purge: {seen:?}");
    assert!(list < ready, "connected before the list: {seen:?}");

    // The hub applies them in the order the link gave them; a second Connected is a
    // barrier: once it settled, every notice before it was applied.
    let mut settled = peer.settled();
    for notice in seen.into_iter().chain([PeerNotice::Connected]) {
        hub.peer_notices.send(("box".to_owned(), peer.generation, notice)).await.unwrap();
    }
    tokio::time::timeout(Duration::from_secs(5), settled.wait_for(|n| *n >= 2))
        .await
        .expect("the hub applies the notices")
        .unwrap();
    let rows = hub.remote_sessions();
    assert!(rows.is_empty(), "the purged row came back: {rows:?}");
    serving.abort();
    fake.abort();
}

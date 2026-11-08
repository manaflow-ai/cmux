//! What the link's one subscription at the peer streams of a chat follows the attaches that
//! reach the link, in the order they reach it (`Peer::streams_every_kind`): a send answered from
//! the row relies on it to hear the agent's reply (review of #38305).

use super::*;

const CHAT: &str = "c";

fn peer() -> Arc<Peer> {
    let (tx, _notices) = mpsc::channel(8);
    Peer::new("box", "ws://127.0.0.1:9", None, None, tx)
}

fn filtered() -> Value {
    json!({"sessionId": CHAT, "limit": 0, "eventStream": true, "kinds": ["tool_call"]})
}

fn unfiltered() -> Value {
    json!({"sessionId": CHAT, "limit": 0})
}

/// A filtered attach is noted first and held before the link; an unfiltered one is noted after
/// it; the filtered one reaches the link last, and the unfiltered one never does (its link went
/// down meanwhile). The peer streams only the filtered kinds, so the chat reads narrowed.
#[tokio::test]
async fn an_attach_noted_later_that_never_reaches_the_link_widens_nothing() {
    let peer = peer();
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let stale = peer.link_epoch() + 1;
    // Held: each attach waits here, before the link, in the order it came.
    let held = peer.pending.lock().await;
    let narrow = tokio::spawn({
        let peer = peer.clone();
        async move { peer.link_request_on(method::MUX_ATTACH, filtered(), None).await }
    });
    tokio::task::yield_now().await;
    let widen = tokio::spawn({
        let peer = peer.clone();
        async move { peer.link_request_on(method::MUX_ATTACH, unfiltered(), Some(stale)).await }
    });
    tokio::task::yield_now().await;
    assert!(!peer.streams_every_kind(CHAT), "an attach on its way narrows it");
    drop(held);
    let frame = tokio::time::timeout(Duration::from_secs(5), out_rx.recv()).await.unwrap().unwrap();
    assert!(frame.line.contains("tool_call"), "the filtered attach reached the link");
    assert!(widen.await.unwrap().is_err(), "the unfiltered attach's link was gone");
    assert!(
        !peer.streams_every_kind(CHAT),
        "the link streams only the filtered kinds, but the chat reads as streaming every kind"
    );
    narrow.abort();
}

/// An unfiltered attach that reaches the link after a filtered one widens the stream again.
#[tokio::test]
async fn an_unfiltered_attach_that_reaches_the_link_last_widens_it() {
    let peer = peer();
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let mut sent = Vec::new();
    for params in [filtered(), unfiltered()] {
        let peer = peer.clone();
        sent.push(tokio::spawn(async move {
            peer.link_request_on(method::MUX_ATTACH, params, None).await
        }));
        tokio::time::timeout(Duration::from_secs(5), out_rx.recv()).await.unwrap().unwrap();
    }
    assert!(peer.streams_every_kind(CHAT));
    for task in sent {
        task.abort();
    }
}

/// An attach that reached the link but that the peer refused (or never answered) leaves the peer
/// streaming nothing of the chat: it no longer reads as streamed, so a send's subscription goes
/// to the peer again (review of #38305 at 8047f79).
#[tokio::test]
async fn an_attach_the_peer_refused_leaves_the_chat_unstreamed() {
    let peer = peer();
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let attach = tokio::spawn({
        let peer = peer.clone();
        async move { peer.link_request_on(method::MUX_ATTACH, unfiltered(), None).await }
    });
    let frame = tokio::time::timeout(Duration::from_secs(5), out_rx.recv()).await.unwrap().unwrap();
    assert!(peer.streams_every_kind(CHAT), "an attach in the queue streams the chat");
    let sent: Value = serde_json::from_str(&frame.line).unwrap();
    let key = sent["id"].to_string();
    let answer = peer.pending.lock().await.remove(&key).expect("the attach waits for its answer");
    let _ = answer.send(Err(RpcError::not_found("no such session")));
    assert!(attach.await.unwrap().is_err());
    assert!(!peer.streams_every_kind(CHAT), "a refused attach left the chat reading as streamed");
}

use super::*;
use tokio_tungstenite::WebSocketStream;
use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;
use tokio_tungstenite::tungstenite::{
    Message as Frame,
    protocol::{CloseFrame, Role},
};

#[tokio::test]
async fn only_close_1012_is_a_typed_restart() {
    for code in [CloseCode::Restart, CloseCode::Normal, CloseCode::Away] {
        let (tx, _notices) = mpsc::channel(64);
        let peer = Peer::new("box", "ws://127.0.0.1:9", None, None, tx);
        let (ours, theirs) = tokio::io::duplex(1 << 16);
        let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
        let mut server = WebSocketStream::from_raw_socket(theirs, Role::Server, None).await;
        server
            .send(Frame::Close(Some(CloseFrame {
                code,
                reason: "restart text is not proof".into(),
            })))
            .await
            .unwrap();
        let mut out_rx = peer.out_rx.lock().await.take().unwrap();
        let result = tokio::time::timeout(Duration::from_secs(5), peer.serve(client, &mut out_rx))
            .await
            .unwrap();
        if code == CloseCode::Restart {
            assert_eq!(result, Ok(LinkEnd::Restarting));
        } else {
            assert!(result.is_err(), "ordinary close still backs off");
        }
    }
}

#[tokio::test]
async fn restart_summary_and_notice_keep_real_failure_backoff() {
    let (tx, _notices) = mpsc::channel(64);
    let peer = Peer::new("box", "ws://127.0.0.1:9", None, None, tx);
    let mut backoff = Backoff::default();
    for _ in 0..4 {
        backoff.next(0.0);
    }
    let mut expected = backoff.clone();
    peer.with_link(|link| {
        link.opened(1);
        link.ready(2);
    });
    peer.open.store(true, Ordering::SeqCst);
    peer.connected.store(true, Ordering::SeqCst);
    let epoch = peer.link_epoch();
    let notice = peer.finish_link(Ok(LinkEnd::Restarting), &mut backoff);
    assert!(matches!(notice, Some(PeerNotice::Restarting)));
    assert_eq!(peer.link_epoch(), epoch + 1);
    let summary = peer.summary();
    assert_eq!(summary["state"], "restarting");
    assert_eq!(peer.state().wire(), crate::protocol::peer_state::PeerLinkState::Reconnecting);
    assert_eq!(summary["connected"], false);
    assert_eq!(summary["attempts"], 0);
    assert_eq!(summary["lastSeen"], 2);
    assert!(summary["error"].is_null());
    peer.with_link(|link| link.opened(3));
    assert_eq!(peer.summary()["state"], "restarting", "handshake still in progress");
    peer.finish_link(Err("connection refused".into()), &mut backoff);
    assert_eq!(peer.summary()["state"], "reconnecting");
    assert_eq!(peer.summary()["attempts"], 1);
    assert_eq!(
        backoff.next(0.0),
        expected.next(0.0),
        "restart neither resets nor advances backoff"
    );
    peer.with_link(|link| {
        link.opened(4);
        link.ready(5);
    });
    assert_eq!(peer.summary()["state"], "connected");
}

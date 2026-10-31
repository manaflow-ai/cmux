use super::*;
use std::sync::Mutex as StdMutex;
use tokio::time::Instant;
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
    // A link up for less than `stable_after`: its restart keeps the backoff it had.
    let now = crate::store::now_ms();
    peer.with_link(|link| {
        link.opened(now - 1);
        link.ready(now);
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
    assert_eq!(summary["lastSeen"], now);
    assert!(summary["error"].is_null());
    peer.with_link(|link| link.opened(now + 1));
    assert_eq!(peer.summary()["state"], "restarting", "handshake still in progress");
    peer.finish_link(Err("connection refused".into()), &mut backoff);
    assert_eq!(peer.summary()["state"], "reconnecting");
    assert_eq!(peer.summary()["attempts"], 1);
    assert_eq!(
        backoff.next(0.0),
        expected.next(0.0),
        "a young link's restart neither resets nor advances backoff"
    );
    peer.with_link(|link| {
        link.opened(4);
        link.ready(5);
    });
    assert_eq!(peer.summary()["state"], "connected");
}

/// huge-blue's daemon restarts at each update: its links were ready for minutes, but the
/// failures after each restart added up across restarts, so the next one waited 32-57 s.
#[tokio::test]
async fn a_stable_link_that_restarts_starts_its_backoff_over() {
    let (tx, _notices) = mpsc::channel(64);
    let peer = Peer::new("huge-blue", "ws://127.0.0.1:9", None, None, tx);
    let mut backoff = Backoff::default();
    for _ in 0..8 {
        backoff.next(0.0);
    }
    let now = crate::store::now_ms();
    peer.with_link(|link| {
        link.opened(now - 600_000);
        link.ready(now - 600_000);
    });
    peer.connected.store(true, Ordering::SeqCst);
    let notice = peer.finish_link(Ok(LinkEnd::Restarting), &mut backoff);
    assert!(matches!(notice, Some(PeerNotice::Restarting)));
    assert_eq!(backoff.next(0.0), Backoff::BASE / 2, "the first step again");
}

/// Answers every request on one WebSocket: `initialize` and the other handshake steps with
/// `{}`, the watch with an empty list. A change of `restart` closes it with 1012, as a
/// daemon that updates does.
async fn answer(stream: tokio::net::TcpStream, mut restart: tokio::sync::watch::Receiver<u32>) {
    use tokio_tungstenite::tungstenite::protocol::{CloseFrame, frame::coding::CloseCode};
    let Ok(mut ws) = tokio_tungstenite::accept_async(stream).await else { return };
    restart.borrow_and_update();
    loop {
        let frame = tokio::select! {
            frame = ws.next() => frame,
            _ = restart.changed() => {
                let close = CloseFrame { code: CloseCode::Restart, reason: "update".into() };
                let _ = ws.send(Frame::Close(Some(close))).await;
                return;
            }
        };
        let Some(Ok(frame)) = frame else { return };
        let Frame::Text(text) = frame else { continue };
        let msg: Value = serde_json::from_str(&text).unwrap();
        let Some(id) = msg.get("id").cloned() else { continue };
        let result = if msg["method"] == crate::rpc::method::MUX_WATCH {
            json!({"sessions": []})
        } else {
            json!({})
        };
        let line = Message::ok(id, result).to_line();
        if ws.send(Frame::Text(line.trim_end().to_owned().into())).await.is_err() {
            return;
        }
    }
}

/// A fake peer daemon on a loopback port. Until `down_until` it accepts and closes each
/// connection before the 101, as huge-blue did while its new daemon started ("WebSocket
/// protocol error: Handshake not finished"); then it answers.
struct Daemon {
    port: u16,
    down_until: std::sync::Arc<StdMutex<Instant>>,
    restart: tokio::sync::watch::Sender<u32>,
    task: tokio::task::JoinHandle<()>,
}

impl Daemon {
    async fn start(down_for: Duration) -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let down_until = std::sync::Arc::new(StdMutex::new(Instant::now() + down_for));
        let (restart, restarts) = tokio::sync::watch::channel(0);
        let until = down_until.clone();
        let task = tokio::spawn(async move {
            loop {
                let (stream, _) = listener.accept().await.unwrap();
                if Instant::now() < *until.lock().unwrap() {
                    drop(stream);
                } else {
                    tokio::spawn(answer(stream, restarts.clone()));
                }
            }
        });
        Self { port, down_until, restart, task }
    }

    /// Closes the live link with 1012 and is down for `down_for`.
    fn restart(&self, down_for: Duration) {
        *self.down_until.lock().unwrap() = Instant::now() + down_for;
        self.restart.send_modify(|n| *n += 1);
    }
}

async fn next_notice(notices: &mut mpsc::Receiver<(String, u64, PeerNotice)>) -> PeerNotice {
    let wait = tokio::time::timeout(Duration::from_secs(120), notices.recv()).await;
    wait.expect("the link moves on").expect("the link runs").2
}

/// huge-blue's updates (2026-10-30): its daemon restarted with 1012 and took a while to
/// listen again; Leo's chat waited 32-57 s for each next link. Three restarts, each down
/// `DOWN`: every reconnect comes within 1.5 s of the peer listening
/// again. Gaps on the base (2 s doubling, never reset by a restart): see the PR.
#[tokio::test]
async fn a_peer_that_restarts_again_and_again_is_back_within_a_second_each_time() {
    const DOWN: Duration = Duration::from_millis(1_500);
    let daemon = Daemon::start(Duration::ZERO).await;
    let (tx, mut notices) = mpsc::channel(64);
    let url = format!("ws://127.0.0.1:{}", daemon.port);
    let peer = Peer::new("huge-blue", &url, None, None, tx);
    let running = tokio::spawn(peer.clone().run());
    while !matches!(next_notice(&mut notices).await, PeerNotice::Connected) {}
    let mut gaps = Vec::new();
    for _ in 0..3 {
        let restarted = Instant::now();
        daemon.restart(DOWN);
        while !matches!(next_notice(&mut notices).await, PeerNotice::Connected) {}
        gaps.push(restarted.elapsed());
    }
    eprintln!("reconnect gaps after a restart down {DOWN:?}: {gaps:?}");
    for gap in &gaps {
        assert!(*gap < DOWN + Duration::from_millis(1_500), "{gaps:?}");
    }
    peer.stop();
    let _ = tokio::time::timeout(Duration::from_secs(10), running).await;
    daemon.task.abort();
}

/// Leo's huge-blue chat: the upgrade ended before its answer once ("WebSocket protocol
/// error: Handshake not finished"), and the chat took 30+ s to load. The next attempt comes
/// within the first backoff step, under a second, not after the 2 s base it had.
#[tokio::test]
async fn a_handshake_that_fails_once_reconnects_within_a_second() {
    // Down for the first attempt only.
    let daemon = Daemon::start(Duration::from_millis(100)).await;
    let port = daemon.port;
    let (tx, mut notices) = mpsc::channel(64);
    let peer = Peer::new("huge-blue", &format!("ws://127.0.0.1:{port}"), None, None, tx);
    let running = tokio::spawn(peer.clone().run());
    let mut failed_at = None;
    let ready_after = loop {
        let (_, _, notice) = tokio::time::timeout(Duration::from_secs(10), notices.recv())
            .await
            .expect("the link connects")
            .expect("the link runs");
        match notice {
            PeerNotice::Disconnected(why) => {
                assert!(why.contains("Handshake not finished"), "{why}");
                failed_at = Some(Instant::now());
            }
            PeerNotice::Connected => break failed_at.expect("one attempt failed").elapsed(),
            _ => {}
        }
    };
    assert!(ready_after < Duration::from_secs(1), "ready {ready_after:?} after the failure");
    peer.stop();
    let _ = tokio::time::timeout(Duration::from_secs(10), running).await;
    daemon.task.abort();
}

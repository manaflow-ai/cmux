use super::*;
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

/// A fake peer daemon on a loopback port. The next `refuse` connections it reads the upgrade
/// request of and closes before the 101, as a daemon that is not serving yet does ("WebSocket
/// protocol error: Handshake not finished"); it answers the others. `accepts` gets the time of
/// each connection, so a test reads the client's waits between attempts off the server.
struct Daemon {
    port: u16,
    refuse: std::sync::Arc<std::sync::atomic::AtomicU32>,
    restart: tokio::sync::watch::Sender<u32>,
    accepts: mpsc::UnboundedReceiver<Instant>,
    task: tokio::task::JoinHandle<()>,
}

impl Daemon {
    async fn start(refuse: u32) -> Self {
        use tokio::io::AsyncReadExt;
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let refuse = std::sync::Arc::new(std::sync::atomic::AtomicU32::new(refuse));
        let (restart, restarts) = tokio::sync::watch::channel(0);
        let (accepted, accepts) = mpsc::unbounded_channel();
        let left = refuse.clone();
        let task = tokio::spawn(async move {
            loop {
                let (mut stream, _) = listener.accept().await.unwrap();
                let _ = accepted.send(Instant::now());
                let refused = left
                    .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |n| n.checked_sub(1))
                    .is_ok();
                if !refused {
                    tokio::spawn(answer(stream, restarts.clone()));
                    continue;
                }
                // The whole request read first: the close is a FIN the client reads as the
                // upgrade ending early, never a reset of unread bytes.
                let mut head = Vec::new();
                let mut chunk = [0u8; 1024];
                while !head.windows(4).any(|w| w == b"\r\n\r\n") {
                    match stream.read(&mut chunk).await {
                        Ok(0) | Err(_) => break,
                        Ok(n) => head.extend_from_slice(chunk.get(..n).unwrap_or_default()),
                    }
                }
                drop(stream);
            }
        });
        Self { port, refuse, restart, accepts, task }
    }

    /// Closes the live link with 1012; the next `refuse` connections are refused.
    fn restart(&self, refuse: u32) {
        self.refuse.store(refuse, Ordering::SeqCst);
        self.restart.send_modify(|n| *n += 1);
    }

    /// The time of the next connection.
    async fn accepted(&mut self) -> Instant {
        let next = tokio::time::timeout(Duration::from_secs(120), self.accepts.recv()).await;
        next.expect("the client connects again").expect("the daemon runs")
    }
}

async fn next_notice(notices: &mut mpsc::Receiver<(String, u64, PeerNotice)>) -> PeerNotice {
    let wait = tokio::time::timeout(Duration::from_secs(120), notices.recv()).await;
    wait.expect("the link moves on").expect("the link runs").2
}

/// The wait between a refused attempt and the next, its first time. Base: 1-2 s (the 2 s backoff
/// base). Head: 0.25-0.5 s.
const FIRST_NEXT_ATTEMPT_WITHIN: Duration = Duration::from_millis(950);

/// The same wait later in an outage the client waits out. Base: doubling, 2-4 s, 4-8 s, ...
/// Head: at most 1 s (`Backoff::WANTED_CAP`).
const NEXT_ATTEMPT_WITHIN: Duration = Duration::from_millis(1_500);

/// The remote host's daemon updates (2026-10-30): each restart closed the link with 1012, the
/// client's one immediate retry was refused, and its next attempt came 32-57 s later, since the
/// backoff grew by a step at every restart and a restart never started it over. Three
/// restarts: each next attempt comes within about a second of the refused one.
#[tokio::test]
async fn a_peer_that_restarts_again_and_again_is_back_within_a_second_each_time() {
    let mut daemon = Daemon::start(0).await;
    let (tx, mut notices) = mpsc::channel(64);
    let url = format!("ws://127.0.0.1:{}", daemon.port);
    let peer = Peer::new("huge-blue", &url, None, None, tx);
    let running = tokio::spawn(peer.clone().run());
    daemon.accepted().await;
    while !matches!(next_notice(&mut notices).await, PeerNotice::Connected) {}
    let mut waits = Vec::new();
    for _ in 0..3 {
        daemon.restart(1);
        let refused = daemon.accepted().await;
        waits.push(daemon.accepted().await.duration_since(refused));
        while !matches!(next_notice(&mut notices).await, PeerNotice::Connected) {}
    }
    eprintln!("wait after the refused attempt, restarts 1-3: {waits:?}");
    assert!(waits[0] < FIRST_NEXT_ATTEMPT_WITHIN, "{waits:?}");
    assert!(waits.iter().all(|w| *w < NEXT_ATTEMPT_WITHIN), "{waits:?}");
    peer.stop();
    let _ = tokio::time::timeout(Duration::from_secs(10), running).await;
    daemon.task.abort();
}

/// Leo's chat on the remote host: the upgrade ended before its answer once ("WebSocket protocol
/// error: Handshake not finished"), and the chat took 30+ s to load. The next attempt comes
/// within the first backoff step, under a second, not after the 2 s base's 1-2 s.
#[tokio::test]
async fn a_handshake_that_fails_once_reconnects_within_a_second() {
    let mut daemon = Daemon::start(1).await;
    let (tx, mut notices) = mpsc::channel(64);
    let url = format!("ws://127.0.0.1:{}", daemon.port);
    let peer = Peer::new("huge-blue", &url, None, None, tx);
    let running = tokio::spawn(peer.clone().run());
    let refused = daemon.accepted().await;
    let wait = daemon.accepted().await.duration_since(refused);
    let mut failed = false;
    loop {
        match next_notice(&mut notices).await {
            PeerNotice::Disconnected(why) => {
                assert!(why.contains("Handshake not finished"), "{why}");
                failed = true;
            }
            PeerNotice::Connected => break,
            _ => {}
        }
    }
    assert!(failed, "the first attempt failed");
    eprintln!("wait after the refused attempt: {wait:?}");
    assert!(wait < FIRST_NEXT_ATTEMPT_WITHIN, "next attempt {wait:?} after the refused one");
    peer.stop();
    let _ = tokio::time::timeout(Duration::from_secs(10), running).await;
    daemon.task.abort();
}

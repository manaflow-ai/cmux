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
    // The whole state says restarting; an older app's folded `state` word says reconnecting.
    assert_eq!(peer.state().wire(), crate::protocol::peer_state::MachineLink::Restarting);
    assert_eq!(
        peer.state().wire().folded(),
        crate::protocol::peer_state::PeerLinkState::Reconnecting
    );
    assert_eq!(summary["link"], "restarting");
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
    let redials = &crate::gauges::links().link_redials;
    let before = redials.load(Ordering::Relaxed);
    let mut waits = Vec::new();
    for _ in 0..3 {
        daemon.restart(1);
        let refused = daemon.accepted().await;
        waits.push(daemon.accepted().await.duration_since(refused));
        while !matches!(next_notice(&mut notices).await, PeerNotice::Connected) {}
    }
    assert!(redials.load(Ordering::Relaxed) >= before + 3);
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

/// The pages of a [`ListDaemon`]'s watch list, the rows on each, and each row's bytes: 2.4 MB
/// in all, in pages of 0.8 MB.
const LIST_PAGES: usize = 3;
const PAGE_ROWS: usize = 100;
const ROW_BYTES: usize = 8_000;

/// How long a [`ListDaemon`] takes over each page of its list on every connection after its
/// first, as a busy daemon does building its list after a restart.
const PAGE_GAP: Duration = Duration::from_secs(1);

/// How soon after the far daemon's restart its link is ready again: one restart took 66 s, its
/// whole list (6 MB in 1.47 MB pages) read first.
const READY_WITHIN: Duration = Duration::from_secs(2);

/// Page `page` of connection `conn`'s watch list: its rows name the connection and the page.
fn list_page(conn: usize, page: usize) -> Value {
    let pad = "x".repeat(ROW_BYTES);
    let id = |n: usize| format!("c{conn}-{page}-{n}");
    let rows: Vec<Value> =
        (0..PAGE_ROWS).map(|n| json!({"sessionId": id(n), "updatedAt": 1, "title": pad})).collect();
    let next = (page + 1 < LIST_PAGES).then(|| format!("p{}", page + 1));
    json!({"sessions": rows, "nextCursor": next})
}

/// Answers one connection (`conn`, from 0) of a [`ListDaemon`]: `initialize` and the other
/// requests with `{}`, the watch and each `_acpmux/sessions {cursor}` with that page of its
/// list, `PAGE_GAP` after it was asked for on every connection after the first. Sends each page
/// on `pages` once it went out. A change of `restart` closes it with 1012, also mid-page.
async fn answer_pages(
    stream: tokio::net::TcpStream,
    conn: usize,
    mut restart: tokio::sync::watch::Receiver<u32>,
    pages: mpsc::UnboundedSender<(usize, usize)>,
) {
    let Ok(mut ws) = tokio_tungstenite::accept_async(stream).await else { return };
    restart.borrow_and_update();
    let gap = if conn == 0 { Duration::ZERO } else { PAGE_GAP };
    loop {
        let frame = tokio::select! {
            frame = ws.next() => frame,
            _ = restart.changed() => break,
        };
        let Some(Ok(frame)) = frame else { return };
        let Frame::Text(text) = frame else { continue };
        let msg: Value = serde_json::from_str(&text).unwrap();
        let Some(id) = msg.get("id").cloned() else { continue };
        let page = match msg["method"].as_str() {
            Some(method::MUX_WATCH) => Some(0),
            Some(method::MUX_SESSIONS) => msg["params"]["cursor"]
                .as_str()
                .and_then(|cursor| cursor.strip_prefix('p'))
                .and_then(|n| n.parse::<usize>().ok()),
            _ => None,
        };
        let result = match page {
            Some(page) => {
                tokio::select! {
                    () = tokio::time::sleep(gap) => {}
                    _ = restart.changed() => break,
                }
                list_page(conn, page)
            }
            None => json!({}),
        };
        let line = Message::ok(id, result).to_line();
        if ws.send(Frame::Text(line.trim_end().to_owned().into())).await.is_err() {
            return;
        }
        if let Some(page) = page {
            let _ = pages.send((conn, page));
        }
    }
    let close = CloseFrame { code: CloseCode::Restart, reason: "update".into() };
    let _ = ws.send(Frame::Close(Some(close))).await;
}

/// A far daemon on a loopback port whose watch list comes in pages ([`answer_pages`]), slowly
/// on every connection after its first.
struct ListDaemon {
    port: u16,
    restart: tokio::sync::watch::Sender<u32>,
    pages: mpsc::UnboundedReceiver<(usize, usize)>,
    /// The pages sent so far, as (connection, page).
    sent: Vec<(usize, usize)>,
    task: tokio::task::JoinHandle<()>,
}

impl ListDaemon {
    async fn start() -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let (restart, restarts) = tokio::sync::watch::channel(0);
        let (sent_tx, pages) = mpsc::unbounded_channel();
        let task = tokio::spawn(async move {
            for conn in 0.. {
                let (stream, _) = listener.accept().await.unwrap();
                tokio::spawn(answer_pages(stream, conn, restarts.clone(), sent_tx.clone()));
            }
        });
        Self { port, restart, pages, sent: Vec::new(), task }
    }

    /// Closes the live connection with 1012, as a daemon that updates does.
    fn restart(&self) {
        self.restart.send_modify(|n| *n += 1);
    }

    /// How many pages of its list connection `conn` was sent so far.
    fn pages_sent(&mut self, conn: usize) -> usize {
        while let Ok(page) = self.pages.try_recv() {
            self.sent.push(page);
        }
        self.sent.iter().filter(|(c, _)| *c == conn).count()
    }

    /// Waits until page `page` of connection `conn` went out.
    async fn page_sent(&mut self, conn: usize, page: usize) {
        while !self.sent.contains(&(conn, page)) {
            let next = tokio::time::timeout(Duration::from_secs(60), self.pages.recv()).await;
            self.sent.push(next.expect("the page goes out").expect("the daemon runs"));
        }
    }
}

/// What a link did from `since` until it was both ready and listed.
struct Relinked {
    /// When it was ready (`Connected`).
    ready: Duration,
    /// When its list came.
    listed: Duration,
    /// Every list it published, as each row's id.
    lists: Vec<Vec<String>>,
    /// The pages of its list its daemon had sent by the time it was ready.
    pages_at_ready: usize,
}

/// Reads `notices` until connection `conn`'s link is ready and has published a list. A link
/// that drops on the way fails the test.
async fn relink(
    daemon: &mut ListDaemon,
    notices: &mut mpsc::Receiver<(String, u64, PeerNotice)>,
    conn: usize,
    since: Instant,
) -> Relinked {
    let (mut ready, mut listed, mut lists, mut pages_at_ready) = (None, None, Vec::new(), 0);
    while ready.is_none() || listed.is_none() {
        match next_notice(notices).await {
            PeerNotice::Connected => {
                ready = Some(since.elapsed());
                pages_at_ready = daemon.pages_sent(conn);
            }
            PeerNotice::Sessions(rows) => {
                listed = Some(since.elapsed());
                let rows = crate::peer::parse_rows(&rows);
                let ids = rows.iter().map(|r| r["sessionId"].as_str().unwrap().to_owned());
                lists.push(ids.collect());
            }
            PeerNotice::Disconnected(why) => panic!("the link dropped: {why}"),
            _ => {}
        }
    }
    let (ready, listed) = (ready.unwrap_or_default(), listed.unwrap_or_default());
    Relinked { ready, listed, lists, pages_at_ready }
}

/// Every row of connection `conn`'s list, once each.
fn whole_list_of(conn: usize, list: &[String]) -> bool {
    let ids: HashSet<&str> = list.iter().map(String::as_str).collect();
    ids.len() == LIST_PAGES * PAGE_ROWS
        && list.len() == ids.len()
        && list.iter().all(|id| id.starts_with(&format!("c{conn}-")))
}

/// The far daemon restarts (an update) and builds its list slowly, a page at a time: one such
/// restart held the link 66 s in its handshake before it was ready, reading the whole list (6 MB
/// in 1.47 MB pages) first. A link that listed before is ready again within `READY_WITHIN` of the
/// restart, before the last page, and reads the list after: it publishes that list once, whole,
/// after its last page, so the hub keeps the last whole list until then. A link that drops
/// while its list comes publishes none of it.
#[tokio::test]
async fn a_far_restart_makes_the_link_ready_before_its_list_is_read() {
    let mut daemon = ListDaemon::start().await;
    let (tx, mut notices) = mpsc::channel(256);
    let url = format!("ws://127.0.0.1:{}", daemon.port);
    let peer = Peer::new("far", &url, None, None, tx);
    let running = tokio::spawn(peer.clone().run());
    let first = relink(&mut daemon, &mut notices, 0, Instant::now()).await;
    assert_eq!(first.lists.len(), 1, "one list on the first link");
    assert!(whole_list_of(0, &first.lists[0]), "the first link's whole list");

    let restarted = Instant::now();
    daemon.restart();
    let again = relink(&mut daemon, &mut notices, 1, restarted).await;
    println!(
        "PERF peer far-restart pages={LIST_PAGES} page_bytes={} restart_to_ready_ms={} restart_to_listed_ms={}",
        PAGE_ROWS * ROW_BYTES,
        again.ready.as_millis(),
        again.listed.as_millis()
    );
    assert!(again.ready < READY_WITHIN, "ready {:?} after the restart", again.ready);
    assert!(again.pages_at_ready < LIST_PAGES, "ready before the list's last page");
    assert!(again.listed > again.ready, "the list is read after the link is ready");
    assert_eq!(again.lists.len(), 1, "no part of the list is published before the whole");
    assert!(whole_list_of(1, &again.lists[0]), "the restarted daemon's whole list");

    // It restarts again while the next link reads its list: that list is never published.
    daemon.restart();
    loop {
        match next_notice(&mut notices).await {
            PeerNotice::Connected => break,
            PeerNotice::Sessions(_) => panic!("a list published before the link was ready"),
            PeerNotice::Disconnected(why) => panic!("the link dropped: {why}"),
            _ => {}
        }
    }
    daemon.page_sent(2, 0).await;
    let dropped = Instant::now();
    daemon.restart();
    let last = relink(&mut daemon, &mut notices, 3, dropped).await;
    assert_eq!(last.lists.len(), 1, "the list of the link that dropped is never published");
    assert!(whole_list_of(3, &last.lists[0]), "only the next link's whole list");
    assert!(last.ready < READY_WITHIN, "ready {:?} after the second restart", last.ready);
    peer.stop();
    let _ = tokio::time::timeout(Duration::from_secs(10), running).await;
    daemon.task.abort();
}

use super::*;
use std::future::pending;
use std::sync::atomic::AtomicUsize;
use tokio::sync::mpsc;

type Dial = std::pin::Pin<Box<dyn Future<Output = Result<&'static str, String>> + Send>>;

fn after(ms: u64, result: Result<&'static str, String>) -> Dial {
    Box::pin(async move {
        tokio::time::sleep(Duration::from_millis(ms)).await;
        result
    })
}

fn dead() -> Dial {
    Box::pin(pending())
}

/// A recovered direct route must get another attempt before the cold-connect
/// deadline expires, whether the old dial stalled before or during its upgrade.
#[cfg(target_os = "linux")]
#[tokio::test]
async fn a_direct_redial_has_its_own_deadline_through_the_websocket_upgrade() {
    use tokio::io::{AsyncBufReadExt, BufReader};
    for during_upgrade in [false, true] {
        let dir = tempfile::tempdir().unwrap();
        let socket = dir.path().join("link.sock");
        let listener = tokio::net::UnixListener::bind(&socket).unwrap();
        let (entered, stalled) = tokio::sync::oneshot::channel();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut stream = BufReader::new(stream);
            let mut line = String::new();
            stream.read_line(&mut line).await.unwrap();
            if during_upgrade {
                stream
                    .get_mut()
                    .write_all(
                        b"{\"ok\":true,\"path_state\":\"direct\",\"relay_available\":false}\n",
                    )
                    .await
                    .unwrap();
                loop {
                    line.clear();
                    assert!(stream.read_line(&mut line).await.unwrap() > 0);
                    if line == "\r\n" {
                        break;
                    }
                }
            }
            entered.send(()).unwrap();
            pending::<()>().await;
            drop(stream);
        });
        let (tx, _rx) = mpsc::channel(8);
        let peer = Peer::new("redial", "ssh://box", Some("token".into()), Some("peer".into()), tx);
        peer.set_link_host("inst_b".into());
        peer.set_link_socket(socket);
        peer.linked_once.store(true, Ordering::SeqCst);
        let dial =
            tokio::spawn(
                async move { peer.open_direct(Via::Link, None, For::Link).await.map(|_| ()) },
            );
        stalled.await.unwrap();
        tokio::time::pause();
        tokio::time::advance(Duration::from_secs(5)).await;
        tokio::task::yield_now().await;
        let finished = dial.is_finished();
        if !finished {
            dial.abort();
        }
        server.abort();
        assert!(
            finished,
            "direct redial still waits on the 30-second deadline; upgrade={during_upgrade}"
        );
        assert!(dial.await.unwrap().unwrap_err().contains("timed out"));
        tokio::time::resume();
    }
}

#[tokio::test(start_paused = true)]
async fn a_dead_direct_path_delays_ssh_by_the_stagger_only() {
    // The direct path never answers (a dead WireGuard route waits out its whole connect
    // deadline); ssh opens 300 ms after it starts.
    let started = tokio::time::Instant::now();
    let won = race(vec![(Via::Link, dead()), (Via::Ssh, after(300, Ok("ssh")))], STAGGER).await;
    let (via, value, failed) = won.expect("ssh opens");
    assert_eq!((via, value), (Via::Ssh, "ssh"));
    assert!(failed.is_empty());
    assert_eq!(started.elapsed(), STAGGER + Duration::from_millis(300));
}

#[tokio::test(start_paused = true)]
async fn a_path_that_fails_at_once_starts_the_next_at_once() {
    let started = tokio::time::Instant::now();
    let won = race(
        vec![
            (Via::Link, after(10, Err("cmux link is not running".into()))),
            (Via::Ssh, after(300, Ok("ssh"))),
        ],
        STAGGER,
    )
    .await;
    let (via, _, failed) = won.unwrap();
    assert_eq!(via, Via::Ssh);
    assert_eq!(failed, vec![(Via::Link, "cmux link is not running".to_owned())]);
    assert_eq!(started.elapsed(), Duration::from_millis(310));
}

#[tokio::test(start_paused = true)]
async fn the_first_path_wins_when_it_opens_within_the_stagger_and_ssh_never_starts() {
    let ssh_started = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let flag = ssh_started.clone();
    let ssh: Dial = Box::pin(async move {
        flag.store(true, Ordering::SeqCst);
        Ok("ssh")
    });
    let (via, _, _) =
        race(vec![(Via::Link, after(5, Ok("link"))), (Via::Ssh, ssh)], STAGGER).await.unwrap();
    assert_eq!(via, Via::Link);
    assert!(!ssh_started.load(Ordering::SeqCst), "no ssh process for a path that opened in 5 ms");
}

#[tokio::test(start_paused = true)]
async fn a_slow_first_path_still_wins_when_it_opens_before_the_next() {
    // Both run after the stagger; the earlier answer wins and the other is dropped.
    let won =
        race(vec![(Via::Link, after(400, Ok("link"))), (Via::Ssh, after(600, Ok("ssh")))], STAGGER)
            .await
            .unwrap();
    assert_eq!(won.0, Via::Link);
}

#[tokio::test(start_paused = true)]
async fn every_failure_is_returned_when_no_path_opens() {
    let failed = race(
        vec![
            (Via::Link, after(10, Err("refused".into()))),
            (Via::Ssh, after(20, Err("Permission denied".into()))),
        ],
        STAGGER,
    )
    .await
    .unwrap_err();
    assert_eq!(failed.len(), 2);
    assert_eq!(failures_line(&failed), "link: refused; ssh: Permission denied");
    assert_eq!(failures_line(&failed[1..]), "Permission denied", "one path: its own error");
}

#[test]
fn acpmux_wireguard_is_the_direct_path_only_while_it_holds_the_key_lock() {
    // The transport runs only when it took the key lock (`wireguard::Transport::start`).
    assert_eq!(direct_via(true, true), Some(Via::Wireguard));
    assert_eq!(direct_via(true, false), Some(Via::Wireguard));
    // The link holds the key: a paired peer is reached through the link.
    assert_eq!(direct_via(false, true), Some(Via::Link));
    assert_eq!(direct_via(false, false), None);
}

#[test]
fn a_ping_stamp_measures_its_pong() {
    let stamp = ping_stamp();
    std::thread::sleep(Duration::from_millis(2));
    let rtt = pong_rtt(&stamp).unwrap();
    assert!(rtt >= Duration::from_millis(2), "{rtt:?}");
    assert_eq!(pong_rtt(b""), None, "a ping from elsewhere (the wake probe) measures nothing");
    assert_eq!(pong_rtt(&u64::MAX.to_le_bytes()), None);
}

/// A link socket that answers one `link.dial` with `reply`, then echoes a line.
#[cfg(target_os = "linux")]
async fn fake_link(reply: &'static str) -> (tempfile::TempDir, PathBuf) {
    use tokio::io::{AsyncBufReadExt, BufReader};
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("link.sock");
    let listener = tokio::net::UnixListener::bind(&path).unwrap();
    tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let (read, mut write) = stream.into_split();
        let mut lines = BufReader::new(read).lines();
        let request = lines.next_line().await.unwrap().unwrap();
        assert_eq!(request, r#"{"op":"link.dial","host":"inst_b","service":"acpmux"}"#);
        write.write_all(reply.as_bytes()).await.unwrap();
        write.write_all(b"GET / HTTP/1.1\n").await.unwrap();
        if let Ok(Some(echoed)) = lines.next_line().await {
            write.write_all(format!("{echoed}\n").as_bytes()).await.unwrap();
        }
    });
    (dir, path)
}

#[cfg(target_os = "linux")]
#[tokio::test]
async fn a_link_dial_asks_for_the_acpmux_service_and_keeps_the_first_stream_bytes() {
    use tokio::io::{AsyncBufReadExt, BufReader};
    let (_dir, path) =
        fake_link("{\"ok\":true,\"path_state\":\"direct\",\"relay_available\":false}\n").await;
    let stream = dial_link(&path, "inst_b").await.unwrap();
    let mut lines = BufReader::new(stream);
    let mut first = String::new();
    lines.read_line(&mut first).await.unwrap();
    assert_eq!(first, "GET / HTTP/1.1\n");
    lines.get_mut().write_all(b"ping\n").await.unwrap();
    let mut echoed = String::new();
    lines.read_line(&mut echoed).await.unwrap();
    assert_eq!(echoed, "ping\n");
}

#[cfg(target_os = "linux")]
#[tokio::test]
async fn a_refused_link_dial_says_why_and_a_missing_link_is_not_running() {
    let (dir, path) = fake_link(
        "{\"ok\":false,\"path_state\":\"unreachable\",\"relay_available\":false,\"error_code\":\"unreachable\"}\n",
    )
    .await;
    let error = dial_link(&path, "inst_b").await.unwrap_err();
    assert!(error.contains("Unreachable"), "{error}");
    let error = dial_link(&dir.path().join("none.sock"), "inst_b").await.unwrap_err();
    assert!(error.starts_with("cmux link is not running"), "{error}");
}

/// A peer whose link `link` finished its handshake as a peer of this daemon, lending GitHub,
/// with a faster path picked and its outbound queue in the test's hands.
async fn lending_peer_with_a_switch_wanted()
-> (Arc<Peer>, u64, mpsc::Receiver<super::super::Outbound>) {
    let (tx, _rx) = mpsc::channel(8);
    let peer = Peer::new("switch-while-answering", "ws://127.0.0.1:9", None, None, tx);
    peer.set_github_broker(true);
    let link = peer.link_epoch();
    peer.github_link.store(link + 1, Ordering::SeqCst);
    let out = peer.out_rx.lock().await.take().unwrap();
    peer.switch_wanted.store(true, Ordering::SeqCst);
    assert!(peer.switch_due(), "nothing in flight: the link may move");
    (peer, link, out)
}

/// Review of #38357 at 9b28f327 (F1): a lent GitHub action the peer asked for holds the link
/// on its path while it runs and until its answer is written, and the answer goes out on the
/// link it was asked on; then the link moves.
#[tokio::test]
async fn an_incoming_github_action_holds_a_path_switch_until_its_answer_is_written() {
    let (peer, link, mut out) = lending_peer_with_a_switch_wanted().await;
    let slot =
        crate::github_broker::admit_owner(&peer.name, peer.github_ready(link), &peer.github_slots)
            .unwrap();
    // Invalid, so it answers without a `gh`: what matters is the answer's way out.
    peer.serve_github_action(serde_json::json!(7), serde_json::json!({}), slot, link);
    assert!(!peer.switch_due(), "the action is running: the link stays");
    let answer = tokio::time::timeout(Duration::from_secs(5), async {
        // Queued and not yet written: the link still stays.
        while peer.out.capacity() == peer.out.max_capacity() {
            assert!(!peer.switch_due(), "the action is running: the link stays");
            tokio::task::yield_now().await;
        }
        assert!(!peer.switch_due(), "the answer is queued, not written: the link stays");
        out.recv().await.unwrap()
    })
    .await
    .unwrap();
    assert_eq!(answer.epoch, link, "the answer goes out on the link it was asked on");
    let v: serde_json::Value = serde_json::from_str(answer.line.trim_end()).unwrap();
    assert_eq!(v["id"], 7, "{v}");
    assert!(v.get("error").is_some(), "{v}");
    assert!(peer.switch_due(), "the answer is out: the link moves");
}

/// An action that runs past its own budget no longer holds the link: a stuck one cannot pin a
/// slow path for good.
#[tokio::test(start_paused = true)]
async fn an_incoming_action_past_its_budget_no_longer_holds_the_link() {
    let (peer, _link, _out) = lending_peer_with_a_switch_wanted().await;
    let running = peer.answering.start(crate::github_broker::ACTION_BUDGET);
    assert!(!peer.switch_due());
    tokio::time::advance(crate::github_broker::ACTION_BUDGET - Duration::from_secs(1)).await;
    assert!(!peer.switch_due(), "within its budget it still holds the link");
    tokio::time::advance(Duration::from_secs(2)).await;
    assert!(peer.switch_due(), "past its budget it does not");
    drop(running);
    assert!(peer.switch_due());
}

/// A link socket that answers one `link.dial` for `inst_b`, then serves a WebSocket on the
/// stream (the peer's listener, through the link).
#[cfg(target_os = "linux")]
async fn fake_link_to_a_listener() -> (tempfile::TempDir, PathBuf) {
    use tokio::io::{AsyncBufReadExt, BufReader};
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("link.sock");
    let listener = tokio::net::UnixListener::bind(&path).unwrap();
    tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut stream = BufReader::new(stream);
        let mut request = String::new();
        stream.read_line(&mut request).await.unwrap();
        assert_eq!(request.trim_end(), r#"{"op":"link.dial","host":"inst_b","service":"acpmux"}"#);
        let reply = "{\"ok\":true,\"path_state\":\"direct\",\"relay_available\":false}\n";
        stream.get_mut().write_all(reply.as_bytes()).await.unwrap();
        let ws = tokio_tungstenite::accept_async(stream.into_inner()).await.unwrap();
        // Held open until the test ends.
        std::future::pending::<()>().await;
        drop(ws);
    });
    (dir, path)
}

/// Review of #38357 at 7e076d8e (F1): with the peer's tokens configured, a reachable link path
/// is dialed without any ssh read first, so an ssh that is down never stops it.
#[cfg(target_os = "linux")]
#[tokio::test]
async fn configured_tokens_reach_the_peer_over_the_link_while_ssh_is_down() {
    let (_dir, socket) = fake_link_to_a_listener().await;
    let (tx, _rx) = mpsc::channel(8);
    // Nothing answers ssh on port 1.
    let peer = Peer::new(
        "link-while-ssh-is-down",
        "ssh://nobody@127.0.0.1:1",
        Some("token".into()),
        Some("peer-token".into()),
        tx,
    );
    peer.refuse_early(); // its fake listener is a plain tungstenite accept, as before the early request
    peer.set_link_host("inst_b".into());
    peer.set_link_socket(socket);
    assert_eq!(peer.dial_order(), [Via::Link, Via::Ssh]);
    let (via, opened) = tokio::time::timeout(Duration::from_secs(5), peer.open_first())
        .await
        .expect("the link path waited on ssh")
        .unwrap();
    assert_eq!(via, Via::Link);
    assert_eq!(opened.presented.as_deref(), Some("peer-token"));
    peer.stop();
}

/// Relay first, measured on the race itself (paused clock): a black-holed WireGuard endpoint
/// and an ssh that never logs in, beside a hub relay that opens in 66 ms (its warm open).
/// Before, the relay was dialed last, two staggers after the dead paths; now it leads and the
/// remembered path starts beside it, so the black hole costs nothing.
#[tokio::test(start_paused = true)]
async fn relay_first_a_black_holed_direct_path_costs_no_more_than_the_relay_open() {
    const RELAY_OPEN: Duration = Duration::from_millis(66);
    let started = tokio::time::Instant::now();
    let before = race(
        vec![(Via::Wireguard, dead()), (Via::Ssh, dead()), (Via::Hub, after(66, Ok("hub")))],
        STAGGER,
    )
    .await
    .unwrap();
    let before_ms = started.elapsed();
    assert_eq!(before.0, Via::Hub);
    let started = tokio::time::Instant::now();
    let now = race_together(
        vec![(Via::Hub, after(66, Ok("hub"))), (Via::Wireguard, dead()), (Via::Ssh, dead())],
        2,
        STAGGER,
    )
    .await
    .unwrap();
    let after_ms = started.elapsed();
    assert_eq!(now.0, Via::Hub);
    eprintln!(
        "first byte with a black-holed WireGuard endpoint: {} ms direct first, {} ms relay first \
         (relay open {} ms)",
        before_ms.as_millis(),
        after_ms.as_millis(),
        RELAY_OPEN.as_millis()
    );
    assert_eq!(before_ms, 2 * STAGGER + RELAY_OPEN);
    assert_eq!(after_ms, RELAY_OPEN, "the black hole cost first-byte time");
}

/// Relay first, the remembered direct path starts beside the relay: when it answers first it
/// carries, and no later path is dialed at all.
#[tokio::test(start_paused = true)]
async fn relay_first_a_live_remembered_path_still_wins_when_it_answers_first() {
    let ssh_started = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let flag = ssh_started.clone();
    let ssh: Dial = Box::pin(async move {
        flag.store(true, Ordering::SeqCst);
        Ok("ssh")
    });
    let started = tokio::time::Instant::now();
    let (via, _, _) = race_together(
        vec![
            (Via::Hub, after(66, Ok("hub"))),
            (Via::Wireguard, after(8, Ok("wireguard"))),
            (Via::Ssh, ssh),
        ],
        2,
        STAGGER,
    )
    .await
    .unwrap();
    assert_eq!(via, Via::Wireguard);
    assert_eq!(started.elapsed(), Duration::from_millis(8));
    assert!(!ssh_started.load(Ordering::SeqCst));
}

// ---- the opt-in tailnet path (tailnet_carrier.rs, peer_tailnet.rs)

fn tailnet_peer(
    mode: crate::tailnet_carrier::Mode,
    calls: &Arc<AtomicUsize>,
    hint: crate::tailnet::PeerPath,
) -> Arc<Peer> {
    use crate::tailnet::{Node, Status};
    let node = |name: &str, ip: &str, path| Node {
        path,
        host_name: name.into(),
        dns_name: format!("{name}.tail1.ts.net"),
        os: "linux".into(),
        login: Some("leo@example.com".into()),
        tags: vec![],
        ips: vec![ip.parse().unwrap()],
        online: true,
        shared: false,
    };
    let status = Status {
        backend_state: "Running".into(),
        this: node("mac", "100.64.0.1", crate::tailnet::PeerPath::Unknown),
        peers: vec![node("box", "100.64.0.2", hint)],
    };
    let seen = calls.clone();
    let snaps = crate::tailnet_carrier::Snapshots::new(Arc::new(move || {
        seen.fetch_add(1, Ordering::SeqCst);
        Ok(status.clone())
    }));
    let (tx, _rx) = mpsc::channel(8);
    let peer = Peer::new("box", "ssh://leo@box:7777", Some("t".into()), Some("p".into()), tx);
    *peer.tailnet.lock().unwrap() = super::super::tailnet_path::State::with(mode, Some(snaps));
    peer
}

#[tokio::test]
async fn the_setting_off_has_no_tailnet_path_and_calls_no_tailscale() {
    use crate::tailnet::PeerPath;
    let calls = Arc::new(AtomicUsize::new(0));
    let peer = tailnet_peer(crate::tailnet_carrier::Mode::Off, &calls, PeerPath::Direct);
    peer.refresh_tailnet(None).await;
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert!(!peer.dial_order().contains(&Via::Tailnet));
    assert_eq!(calls.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn a_direct_hint_makes_a_path_that_is_offered_and_derp_is_not_in_direct_only() {
    use crate::tailnet::PeerPath;
    use crate::tailnet_carrier::Mode;
    let calls = Arc::new(AtomicUsize::new(0));
    let peer = tailnet_peer(Mode::DirectOnly, &calls, PeerPath::Direct);
    peer.refresh_tailnet(Some(Duration::from_secs(2))).await;
    assert!(peer.dial_order().contains(&Via::Tailnet), "offered and raced");
    assert_eq!(calls.load(Ordering::SeqCst), 1);

    let derp = tailnet_peer(Mode::DirectOnly, &calls, PeerPath::Derp);
    derp.refresh_tailnet(Some(Duration::from_secs(2))).await;
    assert!(!derp.dial_order().contains(&Via::Tailnet));

    let relayed = tailnet_peer(Mode::On, &calls, PeerPath::Derp);
    relayed.refresh_tailnet(Some(Duration::from_secs(2))).await;
    assert!(relayed.dial_order().contains(&Via::Tailnet), "on offers it, in the relayed class");
}

#[tokio::test]
async fn a_path_that_stops_being_offered_is_taken_out() {
    use crate::tailnet::PeerPath;
    let calls = Arc::new(AtomicUsize::new(0));
    let peer = tailnet_peer(crate::tailnet_carrier::Mode::DirectOnly, &calls, PeerPath::Direct);
    peer.refresh_tailnet(Some(Duration::from_secs(2))).await;
    assert!(peer.dial_order().contains(&Via::Tailnet));
    peer.apply_tailnet_route(None);
    assert!(!peer.dial_order().contains(&Via::Tailnet));
}

#[tokio::test(start_paused = true)]
async fn a_black_holed_tailnet_path_falls_back_within_the_stagger() {
    // The tailnet path never answers; the next path starts one stagger later, not after the
    // black hole's connect deadline.
    let started = tokio::time::Instant::now();
    let won = race(vec![(Via::Tailnet, dead()), (Via::Ssh, after(300, Ok("ssh")))], STAGGER).await;
    let (via, _, failed) = won.expect("ssh opens");
    assert_eq!(via, Via::Ssh);
    assert!(failed.is_empty());
    assert_eq!(started.elapsed(), STAGGER + Duration::from_millis(300));
}

#[tokio::test]
async fn lockstep_a_new_client_to_a_server_with_nothing_on_the_tailnet_falls_back() {
    // An old daemon listens on nothing at its tailnet address: the dial is refused at once.
    let closed = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = closed.local_addr().unwrap().port();
    drop(closed);
    let refused = tokio::net::TcpStream::connect(("127.0.0.1", port)).await;
    assert!(refused.is_err());
    let won = race(
        vec![
            (Via::Tailnet, Box::pin(async { Err("refused".to_owned()) }) as Dial),
            (Via::Ssh, after(5, Ok("ssh"))),
        ],
        STAGGER,
    )
    .await;
    let (via, _, failed) = won.unwrap();
    assert_eq!(via, Via::Ssh);
    assert_eq!(failed.len(), 1);
}

/// #54052: only the link's dial carries its `initialize` behind the upgrade. A probe's socket
/// greets the peer with its observer `probe_hello`, so its upgrade request has nothing behind it.
#[tokio::test]
async fn only_the_links_dial_sends_a_first_request_behind_the_upgrade() {
    use tokio::io::AsyncReadExt;
    for (dialer, wants_early) in [(For::Link, true), (For::Probe, false)] {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let (behind_tx, behind_rx) = tokio::sync::oneshot::channel();
        let server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut seen = Vec::new();
            let mut chunk = [0u8; 4096];
            let end = loop {
                let n = stream.read(&mut chunk).await.unwrap();
                assert!(n > 0, "the dial closed before its upgrade request ended");
                seen.extend_from_slice(&chunk[..n]);
                if let Some(at) = seen.windows(4).position(|w| w == b"\r\n\r\n") {
                    break at + 4;
                }
            };
            let mut behind = seen.len() - end;
            if behind == 0
                && let Ok(Ok(n)) =
                    tokio::time::timeout(Duration::from_millis(300), stream.read(&mut chunk)).await
            {
                behind = n;
            }
            behind_tx.send(behind).unwrap();
            pending::<()>().await;
            drop(stream);
        });
        let (tx, _rx) = mpsc::channel(8);
        let peer =
            Peer::new("early", &format!("ws://127.0.0.1:{port}"), Some("token".into()), None, tx);
        let dial = tokio::spawn(async move { peer.open_url(dialer).await.map(|_| ()) });
        let behind =
            tokio::time::timeout(Duration::from_secs(5), behind_rx).await.unwrap().unwrap();
        dial.abort();
        server.abort();
        assert_eq!(
            behind > 0,
            wants_early,
            "{dialer:?}: {behind} bytes behind the upgrade request"
        );
    }
}

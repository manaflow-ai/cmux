//! A dead link is found in seconds, and a slow one that still sends bytes is not cut
//! (`Peer::serve_heard`, `peer_link::Heard`, `Peer::ssh_connect_secs`).

use super::*;
use crate::peer_link::Heard;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio_tungstenite::WebSocketStream;
use tokio_tungstenite::tungstenite::protocol::Role;

/// A network that drops every packet (a closed lid, a dead Wi-Fi): the peer's end stays open
/// and says nothing. The link used to wait out 4 pings 20 s apart, 80 s, before its redial.
#[tokio::test(start_paused = true)]
async fn a_silent_peer_loses_the_link_within_seconds() {
    let (tx, _rx) = mpsc::channel(8);
    let peer = Peer::new("p", "ws://127.0.0.1:9", None, None, tx);
    let (ours, _theirs) = tokio::io::duplex(1 << 16);
    let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let link = peer.clone();
    let started = tokio::time::Instant::now();
    let serving = tokio::spawn(async move { link.serve(client, &mut out_rx).await });
    let ended = tokio::time::timeout(Duration::from_secs(10), serving)
        .await
        .expect("a silent peer loses the link within 10 s");
    let error = ended.unwrap().expect_err("the link ends with why");
    assert!(error.contains("stopped answering"), "{error}");
    assert!(started.elapsed() >= peer.timings.silence_budget(), "{:?}", started.elapsed());
}

/// Bytes of a frame still coming in count as an answer, so a large frame on a slow link is
/// not cut by the short silence budget.
#[tokio::test(start_paused = true)]
async fn heard_counts_bytes_as_they_arrive() {
    let heard = Heard::default();
    let (ours, mut theirs) = tokio::io::duplex(64);
    let mut ours = heard.wrap(ours);
    tokio::time::advance(Duration::from_secs(5)).await;
    assert!(heard.silent() >= Duration::from_secs(5));
    theirs.write_all(b"x").await.unwrap();
    let mut byte = [0u8; 1];
    ours.read_exact(&mut byte).await.unwrap();
    assert_eq!(heard.silent(), Duration::ZERO);
}

#[tokio::test(start_paused = true)]
async fn ssh_gives_up_on_a_dead_network_in_seconds_unless_the_host_is_slow_or_waking() {
    let connect = |argv: Vec<String>| argv.iter().any(|a| a == "ConnectTimeout=3");
    let (tx, _rx) = mpsc::channel(8);
    let peer = Peer::new("p", "ssh://box", None, None, tx.clone());
    assert_eq!(peer.ssh_connect_secs(), SSH_CONNECT_SECS);
    assert!(connect(tunnel_argv("box", 1, peer.ssh_connect_secs())));
    assert!(connect(read_config_argv("box", peer.ssh_connect_secs())));
    peer.note_ssh_failure(Some("SSH connection timed out"));
    assert_eq!(peer.ssh_connect_secs(), SSH_CONNECT_SECS, "a dead network keeps it short");
    peer.note_ssh_failure(Some(ssh_errors::BANNER_TIMEOUT));
    assert_eq!(peer.ssh_connect_secs(), SSH_CONNECT_SLOW_SECS, "a slow host gets the long one");
    let waking = Peer::new("w", "ssh://box", None, None, tx);
    waking.wake();
    assert_eq!(waking.ssh_connect_secs(), SSH_CONNECT_SLOW_SECS, "a route may resume the host");
    assert_eq!(
        ssh_errors::reason(b"Connection timed out during banner exchange"),
        Some(ssh_errors::BANNER_TIMEOUT)
    );
}

/// A loaded peer (load far past its cores) answers each ping 7 to 10 s late. With a fixed 6 s
/// budget its link dropped before each answer, and every redial sent the loaded host the whole
/// watch again, so the link flapped for good. A link dropped for silence that opens straight
/// back finds a live peer, slow and not gone: from then on its late answers keep the link.
#[tokio::test(start_paused = true)]
async fn a_peer_that_answers_7_to_10_s_late_keeps_its_link_after_the_first_late_answer() {
    use futures_util::SinkExt;
    use tokio_tungstenite::tungstenite::Message as Frame;
    let (tx, _rx) = mpsc::channel(8);
    let mut peer = Peer::new("p", "ws://127.0.0.1:9", None, None, tx);
    // No handshake here: the stand-in only answers late.
    Arc::get_mut(&mut peer).expect("only this test holds it").timings.handshake =
        Duration::from_secs(3_600);
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let mut answered = Vec::new();
    for link in 0..2 {
        let (ours, theirs) = tokio::io::duplex(1 << 16);
        let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
        let mut server = WebSocketStream::from_raw_socket(theirs, Role::Server, None).await;
        let answering = tokio::spawn(async move {
            for gap in [7u64, 10, 8, 9, 10, 7, 10, 9, 8, 10] {
                tokio::time::sleep(Duration::from_secs(gap)).await;
                if server.send(Frame::Pong(Vec::new().into())).await.is_err() {
                    return None;
                }
            }
            // Kept open: a dropped end would read as a reset on the link.
            Some(server)
        });
        let serving = peer.serve(client, &mut out_rx);
        tokio::pin!(serving);
        let kept = tokio::select! {
            biased;
            done = answering => done.unwrap().is_some(),
            ended = &mut serving => {
                answered.push(format!("link {link} ended: {ended:?}"));
                false
            }
        };
        if link == 1 {
            assert!(kept, "the redialed link to a live but slow peer is kept: {answered:?}");
        }
    }
}

/// A peer that says nothing at all is still let go within 8 s: the fast find of a dead link
/// (a dropped network, a computer that slept) stays.
#[tokio::test(start_paused = true)]
async fn a_silent_peer_still_loses_the_link_within_8_s() {
    let (tx, _rx) = mpsc::channel(8);
    let peer = Peer::new("p", "ws://127.0.0.1:9", None, None, tx);
    let (ours, _theirs) = tokio::io::duplex(1 << 16);
    let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let started = tokio::time::Instant::now();
    let ended = peer.serve(client, &mut out_rx).await;
    assert!(ended.expect_err("the link ends").contains("stopped answering"));
    assert!(started.elapsed() <= Duration::from_secs(8), "{:?}", started.elapsed());
}

/// Run 43783279032: the network went for 10 s without a reset and a request went out on the
/// link. It is dropped within `NETWORK_PROBE` of that request, not after the silence budget.
#[tokio::test(start_paused = true)]
async fn an_unanswered_request_drops_a_silent_link_within_2_s() {
    let (tx, _rx) = mpsc::channel(8);
    let mut peer = Peer::new("p", "ws://127.0.0.1:9", None, None, tx);
    // A budget long enough that only the request's probe can end the link in time.
    let timings = &mut Arc::get_mut(&mut peer).expect("only this test holds it").timings;
    timings.ping_misses = 30;
    timings.handshake = Duration::from_secs(3_600);
    let (ours, _theirs) = tokio::io::duplex(1 << 16);
    let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let link = peer.clone();
    let serving = tokio::spawn(async move { link.serve(client, &mut out_rx).await });
    tokio::time::sleep(Duration::from_secs(3)).await;
    let asked = tokio::time::Instant::now();
    peer.out.try_send(Outbound { epoch: peer.link_epoch(), key: None, line: "{}".into() }).unwrap();
    let ended = tokio::time::timeout(Duration::from_secs(10), serving)
        .await
        .expect("the link ends")
        .unwrap()
        .expect_err("the link ends with why");
    assert!(ended.contains("after a request"), "{ended}");
    let took = asked.elapsed();
    assert!(took <= crate::peer::network::NETWORK_PROBE + Duration::from_millis(100), "{took:?}");
}

/// A request on a link that answers keeps it: the probe's ping is answered.
#[tokio::test(start_paused = true)]
async fn a_request_on_a_link_that_answers_keeps_it() {
    use futures_util::StreamExt;
    let (tx, _rx) = mpsc::channel(8);
    let mut peer = Peer::new("p", "ws://127.0.0.1:9", None, None, tx);
    Arc::get_mut(&mut peer).expect("only this test holds it").timings.handshake =
        Duration::from_secs(3_600);
    let (ours, theirs) = tokio::io::duplex(1 << 16);
    let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
    let mut server = WebSocketStream::from_raw_socket(theirs, Role::Server, None).await;
    // Says nothing for 3 s (a loaded peer), then reads, which answers each ping with a pong.
    let answering = tokio::spawn(async move {
        tokio::time::sleep(Duration::from_secs(3)).await;
        while server.next().await.is_some() {}
    });
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let link = peer.clone();
    let serving = tokio::spawn(async move { link.serve(client, &mut out_rx).await });
    // Sent on a link silent 2.5 s: the probe goes out, and the pong at 3 s keeps the link.
    tokio::time::sleep(Duration::from_millis(2_500)).await;
    peer.out.try_send(Outbound { epoch: peer.link_epoch(), key: None, line: "{}".into() }).unwrap();
    tokio::time::sleep(Duration::from_secs(5)).await;
    assert!(!serving.is_finished(), "a link that answers the probe is kept");
    serving.abort();
    answering.abort();
}

/// This computer's network as a peer sees it (`peer_network.rs`), driven by the test: the sender
/// stands in for the kernel's routing watch.
fn own_network(peer: &Peer) -> tokio::sync::watch::Sender<u64> {
    use crate::no_panic::LockExt as _;
    let (changes, seen) = tokio::sync::watch::channel(0);
    *peer.network.lock_or_recover() = seen;
    changes
}

/// Leo, 2026-11-14: "i also want all our connectivity stuff to shut the fuck up and load
/// faster". A Wi-Fi switch, a VPN or an address change leaves an ssh link riding a route that is
/// gone. It used to wait out the silence budget (measured 7.0 s from the change to the first
/// answer); now it pings at once and redials when nothing answers within `NETWORK_PROBE`.
#[tokio::test(start_paused = true)]
async fn a_network_change_drops_a_link_that_stopped_answering_within_2_s() {
    let (tx, _rx) = mpsc::channel(8);
    let peer = Peer::new("p", "ws://127.0.0.1:9", None, None, tx);
    let changes = own_network(&peer);
    let (ours, _theirs) = tokio::io::duplex(1 << 16);
    let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let link = peer.clone();
    let serving = tokio::spawn(async move { link.serve(client, &mut out_rx).await });
    tokio::time::sleep(Duration::from_millis(500)).await;
    let changed = tokio::time::Instant::now();
    changes.send_modify(|n| *n += 1);
    let ended = tokio::time::timeout(Duration::from_secs(10), serving)
        .await
        .expect("the link ends")
        .unwrap()
        .expect_err("the link ends with why");
    assert!(ended.contains("network changed"), "{ended}");
    let took = changed.elapsed();
    assert!(took <= crate::peer::network::NETWORK_PROBE + Duration::from_millis(100), "{took:?}");
}

/// A link whose route survived the change answers the probe and is kept: no redial.
#[tokio::test(start_paused = true)]
async fn a_network_change_keeps_a_link_that_answers() {
    use futures_util::StreamExt;
    let (tx, _rx) = mpsc::channel(8);
    let mut peer = Peer::new("p", "ws://127.0.0.1:9", None, None, tx);
    Arc::get_mut(&mut peer).expect("only this test holds it").timings.handshake =
        Duration::from_secs(3_600);
    let changes = own_network(&peer);
    let (ours, theirs) = tokio::io::duplex(1 << 16);
    let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
    let mut server = WebSocketStream::from_raw_socket(theirs, Role::Server, None).await;
    // Reading answers each ping with a pong.
    let answering = tokio::spawn(async move { while server.next().await.is_some() {} });
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let link = peer.clone();
    let serving = tokio::spawn(async move { link.serve(client, &mut out_rx).await });
    for _ in 0..3 {
        tokio::time::sleep(Duration::from_millis(500)).await;
        changes.send_modify(|n| *n += 1);
    }
    tokio::time::sleep(Duration::from_secs(5)).await;
    assert!(!serving.is_finished(), "a link that answers is kept");
    serving.abort();
    answering.abort();
}

/// cosmic-gray at load 80 to 100 (2026-11-22): its daemon's link loops waited seconds for a
/// thread, and 493 links in 3 h were dropped for "6 to 19 s without a frame" that were this
/// Mac's stalls, the peer's answers waiting unread. A stall of this loop is not the peer's
/// silence: a link to a peer that answers survives ten 7 s stalls.
#[tokio::test(start_paused = true)]
async fn a_stall_of_this_computer_is_not_the_peers_silence() {
    use futures_util::StreamExt;
    let (tx, _rx) = mpsc::channel(8);
    let mut peer = Peer::new("p", "ws://127.0.0.1:9", None, None, tx);
    Arc::get_mut(&mut peer).expect("only this test holds it").timings.handshake =
        Duration::from_secs(3_600);
    let (ours, theirs) = tokio::io::duplex(1 << 16);
    let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
    let mut server = WebSocketStream::from_raw_socket(theirs, Role::Server, None).await;
    // Reading answers each ping with a pong.
    let answering = tokio::spawn(async move { while server.next().await.is_some() {} });
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let link = peer.clone();
    let serving = tokio::spawn(async move { link.serve(client, &mut out_rx).await });
    for stall in 0..10 {
        tokio::time::sleep(Duration::from_secs(3)).await;
        peer.out
            .try_send(Outbound { epoch: peer.link_epoch(), key: None, line: "{}".into() })
            .unwrap();
        // Nothing runs for 7 s, then every timer due meanwhile fires at once.
        tokio::time::advance(Duration::from_secs(7)).await;
        assert!(!serving.is_finished(), "dropped after stall {stall}");
    }
    tokio::time::sleep(Duration::from_secs(5)).await;
    assert!(!serving.is_finished(), "a link that answers is kept");
    serving.abort();
    answering.abort();
}

/// A dead link is still found when a stall came first: the first tick that runs on time after
/// it counts the whole silence.
#[tokio::test(start_paused = true)]
async fn a_dead_link_is_still_found_after_a_stall() {
    let (tx, _rx) = mpsc::channel(8);
    let mut peer = Peer::new("p", "ws://127.0.0.1:9", None, None, tx);
    Arc::get_mut(&mut peer).expect("only this test holds it").timings.handshake =
        Duration::from_secs(3_600);
    let (ours, _theirs) = tokio::io::duplex(1 << 16);
    let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let link = peer.clone();
    let serving = tokio::spawn(async move { link.serve(client, &mut out_rx).await });
    tokio::time::sleep(Duration::from_secs(1)).await;
    tokio::time::advance(Duration::from_secs(7)).await;
    let resumed = tokio::time::Instant::now();
    let ended = tokio::time::timeout(Duration::from_secs(10), serving)
        .await
        .expect("the link ends")
        .unwrap()
        .expect_err("the link ends with why");
    assert!(ended.contains("stopped answering"), "{ended}");
    assert!(resumed.elapsed() <= peer.timings.ping_every * 2, "{:?}", resumed.elapsed());
}

/// A peer on a loaded host: each of its reads comes 4.5 s after the last, and it then answers
/// everything sent meanwhile. Its pongs measure that, and a request on its link silent 2 s
/// waits for the answer, not the fixed 2 s probe that dropped such a link every few minutes.
#[tokio::test(start_paused = true)]
async fn a_request_waits_for_a_peer_whose_round_trip_is_measured_slow() {
    use futures_util::StreamExt;
    let (tx, _rx) = mpsc::channel(8);
    let mut peer = Peer::new("p", "ws://127.0.0.1:9", None, None, tx);
    Arc::get_mut(&mut peer).expect("only this test holds it").timings.handshake =
        Duration::from_secs(3_600);
    // Learned on the links before this one (the budget is the peer's, across links).
    peer.with_silence(|b| {
        for _ in 0..8 {
            b.answered_in(Duration::from_millis(4_500), tokio::time::Instant::now());
        }
    });
    let (ours, theirs) = tokio::io::duplex(1 << 16);
    let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
    let mut server = WebSocketStream::from_raw_socket(theirs, Role::Server, None).await;
    let answering = tokio::spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_millis(4_500)).await;
            // Reads what came meanwhile; each read answers its ping.
            loop {
                match tokio::time::timeout(Duration::from_millis(1), server.next()).await {
                    Ok(Some(_)) => continue,
                    Ok(None) => return,
                    Err(_) => break,
                }
            }
        }
    });
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let link = peer.clone();
    let serving = tokio::spawn(async move { link.serve(client, &mut out_rx).await });
    for _ in 0..120 {
        tokio::time::sleep(Duration::from_millis(500)).await;
        peer.out
            .try_send(Outbound { epoch: peer.link_epoch(), key: None, line: "{}".into() })
            .unwrap();
        assert!(!serving.is_finished(), "a slow peer that answers keeps its link");
    }
    serving.abort();
    answering.abort();
}

/// Duress count, run by hand on any commit (it uses nothing newer than the link loop):
/// `cargo test -p acpmux duress_link_drops -- --ignored --nocapture`. A live peer, and this
/// computer stalls 60 times for 3 to 9 s (cosmic-gray at load 80 to 100), a request before each:
/// how many times its link drops and is redialed.
#[tokio::test(start_paused = true)]
#[ignore = "a duress count for a PR's Duress line, not a check"]
async fn duress_link_drops_under_this_computers_stalls() {
    use futures_util::StreamExt;
    let (tx, _rx) = mpsc::channel(8);
    let mut peer = Peer::new("p", "ws://127.0.0.1:9", None, None, tx);
    Arc::get_mut(&mut peer).expect("only this test holds it").timings.handshake =
        Duration::from_secs(3_600);
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let stalls = [3u64, 9, 5, 7, 4, 8, 6, 3, 9, 7].repeat(6);
    let mut next = 0;
    let mut why: Vec<String> = Vec::new();
    while next < stalls.len() {
        let (ours, theirs) = tokio::io::duplex(1 << 16);
        let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
        let mut server = WebSocketStream::from_raw_socket(theirs, Role::Server, None).await;
        let answering = tokio::spawn(async move { while server.next().await.is_some() {} });
        let serving = peer.serve(client, &mut out_rx);
        tokio::pin!(serving);
        // The loop runs in this task: while this task stalls, so does the link's loop.
        loop {
            tokio::select! {
                ended = &mut serving => {
                    why.push(format!("{ended:?}"));
                    break;
                }
                () = tokio::time::sleep(Duration::from_secs(2)) => {
                    let line = Outbound { epoch: peer.link_epoch(), key: None, line: "{}".into() };
                    let _ = peer.out.try_send(line);
                    tokio::time::advance(Duration::from_secs(stalls[next])).await;
                    next += 1;
                    if next == stalls.len() {
                        break;
                    }
                }
            }
        }
        answering.abort();
    }
    let probe = why.iter().filter(|w| w.contains("after a request")).count();
    let silence = why.iter().filter(|w| w.contains("stopped answering")).count();
    println!(
        "DURESS link drops under {} stalls of 3-9 s, live peer: {} ({probe} by a request's probe, {silence} for silence)",
        stalls.len(),
        why.len()
    );
}

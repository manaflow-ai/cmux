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

/// A 5G/LTE handoff: the peer's last frame came 0.5 s after the link opened, then nothing. Its
/// link was dropped at the first ping tick past the 6 s budget, open + 8 s, 1.5 s after the
/// budget ran out; most of a direct handoff's 8 s was this wait. It is dropped at the budget.
#[tokio::test(start_paused = true)]
async fn a_dead_link_drops_at_its_budget_not_the_next_ping_tick() {
    use futures_util::SinkExt;
    use tokio_tungstenite::tungstenite::Message as Frame;
    let (tx, _rx) = mpsc::channel(8);
    let mut peer = Peer::new("p", "ws://127.0.0.1:9", None, None, tx);
    Arc::get_mut(&mut peer).expect("only this test holds it").timings.handshake =
        Duration::from_secs(3_600);
    let (ours, theirs) = tokio::io::duplex(1 << 16);
    let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
    let mut server = WebSocketStream::from_raw_socket(theirs, Role::Server, None).await;
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let link = peer.clone();
    let opened = tokio::time::Instant::now();
    let serving = tokio::spawn(async move { link.serve(client, &mut out_rx).await });
    tokio::time::sleep(Duration::from_millis(500)).await;
    server.send(Frame::Pong(Vec::new().into())).await.unwrap();
    let ended = tokio::time::timeout(Duration::from_secs(10), serving)
        .await
        .expect("the link ends")
        .unwrap()
        .expect_err("the link ends with why");
    assert!(ended.contains("stopped answering"), "{ended}");
    let budget = peer.timings.silence_budget();
    let took = opened.elapsed();
    assert!(took >= budget + Duration::from_millis(500), "dropped before its budget: {took:?}");
    assert!(
        took <= budget + Duration::from_millis(600),
        "dropped {took:?} after open, past its budget"
    );
    drop(server);
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

/// A live peer that says something each second and answers each ping, until its end closes.
fn talkative_peer(
    mut server: WebSocketStream<tokio::io::DuplexStream>,
) -> tokio::task::JoinHandle<()> {
    use futures_util::{SinkExt, StreamExt};
    use tokio_tungstenite::tungstenite::Message as Frame;
    tokio::spawn(async move {
        let note = r#"{"jsonrpc":"2.0","method":"_test/note","params":{}}"#;
        loop {
            tokio::select! {
                () = tokio::time::sleep(Duration::from_secs(1)) => {
                    if server.send(Frame::Text(note.into())).await.is_err() {
                        return;
                    }
                }
                frame = server.next() => if frame.is_none_or(|f| f.is_err()) { return },
            }
        }
    })
}

/// This computer's stalls, as the link's loop meets them: the hub does not take its notices
/// (`notices`, one slot) for `stall`, so the loop waits on its send while the peer's frames and
/// pongs wait unread; then the hub takes them all, and every timer due meanwhile is ready with
/// the frames. Answers when the link ended, if it did.
async fn stall_like_a_loaded_mac(
    notices: &mut mpsc::Receiver<(String, u64, PeerNotice)>,
    serving: &mut (impl std::future::Future<Output = Result<LinkEnd, String>> + Unpin),
    calm: Duration,
    stall: Duration,
) -> Option<Result<LinkEnd, String>> {
    let taking = async {
        let until = tokio::time::Instant::now() + calm;
        while tokio::time::timeout_at(until, notices.recv()).await.is_ok_and(|n| n.is_some()) {}
        tokio::time::sleep(stall).await;
    };
    tokio::select! {
        ended = serving => Some(ended),
        () = taking => None,
    }
}

/// cosmic-gray at load 80 to 100 (2026-11-22): its daemon's link loops waited seconds (for a
/// thread, for the hub to take a notice), and 493 links in 3 h were dropped for "6 to 19 s
/// without a frame" while the peer's frames waited unread. The time this loop was stuck is not
/// the peer's silence: a link to a live peer survives ten 9 s stalls, each after a calm 70 s
/// (past `stable_after`, so the silence budget is back at its 6 s start, as between load waves).
#[tokio::test(start_paused = true)]
async fn a_stall_of_this_computer_is_not_the_peers_silence() {
    let (tx, mut notices) = mpsc::channel(1);
    let mut peer = Peer::new("p", "ws://127.0.0.1:9", None, None, tx);
    // No handshake here: the stand-in answers no request, and its link outlives both bounds.
    let timings = &mut Arc::get_mut(&mut peer).expect("only this test holds it").timings;
    (timings.handshake, timings.request) =
        (Duration::from_secs(36_000), Duration::from_secs(36_000));
    let (ours, theirs) = tokio::io::duplex(1 << 20);
    let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
    let server = WebSocketStream::from_raw_socket(theirs, Role::Server, None).await;
    let talking = talkative_peer(server);
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let serving = peer.serve(client, &mut out_rx);
    tokio::pin!(serving);
    for stall in 0..10 {
        let calm = Duration::from_secs(70);
        let ended =
            stall_like_a_loaded_mac(&mut notices, &mut serving, calm, Duration::from_secs(9)).await;
        assert!(ended.is_none(), "dropped at stall {stall}: {ended:?}");
    }
    talking.abort();
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
/// computer stalls 60 times for 3 to 9 s, each after a calm 70 s (load waves on cosmic-gray at
/// load 80 to 100, the budget settled back to its start between them): how many times its link
/// drops and is redialed.
#[tokio::test(start_paused = true)]
#[ignore = "a duress count for a PR's Duress line, not a check"]
async fn duress_link_drops_under_this_computers_stalls() {
    let (tx, mut notices) = mpsc::channel(1);
    let mut peer = Peer::new("p", "ws://127.0.0.1:9", None, None, tx);
    // No handshake here: the stand-in answers no request, and its link outlives both bounds.
    let timings = &mut Arc::get_mut(&mut peer).expect("only this test holds it").timings;
    (timings.handshake, timings.request) =
        (Duration::from_secs(36_000), Duration::from_secs(36_000));
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let stalls = [3u64, 9, 5, 7, 4, 8, 6, 3, 9, 7].repeat(6);
    let mut next = 0;
    let mut why: Vec<String> = Vec::new();
    while next < stalls.len() {
        let (ours, theirs) = tokio::io::duplex(1 << 20);
        let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
        let server = WebSocketStream::from_raw_socket(theirs, Role::Server, None).await;
        let talking = talkative_peer(server);
        let serving = peer.serve(client, &mut out_rx);
        tokio::pin!(serving);
        while next < stalls.len() {
            let stall = Duration::from_secs(stalls[next]);
            next += 1;
            let calm = Duration::from_secs(70);
            if let Some(ended) =
                stall_like_a_loaded_mac(&mut notices, &mut serving, calm, stall).await
            {
                why.push(format!("{ended:?}"));
                break;
            }
        }
        talking.abort();
    }
    let probe = why.iter().filter(|w| w.contains("after a request")).count();
    let silence = why.iter().filter(|w| w.contains("stopped answering")).count();
    println!(
        "DURESS link drops under {} stalls of 3-9 s, live peer: {} ({probe} by a request's probe, {silence} for silence)",
        stalls.len(),
        why.len()
    );
    for w in &why {
        println!("DURESS drop: {w}");
    }
}

/// The link from the Mac to a lane VM reset about 42 times in two hours with a peer that
/// answered every ping: the link's loop waited for room in the hub's notice queue, read nothing
/// meanwhile, and took its own wait for the peer's silence ("peer stopped answering"). Time this
/// daemon keeps the loop from reading is not counted (`peer_link::ReaderHeld`): the link stays,
/// and a peer that is really silent after it is still let go within the budget.
#[tokio::test(start_paused = true)]
async fn a_link_held_by_a_full_hub_queue_is_not_dropped_for_the_peers_silence() {
    use futures_util::{SinkExt, StreamExt};
    use tokio_tungstenite::tungstenite::Message as Frame;
    // Room for one notice, read by nobody for 10 s: the hub is busy.
    let (tx, mut hub) = mpsc::channel(1);
    let mut peer = Peer::new("p", "ws://127.0.0.1:9", None, None, tx);
    Arc::get_mut(&mut peer).expect("only this test holds it").timings.handshake =
        Duration::from_secs(3_600);
    let (ours, theirs) = tokio::io::duplex(1 << 16);
    let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
    let mut server = WebSocketStream::from_raw_socket(theirs, Role::Server, None).await;
    // The peer sends three notices at once and then answers every ping (each read answers it)
    // for 20 s; then it says nothing, its end still open.
    let answering = tokio::spawn(async move {
        for n in 0..3 {
            let note = json!({"jsonrpc": "2.0", "method": "_test/note", "params": {"n": n}});
            server.send(Frame::Text(note.to_string().into())).await.unwrap();
        }
        let reads = async { while let Some(Ok(_)) = server.next().await {} };
        let _ = tokio::time::timeout(Duration::from_secs(20), reads).await;
        std::future::pending::<()>().await;
        drop(server);
    });
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let link = peer.clone();
    let serving = tokio::spawn(async move { link.serve(client, &mut out_rx).await });
    let busy = tokio::spawn(async move {
        tokio::time::sleep(Duration::from_secs(10)).await;
        while hub.recv().await.is_some() {}
    });
    tokio::time::sleep(Duration::from_millis(19_900)).await;
    assert!(
        !serving.is_finished(),
        "a link whose peer answers is kept after this daemon held it 10 s: {:?}",
        serving.await
    );
    // The peer goes silent: still found within the budget.
    let started = tokio::time::Instant::now();
    let ended = tokio::time::timeout(Duration::from_secs(10), serving)
        .await
        .expect("a silent peer still loses the link")
        .unwrap();
    assert!(ended.is_err(), "{ended:?}");
    assert!(started.elapsed() <= Duration::from_secs(9), "{:?}", started.elapsed());
    busy.abort();
    answering.abort();
}

/// A peer that reads this side's writes at 64 bytes a second, and a frame that takes about
/// 30 s to go out: the transport over `Heard` and the frame write under a 5 s send budget.
async fn send_a_frame_to_a_reader(reads: bool) -> (Result<LinkEnd, String>, usize, Duration) {
    let (tx, _rx) = mpsc::channel(8);
    let mut peer = Peer::new("p", "ws://127.0.0.1:9", None, None, tx);
    let timings = &mut Arc::get_mut(&mut peer).expect("only this test holds it").timings;
    timings.send = Duration::from_secs(5);
    timings.handshake = Duration::from_secs(3_600);
    let heard = Heard::default();
    let (ours, mut theirs) = tokio::io::duplex(64);
    let client = WebSocketStream::from_raw_socket(heard.wrap(ours), Role::Client, None).await;
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let link = peer.clone();
    let started = tokio::time::Instant::now();
    let serving =
        tokio::spawn(async move { link.serve_heard(client, &mut out_rx, Some(heard)).await });
    let draining = tokio::spawn(async move {
        let mut got = 0usize;
        let mut chunk = [0u8; 64];
        loop {
            if !reads {
                // Holds its end open and reads nothing: a peer that stopped reading.
                tokio::time::sleep(Duration::from_secs(3_600)).await;
                return got;
            }
            tokio::time::sleep(Duration::from_secs(1)).await;
            match theirs.read(&mut chunk).await {
                Ok(0) | Err(_) => return got,
                Ok(n) => got += n,
            }
        }
    });
    tokio::time::sleep(Duration::from_millis(100)).await;
    let line = format!("{{\"pad\":\"{}\"}}", "x".repeat(2_000));
    peer.out.try_send(Outbound { epoch: peer.link_epoch(), key: None, line }).unwrap();
    let ended = tokio::time::timeout(Duration::from_secs(600), serving)
        .await
        .expect("the link ends")
        .unwrap();
    let took = started.elapsed();
    let got = if reads {
        draining.await.unwrap()
    } else {
        draining.abort();
        0
    };
    (ended, got, took)
}

/// Leo, 2026-11-24: "if it's making good progress, it shiukd be allowed to keep going?" A
/// frame that needs about 30 s on a slow uplink went out in full; before, a fixed send budget
/// from the write's start cut it off and dropped the link.
#[tokio::test(start_paused = true)]
async fn a_slow_frame_write_that_keeps_moving_is_not_cut_off() {
    let (ended, got, took) = send_a_frame_to_a_reader(true).await;
    assert!(got >= 2_000, "the whole frame went out ({got} bytes in {took:?}; link: {ended:?})");
    assert!(took > Duration::from_secs(25), "{took:?}");
    if let Err(error) = &ended {
        assert!(!error.contains("stopped reading"), "{error}");
    }
}

/// A peer that takes no byte of a frame is still let go at the send budget of silence.
#[tokio::test(start_paused = true)]
async fn a_frame_write_that_moves_nothing_still_drops_the_link_at_the_send_budget() {
    let (ended, _, took) = send_a_frame_to_a_reader(false).await;
    let error = ended.expect_err("the link ends with why");
    assert!(error.contains("stopped reading"), "{error}");
    assert!(took <= Duration::from_secs(12), "{took:?}");
}

/// A silent link served under `start_paused` with a long silence budget (a peer whose budget
/// grew), so only a wake probe can end it in time; the lid closes for an hour `before` in. Gives
/// the time from the wake to the end and why it ended.
async fn wake_on_a_dead_link(before: Duration, slow: bool) -> (Duration, String) {
    use crate::store::test_clock;
    test_clock::follow_tokio();
    let (tx, _rx) = mpsc::channel(8);
    let mut peer = Peer::new("p", "ws://127.0.0.1:9", None, None, tx);
    let timings = &mut Arc::get_mut(&mut peer).expect("only this test holds it").timings;
    timings.ping_misses = 60;
    timings.handshake = Duration::from_secs(3_600);
    if slow {
        // A short probe once dropped a link that reopened at once: the peer proved slow.
        peer.with_silence(|b| {
            b.probe_dropped();
            b.opened(tokio::time::Instant::now());
        });
    }
    let (ours, _theirs) = tokio::io::duplex(1 << 16);
    let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let link = peer.clone();
    let serving = tokio::spawn(async move { link.serve(client, &mut out_rx).await });
    tokio::time::sleep(before).await;
    let woke = tokio::time::Instant::now();
    test_clock::advance(60 * 60 * 1_000);
    let ended = tokio::time::timeout(Duration::from_secs(100), serving).await;
    test_clock::reset();
    let ended = ended.expect("the link ends").unwrap().expect_err("the link ends with why");
    (woke.elapsed(), ended)
}

/// The audit of 2026-11-19 (Leo: "i wonder if there's more places we can apply this
/// principle"): after a wake a link had 30 s to answer, so opening the lid froze a remote chat
/// for up to 35 s. It now gets the 2 s network probe: dropped and redialed within one clock check
/// and `NETWORK_PROBE`, whenever in the ping cycle the lid opens.
#[tokio::test(start_paused = true)]
async fn a_wake_drops_a_dead_link_within_the_network_probe() {
    let bound =
        SleepWatch::EVERY + crate::peer::network::NETWORK_PROBE + Duration::from_millis(100);
    let mut worst = Duration::ZERO;
    for before in [500, 1_300, 2_100, 3_900] {
        let (took, why) = wake_on_a_dead_link(Duration::from_millis(before), false).await;
        assert!(why.contains("after this computer woke"), "{why}");
        assert!(took <= bound, "woke {before} ms in: dropped {took:?} after the wake");
        worst = worst.max(took);
    }
    eprintln!("wake to drop, worst of 4: {} ms", worst.as_millis());
}

/// The stop condition of the short probe: a peer that proved slow (a short probe dropped a link
/// that reopened at once) keeps the 30 s wake probe, so a slow link is not redialed on every
/// wake.
#[tokio::test(start_paused = true)]
async fn a_peer_that_proved_slow_keeps_the_long_wake_probe() {
    let (took, why) = wake_on_a_dead_link(Duration::from_millis(500), true).await;
    assert!(why.contains("after this computer woke"), "{why}");
    assert!(took >= crate::peer_link::WAKE_PROBE, "{took:?}");
}

/// A link that answers the wake ping is kept: the short probe costs a live link nothing.
#[tokio::test(start_paused = true)]
async fn a_wake_keeps_a_link_that_answers() {
    use crate::store::test_clock;
    use futures_util::StreamExt;
    test_clock::follow_tokio();
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
    tokio::time::sleep(Duration::from_millis(500)).await;
    test_clock::advance(60 * 60 * 1_000);
    tokio::time::sleep(Duration::from_secs(12)).await;
    test_clock::reset();
    assert!(!serving.is_finished(), "a link that answers the wake probe is kept");
    serving.abort();
    answering.abort();
}

#[test]
fn the_wake_probe_is_the_network_probe_unless_the_peer_proved_slow() {
    use crate::peer_link::{WAKE_PROBE, wake_probe};
    let net = crate::peer::network::NETWORK_PROBE;
    assert_eq!(wake_probe(true, net), Duration::from_secs(2));
    assert_eq!(wake_probe(false, net), WAKE_PROBE);
    assert_eq!(wake_probe(true, Duration::from_secs(90)), WAKE_PROBE, "never longer than before");
}

/// A ready link to `url` that hears nothing, with a 600 ms silence budget: how it ended, how
/// long it took, and whether a replacement waits for the next connect.
async fn a_ready_link_that_goes_silent(url: &str) -> (Result<LinkEnd, String>, Duration, bool) {
    let (tx, _rx) = mpsc::channel(8);
    let mut peer = Peer::new("p", url, None, None, tx);
    {
        let timings = &mut Arc::get_mut(&mut peer).expect("only this test holds it").timings;
        timings.ping_every = Duration::from_millis(200);
        timings.handshake = Duration::from_secs(3_600);
    }
    peer.set_serving(Some(crate::peer_paths::Via::Url));
    peer.with_link(|l| {
        let now = crate::store::now_ms();
        l.opened(now);
        l.ready(now);
    });
    let (ours, _theirs) = tokio::io::duplex(1 << 16);
    let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let started = tokio::time::Instant::now();
    let ended = tokio::time::timeout(Duration::from_secs(10), peer.serve(client, &mut out_rx))
        .await
        .expect("a silent link ends within 10 s");
    let replaced = peer.replacement.lock_or_recover().is_some();
    (ended, started.elapsed(), replaced)
}

/// Regression 1 after #54052: a 4 s blackout on an idle relay link. A ping sent in its first
/// second is retransmitted at +6.2 s, and every later byte waits behind it, so the link heard
/// nothing for its whole 6 s budget while the peer was fine. It was dropped, then waited its
/// backoff and a handshake: 3.6 to 5.6 s to resume instead of 2.3 s. A link silent past its
/// budget now dials a replacement while it still reads; the one that opens first carries the
/// link, with no drop.
#[tokio::test]
async fn a_silent_link_whose_peer_still_answers_a_dial_moves_to_it_without_a_drop() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    // Every connection is served, and one that is not a WebSocket upgrade (a dial's probe) is
    // let go: the listener stays up for the dial itself.
    let server = tokio::spawn(async move {
        let mut held = Vec::new();
        while let Ok((stream, _)) = listener.accept().await {
            if let Ok(ws) = tokio_tungstenite::accept_async(stream).await {
                held.push(ws);
            }
        }
    });
    let (ended, took, replaced) =
        a_ready_link_that_goes_silent(&format!("ws://127.0.0.1:{port}")).await;
    server.abort();
    assert_eq!(ended, Ok(LinkEnd::Switching), "a silent link with a reachable peer was dropped");
    assert!(replaced, "the replacement that opened is not kept for the next connect");
    assert!(took >= Duration::from_millis(600), "moved before its budget ran out: {took:?}");
}

/// The peer does not answer a dial either: the link still drops, by twice its budget.
#[tokio::test]
async fn a_silent_link_whose_replacement_does_not_open_still_drops() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    drop(listener);
    let (ended, took, replaced) =
        a_ready_link_that_goes_silent(&format!("ws://127.0.0.1:{port}")).await;
    let error = ended.expect_err("the link drops");
    assert!(error.contains("stopped answering"), "{error}");
    assert!(!replaced);
    assert!(took <= Duration::from_millis(1_500), "{took:?}");
}

//! WireGuard roaming: the phone's network changes in the middle of a
//! stream (its socket stops working and, with a roam, a new one takes
//! over). The stream must go on with no data lost and no stall a user
//! would notice.

use std::time::{Duration, Instant};

use bytes::Bytes;
use cnx_link::dial::{self, SessionEvents, wireguard};
use cnx_link::testing::{FakeOptions, FakeSignaling, TestTurn};
use cnx_link::{ChannelEvent, DialOptions, LinkConfig, LinkPath, SignalingClient, TransportKind};

fn options() -> DialOptions {
    DialOptions { include_loopback: true, timeout: Duration::from_secs(20), ..DialOptions::default() }
}

/// Bytes `[start, start + len)` of the endless test pattern.
fn pattern(start: usize, len: usize) -> Vec<u8> {
    (start..start + len).map(|i| (i % 251) as u8).collect()
}

/// What a run measured.
#[derive(Debug)]
struct Run {
    /// The longest time no echoed byte arrived, from the network change on.
    stall: Duration,
    /// The phone's path before the change and at the end.
    before: LinkPath,
    after: LinkPath,
    /// The Mac's label of the same path before the change and at the end.
    mac_before: Option<LinkPath>,
    mac_after: Option<LinkPath>,
    marks: Vec<(String, Duration)>,
}

/// What happens to the phone at 1 s.
#[derive(Clone)]
enum Change {
    /// Its network goes away; it roams this much later (as the OS reports
    /// the new path), or never.
    Network(Option<Duration>),
    /// The backend drops its signaling socket; it opens a new one and the
    /// session moves there.
    Signaling,
    /// The TCP or TLS stream of its TURN allocation dies; the session takes
    /// a new allocation.
    TurnStream,
    /// Its network starts dropping UDP to the TURN server (`TestTurn`
    /// blocks it), and it roams: the new allocation must use TLS.
    UdpBlocked(std::sync::Arc<TestTurn>),
}

/// Stream through an echo channel, take the phone's network away at 1 s
/// (and roam `roam` later, as the OS reports the new path), keep streaming
/// for `after_change`, then check every byte came back in order.
async fn stream_across_a_change(
    phone_options: DialOptions,
    mac_options: DialOptions,
    roam: Option<Duration>,
    after_change: Duration,
) -> Run {
    stream_across(phone_options, mac_options, Change::Network(roam), after_change).await
}

async fn stream_across(
    phone_options: DialOptions,
    mac_options: DialOptions,
    change: Change,
    after_change: Duration,
) -> Run {
    // `RUST_LOG=cnx_link=debug` shows what the tunnel did around a stall.
    let _ = tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .with_test_writer()
        .try_init();
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let mac_id = uuid::Uuid::new_v4().to_string();
    let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
    let mac_path = std::sync::Arc::new(std::sync::Mutex::new(None::<tokio::sync::watch::Receiver<LinkPath>>));
    let mac_path_slot = std::sync::Arc::clone(&mac_path);
    tokio::spawn(async move {
        while let Some(session) = mac.next_session().await {
            let events = SessionEvents {
                backend: mac.events(),
                session_id: session.first.session_id.clone(),
                session: session.events,
            };
            let (mac, options) = (mac.clone(), mac_options.clone());
            let mac_path_slot = std::sync::Arc::clone(&mac_path_slot);
            tokio::spawn(async move {
                let connected =
                    dial::answer(&mac, session.first, events, &options, LinkConfig::default()).await.unwrap();
                *mac_path_slot.lock().unwrap() = Some(connected.path.clone());
                while let Some(mut incoming) = connected.link.accept().await {
                    tokio::spawn(async move {
                        while let Some(ChannelEvent::Data(bytes)) = incoming.channel.recv().await {
                            let _ = incoming.channel.send(bytes).await;
                        }
                    });
                }
            });
        }
    });
    let phone_id = uuid::Uuid::new_v4().to_string();
    let phone = SignalingClient::connect(&server.base_url, "user:alice", "team", &phone_id).await.unwrap();
    let connected =
        dial::connect(&phone, &mac_id, TransportKind::WireGuard, &phone_options, LinkConfig::default())
            .await
            .expect("dial");
    let session_id = connected.session_id.clone();
    let mut path = connected.path.clone();
    let _ = tokio::time::timeout(Duration::from_secs(10), path.wait_for(|p| *p != LinkPath::NoPath)).await;
    let channel = connected.link.open("echo", serde_json::json!({})).await.unwrap();
    let (sender, mut receiver) = channel.split();

    // Terminal-like output: 1 KB every 10 ms.
    const CHUNK: usize = 1000;
    let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let writer = {
        let stop = std::sync::Arc::clone(&stop);
        tokio::spawn(async move {
            let mut sent = 0usize;
            let mut tick = tokio::time::interval(Duration::from_millis(10));
            while !stop.load(std::sync::atomic::Ordering::Relaxed) {
                tick.tick().await;
                sender.send(Bytes::from(pattern(sent, CHUNK))).await.expect("send");
                sent += CHUNK;
            }
            // Dropping the sender would close the channel before the echo
            // of the last bytes arrives.
            (sent, sender)
        })
    };
    let (progress_tx, mut progress) = tokio::sync::watch::channel(0usize);
    let reader = tokio::spawn(async move {
        let mut got = 0usize;
        let mut arrivals = Vec::new();
        while let Some(event) = receiver.recv().await {
            match event {
                ChannelEvent::Data(bytes) => {
                    assert_eq!(&bytes[..], &pattern(got, bytes.len())[..], "echo out of order at {got}");
                    got += bytes.len();
                    arrivals.push(Instant::now());
                    progress_tx.send_replace(got);
                }
                ChannelEvent::Closed(_) => break,
            }
        }
        arrivals
    });

    tokio::time::sleep(Duration::from_secs(1)).await;
    let before = *connected.path.borrow();
    let mac_label = || mac_path.lock().unwrap().as_ref().map(|path| *path.borrow());
    let mac_before = mac_label();
    let changed_at = Instant::now();
    let mut _new_phone = None;
    let roam_task = match change {
        Change::Network(roam) => {
            assert_eq!(wireguard::simulate_network_loss(Some(&session_id), true), 1);
            roam.map(|delay| {
                let session_id = session_id.clone();
                tokio::spawn(async move {
                    tokio::time::sleep(delay).await;
                    wireguard::roam_session(&session_id, true).await
                })
            })
        }
        Change::Signaling => {
            server.kick(&phone_id);
            let mut closed = phone.events();
            while !matches!(closed.recv().await, Ok(cnx_link::signaling::SignalingEvent::Disconnected(_))) {}
            let fresh =
                SignalingClient::connect(&server.base_url, "user:alice", "team", &phone_id).await.unwrap();
            assert!(wireguard::rehome(&fresh) >= 1);
            _new_phone = Some(fresh);
            None
        }
        Change::TurnStream => {
            assert_eq!(wireguard::simulate_turn_loss(Some(&session_id), true), 1);
            None
        }
        Change::UdpBlocked(turn) => {
            turn.set_udp_blocked(true);
            assert_eq!(wireguard::simulate_network_loss(Some(&session_id), true), 1);
            let session_id = session_id.clone();
            Some(tokio::spawn(async move { wireguard::roam_session(&session_id, true).await }))
        }
    };
    tokio::time::sleep(after_change).await;
    stop.store(true, std::sync::atomic::Ordering::Relaxed);
    let (sent, _sender) = writer.await.unwrap();
    let timeline = match roam_task {
        Some(task) => task.await.unwrap(),
        None => None,
    };
    // Every byte comes back.
    let all =
        tokio::time::timeout(Duration::from_secs(25), progress.wait_for(|got| *got >= sent)).await.is_ok();
    let got = *progress.borrow();
    connected.link.close("done");
    let arrivals = reader.await.unwrap();
    assert!(all && got == sent, "bytes lost: sent {sent}, echoed {got}");
    let mut last = changed_at;
    let mut stall = Duration::ZERO;
    for at in arrivals.iter().filter(|at| **at >= changed_at) {
        stall = stall.max(at.duration_since(last));
        last = *at;
    }
    let after = *connected.path.borrow();
    let mac_after = mac_label();
    Run {
        stall,
        before,
        after,
        mac_before,
        mac_after,
        marks: timeline.map(|t| t.marks()).unwrap_or_default(),
    }
}

fn names(run: &Run) -> Vec<&str> {
    run.marks.iter().map(|(name, _)| name.as_str()).collect()
}

/// Plain roam: the phone moves to a new socket (a new local port, as on a
/// new network). The Mac roams with WireGuard's endpoint roaming the moment
/// the phone's first datagram from the new socket authenticates.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_roams_to_a_new_socket_without_a_stall() {
    let run =
        stream_across_a_change(options(), options(), Some(Duration::ZERO), Duration::from_secs(3)).await;
    eprintln!("roam: {run:?}");
    assert_eq!(run.before, LinkPath::Direct);
    assert_eq!(run.after, LinkPath::Direct);
    assert_eq!(run.mac_after, Some(LinkPath::Direct));
    assert!(run.stall < Duration::from_secs(1), "stalled {:?}", run.stall);
    for mark in ["network_changed", "roam_reasserted", "roam_first_packet", "roam_direct"] {
        assert!(names(&run).contains(&mark), "no {mark} in {:?}", run.marks);
    }
}

/// The Mac sits behind an address-restricted NAT: it drops the phone's UDP
/// from the new address until it has sent there itself. Only the phone's
/// endpoint announcement (inside the tunnel, over its new route) lets
/// the Mac open its side.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_roams_through_an_address_restricted_nat() {
    let mac = DialOptions { restrict_inbound_udp: true, ..options() };
    let run = stream_across_a_change(options(), mac, Some(Duration::ZERO), Duration::from_secs(3)).await;
    eprintln!("restricted roam: {run:?}");
    assert_eq!(run.before, LinkPath::Direct);
    assert_eq!(run.after, LinkPath::Direct);
    assert!(run.stall < Duration::from_secs(1), "stalled {:?}", run.stall);
}

/// Relay only through TURN: the roam takes a fresh allocation (the old one
/// belongs to the old network) and the Mac follows the new relayed address.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_roam_takes_a_fresh_turn_allocation() {
    let turn = TestTurn::start().await;
    let phone = DialOptions { relay_only: true, ice_servers: vec![turn.udp_only()], ..options() };
    let run = stream_across_a_change(phone, options(), Some(Duration::ZERO), Duration::from_secs(3)).await;
    eprintln!("turn roam: {run:?}");
    assert_eq!(run.before, LinkPath::Turn);
    assert_eq!(run.after, LinkPath::Turn);
    // The Mac sends plain UDP to the phone's relayed address: still TURN,
    // also after the roam's new allocation (wg-init and the roam's
    // endpoint announcement say which address is relayed).
    assert_eq!(run.mac_before, Some(LinkPath::Turn));
    assert_eq!(run.mac_after, Some(LinkPath::Turn));
    assert!(run.stall < Duration::from_secs(1), "stalled {:?}", run.stall);
    for mark in ["roam_turn_allocated", "roam_first_packet", "roam_turn"] {
        assert!(names(&run).contains(&mark), "no {mark} in {:?}", run.marks);
    }
}

/// The OS reports the new path 300 ms after the old network died: what
/// was sent into the dead network meanwhile is sent again, so the stall is
/// that delay plus a round trip, not TCP's 1 s retransmission timeout.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_roams_after_a_late_path_update() {
    let mac = DialOptions { restrict_inbound_udp: true, ..options() };
    let run =
        stream_across_a_change(options(), mac, Some(Duration::from_millis(300)), Duration::from_secs(3))
            .await;
    eprintln!("late roam: {run:?}");
    assert_eq!(run.after, LinkPath::Direct);
    assert!(run.stall < Duration::from_millis(600), "stalled {:?}", run.stall);
}

/// Airplane mode for 5 s, then the network comes back: the same session
/// resumes (no redial), and TCP inside it does not wait out a backed-off
/// retransmission timeout.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_resumes_after_airplane_mode() {
    let run =
        stream_across_a_change(options(), options(), Some(Duration::from_secs(5)), Duration::from_secs(7))
            .await;
    eprintln!("airplane: {run:?}");
    assert_eq!(run.after, LinkPath::Direct);
    assert!(run.stall < Duration::from_millis(5500), "stalled {:?}", run.stall);
}

/// The backend drops the phone's signaling socket, as a network change
/// does. The tunnel never used it for data: the stream goes on, and the
/// session moves to the new socket (for `bye`).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_session_follows_a_new_signaling_socket() {
    let run = stream_across(options(), options(), Change::Signaling, Duration::from_secs(3)).await;
    eprintln!("rehome: {run:?}");
    assert_eq!(run.after, LinkPath::Direct);
    assert!(run.stall < Duration::from_millis(500), "stalled {:?}", run.stall);
}

/// UDP blocked: the roam takes a fresh TURN allocation over TLS, and the
/// Mac follows the new relayed address (still labeled TURN over TLS).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_roam_with_udp_blocked_takes_a_fresh_turn_tls_allocation() {
    let turn = TestTurn::start().await;
    let phone = DialOptions {
        block_udp: true,
        ice_servers: vec![turn.ice.clone()],
        turn_tls_roots: Some(std::sync::Arc::clone(&turn.roots)),
        ..options()
    };
    let run = stream_across_a_change(phone, options(), Some(Duration::ZERO), Duration::from_secs(3)).await;
    eprintln!("turn-tls roam: {run:?}");
    assert_eq!(run.before, LinkPath::TurnTls);
    assert_eq!(run.after, LinkPath::TurnTls);
    assert_eq!(run.mac_before, Some(LinkPath::TurnTls));
    assert_eq!(run.mac_after, Some(LinkPath::TurnTls));
    assert!(run.stall < Duration::from_secs(1), "stalled {:?}", run.stall);
    assert_eq!(turn.stream_connections(), 2, "the roam did not take a new TLS allocation");
    for mark in ["roam_turn_tls_allocated", "roam_first_packet", "roam_turn"] {
        assert!(names(&run).contains(&mark), "no {mark} in {:?}", run.marks);
    }
}

/// Roaming across TURN transports: the phone rides TURN over UDP, then
/// moves to a network that drops UDP. The roam's new allocation falls back
/// to TLS and the stream goes on with every byte.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_roams_from_turn_udp_to_turn_tls() {
    let turn = std::sync::Arc::new(TestTurn::start().await);
    let phone = DialOptions {
        relay_only: true,
        ice_servers: vec![turn.ice.clone()],
        turn_tls_roots: Some(std::sync::Arc::clone(&turn.roots)),
        ..options()
    };
    let run = stream_across(
        phone,
        options(),
        Change::UdpBlocked(std::sync::Arc::clone(&turn)),
        Duration::from_secs(4),
    )
    .await;
    eprintln!("udp to tls roam: {run:?}");
    assert_eq!(run.before, LinkPath::Turn);
    assert_eq!(run.after, LinkPath::TurnTls);
    assert_eq!(run.mac_after, Some(LinkPath::TurnTls));
    // The UDP attempt waits out its stagger before TLS starts.
    assert!(run.stall < Duration::from_secs(3), "stalled {:?}", run.stall);
    assert!(names(&run).contains(&"roam_turn_tls_allocated"), "{:?}", run.marks);
}

/// The TLS stream to the TURN server dies (a middlebox resets it) without
/// any network change: the session takes a new allocation, tells the Mac,
/// and resends what went into the dead one.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_replaces_a_dead_turn_tls_stream() {
    let turn = TestTurn::start().await;
    let phone = DialOptions {
        block_udp: true,
        ice_servers: vec![turn.ice.clone()],
        turn_tls_roots: Some(std::sync::Arc::clone(&turn.roots)),
        ..options()
    };
    let run = stream_across(phone, options(), Change::TurnStream, Duration::from_secs(3)).await;
    eprintln!("dead TLS stream: {run:?}");
    assert_eq!(run.after, LinkPath::TurnTls);
    assert_eq!(run.mac_after, Some(LinkPath::TurnTls));
    assert_eq!(turn.stream_connections(), 2);
    assert!(run.stall < Duration::from_secs(2), "stalled {:?}", run.stall);
}

/// The baseline: the network goes away and nothing roams. With no TURN
/// server and no backend relay (retired), nothing carries the stream again
/// without a roam: the bytes sent meanwhile never come back. Run with
/// `--ignored` to see it.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "takes about 35 s; the before-roaming baseline"]
#[should_panic(expected = "bytes lost")]
async fn wireguard_without_roaming_never_recovers() {
    let _ = stream_across_a_change(options(), options(), None, Duration::from_secs(5)).await;
}

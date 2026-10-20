//! Both dialers carry the same Link through a local fake signaling server.

use std::time::Duration;

use bytes::Bytes;
use cnx_link::dial::{self, SessionEvents};
use cnx_link::testing::{FakeOptions, FakeSignaling, TEST_RELAY_PORTS_START, TestTurn};
use cnx_link::{
    ChannelEvent, DialOptions, Lane, LaneState, LinkConfig, LinkPath, SignalingClient, TransportKind,
};

fn options() -> DialOptions {
    DialOptions { include_loopback: true, timeout: Duration::from_secs(20), ..DialOptions::default() }
}

/// A Mac that answers every new session and echoes every channel.
fn spawn_echo_mac(mac: SignalingClient) -> tokio::task::JoinHandle<()> {
    spawn_echo_mac_with(mac, options())
}

fn spawn_echo_mac_with(mac: SignalingClient, mac_options: DialOptions) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        while let Some(session) = mac.next_session().await {
            let first = session.first;
            let events = SessionEvents {
                backend: mac.events(),
                session_id: first.session_id.clone(),
                session: session.events,
            };
            let mac = mac.clone();
            let mac_options = mac_options.clone();
            tokio::spawn(async move {
                let connected = dial::answer(&mac, first, events, &mac_options, LinkConfig::default())
                    .await
                    .expect("answer");
                while let Some(mut incoming) = connected.link.accept().await {
                    tokio::spawn(async move {
                        if incoming.service != "echo" {
                            incoming.channel.close("unknown_service", "").await;
                            return;
                        }
                        while let Some(ChannelEvent::Data(bytes)) = incoming.channel.recv().await {
                            if incoming.channel.send(bytes).await.is_err() {
                                return;
                            }
                        }
                    });
                }
            });
        }
    })
}

async fn exercise(kind: TransportKind, fake: FakeOptions) -> (LinkPath, u64) {
    let server = FakeSignaling::start(fake).await;
    let phone_id = uuid::Uuid::new_v4().to_string();
    let mac_id = uuid::Uuid::new_v4().to_string();
    let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
    let _mac_task = spawn_echo_mac(mac);
    let phone = SignalingClient::connect(&server.base_url, "user:alice", "team", &phone_id).await.unwrap();
    let connected =
        dial::connect(&phone, &mac_id, kind, &options(), LinkConfig::default()).await.expect("dial");
    assert_eq!(connected.transport, kind);

    let mut channel = connected.link.open("echo", serde_json::json!({})).await.unwrap();
    let payload: Vec<u8> = (0..200_000u32).map(|i| (i % 251) as u8).collect();
    channel.send(Bytes::from(payload.clone())).await.unwrap();
    let mut echoed = Vec::new();
    while echoed.len() < payload.len() {
        match tokio::time::timeout(Duration::from_secs(20), channel.recv()).await.expect("echo in time") {
            Some(ChannelEvent::Data(bytes)) => echoed.extend_from_slice(&bytes),
            other => panic!("unexpected {other:?}"),
        }
    }
    assert_eq!(echoed, payload);

    let mut refused = connected.link.open("shell", serde_json::json!({})).await.unwrap();
    match refused.recv().await {
        Some(ChannelEvent::Closed(info)) => assert_eq!(info.code, "unknown_service"),
        other => panic!("unexpected {other:?}"),
    }
    let rtt = connected.link.ping().await.unwrap();
    assert!(rtt < Duration::from_secs(5));
    let path = *connected.path.borrow();
    connected.link.close("done");
    (path, server.refused_binary_frames())
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn webrtc_carries_the_link() {
    let (path, _) = exercise(TransportKind::WebRtc, FakeOptions::default()).await;
    assert_eq!(path, LinkPath::Direct);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_carries_the_link_directly() {
    let (path, binary) = exercise(TransportKind::WireGuard, FakeOptions::default()).await;
    assert_eq!(path, LinkPath::Direct);
    // Neither side sends a relay frame any more.
    assert_eq!(binary, 0);
}

/// Both sides take the other for an older peer (no `version`): no `reach`
/// will come, so each confirms the route by the peer's datagrams, and the
/// link still settles on the direct path.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_with_an_older_peer_confirms_by_its_datagrams() {
    let (path, binary) =
        exercise(TransportKind::WireGuard, FakeOptions { strip_wg_version: true, ..FakeOptions::default() })
            .await;
    assert_eq!(path, LinkPath::Direct);
    assert_eq!(binary, 0);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn dialing_another_users_mac_is_refused() {
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let mac_id = uuid::Uuid::new_v4().to_string();
    let _mac = SignalingClient::connect(&server.base_url, "user:bob", "team", &mac_id).await.unwrap();
    let phone =
        SignalingClient::connect(&server.base_url, "user:alice", "team", &uuid::Uuid::new_v4().to_string())
            .await
            .unwrap();
    let error = dial::connect(&phone, &mac_id, TransportKind::WebRtc, &options(), LinkConfig::default())
        .await
        .err()
        .expect("refused");
    assert!(matches!(error, cnx_link::DialError::Refused { ref code, .. } if code == "not_owner"), "{error}");
}

/// What [`exercise_turn`] saw.
#[derive(Debug)]
struct TurnRun {
    /// The phone's path once settled, and every change after that.
    phone: LinkPath,
    changes: Vec<LinkPath>,
    /// The Mac's label of the same path at the end.
    mac: Option<LinkPath>,
    /// Relay frames the backend refused (none from a current client).
    binary: u64,
}

/// Dial a Mac that answers with `mac_options`, echo 400 KB in rounds, and
/// return what both sides saw while traffic kept flowing.
async fn exercise_turn(phone_options: DialOptions, mac_options: DialOptions) -> TurnRun {
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
    let phone =
        SignalingClient::connect(&server.base_url, "user:alice", "team", &uuid::Uuid::new_v4().to_string())
            .await
            .unwrap();
    let connected =
        dial::connect(&phone, &mac_id, TransportKind::WireGuard, &phone_options, LinkConfig::default())
            .await
            .expect("dial");
    let mut channel = connected.link.open("echo", serde_json::json!({})).await.unwrap();
    let mut path = connected.path.clone();
    let mut changes = Vec::new();
    // Echo in rounds; after the first rounds the route must have settled.
    for round in 0..8 {
        channel.send(Bytes::from(vec![round as u8; 50_000])).await.unwrap();
        let mut got = 0;
        while got < 50_000 {
            match tokio::time::timeout(Duration::from_secs(20), channel.recv()).await.expect("echo in time") {
                Some(ChannelEvent::Data(bytes)) => got += bytes.len(),
                other => panic!("unexpected {other:?}"),
            }
        }
        if round == 3 {
            path.mark_unchanged();
        }
        if round > 3 && path.has_changed().unwrap_or(false) {
            changes.push(*path.borrow_and_update());
        }
        tokio::time::sleep(Duration::from_millis(150)).await;
    }
    let settled = *connected.path.borrow();
    let mac = mac_path.lock().unwrap().as_ref().map(|path| *path.borrow());
    connected.link.close("done");
    TurnRun { phone: settled, changes, mac, binary: server.refused_binary_frames() }
}

/// [`exercise_turn`], echoing in rounds for at least `min`.
async fn exercise_turn_for(phone_options: DialOptions, mac_options: DialOptions, min: Duration) -> TurnRun {
    exercise_turn_idle(phone_options, mac_options, min, Duration::ZERO).await
}

/// [`exercise_turn_for`], then `idle` with no traffic (keepalives only),
/// then echo rounds again; `changes` lists the Mac's path changes seen from
/// the idle gap on.
async fn exercise_turn_idle(
    phone_options: DialOptions,
    mac_options: DialOptions,
    min: Duration,
    idle: Duration,
) -> TurnRun {
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let mac_id = uuid::Uuid::new_v4().to_string();
    let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
    let mac_path = std::sync::Arc::new(std::sync::Mutex::new(None::<tokio::sync::watch::Receiver<LinkPath>>));
    let slot = std::sync::Arc::clone(&mac_path);
    tokio::spawn(async move {
        while let Some(session) = mac.next_session().await {
            let events = SessionEvents {
                backend: mac.events(),
                session_id: session.first.session_id.clone(),
                session: session.events,
            };
            let (mac, options, slot) = (mac.clone(), mac_options.clone(), std::sync::Arc::clone(&slot));
            tokio::spawn(async move {
                let connected =
                    dial::answer(&mac, session.first, events, &options, LinkConfig::default()).await.unwrap();
                *slot.lock().unwrap() = Some(connected.path.clone());
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
    let phone =
        SignalingClient::connect(&server.base_url, "user:alice", "team", &uuid::Uuid::new_v4().to_string())
            .await
            .unwrap();
    let connected =
        dial::connect(&phone, &mac_id, TransportKind::WireGuard, &phone_options, LinkConfig::default())
            .await
            .expect("dial");
    let mut channel = connected.link.open("echo", serde_json::json!({})).await.unwrap();
    let started = std::time::Instant::now();
    let mut round = 0u8;
    while started.elapsed() < min {
        channel.send(Bytes::from(vec![round; 20_000])).await.unwrap();
        let mut got = 0;
        while got < 20_000 {
            match tokio::time::timeout(Duration::from_secs(20), channel.recv()).await.expect("echo in time") {
                Some(ChannelEvent::Data(bytes)) => got += bytes.len(),
                other => panic!("unexpected {other:?}"),
            }
        }
        round = round.wrapping_add(1);
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    let mut changes = Vec::new();
    if !idle.is_zero() {
        let mut mac_watch = mac_path.lock().unwrap().clone().expect("the Mac answered");
        mac_watch.mark_unchanged();
        let idle_end = tokio::time::Instant::now() + idle;
        while let Ok(Ok(())) = tokio::time::timeout_at(idle_end, mac_watch.changed()).await {
            changes.push(*mac_watch.borrow_and_update());
        }
        for round in 0..5u8 {
            channel.send(Bytes::from(vec![round; 20_000])).await.unwrap();
            let mut got = 0;
            while got < 20_000 {
                match tokio::time::timeout(Duration::from_secs(20), channel.recv())
                    .await
                    .expect("echo after idle")
                {
                    Some(ChannelEvent::Data(bytes)) => got += bytes.len(),
                    other => panic!("unexpected {other:?}"),
                }
            }
        }
        if mac_watch.has_changed().unwrap_or(false) {
            changes.push(*mac_watch.borrow_and_update());
        }
    }
    let settled = *connected.path.borrow();
    let mac = mac_path.lock().unwrap().as_ref().map(|path| *path.borrow());
    connected.link.close("done");
    TurnRun { phone: settled, changes, mac, binary: server.refused_binary_frames() }
}

/// Phone dial options that trust `turn` and use all of its servers.
fn with_turn(turn: &TestTurn, options: DialOptions) -> DialOptions {
    DialOptions {
        ice_servers: vec![turn.ice.clone()],
        turn_tls_roots: Some(std::sync::Arc::clone(&turn.roots)),
        ..options
    }
}

/// Relay only with a TURN server: WireGuard offers only its relayed address
/// and never sends plain UDP, so the link runs through TURN over UDP (UDP
/// is not blocked, so no TLS connection is ever opened).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_relay_only_uses_turn() {
    let turn = TestTurn::start().await;
    let phone = with_turn(&turn, DialOptions { relay_only: true, ..options() });
    let run = exercise_turn(phone, options()).await;
    assert_eq!(run.phone, LinkPath::Turn, "{run:?}");
    assert_eq!(run.mac, Some(LinkPath::Turn), "{run:?}");
    assert!(run.changes.is_empty(), "path flapped: {run:?}");
    assert_eq!(turn.stream_connections(), 0, "a TLS connection was opened with UDP working");
    assert_eq!(run.binary, 0);
}

/// The phone's network blocks UDP: no plain UDP, no TURN over UDP. The
/// link runs through the phone's TURN allocation over TLS, both directions,
/// and both sides label it TURN over TLS.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_with_udp_blocked_rides_turn_over_tls() {
    let turn = TestTurn::start().await;
    let phone = with_turn(&turn, DialOptions { block_udp: true, ..options() });
    let run = exercise_turn(phone, options()).await;
    assert_eq!(run.phone, LinkPath::TurnTls, "{run:?}");
    assert_eq!(run.mac, Some(LinkPath::TurnTls), "{run:?}");
    assert!(run.changes.is_empty(), "path flapped: {run:?}");
    assert_eq!(turn.stream_connections(), 1);
    assert_eq!(run.binary, 0);
}

/// The fallback order: TURN over UDP is tried first; when it gets no
/// allocation (UDP to the TURN server is dropped), TLS takes over.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_falls_back_from_turn_udp_to_turn_tls() {
    let turn = TestTurn::start().await;
    turn.set_udp_blocked(true);
    let phone = with_turn(&turn, DialOptions { relay_only: true, ..options() });
    let started = std::time::Instant::now();
    let run = exercise_turn(phone, options()).await;
    assert_eq!(run.phone, LinkPath::TurnTls, "{run:?}");
    assert_eq!(turn.stream_connections(), 1);
    eprintln!("UDP-blocked fallback run took {:?}", started.elapsed());
}

/// The Mac's network blocks UDP (STUN never answers, here simulated by
/// `block_udp`): the Mac takes its own TURN allocation over TLS and lists it
/// in `wg-resp`; the phone reaches it with plain UDP.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_mac_with_udp_blocked_takes_its_own_turn_over_tls() {
    let turn = TestTurn::start().await;
    let mac = with_turn(&turn, DialOptions { block_udp: true, ..options() });
    let run = exercise_turn(options(), mac).await;
    assert_eq!(run.mac, Some(LinkPath::TurnTls), "{run:?}");
    assert_eq!(run.phone, LinkPath::TurnTls, "{run:?}");
    assert_eq!(turn.stream_connections(), 1);
}

/// Without any TURN server, relay only and UDP blocked have no path: the
/// dial fails at once instead of waiting for the backend relay that is gone.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_without_turn_and_without_udp_fails_fast() {
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let mac_id = uuid::Uuid::new_v4().to_string();
    let _mac_task = spawn_echo_mac(
        SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap(),
    );
    let phone =
        SignalingClient::connect(&server.base_url, "user:alice", "team", &uuid::Uuid::new_v4().to_string())
            .await
            .unwrap();
    for options in
        [DialOptions { relay_only: true, ..options() }, DialOptions { block_udp: true, ..options() }]
    {
        let started = std::time::Instant::now();
        let error = dial::connect(&phone, &mac_id, TransportKind::WireGuard, &options, LinkConfig::default())
            .await
            .err()
            .expect("no path");
        assert!(
            matches!(error, cnx_link::DialError::Transport(ref message) if message.contains("TURN")),
            "{error}"
        );
        assert!(started.elapsed() < Duration::from_secs(1));
    }
}

/// The Mac's OS refuses UDP to the phone's LAN address (macOS Local Network
/// privacy) but reaches the internet, where the phone's TURN allocation is.
/// The Mac must stop answering the LAN address it cannot send to and settle
/// on the relayed address, so the path stops flapping.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_one_way_lan_settles_on_turn() {
    let turn = TestTurn::start().await;
    let phone = DialOptions { ice_servers: vec![turn.udp_only()], ..options() };
    let mac = DialOptions { refuse_udp_to: Some(|addr| addr.port() < TEST_RELAY_PORTS_START), ..options() };
    let run = exercise_turn(phone, mac).await;
    assert_eq!(run.phone, LinkPath::Turn, "{run:?}");
    assert!(run.changes.is_empty(), "path flapped: {run:?}");
}

/// One side's UDP to the LAN is silently lost while its UDP to the internet
/// works (the mini's sshd-launched hostd could not route to the LAN; the
/// retired relay used to carry this). The Mac receives the phone's LAN
/// datagrams, so that route looks fine from its side; the phone's `reach`
/// names the route that actually arrives (plain UDP to the phone's TURN
/// relayed address), and the Mac sends there.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_survives_one_way_udp_through_the_peers_turn() {
    let turn = TestTurn::start().await;
    let phone = DialOptions { ice_servers: vec![turn.udp_only()], ..options() };
    let mac = DialOptions { drop_udp_to: Some(|addr| addr.port() < TEST_RELAY_PORTS_START), ..options() };
    // Busy, then idle past a keepalive interval (only keepalives, each
    // answered by one `reach`), then busy again: the Mac stays on the route
    // the phone confirmed.
    let run = exercise_turn_idle(phone, mac, Duration::from_secs(2), Duration::from_secs(13)).await;
    assert_eq!(run.mac, Some(LinkPath::Turn), "{run:?}");
    assert!(run.changes.is_empty(), "path flapped: {run:?}");
}

/// While set, the Mac's plain UDP to anything but TURN relayed addresses is
/// lost (`wireguard_upgrades_from_the_peers_turn_once_direct_works`).
static MAC_LAN_DOWN: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// The phone first hears the Mac through the phone's TURN allocation (the
/// Mac's LAN UDP is lost at first), so the phone's `reach` moves the Mac to
/// the phone's relayed address. Once the LAN works both ways the Mac's
/// upgrade spray reaches the phone directly and the path ends direct.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_upgrades_from_the_peers_turn_once_direct_works() {
    use std::sync::atomic::Ordering;
    // `RUST_LOG=cnx_link=debug` shows the routes and `reach` decisions.
    let _ = tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .with_test_writer()
        .try_init();
    let turn = TestTurn::start().await;
    MAC_LAN_DOWN.store(true, Ordering::Relaxed);
    let phone = DialOptions { ice_servers: vec![turn.udp_only()], ..options() };
    let mac = DialOptions {
        drop_udp_to: Some(|addr| {
            MAC_LAN_DOWN.load(Ordering::Relaxed) && addr.port() < TEST_RELAY_PORTS_START
        }),
        ..options()
    };
    let lan_back = tokio::spawn(async {
        tokio::time::sleep(Duration::from_secs(2)).await;
        MAC_LAN_DOWN.store(false, Ordering::Relaxed);
    });
    let run = exercise_turn_for(phone, mac, Duration::from_secs(12)).await;
    lan_back.await.unwrap();
    assert_eq!(run.mac, Some(LinkPath::Direct), "{run:?}");
    assert_eq!(run.phone, LinkPath::Direct, "{run:?}");
}

/// An older peer's relay frames get one `relay_retired` error per session
/// (naming it, so the peer's other dials go on), and the socket stays up.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_backend_refuses_relay_frames_and_keeps_the_socket() {
    use futures_util::{SinkExt, StreamExt};
    use tokio_tungstenite::tungstenite::Message;
    use tokio_tungstenite::tungstenite::client::IntoClientRequest;
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let device = uuid::Uuid::new_v4().to_string();
    let url = cnx_link::signaling::signal_url(&server.base_url, "team", &device).unwrap();
    let mut request = url.into_client_request().unwrap();
    request.headers_mut().insert("authorization", "Bearer user:alice".parse().unwrap());
    let (mut socket, _) = tokio_tungstenite::connect_async(request).await.unwrap();
    let session = uuid::Uuid::new_v4();
    for _ in 0..3 {
        let mut frame = session.as_bytes().to_vec();
        frame.extend_from_slice(uuid::Uuid::new_v4().as_bytes());
        frame.extend_from_slice(&[4; 64]);
        socket.send(Message::Binary(frame.into())).await.unwrap();
    }
    let mut errors = Vec::new();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(1);
    while let Ok(Some(Ok(message))) = tokio::time::timeout_at(deadline, socket.next()).await {
        if let Message::Text(text) = message {
            let value: serde_json::Value = serde_json::from_str(&text).unwrap();
            if value["type"] == "error" {
                errors.push(value);
            }
        }
    }
    assert_eq!(errors.len(), 1, "{errors:?}");
    assert_eq!(errors[0]["code"], "relay_retired");
    assert_eq!(errors[0]["sessionId"], session.to_string());
    assert_eq!(server.refused_binary_frames(), 3);
    // Still open: a ping is answered.
    socket.send(Message::Ping(Vec::new().into())).await.unwrap();
    let pong = tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            if let Some(Ok(Message::Pong(_))) = socket.next().await {
                return;
            }
        }
    })
    .await;
    assert!(pong.is_ok(), "the socket closed after relay frames");
}

/// The input lane (PROTOCOL.md "Lanes"): with a Mac that supports it, an
/// input channel rides its own stream; with an older Mac (no `lanes` in its
/// answer) it rides the main stream and still works.
async fn input_lane(kind: TransportKind, mac_supports_lane: bool) {
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let phone_id = uuid::Uuid::new_v4().to_string();
    let mac_id = uuid::Uuid::new_v4().to_string();
    let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
    let _mac_task = spawn_echo_mac_with(mac, DialOptions { input_lane: mac_supports_lane, ..options() });
    let phone = SignalingClient::connect(&server.base_url, "user:alice", "team", &phone_id).await.unwrap();
    let connected =
        dial::connect(&phone, &mac_id, kind, &options(), LinkConfig::default()).await.expect("dial");
    let mut input = connected.link.open_on("echo", serde_json::json!({}), Lane::Input).await.unwrap();
    assert_eq!(input.lane(), Lane::Input);
    assert_eq!(input.sender.on_input_stream(), mac_supports_lane, "{kind:?}");
    let expected = if mac_supports_lane { LaneState::Ready } else { LaneState::Unavailable };
    assert_eq!(connected.link.input_lane(), expected);
    // Bulk and input channels side by side.
    let mut bulk = connected.link.open("echo", serde_json::json!({})).await.unwrap();
    bulk.send(Bytes::from(vec![9u8; 300_000])).await.unwrap();
    input.send(Bytes::from_static(b"key")).await.unwrap();
    match tokio::time::timeout(Duration::from_secs(10), input.recv()).await.expect("echo in time") {
        Some(ChannelEvent::Data(bytes)) => assert_eq!(&bytes[..], b"key"),
        other => panic!("unexpected {other:?}"),
    }
    let mut echoed = 0;
    while echoed < 300_000 {
        match tokio::time::timeout(Duration::from_secs(20), bulk.recv()).await.expect("bulk echo") {
            Some(ChannelEvent::Data(bytes)) => echoed += bytes.len(),
            other => panic!("unexpected {other:?}"),
        }
    }
    connected.link.close("done");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn webrtc_input_lane_has_its_own_data_channel() {
    input_lane(TransportKind::WebRtc, true).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_input_lane_has_its_own_tcp_stream() {
    input_lane(TransportKind::WireGuard, true).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn webrtc_input_lane_falls_back_with_an_older_mac() {
    input_lane(TransportKind::WebRtc, false).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_input_lane_falls_back_with_an_older_mac() {
    input_lane(TransportKind::WireGuard, false).await;
}

/// Throughput probe (run with --ignored --nocapture).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore]
async fn throughput_probe() {
    for kind in [TransportKind::WebRtc, TransportKind::WireGuard] {
        let server = FakeSignaling::start(FakeOptions::default()).await;
        let phone_id = uuid::Uuid::new_v4().to_string();
        let mac_id = uuid::Uuid::new_v4().to_string();
        let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
        let _mac_task = spawn_echo_mac(mac);
        let phone =
            SignalingClient::connect(&server.base_url, "user:alice", "team", &phone_id).await.unwrap();
        let connected =
            dial::connect(&phone, &mac_id, kind, &options(), LinkConfig::default()).await.expect("dial");
        let channel = connected.link.open("echo", serde_json::json!({})).await.unwrap();
        let (sender, mut receiver) = channel.split();
        let total = 20_000_000usize;
        let started = std::time::Instant::now();
        let writer = tokio::spawn(async move {
            let mut sent = 0;
            while sent < total {
                sender.send(Bytes::from(vec![1u8; 256 * 1024])).await.unwrap();
                sent += 256 * 1024;
            }
            sender
        });
        let mut got = 0;
        while got < total {
            if let Some(ChannelEvent::Data(b)) = receiver.recv().await {
                got += b.len();
            }
        }
        let secs = started.elapsed().as_secs_f64();
        eprintln!("{kind:?}: {:.1} Mbit/s each way", got as f64 * 8.0 / 1e6 / secs);
        drop(writer.await);
        connected.link.close("done");
    }
}

/// Like the backend (team-hub.ts), the fake keeps one socket per device: a
/// second socket for the same device closes the first with 4000 "replaced",
/// so a client can tell its warm socket is gone.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_second_socket_for_a_device_replaces_the_first() {
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let device = uuid::Uuid::new_v4().to_string();
    let first = SignalingClient::connect(&server.base_url, "user:alice", "team", &device).await.unwrap();
    let mut events = first.events();
    let _second = SignalingClient::connect(&server.base_url, "user:alice", "team", &device).await.unwrap();
    let reason = tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            if let Ok(cnx_link::signaling::SignalingEvent::Disconnected(reason)) = events.recv().await {
                return reason;
            }
        }
    })
    .await
    .expect("the first socket closes");
    assert!(reason.contains("4000") && reason.contains("replaced"), "{reason}");
    assert!(first.closed_reason().is_some());
}

/// A socket the backend closed takes its writer down with it: nothing more
/// is queued on it (the writer task, and with it the socket's write half,
/// would otherwise live on after every server-side close).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_socket_the_backend_closed_refuses_to_queue() {
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let device = uuid::Uuid::new_v4().to_string();
    let client = SignalingClient::connect(&server.base_url, "user:alice", "team", &device).await.unwrap();
    let mut events = client.events();
    server.kick(&device);
    tokio::time::timeout(Duration::from_secs(5), async {
        while !matches!(events.recv().await, Ok(cnx_link::signaling::SignalingEvent::Disconnected(_))) {}
    })
    .await
    .expect("the socket closes");
    let bye = cnx_link::signaling::SignalPayload::Bye { reason: "late".into() };
    assert!(client.send_signal("mac", "session", bye).is_err(), "a closed socket still queues signals");
}

/// termfix r13 D2b (T-LIFE-12): an offer sent while the Mac's host was down
/// or restarting is never answered. The dial gives up at its answer deadline,
/// not at the whole dial's timeout (25 s in the app: the link came back 26.7 s
/// after a cnx-hostd kill), so the next dial reaches the restarted host.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn webrtc_dial_gives_up_on_an_unanswered_offer_at_its_answer_deadline() {
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let phone_id = uuid::Uuid::new_v4().to_string();
    let mac_id = uuid::Uuid::new_v4().to_string();
    // The Mac is on signaling but never answers (its host is gone).
    let _mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
    let phone = SignalingClient::connect(&server.base_url, "user:alice", "team", &phone_id).await.unwrap();
    let dial_options =
        DialOptions { timeout: Duration::from_secs(20), answer_timeout: Duration::from_secs(1), ..options() };
    let started = std::time::Instant::now();
    let result =
        dial::connect(&phone, &mac_id, TransportKind::WebRtc, &dial_options, LinkConfig::default()).await;
    let waited = started.elapsed();
    assert!(matches!(result, Err(dial::DialError::Timeout)), "expected a timeout, got {:?}", result.err());
    assert!(waited < Duration::from_secs(4), "gave up after {waited:?}");
}

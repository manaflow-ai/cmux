//! WireGuard roaming: the phone's network changes in the middle of a
//! stream (its socket stops working and, with a roam, a new one takes
//! over). The stream must go on with no data lost and no stall a user
//! would notice.

use std::time::{Duration, Instant};

use bytes::Bytes;
use cnx_link::dial::{self, SessionEvents, wireguard};
use cnx_link::testing::{FakeOptions, FakeSignaling};
use cnx_link::{ChannelEvent, DialOptions, LinkConfig, LinkPath, SignalingClient, TransportKind};

fn options() -> DialOptions {
    DialOptions { include_loopback: true, timeout: Duration::from_secs(20), ..DialOptions::default() }
}

/// Bytes `[start, start + len)` of the endless test pattern.
fn pattern(start: usize, len: usize) -> Vec<u8> {
    (start..start + len).map(|i| (i % 251) as u8).collect()
}

/// Relayed ports of the test TURN server.
const TURN_RELAY_PORTS: std::ops::RangeInclusive<u16> = 50_300..=50_399;

struct TurnAuth;

impl webrtc::turn::auth::AuthHandler for TurnAuth {
    fn auth_handle(
        &self,
        username: &str,
        realm: &str,
        _source: std::net::SocketAddr,
    ) -> Result<Vec<u8>, webrtc::turn::Error> {
        Ok(webrtc::turn::auth::generate_auth_key(username, realm, "secret"))
    }
}

async fn turn_server() -> (webrtc::turn::server::Server, cnx_link::api::IceServer) {
    use std::sync::Arc;
    let socket = Arc::new(tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap());
    let port = socket.local_addr().unwrap().port();
    let server = webrtc::turn::server::Server::new(webrtc::turn::server::config::ServerConfig {
        conn_configs: vec![webrtc::turn::server::config::ConnConfig {
            conn: socket,
            relay_addr_generator: Box::new(webrtc::turn::relay::relay_range::RelayAddressGeneratorRanges {
                relay_address: "127.0.0.1".parse().unwrap(),
                min_port: *TURN_RELAY_PORTS.start(),
                max_port: *TURN_RELAY_PORTS.end(),
                max_retries: 10,
                address: "127.0.0.1".into(),
                net: Arc::new(webrtc::util::vnet::net::Net::new(None)),
            }),
        }],
        realm: "cnx.test".into(),
        auth_handler: Arc::new(TurnAuth),
        channel_bind_timeout: Duration::from_secs(0),
        alloc_close_notify: None,
    })
    .await
    .unwrap();
    let ice = cnx_link::api::IceServer {
        urls: vec![format!("turn:127.0.0.1:{port}?transport=udp")],
        username: Some("cnx".into()),
        credential: Some("secret".into()),
    };
    (server, ice)
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
#[derive(Debug, Clone, Copy)]
enum Change {
    /// Its network goes away; it roams this much later (as the OS reports
    /// the new path), or never.
    Network(Option<Duration>),
    /// The backend drops its signaling socket; it opens a new one and the
    /// session moves there.
    Signaling,
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
    let _ = tokio::time::timeout(
        Duration::from_secs(10),
        path.wait_for(|p| *p != LinkPath::Relay || phone_options.relay_only && p == &LinkPath::Relay),
    )
    .await;
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
/// endpoint announcement (inside the tunnel, over the relay meanwhile) lets
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
    let (_turn, ice) = turn_server().await;
    let phone = DialOptions { relay_only: true, ice_servers: vec![ice], ..options() };
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

/// Relay only (no TURN): the backend drops the phone's signaling socket, as
/// a network change does. The session moves to the new socket and the
/// relay frames lost on the old one are sent again.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_relay_follows_a_new_signaling_socket() {
    let phone = DialOptions { relay_only: true, ..options() };
    let mac = DialOptions { relay_only: true, ..options() };
    let run = stream_across(phone, mac, Change::Signaling, Duration::from_secs(3)).await;
    eprintln!("rehome: {run:?}");
    assert_eq!(run.after, LinkPath::Relay);
    assert!(run.stall < Duration::from_secs(1), "stalled {:?}", run.stall);
}

/// The baseline: the network goes away and nothing roams. The session
/// falls back to the backend relay only once the direct route has been
/// silent for 14 s. Run with `--ignored` to measure.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "takes about 20 s; the before-roaming measurement"]
async fn wireguard_without_roaming_stalls_until_the_relay() {
    let run = stream_across_a_change(options(), options(), None, Duration::from_secs(18)).await;
    eprintln!("no roam: {run:?}");
    assert!(run.stall > Duration::from_secs(5), "stalled only {:?}", run.stall);
}

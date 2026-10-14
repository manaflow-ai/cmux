//! Both dialers carry the same Link through a local fake signaling server.

use std::time::Duration;

use bytes::Bytes;
use cnx_link::dial::{self, SessionEvents};
use cnx_link::testing::{FakeOptions, FakeSignaling};
use cnx_link::{ChannelEvent, DialOptions, LinkConfig, LinkPath, SignalingClient, TransportKind};

fn options() -> DialOptions {
    DialOptions { include_loopback: true, timeout: Duration::from_secs(20), ..DialOptions::default() }
}

/// A Mac that answers every new session and echoes every channel.
fn spawn_echo_mac(mac: SignalingClient) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        while let Some(session) = mac.next_session().await {
            let first = session.first;
            let events = SessionEvents {
                backend: mac.events(),
                session_id: first.session_id.clone(),
                session: session.events,
            };
            let mac = mac.clone();
            tokio::spawn(async move {
                let connected = dial::answer(&mac, first, events, &options(), LinkConfig::default())
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
    (path, server.relayed_frames())
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn webrtc_carries_the_link() {
    let (path, _) = exercise(TransportKind::WebRtc, FakeOptions::default()).await;
    assert_eq!(path, LinkPath::Direct);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_carries_the_link_directly() {
    let (path, _) = exercise(TransportKind::WireGuard, FakeOptions::default()).await;
    assert_eq!(path, LinkPath::Direct);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_falls_back_to_the_relay() {
    let (path, relayed) = exercise(
        TransportKind::WireGuard,
        FakeOptions { strip_wg_endpoints: true, ..FakeOptions::default() },
    )
    .await;
    assert_eq!(path, LinkPath::Relay);
    assert!(relayed > 10, "relayed {relayed} frames");
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

/// One side's outbound UDP is lost (the mini's sshd-launched hostd could not
/// route to the LAN), the other's works. The side that receives UDP must not
/// switch to UDP-only replies it cannot deliver; the link stays up on the
/// relay.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_survives_one_way_udp() {
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let mac_id = uuid::Uuid::new_v4().to_string();
    let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
    tokio::spawn(async move {
        while let Some(session) = mac.next_session().await {
            let events = SessionEvents {
                backend: mac.events(),
                session_id: session.first.session_id.clone(),
                session: session.events,
            };
            let mac = mac.clone();
            tokio::spawn(async move {
                let options = DialOptions { drop_outbound_udp: true, ..options() };
                let connected =
                    dial::answer(&mac, session.first, events, &options, LinkConfig::default()).await.unwrap();
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
        dial::connect(&phone, &mac_id, TransportKind::WireGuard, &options(), LinkConfig::default())
            .await
            .expect("dial over the relay");
    let mut channel = connected.link.open("echo", serde_json::json!({})).await.unwrap();
    channel.send(Bytes::from(vec![5u8; 100_000])).await.unwrap();
    let mut got = 0;
    while got < 100_000 {
        match tokio::time::timeout(Duration::from_secs(20), channel.recv()).await.expect("echo in time") {
            Some(ChannelEvent::Data(bytes)) => got += bytes.len(),
            other => panic!("unexpected {other:?}"),
        }
    }
    assert_eq!(*connected.path.borrow(), LinkPath::Relay);
}

/// Relayed ports of the test TURN server; anything else stands for the LAN.
const TURN_RELAY_PORTS: std::ops::RangeInclusive<u16> = 50_200..=50_299;

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

/// A TURN server on loopback, as `/v1/ice` would list it.
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
        urls: vec![
            format!("turns:127.0.0.1:{port}?transport=tcp"),
            format!("turn:127.0.0.1:{port}?transport=udp"),
        ],
        username: Some("cnx".into()),
        credential: Some("secret".into()),
    };
    (server, ice)
}

/// Dial a Mac that answers with `mac_options`, echo 200 KB, and return the
/// phone's path plus every path change seen while traffic kept flowing.
async fn exercise_turn(phone_options: DialOptions, mac_options: DialOptions) -> (LinkPath, Vec<LinkPath>) {
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let mac_id = uuid::Uuid::new_v4().to_string();
    let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
    tokio::spawn(async move {
        while let Some(session) = mac.next_session().await {
            let events = SessionEvents {
                backend: mac.events(),
                session_id: session.first.session_id.clone(),
                session: session.events,
            };
            let (mac, options) = (mac.clone(), mac_options.clone());
            tokio::spawn(async move {
                let connected =
                    dial::answer(&mac, session.first, events, &options, LinkConfig::default()).await.unwrap();
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
    connected.link.close("done");
    (settled, changes)
}

/// Relay only with a TURN server: WireGuard offers only its relayed address
/// and never sends plain UDP, so the link runs through TURN (not the
/// backend relay frames).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_relay_only_uses_turn() {
    let (_turn, ice) = turn_server().await;
    let phone = DialOptions { relay_only: true, ice_servers: vec![ice], ..options() };
    let (path, changes) = exercise_turn(phone, options()).await;
    assert_eq!(path, LinkPath::Turn);
    assert!(changes.is_empty(), "path flapped: {changes:?}");
}

/// The Mac's OS refuses UDP to the phone's LAN address (macOS Local Network
/// privacy) but reaches the internet, where the phone's TURN allocation is.
/// The Mac must stop answering the LAN address it cannot send to and settle
/// on the relayed address, so both directions leave the backend relay and
/// the path stops flapping.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_one_way_lan_settles_on_turn() {
    let (_turn, ice) = turn_server().await;
    let phone = DialOptions { ice_servers: vec![ice], ..options() };
    let mac =
        DialOptions { refuse_udp_to: Some(|addr| !TURN_RELAY_PORTS.contains(&addr.port())), ..options() };
    let (path, changes) = exercise_turn(phone, mac).await;
    assert_eq!(path, LinkPath::Turn);
    assert!(changes.is_empty(), "path flapped: {changes:?}");
}

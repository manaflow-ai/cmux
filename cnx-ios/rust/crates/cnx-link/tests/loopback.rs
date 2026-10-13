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
            let events = SessionEvents { session: session.events, backend: mac.events() };
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

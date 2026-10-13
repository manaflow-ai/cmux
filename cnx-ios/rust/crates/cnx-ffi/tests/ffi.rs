//! The exported API end to end against a fake backend and an echo Mac.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use cnx_ffi::{ChannelMessage, ConnectRequest, LinkEvent, LinkObserver, LinkPath, Transport, connect_inner};
use cnx_link::dial::{self, SessionEvents};
use cnx_link::testing::{FakeOptions, FakeSignaling};
use cnx_link::{ChannelEvent, DialOptions, LinkConfig, SignalingClient};

#[derive(Default)]
struct Recorder(Mutex<Vec<LinkEvent>>);

impl LinkObserver for Recorder {
    fn on_event(&self, event: LinkEvent) {
        self.0.lock().unwrap().push(event);
    }
}

fn spawn_echo_mac(mac: SignalingClient) {
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
                let options = DialOptions { include_loopback: true, ..DialOptions::default() };
                let connected =
                    dial::answer(&mac, first, events, &options, LinkConfig::default()).await.unwrap();
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
}

async fn round_trip(transport: Transport) {
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let mac_id = uuid::Uuid::new_v4().to_string();
    spawn_echo_mac(SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap());
    let recorder = Arc::new(Recorder::default());
    let handle = connect_inner(
        ConnectRequest {
            base_url: server.base_url.clone(),
            token: "user:alice".into(),
            team_id: "team".into(),
            device_id: uuid::Uuid::new_v4().to_string(),
            mac_device_id: mac_id,
            transport,
            include_loopback: true,
            relay_only: false,
        },
        Some(recorder.clone() as Arc<dyn LinkObserver>),
    )
    .await
    .expect("connect");
    assert_eq!(handle.transport(), transport);
    // WireGuard starts on the relay and moves to direct once both sides
    // confirm UDP reaches them.
    for _ in 0..100 {
        if handle.path() == LinkPath::Direct {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert_eq!(handle.path(), LinkPath::Direct);
    let channel = handle.open_channel("echo".into(), String::new()).await.unwrap();
    channel.send(b"hello".to_vec()).await.unwrap();
    assert_eq!(channel.recv().await, ChannelMessage::Data { bytes: b"hello".to_vec() });
    assert!(handle.ping().await.unwrap() < 5000);
    assert!(handle.open_channel("echo".into(), "[1]".into()).await.is_err());
    handle.close();
    match tokio::time::timeout(Duration::from_secs(5), channel.recv()).await.unwrap() {
        ChannelMessage::Closed { code, .. } => assert_eq!(code, "link_closed"),
        other => panic!("unexpected {other:?}"),
    }
    tokio::time::sleep(Duration::from_millis(100)).await;
    let events = recorder.0.lock().unwrap().clone();
    assert_eq!(events.first(), Some(&LinkEvent::Connecting { transport }));
    assert!(
        events.iter().any(|e| matches!(e, LinkEvent::Connected { transport: t, .. } if *t == transport)),
        "{events:?}"
    );
    assert!(
        events.contains(&LinkEvent::Connected { transport, path: LinkPath::Direct })
            || events.contains(&LinkEvent::PathChanged { path: LinkPath::Direct }),
        "{events:?}"
    );
    assert!(events.iter().any(|e| matches!(e, LinkEvent::Rtt { .. })), "{events:?}");
    assert!(matches!(events.last(), Some(LinkEvent::Disconnected { .. })), "{events:?}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn webrtc_round_trip() {
    round_trip(Transport::WebRtc).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn wireguard_round_trip() {
    round_trip(Transport::WireGuard).await;
}

/// Relay only: WireGuard never leaves the backend relay frames.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn wireguard_relay_only_stays_on_the_relay() {
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let mac_id = uuid::Uuid::new_v4().to_string();
    spawn_echo_mac(SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap());
    let recorder = Arc::new(Recorder::default());
    let handle = connect_inner(
        ConnectRequest {
            base_url: server.base_url.clone(),
            token: "user:alice".into(),
            team_id: "team".into(),
            device_id: uuid::Uuid::new_v4().to_string(),
            mac_device_id: mac_id,
            transport: Transport::WireGuard,
            include_loopback: true,
            relay_only: true,
        },
        Some(recorder.clone() as Arc<dyn LinkObserver>),
    )
    .await
    .expect("connect");
    assert_eq!(handle.path(), LinkPath::Relay);
    let channel = handle.open_channel("echo".into(), String::new()).await.unwrap();
    let payload = vec![7u8; 200_000];
    channel.send(payload.clone()).await.unwrap();
    let mut received = Vec::new();
    while received.len() < payload.len() {
        match channel.recv().await {
            ChannelMessage::Data { bytes } => received.extend(bytes),
            other => panic!("unexpected {other:?}"),
        }
    }
    assert_eq!(received, payload);
    // The direct UDP path would have been confirmed well within this.
    tokio::time::sleep(Duration::from_secs(2)).await;
    assert_eq!(handle.path(), LinkPath::Relay);
    let events = recorder.0.lock().unwrap().clone();
    assert!(
        events.contains(&LinkEvent::Connected { transport: Transport::WireGuard, path: LinkPath::Relay }),
        "{events:?}"
    );
    assert!(!events.contains(&LinkEvent::PathChanged { path: LinkPath::Direct }), "{events:?}");
    handle.close();
}

/// Relay only over WebRTC needs TURN; the fake backend offers none, so the
/// dial fails at once instead of waiting for ICE to time out.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn webrtc_relay_only_without_turn_fails_fast() {
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let mac_id = uuid::Uuid::new_v4().to_string();
    spawn_echo_mac(SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap());
    let started = std::time::Instant::now();
    let result = connect_inner(
        ConnectRequest {
            base_url: server.base_url.clone(),
            token: "user:alice".into(),
            team_id: "team".into(),
            device_id: uuid::Uuid::new_v4().to_string(),
            mac_device_id: mac_id,
            transport: Transport::WebRtc,
            include_loopback: true,
            relay_only: true,
        },
        None,
    )
    .await;
    match result {
        Err(cnx_ffi::CnxError::Transport { message }) => assert!(message.contains("TURN"), "{message}"),
        Err(other) => panic!("unexpected error {other:?}"),
        Ok(_) => panic!("relay-only WebRTC connected without TURN"),
    }
    assert!(started.elapsed() < Duration::from_secs(10));
}

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
            let events = SessionEvents { session: session.events, backend: mac.events() };
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

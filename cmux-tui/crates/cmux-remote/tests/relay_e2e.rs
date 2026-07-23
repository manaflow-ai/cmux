use std::time::Duration;

use bytes::Bytes;
use cmux_relay::{Relay, RelayConfig};
use cmux_remote::connection::{ClientConnection, ClientConnectionConfig, ReconnectPolicy};
use cmux_remote::crypto::{ClientAuthMode, StaticIdentity};
use cmux_remote::identity::AuthDatabase;
use cmux_remote::observability::{ConnectionState, TransportPathKind};
use cmux_remote::provider::{
    ConnectRequest, RelayClientConfig, RelayDaemonConfig, RelayProvider, TransportProvider,
    register_relay_daemon,
};
use cmux_remote::session::SessionLimits;
use cmux_remote_protocol::{FrameFlags, Lane, LanePolicy, SessionId};
use tempfile::tempdir;
use url::Url;
use zeroize::Zeroizing;

#[tokio::test]
async fn shared_provider_crosses_native_relay_with_noise_and_parallel_lanes() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let relay = Relay::new(RelayConfig { allow_open: true, ..RelayConfig::default() }).unwrap();
    let (listener, router) = relay.server_parts(listener);
    let relay_task = tokio::spawn(async move {
        axum::serve(listener, router).await.unwrap();
    });

    let state = tempdir().unwrap();
    let auth = AuthDatabase::load_or_create(state.path(), "relay-test", false).unwrap();
    let (daemon, mut accepted) =
        cmux_remote::daemon::RemoteDaemon::new(auth.clone(), SessionLimits::default());
    let endpoint = Url::parse(&format!("relay+ws://{address}")).unwrap();
    let registration = register_relay_daemon(
        daemon,
        RelayDaemonConfig {
            endpoint: endpoint.clone(),
            slot: "slot-test".into(),
            ticket: "open-daemon-ticket".into(),
            maximum_frame_bytes: 65_535,
            control_timeout: Duration::from_secs(5),
        },
    )
    .await
    .unwrap();

    let invitation = auth.create_invitation(Duration::from_secs(60), vec![]).await.unwrap();
    let approver = tokio::spawn({
        let auth = auth.clone();
        async move {
            let pending = auth.wait_for_pending(Duration::from_secs(5)).await.unwrap();
            auth.approve(&pending[0].invitation_id).await.unwrap();
        }
    });
    let provider = RelayProvider::new(RelayClientConfig {
        slot: "slot-test".into(),
        ticket: "open-client-ticket".into(),
        maximum_frame_bytes: 65_535,
        control_timeout: Duration::from_secs(5),
    })
    .unwrap();
    let session = SessionId([42; 16]);
    let group = provider
        .connect(ConnectRequest {
            endpoint,
            session,
            lane_policy: LanePolicy::Auto,
            routing: Default::default(),
        })
        .await
        .unwrap();
    let client_identity = StaticIdentity::generate().unwrap();
    let invitation_secret = invitation.secret_bytes().unwrap();
    let client = ClientConnection::connect(
        group,
        ClientConnectionConfig {
            identity: client_identity,
            expected_daemon: Some(auth.identity().public_key()),
            auth: ClientAuthMode::Invitation {
                id: invitation.id,
                secret: Zeroizing::new(invitation_secret),
            },
            device_name: "relay-client".into(),
            session,
            lane_policy: LanePolicy::Auto,
            limits: SessionLimits::default(),
            reconnect: ReconnectPolicy { maximum_attempts: Some(3), ..ReconnectPolicy::default() },
        },
    )
    .await
    .unwrap();
    approver.await.unwrap();
    let server =
        tokio::time::timeout(Duration::from_secs(5), accepted.recv()).await.unwrap().unwrap();

    let client_snapshot = client.snapshot().await;
    assert_eq!(client_snapshot.state, ConnectionState::Connected);
    assert_eq!(client_snapshot.physical_link_count, 3);
    assert_eq!(client_snapshot.transport.provider, "websocket-relay");
    assert!(client_snapshot.transport.route.starts_with("relay+ws://"));
    assert_eq!(client_snapshot.transport.selected_path.unwrap().kind, TransportPathKind::Relay);
    let server_snapshot = server.snapshot().await;
    assert_eq!(server_snapshot.generation, 0);
    assert_eq!(server_snapshot.physical_link_count, 3);

    client
        .send(Lane::Interactive, 1, Bytes::from_static(b"keystroke"), FrameFlags::empty())
        .await
        .unwrap();
    assert_eq!(server.receive().await.unwrap().unwrap().payload, b"keystroke".as_slice());
    server.send(Lane::Bulk, 2, Bytes::from_static(b"diff"), FrameFlags::empty()).await.unwrap();
    assert_eq!(client.receive().await.unwrap().unwrap().payload, b"diff".as_slice());

    client.close().await.unwrap();
    registration.shutdown().await;
    relay_task.abort();
}

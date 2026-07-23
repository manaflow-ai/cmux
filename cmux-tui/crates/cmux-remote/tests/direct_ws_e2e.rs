use std::time::Duration;

use bytes::Bytes;
use cmux_remote::connection::{ClientConnection, ClientConnectionConfig, ReconnectPolicy};
use cmux_remote::crypto::{ClientAuthMode, StaticIdentity};
use cmux_remote::daemon::{RemoteDaemon, serve_direct_websocket};
use cmux_remote::identity::AuthDatabase;
use cmux_remote::observability::{ConnectionState, TransportPathKind};
use cmux_remote::provider::{ConnectRequest, DirectWebSocketProvider, TransportProvider};
use cmux_remote::session::SessionLimits;
use cmux_remote_protocol::{FrameFlags, Lane, LanePolicy, SessionId};
use tempfile::tempdir;
use url::Url;
use zeroize::Zeroizing;

#[tokio::test]
async fn invitation_enrolls_over_direct_websocket_with_isolated_lanes() {
    let state = tempdir().unwrap();
    let auth = AuthDatabase::load_or_create(state.path(), "websocket-test", false).unwrap();
    let (daemon, mut accepted) = RemoteDaemon::new(auth.clone(), SessionLimits::default());
    let server = serve_direct_websocket(daemon, "127.0.0.1:0".parse().unwrap(), 65_535, false)
        .await
        .unwrap();
    let endpoint = Url::parse(&format!("ws://{}/v1/link", server.local_addr())).unwrap();
    let invitation = auth.create_invitation(Duration::from_secs(60), vec![]).await.unwrap();
    let approver = tokio::spawn({
        let auth = auth.clone();
        async move {
            let pending = auth.wait_for_pending(Duration::from_secs(5)).await.unwrap();
            auth.approve(&pending[0].invitation_id).await.unwrap();
        }
    });
    let session = SessionId([73; 16]);
    let group = DirectWebSocketProvider::new(65_535)
        .connect(ConnectRequest {
            endpoint,
            session,
            lane_policy: LanePolicy::Isolated,
            routing: Default::default(),
        })
        .await
        .unwrap();
    let invitation_secret = invitation.secret_bytes().unwrap();
    let client = ClientConnection::connect(
        group,
        ClientConnectionConfig {
            identity: StaticIdentity::generate().unwrap(),
            expected_daemon: Some(auth.identity().public_key()),
            auth: ClientAuthMode::Invitation {
                id: invitation.id,
                secret: Zeroizing::new(invitation_secret),
            },
            device_name: "websocket-client".into(),
            session,
            lane_policy: LanePolicy::Isolated,
            limits: SessionLimits::default(),
            reconnect: ReconnectPolicy::default(),
        },
    )
    .await
    .unwrap();
    approver.await.unwrap();
    let daemon_client =
        tokio::time::timeout(Duration::from_secs(5), accepted.recv()).await.unwrap().unwrap();

    let client_snapshot = client.snapshot().await;
    assert_eq!(client_snapshot.state, ConnectionState::Connected);
    assert_eq!(client_snapshot.physical_link_count, 4);
    assert_eq!(client_snapshot.transport.provider, "direct-websocket");
    assert_eq!(client_snapshot.transport.selected_path.unwrap().kind, TransportPathKind::Direct);
    assert_eq!(daemon_client.snapshot().await.physical_link_count, 4);

    client
        .send(Lane::Interactive, 1, Bytes::from_static(b"input"), FrameFlags::empty())
        .await
        .unwrap();
    assert_eq!(daemon_client.receive().await.unwrap().unwrap().payload, b"input".as_slice());
    daemon_client
        .send(Lane::Bulk, 2, Bytes::from_static(b"screen"), FrameFlags::empty())
        .await
        .unwrap();
    assert_eq!(client.receive().await.unwrap().unwrap().payload, b"screen".as_slice());

    client.close().await.unwrap();
    server.shutdown().await.unwrap();
}

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
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::{HeaderValue, StatusCode, header::ORIGIN};
use url::Url;
use zeroize::Zeroizing;

const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);

#[tokio::test]
async fn browser_origin_is_rejected_by_direct_websocket_listener() {
    let state = tempdir().unwrap();
    let auth = AuthDatabase::load_or_create(state.path(), "websocket-origin-test", false).unwrap();
    let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());
    let server = serve_direct_websocket(daemon, "127.0.0.1:0".parse().unwrap(), 65_535, false)
        .await
        .unwrap();
    let mut request =
        format!("ws://{}/v1/link", server.local_addr()).into_client_request().unwrap();
    request.headers_mut().insert(ORIGIN, HeaderValue::from_static("https://attacker.invalid"));

    let error = tokio::time::timeout(CONNECT_TIMEOUT, connect_async(request))
        .await
        .expect("browser-origin WebSocket rejection timed out")
        .expect_err("browser-origin WebSocket was upgraded");
    let tokio_tungstenite::tungstenite::Error::Http(response) = error else {
        panic!("browser-origin rejection was not an HTTP response");
    };
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
    assert!(response.body().as_ref().is_none_or(Vec::is_empty));

    let native = tokio::time::timeout(
        CONNECT_TIMEOUT,
        connect_async(format!("ws://{}/v1/link", server.local_addr())),
    )
    .await
    .expect("native WebSocket connection timed out")
    .expect("rejected browser origin retained WebSocket capacity")
    .0;
    drop(native);
    server.shutdown().await.unwrap();
}

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

/// A cmux Cloud machine's listener is reachable only from the owner's private
/// network, so it grants carrier authentication to every link: the client
/// dials with no enrollment and no invitation. The same dial against a
/// listener that is not trusted is refused, so the client flag alone weakens
/// nothing.
#[tokio::test]
async fn carrier_dial_is_accepted_only_by_a_trusted_listener() {
    use cmux_remote::daemon::{DirectWebSocketOptions, serve_direct_websocket_with_options};

    let state = tempdir().unwrap();
    let auth = AuthDatabase::load_or_create(state.path(), "trusted-listener-test", false).unwrap();
    let (daemon, mut accepted) = RemoteDaemon::new(auth.clone(), SessionLimits::default());
    let trusted = serve_direct_websocket_with_options(
        daemon.clone(),
        "127.0.0.1:0".parse().unwrap(),
        65_535,
        DirectWebSocketOptions { allow_insecure_non_loopback: false, trusted_carrier: true },
    )
    .await
    .unwrap();
    let untrusted = serve_direct_websocket(daemon, "127.0.0.1:0".parse().unwrap(), 65_535, false)
        .await
        .unwrap();
    let provider = DirectWebSocketProvider::new(65_535).with_carrier_auth(true);
    let dial = |server: &cmux_remote::daemon::DirectWebSocketServer,
                session: SessionId,
                reconnect: ReconnectPolicy| {
        let endpoint = Url::parse(&format!("ws://{}/v1/link", server.local_addr())).unwrap();
        let provider = provider.clone();
        async move {
            let group = provider
                .connect(ConnectRequest {
                    endpoint,
                    session,
                    lane_policy: LanePolicy::Isolated,
                    routing: Default::default(),
                })
                .await
                .unwrap();
            ClientConnection::connect(
                group,
                ClientConnectionConfig {
                    identity: StaticIdentity::generate().unwrap(),
                    expected_daemon: None,
                    auth: ClientAuthMode::Carrier,
                    device_name: "carrier-client".into(),
                    session,
                    lane_policy: LanePolicy::Isolated,
                    limits: SessionLimits::default(),
                    reconnect,
                },
            )
            .await
        }
    };

    let client = tokio::time::timeout(
        CONNECT_TIMEOUT,
        dial(&trusted, SessionId([81; 16]), ReconnectPolicy::default()),
    )
    .await
    .expect("trusted carrier dial timed out")
    .expect("trusted listener refused a carrier dial");
    let daemon_client =
        tokio::time::timeout(Duration::from_secs(5), accepted.recv()).await.unwrap().unwrap();
    assert_eq!(client.snapshot().await.state, ConnectionState::Connected);
    assert!(auth.pending_enrollments().await.is_empty(), "carrier dial left a pending enrollment");
    client
        .send(Lane::Interactive, 1, Bytes::from_static(b"input"), FrameFlags::empty())
        .await
        .unwrap();
    assert_eq!(daemon_client.receive().await.unwrap().unwrap().payload, b"input".as_slice());
    client.close().await.unwrap();

    // One attempt is enough to observe the refusal; a retry budget would only
    // repeat the same rejected handshake.
    tokio::time::timeout(
        CONNECT_TIMEOUT,
        dial(
            &untrusted,
            SessionId([82; 16]),
            ReconnectPolicy { maximum_attempts: Some(1), ..Default::default() },
        ),
    )
    .await
    .expect("untrusted carrier dial timed out")
    .expect_err("untrusted listener accepted a carrier dial");

    trusted.shutdown().await.unwrap();
    untrusted.shutdown().await.unwrap();
}

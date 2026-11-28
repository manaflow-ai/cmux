//! A direct WebSocket link dialed through an in-process WireGuard tunnel.
//!
//! The daemon listens on a loopback TCP port as it always does. The "network"
//! side of the tunnel accepts the tunneled TCP connection on its userspace stack
//! and bridges it to that daemon, which is exactly what a Cloud VM's private
//! address does from the client's point of view: the route names an address
//! only the tunnel can reach.

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use bytes::Bytes;
use cmux_remote::connection::{ClientConnection, ClientConnectionConfig, ReconnectPolicy};
use cmux_remote::crypto::{ClientAuthMode, StaticIdentity};
use cmux_remote::daemon::{RemoteDaemon, serve_direct_websocket};
use cmux_remote::identity::AuthDatabase;
use cmux_remote::observability::{ConnectionState, TransportPathKind};
use cmux_remote::provider::{
    ConnectRequest, DirectWebSocketProvider, TransportProvider, WireGuardDialer,
};
use cmux_remote::session::SessionLimits;
use cmux_remote_protocol::{FrameFlags, Lane, LanePolicy, SessionId};
use cmux_wg::WgNet;
use cmux_wg::testing::{LoopbackPair, loopback_pair};
use tempfile::tempdir;
use tokio::net::TcpStream;
use url::Url;
use zeroize::Zeroizing;

const TIMEOUT: Duration = Duration::from_secs(10);

/// Accept tunneled connections on `port` and pipe each to `daemon`.
async fn bridge_to_daemon(net: &WgNet, port: u16, daemon: SocketAddr) {
    let mut listener = net.listen(port).await.unwrap();
    tokio::spawn(async move {
        while let Some(mut tunneled) = listener.accept().await {
            tokio::spawn(async move {
                let Ok(mut local) = TcpStream::connect(daemon).await else { return };
                let _ = tokio::io::copy_bidirectional(&mut tunneled, &mut local).await;
            });
        }
    });
}

#[tokio::test]
async fn invitation_enrolls_over_a_wireguard_dialed_websocket() {
    let state = tempdir().unwrap();
    let auth = AuthDatabase::load_or_create(state.path(), "wireguard-test", false).unwrap();
    let (daemon, mut accepted) = RemoteDaemon::new(auth.clone(), SessionLimits::default());
    let server = serve_direct_websocket(daemon, "127.0.0.1:0".parse().unwrap(), 65_535, false)
        .await
        .unwrap();

    let LoopbackPair { client, server: network, client_socket, server_socket, server_v6, .. } =
        loopback_pair().await.unwrap();
    let network = WgNet::start(network, server_socket).await.unwrap();
    bridge_to_daemon(&network, 1337, server.local_addr()).await;
    let tunnel = Arc::new(WgNet::start(client, client_socket).await.unwrap());

    // The route is the machine's private address: nothing on this host
    // listens there, so only the tunnel can complete the dial.
    let endpoint = Url::parse(&format!("ws://[{server_v6}]:1337/v1/link")).unwrap();
    let invitation = auth.create_invitation(Duration::from_secs(60), vec![]).await.unwrap();
    let approver = tokio::spawn({
        let auth = auth.clone();
        async move {
            let pending = auth.wait_for_pending(Duration::from_secs(5)).await.unwrap();
            auth.approve(&pending[0].invitation_id).await.unwrap();
        }
    });
    let session = SessionId([91; 16]);
    let dialer = Arc::new(WireGuardDialer::new(Arc::clone(&tunnel)));
    let group = DirectWebSocketProvider::with_dialer(65_535, dialer)
        .connect(ConnectRequest {
            endpoint,
            session,
            lane_policy: LanePolicy::Isolated,
            routing: Default::default(),
        })
        .await
        .unwrap();
    let invitation_secret = invitation.secret_bytes().unwrap();
    let client = tokio::time::timeout(
        TIMEOUT,
        ClientConnection::connect(
            group,
            ClientConnectionConfig {
                identity: StaticIdentity::generate().unwrap(),
                expected_daemon: Some(auth.identity().public_key()),
                auth: ClientAuthMode::Invitation {
                    id: invitation.id,
                    secret: Zeroizing::new(invitation_secret),
                },
                device_name: "wireguard-client".into(),
                session,
                lane_policy: LanePolicy::Isolated,
                limits: SessionLimits::default(),
                reconnect: ReconnectPolicy::default(),
            },
        ),
    )
    .await
    .expect("connect through the tunnel timed out")
    .unwrap();
    approver.await.unwrap();
    let daemon_client = tokio::time::timeout(TIMEOUT, accepted.recv()).await.unwrap().unwrap();

    let snapshot = client.snapshot().await;
    assert_eq!(snapshot.state, ConnectionState::Connected);
    assert_eq!(snapshot.physical_link_count, 4, "four lanes, four tunneled TCP connections");
    assert_eq!(snapshot.transport.provider, "direct-websocket");
    assert_eq!(snapshot.transport.selected_path.unwrap().kind, TransportPathKind::Direct);

    client
        .send(Lane::Interactive, 1, Bytes::from_static(b"keys"), FrameFlags::empty())
        .await
        .unwrap();
    assert_eq!(daemon_client.receive().await.unwrap().unwrap().payload, b"keys".as_slice());
    let screen = vec![0x5a; 16_000];
    daemon_client
        .send(Lane::Bulk, 2, Bytes::from(screen.clone()), FrameFlags::empty())
        .await
        .unwrap();
    assert_eq!(client.receive().await.unwrap().unwrap().payload, screen.as_slice());

    assert!(tunnel.time_since_last_handshake().await.unwrap().is_some());

    client.close().await.unwrap();
    server.shutdown().await.unwrap();
    network.shutdown().await;
}

#[tokio::test]
async fn addresses_outside_the_tunnel_fail_closed() {
    let state = tempdir().unwrap();
    let auth = AuthDatabase::load_or_create(state.path(), "wireguard-fallback", false).unwrap();
    let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());
    let server = serve_direct_websocket(daemon, "127.0.0.1:0".parse().unwrap(), 65_535, false)
        .await
        .unwrap();
    let LoopbackPair { client, client_socket, .. } = loopback_pair().await.unwrap();
    // No peer is running; the tunnel never handshakes. A loopback route must
    // fail before the operating-system TCP stack can reach it.
    let tunnel = Arc::new(WgNet::start(client, client_socket).await.unwrap());
    let dialer = Arc::new(WireGuardDialer::new(tunnel));
    let endpoint = Url::parse(&format!("ws://{}/v1/link", server.local_addr())).unwrap();
    let error = tokio::time::timeout(
        TIMEOUT,
        cmux_remote::provider::connect_websocket_via(&endpoint, 65_535, dialer.as_ref()),
    )
    .await
    .expect("fail-closed dial timed out")
    .unwrap_err();
    assert!(error.to_string().contains("outside the configured WireGuard routes"), "{error}");
    server.shutdown().await.unwrap();
}

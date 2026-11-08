//! `cmux-tui wg hub` logic in-process: a hub owns the tunnel, a SOCKS dialer
//! reaches a daemon through it, and the hub enforces its ruleset.

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use bytes::Bytes;
use cmux_remote::connection::{ClientConnection, ClientConnectionConfig, ReconnectPolicy};
use cmux_remote::crypto::{ClientAuthMode, StaticIdentity};
use cmux_remote::daemon::{RemoteDaemon, serve_direct_websocket};
use cmux_remote::identity::AuthDatabase;
use cmux_remote::observability::ConnectionState;
use cmux_remote::provider::{
    ConnectRequest, DirectWebSocketProvider, SocksDialer, TransportProvider,
};
use cmux_remote::session::SessionLimits;
use cmux_remote::wireguard_hub::serve_wireguard_hub;
use cmux_remote_protocol::{FrameFlags, Lane, LanePolicy, SessionId};
use cmux_wg::WgNet;
use cmux_wg::testing::{LoopbackPair, loopback_pair};
use tempfile::tempdir;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpStream, UnixStream};
use url::Url;
use zeroize::Zeroizing;

const TIMEOUT: Duration = Duration::from_secs(10);

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

/// Raw SOCKS5 CONNECT; returns the reply code.
async fn socks_connect_reply(path: &std::path::Path, request_tail: &[u8]) -> u8 {
    let mut stream = UnixStream::connect(path).await.unwrap();
    stream.write_all(&[0x05, 1, 0x00]).await.unwrap();
    let mut chosen = [0u8; 2];
    stream.read_exact(&mut chosen).await.unwrap();
    assert_eq!(chosen, [0x05, 0x00]);
    let mut request = vec![0x05, 0x01, 0x00];
    request.extend_from_slice(request_tail);
    stream.write_all(&request).await.unwrap();
    let mut head = [0u8; 4];
    tokio::time::timeout(TIMEOUT, stream.read_exact(&mut head)).await.unwrap().unwrap();
    assert_eq!(head[0], 0x05);
    head[1]
}

#[tokio::test]
async fn sidecar_reaches_a_daemon_through_the_hub() {
    let state = tempdir().unwrap();
    let auth = AuthDatabase::load_or_create(state.path(), "hub-test", false).unwrap();
    let (daemon, mut accepted) = RemoteDaemon::new(auth.clone(), SessionLimits::default());
    let server = serve_direct_websocket(daemon, "127.0.0.1:0".parse().unwrap(), 65_535, false)
        .await
        .unwrap();

    let LoopbackPair { client, server: network, client_socket, server_socket, server_v6, .. } =
        loopback_pair().await.unwrap();
    let network = WgNet::start(network, server_socket).await.unwrap();
    bridge_to_daemon(&network, 1337, server.local_addr()).await;
    let tunnel = Arc::new(WgNet::start(client, client_socket).await.unwrap());

    let hub_dir = tempdir().unwrap();
    let socket_path = hub_dir.path().join("hub").join("wg.sock");
    let hub = serve_wireguard_hub(Arc::clone(&tunnel), socket_path.clone()).await.unwrap();
    assert!(socket_path.exists());
    assert_eq!(hub.routes().len(), 2);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(std::fs::metadata(&socket_path).unwrap().permissions().mode() & 0o777, 0o600);
        assert_eq!(
            std::fs::metadata(socket_path.parent().unwrap()).unwrap().permissions().mode() & 0o777,
            0o700
        );
    }

    let endpoint = Url::parse(&format!("ws://[{server_v6}]:1337/v1/link")).unwrap();
    let invitation = auth.create_invitation(Duration::from_secs(60), vec![]).await.unwrap();
    let approver = tokio::spawn({
        let auth = auth.clone();
        async move {
            let pending = auth.wait_for_pending(Duration::from_secs(5)).await.unwrap();
            auth.approve(&pending[0].invitation_id).await.unwrap();
        }
    });
    let session = SessionId([77; 16]);
    let dialer = Arc::new(SocksDialer::new(socket_path.clone()));
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
                device_name: "hub-sidecar".into(),
                session,
                lane_policy: LanePolicy::Isolated,
                limits: SessionLimits::default(),
                reconnect: ReconnectPolicy::default(),
            },
        ),
    )
    .await
    .expect("connect through the hub timed out")
    .unwrap();
    approver.await.unwrap();
    let daemon_client = tokio::time::timeout(TIMEOUT, accepted.recv()).await.unwrap().unwrap();

    let snapshot = client.snapshot().await;
    assert_eq!(snapshot.state, ConnectionState::Connected);
    assert_eq!(snapshot.physical_link_count, 4);
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

    // Ruleset: outside the tunnel's routes -> 0x02.
    let mut outside = vec![0x01, 192, 0, 2, 1];
    outside.extend_from_slice(&80u16.to_be_bytes());
    assert_eq!(socks_connect_reply(&socket_path, &outside).await, 0x02);

    // Names are not dialed -> 0x08 address type not supported.
    let mut domain = vec![0x03, 11];
    domain.extend_from_slice(b"example.com");
    domain.extend_from_slice(&443u16.to_be_bytes());
    assert_eq!(socks_connect_reply(&socket_path, &domain).await, 0x08);

    // Inside the routes but nothing listens -> connection refused.
    let mut refused = vec![0x01, 10, 200, 0, 2];
    refused.extend_from_slice(&4444u16.to_be_bytes());
    assert_eq!(socks_connect_reply(&socket_path, &refused).await, 0x05);

    client.close().await.unwrap();
    hub.shutdown().await.unwrap();
    assert!(!socket_path.exists(), "hub must remove its socket on shutdown");
    server.shutdown().await.unwrap();
    network.shutdown().await;
}

#[tokio::test]
async fn a_hub_dropped_without_shutdown_still_unlinks_its_socket() {
    let LoopbackPair { client, client_socket, .. } = loopback_pair().await.unwrap();
    let tunnel = Arc::new(WgNet::start(client, client_socket).await.unwrap());
    let hub_dir = tempdir().unwrap();
    let socket_path = hub_dir.path().join("wg.sock");
    let hub = serve_wireguard_hub(tunnel, socket_path.clone()).await.unwrap();
    assert!(socket_path.exists());
    drop(hub);
    assert!(!socket_path.exists());
}

#[tokio::test]
async fn a_second_hub_on_a_live_socket_is_refused() {
    let LoopbackPair { client, client_socket, .. } = loopback_pair().await.unwrap();
    let tunnel = Arc::new(WgNet::start(client, client_socket).await.unwrap());
    let hub_dir = tempdir().unwrap();
    let socket_path = hub_dir.path().join("wg.sock");
    let first = serve_wireguard_hub(Arc::clone(&tunnel), socket_path.clone()).await.unwrap();
    let second = serve_wireguard_hub(tunnel, socket_path.clone()).await;
    assert!(second.is_err(), "two hubs must not share one socket path");
    first.shutdown().await.unwrap();
}

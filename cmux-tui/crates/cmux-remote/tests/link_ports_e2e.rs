//! A link's port forwards over its own socket (`PATH.admin`): the app's Forward Port… action for
//! an SSH machine. A real daemon and link, a TCP target on the machine's loopback, and
//! `port-forward`, `port-list` and `port-close` asked the way the app asks them.

use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use cmux_remote::admin::{AdminRequest, call_admin, serve_link_cell_admin_with_ports};
use cmux_remote::connection::{ClientConnection, ClientConnectionConfig, ReconnectPolicy};
use cmux_remote::crypto::{ClientAuthMode, StaticIdentity};
use cmux_remote::daemon::{RemoteDaemon, serve_direct_websocket};
use cmux_remote::first_dial::LinkCell;
use cmux_remote::identity::AuthDatabase;
use cmux_remote::link_ports::{LinkForward, LinkForwardClosed, LinkForwards, LinkPorts};
use cmux_remote::provider::{ConnectRequest, DirectWebSocketProvider, TransportProvider};
use cmux_remote::service::{EndpointRole, ServiceMultiplexer};
use cmux_remote::services::DaemonServices;
use cmux_remote::session::SessionLimits;
use cmux_remote::workspace::WorkspaceService;
use cmux_remote_protocol::{LanePolicy, SessionId};
use serde::de::DeserializeOwned;
use tempfile::tempdir;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};
use url::Url;
use zeroize::Zeroizing;

const MAXIMUM_FRAME_BYTES: usize = 65_535;
const TEST_TIMEOUT: Duration = Duration::from_secs(60);

/// A machine-side service: answers `PING\n` with `PONG\n` on every connection.
async fn start_ping_target() -> (std::net::SocketAddr, tokio::task::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let task = tokio::spawn(async move {
        loop {
            let Ok((socket, _)) = listener.accept().await else { break };
            tokio::spawn(async move {
                let (reader, mut writer) = socket.into_split();
                let mut line = String::new();
                if BufReader::new(reader).read_line(&mut line).await.is_ok() && line == "PING\n" {
                    let _ = writer.write_all(b"PONG\n").await;
                }
                let _ = writer.shutdown().await;
            });
        }
    });
    (address, task)
}

async fn ask<T: DeserializeOwned>(path: &Path, request: AdminRequest) -> T {
    let response = call_admin(path, &request).await.unwrap();
    assert!(response.ok, "{request:?}: {:?}", response.error);
    serde_json::from_value(response.result.unwrap()).unwrap()
}

async fn ping(local_port: u16) -> Vec<u8> {
    let mut socket = TcpStream::connect(("127.0.0.1", local_port)).await.unwrap();
    socket.write_all(b"PING\n").await.unwrap();
    let mut reply = Vec::new();
    socket.read_to_end(&mut reply).await.unwrap();
    reply
}

/// A connected client link to a real daemon, as `remote connect` holds one.
async fn connected_link(
    root: &Path,
) -> (Arc<ClientConnection>, Arc<ServiceMultiplexer>, Vec<Box<dyn std::any::Any>>) {
    let auth = AuthDatabase::load_or_create(root, "link-ports-e2e", false).unwrap();
    let (daemon, mut accepted) = RemoteDaemon::new(auth.clone(), SessionLimits::default());
    let server =
        serve_direct_websocket(daemon, "127.0.0.1:0".parse().unwrap(), MAXIMUM_FRAME_BYTES, false)
            .await
            .unwrap();
    let endpoint = Url::parse(&format!("ws://{}/v1/link", server.local_addr())).unwrap();
    let invitation = auth.create_invitation(Duration::from_secs(60), Vec::new()).await.unwrap();
    let invitation_secret = invitation.secret_bytes().unwrap();
    let approver = tokio::spawn({
        let auth = auth.clone();
        async move {
            let pending = auth.wait_for_pending(Duration::from_secs(5)).await.unwrap();
            auth.approve(&pending[0].invitation_id).await.unwrap();
        }
    });
    let provider = DirectWebSocketProvider::new(MAXIMUM_FRAME_BYTES);
    let session = SessionId([0x5a; 16]);
    let group = provider
        .connect(ConnectRequest {
            endpoint,
            session,
            lane_policy: LanePolicy::Single,
            routing: Default::default(),
        })
        .await
        .unwrap();
    let client = ClientConnection::connect(
        group,
        ClientConnectionConfig {
            identity: StaticIdentity::generate().unwrap(),
            expected_daemon: Some(auth.identity().public_key()),
            auth: ClientAuthMode::Invitation {
                id: invitation.id,
                secret: Zeroizing::new(invitation_secret),
            },
            device_name: "link-ports-e2e-client".into(),
            session,
            lane_policy: LanePolicy::Single,
            limits: SessionLimits::default(),
            reconnect: ReconnectPolicy::default(),
        },
    )
    .await
    .unwrap();
    approver.await.unwrap();
    let daemon_client = accepted.recv().await.unwrap();
    let services = DaemonServices::new(WorkspaceService::new(), None);
    let service_task = tokio::task::spawn_local({
        let services = services.clone();
        async move { services.serve_client(daemon_client).await }
    });
    let multiplexer = ServiceMultiplexer::new(client.clone(), EndpointRole::Client);
    (client, multiplexer, vec![Box::new(server), Box::new(service_task), Box::new(services)])
}

/// Forward Port… end to end: a forward reaches the machine's port, a second ask answers the same
/// local port, the list shows it, and a close stops the listener and empties the list.
#[tokio::test(flavor = "current_thread")]
async fn the_link_socket_forwards_lists_and_closes_a_machine_port() {
    tokio::task::LocalSet::new()
        .run_until(async {
            tokio::time::timeout(TEST_TIMEOUT, async {
                let (target, target_task) = start_ping_target().await;
                let auth_state = tempdir().unwrap();
                let workspace_root = tempdir().unwrap();
                let (client, multiplexer, _held) = connected_link(auth_state.path()).await;
                let cell = LinkCell::new();
                cell.attach(&client);
                let ports = LinkPorts::new();
                let sockets = tempdir().unwrap();
                let path = sockets.path().join("link.admin");
                let _server = serve_link_cell_admin_with_ports(&cell, &ports, &path).await.unwrap();

                // Before the link is attached a forward is refused with why.
                let early = call_admin(
                    &path,
                    &AdminRequest::PortForward {
                        port: target.port(),
                        host: None,
                        workspace_root: None,
                    },
                )
                .await
                .unwrap();
                assert!(!early.ok);
                assert!(early.error.unwrap().contains("not connected"));
                ports.attach(&multiplexer);

                let root = workspace_root.path().to_string_lossy().into_owned();
                let forward: LinkForward = ask(
                    &path,
                    AdminRequest::PortForward {
                        port: target.port(),
                        host: None,
                        workspace_root: Some(root.clone()),
                    },
                )
                .await;
                assert_eq!(forward.port, target.port());
                assert_eq!(forward.host, "127.0.0.1");
                assert_ne!(forward.local_port, 0);
                assert_eq!(forward.url, format!("http://127.0.0.1:{}/", forward.local_port));
                assert_eq!(ping(forward.local_port).await, b"PONG\n");

                let again: LinkForward = ask(
                    &path,
                    AdminRequest::PortForward {
                        port: target.port(),
                        host: None,
                        workspace_root: Some(root),
                    },
                )
                .await;
                assert_eq!(again, forward);

                let listed: LinkForwards = ask(&path, AdminRequest::PortList).await;
                assert_eq!(listed.forwards, vec![forward.clone()]);

                let closed: LinkForwardClosed =
                    ask(&path, AdminRequest::PortClose { port: target.port(), host: None }).await;
                assert!(closed.closed);
                assert!(TcpStream::connect(("127.0.0.1", forward.local_port)).await.is_err());
                let listed: LinkForwards = ask(&path, AdminRequest::PortList).await;
                assert!(listed.forwards.is_empty());
                let again: LinkForwardClosed =
                    ask(&path, AdminRequest::PortClose { port: target.port(), host: None }).await;
                assert!(!again.closed);

                let zero = call_admin(
                    &path,
                    &AdminRequest::PortForward { port: 0, host: None, workspace_root: None },
                )
                .await
                .unwrap();
                assert!(!zero.ok);
                target_task.abort();
            })
            .await
            .expect("link ports e2e finished in time");
        })
        .await;
}

/// A link socket started without ports (the plain [`serve_link_cell_admin`]) refuses them.
#[tokio::test]
async fn a_link_socket_without_ports_refuses_port_requests() {
    let dir = tempdir().unwrap();
    let path = dir.path().join("link.admin");
    let cell = LinkCell::new();
    let _server = cmux_remote::admin::serve_link_cell_admin(&cell, &path).await.unwrap();
    let refused = call_admin(&path, &AdminRequest::PortList).await.unwrap();
    assert!(!refused.ok);
    assert!(refused.error.unwrap().contains("does not serve port forwards"));
}

use std::io;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use cmux_remote::bridge::LocalPortForward;
use cmux_remote::client::WorkspaceClient;
use cmux_remote::connection::{ClientConnection, ClientConnectionConfig, ReconnectPolicy};
use cmux_remote::crypto::{ClientAuthMode, StaticIdentity};
use cmux_remote::daemon::{RemoteDaemon, serve_direct_websocket};
use cmux_remote::identity::AuthDatabase;
use cmux_remote::provider::{ConnectRequest, DirectWebSocketProvider, TransportProvider};
use cmux_remote::service::{EndpointRole, ServiceMultiplexer};
use cmux_remote::services::DaemonServices;
use cmux_remote::session::SessionLimits;
use cmux_remote::workspace::WorkspaceService;
use cmux_remote_protocol::{
    LanePolicy, RoutePolicy, SessionId, WorkspaceRequest, WorkspaceResponse,
};
use tempfile::tempdir;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader, ReadHalf, WriteHalf};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::oneshot;
use url::Url;
use zeroize::Zeroizing;

const MAXIMUM_FRAME_BYTES: usize = 65_535;
const TRANSFER_BYTES: usize = 1024 * 1024;
const TEST_TIMEOUT: Duration = Duration::from_secs(60);

struct TcpTarget {
    address: SocketAddr,
    shutdown: Option<oneshot::Sender<()>>,
    task: Option<tokio::task::JoinHandle<()>>,
}

impl TcpTarget {
    async fn start() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let (shutdown, mut shutdown_rx) = oneshot::channel();
        let task = tokio::spawn(async move {
            let mut connections = tokio::task::JoinSet::new();
            loop {
                tokio::select! {
                    _ = &mut shutdown_rx => break,
                    accepted = listener.accept() => {
                        let Ok((socket, _)) = accepted else { break };
                        connections.spawn(async move {
                            let _ = serve_target_connection(socket).await;
                        });
                    }
                    _ = connections.join_next(), if !connections.is_empty() => {}
                }
            }
            connections.abort_all();
            while connections.join_next().await.is_some() {}
        });
        Self { address, shutdown: Some(shutdown), task: Some(task) }
    }

    async fn shutdown(mut self) {
        if let Some(shutdown) = self.shutdown.take() {
            let _ = shutdown.send(());
        }
        if let Some(task) = self.task.take() {
            let _ = task.await;
        }
    }
}

impl Drop for TcpTarget {
    fn drop(&mut self) {
        if let Some(shutdown) = self.shutdown.take() {
            let _ = shutdown.send(());
        }
    }
}

async fn serve_target_connection(socket: TcpStream) -> io::Result<()> {
    let (reader, mut writer) = tokio::io::split(socket);
    let mut reader = BufReader::new(reader);
    let mut command = String::new();
    reader.read_line(&mut command).await?;
    match command.as_str() {
        "GET /health HTTP/1.1\r\n" => serve_http(&mut reader, &mut writer).await,
        "BULK\n" => serve_bulk(&mut reader, &mut writer).await,
        "HALF\n" => serve_half_close(&mut reader, &mut writer).await,
        "HOLD\n" => serve_hold(&mut reader, &mut writer).await,
        "PING\n" => {
            writer.write_all(b"PONG\n").await?;
            writer.shutdown().await
        }
        _ => {
            writer.write_all(b"UNKNOWN\n").await?;
            writer.shutdown().await
        }
    }
}

async fn serve_http(
    reader: &mut BufReader<ReadHalf<TcpStream>>,
    writer: &mut WriteHalf<TcpStream>,
) -> io::Result<()> {
    let mut header = String::new();
    loop {
        header.clear();
        reader.read_line(&mut header).await?;
        if header == "\r\n" || header.is_empty() {
            break;
        }
    }
    writer
        .write_all(
            b"HTTP/1.1 200 OK\r\nContent-Length: 12\r\nConnection: close\r\n\r\nforwarded-ok",
        )
        .await?;
    writer.shutdown().await
}

async fn serve_bulk(
    reader: &mut BufReader<ReadHalf<TcpStream>>,
    writer: &mut WriteHalf<TcpStream>,
) -> io::Result<()> {
    let expected_upload = transfer_pattern(17);
    let download = transfer_pattern(91);
    let mut upload = vec![0_u8; TRANSFER_BYTES];
    tokio::try_join!(
        async {
            reader.read_exact(&mut upload).await?;
            Ok::<_, io::Error>(())
        },
        async {
            writer.write_all(&download).await?;
            Ok::<_, io::Error>(())
        },
    )?;
    writer.write_all(if upload == expected_upload { b"OK" } else { b"NO" }).await?;
    writer.shutdown().await
}

async fn serve_half_close(
    reader: &mut BufReader<ReadHalf<TcpStream>>,
    writer: &mut WriteHalf<TcpStream>,
) -> io::Result<()> {
    let mut body = Vec::new();
    reader.read_to_end(&mut body).await?;
    writer
        .write_all(if body == b"request-before-fin" { b"response-after-fin" } else { b"bad" })
        .await?;
    writer.shutdown().await
}

async fn serve_hold(
    reader: &mut BufReader<ReadHalf<TcpStream>>,
    writer: &mut WriteHalf<TcpStream>,
) -> io::Result<()> {
    writer.write_all(b"READY\n").await?;
    let mut discarded = Vec::new();
    reader.read_to_end(&mut discarded).await?;
    Ok(())
}

fn transfer_pattern(seed: u8) -> Vec<u8> {
    (0..TRANSFER_BYTES).map(|index| (index as u8).wrapping_mul(31).wrapping_add(seed)).collect()
}

async fn verify_http(address: SocketAddr) {
    let mut socket = TcpStream::connect(address).await.unwrap();
    socket
        .write_all(b"GET /health HTTP/1.1\r\nHost: forwarded.test\r\nConnection: close\r\n\r\n")
        .await
        .unwrap();
    let mut response = Vec::new();
    socket.read_to_end(&mut response).await.unwrap();
    assert_eq!(
        response,
        b"HTTP/1.1 200 OK\r\nContent-Length: 12\r\nConnection: close\r\n\r\nforwarded-ok"
    );
}

async fn verify_bulk(address: SocketAddr) {
    let socket = TcpStream::connect(address).await.unwrap();
    let (mut reader, mut writer) = tokio::io::split(socket);
    let upload = transfer_pattern(17);
    let expected_download = transfer_pattern(91);
    let mut download = vec![0_u8; TRANSFER_BYTES];
    let mut acknowledgement = [0_u8; 2];
    tokio::try_join!(
        async {
            writer.write_all(b"BULK\n").await?;
            writer.write_all(&upload).await?;
            Ok::<_, io::Error>(())
        },
        async {
            reader.read_exact(&mut download).await?;
            reader.read_exact(&mut acknowledgement).await?;
            Ok::<_, io::Error>(())
        },
    )
    .unwrap();
    assert_eq!(download, expected_download);
    assert_eq!(&acknowledgement, b"OK");
}

async fn verify_half_close(address: SocketAddr) {
    let mut socket = TcpStream::connect(address).await.unwrap();
    socket.write_all(b"HALF\nrequest-before-fin").await.unwrap();
    socket.shutdown().await.unwrap();
    let mut response = Vec::new();
    socket.read_to_end(&mut response).await.unwrap();
    assert_eq!(response, b"response-after-fin");
}

async fn verify_reconnect(
    address: SocketAddr,
    client: &Arc<ClientConnection>,
    provider: &DirectWebSocketProvider,
    endpoint: &Url,
    session: SessionId,
) {
    let mut old_socket = TcpStream::connect(address).await.unwrap();
    old_socket.write_all(b"HOLD\n").await.unwrap();
    let mut ready = [0_u8; 6];
    old_socket.read_exact(&mut ready).await.unwrap();
    assert_eq!(&ready, b"READY\n");

    let replacement = provider
        .connect(ConnectRequest {
            endpoint: endpoint.clone(),
            session,
            lane_policy: LanePolicy::Single,
            routing: Default::default(),
        })
        .await
        .unwrap();
    client.reconnect(replacement).await.unwrap();
    assert_eq!(client.snapshot().await.generation, 1);

    let mut trailing = [0_u8; 1];
    match tokio::time::timeout(Duration::from_secs(5), old_socket.read(&mut trailing))
        .await
        .expect("old forwarded socket stayed open across reconnect")
    {
        Ok(0) => {}
        Err(error)
            if matches!(
                error.kind(),
                io::ErrorKind::BrokenPipe
                    | io::ErrorKind::ConnectionAborted
                    | io::ErrorKind::ConnectionReset
                    | io::ErrorKind::NotConnected
            ) => {}
        outcome => panic!("old forwarded socket did not close after reconnect: {outcome:?}"),
    }

    let mut fresh_socket = TcpStream::connect(address).await.unwrap();
    fresh_socket.write_all(b"PING\n").await.unwrap();
    let mut pong = [0_u8; 5];
    fresh_socket.read_exact(&mut pong).await.unwrap();
    assert_eq!(&pong, b"PONG\n");
}

#[tokio::test(flavor = "current_thread")]
async fn forwarding_crosses_rpc_tunnel_tcp_and_reconnects() {
    tokio::task::LocalSet::new()
        .run_until(async {
            tokio::time::timeout(TEST_TIMEOUT, async {
                let target = TcpTarget::start().await;
                let auth_state = tempdir().unwrap();
                let workspace_root = tempdir().unwrap();
                let auth =
                    AuthDatabase::load_or_create(auth_state.path(), "forward-e2e", false).unwrap();
                let (daemon, mut accepted) =
                    RemoteDaemon::new(auth.clone(), SessionLimits::default());
                let server = serve_direct_websocket(
                    daemon,
                    "127.0.0.1:0".parse().unwrap(),
                    MAXIMUM_FRAME_BYTES,
                    false,
                )
                .await
                .unwrap();
                let endpoint =
                    Url::parse(&format!("ws://{}/v1/link", server.local_addr())).unwrap();
                let invitation =
                    auth.create_invitation(Duration::from_secs(60), Vec::new()).await.unwrap();
                let invitation_secret = invitation.secret_bytes().unwrap();
                let approver = tokio::spawn({
                    let auth = auth.clone();
                    async move {
                        let pending = auth.wait_for_pending(Duration::from_secs(5)).await.unwrap();
                        auth.approve(&pending[0].invitation_id).await.unwrap();
                    }
                });
                let provider = DirectWebSocketProvider::new(MAXIMUM_FRAME_BYTES);
                let session = SessionId([0x4f; 16]);
                let group = provider
                    .connect(ConnectRequest {
                        endpoint: endpoint.clone(),
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
                        device_name: "forward-e2e-client".into(),
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
                let workspace = WorkspaceClient::connect(multiplexer.clone()).await.unwrap();
                let opened = workspace
                    .request(WorkspaceRequest::OpenWorkspace {
                        root: workspace_root.path().to_string_lossy().into_owned(),
                    })
                    .await
                    .unwrap();
                let WorkspaceResponse::Workspace { id: workspace_id, .. } = opened else {
                    panic!("open-workspace returned the wrong response: {opened:?}")
                };
                let created = workspace
                    .request(WorkspaceRequest::CreateRoute {
                        workspace: workspace_id,
                        host: target.address.ip().to_string(),
                        port: target.address.port(),
                        policy: RoutePolicy::LoopbackOnly,
                    })
                    .await
                    .unwrap();
                let WorkspaceResponse::RouteCreated { route, .. } = created else {
                    panic!("create-route returned the wrong response: {created:?}")
                };
                let forward = LocalPortForward::bind(
                    multiplexer.clone(),
                    route,
                    "127.0.0.1:0".parse().unwrap(),
                )
                .await
                .unwrap();
                let address = forward.local_addr();

                verify_http(address).await;
                verify_bulk(address).await;
                verify_half_close(address).await;
                verify_reconnect(address, &client, &provider, &endpoint, session).await;
                assert!(matches!(
                    workspace.request(WorkspaceRequest::Capabilities).await.unwrap(),
                    WorkspaceResponse::Capabilities { .. }
                ));

                assert_eq!(
                    workspace.request(WorkspaceRequest::CloseRoute { route }).await.unwrap(),
                    WorkspaceResponse::Closed
                );
                forward.shutdown().await;
                drop(workspace);
                multiplexer.shutdown().await;
                client.close().await.unwrap();
                service_task.abort();
                let _ = service_task.await;
                server.shutdown().await.unwrap();
                target.shutdown().await;
            })
            .await
            .expect("forwarding E2E timed out");
        })
        .await;
}

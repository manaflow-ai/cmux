#![cfg(unix)]
//! A remote session whose carrier is gone longer than the daemon's resume
//! lease ends for good: the daemon drops it and refuses the reconnect with
//! its typed "session unavailable" rejection. The client must report that end
//! as a typed error a caller can act on (stop redialing, offer a restart), and
//! stay ended. A carrier that breaks and comes back inside the lease must
//! still reconnect. Fuzz catalog row h, finding netdrop n2.
//!
//! The faults come from a TCP proxy between the test's client and the test's
//! daemon on loopback; no host network changes.

use std::collections::BTreeMap;
use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use cmux_remote::client::WorkspaceClient;
use cmux_remote::connection::{ClientConnection, ClientConnectionConfig, ReconnectPolicy};
use cmux_remote::crypto::{ClientAuthMode, StaticIdentity};
use cmux_remote::daemon::{
    DaemonSessionPolicy, DirectWebSocketOptions, DirectWebSocketServer, RemoteDaemon,
    ServerConnection, WebSocketKeepalive, serve_direct_websocket_with_options,
};
use cmux_remote::identity::AuthDatabase;
use cmux_remote::observability::ConnectionState;
use cmux_remote::provider::{ConnectRequest, DirectWebSocketProvider, TransportProvider};
use cmux_remote::service::{EndpointRole, ServiceMultiplexer};
use cmux_remote::services::DaemonServices;
use cmux_remote::session::SessionLimits;
use cmux_remote::workspace::WorkspaceService;
use cmux_remote_protocol::{LanePolicy, SessionId, WorkspaceRequest, WorkspaceResponse};
use tempfile::{TempDir, tempdir};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::tcp::{OwnedReadHalf, OwnedWriteHalf};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::watch;
use tokio::time::Instant;
use url::Url;
use zeroize::Zeroizing;

const MAXIMUM_FRAME_BYTES: usize = 65_535;
/// The daemon closes a silent link after 1.5 s.
const KEEPALIVE: WebSocketKeepalive = WebSocketKeepalive {
    ping_interval: Duration::from_millis(300),
    dead_peer_timeout: Duration::from_millis(1_500),
};
/// The daemon keeps a disconnected session 1 s for a reconnect.
const RESUME_LEASE: Duration = Duration::from_secs(1);
/// Longer than the dead-peer timeout plus the lease, so the session is gone.
const EXPIRING_FREEZE: Duration = Duration::from_secs(4);
const RECONNECT_TIMEOUT: Duration = Duration::from_secs(10);
/// The code a workspace request fails with once the session is gone.
const SESSION_UNAVAILABLE: &str = "session-unavailable";

/// Carries bytes both ways. Frozen: holds every byte (a vanished network),
/// sockets open. Cut: closes every carrier.
struct Proxy {
    address: SocketAddr,
    frozen: watch::Sender<bool>,
    cut: watch::Sender<u64>,
    accepted: Arc<AtomicUsize>,
    task: tokio::task::JoinHandle<()>,
}

impl Proxy {
    async fn start(upstream: SocketAddr) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let (frozen, _) = watch::channel(false);
        let (cut, _) = watch::channel(0_u64);
        let accepted = Arc::new(AtomicUsize::new(0));
        let task = tokio::spawn({
            let frozen = frozen.clone();
            let cut = cut.clone();
            let accepted = accepted.clone();
            async move {
                loop {
                    let Ok((client, _)) = listener.accept().await else { return };
                    accepted.fetch_add(1, Ordering::AcqRel);
                    let frozen = frozen.subscribe();
                    let mut cut = cut.subscribe();
                    tokio::spawn(async move {
                        let epoch = *cut.borrow_and_update();
                        let Ok(daemon) = TcpStream::connect(upstream).await else { return };
                        let (client_read, client_write) = client.into_split();
                        let (daemon_read, daemon_write) = daemon.into_split();
                        tokio::select! {
                            _ = async {
                                tokio::join!(
                                    pump(client_read, daemon_write, frozen.clone()),
                                    pump(daemon_read, client_write, frozen),
                                )
                            } => {}
                            _ = async {
                                while *cut.borrow_and_update() == epoch {
                                    if cut.changed().await.is_err() {
                                        return;
                                    }
                                }
                            } => {}
                        }
                    });
                }
            }
        });
        Self { address, frozen, cut, accepted, task }
    }

    fn freeze(&self, frozen: bool) {
        self.frozen.send_replace(frozen);
    }

    fn cut(&self) {
        self.cut.send_modify(|epoch| *epoch += 1);
    }

    fn accepted(&self) -> usize {
        self.accepted.load(Ordering::Acquire)
    }
}

impl Drop for Proxy {
    fn drop(&mut self) {
        self.task.abort();
        self.cut();
    }
}

/// Holds each chunk while frozen and carries it once the freeze ends.
async fn pump(mut from: OwnedReadHalf, mut to: OwnedWriteHalf, mut frozen: watch::Receiver<bool>) {
    let mut buffer = vec![0_u8; 64 * 1024];
    loop {
        let read = match from.read(&mut buffer).await {
            Ok(0) | Err(_) => break,
            Ok(read) => read,
        };
        while *frozen.borrow_and_update() {
            if frozen.changed().await.is_err() {
                return;
            }
        }
        if to.write_all(&buffer[..read]).await.is_err() {
            break;
        }
    }
    while *frozen.borrow_and_update() {
        if frozen.changed().await.is_err() {
            return;
        }
    }
    let _ = to.shutdown().await;
}

struct Session {
    _state: TempDir,
    _root: TempDir,
    server: DirectWebSocketServer,
    proxy: Proxy,
    client: Arc<ClientConnection>,
    daemon_client: Arc<ServerConnection>,
    multiplexer: Arc<ServiceMultiplexer>,
    workspace: Arc<WorkspaceClient>,
    service_task: tokio::task::JoinHandle<()>,
}

async fn connect(name: &str, session: SessionId) -> Session {
    let state = tempdir().unwrap();
    let root = tempdir().unwrap();
    let auth = AuthDatabase::load_or_create(state.path(), name, false).unwrap();
    let (daemon, mut accepted) = RemoteDaemon::with_policy(
        auth.clone(),
        SessionLimits::default(),
        DaemonSessionPolicy { resume_lease: RESUME_LEASE },
    )
    .unwrap();
    let server = serve_direct_websocket_with_options(
        daemon,
        "127.0.0.1:0".parse().unwrap(),
        MAXIMUM_FRAME_BYTES,
        DirectWebSocketOptions { keepalive: KEEPALIVE, ..Default::default() },
    )
    .await
    .unwrap();
    let proxy = Proxy::start(server.local_addr()).await;
    let invitation = auth.create_invitation(Duration::from_secs(60), Vec::new()).await.unwrap();
    let approver = tokio::spawn({
        let auth = auth.clone();
        async move {
            let pending = auth.wait_for_pending(Duration::from_secs(10)).await.unwrap();
            auth.approve(&pending[0].invitation_id).await.unwrap();
        }
    });
    let secret = Zeroizing::new(invitation.secret_bytes().unwrap());
    let group = DirectWebSocketProvider::new(MAXIMUM_FRAME_BYTES)
        .connect(ConnectRequest {
            endpoint: Url::parse(&format!("ws://{}/v1/link", proxy.address)).unwrap(),
            session,
            lane_policy: LanePolicy::Auto,
            routing: BTreeMap::new(),
        })
        .await
        .unwrap();
    let client = ClientConnection::connect(
        group,
        ClientConnectionConfig {
            identity: StaticIdentity::generate().unwrap(),
            expected_daemon: Some(auth.identity().public_key()),
            auth: ClientAuthMode::Invitation { id: invitation.id, secret },
            device_name: name.into(),
            session,
            lane_policy: LanePolicy::Auto,
            limits: SessionLimits::default(),
            reconnect: ReconnectPolicy {
                initial_delay: Duration::from_millis(20),
                maximum_delay: Duration::from_millis(250),
                attempt_timeout: Duration::from_secs(2),
                full_jitter: false,
                heartbeat_interval: Some(Duration::from_millis(250)),
                heartbeat_timeout: Duration::from_secs(1),
                maximum_attempts: None,
                maximum_duration: None,
            },
        },
    )
    .await
    .unwrap();
    approver.await.unwrap();
    let daemon_client =
        tokio::time::timeout(Duration::from_secs(5), accepted.recv()).await.unwrap().unwrap();
    let services = DaemonServices::new(WorkspaceService::new(), None);
    let service_task = tokio::task::spawn_local({
        let daemon_client = daemon_client.clone();
        async move {
            let _ = services.serve_client(daemon_client).await;
        }
    });
    let multiplexer = ServiceMultiplexer::new(client.clone(), EndpointRole::Client);
    let workspace = WorkspaceClient::connect(multiplexer.clone()).await.unwrap();
    let opened = workspace
        .request(WorkspaceRequest::OpenWorkspace {
            root: root.path().to_string_lossy().into_owned(),
        })
        .await
        .unwrap();
    assert!(matches!(opened, WorkspaceResponse::Workspace { .. }), "{opened:?}");
    Session {
        _state: state,
        _root: root,
        server,
        proxy,
        client,
        daemon_client,
        multiplexer,
        workspace,
        service_task,
    }
}

async fn close(session: Session) {
    let Session { server, client, daemon_client, multiplexer, workspace, service_task, .. } =
        session;
    drop(workspace);
    let _ = tokio::time::timeout(Duration::from_secs(3), multiplexer.shutdown()).await;
    let _ = tokio::time::timeout(Duration::from_secs(3), client.close()).await;
    let _ = tokio::time::timeout(Duration::from_secs(3), daemon_client.close()).await;
    service_task.abort();
    let _ = tokio::time::timeout(Duration::from_secs(3), server.shutdown()).await;
}

#[tokio::test(flavor = "current_thread")]
async fn a_session_gone_past_its_resume_lease_ends_typed_and_stops_redialing() {
    tokio::task::LocalSet::new()
        .run_until(async {
            let session = connect("session-expiry", SessionId([0x5e; 16])).await;
            session.proxy.freeze(true);
            tokio::time::sleep(EXPIRING_FREEZE).await;
            session.proxy.freeze(false);

            // The reconnect is refused: the client leaves Connected for good.
            let deadline = Instant::now() + RECONNECT_TIMEOUT;
            let ended = loop {
                let state = session.client.snapshot().await.state;
                if matches!(state, ConnectionState::Disconnected | ConnectionState::Closed) {
                    break state;
                }
                assert!(
                    Instant::now() < deadline,
                    "the client did not end the gone session: still {state:?}"
                );
                tokio::time::sleep(Duration::from_millis(10)).await;
            };

            // A request fails with the typed session-gone code, not a
            // generic transport error a caller would retry.
            let error = session
                .workspace
                .request_with_timeout(WorkspaceRequest::ListWorkspaces, Duration::from_secs(3))
                .await
                .expect_err("a request on a gone session succeeded");
            assert_eq!(
                error.code, SESSION_UNAVAILABLE,
                "the session end reached the API as {}: {}",
                error.code, error.message
            );

            // It stays ended: no Reconnecting again and no new carrier for 2 s.
            let dials = session.proxy.accepted();
            let hold = Instant::now() + Duration::from_secs(2);
            while Instant::now() < hold {
                let state = session.client.snapshot().await.state;
                assert_eq!(
                    state, ended,
                    "the client went back to {state:?} after the session was gone"
                );
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
            assert_eq!(
                session.proxy.accepted(),
                dials,
                "the client dialed the gone session {} more times in 2 s",
                session.proxy.accepted() - dials
            );
            close(session).await;
        })
        .await;
}

#[tokio::test(flavor = "current_thread")]
async fn a_carrier_cut_inside_the_resume_lease_still_reconnects() {
    tokio::task::LocalSet::new()
        .run_until(async {
            let session = connect("carrier-cut", SessionId([0x5f; 16])).await;
            let before = session.client.snapshot().await.generation;
            session.proxy.cut();

            let deadline = Instant::now() + RECONNECT_TIMEOUT;
            loop {
                let snapshot = session.client.snapshot().await;
                if snapshot.state == ConnectionState::Connected && snapshot.generation > before {
                    break;
                }
                assert!(
                    Instant::now() < deadline,
                    "the client did not reconnect after a cut: {snapshot:?}"
                );
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
            let listed = session
                .workspace
                .request_with_timeout(WorkspaceRequest::ListWorkspaces, Duration::from_secs(3))
                .await
                .expect("a request after the reconnect failed");
            assert!(matches!(listed, WorkspaceResponse::Workspaces { .. }), "{listed:?}");
            close(session).await;
        })
        .await;
}

#![cfg(unix)]

use std::collections::BTreeMap;
use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use bytes::Bytes;
use cmux_remote::client::{ProcessEventStream, WorkspaceClient};
use cmux_remote::connection::{ClientConnection, ClientConnectionConfig, ReconnectPolicy};
use cmux_remote::crypto::{ClientAuthMode, StaticIdentity};
use cmux_remote::daemon::{RemoteDaemon, ServerConnection, serve_direct_websocket};
use cmux_remote::identity::AuthDatabase;
use cmux_remote::observability::ConnectionState;
use cmux_remote::provider::{ConnectRequest, DirectWebSocketProvider, TransportProvider};
use cmux_remote::service::{EndpointRole, ServiceMultiplexer};
use cmux_remote::services::DaemonServices;
use cmux_remote::session::SessionLimits;
use cmux_remote::workspace::WorkspaceService;
use cmux_remote_protocol::{
    ByteString, LanePolicy, ProcessEnvironment, ProcessEvent, ProcessIo, ProcessLifetime,
    ProcessSignal, PtyEofPolicy, RoutePolicy, Service, ServiceControl, SessionId, WorkspaceRequest,
    WorkspaceResponse,
};
use tempfile::tempdir;
use tokio::io::{AsyncReadExt, AsyncWriteExt, copy_bidirectional};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::watch;
use url::Url;
use zeroize::Zeroizing;

const MAXIMUM_FRAME_BYTES: usize = 65_535;
const RECONNECT_TIMEOUT: Duration = Duration::from_secs(30);
const TEST_TIMEOUT: Duration = Duration::from_secs(60);
const TUNNEL_REQUEST: &[u8] = b"tunnel-after-reconnect";
const TUNNEL_RESPONSE: &[u8] = b"fresh-tunnel-ok";

struct CarrierProxy {
    address: SocketAddr,
    cut: watch::Sender<u64>,
    release_delayed: watch::Sender<bool>,
    delayed_seen: watch::Sender<bool>,
    active: Arc<AtomicUsize>,
    task: tokio::task::JoinHandle<()>,
}

impl CarrierProxy {
    async fn start(upstream: SocketAddr) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let (cut, _) = watch::channel(0_u64);
        let (release_delayed, _) = watch::channel(false);
        let (delayed_seen, _) = watch::channel(false);
        let active = Arc::new(AtomicUsize::new(0));
        let task = tokio::spawn({
            let cut = cut.clone();
            let release_delayed = release_delayed.clone();
            let delayed_seen = delayed_seen.clone();
            let active = active.clone();
            async move {
                loop {
                    let Ok((mut downstream, _)) = listener.accept().await else { return };
                    let mut cut = cut.subscribe();
                    let mut release_delayed = release_delayed.subscribe();
                    let delayed_seen = delayed_seen.clone();
                    let active = active.clone();
                    tokio::spawn(async move {
                        let Some(request) = read_http_request(&mut downstream).await else {
                            return;
                        };
                        if delays_reconnect_lane(&request) {
                            delayed_seen.send_replace(true);
                            while !*release_delayed.borrow() {
                                if release_delayed.changed().await.is_err() {
                                    return;
                                }
                            }
                        }
                        let Ok(mut upstream) = TcpStream::connect(upstream).await else { return };
                        let _ = downstream.set_nodelay(true);
                        let _ = upstream.set_nodelay(true);
                        if upstream.write_all(&request).await.is_err() {
                            return;
                        }
                        active.fetch_add(1, Ordering::AcqRel);
                        tokio::select! {
                            _ = cut.changed() => {}
                            _ = copy_bidirectional(&mut downstream, &mut upstream) => {}
                        }
                        active.fetch_sub(1, Ordering::AcqRel);
                    });
                }
            }
        });
        Self { address, cut, release_delayed, delayed_seen, active, task }
    }

    async fn wait_for_active(&self, minimum: usize) {
        tokio::time::timeout(Duration::from_secs(5), async {
            while self.active.load(Ordering::Acquire) < minimum {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("the expected physical carriers did not cross the proxy");
    }

    fn drop_all(&self) {
        self.cut.send_modify(|generation| *generation = generation.wrapping_add(1));
    }

    async fn wait_for_delayed_lane(&self) {
        let mut delayed = self.delayed_seen.subscribe();
        tokio::time::timeout(Duration::from_secs(10), async {
            while !*delayed.borrow() {
                delayed.changed().await.unwrap();
            }
        })
        .await
        .expect("reconnect did not reach the delayed tunnel lane");
    }

    fn release_delayed_lane(&self) {
        self.release_delayed.send_replace(true);
    }
}

impl Drop for CarrierProxy {
    fn drop(&mut self) {
        self.task.abort();
    }
}

async fn read_http_request(stream: &mut TcpStream) -> Option<Vec<u8>> {
    const MAXIMUM_HEADER_BYTES: usize = 64 * 1024;

    let mut request = Vec::with_capacity(1024);
    let mut buffer = [0_u8; 1024];
    loop {
        let size = stream.read(&mut buffer).await.ok()?;
        if size == 0 {
            return None;
        }
        request.extend_from_slice(&buffer[..size]);
        if request.windows(4).any(|window| window == b"\r\n\r\n") {
            return Some(request);
        }
        if request.len() > MAXIMUM_HEADER_BYTES {
            return None;
        }
    }
}

fn delays_reconnect_lane(request: &[u8]) -> bool {
    let request = String::from_utf8_lossy(request);
    let Some(target) = request.lines().next().and_then(|line| line.split_whitespace().nth(1))
    else {
        return false;
    };
    let Ok(url) = Url::parse(&format!("http://carrier.test{target}")) else {
        return false;
    };
    let query = url.query_pairs().collect::<BTreeMap<_, _>>();
    query.get("cmux_generation").is_some_and(|value| value == "1")
        && query.get("cmux_lane").is_some_and(|value| value == "tunnel")
}

struct TunnelTarget {
    address: SocketAddr,
    task: tokio::task::JoinHandle<()>,
}

impl TunnelTarget {
    async fn start() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let task = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut request = vec![0_u8; TUNNEL_REQUEST.len()];
            socket.read_exact(&mut request).await.unwrap();
            assert_eq!(request, TUNNEL_REQUEST);
            socket.write_all(TUNNEL_RESPONSE).await.unwrap();
            socket.shutdown().await.unwrap();
        });
        Self { address, task }
    }

    async fn finish(self) {
        self.task.await.unwrap();
    }
}

async fn wait_for_output(events: &ProcessEventStream, transcript: &mut Vec<u8>, expected: &str) {
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            if String::from_utf8_lossy(transcript).contains(expected) {
                return;
            }
            let event = events
                .receive()
                .await
                .expect("process event stream failed")
                .expect("process event stream closed before the expected output");
            match event.event {
                ProcessEvent::Stdout { data, .. } | ProcessEvent::Stderr { data, .. } => {
                    transcript.extend(data.decode().unwrap());
                }
                ProcessEvent::Exit { code, signal, .. } => {
                    panic!(
                        "PTY exited before producing {expected:?}: code={code:?}, signal={signal:?}"
                    );
                }
                ProcessEvent::OutputTruncated { reason, .. } => {
                    panic!("PTY output was truncated before producing {expected:?}: {reason:?}");
                }
                ProcessEvent::ReplayGap { requested_after, range, .. } => {
                    panic!(
                        "PTY replay after {requested_after} was unavailable before producing \
                         {expected:?}: {range:?}"
                    );
                }
            }
        }
    })
    .await
    .unwrap_or_else(|_| {
        panic!(
            "PTY did not produce {expected:?}; transcript: {:?}",
            String::from_utf8_lossy(transcript)
        )
    });
}

async fn wait_for_committed_generation(
    client: &ClientConnection,
    daemon: &ServerConnection,
) -> u64 {
    let deadline = tokio::time::Instant::now() + RECONNECT_TIMEOUT;
    loop {
        let client_snapshot = client.snapshot().await;
        let daemon_snapshot = daemon.snapshot().await;
        if client_snapshot.generation > 0
            && client_snapshot.generation == daemon_snapshot.generation
            && client_snapshot.state == ConnectionState::Connected
            && daemon_snapshot.state == ConnectionState::Connected
        {
            return client_snapshot.generation;
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "the authenticated session did not resume on both peers: client={client_snapshot:?}, \
             daemon={daemon_snapshot:?}"
        );
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

async fn verify_fresh_tunnel(
    multiplexer: &Arc<ServiceMultiplexer>,
    route: cmux_remote_protocol::RouteId,
) {
    let tunnel = multiplexer
        .open(Service::TcpTunnel, BTreeMap::from([("route".into(), route.0.to_string())]))
        .await
        .unwrap();
    let opened = tokio::time::timeout(Duration::from_secs(2), tunnel.receive())
        .await
        .expect("fresh tunnel did not open")
        .unwrap()
        .expect("fresh tunnel closed during open");
    assert_eq!(
        serde_json::from_slice::<ServiceControl>(&opened.payload).unwrap(),
        ServiceControl::Opened { service: Service::TcpTunnel }
    );

    tunnel.send(Bytes::from_static(TUNNEL_REQUEST)).await.unwrap();
    let mut response = Vec::new();
    while response.len() < TUNNEL_RESPONSE.len() {
        let chunk = tokio::time::timeout(Duration::from_secs(2), tunnel.receive())
            .await
            .expect("fresh tunnel response timed out")
            .unwrap()
            .expect("fresh tunnel closed before its response");
        response.extend_from_slice(&chunk.payload);
    }
    assert_eq!(response, TUNNEL_RESPONSE);
    tunnel.close().await.unwrap();
}

#[tokio::test(flavor = "current_thread")]
async fn real_pty_and_fresh_services_survive_authenticated_carrier_reconnect() {
    tokio::task::LocalSet::new()
        .run_until(async {
            tokio::time::timeout(TEST_TIMEOUT, async {
                let auth_state = tempdir().unwrap();
                let workspace_root = tempdir().unwrap();
                let auth =
                    AuthDatabase::load_or_create(auth_state.path(), "pty-reconnect-e2e", false)
                        .unwrap();
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
                let proxy = CarrierProxy::start(server.local_addr()).await;
                let endpoint = Url::parse(&format!("ws://{}/v1/link", proxy.address)).unwrap();

                let invitation =
                    auth.create_invitation(Duration::from_secs(60), Vec::new()).await.unwrap();
                let approver = tokio::spawn({
                    let auth = auth.clone();
                    async move {
                        let pending = auth.wait_for_pending(Duration::from_secs(5)).await.unwrap();
                        auth.approve(&pending[0].invitation_id).await.unwrap();
                    }
                });
                let provider = DirectWebSocketProvider::new(MAXIMUM_FRAME_BYTES);
                let session = SessionId([0x70; 16]);
                let group = provider
                    .connect(ConnectRequest {
                        endpoint,
                        session,
                        lane_policy: LanePolicy::Auto,
                        routing: BTreeMap::new(),
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
                        device_name: "pty-reconnect-client".into(),
                        session,
                        lane_policy: LanePolicy::Auto,
                        limits: SessionLimits::default(),
                        reconnect: ReconnectPolicy {
                            initial_delay: Duration::from_millis(10),
                            maximum_delay: Duration::from_millis(50),
                            attempt_timeout: Duration::from_secs(5),
                            full_jitter: false,
                            heartbeat_interval: None,
                            heartbeat_timeout: Duration::from_millis(50),
                            maximum_attempts: Some(100),
                        },
                    },
                )
                .await
                .unwrap();
                approver.await.unwrap();
                let daemon_client = tokio::time::timeout(Duration::from_secs(5), accepted.recv())
                    .await
                    .unwrap()
                    .unwrap();
                let services = DaemonServices::new(WorkspaceService::new(), None);
                let service_task = tokio::task::spawn_local({
                    let services = services.clone();
                    let daemon_client = daemon_client.clone();
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
                    panic!("open-workspace returned the wrong response: {opened:?}");
                };
                let process_handle = workspace.allocate_process_handle();
                let started = workspace
                    .spawn_process_with_events(
                        process_handle,
                        WorkspaceRequest::SpawnProcess {
                            workspace: workspace_id.clone(),
                            argv: vec![
                                "/bin/sh".into(),
                                "-c".into(),
                                concat!(
                                    "stty -echo; ",
                                    "printf 'READY PID=%s\\n' \"$$\"; ",
                                    "while IFS= read -r line; do ",
                                    "set -- $(stty size); ",
                                    "printf 'PID=%s ROWS=%s COLS=%s INPUT=%s\\n' ",
                                    "\"$$\" \"$1\" \"$2\" \"$line\"; ",
                                    "done"
                                )
                                .into(),
                            ],
                            cwd: None,
                            env: BTreeMap::new(),
                            io: ProcessIo::Pty {
                                cols: 80,
                                rows: 24,
                                term: "xterm-256color".into(),
                                eof: PtyEofPolicy::Reject,
                            },
                            lifetime: ProcessLifetime::Workspace,
                            operation: None,
                            timeout_ms: Some(60_000),
                            retained_output_bytes: Some(64 * 1024),
                            environment: ProcessEnvironment::Inherit,
                        },
                    )
                    .await
                    .unwrap();
                let process = started.process;
                let pid = started
                    .pid
                    .expect("the Unix PTY process did not report its operating-system PID");
                let events = started.events;
                let mut transcript = Vec::new();
                wait_for_output(&events, &mut transcript, &format!("READY PID={pid}")).await;

                assert_eq!(
                    workspace
                        .request(WorkspaceRequest::ResizeProcess { process, cols: 101, rows: 37 })
                        .await
                        .unwrap(),
                    WorkspaceResponse::ProcessResized { process, cols: 101, rows: 37 }
                );
                assert_eq!(
                    workspace
                        .request(WorkspaceRequest::WriteProcess {
                            process,
                            write_id: 1,
                            data: ByteString::from_bytes(b"before\n"),
                            eof: false,
                        })
                        .await
                        .unwrap(),
                    WorkspaceResponse::ProcessWriteAccepted { process, write_id: 1 }
                );
                wait_for_output(
                    &events,
                    &mut transcript,
                    &format!("PID={pid} ROWS=37 COLS=101 INPUT=before"),
                )
                .await;

                proxy.wait_for_active(3).await;
                let client_generation = client.subscribe_generation();
                let daemon_generation = daemon_client.subscribe_generation();
                proxy.drop_all();
                proxy.wait_for_delayed_lane().await;
                tokio::time::sleep(Duration::from_millis(100)).await;
                assert_eq!(*client_generation.borrow(), 0);
                assert_eq!(*daemon_generation.borrow(), 0);
                assert_eq!(client.snapshot().await.generation, 0);
                assert_eq!(daemon_client.snapshot().await.generation, 0);

                proxy.release_delayed_lane();
                let committed_generation =
                    wait_for_committed_generation(&client, &daemon_client).await;
                assert_eq!(committed_generation, 1);
                assert_eq!(*client_generation.borrow(), committed_generation);
                assert_eq!(*daemon_generation.borrow(), committed_generation);

                assert_eq!(
                    workspace
                        .request(WorkspaceRequest::ResizeProcess { process, cols: 109, rows: 41 })
                        .await
                        .unwrap(),
                    WorkspaceResponse::ProcessResized { process, cols: 109, rows: 41 }
                );
                assert_eq!(
                    workspace
                        .request(WorkspaceRequest::WriteProcess {
                            process,
                            write_id: 2,
                            data: ByteString::from_bytes(b"after\n"),
                            eof: false,
                        })
                        .await
                        .unwrap(),
                    WorkspaceResponse::ProcessWriteAccepted { process, write_id: 2 }
                );
                wait_for_output(
                    &events,
                    &mut transcript,
                    &format!("PID={pid} ROWS=41 COLS=109 INPUT=after"),
                )
                .await;

                let fresh_workspace = WorkspaceClient::connect(multiplexer.clone()).await.unwrap();
                let listed =
                    fresh_workspace.request(WorkspaceRequest::ListWorkspaces).await.unwrap();
                let WorkspaceResponse::Workspaces { workspaces } = listed else {
                    panic!("list-workspaces returned the wrong response: {listed:?}");
                };
                assert!(workspaces.iter().any(|(id, _)| id == &workspace_id));

                let target = TunnelTarget::start().await;
                let created = fresh_workspace
                    .request(WorkspaceRequest::CreateRoute {
                        workspace: workspace_id,
                        host: target.address.ip().to_string(),
                        port: target.address.port(),
                        policy: RoutePolicy::LoopbackOnly,
                    })
                    .await
                    .unwrap();
                let WorkspaceResponse::RouteCreated { route, .. } = created else {
                    panic!("create-route returned the wrong response: {created:?}");
                };
                verify_fresh_tunnel(&multiplexer, route).await;
                target.finish().await;

                tokio::time::sleep(Duration::from_millis(200)).await;
                assert_eq!(client.snapshot().await.generation, committed_generation);
                assert_eq!(daemon_client.snapshot().await.generation, committed_generation);
                assert_eq!(*client_generation.borrow(), committed_generation);
                assert_eq!(*daemon_generation.borrow(), committed_generation);
                assert!(matches!(
                    accepted.try_recv(),
                    Err(tokio::sync::mpsc::error::TryRecvError::Empty)
                ));

                assert_eq!(
                    fresh_workspace.request(WorkspaceRequest::CloseRoute { route }).await.unwrap(),
                    WorkspaceResponse::Closed
                );
                assert_eq!(
                    workspace
                        .request(WorkspaceRequest::SignalProcess {
                            process,
                            signal: ProcessSignal::Kill,
                        })
                        .await
                        .unwrap(),
                    WorkspaceResponse::ProcessSignaled { process, signal: ProcessSignal::Kill }
                );
                assert!(matches!(
                    workspace.request(WorkspaceRequest::WaitProcess { process }).await.unwrap(),
                    WorkspaceResponse::ProcessExit { process: exited, .. } if exited == process
                ));

                drop(fresh_workspace);
                drop(workspace);
                multiplexer.shutdown().await;
                client.close().await.unwrap();
                daemon_client.close().await.unwrap();
                let _ = service_task.await.unwrap();
                server.shutdown().await.unwrap();
            })
            .await
            .expect("PTY reconnect E2E timed out");
        })
        .await;
}

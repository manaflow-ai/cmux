use std::collections::BTreeMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use bytes::Bytes;
use cmux_relay::{Relay, RelayConfig};
use cmux_remote::client::WorkspaceClient;
use cmux_remote::connection::{ClientConnection, ClientConnectionConfig, ReconnectPolicy};
use cmux_remote::crypto::{ClientAuthMode, StaticIdentity};
use cmux_remote::identity::AuthDatabase;
use cmux_remote::observability::{ConnectionState, TransportPathKind};
use cmux_remote::provider::{
    ConnectRequest, RelayClientConfig, RelayDaemonConfig, RelayProvider, TransportProvider,
    register_relay_daemon,
};
use cmux_remote::service::{EndpointRole, ServiceMultiplexer};
use cmux_remote::services::DaemonServices;
use cmux_remote::session::SessionLimits;
use cmux_remote::workspace::WorkspaceService;
use cmux_remote_protocol::{
    FrameFlags, Lane, LanePolicy, RoutePolicy, Service, ServiceControl, SessionId,
    WorkspaceRequest, WorkspaceResponse,
};
use tempfile::tempdir;
use tokio::io::{AsyncReadExt, AsyncWriteExt, copy_bidirectional};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::watch;
use url::Url;
use zeroize::Zeroizing;

const RECONNECT_TEST_TIMEOUT: Duration = Duration::from_secs(60);
const MAXIMUM_EXPECTED_RECONNECT_GENERATION: u64 = 20;

struct DropProxy {
    address: std::net::SocketAddr,
    cut: watch::Sender<u64>,
    reconnect_released: watch::Sender<bool>,
    active: Arc<AtomicUsize>,
    task: tokio::task::JoinHandle<()>,
}

impl DropProxy {
    async fn start(upstream: std::net::SocketAddr) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let (cut, _) = watch::channel(0_u64);
        let (reconnect_released, _) = watch::channel(true);
        let active = Arc::new(AtomicUsize::new(0));
        let task = tokio::spawn({
            let cut = cut.clone();
            let reconnect_released = reconnect_released.clone();
            let active = active.clone();
            async move {
                loop {
                    let Ok((mut downstream, _)) = listener.accept().await else { return };
                    let mut cut = cut.subscribe();
                    let mut reconnect_released = reconnect_released.subscribe();
                    let active = active.clone();
                    tokio::spawn(async move {
                        while !*reconnect_released.borrow() {
                            if reconnect_released.changed().await.is_err() {
                                return;
                            }
                        }
                        let Ok(mut upstream) = TcpStream::connect(upstream).await else { return };
                        downstream.set_nodelay(true).unwrap();
                        upstream.set_nodelay(true).unwrap();
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
        Self { address, cut, reconnect_released, active, task }
    }

    async fn wait_for_active(&self, minimum: usize) {
        tokio::time::timeout(Duration::from_secs(5), async {
            while self.active.load(Ordering::Acquire) < minimum {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
    }

    fn drop_all(&self) {
        self.cut.send_modify(|generation| *generation = generation.wrapping_add(1));
    }

    fn drop_all_and_pause_reconnect(&self) {
        self.reconnect_released.send_replace(false);
        self.drop_all();
    }

    async fn wait_for_inactive(&self) {
        tokio::time::timeout(Duration::from_secs(5), async {
            while self.active.load(Ordering::Acquire) != 0 {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("the proxy did not drop every physical carrier");
    }

    fn release_reconnect(&self) {
        self.reconnect_released.send_replace(true);
    }
}

impl Drop for DropProxy {
    fn drop(&mut self) {
        self.task.abort();
    }
}

struct ReconnectTunnelTarget {
    address: std::net::SocketAddr,
    close_held: Option<tokio::sync::oneshot::Sender<()>>,
    task: tokio::task::JoinHandle<()>,
}

impl ReconnectTunnelTarget {
    async fn start() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let (close_held, close_held_rx) = tokio::sync::oneshot::channel();
        let task = tokio::spawn(async move {
            let (mut held, _) = listener.accept().await.unwrap();
            let mut hold = [0_u8; 4];
            held.read_exact(&mut hold).await.unwrap();
            assert_eq!(&hold, b"HOLD");
            held.write_all(b"READY").await.unwrap();
            let _ = close_held_rx.await;
            held.shutdown().await.unwrap();

            let (mut fresh, _) = listener.accept().await.unwrap();
            let mut ping = [0_u8; 4];
            fresh.read_exact(&mut ping).await.unwrap();
            assert_eq!(&ping, b"PING");
            fresh.write_all(b"PONG").await.unwrap();
            fresh.shutdown().await.unwrap();
        });
        Self { address, close_held: Some(close_held), task }
    }

    fn close_held(&mut self) {
        self.close_held.take().unwrap().send(()).unwrap();
    }

    async fn finish(self) {
        self.task.await.unwrap();
    }
}

#[tokio::test]
async fn shared_provider_crosses_native_relay_with_noise_and_parallel_lanes() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
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

#[tokio::test(flavor = "current_thread")]
async fn native_relay_resumes_real_daemon_services_after_live_tunnel_carrier_loss() {
    tokio::task::LocalSet::new()
        .run_until(async {
            tokio::time::timeout(RECONNECT_TEST_TIMEOUT, async {
                let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
                let relay_address = listener.local_addr().unwrap();
                let relay =
                    Relay::new(RelayConfig { allow_open: true, ..RelayConfig::default() }).unwrap();
                let (listener, router) = relay.server_parts(listener);
                let relay_task = tokio::spawn(async move {
                    axum::serve(listener, router).await.unwrap();
                });
                let proxy = DropProxy::start(relay_address).await;

                let state = tempdir().unwrap();
                let root = tempdir().unwrap();
                let auth =
                    AuthDatabase::load_or_create(state.path(), "relay-live-tunnel", false).unwrap();
                let (daemon, mut accepted) =
                    cmux_remote::daemon::RemoteDaemon::new(auth.clone(), SessionLimits::default());
                let endpoint = Url::parse(&format!("relay+ws://{}", proxy.address)).unwrap();
                let registration = register_relay_daemon(
                    daemon,
                    RelayDaemonConfig {
                        endpoint: endpoint.clone(),
                        slot: "live-tunnel-slot".into(),
                        ticket: "open-daemon-ticket".into(),
                        maximum_frame_bytes: 65_535,
                        control_timeout: Duration::from_secs(1),
                    },
                )
                .await
                .unwrap();

                let invitation =
                    auth.create_invitation(Duration::from_secs(60), vec![]).await.unwrap();
                let approver = tokio::spawn({
                    let auth = auth.clone();
                    async move {
                        let pending = auth.wait_for_pending(Duration::from_secs(5)).await.unwrap();
                        auth.approve(&pending[0].invitation_id).await.unwrap();
                    }
                });
                let provider = RelayProvider::new(RelayClientConfig {
                    slot: "live-tunnel-slot".into(),
                    ticket: "open-client-ticket".into(),
                    maximum_frame_bytes: 65_535,
                    control_timeout: Duration::from_secs(1),
                })
                .unwrap();
                let session = SessionId([44; 16]);
                let group = provider
                    .connect(ConnectRequest {
                        endpoint,
                        session,
                        lane_policy: LanePolicy::Auto,
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
                        device_name: "relay-live-tunnel-client".into(),
                        session,
                        lane_policy: LanePolicy::Auto,
                        limits: SessionLimits::default(),
                        reconnect: ReconnectPolicy {
                            initial_delay: Duration::from_millis(10),
                            maximum_delay: Duration::from_millis(50),
                            attempt_timeout: Duration::from_secs(1),
                            full_jitter: false,
                            heartbeat_interval: Some(Duration::from_millis(20)),
                            heartbeat_timeout: Duration::from_millis(50),
                            maximum_attempts: Some(100),
                        },
                    },
                )
                .await
                .unwrap();
                approver.await.unwrap();
                let server = tokio::time::timeout(Duration::from_secs(5), accepted.recv())
                    .await
                    .unwrap()
                    .unwrap();
                let services = DaemonServices::new(WorkspaceService::new(), None);
                let service_task = tokio::task::spawn_local({
                    let services = services.clone();
                    let server = server.clone();
                    async move { services.serve_client(server).await }
                });
                let multiplexer = ServiceMultiplexer::new(client.clone(), EndpointRole::Client);
                let workspace = WorkspaceClient::connect(multiplexer.clone()).await.unwrap();
                let opened = workspace
                    .request(WorkspaceRequest::OpenWorkspace {
                        root: root.path().to_string_lossy().into_owned(),
                    })
                    .await
                    .unwrap();
                let WorkspaceResponse::Workspace { id: workspace_id, .. } = opened else {
                    panic!("open-workspace returned the wrong response: {opened:?}");
                };

                let mut target = ReconnectTunnelTarget::start().await;
                let created = workspace
                    .request(WorkspaceRequest::CreateRoute {
                        workspace: workspace_id.clone(),
                        host: target.address.ip().to_string(),
                        port: target.address.port(),
                        policy: RoutePolicy::LoopbackOnly,
                    })
                    .await
                    .unwrap();
                let WorkspaceResponse::RouteCreated { route, .. } = created else {
                    panic!("create-route returned the wrong response: {created:?}");
                };
                let held = multiplexer
                    .open(
                        Service::TcpTunnel,
                        BTreeMap::from([("route".into(), route.0.to_string())]),
                    )
                    .await
                    .unwrap();
                let opened = held.receive().await.unwrap().unwrap();
                assert_eq!(
                    serde_json::from_slice::<ServiceControl>(&opened.payload).unwrap(),
                    ServiceControl::Opened { service: Service::TcpTunnel }
                );
                held.send(Bytes::from_static(b"HOLD")).await.unwrap();
                assert_eq!(held.receive().await.unwrap().unwrap().payload, b"READY".as_slice());

                proxy.wait_for_active(8).await;
                proxy.drop_all_and_pause_reconnect();
                proxy.wait_for_inactive().await;
                target.close_held();
                tokio::time::sleep(Duration::from_millis(100)).await;
                proxy.release_reconnect();
                let resumed = tokio::time::timeout(Duration::from_secs(15), async {
                    loop {
                        let client_snapshot = client.snapshot().await;
                        let server_snapshot = server.snapshot().await;
                        if client_snapshot.generation > 0
                            && client_snapshot.generation == server_snapshot.generation
                            && client_snapshot.state == ConnectionState::Connected
                            && server_snapshot.state == ConnectionState::Connected
                        {
                            break client_snapshot.generation;
                        }
                        tokio::time::sleep(Duration::from_millis(10)).await;
                    }
                })
                .await;
                let resumed = match resumed {
                    Ok(generation) => generation,
                    Err(_) => {
                        let client_snapshot = client.snapshot().await;
                        let server_snapshot = server.snapshot().await;
                        panic!(
                            "relay session did not resume after its live tunnel carrier was lost: \
                             client={client_snapshot:?}, daemon={server_snapshot:?}"
                        );
                    }
                };
                assert!(
                    (1..=MAXIMUM_EXPECTED_RECONNECT_GENERATION).contains(&resumed),
                    "relay reconnect burned too many generations: {resumed}"
                );
                assert!(
                    tokio::time::timeout(Duration::from_secs(2), held.receive())
                        .await
                        .expect("generation-bound tunnel remained open after reconnect")
                        .is_err(),
                    "generation-bound tunnel ended without its generation-change error"
                );

                let fresh_workspace = WorkspaceClient::connect(multiplexer.clone()).await.unwrap();
                let listed =
                    fresh_workspace.request(WorkspaceRequest::ListWorkspaces).await.unwrap();
                assert!(matches!(
                    listed,
                    WorkspaceResponse::Workspaces { workspaces }
                        if workspaces.iter().any(|(id, _)| id == &workspace_id)
                ));
                let fresh = multiplexer
                    .open(
                        Service::TcpTunnel,
                        BTreeMap::from([("route".into(), route.0.to_string())]),
                    )
                    .await
                    .unwrap();
                let opened = fresh.receive().await.unwrap().unwrap();
                assert_eq!(
                    serde_json::from_slice::<ServiceControl>(&opened.payload).unwrap(),
                    ServiceControl::Opened { service: Service::TcpTunnel }
                );
                fresh.send(Bytes::from_static(b"PING")).await.unwrap();
                assert_eq!(fresh.receive().await.unwrap().unwrap().payload, b"PONG".as_slice());
                fresh.close().await.unwrap();
                target.finish().await;

                assert_eq!(
                    fresh_workspace.request(WorkspaceRequest::CloseRoute { route }).await.unwrap(),
                    WorkspaceResponse::Closed
                );
                drop(fresh_workspace);
                drop(workspace);
                multiplexer.shutdown().await;
                client.close().await.unwrap();
                server.close().await.unwrap();
                let _ = service_task.await.unwrap();
                registration.shutdown().await;
                relay_task.abort();
            })
            .await
            .expect("live-tunnel relay reconnect E2E timed out");
        })
        .await;
}

#[tokio::test]
async fn native_relay_recovers_after_every_carrier_is_dropped() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let relay_address = listener.local_addr().unwrap();
    let relay = Relay::new(RelayConfig { allow_open: true, ..RelayConfig::default() }).unwrap();
    let (listener, router) = relay.server_parts(listener);
    let relay_task = tokio::spawn(async move {
        axum::serve(listener, router).await.unwrap();
    });
    let proxy = DropProxy::start(relay_address).await;

    let state = tempdir().unwrap();
    let auth = AuthDatabase::load_or_create(state.path(), "relay-reconnect", false).unwrap();
    let (daemon, mut accepted) =
        cmux_remote::daemon::RemoteDaemon::new(auth.clone(), SessionLimits::default());
    let endpoint = Url::parse(&format!("relay+ws://{}", proxy.address)).unwrap();
    let registration = register_relay_daemon(
        daemon,
        RelayDaemonConfig {
            endpoint: endpoint.clone(),
            slot: "reconnect-slot".into(),
            ticket: "open-daemon-ticket".into(),
            maximum_frame_bytes: 65_535,
            control_timeout: Duration::from_secs(1),
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
        slot: "reconnect-slot".into(),
        ticket: "open-client-ticket".into(),
        maximum_frame_bytes: 65_535,
        control_timeout: Duration::from_secs(1),
    })
    .unwrap();
    let session = SessionId([43; 16]);
    let group = provider
        .connect(ConnectRequest {
            endpoint,
            session,
            lane_policy: LanePolicy::Auto,
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
            device_name: "relay-reconnect-client".into(),
            session,
            lane_policy: LanePolicy::Auto,
            limits: SessionLimits::default(),
            reconnect: ReconnectPolicy {
                initial_delay: Duration::from_millis(10),
                maximum_delay: Duration::from_millis(50),
                attempt_timeout: Duration::from_secs(1),
                full_jitter: false,
                heartbeat_interval: Some(Duration::from_millis(20)),
                heartbeat_timeout: Duration::from_millis(50),
                maximum_attempts: Some(20),
            },
        },
    )
    .await
    .unwrap();
    approver.await.unwrap();
    let server =
        tokio::time::timeout(Duration::from_secs(5), accepted.recv()).await.unwrap().unwrap();
    let client_services = ServiceMultiplexer::new(client.clone(), EndpointRole::Client);
    let server_services = ServiceMultiplexer::new(server.clone(), EndpointRole::Daemon);
    let workspace = client_services.open(Service::WorkspaceRpc, BTreeMap::new()).await.unwrap();
    let daemon_workspace = server_services.accept().await.unwrap().unwrap().stream;
    workspace.send(Bytes::from_static(b"before reconnect")).await.unwrap();
    let before = tokio::time::timeout(Duration::from_secs(2), daemon_workspace.receive())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert_eq!(before.payload, b"before reconnect".as_slice());
    let mux_control = client_services.open(Service::MuxControl, BTreeMap::new()).await.unwrap();
    let daemon_mux_control = server_services.accept().await.unwrap().unwrap().stream;
    mux_control
        .send_on(Lane::Interactive, Bytes::from_static(b"before mux reconnect"))
        .await
        .unwrap();
    let before_mux = tokio::time::timeout(Duration::from_secs(2), daemon_mux_control.receive())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert_eq!(before_mux.payload, b"before mux reconnect".as_slice());

    proxy.wait_for_active(8).await;
    let generation = client.subscribe_generation();
    proxy.drop_all();
    let snapshot = tokio::time::timeout(RECONNECT_TEST_TIMEOUT, async {
        loop {
            let client_snapshot = client.snapshot().await;
            let daemon_snapshot = server.snapshot().await;
            if client_snapshot.generation > 0
                && client_snapshot.generation == daemon_snapshot.generation
                && client_snapshot.state == ConnectionState::Connected
                && daemon_snapshot.state == ConnectionState::Connected
            {
                break client_snapshot;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("relay reconnect did not commit on both peers");
    assert_eq!(*generation.borrow(), snapshot.generation);

    workspace.send(Bytes::from_static(b"after reconnect")).await.unwrap();
    let after = tokio::time::timeout(Duration::from_secs(2), daemon_workspace.receive())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert_eq!(after.payload, b"after reconnect".as_slice());
    daemon_workspace.send(Bytes::from_static(b"round trip")).await.unwrap();
    let response = tokio::time::timeout(Duration::from_secs(2), workspace.receive())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert_eq!(response.payload, b"round trip".as_slice());
    let server_snapshot = server.snapshot().await;
    assert_eq!(server_snapshot.state, ConnectionState::Connected);
    assert_eq!(server_snapshot.generation, snapshot.generation);
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(client.snapshot().await.generation, snapshot.generation);
    assert_eq!(server.snapshot().await.generation, snapshot.generation);
    mux_control
        .send_on(Lane::Interactive, Bytes::from_static(b"after mux reconnect"))
        .await
        .unwrap();
    let after_mux = tokio::time::timeout(Duration::from_secs(2), daemon_mux_control.receive())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert_eq!(after_mux.payload, b"after mux reconnect".as_slice());

    client.close().await.unwrap();
    registration.shutdown().await;
    relay_task.abort();
}

#[tokio::test(flavor = "current_thread")]
async fn native_relay_recovers_concurrent_clients_and_persistent_streams() {
    tokio::task::LocalSet::new()
        .run_until(async {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let relay_address = listener.local_addr().unwrap();
            let relay =
                Relay::new(RelayConfig { allow_open: true, ..RelayConfig::default() }).unwrap();
            let (listener, router) = relay.server_parts(listener);
            let relay_task = tokio::spawn(async move {
                axum::serve(listener, router).await.unwrap();
            });
            let proxy = DropProxy::start(relay_address).await;

            let state = tempdir().unwrap();
            let auth =
                AuthDatabase::load_or_create(state.path(), "relay-concurrent", false).unwrap();
            let (daemon, mut accepted) =
                cmux_remote::daemon::RemoteDaemon::new(auth.clone(), SessionLimits::default());
            let daemon_for_reregistration = daemon.clone();
            let endpoint = Url::parse(&format!("relay+ws://{}", proxy.address)).unwrap();
            let daemon_config = RelayDaemonConfig {
                endpoint: endpoint.clone(),
                slot: "concurrent-slot".into(),
                ticket: "open-daemon-ticket".into(),
                maximum_frame_bytes: 65_535,
                control_timeout: Duration::from_secs(1),
            };
            let mut registration =
                register_relay_daemon(daemon, daemon_config.clone()).await.unwrap();
            let provider = RelayProvider::new(RelayClientConfig {
                slot: "concurrent-slot".into(),
                ticket: "open-client-ticket".into(),
                maximum_frame_bytes: 65_535,
                control_timeout: Duration::from_secs(1),
            })
            .unwrap();
            let services = DaemonServices::new(WorkspaceService::new(), None);

            let mut clients = Vec::new();
            let mut client_services = Vec::new();
            let mut workspace_clients = Vec::new();
            let mut service_tasks = Vec::new();
            let client_identities =
                [StaticIdentity::generate().unwrap(), StaticIdentity::generate().unwrap()];
            for index in 0..5_u8 {
                let invitation =
                    auth.create_invitation(Duration::from_secs(60), vec![]).await.unwrap();
                let approver = tokio::spawn({
                    let auth = auth.clone();
                    async move {
                        let pending = auth.wait_for_pending(Duration::from_secs(5)).await.unwrap();
                        auth.approve(&pending[0].invitation_id).await.unwrap();
                    }
                });
                let session = SessionId([60 + index; 16]);
                let group = provider
                    .connect(ConnectRequest {
                        endpoint: endpoint.clone(),
                        session,
                        lane_policy: LanePolicy::Auto,
                        routing: Default::default(),
                    })
                    .await
                    .unwrap();
                let invitation_secret = invitation.secret_bytes().unwrap();
                let client = ClientConnection::connect(
                    group,
                    ClientConnectionConfig {
                        identity: client_identities[usize::from(index % 2)].clone(),
                        expected_daemon: Some(auth.identity().public_key()),
                        auth: ClientAuthMode::Invitation {
                            id: invitation.id,
                            secret: Zeroizing::new(invitation_secret),
                        },
                        device_name: format!("relay-concurrent-{index}"),
                        session,
                        lane_policy: LanePolicy::Auto,
                        limits: SessionLimits::default(),
                        reconnect: ReconnectPolicy {
                            initial_delay: Duration::from_millis(100),
                            maximum_delay: Duration::from_millis(500),
                            attempt_timeout: Duration::from_secs(10),
                            full_jitter: false,
                            heartbeat_interval: Some(Duration::from_millis(500)),
                            heartbeat_timeout: Duration::from_millis(1_500),
                            maximum_attempts: None,
                        },
                    },
                )
                .await
                .unwrap();
                approver.await.unwrap();
                let server = tokio::time::timeout(Duration::from_secs(5), accepted.recv())
                    .await
                    .unwrap()
                    .unwrap();
                service_tasks.push(tokio::task::spawn_local({
                    let services = services.clone();
                    async move { services.serve_client(server).await }
                }));
                let client_mux = ServiceMultiplexer::new(client.clone(), EndpointRole::Client);
                let workspace = WorkspaceClient::connect(client_mux.clone()).await.unwrap();
                assert!(matches!(
                    workspace.request(WorkspaceRequest::ListWorkspaces).await.unwrap(),
                    WorkspaceResponse::Workspaces { .. }
                ));
                clients.push(client);
                client_services.push(client_mux);
                workspace_clients.push(workspace);
            }

            proxy.wait_for_active(36).await;
            registration.shutdown().await;
            proxy.drop_all();
            tokio::time::sleep(Duration::from_millis(150)).await;
            registration =
                register_relay_daemon(daemon_for_reregistration, daemon_config).await.unwrap();
            let deadline = tokio::time::Instant::now() + RECONNECT_TEST_TIMEOUT;
            let recovered_generations = loop {
                let mut snapshots = Vec::with_capacity(clients.len());
                for client in &clients {
                    snapshots.push(client.snapshot().await);
                }
                if snapshots.iter().all(|snapshot| {
                    snapshot.state == ConnectionState::Connected
                        && (1..=MAXIMUM_EXPECTED_RECONNECT_GENERATION)
                            .contains(&snapshot.generation)
                }) {
                    break snapshots.iter().map(|snapshot| snapshot.generation).collect::<Vec<_>>();
                }
                assert!(
                    tokio::time::Instant::now() < deadline,
                    "concurrent relay clients did not recover exactly once: {snapshots:#?}"
                );
                tokio::time::sleep(Duration::from_millis(10)).await;
            };

            for workspace in &workspace_clients {
                assert!(matches!(
                    tokio::time::timeout(
                        Duration::from_secs(2),
                        workspace.request(WorkspaceRequest::ListWorkspaces),
                    )
                    .await
                    .unwrap()
                    .unwrap(),
                    WorkspaceResponse::Workspaces { .. }
                ));
            }

            tokio::time::sleep(Duration::from_millis(200)).await;
            for (client, expected_generation) in clients.iter().zip(&recovered_generations) {
                let snapshot = client.snapshot().await;
                assert_eq!(snapshot.state, ConnectionState::Connected);
                assert_eq!(snapshot.generation, *expected_generation);
            }

            drop(workspace_clients);
            for client_service in client_services {
                client_service.shutdown().await;
            }
            for client in clients {
                client.close().await.unwrap();
            }
            for task in service_tasks {
                let _ = tokio::time::timeout(Duration::from_secs(2), task).await;
            }
            registration.shutdown().await;
            relay_task.abort();
        })
        .await;
}

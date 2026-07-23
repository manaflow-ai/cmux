use std::collections::BTreeMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
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
use cmux_remote::service::{EndpointRole, ServiceMultiplexer};
use cmux_remote::session::SessionLimits;
use cmux_remote_protocol::{FrameFlags, Lane, LanePolicy, Service, SessionId};
use tempfile::tempdir;
use tokio::io::copy_bidirectional;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::watch;
use url::Url;
use zeroize::Zeroizing;

struct DropProxy {
    address: std::net::SocketAddr,
    cut: watch::Sender<u64>,
    active: Arc<AtomicUsize>,
    task: tokio::task::JoinHandle<()>,
}

impl DropProxy {
    async fn start(upstream: std::net::SocketAddr) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let (cut, _) = watch::channel(0_u64);
        let active = Arc::new(AtomicUsize::new(0));
        let task = tokio::spawn({
            let cut = cut.clone();
            let active = active.clone();
            async move {
                loop {
                    let Ok((mut downstream, _)) = listener.accept().await else { return };
                    let mut cut = cut.subscribe();
                    let active = active.clone();
                    tokio::spawn(async move {
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
        Self { address, cut, active, task }
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
}

impl Drop for DropProxy {
    fn drop(&mut self) {
        self.task.abort();
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
    let mut generation = client.subscribe_generation();
    proxy.drop_all();
    tokio::time::timeout(Duration::from_secs(10), async {
        while *generation.borrow() == 0 {
            generation.changed().await.unwrap();
        }
    })
    .await
    .unwrap();
    let snapshot = client.snapshot().await;
    assert_eq!(snapshot.state, ConnectionState::Connected);
    assert!(snapshot.generation > 0);

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

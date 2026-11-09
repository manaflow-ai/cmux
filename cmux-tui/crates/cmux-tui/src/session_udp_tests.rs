use super::*;

use std::sync::atomic::AtomicUsize;

use cmux_remote::client::WorkspaceClient;
use cmux_remote::connection::{
    ClientConnection, ClientConnectionConfig, ReconnectGroupSource, ReconnectPolicy,
};
use cmux_remote::crypto::{ClientAuthMode, StaticIdentity};
use cmux_remote::daemon::{InboundLink, RemoteDaemon, serve_direct_websocket};
use cmux_remote::identity::AuthDatabase;
use cmux_remote::provider::{ConnectRequest, DirectWebSocketProvider, TransportProvider};
use cmux_remote::service::{EndpointRole, ServiceMultiplexer};
use cmux_remote::services::DaemonServices;
use cmux_remote::session::SessionLimits;
use cmux_remote::workspace::WorkspaceService;
use cmux_remote_protocol::{
    LanePolicy, RemoteCapability, SessionId, WorkspaceRequest, WorkspaceResponse,
};
use url::Url;

const FRAME: usize = 65_535;

#[test]
fn keys_round_trip_as_hex_and_refuse_anything_else() {
    let key = [0xa5u8; 32];
    assert_eq!(unhex32(&hex(&key)), Some(key));
    assert_eq!(unhex32(&"ab".repeat(31)), None);
    assert_eq!(unhex32(&format!("{}zz", "ab".repeat(31))), None);
    assert_eq!(unhex32(&"é".repeat(32)), None);
}

#[test]
fn repair_defaults_to_dup_and_refuses_unknown_modes() {
    assert!(repair_mode(None).is_some());
    assert_eq!(repair_mode(None), UltraMode::parse("dup"));
    assert_eq!(repair_mode(Some("fec:8:2")), UltraMode::parse("fec:8:2"));
    assert_eq!(repair_mode(Some("louder")), None);
}

#[test]
fn the_flag_needs_an_object_and_keeps_at_most_four_stun_servers() {
    assert_eq!(SessionUdpFlag::parse(None), None);
    assert_eq!(SessionUdpFlag::parse(Some(&serde_json::json!(true))), None);
    assert_eq!(
        SessionUdpFlag::parse(Some(&serde_json::json!({}))),
        Some(SessionUdpFlag::default())
    );
    let many: Vec<String> = (0..9).map(|i| format!("stun{i}.example:3478")).collect();
    let flag = SessionUdpFlag::parse(Some(&serde_json::json!({"stun": many, "repair": "fec"})))
        .expect("flag");
    assert_eq!(flag.stun.len(), MAX_STUN);
    assert_eq!(flag.repair.as_deref(), Some("fec"));
    // A repair this build cannot run turns the whole flag off, not the repair.
    assert_eq!(SessionUdpFlag::parse(Some(&serde_json::json!({"repair": "louder"}))), None);
}

/// The carrier stand-in: a direct WebSocket to the same daemon. Counts the
/// times the session came back to it.
struct Carrier {
    provider: DirectWebSocketProvider,
    endpoint: Url,
    session: SessionId,
    redials: AtomicUsize,
}

impl Carrier {
    async fn group(&self) -> Arc<dyn LinkGroup> {
        self.provider
            .connect(ConnectRequest {
                endpoint: self.endpoint.clone(),
                session: self.session,
                lane_policy: LanePolicy::Single,
                routing: Default::default(),
            })
            .await
            .expect("carrier group")
    }
}

#[async_trait]
impl ReconnectGroupSource for Carrier {
    async fn next_group(&self) -> Result<Arc<dyn LinkGroup>, ProviderError> {
        self.redials.fetch_add(1, Ordering::Relaxed);
        Ok(self.group().await)
    }
}

struct Rig {
    client: Arc<ClientConnection>,
    workspace: Arc<WorkspaceClient>,
    carrier: Arc<Carrier>,
    udp_links: Arc<AtomicUsize>,
    _auth_state: tempfile::TempDir,
    _server: cmux_remote::daemon::DirectWebSocketServer,
}

/// A daemon on a WebSocket "carrier", a client session on it, and the
/// daemon's workspace service with `session-udp-v1` when `udp` is set.
async fn rig(udp: bool) -> Rig {
    let auth_state = tempfile::tempdir().expect("tempdir");
    let auth = AuthDatabase::load_or_create(auth_state.path(), "session-udp", false).expect("auth");
    let (daemon, mut accepted) = RemoteDaemon::new(auth.clone(), SessionLimits::default());
    let workspace_service = WorkspaceService::new();
    let udp_links = Arc::new(AtomicUsize::new(0));
    if udp {
        let accept_daemon = daemon.clone();
        let counted = udp_links.clone();
        workspace_service.set_session_udp(DaemonRoutes::new(Arc::new(move |link| {
            counted.fetch_add(1, Ordering::Relaxed);
            let daemon = accept_daemon.clone();
            tokio::spawn(async move {
                let inbound = InboundLink::network(link, cmux_remote::crypto::NetworkPeer::Udp);
                let _ = daemon.accept(inbound).await;
            });
        })));
    }
    let server = serve_direct_websocket(daemon, "127.0.0.1:0".parse().expect("addr"), FRAME, false)
        .await
        .expect("serve");
    let endpoint = Url::parse(&format!("ws://{}/v1/link", server.local_addr())).expect("url");
    let session = SessionId([0x5a; 16]);
    let carrier = Arc::new(Carrier {
        provider: DirectWebSocketProvider::new(FRAME),
        endpoint,
        session,
        redials: AtomicUsize::new(0),
    });
    let invitation =
        auth.create_invitation(Duration::from_secs(60), Vec::new()).await.expect("inv");
    let secret = invitation.secret_bytes().expect("secret");
    let approver = tokio::spawn({
        let auth = auth.clone();
        async move {
            let pending = auth.wait_for_pending(Duration::from_secs(5)).await.expect("pending");
            auth.approve(&pending[0].invitation_id).await.expect("approve");
        }
    });
    let source: Arc<dyn ReconnectGroupSource> = carrier.clone();
    let client = ClientConnection::connect_with_reconnect_groups(
        carrier.group().await,
        ClientConnectionConfig {
            identity: StaticIdentity::generate().expect("identity"),
            expected_daemon: Some(auth.identity().public_key()),
            auth: ClientAuthMode::Invitation { id: invitation.id, secret: Zeroizing::new(secret) },
            device_name: "session-udp-client".into(),
            session,
            lane_policy: LanePolicy::Single,
            limits: SessionLimits::default(),
            reconnect: ReconnectPolicy::default(),
        },
        Some(source),
    )
    .await
    .expect("connect");
    approver.await.expect("approver");
    let daemon_client = accepted.recv().await.expect("daemon client");
    let services = DaemonServices::new(workspace_service, None);
    tokio::spawn(async move { services.serve_client(daemon_client).await });
    let multiplexer = ServiceMultiplexer::new(client.clone(), EndpointRole::Client);
    let workspace = WorkspaceClient::connect(multiplexer).await.expect("workspace");
    Rig { client, workspace, carrier, udp_links, _auth_state: auth_state, _server: server }
}

async fn capabilities(workspace: &WorkspaceClient) -> Vec<RemoteCapability> {
    match workspace.request(WorkspaceRequest::Capabilities).await.expect("capabilities") {
        WorkspaceResponse::Capabilities { capabilities } => capabilities,
        other => panic!("unexpected {other:?}"),
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_daemon_without_the_handler_does_not_advertise_it_and_refuses_an_offer() {
    tokio::time::timeout(Duration::from_secs(60), async {
        let rig = rig(false).await;
        assert!(!capabilities(&rig.workspace).await.contains(&RemoteCapability::SessionUdpV1));
        let offer = ClientOffer::new(&[], None).await.expect("offer");
        let refused = rig
            .workspace
            .request(WorkspaceRequest::SessionUdpOffer { offer: offer.offer })
            .await
            .expect_err("no handler");
        assert_eq!(refused.code, "unsupported");
        let _ = rig.client.close().await;
    })
    .await
    .expect("test timed out");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_session_moves_onto_udp_and_falls_back_to_the_carrier_when_it_goes_dark() {
    tokio::time::timeout(Duration::from_secs(90), async {
        let rig = rig(true).await;
        assert!(capabilities(&rig.workspace).await.contains(&RemoteCapability::SessionUdpV1));
        let before = *rig.client.subscribe_generation().borrow();

        let flag = SessionUdpFlag::default();
        let deadline = tokio::time::Instant::now() + ATTEMPT_DEADLINE;
        let group = attempt_once(&rig.client, &rig.workspace, &flag, deadline)
            .await
            .expect("the session moved onto the route");
        let on_udp = *rig.client.subscribe_generation().borrow();
        assert!(on_udp > before, "the move is a resume: {before} -> {on_udp}");
        assert!(rig.udp_links.load(Ordering::Relaxed) >= 1, "the daemon took a link over udp");
        assert_eq!(rig.carrier.redials.load(Ordering::Relaxed), 0);
        // Requests ride the route now.
        for _ in 0..20 {
            capabilities(&rig.workspace).await;
        }

        group.go_dark();
        // The heartbeat sees the silence, the redial skips the dark route and
        // takes the carrier, and the stream that was open carries on.
        capabilities(&rig.workspace).await;
        let mut generation = rig.client.subscribe_generation();
        let _ = generation.wait_for(|g| *g > on_udp).await;
        assert!(rig.carrier.redials.load(Ordering::Relaxed) >= 1, "back on the carrier");
        assert!(group.is_down());
        for _ in 0..5 {
            capabilities(&rig.workspace).await;
        }
        let _ = rig.client.close().await;
    })
    .await
    .expect("test timed out");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_route_whose_peer_never_answers_keeps_the_session_on_the_carrier() {
    tokio::time::timeout(Duration::from_secs(60), async {
        let rig = rig(true).await;
        let before = *rig.client.subscribe_generation().borrow();
        let offer = ClientOffer::new(&[], None).await.expect("offer");
        let answer = match rig
            .workspace
            .request(WorkspaceRequest::SessionUdpOffer { offer: offer.offer.clone() })
            .await
            .expect("answer")
        {
            WorkspaceResponse::SessionUdpAnswer { answer } => answer,
            other => panic!("unexpected {other:?}"),
        };
        // No candidates sent back, and none of the daemon's used: no path.
        let mut start =
            ClientStart::new(offer, &SessionUdpAnswer { candidates: Vec::new(), ..answer })
                .expect("start");
        let _ = start.candidates().await;
        let refused = start.established(tokio::time::Instant::now() + Duration::from_secs(3)).await;
        assert!(refused.is_err());
        assert_eq!(*rig.client.subscribe_generation().borrow(), before);
        capabilities(&rig.workspace).await;
        let _ = rig.client.close().await;
    })
    .await
    .expect("test timed out");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_daemon_refuses_bad_keys_and_unknown_routes() {
    let routes = DaemonRoutes::new(Arc::new(|_| {}));
    use cmux_remote::session_udp::SessionUdpHandler as _;
    let bad = SessionUdpOffer {
        link_key: "00".into(),
        wg_key: hex(&[1; 32]),
        stun: Vec::new(),
        repair: None,
    };
    assert_eq!(routes.offer(bad).await.expect_err("bad key").code, "invalid-request");
    let louder = SessionUdpOffer {
        link_key: hex(&[1; 32]),
        wg_key: hex(&[2; 32]),
        stun: Vec::new(),
        repair: Some("louder".into()),
    };
    assert_eq!(routes.offer(louder).await.expect_err("bad repair").code, "invalid-request");
    assert_eq!(
        routes.candidates("nope", Vec::new()).await.expect_err("no route").code,
        "not-found"
    );
    assert_eq!(routes.route_count(), 0);
}

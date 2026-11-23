//! A carrier grant over a real daemon: the Mac's Noise key, a grant the
//! platform signed for it, and the daemon's grant verifier (cmux-link's
//! `CarrierGrantVerifier`, installed at start). Keys are generated per test.

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use bytes::Bytes;
use cmux_link::carrier_grant::{CarrierGrantVerifier, GRANT_TYP, noise_key_digest};
use cmux_link::keyset::Keyset;
use cmux_remote::connection::{ClientConnection, ClientConnectionConfig, ReconnectPolicy};
use cmux_remote::crypto::{ClientAuthMode, StaticIdentity};
use cmux_remote::daemon::{DirectWebSocketServer, RemoteDaemon, ServerConnection};
use cmux_remote::grant::{grant_device_id, is_grant_device_id};
use cmux_remote::identity::AuthDatabase;
use cmux_remote::observability::ConnectionState;
use cmux_remote::provider::{ConnectRequest, DirectWebSocketProvider, TransportProvider};
use cmux_remote::session::SessionLimits;
use cmux_remote_protocol::{FrameFlags, Lane, LanePolicy, Service, SessionId};
use ring::signature::{Ed25519KeyPair, KeyPair as _};
use serde_json::{Value, json};
use tempfile::tempdir;
use tokio::sync::mpsc;
use url::Url;
use zeroize::Zeroizing;

const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
const ISSUER: &str = "cmux:cloud:test";
const MACHINE: &str = "vm_00000000000000000001";
const NOW: u64 = 1_800_000_000;
const SUBJECT: &str = "user_00000000000000000001";
const TEAM: &str = "team_00000000000000000001";

struct Signer(Ed25519KeyPair);

impl Signer {
    fn generate() -> Self {
        let pkcs8 = Ed25519KeyPair::generate_pkcs8(&ring::rand::SystemRandom::new()).unwrap();
        Self(Ed25519KeyPair::from_pkcs8(pkcs8.as_ref()).unwrap())
    }

    fn keyset(&self) -> Keyset {
        let public: [u8; 32] = self.0.public_key().as_ref().try_into().unwrap();
        Keyset {
            version: "0123456789abcdef".into(),
            keys: [("k1".to_string(), public)].into_iter().collect(),
        }
    }

    fn sign(&self, typ: &str, claims: &Value) -> String {
        let header = json!({"alg": "EdDSA", "kid": "k1", "typ": typ});
        let message = format!(
            "{}.{}",
            URL_SAFE_NO_PAD.encode(serde_json::to_vec(&header).unwrap()),
            URL_SAFE_NO_PAD.encode(serde_json::to_vec(claims).unwrap())
        );
        let signature = self.0.sign(message.as_bytes());
        format!("{message}.{}", URL_SAFE_NO_PAD.encode(signature.as_ref()))
    }

    fn grant(&self, noise_key: &[u8; 32], jti: u8) -> String {
        self.sign(GRANT_TYP, &grant_claims(noise_key, jti))
    }
}

fn grant_claims(noise_key: &[u8; 32], jti: u8) -> Value {
    json!({
        "iss": ISSUER,
        "aud": MACHINE,
        "team": TEAM,
        "sub": SUBJECT,
        "svc": ["mux-control", "terminal-bytes-v1", "a-service-from-the-future"],
        "nk": noise_key_digest(noise_key),
        "jti": URL_SAFE_NO_PAD.encode([jti; 16]),
        "iat": NOW - 5,
        "exp": NOW + 60,
    })
}

struct Daemon {
    auth: Arc<AuthDatabase>,
    server: DirectWebSocketServer,
    accepted: mpsc::Receiver<Arc<ServerConnection>>,
    _state: tempfile::TempDir,
}

async fn daemon(verifier: Option<CarrierGrantVerifier>) -> Daemon {
    use cmux_remote::daemon::{DirectWebSocketOptions, serve_direct_websocket_with_options};
    let state = tempdir().unwrap();
    let auth = AuthDatabase::load_or_create(state.path(), "carrier-grant", false).unwrap();
    if let Some(verifier) = verifier {
        auth.set_grant_verifier(Arc::new(verifier)).unwrap();
    }
    let (daemon, accepted) = RemoteDaemon::new(auth.clone(), SessionLimits::default());
    let server = serve_direct_websocket_with_options(
        daemon,
        "127.0.0.1:0".parse().unwrap(),
        65_535,
        DirectWebSocketOptions::default(),
    )
    .await
    .unwrap();
    Daemon { auth, server, accepted, _state: state }
}

fn verifier(signer: &Signer, now: &Arc<AtomicU64>) -> CarrierGrantVerifier {
    let clock = now.clone();
    CarrierGrantVerifier::new(
        ISSUER,
        MACHINE,
        TEAM,
        signer.keyset(),
        move || Some(clock.load(Ordering::SeqCst)),
        64,
    )
    .unwrap()
}

async fn group(daemon: &Daemon, session: SessionId) -> Arc<dyn cmux_remote::provider::LinkGroup> {
    let endpoint =
        Url::parse(&format!("ws://127.0.0.1:{}/v1/link", daemon.server.local_addr().port()))
            .unwrap();
    DirectWebSocketProvider::new(65_535)
        .connect(ConnectRequest {
            endpoint,
            session,
            lane_policy: LanePolicy::Isolated,
            routing: Default::default(),
        })
        .await
        .unwrap()
}

async fn dial(
    daemon: &Daemon,
    identity: StaticIdentity,
    token: String,
    session: SessionId,
) -> Result<Arc<ClientConnection>, cmux_remote::connection::ConnectionError> {
    let group = group(daemon, session).await;
    tokio::time::timeout(
        CONNECT_TIMEOUT,
        ClientConnection::connect(
            group,
            ClientConnectionConfig {
                identity,
                expected_daemon: Some(daemon.auth.identity().public_key()),
                auth: ClientAuthMode::Grant { token: Zeroizing::new(token) },
                device_name: "carrier-grant-client".into(),
                session,
                lane_policy: LanePolicy::Isolated,
                limits: SessionLimits::default(),
                reconnect: ReconnectPolicy { maximum_attempts: Some(1), ..Default::default() },
            },
        ),
    )
    .await
    .expect("grant dial timed out")
}

/// A valid grant admits a session with exactly its known services, under
/// `carrier:<sub>:<keyfp>`, across every physical lane link of the attempt;
/// the session stays up after the grant's `exp`, and the spent grant cannot
/// open a second session.
#[tokio::test]
async fn a_valid_grant_admits_and_the_session_outlives_its_expiry() {
    let signer = Signer::generate();
    let now = Arc::new(AtomicU64::new(NOW));
    let mut daemon = daemon(Some(verifier(&signer, &now))).await;
    let identity = StaticIdentity::generate().unwrap();
    let key = identity.public_key();
    let token = signer.grant(&key, 1);

    let client = dial(&daemon, identity.clone(), token.clone(), SessionId([11; 16]))
        .await
        .expect("a valid grant was refused");
    let accepted =
        tokio::time::timeout(CONNECT_TIMEOUT, daemon.accepted.recv()).await.unwrap().unwrap();
    let snapshot = accepted.snapshot().await;
    assert_eq!(snapshot.device_id, grant_device_id(SUBJECT, &key));
    assert!(is_grant_device_id(&snapshot.device_id));
    assert!(snapshot.physical_link_count >= 1);
    let authority = accepted.service_authority();
    assert!(authority.allows(Service::MuxControl));
    assert!(authority.allows(Service::TerminalBytes));
    assert!(!authority.allows(Service::WorkspaceRpc));
    assert!(!authority.allows(Service::TcpTunnel));

    // Past the grant's expiry, the admitted session carries frames as before.
    now.store(NOW + 3600, Ordering::SeqCst);
    client
        .send(Lane::Interactive, 1, Bytes::from_static(b"after-exp"), FrameFlags::empty())
        .await
        .unwrap();
    assert_eq!(accepted.receive().await.unwrap().unwrap().payload, b"after-exp".as_slice());
    assert_eq!(client.snapshot().await.state, ConnectionState::Connected);

    // A resume on a new carrier needs no grant (the old one is spent and
    // expired): the same key re-enters its own session, under the same id.
    let replacement = group(&daemon, SessionId([11; 16])).await;
    tokio::time::timeout(CONNECT_TIMEOUT, client.reconnect(replacement))
        .await
        .expect("grant-free resume timed out")
        .expect("a resume of a grant-admitted session was refused");
    assert_eq!(client.snapshot().await.state, ConnectionState::Connected);
    assert_eq!(accepted.snapshot().await.device_id, grant_device_id(SUBJECT, &key));
    assert!(accepted.snapshot().await.generation >= 1);
    client
        .send(Lane::Interactive, 2, Bytes::from_static(b"after-resume"), FrameFlags::empty())
        .await
        .unwrap();
    assert_eq!(accepted.receive().await.unwrap().unwrap().payload, b"after-resume".as_slice());

    // The same grant, still within its life, cannot open another session.
    now.store(NOW, Ordering::SeqCst);
    dial(&daemon, identity, token, SessionId([12; 16]))
        .await
        .expect_err("a spent grant opened a second session");

    client.close().await.unwrap();
    daemon.server.shutdown().await.unwrap();
}

/// One raw handshake carrying every lane on one physical link, so the
/// test picks the connection attempt (the client library draws a fresh one).
async fn raw_link(
    daemon: &Daemon,
    identity: &StaticIdentity,
    token: &str,
    session: SessionId,
    attempt: cmux_remote::crypto::ConnectionAttemptId,
) -> Result<cmux_remote::crypto::SecureLink, cmux_remote::crypto::CryptoError> {
    use cmux_remote::crypto::{ClientHandshake, initiate_secure_link};
    use cmux_remote::provider::LinkRequest;
    let group = group(daemon, session).await;
    let physical = group.open(LinkRequest { lane: Lane::ALL[0], generation: 0 }).await.unwrap();
    tokio::time::timeout(
        CONNECT_TIMEOUT,
        initiate_secure_link(
            physical,
            ClientHandshake {
                identity: identity.clone(),
                expected_daemon: Some(daemon.auth.identity().public_key()),
                auth: ClientAuthMode::Grant { token: Zeroizing::new(token.to_owned()) },
                device_name: "carrier-grant-client".into(),
                session,
                lane: Lane::ALL[0],
                lanes: Lane::ALL.to_vec(),
                generation: 0,
                connection_attempt: attempt,
                resume: Lane::ALL.into_iter().map(|lane| (lane, 0)).collect(),
                handshake_timeout: CONNECT_TIMEOUT,
            },
        ),
    )
    .await
    .expect("raw grant handshake timed out")
}

/// Review BLOCK at 56ed18ef: a session formed from a grant closed, and the
/// same token, key, session, generation and connection attempt (the same
/// link group) opened another session before the grant expired. Once a
/// grant's session registers, its link group admits nothing more.
#[tokio::test]
async fn a_closed_grant_session_cannot_be_opened_again_from_the_same_link_group() {
    use cmux_remote::crypto::ConnectionAttemptId;
    let signer = Signer::generate();
    let now = Arc::new(AtomicU64::new(NOW));
    let mut daemon = daemon(Some(verifier(&signer, &now))).await;
    let identity = StaticIdentity::generate().unwrap();
    let token = signer.grant(&identity.public_key(), 1);
    let session = SessionId([13; 16]);
    let attempt = ConnectionAttemptId([9; 16]);

    let first = raw_link(&daemon, &identity, &token, session, attempt)
        .await
        .expect("a valid grant was refused");
    let accepted =
        tokio::time::timeout(CONNECT_TIMEOUT, daemon.accepted.recv()).await.unwrap().unwrap();
    accepted.close().await.unwrap();
    drop(first);

    raw_link(&daemon, &identity, &token, session, attempt)
        .await
        .expect_err("a closed grant session's link group opened a session again");
    assert!(
        tokio::time::timeout(Duration::from_millis(300), daemon.accepted.recv()).await.is_err(),
        "the daemon registered a second session from one grant"
    );
    daemon.server.shutdown().await.unwrap();
}

/// Default deny: a daemon with no grant verifier refuses every grant.
#[tokio::test]
async fn a_daemon_without_a_verifier_refuses_grants() {
    let signer = Signer::generate();
    let daemon = daemon(None).await;
    let identity = StaticIdentity::generate().unwrap();
    let token = signer.grant(&identity.public_key(), 1);
    let error = dial(&daemon, identity, token, SessionId([21; 16]))
        .await
        .expect_err("a daemon with no verifier admitted a grant");
    assert!(error.to_string().contains("not accepted"), "{error}");
    daemon.server.shutdown().await.unwrap();
}

/// A grant for another Noise key, and a Native link token from the same
/// keyset, are refused by the daemon.
#[tokio::test]
async fn a_grant_for_another_key_or_a_link_token_is_refused() {
    let signer = Signer::generate();
    let now = Arc::new(AtomicU64::new(NOW));
    let daemon = daemon(Some(verifier(&signer, &now))).await;

    let identity = StaticIdentity::generate().unwrap();
    let stolen = signer.grant(&StaticIdentity::generate().unwrap().public_key(), 2);
    let error = dial(&daemon, identity.clone(), stolen, SessionId([31; 16]))
        .await
        .expect_err("a grant for another key was admitted");
    assert!(error.to_string().contains("noise_key"), "{error}");

    let link_token = signer.sign("cmux-link+jwt", &grant_claims(&identity.public_key(), 3));
    let error = dial(&daemon, identity, link_token, SessionId([32; 16]))
        .await
        .expect_err("a link token was admitted as a grant");
    assert!(error.to_string().contains("header_typ"), "{error}");
    daemon.server.shutdown().await.unwrap();
}

/// A grant for another machine or another team, signed by the same keyset,
/// is refused: the daemon's verifier takes both from its own bind record.
#[tokio::test]
async fn a_grant_for_another_machine_or_team_is_refused() {
    let signer = Signer::generate();
    let now = Arc::new(AtomicU64::new(NOW));
    let daemon = daemon(Some(verifier(&signer, &now))).await;
    for (field, value, reason, session) in [
        ("aud", "vm_00000000000000000002", "audience", 41),
        ("team", "team_00000000000000000002", "team", 42),
    ] {
        let identity = StaticIdentity::generate().unwrap();
        let mut claims = grant_claims(&identity.public_key(), session);
        claims[field] = json!(value);
        let error =
            dial(&daemon, identity, signer.sign(GRANT_TYP, &claims), SessionId([session; 16]))
                .await
                .expect_err("a grant for another machine or team was admitted");
        assert!(error.to_string().contains(reason), "{field}: {error}");
    }
    daemon.server.shutdown().await.unwrap();
}

/// Without a grant, only a resume of a key a grant admitted gets in: a new
/// session (generation 0) is refused, and so is a resume by a stranger key.
#[tokio::test]
async fn without_a_grant_only_a_known_key_may_resume() {
    use cmux_remote::crypto::{
        AuthKind, AuthRequest, ConnectionAttemptId, InboundAuthEvidence, NetworkPeer,
        ServerAuthenticator,
    };
    let signer = Signer::generate();
    let now = Arc::new(AtomicU64::new(NOW));
    let daemon = daemon(Some(verifier(&signer, &now))).await;
    let request = |key: [u8; 32], generation: u64| AuthRequest {
        mode: AuthKind::Grant,
        invitation_id: None,
        grant: None,
        connection_attempt: ConnectionAttemptId([5; 16]),
        device_public_key: key,
        device_name: "no-grant".into(),
        session: SessionId([51; 16]),
        lane: Lane::Interactive,
        lanes: vec![Lane::Interactive],
        generation,
        inbound: InboundAuthEvidence::Network(NetworkPeer::Tcp),
    };
    let stranger = StaticIdentity::generate().unwrap().public_key();
    let error = daemon.auth.authorize(request(stranger, 0)).await.unwrap_err();
    assert!(error.contains("needs a grant"), "{error}");
    let error = daemon.auth.authorize(request(stranger, 1)).await.unwrap_err();
    assert!(error.contains("no carrier grant admitted"), "{error}");
    daemon.server.shutdown().await.unwrap();
}

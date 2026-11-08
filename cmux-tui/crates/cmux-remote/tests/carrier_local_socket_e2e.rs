//! The `local-socket` service over a real grant-admitted session: only the
//! machine owner's grant (`vmk: "owner"`) reaches an allowlisted Unix socket
//! (the Cloud desktop, `/run/cmux-rd/desktop.sock`). Keys are generated per
//! test.
#![cfg(unix)]

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
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
use cmux_remote::identity::AuthDatabase;
use cmux_remote::provider::{ConnectRequest, DirectWebSocketProvider, TransportProvider};
use cmux_remote::service::{EndpointRole, ServiceMultiplexer};
use cmux_remote::services::DaemonServices;
use cmux_remote::session::SessionLimits;
use cmux_remote::workspace::WorkspaceService;
use cmux_remote_protocol::{LanePolicy, Service, ServiceControl, SessionId};
use ring::signature::{Ed25519KeyPair, KeyPair as _};
use serde_json::json;
use tempfile::tempdir;
use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
use tokio::sync::mpsc;
use url::Url;
use zeroize::Zeroizing;

const TIMEOUT: Duration = Duration::from_secs(5);
const ISSUER: &str = "cmux:cloud:test";
const MACHINE: &str = "vm_00000000000000000001";
const NOW: u64 = 1_800_000_000;
const TEAM: &str = "team_00000000000000000001";
/// The `svc` of most test grants: it names `local-socket` too, which only
/// `vmk: "owner"` may honor.
const SVC: &[&str] = &["mux-control", "local-socket"];

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

    /// A grant for `noise_key` with `svc`; `vmk` is left out when `None`.
    fn grant_for(&self, noise_key: &[u8; 32], jti: u8, vmk: Option<&str>, svc: &[&str]) -> String {
        let mut claims = json!({
            "iss": ISSUER,
            "aud": MACHINE,
            "team": TEAM,
            "sub": "user_00000000000000000001",
            "svc": svc,
            "nk": noise_key_digest(noise_key),
            "jti": URL_SAFE_NO_PAD.encode([jti; 16]),
            "iat": NOW - 5,
            "exp": NOW + 60,
        });
        if let Some(vmk) = vmk {
            claims["vmk"] = json!(vmk);
        }
        let header = json!({"alg": "EdDSA", "kid": "k1", "typ": GRANT_TYP});
        let message = format!(
            "{}.{}",
            URL_SAFE_NO_PAD.encode(serde_json::to_vec(&header).unwrap()),
            URL_SAFE_NO_PAD.encode(serde_json::to_vec(&claims).unwrap())
        );
        let signature = self.0.sign(message.as_bytes());
        format!("{message}.{}", URL_SAFE_NO_PAD.encode(signature.as_ref()))
    }
}

struct Daemon {
    auth: Arc<AuthDatabase>,
    server: DirectWebSocketServer,
    accepted: mpsc::Receiver<Arc<ServerConnection>>,
    _state: tempfile::TempDir,
}

async fn daemon(signer: &Signer) -> Daemon {
    use cmux_remote::daemon::{DirectWebSocketOptions, serve_direct_websocket_with_options};
    let state = tempdir().unwrap();
    let auth = AuthDatabase::load_or_create(state.path(), "carrier-local-socket", false).unwrap();
    let clock = Arc::new(AtomicU64::new(NOW));
    let verifier = CarrierGrantVerifier::new(
        ISSUER,
        MACHINE,
        TEAM,
        signer.keyset(),
        move || Some(clock.load(Ordering::SeqCst)),
        64,
    )
    .unwrap();
    auth.set_grant_verifier(Arc::new(verifier)).unwrap();
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

/// A Unix socket that answers each connection's bytes upper-cased.
fn echo_socket(path: &Path) -> tokio::task::JoinHandle<()> {
    let listener = tokio::net::UnixListener::bind(path).unwrap();
    tokio::spawn(async move {
        while let Ok((mut socket, _)) = listener.accept().await {
            tokio::spawn(async move {
                let mut buffer = [0_u8; 64];
                while let Ok(size) = socket.read(&mut buffer).await {
                    if size == 0
                        || socket.write_all(&buffer[..size].to_ascii_uppercase()).await.is_err()
                    {
                        break;
                    }
                }
            });
        }
    })
}

/// Dials `daemon` with a grant carrying `vmk`, serves the session with
/// `allowlist`, opens `local-socket` at `path`, and answers the daemon's
/// open response and, when opened, the echo of `ping`.
async fn open_local_socket(
    daemon: &mut Daemon,
    signer: &Signer,
    vmk: Option<&str>,
    allowlist: Vec<PathBuf>,
    path: &Path,
    jti: u8,
    through_bridge: bool,
) -> (ServiceControl, Option<Vec<u8>>) {
    open_local_socket_with(daemon, signer, vmk, SVC, allowlist, path, jti, through_bridge).await
}

/// [`open_local_socket`] with the grant's `svc` list.
#[allow(clippy::too_many_arguments)]
async fn open_local_socket_with(
    daemon: &mut Daemon,
    signer: &Signer,
    vmk: Option<&str>,
    svc: &[&str],
    allowlist: Vec<PathBuf>,
    path: &Path,
    jti: u8,
    through_bridge: bool,
) -> (ServiceControl, Option<Vec<u8>>) {
    let identity = StaticIdentity::generate().unwrap();
    let token = signer.grant_for(&identity.public_key(), jti, vmk, svc);
    let session = SessionId([jti; 16]);
    let endpoint =
        Url::parse(&format!("ws://127.0.0.1:{}/v1/link", daemon.server.local_addr().port()))
            .unwrap();
    let group = DirectWebSocketProvider::new(65_535)
        .connect(ConnectRequest {
            endpoint,
            session,
            lane_policy: LanePolicy::Isolated,
            routing: Default::default(),
        })
        .await
        .unwrap();
    let client = tokio::time::timeout(
        TIMEOUT,
        ClientConnection::connect(
            group,
            ClientConnectionConfig {
                identity,
                expected_daemon: Some(daemon.auth.identity().public_key()),
                auth: ClientAuthMode::Grant { token: Zeroizing::new(token) },
                device_name: "carrier-local-socket".into(),
                session,
                lane_policy: LanePolicy::Isolated,
                limits: SessionLimits::default(),
                reconnect: ReconnectPolicy { maximum_attempts: Some(1), ..Default::default() },
            },
        ),
    )
    .await
    .unwrap()
    .expect("the grant was refused");
    let server = tokio::time::timeout(TIMEOUT, daemon.accepted.recv()).await.unwrap().unwrap();
    let services = DaemonServices::with_local_sockets(WorkspaceService::new(), None, allowlist);
    let local = tokio::task::LocalSet::new();
    local
        .run_until(async {
            let serving = tokio::task::spawn_local({
                let services = services.clone();
                async move { services.serve_client(server).await }
            });
            let multiplexer = ServiceMultiplexer::new(client.clone(), EndpointRole::Client);
            if through_bridge {
                let answer = through_client_bridge(&multiplexer, path).await;
                multiplexer.shutdown().await;
                client.close().await.unwrap();
                serving.abort();
                return answer;
            }
            let metadata = BTreeMap::from([("path".to_owned(), path.display().to_string())]);
            let stream = multiplexer.open(Service::LocalSocket, metadata).await.unwrap();
            let response =
                tokio::time::timeout(TIMEOUT, stream.receive()).await.unwrap().unwrap().unwrap();
            let control: ServiceControl = serde_json::from_slice(&response.payload).unwrap();
            let echo = if matches!(control, ServiceControl::Opened { .. }) {
                stream.send(Bytes::from_static(b"desktop")).await.unwrap();
                let chunk = tokio::time::timeout(TIMEOUT, stream.receive())
                    .await
                    .unwrap()
                    .unwrap()
                    .unwrap();
                Some(chunk.payload.to_vec())
            } else {
                None
            };
            multiplexer.shutdown().await;
            client.close().await.unwrap();
            serving.abort();
            (control, echo)
        })
        .await
}

/// [`open_local_socket`]'s answer the way the dial uses it: the opened
/// stream bridged to a byte pipe, or the daemon's refusal (code `bridge`).
async fn through_client_bridge(
    multiplexer: &Arc<ServiceMultiplexer>,
    path: &Path,
) -> (ServiceControl, Option<Vec<u8>>) {
    use cmux_remote::bridge::{BridgeError, bridge_raw_stream, open_local_socket};
    match open_local_socket(multiplexer, &path.display().to_string()).await {
        Ok(stream) => {
            let (mut ours, theirs) = tokio::io::duplex(1024);
            let (reader, writer) = tokio::io::split(theirs);
            let pump = tokio::task::spawn_local(bridge_raw_stream(stream, reader, writer));
            ours.write_all(b"desktop").await.unwrap();
            let mut echo = [0_u8; 7];
            tokio::time::timeout(TIMEOUT, ours.read_exact(&mut echo)).await.unwrap().unwrap();
            drop(ours);
            pump.abort();
            (ServiceControl::Opened { service: Service::LocalSocket }, Some(echo.to_vec()))
        }
        Err(BridgeError::Rejected(message)) => {
            (ServiceControl::Rejected { code: "bridge".into(), message }, None)
        }
        Err(other) => panic!("the bridge failed: {other}"),
    }
}

fn rejected(control: &ServiceControl) -> (&str, &str) {
    match control {
        ServiceControl::Rejected { code, message } => (code, message),
        other => panic!("expected a rejection, got {other:?}"),
    }
}

/// The owner's grant reaches the allowlisted socket and carries its bytes.
#[tokio::test]
async fn an_owner_grant_reaches_the_allowlisted_socket() {
    let signer = Signer::generate();
    let mut daemon = daemon(&signer).await;
    let directory = tempdir().unwrap();
    let socket = directory.path().join("desktop.sock");
    let _echo = echo_socket(&socket);

    let (control, echo) = open_local_socket(
        &mut daemon,
        &signer,
        Some("owner"),
        vec![socket.clone()],
        &socket,
        1,
        false,
    )
    .await;
    assert_eq!(control, ServiceControl::Opened { service: Service::LocalSocket });
    assert_eq!(echo.as_deref(), Some(b"DESKTOP".as_slice()));
    daemon.server.shutdown().await.unwrap();
}

/// An owner grant whose `svc` names nothing but `local-socket` still admits
/// the session: the owner's desktop needs no other service.
#[tokio::test]
async fn an_owner_grant_for_the_desktop_alone_is_admitted() {
    let signer = Signer::generate();
    let mut daemon = daemon(&signer).await;
    let directory = tempdir().unwrap();
    let socket = directory.path().join("desktop.sock");
    let _echo = echo_socket(&socket);

    let (control, echo) = open_local_socket_with(
        &mut daemon,
        &signer,
        Some("owner"),
        &["local-socket"],
        vec![socket.clone()],
        &socket,
        9,
        false,
    )
    .await;
    assert_eq!(control, ServiceControl::Opened { service: Service::LocalSocket });
    assert_eq!(echo.as_deref(), Some(b"DESKTOP".as_slice()));
    daemon.server.shutdown().await.unwrap();
}

/// A teammate's grant, or one with no `vmk`, never holds `local-socket`,
/// even when its `svc` names it.
#[tokio::test]
async fn a_non_owner_grant_is_refused() {
    let signer = Signer::generate();
    let mut daemon = daemon(&signer).await;
    let directory = tempdir().unwrap();
    let socket = directory.path().join("desktop.sock");
    let _echo = echo_socket(&socket);

    for (jti, vmk) in [(2, Some("team")), (3, None)] {
        let (control, echo) =
            open_local_socket(&mut daemon, &signer, vmk, vec![socket.clone()], &socket, jti, false)
                .await;
        let (code, message) = rejected(&control);
        assert_eq!(code, "permission-denied", "{vmk:?}");
        assert!(message.contains("does not allow local-socket"), "{vmk:?}: {message}");
        assert!(echo.is_none());
    }
    daemon.server.shutdown().await.unwrap();
}

/// The owner still reaches only the allowlist: another socket, or the
/// allowed one spelled another way, is refused.
#[tokio::test]
async fn a_path_outside_the_allowlist_is_refused() {
    let signer = Signer::generate();
    let mut daemon = daemon(&signer).await;
    let directory = tempdir().unwrap();
    let socket = directory.path().join("desktop.sock");
    let other = directory.path().join("other.sock");
    let _echo = echo_socket(&socket);
    let _other = echo_socket(&other);
    let respelled = directory.path().join(".").join("desktop.sock");

    for (jti, path) in [(4, &other), (5, &respelled)] {
        let (control, echo) = open_local_socket(
            &mut daemon,
            &signer,
            Some("owner"),
            vec![socket.clone()],
            path,
            jti,
            false,
        )
        .await;
        let (code, message) = rejected(&control);
        assert_eq!(code, "permission-denied", "{}", path.display());
        assert!(message.contains("allowlist"), "{message}");
        assert!(echo.is_none());
    }
    daemon.server.shutdown().await.unwrap();
}

/// A daemon started with no allowlist serves no local socket, to anyone.
#[tokio::test]
async fn a_daemon_without_an_allowlist_refuses() {
    let signer = Signer::generate();
    let mut daemon = daemon(&signer).await;
    let directory = tempdir().unwrap();
    let socket = directory.path().join("desktop.sock");
    let _echo = echo_socket(&socket);

    let (control, echo) =
        open_local_socket(&mut daemon, &signer, Some("owner"), Vec::new(), &socket, 6, false).await;
    let (code, message) = rejected(&control);
    assert_eq!(code, "unavailable");
    assert!(message.contains("no local sockets"), "{message}");
    assert!(echo.is_none());
    daemon.server.shutdown().await.unwrap();
}

/// The dial's client half: `open_local_socket` and `bridge_raw_stream` carry
/// the owner's bytes, and pass a refusal up with the daemon's reason.
#[tokio::test]
async fn the_client_bridge_carries_the_owner_and_reports_a_refusal() {
    let signer = Signer::generate();
    let mut daemon = daemon(&signer).await;
    let directory = tempdir().unwrap();
    let socket = directory.path().join("desktop.sock");
    let _echo = echo_socket(&socket);

    let (control, echo) = open_local_socket(
        &mut daemon,
        &signer,
        Some("owner"),
        vec![socket.clone()],
        &socket,
        7,
        true,
    )
    .await;
    assert_eq!(control, ServiceControl::Opened { service: Service::LocalSocket });
    assert_eq!(echo.as_deref(), Some(b"DESKTOP".as_slice()));

    let (control, _) = open_local_socket(
        &mut daemon,
        &signer,
        Some("team"),
        vec![socket.clone()],
        &socket,
        8,
        true,
    )
    .await;
    assert!(rejected(&control).1.contains("does not allow local-socket"), "{control:?}");
    daemon.server.shutdown().await.unwrap();
}

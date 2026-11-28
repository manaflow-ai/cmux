use std::ffi::OsString;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::Arc;
use std::time::Duration;

use bytes::Bytes;
use cmux_remote::connection::{ClientConnection, ClientConnectionConfig, ReconnectPolicy};
use cmux_remote::crypto::{ClientAuthMode, StaticIdentity};
use cmux_remote::daemon::{InboundLink, NetworkPeer, RemoteDaemon, ServerConnection};
use cmux_remote::identity::AuthDatabase;
use cmux_remote::observability::{ConnectionState, TransportPathKind};
use cmux_remote::provider::{
    CarrierEvidence, ConnectRequest, DirectWebSocketProvider, LinkRequest, TransportProvider,
    TungsteniteWebSocketLink,
};
use cmux_remote::session::SessionLimits;
use cmux_remote_protocol::{FrameFlags, Lane, LanePolicy, SessionId};
use rcgen::{
    BasicConstraints, CertificateParams, CertifiedIssuer, DistinguishedName, DnType,
    ExtendedKeyUsagePurpose, IsCa, KeyPair, KeyUsagePurpose,
};
use tempfile::{TempDir, tempdir};
use tokio::net::TcpListener;
use tokio::sync::oneshot;
use tokio::task::{JoinHandle, JoinSet};
use tokio_rustls::TlsAcceptor;
use tokio_rustls::rustls::ServerConfig;
use tokio_rustls::rustls::pki_types::{PrivateKeyDer, PrivatePkcs8KeyDer};
use tokio_tungstenite::accept_async;
use url::Url;
use zeroize::Zeroizing;

const MAXIMUM_FRAME_BYTES: usize = 65_535;
const LOOPBACK: IpAddr = IpAddr::V4(Ipv4Addr::LOCALHOST);

struct TestCertificateAuthority {
    issuer: CertifiedIssuer<'static, KeyPair>,
}

impl TestCertificateAuthority {
    fn generate(common_name: &str) -> Self {
        let mut params = CertificateParams::new(Vec::<String>::new()).unwrap();
        params.distinguished_name = distinguished_name(common_name);
        params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
        params.key_usages = vec![KeyUsagePurpose::DigitalSignature, KeyUsagePurpose::KeyCertSign];
        let issuer = CertifiedIssuer::self_signed(params, KeyPair::generate().unwrap()).unwrap();
        Self { issuer }
    }

    fn pem(&self) -> String {
        self.issuer.pem()
    }

    fn server_config(&self, subject_alt_name: &str) -> Arc<ServerConfig> {
        let mut params = CertificateParams::new(vec![subject_alt_name.to_owned()]).unwrap();
        params.distinguished_name = distinguished_name(subject_alt_name);
        params.key_usages = vec![KeyUsagePurpose::DigitalSignature];
        params.extended_key_usages = vec![ExtendedKeyUsagePurpose::ServerAuth];
        params.use_authority_key_identifier_extension = true;
        let key = KeyPair::generate().unwrap();
        let certificate = params.signed_by(&key, &self.issuer).unwrap();
        let private_key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(key.serialize_der()));
        let config = ServerConfig::builder()
            .with_no_client_auth()
            .with_single_cert(vec![certificate.der().clone()], private_key)
            .unwrap();
        Arc::new(config)
    }
}

fn distinguished_name(common_name: &str) -> DistinguishedName {
    let mut name = DistinguishedName::new();
    name.push(DnType::CommonName, common_name);
    name
}

struct CertificateEnvironment {
    previous_file: Option<OsString>,
    previous_dir: Option<OsString>,
    _directory: TempDir,
}

impl CertificateEnvironment {
    fn trust(ca_pem: &str) -> Self {
        let directory = tempdir().unwrap();
        let ca_path = directory.path().join("trusted-ca.pem");
        std::fs::write(&ca_path, ca_pem).unwrap();
        let previous_file = std::env::var_os("SSL_CERT_FILE");
        let previous_dir = std::env::var_os("SSL_CERT_DIR");

        // SAFETY: this integration-test binary contains one current-thread test. It changes the
        // trust-store variables before spawning any tasks and restores them after all tasks stop.
        unsafe {
            std::env::set_var("SSL_CERT_FILE", &ca_path);
            std::env::remove_var("SSL_CERT_DIR");
        }
        Self { previous_file, previous_dir, _directory: directory }
    }
}

impl Drop for CertificateEnvironment {
    fn drop(&mut self) {
        // SAFETY: all tasks created by this single current-thread test have stopped before drop.
        unsafe {
            restore_environment("SSL_CERT_FILE", self.previous_file.take());
            restore_environment("SSL_CERT_DIR", self.previous_dir.take());
        }
    }
}

unsafe fn restore_environment(name: &str, value: Option<OsString>) {
    match value {
        Some(value) => {
            // SAFETY: the caller guarantees exclusive access to the process environment.
            unsafe { std::env::set_var(name, value) }
        }
        None => {
            // SAFETY: the caller guarantees exclusive access to the process environment.
            unsafe { std::env::remove_var(name) }
        }
    }
}

struct TlsWebSocketServer {
    address: SocketAddr,
    shutdown: Option<oneshot::Sender<()>>,
    task: Option<JoinHandle<()>>,
}

impl TlsWebSocketServer {
    async fn start(daemon: Arc<RemoteDaemon>, config: Arc<ServerConfig>) -> Self {
        let listener = TcpListener::bind(SocketAddr::new(LOOPBACK, 0)).await.unwrap();
        let address = listener.local_addr().unwrap();
        let acceptor = TlsAcceptor::from(config);
        let (shutdown_tx, mut shutdown_rx) = oneshot::channel();
        let task = tokio::spawn(async move {
            let mut connections = JoinSet::new();
            loop {
                tokio::select! {
                    _ = &mut shutdown_rx => break,
                    accepted = listener.accept() => {
                        let Ok((stream, _)) = accepted else { break };
                        let acceptor = acceptor.clone();
                        let daemon = daemon.clone();
                        connections.spawn(async move {
                            let Ok(stream) = acceptor.accept(stream).await else { return };
                            let Ok(socket) = accept_async(stream).await else { return };
                            let link = TungsteniteWebSocketLink::new(
                                "test-wss",
                                MAXIMUM_FRAME_BYTES,
                                socket,
                            );
                            let inbound =
                                InboundLink::network(Box::new(link), NetworkPeer::Tls);
                            let _ = daemon.accept(inbound).await;
                        });
                    }
                    Some(_) = connections.join_next(), if !connections.is_empty() => {}
                }
            }
            connections.abort_all();
            while connections.join_next().await.is_some() {}
        });
        Self { address, shutdown: Some(shutdown_tx), task: Some(task) }
    }

    fn endpoint(&self) -> Url {
        Url::parse(&format!("wss://{}/v1/link", self.address)).unwrap()
    }

    async fn shutdown(mut self) {
        if let Some(shutdown) = self.shutdown.take() {
            let _ = shutdown.send(());
        }
        self.task.take().unwrap().await.unwrap();
    }
}

impl Drop for TlsWebSocketServer {
    fn drop(&mut self) {
        if let Some(shutdown) = self.shutdown.take() {
            let _ = shutdown.send(());
        }
        if let Some(task) = self.task.take() {
            task.abort();
        }
    }
}

async fn reject_tls(endpoint: Url, expected_error: &[&str]) {
    let group = DirectWebSocketProvider::new(MAXIMUM_FRAME_BYTES)
        .connect(ConnectRequest {
            endpoint,
            session: SessionId([91; 16]),
            lane_policy: LanePolicy::Single,
            routing: Default::default(),
        })
        .await
        .unwrap();
    let error = match group.open(LinkRequest { lane: Lane::Interactive, generation: 0 }).await {
        Ok(link) => {
            let _ = link.close().await;
            panic!("TLS connection unexpectedly succeeded");
        }
        Err(error) => error,
    };
    let message = error.to_string();
    assert!(
        expected_error.iter().any(|expected| message.contains(expected)),
        "unexpected TLS error: {message}"
    );
}

async fn connect_enrolled_client(
    endpoint: Url,
    auth: Arc<AuthDatabase>,
    accepted: &mut tokio::sync::mpsc::Receiver<Arc<ServerConnection>>,
) -> (Arc<ClientConnection>, Arc<ServerConnection>) {
    let invitation = auth.create_invitation(Duration::from_secs(60), vec![]).await.unwrap();
    let approver = tokio::spawn({
        let auth = auth.clone();
        async move {
            let pending = auth.wait_for_pending(Duration::from_secs(5)).await.unwrap();
            auth.approve(&pending[0].invitation_id).await.unwrap();
        }
    });
    let session = SessionId([73; 16]);
    let group = DirectWebSocketProvider::new(MAXIMUM_FRAME_BYTES)
        .connect(ConnectRequest {
            endpoint,
            session,
            lane_policy: LanePolicy::Isolated,
            routing: Default::default(),
        })
        .await
        .unwrap();
    assert_eq!(group.evidence(), &CarrierEvidence::Tls { server_name: LOOPBACK.to_string() });
    assert!(group.capabilities().carrier_encryption);

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
            device_name: "wss-client".into(),
            session,
            lane_policy: LanePolicy::Isolated,
            limits: SessionLimits::default(),
            reconnect: ReconnectPolicy::default(),
        },
    )
    .await
    .unwrap();
    approver.await.unwrap();
    let daemon_client =
        tokio::time::timeout(Duration::from_secs(5), accepted.recv()).await.unwrap().unwrap();
    (client, daemon_client)
}

#[tokio::test(flavor = "current_thread")]
async fn wss_verifies_certificates_then_enrolls_noise_client_over_isolated_lanes() {
    let trusted_ca = TestCertificateAuthority::generate("cmux trusted WSS test CA");
    let untrusted_ca = TestCertificateAuthority::generate("cmux untrusted WSS test CA");
    let _certificate_environment = CertificateEnvironment::trust(&trusted_ca.pem());

    let state = tempdir().unwrap();
    let auth = AuthDatabase::load_or_create(state.path(), "wss-test", false).unwrap();
    let (daemon, mut accepted) = RemoteDaemon::new(auth.clone(), SessionLimits::default());
    let trusted =
        TlsWebSocketServer::start(daemon.clone(), trusted_ca.server_config(&LOOPBACK.to_string()))
            .await;
    let wrong_hostname =
        TlsWebSocketServer::start(daemon.clone(), trusted_ca.server_config("wrong.example")).await;
    let untrusted =
        TlsWebSocketServer::start(daemon, untrusted_ca.server_config(&LOOPBACK.to_string())).await;

    reject_tls(wrong_hostname.endpoint(), &["not valid for name", "NotValidForName"]).await;
    reject_tls(untrusted.endpoint(), &["UnknownIssuer", "unknown issuer"]).await;

    let (client, daemon_client) =
        connect_enrolled_client(trusted.endpoint(), auth, &mut accepted).await;
    let client_snapshot = client.snapshot().await;
    assert_eq!(client_snapshot.state, ConnectionState::Connected);
    assert_eq!(client_snapshot.physical_link_count, 4);
    assert_eq!(client_snapshot.transport.provider, "direct-websocket");
    assert_eq!(client_snapshot.transport.selected_path.unwrap().kind, TransportPathKind::Direct);
    assert_eq!(daemon_client.snapshot().await.physical_link_count, 4);

    client
        .send(Lane::Interactive, 1, Bytes::from_static(b"input"), FrameFlags::empty())
        .await
        .unwrap();
    assert_eq!(daemon_client.receive().await.unwrap().unwrap().payload, b"input".as_slice());
    daemon_client
        .send(Lane::Bulk, 2, Bytes::from_static(b"screen"), FrameFlags::empty())
        .await
        .unwrap();
    assert_eq!(client.receive().await.unwrap().unwrap().payload, b"screen".as_slice());

    client.close().await.unwrap();
    trusted.shutdown().await;
    wrong_hostname.shutdown().await;
    untrusted.shutdown().await;
}

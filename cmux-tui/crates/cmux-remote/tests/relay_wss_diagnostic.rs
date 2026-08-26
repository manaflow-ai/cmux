use std::ffi::OsString;
use std::sync::Arc;
use std::time::Duration;

use cmux_remote::link::LinkError;
use cmux_remote::provider::{
    ConnectRequest, ProviderError, RelayClientConfig, RelayProvider, TransportProvider,
};
use cmux_remote_protocol::{LanePolicy, SessionId};
use rcgen::{
    BasicConstraints, CertificateParams, CertifiedIssuer, DistinguishedName, DnType,
    ExtendedKeyUsagePurpose, IsCa, KeyPair, KeyUsagePurpose,
};
use tempfile::{TempDir, tempdir};
use tokio::net::TcpListener;
use tokio_rustls::TlsAcceptor;
use tokio_rustls::rustls::ServerConfig;
use tokio_rustls::rustls::pki_types::{PrivateKeyDer, PrivatePkcs8KeyDer};
use url::Url;

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

fn distinguished_name(common_name: &str) -> DistinguishedName {
    let mut name = DistinguishedName::new();
    name.push(DnType::CommonName, common_name);
    name
}

fn wrong_hostname_server_config() -> (String, Arc<ServerConfig>) {
    let mut issuer_params = CertificateParams::new(Vec::<String>::new()).unwrap();
    issuer_params.distinguished_name = distinguished_name("cmux relay WSS diagnostic test CA");
    issuer_params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    issuer_params.key_usages =
        vec![KeyUsagePurpose::DigitalSignature, KeyUsagePurpose::KeyCertSign];
    let issuer = CertifiedIssuer::self_signed(issuer_params, KeyPair::generate().unwrap()).unwrap();

    let mut server_params = CertificateParams::new(vec!["wrong.example".into()]).unwrap();
    server_params.distinguished_name = distinguished_name("wrong.example");
    server_params.key_usages = vec![KeyUsagePurpose::DigitalSignature];
    server_params.extended_key_usages = vec![ExtendedKeyUsagePurpose::ServerAuth];
    server_params.use_authority_key_identifier_extension = true;
    let key = KeyPair::generate().unwrap();
    let certificate = server_params.signed_by(&key, &issuer).unwrap();
    let private_key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(key.serialize_der()));
    let config = ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(vec![certificate.der().clone()], private_key)
        .unwrap();
    (issuer.pem(), Arc::new(config))
}

#[tokio::test(flavor = "current_thread")]
async fn relay_wss_preserves_tls_hostname_failure_without_credentials() {
    let (ca_pem, server_config) = wrong_hostname_server_config();
    let _certificate_environment = CertificateEnvironment::trust(&ca_pem);
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let _ = TlsAcceptor::from(server_config).accept(stream).await;
    });
    let credential = "relay-diagnostic-secret-marker";
    let provider = RelayProvider::new(RelayClientConfig {
        slot: "relay-diagnostic-slot".into(),
        ticket: credential.into(),
        maximum_frame_bytes: 65_535,
        control_timeout: Duration::from_secs(1),
    })
    .unwrap();
    let error = match provider
        .connect(ConnectRequest {
            endpoint: Url::parse(&format!("relay+wss://{address}")).unwrap(),
            session: SessionId::ZERO,
            lane_policy: LanePolicy::Single,
            routing: Default::default(),
        })
        .await
    {
        Ok(_) => panic!("relay WSS accepted a certificate for the wrong hostname"),
        Err(ProviderError::Link(LinkError::Transport(message))) => message,
        Err(error) => panic!("relay WSS carrier failure used the wrong error category: {error}"),
    };
    server.await.unwrap();

    assert!(
        error.contains("certificate")
            || error.contains("not valid for name")
            || error.contains("NotValidForName"),
        "relay WSS discarded the TLS hostname failure: {error}"
    );
    assert!(!error.contains(credential), "relay WSS diagnostic leaked its credential: {error}");
}

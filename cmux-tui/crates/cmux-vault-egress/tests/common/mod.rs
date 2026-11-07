//! The loopback harness the integration tests share: a TLS upstream that
//! echoes the credentials it received, and the proxy in front of it.
#![allow(dead_code)]

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};

use bytes::Bytes;
use cmux_vault_egress::{Authority, Config, HostPattern, Policy, Resolver, Secret};
use http_body_util::{BodyExt, Empty};
use hyper::service::service_fn;
use hyper_util::rt::TokioIo;
use rcgen::{BasicConstraints, CertificateParams, CertifiedIssuer, IsCa, KeyPair, KeyUsagePurpose};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer, ServerName};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use zeroize::Zeroizing;

pub const VALUE: &str = "real-token-6f1c2a";
pub const OTHER_VALUE: &str = "other-token-91b7";

/// A TLS server for allowed.test, other.test and denied.test that answers
/// every request with its Authorization and x-api-key headers.
pub async fn upstream() -> (SocketAddr, CertificateDer<'static>) {
    let mut ca = CertificateParams::new(Vec::<String>::new()).unwrap();
    ca.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    ca.key_usages = vec![KeyUsagePurpose::KeyCertSign, KeyUsagePurpose::DigitalSignature];
    let issuer = CertifiedIssuer::self_signed(ca, KeyPair::generate().unwrap()).unwrap();
    let ca_der = pem_cert(&issuer.pem());
    let params = CertificateParams::new(vec![
        "allowed.test".to_owned(),
        "other.test".to_owned(),
        "denied.test".to_owned(),
    ])
    .unwrap();
    let key = KeyPair::generate().unwrap();
    let cert = params.signed_by(&key, &issuer).unwrap();
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let config = rustls::ServerConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .unwrap()
        .with_no_client_auth()
        .with_single_cert(
            vec![cert.der().clone()],
            PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(key.serialize_der())),
        )
        .unwrap();
    let acceptor = tokio_rustls::TlsAcceptor::from(Arc::new(config));
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        loop {
            let Ok((stream, _)) = listener.accept().await else { return };
            let acceptor = acceptor.clone();
            tokio::spawn(async move {
                let Ok(tls) = acceptor.accept(stream).await else { return };
                let service = service_fn(|req: hyper::Request<hyper::body::Incoming>| async move {
                    let get = |n: &str| {
                        req.headers().get(n).and_then(|v| v.to_str().ok()).unwrap_or("").to_owned()
                    };
                    let body = format!("{}\n{}", get("authorization"), get("x-api-key"));
                    Ok::<_, std::convert::Infallible>(hyper::Response::new(
                        http_body_util::Full::new(Bytes::from(body)),
                    ))
                });
                let _ = hyper::server::conn::http1::Builder::new()
                    .serve_connection(TokioIo::new(tls), service)
                    .await;
            });
        }
    });
    (addr, ca_der)
}

pub fn roots(cert: CertificateDer<'static>) -> rustls::RootCertStore {
    let mut roots = rustls::RootCertStore::empty();
    roots.add(cert).unwrap();
    roots
}

pub struct Harness {
    pub proxy: SocketAddr,
    pub authority: Arc<Authority>,
    pub upstream_ca: CertificateDer<'static>,
    pub policy: Arc<Mutex<Arc<Policy>>>,
}

pub fn secrets() -> Policy {
    Policy::new(vec![
        Secret::new(
            "TOKEN",
            Zeroizing::new(VALUE.to_owned()),
            vec![HostPattern::parse("allowed.test").unwrap()],
        ),
        Secret::new(
            "OTHER",
            Zeroizing::new(OTHER_VALUE.to_owned()),
            vec![HostPattern::parse("other.test").unwrap()],
        ),
    ])
}

pub async fn harness() -> Harness {
    let (up, upstream_ca) = upstream().await;
    let authority = Arc::new(Authority::generate().unwrap());
    let policy = Arc::new(Mutex::new(Arc::new(secrets())));
    let read = policy.clone();
    let fixed: HashMap<(String, u16), SocketAddr> = ["allowed.test", "other.test", "denied.test"]
        .into_iter()
        .map(|h| ((h.to_owned(), 443), up))
        .collect();
    let config = Arc::new(Config {
        policy: Arc::new(move || read.lock().unwrap().clone()),
        authority: authority.clone(),
        upstream_tls: cmux_vault_egress::upstream_tls_with_roots(roots(upstream_ca.clone()))
            .unwrap(),
        resolver: Resolver::Fixed(fixed),
    });
    let listener = cmux_vault_egress::bind().await.unwrap();
    let proxy = listener.local_addr().unwrap();
    tokio::spawn(cmux_vault_egress::serve(listener, config));
    Harness { proxy, authority, upstream_ca, policy }
}

/// CONNECT through the proxy; the TCP stream after its 200, or its status line.
pub async fn tunnel(proxy: SocketAddr, host: &str) -> Result<TcpStream, String> {
    let mut stream = TcpStream::connect(proxy).await.unwrap();
    stream
        .write_all(format!("CONNECT {host}:443 HTTP/1.1\r\nHost: {host}:443\r\n\r\n").as_bytes())
        .await
        .unwrap();
    let mut head = Vec::new();
    let mut byte = [0u8; 1];
    while !head.ends_with(b"\r\n\r\n") {
        stream.read_exact(&mut byte).await.unwrap();
        head.push(byte[0]);
    }
    let head = String::from_utf8(head).unwrap();
    if head.starts_with("HTTP/1.1 200") { Ok(stream) } else { Err(head) }
}

/// One GET over TLS (trusting `trust`) to `host`; the status and body.
pub async fn get(
    stream: TcpStream,
    host: &str,
    trust: rustls::RootCertStore,
    host_header: &str,
    headers: &[(&str, &str)],
) -> Result<(u16, String), String> {
    let config = cmux_vault_egress::upstream_tls_with_roots(trust).unwrap();
    let name = ServerName::try_from(host.to_owned()).unwrap();
    let tls = tokio_rustls::TlsConnector::from(config)
        .connect(name, stream)
        .await
        .map_err(|e| format!("tls: {e}"))?;
    let (mut sender, conn) =
        hyper::client::conn::http1::handshake(TokioIo::new(tls)).await.unwrap();
    tokio::spawn(conn);
    let mut req = hyper::Request::get("/echo").header("host", host_header);
    for (k, v) in headers {
        req = req.header(*k, *v);
    }
    let response = sender.send_request(req.body(Empty::<Bytes>::new()).unwrap()).await.unwrap();
    let code = response.status().as_u16();
    let body = response.into_body().collect().await.unwrap().to_bytes();
    Ok((code, String::from_utf8(body.to_vec()).unwrap()))
}

pub fn pem_cert(pem: &str) -> CertificateDer<'static> {
    use rustls::pki_types::pem::PemObject as _;
    CertificateDer::from_pem_slice(pem.as_bytes()).unwrap()
}

pub fn proxy_roots(h: &Harness) -> rustls::RootCertStore {
    roots(pem_cert(h.authority.pem()))
}

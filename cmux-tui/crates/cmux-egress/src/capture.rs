//! Capture mode, for the seeded-secret tests (feature `capture`, which only
//! dev-dependencies turn on; a shipped build has none of this).
//!
//! [`install`] starts one TLS server on loopback with a CA made for this test
//! process. From then on every gated client ([`crate::client_builder`] and
//! the rest) sends each listed or person-named host to that server instead of
//! the internet and trusts that CA, so the request a payload path would have
//! sent (host, method, path and query, headers, body) is kept in [`requests`].
//! A test plants a secret in the state the path reads, runs the path, and
//! asserts [`leaks`] finds it in none of them (tests/egress_seeded.json lists
//! which test covers each gate site).
//!
//! Only an explicit call turns it on (no environment variable), so nothing
//! outside a test binary can point the gate at another server. The server
//! answers every request `200 {}`; it speaks HTTP/1.1 only, so headers are
//! never HPACK-compressed out of sight.

use std::collections::HashMap;
use std::convert::Infallible;
use std::fmt;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex, OnceLock};

use bytes::Bytes;
use http_body_util::{BodyExt, Full};
use hyper::body::Incoming;
use hyper::{Request, Response};
use hyper_util::rt::TokioIo;
use rcgen::{
    BasicConstraints, CertificateParams, ExtendedKeyUsagePurpose, IsCa, Issuer, KeyPair,
    KeyUsagePurpose,
};
use rustls::ServerConfig;
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use rustls::server::{ClientHello, ResolvesServerCert};
use rustls::sign::CertifiedKey;

/// One request a gated client sent while capture was on.
#[derive(Clone, Debug)]
pub struct Captured {
    /// The host the client asked for (its TLS server name).
    pub host: String,
    pub method: String,
    /// Path and query.
    pub target: String,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl Captured {
    /// Where in this request `secret` appears: `"target"`, `"header NAME"` or
    /// `"body"`, each once.
    pub fn carries(&self, secret: &str) -> Vec<String> {
        let mut found = Vec::new();
        if self.target.contains(secret) || percent_decoded(&self.target).contains(secret) {
            found.push("target".to_owned());
        }
        for (name, value) in &self.headers {
            if value.contains(secret) || name.contains(secret) {
                found.push(format!("header {name}"));
            }
        }
        if contains(&self.body, secret.as_bytes())
            || percent_decoded(&String::from_utf8_lossy(&self.body)).contains(secret)
        {
            found.push("body".to_owned());
        }
        found
    }
}

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    !needle.is_empty() && haystack.windows(needle.len()).any(|window| window == needle)
}

/// `text` with `%XX` and `+` decoded, so a secret sent form- or query-encoded is still found.
fn percent_decoded(text: &str) -> String {
    fn hex(byte: u8) -> Option<u8> {
        (byte as char).to_digit(16).and_then(|digit| u8::try_from(digit).ok())
    }
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        let pair =
            (bytes.get(i + 1).copied().and_then(hex), bytes.get(i + 2).copied().and_then(hex));
        match (bytes[i], pair) {
            (b'%', (Some(high), Some(low))) => {
                out.push(high * 16 + low);
                i += 3;
                continue;
            }
            (b'+', _) => out.push(b' '),
            (byte, _) => out.push(byte),
        }
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

struct Installed {
    addr: SocketAddr,
    ca: CertificateDer<'static>,
    seen: Arc<Mutex<Vec<Captured>>>,
}

static INSTALLED: OnceLock<Installed> = OnceLock::new();

/// Starts the capture server (once per process; later calls return at once)
/// and points every gated client built after it there. Err when the server
/// could not start (no loopback port, no thread).
pub fn install() -> Result<(), String> {
    if INSTALLED.get().is_some() {
        return Ok(());
    }
    let installed = start().map_err(|error| error.to_string())?;
    // A racing install's server stays unused; both answer the same way.
    let _ = INSTALLED.set(installed);
    Ok(())
}

/// Every request captured so far, oldest first.
pub fn requests() -> Vec<Captured> {
    INSTALLED.get().map(|installed| lock(&installed.seen).clone()).unwrap_or_default()
}

/// The captured requests to `host`.
pub fn requests_to(host: &str) -> Vec<Captured> {
    requests().into_iter().filter(|request| request.host == host).collect()
}

/// One line per place `secret` was sent (`"HOST METHOD TARGET: header x-y"`);
/// empty when it went nowhere.
pub fn leaks(secret: &str) -> Vec<String> {
    requests()
        .iter()
        .flat_map(|request| {
            request.carries(secret).into_iter().map(move |place| {
                format!("{} {} {}: {place}", request.host, request.method, request.target)
            })
        })
        .collect()
}

/// Where the gate sends `host` instead of looking it up, when capture is on.
pub(crate) fn redirect(host: &str) -> Option<SocketAddr> {
    let installed = INSTALLED.get()?;
    match crate::verdict(host) {
        crate::Verdict::Listed | crate::Verdict::Named => Some(installed.addr),
        crate::Verdict::Local | crate::Verdict::Unlisted => None,
    }
}

/// The CA gated clients trust too, when capture is on.
pub(crate) fn root() -> Option<reqwest::Certificate> {
    let installed = INSTALLED.get()?;
    reqwest::Certificate::from_der(&installed.ca).ok()
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Leaf certificates for whatever server name a client asks for, signed by the test CA.
struct Leaves {
    issuer: Issuer<'static, KeyPair>,
    made: Mutex<HashMap<String, Arc<CertifiedKey>>>,
}

impl fmt::Debug for Leaves {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Leaves").finish_non_exhaustive()
    }
}

impl Leaves {
    fn leaf(&self, host: &str) -> Result<Arc<CertifiedKey>, Box<dyn std::error::Error>> {
        let mut params = CertificateParams::new(vec![host.to_owned()])?;
        params.key_usages = vec![KeyUsagePurpose::DigitalSignature];
        params.extended_key_usages = vec![ExtendedKeyUsagePurpose::ServerAuth];
        params.use_authority_key_identifier_extension = true;
        let key = KeyPair::generate()?;
        let cert = params.signed_by(&key, &self.issuer)?;
        let private = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(key.serialize_der()));
        let signing =
            rustls::crypto::ring::default_provider().key_provider.load_private_key(private)?;
        Ok(Arc::new(CertifiedKey::new(vec![cert.der().clone()], signing)))
    }
}

impl ResolvesServerCert for Leaves {
    fn resolve(&self, hello: ClientHello<'_>) -> Option<Arc<CertifiedKey>> {
        let host = hello.server_name()?.to_owned();
        let mut made = lock(&self.made);
        if let Some(leaf) = made.get(&host) {
            return Some(leaf.clone());
        }
        let leaf = self.leaf(&host).ok()?;
        made.insert(host, leaf.clone());
        Some(leaf)
    }
}

fn start() -> Result<Installed, Box<dyn std::error::Error>> {
    let mut params = CertificateParams::new(Vec::<String>::new())?;
    params.is_ca = IsCa::Ca(BasicConstraints::Constrained(0));
    params.key_usages = vec![KeyUsagePurpose::KeyCertSign, KeyUsagePurpose::DigitalSignature];
    let key = KeyPair::generate()?;
    let ca = params.self_signed(&key)?.der().clone();
    let leaves = Leaves { issuer: Issuer::new(params, key), made: Mutex::new(HashMap::new()) };

    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let mut config = ServerConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()?
        .with_no_client_auth()
        .with_cert_resolver(Arc::new(leaves));
    config.alpn_protocols = vec![b"http/1.1".to_vec()];
    let acceptor = tokio_rustls::TlsAcceptor::from(Arc::new(config));

    let listener = std::net::TcpListener::bind("127.0.0.1:0")?;
    listener.set_nonblocking(true)?;
    let addr = listener.local_addr()?;
    let seen = Arc::new(Mutex::new(Vec::new()));
    let kept = seen.clone();
    // Its own thread and runtime: it outlives each test's runtime.
    std::thread::Builder::new().name("egress-capture".into()).spawn(move || {
        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build();
        let Ok(runtime) = runtime else { return };
        runtime.block_on(serve(listener, acceptor, kept));
    })?;
    Ok(Installed { addr, ca, seen })
}

async fn serve(
    listener: std::net::TcpListener,
    acceptor: tokio_rustls::TlsAcceptor,
    seen: Arc<Mutex<Vec<Captured>>>,
) {
    let Ok(listener) = tokio::net::TcpListener::from_std(listener) else { return };
    while let Ok((stream, _)) = listener.accept().await {
        let acceptor = acceptor.clone();
        let seen = seen.clone();
        tokio::spawn(async move {
            let Ok(tls) = acceptor.accept(stream).await else { return };
            let host = tls.get_ref().1.server_name().unwrap_or_default().to_owned();
            let service = hyper::service::service_fn(move |request: Request<Incoming>| {
                let host = host.clone();
                let seen = seen.clone();
                async move {
                    let (parts, body) = request.into_parts();
                    let body =
                        body.collect().await.map(|b| b.to_bytes().to_vec()).unwrap_or_default();
                    let headers = parts
                        .headers
                        .iter()
                        .map(|(name, value)| {
                            (
                                name.as_str().to_owned(),
                                String::from_utf8_lossy(value.as_bytes()).into_owned(),
                            )
                        })
                        .collect();
                    let target = parts
                        .uri
                        .path_and_query()
                        .map(|pq| pq.as_str().to_owned())
                        .unwrap_or_default();
                    lock(&seen).push(Captured {
                        host,
                        method: parts.method.to_string(),
                        target,
                        headers,
                        body,
                    });
                    Ok::<_, Infallible>(Response::new(Full::new(Bytes::from_static(b"{}"))))
                }
            });
            let _ = hyper::server::conn::http1::Builder::new()
                .serve_connection(TokioIo::new(tls), service)
                .await;
        });
    }
}

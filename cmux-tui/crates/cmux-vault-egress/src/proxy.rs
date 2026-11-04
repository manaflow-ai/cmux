//! The listener: `CONNECT` only. Intercepted hosts get the header rewrite;
//! every other host a blind tunnel.

use std::collections::HashMap;
use std::convert::Infallible;
use std::io;
use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;
use std::time::Duration;

use bytes::Bytes;
use http::{HeaderValue, Method, Request, Response, StatusCode, header};
use http_body_util::{BodyExt, Full, combinators::BoxBody};
use hyper::body::Incoming;
use hyper::service::service_fn;
use hyper_util::rt::{TokioIo, TokioTimer};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{Mutex, Semaphore};
use tokio_rustls::{TlsAcceptor, TlsConnector};

use crate::ca::Authority;
use crate::substitute::{Policy, dns_name};

const HEADER_TIMEOUT: Duration = Duration::from_secs(30);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const TLS_TIMEOUT: Duration = Duration::from_secs(15);
/// Most client connections served at once; more wait for a slot.
const MAX_CONNECTIONS: usize = 512;

/// Where a `CONNECT` target resolves.
pub enum Resolver {
    /// DNS, then loopback, link-local, unspecified, multicast and broadcast
    /// addresses are refused.
    Dns,
    /// Fixed answers and nothing else (tests): no lookup, no address filter.
    Fixed(HashMap<(String, u16), SocketAddr>),
}

pub struct Config {
    /// The secrets now: called for every request.
    pub policy: Arc<dyn Fn() -> Arc<Policy> + Send + Sync>,
    pub authority: Arc<Authority>,
    /// The upstream TLS client: OS roots ([`upstream_tls_from_os`]).
    pub upstream_tls: Arc<rustls::ClientConfig>,
    pub resolver: Resolver,
}

/// A TLS client verifying servers against the OS trust store, HTTP/1.1.
pub fn upstream_tls_from_os() -> io::Result<Arc<rustls::ClientConfig>> {
    let mut roots = rustls::RootCertStore::empty();
    let found = rustls_native_certs::load_native_certs();
    for cert in found.certs {
        let _ = roots.add(cert);
    }
    if roots.is_empty() {
        return Err(io::Error::other("no OS trust roots"));
    }
    upstream_tls_with_roots(roots)
}

/// A TLS client trusting `roots` only, HTTP/1.1.
pub fn upstream_tls_with_roots(
    roots: rustls::RootCertStore,
) -> io::Result<Arc<rustls::ClientConfig>> {
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let mut config = rustls::ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .map_err(io::Error::other)?
        .with_root_certificates(roots)
        .with_no_client_auth();
    config.alpn_protocols = vec![b"http/1.1".to_vec()];
    Ok(Arc::new(config))
}

/// A loopback listener on a free port.
pub async fn bind() -> io::Result<TcpListener> {
    TcpListener::bind((IpAddr::from([127, 0, 0, 1]), 0)).await
}

/// Serve until the listener fails or the future is dropped (which drops
/// every connection task's handle; tasks end with their sockets).
pub async fn serve(listener: TcpListener, config: Arc<Config>) -> io::Result<()> {
    let slots = Arc::new(Semaphore::new(MAX_CONNECTIONS));
    loop {
        let permit = slots.clone().acquire_owned().await.map_err(io::Error::other)?;
        let (stream, _) = match listener.accept().await {
            Ok(pair) => pair,
            Err(e)
                if matches!(
                    e.kind(),
                    io::ErrorKind::ConnectionAborted
                        | io::ErrorKind::ConnectionReset
                        | io::ErrorKind::Interrupted
                ) =>
            {
                continue;
            }
            Err(e) if e.raw_os_error() == Some(24) || e.raw_os_error() == Some(23) => {
                // Out of descriptors: wait and accept again.
                tokio::time::sleep(Duration::from_millis(100)).await;
                continue;
            }
            Err(e) => return Err(e),
        };
        let config = config.clone();
        tokio::spawn(async move {
            let _permit = permit;
            let _ = stream.set_nodelay(true);
            let service = service_fn(move |req| connect(req, config.clone()));
            let _ = hyper::server::conn::http1::Builder::new()
                .timer(TokioTimer::new())
                .header_read_timeout(HEADER_TIMEOUT)
                .serve_connection(TokioIo::new(stream), service)
                .with_upgrades()
                .await;
        });
    }
}

type Body = BoxBody<Bytes, hyper::Error>;

fn status(code: StatusCode, reason: &'static str) -> Response<Body> {
    let mut response = Response::new(
        Full::new(Bytes::from_static(reason.as_bytes())).map_err(|never| match never {}).boxed(),
    );
    *response.status_mut() = code;
    response.headers_mut().insert(header::CONTENT_TYPE, HeaderValue::from_static("text/plain"));
    response
}

/// `host:port` of a CONNECT target, host lowercased. Bracketed IPv6 is kept.
fn target(req: &Request<Incoming>) -> Option<(String, u16)> {
    let authority = req.uri().authority()?;
    if authority.as_str().contains('@') {
        return None;
    }
    let port = authority.port_u16()?;
    let host = authority.host().trim_start_matches('[').trim_end_matches(']');
    (!host.is_empty() && port != 0).then(|| (host.to_ascii_lowercase(), port))
}

async fn connect(
    req: Request<Incoming>,
    config: Arc<Config>,
) -> Result<Response<Body>, Infallible> {
    if req.method() != Method::CONNECT {
        return Ok(status(
            StatusCode::METHOD_NOT_ALLOWED,
            "this proxy serves HTTPS CONNECT only\n",
        ));
    }
    let Some((host, port)) = target(&req) else {
        return Ok(status(StatusCode::BAD_REQUEST, "invalid CONNECT target\n"));
    };
    let intercept = dns_name(&host) && (config.policy)().intercepts(&host, port);
    let upstream = match open(&config.resolver, &host, port, intercept).await {
        Ok(stream) => stream,
        Err(Refused::Denied) => {
            return Ok(status(StatusCode::FORBIDDEN, "destination is not a public address\n"));
        }
        Err(Refused::Unreachable) => {
            return Ok(status(StatusCode::BAD_GATEWAY, "destination unreachable\n"));
        }
    };
    tokio::spawn(async move {
        let Ok(upgraded) = hyper::upgrade::on(req).await else { return };
        let client = TokioIo::new(upgraded);
        if intercept {
            let _ = intercepted(client, upstream, host, port, config).await;
        } else {
            let mut client = client;
            let mut upstream = upstream;
            let _ = tokio::io::copy_bidirectional(&mut client, &mut upstream).await;
        }
    });
    Ok(Response::new(Full::new(Bytes::new()).map_err(|never| match never {}).boxed()))
}

enum Refused {
    Denied,
    Unreachable,
}

/// A destination this proxy connects to: never loopback, link-local (cloud
/// metadata), unspecified, multicast or broadcast, IPv4-mapped included.
/// An intercepted connection (one a value may go out on) must also reach a
/// globally routed address: no private (RFC 1918), shared (CGNAT, tailnet),
/// benchmarking or IETF-reserved IPv4, no cloud host endpoint (Azure's
/// 168.63.129.16) and no unique-local IPv6, so a name rebound into the
/// machine's network never gets a value. IPv6 forms that embed an IPv4
/// address (mapped, NAT64, 6to4) are judged by that address. A blind tunnel
/// may reach internal addresses, as the agent could without the proxy.
fn reachable(addr: &SocketAddr, intercept: bool) -> bool {
    let ip = match addr.ip() {
        IpAddr::V6(v6) => embedded_v4(&v6).map_or(IpAddr::V6(v6), IpAddr::V4),
        ip => ip,
    };
    match ip {
        IpAddr::V4(v4) => {
            let [a, b, c, _] = v4.octets();
            let never = v4.is_loopback()
                || v4.is_link_local()
                || v4.is_unspecified()
                || v4.is_multicast()
                || v4.is_broadcast()
                || a == 0;
            let internal = v4.is_private()
                || (a == 100 && (b & 0xc0) == 64)
                || (a == 198 && (b & 0xfe) == 18)
                || (a == 192 && b == 0 && c == 0)
                || v4.octets() == [168, 63, 129, 16]
                || a >= 240;
            !(never || (intercept && internal))
        }
        IpAddr::V6(v6) => {
            let never = v6.is_loopback()
                || v6.is_unspecified()
                || v6.is_multicast()
                || v6.is_unicast_link_local();
            let first = v6.segments()[0];
            let internal = (first & 0xfe00) == 0xfc00 || (first & 0xffc0) == 0xfec0;
            !(never || (intercept && internal))
        }
    }
}

/// The IPv4 address an IPv6 one carries: IPv4-mapped, NAT64 (64:ff9b::/96)
/// or 6to4 (2002::/16).
fn embedded_v4(v6: &std::net::Ipv6Addr) -> Option<std::net::Ipv4Addr> {
    if let Some(v4) = v6.to_ipv4_mapped() {
        return Some(v4);
    }
    let s = v6.segments();
    let pair = |hi: u16, lo: u16| {
        std::net::Ipv4Addr::new((hi >> 8) as u8, hi as u8, (lo >> 8) as u8, lo as u8)
    };
    if s[..6] == [0x64, 0xff9b, 0, 0, 0, 0] {
        return Some(pair(s[6], s[7]));
    }
    (s[0] == 0x2002).then(|| pair(s[1], s[2]))
}

async fn open(
    resolver: &Resolver,
    host: &str,
    port: u16,
    intercept: bool,
) -> Result<TcpStream, Refused> {
    let addrs: Vec<SocketAddr> = match resolver {
        Resolver::Fixed(map) => map.get(&(host.to_owned(), port)).copied().into_iter().collect(),
        Resolver::Dns => {
            let found =
                tokio::time::timeout(CONNECT_TIMEOUT, tokio::net::lookup_host((host, port)))
                    .await
                    .map_err(|_| Refused::Unreachable)?
                    .map_err(|_| Refused::Unreachable)?;
            let all: Vec<SocketAddr> = found.collect();
            if all.is_empty() {
                return Err(Refused::Unreachable);
            }
            let allowed: Vec<SocketAddr> =
                all.into_iter().filter(|a| reachable(a, intercept)).collect();
            if allowed.is_empty() {
                return Err(Refused::Denied);
            }
            allowed
        }
    };
    for addr in addrs {
        if let Ok(Ok(stream)) =
            tokio::time::timeout(CONNECT_TIMEOUT, TcpStream::connect(addr)).await
        {
            let _ = stream.set_nodelay(true);
            return Ok(stream);
        }
    }
    Err(Refused::Unreachable)
}

/// The intercepted connection: upstream TLS first (a failure closes the
/// client before it sends anything), then the client handshake with this
/// host's leaf, then one request at a time, rewritten and forwarded.
async fn intercepted(
    client: TokioIo<hyper::upgrade::Upgraded>,
    upstream: TcpStream,
    host: String,
    port: u16,
    config: Arc<Config>,
) -> io::Result<()> {
    let name = rustls::pki_types::ServerName::try_from(host.clone()).map_err(io::Error::other)?;
    let upstream = tokio::time::timeout(
        TLS_TIMEOUT,
        TlsConnector::from(config.upstream_tls.clone()).connect(name, upstream),
    )
    .await
    .map_err(io::Error::other)??;
    let leaf = config.authority.server_config(&host)?;
    let client = tokio::time::timeout(TLS_TIMEOUT, TlsAcceptor::from(leaf).accept(client))
        .await
        .map_err(io::Error::other)??;
    let (sender, connection) = hyper::client::conn::http1::handshake(TokioIo::new(upstream))
        .await
        .map_err(io::Error::other)?;
    let upstream_task = tokio::spawn(connection);
    let sender = Arc::new(Mutex::new(sender));
    let host = Arc::new(host);
    let service =
        service_fn(move |req| forward(req, sender.clone(), host.clone(), port, config.clone()));
    let served = hyper::server::conn::http1::Builder::new()
        .timer(TokioTimer::new())
        .header_read_timeout(HEADER_TIMEOUT)
        .serve_connection(TokioIo::new(client), service)
        .await;
    upstream_task.abort();
    served.map_err(io::Error::other)
}

/// Whether `text` (a Host header or request-target authority) names
/// `host:port`: same host, case-insensitive, and the same port (absent = 443).
fn same_authority(text: &str, host: &str, port: u16) -> bool {
    if text.contains('@') {
        return false;
    }
    let Ok(authority) = text.parse::<http::uri::Authority>() else { return false };
    authority.host().eq_ignore_ascii_case(host) && authority.port_u16().unwrap_or(443) == port
}

async fn forward(
    mut req: Request<Incoming>,
    sender: Arc<Mutex<hyper::client::conn::http1::SendRequest<Incoming>>>,
    host: Arc<String>,
    port: u16,
    config: Arc<Config>,
) -> Result<Response<Body>, Infallible> {
    // The request must be for the host it was connected to: a shared front
    // end would otherwise route it (and a value) to whoever Host names. One
    // Host header, no more: a second could be the one the front end reads.
    let mut hosts = req.headers().get_all(header::HOST).iter();
    let host_header = hosts.next().and_then(|v| v.to_str().ok());
    let one_host = hosts.next().is_none();
    let target_ok = req.uri().authority().is_none_or(|a| same_authority(a.as_str(), &host, port));
    if !one_host || !host_header.is_some_and(|h| same_authority(h, &host, port)) || !target_ok {
        return Ok(status(
            StatusCode::MISDIRECTED_REQUEST,
            "Host does not match the CONNECT target\n",
        ));
    }
    let policy = (config.policy)();
    let mut used: Vec<String> = Vec::new();
    let mut rewritten = Vec::new();
    for (name, value) in req.headers().iter() {
        if name == header::HOST {
            continue;
        }
        let Ok(text) = value.to_str() else { continue };
        if let Some((new, names)) = policy.substitute_header(text, &host, port) {
            let Ok(mut new) = HeaderValue::from_str(&new) else {
                return Ok(status(
                    StatusCode::BAD_GATEWAY,
                    "a vault value is not a valid header value\n",
                ));
            };
            new.set_sensitive(true);
            rewritten.push((name.clone(), value.clone(), new));
            for n in names {
                if !used.contains(&n) {
                    used.push(n);
                }
            }
        }
    }
    drop(policy);
    // Headers can repeat: replace each rewritten value in place.
    for (name, old, new) in rewritten {
        if let header::Entry::Occupied(mut entry) = req.headers_mut().entry(&name) {
            for value in entry.iter_mut() {
                if *value == old {
                    *value = new.clone();
                }
            }
        }
    }
    for secret in &used {
        tracing::info!(secret = %secret, host = %host, port, "vault.egress_substituted");
    }
    let mut sender = sender.lock().await;
    if sender.ready().await.is_err() {
        return Ok(status(StatusCode::BAD_GATEWAY, "upstream closed\n"));
    }
    match sender.send_request(req).await {
        Ok(response) => Ok(response.map(BodyExt::boxed)),
        Err(_) => Ok(status(StatusCode::BAD_GATEWAY, "upstream request failed\n")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn destinations_a_value_may_reach() {
        let at = |a: &str, intercept| reachable(&a.parse().unwrap(), intercept);
        for never in [
            "127.0.0.1:443",
            "169.254.169.254:80",
            "0.0.0.0:443",
            "[::1]:443",
            "[::ffff:127.0.0.1]:443",
            "224.0.0.1:443",
            "[fe80::1]:443",
        ] {
            assert!(!at(never, false) && !at(never, true), "{never}");
        }
        // Inside the machine's network: a blind tunnel may go there, a value never.
        for internal in [
            "10.0.0.5:443",
            "172.16.4.1:443",
            "192.168.1.1:443",
            "100.64.0.1:443",
            "100.127.255.254:443",
            "198.18.0.1:443",
            "192.0.0.8:443",
            "240.0.0.1:443",
            "[fc00::1]:443",
            "[fd12:3456::1]:443",
            "[::ffff:10.0.0.5]:443",
            "168.63.129.16:80",
            "[64:ff9b::a00:5]:443",
            "[2002:c0a8:101::1]:443",
        ] {
            assert!(at(internal, false) && !at(internal, true), "{internal}");
        }
        // NAT64 and 6to4 forms of loopback are never reached, tunnel or not.
        assert!(!at("[64:ff9b::7f00:1]:443", false) && !at("[2002:7f00:1::1]:443", false));
        for public in [
            "140.82.112.6:443",
            "100.128.0.1:443",
            "[2606:4700::1111]:443",
            "[64:ff9b::8c52:7006]:443",
        ] {
            assert!(at(public, false) && at(public, true), "{public}");
        }
    }

    #[test]
    fn authority_match_is_host_and_port() {
        assert!(same_authority("api.github.com", "api.github.com", 443));
        assert!(same_authority("API.GitHub.com:443", "api.github.com", 443));
        assert!(!same_authority("api.github.com:8443", "api.github.com", 443));
        assert!(!same_authority("evil.test", "api.github.com", 443));
        assert!(!same_authority("evil.test@api.github.com", "api.github.com", 443));
    }
}

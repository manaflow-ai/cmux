//! BR-R3 on the headless engine (cx-d0d.79, coordinator call 2026-10-12): a
//! session under a domain policy gets its own SOCKS5 listener on 127.0.0.1,
//! and every browser context its tabs open in names it as `proxyServer`.
//! Every TCP connection those tabs make (navigations, subresources, fetch,
//! and the WebSockets that CDP `Fetch` never sees; not WebRTC UDP, which
//! only an isolated host turns off) names its host here, and
//! a host the session's live policy does not allow is refused before a byte
//! leaves. An allowed connection then goes on as it would without the
//! listener: straight to the host, or on an isolated host
//! (crate::egress_scope) through the host's egress listener, so its range
//! rule still applies to every connection.
//!
//! The check is by host and port only (a SOCKS request carries no scheme):
//! a host passes when the policy allows it for http or https. The gate's
//! request filter still decides each request by its full URL first.

use crate::egress_proxy::{self, Connector, Listening, reply};
use crate::egress_scope::Target;
use std::io::{self, Read, Write};
use std::net::{SocketAddr, TcpStream, ToSocketAddrs};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

/// Whether a connection to `host` (a name or an IP literal) on `port` is
/// allowed.
pub type ConnectionPolicy = Arc<dyn Fn(&str, u16) -> bool + Send + Sync>;

/// How long the handshake with the egress listener may take.
const UPSTREAM_TIMEOUT: Duration = Duration::from_secs(10);

/// One session's listener. Dropping it stops accepting.
pub struct PolicyListener {
    listening: Listening,
    connector: Arc<PolicyConnector>,
}

impl PolicyListener {
    /// Starts a listener that checks `policy` (None: every host passes),
    /// then reaches the host directly or through `egress` (the isolated
    /// host's listener).
    pub fn start(policy: Option<ConnectionPolicy>, egress: Option<SocketAddr>) -> io::Result<Self> {
        let connector = Arc::new(PolicyConnector { policy: Mutex::new(policy), egress });
        let listening = egress_proxy::start_with(connector.clone())?;
        Ok(PolicyListener { listening, connector })
    }

    /// The `proxyServer` for a browser context.
    pub fn proxy_server(&self) -> String {
        format!("socks5://{}", self.listening.addr)
    }

    /// The live policy (None: every host passes); connections already open
    /// keep going.
    pub fn set_policy(&self, policy: Option<ConnectionPolicy>) {
        *self.connector.policy.lock().unwrap_or_else(PoisonError::into_inner) = policy;
    }
}

struct PolicyConnector {
    policy: Mutex<Option<ConnectionPolicy>>,
    egress: Option<SocketAddr>,
}

impl Connector for PolicyConnector {
    fn connect(&self, target: &Target, own: SocketAddr) -> Result<TcpStream, u8> {
        let (host, port) = match target {
            Target::Name(name, port) => (name.clone(), *port),
            Target::Address(addr) => (addr.ip().to_string(), addr.port()),
        };
        let policy = self.policy.lock().unwrap_or_else(PoisonError::into_inner).clone();
        if policy.is_some_and(|allowed| !allowed(&host, port)) {
            return Err(reply::NOT_ALLOWED);
        }
        match self.egress {
            Some(egress) => through(egress, target),
            None => direct(target, own),
        }
    }
}

/// Resolves and dials `target`; never the listener itself.
fn direct(target: &Target, own: SocketAddr) -> Result<TcpStream, u8> {
    let addrs: Vec<SocketAddr> = match target {
        Target::Address(addr) => vec![*addr],
        Target::Name(name, port) => {
            (name.as_str(), *port).to_socket_addrs().map_err(|_| reply::HOST_UNREACHABLE)?.collect()
        }
    };
    if addrs.is_empty() {
        return Err(reply::HOST_UNREACHABLE);
    }
    if addrs.iter().any(|addr| egress_proxy::is_self(*addr, own)) {
        return Err(reply::NOT_ALLOWED);
    }
    egress_proxy::dial(&addrs).map_err(|error| egress_proxy::dial_failure(&error))
}

/// A SOCKS5 CONNECT to `target` through the egress listener; its refusal
/// code is passed on.
fn through(egress: SocketAddr, target: &Target) -> Result<TcpStream, u8> {
    let attempt = || -> io::Result<Result<TcpStream, u8>> {
        let mut stream = TcpStream::connect_timeout(&egress, UPSTREAM_TIMEOUT)?;
        stream.set_read_timeout(Some(UPSTREAM_TIMEOUT))?;
        stream.write_all(&[5, 1, 0])?;
        let mut choice = [0u8; 2];
        stream.read_exact(&mut choice)?;
        if choice != [5, 0] {
            return Ok(Err(reply::FAILURE));
        }
        let mut request = vec![5, 1, 0];
        match target {
            Target::Address(SocketAddr::V4(addr)) => {
                request.push(1);
                request.extend(addr.ip().octets());
                request.extend(addr.port().to_be_bytes());
            }
            Target::Address(SocketAddr::V6(addr)) => {
                request.push(4);
                request.extend(addr.ip().octets());
                request.extend(addr.port().to_be_bytes());
            }
            Target::Name(name, port) => {
                let Ok(len) = u8::try_from(name.len()) else {
                    return Ok(Err(reply::ADDRESS_UNSUPPORTED));
                };
                request.push(3);
                request.push(len);
                request.extend(name.as_bytes());
                request.extend(port.to_be_bytes());
            }
        }
        stream.write_all(&request)?;
        // The egress listener always answers with an IPv4 bound address.
        let mut answer = [0u8; 10];
        stream.read_exact(&mut answer)?;
        if answer[1] != reply::OK {
            return Ok(Err(answer[1]));
        }
        stream.set_read_timeout(None)?;
        Ok(Ok(stream))
    };
    attempt().unwrap_or(Err(reply::FAILURE))
}

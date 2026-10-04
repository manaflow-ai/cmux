//! Browser proxy route (cloud-app.md 3.5, remote-localhost.md 2 and 5): one
//! HTTP proxy per machine on 127.0.0.1 and a random port. A browser tab
//! whose proxy is this route reaches the machine's loopback services, and
//! only them.
//!
//! The proxy accepts `CONNECT host:port` (HTTPS, WebSocket, HTTP/2 over TLS)
//! and absolute-form HTTP/1.1 (`GET http://localhost:3000/ HTTP/1.1`, sent
//! on as origin form with `Connection: close`). The host must be the machine:
//! `localhost`, a name under `.localhost`, or a loopback IP literal, decided
//! from the literal text with no DNS. Any other host is refused with 403, so
//! a tab can never reach this Mac or the internet through the route. An
//! origin-form request (a page's own fetch to the proxy port) is refused
//! with 400. The machine's daemon checks the host again.
//!
//! Gap (flagged): any local process can use the route, like an SSH `-L`
//! forward. The Swift proxy checks the peer process; this server cannot,
//! because the browser helpers are not its children. The browser host lead
//! owns the follow-up (a per-tab route with fd passing or a credential).

use crate::link::Carrier;
use crate::ports::listener::{Handler, Session};
use crate::ports::tunnel::PortTunnel;
use std::io::{Read, Write};
use std::net::{IpAddr, TcpStream};
use std::sync::Arc;
use std::time::Duration;

/// Bound on the request head.
pub const MAX_HEAD: usize = 16 * 1024;
const HEAD_DEADLINE: Duration = Duration::from_secs(10);

/// True when `host` names the machine itself (literal rule, no DNS).
pub fn is_machine_host(host: &str) -> bool {
    let host = normal_host(host);
    if host == "localhost" || host.ends_with(".localhost") {
        // Names: letter, digit and hyphen labels only.
        return host.split('.').all(|label| {
            !label.is_empty() && label.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
        });
    }
    let bare = host.strip_prefix('[').and_then(|h| h.strip_suffix(']')).unwrap_or(&host);
    match bare.parse::<IpAddr>() {
        Ok(IpAddr::V4(v4)) => v4.is_loopback(),
        Ok(IpAddr::V6(v6)) => {
            v6.is_loopback() || v6.to_ipv4_mapped().is_some_and(|v4| v4.is_loopback())
        }
        Err(_) => false,
    }
}

/// The host as the daemon gets it: lower case, no trailing dot.
pub fn normal_host(host: &str) -> String {
    host.strip_suffix('.').unwrap_or(host).to_ascii_lowercase()
}

/// A parsed request target.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Target {
    pub host: String,
    pub port: u16,
    /// CONNECT: a byte tunnel. Otherwise the request head to send on.
    pub forward_head: Option<Vec<u8>>,
}

/// Why a request is refused (status code and text).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Refusal {
    pub status: u16,
    pub reason: String,
}

fn refuse(status: u16, reason: impl Into<String>) -> Refusal {
    Refusal { status, reason: reason.into() }
}

/// Splits `host:port` (`[v6]:port` for IPv6).
fn host_port(authority: &str, default: Option<u16>) -> Option<(String, u16)> {
    let (host, port) = match authority.rsplit_once(':') {
        Some((h, p)) if !h.is_empty() && (!h.contains(':') || h.ends_with(']')) => {
            (h, p.parse().ok()?)
        }
        _ => (authority, default?),
    };
    (port != 0 && !host.is_empty()).then(|| (host.to_owned(), port))
}

/// Parses a request head (everything up to and with the blank line).
pub fn parse_head(head: &[u8]) -> Result<Target, Refusal> {
    let text = std::str::from_utf8(head).map_err(|_| refuse(400, "the request is not text"))?;
    let mut lines = text.split("\r\n");
    let first = lines.next().unwrap_or_default();
    let mut parts = first.split(' ');
    let (Some(method), Some(target), Some(version), None) =
        (parts.next(), parts.next(), parts.next(), parts.next())
    else {
        return Err(refuse(400, "bad request line"));
    };
    if !version.starts_with("HTTP/1.") || method.is_empty() {
        return Err(refuse(400, "bad request line"));
    }
    if method == "CONNECT" {
        let (host, port) =
            host_port(target, None).ok_or_else(|| refuse(400, "CONNECT needs host:port"))?;
        return check(Target { host, port, forward_head: None });
    }
    let Some(rest) = target.strip_prefix("http://") else {
        return Err(refuse(400, "only CONNECT and absolute http:// requests are proxied"));
    };
    let (authority, path) = rest.find('/').map_or((rest, "/"), |i| (&rest[..i], &rest[i..]));
    if authority.contains('@') {
        return Err(refuse(400, "credentials in the URL are not proxied"));
    }
    let (host, port) =
        host_port(authority, Some(80)).ok_or_else(|| refuse(400, "bad host in the URL"))?;
    let mut out = format!("{method} {path} {version}\r\n");
    for line in lines.filter(|l| !l.is_empty()) {
        let name = line.split(':').next().unwrap_or_default().trim().to_ascii_lowercase();
        if !matches!(name.as_str(), "connection" | "proxy-connection" | "proxy-authorization") {
            out.push_str(line);
            out.push_str("\r\n");
        }
    }
    out.push_str("Connection: close\r\n\r\n");
    check(Target { host, port, forward_head: Some(out.into_bytes()) })
}

fn check(target: Target) -> Result<Target, Refusal> {
    if is_machine_host(&target.host) {
        Ok(target)
    } else {
        Err(refuse(
            403,
            format!(
                "{} is not this Cloud machine; the route reaches only its localhost",
                target.host
            ),
        ))
    }
}

fn answer(tcp: &mut TcpStream, status: u16, reason: &str) {
    let title = match status {
        400 => "Bad Request",
        403 => "Forbidden",
        431 => "Request Header Fields Too Large",
        _ => "Bad Gateway",
    };
    let body = format!("{reason}\n");
    let _ = write!(
        tcp,
        "HTTP/1.1 {status} {title}\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
}

/// Reads the head; returns it and the bytes after it.
fn read_head(tcp: &mut TcpStream) -> Result<(Vec<u8>, Vec<u8>), Refusal> {
    let _ = tcp.set_read_timeout(Some(HEAD_DEADLINE));
    let mut data = Vec::new();
    let mut chunk = [0u8; 4096];
    loop {
        if let Some(end) = data.windows(4).position(|w| w == b"\r\n\r\n") {
            let rest = data.split_off(end + 4);
            let _ = tcp.set_read_timeout(None);
            return Ok((data, rest));
        }
        if data.len() > MAX_HEAD {
            return Err(refuse(431, "the request head is too large"));
        }
        match tcp.read(&mut chunk) {
            Ok(0) | Err(_) => return Err(refuse(400, "the request ended early")),
            Ok(n) => data.extend_from_slice(&chunk[..n]),
        }
    }
}

/// The connection handler of a machine's proxy route.
pub fn handler(tunnel: Arc<dyn PortTunnel>, carrier: Carrier) -> Handler {
    let identity = crate::ports::LinkIdentity::of(&carrier);
    Arc::new(move |mut tcp: TcpStream, session: &Session| {
        let target = read_head(&mut tcp).and_then(|(head, rest)| Ok((parse_head(&head)?, rest)));
        let (target, rest) = match target {
            Ok(found) => found,
            Err(refusal) => return answer(&mut tcp, refusal.status, &refusal.reason),
        };
        if !identity.still(&carrier) {
            let why = format!("cmux Cloud machine {}: the link was replaced", carrier.target);
            return answer(&mut tcp, 502, &why);
        }
        let conn = match tunnel.open(&carrier, &normal_host(&target.host), target.port) {
            Ok(conn) => conn,
            Err(e) => {
                let why = format!("cmux Cloud machine {}: {e}", carrier.target);
                return answer(&mut tcp, 502, &why);
            }
        };
        let first = match target.forward_head {
            Some(mut head) => {
                head.extend_from_slice(&rest);
                head
            }
            None => {
                if tcp.write_all(b"HTTP/1.1 200 Connection Established\r\n\r\n").is_err() {
                    conn.abort.abort();
                    return;
                }
                rest
            }
        };
        session.splice(tcp, conn, first);
    })
}

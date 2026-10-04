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

use crate::connector::iface::Carrier;
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
        todo!("C5 red: not built yet")
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
        todo!("C5 red: not built yet")
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
        todo!("C5 red: not built yet")
    }

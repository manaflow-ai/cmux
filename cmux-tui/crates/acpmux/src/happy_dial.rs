//! Outbound TCP dials to a host by name that do not wait out one stalled address.
//!
//! `TcpStream::connect(host:port)` and `connect_async` try a name's addresses one at a time, so a
//! first address whose SYNs go nowhere (a family with a lossy or missing route) costs the kernel's
//! whole SYN retry window before the second is tried. [`connect_tcp`] resolves the name, puts
//! IPv6 first with the families alternating ([`interleave`], RFC 8305), and starts the next
//! attempt [`STAGGER`] after the previous one when it has not connected (happy eyeballs). The
//! resolver's own order is not kept: this is a static musl binary, and musl sorts IPv4 first on a
//! host whose only IPv6 address is ULA and reads no `/etc/gai.conf`
//! ([`cmux_vault_egress::happy`]). The first connect wins and the other attempts are dropped. The caller bounds
//! the whole dial with its own timeout; dropping the future drops every attempt.

use std::future::Future;
use std::io;
use std::net::SocketAddr;
use std::time::Duration;

use futures_util::StreamExt as _;
use futures_util::stream::FuturesUnordered;
use tokio::net::TcpStream;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::handshake::client::{Request, Response};
use tokio_tungstenite::tungstenite::{Error as WsError, error::UrlError};
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream};

/// How long an attempt has alone before the next address is also tried (RFC 8305's "connection
/// attempt delay" recommends 250 ms).
pub const STAGGER: Duration = cmux_vault_egress::happy::STAGGER;

/// A WebSocket over [`connect_tcp`]'s stream, as `connect_async` returns it.
pub type Socket = WebSocketStream<MaybeTlsStream<TcpStream>>;

/// `addresses` IPv6 first, the two families alternating; the order within a family is kept.
pub fn interleave(addresses: &[SocketAddr]) -> Vec<SocketAddr> {
    cmux_vault_egress::happy::v6_first(addresses)
}

/// Connect to the first of `addresses` that answers: attempts start in order, `stagger` apart,
/// and a failed attempt starts the next at once. The error is the last attempt's.
pub async fn race<T, F, Fut>(
    addresses: &[SocketAddr],
    stagger: Duration,
    mut dial: F,
) -> io::Result<T>
where
    F: FnMut(SocketAddr) -> Fut,
    Fut: Future<Output = io::Result<T>>,
{
    let mut pending = addresses.iter().copied();
    let mut running = FuturesUnordered::new();
    let mut last_error = None;
    loop {
        match pending.next() {
            Some(address) => running.push(dial(address)),
            None if running.is_empty() => {
                return Err(last_error.unwrap_or_else(|| {
                    io::Error::new(io::ErrorKind::NotFound, "no addresses to connect to")
                }));
            }
            None => {}
        }
        // Wait for an attempt to end, or for the stagger when another address remains.
        let wait = tokio::time::sleep(stagger);
        tokio::pin!(wait);
        loop {
            tokio::select! {
                Some(result) = running.next() => match result {
                    Ok(connected) => return Ok(connected),
                    Err(error) => {
                        last_error = Some(error);
                        break;
                    }
                },
                () = &mut wait, if pending.len() > 0 => break,
                else => break,
            }
        }
    }
}

/// Resolve `host` (a name, or an IP literal, with or without brackets) and connect to `port`:
/// [`race`] over the addresses IPv6 first, families interleaved, Nagle off.
pub async fn connect_tcp(host: &str, port: u16) -> io::Result<TcpStream> {
    let bare = host.trim_start_matches('[').trim_end_matches(']');
    let addresses: Vec<SocketAddr> = tokio::net::lookup_host((bare, port)).await?.collect();
    if addresses.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            format!("{bare} resolved to no addresses"),
        ));
    }
    let stream = race(&interleave(&addresses), STAGGER, TcpStream::connect).await?;
    let _ = stream.set_nodelay(true);
    Ok(stream)
}

/// `connect_async` over [`connect_tcp`]: the same TLS and handshake, without waiting out a
/// stalled first address. The caller bounds the whole call.
pub async fn connect_ws(request: impl IntoClientRequest) -> Result<(Socket, Response), WsError> {
    let request: Request = request.into_client_request()?;
    let host = request.uri().host().ok_or(WsError::Url(UrlError::NoHostName))?.to_owned();
    let port = match (request.uri().port_u16(), request.uri().scheme_str()) {
        (Some(port), _) => port,
        (None, Some("wss")) => 443,
        (None, Some("ws")) => 80,
        _ => return Err(WsError::Url(UrlError::UnsupportedUrlScheme)),
    };
    let tcp = connect_tcp(&host, port).await.map_err(WsError::Io)?;
    tokio_tungstenite::client_async_tls_with_config(request, tcp, None, None).await
}

#[cfg(test)]
#[path = "happy_dial_tests.rs"]
mod tests;

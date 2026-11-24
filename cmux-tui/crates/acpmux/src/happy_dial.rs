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
        tokio::select! {
            Some(result) = running.next() => match result {
                Ok(connected) => return Ok(connected),
                Err(error) => last_error = Some(error),
            },
            () = &mut wait, if pending.len() > 0 => {}
            else => {}
        }
    }
}

/// Resolve `host` (a name, or an IP literal, with or without brackets) and connect to `port`:
/// [`race`] over the addresses IPv6 first, families interleaved, Nagle off.
/// The egress gate checks `host` first (docs/privacy.md, Egress gate).
pub async fn connect_tcp(host: &str, port: u16) -> io::Result<TcpStream> {
    let bare = host.trim_start_matches('[').trim_end_matches(']');
    cmux_egress::check(bare, "acpmux::happy_dial::connect_tcp")
        .map_err(|refused| io::Error::new(io::ErrorKind::PermissionDenied, refused))?;
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

/// At most this many attempts run at once in [`again`]; at the cap a fresh attempt replaces
/// the oldest, whose next SYN is the furthest off.
pub const AGAIN_AT_MOST: usize = 4;

/// `dial` now, again every `every` and at once on each `kick`, keeping at most `at_most`
/// attempts (the oldest is dropped to make room), until one succeeds or one fails with no
/// other running. The attempts are polled here, not spawned, so `dial` may borrow its caller
/// (a whole link open: connect, TLS and the WebSocket upgrade); returning drops every attempt
/// still running, closing its socket.
pub async fn again<T, E, F, Fut, K, KFut>(
    every: Duration,
    at_most: usize,
    mut kick: K,
    mut dial: F,
) -> Result<T, E>
where
    F: FnMut() -> Fut,
    Fut: Future<Output = Result<T, E>>,
    K: FnMut() -> KFut,
    KFut: Future<Output = ()>,
{
    let at_most = at_most.max(1);
    let mut running: std::collections::VecDeque<std::pin::Pin<Box<Fut>>> =
        std::collections::VecDeque::new();
    let mut start = |running: &mut std::collections::VecDeque<std::pin::Pin<Box<Fut>>>| {
        if running.len() >= at_most {
            running.pop_front();
        }
        running.push_back(Box::pin(dial()));
    };
    start(&mut running);
    let mut next = tokio::time::Instant::now() + every;
    let mut kicked = Box::pin(kick());
    loop {
        let settled = std::future::poll_fn(|cx| {
            for (index, attempt) in running.iter_mut().enumerate() {
                if let std::task::Poll::Ready(result) = attempt.as_mut().poll(cx) {
                    return std::task::Poll::Ready((index, result));
                }
            }
            std::task::Poll::Pending
        });
        tokio::select! {
            (index, result) = settled => {
                drop(running.remove(index));
                match result {
                    Ok(opened) => return Ok(opened),
                    Err(error) if running.is_empty() => return Err(error),
                    Err(_) => {}
                }
            }
            () = tokio::time::sleep_until(next) => {
                start(&mut running);
                next += every;
            }
            () = &mut kicked => {
                start(&mut running);
                next = tokio::time::Instant::now() + every;
                kicked = Box::pin(kick());
            }
        }
    }
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

/// reqwest's resolver for the daemon's HTTP clients: the system lookup, then [`interleave`].
///
/// reqwest's connector already races the families: it dials the addresses of the first
/// address's family and starts the other family 300 ms later (RFC 8305). Its default resolver
/// hands it musl's order, IPv4 first on a host whose only IPv6 is ULA, so the race always led
/// with IPv4 and IPv6 only got the leftovers of a stalled IPv4 dial. Handing it IPv6 first makes
/// IPv6 the lead and IPv4 the hedge; a name with no AAAA (GitHub's) resolves and dials as before.
#[derive(Clone)]
pub struct V6FirstResolver {
    lookup: std::sync::Arc<dyn Fn(String) -> Lookup + Send + Sync>,
}

/// A name's addresses, as [`V6FirstResolver`]'s lookup returns them (the port is replaced).
pub type Lookup = std::pin::Pin<Box<dyn Future<Output = io::Result<Vec<SocketAddr>>> + Send>>;

impl Default for V6FirstResolver {
    fn default() -> Self {
        Self::with_lookup(|host| {
            Box::pin(
                async move { Ok(tokio::net::lookup_host((host.as_str(), 0)).await?.collect()) },
            )
        })
    }
}

impl V6FirstResolver {
    /// Resolve with `lookup` instead of the system's (tests: a name with both families).
    pub fn with_lookup(lookup: impl Fn(String) -> Lookup + Send + Sync + 'static) -> Self {
        Self { lookup: std::sync::Arc::new(lookup) }
    }
}

impl reqwest::dns::Resolve for V6FirstResolver {
    fn resolve(&self, name: reqwest::dns::Name) -> reqwest::dns::Resolving {
        let lookup = (self.lookup)(name.as_str().to_owned());
        Box::pin(async move {
            let addresses = lookup.await?;
            let addresses: reqwest::dns::Addrs = Box::new(interleave(&addresses).into_iter());
            Ok(addresses)
        })
    }
}

/// `reqwest::Client::builder()` with [`V6FirstResolver`] behind the egress gate: every HTTP
/// client the daemon builds starts here, so each passes docs/privacy.md's host list
/// (`cmux_egress`) and then leads with IPv6 where the host has it, hedging IPv4 after 300 ms.
pub fn http_client() -> reqwest::ClientBuilder {
    cmux_egress::client_builder_with("acpmux::happy_dial::http_client", V6FirstResolver::default())
}

#[cfg(test)]
#[path = "happy_dial_tests.rs"]
mod tests;

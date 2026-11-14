//! Port-enforcing transport for namespace listeners passed over SCM_RIGHTS.
//! The keeper owns these services until the sandboxed command exits.
//! Stricter than Seatbelt: reject unspecified (including IPv4 0/8), link-local,
//! multicast and limited broadcast destinations; only the fixed forwarder can
//! reach loopback. No filesystem access, request logging or redirect handling.
//! Deprecated IPv4-compatible, 6to4 and Teredo destinations are refused outright.
//! NAT64/SIIT must pass IPv4 policy and never receive the loopback API exception.
#![allow(dead_code)] // Removed when the Linux sandbox spawn wires this module.

use std::{
    future::Future,
    io,
    net::{IpAddr, SocketAddr},
    sync::Arc,
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    task::JoinSet,
};
use tokio_util::sync::CancellationToken;

const HEADER_LIMIT: usize = 16 * 1024;
const HEADER_TIMEOUT: Duration = Duration::from_secs(30);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_TUNNELS: usize = 256;

#[derive(Clone, Copy, Debug, Default)]
pub(crate) struct NetPolicy {
    /// API port and whether its route is loopback (never opens external egress).
    pub(crate) api: Option<(u16, bool)>,
}

fn normalized(ip: IpAddr) -> IpAddr {
    match ip {
        IpAddr::V6(v6) => v6.to_ipv4_mapped().map_or(ip, IpAddr::V4),
        _ => ip,
    }
}

/// Seatbelt port policy, tightened for metadata and non-unicast destinations.
/// The loopback API exception describes only `serve_forward`; the proxy excludes it.
/// Embedded-address iteration stops after four candidates; recursion ends at IPv4.
pub(crate) fn allowed(policy: &NetPolicy, addr: SocketAddr) -> bool {
    if let IpAddr::V6(v6) = addr.ip() {
        let s = v6.segments();
        let b = v6.octets();
        if (s[..6] == [0; 6] && !v6.is_unspecified() && !v6.is_loopback())
            || s[0] == 0x2002
            || s[..2] == [0x2001, 0]
        {
            return false;
        }
        let last = [b[12], b[13], b[14], b[15]];
        // SIIT ::ffff:0:a.b.c.d expands to 0:0:0:0:ffff:0:<IPv4 high>:<IPv4 low>.
        let translated = s[..6] == [0x64, 0xff9b, 0, 0, 0, 0] || s[..6] == [0, 0, 0, 0, 0xffff, 0];
        let local_nat64 = s[..3] == [0x64, 0xff9b, 1];
        if translated || local_nat64 {
            // RFC 6052 /48, /56 and /64 skip the reserved byte at index 8.
            // With no translation-prefix configuration, require ALL possible
            // layouts under the local /48 to pass (conservatively stricter).
            let candidates = if local_nat64 {
                [
                    [b[6], b[7], b[9], b[10]],
                    [b[7], b[9], b[10], b[11]],
                    [b[9], b[10], b[11], b[12]],
                    last,
                ]
            } else {
                [last; 4]
            };
            return candidates.into_iter().all(|bytes| {
                let v4 = std::net::Ipv4Addr::from(bytes);
                !v4.is_loopback() && allowed(policy, SocketAddr::new(v4.into(), addr.port()))
            });
        }
    }
    let ip = normalized(addr.ip());
    if addr.port() == 0 {
        return false;
    }
    if ip.is_loopback() {
        return policy.api == Some((addr.port(), true));
    }
    let excluded = match ip {
        IpAddr::V4(v4) => v4.octets()[0] == 0 || v4.is_link_local() || v4.is_broadcast(),
        IpAddr::V6(v6) => v6.is_unspecified() || v6.is_unicast_link_local(),
    };
    !excluded
        && !ip.is_multicast()
        && (matches!(addr.port(), 80 | 443) || policy.api == Some((addr.port(), false)))
}

/// Stop condition: `stop` cancellation or accept failure, including every tunnel.
/// Accepts at most 256 live connections; headers are limited to 16 KiB and 30 s.
pub(crate) async fn serve_proxy(
    listener: std::net::TcpListener,
    policy: NetPolicy,
    stop: CancellationToken,
) -> io::Result<()> {
    serve_proxy_with_filter(
        listener,
        move |a| allowed(&policy, a) && !normalized(a.ip()).is_loopback(),
        stop,
    )
    .await
}

/// Forward raw TCP to exactly the supplied loopback API endpoint, never a hostname.
/// Stop condition: `stop` cancellation or accept failure, including every tunnel.
/// The caller supplies the API port; no other loopback destination is reachable.
pub(crate) async fn serve_forward(
    listener: std::net::TcpListener,
    target: SocketAddr,
    stop: CancellationToken,
) -> io::Result<()> {
    if !normalized(target.ip()).is_loopback() || target.port() == 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "API target must be loopback with a nonzero port",
        ));
    }
    serve(
        listener,
        move |client| async move {
            let upstream =
                tokio::time::timeout(CONNECT_TIMEOUT, TcpStream::connect(target)).await??;
            tunnel(client, upstream).await
        },
        stop,
    )
    .await
}

/// Private policy seam for local stand-ins in tests. Stop condition: cancellation
/// or accept failure, delegated to `serve`; production always uses `allowed`.
async fn serve_proxy_with_filter<F>(
    listener: std::net::TcpListener,
    filter: F,
    stop: CancellationToken,
) -> io::Result<()>
where
    F: Fn(SocketAddr) -> bool + Send + Sync + 'static,
{
    let filter = Arc::new(filter);
    serve(
        listener,
        move |client| {
            let filter = filter.clone();
            async move { proxy_connection(client, filter.as_ref()).await }
        },
        stop,
    )
    .await
}

/// Stop condition: cancellation, or an accept failure that means the listener is
/// gone. Any other accept failure (EMFILE, a connection reset in the queue) pauses
/// and accepts again: the keeper ends the sandboxed session when this returns.
/// Shutdown aborts and joins all handlers; dropping this future also aborts them
/// through the owned JoinSet.
async fn serve<F, Fut>(
    listener: std::net::TcpListener,
    handler: F,
    stop: CancellationToken,
) -> io::Result<()>
where
    F: Fn(TcpStream) -> Fut,
    Fut: Future<Output = io::Result<()>> + Send + 'static,
{
    listener.set_nonblocking(true)?;
    let listener = TcpListener::from_std(listener)?;
    let mut tasks = JoinSet::new();
    let result = loop {
        tokio::select! {
            biased;
            _ = stop.cancelled() => break Ok(()),
            _ = tasks.join_next(), if !tasks.is_empty() => {},
            accepted = listener.accept(), if tasks.len() < MAX_TUNNELS => {
                let (client, _) = match accepted {
                    Ok(pair) => pair,
                    Err(e) if crate::server::accept_ends_listener(&e) => break Err(e),
                    Err(e) => {
                        tokio::time::sleep(crate::server::accept_retry_delay(&e)).await;
                        continue;
                    }
                };
                let connection = handler(client);
                let stop = stop.clone();
                tasks.spawn(async move {
                    tokio::select! {
                        biased;
                        _ = stop.cancelled() => {},
                        _ = connection => {},
                    }
                });
            }
        }
    };
    tasks.shutdown().await;
    result
}

/// Both directions stop on either EOF/error; the owning handler cancels on `stop`.
async fn tunnel(client: TcpStream, upstream: TcpStream) -> io::Result<()> {
    let (mut cr, mut cw) = client.into_split();
    let (mut ur, mut uw) = upstream.into_split();
    tokio::select! {
        result = tokio::io::copy(&mut cr, &mut uw) => result.map(|_| ()),
        result = tokio::io::copy(&mut ur, &mut cw) => result.map(|_| ()),
    }
}

/// Stops at the header terminator, EOF/error or 16 KiB; caller imposes 30 s and
/// cancellation. Bytes already read after the terminator are preserved unchanged.
async fn read_header(client: &mut TcpStream) -> Result<(Vec<u8>, usize), &'static str> {
    let mut bytes = Vec::new();
    loop {
        let mut chunk = [0; 4096];
        let limit = chunk.len().min(HEADER_LIMIT - bytes.len());
        if limit == 0 {
            return Err("431 Request Header Fields Too Large");
        }
        let n = client
            .read(chunk.get_mut(..limit).unwrap_or_default())
            .await
            .map_err(|_| "400 Bad Request")?;
        if n == 0 {
            return Err("400 Bad Request");
        }
        let scan_from = bytes.len().saturating_sub(3);
        bytes.extend_from_slice(chunk.get(..n).unwrap_or_default());
        if let Some(at) =
            bytes.get(scan_from..).unwrap_or_default().windows(4).position(|w| w == b"\r\n\r\n")
        {
            return Ok((bytes, scan_from + at + 4));
        }
    }
}

/// No user-controlled response text, logging, or reflected request headers/body.
async fn reply(client: &mut TcpStream, status: &str, reason: &str) -> io::Result<()> {
    let body = format!("{reason}\n");
    client
        .write_all(
            format!(
                "HTTP/1.1 {status}\r\nConnection: close\r\nContent-Length: {}\r\n\r\n{body}",
                body.len()
            )
            .as_bytes(),
        )
        .await
}

fn authority(text: &str, default_port: Option<u16>) -> Option<(String, u16)> {
    let (host, port) = if let Some(rest) = text.strip_prefix('[') {
        let (host, suffix) = rest.split_once(']')?;
        host.parse::<std::net::Ipv6Addr>().ok()?;
        (host, if suffix.is_empty() { None } else { Some(suffix.strip_prefix(':')?) })
    } else {
        let (host, port) = text.split_once(':').map_or((text, None), |(h, p)| (h, Some(p)));
        if host.is_empty()
            || !host.bytes().all(|b| b.is_ascii_alphanumeric() || b".-_".contains(&b))
        {
            return None;
        }
        (host, port)
    };
    let port = match port {
        Some(p) if !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit()) => p.parse().ok()?,
        Some(_) => return None,
        None => default_port?,
    };
    (port != 0).then(|| (host.to_owned(), port))
}

// None for the rewritten line denotes CONNECT. Hosts come only from the request
// target, never Host, redirects or request bodies. Reject credentials and zones.
fn request(line: &str) -> Option<(String, u16, Option<String>)> {
    let mut parts = line.split(' ');
    let (method, target, version) = (parts.next()?, parts.next()?, parts.next()?);
    if parts.next().is_some()
        || version != "HTTP/1.1"
        || method.is_empty()
        || !method.bytes().all(|b| b.is_ascii_uppercase())
        || !target.bytes().all(|b| (0x21..=0x7e).contains(&b) && b != b'#')
    {
        return None;
    }
    if method == "CONNECT" {
        let (host, port) = authority(target, None)?;
        return Some((host, port, None));
    }
    let rest = target.strip_prefix("http://")?;
    let at = rest.find(['/', '?']).unwrap_or(rest.len());
    let (authority_text, path) = rest.split_at_checked(at)?;
    let (host, port) = authority(authority_text, Some(80))?;
    let path = if path.starts_with('/') { path.to_owned() } else { format!("/{path}") };
    Some((host, port, Some(format!("{method} {path} HTTP/1.1\r\n"))))
}

/// Stops on header/DNS deadline (30 s), each connect deadline (10 s), finite
/// address-list exhaustion, tunnel EOF/error, or the owning handler's `stop`.
async fn proxy_connection<F>(mut client: TcpStream, filter: &F) -> io::Result<()>
where
    F: Fn(SocketAddr) -> bool + Sync,
{
    let (bytes, end) = match tokio::time::timeout(HEADER_TIMEOUT, read_header(&mut client)).await {
        Ok(Ok(value)) => value,
        Ok(Err(status)) => return reply(&mut client, status, "invalid or oversized header").await,
        Err(_) => {
            return reply(&mut client, "408 Request Timeout", "header deadline exceeded").await;
        }
    };
    let Some(line_end) = bytes.get(..end).unwrap_or_default().windows(2).position(|w| w == b"\r\n")
    else {
        return reply(&mut client, "400 Bad Request", "missing request line terminator").await;
    };
    let parsed =
        std::str::from_utf8(bytes.get(..line_end).unwrap_or_default()).ok().and_then(request);
    let Some((host, port, rewritten)) = parsed else {
        return reply(&mut client, "400 Bad Request", "invalid proxy request target").await;
    };
    // One lookup only; connecting takes the checked SocketAddr, not the hostname.
    let addresses =
        match tokio::time::timeout(HEADER_TIMEOUT, tokio::net::lookup_host((host.as_str(), port)))
            .await
        {
            Ok(Ok(addresses)) => addresses,
            _ => return reply(&mut client, "502 Bad Gateway", "name resolution failed").await,
        };
    let mut permitted = false;
    for addr in addresses {
        if !filter(addr) {
            continue;
        }
        permitted = true;
        let Ok(Ok(mut upstream)) =
            tokio::time::timeout(CONNECT_TIMEOUT, TcpStream::connect(addr)).await
        else {
            continue;
        };
        if let Some(line) = rewritten {
            upstream.write_all(line.as_bytes()).await?;
            upstream.write_all(bytes.get(line_end + 2..).unwrap_or_default()).await?;
        } else {
            client.write_all(b"HTTP/1.1 200 Connection Established\r\n\r\n").await?;
            upstream.write_all(bytes.get(end..).unwrap_or_default()).await?;
        }
        return tunnel(client, upstream).await;
    }
    if permitted {
        reply(&mut client, "502 Bad Gateway", "no permitted destination connected").await
    } else {
        reply(&mut client, "403 Forbidden", "destination denied by network policy").await
    }
}

/// Table loops stop at their finite inputs. Test services stop on cancellation
/// (or runtime teardown after a panic); test waits have the `bounded` deadline.
#[cfg(test)]
mod tests;

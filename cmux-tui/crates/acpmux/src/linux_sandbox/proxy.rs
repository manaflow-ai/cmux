//! Port-enforcing transport for namespace listeners passed over SCM_RIGHTS.
//! Deliberately unwired until G2; remote sandbox refusal stays unchanged.
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

/// Stop condition: cancellation or accept failure. Shutdown aborts and joins all
/// handlers; dropping this future also aborts them through the owned JoinSet.
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
                    Err(e) => break Err(e),
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
        let n = client.read(&mut chunk[..limit]).await.map_err(|_| "400 Bad Request")?;
        if n == 0 {
            return Err("400 Bad Request");
        }
        let scan_from = bytes.len().saturating_sub(3);
        bytes.extend_from_slice(&chunk[..n]);
        if let Some(at) = bytes[scan_from..].windows(4).position(|w| w == b"\r\n\r\n") {
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
    let (host, port) = authority(&rest[..at], Some(80))?;
    let path = &rest[at..];
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
    let Some(line_end) = bytes[..end].windows(2).position(|w| w == b"\r\n") else {
        return reply(&mut client, "400 Bad Request", "missing request line terminator").await;
    };
    let parsed = std::str::from_utf8(&bytes[..line_end]).ok().and_then(request);
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
            upstream.write_all(&bytes[line_end + 2..]).await?;
        } else {
            client.write_all(b"HTTP/1.1 200 Connection Established\r\n\r\n").await?;
            upstream.write_all(&bytes[end..]).await?;
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
mod tests {
    use super::*;
    use std::{future::Future, time::Duration};
    use tokio::{
        io::{AsyncReadExt, AsyncWriteExt},
        net::{TcpListener, TcpStream},
    };

    /// Every test wait ends after three seconds, even when a stub or regression stalls.
    async fn bounded<T>(f: impl Future<Output = T>) -> T {
        tokio::time::timeout(Duration::from_secs(3), f).await.expect("test timed out")
    }

    fn listener() -> (std::net::TcpListener, SocketAddr) {
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = l.local_addr().unwrap();
        (l, addr)
    }

    /// Stops at CRLF CRLF or the three-second test deadline; never consumes tunnel bytes.
    async fn headers(stream: &mut TcpStream) -> String {
        bounded(async {
            let mut bytes = Vec::new();
            while !bytes.ends_with(b"\r\n\r\n") {
                bytes.push(stream.read_u8().await.unwrap());
                assert!(bytes.len() <= 16 * 1024);
            }
            String::from_utf8(bytes).unwrap()
        })
        .await
    }

    #[test]
    fn allowed_address_and_port_table() {
        let none = NetPolicy::default();
        let external = NetPolicy { api: Some((31415, false)) };
        let local = NetPolicy { api: Some((31415, true)) };
        for (text, expected) in [
            ("8.8.8.8:80", true),
            ("8.8.8.8:443", true),
            ("[2606:4700:4700::1111]:443", true),
            ("[::ffff:8.8.8.8]:80", true),
            ("[::127.0.0.1]:443", false),
            ("[::8.8.8.8]:80", false),
            ("[2002:7f00:1::]:443", false),
            ("[2002:808:808::]:80", false),
            ("[2001:0:1234:5678:9abc:def0:80ff:fffe]:443", false),
            ("[2001:0:1234:5678:9abc:def0:f7f7:f7f7]:80", false),
            ("[64:ff9b::7f00:1]:443", false),
            ("[64:ff9b::a9fe:a9fe]:80", false),
            ("[64:ff9b::e000:1]:443", false),
            ("[64:ff9b::ffff:ffff]:80", false),
            ("[64:ff9b::]:80", false),
            ("[64:ff9b::808:808]:443", true),
            ("[::ffff:0:7f00:1]:443", false),
            ("[::ffff:0:a9fe:a9fe]:80", false),
            ("[::ffff:0:e000:1]:443", false),
            ("[::ffff:0:ffff:ffff]:80", false),
            ("[::ffff:0:0:0]:443", false),
            ("[::ffff:0:808:808]:80", true),
            // Local NAT64 may use /48, /56, /64 or /96: RFC 6052 skips byte 8.
            ("[64:ff9b:1:7f00:0:108:808:808]:443", false),
            ("[64:ff9b:1:87f:0:1:808:808]:443", false),
            ("[64:ff9b:1:808:7f:0:108:808]:443", false),
            ("[64:ff9b:1:808:8:808:7f00:1]:443", false),
            ("[64:ff9b:1:a9fe:a9:fe08:808:808]:80", false),
            ("[64:ff9b:1:808:8:808:808:808]:443", true),
            ("10.0.0.1:443", true),
            ("8.8.8.8:22", false),
            ("8.8.8.8:0", false),
            ("127.0.0.1:443", false),
            ("127.12.34.56:80", false),
            ("[::1]:443", false),
            ("[::ffff:127.0.0.1]:443", false),
            ("0.0.0.0:80", false),
            ("0.1.2.3:80", false),
            ("[::ffff:0.1.2.3]:443", false),
            ("[::]:80", false),
            ("[::ffff:0.0.0.0]:80", false),
            ("169.254.169.254:80", false),
            ("[::ffff:169.254.169.254]:80", false),
            ("[fe80::1]:443", false),
            ("[febf::1]:443", false),
            ("224.0.0.1:80", false),
            ("239.255.255.255:443", false),
            ("[::ffff:224.0.0.1]:80", false),
            ("[ff02::1]:443", false),
            ("255.255.255.255:80", false),
            ("[::ffff:255.255.255.255]:80", false),
        ] {
            assert_eq!(allowed(&none, text.parse().unwrap()), expected, "{text}");
        }
        for text in ["8.8.8.8:31415", "[2606:4700:4700::1111]:31415"] {
            let addr = text.parse().unwrap();
            assert!(allowed(&external, addr));
            assert!(!allowed(&local, addr), "loopback API port must not open external egress");
            assert!(!allowed(&none, addr));
        }
        for text in ["127.0.0.1:31415", "[::1]:31415", "[::ffff:127.0.0.1]:31415"] {
            let addr = text.parse().unwrap();
            assert!(allowed(&local, addr));
            assert!(!allowed(&external, addr));
            assert!(!allowed(&none, addr));
        }
        assert!(!allowed(&local, "127.0.0.1:31416".parse().unwrap()));
        for text in [
            "[64:ff9b::7f00:1]:31415",
            "[::ffff:0:7f00:1]:31415",
            "[64:ff9b:1:808:8:808:7f00:1]:31415",
        ] {
            assert!(!allowed(&local, text.parse().unwrap()), "no translated loopback exception");
        }
        assert!(!allowed(&NetPolicy { api: Some((0, true)) }, "127.0.0.1:0".parse().unwrap()));
    }

    #[tokio::test]
    async fn forbidden_connect_never_reaches_listener_even_for_loopback_api() {
        let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = target.local_addr().unwrap();
        for api in [None, Some((addr.port(), false)), Some((addr.port(), true))] {
            let (l, proxy) = listener();
            let stop = CancellationToken::new();
            let task = tokio::spawn(serve_proxy(l, NetPolicy { api }, stop.clone()));
            let mut client = TcpStream::connect(proxy).await.unwrap();
            client
                .write_all(format!("CONNECT {addr} HTTP/1.1\r\nHost: {addr}\r\n\r\n").as_bytes())
                .await
                .unwrap();
            assert!(headers(&mut client).await.starts_with("HTTP/1.1 403 Forbidden\r\n"));
            let mut reason = String::new();
            bounded(client.read_to_string(&mut reason)).await.unwrap();
            assert_eq!(reason.lines().count(), 1, "one-line reason required");
            assert!(
                tokio::time::timeout(Duration::from_millis(50), target.accept()).await.is_err()
            );
            stop.cancel();
            bounded(task).await.unwrap().unwrap();
        }
    }

    async fn stand_in(
        target: SocketAddr,
    ) -> (TcpStream, CancellationToken, tokio::task::JoinHandle<io::Result<()>>) {
        let (l, proxy) = listener();
        let stop = CancellationToken::new();
        let task = tokio::spawn(serve_proxy_with_filter(l, move |a| a == target, stop.clone()));
        (TcpStream::connect(proxy).await.unwrap(), stop, task)
    }

    #[tokio::test]
    async fn connect_preserves_early_bytes_and_stop_closes_active_tunnel() {
        let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = target.local_addr().unwrap();
        let (mut client, stop, task) = stand_in(addr).await;
        client.write_all(format!("CONNECT {addr} HTTP/1.1\r\n\r\nearly").as_bytes()).await.unwrap();
        let (mut server, _) = bounded(target.accept()).await.unwrap();
        assert!(headers(&mut client).await.starts_with("HTTP/1.1 200 "));
        let mut bytes = [0; 5];
        bounded(server.read_exact(&mut bytes)).await.unwrap();
        assert_eq!(&bytes, b"early");
        server.write_all(b"reply").await.unwrap();
        bounded(client.read_exact(&mut bytes)).await.unwrap();
        assert_eq!(&bytes, b"reply");
        stop.cancel();
        bounded(task).await.unwrap().unwrap();
        assert_eq!(bounded(client.read(&mut bytes)).await.unwrap(), 0);
        assert_eq!(bounded(server.read(&mut bytes)).await.unwrap(), 0);
    }

    #[tokio::test]
    async fn absolute_get_rewrites_origin_form_and_does_not_follow_redirect() {
        let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = target.local_addr().unwrap();
        let (mut client, stop, task) = stand_in(addr).await;
        client
            .write_all(
                format!("GET http://{addr}/path?q=one HTTP/1.1\r\nHost: {addr}\r\n\r\n").as_bytes(),
            )
            .await
            .unwrap();
        let (mut server, _) = bounded(target.accept()).await.unwrap();
        let request = headers(&mut server).await;
        assert!(request.starts_with("GET /path?q=one HTTP/1.1\r\n"), "{request}");
        let redirect =
            b"HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:22/\r\nContent-Length: 0\r\n\r\n";
        server.write_all(redirect).await.unwrap();
        assert_eq!(headers(&mut client).await.as_bytes(), redirect);
        stop.cancel();
        bounded(task).await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn allowed_but_unreachable_returns_502() {
        let (unused, addr) = listener();
        drop(unused);
        let (mut client, stop, task) = stand_in(addr).await;
        client.write_all(format!("CONNECT {addr} HTTP/1.1\r\n\r\n").as_bytes()).await.unwrap();
        assert!(headers(&mut client).await.starts_with("HTTP/1.1 502 "));
        stop.cancel();
        bounded(task).await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn oversized_headers_are_rejected_without_connecting() {
        let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = target.local_addr().unwrap();
        let (mut client, stop, task) = stand_in(addr).await;
        let request = format!("CONNECT {addr} HTTP/1.1\r\nX: {}", "x".repeat(16 * 1024));
        client.write_all(request.as_bytes()).await.unwrap();
        assert!(headers(&mut client).await.starts_with("HTTP/1.1 431 "));
        assert!(tokio::time::timeout(Duration::from_millis(50), target.accept()).await.is_err());
        stop.cancel();
        bounded(task).await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn forward_requires_loopback_and_stop_ends_both_idle_loops() {
        let (l, _) = listener();
        assert!(
            serve_forward(l, "8.8.8.8:80".parse().unwrap(), CancellationToken::new())
                .await
                .is_err()
        );
        let (l, _) = listener();
        let (f, _) = listener();
        let stop = CancellationToken::new();
        let proxy = tokio::spawn(serve_proxy(l, NetPolicy::default(), stop.clone()));
        let forward =
            tokio::spawn(serve_forward(f, "127.0.0.1:12345".parse().unwrap(), stop.clone()));
        tokio::task::yield_now().await;
        stop.cancel();
        bounded(proxy).await.unwrap().unwrap();
        bounded(forward).await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn forward_is_raw_and_stop_closes_its_tunnels() {
        let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let (l, proxy) = listener();
        let stop = CancellationToken::new();
        let task = tokio::spawn(serve_forward(l, target.local_addr().unwrap(), stop.clone()));
        let mut client = TcpStream::connect(proxy).await.unwrap();
        client.write_all(b"raw").await.unwrap();
        let (mut server, _) = bounded(target.accept()).await.unwrap();
        let mut bytes = [0; 3];
        bounded(server.read_exact(&mut bytes)).await.unwrap();
        assert_eq!(&bytes, b"raw");
        server.write_all(b"yes").await.unwrap();
        bounded(client.read_exact(&mut bytes)).await.unwrap();
        assert_eq!(&bytes, b"yes");
        stop.cancel();
        bounded(task).await.unwrap().unwrap();
        assert_eq!(bounded(server.read(&mut bytes)).await.unwrap(), 0);
        assert_eq!(bounded(client.read(&mut bytes)).await.unwrap(), 0);
    }

    #[tokio::test]
    async fn at_most_256_live_tunnels_and_closing_one_releases_capacity() {
        let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = target.local_addr().unwrap();
        let (l, proxy) = listener();
        let stop = CancellationToken::new();
        let task = tokio::spawn(serve_proxy_with_filter(l, move |a| a == addr, stop.clone()));
        let request = format!("CONNECT {addr} HTTP/1.1\r\n\r\n");
        let mut clients = Vec::new();
        let mut servers = Vec::new();
        // Finite loop: fill exactly the specified 256 slots; every wait is bounded.
        for _ in 0..256 {
            let mut client = bounded(TcpStream::connect(proxy)).await.unwrap();
            client.write_all(request.as_bytes()).await.unwrap();
            servers.push(bounded(target.accept()).await.unwrap().0);
            assert!(headers(&mut client).await.starts_with("HTTP/1.1 200 "));
            clients.push(client);
        }
        let mut extra = bounded(TcpStream::connect(proxy)).await.unwrap();
        extra.write_all(request.as_bytes()).await.unwrap();
        assert!(tokio::time::timeout(Duration::from_millis(50), target.accept()).await.is_err());
        drop(clients.pop());
        servers.push(bounded(target.accept()).await.unwrap().0);
        assert!(headers(&mut extra).await.starts_with("HTTP/1.1 200 "));
        stop.cancel();
        bounded(task).await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn stop_cancels_a_partial_header_read() {
        let (l, proxy) = listener();
        let stop = CancellationToken::new();
        let task = tokio::spawn(serve_proxy(l, NetPolicy::default(), stop.clone()));
        let mut client = TcpStream::connect(proxy).await.unwrap();
        client.write_all(b"CONNECT ").await.unwrap();
        tokio::task::yield_now().await;
        stop.cancel();
        bounded(task).await.unwrap().unwrap();
        let mut byte = [0];
        let result = bounded(client.read(&mut byte)).await;
        assert!(matches!(result, Ok(0) | Err(_)), "a partial request survived cancellation");
    }

    #[tokio::test]
    async fn absolute_form_cannot_reach_mapped_loopback() {
        let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = target.local_addr().unwrap().port();
        let (l, proxy) = listener();
        let stop = CancellationToken::new();
        let task =
            tokio::spawn(serve_proxy(l, NetPolicy { api: Some((port, true)) }, stop.clone()));
        let mut client = TcpStream::connect(proxy).await.unwrap();
        client.write_all(format!("GET http://[::ffff:127.0.0.1]:{port}/ HTTP/1.1\r\nHost: harmless.example\r\n\r\n").as_bytes()).await.unwrap();
        assert!(headers(&mut client).await.starts_with("HTTP/1.1 403 Forbidden\r\n"));
        assert!(tokio::time::timeout(Duration::from_millis(50), target.accept()).await.is_err());
        stop.cancel();
        bounded(task).await.unwrap().unwrap();
    }

    #[test]
    fn request_targets_are_unambiguous() {
        for line in [
            "CONNECT host HTTP/1.1",
            "CONNECT host:0 HTTP/1.1",
            "CONNECT host:+443 HTTP/1.1",
            "CONNECT host:65536 HTTP/1.1",
            "CONNECT user@host:443 HTTP/1.1",
            "CONNECT [fe80::1%eth0]:80 HTTP/1.1",
            "GET /relative HTTP/1.1",
            "GET https://host/ HTTP/1.1",
            "GET http://host/#fragment HTTP/1.1",
            "GET http://host/ HTTP/1.0",
            "GET http://host/\r\nInjected:yes HTTP/1.1",
            "GET http://host/ HTTP/1.1 extra",
        ] {
            assert!(request(line).is_none(), "{line:?}");
        }
        assert_eq!(
            request("CONNECT [::ffff:8.8.8.8]:443 HTTP/1.1"),
            Some(("::ffff:8.8.8.8".into(), 443, None))
        );
        assert_eq!(
            request("GET http://host?x=1 HTTP/1.1"),
            Some(("host".into(), 80, Some("GET /?x=1 HTTP/1.1\r\n".into())))
        );
        assert_eq!(
            request("POST http://host:31415 HTTP/1.1"),
            Some(("host".into(), 31415, Some("POST / HTTP/1.1\r\n".into())))
        );
    }

    #[tokio::test]
    async fn partial_header_deadline_is_thirty_seconds() {
        let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let mut client = TcpStream::connect(target.local_addr().unwrap()).await.unwrap();
        let (server, _) = bounded(target.accept()).await.unwrap();
        client.write_all(b"CONNECT ").await.unwrap();
        tokio::time::pause();
        let task = tokio::spawn(async move { proxy_connection(server, &|_| false).await });
        tokio::task::yield_now().await;
        tokio::time::advance(Duration::from_secs(29)).await;
        assert!(!task.is_finished(), "header expired before 30 seconds");
        tokio::time::advance(Duration::from_secs(1)).await;
        bounded(task).await.unwrap().unwrap();
        assert!(headers(&mut client).await.starts_with("HTTP/1.1 408 Request Timeout\r\n"));
    }

    #[tokio::test]
    async fn either_side_eof_ends_the_whole_tunnel() {
        for client_first in [true, false] {
            let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let addr = target.local_addr().unwrap();
            let (mut client, stop, task) = stand_in(addr).await;
            client.write_all(format!("CONNECT {addr} HTTP/1.1\r\n\r\n").as_bytes()).await.unwrap();
            let (mut server, _) = bounded(target.accept()).await.unwrap();
            assert!(headers(&mut client).await.starts_with("HTTP/1.1 200 "));
            if client_first {
                client.shutdown().await.unwrap();
            } else {
                server.shutdown().await.unwrap();
            }
            let mut byte = [0];
            assert_eq!(bounded(client.read(&mut byte)).await.unwrap(), 0);
            assert_eq!(bounded(server.read(&mut byte)).await.unwrap(), 0);
            stop.cancel();
            bounded(task).await.unwrap().unwrap();
        }
    }
}

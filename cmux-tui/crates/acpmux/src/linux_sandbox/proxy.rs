//! Port-enforcing transport for namespace listeners passed over SCM_RIGHTS.
//! Deliberately unwired until G2; remote sandbox refusal stays unchanged.
#![allow(dead_code)] // Removed when the Linux sandbox spawn wires this module.

use std::{io, net::SocketAddr};
use tokio_util::sync::CancellationToken;

#[derive(Clone, Copy, Debug, Default)]
pub(crate) struct NetPolicy {
    pub(crate) api: Option<(u16, bool)>,
}

pub(crate) fn allowed(_policy: &NetPolicy, _addr: SocketAddr) -> bool {
    false
}

/// Stop condition: `stop` cancellation or accept failure, including every tunnel.
pub(crate) async fn serve_proxy(
    _listener: std::net::TcpListener,
    _policy: NetPolicy,
    _stop: CancellationToken,
) -> io::Result<()> {
    Err(io::Error::other("proxy not implemented"))
}

/// Stop condition: `stop` cancellation or accept failure, including every tunnel.
pub(crate) async fn serve_forward(
    _listener: std::net::TcpListener,
    _target: SocketAddr,
    _stop: CancellationToken,
) -> io::Result<()> {
    Err(io::Error::other("forward not implemented"))
}

// Private seam: tests substitute an exact local destination for public egress.
async fn serve_proxy_with_filter<F>(
    _listener: std::net::TcpListener,
    _filter: F,
    _stop: CancellationToken,
) -> io::Result<()>
where
    F: Fn(SocketAddr) -> bool + Send + Sync + 'static,
{
    Err(io::Error::other("proxy not implemented"))
}

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
            ("10.0.0.1:443", true),
            ("8.8.8.8:22", false),
            ("8.8.8.8:0", false),
            ("127.0.0.1:443", false),
            ("127.12.34.56:80", false),
            ("[::1]:443", false),
            ("[::ffff:127.0.0.1]:443", false),
            ("0.0.0.0:80", false),
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

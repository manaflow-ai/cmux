use super::*;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::time::Instant;

fn v4(n: u8) -> SocketAddr {
    SocketAddr::new(IpAddr::V4(Ipv4Addr::new(192, 0, 2, n)), 443)
}

fn v6(n: u16) -> SocketAddr {
    SocketAddr::new(IpAddr::V6(Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, n)), 443)
}

#[test]
fn interleave_starts_with_ipv6_and_keeps_order_within_a_family() {
    let got = interleave(&[v6(1), v6(2), v4(1), v4(2), v4(3)]);
    assert_eq!(got, vec![v6(1), v4(1), v6(2), v4(2), v4(3)]);
    // musl's order on a ULA-only host puts every A record first; IPv6 still goes first.
    let got = interleave(&[v4(1), v4(2), v6(1)]);
    assert_eq!(got, vec![v6(1), v4(1), v4(2)]);
    assert!(interleave(&[]).is_empty());
}

#[tokio::test]
async fn a_black_hole_first_address_loses_to_a_working_second_within_300ms() {
    let started = Instant::now();
    let won = race(&[v6(1), v4(1)], STAGGER, |address| async move {
        if address.is_ipv6() {
            std::future::pending::<io::Result<SocketAddr>>().await
        } else {
            Ok(address)
        }
    })
    .await
    .unwrap();
    assert_eq!(won, v4(1));
    let took = started.elapsed();
    assert!(took >= STAGGER && took < Duration::from_millis(300), "took {took:?}");
}

#[tokio::test]
async fn the_first_address_wins_when_both_work() {
    let won = race(&[v6(1), v4(1)], STAGGER, |address| async move {
        // The later address would answer first, were it started at once.
        let delay = if address.is_ipv6() { 50 } else { 0 };
        tokio::time::sleep(Duration::from_millis(delay)).await;
        Ok(address)
    })
    .await
    .unwrap();
    assert_eq!(won, v6(1));
}

#[tokio::test]
async fn a_refused_first_address_starts_the_next_at_once() {
    let started = Instant::now();
    let won = race(&[v6(1), v4(1)], STAGGER, |address| async move {
        if address.is_ipv6() {
            Err(io::Error::from(io::ErrorKind::ConnectionRefused))
        } else {
            Ok(address)
        }
    })
    .await
    .unwrap();
    assert_eq!(won, v4(1));
    assert!(started.elapsed() < Duration::from_millis(100));
}

#[tokio::test]
async fn every_address_failing_gives_the_last_error() {
    let error = race(&[v6(1), v4(1)], STAGGER, |address| async move {
        Err::<(), _>(io::Error::other(address.to_string()))
    })
    .await
    .unwrap_err();
    assert!(error.to_string().contains("192.0.2.1"), "{error}");
}

/// An HTTP server on `address` that answers every request with `body` and closes.
async fn answering(listener: tokio::net::TcpListener, body: &'static str) {
    use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
    loop {
        let Ok((mut socket, _)) = listener.accept().await else { return };
        tokio::spawn(async move {
            let mut request = [0u8; 4096];
            let _ = socket.read(&mut request).await;
            let reply = format!(
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            let _ = socket.write_all(reply.as_bytes()).await;
        });
    }
}

/// A listener on `[::1]` and one on `127.0.0.1`, on the same port (a URL names one port), or
/// `None` where this machine has no IPv6 loopback.
async fn both_families() -> Option<(tokio::net::TcpListener, tokio::net::TcpListener, u16)> {
    for _ in 0..32 {
        let v6 = tokio::net::TcpListener::bind("[::1]:0").await.ok()?;
        let port = v6.local_addr().ok()?.port();
        if let Ok(v4) = tokio::net::TcpListener::bind(("127.0.0.1", port)).await {
            return Some((v6, v4, port));
        }
    }
    None
}

/// A name that resolves to `addresses`, in that order, as musl hands them over.
fn resolving_to(addresses: Vec<IpAddr>) -> V6FirstResolver {
    V6FirstResolver::with_lookup(move |_| {
        let addresses = addresses.iter().map(|ip| SocketAddr::new(*ip, 0)).collect();
        Box::pin(async move { Ok(addresses) })
    })
}

async fn get(resolver: V6FirstResolver, port: u16) -> (String, Duration) {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let client = reqwest::Client::builder().dns_resolver(resolver).no_proxy().build().unwrap();
    let started = Instant::now();
    let body = tokio::time::timeout(
        Duration::from_secs(5),
        client.get(format!("http://dual.test:{port}/")).send(),
    )
    .await
    .expect("the request ended within 5 s")
    .expect("the request succeeded")
    .text()
    .await
    .unwrap();
    (body, started.elapsed())
}

#[tokio::test]
async fn an_http_client_dials_ipv6_when_the_name_has_both_and_ipv6_answers() {
    let Some((v6, v4, port)) = both_families().await else {
        eprintln!("skipped: no IPv6 loopback on this machine");
        return;
    };
    tokio::spawn(answering(v6, "v6"));
    tokio::spawn(answering(v4, "v4"));
    // IPv4 first, as musl orders a public AAAA on a host whose only IPv6 is ULA.
    let resolver =
        resolving_to(vec![IpAddr::V4(Ipv4Addr::LOCALHOST), IpAddr::V6(Ipv6Addr::LOCALHOST)]);
    let (body, _) = get(resolver, port).await;
    assert_eq!(body, "v6");
}

#[tokio::test]
async fn an_http_client_falls_back_to_ipv4_within_the_hedge_when_ipv6_is_black_holed() {
    let v4 = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = v4.local_addr().unwrap().port();
    tokio::spawn(answering(v4, "v4"));
    // 100::/64 is the discard prefix (RFC 6666): SYNs to it go nowhere, or fail at once
    // where the machine has no IPv6 route. Either way IPv4 must answer within the hedge.
    let black_hole = IpAddr::V6(Ipv6Addr::new(0x100, 0, 0, 0, 0, 0, 0, 1));
    let resolver = resolving_to(vec![IpAddr::V4(Ipv4Addr::LOCALHOST), black_hole]);
    let (body, took) = get(resolver, port).await;
    assert_eq!(body, "v4");
    assert!(took < Duration::from_millis(1500), "took {took:?}");
}

#[tokio::test]
async fn a_name_with_no_aaaa_dials_ipv4_as_before() {
    let v4 = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = v4.local_addr().unwrap().port();
    tokio::spawn(answering(v4, "v4"));
    let (body, _) = get(resolving_to(vec![IpAddr::V4(Ipv4Addr::LOCALHOST)]), port).await;
    assert_eq!(body, "v4");
}

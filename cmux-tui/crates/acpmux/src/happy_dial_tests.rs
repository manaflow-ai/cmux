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
fn interleave_starts_with_the_first_family_and_keeps_order() {
    let got = interleave(&[v6(1), v6(2), v4(1), v4(2), v4(3)]);
    assert_eq!(got, vec![v6(1), v4(1), v6(2), v4(2), v4(3)]);
    let got = interleave(&[v4(1), v4(2), v6(1)]);
    assert_eq!(got, vec![v4(1), v6(1), v4(2)]);
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

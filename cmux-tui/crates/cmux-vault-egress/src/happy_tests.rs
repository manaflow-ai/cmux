use super::*;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

fn v4(n: u8) -> SocketAddr {
    SocketAddr::new(IpAddr::V4(Ipv4Addr::new(192, 0, 2, n)), 443)
}

fn v6(n: u16) -> SocketAddr {
    SocketAddr::new(IpAddr::V6(Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, n)), 443)
}

#[test]
fn v6_first_even_when_the_resolver_put_v4_first() {
    // musl's order on a ULA-only host: every A record before every AAAA.
    assert_eq!(v6_first(&[v4(1), v4(2), v6(1)]), vec![v6(1), v4(1), v4(2)]);
    assert_eq!(v6_first(&[v6(1), v6(2), v4(1)]), vec![v6(1), v4(1), v6(2)]);
    assert_eq!(v6_first(&[v4(1), v4(2)]), vec![v4(1), v4(2)]);
    assert!(v6_first(&[]).is_empty());
}

#[tokio::test]
async fn the_first_listener_that_answers_wins_and_a_dead_address_does_not_wait_its_timeout() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let live = listener.local_addr().unwrap();
    // A bound socket that never listens refuses at once: the next starts with no stagger.
    let dead = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap();
    let started = std::time::Instant::now();
    let stream = race(&[dead, live], Duration::from_secs(5), Duration::from_secs(5)).await.unwrap();
    assert_eq!(stream.peer_addr().unwrap(), live);
    assert!(started.elapsed() < Duration::from_secs(1), "{:?}", started.elapsed());
}

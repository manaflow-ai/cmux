//! Address order and a raced connect for outbound dials by name (RFC 8305, happy eyeballs).
//!
//! acpmux ships as a static musl binary. musl's getaddrinfo sorts by its own fixed RFC 6724
//! table and reads no `/etc/gai.conf`: on a host whose only IPv6 address is ULA (fc00::/7,
//! label 13) a public AAAA (label 1) fails the matching-label rule while the A record's mapped
//! source matches it, so every name comes back IPv4 first. Tried one after the other, the IPv4
//! address always connects and IPv6 is never used, even where it is the faster path.
//!
//! [`v6_first`] orders the addresses IPv6 first, families alternating, as RFC 8305 asks. With
//! [`race`], an IPv6 attempt that has not connected after [`STAGGER`] is joined by the next
//! (IPv4) one and the first to connect wins, so a host whose IPv6 stalls pays at most the stagger
//! once per connect, and a host with no IPv6 route ("Network is unreachable") pays nothing.

use std::io;
use std::net::SocketAddr;
use std::time::Duration;

use tokio::net::TcpStream;
use tokio::task::JoinSet;

/// How long an attempt has alone before the next address is also tried (RFC 8305's
/// "connection attempt delay" recommends 250 ms).
pub const STAGGER: Duration = Duration::from_millis(250);

/// `addresses` IPv6 first, the two families alternating; the order within a family is kept.
pub fn v6_first(addresses: &[SocketAddr]) -> Vec<SocketAddr> {
    let (mut v6, mut v4): (Vec<_>, Vec<_>) =
        addresses.iter().copied().partition(SocketAddr::is_ipv6);
    v6.reverse();
    v4.reverse();
    let mut out = Vec::with_capacity(addresses.len());
    while !v6.is_empty() || !v4.is_empty() {
        out.extend(v6.pop());
        out.extend(v4.pop());
    }
    out
}

/// A TCP connect to the first of `addresses` that answers: attempts start in order, `stagger`
/// apart, a failed attempt starts the next at once, and each attempt is bounded by `attempt`.
/// The others are dropped (aborted) once one connects. The error is the last attempt's.
pub async fn race(
    addresses: &[SocketAddr],
    stagger: Duration,
    attempt: Duration,
) -> io::Result<TcpStream> {
    let mut pending = addresses.iter().copied();
    let mut running = JoinSet::new();
    let mut last_error = None;
    loop {
        match pending.next() {
            Some(address) => {
                running.spawn(async move {
                    match tokio::time::timeout(attempt, TcpStream::connect(address)).await {
                        Ok(result) => result,
                        Err(_) => Err(io::Error::new(
                            io::ErrorKind::TimedOut,
                            format!("connect {address}: timed out"),
                        )),
                    }
                });
            }
            None if running.is_empty() => {
                return Err(last_error.unwrap_or_else(|| {
                    io::Error::new(io::ErrorKind::NotFound, "no addresses to connect to")
                }));
            }
            None => {}
        }
        let wait = tokio::time::sleep(stagger);
        tokio::pin!(wait);
        loop {
            tokio::select! {
                Some(joined) = running.join_next() => match joined {
                    Ok(Ok(stream)) => return Ok(stream),
                    Ok(Err(error)) => { last_error = Some(error); break; }
                    Err(join) => { last_error = Some(io::Error::other(join)); break; }
                },
                () = &mut wait, if pending.len() > 0 => break,
                else => break,
            }
        }
    }
}

#[cfg(test)]
mod tests {
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
        let stream =
            race(&[dead, live], Duration::from_secs(5), Duration::from_secs(5)).await.unwrap();
        assert_eq!(stream.peer_addr().unwrap(), live);
        assert!(started.elapsed() < Duration::from_secs(1), "{:?}", started.elapsed());
    }
}

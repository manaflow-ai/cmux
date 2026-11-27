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
        // One wake per round: an attempt that ended, or the stagger running out with an address
        // still to try. Either way the next round starts the next address or reads the next end.
        tokio::select! {
            Some(joined) = running.join_next() => match joined {
                Ok(Ok(stream)) => return Ok(stream),
                Ok(Err(error)) => last_error = Some(error),
                Err(join) => last_error = Some(io::Error::other(join)),
            },
            () = &mut wait, if pending.len() > 0 => {}
            else => {}
        }
    }
}

#[cfg(test)]
#[path = "happy_tests.rs"]
mod tests;

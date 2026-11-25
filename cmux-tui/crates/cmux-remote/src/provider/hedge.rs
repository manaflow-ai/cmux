//! A hedged connect: a new socket when the first one's SYN goes nowhere.
//!
//! Some network paths black-hole one connection's 5-tuple: its SYN and every
//! retransmit of it are dropped, while a new socket (a new source port) to the
//! same address connects in milliseconds. The operating system retransmits on
//! the same socket for over a minute, and a resolver's addresses tried one
//! after the other wait that long on each. Measured on 2026-11-17: 1 in 8 to 1
//! in 2 new connections to the Cloud API and relay hosts, which turned a 3 s
//! carrier link into 36 to 83 s.
//!
//! [`connect`] starts one attempt, starts another every [`HedgePolicy::stagger`]
//! while none has connected (rotating through the addresses), keeps at most
//! [`HedgePolicy::max_in_flight`] in flight, gives each one
//! [`HedgePolicy::attempt_timeout`], and returns the first that connects. The
//! others are dropped, which closes their sockets. Only the connect is hedged:
//! nothing has been written on any of them yet.
//!
//! The last attempt has no timeout of its own: on a saturated uplink where every
//! connect takes longer than [`HedgePolicy::attempt_timeout`], it still connects
//! slowly inside the caller's own budget (the relay's 10 s connect) instead of
//! failing where a plain connect used to succeed.

use std::future::Future;
use std::io;
use std::net::SocketAddr;
use std::sync::LazyLock;

use cmux_braid_path::LastGood;
use tokio::net::TcpStream;

/// When to start another socket and how many to keep (Braid's race policy, RFD 0164).
pub type HedgePolicy = cmux_braid_path::RacePolicy;

/// `addresses` IPv6 first, the two families alternating (RFC 8305): acpmux ships as a static musl
/// binary, whose resolver puts every A record first on a host whose only IPv6 address is ULA.
/// Shared with the phone's dials (`cmux_braid_path::v6_first`, the same order as
/// `cmux_vault_egress::happy::v6_first`).
pub use cmux_braid_path::v6_first;

/// Keep a caller's preferred prefix ahead of RFC 8305 family ordering.
pub fn v6_first_after_prefix(addresses: &[SocketAddr], preferred_len: usize) -> Vec<SocketAddr> {
    let (preferred, rest) = addresses.split_at_checked(preferred_len).unwrap_or((addresses, &[]));
    let mut out = preferred.to_vec();
    out.extend(v6_first(rest));
    out
}

/// Connects to one of `targets` through `connect`, hedged by `policy`
/// (module docs). Attempt `n` dials `targets[n % targets.len()]`. The error
/// is the last attempt's (an attempt that ran out of time is `TimedOut`). The
/// final attempt is not timed out here: the caller bounds the whole connect.
pub async fn connect<A, T, F, Fut>(targets: &[A], policy: HedgePolicy, connect: F) -> io::Result<T>
where
    A: Clone,
    F: FnMut(A) -> Fut,
    Fut: Future<Output = io::Result<T>>,
{
    cmux_braid_path::race(targets, policy, connect).await.map(|won| won.value)
}

/// The address that last connected per `(host, port)`, for the whole process (Braid's
/// last-good route, RFD 0164 slice B1). `CMUX_BRAID_LAST_GOOD=0` turns it off.
static LAST_GOOD: LazyLock<LastGood<(String, u16), SocketAddr>> = LazyLock::new(LastGood::from_env);

/// A TCP connect to `host:port` over its resolved `addresses`: IPv6 first ([`v6_first`]), but
/// the address that won last time goes first and the next socket starts after 1.5 times its
/// connect time (at least 100 ms, at most `policy`'s stagger). A reconnect on a network whose
/// IPv6 is black-holed goes straight to IPv4 instead of waiting out the dead attempt again.
pub async fn connect_tcp(
    host: &str,
    port: u16,
    addresses: &[SocketAddr],
    policy: HedgePolicy,
) -> io::Result<TcpStream> {
    connect_remembered(&LAST_GOOD, host, port, addresses, 0, policy, TcpStream::connect).await
}

/// [`connect_tcp`] with the first `preferred_len` addresses kept ahead of the RFC 8305 order
/// of the rest (a direct Tailscale path, [`super::tailnet`]). The last-good route still goes
/// first, so a preferred address races beside it at t=0 rather than displacing it.
pub async fn connect_tcp_preferring(
    host: &str,
    port: u16,
    addresses: &[SocketAddr],
    preferred_len: usize,
    policy: HedgePolicy,
) -> io::Result<TcpStream> {
    connect_remembered(&LAST_GOOD, host, port, addresses, preferred_len, policy, TcpStream::connect)
        .await
}

async fn connect_remembered<T, F, Fut>(
    memory: &LastGood<(String, u16), SocketAddr>,
    host: &str,
    port: u16,
    addresses: &[SocketAddr],
    preferred_len: usize,
    policy: HedgePolicy,
    connect: F,
) -> io::Result<T>
where
    F: FnMut(SocketAddr) -> Fut,
    Fut: Future<Output = io::Result<T>>,
{
    let key = (host.to_ascii_lowercase(), port);
    cmux_braid_path::race_remembered(
        memory,
        key,
        &v6_first_after_prefix(addresses, preferred_len),
        policy,
        connect,
    )
    .await
    .map(|(_, won)| won.value)
}

#[cfg(test)]
#[path = "hedge_tests.rs"]
mod tests;

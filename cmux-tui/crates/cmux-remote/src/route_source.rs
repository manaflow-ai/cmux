//! The local address a link's route leaves from, and whether it is still ours.
//!
//! When the address a link was dialed from goes away (DHCP renewed with a new lease, a Wi-Fi
//! hop, a VPN replaced), the kernel keeps the old TCP socket and silently drops what it sends, so
//! the link dies only when a probe goes unanswered. The heartbeat used to wait out that probe
//! (two seconds) before it redialed. An address that is no longer assigned proves the link dead
//! at once, with no round trip.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, UdpSocket};
use std::time::Duration;

/// How long a hostname may take to resolve when the watcher looks for the route's source.
const RESOLVE_TIMEOUT: Duration = Duration::from_millis(500);

/// The address the operating system would send from toward `remote`. A UDP `connect` only
/// consults the routing table: no packet leaves.
pub(crate) fn source_toward(remote: IpAddr) -> Option<IpAddr> {
    let any: IpAddr = match remote {
        IpAddr::V4(_) => Ipv4Addr::UNSPECIFIED.into(),
        IpAddr::V6(_) => Ipv6Addr::UNSPECIFIED.into(),
    };
    let socket = UdpSocket::bind(SocketAddr::new(any, 0)).ok()?;
    socket.connect(SocketAddr::new(remote, 9)).ok()?;
    Some(socket.local_addr().ok()?.ip())
}

/// True when `address` is no longer assigned to any interface of this computer: binding it
/// fails with "address not available". Any other outcome (it binds, or fails for another
/// reason such as a link-local scope) is "not known to be gone".
pub(crate) fn address_is_gone(address: IpAddr) -> bool {
    match UdpSocket::bind(SocketAddr::new(address, 0)) {
        Ok(_) => false,
        Err(error) => error.kind() == std::io::ErrorKind::AddrNotAvailable,
    }
}

/// The IP a route's host names: a literal as is, a name through the resolver (bounded).
pub(crate) async fn resolve_host(host: &str) -> Option<IpAddr> {
    let bare = host.strip_prefix('[').and_then(|rest| rest.strip_suffix(']')).unwrap_or(host);
    if let Ok(address) = bare.parse::<IpAddr>() {
        return Some(address);
    }
    let lookup = tokio::net::lookup_host((bare, 9));
    let mut found = tokio::time::timeout(RESOLVE_TIMEOUT, lookup).await.ok()?.ok()?;
    found.next().map(|address| address.ip())
}

#[cfg(test)]
#[path = "route_source_tests.rs"]
mod tests;

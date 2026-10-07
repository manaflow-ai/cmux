//! FETCH-PRIVATE-RANGES under a proxy (browser-egress.md 7.3).

use std::net::{IpAddr, ToSocketAddrs};
use std::sync::Arc;

/// Resolves `(host, port)` to its addresses on this machine (none when the
/// name does not resolve).
pub type NameResolver = Arc<dyn Fn(&str, u16) -> Vec<IpAddr> + Send + Sync>;

/// This machine's resolver.
pub(super) fn system_resolver() -> NameResolver {
    Arc::new(|host, port| {
        (host, port).to_socket_addrs().map(|addrs| addrs.map(|a| a.ip()).collect()).unwrap_or_default()
    })
}

//! Which network this computer is on, as a short id ([`NetworkId`]) that a winner memory can
//! key by: the source address the kernel picks toward the internet for each family (Linux,
//! macOS and iOS, a UDP `connect`: it consults the routing table, no packet leaves). A switch of Wi-Fi networks, a
//! move to cellular or a VPN taking the default route changes it; a VM bridge coming and going
//! does not (it is not the default route). Std only, so the phone's build shares it.

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, UdpSocket};

/// A network, hashed (no address leaves the process in it).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct NetworkId(pub u64);

/// Documentation addresses (RFC 5737, RFC 3849): no specific route covers them, so the kernel
/// answers with the default route's source; nothing is sent to them.
const PROBE_V4: Ipv4Addr = Ipv4Addr::new(192, 0, 2, 1);
const PROBE_V6: Ipv6Addr = Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1);

impl NetworkId {
    /// The network this computer is on now; `None` with no default route in either family
    /// (offline: every dial shares one bucket).
    #[must_use]
    pub fn current() -> Option<Self> {
        Self::of(source_toward(IpAddr::V4(PROBE_V4)), source_toward(IpAddr::V6(PROBE_V6)))
    }

    /// The id of a network whose sources toward the internet are `v4` and `v6`; `None` when
    /// there is neither.
    #[must_use]
    pub fn of(v4: Option<IpAddr>, v6: Option<IpAddr>) -> Option<Self> {
        if v4.is_none() && v6.is_none() {
            return None;
        }
        let mut hasher = DefaultHasher::new();
        (v4, v6).hash(&mut hasher);
        Some(Self(hasher.finish()))
    }
}

/// The address the kernel would send from toward `remote`, from a UDP `connect` (no packet).
fn source_toward(remote: IpAddr) -> Option<IpAddr> {
    let any: IpAddr = match remote {
        IpAddr::V4(_) => Ipv4Addr::UNSPECIFIED.into(),
        IpAddr::V6(_) => Ipv6Addr::UNSPECIFIED.into(),
    };
    let socket = UdpSocket::bind(SocketAddr::new(any, 0)).ok()?;
    socket.connect(SocketAddr::new(remote, 9)).ok()?;
    Some(socket.local_addr().ok()?.ip())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn two_networks_differ_and_none_is_offline() {
        let home = NetworkId::of(Some("192.168.1.5".parse().unwrap()), None);
        let cafe = NetworkId::of(Some("10.0.0.7".parse().unwrap()), None);
        assert_ne!(home, cafe);
        assert_eq!(home, NetworkId::of(Some("192.168.1.5".parse().unwrap()), None));
        assert_eq!(NetworkId::of(None, None), None);
        // Reading this computer's network never panics (a sandbox may have none).
        let _ = NetworkId::current();
    }
}

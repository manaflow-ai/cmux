//! What a direct path physically rides, so a faster link wins at once.
//!
//! RTT alone cannot rank a Thunderbolt Bridge above wired Ethernet: both
//! answer in well under a millisecond, and the selector's hysteresis margin
//! (3 ms) keeps whichever answered first. Yet one carries 20-38 Gbit/s and
//! the other 1. The medium is a fact about the local interface the peer's
//! address is on, so it is decided once, from this machine's own interface
//! table, and never from anything the peer or the network says.
//!
//! The medium only orders paths. It never admits one: every path still
//! carries the same end-to-end session and is used only after an
//! authenticated probe answers on it.

use std::net::IpAddr;

/// The link a path rides, best first (the derived order is the rank).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Medium {
    /// A point-to-point or same-host link: a Thunderbolt Bridge (macOS
    /// `bridge*`, Linux `thunderbolt*`), a local VM's bridge, or loopback.
    Link,
    /// An address on a network this machine is directly attached to
    /// (Ethernet, Wi-Fi).
    Lan,
    /// Anything routed: through a gateway, a VPN or overlay interface, a
    /// tailnet address, or a relay.
    Routed,
}

impl Medium {
    pub fn wire_name(self) -> &'static str {
        match self {
            Medium::Link => "link",
            Medium::Lan => "lan",
            Medium::Routed => "routed",
        }
    }
}

/// One address of this machine's interfaces with its prefix length.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LocalNetwork {
    pub interface: String,
    pub address: IpAddr,
    pub prefix: u8,
}

impl LocalNetwork {
    fn contains(&self, ip: IpAddr) -> bool {
        match (self.address, ip) {
            (IpAddr::V4(net), IpAddr::V4(ip)) => {
                let prefix = u32::from(self.prefix.min(32));
                let mask = u32::MAX.checked_shl(32 - prefix).unwrap_or(0);
                u32::from(net) & mask == u32::from(ip) & mask
            }
            (IpAddr::V6(net), IpAddr::V6(ip)) => {
                let prefix = u32::from(self.prefix.min(128));
                let mask = u128::MAX.checked_shl(128 - prefix).unwrap_or(0);
                u128::from(net) & mask == u128::from(ip) & mask
            }
            _ => false,
        }
    }
}

/// The medium of an interface by its name, when the name says.
fn interface_medium(name: &str) -> Medium {
    const LINK: [&str; 2] = ["bridge", "thunderbolt"];
    const ROUTED: [&str; 9] =
        ["utun", "tun", "tap", "wg", "tailscale", "ipsec", "ppp", "gif", "stf"];
    if LINK.iter().any(|prefix| name.starts_with(prefix)) {
        Medium::Link
    } else if ROUTED.iter().any(|prefix| name.starts_with(prefix)) {
        Medium::Routed
    } else {
        Medium::Lan
    }
}

/// Tailnet overlay addresses (100.64.0.0/10 and fd7a:115c:a1e0::/48): a
/// peer there is reached through the overlay, whatever interface shows it.
fn is_overlay(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => {
            let [a, b, ..] = v4.octets();
            a == 100 && (b & 0xc0) == 64
        }
        IpAddr::V6(v6) => {
            let s = v6.segments();
            s[0] == 0xfd7a && s[1] == 0x115c && s[2] == 0xa1e0
        }
    }
}

fn unmapped(ip: IpAddr) -> IpAddr {
    match ip {
        IpAddr::V6(v6) => v6.to_ipv4_mapped().map_or(IpAddr::V6(v6), IpAddr::V4),
        v4 => v4,
    }
}

/// The medium a path to `remote` rides, from this machine's `networks`: the
/// interface with the longest prefix containing `remote` decides; no
/// on-link interface means the path is routed.
///
/// When several interfaces share that longest prefix (Wi-Fi and Ethernet on
/// one subnet, or a VPN that claims the LAN's range), the answer must not
/// depend on the order getifaddrs lists them in, and the table alone cannot
/// say which one the kernel routes through. The slowest of them wins: the
/// medium only orders paths, so understating one costs at most the RTT
/// ordering that ranks same-medium paths, while overstating one could put a
/// VPN path ahead of a real LAN path.
pub fn medium_of(remote: IpAddr, networks: &[LocalNetwork]) -> Medium {
    let remote = unmapped(remote);
    if remote.is_loopback() {
        return Medium::Link;
    }
    if is_overlay(remote) {
        return Medium::Routed;
    }
    let Some(longest) = networks
        .iter()
        .filter(|network| network.contains(remote))
        .map(|network| network.prefix)
        .max()
    else {
        return Medium::Routed;
    };
    networks
        .iter()
        .filter(|network| network.prefix == longest && network.contains(remote))
        .map(|network| interface_medium(&network.interface))
        .max()
        .unwrap_or(Medium::Routed)
}

/// This machine's up interface addresses and prefixes (getifaddrs).
#[cfg(all(unix, feature = "local-networks"))]
pub fn local_networks() -> Vec<LocalNetwork> {
    use std::ffi::CStr;
    use std::net::{Ipv4Addr, Ipv6Addr};
    let mut out = Vec::new();
    let mut head: *mut libc::ifaddrs = std::ptr::null_mut();
    // SAFETY: getifaddrs allocates a list we walk read-only and free once;
    // every pointer read is checked for null and cast by its family.
    unsafe {
        if libc::getifaddrs(&mut head) != 0 {
            return out;
        }
        let mut cursor = head;
        while !cursor.is_null() {
            let entry = &*cursor;
            cursor = entry.ifa_next;
            if entry.ifa_addr.is_null()
                || entry.ifa_netmask.is_null()
                || entry.ifa_name.is_null()
                || entry.ifa_flags & (libc::IFF_UP as u32) == 0
            {
                continue;
            }
            let Ok(interface) = CStr::from_ptr(entry.ifa_name).to_str() else { continue };
            let (address, prefix) = match i32::from((*entry.ifa_addr).sa_family) {
                libc::AF_INET => {
                    let sin = &*(entry.ifa_addr as *const libc::sockaddr_in);
                    let mask = &*(entry.ifa_netmask as *const libc::sockaddr_in);
                    let address = IpAddr::V4(Ipv4Addr::from(u32::from_be(sin.sin_addr.s_addr)));
                    (address, u32::from_be(mask.sin_addr.s_addr).count_ones())
                }
                libc::AF_INET6 => {
                    let sin6 = &*(entry.ifa_addr as *const libc::sockaddr_in6);
                    let mask = &*(entry.ifa_netmask as *const libc::sockaddr_in6);
                    let address = IpAddr::V6(Ipv6Addr::from(sin6.sin6_addr.s6_addr));
                    (address, u128::from_be_bytes(mask.sin6_addr.s6_addr).count_ones())
                }
                _ => continue,
            };
            let prefix = u8::try_from(prefix).unwrap_or(0);
            out.push(LocalNetwork { interface: interface.to_owned(), address, prefix });
        }
        libc::freeifaddrs(head);
    }
    out
}

/// No interface table on this platform: every path counts as routed
/// unless its address says otherwise.
#[cfg(not(all(unix, feature = "local-networks")))]
pub fn local_networks() -> Vec<LocalNetwork> {
    Vec::new()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn net(interface: &str, address: &str, prefix: u8) -> LocalNetwork {
        LocalNetwork { interface: interface.into(), address: address.parse().unwrap(), prefix }
    }

    /// A Mac Studio's table: wired en0 and Wi-Fi en1 on the office LAN, a
    /// Thunderbolt Bridge to a second Studio on bridge0, and a tailnet utun.
    fn studio() -> Vec<LocalNetwork> {
        vec![
            net("lo0", "127.0.0.1", 8),
            net("en0", "172.20.22.22", 22),
            net("en1", "172.20.22.23", 22),
            net("bridge0", "10.254.2.1", 30),
            net("utun4", "100.103.118.14", 32),
            net("en0", "fe80::1", 64),
        ]
    }

    fn medium(remote: &str) -> Medium {
        medium_of(remote.parse().unwrap(), &studio())
    }

    #[test]
    fn the_thunderbolt_bridge_is_a_link() {
        assert_eq!(medium("10.254.2.2"), Medium::Link);
        assert_eq!(medium("::ffff:10.254.2.2"), Medium::Link, "mapped addresses unmap");
    }

    #[test]
    fn an_on_link_office_address_is_lan() {
        assert_eq!(medium("172.20.22.26"), Medium::Lan);
        assert_eq!(medium("fe80::2"), Medium::Lan);
    }

    #[test]
    fn tailnet_and_off_link_addresses_are_routed() {
        assert_eq!(medium("100.87.226.47"), Medium::Routed, "tailnet overlay");
        assert_eq!(medium("fd7a:115c:a1e0::1"), Medium::Routed);
        assert_eq!(medium("8.8.8.8"), Medium::Routed, "no on-link interface");
        assert_eq!(medium("10.254.3.2"), Medium::Routed, "outside the bridge's /30");
    }

    #[test]
    fn loopback_is_a_link() {
        assert_eq!(medium("127.0.0.1"), Medium::Link);
        assert_eq!(medium("::1"), Medium::Link);
    }

    #[test]
    fn the_longest_prefix_decides() {
        let networks = vec![net("en0", "10.0.0.5", 8), net("bridge0", "10.254.2.1", 30)];
        assert_eq!(medium_of("10.254.2.2".parse().unwrap(), &networks), Medium::Link);
        assert_eq!(medium_of("10.1.2.3".parse().unwrap(), &networks), Medium::Lan);
    }

    #[test]
    fn a_private_address_behind_a_vpn_interface_is_routed() {
        let networks = vec![net("utun3", "10.8.0.2", 24)];
        assert_eq!(medium_of("10.8.0.9".parse().unwrap(), &networks), Medium::Routed);
    }

    #[test]
    fn a_tie_on_the_longest_prefix_takes_the_slowest_medium_in_any_order() {
        // A VPN that claims the office /22 next to en0, and a Thunderbolt
        // bridge that shares a subnet with Wi-Fi: getifaddrs order must not
        // decide, and the faster claim is never trusted on a tie.
        let vpn = [net("en0", "172.20.22.22", 22), net("utun3", "172.20.22.200", 22)];
        let bridged = [net("bridge0", "192.168.2.1", 24), net("en1", "192.168.2.7", 24)];
        for (table, remote, want) in
            [(&vpn, "172.20.22.26", Medium::Routed), (&bridged, "192.168.2.9", Medium::Lan)]
        {
            let mut reversed = table.to_vec();
            reversed.reverse();
            let remote = remote.parse().unwrap();
            assert_eq!(medium_of(remote, table), want);
            assert_eq!(medium_of(remote, &reversed), want, "order-independent");
        }
        // Two addresses of one class still read as that class.
        let wired_and_wifi = [net("en0", "172.20.22.22", 22), net("en1", "172.20.22.23", 22)];
        assert_eq!(medium_of("172.20.22.26".parse().unwrap(), &wired_and_wifi), Medium::Lan);
        // A longer prefix still beats the tie rule.
        let narrower = [net("utun3", "10.0.0.2", 8), net("bridge0", "10.254.2.1", 30)];
        assert_eq!(medium_of("10.254.2.2".parse().unwrap(), &narrower), Medium::Link);
    }

    #[test]
    fn the_order_is_the_rank() {
        assert!(Medium::Link < Medium::Lan && Medium::Lan < Medium::Routed);
    }
}

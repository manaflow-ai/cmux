//! Which network this machine is on, as a short stable fingerprint (RFD 0164, B2).
//!
//! The route that won at home is not the one that wins at the office: a LAN address, a
//! tailnet path or a direct UDP path all depend on the network the dial starts from. A last
//! good route kept per network fingerprint brings the home route back first when the machine
//! comes home, instead of the office route that overwrote it.
//!
//! The fingerprint is the local source address the OS would use to reach the internet, for
//! IPv4 and for IPv6 (its /64 prefix: privacy addresses rotate inside it). It is read with a
//! UDP `connect`, which only asks the routing table: no packet is sent and nothing waits on
//! the network, so it costs a few microseconds and works offline (no route: that family is
//! absent). Two networks that hand out the same address read as one, which costs only the
//! old single-entry behaviour. Only a hash leaves this module; the addresses are never kept.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, UdpSocket};

/// A network fingerprint: a stable hash of the sources, shown as 16 hex digits.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Fingerprint(u64);

/// The environment switch: `CMUX_BRAID_NETWORK_KEY=0` reads no fingerprint, so every caller
/// keeps one last good route per peer as before B2.
pub const ENV_SWITCH: &str = "CMUX_BRAID_NETWORK_KEY";

/// Where the routing table is asked about: public anycast resolvers, never sent a packet.
const PROBE_V4: SocketAddr = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(1, 1, 1, 1)), 443);
const PROBE_V6: SocketAddr =
    SocketAddr::new(IpAddr::V6(Ipv6Addr::new(0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111)), 443);

impl Fingerprint {
    /// The fingerprint of these sources, `None` when neither is usable (offline, loopback
    /// only, unspecified). The IPv6 source counts only by its /64 prefix.
    #[must_use]
    pub fn of(v4: Option<Ipv4Addr>, v6: Option<Ipv6Addr>) -> Option<Self> {
        let v4 = v4.filter(|address| !address.is_unspecified() && !address.is_loopback());
        let v6 = v6.filter(|address| !address.is_unspecified() && !address.is_loopback());
        if v4.is_none() && v6.is_none() {
            return None;
        }
        // FNV-1a: stable across builds and platforms (the value is kept on disk), unlike std's
        // hasher.
        let mut hash = Fnv::new();
        hash.write(&[1]);
        hash.write(&v4.map_or([0; 4], |address| address.octets()));
        hash.write(&[2]);
        let prefix = v6.map_or([0; 16], |address| address.octets());
        hash.write(&prefix[..8]);
        Some(Self(hash.0))
    }

    /// This machine's network now, or `None` (offline, or [`ENV_SWITCH`] is `0`).
    #[must_use]
    pub fn current() -> Option<Self> {
        if std::env::var(ENV_SWITCH).is_ok_and(|value| value.trim() == "0") {
            return None;
        }
        let v4 = match source_for(PROBE_V4) {
            Some(IpAddr::V4(address)) => Some(address),
            _ => None,
        };
        let v6 = match source_for(PROBE_V6) {
            Some(IpAddr::V6(address)) => Some(address),
            _ => None,
        };
        Self::of(v4, v6)
    }

    /// The fingerprint as 16 lowercase hex digits (the form kept on disk).
    #[must_use]
    pub fn to_hex(self) -> String {
        format!("{:016x}", self.0)
    }
}

impl std::fmt::Display for Fingerprint {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.to_hex())
    }
}

/// The local address the routing table picks to reach `target`, without sending anything.
fn source_for(target: SocketAddr) -> Option<IpAddr> {
    let bind: SocketAddr = match target {
        SocketAddr::V4(_) => (Ipv4Addr::UNSPECIFIED, 0).into(),
        SocketAddr::V6(_) => (Ipv6Addr::UNSPECIFIED, 0).into(),
    };
    let socket = UdpSocket::bind(bind).ok()?;
    socket.connect(target).ok()?;
    Some(socket.local_addr().ok()?.ip())
}

struct Fnv(u64);

impl Fnv {
    fn new() -> Self {
        Self(0xcbf2_9ce4_8422_2325)
    }

    fn write(&mut self, bytes: &[u8]) {
        for byte in bytes {
            self.0 ^= u64::from(*byte);
            self.0 = self.0.wrapping_mul(0x0100_0000_01b3);
        }
    }
}

#[cfg(test)]
#[path = "network_tests.rs"]
mod tests;

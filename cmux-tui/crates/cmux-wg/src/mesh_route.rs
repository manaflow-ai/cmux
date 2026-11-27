//! Where a mesh peer's outer datagrams go: the mesh's own UDP socket.

use std::net::{IpAddr, SocketAddr};

use tokio::net::UdpSocket;

use crate::underlay::SocketPath;

/// Where a peer's outer datagrams go.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum PeerRoute {
    /// The mesh's own UDP socket.
    Udp(SocketAddr),
}

impl From<SocketAddr> for PeerRoute {
    /// A UDP endpoint: what `endpoint: Some(addr)` means.
    fn from(address: SocketAddr) -> Self {
        Self::Udp(address)
    }
}

impl PeerRoute {
    /// The address datagrams go to.
    pub fn address(&self) -> SocketAddr {
        match self {
            Self::Udp(address) => *address,
        }
    }
}

/// Where the mesh's datagrams leave: its UDP socket.
pub(crate) struct Outbound {
    pub(crate) udp: SocketPath<UdpSocket>,
    /// The socket's own address, to map endpoints to its family.
    local: SocketAddr,
}

impl Outbound {
    pub(crate) fn new(udp: SocketPath<UdpSocket>, local: SocketAddr) -> Self {
        Self { udp, local }
    }

    /// Send `datagram` on `route`. A UDP endpoint is mapped to the socket's
    /// address family (a dual-stack IPv6 socket reaches IPv4 peers through
    /// mapped addresses).
    pub(crate) fn send(&mut self, route: Option<PeerRoute>, datagram: &[u8]) {
        let Some(PeerRoute::Udp(target)) = route else { return };
        self.send_to(target, datagram);
    }

    /// Send `datagram` to one UDP address of a peer.
    pub(crate) fn send_to(&mut self, target: SocketAddr, datagram: &[u8]) {
        let target = match (self.local, target) {
            (SocketAddr::V6(_), SocketAddr::V4(v4)) => {
                SocketAddr::new(IpAddr::V6(v4.ip().to_ipv6_mapped()), v4.port())
            }
            (SocketAddr::V4(_), SocketAddr::V6(v6)) => match v6.ip().to_ipv4_mapped() {
                Some(v4) => SocketAddr::new(IpAddr::V4(v4), v6.port()),
                None => return,
            },
            _ => target,
        };
        self.udp.send_to(datagram, target);
    }
}

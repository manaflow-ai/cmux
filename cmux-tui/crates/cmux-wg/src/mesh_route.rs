//! Where a mesh peer's outer datagrams go.
//!
//! A peer is reached either on the mesh's own UDP socket or through a
//! gateway tunnel: a [`crate::WgNet`] session (this install's Freestyle
//! tunnel) whose datagram service carries the mesh's WireGuard datagrams to
//! the peer's VPC endpoint (transport.md 3.1 and 12a). That is WireGuard
//! inside WireGuard, so a mesh that may use a gateway runs with the nested
//! inner MTU (1200 behind a 1280 tunnel).

use std::net::SocketAddr;

/// Where a peer's outer datagrams go.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum PeerRoute {
    /// The mesh's own UDP socket.
    Udp(SocketAddr),
    /// A datagram socket inside a gateway tunnel, to `address` (the peer's
    /// VPC endpoint, UDP 4101).
    Gateway { gateway: GatewayId, address: SocketAddr },
}

impl From<SocketAddr> for PeerRoute {
    /// A UDP endpoint: what `endpoint: Some(addr)` meant before gateways.
    fn from(address: SocketAddr) -> Self {
        Self::Udp(address)
    }
}

impl PeerRoute {
    /// The address datagrams go to (the UDP endpoint or the VPC endpoint).
    pub fn address(&self) -> SocketAddr {
        match self {
            Self::Udp(address) | Self::Gateway { address, .. } => *address,
        }
    }
}

/// A gateway attached to a mesh with [`crate::WgMesh::add_gateway`]. Ids are
/// never reused while the mesh runs, so a removed gateway's id names nothing.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct GatewayId(pub(crate) u64);

//! Entry points for the `wg_packet` and `wg_mesh_packet` targets in
//! `cmux-tui/fuzz` (feature `fuzzing`; no production build turns it on).
//!
//! A decrypted packet from a peer is attacker-shaped once the peer holds a
//! session key. The drivers check its source against the peer's allowed IPs
//! (crypto-key routing), then call [`crate::decrypted`]: the single-peer
//! driver tells a path probe, a UDP datagram and a TCP segment apart and the
//! pacer may rewrite the segment; the mesh driver hands everything to its
//! tagged TCP stack, which parses SYNs to remember their session. These
//! paths call those same functions, with every source allowed.

use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::sync::Arc;
use std::time::Duration;

use tokio::sync::{Notify, mpsc};
use tokio::time::Instant;

use crate::config::{DEFAULT_MTU, InterfaceAddress};
pub use crate::decrypted::Decrypted;
use crate::decrypted::{receive_single, receive_tagged};
use crate::error::WgError;
use crate::pacing::Pacer;
use crate::tcp_stack::{Accepted, LINK_PORT, TcpStack};
use crate::{udp, wire};

/// SYN origins a mesh stack remembers at once.
pub const MAX_SYN_ORIGINS: usize = crate::tcp_stack::MAX_SYN_ORIGINS;
/// Packets a mesh driver decrypts per wake before its stack runs.
pub const RECEIVE_BATCH: usize = crate::mesh_driver::RECEIVE_BATCH;

/// A single-peer driver's receive path and the pacer state it feeds. Times
/// are offsets from the moment the path was made.
pub struct ReceivePath {
    pacer: Pacer,
    epoch: Instant,
}

impl Default for ReceivePath {
    fn default() -> Self {
        Self::new()
    }
}

impl ReceivePath {
    pub fn new() -> Self {
        Self { pacer: Pacer::default(), epoch: Instant::now() }
    }

    fn at(&self, offset: Duration) -> Instant {
        self.epoch.checked_add(offset).unwrap_or(self.epoch)
    }

    /// Queue a packet the TCP stack sends, as `flush_tx` does while the
    /// pacer has room. `None` when it has none.
    pub fn send(&mut self, packet: Vec<u8>, offset: Duration) -> Option<bool> {
        let now = self.at(offset);
        self.pacer.has_room().then(|| self.pacer.push(packet, now))
    }

    /// The next packet the pacer lets leave, if any.
    pub fn pop(&mut self, offset: Duration) -> Option<Vec<u8>> {
        let now = self.at(offset);
        self.pacer.pop(now).ok().flatten()
    }

    /// One decrypted packet through the driver's receive path.
    pub fn receive<'a>(&mut self, packet: &'a [u8], offset: Duration) -> Decrypted<'a> {
        let now = self.at(offset);
        receive_single(&mut self.pacer, packet, now)
    }

    /// The source crypto-key routing checks.
    pub fn source(packet: &[u8]) -> Option<IpAddr> {
        wire::packet_source(packet)
    }

    /// The UDP packet the driver builds for a probe or a datagram, so a
    /// target can check that parsing it gives back what went in.
    pub fn udp_packet(source: SocketAddr, destination: SocketAddr, payload: &[u8]) -> Vec<u8> {
        udp::packet(source, destination, payload)
    }

    /// The source, destination and payload `udp::parse` reads.
    pub fn parse_udp(packet: &[u8]) -> Option<(SocketAddr, SocketAddr, &[u8])> {
        udp::parse(packet)
    }
}

/// A mesh driver's receive path: its pacer and its tagged TCP stack, with a
/// listener on the link port so SYNs open half-open sockets. The stack runs
/// after every [`RECEIVE_BATCH`] packets, as in the driver's receive loop.
pub struct MeshPath {
    pacer: Pacer,
    stack: TcpStack,
    accepted: mpsc::Receiver<Accepted>,
    epoch: Instant,
    unstepped: usize,
}

impl MeshPath {
    /// The stack's IPv4 address (in 10.77.0.0/16).
    pub const ADDRESS_V4: Ipv4Addr = Ipv4Addr::new(10, 77, 0, 1);
    /// The stack's IPv6 address (in fd77::/64).
    pub const ADDRESS_V6: Ipv6Addr = Ipv6Addr::new(0xfd77, 0, 0, 0, 0, 0, 0, 1);
    /// The port the stack listens on.
    pub const PORT: u16 = LINK_PORT;

    pub fn new() -> Result<Self, WgError> {
        let addresses = [
            InterfaceAddress { address: IpAddr::V4(Self::ADDRESS_V4), prefix: 16 },
            InterfaceAddress { address: IpAddr::V6(Self::ADDRESS_V6), prefix: 64 },
        ];
        let mut stack = TcpStack::new(&addresses, DEFAULT_MTU, Arc::new(Notify::new()), true)?;
        let accepted = stack.begin_listen(Self::PORT)?;
        Ok(Self { pacer: Pacer::default(), stack, accepted, epoch: Instant::now(), unstepped: 0 })
    }

    fn at(&self, offset: Duration) -> Instant {
        self.epoch.checked_add(offset).unwrap_or(self.epoch)
    }

    /// One decrypted packet from the session of `key`.
    pub fn receive(&mut self, packet: &[u8], key: [u8; 32], offset: Duration) {
        let now = self.at(offset);
        receive_tagged(&mut self.pacer, &mut self.stack, packet, key, now);
        self.unstepped += 1;
        if self.unstepped >= RECEIVE_BATCH {
            self.step(offset);
        }
    }

    /// Let the stack consume what it received, pace what it emitted as the
    /// driver's flush does, and drop accepted connections.
    pub fn step(&mut self, offset: Duration) {
        let now = self.at(offset);
        self.unstepped = 0;
        self.stack.step();
        while self.pacer.has_room()
            && let Some(packet) = self.stack.pop_tx()
        {
            self.pacer.push(packet, now);
        }
        while self.pacer.pop(now).ok().flatten().is_some() {}
        while self.accepted.try_recv().is_ok() {}
    }

    /// SYN origins the stack remembers now.
    pub fn syn_origins(&self) -> usize {
        self.stack.syn_origins.as_ref().map_or(0, HashMap::len)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// An IPv4 SYN (no ACK) from `source:port` to the mesh path's port. The
    /// checksums are left zero: the SYN-origin bookkeeping runs before
    /// smoltcp checks them.
    fn syn(source: Ipv4Addr, port: u16) -> Vec<u8> {
        let mut packet = vec![0u8; 40];
        packet[0] = 0x45;
        packet[2..4].copy_from_slice(&40u16.to_be_bytes());
        packet[8] = 64;
        packet[9] = 6;
        packet[12..16].copy_from_slice(&source.octets());
        packet[16..20].copy_from_slice(&MeshPath::ADDRESS_V4.octets());
        packet[20..22].copy_from_slice(&port.to_be_bytes());
        packet[22..24].copy_from_slice(&MeshPath::PORT.to_be_bytes());
        packet[32] = 5 << 4;
        packet[33] = 0x02;
        packet[34..36].copy_from_slice(&1024u16.to_be_bytes());
        packet
    }

    #[test]
    fn a_syn_flood_keeps_the_origin_map_bounded() -> Result<(), WgError> {
        let mut path = MeshPath::new()?;
        let source = Ipv4Addr::new(10, 77, 0, 2);
        for port in 1..=(3 * MAX_SYN_ORIGINS as u16) {
            path.receive(&syn(source, port), [7; 32], Duration::ZERO);
            assert!(path.syn_origins() <= MAX_SYN_ORIGINS);
        }
        path.step(Duration::from_millis(1));
        assert!(path.syn_origins() <= MAX_SYN_ORIGINS);
        Ok(())
    }

    #[test]
    fn a_udp_datagram_never_reaches_the_single_peer_stack() {
        let from = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(10, 0, 0, 2)), 5000);
        let to = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(10, 0, 0, 1)), 6000);
        let packet = ReceivePath::udp_packet(from, to, b"hello");
        let mut path = ReceivePath::new();
        assert_eq!(path.receive(&packet, Duration::ZERO), Decrypted::Datagram(from, to, b"hello"));
    }
}

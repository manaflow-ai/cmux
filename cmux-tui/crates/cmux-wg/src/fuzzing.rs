//! Entry points for the `wg_packet` target in `cmux-tui/fuzz` (feature
//! `fuzzing`; no production build turns it on).
//!
//! A decrypted packet from a peer is attacker-shaped once the peer holds a
//! session key: the driver reads its source for crypto-key routing, then
//! tells a path probe, a UDP datagram and a TCP segment apart, and the pacer
//! parses and may rewrite the segment before smoltcp sees it. Those parsers
//! are crate-private, so this module runs them in the order of the
//! `WriteToTunnel` arm of `net.rs` with every source allowed, plus the
//! pacer's send side, which builds the connection state the receive side
//! reads.

use std::net::{IpAddr, SocketAddr};
use std::time::Duration;

use cmux_transport::Probe;
use tokio::time::Instant;

use crate::pacing::Pacer;
use crate::wire::packet_source;
use crate::{probing, udp};

/// What the receive path made of one decrypted packet.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Dispatch {
    /// The source crypto-key routing checks.
    pub source: Option<IpAddr>,
    /// The path probe the packet held, with its source and destination.
    pub probe: Option<(Probe, IpAddr, IpAddr)>,
    /// A UDP datagram for the datagram service: source, destination and
    /// payload length.
    pub datagram: Option<(SocketAddr, SocketAddr, usize)>,
    /// For a packet that goes to the TCP stack: whether the pacer counted it
    /// as new traffic.
    pub fresh: Option<bool>,
    /// The packet as the TCP stack receives it (after the stale-ACK
    /// refresh), or `None` when it never reaches the stack.
    pub to_stack: Option<Vec<u8>>,
}

/// The driver's packet parsers and the pacer state they feed. Times are
/// offsets from the moment the path was made.
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

    /// One decrypted packet through the receive path.
    pub fn receive(&mut self, packet: &[u8], offset: Duration) -> Dispatch {
        let now = self.at(offset);
        let source = packet_source(packet);
        let mut dispatch =
            Dispatch { source, probe: None, datagram: None, fresh: None, to_stack: None };
        if let Some(probe) = probing::decode(packet) {
            dispatch.probe = Some(probe);
        } else if let Some((from, to, payload)) = udp::parse(packet) {
            dispatch.datagram = Some((from, to, payload.len()));
        } else {
            dispatch.fresh = Some(self.pacer.received(packet, now));
            let mut packet = packet.to_vec();
            self.pacer.refresh_stale_ack(&mut packet);
            dispatch.to_stack = Some(packet);
        }
        dispatch
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

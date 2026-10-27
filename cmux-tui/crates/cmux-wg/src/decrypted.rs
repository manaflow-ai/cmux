//! What each engine does with a decrypted packet its peer is allowed to
//! send. The drivers check crypto-key routing and act on the result; the
//! parsing, the pacer's accounting and the stale-ACK refresh are here, so the
//! `fuzzing` module runs the same code as the drivers.

use std::net::{IpAddr, SocketAddr};

use cmux_transport::Probe;
use tokio::time::Instant;

use crate::pacing::Pacer;
use crate::tcp_stack::{PeerKey, TcpStack};
use crate::{probing, udp};

/// One decrypted packet of a single-peer tunnel ([`crate::WgNet`]).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Decrypted<'a> {
    /// A path probe, with its source and destination, for the driver to
    /// answer. Not activity.
    Probe(Probe, IpAddr, IpAddr),
    /// A UDP datagram for the datagram service: source, destination and
    /// payload.
    Datagram(SocketAddr, SocketAddr, &'a [u8]),
    /// A packet for the TCP stack, after the stale-ACK refresh. `fresh` when
    /// the pacer counted it as new traffic (a TCP keepalive or a pure ACK is
    /// not).
    Stack { fresh: bool, packet: Vec<u8> },
}

/// Classify `packet` for a [`crate::WgNet`] driver and, for the TCP stack,
/// run the pacer's receive side on it.
pub(crate) fn receive_single<'a>(
    pacer: &mut Pacer,
    packet: &'a [u8],
    now: Instant,
) -> Decrypted<'a> {
    if let Some((probe, source, destination)) = probing::decode(packet) {
        return Decrypted::Probe(probe, source, destination);
    }
    if let Some((source, destination, payload)) = udp::parse(packet) {
        return Decrypted::Datagram(source, destination, payload);
    }
    let fresh = pacer.received(packet, now);
    let mut packet = packet.to_vec();
    pacer.refresh_stale_ack(&mut packet);
    Decrypted::Stack { fresh, packet }
}

/// Hand `packet` from `key`'s session to a mesh's TCP stack: everything goes
/// to the stack, which records `key` for a SYN.
pub(crate) fn receive_tagged(
    pacer: &mut Pacer,
    stack: &mut TcpStack,
    packet: &[u8],
    key: PeerKey,
    now: Instant,
) {
    pacer.received(packet, now);
    stack.push_rx(packet.to_vec(), Some(key));
}

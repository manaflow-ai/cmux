//! Received datagrams: which session each belongs to, and what the session
//! makes of it (an `impl` block of [`super::MeshDriver`]).
//!
//! Data, handshake responses and cookie replies name the receiver index
//! this side handed out, whose top 24 bits identify the peer. A handshake
//! initiation names no index: its MAC is checked against this side's key
//! first (cheap, and rate-limited), then one Diffie-Hellman decrypts the
//! initiator's static key. A key that is not a configured peer is dropped
//! there, before any session state exists, and gets no answer.
//!
//! A datagram's source is its UDP address, and roaming moves a peer to the
//! address of its latest authenticated datagram.

use boringtun::noise::handshake::parse_handshake_anon;
use boringtun::noise::{Packet, Tunn, TunnResult};
use cmux_transport::{DatagramClass, classify};
use tokio::time::Instant;

use super::MeshDriver;
use crate::mesh_route::PeerRoute;
use crate::tcp_stack::PeerKey;
use crate::wire::packet_source;

/// A cookie reply's size.
const COOKIE_REPLY_BYTES: usize = 64;

impl MeshDriver {
    pub(crate) fn handle_datagram(&mut self, datagram: &[u8], source: Option<PeerRoute>) {
        let key = match Tunn::parse_incoming_packet(datagram) {
            Ok(Packet::HandshakeInit(_)) => self.initiator(datagram, source),
            Ok(Packet::HandshakeResponse(response)) => {
                self.table.by_receiver(response.receiver_idx)
            }
            Ok(Packet::PacketCookieReply(cookie)) => self.table.by_receiver(cookie.receiver_idx),
            Ok(Packet::PacketData(data)) => self.table.by_receiver(data.receiver_idx),
            Err(_) => None,
        };
        if let Some(key) = key {
            self.receive(key, datagram, source);
        }
    }

    /// The configured peer that sent this handshake initiation, or `None`.
    /// An initiation without this side's MAC is dropped; past the handshake
    /// rate the initiator must prove its address with a cookie first
    /// (WireGuard's under-load rule), which reveals nothing it did not
    /// already know and keeps no state. An initiation to this side's retired
    /// key (`WgMesh::start_retiring`) passes its own gate and is taken only
    /// from a peer whose session runs on that key.
    fn initiator(&mut self, datagram: &[u8], source: Option<PeerRoute>) -> Option<PeerKey> {
        let from = source.map(|route| route.address().ip());
        let mut cookie = [0u8; COOKIE_REPLY_BYTES];
        self.gate.reset_count();
        let (initiation, retired) = match self.gate.verify_packet(from, datagram, &mut cookie) {
            Ok(Packet::HandshakeInit(initiation)) => (initiation, false),
            Err(TunnResult::WriteToNetwork(reply)) => {
                self.out.send(source, reply);
                return None;
            }
            Ok(_) => return None,
            Err(_) => {
                let gate = self.retired_gate.as_ref()?;
                gate.reset_count();
                match gate.verify_packet(from, datagram, &mut cookie) {
                    Ok(Packet::HandshakeInit(initiation)) => (initiation, true),
                    Err(TunnResult::WriteToNetwork(reply)) => {
                        self.out.send(source, reply);
                        return None;
                    }
                    _ => return None,
                }
            }
        };
        let (private, public) = if retired {
            self.table.retired()?
        } else {
            (self.table.private(), self.table.public())
        };
        let half = parse_handshake_anon(private, public, &initiation).ok()?;
        let key = half.peer_static_public;
        self.table.admits(&key, retired).then_some(key)
    }

    /// Hand `datagram` to `key`'s session and act on the result.
    fn receive(&mut self, key: PeerKey, datagram: &[u8], source: Option<PeerRoute>) {
        let Some(peer) = self.table.get_mut(&key) else { return };
        let now = Instant::now();
        let mut input = datagram;
        loop {
            let from = source.map(|route| route.address().ip());
            match peer.tunn.decapsulate(from, input, &mut self.scratch) {
                TunnResult::Done => {
                    // A data message that decrypts to nothing is a keepalive:
                    // authenticated, so it moves the peer like any packet.
                    if !input.is_empty() && classify(input) == DatagramClass::WireGuardData {
                        peer.authenticated(source, now);
                    }
                    break;
                }
                TunnResult::Err(_) => break,
                TunnResult::WriteToNetwork(packet) => {
                    // A handshake answered, a session confirmed, or a queued
                    // packet released: all authenticated, except a cookie
                    // reply from the session's own rate limiter, which goes
                    // to the sender without moving the peer.
                    if classify(packet) == DatagramClass::WireGuardCookieReply {
                        self.out.send(source, packet);
                        break;
                    }
                    peer.authenticated(source, now);
                    self.out.send(peer.route, packet);
                    input = &[];
                }
                TunnResult::WriteToTunnelV4(packet, _) | TunnResult::WriteToTunnelV6(packet, _) => {
                    peer.authenticated(source, now);
                    // Crypto-key routing: the peer may only speak from its
                    // own allowed IPs. The stack records this session's key
                    // for a SYN, so an accepted connection is tagged with
                    // the session that carried it.
                    if packet_source(packet).is_some_and(|address| peer.allows(address)) {
                        self.pacer.received(packet, now);
                        self.stack.push_rx(packet.to_vec(), Some(key));
                    }
                    break;
                }
            }
        }
        // A responder's session becomes current with the initiator's first
        // data message; send what boringtun queued while it had none.
        if peer.tunn.time_since_last_handshake().is_some() {
            while let TunnResult::WriteToNetwork(packet) =
                peer.tunn.decapsulate(None, &[], &mut self.scratch)
            {
                self.out.send(peer.route, packet);
            }
        }
    }
}

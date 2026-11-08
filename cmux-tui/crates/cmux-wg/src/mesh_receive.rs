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
//! A datagram's source is its UDP address. Every authenticated source
//! becomes one of the peer's paths ([`crate::mesh_paths`]); path probes and
//! the peer's candidate list are handled here, before the TCP stack, and are
//! not activity.

use boringtun::noise::handshake::parse_handshake_anon;
use std::net::SocketAddr;

use boringtun::noise::{Packet, Tunn, TunnResult};
use cmux_transport::{CANDIDATE_PORT, DatagramClass, classify, decode_candidates};
use tokio::time::Instant;

use super::MeshDriver;
use crate::mesh_route::PeerRoute;
use crate::probing;
use crate::tcp_stack::PeerKey;
use crate::wire::packet_source;

/// The addresses in a decrypted candidate list, or `None` for any other
/// packet.
fn candidate_list(packet: &[u8]) -> Option<Vec<SocketAddr>> {
    let (_, destination, payload) = crate::udp::parse(packet)?;
    if destination.port() != CANDIDATE_PORT {
        return None;
    }
    decode_candidates(payload).ok()
}

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
    /// already know and keeps no state.
    fn initiator(&mut self, datagram: &[u8], source: Option<PeerRoute>) -> Option<PeerKey> {
        self.gate.reset_count();
        let mut cookie = [0u8; COOKIE_REPLY_BYTES];
        let verified = self.gate.verify_packet(
            source.map(|route| route.address().ip()),
            datagram,
            &mut cookie,
        );
        let initiation = match verified {
            Ok(Packet::HandshakeInit(initiation)) => initiation,
            Err(TunnResult::WriteToNetwork(reply)) => {
                self.out.send(source, reply);
                return None;
            }
            _ => return None,
        };
        let half =
            parse_handshake_anon(self.table.private(), self.table.public(), &initiation).ok()?;
        let key = half.peer_static_public;
        self.table.contains(&key).then_some(key)
    }

    /// Hand `datagram` to `key`'s session and act on the result.
    fn receive(&mut self, key: PeerKey, datagram: &[u8], source: Option<PeerRoute>) {
        let Some(peer) = self.table.get_mut(&key) else { return };
        let networks = &self.local.networks;
        let now = Instant::now();
        // The answer to an initiation goes back where it came from, even
        // while datagrams to this peer take another of its paths.
        let initiation = classify(datagram) == DatagramClass::WireGuardInitiation;
        let mut input = datagram;
        loop {
            let from = source.map(|route| route.address().ip());
            match peer.tunn.decapsulate(from, input, &mut self.scratch) {
                TunnResult::Done => {
                    // A data message that decrypts to nothing is a keepalive:
                    // authenticated, so it moves the peer like any packet.
                    if !input.is_empty() && classify(input) == DatagramClass::WireGuardData {
                        peer.authenticated(source, networks, now);
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
                    peer.authenticated(source, networks, now);
                    if initiation && !input.is_empty() && source.is_some() {
                        self.out.send(source, packet);
                    } else {
                        let out = &mut self.out;
                        peer.paths.send(now, |target| out.send_to(target, packet));
                    }
                    input = &[];
                }
                TunnResult::WriteToTunnelV4(packet, _) | TunnResult::WriteToTunnelV6(packet, _) => {
                    // Crypto-key routing: the peer may only speak from its
                    // own allowed IPs.
                    let allowed = packet_source(packet).is_some_and(|address| peer.allows(address));
                    if let Some((probe, from_ip, to_ip)) =
                        probing::decode(packet).filter(|_| allowed)
                    {
                        // A ping is answered on the path it came in on.
                        peer.heard(source, networks, now);
                        match probe.pong() {
                            Some(pong) => {
                                let reply = probing::encode(to_ip, from_ip, &pong);
                                if let TunnResult::WriteToNetwork(answer) =
                                    peer.tunn.encapsulate(&reply, &mut self.scratch)
                                {
                                    self.out.send(source, answer);
                                }
                            }
                            None => peer.paths.pong(probe.path, probe.id, now),
                        }
                    } else if let Some(list) = candidate_list(packet).filter(|_| allowed) {
                        peer.heard(source, networks, now);
                        peer.paths.advertised(&list, networks, now);
                    } else {
                        peer.authenticated(source, networks, now);
                        // The stack records this session's key for a SYN,
                        // so an accepted connection is tagged with the
                        // session that carried it.
                        if allowed {
                            self.pacer.received(packet, now);
                            self.stack.push_rx(packet.to_vec(), Some(key));
                        }
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
                let out = &mut self.out;
                peer.paths.send(now, |target| out.send_to(target, packet));
            }
        }
    }
}

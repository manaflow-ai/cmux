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
            Ok(Packet::HandshakeInit(_)) => match self.initiator(datagram, source) {
                Some((key, true)) => {
                    self.receive_on_current(key, datagram, source);
                    None
                }
                found => found.map(|(key, _)| key),
            },
            Ok(Packet::HandshakeResponse(response)) => {
                let key = self.table.by_receiver(response.receiver_idx);
                // An answer to a probe from the current key (`WgMesh::probe_current`).
                if let Some(key) = key
                    && self.answer_on_current(key, datagram, source)
                {
                    return;
                }
                key
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
    /// from a peer whose session runs on that key; one to the current key
    /// from such a peer moves its session to the current key.
    /// The second value: the initiation is to the current key from a peer on
    /// the retired one ([`MeshDriver::receive_on_current`]).
    fn initiator(&mut self, datagram: &[u8], source: Option<PeerRoute>) -> Option<(PeerKey, bool)> {
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
        if !self.table.admits(&key, retired) {
            return None;
        }
        let on_retired = self.table.get_mut(&key).is_some_and(|peer| peer.on_retired);
        Some((key, !retired && on_retired))
    }

    /// A handshake response for a peer on the retired key that its session on
    /// the current key takes (the peer answered a probe from it): the peer
    /// moves there. False when that session does not take it (an answer to
    /// the retired session, or a forgery), which then goes on as usual.
    fn answer_on_current(
        &mut self,
        key: PeerKey,
        datagram: &[u8],
        source: Option<PeerRoute>,
    ) -> bool {
        let Some(peer) = self.table.get_mut(&key) else { return false };
        let Some(current) = peer.current.as_mut() else { return false };
        let from = source.map(|route| route.address().ip());
        match current.decapsulate(from, datagram, &mut self.scratch) {
            TunnResult::WriteToNetwork(packet) => {
                peer.move_to_current();
                peer.authenticated(source, &self.local.networks, Instant::now());
                self.out.send(source, packet);
                true
            }
            TunnResult::Done if current.time_since_last_handshake().is_some() => {
                peer.move_to_current();
                peer.authenticated(source, &self.local.networks, Instant::now());
                true
            }
            _ => false,
        }
    }

    /// A handshake initiation to the current key from a peer whose session is
    /// on the retired key: its session on the current key checks it in full
    /// (static key, timestamp and its replay check, as any handshake). Only
    /// one it answers moves the peer there; a forged or replayed one changes
    /// nothing.
    fn receive_on_current(&mut self, key: PeerKey, datagram: &[u8], source: Option<PeerRoute>) {
        let Some(peer) = self.table.get_mut(&key) else { return };
        let Some(current) = peer.current.as_mut() else { return };
        let from = source.map(|route| route.address().ip());
        if let TunnResult::WriteToNetwork(packet) =
            current.decapsulate(from, datagram, &mut self.scratch)
        {
            if classify(packet) == DatagramClass::WireGuardCookieReply {
                self.out.send(source, packet);
                return;
            }
            peer.move_to_current();
            peer.authenticated(source, &self.local.networks, Instant::now());
            self.out.send(source, packet);
        }
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
                            None => {
                                if let Some(source) = source {
                                    peer.paths.pong(probe.path, probe.id, source.address(), now);
                                }
                            }
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

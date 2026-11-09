//! The datagram link next to a stream carrier (cmuxterm-hq#7976).
//!
//! A Cloud desktop's `cmux.rd/1` session runs on one byte stream end to end
//! inside the carrier's authenticated Noise session (`cmux carrier dial
//! --service desktop` on the viewer's side, the systemd socket on the host's).
//! Every hop of that stream is TCP, so one lost packet stalls every datagram
//! behind it for a retransmission timeout. This module adds a second path for
//! the datagrams only: a cmux-rd-link secure link (Noise_XX over one UDP
//! socket, sealed packets, a replay window) negotiated inside the stream.
//!
//! - The viewer's `hello` carries a [`LinkOffer`]: a fresh id (the Noise
//!   prologue), its link key and the STUN servers the platform named. The
//!   host answers in `welcome` with a [`LinkAnswer`]: its key and its routes.
//!   More routes follow as `link_candidate` controls, both ways, and only
//!   after a welcome with `link`, so a host that never answered never sees one.
//! - The stream vouches for both keys, so each side accepts only the other's.
//!   Nothing listens: the host's socket is an ephemeral one that only the
//!   link's own packets reach, and a packet without the expected key's
//!   handshake is dropped.
//! - Control stays on the stream. A side sends datagrams on the link while
//!   the link is established and a path answers, and on the stream otherwise,
//!   and takes datagrams from both. The rd datagram layer already tolerates
//!   loss and reordering (FEC, NACK, sequence numbers), so a switch either way
//!   needs no coordination. A link that fails ends; the session goes on on the
//!   stream, as it does today.
//!
//! Version skew: an older host ignores `link_offer` (an unknown field) and
//! answers a welcome without `link`; an older viewer sends no offer. Either
//! way every datagram stays on the stream.

use crate::net::{Candidate, Net, NetConfig, NetEvent};
use crate::{EndpointEvent, Event, KeyPair, Role};
use cmux_rd_proto::control::{LINK_VERSION, LinkAnswer, LinkOffer};
use std::net::{SocketAddr, ToSocketAddrs};
use std::os::fd::RawFd;

/// The largest rd datagram the link carries: one 1280-byte IPv6 minimum MTU
/// path with headroom for a relay's framing (as `cmux-rd serve`).
pub const LINK_MAX_DATAGRAM: usize = 1152 - crate::SEAL_OVERHEAD;
/// Most STUN servers taken from an offer.
const MAX_STUN: usize = 4;
/// Most routes taken from the peer (a session needs a handful).
const MAX_REMOTE_CANDIDATES: usize = 32;
/// Longest STUN server name accepted.
const MAX_STUN_NAME: usize = 255;

/// Something the link produced for its owner.
#[derive(Debug, PartialEq, Eq)]
pub enum LinkOut {
    /// An rd datagram that arrived on the link.
    Datagram(Vec<u8>),
    /// A route of this side, for the peer (send as `link_candidate`).
    Candidate(String),
    /// The link came up, or lost its last path, or failed for good.
    State(LinkState),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LinkState {
    /// Established and a path answers: datagrams go on the link.
    Up,
    /// Established, but no path answers right now: datagrams go on the stream.
    Quiet,
    /// The link ended (`reason`); it never comes back in this session.
    Failed(String),
}

/// One side's datagram link.
pub struct DatagramLink {
    net: Option<Net>,
    established: bool,
    path: bool,
    remote_candidates: usize,
    /// The reason the link ended, once it did.
    failed: Option<String>,
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn unhex<const N: usize>(text: &str) -> Option<[u8; N]> {
    if text.len() != 2 * N {
        return None;
    }
    let mut out = [0u8; N];
    for (i, byte) in out.iter_mut().enumerate() {
        *byte = u8::from_str_radix(text.get(2 * i..2 * i + 2)?, 16).ok()?;
    }
    Some(out)
}

/// The STUN servers of an offer that resolve to IPv4 (the link's socket is IPv4).
fn stun_servers(names: &[String]) -> Vec<SocketAddr> {
    names
        .iter()
        .take(MAX_STUN)
        .filter(|name| name.len() <= MAX_STUN_NAME)
        .filter_map(|name| name.to_socket_addrs().ok()?.find(SocketAddr::is_ipv4))
        .collect()
}

/// A viewer's offer before the link starts: its keys and the offer to send.
pub struct ViewerOffer {
    keys: KeyPair,
    id: [u8; 16],
    stun: Vec<String>,
    pub offer: LinkOffer,
}

impl ViewerOffer {
    /// A fresh key and id for one session; `stun` are the platform's servers.
    pub fn new(stun: Vec<String>) -> Result<Self, String> {
        let keys = KeyPair::generate().map_err(|e| e.to_string())?;
        let id_seed = KeyPair::generate().map_err(|e| e.to_string())?.public;
        let mut id = [0u8; 16];
        id.copy_from_slice(&id_seed[..16]);
        let offer = LinkOffer {
            v: LINK_VERSION,
            id: hex(&id),
            key: hex(&keys.public),
            stun: stun.iter().take(MAX_STUN).cloned().collect(),
        };
        Ok(Self { keys, id, stun, offer })
    }

    /// The host answered: start the viewer's side (it initiates the handshake).
    pub fn start(self, answer: &LinkAnswer, bind: SocketAddr) -> Result<DatagramLink, String> {
        let remote = unhex::<32>(&answer.key).ok_or("the host's link key is not 64 hex")?;
        let net = Net::start(NetConfig {
            role: Role::Initiator,
            session: self.id.to_vec(),
            local: self.keys,
            expected_remote: remote,
            stun: stun_servers(&self.stun),
            bind,
            turn: Vec::new(),
            relay_only: false,
        })
        .map_err(|e| e.to_string())?;
        let mut link = DatagramLink::running(net);
        for candidate in &answer.candidates {
            link.add_remote_candidate(candidate);
        }
        Ok(link)
    }
}

impl DatagramLink {
    fn running(net: Net) -> Self {
        Self { net: Some(net), established: false, path: false, remote_candidates: 0, failed: None }
    }

    /// The host's side for a viewer's offer, and the answer for `welcome`.
    /// `None`: an offer this host does not take (another version, a bad key
    /// or id); the session keeps every datagram on the stream.
    pub fn accept(offer: &LinkOffer, bind: SocketAddr) -> Result<(Self, LinkAnswer), String> {
        if offer.v != LINK_VERSION {
            return Err(format!("link version {} is not {LINK_VERSION}", offer.v));
        }
        let id = unhex::<16>(&offer.id).ok_or("the link id is not 32 hex")?;
        let remote = unhex::<32>(&offer.key).ok_or("the viewer's link key is not 64 hex")?;
        let keys = KeyPair::generate().map_err(|e| e.to_string())?;
        let key = hex(&keys.public);
        let net = Net::start(NetConfig {
            role: Role::Responder,
            session: id.to_vec(),
            local: keys,
            expected_remote: remote,
            stun: stun_servers(&offer.stun),
            bind,
            turn: Vec::new(),
            relay_only: false,
        })
        .map_err(|e| e.to_string())?;
        let mut link = Self::running(net);
        // The host routes are reported at start; they go in the answer.
        let mut candidates = Vec::new();
        let mut early = Vec::new();
        link.poll(&mut early);
        for out in early {
            if let LinkOut::Candidate(c) = out {
                candidates.push(c);
            }
        }
        Ok((link, LinkAnswer { key, candidates }))
    }

    /// Readable when [`DatagramLink::poll`] may have something; `None` once ended.
    pub fn fd(&self) -> Option<RawFd> {
        self.net.as_ref().map(Net::event_fd)
    }

    /// Datagrams go on the link now.
    pub fn is_up(&self) -> bool {
        self.net.is_some() && self.established && self.path
    }

    pub fn failed(&self) -> Option<&str> {
        self.failed.as_deref()
    }

    /// A route the peer sent (`link_candidate`). Malformed or past the bound: dropped.
    pub fn add_remote_candidate(&mut self, text: &str) {
        let Some(net) = &self.net else { return };
        if self.remote_candidates >= MAX_REMOTE_CANDIDATES {
            return;
        }
        if let Some(candidate) = Candidate::from_wire(text) {
            self.remote_candidates += 1;
            net.add_remote_candidate(candidate);
        }
    }

    /// Sends one rd datagram on the link. The caller checks [`DatagramLink::is_up`].
    pub fn send_datagram(&self, datagram: &[u8]) {
        if let Some(net) = &self.net {
            net.send_datagram(datagram.to_vec());
        }
    }

    /// Takes every waiting event.
    pub fn poll(&mut self, out: &mut Vec<LinkOut>) {
        let Some(net) = &self.net else { return };
        let was_up = self.is_up();
        let mut ended = None;
        for event in net.events() {
            match event {
                NetEvent::Candidate(c) => out.push(LinkOut::Candidate(c.to_wire())),
                NetEvent::Endpoint(EndpointEvent::Link(Event::Established)) => {
                    self.established = true;
                }
                NetEvent::Endpoint(EndpointEvent::Link(Event::Datagram(d))) => {
                    out.push(LinkOut::Datagram(d));
                }
                NetEvent::Endpoint(EndpointEvent::PathChanged { route, .. }) => {
                    self.path = route.is_some();
                }
                NetEvent::Endpoint(EndpointEvent::Link(Event::Closed)) => {
                    ended = Some("the peer closed the link".to_owned());
                }
                NetEvent::Failed(reason) => ended = Some(reason),
                _ => {}
            }
        }
        if let Some(reason) = ended {
            // Dropping the driver closes the socket and stops its thread.
            self.net = None;
            self.failed = Some(reason.clone());
            out.push(LinkOut::State(LinkState::Failed(reason)));
            return;
        }
        match (was_up, self.is_up()) {
            (false, true) => out.push(LinkOut::State(LinkState::Up)),
            (true, false) => out.push(LinkOut::State(LinkState::Quiet)),
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    /// Every interface: the host routes are this machine's non-loopback addresses.
    fn loopback() -> SocketAddr {
        "0.0.0.0:0".parse().unwrap()
    }

    /// Pumps both sides until `done` or 5 s; candidates cross as the stream would carry them.
    fn pump(
        host: &mut DatagramLink,
        viewer: &mut DatagramLink,
        mut done: impl FnMut(&[LinkOut], &[LinkOut]) -> bool,
    ) -> (Vec<LinkOut>, Vec<LinkOut>) {
        let (mut h_all, mut v_all) = (Vec::new(), Vec::new());
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline {
            let (mut h, mut v) = (Vec::new(), Vec::new());
            host.poll(&mut h);
            viewer.poll(&mut v);
            for out in &h {
                if let LinkOut::Candidate(c) = out {
                    viewer.add_remote_candidate(c);
                }
            }
            for out in &v {
                if let LinkOut::Candidate(c) = out {
                    host.add_remote_candidate(c);
                }
            }
            h_all.extend(h);
            v_all.extend(v);
            if done(&h_all, &v_all) {
                break;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        (h_all, v_all)
    }

    #[test]
    fn an_offer_and_answer_bring_up_a_link_that_carries_datagrams_both_ways() {
        let offer = ViewerOffer::new(Vec::new()).unwrap();
        let (mut host, answer) = DatagramLink::accept(&offer.offer, loopback()).unwrap();
        let mut viewer = offer.start(&answer, loopback()).unwrap();
        let up = LinkOut::State(LinkState::Up);
        pump(&mut host, &mut viewer, |h, v| h.contains(&up) && v.contains(&up));
        assert!(host.is_up() && viewer.is_up(), "both sides up");
        viewer.send_datagram(b"input");
        host.send_datagram(b"frame");
        let (h, v) = pump(&mut host, &mut viewer, |h, v| {
            h.contains(&LinkOut::Datagram(b"input".to_vec()))
                && v.contains(&LinkOut::Datagram(b"frame".to_vec()))
        });
        assert!(h.contains(&LinkOut::Datagram(b"input".to_vec())), "{h:?}");
        assert!(v.contains(&LinkOut::Datagram(b"frame".to_vec())), "{v:?}");
    }

    #[test]
    fn a_viewer_whose_answer_names_another_key_never_comes_up() {
        let offer = ViewerOffer::new(Vec::new()).unwrap();
        let (mut host, mut answer) = DatagramLink::accept(&offer.offer, loopback()).unwrap();
        // A key the stream did not vouch for (a different host).
        answer.key = hex(&KeyPair::generate().unwrap().public);
        let mut viewer = offer.start(&answer, loopback()).unwrap();
        let up = LinkOut::State(LinkState::Up);
        let (h, v) = pump(&mut host, &mut viewer, |h, v| h.contains(&up) || v.contains(&up));
        assert!(!h.contains(&up) && !v.contains(&up), "no side came up: {h:?} {v:?}");
        assert!(!host.is_up() && !viewer.is_up());
    }

    #[test]
    fn an_offer_of_another_version_or_with_bad_hex_is_not_taken() {
        let good = ViewerOffer::new(Vec::new()).unwrap().offer;
        for bad in [
            LinkOffer { v: LINK_VERSION + 1, ..good.clone() },
            LinkOffer { id: "zz".into(), ..good.clone() },
            LinkOffer { key: "00".into(), ..good },
        ] {
            assert!(DatagramLink::accept(&bad, loopback()).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn the_peers_routes_are_bounded_and_malformed_ones_dropped() {
        let offer = ViewerOffer::new(Vec::new()).unwrap();
        let (mut host, _) = DatagramLink::accept(&offer.offer, loopback()).unwrap();
        host.add_remote_candidate("not a candidate");
        assert_eq!(host.remote_candidates, 0);
        for port in 0..(MAX_REMOTE_CANDIDATES as u16 + 10) {
            host.add_remote_candidate(&format!("host 127.0.0.1:{}", 20000 + port));
        }
        assert_eq!(host.remote_candidates, MAX_REMOTE_CANDIDATES);
    }
}

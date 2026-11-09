//! The datagram link next to a stream carrier (cmuxterm-hq#7976).
//!
//! A Cloud desktop's `cmux.rd/1` session runs on one byte stream end to end
//! inside the carrier's authenticated Noise session (`cmux carrier dial
//! --service desktop` on the viewer's side, the systemd socket on the host's).
//! Every hop of that stream is TCP, so one lost packet stalls every datagram
//! behind it for a retransmission timeout. This module is a second path for
//! the datagrams only: a cmux-rd-link secure link (Noise_XX over one UDP
//! socket, sealed packets, a replay window) negotiated inside the stream.
//!
//! The protocol is the host's (`cmux-rd-host` `hybrid.rs`, cap `link.udp`):
//! after a `welcome` that lists `link.udp`, the viewer sends `link_offer` (a
//! fresh session id, the Noise prologue, and its link key) and the host
//! answers `link_answer` with its key. Routes cross as `link_candidate`
//! controls both ways. This module is the link; the controls are the caller's.
//!
//! - The stream vouches for both keys, so each side takes only the other's.
//!   Nothing listens: each side's socket is an ephemeral one that only the
//!   link's own packets reach, and a packet without the expected key's
//!   handshake is dropped.
//! - Control stays on the stream. A side sends datagrams on the link while the
//!   link is established and a path answers, and on the stream otherwise, and
//!   takes datagrams from both. The rd datagram layer already tolerates loss
//!   and reordering (FEC, NACK, sequence numbers), so a switch either way needs
//!   no coordination. A link that fails ends; the session goes on on the
//!   stream, as it does today.
//! - Past a direct path and a STUN-discovered one, the viewer's TURN relays
//!   (the platform's, over UDP) are the last path before the stream. The viewer
//!   alone allocates: its relay address reaches the host as a `link_candidate`,
//!   and cmux-rd-link prefers any live direct path to every relay.

use crate::net::{Candidate, Net, NetConfig, NetEvent, TurnServer};
use crate::{EndpointEvent, Event, KeyPair, Role};
use std::net::{SocketAddr, ToSocketAddrs};
use std::os::fd::RawFd;
use std::sync::mpsc;
use std::time::{Duration, Instant};

/// The largest rd datagram the link carries: one 1280-byte IPv6 minimum MTU
/// path with headroom for a relay's framing (as the host's `LINK_MAX_DATAGRAM`).
pub const LINK_MAX_DATAGRAM: usize = 1152 - crate::SEAL_OVERHEAD;
/// Most STUN servers a viewer resolves.
const MAX_STUN: usize = 4;
/// Most routes taken from the peer (a session needs a handful).
const MAX_REMOTE_CANDIDATES: usize = 32;
/// Longest STUN or TURN server name resolved.
const MAX_STUN_NAME: usize = 255;
/// Most TURN relays a viewer resolves.
const MAX_TURN: usize = 4;

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

/// The STUN servers that resolve to IPv4 (the link's socket is IPv4).
fn stun_servers(names: &[String]) -> Vec<SocketAddr> {
    names
        .iter()
        .take(MAX_STUN)
        .filter(|name| name.len() <= MAX_STUN_NAME)
        .filter_map(|name| name.to_socket_addrs().ok()?.find(SocketAddr::is_ipv4))
        .collect()
}

/// A TURN relay as the platform names it: `host:port` (UDP) and its credentials.
#[derive(Clone, PartialEq, Eq)]
pub struct TurnName {
    pub addr: String,
    pub username: String,
    pub password: String,
}

impl std::fmt::Debug for TurnName {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TurnName").field("addr", &self.addr).finish_non_exhaustive()
    }
}

/// The TURN relays that resolve to IPv4, with their credentials.
fn turn_servers(names: &[TurnName]) -> Vec<TurnServer> {
    names
        .iter()
        .take(MAX_TURN)
        .filter(|t| t.addr.len() <= MAX_STUN_NAME)
        .filter_map(|t| {
            let addr = t.addr.to_socket_addrs().ok()?.find(SocketAddr::is_ipv4)?;
            Some(TurnServer { addr, username: t.username.clone(), password: t.password.clone() })
        })
        .collect()
}

/// `resolve` on its own thread, so a slow resolver never holds the stream or
/// the other list; an empty `names` answers at once.
fn resolved<N: Send + 'static, T: Send + 'static>(
    thread: &str,
    names: Vec<N>,
    resolve: fn(&[N]) -> Vec<T>,
) -> Result<mpsc::Receiver<Vec<T>>, String> {
    let (tx, rx) = mpsc::channel();
    if names.is_empty() {
        let _ = tx.send(Vec::new());
    } else {
        std::thread::Builder::new()
            .name(thread.into())
            .spawn(move || {
                let _ = tx.send(resolve(&names));
            })
            .map_err(|e| e.to_string())?;
    }
    Ok(rx)
}

/// A viewer's side before the link starts: its keys and session id.
pub struct ViewerOffer {
    keys: KeyPair,
    session: String,
    /// The STUN servers and the TURN relays, each resolved on its own thread so a
    /// slow resolver never holds the stream or the other list; a link that starts
    /// before a list resolves goes without it.
    stun: Resolving<SocketAddr>,
    turn: Resolving<TurnServer>,
}

/// A list on its resolver thread, kept once it arrives.
struct Resolving<T> {
    rx: mpsc::Receiver<Vec<T>>,
    done: Option<Vec<T>>,
}

impl<T> Resolving<T> {
    /// Waits up to `timeout` for the list; true once it is here.
    fn wait(&mut self, timeout: Duration) -> bool {
        if self.done.is_none() {
            self.done = self.rx.recv_timeout(timeout).ok();
        }
        self.done.is_some()
    }

    /// The list if it is here now, else none.
    fn take(mut self) -> Vec<T> {
        self.done.take().or_else(|| self.rx.try_recv().ok()).unwrap_or_default()
    }
}

impl ViewerOffer {
    /// A fresh key and session id for one session; `stun` and `turn` are the platform's servers.
    pub fn new(stun: Vec<String>, turn: Vec<TurnName>) -> Result<Self, String> {
        let keys = KeyPair::generate().map_err(|e| e.to_string())?;
        let id_seed = KeyPair::generate().map_err(|e| e.to_string())?.public;
        let session = hex(&id_seed[..16]);
        let stun = Resolving { rx: resolved("rd-link-stun", stun, stun_servers)?, done: None };
        let turn = Resolving { rx: resolved("rd-link-turn", turn, turn_servers)?, done: None };
        Ok(Self { keys, session, stun, turn })
    }

    /// Waits up to `timeout` for both lists to resolve; true once both are here.
    /// `start` never waits; this is for a caller that can afford to.
    pub fn wait_resolved(&mut self, timeout: Duration) -> bool {
        let deadline = Instant::now() + timeout;
        self.stun.wait(timeout)
            && self.turn.wait(deadline.saturating_duration_since(Instant::now()))
    }

    /// The Noise prologue, for `link_offer`'s `session`.
    pub fn session(&self) -> &str {
        &self.session
    }

    /// This side's link key, 64 hex characters, for `link_offer`'s `key`.
    pub fn key(&self) -> String {
        hex(&self.keys.public)
    }

    /// The host answered (`link_answer`): start the viewer's side, which
    /// initiates the handshake.
    pub fn start(self, host_key: &str, bind: SocketAddr) -> Result<DatagramLink, String> {
        let remote = unhex::<32>(host_key).ok_or("the host's link key is not 64 hex")?;
        let stun = self.stun.take();
        let turn = self.turn.take();
        let net = Net::start(NetConfig {
            role: Role::Initiator,
            session: self.session.into_bytes(),
            local: self.keys,
            expected_remote: remote,
            stun,
            bind,
            turn,
            relay_only: false,
        })
        .map_err(|e| e.to_string())?;
        Ok(DatagramLink::running(net))
    }
}

impl DatagramLink {
    fn running(net: Net) -> Self {
        Self { net: Some(net), established: false, path: false, remote_candidates: 0, failed: None }
    }

    /// The answering side of a link (`link_offer`'s `session` and `key`), and
    /// its own key for `link_answer`. The Cloud host has its own
    /// (`cmux-rd-host` `hybrid.rs`); this one serves tests and other hosts.
    pub fn respond(
        session: &str,
        peer_key: &str,
        bind: SocketAddr,
    ) -> Result<(Self, String), String> {
        let remote = unhex::<32>(peer_key).ok_or("the peer's link key is not 64 hex")?;
        let keys = KeyPair::generate().map_err(|e| e.to_string())?;
        let key = hex(&keys.public);
        let net = Net::start(NetConfig {
            role: Role::Responder,
            session: session.as_bytes().to_vec(),
            local: keys,
            expected_remote: remote,
            stun: Vec::new(),
            bind,
            turn: Vec::new(),
            relay_only: false,
        })
        .map_err(|e| e.to_string())?;
        Ok((Self::running(net), key))
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

    /// Every interface: the host routes are this machine's non-loopback addresses.
    fn any() -> SocketAddr {
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
        let offer = ViewerOffer::new(Vec::new(), Vec::new()).unwrap();
        let (mut host, host_key) =
            DatagramLink::respond(offer.session(), &offer.key(), any()).unwrap();
        let mut viewer = offer.start(&host_key, any()).unwrap();
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
    fn a_viewer_given_another_hosts_key_never_comes_up() {
        let offer = ViewerOffer::new(Vec::new(), Vec::new()).unwrap();
        let (mut host, _) = DatagramLink::respond(offer.session(), &offer.key(), any()).unwrap();
        // A key the stream did not vouch for (a different host).
        let other = hex(&KeyPair::generate().unwrap().public);
        let mut viewer = offer.start(&other, any()).unwrap();
        let up = LinkOut::State(LinkState::Up);
        let (h, v) = pump(&mut host, &mut viewer, |h, v| h.contains(&up) || v.contains(&up));
        assert!(!h.contains(&up) && !v.contains(&up), "no side came up: {h:?} {v:?}");
        assert!(!host.is_up() && !viewer.is_up());
    }

    #[test]
    fn a_key_that_is_not_64_hex_is_refused_on_both_sides() {
        let offer = ViewerOffer::new(Vec::new(), Vec::new()).unwrap();
        assert!(DatagramLink::respond(offer.session(), "zz", any()).is_err());
        assert!(ViewerOffer::new(Vec::new(), Vec::new()).unwrap().start("00", any()).is_err());
    }

    #[test]
    fn a_stun_name_that_does_not_resolve_leaves_the_link_without_it() {
        let offer = ViewerOffer::new(vec!["stun.invalid:3478".into()], Vec::new()).unwrap();
        let (_host, host_key) =
            DatagramLink::respond(offer.session(), &offer.key(), any()).unwrap();
        // Starting never waits for the resolver.
        assert!(offer.start(&host_key, any()).is_ok());
    }

    #[test]
    fn a_slow_turn_lookup_never_holds_the_stun_servers() {
        fn slow(_: &[TurnName]) -> Vec<TurnServer> {
            std::thread::sleep(Duration::from_secs(5));
            Vec::new()
        }
        let turn = resolved("rd-link-turn", vec![turn_name("turn.example:3478")], slow).unwrap();
        let stun =
            resolved("rd-link-stun", vec!["127.0.0.1:3478".to_owned()], stun_servers).unwrap();
        let found = stun.recv_timeout(Duration::from_secs(2)).expect("STUN resolves on its own");
        assert_eq!(found, vec!["127.0.0.1:3478".parse::<SocketAddr>().unwrap()]);
        assert!(turn.try_recv().is_err(), "the TURN lookup is still running");
    }

    fn turn_name(addr: &str) -> TurnName {
        TurnName { addr: addr.into(), username: "alice".into(), password: "correct horse".into() }
    }

    #[test]
    fn turn_relays_resolve_to_ipv4_with_their_credentials_and_are_bounded() {
        let names: Vec<TurnName> =
            (0..6).map(|i| turn_name(&format!("127.0.0.1:{}", 3478 + i))).collect();
        let mut all = vec![turn_name("turn.invalid:3478")];
        all.extend(names);
        let servers = turn_servers(&all);
        // The bound applies to names, before resolving: the unresolvable one takes a slot.
        assert_eq!(servers.len(), MAX_TURN - 1);
        assert!(
            servers.iter().all(|s| s.addr.is_ipv4()
                && s.username == "alice"
                && s.password == "correct horse")
        );
        assert!(
            !format!("{:?}", all[1]).contains("correct horse"),
            "the password stays out of Debug"
        );
    }

    #[test]
    fn the_peers_routes_are_bounded_and_malformed_ones_dropped() {
        let offer = ViewerOffer::new(Vec::new(), Vec::new()).unwrap();
        let (mut host, _) = DatagramLink::respond(offer.session(), &offer.key(), any()).unwrap();
        host.add_remote_candidate("not a candidate");
        assert_eq!(host.remote_candidates, 0);
        for port in 0..(MAX_REMOTE_CANDIDATES as u16 + 10) {
            host.add_remote_candidate(&format!("host 127.0.0.1:{}", 20000 + port));
        }
        assert_eq!(host.remote_candidates, MAX_REMOTE_CANDIDATES);
    }
}

//! One side of a session over every path to the peer
//! (plans/cmux-next/remote-desktop-mac-host.md section 7, rules 2 and 3).
//!
//! An [`Endpoint`] holds the [`Link`] and the candidate paths: a path is a
//! route a packet can take to the peer (a UDP address, or a relay's address
//! for the peer) with its kind. Nothing here prefers a carrier. Until a path
//! answers, packets go out on every path; probes sealed inside the link
//! measure each path and `cmux-transport`'s selector picks the current one
//! (any live direct path beats every relay, then the lower RTT, with
//! hysteresis). A packet that authenticates from a route the endpoint does not
//! know adds that route as a path, as ICE learns peer-reflexive candidates, so
//! a mapping punched by the peer's own packets is used at once.
//!
//! With the machine's interface table ([`Endpoint::set_local_networks`]), a
//! UDP path also carries its [`Medium`], so a Thunderbolt Bridge beats the
//! office LAN at once. A current path that stops answering is caught within
//! a silence window ([`silence_us`]): traffic sent on it with nothing heard
//! back triggers a probe at once, and a probe unanswered for one window
//! makes the path suspect, so packets go on every path until it answers or
//! dies. A dropped fast path costs about two windows, not three probe
//! timeouts.
//!
//! Pure like [`Link`]: the caller owns the sockets and relays, delivers what
//! arrives with the route it came from, and sends each [`Transmit`] on its
//! route.

use crate::{Event, KeyPair, Link, LinkError, Role};
use cmux_transport::selector::default_medium;
use cmux_transport::{
    LocalNetwork, Medium, PathId, PathKind, ProbeOutcome, Selector, SelectorConfig, medium_of,
};
use std::collections::{HashMap, HashSet};
use std::net::SocketAddr;

/// Probe interval of a path that has not answered yet.
pub const PROBE_FAST_US: u64 = 100_000;
/// Probe interval of a live path.
pub const PROBE_SLOW_US: u64 = 1_000_000;
/// A probe with no answer after this long counts as lost.
pub const PROBE_TIMEOUT_US: u64 = 1_000_000;
/// Most paths. Routes learned from unauthenticated handshake packets count,
/// so forged packets cannot make the endpoint answer to many addresses.
pub const MAX_PATHS: usize = 16;
/// The shortest silence window: below it, scheduling jitter alone would
/// look like a dead path.
pub const SILENCE_FLOOR_US: u64 = 100_000;

/// How long the current path may stay silent (traffic out, nothing back),
/// and then leave a probe unanswered, before the endpoint acts: four
/// smoothed round trips, at least [`SILENCE_FLOOR_US`].
pub fn silence_us(rtt_us: Option<u64>) -> u64 {
    rtt_us.map_or(SILENCE_FLOOR_US, |rtt| rtt.saturating_mul(4)).max(SILENCE_FLOOR_US)
}

/// Where a packet goes: a UDP address, or a relay that forwards to the peer.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Route {
    Udp(SocketAddr),
    /// Relay `relay` (the caller's index) towards the peer's address as the
    /// relay sees it.
    Relay {
        relay: u16,
        peer: SocketAddr,
    },
}

/// One packet to send on one route.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Transmit {
    pub route: Route,
    pub packet: Vec<u8>,
}

/// What the endpoint tells its caller, besides link events.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EndpointEvent {
    Link(Event),
    /// The current path changed (`None`: no path answers; sending on all).
    PathChanged {
        route: Option<Route>,
        kind: Option<PathKind>,
        /// What the path rides (Thunderbolt, LAN, routed).
        medium: Option<Medium>,
        rtt_us: Option<u64>,
    },
}

struct PathEntry {
    route: Route,
    kind: PathKind,
    next_probe_us: u64,
    /// When an authenticated packet last arrived on this route.
    heard_us: u64,
    /// Packets sent on this route since then.
    unanswered_sends: u64,
}

pub struct Endpoint {
    link: Link,
    selector: Selector,
    paths: HashMap<PathId, PathEntry>,
    by_route: HashMap<Route, PathId>,
    next_path: u16,
    next_probe_id: u64,
    /// Probe id -> (path, sent at).
    probes: HashMap<u64, (PathId, u64)>,
    events: Vec<EndpointEvent>,
    /// This machine's interfaces, for each UDP path's medium (empty: the
    /// kind's default medium).
    networks: Vec<LocalNetwork>,
    /// Probes that already made their path suspect.
    flagged: HashSet<u64>,
}

impl Endpoint {
    pub fn new(
        role: Role,
        session: &[u8],
        local: &KeyPair,
        expected_remote: [u8; 32],
        now_us: u64,
    ) -> Result<Self, LinkError> {
        Ok(Self {
            link: Link::new(role, session, local, expected_remote, now_us)?,
            selector: Selector::new(SelectorConfig::default()),
            paths: HashMap::new(),
            by_route: HashMap::new(),
            next_path: 0,
            next_probe_id: 1,
            probes: HashMap::new(),
            events: Vec::new(),
            networks: Vec::new(),
            flagged: HashSet::new(),
        })
    }

    pub fn link(&self) -> &Link {
        &self.link
    }

    /// This machine's interface table (`cmux_transport::local_networks()`),
    /// read again on every network change. Paths added from now on carry
    /// the medium it gives them.
    pub fn set_local_networks(&mut self, networks: Vec<LocalNetwork>) {
        self.networks = networks;
        let media: Vec<(PathId, Medium)> =
            self.paths.iter().map(|(id, path)| (*id, self.medium(path.route, path.kind))).collect();
        for (id, medium) in media {
            let _ = self.selector.set_medium(id, medium);
        }
    }

    fn medium(&self, route: Route, kind: PathKind) -> Medium {
        match route {
            Route::Udp(addr) if !self.networks.is_empty() && kind.class().is_direct() => {
                medium_of(addr.ip(), &self.networks)
            }
            _ => default_medium(kind),
        }
    }

    /// Adds a candidate route to the peer (from signaling, or learned).
    pub fn add_path(&mut self, route: Route, kind: PathKind, now_us: u64) {
        if self.by_route.contains_key(&route) || self.paths.len() >= MAX_PATHS {
            return;
        }
        let id = PathId(self.next_path);
        self.next_path = self.next_path.wrapping_add(1);
        let medium = self.medium(route, kind);
        if self.selector.add_path_on(id, kind, medium).is_err() {
            return;
        }
        let entry =
            PathEntry { route, kind, next_probe_us: now_us, heard_us: now_us, unanswered_sends: 0 };
        self.paths.insert(id, entry);
        self.by_route.insert(route, id);
    }

    /// The current path's medium, when one is current.
    pub fn current_medium(&self) -> Option<Medium> {
        self.selector.current().and_then(|id| self.selector.path(id)).map(|view| view.medium)
    }

    /// The local network changed: every path is probed again from scratch.
    pub fn on_network_change(&mut self) {
        if let Some(switch) = self.selector.on_network_change() {
            self.report_switch(switch.to);
        }
        for path in self.paths.values_mut() {
            path.next_probe_us = 0;
        }
    }

    fn report_switch(&mut self, to: Option<PathId>) {
        let entry = to.and_then(|id| self.paths.get(&id));
        let rtt_us = to.and_then(|id| self.selector.path(id)).and_then(|view| view.rtt_us);
        self.events.push(EndpointEvent::PathChanged {
            route: entry.map(|e| e.route),
            kind: entry.map(|e| e.kind),
            medium: to.and_then(|id| self.selector.path(id)).map(|view| view.medium),
            rtt_us,
        });
    }

    /// The routes a link packet goes out on now: the current path, or every
    /// path while none answers (or the current one is suspect). Each send is
    /// counted against its route's silence.
    fn routes(&mut self) -> Vec<Route> {
        let ids: Vec<PathId> = match self.selector.current() {
            Some(id) if self.paths.contains_key(&id) => vec![id],
            _ => self.paths.keys().copied().collect(),
        };
        let mut routes = Vec::with_capacity(ids.len());
        for id in ids {
            if let Some(path) = self.paths.get_mut(&id) {
                path.unanswered_sends = path.unanswered_sends.saturating_add(1);
                routes.push(path.route);
            }
        }
        routes
    }

    /// Feeds a packet that arrived on `route`. Returns the endpoint's events.
    pub fn on_packet(
        &mut self,
        route: Route,
        packet: &[u8],
        now_us: u64,
    ) -> Result<Vec<EndpointEvent>, LinkError> {
        let was_established = self.link.is_established();
        let events = self.link.on_packet(packet, now_us)?;
        // Learn the route once the packet authenticated: a sealed packet that
        // opened (any event), or the handshake moving on.
        let authenticated = !events.is_empty() || (!was_established && self.link.is_established());
        if authenticated
            && let Some(path) = self.by_route.get(&route).and_then(|id| self.paths.get_mut(id))
        {
            path.heard_us = now_us;
            path.unanswered_sends = 0;
        }
        if authenticated && !self.by_route.contains_key(&route) {
            let kind = match route {
                Route::Udp(addr) if is_local(addr) => PathKind::DirectLan,
                Route::Udp(_) => PathKind::DirectWan,
                Route::Relay { .. } => PathKind::TurnRelay,
            };
            self.add_path(route, kind, now_us);
        }
        // During the handshake the peer's packets also teach us where it is.
        if !self.link.is_established()
            && !self.by_route.contains_key(&route)
            && is_handshake(packet)
        {
            let kind = if matches!(route, Route::Relay { .. }) {
                PathKind::TurnRelay
            } else {
                PathKind::DirectWan
            };
            self.add_path(route, kind, now_us);
        }
        for event in events {
            if let Event::ProbeReply(id) = event {
                self.on_probe_reply(id, now_us);
            } else {
                self.events.push(EndpointEvent::Link(event));
            }
        }
        Ok(std::mem::take(&mut self.events))
    }

    fn on_probe_reply(&mut self, id: u64, now_us: u64) {
        let Some((path, sent)) = self.probes.remove(&id) else { return };
        self.flagged.remove(&id);
        // An answered probe proves the probed path, whichever route the
        // reply came back on (the peer may answer on its own choice), so
        // its silence starts over and it is not probed again at once.
        if let Some(entry) = self.paths.get_mut(&path) {
            entry.heard_us = now_us;
            entry.unanswered_sends = 0;
        }
        let outcome = ProbeOutcome::Answered { rtt_us: now_us.saturating_sub(sent).max(1) };
        if let Ok(Some(switch)) = self.selector.on_probe(path, outcome) {
            self.report_switch(switch.to);
        }
    }

    /// Seals one rd datagram for the current path (every path while none answers).
    pub fn send_datagram(&mut self, datagram: &[u8]) -> Result<Vec<Transmit>, LinkError> {
        let packet = self.link.seal_datagram(datagram)?;
        Ok(self
            .routes()
            .into_iter()
            .map(|route| Transmit { route, packet: packet.clone() })
            .collect())
    }

    /// Queues one control record (ordered, reliable).
    pub fn send_control(&mut self, record: Vec<u8>, now_us: u64) -> Result<(), LinkError> {
        self.link.send_control(record, now_us)
    }

    /// Packets to send now: link output on the chosen routes, and the probes
    /// that are due, each on its own path.
    pub fn poll_transmit(&mut self, now_us: u64) -> Result<Vec<Transmit>, LinkError> {
        // Probes that timed out are lost.
        let lost: Vec<(u64, PathId)> = self
            .probes
            .iter()
            .filter(|(_, (_, sent))| now_us.saturating_sub(*sent) > PROBE_TIMEOUT_US)
            .map(|(id, (path, _))| (*id, *path))
            .collect();
        for (id, path) in lost {
            self.probes.remove(&id);
            self.flagged.remove(&id);
            if let Ok(Some(switch)) = self.selector.on_probe(path, ProbeOutcome::Lost) {
                self.report_switch(switch.to);
            }
        }
        self.watch_silence(now_us);
        let mut out = Vec::new();
        let packets = self.link.poll_transmit(now_us)?;
        // Only a poll that sends counts against silence: an idle link
        // waiting for nothing is not a quiet path.
        let routes = if packets.is_empty() { Vec::new() } else { self.routes() };
        for packet in packets {
            for route in &routes {
                out.push(Transmit { route: *route, packet: packet.clone() });
            }
        }
        if self.link.is_established() {
            let due: Vec<PathId> = self
                .paths
                .iter()
                .filter(|(_, p)| p.next_probe_us <= now_us)
                .map(|(id, _)| *id)
                .collect();
            for path in due {
                // A suspect path is probed as fast as a new one, so it
                // proves itself alive (or dead) quickly.
                let alive = self.selector.path(path).is_some_and(|v| {
                    v.rtt_us.is_some() && v.state != cmux_transport::PathState::Suspect
                });
                let id = self.next_probe_id;
                self.next_probe_id += 1;
                let packet = self.link.probe(id)?;
                let Some(entry) = self.paths.get_mut(&path) else { continue };
                entry.next_probe_us = now_us + if alive { PROBE_SLOW_US } else { PROBE_FAST_US };
                self.probes.insert(id, (path, now_us));
                out.push(Transmit { route: entry.route, packet });
            }
        }
        Ok(out)
    }

    /// The current path went quiet: traffic went out on it for a silence
    /// window with nothing authenticated back, so probe it now; a probe on
    /// it unanswered for a window makes it suspect (every path from then).
    fn watch_silence(&mut self, now_us: u64) {
        if !self.link.is_established() {
            return;
        }
        let Some(current) = self.selector.chosen() else { return };
        let window = silence_us(self.selector.path(current).and_then(|view| view.rtt_us));
        let outstanding = self.probes.iter().find(|(_, (path, _))| *path == current);
        match outstanding {
            Some((&id, &(_, sent))) => {
                if now_us.saturating_sub(sent) > window
                    && self.flagged.insert(id)
                    && let Ok(Some(switch)) = self.selector.on_silence(current)
                {
                    self.report_switch(switch.to);
                }
            }
            None => {
                if let Some(path) = self.paths.get_mut(&current)
                    && path.unanswered_sends > 0
                    && now_us.saturating_sub(path.heard_us) > window
                {
                    path.next_probe_us = path.next_probe_us.min(now_us);
                }
            }
        }
    }

    /// The events produced outside `on_packet` (path changes from probe timeouts).
    pub fn take_events(&mut self) -> Vec<EndpointEvent> {
        std::mem::take(&mut self.events)
    }

    /// When to call [`Endpoint::poll_transmit`] next without input.
    pub fn next_deadline_us(&self) -> Option<u64> {
        let probe = if self.link.is_established() {
            self.paths.values().map(|p| p.next_probe_us).min()
        } else {
            None
        };
        let timeout = self.probes.values().map(|(_, sent)| sent + PROBE_TIMEOUT_US).min();
        let established = self.link.is_established();
        let silence = self.selector.chosen().filter(|_| established).and_then(|current| {
            let window = silence_us(self.selector.path(current).and_then(|view| view.rtt_us));
            let path = self.paths.get(&current)?;
            let probe = self.probes.iter().find(|(_, (p, _))| *p == current);
            match probe {
                Some((id, (_, sent))) if !self.flagged.contains(id) => Some(sent + window + 1),
                Some(_) => None,
                None if path.unanswered_sends > 0 => Some(path.heard_us + window + 1),
                None => None,
            }
        });
        [self.link.next_deadline_us(), probe, timeout, silence].into_iter().flatten().min()
    }

    /// Tells the peer the session ends, on the current routes.
    pub fn close(&mut self) -> Result<Vec<Transmit>, LinkError> {
        let packet = self.link.close()?;
        Ok(self
            .routes()
            .into_iter()
            .map(|route| Transmit { route, packet: packet.clone() })
            .collect())
    }
}

fn is_handshake(packet: &[u8]) -> bool {
    matches!(packet.first(), Some(&(crate::TAG_HANDSHAKE_1..=crate::TAG_HANDSHAKE_3)))
}

/// Loopback, private (RFC 1918), link-local, or IPv6 unique-local: the same network.
fn is_local(addr: SocketAddr) -> bool {
    match addr.ip() {
        std::net::IpAddr::V4(v4) => v4.is_loopback() || v4.is_private() || v4.is_link_local(),
        std::net::IpAddr::V6(v6) => {
            v6.is_loopback()
                || (v6.segments()[0] & 0xfe00) == 0xfc00
                || (v6.segments()[0] & 0xffc0) == 0xfe80
        }
    }
}

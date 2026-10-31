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
//! Pure like [`Link`]: the caller owns the sockets and relays, delivers what
//! arrives with the route it came from, and sends each [`Transmit`] on its
//! route.

use crate::{Event, KeyPair, Link, LinkError, Role};
use cmux_transport::{PathId, PathKind, ProbeOutcome, Selector, SelectorConfig};
use std::collections::HashMap;
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
        rtt_us: Option<u64>,
    },
}

struct PathEntry {
    route: Route,
    kind: PathKind,
    next_probe_us: u64,
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
        })
    }

    pub fn link(&self) -> &Link {
        &self.link
    }

    /// Adds a candidate route to the peer (from signaling, or learned).
    pub fn add_path(&mut self, route: Route, kind: PathKind, now_us: u64) {
        if self.by_route.contains_key(&route) || self.paths.len() >= MAX_PATHS {
            return;
        }
        let id = PathId(self.next_path);
        self.next_path = self.next_path.wrapping_add(1);
        if self.selector.add_path(id, kind).is_err() {
            return;
        }
        self.paths.insert(id, PathEntry { route, kind, next_probe_us: now_us });
        self.by_route.insert(route, id);
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
            rtt_us,
        });
    }

    /// The routes a link packet goes out on now: the current path, or every
    /// path while none answers.
    fn routes(&self) -> Vec<Route> {
        match self.selector.current().and_then(|id| self.paths.get(&id)) {
            Some(path) => vec![path.route],
            None => self.paths.values().map(|p| p.route).collect(),
        }
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
            if let Ok(Some(switch)) = self.selector.on_probe(path, ProbeOutcome::Lost) {
                self.report_switch(switch.to);
            }
        }
        let mut out = Vec::new();
        let routes = self.routes();
        for packet in self.link.poll_transmit(now_us)? {
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
                let alive = self.selector.path(path).is_some_and(|v| v.rtt_us.is_some());
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
        [self.link.next_deadline_us(), probe, timeout].into_iter().flatten().min()
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

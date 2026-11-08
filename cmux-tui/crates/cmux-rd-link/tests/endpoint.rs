//! Two endpoints with several routes between them: packets go on every route
//! until one answers, the selector keeps a live direct path over a relay, a
//! relay carries the session when no direct path works, a direct path that
//! starts working takes over, and a route the peer's packets come from is
//! learned.

use cmux_rd_link::{Endpoint, EndpointEvent, Event, KeyPair, Role, Route};
use cmux_transport::PathKind;
use std::net::SocketAddr;

fn addr(s: &str) -> SocketAddr {
    s.parse().unwrap()
}

const HOST_LAN: &str = "192.168.1.20:4103";
const HOST_WAN: &str = "203.0.113.7:51000";
const VIEWER_WAN: &str = "198.51.100.9:62000";

/// Which routes deliver, seen from the sender. `Route::Udp(dst)` from the
/// viewer arrives at the host from `src` (NAT may rewrite it).
struct World {
    lan_works: bool,
    wan_works: bool,
    relay_works: bool,
}

impl World {
    /// Delivers one viewer->host packet: the host sees it from this route.
    fn to_host(&self, route: Route) -> Option<Route> {
        match route {
            Route::Udp(a) if a == addr(HOST_LAN) && self.lan_works => {
                Some(Route::Udp(addr("192.168.1.30:4103")))
            }
            Route::Udp(a) if a == addr(HOST_WAN) && self.wan_works => {
                Some(Route::Udp(addr(VIEWER_WAN)))
            }
            Route::Relay { relay: 0, .. } if self.relay_works => {
                Some(Route::Relay { relay: 0, peer: addr("192.0.2.1:3478") })
            }
            _ => None,
        }
    }

    fn to_viewer(&self, route: Route) -> Option<Route> {
        match route {
            Route::Udp(a) if a == addr("192.168.1.30:4103") && self.lan_works => {
                Some(Route::Udp(addr(HOST_LAN)))
            }
            Route::Udp(a) if a == addr(VIEWER_WAN) && self.wan_works => {
                Some(Route::Udp(addr(HOST_WAN)))
            }
            Route::Relay { relay: 0, .. } if self.relay_works => {
                Some(Route::Relay { relay: 0, peer: addr("192.0.2.2:3478") })
            }
            _ => None,
        }
    }
}

struct Pair {
    viewer: Endpoint,
    host: Endpoint,
    now: u64,
    viewer_events: Vec<EndpointEvent>,
    host_events: Vec<EndpointEvent>,
}

impl Pair {
    fn new() -> Self {
        let (v, h) = (KeyPair::generate().unwrap(), KeyPair::generate().unwrap());
        let mut viewer = Endpoint::new(Role::Initiator, b"s1", &v, h.public, 0).unwrap();
        let host = Endpoint::new(Role::Responder, b"s1", &h, v.public, 0).unwrap();
        // The viewer knows the host's candidates from signaling; the host
        // learns the viewer's routes from its packets.
        viewer.add_path(Route::Udp(addr(HOST_LAN)), PathKind::DirectLan, 0);
        viewer.add_path(Route::Udp(addr(HOST_WAN)), PathKind::DirectWan, 0);
        viewer.add_path(Route::Relay { relay: 0, peer: addr(HOST_WAN) }, PathKind::TurnRelay, 0);
        Self { viewer, host, now: 0, viewer_events: Vec::new(), host_events: Vec::new() }
    }

    fn run(&mut self, world: &World, ms: u64) {
        for _ in 0..ms / 10 {
            self.now += 10_000;
            for t in self.viewer.poll_transmit(self.now).unwrap() {
                if let Some(from) = world.to_host(t.route) {
                    self.host_events
                        .extend(self.host.on_packet(from, &t.packet, self.now).unwrap());
                }
            }
            for t in self.host.poll_transmit(self.now).unwrap() {
                if let Some(from) = world.to_viewer(t.route) {
                    self.viewer_events
                        .extend(self.viewer.on_packet(from, &t.packet, self.now).unwrap());
                }
            }
            self.viewer_events.extend(self.viewer.take_events());
            self.host_events.extend(self.host.take_events());
        }
    }

    fn viewer_path(&self) -> Option<PathKind> {
        self.viewer_events.iter().rev().find_map(|e| match e {
            EndpointEvent::PathChanged { kind, .. } => Some(*kind),
            _ => None,
        })?
    }
}

#[test]
fn a_live_direct_path_beats_the_relay() {
    let mut pair = Pair::new();
    pair.run(&World { lan_works: false, wan_works: true, relay_works: true }, 3_000);
    assert!(pair.viewer.link().is_established() && pair.host.link().is_established());
    assert_eq!(pair.viewer_path(), Some(PathKind::DirectWan));
}

#[test]
fn the_relay_carries_the_session_when_no_direct_path_works_and_direct_takes_over_later() {
    let mut pair = Pair::new();
    pair.run(&World { lan_works: false, wan_works: false, relay_works: true }, 3_000);
    assert!(pair.viewer.link().is_established());
    assert_eq!(pair.viewer_path(), Some(PathKind::TurnRelay));
    // Datagrams flow over the relay.
    let sent = pair.host.send_datagram(b"frame").unwrap();
    assert_eq!(sent.len(), 1, "one route once a path is chosen");
    // The routers open (a punched mapping): the direct path takes over.
    pair.run(&World { lan_works: false, wan_works: true, relay_works: true }, 5_000);
    assert_eq!(pair.viewer_path(), Some(PathKind::DirectWan));
}

#[test]
fn control_flows_and_the_host_learns_the_viewers_route() {
    let mut pair = Pair::new();
    pair.viewer.send_control(b"hello".to_vec(), 0).unwrap();
    pair.run(&World { lan_works: true, wan_works: false, relay_works: false }, 2_000);
    assert!(pair.host_events.contains(&EndpointEvent::Link(Event::Control(b"hello".to_vec()))));
    assert_eq!(pair.viewer_path(), Some(PathKind::DirectLan));
    // The host had no candidates: it answers on the route it learned.
    let sent = pair.host.send_datagram(b"frame").unwrap();
    assert_eq!(
        sent.iter().map(|t| t.route).collect::<Vec<_>>(),
        vec![Route::Udp(addr("192.168.1.30:4103"))]
    );
}

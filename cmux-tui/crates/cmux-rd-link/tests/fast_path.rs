//! The fast path between two Macs: with the viewer's interface table, a
//! Thunderbolt Bridge path beats the office LAN at once (RTT hysteresis
//! alone keeps whichever answered first), and when the fast path drops,
//! datagrams reach the peer on another path within a few silence windows
//! instead of after three probe timeouts.

use cmux_rd_link::{Endpoint, EndpointEvent, Event, KeyPair, Role, Route};
use cmux_transport::{LocalNetwork, Medium, PathKind};
use std::net::SocketAddr;

fn addr(s: &str) -> SocketAddr {
    s.parse().unwrap()
}

/// The host's candidates, and where the viewer's packets come from on each.
const HOST_LAN: &str = "192.168.1.20:4103";
const HOST_TB: &str = "10.254.2.2:4103";
const VIEWER_LAN: &str = "192.168.1.30:4103";
const VIEWER_TB: &str = "10.254.2.1:4103";

/// Which routes deliver. Both work at first; tests cut them.
struct World {
    lan: bool,
    tb: bool,
}

impl World {
    fn to_host(&self, route: Route) -> Option<Route> {
        match route {
            Route::Udp(a) if a == addr(HOST_LAN) && self.lan => Some(Route::Udp(addr(VIEWER_LAN))),
            Route::Udp(a) if a == addr(HOST_TB) && self.tb => Some(Route::Udp(addr(VIEWER_TB))),
            _ => None,
        }
    }

    fn to_viewer(&self, route: Route) -> Option<Route> {
        match route {
            Route::Udp(a) if a == addr(VIEWER_LAN) && self.lan => Some(Route::Udp(addr(HOST_LAN))),
            Route::Udp(a) if a == addr(VIEWER_TB) && self.tb => Some(Route::Udp(addr(HOST_TB))),
            _ => None,
        }
    }
}

fn networks() -> Vec<LocalNetwork> {
    let net = |interface: &str, address: &str, prefix| LocalNetwork {
        interface: interface.into(),
        address: address.parse().unwrap(),
        prefix,
    };
    vec![net("en0", "192.168.1.30", 24), net("bridge0", "10.254.2.1", 30)]
}

struct Pair {
    viewer: Endpoint,
    host: Endpoint,
    now: u64,
    viewer_events: Vec<EndpointEvent>,
    /// When the host last opened a datagram from the viewer, and the longest
    /// gap between two.
    last_delivery: Option<u64>,
    longest_gap: u64,
}

impl Pair {
    /// The LAN candidate is signaled first, as host candidates are in
    /// interface order, so it answers first.
    fn new(with_networks: bool) -> Self {
        let (v, h) = (KeyPair::generate().unwrap(), KeyPair::generate().unwrap());
        let mut viewer = Endpoint::new(Role::Initiator, b"s1", &v, h.public, 0).unwrap();
        let mut host = Endpoint::new(Role::Responder, b"s1", &h, v.public, 0).unwrap();
        if with_networks {
            viewer.set_local_networks(networks());
            host.set_local_networks(networks());
        }
        viewer.add_path(Route::Udp(addr(HOST_LAN)), PathKind::DirectLan, 0);
        Self {
            viewer,
            host,
            now: 0,
            viewer_events: Vec::new(),
            last_delivery: None,
            longest_gap: 0,
        }
    }

    /// One tick is 1 ms; the viewer sends an input every 10 ms and the host
    /// a frame every 10 ms once the link is up.
    fn run(&mut self, world: &World, ms: u64) {
        for _ in 0..ms {
            self.now += 1_000;
            let tick = self.now / 1_000;
            let mut to_host = self.viewer.poll_transmit(self.now).unwrap();
            if self.viewer.link().is_established() && tick.is_multiple_of(10) {
                to_host.extend(self.viewer.send_datagram(b"input").unwrap());
            }
            for t in to_host {
                if let Some(from) = world.to_host(t.route) {
                    for event in self.host.on_packet(from, &t.packet, self.now).unwrap() {
                        if event == EndpointEvent::Link(Event::Datagram(b"input".to_vec())) {
                            if let Some(last) = self.last_delivery {
                                self.longest_gap = self.longest_gap.max(self.now - last);
                            }
                            self.last_delivery = Some(self.now);
                        }
                    }
                }
            }
            let mut to_viewer = self.host.poll_transmit(self.now).unwrap();
            if self.host.link().is_established() && tick % 10 == 5 {
                to_viewer.extend(self.host.send_datagram(b"frame").unwrap());
            }
            for t in to_viewer {
                if let Some(from) = world.to_viewer(t.route) {
                    self.viewer_events
                        .extend(self.viewer.on_packet(from, &t.packet, self.now).unwrap());
                }
            }
            self.viewer_events.extend(self.viewer.take_events());
            self.host.take_events();
        }
    }

    fn viewer_medium(&self) -> Option<Medium> {
        self.viewer_events.iter().rev().find_map(|e| match e {
            EndpointEvent::PathChanged { medium, .. } => Some(*medium),
            _ => None,
        })?
    }

    fn add_tb(&mut self) {
        self.viewer.add_path(Route::Udp(addr(HOST_TB)), PathKind::DirectLan, self.now);
    }
}

#[test]
fn the_thunderbolt_bridge_takes_over_from_the_lan_at_once() {
    let mut pair = Pair::new(true);
    let world = World { lan: true, tb: true };
    pair.run(&world, 1_000);
    assert_eq!(pair.viewer_medium(), Some(Medium::Lan));
    pair.add_tb();
    pair.run(&world, 500);
    assert_eq!(pair.viewer_medium(), Some(Medium::Link));
    assert_eq!(pair.viewer.current_medium(), Some(Medium::Link));
}

#[test]
fn without_the_interface_table_rtt_alone_keeps_the_lan() {
    let mut pair = Pair::new(false);
    let world = World { lan: true, tb: true };
    pair.run(&world, 1_000);
    pair.add_tb();
    pair.run(&world, 5_000);
    assert_eq!(pair.viewer.current_medium(), Some(Medium::Lan), "the old behavior");
}

#[test]
fn a_dropped_thunderbolt_path_falls_back_to_the_lan_without_a_stall() {
    let mut pair = Pair::new(true);
    pair.run(&World { lan: true, tb: true }, 1_000);
    pair.add_tb();
    pair.run(&World { lan: true, tb: true }, 2_000);
    assert_eq!(pair.viewer.current_medium(), Some(Medium::Link));
    pair.longest_gap = 0;
    // The cable comes out.
    pair.run(&World { lan: true, tb: false }, 5_000);
    // Two silence windows (100 ms each at sub-ms RTT) plus a tick: inputs
    // reach the host on the LAN within a quarter second, where three probe
    // timeouts took about four seconds.
    assert!(pair.longest_gap <= 250_000, "longest input gap {} us", pair.longest_gap);
    assert_eq!(pair.viewer.current_medium(), Some(Medium::Lan));
    // It comes back: the link wins again at once.
    pair.run(&World { lan: true, tb: true }, 3_000);
    assert_eq!(pair.viewer.current_medium(), Some(Medium::Link));
}

//! Two endpoints with several routes between them: packets go on every route
//! until one answers, the selector keeps a live direct path over a relay, a
//! relay carries the session when no direct path works, a direct path that
//! starts working takes over, and a route the peer's packets come from is
//! learned.

use cmux_rd_link::{
    Endpoint, EndpointEvent, Event, HANDSHAKE_RETRY_US, HANDSHAKE_TIMEOUT_US, KeyPair, LinkError,
    Role, Route,
};
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

#[test]
fn an_initial_handshake_waits_for_a_candidate_instead_of_being_dropped() {
    for candidate_at in [1, HANDSHAKE_RETRY_US + 1] {
        let viewer_key = KeyPair::generate().unwrap();
        let host_key = KeyPair::generate().unwrap();
        let mut viewer =
            Endpoint::new(Role::Initiator, b"startup", &viewer_key, host_key.public, 0).unwrap();
        let mut host =
            Endpoint::new(Role::Responder, b"startup", &host_key, viewer_key.public, 0).unwrap();

        // Signaling may supply the candidate before or after the first retry deadline.
        assert!(viewer.poll_transmit(0).unwrap().is_empty(), "there is no route yet");
        assert_eq!(viewer.next_deadline_us(), Some(HANDSHAKE_RETRY_US));
        if candidate_at > HANDSHAKE_RETRY_US {
            assert!(viewer.poll_transmit(HANDSHAKE_RETRY_US).unwrap().is_empty());
            assert_eq!(viewer.next_deadline_us(), Some(HANDSHAKE_RETRY_US * 2));
        }
        viewer.add_path(Route::Udp(addr(HOST_LAN)), PathKind::DirectLan, candidate_at);
        let initial = viewer.poll_transmit(candidate_at).unwrap();
        assert_eq!(initial.len(), 1, "send the queued handshake exactly once");
        host.on_packet(Route::Udp(addr(VIEWER_WAN)), &initial[0].packet, candidate_at).unwrap();
        for packet in host.poll_transmit(candidate_at).unwrap() {
            viewer.on_packet(Route::Udp(addr(HOST_LAN)), &packet.packet, candidate_at).unwrap();
        }
        for packet in viewer.poll_transmit(candidate_at).unwrap() {
            host.on_packet(Route::Udp(addr(VIEWER_WAN)), &packet.packet, candidate_at).unwrap();
        }
        assert!(viewer.link().is_established(), "viewer must connect without a retry");
        assert!(host.link().is_established(), "host must connect without a retry");
    }
}

#[test]
fn a_missing_candidate_still_reaches_the_handshake_timeout() {
    let viewer_key = KeyPair::generate().unwrap();
    let host_key = KeyPair::generate().unwrap();
    let mut viewer =
        Endpoint::new(Role::Initiator, b"timeout", &viewer_key, host_key.public, 0).unwrap();

    assert!(viewer.poll_transmit(0).unwrap().is_empty());
    assert!(matches!(
        viewer.poll_transmit(HANDSHAKE_TIMEOUT_US + 1),
        Err(LinkError::HandshakeTimeout)
    ));
}

/// The longest gap (µs) between two packets each side sent during `ms` of a
/// still session (no datagrams, no control), and how many each sent.
fn quiet_gaps(pair: &mut Pair, world: &World, ms: u64) -> ((u64, usize), (u64, usize)) {
    let start = pair.now;
    let (mut viewer_last, mut host_last) = (start, start);
    let (mut viewer, mut host) = ((0, 0), (0, 0));
    for _ in 0..ms {
        pair.now += 1_000;
        let sent = pair.viewer.poll_transmit(pair.now).unwrap();
        if !sent.is_empty() {
            viewer.0 = viewer.0.max(pair.now - viewer_last);
            viewer.1 += sent.len();
            viewer_last = pair.now;
        }
        for t in sent {
            let Some(from) = world.to_host(t.route) else { continue };
            let events = pair.host.on_packet(from, &t.packet, pair.now).unwrap();
            assert!(
                events.iter().all(|e| !matches!(e, EndpointEvent::Link(Event::Datagram(_)))),
                "a keep-awake delivers nothing"
            );
        }
        let sent = pair.host.poll_transmit(pair.now).unwrap();
        if !sent.is_empty() {
            host.0 = host.0.max(pair.now - host_last);
            host.1 += sent.len();
            host_last = pair.now;
        }
        for t in sent {
            if let Some(from) = world.to_viewer(t.route) {
                pair.viewer.on_packet(from, &t.packet, pair.now).unwrap();
            }
        }
    }
    viewer.0 = viewer.0.max(pair.now - viewer_last);
    host.0 = host.0.max(pair.now - host_last);
    (viewer, host)
}

#[test]
fn a_still_session_keeps_both_radios_awake_until_it_goes_idle() {
    use cmux_rd_link::endpoint::{KEEP_AWAKE_IDLE_US, KEEP_AWAKE_US};
    let lan = World { lan_works: true, wan_works: false, relay_works: false };
    let mut pair = Pair::new();
    pair.viewer.set_keep_awake(Some(KEEP_AWAKE_US));
    pair.host.set_keep_awake(Some(KEEP_AWAKE_US));
    pair.viewer.send_control(b"hello".to_vec(), 0).unwrap();
    pair.run(&lan, 3_000);
    assert_eq!(pair.viewer_path(), Some(PathKind::DirectLan));
    // A still screen: neither side goes longer than the interval without a packet.
    let (viewer, host) = quiet_gaps(&mut pair, &lan, 2_000);
    assert!(viewer.0 <= KEEP_AWAKE_US, "viewer gap {viewer:?}");
    assert!(host.0 <= KEEP_AWAKE_US, "host gap {host:?}");
    // About one packet per interval on top of the paths' own probes (the dead
    // paths are probed every 100 ms: about 40 in two seconds), not more.
    assert!(host.1 <= (2_000_000 / KEEP_AWAKE_US) as usize + 45, "host sent {host:?}");
    // A datagram resets the gap: no keep-awake right after it.
    let _ = pair.host.send_datagram(b"frame").unwrap();
    assert!(pair.host.poll_transmit(pair.now + KEEP_AWAKE_US / 2).unwrap().is_empty());
    // Idle past the limit: only the path's own probes and answers remain.
    pair.now += KEEP_AWAKE_IDLE_US;
    let (_, host) = quiet_gaps(&mut pair, &lan, 3_000);
    assert!(host.0 >= 100_000, "an idle session kept sending: {host:?}");
    // Traffic again: keep-awake comes back on both sides.
    pair.viewer.send_control(b"input".to_vec(), pair.now).unwrap();
    pair.run(&lan, 50);
    let (viewer, host) = quiet_gaps(&mut pair, &lan, 500);
    assert!(viewer.0 <= KEEP_AWAKE_US && host.0 <= KEEP_AWAKE_US, "{viewer:?} {host:?}");
}

#[test]
fn keep_awake_is_off_by_default() {
    let lan = World { lan_works: true, wan_works: false, relay_works: false };
    let mut pair = Pair::new();
    pair.viewer.send_control(b"hello".to_vec(), 0).unwrap();
    pair.run(&lan, 3_000);
    let (_, host) = quiet_gaps(&mut pair, &lan, 2_000);
    assert!(host.0 >= 100_000, "the host kept sending without keep-awake: {host:?}");
}

#[test]
fn a_candidate_trickled_after_the_first_handshake_is_tried_without_waiting_for_a_retry() {
    let viewer_key = KeyPair::generate().unwrap();
    let host_key = KeyPair::generate().unwrap();
    let mut viewer =
        Endpoint::new(Role::Initiator, b"trickle", &viewer_key, host_key.public, 0).unwrap();
    let mut host =
        Endpoint::new(Role::Responder, b"trickle", &host_key, viewer_key.public, 0).unwrap();

    // The answer's first candidate does not deliver; message 1 goes out on it and is lost.
    viewer.add_path(Route::Udp(addr(HOST_WAN)), PathKind::DirectWan, 0);
    assert_eq!(viewer.poll_transmit(0).unwrap().len(), 1);
    // The working one trickles in 20 ms later, well before the 250 ms retry.
    let at = 20_000;
    assert!(at < HANDSHAKE_RETRY_US);
    viewer.add_path(Route::Udp(addr(HOST_LAN)), PathKind::DirectLan, at);
    let sent = viewer.poll_transmit(at).unwrap();
    assert_eq!(
        sent.iter().map(|t| t.route).collect::<Vec<_>>(),
        vec![Route::Udp(addr(HOST_LAN))],
        "only the new route gets the message in flight"
    );
    host.on_packet(Route::Udp(addr(VIEWER_WAN)), &sent[0].packet, at).unwrap();
    for t in host.poll_transmit(at).unwrap() {
        viewer.on_packet(Route::Udp(addr(HOST_LAN)), &t.packet, at).unwrap();
    }
    for t in viewer.poll_transmit(at).unwrap() {
        host.on_packet(Route::Udp(addr(VIEWER_WAN)), &t.packet, at).unwrap();
    }
    assert!(viewer.link().is_established() && host.link().is_established());
    // A later poll does not send it again.
    let viewer_again = viewer.poll_transmit(at + 10_000).unwrap();
    assert!(viewer_again.iter().all(|t| t.packet.first() != sent[0].packet.first()));
}

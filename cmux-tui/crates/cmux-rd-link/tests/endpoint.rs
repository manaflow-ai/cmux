//! Two endpoints with several routes between them: packets go on every route
//! until one answers, the selector keeps a live direct path over a relay, a
//! relay carries the session when no direct path works, a direct path that
//! starts working takes over, and a route the peer's packets come from is
//! learned.

use cmux_rd_link::{
    Endpoint, EndpointEvent, Event, HANDSHAKE_FIRST_RETRY_US, HANDSHAKE_RETRY_US,
    HANDSHAKE_TIMEOUT_US, KeyPair, LinkError, Role, Route, SIGNALING_TIMEOUT_US,
    handshake_retry_us,
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
    for candidate_at in [1, HANDSHAKE_FIRST_RETRY_US + 1] {
        let viewer_key = KeyPair::generate().unwrap();
        let host_key = KeyPair::generate().unwrap();
        let mut viewer =
            Endpoint::new(Role::Initiator, b"startup", &viewer_key, host_key.public, 0).unwrap();
        let mut host =
            Endpoint::new(Role::Responder, b"startup", &host_key, viewer_key.public, 0).unwrap();

        // Signaling may supply the candidate before or after the first retry deadline.
        assert!(viewer.poll_transmit(0).unwrap().is_empty(), "there is no route yet");
        assert_eq!(viewer.next_deadline_us(), Some(HANDSHAKE_FIRST_RETRY_US));
        if candidate_at > HANDSHAKE_FIRST_RETRY_US {
            assert!(viewer.poll_transmit(HANDSHAKE_FIRST_RETRY_US).unwrap().is_empty());
            // The retry gap doubles from the first one.
            assert_eq!(
                viewer.next_deadline_us(),
                Some(HANDSHAKE_FIRST_RETRY_US + handshake_retry_us(1))
            );
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

/// Signaling can take longer than the handshake's own bound (the device hub under load; the
/// pair bench's relayed lines took 6 to 23 s on 2026-11-20). The handshake's clock starts when
/// the first route arrives, so a late route still connects.
#[test]
fn a_route_that_arrives_after_the_handshake_timeout_still_connects() {
    let viewer_key = KeyPair::generate().unwrap();
    let host_key = KeyPair::generate().unwrap();
    let mut viewer =
        Endpoint::new(Role::Initiator, b"late", &viewer_key, host_key.public, 0).unwrap();
    let mut host =
        Endpoint::new(Role::Responder, b"late", &host_key, viewer_key.public, 0).unwrap();

    let late = HANDSHAKE_TIMEOUT_US + 2_000_000;
    let mut now = 0;
    while now < late {
        now += HANDSHAKE_RETRY_US;
        assert!(viewer.poll_transmit(now).expect("waiting for signaling fails nothing").is_empty());
        assert!(host.poll_transmit(now).expect("waiting for the viewer fails nothing").is_empty());
    }
    viewer.add_path(Route::Udp(addr(HOST_LAN)), PathKind::DirectLan, now);
    for _ in 0..4 {
        for t in viewer.poll_transmit(now).unwrap() {
            host.on_packet(Route::Udp(addr(VIEWER_WAN)), &t.packet, now).unwrap();
        }
        for t in host.poll_transmit(now).unwrap() {
            viewer.on_packet(Route::Udp(addr(HOST_LAN)), &t.packet, now).unwrap();
        }
    }
    assert!(viewer.link().is_established(), "the viewer connects on the late route");
    assert!(host.link().is_established(), "the host connects on the late route");
}

/// A route that never arrives still ends the session, at the signaling bound, so a dead peer
/// cannot hold the socket; once a route arrives, the handshake has its own bound from then.
#[test]
fn a_route_that_never_arrives_fails_at_its_bound() {
    let viewer_key = KeyPair::generate().unwrap();
    let host_key = KeyPair::generate().unwrap();
    let mut viewer =
        Endpoint::new(Role::Initiator, b"timeout", &viewer_key, host_key.public, 0).unwrap();

    assert!(viewer.poll_transmit(0).unwrap().is_empty());
    assert!(viewer.poll_transmit(HANDSHAKE_TIMEOUT_US + 1).unwrap().is_empty(), "still waiting");
    assert!(viewer.next_deadline_us().is_some_and(|at| at <= SIGNALING_TIMEOUT_US + 1));
    assert!(matches!(viewer.poll_transmit(SIGNALING_TIMEOUT_US + 1), Err(LinkError::NoRoute)));

    let mut viewer =
        Endpoint::new(Role::Initiator, b"timeout", &viewer_key, host_key.public, 0).unwrap();
    let routed = HANDSHAKE_TIMEOUT_US + 2_000_000;
    viewer.add_path(Route::Udp(addr(HOST_LAN)), PathKind::DirectLan, routed);
    assert!(viewer.poll_transmit(routed + HANDSHAKE_TIMEOUT_US).is_ok());
    assert!(matches!(
        viewer.poll_transmit(routed + HANDSHAKE_TIMEOUT_US + 1),
        Err(LinkError::HandshakeTimeout)
    ));
}

/// The Cloud desktop's case (cloud-rd-link-readback): the host sits behind a
/// NAT or stateful firewall that drops a packet from an address it never sent
/// to. Both sides know each other's reflexive address from signaling, and the
/// viewer's message 1 only gets in once the host itself has sent to the
/// viewer's address. A responder that only listens times out.
#[test]
fn a_responder_behind_a_filtering_nat_punches_so_the_handshake_gets_in() {
    let (v, h) = (KeyPair::generate().unwrap(), KeyPair::generate().unwrap());
    let mut viewer = Endpoint::new(Role::Initiator, b"punch", &v, h.public, 0).unwrap();
    let mut host = Endpoint::new(Role::Responder, b"punch", &h, v.public, 0).unwrap();
    viewer.add_path(Route::Udp(addr(HOST_WAN)), PathKind::DirectWan, 0);
    // The viewer's srflx candidate, sent to the host as `link_candidate`.
    host.add_path(Route::Udp(addr(VIEWER_WAN)), PathKind::DirectWan, 0);
    let mut host_opened = false;
    let mut now = 0;
    while now < HANDSHAKE_TIMEOUT_US
        && !(viewer.link().is_established() && host.link().is_established())
    {
        now += 10_000;
        for t in host.poll_transmit(now).unwrap() {
            if t.route == Route::Udp(addr(VIEWER_WAN)) {
                host_opened = true;
                viewer.on_packet(Route::Udp(addr(HOST_WAN)), &t.packet, now).unwrap();
            }
        }
        for t in viewer.poll_transmit(now).unwrap() {
            // The host's NAT lets the viewer in only once the host sent to it.
            if t.route == Route::Udp(addr(HOST_WAN)) && host_opened {
                host.on_packet(Route::Udp(addr(VIEWER_WAN)), &t.packet, now).unwrap();
            }
        }
    }
    assert!(host_opened, "the responder sent nothing to the viewer's route before message 1");
    assert!(viewer.link().is_established() && host.link().is_established());
    assert!(now < 1_000_000, "up within one second, not at the timeout: {now} us");
}

#[test]
fn a_responder_punches_each_retry_interval_and_an_initiator_drops_the_punch() {
    let (v, h) = (KeyPair::generate().unwrap(), KeyPair::generate().unwrap());
    let mut host = Endpoint::new(Role::Responder, b"punch", &h, v.public, 0).unwrap();
    let mut viewer = Endpoint::new(Role::Initiator, b"punch", &v, h.public, 0).unwrap();
    assert!(host.poll_transmit(0).unwrap().is_empty(), "no route: nothing to punch");
    host.add_path(Route::Udp(addr(VIEWER_WAN)), PathKind::DirectWan, 5);
    assert_eq!(host.next_deadline_us(), Some(0), "a new route is punched at once");
    let first = host.poll_transmit(5).unwrap();
    assert_eq!(first.len(), 1);
    assert_eq!(first[0].packet, vec![0xD4], "one byte, TAG_PUNCH");
    assert!(host.poll_transmit(6).unwrap().is_empty(), "one punch per retry interval");
    assert_eq!(host.next_deadline_us(), Some(5 + HANDSHAKE_RETRY_US));
    // An initiator drops a punch: no event, no learned route, no answer.
    assert!(viewer.on_packet(Route::Udp(addr(HOST_WAN)), &first[0].packet, 5).unwrap().is_empty());
    assert!(viewer.poll_transmit(5).unwrap().is_empty(), "the viewer has no route to answer on");
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

#[test]
fn a_viewer_with_no_route_yet_sleeps_between_retries_instead_of_spinning() {
    let viewer_key = KeyPair::generate().unwrap();
    let host_key = KeyPair::generate().unwrap();
    let mut viewer =
        Endpoint::new(Role::Initiator, b"idle", &viewer_key, host_key.public, 0).unwrap();
    // A caller that polls at each deadline, with no candidate for one second.
    let mut now = 0;
    let mut polls = 0;
    while now < 1_000_000 && polls < 10_000 {
        assert!(viewer.poll_transmit(now).unwrap().is_empty(), "there is no route yet");
        polls += 1;
        let next = viewer.next_deadline_us().expect("a handshake retry is due");
        assert!(next > now, "deadline {next} is not after now {now}: the caller would spin");
        now = next;
    }
    println!("NO-ROUTE-POLLS one_second={polls}");
    // 50 ms doubling to the 250 ms cap: 0, 50, 150, 350, 600, 850 ms.
    assert!(polls <= 8, "{polls} polls in one second with no route");
}

/// The route that finished the handshake carries the session from that moment
/// (RFD 0164 B10): no round trip waiting for a probe with every datagram on
/// every path, relay included.
#[test]
fn the_route_that_finished_the_handshake_carries_the_session_at_once() {
    let mut pair = Pair::new();
    let world = World { lan_works: false, wan_works: true, relay_works: true };
    while !(pair.viewer.link().is_established() && pair.host.link().is_established()) {
        assert!(pair.now < 2_000_000, "the link never came up");
        pair.run(&world, 10);
    }
    let chosen = |events: &[EndpointEvent]| {
        events.iter().any(|e| matches!(e, EndpointEvent::PathChanged { route: Some(_), .. }))
    };
    assert!(chosen(&pair.viewer_events), "viewer: no path at Established");
    assert!(chosen(&pair.host_events), "host: no path at Established");
    assert_eq!(pair.host.send_datagram(b"frame").unwrap().len(), 1, "host sprays media");
    assert_eq!(pair.viewer.send_datagram(b"input").unwrap().len(), 1, "viewer sprays input");
    // Probes still rank the paths: the direct path holds against the relay.
    pair.run(&world, 3_000);
    assert_eq!(pair.viewer_path(), Some(PathKind::DirectWan));
}

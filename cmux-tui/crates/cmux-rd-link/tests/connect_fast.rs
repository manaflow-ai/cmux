//! Connect time on a wired LAN pair, on a fake clock with real one-way delays
//! (goal screen-share-fast, "Connect on Leo's NIGHTLY": cmux20 host, cmux17
//! viewer). The host offers its wired, tailnet and public addresses; the
//! viewer dials all three at once and the host learns the viewer's routes
//! from its packets.
//!
//! - Connect is one and a half round trips of the fastest path that answers:
//!   a dead tailnet or WAN candidate costs nothing, nothing waits on them.
//! - Both sides settle on the LAN path, and both call it a LAN path (the host
//!   used to report every route it learned from a handshake as `direct_wan`).
//! - A lost handshake message costs [`HANDSHAKE_FIRST_RETRY_US`], not the
//!   full 250 ms [`HANDSHAKE_RETRY_US`].

use cmux_rd_link::{
    Endpoint, EndpointEvent, Event, HANDSHAKE_FIRST_RETRY_US, HANDSHAKE_RETRY_US, KeyPair, Role,
    Route, TAG_HANDSHAKE_1, TAG_HANDSHAKE_2, TAG_HANDSHAKE_3,
};
use cmux_transport::PathKind;
use std::net::SocketAddr;

fn addr(s: &str) -> SocketAddr {
    s.parse().unwrap()
}

const HOST_LAN: &str = "172.20.21.250:50100";
const HOST_TAILNET: &str = "100.127.99.33:50100";
const HOST_WAN: &str = "203.0.113.7:51000";
const VIEWER_LAN: &str = "172.20.21.17:61200";
const VIEWER_TAILNET: &str = "100.101.7.17:61200";
const VIEWER_WAN: &str = "198.51.100.9:62000";

/// One leg: where the viewer sends, where the host sees it from, its one-way delay.
struct Leg {
    host: &'static str,
    viewer: &'static str,
    one_way_us: u64,
    works: bool,
}

struct World {
    legs: Vec<Leg>,
    /// Drop the first packet whose first byte is this tag.
    drop_tag: Option<u8>,
}

impl World {
    fn wired(lan: bool, tailnet: bool, wan: bool) -> Self {
        Self {
            legs: vec![
                Leg { host: HOST_LAN, viewer: VIEWER_LAN, one_way_us: 250, works: lan },
                Leg {
                    host: HOST_TAILNET,
                    viewer: VIEWER_TAILNET,
                    one_way_us: 2_500,
                    works: tailnet,
                },
                Leg { host: HOST_WAN, viewer: VIEWER_WAN, one_way_us: 10_000, works: wan },
            ],
            drop_tag: None,
        }
    }
}

struct Flight {
    at_us: u64,
    to_host: bool,
    from: Route,
    packet: Vec<u8>,
}

struct Run {
    viewer: Endpoint,
    host: Endpoint,
    viewer_events: Vec<EndpointEvent>,
    host_events: Vec<EndpointEvent>,
    /// When each side reported `Established`.
    viewer_up_us: Option<u64>,
    host_up_us: Option<u64>,
}

const TICK_US: u64 = 50;

/// The viewer got the answer at 0 and dials every host candidate; runs for `ms`.
fn run(mut world: World, ms: u64) -> Run {
    let (v, h) = (KeyPair::generate().unwrap(), KeyPair::generate().unwrap());
    let host = Endpoint::new(Role::Responder, b"wired", &h, v.public, 0).unwrap();
    let mut viewer = Endpoint::new(Role::Initiator, b"wired", &v, h.public, 0).unwrap();
    // Candidate kinds as `net::Candidate::path_kind` gives them for host candidates.
    viewer.add_path(Route::Udp(addr(HOST_LAN)), PathKind::DirectLan, 0);
    viewer.add_path(Route::Udp(addr(HOST_TAILNET)), PathKind::DirectWan, 0);
    viewer.add_path(Route::Udp(addr(HOST_WAN)), PathKind::DirectWan, 0);
    let mut r = Run {
        viewer,
        host,
        viewer_events: Vec::new(),
        host_events: Vec::new(),
        viewer_up_us: None,
        host_up_us: None,
    };
    let mut flights: Vec<Flight> = Vec::new();
    let mut now = 0;
    while now <= ms * 1000 {
        let (due, later): (Vec<Flight>, Vec<Flight>) =
            flights.into_iter().partition(|f| f.at_us <= now);
        flights = later;
        for f in due {
            let events = if f.to_host {
                r.host.on_packet(f.from, &f.packet, now).unwrap()
            } else {
                r.viewer.on_packet(f.from, &f.packet, now).unwrap()
            };
            let up = events.contains(&EndpointEvent::Link(Event::Established));
            if f.to_host {
                r.host_up_us = r.host_up_us.or(up.then_some(now));
                r.host_events.extend(events);
            } else {
                r.viewer_up_us = r.viewer_up_us.or(up.then_some(now));
                r.viewer_events.extend(events);
            }
        }
        for to_host in [true, false] {
            let sender = if to_host { &mut r.viewer } else { &mut r.host };
            for t in sender.poll_transmit(now).unwrap() {
                if world.drop_tag.is_some() && t.packet.first() == world.drop_tag.as_ref() {
                    world.drop_tag = None;
                    continue;
                }
                let Route::Udp(dst) = t.route else { continue };
                let leg = world.legs.iter().find(|leg| {
                    leg.works && addr(if to_host { leg.host } else { leg.viewer }) == dst
                });
                if let Some(leg) = leg {
                    let from = addr(if to_host { leg.viewer } else { leg.host });
                    flights.push(Flight {
                        at_us: now + leg.one_way_us,
                        to_host,
                        from: Route::Udp(from),
                        packet: t.packet,
                    });
                }
            }
        }
        r.viewer_events.extend(r.viewer.take_events());
        r.host_events.extend(r.host.take_events());
        now += TICK_US;
    }
    r
}

fn last_path(events: &[EndpointEvent]) -> Option<(Route, PathKind)> {
    events.iter().rev().find_map(|e| match e {
        EndpointEvent::PathChanged { route: Some(route), kind: Some(kind), .. } => {
            Some((*route, *kind))
        }
        _ => None,
    })
}

#[test]
fn offered_lan_tailnet_and_wan_both_sides_take_the_lan_and_call_it_lan() {
    let r = run(World::wired(true, true, true), 3_000);
    assert_eq!(
        last_path(&r.viewer_events),
        Some((Route::Udp(addr(HOST_LAN)), PathKind::DirectLan)),
        "viewer"
    );
    assert_eq!(
        last_path(&r.host_events),
        Some((Route::Udp(addr(VIEWER_LAN)), PathKind::DirectLan)),
        "host: a viewer route learned from the handshake on a private address is a LAN path"
    );
    // One and a half LAN round trips (0.5 ms each), to the tick.
    let host_up = r.host_up_us.expect("host connected");
    assert!(host_up <= 750 + 2 * TICK_US, "host connected at {host_up} us");
}

#[test]
fn dead_tailnet_and_wan_candidates_cost_the_lan_connect_nothing() {
    let r = run(World::wired(true, false, false), 1_000);
    let host_up = r.host_up_us.expect("host connected");
    assert!(host_up <= 750 + 2 * TICK_US, "host connected at {host_up} us");
    assert_eq!(
        last_path(&r.host_events),
        Some((Route::Udp(addr(VIEWER_LAN)), PathKind::DirectLan))
    );
}

#[test]
fn only_the_tailnet_works_and_it_connects_in_its_own_round_trips() {
    let r = run(World::wired(false, true, false), 1_000);
    let host_up = r.host_up_us.expect("host connected");
    assert!(host_up <= 7_500 + 2 * TICK_US, "host connected at {host_up} us");
    assert_eq!(
        last_path(&r.viewer_events),
        Some((Route::Udp(addr(HOST_TAILNET)), PathKind::DirectWan))
    );
}

#[test]
fn a_lost_handshake_message_costs_the_first_retry_not_250_ms() {
    for tag in [TAG_HANDSHAKE_1, TAG_HANDSHAKE_2, TAG_HANDSHAKE_3] {
        let mut world = World::wired(true, false, false);
        world.drop_tag = Some(tag);
        let r = run(world, 1_000);
        let host_up = r.host_up_us.expect("host connected");
        // The first resend, then one and a half LAN round trips at most.
        let bound = HANDSHAKE_FIRST_RETRY_US + 750 + 4 * TICK_US;
        assert!(
            host_up <= bound && host_up < HANDSHAKE_RETRY_US,
            "message {tag:#x} lost: host connected at {host_up} us (bound {bound})"
        );
        assert!(r.viewer_up_us.is_some(), "viewer connected");
    }
}

//! How fast the path layer picks a path and leaves a dead one, under real
//! round trips (RFD 0164 B10): a viewer and a host with a direct path and a
//! TURN relay between them, each route with its own delay, 60 fps media from
//! the host and one feedback datagram back per frame (as the rd engine
//! sends). Halfway through, the direct path drops in both directions.
//!
//! Measured per RTT (50 and 150 ms) and printed as one `path_timing` line:
//! - `nominate`: from each side's `Established` to its first chosen path
//!   (until then every datagram goes out on every path);
//! - `sprayed`: media datagrams the host sent beyond one per frame;
//! - `gap`: the longest wait between two frames reaching the viewer around
//!   the drop (60 fps is 16.7 ms);
//! - `on_time`: frames of the second after the drop that reached the viewer
//!   within 100 ms of being sent, of 60.

use cmux_rd_link::{Endpoint, EndpointEvent, Event, KeyPair, Role, Route};
use cmux_transport::PathKind;
use std::collections::HashMap;
use std::net::SocketAddr;

fn addr(s: &str) -> SocketAddr {
    s.parse().unwrap()
}

const HOST_WAN: &str = "203.0.113.7:51000";
const VIEWER_WAN: &str = "198.51.100.9:62000";
const TICK_US: u64 = 1_000;
const FRAME_US: u64 = 16_667;
/// The relay's detour on top of the direct round trip.
const RELAY_EXTRA_US: u64 = 20_000;
/// When the direct path drops, after the session started.
const CUT_US: u64 = 4_000_000;
const RUN_US: u64 = 7_000_000;
const ON_TIME_US: u64 = 100_000;

struct Packet {
    at: u64,
    to_host: bool,
    from: Route,
    bytes: Vec<u8>,
}

struct Wire {
    rtt_us: u64,
    direct: bool,
    in_flight: Vec<Packet>,
}

impl Wire {
    /// Puts one packet on `route`, if it delivers, with its route's delay.
    fn send(&mut self, now: u64, to_host: bool, route: Route, bytes: Vec<u8>) {
        let (from, one_way) = match (to_host, route) {
            (true, Route::Udp(a)) if a == addr(HOST_WAN) && self.direct => {
                (Route::Udp(addr(VIEWER_WAN)), self.rtt_us / 2)
            }
            (false, Route::Udp(a)) if a == addr(VIEWER_WAN) && self.direct => {
                (Route::Udp(addr(HOST_WAN)), self.rtt_us / 2)
            }
            (true, Route::Relay { relay: 0, .. }) => (
                Route::Relay { relay: 0, peer: addr("192.0.2.1:3478") },
                (self.rtt_us + RELAY_EXTRA_US) / 2,
            ),
            (false, Route::Relay { relay: 0, .. }) => (
                Route::Relay { relay: 0, peer: addr("192.0.2.2:3478") },
                (self.rtt_us + RELAY_EXTRA_US) / 2,
            ),
            _ => return,
        };
        self.in_flight.push(Packet { at: now + one_way, to_host, from, bytes });
    }

    fn due(&mut self, now: u64) -> Vec<Packet> {
        let (due, later): (Vec<_>, Vec<_>) =
            std::mem::take(&mut self.in_flight).into_iter().partition(|p| p.at <= now);
        self.in_flight = later;
        due
    }
}

#[derive(Debug)]
struct Timing {
    viewer_nominate_us: u64,
    host_nominate_us: u64,
    sprayed: usize,
    gap_us: u64,
    on_time: usize,
}

fn first_path(events: &[(u64, EndpointEvent)]) -> Option<u64> {
    events.iter().find_map(|(at, e)| {
        matches!(e, EndpointEvent::PathChanged { route: Some(_), .. }).then_some(*at)
    })
}

fn established(events: &[(u64, EndpointEvent)]) -> Option<u64> {
    events
        .iter()
        .find_map(|(at, e)| matches!(e, EndpointEvent::Link(Event::Established)).then_some(*at))
}

fn run(rtt_us: u64, braid: bool) -> Timing {
    let (v, h) = (KeyPair::generate().unwrap(), KeyPair::generate().unwrap());
    let mut viewer = Endpoint::new(Role::Initiator, b"s1", &v, h.public, 0).unwrap();
    let mut host = Endpoint::new(Role::Responder, b"s1", &h, v.public, 0).unwrap();
    viewer.set_braid_paths(braid);
    host.set_braid_paths(braid);
    viewer.add_path(Route::Udp(addr(HOST_WAN)), PathKind::DirectWan, 0);
    viewer.add_path(Route::Relay { relay: 0, peer: addr(HOST_WAN) }, PathKind::TurnRelay, 0);
    let mut wire = Wire { rtt_us, direct: true, in_flight: Vec::new() };
    let mut viewer_events: Vec<(u64, EndpointEvent)> = Vec::new();
    let mut host_events: Vec<(u64, EndpointEvent)> = Vec::new();
    let mut sent_at: HashMap<u64, u64> = HashMap::new();
    let mut arrived: HashMap<u64, u64> = HashMap::new();
    let mut next_frame: Option<u64> = None;
    // When media started: the drop comes CUT_US after it.
    let mut media_start: Option<u64> = None;
    let mut frame_no = 0u64;
    let mut sprayed = 0usize;
    let mut cut_at = None;
    let mut now = 0;
    while now < RUN_US {
        now += TICK_US;
        for p in wire.due(now) {
            if p.to_host {
                for e in host.on_packet(p.from, &p.bytes, now).unwrap() {
                    host_events.push((now, e));
                }
            } else {
                for e in viewer.on_packet(p.from, &p.bytes, now).unwrap() {
                    if let EndpointEvent::Link(Event::Datagram(d)) = &e {
                        let no = u64::from_le_bytes(d[..8].try_into().unwrap());
                        if arrived.insert(no, now).is_none() {
                            // One feedback datagram per frame, as the engine sends.
                            for t in viewer.send_datagram(b"feedback").unwrap() {
                                wire.send(now, true, t.route, t.packet);
                            }
                        }
                    }
                    viewer_events.push((now, e));
                }
            }
        }
        if host.link().is_established() && next_frame.is_none() {
            next_frame = Some(now);
            media_start = Some(now);
        }
        if cut_at.is_none() && media_start.is_some_and(|start| now >= start + CUT_US) {
            wire.direct = false;
            cut_at = Some(now);
        }
        if let Some(at) = next_frame
            && now >= at
        {
            let mut frame = frame_no.to_le_bytes().to_vec();
            frame.resize(1_000, 0);
            let out = host.send_datagram(&frame).unwrap();
            sprayed += out.len().saturating_sub(1);
            for t in out {
                wire.send(now, false, t.route, t.packet);
            }
            sent_at.insert(frame_no, now);
            frame_no += 1;
            next_frame = Some(at + FRAME_US);
        }
        for t in viewer.poll_transmit(now).unwrap() {
            wire.send(now, true, t.route, t.packet);
        }
        for t in host.poll_transmit(now).unwrap() {
            wire.send(now, false, t.route, t.packet);
        }
        viewer_events.extend(viewer.take_events().into_iter().map(|e| (now, e)));
        host_events.extend(host.take_events().into_iter().map(|e| (now, e)));
    }
    let cut = cut_at.expect("the direct path was never cut: media never started");
    let viewer_up = established(&viewer_events).unwrap();
    let host_up = established(&host_events).unwrap();
    let mut arrivals: Vec<u64> = arrived.values().copied().filter(|at| *at >= cut).collect();
    arrivals.sort_unstable();
    let gap_us = arrivals.windows(2).map(|w| w[1] - w[0]).max().unwrap_or(u64::MAX);
    let on_time = sent_at
        .iter()
        .filter(|(_, sent)| **sent >= cut && **sent < cut + 1_000_000)
        .filter(|(no, sent)| arrived.get(no).is_some_and(|at| at - **sent <= ON_TIME_US))
        .count();
    Timing {
        viewer_nominate_us: first_path(&viewer_events).unwrap() - viewer_up,
        host_nominate_us: first_path(&host_events).unwrap() - host_up,
        sprayed,
        gap_us,
        on_time,
    }
}

#[test]
fn path_choice_and_failover_under_50_and_150_ms_round_trips() {
    for rtt_ms in [50u64, 150] {
        for braid in [false, true] {
            let t = run(rtt_ms * 1_000, braid);
            println!(
                "path_timing rtt_ms={rtt_ms} mode={} viewer_nominate_ms={:.1} \
                 host_nominate_ms={:.1} sprayed={} gap_ms={:.1} on_time={}/60",
                if braid { "after" } else { "before" },
                t.viewer_nominate_us as f64 / 1e3,
                t.host_nominate_us as f64 / 1e3,
                t.sprayed,
                t.gap_us as f64 / 1e3,
                t.on_time,
            );
            // Both modes survive the drop on the relay and keep media flowing.
            assert!(t.on_time > 0, "{rtt_ms} ms: no frame on time after the drop: {t:?}");
            assert!(t.gap_us < 3_000_000, "{rtt_ms} ms: media stalled: {t:?}");
            if braid {
                // B10: a path is chosen at Established, not a probe round trip later.
                assert!(t.viewer_nominate_us <= 2_000, "{rtt_ms} ms: {t:?}");
                assert!(t.host_nominate_us <= 2_000, "{rtt_ms} ms: {t:?}");
            }
        }
    }
}

//! A screen share resumes after idle or a sleep within one trip: a frame sent
//! after the session sat still past WireGuard's rekey times (120 s, 180 s)
//! arrives at once, and so does the first frame after the host slept while
//! the path it had chosen died, because the wake re-checks every path
//! (`cmux_rd_link::wake`) instead of sending on the dead one until the
//! silence window and the media layer's tail probe catch it.
//!
//! Simulated time with real one-way delays: 5 ms on the LAN, 20 ms through
//! the relay. A sleeping host is neither polled nor reachable, and its link
//! clock stands still (`Instant` reads uptime on macOS).

use cmux_rd_link::wake::SleepWatch;
use cmux_rd_link::{Endpoint, EndpointEvent, Event, KeyPair, Role, Route};
use cmux_transport::PathKind;
use std::net::SocketAddr;

fn addr(s: &str) -> SocketAddr {
    s.parse().unwrap()
}

const HOST_LAN: &str = "192.168.1.20:4103";
const VIEWER_LAN: &str = "192.168.1.30:4103";
const RELAY_PEER: &str = "203.0.113.7:51000";
const LAN_US: u64 = 5_000;
const RELAY_US: u64 = 20_000;
/// The media layer resends an unanswered frame's tail after this long
/// (`cmux-rd-engine` `TAIL_PROBE_US`).
const TAIL_PROBE_US: u64 = 250_000;

#[derive(Clone, Copy, PartialEq)]
enum Side {
    Viewer,
    Host,
}

struct Sim {
    viewer: Endpoint,
    host: Endpoint,
    /// Wall time; the viewer's link clock.
    now: u64,
    /// How long the host slept: its link clock is `now - host_slept`.
    host_slept: u64,
    host_asleep: bool,
    lan_works: bool,
    /// (arrives at, to, from route, packet).
    wire: Vec<(u64, Side, Route, Vec<u8>)>,
    viewer_got: Vec<(u64, Vec<u8>)>,
    viewer_path: Option<PathKind>,
}

impl Sim {
    fn new() -> Self {
        let (v, h) = (KeyPair::generate().unwrap(), KeyPair::generate().unwrap());
        let mut viewer = Endpoint::new(Role::Initiator, b"s1", &v, h.public, 0).unwrap();
        let mut host = Endpoint::new(Role::Responder, b"s1", &h, v.public, 0).unwrap();
        viewer.add_path(Route::Udp(addr(HOST_LAN)), PathKind::DirectLan, 0);
        viewer.add_path(Route::Relay { relay: 0, peer: addr(RELAY_PEER) }, PathKind::TurnRelay, 0);
        host.add_path(Route::Udp(addr(VIEWER_LAN)), PathKind::DirectLan, 0);
        host.add_path(Route::Relay { relay: 0, peer: addr(RELAY_PEER) }, PathKind::TurnRelay, 0);
        Self {
            viewer,
            host,
            now: 0,
            host_slept: 0,
            host_asleep: false,
            lan_works: true,
            wire: Vec::new(),
            viewer_got: Vec::new(),
            viewer_path: None,
        }
    }

    fn host_now(&self) -> u64 {
        self.now - self.host_slept
    }

    /// Puts one packet on the wire, if its route works and the far side is awake.
    fn send(&mut self, from: Side, route: Route, packet: Vec<u8>) {
        let to = if from == Side::Viewer { Side::Host } else { Side::Viewer };
        let (delay, seen_from) = match route {
            Route::Udp(_) if !self.lan_works => return,
            Route::Udp(_) if from == Side::Viewer => (LAN_US, Route::Udp(addr(VIEWER_LAN))),
            Route::Udp(_) => (LAN_US, Route::Udp(addr(HOST_LAN))),
            Route::Relay { .. } => (RELAY_US, route),
        };
        self.wire.push((self.now + delay, to, seen_from, packet));
    }

    fn host_send_frame(&mut self, frame: &[u8]) {
        for t in self.host.send_datagram(frame).unwrap() {
            self.send(Side::Host, t.route, t.packet);
        }
    }

    /// Advances 1 ms at a time for `ms`.
    fn run(&mut self, ms: u64) {
        for _ in 0..ms {
            self.now += 1_000;
            if self.host_asleep {
                self.host_slept += 1_000;
            }
            let due: Vec<_> = {
                let now = self.now;
                let (due, later) =
                    std::mem::take(&mut self.wire).into_iter().partition(|(at, ..)| *at <= now);
                self.wire = later;
                due
            };
            for (_, to, route, packet) in due {
                match to {
                    // A sleeping machine hears nothing.
                    Side::Host if self.host_asleep => {}
                    Side::Host => {
                        let now = self.host_now();
                        self.host.on_packet(route, &packet, now).unwrap();
                    }
                    Side::Viewer => {
                        for event in self.viewer.on_packet(route, &packet, self.now).unwrap() {
                            match event {
                                EndpointEvent::Link(Event::Datagram(d)) => {
                                    self.viewer_got.push((self.now, d));
                                }
                                EndpointEvent::PathChanged { kind, .. } => self.viewer_path = kind,
                                _ => {}
                            }
                        }
                    }
                }
            }
            for t in self.viewer.poll_transmit(self.now).unwrap() {
                self.send(Side::Viewer, t.route, t.packet);
            }
            for event in self.viewer.take_events() {
                if let EndpointEvent::PathChanged { kind, .. } = event {
                    self.viewer_path = kind;
                }
            }
            if !self.host_asleep {
                let now = self.host_now();
                for t in self.host.poll_transmit(now).unwrap() {
                    self.send(Side::Host, t.route, t.packet);
                }
                self.host.take_events();
            }
        }
    }

    /// Sends one single-datagram frame now, resent each tail probe while it
    /// has not arrived, and returns how long it took to reach the viewer.
    fn frame_latency(&mut self, frame: &[u8]) -> u64 {
        let sent = self.now;
        self.host_send_frame(frame);
        loop {
            self.run(1);
            if let Some((at, _)) = self.viewer_got.iter().find(|(_, d)| d == frame) {
                return at - sent;
            }
            let waited = self.now - sent;
            assert!(waited < 2_000_000, "the frame never arrived");
            if waited.is_multiple_of(TAIL_PROBE_US) {
                self.host_send_frame(frame);
            }
        }
    }

    fn established_on_lan() -> Self {
        let mut sim = Self::new();
        sim.run(3_000);
        assert!(sim.viewer.link().is_established() && sim.host.link().is_established());
        assert_eq!(sim.viewer_path, Some(PathKind::DirectLan));
        assert_eq!(sim.frame_latency(b"first"), LAN_US);
        sim
    }

    /// The host sleeps `ms` while the LAN dies under it (Wi-Fi joins again,
    /// a mapping expires), then wakes and sends the next frame at once.
    /// `notices_wake`: the host's driver feeds its [`SleepWatch`].
    fn sleep_and_wake(&mut self, ms: u64, notices_wake: bool) -> u64 {
        let mut watch = SleepWatch::default();
        watch.observe(self.host_now(), self.now);
        self.host_asleep = true;
        self.lan_works = false;
        self.run(ms);
        self.host_asleep = false;
        if watch.observe(self.host_now(), self.now) && notices_wake {
            self.host.on_network_change();
        }
        self.frame_latency(b"after wake")
    }
}

#[test]
fn a_frame_after_idle_past_the_rekey_times_arrives_in_one_trip() {
    // WireGuard re-keys a session idle past 120 s and refuses one past 180 s,
    // so its first packet after that waits a handshake round trip. This link
    // keeps its keys and its probes keep the path proven, so neither costs a trip.
    let mut sim = Sim::established_on_lan();
    for (idle_s, frame) in
        [(121, &b"after 121 s"[..]), (181, b"after 181 s"), (300, b"after 300 s")]
    {
        sim.run(idle_s * 1_000);
        assert_eq!(sim.frame_latency(frame), LAN_US, "after {idle_s} s idle");
    }
}

#[test]
fn the_first_frame_after_the_host_wakes_arrives_in_one_trip() {
    let mut sim = Sim::established_on_lan();
    // Under the viewer's 90 s peer-lost bound, so the session survives the sleep.
    let latency = sim.sleep_and_wake(60_000, true);
    eprintln!("wake to first frame: {} ms", latency as f64 / 1_000.0);
    assert!(latency <= 2 * RELAY_US, "the first frame after a wake took {latency} us");
    // Probes pick the live path again right away; the next frame takes it alone.
    sim.run(200);
    assert_eq!(sim.frame_latency(b"next"), RELAY_US);
}

#[test]
fn without_noticing_the_wake_the_first_frame_waits_for_the_tail_probe() {
    // What the driver did before it watched for sleep: the host held the dead
    // LAN as its path (its clock says it heard it a moment ago), so the frame
    // went there alone and only the tail probe, sent after the silence window
    // made the path suspect, got through.
    let mut sim = Sim::established_on_lan();
    let latency = sim.sleep_and_wake(60_000, false);
    eprintln!("wake to first frame, wake not noticed: {} ms", latency as f64 / 1_000.0);
    assert!(latency >= TAIL_PROBE_US, "took {latency} us");
}

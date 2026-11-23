//! A full network drop between viewer and host (every packet lost both ways
//! for 10 s, then for 60 s): the established link neither fails nor closes,
//! and once the network is back, datagrams and control records flow again
//! within a couple of seconds with no new handshake. This is the link half of
//! "screen-share frames come back by themselves after a 10 s and a 60 s full
//! drop"; the host keeps its session through the drop (cmux-rd-host
//! `stream.rs`, `REATTACH_GRACE_NS`), and `screen-share-netem.py --blip-at S
//! --drop-seconds 10 --drop-seconds 60` measures the whole path under tc netem.

use cmux_rd_link::{Endpoint, EndpointEvent, Event, KeyPair, Role, Route};
use cmux_transport::PathKind;
use std::net::SocketAddr;

fn addr(s: &str) -> SocketAddr {
    s.parse().unwrap()
}

const HOST: &str = "10.77.0.1:4103";
const VIEWER: &str = "10.77.0.2:4103";

struct Pair {
    viewer: Endpoint,
    host: Endpoint,
    now: u64,
    /// When the host last opened the viewer's input, and the viewer the host's frame.
    host_heard: Option<u64>,
    viewer_heard: Option<u64>,
    /// Control records each side delivered, in order.
    host_controls: Vec<Vec<u8>>,
    viewer_controls: Vec<Vec<u8>>,
    /// Closed or failed on either side.
    ended: Vec<String>,
}

impl Pair {
    fn new() -> Self {
        let (v, h) = (KeyPair::generate().unwrap(), KeyPair::generate().unwrap());
        let mut viewer = Endpoint::new(Role::Initiator, b"s1", &v, h.public, 0).unwrap();
        let host = Endpoint::new(Role::Responder, b"s1", &h, v.public, 0).unwrap();
        viewer.add_path(Route::Udp(addr(HOST)), PathKind::DirectLan, 0);
        Self {
            viewer,
            host,
            now: 0,
            host_heard: None,
            viewer_heard: None,
            host_controls: Vec::new(),
            viewer_controls: Vec::new(),
            ended: Vec::new(),
        }
    }

    fn note(&mut self, to_host: bool, events: Vec<EndpointEvent>) {
        for event in events {
            match event {
                EndpointEvent::Link(Event::Datagram(_)) if to_host => {
                    self.host_heard = Some(self.now);
                }
                EndpointEvent::Link(Event::Datagram(_)) => self.viewer_heard = Some(self.now),
                EndpointEvent::Link(Event::Control(record)) if to_host => {
                    self.host_controls.push(record);
                }
                EndpointEvent::Link(Event::Control(record)) => self.viewer_controls.push(record),
                EndpointEvent::Link(Event::Closed) => self.ended.push("closed".into()),
                _ => {}
            }
        }
    }

    /// One tick is 1 ms: the viewer sends an input every 10 ms and the host a
    /// frame every 10 ms once the link is up; `up` false loses every packet.
    fn run(&mut self, up: bool, ms: u64) {
        for _ in 0..ms {
            self.now += 1_000;
            let tick = self.now / 1_000;
            let mut to_host = match self.viewer.poll_transmit(self.now) {
                Ok(out) => out,
                Err(e) => {
                    self.ended.push(format!("viewer: {e}"));
                    return;
                }
            };
            if self.viewer.link().is_established() && tick.is_multiple_of(10) {
                to_host.extend(self.viewer.send_datagram(b"input").unwrap());
            }
            for t in to_host {
                if up && t.route == Route::Udp(addr(HOST)) {
                    let events =
                        self.host.on_packet(Route::Udp(addr(VIEWER)), &t.packet, self.now).unwrap();
                    self.note(true, events);
                }
            }
            let mut to_viewer = match self.host.poll_transmit(self.now) {
                Ok(out) => out,
                Err(e) => {
                    self.ended.push(format!("host: {e}"));
                    return;
                }
            };
            if self.host.link().is_established() && tick % 10 == 5 {
                to_viewer.extend(self.host.send_datagram(b"frame").unwrap());
            }
            for t in to_viewer {
                if up && t.route == Route::Udp(addr(VIEWER)) {
                    let events =
                        self.viewer.on_packet(Route::Udp(addr(HOST)), &t.packet, self.now).unwrap();
                    self.note(false, events);
                }
            }
            let events = self.viewer.take_events();
            self.note(false, events);
            let events = self.host.take_events();
            self.note(true, events);
        }
    }

    /// Drops the network for `drop_s` seconds, sends a control record each way
    /// in the middle of it, restores it, and answers how long after the
    /// restore both directions carried a datagram again (ms).
    fn drop_and_restore(&mut self, drop_s: u64) -> u64 {
        self.run(false, drop_s * 500);
        let (viewer_ctl, host_ctl) = (self.viewer_controls.len(), self.host_controls.len());
        self.viewer.send_control(b"keyframe please".to_vec(), self.now).unwrap();
        self.host.send_control(b"stats".to_vec(), self.now).unwrap();
        self.run(false, drop_s * 500);
        assert!(self.ended.is_empty(), "the link ended during a {drop_s} s drop: {:?}", self.ended);
        let restored = self.now;
        let mut waited_ms = 0;
        while !(self.host_heard.is_some_and(|t| t > restored)
            && self.viewer_heard.is_some_and(|t| t > restored))
        {
            assert!(
                waited_ms < 10_000,
                "no datagram both ways within 10 s of the end of a {drop_s} s drop"
            );
            self.run(true, 1);
            waited_ms += 1;
        }
        // The control records sent into the drop arrive once it ends.
        self.run(true, 3_000);
        assert!(self.ended.is_empty(), "the link ended after a {drop_s} s drop: {:?}", self.ended);
        assert_eq!(
            self.host_controls[host_ctl..],
            [b"keyframe please".to_vec()],
            "{drop_s} s drop"
        );
        assert_eq!(self.viewer_controls[viewer_ctl..], [b"stats".to_vec()], "{drop_s} s drop");
        waited_ms
    }
}

#[test]
fn media_and_control_return_by_themselves_after_a_10_s_and_a_60_s_full_drop() {
    let mut pair = Pair::new();
    pair.run(true, 1_000);
    assert!(pair.viewer.link().is_established() && pair.host.link().is_established());
    assert!(pair.host_heard.is_some() && pair.viewer_heard.is_some());
    for drop_s in [10, 60] {
        let back_ms = pair.drop_and_restore(drop_s);
        // A dead path is probed every 100 ms, so the first probe after the
        // restore answers within a few of them.
        assert!(back_ms <= 1_000, "media back {back_ms} ms after a {drop_s} s drop");
        assert!(pair.viewer.link().is_established() && pair.host.link().is_established());
    }
}

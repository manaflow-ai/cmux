//! A host (the responder) starts its link when the session is approved, so
//! it can hand its key and candidates to signaling; the viewer (the
//! initiator) starts its own only once signaling delivered that answer. The
//! time in between (the hub, the app, a measurement harness) is not time the
//! handshake could run: nobody has sent the host anything yet.
//!
//! Measured 2026-11-19 on a wired LAN (cmux20 host, cmux17 viewer, UDP RTT
//! 0.7 ms): 4 of 6 connects failed with "the secure handshake timed out
//! (heard 0)" on the viewer, the 2 others took 5-6 s through the harness's
//! signaling. The host's link had already given up when the viewer's first
//! packet arrived: it counted its 10 s from its own start, not from the
//! peer's first contact.

use cmux_rd_link::{
    Endpoint, HANDSHAKE_TIMEOUT_US, KeyPair, LinkError, RESPONDER_WAIT_US, Role, Route,
    SIGNALING_TIMEOUT_US,
};
use cmux_transport::PathKind;
use std::net::SocketAddr;

fn addr(s: &str) -> SocketAddr {
    s.parse().unwrap()
}

/// The host's wired address and its tailnet address (UDP between the two
/// Macs works on the LAN, not over the tailnet).
const HOST_LAN: &str = "172.20.21.250:50100";
const HOST_TAILNET: &str = "100.101.7.20:50100";
const VIEWER_LAN: &str = "172.20.21.17:61200";
const VIEWER_TAILNET: &str = "100.101.7.17:61200";

/// Only the LAN delivers. Returns the route the receiver sees the packet on.
fn deliver(to: Route) -> Option<Route> {
    match to {
        Route::Udp(a) if a == addr(HOST_LAN) => Some(Route::Udp(addr(VIEWER_LAN))),
        Route::Udp(a) if a == addr(VIEWER_LAN) => Some(Route::Udp(addr(HOST_LAN))),
        _ => None,
    }
}

/// Runs the host alone from 0 to `viewer_start_us` (its driver wakes at least
/// once a second), then both sides on a 1 ms tick until both are up or
/// `budget_us` after the viewer started. Returns when both came up (us after
/// the viewer started), or the first error either side hit.
fn connect_after(viewer_start_us: u64, budget_us: u64) -> Result<u64, (&'static str, LinkError)> {
    let (v, h) = (KeyPair::generate().unwrap(), KeyPair::generate().unwrap());
    let mut host = Endpoint::new(Role::Responder, b"late-peer", &h, v.public, 0).unwrap();
    let mut now = 0;
    while now < viewer_start_us {
        host.poll_transmit(now).map_err(|e| ("host, before the viewer started", e))?;
        now = (now + 100_000).min(viewer_start_us);
    }
    // Signaling delivered the host's answer: the viewer starts and dials
    // both of the host's candidates; its own reach the host a tick later.
    let mut viewer = Endpoint::new(Role::Initiator, b"late-peer", &v, h.public, now).unwrap();
    viewer.add_path(Route::Udp(addr(HOST_TAILNET)), PathKind::DirectWan, now);
    viewer.add_path(Route::Udp(addr(HOST_LAN)), PathKind::DirectLan, now);
    let start = now;
    let mut host_has_candidates = false;
    while now <= start + budget_us {
        if !host_has_candidates && now > start {
            host.add_path(Route::Udp(addr(VIEWER_TAILNET)), PathKind::DirectWan, now);
            host.add_path(Route::Udp(addr(VIEWER_LAN)), PathKind::DirectLan, now);
            host_has_candidates = true;
        }
        for t in viewer.poll_transmit(now).map_err(|e| ("viewer", e))? {
            if let Some(from) = deliver(t.route) {
                host.on_packet(from, &t.packet, now).map_err(|e| ("host", e))?;
            }
        }
        for t in host.poll_transmit(now).map_err(|e| ("host", e))? {
            if let Some(from) = deliver(t.route) {
                viewer.on_packet(from, &t.packet, now).map_err(|e| ("viewer", e))?;
            }
        }
        if viewer.link().is_established() && host.link().is_established() {
            return Ok(now - start);
        }
        now += 1_000;
    }
    Err(("both", LinkError::HandshakeTimeout))
}

/// Signaling took 10.5 s: the viewer's message 1 reaches a host that is
/// still waiting, and the LAN pair connects at once, the dead tailnet pair
/// next to it notwithstanding.
#[test]
fn a_viewer_that_starts_after_slow_signaling_connects_on_the_lan_at_once() {
    match connect_after(10_500_000, 2_000_000) {
        Ok(us) => {
            assert!(us <= 50_000, "connected {us} us after the viewer started, want <= 50 ms");
        }
        Err((side, e)) => panic!("{side}: {e} (the host gave up before the viewer could dial)"),
    }
}

/// Fast signaling, for comparison: connected within a few ticks.
#[test]
fn a_viewer_that_starts_at_once_connects_on_the_lan_at_once() {
    let us = connect_after(200_000, 2_000_000).expect("connects");
    assert!(us <= 50_000, "connected {us} us after the viewer started, want <= 50 ms");
}

/// Signaling that took 6 s (the measured successes) leaves the host 4 s, which
/// is enough on a LAN; the same is true at 9.9 s.
#[test]
fn a_viewer_that_starts_just_inside_the_old_window_connects() {
    for delay in [6_000_000, 9_900_000] {
        let us = connect_after(delay, 2_000_000).expect("connects");
        assert!(us <= 50_000, "delay {delay} us: connected {us} us after the viewer started");
    }
}

/// The first tick at which `host` fails, polling every 100 ms up to `until_us`
/// (`None`: still waiting then); `contact_at` adds a route to the viewer.
fn host_fails_at(contact_at: Option<u64>, until_us: u64) -> Option<u64> {
    let (v, h) = (KeyPair::generate().unwrap(), KeyPair::generate().unwrap());
    let mut host = Endpoint::new(Role::Responder, b"late-peer", &h, v.public, 0).unwrap();
    let mut now = 0;
    while now <= until_us {
        if contact_at == Some(now) {
            host.add_path(Route::Udp(addr(VIEWER_TAILNET)), PathKind::DirectWan, now);
        }
        match host.poll_transmit(now) {
            Ok(_) => {}
            Err(LinkError::HandshakeTimeout) => return Some(now),
            Err(e) => panic!("host: {e}"),
        }
        now += 100_000;
    }
    None
}

/// A host no viewer ever reaches still ends. In an endpoint the bound is signaling's (#48007):
/// with no route it is still waiting at the bare link's responder wait, and it ends with
/// `NoRoute` at `SIGNALING_TIMEOUT_US`.
#[test]
fn a_responder_nobody_contacts_gives_up_after_its_wait() {
    assert_eq!(host_fails_at(None, RESPONDER_WAIT_US + 1_000_000), None);
    let (v, h) = (KeyPair::generate().unwrap(), KeyPair::generate().unwrap());
    let mut host = Endpoint::new(Role::Responder, b"late-peer", &h, v.public, 0).unwrap();
    let mut now = 0;
    let failed = loop {
        match host.poll_transmit(now) {
            Ok(_) => {}
            Err(LinkError::NoRoute) => break now,
            Err(e) => panic!("host: {e}"),
        }
        assert!(now <= SIGNALING_TIMEOUT_US + 1_000_000, "the wait is bounded");
        now += 100_000;
    };
    assert!(failed > SIGNALING_TIMEOUT_US && failed <= SIGNALING_TIMEOUT_US + 100_000, "{failed}");
}

/// Once signaling gave the host a route (the viewer is dialing), the
/// handshake's own timeout runs from that contact: a peer that never gets
/// through still fails 10 s later, not at the wait's end.
#[test]
fn a_contacted_responder_times_out_from_the_contact() {
    let contact = 15_000_000;
    let failed = host_fails_at(Some(contact), RESPONDER_WAIT_US + 1_000_000).expect("times out");
    let after = failed - contact;
    assert!(after > HANDSHAKE_TIMEOUT_US && after <= HANDSHAKE_TIMEOUT_US + 100_000, "{after}");
}

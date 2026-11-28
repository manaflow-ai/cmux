//! A kept circuit with no stream is not pinged every 30 s: Freestyle resumes a paused VM on any
//! inbound packet, and that ping, from every fleet machine holding a kept circuit to it, woke a
//! paused machine about every 30 s (hq#38778: woken and repaused 188 times in 93 min).

use std::time::Duration;

use super::{IDLE_KEEPALIVE, KeepaliveTick, keepalive_tick};

const EVERY: Duration = Duration::from_secs(30);

fn s(secs: u64) -> Duration {
    Duration::from_secs(secs)
}

#[test]
fn a_busy_circuit_is_pinged_every_period_and_dropped_after_two_silent_ones() {
    assert_eq!(keepalive_tick(true, s(1), s(30), EVERY), KeepaliveTick::Ping);
    assert_eq!(keepalive_tick(true, s(59), s(30), EVERY), KeepaliveTick::Ping);
    assert_eq!(keepalive_tick(true, s(60), s(30), EVERY), KeepaliveTick::Dead);
}

#[test]
fn an_idle_circuit_sends_nothing_between_slow_pings() {
    // Every 30 s tick of a ten-minute idle stretch: a single ping, at nine minutes.
    let mut pinged = Duration::ZERO;
    let mut heard = Duration::ZERO;
    let mut pings = 0;
    for _ in 0..20 {
        pinged += EVERY;
        heard += EVERY;
        match keepalive_tick(false, heard, pinged, EVERY) {
            KeepaliveTick::Ping => {
                pings += 1;
                assert!(pinged <= IDLE_KEEPALIVE, "pinged before the relay's 10 min idle close");
                pinged = Duration::ZERO;
                heard = Duration::ZERO; // the PONG
            }
            KeepaliveTick::Wait => {}
            KeepaliveTick::Dead => panic!("a quiet idle circuit that answers its pings is live"),
        }
    }
    assert_eq!(pings, 1, "one ping in ten idle minutes, not twenty");
    assert!(IDLE_KEEPALIVE < Duration::from_secs(10 * 60));
}

#[test]
fn an_idle_circuit_whose_slow_ping_goes_unanswered_is_dropped() {
    // Pinged 30 s ago, nothing since the hello eight minutes back: not yet two periods.
    assert_eq!(keepalive_tick(false, s(510), s(30), EVERY), KeepaliveTick::Wait);
    // Two periods after the unanswered ping.
    assert_eq!(keepalive_tick(false, s(540), s(60), EVERY), KeepaliveTick::Dead);
    // Answered (heard after the ping): live, however long ago the circuit last carried a stream.
    assert_eq!(keepalive_tick(false, s(50), s(60), EVERY), KeepaliveTick::Wait);
}

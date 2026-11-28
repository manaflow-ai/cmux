use super::*;
use cmux_transport::{Medium, PathId, PathKind};

fn alive() -> PathView {
    PathView {
        id: PathId(0),
        kind: PathKind::DirectLan,
        medium: Medium::Lan,
        state: PathState::Alive,
        rtt_us: Some(10_000),
    }
}

/// One step of the current, chosen path: the ping it sent, if any.
fn step(watch: &mut PathWatch, id: &mut u64, now: Instant) -> Option<u64> {
    watch.step(&ProbeConfig::default(), &alive(), (true, true), id, now).ping
}

/// The first ping at `start`, answered at once.
fn proven(start: Instant) -> (PathWatch, u64) {
    let mut watch = PathWatch::default();
    let mut id = 0;
    let ping = step(&mut watch, &mut id, start).expect("the first ping");
    watch.answer(&ProbeConfig::default(), ping, start).expect("answered");
    (watch, id)
}

/// Traffic on the current path does not stand in for its routine 5 s
/// ping: a direct route that only half works (handshakes come back on
/// the relay) is still checked on schedule.
#[test]
fn traffic_on_the_current_path_does_not_skip_its_routine_ping() {
    let start = Instant::now();
    let (mut watch, mut id) = proven(start);
    watch.heard();
    assert!(step(&mut watch, &mut id, start + Duration::from_secs(5)).is_some());
}

#[test]
fn a_silent_current_path_is_pinged_on_schedule() {
    let start = Instant::now();
    let (mut watch, mut id) = proven(start);
    assert!(step(&mut watch, &mut id, start + Duration::from_secs(5)).is_some());
}

#[test]
fn the_air_gap_holds_routine_pings_but_not_one_asked_for() {
    let start = Instant::now();
    let secs = |n| start + Duration::from_secs(n);
    let (mut watch, mut id) = proven(start);
    watch.hold_routine(Some(secs(20)));
    assert_eq!(step(&mut watch, &mut id, secs(5)), None, "held to the floor");
    watch.probe_now(secs(6));
    let urgent = step(&mut watch, &mut id, secs(6)).expect("asked for: goes now");
    watch.answer(&ProbeConfig::default(), urgent, secs(6));
    assert_eq!(step(&mut watch, &mut id, secs(11)), None);
    assert!(step(&mut watch, &mut id, secs(20)).is_some(), "the floor passed");
}

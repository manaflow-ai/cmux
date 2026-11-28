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

#[test]
fn traffic_on_the_current_path_stands_in_for_its_ping_up_to_the_refresh() {
    let start = Instant::now();
    let secs = |n| start + Duration::from_secs(n);
    let (mut watch, mut id) = proven(start);
    watch.heard();
    for at in [5, 10, 15, 20, 25] {
        assert_eq!(step(&mut watch, &mut id, secs(at)), None, "skipped at {at} s");
    }
    assert!(step(&mut watch, &mut id, secs(30)).is_some(), "the round trip refresh");
}

#[test]
fn the_answer_to_its_own_ping_does_not_stand_in_for_the_next() {
    let start = Instant::now();
    let mut watch = PathWatch::default();
    let mut id = 0;
    let ping = step(&mut watch, &mut id, start).expect("the first ping");
    watch.heard(); // the pong's datagram is heard before it is matched
    watch.answer(&ProbeConfig::default(), ping, start).expect("answered");
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

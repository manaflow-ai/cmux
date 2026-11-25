use super::*;

// Two acts of a host, and times that are exact in binary: a flight of
// 0.25 s that starts at 8 s is half way at 8.125 s.
const INSERT: u32 = 1;
const CLOSE: u32 = 2;
const LENGTH: TweenParameters = TweenParameters::new(0.25, TweenCurve::EaseOutQuad);

fn flying_since_8(act: u32) -> MotionFlight {
    let mut flight = MotionFlight::new();
    assert_eq!(flight.change(act, true, LENGTH, 8.), FlightStep::Start);
    flight
}

#[test]
fn a_change_at_rest_starts_one_flight_on_the_curve() {
    let mut flight = flying_since_8(INSERT);
    assert_eq!(flight.progress(8.), 0.);
    assert_eq!(flight.progress(8.125), 0.75, "ease-out quad at half time");
    assert_eq!(flight.frame(8.125), FlightPhase::Flying);
    assert_eq!(flight.progress(8.25), 1.);
    assert_eq!(flight.frame(8.25), FlightPhase::Still, "the flight did not end at its length");
    assert_eq!(flight.progress(9.), 1.);
    // The flight runs on the curve of its motion, not on the curve of a surface at rest.
    let mut flight = MotionFlight::new();
    let even = TweenParameters::new(0.25, TweenCurve::Linear);
    assert_eq!(flight.change(INSERT, true, even, 8.), FlightStep::Start);
    assert_eq!(flight.progress(8.125), 0.5, "linear at half time");
}

#[test]
fn the_same_act_in_a_flight_applies_at_once_and_ends_the_flight() {
    let mut flight = flying_since_8(INSERT);
    assert_eq!(flight.change(INSERT, true, LENGTH, 8.0625), FlightStep::AtOnce);
    assert_eq!(flight.progress(8.0625), 1., "a layer still moves after the end at once");
    assert_eq!(flight.frame(8.0625), FlightPhase::Quiet);
}

#[test]
fn another_act_in_a_flight_retargets_from_the_place_of_now() {
    let mut flight = flying_since_8(INSERT);
    assert_eq!(flight.change(CLOSE, true, LENGTH, 8.125), FlightStep::Retarget { from: 0.75 });
    assert_eq!(flight.progress(8.125), 0., "the retarget did not start again");
    assert_eq!(flight.frame(8.3125), FlightPhase::Flying, "the whole length did not run again");
    assert_eq!(flight.frame(8.375), FlightPhase::Still);
    // The flight took the second act: that act now ends it, the first one retargets it.
    let mut flight = flying_since_8(INSERT);
    assert_eq!(flight.change(CLOSE, true, LENGTH, 8.125), FlightStep::Retarget { from: 0.75 });
    assert_eq!(flight.change(INSERT, true, LENGTH, 8.25), FlightStep::Retarget { from: 0.75 });
    assert_eq!(flight.change(INSERT, true, LENGTH, 8.3125), FlightStep::AtOnce);
}

#[test]
fn a_change_by_no_act_retargets_and_never_ends_a_flight() {
    let mut flight = flying_since_8(INSERT);
    for now in [8.0625, 8.125, 8.1875] {
        let step = flight.change(MotionFlight::NO_ACT, true, LENGTH, now);
        assert!(matches!(step, FlightStep::Retarget { .. }), "at {now}: {step:?}");
        assert_eq!(flight.frame(now), FlightPhase::Flying, "at {now}");
    }
    // A flight that no act started is also only retargeted by no act.
    let mut flight = flying_since_8(MotionFlight::NO_ACT);
    let step = flight.change(MotionFlight::NO_ACT, true, LENGTH, 8.125);
    assert_eq!(step, FlightStep::Retarget { from: 0.75 });
    // The flight keeps its act through a change by no act: the act's next change ends it.
    let mut flight = flying_since_8(INSERT);
    let step = flight.change(MotionFlight::NO_ACT, true, LENGTH, 8.125);
    assert_eq!(step, FlightStep::Retarget { from: 0.75 });
    assert_eq!(flight.change(INSERT, true, LENGTH, 8.1875), FlightStep::AtOnce);
}

/// A held key (a period below the length): motion for the first key, then no motion at
/// all until one length passed with no key.
#[test]
fn the_quiet_time_applies_each_next_same_act_at_once_until_one_length_with_none() {
    let mut flight = flying_since_8(INSERT);
    for key in 1..=8 {
        let now = 8. + 0.1875 * f64::from(key);
        assert_eq!(flight.change(INSERT, true, LENGTH, now), FlightStep::AtOnce, "key {key}");
        assert_eq!(flight.frame(now), FlightPhase::Quiet, "key {key}");
    }
    // The last key was at 9.5: the quiet time ends at 9.75.
    assert_eq!(flight.frame(9.6875), FlightPhase::Quiet);
    assert_eq!(flight.frame(9.75), FlightPhase::Still);
    assert_eq!(flight.change(INSERT, true, LENGTH, 9.75), FlightStep::Start);
}

#[test]
fn another_act_in_the_quiet_time_starts_a_flight_that_the_quiet_act_ends() {
    let mut flight = flying_since_8(INSERT);
    assert_eq!(flight.change(INSERT, true, LENGTH, 8.0625), FlightStep::AtOnce);
    assert_eq!(flight.change(CLOSE, true, LENGTH, 8.125), FlightStep::Start);
    assert_eq!(flight.frame(8.125), FlightPhase::Flying);
    assert_eq!(flight.change(INSERT, true, LENGTH, 8.1875), FlightStep::AtOnce);
    assert_eq!(flight.progress(8.1875), 1.);
    assert_eq!(flight.frame(8.1875), FlightPhase::Quiet);
}

#[test]
fn a_change_with_no_moved_target_keeps_the_flight_and_the_quiet_time() {
    let mut flight = MotionFlight::new();
    assert_eq!(flight.change(INSERT, false, LENGTH, 8.), FlightStep::Keep);
    assert_eq!(flight.frame(8.), FlightPhase::Still);
    let mut flight = flying_since_8(INSERT);
    let before = flight;
    assert_eq!(flight.change(INSERT, false, LENGTH, 8.125), FlightStep::Keep);
    assert_eq!(flight.change(CLOSE, false, LENGTH, 8.125), FlightStep::Keep);
    assert_eq!(flight, before);
    assert_eq!(flight.progress(8.125), 0.75);
    // In a quiet time too.
    assert_eq!(flight.change(INSERT, true, LENGTH, 8.125), FlightStep::AtOnce);
    let before = flight;
    assert_eq!(flight.change(INSERT, false, LENGTH, 8.1875), FlightStep::Keep);
    assert_eq!(flight.change(CLOSE, false, LENGTH, 8.1875), FlightStep::Keep);
    assert_eq!(flight, before);
    assert_eq!(flight.frame(8.1875), FlightPhase::Quiet);
}

#[test]
fn a_duration_that_is_not_positive_applies_at_once_with_no_quiet_time() {
    for duration in [0., -1., f64::NAN, f64::INFINITY] {
        let mut flight = MotionFlight::new();
        let off = TweenParameters::new(duration, TweenCurve::EaseOutQuad);
        let step = flight.change(INSERT, true, off, 8.);
        assert_eq!(step, FlightStep::AtOnce, "duration {duration}");
        assert_eq!(flight.frame(8.), FlightPhase::Still, "duration {duration}");
        assert_eq!(flight.change(INSERT, true, LENGTH, 8.0625), FlightStep::Start);
        // In a flight it ends the flight, by any act.
        assert_eq!(flight.change(CLOSE, true, off, 8.125), FlightStep::AtOnce);
        assert_eq!(flight.progress(8.125), 1., "duration {duration}");
        assert_eq!(flight.frame(8.125), FlightPhase::Still, "duration {duration}");
    }
}

#[test]
fn a_flight_that_reached_its_length_is_over_for_the_next_same_act() {
    // No frame call between: the change itself sees that the flight is over.
    let mut flight = flying_since_8(INSERT);
    assert_eq!(flight.change(INSERT, true, LENGTH, 8.25), FlightStep::Start);
    // Fifteen 1/60 s frames from 0 sum to just under 0.25 s and must end the flight.
    let mut flight = MotionFlight::new();
    assert_eq!(flight.change(CLOSE, true, LENGTH, 0.), FlightStep::Start);
    let mut now = 0.;
    for _ in 0..15 {
        now += 1. / 60.;
    }
    assert!(now < 0.25, "the sum is not under the length: {now}");
    assert_eq!(flight.frame(now), FlightPhase::Still, "now = {now}");
}

/// The slack is 1e-9 s: a time that is less than the slack under an end is at the end, and
/// a time that is more than the slack under it is not.
#[test]
fn the_end_slack_ends_a_flight_and_a_quiet_time_just_under_their_length() {
    let mut flight = MotionFlight::new();
    assert_eq!(flight.change(INSERT, true, LENGTH, 0.), FlightStep::Start);
    let (mut inside, mut outside) = (flight, flight);
    assert_eq!(outside.frame(0.25 - 2e-9), FlightPhase::Flying);
    assert_eq!(inside.progress(0.25 - 0.5e-9), 1.);
    assert_eq!(inside.frame(0.25 - 0.5e-9), FlightPhase::Still);
    // The quiet time of a second key at 0.0625 ends at 0.3125.
    assert_eq!(flight.change(INSERT, true, LENGTH, 0.0625), FlightStep::AtOnce);
    let (mut inside, mut outside) = (flight, flight);
    assert_eq!(outside.frame(0.3125 - 2e-9), FlightPhase::Quiet);
    assert_eq!(inside.frame(0.3125 - 0.5e-9), FlightPhase::Still);
    let (mut inside, mut outside) = (flight, flight);
    assert_eq!(outside.change(INSERT, true, LENGTH, 0.3125 - 2e-9), FlightStep::AtOnce);
    assert_eq!(inside.change(INSERT, true, LENGTH, 0.3125 - 0.5e-9), FlightStep::Start);
}

/// A change with no motion (its kind is off) by another act or by no act, in the quiet
/// time of a held key: the held key's next change still applies at once.
#[test]
fn a_change_with_no_motion_leaves_a_quiet_time_in_place_as_it_is() {
    let off = TweenParameters::new(0., TweenCurve::EaseOutQuad);
    for other in [CLOSE, MotionFlight::NO_ACT] {
        // The quiet time of INSERT ends at 8.3125.
        let mut flight = flying_since_8(INSERT);
        assert_eq!(flight.change(INSERT, true, LENGTH, 8.0625), FlightStep::AtOnce);
        assert_eq!(flight.change(other, true, off, 8.125), FlightStep::AtOnce, "act {other}");
        let (mut held, mut left) = (flight, flight);
        assert_eq!(held.change(INSERT, true, LENGTH, 8.1875), FlightStep::AtOnce, "act {other}");
        // It is not longer either: it ends where it ended before.
        assert_eq!(left.frame(8.25), FlightPhase::Quiet, "act {other}");
        assert_eq!(left.frame(8.3125), FlightPhase::Still, "act {other}");
    }
}

#[test]
fn a_clock_that_is_not_a_number_moves_nothing() {
    let mut flight = flying_since_8(INSERT);
    assert_eq!(flight.change(CLOSE, true, LENGTH, f64::NAN), FlightStep::AtOnce);
    assert_eq!(flight.progress(f64::NAN), 1.);
    assert_eq!(flight.frame(f64::NAN), FlightPhase::Still);
    // A frame at such a clock ends the flight in the air.
    let mut flight = flying_since_8(INSERT);
    assert_eq!(flight.frame(f64::NAN), FlightPhase::Still);
    assert_eq!(flight.frame(8.125), FlightPhase::Still);
    // A clock that goes back does not pass the start.
    let flight = flying_since_8(INSERT);
    assert_eq!(flight.progress(7.), 0.);
}

#[test]
fn a_clock_that_is_not_finite_moves_nothing() {
    for now in [f64::INFINITY, f64::NEG_INFINITY] {
        // At rest: no flight starts, so no flight is left in the air with no end.
        let mut flight = MotionFlight::new();
        assert_eq!(flight.change(INSERT, true, LENGTH, now), FlightStep::AtOnce, "clock {now}");
        assert_eq!(flight.frame(8.), FlightPhase::Still, "clock {now}");
        assert_eq!(flight.progress(8.), 1., "clock {now}");
        // In a flight: the change ends it.
        let mut flight = flying_since_8(INSERT);
        assert_eq!(flight.change(CLOSE, true, LENGTH, now), FlightStep::AtOnce, "clock {now}");
        assert_eq!(flight.frame(8.125), FlightPhase::Still, "clock {now}");
        // A read and a frame at such a clock: nothing is in the air.
        let mut flight = flying_since_8(INSERT);
        assert_eq!(flight.progress(now), 1., "clock {now}");
        assert_eq!(flight.frame(now), FlightPhase::Still, "clock {now}");
        assert_eq!(flight.frame(8.125), FlightPhase::Still, "clock {now}");
    }
}

/// The fields are public (the C calls copy them), so a host can give a length that
/// `change` never writes.
#[test]
fn a_length_in_the_state_that_is_not_finite_flies_nothing() {
    for duration in [f64::INFINITY, f64::NAN] {
        let mut flight = MotionFlight { duration, ..flying_since_8(INSERT) };
        assert_eq!(flight.progress(8.125), 1., "length {duration}");
        assert_eq!(flight.frame(8.125), FlightPhase::Still, "length {duration}");
    }
}

//! One motion in flight for a surface whose layers all move on one clock
//! (the tab strip): the decision what a change of targets does, and the one
//! progress value every moving layer reads.
//!
//! A surface holds at most one flight; nothing is queued. A change of
//! targets is one of four steps (`FlightStep`):
//!
//! - at rest it starts a flight;
//! - in a flight, a change by another act or by no act (a drag, a resize, a
//!   selection, an echo of the daemon) retargets it: the whole duration
//!   again from the place of now, with no speed carried, like `TweenValue`;
//! - in a flight, a change by the act that the flight has (a second key of
//!   a held key) applies at once and ends the flight, and so does each next
//!   change by that act until one duration passed with none (the quiet
//!   time): a held key shows no motion, not motion, jump, motion, jump;
//! - a duration that is not positive (speed off, Reduce Motion, a kind
//!   switched off) applies at once: it ends the flight in the air, starts no
//!   quiet time, and leaves a quiet time in place as it is, so a held key
//!   stays without motion when a change of a kind that is off comes between
//!   two of its repeats.
//!
//! Pure and synchronous like the tweens: no clock read (the host gives
//! `now`, seconds on any monotonic clock), no allocation, no panic on any
//! input.

use crate::{TweenCurve, TweenParameters};

/// 1e-9 s: frames of 1/60 s sum to just under a length and must end the
/// flight, as in `TweenValue::step`.
const END_SLACK: f64 = 1e-9;

/// What one change of targets does to the surface.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum FlightStep {
    /// No target changed: the flight and the quiet time stay as they are.
    Keep,
    /// A flight starts from rest: every moved layer animates from its old
    /// place over the duration.
    Start,
    /// The flight in the air starts again for the whole duration from the
    /// place of now. `from` is its progress at `now`, before this change: a
    /// layer's offset of now is its old offset times `1 - from`.
    Retarget { from: f64 },
    /// The change applies with no motion and every layer is at rest in this
    /// frame: the flight in the air, if any, ends now.
    AtOnce,
}

/// Where a surface is after a frame.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum FlightPhase {
    /// No flight and no quiet time: the surface is still.
    Still = 0,
    /// No flight, and changes by the quiet act still apply at once.
    Quiet = 1,
    /// A flight is in the air: the host draws another frame.
    Flying = 2,
}

/// The one flight of a surface and its quiet time. All times are seconds on
/// the host's clock.
#[derive(Clone, Copy, Debug, PartialEq)]
#[repr(C)]
pub struct MotionFlight {
    /// When the flight in the air started or was last retargeted.
    pub start: f64,
    /// The flight's length; 0 after a `frame` or a `change` saw that no
    /// flight is in the air.
    pub duration: f64,
    /// When the quiet time ends; changes by `quiet_act` before it apply at once.
    pub quiet_until: f64,
    /// The act of the flight in the air (`NO_ACT` for none).
    pub act: u32,
    /// The act of the quiet time (`NO_ACT` when there is none).
    pub quiet_act: u32,
    /// The curve of the flight in the air.
    pub curve: TweenCurve,
}

impl Default for MotionFlight {
    fn default() -> Self {
        Self::new()
    }
}

impl MotionFlight {
    /// A change that no act made: a drag, a resize, a selection, an echo.
    /// It retargets a flight and never ends one.
    pub const NO_ACT: u32 = 0;

    /// A surface at rest.
    pub const fn new() -> Self {
        Self {
            start: 0.,
            duration: 0.,
            quiet_until: 0.,
            act: Self::NO_ACT,
            quiet_act: Self::NO_ACT,
            curve: TweenCurve::EaseOutQuad,
        }
    }

    /// A change of the surface's targets at `now`. `act` names what made it
    /// (the host's own ids; `NO_ACT` for none), `moved` is false when no
    /// target changed, and `motion` is the motion's length under the policy
    /// and its curve. The host does what the returned step says.
    pub fn change(
        &mut self,
        act: u32,
        moved: bool,
        motion: TweenParameters,
        now: f64,
    ) -> FlightStep {
        if !moved {
            return FlightStep::Keep;
        }
        let flying = self.is_flying(now);
        if !flying {
            self.land();
        }
        let animates = motion.duration.is_finite() && motion.duration > 0.;
        if !animates || !now.is_finite() {
            // No motion (speed off, Reduce Motion, a kind off) or no clock: no new quiet time.
            // A quiet time in place stays: its act is still held.
            self.land();
            return FlightStep::AtOnce;
        }
        let quiet = act == self.quiet_act && now < self.quiet_until - END_SLACK;
        if act != Self::NO_ACT && (quiet || (flying && act == self.act)) {
            self.land();
            self.quiet_act = act;
            self.quiet_until = now + motion.duration;
            return FlightStep::AtOnce;
        }
        let from = self.progress(now);
        self.start = now;
        self.duration = motion.duration;
        self.curve = motion.curve;
        if flying {
            // A change by no act leaves the flight its act: that act's next change still ends it.
            if act != Self::NO_ACT {
                self.act = act;
            }
            FlightStep::Retarget { from }
        } else {
            self.act = act;
            FlightStep::Start
        }
    }

    /// The progress of the flight at `now` on its curve, 0 at its start to
    /// 1 at its end; 1 when no flight is in the air.
    pub fn progress(&self, now: f64) -> f64 {
        if self.is_flying(now) {
            self.curve.progress_f64((now - self.start) / self.duration)
        } else {
            1.
        }
    }

    /// One frame at `now`: ends a flight that reached its length and a quiet
    /// time that passed, and says where the surface is.
    pub fn frame(&mut self, now: f64) -> FlightPhase {
        if self.is_flying(now) {
            return FlightPhase::Flying;
        }
        self.land();
        if self.quiet_act != Self::NO_ACT && now < self.quiet_until - END_SLACK {
            return FlightPhase::Quiet;
        }
        self.quiet_act = Self::NO_ACT;
        FlightPhase::Still
    }

    /// True while the flight has not reached its length at `now`. A clock
    /// or a length that is not finite flies nothing.
    fn is_flying(&self, now: f64) -> bool {
        now.is_finite()
            && self.duration.is_finite()
            && self.duration > 0.
            && now < self.start + self.duration - END_SLACK
    }

    fn land(&mut self) {
        self.duration = 0.;
        self.act = Self::NO_ACT;
    }
}

#[cfg(test)]
mod tests {
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
            assert_eq!(
                held.change(INSERT, true, LENGTH, 8.1875),
                FlightStep::AtOnce,
                "act {other}"
            );
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
}

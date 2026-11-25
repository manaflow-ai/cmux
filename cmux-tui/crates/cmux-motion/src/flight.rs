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
#[path = "flight_tests.rs"]
mod tests;

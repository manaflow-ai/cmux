//! `appearance.gooeyTabs`: the levels and their tunings (gooey-tabs.md
//! "Levels", "Knobs"). `off` is the default and draws nothing new; `subtle`
//! is alive but never loud; `full` is springy and wobbly.

use crate::SpringParameters;

/// `appearance.gooeyTabs`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum GooLevel {
    /// Today's tabs: critically damped token tweens, no goo. The default.
    #[default]
    Off = 0,
    /// Flush-goo fillets and goo springs that barely overshoot.
    Subtle = 1,
    /// Wider fillets, under-damped springs, stretch, lean and long necks.
    Full = 2,
}

impl GooLevel {
    /// The level for a raw value; an unknown one is `Off`.
    pub const fn from_raw(raw: u32) -> Self {
        match raw {
            1 => Self::Subtle,
            2 => Self::Full,
            _ => Self::Off,
        }
    }
}

/// A goo spring: SwiftUI terms (`response` seconds, `damping_fraction`; under
/// 1 overshoots). Not a motion token.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GooSpring {
    pub response: f64,
    pub damping_fraction: f64,
}

impl GooSpring {
    pub const fn new(response: f64, damping_fraction: f64) -> Self {
        Self { response, damping_fraction }
    }

    /// The spring a broken tuning falls back to: critically damped, 0.3 s.
    pub const FALLBACK: GooSpring = GooSpring::new(0.3, 1.);

    /// This spring with every field finite and in range: response 0.02 to
    /// 10 s, damping fraction 0.05 to 4 (an undamped spring never rests).
    pub fn sanitized(self) -> Self {
        let response = if self.response.is_finite() && self.response > 0. {
            self.response.clamp(0.02, 10.)
        } else {
            Self::FALLBACK.response
        };
        let damping_fraction = if self.damping_fraction.is_finite() && self.damping_fraction > 0. {
            self.damping_fraction.clamp(0.05, 4.)
        } else {
            Self::FALLBACK.damping_fraction
        };
        Self { response, damping_fraction }
    }

    /// The sanitized spring as `SpringParameters` (`SpringValue::solve`'s).
    pub fn params(self) -> SpringParameters {
        let s = self.sanitized();
        SpringParameters::new(s.response, s.damping_fraction)
    }
}

/// Every goo knob of one level (gooey-tabs.md "Knobs"). Lengths are points.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GooTuning {
    /// The blob's edges on a select.
    pub select: GooSpring,
    /// A new tab's width from 0, and the blob following it.
    pub open: GooSpring,
    /// A closing tab's pinch, and the blob handed to the next selection.
    pub close: GooSpring,
    /// Neighbours parting around a dragged tab.
    pub reorder: GooSpring,
    /// The neck retracting into the slot when a drag breaks it.
    pub snap: GooSpring,
    /// The neck regrowing and the slot swelling when a drag comes back.
    pub absorb: GooSpring,
    /// The settle wobble; its response is also the stretch and lean time
    /// constant (`response / 2π` seconds of travel).
    pub wobble: GooSpring,
    /// How far the body stretches along its travel, as a share of its width
    /// (0 none).
    pub stretch: f64,
    /// How far the top corners lean toward the travel, as a share of the
    /// body's height (0 none).
    pub lean: f64,
    /// The fillets' radius over `appearance.cornerFlush`'s (`feet_radius`
    /// in a `Blob` is already scaled: the host multiplies).
    pub feet_scale: f64,
    /// The goo threshold of a neighbour's smooth union (pt; 0 none).
    pub k: f64,
    /// A dragged tab farther than this from its slot snaps the neck (pt).
    pub break_distance: f64,
    /// A detached tab closer than this is absorbed again (pt, at most
    /// `break_distance`, so the boundary never flickers).
    pub capture_distance: f64,
    /// The settle wobble's top edge travel at full speed (pt).
    pub wobble_amplitude: f64,
}

impl Default for GooTuning {
    fn default() -> Self {
        Self::for_level(GooLevel::Off)
    }
}

impl GooTuning {
    /// The defaults of `level`, which the Debug Settings tuning page starts
    /// from.
    pub const fn for_level(level: GooLevel) -> Self {
        match level {
            // Off: the token feel (critically damped) and no deformation.
            GooLevel::Off => Self {
                select: GooSpring::new(0.3, 1.),
                open: GooSpring::new(0.3, 1.),
                close: GooSpring::new(0.25, 1.),
                reorder: GooSpring::new(0.3, 1.),
                snap: GooSpring::new(0.25, 1.),
                absorb: GooSpring::new(0.3, 1.),
                wobble: GooSpring::new(0.3, 1.),
                stretch: 0.,
                lean: 0.,
                feet_scale: 1.,
                k: 0.,
                break_distance: 0.,
                capture_distance: 0.,
                wobble_amplitude: 0.,
            },
            // Subtle: damping 0.86 to 0.9, under 1% overshoot (a 200 pt
            // select passes its target by under a point), a short neck
            // that lets go early, about 1 pt of settle.
            GooLevel::Subtle => Self {
                select: GooSpring::new(0.34, 0.88),
                open: GooSpring::new(0.32, 0.9),
                close: GooSpring::new(0.28, 0.9),
                reorder: GooSpring::new(0.3, 0.88),
                snap: GooSpring::new(0.24, 0.86),
                absorb: GooSpring::new(0.3, 0.86),
                wobble: GooSpring::new(0.34, 0.86),
                stretch: 0.12,
                lean: 0.04,
                feet_scale: 1.,
                k: 6.,
                break_distance: 18.,
                capture_distance: 10.,
                wobble_amplitude: 1.,
            },
            // Full: damping 0.55 to 0.7 (a select overshoots by about a
            // tenth of its travel and rings twice), a long neck that
            // stretches to a thread and snaps, 2 to 4 pt of wobble.
            GooLevel::Full => Self {
                select: GooSpring::new(0.44, 0.6),
                open: GooSpring::new(0.42, 0.65),
                close: GooSpring::new(0.36, 0.7),
                reorder: GooSpring::new(0.38, 0.62),
                snap: GooSpring::new(0.3, 0.55),
                absorb: GooSpring::new(0.46, 0.58),
                wobble: GooSpring::new(0.42, 0.55),
                stretch: 0.45,
                lean: 0.3,
                feet_scale: 1.4,
                k: 14.,
                break_distance: 56.,
                capture_distance: 28.,
                wobble_amplitude: 3.,
            },
        }
    }

    /// This tuning with every field finite and in range: springs
    /// sanitized, shares 0 to 1, lengths non-negative and capped, and
    /// `capture_distance` at most `break_distance`.
    pub fn sanitized(&self) -> Self {
        let share = |v: f64| if v.is_finite() { v.clamp(0., 1.) } else { 0. };
        let len = |v: f64, max: f64| if v.is_finite() { v.clamp(0., max) } else { 0. };
        let break_distance = len(self.break_distance, 2000.);
        Self {
            select: self.select.sanitized(),
            open: self.open.sanitized(),
            close: self.close.sanitized(),
            reorder: self.reorder.sanitized(),
            snap: self.snap.sanitized(),
            absorb: self.absorb.sanitized(),
            wobble: self.wobble.sanitized(),
            stretch: share(self.stretch),
            lean: share(self.lean),
            feet_scale: if self.feet_scale.is_finite() {
                self.feet_scale.clamp(0., 4.)
            } else {
                1.
            },
            k: len(self.k, 500.),
            break_distance,
            capture_distance: len(self.capture_distance, 2000.).min(break_distance),
            wobble_amplitude: len(self.wobble_amplitude, 40.),
        }
    }

    /// The spring an event's edges use.
    pub fn spring_for(&self, event: crate::goo::GooEvent) -> GooSpring {
        use crate::goo::GooEvent as E;
        match event {
            E::Select => self.select,
            E::Open => self.open,
            E::Close | E::CloseLast => self.close,
            E::Reorder => self.reorder,
            E::Snap => self.snap,
            E::Absorb => self.absorb,
        }
    }
}

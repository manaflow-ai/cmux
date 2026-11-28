//! The spring rules of `SpringParameters` and `SpringValue` (SpringParameters.swift) the
//! Swift side still computed itself: velocity admission, the settle time a `CASpringAnimation`
//! runs for, and the visible end. Every step is cmux-motion's `advance_spring`, the same
//! closed form the app's `cmux_motion_step` runs, so these match the Swift values exactly.

use super::tokens::MotionSpring;
use cmux_motion::{SpringParameters, advance_spring};
use serde::{Deserialize, Serialize};

/// A spring in Swift's terms (`response`, `dampingFraction`).
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Spring {
    pub response: f64,
    pub damping_fraction: f64,
}

impl From<SpringParameters> for Spring {
    fn from(p: SpringParameters) -> Self {
        Self { response: p.response, damping_fraction: p.damping_fraction }
    }
}

impl From<Spring> for SpringParameters {
    fn from(s: Spring) -> Self {
        SpringParameters::new(s.response, s.damping_fraction)
    }
}

/// `admitted(velocity:distance:)`: a carried velocity kept only toward the target and no faster
/// than the spring would reach on its own (`omega * |distance|`), so a retarget never overshoots.
pub fn admitted(p: SpringParameters, velocity: f64, distance: f64) -> f64 {
    if velocity == 0. {
        return 0.;
    }
    let limit = p.omega() * distance.abs();
    if distance > 0. {
        return swift_min(swift_max(velocity, 0.), limit);
    }
    if distance < 0. {
        return swift_max(swift_min(velocity, 0.), -limit);
    }
    0.
}

/// Swift's `min(x, y)`: `y < x ? y : x` (a NaN limit stays NaN, as Swift's does).
fn swift_min(x: f64, y: f64) -> f64 {
    if y < x { y } else { x }
}

/// Swift's `max(x, y)`: `y >= x ? y : x`.
fn swift_max(x: f64, y: f64) -> f64 {
    if y >= x { y } else { x }
}

/// `settlingTime(within:)`: seconds until a unit step stays within `fraction` of its target
/// (a `CASpringAnimation`'s duration uses 0.002).
pub fn settling_time(p: SpringParameters, fraction: f64) -> f64 {
    let zeta = p.damping_fraction.clamp(0.05, 1.);
    if zeta >= 0.999 {
        let mut x = 1.0_f64;
        for _ in 0..32 {
            x = ((1. + x) / fraction).ln();
        }
        return x / p.omega();
    }
    -(fraction * (1. - zeta * zeta).sqrt()).ln() / (zeta * p.omega())
}

/// `perceivedDuration`: the last time a unit step from rest is more than 0.5% from its target,
/// stepped at 480 Hz with admission, as `SpringValue.step` does (at most 3 s).
pub fn perceived_duration(p: SpringParameters) -> f64 {
    let (mut value, mut velocity, target) = (0.0_f64, 0.0_f64, 1.0_f64);
    let step = 1.0 / 480.0;
    let mut elapsed = 0.0;
    let mut last_outside = 0.0;
    while elapsed < 3. {
        velocity = admitted(p, velocity, target - value);
        advance_spring(&mut value, &mut velocity, target, step, p, 0.);
        elapsed += step;
        if (1. - value).abs() > 0.005 {
            last_outside = elapsed;
        }
        if elapsed > last_outside + 0.25 {
            break;
        }
    }
    last_outside
}

/// `SpringValue.solve`: displacement and velocity after `time` seconds, in 0.1 s closed-form
/// steps; a non-finite or non-positive response or damping takes the `move` spring's, and a
/// time past `min(10, 20 * response)` (or not finite) is settled.
pub fn solve(displacement: f64, velocity: f64, time: f64, p: SpringParameters) -> (f64, f64) {
    let fallback = MotionSpring::Move.base();
    let response =
        if p.response.is_finite() && p.response > 0. { p.response } else { fallback.response };
    let damping = if p.damping_fraction.is_finite() && p.damping_fraction > 0. {
        p.damping_fraction
    } else {
        fallback.damping_fraction
    };
    if !(time.is_finite() && time < (20. * response).min(10.)) {
        return (0., 0.);
    }
    let spring = SpringParameters::new(response, damping);
    let (mut value, mut v) = (displacement, velocity);
    let mut left = time.max(0.);
    while left > 0. {
        let dt = left.min(0.1);
        advance_spring(&mut value, &mut v, 0., dt, spring, 0.);
        left -= dt;
    }
    (value, v)
}

/// One `SpringValue` step (`step`, `advance`, `advanceAdmitted`): the state after `dt`, and
/// whether it still moves.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SpringState {
    pub value: f64,
    #[serde(default)]
    pub velocity: f64,
    pub target: f64,
}

/// `SpringValue.advance` (`admits` true) or `advanceAdmitted` (false).
pub fn advance(
    state: &mut SpringState,
    dt: f64,
    p: SpringParameters,
    epsilon: f64,
    admits: bool,
) -> bool {
    if admits {
        state.velocity = admitted(p, state.velocity, state.target - state.value);
    }
    advance_spring(&mut state.value, &mut state.velocity, state.target, dt, p, epsilon)
}

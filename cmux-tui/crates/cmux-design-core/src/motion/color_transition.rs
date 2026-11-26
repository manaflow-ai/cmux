//! `ColorTransition` (ColorTransition.swift): how a theme color moves to its next value, its
//! Reduce Motion resolution, sampled progress, the mix, and the CSS a web page gets. The curves,
//! the spring arrival and the mix are cmux-motion's.

use super::spring::Spring;
use cmux_motion::{ColorSpace, SpringParameters, TweenCurve};
use serde::{Deserialize, Serialize};

/// `MotionTunables.colorTransitionDefaultDuration`.
pub const DEFAULT_DURATION: f64 = 0.2;
/// `reducedMotionCap`.
pub const REDUCED_MOTION_CAP: f64 = 0.1;
/// `keyframes`.
pub const KEYFRAMES: usize = 24;

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum Curve {
    EaseOut,
    EaseInOut,
    Linear,
    Spring { spring: Spring },
    CubicBezier { x1: f64, y1: f64, x2: f64, y2: f64 },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ReduceMotion {
    Crossfade,
    Instant,
    Full,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Space {
    Oklab,
    Srgb,
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ColorTransition {
    pub enabled: bool,
    pub duration: f64,
    pub curve: Curve,
    pub space: Space,
    pub reduce_motion: ReduceMotion,
}

impl Default for ColorTransition {
    fn default() -> Self {
        Self {
            enabled: true,
            duration: DEFAULT_DURATION,
            curve: Curve::EaseOut,
            space: Space::Oklab,
            reduce_motion: ReduceMotion::Crossfade,
        }
    }
}

impl ColorTransition {
    /// `resolved(speedOff:systemReduceMotion:)`.
    pub fn resolved(&self, speed_off: bool, system_reduce_motion: bool) -> Self {
        let mut resolved = *self;
        if speed_off || !self.enabled {
            resolved.enabled = false;
        }
        if system_reduce_motion {
            match self.reduce_motion {
                ReduceMotion::Instant => resolved.enabled = false,
                ReduceMotion::Crossfade => {
                    resolved.duration = self.seconds().min(REDUCED_MOTION_CAP);
                    if matches!(self.curve, Curve::Spring { .. }) {
                        resolved.curve = Curve::EaseOut;
                    }
                }
                ReduceMotion::Full => {}
            }
        }
        resolved
    }

    /// Seconds the blend runs (a spring's arrival time; 0 when off).
    pub fn seconds(&self) -> f64 {
        if !self.enabled {
            return 0.;
        }
        if let Curve::Spring { spring } = self.curve {
            return cmux_motion::spring_arrival(spring.into());
        }
        if self.duration.is_finite() { self.duration.max(0.) } else { 0. }
    }

    pub fn is_instant(&self) -> bool {
        self.seconds() <= 0.
    }

    /// Progress at time fraction `t` (clamped to 0...1).
    pub fn progress(&self, t: f64) -> f64 {
        let t = t.clamp(0., 1.);
        match self.curve {
            Curve::EaseOut => TweenCurve::EaseOut.progress_f64(t),
            Curve::EaseInOut => TweenCurve::EaseInOut.progress_f64(t),
            Curve::Linear => TweenCurve::Linear.progress_f64(t),
            Curve::CubicBezier { x1, y1, x2, y2 } => {
                cmux_motion::cubic_bezier_progress(t, x1, y1, x2, y2)
            }
            Curve::Spring { spring } => {
                if t >= 1. {
                    return 1.;
                }
                cmux_motion::spring_progress_monotone(
                    t * self.seconds(),
                    SpringParameters::from(spring),
                )
            }
        }
    }

    /// `progressSamples(count:)`: evenly spaced, the last exactly 1.
    pub fn progress_samples(&self, count: usize) -> Vec<f64> {
        if count <= 1 {
            return vec![1.];
        }
        (0..count)
            .map(|i| if i == count - 1 { 1. } else { self.progress(i as f64 / (count - 1) as f64) })
            .collect()
    }

    pub fn keyframe_progress(&self) -> Vec<f64> {
        self.progress_samples(KEYFRAMES)
    }

    pub fn mixes_in_srgb(&self) -> bool {
        self.space == Space::Srgb
    }

    /// `mix(_:_:fraction:)`, RGBA in 0...1.
    pub fn mix(&self, from: [f64; 4], to: [f64; 4], fraction: f64) -> [f64; 4] {
        let space = if self.mixes_in_srgb() { ColorSpace::Srgb } else { ColorSpace::Oklab };
        cmux_motion::mix_rgba(from, to, fraction, space)
    }

    /// `cssDuration`, e.g. `200ms`.
    pub fn css_duration(&self) -> String {
        format!("{}ms", swift_round(self.seconds() * 1000.) as i64)
    }

    /// `cssEasing`: the CSS timing function.
    pub fn css_easing(&self) -> String {
        match self.curve {
            Curve::EaseOut => "cubic-bezier(0, 0, 0.58, 1)".into(),
            Curve::EaseInOut => "cubic-bezier(0.42, 0, 0.58, 1)".into(),
            Curve::Linear => "linear".into(),
            Curve::CubicBezier { x1, y1, x2, y2 } => format!(
                "cubic-bezier({}, {}, {}, {})",
                css(x1.clamp(0., 1.)),
                css(y1),
                css(x2.clamp(0., 1.)),
                css(y2)
            ),
            Curve::Spring { .. } => {
                let samples: Vec<String> =
                    self.progress_samples(KEYFRAMES).into_iter().map(css).collect();
                format!("linear({})", samples.join(", "))
            }
        }
    }
}

/// Swift's `.rounded()`: half away from zero (Rust's `round`).
fn swift_round(v: f64) -> f64 {
    v.round()
}

/// `css(_:)`: three decimals, a whole number without a point.
pub fn css(value: f64) -> String {
    let rounded = swift_round(value * 1000.) / 1000.;
    if rounded == rounded.round() { format!("{}", rounded as i64) } else { format!("{rounded}") }
}

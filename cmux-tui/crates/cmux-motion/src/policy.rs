//! `MotionPolicy`: tokens resolved for one speed, Reduce Motion state
//! and set of per-kind switches.

use crate::{
    AnimationSwitches, MotionFade, MotionKind, MotionLoop, MotionSpeed, MotionSpring, MotionTween,
    SpringParameters,
};

/// Resolves tokens for one speed setting, Reduce Motion state and set of
/// `ui.animations.*` switches.
///
/// - `off`: nothing animates. Wins over Reduce Motion.
/// - Reduce Motion: movement (position, size, scale, scroll) is instant;
///   fades stay, capped at one crossfade (0.1 s); loops stop.
/// - `normal`: every time constant is 1.5x `fast`; damping is unchanged.
/// - Every spring is critically damped (no bounce in any motion); a kind
///   switched off (`animates(kind)` false) applies in one frame, like
///   Reduce Motion.
#[derive(Clone, Copy, Debug, PartialEq)]
#[repr(C)]
pub struct MotionPolicy {
    pub speed: MotionSpeed,
    pub reduce_motion: bool,
    /// Extra time multiplier for screen recordings (`CMUX2_ANIM_SCALE`); 1
    /// normally. Not part of the cmux-next contract.
    pub debug_scale: f64,
    /// `ui.animations.*`: the per-kind switches.
    pub animations: AnimationSwitches,
}

impl Default for MotionPolicy {
    fn default() -> Self {
        Self::new(MotionSpeed::Fast, false)
    }
}

impl MotionPolicy {
    pub fn new(speed: MotionSpeed, reduce_motion: bool) -> Self {
        Self { speed, reduce_motion, debug_scale: 1., animations: AnimationSwitches::DEFAULT }
    }

    /// The same policy with these `ui.animations.*` settings.
    pub fn with_animations(self, animations: AnimationSwitches) -> Self {
        Self { animations, ..self }
    }

    /// `kind` moves: movement animates and its `ui.animations.*` switch is
    /// on. When false the change applies in one frame (no crossfade).
    pub fn animates(&self, kind: MotionKind) -> bool {
        self.animates_movement() && self.animations.enabled(kind)
    }

    pub(crate) fn scale(&self) -> f64 {
        self.speed.time_scale() * self.debug_scale.max(1.)
    }

    /// Position, size, scale and scroll animate. When false, snap.
    pub fn animates_movement(&self) -> bool {
        self.speed != MotionSpeed::Off && !self.reduce_motion
    }

    /// Opacity and color changes animate. When false, apply at once.
    pub fn animates_fades(&self) -> bool {
        self.speed != MotionSpeed::Off
    }

    /// Spinners and pulses run.
    pub fn animates_loops(&self) -> bool {
        self.speed != MotionSpeed::Off && !self.reduce_motion
    }

    /// The spring for `token`. `off` returns the `fast` spring so a caller
    /// that steps anyway never divides by zero; callers snap when
    /// `animates_movement` is false (`Spring::step` does).
    pub fn spring(&self, token: MotionSpring) -> SpringParameters {
        let base = token.base();
        if self.speed == MotionSpeed::Off { base } else { base.scaled(self.scale()) }
    }

    /// Seconds for a fade; 0 applies at once. Reduce Motion caps it at one
    /// crossfade.
    pub fn fade(&self, token: MotionFade) -> f64 {
        if !self.animates_fades() {
            return 0.;
        }
        let scaled = token.base() * self.scale();
        if self.reduce_motion { scaled.min(MotionFade::Crossfade.base()) } else { scaled }
    }

    /// Seconds of a tween; 0 applies at once: speed `off`, Reduce Motion
    /// (Chrome's strip animations are 0 ms under it) or the token's kind
    /// switched off. `normal` is 1.5x.
    pub fn tween(&self, token: MotionTween) -> f64 {
        if !self.animates_movement() || token.kind().is_some_and(|k| !self.animations.enabled(k)) {
            return 0.;
        }
        token.base().duration * self.scale()
    }

    /// Seconds that stand in for a spring when only a timed API exists:
    /// the spring's visible end. 0 when movement does not animate.
    pub fn spring_duration(&self, token: MotionSpring) -> f64 {
        if self.animates_movement() { self.spring(token).visible_end() } else { 0. }
    }

    /// Period of a loop, or `None` when loops are stopped.
    pub fn period(&self, token: MotionLoop) -> Option<f64> {
        self.animates_loops().then(|| token.period())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A tab close slides on the `tabs` category alone: `ui.animations.newTab` off stops only a new
    /// tab's growth, not the close (close case A follow-up, PR #37401).
    #[test]
    fn new_tab_off_stops_only_the_tab_open_tween() {
        let policy = MotionPolicy::default()
            .with_animations(AnimationSwitches::DEFAULT.with(MotionKind::NewTab, false));
        assert_eq!(policy.tween(MotionTween::TabOpen), 0.);
        assert!(
            policy.tween(MotionTween::TabClose) > 0.,
            "the close tween follows ui.animations.newTab"
        );
        assert!(policy.tween(MotionTween::TabMove) > 0.);
    }

    /// No bounce in any motion (Lawrence 2026-11-10;
    /// plans/cmux-next/motion-first-principles-DESIGN.md, principle 5: position never passes
    /// its target). Every spring token, at every speed, is critically damped or more, and no
    /// frame of a 200 pt move on it is past the target (by more than 1e-6 of the travel).
    #[test]
    fn no_spring_token_passes_its_target() {
        for token in MotionSpring::ALL {
            for speed in [MotionSpeed::Fast, MotionSpeed::Normal, MotionSpeed::Off] {
                let spring = MotionPolicy::new(speed, false).spring(token);
                assert!(
                    spring.damping_fraction >= 1.,
                    "{token:?} at speed {speed:?} has damping fraction {}: it passes its target",
                    spring.damping_fraction
                );
                for hz in [60., 120.] {
                    let mut value = crate::SpringValue::new(0.);
                    value.target = 200.;
                    for frame in 0..(3. * hz) as usize {
                        let moving = value.advance(1. / hz, spring, crate::GEOMETRY_EPSILON);
                        assert!(
                            value.value <= 200.0002,
                            "{token:?} at speed {speed:?}, {hz} Hz, frame {frame}: {} is past 200",
                            value.value
                        );
                        if !moving {
                            break;
                        }
                    }
                }
            }
        }
    }
}

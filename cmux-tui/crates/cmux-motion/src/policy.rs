//! `MotionPolicy`: tokens resolved for one speed, Reduce Motion state,
//! bounce setting and set of per-kind switches.

use crate::{
    AnimationSwitches, MotionBounce, MotionFade, MotionKind, MotionLoop, MotionSpeed, MotionSpring,
    MotionTween, SpringParameters,
};

/// Resolves tokens for one speed setting, Reduce Motion state and set of
/// `ui.animations.*` switches.
///
/// - `off`: nothing animates. Wins over Reduce Motion.
/// - Reduce Motion: movement (position, size, scale, scroll) is instant;
///   fades stay, capped at one crossfade (0.1 s); loops stop.
/// - `normal`: every time constant is 1.5x `fast`; damping is unchanged.
/// - Structural springs (`MotionSpring::is_structural`) are critically
///   damped with bounce `none` and take SwiftUI's subtle bounce with
///   `subtle`; a kind switched off (`animates(kind)` false) applies in one
///   frame, like Reduce Motion.
#[derive(Clone, Copy, Debug, PartialEq)]
#[repr(C)]
pub struct MotionPolicy {
    pub speed: MotionSpeed,
    pub reduce_motion: bool,
    /// Extra time multiplier for screen recordings (`CMUX2_ANIM_SCALE`); 1
    /// normally. Not part of the cmux-next contract.
    pub debug_scale: f64,
    /// `ui.animations.*`: per-kind switches and the bounce.
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
        let mut base = token.base();
        if token.is_structural() {
            // Bounce none: critically damped (never past the target); subtle: SwiftUI bounce.
            base = match self.animations.bounce {
                MotionBounce::None => {
                    SpringParameters::new(base.response, base.damping_fraction.max(1.))
                }
                MotionBounce::Subtle => base.with_bounce(MotionBounce::Subtle.amount()),
            };
        }
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

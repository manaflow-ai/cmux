//! Frame-by-frame driving without a UI toolkit: an `Animated<T>` owns a
//! value and the time of its last frame; the toolkit calls `advance` once
//! per frame and schedules the next frame only while it returns true.
//! Time is seconds on any monotonic clock the caller chooses; nothing here
//! reads a clock.

use std::ops::Deref;

use crate::{Fade, MotionPolicy, Spring};

/// Anything that advances by a frame's elapsed time.
pub trait Animatable {
    /// Advances `dt` seconds; true while still moving.
    fn step(&mut self, dt: f64, policy: &MotionPolicy) -> bool;
    fn is_moving(&self) -> bool;
}

impl Animatable for Spring {
    fn step(&mut self, dt: f64, policy: &MotionPolicy) -> bool {
        Spring::step(self, dt, policy)
    }
    fn is_moving(&self) -> bool {
        Spring::is_moving(self)
    }
}

impl Animatable for Fade {
    fn step(&mut self, dt: f64, _: &MotionPolicy) -> bool {
        Fade::step(self, dt)
    }
    fn is_moving(&self) -> bool {
        Fade::is_moving(self)
    }
}

/// An animated value with its own frame clock.
///
/// The first frame after a change shows the value at the moment of the
/// change; later frames advance by the real time between frames, so the
/// motion is the same at 60 and 120 Hz.
#[derive(Clone, Copy, Debug, PartialEq)]
#[repr(C)]
pub struct Animated<T: Animatable> {
    inner: T,
    /// Caller-clock seconds of the last frame while moving.
    last: f64,
    /// False when idle.
    running: bool,
}

impl<T: Animatable> Animated<T> {
    pub fn new(inner: T) -> Self {
        Self { inner, last: 0., running: false }
    }

    /// Changes the animation at `now` (retarget, snap, follow, release).
    /// Starts the frame clock when it was idle.
    pub fn update<R>(&mut self, now: f64, f: impl FnOnce(&mut T) -> R) -> R {
        let r = f(&mut self.inner);
        if !self.running && self.inner.is_moving() {
            self.running = true;
            self.last = now;
        }
        r
    }

    /// Advances to `now`; true while still moving (schedule another frame).
    pub fn advance(&mut self, now: f64, policy: &MotionPolicy) -> bool {
        let dt = if self.running { (now - self.last).max(0.) } else { 0. };
        let moving = self.inner.step(dt, policy);
        self.running = moving;
        self.last = now;
        moving
    }

    /// True between a change and the frame where it comes to rest.
    pub fn is_animating(&self) -> bool {
        self.running
    }
}

impl<T: Animatable> Deref for Animated<T> {
    type Target = T;
    fn deref(&self) -> &T {
        &self.inner
    }
}

impl<T: Animatable + Default> Default for Animated<T> {
    fn default() -> Self {
        Self::new(T::default())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{MotionFade, MotionSpring};

    #[test]
    fn animated_runs_only_while_moving() {
        let p = MotionPolicy::default();
        let mut a = Animated::new(Spring::new(0., MotionSpring::Appear));
        assert!(!a.is_animating());
        // Idle: a frame does nothing and asks for no more frames.
        assert!(!a.advance(0., &p));
        a.update(1., |s| s.set_target(100.));
        assert!(a.is_animating());
        let mut t = 1.;
        let mut frames = 0;
        while a.advance(t, &p) {
            t += 1. / 120.;
            frames += 1;
            assert!(frames < 100);
        }
        assert_eq!(a.value(), 100.);
        assert!(!a.is_animating());
        // appear rests at ~225 ms: 26-29 frames at 120 Hz.
        assert!((24..=30).contains(&frames), "{frames} frames");

        let mut f = Animated::new(Fade::new(0., MotionFade::Hover));
        f.update(5., |f| f.set_target(1., &p));
        assert!(f.advance(5., &p));
        assert!(f.advance(5.04, &p));
        assert!(!f.advance(5.081, &p));
        assert_eq!(f.value(), 1.);
    }

    #[test]
    fn animated_position_moves_below_zero_with_its_token() {
        let p = MotionPolicy::default();
        let mut a = Animated::new(Spring::position(60., MotionSpring::Move));
        a.update(0., |s| s.set_target(-60.));
        let mut t = 0.;
        let mut frames = 0;
        while a.advance(t, &p) {
            assert_eq!(a.active_token(), MotionSpring::Move);
            t += 1. / 120.;
            frames += 1;
            assert!(frames < 100);
        }
        assert_eq!(a.value(), -60.);
        // move rests at ~250 ms (disappear: ~200 ms): 29-31 frames.
        assert!((28..=32).contains(&frames), "{frames} frames");
    }
}

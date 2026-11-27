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

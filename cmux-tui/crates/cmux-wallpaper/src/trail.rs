//! The pointer's recent path (`Frame.trail`): a ring of [`TRAIL_POINTS`]
//! samples, so a program can draw a trail along a curved path instead of a
//! straight wake from the smoothed velocity.
//!
//! The rule: on each pointer move, when the ring has fewer than 2 points or
//! the move comes [`TRAIL_STEP_S`] or more after the newest committed point
//! (`points[1]`), a new head shifts in; otherwise the head (`points[0]`) moves
//! to the sample. So the head follows the pointer and committed points are
//! about 50 ms apart: the ring covers about 0.8 s of travel.

/// Samples in the ring, and rows in `Frame.trail`.
pub const TRAIL_POINTS: usize = 16;
/// A move this long after the newest committed point commits the head.
pub const TRAIL_STEP_S: f64 = 0.05;
/// A point older than this is not part of the trail (`valid` 0).
pub const TRAIL_LIFE_S: f64 = 1.0;

/// One sample: where the pointer was and when.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct TrailPoint {
    /// The host's pointer units (those of `PointerState::moved`), top left origin.
    pub x: f32,
    pub y: f32,
    /// The host's monotonic clock, seconds.
    pub t: f64,
}

/// The ring, newest first: `points[0]` is the head, `points[..len]` are set.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct TrailState {
    pub points: [TrailPoint; TRAIL_POINTS],
    pub len: usize,
}

impl TrailState {
    /// A pointer move to `(x, y)` at time `t`. NaN or infinite input is ignored.
    pub fn moved(&mut self, x: f32, y: f32, t: f64) {
        if !x.is_finite() || !y.is_finite() || !t.is_finite() {
            return;
        }
        let p = TrailPoint { x, y, t };
        let len = self.len.min(TRAIL_POINTS);
        let shift = match self.points.get(1) {
            Some(committed) if len >= 2 => t - committed.t >= TRAIL_STEP_S,
            _ => true,
        };
        if shift {
            self.points.copy_within(0..TRAIL_POINTS - 1, 1);
            self.len = (len + 1).min(TRAIL_POINTS);
        } else {
            self.len = len;
        }
        if let Some(head) = self.points.first_mut() {
            *head = p;
        }
    }

    /// `Frame.trail` at time `now`: one row per point, newest first, as
    /// `[x, y, age seconds, valid]` with `x` and `y` times `scale` (the
    /// host's units to the Frame's rendered pixels). A point older than
    /// [`TRAIL_LIFE_S`], or not set, is `[0, 0, 0, 0]`. A sample from after
    /// `now` has age 0.
    pub fn rows(&self, now: f64, scale: f32) -> [[f32; 4]; TRAIL_POINTS] {
        let mut out = [[0.0; 4]; TRAIL_POINTS];
        let scale = if scale.is_finite() { scale } else { 0.0 };
        if !now.is_finite() {
            return out;
        }
        let len = self.len.min(TRAIL_POINTS);
        for (row, p) in out.iter_mut().zip(self.points.iter().take(len)) {
            let age = (now - p.t).max(0.0);
            if age <= TRAIL_LIFE_S {
                #[allow(
                    clippy::cast_possible_truncation,
                    reason = "age is within 0..=TRAIL_LIFE_S seconds, exact enough in f32"
                )]
                let age = age as f32;
                *row = [p.x * scale, p.y * scale, age, 1.0];
            }
        }
        out
    }
}

#[cfg(test)]
#[path = "trail_tests.rs"]
mod tests;

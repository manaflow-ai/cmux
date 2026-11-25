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
mod tests {
    use super::*;

    #[test]
    fn the_head_follows_the_pointer_between_steps() {
        let mut s = TrailState::default();
        s.moved(0.0, 0.0, 1.0);
        s.moved(10.0, 0.0, 1.01);
        assert_eq!(s.len, 2);
        // Within a step of points[1]: the head moves, nothing shifts.
        s.moved(20.0, 5.0, 1.03);
        s.moved(30.0, 6.0, 1.045);
        assert_eq!(s.len, 2);
        assert_eq!(s.points[0], TrailPoint { x: 30.0, y: 6.0, t: 1.045 });
        // A step after points[1]: the head is committed and a new one shifts in.
        s.moved(40.0, 7.0, 1.05);
        assert_eq!(s.len, 3);
        assert_eq!(s.points[1], TrailPoint { x: 30.0, y: 6.0, t: 1.045 });
        assert_eq!(s.points[2], TrailPoint { x: 0.0, y: 0.0, t: 1.0 });
    }

    #[test]
    fn a_move_a_step_after_the_committed_point_shifts_in() {
        let mut s = TrailState::default();
        s.moved(0.0, 0.0, 0.0);
        s.moved(1.0, 0.0, 0.01);
        s.moved(2.0, 0.0, 0.05);
        assert_eq!(s.len, 3);
        assert_eq!(s.points[0].x, 2.0);
        assert_eq!(s.points[1].x, 1.0);
        assert_eq!(s.points[2].x, 0.0);
        // At 120 Hz for 2 s the ring stays full; a committed point is the last head before the
        // step, so committed points are within one sample under a step apart.
        for i in 0..240 {
            s.moved(f32::from(u8::try_from(i % 200).unwrap()), 0.0, 1.0 + f64::from(i) / 120.0);
        }
        assert_eq!(s.len, TRAIL_POINTS);
        for w in s.points[1..].windows(2) {
            let gap = w[0].t - w[1].t;
            assert!(
                (TRAIL_STEP_S - 1.0 / 120.0 - 1e-9..TRAIL_STEP_S + 1e-9).contains(&gap),
                "{gap}"
            );
        }
    }

    #[test]
    fn rows_carry_scaled_positions_and_ages_and_expire() {
        let mut s = TrailState::default();
        s.moved(100.0, 50.0, 10.0);
        s.moved(200.0, 60.0, 10.5);
        let rows = s.rows(10.6, 0.5);
        assert_eq!(rows[0][0..2], [100.0, 30.0]);
        assert!((rows[0][2] - 0.1).abs() < 1e-5);
        assert_eq!(rows[0][3], 1.0);
        assert_eq!(rows[1][0..2], [50.0, 25.0]);
        assert!((rows[1][2] - 0.6).abs() < 1e-5);
        assert_eq!(rows[1][3], 1.0);
        assert_eq!(rows[2], [0.0; 4]);
        // Past TRAIL_LIFE_S the older point expires, then the head.
        let rows = s.rows(11.2, 1.0);
        assert_eq!(rows[1], [0.0; 4]);
        assert_eq!(rows[0][3], 1.0);
        assert!(s.rows(11.6, 1.0).iter().all(|r| *r == [0.0; 4]));
        // A sample from after `now` is age 0, not negative.
        assert_eq!(s.rows(9.0, 1.0)[0][2], 0.0);
        assert!(TrailState::default().rows(0.0, 1.0).iter().all(|r| *r == [0.0; 4]));
    }

    #[test]
    fn bad_input_is_ignored() {
        let mut s = TrailState::default();
        s.moved(f32::NAN, 0.0, 0.0);
        s.moved(0.0, f32::INFINITY, 0.0);
        s.moved(0.0, 0.0, f64::NAN);
        assert_eq!(s, TrailState::default());
        s.moved(1.0, 2.0, 3.0);
        assert!(s.rows(f64::NAN, 1.0).iter().all(|r| *r == [0.0; 4]));
        assert!(s.rows(3.0, f32::NAN).iter().flatten().all(|v| v.is_finite()));
        // A len past the ring (a C caller's struct) is read as a full ring.
        s.len = 99;
        s.moved(4.0, 5.0, 4.0);
        assert_eq!(s.len, TRAIL_POINTS);
        assert_eq!(s.rows(4.0, 1.0)[0], [4.0, 5.0, 0.0, 1.0]);
    }
}

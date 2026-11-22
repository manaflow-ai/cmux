//! The hover marquee of a clipped title (tabs, sidebar rows), cmux-next
//! `MotionMarquee` and `MotionPolicy.marquee(travel:)`
//! (`CmuxNextDesign/Motion/MotionMarquee.swift`, defaults in
//! `MotionTunables.marquee*`; plans/cmux-next/motion.md, "Marquee
//! (MotionMarquee)"). After the pointer rests for `delay` the title scrolls
//! to its end with `easeInEaseOut`, holds, and goes back on `move`'s timed
//! equivalent with the ease-out curve. Leaving stops it at once; a title
//! caught mid-scroll springs back with `disappear` from where it is (the
//! host's own `Spring`). Reduce Motion and `off` never start it.

use crate::{MotionPolicy, MotionSpring, ease_in_ease_out, ease_out};

/// Pointer rest before the scroll starts (hover intent), seconds at `fast`.
pub const MARQUEE_DELAY: f64 = 0.6;
/// Scroll speed, points per second.
pub const MARQUEE_POINTS_PER_SECOND: f64 = 40.;
/// Shortest scroll, seconds at `fast`, so a few clipped points do not flick
/// past.
pub const MARQUEE_MINIMUM_SCROLL: f64 = 0.4;
/// Pause at the end before it returns, seconds at `fast`.
pub const MARQUEE_HOLD: f64 = 1.2;
/// Travel under this many points never scrolls.
pub const MARQUEE_MINIMUM_TRAVEL: f64 = 2.;

/// Timing of one marquee pass, in seconds (cmux-next `MarqueeTiming`).
#[derive(Clone, Copy, Debug, PartialEq)]
#[repr(C)]
pub struct MarqueeTiming {
    /// Pointer rest before the scroll.
    pub delay: f64,
    /// Scroll to the end (`easeInEaseOut`).
    pub scroll: f64,
    /// Pause at the end (no movement).
    pub hold: f64,
    /// Back to the start (`move`'s visible end, ease-out).
    pub back: f64,
}

impl MarqueeTiming {
    /// Scroll + hold + back (the delay comes before it).
    pub fn total(&self) -> f64 {
        self.scroll + self.hold + self.back
    }

    /// The title's offset `elapsed` seconds after the pointer came to rest
    /// (0 until `delay` ends, `-travel` at the end of the scroll and through
    /// the hold, 0 again at the end), and whether the pass still runs. The
    /// same keyframes as cmux-next's `Motion.marqueeAnimation`: values
    /// 0, -travel, -travel, 0 with `easeInEaseOut`, linear, ease-out.
    pub fn offset(&self, elapsed: f64, travel: f64) -> (f64, bool) {
        let t = elapsed - self.delay;
        if t.is_nan() || t <= 0. {
            return (0., true);
        }
        if t < self.scroll {
            let p = f64::from(ease_in_ease_out((t / self.scroll) as f32));
            return (-travel * p, true);
        }
        let t = t - self.scroll;
        if t < self.hold {
            return (-travel, true);
        }
        let t = t - self.hold;
        if t < self.back {
            let p = f64::from(ease_out((t / self.back) as f32));
            return (-travel * (1. - p), true);
        }
        (0., false)
    }
}

impl MotionPolicy {
    /// The marquee for `travel` points, or `None` when it should not run:
    /// nothing worth revealing (under `MARQUEE_MINIMUM_TRAVEL` or not a
    /// number), animations `off`, or Reduce Motion (the full title is then
    /// in the tooltip or hover card only). `normal` scales delay, scroll and
    /// hold by 1.5; `back` is `move`'s timed equivalent.
    pub fn marquee(&self, travel: f64) -> Option<MarqueeTiming> {
        if !self.animates_movement() || !travel.is_finite() || travel < MARQUEE_MINIMUM_TRAVEL {
            return None;
        }
        let scale = self.scale();
        Some(MarqueeTiming {
            delay: MARQUEE_DELAY * scale,
            scroll: MARQUEE_MINIMUM_SCROLL.max(travel / MARQUEE_POINTS_PER_SECOND) * scale,
            hold: MARQUEE_HOLD * scale,
            back: self.spring_duration(MotionSpring::Move),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::MotionSpeed;

    /// cmux-next `MotionTunables.marquee*` defaults.
    #[test]
    fn marquee_values_are_cmux_next_defaults() {
        assert_eq!(MARQUEE_DELAY, 0.6);
        assert_eq!(MARQUEE_POINTS_PER_SECOND, 40.);
        assert_eq!(MARQUEE_MINIMUM_SCROLL, 0.4);
        assert_eq!(MARQUEE_HOLD, 1.2);
        assert_eq!(MARQUEE_MINIMUM_TRAVEL, 2.);
    }

    #[test]
    fn marquee_timing_at_fast_and_normal() {
        let fast = MotionPolicy::default();
        let m = fast.marquee(80.).expect("runs");
        assert_eq!((m.delay, m.scroll, m.hold), (0.6, 2., 1.2));
        assert_eq!(m.back, fast.spring_duration(MotionSpring::Move));
        assert!((m.back - 0.192).abs() < 0.01, "{}", m.back);
        assert!((m.total() - (2. + 1.2 + m.back)).abs() < 1e-12);
        // A short travel still takes the shortest scroll.
        assert_eq!(fast.marquee(4.).expect("runs").scroll, 0.4);
        let normal = MotionPolicy::new(MotionSpeed::Normal, false);
        let n = normal.marquee(80.).expect("runs");
        assert!(
            (n.delay - 0.9).abs() < 1e-12
                && (n.scroll - 3.).abs() < 1e-12
                && (n.hold - 1.8).abs() < 1e-12
        );
        assert_eq!(n.back, normal.spring_duration(MotionSpring::Move));
    }

    #[test]
    fn marquee_never_runs_under_reduce_motion_off_or_tiny_travel() {
        assert_eq!(MotionPolicy::new(MotionSpeed::Fast, true).marquee(80.), None);
        assert_eq!(MotionPolicy::new(MotionSpeed::Normal, true).marquee(80.), None);
        assert_eq!(MotionPolicy::new(MotionSpeed::Off, false).marquee(80.), None);
        let fast = MotionPolicy::default();
        assert_eq!(fast.marquee(1.9), None);
        assert_eq!(fast.marquee(f64::NAN), None);
        assert_eq!(fast.marquee(f64::INFINITY), None);
        assert!(fast.marquee(2.).is_some());
    }

    #[test]
    fn marquee_offset_follows_the_keyframes() {
        let m = MotionPolicy::default().marquee(80.).expect("runs");
        assert_eq!(m.offset(0., 80.), (0., true));
        assert_eq!(m.offset(0.6, 80.), (0., true));
        // Halfway through the scroll: easeInEaseOut(0.5) = 0.5.
        let (mid, running) = m.offset(0.6 + 1., 80.);
        assert!(running && (mid + 40.).abs() < 1e-3, "{mid}");
        // Through the hold it stays at the end.
        assert_eq!(m.offset(0.6 + 2.5, 80.), (-80., true));
        // Back: ease-out, past halfway at half time.
        let (back, _) = m.offset(0.6 + 3.2 + m.back / 2., 80.);
        assert!(back > -40. && back < 0., "{back}");
        assert_eq!(m.offset(0.6 + m.total() + 0.01, 80.), (0., false));
    }
}

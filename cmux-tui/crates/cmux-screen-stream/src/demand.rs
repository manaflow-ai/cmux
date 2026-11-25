//! The picture size a viewer needs, and the size the host captures at.
//!
//! The viewer reports, every 2 s and when a pinch ends, the long edge in device pixels the whole
//! streamed display takes on its screen at its zoom (`view`). The host captures at the smallest
//! rung that covers it (960, 1280, 1920, 2560 or 3840 on the long edge, never more than the
//! display). A change has to hold before it applies: smaller after 6 s, larger after 3 s, and a
//! larger one that undoes a step down taken in the last 30 s after 6 s. A pinch report raises at
//! once. Ported from Petal's `ViewerDemandResolutionState` (Apache-2.0).

pub const RUNGS: [i64; 5] = [960, 1280, 1920, 2560, 3840];
pub const DOWNSIZE_HOLD: f64 = 6.0;
pub const UPSIZE_HOLD: f64 = 3.0;
pub const REVERSAL_DWELL: f64 = 30.0;

/// One viewer's demand: the cap the host captures at and the change that waits for its hold.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ViewerDemand {
    cap: Option<i64>,
    pending: Option<(Option<i64>, f64)>,
    last_change: Option<(f64, bool)>,
}

/// The rung for a viewer's `long_edge` on a display `display_long_edge` pixels long; `None` when
/// the rung is the display's own size or more (nothing to scale down).
pub fn rung(long_edge: i64, display_long_edge: i64) -> Option<i64> {
    let rung = RUNGS.iter().copied().find(|r| *r >= long_edge).or_else(|| RUNGS.last().copied())?;
    if display_long_edge > 0 && rung >= display_long_edge { None } else { Some(rung) }
}

/// A cap as a size to compare (`None`, the full display, is the largest).
fn size(cap: Option<i64>) -> i64 {
    cap.unwrap_or(i64::MAX)
}

impl ViewerDemand {
    pub fn new() -> Self {
        Self::default()
    }

    /// The long edge the host captures at; `None`: the display's own size.
    pub fn cap(&self) -> Option<i64> {
        self.cap
    }

    /// Takes one report at `now` (seconds, monotonic) and returns whether `cap` changed. A report
    /// of 0 or less carries no size and changes nothing.
    pub fn report(
        &mut self,
        long_edge: i64,
        display_long_edge: i64,
        pinch: bool,
        now: f64,
    ) -> bool {
        if long_edge <= 0 {
            self.pending = None;
            return false;
        }
        let target = rung(long_edge, display_long_edge);
        if target == self.cap {
            self.pending = None;
            return false;
        }
        let raising = size(target) > size(self.cap);
        if raising && pinch {
            self.apply(target, true, now);
            return true;
        }
        match self.pending {
            Some((cap, since)) if cap == target => {
                if now - since >= self.hold(raising, now) {
                    self.apply(target, raising, now);
                    true
                } else {
                    false
                }
            }
            // A new target (or a contradicted one) starts its hold now.
            _ => {
                self.pending = Some((target, now));
                false
            }
        }
    }

    fn apply(&mut self, target: Option<i64>, raised: bool, now: f64) {
        self.cap = target;
        self.pending = None;
        self.last_change = Some((now, raised));
    }

    fn hold(&self, raising: bool, now: f64) -> f64 {
        if !raising {
            return DOWNSIZE_HOLD;
        }
        match self.last_change {
            Some((at, false)) if now - at < REVERSAL_DWELL => DOWNSIZE_HOLD,
            _ => UPSIZE_HOLD,
        }
    }
}

/// `(width, height)` scaled down to fit `cap` on its long edge (even sides, as the encoder
/// wants); unchanged when it already fits or there is no cap.
pub fn fit(width: f64, height: f64, cap: Option<i64>) -> (f64, f64) {
    let Some(cap) = cap else { return (width, height) };
    if !(width > 0.0 && height > 0.0) {
        return (width, height);
    }
    let long_edge = width.max(height);
    if long_edge <= cap as f64 {
        return (width, height);
    }
    let scale = cap as f64 / long_edge;
    let even = |value: f64| ((value * scale / 2.0).round() * 2.0).max(2.0);
    (even(width), even(height))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rung_covers_the_long_edge_and_never_the_display() {
        assert_eq!(rung(1179, 3456), Some(1280));
        assert_eq!(rung(960, 3456), Some(960));
        assert_eq!(rung(5000, 6000), Some(3840));
        assert_eq!(rung(3000, 3456), None);
        assert_eq!(rung(100, 0), Some(960));
    }

    #[test]
    fn a_downsize_holds_six_seconds() {
        let mut d = ViewerDemand::new();
        assert!(!d.report(1179, 3456, false, 0.0));
        assert!(!d.report(1179, 3456, false, 5.9));
        assert!(d.report(1179, 3456, false, 6.0));
        assert_eq!(d.cap(), Some(1280));
        assert!(!d.report(1179, 3456, false, 7.0));
    }

    #[test]
    fn a_pinch_raises_at_once_and_a_reversal_holds_longer() {
        let mut d = ViewerDemand::new();
        d.report(1000, 3456, false, 0.0);
        assert!(d.report(1000, 3456, false, 6.0));
        assert_eq!(d.cap(), Some(1280));
        // Raising within 30 s of the step down waits the downsize hold.
        assert!(!d.report(1800, 3456, false, 10.0));
        assert!(!d.report(1800, 3456, false, 13.0));
        assert!(d.report(1800, 3456, false, 16.0));
        assert_eq!(d.cap(), Some(1920));
        // After a raise, a raise waits 3 s.
        assert!(!d.report(5000, 3456, false, 20.0));
        assert!(d.report(5000, 3456, false, 23.0));
        assert_eq!(d.cap(), None);
        // A pinch raises at once.
        let mut d = ViewerDemand::new();
        d.report(1000, 3456, false, 0.0);
        d.report(1000, 3456, false, 6.0);
        assert!(d.report(3000, 3456, true, 6.5));
        assert_eq!(d.cap(), None);
    }

    #[test]
    fn a_report_without_size_or_back_at_the_cap_drops_the_pending_change() {
        let mut d = ViewerDemand::new();
        d.report(1000, 3456, false, 0.0);
        assert!(!d.report(0, 3456, false, 3.0));
        assert!(!d.report(1000, 3456, false, 6.0));
        assert!(d.report(1000, 3456, false, 12.0));
    }

    #[test]
    fn fit_scales_to_even_sides() {
        assert_eq!(fit(3456.0, 2234.0, Some(1280)), (1280.0, 828.0));
        assert_eq!(fit(1000.0, 500.0, Some(1280)), (1000.0, 500.0));
        assert_eq!(fit(1000.0, 500.0, None), (1000.0, 500.0));
        assert_eq!(fit(4000.0, 1.0, Some(960)), (960.0, 2.0));
    }
}

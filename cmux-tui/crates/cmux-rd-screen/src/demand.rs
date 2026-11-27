//! The picture size a viewer needs, and the size the host captures at
//! (ViewerDemand.swift).
//!
//! The viewer reports the long edge, in device pixels, that the streamed
//! display takes on its screen. The host captures at the smallest rung that
//! covers it, never more than the display. A change has to hold before it
//! applies: a smaller picture after 6 s, a larger one after 3 s, and a larger
//! one that undoes a step down taken in the last 30 s after 6 s. A pinch
//! raises at once. Ported from Petal's `ViewerDemandResolutionState`
//! (https://github.com/kiruna-labs/petal, Apache-2.0).

use serde::{Deserialize, Serialize};

use crate::geometry::Size;

pub const RUNGS: [i64; 5] = [960, 1280, 1920, 2560, 3840];
pub const DOWNSIZE_HOLD: f64 = 6.0;
pub const UPSIZE_HOLD: f64 = 3.0;
pub const REVERSAL_DWELL: f64 = 30.0;

#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Pending {
    pub cap: Option<i64>,
    pub since: f64,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Change {
    pub at: f64,
    pub raised: bool,
}

/// The demand state. Serializable so a caller can keep it between reports.
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ViewerDemand {
    /// The long edge the host captures at; `None`: the display's own size.
    pub cap: Option<i64>,
    #[serde(default)]
    pub pending: Option<Pending>,
    #[serde(default)]
    pub last_change: Option<Change>,
}

/// The rung for a viewer's `long_edge` on a display `display_long_edge`
/// pixels long; `None` when the rung is the display's own size or more.
pub fn rung(long_edge: i64, display_long_edge: i64) -> Option<i64> {
    let rung = RUNGS.iter().copied().find(|r| *r >= long_edge).unwrap_or(RUNGS[RUNGS.len() - 1]);
    if display_long_edge > 0 && rung >= display_long_edge { None } else { Some(rung) }
}

/// A cap as a size to compare: `None`, the full display, is the largest.
fn size(cap: Option<i64>) -> i64 {
    cap.unwrap_or(i64::MAX)
}

impl ViewerDemand {
    /// Takes one report at `now` (seconds, monotonic) and returns whether
    /// `cap` changed. A report of 0 or less carries no size.
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
        let Some(pending) = self.pending.filter(|p| p.cap == target) else {
            // A new target (or a contradicted one) starts its hold now.
            self.pending = Some(Pending { cap: target, since: now });
            return false;
        };
        if now - pending.since < self.hold(raising, now) {
            return false;
        }
        self.apply(target, raising, now);
        true
    }

    fn apply(&mut self, target: Option<i64>, raised: bool, now: f64) {
        self.cap = target;
        self.pending = None;
        self.last_change = Some(Change { at: now, raised });
    }

    fn hold(&self, raising: bool, now: f64) -> f64 {
        if !raising {
            return DOWNSIZE_HOLD;
        }
        match self.last_change {
            Some(c) if !c.raised && now - c.at < REVERSAL_DWELL => DOWNSIZE_HOLD,
            _ => UPSIZE_HOLD,
        }
    }
}

/// `size` scaled down to fit `cap` on its long edge, with even sides (as the
/// encoder wants); unchanged when it fits or there is no cap.
pub fn fit(size: Size, cap: Option<i64>) -> Size {
    let Some(cap) = cap else { return size };
    if size.w <= 0.0 || size.h <= 0.0 {
        return size;
    }
    let long_edge = size.w.max(size.h);
    let cap = cap as f64;
    if long_edge <= cap {
        return size;
    }
    let scale = cap / long_edge;
    // Swift's `.rounded()`: half away from zero, as f64::round.
    let even = |v: f64| ((v * scale / 2.0).round() * 2.0).max(2.0);
    Size { w: even(size.w), h: even(size.h) }
}

/// The quality presets a viewer picks (`ScreenQuality`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Quality {
    Auto,
    Smooth,
    Low,
    Medium,
    High,
}

/// The long edge the source captures at: the viewer's demand, only under an
/// adaptive quality and only for a source that scales.
pub fn capture_cap(demand: Option<i64>, quality: Quality, scales: bool) -> Option<i64> {
    if scales && matches!(quality, Quality::Auto | Quality::Smooth) { demand } else { None }
}

#[cfg(test)]
#[path = "demand_tests.rs"]
mod tests;

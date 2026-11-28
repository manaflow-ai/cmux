//! The drag-out neck (gooey-tabs.md "drag_neck"): while a dragged tab is
//! within `break_distance` of its slot, a smooth-union neck joins them,
//! narrowing with distance until it pinches to a thread at the break. Past
//! it the neck snaps off (`attached = false`; the host plays a `Snap` plan),
//! and only coming back within `capture_distance`, which is shorter, absorbs
//! the tab again, so the boundary never flickers.

use super::{Blob, GooTuning, Outline, RoundedRect, merge};

/// The slot's outline this mouse event, and whether the neck holds.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct DragNeck {
    pub outline: Outline,
    pub attached: bool,
}

/// Whether the neck holds with the tab `gap` points from its slot:
/// hysteresis between `break_distance` (going out) and `capture_distance`
/// (coming back). A non-finite gap lets go; a tuning with no break distance
/// (level off) never attaches.
pub fn neck_holds(gap: f64, was_attached: bool, tuning: &GooTuning) -> bool {
    let t = tuning.sanitized();
    if !gap.is_finite() || t.break_distance <= 0. {
        return false;
    }
    if was_attached { gap < t.break_distance } else { gap < t.capture_distance }
}

/// The drag neck for `slot` (the dragged tab's blob in the strip) and the
/// lifted `tab`. Attached: the slot's blob merged with the tab at a goo
/// threshold of twice `break_distance`, so the neck thins to nothing exactly
/// at the break. Detached: the slot's rest outline.
pub fn drag_neck(
    slot: &Blob,
    tab: &RoundedRect,
    was_attached: bool,
    tuning: &GooTuning,
) -> DragNeck {
    let shape = slot.shape();
    let rest = shape.outline(0.);
    let tab = tab.sanitized();
    let gap = if tab.w > 0. && tab.h > 0. {
        tab.gap_to(shape.left, shape.top, shape.right, shape.baseline)
    } else {
        f64::INFINITY
    };
    let attached = neck_holds(gap, was_attached, tuning);
    if !attached {
        return DragNeck { outline: rest, attached };
    }
    let k = tuning.sanitized().break_distance * 2.;
    DragNeck { outline: merge(&rest, &shape, &tab, k), attached }
}

#[cfg(test)]
#[path = "drag_tests.rs"]
mod tests;

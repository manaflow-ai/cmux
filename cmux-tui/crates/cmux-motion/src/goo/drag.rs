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
mod tests {
    use super::*;
    use crate::goo::{GooLevel, rest_outline};

    fn slot() -> Blob {
        Blob {
            left: 100.,
            right: 260.,
            top: 6.,
            baseline: 36.,
            corner_radius: 8.,
            feet_radius: 8.,
            skips_leading: false,
        }
    }

    fn tab_above(gap: f64) -> RoundedRect {
        RoundedRect::new(110., 6. - gap - 30., 160., 30., 8.)
    }

    #[test]
    fn goo_drag_neck_hysteresis_breaks_past_capture() {
        for level in [GooLevel::Subtle, GooLevel::Full] {
            let t = GooTuning::for_level(level);
            assert!(t.break_distance > t.capture_distance && t.capture_distance > 0.);
            // Going out: holds until the break, then snaps.
            let mut attached = true;
            let mut broke_at = None;
            for i in 0..400 {
                let gap = i as f64 * 0.25;
                let n = drag_neck(&slot(), &tab_above(gap), attached, &t);
                if attached && !n.attached {
                    broke_at = Some(gap);
                }
                attached = n.attached;
            }
            let broke_at = broke_at.expect("the neck breaks");
            assert!((broke_at - t.break_distance).abs() <= 0.25, "{level:?} broke at {broke_at}");
            // Between capture and break a detached tab stays detached, an attached one stays attached.
            let mid = (t.capture_distance + t.break_distance) * 0.5;
            assert!(!drag_neck(&slot(), &tab_above(mid), false, &t).attached);
            assert!(drag_neck(&slot(), &tab_above(mid), true, &t).attached);
            // Jitter on the break boundary does not flicker once broken.
            let mut state = false;
            for j in 0..50 {
                let gap = t.break_distance + if j % 2 == 0 { -0.5 } else { 0.5 };
                state = drag_neck(&slot(), &tab_above(gap), state, &t).attached;
                assert!(!state, "re-attached at {gap}");
            }
            // Coming back: absorbed only inside capture.
            let back = drag_neck(&slot(), &tab_above(t.capture_distance - 0.5), false, &t);
            assert!(back.attached);
            // And jitter on the capture boundary does not flicker once absorbed.
            let mut state = true;
            for j in 0..50 {
                let gap = t.capture_distance + if j % 2 == 0 { -0.5 } else { 0.5 };
                state = drag_neck(&slot(), &tab_above(gap), state, &t).attached;
                assert!(state, "let go at {gap}");
            }
        }
    }

    #[test]
    fn goo_drag_neck_reaches_the_tab_and_detached_is_rest() {
        let t = GooTuning::for_level(GooLevel::Full);
        let n = drag_neck(&slot(), &tab_above(20.), true, &t);
        assert!(n.attached);
        let top = n.outline.p.iter().map(|p| p.y).fold(f64::MAX, f64::min);
        assert!(top < 6. - 19., "the neck reaches the tab: {top}");
        assert!(n.outline.is_finite());
        let far = drag_neck(&slot(), &tab_above(200.), true, &t);
        assert!(!far.attached);
        assert_eq!(far.outline, rest_outline(&slot()));
    }

    #[test]
    fn goo_level_off_never_necks() {
        let t = GooTuning::for_level(GooLevel::Off);
        for gap in [0., 1., 5., 50.] {
            let n = drag_neck(&slot(), &tab_above(gap), true, &t);
            assert!(!n.attached);
            assert_eq!(n.outline, rest_outline(&slot()));
        }
    }

    #[test]
    fn goo_drag_neck_is_garbage_safe() {
        let bad = [f64::NAN, f64::INFINITY, f64::NEG_INFINITY, -10., 0., 1e300];
        let mut tuning = GooTuning::for_level(GooLevel::Full);
        for &a in &bad {
            tuning.break_distance = a;
            tuning.capture_distance = -a;
            for &b in &bad {
                let n = drag_neck(&slot(), &RoundedRect::new(a, b, a, b, a), a > 0., &tuning);
                assert!(n.outline.is_finite());
            }
        }
    }
}

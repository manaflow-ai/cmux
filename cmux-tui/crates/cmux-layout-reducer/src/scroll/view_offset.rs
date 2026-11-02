//! View-offset rules (plans/cmux-next/column-scroll.md, Swift
//! `ColumnViewOffset`), clamped to the strip: cmux never scrolls past the
//! first or last column.

use super::state::CenterFocusedColumn;
use super::strip::{ColumnStrip, Rect};
use super::swift_min_by;
use crate::PaneId;

/// Minimal reveal (F1): leave the view if `rect` is fully visible (with its
/// padding); otherwise align the edge that needs less motion. A rect as wide
/// as the view is left-aligned.
pub fn fit(rect: Rect, current: f64, strip: &ColumnStrip) -> f64 {
    // RED: rule not ported yet.
    let _ = (rect, strip);
    current
}

/// Centered reveal (F2): the column in the middle; a column as wide as the
/// view is left-aligned like [`fit`].
pub fn center(rect: Rect, current: f64, strip: &ColumnStrip) -> f64 {
    // RED: rule not ported yet.
    let _ = (rect, strip);
    current
}

/// On-overflow reveal (F3), plus the focused pane of a column wider than the
/// view: if that pane is visible now, nothing moves; else the column's left
/// edge if that shows the pane; else the least scroll that shows the pane.
pub fn target(
    index: usize,
    pane: Option<PaneId>,
    current: f64,
    mode: CenterFocusedColumn,
    previous: Option<usize>,
    strip: &ColumnStrip,
) -> f64 {
    // RED: rule not ported yet.
    let _ = (index, pane, mode, previous, strip);
    current
}

/// The rect lies inside the viewport, or covers all of it.
fn shows(rect: Rect, offset: f64, strip: &ColumnStrip) -> bool {
    let start = offset + strip.leading_cover;
    let end = start + strip.visible_width();
    let inside = rect.min_x() >= start - 0.5 && rect.max_x() <= end + 0.5;
    let covers = rect.min_x() <= start + 0.5 && rect.max_x() >= end - 0.5;
    inside || covers
}

/// A resting point of a trackpad gesture and the column it belongs to.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Snap {
    pub offset: f64,
    pub column: usize,
}

/// Gesture-end snapping points (T2): each column's left and right alignment
/// (with padding); column centers when centering is always on; under
/// `on-overflow`, an edge whose neighbor cannot share the screen snaps to the
/// center instead. Clamped to the strip, ascending.
pub fn snaps(strip: &ColumnStrip, mode: CenterFocusedColumn) -> Vec<Snap> {
    let mut out = Vec::new();
    snaps_into(strip, mode, &mut out);
    out
}

/// [`snaps`] into `out` (cleared first), reusing its buffer.
pub fn snaps_into(strip: &ColumnStrip, mode: CenterFocusedColumn, out: &mut Vec<Snap>) {
    // RED: rule not ported yet.
    let _ = (strip, mode);
    out.clear();
}

/// Swift's dedup test `abs(last - next) > 0.5`; false for a NaN distance.
fn more_than_half_point_apart(a: f64, b: f64) -> bool {
    (a - b).abs() > 0.5
}

/// Gesture end (T3): after snapping, focus the column farthest in the
/// gesture's direction that is fully visible. cmux keeps the focused column
/// instead when it is still visible, so a peek does not move the keyboard.
/// Returns `None` when focus stays.
pub fn focus_after_scroll(
    focused: Option<usize>,
    snap_column: usize,
    target: f64,
    forward: bool,
    strip: &ColumnStrip,
) -> Option<usize> {
    // RED: rule not ported yet.
    let _ = (focused, snap_column, target, forward, strip);
    None
}

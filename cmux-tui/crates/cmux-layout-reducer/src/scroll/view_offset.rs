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
    // Measured in the uncovered window (F6): `lead` is what a floating
    // leading dock covers, so the window starts at `current + lead`.
    let width = strip.visible_width();
    let lead = strip.leading_cover;
    if width <= rect.w() {
        return strip.clamp(rect.min_x() - lead);
    }
    let pad = strip.padding(rect.w());
    let left = rect.min_x() - pad;
    let right = rect.max_x() + pad;
    let start = current + lead;
    if start <= left + 0.5 && right <= start + width + 0.5 {
        return strip.clamp(current);
    }
    let to_left = (start - left).abs();
    let to_right = (start + width - right).abs();
    strip.clamp((if to_left <= to_right { left } else { right - width }) - lead)
}

/// Centered reveal (F2): the column in the middle; a column as wide as the
/// view is left-aligned like [`fit`].
pub fn center(rect: Rect, current: f64, strip: &ColumnStrip) -> f64 {
    if strip.visible_width() <= rect.w() {
        return fit(rect, current, strip);
    }
    strip.clamp(rect.mid_x() - strip.visible_width() / 2. - strip.leading_cover)
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
    let Some(column) = strip.columns.get(index) else { return strip.clamp(current) };
    let frame = column.frame;
    if strip.is_wide(frame)
        && let Some(pane_frame) = pane.and_then(|pane| strip.pane_frame(index, pane))
    {
        // Inside a wide column the pane's own edges count, not its padding.
        if shows(pane_frame, current, strip) {
            return strip.clamp(current);
        }
        let left_aligned = strip.clamp(frame.min_x() - strip.leading_cover);
        if shows(pane_frame, left_aligned, strip) {
            return left_aligned;
        }
        return fit(pane_frame, current, strip);
    }
    match mode {
        CenterFocusedColumn::Never => fit(frame, current, strip),
        CenterFocusedColumn::Always => center(frame, current, strip),
        CenterFocusedColumn::OnOverflow => {
            let Some(previous) =
                previous.filter(|&previous| previous != index && previous < strip.columns.len())
            else {
                return fit(frame, current, strip);
            };
            // The source is always the target's neighbor on the side focus came from.
            let source = if previous > index {
                index.saturating_add(1).min(strip.columns.len().saturating_sub(1))
            } else {
                index.saturating_sub(1)
            };
            // `source` is in range (`index` is a column of the strip); the guard only keeps the
            // port free of a panic path.
            let Some(a) = strip.frame_at(source) else { return fit(frame, current, strip) };
            let b = frame;
            let span = super::swift_max(a.max_x(), b.max_x())
                - super::swift_min(a.min_x(), b.min_x())
                + strip.gap * 2.;
            if span <= strip.visible_width() + 0.5 {
                fit(b, current, strip)
            } else {
                center(b, current, strip)
            }
        }
    }
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
    out.clear();
    if strip.columns.is_empty() {
        return;
    }
    let width = strip.visible_width();
    let lead = strip.leading_cover;
    for (index, column) in strip.columns.iter().enumerate() {
        let frame = column.frame;
        let centered = strip.clamp(
            (if width <= frame.w() { frame.min_x() } else { frame.mid_x() - width / 2. }) - lead,
        );
        if mode == CenterFocusedColumn::Always {
            out.push(Snap { offset: centered, column: index });
            continue;
        }
        let pad = strip.padding(frame.w());
        let overflows = |neighbor: Option<usize>| {
            let Some(neighbor) = neighbor.and_then(|n| strip.frame_at(n)) else {
                return false;
            };
            mode == CenterFocusedColumn::OnOverflow
                && neighbor.w() + strip.gap * 3. + frame.w() > width
        };
        let left = if overflows(index.checked_add(1)) {
            centered
        } else {
            strip.clamp(frame.min_x() - pad - lead)
        };
        let right = if overflows(index.checked_sub(1)) {
            centered
        } else {
            strip.clamp(frame.max_x() + pad - width - lead)
        };
        out.push(Snap { offset: left, column: index });
        out.push(Snap { offset: right, column: index });
    }
    // Swift sorts by the tuple `(offset, column)`. A NaN offset (only from a NaN frame) takes
    // `total_cmp`'s place so the order stays total and `sort_by` never panics.
    out.sort_by(|a, b| {
        a.offset
            .partial_cmp(&b.offset)
            .unwrap_or_else(|| a.offset.total_cmp(&b.offset))
            .then(a.column.cmp(&b.column))
    });
    // Keep a snap only when it is more than 0.5 pt from the last kept one.
    out.dedup_by(|snap, kept| !more_than_half_point_apart(kept.offset, snap.offset));
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
    if let Some(focused) = focused
        && focused < strip.columns.len()
        && strip.is_column_visible(focused, target)
    {
        return None;
    }
    let visible = (0..strip.columns.len()).filter(|&i| strip.is_column_visible(i, target));
    let distance = |i: usize| i.abs_diff(snap_column);
    let mut index = swift_min_by(visible, |a, b| distance(*a) < distance(*b))?;
    if forward {
        while let Some(next) = index.checked_add(1).filter(|&n| strip.is_column_visible(n, target))
        {
            index = next;
        }
    } else {
        while let Some(previous) =
            index.checked_sub(1).filter(|&n| strip.is_column_visible(n, target))
        {
            index = previous;
        }
    }
    if Some(index) == focused { None } else { Some(index) }
}

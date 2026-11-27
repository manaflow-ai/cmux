//! Column scroll rules (plans/cmux-next/column-scroll.md): the camera of a
//! columns screen, of a column's rows (rows.md V1, V2) and of a scroll area
//! (scroll-areas-DESIGN.md S5). Minimal reveal of the focused column, the
//! centering modes, a camera anchored on the focused column across layout and
//! window changes, the restore of the previous offset when a just-opened
//! column closes, and trackpad and wheel snapping that never fights the
//! automatic reveal.
//!
//! A 1:1 port of the Swift `CmuxNextLayout/Scroll` reducers
//! (`ColumnScrollState.reduce`, `ColumnStrip`, `ColumnViewOffset`,
//! `RowScroll`, `ScrollAreaScroll`) and of the three `ColumnStripGeometry`
//! functions they call. Offsets are the content-space x of the viewport's
//! leading edge, in points, as `f64` (macOS `CGFloat`). Pure: no I/O, no
//! clock; the caller steps the spring each display frame (cmux-motion).
//!
//! `min` and `max` follow Swift's `Swift.min` and `Swift.max` (see
//! [`swift_min`]), and rectangle edges follow `CGRect`'s standardized
//! `minX`/`maxX`/`width`, so every result for finite frames is bit for bit the
//! Swift one. A NaN offset sorts by `total_cmp` among the snaps, where Swift's
//! non-total `<` has no defined order.
//!
//! The C ABI is `cmux_scroll_*` in cmux-layout-reducer-ffi (src/scroll.rs).

mod adapters;
mod geometry;
mod state;
mod strip;
mod view_offset;

pub use adapters::{EMPTY_AREA_CELL, RowId, RowScroll, ScrollAreaScroll};
pub use geometry::{adjacent_snap, projected_offset, rubber_band, snap_target};
pub use state::{
    CenterFocusedColumn, ColumnFocusSource, ColumnScrollEffects, ColumnScrollEvent,
    ColumnScrollState, Gesture, RestorePoint, Sample, Spring,
};
pub use strip::{Axis, ColumnStrip, Rect, StripColumn, StripPane};
pub use view_offset::{Snap, center, fit, focus_after_scroll, snaps, snaps_into, target};

/// `Swift.min(x, y)`: `y < x ? y : x`. Differs from `f64::min` for NaN and
/// signed zero, which the port keeps exact.
#[inline]
pub fn swift_min(x: f64, y: f64) -> f64 {
    if y < x { y } else { x }
}

/// `Swift.max(x, y)`: `y >= x ? y : x`.
#[inline]
pub fn swift_max(x: f64, y: f64) -> f64 {
    if y >= x { y } else { x }
}

/// `Sequence.min(by:)`: the first element no other is "less" than.
pub(crate) fn swift_min_by<T: Copy>(
    items: impl IntoIterator<Item = T>,
    less: impl Fn(&T, &T) -> bool,
) -> Option<T> {
    let mut iter = items.into_iter();
    let mut best = iter.next()?;
    for item in iter {
        if less(&item, &best) {
            best = item;
        }
    }
    Some(best)
}

#[cfg(test)]
mod tests;

#[cfg(test)]
mod model_check_tests;

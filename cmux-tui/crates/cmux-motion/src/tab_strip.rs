//! Tab strip geometry for the Chrome tab motion (design-tokens.json
//! `motion.tabStrip`, read at build time). The hosts lay out and animate
//! the strip; these are the shared numbers.

use crate::tokens::{TAB_STRIP_COMFORTABLE, TAB_STRIP_COMPACT};

/// Points (pt) and, for the closing-mode delay, seconds.
#[derive(Clone, Copy, Debug, PartialEq)]
#[repr(C)]
pub struct TabStripGeometry {
    /// Widest an unpinned tab gets (the default of the host's max-width setting).
    pub max_width: f64,
    /// A new tab starts this wide at the previous tab's right edge minus this.
    pub open_start_width: f64,
    /// A closing tab ends this wide, its left edge pinned.
    pub close_end_width: f64,
    /// Crowding shrinks every tab evenly down to this; the active tab never goes below.
    pub min_active_width: f64,
    /// Then the inactive tabs shrink down to this (then the strip scrolls).
    pub min_inactive_width: f64,
    pub pinned_width: f64,
    /// Pointer travel past a neighbour that reorders a dragged tab, at `max_width`.
    pub reorder_threshold: f64,
    /// Mouse closing mode ends once the pointer is this far below the strip ...
    pub closing_mode_below_pad: f64,
    /// ... or this far past its trailing edge ...
    pub closing_mode_trailing_pad: f64,
    /// ... and this many seconds have passed since it left.
    pub closing_mode_exit_delay: f64,
}

impl TabStripGeometry {
    pub const COMPACT: Self = TAB_STRIP_COMPACT;
    pub const COMFORTABLE: Self = TAB_STRIP_COMFORTABLE;

    /// The reorder threshold for a tab `tab_width` wide (16 x width / 200 by default).
    pub fn reorder_threshold_at(&self, tab_width: f64) -> f64 {
        if self.max_width > 0. { self.reorder_threshold * tab_width / self.max_width } else { 0. }
    }
}

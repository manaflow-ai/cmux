//! The pure geometry of the NEXT app's layout (Swift `CmuxNextLayout/Geometry`), moved to Rust so the
//! Swift types become thin callers (cmuxterm-hq docs/rfd/drafts/why-swift.md).
//!
//! Every function here is a line-by-line port of its Swift twin, in `CGFloat` (f64) arithmetic with
//! Swift's own `min`, `max` and `rounded()` semantics, so each answer is the one the Swift gave bit for
//! bit (tests/data/layout_geometry_vectors.json pins it). Coordinates are flipped: y grows down.
//!
//! - [`drop_zones`]: the tab drop targets of a screen and their preview rects (`DropZoneGeometry`).
//! - [`dock_strip`]: which columns dock and where the docks and the strip sit (`DockStripGeometry`).
//! - [`divider_band`]: a resize handle's line and hit area (`DividerBand`).
//! - [`wire`]: the `layout_geometry_*` JSON operations the app calls over the FFI.
//! - [`pane_chrome`]: a pane's content rect inside its cell (`PaneChromeGeometry`, its `LayoutStyle`
//!   metrics).
//! - [`split_layout`]: a split tree's frames, dividers, minimums and drag ratios (`SplitGeometry`,
//!   `EvenSplitRatios`, `PushResize`).
//! - [`row_stack`]: a column of rows and a row-edge drag (`RowStackGeometry`, `RowResize`).
//! - [`strip_math`]: column-edge drags and the keep-alive band (`StripStart`, `UniformEdge`,
//!   `KeepAliveBand`).
//! - [`column_strip`]: the strip's column frames, snaps, scrollbar and Equalize Splits widths
//!   (`ColumnStripGeometry`, `StripScrollbarGeometry`, `ColumnEqualizer`, `ScrollAreaGeometry`).
//! - [`window_frame`]: a window's docks and stage and a moved window's frame (`WindowFrameGeometry`,
//!   `MovedWindowPlacement`).
//! - [`width_ledger`]: the R3b check that a create keeps other columns' widths (`ColumnWidthLedger`).

pub mod column_strip;
pub mod divider_band;
pub mod dock_strip;
pub mod drop_zones;
pub mod pane_chrome;
pub mod row_stack;
pub mod screen;
pub mod split_layout;
pub mod strip_math;
pub mod width_ledger;
pub mod window_frame;
pub mod wire;

#[cfg(test)]
mod split_tests;
#[cfg(test)]
mod strip_tests;
#[cfg(test)]
mod tests;

pub use crate::scroll::{swift_max, swift_min};
use serde::{Deserialize, Serialize};

/// A rectangle as `CGRect` stores it: origin and size. The edge getters standardize like `CGRect.minX`
/// and `maxX` (a negative size counts from the other edge).
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

/// A point.
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

/// A size.
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Size {
    pub width: f64,
    pub height: f64,
}

impl Point {
    pub const fn new(x: f64, y: f64) -> Self {
        Self { x, y }
    }
}

impl Rect {
    pub const fn new(x: f64, y: f64, w: f64, h: f64) -> Self {
        Self { x, y, w, h }
    }

    pub fn min_x(&self) -> f64 {
        swift_min(self.x, self.x + self.w)
    }
    pub fn max_x(&self) -> f64 {
        swift_max(self.x, self.x + self.w)
    }
    pub fn min_y(&self) -> f64 {
        swift_min(self.y, self.y + self.h)
    }
    pub fn max_y(&self) -> f64 {
        swift_max(self.y, self.y + self.h)
    }
    pub fn mid_x(&self) -> f64 {
        self.x + self.w / 2.
    }
    pub fn mid_y(&self) -> f64 {
        self.y + self.h / 2.
    }
    /// `CGRect.width`: never negative.
    pub fn width(&self) -> f64 {
        self.w.abs()
    }
    /// `CGRect.height`: never negative.
    pub fn height(&self) -> f64 {
        self.h.abs()
    }

    fn standardized(&self) -> Self {
        Self::new(self.min_x(), self.min_y(), self.width(), self.height())
    }

    /// `CGRect.isEmpty`: no area.
    pub fn is_empty(&self) -> bool {
        self.w == 0. || self.h == 0.
    }

    /// `CGRect.contains(_: CGPoint)`: the min edges are inside, the max edges outside.
    pub fn contains(&self, point: Point) -> bool {
        point.x >= self.min_x()
            && point.x < self.max_x()
            && point.y >= self.min_y()
            && point.y < self.max_y()
    }

    /// `CGRect.contains(_: CGRect)`: `other` lies wholly inside, edges included.
    pub fn contains_rect(&self, other: &Rect) -> bool {
        other.min_x() >= self.min_x()
            && other.max_x() <= self.max_x()
            && other.min_y() >= self.min_y()
            && other.max_y() <= self.max_y()
    }

    /// `CGRect.insetBy(dx:dy:)`; `None` where the Swift gives `CGRect.null` (a negative size).
    pub fn inset_by(&self, dx: f64, dy: f64) -> Option<Rect> {
        let r = self.standardized();
        let rect = Rect::new(r.x + dx, r.y + dy, r.w - dx * 2., r.h - dy * 2.);
        (rect.w >= 0. && rect.h >= 0.).then_some(rect)
    }

    /// `CGRect.offsetBy(dx:dy:)`.
    pub fn offset_by(&self, dx: f64, dy: f64) -> Rect {
        Rect::new(self.x + dx, self.y + dy, self.w, self.h)
    }

    /// `CGRect.intersection(_:)`; `None` for `CGRect.null` (no overlap; touching edges overlap with no
    /// area, as in Foundation).
    pub fn intersection(&self, other: &Rect) -> Option<Rect> {
        let min_x = swift_max(self.min_x(), other.min_x());
        let max_x = swift_min(self.max_x(), other.max_x());
        let min_y = swift_max(self.min_y(), other.min_y());
        let max_y = swift_min(self.max_y(), other.max_y());
        (max_x >= min_x && max_y >= min_y)
            .then(|| Rect::new(min_x, min_y, max_x - min_x, max_y - min_y))
    }
}

/// `SplitGeometry.roundToPixel`: the nearest device pixel (Swift `rounded()`, halves away from zero).
pub fn round_to_pixel(value: f64, scale: f64) -> f64 {
    if scale > 0. { (value * scale).round() / scale } else { value }
}

/// `SplitGeometry.ceilToPixel`: the device pixel at or after `value`, with 0.001 pixel of slack.
pub fn ceil_to_pixel(value: f64, scale: f64) -> f64 {
    if scale > 0. { (value * scale - 0.001).ceil() / scale } else { value }
}

/// `SplitGeometry.floorToPixel`: the device pixel at or before `value`, with 0.001 pixel of slack.
pub fn floor_to_pixel(value: f64, scale: f64) -> f64 {
    if scale > 0. { (value * scale + 0.001).floor() / scale } else { value }
}

/// `ColumnStripGeometry.pixelWidth`: a column's width for its fraction of the viewport.
pub fn column_pixel_width(fraction: f64, viewport_width: f64, gap: f64) -> f64 {
    swift_max(1., (viewport_width - gap) * fraction - gap)
}

/// The axis a split divides along: `Horizontal` lays its panes side by side.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SplitAxis {
    Horizontal,
    Vertical,
}

/// A viewport edge a dock sits at (Swift `DockEdge`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DockEdge {
    Left,
    Right,
    Top,
    Bottom,
}

impl DockEdge {
    /// Top and bottom: the dock is a horizontal band.
    pub fn is_band(self) -> bool {
        matches!(self, DockEdge::Top | DockEdge::Bottom)
    }
}

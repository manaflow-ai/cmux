//! A pane's chrome inside its cell (Swift `PaneChromeGeometry` and the `LayoutStyle` metrics in
//! `PaneChromeGeometry.swift`). A pane's frame (its cell) is what split and column geometry compute;
//! its tab strip and content sit in the cell inset by `pane_padding`.

use super::{Rect, swift_max, swift_min};
use serde::{Deserialize, Serialize};

/// The `LayoutStyle` values the pane chrome metrics read.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ChromeStyle {
    pub pane_padding: f64,
    pub column_gap: f64,
    pub divider_thickness: f64,
    pub divider_hit_thickness: f64,
    pub pane_corner_radius: f64,
}

impl Default for ChromeStyle {
    fn default() -> Self {
        Self {
            pane_padding: 0.,
            column_gap: 6.,
            divider_thickness: 1.,
            divider_hit_thickness: 7.,
            pane_corner_radius: 0.,
        }
    }
}

impl ChromeStyle {
    /// `stripGap`: the gap the column strip adds between and around columns, beyond what each pane's
    /// padding already brings.
    pub fn strip_gap(&self) -> f64 {
        swift_max(0., self.column_gap - self.pane_padding * 2.)
    }

    /// `effectiveDividerHitThickness`: at least the visible space between two padded panes.
    pub fn effective_divider_hit_thickness(&self) -> f64 {
        swift_max(self.divider_hit_thickness, self.pane_padding * 2. + self.divider_thickness)
    }

    /// `columnEdgeLineThickness`.
    pub fn column_edge_line_thickness(&self) -> f64 {
        column_edge_line_thickness(self.divider_thickness)
    }

    /// `columnEdgeHitThickness`: a column edge's drag area centered on the column gap.
    pub fn column_edge_hit_thickness(&self) -> f64 {
        swift_max(self.strip_gap() + self.pane_padding * 2., self.divider_hit_thickness)
    }
}

/// `LayoutStyle.columnEdgeLineThickness(dividerThickness:)`: at least 2 pt.
pub fn column_edge_line_thickness(divider_thickness: f64) -> f64 {
    swift_max(divider_thickness, 2.)
}

/// `contentRect(forCell:style:)`: the cell inset by the padding; a cell smaller than twice the padding
/// collapses to its center line.
pub fn content_rect(cell: Rect, pane_padding: f64) -> Rect {
    let dx = swift_min(pane_padding, cell.width() / 2.);
    let dy = swift_min(pane_padding, cell.height() / 2.);
    // Never a negative size: each inset is at most half the side.
    cell.inset_by(dx, dy).unwrap_or(Rect::new(cell.mid_x(), cell.mid_y(), 0., 0.))
}

/// `roundedRect(inPadded:headerHeight:footerHeight:leadingWidth:)`: the padded rect less its header on
/// top, its footer below and its vertical tab list on the leading edge.
pub fn rounded_rect(padded: Rect, header: f64, footer: f64, leading: f64) -> Rect {
    let top = swift_min(swift_max(0., header), padded.height());
    let bottom = swift_min(swift_max(0., footer), padded.height() - top);
    let leading = swift_min(swift_max(0., leading), padded.width());
    Rect::new(
        padded.min_x() + leading,
        padded.min_y() + top,
        padded.width() - leading,
        padded.height() - top - bottom,
    )
}

/// `cornerRadius(for:style:)`: at most half the shorter side.
pub fn corner_radius(rect: Rect, pane_corner_radius: f64) -> f64 {
    swift_max(0., swift_min(pane_corner_radius, swift_min(rect.width(), rect.height()) / 2.))
}

/// `hairlineWidth(scale:)`: one device pixel.
pub fn hairline_width(scale: f64) -> f64 {
    if scale > 0. { 1. / scale } else { 1. }
}

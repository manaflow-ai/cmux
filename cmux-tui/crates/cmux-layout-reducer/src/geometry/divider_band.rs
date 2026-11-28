//! The drawn line and the hit area of one resize handle, centered on the gap it resizes (Swift
//! `DividerBand`). Every pane resize handle (split dividers, column edges, dock edges, row edges) takes
//! its hit frame from here, so the line, the area that takes the mouse and the resize cursor share one
//! center. The line starts on a device pixel, and the hit area grows by the same whole number of device
//! pixels on both sides of it.

use super::{Rect, SplitAxis, ceil_to_pixel, round_to_pixel, swift_max};
use serde::Serialize;

/// A handle's line and hit area.
#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
pub struct DividerBand {
    pub line: Rect,
    pub hit: Rect,
}

impl DividerBand {
    /// A band centered on `center` along `axis` (`Horizontal`: a vertical line between side-by-side
    /// panes), `cross_length` long from `cross_start` on the other axis.
    pub fn new(
        axis: SplitAxis,
        center: f64,
        line_thickness: f64,
        hit_thickness: f64,
        cross_start: f64,
        cross_length: f64,
        scale: f64,
    ) -> Self {
        let thickness = swift_max(0., line_thickness);
        let line_start = round_to_pixel(center - thickness / 2., scale);
        let grow = ceil_to_pixel(swift_max(0., hit_thickness - thickness) / 2., scale);
        let rect = |start: f64, extent: f64| match axis {
            SplitAxis::Horizontal => Rect::new(start, cross_start, extent, cross_length),
            SplitAxis::Vertical => Rect::new(cross_start, start, cross_length, extent),
        };
        Self {
            line: rect(line_start, thickness),
            hit: rect(line_start - grow, thickness + grow * 2.),
        }
    }
}

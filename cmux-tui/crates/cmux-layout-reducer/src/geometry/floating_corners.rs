//! A floating pane card's four corner radii (Swift `FloatingPaneCorners`), each concentric with the
//! window's corner (`ConcentricCorners`). The card's path stays a Swift drawing.

use super::{Size, swift_max, swift_min};
use serde::Serialize;

/// `ConcentricCorners(outer:padding: 0)`'s `nested(in:inset:)`: a radius `inset` in from `radius`.
pub fn nested(radius: f64, inset: f64) -> f64 {
    swift_max(0., radius - inset)
}

/// `ConcentricCorners.radius(fitting:radius:)`: `radius` kept to half the shorter side.
pub fn fitting(size: Size, radius: f64) -> f64 {
    swift_max(0., swift_min(radius, swift_min(size.width, size.height) / 2.))
}

/// `FloatingPaneCorners`.
#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FloatingPaneCorners {
    pub top_left: f64,
    pub top_right: f64,
    pub bottom_left: f64,
    pub bottom_right: f64,
}

impl FloatingPaneCorners {
    /// `init(uniform:)`.
    pub fn uniform(radius: f64) -> Self {
        Self { top_left: radius, top_right: radius, bottom_left: radius, bottom_right: radius }
    }

    /// `init(size:left:top:right:bottom:windowRadius:floor:)`: a corner is concentric with the
    /// window's from the larger of its two edges' distances in, at least `floor`, kept inside the card.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        size: Size,
        left: f64,
        top: f64,
        right: f64,
        bottom: f64,
        window_radius: f64,
        floor: f64,
    ) -> Self {
        // `ConcentricCorners.init` keeps the outer radius at zero or more.
        let outer = swift_max(0., window_radius);
        let corner = |a: f64, b: f64| {
            fitting(size, swift_max(floor, nested(outer, swift_max(swift_max(0., a), b))))
        };
        Self {
            top_left: corner(left, top),
            top_right: corner(right, top),
            bottom_left: corner(left, bottom),
            bottom_right: corner(right, bottom),
        }
    }

    /// `largest`.
    pub fn largest(&self) -> f64 {
        swift_max(
            swift_max(swift_max(self.top_left, self.top_right), self.bottom_left),
            self.bottom_right,
        )
    }

    /// `contentRadius(inset:)`.
    pub fn content_radius(&self, inset: f64) -> f64 {
        swift_max(0., self.largest() - inset)
    }
}

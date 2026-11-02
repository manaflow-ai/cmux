//! The snapping and rubber-band math of a scrolling strip (Swift
//! `ColumnStripGeometry.projectedOffset`, `snapTarget`, `adjacentSnap`,
//! `rubberBand`). Offsets are the content-space x of the viewport's leading
//! edge; velocities are points per second, positive when the offset grows.

use super::{swift_max, swift_min_by};

/// The rate `UIScrollView.decelerationRate.normal` uses.
const DECELERATION_RATE: f64 = 0.998;
/// A release faster than this always advances at least one snap.
const FLING_THRESHOLD: f64 = 300.;

/// Where a fling released at `offset` with `velocity` would coast to.
pub fn projected_offset(offset: f64, velocity: f64) -> f64 {
    // RED: rule not ported yet.
    let _ = velocity;
    offset
}

/// The snap offset a release should settle on: the one nearest the projected
/// coast position. A fast fling always advances at least one snap point in
/// its direction. `snaps` ascend.
pub fn snap_target(release_offset: f64, velocity: f64, snaps: &[f64]) -> f64 {
    // RED: rule not ported yet.
    let _ = (velocity, snaps);
    release_offset
}

/// The adjacent snap offset from `offset` in `direction` (+1 or -1), for
/// discrete mouse wheel steps.
pub fn adjacent_snap(offset: f64, direction: i32, snaps: &[f64]) -> f64 {
    // RED: rule not ported yet.
    let _ = (direction, snaps);
    offset
}

/// Rubber-band resistance past the ends, like AppKit elastic scrolling.
pub fn rubber_band(offset: f64, content_width: f64, viewport_width: f64) -> f64 {
    // RED: rule not ported yet.
    let _ = (content_width, viewport_width);
    offset
}

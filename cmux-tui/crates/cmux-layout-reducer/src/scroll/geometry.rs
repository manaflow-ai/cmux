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
    offset + (velocity / 1000.) * DECELERATION_RATE / (1. - DECELERATION_RATE)
}

/// The snap offset a release should settle on: the one nearest the projected
/// coast position. A fast fling always advances at least one snap point in
/// its direction. `snaps` ascend.
pub fn snap_target(release_offset: f64, velocity: f64, snaps: &[f64]) -> f64 {
    let projected = projected_offset(release_offset, velocity);
    let Some(mut best) =
        swift_min_by(snaps.iter().copied(), |a, b| (a - projected).abs() < (b - projected).abs())
    else {
        return release_offset;
    };
    if velocity > FLING_THRESHOLD
        && best <= release_offset + 0.5
        && let Some(&next) = snaps.iter().find(|&&snap| snap > release_offset + 0.5)
    {
        best = next;
    } else if velocity < -FLING_THRESHOLD
        && best >= release_offset - 0.5
        && let Some(&previous) = snaps.iter().rev().find(|&&snap| snap < release_offset - 0.5)
    {
        best = previous;
    }
    best
}

/// The adjacent snap offset from `offset` in `direction` (+1 or -1), for
/// discrete mouse wheel steps.
pub fn adjacent_snap(offset: f64, direction: i32, snaps: &[f64]) -> f64 {
    if direction > 0 {
        return snaps
            .iter()
            .copied()
            .find(|&snap| snap > offset + 0.5)
            .or_else(|| snaps.last().copied())
            .unwrap_or(offset);
    }
    snaps
        .iter()
        .rev()
        .copied()
        .find(|&snap| snap < offset - 0.5)
        .or_else(|| snaps.first().copied())
        .unwrap_or(offset)
}

/// Rubber-band resistance past the ends, like AppKit elastic scrolling.
pub fn rubber_band(offset: f64, content_width: f64, viewport_width: f64) -> f64 {
    let upper = swift_max(0., content_width - viewport_width);
    let dimension = swift_max(viewport_width, 1.);
    let resist = |overshoot: f64| (1. - 1. / (overshoot * 0.55 / dimension + 1.)) * dimension;
    if offset < 0. {
        return -resist(-offset);
    }
    if offset > upper {
        return upper + resist(offset - upper);
    }
    offset
}

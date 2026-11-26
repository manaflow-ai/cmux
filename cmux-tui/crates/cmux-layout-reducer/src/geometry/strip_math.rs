//! Column strip drag math: trading width with the next column and one shared width (Swift
//! `StripStart`), the uniform width that rests a dragged column edge under the pointer
//! (`UniformEdge`), and the panes kept alive around the viewport (`KeepAliveBand`).

use super::split_layout::{DividerDragValue, WIDTH_RANGE};
use super::{Rect, swift_max, swift_min};
use crate::scroll::anchor_shift;
use crate::shown_resize::{fraction, pixel_width};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

/// `StripStart.Column`: a column's width share and its minimum in points.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct StripColumn {
    pub id: String,
    pub width: f64,
    pub minimum: f64,
}

/// `StripStart`: the strip's columns when a column-edge drag began.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct StripStart {
    pub columns: Vec<StripColumn>,
    pub viewport: f64,
    pub gap: f64,
}

impl StripStart {
    fn points(&self, fraction: f64) -> f64 {
        pixel_width(fraction, self.viewport, self.gap)
    }

    fn fraction(&self, points: f64) -> f64 {
        fraction(points, self.viewport, self.gap)
    }

    /// `next(after:)`.
    pub fn next(&self, column: &str) -> Option<&StripColumn> {
        let index = self.columns.iter().position(|c| c.id == column)?;
        self.columns.get(index + 1)
    }

    /// `trading(_:to:)`: `column` takes `width` from the next column, which keeps its minimum and the
    /// widest share; the last column has no neighbor and just takes `width`.
    pub fn trading(&self, column: &str, width: f64) -> Vec<DividerDragValue> {
        let (Some(start), Some(next)) =
            (self.columns.iter().find(|c| c.id == column), self.next(column))
        else {
            return vec![DividerDragValue::Width { id: column.to_string(), value: width }];
        };
        let widest = self.points(WIDTH_RANGE.1);
        let mut delta = self.points(width) - self.points(start.width);
        let next_start = self.points(next.width);
        delta = swift_min(delta, next_start - swift_max(next.minimum, self.points(WIDTH_RANGE.0)));
        delta = swift_max(delta, next_start - widest);
        // `column` stays within the widest share too: past it, the next column would give up points
        // `column` never takes.
        delta = swift_min(delta, widest - self.points(start.width));
        vec![
            DividerDragValue::Width {
                id: column.to_string(),
                value: self.fraction(self.points(start.width) + delta),
            },
            DividerDragValue::Width {
                id: next.id.clone(),
                value: self.fraction(next_start - delta),
            },
        ]
    }

    /// `uniform(_:)`: every column at one width, at least the widest minimum.
    pub fn uniform(&self, width: f64) -> Vec<DividerDragValue> {
        let floor = self
            .columns
            .iter()
            .map(|c| self.fraction(c.minimum))
            .reduce(|best, value| if value > best { value } else { best })
            .unwrap_or(width);
        let shared = swift_max(width, floor);
        self.columns
            .iter()
            .map(|c| DividerDragValue::Width { id: c.id.clone(), value: shared })
            .collect()
    }
}

/// `UniformEdge`: a command-drag of column `index`'s trailing edge that gives every column one width.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct UniformEdge {
    pub widths: Vec<f64>,
    pub index: usize,
    pub left: f64,
    pub content: f64,
    pub viewport: f64,
    pub camera: f64,
    /// The offset the camera shows this frame; `None` takes `camera` (at rest).
    pub shown: Option<f64>,
}

/// `UniformEdge.Target`: a uniform width, or keep every width as it is.
#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum UniformTarget {
    Width(f64),
    Keep,
}

impl UniformEdge {
    fn shown(&self) -> f64 {
        self.shown.unwrap_or(self.camera)
    }

    /// `shift(_:)`: how far column `index` moves when every column before it is `width` wide.
    pub fn shift(&self, width: f64) -> f64 {
        self.widths[..self.index].iter().fold(0., |sum, w| sum + width - w)
    }

    /// `maxOffset(_:)`.
    pub fn max_offset(&self, width: f64) -> f64 {
        swift_max(
            0.,
            self.content + self.widths.iter().fold(0., |sum, w| sum + width - w) - self.viewport,
        )
    }

    /// `cameraShift(_:)`.
    pub fn camera_shift(&self, width: f64) -> f64 {
        anchor_shift(self.shift(width), self.camera, self.max_offset(width))
    }

    /// `presented(_:)`: the offset shown this frame at `width`.
    pub fn presented(&self, width: f64) -> f64 {
        self.shown() + self.camera_shift(width)
    }

    /// `addsTravel(_:)`: `width` would add camera travel the spring then plays out.
    pub fn adds_travel(&self, width: f64) -> bool {
        let target = swift_min(
            swift_max(self.camera + self.camera_shift(width), 0.),
            self.max_offset(width),
        );
        let before = self.camera - self.shown();
        let after = target - self.presented(width);
        after < swift_min(0., before) - 0.01 || after > swift_max(0., before) + 0.01
    }

    /// `edge(_:)`: the edge's place on screen at `width`.
    pub fn edge(&self, width: f64) -> f64 {
        self.left + self.shift(width) + width - self.presented(width)
    }

    /// `target(restingEdgeAt:)`.
    pub fn target(&self, place: f64) -> UniformTarget {
        self.solve(place).map_or(UniformTarget::Keep, UniformTarget::Width)
    }

    /// `width(restingEdgeAt:)`.
    pub fn width(&self, place: f64) -> Option<f64> {
        self.solve(place)
    }

    fn solve(&self, place: f64) -> Option<f64> {
        let k = self.index as f64;
        let n = self.widths.len() as f64;
        let before: f64 = self.widths[..self.index].iter().fold(0., |sum, w| sum + w);
        let all: f64 = self.widths.iter().fold(0., |sum, w| sum + w);
        let shown = self.shown();
        let base = place - self.left + before + shown;
        let mut candidates =
            vec![place - self.left + shown, (base - self.camera) / (k + 1.), base / (k + 1.)];
        if k + 1. != n {
            candidates
                .push((base + self.content - all - self.viewport - self.camera) / (k + 1. - n));
        }
        let current = self.widths[self.index];
        let reach = (place - self.edge(current)).abs() + 0.01;
        candidates
            .into_iter()
            .find(|&c| {
                c > 0.
                    && (c - current).abs() <= reach
                    && (self.edge(c) - place).abs() < 0.01
                    && !self.adds_travel(c)
            })
            .or_else(|| (!self.adds_travel(current)).then_some(current))
    }
}

/// `KeepAliveBand.panes(displayed:viewport:)`: the panes within one viewport width of the viewport
/// on either side.
pub fn keep_alive(displayed: &BTreeMap<String, Rect>, viewport: Rect) -> BTreeSet<String> {
    if viewport.width() <= 0. || viewport.height() <= 0. {
        return BTreeSet::new();
    }
    let Some(band) = viewport.inset_by(-viewport.width(), 0.) else { return BTreeSet::new() };
    displayed
        .iter()
        .filter(|(_, frame)| {
            frame
                .intersection(&band)
                .is_some_and(|overlap| overlap.width() > 0.5 && overlap.height() > 0.5)
        })
        .map(|(pane, _)| pane.clone())
        .collect()
}

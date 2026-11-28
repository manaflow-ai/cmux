//! A column of rows (Swift `RowStackGeometry`) and a row-edge drag's new heights (`RowResize`).
//! Row heights are permille of the column's height, gaps included.

use super::divider_band::DividerBand;
use super::{Rect, SplitAxis, ceil_to_pixel, round_to_pixel, swift_max, swift_min};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// `LayoutRow.heightRange`.
pub const HEIGHT_RANGE: (i64, i64) = (100, 1000);

/// A row's id and permille height (the `LayoutRow` fields geometry reads).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Row {
    pub id: String,
    pub height: i64,
}

/// `RowFrame`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct RowFrame {
    pub id: String,
    pub frame: Rect,
}

/// `RowEdgeGeometry`: the drag area between two rows.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RowEdge {
    pub column: String,
    pub upper: String,
    pub lower: String,
    pub hit_frame: Rect,
}

/// `RowStackGeometry`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RowStack {
    pub column: String,
    pub frame: Rect,
    pub rows: Vec<RowFrame>,
    pub content_height: f64,
    pub gap: f64,
}

/// `RowStackGeometry.pixelHeight(permille:columnHeight:gap:)`.
pub fn pixel_height(permille: f64, column_height: f64, gap: f64) -> f64 {
    swift_max(1., (column_height + gap) * permille / 1000. - gap)
}

/// `RowStackGeometry.permille(forPixelHeight:columnHeight:gap:)`, kept in [`HEIGHT_RANGE`].
pub fn permille(height: f64, column_height: f64, gap: f64) -> i64 {
    let denominator = column_height + gap;
    if denominator <= 0. {
        return HEIGHT_RANGE.1;
    }
    let value = ((height + gap) / denominator * 1000.).round() as i64;
    value.max(HEIGHT_RANGE.0).min(HEIGHT_RANGE.1)
}

impl RowStack {
    /// `scrolls`.
    pub fn scrolls(&self) -> bool {
        self.content_height > self.frame.height() + 0.5
    }

    /// `maxOffset`.
    pub fn max_offset(&self) -> f64 {
        swift_max(0., self.content_height - self.frame.height())
    }

    /// `RowStackGeometry.compute(column:rows:minimumHeights:in:gap:fits:scale:)`.
    pub fn compute(
        column: &str,
        rows: &[Row],
        minimum_heights: &[f64],
        frame: Rect,
        gap: f64,
        fits: bool,
        scale: f64,
    ) -> Self {
        let sum: i64 = rows.iter().map(|row| row.height.max(1)).sum();
        let fill = fits || sum <= 1000;
        let factor = if fill && sum > 0 { 1000. / sum as f64 } else { 1. };
        let mut heights: Vec<f64> = rows
            .iter()
            .map(|row| {
                round_to_pixel(
                    pixel_height(row.height.max(1) as f64 * factor, frame.height(), gap),
                    scale,
                )
            })
            .collect();
        let with_minimums: Vec<f64> = heights
            .iter()
            .enumerate()
            .map(|(index, &height)| match minimum_heights.get(index) {
                Some(&minimum) => swift_max(height, ceil_to_pixel(minimum, scale)),
                None => height,
            })
            .collect();
        let available = frame.height() - gap * rows.len().saturating_sub(1) as f64;
        if !fits || with_minimums.iter().sum::<f64>() <= available + 0.5 {
            heights = with_minimums;
        }
        let total: f64 = heights.iter().sum();
        let mut y = frame.min_y();
        let mut placed = Vec::with_capacity(rows.len());
        for (index, row) in rows.iter().enumerate() {
            let mut height = heights[index];
            // A filled stack ends exactly at the column's bottom edge.
            if fill && index == rows.len() - 1 && total <= available + 0.5 {
                height = swift_max(1., frame.max_y() - y);
            }
            placed.push(RowFrame {
                id: row.id.clone(),
                frame: Rect::new(frame.min_x(), y, frame.width(), height),
            });
            y += height + gap;
        }
        let content =
            placed.last().map_or(frame.height(), |last| last.frame.max_y() - frame.min_y());
        Self {
            column: column.to_string(),
            frame,
            rows: placed,
            content_height: if fits { swift_min(content, frame.height()) } else { content },
            gap,
        }
    }

    /// `edges(lineThickness:hitThickness:scale:)`: one drag area between each pair of rows.
    pub fn edges(&self, line_thickness: f64, hit_thickness: f64, scale: f64) -> Vec<RowEdge> {
        self.rows
            .windows(2)
            .map(|pair| {
                let (upper, lower) = (&pair[0], &pair[1]);
                let mid = (upper.frame.max_y() + lower.frame.min_y()) / 2.;
                let band = DividerBand::new(
                    SplitAxis::Vertical,
                    mid,
                    line_thickness,
                    hit_thickness,
                    self.frame.min_x(),
                    self.frame.width(),
                    scale,
                );
                RowEdge {
                    column: self.column.clone(),
                    upper: upper.id.clone(),
                    lower: lower.id.clone(),
                    hit_frame: band.hit,
                }
            })
            .collect()
    }
}

/// `RowResize.heights(_:stack:upper:pointerY:minimums:fits:)`: every row's height once the edge
/// under `upper` follows the pointer. A filled stack trades between the two rows; an overflowing one
/// grows or shrinks `upper` alone.
pub fn resize_heights(
    rows: &[Row],
    stack: &RowStack,
    upper: &str,
    pointer_y: f64,
    minimums: &HashMap<String, f64>,
    fits: bool,
) -> Vec<Row> {
    let mut result = rows.to_vec();
    let Some(index) = rows.iter().position(|row| row.id == upper) else { return result };
    if index + 1 >= rows.len() || index + 1 >= stack.rows.len() {
        return result;
    }
    let floor = HEIGHT_RANGE.0;
    let upper_frame = stack.rows[index].frame;
    let min_upper = minimums.get(upper).copied().unwrap_or(0.);
    let sum: i64 = rows.iter().map(|row| row.height).sum();
    if fits || sum <= 1000 {
        let lower_frame = stack.rows[index + 1].frame;
        let pair_pixels = upper_frame.height() + lower_frame.height();
        let min_lower = minimums.get(&rows[index + 1].id).copied().unwrap_or(0.);
        let mut pixels = pointer_y - upper_frame.min_y();
        pixels = if min_upper + min_lower <= pair_pixels {
            swift_min(swift_max(pixels, min_upper), pair_pixels - min_lower)
        } else {
            swift_min(swift_max(pixels, 0.), pair_pixels)
        };
        let pair = rows[index].height + rows[index + 1].height;
        if pair < floor * 2 || pair_pixels <= 0. {
            return result;
        }
        let share =
            ((pair as f64 * (pixels / pair_pixels)).round() as i64).max(floor).min(pair - floor);
        result[index].height = share;
        result[index + 1].height = pair - share;
    } else {
        let pixels = swift_max(pointer_y - upper_frame.min_y(), min_upper);
        result[index].height = permille(pixels, stack.frame.height(), stack.gap);
    }
    result
}

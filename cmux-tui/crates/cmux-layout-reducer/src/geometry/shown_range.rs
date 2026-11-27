//! What a resize may set so the screen shows something new (Swift `ShownResizeRange`): it reads the
//! divider, column, dock and row stack from a placed screen and runs the `shown_resize` rules over
//! them, and checks a column trade by placing it.

use super::SplitAxis;
use super::dock_strip::DockMode;
use super::screen::{Column, ScreenGeometry, ScreenLayout, ScreenStyle};
use super::split_layout;
use crate::shown_resize::{self, Bounds, DockSide, RowInput, TradeInput};

/// `ShownResizeRange`: a placed screen, its style, the pixel scale and where the strip's camera
/// rests.
pub struct ShownResizeRange<'a> {
    pub geometry: &'a ScreenGeometry,
    pub style: &'a ScreenStyle,
    pub scale: f64,
    pub strip_offset: Option<f64>,
}

impl ShownResizeRange<'_> {
    /// `ratio(of:)`: the ratios of `split` that place its divider somewhere new.
    pub fn ratio(&self, split: &str) -> Option<Bounds> {
        let divider = self.geometry.dividers.iter().find(|divider| divider.id == split)?;
        let horizontal = divider.axis == SplitAxis::Horizontal;
        shown_resize::ratio(
            if horizontal { divider.container.width() } else { divider.container.height() },
            if horizontal { divider.frame.width() } else { divider.frame.height() },
            divider.minimum_a,
            divider.minimum_b,
        )
    }

    /// `width(of:)`: the width shares of a strip column that show as different widths.
    pub fn width(&self, column: &Column) -> Option<Bounds> {
        shown_resize::column_width(
            self.geometry.is_columns,
            column.dock.is_some(),
            self.geometry.strip_width,
            column.minimum_size(self.style).width,
            self.style.chrome().strip_gap(),
        )
    }

    /// `trade(_:_:by:in:)`: the two width shares a key press on the edge between neighbor columns
    /// sets, the first candidate pair that, placed, moves only that edge.
    pub fn trade(
        &self,
        left: &Column,
        right: &Column,
        delta: f64,
        layout: &ScreenLayout,
    ) -> Option<(f64, f64)> {
        let left_frame = self.geometry.columns.get(&left.id)?;
        let right_frame = self.geometry.columns.get(&right.id)?;
        let input = TradeInput {
            is_columns: self.geometry.is_columns,
            strip_width: self.geometry.strip_width,
            gap: self.style.chrome().strip_gap(),
            scale: self.scale,
            delta,
            left_min_x: left_frame.min_x(),
            left_max_x: left_frame.max_x(),
            left_width: left_frame.width(),
            right_min_x: right_frame.min_x(),
            right_max_x: right_frame.max_x(),
            right_width: right_frame.width(),
            left_minimum_width: left.minimum_size(self.style).width,
            right_minimum_width: right.minimum_size(self.style).width,
            left_fraction: left.width,
            right_fraction: right.width,
            strip_offset: self.strip_offset,
            uncovered_min_x: self.geometry.uncovered_min_x,
            uncovered_max_x: self.geometry.uncovered_max_x,
            strip_min_x: self.geometry.strip_min_x,
        };
        let candidates = shown_resize::trade(&input)?;
        [candidates.first, candidates.second].into_iter().find(|&(left_width, right_width)| {
            let candidate =
                layout.setting_width(left_width, &left.id).setting_width(right_width, &right.id);
            self.moves_only_the_divider(&candidate, &left.id, &right.id, candidates.move_points)
        })
    }

    /// `movesOnlyTheDivider`: placed, `candidate` keeps both columns' outer edges and every other
    /// column's frame and moves their shared edge by `by`.
    fn moves_only_the_divider(
        &self,
        candidate: &ScreenLayout,
        left: &str,
        right: &str,
        by: f64,
    ) -> bool {
        let placed =
            ScreenGeometry::compute(candidate, self.geometry.viewport, self.style, self.scale);
        let (Some(l0), Some(r0), Some(l1), Some(r1)) = (
            self.geometry.columns.get(left),
            self.geometry.columns.get(right),
            placed.columns.get(left),
            placed.columns.get(right),
        ) else {
            return false;
        };
        let same = |a: f64, b: f64| (a - b).abs() < 0.001;
        if !(same(l1.min_x(), l0.min_x())
            && same(r1.max_x(), r0.max_x())
            && same(l1.max_x(), l0.max_x() + by)
            && same(r1.min_x(), r0.min_x() + by))
        {
            return false;
        }
        self.geometry
            .columns
            .iter()
            .all(|(id, frame)| id == left || id == right || placed.columns.get(id) == Some(frame))
    }

    /// `dockWidth(of:)`: the width shares of a side dock that show as different widths.
    pub fn dock_width(&self, column: &Column) -> Option<Bounds> {
        let sides: Vec<DockSide> = self
            .geometry
            .dock
            .iter()
            .map(|dock| DockSide {
                is_target: dock.column == column.id,
                is_band: dock.edge.is_band(),
                is_docked: dock.mode == DockMode::Docked,
                width: dock.frame.width(),
            })
            .collect();
        shown_resize::dock_width(
            sides,
            self.geometry.viewport.width,
            self.style.chrome().strip_gap(),
            column.minimum_size(self.style).width,
        )
    }

    /// `rowHeights(moving:in:by:)`: every row's id and permille after a key press on the row edge
    /// next to `pane`'s row.
    pub fn row_heights(
        &self,
        pane: &str,
        column: &Column,
        delta: f64,
    ) -> Option<Vec<(String, i64)>> {
        if !column.has_rows() {
            return None;
        }
        let stack = self.geometry.row_stacks.get(&column.id)?;
        let index = column.rows.iter().position(|row| row.root.contains(pane))?;
        let heights: Vec<i64> = column.rows.iter().map(|row| row.height).collect();
        let minimum_heights: Vec<f64> = column
            .rows
            .iter()
            .map(|row| split_layout::minimum_size(&row.root, &self.style.split()).height)
            .collect();
        let input = RowInput {
            heights: &heights,
            minimum_heights: &minimum_heights,
            pane_row: index,
            rows_enabled: self.style.rows_enabled,
            column_height: stack.frame.height(),
            gap: stack.gap,
            scale: self.scale,
            delta,
        };
        let mut out = vec![0; heights.len()];
        if !shown_resize::row_heights(&input, &mut out) {
            return None;
        }
        Some(column.rows.iter().map(|row| row.id.clone()).zip(out).collect())
    }
}

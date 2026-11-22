//! The column strip of one screen as the scroll reducer sees it (Swift
//! `ColumnStrip`): content-space column frames in order, the panes inside
//! each column, the viewport width and the gap. The panes of all columns sit
//! in one flat list (`panes`, a range per column), so the C ABI refills a
//! strip in place with no allocation per call.

use super::{swift_max, swift_min};
use crate::{ColumnId, PaneId};
use std::ops::Range;

/// A rectangle as `CGRect` stores it. The edge getters standardize like
/// `CGRect.minX`/`maxX`/`width` (a negative width counts from the other edge).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Rect {
    pub const fn new(x: f64, y: f64, width: f64, height: f64) -> Self {
        Self { x, y, width, height }
    }

    pub fn min_x(&self) -> f64 {
        swift_min(self.x, self.x + self.width)
    }

    pub fn max_x(&self) -> f64 {
        swift_max(self.x, self.x + self.width)
    }

    pub fn mid_x(&self) -> f64 {
        self.x + self.width / 2.
    }

    pub fn min_y(&self) -> f64 {
        swift_min(self.y, self.y + self.height)
    }

    /// `CGRect.width`: never negative.
    pub fn w(&self) -> f64 {
        self.width.abs()
    }

    /// `CGRect.height`: never negative.
    pub fn h(&self) -> f64 {
        self.height.abs()
    }
}

/// The presentation axis before transposition; row cameras animate without
/// horizontal carry compensation.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Axis {
    #[default]
    Horizontal,
    Vertical,
}

/// One pane of a column. `listed` panes are the column's `panes` (layout
/// order); `frame` is its entry in `paneFrames`. A pane with a frame that is
/// not listed comes after the listed ones.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct StripPane {
    pub id: PaneId,
    pub frame: Option<Rect>,
    pub listed: bool,
}

/// One column: its id, its content-space frame and its panes in `panes`.
#[derive(Clone, Debug, PartialEq)]
pub struct StripColumn {
    pub id: ColumnId,
    pub frame: Rect,
    pub panes: Range<usize>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct ColumnStrip {
    pub columns: Vec<StripColumn>,
    /// The panes of every column, column by column.
    pub panes: Vec<StripPane>,
    pub viewport_width: f64,
    pub content_width: f64,
    pub gap: f64,
    pub axis: Axis,
    /// How much of the viewport's leading and trailing ends a floating side
    /// dock covers (layout-model.md F6). Reveal, visibility and snapping
    /// measure against the uncovered window between them; 0 without one.
    pub leading_cover: f64,
    pub trailing_cover: f64,
}

impl ColumnStrip {
    /// An empty strip with these measures (no columns, no covers).
    pub fn new(viewport_width: f64, content_width: f64, gap: f64) -> Self {
        Self { viewport_width, content_width, gap, ..Self::default() }
    }

    /// Empties the strip and sets its measures, keeping the buffers.
    pub fn reset(&mut self, viewport_width: f64, content_width: f64, gap: f64) {
        self.columns.clear();
        self.panes.clear();
        self.viewport_width = viewport_width;
        self.content_width = content_width;
        self.gap = gap;
        self.axis = Axis::Horizontal;
        self.leading_cover = 0.;
        self.trailing_cover = 0.;
    }

    /// Appends a column with these panes.
    pub fn push_column(
        &mut self,
        id: ColumnId,
        frame: Rect,
        panes: impl IntoIterator<Item = StripPane>,
    ) {
        let start = self.panes.len();
        self.panes.extend(panes);
        self.columns.push(StripColumn { id, frame, panes: start..self.panes.len() });
    }

    /// Appends a column whose listed panes all have a frame.
    pub fn push_framed(&mut self, id: ColumnId, frame: Rect, panes: &[(PaneId, Rect)]) {
        self.push_column(
            id,
            frame,
            panes.iter().map(|&(id, frame)| StripPane { id, frame: Some(frame), listed: true }),
        );
    }

    /// The panes of column `index`.
    pub fn column_panes(&self, index: usize) -> &[StripPane] {
        self.columns
            .get(index)
            .and_then(|column| self.panes.get(column.panes.clone()))
            .unwrap_or(&[])
    }

    /// The column's frame of `pane` (`paneFrames[pane]`).
    pub fn pane_frame(&self, index: usize, pane: PaneId) -> Option<Rect> {
        self.column_panes(index)
            .iter()
            .find(|entry| entry.id == pane && entry.frame.is_some())?
            .frame
    }

    /// The column's first listed pane (`panes.first`).
    pub fn first_pane(&self, index: usize) -> Option<PaneId> {
        self.column_panes(index).iter().find(|entry| entry.listed).map(|entry| entry.id)
    }

    /// Width of the uncovered window.
    pub fn visible_width(&self) -> f64 {
        swift_max(1., self.viewport_width - self.leading_cover - self.trailing_cover)
    }

    pub fn max_offset(&self) -> f64 {
        swift_max(0., self.content_width - self.viewport_width)
    }

    pub fn clamp(&self, offset: f64) -> f64 {
        swift_min(swift_max(offset, 0.), self.max_offset())
    }

    /// The frame of column `index`.
    pub fn frame_at(&self, index: usize) -> Option<Rect> {
        self.columns.get(index).map(|column| column.frame)
    }

    /// The id of column `index`.
    pub fn id_at(&self, index: usize) -> Option<ColumnId> {
        self.columns.get(index).map(|column| column.id)
    }

    /// The frame of the column with this id.
    pub fn frame_of(&self, column: ColumnId) -> Option<Rect> {
        self.columns.iter().find(|entry| entry.id == column).map(|entry| entry.frame)
    }

    pub fn index_of(&self, column: ColumnId) -> Option<usize> {
        self.columns.iter().position(|entry| entry.id == column)
    }

    /// The column holding `pane`, listed or framed.
    pub fn index_of_pane(&self, pane: PaneId) -> Option<usize> {
        (0..self.columns.len())
            .find(|&index| self.column_panes(index).iter().any(|entry| entry.id == pane))
    }

    /// A column at least as wide as the viewport cannot show whole (it is
    /// left-aligned). Narrower columns shrink their padding instead.
    pub fn is_wide(&self, frame: Rect) -> bool {
        frame.w() >= self.visible_width() - 0.5
    }

    /// Padding: the gap, shrunk when the column is nearly as wide as the view.
    pub fn padding(&self, width: f64) -> f64 {
        swift_min(swift_max((self.visible_width() - width) / 2., 0.), self.gap)
    }

    /// True when `rect` (with its padding) lies inside the viewport at `offset`.
    pub fn is_fully_visible(&self, rect: Rect, offset: f64) -> bool {
        let pad = self.padding(rect.w());
        rect.min_x() - pad >= offset + self.leading_cover - 0.5
            && rect.max_x() + pad <= offset + self.leading_cover + self.visible_width() + 0.5
    }

    /// A column counts as visible when it shows whole, or when it is wider
    /// than the view and covers all of it.
    pub fn is_column_visible(&self, index: usize, offset: f64) -> bool {
        let Some(column) = self.columns.get(index) else { return false };
        let frame = column.frame;
        if self.is_wide(frame) {
            return frame.min_x() <= offset + self.leading_cover + 0.5
                && frame.max_x() >= offset + self.leading_cover + self.visible_width() - 0.5;
        }
        self.is_fully_visible(frame, offset)
    }

    /// Relative order of the columns present in both strips is unchanged
    /// (only insertions, removals and width changes happened).
    pub fn keeps_order(&self, other: &ColumnStrip) -> bool {
        let mine = self.columns.iter().map(|c| c.id).filter(|id| other.index_of(*id).is_some());
        let theirs = other.columns.iter().map(|c| c.id).filter(|id| self.index_of(*id).is_some());
        mine.eq(theirs)
    }
}

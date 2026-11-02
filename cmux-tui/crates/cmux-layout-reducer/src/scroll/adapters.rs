//! The two adapters that feed the column scroll reducer something other
//! than a screen's columns: a column's rows on the vertical axis (Swift
//! `RowScroll`, plans/cmux-next/rows.md V1, V2) and the cells of a scroll
//! area (Swift `ScrollAreaScroll`, scroll-areas-DESIGN.md S5).

use super::state::ColumnScrollState;
use super::strip::{Axis, ColumnStrip, Rect};
use crate::ColumnId;

pub use crate::RowId;

/// The column id of a scroll-area cell with no pane (Swift
/// `ColumnID("area-cell:")`): such cells share it, as in Swift.
pub const EMPTY_AREA_CELL: ColumnId = ColumnId::MAX;

/// The vertical scroll of one column's rows. The reducer speaks column ids,
/// so each live row gets an opaque strip slot id (never derived from the row
/// id) that stays stable while the row lives, which keeps the reducer's
/// camera anchor and remembered focus per row.
#[derive(Clone, Debug, Default)]
pub struct RowScroll {
    pub state: ColumnScrollState,
    slots: Vec<(RowId, ColumnId)>,
    next_slot: ColumnId,
}

impl RowScroll {
    pub fn new() -> Self {
        Self::default()
    }

    /// The row a strip slot stands for.
    pub fn row_for_slot(&self, slot: ColumnId) -> Option<RowId> {
        self.slots.iter().find(|(_, s)| *s == slot).map(|(row, _)| *row)
    }

    /// The rows of a column as a strip on the vertical axis, x and y swapped
    /// and measured from the column's top (`top`, the stack frame's min y).
    /// `rows` holds one column per row of the column, in order: its id is
    /// the row id, its frame and its panes' frames are in window space, and
    /// its measures are the stack's (`viewport_width` the stack frame's
    /// height, `content_width` its content height, `gap` its gap). Assigns
    /// slots to new rows and drops those of rows that left. Reuses `rows`'s
    /// buffers.
    pub fn strip(&mut self, mut rows: ColumnStrip, top: f64) -> ColumnStrip {
        self.slots.retain(|(row, _)| rows.index_of(*row).is_some());
        let transposed =
            |rect: Rect| Rect::new(rect.min_y() - top, rect.min_x(), rect.h(), rect.w());
        for column in &mut rows.columns {
            column.id = self.slot(column.id);
            column.frame = transposed(column.frame);
            if let Some(panes) = rows.panes.get_mut(column.panes.clone()) {
                for pane in panes {
                    pane.frame = pane.frame.map(transposed);
                }
            }
        }
        rows.axis = Axis::Vertical;
        rows.leading_cover = 0.;
        rows.trailing_cover = 0.;
        rows
    }

    fn slot(&mut self, row: RowId) -> ColumnId {
        if let Some((_, slot)) = self.slots.iter().find(|(r, _)| *r == row) {
            return *slot;
        }
        self.next_slot = self.next_slot.wrapping_add(1);
        self.slots.push((row, self.next_slot));
        self.next_slot
    }

    /// The rows that hold a slot (the C ABI keeps their ids interned).
    pub fn rows(&self) -> impl Iterator<Item = RowId> + '_ {
        self.slots.iter().map(|(row, _)| *row)
    }
}

/// The horizontal scroll of one scroll area: the area's cells are the
/// reducer's columns, measured from the window's leading edge, so reveal,
/// camera anchor, snapping and focus-after-scroll are the column strip's
/// rules.
#[derive(Clone, Debug, Default)]
pub struct ScrollAreaScroll {
    pub state: ColumnScrollState,
}

impl ScrollAreaScroll {
    pub fn new() -> Self {
        Self::default()
    }

    /// The area as a strip the reducer reads. `cells` holds one column per
    /// cell in window space (its id is ignored), with the area's measures
    /// (`viewport_width` the window's width, `content_width` the area's,
    /// `gap` 0); `window_min_x` is the window's leading edge. Each cell
    /// becomes a column whose id is its first pane, so the reducer's camera
    /// anchor and remembered focus follow the cell while it keeps that pane.
    pub fn strip(&self, mut cells: ColumnStrip, window_min_x: f64) -> ColumnStrip {
        let local = |rect: Rect| Rect { x: rect.x - window_min_x, ..rect };
        for column in &mut cells.columns {
            let panes = cells.panes.get(column.panes.clone()).unwrap_or(&[]);
            column.id =
                panes.iter().find(|pane| pane.listed).map_or(EMPTY_AREA_CELL, |pane| pane.id);
            column.frame = local(column.frame);
            if let Some(panes) = cells.panes.get_mut(column.panes.clone()) {
                for pane in panes {
                    pane.frame = pane.frame.map(local);
                }
            }
        }
        cells.axis = Axis::Horizontal;
        cells.leading_cover = 0.;
        cells.trailing_cover = 0.;
        cells
    }
}

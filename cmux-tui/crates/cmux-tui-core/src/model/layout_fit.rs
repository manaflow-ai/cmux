//! Fitting a new column into the window (`pane.split` with `fit`, the
//! CLI's `split --right --fit`, MCP `open` and the CLI's beside-the-chat
//! placement).
//!
//! A screen that has never scrolled is one full-width column (width 1.0).
//! Agents used to add a column beside it at `viewport_width` 0.5, which made
//! the row 1.5 viewports wide, and a second one 2.0: the person's panes
//! became a sideways-scrolling strip they never asked for (Aziz 2026-11-06:
//! "I want them to open as new panes, just not as a column that is
//! scrollable like that"). A `fit` column, on a screen whose scrolling
//! columns fit the window, makes room: it gets an equal share (`1 / n` of
//! the strip) and the columns there shrink in proportion, so the strip
//! still sums to the window. A screen that already scrolls keeps its
//! columns and takes the new one at half the window. An explicit
//! `viewport_width` is always kept as asked, and the app's own New Column
//! never comes through here: it keeps its rule that a new column resizes
//! no column (R3b).
//!
//! Widths of scrolling columns are shares of the strip (the window minus
//! docked columns), so "fits" means they sum to at most 1. Docked and band
//! columns keep their widths.

use super::{LayoutColumn, Screen};
use crate::SplitId;
use crate::layout::MIN_VIEWPORT_PANE_WIDTH;

/// Slack for float sums (`0.5 + 0.5` stored as f32).
const FIT_EPSILON: f32 = 1e-3;

fn is_strip(column: &LayoutColumn) -> bool {
    column.dock.is_none()
}

impl Screen {
    /// Whether the screen's scrolling columns fit in the window now: a split
    /// tree (no columns yet) fills it exactly; columns fit while their widths
    /// sum to at most 1.
    pub(crate) fn strip_fits_window(&self) -> bool {
        let sum: f32 =
            self.layout_columns.iter().filter(|column| is_strip(column)).map(|c| c.width).sum();
        sum <= 1.0 + FIT_EPSILON
    }

    /// After a `fit` split inserted the column `added` into a screen that fit the
    /// window, resizes the scrolling columns so all of them fit again: the
    /// new one at `1 / n`, the others scaled to share the rest in their old
    /// proportions (equal shares when a scaled one would fall under the
    /// minimum width). Leaves the widths alone when `n` columns cannot fit at
    /// the minimum width; the strip scrolls then. Returns whether it resized.
    pub(crate) fn fit_strip_after_insert(&mut self, added: SplitId) -> bool {
        let count = self.layout_columns.iter().filter(|column| is_strip(column)).count();
        if count == 0 || !self.layout_columns.iter().any(|c| c.id == added && is_strip(c)) {
            return false;
        }
        let share = 1.0 / count as f32;
        if share + FIT_EPSILON < MIN_VIEWPORT_PANE_WIDTH {
            return false;
        }
        let others: f32 = self
            .layout_columns
            .iter()
            .filter(|column| is_strip(column) && column.id != added)
            .map(|column| column.width)
            .sum();
        let scale = if others > 0.0 { (1.0 - share) / others } else { 0.0 };
        let proportional = self
            .layout_columns
            .iter()
            .filter(|column| is_strip(column) && column.id != added)
            .all(|column| column.width * scale + FIT_EPSILON >= MIN_VIEWPORT_PANE_WIDTH);
        for column in self.layout_columns.iter_mut().filter(|column| is_strip(column)) {
            column.width =
                if column.id == added || !proportional { share } else { column.width * scale };
        }
        self.sync_layout_column_projection();
        true
    }
}

#[cfg(test)]
mod tests {
    use super::super::{ColumnDock, DockEdge, DockMode, LayoutColumn, Node, Screen};
    use crate::SplitId;
    use crate::resource::ScreenPublicId;

    fn tree_screen() -> Screen {
        Screen {
            id: 1,
            public_id: ScreenPublicId::parse(format!("screen_{:032x}", 1)).unwrap(),
            name: None,
            root: Node::Leaf(10),
            active_pane: 10,
            zoomed_pane: None,
            creation_order_auto_layout: None,
            viewport_splits: Default::default(),
            viewport_base_width: None,
            layout_columns: Vec::new(),
            layout_revision: 0,
            layout_undo: Default::default(),
        }
    }

    fn screen(widths: &[f32]) -> Screen {
        let mut screen = tree_screen();
        screen.layout_columns = widths
            .iter()
            .enumerate()
            .map(|(index, width)| {
                LayoutColumn::single(index as SplitId + 100, *width, 10 + index as u64)
            })
            .collect();
        screen
    }

    fn widths(screen: &Screen) -> Vec<f32> {
        screen.layout_columns.iter().map(|column| column.width).collect()
    }

    fn close(actual: &[f32], expected: &[f32]) {
        assert_eq!(actual.len(), expected.len(), "{actual:?} vs {expected:?}");
        for (a, e) in actual.iter().zip(expected) {
            assert!((a - e).abs() < 1e-4, "{actual:?} vs {expected:?}");
        }
    }

    #[test]
    fn a_column_beside_a_full_width_one_makes_two_halves() {
        let mut screen = screen(&[1.0, 0.5]);
        assert!(screen.fit_strip_after_insert(101));
        close(&widths(&screen), &[0.5, 0.5]);
    }

    #[test]
    fn a_third_column_takes_a_third_and_keeps_the_others_proportions() {
        let mut even = screen(&[0.5, 0.5, 0.5]);
        assert!(even.fit_strip_after_insert(102));
        close(&widths(&even), &[1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0]);
        let mut uneven = screen(&[0.75, 0.25, 0.5]);
        assert!(uneven.fit_strip_after_insert(102));
        close(&widths(&uneven), &[0.5, 1.0 / 6.0, 1.0 / 3.0]);
    }

    #[test]
    fn a_column_that_would_shrink_under_the_minimum_gets_equal_shares() {
        let mut screen = screen(&[0.9, 0.1, 0.5]);
        assert!(screen.fit_strip_after_insert(102));
        close(&widths(&screen), &[1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0]);
    }

    #[test]
    fn too_many_columns_to_fit_keep_their_widths() {
        let mut many: Vec<f32> = vec![0.1; 10];
        many.push(0.5);
        let mut screen = screen(&many);
        assert!(!screen.fit_strip_after_insert(110));
        close(&widths(&screen), &many);
    }

    #[test]
    fn docked_columns_keep_their_width_and_do_not_count() {
        let mut screen = screen(&[0.33, 1.0, 0.5]);
        screen.layout_columns[0].dock = Some(ColumnDock::new(DockEdge::Left, DockMode::Docked));
        assert!(screen.fit_strip_after_insert(102));
        close(&widths(&screen), &[0.33, 0.5, 0.5]);
    }

    #[test]
    fn a_split_tree_and_a_fitting_strip_fit_and_a_wide_strip_does_not() {
        assert!(tree_screen().strip_fits_window());
        assert!(screen(&[0.5, 0.5]).strip_fits_window());
        assert!(!screen(&[1.0, 0.5]).strip_fits_window());
    }
}

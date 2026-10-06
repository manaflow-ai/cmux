//! Rows of a viewport column (`rows-v1`, plans/cmux-next/rows.md): each
//! column is a vertical strip of rows, and each row holds a split tree.
//!
//! Representation: [`LayoutColumn::root`] stays the one tree that every
//! existing path edits (split, close, swap, tab moves). With two or more rows
//! it is the compat chain: the row trees folded top to bottom into `Down`
//! splits whose ids are the ids of rows 2..n and whose ratios follow the
//! heights. [`LayoutColumn::rows`] holds the id and height of each row. A
//! column with one row of 1000 has no row records.
//!
//! Invariant owner: [`LayoutColumn::normalize_rows`]. Every projection sync
//! (`Screen::sync_layout_column_projection` and its snapshot twin, through
//! [`super::project_layout_columns`]) runs it, so a structural change made
//! by any path is reconciled in the same commit: a row whose chain split
//! collapsed is removed (R2), a column left with one row drops its records,
//! and the chain ratios are rewritten from the heights.

use super::{LayoutColumn, Node, Screen};
use crate::{PaneId, SplitDir, SplitId};

// Shortest and tallest row, in thousandths of the column's viewport height.
pub(crate) use cmux_layout_reducer::ROW_HEIGHT_PERMILLE;

/// Height of the implicit row of a column without row records.
pub(crate) const FULL_ROW_HEIGHT: u16 = 1000;

/// One row of a column: its id (allocated as a split id) and height.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct LayoutRow {
    pub(crate) id: SplitId,
    pub(crate) height: u16,
    /// The row's panes at the last normalize. Read only to tell which of
    /// rows 1 and 2 survived when the chain split between them collapsed.
    members: Vec<PaneId>,
}

impl LayoutRow {
    pub(crate) fn new(id: SplitId, height: u16) -> Self {
        Self { id, height, members: Vec::new() }
    }
}

/// Unfolds the chain of `root` over `ids` (the ids of rows 2..n): the base
/// tree, and the id and tree of each chain split found, top to bottom.
fn unfold(root: &Node, ids: &[SplitId]) -> (Node, Vec<(SplitId, Node)>) {
    let mut node = root;
    let mut found: Vec<(SplitId, Node)> = Vec::new();
    while let Node::Split { id, dir: SplitDir::Down, a, b, .. } = node {
        if !ids.contains(id) || found.iter().any(|(seen, _)| seen == id) {
            break;
        }
        found.push((*id, (**b).clone()));
        node = &**a;
    }
    found.reverse();
    (node.clone(), found)
}

/// Folds row trees into the compat chain; ratios follow the heights.
fn fold(rows: &[LayoutRow], trees: Vec<Node>) -> Node {
    let mut trees = trees.into_iter();
    let mut root = trees.next().expect("a column has at least one row");
    let mut before = f32::from(rows[0].height);
    for (row, tree) in rows[1..].iter().zip(trees) {
        let height = f32::from(row.height);
        root = Node::Split {
            id: row.id,
            dir: SplitDir::Down,
            ratio: before / (before + height),
            a: Box::new(root),
            b: Box::new(tree),
        };
        before += height;
    }
    root
}

impl LayoutColumn {
    /// Each row with its tree, top to bottom. Empty for a column without row
    /// records. Requires a normalized column.
    pub(crate) fn row_trees(&self) -> Vec<(LayoutRow, Node)> {
        if self.rows.len() < 2 {
            return Vec::new();
        }
        let ids = self.rows[1..].iter().map(|row| row.id).collect::<Vec<_>>();
        let (base, found) = unfold(&self.root, &ids);
        debug_assert_eq!(found.len() + 1, self.rows.len(), "column rows are not normalized");
        std::iter::once(base)
            .chain(found.into_iter().map(|(_, tree)| tree))
            .zip(self.rows.iter().cloned())
            .map(|(tree, row)| (row, tree))
            .collect()
    }

    /// Whether `split` is a synthetic split of the compat chain.
    pub(crate) fn is_row_split(&self, split: SplitId) -> bool {
        self.rows.iter().skip(1).any(|row| row.id == split)
    }

    /// Restores the row invariants after any change to `root`, as described
    /// in the module documentation. Idempotent.
    pub(crate) fn normalize_rows(&mut self) {
        if self.rows.is_empty() {
            return;
        }
        let ids = self.rows[1..].iter().map(|row| row.id).collect::<Vec<_>>();
        let (base, found) = unfold(&self.root, &ids);
        let positions = found
            .iter()
            .map(|(id, _)| self.rows.iter().position(|row| row.id == *id).unwrap_or(0))
            .collect::<Vec<_>>();
        if found.is_empty() || !positions.windows(2).all(|pair| pair[0] < pair[1]) {
            // One row left, or a chain no path builds: the tree stays as it
            // is and the column has one implicit row.
            self.rows.clear();
            return;
        }
        // The base is one of the rows above the first chain split found.
        // Only the collapse of row 2's split leaves two candidates.
        let base_panes = base.pane_ids_vec();
        let candidates = &self.rows[..positions[0]];
        let base_row = candidates
            .iter()
            .find(|row| row.members.iter().any(|pane| base_panes.contains(pane)))
            .unwrap_or(&candidates[0])
            .clone();
        let mut rows = vec![base_row];
        let mut trees = vec![base];
        for ((_, tree), position) in found.into_iter().zip(positions) {
            rows.push(self.rows[position].clone());
            trees.push(tree);
        }
        for (row, tree) in rows.iter_mut().zip(&trees) {
            row.members = tree.pane_ids_vec();
        }
        self.root = fold(&rows, trees);
        self.rows = rows;
        self.zellij_auto_layout = None;
    }

    /// Adds `row` holding `tree` below the row of `target`. A column without
    /// row records first gets its implicit row as `base_row` (1000).
    pub(crate) fn insert_row_below(
        &mut self,
        target: PaneId,
        base_row: SplitId,
        row: LayoutRow,
        tree: Node,
    ) -> bool {
        let mut rows = if self.rows.len() < 2 {
            vec![(LayoutRow::new(base_row, FULL_ROW_HEIGHT), self.root.clone())]
        } else {
            self.row_trees()
        };
        let Some(index) = rows.iter().position(|(_, candidate)| candidate.contains(target)) else {
            return false;
        };
        rows.insert(index + 1, (row, tree));
        let (rows, trees): (Vec<_>, Vec<_>) = rows.into_iter().unzip();
        self.root = fold(&rows, trees);
        self.rows = rows;
        self.normalize_rows();
        true
    }

    /// Writes heights by row id (validated by the caller) and refolds.
    pub(crate) fn write_row_heights(&mut self, heights: &[(SplitId, u16)]) {
        let trees = self.row_trees().into_iter().map(|(_, tree)| tree).collect::<Vec<_>>();
        for row in &mut self.rows {
            if let Some((_, height)) = heights.iter().find(|(id, _)| *id == row.id) {
                row.height = *height;
            }
        }
        if !trees.is_empty() {
            self.root = fold(&self.rows, trees);
        }
    }

    /// Runs `edit` on the tree of the row holding `pane` (the whole root for
    /// a column without rows) with the auto-layout order that tree owns:
    /// the column's, or none for a row, so an auto layout stays inside it.
    pub(crate) fn edit_row_of(
        &mut self,
        pane: PaneId,
        edit: impl FnOnce(&mut Node, &mut Option<Vec<PaneId>>),
    ) {
        if self.rows.len() < 2 {
            edit(&mut self.root, &mut self.zellij_auto_layout);
            return;
        }
        let mut rows = self.row_trees();
        if let Some((_, tree)) = rows.iter_mut().find(|(_, tree)| tree.contains(pane)) {
            edit(tree, &mut None);
        }
        let (rows, trees): (Vec<_>, Vec<_>) = rows.into_iter().unzip();
        self.root = fold(&rows, trees);
        self.rows = rows;
        self.normalize_rows();
    }

    /// Row ids for the resource index (row 1's id is in no tree).
    pub(crate) fn row_ids(&self) -> impl Iterator<Item = SplitId> + '_ {
        self.rows.iter().map(|row| row.id)
    }
}

impl Screen {
    /// `new-row`: a row of `row.height` holding `pane` below the row of
    /// `target`. On a split screen the tree first becomes the only row of
    /// one column `base_column`.
    pub(crate) fn insert_layout_row_below(
        &mut self,
        target: PaneId,
        base_column: SplitId,
        base_row: SplitId,
        row: LayoutRow,
        pane: PaneId,
    ) -> bool {
        if self.layout_columns.is_empty() {
            if !self.root.contains(target) {
                return false;
            }
            let root = std::mem::replace(&mut self.root, Node::Leaf(0));
            self.layout_columns.push(LayoutColumn::new(base_column, 1.0, root, None));
            self.zellij_auto_layout = None;
        }
        let inserted = self
            .layout_column_for_pane_mut(target)
            .is_some_and(|column| column.insert_row_below(target, base_row, row, Node::Leaf(pane)));
        self.sync_layout_column_projection();
        inserted
    }

    /// A screen in columns mode with one column, which then has 2+ rows.
    pub(crate) fn has_lone_row_column(&self) -> bool {
        self.layout_columns.len() == 1 && self.layout_columns[0].rows.len() >= 2
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn column_of_rows() -> LayoutColumn {
        let mut column = LayoutColumn::new(100, 1.0, Node::Leaf(1), None);
        assert!(column.insert_row_below(1, 10, LayoutRow::new(20, 400), Node::Leaf(2)));
        assert!(column.insert_row_below(2, 10, LayoutRow::new(30, 300), Node::Leaf(3)));
        column
    }

    fn heights(column: &LayoutColumn) -> Vec<(SplitId, u16)> {
        column.rows.iter().map(|row| (row.id, row.height)).collect()
    }

    #[test]
    fn rows_fold_into_a_chain_whose_split_ids_are_rows_two_to_n() {
        let column = column_of_rows();
        assert_eq!(heights(&column), vec![(10, 1000), (20, 400), (30, 300)]);
        let Node::Split { id, ratio, a, .. } = &column.root else { panic!("chain") };
        assert_eq!(*id, 30);
        assert!((ratio - 1400.0 / 1700.0).abs() < 1e-6);
        assert!(matches!(**a, Node::Split { id: 20, dir: SplitDir::Down, .. }));
        assert!(column.is_row_split(20) && column.is_row_split(30) && !column.is_row_split(10));
    }

    #[test]
    fn removing_a_rows_last_pane_removes_the_row() {
        for (pane, kept) in [(1, vec![20, 30]), (2, vec![10, 30]), (3, vec![10, 20])] {
            let mut column = column_of_rows();
            column.root = column.root.clone().remove_leaf(pane).unwrap();
            column.normalize_rows();
            assert_eq!(column.rows.iter().map(|row| row.id).collect::<Vec<_>>(), kept);
            assert_eq!(column.row_trees().len(), 2);
        }
    }

    #[test]
    fn a_column_left_with_one_row_drops_its_records() {
        let mut column = LayoutColumn::new(100, 1.0, Node::Leaf(1), None);
        assert!(column.insert_row_below(1, 10, LayoutRow::new(20, 500), Node::Leaf(2)));
        column.root = column.root.clone().remove_leaf(1).unwrap();
        column.normalize_rows();
        assert!(column.rows.is_empty());
        assert!(matches!(column.root, Node::Leaf(2)));
    }

    #[test]
    fn a_split_inside_a_row_stays_in_that_row() {
        let mut column = column_of_rows();
        assert!(column.root.split_leaf(2, 99, SplitDir::Right, 4));
        column.normalize_rows();
        let rows = column.row_trees();
        assert_eq!(rows[1].1.pane_ids_vec(), vec![2, 4]);
        column.write_row_heights(&[(10, 500), (20, 250), (30, 250)]);
        assert_eq!(heights(&column), vec![(10, 500), (20, 250), (30, 250)]);
        assert_eq!(column.row_trees()[1].1.pane_ids_vec(), vec![2, 4]);
    }
}

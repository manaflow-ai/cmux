//! Viewport columns of a scrollable screen and their `dock-columns-v1`
//! flags, the compat projection of the columns, plus the layout mutation
//! keys that coalesce undo entries.

use std::collections::BTreeMap;

use super::{LayoutRow, Node, Screen};
use crate::{PaneId, SplitDir, SplitId};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ViewportColumn {
    Base,
    Split(SplitId),
}

/// One stable horizontal column in a scrollable screen.
///
/// `Screen::root` remains the compatibility projection consumed by existing
/// split-tree clients. While columns are active, these records own the real
/// per-column trees and Zellij auto-layout order.
#[derive(Debug, Clone)]
pub(crate) struct LayoutColumn {
    pub(crate) id: SplitId,
    pub(crate) width: f32,
    pub(crate) root: Node,
    pub(crate) creation_order_auto_layout: Option<Vec<PaneId>>,
    /// `dock-columns-v1`: the viewport edge this column is pinned to.
    /// `None` for an ordinary scrolling column. See [`normalize_dock_columns`].
    pub(crate) dock: Option<ColumnDock>,
    /// `rows-v1`: empty, or two or more rows whose trees `root` chains
    /// (plans/cmux-next/rows.md, super::layout_rows).
    pub(crate) rows: Vec<LayoutRow>,
}

impl LayoutColumn {
    /// A scrolling column without rows.
    pub(crate) fn new(
        id: SplitId,
        width: f32,
        root: Node,
        creation_order_auto_layout: Option<Vec<PaneId>>,
    ) -> Self {
        Self { id, width, root, creation_order_auto_layout, dock: None, rows: Vec::new() }
    }

    /// A new scrolling column holding one pane.
    pub(crate) fn single(id: SplitId, width: f32, pane: PaneId) -> Self {
        Self::new(id, width, Node::Leaf(pane), Some(vec![pane]))
    }
}

/// The compatibility fields of a screen derived from its columns.
pub(crate) enum ColumnProjection {
    /// No columns: the screen keeps its own tree.
    Unchanged,
    /// The last column left: the screen becomes this split tree.
    Tree { root: Node, creation_order_auto_layout: Option<Vec<PaneId>> },
    /// Columns mode: the chain of the columns.
    Columns { root: Node, viewport_splits: BTreeMap<SplitId, f32>, base_width: f32 },
}

/// Restores the row ([`LayoutColumn::normalize_rows`]) and docked
/// invariants of `columns` and returns the compatibility projection. Owner
/// of the "columns mode" rule: two or more columns, or one column with two or
/// more rows. Such a lone column fills the screen width (1.0) and keeps its
/// id, also when a second column joins it.
pub(crate) fn project_layout_columns(columns: &mut Vec<LayoutColumn>) -> ColumnProjection {
    for column in columns.iter_mut() {
        column.normalize_rows();
    }
    if columns.len() == 1 && columns[0].rows.is_empty() {
        let column = columns.pop().expect("one column");
        return ColumnProjection::Tree {
            root: column.root,
            creation_order_auto_layout: column.creation_order_auto_layout,
        };
    }
    if let [column] = columns.as_mut_slice() {
        column.width = 1.0;
    }
    normalize_dock_columns(columns);
    let Some(first) = columns.first() else { return ColumnProjection::Unchanged };
    let mut root = first.root.clone();
    let mut width_before = first.width;
    let mut viewport_splits = BTreeMap::new();
    for column in columns.iter().skip(1) {
        // This tree is a read-compatibility projection, not a user resize
        // request. Preserve exact authoritative proportions even when a
        // wide layout requires a derived ratio outside mutation bounds.
        let ratio = width_before / (width_before + column.width);
        root = Node::Split {
            id: column.id,
            dir: SplitDir::Right,
            ratio,
            a: Box::new(root),
            b: Box::new(column.root.clone()),
        };
        viewport_splits.insert(column.id, column.width);
        width_before += column.width;
    }
    debug_assert!(dock_columns_are_consistent(columns));
    ColumnProjection::Columns { root, viewport_splits, base_width: first.width }
}

/// Viewport edge a column is pinned to. Left and right are docked columns
/// (`dock-columns-v1`); top and bottom are screen-wide docks
/// (`edge-docks-v1`, plans/cmux-next/layout-model.md), sent as
/// `columns[].dock` and stored outside `viewport_json` so older builds read
/// such a column as an ordinary one.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DockEdge {
    Left,
    Right,
    Top,
    Bottom,
}

impl DockEdge {
    pub const ALL: [Self; 4] = [Self::Left, Self::Right, Self::Top, Self::Bottom];

    pub fn parse(value: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|edge| edge.as_str() == value)
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Left => "left",
            Self::Right => "right",
            Self::Top => "top",
            Self::Bottom => "bottom",
        }
    }

    /// Top and bottom: a screen-wide dock rather than a docked column.
    pub fn is_band(self) -> bool {
        matches!(self, Self::Top | Self::Bottom)
    }
}

/// How a frontend presents a docked column: `Docked` takes its width out of
/// the scrolling area, `Overlay` floats above the scrolling columns.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DockMode {
    Docked,
    Overlay,
}

impl DockMode {
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "docked" => Some(Self::Docked),
            "overlay" => Some(Self::Overlay),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Docked => "docked",
            Self::Overlay => "overlay",
        }
    }
}

/// The dock flag of one viewport column, as stored and as sent on the wire
/// (`{"edge":"left"|"right","mode":"docked"|"overlay"}`).
/// Unknown members are ignored so a later build may add one without making
/// this build unable to read the record.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct ColumnDock {
    pub edge: DockEdge,
    pub mode: DockMode,
}

/// True when the dock flags satisfy the column invariants: no flag on a
/// screen with fewer than two columns, at most one column per edge, and at
/// least one scrolling (non-dock) column.
pub(crate) fn dock_columns_are_consistent(columns: &[LayoutColumn]) -> bool {
    dock_flags_are_consistent(&columns.iter().map(|column| column.dock).collect::<Vec<_>>())
}

/// [`dock_columns_are_consistent`] over the flags of a screen's columns.
pub(crate) fn dock_flags_are_consistent(flags: &[Option<ColumnDock>]) -> bool {
    let dock = flags.iter().flatten().collect::<Vec<_>>();
    if dock.is_empty() {
        return true;
    }
    flags.len() >= 2
        && dock.len() < flags.len()
        && DockEdge::ALL
            .iter()
            .all(|edge| dock.iter().filter(|flag| flag.edge == *edge).count() <= 1)
}

/// Restore the docked invariants after a structural change removed or
/// reordered columns: a second column on an edge loses its flag, and when no
/// scrolling column remains every flag is cleared. Commands that set flags
/// validate first, so this only acts after removals.
pub(crate) fn normalize_dock_columns(columns: &mut [LayoutColumn]) {
    if columns.len() < 2 || columns.iter().all(|column| column.dock.is_some()) {
        for column in columns.iter_mut() {
            column.dock = None;
        }
        return;
    }
    let mut seen = Vec::with_capacity(2);
    for column in columns.iter_mut() {
        if let Some(flag) = column.dock {
            if seen.contains(&flag.edge) {
                column.dock = None;
            } else {
                seen.push(flag.edge);
            }
        }
    }
    debug_assert!(dock_columns_are_consistent(columns));
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum LayoutResizeOwner {
    InProcess(u64),
    ControlClient(u64),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum LayoutMutationKey {
    Resize {
        owner: LayoutResizeOwner,
        transaction: u64,
    },
    /// `set-column-dock` changes with one connection's transaction. Kept
    /// apart from resizes so a reused transaction id never merges the two.
    ColumnDock {
        owner: LayoutResizeOwner,
        transaction: u64,
    },
}

impl Screen {
    pub(crate) fn layout_columns_active(&self) -> bool {
        !self.layout_columns.is_empty()
    }

    pub(crate) fn layout_column_for_pane_mut(&mut self, pane: PaneId) -> Option<&mut LayoutColumn> {
        self.layout_columns.iter_mut().find(|column| column.root.contains(pane))
    }

    /// Inserts `column` after the column of `target`. A split screen first
    /// becomes the column `base_id`; a lone column with rows keeps its id
    /// (the store revives its parked split identity, screen_rows.rs).
    pub(crate) fn insert_layout_column_after(
        &mut self,
        target: PaneId,
        base_id: SplitId,
        column: LayoutColumn,
    ) -> bool {
        if self.layout_columns.is_empty() {
            if !self.root.contains(target) {
                return false;
            }
            let root = std::mem::replace(&mut self.root, Node::Leaf(0));
            let width = self.viewport_base_width.unwrap_or(1.0);
            let auto_layout = self.creation_order_auto_layout.take();
            self.layout_columns.push(LayoutColumn::new(base_id, width, root, auto_layout));
        }
        let Some(index) =
            self.layout_columns.iter().position(|candidate| candidate.root.contains(target))
        else {
            return false;
        };
        self.layout_columns.insert(index + 1, column);
        self.sync_layout_column_projection();
        true
    }

    /// Re-derives `root`, `viewport_splits`, `viewport_base_width` and the
    /// auto layout from the columns ([`project_layout_columns`]). A screen
    /// left with one column without rows collapses back to its split tree.
    pub(crate) fn sync_layout_column_projection(&mut self) {
        match project_layout_columns(&mut self.layout_columns) {
            ColumnProjection::Unchanged => {
                self.viewport_splits.clear();
                self.viewport_base_width = None;
            }
            ColumnProjection::Tree { root, creation_order_auto_layout } => {
                self.root = root;
                self.creation_order_auto_layout = creation_order_auto_layout;
                self.viewport_splits.clear();
                self.viewport_base_width = None;
            }
            ColumnProjection::Columns { root, viewport_splits, base_width } => {
                self.root = root;
                self.viewport_splits = viewport_splits;
                self.viewport_base_width = Some(base_width);
                self.creation_order_auto_layout = None;
                debug_assert!(self.layout_column_projection_is_consistent());
            }
        }
    }

    pub(crate) fn collapse_single_layout_column(&mut self) {
        self.sync_layout_column_projection();
    }

    pub(crate) fn layout_column_projection_is_consistent(&self) -> bool {
        if self.layout_columns.is_empty() {
            return self.viewport_splits.is_empty() && self.viewport_base_width.is_none();
        }
        if (self.layout_columns.len() < 2 && !self.has_lone_row_column())
            || self.creation_order_auto_layout.is_some()
            || self.viewport_base_width != self.layout_columns.first().map(|column| column.width)
            || self.viewport_splits.len() + 1 != self.layout_columns.len()
        {
            return false;
        }

        let projected_panes = self.root.pane_ids_vec();
        let column_panes = self
            .layout_columns
            .iter()
            .flat_map(|column| column.root.pane_ids_vec())
            .collect::<Vec<_>>();
        if projected_panes != column_panes {
            return false;
        }

        self.layout_columns.iter().enumerate().all(|(index, column)| {
            let expected_owner =
                if index == 0 { ViewportColumn::Base } else { ViewportColumn::Split(column.id) };
            (index == 0 || self.viewport_splits.get(&column.id).copied() == Some(column.width))
                && column.root.pane_ids_vec().into_iter().all(|pane| {
                    self.root.viewport_column_owner(pane, &self.viewport_splits)
                        == Some(expected_owner)
                })
        })
    }
}

//! Viewport columns of a scrollable screen and their `sticky-columns-v1`
//! flags, plus the layout mutation keys that coalesce undo entries.

use super::Node;
use crate::{PaneId, SplitId};

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
    pub(crate) zellij_auto_layout: Option<Vec<PaneId>>,
    /// `sticky-columns-v1`: the viewport edge this column is pinned to.
    /// `None` for an ordinary scrolling column. See [`normalize_sticky_columns`].
    pub(crate) sticky: Option<ColumnSticky>,
}

/// Viewport edge a column is pinned to. Left and right are sticky columns
/// (`sticky-columns-v1`); top and bottom are screen-wide docks
/// (`edge-docks-v1`, plans/cmux-next/layout-model.md), sent as
/// `columns[].dock` and stored outside `viewport_json` so older builds read
/// such a column as an ordinary one.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum StickyEdge {
    Left,
    Right,
    Top,
    Bottom,
}

impl StickyEdge {
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

    /// Top and bottom: a screen-wide dock rather than a sticky column.
    pub fn is_band(self) -> bool {
        matches!(self, Self::Top | Self::Bottom)
    }
}

/// How a frontend presents a sticky column: `Docked` takes its width out of
/// the scrolling area, `Overlay` floats above the scrolling columns.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum StickyMode {
    Docked,
    Overlay,
}

impl StickyMode {
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

/// The sticky flag of one viewport column, as stored and as sent on the wire
/// (`{"edge":"left"|"right","mode":"docked"|"overlay"}`).
/// Unknown members are ignored so a later build may add one without making
/// this build unable to read the record.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct ColumnSticky {
    pub edge: StickyEdge,
    pub mode: StickyMode,
}

/// True when the sticky flags satisfy the column invariants: no flag on a
/// screen with fewer than two columns, at most one column per edge, and at
/// least one scrolling (non-sticky) column.
pub(crate) fn sticky_columns_are_consistent(columns: &[LayoutColumn]) -> bool {
    sticky_flags_are_consistent(&columns.iter().map(|column| column.sticky).collect::<Vec<_>>())
}

/// [`sticky_columns_are_consistent`] over the flags of a screen's columns.
pub(crate) fn sticky_flags_are_consistent(flags: &[Option<ColumnSticky>]) -> bool {
    let sticky = flags.iter().flatten().collect::<Vec<_>>();
    if sticky.is_empty() {
        return true;
    }
    flags.len() >= 2
        && sticky.len() < flags.len()
        && StickyEdge::ALL
            .iter()
            .all(|edge| sticky.iter().filter(|flag| flag.edge == *edge).count() <= 1)
}

/// Restore the sticky invariants after a structural change removed or
/// reordered columns: a second column on an edge loses its flag, and when no
/// scrolling column remains every flag is cleared. Commands that set flags
/// validate first, so this only acts after removals.
pub(crate) fn normalize_sticky_columns(columns: &mut [LayoutColumn]) {
    if columns.len() < 2 || columns.iter().all(|column| column.sticky.is_some()) {
        for column in columns.iter_mut() {
            column.sticky = None;
        }
        return;
    }
    let mut seen = Vec::with_capacity(2);
    for column in columns.iter_mut() {
        if let Some(flag) = column.sticky {
            if seen.contains(&flag.edge) {
                column.sticky = None;
            } else {
                seen.push(flag.edge);
            }
        }
    }
    debug_assert!(sticky_columns_are_consistent(columns));
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
    /// `set-column-sticky` changes with one connection's transaction. Kept
    /// apart from resizes so a reused transaction id never merges the two.
    ColumnSticky {
        owner: LayoutResizeOwner,
        transaction: u64,
    },
}

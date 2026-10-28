//! Docked workspaces, the window frame (plans/cmux-next/docked-workspace-DESIGN.md):
//! the dock record shared with the macOS app and the pure placement of the
//! stage and the edge docks in the client's content area.
//!
//! A client (here: one TUI client) has up to four edge docks around a stage.
//! Each dock holds one ordinary workspace. Placement follows the design's
//! G1-G3: orientation decides which docks own the corners, a Docked dock
//! takes space from the stage, a Floating dock floats over the stage's edge
//! and never resizes it, a hidden dock is not placed, and every extent is
//! clamped to the client's maximum share (W6).

// The app glue lands with the placement; until then only the tests read this.
#![allow(dead_code)]

use cmux_tui_core::Rect;
use serde::{Deserialize, Serialize};

/// The edge of the frame that a dock occupies.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum DockEdge {
    Left,
    Right,
    Top,
    Bottom,
}

impl DockEdge {
    pub(crate) const ALL: [DockEdge; 4] =
        [DockEdge::Left, DockEdge::Right, DockEdge::Top, DockEdge::Bottom];

    /// Left and right docks are side docks; top and bottom docks are bands.
    pub(crate) const fn is_side(self) -> bool {
        matches!(self, DockEdge::Left | DockEdge::Right)
    }
}

/// Whether a dock takes space from the stage or floats over its edge.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum DockMode {
    #[default]
    Docked,
    Floating,
}

/// Which docks own the frame's corners: side docks (column major, the
/// default) or the top and bottom bands (row major).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum DockOrientation {
    #[default]
    ColumnMajor,
    RowMajor,
}

/// The least and the most extent a dock record may hold.
pub(crate) const MIN_EXTENT_PERMILLE: u16 = 100;
pub(crate) const MAX_EXTENT_PERMILLE: u16 = 900;
/// The extent a new dock gets.
pub(crate) const DEFAULT_EXTENT_PERMILLE: u16 = 300;
/// The smallest dock that holds one bordered pane with a usable terminal.
pub(crate) const MIN_DOCK_COLS: u16 = 12;
pub(crate) const MIN_DOCK_ROWS: u16 = 4;
/// The smallest stage a Docked dock may leave.
pub(crate) const MIN_STAGE_COLS: u16 = 12;
pub(crate) const MIN_STAGE_ROWS: u16 = 4;

/// One dock of the frame: the record field names match the app's
/// `WindowRecord.docks` entries.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct WindowDock {
    pub(crate) edge: DockEdge,
    pub(crate) workspace_key: String,
    #[serde(default)]
    pub(crate) mode: DockMode,
    #[serde(default = "default_extent")]
    pub(crate) extent_permille: u16,
    #[serde(default)]
    pub(crate) hidden: bool,
}

fn default_extent() -> u16 {
    DEFAULT_EXTENT_PERMILLE
}

impl WindowDock {
    pub(crate) fn new(edge: DockEdge, workspace_key: impl Into<String>) -> Self {
        Self {
            edge,
            workspace_key: workspace_key.into(),
            mode: DockMode::Docked,
            extent_permille: DEFAULT_EXTENT_PERMILLE,
            hidden: false,
        }
    }
}

/// Where one placed dock draws.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct DockPlacement {
    pub(crate) edge: DockEdge,
    pub(crate) rect: Rect,
    pub(crate) floating: bool,
}

/// The stage and the placed docks, Docked docks first and Floating docks
/// last, so drawing in order puts Floating docks above everything else.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct FramePlacement {
    pub(crate) stage: Rect,
    pub(crate) docks: Vec<DockPlacement>,
}

/// Place the stage and the docks in `area`.
pub(crate) fn place_frame(
    area: Rect,
    docks: &[WindowDock],
    orientation: DockOrientation,
) -> FramePlacement {
    let _ = (docks, orientation);
    FramePlacement { stage: area, docks: Vec::new() }
}

#[cfg(test)]
mod tests;

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
///
/// Docked docks carve the stage out of `area` in orientation order (column
/// major: left, right, top, bottom; row major: top, bottom, left, right), so
/// the docks placed first own the corners (G1). Floating docks are then
/// placed the same way over the stage, which they never resize (G2, W8). The
/// first dock of an edge wins (W1) and hidden docks are not placed. Each
/// extent is a permille of the frame, clamped to the client's share: a side
/// dock at most 1/2 (2/5 beside the other side dock), a band at most 1/2 (1/3
/// beside the other band), never below one pane (W6). A Docked dock that would
/// leave the stage smaller than one pane is not placed.
pub(crate) fn place_frame(
    area: Rect,
    docks: &[WindowDock],
    orientation: DockOrientation,
) -> FramePlacement {
    // The first shown dock of each edge (W1).
    let shown = |edge: DockEdge| docks.iter().find(|dock| !dock.hidden && dock.edge == edge);
    let both_sides = shown(DockEdge::Left).is_some() && shown(DockEdge::Right).is_some();
    let both_bands = shown(DockEdge::Top).is_some() && shown(DockEdge::Bottom).is_some();
    let order = match orientation {
        DockOrientation::ColumnMajor => DockEdge::ALL,
        DockOrientation::RowMajor => {
            [DockEdge::Top, DockEdge::Bottom, DockEdge::Left, DockEdge::Right]
        }
    };
    let sized = |mode: DockMode| {
        order.into_iter().filter_map(move |edge| {
            let dock = shown(edge).filter(|dock| dock.mode == mode)?;
            let (total, share, minimum) = if edge.is_side() {
                (area.width, if both_sides { (2, 5) } else { (1, 2) }, MIN_DOCK_COLS)
            } else {
                (area.height, if both_bands { (1, 3) } else { (1, 2) }, MIN_DOCK_ROWS)
            };
            dock_extent(total, dock.extent_permille, share, minimum).map(|size| (edge, size))
        })
    };

    let mut stage = area;
    let mut placed = Vec::new();
    for (edge, size) in sized(DockMode::Docked) {
        let (remaining, minimum) = if edge.is_side() {
            (stage.width, MIN_STAGE_COLS)
        } else {
            (stage.height, MIN_STAGE_ROWS)
        };
        if remaining.saturating_sub(size) < minimum {
            continue;
        }
        placed.push(DockPlacement { edge, rect: carve(&mut stage, edge, size), floating: false });
    }
    let mut over = stage;
    for (edge, size) in sized(DockMode::Floating) {
        let (room, minimum) =
            if edge.is_side() { (over.width, MIN_DOCK_COLS) } else { (over.height, MIN_DOCK_ROWS) };
        if room < minimum {
            continue;
        }
        let rect = carve(&mut over, edge, size.min(room));
        placed.push(DockPlacement { edge, rect, floating: true });
    }
    FramePlacement { stage, docks: placed }
}

/// A dock's size in cells along its axis: `extent_permille` of `total`,
/// rounded, clamped to `share` of `total` and to `minimum`. None when the
/// share cannot hold `minimum`.
fn dock_extent(total: u16, extent_permille: u16, share: (u32, u32), minimum: u16) -> Option<u16> {
    let total = u32::from(total);
    let permille = u32::from(extent_permille.clamp(MIN_EXTENT_PERMILLE, MAX_EXTENT_PERMILLE));
    // u16 totals times at most 900 cannot overflow u32; the divisors are nonzero.
    let wanted = total.saturating_mul(permille).saturating_add(500).checked_div(1000)?;
    let most = total.saturating_mul(share.0).checked_div(share.1)?;
    let minimum = u32::from(minimum);
    if most < minimum {
        return None;
    }
    u16::try_from(wanted.clamp(minimum, most)).ok()
}

/// Cut `size` cells off `frame`'s `edge` and return the cut rect.
fn carve(frame: &mut Rect, edge: DockEdge, size: u16) -> Rect {
    match edge {
        DockEdge::Left => {
            let rect = Rect { width: size, ..*frame };
            frame.x = frame.x.saturating_add(size);
            frame.width = frame.width.saturating_sub(size);
            rect
        }
        DockEdge::Right => {
            frame.width = frame.width.saturating_sub(size);
            Rect { x: frame.x.saturating_add(frame.width), width: size, ..*frame }
        }
        DockEdge::Top => {
            let rect = Rect { height: size, ..*frame };
            frame.y = frame.y.saturating_add(size);
            frame.height = frame.height.saturating_sub(size);
            rect
        }
        DockEdge::Bottom => {
            frame.height = frame.height.saturating_sub(size);
            Rect { y: frame.y.saturating_add(frame.height), height: size, ..*frame }
        }
    }
}

#[cfg(test)]
mod tests;

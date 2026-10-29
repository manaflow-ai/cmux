//! Docked workspaces, the client's frame record and the edits the dock
//! actions make to it (plans/cmux-next/docked-workspace-DESIGN.md W1-W5).
//!
//! The record's field names (`docks`, `dock_orientation`, `stage_key`) match
//! the app's `WindowRecord`, so a dock reads the same in both frontends. The
//! TUI stores it in its own personal frontend projection, one per client.

use cmux_tui_core::{PaneId, Rect, WorkspaceId};
use serde::{Deserialize, Serialize};

use crate::app::layout::PaneArea;
use crate::app::window_frame::{DockEdge, DockMode, DockOrientation, DockPlacement, WindowDock};

/// The frontend projection that holds a TUI client's frame record.
pub(crate) const PROJECTION_FRONTEND: &str = "cmux-tui";
pub(crate) const PROJECTION_SCOPE: &str = "personal";
pub(crate) const PROJECTION_SCHEMA_VERSION: u32 = 1;
/// The projection subject is the client id with this prefix, so the
/// document never collides with another per-client TUI projection.
pub(crate) const PROJECTION_SUBJECT_PREFIX: &str = "window-frame:";

/// One client's frame: its docks, the corner orientation, and the stage's
/// workspace while a dock holds focus.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct WindowFrameRecord {
    #[serde(default)]
    pub(crate) docks: Vec<WindowDock>,
    #[serde(default)]
    pub(crate) dock_orientation: DockOrientation,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) stage_key: Option<String>,
}

impl WindowFrameRecord {
    pub(crate) fn dock_of(&self, key: &str) -> Option<&WindowDock> {
        self.docks.iter().find(|dock| dock.workspace_key == key)
    }

    pub(crate) fn dock_at(&self, edge: DockEdge) -> Option<&WindowDock> {
        self.docks.iter().find(|dock| dock.edge == edge)
    }

    pub(crate) fn is_docked(&self, key: &str) -> bool {
        self.dock_of(key).is_some()
    }

    /// Dock `key` on `edge`. A workspace is in one place only (W2), so its
    /// dock on another edge moves; the edge's previous workspace goes back to
    /// the sidebar (W1) and is returned. The moved dock keeps its mode and
    /// extent and shows.
    pub(crate) fn dock(&mut self, key: &str, edge: DockEdge) -> Option<String> {
        let kept = self.docks.iter().position(|dock| dock.workspace_key == key).map(|index| {
            let mut dock = self.docks.remove(index);
            dock.edge = edge;
            dock.hidden = false;
            dock
        });
        let replaced = self
            .docks
            .iter()
            .position(|dock| dock.edge == edge)
            .map(|index| self.docks.remove(index).workspace_key);
        self.docks.push(kept.unwrap_or_else(|| WindowDock::new(edge, key)));
        if self.stage_key.as_deref() == Some(key) {
            self.stage_key = None;
        }
        replaced
    }

    /// Remove `key`'s dock; false when it had none.
    pub(crate) fn undock(&mut self, key: &str) -> bool {
        let before = self.docks.len();
        self.docks.retain(|dock| dock.workspace_key != key);
        self.docks.len() != before
    }

    /// Show or hide the dock on `edge`; None when the edge has no dock, else
    /// whether it is hidden now.
    pub(crate) fn toggle_hidden(&mut self, edge: DockEdge) -> Option<bool> {
        let dock = self.docks.iter_mut().find(|dock| dock.edge == edge)?;
        dock.hidden = !dock.hidden;
        Some(dock.hidden)
    }

    /// Show `key`'s dock (W4: selecting a docked workspace shows its dock).
    /// True when it was hidden.
    pub(crate) fn show(&mut self, key: &str) -> bool {
        match self.docks.iter_mut().find(|dock| dock.workspace_key == key) {
            Some(dock) if dock.hidden => {
                dock.hidden = false;
                true
            }
            _ => false,
        }
    }

    /// Docked <-> Floating for `key`'s dock; false when it has none.
    pub(crate) fn toggle_floating(&mut self, key: &str) -> bool {
        let Some(dock) = self.docks.iter_mut().find(|dock| dock.workspace_key == key) else {
            return false;
        };
        dock.mode = match dock.mode {
            DockMode::Docked => DockMode::Floating,
            DockMode::Floating => DockMode::Docked,
        };
        true
    }

    /// Column major <-> row major (W7: membership and extents stay).
    pub(crate) fn toggle_orientation(&mut self) {
        self.dock_orientation = match self.dock_orientation {
            DockOrientation::ColumnMajor => DockOrientation::RowMajor,
            DockOrientation::RowMajor => DockOrientation::ColumnMajor,
        };
    }

    /// Drop docks whose workspace is gone and a stage key that is gone (W3);
    /// keep the first dock of each edge (W1). True when anything changed.
    pub(crate) fn retain_live(&mut self, live: impl Fn(&str) -> bool) -> bool {
        let before = self.clone();
        let mut edges = Vec::new();
        self.docks.retain(|dock| {
            let keep = live(dock.workspace_key.as_str()) && !edges.contains(&dock.edge);
            if keep {
                edges.push(dock.edge);
            }
            keep
        });
        if self.stage_key.as_deref().is_some_and(|key| !live(key) || self.is_docked(key)) {
            self.stage_key = None;
        }
        *self != before
    }

    /// The workspace the stage shows (W5): `active` when it is not docked,
    /// else the stage key, else the most recent of `recent`, else the first
    /// of `order`, each when it is listed in `order` and not docked.
    pub(crate) fn stage_for<'a>(
        &self,
        active: &'a str,
        recent: &[String],
        order: &[&'a str],
    ) -> Option<&'a str> {
        if !self.is_docked(active) {
            return Some(active);
        }
        let candidate = |key: &str| order.iter().copied().find(|item| *item == key);
        self.stage_key
            .as_deref()
            .and_then(candidate)
            .filter(|key| !self.is_docked(key))
            .or_else(|| {
                recent
                    .iter()
                    .rev()
                    .map(String::as_str)
                    .filter_map(candidate)
                    .find(|key| !self.is_docked(key))
            })
            .or_else(|| order.iter().copied().find(|key| !self.is_docked(key)))
    }
}

/// The App's dock state: the record and what the last layout placed.
#[derive(Debug, Default)]
pub(crate) struct DockFrameState {
    pub(crate) record: WindowFrameRecord,
    /// Whether the record was read from the session (or there is none).
    pub(crate) loaded: bool,
    /// The stage's workspaces, oldest first, for W2's "most recently shown".
    pub(crate) recent_stage: Vec<String>,
    /// A Toggle on an empty edge asked for a new workspace: dock the first
    /// workspace that is not in `known` there.
    pub(crate) pending_edge: Option<(DockEdge, Vec<String>)>,
    /// The stage's rect and workspace in the last layout; None without a frame.
    pub(crate) stage: Option<Rect>,
    pub(crate) stage_workspace: Option<WorkspaceId>,
    /// The placed docks and their workspaces in the last layout.
    pub(crate) placed: Vec<(DockPlacement, WorkspaceId)>,
    /// The docked workspaces' pane areas, drawn after the stage's.
    pub(crate) pane_areas: Vec<PaneArea>,
    /// The panes of Floating docks: their hits win over the stage's below.
    pub(crate) floating_panes: Vec<PaneId>,
}

impl DockFrameState {
    /// Remember `key` as the stage's newest workspace.
    pub(crate) fn note_stage(&mut self, key: &str) {
        if self.recent_stage.last().is_some_and(|last| last == key) {
            return;
        }
        self.recent_stage.retain(|item| item != key);
        self.recent_stage.push(key.to_string());
        if self.recent_stage.len() > 16 {
            self.recent_stage.remove(0);
        }
    }

    /// Forget the last layout's frame.
    pub(crate) fn clear_placement(&mut self) {
        self.stage = None;
        self.stage_workspace = None;
        self.placed.clear();
        self.pane_areas.clear();
        self.floating_panes.clear();
    }

    /// The rects of the placed Floating docks.
    pub(crate) fn floating_rects(&self) -> impl Iterator<Item = Rect> + '_ {
        self.placed
            .iter()
            .filter(|(placement, _)| placement.floating)
            .map(|(placement, _)| placement.rect)
    }
}

#[cfg(test)]
mod tests;

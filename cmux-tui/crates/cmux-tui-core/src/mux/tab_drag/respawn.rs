//! Tab drags that leave a fresh tab behind (`respawn`): a pane's only tab
//! dropped on its own pane's edge (`tab-split-respawn-v1`) or moved into a
//! new column (`tab-column-respawn-v1`). The fresh tab is created first, so
//! the source pane never empties, and the drag commits only while that pane
//! holds exactly the fresh and the dragged tab.

use super::*;
use cmux_layout_reducer::{NewTab, TabContent};

/// The fresh tab a split of a pane's only tab leaves in that pane
/// (`move-tab-to-split` `respawn`, `tab-split-respawn-v1`): the same kind as
/// the moved tab, never a copy of its state.
#[derive(Debug, Clone)]
pub enum SplitRespawn {
    /// A new terminal, spawned like `new-tab`.
    Terminal(TerminalSpawnOptions),
    /// A new frontend browser tab (usually the new tab page).
    Browser(crate::workspace_registry::FrontendBrowserRecord),
}

/// The source pane a respawn split expects at its commit: exactly the
/// fresh tab and the dragged tab, in any order.
pub(super) struct SourceGuard {
    pub(super) pane: PaneId,
    pub(super) tabs: [SurfaceId; 2],
}

impl SourceGuard {
    pub(super) fn check(&self, state: &State) -> anyhow::Result<()> {
        anyhow::ensure!(
            state.panes.get(&self.pane).is_some_and(|pane| {
                pane.tabs.len() == self.tabs.len()
                    && self.tabs.iter().all(|tab| pane.tabs.contains(tab))
            }),
            "stale: the pane changed during the respawn split"
        );
        Ok(())
    }
}

/// Where `move-tab-to-column` puts the tab: a new column after
/// `after_column` (default: right of `pane`'s column), `width` a viewport
/// fraction (default the standard column width), pinned at `sticky`.
#[derive(Debug, Clone, Copy)]
pub struct ColumnMove {
    pub pane: PaneId,
    pub after_column: Option<SplitId>,
    pub width: Option<f32>,
    pub sticky: Option<ColumnSticky>,
}

impl Mux {
    /// `move-tab-to-split` with `respawn`: split the tab's own pane, which
    /// holds only that tab, and leave a fresh tab of the given kind in it.
    ///
    /// The layout reducer validates the whole op first (the moved tab plus
    /// the explicitly created one, I1-I3). The fresh tab is created first,
    /// so the source pane never empties; then the split commits with the
    /// client transaction, and only while the pane still holds exactly the
    /// dragged and the fresh tab (another client may have changed it in
    /// between). If the split fails, the fresh tab is closed again, so a
    /// failure leaves the layout as it was. A daemon that dies between the
    /// two commits keeps the fresh tab beside the dragged one; no tab is
    /// lost.
    pub fn move_tab_to_split_respawning(
        self: &Arc<Self>,
        surface: SurfaceId,
        pane: PaneId,
        edge: TabDropEdge,
        ratio: Option<f32>,
        respawn: SplitRespawn,
        transaction: Option<String>,
    ) -> anyhow::Result<TabDragOutcome> {
        validate_split_ratio(ratio)?;
        let model = {
            let state = self.state.lock().unwrap();
            anyhow::ensure!(
                state.panes.get(&pane).is_some_and(|candidate| candidate.tabs == [surface]),
                "bad request: respawn applies only to a split of the pane's only tab"
            );
            layout_invariants::project(&state)
        };
        // Ids the model has never used stand in for the pane and tab the
        // live commits create.
        let kind = LayoutOpKind::MoveTabToSplit {
            tab: surface,
            pane,
            edge: edge.into(),
            new_pane: u64::MAX,
            respawn: Some(NewTab {
                tab: u64::MAX - 1,
                content: TabContent { runtime: u64::MAX, terminal: None, dead: false },
            }),
        };
        layout_invariants::model_result("tab.drag", &model, &kind)?;
        let destination = TabDragDestination::Split { pane, edge, ratio };
        self.commit_tab_drag_respawning(surface, pane, destination, respawn, transaction)
    }

    /// `move-tab-to-column` with `respawn` (`tab-column-respawn-v1`): move
    /// a pane's only tab into a new column (pinned when `sticky` is set) and
    /// leave a fresh tab of the given kind in its pane, with the same
    /// two-commit guard as [`Self::move_tab_to_split_respawning`]. Docking a
    /// screen's only tab uses it: the strip keeps a column to scroll.
    pub fn move_tab_to_column_respawning(
        self: &Arc<Self>,
        surface: SurfaceId,
        destination: ColumnMove,
        respawn: SplitRespawn,
        transaction: Option<String>,
    ) -> anyhow::Result<TabDragOutcome> {
        let ColumnMove { pane, after_column, width, sticky } = destination;
        let width = validated_column_width(width)?;
        let source = self.with_state(|state| state.pane_of(surface));
        let source = source.context("tab has no pane")?;
        self.with_state(|state| {
            anyhow::ensure!(
                state.panes.get(&source).is_some_and(|candidate| candidate.tabs == [surface]),
                "bad request: respawn applies only to a pane's only tab"
            );
            Ok(())
        })?;
        let destination = TabDragDestination::Column { pane, after_column, width, sticky };
        self.commit_tab_drag_respawning(surface, source, destination, respawn, transaction)
    }

    /// Creates the fresh tab in `source` first, so that pane never empties,
    /// then commits the drag while `source` holds exactly the fresh and the
    /// dragged tab. A failed drag closes the fresh tab again.
    fn commit_tab_drag_respawning(
        self: &Arc<Self>,
        surface: SurfaceId,
        source: PaneId,
        destination: TabDragDestination,
        respawn: SplitRespawn,
        transaction: Option<String>,
    ) -> anyhow::Result<TabDragOutcome> {
        let size = self.surface(surface).map(|runtime| runtime.size());
        let fresh = match respawn {
            SplitRespawn::Terminal(spawn) => {
                self.new_tab_with_options(Some(source), spawn, size)?
            }
            SplitRespawn::Browser(record) => {
                self.new_frontend_browser_tab(Some(source), record, size)?
            }
        };
        let guard = SourceGuard { pane: source, tabs: [fresh.id, surface] };
        match self.commit_tab_drag_guarded(surface, destination, transaction, Some(guard)) {
            Ok(outcome) => Ok(outcome),
            Err(error) => {
                if let Err(close) = self.close_surface(fresh.id) {
                    eprintln!(
                        "cmux-tui: respawn drag could not close fresh tab {}: {close:#}",
                        fresh.id
                    );
                }
                Err(error)
            }
        }
    }
}

//! Checked reads of live topology for mux operations.
//!
//! An operation finds a workspace and screen by index or a pane by id under
//! the state lock, then reads or edits it. When that lookup no longer names
//! live state, the operation returns [`StaleTopology`] to its request instead
//! of panicking (plans/cmux-next/rust-panic-free.md, rule 1): one bad request
//! must not take the daemon and every attached client with it.

use std::fmt;

use super::{TreeDecorations, TreeDeltaKind};
use crate::model::{Pane, Screen, State, Workspace};
use crate::resource::{PanePublicId, TabPublicId};
use crate::{PaneId, SurfaceId};

/// A lookup that no longer names live topology.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum StaleTopology {
    Workspace { index: usize },
    Screen { workspace: usize, screen: usize },
    Pane { pane: PaneId },
    PanePublicId { pane: PaneId },
    TabPublicId { surface: SurfaceId },
    LayoutColumn { index: usize },
}

impl fmt::Display for StaleTopology {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Workspace { index } => write!(f, "workspace index {index} is not live"),
            Self::Screen { workspace, screen } => {
                write!(f, "screen index {screen} of workspace index {workspace} is not live")
            }
            Self::Pane { pane } => write!(f, "pane {pane} is not live"),
            Self::PanePublicId { pane } => write!(f, "pane {pane} has no public id"),
            Self::TabPublicId { surface } => write!(f, "tab {surface} has no public id"),
            Self::LayoutColumn { index } => write!(f, "layout column {index} is not live"),
        }
    }
}

impl std::error::Error for StaleTopology {}

impl State {
    pub(crate) fn workspace_at(&self, index: usize) -> Result<&Workspace, StaleTopology> {
        self.workspaces.get(index).ok_or(StaleTopology::Workspace { index })
    }

    pub(crate) fn workspace_at_mut(
        &mut self,
        index: usize,
    ) -> Result<&mut Workspace, StaleTopology> {
        self.workspaces.get_mut(index).ok_or(StaleTopology::Workspace { index })
    }

    pub(crate) fn screen_at(
        &self,
        workspace: usize,
        screen: usize,
    ) -> Result<&Screen, StaleTopology> {
        self.workspace_at(workspace)?
            .screens
            .get(screen)
            .ok_or(StaleTopology::Screen { workspace, screen })
    }

    pub(crate) fn screen_at_mut(
        &mut self,
        workspace: usize,
        screen: usize,
    ) -> Result<&mut Screen, StaleTopology> {
        self.workspace_at_mut(workspace)?
            .screens
            .get_mut(screen)
            .ok_or(StaleTopology::Screen { workspace, screen })
    }

    pub(crate) fn live_pane(&self, pane: PaneId) -> Result<&Pane, StaleTopology> {
        self.panes.get(&pane).ok_or(StaleTopology::Pane { pane })
    }

    pub(crate) fn live_pane_mut(&mut self, pane: PaneId) -> Result<&mut Pane, StaleTopology> {
        self.panes.get_mut(&pane).ok_or(StaleTopology::Pane { pane })
    }

    pub(crate) fn live_pane_public_id(&self, pane: PaneId) -> Result<&PanePublicId, StaleTopology> {
        self.resource_indexes.pane_ids.get(&pane).ok_or(StaleTopology::PanePublicId { pane })
    }

    pub(crate) fn live_tab_public_id(
        &self,
        surface: SurfaceId,
    ) -> Result<&TabPublicId, StaleTopology> {
        self.resource_indexes.tab_ids.get(&surface).ok_or(StaleTopology::TabPublicId { surface })
    }

    /// The screen a mutation plan resolved, for its infallible apply step
    /// (crate::resource_mutation): the step runs under the state lock the
    /// plan read the slot under, so the slot is live (Chrome's CHECK).
    #[allow(
        clippy::expect_used,
        reason = "INVARIANT: a mutation plan's apply step runs under the state lock its plan resolved this slot in"
    )]
    #[track_caller]
    pub(crate) fn planned_screen_mut(&mut self, workspace: usize, screen: usize) -> &mut Screen {
        self.screen_at_mut(workspace, screen).expect("INVARIANT: planned screen is live")
    }

    /// The workspace a mutation plan resolved (see [`Self::planned_screen_mut`]).
    #[allow(
        clippy::expect_used,
        reason = "INVARIANT: a mutation plan's apply step runs under the state lock its plan resolved this slot in"
    )]
    #[track_caller]
    pub(crate) fn planned_workspace_mut(&mut self, workspace: usize) -> &mut Workspace {
        self.workspace_at_mut(workspace).expect("INVARIANT: planned workspace is live")
    }

    /// The pane a mutation plan resolved (see [`Self::planned_screen_mut`]).
    #[allow(
        clippy::expect_used,
        reason = "INVARIANT: a mutation plan's apply step runs under the state lock its plan resolved this slot in"
    )]
    #[track_caller]
    pub(crate) fn planned_pane_mut(&mut self, pane: PaneId) -> &mut Pane {
        self.live_pane_mut(pane).expect("INVARIANT: planned pane is live")
    }

    /// The workspace and screen indexes of a pane a mutation plan resolved
    /// (see [`Self::planned_screen_mut`]).
    #[allow(
        clippy::expect_used,
        reason = "INVARIANT: a mutation plan's apply step runs under the state lock its plan resolved this slot in"
    )]
    #[track_caller]
    pub(crate) fn planned_screen_of(&self, pane: PaneId) -> (usize, usize) {
        self.screen_of(pane).expect("INVARIANT: planned pane remains in its screen")
    }
}

/// The tree entity of a resource the caller just wrote under the state lock
/// it still holds, for the tree delta that announces it.
#[allow(
    clippy::expect_used,
    reason = "INVARIANT: the caller holds the state lock it wrote the resource under, so the tree snapshot holds it"
)]
#[track_caller]
pub(crate) fn committed_tree_entity(
    state: &State,
    notifications: &TreeDecorations,
    kind: TreeDeltaKind,
    id: u64,
) -> serde_json::Value {
    crate::server::tree_entity_json(state, notifications, kind, id)
        .expect("INVARIANT: a resource written under the held state lock is in the tree snapshot")
}

#[cfg(test)]
#[path = "state_slots_tests.rs"]
mod tests;

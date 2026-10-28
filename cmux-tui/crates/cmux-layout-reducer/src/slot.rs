//! Where a pane sits in the layout, and the reads of that place.
//!
//! A `Slot` comes from `locate` or `slot` on the same `LayoutState` the op
//! then edits. Ops read through it before they remove a workspace, screen or
//! column, so its indexes still name the pane's place: a failed read is a
//! broken internal invariant, not bad input, and the accessors say so.

use crate::{Column, LayoutState, PaneId, Reject, Screen, Workspace};

/// Indexes of a pane's workspace, screen, column and position in the column.
#[derive(Debug, Clone, Copy)]
pub(crate) struct Slot {
    pub workspace: usize,
    pub screen: usize,
    pub column: usize,
    pub position: usize,
}

impl LayoutState {
    pub(crate) fn slot(&self, pane: PaneId) -> Option<Slot> {
        for (wi, workspace) in self.workspaces.iter().enumerate() {
            for (si, screen) in workspace.screens.iter().enumerate() {
                for (ci, column) in screen.columns.iter().enumerate() {
                    if let Some(pi) = column.panes.iter().position(|id| *id == pane) {
                        return Some(Slot { workspace: wi, screen: si, column: ci, position: pi });
                    }
                }
            }
        }
        None
    }

    /// Where `pane` sits; a pane that does not exist or is in no layout
    /// rejects the op.
    pub(crate) fn locate(&self, pane: PaneId) -> Result<Slot, Reject> {
        if !self.panes.contains_key(&pane) {
            return Err(Reject::UnknownPane(pane));
        }
        self.slot(pane).ok_or(Reject::UnknownPane(pane))
    }

    #[allow(
        clippy::expect_used,
        reason = "INVARIANT: the slot was located in this state; its place was not removed"
    )]
    pub(crate) fn workspace_at_mut(&mut self, slot: Slot) -> &mut Workspace {
        // crash-allow: INVARIANT, slot located in this state, its place not removed since
        self.workspaces.get_mut(slot.workspace).expect("INVARIANT: slot names a workspace")
    }

    #[allow(
        clippy::expect_used,
        reason = "INVARIANT: the slot was located in this state; its place was not removed"
    )]
    pub(crate) fn screen_at(&self, slot: Slot) -> &Screen {
        self.workspaces
            .get(slot.workspace)
            .and_then(|workspace| workspace.screens.get(slot.screen))
            // crash-allow: INVARIANT, slot located in this state, its place not removed since
            .expect("INVARIANT: slot names a screen")
    }

    #[allow(
        clippy::expect_used,
        reason = "INVARIANT: the slot was located in this state; its place was not removed"
    )]
    pub(crate) fn screen_at_mut(&mut self, slot: Slot) -> &mut Screen {
        self.workspaces
            .get_mut(slot.workspace)
            .and_then(|workspace| workspace.screens.get_mut(slot.screen))
            // crash-allow: INVARIANT, slot located in this state, its place not removed since
            .expect("INVARIANT: slot names a screen")
    }

    #[allow(
        clippy::expect_used,
        reason = "INVARIANT: the slot was located in this state; its place was not removed"
    )]
    pub(crate) fn column_at(&self, slot: Slot) -> &Column {
        // crash-allow: INVARIANT, slot located in this state, its place not removed since
        self.screen_at(slot).columns.get(slot.column).expect("INVARIANT: slot names a column")
    }

    #[allow(
        clippy::expect_used,
        reason = "INVARIANT: the slot was located in this state; its place was not removed"
    )]
    pub(crate) fn column_at_mut(&mut self, slot: Slot) -> &mut Column {
        self.screen_at_mut(slot)
            .columns
            .get_mut(slot.column)
            // crash-allow: INVARIANT, slot located in this state, its place not removed since
            .expect("INVARIANT: slot names a column")
    }
}

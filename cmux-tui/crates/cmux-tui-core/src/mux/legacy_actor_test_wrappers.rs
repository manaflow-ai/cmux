//! Key-less test forms of the ops P8 landing 3b gave an actor (legacy
//! commands, tab and screen groups, workspace ops of the in-process TUI):
//! they act as the daemon. Only tests call them; production code names the
//! actor with the `*_as` form, or does not compile.

use super::*;
use crate::model::ColumnDock;

#[allow(dead_code, clippy::too_many_arguments, reason = "test conveniences; each test uses some")]
impl Mux {
    pub(crate) fn close_workspace(&self, target: WorkspaceId) -> bool {
        self.close_workspace_as(&Actor::Daemon, target)
    }

    pub(crate) fn close_workspace_at_revision(
        &self,
        target: WorkspaceId,
        expected_revision: Option<u64>,
    ) -> anyhow::Result<Option<u64>> {
        self.close_workspace_at_revision_as(&Actor::Daemon, target, expected_revision)
    }

    pub(crate) fn rename_workspace(&self, target: WorkspaceId, name: String) -> bool {
        self.rename_workspace_at_revision_as(&Actor::Daemon, target, name, None)
            .map(|revision| revision.is_some())
            .unwrap_or(false)
    }

    pub(crate) fn rename_workspace_at_revision(
        &self,
        target: WorkspaceId,
        name: String,
        expected_revision: Option<u64>,
    ) -> anyhow::Result<Option<u64>> {
        self.rename_workspace_at_revision_as(&Actor::Daemon, target, name, expected_revision)
    }

    pub(crate) fn move_workspace(&self, workspace: WorkspaceId, index: usize) -> bool {
        self.move_workspace_at_revision_as(&Actor::Daemon, workspace, index, None)
            .map(|result| result.is_some_and(|(_, changed)| changed))
            .unwrap_or(false)
    }

    pub(crate) fn move_workspace_at_revision(
        &self,
        workspace: WorkspaceId,
        index: usize,
        expected_revision: Option<u64>,
    ) -> anyhow::Result<Option<(u64, bool)>> {
        self.move_workspace_at_revision_as(&Actor::Daemon, workspace, index, expected_revision)
    }

    pub(crate) fn rename_provider_managed_workspace(
        &self,
        id: WorkspaceId,
        key: &str,
        name: String,
    ) -> anyhow::Result<Option<u64>> {
        self.rename_provider_managed_workspace_as(&Actor::Daemon, id, key, name)
    }

    pub(crate) fn close_provider_managed_workspace(
        &self,
        id: WorkspaceId,
        key: &str,
    ) -> anyhow::Result<Option<u64>> {
        self.close_provider_managed_workspace_as(&Actor::Daemon, id, key)
    }

    pub(crate) fn select_tab(
        self: &Arc<Self>,
        pane: Option<PaneId>,
        index: Option<usize>,
        delta: Option<isize>,
    ) {
        self.select_tab_as(&Actor::Daemon, pane, index, delta)
    }

    pub(crate) fn set_column_dock(
        self: &Arc<Self>,
        pane: PaneId,
        dock: Option<ColumnDock>,
        transaction: Option<(u64, u64)>,
    ) -> Result<ColumnDockOutcome, ColumnDockError> {
        self.set_column_dock_as(&Actor::Daemon, pane, dock, transaction)
    }

    pub(crate) fn set_row_heights(
        self: &Arc<Self>,
        column: SplitId,
        heights: &[(SplitId, u64)],
        fit: bool,
        transaction: Option<(u64, u64)>,
    ) -> Result<RowHeightsOutcome, RowsError> {
        self.set_row_heights_as(&Actor::Daemon, column, heights, fit, transaction)
    }

    pub(crate) fn apply_layout(
        self: &Arc<Self>,
        workspace: Option<WorkspaceId>,
        name: Option<String>,
        layout: &LayoutSpec,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<AppliedLayout> {
        self.apply_layout_as(&Actor::Daemon, workspace, name, layout, size)
    }

    pub(crate) fn undo_layout(
        self: &Arc<Self>,
        pane: PaneId,
        expected_revision: Option<u64>,
        confirm_close: bool,
    ) -> anyhow::Result<LayoutUndoResult> {
        self.undo_layout_as(&Actor::Daemon, pane, expected_revision, confirm_close)
    }

    pub(crate) fn move_tab_to_split(
        self: &Arc<Self>,
        surface: SurfaceId,
        pane: PaneId,
        edge: TabDropEdge,
        ratio: Option<f32>,
        transaction: Option<String>,
    ) -> anyhow::Result<TabDragOutcome> {
        self.move_tab_to_split_as(&Actor::Daemon, surface, pane, edge, ratio, transaction)
    }

    pub(crate) fn move_tab_to_column(
        self: &Arc<Self>,
        surface: SurfaceId,
        pane: PaneId,
        after_column: Option<SplitId>,
        width: Option<f32>,
        dock: Option<ColumnDock>,
        transaction: Option<String>,
    ) -> anyhow::Result<TabDragOutcome> {
        self.move_tab_to_column_as(
            &Actor::Daemon,
            surface,
            pane,
            after_column,
            width,
            dock,
            transaction,
        )
    }

    pub(crate) fn set_screen_metadata(
        self: &Arc<Self>,
        screen: ScreenId,
        color: Option<Option<String>>,
        icon: Option<Option<String>>,
    ) -> anyhow::Result<bool> {
        self.set_screen_metadata_as(&Actor::Daemon, screen, color, icon)
    }

    pub(crate) fn set_screen_pinned(
        self: &Arc<Self>,
        screen: ScreenId,
        pinned: bool,
    ) -> anyhow::Result<(bool, usize)> {
        self.set_screen_pinned_as(&Actor::Daemon, screen, pinned)
    }

    pub(crate) fn move_screen(
        self: &Arc<Self>,
        screen: ScreenId,
        destination: ScreenDestination,
    ) -> anyhow::Result<ScreenMoveOutcome> {
        self.move_screen_as(&Actor::Daemon, screen, destination)
    }

    pub(crate) fn create_screen_group(
        self: &Arc<Self>,
        members: &[ScreenId],
        name: Option<String>,
        color: Option<String>,
    ) -> anyhow::Result<ScreenGroupOutcome> {
        self.create_screen_group_as(&Actor::Daemon, members, name, color)
    }

    pub(crate) fn update_screen_group(
        &self,
        group: &str,
        name: Option<String>,
        color: Option<String>,
        collapsed: Option<bool>,
    ) -> anyhow::Result<ScreenGroupOutcome> {
        self.update_screen_group_as(&Actor::Daemon, group, name, color, collapsed)
    }

    pub(crate) fn add_screens_to_screen_group(
        self: &Arc<Self>,
        group: &str,
        added: &[ScreenId],
        index: Option<usize>,
    ) -> anyhow::Result<ScreenGroupOutcome> {
        self.add_screens_to_screen_group_as(&Actor::Daemon, group, added, index)
    }

    pub(crate) fn remove_screens_from_screen_group(
        self: &Arc<Self>,
        removed: &[ScreenId],
    ) -> anyhow::Result<Vec<String>> {
        self.remove_screens_from_screen_group_as(&Actor::Daemon, removed)
    }

    pub(crate) fn move_screen_group(
        self: &Arc<Self>,
        group: &str,
        destination: ScreenDestination,
    ) -> anyhow::Result<ScreenGroupOutcome> {
        self.move_screen_group_as(&Actor::Daemon, group, destination)
    }

    pub(crate) fn ungroup_screen_group(&self, group: &str) -> anyhow::Result<Vec<ScreenId>> {
        self.ungroup_screen_group_as(&Actor::Daemon, group)
    }

    pub(crate) fn save_screen_group(&self, group: &str) -> anyhow::Result<String> {
        self.save_screen_group_as(&Actor::Daemon, group)
    }

    pub(crate) fn create_tab_group(
        self: &Arc<Self>,
        surfaces: &[SurfaceId],
        name: Option<String>,
        color: Option<String>,
        id: Option<String>,
        transaction: Option<&str>,
    ) -> anyhow::Result<TabGroupOutcome> {
        self.create_tab_group_as(&Actor::Daemon, surfaces, name, color, id, transaction)
    }

    pub(crate) fn update_tab_group(
        self: &Arc<Self>,
        group: &str,
        name: Option<String>,
        color: Option<String>,
        collapsed: Option<bool>,
    ) -> anyhow::Result<TabGroupOutcome> {
        self.update_tab_group_as(&Actor::Daemon, group, name, color, collapsed)
    }

    pub(crate) fn add_tabs_to_tab_group(
        self: &Arc<Self>,
        group: &str,
        surfaces: &[SurfaceId],
        transaction: Option<&str>,
    ) -> anyhow::Result<TabGroupOutcome> {
        self.add_tabs_to_tab_group_as(&Actor::Daemon, group, surfaces, transaction)
    }

    pub(crate) fn remove_tabs_from_tab_group(
        self: &Arc<Self>,
        surfaces: &[SurfaceId],
        transaction: Option<&str>,
    ) -> anyhow::Result<Vec<String>> {
        self.remove_tabs_from_tab_group_as(&Actor::Daemon, surfaces, transaction)
    }

    pub(crate) fn move_tab_group(
        self: &Arc<Self>,
        group: &str,
        destination: TabGroupDestination,
        transaction: Option<&str>,
    ) -> anyhow::Result<TabGroupOutcome> {
        self.move_tab_group_as(&Actor::Daemon, group, destination, transaction)
    }

    pub(crate) fn ungroup_tab_group(
        self: &Arc<Self>,
        group: &str,
    ) -> anyhow::Result<Vec<SurfaceId>> {
        self.ungroup_tab_group_as(&Actor::Daemon, group)
    }

    pub(crate) fn close_tab_group(self: &Arc<Self>, group: &str) -> anyhow::Result<Vec<SurfaceId>> {
        self.close_tab_group_as(&Actor::Daemon, group)
    }

    pub(crate) fn save_tab_group(self: &Arc<Self>, group: &str) -> anyhow::Result<String> {
        self.save_tab_group_as(&Actor::Daemon, group)
    }

    pub(crate) fn unsave_tab_group(&self, group: &str) -> anyhow::Result<bool> {
        self.unsave_tab_group_as(&Actor::Daemon, group)
    }

    pub(crate) fn delete_saved_tab_group(&self, saved_id: &str) -> anyhow::Result<bool> {
        self.delete_saved_tab_group_as(&Actor::Daemon, saved_id)
    }

    pub(crate) fn set_tab_pinned(
        self: &Arc<Self>,
        surface: SurfaceId,
        pinned: bool,
    ) -> anyhow::Result<TabPinChange> {
        self.set_tab_pinned_as(&Actor::Daemon, surface, pinned)
    }
}

//! Key-less test forms of the topology ops: they act as the daemon. Only
//! tests may call them (P8 landing 3a): production code names the actor
//! with the `*_as` form, or does not compile.

use super::*;
use crate::workspace_registry::FrontendBrowserRecord;

#[allow(dead_code, clippy::too_many_arguments, reason = "test conveniences; each test uses some")]
impl Mux {
    pub(crate) fn close_pane(self: &Arc<Self>, target: PaneId) -> anyhow::Result<bool> {
        self.close_pane_as(&Actor::Daemon, target)
    }

    pub(crate) fn close_screen(self: &Arc<Self>, target: ScreenId) -> anyhow::Result<bool> {
        self.close_screen_as(&Actor::Daemon, target)
    }

    pub(crate) fn close_surface(self: &Arc<Self>, target: SurfaceId) -> anyhow::Result<bool> {
        self.close_surface_as(&Actor::Daemon, target)
    }

    pub(crate) fn create_terminal_result_in_workspace(
        self: &Arc<Self>,
        workspace: WorkspaceId,
        argv: Option<Vec<String>>,
        cwd: Option<String>,
        name: Option<String>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<RunCommandResult> {
        self.create_terminal_result_in_workspace_as(
            &Actor::Daemon,
            workspace,
            argv,
            cwd,
            name,
            size,
        )
    }

    pub(crate) fn focus_direction(
        self: &Arc<Self>,
        pane: Option<PaneId>,
        dir: Direction,
    ) -> anyhow::Result<PaneId> {
        self.focus_direction_as(&Actor::Daemon, pane, dir)
    }

    pub(crate) fn focus_pane(self: &Arc<Self>, pane: PaneId) -> bool {
        self.focus_pane_as(&Actor::Daemon, pane)
    }

    pub(crate) fn move_tab(
        self: &Arc<Self>,
        surface: SurfaceId,
        pane: PaneId,
        index: usize,
    ) -> bool {
        self.move_tab_as(&Actor::Daemon, surface, pane, index)
    }

    pub(crate) fn new_browser_tab_with_fields(
        self: &Arc<Self>,
        url: String,
        pane: Option<PaneId>,
        size: Option<(u16, u16)>,
        extra_fields: Map<String, Value>,
    ) -> anyhow::Result<Arc<Surface>> {
        self.new_browser_tab_with_fields_as(&Actor::Daemon, url, pane, size, extra_fields)
    }

    pub(crate) fn new_pane_right_with_options(
        self: &Arc<Self>,
        target: PaneId,
        width: f32,
        spawn: TerminalSpawnOptions,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        self.new_pane_right_with_options_as(&Actor::Daemon, target, width, spawn, size)
    }

    pub(crate) fn new_pane_with_options(
        self: &Arc<Self>,
        target: PaneId,
        spawn: TerminalSpawnOptions,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        self.new_pane_with_options_as(&Actor::Daemon, target, spawn, size)
    }

    pub(crate) fn new_screen_named(
        self: &Arc<Self>,
        workspace: Option<WorkspaceId>,
        name: Option<String>,
        spawn: TerminalSpawnOptions,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        self.new_screen_named_as(&Actor::Daemon, workspace, name, spawn, size)
    }

    pub(crate) fn new_tab_with_options(
        self: &Arc<Self>,
        pane: Option<PaneId>,
        spawn: TerminalSpawnOptions,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        self.new_tab_with_options_as(&Actor::Daemon, pane, spawn, size)
    }

    pub(crate) fn new_workspace(
        self: &Arc<Self>,
        name: Option<String>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        self.new_workspace_as(&Actor::Daemon, name, size)
    }

    pub(crate) fn rename_pane(self: &Arc<Self>, target: PaneId, name: String) -> bool {
        self.rename_pane_as(&Actor::Daemon, target, name)
    }

    pub(crate) fn rename_screen(self: &Arc<Self>, target: ScreenId, name: String) -> bool {
        self.rename_screen_as(&Actor::Daemon, target, name)
    }

    pub(crate) fn rename_surface(self: &Arc<Self>, target: SurfaceId, name: String) -> bool {
        self.rename_surface_as(&Actor::Daemon, target, name)
    }

    pub(crate) fn run_command_result_with_options(
        self: &Arc<Self>,
        argv: Vec<String>,
        options: RunCommandOptions,
    ) -> anyhow::Result<RunCommandResult> {
        self.run_command_result_with_options_as(&Actor::Daemon, argv, options)
    }

    pub(crate) fn select_screen(self: &Arc<Self>, index: Option<usize>, delta: Option<isize>) {
        self.select_screen_as(&Actor::Daemon, index, delta);
    }

    pub(crate) fn select_workspace(self: &Arc<Self>, index: Option<usize>, delta: Option<isize>) {
        self.select_workspace_as(&Actor::Daemon, index, delta);
    }

    pub(crate) fn split_with_options(
        self: &Arc<Self>,
        target: PaneId,
        dir: SplitDir,
        spawn: TerminalSpawnOptions,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        self.split_with_options_as(&Actor::Daemon, target, dir, spawn, size)
    }

    pub(crate) fn swap_panes(self: &Arc<Self>, pane: PaneId, target: PaneId) -> bool {
        self.swap_panes_as(&Actor::Daemon, pane, target)
    }

    pub(crate) fn zoom_pane(
        self: &Arc<Self>,
        pane: Option<PaneId>,
        mode: ZoomMode,
    ) -> anyhow::Result<ZoomState> {
        self.zoom_pane_as(&Actor::Daemon, pane, mode)
    }

    pub(crate) fn split_browser_pane(
        self: &Arc<Self>,
        target: PaneId,
        dir: SplitDir,
        viewport_width: Option<f32>,
        url: String,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        self.split_browser_pane_as(&Actor::Daemon, target, dir, viewport_width, url, size)
    }

    pub(crate) fn new_row_with_options(
        self: &Arc<Self>,
        target: PaneId,
        height: u64,
        spawn: TerminalSpawnOptions,
        size: Option<(u16, u16)>,
        transaction: Option<String>,
    ) -> anyhow::Result<Arc<Surface>> {
        self.new_row_with_options_as(&Actor::Daemon, target, height, spawn, size, transaction)
    }

    pub(crate) fn run_command_surface_with_options(
        self: &Arc<Self>,
        argv: Vec<String>,
        options: RunCommandOptions,
    ) -> anyhow::Result<RunPlacement> {
        self.run_command_surface_with_options_as(&Actor::Daemon, argv, options)
    }

    pub(crate) fn new_screen_with_cwd(
        self: &Arc<Self>,
        workspace: Option<WorkspaceId>,
        cwd: Option<String>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        self.new_screen_with_cwd_as(&Actor::Daemon, workspace, cwd, size)
    }

    pub(crate) fn new_tab_with_env(
        self: &Arc<Self>,
        pane: Option<PaneId>,
        cwd: Option<String>,
        env: Vec<(String, String)>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        self.new_tab_with_env_as(&Actor::Daemon, pane, cwd, env, size)
    }

    pub(crate) fn create_terminal_in_workspace(
        self: &Arc<Self>,
        workspace: WorkspaceId,
        argv: Option<Vec<String>>,
        cwd: Option<String>,
        name: Option<String>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<RunPlacement> {
        self.create_terminal_in_workspace_as(&Actor::Daemon, workspace, argv, cwd, name, size)
    }

    pub(crate) fn new_browser_tab(
        self: &Arc<Self>,
        url: String,
        pane: Option<PaneId>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        self.new_browser_tab_as(&Actor::Daemon, url, pane, size)
    }

    pub(crate) fn split_with(
        self: &Arc<Self>,
        target: PaneId,
        dir: SplitDir,
        cwd: Option<String>,
        env: Vec<(String, String)>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        self.split_with_as(&Actor::Daemon, target, dir, cwd, env, size)
    }

    pub(crate) fn new_pane_right(
        self: &Arc<Self>,
        target: PaneId,
        width: f32,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        self.new_pane_right_as(&Actor::Daemon, target, width, size)
    }

    pub(crate) fn new_pane(
        self: &Arc<Self>,
        target: PaneId,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        self.new_pane_as(&Actor::Daemon, target, size)
    }

    pub(crate) fn set_ratio_checked(
        self: &Arc<Self>,
        pane: PaneId,
        dir: SplitDir,
        ratio: f32,
    ) -> Result<(), LayoutRatioError> {
        self.set_ratio_checked_as(&Actor::Daemon, pane, dir, ratio)
    }

    pub(crate) fn set_split_ratio_checked(
        self: &Arc<Self>,
        split: SplitId,
        ratio: f32,
    ) -> Result<(), LayoutRatioError> {
        self.set_split_ratio_checked_as(&Actor::Daemon, split, ratio)
    }

    pub(crate) fn set_split_ratio_in_transaction_checked(
        self: &Arc<Self>,
        split: SplitId,
        ratio: f32,
        client: u64,
        transaction: u64,
    ) -> Result<(), LayoutRatioError> {
        self.set_split_ratio_in_transaction_checked_as(
            &Actor::Daemon,
            split,
            ratio,
            client,
            transaction,
        )
    }

    pub(crate) fn set_split_ratio_in_process_transaction_checked(
        self: &Arc<Self>,
        split: SplitId,
        ratio: f32,
        owner: u64,
        transaction: u64,
    ) -> Result<(), LayoutRatioError> {
        self.set_split_ratio_in_process_transaction_checked_as(
            &Actor::Daemon,
            split,
            ratio,
            owner,
            transaction,
        )
    }

    pub(crate) fn set_viewport_pane_width_checked(
        self: &Arc<Self>,
        pane: PaneId,
        width: f32,
    ) -> Result<(), ViewportWidthError> {
        self.set_viewport_pane_width_checked_as(&Actor::Daemon, pane, width)
    }

    pub(crate) fn set_viewport_pane_width_in_transaction_checked(
        self: &Arc<Self>,
        pane: PaneId,
        width: f32,
        client: u64,
        transaction: u64,
    ) -> Result<(), ViewportWidthError> {
        self.set_viewport_pane_width_in_transaction_checked_as(
            &Actor::Daemon,
            pane,
            width,
            client,
            transaction,
        )
    }

    pub(crate) fn set_viewport_pane_width_in_process_transaction_checked(
        self: &Arc<Self>,
        pane: PaneId,
        width: f32,
        owner: u64,
        transaction: u64,
    ) -> Result<(), ViewportWidthError> {
        self.set_viewport_pane_width_in_process_transaction_checked_as(
            &Actor::Daemon,
            pane,
            width,
            owner,
            transaction,
        )
    }

    pub(crate) fn new_frontend_browser_tab_placed(
        self: &Arc<Self>,
        pane: Option<PaneId>,
        record: FrontendBrowserRecord,
        size: Option<(u16, u16)>,
        placement: FrontendTabPlacement,
    ) -> anyhow::Result<Arc<Surface>> {
        self.new_frontend_browser_tab_placed_as(&Actor::Daemon, pane, record, size, placement)
    }

    pub(crate) fn close_screen_group(
        self: &Arc<Self>,
        group: &str,
        end_terminals: bool,
    ) -> anyhow::Result<Vec<ScreenId>> {
        self.close_screen_group_as(&Actor::Daemon, group, end_terminals)
    }

    pub(crate) fn new_screen_with_spec(
        self: &Arc<Self>,
        workspace: Option<WorkspaceId>,
        spawn: TerminalSpawnOptions,
        size: Option<(u16, u16)>,
        spec: ScreenSpec,
    ) -> anyhow::Result<(Arc<Surface>, ScreenId)> {
        self.new_screen_with_spec_as(&Actor::Daemon, workspace, spawn, size, spec)
    }

    pub(crate) fn move_tab_with_undo(
        self: &Arc<Self>,
        surface: SurfaceId,
        pane: PaneId,
        index: usize,
        transaction: Option<String>,
    ) -> (bool, bool) {
        self.move_tab_with_undo_as(&Actor::Daemon, surface, pane, index, transaction)
    }

    pub(crate) fn run_command_surface(
        self: &Arc<Self>,
        argv: Vec<String>,
        pane: Option<PaneId>,
        new_workspace: bool,
        cwd: Option<String>,
        name: Option<String>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<RunPlacement> {
        self.run_command_surface_as(&Actor::Daemon, argv, pane, new_workspace, cwd, name, size)
    }

    pub(crate) fn new_screen(
        self: &Arc<Self>,
        workspace: Option<WorkspaceId>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        self.new_screen_as(&Actor::Daemon, workspace, size)
    }

    pub(crate) fn new_tab(
        self: &Arc<Self>,
        pane: Option<PaneId>,
        cwd: Option<String>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        self.new_tab_as(&Actor::Daemon, pane, cwd, size)
    }

    pub(crate) fn split(
        self: &Arc<Self>,
        target: PaneId,
        dir: SplitDir,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        self.split_as(&Actor::Daemon, target, dir, size)
    }

    pub(crate) fn set_ratio(self: &Arc<Self>, pane: PaneId, dir: SplitDir, ratio: f32) -> bool {
        self.set_ratio_as(&Actor::Daemon, pane, dir, ratio)
    }

    pub(crate) fn set_split_ratio(self: &Arc<Self>, split: SplitId, ratio: f32) -> bool {
        self.set_split_ratio_as(&Actor::Daemon, split, ratio)
    }

    pub(crate) fn set_split_ratio_in_transaction(
        self: &Arc<Self>,
        split: SplitId,
        ratio: f32,
        client: u64,
        transaction: u64,
    ) -> bool {
        self.set_split_ratio_in_transaction_as(&Actor::Daemon, split, ratio, client, transaction)
    }

    pub(crate) fn set_viewport_pane_width(self: &Arc<Self>, pane: PaneId, width: f32) -> bool {
        self.set_viewport_pane_width_as(&Actor::Daemon, pane, width)
    }

    pub(crate) fn set_viewport_pane_width_in_transaction(
        self: &Arc<Self>,
        pane: PaneId,
        width: f32,
        client: u64,
        transaction: u64,
    ) -> bool {
        self.set_viewport_pane_width_in_transaction_as(
            &Actor::Daemon,
            pane,
            width,
            client,
            transaction,
        )
    }

    pub(crate) fn new_frontend_browser_tab(
        self: &Arc<Self>,
        pane: Option<PaneId>,
        record: FrontendBrowserRecord,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        self.new_frontend_browser_tab_as(&Actor::Daemon, pane, record, size)
    }

    pub(crate) fn move_tab_to_workspace(
        self: &Arc<Self>,
        surface: SurfaceId,
        workspace: Option<WorkspaceId>,
    ) -> anyhow::Result<()> {
        self.move_tab_to_workspace_as(&Actor::Daemon, surface, workspace)
    }

    pub(crate) fn move_tab_to_new_workspace(
        self: &Arc<Self>,
        surface: SurfaceId,
        group: Option<String>,
        index: Option<usize>,
        name: Option<String>,
    ) -> anyhow::Result<WorkspaceId> {
        self.move_tab_to_new_workspace_as(&Actor::Daemon, surface, group, index, name)
    }

    pub(crate) fn reopen_saved_screen_group(
        self: &Arc<Self>,
        saved: &str,
        workspace: WorkspaceId,
    ) -> anyhow::Result<ScreenGroupOutcome> {
        self.reopen_saved_screen_group_as(&Actor::Daemon, saved, workspace)
    }

    pub(crate) fn move_tab_to_split_respawning(
        self: &Arc<Self>,
        surface: SurfaceId,
        pane: PaneId,
        edge: TabDropEdge,
        ratio: Option<f32>,
        respawn: SplitRespawn,
        transaction: Option<String>,
    ) -> anyhow::Result<TabDragOutcome> {
        self.move_tab_to_split_respawning_as(
            &Actor::Daemon,
            surface,
            pane,
            edge,
            ratio,
            respawn,
            transaction,
        )
    }

    pub(crate) fn move_tab_to_column_respawning(
        self: &Arc<Self>,
        surface: SurfaceId,
        destination: ColumnMove,
        respawn: SplitRespawn,
        transaction: Option<String>,
    ) -> anyhow::Result<TabDragOutcome> {
        self.move_tab_to_column_respawning_as(
            &Actor::Daemon,
            surface,
            destination,
            respawn,
            transaction,
        )
    }

    pub(crate) fn reopen_saved_tab_group(
        self: &Arc<Self>,
        saved_id: &str,
        pane: PaneId,
        transaction: Option<&str>,
    ) -> anyhow::Result<TabGroupOutcome> {
        self.reopen_saved_tab_group_as(&Actor::Daemon, saved_id, pane, transaction)
    }
}

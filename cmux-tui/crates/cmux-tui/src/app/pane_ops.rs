//! Creating panes, tabs and workspaces from the App: size hints, split and
//! smart new pane, new terminal tab, user commands, and workspace creation.

use cmux_tui_core::{
    DEFAULT_VIEWPORT_PANE_WIDTH, PaneId, Rect, SplitDir, ViewportColumn, layout_screen,
    split_sides, zellij_default_pane_layout,
};

use crate::app::App;
use crate::app::frame_geometry::content_size_for_rect;
use crate::app::layout::PaneArea;
use crate::localization;
use crate::machine::{MachineRequest, WorkspaceCreationMode, WorkspaceCreationPolicy};

impl App {
    /// Content size for a pane filling `rect`.
    pub(super) fn size_of_rect(&self, rect: Rect) -> Option<(u16, u16)> {
        content_size_for_rect(rect, self.config.scrollbar.position, self.config.pane.padding)
    }

    /// Size hint for splitting `pane`: the second side of its rect.
    fn split_size_hint(&self, pane: PaneId, dir: SplitDir) -> Option<(u16, u16)> {
        let area = self.pane_areas.iter().find(|a| a.pane == pane)?;
        let (_, b) = split_sides(area.logical_rect(), dir, 0.5);
        self.size_of_rect(b)
    }

    pub(super) fn pane_creation_selector_candidates(
        &self,
        pane: PaneId,
        fallback_pane: Option<PaneId>,
    ) -> anyhow::Result<Vec<cmux_tui_core::ResourceSelectors>> {
        let mut candidates = Vec::with_capacity(2);
        for pane in [Some(pane), fallback_pane].into_iter().flatten() {
            if let Some(selectors) = self.tree.resource_selectors_for_pane(Some(pane))
                && !candidates.contains(&selectors)
            {
                candidates.push(selectors);
            }
        }
        Ok(candidates)
    }

    pub(super) fn split_pane(
        &mut self,
        pane: PaneId,
        fallback_pane: Option<PaneId>,
        dir: SplitDir,
        semantic_intent: Option<u64>,
    ) -> anyhow::Result<()> {
        let hint = self.split_size_hint(pane, dir);
        if !self.prepare_pty_input_before_mutation() {
            return Ok(());
        }
        let selector_candidates = self.pane_creation_selector_candidates(pane, fallback_pane)?;
        self.session.split_for_semantic_intent(
            pane,
            dir,
            hint,
            selector_candidates,
            semantic_intent,
        )
    }

    pub(super) fn new_terminal_tab(
        &mut self,
        pane: Option<PaneId>,
        fallback_pane: Option<PaneId>,
        semantic_intent: Option<u64>,
    ) -> anyhow::Result<()> {
        let pane = pane.or_else(|| self.active_pane());
        let selector_candidates = pane
            .map(|pane| self.pane_creation_selector_candidates(pane, fallback_pane))
            .transpose()?
            .unwrap_or_default();
        self.session.new_tab_for_semantic_intent(
            pane,
            self.terminal_tab_size_hint(pane),
            selector_candidates,
            semantic_intent,
        )
    }

    /// Run one configured user command as a new PTY tab in the target pane.
    /// The server defaults the working directory to the pane's current
    /// directory when the command has no configured `cwd`.
    pub(super) fn run_user_command(
        &mut self,
        index: usize,
        pane: Option<PaneId>,
    ) -> anyhow::Result<()> {
        // `action_available` already rejects user commands for single-surface
        // clients; keep the invariant local so no future route can create a
        // tab this mode cannot reach.
        if self.is_surface_only() {
            return Ok(());
        }
        let Some(command) = self.config.commands.get(index) else {
            return Ok(());
        };
        let pane = pane.or_else(|| self.active_pane());
        self.session.run_command(
            command.run.clone(),
            pane,
            command.cwd.clone(),
            self.terminal_tab_size_hint(pane),
        )
    }

    pub(super) fn terminal_tab_size_hint(&self, pane: Option<PaneId>) -> Option<(u16, u16)> {
        match pane {
            Some(pane) => {
                self.pane_areas.iter().find(|area| area.pane == pane).map(PaneArea::content_size)
            }
            None => self
                .active_pane()
                .and_then(|pane| self.terminal_tab_size_hint(Some(pane)))
                .or_else(|| self.size_of_rect(self.content_area)),
        }
    }

    pub(super) fn new_pane_smart(
        &mut self,
        pane: Option<PaneId>,
        fallback_pane: Option<PaneId>,
        semantic_intent: Option<u64>,
    ) -> anyhow::Result<()> {
        let Some(pane) = pane.or_else(|| self.active_pane()) else {
            return Ok(());
        };
        let Some(hint) = self.tree.active_screen().and_then(|screen| {
            let mut panes = Vec::new();
            screen.layout.pane_ids(&mut panes);
            let mut local_area = self.content_area;
            if !screen.viewport_splits.is_empty() {
                let owner = screen.layout.viewport_column_owner(pane, &screen.viewport_splits)?;
                panes.retain(|candidate| {
                    screen.layout.viewport_column_owner(*candidate, &screen.viewport_splits)
                        == Some(owner)
                });
                let width = match owner {
                    ViewportColumn::Base => screen.viewport_base_width.unwrap_or(1.0),
                    ViewportColumn::Split(split) => {
                        screen.viewport_splits.get(&split).copied().unwrap_or(1.0)
                    }
                };
                local_area.width =
                    ((f32::from(self.content_area.width) * width).round() as u16).max(1);
            }
            panes.push(PaneId::MAX);
            let layout = zellij_default_pane_layout(&panes)?;
            let rect =
                layout_screen(&layout, local_area, Some(PaneId::MAX)).rect_of(PaneId::MAX)?;
            self.size_of_rect(rect)
        }) else {
            return Ok(());
        };
        if !self.prepare_pty_input_before_mutation() {
            return Ok(());
        }
        let selector_candidates = self.pane_creation_selector_candidates(pane, fallback_pane)?;
        self.session.new_pane_for_semantic_intent(
            pane,
            Some(hint),
            selector_candidates,
            semantic_intent,
        )
    }

    pub(super) fn new_pane_right(
        &mut self,
        pane: Option<PaneId>,
        fallback_pane: Option<PaneId>,
        semantic_intent: Option<u64>,
    ) -> anyhow::Result<()> {
        let Some(pane) = pane.or_else(|| self.active_pane()) else {
            return Ok(());
        };
        let width = ((f32::from(self.content_area.width) * DEFAULT_VIEWPORT_PANE_WIDTH).round()
            as u16)
            .clamp(1, self.content_area.width.max(1));
        let rect = Rect { width, ..self.content_area };
        let hint = self.size_of_rect(rect);
        if self.prepare_pty_input_before_mutation() {
            let selector_candidates =
                self.pane_creation_selector_candidates(pane, fallback_pane)?;
            self.session.new_pane_right_for_semantic_intent(
                pane,
                DEFAULT_VIEWPORT_PANE_WIDTH,
                hint,
                selector_candidates,
                semantic_intent,
            )?;
        }
        Ok(())
    }

    pub(super) fn new_workspace(&mut self, semantic_intent: Option<u64>) -> anyhow::Result<()> {
        let Some(mode) = self.default_workspace_creation_mode() else {
            self.status_message = Some(
                if self.workspace_creation_policy().is_none() {
                    localization::catalog().sidebar.no_active_session
                } else {
                    localization::catalog().sidebar.managed_workspace_unsupported
                }
                .to_string(),
            );
            return Ok(());
        };
        self.create_workspace(mode, semantic_intent)
    }

    pub(super) fn create_workspace(
        &mut self,
        mode: Option<WorkspaceCreationMode>,
        semantic_intent: Option<u64>,
    ) -> anyhow::Result<()> {
        if let Some(mode) = mode {
            self.request_managed_workspace(mode);
            return Ok(());
        }
        if self.workspace_creation_policy() != Some(WorkspaceCreationPolicy::SessionOwned) {
            self.status_message =
                Some(localization::catalog().sidebar.managed_workspace_unsupported.to_string());
            return Ok(());
        }
        if !self.prepare_pty_input_before_mutation() {
            return Ok(());
        }
        self.session.new_workspace_for_semantic_intent(
            self.size_of_rect(self.content_area),
            semantic_intent,
        )
    }

    fn request_managed_workspace(&mut self, mode: WorkspaceCreationMode) {
        let supported = matches!(
            self.workspace_creation_policy(),
            Some(WorkspaceCreationPolicy::ProviderOwned { modes, .. }) if modes.contains(&mode)
        );
        if !supported {
            self.status_message =
                Some(localization::catalog().sidebar.managed_workspace_unsupported.to_string());
            return;
        }
        let Some(machine) = self.machine_ui.as_ref().and_then(|ui| ui.snapshot.active) else {
            self.status_message =
                Some(localization::catalog().sidebar.no_active_session.to_string());
            return;
        };
        let request = match mode {
            WorkspaceCreationMode::Isolated => {
                MachineRequest::CreateManagedIsolatedWorkspace(machine)
            }
            WorkspaceCreationMode::Host => MachineRequest::CreateManagedHostWorkspace(machine),
        };
        if let Some(ui) = self.machine_ui.as_mut() {
            ui.request = Some(request);
        }
    }
}

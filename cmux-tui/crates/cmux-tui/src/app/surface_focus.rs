//! Active pane and surface lookup, client focus restore and reporting,
//! terminal geometry claims, pending surface attach, and visible surface size
//! reassertion.

use cmux_tui_core::{PaneId, ScreenId, SurfaceId, SurfaceKind};

use crate::app::App;
use crate::app::host_input::TerminalInput;
use crate::app::layout::PaneArea;
use crate::app::pointer::deferred::DeferredInputAdmission;
use crate::app::surface_sync::SurfaceResizeDecision;
use crate::config::Action;
use crate::session::SurfaceHandle;

impl App {
    pub(super) fn active_pane(&self) -> Option<PaneId> {
        self.tree.active_screen().map(|screen| screen.active_pane)
    }

    pub(super) fn pane_for_surface(&self, surface: SurfaceId) -> Option<PaneId> {
        let [workspace, screen, pane, _] = self.tab_locations.get(&surface).copied()?;
        self.tree
            .workspaces()
            .get(workspace)?
            .screens
            .get(screen)?
            .panes
            .get(pane)
            .map(|pane| pane.id)
    }

    pub(super) fn active_surface(&self) -> Option<SurfaceId> {
        self.tree.active_surface()
    }

    /// Adopt this client's own remembered focus from the mux (or the
    /// session's last reported focus when this client has none), when the
    /// server has one whose pane still exists in the adopted tree; otherwise
    /// the tree's own focus stays. Sets the report baseline either way.
    pub(super) fn restore_client_focus_from_session(&mut self) {
        let Some(client_id) = self.client_focus_id.clone() else { return };
        let Some(focus) = self.session.client_focus(&client_id) else { return };
        let mut location = None;
        for (workspace_index, workspace) in self.tree.workspaces().iter().enumerate() {
            for (screen_index, screen) in workspace.screens.iter().enumerate() {
                if let Some(pane) = screen.panes.iter().find(|pane| pane.id == focus.pane) {
                    let tab = focus.tab.min(pane.tabs.len().saturating_sub(1));
                    location = Some((workspace_index, screen_index, pane.id, tab));
                }
            }
        }
        let Some((workspace_index, screen_index, pane_id, tab_index)) = location else { return };
        self.tree.active_workspace = workspace_index;
        self.tree.set_active_screen(workspace_index, screen_index);
        self.tree.set_active_pane(workspace_index, screen_index, pane_id);
        self.tree.set_active_tab(workspace_index, screen_index, pane_id, tab_index);
        self.sidebar_workspace_selection =
            workspace_index.min(self.tree.workspaces().len().saturating_sub(1));
        self.pane_focus_history.record(pane_id);
        self.reported_focus = Some(crate::session::ClientFocus { pane: pane_id, tab: tab_index });
    }

    /// Report the client's focus (pane and tab; the server derives workspace
    /// and screen at restore time) to the server's focus memory. The first
    /// observation after adopting a tree is recorded as the baseline without
    /// sending, so attaching never mutates the server; only later user
    /// navigation does.
    pub(super) fn current_client_focus(&self) -> Option<crate::session::ClientFocus> {
        let screen = self.tree.active_screen()?;
        let pane = screen.panes.iter().find(|pane| pane.id == screen.active_pane)?;
        Some(crate::session::ClientFocus { pane: pane.id, tab: pane.active_tab })
    }

    fn report_client_focus(&mut self) {
        let Some(focus) = self.current_client_focus() else { return };
        match self.reported_focus {
            None => self.reported_focus = Some(focus),
            Some(previous) if previous == focus => {}
            Some(previous) => {
                self.session.report_focus(Some(previous), focus, self.client_focus_id.as_deref());
                self.reported_focus = Some(focus);
            }
        }
    }

    pub(super) fn claim_active_terminal_geometry(&mut self, force: bool) {
        self.report_client_focus();
        let terminal = self.tree.active_screen().and_then(|screen| {
            let pane = screen.panes.iter().find(|pane| pane.id == screen.active_pane)?;
            let tab = pane.tabs.get(pane.active_tab)?;
            (tab.kind == SurfaceKind::Pty).then_some(tab.surface)
        });
        let Some(surface) = terminal else {
            self.geometry_authority_surface = None;
            return;
        };
        if !force && self.geometry_authority_surface == Some(surface) {
            return;
        }
        if !self.session.terminal_geometry_claim_ready(surface) {
            // Keep the previous terminal authoritative until the new remote
            // placement has both an attached mirror and a server-side size
            // lease. Attach/resize settlement retries this transition.
            return;
        }
        self.geometry_authority_surface = Some(surface);
        self.session.claim_terminal_geometry(surface);
    }

    pub(super) fn active_surface_handle(&self) -> Option<SurfaceHandle> {
        self.active_surface().and_then(|id| self.session.surface(id))
    }

    pub(super) fn active_surface_with_handle(&self) -> Option<(SurfaceId, SurfaceHandle)> {
        let id = self.active_surface()?;
        Some((id, self.session.surface(id)?))
    }

    fn missing_input_surface(&self, input: &TerminalInput) -> Option<SurfaceId> {
        self.missing_input_surface_for_admission(input, None)
    }

    pub(super) fn missing_input_surface_for_admission(
        &self,
        input: &TerminalInput,
        admission: Option<&DeferredInputAdmission>,
    ) -> Option<SurfaceId> {
        let surface = match input {
            TerminalInput::Keyboard(_)
            | TerminalInput::ClearHistoryKey(_)
            | TerminalInput::Paste(_) => self
                .semantic_destination_for_input(input, admission)
                .or_else(|| self.active_surface())?,
            TerminalInput::FrontendAction { action: Action::SendPrefix, .. } => self
                .semantic_destination_for_input(input, admission)
                .or_else(|| self.active_surface())?,
            TerminalInput::Mouse(mouse) => {
                let area = self.pane_area_at(mouse.column, mouse.row)?;
                area.content.contains(mouse.column, mouse.row).then_some(area.surface)?
            }
            _ => return None,
        };
        (!self.session.surface_is_ready_for_input(surface)).then_some(surface)
    }

    pub(super) fn queue_surface_attach(&mut self, surface: SurfaceId) {
        if !self.session.can_attach_surface(surface) {
            return;
        }
        let size = self
            .pane_areas
            .iter()
            .find(|area| area.surface == surface)
            .map(PaneArea::content_size)
            .filter(|(cols, rows)| *cols > 0 && *rows > 0);
        self.session.attach_surface(surface, size);
    }

    pub(super) fn retry_pending_surface_attach(&mut self) {
        let surface = self
            .deferred_input
            .iter()
            .filter(|input| match &input.event {
                TerminalInput::Mouse(mouse) => !self.pointer_route_is_stale_for_mouse(mouse),
                _ => true,
            })
            .filter_map(|input| {
                self.missing_input_surface_for_admission(&input.event, Some(&input.admission))
            })
            .find(|surface| self.session.can_attach_surface(*surface))
            .or_else(|| {
                self.pending_pointer_motion
                    .filter(|pointer| !self.pointer_route_is_stale_for_mouse(&pointer.event))
                    .and_then(|pointer| {
                        self.missing_input_surface(&TerminalInput::Mouse(pointer.event))
                    })
                    .filter(|surface| self.session.can_attach_surface(*surface))
            });
        if let Some(surface) = surface {
            self.queue_surface_attach(surface);
        }
    }

    pub(super) fn active_screen_id(&self) -> Option<ScreenId> {
        self.tree.active_screen().map(|screen| screen.id)
    }

    pub(super) fn reassert_visible_surface_sizes(&mut self) {
        if self.config.sidebar.plugin.is_some()
            && self.sidebar_visible
            && self.sidebar_width >= 3
            && let Some(surface) = self.sidebar_surface_handle()
        {
            let rect = self.sidebar_plugin_rect();
            if rect.width > 0 && rect.height > 0 {
                let desired = (rect.width, rect.height);
                let needs_barrier = surface.resize_needed(rect.width, rect.height, true);
                if let Some(surface_id) = self.sidebar_plugin_surface
                    && !(surface.kind() == SurfaceKind::Browser
                        && self.browser_input.resize_failed(surface_id, desired))
                {
                    match self.session.surface_resize_decision(
                        surface_id,
                        (rect.width, rect.height),
                        needs_barrier,
                    ) {
                        SurfaceResizeDecision::Noop => {
                            if surface.kind() != SurfaceKind::Browser {
                                let _ = surface.reassert_size(rect.width, rect.height);
                            }
                        }
                        SurfaceResizeDecision::AlreadyClaimed | SurfaceResizeDecision::Failed => {}
                        SurfaceResizeDecision::NeedsQueue(claim)
                            if self.prepare_pty_input_before_mutation() =>
                        {
                            self.enqueue_surface_resize(
                                surface_id,
                                surface,
                                rect.width,
                                rect.height,
                                true,
                                Some(claim),
                            );
                        }
                        SurfaceResizeDecision::NeedsQueue(_) => {}
                    }
                }
            }
        }
        for index in 0..self.pane_areas.len() {
            let area = self.pane_areas[index];
            if area.content.width == 0 || area.content.height == 0 {
                continue;
            }
            if !self.session.has_surface(area.surface) && !self.prepare_pty_input_before_mutation()
            {
                return;
            }
            let desired = area.content_size();
            if let Some(surface) = self.session.surface(area.surface) {
                if surface.kind() == SurfaceKind::Browser
                    && self.browser_input.resize_failed(area.surface, desired)
                {
                    continue;
                }
                let needs_barrier = surface.resize_needed(desired.0, desired.1, true);
                match self.session.surface_resize_decision(area.surface, desired, needs_barrier) {
                    SurfaceResizeDecision::Noop => {
                        if surface.kind() != SurfaceKind::Browser {
                            let _ = surface.reassert_size(desired.0, desired.1);
                        }
                    }
                    SurfaceResizeDecision::AlreadyClaimed | SurfaceResizeDecision::Failed => {}
                    SurfaceResizeDecision::NeedsQueue(claim)
                        if self.prepare_pty_input_before_mutation() =>
                    {
                        self.enqueue_surface_resize(
                            area.surface,
                            surface,
                            desired.0,
                            desired.1,
                            true,
                            Some(claim),
                        );
                    }
                    SurfaceResizeDecision::NeedsQueue(_) => {}
                }
            } else if self.session.can_attach_surface(area.surface)
                && self.prepare_pty_input_before_mutation()
            {
                self.session.attach_surface(area.surface, Some(desired));
            }
        }
    }
}

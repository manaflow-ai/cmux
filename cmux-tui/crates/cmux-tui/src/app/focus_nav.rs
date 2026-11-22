//! Focus navigation: moving focus between panes and the sidebar, pane order,
//! swapping panes, scrolling the active surface, sidebar view toggles, and
//! the clear-history shortcut.

use cmux_tui_core::{Direction, PaneId, SurfaceId, SurfaceKind, ViewportLayoutResult};

use crate::app::{App, RenderAction, WorkspaceRailSelection, should_claim_clear_history_shortcut};
use crate::config::{SidebarResourceKind, SidebarView};
use crate::keys;
use crate::session::SurfaceHandle;

impl App {
    pub(super) fn move_focus(&mut self, direction: Direction) {
        if self.move_focus_between_sidebar_rails(direction) {
            return;
        }
        let Some(screen) = self.tree.active_screen() else {
            if matches!(direction, Direction::Left) {
                self.focus_rightmost_sidebar_rail();
            }
            return;
        };
        if screen.zoomed_pane.is_some() {
            if matches!(direction, Direction::Left) {
                self.focus_rightmost_sidebar_rail();
            }
            return;
        }
        let active = screen.active_pane;
        let (dx, dy) = match direction {
            Direction::Left => (-1, 0),
            Direction::Right => (1, 0),
            Direction::Up => (0, -1),
            Direction::Down => (0, 1),
        };
        let panes = if self.viewport_layout.is_empty() {
            self.pane_areas.iter().map(|area| (area.pane, area.rect.into())).collect()
        } else {
            self.viewport_layout.clone()
        };
        let layout = ViewportLayoutResult { panes, ..Default::default() };
        if let Some(next) =
            layout.neighbor_by_recency(active, dx, dy, |pane| self.pane_focus_history.recency(pane))
        {
            self.focus_pane_after_input(next);
        } else if matches!(direction, Direction::Left) {
            self.focus_rightmost_sidebar_rail();
        }
    }

    fn active_screen_pane_order(&self) -> Vec<PaneId> {
        self.tree
            .active_screen()
            .map(|screen| screen.panes.iter().map(|pane| pane.id).collect())
            .unwrap_or_default()
    }

    fn adjacent_pane_by_order(&self, delta: isize) -> Option<PaneId> {
        let active = self.active_pane()?;
        let panes = self.active_screen_pane_order();
        let position = panes.iter().position(|pane| *pane == active)?;
        let len = panes.len();
        if len < 2 {
            return None;
        }
        let next = (position as isize + delta).rem_euclid(len as isize) as usize;
        panes.get(next).copied()
    }

    pub(super) fn focus_next_pane(&mut self) {
        if let Some(next) = self.adjacent_pane_by_order(1) {
            self.focus_pane_after_input(next);
        }
    }

    pub(super) fn swap_pane_by_order(&mut self, delta: isize) {
        let Some(active) = self.active_pane() else { return };
        if let Some(target) = self.adjacent_pane_by_order(delta)
            && self.prepare_pty_input_before_mutation()
        {
            self.session.swap_pane(active, target);
        }
    }

    pub(super) fn scroll_active(&mut self, delta: isize) {
        if let Some(surface) = self.active_surface_handle() {
            if surface.kind() == SurfaceKind::Browser {
                return;
            }
            let _ = surface.scroll_delta(delta);
        }
    }

    pub(super) fn toggle_sidebar_focus(&mut self) {
        if self.sidebar_rail_focused() {
            self.leave_workspace_sidebar();
            self.sidebar_focus_pending = false;
            return;
        }
        if self.sidebar_focus_pending {
            self.sidebar_focus_pending = false;
            return;
        }
        self.focus_sidebar();
    }

    pub(super) fn focus_sidebar(&mut self) {
        if self.sidebar_rail_focused() || self.sidebar_focus_pending {
            return;
        }
        self.sidebar_visible = true;
        let requested = self.config.sidebar.plugin.is_some() && self.sync_sidebar_plugin(true);
        if self.config.sidebar.plugin.is_none() || self.sidebar_plugin_surface.is_some() {
            let order = self.focusable_rail_order();
            let preferred = order
                .iter()
                .copied()
                .find(|kind| {
                    self.view_index_for_rail(*kind)
                        .and_then(|index| self.config.sidebar.views.get(index))
                        .is_some_and(|view| view.includes(SidebarResourceKind::Workspaces))
                })
                .or_else(|| order.first().copied());
            if let Some(kind) = preferred {
                self.focus_rail(kind);
            }
            if self.config.sidebar.plugin.is_none() {
                if self.sidebar_view == SidebarView::Workspaces {
                    self.sidebar_workspace_selection = self.tree.active_workspace;
                    self.workspace_rail_selection = WorkspaceRailSelection::Workspace;
                    self.workspace_rail_follow_selection = true;
                } else if !self.sync_sidebar_files_to_focus(true) {
                    self.sidebar_files.refresh();
                }
            }
            self.menu = None;
            self.prompt = None;
            self.omnibar = None;
            self.replace_selection(None);
        } else if requested {
            self.sidebar_focus_pending = true;
        }
    }

    pub(super) fn toggle_sidebar_view(&mut self) {
        self.sidebar_view = self.sidebar_view.toggled();
        if self.config.sidebar.plugin.is_some() {
            return;
        }
        match self.sidebar_view {
            SidebarView::Files => {
                self.sidebar_followed_surface = None;
                if !self.sync_sidebar_files_to_focus(true) {
                    self.sidebar_files.refresh();
                }
            }
            SidebarView::Workspaces => {
                self.sidebar_workspace_selection = self.tree.active_workspace;
                self.workspace_rail_selection = WorkspaceRailSelection::Workspace;
                self.workspace_rail_follow_selection = true;
            }
        }
    }

    pub(super) fn sidebar_surface_handle(&self) -> Option<SurfaceHandle> {
        self.sidebar_plugin_surface.and_then(|surface| self.session.surface(surface))
    }

    #[cfg(test)]
    pub(super) fn run_clear_history_shortcut(
        &mut self,
        input: keys::KeyboardInput,
    ) -> RenderAction {
        self.run_clear_history_shortcut_to(input, None)
    }

    pub(super) fn run_clear_history_shortcut_to(
        &mut self,
        input: keys::KeyboardInput,
        destination: Option<SurfaceId>,
    ) -> RenderAction {
        let Some(surface_id) = destination.or_else(|| self.active_surface()) else {
            return RenderAction::None;
        };
        if !should_claim_clear_history_shortcut(
            self.tree.surface_kind(surface_id),
            self.session.supports_clear_history_key_fallback(surface_id),
        ) {
            let visible_state = self.visible_input_state(Some(surface_id));
            self.replace_selection(None);
            self.forward_key_to_surface(input, surface_id);
            let action =
                if self.status_message.is_some() { RenderAction::Draw } else { RenderAction::None };
            return action.merge(self.visible_input_action(visible_state));
        }
        let Some(key_input) = input.into_terminal_input() else {
            return RenderAction::None;
        };
        if self.session.surface(surface_id).is_none() {
            return RenderAction::None;
        }
        self.session.clear_history_or_send_key(
            surface_id,
            key_input,
            self.input_revision,
            self.selection,
            self.selection_generation,
        );
        if self.status_message.is_some() { RenderAction::Draw } else { RenderAction::None }
    }
}

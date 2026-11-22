//! Hit testing and tab moves: pane area and hit lookup, omnibar hits, moving
//! tabs between workspaces, and tab and workspace drop targets.

use cmux_tui_core::{PaneId, SurfaceId, SurfaceKind, WorkspaceId};

use crate::app::layout::{Hit, OmnibarHit, PaneArea, SidebarActionTarget};
use crate::app::menu::MenuItem;
use crate::app::{App, MenuAction};
use crate::config::Action;
use crate::localization;
use crate::machine::WorkspaceCreationPolicy;
use crate::sidebar_projection::{ProjectionBranch, ProjectionTarget};

impl App {
    pub(super) fn pane_area_at(&self, x: u16, y: u16) -> Option<&PaneArea> {
        self.pane_areas.iter().find(|a| a.rect.contains(x, y))
    }

    pub(super) fn hit_at(&self, x: u16, y: u16) -> Option<Hit> {
        self.hits.iter().find(|(rect, _)| rect.contains(x, y)).map(|(_, hit)| *hit)
    }

    pub(super) fn omnibar_hit_at(&self, x: u16, y: u16) -> Option<(PaneId, OmnibarHit)> {
        self.pane_areas.iter().find_map(|area| {
            let rect = area.omnibar?;
            if self.surface_kind(area.surface) != Some(SurfaceKind::Browser) {
                return None;
            }
            let editing = self
                .omnibar
                .as_ref()
                .is_some_and(|state| state.pane == area.pane && state.surface == area.surface);
            crate::ui::omnibar::hit(rect, area.omnibar_source_x(), x, y, editing)
                .map(|hit| (area.pane, hit))
        })
    }

    pub(super) fn move_tab_to_workspace(
        &mut self,
        surface: SurfaceId,
        workspace: Option<WorkspaceId>,
    ) {
        if self.surface_only.is_some()
            || !self.session.supports_tab_workspace_moves()
            || self.tab_location(surface).is_none()
        {
            return;
        }
        if workspace.is_none()
            && self.workspace_creation_policy() != Some(WorkspaceCreationPolicy::SessionOwned)
        {
            return;
        }
        if workspace.is_some_and(|id| !self.tree.workspaces().iter().any(|ws| ws.id == id)) {
            return;
        }
        if self.prepare_pty_input_before_mutation() {
            self.session.move_tab_to_workspace(surface, workspace);
        }
    }

    pub(super) fn tab_move_workspace_item(&self, surface: SurfaceId) -> Option<MenuItem> {
        if self.surface_only.is_some() || !self.session.supports_tab_workspace_moves() {
            return None;
        }
        let (source_pane, _) = self.tab_location(surface)?;
        let mut items = self
            .tree
            .workspaces()
            .iter()
            .filter(|ws| {
                !ws.screens
                    .iter()
                    .any(|screen| screen.panes.iter().any(|pane| pane.id == source_pane))
            })
            .map(|ws| MenuItem::LabeledAction {
                label: ws.name.clone(),
                action: MenuAction::MoveTabToWorkspace { surface, workspace: Some(ws.id) },
            })
            .collect::<Vec<_>>();
        if self.workspace_creation_policy() == Some(WorkspaceCreationPolicy::SessionOwned) {
            if !items.is_empty() {
                items.push(MenuItem::Separator);
            }
            items.push(MenuItem::Action(MenuAction::MoveTabToWorkspace {
                surface,
                workspace: None,
            }));
        }
        (!items.is_empty()).then(|| MenuItem::Submenu {
            label: localization::catalog().menu.move_tab_workspace.to_string(),
            items,
        })
    }

    pub(super) fn tab_workspace_drop_at(&self, x: u16, y: u16) -> Option<Option<WorkspaceId>> {
        match self.hit_at(x, y)? {
            Hit::CreateWorkspace { mode: None }
            | Hit::SidebarAction { action: SidebarActionTarget::CreateWorkspace(None), .. }
            | Hit::SidebarAction {
                action: SidebarActionTarget::Run(Action::NewWorkspace), ..
            } if self.workspace_creation_policy()
                == Some(WorkspaceCreationPolicy::SessionOwned) =>
            {
                Some(None)
            }
            Hit::Workspace { id, .. }
            | Hit::ProjectionRow { target: ProjectionTarget::Workspace { id, .. }, .. }
            | Hit::ProjectionToggle { branch: ProjectionBranch::Workspace(id), .. } => {
                Some(Some(id))
            }
            _ => None,
        }
    }

    pub(super) fn tab_drop_target_at(&self, x: u16, y: u16) -> Option<(PaneId, usize)> {
        let area = self.pane_areas.iter().find(|area| {
            area.bar.is_some_and(|bar| bar.contains(x, y)) || area.content.contains(x, y)
        })?;
        let pane = self.tree.pane(area.pane)?;
        let len = pane.tabs.len();
        if !area.bar.is_some_and(|bar| bar.contains(x, y)) {
            return Some((area.pane, len));
        }
        let mut tab_hits = self
            .hits
            .iter()
            .filter_map(|(rect, hit)| match hit {
                Hit::Tab { pane, index } if *pane == area.pane => Some((*rect, *index)),
                _ => None,
            })
            .collect::<Vec<_>>();
        tab_hits.sort_by_key(|(rect, index)| (rect.x, *index));
        for (rect, index) in &tab_hits {
            let mid = rect.x + rect.width / 2;
            if x < mid {
                return Some((area.pane, (*index).min(len)));
            }
            if rect.contains(x, y) {
                return Some((area.pane, (index + 1).min(len)));
            }
        }
        Some((area.pane, len))
    }

    pub(super) fn workspace_drop_target_at(&self, x: u16, y: u16) -> Option<usize> {
        let area = self.workspace_sidebar_area(self.content_area.height.saturating_add(1))?;
        if area.width < 3 || x < area.x || x >= area.x + area.width.saturating_sub(1) || y < area.y
        {
            return None;
        }
        let len = self.tree.workspaces().len();
        for index in 0..len {
            let start = area.y + 2 + index as u16 * 3;
            if y < start {
                return Some(index);
            }
            if y <= start + 1 {
                return Some(if y == start { index } else { index + 1 }.min(len));
            }
        }
        Some(len)
    }

    pub(super) fn tab_location(&self, surface: SurfaceId) -> Option<(PaneId, usize)> {
        self.tree
            .workspaces()
            .iter()
            .flat_map(|ws| ws.screens.iter())
            .flat_map(|screen| screen.panes.iter())
            .find_map(|pane| {
                pane.tabs
                    .iter()
                    .position(|tab| tab.surface == surface)
                    .map(|index| (pane.id, index))
            })
    }
}

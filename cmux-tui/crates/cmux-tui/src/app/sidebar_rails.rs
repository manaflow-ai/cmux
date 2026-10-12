//! Sidebar rails on the App: rail focus and order, rail areas, projection
//! rows, sidebar action rows and tab targets, and activating workspaces and
//! projection targets from the rails.

use std::collections::HashSet;

use cmux_tui_core::{Direction, PaneId, Rect};

use crate::app::frame_geometry::sidebar_layout_for_state;
use crate::app::layout::{
    FocusTarget, RailKind, SidebarActionRow, SidebarActionTarget, SidebarTabTarget,
};
use crate::app::menu::MenuItem;
use crate::app::{App, MenuAction, RenderAction, WorkspaceRailSelection};
use crate::config::{Action, SidebarColumnKind, SidebarResourceKind};
use crate::localization;
use crate::machine::WorkspaceCreationMode;
use crate::sidebar_projection::{ProjectionRailState, ProjectionRow, ProjectionTarget};

impl App {
    pub(super) fn reconcile_workspace_rail_selection(&mut self) {
        let actions = self.workspace_sidebar_action_rows();
        let selection_is_valid = match self.workspace_rail_selection {
            WorkspaceRailSelection::Workspace => true,
            WorkspaceRailSelection::Recoverable => self.machine_ui.as_ref().is_some_and(|ui| {
                self.sidebar_recoverable_workspace_selection < ui.recoverable_workspaces().len()
            }),
            WorkspaceRailSelection::Action(target) => {
                actions.iter().any(|action| action.target == target)
            }
        };
        if self.workspace_rail_selection != WorkspaceRailSelection::Workspace && !selection_is_valid
        {
            self.workspace_rail_selection = actions
                .first()
                .map(|action| WorkspaceRailSelection::Action(action.target))
                .unwrap_or(WorkspaceRailSelection::Workspace);
        }
    }

    pub fn workspace_sidebar_focused(&self) -> bool {
        self.focus == FocusTarget::WorkspaceRail
    }

    pub fn machine_sidebar_focused(&self) -> bool {
        self.focus == FocusTarget::MachineRail
    }

    pub fn tabs_sidebar_focused(&self) -> bool {
        self.focus == FocusTarget::TabsRail
    }

    pub(super) fn sidebar_rail_focused(&self) -> bool {
        matches!(
            self.focus,
            FocusTarget::MachineRail
                | FocusTarget::WorkspaceRail
                | FocusTarget::TabsRail
                | FocusTarget::ProjectionRail(_)
        )
    }

    fn focused_rail_kind(&self) -> Option<RailKind> {
        match self.focus {
            FocusTarget::MachineRail => Some(RailKind::Machine),
            FocusTarget::WorkspaceRail => Some(RailKind::Workspace),
            FocusTarget::TabsRail => Some(RailKind::Tabs),
            FocusTarget::ProjectionRail(index) => Some(RailKind::Projection(index)),
            FocusTarget::Pane => None,
        }
    }

    pub(super) fn focused_sidebar_view_id(&self) -> Option<String> {
        let rail = self.focused_rail_kind()?;
        self.view_index_for_rail(rail)
            .and_then(|index| self.config.sidebar.views.get(index))
            .map(|view| view.id.clone())
    }

    fn fallback_sidebar_area(&self, kind: RailKind, height: u16) -> Option<Rect> {
        let width_for = |candidate| match candidate {
            RailKind::Machine => self.machine_sidebar_width,
            RailKind::Workspace => self.sidebar_width,
            RailKind::Tabs => self.tabs_sidebar_width,
            RailKind::Projection(_) => 0,
        };
        let width = width_for(kind);
        if width == 0 {
            return None;
        }
        let mut x = 0u16;
        for column in &self.config.sidebar.columns {
            let candidate = match column.kind {
                SidebarColumnKind::Machines => RailKind::Machine,
                SidebarColumnKind::Workspaces => RailKind::Workspace,
                SidebarColumnKind::Tabs => RailKind::Tabs,
            };
            if candidate == kind {
                return Some(Rect { x, y: 0, width, height });
            }
            x = x.saturating_add(width_for(candidate));
        }
        None
    }

    pub fn machine_sidebar_area(&self, height: u16) -> Option<Rect> {
        self.sidebar_layout
            .machine
            .or_else(|| self.fallback_sidebar_area(RailKind::Machine, height))
    }

    pub fn workspace_sidebar_area(&self, height: u16) -> Option<Rect> {
        self.sidebar_layout
            .workspace
            .or_else(|| self.fallback_sidebar_area(RailKind::Workspace, height))
    }

    pub fn tabs_sidebar_area(&self, height: u16) -> Option<Rect> {
        self.sidebar_layout.tabs.or_else(|| self.fallback_sidebar_area(RailKind::Tabs, height))
    }

    pub(crate) fn projection_sidebar_area(&self, index: usize) -> Option<Rect> {
        self.sidebar_layout.rail(RailKind::Projection(index))
    }

    pub(crate) fn projection_sidebar_focused(&self, index: usize) -> bool {
        self.focus == FocusTarget::ProjectionRail(index)
    }

    pub(crate) fn projection_rows(&mut self, index: usize) -> Vec<ProjectionRow> {
        let Some(spec) = self.config.sidebar.views.get(index) else { return Vec::new() };
        let empty_collapsed = HashSet::new();
        let collapsed = self
            .projection_rails
            .get(&spec.id)
            .map(|state| &state.collapsed)
            .unwrap_or(&empty_collapsed);
        let agents = if spec.includes(SidebarResourceKind::Agents) {
            // Finished reports are historical records, not active agents.
            // Otherwise detached "surface..." rows remain forever after exit.
            self.session
                .agents()
                .into_iter()
                .filter(|agent| !matches!(agent.state.as_str(), "done" | "unknown"))
                .collect::<Vec<_>>()
        } else {
            Vec::new()
        };
        crate::sidebar_projection::rows_cached(
            spec,
            &self.tree,
            &agents,
            self.sidebar_workspace_selection,
            collapsed,
            &mut self.projection_order_cache,
        )
    }

    pub(crate) fn sidebar_action_rows(&self, index: usize) -> Vec<SidebarActionRow> {
        let Some(spec) = self.config.sidebar.views.get(index) else { return Vec::new() };
        let messages = &localization::catalog().sidebar;
        spec.actions
            .iter()
            .flat_map(|action_spec| {
                let action = action_spec.action;
                let label_override = action_spec.label.as_deref();
                if action == Action::NewWorkspace {
                    return self
                        .workspace_creation_modes()
                        .into_iter()
                        .map(|mode| SidebarActionRow {
                            label: match mode {
                                // A configured label renames the plain
                                // button; the provider-specific isolated and
                                // shared variants keep their catalog labels.
                                None => {
                                    label_override.unwrap_or(messages.new_workspace).to_string()
                                }
                                Some(WorkspaceCreationMode::Isolated) => {
                                    messages.new_isolated_workspace.to_string()
                                }
                                Some(WorkspaceCreationMode::Host) => {
                                    messages.new_shared_workspace.to_string()
                                }
                            },
                            target: SidebarActionTarget::CreateWorkspace(mode),
                        })
                        .collect::<Vec<_>>();
                }
                self.action_available(action)
                    .then(|| SidebarActionRow {
                        label: label_override
                            .map(str::to_string)
                            .unwrap_or_else(|| self.action_display_label(action).to_string()),
                        target: SidebarActionTarget::Run(action),
                    })
                    .into_iter()
                    .collect()
            })
            .collect()
    }

    /// Menu items for a configurable `+` button's right-click menu.
    pub(super) fn plus_menu_items(
        &self,
        plus: &crate::config::PlusButton,
        pane: Option<PaneId>,
    ) -> Vec<MenuItem> {
        plus.menu
            .iter()
            .filter(|spec| self.action_available(spec.action))
            .map(|spec| MenuItem::LabeledAction {
                label: spec
                    .label
                    .clone()
                    .unwrap_or_else(|| self.action_display_label(spec.action).to_string()),
                action: MenuAction::RunConfigured { action: spec.action, pane },
            })
            .collect()
    }

    /// Where the workspace rail's pinned action buttons render.
    pub(crate) fn workspace_actions_position(&self) -> crate::config::ActionsPosition {
        self.view_index_for_rail(RailKind::Workspace)
            .and_then(|index| self.config.sidebar.views.get(index))
            .map(|spec| spec.actions_position)
            .unwrap_or_default()
    }

    /// Expand the configured workspace row label template. The default
    /// template borrows the name, so ordinary draws do not allocate.
    pub(crate) fn workspace_button_label<'a>(
        &self,
        index: usize,
        name: &'a str,
    ) -> std::borrow::Cow<'a, str> {
        let template = &self.config.sidebar.workspace_label;
        if template == "{name}" {
            return std::borrow::Cow::Borrowed(name);
        }
        std::borrow::Cow::Owned(
            template.replace("{index}", &index.to_string()).replace("{name}", name),
        )
    }

    pub(crate) fn projection_rail_state_mut(&mut self, index: usize) -> &mut ProjectionRailState {
        let id = self
            .config
            .sidebar
            .views
            .get(index)
            .map(|view| view.id.clone())
            .unwrap_or_else(|| format!("missing-{index}"));
        self.projection_rails.entry(id).or_default()
    }

    pub(super) fn invoke_sidebar_action(
        &mut self,
        target: SidebarActionTarget,
    ) -> anyhow::Result<RenderAction> {
        match target {
            SidebarActionTarget::Run(action) => self.run_action(action),
            SidebarActionTarget::CreateWorkspace(mode) => {
                self.create_workspace(mode, None)?;
                Ok(RenderAction::Draw)
            }
        }
    }

    pub(crate) fn sidebar_tab_targets(&self) -> Vec<SidebarTabTarget> {
        if self.workspace_rail_selection != WorkspaceRailSelection::Workspace {
            return Vec::new();
        }
        let workspace_index =
            self.sidebar_workspace_selection.min(self.tree.workspaces().len().saturating_sub(1));
        let Some(workspace) = self.tree.workspaces().get(workspace_index) else {
            return Vec::new();
        };
        workspace
            .screens
            .iter()
            .enumerate()
            .flat_map(|(screen_index, screen)| {
                screen.panes.iter().flat_map(move |pane| {
                    pane.tabs.iter().enumerate().map(move |(tab_index, tab)| {
                        let name = tab
                            .name
                            .as_deref()
                            .filter(|name| !name.is_empty())
                            .or_else(|| (!tab.title.is_empty()).then_some(tab.title.as_str()))
                            .unwrap_or(tab.short_id.as_str())
                            .to_string();
                        let subtitle = if workspace.screens.len() > 1 {
                            format!("{} · {}", screen.display_name(screen_index), pane.short_id)
                        } else {
                            pane.short_id.clone()
                        };
                        let active = workspace_index == self.tree.active_workspace
                            && screen_index == workspace.active_screen
                            && pane.id == screen.active_pane
                            && tab_index == pane.active_tab;
                        SidebarTabTarget {
                            workspace: workspace_index,
                            screen: screen_index,
                            pane: pane.id,
                            index: tab_index,
                            surface: tab.surface,
                            name,
                            subtitle,
                            active,
                        }
                    })
                })
            })
            .collect()
    }

    pub(super) fn activate_sidebar_tab(&mut self, target: &SidebarTabTarget) -> anyhow::Result<()> {
        if !self.prepare_pty_input_before_mutation() {
            return Ok(());
        }
        if !self.tree.select_surface(target.surface) {
            return Ok(());
        }
        self.follow_sidebar_workspace(target.workspace);
        self.pane_focus_history.record(target.pane);
        self.claim_active_terminal_geometry(true);
        Ok(())
    }

    fn follow_sidebar_workspace(&mut self, index: usize) {
        if self.sidebar_workspace_selection != index {
            self.tabs_rail_selection = 0;
            self.tabs_rail_scroll = 0;
        }
        self.sidebar_workspace_selection = index;
        self.workspace_rail_selection = WorkspaceRailSelection::Workspace;
    }

    pub(super) fn activate_workspace(&mut self, index: usize) {
        if index >= self.tree.workspaces().len() || !self.prepare_pty_input_before_mutation() {
            return;
        }
        self.follow_sidebar_workspace(index);
        self.tree.active_workspace = index;
        self.select_workspace_for_client(Some(index), None);
    }

    pub(super) fn activate_projection_target(
        &mut self,
        target: ProjectionTarget,
    ) -> anyhow::Result<()> {
        match target {
            ProjectionTarget::Workspace { id, .. } => {
                // The hit map can outlive a tree snapshot while a remote
                // reorder is queued. Resolve the stable workspace identity
                // again instead of applying a stale row index.
                let Some(index) =
                    self.tree.workspaces().iter().position(|workspace| workspace.id == id)
                else {
                    return Ok(());
                };
                self.activate_workspace(index);
            }
            ProjectionTarget::Pane { workspace, screen, pane } => {
                if !self.prepare_pty_input_before_mutation() {
                    return Ok(());
                }
                self.follow_sidebar_workspace(workspace);
                self.tree.active_workspace = workspace;
                self.tree.set_active_screen(workspace, screen);
                self.tree.set_active_pane(workspace, screen, pane);
                self.pane_focus_history.record(pane);
                self.claim_active_terminal_geometry(true);
            }
            ProjectionTarget::Surface { workspace, screen, pane, index, surface, .. } => {
                self.activate_sidebar_tab(&SidebarTabTarget {
                    workspace,
                    screen,
                    pane,
                    index,
                    surface,
                    name: String::new(),
                    subtitle: String::new(),
                    active: false,
                })?;
            }
        }
        Ok(())
    }

    pub fn total_sidebar_width(&self) -> u16 {
        let layout_width = self.sidebar_layout.total_width();
        if layout_width > 0 {
            layout_width
        } else {
            self.machine_sidebar_width
                .saturating_add(self.sidebar_width)
                .saturating_add(self.tabs_sidebar_width)
        }
    }

    pub(super) fn visible_rail_order(&self) -> Vec<RailKind> {
        self.sidebar_layout.ordered.iter().map(|placement| placement.kind).collect()
    }

    pub(super) fn focusable_rail_order(&self) -> Vec<RailKind> {
        let order = self.visible_rail_order();
        if !order.is_empty() {
            return order;
        }
        let size = (
            self.sidebar_layout.content.x.saturating_add(self.sidebar_layout.content.width),
            self.sidebar_layout.content.height.saturating_add(1),
        );
        if size.0 == 0 || size.1 == 0 {
            return Vec::new();
        }
        let hidden_views = self
            .hidden_sidebar_views
            .get(&self.config.sidebar.active_profile)
            .cloned()
            .unwrap_or_default();
        sidebar_layout_for_state(
            &self.config,
            true,
            self.sidebar_compact,
            self.machine_ui.is_some(),
            size,
            self.sidebar_width_override,
            self.machine_sidebar_width_override,
            self.tabs_sidebar_width_override,
            &self.projection_sidebar_width_overrides,
            &hidden_views,
            None,
        )
        .ordered
        .iter()
        .map(|placement| placement.kind)
        .collect()
    }

    pub(super) fn rail_kind_for_view(&self, index: usize) -> RailKind {
        self.config.sidebar.views.get(index).and_then(|view| view.legacy_kind()).map_or(
            RailKind::Projection(index),
            |kind| match kind {
                SidebarColumnKind::Machines => RailKind::Machine,
                SidebarColumnKind::Workspaces => RailKind::Workspace,
                SidebarColumnKind::Tabs => RailKind::Tabs,
            },
        )
    }

    pub(crate) fn view_index_for_rail(&self, kind: RailKind) -> Option<usize> {
        self.sidebar_layout
            .ordered
            .iter()
            .find(|placement| placement.kind == kind)
            .map(|placement| placement.view_index)
            .or_else(|| {
                self.config.sidebar.views.iter().enumerate().find_map(|(index, _)| {
                    (self.rail_kind_for_view(index) == kind).then_some(index)
                })
            })
    }

    pub(crate) fn workspace_sidebar_action_rows(&self) -> Vec<SidebarActionRow> {
        self.view_index_for_rail(RailKind::Workspace)
            .map(|index| self.sidebar_action_rows(index))
            .unwrap_or_default()
    }

    pub(super) fn focus_rail(&mut self, kind: RailKind) {
        self.focus = match kind {
            RailKind::Machine => FocusTarget::MachineRail,
            RailKind::Workspace => FocusTarget::WorkspaceRail,
            RailKind::Tabs => FocusTarget::TabsRail,
            RailKind::Projection(index) => FocusTarget::ProjectionRail(index),
        };
    }

    pub(super) fn focus_adjacent_rail(&mut self, kind: RailKind, delta: isize) -> bool {
        let order = self.visible_rail_order();
        let Some(index) = order.iter().position(|candidate| *candidate == kind) else {
            return false;
        };
        let next = index as isize + delta;
        let Some(next) = usize::try_from(next).ok().filter(|next| *next < order.len()) else {
            return false;
        };
        self.focus_rail(order[next]);
        true
    }

    pub(super) fn move_focus_between_sidebar_rails(&mut self, direction: Direction) -> bool {
        let Some(kind) = self.focused_rail_kind() else { return false };
        match direction {
            Direction::Left => {
                self.focus_adjacent_rail(kind, -1);
                true
            }
            Direction::Right => {
                if !self.focus_adjacent_rail(kind, 1) {
                    self.focus = FocusTarget::Pane;
                }
                true
            }
            Direction::Up | Direction::Down => false,
        }
    }

    pub(super) fn focus_rightmost_sidebar_rail(&mut self) -> bool {
        if !self.sidebar_visible || self.surface_only.is_some() {
            return false;
        }
        let Some(kind) = self.visible_rail_order().last().copied() else {
            return false;
        };
        self.focus_rail(kind);
        true
    }

    pub(super) fn leave_workspace_sidebar(&mut self) {
        if self.sidebar_rail_focused() {
            self.focus = FocusTarget::Pane;
        }
    }
}

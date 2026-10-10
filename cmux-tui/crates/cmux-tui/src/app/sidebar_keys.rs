//! Sidebar key handling: the machine, projection, builtin and tabs sidebar
//! key handlers.

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

use crate::app::layout::{FocusTarget, RailKind};
use crate::app::{
    App, MachineRailCommand, RenderAction, WorkspaceRailTarget, rail_navigation_index,
    rail_page_size,
};
use crate::config::{Action, SidebarView};
use crate::machine::{MachineRailTarget, ManagedMachineStatus};

impl App {
    pub(super) fn handle_machine_sidebar_key(&mut self, key: &KeyEvent) -> RenderAction {
        if self.config.keys.action_for(key) == Some(Action::ProviderMenu)
            || (!self.config.keys.provider_menu_overridden
                && key.modifiers == KeyModifiers::NONE
                && key.code == KeyCode::Char('m'))
        {
            let _ = self.open_provider_rail_menu(1, 2);
            return RenderAction::Draw;
        }
        if matches!(key.code, KeyCode::Left | KeyCode::Char('h')) {
            self.focus_adjacent_rail(RailKind::Machine, -1);
            return RenderAction::Draw;
        }
        if matches!(key.code, KeyCode::Right | KeyCode::Char('l')) {
            if !self.focus_adjacent_rail(RailKind::Machine, 1) {
                self.focus = FocusTarget::Pane;
            }
            return RenderAction::Draw;
        }
        if key.code == KeyCode::Esc {
            self.focus = FocusTarget::Pane;
            return RenderAction::Draw;
        }
        if key.code == KeyCode::Enter
            && self.machine_ui.as_ref().is_some_and(|machine| {
                matches!(
                    machine.rail_target(),
                    Some(MachineRailTarget::Machine(key))
                        if Some(key) == machine.snapshot.active && machine.session_available
                )
            })
        {
            // Enter on the open machine means "enter the machine", not
            // "remain trapped in its rail row".
            self.focus = FocusTarget::Pane;
            return RenderAction::Draw;
        }
        if matches!(
            key.code,
            KeyCode::Up
                | KeyCode::Down
                | KeyCode::Char('j' | 'k')
                | KeyCode::Home
                | KeyCode::End
                | KeyCode::PageUp
                | KeyCode::PageDown
        ) {
            self.machine_rail_follow_selection = true;
        }
        let page = rail_page_size(self.sidebar_layout.machine);
        let command = {
            let Some(machine) = self.machine_ui.as_mut() else {
                self.focus = FocusTarget::Pane;
                return RenderAction::Draw;
            };
            let targets = machine.rail_targets();
            let current = machine
                .rail_target()
                .and_then(|selected| targets.iter().position(|target| *target == selected))
                .unwrap_or_default();
            let provider_menu = self.config.keys.action_for(key) == Some(Action::ProviderMenu)
                || (!self.config.keys.provider_menu_overridden
                    && key.modifiers == KeyModifiers::NONE
                    && key.code == KeyCode::Char('m'));
            if provider_menu {
                // Resolve the configured action before the built-in movement
                // keys. A valid provider-menu binding may intentionally use
                // j, k, h, l, or an arrow key.
                Some(MachineRailCommand::ProviderMenu)
            } else if let Some(next) = rail_navigation_index(key, current, targets.len(), page) {
                if let Some(target) = targets.get(next).copied() {
                    machine.select_rail_target(target);
                }
                None
            } else if let Some(MachineRailTarget::Machine(machine_key)) =
                targets.get(current).copied()
            {
                let managed = machine.managed_machine(machine_key);
                let client_renamable = machine.is_client_machine_renamable(machine_key);
                match key.code {
                    KeyCode::Char('r')
                        if client_renamable
                            || managed.is_some_and(|managed| {
                                managed.status == ManagedMachineStatus::Active
                                    && managed.capabilities.rename
                            }) =>
                    {
                        Some(MachineRailCommand::Rename(machine_key))
                    }
                    KeyCode::Char('d') | KeyCode::Delete
                        if managed.is_some_and(|managed| {
                            managed.status == ManagedMachineStatus::Active
                                && managed.capabilities.delete
                        }) =>
                    {
                        Some(MachineRailCommand::Delete(machine_key))
                    }
                    KeyCode::Char('p') | KeyCode::Delete
                        if managed.is_some_and(|managed| {
                            managed.status == ManagedMachineStatus::Recoverable
                                && managed.capabilities.purge
                        }) =>
                    {
                        Some(MachineRailCommand::Purge(machine_key))
                    }
                    KeyCode::Enter
                        if Some(machine_key) != machine.snapshot.active
                            || managed.is_some_and(|managed| {
                                managed.status == ManagedMachineStatus::Recoverable
                                    && managed.capabilities.restore
                            }) =>
                    {
                        Some(MachineRailCommand::Activate(machine_key))
                    }
                    _ => None,
                }
            } else if key.code == KeyCode::Enter {
                match targets.get(current).copied() {
                    Some(MachineRailTarget::NewVm) => Some(MachineRailCommand::Create),
                    Some(MachineRailTarget::ConnectMachine) => Some(MachineRailCommand::Connect),
                    Some(MachineRailTarget::Machine(_)) | None => None,
                }
            } else {
                None
            }
        };
        match command {
            Some(MachineRailCommand::Activate(machine)) => {
                self.activate_machine(machine);
                self.focus = FocusTarget::Pane;
            }
            Some(MachineRailCommand::Rename(machine)) => {
                self.open_rename_machine_prompt(machine);
            }
            Some(MachineRailCommand::Delete(machine)) => {
                self.open_delete_managed_machine_prompt(machine);
            }
            Some(MachineRailCommand::Purge(machine)) => {
                self.open_purge_managed_machine_prompt(machine);
            }
            Some(MachineRailCommand::ProviderMenu) => {
                self.open_provider_rail_menu(1, 2);
            }
            Some(MachineRailCommand::Create) => {
                self.open_machine_creation_menu(1, 3);
            }
            Some(MachineRailCommand::Connect) => {
                self.open_machine_connection_menu(1, 3);
            }
            None => {}
        }
        RenderAction::Draw
    }

    pub(super) fn handle_projection_sidebar_key(
        &mut self,
        view_index: usize,
        key: &KeyEvent,
    ) -> anyhow::Result<RenderAction> {
        if key.code == KeyCode::Esc {
            self.focus = FocusTarget::Pane;
            return Ok(RenderAction::Draw);
        }
        let rows = self.projection_rows(view_index);
        let actions = self.sidebar_action_rows(view_index);
        let selectable_rows = rows.len().saturating_add(actions.len());
        let current = self
            .config
            .sidebar
            .views
            .get(view_index)
            .and_then(|view| self.projection_rails.get(&view.id))
            .map_or(0, |state| match state.selected_action {
                Some(index) if index < actions.len() => rows.len().saturating_add(index),
                Some(_) => selectable_rows,
                None => state.selected.min(selectable_rows.saturating_sub(1)),
            });
        let selected = rows.get(current).cloned();
        if matches!(key.code, KeyCode::Left | KeyCode::Char('h')) {
            if !key.modifiers.contains(KeyModifiers::ALT)
                && let Some(branch) = selected.as_ref().and_then(|row| row.branch)
                && selected.as_ref().is_some_and(|row| row.expanded)
            {
                self.projection_rail_state_mut(view_index).collapsed.insert(branch);
            } else {
                self.focus_adjacent_rail(RailKind::Projection(view_index), -1);
            }
            return Ok(RenderAction::Draw);
        }
        if matches!(key.code, KeyCode::Right | KeyCode::Char('l')) {
            if !key.modifiers.contains(KeyModifiers::ALT)
                && let Some(branch) = selected.as_ref().and_then(|row| row.branch)
                && selected.as_ref().is_some_and(|row| !row.expanded)
            {
                self.projection_rail_state_mut(view_index).collapsed.remove(&branch);
            } else if !self.focus_adjacent_rail(RailKind::Projection(view_index), 1) {
                self.focus = FocusTarget::Pane;
            }
            return Ok(RenderAction::Draw);
        }
        let page = self
            .projection_sidebar_area(view_index)
            .map_or(1, |area| usize::from(area.height.saturating_sub(2)).max(1));
        if let Some(next) = rail_navigation_index(key, current, selectable_rows, page) {
            let state = self.projection_rail_state_mut(view_index);
            if next < rows.len() {
                state.selected = next;
                state.selected_action = None;
            } else {
                state.selected_action = Some(next.saturating_sub(rows.len()));
            }
            state.follow_selection = true;
            return Ok(RenderAction::Draw);
        }
        if matches!(key.code, KeyCode::Char(' '))
            && let Some(branch) = selected.as_ref().and_then(|row| row.branch)
        {
            let state = self.projection_rail_state_mut(view_index);
            if !state.collapsed.remove(&branch) {
                state.collapsed.insert(branch);
            }
            return Ok(RenderAction::Draw);
        }
        if key.code == KeyCode::Enter {
            if let Some(row) = selected {
                self.activate_projection_target(row.target)?;
                self.focus = FocusTarget::Pane;
            } else if let Some(action) = current
                .checked_sub(rows.len())
                .and_then(|index| actions.get(index))
                .map(|action| action.target)
            {
                return self.invoke_sidebar_action(action);
            }
        }
        Ok(RenderAction::Draw)
    }
}

impl App {
    pub(super) fn handle_builtin_sidebar_key(
        &mut self,
        key: &KeyEvent,
    ) -> anyhow::Result<RenderAction> {
        if key.code == KeyCode::Tab {
            return self.run_action(Action::ToggleSidebarView);
        }
        if matches!(key.code, KeyCode::Left | KeyCode::Char('h')) {
            let moved = self.focus_adjacent_rail(RailKind::Workspace, -1);
            if moved
                || self.sidebar_view == SidebarView::Workspaces
                || key.modifiers.contains(KeyModifiers::ALT)
            {
                return Ok(RenderAction::Draw);
            }
        }
        if (self.sidebar_view == SidebarView::Workspaces
            || key.modifiers.contains(KeyModifiers::ALT))
            && matches!(key.code, KeyCode::Right | KeyCode::Char('l'))
        {
            if !self.focus_adjacent_rail(RailKind::Workspace, 1) {
                self.focus = FocusTarget::Pane;
            }
            return Ok(RenderAction::Draw);
        }
        if key.code == KeyCode::Esc {
            self.focus = FocusTarget::Pane;
            return Ok(RenderAction::Draw);
        }
        match self.sidebar_view {
            SidebarView::Files => {
                if let Some(command) = self.sidebar_files.handle_key(key) {
                    self.run_file_command(command);
                }
            }
            SidebarView::Workspaces => {
                if matches!(
                    key.code,
                    KeyCode::Up
                        | KeyCode::Down
                        | KeyCode::Char('j' | 'k')
                        | KeyCode::Home
                        | KeyCode::End
                        | KeyCode::PageUp
                        | KeyCode::PageDown
                ) {
                    self.workspace_rail_follow_selection = true;
                }
                let targets = self.workspace_rail_targets();
                let current = self
                    .workspace_rail_target()
                    .and_then(|selected| targets.iter().position(|target| target == &selected))
                    .unwrap_or_default();
                let page = rail_page_size(self.sidebar_layout.workspace);
                if let Some(next) = rail_navigation_index(key, current, targets.len(), page) {
                    if let Some(target) = targets.get(next).cloned() {
                        self.select_workspace_rail_target(target);
                    }
                } else if key.code == KeyCode::Enter {
                    match targets.get(current).cloned() {
                        Some(WorkspaceRailTarget::Workspace(id)) => {
                            if let Some(index) = self
                                .tree
                                .workspaces()
                                .iter()
                                .position(|workspace| workspace.id == id)
                            {
                                self.select_workspace_for_client(Some(index), None);
                                self.focus = FocusTarget::Pane;
                            }
                        }
                        Some(WorkspaceRailTarget::Action(action)) => {
                            return self.invoke_sidebar_action(action);
                        }
                        Some(WorkspaceRailTarget::Recoverable(id)) => {
                            self.request_restore_managed_workspace(&id);
                            self.focus = FocusTarget::Pane;
                        }
                        None => {}
                    }
                }
            }
        }
        Ok(RenderAction::Draw)
    }

    pub(super) fn handle_tabs_sidebar_key(
        &mut self,
        key: &KeyEvent,
    ) -> anyhow::Result<RenderAction> {
        if matches!(key.code, KeyCode::Left | KeyCode::Char('h')) {
            self.focus_adjacent_rail(RailKind::Tabs, -1);
            return Ok(RenderAction::Draw);
        }
        if matches!(key.code, KeyCode::Right | KeyCode::Char('l')) {
            if !self.focus_adjacent_rail(RailKind::Tabs, 1) {
                self.focus = FocusTarget::Pane;
            }
            return Ok(RenderAction::Draw);
        }
        if key.code == KeyCode::Esc {
            self.focus = FocusTarget::Pane;
            return Ok(RenderAction::Draw);
        }
        if matches!(
            key.code,
            KeyCode::Up
                | KeyCode::Down
                | KeyCode::Char('j' | 'k')
                | KeyCode::Home
                | KeyCode::End
                | KeyCode::PageUp
                | KeyCode::PageDown
        ) {
            self.tabs_rail_follow_selection = true;
        }
        let targets = self.sidebar_tab_targets();
        self.tabs_rail_selection = self.tabs_rail_selection.min(targets.len().saturating_sub(1));
        let page = rail_page_size(self.sidebar_layout.tabs);
        if let Some(next) =
            rail_navigation_index(key, self.tabs_rail_selection, targets.len(), page)
        {
            self.tabs_rail_selection = next;
        } else if key.code == KeyCode::Enter
            && let Some(target) = targets.get(self.tabs_rail_selection)
        {
            self.activate_sidebar_tab(target)?;
            self.focus = FocusTarget::Pane;
        }
        Ok(RenderAction::Draw)
    }
}

//! Building context menus: menu item and group helpers, action availability
//! and labels, sidebar view and profile items, opening a menu, and
//! `build_context_menu`; plus the attached-clients menu.

use cmux_tui_core::{BrowserSource, SurfaceId, SurfaceKind};

use crate::app::layout::{FocusTarget, Hit, RailKind};
use crate::app::menu::MenuItem;
use crate::app::menu::context_menu::{ContextMenu, pane_context_menu_groups};
use crate::app::menu::items::terminal_size_menu_item;
use crate::app::{App, MenuAction, action_available_in_mode, keyboard_action_for_menu};
use crate::config::{Action, SidebarColumn, SidebarResourceKind};
use crate::localization;
use crate::machine::ManagedMachineStatus;
use crate::session::ClientInfo;
use crate::sidebar_projection::{ProjectionBranch, ProjectionTarget};

impl App {
    fn menu_item(&self, action: MenuAction) -> MenuItem {
        self.menu_action_matches_keyboard_target(action)
            .then(|| keyboard_action_for_menu(action))
            .flatten()
            .and_then(|bound| self.config.keys.shortcut_label(bound))
            .map(|shortcut| MenuItem::ActionWithShortcut { action, shortcut })
            .unwrap_or(MenuItem::Action(action))
    }

    fn menu_action_matches_keyboard_target(&self, action: MenuAction) -> bool {
        match action {
            MenuAction::RenameWorkspace(workspace) | MenuAction::CloseWorkspace(workspace) => {
                self.tree.active_workspace().is_some_and(|active| active.id == workspace)
            }
            MenuAction::RenameScreen(screen) | MenuAction::CloseScreen(screen) => {
                self.tree.active_screen().is_some_and(|active| active.id == screen)
            }
            MenuAction::BrowserBack(pane)
            | MenuAction::BrowserForward(pane)
            | MenuAction::BrowserReload(pane)
            | MenuAction::BrowserEditUrl(pane)
            | MenuAction::RenameTab(pane)
            | MenuAction::NewPaneSmart(pane)
            | MenuAction::NewTab(pane)
            | MenuAction::NewBrowserTab(pane)
            | MenuAction::SplitRight(pane)
            | MenuAction::SplitDown(pane)
            | MenuAction::CloseTab(pane)
            | MenuAction::ClosePane(pane)
            | MenuAction::TogglePaneZoom { pane, .. } => self.active_pane() == Some(pane),
            _ => true,
        }
    }

    fn menu_group(&self, actions: impl IntoIterator<Item = MenuAction>) -> Vec<MenuItem> {
        actions
            .into_iter()
            .filter(|action| {
                keyboard_action_for_menu(*action)
                    .is_none_or(|keyboard_action| self.action_available(keyboard_action))
            })
            .map(|action| self.menu_item(action))
            .collect()
    }

    pub(crate) fn action_available(&self, action: Action) -> bool {
        action_available_in_mode(action, self.surface_only.is_some())
    }

    /// The display label for an action: the localized catalog label, or the
    /// user's configured command name for `Action::UserCommand`.
    pub(crate) fn action_display_label(&self, action: Action) -> &str {
        if let Some(index) = action.user_command_index()
            && let Some(command) = self.config.commands.get(index)
        {
            return command.name.as_str();
        }
        localization::catalog().action_label(action)
    }

    fn sidebar_menu_actions(&self) -> Vec<MenuAction> {
        vec![
            MenuAction::ToggleSidebar { visible: self.sidebar_visible },
            MenuAction::ToggleSidebarCompact { compact: self.sidebar_compact },
            MenuAction::FocusSidebar,
        ]
    }

    fn sidebar_view_name(&self, index: usize) -> String {
        let messages = &localization::catalog().sidebar;
        let Some(view) = self.config.sidebar.views.get(index) else { return String::new() };
        match view.levels.as_slice() {
            [SidebarResourceKind::Machines] => messages.machines.to_string(),
            [SidebarResourceKind::Workspaces] => messages.workspaces.to_string(),
            [SidebarResourceKind::Tabs] => messages.tabs.to_string(),
            _ => view.id.clone(),
        }
    }

    fn sidebar_view_visibility_item(&self, index: usize) -> Option<MenuItem> {
        let view = self.config.sidebar.views.get(index)?;
        let hidden = self
            .hidden_sidebar_views
            .get(&self.config.sidebar.active_profile)
            .is_some_and(|hidden| hidden.contains(&view.id));
        let template = if hidden {
            localization::catalog().menu.show_sidebar_view
        } else {
            localization::catalog().menu.hide_sidebar_view
        };
        Some(MenuItem::LabeledAction {
            label: template.replace("{view}", &self.sidebar_view_name(index)),
            action: MenuAction::SetSidebarViewVisible { view: index, visible: hidden },
        })
    }

    fn sidebar_presentation_menu_item(&self) -> MenuItem {
        let mut items = Vec::new();
        if self.config.sidebar.profiles.len() > 1 {
            items.push(MenuItem::Submenu {
                label: localization::catalog().menu.sidebar_profiles.to_string(),
                items: self
                    .config
                    .sidebar
                    .profiles
                    .iter()
                    .enumerate()
                    .map(|(index, profile)| MenuItem::LabeledAction {
                        label: format!(
                            "{}{}",
                            if profile.id == self.config.sidebar.active_profile {
                                "✓ "
                            } else {
                                "  "
                            },
                            profile.name
                        ),
                        action: MenuAction::ActivateSidebarProfile(index),
                    })
                    .collect(),
            });
        }
        if !self.config.sidebar.views.is_empty() {
            if !items.is_empty() {
                items.push(MenuItem::Separator);
            }
            items.extend(
                (0..self.config.sidebar.views.len())
                    .filter_map(|index| self.sidebar_view_visibility_item(index)),
            );
        }
        MenuItem::Submenu { label: localization::catalog().menu.sidebar_layout.to_string(), items }
    }

    pub(super) fn global_menu_items(&self) -> Vec<MenuItem> {
        let mut items =
            self.menu_group([MenuAction::ToggleSidebar { visible: self.sidebar_visible }]);
        if self.surface_only.is_none() {
            items.push(self.sidebar_presentation_menu_item());
        }
        items.push(self.menu_item(MenuAction::ShowShortcuts));
        items
    }

    pub(super) fn set_sidebar_view_visible(&mut self, index: usize, visible: bool) {
        let Some(view) = self.config.sidebar.views.get(index) else { return };
        let view_id = view.id.clone();
        let hides_focused = !visible && self.focused_sidebar_view_id().as_deref() == Some(&view_id);
        let hidden = self
            .hidden_sidebar_views
            .entry(self.config.sidebar.active_profile.clone())
            .or_default();
        if visible {
            hidden.remove(&view_id);
            self.sidebar_visible = true;
        } else {
            hidden.insert(view_id);
            if hides_focused {
                self.focus = FocusTarget::Pane;
            }
        }
    }

    pub(super) fn activate_sidebar_profile(&mut self, index: usize) {
        let Some(profile) = self.config.sidebar.profiles.get(index).cloned() else { return };
        let focused_view = self.focused_sidebar_view_id();
        self.config.sidebar.active_profile = profile.id;
        self.config.sidebar.views = profile.views;
        self.config.sidebar.columns = self
            .config
            .sidebar
            .views
            .iter()
            .filter_map(|view| {
                view.legacy_kind().map(|kind| SidebarColumn {
                    kind,
                    width: view.width,
                    max_width: view.max_width,
                })
            })
            .collect();
        self.sidebar_visible = true;
        if let Some(focused_view) = focused_view {
            let hidden = self
                .hidden_sidebar_views
                .get(&self.config.sidebar.active_profile)
                .is_some_and(|hidden| hidden.contains(&focused_view));
            if !hidden
                && let Some(index) =
                    self.config.sidebar.views.iter().position(|view| view.id == focused_view)
            {
                self.focus_rail(self.rail_kind_for_view(index));
                return;
            }
            self.focus = FocusTarget::Pane;
        }
    }

    pub(super) fn open_context_menu(&mut self, x: u16, y: u16) {
        self.build_context_menu(x, y);
        self.capture_menu_resources();
    }

    pub(super) fn capture_menu_resources(&mut self) {
        let captured_resources = self.menu.as_ref().map(|menu| {
            menu.actions()
                .into_iter()
                .map(|action| (action, self.menu_action_resource(action)))
                .collect()
        });
        if let (Some(menu), Some(captured_resources)) = (&mut self.menu, captured_resources) {
            menu.captured_resources = captured_resources;
        }
    }

    fn build_context_menu(&mut self, x: u16, y: u16) {
        self.cancel_pty_mouse_drag();
        self.menu = None;
        self.omnibar = None;
        self.session.refresh_clients_background();
        let hit = self.hit_at(x, y);
        if matches!(hit, Some(Hit::StatusMessage)) {
            self.menu = Some(ContextMenu::with_groups(
                x,
                y,
                vec![self.menu_group([MenuAction::CopyStatusMessage]), self.global_menu_items()],
            ));
            return;
        }
        // Configurable `+` buttons: a right click opens their configured
        // menu when one exists; without one the generic paths below apply.
        if let Some(Hit::NewTab { pane }) = hit {
            let items = self.plus_menu_items(&self.config.tabs.plus, Some(pane));
            if !items.is_empty() {
                self.menu =
                    Some(ContextMenu::with_groups(x, y, vec![items, self.global_menu_items()]));
                return;
            }
        }
        // "+ new vm" and the machine rail's top pad carry the provider
        // scope switcher and provider actions since their dedicated rail
        // rows were removed (`m` is the keyboard twin).
        if matches!(hit, Some(Hit::NewVm) | Some(Hit::RailPad(RailKind::Machine)))
            && self.open_provider_rail_menu(x, y)
        {
            return;
        }
        if matches!(hit, Some(Hit::NewScreen)) {
            let items =
                self.plus_menu_items(&self.config.status_bar.screens_plus, self.active_pane());
            if !items.is_empty() {
                self.menu =
                    Some(ContextMenu::with_groups(x, y, vec![items, self.global_menu_items()]));
                return;
            }
        }
        if self.total_sidebar_width() > 0 && x < self.total_sidebar_width() {
            let mut groups = Vec::new();
            match hit {
                Some(Hit::Machine { key, .. }) => {
                    if let Some(machine) = self.managed_machine(key) {
                        let mut actions = Vec::new();
                        match machine.status {
                            ManagedMachineStatus::Active => {
                                if machine.capabilities.rename {
                                    actions.push(MenuAction::RenameManagedMachine(key));
                                }
                                if machine.capabilities.delete {
                                    actions.push(MenuAction::DeleteManagedMachine(key));
                                }
                            }
                            ManagedMachineStatus::Recoverable => {
                                if machine.capabilities.restore {
                                    actions.push(MenuAction::RestoreManagedMachine(key));
                                }
                                if machine.capabilities.purge {
                                    actions.push(MenuAction::PurgeManagedMachine(key));
                                }
                            }
                        }
                        groups.push(self.menu_group(actions));
                    } else if self
                        .machine_ui
                        .as_ref()
                        .is_some_and(|ui| ui.is_client_machine_renamable(key))
                    {
                        groups.push(self.menu_group([MenuAction::RenameClientMachine(key)]));
                    }
                }
                Some(Hit::Workspace { id, .. }) => {
                    if self.provider_manages_current_workspace_session() {
                        if let Some(workspace) = self.managed_workspace_for_view(id) {
                            let mut actions = Vec::new();
                            if workspace.capabilities.rename {
                                actions.push(MenuAction::RenameManagedWorkspace(id));
                            }
                            if workspace.capabilities.delete {
                                actions.push(MenuAction::DeleteManagedWorkspace(id));
                            }
                            groups.push(self.menu_group(actions));
                        }
                    } else {
                        groups.push(self.menu_group([
                            MenuAction::RenameWorkspace(id),
                            MenuAction::CloseWorkspace(id),
                        ]));
                        groups.push(self.menu_group([MenuAction::CopyWorkspaceId(id)]));
                    }
                }
                Some(Hit::RecoverableWorkspace { index }) => {
                    if let Some(workspace) = self
                        .machine_ui
                        .as_ref()
                        .and_then(|ui| ui.recoverable_workspaces().get(index).copied())
                    {
                        let mut actions = Vec::new();
                        if workspace.capabilities.restore {
                            actions.push(MenuAction::RestoreManagedWorkspace(index));
                        }
                        if workspace.capabilities.purge {
                            actions.push(MenuAction::PurgeManagedWorkspace(index));
                        }
                        groups.push(self.menu_group(actions));
                    }
                }
                Some(Hit::SidebarTab { surface, .. }) => {
                    groups.push(self.menu_group([MenuAction::RenameSurface(surface)]));
                    if let Some(item) = self.tab_move_workspace_item(surface) {
                        groups.push(vec![item]);
                    }
                }
                Some(Hit::ProjectionRow {
                    target: ProjectionTarget::Workspace { id, .. }, ..
                })
                | Some(Hit::ProjectionToggle { branch: ProjectionBranch::Workspace(id), .. }) => {
                    if self.provider_manages_current_workspace_session() {
                        if let Some(workspace) = self.managed_workspace_for_view(id) {
                            let mut actions = Vec::new();
                            if workspace.capabilities.rename {
                                actions.push(MenuAction::RenameManagedWorkspace(id));
                            }
                            if workspace.capabilities.delete {
                                actions.push(MenuAction::DeleteManagedWorkspace(id));
                            }
                            groups.push(self.menu_group(actions));
                        }
                    } else {
                        groups.push(self.menu_group([
                            MenuAction::RenameWorkspace(id),
                            MenuAction::CloseWorkspace(id),
                        ]));
                        groups.push(self.menu_group([MenuAction::CopyWorkspaceId(id)]));
                    }
                }
                Some(Hit::ProjectionRow {
                    target: ProjectionTarget::Surface { surface, .. },
                    ..
                }) => {
                    groups.push(self.menu_group([MenuAction::RenameSurface(surface)]));
                    if let Some(item) = self.tab_move_workspace_item(surface) {
                        groups.push(vec![item]);
                    }
                }
                _ => {}
            }
            if let Some(view_index) = self
                .sidebar_layout
                .ordered
                .iter()
                .find(|placement| placement.rect.contains(x, y))
                .map(|placement| placement.view_index)
                && let Some(item) = self.sidebar_view_visibility_item(view_index)
            {
                groups.push(vec![item]);
            }
            groups.push(self.menu_group(self.sidebar_menu_actions()));
            groups.push(vec![self.sidebar_presentation_menu_item()]);
            groups.push(self.menu_group([MenuAction::ShowShortcuts]));
            self.menu = Some(ContextMenu::with_groups(x, y, groups));
            // Provider scope/action entries dispatch by displayed index;
            // capture the stable resources behind them (see the identity
            // tests) exactly like the dedicated menus used to.
            self.capture_menu_resources();
            return;
        }
        match hit {
            Some(Hit::Tab { pane, index }) => {
                let Some(surface) = self
                    .tree
                    .pane(pane)
                    .and_then(|pane| pane.tabs.get(index))
                    .map(|tab| tab.surface)
                else {
                    return;
                };
                let is_browser = self.surface_kind(surface) == Some(SurfaceKind::Browser);
                let external_browser =
                    self.browser_source(surface) == Some(BrowserSource::External);
                let mut actions = pane_context_menu_groups(pane, is_browser, external_browser);
                if let Some(rename) = actions.first_mut().and_then(|group| group.first_mut()) {
                    *rename = MenuAction::RenameSurface(surface);
                }
                let mut groups = actions
                    .into_iter()
                    .map(|group| self.menu_group(group))
                    .collect::<Vec<Vec<MenuItem>>>();
                if let Some(item) = self.tab_move_workspace_item(surface) {
                    groups.push(vec![item]);
                }
                if self.surface_only.is_none() {
                    let zoomed = self
                        .tree
                        .active_screen()
                        .is_some_and(|screen| screen.zoomed_pane == Some(pane));
                    groups.push(self.menu_group([MenuAction::TogglePaneZoom { pane, zoomed }]));
                }
                if self.surface_only.is_none()
                    && let Some(clients) = terminal_size_menu_item(
                        self.session.size_state(surface).as_ref(),
                        &self.clients,
                        surface,
                    )
                {
                    groups.push(vec![clients]);
                }
                groups.push(self.global_menu_items());
                self.menu = Some(ContextMenu::with_groups(x, y, groups));
                return;
            }
            Some(Hit::ScreenEntry { id, .. }) => {
                self.menu = Some(ContextMenu::with_groups(
                    x,
                    y,
                    vec![
                        self.menu_group([
                            MenuAction::RenameScreen(id),
                            MenuAction::CloseScreen(id),
                        ]),
                        self.global_menu_items(),
                    ],
                ));
                return;
            }
            Some(Hit::Clients { surface }) => {
                self.open_clients_menu(x, y, surface);
                return;
            }
            _ => {}
        }
        if let Some(area) = self.pane_area_at(x, y) {
            let is_browser = self.surface_kind(area.surface) == Some(SurfaceKind::Browser);
            let external_browser =
                self.browser_source(area.surface) == Some(BrowserSource::External);
            let mut groups = pane_context_menu_groups(area.pane, is_browser, external_browser)
                .into_iter()
                .map(|group| self.menu_group(group))
                .collect::<Vec<Vec<MenuItem>>>();
            if self.surface_only.is_none() {
                let zoomed = self
                    .tree
                    .active_screen()
                    .is_some_and(|screen| screen.zoomed_pane == Some(area.pane));
                groups.push(
                    self.menu_group([MenuAction::TogglePaneZoom { pane: area.pane, zoomed }]),
                );
            }
            if self.surface_only.is_none()
                && let Some(clients) = terminal_size_menu_item(
                    self.session.size_state(area.surface).as_ref(),
                    &self.clients,
                    area.surface,
                )
            {
                groups.push(vec![clients]);
            }
            groups.push(self.global_menu_items());
            self.menu = Some(ContextMenu::with_groups(x, y, groups));
            return;
        }
        self.menu = Some(ContextMenu::with_groups(x, y, vec![self.global_menu_items()]));
    }

    pub(super) fn replace_clients(&mut self, clients: Vec<ClientInfo>) {
        self.client_border_labels = crate::ui::pane::client_border_labels(&clients);
        self.clients = clients;
    }

    /// Recomputes a terminal's shared-sizing border label from the session's
    /// latest size state. A terminal with a size state uses it instead of the
    /// legacy client label, including when it hides the label.
    pub(super) fn refresh_size_state_label(&mut self, surface: SurfaceId) {
        match self.session.size_state(surface) {
            Some(size) => {
                let label = crate::ui::sizing::border_label(&size, &localization::catalog().menu);
                self.size_state_labels.insert(surface, label);
            }
            None => {
                self.size_state_labels.remove(&surface);
            }
        }
    }

    /// Resolves a size-menu participant index against the state the menu
    /// showed; a newer state means the menu is stale.
    pub(super) fn size_menu_participant(
        &mut self,
        surface: SurfaceId,
        generation: u64,
        participant: usize,
    ) -> Option<(String, bool)> {
        let size = self.session.size_state(surface)?;
        if size.state.generation != generation {
            self.status_message =
                Some(localization::catalog().menu.terminal_size_changed.to_string());
            return None;
        }
        let row = size.state.participants.get(participant)?;
        let is_self = size.self_participant.as_deref() == Some(row.participant.id.as_str());
        Some((row.participant.id.clone(), is_self))
    }

    pub(super) fn open_clients_menu(&mut self, x: u16, y: u16, surface: SurfaceId) {
        self.session.refresh_clients_background();
        let mut groups = Vec::new();
        let size = self.session.size_state(surface);
        if let Some(MenuItem::Submenu { items, .. }) =
            terminal_size_menu_item(size.as_ref(), &self.clients, surface)
        {
            groups.push(items);
        }
        groups.push(self.global_menu_items());
        self.menu = Some(ContextMenu::with_groups(x, y, groups));
    }
}

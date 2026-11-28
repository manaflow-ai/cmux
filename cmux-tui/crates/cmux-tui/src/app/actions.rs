//! Action dispatch: running a resolved action (with its semantic intent) for
//! the active or a given pane, and the rename prompts that actions open.

use cmux_tui_core::{Direction, PaneId, SplitDir, SurfaceId, SurfaceKind, WorkspaceId};
use crossterm::event::KeyEvent;

use crate::app::layout::FocusTarget;
use crate::app::overlays::{Prompt, PromptTarget, ShortcutHelp};
use crate::app::{App, RenderAction, action_prepares_pty_release};
use crate::browser_input::BrowserInputKind;
use crate::config::Action;
use crate::localization;

impl App {
    pub(super) fn run_resolved_action(
        &mut self,
        action: Action,
        prefix: KeyEvent,
    ) -> anyhow::Result<RenderAction> {
        self.run_resolved_action_with_semantic_intent(action, prefix, None, None, None)
    }

    pub(super) fn run_resolved_action_with_semantic_intent(
        &mut self,
        action: Action,
        prefix: KeyEvent,
        semantic_intent: Option<u64>,
        action_destination: Option<SurfaceId>,
        action_fallback_destination: Option<SurfaceId>,
    ) -> anyhow::Result<RenderAction> {
        if action == Action::SendPrefix && self.workspace_sidebar_focused() {
            self.forward_sidebar_key(prefix.into());
            return Ok(RenderAction::Draw);
        }
        let pane = match action_destination {
            Some(surface) => self.pane_for_surface(surface),
            None => self.active_pane(),
        };
        let fallback_pane =
            action_fallback_destination.and_then(|surface| self.pane_for_surface(surface));
        let pane = pane.or(fallback_pane);
        if (action_destination.is_some() || action_fallback_destination.is_some()) && pane.is_none()
        {
            if let Some(intent) = semantic_intent {
                self.mark_semantic_destination_failed(intent);
            }
            return Ok(RenderAction::Draw);
        }
        let destination_started = self.session.destination_mutation_started();
        let result = self.run_action_for_pane_with_prefix(
            action,
            pane,
            fallback_pane.filter(|fallback| Some(*fallback) != pane),
            prefix,
            semantic_intent,
        );
        if let Some(intent) = semantic_intent
            && (result.is_err()
                || self.session.destination_mutation_started() == destination_started)
        {
            self.mark_semantic_destination_failed(intent);
        }
        result
    }

    /// Execute one bound action. Shared by the (configurable) prefix keys
    /// and any future command surface.
    pub(super) fn run_action(&mut self, action: Action) -> anyhow::Result<RenderAction> {
        let prefix = self.config.keys.prefix;
        self.run_resolved_action(action, KeyEvent::new(prefix.code, prefix.mods))
    }

    /// Execute an action against an explicit pane. Context menus use this
    /// shared path because right-clicking does not change keyboard focus.
    pub(super) fn run_action_for_pane(
        &mut self,
        action: Action,
        pane: Option<PaneId>,
    ) -> anyhow::Result<RenderAction> {
        let prefix = self.config.keys.prefix;
        self.run_action_for_pane_with_prefix(
            action,
            pane,
            None,
            KeyEvent::new(prefix.code, prefix.mods),
            None,
        )
    }

    fn run_action_for_pane_with_prefix(
        &mut self,
        action: Action,
        pane: Option<PaneId>,
        fallback_pane: Option<PaneId>,
        prefix: KeyEvent,
        semantic_intent: Option<u64>,
    ) -> anyhow::Result<RenderAction> {
        if !self.action_available(action) {
            return Ok(RenderAction::Draw);
        }
        if action_prepares_pty_release(action) && !self.prepare_pty_input_before_mutation() {
            return Ok(RenderAction::None);
        }
        match action {
            Action::SendPrefix => {
                self.forward_key_to_pane(&prefix, pane);
            }
            Action::NewTab => {
                self.new_terminal_tab(pane, fallback_pane, semantic_intent)?;
            }
            Action::NewBrowserTab => {
                self.create_browser_tab_for_edit(pane, fallback_pane, semantic_intent)?;
            }
            Action::NewPaneSmart => self.new_pane_smart(pane, fallback_pane, semantic_intent)?,
            Action::NextTab => self.select_tab_for_client(pane, None, Some(1)),
            Action::PrevTab => self.select_tab_for_client(pane, None, Some(-1)),
            Action::SelectTab(_) => {
                if let Some(index) = action.tab_index() {
                    self.select_tab_for_client(pane, Some(index), None);
                }
            }
            Action::SplitRight => {
                if let Some(pane) = pane {
                    self.split_pane(pane, fallback_pane, SplitDir::Right, semantic_intent)?;
                }
            }
            Action::SplitDown => {
                if let Some(pane) = pane {
                    self.split_pane(pane, fallback_pane, SplitDir::Down, semantic_intent)?;
                }
            }
            Action::CloseTab => {
                // Close the active tab; the pane collapses with its last
                // tab, so this is also "close pane" for single-tab panes.
                if let Some(surface) = pane
                    .and_then(|pane| self.tree.pane(pane))
                    .and_then(|pane| pane.active_surface())
                {
                    self.session.close_surface(surface);
                }
            }
            Action::ClosePane => {
                if let Some(pane) = pane {
                    self.session.close_pane(pane);
                }
            }
            Action::RenameTab => self.open_rename_tab_prompt(pane),
            Action::RenameScreen => self.open_rename_screen_prompt(),
            Action::RenameWorkspace => self.open_rename_workspace_prompt(),
            Action::CloseScreen => {
                if let Some(screen) = self.active_screen_id() {
                    self.session.close_screen(screen);
                }
            }
            Action::PrevScreen => self.select_screen_for_client(None, Some(-1)),
            Action::NextScreen => self.select_screen_for_client(None, Some(1)),
            Action::SelectScreen(_) => {
                if let Some(index) = action.screen_index() {
                    self.select_screen_for_client(Some(index), None);
                }
            }
            Action::NewScreen => self.new_screen(semantic_intent)?,
            Action::PrevWorkspace => self.select_workspace_for_client(None, Some(-1)),
            Action::NextWorkspace => self.select_workspace_for_client(None, Some(1)),
            Action::NewWorkspace => self.new_workspace(semantic_intent)?,
            Action::CloseWorkspace => {
                if let Some(workspace) = self.tree.active_workspace().map(|workspace| workspace.id)
                {
                    self.request_delete_workspace(workspace);
                }
            }
            Action::ToggleSidebar => {
                self.sidebar_visible = !self.sidebar_visible;
                if !self.sidebar_visible {
                    self.session.invalidate_sidebar_plugin_sync();
                    self.focus = FocusTarget::Pane;
                }
            }
            Action::ToggleSidebarCompact => {
                self.sidebar_compact = !self.sidebar_compact;
                self.sidebar_visible = true;
            }
            Action::ToggleSidebarView => self.toggle_sidebar_view(),
            Action::FocusSidebar => self.toggle_sidebar_focus(),
            Action::ProviderMenu => {
                if self.focus == FocusTarget::MachineRail {
                    self.open_provider_rail_menu(1, 2);
                }
            }
            Action::NewPaneRight => self.new_pane_right(pane, fallback_pane, semantic_intent)?,
            Action::UndoLayout => {
                if let Some(pane) = pane {
                    self.session.undo_layout(pane, None, false)?;
                }
            }
            Action::FocusLeft => self.move_focus(Direction::Left),
            Action::FocusRight => self.move_focus(Direction::Right),
            Action::FocusUp => self.move_focus(Direction::Up),
            Action::FocusDown => self.move_focus(Direction::Down),
            Action::FocusNextPane => self.focus_next_pane(),
            Action::SwapPanePrev => self.swap_pane_by_order(-1),
            Action::SwapPaneNext => self.swap_pane_by_order(1),
            Action::ZoomPane => self.session.zoom_pane(pane),
            Action::ResizeGrow => self.resize_focused_split(0.05),
            Action::ResizeShrink => self.resize_focused_split(-0.05),
            Action::ScrollUp => self.scroll_active(-10),
            Action::ScrollDown => self.scroll_active(10),
            Action::ClearHistory => {
                if let Some(surface) = self.active_surface()
                    && self.tree.surface_kind(surface) == SurfaceKind::Pty
                {
                    self.session.clear_history(
                        surface,
                        self.input_revision,
                        self.selection,
                        self.selection_generation,
                    );
                }
                return Ok(RenderAction::None);
            }
            Action::BrowserBack => {
                self.enqueue_active_browser_command(BrowserInputKind::Back);
                return Ok(RenderAction::Draw);
            }
            Action::BrowserForward => {
                self.enqueue_active_browser_command(BrowserInputKind::Forward);
                return Ok(RenderAction::Draw);
            }
            Action::BrowserReload => {
                self.enqueue_active_browser_command(BrowserInputKind::Reload);
                return Ok(RenderAction::Draw);
            }
            Action::BrowserEditUrl => {
                if let Some(pane) = pane {
                    self.focus_omnibar(pane);
                }
                return Ok(RenderAction::Draw);
            }
            Action::ShowShortcuts => {
                self.shortcut_help = if self.shortcut_help.is_some() {
                    None
                } else {
                    self.finish_active_drag();
                    Some(ShortcutHelp::from_config(&self.config, self.surface_only.is_some()))
                };
                self.menu = None;
                self.prompt = None;
                self.omnibar = None;
                self.replace_selection(None);
                return Ok(RenderAction::Draw);
            }
            Action::Detach => {
                // Only a session hosted inside this process ends with the
                // TUI; a session owned elsewhere (detached local owner or
                // remote daemon) keeps running after this client leaves.
                self.quit = true;
                return Ok(RenderAction::None);
            }
            Action::UserCommand(_) => {
                if let Some(index) = action.user_command_index() {
                    self.run_user_command(index, pane)?;
                }
            }
        }
        if !self.status_message_hovered() {
            self.status_message = None;
        }
        Ok(RenderAction::Draw)
    }

    pub(super) fn open_rename_tab_prompt(&mut self, pane: Option<PaneId>) {
        let Some(pane) = pane else { return };
        let Some(surface) = self
            .tree
            .pane(pane)
            .and_then(|pane| pane.tabs.get(pane.active_tab))
            .map(|tab| tab.surface)
        else {
            return;
        };
        self.open_rename_surface_prompt(surface);
    }

    pub(super) fn open_rename_surface_prompt(&mut self, surface: SurfaceId) {
        let Some(buffer) = self
            .tree
            .workspaces()
            .iter()
            .flat_map(|workspace| workspace.screens.iter())
            .flat_map(|screen| screen.panes.iter())
            .flat_map(|pane| pane.tabs.iter())
            .find(|tab| tab.surface == surface)
            .map(|tab| tab.name.clone().unwrap_or_default())
        else {
            return;
        };
        let prompt = Prompt::new(
            localization::catalog().action_label(Action::RenameTab),
            buffer,
            PromptTarget::Surface(surface),
        );
        self.cancel_pty_mouse_drag();
        self.prompt = Some(prompt);
    }

    fn open_rename_workspace_prompt(&mut self) {
        let Some(workspace_id) = self.tree.active_workspace().map(|workspace| workspace.id) else {
            return;
        };
        self.open_rename_workspace_prompt_for(workspace_id);
    }

    pub(super) fn open_rename_workspace_prompt_for(&mut self, workspace_id: WorkspaceId) {
        let Some(buffer) = self
            .tree
            .workspaces()
            .iter()
            .find(|ws| ws.id == workspace_id)
            .map(|workspace| workspace.name.clone())
        else {
            return;
        };
        let provider_managed = self.provider_manages_current_workspace_session();
        let target = if provider_managed {
            if self.machine_ui.as_ref().and_then(|ui| ui.snapshot.active).is_none() {
                self.reject_inactive_managed_workspace_machine();
                return;
            }
            let Some(managed) = self.managed_workspace_for_view(workspace_id) else {
                self.reject_unavailable_managed_workspace_operation();
                return;
            };
            if !managed.capabilities.rename {
                self.reject_disallowed_managed_workspace_operation();
                return;
            }
            PromptTarget::ManagedWorkspace(workspace_id)
        } else {
            PromptTarget::Workspace(workspace_id)
        };
        let prompt = Prompt::new(localization::catalog().sidebar.rename_workspace, buffer, target);
        self.cancel_pty_mouse_drag();
        self.prompt = Some(prompt);
    }

    fn open_rename_screen_prompt(&mut self) {
        let Some(ws) = self.tree.active_workspace() else { return };
        let Some(screen) = ws.active_screen_ref() else { return };
        let buffer = screen.name.clone().unwrap_or_default();
        let prompt = Prompt::new(
            localization::catalog().action_label(Action::RenameScreen),
            buffer,
            PromptTarget::Screen(screen.id),
        );
        self.cancel_pty_mouse_drag();
        self.prompt = Some(prompt);
    }
}

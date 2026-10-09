//! Activating a context menu item: `activate_menu` maps each menu action to
//! its session mutation, prompt, or frontend effect.

use cmux_tui_core::sizing_policy::{TerminalSizingMode, TerminalSizingPolicy};

use crate::app::overlays::{Prompt, PromptTarget};
use crate::app::{App, MenuAction, menu_action_prepares_pty_release};
use crate::browser_input::BrowserInputKind;
use crate::config::Action;
use crate::localization;
use crate::machine::{MachineConnectRoute, MachineRequest};

impl App {
    pub(super) fn activate_menu(&mut self, action: MenuAction) -> anyhow::Result<()> {
        match action {
            MenuAction::TogglePaneZoom { pane, zoomed } => {
                if self.active_pane() != Some(pane) {
                    self.focus_pane_after_input(pane);
                }
                self.session.set_pane_zoom(pane, !zoomed);
                return Ok(());
            }
            MenuAction::NewPaneSmart(pane) => {
                self.run_action_for_pane(Action::NewPaneSmart, Some(pane))?;
                return Ok(());
            }
            MenuAction::NewTab(pane) => {
                self.run_action_for_pane(Action::NewTab, Some(pane))?;
                return Ok(());
            }
            MenuAction::NewBrowserTab(pane) => {
                self.run_action_for_pane(Action::NewBrowserTab, Some(pane))?;
                return Ok(());
            }
            MenuAction::SplitRight(pane) => {
                self.run_action_for_pane(Action::SplitRight, Some(pane))?;
                return Ok(());
            }
            MenuAction::SplitDown(pane) => {
                self.run_action_for_pane(Action::SplitDown, Some(pane))?;
                return Ok(());
            }
            MenuAction::ToggleSidebar { .. } => {
                self.run_action(Action::ToggleSidebar)?;
                return Ok(());
            }
            MenuAction::ToggleSidebarCompact { .. } => {
                self.run_action(Action::ToggleSidebarCompact)?;
                return Ok(());
            }
            MenuAction::FocusSidebar => {
                if !self.workspace_sidebar_focused() && self.prepare_pty_input_before_mutation() {
                    self.focus_sidebar();
                }
                return Ok(());
            }
            MenuAction::ActivateSidebarProfile(index) => {
                self.activate_sidebar_profile(index);
                return Ok(());
            }
            MenuAction::SetSidebarViewVisible { view, visible } => {
                self.set_sidebar_view_visible(view, visible);
                return Ok(());
            }
            MenuAction::ShowShortcuts => {
                self.run_action(Action::ShowShortcuts)?;
                return Ok(());
            }
            _ => {}
        }
        if menu_action_prepares_pty_release(action) && !self.prepare_pty_input_before_mutation() {
            return Ok(());
        }
        match action {
            MenuAction::RenameClientMachine(key) => {
                self.open_rename_client_machine_prompt(key);
            }
            MenuAction::RenameManagedMachine(key) => {
                self.open_rename_managed_machine_prompt(key);
            }
            MenuAction::DeleteManagedMachine(key) => {
                self.open_delete_managed_machine_prompt(key);
            }
            MenuAction::RestoreManagedMachine(key) => {
                self.request_restore_managed_machine(key);
            }
            MenuAction::PurgeManagedMachine(key) => {
                self.open_purge_managed_machine_prompt(key);
            }
            MenuAction::RenameWorkspace(id) => self.open_rename_workspace_prompt_for(id),
            MenuAction::RenameManagedWorkspace(id) => {
                self.open_rename_workspace_prompt_for(id);
            }
            MenuAction::CloseWorkspace(id) => self.request_delete_workspace(id),
            MenuAction::DeleteManagedWorkspace(id) => self.request_delete_workspace(id),
            MenuAction::RestoreManagedWorkspace(index) => {
                let workspace_id = self
                    .machine_ui
                    .as_ref()
                    .and_then(|ui| ui.recoverable_workspaces().get(index).copied())
                    .map(|workspace| workspace.id.clone());
                if let Some(workspace_id) = workspace_id {
                    self.request_restore_managed_workspace(&workspace_id);
                }
            }
            MenuAction::PurgeManagedWorkspace(index) => {
                self.prompt = Some(Prompt::new(
                    localization::catalog().sidebar.confirm_purge_workspace,
                    String::new(),
                    PromptTarget::ConfirmPurgeManagedWorkspace(index),
                ));
            }
            MenuAction::CopyWorkspaceId(id) => {
                if let Some(short_id) = self
                    .tree
                    .workspaces()
                    .iter()
                    .find(|ws| ws.id == id)
                    .map(|ws| ws.short_id.clone())
                {
                    self.copy_short_id(short_id);
                }
            }
            MenuAction::RenameScreen(id) => {
                let buffer = self
                    .tree
                    .workspaces()
                    .iter()
                    .flat_map(|ws| ws.screens.iter())
                    .find(|s| s.id == id)
                    .and_then(|s| s.name.clone())
                    .unwrap_or_default();
                self.prompt = Some(Prompt::new(
                    localization::catalog().action_label(Action::RenameScreen),
                    buffer,
                    PromptTarget::Screen(id),
                ));
            }
            MenuAction::CloseScreen(id) => self.session.close_screen(id),
            MenuAction::BrowserBack(id) => {
                self.enqueue_browser_command_for_pane(id, BrowserInputKind::Back);
            }
            MenuAction::BrowserForward(id) => {
                self.enqueue_browser_command_for_pane(id, BrowserInputKind::Forward);
            }
            MenuAction::BrowserReload(id) => {
                self.enqueue_browser_command_for_pane(id, BrowserInputKind::Reload);
            }
            MenuAction::BrowserEditUrl(id) => self.focus_omnibar(id),
            MenuAction::BrowserCopyUrl(id) => self.browser_copy_url(id),
            MenuAction::BrowserActivate(id) => {
                self.enqueue_browser_command_for_pane(id, BrowserInputKind::Activate);
            }
            MenuAction::RenameTab(id) => self.open_rename_tab_prompt(Some(id)),
            MenuAction::RenameSurface(surface) => self.open_rename_surface_prompt(surface),
            MenuAction::MoveTabToWorkspace { surface, workspace } => {
                self.move_tab_to_workspace(surface, workspace);
            }
            MenuAction::CopyTabId(id) => {
                if let Some(short_id) = self
                    .tree
                    .pane(id)
                    .and_then(|pane| pane.tabs.get(pane.active_tab))
                    .map(|tab| tab.short_id.clone())
                {
                    self.copy_short_id(short_id);
                }
            }
            MenuAction::CopyPaneId(id) => {
                if let Some(short_id) = self.tree.pane(id).map(|pane| pane.short_id.clone()) {
                    self.copy_short_id(short_id);
                }
            }
            MenuAction::CopyStatusMessage => self.copy_status_message(),
            MenuAction::NewPaneSmart(_)
            | MenuAction::NewTab(_)
            | MenuAction::NewBrowserTab(_)
            | MenuAction::SplitRight(_)
            | MenuAction::SplitDown(_) => unreachable!("shared menu actions return above"),
            MenuAction::CloseTab(id) => {
                if let Some(surface) = self.tree.pane(id).and_then(|p| p.active_surface()) {
                    self.session.close_surface(surface);
                }
            }
            MenuAction::ClosePane(id) => self.session.close_pane(id),
            MenuAction::TogglePaneZoom { .. }
            | MenuAction::ToggleSidebar { .. }
            | MenuAction::ToggleSidebarCompact { .. }
            | MenuAction::FocusSidebar
            | MenuAction::ActivateSidebarProfile(_)
            | MenuAction::SetSidebarViewVisible { .. }
            | MenuAction::ShowShortcuts => unreachable!("shared menu actions return above"),
            MenuAction::SetClientSizing { surface, client, enabled } => {
                self.session.set_client_sizing(surface, client, enabled);
            }
            MenuAction::UseClientSize { surface, client } => {
                self.session.use_only_client_sizing(surface, client);
            }
            MenuAction::RestoreAllClientSizing(surface) => {
                self.session.use_all_client_sizing(surface);
            }
            MenuAction::SetSizeMode { surface, mode } => {
                if let Some(size) = self.session.size_state(surface) {
                    let state = &size.state;
                    let priority = if mode == TerminalSizingMode::Priority {
                        crate::ui::sizing::priority_with_self_first(
                            state,
                            size.self_participant.as_deref(),
                        )
                    } else {
                        state.policy.priority.clone()
                    };
                    // Fixed keeps the current grid; the Mac and iPhone edit it.
                    let fixed = state.policy.fixed.or(Some(state.size()));
                    self.session
                        .set_size_policy(surface, TerminalSizingPolicy::new(mode, priority, fixed));
                }
            }
            MenuAction::SetSizeCounts { surface, generation, participant, counts } => {
                if let Some((id, _)) = self.size_menu_participant(surface, generation, participant)
                {
                    self.session.set_size_counts(surface, id, Some(counts));
                }
            }
            MenuAction::DisconnectSizeParticipant { surface, generation, participant } => {
                if let Some((id, is_self)) =
                    self.size_menu_participant(surface, generation, participant)
                {
                    if is_self {
                        // Same as disconnecting this client from the legacy menu:
                        // leave through the local detach lifecycle.
                        self.run_action(Action::Detach)?;
                    } else {
                        self.session.disconnect_size_participant(surface, id);
                    }
                }
            }
            MenuAction::DisconnectClient(client) => {
                if self.clients.iter().any(|info| info.client == client && info.is_self) {
                    // Disconnecting this control connection would close the socket that must
                    // carry the response. Exit through the same local detach lifecycle as the
                    // keyboard action instead, without another request on that socket.
                    self.run_action(Action::Detach)?;
                } else {
                    // Peer disconnects can resize viewer-owned surfaces, so they pass through
                    // the pointer-map mutation barrier while running off the UI thread. A stale
                    // client id remains a harmless no-op.
                    self.session.disconnect_client(client);
                }
            }
            MenuAction::SelectProviderScope(index) => {
                let scope = self
                    .machine_ui
                    .as_ref()
                    .and_then(|ui| ui.provider.as_ref())
                    .and_then(|provider| provider.scopes.get(index))
                    .map(|scope| scope.id.clone());
                if let (Some(ui), Some(scope)) = (self.machine_ui.as_mut(), scope)
                    && ui
                        .provider
                        .as_ref()
                        .is_some_and(|provider| provider.selected_scope_id != scope)
                {
                    ui.request = Some(MachineRequest::SelectProviderScope(scope));
                }
            }
            MenuAction::InvokeProviderAction(index) => self.begin_provider_action(index),
            MenuAction::CreateMachineFrom(index) => {
                let source_id = self
                    .machine_ui
                    .as_ref()
                    .and_then(|ui| ui.creation_sources.get(index))
                    .map(|source| source.id.clone());
                if let (Some(ui), Some(source_id)) = (self.machine_ui.as_mut(), source_id) {
                    ui.request = Some(MachineRequest::CreateFrom { source_id });
                }
            }
            MenuAction::ConnectMachineTarget(index) => {
                let target = self
                    .machine_ui
                    .as_ref()
                    .and_then(|ui| ui.connection_targets.get(index))
                    .map(|target| target.target.clone());
                if let Some(target) = target {
                    self.begin_machine_connection(target, MachineConnectRoute::Local);
                }
            }
            MenuAction::RunConfigured { action, pane } => {
                self.run_action_for_pane(action, pane.or_else(|| self.active_pane()))?;
            }
            MenuAction::ConnectOtherMachine => {
                let prompt = self.connect_machine_prompt();
                self.prompt = Some(prompt);
            }
        }
        Ok(())
    }
}

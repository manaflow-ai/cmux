//! Machine and provider menus: machine creation and connection menus and
//! prompts, connection retry and error copy, and provider rail actions.

use crate::app::menu::MenuItem;
use crate::app::menu::context_menu::ContextMenu;
use crate::app::overlays::{ConnectionDialogPhase, ConnectionTransaction, Prompt, PromptTarget};
use crate::app::{App, MenuAction, provider_action_error_message};
use crate::localization;
use crate::machine::{
    MachineConnectRoute, MachineRequest, ProviderActionContext, ProviderActionInputError,
};

impl App {
    pub(super) fn open_machine_creation_menu(&mut self, x: u16, y: u16) {
        let sources =
            self.machine_ui.as_ref().map(|ui| ui.creation_sources.clone()).unwrap_or_default();
        match sources.as_slice() {
            [] => {
                if let Some(ui) = self.machine_ui.as_mut() {
                    ui.request = Some(MachineRequest::Create);
                }
            }
            [source] => {
                if let Some(ui) = self.machine_ui.as_mut() {
                    ui.request = Some(MachineRequest::CreateFrom { source_id: source.id.clone() });
                }
            }
            _ => {
                let items = sources
                    .iter()
                    .enumerate()
                    .map(|(index, source)| MenuItem::LabeledAction {
                        label: if source.subtitle.is_empty() {
                            source.name.clone()
                        } else {
                            format!("{} · {}", source.name, source.subtitle)
                        },
                        action: MenuAction::CreateMachineFrom(index),
                    })
                    .collect::<Vec<_>>();
                self.menu = Some(ContextMenu::with_groups(x, y, vec![items]));
                self.capture_menu_resources();
            }
        }
    }

    pub(super) fn open_machine_connection_menu(&mut self, x: u16, y: u16) {
        if self.machine_ui.as_ref().is_some_and(|ui| ui.connect_accepts_pairing_code) {
            let prompt = self.connect_machine_prompt();
            self.prompt = Some(prompt);
            return;
        }
        let targets =
            self.machine_ui.as_ref().map(|ui| ui.connection_targets.clone()).unwrap_or_default();
        if targets.is_empty() {
            let prompt = self.connect_machine_prompt();
            self.prompt = Some(prompt);
            return;
        }
        let targets = targets
            .iter()
            .enumerate()
            .map(|(index, target)| MenuItem::LabeledAction {
                label: target.name.clone(),
                action: MenuAction::ConnectMachineTarget(index),
            })
            .collect::<Vec<_>>();
        let messages = &localization::catalog().sidebar;
        self.menu = Some(ContextMenu::searchable(
            x,
            y,
            messages.ssh_hosts,
            messages.type_to_filter,
            targets,
            vec![MenuItem::Action(MenuAction::ConnectOtherMachine)],
        ));
        self.capture_menu_resources();
    }

    pub(super) fn connect_machine_prompt(&mut self) -> Prompt {
        let messages = &localization::catalog().sidebar;
        let (label, route) =
            if self.machine_ui.as_ref().is_some_and(|ui| ui.connect_accepts_pairing_code) {
                (messages.connect_prompt, MachineConnectRoute::Provider)
            } else {
                (messages.connect_host_prompt, MachineConnectRoute::Local)
            };
        self.connection_transaction = Some(ConnectionTransaction {
            attempt: self.next_connection_attempt,
            target: String::new(),
            route,
            phase: ConnectionDialogPhase::Editing,
        });
        Prompt::new(label, String::new(), PromptTarget::ConnectMachine(route))
    }

    pub(super) fn begin_machine_connection(&mut self, target: String, route: MachineConnectRoute) {
        let target = target.trim().to_string();
        if target.is_empty() {
            return;
        }
        if let Some(ConnectionTransaction { phase: ConnectionDialogPhase::Failed(error), .. }) =
            self.connection_transaction.as_ref()
            && self.status_message.as_deref() == Some(error.as_str())
        {
            self.status_message = None;
            self.status_selection = None;
        }
        let attempt = self.next_connection_attempt;
        self.next_connection_attempt = self.next_connection_attempt.wrapping_add(1).max(1);
        self.connection_transaction = Some(ConnectionTransaction {
            attempt,
            target: target.clone(),
            route,
            phase: ConnectionDialogPhase::Connecting,
        });
        let label = match route {
            MachineConnectRoute::Local => localization::catalog().sidebar.connect_host_prompt,
            MachineConnectRoute::Provider => localization::catalog().sidebar.connect_prompt,
        };
        self.prompt = Some(Prompt::new(label, target.clone(), PromptTarget::ConnectMachine(route)));
        if let Some(machine) = self.machine_ui.as_mut() {
            machine.request = Some(MachineRequest::Connect { target, route });
        }
    }

    pub(super) fn retry_machine_connection(&mut self) {
        let Some(transaction) = self.connection_transaction.clone() else { return };
        self.begin_machine_connection(transaction.target, transaction.route);
    }

    pub(super) fn copy_connection_error(&mut self) {
        let Some(ConnectionTransaction { phase: ConnectionDialogPhase::Failed(error), .. }) =
            self.connection_transaction.as_ref()
        else {
            return;
        };
        let error = error.clone();
        self.copy_text_to_clipboard(&error);
        self.show_toast(localization::catalog().menu.copied.to_string());
    }

    /// Open the provider scope/actions menu near (x, y). The active scope
    /// starts selected, exactly like the removed dedicated scope row, so a
    /// plain Enter never switches scope by accident. False when the provider
    /// offers nothing to show.
    pub(super) fn open_provider_rail_menu(&mut self, x: u16, y: u16) -> bool {
        let scopes = self.provider_scope_menu_items();
        let selected_scope = if scopes.is_empty() {
            None
        } else {
            self.machine_ui.as_ref().and_then(|ui| ui.provider.as_ref()).and_then(|provider| {
                provider.scopes.iter().position(|scope| scope.id == provider.selected_scope_id)
            })
        };
        let actions = self.provider_actions_menu_items();
        if scopes.is_empty() && actions.is_empty() {
            return false;
        }
        let has_scopes = !scopes.is_empty();
        let mut groups = Vec::new();
        if !scopes.is_empty() {
            groups.push(scopes);
        }
        if !actions.is_empty() {
            groups.push(actions);
        }
        groups.push(self.global_menu_items());
        let mut menu = ContextMenu::with_groups(x, y, groups);
        if let (Some(level), Some(selected)) = (menu.levels.first_mut(), selected_scope) {
            level.selected = selected;
            level.ensure_selection_visible();
        } else if !has_scopes {
            // One scope is not a switch choice. Keep the combined menu inert
            // until the user moves or clicks, so Enter cannot invoke its
            // first provider action as a side effect of opening the menu.
            if let Some(level) = menu.levels.first_mut() {
                level.selection_active = false;
            }
        }
        self.menu = Some(menu);
        self.capture_menu_resources();
        true
    }

    /// Scope-switch entries for the provider rail menu. Empty when only one
    /// scope exists (nothing to switch to).
    fn provider_scope_menu_items(&self) -> Vec<MenuItem> {
        let messages = &localization::catalog().sidebar;
        let Some(provider) = self.machine_ui.as_ref().and_then(|ui| ui.provider.as_ref()) else {
            return Vec::new();
        };
        if provider.scopes.len() < 2 {
            return Vec::new();
        }
        provider
            .scopes
            .iter()
            .enumerate()
            .map(|(index, scope)| {
                let selected = scope.id == provider.selected_scope_id;
                let kind = match scope.kind {
                    crate::machine::ProviderScopeKind::Personal => messages.personal_scope,
                    crate::machine::ProviderScopeKind::Team => messages.team_scope,
                };
                let marker = if selected { "✓ " } else { "  " };
                MenuItem::LabeledAction {
                    label: format!("{marker}{} ({kind})", scope.name),
                    action: MenuAction::SelectProviderScope(index),
                }
            })
            .collect()
    }

    fn provider_actions_menu_items(&self) -> Vec<MenuItem> {
        let Some(provider) = self.machine_ui.as_ref().and_then(|ui| ui.provider.as_ref()) else {
            return Vec::new();
        };
        provider
            .actions
            .iter()
            .enumerate()
            .map(|(index, action)| MenuItem::LabeledAction {
                label: if action.destructive {
                    format!(
                        "⚠ {}",
                        localization::catalog()
                            .sidebar
                            .provider_action_label(&action.id)
                            .unwrap_or(action.label.as_str())
                    )
                } else {
                    localization::catalog()
                        .sidebar
                        .provider_action_label(&action.id)
                        .map(str::to_owned)
                        .unwrap_or_else(|| action.label.clone())
                },
                action: MenuAction::InvokeProviderAction(index),
            })
            .collect()
    }

    pub(super) fn begin_provider_action(&mut self, index: usize) {
        let Some(action) = self
            .machine_ui
            .as_ref()
            .and_then(|ui| ui.provider.as_ref())
            .and_then(|provider| provider.actions.get(index))
            .cloned()
        else {
            return;
        };
        match action.fields.as_slice() {
            [] => self.stage_provider_action(index, None),
            [field] => {
                self.prompt = Some(Prompt::new(
                    localization::catalog()
                        .sidebar
                        .provider_action_field_label(&action.id, &field.id)
                        .map(str::to_owned)
                        .unwrap_or_else(|| field.label.clone()),
                    String::new(),
                    PromptTarget::ProviderAction(index),
                ));
            }
            _ => {
                self.status_message = Some(
                    localization::catalog().sidebar.action_multiple_fields_unsupported.to_string(),
                );
            }
        }
    }

    pub(super) fn provider_action_context(&self) -> ProviderActionContext {
        let Some(ui) = self.machine_ui.as_ref() else {
            return ProviderActionContext::default();
        };
        let Some(active) = ui.snapshot.active.filter(|active| ui.is_provider_machine(*active))
        else {
            return ProviderActionContext::default();
        };
        let machine_id = ui
            .snapshot
            .machines
            .iter()
            .find(|machine| machine.key == active)
            .map(|machine| machine.id.clone());
        // Provider runtimes expose a session only while its machine matches
        // the active provider machine. That ownership is sufficient for
        // session-created workspaces that have no lifecycle-catalog entry.
        let workspace_id = if ui.session_available {
            self.tree
                .active_workspace()
                .map(|workspace| workspace.key.clone())
                .filter(|id| !id.is_empty())
        } else {
            None
        };
        ProviderActionContext { machine_id, workspace_id }
    }

    pub(super) fn bound_provider_action(
        &self,
        index: usize,
        input: Option<&str>,
    ) -> Option<Result<(MachineRequest, bool), ProviderActionInputError>> {
        let context = self.provider_action_context();
        self.machine_ui
            .as_ref()
            .and_then(|ui| ui.provider.as_ref())
            .and_then(|provider| provider.actions.get(index))
            .map(|action| {
                action.request(input, &context).map(|request| (request, action.destructive))
            })
    }

    fn stage_provider_action(&mut self, index: usize, input: Option<&str>) {
        let result = self.bound_provider_action(index, input);
        match result {
            Some(Ok((request, true))) => {
                self.pending_provider_action = Some(request);
                self.prompt = Some(Prompt::new(
                    localization::catalog().sidebar.confirm_destructive_action,
                    String::new(),
                    PromptTarget::ConfirmProviderAction,
                ));
            }
            Some(Ok((request, false))) => {
                if let Some(ui) = self.machine_ui.as_mut() {
                    ui.request = Some(request);
                }
            }
            Some(Err(error)) => {
                self.status_message = Some(provider_action_error_message(error).to_string());
            }
            None => {}
        }
    }
}

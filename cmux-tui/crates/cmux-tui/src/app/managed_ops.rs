//! Managed machine and workspace operations: rename, delete, restore and
//! purge requests and their prompts, provider-managed workspace guards, and
//! workspace rail targets.

use cmux_tui_core::WorkspaceId;

use crate::app::machine_worker::uses_provider_managed_workspaces;
use crate::app::overlays::{Prompt, PromptTarget};
use crate::app::{App, WorkspaceRailSelection, WorkspaceRailTarget};
use crate::localization;
use crate::machine::{
    MachineKey, MachineRequest, MachineUiState, ManagedMachineDescriptor, ManagedMachineStatus,
    ManagedWorkspaceDescriptor, ManagedWorkspaceStatus,
};

impl App {
    pub(super) fn managed_machine(&self, key: MachineKey) -> Option<ManagedMachineDescriptor> {
        self.machine_ui.as_ref()?.managed_machine(key).cloned()
    }

    pub(super) fn request_rename_client_machine(&mut self, key: MachineKey, name: String) {
        if !self.machine_ui.as_ref().is_some_and(|ui| ui.is_client_machine_renamable(key)) {
            return;
        }
        if let Some(ui) = self.machine_ui.as_mut() {
            ui.request = Some(MachineRequest::RenameClientMachine { machine: key, name });
        }
    }

    pub(super) fn request_rename_managed_machine(&mut self, key: MachineKey, name: String) {
        let Some(machine) = self.managed_machine(key).filter(|machine| {
            machine.status == ManagedMachineStatus::Active && machine.capabilities.rename
        }) else {
            return;
        };
        if let Some(ui) = self.machine_ui.as_mut() {
            ui.request = Some(MachineRequest::RenameManagedMachine {
                machine: key,
                expected_version: machine.version,
                name,
            });
        }
    }

    pub(super) fn request_delete_managed_machine(&mut self, key: MachineKey) {
        let Some(machine) = self.managed_machine(key).filter(|machine| {
            machine.status == ManagedMachineStatus::Active && machine.capabilities.delete
        }) else {
            return;
        };
        if let Some(ui) = self.machine_ui.as_mut() {
            ui.request = Some(MachineRequest::DeleteManagedMachine {
                machine: key,
                expected_version: machine.version,
            });
        }
    }

    pub(super) fn request_restore_managed_machine(&mut self, key: MachineKey) {
        let Some(machine) = self.managed_machine(key).filter(|machine| {
            machine.status == ManagedMachineStatus::Recoverable && machine.capabilities.restore
        }) else {
            return;
        };
        if let Some(ui) = self.machine_ui.as_mut() {
            ui.request = Some(MachineRequest::RestoreManagedMachine {
                machine: key,
                expected_version: machine.version,
            });
        }
    }

    pub(super) fn activate_machine(&mut self, key: MachineKey) {
        self.select_machine_intent(key);
        if self.managed_machine(key).is_some_and(|machine| {
            machine.status == ManagedMachineStatus::Recoverable && machine.capabilities.restore
        }) {
            self.request_restore_managed_machine(key);
        } else {
            let needs_switch = self.machine_presented != Some(key)
                || self.machine_ui.as_ref().is_some_and(|ui| !ui.session_available);
            if let Some(ui) = self.machine_ui.as_mut() {
                if needs_switch {
                    ui.request = Some(MachineRequest::Switch(key));
                } else if matches!(ui.request, Some(MachineRequest::Switch(_))) {
                    ui.request = None;
                }
            }
        }
    }

    pub(super) fn request_purge_managed_machine(&mut self, key: MachineKey) {
        let Some(machine) = self.managed_machine(key).filter(|machine| {
            machine.status == ManagedMachineStatus::Recoverable && machine.capabilities.purge
        }) else {
            return;
        };
        if let Some(ui) = self.machine_ui.as_mut() {
            ui.request = Some(MachineRequest::PurgeManagedMachine {
                machine: key,
                expected_version: machine.version,
            });
        }
    }

    pub(super) fn open_rename_managed_machine_prompt(&mut self, key: MachineKey) {
        let Some(machine) = self.managed_machine(key).filter(|machine| {
            machine.status == ManagedMachineStatus::Active && machine.capabilities.rename
        }) else {
            return;
        };
        self.cancel_pty_mouse_drag();
        self.prompt = Some(Prompt::new(
            localization::catalog().sidebar.rename_machine,
            machine.name,
            PromptTarget::ManagedMachine(key),
        ));
    }

    pub(super) fn open_rename_client_machine_prompt(&mut self, key: MachineKey) {
        let Some(ui) = self.machine_ui.as_ref().filter(|ui| ui.is_client_machine_renamable(key))
        else {
            return;
        };
        let Some(name) = ui
            .snapshot
            .machines
            .iter()
            .find(|machine| machine.key == key)
            .map(|machine| machine.name.clone())
        else {
            return;
        };
        self.cancel_pty_mouse_drag();
        self.prompt = Some(Prompt::new(
            localization::catalog().sidebar.rename_machine,
            name,
            PromptTarget::ClientMachine(key),
        ));
    }

    pub(super) fn open_rename_machine_prompt(&mut self, key: MachineKey) {
        if self.managed_machine(key).is_some() {
            self.open_rename_managed_machine_prompt(key);
        } else {
            self.open_rename_client_machine_prompt(key);
        }
    }

    pub(super) fn open_delete_managed_machine_prompt(&mut self, key: MachineKey) {
        if self.managed_machine(key).is_some_and(|machine| {
            machine.status == ManagedMachineStatus::Active && machine.capabilities.delete
        }) {
            self.cancel_pty_mouse_drag();
            self.prompt = Some(Prompt::new(
                localization::catalog().sidebar.confirm_delete_machine,
                String::new(),
                PromptTarget::ConfirmDeleteManagedMachine(key),
            ));
        }
    }

    pub(super) fn open_purge_managed_machine_prompt(&mut self, key: MachineKey) {
        if self.managed_machine(key).is_some_and(|machine| {
            machine.status == ManagedMachineStatus::Recoverable && machine.capabilities.purge
        }) {
            self.cancel_pty_mouse_drag();
            self.prompt = Some(Prompt::new(
                localization::catalog().sidebar.confirm_purge_machine,
                String::new(),
                PromptTarget::ConfirmPurgeManagedMachine(key),
            ));
        }
    }

    pub(super) fn managed_workspace_for_view(
        &self,
        workspace_id: WorkspaceId,
    ) -> Option<ManagedWorkspaceDescriptor> {
        let workspace_key = self
            .tree
            .workspaces()
            .iter()
            .find(|workspace| workspace.id == workspace_id)?
            .key
            .as_str();
        self.machine_ui
            .as_ref()?
            .managed_workspace(workspace_key)
            .filter(|workspace| workspace.status == ManagedWorkspaceStatus::Active)
            .cloned()
    }

    pub(super) fn provider_manages_current_workspace_session(&self) -> bool {
        self.session.workspaces_are_provider_managed()
            || uses_provider_managed_workspaces(self.machine_ui.as_ref())
    }

    pub(super) fn reject_inactive_managed_workspace_machine(&mut self) {
        self.status_message =
            Some(localization::catalog().sidebar.managed_workspace_machine_inactive.to_string());
    }

    pub(super) fn reject_unavailable_managed_workspace_operation(&mut self) {
        self.status_message =
            Some(localization::catalog().sidebar.managed_workspace_unavailable.to_string());
    }

    pub(super) fn reject_disallowed_managed_workspace_operation(&mut self) {
        self.status_message = Some(
            localization::catalog().sidebar.managed_workspace_operation_not_allowed.to_string(),
        );
    }

    pub(super) fn request_rename_managed_workspace(
        &mut self,
        workspace_id: WorkspaceId,
        name: String,
    ) {
        let Some(machine) = self.machine_ui.as_ref().and_then(|ui| ui.snapshot.active) else {
            self.reject_inactive_managed_workspace_machine();
            return;
        };
        let Some(workspace) = self.managed_workspace_for_view(workspace_id) else {
            self.reject_unavailable_managed_workspace_operation();
            return;
        };
        if workspace.capabilities.rename
            && let Some(ui) = self.machine_ui.as_mut()
        {
            ui.request = Some(MachineRequest::RenameManagedWorkspace {
                machine,
                workspace_id: workspace.id,
                expected_version: workspace.version,
                name,
            });
        } else {
            self.reject_disallowed_managed_workspace_operation();
        }
    }

    pub(super) fn request_rename_workspace(&mut self, workspace_id: WorkspaceId, name: String) {
        if self.provider_manages_current_workspace_session() {
            self.request_rename_managed_workspace(workspace_id, name);
        } else {
            self.session.rename_workspace(workspace_id, name);
        }
    }

    pub(super) fn request_delete_workspace(&mut self, workspace_id: WorkspaceId) {
        if self.provider_manages_current_workspace_session() {
            let Some(machine) = self.machine_ui.as_ref().and_then(|ui| ui.snapshot.active) else {
                self.reject_inactive_managed_workspace_machine();
                return;
            };
            let Some(workspace) = self.managed_workspace_for_view(workspace_id) else {
                self.reject_unavailable_managed_workspace_operation();
                return;
            };
            if workspace.capabilities.delete
                && let Some(ui) = self.machine_ui.as_mut()
            {
                ui.request = Some(MachineRequest::DeleteManagedWorkspace {
                    machine,
                    workspace_id: workspace.id,
                    expected_version: workspace.version,
                });
            } else {
                self.reject_disallowed_managed_workspace_operation();
            }
            return;
        }
        self.session.close_workspace(workspace_id);
    }

    pub(super) fn request_restore_managed_workspace(&mut self, workspace_id: &str) {
        let Some(workspace) = self
            .machine_ui
            .as_ref()
            .and_then(|ui| ui.managed_workspace(workspace_id))
            .filter(|workspace| {
                workspace.status == ManagedWorkspaceStatus::Recoverable
                    && workspace.capabilities.restore
            })
            .cloned()
        else {
            return;
        };
        let Some(machine) = self.machine_ui.as_ref().and_then(|ui| ui.snapshot.active) else {
            return;
        };
        if let Some(ui) = self.machine_ui.as_mut() {
            ui.request = Some(MachineRequest::RestoreManagedWorkspace {
                machine,
                workspace_id: workspace.id,
                expected_version: workspace.version,
            });
        }
    }

    pub(super) fn request_purge_managed_workspace(&mut self, workspace_id: &str) {
        let Some(workspace) = self
            .machine_ui
            .as_ref()
            .and_then(|ui| ui.managed_workspace(workspace_id))
            .filter(|workspace| {
                workspace.status == ManagedWorkspaceStatus::Recoverable
                    && workspace.capabilities.purge
            })
            .cloned()
        else {
            return;
        };
        let Some(machine) = self.machine_ui.as_ref().and_then(|ui| ui.snapshot.active) else {
            return;
        };
        if let Some(ui) = self.machine_ui.as_mut() {
            ui.request = Some(MachineRequest::PurgeManagedWorkspace {
                machine,
                workspace_id: workspace.id,
                expected_version: workspace.version,
            });
        }
    }

    pub(super) fn workspace_rail_targets(&self) -> Vec<WorkspaceRailTarget> {
        let mut targets = self
            .tree
            .workspaces()
            .iter()
            .map(|workspace| WorkspaceRailTarget::Workspace(workspace.id))
            .collect::<Vec<_>>();
        targets.extend(
            self.machine_ui
                .as_ref()
                .into_iter()
                .flat_map(MachineUiState::recoverable_workspaces)
                .map(|workspace| WorkspaceRailTarget::Recoverable(workspace.id.clone())),
        );
        targets.extend(
            self.workspace_sidebar_action_rows()
                .into_iter()
                .map(|action| WorkspaceRailTarget::Action(action.target)),
        );
        targets
    }

    pub(super) fn workspace_rail_target(&self) -> Option<WorkspaceRailTarget> {
        match self.workspace_rail_selection {
            WorkspaceRailSelection::Workspace => self
                .tree
                .workspaces()
                .get(self.sidebar_workspace_selection)
                .map(|workspace| WorkspaceRailTarget::Workspace(workspace.id)),
            WorkspaceRailSelection::Recoverable => self
                .machine_ui
                .as_ref()
                .and_then(|ui| {
                    ui.recoverable_workspaces()
                        .get(self.sidebar_recoverable_workspace_selection)
                        .copied()
                })
                .map(|workspace| WorkspaceRailTarget::Recoverable(workspace.id.clone())),
            WorkspaceRailSelection::Action(action) => Some(WorkspaceRailTarget::Action(action)),
        }
    }

    pub(super) fn select_workspace_rail_target(&mut self, target: WorkspaceRailTarget) {
        match target {
            WorkspaceRailTarget::Workspace(id) => {
                if let Some(index) =
                    self.tree.workspaces().iter().position(|workspace| workspace.id == id)
                {
                    if self.sidebar_workspace_selection != index {
                        self.tabs_rail_selection = 0;
                        self.tabs_rail_scroll = 0;
                    }
                    self.sidebar_workspace_selection = index;
                    self.workspace_rail_selection = WorkspaceRailSelection::Workspace;
                }
            }
            WorkspaceRailTarget::Recoverable(id) => {
                if let Some(index) = self.machine_ui.as_ref().and_then(|ui| {
                    ui.recoverable_workspaces().iter().position(|workspace| workspace.id == id)
                }) {
                    self.sidebar_recoverable_workspace_selection = index;
                    self.workspace_rail_selection = WorkspaceRailSelection::Recoverable;
                }
            }
            WorkspaceRailTarget::Action(action) => {
                self.workspace_rail_selection = WorkspaceRailSelection::Action(action);
            }
        }
    }

    pub(super) fn new_screen(&mut self, semantic_intent: Option<u64>) -> anyhow::Result<()> {
        if !self.prepare_pty_input_before_mutation() {
            return Ok(());
        }
        let workspace = self.tree.active_workspace().map(|workspace| workspace.id);
        self.session.new_screen_for_semantic_intent(
            workspace,
            self.size_of_rect(self.content_area),
            semantic_intent,
        )
    }
}

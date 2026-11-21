//! Projection of provider snapshots (machines, lifecycle, workspaces, scopes and actions) into
//! the sidebar's `MachineUiState`.

use super::*;

pub(super) fn machine_ui_state(
    snapshot: &protocol::SnapshotResult,
    machine_lifecycle_snapshot: &protocol::MachineLifecycleSnapshotResult,
    workspace_snapshot: Option<&protocol::WorkspaceSnapshotResult>,
    keys: &Arc<Mutex<KeyRegistry>>,
    session_available: bool,
    provider_connect_supported: bool,
) -> MachineUiState {
    reconcile_keys(keys, snapshot, machine_lifecycle_snapshot);
    let active = snapshot.selected_machine_id.as_ref().and_then(|id| key_for_id(keys, id));
    let snapshot_machine_ids: HashSet<_> =
        snapshot.machines.iter().map(|machine| machine.id.clone()).collect();
    let mut ui = MachineUiState::new(MachineSnapshot {
        machines: snapshot
            .machines
            .iter()
            .filter_map(|machine| {
                Some(MachineDescriptor {
                    key: key_for_id(keys, &machine.id)?,
                    id: machine.id.as_str().to_string(),
                    name: machine.display_name.clone(),
                    subtitle: machine.subtitle.clone(),
                    status: machine_status(machine.status),
                    platform: machine.platform.as_ref().map(|platform| MachinePlatform {
                        os: platform.os.clone(),
                        arch: platform.arch.clone(),
                    }),
                    capabilities: machine.capabilities.clone(),
                })
            })
            .chain(
                machine_lifecycle_snapshot
                    .machines
                    .iter()
                    .filter(|managed| {
                        managed.status == protocol::MachineLifecycleStatus::Recoverable
                            && !snapshot_machine_ids.contains(&managed.id)
                    })
                    .filter_map(|machine| {
                        Some(MachineDescriptor {
                            key: key_for_id(keys, &machine.id)?,
                            id: machine.id.as_str().to_string(),
                            name: machine.display_name.clone(),
                            subtitle: String::new(),
                            status: MachineStatus::Stopped,
                            platform: None,
                            capabilities: Vec::new(),
                        })
                    }),
            )
            .collect(),
        active,
        capabilities: MachineCapabilities {
            create: snapshot.capabilities.create_machine,
            connect: snapshot.capabilities.connect_external_machine && provider_connect_supported,
        },
    });
    ui.connect_accepts_pairing_code =
        snapshot.capabilities.connect_external_machine && provider_connect_supported;
    ui.session_available = session_available;
    ui.set_managed_machines(
        machine_lifecycle_snapshot
            .machines
            .iter()
            .filter_map(|machine| managed_machine_descriptor(machine, keys))
            .collect(),
    );
    for machine in &snapshot.machines {
        let Some(key) = key_for_id(keys, &machine.id) else { continue };
        let policy = match &machine.workspace_create {
            protocol::WorkspaceCreatePolicy::Session => WorkspaceCreationPolicy::SessionOwned,
            protocol::WorkspaceCreatePolicy::Provider { default_mode, modes } => {
                WorkspaceCreationPolicy::ProviderOwned {
                    default_mode: workspace_creation_mode(*default_mode),
                    modes: modes.iter().copied().map(workspace_creation_mode).collect(),
                }
            }
        };
        ui.set_workspace_creation_policy(key, policy);
    }
    if let Some(workspace_snapshot) = workspace_snapshot
        && let Some(key) = key_for_id(keys, &workspace_snapshot.machine_id)
    {
        ui.set_managed_workspaces(
            key,
            workspace_snapshot.workspaces.iter().map(managed_workspace_descriptor).collect(),
        );
    }
    ui.set_provider_presentation(provider_presentation(snapshot));
    ui
}

fn managed_machine_descriptor(
    machine: &protocol::MachineLifecycleDescriptor,
    keys: &Arc<Mutex<KeyRegistry>>,
) -> Option<ManagedMachineDescriptor> {
    Some(ManagedMachineDescriptor {
        key: key_for_id(keys, &machine.id)?,
        id: machine.id.as_str().to_string(),
        name: machine.display_name.clone(),
        status: match machine.status {
            protocol::MachineLifecycleStatus::Active => ManagedMachineStatus::Active,
            protocol::MachineLifecycleStatus::Recoverable => ManagedMachineStatus::Recoverable,
        },
        version: machine.version,
        recoverable_until: machine.recoverable_until.clone(),
        capabilities: ManagedMachineCapabilities {
            rename: machine.capabilities.rename,
            delete: machine.capabilities.delete,
            restore: machine.capabilities.restore,
            purge: machine.capabilities.purge,
        },
    })
}

fn managed_workspace_descriptor(
    workspace: &protocol::WorkspaceLifecycleDescriptor,
) -> ManagedWorkspaceDescriptor {
    ManagedWorkspaceDescriptor {
        id: workspace.id.as_str().to_string(),
        name: workspace.display_name.clone(),
        mode: workspace_creation_mode(workspace.mode),
        status: match workspace.status {
            protocol::WorkspaceLifecycleStatus::Active => ManagedWorkspaceStatus::Active,
            protocol::WorkspaceLifecycleStatus::Recoverable => ManagedWorkspaceStatus::Recoverable,
        },
        version: workspace.version,
        recoverable_until: workspace.recoverable_until.clone(),
        capabilities: ManagedWorkspaceCapabilities {
            rename: workspace.capabilities.rename,
            delete: workspace.capabilities.delete,
            restore: workspace.capabilities.restore,
            purge: workspace.capabilities.purge,
        },
    }
}

fn workspace_creation_mode(mode: protocol::WorkspaceCreateMode) -> WorkspaceCreationMode {
    match mode {
        protocol::WorkspaceCreateMode::Isolated => WorkspaceCreationMode::Isolated,
        protocol::WorkspaceCreateMode::Host => WorkspaceCreationMode::Host,
    }
}

fn machine_status(status: protocol::MachineStatus) -> MachineStatus {
    match status {
        protocol::MachineStatus::Running => MachineStatus::Running,
        protocol::MachineStatus::Connecting => MachineStatus::Connecting,
        protocol::MachineStatus::Sleeping => MachineStatus::Sleeping,
        protocol::MachineStatus::Stopped => MachineStatus::Stopped,
        protocol::MachineStatus::Unavailable => MachineStatus::Unavailable,
    }
}

pub(super) fn provider_presentation(snapshot: &protocol::SnapshotResult) -> ProviderPresentation {
    ProviderPresentation {
        scopes: snapshot
            .scopes
            .iter()
            .map(|scope| ProviderScopeDescriptor {
                id: scope.id.as_str().to_string(),
                name: scope.display_name.clone(),
                kind: match scope.kind {
                    protocol::ScopeKind::Personal => ProviderScopeKind::Personal,
                    protocol::ScopeKind::Team => ProviderScopeKind::Team,
                },
                can_admin: scope.can_admin,
            })
            .collect(),
        selected_scope_id: snapshot.selected_scope_id.as_str().to_string(),
        actions: snapshot
            .actions
            .iter()
            .filter_map(|action| {
                let target = match action.target {
                    protocol::ProviderActionTarget::Scope => ProviderActionTarget::Scope,
                    protocol::ProviderActionTarget::SelectedMachine => {
                        ProviderActionTarget::SelectedMachine
                    }
                    protocol::ProviderActionTarget::SelectedWorkspace => {
                        ProviderActionTarget::SelectedWorkspace
                    }
                    protocol::ProviderActionTarget::Unsupported => return None,
                };
                Some(ProviderActionDescriptor {
                    id: action.id.as_str().to_string(),
                    label: localization::catalog()
                        .sidebar
                        .provider_action_label(action.id.as_str())
                        .unwrap_or(&action.label)
                        .to_string(),
                    target,
                    destructive: action.destructive,
                    fields: action
                        .fields
                        .iter()
                        .map(|field| ProviderActionFieldDescriptor {
                            id: field.id.clone(),
                            label: localization::catalog()
                                .sidebar
                                .provider_action_field_label(action.id.as_str(), &field.id)
                                .unwrap_or(&field.label)
                                .to_string(),
                            kind: match field.kind {
                                protocol::ActionFieldKind::Text => ProviderActionFieldKind::Text,
                                protocol::ActionFieldKind::Email => ProviderActionFieldKind::Email,
                                protocol::ActionFieldKind::Integer => {
                                    ProviderActionFieldKind::Integer
                                }
                            },
                            required: field.required,
                            max_length: field.max_length,
                            minimum: field.minimum,
                            maximum: field.maximum,
                            placeholder: field.placeholder.clone(),
                        })
                        .collect(),
                })
            })
            .collect(),
    }
}

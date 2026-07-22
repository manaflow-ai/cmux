//! Dynamic machine catalog backed by a versioned external provider.

use std::collections::{BTreeMap, HashMap, HashSet};
#[cfg(test)]
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::time::Duration;

use cmux_tui_core::{Mux, SurfaceOptions};
use cmux_tui_machine_protocol as protocol;
use zeroize::Zeroize;

use crate::config::MachineConfig;
use crate::localization;
use crate::machine::{
    MachineActionResult, MachineCapabilities, MachineController, MachineDescriptor, MachineKey,
    MachineRequest, MachineSnapshot, MachineStatus, MachineUiState, MachineUpdateStream,
    ManagedMachineCapabilities, ManagedMachineDescriptor, ManagedMachineStatus,
    ManagedWorkspaceCapabilities, ManagedWorkspaceDescriptor, ManagedWorkspaceSessionMutation,
    ManagedWorkspaceStatus, ProviderActionDescriptor, ProviderActionFieldDescriptor,
    ProviderActionFieldKind, ProviderActionValue, ProviderPresentation, ProviderScopeDescriptor,
    ProviderScopeKind, WorkspaceCreationMode, WorkspaceCreationPolicy,
};
#[cfg(test)]
use crate::machine_provider_client::UnixProviderConnector;
use crate::machine_provider_client::{MachineProviderConnector, ProviderClient};
use crate::machine_runtime::MachineRuntime;
use crate::session::{RemoteSession, Session};

struct OpenConnection {
    client: Arc<ProviderClient>,
    connection_id: protocol::OpaqueId,
    machine_id: protocol::OpaqueId,
}

struct ProviderSelectionRollback {
    selected_machine_id: Option<protocol::OpaqueId>,
    workspace_snapshot: Option<protocol::WorkspaceSnapshotResult>,
}

struct PendingConnection {
    candidate: Option<OpenConnection>,
    rollback: Option<ProviderSelectionRollback>,
}

struct KeyRegistry {
    by_id: HashMap<protocol::OpaqueId, MachineKey>,
    by_key: HashMap<MachineKey, protocol::OpaqueId>,
    next: u64,
}

/// Owns the provider control connection and stable process-local machine keys.
pub(crate) struct ProviderMachineRuntime {
    connector: Arc<dyn MachineProviderConnector>,
    client: Arc<ProviderClient>,
    snapshot: protocol::SnapshotResult,
    machine_lifecycle_snapshot: protocol::MachineLifecycleSnapshotResult,
    workspace_snapshot: Option<protocol::WorkspaceSnapshotResult>,
    keys: Arc<Mutex<KeyRegistry>>,
    mutation_nonce: String,
    mutation_sequence: AtomicU64,
    open: Option<OpenConnection>,
    pending: Option<PendingConnection>,
    notice: Option<String>,
}

/// Composes a provider-owned catalog with client-local socket and SSH targets.
/// The provider never receives local target names, credentials, or lifecycle
/// requests. Native provider processes can omit this wrapper entirely.
pub(crate) struct ProviderMachineController {
    provider: ProviderMachineRuntime,
    local: MachineRuntime,
    active_local: Option<MachineKey>,
    pending_active_local: Option<Option<MachineKey>>,
}

impl ProviderMachineController {
    pub(crate) fn connect_with(
        connector: Arc<dyn MachineProviderConnector>,
        configured: Vec<MachineConfig>,
        connect_external: bool,
    ) -> anyhow::Result<Self> {
        Ok(Self {
            provider: ProviderMachineRuntime::connect_with(connector)?,
            local: MachineRuntime::external(configured, connect_external),
            active_local: None,
            pending_active_local: None,
        })
    }

    pub(crate) fn open_selected(&mut self) -> anyhow::Result<(Session, String, MachineUiState)> {
        let (session, label, ui) = self.provider.open_selected()?;
        Ok((session, label, self.merge_local_ui(ui)))
    }

    pub(crate) fn placeholder(
        &mut self,
        notice: impl Into<String>,
    ) -> (Session, String, MachineUiState) {
        let (session, label, ui) = self.provider.placeholder(notice);
        (session, label, self.merge_local_ui(ui))
    }

    fn perform_request(&mut self, request: MachineRequest) -> anyhow::Result<MachineActionResult> {
        match request {
            MachineRequest::Switch(key) if self.local.contains(key) => self.switch_local(key),
            MachineRequest::Connect(target) => {
                let key = self.local.connect_machine(&target)?;
                self.switch_local(key)
            }
            MachineRequest::ReconnectProvider if self.active_local.is_some() => {
                self.provider.reconnect_control()?;
                let ui = self.provider.ui_state_for_open_connection();
                let mut result = MachineActionResult::ui(self.merge_local_ui(ui));
                result.restart_updates = true;
                Ok(result)
            }
            request => {
                let switching_provider = matches!(request, MachineRequest::Switch(_));
                let mut result = self.provider.perform_request(request)?;
                if result.replacement.is_some()
                    && (switching_provider || self.active_local.is_none())
                {
                    self.pending_active_local = Some(None);
                    result.ui = self.merge_local_ui_for(result.ui, None);
                } else if self.active_local.is_some() && result.replacement.is_some() {
                    // A provider lifecycle response must never replace an
                    // active client-local session implicitly.
                    self.provider.abort_replacement();
                    result.replacement = None;
                    result.session_label = None;
                    result.ui = self.merge_local_ui(result.ui);
                } else {
                    result.ui = self.merge_local_ui(result.ui);
                }
                Ok(result)
            }
        }
    }

    fn switch_local(&mut self, key: MachineKey) -> anyhow::Result<MachineActionResult> {
        // Open the candidate first. Failed SSH or socket authentication leaves
        // the current provider/local session untouched.
        let session = self.local.connect(key)?;
        let label = self.local.name(key).unwrap_or("machine").to_string();
        self.provider.stage_connection(None, None)?;
        self.pending_active_local = Some(Some(key));
        let ui = self.provider.ui_state_for_open_connection();
        let mut result =
            MachineActionResult::replace(self.merge_local_ui_for(ui, Some(key)), session, label);
        result.restart_updates = true;
        Ok(result)
    }

    fn merge_local_ui(&self, ui: MachineUiState) -> MachineUiState {
        self.merge_local_ui_for(ui, self.active_local)
    }

    fn merge_local_ui_for(
        &self,
        ui: MachineUiState,
        active_local: Option<MachineKey>,
    ) -> MachineUiState {
        merge_local_machine_ui(ui, &self.local.snapshot_with_active(active_local), active_local)
    }

    fn subscribe_ui_updates(&self) -> anyhow::Result<MachineUpdateStream> {
        let provider_updates = self.provider.subscribe_ui_updates()?;
        let (provider_receiver, provider_stop, provider_worker) = provider_updates.into_parts();
        let local_snapshot = self.local.snapshot_with_active(self.active_local);
        let active_local = self.active_local;
        let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let worker_stop = stop.clone();
        let (sender, receiver) = mpsc::sync_channel(8);
        let worker =
            std::thread::Builder::new().name("machine-local-overlay".into()).spawn(move || {
                while !worker_stop.load(Ordering::Acquire) {
                    match provider_receiver.recv_timeout(Duration::from_millis(250)) {
                        Ok(ui) => {
                            if sender
                                .send(merge_local_machine_ui(ui, &local_snapshot, active_local))
                                .is_err()
                            {
                                break;
                            }
                        }
                        Err(mpsc::RecvTimeoutError::Timeout) => continue,
                        Err(mpsc::RecvTimeoutError::Disconnected) => break,
                    }
                }
                provider_stop.store(true, Ordering::Release);
                drop(provider_receiver);
                let _ = provider_worker.join();
            })?;
        Ok(MachineUpdateStream::new(receiver, stop, worker))
    }

    fn close(&mut self) {
        self.abort_replacement();
        self.provider.close();
    }

    fn commit_replacement(&mut self) -> anyhow::Result<()> {
        let active_local = self.pending_active_local.as_ref().copied().ok_or_else(|| {
            anyhow::anyhow!(localization::catalog().sidebar.machine_replacement_target_missing)
        })?;
        self.provider.commit_replacement()?;
        self.pending_active_local.take();
        self.active_local = active_local;
        Ok(())
    }

    fn abort_replacement(&mut self) {
        self.provider.abort_replacement();
        self.pending_active_local = None;
    }
}

impl MachineController for ProviderMachineController {
    fn perform(&mut self, request: MachineRequest) -> anyhow::Result<MachineActionResult> {
        self.perform_request(request)
    }

    fn subscribe_updates(&self) -> anyhow::Result<Option<MachineUpdateStream>> {
        self.subscribe_ui_updates().map(Some)
    }

    fn commit_replacement(&mut self) -> anyhow::Result<()> {
        ProviderMachineController::commit_replacement(self)
    }

    fn abort_replacement(&mut self) {
        ProviderMachineController::abort_replacement(self);
    }

    fn close(&mut self) {
        ProviderMachineController::close(self);
    }
}

impl ProviderMachineRuntime {
    #[cfg(test)]
    pub(crate) fn connect(
        socket_path: impl AsRef<Path>,
        token: protocol::BearerToken,
    ) -> anyhow::Result<Self> {
        Self::connect_with(Arc::new(UnixProviderConnector::new(
            socket_path.as_ref().to_path_buf(),
            token,
        )))
    }

    pub(crate) fn connect_with(
        connector: Arc<dyn MachineProviderConnector>,
    ) -> anyhow::Result<Self> {
        let (client, snapshot, machine_lifecycle_snapshot, workspace_snapshot) =
            connect_client(Arc::clone(&connector))?;
        let client = Arc::new(client);
        let mut runtime = Self {
            connector,
            client,
            snapshot,
            machine_lifecycle_snapshot,
            workspace_snapshot,
            keys: Arc::new(Mutex::new(KeyRegistry {
                by_id: HashMap::new(),
                by_key: HashMap::new(),
                next: 1,
            })),
            mutation_nonce: random_mutation_nonce()?,
            mutation_sequence: AtomicU64::new(1),
            open: None,
            pending: None,
            notice: None,
        };
        runtime.reconcile_keys();
        Ok(runtime)
    }

    pub(crate) fn refresh(&mut self) -> anyhow::Result<()> {
        self.snapshot = self.client.snapshot(Some(self.snapshot.revision))?;
        self.machine_lifecycle_snapshot =
            load_machine_lifecycle_snapshot(&self.client, &self.snapshot)?;
        self.workspace_snapshot = load_workspace_snapshot(&self.client, &self.snapshot)?;
        self.reconcile_keys();
        if let Some(notice) = &self.snapshot.notice {
            self.notice = Some(notice.message.clone());
        }
        Ok(())
    }

    pub(crate) fn open_selected(&mut self) -> anyhow::Result<(Session, String, MachineUiState)> {
        let (session, label, open) = self.open_selected_candidate()?;
        self.close_open_connection();
        let session_available = open.is_some();
        self.open = open;
        let mut ui = self.ui_state(session_available);
        ui.notice = self.notice.take();
        Ok((session, label, ui))
    }

    pub(crate) fn placeholder(
        &mut self,
        notice: impl Into<String>,
    ) -> (Session, String, MachineUiState) {
        self.close_open_connection();
        let label = self
            .snapshot
            .selected_machine_id
            .as_ref()
            .and_then(|id| self.snapshot.machines.iter().find(|machine| &machine.id == id))
            .map(|machine| machine.display_name.clone())
            .unwrap_or_else(|| "machines".to_string());
        let mut ui = self.ui_state(false);
        ui.notice = Some(notice.into());
        (placeholder_session(), label, ui)
    }

    fn perform_request(&mut self, request: MachineRequest) -> anyhow::Result<MachineActionResult> {
        if matches!(&request, MachineRequest::ReconnectProvider) {
            return self.reconnect_session();
        }
        // Live catalog events update the rail without interrupting a usable
        // remote session. Re-read the authoritative snapshot when the user
        // acts so newly added machines and changed scopes cannot race the
        // runtime's local snapshot.
        self.refresh()?;
        match request {
            MachineRequest::Switch(key) => {
                let machine_id = self.machine_id(key)?;
                let rollback = ProviderSelectionRollback {
                    selected_machine_id: self.snapshot.selected_machine_id.clone(),
                    workspace_snapshot: self.workspace_snapshot.clone(),
                };
                self.snapshot.selected_machine_id = Some(machine_id);
                self.workspace_snapshot =
                    match load_workspace_snapshot(&self.client, &self.snapshot) {
                        Ok(snapshot) => snapshot,
                        Err(error) => {
                            self.restore_selection(rollback);
                            return Err(error);
                        }
                    };
                let (session, label, open) = match self.open_selected_candidate() {
                    Ok(candidate) => candidate,
                    Err(error) => {
                        self.restore_selection(rollback);
                        return Err(error);
                    }
                };
                let session_available = open.is_some();
                self.stage_connection(open, Some(rollback))?;
                let mut ui = self.ui_state(session_available);
                ui.notice = self.notice.take();
                let mut result = MachineActionResult::replace(ui, session, label);
                result.restart_updates = true;
                return Ok(result);
            }
            MachineRequest::Create => {
                let created = self.client.create_machine(
                    self.snapshot.selected_scope_id.clone(),
                    self.next_mutation_id()?,
                )?;
                let created_machine_id = created.machine_id;
                self.set_notice(created.notice);
                self.refresh()?;
                if key_for_id(&self.keys, &created_machine_id).is_some() {
                    self.snapshot.selected_machine_id = Some(created_machine_id);
                    self.workspace_snapshot =
                        load_workspace_snapshot(&self.client, &self.snapshot)?;
                }
            }
            MachineRequest::SelectProviderScope(scope_id) => {
                let scope_id = protocol::OpaqueId::new(scope_id)?;
                self.snapshot = self.client.select_scope(scope_id)?.snapshot;
                self.machine_lifecycle_snapshot =
                    load_machine_lifecycle_snapshot(&self.client, &self.snapshot)?;
                self.workspace_snapshot = load_workspace_snapshot(&self.client, &self.snapshot)?;
                self.reconcile_keys();
            }
            MachineRequest::InvokeProviderAction { action_id, values } => {
                let values = values
                    .into_iter()
                    .map(|(key, value)| {
                        let value = match value {
                            ProviderActionValue::Text(value) => protocol::ActionValue::Text(value),
                            ProviderActionValue::Integer(value) => {
                                protocol::ActionValue::Integer(value)
                            }
                        };
                        (key, value)
                    })
                    .collect::<BTreeMap<_, _>>();
                let result = self.client.invoke_action(
                    protocol::OpaqueId::new(action_id)?,
                    values,
                    self.next_mutation_id()?,
                )?;
                let selected_scope_id = result.selected_scope_id;
                let selected_machine_id = result.selected_machine_id;
                self.set_notice(result.notice);
                if let Some(url) = result.url {
                    self.notice = Some(format!("Open {url}"));
                }
                self.refresh()?;
                if let Some(scope_id) = selected_scope_id {
                    self.snapshot.selected_scope_id = scope_id;
                }
                if let Some(machine_id) = selected_machine_id
                    && key_for_id(&self.keys, &machine_id).is_some()
                {
                    self.snapshot.selected_machine_id = Some(machine_id);
                }
            }
            MachineRequest::RenameManagedMachine { machine, expected_version, name } => {
                let machine_id = self.machine_id(machine)?;
                let renames_open_session =
                    self.open.as_ref().is_some_and(|open| open.machine_id == machine_id);
                let result = self.client.rename_machine(protocol::RenameMachineParams {
                    scope_id: self.snapshot.selected_scope_id.clone(),
                    machine_id: machine_id.clone(),
                    expected_version,
                    display_name: name,
                    mutation_id: self.next_mutation_id()?,
                })?;
                self.set_notice(result.notice);
                self.refresh()?;
                let result = MachineActionResult::ui(self.ui_state_for_open_connection());
                return Ok(if renames_open_session {
                    let label = self
                        .snapshot
                        .machines
                        .iter()
                        .find(|machine| machine.id == machine_id)
                        .map(|machine| machine.display_name.clone())
                        .ok_or_else(|| {
                            anyhow::anyhow!("renamed machine is missing from snapshot")
                        })?;
                    result.with_session_label(label)
                } else {
                    result
                });
            }
            MachineRequest::DeleteManagedMachine { machine, expected_version } => {
                let machine_id = self.machine_id(machine)?;
                let deletes_open_session =
                    self.open.as_ref().is_some_and(|open| open.machine_id == machine_id);
                let result = self.client.delete_machine(protocol::MachineMutationParams {
                    scope_id: self.snapshot.selected_scope_id.clone(),
                    machine_id,
                    expected_version,
                    mutation_id: self.next_mutation_id()?,
                })?;
                self.set_notice(result.notice);
                self.refresh()?;
                if deletes_open_session {
                    let (session, label, open) = self.open_selected_candidate()?;
                    let session_available = open.is_some();
                    self.stage_connection(open, None)?;
                    let mut ui = self.ui_state(session_available);
                    ui.notice = self.notice.take();
                    return Ok(MachineActionResult::replace(ui, session, label));
                }
            }
            MachineRequest::RestoreManagedMachine { machine, expected_version } => {
                let result = self.client.restore_machine(protocol::MachineMutationParams {
                    scope_id: self.snapshot.selected_scope_id.clone(),
                    machine_id: self.machine_id(machine)?,
                    expected_version,
                    mutation_id: self.next_mutation_id()?,
                })?;
                self.set_notice(result.notice);
                self.refresh()?;
            }
            MachineRequest::PurgeManagedMachine { machine, expected_version } => {
                let result = self.client.purge_machine(protocol::MachineMutationParams {
                    scope_id: self.snapshot.selected_scope_id.clone(),
                    machine_id: self.machine_id(machine)?,
                    expected_version,
                    mutation_id: self.next_mutation_id()?,
                })?;
                self.set_notice(result.notice);
                self.refresh()?;
            }
            MachineRequest::CreateManagedIsolatedWorkspace(key) => {
                self.create_workspace(key, protocol::WorkspaceCreateMode::Isolated)?;
            }
            MachineRequest::CreateManagedHostWorkspace(key) => {
                self.create_workspace(key, protocol::WorkspaceCreateMode::Host)?;
            }
            MachineRequest::RenameManagedWorkspace {
                machine,
                workspace_id,
                expected_version,
                name,
            } => {
                let result = self.client.rename_workspace(protocol::RenameWorkspaceParams {
                    machine_id: self.machine_id(machine)?,
                    workspace_id: protocol::OpaqueId::new(workspace_id.clone())?,
                    expected_version,
                    display_name: name.clone(),
                    mutation_id: self.next_mutation_id()?,
                })?;
                self.set_notice(result.notice);
                self.refresh()?;
                return Ok(MachineActionResult::ui(self.ui_state_for_open_connection())
                    .with_session_mutation(ManagedWorkspaceSessionMutation::Rename {
                        workspace_key: workspace_id,
                        name,
                    }));
            }
            MachineRequest::DeleteManagedWorkspace { machine, workspace_id, expected_version } => {
                let result = self.client.delete_workspace(protocol::WorkspaceMutationParams {
                    machine_id: self.machine_id(machine)?,
                    workspace_id: protocol::OpaqueId::new(workspace_id.clone())?,
                    expected_version,
                    mutation_id: self.next_mutation_id()?,
                })?;
                self.set_notice(result.notice);
                self.refresh()?;
                return Ok(MachineActionResult::ui(self.ui_state_for_open_connection())
                    .with_session_mutation(ManagedWorkspaceSessionMutation::Close {
                        workspace_key: workspace_id,
                    }));
            }
            MachineRequest::RestoreManagedWorkspace { machine, workspace_id, expected_version } => {
                let result = self.client.restore_workspace(protocol::WorkspaceMutationParams {
                    machine_id: self.machine_id(machine)?,
                    workspace_id: protocol::OpaqueId::new(workspace_id)?,
                    expected_version,
                    mutation_id: self.next_mutation_id()?,
                })?;
                self.set_notice(result.notice);
                self.refresh()?;
            }
            MachineRequest::PurgeManagedWorkspace { machine, workspace_id, expected_version } => {
                let result = self.client.purge_workspace(protocol::WorkspaceMutationParams {
                    machine_id: self.machine_id(machine)?,
                    workspace_id: protocol::OpaqueId::new(workspace_id)?,
                    expected_version,
                    mutation_id: self.next_mutation_id()?,
                })?;
                self.set_notice(result.notice);
                self.refresh()?;
            }
            MachineRequest::Connect(_) => {
                anyhow::bail!("this machine provider cannot connect external machines")
            }
            MachineRequest::ReconnectProvider => unreachable!("handled before refresh"),
        }
        Ok(MachineActionResult::ui(self.ui_state_for_open_connection()))
    }

    pub(crate) fn close(&mut self) {
        self.abort_replacement();
        self.close_open_connection();
    }

    pub(crate) fn subscribe_ui_updates(&self) -> anyhow::Result<MachineUpdateStream> {
        let events = self.client.subscribe_events()?;
        let client = self.client.clone();
        let keys = self.keys.clone();
        let provider_connect_supported = client
            .supports_capability(protocol::EXTERNAL_MACHINE_CONNECT_CAPABILITY)
            .unwrap_or(false);
        let mut connected_machine_id = self.open.as_ref().map(|open| open.machine_id.clone());
        let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let thread_stop = stop.clone();
        let (sender, receiver) = mpsc::sync_channel(8);
        let mut last_snapshot = self.snapshot.clone();
        let mut last_machine_lifecycle_snapshot = self.machine_lifecycle_snapshot.clone();
        let mut last_workspace_snapshot = self.workspace_snapshot.clone();
        let worker = std::thread::Builder::new().name("machine-provider-snapshots".into()).spawn(
            move || {
                while !thread_stop.load(Ordering::Acquire) {
                    let event = match events.recv_timeout(Duration::from_millis(250)) {
                        Ok(event) => event,
                        Err(mpsc::RecvTimeoutError::Timeout) => continue,
                        Err(mpsc::RecvTimeoutError::Disconnected) => {
                            let mut ui = machine_ui_state(
                                &last_snapshot,
                                &last_machine_lifecycle_snapshot,
                                last_workspace_snapshot.as_ref(),
                                &keys,
                                false,
                                provider_connect_supported,
                            );
                            ui.notice = Some(
                                localization::catalog()
                                    .sidebar
                                    .machine_provider_disconnected
                                    .into(),
                            );
                            ui.request = Some(MachineRequest::ReconnectProvider);
                            let _ = sender.send(ui);
                            break;
                        }
                    };
                    let mut notice = None;
                    let had_connected_session = connected_machine_id.is_some();
                    if let protocol::ProviderEvent::ConnectionClosed(closed) = &event
                        && connected_machine_id.as_ref() == Some(&closed.machine_id)
                    {
                        connected_machine_id = None;
                        notice = Some(closed.reason.clone());
                    }
                    if let protocol::ProviderEvent::Notice(provider_notice) = &event {
                        notice = Some(provider_notice.message.clone());
                    }
                    let snapshot = match client.snapshot(Some(last_snapshot.revision)) {
                        Ok(snapshot) => snapshot,
                        Err(error) => {
                            let mut ui = machine_ui_state(
                                &last_snapshot,
                                &last_machine_lifecycle_snapshot,
                                last_workspace_snapshot.as_ref(),
                                &keys,
                                false,
                                provider_connect_supported,
                            );
                            ui.notice = Some(format!("Machine provider update failed: {error}"));
                            ui.request = Some(MachineRequest::ReconnectProvider);
                            let _ = sender.send(ui);
                            break;
                        }
                    };
                    last_snapshot = snapshot.clone();
                    last_machine_lifecycle_snapshot =
                        match load_machine_lifecycle_snapshot(&client, &snapshot) {
                            Ok(snapshot) => snapshot,
                            Err(error) => {
                                let mut ui = machine_ui_state(
                                    &last_snapshot,
                                    &last_machine_lifecycle_snapshot,
                                    last_workspace_snapshot.as_ref(),
                                    &keys,
                                    false,
                                    provider_connect_supported,
                                );
                                ui.notice = Some(format!(
                                    "Machine provider lifecycle update failed: {error}"
                                ));
                                ui.request = Some(MachineRequest::ReconnectProvider);
                                let _ = sender.send(ui);
                                break;
                            }
                        };
                    last_workspace_snapshot = match load_workspace_snapshot(&client, &snapshot) {
                        Ok(snapshot) => snapshot,
                        Err(error) => {
                            let mut ui = machine_ui_state(
                                &last_snapshot,
                                &last_machine_lifecycle_snapshot,
                                last_workspace_snapshot.as_ref(),
                                &keys,
                                false,
                                provider_connect_supported,
                            );
                            ui.notice =
                                Some(format!("Machine provider workspace update failed: {error}"));
                            ui.request = Some(MachineRequest::ReconnectProvider);
                            let _ = sender.send(ui);
                            break;
                        }
                    };
                    let session_available = snapshot.selected_machine_id.is_some()
                        && snapshot.selected_machine_id.as_ref() == connected_machine_id.as_ref();
                    let mut ui = machine_ui_state(
                        &snapshot,
                        &last_machine_lifecycle_snapshot,
                        last_workspace_snapshot.as_ref(),
                        &keys,
                        session_available,
                        provider_connect_supported,
                    );
                    ui.notice = notice
                        .or_else(|| snapshot.notice.as_ref().map(|notice| notice.message.clone()));
                    if !session_available
                        && let Some(selected) = snapshot.selected_machine_id.as_ref()
                        && snapshot
                            .machines
                            .iter()
                            .any(|machine| &machine.id == selected && machine.connectable)
                        && let Some(key) = key_for_id(&keys, selected)
                    {
                        ui.request = Some(MachineRequest::Switch(key));
                    } else if !session_available && had_connected_session {
                        ui.request = Some(MachineRequest::ReconnectProvider);
                    }
                    if sender.send(ui).is_err() {
                        break;
                    }
                }
            },
        )?;
        Ok(MachineUpdateStream::new(receiver, stop, worker))
    }

    fn reconnect_session(&mut self) -> anyhow::Result<MachineActionResult> {
        self.reconnect_control()?;

        match self.open_selected_candidate() {
            Ok((session, label, open)) => {
                let session_available = open.is_some();
                self.stage_connection(open, None)?;
                let mut ui = self.ui_state(session_available);
                ui.notice = self.notice.take();
                let mut result = MachineActionResult::replace(ui, session, label);
                result.restart_updates = true;
                Ok(result)
            }
            Err(error) => {
                // The provider control plane is live again, but opening its
                // selected machine failed. Keep the current mux transport and
                // restart catalog updates against the fresh control client.
                let mut ui = self.ui_state_for_open_connection();
                ui.notice = Some(format!("Could not reconnect machine: {error}"));
                Ok(MachineActionResult {
                    ui,
                    replacement: None,
                    restart_updates: true,
                    session_mutation: None,
                    session_label: None,
                })
            }
        }
    }

    fn reconnect_control(&mut self) -> anyhow::Result<()> {
        let (client, snapshot, machine_lifecycle_snapshot, workspace_snapshot) =
            connect_client(Arc::clone(&self.connector))?;
        self.client = Arc::new(client);
        self.snapshot = snapshot;
        self.machine_lifecycle_snapshot = machine_lifecycle_snapshot;
        self.workspace_snapshot = workspace_snapshot;
        self.reconcile_keys();
        if let Some(notice) = &self.snapshot.notice {
            self.notice = Some(notice.message.clone());
        }
        Ok(())
    }

    fn open_selected_candidate(&self) -> anyhow::Result<(Session, String, Option<OpenConnection>)> {
        let selected = self
            .snapshot
            .selected_machine_id
            .as_ref()
            .and_then(|id| self.snapshot.machines.iter().find(|machine| &machine.id == id))
            .cloned();
        let Some(machine) = selected else {
            return Ok((placeholder_session(), "machines".to_string(), None));
        };
        if !machine.connectable {
            anyhow::bail!("{} is not ready to connect", machine.display_name);
        }
        let provider_managed =
            matches!(machine.workspace_create, protocol::WorkspaceCreatePolicy::Provider { .. });
        if provider_managed
            && !self.client.supports_capability(protocol::WORKSPACE_MIRROR_AUTHORITY_CAPABILITY)?
        {
            anyhow::bail!(
                "{} cannot authorize managed workspace mirrors; upgrade the machine provider",
                machine.display_name
            );
        }

        let opened = self.client.open_machine(machine.id.clone(), provider_managed)?;
        let connection_id = opened.connection_id.clone();
        let workspace_mirror_authority = opened.workspace_mirror_authority;
        let authority_is_valid = workspace_mirror_authority.as_ref().is_some_and(|authority| {
            authority.expose().len() >= protocol::MIN_WORKSPACE_MIRROR_AUTHORITY_BYTES
        });
        if provider_managed != workspace_mirror_authority.is_some()
            || (provider_managed && !authority_is_valid)
        {
            let _ = self.client.close_machine(connection_id);
            anyhow::bail!(
                "{} returned an invalid managed workspace authority binding",
                machine.display_name
            );
        }
        let transport = match self.client.consume_transport(opened.transport) {
            Ok(transport) => transport,
            Err(error) => {
                let _ = self.client.close_machine(connection_id);
                return Err(error.into());
            }
        };
        let remote = match workspace_mirror_authority {
            Some(authority) => RemoteSession::connect_provider_transport(transport, authority),
            None => RemoteSession::connect_transport(transport),
        };
        let remote = match remote {
            Ok(remote) => remote,
            Err(error) => {
                let _ = self.client.close_machine(connection_id);
                return Err(error);
            }
        };
        Ok((
            Session::Remote(remote),
            machine.display_name,
            Some(OpenConnection {
                client: self.client.clone(),
                connection_id,
                machine_id: machine.id,
            }),
        ))
    }

    fn create_workspace(
        &mut self,
        key: MachineKey,
        mode: protocol::WorkspaceCreateMode,
    ) -> anyhow::Result<()> {
        let result =
            self.client.create_workspace(self.machine_id(key)?, mode, self.next_mutation_id()?)?;
        self.set_notice(result.notice);
        self.refresh()
    }

    fn stage_connection(
        &mut self,
        candidate: Option<OpenConnection>,
        rollback: Option<ProviderSelectionRollback>,
    ) -> anyhow::Result<()> {
        if self.pending.is_some() {
            if let Some(candidate) = candidate {
                Self::close_connection(candidate);
            }
            if let Some(rollback) = rollback {
                self.restore_selection(rollback);
            }
            anyhow::bail!(localization::catalog().sidebar.machine_replacement_pending)
        }
        self.pending = Some(PendingConnection { candidate, rollback });
        Ok(())
    }

    fn commit_replacement(&mut self) -> anyhow::Result<()> {
        let pending = self.pending.take().ok_or_else(|| {
            anyhow::anyhow!(localization::catalog().sidebar.machine_replacement_not_pending)
        })?;
        self.close_open_connection();
        self.open = pending.candidate;
        Ok(())
    }

    fn abort_replacement(&mut self) {
        let Some(pending) = self.pending.take() else {
            return;
        };
        if let Some(candidate) = pending.candidate {
            Self::close_connection(candidate);
        }
        if let Some(rollback) = pending.rollback {
            self.restore_selection(rollback);
        }
    }

    fn restore_selection(&mut self, rollback: ProviderSelectionRollback) {
        self.snapshot.selected_machine_id = rollback.selected_machine_id;
        self.workspace_snapshot = rollback.workspace_snapshot;
    }

    fn close_connection(open: OpenConnection) {
        let _ = open.client.close_machine(open.connection_id);
    }

    fn close_open_connection(&mut self) {
        if let Some(open) = self.open.take() {
            Self::close_connection(open);
        }
    }

    fn machine_id(&self, key: MachineKey) -> anyhow::Result<protocol::OpaqueId> {
        self.keys
            .lock()
            .map_err(|_| anyhow::anyhow!("machine key registry is poisoned"))?
            .by_key
            .get(&key)
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("unknown machine {}", key.0))
    }

    fn next_mutation_id(&self) -> anyhow::Result<protocol::OpaqueId> {
        let sequence = self.mutation_sequence.fetch_add(1, Ordering::Relaxed);
        if sequence == u64::MAX {
            anyhow::bail!("machine-provider mutation sequence is exhausted");
        }
        Ok(protocol::OpaqueId::new(format!("cmux-{}-{sequence}", self.mutation_nonce))?)
    }

    fn reconcile_keys(&mut self) {
        reconcile_keys(&self.keys, &self.snapshot, &self.machine_lifecycle_snapshot);
    }

    fn ui_state(&self, session_available: bool) -> MachineUiState {
        machine_ui_state(
            &self.snapshot,
            &self.machine_lifecycle_snapshot,
            self.workspace_snapshot.as_ref(),
            &self.keys,
            session_available,
            self.client
                .supports_capability(protocol::EXTERNAL_MACHINE_CONNECT_CAPABILITY)
                .unwrap_or(false),
        )
    }

    fn ui_state_for_open_connection(&mut self) -> MachineUiState {
        let session_available = self.open.as_ref().is_some_and(|open| {
            self.snapshot.selected_machine_id.as_ref() == Some(&open.machine_id)
        });
        let mut ui = self.ui_state(session_available);
        ui.notice = self.notice.take();
        if !session_available
            && let Some(selected) = self.snapshot.selected_machine_id.as_ref()
            && self
                .snapshot
                .machines
                .iter()
                .any(|machine| &machine.id == selected && machine.connectable)
            && let Some(key) = key_for_id(&self.keys, selected)
        {
            ui.request = Some(MachineRequest::Switch(key));
        }
        ui
    }

    fn set_notice(&mut self, notice: Option<protocol::ProviderNotice>) {
        if let Some(notice) = notice {
            self.notice = Some(notice.message);
        }
    }
}

fn merge_local_machine_ui(
    mut ui: MachineUiState,
    local: &MachineSnapshot,
    active_local: Option<MachineKey>,
) -> MachineUiState {
    ui.snapshot.machines.extend(local.machines.iter().cloned());
    ui.snapshot.capabilities.connect |= local.capabilities.connect;
    if let Some(active) = active_local {
        ui.snapshot.active = Some(active);
        ui.session_available = true;
        // Provider selection changes are catalog updates while a local
        // session is active. Only an explicit user switch may replace it.
        if matches!(ui.request, Some(MachineRequest::Switch(_))) {
            ui.request = None;
        }
    }
    ui.selection = ui.snapshot.active_index().unwrap_or_default();
    ui
}

fn random_mutation_nonce() -> anyhow::Result<String> {
    let mut bytes = [0_u8; 16];
    getrandom::fill(&mut bytes)
        .map_err(|_| anyhow::anyhow!("cryptographic randomness is unavailable"))?;
    let mut encoded = String::with_capacity(bytes.len() * 2);
    for byte in &bytes {
        use std::fmt::Write as _;
        let _ = write!(encoded, "{byte:02x}");
    }
    bytes.zeroize();
    Ok(encoded)
}

impl MachineController for ProviderMachineRuntime {
    fn perform(&mut self, request: MachineRequest) -> anyhow::Result<MachineActionResult> {
        self.perform_request(request)
    }

    fn subscribe_updates(&self) -> anyhow::Result<Option<MachineUpdateStream>> {
        self.subscribe_ui_updates().map(Some)
    }

    fn commit_replacement(&mut self) -> anyhow::Result<()> {
        ProviderMachineRuntime::commit_replacement(self)
    }

    fn abort_replacement(&mut self) {
        ProviderMachineRuntime::abort_replacement(self);
    }

    fn close(&mut self) {
        ProviderMachineRuntime::close(self);
    }
}

fn connect_client(
    connector: Arc<dyn MachineProviderConnector>,
) -> anyhow::Result<(
    ProviderClient,
    protocol::SnapshotResult,
    protocol::MachineLifecycleSnapshotResult,
    Option<protocol::WorkspaceSnapshotResult>,
)> {
    let client_descriptor = protocol::ClientDescriptor {
        name: "cmux-tui".to_string(),
        version: env!("CARGO_PKG_VERSION").to_string(),
        supported_versions: vec![protocol::PROTOCOL_VERSION],
    };
    let (client, _hello) =
        ProviderClient::connect_authenticated_with(connector, client_descriptor)?;
    let snapshot = client.snapshot(None)?;
    let machine_lifecycle_snapshot = load_machine_lifecycle_snapshot(&client, &snapshot)?;
    let workspace_snapshot = load_workspace_snapshot(&client, &snapshot)?;
    Ok((client, snapshot, machine_lifecycle_snapshot, workspace_snapshot))
}

fn load_machine_lifecycle_snapshot(
    client: &ProviderClient,
    snapshot: &protocol::SnapshotResult,
) -> anyhow::Result<protocol::MachineLifecycleSnapshotResult> {
    if !client.supports_capability(protocol::MACHINE_LIFECYCLE_CAPABILITY)? {
        return Ok(protocol::MachineLifecycleSnapshotResult {
            revision: snapshot.revision,
            scope_id: snapshot.selected_scope_id.clone(),
            machines: Vec::new(),
        });
    }
    client.machine_lifecycle_snapshot(snapshot.selected_scope_id.clone(), None).map_err(Into::into)
}

fn load_workspace_snapshot(
    client: &ProviderClient,
    snapshot: &protocol::SnapshotResult,
) -> anyhow::Result<Option<protocol::WorkspaceSnapshotResult>> {
    if !client.supports_capability(protocol::WORKSPACE_LIFECYCLE_CAPABILITY)? {
        return Ok(None);
    }
    let Some(machine_id) = snapshot.selected_machine_id.as_ref() else {
        return Ok(None);
    };
    let Some(machine) = snapshot.machines.iter().find(|machine| &machine.id == machine_id) else {
        return Ok(None);
    };
    if !matches!(machine.workspace_create, protocol::WorkspaceCreatePolicy::Provider { .. }) {
        return Ok(None);
    }
    client.workspace_snapshot(machine_id.clone(), None).map(Some).map_err(Into::into)
}

impl Drop for ProviderMachineRuntime {
    fn drop(&mut self) {
        self.close();
    }
}

fn reconcile_keys(
    keys: &Arc<Mutex<KeyRegistry>>,
    snapshot: &protocol::SnapshotResult,
    machine_lifecycle_snapshot: &protocol::MachineLifecycleSnapshotResult,
) {
    let Ok(mut keys) = keys.lock() else { return };
    for machine_id in snapshot
        .machines
        .iter()
        .map(|machine| &machine.id)
        .chain(machine_lifecycle_snapshot.machines.iter().map(|machine| &machine.id))
    {
        if keys.by_id.contains_key(machine_id) {
            continue;
        }
        let key = MachineKey(keys.next);
        keys.next = keys.next.saturating_add(1);
        keys.by_id.insert(machine_id.clone(), key);
        keys.by_key.insert(key, machine_id.clone());
    }
}

fn key_for_id(keys: &Arc<Mutex<KeyRegistry>>, id: &protocol::OpaqueId) -> Option<MachineKey> {
    keys.lock().ok()?.by_id.get(id).copied()
}

fn machine_ui_state(
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

fn placeholder_session() -> Session {
    Session::Local(Mux::new(
        format!("provider-placeholder-{}", std::process::id()),
        SurfaceOptions::default(),
    ))
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

fn provider_presentation(snapshot: &protocol::SnapshotResult) -> ProviderPresentation {
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
            .map(|action| ProviderActionDescriptor {
                id: action.id.as_str().to_string(),
                label: action.label.clone(),
                destructive: action.destructive,
                fields: action
                    .fields
                    .iter()
                    .map(|field| ProviderActionFieldDescriptor {
                        id: field.id.clone(),
                        label: field.label.clone(),
                        kind: match field.kind {
                            protocol::ActionFieldKind::Text => ProviderActionFieldKind::Text,
                            protocol::ActionFieldKind::Email => ProviderActionFieldKind::Email,
                            protocol::ActionFieldKind::Integer => ProviderActionFieldKind::Integer,
                        },
                        required: field.required,
                        max_length: field.max_length,
                        minimum: field.minimum,
                        maximum: field.maximum,
                        placeholder: field.placeholder.clone(),
                    })
                    .collect(),
            })
            .collect(),
    }
}

#[cfg(test)]
mod tests {
    use std::io::{BufRead, BufReader, Write};
    use std::os::unix::net::{UnixListener, UnixStream};
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::mpsc;
    use std::thread;
    use std::time::Duration;

    use serde::Serialize;
    use serde::de::DeserializeOwned;
    use serde_json::{Value, json};

    use super::*;

    static NEXT_SOCKET_ID: AtomicU64 = AtomicU64::new(1);

    struct TestProviderSocket {
        path: PathBuf,
        listener: UnixListener,
    }

    impl TestProviderSocket {
        fn bind() -> Self {
            let id = NEXT_SOCKET_ID.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir()
                .join(format!("cmux-provider-runtime-{}-{id}.sock", std::process::id()));
            let _ = std::fs::remove_file(&path);
            let listener = UnixListener::bind(&path).unwrap();
            Self { path, listener }
        }

        fn listener(&self) -> UnixListener {
            self.listener.try_clone().unwrap()
        }
    }

    impl Drop for TestProviderSocket {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.path);
        }
    }

    fn id(value: &str) -> protocol::OpaqueId {
        protocol::OpaqueId::new(value).unwrap()
    }

    fn token() -> protocol::BearerToken {
        protocol::BearerToken::new("runtime-test-token").unwrap()
    }

    fn read_frame<T: DeserializeOwned>(reader: &mut BufReader<UnixStream>) -> T {
        let mut line = String::new();
        assert_ne!(reader.read_line(&mut line).unwrap(), 0, "provider client reached EOF");
        serde_json::from_str(&line).unwrap()
    }

    fn write_frame<T: Serialize>(stream: &mut UnixStream, frame: &T) {
        serde_json::to_writer(&mut *stream, frame).unwrap();
        stream.write_all(b"\n").unwrap();
        stream.flush().unwrap();
    }

    fn serve_initial_snapshot(
        listener: &UnixListener,
        snapshot: protocol::SnapshotResult,
    ) -> (UnixStream, BufReader<UnixStream>) {
        let (mut stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let hello: protocol::RequestEnvelope = read_frame(&mut reader);
        let protocol::ProviderRequest::Hello(params) = hello.request else {
            panic!("first provider request was not hello");
        };
        assert_eq!(params.token.expose(), "runtime-test-token");
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::success(
                hello.id,
                protocol::HelloResult {
                    provider_id: id("test-provider"),
                    provider_name: "Test Provider".into(),
                    negotiated_version: protocol::Version,
                },
            )
            .with_capabilities([
                protocol::MACHINE_LIFECYCLE_CAPABILITY,
                protocol::WORKSPACE_LIFECYCLE_CAPABILITY,
                protocol::WORKSPACE_MIRROR_AUTHORITY_CAPABILITY,
            ]),
        );

        let request: protocol::RequestEnvelope = read_frame(&mut reader);
        assert!(matches!(request.request, protocol::ProviderRequest::Snapshot(_)));
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::success(request.id, snapshot.clone()),
        );
        serve_machine_lifecycle_snapshot(&mut stream, &mut reader, &snapshot);
        (stream, reader)
    }

    fn machine_lifecycle_snapshot(
        snapshot: &protocol::SnapshotResult,
    ) -> protocol::MachineLifecycleSnapshotResult {
        protocol::MachineLifecycleSnapshotResult {
            revision: snapshot.revision,
            scope_id: snapshot.selected_scope_id.clone(),
            machines: snapshot
                .machines
                .iter()
                .map(|machine| protocol::MachineLifecycleDescriptor {
                    id: machine.id.clone(),
                    display_name: machine.display_name.clone(),
                    status: protocol::MachineLifecycleStatus::Active,
                    version: snapshot.revision,
                    recoverable_until: None,
                    capabilities: protocol::MachineLifecycleCapabilities {
                        rename: true,
                        delete: true,
                        restore: false,
                        purge: false,
                    },
                })
                .collect(),
        }
    }

    fn serve_machine_lifecycle_snapshot(
        stream: &mut UnixStream,
        reader: &mut BufReader<UnixStream>,
        snapshot: &protocol::SnapshotResult,
    ) {
        let request: protocol::RequestEnvelope = read_frame(reader);
        assert!(matches!(
            &request.request,
            protocol::ProviderRequest::MachineLifecycleSnapshot(params)
                if params.scope_id == snapshot.selected_scope_id
        ));
        write_frame(
            stream,
            &protocol::ResponseEnvelope::success(request.id, machine_lifecycle_snapshot(snapshot)),
        );
    }

    fn snapshot(
        revision: u64,
        machine_name: &str,
        status: protocol::MachineStatus,
    ) -> protocol::SnapshotResult {
        protocol::SnapshotResult {
            revision,
            scopes: vec![protocol::ScopeDescriptor {
                id: id("personal"),
                display_name: "Personal".into(),
                kind: protocol::ScopeKind::Personal,
                can_admin: false,
            }],
            selected_scope_id: id("personal"),
            machines: vec![protocol::MachineDescriptor {
                id: id("machine-1"),
                display_name: machine_name.into(),
                subtitle: "cloud".into(),
                status,
                connectable: false,
                workspace_create: protocol::WorkspaceCreatePolicy::Session,
            }],
            selected_machine_id: Some(id("machine-1")),
            capabilities: protocol::ProviderCapabilities {
                create_machine: true,
                connect_external_machine: false,
            },
            actions: vec![protocol::ProviderAction {
                id: id("billing"),
                label: format!("Billing revision {revision}"),
                destructive: false,
                fields: Vec::new(),
            }],
            notice: None,
        }
    }

    #[test]
    fn legacy_v1_provider_connects_without_receiving_lifecycle_requests() {
        let socket = TestProviderSocket::bind();
        let listener = socket.listener();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());

            let hello: protocol::RequestEnvelope = read_frame(&mut reader);
            assert!(matches!(hello.request, protocol::ProviderRequest::Hello(_)));
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::success(
                    hello.id,
                    protocol::HelloResult {
                        provider_id: id("legacy-provider"),
                        provider_name: "Legacy Provider".into(),
                        negotiated_version: protocol::Version,
                    },
                ),
            );

            let request: protocol::RequestEnvelope = read_frame(&mut reader);
            assert!(matches!(request.request, protocol::ProviderRequest::Snapshot(_)));
            let mut legacy_snapshot =
                snapshot(1, "Legacy machine", protocol::MachineStatus::Running);
            legacy_snapshot.machines[0].workspace_create =
                protocol::WorkspaceCreatePolicy::Provider {
                    default_mode: protocol::WorkspaceCreateMode::Isolated,
                    modes: vec![protocol::WorkspaceCreateMode::Isolated],
                };
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::success(request.id, legacy_snapshot),
            );

            stream.set_read_timeout(Some(Duration::from_millis(250))).unwrap();
            let mut unexpected = String::new();
            match reader.read_line(&mut unexpected) {
                Err(error)
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) => {}
                Ok(0) => panic!("provider client disconnected during legacy fallback"),
                Ok(_) => panic!("legacy provider received an unsupported request: {unexpected}"),
                Err(error) => panic!("legacy provider read failed: {error}"),
            }
        });

        let mut runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
        let ui = runtime.ui_state_for_open_connection();
        assert!(ui.managed_machines().is_empty());
        assert!(ui.managed_workspaces().is_empty());

        server.join().unwrap();
    }

    #[test]
    fn presentation_translation_preserves_provider_permissions_and_fields() {
        let snapshot = protocol::SnapshotResult {
            revision: 1,
            scopes: vec![protocol::ScopeDescriptor {
                id: id("team-1"),
                display_name: "Acme".into(),
                kind: protocol::ScopeKind::Team,
                can_admin: true,
            }],
            selected_scope_id: id("team-1"),
            machines: Vec::new(),
            selected_machine_id: None,
            capabilities: protocol::ProviderCapabilities {
                create_machine: true,
                connect_external_machine: false,
            },
            actions: vec![protocol::ProviderAction {
                id: id("invite"),
                label: "Invite member".into(),
                destructive: false,
                fields: vec![protocol::ActionField {
                    id: "email".into(),
                    kind: protocol::ActionFieldKind::Email,
                    label: "Email".into(),
                    required: true,
                    max_length: Some(254),
                    minimum: None,
                    maximum: None,
                    placeholder: Some("person@example.com".into()),
                }],
            }],
            notice: None,
        };

        let presentation = provider_presentation(&snapshot);
        assert!(presentation.scopes[0].can_admin);
        assert_eq!(presentation.selected_scope().unwrap().name, "Acme");
        assert_eq!(presentation.actions[0].fields[0].kind, ProviderActionFieldKind::Email);
    }

    #[test]
    fn provider_connect_footer_requires_negotiated_support() {
        let mut snapshot = snapshot(1, "Machine", protocol::MachineStatus::Running);
        snapshot.capabilities.connect_external_machine = true;
        let lifecycle = machine_lifecycle_snapshot(&snapshot);
        let keys = Arc::new(Mutex::new(KeyRegistry {
            by_id: HashMap::new(),
            by_key: HashMap::new(),
            next: 1,
        }));

        let ui = machine_ui_state(&snapshot, &lifecycle, None, &keys, true, false);

        assert!(
            !ui.snapshot.capabilities.connect,
            "a snapshot bit cannot expose an operation absent from hello negotiation"
        );

        let negotiated = machine_ui_state(&snapshot, &lifecycle, None, &keys, true, true);
        assert!(negotiated.snapshot.capabilities.connect);
    }

    #[test]
    fn local_overlay_appends_disjoint_machines_and_owns_active_session() {
        let snapshot = snapshot(1, "Cloud machine", protocol::MachineStatus::Running);
        let lifecycle = machine_lifecycle_snapshot(&snapshot);
        let keys = Arc::new(Mutex::new(KeyRegistry {
            by_id: HashMap::new(),
            by_key: HashMap::new(),
            next: 1,
        }));
        let mut provider = machine_ui_state(&snapshot, &lifecycle, None, &keys, false, false);
        let provider_key = provider.snapshot.active.unwrap();
        provider.request = Some(MachineRequest::Switch(provider_key));
        let local_key = MachineKey(crate::machine_runtime::CLIENT_MACHINE_KEY_START);
        let local = MachineSnapshot {
            machines: vec![MachineDescriptor {
                key: local_key,
                id: "mini".into(),
                name: "Mini".into(),
                subtitle: "local".into(),
                status: MachineStatus::Running,
            }],
            active: Some(local_key),
            capabilities: MachineCapabilities { create: false, connect: true },
        };

        let merged = merge_local_machine_ui(provider, &local, Some(local_key));

        assert_eq!(merged.snapshot.machines.len(), 2);
        assert_ne!(provider_key, local_key);
        assert_eq!(merged.snapshot.active, Some(local_key));
        assert_eq!(merged.selected().map(|machine| machine.key), Some(local_key));
        assert!(merged.snapshot.capabilities.connect);
        assert!(merged.session_available);
        assert!(merged.request.is_none(), "provider selection must not evict a local session");
        assert!(merged.provider.is_some(), "provider presentation remains available");
    }

    #[test]
    fn local_overlay_keeps_provider_reconnect_requests_without_losing_session() {
        let mut provider = MachineUiState::new(MachineSnapshot {
            machines: Vec::new(),
            active: None,
            capabilities: MachineCapabilities::default(),
        });
        provider.request = Some(MachineRequest::ReconnectProvider);
        let local_key = MachineKey(crate::machine_runtime::CLIENT_MACHINE_KEY_START);
        let local = MachineSnapshot {
            machines: vec![MachineDescriptor {
                key: local_key,
                id: "mini".into(),
                name: "Mini".into(),
                subtitle: "local".into(),
                status: MachineStatus::Running,
            }],
            active: Some(local_key),
            capabilities: MachineCapabilities::default(),
        };

        let merged = merge_local_machine_ui(provider, &local, Some(local_key));

        assert!(matches!(merged.request, Some(MachineRequest::ReconnectProvider)));
        assert!(merged.session_available);
    }

    #[test]
    fn provider_reconnect_replacement_commits_as_provider_active() {
        let socket = TestProviderSocket::bind();
        let listener = socket.listener();
        let (finish, finished) = mpsc::channel();
        let server = thread::spawn(move || {
            let (_first_stream, _first_reader) = serve_initial_snapshot(
                &listener,
                snapshot(1, "Before reconnect", protocol::MachineStatus::Running),
            );
            let mut disconnected =
                snapshot(2, "After reconnect", protocol::MachineStatus::Sleeping);
            disconnected.machines.clear();
            disconnected.selected_machine_id = None;
            let (_second_stream, _second_reader) = serve_initial_snapshot(&listener, disconnected);
            finished.recv_timeout(Duration::from_secs(2)).unwrap();
        });
        let connector = Arc::new(UnixProviderConnector::new(socket.path.clone(), token()));
        let mut controller =
            ProviderMachineController::connect_with(connector, Vec::new(), false).unwrap();

        let result = controller.perform_request(MachineRequest::ReconnectProvider).unwrap();
        assert!(result.replacement.is_some());
        let committed = controller.commit_replacement();

        controller.abort_replacement();
        controller.close();
        finish.send(()).unwrap();
        server.join().unwrap();
        assert!(committed.is_ok(), "provider replacement did not commit: {committed:?}");
        assert_eq!(controller.active_local, None);
    }

    #[test]
    fn deleting_open_managed_machine_restarts_updates_for_replacement() {
        let socket = TestProviderSocket::bind();
        let listener = socket.listener();
        let server = thread::spawn(move || {
            let initial = snapshot(1, "Before delete", protocol::MachineStatus::Running);
            let (mut stream, mut reader) = serve_initial_snapshot(&listener, initial);

            let refresh: protocol::RequestEnvelope = read_frame(&mut reader);
            assert!(matches!(refresh.request, protocol::ProviderRequest::Snapshot(_)));
            let refreshed = snapshot(2, "Before delete", protocol::MachineStatus::Running);
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::success(refresh.id, refreshed.clone()),
            );
            serve_machine_lifecycle_snapshot(&mut stream, &mut reader, &refreshed);

            let delete: protocol::RequestEnvelope = read_frame(&mut reader);
            assert!(matches!(
                &delete.request,
                protocol::ProviderRequest::DeleteMachine(params)
                    if params.machine_id == id("machine-1") && params.expected_version == 1
            ));
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::success(
                    delete.id,
                    protocol::MachineMutationResult {
                        machine_id: id("machine-1"),
                        version: 2,
                        revision: 3,
                        notice: None,
                    },
                ),
            );

            let post_delete: protocol::RequestEnvelope = read_frame(&mut reader);
            assert!(matches!(post_delete.request, protocol::ProviderRequest::Snapshot(_)));
            let mut deleted = snapshot(3, "Deleted", protocol::MachineStatus::Stopped);
            deleted.machines.clear();
            deleted.selected_machine_id = None;
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::success(post_delete.id, deleted.clone()),
            );
            serve_machine_lifecycle_snapshot(&mut stream, &mut reader, &deleted);

            let close: protocol::RequestEnvelope = read_frame(&mut reader);
            assert!(matches!(
                close.request,
                protocol::ProviderRequest::CloseMachine(params)
                    if params.connection_id == id("deleted-open")
            ));
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::success(
                    close.id,
                    protocol::CloseMachineResult { revision: 4 },
                ),
            );
        });
        let connector = Arc::new(UnixProviderConnector::new(socket.path.clone(), token()));
        let mut controller =
            ProviderMachineController::connect_with(connector, Vec::new(), false).unwrap();
        let machine = key_for_id(&controller.provider.keys, &id("machine-1")).unwrap();
        controller.provider.open = Some(OpenConnection {
            client: controller.provider.client.clone(),
            connection_id: id("deleted-open"),
            machine_id: id("machine-1"),
        });

        let result = controller
            .perform_request(MachineRequest::DeleteManagedMachine { machine, expected_version: 1 })
            .unwrap();

        assert!(result.replacement.is_some());
        assert!(result.restart_updates, "replacement retained the deleted machine update stream");
        controller.abort_replacement();
        drop(result);
        controller.close();
        server.join().unwrap();
    }

    #[test]
    fn local_overlay_switches_to_a_real_client_local_mux() {
        let provider_socket = TestProviderSocket::bind();
        let listener = provider_socket.listener();
        let (provider_stop, provider_stopped) = mpsc::channel();
        let provider_server = thread::spawn(move || {
            let _control = serve_initial_snapshot(
                &listener,
                snapshot(1, "Cloud machine", protocol::MachineStatus::Running),
            );
            provider_stopped.recv_timeout(Duration::from_secs(2)).unwrap();
        });
        let local_socket = std::env::temp_dir().join(format!(
            "cmux-local-overlay-{}-{}.sock",
            std::process::id(),
            NEXT_SOCKET_ID.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = std::fs::remove_file(&local_socket);
        let local_listener = UnixListener::bind(&local_socket).unwrap();
        let (local_stop, local_stopped) = mpsc::channel();
        let local_server = thread::spawn(move || {
            let (stream, _) = local_listener.accept().unwrap();
            let mut peer = BufReader::new(stream);
            for expected_command in ["identify", "set-client-info", "subscribe"] {
                let mut line = String::new();
                peer.read_line(&mut line).unwrap();
                let request: Value = serde_json::from_str(&line).unwrap();
                assert_eq!(request["cmd"], expected_command);
                let data = if expected_command == "identify" {
                    json!({
                        "app": "cmux-tui",
                        "protocol": cmux_tui_core::server::PROTOCOL_VERSION,
                    })
                } else {
                    Value::Null
                };
                writeln!(
                    peer.get_mut(),
                    "{}",
                    json!({"id": request["id"], "ok": true, "data": data})
                )
                .unwrap();
            }
            local_stopped.recv_timeout(Duration::from_secs(2)).unwrap();
        });
        let local = MachineRuntime::external(
            vec![
                MachineConfig {
                    id: "mini".into(),
                    name: "Mini".into(),
                    subtitle: "local".into(),
                    target: crate::config::MachineTargetConfig::Unix {
                        socket: local_socket.clone(),
                    },
                },
                MachineConfig {
                    id: "offline".into(),
                    name: "Offline".into(),
                    subtitle: "local".into(),
                    target: crate::config::MachineTargetConfig::Unix {
                        socket: local_socket.with_extension("missing"),
                    },
                },
            ],
            true,
        );
        let local_snapshot = local.snapshot_with_active(None);
        let local_key = local_snapshot.machines[0].key;
        let offline_key = local_snapshot.machines[1].key;
        let mut controller = ProviderMachineController {
            provider: ProviderMachineRuntime::connect(&provider_socket.path, token()).unwrap(),
            local,
            active_local: None,
            pending_active_local: None,
        };

        let result = controller.perform_request(MachineRequest::Switch(local_key)).unwrap();

        assert!(result.replacement.is_some());
        assert!(result.restart_updates);
        assert_eq!(result.ui.snapshot.active, Some(local_key));
        assert!(result.ui.session_available);
        assert_eq!(controller.active_local, None, "candidate is not active before commit");
        controller.commit_replacement().unwrap();
        assert_eq!(controller.active_local, Some(local_key));
        let failed = controller.perform_request(MachineRequest::Switch(offline_key));
        assert!(failed.is_err());
        assert_eq!(
            controller.active_local,
            Some(local_key),
            "a failed candidate must not evict the active session"
        );
        local_stop.send(()).unwrap();
        drop(result);
        controller.close();
        provider_stop.send(()).unwrap();
        provider_server.join().unwrap();
        local_server.join().unwrap();
        let _ = std::fs::remove_file(local_socket);
    }

    #[test]
    fn workspace_policy_translation_preserves_provider_order_and_default() {
        let mut snapshot = snapshot(1, "Machine", protocol::MachineStatus::Running);
        snapshot.machines[0].workspace_create = protocol::WorkspaceCreatePolicy::Provider {
            default_mode: protocol::WorkspaceCreateMode::Isolated,
            modes: vec![
                protocol::WorkspaceCreateMode::Host,
                protocol::WorkspaceCreateMode::Isolated,
            ],
        };
        let keys = Arc::new(Mutex::new(KeyRegistry {
            by_id: HashMap::new(),
            by_key: HashMap::new(),
            next: 1,
        }));

        let machine_lifecycle = machine_lifecycle_snapshot(&snapshot);
        let ui = machine_ui_state(&snapshot, &machine_lifecycle, None, &keys, true, false);

        assert_eq!(
            ui.workspace_creation_policy(),
            Some(WorkspaceCreationPolicy::ProviderOwned {
                default_mode: WorkspaceCreationMode::Isolated,
                modes: vec![WorkspaceCreationMode::Host, WorkspaceCreationMode::Isolated],
            })
        );
    }

    #[test]
    fn workspace_snapshot_translation_preserves_stable_identity_and_capabilities() {
        let mut snapshot = snapshot(1, "Machine", protocol::MachineStatus::Running);
        snapshot.machines[0].workspace_create = protocol::WorkspaceCreatePolicy::Provider {
            default_mode: protocol::WorkspaceCreateMode::Isolated,
            modes: vec![protocol::WorkspaceCreateMode::Isolated],
        };
        let lifecycle = protocol::WorkspaceSnapshotResult {
            revision: 9,
            machine_id: id("machine-1"),
            workspaces: vec![protocol::WorkspaceLifecycleDescriptor {
                id: id("workspace-uuid"),
                display_name: "recover me".into(),
                mode: protocol::WorkspaceCreateMode::Host,
                status: protocol::WorkspaceLifecycleStatus::Recoverable,
                version: 12,
                recoverable_until: Some("2030-01-02T03:04:05Z".into()),
                capabilities: protocol::WorkspaceLifecycleCapabilities {
                    rename: false,
                    delete: false,
                    restore: true,
                    purge: true,
                },
            }],
        };
        let keys = Arc::new(Mutex::new(KeyRegistry {
            by_id: HashMap::new(),
            by_key: HashMap::new(),
            next: 1,
        }));

        let machine_lifecycle = machine_lifecycle_snapshot(&snapshot);
        let ui =
            machine_ui_state(&snapshot, &machine_lifecycle, Some(&lifecycle), &keys, true, false);

        assert_eq!(
            ui.managed_workspaces(),
            &[ManagedWorkspaceDescriptor {
                id: "workspace-uuid".into(),
                name: "recover me".into(),
                mode: WorkspaceCreationMode::Host,
                status: ManagedWorkspaceStatus::Recoverable,
                version: 12,
                recoverable_until: Some("2030-01-02T03:04:05Z".into()),
                capabilities: ManagedWorkspaceCapabilities {
                    rename: false,
                    delete: false,
                    restore: true,
                    purge: true,
                },
            }]
        );
    }

    #[test]
    fn machine_lifecycle_translation_keeps_tombstone_identity_version_and_capabilities() {
        let snapshot = snapshot(1, "Machine", protocol::MachineStatus::Running);
        let mut lifecycle = machine_lifecycle_snapshot(&snapshot);
        lifecycle.machines.push(protocol::MachineLifecycleDescriptor {
            id: id("deleted-machine-uuid"),
            display_name: "quiet-forest".into(),
            status: protocol::MachineLifecycleStatus::Recoverable,
            version: 12,
            recoverable_until: Some("2030-01-02T03:04:05Z".into()),
            capabilities: protocol::MachineLifecycleCapabilities {
                rename: false,
                delete: false,
                restore: true,
                purge: true,
            },
        });
        let keys = Arc::new(Mutex::new(KeyRegistry {
            by_id: HashMap::new(),
            by_key: HashMap::new(),
            next: 1,
        }));

        let first = machine_ui_state(&snapshot, &lifecycle, None, &keys, true, false);
        let tombstone_key = first.snapshot.machines[1].key;
        assert_eq!(first.snapshot.machines[1].id, "deleted-machine-uuid");
        assert_eq!(
            first.managed_machine(tombstone_key),
            Some(&ManagedMachineDescriptor {
                key: tombstone_key,
                id: "deleted-machine-uuid".into(),
                name: "quiet-forest".into(),
                status: ManagedMachineStatus::Recoverable,
                version: 12,
                recoverable_until: Some("2030-01-02T03:04:05Z".into()),
                capabilities: ManagedMachineCapabilities {
                    rename: false,
                    delete: false,
                    restore: true,
                    purge: true,
                },
            })
        );

        lifecycle.machines[1].display_name = "renamed tombstone".into();
        lifecycle.machines[1].version = 13;
        let refreshed = machine_ui_state(&snapshot, &lifecycle, None, &keys, true, false);
        assert_eq!(refreshed.snapshot.machines[1].key, tombstone_key);
        assert_eq!(refreshed.managed_machine(tombstone_key).unwrap().version, 13);
    }

    #[test]
    fn switching_to_a_lifecycle_tombstone_disables_the_placeholder_session() {
        let socket = TestProviderSocket::bind();
        let listener = socket.listener();
        let catalog = snapshot(1, "Machine", protocol::MachineStatus::Running);
        let mut lifecycle = machine_lifecycle_snapshot(&catalog);
        lifecycle.machines.push(protocol::MachineLifecycleDescriptor {
            id: id("deleted-machine-uuid"),
            display_name: "quiet-forest".into(),
            status: protocol::MachineLifecycleStatus::Recoverable,
            version: 12,
            recoverable_until: Some("2030-01-02T03:04:05Z".into()),
            capabilities: protocol::MachineLifecycleCapabilities {
                rename: false,
                delete: false,
                restore: true,
                purge: true,
            },
        });
        let server_catalog = catalog;
        let server_lifecycle = lifecycle.clone();
        let (finish, finished) = mpsc::channel();
        let server = thread::spawn(move || {
            let (mut stream, mut reader) =
                serve_initial_snapshot(&listener, server_catalog.clone());

            let refresh: protocol::RequestEnvelope = read_frame(&mut reader);
            assert!(matches!(refresh.request, protocol::ProviderRequest::Snapshot(_)));
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::success(refresh.id, server_catalog),
            );

            let lifecycle_request: protocol::RequestEnvelope = read_frame(&mut reader);
            assert!(matches!(
                lifecycle_request.request,
                protocol::ProviderRequest::MachineLifecycleSnapshot(_)
            ));
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::success(lifecycle_request.id, server_lifecycle),
            );
            finished.recv().unwrap();
        });

        let mut runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
        runtime.machine_lifecycle_snapshot = lifecycle;
        runtime.reconcile_keys();
        let tombstone_key = key_for_id(&runtime.keys, &id("deleted-machine-uuid")).unwrap();

        let result = runtime.perform_request(MachineRequest::Switch(tombstone_key)).unwrap();

        assert!(result.replacement.is_some());
        assert_eq!(result.ui.snapshot.active, Some(tombstone_key));
        assert!(!result.ui.session_available);
        assert!(runtime.open.is_none());
        finish.send(()).unwrap();
        drop(result);
        drop(runtime);
        server.join().unwrap();
    }

    #[test]
    fn mutation_nonce_is_cryptographically_unique_and_pid_independent() {
        let first = random_mutation_nonce().unwrap();
        let second = random_mutation_nonce().unwrap();
        assert_eq!(first.len(), 32);
        assert!(first.bytes().all(|byte| byte.is_ascii_hexdigit()));
        assert_ne!(first, second);
        assert!(!first.contains(&std::process::id().to_string()));
    }

    #[test]
    fn healthy_provider_waits_for_a_selected_provisioning_machine() {
        let socket = TestProviderSocket::bind();
        let listener = socket.listener();
        let (finish, finished) = mpsc::channel();
        let server = thread::spawn(move || {
            let (_stream, _reader) = serve_initial_snapshot(
                &listener,
                snapshot(1, "Provisioning", protocol::MachineStatus::Connecting),
            );
            finished.recv().unwrap();
        });

        let mut runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
        let ui = runtime.ui_state_for_open_connection();
        assert!(!ui.session_available);
        assert!(ui.request.is_none());

        finish.send(()).unwrap();
        drop(runtime);
        server.join().unwrap();
    }

    #[test]
    fn non_switch_provider_action_preserves_the_open_machine_transport() {
        let socket = TestProviderSocket::bind();
        let listener = socket.listener();
        let server = thread::spawn(move || {
            let (mut stream, mut reader) = serve_initial_snapshot(
                &listener,
                snapshot(1, "Machine", protocol::MachineStatus::Running),
            );

            let refresh: protocol::RequestEnvelope = read_frame(&mut reader);
            assert!(matches!(refresh.request, protocol::ProviderRequest::Snapshot(_)));
            let refreshed = snapshot(2, "Machine", protocol::MachineStatus::Running);
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::success(refresh.id, refreshed.clone()),
            );
            serve_machine_lifecycle_snapshot(&mut stream, &mut reader, &refreshed);

            let select: protocol::RequestEnvelope = read_frame(&mut reader);
            assert!(matches!(
                &select.request,
                protocol::ProviderRequest::SelectScope(params)
                    if params.scope_id == id("personal")
            ));
            let selected = snapshot(3, "Machine", protocol::MachineStatus::Running);
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::success(
                    select.id,
                    protocol::SelectScopeResult { snapshot: selected.clone() },
                ),
            );
            serve_machine_lifecycle_snapshot(&mut stream, &mut reader, &selected);

            // The close must be the first request after the non-switch action
            // and is emitted only when the runtime is dropped below.
            let close: protocol::RequestEnvelope = read_frame(&mut reader);
            assert!(matches!(
                close.request,
                protocol::ProviderRequest::CloseMachine(params)
                    if params.connection_id == id("keep-open")
            ));
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::success(
                    close.id,
                    protocol::CloseMachineResult { revision: 4 },
                ),
            );
        });

        let mut runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
        runtime.open = Some(OpenConnection {
            client: runtime.client.clone(),
            connection_id: id("keep-open"),
            machine_id: id("machine-1"),
        });

        let result = runtime
            .perform_request(MachineRequest::SelectProviderScope("personal".into()))
            .unwrap();

        assert!(result.replacement.is_none());
        assert!(result.ui.session_available);
        assert_eq!(
            runtime.open.as_ref().map(|open| open.connection_id.as_str()),
            Some("keep-open")
        );
        drop(runtime);
        server.join().unwrap();
    }

    #[test]
    fn failed_candidate_open_preserves_the_current_machine_transport() {
        let socket = TestProviderSocket::bind();
        let listener = socket.listener();
        let mut catalog = snapshot(1, "First", protocol::MachineStatus::Running);
        catalog.machines[0].connectable = true;
        catalog.machines.push(protocol::MachineDescriptor {
            id: id("machine-2"),
            display_name: "Second".into(),
            subtitle: "cloud".into(),
            status: protocol::MachineStatus::Running,
            connectable: true,
            workspace_create: protocol::WorkspaceCreatePolicy::Session,
        });
        let server_catalog = catalog.clone();
        let server = thread::spawn(move || {
            let (mut stream, mut reader) =
                serve_initial_snapshot(&listener, server_catalog.clone());

            let refresh: protocol::RequestEnvelope = read_frame(&mut reader);
            assert!(matches!(refresh.request, protocol::ProviderRequest::Snapshot(_)));
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::success(refresh.id, server_catalog.clone()),
            );
            serve_machine_lifecycle_snapshot(&mut stream, &mut reader, &server_catalog);

            let open: protocol::RequestEnvelope = read_frame(&mut reader);
            assert!(matches!(
                &open.request,
                protocol::ProviderRequest::OpenMachine(params)
                    if params.machine_id == id("machine-2")
            ));
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::<protocol::OpenMachineResult>::failure(
                    open.id,
                    protocol::ProviderError {
                        code: protocol::ProviderErrorCode::Unavailable,
                        message: "candidate refused".into(),
                        retryable: true,
                    },
                ),
            );

            let close: protocol::RequestEnvelope = read_frame(&mut reader);
            assert!(matches!(
                close.request,
                protocol::ProviderRequest::CloseMachine(params)
                    if params.connection_id == id("keep-first-open")
            ));
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::success(
                    close.id,
                    protocol::CloseMachineResult { revision: 2 },
                ),
            );
        });

        let mut runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
        runtime.open = Some(OpenConnection {
            client: runtime.client.clone(),
            connection_id: id("keep-first-open"),
            machine_id: id("machine-1"),
        });
        let second = key_for_id(&runtime.keys, &id("machine-2")).unwrap();

        let Err(error) = runtime.perform_request(MachineRequest::Switch(second)) else {
            panic!("candidate open unexpectedly succeeded");
        };

        assert!(error.to_string().contains("candidate refused"));
        assert_eq!(runtime.snapshot.selected_machine_id, Some(id("machine-1")));
        assert_eq!(
            runtime.open.as_ref().map(|open| open.connection_id.as_str()),
            Some("keep-first-open")
        );
        drop(runtime);
        server.join().unwrap();
    }

    #[test]
    fn rejected_candidate_authority_preserves_the_current_transport_and_selection() {
        let socket = TestProviderSocket::bind();
        let listener = socket.listener();
        let mut catalog = snapshot(1, "First", protocol::MachineStatus::Running);
        catalog.machines.push(protocol::MachineDescriptor {
            id: id("machine-2"),
            display_name: "Second".into(),
            subtitle: "cloud".into(),
            status: protocol::MachineStatus::Running,
            connectable: true,
            workspace_create: protocol::WorkspaceCreatePolicy::Session,
        });
        let server_catalog = catalog.clone();
        let server = thread::spawn(move || {
            let (mut stream, mut reader) =
                serve_initial_snapshot(&listener, server_catalog.clone());

            let close_candidate: protocol::RequestEnvelope = read_frame(&mut reader);
            assert!(matches!(
                close_candidate.request,
                protocol::ProviderRequest::CloseMachine(params)
                    if params.connection_id == id("reject-second")
            ));
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::success(
                    close_candidate.id,
                    protocol::CloseMachineResult { revision: 2 },
                ),
            );

            let refresh: protocol::RequestEnvelope = read_frame(&mut reader);
            assert!(matches!(refresh.request, protocol::ProviderRequest::Snapshot(_)));
            let mut refreshed = server_catalog;
            refreshed.revision = 2;
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::success(refresh.id, refreshed.clone()),
            );
            serve_machine_lifecycle_snapshot(&mut stream, &mut reader, &refreshed);

            let close_current: protocol::RequestEnvelope = read_frame(&mut reader);
            assert!(matches!(
                close_current.request,
                protocol::ProviderRequest::CloseMachine(params)
                    if params.connection_id == id("keep-first-open")
            ));
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::success(
                    close_current.id,
                    protocol::CloseMachineResult { revision: 3 },
                ),
            );
        });

        let mut runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
        runtime.open = Some(OpenConnection {
            client: runtime.client.clone(),
            connection_id: id("keep-first-open"),
            machine_id: id("machine-1"),
        });
        let rollback = ProviderSelectionRollback {
            selected_machine_id: runtime.snapshot.selected_machine_id.clone(),
            workspace_snapshot: runtime.workspace_snapshot.clone(),
        };
        runtime.snapshot.selected_machine_id = Some(id("machine-2"));
        runtime.snapshot.machines[1].workspace_create = protocol::WorkspaceCreatePolicy::Provider {
            default_mode: protocol::WorkspaceCreateMode::Isolated,
            modes: vec![protocol::WorkspaceCreateMode::Isolated],
        };
        runtime
            .stage_connection(
                Some(OpenConnection {
                    client: runtime.client.clone(),
                    connection_id: id("reject-second"),
                    machine_id: id("machine-2"),
                }),
                Some(rollback),
            )
            .unwrap();
        let candidate = crate::session::test_remote_session_without_provider_authority();
        let candidate_ui = runtime.ui_state(true);

        let error =
            crate::machine::validate_machine_session(&candidate, &candidate_ui).unwrap_err();
        runtime.abort_replacement();

        assert!(error.to_string().contains("did not supply workspace mirror authority"));
        assert_eq!(runtime.snapshot.selected_machine_id, Some(id("machine-1")));
        assert_eq!(
            runtime.open.as_ref().map(|open| open.connection_id.as_str()),
            Some("keep-first-open")
        );
        runtime.refresh().expect("provider control connection remains usable");
        drop(runtime);
        server.join().unwrap();
    }

    #[test]
    fn snapshot_event_replaces_dynamic_ui_with_stable_machine_key() {
        let socket = TestProviderSocket::bind();
        let listener = socket.listener();
        let (trigger, triggered) = mpsc::channel();
        let (finish, finished) = mpsc::channel();
        let server = thread::spawn(move || {
            let (mut stream, mut reader) = serve_initial_snapshot(
                &listener,
                snapshot(1, "First name", protocol::MachineStatus::Running),
            );
            triggered.recv().unwrap();
            write_frame(
                &mut stream,
                &protocol::EventEnvelope::new(protocol::ProviderEvent::SnapshotChanged(
                    protocol::SnapshotChangedEvent { revision: 2 },
                )),
            );
            let request: protocol::RequestEnvelope = read_frame(&mut reader);
            let protocol::ProviderRequest::Snapshot(params) = request.request else {
                panic!("snapshot event did not trigger a snapshot request");
            };
            assert_eq!(params.known_revision, Some(1));
            let refreshed = snapshot(2, "Renamed machine", protocol::MachineStatus::Sleeping);
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::success(request.id, refreshed.clone()),
            );
            serve_machine_lifecycle_snapshot(&mut stream, &mut reader, &refreshed);
            finished.recv().unwrap();
        });

        let runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
        let original_key = key_for_id(&runtime.keys, &id("machine-1")).unwrap();
        let updates = runtime.subscribe_ui_updates().unwrap();
        let (receiver, stop, worker) = updates.into_parts();
        trigger.send(()).unwrap();

        let update = receiver.recv_timeout(Duration::from_secs(2)).unwrap();
        assert_eq!(update.snapshot.active, Some(original_key));
        assert_eq!(update.snapshot.machines[0].key, original_key);
        assert_eq!(update.snapshot.machines[0].name, "Renamed machine");
        assert_eq!(update.snapshot.machines[0].status, MachineStatus::Sleeping);
        assert_eq!(update.provider.as_ref().unwrap().actions[0].label, "Billing revision 2");
        assert!(!update.session_available);
        assert!(update.request.is_none());

        stop.store(true, Ordering::Release);
        drop(receiver);
        worker.join().unwrap();
        finish.send(()).unwrap();
        drop(runtime);
        server.join().unwrap();
    }

    #[test]
    fn provider_eof_requests_and_completes_a_fresh_authenticated_connection() {
        let socket = TestProviderSocket::bind();
        let listener = socket.listener();
        let (disconnect, disconnect_now) = mpsc::channel();
        let (finish, finished) = mpsc::channel();
        let server = thread::spawn(move || {
            let (first_stream, first_reader) = serve_initial_snapshot(
                &listener,
                snapshot(1, "Before restart", protocol::MachineStatus::Running),
            );
            disconnect_now.recv().unwrap();
            drop(first_reader);
            drop(first_stream);

            let (_second_stream, _second_reader) = serve_initial_snapshot(
                &listener,
                snapshot(2, "After restart", protocol::MachineStatus::Sleeping),
            );
            finished.recv().unwrap();
        });

        let mut runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
        let updates = runtime.subscribe_ui_updates().unwrap();
        let (receiver, stop, worker) = updates.into_parts();
        disconnect.send(()).unwrap();

        let update = receiver.recv_timeout(Duration::from_secs(2)).unwrap();
        assert_eq!(update.request, Some(MachineRequest::ReconnectProvider));
        assert_eq!(
            update.notice.as_deref(),
            Some(localization::catalog().sidebar.machine_provider_disconnected)
        );
        stop.store(true, Ordering::Release);
        drop(receiver);
        worker.join().unwrap();

        runtime.perform_request(MachineRequest::ReconnectProvider).unwrap();
        assert_eq!(runtime.snapshot.revision, 2);
        let ui = runtime.ui_state(false);
        assert_eq!(ui.snapshot.machines[0].name, "After restart");
        assert_eq!(ui.snapshot.machines[0].status, MachineStatus::Sleeping);

        finish.send(()).unwrap();
        drop(runtime);
        server.join().unwrap();
    }
}

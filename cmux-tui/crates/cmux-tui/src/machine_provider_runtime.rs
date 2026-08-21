//! Dynamic machine catalog backed by a versioned external provider.

use std::collections::{BTreeMap, HashMap, HashSet};
#[cfg(test)]
use std::path::Path;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::time::Duration;

use cmux_tui_core::{Mux, SurfaceOptions};
use cmux_tui_machine_protocol as protocol;
use zeroize::Zeroize;

use crate::config::MachineConfig;
use crate::localization;
use crate::machine::{
    DurableNoticeDelivery, DurableNoticeLevel, DurableProviderNotice, MachineActionResult,
    MachineCapabilities, MachineConnectRoute, MachineController, MachineDescriptor, MachineKey,
    MachineRequest, MachineSnapshot, MachineStatus, MachineUiState, MachineUpdate,
    MachineUpdateStream, ManagedMachineCapabilities, ManagedMachineDescriptor,
    ManagedMachineStatus, ManagedWorkspaceCapabilities, ManagedWorkspaceDescriptor,
    ManagedWorkspaceSessionMutation, ManagedWorkspaceStatus, ProviderActionDescriptor,
    ProviderActionFieldDescriptor, ProviderActionFieldKind, ProviderActionTarget,
    ProviderActionValue, ProviderPresentation, ProviderScopeDescriptor, ProviderScopeKind,
    WorkspaceCreationMode, WorkspaceCreationPolicy,
};
#[cfg(test)]
use crate::machine_provider_client::UnixProviderConnector;
use crate::machine_provider_client::{
    MachineProviderConnector, ProviderClient, ProviderClientError,
};
use crate::machine_runtime::{
    MachineConnectFn, MachineConnection, MachineConnectionHub, MachineRuntime,
};
use crate::session::{RemoteSession, Session};

const PROVIDER_REFRESH_QUEUE_CAPACITY: usize = 64;

#[derive(Clone)]
struct OpenConnection {
    client: Arc<ProviderClient>,
    connection_id: protocol::OpaqueId,
    machine_id: protocol::OpaqueId,
}

struct ProviderMachineConnectionLease {
    open: OpenConnection,
    key: MachineKey,
    registry: Arc<Mutex<HashMap<MachineKey, OpenConnection>>>,
}

impl Drop for ProviderMachineConnectionLease {
    fn drop(&mut self) {
        if let Ok(mut registry) = self.registry.lock()
            && registry
                .get(&self.key)
                .is_some_and(|open| open.connection_id == self.open.connection_id)
        {
            registry.remove(&self.key);
        }
        let _ = self.open.client.close_machine(self.open.connection_id.clone());
    }
}

struct ProviderSelectionRollback {
    selected_machine_id: Option<protocol::OpaqueId>,
    workspace_snapshot: Option<protocol::WorkspaceSnapshotResult>,
}

struct PendingConnection {
    candidate: Option<OpenConnection>,
    rollback: Option<ProviderSelectionRollback>,
    retire_open_on_abort: bool,
}

struct PendingExternalConnect {
    scope_id: protocol::OpaqueId,
    specifier: protocol::ExternalMachineSpecifier,
    mutation_id: protocol::OpaqueId,
}

#[derive(Clone)]
struct AcceptedSelectionIntent {
    scope_id: Option<protocol::OpaqueId>,
    machine_id: Option<protocol::OpaqueId>,
}

#[derive(Default)]
struct AcceptedProviderEffects {
    session_mutation: Option<ManagedWorkspaceSessionMutation>,
    session_label: Option<String>,
    retire_open_on_failure: bool,
    restart_updates: bool,
}

#[derive(Debug)]
enum ProviderRefreshSignal {
    Refresh(Option<protocol::ProviderEvent>),
    Disconnected,
}

struct KeyRegistry {
    by_id: HashMap<protocol::OpaqueId, MachineKey>,
    by_key: HashMap<MachineKey, protocol::OpaqueId>,
    next: u64,
}

enum ProviderNoticeIdentity {
    #[cfg(test)]
    Ephemeral(protocol::OpaqueId),
    Persisted {
        state_root: Option<PathBuf>,
        lease: Option<crate::provider_notice_identity::ProviderNoticeIdentityLease>,
    },
}

impl ProviderNoticeIdentity {
    fn consumer_id(&mut self) -> anyhow::Result<&protocol::OpaqueId> {
        match self {
            #[cfg(test)]
            Self::Ephemeral(consumer_id) => Ok(consumer_id),
            Self::Persisted { state_root, lease } => {
                if lease.is_none() {
                    let message =
                        localization::catalog().sidebar.provider_notice_identity_unavailable;
                    let state_root = state_root.as_deref().ok_or_else(|| {
                        anyhow::anyhow!("cannot determine durable state directory").context(message)
                    })?;
                    let acquired =
                        crate::provider_notice_identity::acquire(state_root).map_err(|error| {
                            let message = if error
                                .downcast_ref::<crate::provider_notice_identity::ProviderNoticeIdentityInUse>()
                                .is_some()
                            {
                                localization::catalog()
                                    .sidebar
                                    .provider_connection_already_running
                            } else {
                                localization::catalog()
                                    .sidebar
                                    .provider_notice_identity_unavailable
                            };
                            error.context(message)
                        })?;
                    *lease = Some(acquired);
                }
                Ok(lease.as_ref().expect("notice identity lease was initialized").consumer_id())
            }
        }
    }

    #[cfg(test)]
    fn acquired_consumer_id(&self) -> Option<&protocol::OpaqueId> {
        match self {
            Self::Ephemeral(consumer_id) => Some(consumer_id),
            Self::Persisted { lease, .. } => lease.as_ref().map(|identity| identity.consumer_id()),
        }
    }
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
    connections: MachineConnectionHub,
    connection_registry: Arc<Mutex<HashMap<MachineKey, OpenConnection>>>,
    pending: Option<PendingConnection>,
    pending_external_connect: Option<PendingExternalConnect>,
    accepted_selection: Option<AcceptedSelectionIntent>,
    last_snapshot_notice: Option<protocol::ProviderNotice>,
    pending_notice_messages: HashSet<String>,
    notice: Option<String>,
    notice_identity: ProviderNoticeIdentity,
}

/// Composes a provider-owned catalog with client-local socket and SSH targets.
/// The provider never receives local target names, credentials, or lifecycle
/// requests. Native provider processes can omit this wrapper entirely.
pub(crate) struct ProviderMachineController {
    provider: ProviderMachineRuntime,
    local: MachineRuntime,
    active_local: Option<MachineKey>,
    local_connections: MachineConnectionHub,
    pending_active_local: Option<Option<MachineKey>>,
    pending_provider_switch: bool,
}

impl ProviderMachineController {
    #[cfg(test)]
    fn for_test(
        provider: ProviderMachineRuntime,
        local: MachineRuntime,
        active_local: Option<MachineKey>,
        pending_provider_switch: bool,
    ) -> Self {
        let local_connections = MachineConnectionHub::new(local.connection_connectors());
        Self {
            provider,
            local,
            active_local,
            local_connections,
            pending_active_local: None,
            pending_provider_switch,
        }
    }

    pub(crate) fn connect_with(
        connector: Arc<dyn MachineProviderConnector>,
        configured: Vec<MachineConfig>,
        connect_external: bool,
        state_root: Option<PathBuf>,
    ) -> anyhow::Result<Self> {
        let local = MachineRuntime::external(configured, connect_external);
        let local_connections = MachineConnectionHub::new(local.connection_connectors());
        Ok(Self {
            provider: ProviderMachineRuntime::connect_with(connector, state_root)?,
            local,
            active_local: None,
            local_connections,
            pending_active_local: None,
            pending_provider_switch: false,
        })
    }

    pub(crate) fn open_selected(&mut self) -> anyhow::Result<(Session, String, MachineUiState)> {
        let (session, label, ui) = self.provider.open_selected()?;
        Ok((session, label, self.merge_local_ui(ui)))
    }

    pub(crate) fn sync_connections(&self) {
        self.provider.sync_connections();
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
            MachineRequest::Connect { target, route: MachineConnectRoute::Provider } => {
                let result = self.provider.perform_external_connect(target)?;
                self.pending_provider_switch = true;
                Ok(self.finish_provider_result(true, result))
            }
            MachineRequest::Connect { target, route: MachineConnectRoute::Local } => {
                let key = self.local.connect_machine(&target)?;
                self.register_local(key)?;
                self.switch_local(key)
            }
            MachineRequest::RenameClientMachine { machine, name }
                if self.local.contains(machine) =>
            {
                let name = self.local.rename_machine(machine, &name)?;
                let ui = self.provider.ui_state_for_open_connection();
                let mut result = MachineActionResult::ui(self.merge_local_ui(ui));
                // Provider update streams capture the local overlay at
                // subscription time. Replace that capture before a later
                // provider refresh can restore the old display name.
                result.restart_updates = true;
                Ok(if self.active_local == Some(machine) {
                    result.with_session_label(name)
                } else {
                    result
                })
            }
            MachineRequest::Switch(key) if self.local.contains(key) => self.switch_local(key),
            MachineRequest::ReconnectProvider if self.active_local.is_some() => {
                let switching_provider = self.pending_provider_switch;
                self.provider.reconnect_control()?;
                let ui = self.provider.ui_state_for_open_connection();
                let mut result = MachineActionResult::ui(ui);
                result.restart_updates = true;
                Ok(self.finish_provider_result(switching_provider, result))
            }
            request => {
                let switching_provider = matches!(request, MachineRequest::Switch(_));
                let result = self.provider.perform_request(request)?;
                Ok(self.finish_provider_result(switching_provider, result))
            }
        }
    }

    fn finish_provider_result(
        &mut self,
        switching_provider: bool,
        mut result: MachineActionResult,
    ) -> MachineActionResult {
        let explicit_provider_switch = switching_provider
            .then(|| result.ui.request.clone())
            .flatten()
            .filter(|request| matches!(request, MachineRequest::Switch(_)));
        if result.replacement.is_some() && (switching_provider || self.active_local.is_none()) {
            self.pending_active_local = Some(None);
            // Update streams capture the connected machine at subscription time.
            result.restart_updates = true;
            result.ui = self.merge_local_ui_for(result.ui, None);
        } else if switching_provider && explicit_provider_switch.is_some() {
            // An accepted provider enrollment selects its provider-owned
            // machine before the generated Switch request opens it. Preserve
            // that explicit intent instead of reasserting the active local row.
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
        if let Some(request) = explicit_provider_switch {
            result.ui.request = Some(request);
        }
        result
    }

    fn switch_local(&mut self, key: MachineKey) -> anyhow::Result<MachineActionResult> {
        // Open the candidate first. Failed SSH or socket authentication leaves
        // the current provider/local session untouched.
        self.register_local(key)?;
        let (session, reused) = self.local_connections.connect_tracked(key)?;
        let label = self.local.name(key).unwrap_or("machine").to_string();
        self.provider.stage_connection(None, None)?;
        self.pending_active_local = Some(Some(key));
        let ui = self.provider.ui_state_for_open_connection();
        let mut result =
            MachineActionResult::replace(self.merge_local_ui_for(ui, Some(key)), session, label)
                .with_reused_session(reused);
        result.restart_updates = true;
        Ok(result)
    }

    fn merge_local_ui(&self, ui: MachineUiState) -> MachineUiState {
        merge_local_machine_ui_for_provider_switch(
            ui,
            &self.local_ui(self.active_local),
            self.active_local,
            self.pending_provider_switch,
        )
    }

    fn merge_local_ui_for(
        &self,
        ui: MachineUiState,
        active_local: Option<MachineKey>,
    ) -> MachineUiState {
        merge_local_machine_ui(ui, &self.local_ui(active_local), active_local)
    }

    fn subscribe_ui_updates(&self) -> anyhow::Result<MachineUpdateStream> {
        let provider_updates = self.provider.subscribe_ui_updates()?;
        let (provider_receiver, provider_stop, provider_worker) = provider_updates.into_parts();
        let local_ui = self.local_ui(self.active_local);
        let active_local = self.active_local;
        let pending_provider_switch = self.pending_provider_switch;
        let stop = Arc::new(AtomicBool::new(false));
        let worker_stop = stop.clone();
        let (sender, receiver) = mpsc::sync_channel(8);
        let worker =
            std::thread::Builder::new().name("machine-local-overlay".into()).spawn(move || {
                while !worker_stop.load(Ordering::Acquire) {
                    match provider_receiver.recv_timeout(Duration::from_millis(250)) {
                        Ok(update) => {
                            let update = match update {
                                MachineUpdate::Ui(ui) => MachineUpdate::Ui(Box::new(
                                    merge_local_machine_ui_for_provider_switch(
                                        *ui,
                                        &local_ui,
                                        active_local,
                                        pending_provider_switch,
                                    ),
                                )),
                                MachineUpdate::DurableNotice(notice) => {
                                    MachineUpdate::DurableNotice(notice)
                                }
                                MachineUpdate::ConnectionProgress { machine_id, latest } => {
                                    MachineUpdate::ConnectionProgress { machine_id, latest }
                                }
                            };
                            if sender.send(update).is_err() {
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
        self.local_connections.close();
    }

    fn commit_replacement(&mut self, present: bool) -> anyhow::Result<()> {
        if !present {
            self.provider.commit_replacement(false)?;
            self.pending_active_local = None;
            return Ok(());
        }
        let active_local = self.pending_active_local.as_ref().copied().ok_or_else(|| {
            anyhow::anyhow!(localization::catalog().sidebar.machine_replacement_target_missing)
        })?;
        self.provider.commit_replacement(true)?;
        self.pending_active_local.take();
        self.active_local = active_local;
        self.local_connections.note_presented(active_local);
        self.pending_provider_switch = false;
        Ok(())
    }

    fn abort_replacement(&mut self) {
        self.provider.abort_replacement();
        if let Some(Some(machine)) = self.pending_active_local.take()
            && self.active_local != Some(machine)
        {
            self.local_connections.remove(machine);
        }
    }

    fn register_local(&self, machine: MachineKey) -> anyhow::Result<()> {
        let connector = self.local.connection_connector(machine).ok_or_else(|| {
            anyhow::anyhow!(localization::catalog().sidebar.client_machine_unavailable)
        })?;
        self.local_connections.register(machine, connector);
        Ok(())
    }

    fn local_ui(&self, active: Option<MachineKey>) -> MachineUiState {
        let mut ui = self.local.ui_state_with_active(active);
        ui.set_connection_phases(self.local_connections.phases());
        ui
    }
}

impl MachineController for ProviderMachineController {
    fn perform(&mut self, request: MachineRequest) -> anyhow::Result<MachineActionResult> {
        self.perform_request(request)
    }

    fn subscribe_updates(&self) -> anyhow::Result<Option<MachineUpdateStream>> {
        self.subscribe_ui_updates().map(Some)
    }

    fn acknowledge_durable_notice(
        &mut self,
        delivery: &DurableNoticeDelivery,
    ) -> anyhow::Result<()> {
        self.provider.acknowledge_durable_notice(delivery)
    }

    fn commit_replacement(&mut self, present: bool) -> anyhow::Result<()> {
        ProviderMachineController::commit_replacement(self, present)
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
        Self::connect_with_notice_identity(
            Arc::new(UnixProviderConnector::new(socket_path.as_ref().to_path_buf(), token)),
            ProviderNoticeIdentity::Ephemeral(random_notice_consumer_id()?),
        )
    }

    pub(crate) fn connect_with(
        connector: Arc<dyn MachineProviderConnector>,
        state_root: Option<PathBuf>,
    ) -> anyhow::Result<Self> {
        Self::connect_with_notice_identity(
            connector,
            ProviderNoticeIdentity::Persisted { state_root, lease: None },
        )
    }

    #[cfg(test)]
    fn connect_in_state_root(
        socket_path: impl AsRef<Path>,
        token: protocol::BearerToken,
        state_root: &Path,
    ) -> anyhow::Result<Self> {
        Self::connect_with(
            Arc::new(UnixProviderConnector::new(socket_path.as_ref().to_path_buf(), token)),
            Some(state_root.to_path_buf()),
        )
    }

    #[cfg(test)]
    fn connect_without_state_root(
        socket_path: impl AsRef<Path>,
        token: protocol::BearerToken,
    ) -> anyhow::Result<Self> {
        Self::connect_with(
            Arc::new(UnixProviderConnector::new(socket_path.as_ref().to_path_buf(), token)),
            None,
        )
    }

    fn connect_with_notice_identity(
        connector: Arc<dyn MachineProviderConnector>,
        mut notice_identity: ProviderNoticeIdentity,
    ) -> anyhow::Result<Self> {
        let (client, snapshot, machine_lifecycle_snapshot, workspace_snapshot) =
            connect_client(Arc::clone(&connector), &mut notice_identity)?;
        let client = Arc::new(client);
        let surface_initial_snapshot_notice = !client.has_retained_durable_notices()?;
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
            connections: MachineConnectionHub::new(std::iter::empty::<(
                MachineKey,
                MachineConnectFn,
            )>()),
            connection_registry: Arc::new(Mutex::new(HashMap::new())),
            pending: None,
            pending_external_connect: None,
            accepted_selection: None,
            last_snapshot_notice: None,
            pending_notice_messages: HashSet::new(),
            notice: None,
            notice_identity,
        };
        runtime.observe_snapshot_notice(
            runtime.snapshot.notice.clone(),
            surface_initial_snapshot_notice,
        );
        runtime.reconcile_keys();
        runtime.sync_connection_hub();
        Ok(runtime)
    }

    pub(crate) fn refresh(&mut self) -> anyhow::Result<()> {
        let (mut desired_scope_id, mut desired_machine_id) = self.desired_selection();
        let snapshot = load_snapshot_for_selection(
            &self.client,
            Some(self.snapshot.revision),
            &self.snapshot.selected_scope_id,
            &mut desired_scope_id,
            &mut desired_machine_id,
        )?;
        self.install_snapshot(snapshot)
    }

    fn install_snapshot(&mut self, mut snapshot: protocol::SnapshotResult) -> anyhow::Result<()> {
        let surface_snapshot_notice =
            !self.client.supports_capability(protocol::DURABLE_NOTICES_CAPABILITY)?;
        self.observe_snapshot_notice(snapshot.notice.clone(), surface_snapshot_notice);
        let selection_applied = self.accepted_selection.as_ref().is_none_or(|intent| {
            let scope_matches = intent
                .scope_id
                .as_ref()
                .is_none_or(|scope_id| scope_id == &snapshot.selected_scope_id);
            let machine_matches = intent.machine_id.as_ref().is_none_or(|machine_id| {
                if snapshot.machines.iter().any(|machine| &machine.id == machine_id) {
                    snapshot.selected_machine_id = Some(machine_id.clone());
                    true
                } else {
                    false
                }
            });
            scope_matches && machine_matches
        });
        let machine_lifecycle_snapshot = load_machine_lifecycle_snapshot(&self.client, &snapshot)?;
        let workspace_snapshot = load_workspace_snapshot(&self.client, &snapshot)?;
        self.snapshot = snapshot;
        self.machine_lifecycle_snapshot = machine_lifecycle_snapshot;
        self.workspace_snapshot = workspace_snapshot;
        if selection_applied {
            self.accepted_selection = None;
        }
        self.reconcile_keys();
        self.sync_connection_hub();
        Ok(())
    }

    pub(crate) fn open_selected(&mut self) -> anyhow::Result<(Session, String, MachineUiState)> {
        let (session, label, open, _reused) = self.open_selected_candidate()?;
        let session_available = open.is_some();
        self.open = open;
        // The initial connection is presented without a commit_replacement
        // round; record it so warm-pool eviction never shuts down the
        // session on screen.
        let presented =
            self.open.as_ref().and_then(|open| key_for_id(&self.keys, &open.machine_id));
        self.connections.note_presented(presented);
        let mut ui = self.ui_state(session_available);
        ui.notice = self.take_notice();
        Ok((session, label, ui))
    }

    pub(crate) fn placeholder(
        &mut self,
        notice: impl Into<String>,
    ) -> (Session, String, MachineUiState) {
        self.open = None;
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
                let (session, label, open, reused) = match self.open_selected_candidate() {
                    Ok(candidate) => candidate,
                    Err(error) => {
                        self.restore_selection(rollback);
                        return Err(error);
                    }
                };
                let session_available = open.is_some();
                self.stage_connection(open, Some(rollback))?;
                let mut ui = self.ui_state(session_available);
                ui.notice = self.take_notice();
                let mut result = MachineActionResult::replace(ui, session, label)
                    .with_reused_session(reused && session_available);
                result.restart_updates = true;
                Ok(result)
            }
            MachineRequest::Create => {
                let created = self.client.create_machine(
                    self.snapshot.selected_scope_id.clone(),
                    self.next_mutation_id()?,
                )?;
                Ok(self.finish_accepted_machine_selection(created.machine_id, created.notice))
            }
            MachineRequest::CreateFrom { .. } => {
                anyhow::bail!(localization::catalog().sidebar.machine_creation_source_unavailable)
            }
            MachineRequest::Connect { .. } => {
                unreachable!("external connect requests are routed by ProviderMachineController")
            }
            MachineRequest::SelectProviderScope(scope_id) => {
                let selected =
                    self.client.select_scope(protocol::OpaqueId::new(scope_id)?)?.snapshot;
                self.accept_selection_intent(AcceptedSelectionIntent {
                    scope_id: Some(selected.selected_scope_id.clone()),
                    machine_id: None,
                });
                Ok(self.finish_accepted_action(
                    AcceptedProviderEffects {
                        restart_updates: true,
                        ..AcceptedProviderEffects::default()
                    },
                    move |runtime| {
                        runtime.install_snapshot(selected)?;
                        Ok(MachineActionResult::ui(runtime.ui_state_for_open_connection()))
                    },
                ))
            }
            MachineRequest::InvokeProviderAction {
                action_id,
                values,
                machine_id,
                workspace_id,
            } => {
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
                    machine_id.map(protocol::OpaqueId::new).transpose()?,
                    workspace_id.map(protocol::OpaqueId::new).transpose()?,
                    self.next_mutation_id()?,
                )?;
                let selected_scope_id = result.selected_scope_id;
                let selected_machine_id = result.selected_machine_id;
                self.set_notice(result.notice);
                if let Some(url) = result.url {
                    self.push_notice(format!(
                        "{} {url}",
                        localization::catalog().sidebar.provider_action_open_url
                    ));
                }
                let restarts_updates = selected_scope_id.is_some() || selected_machine_id.is_some();
                if restarts_updates {
                    self.accept_selection_intent(AcceptedSelectionIntent {
                        scope_id: selected_scope_id,
                        machine_id: selected_machine_id,
                    });
                }
                Ok(self.finish_accepted_action(
                    AcceptedProviderEffects {
                        restart_updates: restarts_updates,
                        ..AcceptedProviderEffects::default()
                    },
                    |runtime| {
                        runtime.refresh()?;
                        Ok(MachineActionResult::ui(runtime.ui_state_for_open_connection()))
                    },
                ))
            }
            MachineRequest::RenameManagedMachine { machine, expected_version, name } => {
                let machine_id = self.machine_id(machine)?;
                let renames_open_session =
                    self.open.as_ref().is_some_and(|open| open.machine_id == machine_id);
                let session_label = renames_open_session.then(|| name.clone());
                let result = self.client.rename_machine(protocol::RenameMachineParams {
                    scope_id: self.snapshot.selected_scope_id.clone(),
                    machine_id,
                    expected_version,
                    display_name: name,
                    mutation_id: self.next_mutation_id()?,
                })?;
                self.set_notice(result.notice);
                Ok(self.finish_accepted_action(
                    AcceptedProviderEffects { session_label, ..AcceptedProviderEffects::default() },
                    |runtime| {
                        runtime.refresh()?;
                        Ok(MachineActionResult::ui(runtime.ui_state_for_open_connection()))
                    },
                ))
            }
            MachineRequest::RenameClientMachine { .. } => {
                anyhow::bail!(localization::catalog().sidebar.client_machine_unavailable)
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
                Ok(self.finish_accepted_action(
                    AcceptedProviderEffects {
                        retire_open_on_failure: deletes_open_session,
                        ..AcceptedProviderEffects::default()
                    },
                    |runtime| {
                        runtime.refresh()?;
                        if deletes_open_session {
                            let (session, label, open, reused) =
                                runtime.open_selected_candidate()?;
                            let session_available = open.is_some();
                            runtime.stage_mandatory_replacement(open);
                            let mut ui = runtime.ui_state(session_available);
                            ui.notice = runtime.take_notice();
                            return Ok(MachineActionResult::replace(ui, session, label)
                                .with_reused_session(reused && session_available));
                        }
                        Ok(MachineActionResult::ui(runtime.ui_state_for_open_connection()))
                    },
                ))
            }
            MachineRequest::RestoreManagedMachine { machine, expected_version } => {
                let result = self.client.restore_machine(protocol::MachineMutationParams {
                    scope_id: self.snapshot.selected_scope_id.clone(),
                    machine_id: self.machine_id(machine)?,
                    expected_version,
                    mutation_id: self.next_mutation_id()?,
                })?;
                self.set_notice(result.notice);
                Ok(self.finish_accepted_action(AcceptedProviderEffects::default(), |runtime| {
                    runtime.refresh()?;
                    Ok(MachineActionResult::ui(runtime.ui_state_for_open_connection()))
                }))
            }
            MachineRequest::PurgeManagedMachine { machine, expected_version } => {
                let result = self.client.purge_machine(protocol::MachineMutationParams {
                    scope_id: self.snapshot.selected_scope_id.clone(),
                    machine_id: self.machine_id(machine)?,
                    expected_version,
                    mutation_id: self.next_mutation_id()?,
                })?;
                self.set_notice(result.notice);
                Ok(self.finish_accepted_action(AcceptedProviderEffects::default(), |runtime| {
                    runtime.refresh()?;
                    Ok(MachineActionResult::ui(runtime.ui_state_for_open_connection()))
                }))
            }
            MachineRequest::CreateManagedIsolatedWorkspace(key) => {
                self.create_workspace(key, protocol::WorkspaceCreateMode::Isolated)
            }
            MachineRequest::CreateManagedHostWorkspace(key) => {
                self.create_workspace(key, protocol::WorkspaceCreateMode::Host)
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
                Ok(self.finish_accepted_workspace_mutation(
                    ManagedWorkspaceSessionMutation::Rename { workspace_key: workspace_id, name },
                ))
            }
            MachineRequest::DeleteManagedWorkspace { machine, workspace_id, expected_version } => {
                let result = self.client.delete_workspace(protocol::WorkspaceMutationParams {
                    machine_id: self.machine_id(machine)?,
                    workspace_id: protocol::OpaqueId::new(workspace_id.clone())?,
                    expected_version,
                    mutation_id: self.next_mutation_id()?,
                })?;
                self.set_notice(result.notice);
                Ok(self.finish_accepted_workspace_mutation(
                    ManagedWorkspaceSessionMutation::Close { workspace_key: workspace_id },
                ))
            }
            MachineRequest::RestoreManagedWorkspace { machine, workspace_id, expected_version } => {
                let result = self.client.restore_workspace(protocol::WorkspaceMutationParams {
                    machine_id: self.machine_id(machine)?,
                    workspace_id: protocol::OpaqueId::new(workspace_id)?,
                    expected_version,
                    mutation_id: self.next_mutation_id()?,
                })?;
                self.set_notice(result.notice);
                Ok(self.finish_accepted_action(AcceptedProviderEffects::default(), |runtime| {
                    runtime.refresh()?;
                    Ok(MachineActionResult::ui(runtime.ui_state_for_open_connection()))
                }))
            }
            MachineRequest::PurgeManagedWorkspace { machine, workspace_id, expected_version } => {
                let result = self.client.purge_workspace(protocol::WorkspaceMutationParams {
                    machine_id: self.machine_id(machine)?,
                    workspace_id: protocol::OpaqueId::new(workspace_id)?,
                    expected_version,
                    mutation_id: self.next_mutation_id()?,
                })?;
                self.set_notice(result.notice);
                Ok(self.finish_accepted_action(AcceptedProviderEffects::default(), |runtime| {
                    runtime.refresh()?;
                    Ok(MachineActionResult::ui(runtime.ui_state_for_open_connection()))
                }))
            }
            MachineRequest::ReconnectProvider => unreachable!("handled before refresh"),
        }
    }

    fn perform_external_connect(
        &mut self,
        specifier: String,
    ) -> anyhow::Result<MachineActionResult> {
        let matches_pending = protocol::ExternalMachineSpecifier::new(specifier.clone())
            .ok()
            .is_some_and(|candidate| {
                self.pending_external_connect
                    .as_ref()
                    .is_some_and(|pending| pending.specifier == candidate)
            });
        if self.pending_external_connect.is_some() && !matches_pending {
            anyhow::bail!(
                localization::catalog().sidebar.machine_provider_external_connect_ambiguous
            );
        }
        match self.client.supports_capability(protocol::EXTERNAL_MACHINE_CONNECT_CAPABILITY) {
            Ok(true) => {}
            Ok(false) => {
                if matches_pending {
                    anyhow::bail!(
                        localization::catalog().sidebar.machine_provider_external_connect_ambiguous
                    );
                }
                self.pending_external_connect = None;
                anyhow::bail!(
                    localization::catalog().sidebar.machine_provider_external_connect_unsupported
                );
            }
            Err(ProviderClientError::Disconnected | ProviderClientError::NotAuthenticated) => {
                anyhow::bail!(localization::catalog().sidebar.machine_provider_disconnected);
            }
            Err(error) => return Err(error.into()),
        }
        if let Err(error) = self.refresh() {
            match error.downcast_ref::<ProviderClientError>() {
                Some(ProviderClientError::Disconnected | ProviderClientError::NotAuthenticated) => {
                    anyhow::bail!(localization::catalog().sidebar.machine_provider_disconnected);
                }
                _ => return Err(error),
            }
        }
        if !self.snapshot.capabilities.connect_external_machine {
            if matches_pending {
                anyhow::bail!(
                    localization::catalog().sidebar.machine_provider_external_connect_ambiguous
                );
            }
            self.pending_external_connect = None;
            anyhow::bail!(
                localization::catalog().sidebar.machine_provider_external_connect_unsupported
            );
        }
        self.connect_external_after_refresh(specifier)
    }

    fn connect_external_after_refresh(
        &mut self,
        specifier: String,
    ) -> anyhow::Result<MachineActionResult> {
        let specifier = match protocol::ExternalMachineSpecifier::new(specifier) {
            Ok(specifier) => specifier,
            Err(error) => {
                self.pending_external_connect = None;
                return Err(error.into());
            }
        };
        let scope_id = self.snapshot.selected_scope_id.clone();
        if self
            .pending_external_connect
            .as_ref()
            .is_some_and(|pending| pending.specifier == specifier && pending.scope_id != scope_id)
        {
            anyhow::bail!(
                localization::catalog().sidebar.machine_provider_external_connect_ambiguous
            );
        }
        let mutation_id = if let Some(pending) = self
            .pending_external_connect
            .as_ref()
            .filter(|pending| pending.scope_id == scope_id && pending.specifier == specifier)
        {
            pending.mutation_id.clone()
        } else {
            self.next_mutation_id()?
        };
        self.pending_external_connect = Some(PendingExternalConnect {
            scope_id: scope_id.clone(),
            specifier: specifier.clone(),
            mutation_id: mutation_id.clone(),
        });
        let connected = match self.client.connect_external_machine(scope_id, specifier, mutation_id)
        {
            Ok(connected) => connected,
            Err(error) => {
                if matches!(
                    &error,
                    ProviderClientError::Provider(provider_error) if !provider_error.retryable
                ) {
                    self.pending_external_connect = None;
                }
                return Err(error.into());
            }
        };
        self.pending_external_connect = None;
        Ok(self.finish_accepted_machine_selection(connected.machine_id, connected.notice))
    }

    pub(crate) fn close(&mut self) {
        self.abort_replacement();
        self.open = None;
        self.connections.close();
    }

    fn acknowledge_durable_notice(&self, delivery: &DurableNoticeDelivery) -> anyhow::Result<()> {
        self.client.acknowledge_notice(protocol::NoticeDelivery {
            notice_id: protocol::OpaqueId::new(delivery.notice_id.clone())?,
            sequence: delivery.sequence,
        })?;
        Ok(())
    }

    pub(crate) fn subscribe_ui_updates(&self) -> anyhow::Result<MachineUpdateStream> {
        let events = self.client.subscribe_events()?;
        let client = self.client.clone();
        let keys = self.keys.clone();
        let connections = self.connections.clone();
        let connection_registry = self.connection_registry.clone();
        let provider_connect_supported = client
            .supports_capability(protocol::EXTERNAL_MACHINE_CONNECT_CAPABILITY)
            .unwrap_or(false);
        let durable_notices_supported =
            client.supports_capability(protocol::DURABLE_NOTICES_CAPABILITY).unwrap_or(false);
        let mut connected_session =
            self.open.as_ref().map(|open| (open.connection_id.clone(), open.machine_id.clone()));
        let stop = Arc::new(AtomicBool::new(false));
        let thread_stop = stop.clone();
        let (sender, receiver) = mpsc::sync_channel(PROVIDER_REFRESH_QUEUE_CAPACITY);
        let mut last_snapshot = self.snapshot.clone();
        let mut last_machine_lifecycle_snapshot = self.machine_lifecycle_snapshot.clone();
        let mut last_workspace_snapshot = self.workspace_snapshot.clone();
        let mut last_snapshot_notice = self.last_snapshot_notice.clone();
        let (mut desired_scope_id, mut desired_machine_id) = self.desired_selection();
        let (refresh_sender, refresh_receiver) =
            mpsc::sync_channel(PROVIDER_REFRESH_QUEUE_CAPACITY);
        let refresh_overflowed = Arc::new(AtomicBool::new(false));
        let worker_refresh_overflowed = refresh_overflowed.clone();
        let snapshot_refresh_pending = Arc::new(AtomicBool::new(false));
        let worker_snapshot_refresh_pending = snapshot_refresh_pending.clone();
        let refresh_stop = stop.clone();
        let refresh_output = sender.clone();
        let refresh_worker = std::thread::Builder::new()
            .name("machine-provider-refresh".into())
            .spawn(move || {
                // Latest-value cells for connection progress, one per machine
                // (see MachineUpdate::ConnectionProgress).
                let mut progress_cells: HashMap<String, Arc<Mutex<Option<String>>>> =
                    HashMap::new();
                let mut progress_last_sent: HashMap<String, std::time::Instant> = HashMap::new();
                while !refresh_stop.load(Ordering::Acquire) {
                    if worker_refresh_overflowed.load(Ordering::Acquire) {
                        let mut ui = machine_ui_state(
                            &last_snapshot,
                            &last_machine_lifecycle_snapshot,
                            last_workspace_snapshot.as_ref(),
                            &keys,
                            false,
                            false,
                        );
                        ui.notice = Some(
                            localization::catalog().sidebar.machine_provider_disconnected.into(),
                        );
                        ui.request = Some(MachineRequest::ReconnectProvider);
                        let _ = refresh_output.send(MachineUpdate::Ui(Box::new(ui)));
                        break;
                    }
                    let event = match refresh_receiver.recv_timeout(Duration::from_millis(250)) {
                        Ok(ProviderRefreshSignal::Refresh(event)) => {
                            if matches!(&event, Some(protocol::ProviderEvent::SnapshotChanged(_))) {
                                // Permit one follow-up invalidation while this authoritative
                                // refresh is in flight. Its snapshot will include every earlier
                                // state-free invalidation.
                                worker_snapshot_refresh_pending.store(false, Ordering::Release);
                            }
                            event
                        }
                        Ok(ProviderRefreshSignal::Disconnected) => {
                            let mut ui = machine_ui_state(
                                &last_snapshot,
                                &last_machine_lifecycle_snapshot,
                                last_workspace_snapshot.as_ref(),
                                &keys,
                                false,
                                false,
                            );
                            ui.notice = Some(
                                localization::catalog()
                                    .sidebar
                                    .machine_provider_disconnected
                                    .into(),
                            );
                            ui.request = Some(MachineRequest::ReconnectProvider);
                            let _ = refresh_output.send(MachineUpdate::Ui(Box::new(ui)));
                            break;
                        }
                        Err(mpsc::RecvTimeoutError::Timeout) => continue,
                        Err(mpsc::RecvTimeoutError::Disconnected) => {
                            if worker_refresh_overflowed.load(Ordering::Acquire) {
                                let mut ui = machine_ui_state(
                                    &last_snapshot,
                                    &last_machine_lifecycle_snapshot,
                                    last_workspace_snapshot.as_ref(),
                                    &keys,
                                    false,
                                    false,
                                );
                                ui.notice = Some(
                                    localization::catalog()
                                        .sidebar
                                        .machine_provider_disconnected
                                        .into(),
                                );
                                ui.request = Some(MachineRequest::ReconnectProvider);
                                let _ = refresh_output.send(MachineUpdate::Ui(Box::new(ui)));
                            }
                            break;
                        }
                    };
                    if let Some(protocol::ProviderEvent::ConnectionProgress(progress)) =
                        event.as_ref()
                    {
                        // Forward without a snapshot reload: the provider's
                        // serialized control loop is busy inside open_machine
                        // while it pushes these, so a snapshot request would
                        // stall exactly the message it is meant to show.
                        let machine_id = progress.machine_id.as_str().to_string();
                        // Provider-controlled text: strip terminal control
                        // characters (ESC/OSC injection) and cap it at the
                        // trust boundary (char-safe) before it is stored or
                        // drawn.
                        let mut message: String = progress
                            .message
                            .chars()
                            .map(|c| if c.is_control() { ' ' } else { c })
                            .collect();
                        if message.len() > 512 {
                            let mut end = 512;
                            while !message.is_char_boundary(end) {
                                end -= 1;
                            }
                            message.truncate(end);
                        }
                        // Hard bound against a provider spraying distinct
                        // ids while no snapshot prunes the map. Rejecting the
                        // event (progress is advisory) keeps the one-in-
                        // flight-per-machine invariant; clearing instead
                        // would mint fresh cells whose updates stack on top
                        // of unconsumed ones.
                        if progress_cells.len() >= 128 && !progress_cells.contains_key(&machine_id)
                        {
                            continue;
                        }
                        // Rate floor per machine, checked before any state is
                        // written: a provider emitting stages faster than
                        // 20/s buys no fidelity and would drive main-loop
                        // redraws at its own cadence. Dropped events leave
                        // the cell untouched, so the in-flight invariant
                        // holds (progress is advisory; the settle clears it).
                        let now = std::time::Instant::now();
                        if let Some(last) = progress_last_sent.get(&machine_id)
                            && now.duration_since(*last) < Duration::from_millis(50)
                        {
                            continue;
                        }
                        let cell = progress_cells.entry(machine_id.clone()).or_default();
                        let already_in_flight = {
                            let mut slot =
                                cell.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
                            let pending = slot.is_some();
                            *slot = Some(message);
                            pending
                        };
                        if already_in_flight {
                            // An unconsumed update for this machine is queued;
                            // it will deliver this newer message when read.
                            continue;
                        }
                        progress_last_sent.insert(machine_id.clone(), now);
                        if refresh_output
                            .send(MachineUpdate::ConnectionProgress {
                                machine_id,
                                latest: Arc::clone(cell),
                            })
                            .is_err()
                        {
                            // The app side is gone (shutdown): stop pumping
                            // like every other update path does.
                            break;
                        }
                        continue;
                    }
                    let mut notice = None;
                    let had_connected_session = connected_session.is_some();
                    if let Some(protocol::ProviderEvent::ConnectionClosed(closed)) = event.as_ref()
                    {
                        let closed_key = connection_registry.lock().ok().and_then(|registry| {
                            registry.iter().find_map(|(key, open)| {
                                (open.connection_id == closed.connection_id
                                    && open.machine_id == closed.machine_id)
                                    .then_some(*key)
                            })
                        });
                        if let Some(key) = closed_key {
                            connections.remove(key);
                        }
                        if connected_session.as_ref().is_some_and(|(connection_id, machine_id)| {
                            connection_id == &closed.connection_id
                                && machine_id == &closed.machine_id
                        }) {
                            connected_session = None;
                            notice = Some(closed.reason.clone());
                        }
                    }
                    if let Some(protocol::ProviderEvent::Notice(provider_notice)) = event.as_ref() {
                        notice = Some(provider_notice.message.clone());
                    }
                    let snapshot = match load_snapshot_for_selection(
                        &client,
                        Some(last_snapshot.revision),
                        &last_snapshot.selected_scope_id,
                        &mut desired_scope_id,
                        &mut desired_machine_id,
                    ) {
                        Ok(snapshot) => snapshot,
                        Err(error) => {
                            let mut ui = machine_ui_state(
                                &last_snapshot,
                                &last_machine_lifecycle_snapshot,
                                last_workspace_snapshot.as_ref(),
                                &keys,
                                false,
                                false,
                            );
                            ui.notice = Some(if client.is_live() {
                                format!(
                                    "{}: {error}",
                                    localization::catalog().sidebar.machine_provider_update_failed
                                )
                            } else {
                                localization::catalog().sidebar.machine_provider_disconnected.into()
                            });
                            ui.request = Some(MachineRequest::ReconnectProvider);
                            let _ = refresh_output.send(MachineUpdate::Ui(Box::new(ui)));
                            break;
                        }
                    };
                    // Each snapshot is the authoritative machine set: drop
                    // progress cells for machines that no longer exist, so a
                    // long-lived provider emitting many distinct ids cannot
                    // grow the registry without bound.
                    progress_cells.retain(|machine_id, _| {
                        snapshot
                            .machines
                            .iter()
                            .any(|machine| machine.id.as_str() == machine_id.as_str())
                    });
                    progress_last_sent.retain(|machine_id, _| {
                        snapshot
                            .machines
                            .iter()
                            .any(|machine| machine.id.as_str() == machine_id.as_str())
                    });
                    let changed_snapshot_notice =
                        if !durable_notices_supported && snapshot.notice != last_snapshot_notice {
                            snapshot.notice.clone()
                        } else {
                            None
                        };
                    last_snapshot_notice = snapshot.notice.clone();
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
                                    false,
                                );
                                ui.notice = Some(format!(
                                    "{}: {error}",
                                    localization::catalog()
                                        .sidebar
                                        .machine_provider_lifecycle_update_failed
                                ));
                                ui.request = Some(MachineRequest::ReconnectProvider);
                                let _ = refresh_output.send(MachineUpdate::Ui(Box::new(ui)));
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
                                false,
                            );
                            ui.notice = Some(format!(
                                "{}: {error}",
                                localization::catalog()
                                    .sidebar
                                    .machine_provider_workspace_update_failed
                            ));
                            ui.request = Some(MachineRequest::ReconnectProvider);
                            let _ = refresh_output.send(MachineUpdate::Ui(Box::new(ui)));
                            break;
                        }
                    };
                    reconcile_keys(&keys, &snapshot, &last_machine_lifecycle_snapshot);
                    sync_provider_connection_hub(
                        &snapshot,
                        Arc::clone(&client),
                        &keys,
                        &connections,
                        &connection_registry,
                    );
                    let session_available = snapshot.selected_machine_id.is_some()
                        && connected_session.as_ref().is_some_and(|(_, machine_id)| {
                            snapshot.selected_machine_id.as_ref() == Some(machine_id)
                                && key_for_id(&keys, machine_id)
                                    .is_some_and(|key| connections.is_ready(key))
                        });
                    let mut ui = machine_ui_state(
                        &snapshot,
                        &last_machine_lifecycle_snapshot,
                        last_workspace_snapshot.as_ref(),
                        &keys,
                        session_available,
                        provider_connect_supported,
                    );
                    ui.set_connection_phases(connections.phases());
                    ui.notice = notice;
                    if let Some(snapshot_notice) = changed_snapshot_notice {
                        append_notice_once(&mut ui.notice, snapshot_notice.message);
                    }
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
                    if refresh_output.send(MachineUpdate::Ui(Box::new(ui))).is_err() {
                        break;
                    }
                }
            })?;
        refresh_sender.send(ProviderRefreshSignal::Refresh(None))?;
        let worker = std::thread::Builder::new().name("machine-provider-events".into()).spawn(
            move || {
                while !thread_stop.load(Ordering::Acquire) {
                    match events.recv_timeout(Duration::from_millis(250)) {
                        Ok(received) => {
                            let crate::machine_provider_client::ReceivedProviderEvent {
                                event,
                                delivery,
                            } = received;
                            if let (
                                protocol::ProviderEvent::Notice(provider_notice),
                                Some(delivery),
                            ) = (&event, delivery)
                            {
                                let level = match provider_notice.level {
                                    protocol::NoticeLevel::Info => DurableNoticeLevel::Info,
                                    protocol::NoticeLevel::Warning => DurableNoticeLevel::Warning,
                                    protocol::NoticeLevel::Error => DurableNoticeLevel::Error,
                                };
                                let update = MachineUpdate::DurableNotice(DurableProviderNotice {
                                    delivery: DurableNoticeDelivery {
                                        notice_id: delivery.notice_id.into_inner(),
                                        sequence: delivery.sequence,
                                    },
                                    level,
                                    message: provider_notice.message.clone(),
                                });
                                if sender.send(update).is_err() {
                                    break;
                                }
                                continue;
                            }
                            if matches!(&event, protocol::ProviderEvent::SnapshotChanged(_)) {
                                if snapshot_refresh_pending.swap(true, Ordering::AcqRel) {
                                    continue;
                                }
                                match refresh_sender
                                    .try_send(ProviderRefreshSignal::Refresh(Some(event)))
                                {
                                    Ok(()) => {}
                                    Err(mpsc::TrySendError::Full(_)) => {
                                        // Every queued refresh loads the latest snapshot, so a
                                        // state-free invalidation can be retried or subsumed
                                        // without treating the provider stream as lossy.
                                        snapshot_refresh_pending.store(false, Ordering::Release);
                                    }
                                    Err(mpsc::TrySendError::Disconnected(_)) => {
                                        snapshot_refresh_pending.store(false, Ordering::Release);
                                        break;
                                    }
                                }
                                continue;
                            }
                            match refresh_sender
                                .try_send(ProviderRefreshSignal::Refresh(Some(event)))
                            {
                                Ok(()) => {}
                                Err(mpsc::TrySendError::Full(_)) => {
                                    refresh_overflowed.store(true, Ordering::Release);
                                    break;
                                }
                                Err(mpsc::TrySendError::Disconnected(_)) => break,
                            }
                        }
                        Err(mpsc::RecvTimeoutError::Timeout) => continue,
                        Err(mpsc::RecvTimeoutError::Disconnected) => {
                            if let Err(mpsc::TrySendError::Full(_)) =
                                refresh_sender.try_send(ProviderRefreshSignal::Disconnected)
                            {
                                refresh_overflowed.store(true, Ordering::Release);
                            }
                            break;
                        }
                    }
                }
                drop(refresh_sender);
                let _ = refresh_worker.join();
            },
        )?;
        Ok(MachineUpdateStream::new(receiver, stop, worker))
    }

    fn reconnect_session(&mut self) -> anyhow::Result<MachineActionResult> {
        self.reconnect_control()?;

        match self.open_selected_candidate() {
            Ok((session, label, open, reused)) => {
                let session_available = open.is_some();
                self.stage_connection(open, None)?;
                let mut ui = self.ui_state(session_available);
                ui.notice = self.take_notice();
                let mut result = MachineActionResult::replace(ui, session, label)
                    .with_reused_session(reused && session_available);
                result.restart_updates = true;
                Ok(result)
            }
            Err(error) => {
                // The provider control plane is live again, but opening its
                // selected machine failed. Keep the current mux transport and
                // restart catalog updates against the fresh control client.
                let mut ui = self.ui_state_for_open_connection();
                append_notice(
                    &mut ui.notice,
                    format!(
                        "{}: {error}",
                        localization::catalog().sidebar.machine_reconnect_failed
                    ),
                );
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
        let (client, initial_snapshot, initial_machine_lifecycle, initial_workspace) =
            connect_client(Arc::clone(&self.connector), &mut self.notice_identity)?;
        let (mut desired_scope_id, mut desired_machine_id) = self.desired_selection();
        let mut snapshot = reconcile_snapshot_selection(
            &client,
            initial_snapshot.clone(),
            &mut desired_scope_id,
            &mut desired_machine_id,
        )?;
        let surface_snapshot_notice =
            !client.supports_capability(protocol::DURABLE_NOTICES_CAPABILITY)?;
        self.observe_snapshot_notice(snapshot.notice.clone(), surface_snapshot_notice);
        let (machine_lifecycle_snapshot, workspace_snapshot) = if snapshot == initial_snapshot {
            (initial_machine_lifecycle, initial_workspace)
        } else {
            (
                load_machine_lifecycle_snapshot(&client, &snapshot)?,
                load_workspace_snapshot(&client, &snapshot)?,
            )
        };
        let selection_applied = if let Some(intent) = self.accepted_selection.as_ref() {
            let scope_matches = intent
                .scope_id
                .as_ref()
                .is_none_or(|scope_id| scope_id == &snapshot.selected_scope_id);
            let machine_matches = intent.machine_id.as_ref().is_none_or(|machine_id| {
                if snapshot.machines.iter().any(|machine| &machine.id == machine_id) {
                    snapshot.selected_machine_id = Some(machine_id.clone());
                    true
                } else {
                    false
                }
            });
            scope_matches && machine_matches
        } else {
            true
        };
        self.client = Arc::new(client);
        self.snapshot = snapshot;
        self.machine_lifecycle_snapshot = machine_lifecycle_snapshot;
        self.workspace_snapshot = workspace_snapshot;
        if selection_applied {
            self.accepted_selection = None;
        }
        self.reconcile_keys();
        self.sync_connection_hub();
        Ok(())
    }

    fn open_selected_candidate(
        &self,
    ) -> anyhow::Result<(Session, String, Option<OpenConnection>, bool)> {
        let selected = self
            .snapshot
            .selected_machine_id
            .as_ref()
            .and_then(|id| self.snapshot.machines.iter().find(|machine| &machine.id == id))
            .cloned();
        let Some(machine) = selected else {
            return Ok((placeholder_session(), "machines".to_string(), None, false));
        };
        if !machine.connectable {
            anyhow::bail!(localization::catalog().sidebar.machine_not_ready_to_connect);
        }
        let key = key_for_id(&self.keys, &machine.id).ok_or_else(|| {
            anyhow::anyhow!(localization::catalog().sidebar.machine_not_ready_to_connect)
        })?;
        self.sync_connection_hub();
        let (session, reused) = self.connections.connect_tracked(key)?;
        let open = self
            .connection_registry
            .lock()
            .map_err(|_| {
                anyhow::anyhow!(localization::catalog().sidebar.machine_provider_update_failed)
            })?
            .get(&key)
            .cloned()
            .ok_or_else(|| {
                anyhow::anyhow!(localization::catalog().sidebar.machine_not_ready_to_connect)
            })?;
        Ok((session, machine.display_name, Some(open), reused))
    }

    fn create_workspace(
        &mut self,
        key: MachineKey,
        mode: protocol::WorkspaceCreateMode,
    ) -> anyhow::Result<MachineActionResult> {
        let result =
            self.client.create_workspace(self.machine_id(key)?, mode, self.next_mutation_id()?)?;
        self.set_notice(result.notice);
        Ok(self.finish_accepted_action(AcceptedProviderEffects::default(), |runtime| {
            runtime.refresh()?;
            Ok(MachineActionResult::ui(runtime.ui_state_for_open_connection()))
        }))
    }

    /// Reconcile every mutation that selects a newly created or enrolled
    /// machine through the same authoritative refresh and switch request.
    fn finish_accepted_machine_selection(
        &mut self,
        machine_id: protocol::OpaqueId,
        notice: Option<protocol::ProviderNotice>,
    ) -> MachineActionResult {
        self.set_notice(notice);
        self.accepted_selection = Some(AcceptedSelectionIntent {
            scope_id: Some(self.snapshot.selected_scope_id.clone()),
            machine_id: Some(machine_id),
        });
        self.finish_accepted_action(
            AcceptedProviderEffects { restart_updates: true, ..AcceptedProviderEffects::default() },
            |runtime| {
                runtime.refresh()?;
                Ok(MachineActionResult::ui(runtime.ui_state_for_open_connection()))
            },
        )
    }

    fn finish_accepted_workspace_mutation(
        &mut self,
        mutation: ManagedWorkspaceSessionMutation,
    ) -> MachineActionResult {
        self.finish_accepted_action(
            AcceptedProviderEffects {
                session_mutation: Some(mutation),
                ..AcceptedProviderEffects::default()
            },
            |runtime| {
                runtime.refresh()?;
                Ok(MachineActionResult::ui(runtime.ui_state_for_open_connection()))
            },
        )
    }

    fn finish_accepted_action(
        &mut self,
        effects: AcceptedProviderEffects,
        completion: impl FnOnce(&mut Self) -> anyhow::Result<MachineActionResult>,
    ) -> MachineActionResult {
        let mut reconciliation_failed = false;
        let mut result = match completion(self) {
            Ok(result) => result,
            Err(error) => {
                reconciliation_failed = true;
                let mut ui = self.ui_state_for_open_connection();
                append_notice(
                    &mut ui.notice,
                    format!(
                        "{}: {error}",
                        localization::catalog().sidebar.machine_provider_update_failed
                    ),
                );
                ui.request = Some(MachineRequest::ReconnectProvider);
                MachineActionResult::ui(ui)
            }
        };
        if self.accepted_selection.is_some() {
            result.ui.request = Some(MachineRequest::ReconnectProvider);
        }
        if let Some(mutation) = effects.session_mutation {
            result = result.with_session_mutation(mutation);
        }
        if let Some(label) = effects.session_label {
            result = result.with_session_label(label);
        }
        result.restart_updates |= effects.restart_updates;
        if reconciliation_failed && effects.retire_open_on_failure {
            let label = self
                .open
                .as_ref()
                .and_then(|open| {
                    self.snapshot.machines.iter().find(|machine| machine.id == open.machine_id)
                })
                .map(|machine| machine.display_name.clone())
                .unwrap_or_else(|| "machines".to_string());
            self.stage_mandatory_replacement(None);
            result.ui.session_available = false;
            let machine = result.ui.snapshot.active;
            result.replacement = Some(crate::machine::MachineSession {
                session: placeholder_session(),
                label,
                machine,
                reused: false,
            });
            result.restart_updates = true;
        }
        result
    }

    fn stage_connection(
        &mut self,
        candidate: Option<OpenConnection>,
        rollback: Option<ProviderSelectionRollback>,
    ) -> anyhow::Result<()> {
        if self.pending.is_some() {
            if let Some(rollback) = rollback {
                self.restore_selection(rollback);
            }
            anyhow::bail!(localization::catalog().sidebar.machine_replacement_pending)
        }
        self.pending = Some(PendingConnection { candidate, rollback, retire_open_on_abort: false });
        Ok(())
    }

    fn stage_mandatory_replacement(&mut self, candidate: Option<OpenConnection>) {
        debug_assert!(self.pending.is_none());
        self.abort_replacement();
        self.pending =
            Some(PendingConnection { candidate, rollback: None, retire_open_on_abort: true });
    }

    fn commit_replacement(&mut self, present: bool) -> anyhow::Result<()> {
        if !present {
            let pending = self.pending.take().ok_or_else(|| {
                anyhow::anyhow!(localization::catalog().sidebar.machine_replacement_not_pending)
            })?;
            if let Some(rollback) = pending.rollback {
                self.restore_selection(rollback);
            }
            if pending.retire_open_on_abort {
                if let Some(key) =
                    self.open.as_ref().and_then(|open| key_for_id(&self.keys, &open.machine_id))
                {
                    self.connections.remove(key);
                }
                self.open = None;
                self.connections.note_presented(None);
            }
            return Ok(());
        }
        let pending = self.pending.take().ok_or_else(|| {
            anyhow::anyhow!(localization::catalog().sidebar.machine_replacement_not_pending)
        })?;
        self.open = pending.candidate;
        let presented =
            self.open.as_ref().and_then(|open| key_for_id(&self.keys, &open.machine_id));
        self.connections.note_presented(presented);
        Ok(())
    }

    fn abort_replacement(&mut self) {
        let Some(pending) = self.pending.take() else {
            return;
        };
        if let Some(key) = pending
            .candidate
            .as_ref()
            .and_then(|candidate| key_for_id(&self.keys, &candidate.machine_id))
        {
            self.connections.remove(key);
        }
        if let Some(rollback) = pending.rollback {
            self.restore_selection(rollback);
        }
        if pending.retire_open_on_abort {
            if let Some(key) =
                self.open.as_ref().and_then(|open| key_for_id(&self.keys, &open.machine_id))
            {
                self.connections.remove(key);
            }
            self.open = None;
            self.connections.note_presented(None);
        }
    }

    fn restore_selection(&mut self, rollback: ProviderSelectionRollback) {
        self.snapshot.selected_machine_id = rollback.selected_machine_id;
        self.workspace_snapshot = rollback.workspace_snapshot;
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

    fn accept_selection_intent(&mut self, intent: AcceptedSelectionIntent) {
        self.pending_external_connect = None;
        self.accepted_selection = Some(intent);
    }

    fn reconcile_keys(&mut self) {
        reconcile_keys(&self.keys, &self.snapshot, &self.machine_lifecycle_snapshot);
    }

    fn sync_connection_hub(&self) {
        sync_provider_connection_hub(
            &self.snapshot,
            Arc::clone(&self.client),
            &self.keys,
            &self.connections,
            &self.connection_registry,
        );
    }

    fn sync_connections(&self) {
        self.sync_connection_hub();
    }

    fn ui_state(&self, session_available: bool) -> MachineUiState {
        let mut ui = machine_ui_state(
            &self.snapshot,
            &self.machine_lifecycle_snapshot,
            self.workspace_snapshot.as_ref(),
            &self.keys,
            session_available,
            self.client
                .supports_capability(protocol::EXTERNAL_MACHINE_CONNECT_CAPABILITY)
                .unwrap_or(false),
        );
        ui.set_connection_phases(self.connections.phases());
        ui
    }

    fn ui_state_for_open_connection(&mut self) -> MachineUiState {
        let session_available = self.open.as_ref().is_some_and(|open| {
            self.snapshot.selected_machine_id.as_ref() == Some(&open.machine_id)
                && key_for_id(&self.keys, &open.machine_id)
                    .is_some_and(|key| self.connections.is_ready(key))
        });
        let mut ui = self.ui_state(session_available);
        ui.notice = self.take_notice();
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

    fn desired_selection(&self) -> (protocol::OpaqueId, Option<protocol::OpaqueId>) {
        let scope_id = self
            .accepted_selection
            .as_ref()
            .and_then(|intent| intent.scope_id.clone())
            .unwrap_or_else(|| self.snapshot.selected_scope_id.clone());
        let machine_id = self
            .accepted_selection
            .as_ref()
            .and_then(|intent| intent.machine_id.clone())
            .or_else(|| self.snapshot.selected_machine_id.clone());
        (scope_id, machine_id)
    }

    fn observe_snapshot_notice(&mut self, notice: Option<protocol::ProviderNotice>, surface: bool) {
        if self.last_snapshot_notice == notice {
            return;
        }
        self.last_snapshot_notice = notice.clone();
        if surface && let Some(notice) = notice {
            self.push_notice(notice.message);
        }
    }

    fn take_notice(&mut self) -> Option<String> {
        self.pending_notice_messages.clear();
        self.notice.take()
    }

    fn set_notice(&mut self, notice: Option<protocol::ProviderNotice>) {
        if let Some(notice) = notice {
            self.push_notice(notice.message);
        }
    }

    fn push_notice(&mut self, notice: impl Into<String>) {
        let notice = notice.into();
        if self.pending_notice_messages.insert(notice.clone()) {
            append_notice(&mut self.notice, notice);
        }
    }
}

fn append_notice(notice: &mut Option<String>, message: impl Into<String>) {
    let message = message.into();
    *notice = Some(match notice.take() {
        Some(existing) => format!("{existing}\n{message}"),
        None => message,
    });
}

fn append_notice_once(notice: &mut Option<String>, message: impl Into<String>) {
    let message = message.into();
    if notice.as_deref() != Some(message.as_str()) {
        append_notice(notice, message);
    }
}

fn merge_local_machine_ui(
    mut ui: MachineUiState,
    local: &MachineUiState,
    active_local: Option<MachineKey>,
) -> MachineUiState {
    ui.snapshot.machines.extend(local.snapshot.machines.iter().cloned());
    ui.snapshot.capabilities.create |= local.snapshot.capabilities.create;
    ui.snapshot.capabilities.connect |= local.snapshot.capabilities.connect;
    ui.creation_sources.extend(local.creation_sources.iter().cloned());
    ui.connection_targets.extend(local.connection_targets.iter().cloned());
    ui.extend_client_renamable_machines(
        local
            .snapshot
            .machines
            .iter()
            .filter(|machine| local.is_client_machine_renamable(machine.key))
            .map(|machine| machine.key),
    );
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

fn merge_local_machine_ui_for_provider_switch(
    ui: MachineUiState,
    local: &MachineUiState,
    active_local: Option<MachineKey>,
    pending_provider_switch: bool,
) -> MachineUiState {
    let active_local =
        if pending_provider_switch && matches!(ui.request, Some(MachineRequest::Switch(_))) {
            None
        } else {
            active_local
        };
    merge_local_machine_ui(ui, local, active_local)
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

#[cfg(test)]
fn random_notice_consumer_id() -> anyhow::Result<protocol::OpaqueId> {
    protocol::OpaqueId::new(format!("cmux-tui-{}", random_mutation_nonce()?))
        .map_err(anyhow::Error::from)
}

impl MachineController for ProviderMachineRuntime {
    fn perform(&mut self, request: MachineRequest) -> anyhow::Result<MachineActionResult> {
        self.perform_request(request)
    }

    fn subscribe_updates(&self) -> anyhow::Result<Option<MachineUpdateStream>> {
        self.subscribe_ui_updates().map(Some)
    }

    fn acknowledge_durable_notice(
        &mut self,
        delivery: &DurableNoticeDelivery,
    ) -> anyhow::Result<()> {
        ProviderMachineRuntime::acknowledge_durable_notice(self, delivery)
    }

    fn commit_replacement(&mut self, present: bool) -> anyhow::Result<()> {
        ProviderMachineRuntime::commit_replacement(self, present)
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
    notice_identity: &mut ProviderNoticeIdentity,
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
    if client.supports_capability(protocol::DURABLE_NOTICES_CAPABILITY)? {
        let consumer_id = notice_identity.consumer_id()?.clone();
        client.subscribe_notices(consumer_id)?;
    }
    let snapshot = client.snapshot(None)?;
    let machine_lifecycle_snapshot = load_machine_lifecycle_snapshot(&client, &snapshot)?;
    let workspace_snapshot = load_workspace_snapshot(&client, &snapshot)?;
    Ok((client, snapshot, machine_lifecycle_snapshot, workspace_snapshot))
}

fn load_snapshot_for_selection(
    client: &ProviderClient,
    known_revision: Option<u64>,
    observed_scope_id: &protocol::OpaqueId,
    desired_scope_id: &mut protocol::OpaqueId,
    desired_machine_id: &mut Option<protocol::OpaqueId>,
) -> anyhow::Result<protocol::SnapshotResult> {
    let snapshot = if observed_scope_id == desired_scope_id {
        client.snapshot(known_revision)?
    } else {
        client.select_scope(desired_scope_id.clone())?.snapshot
    };
    reconcile_snapshot_selection(client, snapshot, desired_scope_id, desired_machine_id)
}

fn reconcile_snapshot_selection(
    client: &ProviderClient,
    mut snapshot: protocol::SnapshotResult,
    desired_scope_id: &mut protocol::OpaqueId,
    desired_machine_id: &mut Option<protocol::OpaqueId>,
) -> anyhow::Result<protocol::SnapshotResult> {
    if snapshot.selected_scope_id != *desired_scope_id {
        if snapshot.scopes.iter().any(|scope| scope.id == *desired_scope_id) {
            snapshot = client.select_scope(desired_scope_id.clone())?.snapshot;
        } else {
            *desired_scope_id = snapshot.selected_scope_id.clone();
            *desired_machine_id = snapshot.selected_machine_id.clone();
        }
    }
    if snapshot.selected_scope_id == *desired_scope_id {
        if let Some(machine_id) = desired_machine_id.as_ref()
            && snapshot.machines.iter().any(|machine| &machine.id == machine_id)
        {
            snapshot.selected_machine_id = Some(machine_id.clone());
        } else {
            *desired_machine_id = snapshot.selected_machine_id.clone();
        }
    }
    Ok(snapshot)
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

fn sync_provider_connection_hub(
    snapshot: &protocol::SnapshotResult,
    client: Arc<ProviderClient>,
    keys: &Arc<Mutex<KeyRegistry>>,
    connections: &MachineConnectionHub,
    registry: &Arc<Mutex<HashMap<MachineKey, OpenConnection>>>,
) {
    let visible =
        snapshot.machines.iter().map(|machine| machine.id.clone()).collect::<HashSet<_>>();
    // A provider may temporarily mark a running machine non-connectable while
    // preserving an already-open transport. Do not wake such a machine, but
    // keep its existing session until the provider closes or removes it.
    let mut keep = registry.lock().ok().map_or_else(HashSet::new, |registry| {
        registry
            .iter()
            .filter_map(|(key, open)| visible.contains(&open.machine_id).then_some(*key))
            .collect()
    });
    for machine in snapshot.machines.iter().filter(|machine| machine.connectable) {
        let Some(key) = key_for_id(keys, &machine.id) else { continue };
        keep.insert(key);
        connections.register(
            key,
            provider_machine_connector(
                Arc::clone(&client),
                machine.clone(),
                key,
                Arc::clone(registry),
            ),
        );
    }
    connections.retain(&keep);
}

fn provider_machine_connector(
    client: Arc<ProviderClient>,
    machine: protocol::MachineDescriptor,
    key: MachineKey,
    registry: Arc<Mutex<HashMap<MachineKey, OpenConnection>>>,
) -> MachineConnectFn {
    Arc::new(move || {
        connect_provider_machine(Arc::clone(&client), machine.clone(), key, Arc::clone(&registry))
    })
}

fn connect_provider_machine(
    client: Arc<ProviderClient>,
    machine: protocol::MachineDescriptor,
    key: MachineKey,
    registry: Arc<Mutex<HashMap<MachineKey, OpenConnection>>>,
) -> anyhow::Result<MachineConnection> {
    let provider_managed =
        matches!(machine.workspace_create, protocol::WorkspaceCreatePolicy::Provider { .. });
    if provider_managed
        && !client.supports_capability(protocol::WORKSPACE_MIRROR_AUTHORITY_CAPABILITY)?
    {
        anyhow::bail!(localization::catalog().sidebar.machine_managed_authority_unsupported);
    }

    let opened = client.open_machine(machine.id.clone(), provider_managed)?;
    let connection_id = opened.connection_id.clone();
    let workspace_mirror_authority = opened.workspace_mirror_authority;
    let authority_is_valid = workspace_mirror_authority.as_ref().is_some_and(|authority| {
        authority.expose().len() >= protocol::MIN_WORKSPACE_MIRROR_AUTHORITY_BYTES
    });
    if provider_managed != workspace_mirror_authority.is_some()
        || (provider_managed && !authority_is_valid)
    {
        let _ = client.close_machine(connection_id);
        anyhow::bail!(localization::catalog().sidebar.machine_managed_authority_invalid);
    }
    let transport = match client.consume_transport(opened.transport) {
        Ok(transport) => transport,
        Err(error) => {
            let _ = client.close_machine(connection_id);
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
            let _ = client.close_machine(connection_id);
            return Err(error);
        }
    };
    let session = Session::Remote(remote);
    let open = OpenConnection { client, connection_id, machine_id: machine.id };
    let mut connections = match registry.lock() {
        Ok(connections) => connections,
        Err(_) => {
            session.begin_shutdown();
            let _ = open.client.close_machine(open.connection_id);
            anyhow::bail!(localization::catalog().sidebar.machine_provider_update_failed);
        }
    };
    connections.insert(key, open.clone());
    drop(connections);
    Ok(MachineConnection {
        session,
        _lease: Some(Box::new(ProviderMachineConnectionLease { open, key, registry })),
    })
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

#[cfg(test)]
mod tests {
    use std::io::{BufRead, BufReader, ErrorKind as IoErrorKind, Write};
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
    use std::os::unix::net::{UnixListener, UnixStream};
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::mpsc;
    use std::thread;
    use std::time::{Duration, Instant as TestInstant};

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

    struct TestStateRoot {
        path: PathBuf,
    }

    impl TestStateRoot {
        fn create(label: &str) -> Self {
            let id = NEXT_SOCKET_ID.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir()
                .join(format!("cmux-provider-state-{label}-{}-{id}", std::process::id()));
            let _ = std::fs::remove_dir_all(&path);
            let mut builder = std::fs::DirBuilder::new();
            builder.mode(0o700).create(&path).unwrap();
            Self { path }
        }
    }

    impl Drop for TestStateRoot {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.path);
        }
    }

    fn connect_after_runtime_start(
        socket_path: &Path,
        state_root: &Path,
    ) -> ProviderMachineRuntime {
        ProviderMachineRuntime::connect_in_state_root(socket_path, token(), state_root).unwrap()
    }

    fn id(value: &str) -> protocol::OpaqueId {
        protocol::OpaqueId::new(value).unwrap()
    }

    fn token() -> protocol::BearerToken {
        protocol::BearerToken::new("runtime-test-token").unwrap()
    }

    fn cache_test_connection(
        runtime: &mut ProviderMachineRuntime,
        connection_id: &str,
        machine_id: &str,
        close_on_drop: bool,
    ) -> OpenConnection {
        let machine_id = id(machine_id);
        let key = key_for_id(&runtime.keys, &machine_id).expect("test machine has a stable key");
        let open = OpenConnection {
            client: runtime.client.clone(),
            connection_id: id(connection_id),
            machine_id,
        };
        let connector: MachineConnectFn =
            Arc::new(|| anyhow::bail!("test connection must be served from the ready cache"));
        runtime.connections.register(key, connector);
        runtime.connection_registry.lock().unwrap().insert(key, open.clone());
        let lease = close_on_drop.then(|| {
            Box::new(ProviderMachineConnectionLease {
                open: open.clone(),
                key,
                registry: runtime.connection_registry.clone(),
            }) as Box<dyn crate::machine_runtime::MachineConnectionLease>
        });
        runtime.connections.insert_ready(
            key,
            MachineConnection {
                session: Session::Local(Mux::new(
                    format!(
                        "provider-test-connection-{}",
                        NEXT_SOCKET_ID.fetch_add(1, Ordering::Relaxed)
                    ),
                    SurfaceOptions::default(),
                )),
                _lease: lease,
            },
        );
        open
    }

    fn install_test_connection(
        runtime: &mut ProviderMachineRuntime,
        connection_id: &str,
        machine_id: &str,
        close_on_drop: bool,
    ) {
        let open = cache_test_connection(runtime, connection_id, machine_id, close_on_drop);
        runtime.open = Some(open);
    }

    fn provider_connect(target: &str) -> MachineRequest {
        MachineRequest::Connect { target: target.into(), route: MachineConnectRoute::Provider }
    }

    fn local_connect(target: &str) -> MachineRequest {
        MachineRequest::Connect { target: target.into(), route: MachineConnectRoute::Local }
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

    fn expect_ui_update(update: MachineUpdate) -> MachineUiState {
        match update {
            MachineUpdate::Ui(ui) => *ui,
            MachineUpdate::DurableNotice(notice) => {
                panic!("expected UI update, received durable notice {notice:?}")
            }
            MachineUpdate::ConnectionProgress { machine_id, latest } => {
                panic!("expected UI update, received progress {machine_id:?}: {latest:?}")
            }
        }
    }

    fn serve_initial_snapshot(
        listener: &UnixListener,
        snapshot: protocol::SnapshotResult,
    ) -> (UnixStream, BufReader<UnixStream>) {
        serve_initial_snapshot_with_capabilities(listener, snapshot, &[])
    }

    fn serve_initial_snapshot_with_capabilities(
        listener: &UnixListener,
        snapshot: protocol::SnapshotResult,
        additional_capabilities: &[&str],
    ) -> (UnixStream, BufReader<UnixStream>) {
        let (stream, _) = listener.accept().unwrap();
        serve_initial_snapshot_on_stream(stream, snapshot, additional_capabilities)
    }

    fn serve_initial_snapshot_on_stream(
        mut stream: UnixStream,
        snapshot: protocol::SnapshotResult,
        additional_capabilities: &[&str],
    ) -> (UnixStream, BufReader<UnixStream>) {
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let hello: protocol::RequestEnvelope = read_frame(&mut reader);
        let protocol::ProviderRequest::Hello(params) = hello.request else {
            panic!("first provider request was not hello");
        };
        assert_eq!(params.token.expose(), "runtime-test-token");
        let capabilities = [
            protocol::MACHINE_LIFECYCLE_CAPABILITY,
            protocol::WORKSPACE_LIFECYCLE_CAPABILITY,
            protocol::WORKSPACE_MIRROR_AUTHORITY_CAPABILITY,
        ]
        .into_iter()
        .chain(additional_capabilities.iter().copied());
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
            .with_capabilities(capabilities),
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

    fn accept_with_timeout(listener: &UnixListener) -> Option<UnixStream> {
        listener.set_nonblocking(true).unwrap();
        let deadline = TestInstant::now() + Duration::from_secs(2);
        loop {
            match listener.accept() {
                Ok((stream, _)) => {
                    stream.set_nonblocking(false).unwrap();
                    return Some(stream);
                }
                Err(error) if error.kind() == IoErrorKind::WouldBlock => {
                    if TestInstant::now() >= deadline {
                        return None;
                    }
                    thread::sleep(Duration::from_millis(10));
                }
                Err(error) => panic!("accept provider connection: {error}"),
            }
        }
    }

    fn negotiate_durable_then_expect_disconnect(listener: &UnixListener) -> bool {
        let Some(mut stream) = accept_with_timeout(listener) else { return false };
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let hello: protocol::RequestEnvelope = read_frame(&mut reader);
        assert!(matches!(hello.request, protocol::ProviderRequest::Hello(_)));
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
            .with_capabilities([protocol::DURABLE_NOTICES_CAPABILITY]),
        );

        let mut next = String::new();
        assert_eq!(
            reader.read_line(&mut next).unwrap(),
            0,
            "identity failure did not stop before durable subscription: {next}"
        );
        true
    }

    fn serve_initial_durable_snapshot(
        listener: &UnixListener,
        snapshot: protocol::SnapshotResult,
        replay: Option<protocol::EventEnvelope>,
    ) -> (UnixStream, BufReader<UnixStream>, protocol::OpaqueId) {
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
                protocol::DURABLE_NOTICES_CAPABILITY,
                protocol::MACHINE_LIFECYCLE_CAPABILITY,
                protocol::WORKSPACE_LIFECYCLE_CAPABILITY,
                protocol::WORKSPACE_MIRROR_AUTHORITY_CAPABILITY,
            ]),
        );

        let subscribe: protocol::RequestEnvelope = read_frame(&mut reader);
        let protocol::ProviderRequest::SubscribeNotices(params) = subscribe.request else {
            panic!("durable notice subscription did not precede the initial snapshot");
        };
        if let Some(event) = replay {
            write_frame(&mut stream, &event);
        }
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::success(
                subscribe.id,
                protocol::SubscribeNoticesResult { sequence: 0 },
            ),
        );

        let request: protocol::RequestEnvelope = read_frame(&mut reader);
        assert!(matches!(request.request, protocol::ProviderRequest::Snapshot(_)));
        write_frame(
            &mut stream,
            &protocol::ResponseEnvelope::success(request.id, snapshot.clone()),
        );
        serve_machine_lifecycle_snapshot(&mut stream, &mut reader, &snapshot);
        (stream, reader, params.consumer_id)
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
                target: protocol::ProviderActionTarget::Scope,
                destructive: false,
                fields: Vec::new(),
            }],
            notice: None,
        }
    }

    fn provider_managed_snapshot(revision: u64) -> protocol::SnapshotResult {
        let mut catalog = snapshot(revision, "Machine", protocol::MachineStatus::Running);
        catalog.machines[0].workspace_create = protocol::WorkspaceCreatePolicy::Provider {
            default_mode: protocol::WorkspaceCreateMode::Isolated,
            modes: vec![protocol::WorkspaceCreateMode::Isolated],
        };
        catalog
    }

    fn active_workspace_snapshot(revision: u64) -> protocol::WorkspaceSnapshotResult {
        protocol::WorkspaceSnapshotResult {
            revision,
            machine_id: id("machine-1"),
            workspaces: vec![protocol::WorkspaceLifecycleDescriptor {
                id: id("workspace-1"),
                display_name: "Before".into(),
                mode: protocol::WorkspaceCreateMode::Isolated,
                status: protocol::WorkspaceLifecycleStatus::Active,
                version: 1,
                recoverable_until: None,
                capabilities: protocol::WorkspaceLifecycleCapabilities {
                    rename: true,
                    delete: true,
                    restore: false,
                    purge: false,
                },
            }],
        }
    }

    fn serve_workspace_snapshot(
        stream: &mut UnixStream,
        reader: &mut BufReader<UnixStream>,
        snapshot: &protocol::WorkspaceSnapshotResult,
    ) {
        let request: protocol::RequestEnvelope = read_frame(reader);
        assert!(matches!(
            &request.request,
            protocol::ProviderRequest::WorkspaceSnapshot(params)
                if params.machine_id == snapshot.machine_id
        ));
        write_frame(stream, &protocol::ResponseEnvelope::success(request.id, snapshot.clone()));
    }

    fn serve_runtime_refresh(
        stream: &mut UnixStream,
        reader: &mut BufReader<UnixStream>,
        catalog: &protocol::SnapshotResult,
        workspace: Option<&protocol::WorkspaceSnapshotResult>,
    ) {
        let refresh: protocol::RequestEnvelope = read_frame(reader);
        assert!(matches!(refresh.request, protocol::ProviderRequest::Snapshot(_)));
        write_frame(stream, &protocol::ResponseEnvelope::success(refresh.id, catalog.clone()));
        serve_machine_lifecycle_snapshot(stream, reader, catalog);
        if let Some(workspace) = workspace {
            serve_workspace_snapshot(stream, reader, workspace);
        }
    }

    #[derive(Clone, Copy, Debug)]
    enum AcceptedMutationKind {
        CreateMachine,
        RenameMachine,
        DeleteMachine,
        RestoreMachine,
        PurgeMachine,
        CreateIsolatedWorkspace,
        CreateHostWorkspace,
        RestoreWorkspace,
        PurgeWorkspace,
        InvokeAction,
    }

    impl AcceptedMutationKind {
        const ALL: [Self; 10] = [
            Self::CreateMachine,
            Self::RenameMachine,
            Self::DeleteMachine,
            Self::RestoreMachine,
            Self::PurgeMachine,
            Self::CreateIsolatedWorkspace,
            Self::CreateHostWorkspace,
            Self::RestoreWorkspace,
            Self::PurgeWorkspace,
            Self::InvokeAction,
        ];
    }

    fn accepted_mutation_request(
        kind: AcceptedMutationKind,
        machine: MachineKey,
    ) -> MachineRequest {
        match kind {
            AcceptedMutationKind::CreateMachine => MachineRequest::Create,
            AcceptedMutationKind::RenameMachine => MachineRequest::RenameManagedMachine {
                machine,
                expected_version: 1,
                name: "Renamed".into(),
            },
            AcceptedMutationKind::DeleteMachine => {
                MachineRequest::DeleteManagedMachine { machine, expected_version: 1 }
            }
            AcceptedMutationKind::RestoreMachine => {
                MachineRequest::RestoreManagedMachine { machine, expected_version: 1 }
            }
            AcceptedMutationKind::PurgeMachine => {
                MachineRequest::PurgeManagedMachine { machine, expected_version: 1 }
            }
            AcceptedMutationKind::CreateIsolatedWorkspace => {
                MachineRequest::CreateManagedIsolatedWorkspace(machine)
            }
            AcceptedMutationKind::CreateHostWorkspace => {
                MachineRequest::CreateManagedHostWorkspace(machine)
            }
            AcceptedMutationKind::RestoreWorkspace => MachineRequest::RestoreManagedWorkspace {
                machine,
                workspace_id: "workspace-1".into(),
                expected_version: 1,
            },
            AcceptedMutationKind::PurgeWorkspace => MachineRequest::PurgeManagedWorkspace {
                machine,
                workspace_id: "workspace-1".into(),
                expected_version: 1,
            },
            AcceptedMutationKind::InvokeAction => MachineRequest::InvokeProviderAction {
                action_id: "billing".into(),
                values: BTreeMap::new(),
                machine_id: None,
                workspace_id: None,
            },
        }
    }

    fn serve_accepted_mutation(
        kind: AcceptedMutationKind,
        stream: &mut UnixStream,
        reader: &mut BufReader<UnixStream>,
    ) {
        let mutation: protocol::RequestEnvelope = read_frame(reader);
        let request_id = mutation.id;
        match (kind, mutation.request) {
            (AcceptedMutationKind::CreateMachine, protocol::ProviderRequest::CreateMachine(_)) => {
                write_frame(
                    stream,
                    &protocol::ResponseEnvelope::success(
                        request_id,
                        protocol::CreateMachineResult {
                            machine_id: id("created-machine"),
                            revision: 2,
                            notice: Some(protocol::ProviderNotice {
                                level: protocol::NoticeLevel::Info,
                                message: format!("accepted {kind:?}"),
                            }),
                        },
                    ),
                );
            }
            (
                AcceptedMutationKind::RenameMachine,
                protocol::ProviderRequest::RenameMachine(params),
            ) if params.display_name == "Renamed" => {
                write_frame(
                    stream,
                    &protocol::ResponseEnvelope::success(
                        request_id,
                        protocol::MachineMutationResult {
                            machine_id: id("machine-1"),
                            version: 2,
                            revision: 2,
                            notice: Some(protocol::ProviderNotice {
                                level: protocol::NoticeLevel::Info,
                                message: format!("accepted {kind:?}"),
                            }),
                        },
                    ),
                );
            }
            (AcceptedMutationKind::DeleteMachine, protocol::ProviderRequest::DeleteMachine(_))
            | (
                AcceptedMutationKind::RestoreMachine,
                protocol::ProviderRequest::RestoreMachine(_),
            )
            | (AcceptedMutationKind::PurgeMachine, protocol::ProviderRequest::PurgeMachine(_)) => {
                write_frame(
                    stream,
                    &protocol::ResponseEnvelope::success(
                        request_id,
                        protocol::MachineMutationResult {
                            machine_id: id("machine-1"),
                            version: 2,
                            revision: 2,
                            notice: Some(protocol::ProviderNotice {
                                level: protocol::NoticeLevel::Info,
                                message: format!("accepted {kind:?}"),
                            }),
                        },
                    ),
                );
            }
            (
                AcceptedMutationKind::CreateIsolatedWorkspace
                | AcceptedMutationKind::CreateHostWorkspace,
                protocol::ProviderRequest::CreateWorkspace(_),
            ) => {
                write_frame(
                    stream,
                    &protocol::ResponseEnvelope::success(
                        request_id,
                        protocol::CreateWorkspaceResult {
                            revision: 2,
                            notice: Some(protocol::ProviderNotice {
                                level: protocol::NoticeLevel::Info,
                                message: format!("accepted {kind:?}"),
                            }),
                        },
                    ),
                );
            }
            (
                AcceptedMutationKind::RestoreWorkspace,
                protocol::ProviderRequest::RestoreWorkspace(_),
            )
            | (
                AcceptedMutationKind::PurgeWorkspace,
                protocol::ProviderRequest::PurgeWorkspace(_),
            ) => {
                write_frame(
                    stream,
                    &protocol::ResponseEnvelope::success(
                        request_id,
                        protocol::WorkspaceMutationResult {
                            workspace_id: id("workspace-1"),
                            version: 2,
                            revision: 2,
                            notice: Some(protocol::ProviderNotice {
                                level: protocol::NoticeLevel::Info,
                                message: format!("accepted {kind:?}"),
                            }),
                        },
                    ),
                );
            }
            (AcceptedMutationKind::InvokeAction, protocol::ProviderRequest::InvokeAction(_)) => {
                write_frame(
                    stream,
                    &protocol::ResponseEnvelope::success(
                        request_id,
                        protocol::InvokeActionResult {
                            revision: 2,
                            notice: Some(protocol::ProviderNotice {
                                level: protocol::NoticeLevel::Info,
                                message: format!("accepted {kind:?}"),
                            }),
                            url: Some("https://example.com/accepted".into()),
                            selected_scope_id: None,
                            selected_machine_id: None,
                        },
                    ),
                );
            }
            (_, request) => panic!("unexpected request for {kind:?}: {request:?}"),
        }
    }

    #[test]
    fn every_accepted_provider_mutation_survives_followup_refresh_failure() {
        let socket = TestProviderSocket::bind();
        let listener = socket.listener();
        let catalog = provider_managed_snapshot(1);
        let workspace = active_workspace_snapshot(1);
        let server_catalog = catalog;
        let server_workspace = workspace;
        let server = thread::spawn(move || {
            let (mut stream, mut reader) =
                serve_initial_snapshot(&listener, server_catalog.clone());
            serve_workspace_snapshot(&mut stream, &mut reader, &server_workspace);
            for kind in AcceptedMutationKind::ALL {
                serve_runtime_refresh(
                    &mut stream,
                    &mut reader,
                    &server_catalog,
                    Some(&server_workspace),
                );
                serve_accepted_mutation(kind, &mut stream, &mut reader);
                let failed_refresh: protocol::RequestEnvelope = read_frame(&mut reader);
                assert!(matches!(failed_refresh.request, protocol::ProviderRequest::Snapshot(_)));
                write_frame(
                    &mut stream,
                    &protocol::ResponseEnvelope::<protocol::SnapshotResult>::failure(
                        failed_refresh.id,
                        protocol::ProviderError {
                            code: protocol::ProviderErrorCode::Unavailable,
                            message: format!("refresh failed after accepted {kind:?}"),
                            retryable: true,
                        },
                    ),
                );
            }
        });

        let mut runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
        let machine = key_for_id(&runtime.keys, &id("machine-1")).unwrap();
        let mut rejected = Vec::new();
        for kind in AcceptedMutationKind::ALL {
            if matches!(kind, AcceptedMutationKind::RenameMachine) {
                install_test_connection(&mut runtime, "open-machine", "machine-1", false);
            }
            match runtime.perform_request(accepted_mutation_request(kind, machine)) {
                Ok(result) => {
                    assert_eq!(result.ui.request, Some(MachineRequest::ReconnectProvider));
                    assert!(
                        result
                            .ui
                            .notice
                            .as_deref()
                            .is_some_and(|notice| notice.contains("refresh failed after accepted")),
                        "accepted {kind:?} did not surface its refresh failure"
                    );
                    assert!(
                        result
                            .ui
                            .notice
                            .as_deref()
                            .is_some_and(|notice| notice.contains(&format!("accepted {kind:?}"))),
                        "accepted {kind:?} lost its provider notice"
                    );
                    if matches!(kind, AcceptedMutationKind::InvokeAction) {
                        assert!(
                            result.ui.notice.as_deref().is_some_and(|notice| {
                                notice.contains("https://example.com/accepted")
                            }),
                            "accepted provider action lost its URL"
                        );
                    }
                    if matches!(kind, AcceptedMutationKind::RenameMachine) {
                        assert_eq!(result.session_label.as_deref(), Some("Renamed"));
                    }
                    if matches!(kind, AcceptedMutationKind::DeleteMachine) {
                        assert!(result.replacement.is_none());
                    }
                    if matches!(kind, AcceptedMutationKind::CreateMachine) {
                        assert_eq!(
                            runtime
                                .accepted_selection
                                .as_ref()
                                .and_then(|selection| selection.machine_id.as_ref())
                                .map(protocol::OpaqueId::as_str),
                            Some("created-machine")
                        );
                    }
                }
                Err(error) => rejected.push(format!("{kind:?}: {error}")),
            }
            runtime.open = None;
        }
        drop(runtime);
        server.join().unwrap();

        assert!(
            rejected.is_empty(),
            "durably accepted mutations were reported as failed:\n{}",
            rejected.join("\n")
        );
    }

    #[test]
    fn accepted_create_selection_survives_workspace_refresh_failure() {
        let socket = TestProviderSocket::bind();
        let listener = socket.listener();
        let initial = provider_managed_snapshot(1);
        let initial_workspace = active_workspace_snapshot(1);
        let mut created = initial.clone();
        created.revision = 2;
        let mut created_machine = created.machines[0].clone();
        created_machine.id = id("created-machine");
        created_machine.display_name = "Created".into();
        created.machines.push(created_machine);
        let created_workspace = protocol::WorkspaceSnapshotResult {
            revision: 2,
            machine_id: id("created-machine"),
            workspaces: Vec::new(),
        };
        let server_initial = initial.clone();
        let server_created = created.clone();
        let server = thread::spawn(move || {
            let (mut stream, mut reader) =
                serve_initial_snapshot(&listener, server_initial.clone());
            serve_workspace_snapshot(&mut stream, &mut reader, &initial_workspace);
            serve_runtime_refresh(
                &mut stream,
                &mut reader,
                &server_initial,
                Some(&initial_workspace),
            );

            let create: protocol::RequestEnvelope = read_frame(&mut reader);
            assert!(matches!(create.request, protocol::ProviderRequest::CreateMachine(_)));
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::success(
                    create.id,
                    protocol::CreateMachineResult {
                        machine_id: id("created-machine"),
                        revision: 2,
                        notice: Some(protocol::ProviderNotice {
                            level: protocol::NoticeLevel::Info,
                            message: "create accepted".into(),
                        }),
                    },
                ),
            );

            let refresh: protocol::RequestEnvelope = read_frame(&mut reader);
            assert!(matches!(refresh.request, protocol::ProviderRequest::Snapshot(_)));
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::success(refresh.id, server_created.clone()),
            );
            serve_machine_lifecycle_snapshot(&mut stream, &mut reader, &server_created);
            let workspace: protocol::RequestEnvelope = read_frame(&mut reader);
            assert!(matches!(
                &workspace.request,
                protocol::ProviderRequest::WorkspaceSnapshot(params)
                    if params.machine_id == id("created-machine")
            ));
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::<protocol::WorkspaceSnapshotResult>::failure(
                    workspace.id,
                    protocol::ProviderError {
                        code: protocol::ProviderErrorCode::Unavailable,
                        message: "created workspace refresh failed".into(),
                        retryable: true,
                    },
                ),
            );

            let (mut stream, mut reader) =
                serve_initial_snapshot(&listener, server_created.clone());
            serve_workspace_snapshot(&mut stream, &mut reader, &initial_workspace);
            serve_machine_lifecycle_snapshot(&mut stream, &mut reader, &server_created);
            serve_workspace_snapshot(&mut stream, &mut reader, &created_workspace);
        });

        let mut runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
        let result = runtime.perform_request(MachineRequest::Create).unwrap();
        assert_eq!(result.ui.request, Some(MachineRequest::ReconnectProvider));
        assert_eq!(runtime.snapshot, initial, "failed install mixed provider state");
        assert!(result.ui.notice.as_deref().is_some_and(|notice| {
            notice.contains("create accepted")
                && notice.contains("created workspace refresh failed")
        }));
        assert_eq!(
            runtime
                .accepted_selection
                .as_ref()
                .and_then(|selection| selection.machine_id.as_ref())
                .map(protocol::OpaqueId::as_str),
            Some("created-machine")
        );

        runtime.reconnect_control().unwrap();
        assert_eq!(runtime.snapshot.selected_machine_id, Some(id("created-machine")));
        assert_eq!(
            runtime.workspace_snapshot.as_ref().map(|snapshot| &snapshot.machine_id),
            Some(&id("created-machine"))
        );
        assert!(runtime.accepted_selection.is_none());
        drop(runtime);
        server.join().unwrap();
    }

    #[test]
    fn accepted_action_selection_and_messages_survive_scope_refresh_failure() {
        let socket = TestProviderSocket::bind();
        let listener = socket.listener();
        let mut personal = provider_managed_snapshot(1);
        personal.scopes.push(protocol::ScopeDescriptor {
            id: id("team-1"),
            display_name: "Team".into(),
            kind: protocol::ScopeKind::Team,
            can_admin: true,
        });
        let personal_workspace = active_workspace_snapshot(1);
        let mut team = personal.clone();
        team.revision = 2;
        team.selected_scope_id = id("team-1");
        team.machines[0].id = id("team-default");
        team.machines[0].display_name = "Team default".into();
        let mut selected_machine = team.machines[0].clone();
        selected_machine.id = id("team-selected");
        selected_machine.display_name = "Team selected".into();
        team.machines.push(selected_machine);
        team.selected_machine_id = Some(id("team-default"));
        let selected_workspace = protocol::WorkspaceSnapshotResult {
            revision: 2,
            machine_id: id("team-selected"),
            workspaces: Vec::new(),
        };
        let server_personal = personal.clone();
        let server_team = team.clone();
        let server = thread::spawn(move || {
            let (mut stream, mut reader) =
                serve_initial_snapshot(&listener, server_personal.clone());
            serve_workspace_snapshot(&mut stream, &mut reader, &personal_workspace);
            serve_runtime_refresh(
                &mut stream,
                &mut reader,
                &server_personal,
                Some(&personal_workspace),
            );

            let action: protocol::RequestEnvelope = read_frame(&mut reader);
            assert!(matches!(action.request, protocol::ProviderRequest::InvokeAction(_)));
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::success(
                    action.id,
                    protocol::InvokeActionResult {
                        revision: 2,
                        notice: Some(protocol::ProviderNotice {
                            level: protocol::NoticeLevel::Info,
                            message: "action accepted".into(),
                        }),
                        url: Some("https://example.com/action".into()),
                        selected_scope_id: Some(id("team-1")),
                        selected_machine_id: Some(id("team-selected")),
                    },
                ),
            );
            let failed_select: protocol::RequestEnvelope = read_frame(&mut reader);
            assert!(matches!(
                &failed_select.request,
                protocol::ProviderRequest::SelectScope(params)
                    if params.scope_id == id("team-1")
            ));
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::<protocol::SelectScopeResult>::failure(
                    failed_select.id,
                    protocol::ProviderError {
                        code: protocol::ProviderErrorCode::Unavailable,
                        message: "team scope refresh failed".into(),
                        retryable: true,
                    },
                ),
            );

            let select: protocol::RequestEnvelope = read_frame(&mut reader);
            assert!(matches!(
                &select.request,
                protocol::ProviderRequest::SelectScope(params)
                    if params.scope_id == id("team-1")
            ));
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::success(
                    select.id,
                    protocol::SelectScopeResult { snapshot: server_team.clone() },
                ),
            );
            serve_machine_lifecycle_snapshot(&mut stream, &mut reader, &server_team);
            serve_workspace_snapshot(&mut stream, &mut reader, &selected_workspace);
        });

        let mut runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
        let result = runtime
            .perform_request(MachineRequest::InvokeProviderAction {
                action_id: "billing".into(),
                values: BTreeMap::new(),
                machine_id: None,
                workspace_id: None,
            })
            .unwrap();
        assert_eq!(result.ui.request, Some(MachineRequest::ReconnectProvider));
        assert_eq!(runtime.snapshot, personal, "failed scope install mixed provider state");
        assert!(result.ui.notice.as_deref().is_some_and(|notice| {
            notice.contains("action accepted")
                && notice.contains("https://example.com/action")
                && notice.contains("team scope refresh failed")
        }));

        runtime.refresh().unwrap();
        assert_eq!(runtime.snapshot.selected_scope_id, id("team-1"));
        assert_eq!(runtime.snapshot.selected_machine_id, Some(id("team-selected")));
        assert_eq!(
            runtime.workspace_snapshot.as_ref().map(|snapshot| &snapshot.machine_id),
            Some(&id("team-selected"))
        );
        assert!(runtime.accepted_selection.is_none());
        drop(runtime);
        server.join().unwrap();
    }

    #[test]
    fn accepted_open_machine_delete_retires_session_when_refresh_fails() {
        let socket = TestProviderSocket::bind();
        let listener = socket.listener();
        let catalog = snapshot(1, "Deleted machine", protocol::MachineStatus::Running);
        let server_catalog = catalog;
        let server = thread::spawn(move || {
            let (mut stream, mut reader) =
                serve_initial_snapshot(&listener, server_catalog.clone());
            serve_runtime_refresh(&mut stream, &mut reader, &server_catalog, None);

            let delete: protocol::RequestEnvelope = read_frame(&mut reader);
            assert!(matches!(delete.request, protocol::ProviderRequest::DeleteMachine(_)));
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::success(
                    delete.id,
                    protocol::MachineMutationResult {
                        machine_id: id("machine-1"),
                        version: 2,
                        revision: 2,
                        notice: None,
                    },
                ),
            );
            let failed_refresh: protocol::RequestEnvelope = read_frame(&mut reader);
            assert!(matches!(failed_refresh.request, protocol::ProviderRequest::Snapshot(_)));
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::<protocol::SnapshotResult>::failure(
                    failed_refresh.id,
                    protocol::ProviderError {
                        code: protocol::ProviderErrorCode::Unavailable,
                        message: "delete refresh failed".into(),
                        retryable: true,
                    },
                ),
            );

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
                    protocol::CloseMachineResult { revision: 3 },
                ),
            );
        });

        let mut runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
        let machine = key_for_id(&runtime.keys, &id("machine-1")).unwrap();
        install_test_connection(&mut runtime, "deleted-open", "machine-1", true);
        let result = runtime
            .perform_request(MachineRequest::DeleteManagedMachine { machine, expected_version: 1 })
            .unwrap();
        assert!(result.replacement.is_some());
        assert!(result.restart_updates);
        assert!(!result.ui.session_available);
        assert!(runtime.pending.as_ref().is_some_and(|pending| pending.retire_open_on_abort));

        runtime.abort_replacement();
        assert!(runtime.open.is_none(), "aborted preparation retained a deleted session");
        drop(result);
        drop(runtime);
        server.join().unwrap();
    }

    #[test]
    fn accepted_scope_selection_survives_lifecycle_refresh_failure() {
        let socket = TestProviderSocket::bind();
        let listener = socket.listener();
        let catalog = provider_managed_snapshot(1);
        let workspace = active_workspace_snapshot(1);
        let server_catalog = catalog;
        let server_workspace = workspace;
        let server = thread::spawn(move || {
            let (mut stream, mut reader) =
                serve_initial_snapshot(&listener, server_catalog.clone());
            serve_workspace_snapshot(&mut stream, &mut reader, &server_workspace);
            serve_runtime_refresh(
                &mut stream,
                &mut reader,
                &server_catalog,
                Some(&server_workspace),
            );

            let select: protocol::RequestEnvelope = read_frame(&mut reader);
            assert!(matches!(
                &select.request,
                protocol::ProviderRequest::SelectScope(params)
                    if params.scope_id == id("personal")
            ));
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::success(
                    select.id,
                    protocol::SelectScopeResult { snapshot: server_catalog },
                ),
            );
            let lifecycle: protocol::RequestEnvelope = read_frame(&mut reader);
            assert!(matches!(
                lifecycle.request,
                protocol::ProviderRequest::MachineLifecycleSnapshot(_)
            ));
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::<protocol::MachineLifecycleSnapshotResult>::failure(
                    lifecycle.id,
                    protocol::ProviderError {
                        code: protocol::ProviderErrorCode::Unavailable,
                        message: "scope lifecycle refresh failed after acceptance".into(),
                        retryable: true,
                    },
                ),
            );
        });

        let mut runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
        let result = runtime
            .perform_request(MachineRequest::SelectProviderScope("personal".into()))
            .expect("an accepted scope selection must survive a lifecycle refresh error");
        assert_eq!(result.ui.request, Some(MachineRequest::ReconnectProvider));
        assert!(
            result
                .ui
                .notice
                .as_deref()
                .is_some_and(|notice| notice.contains("scope lifecycle refresh failed"))
        );
        drop(runtime);
        server.join().unwrap();
    }

    fn assert_accepted_workspace_mutation_survives_refresh_error(delete: bool) {
        let socket = TestProviderSocket::bind();
        let listener = socket.listener();
        let catalog = provider_managed_snapshot(1);
        let workspace = active_workspace_snapshot(1);
        let server_catalog = catalog;
        let server_workspace = workspace;
        let server = thread::spawn(move || {
            let (mut stream, mut reader) =
                serve_initial_snapshot(&listener, server_catalog.clone());
            serve_workspace_snapshot(&mut stream, &mut reader, &server_workspace);

            let refresh: protocol::RequestEnvelope = read_frame(&mut reader);
            assert!(matches!(refresh.request, protocol::ProviderRequest::Snapshot(_)));
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::success(refresh.id, server_catalog.clone()),
            );
            serve_machine_lifecycle_snapshot(&mut stream, &mut reader, &server_catalog);
            serve_workspace_snapshot(&mut stream, &mut reader, &server_workspace);

            let mutation: protocol::RequestEnvelope = read_frame(&mut reader);
            if delete {
                assert!(matches!(
                    mutation.request,
                    protocol::ProviderRequest::DeleteWorkspace(ref params)
                        if params.workspace_id == id("workspace-1")
                ));
            } else {
                assert!(matches!(
                    mutation.request,
                    protocol::ProviderRequest::RenameWorkspace(ref params)
                        if params.workspace_id == id("workspace-1")
                            && params.display_name == "After"
                ));
            }
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::success(
                    mutation.id,
                    protocol::WorkspaceMutationResult {
                        workspace_id: id("workspace-1"),
                        version: 2,
                        revision: 2,
                        notice: None,
                    },
                ),
            );

            let failed_refresh: protocol::RequestEnvelope = read_frame(&mut reader);
            assert!(matches!(failed_refresh.request, protocol::ProviderRequest::Snapshot(_)));
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::<protocol::SnapshotResult>::failure(
                    failed_refresh.id,
                    protocol::ProviderError {
                        code: protocol::ProviderErrorCode::Unavailable,
                        message: "refresh failed after commit".into(),
                        retryable: true,
                    },
                ),
            );
        });

        let mut runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
        let machine = key_for_id(&runtime.keys, &id("machine-1")).unwrap();
        let request = if delete {
            MachineRequest::DeleteManagedWorkspace {
                machine,
                workspace_id: "workspace-1".into(),
                expected_version: 1,
            }
        } else {
            MachineRequest::RenameManagedWorkspace {
                machine,
                workspace_id: "workspace-1".into(),
                expected_version: 1,
                name: "After".into(),
            }
        };

        let result = runtime
            .perform_request(request)
            .expect("an accepted workspace mutation must survive a refresh error");
        match (delete, result.session_mutation) {
            (false, Some(ManagedWorkspaceSessionMutation::Rename { workspace_key, name })) => {
                assert_eq!(workspace_key, "workspace-1");
                assert_eq!(name, "After");
            }
            (true, Some(ManagedWorkspaceSessionMutation::Close { workspace_key })) => {
                assert_eq!(workspace_key, "workspace-1");
            }
            _ => panic!("accepted provider mutation did not reach the nested mux"),
        }
        assert_eq!(result.ui.request, Some(MachineRequest::ReconnectProvider));
        assert!(
            result
                .ui
                .notice
                .as_deref()
                .is_some_and(|notice| notice.contains("refresh failed after commit"))
        );
        drop(runtime);
        server.join().unwrap();
    }

    #[test]
    fn accepted_workspace_rename_survives_refresh_error() {
        assert_accepted_workspace_mutation_survives_refresh_error(false);
    }

    #[test]
    fn accepted_workspace_delete_survives_refresh_error() {
        assert_accepted_workspace_mutation_survives_refresh_error(true);
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
            actions: vec![
                protocol::ProviderAction {
                    id: id("invite"),
                    label: "Invite member".into(),
                    target: protocol::ProviderActionTarget::Scope,
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
                },
                protocol::ProviderAction {
                    id: id("future-action"),
                    label: "Future action".into(),
                    target: protocol::ProviderActionTarget::Unsupported,
                    destructive: false,
                    fields: Vec::new(),
                },
            ],
            notice: None,
        };

        let presentation = provider_presentation(&snapshot);
        assert!(presentation.scopes[0].can_admin);
        assert_eq!(presentation.selected_scope().unwrap().name, "Acme");
        assert_eq!(presentation.actions.len(), 1);
        assert_eq!(presentation.actions[0].fields[0].kind, ProviderActionFieldKind::Email);
    }

    #[test]
    fn targeted_actions_are_negotiated_before_the_initial_snapshot() {
        let socket = TestProviderSocket::bind();
        let listener = socket.listener();
        let mut targeted = snapshot(1, "Machine", protocol::MachineStatus::Running);
        targeted.actions[0].target = protocol::ProviderActionTarget::SelectedWorkspace;
        let (finish, finished) = mpsc::channel();
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
                        provider_id: id("test-provider"),
                        provider_name: "Test Provider".into(),
                        negotiated_version: protocol::Version,
                    },
                )
                .with_capabilities([
                    protocol::CLIENT_CAPABILITY_NEGOTIATION_CAPABILITY,
                    protocol::DURABLE_NOTICES_CAPABILITY,
                    protocol::MACHINE_LIFECYCLE_CAPABILITY,
                ]),
            );

            let negotiation: protocol::RequestEnvelope = read_frame(&mut reader);
            let protocol::ProviderRequest::NegotiateClientCapabilities(params) =
                negotiation.request
            else {
                panic!("client capability negotiation did not immediately follow hello");
            };
            assert_eq!(
                params.capabilities,
                [
                    protocol::PROVIDER_ACTION_TARGETS_CLIENT_CAPABILITY,
                    protocol::CONNECTION_PROGRESS_CLIENT_CAPABILITY,
                ]
            );
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::success(
                    negotiation.id,
                    protocol::NegotiateClientCapabilitiesResult {
                        capabilities: vec![
                            protocol::PROVIDER_ACTION_TARGETS_CLIENT_CAPABILITY.to_string(),
                        ],
                    },
                ),
            );

            let subscribe: protocol::RequestEnvelope = read_frame(&mut reader);
            assert!(matches!(subscribe.request, protocol::ProviderRequest::SubscribeNotices(_)));
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::success(
                    subscribe.id,
                    protocol::SubscribeNoticesResult { sequence: 0 },
                ),
            );

            let request: protocol::RequestEnvelope = read_frame(&mut reader);
            assert!(matches!(request.request, protocol::ProviderRequest::Snapshot(_)));
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::success(request.id, targeted.clone()),
            );
            serve_machine_lifecycle_snapshot(&mut stream, &mut reader, &targeted);
            finished.recv_timeout(Duration::from_secs(1)).unwrap();
        });

        let runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
        assert_eq!(
            runtime.snapshot.actions[0].target,
            protocol::ProviderActionTarget::SelectedWorkspace
        );
        finish.send(()).unwrap();
        server.join().unwrap();
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
    fn negotiated_external_connect_routes_opaque_input_to_provider_selection_path() {
        let socket = TestProviderSocket::bind();
        let listener = socket.listener();
        let mut initial = snapshot(1, "Existing", protocol::MachineStatus::Running);
        initial.capabilities.connect_external_machine = true;
        let mut enrolled = initial.clone();
        enrolled.revision = 2;
        enrolled.machines.push(protocol::MachineDescriptor {
            id: id("paired-machine"),
            display_name: "Paired mini".into(),
            subtitle: "external".into(),
            status: protocol::MachineStatus::Running,
            connectable: true,
            workspace_create: protocol::WorkspaceCreatePolicy::Session,
        });
        enrolled.selected_machine_id = Some(id("paired-machine"));
        let server_initial = initial;
        let server_enrolled = enrolled.clone();
        let (finish, finished) = mpsc::channel();
        let server = thread::spawn(move || {
            let (mut stream, mut reader) = serve_initial_snapshot_with_capabilities(
                &listener,
                server_initial.clone(),
                &[protocol::EXTERNAL_MACHINE_CONNECT_CAPABILITY],
            );
            serve_runtime_refresh(&mut stream, &mut reader, &server_initial, None);

            let request: protocol::RequestEnvelope = read_frame(&mut reader);
            let protocol::ProviderRequest::ConnectExternalMachine(params) = request.request else {
                panic!("connect request did not use the provider protocol");
            };
            assert_eq!(params.scope_id, id("personal"));
            assert_eq!(params.specifier.expose(), "PAIR 4J7K;$(opaque)");
            assert!(params.mutation_id.as_str().starts_with("cmux-"));
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::success(
                    request.id,
                    protocol::ConnectExternalMachineResult {
                        machine_id: id("paired-machine"),
                        revision: 2,
                        notice: Some(protocol::ProviderNotice {
                            level: protocol::NoticeLevel::Info,
                            message: "Paired machine enrolled".into(),
                        }),
                    },
                ),
            );
            serve_runtime_refresh(&mut stream, &mut reader, &server_enrolled, None);
            finished.recv().unwrap();
        });

        let provider = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
        let mut controller = ProviderMachineController::for_test(
            provider,
            MachineRuntime::external(Vec::new(), true),
            Some(MachineKey(crate::machine_runtime::CLIENT_MACHINE_KEY_START)),
            false,
        );
        let result = controller.perform_request(provider_connect("PAIR 4J7K;$(opaque)")).unwrap();

        let paired = result
            .ui
            .snapshot
            .machines
            .iter()
            .find(|machine| machine.id == "paired-machine")
            .unwrap();
        assert_eq!(result.ui.snapshot.active, Some(paired.key));
        assert_eq!(result.ui.request, Some(MachineRequest::Switch(paired.key)));
        assert_eq!(result.ui.notice.as_deref(), Some("Paired machine enrolled"));
        assert!(
            result.ui.snapshot.machines.iter().all(|machine| !machine.id.starts_with("ssh:")),
            "provider-owned input leaked into the client-local SSH catalog"
        );

        finish.send(()).unwrap();
        controller.close();
        server.join().unwrap();
    }

    #[test]
    fn accepted_external_connect_reconnect_keeps_provider_switch_over_local_session() {
        let socket = TestProviderSocket::bind();
        let listener = socket.listener();
        let mut initial = snapshot(1, "Existing", protocol::MachineStatus::Running);
        initial.capabilities.connect_external_machine = true;
        let mut enrolled = initial.clone();
        enrolled.revision = 2;
        enrolled.machines.push(protocol::MachineDescriptor {
            id: id("paired-machine"),
            display_name: "Paired mini".into(),
            subtitle: "external".into(),
            status: protocol::MachineStatus::Running,
            connectable: false,
            workspace_create: protocol::WorkspaceCreatePolicy::Session,
        });
        enrolled.selected_machine_id = Some(id("paired-machine"));
        let server_initial = initial;
        let server_enrolled = enrolled;
        let (finish, finished) = mpsc::channel();
        let server = thread::spawn(move || {
            {
                let (mut stream, mut reader) = serve_initial_snapshot_with_capabilities(
                    &listener,
                    server_initial.clone(),
                    &[protocol::EXTERNAL_MACHINE_CONNECT_CAPABILITY],
                );
                serve_runtime_refresh(&mut stream, &mut reader, &server_initial, None);
                let connect: protocol::RequestEnvelope = read_frame(&mut reader);
                assert!(matches!(
                    connect.request,
                    protocol::ProviderRequest::ConnectExternalMachine(_)
                ));
                write_frame(
                    &mut stream,
                    &protocol::ResponseEnvelope::success(
                        connect.id,
                        protocol::ConnectExternalMachineResult {
                            machine_id: id("paired-machine"),
                            revision: 2,
                            notice: None,
                        },
                    ),
                );
                let refresh: protocol::RequestEnvelope = read_frame(&mut reader);
                assert!(matches!(refresh.request, protocol::ProviderRequest::Snapshot(_)));
                write_frame(
                    &mut stream,
                    &protocol::ResponseEnvelope::<protocol::SnapshotResult>::failure(
                        refresh.id,
                        protocol::ProviderError {
                            code: protocol::ProviderErrorCode::Unavailable,
                            message: "accepted pairing refresh failed".into(),
                            retryable: true,
                        },
                    ),
                );
            }

            let (_stream, _reader) = serve_initial_snapshot_with_capabilities(
                &listener,
                server_enrolled,
                &[protocol::EXTERNAL_MACHINE_CONNECT_CAPABILITY],
            );
            finished.recv().unwrap();
        });

        let provider = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
        let mut controller = ProviderMachineController::for_test(
            provider,
            MachineRuntime::external(Vec::new(), true),
            Some(MachineKey(crate::machine_runtime::CLIENT_MACHINE_KEY_START)),
            false,
        );
        let accepted = controller.perform_request(provider_connect("PAIR 4J7K")).unwrap();
        assert_eq!(accepted.ui.request, Some(MachineRequest::ReconnectProvider));

        let reconnected = controller.perform_request(MachineRequest::ReconnectProvider).unwrap();
        let local_key = MachineKey(crate::machine_runtime::CLIENT_MACHINE_KEY_START);
        assert_eq!(reconnected.ui.snapshot.active, Some(local_key));
        assert!(reconnected.ui.request.is_none());

        controller.provider.snapshot.machines[1].connectable = true;
        let provider_update = controller.provider.ui_state_for_open_connection();
        let available = controller.merge_local_ui(provider_update);
        let paired = reconnected
            .ui
            .snapshot
            .machines
            .iter()
            .find(|machine| machine.id == "paired-machine")
            .unwrap();
        assert_eq!(available.snapshot.active, Some(paired.key));
        assert_eq!(available.request, Some(MachineRequest::Switch(paired.key)));

        finish.send(()).unwrap();
        controller.close();
        server.join().unwrap();
    }

    #[test]
    fn retryable_external_connect_error_reuses_mutation_id() {
        let socket = TestProviderSocket::bind();
        let listener = socket.listener();
        let mut catalog = snapshot(1, "Existing", protocol::MachineStatus::Running);
        catalog.capabilities.connect_external_machine = true;
        let mut enrolled = catalog.clone();
        enrolled.revision = 2;
        enrolled.selected_machine_id = Some(id("machine-1"));
        enrolled.machines[0].connectable = true;
        let server_catalog = catalog;
        let server = thread::spawn(move || {
            let (mut stream, mut reader) = serve_initial_snapshot_with_capabilities(
                &listener,
                server_catalog.clone(),
                &[protocol::EXTERNAL_MACHINE_CONNECT_CAPABILITY],
            );
            serve_runtime_refresh(&mut stream, &mut reader, &server_catalog, None);
            let first: protocol::RequestEnvelope = read_frame(&mut reader);
            let protocol::ProviderRequest::ConnectExternalMachine(first_params) = first.request
            else {
                panic!("first request was not external connect");
            };
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::<protocol::ConnectExternalMachineResult>::failure(
                    first.id,
                    protocol::ProviderError {
                        code: protocol::ProviderErrorCode::Unavailable,
                        message: "pairing outcome unknown".into(),
                        retryable: true,
                    },
                ),
            );

            serve_runtime_refresh(&mut stream, &mut reader, &server_catalog, None);
            let retry: protocol::RequestEnvelope = read_frame(&mut reader);
            let protocol::ProviderRequest::ConnectExternalMachine(retry_params) = retry.request
            else {
                panic!("retry request was not external connect");
            };
            assert_eq!(retry_params.specifier, first_params.specifier);
            assert_eq!(retry_params.mutation_id, first_params.mutation_id);
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::success(
                    retry.id,
                    protocol::ConnectExternalMachineResult {
                        machine_id: id("machine-1"),
                        revision: 2,
                        notice: None,
                    },
                ),
            );
            serve_runtime_refresh(&mut stream, &mut reader, &enrolled, None);
        });

        let mut runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
        let Err(first) = runtime.perform_external_connect("PAIR 4J7K".into()) else {
            panic!("retryable provider error unexpectedly completed external connect");
        };
        assert!(first.to_string().contains("pairing outcome unknown"));
        let retry = runtime.perform_external_connect("PAIR 4J7K".into()).unwrap();

        assert!(retry.ui.request.is_some());
        runtime.close();
        server.join().unwrap();
    }

    #[test]
    fn selecting_provider_scope_cancels_ambiguous_external_connect() {
        let socket = TestProviderSocket::bind();
        let listener = socket.listener();
        let mut personal = snapshot(1, "Existing", protocol::MachineStatus::Running);
        personal.scopes.push(protocol::ScopeDescriptor {
            id: id("team-1"),
            display_name: "Team".into(),
            kind: protocol::ScopeKind::Team,
            can_admin: true,
        });
        let mut team = personal.clone();
        team.revision = 2;
        team.selected_scope_id = id("team-1");
        let server_personal = personal.clone();
        let server = thread::spawn(move || {
            let (mut stream, mut reader) =
                serve_initial_snapshot(&listener, server_personal.clone());
            serve_runtime_refresh(&mut stream, &mut reader, &server_personal, None);

            let select: protocol::RequestEnvelope = read_frame(&mut reader);
            assert!(matches!(
                &select.request,
                protocol::ProviderRequest::SelectScope(params)
                    if params.scope_id == id("team-1")
            ));
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::success(
                    select.id,
                    protocol::SelectScopeResult { snapshot: team.clone() },
                ),
            );
            serve_machine_lifecycle_snapshot(&mut stream, &mut reader, &team);
        });

        let mut runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
        runtime.pending_external_connect = Some(PendingExternalConnect {
            scope_id: personal.selected_scope_id,
            specifier: protocol::ExternalMachineSpecifier::new("PAIR 4J7K").unwrap(),
            mutation_id: id("old-scope-mutation"),
        });

        runtime.perform_request(MachineRequest::SelectProviderScope("team-1".into())).unwrap();

        assert!(
            runtime.pending_external_connect.is_none(),
            "an accepted scope selection must cancel the old scope's ambiguous connect"
        );
        drop(runtime);
        server.join().unwrap();
    }

    #[test]
    fn capability_revocation_fails_the_presented_provider_route_closed() {
        let socket = TestProviderSocket::bind();
        let listener = socket.listener();
        let mut initial = snapshot(1, "Existing", protocol::MachineStatus::Running);
        initial.capabilities.connect_external_machine = true;
        let mut revoked = initial.clone();
        revoked.revision = 2;
        revoked.capabilities.connect_external_machine = false;
        let server = thread::spawn(move || {
            let (mut stream, mut reader) = serve_initial_snapshot_with_capabilities(
                &listener,
                initial,
                &[protocol::EXTERNAL_MACHINE_CONNECT_CAPABILITY],
            );
            serve_runtime_refresh(&mut stream, &mut reader, &revoked, None);
            stream.set_read_timeout(Some(Duration::from_millis(250))).unwrap();
            let mut unexpected = String::new();
            match reader.read_line(&mut unexpected) {
                Err(error)
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) => {}
                Ok(0) => {}
                Ok(_) => panic!("revoked provider received connect input: {unexpected}"),
                Err(error) => panic!("provider read failed: {error}"),
            }
        });

        let provider = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
        let mut controller = ProviderMachineController::for_test(
            provider,
            MachineRuntime::external(Vec::new(), true),
            None,
            false,
        );
        let Err(error) = controller.perform_request(provider_connect("PAIR 4J7K")) else {
            panic!("revoked provider unexpectedly handled external connect");
        };

        assert_eq!(
            error.to_string(),
            localization::catalog().sidebar.machine_provider_external_connect_unsupported
        );
        controller.close();
        server.join().unwrap();
    }

    #[test]
    fn ambiguous_protocol_failure_reuses_external_connect_mutation_id_after_reconnect() {
        let socket = TestProviderSocket::bind();
        let listener = socket.listener();
        let mut catalog = snapshot(1, "Existing", protocol::MachineStatus::Running);
        catalog.capabilities.connect_external_machine = true;
        let mut enrolled = catalog.clone();
        enrolled.revision = 2;
        enrolled.machines[0].connectable = true;
        let server_catalog = catalog;
        let (finish, finished) = mpsc::channel();
        let server = thread::spawn(move || {
            let first_mutation_id = {
                let (mut stream, mut reader) = serve_initial_snapshot_with_capabilities(
                    &listener,
                    server_catalog.clone(),
                    &[protocol::EXTERNAL_MACHINE_CONNECT_CAPABILITY],
                );
                serve_runtime_refresh(&mut stream, &mut reader, &server_catalog, None);
                let request: protocol::RequestEnvelope = read_frame(&mut reader);
                let protocol::ProviderRequest::ConnectExternalMachine(params) = request.request
                else {
                    panic!("first request was not external connect");
                };
                assert_eq!(params.specifier.expose(), "PAIR 4J7K");
                stream.write_all(b"{\"invalid\":}\n").unwrap();
                stream.flush().unwrap();
                params.mutation_id
            };

            let (mut stream, mut reader) = serve_initial_snapshot_with_capabilities(
                &listener,
                server_catalog.clone(),
                &[protocol::EXTERNAL_MACHINE_CONNECT_CAPABILITY],
            );
            serve_runtime_refresh(&mut stream, &mut reader, &server_catalog, None);
            let request: protocol::RequestEnvelope = read_frame(&mut reader);
            let protocol::ProviderRequest::ConnectExternalMachine(params) = request.request else {
                panic!("retry request was not external connect");
            };
            assert_eq!(params.specifier.expose(), "PAIR 4J7K");
            assert_eq!(params.mutation_id, first_mutation_id);
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::success(
                    request.id,
                    protocol::ConnectExternalMachineResult {
                        machine_id: id("machine-1"),
                        revision: enrolled.revision,
                        notice: None,
                    },
                ),
            );
            serve_runtime_refresh(&mut stream, &mut reader, &enrolled, None);
            finished.recv().unwrap();
        });

        let provider = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
        let mut controller = ProviderMachineController::for_test(
            provider,
            MachineRuntime::external(Vec::new(), true),
            None,
            false,
        );
        let Err(first_error) = controller.perform_request(provider_connect("PAIR 4J7K")) else {
            panic!("invalid provider response unexpectedly completed external connect");
        };
        assert!(first_error.to_string().contains("protocol error"));
        for unrelated in ["PAIR 9ZZZ", "not a valid local machine"] {
            let Err(error) = controller.perform_request(provider_connect(unrelated)) else {
                panic!("unrelated input discarded an ambiguous external connect");
            };
            assert_eq!(
                error.to_string(),
                localization::catalog().sidebar.machine_provider_external_connect_ambiguous
            );
        }
        let Err(retry_while_disconnected) =
            controller.perform_request(provider_connect("PAIR 4J7K"))
        else {
            panic!("ambiguous connect retry was rerouted while its provider was disconnected");
        };
        assert_eq!(
            retry_while_disconnected.to_string(),
            localization::catalog().sidebar.machine_provider_disconnected
        );
        controller.provider.reconnect_control().unwrap();
        let result = controller.perform_request(provider_connect("PAIR 4J7K")).unwrap();

        let connected =
            result.ui.snapshot.machines.iter().find(|machine| machine.id == "machine-1").unwrap();
        assert_eq!(result.ui.request, Some(MachineRequest::Switch(connected.key)));
        finish.send(()).unwrap();
        controller.close();
        server.join().unwrap();
    }

    #[test]
    fn ambiguous_external_connect_does_not_fall_back_after_capability_revocation() {
        let socket = TestProviderSocket::bind();
        let listener = socket.listener();
        let mut supported = snapshot(1, "Existing", protocol::MachineStatus::Running);
        supported.capabilities.connect_external_machine = true;
        let mut revoked = supported.clone();
        revoked.revision = 2;
        revoked.capabilities.connect_external_machine = false;
        let server = thread::spawn(move || {
            {
                let (mut stream, mut reader) = serve_initial_snapshot_with_capabilities(
                    &listener,
                    supported.clone(),
                    &[protocol::EXTERNAL_MACHINE_CONNECT_CAPABILITY],
                );
                serve_runtime_refresh(&mut stream, &mut reader, &supported, None);
                let request: protocol::RequestEnvelope = read_frame(&mut reader);
                assert!(matches!(
                    request.request,
                    protocol::ProviderRequest::ConnectExternalMachine(_)
                ));
            }

            let (stream, mut reader) =
                serve_initial_snapshot_with_capabilities(&listener, revoked, &[]);
            stream.set_read_timeout(Some(Duration::from_millis(250))).unwrap();
            let mut unexpected = String::new();
            match reader.read_line(&mut unexpected) {
                Err(error)
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) => {}
                Ok(0) => {}
                Ok(_) => panic!("ambiguous retry was rerouted after capability loss: {unexpected}"),
                Err(error) => panic!("provider read failed: {error}"),
            }
        });

        let provider = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
        let mut controller = ProviderMachineController::for_test(
            provider,
            MachineRuntime::external(Vec::new(), true),
            None,
            false,
        );
        assert!(controller.perform_request(provider_connect("PAIR 4J7K")).is_err());
        controller.provider.reconnect_control().unwrap();

        let Err(error) = controller.perform_request(provider_connect("PAIR 4J7K")) else {
            panic!("ambiguous retry fell back after capability revocation");
        };
        assert_eq!(
            error.to_string(),
            localization::catalog().sidebar.machine_provider_external_connect_ambiguous
        );

        controller.close();
        server.join().unwrap();
    }

    #[test]
    fn unnegotiated_external_connect_preserves_client_local_validation() {
        let socket = TestProviderSocket::bind();
        let listener = socket.listener();
        let mut catalog = snapshot(1, "Existing", protocol::MachineStatus::Running);
        catalog.capabilities.connect_external_machine = true;
        let server_catalog = catalog;
        let server = thread::spawn(move || {
            let (stream, mut reader) = serve_initial_snapshot(&listener, server_catalog);
            stream.set_read_timeout(Some(Duration::from_millis(250))).unwrap();
            let mut unexpected = String::new();
            match reader.read_line(&mut unexpected) {
                Err(error)
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) => {}
                Ok(0) => {}
                Ok(_) => panic!("unnegotiated provider received local SSH input: {unexpected}"),
                Err(error) => panic!("provider read failed: {error}"),
            }
        });

        let provider = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
        let mut controller = ProviderMachineController::for_test(
            provider,
            MachineRuntime::external(Vec::new(), true),
            None,
            false,
        );
        let Err(error) = controller.perform_request(local_connect("PAIR 4J7K")) else {
            panic!("unnegotiated provider unexpectedly handled local connect input");
        };

        assert_eq!(
            error.to_string(),
            "machine address must be a host or user@host without whitespace"
        );
        controller.close();
        server.join().unwrap();
    }

    #[test]
    fn disconnected_provider_external_connect_never_reaches_local_ssh() {
        let socket = TestProviderSocket::bind();
        let listener = socket.listener();
        let (disconnect, disconnect_now) = mpsc::channel();
        let server = thread::spawn(move || {
            let (_stream, _reader) = serve_initial_snapshot_with_capabilities(
                &listener,
                snapshot(1, "Existing", protocol::MachineStatus::Running),
                &[protocol::EXTERNAL_MACHINE_CONNECT_CAPABILITY],
            );
            disconnect_now.recv().unwrap();
        });

        let provider = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
        disconnect.send(()).unwrap();
        server.join().unwrap();
        let deadline = std::time::Instant::now() + Duration::from_secs(2);
        while provider.client.is_live() && std::time::Instant::now() < deadline {
            thread::yield_now();
        }
        assert!(!provider.client.is_live(), "provider reader did not observe disconnect");
        let mut controller = ProviderMachineController::for_test(
            provider,
            MachineRuntime::external(Vec::new(), true),
            None,
            false,
        );

        let Err(error) = controller.perform_request(provider_connect("ABCD-EFGH")) else {
            panic!("disconnected provider unexpectedly completed external connect");
        };

        assert_eq!(
            error.to_string(),
            localization::catalog().sidebar.machine_provider_disconnected
        );
        controller.close();
    }

    #[test]
    fn provider_disconnect_during_external_connect_refresh_fails_closed() {
        let socket = TestProviderSocket::bind();
        let listener = socket.listener();
        let server = thread::spawn(move || {
            let (stream, mut reader) = serve_initial_snapshot_with_capabilities(
                &listener,
                snapshot(1, "Existing", protocol::MachineStatus::Running),
                &[protocol::EXTERNAL_MACHINE_CONNECT_CAPABILITY],
            );
            let refresh: protocol::RequestEnvelope = read_frame(&mut reader);
            assert!(matches!(refresh.request, protocol::ProviderRequest::Snapshot(_)));
            drop(stream);
        });

        let provider = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
        let mut controller = ProviderMachineController::for_test(
            provider,
            MachineRuntime::external(Vec::new(), true),
            None,
            false,
        );
        let Err(error) = controller.perform_request(provider_connect("ABCD-EFGH")) else {
            panic!("refresh-disconnected provider unexpectedly handled external connect");
        };

        assert_eq!(
            error.to_string(),
            localization::catalog().sidebar.machine_provider_disconnected
        );
        controller.close();
        server.join().unwrap();
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
        let mut local = MachineUiState::new(MachineSnapshot {
            machines: vec![MachineDescriptor {
                key: local_key,
                id: "mini".into(),
                name: "Mini".into(),
                subtitle: "local".into(),
                status: MachineStatus::Running,
            }],
            active: Some(local_key),
            capabilities: MachineCapabilities { create: false, connect: true },
        });
        local.set_client_renamable_machines([local_key]);

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
        let mut local = MachineUiState::new(MachineSnapshot {
            machines: vec![MachineDescriptor {
                key: local_key,
                id: "mini".into(),
                name: "Mini".into(),
                subtitle: "local".into(),
                status: MachineStatus::Running,
            }],
            active: Some(local_key),
            capabilities: MachineCapabilities::default(),
        });
        local.set_client_renamable_machines([local_key]);

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
        let state_root = TestStateRoot::create("provider-reconnect");
        let mut controller = ProviderMachineController::connect_with(
            connector,
            Vec::new(),
            false,
            Some(state_root.path.clone()),
        )
        .unwrap();

        let result = controller.perform_request(MachineRequest::ReconnectProvider).unwrap();
        assert!(result.replacement.is_some());
        let committed = controller.commit_replacement(true);

        controller.abort_replacement();
        controller.close();
        finish.send(()).unwrap();
        server.join().unwrap();
        assert!(committed.is_ok(), "provider replacement did not commit: {committed:?}");
        assert_eq!(controller.active_local, None);
    }

    #[test]
    fn reconnect_open_failure_preserves_snapshot_notice() {
        let socket = TestProviderSocket::bind();
        let listener = socket.listener();
        let (finish, finished) = mpsc::channel();
        let server = thread::spawn(move || {
            let (_first_stream, _first_reader) = serve_initial_snapshot(
                &listener,
                snapshot(1, "Before reconnect", protocol::MachineStatus::Running),
            );
            let mut reconnected =
                snapshot(2, "Still provisioning", protocol::MachineStatus::Connecting);
            reconnected.notice = Some(protocol::ProviderNotice {
                level: protocol::NoticeLevel::Warning,
                message: "provider maintenance".into(),
            });
            let (_second_stream, _second_reader) = serve_initial_snapshot(&listener, reconnected);
            finished.recv().unwrap();
        });

        let mut runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
        let result = runtime.perform_request(MachineRequest::ReconnectProvider).unwrap();
        let notice = result.ui.notice.as_deref().unwrap();

        finish.send(()).unwrap();
        assert!(notice.contains("provider maintenance"));
        assert!(notice.contains(localization::catalog().sidebar.machine_reconnect_failed));
        drop(runtime);
        server.join().unwrap();
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
        let state_root = TestStateRoot::create("provider-delete");
        let mut controller = ProviderMachineController::connect_with(
            connector,
            Vec::new(),
            false,
            Some(state_root.path.clone()),
        )
        .unwrap();
        let machine = key_for_id(&controller.provider.keys, &id("machine-1")).unwrap();
        install_test_connection(&mut controller.provider, "deleted-open", "machine-1", true);

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
                        "capabilities": ["browser-pointer-frame-guard-v1"],
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
        let mut controller = ProviderMachineController::for_test(
            ProviderMachineRuntime::connect(&provider_socket.path, token()).unwrap(),
            local,
            None,
            true,
        );

        let result = controller.perform_request(MachineRequest::Switch(local_key)).unwrap();

        assert!(result.replacement.is_some());
        assert!(result.restart_updates);
        assert_eq!(result.ui.snapshot.active, Some(local_key));
        assert!(result.ui.session_available);
        assert_eq!(controller.active_local, None, "candidate is not active before commit");
        assert!(
            controller.pending_provider_switch,
            "an uncommitted local candidate cannot cancel the pairing handoff"
        );
        controller.commit_replacement(true).unwrap();
        assert_eq!(controller.active_local, Some(local_key));
        assert!(
            !controller.pending_provider_switch,
            "the committed local selection supersedes the automatic pairing handoff"
        );
        let renamed = controller
            .perform_request(MachineRequest::RenameClientMachine {
                machine: local_key,
                name: "Renamed mini".into(),
            })
            .unwrap();
        assert!(renamed.restart_updates);
        assert_eq!(renamed.session_label.as_deref(), Some("Renamed mini"));
        assert_eq!(
            renamed
                .ui
                .snapshot
                .machines
                .iter()
                .find(|machine| machine.key == local_key)
                .map(|machine| machine.name.as_str()),
            Some("Renamed mini")
        );
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
            let mut selected = snapshot(3, "Machine", protocol::MachineStatus::Running);
            selected.notice = Some(protocol::ProviderNotice {
                level: protocol::NoticeLevel::Info,
                message: "scope selected".into(),
            });
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
        install_test_connection(&mut runtime, "keep-open", "machine-1", true);

        let result = runtime
            .perform_request(MachineRequest::SelectProviderScope("personal".into()))
            .unwrap();

        assert!(result.replacement.is_none());
        assert!(result.ui.session_available);
        assert_eq!(result.ui.notice.as_deref(), Some("scope selected"));
        assert_eq!(
            runtime.open.as_ref().map(|open| open.connection_id.as_str()),
            Some("keep-open")
        );
        drop(runtime);
        server.join().unwrap();
    }

    #[test]
    fn action_selected_scope_loads_the_selected_scope_snapshot() {
        let socket = TestProviderSocket::bind();
        let listener = socket.listener();
        let (finish, finished) = mpsc::channel();
        let mut personal = snapshot(1, "Personal machine", protocol::MachineStatus::Running);
        personal.scopes.push(protocol::ScopeDescriptor {
            id: id("team-1"),
            display_name: "Team".into(),
            kind: protocol::ScopeKind::Team,
            can_admin: true,
        });
        let mut team = personal.clone();
        team.revision = 3;
        team.selected_scope_id = id("team-1");
        team.machines[0].id = id("team-machine");
        team.machines[0].display_name = "Team machine".into();
        team.selected_machine_id = Some(id("team-machine"));

        let server = thread::spawn(move || {
            let (mut stream, mut reader) = serve_initial_snapshot(&listener, personal.clone());

            let refresh: protocol::RequestEnvelope = read_frame(&mut reader);
            assert!(matches!(refresh.request, protocol::ProviderRequest::Snapshot(_)));
            let mut refreshed_personal = personal.clone();
            refreshed_personal.revision = 2;
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::success(refresh.id, refreshed_personal.clone()),
            );
            serve_machine_lifecycle_snapshot(&mut stream, &mut reader, &refreshed_personal);

            let action: protocol::RequestEnvelope = read_frame(&mut reader);
            assert!(matches!(
                &action.request,
                protocol::ProviderRequest::InvokeAction(params)
                    if params.action_id == id("billing")
            ));
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::success(
                    action.id,
                    protocol::InvokeActionResult {
                        revision: 3,
                        notice: None,
                        url: None,
                        selected_scope_id: Some(id("team-1")),
                        selected_machine_id: Some(id("team-machine")),
                    },
                ),
            );

            let selection: protocol::RequestEnvelope = read_frame(&mut reader);
            match selection.request {
                protocol::ProviderRequest::SelectScope(params) => {
                    assert_eq!(params.scope_id, id("team-1"));
                    write_frame(
                        &mut stream,
                        &protocol::ResponseEnvelope::success(
                            selection.id,
                            protocol::SelectScopeResult { snapshot: team.clone() },
                        ),
                    );
                    serve_machine_lifecycle_snapshot(&mut stream, &mut reader, &team);
                }
                protocol::ProviderRequest::Snapshot(_) => {
                    // A provider may return the action-selected scope without mutating its
                    // process-global selection. Refreshing here therefore returns the old scope.
                    let mut old_scope = personal.clone();
                    old_scope.revision = 3;
                    write_frame(
                        &mut stream,
                        &protocol::ResponseEnvelope::success(selection.id, old_scope.clone()),
                    );
                    serve_machine_lifecycle_snapshot(&mut stream, &mut reader, &old_scope);
                }
                request => panic!("unexpected request after provider action: {request:?}"),
            }

            let refresh: protocol::RequestEnvelope = read_frame(&mut reader);
            assert!(matches!(refresh.request, protocol::ProviderRequest::Snapshot(_)));
            let mut old_scope = personal;
            old_scope.revision = 4;
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::success(refresh.id, old_scope.clone()),
            );

            let selection: protocol::RequestEnvelope = read_frame(&mut reader);
            match selection.request {
                protocol::ProviderRequest::SelectScope(params) => {
                    assert_eq!(params.scope_id, id("team-1"));
                    let mut updated_team = team;
                    updated_team.revision = 4;
                    updated_team.machines[0].display_name = "Updated team machine".into();
                    write_frame(
                        &mut stream,
                        &protocol::ResponseEnvelope::success(
                            selection.id,
                            protocol::SelectScopeResult { snapshot: updated_team.clone() },
                        ),
                    );
                    serve_machine_lifecycle_snapshot(&mut stream, &mut reader, &updated_team);
                }
                protocol::ProviderRequest::MachineLifecycleSnapshot(params) => {
                    assert_eq!(params.scope_id, id("personal"));
                    write_frame(
                        &mut stream,
                        &protocol::ResponseEnvelope::success(
                            selection.id,
                            machine_lifecycle_snapshot(&old_scope),
                        ),
                    );
                }
                request => panic!("unexpected subscription reconciliation request: {request:?}"),
            }
            finished.recv().unwrap();
        });

        let mut runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
        let result = runtime
            .perform_request(MachineRequest::InvokeProviderAction {
                action_id: "billing".into(),
                values: BTreeMap::new(),
                machine_id: None,
                workspace_id: None,
            })
            .unwrap();
        let updates = runtime.subscribe_ui_updates().unwrap();
        let (receiver, stop, worker) = updates.into_parts();
        let update = expect_ui_update(receiver.recv_timeout(Duration::from_secs(2)).unwrap());
        stop.store(true, Ordering::Release);
        drop(receiver);
        worker.join().unwrap();
        finish.send(()).unwrap();
        server.join().unwrap();

        assert_eq!(runtime.snapshot.selected_scope_id, id("team-1"));
        assert_eq!(runtime.snapshot.selected_machine_id, Some(id("team-machine")));
        assert_eq!(runtime.snapshot.machines[0].id, id("team-machine"));
        assert_eq!(runtime.machine_lifecycle_snapshot.scope_id, id("team-1"));
        assert_eq!(result.ui.snapshot.machines[0].id, "team-machine");
        assert_eq!(update.provider.as_ref().unwrap().selected_scope_id, "team-1");
        assert_eq!(update.snapshot.machines[0].name, "Updated team machine");
    }

    #[test]
    fn persistent_snapshot_notice_is_not_repeated_by_refresh() {
        let socket = TestProviderSocket::bind();
        let listener = socket.listener();
        let mut catalog = snapshot(1, "Machine", protocol::MachineStatus::Running);
        catalog.notice = Some(protocol::ProviderNotice {
            level: protocol::NoticeLevel::Warning,
            message: "scheduled maintenance".into(),
        });
        let server_catalog = catalog;
        let (finish, finished) = mpsc::channel();
        let server = thread::spawn(move || {
            let (mut stream, mut reader) =
                serve_initial_snapshot(&listener, server_catalog.clone());
            let mut second = server_catalog.clone();
            second.revision = 2;
            serve_runtime_refresh(&mut stream, &mut reader, &second, None);
            let mut third = server_catalog;
            third.revision = 3;
            serve_runtime_refresh(&mut stream, &mut reader, &third, None);
            finished.recv().unwrap();
        });

        let mut runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
        runtime.refresh().unwrap();
        runtime.refresh().unwrap();
        let ui = runtime.ui_state_for_open_connection();

        finish.send(()).unwrap();
        assert_eq!(ui.notice.as_deref(), Some("scheduled maintenance"));
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
        install_test_connection(&mut runtime, "keep-first-open", "machine-1", true);
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
        install_test_connection(&mut runtime, "keep-first-open", "machine-1", true);
        let rollback = ProviderSelectionRollback {
            selected_machine_id: runtime.snapshot.selected_machine_id.clone(),
            workspace_snapshot: runtime.workspace_snapshot.clone(),
        };
        runtime.snapshot.selected_machine_id = Some(id("machine-2"));
        runtime.snapshot.machines[1].workspace_create = protocol::WorkspaceCreatePolicy::Provider {
            default_mode: protocol::WorkspaceCreateMode::Isolated,
            modes: vec![protocol::WorkspaceCreateMode::Isolated],
        };
        let candidate_open =
            cache_test_connection(&mut runtime, "reject-second", "machine-2", true);
        runtime.stage_connection(Some(candidate_open), Some(rollback)).unwrap();
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
    fn durable_notice_bypasses_a_blocked_authoritative_refresh() {
        let socket = TestProviderSocket::bind();
        let listener = socket.listener();
        let (refresh_started, wait_for_refresh) = mpsc::channel();
        let (release_refresh, refresh_release) = mpsc::channel();
        let replay = protocol::EventEnvelope::with_delivery(
            protocol::ProviderEvent::Notice(protocol::ProviderNotice {
                level: protocol::NoticeLevel::Warning,
                message: "Usage reached 80%".into(),
            }),
            protocol::NoticeDelivery { notice_id: id("usage-80"), sequence: 1 },
        );
        let server = thread::spawn(move || {
            let catalog = snapshot(1, "Machine", protocol::MachineStatus::Running);
            let (mut stream, mut reader, _) =
                serve_initial_durable_snapshot(&listener, catalog.clone(), Some(replay));
            let refresh: protocol::RequestEnvelope = read_frame(&mut reader);
            assert!(matches!(refresh.request, protocol::ProviderRequest::Snapshot(_)));
            refresh_started.send(()).unwrap();
            refresh_release.recv().unwrap();
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::success(refresh.id, catalog.clone()),
            );
            serve_machine_lifecycle_snapshot(&mut stream, &mut reader, &catalog);
        });

        let runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
        let updates = runtime.subscribe_ui_updates().unwrap();
        let (receiver, stop, worker) = updates.into_parts();
        wait_for_refresh.recv_timeout(Duration::from_secs(2)).unwrap();

        let update = receiver.recv_timeout(Duration::from_secs(2)).unwrap();
        let MachineUpdate::DurableNotice(notice) = update else {
            panic!("blocked refresh reached the app before the durable notice");
        };
        assert_eq!(notice.delivery.notice_id, "usage-80");
        assert_eq!(notice.delivery.sequence, 1);
        assert_eq!(notice.level, DurableNoticeLevel::Warning);
        assert_eq!(notice.message, "Usage reached 80%");

        release_refresh.send(()).unwrap();
        stop.store(true, Ordering::Release);
        drop(receiver);
        worker.join().unwrap();
        drop(runtime);
        server.join().unwrap();
    }

    #[test]
    fn snapshot_change_burst_does_not_disconnect_or_starve_durable_notice() {
        let socket = TestProviderSocket::bind();
        let listener = socket.listener();
        let (refresh_started, wait_for_refresh) = mpsc::channel();
        let (release_refresh, refresh_release) = mpsc::channel();
        let server = thread::spawn(move || {
            let catalog = snapshot(1, "Machine", protocol::MachineStatus::Running);
            let (mut stream, mut reader, _) =
                serve_initial_durable_snapshot(&listener, catalog, None);
            let refresh: protocol::RequestEnvelope = read_frame(&mut reader);
            assert!(matches!(refresh.request, protocol::ProviderRequest::Snapshot(_)));
            refresh_started.send(()).unwrap();

            let last_revision = PROVIDER_REFRESH_QUEUE_CAPACITY as u64 + 2;
            for revision in 2..=last_revision {
                write_frame(
                    &mut stream,
                    &protocol::EventEnvelope::new(protocol::ProviderEvent::SnapshotChanged(
                        protocol::SnapshotChangedEvent { revision },
                    )),
                );
            }
            write_frame(
                &mut stream,
                &protocol::EventEnvelope::with_delivery(
                    protocol::ProviderEvent::Notice(protocol::ProviderNotice {
                        level: protocol::NoticeLevel::Warning,
                        message: "Usage reached 80%".into(),
                    }),
                    protocol::NoticeDelivery { notice_id: id("usage-80"), sequence: 1 },
                ),
            );

            refresh_release.recv().unwrap();
            let refreshed = snapshot(last_revision, "Machine", protocol::MachineStatus::Running);
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::success(refresh.id, refreshed.clone()),
            );
            serve_machine_lifecycle_snapshot(&mut stream, &mut reader, &refreshed);
        });

        let runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
        let updates = runtime.subscribe_ui_updates().unwrap();
        let (receiver, stop, worker) = updates.into_parts();
        wait_for_refresh.recv_timeout(Duration::from_secs(2)).unwrap();

        let received = receiver.recv_timeout(Duration::from_secs(2));
        release_refresh.send(()).unwrap();
        stop.store(true, Ordering::Release);
        drop(receiver);
        worker.join().unwrap();
        drop(runtime);
        server.join().unwrap();

        let MachineUpdate::DurableNotice(notice) = received.expect(
            "redundant snapshot invalidations must coalesce instead of disconnecting the provider",
        ) else {
            panic!("snapshot invalidation burst disconnected before the durable notice");
        };
        assert_eq!(notice.delivery.notice_id, "usage-80");
        assert_eq!(notice.delivery.sequence, 1);
    }

    #[test]
    fn initial_durable_replay_suppresses_the_legacy_snapshot_notice() {
        let socket = TestProviderSocket::bind();
        let listener = socket.listener();
        let (finish, finished) = mpsc::channel();
        let replay = protocol::EventEnvelope::with_delivery(
            protocol::ProviderEvent::Notice(protocol::ProviderNotice {
                level: protocol::NoticeLevel::Warning,
                message: "Usage reached 80%".into(),
            }),
            protocol::NoticeDelivery { notice_id: id("usage-80"), sequence: 1 },
        );
        let server = thread::spawn(move || {
            let mut catalog = snapshot(1, "Machine", protocol::MachineStatus::Running);
            catalog.notice = Some(protocol::ProviderNotice {
                level: protocol::NoticeLevel::Warning,
                message: "Usage reached 80%".into(),
            });
            let (_stream, _reader, _) =
                serve_initial_durable_snapshot(&listener, catalog, Some(replay));
            finished.recv().unwrap();
        });

        let mut runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
        assert!(
            runtime.ui_state_for_open_connection().notice.is_none(),
            "the durable replay and legacy snapshot notice would be shown twice"
        );
        let updates = runtime.subscribe_ui_updates().unwrap();
        let (receiver, stop, worker) = updates.into_parts();
        let MachineUpdate::DurableNotice(notice) =
            receiver.recv_timeout(Duration::from_secs(2)).unwrap()
        else {
            panic!("expected the retained durable notice");
        };
        assert_eq!(notice.delivery.notice_id, "usage-80");

        stop.store(true, Ordering::Release);
        drop(receiver);
        worker.join().unwrap();
        finish.send(()).unwrap();
        drop(runtime);
        server.join().unwrap();
    }

    #[test]
    fn initial_current_warning_remains_visible_without_a_durable_replay() {
        let socket = TestProviderSocket::bind();
        let listener = socket.listener();
        let (finish, finished) = mpsc::channel();
        let server = thread::spawn(move || {
            let mut catalog = snapshot(1, "Machine", protocol::MachineStatus::Running);
            catalog.notice = Some(protocol::ProviderNotice {
                level: protocol::NoticeLevel::Warning,
                message: "Usage reached 50%".into(),
            });
            let (_stream, _reader, _) = serve_initial_durable_snapshot(&listener, catalog, None);
            finished.recv().unwrap();
        });

        let mut runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
        assert_eq!(
            runtime.ui_state_for_open_connection().notice.as_deref(),
            Some("Usage reached 50%")
        );
        finish.send(()).unwrap();
        drop(runtime);
        server.join().unwrap();
    }

    #[test]
    fn durable_provider_suppresses_later_legacy_snapshot_warning_updates() {
        let socket = TestProviderSocket::bind();
        let listener = socket.listener();
        let (trigger, triggered) = mpsc::channel();
        let (finish, finished) = mpsc::channel();
        let server = thread::spawn(move || {
            let catalog = snapshot(1, "Machine", protocol::MachineStatus::Running);
            let (mut stream, mut reader, _) =
                serve_initial_durable_snapshot(&listener, catalog, None);
            triggered.recv().unwrap();
            let refresh: protocol::RequestEnvelope = read_frame(&mut reader);
            assert!(matches!(refresh.request, protocol::ProviderRequest::Snapshot(_)));
            write_frame(
                &mut stream,
                &protocol::EventEnvelope::with_delivery(
                    protocol::ProviderEvent::Notice(protocol::ProviderNotice {
                        level: protocol::NoticeLevel::Warning,
                        message: "Usage reached 80%".into(),
                    }),
                    protocol::NoticeDelivery { notice_id: id("usage-80"), sequence: 1 },
                ),
            );
            let mut refreshed = snapshot(2, "Machine", protocol::MachineStatus::Running);
            refreshed.notice = Some(protocol::ProviderNotice {
                level: protocol::NoticeLevel::Warning,
                message: "Usage reached 80%".into(),
            });
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::success(refresh.id, refreshed.clone()),
            );
            serve_machine_lifecycle_snapshot(&mut stream, &mut reader, &refreshed);
            finished.recv().unwrap();
        });

        let runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
        let updates = runtime.subscribe_ui_updates().unwrap();
        let (receiver, stop, worker) = updates.into_parts();
        trigger.send(()).unwrap();
        let mut saw_durable = false;
        let mut saw_refresh = false;
        for _ in 0..2 {
            match receiver.recv_timeout(Duration::from_secs(2)).unwrap() {
                MachineUpdate::DurableNotice(notice) => {
                    assert_eq!(notice.delivery.notice_id, "usage-80");
                    saw_durable = true;
                }
                MachineUpdate::Ui(ui) => {
                    assert!(
                        ui.notice.is_none(),
                        "legacy snapshot warning duplicated the durable event"
                    );
                    saw_refresh = true;
                }
                MachineUpdate::ConnectionProgress { machine_id, latest } => {
                    panic!("unexpected progress {machine_id:?}: {latest:?}")
                }
            }
        }
        assert!(saw_durable && saw_refresh);

        stop.store(true, Ordering::Release);
        drop(receiver);
        worker.join().unwrap();
        finish.send(()).unwrap();
        drop(runtime);
        server.join().unwrap();
    }

    #[test]
    fn reconnect_reuses_the_process_stable_notice_consumer_id() {
        let socket = TestProviderSocket::bind();
        let listener = socket.listener();
        let (consumers, consumer_ids) = mpsc::channel();
        let (reconnect, reconnect_now) = mpsc::channel();
        let (finish, finished) = mpsc::channel();
        let server = thread::spawn(move || {
            for revision in [1, 2] {
                let catalog = snapshot(revision, "Machine", protocol::MachineStatus::Running);
                let (stream, reader, consumer_id) =
                    serve_initial_durable_snapshot(&listener, catalog, None);
                consumers.send(consumer_id).unwrap();
                if revision == 2 {
                    finished.recv().unwrap();
                } else {
                    reconnect_now.recv().unwrap();
                }
                drop(reader);
                drop(stream);
            }
        });

        let mut runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
        let first = consumer_ids.recv_timeout(Duration::from_secs(2)).unwrap();
        reconnect.send(()).unwrap();
        runtime.reconnect_control().unwrap();
        let second = consumer_ids.recv_timeout(Duration::from_secs(2)).unwrap();

        assert_eq!(first, second);
        assert_eq!(Some(&first), runtime.notice_identity.acquired_consumer_id());
        finish.send(()).unwrap();
        drop(runtime);
        server.join().unwrap();
    }

    #[test]
    fn legacy_provider_does_not_require_notice_identity_state() {
        let socket = TestProviderSocket::bind();
        let listener = socket.listener();
        let state = TestStateRoot::create("legacy-without-identity");
        let identity_parent = crate::provider_notice_identity::identity_parent(&state.path);
        std::fs::DirBuilder::new().mode(0o755).create(&identity_parent).unwrap();
        std::fs::set_permissions(&identity_parent, std::fs::Permissions::from_mode(0o755)).unwrap();
        let (release, release_connection) = mpsc::channel();
        let server = thread::spawn(move || {
            let Some(stream) = accept_with_timeout(&listener) else { return false };
            let (stream, reader) = serve_initial_snapshot_on_stream(
                stream,
                snapshot(1, "Legacy", protocol::MachineStatus::Running),
                &[],
            );
            release_connection.recv_timeout(Duration::from_secs(2)).unwrap();
            drop(reader);
            drop(stream);
            true
        });

        let runtime =
            ProviderMachineRuntime::connect_in_state_root(&socket.path, token(), &state.path);
        release.send(()).unwrap();
        assert!(
            server.join().unwrap(),
            "legacy provider was not contacted before identity state was accessed"
        );
        let runtime = runtime.expect("legacy provider should not require durable identity state");
        assert_eq!(runtime.ui_state(false).snapshot.machines[0].name, "Legacy");
    }

    #[test]
    fn legacy_provider_connects_without_a_resolvable_state_root() {
        let socket = TestProviderSocket::bind();
        let listener = socket.listener();
        let (release, release_connection) = mpsc::channel();
        let server = thread::spawn(move || {
            let Some(stream) = accept_with_timeout(&listener) else { return false };
            let (stream, reader) = serve_initial_snapshot_on_stream(
                stream,
                snapshot(1, "Legacy", protocol::MachineStatus::Running),
                &[],
            );
            release_connection.recv_timeout(Duration::from_secs(2)).unwrap();
            drop(reader);
            drop(stream);
            true
        });

        let runtime = ProviderMachineRuntime::connect_without_state_root(&socket.path, token());
        release.send(()).unwrap();
        assert!(
            server.join().unwrap(),
            "legacy provider was not contacted before the missing state root was required"
        );
        let runtime = runtime.expect("legacy provider should not require a durable state root");
        assert_eq!(runtime.ui_state(false).snapshot.machines[0].name, "Legacy");
    }

    #[test]
    fn unavailable_notice_identity_preserves_localized_context_after_durable_handshake() {
        let socket = TestProviderSocket::bind();
        let listener = socket.listener();
        let state = TestStateRoot::create("unavailable-identity");
        let identity_parent = crate::provider_notice_identity::identity_parent(&state.path);
        std::fs::DirBuilder::new().mode(0o755).create(&identity_parent).unwrap();
        std::fs::set_permissions(&identity_parent, std::fs::Permissions::from_mode(0o755)).unwrap();
        let server = thread::spawn(move || negotiate_durable_then_expect_disconnect(&listener));

        let error =
            ProviderMachineRuntime::connect_in_state_root(&socket.path, token(), &state.path)
                .err()
                .expect("permissive identity state unexpectedly connected");
        assert!(
            server.join().unwrap(),
            "durable capability was not negotiated before identity state was accessed"
        );
        assert_eq!(
            error.to_string(),
            localization::catalog().sidebar.provider_notice_identity_unavailable
        );
        assert!(
            format!("{error:?}")
                .contains("provider notice identity directory must not be accessible")
        );
    }

    #[test]
    fn missing_notice_identity_root_uses_localized_error_after_durable_handshake() {
        let socket = TestProviderSocket::bind();
        let listener = socket.listener();
        let server = thread::spawn(move || negotiate_durable_then_expect_disconnect(&listener));

        let error = ProviderMachineRuntime::connect_without_state_root(&socket.path, token())
            .err()
            .expect("missing identity root unexpectedly connected");
        assert!(
            server.join().unwrap(),
            "durable capability was not negotiated before the missing state root was required"
        );
        assert_eq!(
            error.to_string(),
            localization::catalog().sidebar.provider_notice_identity_unavailable
        );
        assert!(format!("{error:?}").contains("cannot determine durable state directory"));
    }

    #[test]
    fn runtime_identity_lease_blocks_a_second_cursor_and_reuses_it_after_release() {
        let socket = TestProviderSocket::bind();
        let listener = socket.listener();
        let first_root = TestStateRoot::create("first");
        let second_root = TestStateRoot::create("second");
        let (consumers, consumer_ids) = mpsc::channel();
        let (release, release_connection) = mpsc::channel();
        let server = thread::spawn(move || {
            let first_catalog = snapshot(1, "Machine", protocol::MachineStatus::Running);
            let (first_stream, first_reader, first_consumer_id) =
                serve_initial_durable_snapshot(&listener, first_catalog, None);
            consumers.send(first_consumer_id).unwrap();

            let (mut blocked_stream, _) = listener.accept().unwrap();
            let mut blocked_reader = BufReader::new(blocked_stream.try_clone().unwrap());
            let hello: protocol::RequestEnvelope = read_frame(&mut blocked_reader);
            assert!(matches!(hello.request, protocol::ProviderRequest::Hello(_)));
            write_frame(
                &mut blocked_stream,
                &protocol::ResponseEnvelope::success(
                    hello.id,
                    protocol::HelloResult {
                        provider_id: id("test-provider"),
                        provider_name: "Test Provider".into(),
                        negotiated_version: protocol::Version,
                    },
                )
                .with_capabilities([protocol::DURABLE_NOTICES_CAPABILITY]),
            );
            let mut blocked_request = String::new();
            assert_eq!(
                blocked_reader.read_line(&mut blocked_request).unwrap(),
                0,
                "competing runtime subscribed with the leased identity: {blocked_request}"
            );
            drop(blocked_reader);
            drop(blocked_stream);

            release_connection.recv().unwrap();
            drop(first_reader);
            drop(first_stream);

            for revision in [2, 3] {
                let catalog = snapshot(revision, "Machine", protocol::MachineStatus::Running);
                let (stream, reader, consumer_id) =
                    serve_initial_durable_snapshot(&listener, catalog, None);
                consumers.send(consumer_id).unwrap();
                release_connection.recv().unwrap();
                drop(reader);
                drop(stream);
            }
        });

        let first = connect_after_runtime_start(&socket.path, &first_root.path);
        let first_id = consumer_ids.recv_timeout(Duration::from_secs(2)).unwrap();

        let blocked_socket = socket.path.clone();
        let blocked_root = first_root.path.clone();
        let (blocked_result, blocked_outcome) = mpsc::channel();
        let blocked = thread::spawn(move || {
            let result = ProviderMachineRuntime::connect_in_state_root(
                blocked_socket,
                token(),
                &blocked_root,
            );
            blocked_result
                .send(match result {
                    Ok(runtime) => {
                        drop(runtime);
                        Ok(())
                    }
                    Err(error) => Err(error.to_string()),
                })
                .unwrap();
        });
        let blocked_error = blocked_outcome
            .recv_timeout(Duration::from_secs(2))
            .expect("second runtime did not fail before subscribing")
            .expect_err("second runtime unexpectedly acquired the shared notice cursor");
        assert_eq!(
            blocked_error,
            localization::catalog().sidebar.provider_connection_already_running
        );
        blocked.join().unwrap();
        assert!(consumer_ids.try_recv().is_err());

        let first_ui = first.ui_state(false);
        assert_eq!(first_ui.snapshot.machines[0].name, "Machine");
        drop(first);
        release.send(()).unwrap();

        let restarted = connect_after_runtime_start(&socket.path, &first_root.path);
        let restarted_id = consumer_ids.recv_timeout(Duration::from_secs(2)).unwrap();
        drop(restarted);
        release.send(()).unwrap();

        let separate = connect_after_runtime_start(&socket.path, &second_root.path);
        let separate_id = consumer_ids.recv_timeout(Duration::from_secs(2)).unwrap();
        drop(separate);
        release.send(()).unwrap();

        assert_eq!(restarted_id, first_id);
        assert_ne!(separate_id, first_id);
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

        let update = expect_ui_update(receiver.recv_timeout(Duration::from_secs(2)).unwrap());
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
    fn subscription_refreshes_after_an_event_published_before_registration() {
        let socket = TestProviderSocket::bind();
        let listener = socket.listener();
        let (publish, published) = mpsc::channel();
        let server = thread::spawn(move || {
            let (mut stream, mut reader) = serve_initial_snapshot(
                &listener,
                snapshot(1, "Before subscription", protocol::MachineStatus::Running),
            );
            published.recv().unwrap();
            write_frame(
                &mut stream,
                &protocol::EventEnvelope::new(protocol::ProviderEvent::SnapshotChanged(
                    protocol::SnapshotChangedEvent { revision: 2 },
                )),
            );

            // Synchronize with the control reader after the unobserved event.
            // This response is deliberately stale and is not installed by the runtime.
            let synchronize: protocol::RequestEnvelope = read_frame(&mut reader);
            assert!(matches!(synchronize.request, protocol::ProviderRequest::Snapshot(_)));
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::success(
                    synchronize.id,
                    snapshot(1, "Before subscription", protocol::MachineStatus::Running),
                ),
            );

            let mut line = String::new();
            if reader.read_line(&mut line).unwrap() == 0 {
                return;
            }
            let refresh: protocol::RequestEnvelope = serde_json::from_str(&line).unwrap();
            assert!(matches!(refresh.request, protocol::ProviderRequest::Snapshot(_)));
            let refreshed = snapshot(2, "After subscription", protocol::MachineStatus::Sleeping);
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::success(refresh.id, refreshed.clone()),
            );
            serve_machine_lifecycle_snapshot(&mut stream, &mut reader, &refreshed);
        });

        let runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
        publish.send(()).unwrap();
        let ignored = runtime.client.snapshot(Some(1)).unwrap();
        assert_eq!(ignored.revision, 1);

        let updates = runtime.subscribe_ui_updates().unwrap();
        let (receiver, stop, worker) = updates.into_parts();
        let received = receiver.recv_timeout(Duration::from_secs(2));
        stop.store(true, Ordering::Release);
        drop(receiver);
        worker.join().unwrap();
        drop(runtime);
        server.join().unwrap();

        let update = expect_ui_update(received.expect(
            "subscription must perform an authoritative refresh after registering for events",
        ));
        assert_eq!(update.snapshot.machines[0].name, "After subscription");
        assert_eq!(update.snapshot.machines[0].status, MachineStatus::Sleeping);
    }

    #[test]
    fn provider_update_failure_uses_selected_locale() {
        const CHILD_ENV: &str = "CMUX_PROVIDER_UPDATE_LOCALE_CHILD";
        if std::env::var_os(CHILD_ENV).is_none() {
            let output = std::process::Command::new(std::env::current_exe().unwrap())
                .arg(
                    "machine_provider_runtime::tests::provider_update_failure_uses_selected_locale",
                )
                .arg("--exact")
                .arg("--nocapture")
                .env(CHILD_ENV, "1")
                .env("LC_ALL", "ja_JP.UTF-8")
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "Japanese provider failure child failed:\nstdout:\n{}\nstderr:\n{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
            return;
        }

        let socket = TestProviderSocket::bind();
        let listener = socket.listener();
        let (trigger, triggered) = mpsc::channel();
        let (finish, finished) = mpsc::channel();
        let server = thread::spawn(move || {
            let (mut stream, mut reader) = serve_initial_snapshot(
                &listener,
                snapshot(1, "Machine", protocol::MachineStatus::Running),
            );
            triggered.recv().unwrap();
            write_frame(
                &mut stream,
                &protocol::EventEnvelope::new(protocol::ProviderEvent::SnapshotChanged(
                    protocol::SnapshotChangedEvent { revision: 2 },
                )),
            );
            let request: protocol::RequestEnvelope = read_frame(&mut reader);
            assert!(matches!(request.request, protocol::ProviderRequest::Snapshot(_)));
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::<protocol::SnapshotResult>::failure(
                    request.id,
                    protocol::ProviderError {
                        code: protocol::ProviderErrorCode::Unavailable,
                        message: "catalog unavailable".into(),
                        retryable: true,
                    },
                ),
            );
            finished.recv().unwrap();
        });

        let runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
        let updates = runtime.subscribe_ui_updates().unwrap();
        let (receiver, stop, worker) = updates.into_parts();
        trigger.send(()).unwrap();
        let update = expect_ui_update(receiver.recv_timeout(Duration::from_secs(2)).unwrap());
        stop.store(true, Ordering::Release);
        drop(receiver);
        worker.join().unwrap();
        finish.send(()).unwrap();
        drop(runtime);
        server.join().unwrap();

        let notice = update.notice.unwrap();
        assert!(
            notice.starts_with("マシンプロバイダーの更新に失敗しました: "),
            "provider failure did not use the selected Japanese locale: {notice}"
        );
    }

    #[test]
    fn provider_connection_state_errors_use_selected_locale() {
        const CHILD_ENV: &str = "CMUX_PROVIDER_CONNECTION_LOCALE_CHILD";
        if std::env::var_os(CHILD_ENV).is_none() {
            let output = std::process::Command::new(std::env::current_exe().unwrap())
                .arg(
                    "machine_provider_runtime::tests::provider_connection_state_errors_use_selected_locale",
                )
                .arg("--exact")
                .arg("--nocapture")
                .env(CHILD_ENV, "1")
                .env("LC_ALL", "ja_JP.UTF-8")
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "Japanese provider connection child failed:\nstdout:\n{}\nstderr:\n{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
            return;
        }

        let socket = TestProviderSocket::bind();
        let listener = socket.listener();
        let (finish, finished) = mpsc::channel();
        let server = thread::spawn(move || {
            let _control = serve_initial_snapshot(
                &listener,
                snapshot(1, "Machine", protocol::MachineStatus::Running),
            );
            finished.recv().unwrap();
        });
        let mut runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();

        let error = runtime.open_selected().err().expect("machine is not connectable");
        assert_eq!(error.to_string(), "選択したマシンは接続準備ができていません");
        finish.send(()).unwrap();
        drop(runtime);
        server.join().unwrap();
    }

    #[test]
    fn provider_runtime_user_notices_are_catalog_backed() {
        let source = include_str!("machine_provider_runtime.rs");
        for hardcoded in [
            concat!("Open ", "{url}"),
            concat!("Machine provider ", "update failed: {error}"),
            concat!("Machine provider lifecycle ", "update failed: {error}"),
            concat!("Machine provider workspace ", "update failed: {error}"),
            concat!("Could not reconnect ", "machine: {error}"),
            concat!("this machine provider cannot connect ", "external machines"),
            concat!("is not ready ", "to connect"),
            concat!("cannot authorize managed workspace mirrors; ", "upgrade the machine provider"),
            concat!("returned an invalid managed workspace ", "authority binding"),
        ] {
            assert!(
                !source.contains(hardcoded),
                "provider notice bypasses the localization catalog: {hardcoded}"
            );
        }
    }

    #[test]
    fn stale_connection_closed_event_preserves_the_current_connection() {
        let socket = TestProviderSocket::bind();
        let listener = socket.listener();
        let (trigger, triggered) = mpsc::channel();
        let (finish, finished) = mpsc::channel();
        let server = thread::spawn(move || {
            let (mut stream, mut reader) = serve_initial_snapshot(
                &listener,
                snapshot(1, "Machine", protocol::MachineStatus::Running),
            );
            triggered.recv().unwrap();
            write_frame(
                &mut stream,
                &protocol::EventEnvelope::new(protocol::ProviderEvent::ConnectionClosed(
                    protocol::ConnectionClosedEvent {
                        connection_id: id("old-connection"),
                        machine_id: id("machine-1"),
                        reason: "old connection closed late".into(),
                    },
                )),
            );
            let request: protocol::RequestEnvelope = read_frame(&mut reader);
            assert!(matches!(request.request, protocol::ProviderRequest::Snapshot(_)));
            let refreshed = snapshot(2, "Machine", protocol::MachineStatus::Running);
            write_frame(
                &mut stream,
                &protocol::ResponseEnvelope::success(request.id, refreshed.clone()),
            );
            serve_machine_lifecycle_snapshot(&mut stream, &mut reader, &refreshed);
            finished.recv().unwrap();
        });

        let mut runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
        install_test_connection(&mut runtime, "current-connection", "machine-1", false);
        let updates = runtime.subscribe_ui_updates().unwrap();
        let (receiver, stop, worker) = updates.into_parts();
        trigger.send(()).unwrap();

        let update = expect_ui_update(receiver.recv_timeout(Duration::from_secs(2)).unwrap());
        stop.store(true, Ordering::Release);
        drop(receiver);
        worker.join().unwrap();
        finish.send(()).unwrap();
        runtime.open = None;
        drop(runtime);
        server.join().unwrap();

        assert!(update.session_available);
        assert!(update.request.is_none());
        assert_ne!(update.notice.as_deref(), Some("old connection closed late"));
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

        let update = expect_ui_update(receiver.recv_timeout(Duration::from_secs(2)).unwrap());
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

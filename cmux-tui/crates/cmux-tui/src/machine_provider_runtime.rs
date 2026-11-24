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
    MachinePlatform, MachineRequest, MachineSnapshot, MachineStatus, MachineUiState, MachineUpdate,
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
    MachineProviderConnector, ProviderClient, ProviderClientError, ProviderResult,
    request_mutation_id_mut,
};
use crate::machine_runtime::{
    MachineConnectFn, MachineConnection, MachineConnectionHub, MachineRuntime,
};
use crate::session::{RemoteSession, Session};

mod projection;
mod updates;

use projection::machine_ui_state;
#[cfg(test)]
use projection::provider_presentation;

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

/// Mutations sent without a definite answer.
///
/// A timeout, disconnect, or retryable failure leaves a mutation's outcome
/// unknown: the provider may still commit it. Each entry keys the exact
/// request, with its id cleared, to the `mutation_id` already sent, so the
/// next identical request replays that id and the provider returns the one
/// committed result instead of making a second machine or workspace.
///
/// Only a definite answer removes an entry, so every entry here is unsettled
/// and none is ever evicted: dropping one would make its retry mint a new id
/// and could create a second machine. While the ledger is full, a request
/// with a new intent is refused before it reaches the provider; a retry of a
/// listed request still replays its id and, once answered, frees its slot.
#[derive(Default)]
struct UnsettledMutations {
    entries: Vec<(protocol::ProviderRequest, protocol::OpaqueId)>,
}

/// How many mutations may wait for a definite answer at once. A new intent
/// past this is refused, never made room for by forgetting an unsettled one.
const MAX_UNSETTLED_MUTATIONS: usize = 32;

/// The refusal a new mutation gets while the ledger is full of unsettled ones.
#[derive(Debug)]
struct UnsettledMutationsFull {
    pending: usize,
}

impl std::fmt::Display for UnsettledMutationsFull {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            formatter,
            "{} earlier machine-provider requests are still waiting for an answer, so a new one \
             is not sent. Retry one of them until it succeeds or fails; each retry reuses its \
             request id, so it cannot create a second machine.",
            self.pending
        )
    }
}

impl std::error::Error for UnsettledMutationsFull {}

impl UnsettledMutations {
    fn replay_id(&self, intent: &protocol::ProviderRequest) -> Option<protocol::OpaqueId> {
        self.entries
            .iter()
            .find(|(candidate, _)| candidate == intent)
            .map(|(_, mutation_id)| mutation_id.clone())
    }

    /// Refuses a new intent while the ledger is full. A listed intent passes:
    /// its retry replays an id already in the ledger and adds no entry.
    fn admit(&self, intent: &protocol::ProviderRequest) -> Result<(), UnsettledMutationsFull> {
        if self.entries.len() >= MAX_UNSETTLED_MUTATIONS
            && !self.entries.iter().any(|(candidate, _)| candidate == intent)
        {
            return Err(UnsettledMutationsFull { pending: self.entries.len() });
        }
        Ok(())
    }

    fn remember(
        &mut self,
        intent: protocol::ProviderRequest,
        mutation_id: protocol::OpaqueId,
    ) -> Result<(), UnsettledMutationsFull> {
        if let Some(entry) = self.entries.iter_mut().find(|(candidate, _)| *candidate == intent) {
            entry.1 = mutation_id;
            return Ok(());
        }
        self.admit(&intent)?;
        self.entries.push((intent, mutation_id));
        Ok(())
    }

    fn settle(&mut self, intent: &protocol::ProviderRequest) {
        self.entries.retain(|(candidate, _)| candidate != intent);
    }
}

/// Success or a non-retryable provider failure ends a mutation. Anything else
/// (timeout, disconnect, protocol error, retryable failure) may have committed.
fn mutation_answer_is_definite<T>(result: &ProviderResult<T>) -> bool {
    match result {
        Ok(_) => true,
        Err(ProviderClientError::Provider(error)) => !error.retryable,
        Err(_) => false,
    }
}

/// The id a mutation request carries before the runtime assigns its real one.
fn unassigned_mutation_id() -> anyhow::Result<protocol::OpaqueId> {
    Ok(protocol::OpaqueId::new("cmux-unassigned-mutation")?)
}

/// An external connect whose outcome is still unknown. Its `mutation_id`
/// lives in `UnsettledMutations`, like every other mutation's.
struct PendingExternalConnect {
    scope_id: protocol::OpaqueId,
    specifier: protocol::ExternalMachineSpecifier,
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
    unsettled_mutations: UnsettledMutations,
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
            unsettled_mutations: UnsettledMutations::default(),
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
                let created: protocol::CreateMachineResult = self.send_mutation(
                    protocol::ProviderRequest::CreateMachine(protocol::CreateMachineParams {
                        scope_id: self.snapshot.selected_scope_id.clone(),
                        mutation_id: unassigned_mutation_id()?,
                    }),
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
                let result: protocol::InvokeActionResult = self.send_mutation(
                    protocol::ProviderRequest::InvokeAction(protocol::InvokeActionParams {
                        action_id: protocol::OpaqueId::new(action_id)?,
                        values,
                        machine_id: machine_id.map(protocol::OpaqueId::new).transpose()?,
                        workspace_id: workspace_id.map(protocol::OpaqueId::new).transpose()?,
                        mutation_id: unassigned_mutation_id()?,
                    }),
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
                let result: protocol::MachineMutationResult = self.send_mutation(
                    protocol::ProviderRequest::RenameMachine(protocol::RenameMachineParams {
                        scope_id: self.snapshot.selected_scope_id.clone(),
                        machine_id,
                        expected_version,
                        display_name: name,
                        mutation_id: unassigned_mutation_id()?,
                    }),
                )?;
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
                // The deleted machine's list slot, so the replacement can be
                // the machine that takes its place (or the new last one).
                let deleted_slot = self
                    .snapshot
                    .machines
                    .iter()
                    .position(|descriptor| descriptor.id == machine_id)
                    .unwrap_or_default();
                let deleted_id = machine_id.clone();
                let result: protocol::MachineMutationResult = self.send_mutation(
                    protocol::ProviderRequest::DeleteMachine(protocol::MachineMutationParams {
                        scope_id: self.snapshot.selected_scope_id.clone(),
                        machine_id,
                        expected_version,
                        mutation_id: unassigned_mutation_id()?,
                    }),
                )?;
                self.set_notice(result.notice);
                Ok(self.finish_accepted_action(
                    AcceptedProviderEffects {
                        retire_open_on_failure: deletes_open_session,
                        ..AcceptedProviderEffects::default()
                    },
                    move |runtime| {
                        runtime.refresh()?;
                        // The refreshed catalog no longer lists the deleted
                        // machine, but the selection may still point at it -
                        // reopening it would wake the machine the user just
                        // deleted (or hang behind its teardown). Reselect the
                        // next available machine before opening.
                        // Usable = listed and not a Recoverable leftover:
                        // recovery-capable providers may keep soft-deleted
                        // machines in the catalog, and reopening one would
                        // resurrect what the user just deleted.
                        let recoverable = |id: &protocol::OpaqueId| {
                            runtime.machine_lifecycle_snapshot.machines.iter().any(
                                |descriptor| {
                                    &descriptor.id == id
                                        && descriptor.status
                                            == protocol::MachineLifecycleStatus::Recoverable
                                },
                            )
                        };
                        let selection_stale = runtime
                            .snapshot
                            .selected_machine_id
                            .as_ref()
                            .is_none_or(|selected| {
                                *selected == deleted_id
                                    || recoverable(selected)
                                    || !runtime
                                        .snapshot
                                        .machines
                                        .iter()
                                        .any(|descriptor| &descriptor.id == selected)
                            });
                        // Refresh may replace the deleted desired selection
                        // with an arbitrary valid provider fallback. The
                        // open machine was still deleted, so slot-based
                        // failover must win even when the refreshed selection
                        // is no longer technically stale.
                        if deletes_open_session {
                            let usable: Vec<protocol::OpaqueId> = runtime
                                .snapshot
                                .machines
                                .iter()
                                .filter(|descriptor| {
                                    descriptor.id != deleted_id
                                        && descriptor.connectable
                                        && !recoverable(&descriptor.id)
                                })
                                .map(|descriptor| descriptor.id.clone())
                                .collect();
                            runtime.snapshot.selected_machine_id =
                                usable.get(deleted_slot.min(usable.len().saturating_sub(1))).cloned();
                            runtime.workspace_snapshot = load_workspace_snapshot(
                                &runtime.client,
                                &runtime.snapshot,
                            )?;
                        }
                        crate::client_log::info(
                            "machine",
                            &format!(
                                "delete replacement: stale={selection_stale} machines={} selected={:?}",
                                runtime.snapshot.machines.len(),
                                runtime.snapshot.selected_machine_id.as_ref().map(|id| id.as_str().to_string()),
                            ),
                        );
                        if deletes_open_session {
                            let (session, label, open, reused) =
                                runtime.open_selected_candidate()?;
                            crate::client_log::info(
                                "machine",
                                &format!(
                                    "delete replacement opened: label={label} open={} reused={reused}",
                                    open.is_some(),
                                ),
                            );
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
                let result: protocol::MachineMutationResult = self.send_mutation(
                    protocol::ProviderRequest::RestoreMachine(protocol::MachineMutationParams {
                        scope_id: self.snapshot.selected_scope_id.clone(),
                        machine_id: self.machine_id(machine)?,
                        expected_version,
                        mutation_id: unassigned_mutation_id()?,
                    }),
                )?;
                self.set_notice(result.notice);
                Ok(self.finish_accepted_action(AcceptedProviderEffects::default(), |runtime| {
                    runtime.refresh()?;
                    Ok(MachineActionResult::ui(runtime.ui_state_for_open_connection()))
                }))
            }
            MachineRequest::PurgeManagedMachine { machine, expected_version } => {
                let result: protocol::MachineMutationResult = self.send_mutation(
                    protocol::ProviderRequest::PurgeMachine(protocol::MachineMutationParams {
                        scope_id: self.snapshot.selected_scope_id.clone(),
                        machine_id: self.machine_id(machine)?,
                        expected_version,
                        mutation_id: unassigned_mutation_id()?,
                    }),
                )?;
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
                let result: protocol::WorkspaceMutationResult = self.send_mutation(
                    protocol::ProviderRequest::RenameWorkspace(protocol::RenameWorkspaceParams {
                        machine_id: self.machine_id(machine)?,
                        workspace_id: protocol::OpaqueId::new(workspace_id.clone())?,
                        expected_version,
                        display_name: name.clone(),
                        mutation_id: unassigned_mutation_id()?,
                    }),
                )?;
                self.set_notice(result.notice);
                Ok(self.finish_accepted_workspace_mutation(
                    ManagedWorkspaceSessionMutation::Rename { workspace_key: workspace_id, name },
                ))
            }
            MachineRequest::DeleteManagedWorkspace { machine, workspace_id, expected_version } => {
                let result: protocol::WorkspaceMutationResult = self.send_mutation(
                    protocol::ProviderRequest::DeleteWorkspace(protocol::WorkspaceMutationParams {
                        machine_id: self.machine_id(machine)?,
                        workspace_id: protocol::OpaqueId::new(workspace_id.clone())?,
                        expected_version,
                        mutation_id: unassigned_mutation_id()?,
                    }),
                )?;
                self.set_notice(result.notice);
                Ok(self.finish_accepted_workspace_mutation(
                    ManagedWorkspaceSessionMutation::Close { workspace_key: workspace_id },
                ))
            }
            MachineRequest::RestoreManagedWorkspace { machine, workspace_id, expected_version } => {
                let result: protocol::WorkspaceMutationResult =
                    self.send_mutation(protocol::ProviderRequest::RestoreWorkspace(
                        protocol::WorkspaceMutationParams {
                            machine_id: self.machine_id(machine)?,
                            workspace_id: protocol::OpaqueId::new(workspace_id)?,
                            expected_version,
                            mutation_id: unassigned_mutation_id()?,
                        },
                    ))?;
                self.set_notice(result.notice);
                Ok(self.finish_accepted_action(AcceptedProviderEffects::default(), |runtime| {
                    runtime.refresh()?;
                    Ok(MachineActionResult::ui(runtime.ui_state_for_open_connection()))
                }))
            }
            MachineRequest::PurgeManagedWorkspace { machine, workspace_id, expected_version } => {
                let result: protocol::WorkspaceMutationResult = self.send_mutation(
                    protocol::ProviderRequest::PurgeWorkspace(protocol::WorkspaceMutationParams {
                        machine_id: self.machine_id(machine)?,
                        workspace_id: protocol::OpaqueId::new(workspace_id)?,
                        expected_version,
                        mutation_id: unassigned_mutation_id()?,
                    }),
                )?;
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
        // The ledger owns the mutation_id: it replays the id an unanswered
        // attempt in this scope already sent, counts the connect against its
        // cap, and settles it on a definite answer.
        let intent = protocol::ProviderRequest::ConnectExternalMachine(
            protocol::ConnectExternalMachineParams {
                scope_id: scope_id.clone(),
                specifier: specifier.clone(),
                mutation_id: unassigned_mutation_id()?,
            },
        );
        let result: anyhow::Result<protocol::ConnectExternalMachineResult> =
            self.send_mutation(intent.clone());
        // The connect stays ambiguous exactly while the ledger still lists
        // it. A connect the full ledger refused leaves another one alone.
        if self.unsettled_mutations.replay_id(&intent).is_some() {
            self.pending_external_connect = Some(PendingExternalConnect { scope_id, specifier });
        } else if self
            .pending_external_connect
            .as_ref()
            .is_some_and(|pending| pending.scope_id == scope_id && pending.specifier == specifier)
        {
            self.pending_external_connect = None;
        }
        let connected = result?;
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
        let result: protocol::CreateWorkspaceResult = self.send_mutation(
            protocol::ProviderRequest::CreateWorkspace(protocol::CreateWorkspaceParams {
                machine_id: self.machine_id(key)?,
                mode,
                mutation_id: unassigned_mutation_id()?,
            }),
        )?;
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

    /// Sends one mutation, replaying the `mutation_id` an earlier unanswered
    /// attempt of the exact same request already sent.
    ///
    /// Every provider mutation goes through here, so every one is replayed
    /// and counted against `MAX_UNSETTLED_MUTATIONS`. The test
    /// `every_provider_mutate_call_goes_through_send_mutation` fails on a
    /// `.mutate(` call anywhere else in the crate.
    fn send_mutation<T>(&mut self, mut request: protocol::ProviderRequest) -> anyhow::Result<T>
    where
        T: serde::de::DeserializeOwned,
    {
        let mut intent = request.clone();
        let Some(intent_id) = request_mutation_id_mut(&mut intent) else {
            anyhow::bail!("machine-provider request carries no mutation id");
        };
        *intent_id = unassigned_mutation_id()?;
        // Refuse before minting an id, so a refused request leaves no trace.
        self.unsettled_mutations.admit(&intent)?;
        let replayed = self.unsettled_mutations.replay_id(&intent);
        let first_attempt = replayed.is_none();
        let mutation_id = match replayed {
            Some(mutation_id) => mutation_id,
            None => self.next_mutation_id()?,
        };
        if let Some(slot) = request_mutation_id_mut(&mut request) {
            *slot = mutation_id.clone();
        }
        self.unsettled_mutations.remember(intent.clone(), mutation_id)?;
        let result = self.client.mutate(request);
        // A first attempt that failed before its frame was written left
        // nothing on the provider, so it holds no slot. A replay keeps its
        // entry: an earlier attempt with that id may still commit.
        let never_sent = first_attempt
            && result.as_ref().err().is_some_and(ProviderClientError::proves_request_unsent);
        if never_sent || mutation_answer_is_definite(&result) {
            self.unsettled_mutations.settle(&intent);
        }
        Ok(result?)
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

fn placeholder_session() -> Session {
    Session::Local(Mux::new(
        format!("provider-placeholder-{}", std::process::id()),
        SurfaceOptions::default(),
    ))
}

#[cfg(test)]
#[path = "machine_provider_runtime_tests.rs"]
mod tests;

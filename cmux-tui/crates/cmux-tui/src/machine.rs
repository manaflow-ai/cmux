//! Client-local machine catalog values.
//!
//! Machines are connection targets. Each target exposes an ordinary cmux
//! session whose workspaces remain owned by that machine. The catalog is a
//! presentation snapshot so cloud, SSH, local-socket, and future transports
//! can share the same Ratatui rail without sharing provider implementation.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Receiver;
use std::thread::JoinHandle;

use crate::session::Session;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct MachineKey(pub u64);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
// The static connector currently emits only Running and Unavailable. Dynamic
// providers use the other states when their catalog adapter lands.
#[allow(dead_code)]
pub enum MachineStatus {
    Running,
    Connecting,
    Sleeping,
    Stopped,
    Unavailable,
}

/// Client-side transport state. Provider lifecycle state remains in
/// [`MachineStatus`], so selecting a running VM never has to imply that its
/// terminal transport has finished opening.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum MachineConnectionPhase {
    #[default]
    Disconnected,
    Connecting,
    Ready,
    Failed,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct MachineCapabilities {
    pub create: bool,
    pub connect: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MachineDescriptor {
    pub key: MachineKey,
    /// Provider-stable identifier. It is deliberately opaque to the TUI.
    pub id: String,
    pub name: String,
    pub subtitle: String,
    pub status: MachineStatus,
}

/// Provider-owned identity boundary shown above the machine catalog. The TUI
/// treats the identifier as opaque and never infers permissions from the
/// display name or scope kind.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProviderScopeDescriptor {
    pub id: String,
    pub name: String,
    pub kind: ProviderScopeKind,
    pub can_admin: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
// Constructed by the dynamic provider adapter. Static catalogs leave the
// provider presentation absent.
#[allow(dead_code)]
pub enum ProviderScopeKind {
    Personal,
    Team,
}

/// A provider action field that can be collected by the shared text prompt.
/// Multiple fields remain representable so a future form surface can support
/// them without changing the provider boundary.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProviderActionFieldDescriptor {
    pub id: String,
    pub label: String,
    pub kind: ProviderActionFieldKind,
    pub required: bool,
    pub max_length: Option<u32>,
    pub minimum: Option<i64>,
    pub maximum: Option<i64>,
    pub placeholder: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[allow(dead_code)]
pub enum ProviderActionFieldKind {
    Text,
    Email,
    Integer,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum ProviderActionTarget {
    #[default]
    Scope,
    SelectedMachine,
    SelectedWorkspace,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ProviderActionContext {
    pub machine_id: Option<String>,
    pub workspace_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProviderActionDescriptor {
    pub id: String,
    pub label: String,
    pub target: ProviderActionTarget,
    pub destructive: bool,
    pub fields: Vec<ProviderActionFieldDescriptor>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProviderPresentation {
    pub scopes: Vec<ProviderScopeDescriptor>,
    pub selected_scope_id: String,
    pub actions: Vec<ProviderActionDescriptor>,
}

impl ProviderPresentation {
    pub fn selected_scope(&self) -> Option<&ProviderScopeDescriptor> {
        self.scopes.iter().find(|scope| scope.id == self.selected_scope_id)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProviderActionValue {
    Text(String),
    Integer(i64),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProviderActionInputError {
    Required,
    TooLong,
    InvalidEmail,
    InvalidInteger,
    BelowMinimum,
    AboveMaximum,
    MissingSelectedMachine,
    MissingSelectedWorkspace,
    UnsupportedFieldCount,
}

impl ProviderActionDescriptor {
    /// Build a typed provider request from the shared one-field text prompt.
    /// Zero-field actions submit immediately. Descriptors with more than one
    /// field are rejected until the TUI has a real multi-field form.
    pub fn request(
        &self,
        input: Option<&str>,
        context: &ProviderActionContext,
    ) -> Result<MachineRequest, ProviderActionInputError> {
        let mut values = BTreeMap::new();
        match self.fields.as_slice() {
            [] => {}
            [field] => {
                let value = field.validate(input.unwrap_or_default())?;
                if let Some(value) = value {
                    values.insert(field.id.clone(), value);
                }
            }
            _ => return Err(ProviderActionInputError::UnsupportedFieldCount),
        }
        let (machine_id, workspace_id) = match self.target {
            ProviderActionTarget::Scope => (None, None),
            ProviderActionTarget::SelectedMachine => (
                Some(
                    context
                        .machine_id
                        .clone()
                        .ok_or(ProviderActionInputError::MissingSelectedMachine)?,
                ),
                None,
            ),
            ProviderActionTarget::SelectedWorkspace => (
                Some(
                    context
                        .machine_id
                        .clone()
                        .ok_or(ProviderActionInputError::MissingSelectedMachine)?,
                ),
                Some(
                    context
                        .workspace_id
                        .clone()
                        .ok_or(ProviderActionInputError::MissingSelectedWorkspace)?,
                ),
            ),
        };
        Ok(MachineRequest::InvokeProviderAction {
            action_id: self.id.clone(),
            values,
            machine_id,
            workspace_id,
        })
    }
}

impl ProviderActionFieldDescriptor {
    fn validate(
        &self,
        input: &str,
    ) -> Result<Option<ProviderActionValue>, ProviderActionInputError> {
        let input = input.trim();
        if input.is_empty() {
            return if self.required { Err(ProviderActionInputError::Required) } else { Ok(None) };
        }
        if self.max_length.is_some_and(|maximum| input.chars().count() > maximum as usize) {
            return Err(ProviderActionInputError::TooLong);
        }
        match self.kind {
            ProviderActionFieldKind::Text => Ok(Some(ProviderActionValue::Text(input.to_string()))),
            ProviderActionFieldKind::Email => {
                let mut parts = input.split('@');
                let local = parts.next().unwrap_or_default();
                let domain = parts.next().unwrap_or_default();
                if local.is_empty()
                    || domain.is_empty()
                    || parts.next().is_some()
                    || input.chars().any(char::is_whitespace)
                {
                    return Err(ProviderActionInputError::InvalidEmail);
                }
                Ok(Some(ProviderActionValue::Text(input.to_string())))
            }
            ProviderActionFieldKind::Integer => {
                let value =
                    input.parse::<i64>().map_err(|_| ProviderActionInputError::InvalidInteger)?;
                if self.minimum.is_some_and(|minimum| value < minimum) {
                    return Err(ProviderActionInputError::BelowMinimum);
                }
                if self.maximum.is_some_and(|maximum| value > maximum) {
                    return Err(ProviderActionInputError::AboveMaximum);
                }
                Ok(Some(ProviderActionValue::Integer(value)))
            }
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum WorkspaceCreationMode {
    Isolated,
    Host,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub enum WorkspaceCreationPolicy {
    #[default]
    SessionOwned,
    // Constructed by provider adapters; the static socket/SSH runtime remains session-owned.
    #[allow(dead_code)]
    ProviderOwned { default_mode: WorkspaceCreationMode, modes: Vec<WorkspaceCreationMode> },
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ManagedWorkspaceCapabilities {
    pub rename: bool,
    pub delete: bool,
    pub restore: bool,
    pub purge: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ManagedWorkspaceStatus {
    Active,
    Recoverable,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ManagedWorkspaceDescriptor {
    /// Provider-stable workspace identifier, also used as the nested cmux key.
    pub id: String,
    pub name: String,
    pub mode: WorkspaceCreationMode,
    pub status: ManagedWorkspaceStatus,
    pub version: u64,
    pub recoverable_until: Option<String>,
    pub capabilities: ManagedWorkspaceCapabilities,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ManagedMachineCapabilities {
    pub rename: bool,
    pub delete: bool,
    pub restore: bool,
    pub purge: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ManagedMachineStatus {
    Active,
    Recoverable,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ManagedMachineDescriptor {
    pub key: MachineKey,
    pub id: String,
    pub name: String,
    pub status: ManagedMachineStatus,
    pub version: u64,
    pub recoverable_until: Option<String>,
    pub capabilities: ManagedMachineCapabilities,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MachineSnapshot {
    pub machines: Vec<MachineDescriptor>,
    pub active: Option<MachineKey>,
    pub capabilities: MachineCapabilities,
}

impl MachineSnapshot {
    pub fn active_index(&self) -> Option<usize> {
        let active = self.active?;
        self.machines.iter().position(|machine| machine.key == active)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MachineConnectRoute {
    Local,
    Provider,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MachineRequest {
    Switch(MachineKey),
    /// Internal lifecycle request emitted when the provider control socket
    /// closes. The runtime reconnects and fetches an authoritative snapshot
    /// before reopening the selected machine.
    ReconnectProvider,
    Create,
    /// Select one native creation source advertised by the client-local
    /// catalog. Dynamic providers continue to own the source-less `Create`.
    CreateFrom {
        source_id: String,
    },
    Connect {
        target: String,
        route: MachineConnectRoute,
    },
    SelectProviderScope(String),
    InvokeProviderAction {
        action_id: String,
        values: BTreeMap<String, ProviderActionValue>,
        machine_id: Option<String>,
        workspace_id: Option<String>,
    },
    RenameManagedMachine {
        machine: MachineKey,
        expected_version: u64,
        name: String,
    },
    /// Rename a row owned by the client-local catalog. This changes only the
    /// current process's presentation; it never rewrites SSH or cmux config.
    RenameClientMachine {
        machine: MachineKey,
        name: String,
    },
    DeleteManagedMachine {
        machine: MachineKey,
        expected_version: u64,
    },
    RestoreManagedMachine {
        machine: MachineKey,
        expected_version: u64,
    },
    PurgeManagedMachine {
        machine: MachineKey,
        expected_version: u64,
    },
    CreateManagedIsolatedWorkspace(MachineKey),
    CreateManagedHostWorkspace(MachineKey),
    RenameManagedWorkspace {
        machine: MachineKey,
        workspace_id: String,
        expected_version: u64,
        name: String,
    },
    DeleteManagedWorkspace {
        machine: MachineKey,
        workspace_id: String,
        expected_version: u64,
    },
    RestoreManagedWorkspace {
        machine: MachineKey,
        workspace_id: String,
        expected_version: u64,
    },
    PurgeManagedWorkspace {
        machine: MachineKey,
        workspace_id: String,
        expected_version: u64,
    },
}

/// Nested mux mutation applied only after the provider durably accepts it.
pub(crate) enum ManagedWorkspaceSessionMutation {
    Rename { workspace_key: String, name: String },
    Close { workspace_key: String },
}

/// A fully opened replacement session. Controllers construct this before
/// changing their active connection so a failed open leaves the current
/// session usable.
/// What the connect interstitial renders for the machine being opened: its
/// name, transport phase, last known provider status, and the provider's
/// latest connect-time progress message when one arrived.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MachineTransitionView<'a> {
    pub name: &'a str,
    pub phase: MachineConnectionPhase,
    pub status: MachineStatus,
    pub progress: Option<&'a str>,
}

pub(crate) struct MachineSession {
    pub session: Session,
    pub label: String,
    pub machine: Option<MachineKey>,
    /// True when the session came from the warm connection pool: it was fully
    /// prepared when first opened, so per-switch preparation round-trips
    /// (managed-workspace guard, default colors) can be skipped.
    pub reused: bool,
}

/// The result of one machine-side action. Most actions only update the rail;
/// switching and revocation additionally replace the attached mux session.
pub(crate) struct MachineActionResult {
    pub ui: MachineUiState,
    pub replacement: Option<MachineSession>,
    pub restart_updates: bool,
    pub session_mutation: Option<ManagedWorkspaceSessionMutation>,
    pub session_label: Option<String>,
}

impl MachineActionResult {
    pub(crate) fn ui(ui: MachineUiState) -> Self {
        Self {
            ui,
            replacement: None,
            restart_updates: false,
            session_mutation: None,
            session_label: None,
        }
    }

    pub(crate) fn replace(ui: MachineUiState, session: Session, label: String) -> Self {
        let machine = ui.snapshot.active;
        Self {
            ui,
            replacement: Some(MachineSession { session, label, machine, reused: false }),
            restart_updates: false,
            session_mutation: None,
            session_label: None,
        }
    }

    /// Mark the replacement session as reused from the warm pool.
    pub(crate) fn with_reused_session(mut self, reused: bool) -> Self {
        if let Some(replacement) = self.replacement.as_mut() {
            replacement.reused = reused;
        }
        self
    }

    pub(crate) fn with_session_mutation(
        mut self,
        mutation: ManagedWorkspaceSessionMutation,
    ) -> Self {
        self.session_mutation = Some(mutation);
        self
    }

    pub(crate) fn with_session_label(mut self, label: String) -> Self {
        self.session_label = Some(label);
        self
    }
}

pub(crate) fn validate_machine_session(
    session: &Session,
    ui: &MachineUiState,
) -> anyhow::Result<()> {
    if matches!(ui.workspace_creation_policy(), Some(WorkspaceCreationPolicy::ProviderOwned { .. }))
    {
        session.mark_workspaces_provider_managed()?;
    }
    Ok(())
}

/// Mutable machine lifecycle boundary owned by the long-lived TUI app.
pub(crate) trait MachineController: Send {
    fn perform(&mut self, request: MachineRequest) -> anyhow::Result<MachineActionResult>;

    /// Persist acknowledgement of a provider notice only after the app has
    /// accepted and painted that exact delivery.
    fn acknowledge_durable_notice(
        &mut self,
        _delivery: &DurableNoticeDelivery,
    ) -> anyhow::Result<()> {
        Ok(())
    }

    /// Commit controller-side ownership changes for a replacement only after
    /// the replacement session has passed the shared workspace guard.
    fn commit_replacement(&mut self, _present: bool) -> anyhow::Result<()> {
        Ok(())
    }

    /// Discard a prepared replacement while leaving the active transport and
    /// controller selection unchanged.
    fn abort_replacement(&mut self) {}

    fn subscribe_updates(&self) -> anyhow::Result<Option<MachineUpdateStream>> {
        Ok(None)
    }

    fn close(&mut self) {}
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum MachineRailSelection {
    Scope,
    Actions,
    #[default]
    Machine,
    NewVm,
    ConnectMachine,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MachineRailTarget {
    Scope,
    Actions,
    Machine(MachineKey),
    NewVm,
    ConnectMachine,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MachineCreationSource {
    pub id: String,
    pub name: String,
    pub subtitle: String,
}

/// A client-local destination advertised by a native connection source.
/// `target` is opaque to the picker and is passed back to the owning route.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MachineConnectionTarget {
    pub target: String,
    pub name: String,
}

#[derive(Debug, Clone)]
pub struct MachineUiState {
    pub snapshot: MachineSnapshot,
    pub selection: usize,
    pub request: Option<MachineRequest>,
    pub notice: Option<String>,
    pub session_available: bool,
    pub provider: Option<ProviderPresentation>,
    pub connect_accepts_pairing_code: bool,
    pub rail_selection: MachineRailSelection,
    pub creation_sources: Vec<MachineCreationSource>,
    pub connection_targets: Vec<MachineConnectionTarget>,
    connection_phases: HashMap<MachineKey, MachineConnectionPhase>,
    /// Latest provider-pushed progress message per opening machine
    /// (connection-progress-v1), rendered by the connect interstitial.
    connection_progress: HashMap<MachineKey, String>,
    workspace_creation: HashMap<MachineKey, WorkspaceCreationPolicy>,
    client_renamable_machines: HashSet<MachineKey>,
    managed_machines: Vec<ManagedMachineDescriptor>,
    managed_workspaces: HashMap<MachineKey, Vec<ManagedWorkspaceDescriptor>>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DurableNoticeLevel {
    Info,
    Warning,
    Error,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct DurableNoticeDelivery {
    pub notice_id: String,
    pub sequence: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DurableProviderNotice {
    pub delivery: DurableNoticeDelivery,
    pub level: DurableNoticeLevel,
    pub message: String,
}

#[derive(Debug, Clone)]
pub enum MachineUpdate {
    Ui(Box<MachineUiState>),
    DurableNotice(DurableProviderNotice),
    /// Provider-pushed connect-time step for one machine, forwarded without a
    /// snapshot reload so it renders while the provider's serialized control
    /// loop is still busy opening that machine. The message rides a shared
    /// latest-value cell: a chatty provider overwrites the pending message
    /// instead of queueing another update, so at most one progress update per
    /// machine is ever in flight and the consumer always reads the newest
    /// stage.
    ConnectionProgress {
        machine_id: String,
        latest: Arc<std::sync::Mutex<Option<String>>>,
    },
}

/// A cancelable stream of provider-owned presentation snapshots.
pub struct MachineUpdateStream {
    receiver: Option<Receiver<MachineUpdate>>,
    stop: Arc<AtomicBool>,
    worker: Option<JoinHandle<()>>,
    armed: bool,
}

impl MachineUpdateStream {
    pub fn new(
        receiver: Receiver<MachineUpdate>,
        stop: Arc<AtomicBool>,
        worker: JoinHandle<()>,
    ) -> Self {
        Self { receiver: Some(receiver), stop, worker: Some(worker), armed: true }
    }

    pub(crate) fn into_parts(
        mut self,
    ) -> (Receiver<MachineUpdate>, Arc<AtomicBool>, JoinHandle<()>) {
        self.armed = false;
        (
            self.receiver.take().expect("machine update receiver is present"),
            self.stop.clone(),
            self.worker.take().expect("machine update worker is present"),
        )
    }

    pub(crate) fn stop_handle(&self) -> Arc<AtomicBool> {
        self.stop.clone()
    }
}

impl Drop for MachineUpdateStream {
    fn drop(&mut self) {
        if self.armed {
            self.stop.store(true, Ordering::Release);
            // Drop the receiver before joining so a worker blocked on a full
            // bounded channel observes cancellation instead of deadlocking.
            self.receiver.take();
            if let Some(worker) = self.worker.take() {
                let _ = worker.join();
            }
        }
    }
}

impl MachineUiState {
    pub fn new(snapshot: MachineSnapshot) -> Self {
        let selection = snapshot.active_index().unwrap_or_default();
        let session_available = snapshot.active_index().is_some();
        let connection_phases = snapshot
            .active
            .map(|active| (active, MachineConnectionPhase::Ready))
            .into_iter()
            .collect();
        let mut state = Self {
            snapshot,
            selection,
            request: None,
            notice: None,
            session_available,
            provider: None,
            connect_accepts_pairing_code: false,
            rail_selection: MachineRailSelection::Machine,
            creation_sources: Vec::new(),
            connection_targets: Vec::new(),
            connection_phases,
            connection_progress: HashMap::new(),
            workspace_creation: HashMap::new(),
            client_renamable_machines: HashSet::new(),
            managed_machines: Vec::new(),
            managed_workspaces: HashMap::new(),
        };
        state.ensure_rail_selection();
        state
    }

    pub fn connection_phase(&self, machine: MachineKey) -> MachineConnectionPhase {
        self.connection_phases.get(&machine).copied().unwrap_or_default()
    }

    pub fn set_connection_phase(&mut self, machine: MachineKey, phase: MachineConnectionPhase) {
        self.connection_phases.insert(machine, phase);
    }

    pub fn set_connection_phases(
        &mut self,
        phases: impl IntoIterator<Item = (MachineKey, MachineConnectionPhase)>,
    ) {
        self.connection_phases = phases.into_iter().collect();
    }

    pub fn extend_connection_phases_from(&mut self, previous: &Self) {
        let visible =
            self.snapshot.machines.iter().map(|machine| machine.key).collect::<HashSet<_>>();
        for (machine, phase) in &previous.connection_phases {
            if visible.contains(machine) {
                self.connection_phases.entry(*machine).or_insert(*phase);
            }
        }
        // Progress is transient connect-time state; a snapshot rebuild
        // mid-connect must not blank the interstitial's live message - but a
        // machine no longer Connecting (settled, failed, or disconnected via
        // this very snapshot) must not keep narrating a finished open.
        for (machine, message) in &previous.connection_progress {
            if visible.contains(machine)
                && self.connection_phase(*machine) == MachineConnectionPhase::Connecting
            {
                self.connection_progress.entry(*machine).or_insert_with(|| message.clone());
            }
        }
    }

    pub fn connection_progress(&self, machine: MachineKey) -> Option<&str> {
        self.connection_progress.get(&machine).map(String::as_str)
    }

    pub fn set_connection_progress(&mut self, machine: MachineKey, message: String) {
        self.connection_progress.insert(machine, message);
    }

    pub fn clear_connection_progress(&mut self, machine: MachineKey) {
        self.connection_progress.remove(&machine);
    }

    pub fn selected(&self) -> Option<&MachineDescriptor> {
        self.snapshot.machines.get(self.selection)
    }

    #[allow(dead_code)]
    pub fn set_provider_presentation(&mut self, provider: ProviderPresentation) {
        self.provider = Some(provider);
        if self.snapshot.machines.is_empty()
            && self.provider.as_ref().is_some_and(|provider| !provider.scopes.is_empty())
        {
            self.rail_selection = MachineRailSelection::Scope;
        } else {
            self.ensure_rail_selection();
        }
    }

    #[allow(dead_code)]
    pub fn selected_scope(&self) -> Option<&ProviderScopeDescriptor> {
        self.provider.as_ref()?.selected_scope()
    }

    // Provider adapters populate this sidecar after translating their snapshot.
    #[allow(dead_code)]
    pub fn set_workspace_creation_policy(
        &mut self,
        machine: MachineKey,
        policy: WorkspaceCreationPolicy,
    ) {
        self.workspace_creation.insert(machine, policy);
    }

    pub fn workspace_creation_policy(&self) -> Option<WorkspaceCreationPolicy> {
        let active = self.snapshot.active?;
        self.snapshot
            .machines
            .iter()
            .any(|machine| machine.key == active)
            .then(|| self.workspace_creation.get(&active).cloned().unwrap_or_default())
    }

    pub fn is_provider_machine(&self, machine: MachineKey) -> bool {
        self.workspace_creation.contains_key(&machine)
    }

    pub fn set_client_renamable_machines(
        &mut self,
        machines: impl IntoIterator<Item = MachineKey>,
    ) {
        self.client_renamable_machines = machines.into_iter().collect();
    }

    pub fn extend_client_renamable_machines(
        &mut self,
        machines: impl IntoIterator<Item = MachineKey>,
    ) {
        self.client_renamable_machines.extend(machines);
    }

    pub fn is_client_machine_renamable(&self, machine: MachineKey) -> bool {
        self.client_renamable_machines.contains(&machine)
    }

    pub fn set_managed_machines(&mut self, machines: Vec<ManagedMachineDescriptor>) {
        self.managed_machines = machines;
    }

    pub fn managed_machines(&self) -> &[ManagedMachineDescriptor] {
        &self.managed_machines
    }

    pub fn managed_machine(&self, key: MachineKey) -> Option<&ManagedMachineDescriptor> {
        self.managed_machines.iter().find(|machine| machine.key == key)
    }

    pub fn set_managed_workspaces(
        &mut self,
        machine: MachineKey,
        workspaces: Vec<ManagedWorkspaceDescriptor>,
    ) {
        self.managed_workspaces.insert(machine, workspaces);
    }

    pub fn managed_workspaces(&self) -> &[ManagedWorkspaceDescriptor] {
        self.snapshot
            .active
            .and_then(|machine| self.managed_workspaces.get(&machine))
            .map(Vec::as_slice)
            .unwrap_or_default()
    }

    pub fn managed_workspace(&self, id: &str) -> Option<&ManagedWorkspaceDescriptor> {
        self.managed_workspaces().iter().find(|workspace| workspace.id == id)
    }

    pub fn recoverable_workspaces(&self) -> Vec<&ManagedWorkspaceDescriptor> {
        self.managed_workspaces()
            .iter()
            .filter(|workspace| workspace.status == ManagedWorkspaceStatus::Recoverable)
            .collect()
    }

    pub fn rail_targets(&self) -> Vec<MachineRailTarget> {
        let mut targets = Vec::with_capacity(self.snapshot.machines.len() + 4);
        if self.provider.as_ref().is_some_and(|provider| !provider.scopes.is_empty()) {
            targets.push(MachineRailTarget::Scope);
        }
        if self.provider.as_ref().is_some_and(|provider| !provider.actions.is_empty()) {
            targets.push(MachineRailTarget::Actions);
        }
        targets.extend(
            self.snapshot.machines.iter().map(|machine| MachineRailTarget::Machine(machine.key)),
        );
        if self.snapshot.capabilities.create {
            targets.push(MachineRailTarget::NewVm);
        }
        if self.snapshot.capabilities.connect {
            targets.push(MachineRailTarget::ConnectMachine);
        }
        targets
    }

    pub fn rail_target(&self) -> Option<MachineRailTarget> {
        match self.rail_selection {
            MachineRailSelection::Scope => Some(MachineRailTarget::Scope),
            MachineRailSelection::Actions => Some(MachineRailTarget::Actions),
            MachineRailSelection::Machine => {
                self.selected().map(|machine| MachineRailTarget::Machine(machine.key))
            }
            MachineRailSelection::NewVm => Some(MachineRailTarget::NewVm),
            MachineRailSelection::ConnectMachine => Some(MachineRailTarget::ConnectMachine),
        }
    }

    pub fn select_rail_target(&mut self, target: MachineRailTarget) {
        match target {
            MachineRailTarget::Scope => self.rail_selection = MachineRailSelection::Scope,
            MachineRailTarget::Actions => self.rail_selection = MachineRailSelection::Actions,
            MachineRailTarget::Machine(key) => {
                if let Some(index) =
                    self.snapshot.machines.iter().position(|machine| machine.key == key)
                {
                    self.selection = index;
                    self.rail_selection = MachineRailSelection::Machine;
                }
            }
            MachineRailTarget::NewVm => self.rail_selection = MachineRailSelection::NewVm,
            MachineRailTarget::ConnectMachine => {
                self.rail_selection = MachineRailSelection::ConnectMachine;
            }
        }
    }

    pub fn reconcile_navigation_from(&mut self, previous: &Self) {
        let targets = self.rail_targets();
        if targets.is_empty() {
            self.selection = 0;
            self.rail_selection = MachineRailSelection::Machine;
            return;
        }
        let previous_targets = previous.rail_targets();
        let previous_target = previous.rail_target();
        let target = previous_target
            .filter(|target| targets.contains(target))
            .or_else(|| {
                self.snapshot.active.and_then(|active| {
                    let target = MachineRailTarget::Machine(active);
                    targets.contains(&target).then_some(target)
                })
            })
            .unwrap_or_else(|| {
                let previous_index = previous_target
                    .and_then(|target| previous_targets.iter().position(|item| *item == target))
                    .unwrap_or_default();
                targets[previous_index.min(targets.len() - 1)]
            });
        self.select_rail_target(target);
    }

    fn ensure_rail_selection(&mut self) {
        let targets = self.rail_targets();
        if targets.is_empty() {
            self.selection = 0;
            self.rail_selection = MachineRailSelection::Machine;
            return;
        }
        if let Some(target) = self.rail_target()
            && targets.contains(&target)
        {
            return;
        }
        self.select_rail_target(targets[0]);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ui_selection_starts_on_the_active_machine() {
        let snapshot = MachineSnapshot {
            machines: vec![
                MachineDescriptor {
                    key: MachineKey(1),
                    id: "one".into(),
                    name: "one".into(),
                    subtitle: String::new(),
                    status: MachineStatus::Running,
                },
                MachineDescriptor {
                    key: MachineKey(2),
                    id: "two".into(),
                    name: "two".into(),
                    subtitle: String::new(),
                    status: MachineStatus::Sleeping,
                },
            ],
            active: Some(MachineKey(2)),
            capabilities: MachineCapabilities::default(),
        };

        let ui = MachineUiState::new(snapshot);
        assert_eq!(ui.selection, 1);
        assert_eq!(ui.selected().map(|machine| machine.key), Some(MachineKey(2)));
        assert!(ui.session_available);
        assert_eq!(ui.workspace_creation_policy(), Some(WorkspaceCreationPolicy::SessionOwned));
    }

    #[test]
    fn zero_machine_snapshot_has_no_active_session_or_workspace_policy() {
        let ui = MachineUiState::new(MachineSnapshot {
            machines: Vec::new(),
            active: None,
            capabilities: MachineCapabilities { create: true, connect: true },
        });

        assert_eq!(ui.selection, 0);
        assert!(ui.selected().is_none());
        assert!(!ui.session_available);
        assert_eq!(ui.workspace_creation_policy(), None);
    }

    #[test]
    fn workspace_creation_policy_is_scoped_to_the_active_machine() {
        let first = MachineKey(1);
        let second = MachineKey(2);
        let mut ui = MachineUiState::new(MachineSnapshot {
            machines: vec![
                MachineDescriptor {
                    key: first,
                    id: "one".into(),
                    name: "one".into(),
                    subtitle: String::new(),
                    status: MachineStatus::Running,
                },
                MachineDescriptor {
                    key: second,
                    id: "two".into(),
                    name: "two".into(),
                    subtitle: String::new(),
                    status: MachineStatus::Running,
                },
            ],
            active: Some(first),
            capabilities: MachineCapabilities::default(),
        });
        let provider_policy = WorkspaceCreationPolicy::ProviderOwned {
            default_mode: WorkspaceCreationMode::Host,
            modes: vec![WorkspaceCreationMode::Host, WorkspaceCreationMode::Isolated],
        };
        ui.set_workspace_creation_policy(first, provider_policy.clone());

        assert_eq!(ui.workspace_creation_policy(), Some(provider_policy));
        ui.snapshot.active = Some(second);
        assert_eq!(ui.workspace_creation_policy(), Some(WorkspaceCreationPolicy::SessionOwned));
    }

    #[test]
    fn rail_targets_include_controls_catalog_and_pinned_actions_in_visual_order() {
        let mut ui = MachineUiState::new(MachineSnapshot {
            machines: vec![MachineDescriptor {
                key: MachineKey(7),
                id: "seven".into(),
                name: "seven".into(),
                subtitle: String::new(),
                status: MachineStatus::Running,
            }],
            active: Some(MachineKey(7)),
            capabilities: MachineCapabilities { create: true, connect: true },
        });
        ui.set_provider_presentation(ProviderPresentation {
            scopes: vec![ProviderScopeDescriptor {
                id: "personal".into(),
                name: "Personal".into(),
                kind: ProviderScopeKind::Personal,
                can_admin: false,
            }],
            selected_scope_id: "personal".into(),
            actions: vec![ProviderActionDescriptor {
                id: "billing".into(),
                label: "Billing".into(),
                target: ProviderActionTarget::Scope,
                destructive: false,
                fields: Vec::new(),
            }],
        });

        assert_eq!(
            ui.rail_targets(),
            vec![
                MachineRailTarget::Scope,
                MachineRailTarget::Actions,
                MachineRailTarget::Machine(MachineKey(7)),
                MachineRailTarget::NewVm,
                MachineRailTarget::ConnectMachine,
            ]
        );
    }

    #[test]
    fn catalog_refresh_preserves_selection_by_machine_key_after_reorder() {
        let descriptor = |key| MachineDescriptor {
            key: MachineKey(key),
            id: key.to_string(),
            name: key.to_string(),
            subtitle: String::new(),
            status: MachineStatus::Running,
        };
        let mut previous = MachineUiState::new(MachineSnapshot {
            machines: vec![descriptor(1), descriptor(2)],
            active: Some(MachineKey(1)),
            capabilities: MachineCapabilities::default(),
        });
        previous.select_rail_target(MachineRailTarget::Machine(MachineKey(2)));
        let mut update = MachineUiState::new(MachineSnapshot {
            machines: vec![descriptor(2), descriptor(1)],
            active: Some(MachineKey(1)),
            capabilities: MachineCapabilities::default(),
        });

        update.reconcile_navigation_from(&previous);

        assert_eq!(update.rail_target(), Some(MachineRailTarget::Machine(MachineKey(2))));
        assert_eq!(update.selection, 0);
    }

    fn action_field(kind: ProviderActionFieldKind) -> ProviderActionFieldDescriptor {
        ProviderActionFieldDescriptor {
            id: "value".into(),
            label: "Value".into(),
            kind,
            required: true,
            max_length: None,
            minimum: None,
            maximum: None,
            placeholder: None,
        }
    }

    fn action(fields: Vec<ProviderActionFieldDescriptor>) -> ProviderActionDescriptor {
        ProviderActionDescriptor {
            id: "action".into(),
            label: "Action".into(),
            target: ProviderActionTarget::Scope,
            destructive: false,
            fields,
        }
    }

    #[test]
    fn provider_presentation_resolves_selected_scope_by_opaque_id() {
        let mut ui = MachineUiState::new(MachineSnapshot {
            machines: Vec::new(),
            active: None,
            capabilities: MachineCapabilities::default(),
        });
        ui.set_provider_presentation(ProviderPresentation {
            scopes: vec![
                ProviderScopeDescriptor {
                    id: "personal-id".into(),
                    name: "Personal".into(),
                    kind: ProviderScopeKind::Personal,
                    can_admin: false,
                },
                ProviderScopeDescriptor {
                    id: "team-id".into(),
                    name: "Acme".into(),
                    kind: ProviderScopeKind::Team,
                    can_admin: true,
                },
            ],
            selected_scope_id: "team-id".into(),
            actions: Vec::new(),
        });

        assert_eq!(ui.selected_scope().map(|scope| scope.name.as_str()), Some("Acme"));
        assert_eq!(ui.rail_selection, MachineRailSelection::Scope);
    }

    #[test]
    fn provider_action_builds_zero_and_one_field_typed_requests() {
        assert_eq!(
            action(Vec::new()).request(None, &ProviderActionContext::default()),
            Ok(MachineRequest::InvokeProviderAction {
                action_id: "action".into(),
                values: BTreeMap::new(),
                machine_id: None,
                workspace_id: None,
            })
        );

        let request = action(vec![action_field(ProviderActionFieldKind::Email)])
            .request(Some("  person@example.com  "), &ProviderActionContext::default())
            .unwrap();
        assert_eq!(
            request,
            MachineRequest::InvokeProviderAction {
                action_id: "action".into(),
                values: BTreeMap::from([(
                    "value".into(),
                    ProviderActionValue::Text("person@example.com".into())
                )]),
                machine_id: None,
                workspace_id: None,
            }
        );
    }

    #[test]
    fn provider_action_validates_required_email_integer_and_field_count() {
        assert_eq!(
            action(vec![action_field(ProviderActionFieldKind::Text)])
                .request(Some(""), &ProviderActionContext::default()),
            Err(ProviderActionInputError::Required)
        );
        assert_eq!(
            action(vec![action_field(ProviderActionFieldKind::Email)])
                .request(Some("not-an-email"), &ProviderActionContext::default()),
            Err(ProviderActionInputError::InvalidEmail)
        );

        let mut integer = action_field(ProviderActionFieldKind::Integer);
        integer.minimum = Some(2);
        integer.maximum = Some(4);
        assert_eq!(
            action(vec![integer.clone()]).request(Some("one"), &ProviderActionContext::default()),
            Err(ProviderActionInputError::InvalidInteger)
        );
        assert_eq!(
            action(vec![integer.clone()]).request(Some("1"), &ProviderActionContext::default()),
            Err(ProviderActionInputError::BelowMinimum)
        );
        assert_eq!(
            action(vec![integer.clone()]).request(Some("5"), &ProviderActionContext::default()),
            Err(ProviderActionInputError::AboveMaximum)
        );
        assert_eq!(
            action(vec![integer, action_field(ProviderActionFieldKind::Text)])
                .request(None, &ProviderActionContext::default()),
            Err(ProviderActionInputError::UnsupportedFieldCount)
        );
    }

    #[test]
    fn provider_action_binds_selected_workspace_context() {
        let mut descriptor = action(Vec::new());
        descriptor.target = ProviderActionTarget::SelectedWorkspace;
        let context = ProviderActionContext {
            machine_id: Some("machine-1".into()),
            workspace_id: Some("workspace-1".into()),
        };
        assert_eq!(
            descriptor.request(None, &context),
            Ok(MachineRequest::InvokeProviderAction {
                action_id: "action".into(),
                values: BTreeMap::new(),
                machine_id: Some("machine-1".into()),
                workspace_id: Some("workspace-1".into()),
            })
        );
        assert_eq!(
            descriptor.request(
                None,
                &ProviderActionContext { machine_id: Some("machine-1".into()), workspace_id: None }
            ),
            Err(ProviderActionInputError::MissingSelectedWorkspace)
        );
        assert_eq!(
            descriptor.request(None, &ProviderActionContext::default()),
            Err(ProviderActionInputError::MissingSelectedMachine)
        );

        let mut machine_scoped = action(Vec::new());
        machine_scoped.target = ProviderActionTarget::SelectedMachine;
        assert_eq!(
            machine_scoped.request(None, &context),
            Ok(MachineRequest::InvokeProviderAction {
                action_id: "action".into(),
                values: BTreeMap::new(),
                machine_id: Some("machine-1".into()),
                workspace_id: None,
            })
        );
        assert_eq!(
            machine_scoped.request(None, &ProviderActionContext::default()),
            Err(ProviderActionInputError::MissingSelectedMachine)
        );
    }

    #[test]
    fn dropping_update_stream_cancels_and_joins_a_blocked_worker() {
        let update = MachineUiState::new(MachineSnapshot {
            machines: Vec::new(),
            active: None,
            capabilities: MachineCapabilities::default(),
        });
        let (sender, receiver) = std::sync::mpsc::sync_channel(1);
        sender.send(MachineUpdate::Ui(Box::new(update.clone()))).unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let exited = Arc::new(AtomicBool::new(false));
        let worker_exited = exited.clone();
        let worker = std::thread::spawn(move || {
            // This blocks until MachineUpdateStream drops its receiver.
            let _ = sender.send(MachineUpdate::Ui(Box::new(update)));
            worker_exited.store(true, Ordering::Release);
        });
        let stream = MachineUpdateStream::new(receiver, stop.clone(), worker);

        drop(stream);

        assert!(stop.load(Ordering::Acquire));
        assert!(exited.load(Ordering::Acquire));
    }
}

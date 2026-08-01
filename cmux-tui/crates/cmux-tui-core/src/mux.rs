//! The multiplexer: owns the session [`State`] and every surface runtime,
//! and broadcasts [`MuxEvent`]s to subscribed frontends.

mod public_projections;
mod resource_content;
mod resource_topology;

pub(crate) use resource_content::ResourceEffectProjection;

use public_projections::{RestoredPublicProjections, restore_public_projections};
use std::collections::{HashMap, HashSet, VecDeque};
use std::fmt;
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc::{Receiver, SyncSender};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, OnceLock, Weak};
use std::thread::ThreadId;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::Context;
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};
use zeroize::Zeroize;

use crate::browser::{self, BrowserBootstrap, BrowserRuntime, BrowserSource};
use crate::event_bus::{MuxEventBroadcaster, MuxEventReceiver};
#[cfg(test)]
use crate::layout::layout_screen_with_viewport;
use crate::layout::{
    LayoutResult, MAX_VIEWPORT_PANE_WIDTH, MIN_VIEWPORT_PANE_WIDTH, Rect, layout_screen,
};
#[cfg(test)]
use crate::model::ViewportColumn;
use crate::model::{
    LayoutColumn, LayoutMutationKey, LayoutResizeOwner, Node, Pane, Screen, State, Workspace,
};
use crate::pairing::PairingBroker;
use crate::resource::{
    AgentPublicId, ContentPublicId, FrontendProjectionPublicId, NotificationPublicId,
    PairingRequestPublicId, PanePublicId, PublicSlotIndexes, ResourceError, ResourceOperation,
    ScreenPublicId, Selector, SidebarViewPublicId, SplitPublicId, TabPublicId, TabResourceIdentity,
    TerminalPublicId, WorkspacePublicId,
};
use crate::resource_mutation::{ResourceMutationMetrics, ResourceMutationPlan};
use crate::resource_selector::{
    ResolvedResourceSlots, ResourceSelectorContext, resolve_resource_selectors,
};
use crate::surface::{
    DefaultColors, Surface, SurfaceOptions, SurfaceShutdownOwner, SurfaceShutdownOwnerIdentity,
};
use crate::terminal_host::TerminalId;
use crate::terminal_host_protocol::TerminalExit;
use crate::terminal_host_runtime::TerminalHostIdentity;
#[cfg(unix)]
use crate::terminal_host_runtime::TerminalHostLiveness;
use crate::workspace_registry::{
    FrontendProjection, ProjectionCommit, RegistryBrowser, RegistryBrowserReconnect,
    RegistryCommit, RegistryLayoutNode, RegistrySnapshot, RegistryTab, RegistryTerminal,
    RegistryViewport, RegistryWorkspace, ResourceChange, ResourceEffectOutcome,
    ResourceEffectPreparation, ResourcePatch, ResourcePatchCommit, ResourceTopologySnapshot,
    TerminalLifecycle, TerminalRegistrySnapshot, WorkspaceMutation, WorkspaceRegistry,
};
use crate::{
    PairingChallenge, PairingDecision, PairingError, PaneId, ScreenId, SplitDir, SplitId,
    SurfaceId, WorkspaceId,
};

pub type SurfaceResizeReporter = Arc<dyn Fn(SurfaceId, (u16, u16), Option<u64>) + Send + Sync>;
#[cfg(test)]
type ShutdownAttemptHook = Arc<dyn Fn(usize) + Send + Sync>;
#[cfg(unix)]
type TerminalHostRecords =
    Vec<(std::path::PathBuf, crate::terminal_host_runtime::TerminalHostRecord)>;
#[cfg(all(test, unix))]
type TerminalAdoptionSurfaceFactory =
    Arc<dyn Fn(SurfaceId) -> anyhow::Result<Arc<Surface>> + Send + Sync>;
#[cfg(all(test, unix))]
type TerminalHostRecordLoader = Arc<
    dyn Fn(std::path::PathBuf, usize, Instant) -> anyhow::Result<TerminalHostRecords> + Send + Sync,
>;
#[cfg(test)]
type NewPaneAfterSpawnHook = Arc<dyn Fn(Arc<Surface>) + Send + Sync>;
#[cfg(test)]
type BrowserTabAfterSpawnHook = Arc<dyn Fn(Arc<Surface>) + Send + Sync>;

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct DaemonIdentity {
    pub(crate) pid: u32,
    pub(crate) generation: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct DaemonHandoffRequest {
    pub(crate) expected_identity: Option<DaemonIdentity>,
    pub(crate) force: bool,
}

impl DaemonHandoffRequest {
    pub(crate) fn unfenced(force: bool) -> Self {
        Self { expected_identity: None, force }
    }

    pub(crate) fn fenced(pid: u32, generation: String, force: bool) -> Self {
        Self { expected_identity: Some(DaemonIdentity { pid, generation }), force }
    }
}

#[cfg(test)]
type WorkspaceRenameHook = Arc<dyn Fn(&WorkspacePublicId) + Send + Sync>;
#[cfg(test)]
type TerminalReservationHook = Arc<dyn Fn(&str) + Send + Sync>;
type RestoredViewport = (std::collections::BTreeMap<SplitId, f32>, Option<f32>, Vec<LayoutColumn>);

const TERMINAL_DIMENSION_MAX: u16 = 10_000;
const WORKSPACE_REGISTRY_LIMIT: usize = 4_096;
const WORKSPACE_KEY_MAX_BYTES: usize = 256;
const WORKSPACE_NAME_MAX_BYTES: usize = 1_024;
const PROVIDER_WORKSPACE_AUTHORITY_MIN_BYTES: usize = 32;
const PROVIDER_WORKSPACE_AUTHORITY_MAX_BYTES: usize = 512;
const SHUTDOWN_TERMINATION_TIMEOUT: Duration = Duration::from_millis(100);
const SHUTDOWN_FANOUT_WORKERS: usize = 32;
const SHUTDOWN_RECONCILE_INITIAL_DELAY: Duration = Duration::from_millis(25);
const SHUTDOWN_RECONCILE_MAX_DELAY: Duration = Duration::from_secs(1);
const SERVER_EXIT_RETRY_INITIAL_DELAY: Duration = Duration::from_millis(25);
const SERVER_EXIT_RETRY_MAX_DELAY: Duration = Duration::from_secs(1);
#[cfg(test)]
const SERVER_EXIT_TEST_ATTEMPT_BUDGET: u32 = 8;
const SHUTDOWN_OWNER_CAPACITY: usize = 4_096;
#[cfg(unix)]
const TERMINAL_ADOPTION_QUEUE_CAPACITY: usize = SHUTDOWN_OWNER_CAPACITY;
#[cfg(unix)]
const TERMINAL_ADOPTION_DEFERRED_CAPACITY: usize = TERMINAL_ADOPTION_QUEUE_CAPACITY;
#[cfg(unix)]
const TERMINAL_ADOPTION_WORKERS: usize = 4;
#[cfg(not(test))]
const SHUTDOWN_RECONCILE_MAX_ATTEMPTS: usize = 8;
#[cfg(test)]
const SHUTDOWN_RECONCILE_MAX_ATTEMPTS: usize = 3;

#[cfg(unix)]
struct TerminalAdoptionTask {
    options: SurfaceOptions,
    record: crate::terminal_host_runtime::TerminalHostRecord,
    record_path: std::path::PathBuf,
    next_attempt: Instant,
    delay: Duration,
}

#[cfg(unix)]
struct TerminalAdoptionQueueState {
    tasks: Vec<TerminalAdoptionTask>,
    deferred: VecDeque<TerminalAdoptionTask>,
    in_flight: usize,
    rescan_required: bool,
    next_rescan: Option<Instant>,
    rescan_delay: Duration,
    workers_running: usize,
    stopping: bool,
}

#[cfg(unix)]
impl Default for TerminalAdoptionQueueState {
    fn default() -> Self {
        Self {
            tasks: Vec::new(),
            deferred: VecDeque::new(),
            in_flight: 0,
            rescan_required: false,
            next_rescan: None,
            rescan_delay: Duration::from_millis(100),
            workers_running: 0,
            stopping: false,
        }
    }
}

#[cfg(unix)]
impl TerminalAdoptionQueueState {
    fn active_len(&self) -> usize {
        self.tasks.len() + self.in_flight
    }

    fn enqueue(&mut self, task: TerminalAdoptionTask) -> bool {
        if self.active_len() < TERMINAL_ADOPTION_QUEUE_CAPACITY {
            self.tasks.push(task);
            return true;
        }
        if self.deferred.len() < TERMINAL_ADOPTION_DEFERRED_CAPACITY {
            self.deferred.push_back(task);
            return true;
        }
        false
    }

    fn promote_deferred(&mut self) {
        while self.active_len() < TERMINAL_ADOPTION_QUEUE_CAPACITY {
            let Some(task) = self.deferred.pop_front() else { break };
            self.tasks.push(task);
        }
    }

    fn requeue_retry(&mut self, task: TerminalAdoptionTask) {
        if let Some(next) = self.deferred.pop_front() {
            self.tasks.push(next);
            self.deferred.push_back(task);
        } else {
            self.tasks.push(task);
        }
    }

    fn rescan_due(&self, now: Instant) -> bool {
        self.rescan_required
            && self.deferred.is_empty()
            && self.next_rescan.is_none_or(|next_rescan| next_rescan <= now)
    }
}

#[cfg(unix)]
#[derive(Default)]
struct TerminalAdoptionCoordinator {
    state: Mutex<TerminalAdoptionQueueState>,
    wake: Condvar,
}

#[cfg(unix)]
struct TerminalHostRecordScanTask {
    root: std::path::PathBuf,
    capacity: usize,
    result: Receiver<anyhow::Result<TerminalHostRecords>>,
    worker: std::thread::JoinHandle<()>,
}

#[cfg(unix)]
#[derive(Default)]
struct TerminalHostRecordScanOwner {
    task: Mutex<Option<TerminalHostRecordScanTask>>,
}

#[cfg(unix)]
impl TerminalHostRecordScanOwner {
    fn scan_until<F>(
        &self,
        root: std::path::PathBuf,
        capacity: usize,
        deadline: Instant,
        loader: F,
    ) -> anyhow::Result<TerminalHostRecords>
    where
        F: FnOnce(std::path::PathBuf, usize, Instant) -> anyhow::Result<TerminalHostRecords>
            + Send
            + 'static,
    {
        let mut task = self.task.lock().unwrap();
        if let Some(active) = task.as_ref() {
            anyhow::ensure!(
                active.root == root && active.capacity == capacity,
                "terminal-host record scan parameters changed during shutdown"
            );
        } else {
            let (result_tx, result_rx) = std::sync::mpsc::sync_channel(1);
            let scan_root = root.clone();
            let worker = std::thread::Builder::new()
                .name("terminal-host-record-scan".into())
                .spawn(move || {
                    let result = loader(scan_root, capacity, deadline);
                    let _ = result_tx.send(result);
                })
                .context("start terminal-host record scan")?;
            *task = Some(TerminalHostRecordScanTask { root, capacity, result: result_rx, worker });
        }

        let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
            anyhow::bail!("terminal-host record scan exceeded the shutdown deadline");
        };
        let received = task
            .as_ref()
            .expect("terminal-host record scan was installed")
            .result
            .recv_timeout(remaining);
        match received {
            Ok(result) => {
                let completed = task.take().expect("completed record scan remained installed");
                drop(task);
                if completed.worker.join().is_err() {
                    anyhow::bail!("terminal-host record scan worker panicked");
                }
                result
            }
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                anyhow::bail!("terminal-host record scan exceeded the shutdown deadline")
            }
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                let failed = task.take().expect("failed record scan remained installed");
                drop(task);
                let _ = failed.worker.join();
                anyhow::bail!("terminal-host record scan worker stopped without a result")
            }
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
enum ShutdownOwnerKey {
    Surface(SurfaceId),
    Hosted { terminal_id: String, incarnation: String },
}

enum ShutdownOwnerWork {
    Single((ShutdownOwnerKey, Arc<SurfaceShutdownOwner>)),
    BrowserBatch {
        runtime: Arc<BrowserRuntime>,
        owners: Vec<(ShutdownOwnerKey, Arc<SurfaceShutdownOwner>)>,
    },
}

impl ShutdownOwnerWork {
    fn record_failed_keys(&self, failed: &mut HashSet<ShutdownOwnerKey>) {
        match self {
            Self::Single((key, _)) => {
                failed.insert(key.clone());
            }
            Self::BrowserBatch { owners, .. } => {
                failed.extend(owners.iter().map(|(key, _)| key.clone()));
            }
        }
    }
}

fn shutdown_owner_key(surface: SurfaceId, owner: &SurfaceShutdownOwner) -> ShutdownOwnerKey {
    owner
        .hosted_identity()
        .map(|(terminal_id, incarnation)| ShutdownOwnerKey::Hosted {
            terminal_id: terminal_id.to_string(),
            incarnation: incarnation.to_string(),
        })
        .unwrap_or(ShutdownOwnerKey::Surface(surface))
}

#[derive(Default)]
struct ShutdownOwnerLedger {
    owners: Mutex<HashMap<ShutdownOwnerKey, Arc<SurfaceShutdownOwner>>>,
}

impl ShutdownOwnerLedger {
    fn get(&self, key: &ShutdownOwnerKey) -> Option<(ShutdownOwnerKey, Arc<SurfaceShutdownOwner>)> {
        self.owners.lock().unwrap().get(key).cloned().map(|owner| (key.clone(), owner))
    }

    fn stage(
        &self,
        key: ShutdownOwnerKey,
        owner: SurfaceShutdownOwner,
    ) -> (ShutdownOwnerKey, Arc<SurfaceShutdownOwner>) {
        let staged = self
            .owners
            .lock()
            .unwrap()
            .entry(key.clone())
            .or_insert_with(|| Arc::new(owner))
            .clone();
        (key, staged)
    }

    fn stage_surface(
        &self,
        surface: &Arc<Surface>,
    ) -> Option<(ShutdownOwnerKey, Arc<SurfaceShutdownOwner>)> {
        let surface_key = ShutdownOwnerKey::Surface(surface.id);
        if let Some(staged) = self.get(&surface_key) {
            return Some(staged);
        }
        let owner = surface.shutdown_owner()?;
        Some(self.stage(shutdown_owner_key(surface.id, &owner), owner))
    }

    fn snapshot(&self) -> Vec<(ShutdownOwnerKey, Arc<SurfaceShutdownOwner>)> {
        self.owners
            .lock()
            .unwrap()
            .iter()
            .map(|(key, owner)| (key.clone(), owner.clone()))
            .collect()
    }

    fn remove_confirmed(&self, confirmed: &[(ShutdownOwnerKey, Arc<SurfaceShutdownOwner>)]) {
        let mut owners = self.owners.lock().unwrap();
        for (key, confirmed) in confirmed {
            if owners.get(key).is_some_and(|owner| Arc::ptr_eq(owner, confirmed)) {
                owners.remove(key);
            }
        }
    }

    fn remove_browser_runtime(&self, runtime: &Arc<BrowserRuntime>) {
        self.owners.lock().unwrap().retain(|_, owner| {
            owner.browser_runtime().is_none_or(|owner_runtime| !Arc::ptr_eq(owner_runtime, runtime))
        });
    }

    fn len(&self) -> usize {
        self.owners.lock().unwrap().len()
    }

    #[cfg(test)]
    fn is_empty(&self) -> bool {
        self.owners.lock().unwrap().is_empty()
    }
}

#[derive(Default)]
struct ShutdownOwnerReconcilerState {
    pending: bool,
    stopping: bool,
    worker_started: bool,
    degraded: bool,
}

#[derive(Default)]
struct ShutdownOwnerReconciler {
    state: Mutex<ShutdownOwnerReconcilerState>,
    wake: Condvar,
    mux: OnceLock<Weak<Mux>>,
    #[cfg(test)]
    after_attempt: Mutex<Option<ShutdownAttemptHook>>,
}

impl ShutdownOwnerReconciler {
    fn bind(&self, mux: Weak<Mux>) {
        assert!(self.mux.set(mux).is_ok(), "shutdown owner reconciler was bound twice");
    }

    #[cfg(test)]
    fn worker_started(&self) -> bool {
        self.state.lock().unwrap().worker_started
    }

    fn schedule(self: &Arc<Self>) {
        let mut state = self.state.lock().unwrap();
        if state.stopping {
            return;
        }
        state.pending = true;
        state.degraded = false;
        if state.worker_started {
            self.wake.notify_one();
            return;
        }
        state.worker_started = true;
        drop(state);

        let mux =
            self.mux.get().cloned().expect("shutdown owner reconciler must bind before scheduling");
        let reconciler = self.clone();
        if std::thread::Builder::new()
            .name("cmux-shutdown-owner-reconciler".into())
            .spawn(move || reconciler.run(mux))
            .is_err()
        {
            // Ownership remains in the ledger for full shutdown. A later
            // retirement will retry worker creation if process pressure eases.
            let mut state = self.state.lock().unwrap();
            state.worker_started = false;
            state.degraded = true;
        }
    }

    fn stop(&self) {
        let mut state = self.state.lock().unwrap();
        state.stopping = true;
        self.wake.notify_all();
    }

    fn run(self: Arc<Self>, mux: Weak<Mux>) {
        let mut delay = SHUTDOWN_RECONCILE_INITIAL_DELAY;
        loop {
            let mut state = self.state.lock().unwrap();
            while !state.pending && !state.stopping {
                state = self.wake.wait(state).unwrap();
            }
            if state.stopping {
                return;
            }
            state.pending = false;
            drop(state);

            let mut attempts = 0;
            loop {
                let Some(mux) = mux.upgrade() else { return };
                let deadline = Instant::now() + SHUTDOWN_TERMINATION_TIMEOUT;
                let pending = match mux.lock_shutdown_coordinator_until(deadline) {
                    Ok(_coordinator) => mux.terminate_staged_shutdown_owners_until(deadline),
                    Err(_) => true,
                };
                drop(mux);
                if !pending {
                    delay = SHUTDOWN_RECONCILE_INITIAL_DELAY;
                    break;
                }
                attempts += 1;
                #[cfg(test)]
                if let Some(hook) = self.after_attempt.lock().unwrap().clone() {
                    hook(attempts);
                }
                if attempts >= SHUTDOWN_RECONCILE_MAX_ATTEMPTS {
                    let mut state = self.state.lock().unwrap();
                    if state.pending {
                        // The final sweep did not include work scheduled
                        // while it was running. Give that new ownership batch
                        // its own bounded retry budget.
                        state.pending = false;
                        state.degraded = false;
                        attempts = 0;
                        delay = SHUTDOWN_RECONCILE_INITIAL_DELAY;
                        drop(state);
                        continue;
                    }
                    state.pending = false;
                    state.worker_started = false;
                    state.degraded = true;
                    return;
                }

                let state = self.state.lock().unwrap();
                let mut state = if state.pending {
                    state
                } else {
                    self.wake.wait_timeout(state, delay).unwrap().0
                };
                if state.stopping {
                    return;
                }
                state.pending = false;
                drop(state);
                delay = delay.saturating_mul(2).min(SHUTDOWN_RECONCILE_MAX_DELAY);
            }
        }
    }
}

fn workspace_resource_upsert(
    sequence: usize,
    session_id: &str,
    workspace_id: &WorkspacePublicId,
    name: &str,
    index: usize,
    focused: bool,
) -> Value {
    serde_json::json!({
        "kind":"upsert",
        "sequence":sequence,
        "resource":"workspace",
        "id":workspace_id,
        "value":{
            "id":workspace_id,
            "session_id":session_id,
            "name":name,
            "index":index,
            "focused":focused,
        },
    })
}

/// An opaque per-mux credential provisioned by the external machine
/// provider. Debug output is deliberately redacted.
#[derive(PartialEq, Eq)]
pub struct ProviderWorkspaceAuthority(Box<str>);

impl ProviderWorkspaceAuthority {
    pub fn new(value: impl Into<String>) -> anyhow::Result<Self> {
        let mut value = value.into();
        if !(PROVIDER_WORKSPACE_AUTHORITY_MIN_BYTES..=PROVIDER_WORKSPACE_AUTHORITY_MAX_BYTES)
            .contains(&value.len())
            || value.bytes().any(|byte| byte.is_ascii_control())
        {
            value.zeroize();
            anyhow::bail!(
                "provider workspace authority must be 32 to 512 bytes without control characters"
            );
        }
        Ok(Self(value.into_boxed_str()))
    }

    pub(crate) fn expose(&self) -> &[u8] {
        self.0.as_bytes()
    }
}

/// Public, non-secret state exposed by the provider management socket.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct ProviderWorkspaceAuthorityStatus {
    pub managed: bool,
    pub mux_generation: Option<String>,
    pub authority_generation: u64,
    pub authority_installed: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProviderWorkspaceAuthorityUpdateError {
    Unmanaged,
    MuxGenerationMismatch,
    ExpectedGenerationMismatch,
    GenerationConflict,
    InvalidGeneration,
}

impl fmt::Display for ProviderWorkspaceAuthorityUpdateError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::Unmanaged => "workspace lifecycle is not provider-managed",
            Self::MuxGenerationMismatch => "mux generation does not match the running process",
            Self::ExpectedGenerationMismatch => "authority generation changed concurrently",
            Self::GenerationConflict => {
                "authority generation already contains a different credential"
            }
            Self::InvalidGeneration => "authority generation must advance by exactly one",
        })
    }
}

impl std::error::Error for ProviderWorkspaceAuthorityUpdateError {}

#[derive(Default)]
struct ProviderWorkspaceState {
    managed: bool,
    mux_generation: Option<Box<str>>,
    authority_generation: u64,
    authority: Option<ProviderWorkspaceAuthority>,
}

impl ProviderWorkspaceState {
    fn status(&self) -> ProviderWorkspaceAuthorityStatus {
        ProviderWorkspaceAuthorityStatus {
            managed: self.managed,
            mux_generation: self.mux_generation.as_deref().map(str::to_owned),
            authority_generation: self.authority_generation,
            authority_installed: self.authority.is_some(),
        }
    }
}

impl fmt::Debug for ProviderWorkspaceAuthority {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("ProviderWorkspaceAuthority([redacted])")
    }
}

impl Drop for ProviderWorkspaceAuthority {
    fn drop(&mut self) {
        // NUL bytes remain valid UTF-8, so the boxed string can be cleared in
        // place before its allocation is released.
        self.0.zeroize();
    }
}

fn constant_time_eq(left: &[u8], right: &[u8]) -> bool {
    let mut difference = left.len() ^ right.len();
    let length = left.len().max(right.len());
    for index in 0..length {
        difference |= usize::from(
            left.get(index).copied().unwrap_or(0) ^ right.get(index).copied().unwrap_or(0),
        );
    }
    difference == 0
}

fn validate_mux_generation(value: &str) -> anyhow::Result<()> {
    if value.len() != 32
        || !value.bytes().all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
    {
        anyhow::bail!("mux generation must be 32 lowercase hexadecimal characters");
    }
    Ok(())
}

pub(crate) fn clamp_terminal_size(cols: u16, rows: u16) -> (u16, u16) {
    (cols.clamp(1, TERMINAL_DIMENSION_MAX), rows.clamp(1, TERMINAL_DIMENSION_MAX))
}

#[derive(Debug, Default)]
pub struct CellPixelUpdate {
    pub resizes: Vec<(SurfaceId, (u16, u16), u64)>,
    pub failures: Vec<CellPixelUpdateFailure>,
}

#[derive(Debug)]
pub struct CellPixelUpdateFailure {
    pub surface: SurfaceId,
    pub error: String,
}

/// Events pushed to subscribed frontends.
#[derive(Debug, Clone)]
pub enum MuxEvent {
    /// New output arrived in a surface (coalesced; cleared when rendered).
    SurfaceOutput(SurfaceId),
    /// A surface's runtime changed size.
    SurfaceResized {
        surface: SurfaceId,
        cols: u16,
        rows: u16,
        reservation_id: Option<u64>,
    },
    /// An asynchronous browser resize failed after queue acceptance.
    SurfaceResizeFailed {
        surface: SurfaceId,
        cols: u16,
        rows: u16,
        error: Arc<str>,
        retry_after_ms: Option<u64>,
        reservation_id: Option<u64>,
    },
    /// A surface's child exited. Hosted terminals remain in the tree as an
    /// addressable Exited tab until an explicit close tombstones them; local
    /// terminals have already been reaped when this arrives.
    SurfaceExited(SurfaceId),
    TitleChanged {
        surface: SurfaceId,
        title: Arc<str>,
    },
    Bell(SurfaceId),
    Notification(NotificationEvent),
    Status(String),
    /// A frontend should reload its local mux configuration and redraw.
    ConfigReloadRequested,
    /// A frontend should set its host terminal window title. Empty clears it.
    WindowTitleRequested(String),
    /// A PTY surface viewport moved within its scrollback.
    ScrollChanged {
        surface: SurfaceId,
        offset: u64,
        at_bottom: bool,
    },
    /// The workspace/screen/pane/tab tree changed (from any frontend or
    /// the control socket).
    TreeChanged,
    /// Delta subscribers need a coarse snapshot resync for a selection-only change.
    TreeSelectionChanged,
    /// One protocol-v7 lifecycle mutation. Coarse subscribers project this
    /// back to the legacy `tree-changed` event.
    TreeDelta(TreeDelta),
    FrontendProjectionChanged {
        frontend: String,
        scope: String,
        subject_key: String,
        projection_revision: u64,
        origin: String,
        mutation_id: String,
    },
    /// A durable terminal-registry mutation committed. Consumers use this as
    /// a barrier, then fetch `terminal-events` or a fresh snapshot.
    TerminalRegistryChanged {
        registry_id: String,
        generation: String,
        terminal_revision: u64,
    },
    /// A screen's pane geometry changed. Clients should re-fetch layout.
    LayoutChanged(ScreenId),
    /// A control connection attached its first surface.
    ClientAttached {
        client: u64,
        transport: String,
        name: Option<String>,
        kind: Option<String>,
    },
    /// A control connection updated its display metadata.
    ClientChanged {
        client: u64,
        name: Option<String>,
        kind: Option<String>,
    },
    /// A control connection ended.
    ClientDetached(u64),
    /// A recovered event subscription may have missed client lifecycle
    /// events, so consumers must reload the authoritative client list.
    ClientListInvalidated,
    /// An unauthenticated browser is waiting for a trusted TUI decision.
    PairingRequested(PairingChallenge),
    /// A pairing request was approved, denied, disconnected, or expired.
    PairingResolved {
        request: u64,
    },
    /// Every workspace is gone.
    Empty,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TreeDeltaKind {
    WorkspaceAdded,
    WorkspaceClosed,
    WorkspaceRenamed,
    WorkspaceMoved,
    ScreenAdded,
    ScreenClosed,
    ScreenRenamed,
    PaneAdded,
    PaneClosed,
    TabAdded,
    TabClosed,
    TabRenamed,
}

impl TreeDeltaKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::WorkspaceAdded => "workspace-added",
            Self::WorkspaceClosed => "workspace-closed",
            Self::WorkspaceRenamed => "workspace-renamed",
            Self::WorkspaceMoved => "workspace-moved",
            Self::ScreenAdded => "screen-added",
            Self::ScreenClosed => "screen-closed",
            Self::ScreenRenamed => "screen-renamed",
            Self::PaneAdded => "pane-added",
            Self::PaneClosed => "pane-closed",
            Self::TabAdded => "tab-added",
            Self::TabClosed => "tab-closed",
            Self::TabRenamed => "tab-renamed",
        }
    }
}

#[derive(Debug, Clone)]
pub struct TreeDelta {
    pub kind: TreeDeltaKind,
    pub workspace: WorkspaceId,
    pub screen: Option<ScreenId>,
    pub pane: Option<PaneId>,
    pub surface: Option<SurfaceId>,
    pub index: Option<usize>,
    pub entity: Value,
    /// Present for ordered workspace-registry mutations. Consumers can apply
    /// only the exact next revision and refetch after a gap.
    pub workspace_revision: Option<u64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NotificationLevel {
    Info,
    Warning,
    Error,
}

impl NotificationLevel {
    pub fn as_str(self) -> &'static str {
        match self {
            NotificationLevel::Info => "info",
            NotificationLevel::Warning => "warning",
            NotificationLevel::Error => "error",
        }
    }
}

#[derive(Debug, Clone)]
pub struct NotificationEvent {
    pub notification: u64,
    pub title: String,
    pub body: String,
    pub level: NotificationLevel,
    pub surface: Option<SurfaceId>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResourceNotification {
    pub id: NotificationPublicId,
    pub title: String,
    pub body: String,
    pub level: NotificationLevel,
    pub terminal_id: Option<TerminalPublicId>,
    pub created_at_ms: u64,
    pub(crate) surface: Option<SurfaceId>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AgentState {
    Working,
    Blocked,
    Idle,
    Done,
    Unknown,
}

impl AgentState {
    pub fn as_str(self) -> &'static str {
        match self {
            AgentState::Working => "working",
            AgentState::Blocked => "blocked",
            AgentState::Idle => "idle",
            AgentState::Done => "done",
            AgentState::Unknown => "unknown",
        }
    }
}

#[derive(Debug, Clone)]
pub struct LayoutLeafSpec {
    pub cwd: Option<String>,
    pub command: Option<Vec<String>>,
}

#[derive(Debug, Clone)]
pub enum LayoutSpec {
    Leaf(LayoutLeafSpec),
    Split { dir: SplitDir, ratio: f32, a: Box<LayoutSpec>, b: Box<LayoutSpec> },
    Stack { pane_count: usize, expanded_index: usize },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ZoomMode {
    Toggle,
    On,
    Off,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    Left,
    Right,
    Up,
    Down,
}

impl Direction {
    fn delta(self) -> (i32, i32) {
        match self {
            Direction::Left => (-1, 0),
            Direction::Right => (1, 0),
            Direction::Up => (0, -1),
            Direction::Down => (0, 1),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AgentSource {
    Detected,
    Socket,
    Hook,
}

impl AgentSource {
    pub fn as_str(self) -> &'static str {
        match self {
            AgentSource::Detected => "detected",
            AgentSource::Socket => "socket",
            AgentSource::Hook => "hook",
        }
    }
}

#[derive(Debug, Clone)]
pub struct AgentRecord {
    pub surface: SurfaceId,
    pub state: AgentState,
    pub source: AgentSource,
    pub session: Option<String>,
    pub updated_at_ms: u64,
}

enum AgentReportTarget<'a> {
    Surface(SurfaceId),
    Resource { selectors: &'a crate::ResourceSelectors, terminal_id: &'a TerminalPublicId },
}

#[derive(Debug, Clone, Copy)]
pub struct SurfaceNotification {
    pub notification: u64,
    pub level: NotificationLevel,
    pub unread: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RunPlacement {
    pub surface: SurfaceId,
    pub pane: PaneId,
    pub screen: ScreenId,
    pub workspace: WorkspaceId,
}

#[derive(Debug, Default)]
pub(crate) struct RunCommandOptions {
    pub pane: Option<PaneId>,
    pub new_workspace: bool,
    pub workspace_key: Option<String>,
    pub cwd: Option<String>,
    pub name: Option<String>,
    pub size: Option<(u16, u16)>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalCloseResult {
    pub surface: Option<SurfaceId>,
    pub terminal_id: String,
    pub terminal_incarnation: Option<String>,
    pub already_closed: bool,
    pub terminal_revision: u64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct TerminalResolution {
    pub surface: Option<SurfaceId>,
    pub terminal: RegistryTerminal,
    pub terminal_revision: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalPlacementResult {
    pub placement: RunPlacement,
    pub terminal_id: String,
    pub terminal_incarnation: Option<String>,
    pub terminal_revision: u64,
    pub replayed: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct TerminalMoveResult {
    pub placement: Option<RunPlacement>,
    pub terminal: RegistryTerminal,
    pub terminal_revision: u64,
    pub replayed: bool,
    pub changed: bool,
}

#[derive(Debug, Clone)]
struct TerminalReservationRequest {
    terminal_id: TerminalId,
    mutation: WorkspaceMutation,
    fingerprint: Value,
    expected_generation: Option<String>,
    expected_revision: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkspacePlacement {
    pub workspace: WorkspaceId,
    pub key: String,
    pub index: usize,
    pub revision: u64,
    pub replayed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkspaceMutationResult {
    pub workspace: Option<WorkspaceId>,
    pub key: String,
    pub index: Option<usize>,
    pub revision: u64,
    pub replayed: bool,
    pub changed: bool,
}

#[derive(Clone, Copy)]
enum TreeCloseTarget {
    Pane(PaneId),
    Screen(ScreenId),
}

enum WorkspaceMutationAuthority<'a> {
    Ordinary,
    TrustedProvider,
    ProviderCredential(&'a str),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AppliedPane {
    pub pane: PaneId,
    pub surface: SurfaceId,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AppliedLayout {
    pub screen: ScreenId,
    pub panes: Vec<AppliedPane>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ZoomState {
    pub pane: PaneId,
    pub zoomed: bool,
    pub zoomed_pane: Option<PaneId>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LayoutUndoResult {
    Undone { screen: ScreenId, revision: u64 },
    ConfirmationRequired { screen: ScreenId, revision: u64, closes_panes: Vec<PaneId> },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LayoutUndoError {
    Unavailable,
    Stale(String),
}

impl LayoutUndoError {
    pub const UNAVAILABLE_CODE: &'static str = "layout-undo-unavailable";
    pub const STALE_CODE: &'static str = "layout-undo-stale";

    pub fn code(&self) -> &'static str {
        match self {
            Self::Unavailable => Self::UNAVAILABLE_CODE,
            Self::Stale(_) => Self::STALE_CODE,
        }
    }
}

impl fmt::Display for LayoutUndoError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unavailable => formatter.write_str("no layout change to undo"),
            Self::Stale(message) => formatter.write_str(message),
        }
    }
}

impl std::error::Error for LayoutUndoError {}

#[derive(Debug, Clone, PartialEq)]
pub enum LayoutRatioError {
    UnknownPaneSplit { pane: PaneId },
    UnknownSplit { split: SplitId },
    UnrepresentableViewportWidth { split: SplitId, ratio: f32, width: f32 },
}

impl LayoutRatioError {
    pub const UNKNOWN_TARGET_CODE: &'static str = "layout-ratio-target-missing";
    pub const OUT_OF_RANGE_CODE: &'static str = "layout-ratio-out-of-range";

    pub fn code(&self) -> &'static str {
        match self {
            Self::UnknownPaneSplit { .. } | Self::UnknownSplit { .. } => Self::UNKNOWN_TARGET_CODE,
            Self::UnrepresentableViewportWidth { .. } => Self::OUT_OF_RANGE_CODE,
        }
    }
}

impl fmt::Display for LayoutRatioError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnknownPaneSplit { pane } => write!(formatter, "unknown pane/split {pane}"),
            Self::UnknownSplit { split } => write!(formatter, "unknown split {split}"),
            Self::UnrepresentableViewportWidth { split, ratio, width } => write!(
                formatter,
                "split {split} ratio {ratio} implies viewport width {width}; width must be between {MIN_VIEWPORT_PANE_WIDTH} and {MAX_VIEWPORT_PANE_WIDTH}"
            ),
        }
    }
}

impl std::error::Error for LayoutRatioError {}

#[derive(Debug, Clone, PartialEq)]
pub enum ViewportWidthError {
    OutOfRange { width: f32 },
    PaneNotResizable { pane: PaneId },
}

impl ViewportWidthError {
    pub const OUT_OF_RANGE_CODE: &'static str = "viewport-width-out-of-range";
    pub const COLUMN_MISSING_CODE: &'static str = "viewport-column-not-found";

    pub fn code(&self) -> &'static str {
        match self {
            Self::OutOfRange { .. } => Self::OUT_OF_RANGE_CODE,
            Self::PaneNotResizable { .. } => Self::COLUMN_MISSING_CODE,
        }
    }
}

impl fmt::Display for ViewportWidthError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::OutOfRange { .. } => {
                formatter.write_str("viewport pane width must be between 0.1 and 1.0")
            }
            Self::PaneNotResizable { pane } => {
                write!(formatter, "pane {pane} has no resizable viewport column")
            }
        }
    }
}

impl std::error::Error for ViewportWidthError {}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SidebarPluginOptions {
    pub command: Vec<String>,
    pub cwd: Option<String>,
}

#[derive(Debug, Clone)]
pub struct SidebarPluginStatus {
    pub surface: Option<SurfaceId>,
    pub error: Option<String>,
    pub retry_after: Option<Duration>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct ShutdownCleanupHealth {
    pub(crate) pending: usize,
    pub(crate) retrying: bool,
    pub(crate) degraded: bool,
}

#[derive(Debug, Default)]
struct SidebarPluginRuntime {
    options: Option<SidebarPluginOptions>,
    surface: Option<SurfaceId>,
    last_size: Option<(u16, u16)>,
    last_error: Option<String>,
    failures: u32,
    retry_at: Option<Instant>,
}

enum BrowserSurfaceAttach {
    MissingPane,
    Rejected,
    Attached(Option<TreeDelta>),
}

type ClientSurfaceSizes = HashMap<SurfaceId, HashMap<u64, (u16, u16)>>;
type SurfaceResizeAcceptance = (bool, Option<u64>);
type AppliedClientSize = (SurfaceResizeAcceptance, Option<(u16, u16)>, ClientSizeRollback);
type SurfaceResizeOutcome = Result<(), Arc<str>>;
type SurfaceResizeCompletion = SyncSender<SurfaceResizeOutcome>;

struct PendingWorkspaceSurface<'a> {
    pending: &'a Mutex<HashMap<SurfaceId, WorkspaceId>>,
    surface: SurfaceId,
}

impl Drop for PendingWorkspaceSurface<'_> {
    fn drop(&mut self) {
        self.pending.lock().unwrap().remove(&self.surface);
    }
}

#[derive(Default)]
struct SurfaceCreationState {
    shutting_down: bool,
    active_threads: HashMap<ThreadId, usize>,
}

#[derive(Default)]
struct SurfaceCreationGate {
    state: Mutex<SurfaceCreationState>,
    idle: Condvar,
}

impl SurfaceCreationGate {
    fn begin(&self) -> anyhow::Result<SurfaceCreationGuard<'_>> {
        let thread = std::thread::current().id();
        let mut state = self.state.lock().unwrap();
        if let Some(depth) = state.active_threads.get_mut(&thread) {
            *depth = depth.saturating_add(1);
        } else {
            if state.shutting_down {
                anyhow::bail!("server is shutting down");
            }
            state.active_threads.insert(thread, 1);
        }
        Ok(SurfaceCreationGuard { gate: self, thread })
    }

    fn stop(&self) {
        let mut state = self.state.lock().unwrap();
        state.shutting_down = true;
        self.idle.notify_all();
    }

    fn stop_and_wait_until(&self, deadline: Instant) -> bool {
        let mut state = self.state.lock().unwrap();
        state.shutting_down = true;
        while !state.active_threads.is_empty() {
            let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
                return false;
            };
            let (next, timeout) = self.idle.wait_timeout(state, remaining).unwrap();
            state = next;
            if timeout.timed_out() && !state.active_threads.is_empty() {
                return false;
            }
        }
        true
    }
}

struct SurfaceCreationGuard<'a> {
    gate: &'a SurfaceCreationGate,
    thread: ThreadId,
}

impl Drop for SurfaceCreationGuard<'_> {
    fn drop(&mut self) {
        let mut state = self.gate.state.lock().unwrap();
        let remove = {
            let depth =
                state.active_threads.get_mut(&self.thread).expect("surface creation guard tracked");
            *depth -= 1;
            *depth == 0
        };
        if remove {
            state.active_threads.remove(&self.thread);
        }
        if state.active_threads.is_empty() {
            self.gate.idle.notify_all();
        }
    }
}

struct SurfaceOwnerReservation<'a> {
    mux: &'a Mux,
    active: bool,
}

impl SurfaceOwnerReservation<'_> {
    fn release(&mut self) {
        if self.active {
            let previous = self.mux.surface_owner_reservations.fetch_sub(1, Ordering::AcqRel);
            debug_assert!(previous > 0, "surface owner reservation accounting underflowed");
            self.active = false;
        }
    }
}

impl Drop for SurfaceOwnerReservation<'_> {
    fn drop(&mut self) {
        self.release();
    }
}

#[derive(Default)]
struct ShutdownCoordinatorState {
    held: bool,
    poisoned: bool,
}

#[derive(Default)]
struct ShutdownCoordinator {
    state: Mutex<ShutdownCoordinatorState>,
    available: Condvar,
}

impl ShutdownCoordinator {
    fn lock_until(&self, deadline: Instant) -> anyhow::Result<ShutdownCoordinatorGuard<'_>> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| anyhow::anyhow!("shutdown coordinator is unavailable"))?;
        loop {
            if state.poisoned {
                anyhow::bail!("shutdown coordinator is unavailable");
            }
            if !state.held {
                state.held = true;
                return Ok(ShutdownCoordinatorGuard { coordinator: self });
            }
            let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
                anyhow::bail!("another shutdown request exceeded the shutdown deadline");
            };
            let (next, timeout) = self
                .available
                .wait_timeout(state, remaining)
                .map_err(|_| anyhow::anyhow!("shutdown coordinator is unavailable"))?;
            state = next;
            if timeout.timed_out() && state.held {
                anyhow::bail!("another shutdown request exceeded the shutdown deadline");
            }
        }
    }
}

struct ShutdownCoordinatorGuard<'a> {
    coordinator: &'a ShutdownCoordinator,
}

impl Drop for ShutdownCoordinatorGuard<'_> {
    fn drop(&mut self) {
        let mut state =
            self.coordinator.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        state.poisoned |= std::thread::panicking();
        state.held = false;
        self.coordinator.available.notify_one();
    }
}

#[derive(Clone, Copy, Default, PartialEq, Eq)]
enum ShutdownRequestWatchState {
    #[default]
    Pending,
    Requested,
    Cancelled,
}

#[derive(Default)]
struct ShutdownRequestWatchInner {
    state: Mutex<ShutdownRequestWatchState>,
    changed: Condvar,
}

impl ShutdownRequestWatchInner {
    fn transition(&self, next: ShutdownRequestWatchState) {
        let mut state = self.state.lock().unwrap();
        if *state == ShutdownRequestWatchState::Pending {
            *state = next;
            self.changed.notify_all();
        }
    }
}

/// One-shot notification that the server process has accepted an exit request.
#[derive(Clone)]
pub struct ShutdownRequestWatch {
    inner: Arc<ShutdownRequestWatchInner>,
}

impl ShutdownRequestWatch {
    /// Block until shutdown is requested or this watch is cancelled.
    pub fn wait(&self) -> bool {
        let state = self.inner.state.lock().unwrap();
        let state = self
            .inner
            .changed
            .wait_while(state, |state| *state == ShutdownRequestWatchState::Pending)
            .unwrap();
        *state == ShutdownRequestWatchState::Requested
    }

    /// Wake a waiter that no longer needs to observe shutdown.
    pub fn cancel(&self) {
        self.inner.transition(ShutdownRequestWatchState::Cancelled);
    }

    fn request(&self) {
        self.inner.transition(ShutdownRequestWatchState::Requested);
    }
}

#[derive(Default)]
struct AsyncSurfaceCreationState {
    shutting_down: bool,
    active: usize,
}

#[derive(Default)]
struct AsyncSurfaceCreationGate {
    inner: Arc<AsyncSurfaceCreationGateInner>,
}

#[derive(Default)]
struct AsyncSurfaceCreationGateInner {
    state: Mutex<AsyncSurfaceCreationState>,
    idle: Condvar,
}

impl AsyncSurfaceCreationGate {
    fn begin(&self) -> anyhow::Result<AsyncSurfaceCreationGuard> {
        let mut state = self.inner.state.lock().unwrap();
        if state.shutting_down {
            anyhow::bail!("server is shutting down");
        }
        state.active = state.active.saturating_add(1);
        Ok(AsyncSurfaceCreationGuard { gate: self.inner.clone() })
    }

    fn stop(&self) {
        let mut state = self.inner.state.lock().unwrap();
        state.shutting_down = true;
        self.inner.idle.notify_all();
    }

    fn stop_and_wait_until(&self, deadline: Instant) -> bool {
        let mut state = self.inner.state.lock().unwrap();
        state.shutting_down = true;
        while state.active != 0 {
            let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
                return false;
            };
            let (next, timeout) = self.inner.idle.wait_timeout(state, remaining).unwrap();
            state = next;
            if timeout.timed_out() && state.active != 0 {
                return false;
            }
        }
        true
    }
}

struct AsyncSurfaceCreationGuard {
    gate: Arc<AsyncSurfaceCreationGateInner>,
}

impl Drop for AsyncSurfaceCreationGuard {
    fn drop(&mut self) {
        let mut state = self.gate.state.lock().unwrap();
        state.active = state.active.checked_sub(1).expect("async surface creation guard tracked");
        if state.active == 0 {
            self.gate.idle.notify_all();
        }
    }
}

#[derive(Default)]
enum BrowserRuntimeSlotState {
    #[default]
    Empty,
    Connecting,
    Ready(Arc<BrowserRuntime>),
    Stopping(Option<Arc<BrowserRuntime>>),
}

#[derive(Default)]
struct BrowserRuntimeSlot {
    state: Mutex<BrowserRuntimeSlotState>,
    changed: Condvar,
}

impl BrowserRuntimeSlot {
    fn stop(&self) {
        let mut state = self.state.lock().unwrap();
        let current = std::mem::take(&mut *state);
        *state = match current {
            BrowserRuntimeSlotState::Ready(runtime) => {
                BrowserRuntimeSlotState::Stopping(Some(runtime))
            }
            BrowserRuntimeSlotState::Stopping(runtime) => {
                BrowserRuntimeSlotState::Stopping(runtime)
            }
            BrowserRuntimeSlotState::Empty | BrowserRuntimeSlotState::Connecting => {
                BrowserRuntimeSlotState::Stopping(None)
            }
        };
        self.changed.notify_all();
    }

    fn take_for_shutdown(&self) -> Option<Arc<BrowserRuntime>> {
        self.stop();
        let mut state = self.state.lock().unwrap();
        let BrowserRuntimeSlotState::Stopping(runtime) = &mut *state else {
            unreachable!("stopped browser runtime slot has a stopping state");
        };
        runtime.take()
    }

    fn restore_for_shutdown(&self, runtime: Arc<BrowserRuntime>) {
        let mut state = self.state.lock().unwrap();
        let BrowserRuntimeSlotState::Stopping(current) = &mut *state else {
            unreachable!("browser runtime can only be restored while stopping");
        };
        debug_assert!(current.is_none(), "browser runtime restored twice");
        *current = Some(runtime);
    }

    fn take_on_drop(&mut self) -> Option<Arc<BrowserRuntime>> {
        let state = self.state.get_mut().unwrap_or_else(std::sync::PoisonError::into_inner);
        match std::mem::take(state) {
            BrowserRuntimeSlotState::Ready(runtime) => Some(runtime),
            BrowserRuntimeSlotState::Stopping(runtime) => runtime,
            BrowserRuntimeSlotState::Empty | BrowserRuntimeSlotState::Connecting => None,
        }
    }

    #[cfg(test)]
    fn install_for_test(&self, runtime: Arc<BrowserRuntime>) {
        *self.state.lock().unwrap() = BrowserRuntimeSlotState::Ready(runtime);
    }

    #[cfg(test)]
    fn has_runtime_for_test(&self) -> bool {
        match &*self.state.lock().unwrap() {
            BrowserRuntimeSlotState::Ready(_) | BrowserRuntimeSlotState::Stopping(Some(_)) => true,
            BrowserRuntimeSlotState::Empty
            | BrowserRuntimeSlotState::Connecting
            | BrowserRuntimeSlotState::Stopping(None) => false,
        }
    }

    #[cfg(test)]
    fn lock_available_for_test(&self) -> bool {
        self.state.try_lock().is_ok()
    }
}

enum SurfaceResizeRestore {
    Complete(bool),
    Pending(Receiver<SurfaceResizeOutcome>),
}

#[derive(PartialEq, Eq)]
struct ClientSizingRollbackToken {
    surface_sizes: Option<HashMap<u64, (u16, u16)>>,
    surface_orders: HashMap<u64, u64>,
    participating_surface_clients: HashSet<u64>,
    uses_excluded_fallback: bool,
}

#[derive(Clone, Copy)]
pub(crate) struct ClientSizeRollback {
    pub(crate) previous_size: Option<(u16, u16)>,
    pub(crate) previous_report_order: Option<u64>,
    pub(crate) previous_geometry: Option<(u16, u16)>,
    pub(crate) applied_report_order: u64,
}

pub(crate) struct ControlClientResize {
    pub accepted: bool,
    pub reservation_id: Option<u64>,
    pub effective_size: Option<(u16, u16)>,
    pub attached: Option<crate::server::ClientSizeUpdate>,
    pub rollback: ClientSizeRollback,
}

#[derive(Default)]
struct SurfaceClientSizing {
    excluded_clients: HashSet<u64>,
    exclusive_client: Option<u64>,
}

#[derive(Default)]
struct ClientSizingState {
    surfaces: ClientSurfaceSizes,
    report_order: HashMap<(SurfaceId, u64), u64>,
    latest_explicit_size: Option<(u64, (u16, u16))>,
    next_size_order: u64,
    policies: HashMap<SurfaceId, SurfaceClientSizing>,
}

impl ClientSizingState {
    fn next_size_order(&mut self) -> u64 {
        self.next_size_order = self.next_size_order.wrapping_add(1).max(1);
        self.next_size_order
    }

    fn record_explicit_size(&mut self, size: (u16, u16)) {
        let order = self.next_size_order();
        self.latest_explicit_size = Some((order, size));
    }

    fn rollback_token(
        &self,
        surface: SurfaceId,
        attached_clients: Option<&HashSet<u64>>,
    ) -> ClientSizingRollbackToken {
        let participating_surface_clients = self
            .surfaces
            .get(&surface)
            .into_iter()
            .flat_map(HashMap::keys)
            .filter(|client| self.client_participates(surface, **client))
            .copied()
            .collect();
        ClientSizingRollbackToken {
            surface_sizes: self.surfaces.get(&surface).cloned(),
            surface_orders: self
                .report_order
                .iter()
                .filter_map(|((reported_surface, client), order)| {
                    (*reported_surface == surface).then_some((*client, *order))
                })
                .collect(),
            participating_surface_clients,
            uses_excluded_fallback: self.uses_excluded_fallback(surface, attached_clients),
        }
    }

    fn client_participates(&self, surface: SurfaceId, client: u64) -> bool {
        let Some(policy) = self.policies.get(&surface) else {
            return true;
        };
        policy.exclusive_client.map_or_else(
            || !policy.excluded_clients.contains(&client),
            |exclusive| exclusive == client,
        )
    }

    fn uses_excluded_fallback(
        &self,
        surface: SurfaceId,
        attached_clients: Option<&HashSet<u64>>,
    ) -> bool {
        let attached_participates = attached_clients.is_some_and(|clients| {
            clients.iter().any(|client| self.client_participates(surface, *client))
        });
        let reporter_participates = self.surfaces.get(&surface).is_some_and(|viewers| {
            viewers.keys().any(|client| self.client_participates(surface, *client))
        });
        !attached_participates && !reporter_participates
    }

    fn effective_size(&self, surface: SurfaceId, use_excluded: bool) -> Option<(u16, u16)> {
        self.surfaces
            .get(&surface)?
            .iter()
            .filter(|(client, _)| use_excluded || self.client_participates(surface, **client))
            .map(|(_, size)| *size)
            .reduce(|smallest, size| (smallest.0.min(size.0), smallest.1.min(size.1)))
    }

    fn latest_effective_size(
        &self,
        attached_clients: &HashMap<SurfaceId, HashSet<u64>>,
    ) -> Option<(u64, (u16, u16))> {
        // The default for a newly created surface is session-wide, so this
        // must consider every report. Cache fallback once per surface to keep
        // multiple viewers on the same surface linear instead of quadratic.
        let mut fallback_by_surface = HashMap::<SurfaceId, bool>::new();
        let ((surface, _), order) = self
            .report_order
            .iter()
            .filter(|((surface, client), _)| {
                let use_excluded = *fallback_by_surface.entry(*surface).or_insert_with(|| {
                    self.uses_excluded_fallback(*surface, attached_clients.get(surface))
                });
                self.surfaces.get(surface).is_some_and(|viewers| viewers.contains_key(client))
                    && (use_excluded || self.client_participates(*surface, *client))
            })
            .max_by_key(|(_, order)| *order)
            .map(|(key, order)| (*key, *order))?;
        let use_excluded = fallback_by_surface[&surface];
        self.effective_size(surface, use_excluded).map(|size| (order, size))
    }

    fn creation_size(
        &mut self,
        attached_clients: &HashMap<SurfaceId, HashSet<u64>>,
    ) -> Option<(u16, u16)> {
        let report = self.latest_effective_size(attached_clients);
        match (self.latest_explicit_size, report) {
            (Some((explicit_order, explicit)), Some((report_order, _)))
                if explicit_order >= report_order =>
            {
                Some(explicit)
            }
            (_, Some((_, report))) => {
                self.latest_explicit_size = None;
                Some(report)
            }
            (Some((_, explicit)), None) => Some(explicit),
            (None, None) => None,
        }
    }

    fn note_applied_report(
        &mut self,
        surface: SurfaceId,
        client: u64,
        attached_clients: &HashSet<u64>,
        effective: Option<(u16, u16)>,
        report_order: u64,
    ) {
        let use_excluded = self.uses_excluded_fallback(surface, Some(attached_clients));
        let contributes = use_excluded || self.client_participates(surface, client);
        if effective.is_some()
            && contributes
            && self
                .latest_explicit_size
                .is_some_and(|(explicit_order, _)| report_order > explicit_order)
        {
            self.latest_explicit_size = None;
        }
    }
}

/// One-shot wakeup shared by a terminal-exit subscription and any
/// connection-owned cancellation sources. The durable terminal registry
/// remains authoritative; this only decides when a waiter should query it.
pub(crate) struct ResourceWaitWake {
    notified: Mutex<bool>,
    changed: Condvar,
}

impl Default for ResourceWaitWake {
    fn default() -> Self {
        Self { notified: Mutex::new(false), changed: Condvar::new() }
    }
}

impl ResourceWaitWake {
    pub(crate) fn notify(&self) {
        let mut notified = self.notified.lock().unwrap();
        *notified = true;
        self.changed.notify_all();
    }

    /// Returns true for an explicit wake and false when the deadline expires.
    pub(crate) fn wait_until(&self, deadline: Option<Instant>) -> bool {
        let mut notified = self.notified.lock().unwrap();
        while !*notified {
            match deadline {
                Some(deadline) => {
                    let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
                        return false;
                    };
                    let (next, timeout) = self.changed.wait_timeout(notified, remaining).unwrap();
                    notified = next;
                    if timeout.timed_out() && !*notified {
                        return false;
                    }
                }
                None => notified = self.changed.wait(notified).unwrap(),
            }
        }
        true
    }
}

#[derive(Default)]
struct TerminalExitWaiters {
    next_id: AtomicU64,
    waiters: Mutex<HashMap<TerminalPublicId, HashMap<u64, Weak<ResourceWaitWake>>>>,
}

pub(crate) struct TerminalExitSubscription<'a> {
    owner: &'a TerminalExitWaiters,
    terminal_id: TerminalPublicId,
    waiter_id: u64,
    wake: Arc<ResourceWaitWake>,
}

impl TerminalExitWaiters {
    fn subscribe(&self, terminal_id: &TerminalPublicId) -> TerminalExitSubscription<'_> {
        let waiter_id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let wake = Arc::new(ResourceWaitWake::default());
        self.waiters
            .lock()
            .unwrap()
            .entry(terminal_id.clone())
            .or_default()
            .insert(waiter_id, Arc::downgrade(&wake));
        TerminalExitSubscription { owner: self, terminal_id: terminal_id.clone(), waiter_id, wake }
    }

    fn notify(&self, terminal_id: &TerminalPublicId) {
        let waiters = self.waiters.lock().unwrap().remove(terminal_id).unwrap_or_default();
        for waiter in waiters.into_values().filter_map(|waiter| waiter.upgrade()) {
            waiter.notify();
        }
    }

    #[cfg(test)]
    fn waiter_count(&self, terminal_id: &TerminalPublicId) -> usize {
        self.waiters.lock().unwrap().get(terminal_id).map(HashMap::len).unwrap_or_default()
    }
}

impl TerminalExitSubscription<'_> {
    pub(crate) fn wake(&self) -> Arc<ResourceWaitWake> {
        self.wake.clone()
    }

    pub(crate) fn wait_until(&self, deadline: Option<Instant>) -> bool {
        self.wake.wait_until(deadline)
    }
}

impl Drop for TerminalExitSubscription<'_> {
    fn drop(&mut self) {
        let mut waiters = self.owner.waiters.lock().unwrap();
        let remove_terminal = waiters.get_mut(&self.terminal_id).is_some_and(|terminal_waiters| {
            terminal_waiters.remove(&self.waiter_id);
            terminal_waiters.is_empty()
        });
        if remove_terminal {
            waiters.remove(&self.terminal_id);
        }
    }
}

#[cfg(test)]
struct TerminalExitStateQueryGuard<'a>(&'a AtomicU64);

#[cfg(test)]
impl Drop for TerminalExitStateQueryGuard<'_> {
    fn drop(&mut self) {
        // Count completed queries. Tests use this release/acquire edge to
        // distinguish a waiter blocked after its initial read from one that
        // merely entered terminal_exit_state and is still behind the registry
        // writer lock.
        self.0.fetch_add(1, Ordering::Release);
    }
}

/// The multiplexer. Shared by frontends and the control socket server.
pub struct Mux {
    /// Serializes durable workspace commits and their in-memory/event
    /// projection. Lock order is always registry, then state.
    workspace_registry: Mutex<WorkspaceRegistry>,
    state: Mutex<State>,
    subscribers: MuxEventBroadcaster,
    shutdown_requested: AtomicBool,
    shutdown_request_watchers: Mutex<Vec<Weak<ShutdownRequestWatchInner>>>,
    surface_creations: SurfaceCreationGate,
    async_surface_creations: AsyncSurfaceCreationGate,
    shutdown_coordinator: ShutdownCoordinator,
    shutdown_owners: ShutdownOwnerLedger,
    shutdown_owner_reconciler: Arc<ShutdownOwnerReconciler>,
    surface_owner_reservations: AtomicUsize,
    next_id: AtomicU64,
    next_notification_id: AtomicU64,
    next_active_at: AtomicU64,
    next_in_process_resize_owner: AtomicU64,
    surface_options: Mutex<SurfaceOptions>,
    provider_workspace: Mutex<ProviderWorkspaceState>,
    workspace_lifecycles: Mutex<HashMap<WorkspaceId, Weak<Mutex<()>>>>,
    pending_workspace_surfaces: Mutex<HashMap<SurfaceId, WorkspaceId>>,
    client_sizing_lifecycle: Mutex<()>,
    client_sizing: Mutex<ClientSizingState>,
    #[cfg(test)]
    client_resize_before_apply: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
    #[cfg(test)]
    terminal_move_before_projection: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
    #[cfg(test)]
    client_rollback_before_wait: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
    #[cfg(test)]
    workspace_close_before_empty_check: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
    #[cfg(test)]
    workspace_close_after_selector_resolution: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
    #[cfg(test)]
    resource_rename_after_selector_resolution: Mutex<Option<WorkspaceRenameHook>>,
    #[cfg(test)]
    layout_apply_after_workspace_reservation: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
    #[cfg(test)]
    terminal_create_after_empty_check: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
    #[cfg(test)]
    terminal_create_after_materialization_lock: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
    #[cfg(test)]
    terminal_create_after_workspace_reservation: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
    #[cfg(test)]
    new_pane_after_spawn: Mutex<Option<NewPaneAfterSpawnHook>>,
    #[cfg(test)]
    browser_tab_after_spawn: Mutex<Option<BrowserTabAfterSpawnHook>>,
    #[cfg(test)]
    terminal_adoption_after_attach: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
    #[cfg(all(test, unix))]
    terminal_adoption_surface_factory: Mutex<Option<TerminalAdoptionSurfaceFactory>>,
    #[cfg(all(test, unix))]
    terminal_host_record_loader: Mutex<Option<TerminalHostRecordLoader>>,
    #[cfg(test)]
    terminal_adoption_workers_started: AtomicUsize,
    #[cfg(test)]
    browser_bootstrap_before_runtime: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
    #[cfg(test)]
    browser_runtime_connect: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
    #[cfg(test)]
    shutdown_owner_capacity: AtomicUsize,
    #[cfg(test)]
    shutdown_attempt_timeout: Mutex<Option<Duration>>,
    #[cfg(test)]
    viewport_split_after_spawn: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
    #[cfg(test)]
    terminal_create_after_terminal_reservation: Mutex<Option<TerminalReservationHook>>,
    reserved_in_process_terminals: Mutex<HashMap<SurfaceId, TerminalHostIdentity>>,
    #[cfg(test)]
    resource_mutation_metrics: Mutex<Option<ResourceMutationMetrics>>,
    #[cfg(test)]
    resource_projection_before_commit: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
    #[cfg(test)]
    resource_close_after_commit: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
    #[cfg(test)]
    discovered_terminal_termination_requests: Mutex<Vec<(String, Option<String>)>>,
    browser_runtime: BrowserRuntimeSlot,
    cell_pixels: Mutex<(u16, u16)>,
    default_colors: Mutex<DefaultColors>,
    durable_terminal_defaults: AtomicBool,
    sidebar_plugin: Mutex<SidebarPluginRuntime>,
    agent_records: Mutex<HashMap<SurfaceId, AgentRecord>>,
    surface_notifications: Mutex<HashMap<SurfaceId, SurfaceNotification>>,
    notification_ledger: Mutex<VecDeque<ResourceNotification>>,
    resource_machine_service: OnceLock<Arc<dyn crate::ResourceMachineService>>,
    resource_event_epoch: Mutex<u64>,
    resource_event_changed: Condvar,
    terminal_exit_waiters: TerminalExitWaiters,
    #[cfg(test)]
    terminal_exit_state_queries: AtomicU64,
    /// Keeps a close from removing a just-created surface before legacy
    /// callers have resolved the committed public result back to its runtime.
    resource_creation_handoff: Mutex<()>,
    resource_creation_execution: Mutex<()>,
    resource_creation_active: AtomicBool,
    terminal_adoptions: Mutex<HashSet<String>>,
    #[cfg(unix)]
    terminal_adoption_coordinator: Arc<TerminalAdoptionCoordinator>,
    #[cfg(unix)]
    terminal_host_record_scan: TerminalHostRecordScanOwner,
    terminal_adoption_insert_failures: AtomicU64,
    /// Fences the interval between accepting a browser daemon-handoff request
    /// and queueing its acknowledgement. ClientRegistry consults this under
    /// its own lock so a new native-browser owner cannot race the shutdown.
    pub(crate) daemon_handoff_pending: AtomicBool,
    shutting_down: AtomicBool,
    daemon_shutdown_requested: AtomicBool,
    pub(crate) control_clients: crate::server::ClientRegistry,
    pub(crate) surface_operation_admission: Arc<crate::server::ServerSurfaceOperationAdmission>,
    pairing: PairingBroker,
    #[cfg(test)]
    test_surface_runtime: bool,
    pub session: String,
}

#[derive(Clone)]
struct RestoredResourceContent {
    slot: SurfaceId,
    identity: TabResourceIdentity,
    name: Option<String>,
    browser: Option<RegistryBrowser>,
}

struct RestoredResourceState {
    state: State,
    next_id: u64,
    contents: Vec<RestoredResourceContent>,
}

impl Mux {
    fn default_workspace_name(state: &State) -> String {
        state.workspaces.len().to_string()
    }

    /// Resolve one public resource path from a single live-state snapshot.
    /// Direct content IDs use the reverse resource indexes and never trigger
    /// a registry snapshot or process query.
    pub fn resolve_resource_path(
        &self,
        target: crate::ResourceTarget,
        selectors: &crate::ResourceSelectors,
    ) -> Result<crate::ResolvedResourcePath, ResourceError> {
        let registry = self.workspace_registry.lock().unwrap();
        let state = self.state.lock().unwrap();
        resolve_resource_selectors(
            &state,
            ResourceSelectorContext {
                machine_id: registry.machine_id(),
                machine_name: None,
                session_id: registry.session_id(),
                session_name: &self.session,
            },
            target,
            selectors,
        )
        .map(|resolved| resolved.path)
    }

    fn resolve_resource_path_in_state(
        &self,
        state: &State,
        registry: &WorkspaceRegistry,
        target: crate::ResourceTarget,
        selectors: &crate::ResourceSelectors,
    ) -> Result<ResolvedResourceSlots, ResourceError> {
        resolve_resource_selectors(
            state,
            ResourceSelectorContext {
                machine_id: registry.machine_id(),
                machine_name: None,
                session_id: registry.session_id(),
                session_name: &self.session,
            },
            target,
            selectors,
        )
    }

    pub fn new(session: impl Into<String>, surface_options: SurfaceOptions) -> Arc<Self> {
        Self::new_with_test_surface_runtime(
            session,
            surface_options,
            ProviderWorkspaceState::default(),
            false,
        )
    }

    /// Builds a mux whose workspace lifecycle is provider-owned from its
    /// first control connection. The authority must be provisioned by the
    /// provider that owns this mux generation.
    pub fn new_provider_managed(
        session: impl Into<String>,
        surface_options: SurfaceOptions,
        authority: ProviderWorkspaceAuthority,
    ) -> Arc<Self> {
        Self::new_with_test_surface_runtime(
            session,
            surface_options,
            ProviderWorkspaceState {
                managed: true,
                mux_generation: None,
                authority_generation: 1,
                authority: Some(authority),
            },
            false,
        )
    }

    /// Builds a provider-owned mux whose authority will be installed through
    /// the root-only management socket before lifecycle mutations are allowed.
    pub fn new_provider_managed_pending(
        session: impl Into<String>,
        surface_options: SurfaceOptions,
        mux_generation: impl Into<String>,
    ) -> anyhow::Result<Arc<Self>> {
        let mux_generation = mux_generation.into();
        validate_mux_generation(&mux_generation)?;
        Ok(Self::new_with_test_surface_runtime(
            session,
            surface_options,
            ProviderWorkspaceState {
                managed: true,
                mux_generation: Some(mux_generation.into_boxed_str()),
                authority_generation: 0,
                authority: None,
            },
            false,
        ))
    }

    fn new_with_test_surface_runtime(
        session: impl Into<String>,
        surface_options: SurfaceOptions,
        provider_workspace: ProviderWorkspaceState,
        #[cfg_attr(not(test), allow(unused_variables))] test_surface_runtime: bool,
    ) -> Arc<Self> {
        let session = session.into();
        let registry = WorkspaceRegistry::in_memory(&session)
            .expect("in-memory workspace registry must initialize");
        Self::from_workspace_registry(
            session,
            surface_options,
            registry,
            provider_workspace,
            test_surface_runtime,
        )
        .expect("in-memory workspace registry must load")
    }

    pub fn open_persistent(
        session: impl Into<String>,
        surface_options: SurfaceOptions,
        state_root: &Path,
    ) -> anyhow::Result<Arc<Self>> {
        let session = session.into();
        let registry = WorkspaceRegistry::open(state_root, &session)?;
        Self::from_workspace_registry(
            session,
            surface_options,
            registry,
            ProviderWorkspaceState::default(),
            false,
        )
    }

    pub fn open_persistent_provider_managed(
        session: impl Into<String>,
        surface_options: SurfaceOptions,
        state_root: &Path,
        authority: ProviderWorkspaceAuthority,
    ) -> anyhow::Result<Arc<Self>> {
        let session = session.into();
        let registry = WorkspaceRegistry::open(state_root, &session)?;
        Self::from_workspace_registry(
            session,
            surface_options,
            registry,
            ProviderWorkspaceState {
                managed: true,
                mux_generation: None,
                authority_generation: 1,
                authority: Some(authority),
            },
            false,
        )
    }

    pub fn open_persistent_provider_managed_pending(
        session: impl Into<String>,
        surface_options: SurfaceOptions,
        state_root: &Path,
        mux_generation: impl Into<String>,
    ) -> anyhow::Result<Arc<Self>> {
        let mux_generation = mux_generation.into();
        validate_mux_generation(&mux_generation)?;
        let session = session.into();
        let registry = WorkspaceRegistry::open(state_root, &session)?;
        Self::from_workspace_registry(
            session,
            surface_options,
            registry,
            ProviderWorkspaceState {
                managed: true,
                mux_generation: Some(mux_generation.into_boxed_str()),
                authority_generation: 0,
                authority: None,
            },
            false,
        )
    }

    fn from_workspace_registry(
        session: String,
        mut surface_options: SurfaceOptions,
        registry: WorkspaceRegistry,
        provider_workspace: ProviderWorkspaceState,
        #[cfg_attr(not(test), allow(unused_variables))] test_surface_runtime: bool,
    ) -> anyhow::Result<Arc<Self>> {
        let snapshot = registry.snapshot()?;
        let topology = registry.resource_topology_snapshot()?;
        let RestoredResourceState { mut state, next_id, contents } =
            restore_resource_state(snapshot, topology)?;
        let RestoredPublicProjections {
            default_colors,
            has_terminal_defaults,
            next_notification_id,
            agent_records,
            surface_notifications,
            notification_ledger,
        } = restore_public_projections(&state, registry.public_projections()?)?;
        surface_options.browser_session_name = session.clone();
        #[cfg(unix)]
        crate::process_session::initialize_stable_process_signaling();
        Self::rebuild_split_screen_index(&mut state);
        let mux = Arc::new(Mux {
            workspace_registry: Mutex::new(registry),
            state: Mutex::new(state),
            subscribers: MuxEventBroadcaster::default(),
            shutdown_requested: AtomicBool::new(false),
            shutdown_request_watchers: Mutex::new(Vec::new()),
            surface_creations: SurfaceCreationGate::default(),
            async_surface_creations: AsyncSurfaceCreationGate::default(),
            shutdown_coordinator: ShutdownCoordinator::default(),
            shutdown_owners: ShutdownOwnerLedger::default(),
            shutdown_owner_reconciler: Arc::new(ShutdownOwnerReconciler::default()),
            surface_owner_reservations: AtomicUsize::new(0),
            next_id: AtomicU64::new(next_id),
            next_notification_id: AtomicU64::new(next_notification_id),
            next_active_at: AtomicU64::new(1),
            next_in_process_resize_owner: AtomicU64::new(1),
            surface_options: Mutex::new(surface_options),
            provider_workspace: Mutex::new(provider_workspace),
            workspace_lifecycles: Mutex::new(HashMap::new()),
            pending_workspace_surfaces: Mutex::new(HashMap::new()),
            client_sizing_lifecycle: Mutex::new(()),
            client_sizing: Mutex::new(ClientSizingState::default()),
            #[cfg(test)]
            client_resize_before_apply: Mutex::new(None),
            #[cfg(test)]
            terminal_move_before_projection: Mutex::new(None),
            #[cfg(test)]
            client_rollback_before_wait: Mutex::new(None),
            #[cfg(test)]
            workspace_close_before_empty_check: Mutex::new(None),
            #[cfg(test)]
            workspace_close_after_selector_resolution: Mutex::new(None),
            #[cfg(test)]
            resource_rename_after_selector_resolution: Mutex::new(None),
            #[cfg(test)]
            layout_apply_after_workspace_reservation: Mutex::new(None),
            #[cfg(test)]
            terminal_create_after_empty_check: Mutex::new(None),
            #[cfg(test)]
            terminal_create_after_materialization_lock: Mutex::new(None),
            #[cfg(test)]
            terminal_create_after_workspace_reservation: Mutex::new(None),
            #[cfg(test)]
            new_pane_after_spawn: Mutex::new(None),
            #[cfg(test)]
            browser_tab_after_spawn: Mutex::new(None),
            #[cfg(test)]
            terminal_adoption_after_attach: Mutex::new(None),
            #[cfg(all(test, unix))]
            terminal_adoption_surface_factory: Mutex::new(None),
            #[cfg(all(test, unix))]
            terminal_host_record_loader: Mutex::new(None),
            #[cfg(test)]
            terminal_adoption_workers_started: AtomicUsize::new(0),
            #[cfg(test)]
            browser_bootstrap_before_runtime: Mutex::new(None),
            #[cfg(test)]
            browser_runtime_connect: Mutex::new(None),
            #[cfg(test)]
            shutdown_owner_capacity: AtomicUsize::new(usize::MAX),
            #[cfg(test)]
            shutdown_attempt_timeout: Mutex::new(None),
            #[cfg(test)]
            viewport_split_after_spawn: Mutex::new(None),
            #[cfg(test)]
            terminal_create_after_terminal_reservation: Mutex::new(None),
            reserved_in_process_terminals: Mutex::new(HashMap::new()),
            #[cfg(test)]
            resource_mutation_metrics: Mutex::new(None),
            #[cfg(test)]
            resource_projection_before_commit: Mutex::new(None),
            #[cfg(test)]
            resource_close_after_commit: Mutex::new(None),
            #[cfg(test)]
            discovered_terminal_termination_requests: Mutex::new(Vec::new()),
            browser_runtime: BrowserRuntimeSlot::default(),
            cell_pixels: Mutex::new((8, 16)),
            default_colors: Mutex::new(default_colors),
            durable_terminal_defaults: AtomicBool::new(has_terminal_defaults),
            sidebar_plugin: Mutex::new(SidebarPluginRuntime::default()),
            agent_records: Mutex::new(agent_records),
            surface_notifications: Mutex::new(surface_notifications),
            notification_ledger: Mutex::new(notification_ledger),
            resource_machine_service: OnceLock::new(),
            resource_event_epoch: Mutex::new(0),
            resource_event_changed: Condvar::new(),
            terminal_exit_waiters: TerminalExitWaiters::default(),
            #[cfg(test)]
            terminal_exit_state_queries: AtomicU64::new(0),
            resource_creation_handoff: Mutex::new(()),
            resource_creation_execution: Mutex::new(()),
            resource_creation_active: AtomicBool::new(false),
            terminal_adoptions: Mutex::new(HashSet::new()),
            #[cfg(unix)]
            terminal_adoption_coordinator: Arc::new(TerminalAdoptionCoordinator::default()),
            #[cfg(unix)]
            terminal_host_record_scan: TerminalHostRecordScanOwner::default(),
            terminal_adoption_insert_failures: AtomicU64::new(
                std::env::var("CMUX_TUI_TEST_ADOPTION_INSERT_FAILURES")
                    .ok()
                    .and_then(|value| value.parse().ok())
                    .unwrap_or(0),
            ),
            daemon_handoff_pending: AtomicBool::new(false),
            shutting_down: AtomicBool::new(false),
            daemon_shutdown_requested: AtomicBool::new(false),
            control_clients: crate::server::ClientRegistry::new(),
            surface_operation_admission: Arc::new(
                crate::server::ServerSurfaceOperationAdmission::default(),
            ),
            pairing: PairingBroker::new(),
            #[cfg(test)]
            test_surface_runtime,
            session,
        });
        mux.shutdown_owner_reconciler.bind(Arc::downgrade(&mux));
        mux.materialize_interrupted_resource_workspaces()?;
        mux.materialize_restored_browsers(&contents)?;
        #[cfg(unix)]
        {
            if mux.surface_options.lock().unwrap().terminal_host_root.is_some() {
                mux.ensure_terminal_adoption_workers()?;
            }
            mux.adopt_terminal_hosts()?;
        }
        {
            let mut state = mux.state.lock().unwrap();
            state.rebuild_resource_indexes();
            for content in &contents {
                if let Some(surface) = state.surfaces.get(&content.slot) {
                    surface.set_name(content.name.clone());
                }
            }
        }
        let recovery_deadline = Instant::now() + Duration::from_secs(15);
        while mux.reconcile_interrupted_resource_creations()? {
            if Instant::now() >= recovery_deadline {
                let _ = mux.shutdown();
                anyhow::bail!("interrupted resource creation did not settle during startup");
            }
            std::thread::sleep(Duration::from_millis(25));
        }
        Ok(mux)
    }

    /// Rehydrate workspace rows that belong to an interrupted correlated
    /// creation without exposing them through the public snapshot. Terminal
    /// host adoption then restores the live content, and creation settlement
    /// publishes the complete resource subtree atomically before startup
    /// returns.
    fn materialize_interrupted_resource_workspaces(&self) -> anyhow::Result<()> {
        let (recoveries, staged) = {
            let registry = self.workspace_registry.lock().unwrap();
            (
                registry.interrupted_resource_creation_recoveries()?,
                registry.interrupted_resource_workspaces()?,
            )
        };
        anyhow::ensure!(
            recoveries.len() <= 1,
            "multiple interrupted resource creations cannot be recovered atomically"
        );
        if staged.is_empty() {
            return Ok(());
        }
        anyhow::ensure!(
            staged.len() == 1,
            "multiple interrupted workspace creations cannot be recovered atomically"
        );
        let active_workspace = staged
            .last()
            .map(|(_, workspace)| workspace.id)
            .expect("non-empty staged workspace list");
        let mut state = self.state.lock().unwrap();
        for (position, workspace) in staged {
            anyhow::ensure!(
                position <= state.workspaces.len(),
                "interrupted workspace {} has invalid position {position}",
                workspace.key
            );
            anyhow::ensure!(
                state.workspace_by_id(workspace.id).is_none(),
                "interrupted workspace {} reuses numeric id {}",
                workspace.key,
                workspace.id
            );
            anyhow::ensure!(
                state.workspace_by_key(&workspace.key).is_none(),
                "interrupted workspace key {} is already live",
                workspace.key
            );
            anyhow::ensure!(
                !state.resource_indexes.workspaces.contains_key(&workspace.public_id),
                "interrupted workspace public id {} is already live",
                workspace.public_id
            );
            state.workspaces.insert(
                position,
                Workspace {
                    id: workspace.id,
                    public_id: workspace.public_id,
                    key: workspace.key,
                    name: workspace.name,
                    screens: Vec::new(),
                    active_screen: 0,
                },
            );
        }
        state.rebuild_workspace_indexes();
        state.rebuild_resource_indexes();
        state.active_workspace = state
            .workspace_index(active_workspace)
            .context("interrupted active workspace disappeared during restore")?;
        Ok(())
    }

    fn materialize_restored_browsers(
        self: &Arc<Self>,
        contents: &[RestoredResourceContent],
    ) -> anyhow::Result<()> {
        let opts = self.surface_options.lock().unwrap().clone();
        let cell_pixels = *self.cell_pixels.lock().unwrap();
        for content in contents {
            let Some(browser) = content.browser.clone() else { continue };
            let mut owner_reservation = self.reserve_surface_owner()?;
            let size = (browser.cols, browser.rows);
            let url = browser.url;
            let surface = browser::new_surface_with_resource_identity(
                content.slot,
                url.clone(),
                size,
                cell_pixels,
                &opts,
                Arc::downgrade(self),
                content.identity.clone(),
            )?;
            surface.set_name(content.name.clone());
            let insertion = {
                let mut state = self.state.lock().unwrap();
                insert_reserved_surface_checked(
                    self,
                    &mut state,
                    surface.clone(),
                    &mut owner_reservation,
                )
            };
            if let Err(error) = insertion {
                self.retire_reserved_surface_runtime(surface, &mut owner_reservation);
                return Err(error);
            }
            match browser.reconnect {
                RegistryBrowserReconnect::Recreate => {
                    self.start_browser_bootstrap(surface, BrowserBootstrap::Create { url }, None);
                }
            }
        }
        Ok(())
    }

    #[cfg(unix)]
    fn restored_terminal_binding(
        &self,
        terminal_id: &str,
    ) -> anyhow::Result<Option<(SurfaceId, TabResourceIdentity)>> {
        let registry = self.workspace_registry.lock().unwrap();
        let Some(public_id) = registry.terminal_resource_id(terminal_id)? else {
            return Ok(None);
        };
        let state = self.state.lock().unwrap();
        let content_id = ContentPublicId::Terminal(public_id);
        let Some(slot) = state.resource_indexes.content.get(&content_id).copied() else {
            return Ok(None);
        };
        let tab_id = state
            .resource_indexes
            .tab_ids
            .get(&slot)
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("restored terminal slot has no tab identity"))?;
        Ok(Some((slot, TabResourceIdentity::new(tab_id, content_id))))
    }

    #[cfg(unix)]
    fn adopt_terminal_hosts(self: &Arc<Self>) -> anyhow::Result<()> {
        let options = self.surface_options.lock().unwrap().clone();
        let exit_records = match options.terminal_host_root.as_deref() {
            Some(root) => crate::terminal_host_runtime::load_terminal_host_exit_records(root)?,
            None => Vec::new(),
        };
        let records = match options.terminal_host_root.as_deref() {
            Some(root) => crate::terminal_host_runtime::load_terminal_host_records(root)?,
            None => Vec::new(),
        };
        let mut handled_terminals = HashSet::new();
        // Sidecars are host-owned write-ahead completion records. Reconcile
        // them before live discovery records so a daemon crash after host
        // completion cannot collapse the exact status into "host missing".
        for (exit_path, record) in exit_records {
            let Some(terminal) =
                self.workspace_registry.lock().unwrap().terminal_record(&record.terminal_id)?
            else {
                continue;
            };
            if terminal.lifecycle == TerminalLifecycle::Tombstoned {
                let _ = crate::terminal_host_runtime::acknowledge_terminal_host_exit_record(
                    &exit_path, &record,
                )?;
                handled_terminals.insert(record.terminal_id);
                continue;
            }
            if terminal
                .incarnation
                .as_deref()
                .is_some_and(|incarnation| incarnation != record.incarnation)
            {
                // Retain evidence from the non-current incarnation. It must
                // never be allowed to terminate a replacement process.
                continue;
            }
            self.persist_terminal_exit(
                &record.terminal_id,
                Some(&record.incarnation),
                &record.exit,
            )?;
            self.materialize_exited_terminal(&record.terminal_id, &options)?;
            let _ = crate::terminal_host_runtime::acknowledge_terminal_host_exit_record(
                &exit_path, &record,
            )?;
            handled_terminals.insert(record.terminal_id);
        }
        for (record_path, record) in records {
            let terminal_id = record.terminal_id.clone();
            if handled_terminals.contains(&terminal_id) {
                if !cleanup_terminal_host_record(&record, &record_path) {
                    self.schedule_terminal_adoption(options.clone(), record, record_path);
                }
                continue;
            }
            let mut terminal =
                self.workspace_registry.lock().unwrap().terminal_record(&terminal_id)?;
            if terminal.is_none() {
                // One-release migration path for hosts launched before SQLite
                // became placement authority. Never trust the JSON hint when
                // its workspace no longer exists.
                let can_import = !record.workspace_key.is_empty()
                    && self.state.lock().unwrap().workspace_by_key(&record.workspace_key).is_some();
                if can_import {
                    let imported = RegistryTerminal {
                        terminal_id: terminal_id.clone(),
                        workspace_key: record.workspace_key.clone(),
                        incarnation: None,
                        lifecycle: TerminalLifecycle::Launching,
                        launch_spec: serde_json::json!({"legacy_import":true}),
                        exit: None,
                    };
                    let mut registry = self.workspace_registry.lock().unwrap();
                    let revision = commit_terminal_transition(
                        &mut registry,
                        "terminal-imported",
                        "import-legacy-terminal",
                        &imported,
                    )?;
                    self.emit_terminal_registry_changed(&registry, revision);
                    terminal = Some(imported);
                } else {
                    if !cleanup_terminal_host_record(&record, &record_path) {
                        self.schedule_terminal_adoption(options.clone(), record, record_path);
                    }
                    continue;
                }
            }
            let terminal = terminal.expect("terminal imported or loaded");
            if terminal.lifecycle == TerminalLifecycle::Tombstoned {
                if !cleanup_terminal_host_record(&record, &record_path) {
                    self.schedule_terminal_adoption(options.clone(), record, record_path);
                }
                continue;
            }
            if terminal.lifecycle == TerminalLifecycle::Exited {
                self.materialize_exited_terminal(&terminal.terminal_id, &options)?;
                handled_terminals.insert(terminal_id.clone());
                if !cleanup_terminal_host_record(&record, &record_path) {
                    self.schedule_terminal_adoption(options.clone(), record, record_path);
                }
                continue;
            }
            if terminal.incarnation.as_deref().is_some_and(|value| value != record.incarnation) {
                self.mark_terminal_exited_and_materialize(
                    &terminal_id,
                    "terminal-incarnation-mismatch",
                    "host-incarnation-mismatch",
                    &options,
                )?;
                handled_terminals.insert(terminal_id.clone());
                if !cleanup_terminal_host_record(&record, &record_path) {
                    self.schedule_terminal_adoption(options.clone(), record, record_path);
                }
                continue;
            }
            if let Err(error) = self.transition_terminal_lifecycle(
                "terminal-adopting",
                "adopt-terminal",
                &terminal_id,
                TerminalLifecycle::Adopting,
                Some(&record.incarnation),
                None,
            ) {
                let current =
                    self.workspace_registry.lock().unwrap().terminal_record(&terminal_id)?;
                if current.as_ref().is_some_and(|terminal| {
                    matches!(
                        terminal.lifecycle,
                        TerminalLifecycle::Exited | TerminalLifecycle::Tombstoned
                    )
                }) {
                    if current
                        .as_ref()
                        .is_some_and(|terminal| terminal.lifecycle == TerminalLifecycle::Exited)
                    {
                        self.materialize_exited_terminal(&terminal_id, &options)?;
                    }
                    handled_terminals.insert(terminal_id.clone());
                    if !cleanup_terminal_host_record(&record, &record_path) {
                        self.schedule_terminal_adoption(options.clone(), record, record_path);
                    }
                    continue;
                }
                return Err(error);
            }
            if terminal_host_record_liveness(&record_path, &record) == TerminalHostLiveness::Dead {
                let _ = crate::terminal_host_runtime::remove_stale_terminal_host_record(
                    &record_path,
                    &record,
                );
                self.mark_terminal_exited_and_materialize(
                    &terminal_id,
                    "terminal-host-proven-dead",
                    "host-process-ended-before-adoption",
                    &options,
                )?;
                handled_terminals.insert(terminal_id.clone());
                continue;
            }
            // Host handshakes can consume their full timeout. Queue every
            // live or indeterminate record before the control socket is
            // published so startup time is independent of record count.
            handled_terminals.insert(terminal_id);
            self.schedule_terminal_adoption(options.clone(), record, record_path);
        }

        // No launcher survives a daemon restart. A durable lifecycle row
        // without a host-owned record therefore represents a closed crash
        // window, not permission to spawn a replacement shell.
        let snapshot = self.workspace_registry.lock().unwrap().terminal_snapshot()?;
        for terminal in snapshot.terminals {
            if terminal.lifecycle == TerminalLifecycle::Tombstoned
                || handled_terminals.contains(&terminal.terminal_id)
            {
                continue;
            }
            if terminal.lifecycle == TerminalLifecycle::Exited {
                self.materialize_exited_terminal(&terminal.terminal_id, &options)?;
                continue;
            }
            self.mark_terminal_exited_and_materialize(
                &terminal.terminal_id,
                "terminal-record-missing",
                "missing-host-record",
                &options,
            )?;
        }
        Ok(())
    }

    /// Project durable Exited state into the normal topology. The placeholder
    /// owns no PTY and can never respawn a shell, but it retains the stable
    /// terminal/incarnation identity until an explicit close tombstones it.
    /// Re-reading under registry -> state makes a concurrent move or close
    /// authoritative.
    #[cfg(unix)]
    fn materialize_exited_terminal(
        self: &Arc<Self>,
        terminal_id: &str,
        options: &SurfaceOptions,
    ) -> anyhow::Result<Option<RunPlacement>> {
        let _creation = self.begin_surface_creation()?;
        let terminal = self.workspace_registry.lock().unwrap().terminal_record(terminal_id)?;
        let Some(terminal) = terminal.filter(|terminal| {
            terminal.lifecycle == TerminalLifecycle::Exited && terminal.incarnation.is_some()
        }) else {
            return Ok(None);
        };
        let identity = TerminalHostIdentity {
            terminal_id: terminal.terminal_id,
            incarnation: terminal.incarnation.expect("filtered Exited incarnation"),
        };
        if let Some((slot, resource_identity)) =
            self.restored_terminal_binding(&identity.terminal_id)?
        {
            if let Some(placement) = {
                let state = self.state.lock().unwrap();
                state
                    .surfaces
                    .contains_key(&slot)
                    .then(|| run_placement_for_surface(&state, slot))
                    .flatten()
            } {
                return Ok(Some(placement));
            }
            let placeholder = Surface::exited_terminal_placeholder_with_resource_identity(
                slot,
                options.clone(),
                Arc::downgrade(self),
                identity.clone(),
                resource_identity,
            )?;
            let placement = {
                let registry = self.workspace_registry.lock().unwrap();
                let Some(current) = registry.terminal_record(terminal_id)? else {
                    return Ok(None);
                };
                if current.lifecycle != TerminalLifecycle::Exited
                    || current.incarnation.as_deref() != Some(identity.incarnation.as_str())
                {
                    return Ok(None);
                }
                let mut state = self.state.lock().unwrap();
                if !state.surfaces.contains_key(&slot) {
                    insert_surface_checked(self, &mut state, placeholder)?;
                }
                run_placement_for_surface(&state, slot).ok_or_else(|| {
                    anyhow::anyhow!("restored terminal has no durable tab placement")
                })?
            };
            self.emit(MuxEvent::TreeChanged);
            return Ok(Some(placement));
        }
        let existing_projection = {
            let registry = self.workspace_registry.lock().unwrap();
            let Some(current) = registry.terminal_record(terminal_id)? else {
                return Ok(None);
            };
            if current.lifecycle != TerminalLifecycle::Exited
                || current.incarnation.as_deref() != Some(identity.incarnation.as_str())
            {
                return Ok(None);
            }
            let mut state = self.state.lock().unwrap();
            let existing = unique_terminal_match(
                terminal_id,
                state.surfaces.values().filter_map(|surface| {
                    surface.terminal_host_identity().map(|identity| (surface.id, identity))
                }),
            )?;
            if existing.is_some() {
                Some(self.project_terminal_to_workspace_in_state(
                    &mut state,
                    terminal_id,
                    &current.workspace_key,
                )?)
            } else {
                None
            }
        };
        if let Some((placement, changed)) = existing_projection {
            if changed {
                self.emit(MuxEvent::TreeChanged);
            }
            return Ok(placement);
        }
        let placeholder = Surface::exited_terminal_placeholder(
            self.next_id(),
            options.clone(),
            Arc::downgrade(self),
            identity.clone(),
        )?;

        let (placement, changed) = {
            let registry = self.workspace_registry.lock().unwrap();
            let Some(current) = registry.terminal_record(terminal_id)? else {
                return Ok(None);
            };
            if current.lifecycle != TerminalLifecycle::Exited
                || current.incarnation.as_deref() != Some(identity.incarnation.as_str())
            {
                return Ok(None);
            }
            let mut state = self.state.lock().unwrap();
            let existing = unique_terminal_match(
                terminal_id,
                state.surfaces.values().filter_map(|surface| {
                    surface.terminal_host_identity().map(|identity| (surface.id, identity))
                }),
            )?;
            if existing.is_none() {
                insert_surface_checked(self, &mut state, placeholder.clone())?;
            }
            match self.project_terminal_to_workspace_in_state(
                &mut state,
                terminal_id,
                &current.workspace_key,
            ) {
                Ok(result) => result,
                Err(error) => {
                    if existing.is_none() {
                        state.surfaces.remove(&placeholder.id);
                    }
                    return Err(error);
                }
            }
        };
        if changed {
            self.emit(MuxEvent::TreeChanged);
        }
        Ok(placement)
    }

    #[cfg(unix)]
    fn mark_terminal_exited_and_materialize(
        self: &Arc<Self>,
        terminal_id: &str,
        _operation: &str,
        reason: &str,
        options: &SurfaceOptions,
    ) -> anyhow::Result<()> {
        let terminal = self.workspace_registry.lock().unwrap().terminal_record(terminal_id)?;
        let Some(terminal) = terminal else { return Ok(()) };
        if terminal.lifecycle == TerminalLifecycle::Tombstoned {
            return Ok(());
        }
        let sidecar = options
            .terminal_host_root
            .as_ref()
            .map(|root| root.join(format!("{terminal_id}.json")))
            .map(|record_path| {
                crate::terminal_host_runtime::terminal_host_exit_record(&record_path)
            })
            .transpose()?
            .flatten()
            .filter(|(_, record)| {
                record.terminal_id == terminal_id
                    && terminal
                        .incarnation
                        .as_deref()
                        .is_none_or(|incarnation| incarnation == record.incarnation)
            });
        if terminal.lifecycle != TerminalLifecycle::Exited {
            let observed = sidecar
                .as_ref()
                .map(|(_, record)| record.exit.clone())
                .unwrap_or_else(|| TerminalExit::unknown(reason));
            let incarnation = sidecar
                .as_ref()
                .map(|(_, record)| record.incarnation.as_str())
                .or(terminal.incarnation.as_deref());
            self.persist_terminal_exit(terminal_id, incarnation, &observed)?;
        }
        if let Some((path, record)) = sidecar {
            let _ = crate::terminal_host_runtime::acknowledge_terminal_host_exit_record(
                &path, &record,
            )?;
        }
        self.materialize_exited_terminal(terminal_id, options)?;
        Ok(())
    }

    #[cfg(unix)]
    fn finish_terminal_adoption(
        &self,
        terminal_id: &str,
        incarnation: &str,
        surface: Arc<Surface>,
        owner_reservation: &mut SurfaceOwnerReservation<'_>,
    ) -> anyhow::Result<()> {
        let _creation = self.begin_surface_creation()?;
        if surface.is_dead() {
            self.persist_terminal_exit(
                terminal_id,
                Some(incarnation),
                &TerminalExit::unknown("host-exited-during-adoption"),
            )?;
            anyhow::bail!("terminal host exited during adoption");
        }
        let mut registry = self.workspace_registry.lock().unwrap();
        let mut state = self.state.lock().unwrap();
        let terminal = registry
            .terminal_record(terminal_id)?
            .ok_or_else(|| anyhow::anyhow!("terminal disappeared during adoption"))?;
        anyhow::ensure!(
            terminal.lifecycle == TerminalLifecycle::Adopting,
            "terminal is no longer awaiting adoption"
        );
        anyhow::ensure!(
            terminal.incarnation.as_deref() == Some(incarnation),
            "terminal incarnation changed during adoption"
        );
        anyhow::ensure!(
            surface.terminal_host_identity().is_some_and(|identity| {
                identity.terminal_id == terminal_id && identity.incarnation == incarnation
            }),
            "adopted host identity does not match durable terminal"
        );

        let before = state.clone();
        if let Some(placement) = run_placement_for_surface(&state, surface.id) {
            anyhow::ensure!(
                !state.surfaces.contains_key(&surface.id),
                "restored terminal slot is already materialized"
            );
            let expected_tab = state.resource_indexes.tab_ids.get(&surface.id);
            let expected_content = state.resource_indexes.content_ids.get(&surface.id);
            let actual = surface.resource_identity();
            anyhow::ensure!(
                actual.is_some_and(|actual| {
                    Some(&actual.tab_id) == expected_tab
                        && Some(&actual.content_id) == expected_content
                }),
                "adopted terminal identity does not match its durable tab"
            );
            let workspace_key =
                state.workspace_by_id(placement.workspace).map(|workspace| workspace.key.as_str());
            anyhow::ensure!(
                workspace_key == Some(terminal.workspace_key.as_str()),
                "restored terminal workspace does not match durable placement"
            );
            anyhow::ensure!(
                !self.consume_terminal_adoption_insert_failure(),
                "injected terminal adoption topology failure"
            );
            insert_surface_with_active_reservation_checked(self, &mut state, surface)?;
        } else {
            let workspace_index = state
                .workspaces
                .iter()
                .position(|workspace| workspace.key == terminal.workspace_key)
                .ok_or_else(|| anyhow::anyhow!("terminal workspace disappeared during adoption"))?;
            let (pane_id, pane) = self.make_pane(surface.id)?;
            let screen_id = self.next_id();
            let screen_public_id = ScreenPublicId::random()?;
            anyhow::ensure!(
                !self.consume_terminal_adoption_insert_failure(),
                "injected terminal adoption topology failure"
            );
            insert_surface_with_active_reservation_checked(self, &mut state, surface)?;
            {
                let workspace = &mut state.workspaces[workspace_index];
                workspace.screens.push(Screen {
                    id: screen_id,
                    public_id: screen_public_id,
                    name: None,
                    root: Node::Leaf(pane_id),
                    active_pane: pane_id,
                    zoomed_pane: None,
                    zellij_auto_layout: Some(vec![pane_id]),
                    viewport_splits: Default::default(),
                    viewport_base_width: None,
                    layout_columns: Vec::new(),
                    layout_revision: 0,
                    layout_undo: Default::default(),
                });
                workspace.active_screen = workspace.screens.len() - 1;
            }
            // Adoption materializes a live pane without stealing focus, but it
            // must still advance the pane-set revision used by frontend focus
            // history pruning.
            state.insert_pane(pane);
            state.rebuild_resource_indexes();
        }

        let revision = match commit_terminal_lifecycle(
            &mut registry,
            "terminal-ready",
            "terminal-adopted",
            terminal_id,
            TerminalLifecycle::Running,
            Some(incarnation),
            None,
        ) {
            Ok((_, revision)) => revision,
            Err(error) => {
                *state = before;
                return Err(error);
            }
        };
        owner_reservation.release();
        drop(state);
        self.emit_terminal_registry_changed(&registry, revision);
        Ok(())
    }

    #[cfg(unix)]
    fn ensure_terminal_adoption_workers(self: &Arc<Self>) -> std::io::Result<()> {
        let coordinator = self.terminal_adoption_coordinator.clone();
        let (existing, missing) = {
            let mut state = coordinator.state.lock().unwrap();
            if state.stopping {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::Interrupted,
                    "terminal adoption is stopping",
                ));
            }
            if state.workers_running >= TERMINAL_ADOPTION_WORKERS {
                return Ok(());
            }
            let existing = state.workers_running;
            let missing = TERMINAL_ADOPTION_WORKERS - existing;
            state.workers_running += missing;
            (existing, missing)
        };
        let mut started = 0;
        let mut first_error = None;
        for worker in 0..missing {
            let worker = existing + worker;
            let mux = Arc::downgrade(self);
            let worker_coordinator = coordinator.clone();
            match std::thread::Builder::new().name(format!("terminal-adoption-{worker}")).spawn(
                move || {
                    #[cfg(test)]
                    if let Some(mux) = mux.upgrade() {
                        mux.terminal_adoption_workers_started.fetch_add(1, Ordering::AcqRel);
                    }
                    Self::run_terminal_adoption_worker(mux, worker_coordinator);
                },
            ) {
                Ok(_) => started += 1,
                Err(error) => {
                    let mut state = coordinator.state.lock().unwrap();
                    state.workers_running = state.workers_running.saturating_sub(1);
                    coordinator.wake.notify_all();
                    first_error.get_or_insert(error);
                }
            }
        }
        if existing + started > 0 {
            Ok(())
        } else {
            Err(first_error.expect("at least one worker spawn failed"))
        }
    }

    #[cfg(unix)]
    fn consume_terminal_adoption_insert_failure(&self) -> bool {
        self.terminal_adoption_insert_failures
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |remaining| remaining.checked_sub(1))
            .is_ok()
    }

    #[cfg(unix)]
    fn schedule_terminal_adoption(
        self: &Arc<Self>,
        options: SurfaceOptions,
        record: crate::terminal_host_runtime::TerminalHostRecord,
        record_path: std::path::PathBuf,
    ) {
        if self.shutting_down.load(Ordering::Acquire) {
            return;
        }
        let terminal_id = record.terminal_id.clone();
        {
            let mut tracked = self.terminal_adoptions.lock().unwrap();
            if tracked.contains(&terminal_id) {
                return;
            }
            tracked.insert(terminal_id.clone());
        }

        let task = TerminalAdoptionTask {
            options,
            record,
            record_path,
            next_attempt: Instant::now() + Duration::from_millis(100),
            delay: Duration::from_millis(100),
        };
        let mut state = self.terminal_adoption_coordinator.state.lock().unwrap();
        if !state.enqueue(task) {
            self.terminal_adoptions.lock().unwrap().remove(&terminal_id);
            state.rescan_required = true;
            state.next_rescan.get_or_insert_with(Instant::now);
            self.terminal_adoption_coordinator.wake.notify_one();
            return;
        }
        drop(state);
        self.terminal_adoption_coordinator.wake.notify_one();
        if self.ensure_terminal_adoption_workers().is_err() {
            self.terminal_adoptions.lock().unwrap().remove(&terminal_id);
            let mut state = self.terminal_adoption_coordinator.state.lock().unwrap();
            state.tasks.retain(|task| task.record.terminal_id != terminal_id);
            state.deferred.retain(|task| task.record.terminal_id != terminal_id);
            state.promote_deferred();
            state.rescan_required = true;
            state.next_rescan.get_or_insert_with(Instant::now);
        }
    }

    #[cfg(unix)]
    fn rescan_terminal_adoptions(self: &Arc<Self>) -> bool {
        let options = self.surface_options.lock().unwrap().clone();
        let Some(root) = options.terminal_host_root.as_deref() else { return true };
        let Ok(records) = crate::terminal_host_runtime::load_terminal_host_records(root) else {
            return false;
        };
        let registered = {
            let registry = self.workspace_registry.lock().unwrap();
            let Ok(terminals) = registry.terminal_ids_including_tombstones() else {
                return false;
            };
            terminals.into_iter().collect::<HashSet<_>>()
        };
        let live_incarnations = {
            let state = self.state.lock().unwrap();
            let mut live = HashMap::<String, HashSet<String>>::new();
            for identity in
                state.surfaces.values().filter_map(|surface| surface.live_terminal_host_identity())
            {
                live.entry(identity.terminal_id).or_default().insert(identity.incarnation);
            }
            live
        };
        for (record_path, record) in records {
            let already_live = registered.contains(&record.terminal_id)
                && live_incarnations
                    .get(&record.terminal_id)
                    .is_some_and(|incarnations| incarnations.contains(&record.incarnation));
            if already_live {
                continue;
            }
            self.schedule_terminal_adoption(options.clone(), record, record_path);
        }
        true
    }

    #[cfg(unix)]
    fn run_terminal_adoption_worker(
        mux: Weak<Self>,
        coordinator: Arc<TerminalAdoptionCoordinator>,
    ) {
        loop {
            let stopping = coordinator.state.lock().unwrap().stopping;
            if stopping {
                Self::terminal_adoption_worker_stopped(&coordinator);
                return;
            }
            let Some(mux) = mux.upgrade() else {
                Self::terminal_adoption_worker_stopped(&coordinator);
                return;
            };
            if mux.shutting_down.load(Ordering::Acquire) {
                mux.terminal_adoptions.lock().unwrap().clear();
                drop(mux);
                Self::terminal_adoption_worker_stopped(&coordinator);
                return;
            }

            let mut state = coordinator.state.lock().unwrap();
            let now = Instant::now();
            if state.rescan_due(now) {
                state.rescan_required = false;
                state.next_rescan = None;
                drop(state);
                if !mux.rescan_terminal_adoptions() {
                    let mut state = coordinator.state.lock().unwrap();
                    state.rescan_required = true;
                    state.next_rescan = Some(Instant::now() + state.rescan_delay);
                    state.rescan_delay = (state.rescan_delay * 2).min(Duration::from_secs(5));
                } else {
                    coordinator.state.lock().unwrap().rescan_delay = Duration::from_millis(100);
                }
                continue;
            }

            if let Some(index) = state.tasks.iter().position(|task| task.next_attempt <= now) {
                let mut task = state.tasks.swap_remove(index);
                state.in_flight += 1;
                drop(state);
                let complete = mux.try_terminal_adoption(&task);
                let mut state = coordinator.state.lock().unwrap();
                state.in_flight =
                    state.in_flight.checked_sub(1).expect("adoption worker tracks in-flight tasks");
                if complete || mux.shutting_down.load(Ordering::Acquire) {
                    mux.terminal_adoptions.lock().unwrap().remove(&task.record.terminal_id);
                } else {
                    task.delay = (task.delay * 2).min(Duration::from_secs(5));
                    task.next_attempt = Instant::now() + task.delay;
                    state.requeue_retry(task);
                }
                state.promote_deferred();
                drop(state);
                coordinator.wake.notify_one();
                continue;
            }

            let wait = state
                .tasks
                .iter()
                .map(|task| task.next_attempt.saturating_duration_since(now))
                .min()
                .unwrap_or(Duration::from_secs(1))
                .min(Duration::from_secs(1));
            drop(mux);
            let _ = coordinator.wake.wait_timeout(state, wait).unwrap();
        }
    }

    #[cfg(unix)]
    fn terminal_adoption_worker_stopped(coordinator: &TerminalAdoptionCoordinator) {
        let mut state = coordinator.state.lock().unwrap();
        state.workers_running = state.workers_running.saturating_sub(1);
        coordinator.wake.notify_all();
    }

    #[cfg(unix)]
    fn request_terminal_adoption_stop(&self) {
        self.terminal_adoptions.lock().unwrap().clear();
        let mut state = self.terminal_adoption_coordinator.state.lock().unwrap();
        state.stopping = true;
        state.tasks.clear();
        state.deferred.clear();
        self.terminal_adoption_coordinator.wake.notify_all();
    }

    #[cfg(unix)]
    fn wait_for_terminal_adoption_workers_until(&self, deadline: Instant) -> bool {
        let mut state = self.terminal_adoption_coordinator.state.lock().unwrap();
        while state.workers_running != 0 {
            let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
                return false;
            };
            let (next, timeout) =
                self.terminal_adoption_coordinator.wake.wait_timeout(state, remaining).unwrap();
            state = next;
            if timeout.timed_out() && state.workers_running != 0 {
                return false;
            }
        }
        true
    }

    #[cfg(unix)]
    fn try_terminal_adoption(self: &Arc<Self>, task: &TerminalAdoptionTask) -> bool {
        let terminal_id = &task.record.terminal_id;
        let terminal = match self.workspace_registry.lock().unwrap().terminal_record(terminal_id) {
            Ok(terminal) => terminal,
            Err(_) => return false,
        };
        let Some(terminal) = terminal else {
            return cleanup_terminal_host_record(&task.record, &task.record_path);
        };
        if terminal.lifecycle == TerminalLifecycle::Exited {
            if self.materialize_exited_terminal(terminal_id, &task.options).is_err() {
                return false;
            }
            return cleanup_terminal_host_record(&task.record, &task.record_path);
        }
        if terminal.lifecycle == TerminalLifecycle::Tombstoned {
            return cleanup_terminal_host_record(&task.record, &task.record_path);
        }
        if terminal
            .incarnation
            .as_deref()
            .is_some_and(|incarnation| incarnation != task.record.incarnation)
        {
            if self
                .mark_terminal_exited_and_materialize(
                    terminal_id,
                    "terminal-incarnation-mismatch",
                    "host-incarnation-mismatch",
                    &task.options,
                )
                .is_err()
            {
                return false;
            }
            return cleanup_terminal_host_record(&task.record, &task.record_path);
        }
        if terminal.lifecycle == TerminalLifecycle::Running {
            let already_live = match self.resolve_terminal(terminal_id) {
                Ok(resolution) => resolution.is_some_and(|resolution| resolution.surface.is_some()),
                Err(_) => return false,
            };
            if already_live {
                return true;
            }
            if self
                .transition_terminal_lifecycle(
                    "terminal-adopting",
                    "retry-terminal-adoption",
                    terminal_id,
                    TerminalLifecycle::Adopting,
                    Some(&task.record.incarnation),
                    None,
                )
                .is_err()
            {
                let current =
                    match self.workspace_registry.lock().unwrap().terminal_record(terminal_id) {
                        Ok(Some(current)) => current,
                        Ok(None) | Err(_) => return false,
                    };
                if current.lifecycle == TerminalLifecycle::Exited {
                    if self.materialize_exited_terminal(terminal_id, &task.options).is_err() {
                        return false;
                    }
                    return cleanup_terminal_host_record(&task.record, &task.record_path);
                }
                if current.lifecycle == TerminalLifecycle::Tombstoned {
                    return cleanup_terminal_host_record(&task.record, &task.record_path);
                }
                if current.incarnation.as_deref() != Some(task.record.incarnation.as_str()) {
                    return false;
                }
                match current.lifecycle {
                    TerminalLifecycle::Adopting => {}
                    TerminalLifecycle::Running => {
                        return match self.resolve_terminal(terminal_id) {
                            Ok(resolution) => {
                                resolution.is_some_and(|resolution| resolution.surface.is_some())
                            }
                            Err(_) => false,
                        };
                    }
                    TerminalLifecycle::Launching
                    | TerminalLifecycle::Exited
                    | TerminalLifecycle::Tombstoned => return false,
                }
            }
        }
        if terminal_host_record_liveness(&task.record_path, &task.record)
            == TerminalHostLiveness::Dead
        {
            let _ = crate::terminal_host_runtime::remove_stale_terminal_host_record(
                &task.record_path,
                &task.record,
            );
            return self
                .mark_terminal_exited_and_materialize(
                    terminal_id,
                    "terminal-host-proven-dead",
                    "host-process-ended-before-adoption",
                    &task.options,
                )
                .is_ok();
        }
        let Ok(_creation) = self.begin_surface_creation() else {
            return true;
        };
        let mut owner_reservation = match self.reserve_surface_owner() {
            Ok(reservation) => reservation,
            Err(_) => return false,
        };
        let restored_binding = match self.restored_terminal_binding(terminal_id) {
            Ok(binding) => binding,
            Err(_) => return false,
        };
        let id = restored_binding.as_ref().map_or_else(|| self.next_id(), |(slot, _)| *slot);
        #[cfg(test)]
        let adoption_surface_factory =
            self.terminal_adoption_surface_factory.lock().unwrap().clone();
        #[cfg(test)]
        let adopted = if let Some(factory) = adoption_surface_factory {
            factory(id)
        } else if let Some((_, resource_identity)) = &restored_binding {
            Surface::adopt_hosted_with_resource_identity(
                id,
                task.options.clone(),
                Arc::downgrade(self),
                task.record.clone(),
                task.record_path.clone(),
                resource_identity.clone(),
            )
        } else {
            Surface::adopt_hosted(
                id,
                task.options.clone(),
                Arc::downgrade(self),
                task.record.clone(),
                task.record_path.clone(),
            )
        };
        #[cfg(not(test))]
        let adopted = if let Some((_, resource_identity)) = &restored_binding {
            Surface::adopt_hosted_with_resource_identity(
                id,
                task.options.clone(),
                Arc::downgrade(self),
                task.record.clone(),
                task.record_path.clone(),
                resource_identity.clone(),
            )
        } else {
            Surface::adopt_hosted(
                id,
                task.options.clone(),
                Arc::downgrade(self),
                task.record.clone(),
                task.record_path.clone(),
            )
        };
        let Ok(surface) = adopted else { return false };
        #[cfg(test)]
        let after_attach = self.terminal_adoption_after_attach.lock().unwrap().clone();
        #[cfg(test)]
        if let Some(hook) = after_attach {
            hook();
        }
        if self
            .finish_terminal_adoption(
                terminal_id,
                &task.record.incarnation,
                surface.clone(),
                &mut owner_reservation,
            )
            .is_ok()
        {
            self.reap_if_dead(&surface);
            return true;
        }
        let host_is_dead = surface.is_dead()
            || terminal_host_record_liveness(&task.record_path, &task.record)
                == TerminalHostLiveness::Dead;
        surface.disconnect_for_daemon_shutdown();
        owner_reservation.release();
        if !host_is_dead {
            return false;
        }
        let _ = crate::terminal_host_runtime::remove_stale_terminal_host_record(
            &task.record_path,
            &task.record,
        );
        self.mark_terminal_exited_and_materialize(
            terminal_id,
            "terminal-adoption-failed",
            "host-adoption-topology-failed",
            &task.options,
        )
        .is_ok()
    }

    #[cfg(test)]
    pub(crate) fn new_for_test(
        session: impl Into<String>,
        surface_options: SurfaceOptions,
    ) -> Arc<Self> {
        Self::new_with_test_surface_runtime(
            session,
            surface_options,
            ProviderWorkspaceState::default(),
            true,
        )
    }

    #[cfg(test)]
    pub(crate) fn new_provider_managed_for_test(
        session: impl Into<String>,
        surface_options: SurfaceOptions,
        authority: ProviderWorkspaceAuthority,
    ) -> Arc<Self> {
        Self::new_with_test_surface_runtime(
            session,
            surface_options,
            ProviderWorkspaceState {
                managed: true,
                mux_generation: None,
                authority_generation: 1,
                authority: Some(authority),
            },
            true,
        )
    }

    #[cfg(test)]
    pub(crate) fn new_provider_managed_pending_for_test(
        session: impl Into<String>,
        surface_options: SurfaceOptions,
        mux_generation: &str,
    ) -> Arc<Self> {
        let mux = Self::new_with_test_surface_runtime(
            session,
            surface_options,
            ProviderWorkspaceState {
                managed: true,
                mux_generation: Some(mux_generation.into()),
                authority_generation: 0,
                authority: None,
            },
            true,
        );
        validate_mux_generation(mux_generation).unwrap();
        mux
    }

    fn next_id(&self) -> u64 {
        self.next_id.fetch_add(1, Ordering::Relaxed)
    }

    fn begin_surface_creation(&self) -> anyhow::Result<SurfaceCreationGuard<'_>> {
        self.surface_creations.begin()
    }

    fn reserve_surface_owner(&self) -> anyhow::Result<SurfaceOwnerReservation<'_>> {
        // Every topology removal transfers ownership to the shutdown ledger
        // before releasing this same state lock. Counting reservations here
        // therefore closes the only interval in which a new runtime could be
        // spawned without an owner slot.
        let state = self.state.lock().unwrap();
        let used = state
            .surfaces
            .len()
            .saturating_add(self.shutdown_owners.len())
            .saturating_add(self.surface_owner_reservations.load(Ordering::Acquire));
        if used >= self.shutdown_owner_capacity() {
            anyhow::bail!("surface_owner_capacity_exhausted");
        }
        self.surface_owner_reservations.fetch_add(1, Ordering::AcqRel);
        drop(state);
        Ok(SurfaceOwnerReservation { mux: self, active: true })
    }

    #[cfg(not(test))]
    fn shutdown_owner_capacity(&self) -> usize {
        SHUTDOWN_OWNER_CAPACITY
    }

    #[cfg(test)]
    fn shutdown_owner_capacity(&self) -> usize {
        self.shutdown_owner_capacity.load(Ordering::Acquire).min(SHUTDOWN_OWNER_CAPACITY)
    }

    fn next_active_at(&self) -> u64 {
        self.next_active_at.fetch_add(1, Ordering::Relaxed)
    }

    fn next_notification_id(&self) -> u64 {
        self.next_notification_id.fetch_add(1, Ordering::Relaxed)
    }

    /// Allocate an undo-coalescing owner for one in-process frontend.
    ///
    /// Layout undo is in-memory state, so this namespace intentionally follows
    /// the mux lifecycle rather than durable workspace identity.
    pub fn allocate_in_process_resize_owner(&self) -> u64 {
        self.next_in_process_resize_owner
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |owner| {
                Some(owner.wrapping_add(1).max(1))
            })
            .expect("in-process resize owner allocation cannot fail")
    }

    fn new_workspace_key() -> anyhow::Result<String> {
        let mut bytes = [0u8; 16];
        getrandom::fill(&mut bytes).map_err(|_| {
            anyhow::anyhow!(
                "could not create workspace identity; retry, then restart cmux if the problem continues"
            )
        })?;
        // RFC 9562 UUIDv4 version and variant bits. Keeping the formatter
        // local avoids making stable workspace identity depend on a UUID
        // library at the protocol boundary.
        bytes[6] = (bytes[6] & 0x0f) | 0x40;
        bytes[8] = (bytes[8] & 0x3f) | 0x80;
        Ok(format!(
            "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
            bytes[0],
            bytes[1],
            bytes[2],
            bytes[3],
            bytes[4],
            bytes[5],
            bytes[6],
            bytes[7],
            bytes[8],
            bytes[9],
            bytes[10],
            bytes[11],
            bytes[12],
            bytes[13],
            bytes[14],
            bytes[15]
        ))
    }

    fn validate_workspace_key(key: &str) -> anyhow::Result<()> {
        if key.trim().is_empty() {
            anyhow::bail!("workspace key cannot be empty");
        }
        if key.len() > WORKSPACE_KEY_MAX_BYTES {
            anyhow::bail!("workspace key exceeds {WORKSPACE_KEY_MAX_BYTES} bytes");
        }
        Ok(())
    }

    fn validate_workspace_name(name: &str) -> anyhow::Result<()> {
        if name.len() > WORKSPACE_NAME_MAX_BYTES {
            anyhow::bail!("workspace name exceeds {WORKSPACE_NAME_MAX_BYTES} bytes");
        }
        Ok(())
    }

    fn workspace_lifecycle(&self, workspace: WorkspaceId) -> Arc<Mutex<()>> {
        let mut lifecycles = self.workspace_lifecycles.lock().unwrap();
        lifecycles.retain(|_, lifecycle| lifecycle.strong_count() > 0);
        if let Some(lifecycle) = lifecycles.get(&workspace).and_then(Weak::upgrade) {
            return lifecycle;
        }
        let lifecycle = Arc::new(Mutex::new(()));
        lifecycles.insert(workspace, Arc::downgrade(&lifecycle));
        lifecycle
    }

    /// Permanently assigns workspace rename/delete ownership to the external
    /// provider for this mux generation. The transition is intentionally
    /// one-way so a stale frontend cannot reopen ordinary mutation paths.
    pub fn mark_workspaces_provider_managed_internal(&self) {
        self.provider_workspace.lock().unwrap().managed = true;
    }

    pub fn workspaces_are_provider_managed(&self) -> bool {
        self.provider_workspace.lock().unwrap().managed
    }

    pub fn provider_workspace_authority_status(&self) -> ProviderWorkspaceAuthorityStatus {
        self.provider_workspace.lock().unwrap().status()
    }

    pub fn install_or_rotate_provider_workspace_authority(
        &self,
        mux_generation: &str,
        expected_authority_generation: u64,
        authority_generation: u64,
        authority: ProviderWorkspaceAuthority,
    ) -> Result<ProviderWorkspaceAuthorityStatus, ProviderWorkspaceAuthorityUpdateError> {
        let mut state = self.provider_workspace.lock().unwrap();
        if !state.managed || state.mux_generation.is_none() {
            return Err(ProviderWorkspaceAuthorityUpdateError::Unmanaged);
        }
        if state.mux_generation.as_deref() != Some(mux_generation) {
            return Err(ProviderWorkspaceAuthorityUpdateError::MuxGenerationMismatch);
        }

        if authority_generation == state.authority_generation {
            let identical = state
                .authority
                .as_ref()
                .is_some_and(|installed| constant_time_eq(authority.expose(), installed.expose()));
            return if identical {
                Ok(state.status())
            } else {
                Err(ProviderWorkspaceAuthorityUpdateError::GenerationConflict)
            };
        }

        if expected_authority_generation != state.authority_generation {
            return Err(ProviderWorkspaceAuthorityUpdateError::ExpectedGenerationMismatch);
        }
        let valid_initial_install = state.authority_generation == 0
            && state.authority.is_none()
            && authority_generation > 0;
        let valid_rotation = state.authority.is_some()
            && authority_generation == state.authority_generation.saturating_add(1);
        if !valid_initial_install && !valid_rotation {
            return Err(ProviderWorkspaceAuthorityUpdateError::InvalidGeneration);
        }
        state.authority_generation = authority_generation;
        state.authority = Some(authority);
        Ok(state.status())
    }

    /// Validates the secret provisioned for this provider-owned mux
    /// generation. The same rejection covers missing and incorrect secrets so
    /// the control socket cannot be used to probe whether a value was set.
    pub fn authorize_provider_workspace_authority(&self, provided: &str) -> anyhow::Result<()> {
        let authorized = self
            .provider_workspace
            .lock()
            .unwrap()
            .authority
            .as_ref()
            .is_some_and(|expected| constant_time_eq(provided.as_bytes(), expected.expose()));
        if !authorized {
            anyhow::bail!("invalid provider workspace authority");
        }
        Ok(())
    }

    fn authorize_workspace_lifecycle_mutation(
        &self,
        authorization: WorkspaceMutationAuthority<'_>,
        operation: &str,
    ) -> anyhow::Result<MutexGuard<'_, ProviderWorkspaceState>> {
        let authority = self.provider_workspace.lock().unwrap();
        if authority.managed && matches!(authorization, WorkspaceMutationAuthority::Ordinary) {
            anyhow::bail!(
                "cannot {operation} a provider-managed workspace directly; use the managed workspace lifecycle controls"
            );
        }
        if !authority.managed && !matches!(authorization, WorkspaceMutationAuthority::Ordinary) {
            anyhow::bail!(
                "cannot apply provider workspace {operation}; this session is not provider-managed"
            );
        }
        if let WorkspaceMutationAuthority::ProviderCredential(provided) = authorization {
            let authorized = authority
                .authority
                .as_ref()
                .is_some_and(|expected| constant_time_eq(provided.as_bytes(), expected.expose()));
            if !authorized {
                anyhow::bail!("invalid provider workspace authority");
            }
        }
        Ok(authority)
    }

    fn pending_workspace_surface(&self, surface: SurfaceId) -> PendingWorkspaceSurface<'_> {
        PendingWorkspaceSurface { pending: &self.pending_workspace_surfaces, surface }
    }

    fn workspace_for_surface_in_state(state: &State, surface: SurfaceId) -> Option<WorkspaceId> {
        let pane = state.pane_of(surface)?;
        let (workspace, _) = state.screen_of(pane)?;
        Some(state.workspaces[workspace].id)
    }

    fn workspace_for_tree_target_in_state(
        state: &State,
        target: TreeCloseTarget,
    ) -> Option<WorkspaceId> {
        match target {
            TreeCloseTarget::Pane(pane) => {
                let (workspace, _) = state.screen_of(pane)?;
                Some(state.workspaces[workspace].id)
            }
            TreeCloseTarget::Screen(screen) => state
                .workspaces
                .iter()
                .find(|workspace| workspace.screens.iter().any(|candidate| candidate.id == screen))
                .map(|workspace| workspace.id),
        }
    }

    fn surface_workspace(&self, surface: SurfaceId) -> Option<WorkspaceId> {
        self.pending_workspace_surfaces.lock().unwrap().get(&surface).copied().or_else(|| {
            let state = self.state.lock().unwrap();
            Self::workspace_for_surface_in_state(&state, surface)
        })
    }

    fn require_workspace_revision(state: &State, expected: Option<u64>) -> anyhow::Result<()> {
        if let Some(expected) = expected
            && expected != state.workspace_revision
        {
            anyhow::bail!(
                "workspace revision conflict: expected {expected}, current {}",
                state.workspace_revision
            );
        }
        Ok(())
    }

    fn registry_projection(&self, state: &State) -> Vec<RegistryWorkspace> {
        state
            .workspaces
            .iter()
            .map(|workspace| RegistryWorkspace {
                id: workspace.id,
                public_id: workspace.public_id.clone(),
                key: workspace.key.clone(),
                name: workspace.name.clone(),
                group_key: self.session.clone(),
            })
            .collect()
    }

    fn ordinary_resource_selectors() -> crate::ResourceSelectors {
        crate::ResourceSelectors {
            machine: Some("current".into()),
            session: Some("current".into()),
            ..crate::ResourceSelectors::default()
        }
    }

    fn ordinary_workspace_selectors(
        &self,
        workspace: WorkspaceId,
    ) -> Option<crate::ResourceSelectors> {
        let public_id =
            self.with_state(|state| state.resource_indexes.workspace_ids.get(&workspace).cloned())?;
        Some(crate::ResourceSelectors {
            workspace: Some(public_id.to_string()),
            ..Self::ordinary_resource_selectors()
        })
    }

    fn ordinary_screen_selectors(&self, screen: ScreenId) -> Option<crate::ResourceSelectors> {
        let public_id =
            self.with_state(|state| state.resource_indexes.screen_ids.get(&screen).cloned())?;
        Some(crate::ResourceSelectors {
            screen: Some(public_id.to_string()),
            ..Self::ordinary_resource_selectors()
        })
    }

    fn ordinary_pane_selectors(&self, pane: PaneId) -> Option<crate::ResourceSelectors> {
        let public_id =
            self.with_state(|state| state.resource_indexes.pane_ids.get(&pane).cloned())?;
        Some(crate::ResourceSelectors {
            pane: Some(public_id.to_string()),
            ..Self::ordinary_resource_selectors()
        })
    }

    fn ordinary_tab_selectors(&self, surface: SurfaceId) -> Option<crate::ResourceSelectors> {
        let public_id =
            self.with_state(|state| state.resource_indexes.tab_ids.get(&surface).cloned())?;
        Some(crate::ResourceSelectors {
            tab: Some(public_id.to_string()),
            ..Self::ordinary_resource_selectors()
        })
    }

    fn commit_ordinary_topology_operation(
        self: &Arc<Self>,
        operation: ResourceOperation,
        selectors: crate::ResourceSelectors,
        fields: Map<String, Value>,
    ) -> anyhow::Result<ResourcePatchCommit> {
        self.commit_resource_topology_operation(
            operation,
            selectors,
            fields,
            None,
            &WorkspaceMutation::local("cmux-tui"),
        )
    }

    fn nullable_name_fields(name: String) -> Map<String, Value> {
        Map::from_iter([(
            "name".into(),
            if name.is_empty() { Value::Null } else { Value::String(name) },
        )])
    }

    fn insert_cell_size(fields: &mut Map<String, Value>, size: Option<(u16, u16)>) {
        if let Some((cols, rows)) = size {
            fields.insert("cols".into(), Value::from(cols));
            fields.insert("rows".into(), Value::from(rows));
        }
    }

    fn insert_optional_string(
        fields: &mut Map<String, Value>,
        name: &'static str,
        value: Option<String>,
    ) {
        if let Some(value) = value {
            fields.insert(name.into(), Value::String(value));
        }
    }

    fn ordinary_created_surface(
        &self,
        commit: &ResourcePatchCommit,
    ) -> anyhow::Result<Arc<Surface>> {
        let tab_id = TabPublicId::parse(
            commit.result["tab_id"]
                .as_str()
                .context("created resource result omitted its tab id")?
                .to_string(),
        )?;
        let surface = self
            .with_state(|state| state.resource_indexes.tabs.get(&tab_id).copied())
            .context("created tab disappeared")?;
        self.surface(surface).context("created surface disappeared")
    }

    #[allow(clippy::too_many_arguments)]
    fn commit_resource_mutation_plan(
        &self,
        mutation: &WorkspaceMutation,
        operation: &str,
        fingerprint: &Value,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        prepare: impl FnOnce(&mut State, &WorkspaceRegistry) -> anyhow::Result<ResourceMutationPlan>,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let mut registry = self.workspace_registry.lock().unwrap();
        if let Some(replay) = registry.replay_resource_patch(mutation, operation, fingerprint)? {
            return Ok(replay);
        }

        let mut state = self.state.lock().unwrap();
        let mut plan = prepare(&mut state, &registry)?;
        persist_public_topology_result(operation, &mut plan.result, &plan.deltas)?;
        #[cfg(test)]
        {
            *self.resource_mutation_metrics.lock().unwrap() = Some(plan.metrics);
        }
        let commit = registry.commit_resource_patch(
            mutation,
            operation,
            fingerprint,
            expected_generation,
            expected_revision,
            &plan.patch,
            &plan.result,
            &plan.deltas,
        )?;
        plan.apply(&mut state, &commit);
        drop(state);
        drop(registry);
        if !commit.replayed {
            self.publish_resource_event();
        }
        Ok(commit)
    }

    #[cfg(test)]
    pub(crate) fn resource_create_empty_workspace(
        &self,
        name: Option<String>,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
    ) -> anyhow::Result<ResourcePatchCommit> {
        if let Some(name) = name.as_deref() {
            Self::validate_workspace_name(name)?;
        }
        let workspace_slot = self.next_id();
        let public_id = WorkspacePublicId::random()?;
        let generated_key = Self::new_workspace_key()?;
        let fingerprint = serde_json::json!({
            "operation": "workspace.create",
            "name": name,
            "initial_content": "empty",
        });
        self.commit_resource_mutation_plan(
            mutation,
            "workspace.create",
            &fingerprint,
            expected_generation,
            expected_revision,
            move |state, registry| {
                anyhow::ensure!(
                    state.workspaces.len() < WORKSPACE_REGISTRY_LIMIT,
                    "workspace limit reached ({WORKSPACE_REGISTRY_LIMIT})"
                );
                let key = generated_key.clone();
                let name = name.clone().unwrap_or_else(|| Self::default_workspace_name(state));
                let index = state.workspaces.len();
                let workspace = Workspace {
                    id: workspace_slot,
                    public_id: public_id.clone(),
                    key: key.clone(),
                    name: name.clone(),
                    screens: Vec::new(),
                    active_screen: 0,
                };
                let mut order = Vec::with_capacity(index + 1);
                order.extend(state.workspaces.iter().map(|workspace| workspace.public_id.clone()));
                order.push(public_id.clone());
                state.workspaces.reserve(1);
                state.workspace_index_by_id.reserve(1);
                state.workspace_id_by_key.reserve(1);
                state.resource_indexes.workspaces.reserve(1);
                state.resource_indexes.workspace_ids.reserve(1);
                let result = serde_json::json!({
                    "workspace": public_id.as_str(),
                    "name": name,
                    "index": index,
                });
                let mut deltas = Vec::with_capacity(2);
                if let Some(previous) = state.workspaces.get(state.active_workspace) {
                    deltas.push(workspace_resource_upsert(
                        0,
                        registry.session_id().as_str(),
                        &previous.public_id,
                        &previous.name,
                        state.active_workspace,
                        false,
                    ));
                }
                deltas.push(workspace_resource_upsert(
                    deltas.len(),
                    registry.session_id().as_str(),
                    &public_id,
                    &name,
                    index,
                    true,
                ));
                Ok(ResourceMutationPlan::new(
                    ResourcePatch {
                        changes: vec![
                            ResourceChange::UpsertWorkspace {
                                workspace: RegistryWorkspace {
                                    id: workspace.id,
                                    public_id: public_id.clone(),
                                    key,
                                    name,
                                    group_key: self.session.clone(),
                                },
                                position: index,
                                active_screen: None,
                            },
                            ResourceChange::SetWorkspaceOrder { workspace_ids: order },
                            ResourceChange::SetActiveWorkspace { workspace_id: Some(public_id) },
                        ],
                    },
                    result,
                    Value::Array(deltas),
                    move |state| {
                        state.push_workspace(workspace);
                        state.active_workspace = index;
                        state.workspace_revision = state.workspace_revision.saturating_add(1);
                    },
                )
                .with_metrics(ResourceMutationMetrics {
                    touched_resources: 1,
                    order_entries: index + 1,
                    terminal_queries: 0,
                    changed_rows: index + 3,
                }))
            },
        )
    }

    #[cfg(test)]
    pub(crate) fn resource_rename_workspace(
        &self,
        workspace_id: &WorkspacePublicId,
        name: String,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
    ) -> anyhow::Result<ResourcePatchCommit> {
        Self::validate_workspace_name(&name)?;
        let fingerprint = serde_json::json!({
            "operation": "workspace.rename",
            "workspace": workspace_id.as_str(),
            "name": name,
        });
        let target = workspace_id.clone();
        self.commit_resource_mutation_plan(
            mutation,
            "workspace.rename",
            &fingerprint,
            expected_generation,
            expected_revision,
            move |state, registry| {
                let slot = *state
                    .resource_indexes
                    .workspaces
                    .get(&target)
                    .with_context(|| format!("unknown workspace {target}"))?;
                let index = state
                    .workspace_index(slot)
                    .with_context(|| format!("workspace {target} has no live slot"))?;
                let workspace = &state.workspaces[index];
                let changed = workspace.name != name;
                let active_screen = workspace
                    .screens
                    .get(workspace.active_screen)
                    .map(|screen| screen.public_id.clone());
                let durable = RegistryWorkspace {
                    id: workspace.id,
                    public_id: workspace.public_id.clone(),
                    key: workspace.key.clone(),
                    name: name.clone(),
                    group_key: self.session.clone(),
                };
                let result = serde_json::json!({
                    "workspace": target.as_str(),
                    "name": name,
                    "changed": changed,
                });
                let deltas = Value::Array(vec![workspace_resource_upsert(
                    0,
                    registry.session_id().as_str(),
                    &target,
                    &name,
                    index,
                    index == state.active_workspace,
                )]);
                Ok(ResourceMutationPlan::new(
                    ResourcePatch {
                        changes: vec![ResourceChange::UpsertWorkspace {
                            workspace: durable,
                            position: index,
                            active_screen,
                        }],
                    },
                    result,
                    deltas,
                    move |state| {
                        state.workspaces[index].name = name;
                        state.workspace_revision = state.workspace_revision.saturating_add(1);
                    },
                )
                .with_metrics(ResourceMutationMetrics {
                    touched_resources: 1,
                    order_entries: 0,
                    terminal_queries: 0,
                    changed_rows: 1,
                }))
            },
        )
    }

    pub(crate) fn resource_rename_workspace_selected(
        &self,
        selectors: crate::ResourceSelectors,
        name: String,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
    ) -> anyhow::Result<ResourcePatchCommit> {
        Self::validate_workspace_name(&name)?;
        let fingerprint = serde_json::json!({
            "operation": "workspace.rename",
            "selectors": selectors,
            "name": name,
        });
        self.commit_resource_mutation_plan(
            mutation,
            "workspace.rename",
            &fingerprint,
            expected_generation,
            expected_revision,
            move |state, registry| {
                let resolved = self
                    .resolve_resource_path_in_state(
                        state,
                        registry,
                        crate::ResourceTarget::Workspace,
                        &selectors,
                    )
                    .map_err(anyhow::Error::new)?;
                let target = resolved
                    .path
                    .workspace
                    .expect("workspace target resolution returns a workspace");
                let slot =
                    resolved.workspace.expect("workspace target resolution returns a live slot");
                let index = state
                    .workspace_index(slot)
                    .with_context(|| format!("workspace {target} has no live slot"))?;
                #[cfg(test)]
                if let Some(hook) =
                    self.resource_rename_after_selector_resolution.lock().unwrap().clone()
                {
                    hook(&target);
                }
                let workspace = &state.workspaces[index];
                let changed = workspace.name != name;
                let active_screen = workspace
                    .screens
                    .get(workspace.active_screen)
                    .map(|screen| screen.public_id.clone());
                let durable = RegistryWorkspace {
                    id: workspace.id,
                    public_id: workspace.public_id.clone(),
                    key: workspace.key.clone(),
                    name: name.clone(),
                    group_key: self.session.clone(),
                };
                let result = serde_json::json!({
                    "workspace": target.as_str(),
                    "name": name,
                    "changed": changed,
                });
                let deltas = Value::Array(vec![workspace_resource_upsert(
                    0,
                    registry.session_id().as_str(),
                    &target,
                    &name,
                    index,
                    index == state.active_workspace,
                )]);
                Ok(ResourceMutationPlan::new(
                    ResourcePatch {
                        changes: vec![ResourceChange::UpsertWorkspace {
                            workspace: durable,
                            position: index,
                            active_screen,
                        }],
                    },
                    result,
                    deltas,
                    move |state| {
                        state.workspaces[index].name = name;
                        state.workspace_revision = state.workspace_revision.saturating_add(1);
                    },
                )
                .with_metrics(ResourceMutationMetrics {
                    touched_resources: 1,
                    order_entries: 0,
                    terminal_queries: 0,
                    changed_rows: 1,
                }))
            },
        )
    }

    #[cfg(test)]
    pub(crate) fn resource_move_workspace(
        &self,
        workspace_id: &WorkspacePublicId,
        index: usize,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let fingerprint = serde_json::json!({
            "operation": "workspace.move",
            "workspace": workspace_id.as_str(),
            "index": index,
        });
        let target = workspace_id.clone();
        self.commit_resource_mutation_plan(
            mutation,
            "workspace.move",
            &fingerprint,
            expected_generation,
            expected_revision,
            move |state, registry| {
                let slot = *state
                    .resource_indexes
                    .workspaces
                    .get(&target)
                    .with_context(|| format!("unknown workspace {target}"))?;
                let old_index = state
                    .workspace_index(slot)
                    .with_context(|| format!("workspace {target} has no live slot"))?;
                let new_index = index.min(state.workspaces.len().saturating_sub(1));
                let changed = new_index != old_index;
                let active_slot =
                    state.workspaces.get(state.active_workspace).map(|workspace| workspace.id);
                let mut order = state
                    .workspaces
                    .iter()
                    .map(|workspace| workspace.public_id.clone())
                    .collect::<Vec<_>>();
                if changed {
                    let moved = order.remove(old_index);
                    order.insert(new_index, moved);
                }
                let changes = if changed {
                    vec![ResourceChange::SetWorkspaceOrder { workspace_ids: order.clone() }]
                } else {
                    let workspace = &state.workspaces[old_index];
                    vec![ResourceChange::UpsertWorkspace {
                        workspace: RegistryWorkspace {
                            id: workspace.id,
                            public_id: workspace.public_id.clone(),
                            key: workspace.key.clone(),
                            name: workspace.name.clone(),
                            group_key: self.session.clone(),
                        },
                        position: old_index,
                        active_screen: workspace
                            .screens
                            .get(workspace.active_screen)
                            .map(|screen| screen.public_id.clone()),
                    }]
                };
                let result = serde_json::json!({
                    "workspace": target.as_str(),
                    "index": new_index,
                    "changed": changed,
                });
                let deltas = Value::Array(
                    order
                        .iter()
                        .enumerate()
                        .map(|(position, workspace_id)| {
                            let workspace = state
                                .workspaces
                                .iter()
                                .find(|workspace| &workspace.public_id == workspace_id)
                                .expect("workspace order was built from live workspaces");
                            workspace_resource_upsert(
                                position,
                                registry.session_id().as_str(),
                                workspace_id,
                                &workspace.name,
                                position,
                                active_slot == Some(workspace.id),
                            )
                        })
                        .collect(),
                );
                let order_entries = usize::from(changed) * order.len();
                Ok(ResourceMutationPlan::new(
                    ResourcePatch { changes },
                    result,
                    deltas,
                    move |state| {
                        if changed {
                            state.move_workspace(old_index, new_index);
                            for (workspace_index, _, _) in state.split_screens.values_mut() {
                                *workspace_index = if *workspace_index == old_index {
                                    new_index
                                } else if old_index < new_index
                                    && (old_index + 1..=new_index).contains(workspace_index)
                                {
                                    workspace_index.saturating_sub(1)
                                } else if new_index < old_index
                                    && (new_index..old_index).contains(workspace_index)
                                {
                                    workspace_index.saturating_add(1)
                                } else {
                                    *workspace_index
                                };
                            }
                            state.active_workspace = active_slot
                                .and_then(|slot| state.workspace_index(slot))
                                .unwrap_or_else(|| state.workspaces.len().saturating_sub(1));
                        }
                        state.workspace_revision = state.workspace_revision.saturating_add(1);
                    },
                )
                .with_metrics(ResourceMutationMetrics {
                    touched_resources: 1,
                    order_entries,
                    terminal_queries: 0,
                    changed_rows: if changed { order.len() } else { 1 },
                }))
            },
        )
    }

    pub(crate) fn resource_move_workspace_selected(
        &self,
        selectors: crate::ResourceSelectors,
        index: usize,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let fingerprint = serde_json::json!({
            "operation": "workspace.move",
            "selectors": selectors,
            "index": index,
        });
        self.commit_resource_mutation_plan(
            mutation,
            "workspace.move",
            &fingerprint,
            expected_generation,
            expected_revision,
            move |state, registry| {
                let resolved = self
                    .resolve_resource_path_in_state(
                        state,
                        registry,
                        crate::ResourceTarget::Workspace,
                        &selectors,
                    )
                    .map_err(anyhow::Error::new)?;
                let target = resolved
                    .path
                    .workspace
                    .expect("workspace target resolution returns a workspace");
                let slot =
                    resolved.workspace.expect("workspace target resolution returns a live slot");
                let old_index = state
                    .workspace_index(slot)
                    .with_context(|| format!("workspace {target} has no live slot"))?;
                let new_index = index.min(state.workspaces.len().saturating_sub(1));
                let changed = new_index != old_index;
                let active_slot =
                    state.workspaces.get(state.active_workspace).map(|workspace| workspace.id);
                let mut order = state
                    .workspaces
                    .iter()
                    .map(|workspace| workspace.public_id.clone())
                    .collect::<Vec<_>>();
                if changed {
                    let moved = order.remove(old_index);
                    order.insert(new_index, moved);
                }
                let changes = if changed {
                    vec![ResourceChange::SetWorkspaceOrder { workspace_ids: order.clone() }]
                } else {
                    let workspace = &state.workspaces[old_index];
                    vec![ResourceChange::UpsertWorkspace {
                        workspace: RegistryWorkspace {
                            id: workspace.id,
                            public_id: workspace.public_id.clone(),
                            key: workspace.key.clone(),
                            name: workspace.name.clone(),
                            group_key: self.session.clone(),
                        },
                        position: old_index,
                        active_screen: workspace
                            .screens
                            .get(workspace.active_screen)
                            .map(|screen| screen.public_id.clone()),
                    }]
                };
                let result = serde_json::json!({
                    "workspace": target.as_str(),
                    "index": new_index,
                    "changed": changed,
                });
                let deltas = Value::Array(
                    order
                        .iter()
                        .enumerate()
                        .map(|(position, workspace_id)| {
                            let workspace = state
                                .workspaces
                                .iter()
                                .find(|workspace| &workspace.public_id == workspace_id)
                                .expect("workspace order was built from live workspaces");
                            workspace_resource_upsert(
                                position,
                                registry.session_id().as_str(),
                                workspace_id,
                                &workspace.name,
                                position,
                                active_slot == Some(workspace.id),
                            )
                        })
                        .collect(),
                );
                let order_entries = usize::from(changed) * order.len();
                Ok(ResourceMutationPlan::new(
                    ResourcePatch { changes },
                    result,
                    deltas,
                    move |state| {
                        if changed {
                            state.move_workspace(old_index, new_index);
                            for (workspace_index, _, _) in state.split_screens.values_mut() {
                                *workspace_index = if *workspace_index == old_index {
                                    new_index
                                } else if old_index < new_index
                                    && (old_index + 1..=new_index).contains(workspace_index)
                                {
                                    workspace_index.saturating_sub(1)
                                } else if new_index < old_index
                                    && (new_index..old_index).contains(workspace_index)
                                {
                                    workspace_index.saturating_add(1)
                                } else {
                                    *workspace_index
                                };
                            }
                            state.active_workspace = active_slot
                                .and_then(|slot| state.workspace_index(slot))
                                .unwrap_or_else(|| state.workspaces.len().saturating_sub(1));
                        }
                        state.workspace_revision = state.workspace_revision.saturating_add(1);
                    },
                )
                .with_metrics(ResourceMutationMetrics {
                    touched_resources: 1,
                    order_entries,
                    terminal_queries: 0,
                    changed_rows: if changed { order.len() } else { 1 },
                }))
            },
        )
    }

    pub fn registry_identity(&self) -> (String, String) {
        let registry = self.workspace_registry.lock().unwrap();
        (registry.registry_id().to_string(), registry.generation().to_string())
    }

    pub fn install_resource_machine_service(
        &self,
        service: Arc<dyn crate::ResourceMachineService>,
    ) -> anyhow::Result<()> {
        self.resource_machine_service
            .set(service)
            .map_err(|_| anyhow::anyhow!("resource machine service is already installed"))
    }

    pub(crate) fn resource_machine_service(
        self: &Arc<Self>,
    ) -> Arc<dyn crate::ResourceMachineService> {
        self.resource_machine_service
            .get_or_init(|| {
                Arc::new(crate::resource_api::LocalResourceMachineService::new(Arc::downgrade(
                    self,
                )))
            })
            .clone()
    }

    pub(crate) fn local_resource_context(
        &self,
    ) -> anyhow::Result<crate::resource_api::LocalResourceContext> {
        let registry = self.workspace_registry.lock().unwrap();
        let topology = registry.resource_topology_snapshot()?;
        Ok(crate::resource_api::LocalResourceContext {
            machine_id: registry.machine_id().clone(),
            session_id: registry.session_id().clone(),
            session_name: self.session.clone(),
            generation: topology.generation,
            revision: topology.revision,
        })
    }

    pub(crate) fn with_resource_projection<R>(
        &self,
        project: impl FnOnce(&WorkspaceRegistry, &State) -> anyhow::Result<R>,
    ) -> anyhow::Result<R> {
        let registry = self.workspace_registry.lock().unwrap();
        let state = self.state.lock().unwrap();
        project(&registry, &state)
    }

    pub(crate) fn lookup_resource_effect(
        &self,
        idempotency_key: &str,
        operation: &str,
        fingerprint: &Value,
    ) -> anyhow::Result<Option<ResourceEffectPreparation>> {
        self.workspace_registry.lock().unwrap().lookup_resource_effect(
            idempotency_key,
            operation,
            fingerprint,
        )
    }

    pub(crate) fn resource_input_receipt_hmac(
        &self,
        idempotency_key: &str,
        operation: &str,
        canonical_fields: &[u8],
    ) -> [u8; 32] {
        self.workspace_registry.lock().unwrap().resource_input_receipt_hmac(
            idempotency_key,
            operation,
            canonical_fields,
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub(crate) fn prepare_resource_effect(
        &self,
        idempotency_key: &str,
        operation: &str,
        fingerprint: &Value,
        intent: &Value,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
    ) -> anyhow::Result<ResourceEffectPreparation> {
        self.workspace_registry.lock().unwrap().prepare_resource_effect(
            idempotency_key,
            operation,
            fingerprint,
            intent,
            expected_generation,
            expected_revision,
        )
    }

    pub(crate) fn mark_resource_effect_executing(
        &self,
        idempotency_key: &str,
        operation: &str,
        fingerprint: &Value,
    ) -> anyhow::Result<Value> {
        self.workspace_registry.lock().unwrap().mark_resource_effect_executing(
            idempotency_key,
            operation,
            fingerprint,
        )
    }

    pub(crate) fn commit_resource_effect(
        &self,
        idempotency_key: &str,
        operation: &str,
        fingerprint: &Value,
        outcome: &ResourceEffectOutcome,
        deltas: Option<&Value>,
    ) -> anyhow::Result<u64> {
        let mut registry = self.workspace_registry.lock().unwrap();
        let revision = registry.commit_resource_effect(
            idempotency_key,
            operation,
            fingerprint,
            outcome,
            deltas,
        )?;
        if deltas.is_some() {
            self.state.lock().unwrap().resource_revision = revision;
            drop(registry);
            self.publish_resource_event();
        } else {
            drop(registry);
        }
        Ok(revision)
    }

    /// Capture a post-effect live projection and commit its topology, public
    /// deltas, and effect receipt while holding one registry -> state writer
    /// fence. This prevents another topology writer from landing between the
    /// captured tree and its durable revision.
    pub(crate) fn commit_resource_effect_projection(
        &self,
        idempotency_key: &str,
        operation: &str,
        fingerprint: &Value,
        project: impl FnOnce(&WorkspaceRegistry, &mut State) -> anyhow::Result<ResourceEffectProjection>,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let mut registry = self.workspace_registry.lock().unwrap();
        let mut state = self.state.lock().unwrap();
        let mut projection = project(&registry, &mut state)?;
        persist_public_topology_result(operation, &mut projection.result, &projection.changes)?;
        #[cfg(test)]
        if let Some(hook) = self.resource_projection_before_commit.lock().unwrap().clone() {
            hook();
        }
        let commit = registry.commit_resource_effect_patch(
            idempotency_key,
            operation,
            fingerprint,
            &projection.patch,
            &projection.result,
            &projection.changes,
        )?;
        state.resource_revision = commit.revision;
        drop(state);
        drop(registry);
        self.publish_resource_event();
        Ok(commit)
    }

    pub(crate) fn commit_full_resource_effect_projection(
        &self,
        idempotency_key: &str,
        operation: &str,
        fingerprint: &Value,
        result: Value,
    ) -> anyhow::Result<ResourcePatchCommit> {
        self.commit_resource_effect_projection(
            idempotency_key,
            operation,
            fingerprint,
            |registry, state| self.resource_effect_projection_locked(registry, state, result),
        )
    }

    /// Reconcile an already-committed local mutation into one public topology
    /// revision. This is reserved for legacy/internal paths whose durable
    /// side effect predates the resource coordinator.
    fn commit_ordinary_full_resource_projection(
        &self,
        operation: &'static str,
        result: Value,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let mutation = WorkspaceMutation::local("cmux-tui");
        let fingerprint = serde_json::json!({"operation":operation,"result":result});
        self.commit_full_resource_projection_with_mutation(
            &mutation,
            operation,
            &fingerprint,
            result,
        )
    }

    pub(crate) fn commit_full_resource_projection_with_mutation(
        &self,
        mutation: &WorkspaceMutation,
        operation: &str,
        fingerprint: &Value,
        result: Value,
    ) -> anyhow::Result<ResourcePatchCommit> {
        self.commit_resource_mutation_plan(
            mutation,
            operation,
            fingerprint,
            None,
            None,
            |state, registry| {
                let projection = self.resource_effect_projection_locked(registry, state, result)?;
                Ok(ResourceMutationPlan::new(
                    projection.patch,
                    projection.result,
                    projection.changes,
                    |_| {},
                ))
            },
        )
    }

    pub(crate) fn mark_resource_effect_indeterminate(
        &self,
        idempotency_key: &str,
    ) -> anyhow::Result<()> {
        self.workspace_registry.lock().unwrap().mark_resource_effect_indeterminate(idempotency_key)
    }

    pub(crate) fn resource_surface_for_terminal(
        &self,
        terminal_id: &TerminalPublicId,
    ) -> Option<SurfaceId> {
        self.state
            .lock()
            .unwrap()
            .resource_indexes
            .content
            .get(&ContentPublicId::Terminal(terminal_id.clone()))
            .copied()
    }

    /// Read only public terminal completion state. The host UUID and
    /// incarnation remain an internal fencing mechanism and never enter the
    /// resource API result.
    pub(crate) fn terminal_exit_state(
        &self,
        terminal_id: &TerminalPublicId,
    ) -> anyhow::Result<Value> {
        #[cfg(test)]
        let _query = TerminalExitStateQueryGuard(&self.terminal_exit_state_queries);
        let registry = self.workspace_registry.lock().unwrap();
        let host_id = registry
            .terminal_host_id(terminal_id)?
            .ok_or_else(|| anyhow::anyhow!("terminal {terminal_id} is not live"))?;
        let terminal = registry
            .terminal_record(&host_id)?
            .ok_or_else(|| anyhow::anyhow!("terminal {terminal_id} has no durable placement"))?;
        if terminal.lifecycle == TerminalLifecycle::Exited {
            let exit = terminal.exit.as_ref().and_then(Value::as_object).ok_or_else(|| {
                anyhow::anyhow!("exited terminal {terminal_id} omitted exit metadata")
            })?;
            let outcome = exit.get("outcome").cloned().ok_or_else(|| {
                anyhow::anyhow!("exited terminal {terminal_id} omitted its outcome")
            })?;
            let exited_at = exit.get("exited_at").and_then(Value::as_str).ok_or_else(|| {
                anyhow::anyhow!("exited terminal {terminal_id} omitted exited_at")
            })?;
            let exit_revision = exit.get("revision").and_then(Value::as_str).ok_or_else(|| {
                anyhow::anyhow!("exited terminal {terminal_id} omitted its revision")
            })?;
            return Ok(serde_json::json!({
                "state": "exited",
                "terminal_id": terminal_id,
                "lifecycle": "exited",
                "outcome": outcome,
                "exited_at": exited_at,
                "revision": exit_revision,
            }));
        }
        let revision = registry.resource_revision()?;
        let lifecycle = match terminal.lifecycle {
            TerminalLifecycle::Launching | TerminalLifecycle::Adopting => "launching",
            TerminalLifecycle::Running => "running",
            TerminalLifecycle::Exited => "exited",
            TerminalLifecycle::Tombstoned => {
                anyhow::bail!("terminal {terminal_id} is tombstoned")
            }
        };
        Ok(serde_json::json!({
            "state": "pending",
            "terminal_id": terminal_id,
            "lifecycle": lifecycle,
            "revision": revision.to_string(),
        }))
    }

    pub(crate) fn subscribe_terminal_exit(
        &self,
        terminal_id: &TerminalPublicId,
    ) -> TerminalExitSubscription<'_> {
        self.terminal_exit_waiters.subscribe(terminal_id)
    }

    fn terminal_public_ids_for_hosted(
        registry: &WorkspaceRegistry,
        hosted: &[(String, Option<String>)],
    ) -> anyhow::Result<Vec<TerminalPublicId>> {
        let mut public_ids = Vec::with_capacity(hosted.len());
        let mut unique = HashSet::with_capacity(hosted.len());
        for (terminal_id, _) in hosted {
            let is_tombstoned = registry
                .terminal_record(terminal_id)?
                .is_none_or(|terminal| terminal.lifecycle == TerminalLifecycle::Tombstoned);
            if is_tombstoned {
                continue;
            }
            if let Some(public_id) = registry.terminal_resource_id(terminal_id)?
                && unique.insert(public_id.clone())
            {
                public_ids.push(public_id);
            }
        }
        Ok(public_ids)
    }

    fn notify_terminal_exit_waiters(
        &self,
        terminal_ids: impl IntoIterator<Item = TerminalPublicId>,
    ) {
        for terminal_id in terminal_ids {
            self.terminal_exit_waiters.notify(&terminal_id);
        }
    }

    pub(crate) fn wait_for_terminal_exit(
        &self,
        terminal_id: &TerminalPublicId,
        timeout: Option<Duration>,
    ) -> anyhow::Result<Value> {
        let deadline = timeout
            .map(|timeout| {
                Instant::now()
                    .checked_add(timeout)
                    .ok_or_else(|| anyhow::anyhow!("terminal exit timeout exceeds deadline range"))
            })
            .transpose()?;
        // Register before the initial query. A concurrent durable exit either
        // appears in that query or wakes this exact terminal subscription.
        let subscription = self.subscribe_terminal_exit(terminal_id);
        let state = self.terminal_exit_state(terminal_id)?;
        if state["state"] == "exited" || timeout == Some(Duration::ZERO) {
            return Ok(state);
        }
        let _explicit_wake = subscription.wait_until(deadline);
        // One targeted read closes either the exit-notification or deadline
        // race. Idle waits perform no periodic registry work.
        self.terminal_exit_state(terminal_id)
    }

    #[cfg(test)]
    pub(crate) fn terminal_exit_waiter_count_for_test(
        &self,
        terminal_id: &TerminalPublicId,
    ) -> usize {
        self.terminal_exit_waiters.waiter_count(terminal_id)
    }

    #[cfg(test)]
    pub(crate) fn reset_terminal_exit_state_query_count_for_test(&self) {
        self.terminal_exit_state_queries.store(0, Ordering::Release);
    }

    #[cfg(test)]
    pub(crate) fn terminal_exit_state_query_count_for_test(&self) -> u64 {
        self.terminal_exit_state_queries.load(Ordering::Acquire)
    }

    #[cfg(test)]
    pub(crate) fn persist_terminal_exit_for_test(
        &self,
        terminal_id: &TerminalPublicId,
        exit: &TerminalExit,
    ) -> anyhow::Result<bool> {
        let (host_id, incarnation) = {
            let registry = self.workspace_registry.lock().unwrap();
            let host_id = registry
                .terminal_host_id(terminal_id)?
                .ok_or_else(|| anyhow::anyhow!("unknown terminal {terminal_id}"))?;
            let incarnation =
                registry.terminal_record(&host_id)?.and_then(|terminal| terminal.incarnation);
            (host_id, incarnation)
        };
        self.persist_terminal_exit(&host_id, incarnation.as_deref(), exit)
    }

    fn publish_resource_event(&self) {
        let mut epoch = self.resource_event_epoch.lock().unwrap();
        *epoch = epoch.wrapping_add(1);
        self.resource_event_changed.notify_all();
    }

    pub(crate) fn resource_event_epoch(&self) -> u64 {
        *self.resource_event_epoch.lock().unwrap()
    }

    pub(crate) fn wait_for_resource_event(&self, epoch: u64, timeout: Duration) -> u64 {
        let current = self.resource_event_epoch.lock().unwrap();
        if *current != epoch {
            return *current;
        }
        let (current, _) = self.resource_event_changed.wait_timeout(current, timeout).unwrap();
        *current
    }

    pub(crate) fn resource_events_after(
        &self,
        revision: u64,
    ) -> anyhow::Result<crate::workspace_registry::ResourceEventPage> {
        self.workspace_registry.lock().unwrap().resource_events_after(revision)
    }

    #[cfg(test)]
    pub(crate) fn resource_mutation_count_for_test(&self) -> anyhow::Result<u64> {
        self.workspace_registry.lock().unwrap().resource_mutation_count_for_test()
    }

    #[cfg(test)]
    pub(crate) fn resource_agent_projection_count_for_test(&self) -> anyhow::Result<u64> {
        self.workspace_registry.lock().unwrap().resource_agent_projection_count_for_test()
    }

    pub fn terminal_registry_snapshot(&self) -> anyhow::Result<TerminalRegistrySnapshot> {
        self.workspace_registry.lock().unwrap().terminal_snapshot()
    }

    pub fn terminal_registry_revision(&self) -> anyhow::Result<u64> {
        self.workspace_registry.lock().unwrap().terminal_revision()
    }

    #[cfg(test)]
    pub(crate) fn reset_terminal_snapshot_count_for_test(&self) {
        self.workspace_registry.lock().unwrap().reset_terminal_snapshot_count_for_test();
    }

    #[cfg(test)]
    pub(crate) fn terminal_snapshot_count_for_test(&self) -> usize {
        self.workspace_registry.lock().unwrap().terminal_snapshot_count_for_test()
    }

    pub fn terminal_registry_events_page(
        &self,
        revision: u64,
    ) -> anyhow::Result<(
        TerminalRegistrySnapshot,
        Vec<crate::workspace_registry::TerminalRegistryEvent>,
    )> {
        // One writer guard is the read transaction boundary exposed to a
        // frontend. Otherwise a commit between snapshot and event queries can
        // return an event whose revision is newer than terminal_revision.
        let registry = self.workspace_registry.lock().unwrap();
        let snapshot = registry.terminal_snapshot()?;
        let events = registry.terminal_events_after(revision)?;
        Ok((snapshot, events))
    }

    pub fn workspace_registry_event(
        &self,
        revision: u64,
    ) -> anyhow::Result<Option<crate::workspace_registry::RegistryEvent>> {
        if revision == 0 {
            return Ok(None);
        }
        Ok(self
            .workspace_registry
            .lock()
            .unwrap()
            .events_after(revision - 1)?
            .into_iter()
            .find(|event| event.revision == revision))
    }

    pub fn get_frontend_projection(
        &self,
        frontend: &str,
        scope: &str,
        subject_key: &str,
    ) -> anyhow::Result<Option<FrontendProjection>> {
        self.workspace_registry.lock().unwrap().get_frontend_projection(
            frontend,
            scope,
            subject_key,
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub fn put_frontend_projection(
        &self,
        mutation: &WorkspaceMutation,
        frontend: &str,
        scope: &str,
        subject_key: &str,
        schema_version: u32,
        expected_projection_revision: Option<u64>,
        projection: &Value,
    ) -> anyhow::Result<ProjectionCommit> {
        let mut registry = self.workspace_registry.lock().unwrap();
        let commit = registry.put_frontend_projection(
            mutation,
            frontend,
            scope,
            subject_key,
            schema_version,
            expected_projection_revision,
            projection,
        )?;
        if !commit.replayed {
            self.emit(MuxEvent::FrontendProjectionChanged {
                frontend: frontend.to_string(),
                scope: scope.to_string(),
                subject_key: subject_key.to_string(),
                projection_revision: commit.projection.projection_revision,
                origin: mutation.origin.clone(),
                mutation_id: mutation.id.clone(),
            });
        }
        Ok(commit)
    }

    pub(crate) fn resource_put_frontend_projection_selected(
        &self,
        selectors: crate::ResourceSelectors,
        projection_id: &FrontendProjectionPublicId,
        projection: &Value,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let fingerprint = serde_json::json!({
            "operation":"frontend_projection.put",
            "selectors":selectors,
            "projection":projection,
        });
        let mut registry = self.workspace_registry.lock().unwrap();
        if let Some(replay) =
            registry.replay_resource_patch(mutation, "frontend_projection.put", &fingerprint)?
        {
            return Ok(replay);
        }
        let mut session_selectors = selectors;
        session_selectors.frontend_projection = None;
        let mut state = self.state.lock().unwrap();
        let resolved = self
            .resolve_resource_path_in_state(
                &state,
                &registry,
                crate::ResourceTarget::Session,
                &session_selectors,
            )
            .map_err(anyhow::Error::new)?;
        let session_id =
            resolved.path.session.context("projection route omitted its session identity")?;
        let value = serde_json::json!({
            "id":projection_id,
            "session_id":session_id,
            "projection":projection,
        });
        let deltas = serde_json::json!([{
            "kind":"upsert",
            "sequence":0,
            "resource":"frontend_projection",
            "id":projection_id,
            "value":value,
        }]);
        let commit = registry.commit_resource_projection(
            mutation,
            "frontend_projection.put",
            &fingerprint,
            None,
            expected_revision,
            "resource-api",
            "session",
            projection_id.as_str(),
            1,
            projection,
            &value,
            &deltas,
        )?;
        state.resource_revision = commit.revision;
        drop(state);
        drop(registry);
        if !commit.replayed {
            self.publish_resource_event();
            self.emit(MuxEvent::FrontendProjectionChanged {
                frontend: "resource-api".to_string(),
                scope: "session".to_string(),
                subject_key: projection_id.to_string(),
                projection_revision: commit.revision,
                origin: mutation.origin.clone(),
                mutation_id: mutation.id.clone(),
            });
        }
        Ok(commit)
    }

    fn resolve_workspace_selector(
        state: &State,
        id: Option<WorkspaceId>,
        key: Option<&str>,
    ) -> anyhow::Result<Option<(WorkspaceId, String)>> {
        let by_id = id.and_then(|id| state.workspace_by_id(id));
        let by_key = key.and_then(|key| state.workspace_by_key(key));
        let workspace = match (id, key, by_id, by_key) {
            (None, None, _, _) => anyhow::bail!("workspace or key is required"),
            (Some(id), None, Some(workspace), _) if workspace.id == id => Some(workspace),
            (Some(_), None, None, _) => None,
            (None, Some(key), _, Some(workspace)) if workspace.key == key => Some(workspace),
            (None, Some(_), _, None) => None,
            (Some(_), Some(_), Some(by_id), Some(by_key)) if by_id.id == by_key.id => Some(by_id),
            (Some(_), Some(_), _, _) => {
                anyhow::bail!("workspace id and key do not identify the same workspace")
            }
            _ => unreachable!("workspace selector cases are exhaustive"),
        };
        Ok(workspace.map(|workspace| (workspace.id, workspace.key.clone())))
    }

    pub fn subscribe(&self) -> MuxEventReceiver {
        self.subscribers.subscribe()
    }

    pub fn subscribe_attached_surface(&self, surface: SurfaceId) -> MuxEventReceiver {
        self.subscribers.subscribe_attached_surface(surface)
    }

    pub fn subscribe_surface_session(&self, surface: SurfaceId) -> Option<MuxEventReceiver> {
        let state = self.state.lock().unwrap();
        let pane = state.pane_of(surface)?;
        let (workspace_index, screen_index) = state.screen_of(pane)?;
        let workspace = state.workspaces.get(workspace_index)?;
        let screen = workspace.screens.get(screen_index)?;
        Some(self.subscribers.subscribe_surface_session(surface, workspace.id, screen.id, pane))
    }

    pub fn emit(&self, event: MuxEvent) {
        self.subscribers.emit(event);
    }

    fn emit_tree_delta(&self, delta: TreeDelta, selection_resync: bool) {
        self.emit(MuxEvent::TreeDelta(delta));
        if selection_resync {
            self.emit(MuxEvent::TreeSelectionChanged);
        }
    }

    fn emit_empty_if_current(&self, workspace_revision: Option<u64>) {
        let Some(workspace_revision) = workspace_revision else { return };
        #[cfg(test)]
        let before_empty_check = self.workspace_close_before_empty_check.lock().unwrap().clone();
        #[cfg(test)]
        if let Some(hook) = before_empty_check {
            hook();
        }
        let state = self.state.lock().unwrap();
        if state.workspaces.is_empty() && state.workspace_revision == workspace_revision {
            self.emit(MuxEvent::Empty);
        }
    }

    fn rebuild_split_screen_index(state: &mut State) {
        fn index_node(
            node: &Node,
            workspace_index: usize,
            screen_index: usize,
            screen: ScreenId,
            index: &mut HashMap<SplitId, (usize, usize, ScreenId)>,
        ) {
            if let Node::Split { id, a, b, .. } = node {
                index.insert(*id, (workspace_index, screen_index, screen));
                index_node(a, workspace_index, screen_index, screen, index);
                index_node(b, workspace_index, screen_index, screen, index);
            }
        }

        let mut index = HashMap::new();
        for (workspace_index, workspace) in state.workspaces.iter().enumerate() {
            for (screen_index, screen) in workspace.screens.iter().enumerate() {
                debug_assert!(
                    screen.layout_column_projection_is_consistent(),
                    "screen {} has a stale layout column projection",
                    screen.id
                );
                index_node(&screen.root, workspace_index, screen_index, screen.id, &mut index);
            }
        }
        state.split_screens = index;
        state.rebuild_resource_indexes();
    }

    fn emit_terminal_registry_changed(&self, registry: &WorkspaceRegistry, terminal_revision: u64) {
        self.emit(MuxEvent::TerminalRegistryChanged {
            registry_id: registry.registry_id().to_string(),
            generation: registry.generation().to_string(),
            terminal_revision,
        });
    }

    fn transition_terminal_lifecycle(
        &self,
        event_kind: &str,
        operation: &str,
        terminal_id: &str,
        lifecycle: TerminalLifecycle,
        incarnation: Option<&str>,
        exit: Option<Value>,
    ) -> anyhow::Result<(RegistryTerminal, u64)> {
        anyhow::ensure!(
            lifecycle != TerminalLifecycle::Exited,
            "terminal exits must use the durable public exit latch"
        );
        let mut registry = self.workspace_registry.lock().unwrap();
        let result = commit_terminal_lifecycle(
            &mut registry,
            event_kind,
            operation,
            terminal_id,
            lifecycle,
            incarnation,
            exit,
        )?;
        self.emit_terminal_registry_changed(&registry, result.1);
        Ok(result)
    }

    /// A broken admin stream is not evidence that the per-terminal process
    /// died. The surface keeps its tab and reconnects the same incarnation;
    /// this callback only exposes the transient lifecycle to frontends.
    pub(crate) fn terminal_host_connection_lost(
        &self,
        surface_id: SurfaceId,
        identity: &TerminalHostIdentity,
    ) -> bool {
        if self.shutting_down.load(Ordering::Acquire) {
            return false;
        }
        let mut registry = self.workspace_registry.lock().unwrap();
        let state = self.state.lock().unwrap();
        let identity_matches = state
            .surfaces
            .get(&surface_id)
            .and_then(|surface| surface.terminal_host_identity())
            .is_some_and(|current| current == *identity);
        drop(state);
        if !identity_matches {
            return false;
        }
        let Ok(Some(terminal)) = registry.terminal_record(&identity.terminal_id) else {
            return false;
        };
        if terminal.incarnation.as_deref() != Some(identity.incarnation.as_str())
            || matches!(
                terminal.lifecycle,
                TerminalLifecycle::Exited | TerminalLifecycle::Tombstoned
            )
        {
            return false;
        }
        if terminal.lifecycle == TerminalLifecycle::Adopting {
            return true;
        }
        match commit_terminal_lifecycle(
            &mut registry,
            "terminal-adopting",
            "terminal-admin-stream-lost",
            &identity.terminal_id,
            TerminalLifecycle::Adopting,
            Some(&identity.incarnation),
            None,
        ) {
            Ok((_, revision)) => {
                self.emit_terminal_registry_changed(&registry, revision);
                true
            }
            Err(error) => {
                self.emit(MuxEvent::Status(format!(
                    "could not persist terminal {} reconnect state: {error}",
                    identity.terminal_id
                )));
                false
            }
        }
    }

    pub(crate) fn terminal_host_reconnected(
        &self,
        surface_id: SurfaceId,
        identity: &TerminalHostIdentity,
    ) -> bool {
        if self.shutting_down.load(Ordering::Acquire) {
            return false;
        }
        let mut registry = self.workspace_registry.lock().unwrap();
        let state = self.state.lock().unwrap();
        let identity_matches = state
            .surfaces
            .get(&surface_id)
            .and_then(|surface| surface.terminal_host_identity())
            .is_some_and(|current| current == *identity);
        drop(state);
        if !identity_matches {
            return false;
        }
        let Ok(Some(terminal)) = registry.terminal_record(&identity.terminal_id) else {
            return false;
        };
        if terminal.incarnation.as_deref() != Some(identity.incarnation.as_str())
            || matches!(
                terminal.lifecycle,
                TerminalLifecycle::Exited | TerminalLifecycle::Tombstoned
            )
        {
            return false;
        }
        if terminal.lifecycle == TerminalLifecycle::Running {
            return true;
        }
        match commit_terminal_lifecycle(
            &mut registry,
            "terminal-ready",
            "terminal-admin-stream-reconnected",
            &identity.terminal_id,
            TerminalLifecycle::Running,
            Some(&identity.incarnation),
            None,
        ) {
            Ok((_, revision)) => {
                self.emit_terminal_registry_changed(&registry, revision);
                true
            }
            Err(error) => {
                self.emit(MuxEvent::Status(format!(
                    "could not persist terminal {} reconnect completion: {error}",
                    identity.terminal_id
                )));
                false
            }
        }
    }

    pub(crate) fn lock_client_sizing_lifecycle(&self) -> MutexGuard<'_, ()> {
        self.client_sizing_lifecycle.lock().unwrap()
    }

    pub fn begin_pairing(
        &self,
        peer: std::net::IpAddr,
    ) -> Result<(PairingChallenge, Receiver<PairingDecision>), PairingError> {
        let result = self.pairing.begin(peer)?;
        self.emit(MuxEvent::PairingRequested(result.0.clone()));
        Ok(result)
    }

    pub fn respond_pairing(&self, id: u64, approve: bool) -> bool {
        let responded = self.pairing.respond(id, approve);
        if responded {
            self.emit(MuxEvent::PairingResolved { request: id });
        }
        responded
    }

    pub(crate) fn resource_resolve_pairing_selected(
        &self,
        selectors: crate::ResourceSelectors,
        pairing_id: &PairingRequestPublicId,
        decision: &str,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let fingerprint = serde_json::json!({
            "operation":"pairing_request.resolve",
            "selectors":selectors,
            "pairing_request_id":pairing_id,
            "decision":decision,
        });
        let mut registry = self.workspace_registry.lock().unwrap();
        if let Some(replay) =
            registry.replay_resource_patch(mutation, "pairing_request.resolve", &fingerprint)?
        {
            return Ok(replay);
        }

        let approve = match decision {
            "accept" => true,
            "reject" => false,
            _ => {
                return Err(anyhow::Error::new(ResourceError::validation_invalid(
                    Some("decision"),
                    "pairing decision must be accept or reject",
                )));
            }
        };
        let payload =
            pairing_id.as_str().strip_prefix("pairing_").expect("typed pairing id prefix");
        let numeric = u128::from_str_radix(payload, 16)
            .ok()
            .and_then(|value| u64::try_from(value).ok())
            .ok_or_else(|| {
                anyhow::Error::new(ResourceError::not_found("pairing_request", pairing_id.as_str()))
            })?;

        let mut session_selectors = selectors;
        session_selectors.pairing_request = None;
        let mut state = self.state.lock().unwrap();
        let resolved = self
            .resolve_resource_path_in_state(
                &state,
                &registry,
                crate::ResourceTarget::Session,
                &session_selectors,
            )
            .map_err(anyhow::Error::new)?;
        let session_id =
            resolved.path.session.context("pairing route omitted its session identity")?;

        let commit = self
            .pairing
            .respond_after(numeric, approve, |challenge| {
                let status = if approve { "accepted" } else { "rejected" };
                let value = serde_json::json!({
                    "pairing_request":{
                        "id":pairing_id,
                        "session_id":session_id,
                        "peer":challenge.peer,
                        "code":challenge.code,
                        "expires_in_seconds":challenge.expires_in.to_string(),
                        "status":status,
                    },
                });
                let deltas = serde_json::json!([{
                    "kind":"delete",
                    "sequence":0,
                    "resource":"pairing_request",
                    "id":pairing_id,
                }]);
                registry.commit_resource_patch(
                    mutation,
                    "pairing_request.resolve",
                    &fingerprint,
                    None,
                    expected_revision,
                    &ResourcePatch { changes: Vec::new() },
                    &value,
                    &deltas,
                )
            })?
            .ok_or_else(|| {
                anyhow::Error::new(ResourceError::not_found("pairing_request", pairing_id.as_str()))
            })?;

        state.resource_revision = commit.revision;
        drop(state);
        drop(registry);
        if !commit.replayed {
            self.publish_resource_event();
            self.emit(MuxEvent::PairingResolved { request: numeric });
        }
        Ok(commit)
    }

    pub fn cancel_pairing(&self, id: u64) {
        if self.pairing.cancel(id) {
            self.emit(MuxEvent::PairingResolved { request: id });
        }
    }

    pub fn authenticate_pairing_credential(&self, credential: &str) -> bool {
        self.pairing.authenticate(credential)
    }

    pub fn pending_pairings(&self) -> Vec<PairingChallenge> {
        self.pairing.pending()
    }

    fn spawn_surface_in_workspace(
        self: &Arc<Self>,
        workspace_key: &str,
        cwd: Option<String>,
        size: Option<(u16, u16)>,
        command: Option<Vec<String>>,
    ) -> anyhow::Result<Arc<Surface>> {
        self.spawn_surface_with(cwd, command, size, Some(workspace_key), None)
    }

    fn spawn_surface_in_workspace_reserved(
        self: &Arc<Self>,
        workspace_key: &str,
        cwd: Option<String>,
        size: Option<(u16, u16)>,
        command: Option<Vec<String>>,
        reservation: TerminalReservationRequest,
    ) -> anyhow::Result<Arc<Surface>> {
        self.spawn_surface_with(cwd, command, size, Some(workspace_key), Some(reservation))
    }

    fn spawn_surface_with(
        self: &Arc<Self>,
        cwd: Option<String>,
        command: Option<Vec<String>>,
        size: Option<(u16, u16)>,
        workspace_key: Option<&str>,
        reservation: Option<TerminalReservationRequest>,
    ) -> anyhow::Result<Arc<Surface>> {
        let mut owner_reservation = self.reserve_surface_owner()?;
        let id = self.next_id();
        let mut opts = self.surface_options.lock().unwrap().clone();
        if cwd.is_some() {
            opts.cwd = cwd;
        }
        if command.is_some() {
            opts.command = command;
        }
        // Spawn at the latest client-owned size: starting at the default
        // 80x24 and resizing a frame later makes shells emit artifacts
        // (e.g. zsh's reverse-video %% partial-line marker).
        let (cols, rows) = self.resolve_client_size(size, (opts.cols, opts.rows));
        opts.cols = cols;
        opts.rows = rows;
        #[cfg(all(test, unix))]
        let use_host_runtime = !self.test_surface_runtime;
        #[cfg(all(not(test), unix))]
        let use_host_runtime = true;
        #[cfg(unix)]
        if let (Some(_), Some(workspace_key), true) =
            (opts.terminal_host_root.as_ref(), workspace_key, use_host_runtime)
        {
            let terminal_id = reservation
                .as_ref()
                .map(|reservation| reservation.terminal_id)
                .map(Ok)
                .unwrap_or_else(TerminalId::random)?;
            let terminal_hex = terminal_id.to_hex();
            let launch_spec = terminal_launch_spec(&opts);
            let terminal = RegistryTerminal {
                terminal_id: terminal_hex.clone(),
                workspace_key: workspace_key.to_string(),
                incarnation: None,
                lifecycle: TerminalLifecycle::Launching,
                launch_spec,
                exit: None,
            };
            let reserve_replayed = {
                let mut registry = self.workspace_registry.lock().unwrap();
                let (replayed, revision) = if let Some(reservation) = reservation.as_ref() {
                    let commit = registry.commit_terminal(
                        &reservation.mutation,
                        &reservation.fingerprint,
                        reservation.expected_generation.as_deref(),
                        reservation.expected_revision,
                        "terminal-reserved",
                        &terminal,
                        &serde_json::json!({
                            "terminal_id":terminal_hex,
                            "workspace_key":workspace_key,
                            "state":"launching",
                        }),
                    )?;
                    (commit.replayed, commit.revision)
                } else {
                    let revision = commit_terminal_transition(
                        &mut registry,
                        "terminal-reserved",
                        "reserve-terminal",
                        &terminal,
                    )?;
                    (false, revision)
                };
                if !replayed {
                    self.emit_terminal_registry_changed(&registry, revision);
                }
                replayed
            };
            if reserve_replayed {
                anyhow::bail!("terminal_create_replayed");
            }
            let surface = match Surface::spawn_with_terminal_id(
                id,
                opts,
                Arc::downgrade(self),
                Some(terminal_id),
            ) {
                Ok(surface) => surface,
                Err(error) => {
                    let _ = self.persist_terminal_exit(
                        &terminal_hex,
                        None,
                        &TerminalExit::unknown(format!("launch-failed: {error}")),
                    );
                    return Err(error);
                }
            };
            let Some(identity) = surface.terminal_host_identity() else {
                self.retire_reserved_surface_runtime(surface, &mut owner_reservation);
                anyhow::bail!("reserved terminal did not return host identity");
            };
            if identity.terminal_id != terminal_hex {
                let _ = self.persist_terminal_exit(
                    &terminal_hex,
                    None,
                    &TerminalExit::unknown("host-identity-mismatch"),
                );
                self.retire_reserved_surface_runtime(surface, &mut owner_reservation);
                anyhow::bail!("terminal host changed registry-reserved identity");
            }
            {
                let mut registry = self.workspace_registry.lock().unwrap();
                let ready = commit_terminal_lifecycle(
                    &mut registry,
                    "terminal-ready",
                    "terminal-ready",
                    &terminal_hex,
                    TerminalLifecycle::Running,
                    Some(&identity.incarnation),
                    None,
                );
                let (_, ready_revision) = match ready {
                    Ok(ready) => ready,
                    Err(error) => {
                        drop(registry);
                        self.retire_reserved_surface_runtime(surface, &mut owner_reservation);
                        return Err(error);
                    }
                };
                self.emit_terminal_registry_changed(&registry, ready_revision);
                let insertion = {
                    let mut state = self.state.lock().unwrap();
                    insert_reserved_surface_checked(
                        self,
                        &mut state,
                        surface.clone(),
                        &mut owner_reservation,
                    )
                };
                if let Err(error) = insertion {
                    drop(registry);
                    let _ = self.persist_terminal_exit(
                        &terminal_hex,
                        Some(&identity.incarnation),
                        &TerminalExit::unknown("surface-insert-failed"),
                    );
                    self.retire_reserved_surface_runtime(surface, &mut owner_reservation);
                    return Err(error);
                }
            }
            // Deprecated recovery mirror only; SQLite is placement authority.
            let _ = surface.persist_host_workspace(workspace_key);
            return Ok(surface);
        }
        if let (Some(workspace_key), Some(reservation)) = (workspace_key, reservation.as_ref()) {
            let terminal_hex = reservation.terminal_id.to_hex();
            let launch_spec = terminal_launch_spec(&opts);
            let terminal = RegistryTerminal {
                terminal_id: terminal_hex.clone(),
                workspace_key: workspace_key.to_string(),
                incarnation: None,
                lifecycle: TerminalLifecycle::Launching,
                launch_spec,
                exit: None,
            };
            {
                let mut registry = self.workspace_registry.lock().unwrap();
                let commit = registry.commit_terminal(
                    &reservation.mutation,
                    &reservation.fingerprint,
                    reservation.expected_generation.as_deref(),
                    reservation.expected_revision,
                    "terminal-reserved",
                    &terminal,
                    &serde_json::json!({
                        "terminal_id":terminal_hex,
                        "workspace_key":workspace_key,
                        "state":"launching",
                    }),
                )?;
                if commit.replayed {
                    anyhow::bail!("terminal_create_replayed");
                }
                self.emit_terminal_registry_changed(&registry, commit.revision);
            }
            #[cfg(test)]
            if let Some(hook) =
                self.terminal_create_after_terminal_reservation.lock().unwrap().clone()
            {
                hook(&terminal_hex);
            }
            #[cfg(test)]
            let surface_result = if self.test_surface_runtime {
                Surface::spawn_for_test(id, opts, Arc::downgrade(self))
            } else {
                Surface::spawn(id, opts, Arc::downgrade(self))
            };
            #[cfg(not(test))]
            let surface_result = Surface::spawn(id, opts, Arc::downgrade(self));
            let surface = match surface_result {
                Ok(surface) => surface,
                Err(error) => {
                    let _ = self.persist_terminal_exit(
                        &terminal_hex,
                        None,
                        &TerminalExit::unknown(format!("launch-failed: {error}")),
                    );
                    return Err(error);
                }
            };
            let incarnation = TerminalId::random()?.to_hex();
            let identity = TerminalHostIdentity {
                terminal_id: terminal_hex.clone(),
                incarnation: incarnation.clone(),
            };
            {
                let mut registry = self.workspace_registry.lock().unwrap();
                let (_, revision) = match commit_terminal_lifecycle(
                    &mut registry,
                    "terminal-ready",
                    "terminal-ready",
                    &terminal_hex,
                    TerminalLifecycle::Running,
                    Some(&incarnation),
                    None,
                ) {
                    Ok(ready) => ready,
                    Err(error) => {
                        drop(registry);
                        self.retire_reserved_surface_runtime(surface, &mut owner_reservation);
                        return Err(error);
                    }
                };
                self.emit_terminal_registry_changed(&registry, revision);
            }
            let insertion = {
                let mut state = self.state.lock().unwrap();
                insert_reserved_surface_checked(
                    self,
                    &mut state,
                    surface.clone(),
                    &mut owner_reservation,
                )
            };
            if let Err(error) = insertion {
                let _ = self.persist_terminal_exit(
                    &terminal_hex,
                    Some(&incarnation),
                    &TerminalExit::unknown("surface-insert-failed"),
                );
                self.retire_reserved_surface_runtime(surface, &mut owner_reservation);
                return Err(error);
            }
            self.reserved_in_process_terminals.lock().unwrap().insert(surface.id, identity);
            return Ok(surface);
        }
        #[cfg(test)]
        let surface_result = if self.test_surface_runtime {
            Surface::spawn_for_test(id, opts, Arc::downgrade(self))
        } else {
            Surface::spawn(id, opts, Arc::downgrade(self))
        };
        #[cfg(not(test))]
        let surface_result = Surface::spawn(id, opts, Arc::downgrade(self));
        let surface = match surface_result {
            Ok(surface) => surface,
            Err(error) => {
                self.pending_workspace_surfaces.lock().unwrap().remove(&id);
                return Err(error);
            }
        };
        let insertion = {
            let mut state = self.state.lock().unwrap();
            insert_reserved_surface_checked(
                self,
                &mut state,
                surface.clone(),
                &mut owner_reservation,
            )
        };
        if let Err(error) = insertion {
            self.pending_workspace_surfaces.lock().unwrap().remove(&id);
            self.retire_reserved_surface_runtime(surface, &mut owner_reservation);
            return Err(error);
        }
        Ok(surface)
    }

    fn spawn_sidebar_plugin_surface(
        self: &Arc<Self>,
        options: &SidebarPluginOptions,
        size: (u16, u16),
    ) -> anyhow::Result<Arc<Surface>> {
        if options.command.is_empty() {
            anyhow::bail!("sidebar plugin command is empty");
        }
        let mut owner_reservation = self.reserve_surface_owner()?;
        let id = self.next_id();
        let mut opts = self.surface_options.lock().unwrap().clone();
        opts.command = Some(options.command.clone());
        opts.cwd = options.cwd.clone();
        opts.cols = size.0.max(1);
        opts.rows = size.1.max(1);
        opts.extra_env.push(("CMUX_SIDEBAR".to_string(), "1".to_string()));
        #[cfg(test)]
        let surface = if self.test_surface_runtime {
            Surface::spawn_for_test_with_resource_identity(id, opts, Arc::downgrade(self), None)?
        } else {
            Surface::spawn_auxiliary(id, opts, Arc::downgrade(self))?
        };
        #[cfg(not(test))]
        let surface = Surface::spawn_auxiliary(id, opts, Arc::downgrade(self))?;
        let insertion = {
            let mut state = self.state.lock().unwrap();
            insert_reserved_surface_checked(
                self,
                &mut state,
                surface.clone(),
                &mut owner_reservation,
            )
        };
        if let Err(error) = insertion {
            self.retire_reserved_surface_runtime(surface, &mut owner_reservation);
            return Err(error);
        }
        Ok(surface)
    }

    fn spawn_browser_surface_with_resource_identity(
        self: &Arc<Self>,
        url: String,
        size: Option<(u16, u16)>,
        pending_workspace: Option<WorkspaceId>,
        resource_identity: Option<TabResourceIdentity>,
    ) -> anyhow::Result<Arc<Surface>> {
        let mut owner_reservation = self.reserve_surface_owner()?;
        let id = self.next_id();
        if let Some(workspace) = pending_workspace {
            self.pending_workspace_surfaces.lock().unwrap().insert(id, workspace);
        }
        let opts = self.surface_options.lock().unwrap().clone();
        let size = self.resolve_client_size(size, (opts.cols, opts.rows));
        let cell_pixels = *self.cell_pixels.lock().unwrap();
        let surface = match resource_identity {
            Some(identity) => browser::new_surface_with_resource_identity(
                id,
                url.clone(),
                size,
                cell_pixels,
                &opts,
                Arc::downgrade(self),
                identity,
            )?,
            None => browser::new_surface(
                id,
                url.clone(),
                size,
                cell_pixels,
                &opts,
                Arc::downgrade(self),
            )?,
        };
        let insertion = {
            let mut state = self.state.lock().unwrap();
            insert_reserved_surface_checked(
                self,
                &mut state,
                surface.clone(),
                &mut owner_reservation,
            )
        };
        if let Err(error) = insertion {
            self.pending_workspace_surfaces.lock().unwrap().remove(&id);
            self.retire_reserved_surface_runtime(surface, &mut owner_reservation);
            return Err(error);
        }
        self.start_browser_bootstrap(surface.clone(), BrowserBootstrap::Create { url }, None);
        Ok(surface)
    }

    fn resolve_client_size(
        &self,
        requested: Option<(u16, u16)>,
        default: (u16, u16),
    ) -> (u16, u16) {
        let mut sizing = self.client_sizing.lock().unwrap();
        if let Some((cols, rows)) = requested {
            let size = clamp_terminal_size(cols, rows);
            sizing.record_explicit_size(size);
            return size;
        }
        let attached_clients = self.control_clients.attached_client_ids_by_surface();
        sizing
            .creation_size(&attached_clients)
            .unwrap_or_else(|| clamp_terminal_size(default.0, default.1))
    }

    /// Record a genuine client-chosen size (protocol resize-surface, sized
    /// creation, or the local TUI sizing a pane) as the default for future
    /// unsized surface creation.
    pub fn record_client_size(&self, cols: u16, rows: u16) -> (u16, u16) {
        let size = clamp_terminal_size(cols, rows);
        self.client_sizing.lock().unwrap().record_explicit_size(size);
        size
    }

    /// Record one viewer's available grid and resize the shared surface to
    /// the smallest rows and columns reported by all current viewers.
    pub fn resize_surface_for_client(
        &self,
        id: SurfaceId,
        client: u64,
        cols: u16,
        rows: u16,
    ) -> anyhow::Result<bool> {
        self.resize_surface_for_client_with_reservation(id, client, cols, rows)
            .map(|(accepted, _)| accepted)
    }

    pub fn resize_surface_for_client_with_reservation(
        &self,
        id: SurfaceId,
        client: u64,
        cols: u16,
        rows: u16,
    ) -> anyhow::Result<(bool, Option<u64>)> {
        let requested = clamp_terminal_size(cols, rows);
        // Serialize the report and its application. Otherwise an older
        // effective size can reach the PTY after a newer shared minimum.
        let mut sizing = self.client_sizing.lock().unwrap();
        let attached_clients = self.control_clients.attached_client_ids_for_surface(id);
        let result = self.resize_surface_for_client_locked(
            &mut sizing,
            Some(&attached_clients),
            id,
            client,
            requested,
            None,
        )?;
        sizing.note_applied_report(
            id,
            client,
            &attached_clients,
            result.1,
            result.2.applied_report_order,
        );
        drop(sizing);
        Ok(result.0)
    }

    pub(crate) fn resize_surface_for_control_client_with_reservation(
        &self,
        id: SurfaceId,
        client: u64,
        cols: u16,
        rows: u16,
    ) -> anyhow::Result<ControlClientResize> {
        self.resize_surface_for_control_client_with_completion(id, client, cols, rows, None)
    }

    pub(crate) fn resize_surface_for_control_client_with_completion(
        &self,
        id: SurfaceId,
        client: u64,
        cols: u16,
        rows: u16,
        completion: Option<SurfaceResizeCompletion>,
    ) -> anyhow::Result<ControlClientResize> {
        let requested = clamp_terminal_size(cols, rows);
        // Keep registration, report insertion, and reducer insertion in one
        // critical section. Disconnect and final stream detach remove their
        // leases through this same sizing lock after dropping the registry lock.
        let mut sizing = self.client_sizing.lock().unwrap();
        let attached = self.control_clients.record_size(client, id, requested.0, requested.1)?;
        let attached_clients = self.control_clients.attached_client_ids_for_surface(id);
        let result = self.resize_surface_for_client_locked(
            &mut sizing,
            Some(&attached_clients),
            id,
            client,
            requested,
            completion,
        );
        if result.is_err()
            && let Some((_, _, _, previous)) = attached.as_ref()
        {
            self.control_clients.restore_size(client, id, *previous);
        }
        let result = result?;
        self.control_clients.set_report_order(client, id, result.2.applied_report_order);
        sizing.note_applied_report(
            id,
            client,
            &attached_clients,
            result.1,
            result.2.applied_report_order,
        );
        drop(sizing);
        Ok(ControlClientResize {
            accepted: result.0.0,
            reservation_id: result.0.1,
            effective_size: result.1,
            attached,
            rollback: result.2,
        })
    }

    fn resize_surface_for_client_locked(
        &self,
        sizing: &mut ClientSizingState,
        attached_clients: Option<&HashSet<u64>>,
        id: SurfaceId,
        client: u64,
        requested: (u16, u16),
        completion: Option<SurfaceResizeCompletion>,
    ) -> anyhow::Result<AppliedClientSize> {
        let previous_geometry = self.surface(id).map(|surface| surface.size());
        if sizing
            .policies
            .get(&id)
            .and_then(|policy| policy.exclusive_client)
            .is_some_and(|exclusive| exclusive != client)
        {
            sizing.policies.entry(id).or_default().excluded_clients.insert(client);
        }
        let report_order = sizing.next_size_order();
        let previous_order = sizing.report_order.insert((id, client), report_order);
        let previous = {
            let viewers = sizing.surfaces.entry(id).or_default();
            viewers.insert(client, requested)
        };
        let use_excluded = sizing.uses_excluded_fallback(id, attached_clients);
        let effective = sizing.effective_size(id, use_excluded);
        let Some(effective) = effective else {
            return Ok((
                (false, None),
                None,
                ClientSizeRollback {
                    previous_size: previous,
                    previous_report_order: previous_order,
                    previous_geometry,
                    applied_report_order: report_order,
                },
            ));
        };
        #[cfg(test)]
        let before_apply = self.client_resize_before_apply.lock().unwrap().clone();
        #[cfg(test)]
        if let Some(hook) = before_apply {
            hook();
        }
        match self.resize_surface_with_completion(id, effective.0, effective.1, completion) {
            Ok(changed) => Ok((
                changed,
                Some(effective),
                ClientSizeRollback {
                    previous_size: previous,
                    previous_report_order: previous_order,
                    previous_geometry,
                    applied_report_order: report_order,
                },
            )),
            Err(error) => {
                if let Some(viewers) = sizing.surfaces.get_mut(&id) {
                    if let Some(previous) = previous {
                        viewers.insert(client, previous);
                    } else {
                        viewers.remove(&client);
                    }
                    if viewers.is_empty() {
                        sizing.surfaces.remove(&id);
                    }
                }
                if let Some(previous_order) = previous_order {
                    sizing.report_order.insert((id, client), previous_order);
                } else {
                    sizing.report_order.remove(&(id, client));
                }
                Err(error)
            }
        }
    }

    pub(crate) fn rollback_surface_size_client(
        &self,
        id: SurfaceId,
        client: u64,
        rollback: ClientSizeRollback,
    ) {
        let lifecycle = self.lock_client_sizing_lifecycle();
        if !self.control_clients.contains(client) {
            return;
        }
        let mut sizing = self.client_sizing.lock().unwrap();
        let current_size =
            sizing.surfaces.get(&id).and_then(|viewers| viewers.get(&client).copied());
        let current_report_order = sizing.report_order.get(&(id, client)).copied();
        if current_report_order != Some(rollback.applied_report_order) {
            return;
        }
        self.control_clients.restore_size_and_report_order(
            client,
            id,
            rollback.previous_size,
            rollback.previous_report_order,
        );
        match rollback.previous_size {
            Some(size) => {
                sizing.surfaces.entry(id).or_default().insert(client, size);
            }
            None => {
                if let Some(viewers) = sizing.surfaces.get_mut(&id) {
                    viewers.remove(&client);
                    if viewers.is_empty() {
                        sizing.surfaces.remove(&id);
                    }
                }
            }
        }
        match rollback.previous_report_order {
            Some(order) => {
                sizing.report_order.insert((id, client), order);
            }
            None => {
                sizing.report_order.remove(&(id, client));
            }
        }
        let attached_clients = self.control_clients.attached_client_ids_for_surface(id);
        let use_excluded = sizing.uses_excluded_fallback(id, Some(&attached_clients));
        let desired_geometry =
            sizing.effective_size(id, use_excluded).or(rollback.previous_geometry);
        let restore =
            desired_geometry.map_or(SurfaceResizeRestore::Complete(true), |(cols, rows)| {
                let (completion, completed) = std::sync::mpsc::sync_channel(1);
                match self.resize_surface_with_completion(id, cols, rows, Some(completion)) {
                    Ok((true, Some(_))) => SurfaceResizeRestore::Pending(completed),
                    Ok((_, _)) => match self.surface(id) {
                        Some(surface) if surface.size() == (cols, rows) => {
                            SurfaceResizeRestore::Complete(true)
                        }
                        Some(surface) => match surface.pending_resize_completion(cols, rows) {
                            Ok(Some(pending)) => SurfaceResizeRestore::Pending(pending.completion),
                            Ok(None) | Err(_) => SurfaceResizeRestore::Complete(false),
                        },
                        None => SurfaceResizeRestore::Complete(false),
                    },
                    Err(_) => SurfaceResizeRestore::Complete(false),
                }
            });
        let rollback_token = sizing.rollback_token(id, Some(&attached_clients));
        drop(sizing);
        drop(lifecycle);

        #[cfg(test)]
        if let Some(hook) = self.client_rollback_before_wait.lock().unwrap().clone() {
            hook();
        }

        let restoration_failed = match restore {
            SurfaceResizeRestore::Complete(restored) => !restored,
            SurfaceResizeRestore::Pending(completion) => {
                match completion.recv_timeout(Duration::from_secs(10)) {
                    Ok(Ok(())) => false,
                    Ok(Err(_)) | Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => true,
                    Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                        // The rolled-back registry remains authoritative while
                        // the compensating browser reservation stays queued.
                        // Do not reinstall the failed attach's claim before the
                        // browser worker reaches a terminal outcome, and do not
                        // retain the connection or another blocking waiter.
                        return;
                    }
                }
            }
        };
        if restoration_failed {
            self.reconcile_failed_surface_size_rollback(
                id,
                client,
                current_size,
                current_report_order,
                rollback_token,
            );
        }
    }

    fn reconcile_failed_surface_size_rollback(
        &self,
        id: SurfaceId,
        client: u64,
        current_size: Option<(u16, u16)>,
        current_report_order: Option<u64>,
        rollback_token: ClientSizingRollbackToken,
    ) {
        let _lifecycle = self.lock_client_sizing_lifecycle();
        if !self.control_clients.contains(client) {
            return;
        }
        let mut sizing = self.client_sizing.lock().unwrap();
        let attached_clients = self.control_clients.attached_client_ids_for_surface(id);
        if sizing.rollback_token(id, Some(&attached_clients)) != rollback_token {
            return;
        }
        // The failed attach already changed the real surface geometry. If
        // restoration fails, retain the pre-rollback report only when no
        // newer sizing mutation superseded this rollback while it was pending.
        self.control_clients.restore_size_and_report_order(
            client,
            id,
            current_size,
            current_report_order,
        );
        match current_size {
            Some(size) => {
                sizing.surfaces.entry(id).or_default().insert(client, size);
            }
            None => {
                if let Some(viewers) = sizing.surfaces.get_mut(&id) {
                    viewers.remove(&client);
                    if viewers.is_empty() {
                        sizing.surfaces.remove(&id);
                    }
                }
            }
        }
        match current_report_order {
            Some(order) => {
                sizing.report_order.insert((id, client), order);
            }
            None => {
                sizing.report_order.remove(&(id, client));
            }
        }
    }

    fn apply_effective_client_size(
        &self,
        sizing: &ClientSizingState,
        surface_id: SurfaceId,
        attached_clients: Option<&HashSet<u64>>,
    ) {
        let use_excluded = sizing.uses_excluded_fallback(surface_id, attached_clients);
        if let Some((cols, rows)) = sizing.effective_size(surface_id, use_excluded) {
            let _ = self.resize_surface(surface_id, cols, rows);
        } else if let Some(surface) = self.surface(surface_id) {
            let _ = surface.release_viewer_size();
        }
    }

    fn apply_effective_client_sizes(
        &self,
        sizing: &ClientSizingState,
        affected: impl IntoIterator<Item = SurfaceId>,
        attached_clients: &HashMap<SurfaceId, HashSet<u64>>,
    ) {
        let mut affected = affected.into_iter().collect::<Vec<_>>();
        affected.sort_unstable();
        affected.dedup();
        for surface_id in affected {
            self.apply_effective_client_size(sizing, surface_id, attached_clients.get(&surface_id));
        }
    }

    pub fn remove_surface_size_client(&self, id: SurfaceId, client: u64) {
        // Removal participates in the same ordering as size reports.
        let mut sizing = self.client_sizing.lock().unwrap();
        let attached_clients = self.control_clients.attached_client_ids_for_surface(id);
        // Final-stream cleanup runs after the registry removes this
        // attachment. Reconstruct the preceding attachment set so an
        // unreported client only triggers geometry when its removal actually
        // changes excluded-report fallback.
        let mut attached_clients_before = attached_clients.clone();
        attached_clients_before.insert(client);
        let fallback_before = sizing.uses_excluded_fallback(id, Some(&attached_clients_before));
        let removed = {
            let removed = sizing
                .surfaces
                .get_mut(&id)
                .is_some_and(|viewers| viewers.remove(&client).is_some());
            if sizing.surfaces.get(&id).is_some_and(HashMap::is_empty) {
                sizing.surfaces.remove(&id);
            }
            removed
        };
        sizing.report_order.remove(&(id, client));
        let fallback_after = sizing.uses_excluded_fallback(id, Some(&attached_clients));
        // A final unreported attachment can be the only thing suppressing
        // this terminal's excluded-report fallback even though it had no
        // visibility lease of its own to remove.
        if !removed && fallback_before == fallback_after {
            return;
        }
        #[cfg(test)]
        let before_apply = self.client_resize_before_apply.lock().unwrap().clone();
        #[cfg(test)]
        if let Some(hook) = before_apply {
            hook();
        }
        self.apply_effective_client_size(&sizing, id, Some(&attached_clients));
        drop(sizing);
    }

    #[cfg(test)]
    pub fn remove_size_client(&self, client: u64) {
        self.remove_size_client_from_attached_surfaces(client, []);
    }

    pub(crate) fn remove_size_client_from_attached_surfaces(
        &self,
        client: u64,
        attached_surfaces: impl IntoIterator<Item = SurfaceId>,
    ) {
        let mut sizing = self.client_sizing.lock().unwrap();
        let attached_clients = self.control_clients.attached_client_ids_by_surface();
        // The registry snapshot no longer contains this client. Reconstruct
        // whether each old attachment suppressed excluded-report fallback so
        // an unsized disconnect only reapplies geometry when that changed.
        let detached_fallbacks = attached_surfaces
            .into_iter()
            .map(|surface| {
                let used_fallback = if sizing.client_participates(surface, client) {
                    false
                } else {
                    sizing.uses_excluded_fallback(surface, attached_clients.get(&surface))
                };
                (surface, used_fallback)
            })
            .collect::<HashMap<_, _>>();
        let mut affected = HashSet::new();
        for (surface, viewers) in &mut sizing.surfaces {
            if viewers.remove(&client).is_some() {
                affected.insert(*surface);
            }
        }
        sizing.surfaces.retain(|_, viewers| !viewers.is_empty());
        sizing.report_order.retain(|(surface, reporter), _| {
            if *reporter != client {
                return true;
            }
            affected.insert(*surface);
            false
        });
        let mut restored_surfaces = HashSet::new();
        for (surface, policy) in &mut sizing.policies {
            let changed = if policy.exclusive_client == Some(client) {
                policy.exclusive_client = None;
                policy.excluded_clients.clear();
                restored_surfaces.insert(*surface);
                true
            } else {
                policy.excluded_clients.remove(&client)
            };
            if changed {
                affected.insert(*surface);
            }
        }
        sizing.policies.retain(|_, policy| {
            policy.exclusive_client.is_some() || !policy.excluded_clients.is_empty()
        });
        for (surface, fallback_before) in detached_fallbacks {
            let fallback_after =
                sizing.uses_excluded_fallback(surface, attached_clients.get(&surface));
            if fallback_before != fallback_after {
                affected.insert(surface);
            }
        }
        let mut changed_clients = HashSet::new();
        for surface in restored_surfaces {
            if let Some(clients) = attached_clients.get(&surface) {
                changed_clients.extend(clients.iter().copied());
            }
            if let Some(reporters) = sizing.surfaces.get(&surface) {
                changed_clients.extend(reporters.keys().copied());
            }
        }
        changed_clients.remove(&client);
        self.apply_effective_client_sizes(&sizing, affected, &attached_clients);
        drop(sizing);
        self.emit_client_sizing_changes(changed_clients);
    }

    pub fn client_surface_size(&self, id: SurfaceId, client: u64) -> Option<(u16, u16)> {
        self.client_sizing
            .lock()
            .unwrap()
            .surfaces
            .get(&id)
            .and_then(|viewers| viewers.get(&client).copied())
    }

    fn emit_client_sizing_changes(&self, clients: impl IntoIterator<Item = u64>) {
        for client in clients {
            let (name, kind) = self.control_clients.client_info(client).unwrap_or((None, None));
            self.emit(MuxEvent::ClientChanged { client, name, kind });
        }
    }

    /// Include or exclude one live client's dimensions from one terminal's
    /// tmux-style shared minimum. Validation, mutation, and disconnect cleanup
    /// share one lifecycle lock so a stale menu action cannot retain a dead ID.
    pub fn set_client_size_participation(
        &self,
        surface: SurfaceId,
        client: u64,
        participating: bool,
    ) -> Option<bool> {
        let _lifecycle = self.lock_client_sizing_lifecycle();
        self.surface(surface)?;
        let mut sizing = self.client_sizing.lock().unwrap();
        let attached_clients = self.control_clients.attached_client_ids_for_surface(surface);
        let mut known_clients = attached_clients.clone();
        if let Some(reporters) = sizing.surfaces.get(&surface) {
            known_clients.extend(reporters.keys().copied());
        }
        if !known_clients.contains(&client) {
            return None;
        }
        if sizing.client_participates(surface, client) == participating {
            return Some(false);
        }
        let policy = sizing.policies.entry(surface).or_default();
        if let Some(exclusive) = policy.exclusive_client.take() {
            policy
                .excluded_clients
                .extend(known_clients.iter().copied().filter(|candidate| *candidate != exclusive));
            policy.excluded_clients.remove(&exclusive);
        }
        if participating {
            policy.excluded_clients.remove(&client);
        } else {
            policy.excluded_clients.insert(client);
        }
        if policy.excluded_clients.is_empty() {
            sizing.policies.remove(&surface);
        }
        self.apply_effective_client_size(&sizing, surface, Some(&attached_clients));
        drop(sizing);
        self.emit_client_sizing_changes([client]);
        Some(true)
    }

    /// Atomically make one client the only sizing participant for one terminal.
    pub fn use_only_client_size(&self, surface: SurfaceId, target: u64) -> Option<bool> {
        let _lifecycle = self.lock_client_sizing_lifecycle();
        self.surface(surface)?;
        let mut sizing = self.client_sizing.lock().unwrap();
        let attached_clients = self.control_clients.attached_client_ids_for_surface(surface);
        let reporters = sizing.surfaces.get(&surface);
        let target_is_reporting = reporters.is_some_and(|viewers| viewers.contains_key(&target));
        if !target_is_reporting {
            return None;
        }
        let mut known_clients = attached_clients.clone();
        if let Some(reporters) = reporters {
            known_clients.extend(reporters.keys().copied());
        }
        let excluded = known_clients
            .iter()
            .copied()
            .filter(|client| *client != target)
            .collect::<HashSet<_>>();
        let policy = sizing.policies.entry(surface).or_default();
        if policy.excluded_clients == excluded && policy.exclusive_client == Some(target) {
            return Some(false);
        }
        policy.excluded_clients = excluded;
        policy.exclusive_client = Some(target);
        self.apply_effective_client_size(&sizing, surface, Some(&attached_clients));
        drop(sizing);
        self.emit_client_sizing_changes(known_clients);
        Some(true)
    }

    /// Atomically restore every connected or reporting client for one terminal.
    pub fn use_all_client_sizes(&self, surface: SurfaceId) -> Option<bool> {
        let _lifecycle = self.lock_client_sizing_lifecycle();
        self.surface(surface)?;
        let mut sizing = self.client_sizing.lock().unwrap();
        let attached_clients = self.control_clients.attached_client_ids_for_surface(surface);
        let Some(_) = sizing.policies.remove(&surface) else {
            return Some(false);
        };
        let mut known_clients = attached_clients.clone();
        if let Some(reporters) = sizing.surfaces.get(&surface) {
            known_clients.extend(reporters.keys().copied());
        }
        self.apply_effective_client_size(&sizing, surface, Some(&attached_clients));
        drop(sizing);
        self.emit_client_sizing_changes(known_clients);
        Some(true)
    }

    pub fn client_size_participates(&self, surface: SurfaceId, client: u64) -> bool {
        self.client_sizing.lock().unwrap().client_participates(surface, client)
    }

    pub fn control_clients_json(&self, requesting_client: u64) -> Value {
        let mut clients = self.control_clients.list_json(requesting_client);
        let sizing = self.client_sizing.lock().unwrap();
        if let Some(clients) = clients.as_array_mut() {
            for info in clients {
                let id = info.get("client").and_then(Value::as_u64).unwrap_or_default();
                if let Some(sizes) = info.get_mut("sizes").and_then(Value::as_array_mut) {
                    for size in sizes {
                        let surface =
                            size.get("surface").and_then(Value::as_u64).unwrap_or_default();
                        size["size_participating"] =
                            serde_json::json!(sizing.client_participates(surface, id));
                    }
                }
            }
        }
        let local_sizes = sizing
            .surfaces
            .iter()
            .filter_map(|(surface, viewers)| {
                viewers.get(&0).map(|(cols, rows)| {
                    serde_json::json!({
                        "surface": surface,
                        "cols": cols,
                        "rows": rows,
                        "size_participating": sizing.client_participates(*surface, 0),
                    })
                })
            })
            .collect::<Vec<_>>();
        if !local_sizes.is_empty()
            && let Some(clients) = clients.as_array_mut()
        {
            clients.insert(
                0,
                serde_json::json!({
                    "client": 0,
                    "transport": "local",
                    "name": "This TUI",
                    "kind": "tui",
                    "connected_seconds": 0,
                    "attached": local_sizes.iter().filter_map(|size| size.get("surface")).cloned().collect::<Vec<_>>(),
                    "sizes": local_sizes,
                    "self": requesting_client == 0,
                }),
            );
        }
        clients
    }

    #[cfg(test)]
    fn set_client_resize_before_apply(&self, hook: Option<Arc<dyn Fn() + Send + Sync>>) {
        *self.client_resize_before_apply.lock().unwrap() = hook;
    }

    #[cfg(test)]
    pub(crate) fn set_client_rollback_before_wait(
        &self,
        hook: Option<Arc<dyn Fn() + Send + Sync>>,
    ) {
        *self.client_rollback_before_wait.lock().unwrap() = hook;
    }

    #[cfg(test)]
    fn set_terminal_move_before_projection(&self, hook: Option<Arc<dyn Fn() + Send + Sync>>) {
        *self.terminal_move_before_projection.lock().unwrap() = hook;
    }

    #[cfg(test)]
    fn set_shutdown_owner_capacity_for_test(&self, capacity: usize) {
        self.shutdown_owner_capacity.store(capacity, Ordering::Release);
    }

    #[cfg(test)]
    fn last_resource_mutation_metrics(&self) -> ResourceMutationMetrics {
        self.resource_mutation_metrics
            .lock()
            .unwrap()
            .expect("resource mutation did not record metrics")
    }

    #[cfg(all(test, unix))]
    pub(crate) fn seed_running_terminal_for_test(
        self: &Arc<Self>,
        terminal_id: &str,
        incarnation: &str,
        workspace_key: &str,
    ) -> anyhow::Result<SurfaceId> {
        let _creation = self.begin_surface_creation()?;
        let mut registry = self.workspace_registry.lock().unwrap();
        commit_terminal_transition(
            &mut registry,
            "terminal-reserved",
            "seed-terminal-reservation",
            &RegistryTerminal {
                terminal_id: terminal_id.to_string(),
                workspace_key: workspace_key.to_string(),
                incarnation: None,
                lifecycle: TerminalLifecycle::Launching,
                launch_spec: serde_json::json!({}),
                exit: None,
            },
        )?;
        commit_terminal_lifecycle(
            &mut registry,
            "terminal-ready",
            "seed-running-terminal",
            terminal_id,
            TerminalLifecycle::Running,
            Some(incarnation),
            None,
        )?;
        let surface = Surface::exited_terminal_placeholder(
            self.next_id(),
            self.surface_options.lock().unwrap().clone(),
            Arc::downgrade(self),
            TerminalHostIdentity {
                terminal_id: terminal_id.to_string(),
                incarnation: incarnation.to_string(),
            },
        )?;
        let mut state = self.state.lock().unwrap();
        insert_surface_checked(self, &mut state, surface.clone())?;
        let (placement, changed) =
            self.project_terminal_to_workspace_in_state(&mut state, terminal_id, workspace_key)?;
        anyhow::ensure!(changed, "seeded terminal did not change topology");
        anyhow::ensure!(
            placement.is_some_and(|placement| placement.surface == surface.id),
            "seeded terminal projection returned the wrong surface"
        );
        drop(state);
        drop(registry);
        self.commit_ordinary_full_resource_projection("test.terminal.seed", serde_json::json!({}))?;
        Ok(surface.id)
    }

    #[cfg(test)]
    pub(crate) fn set_terminal_close_failure_for_test(&self, enabled: bool) -> anyhow::Result<()> {
        self.workspace_registry.lock().unwrap().set_terminal_close_failure(enabled)
    }

    fn browser_runtime(&self) -> anyhow::Result<Arc<BrowserRuntime>> {
        loop {
            let mut state = self.browser_runtime.state.lock().unwrap();
            if self.is_shutting_down() {
                anyhow::bail!("server is shutting down");
            }
            match &*state {
                BrowserRuntimeSlotState::Ready(runtime) if !runtime.is_closed() => {
                    return Ok(runtime.clone());
                }
                BrowserRuntimeSlotState::Ready(_) => {
                    *state = BrowserRuntimeSlotState::Empty;
                }
                BrowserRuntimeSlotState::Empty => {
                    *state = BrowserRuntimeSlotState::Connecting;
                    break;
                }
                BrowserRuntimeSlotState::Connecting => {
                    drop(self.browser_runtime.changed.wait(state).unwrap());
                }
                BrowserRuntimeSlotState::Stopping(_) => {
                    anyhow::bail!("server is shutting down");
                }
            }
        }

        let opts = self.surface_options.lock().unwrap().clone();
        #[cfg(test)]
        if let Some(hook) = self.browser_runtime_connect.lock().unwrap().clone() {
            hook();
        }
        let connected = BrowserRuntime::connect(&opts);
        let mut state = self.browser_runtime.state.lock().unwrap();
        match connected {
            Ok(created)
                if matches!(*state, BrowserRuntimeSlotState::Connecting)
                    && !self.is_shutting_down() =>
            {
                *state = BrowserRuntimeSlotState::Ready(created.clone());
                self.browser_runtime.changed.notify_all();
                Ok(created)
            }
            Ok(created) => {
                self.browser_runtime.changed.notify_all();
                drop(state);
                created.shutdown();
                anyhow::bail!("server is shutting down");
            }
            Err(error) => {
                let stopping = self.is_shutting_down()
                    || matches!(*state, BrowserRuntimeSlotState::Stopping(_));
                if matches!(*state, BrowserRuntimeSlotState::Connecting) {
                    *state = BrowserRuntimeSlotState::Empty;
                }
                self.browser_runtime.changed.notify_all();
                drop(state);
                if stopping {
                    anyhow::bail!("server is shutting down");
                }
                Err(error)
            }
        }
    }

    fn start_browser_bootstrap(
        self: &Arc<Self>,
        surface: Arc<Surface>,
        bootstrap: BrowserBootstrap,
        runtime: Option<Arc<BrowserRuntime>>,
    ) {
        let bootstrap_guard = match self.async_surface_creations.begin() {
            Ok(guard) => guard,
            Err(error) => {
                self.report_browser_bootstrap_failure(&surface, error.to_string());
                return;
            }
        };
        let mux = self.clone();
        let id = surface.id;
        let worker_surface = surface.clone();
        let worker = std::thread::Builder::new()
            .name(format!("browser-surface-{id}-bootstrap"))
            .spawn(move || {
                let _bootstrap_guard = bootstrap_guard;
                #[cfg(test)]
                if let Some(hook) = mux.browser_bootstrap_before_runtime.lock().unwrap().clone() {
                    hook();
                }
                let result = (|| -> anyhow::Result<()> {
                    if mux.is_shutting_down() {
                        anyhow::bail!("server is shutting down");
                    }
                    let runtime = match runtime {
                        Some(runtime) => runtime,
                        None => mux.browser_runtime()?,
                    };
                    if mux.is_shutting_down() {
                        anyhow::bail!("server is shutting down");
                    }
                    runtime.bootstrap_surface_sync(
                        worker_surface.clone(),
                        bootstrap,
                        Arc::downgrade(&mux),
                    )
                })();
                if let Err(err) = result {
                    mux.report_browser_bootstrap_failure(&worker_surface, err.to_string());
                }
            });
        if let Err(error) = worker {
            self.report_browser_bootstrap_failure(&surface, error.to_string());
        }
    }

    fn report_browser_bootstrap_failure(&self, surface: &Arc<Surface>, error: String) {
        if let Surface::Browser(browser) = surface.as_ref() {
            browser.mark_failed(error.clone());
        }
        self.emit(MuxEvent::Status(format!("browser failed: {error}")));
        self.emit(MuxEvent::TitleChanged { surface: surface.id, title: surface.title().into() });
        self.emit(MuxEvent::SurfaceOutput(surface.id));
    }

    /// A fresh single-tab pane wrapping `surface`.
    fn make_pane(&self, surface: SurfaceId) -> anyhow::Result<(PaneId, Pane)> {
        let id = self.next_id();
        let active_at = self.next_active_at();
        Ok((
            id,
            Pane {
                id,
                public_id: PanePublicId::random()?,
                name: None,
                tabs: vec![surface],
                active_tab: 0,
                active_at,
                focused_at: 0,
            },
        ))
    }

    pub fn surface(&self, id: SurfaceId) -> Option<Arc<Surface>> {
        self.state.lock().unwrap().surfaces.get(&id).cloned()
    }

    #[cfg(test)]
    pub(crate) fn remove_surface_runtime_for_test(&self, id: SurfaceId) -> Option<Arc<Surface>> {
        self.state.lock().unwrap().surfaces.remove(&id)
    }

    /// Resolve a process-stable terminal UUID to this daemon generation's
    /// local surface id. This is lookup-only: absence during startup adoption
    /// is retryable and never creates a replacement shell.
    pub fn resolve_terminal(
        &self,
        terminal_id: &str,
    ) -> anyhow::Result<Option<TerminalResolution>> {
        validate_terminal_hex(terminal_id, "invalid_terminal_id")?;
        let (terminal, terminal_revision) = {
            let registry = self.workspace_registry.lock().unwrap();
            let snapshot = registry.terminal_snapshot()?;
            (registry.terminal_record(terminal_id)?, snapshot.revision)
        };
        let Some(terminal) = terminal else {
            return Ok(None);
        };
        let state = self.state.lock().unwrap();
        let surface = unique_terminal_match(
            terminal_id,
            state.surfaces.values().filter_map(|surface| {
                self.resource_terminal_host_identity(surface).map(|identity| (surface.id, identity))
            }),
        )?
        .map(|(surface, _)| surface);
        Ok(Some(TerminalResolution { surface, terminal, terminal_revision }))
    }

    /// Atomically resolve, incarnation-check, and remove a hosted terminal by
    /// process-stable identity. The host is terminated only after the state
    /// lock has made the removal authoritative for this daemon generation.
    pub fn close_terminal(
        &self,
        terminal_id: &str,
        terminal_incarnation: &str,
    ) -> anyhow::Result<TerminalCloseResult> {
        self.close_terminal_with_mutation(
            terminal_id,
            Some(terminal_incarnation),
            None,
            None,
            &WorkspaceMutation::local("cmux-tui"),
        )
    }

    pub fn close_terminal_with_mutation(
        &self,
        terminal_id: &str,
        terminal_incarnation: Option<&str>,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
    ) -> anyhow::Result<TerminalCloseResult> {
        validate_terminal_hex(terminal_id, "invalid_terminal_id")?;
        if let Some(incarnation) = terminal_incarnation {
            validate_terminal_hex(incarnation, "invalid_terminal_incarnation")?;
        }
        let (commit, terminal_incarnation, closed_public_id) = {
            let mut registry = self.workspace_registry.lock().unwrap();
            let public_id = registry.terminal_resource_id(terminal_id)?;
            let commit = registry.close_terminal(
                mutation,
                expected_generation,
                expected_revision,
                terminal_id,
                terminal_incarnation,
            )?;
            let newly_closed =
                !commit.replayed && !commit.result["already_closed"].as_bool().unwrap_or(false);
            if newly_closed {
                self.emit_terminal_registry_changed(&registry, commit.revision);
            }
            let incarnation =
                registry.terminal_record(terminal_id)?.and_then(|terminal| terminal.incarnation);
            (commit, incarnation, newly_closed.then_some(public_id).flatten())
        };
        self.notify_terminal_exit_waiters(closed_public_id);
        let notifications = self.surface_notifications();
        let (target, removed, changed_screens, empty_revision, delta, selection_resync) = {
            let mut state = self.state.lock().unwrap();
            let matched = unique_terminal_match(
                terminal_id,
                state.surfaces.values().filter_map(|surface| {
                    self.resource_terminal_host_identity(surface)
                        .map(|identity| (surface.id, identity))
                }),
            )?;
            if let Some((_, identity)) = matched.as_ref()
                && terminal_incarnation.as_deref() != Some(identity.incarnation.as_str())
            {
                anyhow::bail!("terminal_incarnation_mismatch");
            }
            let target = matched.map(|(surface, _)| surface);
            let selection_before = active_tree_selection(&state);
            let changed_screen = target.and_then(|target| surface_screen_id(&state, target));
            let delta =
                target.and_then(|target| close_surface_delta(&state, &notifications, target));
            let removed = target.and_then(|target| {
                let (removed, split_index_dirty) = remove_surface(self, &mut state, target);
                if split_index_dirty {
                    Self::rebuild_split_screen_index(&mut state);
                }
                removed
            });
            let empty_revision = state.workspaces.is_empty().then_some(state.workspace_revision);
            let selection_resync =
                empty_revision.is_none() && selection_before != active_tree_selection(&state);
            (
                target,
                removed,
                changed_screen.into_iter().collect::<Vec<_>>(),
                empty_revision,
                delta,
                selection_resync,
            )
        };
        if let Some(surface) = removed {
            self.purge_surface_side_tables(surface.id);
            self.retire_surface_runtime(surface);
            if let Some(delta) = delta {
                self.emit_tree_delta(delta, selection_resync);
            } else {
                self.emit(MuxEvent::TreeChanged);
            }
            for screen in changed_screens {
                self.emit(MuxEvent::LayoutChanged(screen));
            }
        }
        self.terminate_discovered_terminal_host(terminal_id, terminal_incarnation.as_deref());
        self.emit_empty_if_current(empty_revision);
        Ok(TerminalCloseResult {
            surface: target,
            terminal_id: terminal_id.to_string(),
            terminal_incarnation,
            already_closed: commit.result["already_closed"].as_bool().unwrap_or(commit.replayed),
            terminal_revision: commit.revision,
        })
    }

    fn tombstone_hosted_surface(&self, surface: &Arc<Surface>) -> anyhow::Result<()> {
        let Some(identity) = self.resource_terminal_host_identity(surface) else {
            return Ok(());
        };
        let mut registry = self.workspace_registry.lock().unwrap();
        let public_id = registry.terminal_resource_id(&identity.terminal_id)?;
        let commit = registry.close_terminal(
            &WorkspaceMutation::local("cmux-tui"),
            None,
            None,
            &identity.terminal_id,
            Some(&identity.incarnation),
        )?;
        let newly_closed =
            !commit.replayed && !commit.result["already_closed"].as_bool().unwrap_or(false);
        if newly_closed {
            self.emit_terminal_registry_changed(&registry, commit.revision);
        }
        drop(registry);
        if newly_closed {
            self.notify_terminal_exit_waiters(public_id);
        }
        Ok(())
    }

    /// A host can become Running before its topology binding is built. Keep
    /// the durable lifecycle transition ahead of in-memory removal so a crash
    /// at any point cannot resurrect an unbound Running terminal on restart.
    fn fail_hosted_terminal_attachment(
        &self,
        surface: &Arc<Surface>,
        _operation: &str,
        reason: &str,
    ) -> anyhow::Result<()> {
        let Some(identity) = self.resource_terminal_host_identity(surface) else {
            let removed = {
                let mut state = self.state.lock().unwrap();
                take_surface_for_retirement(self, &mut state, surface.id)
            };
            if let Some(removed) = removed {
                self.retire_surface_runtime(removed);
            }
            return Ok(());
        };
        self.persist_terminal_exit(
            &identity.terminal_id,
            Some(&identity.incarnation),
            &TerminalExit::unknown(reason),
        )?;
        let removed = {
            let mut state = self.state.lock().unwrap();
            let (removed, split_index_dirty) = remove_surface(self, &mut state, surface.id);
            if split_index_dirty {
                Self::rebuild_split_screen_index(&mut state);
            }
            removed.or_else(|| take_surface_for_retirement(self, &mut state, surface.id))
        };
        if let Some(removed) = removed {
            self.purge_surface_side_tables(surface.id);
            self.retire_surface_runtime(removed);
        }
        Ok(())
    }

    fn terminate_discovered_terminal_host(&self, terminal_id: &str, incarnation: Option<&str>) {
        self.terminate_discovered_terminal_hosts(&[(
            terminal_id.to_string(),
            incarnation.map(str::to_string),
        )]);
    }

    fn terminate_discovered_terminal_hosts(&self, terminals: &[(String, Option<String>)]) {
        if terminals.is_empty() {
            return;
        }
        #[cfg(test)]
        self.discovered_terminal_termination_requests
            .lock()
            .unwrap()
            .extend(terminals.iter().cloned());
        #[cfg(unix)]
        {
            let root = self.surface_options.lock().unwrap().terminal_host_root.clone();
            let Some(root) = root else { return };
            let Ok(records) = crate::terminal_host_runtime::load_terminal_host_records(&root)
            else {
                return;
            };
            let targets = terminals
                .iter()
                .map(|(terminal_id, incarnation)| (terminal_id.as_str(), incarnation.as_deref()))
                .collect::<HashMap<_, _>>();
            for (path, record) in records {
                let Some(expected_incarnation) = targets.get(record.terminal_id.as_str()) else {
                    continue;
                };
                if match *expected_incarnation {
                    Some(expected) => record.incarnation == expected,
                    None => true,
                } {
                    terminate_host_record(record, path);
                }
            }
        }
        #[cfg(not(unix))]
        let _ = terminals;
    }

    #[cfg(test)]
    pub(crate) fn take_discovered_terminal_termination_requests_for_test(
        &self,
    ) -> Vec<(String, Option<String>)> {
        std::mem::take(&mut *self.discovered_terminal_termination_requests.lock().unwrap())
    }

    fn terminate_tombstoned_workspace_hosts(&self, workspace_key: &str) {
        #[cfg(unix)]
        {
            let root = self.surface_options.lock().unwrap().terminal_host_root.clone();
            let Some(root) = root else { return };
            let Ok(records) = crate::terminal_host_runtime::load_terminal_host_records(&root)
            else {
                return;
            };
            for (path, record) in records {
                let terminal = self
                    .workspace_registry
                    .lock()
                    .unwrap()
                    .terminal_record(&record.terminal_id)
                    .ok()
                    .flatten();
                if terminal.as_ref().is_some_and(|terminal| {
                    terminal.workspace_key == workspace_key
                        && terminal.lifecycle == TerminalLifecycle::Tombstoned
                        && terminal
                            .incarnation
                            .as_deref()
                            .is_none_or(|expected| expected == record.incarnation)
                }) {
                    terminate_host_record(record, path);
                }
            }
        }
        #[cfg(not(unix))]
        let _ = workspace_key;
    }

    /// Run `f` with the session state.
    ///
    /// The state lock is held for the duration of `f`; do not call back
    /// into `Mux` methods that take it (`surface()`, `close_pane()`, ...).
    pub fn with_state<R>(&self, f: impl FnOnce(&State) -> R) -> R {
        f(&self.state.lock().unwrap())
    }

    pub fn surface_count(&self) -> usize {
        self.state.lock().unwrap().surfaces.len()
    }

    pub fn surface_notification(&self, surface: SurfaceId) -> Option<SurfaceNotification> {
        self.surface_notifications.lock().unwrap().get(&surface).copied()
    }

    pub fn surface_notifications(&self) -> HashMap<SurfaceId, SurfaceNotification> {
        self.surface_notifications.lock().unwrap().clone()
    }

    pub fn clear_surface_notification(&self, surface: SurfaceId) -> bool {
        let cleared = self.surface_notifications.lock().unwrap().remove(&surface).is_some();
        if cleared {
            self.emit(MuxEvent::TreeChanged);
        }
        cleared
    }

    fn active_surface_in_state(state: &State) -> Option<SurfaceId> {
        let pane = state.active_pane()?;
        state.panes.get(&pane)?.active_surface()
    }

    pub fn active_surface(&self) -> Option<SurfaceId> {
        self.with_state(Self::active_surface_in_state)
    }

    fn clear_viewed_notification(&self, surface: Option<SurfaceId>) {
        if let Some(surface) = surface {
            let _ = self.surface_notifications.lock().unwrap().remove(&surface);
        }
    }

    pub fn post_notification(
        &self,
        title: String,
        body: String,
        level: NotificationLevel,
        surface: Option<SurfaceId>,
    ) -> anyhow::Result<u64> {
        let public_id = NotificationPublicId::random()?;
        let terminal_id = surface.and_then(|surface| {
            self.state.lock().unwrap().resource_indexes.content_ids.get(&surface).and_then(
                |content| match content {
                    ContentPublicId::Terminal(id) => Some(id.clone()),
                    ContentPublicId::Browser(_) => None,
                },
            )
        });
        Ok(self.post_resource_notification(
            public_id,
            title,
            body,
            level,
            surface,
            terminal_id,
            now_ms(),
        ))
    }

    #[allow(clippy::too_many_arguments)]
    pub(crate) fn post_resource_notification(
        &self,
        public_id: NotificationPublicId,
        title: String,
        body: String,
        level: NotificationLevel,
        surface: Option<SurfaceId>,
        terminal_id: Option<TerminalPublicId>,
        created_at_ms: u64,
    ) -> u64 {
        let id = self.next_notification_id();
        {
            const NOTIFICATION_LEDGER_CAPACITY: usize = 256;
            let mut ledger = self.notification_ledger.lock().unwrap();
            ledger.push_back(ResourceNotification {
                id: public_id,
                title: title.clone(),
                body: body.clone(),
                level,
                terminal_id,
                created_at_ms,
                surface,
            });
            while ledger.len() > NOTIFICATION_LEDGER_CAPACITY {
                ledger.pop_front();
            }
        }
        let mut unread_changed = false;
        if let Some(surface) = surface
            && self.active_surface() != Some(surface)
        {
            self.surface_notifications
                .lock()
                .unwrap()
                .insert(surface, SurfaceNotification { notification: id, level, unread: true });
            unread_changed = true;
        }
        self.emit(MuxEvent::Notification(NotificationEvent {
            notification: id,
            title,
            body,
            level,
            surface,
        }));
        if unread_changed {
            self.emit(MuxEvent::TreeChanged);
        }
        id
    }

    pub fn resource_notifications(&self, limit: usize) -> Vec<ResourceNotification> {
        self.notification_ledger
            .lock()
            .unwrap()
            .iter()
            .rev()
            .take(limit.min(256))
            .cloned()
            .collect()
    }

    pub fn report_agent(
        &self,
        surface: SurfaceId,
        state: AgentState,
        source: AgentSource,
        session: Option<String>,
    ) -> anyhow::Result<AgentRecord> {
        let mutation = WorkspaceMutation::new(
            format!("raw-agent-{}", crate::workspace_registry::new_uuid_v4()),
            "raw-control",
        )?;
        let fingerprint = serde_json::json!({
            "operation":"agent.report",
            "surface":surface,
            "state":state.as_str(),
            "source":source.as_str(),
            "source_session":session,
        });
        let (_, record) = self.commit_agent_report(
            AgentReportTarget::Surface(surface),
            state,
            source,
            session,
            None,
            &mutation,
            &fingerprint,
        )?;
        record.context("fresh raw agent report unexpectedly replayed")
    }

    #[allow(clippy::too_many_arguments)]
    pub(crate) fn resource_report_agent_selected(
        &self,
        selectors: crate::ResourceSelectors,
        terminal_id: &TerminalPublicId,
        agent_state: AgentState,
        source: AgentSource,
        source_session: Option<String>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let fingerprint = serde_json::json!({
            "operation":"agent.report",
            "selectors":selectors,
            "terminal_id":terminal_id,
            "state":agent_state.as_str(),
            "source":source.as_str(),
            "source_session":source_session,
        });
        self.commit_agent_report(
            AgentReportTarget::Resource { selectors: &selectors, terminal_id },
            agent_state,
            source,
            source_session,
            expected_revision,
            mutation,
            &fingerprint,
        )
        .map(|(commit, _)| commit)
    }

    #[allow(clippy::too_many_arguments)]
    fn commit_agent_report(
        &self,
        target: AgentReportTarget<'_>,
        agent_state: AgentState,
        source: AgentSource,
        source_session: Option<String>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
    ) -> anyhow::Result<(ResourcePatchCommit, Option<AgentRecord>)> {
        let mut registry = self.workspace_registry.lock().unwrap();
        if let Some(replay) =
            registry.replay_resource_patch(mutation, "agent.report", fingerprint)?
        {
            return Ok((replay, None));
        }
        let mut state = self.state.lock().unwrap();
        let (surface, terminal_id) = match target {
            AgentReportTarget::Surface(surface) => {
                let runtime = state
                    .surfaces
                    .get(&surface)
                    .with_context(|| format!("unknown surface {surface}"))?;
                let identity = runtime.resource_identity().with_context(|| {
                    format!("surface {surface} has no durable resource identity")
                })?;
                let ContentPublicId::Terminal(terminal_id) = &identity.content_id else {
                    anyhow::bail!("surface {surface} is not a terminal");
                };
                (surface, terminal_id.clone())
            }
            AgentReportTarget::Resource { selectors, terminal_id } => {
                self.resolve_resource_path_in_state(
                    &state,
                    &registry,
                    crate::ResourceTarget::Session,
                    selectors,
                )
                .map_err(anyhow::Error::new)?;
                let surface = state
                    .resource_indexes
                    .content
                    .get(&ContentPublicId::Terminal((*terminal_id).clone()))
                    .copied()
                    .with_context(|| format!("unknown terminal {terminal_id}"))?;
                (surface, (*terminal_id).clone())
            }
        };
        let now = now_ms();
        let mut records = self.agent_records.lock().unwrap();
        let record = match records.get(&surface) {
            Some(existing)
                if existing.source == AgentSource::Hook && source == AgentSource::Socket =>
            {
                existing.clone()
            }
            _ => AgentRecord {
                surface,
                state: agent_state,
                source,
                session: source_session,
                updated_at_ms: now,
            },
        };
        let digest = Sha256::digest(format!("cmux.protocol/1/agent/{terminal_id}").as_bytes());
        let payload = digest[..16].iter().map(|byte| format!("{byte:02x}")).collect::<String>();
        let agent_id =
            AgentPublicId::parse(format!("agent_{payload}")).map_err(anyhow::Error::new)?;
        let session_id = registry.session_id().clone();
        let value = serde_json::json!({
            "id":agent_id,
            "session_id":session_id,
            "terminal_id":terminal_id,
            "state":record.state.as_str(),
            "source":record.source.as_str(),
            "updated_at_ms":record.updated_at_ms.to_string(),
            "source_session":record.session,
        });
        let deltas = serde_json::json!([{
            "kind":"upsert",
            "sequence":0,
            "resource":"agent",
            "id":agent_id,
            "value":value,
        }]);
        let commit = registry.commit_agent_projection(
            mutation,
            fingerprint,
            expected_revision,
            &terminal_id,
            &value,
            &deltas,
        )?;
        state.resource_revision = commit.revision;
        if !commit.replayed {
            records.insert(surface, record.clone());
        }
        drop(records);
        drop(state);
        drop(registry);
        if !commit.replayed {
            self.publish_resource_event();
        }
        Ok((commit, Some(record)))
    }

    /// Drop per-surface metadata for a surface that has left the tree.
    /// `SurfaceId` is monotonic, so without this every closed tab would
    /// leak an entry forever and `list-agents` would keep reporting dead
    /// surfaces as live agents.
    fn purge_surface_side_tables(&self, surface: SurfaceId) {
        self.agent_records.lock().unwrap().remove(&surface);
        self.surface_notifications.lock().unwrap().remove(&surface);
        self.reserved_in_process_terminals.lock().unwrap().remove(&surface);
        let _lifecycle = self.lock_client_sizing_lifecycle();
        let mut sizing = self.client_sizing.lock().unwrap();
        sizing.surfaces.remove(&surface);
        sizing.report_order.retain(|(reported_surface, _), _| *reported_surface != surface);
        sizing.policies.remove(&surface);
    }

    /// Finish removed runtimes outside the topology lock. One shared deadline
    /// bounds an entire pane/workspace close, and failures retain only the
    /// minimal process/target owner needed for a later retry.
    fn retire_surface_runtime(&self, surface: Arc<Surface>) {
        self.retire_surface_runtimes([surface]);
    }

    /// Transfer an uninserted runtime from its admission reservation into the
    /// retry ledger without opening a capacity-accounting gap.
    fn retire_reserved_surface_runtime(
        &self,
        surface: Arc<Surface>,
        reservation: &mut SurfaceOwnerReservation<'_>,
    ) {
        let owner = {
            let _state = self.state.lock().unwrap();
            let owner = self.shutdown_owners.stage_surface(&surface);
            reservation.release();
            owner
        };
        let Some(owner) = owner else { return };
        let deadline = Instant::now() + SHUTDOWN_TERMINATION_TIMEOUT;
        let Ok(_coordinator) = self.lock_shutdown_coordinator_until(deadline) else {
            self.shutdown_owner_reconciler.schedule();
            return;
        };
        if self.terminate_shutdown_owners_until(vec![owner], deadline) {
            self.shutdown_owner_reconciler.schedule();
        }
    }

    fn retire_surface_runtimes(&self, surfaces: impl IntoIterator<Item = Arc<Surface>>) {
        let owners = surfaces
            .into_iter()
            .filter_map(|surface| self.shutdown_owners.stage_surface(&surface))
            .collect::<Vec<_>>();
        let deadline = Instant::now() + SHUTDOWN_TERMINATION_TIMEOUT;
        let Ok(_coordinator) = self.lock_shutdown_coordinator_until(deadline) else {
            self.shutdown_owner_reconciler.schedule();
            return;
        };
        if self.terminate_shutdown_owners_until(owners, deadline) {
            self.shutdown_owner_reconciler.schedule();
        }
    }

    fn terminate_staged_shutdown_owners_until(&self, deadline: Instant) -> bool {
        let owners = self.shutdown_owners.snapshot();
        self.terminate_shutdown_owners_until(owners, deadline)
    }

    fn terminate_shutdown_owners_until(
        &self,
        owners: Vec<(ShutdownOwnerKey, Arc<SurfaceShutdownOwner>)>,
        deadline: Instant,
    ) -> bool {
        if owners.is_empty() {
            return false;
        }
        #[cfg(unix)]
        let process_snapshot = crate::process_session::SessionProcessSnapshot::capture(
            owners.iter().filter_map(|(_, owner)| owner.local_process_session()),
            deadline,
        )
        .ok();
        let mut single_work = Vec::new();
        let mut browser_batches = HashMap::<
            *const BrowserRuntime,
            (Arc<BrowserRuntime>, Vec<(ShutdownOwnerKey, Arc<SurfaceShutdownOwner>)>),
        >::new();
        for (key, owner) in &owners {
            if let Some(runtime) = owner.browser_runtime() {
                browser_batches
                    .entry(Arc::as_ptr(runtime))
                    .or_insert_with(|| (runtime.clone(), Vec::new()))
                    .1
                    .push((key.clone(), owner.clone()));
            } else {
                single_work.push(ShutdownOwnerWork::Single((key.clone(), owner.clone())));
            }
        }
        // Start each high-fan-in browser batch before individual process work,
        // so a saturated fanout cannot strand every target behind the deadline.
        let mut work = browser_batches
            .into_values()
            .map(|(runtime, owners)| ShutdownOwnerWork::BrowserBatch { runtime, owners })
            .collect::<Vec<_>>();
        work.extend(single_work);

        let failed = Mutex::new(HashSet::new());
        let started = bounded_shutdown_fanout(&work, deadline, |work, deadline| match work {
            ShutdownOwnerWork::Single((key, owner)) => {
                #[cfg(unix)]
                let terminated =
                    owner.terminate_until_in_batch(deadline, process_snapshot.as_ref());
                #[cfg(not(unix))]
                let terminated = owner.terminate_until(deadline);
                if !terminated {
                    failed.lock().unwrap().insert(key.clone());
                }
            }
            ShutdownOwnerWork::BrowserBatch { runtime, owners } => {
                let browser_owners = owners
                    .iter()
                    .map(|(_, owner)| {
                        owner.browser_shutdown_owner().expect("browser batch has browser owners")
                    })
                    .collect::<Vec<_>>();
                let outcomes = runtime.close_owners_for_shutdown(&browser_owners, deadline);
                let mut failed = failed.lock().unwrap();
                for (index, (key, _)) in owners.iter().enumerate() {
                    if !outcomes.get(index).copied().unwrap_or(false) {
                        failed.insert(key.clone());
                    }
                }
            }
        });
        let mut failed = failed.into_inner().unwrap();
        for work in &work[started..] {
            work.record_failed_keys(&mut failed);
        }
        let confirmed =
            owners.into_iter().filter(|(key, _)| !failed.contains(key)).collect::<Vec<_>>();
        self.shutdown_owners.remove_confirmed(&confirmed);
        !failed.is_empty()
    }

    pub fn list_agents(
        &self,
        surface: Option<SurfaceId>,
        state: Option<AgentState>,
    ) -> Vec<AgentRecord> {
        let mut records = self.agent_records.lock().unwrap().values().cloned().collect::<Vec<_>>();
        records.sort_by_key(|record| record.surface);
        records
            .into_iter()
            .filter(|record| surface.is_none_or(|surface| record.surface == surface))
            .filter(|record| state.is_none_or(|state| record.state == state))
            .collect()
    }

    fn shutdown_browser_runtimes_until(&self, deadline: Instant) -> bool {
        let retained = self.shutdown_owners.snapshot();
        let current_browser_runtime = self.browser_runtime.take_for_shutdown();
        let mut browser_runtimes = Vec::new();
        for runtime in retained.iter().filter_map(|(_, owner)| owner.browser_runtime()) {
            if !browser_runtimes.iter().any(|candidate| Arc::ptr_eq(candidate, runtime)) {
                browser_runtimes.push(runtime.clone());
            }
        }
        if let Some(runtime) = &current_browser_runtime
            && !browser_runtimes.iter().any(|candidate| Arc::ptr_eq(candidate, runtime))
        {
            browser_runtimes.push(runtime.clone());
        }

        let mut failed = false;
        for runtime in browser_runtimes {
            let is_current = current_browser_runtime
                .as_ref()
                .is_some_and(|current| Arc::ptr_eq(current, &runtime));
            let surface_failed = retained.iter().any(|(_, owner)| {
                owner
                    .browser_runtime()
                    .is_some_and(|owner_runtime| Arc::ptr_eq(owner_runtime, &runtime))
            });
            if surface_failed && runtime.source() == BrowserSource::External {
                if is_current {
                    self.browser_runtime.restore_for_shutdown(runtime);
                }
                continue;
            }
            if runtime.shutdown_until(deadline) {
                if runtime.source() == BrowserSource::Launched {
                    self.shutdown_owners.remove_browser_runtime(&runtime);
                }
            } else {
                failed = true;
                if is_current {
                    self.browser_runtime.restore_for_shutdown(runtime);
                }
            }
        }
        failed
    }

    fn shutdown_once_until(&self, deadline: Instant) -> anyhow::Result<()> {
        self.shutting_down.store(true, Ordering::Release);
        self.browser_runtime.stop();
        #[cfg(unix)]
        self.request_terminal_adoption_stop();
        #[cfg(unix)]
        crate::process_session::require_stable_process_signaling_until(deadline)
            .context("preflight process control for daemon exit")?;
        let _coordinator = self.lock_shutdown_coordinator_until(deadline)?;
        if !self.surface_creations.stop_and_wait_until(deadline) {
            anyhow::bail!("surface creation remains active at the daemon exit deadline");
        }
        if !self.async_surface_creations.stop_and_wait_until(deadline) {
            anyhow::bail!("browser bootstrap remains active at the daemon exit deadline");
        }
        #[cfg(unix)]
        if !self.wait_for_terminal_adoption_workers_until(deadline) {
            anyhow::bail!("terminal adoption remains active at the daemon exit deadline");
        }
        let surfaces = self.state.lock().unwrap().surfaces.values().cloned().collect::<Vec<_>>();
        for surface in &surfaces {
            match surface.shutdown_owner_identity() {
                Some(SurfaceShutdownOwnerIdentity::Surface) => {
                    anyhow::ensure!(
                        self.shutdown_owners.stage_surface(surface).is_some(),
                        "surface {} lost its shutdown owner during daemon exit",
                        surface.id
                    );
                }
                #[cfg(unix)]
                Some(SurfaceShutdownOwnerIdentity::Hosted { .. }) | None => {}
                #[cfg(not(unix))]
                None => {}
            }
        }
        for surface in &surfaces {
            surface.disconnect_for_daemon_shutdown();
        }
        self.terminate_staged_shutdown_owners_until(deadline);
        let browser_runtime_failed = self.shutdown_browser_runtimes_until(deadline);
        let retained = self.shutdown_owners.len();
        if retained != 0 || browser_runtime_failed {
            anyhow::bail!(
                "daemon exit retained {retained} surface owner(s); browser runtime failure: \
                 {browser_runtime_failed}"
            );
        }
        Ok(())
    }

    /// Finish every fallible cleanup phase before allowing the server process
    /// to release its socket. Retried work keeps exact ownership, while one
    /// absolute deadline guarantees an accepted daemon handoff cannot wedge
    /// the old process or its socket forever.
    pub fn shutdown(&self) -> anyhow::Result<()> {
        self.shutdown_owner_reconciler.stop();
        let overall_deadline = Instant::now() + self.shutdown_total_timeout();
        let mut retry_delay = SERVER_EXIT_RETRY_INITIAL_DELAY;
        let mut last_error = None;
        loop {
            let now = Instant::now();
            if now >= overall_deadline {
                break;
            }
            let attempt_deadline = (now + self.shutdown_attempt_timeout()).min(overall_deadline);
            match self.shutdown_once_until(attempt_deadline) {
                Ok(()) => return Ok(()),
                Err(error) => last_error = Some(error),
            }
            let Some(remaining) = overall_deadline.checked_duration_since(Instant::now()) else {
                break;
            };
            std::thread::sleep(retry_delay.min(remaining));
            retry_delay = retry_delay.saturating_mul(2).min(SERVER_EXIT_RETRY_MAX_DELAY);
        }
        let error =
            last_error.unwrap_or_else(|| anyhow::anyhow!("daemon cleanup deadline expired"));
        Err(error.context("daemon cleanup did not finish before the process exit deadline"))
    }

    fn shutdown_attempt_timeout(&self) -> Duration {
        #[cfg(test)]
        if let Some(timeout) = *self.shutdown_attempt_timeout.lock().unwrap() {
            return timeout;
        }
        crate::server::SERVER_SHUTDOWN_TIMEOUT
    }

    fn shutdown_total_timeout(&self) -> Duration {
        #[cfg(test)]
        if let Some(timeout) = *self.shutdown_attempt_timeout.lock().unwrap() {
            return timeout.saturating_mul(SERVER_EXIT_TEST_ATTEMPT_BUDGET);
        }
        crate::server::SERVER_SHUTDOWN_TIMEOUT
    }

    #[cfg(test)]
    fn set_shutdown_attempt_timeout_for_test(&self, timeout: Duration) {
        *self.shutdown_attempt_timeout.lock().unwrap() = Some(timeout);
    }

    pub fn request_shutdown(&self) {
        self.shutdown_requested.store(true, Ordering::Release);
        let watchers = {
            let mut watchers = self.shutdown_request_watchers.lock().unwrap();
            watchers.drain(..).filter_map(|watcher| watcher.upgrade()).collect::<Vec<_>>()
        };
        for watcher in watchers {
            ShutdownRequestWatch { inner: watcher }.request();
        }
    }

    pub fn shutdown_requested(&self) -> bool {
        self.shutdown_requested.load(Ordering::Acquire)
    }

    pub fn watch_shutdown_request(&self) -> ShutdownRequestWatch {
        let inner = Arc::new(ShutdownRequestWatchInner::default());
        let watch = ShutdownRequestWatch { inner: inner.clone() };
        let mut watchers = self.shutdown_request_watchers.lock().unwrap();
        watchers.retain(|watcher| watcher.strong_count() != 0);
        if self.shutdown_requested.load(Ordering::Acquire) {
            watch.request();
        } else {
            watchers.push(Arc::downgrade(&inner));
        }
        watch
    }

    /// Observe the next shutdown request, even after the server has already
    /// accepted an earlier request. Degraded process cleanup uses this to
    /// require explicit operator intent before each bounded retry.
    pub fn watch_next_shutdown_request(&self) -> ShutdownRequestWatch {
        let inner = Arc::new(ShutdownRequestWatchInner::default());
        let watch = ShutdownRequestWatch { inner: inner.clone() };
        let mut watchers = self.shutdown_request_watchers.lock().unwrap();
        watchers.retain(|watcher| watcher.strong_count() != 0);
        watchers.push(Arc::downgrade(&inner));
        watch
    }

    pub(crate) fn shutdown_cleanup_health(&self) -> ShutdownCleanupHealth {
        let pending = self.shutdown_owners.len();
        let state = self.shutdown_owner_reconciler.state.lock().unwrap();
        ShutdownCleanupHealth {
            pending,
            retrying: pending != 0 && state.worker_started && !state.degraded,
            degraded: pending != 0 && (state.degraded || !state.worker_started),
        }
    }

    /// Permanently fence new surface creation, tombstone every durable
    /// terminal in one transaction, detach the complete topology in one
    /// state mutation, and terminate each runtime before acknowledging the
    /// shutdown request. A failed durable commit leaves topology untouched;
    /// a failed runtime termination keeps process ownership and the fence
    /// closed so a retry cannot race a new PTY into the session.
    pub fn close_all_surfaces_for_shutdown(&self) -> anyhow::Result<usize> {
        let deadline = Instant::now() + crate::server::SERVER_SHUTDOWN_TIMEOUT;
        self.close_all_surfaces_for_shutdown_until(deadline)
    }

    fn close_all_surfaces_for_shutdown_until(&self, deadline: Instant) -> anyhow::Result<usize> {
        #[cfg(unix)]
        crate::process_session::require_stable_process_signaling_until(deadline)
            .context("preflight process control for server shutdown")?;
        let _coordinator = self.lock_shutdown_coordinator_until(deadline)?;
        self.shutting_down.store(true, Ordering::Release);
        self.browser_runtime.stop();
        #[cfg(unix)]
        self.request_terminal_adoption_stop();
        if !self.surface_creations.stop_and_wait_until(deadline) {
            anyhow::bail!("surface creation did not stop before the shutdown deadline");
        }
        if !self.async_surface_creations.stop_and_wait_until(deadline) {
            anyhow::bail!("browser bootstrap did not stop before the shutdown deadline");
        }
        #[cfg(unix)]
        if !self.wait_for_terminal_adoption_workers_until(deadline) {
            anyhow::bail!("terminal adoption did not stop before the shutdown deadline");
        }

        #[cfg(unix)]
        let terminal_host_records = {
            let root = self.surface_options.lock().unwrap().terminal_host_root.clone();
            let capacity = self.shutdown_owner_capacity();
            let (required, surface_owner_keys) = {
                let state = self.state.lock().unwrap();
                let required = state
                    .surfaces
                    .values()
                    .filter(|surface| !surface.is_dead())
                    .filter_map(|surface| surface.terminal_host_identity())
                    .collect::<Vec<_>>();
                let surface_owner_keys = state
                    .surfaces
                    .values()
                    .filter_map(|surface| match surface.shutdown_owner_identity()? {
                        SurfaceShutdownOwnerIdentity::Surface => {
                            Some(ShutdownOwnerKey::Surface(surface.id))
                        }
                        SurfaceShutdownOwnerIdentity::Hosted { terminal_id, incarnation } => {
                            Some(ShutdownOwnerKey::Hosted { terminal_id, incarnation })
                        }
                    })
                    .collect::<Vec<_>>();
                (required, surface_owner_keys)
            };
            let mut owner_keys = self
                .shutdown_owners
                .snapshot()
                .into_iter()
                .map(|(key, _)| key)
                .collect::<HashSet<_>>();
            owner_keys.extend(surface_owner_keys);
            let records = match root {
                Some(root) => {
                    let records = self
                        .load_terminal_host_records_for_shutdown(root, capacity, deadline)
                        .context("load terminal hosts for server shutdown")?;
                    let available = records
                        .iter()
                        .map(|(_, record)| {
                            (record.terminal_id.as_str(), record.incarnation.as_str())
                        })
                        .collect::<HashSet<_>>();
                    for identity in required {
                        if !available.contains(&(
                            identity.terminal_id.as_str(),
                            identity.incarnation.as_str(),
                        )) {
                            anyhow::bail!(
                                "load terminal hosts for server shutdown: missing record for {}:{}",
                                identity.terminal_id,
                                identity.incarnation
                            );
                        }
                    }
                    records
                }
                None if required.is_empty() => Vec::new(),
                None => anyhow::bail!(
                    "load terminal hosts for server shutdown: terminal-host root is unavailable"
                ),
            };
            owner_keys.extend(records.iter().map(|(_, record)| ShutdownOwnerKey::Hosted {
                terminal_id: record.terminal_id.clone(),
                incarnation: record.incarnation.clone(),
            }));
            if owner_keys.len() > capacity {
                anyhow::bail!(
                    "load terminal hosts for server shutdown: shutdown owner capacity \
                     {capacity} cannot retain {} unique owners",
                    owner_keys.len()
                );
            }
            records
        };

        let (surfaces, retained_count, tree_changed, closed_public_ids) = {
            let mutation = WorkspaceMutation::local("cmux-tui-shutdown");
            let operation = "server.stop";
            let fingerprint = serde_json::json!({"operation":operation});
            let mut registry = self.workspace_registry.lock().unwrap();
            let terminal_snapshot = registry.terminal_snapshot()?;
            let terminals = terminal_snapshot
                .terminals
                .into_iter()
                .map(|terminal| (terminal.terminal_id, terminal.incarnation))
                .collect::<Vec<_>>();
            let closed_public_ids = Self::terminal_public_ids_for_hosted(&registry, &terminals)?;
            let preparation = registry.prepare_resource_effect(
                &mutation.id,
                operation,
                &fingerprint,
                &serde_json::json!({"scope":"session"}),
                None,
                None,
            )?;
            anyhow::ensure!(
                matches!(preparation, ResourceEffectPreparation::Execute { .. }),
                "server stop could not reserve its durable close transaction"
            );
            registry.mark_resource_effect_executing(&mutation.id, operation, &fingerprint)?;

            let result = (|| -> anyhow::Result<_> {
                let mut state = self.state.lock().unwrap();
                let retained_count = self.shutdown_owners.len();
                let tree_changed = !state.surfaces.is_empty()
                    || !state.panes.is_empty()
                    || state.workspaces.iter().any(|workspace| !workspace.screens.is_empty());
                let surfaces = state.surfaces.values().cloned().collect::<Vec<_>>();
                let mut projected = state.clone();
                projected.surfaces.clear();
                for workspace in &mut projected.workspaces {
                    workspace.screens.clear();
                    workspace.active_screen = 0;
                }
                if !projected.panes.is_empty() {
                    projected.pane_revision = projected.pane_revision.saturating_add(1);
                }
                projected.panes.clear();
                projected.split_screens.clear();
                let projection = self.resource_effect_projection_locked(
                    &registry,
                    &mut projected,
                    serde_json::json!({"stopped":true}),
                )?;
                let close = registry.commit_resource_close_patch(
                    &mutation.id,
                    operation,
                    &fingerprint,
                    &projection.patch,
                    &projection.result,
                    &projection.changes,
                    &terminals,
                    None,
                )?;
                projected.resource_revision = close.resource.revision;
                for surface in &surfaces {
                    let _ = self.shutdown_owners.stage_surface(surface);
                }
                *state = projected;
                Ok((surfaces, retained_count, tree_changed, close.terminal_batch))
            })();
            let (surfaces, retained_count, tree_changed, terminal_batch) = match result {
                Ok(result) => result,
                Err(error) => {
                    let _ = registry.mark_resource_effect_indeterminate(&mutation.id);
                    return Err(error);
                }
            };

            if terminal_batch.closed != 0 {
                self.emit_terminal_registry_changed(&registry, terminal_batch.revision);
            }
            (surfaces, retained_count, tree_changed, closed_public_ids)
        };
        self.notify_terminal_exit_waiters(closed_public_ids);
        self.publish_resource_event();
        self.pending_workspace_surfaces.lock().unwrap().clear();
        self.agent_records.lock().unwrap().clear();
        self.surface_notifications.lock().unwrap().clear();
        self.sidebar_plugin.lock().unwrap().surface = None;
        *self.client_sizing.lock().unwrap() = ClientSizingState::default();
        if tree_changed {
            self.emit(MuxEvent::TreeChanged);
        }

        let closed_count = surfaces.len() + retained_count;
        drop(surfaces);
        #[cfg(unix)]
        for (record_path, record) in terminal_host_records {
            let owner = SurfaceShutdownOwner::hosted(record, record_path);
            let key = owner
                .hosted_identity()
                .map(|(terminal_id, incarnation)| ShutdownOwnerKey::Hosted {
                    terminal_id: terminal_id.to_string(),
                    incarnation: incarnation.to_string(),
                })
                .expect("hosted owner has a terminal identity");
            let _ = self.shutdown_owners.stage(key, owner);
        }
        self.terminate_staged_shutdown_owners_until(deadline);
        let browser_runtime_failed = self.shutdown_browser_runtimes_until(deadline);

        let retained = self.shutdown_owners.snapshot();
        let mut failed_surface_ids = retained
            .iter()
            .filter_map(|(key, _)| match key {
                ShutdownOwnerKey::Surface(surface) => Some(*surface),
                ShutdownOwnerKey::Hosted { .. } => None,
            })
            .collect::<Vec<_>>();
        failed_surface_ids.sort_unstable();
        let mut failed_hosts = retained
            .iter()
            .filter_map(|(key, _)| match key {
                ShutdownOwnerKey::Hosted { terminal_id, .. } => Some(terminal_id.clone()),
                ShutdownOwnerKey::Surface(_) => None,
            })
            .collect::<Vec<_>>();
        failed_hosts.sort();

        let mut failures = Vec::new();
        if !failed_surface_ids.is_empty() {
            failures.push(format!(
                "could not terminate {} surface process(es): {}",
                failed_surface_ids.len(),
                failed_surface_ids
                    .into_iter()
                    .map(|surface| surface.to_string())
                    .collect::<Vec<_>>()
                    .join(", ")
            ));
        }
        if browser_runtime_failed {
            failures.push("could not terminate the owned browser before the deadline".to_string());
        }
        if !failed_hosts.is_empty() {
            failures.push(format!(
                "could not terminate {} terminal host(s): {}",
                failed_hosts.len(),
                failed_hosts.join(", ")
            ));
        }
        if !failures.is_empty() {
            anyhow::bail!("{}", failures.join("; "));
        }

        Ok(closed_count)
    }

    #[cfg(unix)]
    fn load_terminal_host_records_for_shutdown(
        &self,
        root: std::path::PathBuf,
        capacity: usize,
        deadline: Instant,
    ) -> anyhow::Result<TerminalHostRecords> {
        #[cfg(test)]
        {
            let loader = self.terminal_host_record_loader.lock().unwrap().clone();
            self.terminal_host_record_scan.scan_until(
                root,
                capacity,
                deadline,
                move |root, capacity, deadline| {
                    if let Some(loader) = loader {
                        loader(root, capacity, deadline)
                    } else {
                        crate::terminal_host_runtime::load_terminal_host_records_strict(
                            &root, capacity, deadline,
                        )
                    }
                },
            )
        }
        #[cfg(not(test))]
        {
            self.terminal_host_record_scan.scan_until(
                root,
                capacity,
                deadline,
                |root, capacity, deadline| {
                    crate::terminal_host_runtime::load_terminal_host_records_strict(
                        &root, capacity, deadline,
                    )
                },
            )
        }
    }

    fn lock_shutdown_coordinator_until(
        &self,
        deadline: Instant,
    ) -> anyhow::Result<ShutdownCoordinatorGuard<'_>> {
        self.shutdown_coordinator.lock_until(deadline)
    }

    /// Validate the target daemon and atomically reserve its handoff. Unless
    /// forced, this proves no other native browser owns the mux. New owner
    /// announcements are rejected until the response is queued or the
    /// reservation is cancelled.
    pub(crate) fn begin_daemon_handoff(
        &self,
        requesting_client: u64,
        request: DaemonHandoffRequest,
    ) -> anyhow::Result<DaemonIdentity> {
        let (_, generation) = self.registry_identity();
        let actual_identity = DaemonIdentity { pid: std::process::id(), generation };
        if let Some(expected_identity) = &request.expected_identity {
            if expected_identity.pid != actual_identity.pid {
                anyhow::bail!("daemon pid changed; identify again");
            }
            if expected_identity.generation != actual_identity.generation {
                anyhow::bail!("daemon generation changed; identify again");
            }
        }
        self.control_clients.begin_daemon_handoff(
            requesting_client,
            &self.daemon_handoff_pending,
            request.force,
        )?;
        let deadline = Instant::now() + crate::server::SERVER_SHUTDOWN_TIMEOUT;
        let preflight: anyhow::Result<()> = (|| {
            #[cfg(unix)]
            crate::process_session::require_stable_process_signaling_until(deadline)
                .context("preflight process control for daemon handoff")?;
            let _coordinator = self.lock_shutdown_coordinator_until(deadline)?;
            Ok(())
        })();
        if preflight.is_err() {
            self.cancel_daemon_handoff();
        }
        preflight?;
        Ok(actual_identity)
    }

    pub fn cancel_daemon_handoff(&self) {
        self.daemon_handoff_pending.store(false, Ordering::Release);
    }

    /// Ask the owning frontend loop to leave through the normal daemon
    /// shutdown path. Durable terminal hosts are disconnected by `shutdown`
    /// and remain available for the replacement daemon to adopt.
    pub fn request_daemon_shutdown(&self) {
        self.shutting_down.store(true, Ordering::Release);
        self.surface_creations.stop();
        self.async_surface_creations.stop();
        self.browser_runtime.stop();
        self.daemon_shutdown_requested.store(true, Ordering::Release);
        #[cfg(unix)]
        self.request_terminal_adoption_stop();
        self.request_shutdown();
    }

    pub fn daemon_shutdown_requested(&self) -> bool {
        self.daemon_shutdown_requested.load(Ordering::Acquire)
    }

    pub(crate) fn is_shutting_down(&self) -> bool {
        self.shutting_down.load(Ordering::Acquire)
    }

    /// Update options used for future surface/browser launches.
    pub fn update_surface_options(&self, update: impl FnOnce(&mut SurfaceOptions)) {
        let mut options = self.surface_options.lock().unwrap();
        update(&mut options);
        options.browser_session_name = self.session.clone();
    }

    pub fn configure_sidebar_plugin(&self, options: Option<SidebarPluginOptions>) {
        let old_surface = {
            let mut runtime = self.sidebar_plugin.lock().unwrap();
            if runtime.options == options {
                return;
            }
            runtime.options = options;
            runtime.last_error = None;
            runtime.failures = 0;
            runtime.retry_at = None;
            runtime.surface.take()
        };
        let retired = old_surface.and_then(|id| {
            let mut state = self.state.lock().unwrap();
            take_surface_for_retirement(self, &mut state, id)
        });
        if let Some(surface) = retired {
            self.retire_surface_runtime(surface.clone());
            self.emit(MuxEvent::SurfaceExited(surface.id));
        }
    }

    pub fn ensure_sidebar_plugin(
        self: &Arc<Self>,
        cols: u16,
        rows: u16,
        relaunch: bool,
    ) -> SidebarPluginStatus {
        let _creation = match self.begin_surface_creation() {
            Ok(creation) => creation,
            Err(error) => {
                return SidebarPluginStatus {
                    surface: None,
                    error: Some(error.to_string()),
                    retry_after: None,
                };
            }
        };
        let now = Instant::now();
        let size = (cols.max(1), rows.max(1));
        let spawn_options = {
            let mut runtime = self.sidebar_plugin.lock().unwrap();
            let Some(options) = runtime.options.clone() else {
                return SidebarPluginStatus { surface: None, error: None, retry_after: None };
            };
            runtime.last_size = Some(size);
            if let Some(surface_id) = runtime.surface {
                if let Some(surface) = self.surface(surface_id).filter(|surface| !surface.is_dead())
                {
                    drop(runtime);
                    let _ = self.resize_surface(surface_id, size.0, size.1);
                    drop(surface);
                    return SidebarPluginStatus {
                        surface: Some(surface_id),
                        error: None,
                        retry_after: None,
                    };
                }
                runtime.surface = None;
            }
            if let Some(error) = runtime.last_error.clone() {
                let retry_after = runtime.retry_at.and_then(|retry_at| {
                    (retry_at > now).then_some(retry_at.saturating_duration_since(now))
                });
                if !relaunch || retry_after.is_some() {
                    return SidebarPluginStatus { surface: None, error: Some(error), retry_after };
                }
            }
            options
        };
        match self.spawn_sidebar_plugin_surface(&spawn_options, size) {
            Ok(surface) => {
                let surface_id = surface.id;
                {
                    let mut runtime = self.sidebar_plugin.lock().unwrap();
                    runtime.surface = Some(surface_id);
                    runtime.last_error = None;
                    runtime.failures = 0;
                    runtime.retry_at = None;
                }
                self.reap_if_dead(&surface);
                SidebarPluginStatus { surface: Some(surface_id), error: None, retry_after: None }
            }
            Err(err) => {
                let mut runtime = self.sidebar_plugin.lock().unwrap();
                runtime.surface = None;
                runtime.failures = runtime.failures.saturating_add(1);
                let delay = sidebar_retry_delay(runtime.failures);
                let message = format!("sidebar plugin failed to start: {err}");
                runtime.last_error = Some(message.clone());
                runtime.retry_at = Some(now + delay);
                SidebarPluginStatus {
                    surface: None,
                    error: Some(message),
                    retry_after: Some(delay),
                }
            }
        }
    }

    #[cfg(test)]
    pub(crate) fn sidebar_plugin_status(&self) -> SidebarPluginStatus {
        let runtime = self.sidebar_plugin.lock().unwrap();
        let now = Instant::now();
        let surface = runtime
            .surface
            .filter(|surface| self.surface(*surface).is_some_and(|surface| !surface.is_dead()));
        SidebarPluginStatus {
            surface,
            error: runtime.last_error.clone(),
            retry_after: runtime
                .retry_at
                .and_then(|retry_at| (retry_at > now).then(|| retry_at.duration_since(now))),
        }
    }

    pub(crate) fn sidebar_plugin_surface(&self) -> Option<Arc<Surface>> {
        let surface = self.sidebar_plugin.lock().unwrap().surface?;
        self.surface(surface)
    }

    pub(crate) fn sidebar_plugin_resource_status(
        &self,
    ) -> (SidebarPluginStatus, Option<(u16, u16)>, bool) {
        let runtime = self.sidebar_plugin.lock().unwrap();
        let now = Instant::now();
        let surface = runtime
            .surface
            .filter(|surface| self.surface(*surface).is_some_and(|surface| !surface.is_dead()));
        (
            SidebarPluginStatus {
                surface,
                error: runtime.last_error.clone(),
                retry_after: runtime
                    .retry_at
                    .and_then(|retry_at| (retry_at > now).then(|| retry_at.duration_since(now))),
            },
            runtime.last_size,
            runtime.options.is_some(),
        )
    }

    pub(crate) fn reload_sidebar_plugin(
        self: &Arc<Self>,
        cols: u16,
        rows: u16,
    ) -> SidebarPluginStatus {
        let old_surface = {
            let mut runtime = self.sidebar_plugin.lock().unwrap();
            runtime.last_size = Some((cols.max(1), rows.max(1)));
            runtime.last_error = None;
            runtime.failures = 0;
            runtime.retry_at = None;
            runtime.surface.take()
        };
        let removed = old_surface.and_then(|id| {
            let mut state = self.state.lock().unwrap();
            take_surface_for_retirement(self, &mut state, id)
        });
        if let Some(surface) = removed {
            self.purge_surface_side_tables(surface.id);
            self.retire_surface_runtime(surface.clone());
            self.emit(MuxEvent::SurfaceExited(surface.id));
        }
        self.ensure_sidebar_plugin(cols, rows, true)
    }

    pub(crate) fn resource_resize_sidebar_selected(
        &self,
        selectors: crate::ResourceSelectors,
        sidebar_id: &SidebarViewPublicId,
        cols: u16,
        rows: u16,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let cols = cols.max(1);
        let rows = rows.max(1);
        let fingerprint = serde_json::json!({
            "operation":"sidebar_view.resize",
            "selectors":selectors,
            "sidebar_view":sidebar_id,
            "cols":cols,
            "rows":rows,
        });
        if let Some(replay) = self.workspace_registry.lock().unwrap().replay_resource_patch(
            mutation,
            "sidebar_view.resize",
            &fingerprint,
        )? {
            return Ok(replay);
        }
        let raw = selectors.sidebar_view.as_deref().ok_or_else(|| {
            anyhow::Error::new(ResourceError::selector_invalid(
                "sidebar_view",
                "<missing>",
                "missing required sidebar_view selector",
            ))
        })?;
        match Selector::parse(raw).map_err(anyhow::Error::new)? {
            Selector::Current => {}
            Selector::Id(id) if id == sidebar_id.as_str() => {}
            Selector::Name(name) if matches!(name.as_str(), "sidebar" | "default") => {}
            Selector::Id(_) | Selector::Name(_) => {
                return Err(anyhow::Error::new(ResourceError::not_found("sidebar_view", raw)));
            }
        }
        let mut runtime = self.sidebar_plugin.lock().unwrap();
        anyhow::ensure!(runtime.options.is_some(), "sidebar view is not configured");
        let surface_id = runtime.surface.context("sidebar view is not running")?;
        let surface = self
            .state
            .lock()
            .unwrap()
            .surfaces
            .get(&surface_id)
            .cloned()
            .context("sidebar view surface disappeared")?;
        anyhow::ensure!(!surface.is_dead(), "sidebar view is not running");
        let mut session_selectors = selectors.clone();
        session_selectors.sidebar_view = None;
        let sidebar_id = sidebar_id.clone();
        let commit = self.commit_resource_mutation_plan(
            mutation,
            "sidebar_view.resize",
            &fingerprint,
            None,
            expected_revision,
            move |state, registry| {
                self.resolve_resource_path_in_state(
                    state,
                    registry,
                    crate::ResourceTarget::Session,
                    &session_selectors,
                )
                .map_err(anyhow::Error::new)?;
                let value = serde_json::json!({
                    "id":sidebar_id,
                    "session_id":registry.session_id(),
                    "cols":cols,
                    "rows":rows,
                    "running":true,
                });
                let deltas = serde_json::json!([{
                    "kind":"upsert",
                    "sequence":0,
                    "resource":"sidebar_view",
                    "id":sidebar_id,
                    "value":value,
                }]);
                Ok(ResourceMutationPlan::new(
                    ResourcePatch { changes: Vec::new() },
                    value,
                    deltas,
                    move |_state| {
                        let _ = surface.resize(cols, rows);
                    },
                )
                .with_metrics(ResourceMutationMetrics {
                    touched_resources: 1,
                    order_entries: 0,
                    terminal_queries: 0,
                    changed_rows: 0,
                }))
            },
        )?;
        if !commit.replayed {
            runtime.last_size = Some((cols, rows));
        }
        Ok(commit)
    }

    pub fn set_cell_pixel_size(&self, width_px: u16, height_px: u16) -> CellPixelUpdate {
        self.set_cell_pixel_size_reporting(width_px, height_px, Arc::new(|_, _, _| {}))
    }

    pub fn cell_pixel_size(&self) -> (u16, u16) {
        *self.cell_pixels.lock().unwrap()
    }

    pub(crate) fn resource_terminal_host_identity(
        &self,
        surface: &Surface,
    ) -> Option<TerminalHostIdentity> {
        surface.terminal_host_identity().or_else(|| {
            self.reserved_in_process_terminals.lock().unwrap().get(&surface.id).cloned()
        })
    }

    pub fn set_cell_pixel_size_reporting(
        &self,
        width_px: u16,
        height_px: u16,
        report: SurfaceResizeReporter,
    ) -> CellPixelUpdate {
        let next = (width_px.max(1), height_px.max(1));
        // This is the desired global metric used for new browser surfaces.
        // Existing surfaces still check their settled geometry on every call,
        // so a rejected queue submission can be retried with the same value.
        *self.cell_pixels.lock().unwrap() = next;
        let surfaces = self.state.lock().unwrap().surfaces.values().cloned().collect::<Vec<_>>();
        let mut update = CellPixelUpdate::default();
        for surface in surfaces {
            let id = surface.id;
            let size = surface.size();
            let callback = report.clone();
            match surface.set_cell_pixel_size_reporting(
                next.0,
                next.1,
                Box::new(move |accepted| callback(id, size, accepted)),
            ) {
                Ok(Some(reservation_id)) => update.resizes.push((id, size, reservation_id)),
                Ok(None) => {}
                Err(error) => update
                    .failures
                    .push(CellPixelUpdateFailure { surface: id, error: error.to_string() }),
            }
        }
        update
    }

    pub fn default_colors(&self) -> DefaultColors {
        *self.default_colors.lock().unwrap()
    }

    pub fn set_default_colors(&self, colors: DefaultColors) {
        let state = self.state.lock().unwrap();
        let surfaces = {
            let mut current = self.default_colors.lock().unwrap();
            if *current == colors {
                return;
            }
            *current = colors;
            state.surfaces.values().cloned().collect::<Vec<_>>()
        };
        for surface in surfaces {
            surface.set_default_colors(colors);
            self.emit(MuxEvent::SurfaceOutput(surface.id));
        }
    }

    pub fn seed_default_colors_if_no_durable_override(&self, colors: DefaultColors) {
        let state = self.state.lock().unwrap();
        let surfaces = {
            let mut current = self.default_colors.lock().unwrap();
            if self.durable_terminal_defaults.load(Ordering::Acquire) || *current == colors {
                return;
            }
            *current = colors;
            state.surfaces.values().cloned().collect::<Vec<_>>()
        };
        for surface in surfaces {
            surface.set_default_colors(colors);
            self.emit(MuxEvent::SurfaceOutput(surface.id));
        }
    }

    #[allow(clippy::too_many_arguments)]
    pub(crate) fn resource_update_terminal_defaults_selected(
        &self,
        selectors: crate::ResourceSelectors,
        fields: &Value,
        colors: DefaultColors,
        value: &Value,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let mut intent_fields = fields.clone();
        if let Some(fields) = intent_fields.as_object_mut() {
            fields.remove("expected_revision");
        }
        let fingerprint = serde_json::json!({
            "operation":"session.terminal_defaults.update",
            "selectors":selectors,
            "fields":intent_fields,
        });
        let mut registry = self.workspace_registry.lock().unwrap();
        if let Some(replay) = registry.replay_resource_patch(
            mutation,
            "session.terminal_defaults.update",
            &fingerprint,
        )? {
            return Ok(replay);
        }
        let mut state = self.state.lock().unwrap();
        self.resolve_resource_path_in_state(
            &state,
            &registry,
            crate::ResourceTarget::Session,
            &selectors,
        )
        .map_err(anyhow::Error::new)?;
        let surfaces = state.surfaces.values().cloned().collect::<Vec<_>>();
        let commit = registry.commit_resource_patch(
            mutation,
            "session.terminal_defaults.update",
            &fingerprint,
            None,
            expected_revision,
            &ResourcePatch { changes: Vec::new() },
            value,
            &Value::Array(Vec::new()),
        )?;
        state.resource_revision = commit.revision;
        self.durable_terminal_defaults.store(true, Ordering::Release);
        *self.default_colors.lock().unwrap() = colors;
        for surface in surfaces {
            surface.set_default_colors(colors);
            self.emit(MuxEvent::SurfaceOutput(surface.id));
        }
        drop(state);
        drop(registry);
        if !commit.replayed {
            self.publish_resource_event();
        }
        Ok(commit)
    }

    /// Resize a surface and broadcast the final clamped size when it actually
    /// changes. Browser workers broadcast after their asynchronous CDP work.
    pub fn resize_surface(&self, id: SurfaceId, cols: u16, rows: u16) -> anyhow::Result<bool> {
        self.resize_surface_with_reservation(id, cols, rows).map(|(accepted, _)| accepted)
    }

    pub fn resize_surface_with_reservation(
        &self,
        id: SurfaceId,
        cols: u16,
        rows: u16,
    ) -> anyhow::Result<(bool, Option<u64>)> {
        self.resize_surface_with_completion(id, cols, rows, None)
    }

    fn resize_surface_with_completion(
        &self,
        id: SurfaceId,
        cols: u16,
        rows: u16,
        completion: Option<SurfaceResizeCompletion>,
    ) -> anyhow::Result<(bool, Option<u64>)> {
        let Some(surface) = self.surface(id) else {
            anyhow::bail!("unknown surface {id}");
        };
        // Not recorded as a client size here: internal resizes (e.g. the
        // sidebar plugin surface tracking the TUI rect every frame) also land
        // in this method and must not become the default for new surfaces.
        // Client interactions record explicitly at the protocol/TUI layers.
        let (cols, rows) = clamp_terminal_size(cols, rows);
        if surface.as_browser().is_some() {
            let reservation_id =
                surface.resize_reporting_completion(cols, rows, Box::new(|_| {}), completion)?;
            return Ok((reservation_id.is_some(), reservation_id));
        }
        let reports_asynchronously = surface.resize_reports_asynchronously();
        if !surface.resize(cols, rows)? {
            if let Some(completion) = completion {
                let _ = completion.send(Ok(()));
            }
            return Ok((false, None));
        }
        if reports_asynchronously {
            return Ok((true, None));
        }
        if let Some(completion) = completion {
            let _ = completion.send(Ok(()));
        }
        let (cols, rows) = surface.size();
        self.emit(MuxEvent::SurfaceResized { surface: id, cols, rows, reservation_id: None });
        Ok((true, None))
    }

    /// Create a workspace with one screen holding one pane with one tab.
    /// Returns the tab's surface. `size` is the expected content size in
    /// cells, when the caller knows it (spawning at the final size avoids
    /// shell redraw artifacts).
    pub fn new_workspace(
        self: &Arc<Self>,
        name: Option<String>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        let _creation = self.begin_surface_creation()?;
        let _creation_handoff = self.resource_creation_handoff.lock().unwrap();
        let mut fields =
            Map::from_iter([("initial_content".into(), Value::String("terminal".into()))]);
        Self::insert_optional_string(&mut fields, "name", name);
        Self::insert_cell_size(&mut fields, size);
        let commit = self.commit_ordinary_topology_operation(
            ResourceOperation::WorkspaceCreate,
            Self::ordinary_resource_selectors(),
            fields,
        )?;
        self.emit_resource_topology_legacy_events(ResourceOperation::WorkspaceCreate, &commit);
        self.ordinary_created_surface(&commit)
    }

    /// Add an ordered workspace-registry entry without creating a PTY,
    /// screen, or pane. Detached GUI frontends use this when a user creates
    /// an empty workspace in Chrome.
    pub fn create_empty_workspace(
        &self,
        name: Option<String>,
        key: Option<String>,
        expected_revision: Option<u64>,
    ) -> anyhow::Result<WorkspacePlacement> {
        let mutation = WorkspaceMutation::local("cmux-tui");
        self.create_empty_workspace_with_mutation(name, key, None, expected_revision, &mutation)
    }

    pub fn create_empty_workspace_with_mutation(
        &self,
        name: Option<String>,
        requested_key: Option<String>,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
    ) -> anyhow::Result<WorkspacePlacement> {
        self.create_empty_workspace_with_mutation_inner(
            name,
            requested_key,
            None,
            expected_generation,
            expected_revision,
            mutation,
            true,
        )
    }

    fn create_empty_workspace_for_resource_effect(
        &self,
        name: Option<String>,
        requested_key: Option<String>,
        public_id: WorkspacePublicId,
        mutation: &WorkspaceMutation,
    ) -> anyhow::Result<WorkspacePlacement> {
        self.create_empty_workspace_with_mutation_inner(
            name,
            requested_key,
            Some(public_id),
            None,
            None,
            mutation,
            false,
        )
    }

    #[allow(clippy::too_many_arguments)]
    fn create_empty_workspace_with_mutation_inner(
        &self,
        name: Option<String>,
        requested_key: Option<String>,
        requested_public_id: Option<WorkspacePublicId>,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
        project_resource: bool,
    ) -> anyhow::Result<WorkspacePlacement> {
        if let Some(name) = name.as_deref() {
            Self::validate_workspace_name(name)?;
        }
        let key = match requested_key.as_ref() {
            Some(key) if key.trim().is_empty() => anyhow::bail!("workspace key cannot be empty"),
            Some(key) if !crate::workspace_registry::is_canonical_workspace_key(key) => {
                anyhow::bail!("workspace key must be a lowercase UUID")
            }
            Some(key) => key.clone(),
            None => Self::new_workspace_key()?,
        };
        Self::validate_workspace_key(&key)?;
        let requested_name = name.clone();
        let ws_id = self.next_id();
        let notifications = self.surface_notifications();
        let mut registry = self.workspace_registry.lock().unwrap();
        let fingerprint = serde_json::json!({
            "op": "create-workspace",
            "name": requested_name,
            "requested_key": requested_key,
        });
        if let Some(commit) = registry.replay(mutation, &fingerprint)? {
            let workspace = commit.result["workspace"]
                .as_u64()
                .ok_or_else(|| anyhow::anyhow!("stored create result is missing workspace"))?;
            let key = commit.result["key"]
                .as_str()
                .ok_or_else(|| anyhow::anyhow!("stored create result is missing key"))?
                .to_string();
            let index = commit.result["index"]
                .as_u64()
                .and_then(|value| usize::try_from(value).ok())
                .ok_or_else(|| anyhow::anyhow!("stored create result is missing index"))?;
            return Ok(WorkspacePlacement {
                workspace,
                key,
                index,
                revision: commit.revision,
                replayed: true,
            });
        }
        let workspace_public_id =
            requested_public_id.map(Ok).unwrap_or_else(WorkspacePublicId::random)?;
        let (placement, delta, selection_resync) = {
            let mut state = self.state.lock().unwrap();
            if state.workspaces.len() >= WORKSPACE_REGISTRY_LIMIT {
                anyhow::bail!("workspace limit reached ({WORKSPACE_REGISTRY_LIMIT})");
            }
            if state.workspace_by_key(&key).is_some() {
                anyhow::bail!("workspace key already exists: {key}");
            }
            let name = name.unwrap_or_else(|| Self::default_workspace_name(&state));
            let index = state.workspaces.len();
            let selection_resync = !state.workspaces.is_empty();
            let mut desired = self.registry_projection(&state);
            desired.push(RegistryWorkspace {
                id: ws_id,
                public_id: workspace_public_id.clone(),
                key: key.clone(),
                name: name.clone(),
                group_key: self.session.clone(),
            });
            let result = serde_json::json!({
                "workspace": ws_id,
                "workspace_id": workspace_public_id.as_str(),
                "key": key,
                "index": index,
            });
            let commit = if project_resource {
                registry.commit_with_active_workspace(
                    mutation,
                    &fingerprint,
                    expected_generation,
                    expected_revision,
                    "workspace-added",
                    &key,
                    &desired,
                    Some(&workspace_public_id),
                    &result,
                )?
            } else {
                registry.commit_for_resource_effect(
                    mutation,
                    &fingerprint,
                    expected_generation,
                    expected_revision,
                    "workspace-added",
                    &key,
                    &desired,
                    Some(&workspace_public_id),
                    &result,
                )?
            };
            let committed_workspace = commit.result["workspace"]
                .as_u64()
                .ok_or_else(|| anyhow::anyhow!("stored create result is missing workspace"))?;
            let committed_key = commit.result["key"]
                .as_str()
                .ok_or_else(|| anyhow::anyhow!("stored create result is missing key"))?
                .to_string();
            let committed_index = commit.result["index"]
                .as_u64()
                .and_then(|value| usize::try_from(value).ok())
                .ok_or_else(|| anyhow::anyhow!("stored create result is missing index"))?;
            if commit.replayed {
                return Ok(WorkspacePlacement {
                    workspace: committed_workspace,
                    key: committed_key,
                    index: committed_index,
                    revision: commit.revision,
                    replayed: true,
                });
            }
            let resource_revision = project_resource
                .then(|| registry.snapshot())
                .transpose()?
                .map(|snapshot| snapshot.resource_revision);
            state.push_workspace(Workspace {
                id: ws_id,
                public_id: workspace_public_id,
                key: key.clone(),
                name,
                screens: Vec::new(),
                active_screen: 0,
            });
            state.active_workspace = state.workspaces.len() - 1;
            state.workspace_revision = commit.revision;
            if let Some(resource_revision) = resource_revision {
                state.resource_revision = resource_revision;
            }
            let revision = commit.revision;
            let entity = crate::server::tree_entity_json(
                &state,
                &notifications,
                TreeDeltaKind::WorkspaceAdded,
                ws_id,
            )
            .expect("new empty workspace is present in tree snapshot");
            (
                WorkspacePlacement { workspace: ws_id, key, index, revision, replayed: false },
                TreeDelta {
                    kind: TreeDeltaKind::WorkspaceAdded,
                    workspace: ws_id,
                    screen: None,
                    pane: None,
                    surface: None,
                    index: Some(index),
                    entity,
                    workspace_revision: Some(revision),
                },
                selection_resync,
            )
        };
        drop(registry);
        if project_resource {
            self.publish_resource_event();
        }
        self.emit_tree_delta(delta, selection_resync);
        Ok(placement)
    }

    pub fn run_command_surface(
        self: &Arc<Self>,
        argv: Vec<String>,
        pane: Option<PaneId>,
        new_workspace: bool,
        cwd: Option<String>,
        name: Option<String>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<RunPlacement> {
        self.run_command_surface_with_options(
            argv,
            RunCommandOptions { pane, new_workspace, workspace_key: None, cwd, name, size },
        )
    }

    /// Runs a command and optionally creates its workspace with a caller-owned
    /// stable key. The key is only meaningful when `new_workspace` is true.
    pub(crate) fn run_command_surface_with_options(
        self: &Arc<Self>,
        argv: Vec<String>,
        options: RunCommandOptions,
    ) -> anyhow::Result<RunPlacement> {
        let _creation = self.begin_surface_creation()?;
        let _creation_handoff = self.resource_creation_handoff.lock().unwrap();
        let RunCommandOptions { pane, new_workspace, workspace_key, cwd, name, size } = options;
        if workspace_key.is_some() && !new_workspace {
            anyhow::bail!("workspace key requires a new workspace");
        }
        let (operation, selectors) = if new_workspace {
            (ResourceOperation::WorkspaceCreate, Self::ordinary_resource_selectors())
        } else {
            let state = self.state.lock().unwrap();
            let target = match pane {
                Some(id) => {
                    if !state.panes.contains_key(&id) {
                        anyhow::bail!("unknown pane {id}");
                    }
                    Some(id)
                }
                None => state.active_pane(),
            };
            if let Some(target) = target {
                drop(state);
                (
                    ResourceOperation::PaneRun,
                    self.ordinary_pane_selectors(target)
                        .with_context(|| format!("unknown pane {target}"))?,
                )
            } else if let Some(workspace) = state.workspaces.get(state.active_workspace) {
                let workspace = workspace.id;
                drop(state);
                (
                    ResourceOperation::WorkspaceRun,
                    self.ordinary_workspace_selectors(workspace)
                        .with_context(|| format!("unknown workspace {workspace}"))?,
                )
            } else {
                (ResourceOperation::WorkspaceCreate, Self::ordinary_resource_selectors())
            }
        };
        let mut fields = Map::from_iter([(
            "argv".into(),
            Value::Array(argv.into_iter().map(Value::String).collect()),
        )]);
        if operation == ResourceOperation::WorkspaceCreate {
            fields.insert("initial_content".into(), Value::String("terminal".into()));
            Self::insert_optional_string(&mut fields, "name", name.clone());
            Self::insert_optional_string(&mut fields, "workspace_key", workspace_key);
            Self::insert_optional_string(&mut fields, "terminal_name", name);
        } else {
            Self::insert_optional_string(&mut fields, "name", name);
        }
        Self::insert_optional_string(&mut fields, "cwd", cwd);
        Self::insert_cell_size(&mut fields, size);
        let commit = self.commit_ordinary_topology_operation(operation, selectors, fields)?;
        self.emit_resource_topology_legacy_events(operation, &commit);
        let surface = self.ordinary_created_surface(&commit)?;
        self.with_state(|state| run_placement_for_surface(state, surface.id))
            .context("created command surface has no placement")
    }

    /// Create a screen in a workspace (default: the active one) with one
    /// pane/tab, and make it active. Returns the tab's surface.
    pub fn new_screen(
        self: &Arc<Self>,
        workspace: Option<WorkspaceId>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        self.new_screen_with_cwd(workspace, None, size)
    }

    fn new_screen_with_cwd(
        self: &Arc<Self>,
        workspace: Option<WorkspaceId>,
        cwd: Option<String>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        let _creation = self.begin_surface_creation()?;
        let _creation_handoff = self.resource_creation_handoff.lock().unwrap();
        let selectors = match workspace {
            Some(workspace) => self
                .ordinary_workspace_selectors(workspace)
                .with_context(|| format!("unknown workspace {workspace}"))?,
            None => {
                let active = self.with_state(|state| {
                    state.workspaces.get(state.active_workspace).map(|workspace| workspace.id)
                });
                active
                    .and_then(|workspace| self.ordinary_workspace_selectors(workspace))
                    .unwrap_or_else(Self::ordinary_resource_selectors)
            }
        };
        let mut fields = Map::new();
        Self::insert_optional_string(&mut fields, "cwd", cwd);
        Self::insert_cell_size(&mut fields, size);
        let commit = self.commit_ordinary_topology_operation(
            ResourceOperation::ScreenCreate,
            selectors,
            fields,
        )?;
        self.emit_resource_topology_legacy_events(ResourceOperation::ScreenCreate, &commit);
        self.ordinary_created_surface(&commit)
    }

    /// Create a tab in a pane (default: the active pane of the active
    /// screen). When the session has no workspaces yet (headless before
    /// any command), a workspace is created around the new tab.
    pub fn new_tab(
        self: &Arc<Self>,
        pane: Option<PaneId>,
        cwd: Option<String>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        let _creation = self.begin_surface_creation()?;
        let _creation_handoff = self.resource_creation_handoff.lock().unwrap();
        let selectors = {
            let state = self.state.lock().unwrap();
            let target = match pane {
                Some(id) => {
                    if !state.panes.contains_key(&id) {
                        anyhow::bail!("unknown pane {id}");
                    }
                    Some(id)
                }
                None => state.active_pane(),
            };
            if let Some(target) = target {
                drop(state);
                self.ordinary_pane_selectors(target)
                    .with_context(|| format!("unknown pane {target}"))?
            } else if let Some(workspace) = state.workspaces.get(state.active_workspace) {
                let workspace = workspace.id;
                drop(state);
                self.ordinary_workspace_selectors(workspace)
                    .with_context(|| format!("unknown workspace {workspace}"))?
            } else {
                Self::ordinary_resource_selectors()
            }
        };
        let mut fields = Map::new();
        Self::insert_optional_string(&mut fields, "cwd", cwd);
        Self::insert_cell_size(&mut fields, size);
        let commit = self.commit_ordinary_topology_operation(
            ResourceOperation::TabCreateTerminal,
            selectors,
            fields,
        )?;
        self.emit_resource_topology_legacy_events(ResourceOperation::TabCreateTerminal, &commit);
        self.ordinary_created_surface(&commit)
    }

    /// Create a terminal in a specific workspace without changing the mux's
    /// active workspace. An empty workspace gets its first screen and pane;
    /// otherwise the new surface becomes a tab in that workspace's active
    /// pane. The target is re-resolved under the attach lock so concurrent
    /// first-terminal requests cannot accidentally create another workspace.
    pub fn create_terminal_in_workspace(
        self: &Arc<Self>,
        workspace: WorkspaceId,
        argv: Option<Vec<String>>,
        cwd: Option<String>,
        name: Option<String>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<RunPlacement> {
        self.create_terminal_surface_in_workspace(workspace, argv, cwd, name, size)
            .map(|(_, placement)| placement)
    }

    fn create_terminal_surface_in_workspace(
        self: &Arc<Self>,
        workspace: WorkspaceId,
        argv: Option<Vec<String>>,
        cwd: Option<String>,
        name: Option<String>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<(Arc<Surface>, RunPlacement)> {
        let _creation = self.begin_surface_creation()?;
        let _creation_handoff = self.resource_creation_handoff.lock().unwrap();
        let selectors = self
            .ordinary_workspace_selectors(workspace)
            .with_context(|| format!("unknown workspace {workspace}"))?;
        let operation = if argv.is_some() {
            ResourceOperation::WorkspaceRun
        } else {
            ResourceOperation::TabCreateTerminal
        };
        let mut fields = Map::new();
        if let Some(argv) = argv {
            fields
                .insert("argv".into(), Value::Array(argv.into_iter().map(Value::String).collect()));
        }
        Self::insert_optional_string(&mut fields, "cwd", cwd);
        Self::insert_optional_string(&mut fields, "name", name);
        Self::insert_cell_size(&mut fields, size);
        let commit = self.commit_ordinary_topology_operation(operation, selectors, fields)?;
        self.emit_resource_topology_legacy_events(operation, &commit);
        let surface = self.ordinary_created_surface(&commit)?;
        let placement = self
            .with_state(|state| run_placement_for_surface(state, surface.id))
            .context("created terminal has no placement")?;
        Ok((surface, placement))
    }

    #[allow(clippy::too_many_arguments)]
    pub fn create_terminal_in_workspace_with_mutation(
        self: &Arc<Self>,
        workspace: WorkspaceId,
        argv: Option<Vec<String>>,
        cwd: Option<String>,
        name: Option<String>,
        size: Option<(u16, u16)>,
        requested_terminal_id: Option<&str>,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
    ) -> anyhow::Result<TerminalPlacementResult> {
        let workspace_key = self
            .state
            .lock()
            .unwrap()
            .workspace_by_id(workspace)
            .map(|workspace| workspace.key.clone())
            .ok_or_else(|| anyhow::anyhow!("unknown workspace {workspace}"))?;
        if let Some(terminal_id) = requested_terminal_id {
            validate_terminal_hex(terminal_id, "invalid_terminal_id")?;
        }
        let fingerprint = terminal_create_fingerprint(
            &workspace_key,
            requested_terminal_id,
            argv.as_deref(),
            cwd.as_deref(),
            name.as_deref(),
            size,
        )?;
        let replay =
            { self.workspace_registry.lock().unwrap().replay_terminal(mutation, &fingerprint)? };
        if let Some(replay) = replay {
            let terminal_id = replay.result["terminal_id"]
                .as_str()
                .ok_or_else(|| anyhow::anyhow!("stored terminal create result is missing id"))?;
            return self.replayed_terminal_placement(terminal_id);
        }
        let terminal_id = match requested_terminal_id {
            Some(value) => TerminalId::from_hex(value).expect("validated terminal UUID"),
            None => TerminalId::random()?,
        };
        let reservation = TerminalReservationRequest {
            terminal_id,
            mutation: mutation.clone(),
            fingerprint,
            expected_generation: expected_generation.map(str::to_string),
            expected_revision,
        };
        let (placement, surface) = self.create_terminal_in_workspace_impl(
            workspace,
            argv,
            cwd,
            name,
            size,
            Some(reservation),
        )?;
        let identity = self
            .resource_terminal_host_identity(&surface)
            .ok_or_else(|| anyhow::anyhow!("created terminal has no host identity"))?;
        let snapshot = self.workspace_registry.lock().unwrap().terminal_snapshot()?;
        Ok(TerminalPlacementResult {
            placement,
            terminal_id: identity.terminal_id,
            terminal_incarnation: Some(identity.incarnation),
            terminal_revision: snapshot.revision,
            replayed: false,
        })
    }

    fn replayed_terminal_placement(
        &self,
        terminal_id: &str,
    ) -> anyhow::Result<TerminalPlacementResult> {
        let resolution = self
            .resolve_terminal(terminal_id)?
            .ok_or_else(|| anyhow::anyhow!("stored terminal create result has no registry row"))?;
        let surface = resolution.surface.ok_or_else(|| {
            anyhow::anyhow!(
                "terminal_create_pending:{}",
                terminal_lifecycle_name(resolution.terminal.lifecycle)
            )
        })?;
        let placement = {
            let state = self.state.lock().unwrap();
            run_placement_for_surface(&state, surface)
        }
        .ok_or_else(|| anyhow::anyhow!("terminal_create_pending:binding"))?;
        Ok(TerminalPlacementResult {
            placement,
            terminal_id: resolution.terminal.terminal_id,
            terminal_incarnation: resolution.terminal.incarnation,
            terminal_revision: resolution.terminal_revision,
            replayed: true,
        })
    }

    fn create_terminal_in_workspace_impl(
        self: &Arc<Self>,
        workspace: WorkspaceId,
        argv: Option<Vec<String>>,
        cwd: Option<String>,
        name: Option<String>,
        size: Option<(u16, u16)>,
        reservation: Option<TerminalReservationRequest>,
    ) -> anyhow::Result<(RunPlacement, Arc<Surface>)> {
        let _creation = self.begin_surface_creation()?;
        {
            let state = self.state.lock().unwrap();
            if state.workspace_by_id(workspace).is_none() {
                anyhow::bail!("unknown workspace {workspace}");
            }
        }
        #[cfg(test)]
        if let Some(hook) = self.terminal_create_after_empty_check.lock().unwrap().clone() {
            hook();
        }
        let lifecycle = self.workspace_lifecycle(workspace);
        let workspace_lifecycle = lifecycle.lock().unwrap();
        #[cfg(test)]
        if let Some(hook) = self.terminal_create_after_materialization_lock.lock().unwrap().clone()
        {
            hook();
        }
        #[cfg(test)]
        if let Some(hook) = self.terminal_create_after_workspace_reservation.lock().unwrap().clone()
        {
            hook();
        }
        let (workspace_key, inherited_pane) = {
            let state = self.state.lock().unwrap();
            let Some(workspace) = state.workspace_by_id(workspace) else {
                anyhow::bail!("unknown workspace {workspace}");
            };
            (workspace.key.clone(), workspace.active_screen_ref().map(|screen| screen.active_pane))
        };
        let inherited_cwd = inherited_pane.and_then(|pane| self.pane_cwd(pane));
        let surface = match reservation {
            Some(reservation) => self.spawn_surface_in_workspace_reserved(
                &workspace_key,
                cwd.or(inherited_cwd),
                size,
                argv,
                reservation,
            )?,
            None => {
                self.spawn_surface_in_workspace(&workspace_key, cwd.or(inherited_cwd), size, argv)?
            }
        };
        self.pending_workspace_surfaces.lock().unwrap().insert(surface.id, workspace);
        let pending_surface = self.pending_workspace_surface(surface.id);
        if let Some(name) = name {
            surface.set_name(Some(name));
        }
        if surface.terminal_host_identity().is_some() {
            // Launch/Ready intentionally releases the registry lock around
            // process startup. Re-read canonical placement after Ready and
            // hold registry -> state through the binding so a move committed
            // during launch is projected instead of the stale request target.
            let projected = self.bind_running_terminal_to_canonical_workspace(&surface);
            let (placement, canonical_workspace, changed) = match projected {
                Ok(projected) => projected,
                Err(error) => {
                    self.fail_hosted_terminal_attachment(
                        &surface,
                        "terminal-topology-attach-failed",
                        "topology-attach-failed",
                    )?;
                    return Err(error);
                }
            };
            let _ = surface.persist_host_workspace(&canonical_workspace);
            if changed {
                self.emit(MuxEvent::TreeChanged);
            }
            drop(pending_surface);
            drop(workspace_lifecycle);
            self.reap_if_dead(&surface);
            return Ok((placement, surface));
        }
        let notifications = self.surface_notifications();
        let active_at = self.next_active_at();
        let attached = (|| -> anyhow::Result<(RunPlacement, TreeDelta, bool)> {
            let mut state = self.state.lock().unwrap();
            if !state.surfaces.contains_key(&surface.id) {
                anyhow::bail!("terminal closed while its topology binding was being created");
            }
            let Some(wi) = state.workspace_index(workspace) else {
                anyhow::bail!("workspace disappeared while creating terminal");
            };
            let target = state.workspaces[wi].active_screen_ref().map(|screen| screen.active_pane);
            if let Some(target) = target {
                let Some((_, si)) = state.screen_of(target) else {
                    anyhow::bail!("workspace active pane disappeared while creating terminal");
                };
                let Some(pane) = state.panes.get_mut(&target) else {
                    anyhow::bail!("workspace active pane disappeared while creating terminal");
                };
                pane.tabs.push(surface.id);
                pane.active_tab = pane.tabs.len() - 1;
                pane.active_at = active_at;
                let index = pane.tabs.len() - 1;
                fence_layout_undo_for_tab_membership(&mut state, &[target]);
                let screen = state.workspaces[wi].screens[si].id;
                let entity = crate::server::tree_entity_json(
                    &state,
                    &notifications,
                    TreeDeltaKind::TabAdded,
                    surface.id,
                )
                .expect("new terminal tab is present in tree snapshot");
                Ok((
                    RunPlacement { surface: surface.id, pane: target, screen, workspace },
                    TreeDelta {
                        kind: TreeDeltaKind::TabAdded,
                        workspace,
                        screen: Some(screen),
                        pane: Some(target),
                        surface: Some(surface.id),
                        index: Some(index),
                        entity,
                        workspace_revision: None,
                    },
                    true,
                ))
            } else {
                let (pane_id, pane) = self.make_pane(surface.id)?;
                let screen_id = self.next_id();
                state.insert_pane(pane);
                stamp_pane_focus(self, &mut state, pane_id);
                state.workspaces[wi].screens.push(Screen {
                    id: screen_id,
                    public_id: ScreenPublicId::random()?,
                    name: None,
                    root: Node::Leaf(pane_id),
                    active_pane: pane_id,
                    zoomed_pane: None,
                    zellij_auto_layout: Some(vec![pane_id]),
                    viewport_splits: Default::default(),
                    viewport_base_width: None,
                    layout_columns: Vec::new(),
                    layout_revision: 0,
                    layout_undo: Default::default(),
                });
                state.workspaces[wi].active_screen = 0;
                let entity = crate::server::tree_entity_json(
                    &state,
                    &notifications,
                    TreeDeltaKind::ScreenAdded,
                    screen_id,
                )
                .expect("first workspace screen is present in tree snapshot");
                Ok((
                    RunPlacement {
                        surface: surface.id,
                        pane: pane_id,
                        screen: screen_id,
                        workspace,
                    },
                    TreeDelta {
                        kind: TreeDeltaKind::ScreenAdded,
                        workspace,
                        screen: Some(screen_id),
                        pane: None,
                        surface: None,
                        index: Some(0),
                        entity,
                        workspace_revision: None,
                    },
                    false,
                ))
            }
        })();
        let attached = match attached {
            Ok(attached) => attached,
            Err(error) => {
                drop(pending_surface);
                self.fail_hosted_terminal_attachment(
                    &surface,
                    "terminal-topology-attach-failed",
                    "topology-attach-failed",
                )?;
                return Err(error);
            }
        };
        drop(pending_surface);
        self.emit_tree_delta(attached.1, attached.2);
        drop(workspace_lifecycle);
        self.reap_if_dead(&surface);
        Ok((attached.0, surface))
    }

    /// Bind a just-launched hosted surface using the latest durable row, not
    /// the workspace requested before process launch. Holding registry ->
    /// state through projection is the create/move serialization fence.
    fn bind_running_terminal_to_canonical_workspace(
        &self,
        surface: &Arc<Surface>,
    ) -> anyhow::Result<(RunPlacement, String, bool)> {
        let identity = surface
            .terminal_host_identity()
            .ok_or_else(|| anyhow::anyhow!("created terminal has no host identity"))?;
        let registry = self.workspace_registry.lock().unwrap();
        let terminal = registry
            .terminal_record(&identity.terminal_id)?
            .ok_or_else(|| anyhow::anyhow!("created terminal has no registry row"))?;
        if terminal.lifecycle != TerminalLifecycle::Running {
            anyhow::bail!(
                "created terminal is {} before topology binding",
                terminal_lifecycle_name(terminal.lifecycle)
            );
        }
        let mut state = self.state.lock().unwrap();
        if !state.surfaces.contains_key(&surface.id) {
            anyhow::bail!("terminal closed while its topology binding was being created");
        }
        let (placement, changed) = self.project_terminal_to_workspace_in_state(
            &mut state,
            &identity.terminal_id,
            &terminal.workspace_key,
        )?;
        let placement =
            placement.ok_or_else(|| anyhow::anyhow!("created terminal has no live surface"))?;
        Ok((placement, terminal.workspace_key, changed))
    }

    /// Create a browser tab in a pane (default: the active pane). When
    /// the session has no workspaces yet, a workspace is created around
    /// the browser tab.
    pub fn new_browser_tab(
        self: &Arc<Self>,
        url: String,
        pane: Option<PaneId>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        let _creation = self.begin_surface_creation()?;
        let _creation_handoff = self.resource_creation_handoff.lock().unwrap();
        let selectors = {
            let state = self.state.lock().unwrap();
            let target = match pane {
                Some(id) => {
                    if !state.panes.contains_key(&id) {
                        anyhow::bail!("unknown pane {id}");
                    }
                    Some(id)
                }
                None => state.active_pane(),
            };
            if let Some(target) = target {
                drop(state);
                self.ordinary_pane_selectors(target)
                    .with_context(|| format!("unknown pane {target}"))?
            } else if let Some(workspace) = state.workspaces.get(state.active_workspace) {
                let workspace = workspace.id;
                drop(state);
                self.ordinary_workspace_selectors(workspace)
                    .with_context(|| format!("unknown workspace {workspace}"))?
            } else {
                Self::ordinary_resource_selectors()
            }
        };
        let mut fields = Map::from_iter([("url".into(), Value::String(url))]);
        if let Some((cols, rows)) = size {
            let (cell_width, cell_height) = self.cell_pixel_size();
            fields.insert("width_px".into(), Value::from(u64::from(cols) * u64::from(cell_width)));
            fields
                .insert("height_px".into(), Value::from(u64::from(rows) * u64::from(cell_height)));
        }
        let commit = self.commit_ordinary_topology_operation(
            ResourceOperation::TabCreateBrowser,
            selectors,
            fields,
        )?;
        self.emit_resource_topology_legacy_events(ResourceOperation::TabCreateBrowser, &commit);
        self.ordinary_created_surface(&commit)
    }

    pub(crate) fn new_browser_tab_reserved(
        self: &Arc<Self>,
        url: String,
        pane: Option<PaneId>,
        size: Option<(u16, u16)>,
        resource_identity: TabResourceIdentity,
        workspace_key: Option<String>,
    ) -> anyhow::Result<Arc<Surface>> {
        self.new_browser_tab_with_resource_identity(
            url,
            pane,
            size,
            Some(resource_identity),
            workspace_key,
        )
    }

    fn new_browser_tab_with_resource_identity(
        self: &Arc<Self>,
        url: String,
        pane: Option<PaneId>,
        size: Option<(u16, u16)>,
        resource_identity: Option<TabResourceIdentity>,
        workspace_key: Option<String>,
    ) -> anyhow::Result<Arc<Surface>> {
        let (target, empty_workspace) = {
            let state = self.state.lock().unwrap();
            let target = match pane {
                Some(id) => {
                    if !state.panes.contains_key(&id) {
                        anyhow::bail!("unknown pane {id}");
                    }
                    Some(id)
                }
                None => state.active_pane(),
            };
            let empty_workspace = target
                .is_none()
                .then(|| state.workspaces.get(state.active_workspace))
                .flatten()
                .filter(|workspace| workspace.screens.is_empty())
                .map(|workspace| workspace.id);
            (target, empty_workspace)
        };
        let Some(target) = target else {
            if let Some(workspace) = empty_workspace {
                return self.create_browser_surface_in_workspace(
                    workspace,
                    url,
                    size,
                    resource_identity,
                );
            }
            let workspace_key = match workspace_key {
                Some(workspace_key) => workspace_key,
                None => Self::new_workspace_key()?,
            };
            let surface = self.spawn_browser_surface_with_resource_identity(
                url,
                size,
                None,
                resource_identity,
            )?;
            let (pane_id, pane) = self.make_pane(surface.id)?;
            let screen_id = self.next_id();
            let ws_id = self.next_id();
            let notifications = self.surface_notifications();
            if let Some(workspace_id) = empty_workspace {
                let delta = {
                    let mut state = self.state.lock().unwrap();
                    let Some(workspace_index) =
                        state.workspaces.iter().position(|workspace| workspace.id == workspace_id)
                    else {
                        drop(state);
                        self.discard_spawned(vec![surface]);
                        anyhow::bail!("workspace disappeared while creating browser tab");
                    };
                    state.insert_pane(pane);
                    stamp_pane_focus(self, &mut state, pane_id);
                    state.workspaces[workspace_index].screens.push(Screen {
                        id: screen_id,
                        public_id: ScreenPublicId::random()?,
                        name: None,
                        root: Node::Leaf(pane_id),
                        active_pane: pane_id,
                        zoomed_pane: None,
                        zellij_auto_layout: Some(vec![pane_id]),
                        viewport_splits: Default::default(),
                        viewport_base_width: None,
                        layout_columns: Vec::new(),
                        layout_revision: 0,
                        layout_undo: Default::default(),
                    });
                    state.workspaces[workspace_index].active_screen = 0;
                    let entity = crate::server::tree_entity_json(
                        &state,
                        &notifications,
                        TreeDeltaKind::ScreenAdded,
                        screen_id,
                    )
                    .expect("first workspace screen is present in tree snapshot");
                    TreeDelta {
                        kind: TreeDeltaKind::ScreenAdded,
                        workspace: workspace_id,
                        screen: Some(screen_id),
                        pane: None,
                        surface: None,
                        index: Some(0),
                        entity,
                        workspace_revision: None,
                    }
                };
                self.emit(MuxEvent::TreeDelta(delta));
                self.reap_if_dead(&surface);
                return Ok(surface);
            }
            let mutation = WorkspaceMutation::local("cmux-tui");
            let workspace_public_id = WorkspacePublicId::random()?;
            let mut registry = self.workspace_registry.lock().unwrap();
            let delta = {
                let mut state = self.state.lock().unwrap();
                let name = Self::default_workspace_name(&state);
                let index = state.workspaces.len();
                let mut desired = self.registry_projection(&state);
                desired.push(RegistryWorkspace {
                    id: ws_id,
                    public_id: workspace_public_id.clone(),
                    key: workspace_key.clone(),
                    name: name.clone(),
                    group_key: self.session.clone(),
                });
                let commit = match registry.commit(
                    &mutation,
                    &serde_json::json!({
                        "op": "new-browser-workspace",
                        "workspace": ws_id,
                        "key": workspace_key.clone(),
                        "name": name,
                    }),
                    None,
                    None,
                    "workspace-added",
                    &workspace_key,
                    &desired,
                    &serde_json::json!({
                        "workspace": ws_id,
                        "workspace_id": workspace_public_id.as_str(),
                        "key": workspace_key.clone(),
                        "index": index,
                    }),
                ) {
                    Ok(commit) => commit,
                    Err(error) => {
                        drop(state);
                        drop(registry);
                        self.discard_spawned(vec![surface]);
                        return Err(error);
                    }
                };
                state.insert_pane(pane);
                stamp_pane_focus(self, &mut state, pane_id);
                state.push_workspace(Workspace {
                    id: ws_id,
                    public_id: workspace_public_id,
                    key: workspace_key,
                    name,
                    screens: vec![Screen {
                        id: screen_id,
                        public_id: ScreenPublicId::random()?,
                        name: None,
                        root: Node::Leaf(pane_id),
                        active_pane: pane_id,
                        zoomed_pane: None,
                        zellij_auto_layout: Some(vec![pane_id]),
                        viewport_splits: Default::default(),
                        viewport_base_width: None,
                        layout_columns: Vec::new(),
                        layout_revision: 0,
                        layout_undo: Default::default(),
                    }],
                    active_screen: 0,
                });
                state.active_workspace = state.workspaces.len() - 1;
                state.workspace_revision = commit.revision;
                let workspace_revision = commit.revision;
                let entity = crate::server::tree_entity_json(
                    &state,
                    &notifications,
                    TreeDeltaKind::WorkspaceAdded,
                    ws_id,
                )
                .expect("new workspace is present in tree snapshot");
                TreeDelta {
                    kind: TreeDeltaKind::WorkspaceAdded,
                    workspace: ws_id,
                    screen: None,
                    pane: None,
                    surface: None,
                    index: Some(index),
                    entity,
                    workspace_revision: Some(workspace_revision),
                }
            };
            let selection_resync = delta.index.is_some_and(|index| index > 0);
            self.emit_tree_delta(delta, selection_resync);
            self.reap_if_dead(&surface);
            return Ok(surface);
        };

        let surface =
            self.spawn_browser_surface_with_resource_identity(url, size, None, resource_identity)?;
        #[cfg(test)]
        if let Some(hook) = self.browser_tab_after_spawn.lock().unwrap().clone() {
            hook(surface.clone());
        }
        let active_at = self.next_active_at();
        let notifications = self.surface_notifications();
        let (attached, retired) = {
            let mut state = self.state.lock().unwrap();
            match state.panes.get_mut(&target) {
                Some(pane) => {
                    pane.tabs.push(surface.id);
                    pane.active_tab = pane.tabs.len() - 1;
                    pane.active_at = active_at;
                    let index = pane.tabs.len() - 1;
                    fence_layout_undo_for_tab_membership(&mut state, &[target]);
                    let (wi, si) = state.screen_of(target).expect("live pane belongs to a screen");
                    let workspace = state.workspaces[wi].id;
                    let screen = state.workspaces[wi].screens[si].id;
                    let entity = crate::server::tree_entity_json(
                        &state,
                        &notifications,
                        TreeDeltaKind::TabAdded,
                        surface.id,
                    )
                    .expect("new browser tab is present in tree snapshot");
                    (
                        Some(TreeDelta {
                            kind: TreeDeltaKind::TabAdded,
                            workspace,
                            screen: Some(screen),
                            pane: Some(target),
                            surface: Some(surface.id),
                            index: Some(index),
                            entity,
                            workspace_revision: None,
                        }),
                        None,
                    )
                }
                None => (None, take_surface_for_retirement(self, &mut state, surface.id)),
            }
        };
        let Some(delta) = attached else {
            if let Some(retired) = retired {
                self.retire_surface_runtime(retired);
            }
            anyhow::bail!("pane disappeared while creating browser tab");
        };
        self.emit_tree_delta(delta, true);
        self.reap_if_dead(&surface);
        Ok(surface)
    }

    fn create_browser_surface_in_workspace(
        self: &Arc<Self>,
        workspace: WorkspaceId,
        url: String,
        size: Option<(u16, u16)>,
        resource_identity: Option<TabResourceIdentity>,
    ) -> anyhow::Result<Arc<Surface>> {
        let _creation = self.begin_surface_creation()?;
        let lifecycle = self.workspace_lifecycle(workspace);
        let workspace_lifecycle = lifecycle.lock().unwrap();
        if self.state.lock().unwrap().workspace_by_id(workspace).is_none() {
            anyhow::bail!("unknown workspace {workspace}");
        }
        let surface = self.spawn_browser_surface_with_resource_identity(
            url,
            size,
            Some(workspace),
            resource_identity,
        )?;
        let pending_surface = self.pending_workspace_surface(surface.id);
        let notifications = self.surface_notifications();
        let active_at = self.next_active_at();
        let (attachment, retired) = {
            let mut state = self.state.lock().unwrap();
            let attachment = 'attach: {
                let Some(wi) = state.workspace_index(workspace) else {
                    break 'attach Err("workspace disappeared while creating browser tab");
                };
                let target =
                    state.workspaces[wi].active_screen_ref().map(|screen| screen.active_pane);
                if let Some(target) = target {
                    let Some((_, si)) = state.screen_of(target) else {
                        break 'attach Err(
                            "workspace active pane disappeared while creating browser tab",
                        );
                    };
                    let Some(pane) = state.panes.get_mut(&target) else {
                        break 'attach Err(
                            "workspace active pane disappeared while creating browser tab",
                        );
                    };
                    pane.tabs.push(surface.id);
                    pane.active_tab = pane.tabs.len() - 1;
                    pane.active_at = active_at;
                    let index = pane.tabs.len() - 1;
                    fence_layout_undo_for_tab_membership(&mut state, &[target]);
                    let screen = state.workspaces[wi].screens[si].id;
                    let entity = crate::server::tree_entity_json(
                        &state,
                        &notifications,
                        TreeDeltaKind::TabAdded,
                        surface.id,
                    )
                    .expect("new browser tab is present in tree snapshot");
                    Ok((
                        TreeDelta {
                            kind: TreeDeltaKind::TabAdded,
                            workspace,
                            screen: Some(screen),
                            pane: Some(target),
                            surface: Some(surface.id),
                            index: Some(index),
                            entity,
                            workspace_revision: None,
                        },
                        true,
                    ))
                } else {
                    let (pane_id, pane) = self.make_pane(surface.id)?;
                    let screen_id = self.next_id();
                    state.insert_pane(pane);
                    stamp_pane_focus(self, &mut state, pane_id);
                    state.workspaces[wi].screens.push(Screen {
                        id: screen_id,
                        public_id: ScreenPublicId::random()?,
                        name: None,
                        root: Node::Leaf(pane_id),
                        active_pane: pane_id,
                        zoomed_pane: None,
                        zellij_auto_layout: Some(vec![pane_id]),
                        viewport_splits: Default::default(),
                        viewport_base_width: None,
                        layout_columns: Vec::new(),
                        layout_revision: 0,
                        layout_undo: Default::default(),
                    });
                    state.workspaces[wi].active_screen = 0;
                    let entity = crate::server::tree_entity_json(
                        &state,
                        &notifications,
                        TreeDeltaKind::ScreenAdded,
                        screen_id,
                    )
                    .expect("first browser screen is present in tree snapshot");
                    Ok((
                        TreeDelta {
                            kind: TreeDeltaKind::ScreenAdded,
                            workspace,
                            screen: Some(screen_id),
                            pane: None,
                            surface: None,
                            index: Some(0),
                            entity,
                            workspace_revision: None,
                        },
                        false,
                    ))
                }
            };
            let retired = attachment
                .is_err()
                .then(|| take_surface_for_retirement(self, &mut state, surface.id))
                .flatten();
            (attachment, retired)
        };
        if let Some(retired) = retired {
            self.retire_surface_runtime(retired);
        }
        let (delta, selection_resync) = attachment.map_err(anyhow::Error::msg)?;
        drop(pending_surface);
        self.emit_tree_delta(delta, selection_resync);
        drop(workspace_lifecycle);
        self.reap_if_dead(&surface);
        Ok(surface)
    }

    pub fn adopt_browser_target(
        self: &Arc<Self>,
        opener_surface: SurfaceId,
        target_id: String,
        url: String,
        runtime: Arc<BrowserRuntime>,
    ) -> anyhow::Result<bool> {
        let _creation = self.begin_surface_creation()?;
        let (pane_id, size) = {
            let state = self.state.lock().unwrap();
            let Some(pane_id) = state.pane_of(opener_surface) else {
                return Ok(false);
            };
            let size = state.surfaces.get(&opener_surface).map(|surface| surface.size());
            (pane_id, size)
        };
        let id = self.next_id();
        let mut owner_reservation = self.reserve_surface_owner()?;
        let opts = self.surface_options.lock().unwrap().clone();
        let size = size.unwrap_or((opts.cols, opts.rows));
        let cell_pixels = *self.cell_pixels.lock().unwrap();
        let surface =
            browser::new_surface(id, url.clone(), size, cell_pixels, &opts, Arc::downgrade(self))?;
        let active_at = self.next_active_at();
        let attached = match self.attach_browser_surface_to_pane_or_kill(
            pane_id,
            &surface,
            active_at,
            &mut owner_reservation,
        ) {
            BrowserSurfaceAttach::MissingPane | BrowserSurfaceAttach::Rejected => return Ok(false),
            BrowserSurfaceAttach::Attached(delta) => delta,
        };
        let identity = surface
            .resource_identity()
            .context("adopted browser surface omitted its public identity")?;
        let result = serde_json::json!({
            "tab_id":identity.tab_id,
            "browser_id":identity.content_id,
        });
        if let Err(error) =
            self.commit_ordinary_full_resource_projection("browser.target.adopt", result)
        {
            let rollback = self.close_surface_for_resource_effect(surface.id);
            return match rollback {
                Ok(true) => Err(error.context("could not persist adopted browser target")),
                Ok(false) => Err(error.context(
                    "could not persist adopted browser target and its tab disappeared during rollback",
                )),
                Err(rollback) => Err(error.context(format!(
                    "could not persist adopted browser target; rollback also failed: {rollback:#}"
                ))),
            };
        }
        if let Some(delta) = attached {
            self.emit_tree_delta(delta, true);
        } else {
            self.emit(MuxEvent::TreeChanged);
        }
        self.start_browser_bootstrap(
            surface,
            BrowserBootstrap::ExistingTarget { target_id, url },
            Some(runtime),
        );
        Ok(true)
    }

    fn attach_browser_surface_to_pane_or_kill(
        &self,
        pane_id: PaneId,
        surface: &Arc<Surface>,
        active_at: u64,
        owner_reservation: &mut SurfaceOwnerReservation<'_>,
    ) -> BrowserSurfaceAttach {
        let notifications = self.surface_notifications();
        let attached = {
            let mut state = self.state.lock().unwrap();
            if !state.panes.contains_key(&pane_id) {
                BrowserSurfaceAttach::MissingPane
            } else if insert_reserved_surface_checked(
                self,
                &mut state,
                surface.clone(),
                owner_reservation,
            )
            .is_err()
            {
                BrowserSurfaceAttach::Rejected
            } else {
                let pane = state.panes.get_mut(&pane_id).expect("pane existence was checked");
                pane.tabs.push(surface.id);
                pane.active_tab = pane.tabs.len() - 1;
                pane.active_at = active_at;
                let delta = (|| {
                    let (wi, si) = state.screen_of(pane_id)?;
                    let pane = state.panes.get(&pane_id)?;
                    let index = pane.tabs.iter().position(|id| *id == surface.id)?;
                    let entity = crate::server::tree_entity_json(
                        &state,
                        &notifications,
                        TreeDeltaKind::TabAdded,
                        surface.id,
                    )?;
                    Some(TreeDelta {
                        kind: TreeDeltaKind::TabAdded,
                        workspace: state.workspaces[wi].id,
                        screen: Some(state.workspaces[wi].screens[si].id),
                        pane: Some(pane_id),
                        surface: Some(surface.id),
                        index: Some(index),
                        entity,
                        workspace_revision: None,
                    })
                })();
                BrowserSurfaceAttach::Attached(delta)
            }
        };
        if matches!(attached, BrowserSurfaceAttach::MissingPane | BrowserSurfaceAttach::Rejected) {
            self.retire_reserved_surface_runtime(surface.clone(), owner_reservation);
        }
        attached
    }

    /// Working directory of a pane's active surface, if reported.
    fn pane_cwd(&self, pane: PaneId) -> Option<String> {
        let surface = {
            let state = self.state.lock().unwrap();
            let active = state.panes.get(&pane)?.active_surface()?;
            state.surfaces.get(&active).cloned()
        };
        surface.and_then(|surface| surface.pwd().or_else(|| surface.spawn_cwd()))
    }

    fn workspace_key_for_pane(&self, pane: PaneId) -> Option<String> {
        let state = self.state.lock().unwrap();
        let (workspace, _) = state.screen_of(pane)?;
        Some(state.workspaces[workspace].key.clone())
    }

    /// Split the screen containing `target`, putting a new single-tab
    /// pane after it. Returns the new pane's surface. `size` is the
    /// expected content size of the new pane, when the caller knows it.
    pub fn split(
        self: &Arc<Self>,
        target: PaneId,
        dir: SplitDir,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        let _creation = self.begin_surface_creation()?;
        let _creation_handoff = self.resource_creation_handoff.lock().unwrap();
        let selectors = self
            .ordinary_pane_selectors(target)
            .with_context(|| format!("unknown pane {target}"))?;
        let direction = match dir {
            SplitDir::Right => "right",
            SplitDir::Down => "down",
        };
        let mut fields = Map::from_iter([("direction".into(), Value::String(direction.into()))]);
        Self::insert_cell_size(&mut fields, size);
        let commit = self.commit_ordinary_topology_operation(
            ResourceOperation::PaneSplit,
            selectors,
            fields,
        )?;
        self.emit_resource_topology_legacy_events(ResourceOperation::PaneSplit, &commit);
        self.ordinary_created_surface(&commit)
    }

    /// Add a terminal as a viewport-width column after the target's column.
    ///
    /// Updated frontends render the new column at `width` times their own
    /// viewport width. The ordinary split ratio remains valid fallback data
    /// for older clients.
    pub fn new_pane_right(
        self: &Arc<Self>,
        target: PaneId,
        width: f32,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        let _creation = self.begin_surface_creation()?;
        let _creation_handoff = self.resource_creation_handoff.lock().unwrap();
        if !width.is_finite()
            || !(MIN_VIEWPORT_PANE_WIDTH..=MAX_VIEWPORT_PANE_WIDTH).contains(&width)
        {
            return Err(ViewportWidthError::OutOfRange { width }.into());
        }
        let selectors = self
            .ordinary_pane_selectors(target)
            .with_context(|| format!("unknown pane {target}"))?;
        let mut fields = Map::from_iter([
            ("direction".into(), Value::String("right".into())),
            ("viewport_width".into(), Value::from(width)),
        ]);
        Self::insert_cell_size(&mut fields, size);
        let commit = self
            .commit_ordinary_topology_operation(ResourceOperation::PaneSplit, selectors, fields)
            .map_err(|error| {
                eprintln!("cmux-tui: viewport pane PTY creation failed: {error:#}");
                anyhow::anyhow!("pane creation failed")
            })?;
        self.emit_resource_topology_legacy_events(ResourceOperation::PaneSplit, &commit);
        self.ordinary_created_surface(&commit)
    }

    /// Create a pane and reapply Zellij's default pane distribution to the
    /// containing screen. The screen stores creation order independently of
    /// the mutable split tree, so swaps and directional splits cannot reorder
    /// terminals when automatic layout resumes.
    pub fn new_pane(
        self: &Arc<Self>,
        target: PaneId,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        let _creation = self.begin_surface_creation()?;
        let _creation_handoff = self.resource_creation_handoff.lock().unwrap();
        let selectors = self
            .ordinary_pane_selectors(target)
            .with_context(|| format!("unknown pane {target}"))?;
        let mut fields = Map::new();
        Self::insert_cell_size(&mut fields, size);
        let commit = self.commit_ordinary_topology_operation(
            ResourceOperation::PaneCreate,
            selectors,
            fields,
        )?;
        self.emit_resource_topology_legacy_events(ResourceOperation::PaneCreate, &commit);
        self.ordinary_created_surface(&commit)
    }

    /// Close one tab. When it was the pane's last tab, the pane collapses
    /// out of its split tree. Empty workspace containers remain durable;
    /// only an explicit close-workspace mutation removes a workspace.
    pub fn close_surface(self: &Arc<Self>, target: SurfaceId) -> anyhow::Result<bool> {
        let Some(selectors) = self.ordinary_tab_selectors(target) else { return Ok(false) };
        let commit = self
            .commit_ordinary_topology_operation(ResourceOperation::TabClose, selectors, Map::new())
            .with_context(|| format!("close surface {target}"))?;
        self.emit_resource_topology_legacy_events(ResourceOperation::TabClose, &commit);
        Ok(true)
    }

    pub(crate) fn close_surface_for_resource_effect(
        &self,
        target: SurfaceId,
    ) -> anyhow::Result<bool> {
        if let Some(surface) = self.surface(target)
            && let Err(error) = self.tombstone_hosted_surface(&surface)
        {
            return Err(error);
        }
        Ok(self.remove_surface_after_registry(target))
    }

    fn remove_surface_after_registry(&self, target: SurfaceId) -> bool {
        let notifications = self.surface_notifications();
        let remove = || {
            let mut state = self.state.lock().unwrap();
            let selection_before = active_tree_selection(&state);
            let changed_screen = surface_screen_id(&state, target);
            let delta = close_surface_delta(&state, &notifications, target);
            let (removed, split_index_dirty) = remove_surface(self, &mut state, target);
            if split_index_dirty {
                Self::rebuild_split_screen_index(&mut state);
            }
            let empty_revision = state.workspaces.is_empty().then_some(state.workspace_revision);
            let selection_resync =
                empty_revision.is_none() && selection_before != active_tree_selection(&state);
            let changed = removed.is_some() || delta.is_some();
            (
                removed,
                changed_screen.into_iter().collect::<Vec<_>>(),
                empty_revision,
                delta,
                selection_resync,
                changed,
            )
        };
        let (removed, changed_screens, empty_revision, delta, selection_resync, changed) = loop {
            let Some(workspace) = self.surface_workspace(target) else {
                break remove();
            };
            let lifecycle = self.workspace_lifecycle(workspace);
            let workspace_lifecycle = lifecycle.lock().unwrap();
            if self.surface_workspace(target) != Some(workspace) {
                drop(workspace_lifecycle);
                continue;
            }
            let result = remove();
            drop(workspace_lifecycle);
            break result;
        };
        if let Some(surface) = &removed {
            self.purge_surface_side_tables(surface.id);
            self.retire_surface_runtime(surface.clone());
        }
        if let Some(delta) = delta {
            self.emit_tree_delta(delta, selection_resync);
        } else if removed.is_some() {
            self.emit(MuxEvent::TreeChanged);
        }
        if removed.is_some() || !changed_screens.is_empty() {
            for screen in changed_screens {
                self.emit(MuxEvent::LayoutChanged(screen));
            }
        }
        self.emit_empty_if_current(empty_revision);
        changed
    }

    /// Close a pane or screen while holding the target workspace's lifecycle
    /// lock from revalidation through the durable terminal and topology
    /// commits. This keeps a concurrent terminal creation from attaching to a
    /// target after its close snapshot was taken.
    fn close_tree_target(&self, target: TreeCloseTarget) -> anyhow::Result<bool> {
        let notifications = self.surface_notifications();
        let result = loop {
            let Some(workspace) =
                self.with_state(|state| Self::workspace_for_tree_target_in_state(state, target))
            else {
                return Ok(false);
            };
            let lifecycle = self.workspace_lifecycle(workspace);
            let workspace_lifecycle = lifecycle.lock().unwrap();
            if self.with_state(|state| Self::workspace_for_tree_target_in_state(state, target))
                != Some(workspace)
            {
                drop(workspace_lifecycle);
                continue;
            }
            let mutation = WorkspaceMutation::local("cmux-tui");
            let mut registry = self.workspace_registry.lock().unwrap();
            let result = (|| -> anyhow::Result<Option<_>> {
                let mut state = self.state.lock().unwrap();
                let selection_before = active_tree_selection(&state);
                let (tabs, delta) = match target {
                    TreeCloseTarget::Pane(target) => {
                        let Some(pane) = state.panes.get(&target) else { return Ok(None) };
                        (
                            pane.tabs.clone(),
                            close_pane_delta(&state, &notifications, target)
                                .expect("live pane has a close delta"),
                        )
                    }
                    TreeCloseTarget::Screen(target) => {
                        let Some(screen) = state
                            .workspaces
                            .iter()
                            .flat_map(|workspace| &workspace.screens)
                            .find(|screen| screen.id == target)
                        else {
                            return Ok(None);
                        };
                        (
                            screen_tabs(&state, screen),
                            close_screen_delta(&state, &notifications, target)
                                .expect("live screen has a close delta"),
                        )
                    }
                };
                let hosted = tabs
                    .iter()
                    .filter_map(|id| state.surfaces.get(id))
                    .filter_map(|surface| self.resource_terminal_host_identity(surface))
                    .map(|identity| (identity.terminal_id, Some(identity.incarnation)))
                    .collect::<Vec<_>>();
                let closed_public_ids = Self::terminal_public_ids_for_hosted(&registry, &hosted)?;
                let batch = registry.close_terminals_atomically(&mutation, &hosted)?;
                let changed_screens = unique_screen_ids(
                    tabs.iter().filter_map(|surface| surface_screen_id(&state, *surface)),
                );
                let mut removed = Vec::new();
                let mut split_index_dirty = false;
                for surface in tabs {
                    let (surface, topology_changed) = remove_surface(self, &mut state, surface);
                    split_index_dirty |= topology_changed;
                    if let Some(surface) = surface {
                        removed.push(surface);
                    }
                }
                if split_index_dirty {
                    Self::rebuild_split_screen_index(&mut state);
                }
                let tree_removed = match target {
                    TreeCloseTarget::Pane(target) => !state.panes.contains_key(&target),
                    TreeCloseTarget::Screen(target) => !state
                        .workspaces
                        .iter()
                        .flat_map(|workspace| &workspace.screens)
                        .any(|screen| screen.id == target),
                };
                let empty_revision =
                    state.workspaces.is_empty().then_some(state.workspace_revision);
                let selection_resync =
                    empty_revision.is_none() && selection_before != active_tree_selection(&state);
                Ok(Some((
                    removed,
                    changed_screens,
                    empty_revision,
                    delta,
                    tree_removed,
                    selection_resync,
                    batch,
                    closed_public_ids,
                )))
            })();
            let result = result?;
            if let Some((_, _, _, _, _, _, batch, _)) = &result
                && batch.closed != 0
            {
                self.emit_terminal_registry_changed(&registry, batch.revision);
            }
            drop(registry);
            drop(workspace_lifecycle);
            break result;
        };
        let Some((
            removed,
            changed_screens,
            empty_revision,
            delta,
            tree_removed,
            selection_resync,
            _,
            closed_public_ids,
        )) = result
        else {
            return Ok(false);
        };
        self.notify_terminal_exit_waiters(closed_public_ids);
        for surface in &removed {
            self.purge_surface_side_tables(surface.id);
        }
        self.retire_surface_runtimes(removed);
        if tree_removed {
            self.emit_tree_delta(delta, selection_resync);
            for screen in changed_screens {
                self.emit(MuxEvent::LayoutChanged(screen));
            }
        }
        self.emit_empty_if_current(empty_revision);
        Ok(true)
    }

    /// Close a pane and every tab in it.
    pub fn close_pane(self: &Arc<Self>, target: PaneId) -> anyhow::Result<bool> {
        let Some(selectors) = self.ordinary_pane_selectors(target) else { return Ok(false) };
        let commit = self
            .commit_ordinary_topology_operation(ResourceOperation::PaneClose, selectors, Map::new())
            .with_context(|| format!("close pane {target}"))?;
        self.emit_resource_topology_legacy_events(ResourceOperation::PaneClose, &commit);
        Ok(true)
    }

    pub(crate) fn close_pane_for_resource_effect(&self, target: PaneId) -> anyhow::Result<bool> {
        self.close_tree_target(TreeCloseTarget::Pane(target))
            .with_context(|| format!("close pane {target}"))
    }

    /// Close a screen and every pane/tab in it.
    pub fn close_screen(self: &Arc<Self>, target: ScreenId) -> anyhow::Result<bool> {
        let Some(selectors) = self.ordinary_screen_selectors(target) else { return Ok(false) };
        let commit = self
            .commit_ordinary_topology_operation(
                ResourceOperation::ScreenClose,
                selectors,
                Map::new(),
            )
            .with_context(|| format!("close screen {target}"))?;
        self.emit_resource_topology_legacy_events(ResourceOperation::ScreenClose, &commit);
        Ok(true)
    }

    pub(crate) fn close_screen_for_resource_effect(
        &self,
        target: ScreenId,
    ) -> anyhow::Result<bool> {
        self.close_tree_target(TreeCloseTarget::Screen(target))
            .with_context(|| format!("close screen {target}"))
    }

    /// Close a workspace and every screen/pane/tab in it.
    pub fn close_workspace(&self, target: WorkspaceId) -> bool {
        self.close_workspace_at_revision(target, None)
            .map(|revision| revision.is_some())
            .unwrap_or(false)
    }

    /// Atomically close one workspace if the caller's registry snapshot is
    /// still current. Returns the resulting revision when the workspace was
    /// present and closed.
    pub fn close_workspace_at_revision(
        &self,
        target: WorkspaceId,
        expected_revision: Option<u64>,
    ) -> anyhow::Result<Option<u64>> {
        Ok(self
            .close_workspace_selector_at_revision(Some(target), None, expected_revision)?
            .map(|(_, _, revision)| revision))
    }

    pub(crate) fn close_workspace_selector_at_revision(
        &self,
        id: Option<WorkspaceId>,
        key: Option<&str>,
        expected_revision: Option<u64>,
    ) -> anyhow::Result<Option<(WorkspaceId, String, u64)>> {
        self.close_workspace_selector_with_authority(
            id,
            key,
            expected_revision,
            WorkspaceMutationAuthority::Ordinary,
            true,
        )
    }

    pub(crate) fn close_workspace_at_revision_for_resource_effect(
        &self,
        target: WorkspaceId,
    ) -> anyhow::Result<Option<u64>> {
        Ok(self
            .close_workspace_selector_with_authority(
                Some(target),
                None,
                None,
                WorkspaceMutationAuthority::Ordinary,
                false,
            )?
            .map(|(_, _, revision)| revision))
    }

    pub fn close_workspace_with_mutation(
        &self,
        target: Option<WorkspaceId>,
        requested_key: Option<&str>,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
    ) -> anyhow::Result<WorkspaceMutationResult> {
        let _creation_handoff = self.resource_creation_handoff.lock().unwrap();
        let _creation_fence = self.resource_creation_execution.lock().unwrap();
        let authority = self.authorize_workspace_lifecycle_mutation(
            WorkspaceMutationAuthority::Ordinary,
            "close",
        )?;
        let result = self.close_workspace_with_mutation_inner(
            target,
            requested_key,
            expected_generation,
            expected_revision,
            mutation,
            true,
        );
        drop(authority);
        result
    }

    pub fn close_provider_managed_workspace(
        &self,
        id: WorkspaceId,
        key: &str,
    ) -> anyhow::Result<Option<u64>> {
        Ok(self
            .close_workspace_selector_with_authority(
                Some(id),
                Some(key),
                None,
                WorkspaceMutationAuthority::TrustedProvider,
                true,
            )?
            .map(|(_, _, revision)| revision))
    }

    pub(crate) fn close_provider_managed_workspace_authorized(
        &self,
        id: WorkspaceId,
        key: &str,
        authority: &str,
    ) -> anyhow::Result<Option<u64>> {
        Ok(self
            .close_workspace_selector_with_authority(
                Some(id),
                Some(key),
                None,
                WorkspaceMutationAuthority::ProviderCredential(authority),
                true,
            )?
            .map(|(_, _, revision)| revision))
    }

    fn close_workspace_selector_with_authority(
        &self,
        id: Option<WorkspaceId>,
        key: Option<&str>,
        expected_revision: Option<u64>,
        authorization: WorkspaceMutationAuthority<'_>,
        project_resource: bool,
    ) -> anyhow::Result<Option<(WorkspaceId, String, u64)>> {
        let _creation_handoff =
            project_resource.then(|| self.resource_creation_handoff.lock().unwrap());
        let _creation_fence =
            project_resource.then(|| self.resource_creation_execution.lock().unwrap());
        let authority = self.authorize_workspace_lifecycle_mutation(authorization, "close")?;
        let resolved = {
            let state = self.state.lock().unwrap();
            Self::require_workspace_revision(&state, expected_revision)?;
            Self::resolve_workspace_selector(&state, id, key)?
        };
        let Some((resolved_target, _)) = resolved else {
            return Ok(None);
        };
        let mutation = WorkspaceMutation::local("cmux-tui");
        let result = self.close_workspace_with_mutation_inner(
            id,
            key,
            None,
            expected_revision,
            &mutation,
            project_resource,
        );
        drop(authority);
        let result = result?;
        Ok(Some((result.workspace.unwrap_or(resolved_target), result.key, result.revision)))
    }

    fn close_workspace_with_mutation_inner(
        &self,
        target: Option<WorkspaceId>,
        requested_key: Option<&str>,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
        project_resource: bool,
    ) -> anyhow::Result<WorkspaceMutationResult> {
        let fingerprint = serde_json::json!({
            "op": "close-workspace",
            "workspace": target,
            "key": requested_key,
        });
        {
            let registry = self.workspace_registry.lock().unwrap();
            if let Some(commit) = registry.replay(mutation, &fingerprint)? {
                let result = workspace_mutation_result(&commit)?;
                let key = result.key.clone();
                drop(registry);
                self.terminate_tombstoned_workspace_hosts(&key);
                return Ok(result);
            }
        }
        loop {
            let resolved_target = {
                let state = self.state.lock().unwrap();
                Self::require_workspace_revision(&state, expected_revision)?;
                let index = resolve_workspace_index(&state, target, requested_key)?;
                state.workspaces[index].id
            };
            #[cfg(test)]
            if let Some(hook) =
                self.workspace_close_after_selector_resolution.lock().unwrap().clone()
            {
                hook();
            }
            let lifecycle = self.workspace_lifecycle(resolved_target);
            let workspace_lifecycle = lifecycle.lock().unwrap();
            let current_target = {
                let state = self.state.lock().unwrap();
                Self::require_workspace_revision(&state, expected_revision)?;
                let index = resolve_workspace_index(&state, target, requested_key)?;
                state.workspaces[index].id
            };
            if current_target != resolved_target {
                drop(workspace_lifecycle);
                continue;
            }
            let result = self.close_workspace_with_mutation_locked(
                target,
                requested_key,
                expected_generation,
                expected_revision,
                mutation,
                &fingerprint,
                resolved_target,
                project_resource,
            );
            drop(workspace_lifecycle);
            return result;
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn close_workspace_with_mutation_locked(
        &self,
        target: Option<WorkspaceId>,
        requested_key: Option<&str>,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
        resolved_target: WorkspaceId,
        project_resource: bool,
    ) -> anyhow::Result<WorkspaceMutationResult> {
        let notifications = self.surface_notifications();
        let mut registry = self.workspace_registry.lock().unwrap();
        if let Some(commit) = registry.replay(mutation, fingerprint)? {
            let result = workspace_mutation_result(&commit)?;
            let key = result.key.clone();
            drop(registry);
            self.terminate_tombstoned_workspace_hosts(&key);
            return Ok(result);
        }
        let terminal_revision_before = registry.terminal_snapshot()?.revision;
        let (
            removed,
            delta,
            empty_revision,
            selection_resync,
            result,
            closed_workspace_key,
            closed_public_ids,
        ) = {
            let mut state = self.state.lock().unwrap();
            Self::require_workspace_revision(&state, expected_revision)?;
            let index = resolve_workspace_index(&state, target, requested_key)?;
            let workspace_id = state.workspaces[index].id;
            if workspace_id != resolved_target {
                anyhow::bail!("workspace selector changed while closing");
            }
            let previous_active = state.active_pane();
            let key = state.workspaces[index].key.clone();
            let closed_public_ids = registry.terminal_resource_ids_in_workspace(&key)?;
            let mut desired = self.registry_projection(&state);
            desired.remove(index);
            let desired_active_workspace = if state.active_workspace == index {
                desired.last().map(|workspace| &workspace.public_id)
            } else {
                state.workspaces.get(state.active_workspace).map(|workspace| &workspace.public_id)
            };
            let committed_result = serde_json::json!({
                "workspace": workspace_id,
                "key": key,
                "index": index,
                "changed": true,
            });
            let commit = if project_resource {
                registry.commit_with_active_workspace(
                    mutation,
                    fingerprint,
                    expected_generation,
                    expected_revision,
                    "workspace-closed",
                    &key,
                    &desired,
                    desired_active_workspace,
                    &committed_result,
                )?
            } else {
                registry.commit_for_resource_effect(
                    mutation,
                    fingerprint,
                    expected_generation,
                    expected_revision,
                    "workspace-closed",
                    &key,
                    &desired,
                    desired_active_workspace,
                    &committed_result,
                )?
            };
            let resource_revision = project_resource
                .then(|| registry.snapshot().map(|snapshot| snapshot.resource_revision))
                .transpose()?;
            let mut delta = close_workspace_delta(&state, &notifications, workspace_id)
                .expect("live workspace has a close delta");
            let was_active = state.active_workspace == index;
            let active_id =
                state.workspaces.get(state.active_workspace).map(|workspace| workspace.id);
            let workspace = state.remove_workspace(index);
            let mut pane_ids = Vec::new();
            for screen in &workspace.screens {
                screen.root.pane_ids(&mut pane_ids);
            }
            let mut removed = Vec::new();
            for pane_id in pane_ids {
                if let Some(pane) = state.remove_pane(pane_id) {
                    for surface in pane.tabs {
                        if let Some(surface) =
                            take_surface_for_retirement(self, &mut state, surface)
                        {
                            removed.push(surface);
                        }
                    }
                }
            }
            state.active_workspace = active_id
                .and_then(|id| state.workspace_index(id))
                .unwrap_or_else(|| state.workspaces.len().saturating_sub(1));
            stamp_changed_active_pane(self, &mut state, previous_active);
            Self::rebuild_split_screen_index(&mut state);
            state.workspace_revision = commit.revision;
            if let Some(resource_revision) = resource_revision {
                state.resource_revision = resource_revision;
            }
            delta.workspace_revision = Some(commit.revision);
            let empty_revision = state.workspaces.is_empty().then_some(state.workspace_revision);
            let selection_resync = was_active && empty_revision.is_none();
            let result = workspace_mutation_result(&commit)?;
            (removed, delta, empty_revision, selection_resync, result, key, closed_public_ids)
        };
        let terminal_revision_after = registry.terminal_snapshot()?.revision;
        if terminal_revision_after != terminal_revision_before {
            self.emit_terminal_registry_changed(&registry, terminal_revision_after);
        }
        drop(registry);
        self.notify_terminal_exit_waiters(closed_public_ids);
        if project_resource {
            self.publish_resource_event();
        }
        for surface in &removed {
            self.purge_surface_side_tables(surface.id);
        }
        self.retire_surface_runtimes(removed);
        self.terminate_tombstoned_workspace_hosts(&closed_workspace_key);
        self.emit_tree_delta(delta, selection_resync);
        self.emit_empty_if_current(empty_revision);
        Ok(result)
    }

    pub fn rename_workspace(&self, target: WorkspaceId, name: String) -> bool {
        self.rename_workspace_at_revision(target, name, None)
            .map(|revision| revision.is_some())
            .unwrap_or(false)
    }

    pub fn rename_workspace_at_revision(
        &self,
        target: WorkspaceId,
        name: String,
        expected_revision: Option<u64>,
    ) -> anyhow::Result<Option<u64>> {
        Ok(self
            .rename_workspace_selector_with_authority(
                Some(target),
                None,
                name,
                expected_revision,
                WorkspaceMutationAuthority::Ordinary,
            )?
            .map(|(_, _, revision)| revision))
    }

    #[allow(clippy::too_many_arguments)]
    pub fn rename_workspace_with_mutation(
        &self,
        target: Option<WorkspaceId>,
        requested_key: Option<&str>,
        name: String,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
    ) -> anyhow::Result<WorkspaceMutationResult> {
        let authority = self.authorize_workspace_lifecycle_mutation(
            WorkspaceMutationAuthority::Ordinary,
            "rename",
        )?;
        let result = self.rename_workspace_with_mutation_inner(
            target,
            requested_key,
            name,
            expected_generation,
            expected_revision,
            mutation,
        );
        drop(authority);
        result
    }

    pub fn rename_provider_managed_workspace(
        &self,
        id: WorkspaceId,
        key: &str,
        name: String,
    ) -> anyhow::Result<Option<u64>> {
        Ok(self
            .rename_workspace_selector_with_authority(
                Some(id),
                Some(key),
                name,
                None,
                WorkspaceMutationAuthority::TrustedProvider,
            )?
            .map(|(_, _, revision)| revision))
    }

    pub(crate) fn rename_provider_managed_workspace_authorized(
        &self,
        id: WorkspaceId,
        key: &str,
        name: String,
        authority: &str,
    ) -> anyhow::Result<Option<u64>> {
        Ok(self
            .rename_workspace_selector_with_authority(
                Some(id),
                Some(key),
                name,
                None,
                WorkspaceMutationAuthority::ProviderCredential(authority),
            )?
            .map(|(_, _, revision)| revision))
    }

    fn rename_workspace_selector_with_authority(
        &self,
        id: Option<WorkspaceId>,
        key: Option<&str>,
        name: String,
        expected_revision: Option<u64>,
        authorization: WorkspaceMutationAuthority<'_>,
    ) -> anyhow::Result<Option<(WorkspaceId, String, u64)>> {
        let authority = self.authorize_workspace_lifecycle_mutation(authorization, "rename")?;
        let resolved = {
            let state = self.state.lock().unwrap();
            Self::require_workspace_revision(&state, expected_revision)?;
            Self::resolve_workspace_selector(&state, id, key)?
        };
        let Some((resolved_target, _)) = resolved else {
            return Ok(None);
        };
        let mutation = WorkspaceMutation::local("cmux-tui");
        let result = self.rename_workspace_with_mutation_inner(
            id,
            key,
            name,
            None,
            expected_revision,
            &mutation,
        );
        drop(authority);
        let result = result?;
        Ok(Some((result.workspace.unwrap_or(resolved_target), result.key, result.revision)))
    }

    #[allow(clippy::too_many_arguments)]
    fn rename_workspace_with_mutation_inner(
        &self,
        target: Option<WorkspaceId>,
        requested_key: Option<&str>,
        name: String,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
    ) -> anyhow::Result<WorkspaceMutationResult> {
        Self::validate_workspace_name(&name)?;
        let fingerprint = serde_json::json!({
            "op": "rename-workspace",
            "workspace": target,
            "key": requested_key,
            "name": name,
        });
        let notifications = self.surface_notifications();
        let mut registry = self.workspace_registry.lock().unwrap();
        if let Some(commit) = registry.replay(mutation, &fingerprint)? {
            return workspace_mutation_result(&commit);
        }
        let (renamed, result) = {
            let mut state = self.state.lock().unwrap();
            Self::require_workspace_revision(&state, expected_revision)?;
            let index = resolve_workspace_index(&state, target, requested_key)?;
            let workspace_id = state.workspaces[index].id;
            let key = state.workspaces[index].key.clone();
            let changed = state.workspaces[index].name != name;
            let mut desired = self.registry_projection(&state);
            desired[index].name = name.clone();
            let desired_active_workspace =
                state.workspaces.get(state.active_workspace).map(|workspace| &workspace.public_id);
            let commit = registry.commit_with_active_workspace(
                mutation,
                &fingerprint,
                expected_generation,
                expected_revision,
                "workspace-renamed",
                &key,
                &desired,
                desired_active_workspace,
                &serde_json::json!({
                    "workspace": workspace_id,
                    "key": key.clone(),
                    "index": index,
                    "changed": changed,
                }),
            )?;
            let resource_revision = registry.snapshot()?.resource_revision;
            state.workspaces[index].name = name;
            state.workspace_revision = commit.revision;
            state.resource_revision = resource_revision;
            let workspace_revision = commit.revision;
            let entity = crate::server::tree_entity_json(
                &state,
                &notifications,
                TreeDeltaKind::WorkspaceRenamed,
                workspace_id,
            )
            .expect("renamed workspace is present in tree snapshot");
            (
                TreeDelta {
                    kind: TreeDeltaKind::WorkspaceRenamed,
                    workspace: workspace_id,
                    screen: None,
                    pane: None,
                    surface: None,
                    index: None,
                    entity,
                    workspace_revision: Some(workspace_revision),
                },
                workspace_mutation_result(&commit)?,
            )
        };
        drop(registry);
        self.publish_resource_event();
        self.emit(MuxEvent::TreeDelta(renamed));
        Ok(result)
    }

    /// Set a pane's user-visible name. An empty name clears it (the pane
    /// falls back to its active tab's title).
    pub fn rename_pane(self: &Arc<Self>, target: PaneId, name: String) -> bool {
        let Some(selectors) = self.ordinary_pane_selectors(target) else { return false };
        if self
            .commit_ordinary_topology_operation(
                ResourceOperation::PaneRename,
                selectors,
                Self::nullable_name_fields(name),
            )
            .is_err()
        {
            return false;
        }
        self.emit(MuxEvent::TreeChanged);
        true
    }

    /// Set a tab's user-visible name. An empty name clears it (the tab
    /// falls back to its process title/number label).
    pub fn rename_surface(self: &Arc<Self>, target: SurfaceId, name: String) -> bool {
        let Some(selectors) = self.ordinary_tab_selectors(target) else { return false };
        if self
            .commit_ordinary_topology_operation(
                ResourceOperation::TabRename,
                selectors,
                Self::nullable_name_fields(name),
            )
            .is_err()
        {
            return false;
        }
        let notifications = self.surface_notifications();
        let delta = {
            let state = self.state.lock().unwrap();
            if !state.surfaces.contains_key(&target) {
                return false;
            }
            (|| {
                let pane = state.pane_of(target)?;
                let (wi, si) = state.screen_of(pane)?;
                let entity = crate::server::tree_entity_json(
                    &state,
                    &notifications,
                    TreeDeltaKind::TabRenamed,
                    target,
                )?;
                Some(TreeDelta {
                    kind: TreeDeltaKind::TabRenamed,
                    workspace: state.workspaces[wi].id,
                    screen: Some(state.workspaces[wi].screens[si].id),
                    pane: Some(pane),
                    surface: Some(target),
                    index: None,
                    entity,
                    workspace_revision: None,
                })
            })()
        };
        match delta {
            Some(delta) => self.emit(MuxEvent::TreeDelta(delta)),
            None => self.emit(MuxEvent::TreeChanged),
        }
        true
    }

    /// Set a screen's user-visible name. An empty name clears it (the
    /// screen falls back to its number).
    pub fn rename_screen(self: &Arc<Self>, target: ScreenId, name: String) -> bool {
        let Some(selectors) = self.ordinary_screen_selectors(target) else { return false };
        if self
            .commit_ordinary_topology_operation(
                ResourceOperation::ScreenRename,
                selectors,
                Self::nullable_name_fields(name),
            )
            .is_err()
        {
            return false;
        }
        let notifications = self.surface_notifications();
        let renamed = {
            let state = self.state.lock().unwrap();
            let Some(wi) = state
                .workspaces
                .iter()
                .enumerate()
                .find_map(|(wi, workspace)| {
                    workspace
                        .screens
                        .iter()
                        .position(|screen| screen.id == target)
                        .map(|si| (wi, si))
                })
                .map(|(wi, _)| wi)
            else {
                return false;
            };
            let entity = crate::server::tree_entity_json(
                &state,
                &notifications,
                TreeDeltaKind::ScreenRenamed,
                target,
            )
            .expect("renamed screen is present in tree snapshot");
            TreeDelta {
                kind: TreeDeltaKind::ScreenRenamed,
                workspace: state.workspaces[wi].id,
                screen: Some(target),
                pane: None,
                surface: None,
                index: None,
                entity,
                workspace_revision: None,
            }
        };
        self.emit(MuxEvent::TreeDelta(renamed));
        true
    }

    /// Reconcile a surface whose child exited before its tree insert
    /// completed. Hosted terminals retain their binding as Exited tabs;
    /// local terminals are reaped after the creator closes the insert race.
    fn reap_if_dead(&self, surface: &Arc<Surface>) {
        if surface.is_dead() {
            if self.resource_creation_active.load(Ordering::Acquire) {
                // The reader's exit callback is fenced by the creation
                // execution lock. It will reap this surface after the public
                // creation batch and any legacy runtime handoff complete.
                return;
            }
            if surface.terminal_host_identity().is_some() {
                if let Err(error) =
                    self.mark_hosted_surface_exited(surface, "host-exited-before-attach")
                {
                    self.emit(MuxEvent::Status(format!(
                        "could not persist terminal {} exit: {error}",
                        surface.id
                    )));
                    return;
                }
                // Hosted exits remain addressable/renderable placeholders
                // until an explicit close mutation tombstones the terminal.
                self.emit(MuxEvent::TreeChanged);
                return;
            }
            self.remove_surface_after_registry(surface.id);
            return;
        }
        let workspace_key = {
            let state = self.state.lock().unwrap();
            state.workspaces.iter().find_map(|workspace| {
                workspace
                    .screens
                    .iter()
                    .any(|screen| screen_tabs(&state, screen).contains(&surface.id))
                    .then(|| workspace.key.clone())
            })
        };
        if let Some(workspace_key) = workspace_key {
            let _ = surface.persist_host_workspace(&workspace_key);
        }
    }

    /// Called by a surface's reader thread when its child exits. Hosted
    /// terminals remain stable, renderable Exited tabs until an explicit
    /// close; local surfaces are removed immediately.
    pub fn surface_exited(&self, id: SurfaceId) {
        if self.sidebar_surface_exited(id) {
            self.emit(MuxEvent::SurfaceExited(id));
            return;
        }
        let _creation_handoff = self.resource_creation_handoff.lock().unwrap();
        let _creation_fence = self.resource_creation_execution.lock().unwrap();
        if let Some(surface) = self.surface(id)
            && surface.terminal_host_identity().is_some()
        {
            if let Err(error) = self.mark_hosted_surface_exited(&surface, "host-exited") {
                self.emit(MuxEvent::Status(format!(
                    "could not persist terminal {id} exit: {error}"
                )));
                return;
            }
            self.emit(MuxEvent::TreeChanged);
            self.emit(MuxEvent::SurfaceExited(id));
            return;
        }
        self.remove_surface_after_registry(id);
        self.emit(MuxEvent::SurfaceExited(id));
    }

    fn mark_hosted_surface_exited(
        &self,
        surface: &Arc<Surface>,
        reason: &str,
    ) -> anyhow::Result<()> {
        let Some(identity) = surface.terminal_host_identity() else {
            return Ok(());
        };
        let exit = surface.terminal_exit().unwrap_or_else(|| TerminalExit::unknown(reason));
        self.persist_terminal_exit(&identity.terminal_id, Some(&identity.incarnation), &exit)?;
        #[cfg(unix)]
        if let Some((path, expected)) = surface.terminal_host_exit_sidecar() {
            crate::terminal_host_runtime::acknowledge_terminal_host_exit_record(&path, &expected)?;
        }
        Ok(())
    }

    /// Commit terminal lifecycle, public snapshot, and exactly one session
    /// event in one registry transaction. Callers may observe the same exit
    /// through the live frame, sidecar recovery, and dead-host reconciliation;
    /// the first commit is the latch and all later observations are no-ops.
    fn persist_terminal_exit(
        &self,
        terminal_id: &str,
        incarnation: Option<&str>,
        exit: &TerminalExit,
    ) -> anyhow::Result<bool> {
        let mut registry = self.workspace_registry.lock().unwrap();
        let terminal = registry
            .terminal_record(terminal_id)?
            .ok_or_else(|| anyhow::anyhow!("unknown terminal {terminal_id}"))?;
        let public_terminal_id = registry.terminal_resource_id(terminal_id)?;
        if !matches!(terminal.lifecycle, TerminalLifecycle::Exited | TerminalLifecycle::Tombstoned)
            && public_terminal_id.is_none()
        {
            // One-release compatibility for pre-resource terminal rows. They
            // have no public identity to emit, but still retain the exact
            // outcome in the terminal timeline and remain first-writer wins.
            let resource_revision = registry.resource_revision()?;
            let (_, terminal_revision) = commit_terminal_lifecycle(
                &mut registry,
                "terminal-exited",
                "terminal-host-exited",
                terminal_id,
                TerminalLifecycle::Exited,
                incarnation,
                Some(serde_json::json!({
                    "outcome": &exit.outcome,
                    "exited_at": exit.exited_at_ms.to_string(),
                    "revision": resource_revision.to_string(),
                })),
            )?;
            self.emit_terminal_registry_changed(&registry, terminal_revision);
            return Ok(true);
        }
        let mut state = self.state.lock().unwrap();
        let terminal_snapshot = if matches!(
            terminal.lifecycle,
            TerminalLifecycle::Exited | TerminalLifecycle::Tombstoned
        ) {
            Value::Null
        } else {
            terminal_exit_snapshot_in_state(&registry, &state, terminal_id)?
        };
        let (_, terminal_revision, resource_revision, replayed) =
            registry.commit_terminal_exit(terminal_id, incarnation, exit, terminal_snapshot)?;
        if !replayed {
            state.resource_revision = resource_revision;
            self.emit_terminal_registry_changed(&registry, terminal_revision);
        }
        drop(state);
        drop(registry);
        if !replayed {
            if let Some(public_terminal_id) = public_terminal_id.as_ref() {
                self.terminal_exit_waiters.notify(public_terminal_id);
            }
            self.publish_resource_event();
        }
        Ok(!replayed)
    }

    fn sidebar_surface_exited(&self, id: SurfaceId) -> bool {
        let mut runtime = self.sidebar_plugin.lock().unwrap();
        if runtime.surface != Some(id) {
            return false;
        }
        runtime.surface = None;
        runtime.failures = runtime.failures.saturating_add(1);
        let delay = sidebar_retry_delay(runtime.failures);
        runtime.last_error = Some("sidebar plugin exited".to_string());
        runtime.retry_at = Some(Instant::now() + delay);
        drop(runtime);
        let retired = {
            let mut state = self.state.lock().unwrap();
            take_surface_for_retirement(self, &mut state, id)
        };
        if let Some(surface) = retired {
            self.purge_surface_side_tables(id);
            self.retire_surface_runtime(surface);
        }
        true
    }

    /// Make `pane` the active pane of its screen (and that screen and
    /// workspace active).
    pub fn focus_pane(self: &Arc<Self>, pane: PaneId) -> bool {
        let layout_changed = self.with_state(|state| {
            let (workspace, screen) = state.screen_of(pane)?;
            let screen = &state.workspaces[workspace].screens[screen];
            (screen.active_pane != pane
                && (screen.root.contains_stack_pane(screen.active_pane)
                    || screen.root.contains_stack_pane(pane)))
            .then_some(screen.id)
        });
        let Some(selectors) = self.ordinary_pane_selectors(pane) else { return false };
        if self
            .commit_ordinary_topology_operation(ResourceOperation::PaneFocus, selectors, Map::new())
            .is_err()
        {
            return false;
        }
        let viewed = self.with_state(Self::active_surface_in_state);
        self.clear_viewed_notification(viewed);
        if let Some(screen) = layout_changed {
            self.emit(MuxEvent::LayoutChanged(screen));
        } else {
            self.emit(MuxEvent::TreeChanged);
        };
        true
    }

    /// Set the deepest split ratio in `dir` on the path to `pane`.
    pub fn set_ratio(self: &Arc<Self>, pane: PaneId, dir: SplitDir, ratio: f32) -> bool {
        self.set_ratio_checked(pane, dir, ratio).is_ok()
    }

    /// Set a pane-addressed split ratio while preserving rejection details.
    pub fn set_ratio_checked(
        self: &Arc<Self>,
        pane: PaneId,
        dir: SplitDir,
        ratio: f32,
    ) -> Result<(), LayoutRatioError> {
        let split = self
            .with_state(|state| {
                state
                    .workspaces
                    .iter()
                    .flat_map(|workspace| workspace.screens.iter())
                    .find(|screen| screen.root.contains(pane))
                    .and_then(|screen| screen.root.deepest_split_for_pane(pane, dir))
            })
            .ok_or(LayoutRatioError::UnknownPaneSplit { pane })?;
        self.set_split_ratio_inner(split, ratio, None, true).map_err(|error| match error {
            LayoutRatioError::UnknownSplit { .. } => LayoutRatioError::UnknownPaneSplit { pane },
            error => error,
        })
    }

    /// Set one split ratio by its stable split-tree node id.
    pub fn set_split_ratio(self: &Arc<Self>, split: SplitId, ratio: f32) -> bool {
        self.set_split_ratio_checked(split, ratio).is_ok()
    }

    /// Set one split ratio while preserving rejection details.
    pub fn set_split_ratio_checked(
        self: &Arc<Self>,
        split: SplitId,
        ratio: f32,
    ) -> Result<(), LayoutRatioError> {
        self.set_split_ratio_inner(split, ratio, None, false)
    }

    /// Set one split ratio as part of a client-scoped resize transaction.
    pub fn set_split_ratio_in_transaction(
        self: &Arc<Self>,
        split: SplitId,
        ratio: f32,
        client: u64,
        transaction: u64,
    ) -> bool {
        self.set_split_ratio_in_transaction_checked(split, ratio, client, transaction).is_ok()
    }

    /// Set one transactional split ratio while preserving rejection details.
    pub fn set_split_ratio_in_transaction_checked(
        self: &Arc<Self>,
        split: SplitId,
        ratio: f32,
        client: u64,
        transaction: u64,
    ) -> Result<(), LayoutRatioError> {
        self.set_split_ratio_inner(
            split,
            ratio,
            Some((LayoutResizeOwner::ControlClient(client), transaction)),
            false,
        )
    }

    /// Set one in-process transactional split ratio without sharing the
    /// control-client ownership namespace.
    pub fn set_split_ratio_in_process_transaction_checked(
        self: &Arc<Self>,
        split: SplitId,
        ratio: f32,
        owner: u64,
        transaction: u64,
    ) -> Result<(), LayoutRatioError> {
        self.set_split_ratio_inner(
            split,
            ratio,
            Some((LayoutResizeOwner::InProcess(owner), transaction)),
            false,
        )
    }

    fn set_split_ratio_inner(
        self: &Arc<Self>,
        split: SplitId,
        ratio: f32,
        transaction: Option<(LayoutResizeOwner, u64)>,
        tree_changed: bool,
    ) -> Result<(), LayoutRatioError> {
        let ratio = clamp_split_ratio(ratio);
        let target = {
            let state = self.state.lock().unwrap();
            let Some((workspace_index, screen_index, owner)) =
                state.split_screens.get(&split).copied()
            else {
                return Err(LayoutRatioError::UnknownSplit { split });
            };
            if state
                .workspaces
                .get(workspace_index)
                .and_then(|workspace| workspace.screens.get(screen_index))
                .is_none_or(|screen| screen.id != owner)
            {
                return Err(LayoutRatioError::UnknownSplit { split });
            }
            let screen = &state.workspaces[workspace_index].screens[screen_index];
            if let Some(index) = screen
                .layout_columns
                .iter()
                .position(|column| column.id == split)
                .filter(|index| *index > 0)
            {
                let width_before =
                    screen.layout_columns[..index].iter().map(|column| column.width).sum::<f32>();
                let width = width_before * (1.0 - ratio) / ratio;
                if !width.is_finite()
                    || !(MIN_VIEWPORT_PANE_WIDTH..=MAX_VIEWPORT_PANE_WIDTH).contains(&width)
                {
                    return Err(LayoutRatioError::UnrepresentableViewportWidth {
                        split,
                        ratio,
                        width,
                    });
                }
                if screen.layout_columns[index].width == width {
                    return Ok(());
                }
            } else {
                let Some(current) = screen.root.split_ratio(split) else {
                    return Err(LayoutRatioError::UnknownSplit { split });
                };
                if current == ratio {
                    return Ok(());
                }
            }
            (
                screen.active_pane,
                state
                    .resource_indexes
                    .split_ids
                    .get(&split)
                    .cloned()
                    .ok_or(LayoutRatioError::UnknownSplit { split })?,
            )
        };
        let selectors = self
            .ordinary_pane_selectors(target.0)
            .ok_or(LayoutRatioError::UnknownSplit { split })?;
        let mut fields = Map::from_iter([
            ("split_id".into(), Value::String(target.1.to_string())),
            ("ratio".into(), Value::from(ratio)),
        ]);
        if let Some((owner, transaction)) = transaction {
            let (kind, owner) = match owner {
                LayoutResizeOwner::ControlClient(owner) => ("control-client", owner),
                LayoutResizeOwner::InProcess(owner) => ("in-process", owner),
            };
            fields.insert("resize_owner_kind".into(), Value::String(kind.into()));
            fields.insert("resize_owner".into(), Value::from(owner));
            fields.insert("resize_transaction".into(), Value::from(transaction));
        }
        let commit = self
            .commit_ordinary_topology_operation(
                ResourceOperation::PaneSplitRatioSet,
                selectors,
                fields,
            )
            .map_err(|error| {
                self.emit(MuxEvent::Status(format!("could not persist split ratio: {error:#}")));
                LayoutRatioError::UnknownSplit { split }
            })?;
        if tree_changed {
            self.emit(MuxEvent::TreeChanged);
        }
        if let Some(screen) = commit
            .result
            .get("screen")
            .and_then(Value::as_str)
            .and_then(|id| ScreenPublicId::parse(id.to_string()).ok())
            .and_then(|id| {
                self.with_state(|state| state.resource_indexes.screens.get(&id).copied())
            })
        {
            self.emit(MuxEvent::LayoutChanged(screen));
        }
        Ok(())
    }

    /// Set the width of the horizontal viewport column containing `pane`.
    pub fn set_viewport_pane_width(self: &Arc<Self>, pane: PaneId, width: f32) -> bool {
        self.set_viewport_pane_width_checked(pane, width).is_ok()
    }

    /// Set a viewport column width while preserving rejection details.
    pub fn set_viewport_pane_width_checked(
        self: &Arc<Self>,
        pane: PaneId,
        width: f32,
    ) -> Result<(), ViewportWidthError> {
        self.set_viewport_pane_width_inner(pane, width, None)
    }

    /// Set a viewport column width as part of a client-scoped resize transaction.
    pub fn set_viewport_pane_width_in_transaction(
        self: &Arc<Self>,
        pane: PaneId,
        width: f32,
        client: u64,
        transaction: u64,
    ) -> bool {
        self.set_viewport_pane_width_in_transaction_checked(pane, width, client, transaction)
            .is_ok()
    }

    /// Set a transactional viewport width while preserving rejection details.
    pub fn set_viewport_pane_width_in_transaction_checked(
        self: &Arc<Self>,
        pane: PaneId,
        width: f32,
        client: u64,
        transaction: u64,
    ) -> Result<(), ViewportWidthError> {
        self.set_viewport_pane_width_inner(
            pane,
            width,
            Some((LayoutResizeOwner::ControlClient(client), transaction)),
        )
    }

    /// Set one in-process transactional viewport width without sharing the
    /// control-client ownership namespace.
    pub fn set_viewport_pane_width_in_process_transaction_checked(
        self: &Arc<Self>,
        pane: PaneId,
        width: f32,
        owner: u64,
        transaction: u64,
    ) -> Result<(), ViewportWidthError> {
        self.set_viewport_pane_width_inner(
            pane,
            width,
            Some((LayoutResizeOwner::InProcess(owner), transaction)),
        )
    }

    fn set_viewport_pane_width_inner(
        self: &Arc<Self>,
        pane: PaneId,
        width: f32,
        transaction: Option<(LayoutResizeOwner, u64)>,
    ) -> Result<(), ViewportWidthError> {
        if !width.is_finite()
            || !(MIN_VIEWPORT_PANE_WIDTH..=MAX_VIEWPORT_PANE_WIDTH).contains(&width)
        {
            return Err(ViewportWidthError::OutOfRange { width });
        }
        {
            let state = self.state.lock().unwrap();
            let Some((workspace_index, screen_index)) = state.screen_of(pane) else {
                return Err(ViewportWidthError::PaneNotResizable { pane });
            };
            let screen = &state.workspaces[workspace_index].screens[screen_index];
            if !screen.layout_columns_active() {
                return Err(ViewportWidthError::PaneNotResizable { pane });
            }
            let Some(column_index) =
                screen.layout_columns.iter().position(|column| column.root.contains(pane))
            else {
                return Err(ViewportWidthError::PaneNotResizable { pane });
            };
            if (screen.layout_columns[column_index].width - width).abs() < f32::EPSILON {
                return Ok(());
            }
        }
        let selectors = self
            .ordinary_pane_selectors(pane)
            .ok_or(ViewportWidthError::PaneNotResizable { pane })?;
        let mut fields = Map::from_iter([("width".into(), Value::from(width))]);
        if let Some((owner, transaction)) = transaction {
            let (kind, owner) = match owner {
                LayoutResizeOwner::ControlClient(owner) => ("control-client", owner),
                LayoutResizeOwner::InProcess(owner) => ("in-process", owner),
            };
            fields.insert("resize_owner_kind".into(), Value::String(kind.into()));
            fields.insert("resize_owner".into(), Value::from(owner));
            fields.insert("resize_transaction".into(), Value::from(transaction));
        }
        let commit = self
            .commit_ordinary_topology_operation(
                ResourceOperation::PaneViewportWidthSet,
                selectors,
                fields,
            )
            .map_err(|error| {
                self.emit(MuxEvent::Status(format!(
                    "could not persist viewport pane width: {error:#}"
                )));
                ViewportWidthError::PaneNotResizable { pane }
            })?;
        if let Some(screen) = commit
            .result
            .get("screen")
            .and_then(Value::as_str)
            .and_then(|id| ScreenPublicId::parse(id.to_string()).ok())
            .and_then(|id| {
                self.with_state(|state| state.resource_indexes.screens.get(&id).copied())
            })
        {
            self.emit(MuxEvent::LayoutChanged(screen));
        }
        Ok(())
    }

    fn pane_navigation_layout(screen: &Screen, pane: PaneId, dir: Direction) -> LayoutResult {
        const NAVIGATION_COLUMN_WIDTH: u16 = 10_000;
        let column_area = Rect { x: 0, y: 0, width: NAVIGATION_COLUMN_WIDTH, height: 10_000 };
        if !screen.layout_columns_active() {
            return layout_screen(&screen.root, column_area, Some(screen.active_pane));
        }
        let Some(current_index) =
            screen.layout_columns.iter().position(|column| column.root.contains(pane))
        else {
            return layout_screen(&screen.root, column_area, Some(screen.active_pane));
        };
        let neighbor_index = match dir {
            Direction::Up | Direction::Down => None,
            Direction::Left => current_index.checked_sub(1),
            Direction::Right => {
                current_index.checked_add(1).filter(|index| *index < screen.layout_columns.len())
            }
        };
        let Some(neighbor_index) = neighbor_index else {
            return layout_screen(
                &screen.layout_columns[current_index].root,
                column_area,
                Some(screen.active_pane),
            );
        };

        let (left_index, right_index) = if neighbor_index < current_index {
            (neighbor_index, current_index)
        } else {
            (current_index, neighbor_index)
        };
        let mut result = LayoutResult { virtual_width: 20_000, ..Default::default() };
        for (index, x) in [(left_index, 0), (right_index, NAVIGATION_COLUMN_WIDTH)] {
            let mut column = layout_screen(
                &screen.layout_columns[index].root,
                Rect { x, ..column_area },
                Some(screen.active_pane),
            );
            result.panes.append(&mut column.panes);
            result.stacked_headers.extend(column.stacked_headers);
        }
        result
    }

    pub fn pane_neighbor(&self, pane: PaneId, dir: Direction) -> anyhow::Result<Option<PaneId>> {
        self.with_state(|state| {
            let Some((wi, si)) = state.screen_of(pane) else {
                anyhow::bail!("unknown pane {pane}");
            };
            let screen = &state.workspaces[wi].screens[si];
            let (dx, dy) = dir.delta();
            let layout = Self::pane_navigation_layout(screen, pane, dir);
            Ok(layout.neighbor(pane, dx, dy))
        })
    }

    #[cfg(test)]
    fn pane_focus_neighbor(&self, pane: PaneId, dir: Direction) -> anyhow::Result<Option<PaneId>> {
        self.with_state(|state| {
            let Some((wi, si)) = state.screen_of(pane) else {
                anyhow::bail!("unknown pane {pane}");
            };
            let screen = &state.workspaces[wi].screens[si];
            let (dx, dy) = dir.delta();
            let layout = Self::pane_navigation_layout(screen, pane, dir);
            Ok(layout.neighbor_by_recency(pane, dx, dy, |candidate| {
                state.panes.get(&candidate).map(|pane| pane.focused_at).unwrap_or_default()
            }))
        })
    }

    pub fn focus_direction(
        self: &Arc<Self>,
        pane: Option<PaneId>,
        dir: Direction,
    ) -> anyhow::Result<PaneId> {
        let target = self.with_state(|state| pane.or_else(|| state.active_pane()));
        let Some(target) = target else {
            anyhow::bail!("no active pane");
        };
        let selectors = self
            .ordinary_pane_selectors(target)
            .with_context(|| format!("unknown pane {target}"))?;
        let direction = match dir {
            Direction::Left => "left",
            Direction::Right => "right",
            Direction::Up => "up",
            Direction::Down => "down",
        };
        let commit = self.commit_ordinary_topology_operation(
            ResourceOperation::PaneFocusDirection,
            selectors,
            Map::from_iter([("direction".into(), Value::String(direction.into()))]),
        )?;
        let public_id = PanePublicId::parse(
            commit.result["pane"]
                .as_str()
                .context("pane focus result omitted its pane id")?
                .to_string(),
        )?;
        let next = self
            .with_state(|state| state.resource_indexes.panes.get(&public_id).copied())
            .context("focused pane disappeared")?;
        let viewed = self.with_state(Self::active_surface_in_state);
        self.clear_viewed_notification(viewed);
        self.emit(MuxEvent::TreeChanged);
        Ok(next)
    }

    pub fn swap_panes(self: &Arc<Self>, pane: PaneId, target: PaneId) -> bool {
        if pane == target {
            return false;
        }
        let Some(selectors) = self.ordinary_pane_selectors(pane) else { return false };
        let Some((other_workspace, other_screen, other_pane)) = self.with_state(|state| {
            let first = state.screen_of(pane)?;
            let second = state.screen_of(target)?;
            if first != second {
                return None;
            }
            Some((
                state.workspaces[second.0].public_id.to_string(),
                state.workspaces[second.0].screens[second.1].public_id.to_string(),
                state.resource_indexes.pane_ids.get(&target)?.to_string(),
            ))
        }) else {
            return false;
        };
        let fields = Map::from_iter([
            ("other_workspace".into(), Value::String(other_workspace)),
            ("other_screen".into(), Value::String(other_screen)),
            ("other_pane".into(), Value::String(other_pane)),
        ]);
        let Ok(commit) =
            self.commit_ordinary_topology_operation(ResourceOperation::PaneSwap, selectors, fields)
        else {
            return false;
        };
        self.emit_resource_topology_legacy_events(ResourceOperation::PaneSwap, &commit);
        true
    }

    pub fn zoom_pane(
        self: &Arc<Self>,
        pane: Option<PaneId>,
        mode: ZoomMode,
    ) -> anyhow::Result<ZoomState> {
        let (target, next, changed) = self.with_state(|state| {
            let target = pane.or_else(|| state.active_pane()).context("no active pane")?;
            let (workspace, screen) =
                state.screen_of(target).with_context(|| format!("unknown pane {target}"))?;
            let current = state.workspaces[workspace].screens[screen].zoomed_pane;
            let next = match mode {
                ZoomMode::Toggle if current == Some(target) => None,
                ZoomMode::Toggle | ZoomMode::On => Some(target),
                ZoomMode::Off => None,
            };
            Ok::<_, anyhow::Error>((target, next, current != next))
        })?;
        if !changed {
            return Ok(ZoomState { pane: target, zoomed: next.is_some(), zoomed_pane: next });
        }
        let selectors = self
            .ordinary_pane_selectors(target)
            .with_context(|| format!("unknown pane {target}"))?;
        let fields = match mode {
            ZoomMode::Toggle => Map::new(),
            ZoomMode::On => Map::from_iter([("enabled".into(), Value::Bool(true))]),
            ZoomMode::Off => Map::from_iter([("enabled".into(), Value::Bool(false))]),
        };
        let commit = self.commit_ordinary_topology_operation(
            ResourceOperation::PaneZoom,
            selectors,
            fields,
        )?;
        self.emit_resource_topology_legacy_events(ResourceOperation::PaneZoom, &commit);
        let zoomed_pane = self.with_state(|state| {
            state
                .screen_of(target)
                .and_then(|(workspace, screen)| {
                    state.workspaces.get(workspace)?.screens.get(screen)
                })
                .and_then(|screen| screen.zoomed_pane)
        });
        Ok(ZoomState { pane: target, zoomed: zoomed_pane.is_some(), zoomed_pane })
    }

    /// Undo the latest structural layout transaction on `pane`'s screen.
    ///
    /// Transactions that created panes return a confirmation preview first.
    /// The preview is read only. The caller must retry with its exact current
    /// layout revision and `confirm_close=true`; structural or created-pane tab
    /// membership changes advance that revision before the retry can commit.
    pub fn undo_layout(
        self: &Arc<Self>,
        pane: PaneId,
        expected_revision: Option<u64>,
        confirm_close: bool,
    ) -> anyhow::Result<LayoutUndoResult> {
        let (screen_id, current_revision, created_panes) = {
            let state = self.state.lock().unwrap();
            let Some((workspace_index, screen_index)) = state.screen_of(pane) else {
                return Err(LayoutUndoError::Stale(
                    "layout undo target is no longer available".to_string(),
                )
                .into());
            };
            let screen = &state.workspaces[workspace_index].screens[screen_index];
            let Some(entry) = screen.layout_undo.back() else {
                return Err(LayoutUndoError::Unavailable.into());
            };
            if entry.after_revision != screen.layout_revision {
                return Err(LayoutUndoError::Stale(
                    "layout changed since the last undoable action".to_string(),
                )
                .into());
            }
            if let Some(expected) = expected_revision
                && expected != entry.after_revision
            {
                return Err(LayoutUndoError::Stale(format!(
                    "layout revision conflict: expected {expected}, current {}",
                    entry.after_revision
                ))
                .into());
            }
            for created in &entry.created_panes {
                if !state.panes.contains_key(created) {
                    return Err(LayoutUndoError::Stale(format!(
                        "created pane {created} disappeared before undo preview"
                    ))
                    .into());
                }
            }
            (screen.id, entry.after_revision, entry.created_panes.clone())
        };
        if !created_panes.is_empty() && !confirm_close {
            return Ok(LayoutUndoResult::ConfirmationRequired {
                screen: screen_id,
                revision: current_revision,
                closes_panes: created_panes,
            });
        }
        if !created_panes.is_empty() && expected_revision.is_none() {
            return Err(LayoutUndoError::Stale(
                "confirmed layout undo requires the preview revision".to_string(),
            )
            .into());
        }

        let selectors = self.ordinary_screen_selectors(screen_id).ok_or_else(|| {
            LayoutUndoError::Stale("layout undo target is no longer available".to_string())
        })?;
        let mut fields = Map::from_iter([("confirm_close".into(), Value::Bool(confirm_close))]);
        fields.insert("expected_layout_revision".into(), Value::from(current_revision));
        let expected_resource_revision = if created_panes.is_empty() {
            None
        } else {
            let registry = self.workspace_registry.lock().unwrap();
            let state = self.state.lock().unwrap();
            let Some((workspace_index, screen_index)) = state.screen_of(pane) else {
                return Err(LayoutUndoError::Stale(
                    "layout undo target disappeared before confirmation".to_string(),
                )
                .into());
            };
            let details =
                layout_undo_confirmation_details(&state, &registry, workspace_index, screen_index)?;
            let token = details["confirmation_token"]
                .as_str()
                .context("layout undo confirmation omitted its token")?;
            fields.insert("confirmation_token".into(), Value::String(token.to_string()));
            Some(registry.resource_topology_snapshot()?.revision)
        };
        let commit = self
            .commit_resource_topology_operation(
                ResourceOperation::ScreenLayoutUndo,
                selectors,
                fields,
                expected_resource_revision,
                &WorkspaceMutation::local("cmux-tui-layout-undo"),
            )
            .map_err(|error| {
                if error
                    .downcast_ref::<ResourceError>()
                    .is_some_and(|error| error.code == "revision.conflict")
                {
                    anyhow::Error::new(LayoutUndoError::Stale(
                        "layout revision conflict: resource topology changed before confirmed undo could commit"
                            .to_string(),
                    ))
                } else {
                    error
                }
            })?;
        let screen = commit
            .result
            .get("screen")
            .and_then(Value::as_str)
            .and_then(|id| ScreenPublicId::parse(id.to_string()).ok())
            .and_then(|id| {
                self.with_state(|state| state.resource_indexes.screens.get(&id).copied())
            })
            .unwrap_or(screen_id);
        let revision = self
            .with_state(|state| {
                state
                    .workspaces
                    .iter()
                    .flat_map(|workspace| workspace.screens.iter())
                    .find(|candidate| candidate.id == screen)
                    .map(|screen| screen.layout_revision)
            })
            .ok_or_else(|| {
                LayoutUndoError::Stale(
                    "layout undo screen disappeared after the change committed".to_string(),
                )
            })?;
        Ok(LayoutUndoResult::Undone { screen, revision })
    }

    fn undo_layout_with_confirmation_token_for_resource_effect(
        &self,
        pane: PaneId,
        expected_revision: Option<u64>,
        confirm_close: bool,
        confirmation_token: Option<&str>,
    ) -> anyhow::Result<LayoutUndoResult> {
        let (workspace, screen_id, preview) = {
            let state = self.state.lock().unwrap();
            let Some((workspace_index, screen_index)) = state.screen_of(pane) else {
                return Err(LayoutUndoError::Stale(
                    "layout undo target is no longer available".to_string(),
                )
                .into());
            };
            let workspace = state.workspaces[workspace_index].id;
            let screen_id = state.workspaces[workspace_index].screens[screen_index].id;
            let entry = {
                let screen = &state.workspaces[workspace_index].screens[screen_index];
                let Some(entry) = screen.layout_undo.back().cloned() else {
                    return Err(LayoutUndoError::Unavailable.into());
                };
                if entry.after_revision != screen.layout_revision {
                    return Err(LayoutUndoError::Stale(
                        "layout changed since the last undoable action".to_string(),
                    )
                    .into());
                }
                entry
            };
            if let Some(expected) = expected_revision
                && expected != entry.after_revision
            {
                return Err(LayoutUndoError::Stale(format!(
                    "layout revision conflict: expected {expected}, current {}",
                    entry.after_revision
                ))
                .into());
            }
            if !entry.created_panes.is_empty() && !confirm_close {
                for created in &entry.created_panes {
                    if !state.panes.contains_key(created) {
                        return Err(LayoutUndoError::Stale(format!(
                            "created pane {created} disappeared before undo preview"
                        ))
                        .into());
                    }
                }
                return Ok(LayoutUndoResult::ConfirmationRequired {
                    screen: screen_id,
                    revision: entry.after_revision,
                    closes_panes: entry.created_panes,
                });
            }
            (workspace, screen_id, entry)
        };
        if !preview.created_panes.is_empty() && expected_revision.is_none() {
            return Err(LayoutUndoError::Stale(
                "confirmed layout undo requires the preview revision".to_string(),
            )
            .into());
        }
        if preview.created_panes.is_empty() {
            let revision = {
                let mut state = self.state.lock().unwrap();
                let Some((workspace_index, screen_index)) = state.screen_of(pane) else {
                    return Err(LayoutUndoError::Stale(
                        "layout undo target disappeared before the change could commit".to_string(),
                    )
                    .into());
                };
                let screen = &mut state.workspaces[workspace_index].screens[screen_index];
                let Some(entry) = screen.layout_undo.pop_back() else {
                    return Err(
                        LayoutUndoError::Stale("layout undo disappeared".to_string()).into()
                    );
                };
                if entry.after_revision != screen.layout_revision
                    || expected_revision.is_some_and(|expected| expected != entry.after_revision)
                {
                    screen.layout_undo.push_back(entry);
                    return Err(LayoutUndoError::Stale(
                        "layout changed before undo could commit".to_string(),
                    )
                    .into());
                }
                let revision = screen.layout_revision.saturating_add(1);
                screen.restore_layout_snapshot(entry.before);
                screen.layout_revision = revision;
                if let Some(previous) = screen.layout_undo.back_mut() {
                    previous.after_revision = revision;
                    previous.coalesce = None;
                }
                Self::rebuild_split_screen_index(&mut state);
                revision
            };
            self.emit(MuxEvent::TreeChanged);
            self.emit(MuxEvent::LayoutChanged(screen_id));
            return Ok(LayoutUndoResult::Undone { screen: screen_id, revision });
        }

        let lifecycle = self.workspace_lifecycle(workspace);
        let _workspace_lifecycle = lifecycle.lock().unwrap();
        let notifications = self.surface_notifications();
        let mut registry = self.workspace_registry.lock().unwrap();
        let mutation = WorkspaceMutation::local("cmux-tui-layout-undo");
        let (
            removed,
            deltas,
            selection_resync,
            terminal_revision,
            terminal_count,
            closed_public_ids,
            revision,
        ) = {
            let mut state = self.state.lock().unwrap();
            let Some(workspace_index) = state.workspace_index(workspace) else {
                return Err(LayoutUndoError::Stale(
                    "layout undo workspace is no longer available".to_string(),
                )
                .into());
            };
            let Some(screen_index) = state.workspaces[workspace_index]
                .screens
                .iter()
                .position(|screen| screen.id == screen_id)
            else {
                return Err(LayoutUndoError::Stale(
                    "layout undo screen is no longer available".to_string(),
                )
                .into());
            };
            let entry = {
                let screen = &state.workspaces[workspace_index].screens[screen_index];
                let Some(entry) = screen.layout_undo.back().cloned() else {
                    return Err(
                        LayoutUndoError::Stale("layout undo disappeared".to_string()).into()
                    );
                };
                if entry.after_revision != screen.layout_revision
                    || expected_revision != Some(entry.after_revision)
                {
                    return Err(LayoutUndoError::Stale(
                        "layout changed before confirmed undo could commit".to_string(),
                    )
                    .into());
                }
                entry
            };
            let mut remaining_history =
                state.workspaces[workspace_index].screens[screen_index].layout_undo.clone();
            remaining_history.pop_back();

            let mut before_panes = Vec::new();
            entry.before.root.pane_ids(&mut before_panes);
            let before_panes = before_panes.into_iter().collect::<HashSet<_>>();
            let mut current_panes = Vec::new();
            state.workspaces[workspace_index].screens[screen_index]
                .root
                .pane_ids(&mut current_panes);
            let expected_panes = before_panes
                .iter()
                .copied()
                .chain(entry.created_panes.iter().copied())
                .collect::<HashSet<_>>();
            if current_panes.into_iter().collect::<HashSet<_>>() != expected_panes {
                return Err(LayoutUndoError::Stale(
                    "screen panes changed since the action being undone".to_string(),
                )
                .into());
            }
            if let Some(expected_token) = confirmation_token {
                let details = layout_undo_confirmation_details(
                    &state,
                    &registry,
                    workspace_index,
                    screen_index,
                )?;
                if details["confirmation_token"].as_str() != Some(expected_token) {
                    return Err(anyhow::Error::new(ResourceError::new(
                        "confirmation.required",
                        "layout undo confirmation is stale",
                        details,
                        false,
                    )));
                }
            }

            let selection_before = active_tree_selection(&state);
            let mut tabs = Vec::new();
            let mut deltas = Vec::new();
            for created in &entry.created_panes {
                let Some(pane) = state.panes.get(created) else {
                    return Err(LayoutUndoError::Stale(format!(
                        "created pane {created} disappeared before undo"
                    ))
                    .into());
                };
                tabs.extend(pane.tabs.iter().copied());
                if let Some(delta) = close_pane_delta(&state, &notifications, *created) {
                    deltas.push(delta);
                }
            }
            let hosted = tabs
                .iter()
                .filter_map(|id| state.surfaces.get(id))
                .filter_map(|surface| self.resource_terminal_host_identity(surface))
                .map(|identity| (identity.terminal_id, Some(identity.incarnation)))
                .collect::<Vec<_>>();
            let closed_public_ids = Self::terminal_public_ids_for_hosted(&registry, &hosted)?;
            let batch = registry.close_terminals_atomically(&mutation, &hosted)?;
            let mut removed = Vec::new();
            for surface in tabs {
                if let (Some(surface), _) = remove_surface(self, &mut state, surface) {
                    removed.push(surface);
                }
            }
            let Some(screen_index) = state.workspaces[workspace_index]
                .screens
                .iter()
                .position(|screen| screen.id == screen_id)
            else {
                return Err(LayoutUndoError::Stale(
                    "layout changed while undo was closing panes".to_string(),
                )
                .into());
            };
            let screen = &mut state.workspaces[workspace_index].screens[screen_index];
            let revision = screen.layout_revision.max(entry.after_revision).saturating_add(1);
            screen.restore_layout_snapshot(entry.before);
            screen.layout_revision = revision;
            screen.layout_undo = remaining_history;
            if let Some(previous) = screen.layout_undo.back_mut() {
                previous.after_revision = revision;
                previous.coalesce = None;
            }
            Self::rebuild_split_screen_index(&mut state);
            let selection_resync = selection_before != active_tree_selection(&state);
            (
                removed,
                deltas,
                selection_resync,
                batch.revision,
                batch.closed,
                closed_public_ids,
                revision,
            )
        };
        drop(registry);

        self.notify_terminal_exit_waiters(closed_public_ids);
        for surface in &removed {
            self.purge_surface_side_tables(surface.id);
        }
        self.retire_surface_runtimes(removed);
        if terminal_count != 0 {
            let registry = self.workspace_registry.lock().unwrap();
            self.emit_terminal_registry_changed(&registry, terminal_revision);
        }
        if deltas.is_empty() {
            self.emit(MuxEvent::TreeChanged);
        } else {
            for delta in deltas {
                self.emit_tree_delta(delta, selection_resync);
            }
        }
        self.emit(MuxEvent::LayoutChanged(screen_id));
        Ok(LayoutUndoResult::Undone { screen: screen_id, revision })
    }

    pub fn apply_layout(
        self: &Arc<Self>,
        workspace: Option<WorkspaceId>,
        name: Option<String>,
        layout: &LayoutSpec,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<AppliedLayout> {
        let _creation = self.begin_surface_creation()?;
        let target_workspace = {
            let state = self.state.lock().unwrap();
            if let Some(id) = workspace
                && !state.workspaces.iter().any(|ws| ws.id == id)
            {
                anyhow::bail!("unknown workspace {id}");
            }
            workspace.or_else(|| state.workspaces.get(state.active_workspace).map(|ws| ws.id))
        };
        let (target_workspace, created_workspace) = match target_workspace {
            Some(workspace) => (workspace, false),
            None => (
                self.create_empty_workspace_for_resource_effect(
                    None,
                    None,
                    WorkspacePublicId::random()?,
                    &WorkspaceMutation::local("cmux-tui-layout-workspace"),
                )?
                .workspace,
                true,
            ),
        };
        let workspace_lifecycle = self.workspace_lifecycle(target_workspace);
        let workspace_lifecycle_guard = workspace_lifecycle.lock().unwrap();
        let workspace_key = self
            .state
            .lock()
            .unwrap()
            .workspace_by_id(target_workspace)
            .map(|workspace| workspace.key.clone())
            .ok_or_else(|| anyhow::anyhow!("layout workspace disappeared"))?;
        #[cfg(test)]
        if let Some(hook) = self.layout_apply_after_workspace_reservation.lock().unwrap().clone() {
            hook();
        }

        let mut created = Vec::new();
        let mut panes = Vec::new();
        let mut spawned = Vec::new();
        let root = match self.instantiate_layout(
            layout,
            size,
            &workspace_key,
            &mut panes,
            &mut created,
            &mut spawned,
        ) {
            Ok(root) => root,
            Err(err) => {
                self.discard_spawned(spawned);
                if created_workspace {
                    drop(workspace_lifecycle_guard);
                    let _ = self.close_workspace_at_revision_for_resource_effect(target_workspace);
                }
                return Err(err);
            }
        };
        if created.is_empty() {
            self.discard_spawned(spawned);
            if created_workspace {
                drop(workspace_lifecycle_guard);
                let _ = self.close_workspace_at_revision_for_resource_effect(target_workspace);
            }
            anyhow::bail!("layout must contain at least one leaf");
        }
        let active_pane = root.first_visible_pane();
        let screen_id = self.next_id();
        let notifications = self.surface_notifications();
        let delta = {
            let mut state = self.state.lock().unwrap();
            let Some(workspace_index) = state.workspace_index(target_workspace) else {
                drop(state);
                self.discard_spawned(spawned);
                anyhow::bail!("layout workspace disappeared");
            };
            for (_, pane) in panes {
                state.insert_pane(pane);
            }
            stamp_pane_focus(self, &mut state, active_pane);
            let screen = Screen {
                id: screen_id,
                public_id: ScreenPublicId::random()?,
                name,
                root,
                active_pane,
                zoomed_pane: None,
                zellij_auto_layout: None,
                viewport_splits: Default::default(),
                viewport_base_width: None,
                layout_columns: Vec::new(),
                layout_revision: 0,
                layout_undo: Default::default(),
            };
            let ws = &mut state.workspaces[workspace_index];
            ws.screens.push(screen);
            ws.active_screen = ws.screens.len().saturating_sub(1);
            let index = ws.active_screen;
            let entity = crate::server::tree_entity_json(
                &state,
                &notifications,
                TreeDeltaKind::ScreenAdded,
                screen_id,
            )
            .expect("applied screen is present in tree snapshot");
            Self::rebuild_split_screen_index(&mut state);
            TreeDelta {
                kind: TreeDeltaKind::ScreenAdded,
                workspace: target_workspace,
                screen: Some(screen_id),
                pane: None,
                surface: None,
                index: Some(index),
                entity,
                workspace_revision: None,
            }
        };
        let projection_result = self.with_state(|state| {
            let (workspace, screen) =
                state.screen_of(active_pane).expect("applied screen remains live");
            serde_json::json!({
                "workspace_id":state.workspaces[workspace].public_id,
                "screen_id":state.workspaces[workspace].screens[screen].public_id,
            })
        });
        if let Err(error) =
            self.commit_ordinary_full_resource_projection("screen.layout.create", projection_result)
        {
            drop(workspace_lifecycle_guard);
            let rollback = self.close_screen_for_resource_effect(screen_id);
            if created_workspace {
                let _ = self.close_workspace_at_revision_for_resource_effect(target_workspace);
            }
            return match rollback {
                Ok(true) => Err(error.context("could not persist applied layout")),
                Ok(false) => Err(error.context(
                    "could not persist applied layout and its screen disappeared during rollback",
                )),
                Err(rollback) => Err(error.context(format!(
                    "could not persist applied layout; rollback also failed: {rollback:#}"
                ))),
            };
        }
        self.emit(MuxEvent::TreeDelta(delta));
        self.emit(MuxEvent::LayoutChanged(screen_id));
        for surface in spawned {
            self.reap_if_dead(&surface);
        }
        Ok(AppliedLayout { screen: screen_id, panes: created })
    }

    fn instantiate_layout(
        self: &Arc<Self>,
        layout: &LayoutSpec,
        size: Option<(u16, u16)>,
        workspace_key: &str,
        panes: &mut Vec<(PaneId, Pane)>,
        created: &mut Vec<AppliedPane>,
        spawned: &mut Vec<Arc<Surface>>,
    ) -> anyhow::Result<Node> {
        match layout {
            LayoutSpec::Leaf(spec) => {
                if spec.command.as_ref().is_some_and(|argv| argv.is_empty()) {
                    anyhow::bail!("leaf command must not be empty");
                }
                let terminal_id = TerminalId::random()?;
                let terminal_hex = terminal_id.to_hex();
                let mutation = WorkspaceMutation::local("cmux-tui-layout-terminal");
                let reservation = TerminalReservationRequest {
                    terminal_id,
                    mutation,
                    fingerprint: terminal_create_fingerprint(
                        workspace_key,
                        Some(&terminal_hex),
                        spec.command.as_deref(),
                        spec.cwd.as_deref(),
                        None,
                        size,
                    )?,
                    expected_generation: None,
                    expected_revision: None,
                };
                let surface = self.spawn_surface_in_workspace_reserved(
                    workspace_key,
                    spec.cwd.clone(),
                    size,
                    spec.command.clone(),
                    reservation,
                )?;
                let (pane_id, pane) = self.make_pane(surface.id)?;
                created.push(AppliedPane { pane: pane_id, surface: surface.id });
                panes.push((pane_id, pane));
                spawned.push(surface);
                Ok(Node::Leaf(pane_id))
            }
            LayoutSpec::Split { dir, ratio, a, b } => Ok(Node::Split {
                id: self.next_id(),
                dir: *dir,
                ratio: clamp_split_ratio(*ratio),
                a: Box::new(self.instantiate_layout(
                    a,
                    size,
                    workspace_key,
                    panes,
                    created,
                    spawned,
                )?),
                b: Box::new(self.instantiate_layout(
                    b,
                    size,
                    workspace_key,
                    panes,
                    created,
                    spawned,
                )?),
            }),
            LayoutSpec::Stack { pane_count, expanded_index } => {
                if *pane_count == 0 {
                    anyhow::bail!("stack must contain at least one pane");
                }
                if *expanded_index >= *pane_count {
                    anyhow::bail!("stack expanded pane must be a member");
                }
                let mut pane_ids = Vec::with_capacity(*pane_count);
                for _ in 0..*pane_count {
                    let node = self.instantiate_layout(
                        &LayoutSpec::Leaf(LayoutLeafSpec { cwd: None, command: None }),
                        size,
                        workspace_key,
                        panes,
                        created,
                        spawned,
                    )?;
                    let Node::Leaf(pane_id) = node else { unreachable!() };
                    pane_ids.push(pane_id);
                }
                let expanded = pane_ids[*expanded_index];
                Ok(Node::stack_with_expanded(pane_ids, expanded).expect("validated stack"))
            }
        }
    }

    fn discard_spawned(&self, spawned: Vec<Arc<Surface>>) {
        if spawned.is_empty() {
            return;
        }
        let hosted = spawned
            .iter()
            .filter_map(|surface| self.resource_terminal_host_identity(surface))
            .map(|identity| (identity.terminal_id, Some(identity.incarnation)))
            .collect::<Vec<_>>();
        let mut registry = self.workspace_registry.lock().unwrap();
        let close = Self::terminal_public_ids_for_hosted(&registry, &hosted).and_then(
            |closed_public_ids| {
                registry
                    .close_terminals_atomically(
                        &WorkspaceMutation::local("cmux-tui-layout-discard"),
                        &hosted,
                    )
                    .map(|batch| (batch, closed_public_ids))
            },
        );
        let (batch, closed_public_ids) = match close {
            Ok(result) => result,
            Err(error) => {
                // The transaction rolled back, so killing or dropping these
                // surfaces would leave durable Running rows unreachable. Put
                // every still-canonical terminal into its registry workspace
                // while the same registry -> state writer fence is held.
                let mut topology_changed = false;
                let mut projection_errors = Vec::new();
                {
                    let mut state = self.state.lock().unwrap();
                    for (terminal_id, _) in &hosted {
                        let terminal = match registry.terminal_record(terminal_id) {
                            Ok(Some(terminal))
                                if terminal.lifecycle != TerminalLifecycle::Tombstoned =>
                            {
                                terminal
                            }
                            Ok(_) => continue,
                            Err(projection_error) => {
                                projection_errors.push(format!(
                                    "{terminal_id}: could not read canonical placement: {projection_error}"
                                ));
                                continue;
                            }
                        };
                        match self.project_terminal_to_workspace_in_state(
                            &mut state,
                            terminal_id,
                            &terminal.workspace_key,
                        ) {
                            Ok((_, changed)) => topology_changed |= changed,
                            Err(projection_error) => projection_errors.push(format!(
                                "{terminal_id}: could not restore topology: {projection_error}"
                            )),
                        }
                    }
                }
                drop(registry);
                let projection_errors = if projection_errors.is_empty() {
                    String::new()
                } else {
                    format!("; {}", projection_errors.join("; "))
                };
                self.emit(MuxEvent::Status(format!(
                    "could not atomically close discarded terminals: {error}{projection_errors}"
                )));
                if topology_changed {
                    self.emit(MuxEvent::TreeChanged);
                }
                return;
            }
        };
        let ids = spawned.iter().map(|surface| surface.id).collect::<Vec<_>>();
        {
            let mut state = self.state.lock().unwrap();
            for id in &ids {
                let _ = take_surface_for_retirement(self, &mut state, *id);
            }
        }
        if batch.closed != 0 {
            self.emit_terminal_registry_changed(&registry, batch.revision);
        }
        drop(registry);
        self.notify_terminal_exit_waiters(closed_public_ids);
        self.retire_surface_runtimes(spawned);
    }

    #[allow(clippy::too_many_arguments)]
    pub fn move_terminal_with_mutation(
        &self,
        terminal_id: &str,
        workspace_key: &str,
        expected_incarnation: Option<&str>,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
    ) -> anyhow::Result<TerminalMoveResult> {
        validate_terminal_hex(terminal_id, "invalid_terminal_id")?;
        if let Some(incarnation) = expected_incarnation {
            validate_terminal_hex(incarnation, "invalid_terminal_incarnation")?;
        }
        let fingerprint = serde_json::json!({
            "op":"move-terminal",
            "terminal_id":terminal_id,
            "workspace_key":workspace_key,
            "incarnation":expected_incarnation,
        });
        let (terminal, terminal_revision, replayed, changed, placement, topology_changed) = {
            let mut registry = self.workspace_registry.lock().unwrap();
            // Registry -> state is the global writer order. Holding both from
            // canonical commit through projection prevents move B / move C
            // from projecting C and then stale B, and serializes moves with a
            // concurrent workspace close.
            let mut state = self.state.lock().unwrap();
            if let Some(replay) = registry.replay_terminal(mutation, &fingerprint)? {
                let terminal = registry
                    .terminal_record(terminal_id)?
                    .ok_or_else(|| anyhow::anyhow!("unknown terminal {terminal_id}"))?;
                let current_revision = registry.terminal_snapshot()?.revision;
                let changed = replay.result["changed"].as_bool().unwrap_or(true);
                #[cfg(test)]
                if let Some(hook) = self.terminal_move_before_projection.lock().unwrap().clone() {
                    hook();
                }
                let (placement, topology_changed) =
                    if terminal.lifecycle == TerminalLifecycle::Tombstoned {
                        (None, false)
                    } else {
                        self.project_terminal_to_workspace_in_state(
                            &mut state,
                            terminal_id,
                            &terminal.workspace_key,
                        )?
                    };
                (terminal, current_revision, true, changed, placement, topology_changed)
            } else {
                let snapshot = registry.terminal_snapshot()?;
                let mut terminal = registry
                    .terminal_record(terminal_id)?
                    .ok_or_else(|| anyhow::anyhow!("unknown terminal {terminal_id}"))?;
                if terminal.lifecycle == TerminalLifecycle::Tombstoned {
                    anyhow::bail!("terminal is already closed");
                }
                if let Some(expected) = expected_incarnation
                    && terminal.incarnation.as_deref() != Some(expected)
                {
                    anyhow::bail!("terminal_incarnation_mismatch");
                }
                let changed = terminal.workspace_key != workspace_key;
                terminal.workspace_key = workspace_key.to_string();
                let commit = registry.commit_terminal(
                    mutation,
                    &fingerprint,
                    expected_generation,
                    expected_revision.or(Some(snapshot.revision)),
                    "terminal-moved",
                    &terminal,
                    &serde_json::json!({
                        "terminal_id":terminal_id,
                        "workspace_key":workspace_key,
                        "incarnation":terminal.incarnation,
                        "state":terminal.lifecycle,
                        "changed":changed,
                    }),
                )?;
                self.emit_terminal_registry_changed(&registry, commit.revision);
                #[cfg(test)]
                if let Some(hook) = self.terminal_move_before_projection.lock().unwrap().clone() {
                    hook();
                }
                let (placement, topology_changed) = self.project_terminal_to_workspace_in_state(
                    &mut state,
                    terminal_id,
                    &terminal.workspace_key,
                )?;
                (terminal, commit.revision, false, changed, placement, topology_changed)
            }
        };
        if placement.is_some()
            && let Some(surface) = placement.and_then(|placement| self.surface(placement.surface))
        {
            let _ = surface.persist_host_workspace(&terminal.workspace_key);
        }
        if topology_changed {
            self.emit(MuxEvent::TreeChanged);
        }
        Ok(TerminalMoveResult { placement, terminal, terminal_revision, replayed, changed })
    }

    fn project_terminal_to_workspace_in_state(
        &self,
        state: &mut State,
        terminal_id: &str,
        workspace_key: &str,
    ) -> anyhow::Result<(Option<RunPlacement>, bool)> {
        let identity = unique_terminal_match(
            terminal_id,
            state.surfaces.values().filter_map(|surface| {
                self.resource_terminal_host_identity(surface).map(|identity| (surface.id, identity))
            }),
        )?;
        let Some((surface, _)) = identity else {
            // Still validate the in-memory projection while both writer locks
            // are held; a missing destination indicates registry/state drift.
            if state.workspaces.iter().all(|workspace| workspace.key != workspace_key) {
                anyhow::bail!("unknown workspace key {workspace_key}");
            }
            return Ok((None, false));
        };
        let active_at = self.next_active_at();
        let preserved_focus = current_focus_identity(state);
        let destination = state
            .workspaces
            .iter()
            .position(|workspace| workspace.key == workspace_key)
            .ok_or_else(|| anyhow::anyhow!("unknown workspace key {workspace_key}"))?;
        if let Some(current) = run_placement_for_surface(state, surface)
            && current.workspace == state.workspaces[destination].id
        {
            return Ok((Some(current), false));
        }
        let target_pane = if let Some(pane) =
            state.workspaces[destination].active_screen_ref().map(|screen| screen.active_pane)
        {
            pane
        } else {
            let pane = self.next_id();
            let screen = self.next_id();
            state.insert_pane(Pane {
                id: pane,
                public_id: PanePublicId::random()?,
                name: None,
                tabs: Vec::new(),
                active_tab: 0,
                active_at,
                // The projection preserves the user's existing focus
                // identity below; this destination starts unfocused.
                focused_at: 0,
            });
            state.workspaces[destination].screens.push(Screen {
                id: screen,
                public_id: ScreenPublicId::random()?,
                name: None,
                root: Node::Leaf(pane),
                active_pane: pane,
                zoomed_pane: None,
                zellij_auto_layout: Some(vec![pane]),
                viewport_splits: Default::default(),
                viewport_base_width: None,
                layout_columns: Vec::new(),
                layout_revision: 0,
                layout_undo: Default::default(),
            });
            state.workspaces[destination].active_screen = 0;
            pane
        };
        if state.pane_of(surface).is_some() {
            let (moved, topology_changed) =
                move_tab_in_state(self, state, surface, target_pane, usize::MAX);
            if !moved {
                anyhow::bail!("terminal topology changed during move");
            }
            if topology_changed {
                Self::rebuild_split_screen_index(state);
            }
        } else {
            let pane = state
                .panes
                .get_mut(&target_pane)
                .ok_or_else(|| anyhow::anyhow!("destination pane disappeared"))?;
            pane.tabs.push(surface);
            pane.active_tab = pane.tabs.len() - 1;
            pane.active_at = active_at;
            fence_layout_undo_for_tab_membership(state, &[target_pane]);
        }
        restore_focus_identity(state, preserved_focus);
        let placement = run_placement_for_surface(state, surface)
            .ok_or_else(|| anyhow::anyhow!("terminal move did not produce a binding"))?;
        Ok((Some(placement), true))
    }

    /// Move an existing tab to `index` in `pane`. The surface is kept
    /// alive; if moving it empties the source pane, that pane collapses
    /// out of its split tree.
    pub fn move_tab(self: &Arc<Self>, surface: SurfaceId, pane: PaneId, index: usize) -> bool {
        if self.with_state(|state| {
            let Some(source) = state.pane_of(surface) else { return false };
            if source != pane {
                return false;
            }
            let Some(pane) = state.panes.get(&pane) else { return false };
            let Some(old_index) = pane.tabs.iter().position(|candidate| *candidate == surface)
            else {
                return false;
            };
            let final_index = if index > old_index { index.saturating_sub(1) } else { index }
                .min(pane.tabs.len().saturating_sub(1));
            final_index == old_index
        }) {
            return false;
        }
        let Some(selectors) = self.ordinary_tab_selectors(surface) else { return false };
        let Some((destination_workspace, destination_screen, destination_pane, changed_screen)) =
            self.with_state(|state| {
                let (workspace, screen) = state.screen_of(pane)?;
                let source_pane = state.pane_of(surface)?;
                let source_screen = (source_pane != pane
                    && state.panes.get(&source_pane)?.tabs.len() == 1)
                    .then(|| {
                        state.screen_of(source_pane).map(|(workspace, screen)| {
                            state.workspaces[workspace].screens[screen].id
                        })
                    })
                    .flatten();
                Some((
                    state.workspaces[workspace].public_id.to_string(),
                    state.workspaces[workspace].screens[screen].public_id.to_string(),
                    state.resource_indexes.pane_ids.get(&pane)?.to_string(),
                    source_screen,
                ))
            })
        else {
            return false;
        };
        let fields = Map::from_iter([
            ("destination_workspace".into(), Value::String(destination_workspace)),
            ("destination_screen".into(), Value::String(destination_screen)),
            ("destination_pane".into(), Value::String(destination_pane)),
            ("index".into(), Value::from(u64::try_from(index).unwrap_or(u64::MAX))),
        ]);
        let Ok(commit) =
            self.commit_ordinary_topology_operation(ResourceOperation::TabMove, selectors, fields)
        else {
            return false;
        };
        if let Some(surface) = self.surface(surface)
            && let Some(workspace_key) = self.workspace_key_for_pane(pane)
        {
            let _ = surface.persist_host_workspace(&workspace_key);
        }
        self.emit_resource_topology_legacy_events(ResourceOperation::TabMove, &commit);
        if let Some(screen) = changed_screen.filter(|source| {
            self.with_state(|state| {
                state
                    .workspaces
                    .iter()
                    .any(|workspace| workspace.screens.iter().any(|screen| screen.id == *source))
            })
        }) {
            self.emit(MuxEvent::LayoutChanged(screen));
        }
        true
    }

    /// Reorder a workspace. The active workspace follows the moved entry.
    pub fn move_workspace(&self, workspace: WorkspaceId, index: usize) -> bool {
        self.move_workspace_at_revision(workspace, index, None)
            .map(|result| result.is_some_and(|(_, changed)| changed))
            .unwrap_or(false)
    }

    pub fn move_workspace_at_revision(
        &self,
        workspace: WorkspaceId,
        index: usize,
        expected_revision: Option<u64>,
    ) -> anyhow::Result<Option<(u64, bool)>> {
        {
            let state = self.state.lock().unwrap();
            let Some(old_index) = state.workspace_index(workspace) else {
                return Ok(None);
            };
            if let Some(expected) = expected_revision
                && expected != state.workspace_revision
            {
                anyhow::bail!(
                    "workspace revision conflict: expected {expected}, current {}",
                    state.workspace_revision
                );
            }
            let new_index = if index > old_index { index.saturating_sub(1) } else { index };
            let new_index = new_index.min(state.workspaces.len().saturating_sub(1));
            if new_index == old_index {
                return Ok(Some((state.workspace_revision, false)));
            }
        }
        let mutation = WorkspaceMutation::local("cmux-tui");
        let result = self.move_workspace_with_mutation(
            Some(workspace),
            None,
            index,
            None,
            expected_revision,
            &mutation,
        )?;
        Ok(Some((result.revision, result.changed)))
    }

    #[allow(clippy::too_many_arguments)]
    pub fn move_workspace_with_mutation(
        &self,
        workspace: Option<WorkspaceId>,
        requested_key: Option<&str>,
        index: usize,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
    ) -> anyhow::Result<WorkspaceMutationResult> {
        let fingerprint = serde_json::json!({
            "op": "move-workspace",
            "workspace": workspace,
            "key": requested_key,
            "index": index,
        });
        let notifications = self.surface_notifications();
        let mut registry = self.workspace_registry.lock().unwrap();
        if let Some(commit) = registry.replay(mutation, &fingerprint)? {
            return workspace_mutation_result(&commit);
        }
        let (delta, result) = {
            let mut state = self.state.lock().unwrap();
            Self::require_workspace_revision(&state, expected_revision)?;
            let old_idx = resolve_workspace_index(&state, workspace, requested_key)?;
            let workspace_id = state.workspaces[old_idx].id;
            let key = state.workspaces[old_idx].key.clone();
            // Protocol v7 uses insertion-point semantics. Once the source is
            // removed, insertion points to its right shift left by one.
            let new_idx = if index > old_idx { index.saturating_sub(1) } else { index };
            let new_idx = new_idx.min(state.workspaces.len().saturating_sub(1));
            let changed = new_idx != old_idx;
            let mut desired = self.registry_projection(&state);
            let desired_workspace = desired.remove(old_idx);
            desired.insert(new_idx, desired_workspace);
            let desired_active_workspace =
                state.workspaces.get(state.active_workspace).map(|workspace| &workspace.public_id);
            let commit = registry.commit_with_active_workspace(
                mutation,
                &fingerprint,
                expected_generation,
                expected_revision,
                "workspace-moved",
                &key,
                &desired,
                desired_active_workspace,
                &serde_json::json!({
                    "workspace": workspace_id,
                    "key": key.clone(),
                    "index": new_idx,
                    "changed": changed,
                }),
            )?;
            let resource_revision = registry.snapshot()?.resource_revision;
            let active_id = state.workspaces.get(state.active_workspace).map(|ws| ws.id);
            state.move_workspace(old_idx, new_idx);
            state.active_workspace = active_id
                .and_then(|id| state.workspace_index(id))
                .unwrap_or_else(|| state.workspaces.len().saturating_sub(1));
            Self::rebuild_split_screen_index(&mut state);
            state.workspace_revision = commit.revision;
            state.resource_revision = resource_revision;
            let workspace_revision = commit.revision;
            let entity = crate::server::tree_entity_json(
                &state,
                &notifications,
                TreeDeltaKind::WorkspaceMoved,
                workspace_id,
            )
            .expect("moved workspace is present in tree snapshot");
            (
                TreeDelta {
                    kind: TreeDeltaKind::WorkspaceMoved,
                    workspace: workspace_id,
                    screen: None,
                    pane: None,
                    surface: None,
                    index: Some(new_idx),
                    entity,
                    workspace_revision: Some(workspace_revision),
                },
                workspace_mutation_result(&commit)?,
            )
        };
        drop(registry);
        self.publish_resource_event();
        self.emit(MuxEvent::TreeDelta(delta));
        Ok(result)
    }

    /// Select a tab within a pane (default: the active pane) by index or
    /// relative delta.
    pub fn select_tab(
        self: &Arc<Self>,
        pane: Option<PaneId>,
        index: Option<usize>,
        delta: Option<isize>,
    ) {
        let surface = {
            let state = self.state.lock().unwrap();
            let Some(target) = pane.or_else(|| state.active_pane()) else { return };
            let Some(pane) = state.panes.get(&target) else { return };
            let len = pane.tabs.len();
            if len == 0 {
                return;
            }
            let selected = if let Some(index) = index.filter(|index| *index < len) {
                index
            } else if let Some(delta) = delta {
                ((pane.active_tab as isize + delta).rem_euclid(len as isize)) as usize
            } else {
                pane.active_tab
            };
            pane.tabs[selected]
        };
        let Some(selectors) = self.ordinary_tab_selectors(surface) else { return };
        if self.commit_ordinary_tab_selection(selectors).is_err() {
            return;
        }
        let viewed = self.with_state(Self::active_surface_in_state);
        self.clear_viewed_notification(viewed);
        self.emit(MuxEvent::TreeChanged);
    }

    /// Select a screen in the active workspace by index or relative delta.
    pub fn select_screen(self: &Arc<Self>, index: Option<usize>, delta: Option<isize>) {
        let screen = {
            let state = self.state.lock().unwrap();
            let active = state.active_workspace;
            let Some(ws) = state.workspaces.get(active) else { return };
            let len = ws.screens.len();
            if len == 0 {
                return;
            }
            let selected = if let Some(index) = index.filter(|index| *index < len) {
                index
            } else if let Some(delta) = delta {
                ((ws.active_screen as isize + delta).rem_euclid(len as isize)) as usize
            } else {
                ws.active_screen
            };
            ws.screens[selected].id
        };
        let Some(selectors) = self.ordinary_screen_selectors(screen) else { return };
        if self
            .commit_ordinary_topology_operation(
                ResourceOperation::ScreenFocus,
                selectors,
                Map::new(),
            )
            .is_err()
        {
            return;
        }
        let viewed = self.with_state(Self::active_surface_in_state);
        self.clear_viewed_notification(viewed);
        self.emit(MuxEvent::TreeChanged);
    }

    /// Select a workspace by index or relative delta.
    pub fn select_workspace(self: &Arc<Self>, index: Option<usize>, delta: Option<isize>) {
        let workspace = {
            let state = self.state.lock().unwrap();
            let len = state.workspaces.len();
            if len == 0 {
                return;
            }
            let selected = if let Some(index) = index.filter(|index| *index < len) {
                index
            } else if let Some(delta) = delta {
                ((state.active_workspace as isize + delta).rem_euclid(len as isize)) as usize
            } else {
                state.active_workspace
            };
            state.workspaces[selected].id
        };
        let Some(selectors) = self.ordinary_workspace_selectors(workspace) else { return };
        if self
            .commit_ordinary_topology_operation(
                ResourceOperation::WorkspaceFocus,
                selectors,
                Map::new(),
            )
            .is_err()
        {
            return;
        }
        let viewed = self.with_state(Self::active_surface_in_state);
        self.clear_viewed_notification(viewed);
        self.emit(MuxEvent::TreeChanged);
    }
}

fn persist_public_topology_result(
    operation: &str,
    result: &mut Value,
    changes: &Value,
) -> anyhow::Result<()> {
    let Some((resource, identity_field)) = public_topology_result_target(operation) else {
        return Ok(());
    };
    let id = result
        .get(identity_field)
        .and_then(Value::as_str)
        .with_context(|| format!("{operation} result omitted its {identity_field} identity"))?;
    let value = changes
        .as_array()
        .context("public topology changes are not an array")?
        .iter()
        .rev()
        .find(|change| {
            change["kind"] == "upsert"
                && change["resource"] == resource
                && change["id"].as_str() == Some(id)
        })
        .and_then(|change| change.get("value"))
        .cloned()
        .with_context(|| {
            format!("{operation} changes omitted the committed {resource} value for {id}")
        })?;
    result
        .as_object_mut()
        .context("public topology result is not an object")?
        .insert("public_value".to_string(), value);
    Ok(())
}

fn public_topology_result_target(operation: &str) -> Option<(&'static str, &'static str)> {
    match operation {
        "workspace.rename" | "workspace.move" | "workspace.focus" | "workspace.layout.apply" => {
            Some(("workspace", "workspace"))
        }
        "screen.rename" | "screen.focus" | "screen.layout.undo" => Some(("screen", "screen")),
        "pane.rename"
        | "pane.focus"
        | "pane.focus_direction"
        | "pane.swap"
        | "pane.zoom"
        | "pane.split_ratio.set"
        | "pane.viewport_width.set" => Some(("pane", "pane")),
        "tab.rename" | "tab.move" | "tab.focus" => Some(("tab", "tab")),
        _ => None,
    }
}

fn terminal_launch_spec(options: &SurfaceOptions) -> Value {
    let cmux_env = options
        .extra_env
        .iter()
        .map(|(key, _)| key.as_str())
        .filter(|key| matches!(*key, "CMUX_TUI_SOCKET" | "CMUX_MUX_SOCKET" | "CMUX_SIDEBAR"))
        .collect::<Vec<_>>();
    serde_json::json!({
        // This is diagnostic shape, not a respawn recipe. argv and cwd can
        // both contain credentials and missing hosts are never recreated.
        "command_present": options.command.is_some(),
        "cwd_present": options.cwd.is_some(),
        "term": options.term,
        "cols": options.cols,
        "rows": options.rows,
        "scrollback": options.scrollback,
        // Values are deliberately absent: launch environments routinely
        // contain bearer credentials and SQLite is durable frontend state,
        // not a secret store or a shell-respawn recipe.
        "cmux_env": cmux_env,
    })
}

/// Durable exactly-once metadata must distinguish retries without turning the
/// workspace registry into a second secret store. Command arguments, cwd, and
/// user-provided names can all contain credentials, so only their digest is
/// persisted alongside the non-secret routing identity.
fn terminal_create_fingerprint(
    workspace_key: &str,
    terminal_id: Option<&str>,
    argv: Option<&[String]>,
    cwd: Option<&str>,
    name: Option<&str>,
    size: Option<(u16, u16)>,
) -> anyhow::Result<Value> {
    let request = serde_json::json!({
        "argv": argv,
        "cwd": cwd,
        "name": name,
        "size": size,
    });
    let digest = Sha256::digest(serde_json::to_vec(&request)?);
    let request_sha256 = digest.iter().map(|byte| format!("{byte:02x}")).collect::<String>();
    Ok(serde_json::json!({
        "op": "create-terminal",
        "workspace_key": workspace_key,
        "terminal_id": terminal_id,
        "request_sha256": request_sha256,
    }))
}

fn terminal_lifecycle_name(lifecycle: TerminalLifecycle) -> &'static str {
    match lifecycle {
        TerminalLifecycle::Launching => "launching",
        TerminalLifecycle::Adopting => "adopting",
        TerminalLifecycle::Running => "running",
        TerminalLifecycle::Exited => "exited",
        TerminalLifecycle::Tombstoned => "tombstoned",
    }
}

fn run_placement_for_surface(state: &State, surface: SurfaceId) -> Option<RunPlacement> {
    let pane = state.pane_of(surface)?;
    let (workspace_index, screen_index) = state.screen_of(pane)?;
    Some(RunPlacement {
        surface,
        pane,
        screen: state.workspaces[workspace_index].screens[screen_index].id,
        workspace: state.workspaces[workspace_index].id,
    })
}

fn terminal_exit_snapshot_in_state(
    registry: &WorkspaceRegistry,
    state: &State,
    terminal_id: &str,
) -> anyhow::Result<Value> {
    let public_id = registry
        .terminal_resource_id(terminal_id)?
        .ok_or_else(|| anyhow::anyhow!("terminal {terminal_id} has no public resource id"))?;
    let content_id = ContentPublicId::Terminal(public_id.clone());
    let topology = registry.resource_topology_snapshot()?;
    let tab = topology
        .tabs
        .iter()
        .find(|tab| tab.content_id == content_id)
        .ok_or_else(|| anyhow::anyhow!("terminal {public_id} has no durable tab"))?;
    let surface =
        state.resource_indexes.content.get(&content_id).and_then(|slot| state.surfaces.get(slot));
    let (cols, rows) = surface.map(|surface| surface.size()).unwrap_or((80, 24));
    let mut snapshot = serde_json::json!({
        "id": public_id,
        "tab_id": tab.public_id,
        "title": surface.map(|surface| surface.title()).unwrap_or_default(),
        "cols": cols.max(1),
        "rows": rows.max(1),
        "running": false,
    });
    if let Some(cwd) = surface.and_then(|surface| surface.spawn_cwd()) {
        snapshot["cwd"] = serde_json::json!(cwd);
    }
    Ok(snapshot)
}

type FocusIdentity = (WorkspaceId, ScreenId, PaneId);

fn current_focus_identity(state: &State) -> Option<FocusIdentity> {
    let workspace = state.workspaces.get(state.active_workspace)?;
    let screen = workspace.active_screen_ref()?;
    Some((workspace.id, screen.id, screen.active_pane))
}

fn restore_focus_identity(state: &mut State, focus: Option<FocusIdentity>) {
    let Some((workspace_id, screen_id, pane_id)) = focus else { return };
    let Some(workspace_index) = state.workspace_index(workspace_id) else { return };
    state.active_workspace = workspace_index;
    let Some(screen_index) =
        state.workspaces[workspace_index].screens.iter().position(|screen| screen.id == screen_id)
    else {
        return;
    };
    state.workspaces[workspace_index].active_screen = screen_index;
    if state.workspaces[workspace_index].screens[screen_index].root.contains(pane_id) {
        state.workspaces[workspace_index].screens[screen_index].active_pane = pane_id;
    }
}

fn commit_terminal_transition(
    registry: &mut WorkspaceRegistry,
    event_kind: &str,
    operation: &str,
    terminal: &RegistryTerminal,
) -> anyhow::Result<u64> {
    let mutation = WorkspaceMutation::local("cmux-tui-runtime");
    let commit = registry.commit_terminal(
        &mutation,
        &serde_json::json!({
            "op": operation,
            "terminal_id": terminal.terminal_id,
            "workspace_key": terminal.workspace_key,
            "incarnation": terminal.incarnation,
            "lifecycle": terminal.lifecycle,
        }),
        None,
        None,
        event_kind,
        terminal,
        &serde_json::json!({
            "terminal_id": terminal.terminal_id,
            "workspace_key": terminal.workspace_key,
            "incarnation": terminal.incarnation,
            "state": terminal.lifecycle,
        }),
    )?;
    Ok(commit.revision)
}

/// Advance only renderer lifecycle fields from the latest durable row. This
/// deliberately re-reads under the registry writer mutex and uses the
/// terminal revision as a CAS: a GUI move committed while a host launch or
/// adoption was in flight can never be overwritten by a stale row clone.
fn commit_terminal_lifecycle(
    registry: &mut WorkspaceRegistry,
    event_kind: &str,
    operation: &str,
    terminal_id: &str,
    lifecycle: TerminalLifecycle,
    incarnation: Option<&str>,
    exit: Option<Value>,
) -> anyhow::Result<(RegistryTerminal, u64)> {
    let snapshot = registry.terminal_snapshot()?;
    let mut terminal = registry
        .terminal_record(terminal_id)?
        .ok_or_else(|| anyhow::anyhow!("unknown terminal {terminal_id}"))?;
    terminal.lifecycle = lifecycle;
    if let Some(incarnation) = incarnation {
        terminal.incarnation = Some(incarnation.to_string());
    }
    terminal.exit = exit;
    let mutation = WorkspaceMutation::local("cmux-tui-runtime");
    let commit = registry.commit_terminal(
        &mutation,
        &serde_json::json!({
            "op": operation,
            "terminal_id": terminal.terminal_id,
            "incarnation": terminal.incarnation,
            "lifecycle": terminal.lifecycle,
        }),
        Some(&snapshot.generation),
        Some(snapshot.revision),
        event_kind,
        &terminal,
        &serde_json::json!({
            "terminal_id": terminal.terminal_id,
            "workspace_key": terminal.workspace_key,
            "incarnation": terminal.incarnation,
            "state": terminal.lifecycle,
        }),
    )?;
    Ok((terminal, commit.revision))
}

#[cfg(test)]
fn commit_terminal_workspace(
    registry: &mut WorkspaceRegistry,
    terminal_id: &str,
    workspace_key: &str,
) -> anyhow::Result<u64> {
    let snapshot = registry.terminal_snapshot()?;
    let mut terminal = registry
        .terminal_record(terminal_id)?
        .ok_or_else(|| anyhow::anyhow!("unknown terminal {terminal_id}"))?;
    if terminal.lifecycle == TerminalLifecycle::Tombstoned {
        anyhow::bail!("terminal is already closed");
    }
    terminal.workspace_key = workspace_key.to_string();
    let mutation = WorkspaceMutation::local("cmux-tui-runtime");
    let commit = registry.commit_terminal(
        &mutation,
        &serde_json::json!({
            "op":"move-terminal",
            "terminal_id":terminal_id,
            "workspace_key":workspace_key,
        }),
        Some(&snapshot.generation),
        Some(snapshot.revision),
        "terminal-moved",
        &terminal,
        &serde_json::json!({
            "terminal_id":terminal_id,
            "workspace_key":workspace_key,
            "incarnation":terminal.incarnation,
            "state":terminal.lifecycle,
        }),
    )?;
    Ok(commit.revision)
}

#[cfg(unix)]
fn terminate_host_record(
    record: crate::terminal_host_runtime::TerminalHostRecord,
    record_path: std::path::PathBuf,
) -> bool {
    if let Ok(host) = crate::terminal_host_runtime::adopt_terminal_host(record, record_path) {
        let terminated = host.terminate().is_ok();
        host.disconnect();
        terminated
    } else {
        false
    }
}

#[cfg(unix)]
fn terminal_host_record_liveness(
    record_path: &Path,
    record: &crate::terminal_host_runtime::TerminalHostRecord,
) -> TerminalHostLiveness {
    crate::terminal_host_runtime::terminal_host_record_liveness(record_path, record)
        .unwrap_or(TerminalHostLiveness::Indeterminate)
}

/// Ask a host to terminate first; if its admin socket is unavailable, remove
/// discovery artifacts only when the process-start nonce positively proves
/// this exact incarnation is dead. `false` means the live/ambiguous record is
/// deliberately retained for a later retry.
#[cfg(unix)]
fn cleanup_terminal_host_record(
    record: &crate::terminal_host_runtime::TerminalHostRecord,
    record_path: &Path,
) -> bool {
    match terminal_host_record_liveness(record_path, record) {
        TerminalHostLiveness::Dead => {
            match crate::terminal_host_runtime::remove_stale_terminal_host_record(
                record_path,
                record,
            ) {
                Ok(removed) => removed,
                // Positive nonce/PID death proof remains authoritative when
                // the host already removed its own record between probe and
                // compare-delete.
                Err(_) if !record_path.exists() => true,
                Err(_) => false,
            }
        }
        TerminalHostLiveness::Live | TerminalHostLiveness::Indeterminate => {
            terminate_host_record(record.clone(), record_path.to_path_buf())
        }
    }
}

fn bounded_shutdown_fanout<T: Sync>(
    items: &[T],
    deadline: Instant,
    operation: impl Fn(&T, Instant) + Sync,
) -> usize {
    if items.is_empty() {
        return 0;
    }
    let next = AtomicUsize::new(0);
    let workers = items.len().min(SHUTDOWN_FANOUT_WORKERS);
    std::thread::scope(|scope| {
        for worker in 0..workers {
            let next = &next;
            let operation = &operation;
            let spawned = std::thread::Builder::new()
                .name(format!("shutdown-owner-{worker}"))
                .spawn_scoped(scope, move || {
                    loop {
                        if Instant::now() >= deadline {
                            break;
                        }
                        let index = next.fetch_add(1, Ordering::Relaxed);
                        let Some(item) = items.get(index) else { break };
                        operation(item, deadline);
                    }
                });
            if spawned.is_err() {
                break;
            }
        }
    });
    next.load(Ordering::Relaxed).min(items.len())
}

fn insert_surface_checked(
    mux: &Mux,
    state: &mut State,
    surface: Arc<Surface>,
) -> anyhow::Result<()> {
    validate_surface_insertion(state, &surface)?;
    if state
        .surfaces
        .len()
        .saturating_add(mux.shutdown_owners.len())
        .saturating_add(mux.surface_owner_reservations.load(Ordering::Acquire))
        >= mux.shutdown_owner_capacity()
    {
        anyhow::bail!("surface_owner_capacity_exhausted");
    }
    state.surfaces.insert(surface.id, surface);
    Ok(())
}

fn insert_reserved_surface_checked(
    mux: &Mux,
    state: &mut State,
    surface: Arc<Surface>,
    reservation: &mut SurfaceOwnerReservation<'_>,
) -> anyhow::Result<()> {
    validate_surface_insertion(state, &surface)?;
    if state
        .surfaces
        .len()
        .saturating_add(mux.shutdown_owners.len())
        .saturating_add(mux.surface_owner_reservations.load(Ordering::Acquire))
        > mux.shutdown_owner_capacity()
    {
        anyhow::bail!("surface_owner_capacity_exhausted");
    }
    state.surfaces.insert(surface.id, surface);
    reservation.release();
    Ok(())
}

fn insert_surface_with_active_reservation_checked(
    mux: &Mux,
    state: &mut State,
    surface: Arc<Surface>,
) -> anyhow::Result<()> {
    validate_surface_insertion(state, &surface)?;
    if state
        .surfaces
        .len()
        .saturating_add(mux.shutdown_owners.len())
        .saturating_add(mux.surface_owner_reservations.load(Ordering::Acquire))
        > mux.shutdown_owner_capacity()
    {
        anyhow::bail!("surface_owner_capacity_exhausted");
    }
    state.surfaces.insert(surface.id, surface);
    Ok(())
}

fn validate_surface_insertion(state: &State, surface: &Surface) -> anyhow::Result<()> {
    if state.surfaces.contains_key(&surface.id) {
        anyhow::bail!("duplicate_surface_id");
    }
    if let Some(expected_tab) = state.resource_indexes.tab_ids.get(&surface.id) {
        let expected_content = state
            .resource_indexes
            .content_ids
            .get(&surface.id)
            .ok_or_else(|| anyhow::anyhow!("reserved tab has no content identity"))?;
        let actual = surface
            .resource_identity()
            .ok_or_else(|| anyhow::anyhow!("public tab slot received auxiliary content"))?;
        if &actual.tab_id != expected_tab || &actual.content_id != expected_content {
            anyhow::bail!("surface resource identity does not match its reserved tab slot");
        }
    } else if let Some(identity) = surface.resource_identity() {
        if state.resource_indexes.tabs.contains_key(&identity.tab_id) {
            anyhow::bail!("duplicate_tab_id");
        }
        if state.resource_indexes.content.contains_key(&identity.content_id) {
            anyhow::bail!("duplicate_content_id");
        }
    }
    if let Some(identity) = surface.terminal_host_identity()
        && unique_terminal_match(
            &identity.terminal_id,
            state.surfaces.values().filter_map(|surface| {
                surface.terminal_host_identity().map(|identity| (surface.id, identity))
            }),
        )?
        .is_some()
    {
        anyhow::bail!("duplicate_terminal_id");
    }
    Ok(())
}

fn validate_terminal_hex(value: &str, error: &'static str) -> anyhow::Result<()> {
    if TerminalId::from_hex(value).is_none() {
        anyhow::bail!(error);
    }
    Ok(())
}

fn unique_terminal_match(
    terminal_id: &str,
    identities: impl IntoIterator<Item = (SurfaceId, TerminalHostIdentity)>,
) -> anyhow::Result<Option<(SurfaceId, TerminalHostIdentity)>> {
    let mut found = None;
    for (surface, identity) in identities {
        if identity.terminal_id != terminal_id {
            continue;
        }
        if found.is_some() {
            anyhow::bail!("duplicate_terminal_id");
        }
        found = Some((surface, identity));
    }
    Ok(found)
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as u64)
        .unwrap_or(0)
}

fn sidebar_retry_delay(failures: u32) -> Duration {
    let shift = failures.saturating_sub(1).min(5);
    Duration::from_secs(1u64 << shift)
}

impl Drop for Mux {
    fn drop(&mut self) {
        self.shutdown_owner_reconciler.stop();
        if let Ok(watchers) = self.shutdown_request_watchers.get_mut() {
            for watcher in watchers.drain(..).filter_map(|watcher| watcher.upgrade()) {
                ShutdownRequestWatch { inner: watcher }.cancel();
            }
        }
        if let Ok(state) = self.state.get_mut() {
            for surface in state.surfaces.values() {
                surface.disconnect_for_daemon_shutdown();
            }
        }
        if let Some(runtime) = self.browser_runtime.take_on_drop() {
            runtime.shutdown();
        }
    }
}

fn restore_resource_state(
    snapshot: RegistrySnapshot,
    topology: ResourceTopologySnapshot,
) -> anyhow::Result<RestoredResourceState> {
    anyhow::ensure!(
        topology.session_id == snapshot.session_id,
        "resource topology belongs to a different session"
    );
    anyhow::ensure!(
        topology.generation == snapshot.generation,
        "resource topology generation changed during startup"
    );
    anyhow::ensure!(
        topology.revision == snapshot.resource_revision,
        "resource topology revision changed during startup"
    );

    let mut next_id = snapshot.next_numeric_id.max(1);
    let mut allocate = || -> anyhow::Result<u64> {
        let id = next_id;
        next_id =
            next_id.checked_add(1).ok_or_else(|| anyhow::anyhow!("runtime id space exhausted"))?;
        Ok(id)
    };

    let workspace_revision = snapshot.revision;
    let resource_revision = snapshot.resource_revision;
    let mut workspaces = snapshot
        .workspaces
        .into_iter()
        .map(|workspace| Workspace {
            id: workspace.id,
            public_id: workspace.public_id,
            key: workspace.key,
            name: workspace.name,
            screens: Vec::new(),
            active_screen: 0,
        })
        .collect::<Vec<_>>();
    let workspace_index_by_public = workspaces
        .iter()
        .enumerate()
        .map(|(index, workspace)| (workspace.public_id.clone(), index))
        .collect::<HashMap<_, _>>();

    let mut screen_slots = HashMap::new();
    for screen in &topology.screens {
        let old = screen_slots.insert(screen.public_id.clone(), allocate()?);
        anyhow::ensure!(old.is_none(), "duplicate screen {}", screen.public_id);
    }
    let mut pane_slots = HashMap::new();
    for pane in &topology.panes {
        let old = pane_slots.insert(pane.public_id.clone(), allocate()?);
        anyhow::ensure!(old.is_none(), "duplicate pane {}", pane.public_id);
    }
    let mut tab_slots = HashMap::new();
    for tab in &topology.tabs {
        let old = tab_slots.insert(tab.public_id.clone(), allocate()?);
        anyhow::ensure!(old.is_none(), "duplicate tab {}", tab.public_id);
    }

    let mut indexes = PublicSlotIndexes::default();
    for workspace in &workspaces {
        anyhow::ensure!(
            indexes.workspaces.insert(workspace.public_id.clone(), workspace.id).is_none(),
            "duplicate workspace {}",
            workspace.public_id
        );
        indexes.workspace_ids.insert(workspace.id, workspace.public_id.clone());
    }
    for (public_id, slot) in &screen_slots {
        indexes.screens.insert(public_id.clone(), *slot);
        indexes.screen_ids.insert(*slot, public_id.clone());
    }
    for (public_id, slot) in &pane_slots {
        indexes.panes.insert(public_id.clone(), *slot);
        indexes.pane_ids.insert(*slot, public_id.clone());
    }

    let mut browsers_by_id = topology
        .browsers
        .iter()
        .cloned()
        .map(|browser| (browser.public_id.clone(), browser))
        .collect::<HashMap<_, _>>();
    anyhow::ensure!(
        browsers_by_id.len() == topology.browsers.len(),
        "resource topology contains duplicate browser metadata"
    );
    let mut tabs_by_pane = HashMap::<PanePublicId, Vec<RegistryTab>>::new();
    let mut contents = Vec::with_capacity(topology.tabs.len());
    for tab in topology.tabs {
        let browser = match (&tab.content_id, &tab.browser_url, &tab.terminal_id) {
            (ContentPublicId::Terminal(_), None, Some(_)) => None,
            (ContentPublicId::Browser(browser_id), Some(url), None) => {
                let browser = browsers_by_id.remove(browser_id).ok_or_else(|| {
                    anyhow::anyhow!("browser tab {} has no restart metadata", tab.public_id)
                })?;
                anyhow::ensure!(
                    &browser.url == url,
                    "browser tab {} URL disagrees with its restart metadata",
                    tab.public_id
                );
                Some(browser)
            }
            _ => {
                anyhow::bail!("tab {} has inconsistent persisted content metadata", tab.public_id)
            }
        };
        let slot = tab_slots[&tab.public_id];
        let identity = TabResourceIdentity::new(tab.public_id.clone(), tab.content_id.clone());
        anyhow::ensure!(
            indexes.tabs.insert(tab.public_id.clone(), slot).is_none(),
            "duplicate tab {}",
            tab.public_id
        );
        indexes.tab_ids.insert(slot, tab.public_id.clone());
        anyhow::ensure!(
            indexes.content.insert(tab.content_id.clone(), slot).is_none(),
            "duplicate content {}",
            tab.content_id.as_str()
        );
        indexes.content_ids.insert(slot, tab.content_id.clone());
        contents.push(RestoredResourceContent { slot, identity, name: tab.name.clone(), browser });
        tabs_by_pane.entry(tab.pane_id.clone()).or_default().push(tab);
    }
    anyhow::ensure!(
        browsers_by_id.is_empty(),
        "resource topology contains orphan browser metadata"
    );
    for tabs in tabs_by_pane.values_mut() {
        tabs.sort_by_key(|tab| tab.position);
    }

    let mut panes = HashMap::new();
    for pane in &topology.panes {
        let id = pane_slots[&pane.public_id];
        let pane_tabs = tabs_by_pane.get(&pane.public_id).map(Vec::as_slice).unwrap_or_default();
        let tabs = pane_tabs.iter().map(|tab| tab_slots[&tab.public_id]).collect::<Vec<_>>();
        let active_tab = match pane.active_tab.as_ref() {
            Some(active) => {
                pane_tabs.iter().position(|tab| &tab.public_id == active).ok_or_else(|| {
                    anyhow::anyhow!("pane {} has unknown active tab {}", pane.public_id, active)
                })?
            }
            None if pane_tabs.is_empty() => 0,
            None => anyhow::bail!("pane {} has tabs but no active tab", pane.public_id),
        };
        anyhow::ensure!(
            panes
                .insert(
                    id,
                    Pane {
                        id,
                        public_id: pane.public_id.clone(),
                        name: pane.name.clone(),
                        tabs,
                        active_tab,
                        active_at: pane.creation_ordinal,
                        focused_at: 0,
                    },
                )
                .is_none(),
            "duplicate pane slot {id}"
        );
        let screen = *screen_slots
            .get(&pane.screen_id)
            .ok_or_else(|| anyhow::anyhow!("pane {} has unknown screen", pane.public_id))?;
        indexes.pane_screen.insert(id, screen);
        for tab in pane_tabs {
            indexes.tab_pane.insert(tab_slots[&tab.public_id], id);
        }
    }

    let mut split_slots = HashMap::<SplitPublicId, SplitId>::new();
    let mut screens_by_workspace = HashMap::<WorkspacePublicId, Vec<(usize, Screen)>>::new();
    for screen in &topology.screens {
        let expected_panes = topology
            .panes
            .iter()
            .filter(|pane| pane.screen_id == screen.public_id)
            .map(|pane| pane.public_id.clone())
            .collect::<HashSet<_>>();
        crate::workspace_registry::validate_registry_screen_projection(screen, &expected_panes)?;
        let id = screen_slots[&screen.public_id];
        let root =
            restore_layout_node(&screen.layout, &pane_slots, &mut split_slots, &mut allocate)?;
        let active_pane = *pane_slots.get(&screen.active_pane).ok_or_else(|| {
            anyhow::anyhow!("screen {} has unknown active pane", screen.public_id)
        })?;
        let zoomed_pane = screen
            .zoomed_pane
            .as_ref()
            .map(|pane| {
                pane_slots.get(pane).copied().ok_or_else(|| {
                    anyhow::anyhow!("screen {} has unknown zoomed pane {}", screen.public_id, pane)
                })
            })
            .transpose()?;
        let zellij_auto_layout = screen
            .auto_layout
            .as_ref()
            .map(|panes| {
                panes
                    .iter()
                    .map(|pane| {
                        pane_slots.get(pane).copied().ok_or_else(|| {
                            anyhow::anyhow!(
                                "screen {} auto-layout has unknown pane {}",
                                screen.public_id,
                                pane
                            )
                        })
                    })
                    .collect::<anyhow::Result<Vec<_>>>()
            })
            .transpose()?;
        let (viewport_splits, viewport_base_width, layout_columns) = restore_registry_viewport(
            &screen.viewport,
            &pane_slots,
            &mut split_slots,
            &mut allocate,
        )?;
        indexes.screen_workspace.insert(
            id,
            workspaces[*workspace_index_by_public.get(&screen.workspace_id).ok_or_else(|| {
                anyhow::anyhow!("screen {} has unknown workspace", screen.public_id)
            })?]
            .id,
        );
        let restored_screen = Screen {
            id,
            public_id: screen.public_id.clone(),
            name: screen.name.clone(),
            root,
            active_pane,
            zoomed_pane,
            zellij_auto_layout,
            viewport_splits,
            viewport_base_width,
            layout_columns,
            layout_revision: 0,
            layout_undo: Default::default(),
        };
        anyhow::ensure!(
            restored_screen.layout_column_projection_is_consistent(),
            "screen {} has inconsistent viewport projection",
            screen.public_id
        );
        screens_by_workspace
            .entry(screen.workspace_id.clone())
            .or_default()
            .push((screen.position, restored_screen));
    }
    for (workspace_id, mut screens) in screens_by_workspace {
        screens.sort_by_key(|(position, _)| *position);
        let workspace_index = workspace_index_by_public[&workspace_id];
        workspaces[workspace_index].screens =
            screens.into_iter().map(|(_, screen)| screen).collect();
    }
    let mut active_screens = HashMap::new();
    for (workspace, active) in topology.active_screens {
        anyhow::ensure!(
            active_screens.insert(workspace.clone(), active).is_none(),
            "workspace {workspace} has duplicate active-screen metadata"
        );
    }
    anyhow::ensure!(
        active_screens.len() == workspaces.len()
            && workspaces.iter().all(|workspace| active_screens.contains_key(&workspace.public_id)),
        "active-screen metadata does not exactly cover the live workspaces"
    );
    for workspace in &mut workspaces {
        workspace.active_screen = match active_screens[&workspace.public_id].as_ref() {
            Some(active) => {
                workspace.screens.iter().position(|screen| &screen.public_id == active).ok_or_else(
                    || {
                        anyhow::anyhow!(
                            "workspace {} has unknown active screen {}",
                            workspace.public_id,
                            active
                        )
                    },
                )?
            }
            None if workspace.screens.is_empty() => 0,
            None => {
                anyhow::bail!("workspace {} has screens but no active screen", workspace.public_id)
            }
        };
    }
    let active_workspace = match topology.active_workspace.as_ref() {
        Some(active) => workspaces
            .iter()
            .position(|workspace| &workspace.public_id == active)
            .ok_or_else(|| anyhow::anyhow!("unknown active workspace {active}"))?,
        None if workspaces.is_empty() => 0,
        None => anyhow::bail!("session has workspaces but no active workspace"),
    };

    for (public_id, slot) in split_slots {
        indexes.splits.insert(public_id.clone(), slot);
        indexes.split_ids.insert(slot, public_id);
    }
    let workspace_index_by_id =
        workspaces.iter().enumerate().map(|(index, workspace)| (workspace.id, index)).collect();
    let workspace_id_by_key =
        workspaces.iter().map(|workspace| (workspace.key.clone(), workspace.id)).collect();
    Ok(RestoredResourceState {
        state: State {
            workspaces,
            workspace_index_by_id,
            workspace_id_by_key,
            workspace_revision,
            pane_revision: panes.len() as u64,
            resource_revision,
            focus_sequence: 0,
            active_workspace,
            panes,
            surfaces: HashMap::new(),
            split_screens: HashMap::new(),
            resource_indexes: indexes,
        },
        next_id,
        contents,
    })
}

fn restore_layout_node(
    node: &RegistryLayoutNode,
    panes: &HashMap<PanePublicId, PaneId>,
    splits: &mut HashMap<SplitPublicId, SplitId>,
    allocate: &mut impl FnMut() -> anyhow::Result<u64>,
) -> anyhow::Result<Node> {
    Ok(match node {
        RegistryLayoutNode::Leaf { pane } => Node::Leaf(
            *panes.get(pane).ok_or_else(|| anyhow::anyhow!("layout has unknown pane {pane}"))?,
        ),
        RegistryLayoutNode::Split { split, direction, ratio, first, second } => {
            anyhow::ensure!(!splits.contains_key(split), "split {split} appears more than once");
            let id = allocate()?;
            splits.insert(split.clone(), id);
            let dir = match direction.as_str() {
                "right" => SplitDir::Right,
                "down" => SplitDir::Down,
                _ => anyhow::bail!("split {split} has invalid direction {direction:?}"),
            };
            Node::Split {
                id,
                dir,
                ratio: *ratio,
                a: Box::new(restore_layout_node(first, panes, splits, allocate)?),
                b: Box::new(restore_layout_node(second, panes, splits, allocate)?),
            }
        }
        RegistryLayoutNode::Stack { panes: members, expanded } => {
            let members = members
                .iter()
                .map(|pane| {
                    panes
                        .get(pane)
                        .copied()
                        .ok_or_else(|| anyhow::anyhow!("stack has unknown pane {pane}"))
                })
                .collect::<anyhow::Result<Vec<_>>>()?;
            let expanded = *panes
                .get(expanded)
                .ok_or_else(|| anyhow::anyhow!("stack has unknown expanded pane {expanded}"))?;
            Node::stack_with_expanded(members, expanded)
                .ok_or_else(|| anyhow::anyhow!("stored stack is empty or has invalid selection"))?
        }
    })
}

fn restore_registry_viewport(
    viewport: &RegistryViewport,
    panes: &HashMap<PanePublicId, PaneId>,
    splits: &mut HashMap<SplitPublicId, SplitId>,
    allocate: &mut impl FnMut() -> anyhow::Result<u64>,
) -> anyhow::Result<RestoredViewport> {
    if viewport.columns.is_empty() {
        return Ok((Default::default(), None, Vec::new()));
    }
    let mut columns = Vec::with_capacity(viewport.columns.len());
    for (index, column) in viewport.columns.iter().enumerate() {
        let id = match splits.get(&column.id).copied() {
            Some(id) => id,
            None if index == 0 => {
                let id = allocate()?;
                splits.insert(column.id.clone(), id);
                id
            }
            None => anyhow::bail!("viewport references unknown boundary split {}", column.id),
        };
        let root = restore_layout_node_from_known_splits(&column.layout, panes, splits)?;
        let zellij_auto_layout = column
            .auto_layout
            .as_ref()
            .map(|members| {
                members
                    .iter()
                    .map(|pane| {
                        panes.get(pane).copied().ok_or_else(|| {
                            anyhow::anyhow!("viewport auto-layout has unknown pane {pane}")
                        })
                    })
                    .collect::<anyhow::Result<Vec<_>>>()
            })
            .transpose()?;
        columns.push(LayoutColumn { id, width: column.width, root, zellij_auto_layout });
    }
    let viewport_splits = columns.iter().skip(1).map(|column| (column.id, column.width)).collect();
    Ok((viewport_splits, viewport.base_width, columns))
}

fn restore_layout_node_from_known_splits(
    node: &RegistryLayoutNode,
    panes: &HashMap<PanePublicId, PaneId>,
    splits: &HashMap<SplitPublicId, SplitId>,
) -> anyhow::Result<Node> {
    Ok(match node {
        RegistryLayoutNode::Leaf { pane } => Node::Leaf(
            *panes.get(pane).ok_or_else(|| anyhow::anyhow!("layout has unknown pane {pane}"))?,
        ),
        RegistryLayoutNode::Split { split, direction, ratio, first, second } => {
            let id = *splits
                .get(split)
                .ok_or_else(|| anyhow::anyhow!("layout has unknown split {split}"))?;
            let dir = match direction.as_str() {
                "right" => SplitDir::Right,
                "down" => SplitDir::Down,
                _ => anyhow::bail!("split {split} has invalid direction {direction:?}"),
            };
            Node::Split {
                id,
                dir,
                ratio: *ratio,
                a: Box::new(restore_layout_node_from_known_splits(first, panes, splits)?),
                b: Box::new(restore_layout_node_from_known_splits(second, panes, splits)?),
            }
        }
        RegistryLayoutNode::Stack { panes: members, expanded } => {
            let members = members
                .iter()
                .map(|pane| {
                    panes
                        .get(pane)
                        .copied()
                        .ok_or_else(|| anyhow::anyhow!("stack has unknown pane {pane}"))
                })
                .collect::<anyhow::Result<Vec<_>>>()?;
            let expanded = *panes
                .get(expanded)
                .ok_or_else(|| anyhow::anyhow!("stack has unknown expanded pane {expanded}"))?;
            Node::stack_with_expanded(members, expanded)
                .ok_or_else(|| anyhow::anyhow!("stored stack is empty or has invalid selection"))?
        }
    })
}

/// Every surface in a screen (all panes, all tabs).
fn screen_tabs(state: &State, screen: &Screen) -> Vec<SurfaceId> {
    let mut pane_ids = Vec::new();
    screen.root.pane_ids(&mut pane_ids);
    pane_ids
        .iter()
        .filter_map(|id| state.panes.get(id))
        .flat_map(|pane| pane.tabs.iter().copied())
        .collect()
}

fn stamp_pane_focus(mux: &Mux, state: &mut State, pane: PaneId) {
    let focused_at = state.next_focus_sequence();
    let active_at = mux.next_active_at();
    if let Some(pane) = state.panes.get_mut(&pane) {
        pane.active_at = active_at;
        pane.focused_at = focused_at;
    }
}

fn stamp_changed_active_pane(mux: &Mux, state: &mut State, previous: Option<PaneId>) {
    let current = state.active_pane();
    if current != previous
        && let Some(pane) = current
    {
        stamp_pane_focus(mux, state, pane);
    }
}

fn most_recent_pane(state: &State, panes: &[PaneId]) -> Option<PaneId> {
    panes
        .iter()
        .filter_map(|id| state.panes.get(id).map(|pane| (*id, pane.active_at)))
        .max_by_key(|(_, active_at)| *active_at)
        .map(|(id, _)| id)
}

fn clamp_split_ratio(ratio: f32) -> f32 {
    ratio.clamp(0.05, 0.95)
}

fn append_to_auto_layout(
    root: &mut Node,
    auto_layout: &mut Option<Vec<PaneId>>,
    pane: PaneId,
    mut next_id: impl FnMut() -> SplitId,
) {
    let mut panes = auto_layout.clone().unwrap_or_else(|| {
        let mut panes = Vec::new();
        root.pane_ids(&mut panes);
        panes.sort_unstable();
        panes
    });
    let current_panes = root.pane_ids_vec().into_iter().collect::<HashSet<_>>();
    panes.retain(|pane| current_panes.contains(pane));
    panes.push(pane);
    *root = crate::layout::zellij_default_pane_layout_with_ids(&panes, &mut next_id)
        .expect("new pane layout always has at least one pane");
    *auto_layout = Some(panes);
}

fn remove_pane_from_screen_layout(mux: &Mux, screen: &mut Screen, pane: PaneId) -> bool {
    screen.invalidate_layout_undo();
    if screen.layout_columns_active() {
        let Some(index) =
            screen.layout_columns.iter().position(|column| column.root.contains(pane))
        else {
            return true;
        };
        let column = &mut screen.layout_columns[index];
        let root = std::mem::replace(&mut column.root, Node::Leaf(0));
        let stack_expanded = root.stack_expanded_pane();
        match root.remove_leaf(pane) {
            Some(mut root) => {
                if let Some(panes) = column.zellij_auto_layout.as_mut() {
                    panes.retain(|candidate| *candidate != pane);
                    if let Some(layout) =
                        crate::layout::zellij_default_pane_layout_with_ids(panes, &mut || {
                            mux.next_id()
                        })
                    {
                        root = layout;
                        if let Some(expanded) = stack_expanded {
                            root.expand_stack_pane(expanded);
                        }
                    } else {
                        column.zellij_auto_layout = None;
                    }
                }
                column.root = root;
            }
            None => {
                screen.layout_columns.remove(index);
            }
        }
        if screen.layout_columns.is_empty() {
            return false;
        }
        screen.collapse_single_layout_column();
        return true;
    }

    let root = std::mem::replace(&mut screen.root, Node::Leaf(0));
    let stack_expanded = root.stack_expanded_pane();
    let Some(mut root) = root.remove_leaf(pane) else {
        return false;
    };
    if let Some(panes) = screen.zellij_auto_layout.as_mut() {
        panes.retain(|candidate| *candidate != pane);
        if let Some(layout) =
            crate::layout::zellij_default_pane_layout_with_ids(panes, &mut || mux.next_id())
        {
            root = layout;
            if let Some(expanded) = stack_expanded {
                root.expand_stack_pane(expanded);
            }
        } else {
            screen.zellij_auto_layout = None;
        }
    }
    screen.root = root;
    true
}

fn unique_screen_ids(ids: impl IntoIterator<Item = ScreenId>) -> Vec<ScreenId> {
    let mut unique = Vec::new();
    for id in ids {
        if !unique.contains(&id) {
            unique.push(id);
        }
    }
    unique
}

#[derive(Clone, Copy, PartialEq, Eq)]
struct ActiveTreeSelection {
    workspace: Option<WorkspaceId>,
    screen: Option<ScreenId>,
    pane: Option<PaneId>,
    surface: Option<SurfaceId>,
}

fn active_tree_selection(state: &State) -> ActiveTreeSelection {
    let workspace = state.workspaces.get(state.active_workspace);
    let screen = workspace.and_then(|workspace| workspace.screens.get(workspace.active_screen));
    let pane = screen.and_then(|screen| state.panes.get(&screen.active_pane));
    ActiveTreeSelection {
        workspace: workspace.map(|workspace| workspace.id),
        screen: screen.map(|screen| screen.id),
        pane: screen.map(|screen| screen.active_pane),
        surface: pane.and_then(|pane| pane.tabs.get(pane.active_tab)).copied(),
    }
}

fn surface_screen_id(state: &State, surface: SurfaceId) -> Option<ScreenId> {
    let pane = state.pane_of(surface)?;
    let (wi, si) = state.screen_of(pane)?;
    Some(state.workspaces[wi].screens[si].id)
}

fn resolve_workspace_index(
    state: &State,
    id: Option<WorkspaceId>,
    key: Option<&str>,
) -> anyhow::Result<usize> {
    if id.is_none() && key.is_none() {
        anyhow::bail!("workspace or key is required");
    }
    let by_id = id.and_then(|id| state.workspaces.iter().position(|workspace| workspace.id == id));
    let by_key =
        key.and_then(|key| state.workspaces.iter().position(|workspace| workspace.key == key));
    match (id, key, by_id, by_key) {
        (Some(id), _, None, _) => anyhow::bail!("unknown workspace {id}"),
        (_, Some(key), _, None) => anyhow::bail!("unknown workspace key {key}"),
        (Some(_), Some(_), Some(left), Some(right)) if left != right => {
            anyhow::bail!("workspace and key identify different workspaces")
        }
        (_, _, Some(index), _) | (_, _, _, Some(index)) => Ok(index),
        _ => anyhow::bail!("unknown workspace"),
    }
}

fn workspace_mutation_result(commit: &RegistryCommit) -> anyhow::Result<WorkspaceMutationResult> {
    let workspace = commit.result["workspace"].as_u64();
    let key = commit.result["key"]
        .as_str()
        .ok_or_else(|| anyhow::anyhow!("stored workspace mutation result is missing key"))?
        .to_string();
    let index = commit.result["index"]
        .as_u64()
        .map(usize::try_from)
        .transpose()
        .context("stored workspace mutation index is invalid")?;
    let changed = commit.result["changed"].as_bool().unwrap_or(true);
    Ok(WorkspaceMutationResult {
        workspace,
        key,
        index,
        revision: commit.revision,
        replayed: commit.replayed,
        changed,
    })
}

fn close_surface_delta(
    state: &State,
    notifications: &HashMap<SurfaceId, SurfaceNotification>,
    surface: SurfaceId,
) -> Option<TreeDelta> {
    let pane_id = state.pane_of(surface)?;
    let pane = state.panes.get(&pane_id)?;
    let tab_index = pane.tabs.iter().position(|candidate| *candidate == surface)?;
    let (wi, si) = state.screen_of(pane_id)?;
    let workspace = &state.workspaces[wi];
    let screen = &workspace.screens[si];
    if pane.tabs.len() > 1 {
        let entity = crate::server::tree_entity_json(
            state,
            notifications,
            TreeDeltaKind::TabClosed,
            surface,
        )?;
        return Some(TreeDelta {
            kind: TreeDeltaKind::TabClosed,
            workspace: workspace.id,
            screen: Some(screen.id),
            pane: Some(pane_id),
            surface: Some(surface),
            index: Some(tab_index),
            entity,
            workspace_revision: None,
        });
    }
    close_pane_delta(state, notifications, pane_id)
}

fn close_pane_delta(
    state: &State,
    notifications: &HashMap<SurfaceId, SurfaceNotification>,
    pane: PaneId,
) -> Option<TreeDelta> {
    let (wi, si) = state.screen_of(pane)?;
    let workspace = &state.workspaces[wi];
    let screen = &workspace.screens[si];
    let mut panes = Vec::new();
    screen.root.pane_ids(&mut panes);
    if panes.len() > 1 {
        let entity =
            crate::server::tree_entity_json(state, notifications, TreeDeltaKind::PaneClosed, pane)?;
        return Some(TreeDelta {
            kind: TreeDeltaKind::PaneClosed,
            workspace: workspace.id,
            screen: Some(screen.id),
            pane: Some(pane),
            surface: None,
            index: Some(panes.iter().position(|candidate| *candidate == pane)?),
            entity,
            workspace_revision: None,
        });
    }
    close_screen_delta(state, notifications, screen.id)
}

fn close_screen_delta(
    state: &State,
    notifications: &HashMap<SurfaceId, SurfaceNotification>,
    screen: ScreenId,
) -> Option<TreeDelta> {
    let (wi, si) = state.workspaces.iter().enumerate().find_map(|(wi, workspace)| {
        workspace.screens.iter().position(|candidate| candidate.id == screen).map(|si| (wi, si))
    })?;
    let workspace = &state.workspaces[wi];
    let entity =
        crate::server::tree_entity_json(state, notifications, TreeDeltaKind::ScreenClosed, screen)?;
    Some(TreeDelta {
        kind: TreeDeltaKind::ScreenClosed,
        workspace: workspace.id,
        screen: Some(screen),
        pane: None,
        surface: None,
        index: Some(si),
        entity,
        workspace_revision: None,
    })
}

fn close_workspace_delta(
    state: &State,
    notifications: &HashMap<SurfaceId, SurfaceNotification>,
    workspace: WorkspaceId,
) -> Option<TreeDelta> {
    let index = state.workspace_index(workspace)?;
    let entity = crate::server::tree_entity_json(
        state,
        notifications,
        TreeDeltaKind::WorkspaceClosed,
        workspace,
    )?;
    Some(TreeDelta {
        kind: TreeDeltaKind::WorkspaceClosed,
        workspace,
        screen: None,
        pane: None,
        surface: None,
        index: Some(index),
        entity,
        workspace_revision: None,
    })
}

fn update_layout_undo_token_part(hasher: &mut Sha256, value: &[u8]) {
    hasher.update(u64::try_from(value.len()).unwrap_or(u64::MAX).to_be_bytes());
    hasher.update(value);
}

fn layout_undo_confirmation_details(
    state: &State,
    registry: &WorkspaceRegistry,
    workspace_index: usize,
    screen_index: usize,
) -> anyhow::Result<Value> {
    let screen = state
        .workspaces
        .get(workspace_index)
        .and_then(|workspace| workspace.screens.get(screen_index))
        .context("layout undo screen disappeared")?;
    let entry = screen.layout_undo.back().ok_or(LayoutUndoError::Unavailable)?;
    if entry.after_revision != screen.layout_revision {
        return Err(LayoutUndoError::Stale(
            "layout changed since the last undoable action".to_string(),
        )
        .into());
    }
    anyhow::ensure!(!entry.created_panes.is_empty(), "layout undo does not require confirmation");

    let mut hasher = Sha256::new();
    update_layout_undo_token_part(&mut hasher, b"cmux.layout-undo.confirmation.v1");
    update_layout_undo_token_part(&mut hasher, registry.generation().as_bytes());
    update_layout_undo_token_part(&mut hasher, screen.public_id.to_string().as_bytes());
    update_layout_undo_token_part(&mut hasher, &screen.layout_revision.to_be_bytes());
    hasher.update(u64::try_from(entry.created_panes.len()).unwrap_or(u64::MAX).to_be_bytes());

    let mut closes_panes = Vec::with_capacity(entry.created_panes.len());
    for created in &entry.created_panes {
        let pane_id = state
            .resource_indexes
            .pane_ids
            .get(created)
            .with_context(|| format!("pane {created} has no public identity"))?;
        let pane = state
            .panes
            .get(created)
            .with_context(|| format!("created pane {created} disappeared before undo preview"))?;
        closes_panes.push(pane_id.clone());
        update_layout_undo_token_part(&mut hasher, pane_id.to_string().as_bytes());
        hasher.update(u64::try_from(pane.tabs.len()).unwrap_or(u64::MAX).to_be_bytes());
        for surface in &pane.tabs {
            let tab_id = state
                .resource_indexes
                .tab_ids
                .get(surface)
                .cloned()
                .or_else(|| {
                    state
                        .surfaces
                        .get(surface)
                        .and_then(|surface| surface.resource_identity())
                        .map(|identity| identity.tab_id.clone())
                })
                .with_context(|| format!("tab {surface} has no public identity"))?;
            update_layout_undo_token_part(&mut hasher, tab_id.to_string().as_bytes());
        }
    }
    let confirmation_token =
        hasher.finalize().iter().map(|byte| format!("{byte:02x}")).collect::<String>();
    let revision = registry.resource_topology_snapshot()?.revision;
    Ok(serde_json::json!({
        "revision":revision.to_string(),
        "confirmation_token":confirmation_token,
        "closes_panes":closes_panes,
    }))
}

/// Advance the confirmation fence when a tab membership mutation touches a
/// pane that the latest undo would close. This runs in the same state-lock
/// critical section as the tab mutation, so a confirmed undo observes either
/// the old membership and revision or the new membership and revision.
fn fence_layout_undo_for_tab_membership(state: &mut State, panes: &[PaneId]) {
    let screens = panes
        .iter()
        .filter_map(|pane| state.screen_of(*pane))
        .map(|(workspace, screen)| state.workspaces[workspace].screens[screen].id)
        .collect::<HashSet<_>>();
    for screen_id in screens {
        let Some(screen) = state
            .workspaces
            .iter_mut()
            .flat_map(|workspace| workspace.screens.iter_mut())
            .find(|screen| screen.id == screen_id)
        else {
            continue;
        };
        let affects_created_pane = screen.layout_undo.back().is_some_and(|entry| {
            entry.after_revision == screen.layout_revision
                && entry.created_panes.iter().any(|created| panes.contains(created))
        });
        if !affects_created_pane {
            continue;
        }
        let revision = screen.layout_revision.saturating_add(1);
        screen.layout_revision = revision;
        let entry = screen.layout_undo.back_mut().expect("validated undo entry remains present");
        entry.after_revision = revision;
        entry.coalesce = None;
    }
}

/// Remove one surface from the state: detach it from its
/// pane, and collapse emptied panes/screens. Empty workspaces remain as
/// canonical registry entries. Returns the removed surface and whether
/// split ownership or positional indexes changed. Runs under the state lock.
fn remove_surface(mux: &Mux, state: &mut State, target: SurfaceId) -> (Option<Arc<Surface>>, bool) {
    let previous_active = state.active_pane();
    let removed = take_surface_for_retirement(mux, state, target);
    let Some(pane_id) = state.pane_of(target) else {
        return (removed, false);
    };
    let pane = state.panes.get_mut(&pane_id).expect("pane_of returned live id");
    let idx = pane.tabs.iter().position(|id| *id == target).expect("tab in pane");
    pane.tabs.remove(idx);
    if !pane.tabs.is_empty() {
        if pane.active_tab >= idx && pane.active_tab > 0 {
            pane.active_tab -= 1;
        }
        fence_layout_undo_for_tab_membership(state, &[pane_id]);
        return (removed, false);
    }

    // Last tab gone: the pane collapses out of its screen.
    state.remove_pane(pane_id);
    let Some((wi, si)) = state.screen_of(pane_id) else {
        return (removed, false);
    };
    let (was_active, screen_remains) = {
        let screen = &mut state.workspaces[wi].screens[si];
        let was_active = screen.active_pane == pane_id;
        if screen.zoomed_pane == Some(pane_id) {
            screen.zoomed_pane = None;
        }
        let screen_remains = remove_pane_from_screen_layout(mux, screen, pane_id);
        (was_active, screen_remains)
    };
    if screen_remains {
        let next_active = if was_active {
            let mut ids = Vec::new();
            state.workspaces[wi].screens[si].root.pane_ids(&mut ids);
            most_recent_pane(state, &ids)
        } else {
            None
        };
        if let Some(next) = next_active {
            state.workspaces[wi].screens[si].active_pane = next;
        }
        stamp_changed_active_pane(mux, state, previous_active);
        return (removed, true);
    }

    // Screen emptied: drop it from the workspace.
    let ws = &mut state.workspaces[wi];
    ws.screens.remove(si);
    ws.active_screen = ws.active_screen.min(ws.screens.len().saturating_sub(1));
    if !ws.screens.is_empty() {
        stamp_changed_active_pane(mux, state, previous_active);
        return (removed, true);
    }

    // The screen emptied, but the workspace remains as a canonical registry
    // entry. Record the resulting loss of active pane without discarding its
    // stable workspace identity.
    stamp_changed_active_pane(mux, state, previous_active);
    (removed, true)
}

/// Transfer a topology-owned runtime into the shutdown ledger before the
/// state lock is released, so shutdown always sees one authoritative owner.
fn take_surface_for_retirement(
    mux: &Mux,
    state: &mut State,
    target: SurfaceId,
) -> Option<Arc<Surface>> {
    let removed = state.surfaces.remove(&target);
    if let Some(surface) = &removed {
        let _ = mux.shutdown_owners.stage_surface(surface);
    }
    removed
}

fn collapse_empty_pane(mux: &Mux, state: &mut State, pane_id: PaneId) {
    state.remove_pane(pane_id);
    let Some((wi, si)) = state.screen_of(pane_id) else {
        return;
    };
    let (was_active, screen_remains) = {
        let screen = &mut state.workspaces[wi].screens[si];
        let was_active = screen.active_pane == pane_id;
        if screen.zoomed_pane == Some(pane_id) {
            screen.zoomed_pane = None;
        }
        let screen_remains = remove_pane_from_screen_layout(mux, screen, pane_id);
        (was_active, screen_remains)
    };
    if screen_remains {
        let next_active = if was_active {
            let mut ids = Vec::new();
            state.workspaces[wi].screens[si].root.pane_ids(&mut ids);
            most_recent_pane(state, &ids)
        } else {
            None
        };
        if let Some(next) = next_active {
            state.workspaces[wi].screens[si].active_pane = next;
        }
    } else {
        let ws = &mut state.workspaces[wi];
        ws.screens.remove(si);
        ws.active_screen = ws.active_screen.min(ws.screens.len().saturating_sub(1));
    }
}

fn move_tab_in_state(
    mux: &Mux,
    state: &mut State,
    surface: SurfaceId,
    target_pane: PaneId,
    index: usize,
) -> (bool, bool) {
    if !state.surfaces.contains_key(&surface) || !state.panes.contains_key(&target_pane) {
        return (false, false);
    }
    let Some(source_pane) = state.pane_of(surface) else { return (false, false) };
    if source_pane == target_pane {
        let Some(pane) = state.panes.get_mut(&target_pane) else {
            return (false, false);
        };
        let Some(old_idx) = pane.tabs.iter().position(|id| *id == surface) else {
            return (false, false);
        };
        let new_idx = if index > old_idx { index.saturating_sub(1) } else { index };
        let new_idx = new_idx.min(pane.tabs.len().saturating_sub(1));
        if new_idx == old_idx {
            return (false, false);
        }
        let tab = pane.tabs.remove(old_idx);
        pane.tabs.insert(new_idx, tab);
        pane.active_tab = new_idx;
        fence_layout_undo_for_tab_membership(state, &[target_pane]);
        return (true, false);
    }

    fence_layout_undo_for_tab_membership(state, &[source_pane, target_pane]);
    {
        let Some(source) = state.panes.get_mut(&source_pane) else {
            return (false, false);
        };
        let Some(old_idx) = source.tabs.iter().position(|id| *id == surface) else {
            return (false, false);
        };
        source.tabs.remove(old_idx);
        if !source.tabs.is_empty() && source.active_tab >= old_idx && source.active_tab > 0 {
            source.active_tab -= 1;
        }
    }

    let topology_changed = state.panes.get(&source_pane).is_some_and(|pane| pane.tabs.is_empty());
    if topology_changed {
        collapse_empty_pane(mux, state, source_pane);
    }

    let Some(target) = state.panes.get_mut(&target_pane) else {
        return (false, topology_changed);
    };
    let new_idx = index.min(target.tabs.len());
    target.tabs.insert(new_idx, surface);
    target.active_tab = new_idx;
    let destination_path = if let Some((wi, si)) = state.screen_of(target_pane) {
        state.active_workspace = wi;
        let ws = &mut state.workspaces[wi];
        ws.active_screen = si;
        let screen = &mut ws.screens[si];
        screen.active_pane = target_pane;
        Some((ws.id, screen.id))
    } else {
        None
    };
    if let Some((workspace, screen)) = destination_path {
        mux.subscribers.update_surface_session_path(surface, workspace, screen, target_pane);
    }
    (true, topology_changed)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    use crate::layout::{DEFAULT_VIEWPORT_PANE_WIDTH, VirtualRect};
    use crate::resource::{BrowserPublicId, MachinePublicId, SessionPublicId, TabPublicId};
    use crate::workspace_registry::{
        RegistryPane, RegistryScreen, RegistryViewportColumn, ResourceChange, ResourcePatch,
    };

    fn test_mux() -> Arc<Mux> {
        Mux::new_for_test("test", SurfaceOptions::default())
    }

    fn public_request(
        mux: &Arc<Mux>,
        id: &str,
        operation: &str,
        params: Value,
        idempotency_key: Option<&str>,
    ) -> Value {
        let mut request = serde_json::json!({
            "protocol":"cmux.protocol/1",
            "type":"request",
            "id":id,
            "operation":operation,
            "params":params,
        });
        if let Some(idempotency_key) = idempotency_key {
            request["idempotency_key"] = Value::String(idempotency_key.to_string());
        }
        crate::resource_router::handle_resource_message(mux, &request.to_string()).unwrap()
    }

    fn state_topology_fingerprint(state: &State) -> String {
        let workspaces = state
            .workspaces
            .iter()
            .map(|workspace| {
                (
                    workspace.id,
                    workspace.public_id.clone(),
                    workspace.key.clone(),
                    workspace.name.clone(),
                    workspace.active_screen,
                    workspace
                        .screens
                        .iter()
                        .map(|screen| {
                            (
                                screen.id,
                                screen.public_id.clone(),
                                screen.layout_revision,
                                format!("{:?}", screen.layout_snapshot()),
                                format!("{:?}", screen.layout_undo),
                            )
                        })
                        .collect::<Vec<_>>(),
                )
            })
            .collect::<Vec<_>>();
        let mut panes = state
            .panes
            .iter()
            .map(|(id, pane)| (*id, pane.tabs.clone(), pane.active_tab))
            .collect::<Vec<_>>();
        panes.sort_by_key(|(id, _, _)| *id);
        let mut surfaces = state.surfaces.keys().copied().collect::<Vec<_>>();
        surfaces.sort_unstable();
        format!(
            "{:?}",
            (
                state.resource_revision,
                state.workspace_revision,
                state.active_workspace,
                workspaces,
                panes,
                surfaces,
            )
        )
    }

    fn restore_workspace_id(value: u128) -> WorkspacePublicId {
        WorkspacePublicId::parse(format!("ws_{value:032x}")).unwrap()
    }

    fn restore_screen_id(value: u128) -> ScreenPublicId {
        ScreenPublicId::parse(format!("screen_{value:032x}")).unwrap()
    }

    fn restore_pane_id(value: u128) -> PanePublicId {
        PanePublicId::parse(format!("pane_{value:032x}")).unwrap()
    }

    fn restore_tab_id(value: u128) -> TabPublicId {
        TabPublicId::parse(format!("tab_{value:032x}")).unwrap()
    }

    fn restore_browser_id(value: u128) -> BrowserPublicId {
        BrowserPublicId::parse(format!("browser_{value:032x}")).unwrap()
    }

    fn restore_terminal_id(value: u128) -> TerminalPublicId {
        TerminalPublicId::parse(format!("term_{value:032x}")).unwrap()
    }

    fn restore_split_id(value: u128) -> SplitPublicId {
        SplitPublicId::parse(format!("split_{value:032x}")).unwrap()
    }

    fn resource_restore_fixture() -> (RegistrySnapshot, ResourceTopologySnapshot) {
        let first_workspace = RegistryWorkspace {
            id: 10,
            public_id: restore_workspace_id(1),
            key: "first".into(),
            name: "Duplicate".into(),
            group_key: "test".into(),
        };
        let empty_workspace = RegistryWorkspace {
            id: 20,
            public_id: restore_workspace_id(2),
            key: "empty".into(),
            name: "Duplicate".into(),
            group_key: "test".into(),
        };
        let first_screen = restore_screen_id(1);
        let second_screen = restore_screen_id(2);
        let panes = (1..=5).map(restore_pane_id).collect::<Vec<_>>();
        let tabs = (1..=6).map(restore_tab_id).collect::<Vec<_>>();
        let internal_split = restore_split_id(1);
        let boundary_split = restore_split_id(2);
        let base_column = restore_split_id(3);
        let first_column_layout = RegistryLayoutNode::Split {
            split: internal_split,
            direction: "down".into(),
            ratio: 0.6,
            first: Box::new(RegistryLayoutNode::Stack {
                panes: vec![panes[0].clone(), panes[1].clone()],
                expanded: panes[1].clone(),
            }),
            second: Box::new(RegistryLayoutNode::Leaf { pane: panes[2].clone() }),
        };
        let first_layout = RegistryLayoutNode::Split {
            split: boundary_split.clone(),
            direction: "right".into(),
            ratio: 0.8 / (0.8 + 0.4),
            first: Box::new(first_column_layout.clone()),
            second: Box::new(RegistryLayoutNode::Leaf { pane: panes[3].clone() }),
        };
        let screens = vec![
            RegistryScreen {
                public_id: first_screen.clone(),
                workspace_id: first_workspace.public_id.clone(),
                position: 0,
                name: Some("Columns".into()),
                layout: first_layout,
                active_pane: panes[2].clone(),
                zoomed_pane: Some(panes[2].clone()),
                auto_layout: None,
                viewport: RegistryViewport {
                    base_width: Some(0.8),
                    columns: vec![
                        RegistryViewportColumn {
                            id: base_column,
                            width: 0.8,
                            layout: first_column_layout,
                            auto_layout: None,
                        },
                        RegistryViewportColumn {
                            id: boundary_split,
                            width: 0.4,
                            layout: RegistryLayoutNode::Leaf { pane: panes[3].clone() },
                            auto_layout: Some(vec![panes[3].clone()]),
                        },
                    ],
                },
            },
            RegistryScreen {
                public_id: second_screen.clone(),
                workspace_id: first_workspace.public_id.clone(),
                position: 1,
                name: Some("Selected".into()),
                layout: RegistryLayoutNode::Leaf { pane: panes[4].clone() },
                active_pane: panes[4].clone(),
                zoomed_pane: Some(panes[4].clone()),
                auto_layout: Some(vec![panes[4].clone()]),
                viewport: RegistryViewport::default(),
            },
        ];
        let registry_panes = vec![
            RegistryPane {
                public_id: panes[0].clone(),
                screen_id: first_screen.clone(),
                name: Some("one".into()),
                active_tab: Some(tabs[0].clone()),
                creation_ordinal: 1,
            },
            RegistryPane {
                public_id: panes[1].clone(),
                screen_id: first_screen.clone(),
                name: Some("two".into()),
                active_tab: Some(tabs[1].clone()),
                creation_ordinal: 2,
            },
            RegistryPane {
                public_id: panes[2].clone(),
                screen_id: first_screen.clone(),
                name: Some("three".into()),
                active_tab: Some(tabs[2].clone()),
                creation_ordinal: 3,
            },
            RegistryPane {
                public_id: panes[3].clone(),
                screen_id: first_screen,
                name: Some("four".into()),
                active_tab: Some(tabs[3].clone()),
                creation_ordinal: 4,
            },
            RegistryPane {
                public_id: panes[4].clone(),
                screen_id: second_screen.clone(),
                name: Some("five".into()),
                active_tab: Some(tabs[5].clone()),
                creation_ordinal: 5,
            },
        ];
        let registry_tabs = tabs
            .iter()
            .enumerate()
            .map(|(index, tab)| {
                let pane_index = index.min(4);
                RegistryTab {
                    public_id: tab.clone(),
                    pane_id: panes[pane_index].clone(),
                    position: usize::from(index == 5),
                    content_id: ContentPublicId::Browser(restore_browser_id(index as u128 + 1)),
                    name: Some(format!("tab-{index}")),
                    browser_url: Some(format!("about:blank#{index}")),
                    terminal_id: None,
                }
            })
            .collect::<Vec<_>>();
        let browsers = registry_tabs
            .iter()
            .enumerate()
            .map(|(index, tab)| {
                let ContentPublicId::Browser(public_id) = &tab.content_id else {
                    unreachable!("restart fixture uses browser tabs");
                };
                RegistryBrowser {
                    public_id: public_id.clone(),
                    url: tab.browser_url.clone().unwrap(),
                    source: if index % 2 == 0 {
                        crate::workspace_registry::RegistryBrowserSource::Launched
                    } else {
                        crate::workspace_registry::RegistryBrowserSource::External
                    },
                    launch: if index % 2 == 0 {
                        crate::workspace_registry::RegistryBrowserLaunch::Create
                    } else {
                        crate::workspace_registry::RegistryBrowserLaunch::Adopted
                    },
                    reconnect: RegistryBrowserReconnect::Recreate,
                    status: if index % 2 == 0 {
                        crate::workspace_registry::RegistryBrowserStatus::Live
                    } else {
                        crate::workspace_registry::RegistryBrowserStatus::Failed
                    },
                    cols: 90 + index as u16,
                    rows: 30 + index as u16,
                }
            })
            .collect();
        let session_id =
            SessionPublicId::parse("session_00000000000000000000000000000001").unwrap();
        (
            RegistrySnapshot {
                registry_id: "registry".into(),
                generation: "generation".into(),
                revision: 1,
                resource_revision: 1,
                session_id: session_id.clone(),
                next_numeric_id: 100,
                workspaces: vec![first_workspace.clone(), empty_workspace.clone()],
            },
            ResourceTopologySnapshot {
                session_id,
                generation: "generation".into(),
                revision: 1,
                active_workspace: Some(empty_workspace.public_id.clone()),
                active_screens: vec![
                    (first_workspace.public_id, Some(second_screen)),
                    (empty_workspace.public_id, None),
                ],
                screens,
                panes: registry_panes,
                tabs: registry_tabs,
                browsers,
            },
        )
    }

    fn selector_fixture()
    -> (RestoredResourceState, MachinePublicId, SessionPublicId, ResourceTopologySnapshot) {
        let (snapshot, topology) = resource_restore_fixture();
        let session = snapshot.session_id.clone();
        let restored = restore_resource_state(snapshot, topology.clone()).unwrap();
        (restored, MachinePublicId::random().unwrap(), session, topology)
    }

    fn routed_selectors(
        machine: &MachinePublicId,
        session: &SessionPublicId,
    ) -> crate::ResourceSelectors {
        crate::ResourceSelectors {
            machine: Some(machine.to_string()),
            session: Some(session.to_string()),
            ..crate::ResourceSelectors::default()
        }
    }

    #[test]
    fn direct_browser_id_derives_its_complete_path_without_structural_selectors() {
        let (restored, machine, session, topology) = selector_fixture();
        let browser = topology.browsers[0].public_id.clone();
        let tab = topology
            .tabs
            .iter()
            .find(|tab| tab.content_id == ContentPublicId::Browser(browser.clone()))
            .unwrap();
        let pane = topology.panes.iter().find(|pane| pane.public_id == tab.pane_id).unwrap();
        let screen =
            topology.screens.iter().find(|screen| screen.public_id == pane.screen_id).unwrap();
        let mut selectors = routed_selectors(&machine, &session);
        selectors.browser = Some(browser.to_string());

        let resolved = resolve_resource_selectors(
            &restored.state,
            ResourceSelectorContext {
                machine_id: &machine,
                machine_name: None,
                session_id: &session,
                session_name: "test",
            },
            crate::ResourceTarget::Browser,
            &selectors,
        )
        .unwrap()
        .path;
        assert_eq!(resolved.workspace, Some(screen.workspace_id.clone()));
        assert_eq!(resolved.screen, Some(screen.public_id.clone()));
        assert_eq!(resolved.pane, Some(pane.public_id.clone()));
        assert_eq!(resolved.tab, Some(tab.public_id.clone()));
        assert_eq!(resolved.browser, Some(browser));
    }

    #[test]
    fn selector_names_preserve_empty_whitespace_and_unicode_and_report_duplicates() {
        let (mut restored, machine, session, _) = selector_fixture();
        let before = restored.state.resource_revision;
        let mut selectors = routed_selectors(&machine, &session);
        selectors.workspace = Some("Duplicate".into());
        let duplicate = resolve_resource_selectors(
            &restored.state,
            ResourceSelectorContext {
                machine_id: &machine,
                machine_name: None,
                session_id: &session,
                session_name: "test",
            },
            crate::ResourceTarget::Workspace,
            &selectors,
        )
        .unwrap_err();
        assert_eq!(duplicate.code, "selector.ambiguous");
        assert_eq!(
            duplicate.details["candidates"],
            serde_json::json!([restore_workspace_id(1), restore_workspace_id(2)])
        );
        assert_eq!(restored.state.resource_revision, before);

        for (index, name) in ["", "  日本語  "].into_iter().enumerate() {
            restored.state.workspaces[index].name = name.into();
            selectors.workspace = Some(format!("name:{name}"));
            let resolved = resolve_resource_selectors(
                &restored.state,
                ResourceSelectorContext {
                    machine_id: &machine,
                    machine_name: None,
                    session_id: &session,
                    session_name: "test",
                },
                crate::ResourceTarget::Workspace,
                &selectors,
            )
            .unwrap();
            assert_eq!(
                resolved.path.workspace,
                Some(restored.state.workspaces[index].public_id.clone())
            );
        }
    }

    #[test]
    fn selector_rejects_incomplete_name_chain_wrong_type_stale_id_and_wrong_parent() {
        let (restored, machine, session, topology) = selector_fixture();
        let context = ResourceSelectorContext {
            machine_id: &machine,
            machine_name: None,
            session_id: &session,
            session_name: "test",
        };

        let mut incomplete = routed_selectors(&machine, &session);
        incomplete.screen = Some(topology.screens[0].public_id.to_string());
        incomplete.pane = Some("one".into());
        let error = resolve_resource_selectors(
            &restored.state,
            context.clone(),
            crate::ResourceTarget::Pane,
            &incomplete,
        )
        .unwrap_err();
        assert_eq!(error.code, "selector.invalid");
        assert_eq!(error.details["scope"], "pane");
        assert!(
            error.details["reason"].as_str().is_some_and(|reason| reason.contains("workspace"))
        );

        let mut wrong_type = routed_selectors(&machine, &session);
        wrong_type.workspace = Some(topology.browsers[0].public_id.to_string());
        assert_eq!(
            resolve_resource_selectors(
                &restored.state,
                context.clone(),
                crate::ResourceTarget::Workspace,
                &wrong_type,
            )
            .unwrap_err()
            .code,
            "selector.invalid"
        );

        let mut stale = routed_selectors(&machine, &session);
        stale.workspace = Some(WorkspacePublicId::random().unwrap().to_string());
        assert_eq!(
            resolve_resource_selectors(
                &restored.state,
                context.clone(),
                crate::ResourceTarget::Workspace,
                &stale,
            )
            .unwrap_err()
            .code,
            "selector.not_found"
        );

        let mut wrong_parent = routed_selectors(&machine, &session);
        wrong_parent.workspace = Some(restore_workspace_id(2).to_string());
        wrong_parent.browser = Some(topology.browsers[0].public_id.to_string());
        let error = resolve_resource_selectors(
            &restored.state,
            context,
            crate::ResourceTarget::Browser,
            &wrong_parent,
        )
        .unwrap_err();
        assert_eq!(error.code, "selector.wrong_parent");
        assert!(error.details["expected_parent"].as_str().unwrap().starts_with("ws_"));
        assert!(error.details["actual_parent"].as_str().unwrap().starts_with("ws_"));
        let encoded = serde_json::to_string(&error).unwrap();
        for private in ["workspace_key", "surface", "numeric_id", "short_id", "\"slot\""] {
            assert!(!encoded.contains(private));
        }
    }

    #[test]
    fn selector_rename_and_concurrent_rename_share_one_locked_snapshot() {
        let mux = test_mux();
        let first = mux
            .resource_create_empty_workspace(
                Some("target".into()),
                None,
                Some(0),
                &WorkspaceMutation::new("selector-race-first", "test").unwrap(),
            )
            .unwrap();
        let second = mux
            .resource_create_empty_workspace(
                Some("other".into()),
                None,
                Some(1),
                &WorkspaceMutation::new("selector-race-second", "test").unwrap(),
            )
            .unwrap();
        let first_id =
            WorkspacePublicId::parse(first.result["workspace"].as_str().unwrap()).unwrap();
        let second_id =
            WorkspacePublicId::parse(second.result["workspace"].as_str().unwrap()).unwrap();
        let (machine, session) = {
            let registry = mux.workspace_registry.lock().unwrap();
            (registry.machine_id().clone(), registry.session_id().clone())
        };
        let mut selectors = routed_selectors(&machine, &session);
        selectors.workspace = Some("target".into());

        let (resolved_tx, resolved_rx) = std::sync::mpsc::sync_channel(1);
        let overlap = Arc::new(std::sync::Barrier::new(2));
        *mux.resource_rename_after_selector_resolution.lock().unwrap() = Some(Arc::new({
            let overlap = overlap.clone();
            move |resolved| {
                resolved_tx.send(resolved.clone()).unwrap();
                overlap.wait();
            }
        }));
        let selected = {
            let mux = mux.clone();
            std::thread::spawn(move || {
                mux.resource_rename_workspace_selected(
                    selectors,
                    "renamed".into(),
                    None,
                    Some(2),
                    &WorkspaceMutation::new("selector-race-selected", "test").unwrap(),
                )
            })
        };
        assert_eq!(resolved_rx.recv().unwrap(), first_id);
        let concurrent = {
            let mux = mux.clone();
            let second_id = second_id.clone();
            std::thread::spawn(move || {
                overlap.wait();
                mux.resource_rename_workspace(
                    &second_id,
                    "target".into(),
                    None,
                    None,
                    &WorkspaceMutation::new("selector-race-direct", "test").unwrap(),
                )
            })
        };
        selected.join().unwrap().unwrap();
        concurrent.join().unwrap().unwrap();
        *mux.resource_rename_after_selector_resolution.lock().unwrap() = None;

        mux.with_state(|state| {
            let first = state.resource_indexes.workspaces[&first_id];
            let second = state.resource_indexes.workspaces[&second_id];
            assert_eq!(state.workspaces[state.workspace_index(first).unwrap()].name, "renamed");
            assert_eq!(state.workspaces[state.workspace_index(second).unwrap()].name, "target");
        });
    }

    #[test]
    fn resource_startup_restores_nested_columns_selections_and_empty_workspace() {
        let (snapshot, topology) = resource_restore_fixture();
        let expected_tab = topology.tabs[5].public_id.clone();
        let expected_browser = topology.tabs[5].content_id.clone();
        let expected_base_column = topology.screens[0].viewport.columns[0].id.clone();
        let mut restored = restore_resource_state(snapshot, topology).unwrap();
        Mux::rebuild_split_screen_index(&mut restored.state);

        let state = &restored.state;
        assert_eq!(state.workspaces.len(), 2);
        assert_eq!(state.active_workspace, 1);
        assert!(state.workspaces[1].screens.is_empty());
        assert_eq!(state.workspaces[0].active_screen, 1);
        let columns = &state.workspaces[0].screens[0];
        assert_eq!(columns.layout_columns.len(), 2);
        assert_eq!(columns.viewport_base_width, Some(0.8));
        assert_eq!(columns.zoomed_pane, Some(columns.active_pane));
        assert!(matches!(
            &columns.layout_columns[0].root,
            Node::Split { a, .. }
                if matches!(a.as_ref(), Node::Stack { expanded, .. }
                    if *expanded == state.resource_indexes.panes[&restore_pane_id(2)])
        ));
        assert!(columns.layout_column_projection_is_consistent());
        assert!(state.resource_indexes.splits.contains_key(&expected_base_column));
        let selected_pane = state.resource_indexes.panes[&restore_pane_id(5)];
        assert_eq!(
            state.panes[&selected_pane].tabs[state.panes[&selected_pane].active_tab],
            state.resource_indexes.tabs[&expected_tab]
        );
        assert_eq!(
            state.resource_indexes.content[&expected_browser],
            state.resource_indexes.tabs[&expected_tab]
        );
        assert_eq!(state.surfaces.len(), 0);
        assert_eq!(restored.contents.len(), 6);
        assert!(restored.next_id > 100);
    }

    #[test]
    fn resource_startup_rejects_corrupt_persisted_selectors() {
        let (snapshot, mut topology) = resource_restore_fixture();
        topology.active_screens[0].1 = Some(restore_screen_id(999));
        assert!(
            restore_resource_state(snapshot.clone(), topology)
                .err()
                .unwrap()
                .to_string()
                .contains("unknown active screen")
        );

        let (_, mut topology) = resource_restore_fixture();
        topology.panes[0].active_tab = Some(restore_tab_id(999));
        assert!(
            restore_resource_state(snapshot, topology)
                .err()
                .unwrap()
                .to_string()
                .contains("unknown active tab")
        );
    }

    #[test]
    fn resource_startup_requires_exact_browser_restart_metadata_coverage() {
        let (snapshot, mut topology) = resource_restore_fixture();
        topology.browsers.pop();
        assert!(
            restore_resource_state(snapshot.clone(), topology)
                .err()
                .unwrap()
                .to_string()
                .contains("has no restart metadata")
        );

        let (_, mut topology) = resource_restore_fixture();
        let mut orphan = topology.browsers[0].clone();
        orphan.public_id = restore_browser_id(999);
        topology.browsers.push(orphan);
        assert!(
            restore_resource_state(snapshot.clone(), topology)
                .err()
                .unwrap()
                .to_string()
                .contains("orphan browser metadata")
        );

        let (_, mut topology) = resource_restore_fixture();
        topology.browsers.push(topology.browsers[0].clone());
        assert!(
            restore_resource_state(snapshot, topology)
                .err()
                .unwrap()
                .to_string()
                .contains("duplicate browser metadata")
        );
    }

    #[test]
    fn resource_startup_rejects_missing_required_active_selectors() {
        let (snapshot, mut topology) = resource_restore_fixture();
        topology.panes[0].active_tab = None;
        assert_eq!(
            restore_resource_state(snapshot.clone(), topology).err().unwrap().to_string(),
            format!("pane {} has tabs but no active tab", restore_pane_id(1))
        );

        let (_, mut topology) = resource_restore_fixture();
        topology.active_screens[0].1 = None;
        assert_eq!(
            restore_resource_state(snapshot.clone(), topology).err().unwrap().to_string(),
            format!("workspace {} has screens but no active screen", restore_workspace_id(1))
        );

        let (_, mut topology) = resource_restore_fixture();
        topology.active_workspace = None;
        assert_eq!(
            restore_resource_state(snapshot.clone(), topology).err().unwrap().to_string(),
            "session has workspaces but no active workspace"
        );

        let (_, mut topology) = resource_restore_fixture();
        topology.active_screens.pop();
        assert_eq!(
            restore_resource_state(snapshot, topology).err().unwrap().to_string(),
            "active-screen metadata does not exactly cover the live workspaces"
        );
    }

    #[test]
    fn resource_startup_accepts_none_only_for_empty_containers() {
        let (snapshot, mut topology) = resource_restore_fixture();
        let empty_pane = topology.panes[0].public_id.clone();
        topology.tabs.retain(|tab| tab.pane_id != empty_pane);
        let retained_browsers = topology
            .tabs
            .iter()
            .filter_map(|tab| match &tab.content_id {
                ContentPublicId::Browser(browser) => Some(browser.clone()),
                ContentPublicId::Terminal(_) => None,
            })
            .collect::<HashSet<_>>();
        topology.browsers.retain(|browser| retained_browsers.contains(&browser.public_id));
        topology.panes[0].active_tab = None;
        let restored = restore_resource_state(snapshot, topology).unwrap();
        assert!(
            restored.state.panes[&restored.state.resource_indexes.panes[&empty_pane]]
                .tabs
                .is_empty()
        );

        let (mut snapshot, mut topology) = resource_restore_fixture();
        snapshot.workspaces.clear();
        topology.active_workspace = None;
        topology.active_screens.clear();
        topology.screens.clear();
        topology.panes.clear();
        topology.tabs.clear();
        topology.browsers.clear();
        assert!(restore_resource_state(snapshot, topology).unwrap().state.workspaces.is_empty());
    }

    #[test]
    fn resource_state_patch_commits_before_infallible_projection_and_replays_once() {
        let mux = test_mux();
        let mutation = WorkspaceMutation::new("create-once", "test-client").unwrap();
        let first = mux
            .resource_create_empty_workspace(Some("API".into()), None, Some(0), &mutation)
            .unwrap();
        assert_eq!(first.revision, 1);
        assert!(!first.replayed);
        let public_id =
            WorkspacePublicId::parse(first.result["workspace"].as_str().unwrap()).unwrap();
        mux.with_state(|state| {
            assert_eq!(state.resource_revision, 1);
            assert_eq!(state.workspaces.len(), 1);
            assert_eq!(state.workspaces[0].public_id, public_id);
            assert_eq!(state.workspaces[0].name, "API");
        });
        let durable = mux.workspace_registry.lock().unwrap().resource_topology_snapshot().unwrap();
        assert_eq!(durable.revision, 1);
        assert_eq!(durable.active_workspace, Some(public_id));

        let replay = mux
            .resource_create_empty_workspace(Some("API".into()), None, Some(0), &mutation)
            .unwrap();
        assert!(replay.replayed);
        assert_eq!(replay.revision, 1);
        assert_eq!(replay.result, first.result);
        mux.with_state(|state| {
            assert_eq!(state.resource_revision, 1);
            assert_eq!(state.workspaces.len(), 1);
        });
    }

    #[test]
    fn resource_state_patch_failure_leaves_memory_and_database_unchanged() {
        let mux = test_mux();
        mux.workspace_registry.lock().unwrap().set_resource_patch_failure(true).unwrap();
        let error = mux
            .resource_create_empty_workspace(
                Some("Never visible".into()),
                None,
                Some(0),
                &WorkspaceMutation::new("fail-create", "test-client").unwrap(),
            )
            .unwrap_err();
        assert!(error.to_string().contains("forced resource patch failure"));
        mux.with_state(|state| {
            assert!(state.workspaces.is_empty());
            assert_eq!(state.resource_revision, 0);
        });
        let registry = mux.workspace_registry.lock().unwrap();
        assert_eq!(registry.resource_topology_snapshot().unwrap().revision, 0);
        assert!(registry.snapshot().unwrap().workspaces.is_empty());
        registry.set_resource_patch_failure(false).unwrap();
    }

    fn begin_test_resource_effect(mux: &Mux, idempotency_key: &str, operation: &str) -> Value {
        let fingerprint = serde_json::json!({
            "operation": operation,
            "fixture": idempotency_key,
        });
        let expected_revision = mux.with_state(|state| state.resource_revision);
        assert!(matches!(
            mux.prepare_resource_effect(
                idempotency_key,
                operation,
                &fingerprint,
                &serde_json::json!({}),
                None,
                Some(expected_revision),
            )
            .unwrap(),
            ResourceEffectPreparation::Execute { resumed: false, .. }
        ));
        mux.mark_resource_effect_executing(idempotency_key, operation, &fingerprint).unwrap();
        fingerprint
    }

    #[test]
    fn projected_effect_failure_rolls_back_revision_event_and_topology() {
        let mux = test_mux();
        let surface =
            mux.new_browser_tab("about:blank#rollback".into(), None, Some((80, 24))).unwrap();
        let before_revision = mux.with_state(|state| state.resource_revision);
        let fingerprint =
            begin_test_resource_effect(&mux, "effect-projection-rollback", "test.project");
        let before_epoch = mux.resource_event_epoch();
        mux.workspace_registry.lock().unwrap().set_resource_patch_failure(true).unwrap();

        let error = mux
            .commit_full_resource_effect_projection(
                "effect-projection-rollback",
                "test.project",
                &fingerprint,
                serde_json::json!({"projected":true}),
            )
            .unwrap_err();

        assert!(error.to_string().contains("forced resource patch failure"));
        assert_eq!(mux.resource_event_epoch(), before_epoch);
        mux.with_state(|state| assert_eq!(state.resource_revision, before_revision));
        let registry = mux.workspace_registry.lock().unwrap();
        assert_eq!(registry.resource_topology_snapshot().unwrap().revision, before_revision);
        assert!(registry.resource_events_after(before_revision).unwrap().batches.is_empty());
        registry.set_resource_patch_failure(false).unwrap();
        surface.kill();
    }

    #[test]
    fn projected_effect_preserves_restored_terminal_before_surface_adoption() {
        let mux = test_mux();
        let surface = mux.new_workspace(Some("Restored".into()), Some((80, 24))).unwrap();
        let identity = surface.resource_identity().unwrap().clone();
        let ContentPublicId::Terminal(terminal_id) = identity.content_id.clone() else {
            panic!("workspace fixture must create a terminal");
        };
        let host = mux.resource_terminal_host_identity(&surface).unwrap();
        let removed = mux.state.lock().unwrap().surfaces.remove(&surface.id);
        assert!(removed.is_some(), "surface must exist before simulating delayed adoption");

        let projection = mux
            .resource_effect_projection()
            .expect("a restored terminal may be projected before its surface is adopted");

        assert!(projection.patch.changes.iter().any(|change| matches!(
            change,
            ResourceChange::UpsertTab(tab)
                if tab.public_id == identity.tab_id
                    && tab.content_id == ContentPublicId::Terminal(terminal_id.clone())
        )));
        assert!(projection.patch.changes.iter().any(|change| matches!(
            change,
            ResourceChange::UpsertTerminal { public_id, terminal }
                if public_id == &terminal_id && terminal.terminal_id == host.terminal_id
        )));
        assert!(!projection.patch.changes.iter().any(|change| matches!(
            change,
            ResourceChange::TombstoneTab { tab_id } if tab_id == &identity.tab_id
        )));
        assert!(!projection.patch.changes.iter().any(|change| matches!(
            change,
            ResourceChange::TombstoneTerminal { public_id, .. } if public_id == &terminal_id
        )));
        surface.kill();
    }

    #[test]
    fn projected_effect_holds_writer_fence_through_commit_and_publishes_once() {
        use std::sync::mpsc;

        let mux = test_mux();
        let surface = mux.new_browser_tab("about:blank#race".into(), None, Some((80, 24))).unwrap();
        let original_name = mux.with_state(|state| state.workspaces[0].name.clone());
        let before_revision = mux.with_state(|state| state.resource_revision);
        let before_epoch = mux.resource_event_epoch();
        let fingerprint =
            begin_test_resource_effect(&mux, "effect-projection-race", "test.project");
        let projection_ready = Arc::new(std::sync::Barrier::new(2));
        let allow_commit = Arc::new(std::sync::Barrier::new(2));
        *mux.resource_projection_before_commit.lock().unwrap() = Some(Arc::new({
            let projection_ready = projection_ready.clone();
            let allow_commit = allow_commit.clone();
            move || {
                projection_ready.wait();
                allow_commit.wait();
            }
        }));

        let commit_thread = {
            let mux = mux.clone();
            std::thread::spawn(move || {
                mux.commit_full_resource_effect_projection(
                    "effect-projection-race",
                    "test.project",
                    &fingerprint,
                    serde_json::json!({"projected":true}),
                )
                .unwrap()
            })
        };
        projection_ready.wait();

        let (acquired_tx, acquired_rx) = mpsc::channel();
        let racing_writer = {
            let mux = mux.clone();
            std::thread::spawn(move || {
                let mut state = mux.state.lock().unwrap();
                state.workspaces[0].name = "Raced after capture".into();
                acquired_tx.send(()).unwrap();
            })
        };
        assert!(
            acquired_rx.recv_timeout(Duration::from_millis(50)).is_err(),
            "a topology writer entered between projection capture and durable commit"
        );
        allow_commit.wait();
        let commit = commit_thread.join().unwrap();
        acquired_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        racing_writer.join().unwrap();
        *mux.resource_projection_before_commit.lock().unwrap() = None;

        assert_eq!(commit.revision, before_revision + 1);
        assert_eq!(mux.resource_event_epoch(), before_epoch + 1);
        let registry = mux.workspace_registry.lock().unwrap();
        let snapshot = registry.snapshot().unwrap();
        assert_eq!(snapshot.resource_revision, before_revision + 1);
        assert_eq!(snapshot.workspaces[0].name, original_name);
        let events = registry.resource_events_after(before_revision).unwrap();
        assert_eq!(events.batches.len(), 1);
        let changes = events.batches[0].changes.as_array().unwrap();
        assert!(!changes.is_empty());
        for (sequence, change) in changes.iter().enumerate() {
            assert_eq!(change["sequence"], sequence);
            assert!(matches!(change["kind"].as_str(), Some("upsert" | "delete")));
            assert!(change["resource"].is_string());
            assert!(change["id"].is_string());
            assert!(change.get("event").is_none());
        }
        surface.kill();
    }

    #[test]
    fn ordinary_workspace_mutations_publish_one_immediate_public_revision() {
        fn assert_public_state(
            mux: &Mux,
            revision: u64,
            expected: &[(&str, bool)],
        ) -> Vec<WorkspacePublicId> {
            assert_eq!(mux.resource_event_epoch(), revision);
            mux.with_state(|state| assert_eq!(state.resource_revision, revision));

            let snapshot = crate::resource_api::public_session_snapshot(mux).unwrap();
            assert_eq!(snapshot["session"]["revision"], revision.to_string());
            let workspaces = snapshot["workspaces"].as_array().unwrap();
            assert_eq!(workspaces.len(), expected.len());
            for (index, (workspace, (name, focused))) in
                workspaces.iter().zip(expected.iter()).enumerate()
            {
                assert_eq!(workspace["name"], *name);
                assert_eq!(workspace["index"], u64::try_from(index).unwrap());
                assert_eq!(workspace["focused"], *focused);
            }

            let registry = mux.workspace_registry.lock().unwrap();
            assert_eq!(registry.snapshot().unwrap().resource_revision, revision);
            let events = registry.resource_events_after(0).unwrap();
            assert_eq!(events.batches.len(), usize::try_from(revision).unwrap());
            let batch = events.batches.last().unwrap();
            assert_eq!(batch.previous_revision, revision - 1);
            assert_eq!(batch.revision, revision);
            for (sequence, change) in batch.changes.as_array().unwrap().iter().enumerate() {
                assert_eq!(change["sequence"], sequence);
                assert!(matches!(change["kind"].as_str(), Some("upsert" | "delete")));
                assert!(change["resource"].is_string());
                assert!(change["id"].is_string());
                assert!(change.get("event").is_none());
            }
            workspaces
                .iter()
                .map(|workspace| {
                    WorkspacePublicId::parse(workspace["id"].as_str().unwrap()).unwrap()
                })
                .collect()
        }

        let mux = test_mux();
        let first = mux.create_empty_workspace(Some("One".into()), None, Some(0)).unwrap();
        assert_public_state(&mux, 1, &[("One", true)]);

        let second = mux.create_empty_workspace(Some("Two".into()), None, Some(1)).unwrap();
        let ids = assert_public_state(&mux, 2, &[("One", false), ("Two", true)]);

        assert_eq!(
            mux.rename_workspace_at_revision(first.workspace, "Renamed".into(), Some(2)).unwrap(),
            Some(3)
        );
        assert_public_state(&mux, 3, &[("Renamed", false), ("Two", true)]);

        assert_eq!(
            mux.move_workspace_at_revision(first.workspace, 2, Some(3)).unwrap(),
            Some((4, true))
        );
        let moved_ids = assert_public_state(&mux, 4, &[("Two", true), ("Renamed", false)]);
        assert_eq!(moved_ids, vec![ids[1].clone(), ids[0].clone()]);

        assert_eq!(mux.close_workspace_at_revision(first.workspace, Some(4)).unwrap(), Some(5));
        let remaining = assert_public_state(&mux, 5, &[("Two", true)]);
        assert_eq!(remaining, vec![ids[1].clone()]);
        assert_eq!(second.workspace, mux.with_state(|state| state.workspaces[0].id));
    }

    fn assert_ordinary_public_revision(mux: &Mux, revision: u64) -> Value {
        assert_eq!(mux.resource_event_epoch(), revision);
        mux.with_state(|state| assert_eq!(state.resource_revision, revision));
        let snapshot = crate::resource_api::public_session_snapshot(mux).unwrap();
        assert_eq!(snapshot["session"]["revision"], revision.to_string());

        let registry = mux.workspace_registry.lock().unwrap();
        assert_eq!(registry.resource_topology_snapshot().unwrap().revision, revision);
        let events = registry.resource_events_after(0).unwrap();
        assert_eq!(events.batches.len(), usize::try_from(revision).unwrap());
        let batch = events.batches.last().unwrap();
        assert_eq!(batch.previous_revision, revision - 1);
        assert_eq!(batch.revision, revision);
        let changes = batch.changes.as_array().unwrap();
        assert!(!changes.is_empty());
        for (sequence, change) in changes.iter().enumerate() {
            assert_eq!(change["sequence"], sequence);
            assert!(matches!(change["kind"].as_str(), Some("upsert" | "delete")));
            assert!(change["resource"].is_string());
            assert!(change["id"].is_string());
            assert!(change.get("event").is_none());
        }
        snapshot
    }

    #[test]
    fn ordinary_topology_creates_renames_and_focus_publish_one_revision_each() {
        let mux = test_mux();
        let first = mux.new_workspace(Some("One".into()), None).unwrap();
        assert_ordinary_public_revision(&mux, 1);
        let (first_workspace, first_screen, first_pane) = mux.with_state(|state| {
            let pane = state.pane_of(first.id).unwrap();
            let (workspace, screen) = state.screen_of(pane).unwrap();
            (state.workspaces[workspace].id, state.workspaces[workspace].screens[screen].id, pane)
        });

        let second_tab = mux.new_tab(Some(first_pane), None, None).unwrap();
        assert_ordinary_public_revision(&mux, 2);
        let browser = mux
            .new_browser_tab("about:blank#ordinary-public".into(), Some(first_pane), None)
            .unwrap();
        assert_ordinary_public_revision(&mux, 3);

        let second_screen_surface = mux.new_screen(Some(first_workspace), None).unwrap();
        assert_ordinary_public_revision(&mux, 4);
        let second_pane = mux.with_state(|state| state.pane_of(second_screen_surface.id).unwrap());
        let split_surface = mux.split(second_pane, SplitDir::Right, None).unwrap();
        assert_ordinary_public_revision(&mux, 5);
        let split_pane = mux.with_state(|state| state.pane_of(split_surface.id).unwrap());
        let distributed_surface = mux.new_pane(split_pane, None).unwrap();
        assert_ordinary_public_revision(&mux, 6);
        let distributed_pane =
            mux.with_state(|state| state.pane_of(distributed_surface.id).unwrap());

        assert!(mux.rename_pane(distributed_pane, "Worker".into()));
        assert_ordinary_public_revision(&mux, 7);
        assert!(mux.rename_surface(browser.id, "Docs".into()));
        assert_ordinary_public_revision(&mux, 8);
        let second_screen = mux.with_state(|state| {
            let (workspace, screen) = state.screen_of(second_pane).unwrap();
            state.workspaces[workspace].screens[screen].id
        });
        assert!(mux.rename_screen(second_screen, "Build".into()));
        let snapshot = assert_ordinary_public_revision(&mux, 9);
        let pane_public =
            mux.with_state(|state| state.resource_indexes.pane_ids[&distributed_pane].to_string());
        let tab_public =
            mux.with_state(|state| state.resource_indexes.tab_ids[&browser.id].to_string());
        let screen_public =
            mux.with_state(|state| state.resource_indexes.screen_ids[&second_screen].to_string());
        assert_eq!(
            snapshot["panes"]
                .as_array()
                .unwrap()
                .iter()
                .find(|pane| pane["id"] == pane_public)
                .unwrap()["name"],
            "Worker"
        );
        assert_eq!(
            snapshot["tabs"]
                .as_array()
                .unwrap()
                .iter()
                .find(|tab| tab["id"] == tab_public)
                .unwrap()["name"],
            "Docs"
        );
        assert_eq!(
            snapshot["screens"]
                .as_array()
                .unwrap()
                .iter()
                .find(|screen| screen["id"] == screen_public)
                .unwrap()["name"],
            "Build"
        );

        assert!(mux.focus_pane(second_pane));
        assert_ordinary_public_revision(&mux, 10);
        mux.select_tab(Some(first_pane), Some(0), None);
        assert_ordinary_public_revision(&mux, 11);
        mux.with_state(|state| assert_eq!(state.active_pane(), Some(second_pane)));
        mux.select_screen(Some(0), None);
        assert_ordinary_public_revision(&mux, 12);
        mux.with_state(|state| {
            assert_eq!(
                state.workspaces[0].screens[state.workspaces[0].active_screen].id,
                first_screen
            );
        });

        mux.new_workspace(Some("Two".into()), None).unwrap();
        assert_ordinary_public_revision(&mux, 13);
        mux.select_workspace(Some(0), None);
        let snapshot = assert_ordinary_public_revision(&mux, 14);
        assert_eq!(
            snapshot["workspaces"]
                .as_array()
                .unwrap()
                .iter()
                .find(|workspace| workspace["name"] == "One")
                .unwrap()["focused"],
            true
        );

        assert_eq!(second_tab.id, mux.with_state(|state| state.panes[&first_pane].tabs[1]));
    }

    #[test]
    fn durable_workspace_creation_supports_the_in_process_terminal_runtime() {
        let mux = Mux::new(
            format!("in-process-resource-{}", WorkspacePublicId::random().unwrap()),
            SurfaceOptions::default(),
        );

        let surface = mux.new_workspace(Some("headless".into()), Some((80, 24))).unwrap();
        let identity = mux
            .resource_terminal_host_identity(&surface)
            .expect("reserved in-process terminal has a durable lifecycle identity");
        assert!(
            mux.reserved_in_process_terminals.lock().unwrap().contains_key(&surface.id),
            "in-process reservation must remain available to close and exit paths"
        );
        let snapshot = mux.workspace_registry.lock().unwrap().resource_topology_snapshot().unwrap();
        assert_eq!(snapshot.revision, 1);
        assert_eq!(snapshot.active_screens.len(), 1);
        assert_eq!(snapshot.tabs.len(), 1);
        assert_eq!(snapshot.tabs[0].terminal_id.as_deref(), Some(identity.terminal_id.as_str()));

        let workspace = mux.with_state(|state| state.workspaces[0].id);
        assert!(mux.close_workspace(workspace));
        let _ = mux.shutdown();
    }

    #[test]
    fn ordinary_topology_projection_failure_keeps_memory_and_public_state_unchanged() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, None).unwrap();
        let pane = mux.with_state(|state| state.pane_of(surface.id).unwrap());
        mux.workspace_registry.lock().unwrap().set_resource_patch_failure(true).unwrap();

        assert!(!mux.rename_pane(pane, "Never visible".into()));

        assert_eq!(mux.resource_event_epoch(), 1);
        mux.with_state(|state| {
            assert_eq!(state.resource_revision, 1);
            assert_eq!(state.panes[&pane].name, None);
        });
        let registry = mux.workspace_registry.lock().unwrap();
        assert_eq!(registry.resource_topology_snapshot().unwrap().revision, 1);
        assert_eq!(registry.resource_events_after(0).unwrap().batches.len(), 1);
        registry.set_resource_patch_failure(false).unwrap();
    }

    #[test]
    fn ordinary_workspace_projection_failure_rolls_back_both_registries_and_memory() {
        let mux = test_mux();
        mux.workspace_registry.lock().unwrap().set_resource_patch_failure(true).unwrap();

        let error =
            mux.create_empty_workspace(Some("Never visible".into()), None, Some(0)).unwrap_err();
        assert!(error.to_string().contains("forced resource patch failure"));
        assert_eq!(mux.resource_event_epoch(), 0);
        mux.with_state(|state| {
            assert!(state.workspaces.is_empty());
            assert_eq!(state.workspace_revision, 0);
            assert_eq!(state.resource_revision, 0);
        });
        let registry = mux.workspace_registry.lock().unwrap();
        let snapshot = registry.snapshot().unwrap();
        assert_eq!(snapshot.revision, 0);
        assert_eq!(snapshot.resource_revision, 0);
        assert!(snapshot.workspaces.is_empty());
        assert!(registry.resource_events_after(0).unwrap().batches.is_empty());
        registry.set_resource_patch_failure(false).unwrap();
    }

    #[test]
    fn resource_idempotency_is_session_global_and_rejects_changed_input() {
        let mux = test_mux();
        let first = WorkspaceMutation::new("global-key", "client-a").unwrap();
        mux.resource_create_empty_workspace(Some("One".into()), None, Some(0), &first).unwrap();
        let reused = WorkspaceMutation::new("global-key", "client-b").unwrap();
        let error = mux
            .resource_create_empty_workspace(Some("Two".into()), None, Some(1), &reused)
            .unwrap_err();
        assert!(error.to_string().contains("idempotency.conflict"));
        mux.with_state(|state| {
            assert_eq!(state.workspaces.len(), 1);
            assert_eq!(state.workspaces[0].name, "One");
        });
    }

    #[test]
    fn resource_results_never_expose_numeric_workspace_slots() {
        let mux = test_mux();
        let result = mux
            .resource_create_empty_workspace(
                Some("Public".into()),
                None,
                Some(0),
                &WorkspaceMutation::new("public-only", "test").unwrap(),
            )
            .unwrap()
            .result;
        let object = result.as_object().unwrap();
        assert_eq!(
            object.keys().map(String::as_str).collect::<HashSet<_>>(),
            HashSet::from(["workspace", "name", "index"])
        );
        assert!(WorkspacePublicId::parse(object["workspace"].as_str().unwrap()).is_ok());
        let encoded = serde_json::to_string(&result).unwrap();
        for forbidden in ["key", "workspace_key", "slot", "numeric_id", "short_id", "surface"] {
            assert!(!encoded.contains(forbidden), "leaked {forbidden}: {encoded}");
        }
    }

    #[test]
    fn resource_large_workspace_mutations_are_targeted_and_query_bounded() {
        const WORKSPACE_COUNT: usize = 1_000;
        let mux = test_mux();
        let mut durable = Vec::with_capacity(WORKSPACE_COUNT);
        let mut memory = Vec::with_capacity(WORKSPACE_COUNT);
        let mut order = Vec::with_capacity(WORKSPACE_COUNT);
        for index in 0..WORKSPACE_COUNT {
            let public_id = restore_workspace_id(index as u128 + 1);
            let key = format!("00000000-0000-4000-8000-{index:012x}");
            let slot = mux.next_id();
            let name = format!("Workspace {}", index + 1);
            durable.push(ResourceChange::UpsertWorkspace {
                workspace: RegistryWorkspace {
                    id: slot,
                    public_id: public_id.clone(),
                    key: key.clone(),
                    name: name.clone(),
                    group_key: mux.session.clone(),
                },
                position: index,
                active_screen: None,
            });
            memory.push(Workspace {
                id: slot,
                public_id: public_id.clone(),
                key,
                name,
                screens: Vec::new(),
                active_screen: 0,
            });
            order.push(public_id);
        }
        durable.push(ResourceChange::SetWorkspaceOrder { workspace_ids: order.clone() });
        durable.push(ResourceChange::SetActiveWorkspace { workspace_id: order.first().cloned() });
        {
            let mut registry = mux.workspace_registry.lock().unwrap();
            let commit = registry
                .commit_resource_patch(
                    &WorkspaceMutation::new("seed-thousand", "test").unwrap(),
                    "session.seed",
                    &serde_json::json!({"count":WORKSPACE_COUNT}),
                    None,
                    Some(0),
                    &ResourcePatch { changes: durable },
                    &serde_json::json!({"count":WORKSPACE_COUNT}),
                    &serde_json::json!([{"kind":"session.seeded"}]),
                )
                .unwrap();
            let mut state = mux.state.lock().unwrap();
            state.workspaces.reserve(WORKSPACE_COUNT);
            state.workspace_index_by_id.reserve(WORKSPACE_COUNT);
            state.workspace_id_by_key.reserve(WORKSPACE_COUNT);
            state.resource_indexes.workspaces.reserve(WORKSPACE_COUNT);
            state.resource_indexes.workspace_ids.reserve(WORKSPACE_COUNT);
            for workspace in memory {
                state.push_workspace(workspace);
            }
            state.active_workspace = 0;
            state.resource_revision = commit.revision;
        }

        let target = order[499].clone();
        let renamed = mux
            .resource_rename_workspace(
                &target,
                "Renamed".into(),
                None,
                Some(1),
                &WorkspaceMutation::new("rename-thousand", "test").unwrap(),
            )
            .unwrap();
        assert_eq!(renamed.revision, 2);
        assert_eq!(
            mux.last_resource_mutation_metrics(),
            ResourceMutationMetrics {
                touched_resources: 1,
                order_entries: 0,
                terminal_queries: 0,
                changed_rows: 1,
            }
        );
        mux.with_state(|state| {
            assert_eq!(state.workspace_by_public_id(&target).unwrap().name, "Renamed");
        });

        let moved = mux
            .resource_move_workspace(
                &target,
                WORKSPACE_COUNT - 1,
                None,
                Some(2),
                &WorkspaceMutation::new("move-thousand", "test").unwrap(),
            )
            .unwrap();
        assert_eq!(moved.revision, 3);
        assert_eq!(
            mux.last_resource_mutation_metrics(),
            ResourceMutationMetrics {
                touched_resources: 1,
                order_entries: WORKSPACE_COUNT,
                terminal_queries: 0,
                changed_rows: WORKSPACE_COUNT,
            }
        );
        mux.with_state(|state| {
            assert_eq!(state.workspaces.last().unwrap().public_id, target);
            assert_eq!(state.workspaces.len(), WORKSPACE_COUNT);
        });
        let registry = mux.workspace_registry.lock().unwrap().snapshot().unwrap();
        assert_eq!(registry.resource_revision, 3);
        assert_eq!(registry.workspaces.last().unwrap().public_id, target);
        assert_eq!(registry.workspaces.last().unwrap().name, "Renamed");
    }

    #[test]
    fn resource_startup_revalidates_exact_layout_and_viewport_coverage() {
        let (snapshot, mut topology) = resource_restore_fixture();
        topology.panes[3].screen_id = restore_screen_id(2);
        assert_eq!(
            restore_resource_state(snapshot.clone(), topology).err().unwrap().to_string(),
            format!("screen {} layout does not cover its panes exactly once", restore_screen_id(1))
        );

        let (_, mut topology) = resource_restore_fixture();
        topology.screens[0].viewport.columns[1].id = restore_split_id(999);
        assert!(
            restore_resource_state(snapshot, topology)
                .err()
                .unwrap()
                .to_string()
                .contains("unknown projected split")
        );
    }

    fn resource_restore_patch(
        snapshot: &RegistrySnapshot,
        topology: &ResourceTopologySnapshot,
    ) -> ResourcePatch {
        let active_screens = topology.active_screens.iter().cloned().collect::<HashMap<_, _>>();
        let mut changes = Vec::new();
        for (position, workspace) in snapshot.workspaces.iter().enumerate() {
            changes.push(ResourceChange::UpsertWorkspace {
                workspace: workspace.clone(),
                position,
                active_screen: active_screens.get(&workspace.public_id).cloned().flatten(),
            });
        }
        changes.extend(topology.screens.iter().cloned().map(ResourceChange::UpsertScreen));
        changes.extend(topology.panes.iter().cloned().map(ResourceChange::UpsertPane));
        changes.extend(topology.browsers.iter().cloned().map(ResourceChange::UpsertBrowser));
        for tab in &topology.tabs {
            let ContentPublicId::Browser(_) = &tab.content_id else {
                panic!("restart fixture uses browser tabs");
            };
            changes.push(ResourceChange::UpsertTab(tab.clone()));
        }
        changes.push(ResourceChange::SetWorkspaceOrder {
            workspace_ids: snapshot
                .workspaces
                .iter()
                .map(|workspace| workspace.public_id.clone())
                .collect(),
        });
        for workspace in &snapshot.workspaces {
            changes.push(ResourceChange::SetScreenOrder {
                workspace_id: workspace.public_id.clone(),
                screen_ids: topology
                    .screens
                    .iter()
                    .filter(|screen| screen.workspace_id == workspace.public_id)
                    .map(|screen| screen.public_id.clone())
                    .collect(),
            });
        }
        for pane in &topology.panes {
            changes.push(ResourceChange::SetTabOrder {
                pane_id: pane.public_id.clone(),
                tab_ids: topology
                    .tabs
                    .iter()
                    .filter(|tab| tab.pane_id == pane.public_id)
                    .map(|tab| tab.public_id.clone())
                    .collect(),
            });
        }
        changes.push(ResourceChange::SetActiveWorkspace {
            workspace_id: topology.active_workspace.clone(),
        });
        ResourcePatch { changes }
    }

    #[test]
    fn persistent_mux_restart_keeps_public_topology_and_browser_tabs() {
        let root = std::env::temp_dir()
            .join(format!("cmux-resource-restart-{}", WorkspacePublicId::random().unwrap()));
        let (fixture_snapshot, fixture_topology) = resource_restore_fixture();
        {
            let mut registry = WorkspaceRegistry::open(&root, "restart").unwrap();
            registry
                .commit_resource_patch(
                    &WorkspaceMutation::new("seed-restart", "test").unwrap(),
                    "session.restore_fixture",
                    &serde_json::json!({"fixture":"nested-columns"}),
                    None,
                    Some(0),
                    &resource_restore_patch(&fixture_snapshot, &fixture_topology),
                    &serde_json::json!({"restored":true}),
                    &serde_json::json!([{"event":"session.restored"}]),
                )
                .unwrap();
        }

        let registry = WorkspaceRegistry::open(&root, "restart").unwrap();
        let mux = Mux::from_workspace_registry(
            "restart".into(),
            SurfaceOptions::default(),
            registry,
            ProviderWorkspaceState::default(),
            true,
        )
        .unwrap();
        mux.with_state(|state| {
            assert_eq!(state.workspaces.len(), 2);
            assert_eq!(state.active_workspace, 1);
            assert!(state.workspaces[1].screens.is_empty());
            assert_eq!(state.workspaces[0].active_screen, 1);
            assert_eq!(state.workspaces[0].screens[0].layout_columns.len(), 2);
            assert!(state.workspaces[0].screens[0].layout_column_projection_is_consistent());
            assert_eq!(state.surfaces.len(), fixture_topology.tabs.len());
            for tab in &fixture_topology.tabs {
                let slot = state.resource_indexes.tabs[&tab.public_id];
                let surface = &state.surfaces[&slot];
                let ContentPublicId::Browser(browser_id) = &tab.content_id else {
                    unreachable!("restart fixture uses browser tabs");
                };
                let expected_browser = fixture_topology
                    .browsers
                    .iter()
                    .find(|browser| &browser.public_id == browser_id)
                    .unwrap();
                assert_eq!(surface.resource_identity().unwrap().tab_id, tab.public_id);
                assert_eq!(surface.resource_identity().unwrap().content_id, tab.content_id);
                assert_eq!(surface.name(), tab.name);
                assert_eq!(surface.browser_url().as_deref(), Some(expected_browser.url.as_str()));
                assert_eq!(surface.size(), (expected_browser.cols, expected_browser.rows));
            }
        });
        let _ = mux.shutdown();
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn restart_finishes_a_close_committed_before_live_state_detach() {
        let root = std::env::temp_dir()
            .join(format!("cmux-resource-close-crash-{}", WorkspacePublicId::random().unwrap()));
        let session = "resource-close-crash";
        let session_selectors = serde_json::json!({"machine":"current","session":"current"});
        let registry = WorkspaceRegistry::open(&root, session).unwrap();
        let mux = Mux::from_workspace_registry(
            session.into(),
            SurfaceOptions::default(),
            registry,
            ProviderWorkspaceState::default(),
            true,
        )
        .unwrap();
        let created = public_request(
            &mux,
            "create-workspace",
            "workspace.create",
            serde_json::json!({
                "machine":"current",
                "session":"current",
                "name":"close crash",
                "initial_content":"empty",
            }),
            Some("close-crash-create"),
        );
        let workspace = created["result"]["value"]["workspace_id"].as_str().unwrap().to_string();
        let before_revision =
            created["result"]["revision"].as_str().unwrap().parse::<u64>().unwrap();
        mux.set_resource_close_after_commit_hook_for_test(Some(Arc::new(|| {
            panic!("simulated daemon crash after close commit")
        })));
        let crashed = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            public_request(
                &mux,
                "close-workspace",
                "workspace.close",
                serde_json::json!({
                    "machine":"current",
                    "session":"current",
                    "workspace":workspace,
                }),
                Some("close-crash-effect"),
            )
        }));
        assert!(crashed.is_err());
        drop(mux);

        let registry = WorkspaceRegistry::open(&root, session).unwrap();
        let reopened = Mux::from_workspace_registry(
            session.into(),
            SurfaceOptions::default(),
            registry,
            ProviderWorkspaceState::default(),
            true,
        )
        .unwrap();
        let snapshot = crate::resource_api::public_session_snapshot(&reopened).unwrap();
        assert!(snapshot["workspaces"].as_array().unwrap().is_empty());
        let events = reopened.resource_events_after(before_revision).unwrap();
        assert_eq!(events.batches.len(), 1);
        assert_eq!(events.batches[0].revision, before_revision + 1);
        let replay = public_request(
            &reopened,
            "close-replay",
            "workspace.close",
            serde_json::json!({
                "machine":"current",
                "session":"current",
                "workspace":workspace,
            }),
            Some("close-crash-effect"),
        );
        assert_eq!(replay["result"]["replayed"], true);
        assert_eq!(replay["result"]["revision"], (before_revision + 1).to_string());
        assert_eq!(reopened.resource_events_after(before_revision).unwrap().batches.len(), 1);
        assert_eq!(
            public_request(&reopened, "snapshot", "session.snapshot", session_selectors, None,)["result"]
                ["workspaces"],
            serde_json::json!([])
        );
        let _ = reopened.shutdown();
        drop(reopened);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn persistent_mux_restart_restores_auxiliary_resources_and_exact_replay() {
        let root = std::env::temp_dir().join(format!(
            "cmux-resource-auxiliary-restart-{}",
            WorkspacePublicId::random().unwrap()
        ));
        let session = "auxiliary-restart";
        let selectors = serde_json::json!({"machine":"current","session":"current"});
        let create_params = serde_json::json!({
            "machine":"current",
            "session":"current",
            "name":"Durable resources",
            "initial_content":"terminal",
        });
        let registry = WorkspaceRegistry::open(&root, session).unwrap();
        let mux = Mux::from_workspace_registry(
            session.into(),
            SurfaceOptions::default(),
            registry,
            ProviderWorkspaceState::default(),
            true,
        )
        .unwrap();

        let created = public_request(
            &mux,
            "create",
            "workspace.create",
            create_params.clone(),
            Some("auxiliary-restart-create"),
        );
        let created_value = created["result"]["value"].clone();
        let terminal_id = created_value["terminal_id"].as_str().unwrap().to_string();
        let notification_params = serde_json::json!({
            "machine":"current",
            "session":"current",
            "title":"Durable build",
            "body":"All checks passed",
            "level":"warning",
            "terminal_id":terminal_id,
        });
        let notification = public_request(
            &mux,
            "notification",
            "notification.create",
            notification_params.clone(),
            Some("auxiliary-restart-notification"),
        );
        let notification_value = notification["result"]["value"].clone();
        let agent_params = serde_json::json!({
            "machine":"current",
            "session":"current",
            "terminal_id":terminal_id,
            "state":"working",
            "source":"hook",
            "source_session":"worker-7",
        });
        let agent = public_request(
            &mux,
            "agent",
            "agent.report",
            agent_params.clone(),
            Some("auxiliary-restart-agent"),
        );
        let agent_value = agent["result"]["value"].clone();
        let defaults_params = serde_json::json!({
            "machine":"current",
            "session":"current",
            "foreground":"#123456",
            "background":"#654321",
            "cursor_style":"bar",
            "cursor_blink":true,
            "palette":{"1":"#abcdef"},
            "complete":true,
        });
        let defaults = public_request(
            &mux,
            "defaults",
            "session.terminal_defaults.update",
            defaults_params.clone(),
            Some("auxiliary-restart-defaults"),
        );
        let defaults_value = defaults["result"]["value"].clone();
        let projection_id = "projection_00000000000000000000000000000001";
        let projection_params = serde_json::json!({
            "machine":"current",
            "session":"current",
            "frontend_projection":projection_id,
            "projection":{
                "schema":"cmux.sidebar.test/1",
                "revision":"7",
                "rows":[{"label":"build","state":"working"}],
            },
        });
        let projection = public_request(
            &mux,
            "projection",
            "frontend_projection.put",
            projection_params.clone(),
            Some("auxiliary-restart-projection"),
        );
        let projection_value = projection["result"]["value"].clone();

        let before = crate::resource_api::public_session_snapshot(&mux).unwrap();
        assert!(before["notifications"].as_array().unwrap().contains(&notification_value));
        assert!(before["agents"].as_array().unwrap().contains(&agent_value));
        assert!(before["frontend_projections"].as_array().unwrap().contains(&projection_value));
        let durable_colors = mux.default_colors();
        assert_eq!(defaults_value["foreground"], "#123456");
        assert_eq!(defaults_value["background"], "#654321");
        assert_eq!(defaults_value["cursor_style"], "bar");
        assert_eq!(defaults_value["cursor_blink"], true);
        assert_eq!(defaults_value["palette"]["1"], "#abcdef");
        let _ = mux.shutdown();
        drop(mux);

        let registry = WorkspaceRegistry::open(&root, session).unwrap();
        let reopened = Mux::from_workspace_registry(
            session.into(),
            SurfaceOptions::default(),
            registry,
            ProviderWorkspaceState::default(),
            true,
        )
        .unwrap();
        assert_eq!(reopened.default_colors(), durable_colors);
        let config_colors = DefaultColors {
            fg: Some(crate::Rgb { r: 0xee, g: 0xdd, b: 0xcc }),
            ..Default::default()
        };
        reopened.seed_default_colors_if_no_durable_override(config_colors);
        assert_eq!(
            reopened.default_colors(),
            durable_colors,
            "startup config must not overwrite an explicit durable update"
        );

        let after = crate::resource_api::public_session_snapshot(&reopened).unwrap();
        assert!(after["notifications"].as_array().unwrap().contains(&notification_value));
        assert!(after["agents"].as_array().unwrap().contains(&agent_value));
        assert!(after["frontend_projections"].as_array().unwrap().contains(&projection_value));
        let notifications = public_request(
            &reopened,
            "notifications",
            "notification.list",
            selectors.clone(),
            None,
        );
        assert_eq!(notifications["result"], serde_json::json!([notification_value]));
        let agents = public_request(&reopened, "agents", "agent.list", selectors.clone(), None);
        assert_eq!(agents["result"], serde_json::json!([agent_value]));
        let snapshot = public_request(&reopened, "snapshot", "session.snapshot", selectors, None);
        assert_eq!(snapshot["result"]["notifications"], after["notifications"]);
        assert_eq!(snapshot["result"]["agents"], after["agents"]);
        assert_eq!(snapshot["result"]["frontend_projections"], after["frontend_projections"]);

        for (id, operation, params, key, original) in [
            (
                "create-replay",
                "workspace.create",
                create_params,
                "auxiliary-restart-create",
                created_value,
            ),
            (
                "notification-replay",
                "notification.create",
                notification_params,
                "auxiliary-restart-notification",
                notification_value,
            ),
            ("agent-replay", "agent.report", agent_params, "auxiliary-restart-agent", agent_value),
            (
                "defaults-replay",
                "session.terminal_defaults.update",
                defaults_params,
                "auxiliary-restart-defaults",
                defaults_value,
            ),
            (
                "projection-replay",
                "frontend_projection.put",
                projection_params,
                "auxiliary-restart-projection",
                projection_value,
            ),
        ] {
            let replay = public_request(&reopened, id, operation, params, Some(key));
            assert_eq!(replay["result"]["value"], original, "{operation}");
            assert_eq!(replay["result"]["replayed"], true, "{operation}");
        }
        assert_eq!(reopened.resource_notifications(256).len(), 1);
        assert_eq!(reopened.list_agents(None, None).len(), 1);
        assert_eq!(
            reopened
                .workspace_registry
                .lock()
                .unwrap()
                .public_frontend_projections()
                .unwrap()
                .len(),
            1
        );

        let _ = reopened.shutdown();
        drop(reopened);

        let registry = WorkspaceRegistry::open(&root, session).unwrap();
        registry.insert_corrupt_terminal_defaults_for_test();
        let error = Mux::from_workspace_registry(
            session.into(),
            SurfaceOptions::default(),
            registry,
            ProviderWorkspaceState::default(),
            true,
        )
        .err()
        .expect("corrupt durable terminal defaults must fail startup");
        assert!(
            error.to_string().contains("omitted background"),
            "unexpected startup error: {error:#}"
        );
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn resource_layout_undo_confirmation_is_restart_safe() {
        let root = std::env::temp_dir()
            .join(format!("cmux-resource-undo-restart-{}", WorkspacePublicId::random().unwrap()));
        let (fixture_snapshot, fixture_topology) = resource_restore_fixture();
        {
            let mut registry = WorkspaceRegistry::open(&root, "undo-restart").unwrap();
            registry
                .commit_resource_patch(
                    &WorkspaceMutation::new("seed-undo-restart", "test").unwrap(),
                    "session.restore_fixture",
                    &serde_json::json!({"fixture":"layout-undo-restart"}),
                    None,
                    Some(0),
                    &resource_restore_patch(&fixture_snapshot, &fixture_topology),
                    &serde_json::json!({"restored":true}),
                    &serde_json::json!([{"event":"session.restored"}]),
                )
                .unwrap();
        }

        let registry = WorkspaceRegistry::open(&root, "undo-restart").unwrap();
        let mux = Mux::from_workspace_registry(
            "undo-restart".into(),
            SurfaceOptions::default(),
            registry,
            ProviderWorkspaceState::default(),
            true,
        )
        .unwrap();
        let base_pane = mux.with_state(|state| state.workspaces[0].screens[0].active_pane);
        let created = mux.new_pane_right(base_pane, 0.5, Some((38, 22))).unwrap();
        let created_pane = mux.with_state(|state| state.pane_of(created.id).unwrap());
        let (selectors, screen_id) = {
            let registry = mux.workspace_registry.lock().unwrap();
            let state = mux.state.lock().unwrap();
            let (workspace, screen) = state.screen_of(created_pane).unwrap();
            (
                crate::ResourceSelectors {
                    machine: Some(registry.machine_id().to_string()),
                    session: Some(registry.session_id().to_string()),
                    workspace: Some(state.workspaces[workspace].public_id.to_string()),
                    screen: Some(state.workspaces[workspace].screens[screen].public_id.to_string()),
                    ..crate::ResourceSelectors::default()
                },
                state.workspaces[workspace].screens[screen].public_id.clone(),
            )
        };
        let preview_fields =
            serde_json::json!({"confirm_close":false}).as_object().unwrap().clone();
        let durable_before =
            mux.workspace_registry.lock().unwrap().resource_topology_snapshot().unwrap();
        let preview_error = mux
            .resource_topology_operation(
                ResourceOperation::ScreenLayoutUndo,
                selectors.clone(),
                preview_fields,
                Some(durable_before.revision),
                &WorkspaceMutation::new("restart-undo-preview", "test").unwrap(),
            )
            .unwrap_err();
        let preview_revision = preview_error
            .downcast_ref::<ResourceError>()
            .and_then(|error| error.details["revision"].as_str())
            .and_then(|revision| revision.parse::<u64>().ok())
            .unwrap();
        let confirmation_token = preview_error
            .downcast_ref::<ResourceError>()
            .and_then(|error| error.details["confirmation_token"].as_str())
            .unwrap()
            .to_string();
        assert_eq!(preview_revision, durable_before.revision);
        drop(created);
        let _ = mux.shutdown();
        let shutdown_deadline = Instant::now() + Duration::from_secs(10);
        while Arc::strong_count(&mux) > 1 && Instant::now() < shutdown_deadline {
            std::thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(
            Arc::strong_count(&mux),
            1,
            "restored browser bootstrap workers must release the mux before restart"
        );
        drop(mux);

        let registry = WorkspaceRegistry::open(&root, "undo-restart").unwrap();
        let reopened = Mux::from_workspace_registry(
            "undo-restart".into(),
            SurfaceOptions::default(),
            registry,
            ProviderWorkspaceState::default(),
            true,
        )
        .unwrap();
        let reopened_before =
            reopened.workspace_registry.lock().unwrap().resource_topology_snapshot().unwrap();
        // Restart may reconcile terminal liveness into a later public
        // revision. The confirmation token is fenced by generation, screen,
        // layout revision, and pane/tab membership rather than that unrelated
        // liveness revision.
        assert!(reopened_before.revision >= durable_before.revision);
        assert_eq!(reopened_before.screens, durable_before.screens);
        assert_eq!(reopened_before.panes, durable_before.panes);
        assert_eq!(reopened_before.tabs, durable_before.tabs);
        assert!(reopened_before.screens.iter().any(|screen| screen.public_id == screen_id));
        let state_before = reopened.with_state(state_topology_fingerprint);
        let confirm_fields = serde_json::json!({
            "confirm_close":true,
            "confirmation_token":confirmation_token,
        })
        .as_object()
        .unwrap()
        .clone();
        let confirm_fingerprint = serde_json::json!({
            "operation":"screen.layout.undo",
            "selectors":selectors,
            "fields":confirm_fields,
        });
        let confirm_mutation = WorkspaceMutation::new("restart-undo-confirm", "test").unwrap();

        let error = reopened
            .resource_topology_operation(
                ResourceOperation::ScreenLayoutUndo,
                selectors,
                confirm_fields,
                Some(reopened_before.revision),
                &confirm_mutation,
            )
            .unwrap_err();

        assert!(matches!(
            error.downcast_ref::<LayoutUndoError>(),
            Some(LayoutUndoError::Unavailable)
        ));
        assert_eq!(reopened.with_state(state_topology_fingerprint), state_before);
        let registry = reopened.workspace_registry.lock().unwrap();
        assert_eq!(registry.resource_topology_snapshot().unwrap(), reopened_before);
        assert!(
            registry.resource_events_after(reopened_before.revision).unwrap().batches.is_empty()
        );
        assert!(
            registry
                .lookup_resource_effect(
                    &confirm_mutation.id,
                    "screen.layout.undo",
                    &confirm_fingerprint,
                )
                .unwrap()
                .is_none()
        );
        drop(registry);
        let _ = reopened.shutdown();
        drop(reopened);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[cfg(unix)]
    fn insert_terminal_identity_surface(
        mux: &Arc<Mux>,
        terminal_id: &str,
        incarnation: &str,
        workspace_key: &str,
    ) -> Arc<Surface> {
        let surface = Surface::exited_terminal_placeholder(
            mux.next_id(),
            mux.surface_options.lock().unwrap().clone(),
            Arc::downgrade(mux),
            TerminalHostIdentity {
                terminal_id: terminal_id.to_string(),
                incarnation: incarnation.to_string(),
            },
        )
        .unwrap();
        let _registry = mux.workspace_registry.lock().unwrap();
        let mut state = mux.state.lock().unwrap();
        insert_surface_checked(mux, &mut state, surface.clone()).unwrap();
        let (placement, changed) = mux
            .project_terminal_to_workspace_in_state(&mut state, terminal_id, workspace_key)
            .unwrap();
        assert!(changed);
        assert_eq!(placement.unwrap().surface, surface.id);
        surface
    }

    #[cfg(unix)]
    fn insert_running_terminal_identity_surface(
        mux: &Arc<Mux>,
        terminal_id: &str,
        incarnation: &str,
        workspace_key: &str,
    ) -> Arc<Surface> {
        let surface =
            mux.seed_running_terminal_for_test(terminal_id, incarnation, workspace_key).unwrap();
        mux.surface(surface).unwrap()
    }

    #[test]
    fn terminal_registry_launch_spec_never_persists_environment_secrets() {
        let sentinel = "cmux-secret-sentinel-do-not-persist";
        let options = SurfaceOptions {
            command: Some(vec!["/bin/sh".into(), "-c".into(), sentinel.into()]),
            cwd: Some(format!("/tmp/{sentinel}")),
            extra_env: vec![
                ("API_BEARER_TOKEN".into(), sentinel.into()),
                ("CMUX_TUI_SOCKET".into(), "/tmp/cmux.sock".into()),
            ],
            ..SurfaceOptions::default()
        };
        let encoded = serde_json::to_string(&terminal_launch_spec(&options)).unwrap();
        assert!(!encoded.contains(sentinel));
        assert!(!encoded.contains("API_BEARER_TOKEN"));
        assert!(!encoded.contains("/tmp/cmux.sock"));
        assert!(!encoded.contains("/bin/sh"));
        assert!(encoded.contains("CMUX_TUI_SOCKET"));
    }

    #[test]
    fn terminal_create_mutation_persists_only_a_secret_free_digest() {
        const TERMINAL: &str = "00000000000040008000000000000009";
        let sentinel = "cmux-create-secret-sentinel-do-not-persist";
        let root = std::env::temp_dir()
            .join(format!("cmux-create-fingerprint-{}", crate::workspace_registry::new_uuid_v4()));
        let argv = vec!["/bin/sh".to_string(), "-c".to_string(), sentinel.to_string()];
        let cwd = format!("/tmp/{sentinel}");
        let name = format!("terminal-{sentinel}");
        let fingerprint = terminal_create_fingerprint(
            "workspace-one",
            Some(TERMINAL),
            Some(&argv),
            Some(&cwd),
            Some(&name),
            Some((80, 24)),
        )
        .unwrap();
        assert!(!serde_json::to_string(&fingerprint).unwrap().contains(sentinel));

        {
            let mut registry = WorkspaceRegistry::open(&root, "secret-test").unwrap();
            registry
                .commit(
                    &WorkspaceMutation::new("workspace", "test").unwrap(),
                    &serde_json::json!({"op":"create-workspace"}),
                    None,
                    Some(0),
                    "workspace-added",
                    "workspace-one",
                    &[RegistryWorkspace {
                        id: 1,
                        public_id: WorkspacePublicId::random().unwrap(),
                        key: "workspace-one".into(),
                        name: "One".into(),
                        group_key: "secret-test".into(),
                    }],
                    &serde_json::json!({"workspace":1,"key":"workspace-one"}),
                )
                .unwrap();
            registry
                .commit_terminal(
                    &WorkspaceMutation::new("create", "browser").unwrap(),
                    &fingerprint,
                    None,
                    Some(0),
                    "terminal-reserved",
                    &RegistryTerminal {
                        terminal_id: TERMINAL.into(),
                        workspace_key: "workspace-one".into(),
                        incarnation: None,
                        lifecycle: TerminalLifecycle::Launching,
                        launch_spec: serde_json::json!({"command_present":true}),
                        exit: None,
                    },
                    &serde_json::json!({"terminal_id":TERMINAL}),
                )
                .unwrap();
        }

        fn assert_tree_does_not_contain(path: &Path, needle: &[u8]) {
            for entry in std::fs::read_dir(path).unwrap() {
                let path = entry.unwrap().path();
                if path.is_dir() {
                    assert_tree_does_not_contain(&path, needle);
                } else {
                    let bytes = std::fs::read(&path).unwrap();
                    assert!(
                        !bytes.windows(needle.len()).any(|window| window == needle),
                        "secret persisted in {}",
                        path.display()
                    );
                }
            }
        }
        assert_tree_does_not_contain(&root, sentinel.as_bytes());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn stable_terminal_lookup_never_chooses_between_duplicate_ids() {
        let terminal_id = "00112233445566778899aabbccddeeff";
        let identities = vec![
            (
                10,
                TerminalHostIdentity {
                    terminal_id: terminal_id.into(),
                    incarnation: "11111111111111111111111111111111".into(),
                },
            ),
            (
                20,
                TerminalHostIdentity {
                    terminal_id: terminal_id.into(),
                    incarnation: "22222222222222222222222222222222".into(),
                },
            ),
        ];

        assert_eq!(
            unique_terminal_match(terminal_id, identities.clone()).unwrap_err().to_string(),
            "duplicate_terminal_id"
        );
        let unique =
            unique_terminal_match(terminal_id, identities.into_iter().take(1)).unwrap().unwrap();
        assert_eq!(unique.0, 10);
    }

    #[test]
    fn failed_viewer_resize_preserves_previous_report_and_creation_default() {
        let mux = test_mux();
        let missing_surface = 99_999;
        mux.record_client_size(90, 30);
        mux.client_sizing
            .lock()
            .unwrap()
            .surfaces
            .entry(missing_surface)
            .or_default()
            .insert(7, (80, 25));

        assert!(mux.resize_surface_for_client(missing_surface, 7, 120, 40).is_err());
        assert_eq!(mux.client_surface_size(missing_surface, 7), Some((80, 25)));
        assert_eq!(mux.new_workspace(None, None).unwrap().size(), (90, 30));
    }

    #[test]
    fn removing_smallest_viewer_updates_unsized_creation_default() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, None).unwrap();

        mux.resize_surface_for_client(surface.id, 1, 120, 40).unwrap();
        mux.resize_surface_for_client(surface.id, 2, 80, 50).unwrap();
        assert_eq!(surface.size(), (80, 40));

        mux.remove_surface_size_client(surface.id, 2);
        assert_eq!(surface.size(), (120, 40));
        assert_eq!(mux.new_workspace(None, None).unwrap().size(), (120, 40));
    }

    #[test]
    fn removing_latest_report_restores_previous_surface_creation_default() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let second = mux.new_workspace(None, None).unwrap();

        mux.resize_surface_for_client(first.id, 1, 120, 40).unwrap();
        mux.resize_surface_for_client(second.id, 2, 80, 24).unwrap();
        assert_eq!(mux.new_workspace(None, None).unwrap().size(), (80, 24));

        mux.remove_surface_size_client(second.id, 2);

        assert_eq!(mux.new_workspace(None, None).unwrap().size(), (120, 40));
    }

    #[test]
    fn removing_last_viewer_restores_default_for_unsized_creation() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, None).unwrap();

        mux.resize_surface_for_client(surface.id, 1, 117, 30).unwrap();
        mux.remove_size_client(1);

        assert_eq!(surface.size(), (117, 30));
        assert_eq!(mux.new_workspace(None, None).unwrap().size(), (80, 24));
    }

    #[test]
    fn excluded_viewer_keeps_reporting_without_constraining_the_shared_grid() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, None).unwrap();

        mux.resize_surface_for_client(surface.id, 1, 120, 40).unwrap();
        mux.resize_surface_for_client(surface.id, 2, 80, 50).unwrap();
        assert_eq!(surface.size(), (80, 40));

        assert_eq!(mux.set_client_size_participation(surface.id, 2, false), Some(true));
        assert_eq!(surface.size(), (120, 40));
        assert!(!mux.client_size_participates(surface.id, 2));

        mux.resize_surface_for_client(surface.id, 2, 60, 30).unwrap();
        assert_eq!(surface.size(), (120, 40));
        assert_eq!(mux.client_surface_size(surface.id, 2), Some((60, 30)));

        assert_eq!(mux.set_client_size_participation(surface.id, 2, true), Some(true));
        assert_eq!(surface.size(), (60, 30));
        assert!(mux.client_size_participates(surface.id, 2));
    }

    #[test]
    fn excluded_report_does_not_replace_a_newer_participating_creation_default() {
        let mux = test_mux();
        let excluded_surface = mux.new_workspace(None, None).unwrap();
        let latest_surface = mux.new_workspace(None, None).unwrap();

        mux.resize_surface_for_client(excluded_surface.id, 1, 100, 30).unwrap();
        mux.resize_surface_for_client(excluded_surface.id, 2, 90, 25).unwrap();
        assert_eq!(mux.set_client_size_participation(excluded_surface.id, 2, false), Some(true));
        mux.resize_surface_for_client(latest_surface.id, 3, 120, 40).unwrap();

        mux.resize_surface_for_client(excluded_surface.id, 2, 60, 20).unwrap();

        assert_eq!(excluded_surface.size(), (100, 30));
        assert_eq!(mux.new_workspace(None, None).unwrap().size(), (120, 40));
    }

    #[test]
    fn excluded_report_updates_creation_default_when_surface_uses_fallback() {
        let mux = test_mux();
        let fallback_surface = mux.new_workspace(None, None).unwrap();
        let latest_surface = mux.new_workspace(None, None).unwrap();

        mux.resize_surface_for_client(fallback_surface.id, 1, 100, 30).unwrap();
        assert_eq!(mux.set_client_size_participation(fallback_surface.id, 1, false), Some(true));
        mux.resize_surface_for_client(latest_surface.id, 2, 120, 40).unwrap();

        mux.resize_surface_for_client(fallback_surface.id, 1, 70, 20).unwrap();

        assert_eq!(fallback_surface.size(), (70, 20));
        assert_eq!(mux.new_workspace(None, None).unwrap().size(), (70, 20));
    }

    #[test]
    fn enabling_an_already_participating_client_does_not_create_a_policy() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, None).unwrap();
        mux.resize_surface_for_client(surface.id, 1, 120, 40).unwrap();

        assert_eq!(mux.set_client_size_participation(surface.id, 1, true), Some(false));
        assert_eq!(mux.use_all_client_sizes(surface.id), Some(false));
    }

    #[test]
    fn local_sizing_mutations_broadcast_authoritative_client_changes() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, None).unwrap();
        mux.resize_surface_for_client(surface.id, 7, 80, 24).unwrap();
        let events = mux.subscribe();

        assert_eq!(mux.set_client_size_participation(surface.id, 7, false), Some(true));

        assert!(matches!(
            events.recv_timeout(Duration::from_secs(1)),
            Ok(MuxEvent::ClientChanged { client: 7, .. })
        ));
    }

    #[test]
    fn stale_sizing_target_does_not_change_exclusive_state() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, None).unwrap();
        mux.resize_surface_for_client(surface.id, 1, 120, 40).unwrap();
        mux.resize_surface_for_client(surface.id, 2, 80, 24).unwrap();
        assert_eq!(mux.use_only_client_size(surface.id, 1), Some(true));

        assert_eq!(mux.set_client_size_participation(surface.id, 99, false), None);

        assert!(mux.client_size_participates(surface.id, 1));
        assert!(!mux.client_size_participates(surface.id, 2));
    }

    #[test]
    fn closed_surfaces_reject_sizing_policy_mutations() {
        let mux = test_mux();
        let excluded = mux.new_workspace(None, None).unwrap();
        let exclusive = mux.new_workspace(None, None).unwrap();
        mux.resize_surface_for_client(excluded.id, 1, 120, 40).unwrap();
        mux.resize_surface_for_client(exclusive.id, 2, 80, 24).unwrap();
        assert!(mux.remove_surface_runtime_for_test(excluded.id).is_some());
        assert!(mux.remove_surface_runtime_for_test(exclusive.id).is_some());

        assert_eq!(mux.set_client_size_participation(excluded.id, 1, false), None);
        assert_eq!(mux.use_only_client_size(exclusive.id, 2), None);

        let sizing = mux.client_sizing.lock().unwrap();
        assert!(!sizing.policies.contains_key(&excluded.id));
        assert!(!sizing.policies.contains_key(&exclusive.id));
    }

    #[test]
    fn all_excluded_viewers_fall_back_to_their_shared_minimum() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, None).unwrap();

        mux.resize_surface_for_client(surface.id, 1, 120, 40).unwrap();
        mux.resize_surface_for_client(surface.id, 2, 80, 50).unwrap();
        assert_eq!(surface.size(), (80, 40));

        assert_eq!(mux.set_client_size_participation(surface.id, 1, false), Some(true));
        assert_eq!(surface.size(), (80, 50));
        assert_eq!(mux.set_client_size_participation(surface.id, 2, false), Some(true));

        // tmux's ignore-size flag is only effective while at least one
        // size-capable client is not ignored. If every viewer is ignored,
        // they all participate again so the shared grid remains defined.
        assert_eq!(surface.size(), (80, 40));
    }

    #[test]
    fn excluded_client_fallback_is_independent_per_surface() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let second = mux.new_workspace(None, None).unwrap();

        mux.resize_surface_for_client(first.id, 1, 120, 40).unwrap();
        mux.resize_surface_for_client(second.id, 2, 80, 25).unwrap();
        assert_eq!(mux.set_client_size_participation(second.id, 2, false), Some(true));

        // Every viewer on this terminal is excluded, so this terminal alone
        // falls back to its excluded reports.
        mux.resize_surface_for_client(second.id, 2, 60, 20).unwrap();
        assert_eq!(second.size(), (60, 20));

        assert_eq!(mux.set_client_size_participation(first.id, 1, false), Some(true));
        assert_eq!(first.size(), (120, 40));
        assert_eq!(second.size(), (60, 20));
    }

    #[test]
    fn detaching_client_does_not_change_another_surface_policy() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let second = mux.new_workspace(None, None).unwrap();

        mux.resize_surface_for_client(first.id, 1, 120, 40).unwrap();
        mux.resize_surface_for_client(second.id, 2, 80, 25).unwrap();
        assert_eq!(mux.set_client_size_participation(second.id, 2, false), Some(true));
        mux.resize_surface_for_client(second.id, 2, 60, 20).unwrap();
        assert_eq!(second.size(), (60, 20));

        mux.remove_size_client(1);
        assert_eq!(second.size(), (60, 20));
    }

    #[test]
    fn detaching_client_does_not_resize_an_unrelated_surface() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let second = mux.new_workspace(None, None).unwrap();
        mux.resize_surface_for_client(first.id, 1, 120, 40).unwrap();
        mux.resize_surface_for_client(second.id, 2, 80, 25).unwrap();
        mux.resize_surface(second.id, 100, 35).unwrap();

        mux.remove_size_client(1);

        assert_eq!(second.size(), (100, 35));
    }

    #[test]
    fn detaching_unsized_client_does_not_reapply_a_stale_report() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, None).unwrap();
        mux.resize_surface_for_client(surface.id, 1, 80, 24).unwrap();
        mux.resize_surface(surface.id, 100, 35).unwrap();

        mux.remove_size_client_from_attached_surfaces(2, [surface.id]);

        assert_eq!(surface.size(), (100, 35));
    }

    #[test]
    fn detaching_exclusive_target_restores_remaining_clients() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, None).unwrap();
        let other = mux.new_workspace(None, None).unwrap();
        mux.resize_surface_for_client(surface.id, 1, 120, 40).unwrap();
        mux.resize_surface_for_client(surface.id, 2, 80, 30).unwrap();
        mux.resize_surface_for_client(other.id, 2, 80, 30).unwrap();

        assert_eq!(mux.use_only_client_size(surface.id, 1), Some(true));
        assert_eq!(surface.size(), (120, 40));
        mux.resize_surface_for_client(other.id, 2, 60, 20).unwrap();
        assert_eq!(other.size(), (60, 20));
        let events = mux.subscribe();
        mux.remove_size_client(1);

        assert_eq!(surface.size(), (80, 30));
        assert_eq!(other.size(), (60, 20));
        assert!(mux.client_size_participates(surface.id, 2));
        assert!(
            events
                .try_iter()
                .any(|event| matches!(event, MuxEvent::ClientChanged { client: 2, .. }))
        );
        assert_eq!(mux.use_only_client_size(surface.id, 99), None);
    }

    #[test]
    fn client_sizes_clamp_to_tmux_window_bounds() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, None).unwrap();

        mux.resize_surface_for_client(surface.id, 1, 0, u16::MAX).unwrap();

        assert_eq!(mux.client_surface_size(surface.id, 1), Some((1, 10_000)));
        assert_eq!(surface.size(), (1, 10_000));
    }

    #[test]
    fn in_process_tui_is_listed_as_local_client_zero() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, None).unwrap();
        mux.resize_surface_for_client(surface.id, 0, 100, 30).unwrap();

        let clients = mux.control_clients_json(0);
        assert_eq!(clients[0]["client"], 0);
        assert_eq!(clients[0]["transport"], "local");
        assert_eq!(clients[0]["self"], true);
        assert_eq!(clients[0]["sizes"][0]["cols"], 100);
        assert_eq!(clients[0]["sizes"][0]["rows"], 30);
    }

    #[test]
    fn concurrent_viewer_reports_settle_at_shared_minimum() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, None).unwrap();
        let surface_id = surface.id;
        let pause_first = Arc::new(AtomicBool::new(true));
        let (reached_tx, reached_rx) = std::sync::mpsc::sync_channel(1);
        let release = Arc::new((Mutex::new(false), Condvar::new()));
        let hook_release = release.clone();
        mux.set_client_resize_before_apply(Some(Arc::new(move || {
            if pause_first.swap(false, Ordering::SeqCst) {
                reached_tx.send(()).unwrap();
                let (lock, ready) = &*hook_release;
                let mut released = lock.lock().unwrap();
                while !*released {
                    released = ready.wait(released).unwrap();
                }
            }
        })));

        let first_mux = mux.clone();
        let first = std::thread::spawn(move || {
            first_mux.resize_surface_for_client(surface_id, 1, 120, 40).unwrap();
        });
        reached_rx.recv_timeout(Duration::from_secs(1)).unwrap();

        let second_mux = mux.clone();
        let (second_done_tx, second_done_rx) = std::sync::mpsc::sync_channel(1);
        let second = std::thread::spawn(move || {
            second_mux.resize_surface_for_client(surface_id, 2, 80, 50).unwrap();
            second_done_tx.send(()).unwrap();
        });
        let second_finished_before_release =
            second_done_rx.recv_timeout(Duration::from_millis(250)).is_ok();

        let (lock, ready) = &*release;
        *lock.lock().unwrap() = true;
        ready.notify_all();
        first.join().unwrap();
        if !second_finished_before_release {
            second_done_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        }
        second.join().unwrap();

        assert_eq!(mux.surface(surface_id).unwrap().size(), (80, 40));
        assert_eq!(mux.new_workspace(None, None).unwrap().size(), (80, 40));
    }

    #[test]
    fn concurrent_viewer_removal_and_report_settle_at_shared_minimum() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, None).unwrap();
        let surface_id = surface.id;
        mux.resize_surface_for_client(surface_id, 1, 80, 40).unwrap();
        mux.resize_surface_for_client(surface_id, 2, 120, 50).unwrap();

        let pause_first = Arc::new(AtomicBool::new(true));
        let (reached_tx, reached_rx) = std::sync::mpsc::sync_channel(1);
        let release = Arc::new((Mutex::new(false), Condvar::new()));
        let hook_release = release.clone();
        mux.set_client_resize_before_apply(Some(Arc::new(move || {
            if pause_first.swap(false, Ordering::SeqCst) {
                reached_tx.send(()).unwrap();
                let (lock, ready) = &*hook_release;
                let mut released = lock.lock().unwrap();
                while !*released {
                    released = ready.wait(released).unwrap();
                }
            }
        })));

        let remove_mux = mux.clone();
        let remove = std::thread::spawn(move || {
            remove_mux.remove_surface_size_client(surface_id, 1);
        });
        reached_rx.recv_timeout(Duration::from_secs(1)).unwrap();

        let report_mux = mux.clone();
        let (report_done_tx, report_done_rx) = std::sync::mpsc::sync_channel(1);
        let report = std::thread::spawn(move || {
            report_mux.resize_surface_for_client(surface_id, 2, 90, 45).unwrap();
            report_done_tx.send(()).unwrap();
        });
        let report_finished_before_release =
            report_done_rx.recv_timeout(Duration::from_millis(250)).is_ok();

        let (lock, ready) = &*release;
        *lock.lock().unwrap() = true;
        ready.notify_all();
        remove.join().unwrap();
        if !report_finished_before_release {
            report_done_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        }
        report.join().unwrap();

        assert_eq!(mux.surface(surface_id).unwrap().size(), (90, 45));
    }

    #[test]
    fn randomized_multi_surface_sizing_settles_to_the_model() {
        let mux = test_mux();
        let surfaces =
            (0..3).map(|_| mux.new_workspace(None, Some((80, 24))).unwrap()).collect::<Vec<_>>();
        let mut reports = HashMap::<(SurfaceId, u64), (u16, u16)>::new();
        let mut excluded = HashMap::<SurfaceId, HashSet<u64>>::new();
        let mut exclusive = HashMap::<SurfaceId, u64>::new();
        let mut expected =
            surfaces.iter().map(|surface| (surface.id, surface.size())).collect::<HashMap<_, _>>();
        let mut random = 0x5eed_u64;
        let next = |state: &mut u64| {
            *state = state.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1);
            *state
        };

        for step in 0..1_000 {
            let surface = surfaces[(next(&mut random) as usize) % surfaces.len()].id;
            let client = next(&mut random) % 6 + 1;
            match next(&mut random) % 5 {
                0 | 1 => {
                    let size =
                        ((next(&mut random) % 180 + 1) as u16, (next(&mut random) % 70 + 1) as u16);
                    if exclusive.get(&surface).is_some_and(|target| *target != client) {
                        excluded.entry(surface).or_default().insert(client);
                    }
                    reports.insert((surface, client), size);
                    mux.resize_surface_for_client(surface, client, size.0, size.1).unwrap();
                }
                2 => {
                    reports.remove(&(surface, client));
                    mux.remove_surface_size_client(surface, client);
                }
                3 => {
                    if reports.contains_key(&(surface, client)) {
                        let surface_excluded = excluded.entry(surface).or_default();
                        let participates = surface_excluded.contains(&client);
                        if participates {
                            surface_excluded.remove(&client);
                        } else {
                            surface_excluded.insert(client);
                        }
                        if surface_excluded.is_empty() {
                            excluded.remove(&surface);
                        }
                        assert!(
                            mux.set_client_size_participation(surface, client, participates)
                                .is_some()
                        );
                        exclusive.remove(&surface);
                    }
                }
                _ => {
                    let known = reports.contains_key(&(surface, client));
                    if known && step % 2 == 0 {
                        let known_clients = reports
                            .keys()
                            .filter_map(|(reported_surface, reporter)| {
                                (*reported_surface == surface).then_some(*reporter)
                            })
                            .collect::<HashSet<_>>();
                        excluded.insert(
                            surface,
                            known_clients
                                .into_iter()
                                .filter(|known_client| *known_client != client)
                                .collect(),
                        );
                        exclusive.insert(surface, client);
                        assert!(mux.use_only_client_size(surface, client).is_some());
                    } else {
                        reports.retain(|(_, reporter), _| *reporter != client);
                        for candidate in &surfaces {
                            if exclusive.get(&candidate.id) == Some(&client) {
                                exclusive.remove(&candidate.id);
                                excluded.remove(&candidate.id);
                            } else if let Some(surface_excluded) = excluded.get_mut(&candidate.id) {
                                surface_excluded.remove(&client);
                                if surface_excluded.is_empty() {
                                    excluded.remove(&candidate.id);
                                }
                            }
                        }
                        mux.remove_size_client(client);
                    }
                }
            }

            for candidate in &surfaces {
                let surface_excluded = excluded.get(&candidate.id);
                let use_excluded = !reports.keys().any(|(reported_surface, reporter)| {
                    *reported_surface == candidate.id
                        && !surface_excluded.is_some_and(|clients| clients.contains(reporter))
                });
                let effective = reports
                    .iter()
                    .filter(|((reported_surface, reporter), _)| {
                        *reported_surface == candidate.id
                            && (use_excluded
                                || !surface_excluded
                                    .is_some_and(|clients| clients.contains(reporter)))
                    })
                    .map(|(_, size)| *size)
                    .reduce(|smallest, size| (smallest.0.min(size.0), smallest.1.min(size.1)));
                if let Some(size) = effective {
                    expected.insert(candidate.id, size);
                }
                assert_eq!(
                    candidate.size(),
                    expected[&candidate.id],
                    "step {step}, surface {}, reports={reports:?}, excluded={excluded:?}",
                    candidate.id,
                );
            }
        }
    }

    #[test]
    fn agent_reports_apply_hook_authority() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, None).unwrap();
        let initial_revision = mux.with_state(|state| state.resource_revision);
        let initial_epoch = mux.resource_event_epoch();
        let socket = mux
            .report_agent(
                surface.id,
                AgentState::Working,
                AgentSource::Socket,
                Some("socket-session".to_string()),
            )
            .unwrap();
        assert_eq!(socket.state, AgentState::Working);
        assert_eq!(socket.source, AgentSource::Socket);

        let hook = mux
            .report_agent(
                surface.id,
                AgentState::Blocked,
                AgentSource::Hook,
                Some("hook-session".to_string()),
            )
            .unwrap();
        assert_eq!(hook.state, AgentState::Blocked);
        assert_eq!(hook.source, AgentSource::Hook);

        let ignored_socket = mux
            .report_agent(
                surface.id,
                AgentState::Done,
                AgentSource::Socket,
                Some("late-socket".to_string()),
            )
            .unwrap();
        assert_eq!(ignored_socket.state, AgentState::Blocked);
        assert_eq!(ignored_socket.source, AgentSource::Hook);

        let filtered = mux.list_agents(Some(surface.id), Some(AgentState::Blocked));
        assert_eq!(filtered.len(), 1);
        assert_eq!(filtered[0].session.as_deref(), Some("hook-session"));
        assert!(mux.list_agents(Some(surface.id), Some(AgentState::Done)).is_empty());
        assert_eq!(mux.with_state(|state| state.resource_revision), initial_revision + 3);
        assert_eq!(mux.resource_event_epoch(), initial_epoch + 3);
        assert_eq!(mux.resource_agent_projection_count_for_test().unwrap(), 1);
        let events = mux.resource_events_after(initial_revision).unwrap();
        assert_eq!(events.batches.len(), 3);
        assert_eq!(events.batches[0].changes[0]["value"]["source"], "socket");
        assert_eq!(events.batches[1].changes[0]["value"]["source"], "hook");
        assert_eq!(events.batches[2].changes[0]["value"]["source"], "hook");
        assert_eq!(events.batches[2].changes[0]["value"]["state"], "blocked");
        assert_eq!(events.batches[2].changes[0]["value"]["source_session"], "hook-session");
    }

    #[test]
    fn raw_and_resource_agent_reports_share_durable_order_across_restart() {
        let root = std::env::temp_dir()
            .join(format!("cmux-agent-coordinator-{}", WorkspacePublicId::random().unwrap()));
        let session = "agent-coordinator";
        let registry = WorkspaceRegistry::open(&root, session).unwrap();
        let mux = Mux::from_workspace_registry(
            session.into(),
            SurfaceOptions::default(),
            registry,
            ProviderWorkspaceState::default(),
            true,
        )
        .unwrap();
        let created = public_request(
            &mux,
            "agent-create",
            "workspace.create",
            serde_json::json!({
                "machine":"current",
                "session":"current",
                "initial_content":"terminal",
            }),
            Some("agent-create"),
        );
        let terminal_id =
            TerminalPublicId::parse(created["result"]["value"]["terminal_id"].as_str().unwrap())
                .unwrap();
        let surface = mux.resource_surface_for_terminal(&terminal_id).unwrap();
        let created_revision =
            created["result"]["revision"].as_str().unwrap().parse::<u64>().unwrap();
        let initial_epoch = mux.resource_event_epoch();

        let raw = mux
            .report_agent(
                surface,
                AgentState::Working,
                AgentSource::Socket,
                Some("raw-session".into()),
            )
            .unwrap();
        assert_eq!(raw.state, AgentState::Working);
        assert_eq!(mux.with_state(|state| state.resource_revision), created_revision + 1);

        let hook_params = serde_json::json!({
            "machine":"current",
            "session":"current",
            "terminal_id":terminal_id,
            "state":"blocked",
            "source":"hook",
            "source_session":"hook-session",
            "expected_revision":(created_revision + 1).to_string(),
        });
        let hook = public_request(
            &mux,
            "agent-hook",
            "agent.report",
            hook_params.clone(),
            Some("agent-hook"),
        );
        assert_eq!(hook["result"]["revision"], (created_revision + 2).to_string());
        assert_eq!(hook["result"]["value"]["source"], "hook");
        assert_eq!(hook["result"]["value"]["state"], "blocked");

        let ignored = mux
            .report_agent(
                surface,
                AgentState::Done,
                AgentSource::Socket,
                Some("late-raw-session".into()),
            )
            .unwrap();
        assert_eq!(ignored.state, AgentState::Blocked);
        assert_eq!(ignored.source, AgentSource::Hook);
        assert_eq!(ignored.session.as_deref(), Some("hook-session"));
        assert_eq!(mux.with_state(|state| state.resource_revision), created_revision + 3);
        assert_eq!(mux.resource_event_epoch(), initial_epoch + 3);
        assert_eq!(mux.resource_agent_projection_count_for_test().unwrap(), 1);

        let batches = mux.resource_events_after(created_revision).unwrap().batches;
        assert_eq!(
            batches.iter().map(|batch| batch.revision).collect::<Vec<_>>(),
            vec![created_revision + 1, created_revision + 2, created_revision + 3]
        );
        assert_eq!(batches[0].changes[0]["value"]["source"], "socket");
        assert_eq!(batches[0].changes[0]["value"]["source_session"], "raw-session");
        assert_eq!(batches[1].changes[0]["value"], hook["result"]["value"]);
        assert_eq!(batches[2].changes[0]["value"], hook["result"]["value"]);
        assert_eq!(
            crate::resource_api::public_session_snapshot(&mux).unwrap()["agents"],
            serde_json::json!([hook["result"]["value"].clone()])
        );

        let _ = mux.shutdown();
        drop(mux);

        let registry = WorkspaceRegistry::open(&root, session).unwrap();
        let reopened = Mux::from_workspace_registry(
            session.into(),
            SurfaceOptions::default(),
            registry,
            ProviderWorkspaceState::default(),
            true,
        )
        .unwrap();
        assert_eq!(reopened.resource_agent_projection_count_for_test().unwrap(), 1);
        let restored = reopened.list_agents(None, None);
        assert_eq!(restored.len(), 1);
        assert_eq!(restored[0].state, AgentState::Blocked);
        assert_eq!(restored[0].source, AgentSource::Hook);
        assert_eq!(restored[0].session.as_deref(), Some("hook-session"));
        assert_eq!(
            crate::resource_api::public_session_snapshot(&reopened).unwrap()["agents"],
            serde_json::json!([hook["result"]["value"].clone()])
        );

        let epoch_before_replay = reopened.resource_event_epoch();
        let event_count_before_replay =
            reopened.resource_events_after(created_revision).unwrap().batches.len();
        let replay = public_request(
            &reopened,
            "agent-hook-replay",
            "agent.report",
            hook_params,
            Some("agent-hook"),
        );
        assert_eq!(replay["result"]["replayed"], true);
        assert_eq!(replay["result"]["revision"], (created_revision + 2).to_string());
        assert_eq!(replay["result"]["value"], hook["result"]["value"]);
        assert_eq!(reopened.resource_event_epoch(), epoch_before_replay);
        assert_eq!(
            reopened.resource_events_after(created_revision).unwrap().batches.len(),
            event_count_before_replay
        );
        assert_eq!(reopened.resource_agent_projection_count_for_test().unwrap(), 1);

        let _ = reopened.shutdown();
        drop(reopened);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn concurrent_raw_socket_and_resource_hook_reports_serialize_to_hook_state() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, None).unwrap();
        let surface_id = surface.id;
        let terminal_id = mux.with_state(|state| {
            match state.resource_indexes.content_ids.get(&surface_id).unwrap() {
                ContentPublicId::Terminal(terminal_id) => terminal_id.clone(),
                ContentPublicId::Browser(_) => panic!("workspace opened a browser"),
            }
        });
        let revision = mux.with_state(|state| state.resource_revision);
        let barrier = Arc::new(std::sync::Barrier::new(3));

        let raw_thread = {
            let mux = mux.clone();
            let barrier = barrier.clone();
            std::thread::spawn(move || {
                barrier.wait();
                mux.report_agent(
                    surface_id,
                    AgentState::Working,
                    AgentSource::Socket,
                    Some("racing-socket".into()),
                )
                .unwrap()
            })
        };
        let hook_thread = {
            let mux = mux.clone();
            let barrier = barrier.clone();
            std::thread::spawn(move || {
                barrier.wait();
                mux.resource_report_agent_selected(
                    crate::ResourceSelectors {
                        machine: Some("current".into()),
                        session: Some("current".into()),
                        ..Default::default()
                    },
                    &terminal_id,
                    AgentState::Blocked,
                    AgentSource::Hook,
                    Some("racing-hook".into()),
                    None,
                    &WorkspaceMutation::new("racing-hook", "resource-test").unwrap(),
                )
                .unwrap()
            })
        };
        barrier.wait();
        let raw_result = raw_thread.join().unwrap();
        let hook_commit = hook_thread.join().unwrap();
        assert!(matches!(raw_result.source, AgentSource::Socket | AgentSource::Hook));
        assert!(
            matches!(hook_commit.revision, value if value == revision + 1 || value == revision + 2)
        );

        let records = mux.list_agents(Some(surface_id), None);
        assert_eq!(records.len(), 1);
        assert_eq!(records[0].state, AgentState::Blocked);
        assert_eq!(records[0].source, AgentSource::Hook);
        assert_eq!(records[0].session.as_deref(), Some("racing-hook"));
        assert_eq!(mux.resource_agent_projection_count_for_test().unwrap(), 1);
        let batches = mux.resource_events_after(revision).unwrap().batches;
        assert_eq!(batches.len(), 2);
        assert_eq!(batches[0].revision, revision + 1);
        assert_eq!(batches[1].revision, revision + 2);
        assert_eq!(batches[1].changes[0]["value"]["source"], "hook");
        assert_eq!(batches[1].changes[0]["value"]["state"], "blocked");
    }

    #[test]
    fn failed_raw_agent_report_rolls_back_projection_memory_revision_and_event() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, None).unwrap();
        let revision = mux.with_state(|state| state.resource_revision);
        let epoch = mux.resource_event_epoch();
        mux.workspace_registry.lock().unwrap().set_resource_patch_failure(true).unwrap();

        let error = mux
            .report_agent(
                surface.id,
                AgentState::Working,
                AgentSource::Socket,
                Some("failed-session".into()),
            )
            .unwrap_err();
        assert!(error.to_string().contains("forced resource patch failure"));
        assert!(mux.list_agents(None, None).is_empty());
        assert_eq!(mux.resource_agent_projection_count_for_test().unwrap(), 0);
        assert_eq!(mux.with_state(|state| state.resource_revision), revision);
        assert_eq!(mux.resource_event_epoch(), epoch);
        assert!(mux.resource_events_after(revision).unwrap().batches.is_empty());
        mux.workspace_registry.lock().unwrap().set_resource_patch_failure(false).unwrap();
    }

    #[test]
    fn agent_reports_require_a_terminal_and_never_create_a_default_projection() {
        let mux = test_mux();
        let browser = mux.new_browser_tab("about:blank".into(), None, None).unwrap();
        let revision = mux.with_state(|state| state.resource_revision);
        let epoch = mux.resource_event_epoch();
        let error = mux
            .report_agent(
                browser.id,
                AgentState::Working,
                AgentSource::Socket,
                Some("browser-session".into()),
            )
            .unwrap_err();
        assert!(error.to_string().contains("is not a terminal"));
        assert!(mux.list_agents(None, None).is_empty());
        assert_eq!(mux.resource_agent_projection_count_for_test().unwrap(), 0);
        assert_eq!(mux.with_state(|state| state.resource_revision), revision);
        assert_eq!(mux.resource_event_epoch(), epoch);
    }

    #[test]
    fn closing_a_surface_purges_agent_and_notification_side_tables() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        // A second tab keeps the workspace alive after `first` closes, so we
        // exercise the per-surface purge rather than a full teardown.
        let second = mux.new_tab(Some(pane), None, None).unwrap();

        mux.report_agent(
            first.id,
            AgentState::Working,
            AgentSource::Socket,
            Some("conf".to_string()),
        )
        .unwrap();
        mux.post_notification(
            "Build".to_string(),
            "ok".to_string(),
            NotificationLevel::Warning,
            Some(first.id),
        )
        .unwrap();
        assert_eq!(mux.list_agents(Some(first.id), None).len(), 1);
        assert!(mux.surface_notification(first.id).is_some());

        mux.close_surface(first.id).unwrap();

        // The dead surface must not linger in either side table.
        assert!(mux.list_agents(Some(first.id), None).is_empty());
        assert!(mux.list_agents(None, None).is_empty());
        assert!(mux.surface_notification(first.id).is_none());
        assert!(mux.with_state(|state| state.surfaces.contains_key(&second.id)));
    }

    #[test]
    fn failed_browser_surface_attach_kills_worker() {
        let mux = test_mux();
        let opts = mux.surface_options.lock().unwrap().clone();
        let surface = browser::new_surface(
            999,
            "https://example.test".to_string(),
            (10, 5),
            (8, 16),
            &opts,
            Arc::downgrade(&mux),
        )
        .unwrap();
        let browser = surface.as_browser().expect("browser surface");
        let done = browser.take_worker_done_for_test();
        let mut owner_reservation = mux.reserve_surface_owner().unwrap();

        assert!(matches!(
            mux.attach_browser_surface_to_pane_or_kill(
                123_456,
                &surface,
                1,
                &mut owner_reservation,
            ),
            BrowserSurfaceAttach::MissingPane
        ));
        assert!(browser.is_dead());
        done.recv_timeout(Duration::from_secs(1))
            .expect("browser worker exited after failed attach");
    }

    #[test]
    fn failed_browser_tab_attach_retains_its_shutdown_owner() {
        fn read_ws_json(ws: &mut tungstenite::WebSocket<std::net::TcpStream>) -> Value {
            loop {
                match ws.read().unwrap() {
                    tungstenite::Message::Text(text) => {
                        return serde_json::from_str(&text).unwrap();
                    }
                    tungstenite::Message::Binary(bytes) => {
                        return serde_json::from_slice(&bytes).unwrap();
                    }
                    _ => {}
                }
            }
        }

        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = std::thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut ws = tungstenite::accept(stream).unwrap();
            let discover = read_ws_json(&mut ws);
            assert_eq!(discover["method"], "Target.setDiscoverTargets");
            ws.send(tungstenite::Message::Text(
                serde_json::json!({"id": discover["id"], "result": {}}).to_string().into(),
            ))
            .unwrap();
        });
        let runtime = BrowserRuntime::connect_external_for_test(&format!(
            "ws://{address}/devtools/browser/fake"
        ))
        .unwrap();
        server.join().unwrap();
        let deadline = Instant::now() + Duration::from_secs(1);
        while !runtime.is_closed() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(runtime.is_closed(), "test CDP runtime did not observe disconnect");

        let mux = test_mux();
        let initial = mux.new_workspace(None, Some((80, 24))).unwrap();
        let pane = mux.with_state(|state| state.pane_of(initial.id).unwrap());
        let (bootstrap_reached_tx, bootstrap_reached_rx) = std::sync::mpsc::sync_channel(1);
        let (release_bootstrap_tx, release_bootstrap_rx) = std::sync::mpsc::sync_channel(1);
        let release_bootstrap_rx = Arc::new(Mutex::new(release_bootstrap_rx));
        *mux.browser_bootstrap_before_runtime.lock().unwrap() = Some(Arc::new({
            move || {
                bootstrap_reached_tx.send(()).unwrap();
                release_bootstrap_rx.lock().unwrap().recv().unwrap();
            }
        }));
        *mux.browser_tab_after_spawn.lock().unwrap() = Some(Arc::new({
            let mux = Arc::downgrade(&mux);
            let runtime = runtime.clone();
            move |surface| {
                let mux = mux.upgrade().expect("test mux remained alive through browser spawn");
                surface.as_browser().unwrap().install_shutdown_session_for_test(
                    runtime.clone(),
                    "target-race",
                    "session-race",
                );
                mux.state.lock().unwrap().panes.remove(&pane);
            }
        }));

        let result = mux.new_browser_tab("about:blank".into(), Some(pane), Some((80, 24)));
        bootstrap_reached_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        mux.request_daemon_shutdown();
        release_bootstrap_tx.send(()).unwrap();
        let deadline = Instant::now() + Duration::from_secs(1);
        while mux.async_surface_creations.inner.state.lock().unwrap().active != 0
            && Instant::now() < deadline
        {
            std::thread::sleep(Duration::from_millis(10));
        }

        assert!(result.is_err(), "browser attached after its pane disappeared");
        assert_eq!(
            mux.shutdown_owners.len(),
            1,
            "failed browser attachment discarded its retryable target owner"
        );
        initial.kill();
        runtime.shutdown();
    }

    #[test]
    fn notification_sets_unread_and_clears_when_tab_is_viewed() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let second = mux.new_tab(Some(pane), None, None).unwrap();
        let notification = mux
            .post_notification(
                "Build".to_string(),
                "ok".to_string(),
                NotificationLevel::Warning,
                Some(first.id),
            )
            .unwrap();

        let state = mux.surface_notification(first.id).unwrap();
        assert_eq!(state.notification, notification);
        assert_eq!(state.level, NotificationLevel::Warning);
        assert!(state.unread);

        mux.select_tab(Some(pane), Some(1), None);
        assert!(mux.surface_notification(first.id).is_some());
        mux.select_tab(Some(pane), Some(0), None);
        assert!(mux.surface_notification(first.id).is_none());
        assert!(mux.surface_notification(second.id).is_none());
    }

    #[test]
    fn notification_to_active_surface_does_not_set_unread() {
        let mux = test_mux();
        let events = mux.subscribe();
        let surface = mux.new_workspace(None, None).unwrap();
        assert_eq!(mux.active_surface(), Some(surface.id));

        let notification = mux
            .post_notification(
                "Build".to_string(),
                "ok".to_string(),
                NotificationLevel::Info,
                Some(surface.id),
            )
            .unwrap();

        assert!(mux.surface_notification(surface.id).is_none());
        assert!(events.try_iter().any(|event| {
            matches!(
                event,
                MuxEvent::Notification(note)
                    if note.notification == notification && note.surface == Some(surface.id)
            )
        }));
    }

    #[test]
    fn notification_ledger_is_bounded_newest_first_and_uses_public_ids() {
        let mux = test_mux();
        let terminal = mux.new_workspace(None, None).unwrap();
        let terminal_id = TerminalPublicId::random().unwrap();
        {
            let mut state = mux.state.lock().unwrap();
            state
                .resource_indexes
                .content_ids
                .insert(terminal.id, ContentPublicId::Terminal(terminal_id.clone()));
        }
        mux.post_notification(
            "attached".into(),
            "terminal".into(),
            NotificationLevel::Info,
            Some(terminal.id),
        )
        .unwrap();
        assert_eq!(mux.resource_notifications(1)[0].terminal_id, Some(terminal_id));

        for index in 0..300 {
            mux.post_notification(
                format!("notice-{index}"),
                String::new(),
                NotificationLevel::Info,
                None,
            )
            .unwrap();
        }
        let notifications = mux.resource_notifications(1_000);
        assert_eq!(notifications.len(), 256);
        assert_eq!(notifications.first().unwrap().title, "notice-299");
        assert_eq!(notifications.last().unwrap().title, "notice-44");
        assert_eq!(
            notifications.iter().map(|notification| &notification.id).collect::<HashSet<_>>().len(),
            256
        );
        assert!(
            notifications.windows(2).all(|pair| pair[0].created_at_ms >= pair[1].created_at_ms)
        );
    }

    fn seed_split_ratio_tree(mux: &Arc<Mux>) -> (PaneId, PaneId, PaneId, SplitId, SplitId) {
        let first = mux.new_workspace(None, None).unwrap();
        let p1 = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let second = mux.split(p1, SplitDir::Right, None).unwrap();
        let p2 = mux.with_state(|state| state.pane_of(second.id).unwrap());
        let third = mux.split(p1, SplitDir::Right, None).unwrap();
        let p3 = mux.with_state(|state| state.pane_of(third.id).unwrap());
        let (root_split, inner_split) = mux.with_state(|state| {
            let Node::Split { id: root, a, .. } = &state.workspaces[0].screens[0].root else {
                panic!("root should be split");
            };
            let Node::Split { id: inner, .. } = a.as_ref() else {
                panic!("first child should be split");
            };
            (*root, *inner)
        });
        (p1, p2, p3, root_split, inner_split)
    }

    fn leaf_spec() -> LayoutSpec {
        LayoutSpec::Leaf(LayoutLeafSpec { cwd: None, command: None })
    }

    fn split_spec(dir: SplitDir, ratio: f32, a: LayoutSpec, b: LayoutSpec) -> LayoutSpec {
        LayoutSpec::Split { dir, ratio, a: Box::new(a), b: Box::new(b) }
    }

    fn node_shape(node: &Node) -> String {
        match node {
            Node::Leaf(_) => "leaf".to_string(),
            Node::Split { dir, ratio, a, b, .. } => {
                let dir = match dir {
                    SplitDir::Right => "right",
                    SplitDir::Down => "down",
                };
                format!("{dir}:{ratio:.2}({}, {})", node_shape(a), node_shape(b))
            }
            Node::Stack { panes, expanded } => format!("stack:{panes:?}:{expanded}"),
        }
    }

    fn spec_shape(spec: &LayoutSpec) -> String {
        match spec {
            LayoutSpec::Leaf(_) => "leaf".to_string(),
            LayoutSpec::Split { dir, ratio, a, b } => {
                let dir = match dir {
                    SplitDir::Right => "right",
                    SplitDir::Down => "down",
                };
                format!(
                    "{dir}:{:.2}({}, {})",
                    clamp_split_ratio(*ratio),
                    spec_shape(a),
                    spec_shape(b)
                )
            }
            LayoutSpec::Stack { pane_count, expanded_index } => {
                format!("stack:{pane_count}:{expanded_index}")
            }
        }
    }

    fn leaf_order(node: &Node) -> Vec<PaneId> {
        let mut ids = Vec::new();
        node.pane_ids(&mut ids);
        ids
    }

    fn screen_root(mux: &Mux, screen: ScreenId) -> Node {
        mux.with_state(|s| {
            s.workspaces
                .iter()
                .flat_map(|ws| ws.screens.iter())
                .find(|candidate| candidate.id == screen)
                .unwrap()
                .root
                .clone()
        })
    }

    #[test]
    fn apply_layout_round_trip_reproduces_tree_shape_and_ratios() {
        let mux = test_mux();
        let spec = split_spec(
            SplitDir::Right,
            0.33,
            leaf_spec(),
            split_spec(SplitDir::Down, 0.67, leaf_spec(), leaf_spec()),
        );
        let first = mux.apply_layout(None, Some("round-trip".into()), &spec, None).unwrap();
        let exported_shape = node_shape(&screen_root(&mux, first.screen));
        mux.with_state(|state| assert_eq!(state.workspaces[0].name, "0"));

        let round_trip_spec = mux.with_state(|s| {
            fn from_node(node: &Node) -> LayoutSpec {
                match node {
                    Node::Leaf(_) => leaf_spec(),
                    Node::Split { dir, ratio, a, b, .. } => {
                        split_spec(*dir, *ratio, from_node(a), from_node(b))
                    }
                    Node::Stack { panes, expanded } => LayoutSpec::Stack {
                        pane_count: panes.len(),
                        expanded_index: panes
                            .iter()
                            .position(|pane| pane == expanded)
                            .expect("valid stack expansion"),
                    },
                }
            }
            from_node(&s.workspaces[0].screens[0].root)
        });
        let second =
            mux.apply_layout(None, Some("round-trip-2".into()), &round_trip_spec, None).unwrap();
        let applied_shape = node_shape(&screen_root(&mux, second.screen));

        assert_eq!(exported_shape, spec_shape(&spec));
        assert_eq!(applied_shape, exported_shape);
        assert_eq!(first.panes.len(), 3);
        assert_eq!(second.panes.len(), 3);
    }

    #[test]
    fn apply_layout_holds_target_workspace_lifecycle_through_commit() {
        let mux = test_mux();
        let target = mux.create_empty_workspace(Some("target".into()), None, None).unwrap();
        let (reserved_tx, reserved_rx) = std::sync::mpsc::sync_channel(1);
        let (release_tx, release_rx) = std::sync::mpsc::sync_channel(1);
        let release_rx = Arc::new(Mutex::new(release_rx));
        *mux.layout_apply_after_workspace_reservation.lock().unwrap() = Some(Arc::new({
            move || {
                reserved_tx.send(()).unwrap();
                release_rx.lock().unwrap().recv().unwrap();
            }
        }));
        let apply = std::thread::spawn({
            let mux = mux.clone();
            move || mux.apply_layout(Some(target.workspace), None, &leaf_spec(), None)
        });
        reserved_rx.recv().unwrap();

        let (close_done_tx, close_done_rx) = std::sync::mpsc::sync_channel(1);
        let close = std::thread::spawn({
            let mux = mux.clone();
            move || {
                close_done_tx
                    .send(mux.close_workspace_at_revision(target.workspace, Some(1)))
                    .unwrap();
            }
        });
        let premature_close = close_done_rx.recv_timeout(Duration::from_millis(250));
        let closed_early = premature_close.is_ok();
        release_tx.send(()).unwrap();
        let applied = apply.join();
        let close_result = match premature_close {
            Ok(result) => result,
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => close_done_rx.recv().unwrap(),
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                panic!("workspace close result channel disconnected")
            }
        };
        close.join().unwrap();
        *mux.layout_apply_after_workspace_reservation.lock().unwrap() = None;

        assert!(!closed_early, "workspace closed before layout commit");
        assert!(applied.unwrap().is_ok());
        assert_eq!(close_result.unwrap(), Some(2));
        mux.shutdown().unwrap();
    }

    #[test]
    fn apply_layout_constructs_stack_with_requested_expansion() {
        let mux = test_mux();
        let applied = mux
            .apply_layout(
                None,
                Some("stack".into()),
                &LayoutSpec::Stack { pane_count: 3, expanded_index: 1 },
                None,
            )
            .unwrap();
        let root = screen_root(&mux, applied.screen);

        assert!(matches!(
            root,
            Node::Stack { ref panes, expanded }
                if panes.len() == 3 && expanded == applied.panes[1].pane
        ));
        mux.with_state(|state| {
            assert_eq!(state.workspaces[0].screens[0].active_pane, applied.panes[1].pane);
        });
    }

    #[test]
    fn pane_neighbor_returns_directional_adjacency() {
        let mux = test_mux();
        let applied = mux
            .apply_layout(
                None,
                None,
                &split_spec(
                    SplitDir::Right,
                    0.5,
                    leaf_spec(),
                    split_spec(SplitDir::Down, 0.5, leaf_spec(), leaf_spec()),
                ),
                None,
            )
            .unwrap();
        let p1 = applied.panes[0].pane;
        let p2 = applied.panes[1].pane;
        let p3 = applied.panes[2].pane;

        assert_eq!(mux.pane_neighbor(p1, Direction::Right).unwrap(), Some(p2));
        assert_eq!(mux.pane_neighbor(p2, Direction::Down).unwrap(), Some(p3));
        assert_eq!(mux.pane_neighbor(p1, Direction::Left).unwrap(), None);
    }

    #[test]
    fn focus_direction_moves_active_pane() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let p1 = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let second = mux.split(p1, SplitDir::Right, None).unwrap();
        let p2 = mux.with_state(|state| state.pane_of(second.id).unwrap());
        assert!(mux.focus_pane(p1));

        assert_eq!(mux.focus_direction(None, Direction::Right).unwrap(), p2);
        mux.with_state(|s| assert_eq!(s.workspaces[0].screens[0].active_pane, p2));
        assert!(mux.focus_direction(None, Direction::Right).is_err());
    }

    #[test]
    fn focus_direction_returns_to_most_recently_focused_adjacent_pane() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let left = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let right = mux.split(left, SplitDir::Right, None).unwrap();
        let top_right = mux.with_state(|state| state.pane_of(right.id).unwrap());
        let bottom = mux.split(top_right, SplitDir::Down, None).unwrap();
        let bottom_right = mux.with_state(|state| state.pane_of(bottom.id).unwrap());

        assert!(mux.focus_pane(top_right));
        assert!(mux.focus_pane(bottom_right));
        assert_eq!(mux.focus_direction(None, Direction::Left).unwrap(), left);
        assert_eq!(mux.focus_direction(None, Direction::Right).unwrap(), bottom_right);
    }

    #[test]
    fn fresh_layout_focus_uses_layout_order_for_unfocused_candidates() {
        let mux = test_mux();
        let applied = mux
            .apply_layout(
                None,
                None,
                &split_spec(
                    SplitDir::Right,
                    0.5,
                    leaf_spec(),
                    split_spec(SplitDir::Down, 0.5, leaf_spec(), leaf_spec()),
                ),
                None,
            )
            .unwrap();

        assert_eq!(mux.focus_direction(None, Direction::Right).unwrap(), applied.panes[1].pane);
    }

    #[test]
    fn selecting_a_tab_in_an_inactive_pane_does_not_change_focus_recency() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let left = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let right_surface = mux.split(left, SplitDir::Right, None).unwrap();
        let right = mux.with_state(|state| state.pane_of(right_surface.id).unwrap());
        assert!(mux.focus_pane(left));
        mux.new_tab(Some(right), None, None).unwrap();
        let before = mux.with_state(|state| state.panes[&right].focused_at);

        mux.select_tab(Some(right), Some(0), None);

        assert_eq!(mux.with_state(|state| state.panes[&right].focused_at), before);
    }

    #[test]
    fn moving_a_tab_to_another_pane_stamps_the_new_focus() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let left = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let extra = mux.new_tab(Some(left), None, None).unwrap();
        let right_surface = mux.split(left, SplitDir::Right, None).unwrap();
        let right = mux.with_state(|state| state.pane_of(right_surface.id).unwrap());
        assert!(mux.focus_pane(left));
        let before = mux.with_state(|state| state.panes[&right].focused_at);

        assert!(mux.move_tab(extra.id, right, 0));

        mux.with_state(|state| {
            assert_eq!(state.active_pane(), Some(right));
            assert!(state.panes[&right].focused_at > before);
        });
    }

    #[test]
    fn swap_pane_exchanges_leaf_positions_and_preserves_surfaces() {
        let mux = test_mux();
        let applied = mux
            .apply_layout(
                None,
                None,
                &split_spec(SplitDir::Right, 0.5, leaf_spec(), leaf_spec()),
                None,
            )
            .unwrap();
        let p1 = applied.panes[0].pane;
        let s1 = applied.panes[0].surface;
        let p2 = applied.panes[1].pane;
        let s2 = applied.panes[1].surface;
        assert_eq!(leaf_order(&screen_root(&mux, applied.screen)), vec![p1, p2]);

        assert!(mux.swap_panes(p1, p2));
        assert_eq!(leaf_order(&screen_root(&mux, applied.screen)), vec![p2, p1]);
        mux.with_state(|s| {
            assert_eq!(s.panes[&p1].tabs, vec![s1]);
            assert_eq!(s.panes[&p2].tabs, vec![s2]);
        });
    }

    #[test]
    fn zoom_pane_toggles_screen_zoom_state() {
        let mux = test_mux();
        let applied = mux
            .apply_layout(
                None,
                None,
                &split_spec(SplitDir::Right, 0.5, leaf_spec(), leaf_spec()),
                None,
            )
            .unwrap();
        let p2 = applied.panes[1].pane;

        let zoomed = mux.zoom_pane(Some(p2), ZoomMode::Toggle).unwrap();
        assert_eq!(zoomed.zoomed_pane, Some(p2));
        mux.with_state(|s| assert_eq!(s.workspaces[0].screens[0].zoomed_pane, Some(p2)));

        let restored = mux.zoom_pane(Some(p2), ZoomMode::Toggle).unwrap();
        assert_eq!(restored.zoomed_pane, None);
        mux.with_state(|s| assert_eq!(s.workspaces[0].screens[0].zoomed_pane, None));
    }

    #[test]
    fn process_info_metadata_is_recorded_for_spawned_surface() {
        let mux = test_mux();
        let cwd = std::env::temp_dir().to_string_lossy().into_owned();
        let applied = mux
            .apply_layout(
                None,
                None,
                &LayoutSpec::Leaf(LayoutLeafSpec {
                    cwd: Some(cwd.clone()),
                    command: Some(vec!["echo".into(), "ok".into()]),
                }),
                None,
            )
            .unwrap();
        let surface = mux.surface(applied.panes[0].surface).unwrap();

        assert_eq!(surface.process_id(), Some(surface.id as u32));
        assert_eq!(surface.spawn_command().as_deref(), Some("echo ok"));
        assert_eq!(surface.spawn_cwd().as_deref(), Some(cwd.as_str()));
    }

    #[test]
    fn split_and_close_collapses_tree() {
        let mux = test_mux();
        let s1 = mux.new_workspace(None, None).unwrap();
        let p1 = mux.with_state(|s| s.pane_of(s1.id).unwrap());
        let s2 = mux.split(p1, SplitDir::Right, None).unwrap();
        let p2 = mux.with_state(|s| s.pane_of(s2.id).unwrap());
        let s3 = mux.split(p2, SplitDir::Down, None).unwrap();
        let p3 = mux.with_state(|s| s.pane_of(s3.id).unwrap());

        mux.with_state(|s| {
            let mut ids = Vec::new();
            s.workspaces[0].screens[0].root.pane_ids(&mut ids);
            assert_eq!(ids, vec![p1, p2, p3]);
        });

        mux.close_pane(p2).unwrap();
        mux.with_state(|s| {
            let mut ids = Vec::new();
            s.workspaces[0].screens[0].root.pane_ids(&mut ids);
            assert_eq!(ids, vec![p1, p3]);
        });

        mux.close_pane(p1).unwrap();
        mux.close_pane(p3).unwrap();
        assert_eq!(mux.surface_count(), 0);
        mux.with_state(|s| {
            assert_eq!(s.workspaces.len(), 1);
            assert!(s.workspaces[0].screens.is_empty());
            assert_eq!(s.workspace_revision, 1);
        });
    }

    #[test]
    fn new_pane_right_wraps_the_screen_in_a_viewport_split() {
        let mux = test_mux();
        let first = mux.new_workspace(None, Some((80, 22))).unwrap();
        let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let second = mux.split(first_pane, SplitDir::Right, Some((38, 22))).unwrap();
        let second_pane = mux.with_state(|state| state.pane_of(second.id).unwrap());

        let appended =
            mux.new_pane_right(second_pane, DEFAULT_VIEWPORT_PANE_WIDTH, Some((51, 22))).unwrap();
        let appended_pane = mux.with_state(|state| state.pane_of(appended.id).unwrap());

        mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            assert_eq!(screen.active_pane, appended_pane);
            assert_eq!(screen.zoomed_pane, None);
            assert_eq!(screen.viewport_splits.len(), 1);
            let Node::Split { id, dir, ratio, a, b } = &screen.root else {
                panic!("viewport pane must wrap the screen root");
            };
            assert_eq!(*dir, SplitDir::Right);
            assert!((*ratio - 0.6).abs() < f32::EPSILON);
            assert!(a.contains(first_pane));
            assert!(a.contains(second_pane));
            assert!(matches!(b.as_ref(), Node::Leaf(pane) if *pane == appended_pane));
            assert_eq!(screen.viewport_splits[id], DEFAULT_VIEWPORT_PANE_WIDTH);

            let layout = layout_screen_with_viewport(
                &screen.root,
                Rect { x: 0, y: 0, width: 80, height: 24 },
                Some(screen.active_pane),
                screen.viewport_base_width.unwrap_or(1.0),
                &screen.viewport_splits,
            );
            assert_eq!(layout.virtual_width, 133);
            assert_eq!(layout.rect_of(first_pane).unwrap().width, 40);
            assert_eq!(layout.rect_of(second_pane).unwrap().width, 40);
            assert_eq!(
                layout.rect_of(appended_pane).unwrap(),
                VirtualRect { x: 80, y: 0, width: 53, height: 24 }
            );
        });
        assert_eq!(mux.pane_neighbor(second_pane, Direction::Right).unwrap(), Some(appended_pane));
        assert_eq!(mux.pane_neighbor(appended_pane, Direction::Left).unwrap(), Some(second_pane));
    }

    #[test]
    fn viewport_neighbor_navigation_remains_adjacent_past_u16_layout_extent() {
        let mux = test_mux();
        let first = mux.new_workspace(None, Some((80, 22))).unwrap();
        let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let mut panes = vec![first_pane];

        for _ in 0..12 {
            let previous = *panes.last().unwrap();
            let surface =
                mux.new_pane_right(previous, DEFAULT_VIEWPORT_PANE_WIDTH, Some((51, 22))).unwrap();
            panes.push(mux.with_state(|state| state.pane_of(surface.id).unwrap()));
        }

        for pair in panes.windows(2) {
            let [left, right] = pair else { unreachable!() };
            assert_eq!(mux.pane_neighbor(*left, Direction::Right).unwrap(), Some(*right));
            assert_eq!(mux.pane_neighbor(*right, Direction::Left).unwrap(), Some(*left));
            assert_eq!(mux.pane_focus_neighbor(*left, Direction::Right).unwrap(), Some(*right));
            assert_eq!(mux.pane_focus_neighbor(*right, Direction::Left).unwrap(), Some(*left));
        }
    }

    #[test]
    fn new_pane_right_rejects_invalid_width_before_spawning() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let surfaces = mux.with_state(|state| state.surfaces.len());

        assert!(mux.new_pane_right(pane, 0.0, None).is_err());
        assert_eq!(mux.with_state(|state| state.surfaces.len()), surfaces);
    }

    #[test]
    fn new_pane_right_discards_spawn_when_target_disappears_before_attachment() {
        let mux = test_mux();
        let first = mux.new_workspace(None, Some((80, 22))).unwrap();
        let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let weak = Arc::downgrade(&mux);
        *mux.viewport_split_after_spawn.lock().unwrap() = Some(Arc::new(move || {
            weak.upgrade().unwrap().close_pane_for_resource_effect(first_pane).unwrap();
        }));

        let error = mux.new_pane_right(first_pane, 0.5, Some((38, 22))).unwrap_err();

        assert_eq!(error.to_string(), "pane creation failed");
        mux.with_state(|state| {
            assert!(state.surfaces.is_empty());
            assert!(state.panes.is_empty());
            assert!(state.workspaces[0].screens.is_empty());
        });
    }

    #[test]
    fn viewport_columns_resize_independently() {
        let mux = test_mux();
        let first = mux.new_workspace(None, Some((80, 22))).unwrap();
        let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let second = mux.split(first_pane, SplitDir::Right, Some((38, 22))).unwrap();
        let second_pane = mux.with_state(|state| state.pane_of(second.id).unwrap());
        let appended =
            mux.new_pane_right(second_pane, DEFAULT_VIEWPORT_PANE_WIDTH, Some((51, 22))).unwrap();
        let appended_pane = mux.with_state(|state| state.pane_of(appended.id).unwrap());

        assert!(mux.set_viewport_pane_width(first_pane, 0.75));
        assert!(mux.set_viewport_pane_width(appended_pane, 0.5));
        assert!(!mux.set_viewport_pane_width(appended_pane, 0.0));

        mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            assert_eq!(screen.viewport_base_width, Some(0.75));
            let appended_split = match screen
                .root
                .viewport_column_owner(appended_pane, &screen.viewport_splits)
                .unwrap()
            {
                ViewportColumn::Split(split) => split,
                ViewportColumn::Base => panic!("appended pane must own a viewport split"),
            };
            assert_eq!(screen.viewport_splits[&appended_split], 0.5);
            let Node::Split { ratio, .. } = &screen.root else {
                panic!("viewport layout must retain its root split");
            };
            assert!((*ratio - 0.6).abs() < f32::EPSILON);

            let layout = layout_screen_with_viewport(
                &screen.root,
                Rect { x: 0, y: 0, width: 80, height: 24 },
                Some(screen.active_pane),
                screen.viewport_base_width.unwrap(),
                &screen.viewport_splits,
            );
            assert_eq!(layout.virtual_width, 100);
            assert_eq!(layout.rect_of(first_pane).unwrap().width, 30);
            assert_eq!(layout.rect_of(second_pane).unwrap().width, 30);
            assert_eq!(
                layout.rect_of(appended_pane).unwrap(),
                VirtualRect { x: 60, y: 0, width: 40, height: 24 }
            );
        });
    }

    #[test]
    fn projected_viewport_split_ratio_resizes_the_authoritative_column() {
        let mux = test_mux();
        let first = mux.new_workspace(None, Some((80, 22))).unwrap();
        let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let appended = mux.new_pane_right(first_pane, 0.5, Some((38, 22))).unwrap();
        let appended_pane = mux.with_state(|state| state.pane_of(appended.id).unwrap());
        let split = mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            match &screen.root {
                Node::Split { id, .. } => *id,
                _ => panic!("viewport layout must expose a compatibility split"),
            }
        });

        let events = mux.subscribe();
        assert!(mux.set_split_ratio_checked(split, 0.5).is_ok());
        assert!(matches!(events.recv().unwrap(), MuxEvent::LayoutChanged(_)));
        let after_change = mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            (screen.layout_revision, screen.layout_undo.len())
        });
        assert!(mux.set_split_ratio_checked(split, 0.5).is_ok());
        assert!(matches!(
            mux.set_split_ratio_checked(split, 0.25),
            Err(LayoutRatioError::UnrepresentableViewportWidth { split: rejected, .. })
                if rejected == split
        ));
        mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            assert_eq!((screen.layout_revision, screen.layout_undo.len()), after_change);
            assert_eq!(screen.viewport_splits[&split], 1.0);
            assert_eq!(
                screen
                    .layout_columns
                    .iter()
                    .find(|column| column.root.contains(appended_pane))
                    .map(|column| column.width),
                Some(1.0)
            );
            assert!(matches!(
                &screen.root,
                Node::Split { id, ratio, .. }
                    if *id == split && (*ratio - 0.5).abs() < f32::EPSILON
            ));
            assert!(state.split_screens.contains_key(&split));
        });
        assert!(events.try_iter().next().is_none());
    }

    fn seed_high_ratio_viewport_projection() -> (Arc<Mux>, PaneId, SplitId) {
        let mux = test_mux();
        let first = mux.new_workspace(None, Some((80, 22))).unwrap();
        let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let middle = mux.new_pane_right(first_pane, 1.0, Some((78, 22))).unwrap();
        let middle_pane = mux.with_state(|state| state.pane_of(middle.id).unwrap());
        let right =
            mux.new_pane_right(middle_pane, MIN_VIEWPORT_PANE_WIDTH, Some((6, 22))).unwrap();
        let right_pane = mux.with_state(|state| state.pane_of(right.id).unwrap());
        let split = mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            let Node::Split { id, ratio, .. } = &screen.root else {
                panic!("three columns should expose a projected root split");
            };
            assert!((*ratio - (2.0 / 2.1)).abs() < f32::EPSILON);
            *id
        });
        (mux, right_pane, split)
    }

    fn assert_high_ratio_projection_resize_applied(
        mux: &Mux,
        expected_width: f32,
        undo_count_before: usize,
    ) {
        mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            assert!(
                (screen.layout_columns[2].width - expected_width).abs() < 1e-6,
                "projected ratio should update authoritative width: {:?}",
                screen.layout_columns
            );
            assert_eq!(screen.layout_undo.len(), undo_count_before + 1);
            assert!(screen.layout_column_projection_is_consistent());
        });
    }

    #[test]
    fn maximum_projected_split_ratio_still_resizes_authoritative_column() {
        let (mux, _right_pane, split) = seed_high_ratio_viewport_projection();
        let expected_width = 2.0 * (1.0 - 0.95) / 0.95;
        let undo_count_before =
            mux.with_state(|state| state.workspaces[0].screens[0].layout_undo.len());
        let events = mux.subscribe();

        assert!(mux.set_split_ratio_checked(split, 0.95).is_ok());

        assert_high_ratio_projection_resize_applied(&mux, expected_width, undo_count_before);
        assert!(matches!(events.try_recv(), Ok(MuxEvent::LayoutChanged(_))));
    }

    #[test]
    fn maximum_pane_addressed_ratio_still_resizes_authoritative_column() {
        let (mux, right_pane, _split) = seed_high_ratio_viewport_projection();
        let expected_width = 2.0 * (1.0 - 0.95) / 0.95;
        let undo_count_before =
            mux.with_state(|state| state.workspaces[0].screens[0].layout_undo.len());
        let events = mux.subscribe();

        assert!(mux.set_ratio_checked(right_pane, SplitDir::Right, 0.95).is_ok());

        assert_high_ratio_projection_resize_applied(&mux, expected_width, undo_count_before);
        assert!(matches!(events.try_recv(), Ok(MuxEvent::TreeChanged)));
        assert!(matches!(events.try_recv(), Ok(MuxEvent::LayoutChanged(_))));
    }

    #[test]
    fn set_ratio_resizes_a_projected_viewport_split() {
        let mux = test_mux();
        let first = mux.new_workspace(None, Some((80, 22))).unwrap();
        let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        mux.new_pane_right(first_pane, 0.5, Some((38, 22))).unwrap();

        assert!(mux.set_ratio_checked(first_pane, SplitDir::Right, 0.5).is_ok());
        mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            let Node::Split { id, ratio, .. } = &screen.root else {
                panic!("viewport layout must expose a compatibility split");
            };
            assert!((*ratio - 0.5).abs() < f32::EPSILON);
            assert_eq!(screen.viewport_splits[id], 1.0);
            assert!(screen.layout_column_projection_is_consistent());
        });
    }

    #[test]
    fn new_pane_right_inserts_after_the_target_viewport_column() {
        let mux = test_mux();
        let first = mux.new_workspace(None, Some((80, 22))).unwrap();
        let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let second = mux.new_pane_right(first_pane, 0.5, Some((38, 22))).unwrap();
        let second_pane = mux.with_state(|state| state.pane_of(second.id).unwrap());
        let middle = mux.new_pane_right(first_pane, 0.5, Some((38, 22))).unwrap();
        let middle_pane = mux.with_state(|state| state.pane_of(middle.id).unwrap());

        mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            let layout = layout_screen_with_viewport(
                &screen.root,
                Rect { x: 0, y: 0, width: 80, height: 24 },
                Some(screen.active_pane),
                screen.viewport_base_width.unwrap(),
                &screen.viewport_splits,
            );
            assert_eq!(
                layout.panes.iter().map(|(pane, _)| *pane).collect::<Vec<_>>(),
                vec![first_pane, middle_pane, second_pane]
            );
            assert_eq!(layout.rect_of(first_pane).unwrap().x, 0);
            assert_eq!(layout.rect_of(middle_pane).unwrap().x, 80);
            assert_eq!(layout.rect_of(second_pane).unwrap().x, 120);
        });
    }

    #[test]
    fn viewport_self_swap_is_a_noop_without_undo_history_or_events() {
        let mux = test_mux();
        let first = mux.new_workspace(None, Some((80, 22))).unwrap();
        let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let right = mux.new_pane_right(first_pane, 0.5, Some((38, 22))).unwrap();
        let right_pane = mux.with_state(|state| state.pane_of(right.id).unwrap());
        let before = mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            (screen.layout_revision, screen.layout_undo.len(), format!("{:?}", screen.root))
        });
        let events = mux.subscribe();

        assert!(!mux.swap_panes(right_pane, right_pane));

        mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            assert_eq!(screen.layout_revision, before.0);
            assert_eq!(screen.layout_undo.len(), before.1);
            assert_eq!(format!("{:?}", screen.root), before.2);
        });
        assert!(events.try_iter().next().is_none());
    }

    #[test]
    fn zellij_new_pane_rebalances_only_the_focused_layout_column() {
        let mux = test_mux();
        let first = mux.new_workspace(None, Some((80, 22))).unwrap();
        let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let right = mux.new_pane_right(first_pane, 0.5, Some((38, 22))).unwrap();
        let right_pane = mux.with_state(|state| state.pane_of(right.id).unwrap());

        let right_added = mux.new_pane(right_pane, Some((38, 10))).unwrap();
        let right_added_pane = mux.with_state(|state| state.pane_of(right_added.id).unwrap());
        mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            assert_eq!(screen.layout_columns.len(), 2);
            assert_eq!(screen.layout_columns[0].root.pane_ids_vec(), vec![first_pane]);
            assert_eq!(
                screen.layout_columns[1].root.pane_ids_vec(),
                vec![right_pane, right_added_pane]
            );
            assert_eq!(
                screen.layout_columns[1].zellij_auto_layout.as_deref(),
                Some([right_pane, right_added_pane].as_slice())
            );
            assert_eq!(screen.viewport_splits.len(), 1);
        });

        let left_added = mux.new_pane(first_pane, Some((38, 10))).unwrap();
        let left_added_pane = mux.with_state(|state| state.pane_of(left_added.id).unwrap());
        mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            assert_eq!(
                screen.layout_columns[0].root.pane_ids_vec(),
                vec![first_pane, left_added_pane]
            );
            assert_eq!(
                screen.layout_columns[1].root.pane_ids_vec(),
                vec![right_pane, right_added_pane]
            );
            assert_eq!(screen.viewport_base_width, Some(1.0));
            assert_eq!(screen.viewport_splits.values().copied().collect::<Vec<_>>(), vec![0.5]);
            assert!(screen.layout_column_projection_is_consistent());
        });
    }

    #[test]
    fn layout_undo_removes_only_the_pane_created_in_the_focused_column() {
        let mux = test_mux();
        let first = mux.new_workspace(None, Some((80, 22))).unwrap();
        let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let right = mux.new_pane_right(first_pane, 0.5, Some((38, 22))).unwrap();
        let right_pane = mux.with_state(|state| state.pane_of(right.id).unwrap());
        let added = mux.new_pane(right_pane, Some((38, 10))).unwrap();
        let added_pane = mux.with_state(|state| state.pane_of(added.id).unwrap());

        let LayoutUndoResult::ConfirmationRequired { revision, closes_panes, .. } =
            mux.undo_layout(added_pane, None, false).unwrap()
        else {
            panic!("new pane undo must require confirmation");
        };
        assert_eq!(closes_panes, vec![added_pane]);
        assert!(matches!(
            mux.undo_layout(added_pane, Some(revision), true).unwrap(),
            LayoutUndoResult::Undone { .. }
        ));

        assert!(mux.surface(added.id).is_none());
        assert!(mux.surface(right.id).is_some());
        mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            assert_eq!(screen.layout_columns.len(), 2);
            assert_eq!(screen.layout_columns[0].root.pane_ids_vec(), vec![first_pane]);
            assert_eq!(screen.layout_columns[1].root.pane_ids_vec(), vec![right_pane]);
            assert!(screen.layout_column_projection_is_consistent());
        });
    }

    #[test]
    fn layout_undo_retires_removed_surface_owner_before_reusing_capacity() {
        let mux = test_mux();
        mux.set_shutdown_owner_capacity_for_test(2);
        let first = mux.new_workspace(None, Some((80, 22))).unwrap();
        let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let added = mux.new_pane(first_pane, Some((80, 10))).unwrap();
        let added_pane = mux.with_state(|state| state.pane_of(added.id).unwrap());

        let LayoutUndoResult::ConfirmationRequired { revision, .. } =
            mux.undo_layout(added_pane, None, false).unwrap()
        else {
            panic!("new pane undo must require confirmation");
        };
        assert!(matches!(
            mux.undo_layout(added_pane, Some(revision), true).unwrap(),
            LayoutUndoResult::Undone { .. }
        ));

        assert!(mux.surface(added.id).is_none());
        assert!(
            mux.shutdown_owners.is_empty(),
            "layout undo retained the removed surface owner after confirmed shutdown"
        );
        let replacement = mux
            .new_pane(first_pane, Some((80, 10)))
            .expect("confirmed undo cleanup must release capacity for a replacement pane");
        assert!(mux.surface(replacement.id).is_some());
    }

    #[test]
    fn layout_undo_confirmation_preview_is_read_only() {
        let mux = test_mux();
        let first = mux.new_workspace(None, Some((80, 22))).unwrap();
        let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let right = mux.new_pane_right(first_pane, 0.5, Some((38, 22))).unwrap();
        let right_pane = mux.with_state(|state| state.pane_of(right.id).unwrap());
        let before = mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            (
                screen.layout_revision,
                format!("{:?}", screen.layout_snapshot()),
                format!("{:?}", screen.layout_undo),
                state.panes[&right_pane].tabs.clone(),
            )
        });

        let first_preview = mux.undo_layout(right_pane, None, false).unwrap();
        let second_preview = mux.undo_layout(right_pane, None, false).unwrap();

        assert_eq!(
            first_preview,
            LayoutUndoResult::ConfirmationRequired {
                screen: mux.with_state(|state| state.workspaces[0].screens[0].id),
                revision: before.0,
                closes_panes: vec![right_pane],
            }
        );
        assert_eq!(second_preview, first_preview);
        mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            assert_eq!(screen.layout_revision, before.0);
            assert_eq!(format!("{:?}", screen.layout_snapshot()), before.1);
            assert_eq!(format!("{:?}", screen.layout_undo), before.2);
            assert_eq!(state.panes[&right_pane].tabs, before.3);
        });
    }

    #[test]
    fn resource_layout_undo_preview_does_not_enter_the_durable_journal() {
        let mux = test_mux();
        let first = mux.new_browser_tab("about:blank#first".into(), None, Some((80, 22))).unwrap();
        let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let right_terminal = mux.new_pane_right(first_pane, 0.5, Some((38, 22))).unwrap();
        let right_pane = mux.with_state(|state| state.pane_of(right_terminal.id).unwrap());
        let right = mux
            .new_browser_tab("about:blank#right".into(), Some(right_pane), Some((38, 22)))
            .unwrap();
        assert!(mux.close_surface(right_terminal.id).unwrap());
        let (selectors, before_screen) = {
            let registry = mux.workspace_registry.lock().unwrap();
            let state = mux.state.lock().unwrap();
            let (workspace, screen) = state.screen_of(right_pane).unwrap();
            (
                crate::ResourceSelectors {
                    machine: Some(registry.machine_id().to_string()),
                    session: Some(registry.session_id().to_string()),
                    workspace: Some(state.workspaces[workspace].public_id.to_string()),
                    screen: Some(state.workspaces[workspace].screens[screen].public_id.to_string()),
                    ..crate::ResourceSelectors::default()
                },
                (
                    state.workspaces[workspace].screens[screen].layout_revision,
                    format!("{:?}", state.workspaces[workspace].screens[screen].layout_snapshot()),
                    format!("{:?}", state.workspaces[workspace].screens[screen].layout_undo),
                ),
            )
        };
        let fields = serde_json::json!({"confirm_close":false}).as_object().unwrap().clone();
        let fingerprint = serde_json::json!({
            "operation":"screen.layout.undo",
            "selectors":selectors,
            "fields":fields,
        });
        let mutation = WorkspaceMutation::new("read-only-undo-preview", "test").unwrap();
        let before_registry =
            mux.workspace_registry.lock().unwrap().resource_topology_snapshot().unwrap();

        let error = mux
            .resource_topology_operation(
                ResourceOperation::ScreenLayoutUndo,
                selectors.clone(),
                fields,
                Some(before_registry.revision),
                &mutation,
            )
            .unwrap_err();

        let preview = error.downcast_ref::<ResourceError>().unwrap();
        assert_eq!(preview.code, "confirmation.required");
        assert_eq!(preview.details["revision"], before_registry.revision.to_string());
        let confirmation_token =
            preview.details["confirmation_token"].as_str().unwrap().to_string();
        assert_eq!(confirmation_token.len(), 64);
        assert!(confirmation_token.bytes().all(|byte| byte.is_ascii_hexdigit()));
        mux.with_state(|state| {
            let (workspace, screen) = state.screen_of(right_pane).unwrap();
            let screen = &state.workspaces[workspace].screens[screen];
            assert_eq!(screen.layout_revision, before_screen.0);
            assert_eq!(format!("{:?}", screen.layout_snapshot()), before_screen.1);
            assert_eq!(format!("{:?}", screen.layout_undo), before_screen.2);
        });
        let registry = mux.workspace_registry.lock().unwrap();
        assert_eq!(registry.resource_topology_snapshot().unwrap(), before_registry);
        assert!(
            registry.resource_events_after(before_registry.revision).unwrap().batches.is_empty()
        );
        assert!(
            registry
                .lookup_resource_effect(&mutation.id, "screen.layout.undo", &fingerprint,)
                .unwrap()
                .is_none()
        );
        drop(registry);

        let missing_token_fields =
            serde_json::json!({"confirm_close":true}).as_object().unwrap().clone();
        let missing_token_fingerprint = serde_json::json!({
            "operation":"screen.layout.undo",
            "selectors":selectors,
            "fields":missing_token_fields,
        });
        let missing_token_mutation =
            WorkspaceMutation::new("missing-token-undo-confirm", "test").unwrap();
        let missing_token = mux
            .resource_topology_operation(
                ResourceOperation::ScreenLayoutUndo,
                selectors.clone(),
                missing_token_fields,
                Some(before_registry.revision),
                &missing_token_mutation,
            )
            .unwrap_err();
        let missing_token = missing_token.downcast_ref::<ResourceError>().unwrap();
        assert_eq!(missing_token.code, "confirmation.required");
        assert_eq!(missing_token.details, preview.details);

        let missing_revision_fields = serde_json::json!({
            "confirm_close":true,
            "confirmation_token":confirmation_token,
        })
        .as_object()
        .unwrap()
        .clone();
        let missing_revision_fingerprint = serde_json::json!({
            "operation":"screen.layout.undo",
            "selectors":selectors,
            "fields":missing_revision_fields,
        });
        let missing_revision_mutation =
            WorkspaceMutation::new("missing-revision-undo-confirm", "test").unwrap();
        let missing_revision = mux
            .resource_topology_operation(
                ResourceOperation::ScreenLayoutUndo,
                selectors.clone(),
                missing_revision_fields,
                None,
                &missing_revision_mutation,
            )
            .unwrap_err();
        let missing_revision = missing_revision.downcast_ref::<ResourceError>().unwrap();
        assert_eq!(missing_revision.code, "confirmation.required");
        assert_eq!(missing_revision.details, preview.details);
        let registry = mux.workspace_registry.lock().unwrap();
        assert_eq!(registry.resource_topology_snapshot().unwrap(), before_registry);
        assert!(
            registry.resource_events_after(before_registry.revision).unwrap().batches.is_empty()
        );
        assert!(
            registry
                .lookup_resource_effect(
                    &missing_token_mutation.id,
                    "screen.layout.undo",
                    &missing_token_fingerprint,
                )
                .unwrap()
                .is_none()
        );
        assert!(
            registry
                .lookup_resource_effect(
                    &missing_revision_mutation.id,
                    "screen.layout.undo",
                    &missing_revision_fingerprint,
                )
                .unwrap()
                .is_none()
        );
        drop(registry);

        let late_tab = mux.new_tab(Some(right_pane), None, Some((38, 22))).unwrap();
        let stale_fields = serde_json::json!({
            "confirm_close":true,
            "confirmation_token":confirmation_token,
        })
        .as_object()
        .unwrap()
        .clone();
        let stale_fingerprint = serde_json::json!({
            "operation":"screen.layout.undo",
            "selectors":selectors,
            "fields":stale_fields,
        });
        let stale_mutation = WorkspaceMutation::new("stale-undo-confirm", "test").unwrap();
        let stale = mux
            .resource_topology_operation(
                ResourceOperation::ScreenLayoutUndo,
                selectors.clone(),
                stale_fields.clone(),
                Some(before_registry.revision),
                &stale_mutation,
            )
            .unwrap_err();
        let refreshed = stale
            .downcast_ref::<ResourceError>()
            .unwrap_or_else(|| panic!("stale confirmation returned an untyped error: {stale:#}"));
        assert_eq!(refreshed.code, "confirmation.required");
        assert_ne!(refreshed.details["confirmation_token"], stale_fields["confirmation_token"]);
        assert!(mux.surface(right.id).is_some());
        assert!(mux.surface(late_tab.id).is_some());
        assert!(
            mux.workspace_registry
                .lock()
                .unwrap()
                .lookup_resource_effect(
                    &stale_mutation.id,
                    "screen.layout.undo",
                    &stale_fingerprint,
                )
                .unwrap()
                .is_none()
        );

        let refreshed_revision =
            refreshed.details["revision"].as_str().unwrap().parse::<u64>().unwrap();
        let confirmed_fields = serde_json::json!({
            "confirm_close":true,
            "confirmation_token":refreshed.details["confirmation_token"],
        })
        .as_object()
        .unwrap()
        .clone();
        let committed = mux
            .resource_topology_operation(
                ResourceOperation::ScreenLayoutUndo,
                selectors,
                confirmed_fields,
                Some(refreshed_revision),
                &WorkspaceMutation::new("fresh-undo-confirm", "test").unwrap(),
            )
            .unwrap();
        assert!(!committed.replayed);
        assert!(mux.surface(right.id).is_none());
        assert!(mux.surface(late_tab.id).is_none());
    }

    #[test]
    fn layout_undo_confirmation_fences_exact_created_pane_tab_membership() {
        let mux = test_mux();
        let first = mux.new_workspace(None, Some((80, 22))).unwrap();
        let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let right = mux.new_pane_right(first_pane, 0.5, Some((38, 22))).unwrap();
        let right_pane = mux.with_state(|state| state.pane_of(right.id).unwrap());

        let LayoutUndoResult::ConfirmationRequired { revision, .. } =
            mux.undo_layout(right_pane, None, false).unwrap()
        else {
            panic!("pane creation undo must require confirmation");
        };
        let late_tab = mux.new_tab(Some(right_pane), None, Some((38, 22))).unwrap();

        let error = mux.undo_layout(right_pane, Some(revision), true).unwrap_err();
        assert!(matches!(
            error.downcast_ref::<LayoutUndoError>(),
            Some(LayoutUndoError::Stale(message))
                if message.contains("layout revision conflict")
        ));
        assert!(mux.surface(right.id).is_some());
        assert!(mux.surface(late_tab.id).is_some());

        let LayoutUndoResult::ConfirmationRequired { revision: refreshed, .. } =
            mux.undo_layout(right_pane, None, false).unwrap()
        else {
            panic!("a fresh preview must capture the new tab membership");
        };
        assert!(refreshed > revision);
        assert!(matches!(
            mux.undo_layout(right_pane, Some(refreshed), true).unwrap(),
            LayoutUndoResult::Undone { .. }
        ));
        assert!(mux.surface(right.id).is_none());
        assert!(mux.surface(late_tab.id).is_none());
    }

    #[test]
    fn layout_undo_confirmation_and_tab_creation_commit_atomically() {
        for _ in 0..16 {
            let mux = test_mux();
            let first = mux.new_workspace(None, Some((80, 22))).unwrap();
            let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
            let right = mux.new_pane_right(first_pane, 0.5, Some((38, 22))).unwrap();
            let right_pane = mux.with_state(|state| state.pane_of(right.id).unwrap());
            let LayoutUndoResult::ConfirmationRequired { revision, .. } =
                mux.undo_layout(right_pane, None, false).unwrap()
            else {
                panic!("pane creation undo must require confirmation");
            };
            let start = Arc::new(std::sync::Barrier::new(3));
            let tab = {
                let mux = mux.clone();
                let start = start.clone();
                std::thread::spawn(move || {
                    start.wait();
                    mux.new_tab(Some(right_pane), None, Some((38, 22)))
                })
            };
            let undo = {
                let mux = mux.clone();
                let start = start.clone();
                std::thread::spawn(move || {
                    start.wait();
                    mux.undo_layout(right_pane, Some(revision), true)
                })
            };
            start.wait();
            let tab = tab.join().unwrap();
            let undo = undo.join().unwrap();

            match (tab, undo) {
                (Ok(tab), Err(error)) => {
                    assert!(matches!(
                        error.downcast_ref::<LayoutUndoError>(),
                        Some(LayoutUndoError::Stale(message))
                            if message.contains("layout revision conflict")
                    ));
                    assert!(mux.surface(right.id).is_some());
                    assert!(mux.surface(tab.id).is_some());
                }
                (Err(_), Ok(LayoutUndoResult::Undone { .. })) => {
                    assert!(mux.surface(right.id).is_none());
                }
                (tab, undo) => {
                    panic!("tab creation and confirmed undo partially committed: {tab:?}, {undo:?}")
                }
            }
        }
    }

    #[test]
    fn layout_undo_public_edge_failures_are_typed() {
        let mux = test_mux();
        let unknown_pane = mux.undo_layout(u64::MAX, None, false).unwrap_err();

        let first = mux.new_workspace(None, Some((80, 22))).unwrap();
        let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let right = mux.new_pane_right(first_pane, 0.5, Some((38, 22))).unwrap();
        let right_pane = mux.with_state(|state| state.pane_of(right.id).unwrap());
        let LayoutUndoResult::ConfirmationRequired { .. } =
            mux.undo_layout(right_pane, None, false).unwrap()
        else {
            panic!("pane creation undo must require confirmation");
        };
        let missing_revision = mux.undo_layout(right_pane, None, true).unwrap_err();

        assert_eq!(
            [
                matches!(
                    unknown_pane.downcast_ref::<LayoutUndoError>(),
                    Some(LayoutUndoError::Stale(_))
                ),
                matches!(
                    missing_revision.downcast_ref::<LayoutUndoError>(),
                    Some(LayoutUndoError::Stale(_))
                ),
            ],
            [true, true],
            "public layout-undo edge failures must preserve their typed error"
        );
    }

    #[test]
    fn layout_undo_coalesces_resize_and_fences_pane_closure() {
        let mux = test_mux();
        let first = mux.new_workspace(None, Some((80, 22))).unwrap();
        let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let right = mux.new_pane_right(first_pane, 0.5, Some((38, 22))).unwrap();
        let right_pane = mux.with_state(|state| state.pane_of(right.id).unwrap());

        assert!(mux.set_viewport_pane_width_in_transaction(right_pane, 0.6, 7, 11));
        mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            assert!(
                screen
                    .layout_snapshot_for_coalescing_change(Some(LayoutMutationKey::Resize {
                        owner: LayoutResizeOwner::ControlClient(7),
                        transaction: 11,
                    }))
                    .is_none(),
                "continuation samples must reuse the transaction's first snapshot"
            );
        });
        assert!(mux.set_viewport_pane_width_in_transaction(right_pane, 0.7, 7, 11));
        assert!(matches!(
            mux.undo_layout(right_pane, None, false).unwrap(),
            LayoutUndoResult::Undone { .. }
        ));
        mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            assert_eq!(screen.layout_columns[1].width, 0.5);
        });

        let LayoutUndoResult::ConfirmationRequired { revision, closes_panes, .. } =
            mux.undo_layout(right_pane, None, false).unwrap()
        else {
            panic!("pane creation undo must require confirmation");
        };
        assert_eq!(closes_panes, vec![right_pane]);
        assert!(
            mux.undo_layout(right_pane, None, true)
                .unwrap_err()
                .to_string()
                .contains("requires the preview revision")
        );
        assert!(
            mux.undo_layout(right_pane, Some(revision.saturating_sub(1)), true)
                .unwrap_err()
                .to_string()
                .contains("revision conflict")
        );
        assert!(mux.surface(right.id).is_some());

        assert!(matches!(
            mux.undo_layout(right_pane, Some(revision), true).unwrap(),
            LayoutUndoResult::Undone { .. }
        ));
        assert!(mux.surface(right.id).is_none());
        mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            assert!(!screen.layout_columns_active());
            assert!(screen.viewport_splits.is_empty());
            assert_eq!(screen.root.pane_ids_vec(), vec![first_pane]);
            assert_eq!(screen.active_pane, first_pane);
            assert!(screen.layout_column_projection_is_consistent());
        });
    }

    #[test]
    fn layout_undo_preserves_focus_when_the_current_pane_survives() {
        let mux = test_mux();
        let first = mux.new_workspace(None, Some((80, 22))).unwrap();
        let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let right = mux.new_pane_right(first_pane, 0.5, Some((38, 22))).unwrap();
        let right_pane = mux.with_state(|state| state.pane_of(right.id).unwrap());

        assert!(mux.focus_pane(first_pane));
        assert!(mux.set_viewport_pane_width(right_pane, 0.7));
        assert!(mux.focus_pane(right_pane));
        assert!(matches!(
            mux.undo_layout(right_pane, None, false).unwrap(),
            LayoutUndoResult::Undone { .. }
        ));

        mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            assert_eq!(screen.active_pane, right_pane);
            assert_eq!(screen.layout_columns[1].width, 0.5);
        });
    }

    #[test]
    fn layout_undo_restores_focus_to_the_restored_zoomed_pane() {
        let mux = test_mux();
        let first = mux.new_workspace(None, Some((80, 22))).unwrap();
        let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let right = mux.split(first_pane, SplitDir::Right, Some((38, 22))).unwrap();
        let right_pane = mux.with_state(|state| state.pane_of(right.id).unwrap());

        assert!(mux.focus_pane(first_pane));
        mux.zoom_pane(Some(first_pane), ZoomMode::On).unwrap();
        mux.zoom_pane(Some(first_pane), ZoomMode::Off).unwrap();
        assert!(mux.focus_pane(right_pane));
        assert!(matches!(
            mux.undo_layout(right_pane, None, false).unwrap(),
            LayoutUndoResult::Undone { .. }
        ));

        mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            assert_eq!(screen.zoomed_pane, Some(first_pane));
            assert_eq!(screen.active_pane, first_pane);
            assert_eq!(state.active_pane(), Some(first_pane));
        });
    }

    #[test]
    fn layout_undo_preserves_inactive_stack_selection() {
        let mux = test_mux();
        let applied = mux
            .apply_layout(
                None,
                None,
                &split_spec(
                    SplitDir::Right,
                    0.5,
                    LayoutSpec::Stack { pane_count: 2, expanded_index: 0 },
                    LayoutSpec::Stack { pane_count: 2, expanded_index: 0 },
                ),
                Some((80, 22)),
            )
            .unwrap();
        let [left_first, left_second, right_first, _right_second] =
            applied.panes.iter().map(|pane| pane.pane).collect::<Vec<_>>()[..]
        else {
            panic!("two two-pane stacks should create four panes");
        };
        {
            let mut state = mux.state.lock().unwrap();
            let screen = &mut state.workspaces[0].screens[0];
            let root = std::mem::replace(&mut screen.root, Node::Leaf(0));
            let Node::Split { id, a, b, .. } = root else {
                panic!("test layout should have two stack branches");
            };
            screen.layout_columns = vec![
                LayoutColumn { id: mux.next_id(), width: 1.0, root: *a, zellij_auto_layout: None },
                LayoutColumn { id, width: 0.5, root: *b, zellij_auto_layout: None },
            ];
            screen.sync_layout_column_projection();
            Mux::rebuild_split_screen_index(&mut state);
        }
        mux.commit_ordinary_full_resource_projection(
            "test.viewport_stack.prepare",
            serde_json::json!({}),
        )
        .unwrap();

        assert!(mux.focus_pane(right_first));
        assert!(mux.set_viewport_pane_width(right_first, 0.7));
        assert!(mux.focus_pane(left_second));
        assert!(mux.focus_pane(right_first));
        assert!(matches!(
            mux.undo_layout(right_first, None, false).unwrap(),
            LayoutUndoResult::Undone { .. }
        ));

        mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            assert_eq!(screen.active_pane, right_first);
            assert!(matches!(
                &screen.layout_columns[0].root,
                Node::Stack { expanded, .. } if *expanded == left_second
            ));
            assert!(!matches!(
                &screen.layout_columns[0].root,
                Node::Stack { expanded, .. } if *expanded == left_first
            ));
            assert!(matches!(
                &screen.root,
                Node::Split { a, .. }
                    if matches!(
                        a.as_ref(),
                        Node::Stack { expanded, .. } if *expanded == left_second
                    )
            ));
            assert!(screen.layout_column_projection_is_consistent());
        });
    }

    #[test]
    fn layout_undo_coalesces_every_target_in_one_resize_transaction() {
        let mux = test_mux();
        let first = mux.new_workspace(None, Some((80, 22))).unwrap();
        let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let right = mux.new_pane_right(first_pane, 0.5, Some((38, 22))).unwrap();
        let right_pane = mux.with_state(|state| state.pane_of(right.id).unwrap());
        let bottom = mux.split(right_pane, SplitDir::Down, Some((38, 10))).unwrap();
        let bottom_pane = mux.with_state(|state| state.pane_of(bottom.id).unwrap());
        let (split, initial_ratio, initial_undo_len) = mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            let Node::Split { id, ratio, .. } = &screen.layout_columns[1].root else {
                panic!("right viewport column must contain the vertical split");
            };
            (*id, *ratio, screen.layout_undo.len())
        });

        assert!(mux.set_viewport_pane_width_in_transaction(right_pane, 0.7, 9, 41));
        assert!(mux.set_split_ratio_in_transaction_checked(split, 0.7, 9, 41).is_ok());
        mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            assert_eq!(screen.layout_undo.len(), initial_undo_len + 1);
        });

        assert!(matches!(
            mux.undo_layout(bottom_pane, None, false).unwrap(),
            LayoutUndoResult::Undone { .. }
        ));
        mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            assert_eq!(screen.layout_columns[1].width, 0.5);
            let Node::Split { ratio, .. } = &screen.layout_columns[1].root else {
                panic!("right viewport column must retain the vertical split");
            };
            assert!((*ratio - initial_ratio).abs() < f32::EPSILON);
            assert_eq!(screen.layout_undo.len(), initial_undo_len);
        });
    }

    #[test]
    fn layout_undo_separates_resize_transactions_and_clients() {
        let mux = test_mux();
        let first = mux.new_workspace(None, Some((80, 22))).unwrap();
        let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let right = mux.new_pane_right(first_pane, 0.5, Some((38, 22))).unwrap();
        let right_pane = mux.with_state(|state| state.pane_of(right.id).unwrap());

        assert!(mux.set_viewport_pane_width_in_transaction(right_pane, 0.6, 1, 1));
        assert!(mux.set_viewport_pane_width_in_transaction(right_pane, 0.7, 1, 1));
        assert!(mux.set_viewport_pane_width_in_transaction(right_pane, 0.8, 1, 2));
        assert!(mux.set_viewport_pane_width_in_transaction(right_pane, 0.65, 2, 2));
        assert!(matches!(
            mux.undo_layout(right_pane, None, false).unwrap(),
            LayoutUndoResult::Undone { .. }
        ));
        mux.with_state(|state| {
            assert_eq!(state.workspaces[0].screens[0].layout_columns[1].width, 0.8);
        });

        assert!(matches!(
            mux.undo_layout(right_pane, None, false).unwrap(),
            LayoutUndoResult::Undone { .. }
        ));
        mux.with_state(|state| {
            assert_eq!(state.workspaces[0].screens[0].layout_columns[1].width, 0.7);
        });

        assert!(matches!(
            mux.undo_layout(right_pane, None, false).unwrap(),
            LayoutUndoResult::Undone { .. }
        ));
        mux.with_state(|state| {
            assert_eq!(state.workspaces[0].screens[0].layout_columns[1].width, 0.5);
        });
    }

    #[test]
    fn layout_undo_separates_in_process_and_control_resize_owners_with_same_ids() {
        let mux = test_mux();
        let first = mux.new_workspace(None, Some((80, 22))).unwrap();
        let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let right = mux.new_pane_right(first_pane, 0.5, Some((38, 22))).unwrap();
        let right_pane = mux.with_state(|state| state.pane_of(right.id).unwrap());

        // These model independent in-process and control-client entrypoints
        // that happen to allocate the same numeric owner and transaction ids.
        assert!(
            mux.set_viewport_pane_width_in_process_transaction_checked(right_pane, 0.6, 1, 1)
                .is_ok()
        );
        assert!(mux.set_viewport_pane_width_in_transaction(right_pane, 0.7, 1, 1));

        assert!(matches!(
            mux.undo_layout(right_pane, None, false).unwrap(),
            LayoutUndoResult::Undone { .. }
        ));
        mux.with_state(|state| {
            assert_eq!(state.workspaces[0].screens[0].layout_columns[1].width, 0.6);
        });

        assert!(matches!(
            mux.undo_layout(right_pane, None, false).unwrap(),
            LayoutUndoResult::Undone { .. }
        ));
        mux.with_state(|state| {
            assert_eq!(state.workspaces[0].screens[0].layout_columns[1].width, 0.5);
        });
    }

    #[test]
    fn in_process_resize_owner_allocation_is_mux_scoped() {
        let first = test_mux();
        assert_eq!(first.allocate_in_process_resize_owner(), 1);
        assert_eq!(first.allocate_in_process_resize_owner(), 2);

        let second = test_mux();
        assert_eq!(second.allocate_in_process_resize_owner(), 1);
    }

    #[test]
    fn layout_undo_separates_a_new_resize_from_pre_undo_history() {
        let mux = test_mux();
        let first = mux.new_workspace(None, Some((80, 22))).unwrap();
        let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let right = mux.new_pane_right(first_pane, 0.5, Some((38, 22))).unwrap();
        let right_pane = mux.with_state(|state| state.pane_of(right.id).unwrap());

        assert!(mux.set_viewport_pane_width(right_pane, 0.6));
        assert!(mux.set_viewport_pane_width(first_pane, 0.9));
        assert!(matches!(
            mux.undo_layout(first_pane, None, false).unwrap(),
            LayoutUndoResult::Undone { .. }
        ));

        assert!(mux.set_viewport_pane_width(right_pane, 0.7));
        assert!(matches!(
            mux.undo_layout(right_pane, None, false).unwrap(),
            LayoutUndoResult::Undone { .. }
        ));
        mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            assert_eq!(screen.layout_columns[0].width, 1.0);
            assert_eq!(screen.layout_columns[1].width, 0.6);
        });
    }

    #[test]
    fn closing_a_pane_invalidates_layout_undo_history() {
        let mux = test_mux();
        let first = mux.new_workspace(None, Some((80, 22))).unwrap();
        let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let right = mux.new_pane_right(first_pane, 0.5, Some((38, 22))).unwrap();
        let right_pane = mux.with_state(|state| state.pane_of(right.id).unwrap());

        assert!(mux.close_pane(right_pane).unwrap());
        let error = mux.undo_layout(first_pane, None, false).unwrap_err();

        assert_eq!(error.to_string(), "no layout change to undo");
        assert!(mux.surface(right.id).is_none());
        mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            assert!(!screen.layout_columns_active());
            assert!(screen.layout_column_projection_is_consistent());
        });
    }

    #[test]
    fn closing_the_base_viewport_column_preserves_the_promoted_width() {
        let mux = test_mux();
        let first = mux.new_workspace(None, Some((80, 22))).unwrap();
        let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let middle = mux.new_pane_right(first_pane, 0.5, Some((38, 22))).unwrap();
        let middle_pane = mux.with_state(|state| state.pane_of(middle.id).unwrap());
        let right = mux.new_pane_right(middle_pane, 0.4, Some((30, 22))).unwrap();
        let right_pane = mux.with_state(|state| state.pane_of(right.id).unwrap());
        assert!(mux.set_viewport_pane_width(first_pane, 0.75));

        assert!(mux.close_pane(first_pane).unwrap());

        mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            assert_eq!(screen.viewport_base_width, Some(0.5));
            assert_eq!(
                screen.root.viewport_column_owner(middle_pane, &screen.viewport_splits),
                Some(ViewportColumn::Base)
            );
            let ViewportColumn::Split(right_split) =
                screen.root.viewport_column_owner(right_pane, &screen.viewport_splits).unwrap()
            else {
                panic!("right pane must remain an appended column");
            };
            assert_eq!(screen.viewport_splits[&right_split], 0.4);
            let Node::Split { ratio, .. } = &screen.root else {
                panic!("two viewport columns must retain one split");
            };
            assert!((*ratio - (0.5 / 0.9)).abs() < 0.0001);
        });
    }

    #[test]
    fn closing_a_middle_viewport_column_recomputes_fallback_ratios() {
        let mux = test_mux();
        let first = mux.new_workspace(None, Some((80, 22))).unwrap();
        let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let middle = mux.new_pane_right(first_pane, 0.5, Some((38, 22))).unwrap();
        let middle_pane = mux.with_state(|state| state.pane_of(middle.id).unwrap());
        let right = mux.new_pane_right(middle_pane, 0.4, Some((30, 22))).unwrap();
        let right_pane = mux.with_state(|state| state.pane_of(right.id).unwrap());
        assert!(mux.set_viewport_pane_width(first_pane, 0.75));

        assert!(mux.close_pane(middle_pane).unwrap());

        mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            assert_eq!(screen.viewport_base_width, Some(0.75));
            let ViewportColumn::Split(right_split) =
                screen.root.viewport_column_owner(right_pane, &screen.viewport_splits).unwrap()
            else {
                panic!("right pane must remain appended");
            };
            assert_eq!(screen.viewport_splits.len(), 1);
            assert_eq!(screen.viewport_splits[&right_split], 0.4);
            let Node::Split { ratio, .. } = &screen.root else {
                panic!("two viewport columns must retain one split");
            };
            assert!((*ratio - (0.75 / 1.15)).abs() < 0.0001);
        });
    }

    #[cfg(unix)]
    #[test]
    fn discard_spawned_restores_unbound_running_terminal_when_registry_close_fails() {
        const TERMINAL: &str = "00000000000040008000000000000012";
        const INCARNATION: &str = "10000000000040008000000000000012";
        let mux = test_mux();
        let workspace = mux
            .create_empty_workspace(None, Some("018f6e21-7b70-7e70-8000-000000001012".into()), None)
            .unwrap();
        let surface =
            insert_running_terminal_identity_surface(&mux, TERMINAL, INCARNATION, &workspace.key);
        {
            let mut state = mux.state.lock().unwrap();
            let (removed, split_index_dirty) = remove_surface(&mux, &mut state, surface.id);
            if split_index_dirty {
                Mux::rebuild_split_screen_index(&mut state);
            }
            insert_surface_checked(
                &mux,
                &mut state,
                removed.expect("seeded terminal is removable from topology"),
            )
            .unwrap();
        }
        assert_eq!(mux.with_state(|state| state.pane_of(surface.id)), None);
        let events = mux.subscribe();
        mux.workspace_registry.lock().unwrap().set_terminal_close_failure(true).unwrap();

        mux.discard_spawned(vec![surface.clone()]);

        let restored = mux
            .with_state(|state| state.pane_of(surface.id))
            .expect("failed close must project the terminal back into reachable topology");
        assert_eq!(
            mux.workspace_registry
                .lock()
                .unwrap()
                .terminal_record(TERMINAL)
                .unwrap()
                .unwrap()
                .lifecycle,
            TerminalLifecycle::Running
        );
        assert!(events.try_iter().any(|event| {
            matches!(event, MuxEvent::Status(message)
                if message.contains("could not atomically close discarded terminals"))
        }));

        mux.workspace_registry.lock().unwrap().set_terminal_close_failure(false).unwrap();
        assert!(mux.close_pane_for_resource_effect(restored).unwrap());
    }

    #[cfg(unix)]
    #[test]
    fn close_pane_reports_registry_failure_without_mutating_topology() {
        const TERMINAL: &str = "00000000000040008000000000000010";
        const INCARNATION: &str = "10000000000040008000000000000010";
        let mux = test_mux();
        let workspace = mux
            .create_empty_workspace(None, Some("018f6e21-7b70-7e70-8000-000000001002".into()), None)
            .unwrap();
        let surface =
            insert_running_terminal_identity_surface(&mux, TERMINAL, INCARNATION, &workspace.key);
        let pane = mux.with_state(|state| state.pane_of(surface.id).unwrap());
        let events = mux.subscribe();
        mux.workspace_registry.lock().unwrap().set_terminal_close_failure(true).unwrap();

        let error = mux.close_pane(pane).unwrap_err();
        assert!(error.to_string().contains("close pane"));
        assert!(format!("{error:#}").contains("forced terminal close failure"));
        assert_eq!(mux.with_state(|state| state.pane_of(surface.id)), Some(pane));
        assert!(mux.surface(surface.id).is_some());
        assert_eq!(
            mux.workspace_registry
                .lock()
                .unwrap()
                .terminal_record(TERMINAL)
                .unwrap()
                .unwrap()
                .lifecycle,
            TerminalLifecycle::Running
        );
        assert!(events.recv_timeout(Duration::from_millis(25)).is_err());

        mux.workspace_registry.lock().unwrap().set_terminal_close_failure(false).unwrap();
        assert!(mux.close_pane(pane).unwrap());
        assert!(mux.surface(surface.id).is_none());
        assert_eq!(
            mux.workspace_registry
                .lock()
                .unwrap()
                .terminal_record(TERMINAL)
                .unwrap()
                .unwrap()
                .lifecycle,
            TerminalLifecycle::Tombstoned
        );
    }

    #[cfg(unix)]
    #[test]
    fn close_screen_reports_registry_failure_without_mutating_topology() {
        const TERMINAL: &str = "00000000000040008000000000000011";
        const INCARNATION: &str = "10000000000040008000000000000011";
        let mux = test_mux();
        let workspace = mux
            .create_empty_workspace(None, Some("018f6e21-7b70-7e70-8000-000000001003".into()), None)
            .unwrap();
        let surface =
            insert_running_terminal_identity_surface(&mux, TERMINAL, INCARNATION, &workspace.key);
        let screen = mux.with_state(|state| surface_screen_id(state, surface.id).unwrap());
        mux.workspace_registry.lock().unwrap().set_terminal_close_failure(true).unwrap();

        let error = mux.close_screen(screen).unwrap_err();
        assert!(error.to_string().contains("close screen"));
        assert!(format!("{error:#}").contains("forced terminal close failure"));
        assert_eq!(mux.with_state(|state| surface_screen_id(state, surface.id)), Some(screen));
        assert!(mux.surface(surface.id).is_some());
        assert_eq!(
            mux.workspace_registry
                .lock()
                .unwrap()
                .terminal_record(TERMINAL)
                .unwrap()
                .unwrap()
                .lifecycle,
            TerminalLifecycle::Running
        );

        mux.workspace_registry.lock().unwrap().set_terminal_close_failure(false).unwrap();
        assert!(mux.close_screen(screen).unwrap());
        assert!(mux.surface(surface.id).is_none());
        assert_eq!(
            mux.workspace_registry
                .lock()
                .unwrap()
                .terminal_record(TERMINAL)
                .unwrap()
                .unwrap()
                .lifecycle,
            TerminalLifecycle::Tombstoned
        );
    }

    #[test]
    fn zellij_new_pane_uses_creation_order_after_manual_split() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let p1 = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let second = mux.new_pane(p1, None).unwrap();
        let p2 = mux.with_state(|state| state.pane_of(second.id).unwrap());
        let third = mux.split(p1, SplitDir::Down, None).unwrap();
        let p3 = mux.with_state(|state| state.pane_of(third.id).unwrap());
        let fourth = mux.new_pane(p3, None).unwrap();
        let p4 = mux.with_state(|state| state.pane_of(fourth.id).unwrap());

        mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            let mut order = Vec::new();
            screen.root.pane_ids(&mut order);
            assert_eq!(order, vec![p1, p2, p3, p4]);
            assert_eq!(screen.zellij_auto_layout.as_deref(), Some(order.as_slice()));
        });
    }

    #[test]
    fn failed_new_pane_attachment_retains_shutdown_ownership() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let target = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let (spawned_tx, spawned_rx) = std::sync::mpsc::sync_channel(1);
        let (release_tx, release_rx) = std::sync::mpsc::sync_channel(1);
        let release_rx = Arc::new(Mutex::new(release_rx));
        *mux.new_pane_after_spawn.lock().unwrap() = Some(Arc::new({
            move |surface| {
                surface.set_server_shutdown_failure_for_test(true);
                spawned_tx.send(surface).unwrap();
                release_rx.lock().unwrap().recv().unwrap();
            }
        }));

        let create = std::thread::spawn({
            let mux = mux.clone();
            move || mux.new_pane(target, None)
        });
        let abandoned = spawned_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(mux.close_pane(target).unwrap());
        release_tx.send(()).unwrap();

        let error = create.join().unwrap().unwrap_err();
        assert!(error.to_string().contains("not found"));
        assert!(mux.surface(abandoned.id).is_none());
        assert_eq!(
            mux.shutdown_owners.len(),
            1,
            "failed pane attachment discarded its process owner instead of staging a retry"
        );

        *mux.new_pane_after_spawn.lock().unwrap() = None;
        abandoned.set_server_shutdown_failure_for_test(false);
        let _ = mux.close_all_surfaces_for_shutdown();
        assert!(mux.shutdown_owners.is_empty());
    }

    #[test]
    fn zellij_new_pane_exits_zoom_before_focusing_the_new_pane() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        mux.zoom_pane(Some(first_pane), ZoomMode::On).unwrap();

        let new_surface = mux.new_pane(first_pane, None).unwrap();
        let new_pane = mux.with_state(|state| state.pane_of(new_surface.id).unwrap());

        mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            assert_eq!(screen.active_pane, new_pane);
            assert_eq!(screen.zoomed_pane, None);
        });
    }

    #[test]
    fn zellij_new_pane_emits_pane_added_delta_and_layout_change() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let (workspace, screen, first_pane) = mux.with_state(|state| {
            let workspace = &state.workspaces[0];
            let screen = &workspace.screens[0];
            (workspace.id, screen.id, state.pane_of(first.id).unwrap())
        });
        let events = mux.subscribe();

        let added = mux.new_pane(first_pane, None).unwrap();
        let added_pane = mux.with_state(|state| state.pane_of(added.id).unwrap());

        let deadline = Instant::now() + Duration::from_secs(1);
        let mut saw_added = false;
        loop {
            let remaining = deadline.saturating_duration_since(Instant::now());
            match events.recv_timeout(remaining).expect("pane creation events arrive") {
                MuxEvent::TreeDelta(TreeDelta {
                    kind: TreeDeltaKind::PaneAdded,
                    workspace: event_workspace,
                    screen: Some(event_screen),
                    pane: Some(event_pane),
                    surface: None,
                    index: Some(1),
                    ..
                }) if event_workspace == workspace
                    && event_screen == screen
                    && event_pane == added_pane =>
                {
                    saw_added = true;
                }
                MuxEvent::LayoutChanged(event_screen) if saw_added && event_screen == screen => {
                    break;
                }
                MuxEvent::LayoutChanged(_) if !saw_added => {
                    panic!("layout invalidation arrived before the pane-added delta")
                }
                _ => {}
            }
        }
        assert!(events.try_iter().all(|event| !matches!(event, MuxEvent::TreeChanged)));
    }

    #[test]
    fn closing_zellij_pane_reapplies_layout_for_remaining_count() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let mut surfaces = vec![first];
        let mut active = mux.with_state(|state| state.pane_of(surfaces[0].id).unwrap());
        for _ in 0..4 {
            let surface = mux.new_pane(active, None).unwrap();
            active = mux.with_state(|state| state.pane_of(surface.id).unwrap());
            surfaces.push(surface);
        }

        mux.close_surface(surfaces[0].id).unwrap();
        mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            let order = screen.zellij_auto_layout.as_ref().unwrap();
            assert_eq!(order.len(), 4);
            let layout = layout_screen(
                &screen.root,
                Rect { x: 0, y: 0, width: 200, height: 40 },
                Some(screen.active_pane),
            );
            assert_eq!(layout.rect_of(order[0]).unwrap().height, 40);
            let right_heights = order[1..]
                .iter()
                .map(|pane| layout.rect_of(*pane).unwrap().height)
                .collect::<Vec<_>>();
            assert_eq!(right_heights, vec![13, 14, 13]);
        });
    }

    #[test]
    fn closing_zellij_stack_pane_keeps_active_pane_expanded() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let mut surfaces = vec![first];
        let mut active = mux.with_state(|state| state.pane_of(surfaces[0].id).unwrap());
        for _ in 1..14 {
            let surface = mux.new_pane(active, None).unwrap();
            active = mux.with_state(|state| state.pane_of(surface.id).unwrap());
            surfaces.push(surface);
        }
        let leading_pane = mux.with_state(|state| state.pane_of(surfaces[0].id).unwrap());
        let active_stack_pane = mux.with_state(|state| state.pane_of(surfaces[2].id).unwrap());
        assert!(mux.focus_pane(active_stack_pane));

        mux.close_surface(surfaces[1].id).unwrap();
        mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            assert_eq!(screen.active_pane, active_stack_pane);
            assert!(matches!(
                &screen.root,
                Node::Split { dir: SplitDir::Right, a, b, .. }
                    if matches!(a.as_ref(), Node::Leaf(pane) if *pane == leading_pane)
                        && matches!(b.as_ref(), Node::Stack { panes, .. } if panes.contains(&active_stack_pane))
            ));
            let layout = layout_screen(
                &screen.root,
                Rect { x: 0, y: 0, width: 80, height: 40 },
                Some(screen.active_pane),
            );
            assert!(!layout.stacked_headers.contains(&active_stack_pane));
            assert!(layout.rect_of(active_stack_pane).unwrap().height > 1);
        });
    }

    #[test]
    fn rebuilding_zellij_layout_preserves_stack_expansion_while_focus_is_elsewhere() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let mut surfaces = vec![first];
        let mut active = mux.with_state(|state| state.pane_of(surfaces[0].id).unwrap());
        for _ in 1..14 {
            let surface = mux.new_pane(active, None).unwrap();
            active = mux.with_state(|state| state.pane_of(surface.id).unwrap());
            surfaces.push(surface);
        }
        let leading_pane = mux.with_state(|state| state.pane_of(surfaces[0].id).unwrap());
        let expanded_stack_pane = mux.with_state(|state| state.pane_of(surfaces[2].id).unwrap());
        assert!(mux.focus_pane(expanded_stack_pane));
        assert!(mux.focus_pane(leading_pane));

        mux.close_surface(surfaces[1].id).unwrap();
        mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            let layout = layout_screen(
                &screen.root,
                Rect { x: 0, y: 0, width: 80, height: 40 },
                Some(screen.active_pane),
            );
            assert!(!layout.stacked_headers.contains(&expanded_stack_pane));
            assert!(layout.rect_of(expanded_stack_pane).unwrap().height > 1);
        });
    }

    #[test]
    fn moving_zellij_stack_pane_keeps_target_pane_expanded() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let mut surfaces = vec![first];
        let mut active = mux.with_state(|state| state.pane_of(surfaces[0].id).unwrap());
        for _ in 1..14 {
            let surface = mux.new_pane(active, None).unwrap();
            active = mux.with_state(|state| state.pane_of(surface.id).unwrap());
            surfaces.push(surface);
        }
        let leading_pane = mux.with_state(|state| state.pane_of(surfaces[0].id).unwrap());
        let target = mux.with_state(|state| state.pane_of(surfaces[2].id).unwrap());
        let events = mux.subscribe();

        assert!(mux.move_tab(surfaces[1].id, target, 0));
        mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            assert_eq!(screen.active_pane, target);
            assert!(matches!(
                &screen.root,
                Node::Split { dir: SplitDir::Right, a, b, .. }
                    if matches!(a.as_ref(), Node::Leaf(pane) if *pane == leading_pane)
                        && matches!(b.as_ref(), Node::Stack { panes, .. } if panes.contains(&target))
            ));
            let layout = layout_screen(
                &screen.root,
                Rect { x: 0, y: 0, width: 80, height: 40 },
                Some(screen.active_pane),
            );
            assert!(!layout.stacked_headers.contains(&target));
            assert!(layout.rect_of(target).unwrap().height > 1);
        });
        assert!(events.try_iter().any(|event| matches!(event, MuxEvent::LayoutChanged(_))));
    }

    #[test]
    fn swapping_zellij_stack_panes_keeps_active_pane_expanded() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let mut active = first_pane;
        for _ in 1..13 {
            let surface = mux.new_pane(active, None).unwrap();
            active = mux.with_state(|state| state.pane_of(surface.id).unwrap());
        }

        assert!(mux.swap_panes(active, first_pane));
        mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            assert_eq!(screen.active_pane, active);
            assert!(screen.zellij_auto_layout.is_none());
            let layout = layout_screen(
                &screen.root,
                Rect { x: 0, y: 0, width: 80, height: 40 },
                Some(screen.active_pane),
            );
            assert!(!layout.stacked_headers.contains(&active));
            assert!(layout.rect_of(active).unwrap().height > 1);
        });
    }

    #[test]
    fn closing_active_pane_in_damaged_stack_expands_replacement() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let mut active_surface = first;
        let mut active = first_pane;
        for _ in 1..14 {
            active_surface = mux.new_pane(active, None).unwrap();
            active = mux.with_state(|state| state.pane_of(active_surface.id).unwrap());
        }
        assert!(mux.swap_panes(active, first_pane));

        mux.close_surface(active_surface.id).unwrap();
        mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            assert!(screen.zellij_auto_layout.is_none());
            let layout = layout_screen(
                &screen.root,
                Rect { x: 0, y: 0, width: 80, height: 40 },
                Some(screen.active_pane),
            );
            assert!(!layout.stacked_headers.contains(&screen.active_pane));
            assert!(layout.rect_of(screen.active_pane).unwrap().height > 1);
        });
    }

    #[test]
    fn focusing_zellij_stack_header_expands_that_pane() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let mut active = mux.with_state(|state| state.pane_of(first.id).unwrap());
        for _ in 1..13 {
            let surface = mux.new_pane(active, None).unwrap();
            active = mux.with_state(|state| state.pane_of(surface.id).unwrap());
        }
        let stack_pane = mux.with_state(|state| {
            state.workspaces[0].screens[0].zellij_auto_layout.as_ref().unwrap()[1]
        });

        assert!(mux.focus_pane(stack_pane));
        mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            assert_eq!(screen.active_pane, stack_pane);
            assert!(matches!(
                &screen.root,
                Node::Split { dir: SplitDir::Right, b, .. }
                    if matches!(b.as_ref(), Node::Stack { panes, .. } if panes.contains(&stack_pane))
            ));
            let layout = layout_screen(
                &screen.root,
                Rect { x: 0, y: 0, width: 80, height: 40 },
                Some(screen.active_pane),
            );
            assert!(!layout.stacked_headers.contains(&stack_pane));
            assert!(layout.rect_of(stack_pane).unwrap().height > 1);
        });
    }

    #[test]
    fn focusing_outside_a_stack_emits_layout_changed() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let mut active = first_pane;
        for _ in 1..13 {
            let surface = mux.new_pane(active, None).unwrap();
            active = mux.with_state(|state| state.pane_of(surface.id).unwrap());
        }
        let stack_pane = mux.with_state(|state| {
            state.workspaces[0].screens[0].zellij_auto_layout.as_ref().unwrap()[1]
        });
        let outside = mux.split(active, SplitDir::Right, None).unwrap();
        let outside_pane = mux.with_state(|state| state.pane_of(outside.id).unwrap());
        assert!(mux.focus_pane(stack_pane));
        let events = mux.subscribe();

        assert!(mux.focus_pane(outside_pane));
        mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            let layout = layout_screen(
                &screen.root,
                Rect { x: 0, y: 0, width: 80, height: 40 },
                Some(screen.active_pane),
            );
            assert!(!layout.stacked_headers.contains(&stack_pane));
            assert!(layout.rect_of(stack_pane).unwrap().height > 1);
        });
        let invalidations = events
            .try_iter()
            .filter(|event| matches!(event, MuxEvent::TreeChanged | MuxEvent::LayoutChanged(_)))
            .collect::<Vec<_>>();
        assert_eq!(invalidations.len(), 1);
        assert!(matches!(invalidations[0], MuxEvent::LayoutChanged(_)));
    }

    #[test]
    fn directional_split_of_zellij_stack_preserves_requested_direction() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let mut active = first_pane;
        for _ in 1..13 {
            let surface = mux.new_pane(active, None).unwrap();
            active = mux.with_state(|state| state.pane_of(surface.id).unwrap());
        }

        let split = mux.split(active, SplitDir::Right, None).unwrap();
        let split_pane = mux.with_state(|state| state.pane_of(split.id).unwrap());
        mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            assert!(matches!(
                &screen.root,
                Node::Split { dir: SplitDir::Right, a, b, .. }
                    if matches!(a.as_ref(), Node::Leaf(pane) if *pane == first_pane)
                        && matches!(
                            b.as_ref(),
                            Node::Split { dir: SplitDir::Right, a, b, .. }
                                if matches!(a.as_ref(), Node::Stack { .. })
                                    && matches!(b.as_ref(), Node::Leaf(pane) if *pane == split_pane)
                        )
            ));
            assert!(screen.zellij_auto_layout.is_none());
        });
    }

    #[test]
    fn splitting_a_collapsed_stack_member_expands_the_target_side() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let mut active = first_pane;
        for _ in 1..13 {
            let surface = mux.new_pane(active, None).unwrap();
            active = mux.with_state(|state| state.pane_of(surface.id).unwrap());
        }
        let target = mux.with_state(|state| {
            state.workspaces[0].screens[0].zellij_auto_layout.as_ref().unwrap()[1]
        });

        mux.split(target, SplitDir::Right, None).unwrap();
        mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            assert!(matches!(
                &screen.root,
                Node::Split { b, .. }
                    if matches!(
                        b.as_ref(),
                        Node::Split { a, .. }
                            if matches!(a.as_ref(), Node::Stack { expanded, .. } if *expanded == target)
                    )
            ));
        });
    }

    #[test]
    fn structural_test_mux_can_create_many_surfaces_without_ptys() {
        let mux = test_mux();
        let first = mux.new_workspace(None, Some((120, 40))).unwrap();
        let pane = mux.with_state(|s| s.pane_of(first.id).unwrap());

        for _ in 0..450 {
            mux.new_tab(Some(pane), None, None).unwrap();
        }

        assert_eq!(mux.surface_count(), 451);
        mux.with_state(|s| {
            let pane = &s.panes[&pane];
            assert_eq!(pane.tabs.len(), 451);
            for surface in pane.tabs.iter().filter_map(|id| s.surfaces.get(id)) {
                assert_eq!(surface.kind(), crate::surface::SurfaceKind::Pty);
                assert_eq!(surface.size(), (120, 40));
                assert!(!surface.is_dead());
            }
        });
    }

    #[test]
    fn server_shutdown_clears_many_surfaces_with_one_tree_event() {
        let mux = test_mux();
        let first = mux.new_workspace(None, Some((120, 40))).unwrap();
        mux.resize_surface_for_client(first.id, 1, 100, 30).unwrap();
        assert_eq!(mux.set_client_size_participation(first.id, 1, false), Some(true));
        mux.record_client_size(90, 28);
        let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        for _ in 0..450 {
            mux.new_tab(Some(pane), None, None).unwrap();
        }
        let events = mux.subscribe();

        assert_eq!(mux.close_all_surfaces_for_shutdown().unwrap(), 451);

        mux.with_state(|state| {
            assert!(state.surfaces.is_empty());
            assert!(state.panes.is_empty());
            assert!(state.split_screens.is_empty());
            assert!(state.workspaces.iter().all(|workspace| workspace.screens.is_empty()));
        });
        let sizing = mux.client_sizing.lock().unwrap();
        assert!(sizing.surfaces.is_empty());
        assert!(sizing.report_order.is_empty());
        assert!(sizing.policies.is_empty());
        assert!(sizing.latest_explicit_size.is_none());
        drop(sizing);
        let events = events.try_iter().collect::<Vec<_>>();
        assert_eq!(events.iter().filter(|event| matches!(event, MuxEvent::TreeChanged)).count(), 1);
        assert_eq!(
            events
                .iter()
                .filter(|event| matches!(event, MuxEvent::TerminalRegistryChanged { .. }))
                .count(),
            1
        );
        assert_eq!(events.len(), 2);
        let error = mux.new_workspace(None, None).unwrap_err();
        assert_eq!(error.to_string(), "server is shutting down");
    }

    #[test]
    fn failed_surface_shutdown_retains_process_ownership_for_retry() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
        let owned = mux.surface(surface.id).unwrap();
        owned.set_server_shutdown_failure_for_test(true);

        let error = mux.close_all_surfaces_for_shutdown().unwrap_err();

        assert!(error.to_string().contains("could not terminate 1 surface process"));
        assert!(mux.surface(surface.id).is_none());
        assert_eq!(mux.shutdown_owners.len(), 1);

        owned.set_server_shutdown_failure_for_test(false);
        assert_eq!(mux.close_all_surfaces_for_shutdown().unwrap(), 1);
        assert!(mux.shutdown_owners.is_empty());
    }

    #[test]
    fn ordinary_mux_lifecycle_does_not_start_a_reconciler_worker() {
        let mux = test_mux();
        assert!(!mux.shutdown_owner_reconciler.worker_started());

        let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
        assert!(mux.close_surface(surface.id).unwrap());

        assert!(!mux.shutdown_owner_reconciler.worker_started());
    }

    #[test]
    fn ordinary_surface_close_retains_failed_process_ownership_until_reconciled() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
        let owned = mux.surface(surface.id).unwrap();
        owned.set_server_shutdown_failure_for_test(true);

        assert!(mux.close_surface(surface.id).unwrap());
        assert!(mux.surface(surface.id).is_none());
        assert_eq!(mux.shutdown_owners.len(), 1);

        owned.set_server_shutdown_failure_for_test(false);
        mux.close_all_surfaces_for_shutdown().unwrap();
        assert!(mux.shutdown_owners.is_empty());
    }

    #[test]
    fn ordinary_surface_close_reconciles_a_transient_termination_failure() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
        let owned = mux.surface(surface.id).unwrap();
        let (failing, attempts) = owned.set_recovering_server_shutdown_for_test();

        assert!(mux.close_surface(surface.id).unwrap());
        assert_eq!(mux.shutdown_owners.len(), 1);
        assert_eq!(attempts.load(Ordering::Acquire), 1);

        failing.store(false, Ordering::Release);
        let deadline = Instant::now() + Duration::from_secs(2);
        while !mux.shutdown_owners.is_empty() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(10));
        }

        assert!(mux.shutdown_owners.is_empty(), "retained owner had no normal-lifecycle retry");
        assert!(attempts.load(Ordering::Acquire) >= 2);
    }

    #[test]
    fn retained_shutdown_owners_bound_future_surface_admission() {
        let mux = test_mux();
        mux.set_shutdown_owner_capacity_for_test(1);
        let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
        let owned = mux.surface(surface.id).unwrap();
        owned.set_server_shutdown_failure_for_test(true);

        assert!(mux.close_surface(surface.id).unwrap());
        assert_eq!(mux.shutdown_owners.len(), 1);

        let error = mux.new_workspace(None, Some((80, 24))).unwrap_err();
        assert_eq!(error.to_string(), "surface_owner_capacity_exhausted");
    }

    #[test]
    fn permanent_shutdown_owner_failure_stops_automatic_retry_sweeps() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
        let owned = mux.surface(surface.id).unwrap();
        let (_failing, attempts) = owned.set_recovering_server_shutdown_for_test();

        assert!(mux.close_surface(surface.id).unwrap());
        let first_deadline = Instant::now() + Duration::from_secs(1);
        while attempts.load(Ordering::Acquire) < 4 && Instant::now() < first_deadline {
            std::thread::sleep(Duration::from_millis(10));
        }
        let settled = attempts.load(Ordering::Acquire);
        assert!(settled >= 4, "reconciler did not exercise its retry budget");

        std::thread::sleep(Duration::from_millis(250));

        assert_eq!(
            attempts.load(Ordering::Acquire),
            settled,
            "permanent cleanup failure kept an unbounded retry sweep alive"
        );
        assert_eq!(mux.shutdown_owners.len(), 1);
        assert_eq!(
            mux.shutdown_cleanup_health(),
            ShutdownCleanupHealth { pending: 1, retrying: false, degraded: true }
        );
    }

    #[test]
    fn cleanup_scheduled_during_the_final_retry_gets_a_fresh_retry_budget() {
        let mux = test_mux();
        let first = mux.new_workspace(None, Some((80, 24))).unwrap();
        let first = mux.surface(first.id).unwrap();
        let (first_failing, _) = first.set_recovering_server_shutdown_for_test();
        let second = Surface::spawn_for_test(
            mux.next_id(),
            mux.surface_options.lock().unwrap().clone(),
            Arc::downgrade(&mux),
        )
        .unwrap();
        let (second_failing, _) = second.set_recovering_server_shutdown_for_test();
        let injected = Arc::new(AtomicBool::new(false));
        *mux.shutdown_owner_reconciler.after_attempt.lock().unwrap() = Some(Arc::new({
            let mux = mux.clone();
            let injected = injected.clone();
            move |attempt| {
                if attempt != SHUTDOWN_RECONCILE_MAX_ATTEMPTS
                    || injected.swap(true, Ordering::AcqRel)
                {
                    return;
                }
                mux.retire_surface_runtime(second.clone());
                first_failing.store(false, Ordering::Release);
                second_failing.store(false, Ordering::Release);
            }
        }));

        assert!(mux.close_surface(first.id).unwrap());
        let deadline = Instant::now() + Duration::from_secs(2);
        while (!injected.load(Ordering::Acquire) || !mux.shutdown_owners.is_empty())
            && Instant::now() < deadline
        {
            std::thread::sleep(Duration::from_millis(10));
        }
        let reconciled = injected.load(Ordering::Acquire) && mux.shutdown_owners.is_empty();
        if !reconciled {
            mux.close_all_surfaces_for_shutdown().unwrap();
        }

        assert!(
            reconciled,
            "cleanup staged during the final attempt was left without a retry worker"
        );
    }

    #[test]
    fn rejected_sidebar_admission_does_not_launch_a_process() {
        let root = std::env::temp_dir()
            .join(format!("cmux-sidebar-admission-{}", crate::workspace_registry::new_uuid_v4()));
        std::fs::create_dir_all(&root).unwrap();
        let pid_path = root.join("sidebar.pid");
        let mux = Mux::new("sidebar-admission", SurfaceOptions::default());
        mux.set_shutdown_owner_capacity_for_test(0);
        let options = SidebarPluginOptions {
            command: vec![
                "/bin/sh".into(),
                "-c".into(),
                format!("echo $$ > {}; exec sleep 30", pid_path.display()),
            ],
            cwd: None,
        };

        let error = mux.spawn_sidebar_plugin_surface(&options, (80, 24)).unwrap_err();
        let deadline = Instant::now() + Duration::from_secs(1);
        while !pid_path.exists() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(10));
        }
        let spawned_pid = std::fs::read_to_string(&pid_path)
            .ok()
            .and_then(|pid| pid.trim().parse::<libc::pid_t>().ok());
        if let Some(pid) = spawned_pid {
            // SAFETY: this PID was written by the test-owned sidebar command.
            unsafe {
                libc::kill(pid, libc::SIGKILL);
            }
        }
        drop(mux);
        let _ = std::fs::remove_dir_all(root);

        assert_eq!(error.to_string(), "surface_owner_capacity_exhausted");
        assert!(
            spawned_pid.is_none(),
            "capacity rejection launched sidebar process {spawned_pid:?}"
        );
    }

    #[test]
    fn exited_sidebar_surface_transfers_its_shutdown_owner_before_removal() {
        let mux = test_mux();
        mux.configure_sidebar_plugin(Some(SidebarPluginOptions {
            command: vec!["sidebar-test".into()],
            cwd: None,
        }));
        let status = mux.ensure_sidebar_plugin(80, 24, true);
        let surface_id = status.surface.expect("sidebar surface was not created");
        let surface = mux.surface(surface_id).unwrap();
        surface.set_server_shutdown_failure_for_test(true);

        mux.surface_exited(surface_id);

        assert!(mux.surface(surface_id).is_none());
        assert_eq!(
            mux.shutdown_owners.len(),
            1,
            "sidebar exit discarded its still-retryable process owner"
        );

        surface.set_server_shutdown_failure_for_test(false);
        let _ = mux.terminate_staged_shutdown_owners_until(Instant::now() + Duration::from_secs(1));
        assert!(mux.shutdown_owners.is_empty());
    }

    #[cfg(unix)]
    #[test]
    fn rejected_terminal_admission_does_not_launch_a_process() {
        let root = std::env::temp_dir()
            .join(format!("cmux-terminal-admission-{}", crate::workspace_registry::new_uuid_v4()));
        std::fs::create_dir_all(&root).unwrap();
        let pid_path = root.join("terminal.pid");
        let mux = Mux::new(
            "terminal-admission",
            SurfaceOptions {
                command: Some(vec![
                    "/bin/sh".into(),
                    "-c".into(),
                    format!("echo $$ > {}; exec sleep 30", pid_path.display()),
                ]),
                ..SurfaceOptions::default()
            },
        );
        mux.set_shutdown_owner_capacity_for_test(0);

        let state = mux.state.lock().unwrap();
        let spawn = std::thread::spawn({
            let mux = mux.clone();
            move || mux.spawn_surface_with(None, None, Some((80, 24)), None, None)
        });
        let deadline = Instant::now() + Duration::from_secs(1);
        while !pid_path.exists() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(10));
        }
        let spawned_pid = std::fs::read_to_string(&pid_path)
            .ok()
            .and_then(|pid| pid.trim().parse::<libc::pid_t>().ok());
        drop(state);
        let error = spawn.join().unwrap().unwrap_err();
        if let Some(pid) = spawned_pid {
            // SAFETY: this PID was written by the test-owned terminal command.
            unsafe {
                libc::kill(pid, libc::SIGKILL);
            }
        }
        drop(mux);
        let _ = std::fs::remove_dir_all(root);

        assert_eq!(error.to_string(), "surface_owner_capacity_exhausted");
        assert!(
            spawned_pid.is_none(),
            "capacity rejection launched terminal process {spawned_pid:?}"
        );
    }

    #[cfg(unix)]
    #[test]
    fn cold_start_terminal_adoption_never_handshakes_inline() {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};

        let root = std::env::temp_dir().join(format!(
            "cmux-adoption-startup-budget-{}",
            crate::workspace_registry::new_uuid_v4()
        ));
        std::fs::create_dir_all(&root).unwrap();
        let uid = std::fs::metadata(&root).unwrap().uid();
        let mux = Mux::new_for_test("adoption-startup-budget", SurfaceOptions::default());
        let workspace =
            mux.create_empty_workspace(Some("startup-budget".into()), None, None).unwrap();
        {
            let mut registry = mux.workspace_registry.lock().unwrap();
            for index in 0..3 {
                let terminal_id = TerminalId::random().unwrap().to_hex();
                let incarnation = crate::terminal_host::HostIncarnation::random().unwrap().to_hex();
                commit_terminal_transition(
                    &mut registry,
                    "terminal-reserved",
                    &format!("startup-adoption-reserve-{index}"),
                    &RegistryTerminal {
                        terminal_id: terminal_id.clone(),
                        workspace_key: workspace.key.clone(),
                        incarnation: None,
                        lifecycle: TerminalLifecycle::Launching,
                        launch_spec: serde_json::json!({}),
                        exit: None,
                    },
                )
                .unwrap();
                let record = crate::terminal_host_runtime::TerminalHostRecord {
                    record_version: 1,
                    terminal_id: terminal_id.clone(),
                    incarnation,
                    endpoint: format!("/tmp/cmux-th-{uid}/{terminal_id}.sock"),
                    owner_token: "01".repeat(crate::terminal_host::CAPABILITY_TOKEN_LEN),
                    host_pid: 0,
                    host_start_nonce: String::new(),
                    workspace_key: workspace.key.clone(),
                    supports_set_defaults: false,
                    supports_terminate_only: false,
                    supports_clear_history: false,
                };
                let path = root.join(format!("{terminal_id}.json"));
                std::fs::write(&path, serde_json::to_vec(&record).unwrap()).unwrap();
                let mut permissions = std::fs::metadata(&path).unwrap().permissions();
                permissions.set_mode(0o600);
                std::fs::set_permissions(path, permissions).unwrap();
            }
        }
        mux.update_surface_options(|surface_options| {
            surface_options.terminal_host_root = Some(root.clone());
        });
        mux.terminal_adoption_coordinator.state.lock().unwrap().stopping = true;

        let (started_tx, started_rx) = std::sync::mpsc::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        let release_rx = Arc::new(Mutex::new(release_rx));
        *mux.terminal_adoption_surface_factory.lock().unwrap() = Some(Arc::new({
            move |_| {
                started_tx.send(()).unwrap();
                release_rx.lock().unwrap().recv().unwrap();
                anyhow::bail!("blocked startup handshake")
            }
        }));
        let (done_tx, done_rx) = std::sync::mpsc::sync_channel(1);
        let adoption = std::thread::spawn({
            let mux = mux.clone();
            move || {
                done_tx.send(mux.adopt_terminal_hosts()).unwrap();
            }
        });

        let started_inline = started_rx.recv_timeout(Duration::from_millis(100)).is_ok();
        let completed_inline = done_rx.recv_timeout(Duration::from_millis(100)).ok();
        let completed_without_release = completed_inline.is_some();
        for _ in 0..3 {
            release_tx.send(()).unwrap();
        }
        let result = match completed_inline {
            Some(result) => result,
            None => done_rx.recv_timeout(Duration::from_secs(2)).unwrap(),
        };
        adoption.join().unwrap();
        mux.terminal_adoption_coordinator.state.lock().unwrap().stopping = false;
        mux.request_daemon_shutdown();
        let _ = std::fs::remove_dir_all(root);

        result.unwrap();
        assert!(!started_inline, "cold-start adoption entered a persisted host handshake inline");
        assert!(
            completed_without_release,
            "cold-start adoption waited for a persisted host handshake"
        );
    }

    #[cfg(unix)]
    #[test]
    fn terminal_adoption_overflow_uses_one_bounded_worker_pool() {
        let options = SurfaceOptions::default();
        let mux = Mux::new_for_test("adoption-worker-bound", options.clone());
        let root =
            std::env::temp_dir().join(format!("cmux-adoption-worker-bound-{}", std::process::id()));

        for _ in 0..3 {
            let terminal_id = TerminalId::random().unwrap().to_hex();
            let record_path = root.join(format!("{terminal_id}.json"));
            mux.schedule_terminal_adoption(
                options.clone(),
                crate::terminal_host_runtime::TerminalHostRecord {
                    record_version: 2,
                    terminal_id,
                    incarnation: crate::terminal_host::HostIncarnation::random().unwrap().to_hex(),
                    endpoint: record_path.with_extension("sock").to_string_lossy().into_owned(),
                    owner_token: "00".repeat(crate::terminal_host::CAPABILITY_TOKEN_LEN),
                    host_pid: 0,
                    host_start_nonce: String::new(),
                    workspace_key: String::new(),
                    supports_set_defaults: true,
                    supports_terminate_only: true,
                    supports_clear_history: true,
                },
                record_path,
            );
        }

        let deadline = Instant::now() + crate::test_timeout(Duration::from_secs(1));
        while mux.terminal_adoption_workers_started.load(Ordering::Acquire)
            < TERMINAL_ADOPTION_WORKERS
            && Instant::now() < deadline
        {
            std::thread::sleep(Duration::from_millis(10));
        }
        let workers = mux.terminal_adoption_workers_started.load(Ordering::Acquire);
        let workers_running =
            mux.terminal_adoption_coordinator.state.lock().unwrap().workers_running;
        mux.request_daemon_shutdown();
        let _ = std::fs::remove_dir_all(root);

        assert_eq!(
            workers, TERMINAL_ADOPTION_WORKERS,
            "adoption did not preflight its fixed worker pool"
        );
        assert!(
            workers_running <= TERMINAL_ADOPTION_WORKERS,
            "overflow adoption retained {workers_running} concurrent retry threads"
        );
    }

    #[cfg(unix)]
    #[test]
    fn terminal_adoption_overflow_uses_a_bounded_deferred_tier() {
        fn task(index: usize) -> TerminalAdoptionTask {
            let terminal_id = format!("{index:032x}");
            TerminalAdoptionTask {
                options: SurfaceOptions::default(),
                record: crate::terminal_host_runtime::TerminalHostRecord {
                    record_version: 1,
                    terminal_id: terminal_id.clone(),
                    incarnation: terminal_id,
                    endpoint: String::new(),
                    owner_token: String::new(),
                    host_pid: 0,
                    host_start_nonce: String::new(),
                    workspace_key: String::new(),
                    supports_set_defaults: false,
                    supports_terminate_only: false,
                    supports_clear_history: false,
                },
                record_path: std::path::PathBuf::new(),
                next_attempt: Instant::now(),
                delay: Duration::from_millis(100),
            }
        }

        let mut state = TerminalAdoptionQueueState::default();
        for index in 0..TERMINAL_ADOPTION_QUEUE_CAPACITY {
            assert!(state.enqueue(task(index)));
        }
        for index in TERMINAL_ADOPTION_QUEUE_CAPACITY..TERMINAL_ADOPTION_QUEUE_CAPACITY * 2 {
            assert!(state.enqueue(task(index)));
        }
        assert!(
            !state.enqueue(task(TERMINAL_ADOPTION_QUEUE_CAPACITY * 2)),
            "adoption overflow exceeded both bounded queue tiers"
        );
        state.rescan_required = true;
        state.next_rescan = Some(Instant::now());
        assert!(
            !state.rescan_due(Instant::now()),
            "adoption overflow rescanned while deferred records remained"
        );

        let retry = state.tasks.pop().unwrap();
        let retry_id = retry.record.terminal_id.clone();
        state.in_flight += 1;
        state.in_flight -= 1;
        state.requeue_retry(retry);
        assert!(
            state.tasks.iter().any(|task| {
                task.record.terminal_id == format!("{TERMINAL_ADOPTION_QUEUE_CAPACITY:032x}")
            }),
            "a permanently retrying active record starved the oldest deferred record"
        );
        assert_eq!(
            state.deferred.back().map(|task| task.record.terminal_id.as_str()),
            Some(retry_id.as_str()),
            "a retry did not rotate behind deferred adoption work"
        );

        for _ in 0..TERMINAL_ADOPTION_DEFERRED_CAPACITY {
            state.tasks.pop().unwrap();
            state.promote_deferred();
        }
        assert_eq!(state.active_len(), TERMINAL_ADOPTION_QUEUE_CAPACITY);
        assert!(state.deferred.is_empty());
        assert!(
            state.rescan_due(Instant::now()),
            "adoption overflow did not request one new batch after draining deferred records"
        );
    }

    #[cfg(unix)]
    #[test]
    fn terminal_adoption_rescan_uses_one_registry_snapshot() {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};

        let root = std::env::temp_dir()
            .join(format!("cmux-adoption-snapshot-{}", crate::workspace_registry::new_uuid_v4()));
        std::fs::create_dir_all(&root).unwrap();
        let uid = std::fs::metadata(&root).unwrap().uid();
        for _ in 0..3 {
            let terminal_id = TerminalId::random().unwrap().to_hex();
            let record = crate::terminal_host_runtime::TerminalHostRecord {
                record_version: 1,
                terminal_id: terminal_id.clone(),
                incarnation: crate::terminal_host::HostIncarnation::random().unwrap().to_hex(),
                endpoint: format!("/tmp/cmux-th-{uid}/{terminal_id}.sock"),
                owner_token: "01".repeat(crate::terminal_host::CAPABILITY_TOKEN_LEN),
                host_pid: 0,
                host_start_nonce: String::new(),
                workspace_key: String::new(),
                supports_set_defaults: false,
                supports_terminate_only: false,
                supports_clear_history: false,
            };
            let path = root.join(format!("{terminal_id}.json"));
            std::fs::write(&path, serde_json::to_vec(&record).unwrap()).unwrap();
            let mut permissions = std::fs::metadata(&path).unwrap().permissions();
            permissions.set_mode(0o600);
            std::fs::set_permissions(path, permissions).unwrap();
        }
        let mux = Mux::new_for_test("adoption-snapshot", SurfaceOptions::default());
        mux.update_surface_options(|options| options.terminal_host_root = Some(root.clone()));
        mux.shutting_down.store(true, Ordering::Release);
        mux.workspace_registry.lock().unwrap().reset_terminal_snapshot_count_for_test();

        assert!(mux.rescan_terminal_adoptions());
        let snapshots = mux.workspace_registry.lock().unwrap().terminal_snapshot_count_for_test();
        let _ = std::fs::remove_dir_all(root);

        assert_eq!(
            snapshots, 1,
            "one adoption rescan queried the full terminal registry {snapshots} times"
        );
    }

    #[cfg(unix)]
    #[test]
    fn exited_placeholder_does_not_suppress_terminal_adoption_rescan() {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};

        let root = std::env::temp_dir().join(format!(
            "cmux-adoption-exited-placeholder-{}",
            crate::workspace_registry::new_uuid_v4()
        ));
        std::fs::create_dir_all(&root).unwrap();
        let mux = Mux::new_for_test("adoption-exited-placeholder", SurfaceOptions::default());
        let workspace =
            mux.create_empty_workspace(Some("adoption-placeholder".into()), None, None).unwrap();
        let terminal_id = TerminalId::random().unwrap().to_hex();
        let incarnation = crate::terminal_host::HostIncarnation::random().unwrap().to_hex();
        let placeholder = insert_running_terminal_identity_surface(
            &mux,
            &terminal_id,
            &incarnation,
            &workspace.key,
        );
        assert!(placeholder.is_dead());

        let record = crate::terminal_host_runtime::TerminalHostRecord {
            record_version: 2,
            terminal_id: terminal_id.clone(),
            incarnation,
            endpoint: format!(
                "/tmp/cmux-th-{}/{}.sock",
                std::fs::metadata(&root).unwrap().uid(),
                terminal_id
            ),
            owner_token: "01".repeat(crate::terminal_host::CAPABILITY_TOKEN_LEN),
            host_pid: 1,
            host_start_nonce: "01".repeat(32),
            workspace_key: workspace.key,
            supports_set_defaults: true,
            supports_terminate_only: true,
            supports_clear_history: true,
        };
        let record_path = root.join(format!("{terminal_id}.json"));
        std::fs::write(&record_path, serde_json::to_vec(&record).unwrap()).unwrap();
        let mut permissions = std::fs::metadata(&record_path).unwrap().permissions();
        permissions.set_mode(0o600);
        std::fs::set_permissions(&record_path, permissions).unwrap();
        mux.update_surface_options(|options| options.terminal_host_root = Some(root.clone()));
        mux.terminal_adoption_coordinator.state.lock().unwrap().stopping = true;

        assert!(mux.rescan_terminal_adoptions());
        let rescan_required =
            mux.terminal_adoption_coordinator.state.lock().unwrap().rescan_required;
        mux.terminal_adoption_coordinator.state.lock().unwrap().stopping = false;
        let _ = std::fs::remove_dir_all(root);

        assert!(
            rescan_required,
            "an exited identity placeholder suppressed the retry for its live discovery record"
        );
    }

    #[cfg(unix)]
    #[test]
    fn terminal_adoption_retries_when_the_registry_read_is_uncertain() {
        use std::os::unix::fs::MetadataExt;

        let root = std::env::temp_dir().join(format!(
            "cmux-adoption-registry-error-{}",
            crate::workspace_registry::new_uuid_v4()
        ));
        std::fs::create_dir_all(&root).unwrap();
        let terminal_id = TerminalId::random().unwrap().to_hex();
        let record_path = root.join(format!("{terminal_id}.json"));
        let record = crate::terminal_host_runtime::TerminalHostRecord {
            record_version: 1,
            terminal_id: terminal_id.clone(),
            incarnation: crate::terminal_host::HostIncarnation::random().unwrap().to_hex(),
            endpoint: format!(
                "/tmp/cmux-th-{}/{}.sock",
                std::fs::metadata(&root).unwrap().uid(),
                terminal_id
            ),
            owner_token: "01".repeat(crate::terminal_host::CAPABILITY_TOKEN_LEN),
            host_pid: 0,
            host_start_nonce: String::new(),
            workspace_key: String::new(),
            supports_set_defaults: false,
            supports_terminate_only: false,
            supports_clear_history: false,
        };
        let task = TerminalAdoptionTask {
            options: SurfaceOptions::default(),
            record,
            record_path,
            next_attempt: Instant::now(),
            delay: Duration::from_millis(100),
        };
        let mux = Mux::new_for_test("adoption-registry-error", SurfaceOptions::default());
        mux.workspace_registry.lock().unwrap().set_terminal_record_read_failure_for_test(true);

        let complete = mux.try_terminal_adoption(&task);

        mux.workspace_registry.lock().unwrap().set_terminal_record_read_failure_for_test(false);
        let _ = std::fs::remove_dir_all(root);
        assert!(
            !complete,
            "an uncertain registry read was treated as proof that the host should be cleaned up"
        );
    }

    #[cfg(unix)]
    #[test]
    fn terminal_adoption_retries_when_the_running_transition_write_fails() {
        let mux = test_mux();
        let workspace =
            mux.create_empty_workspace(Some("adoption-write-retry".into()), None, None).unwrap();
        let terminal_id = TerminalId::random().unwrap().to_hex();
        let incarnation = crate::terminal_host::HostIncarnation::random().unwrap().to_hex();
        {
            let mut registry = mux.workspace_registry.lock().unwrap();
            commit_terminal_transition(
                &mut registry,
                "terminal-reserved",
                "adoption-write-retry-reserve",
                &RegistryTerminal {
                    terminal_id: terminal_id.clone(),
                    workspace_key: workspace.key,
                    incarnation: None,
                    lifecycle: TerminalLifecycle::Launching,
                    launch_spec: serde_json::json!({}),
                    exit: None,
                },
            )
            .unwrap();
            commit_terminal_lifecycle(
                &mut registry,
                "terminal-ready",
                "adoption-write-retry-running",
                &terminal_id,
                TerminalLifecycle::Running,
                Some(&incarnation),
                None,
            )
            .unwrap();
        }
        let task = TerminalAdoptionTask {
            options: SurfaceOptions::default(),
            record: crate::terminal_host_runtime::TerminalHostRecord {
                record_version: 2,
                terminal_id: terminal_id.clone(),
                incarnation,
                endpoint: String::new(),
                owner_token: "01".repeat(crate::terminal_host::CAPABILITY_TOKEN_LEN),
                host_pid: 1,
                host_start_nonce: "01".repeat(32),
                workspace_key: String::new(),
                supports_set_defaults: true,
                supports_terminate_only: true,
                supports_clear_history: true,
            },
            record_path: std::path::PathBuf::new(),
            next_attempt: Instant::now(),
            delay: Duration::from_millis(100),
        };
        mux.set_terminal_close_failure_for_test(true).unwrap();

        let complete = mux.try_terminal_adoption(&task);

        mux.set_terminal_close_failure_for_test(false).unwrap();
        let terminal =
            mux.workspace_registry.lock().unwrap().terminal_record(&terminal_id).unwrap().unwrap();
        assert_eq!(terminal.lifecycle, TerminalLifecycle::Running);
        assert!(
            !complete,
            "a failed Running-to-Adopting write permanently completed the adoption task"
        );
    }

    #[cfg(unix)]
    #[test]
    fn blocked_terminal_adoption_does_not_stall_an_unrelated_terminal() {
        let options = SurfaceOptions::default();
        let mux = Mux::new_for_test("adoption-parallel-progress", options.clone());
        let workspace =
            mux.create_empty_workspace(Some("parallel-progress".into()), None, None).unwrap();
        let root = std::env::temp_dir().join(format!(
            "cmux-adoption-parallel-progress-{}",
            crate::workspace_registry::new_uuid_v4()
        ));
        let mut records = Vec::new();
        {
            let mut registry = mux.workspace_registry.lock().unwrap();
            for index in 0..2 {
                let terminal_id = TerminalId::random().unwrap().to_hex();
                let incarnation = crate::terminal_host::HostIncarnation::random().unwrap().to_hex();
                let record_path = root.join(format!("{terminal_id}.json"));
                commit_terminal_transition(
                    &mut registry,
                    "terminal-reserved",
                    &format!("parallel-adoption-reserve-{index}"),
                    &RegistryTerminal {
                        terminal_id: terminal_id.clone(),
                        workspace_key: workspace.key.clone(),
                        incarnation: None,
                        lifecycle: TerminalLifecycle::Launching,
                        launch_spec: serde_json::json!({}),
                        exit: None,
                    },
                )
                .unwrap();
                commit_terminal_lifecycle(
                    &mut registry,
                    "terminal-adopting",
                    &format!("parallel-adoption-start-{index}"),
                    &terminal_id,
                    TerminalLifecycle::Adopting,
                    Some(&incarnation),
                    None,
                )
                .unwrap();
                records.push((
                    crate::terminal_host_runtime::TerminalHostRecord {
                        record_version: 2,
                        terminal_id,
                        incarnation,
                        endpoint: record_path.with_extension("sock").to_string_lossy().into_owned(),
                        owner_token: "00".repeat(crate::terminal_host::CAPABILITY_TOKEN_LEN),
                        host_pid: 0,
                        host_start_nonce: String::new(),
                        workspace_key: workspace.key.clone(),
                        supports_set_defaults: true,
                        supports_terminate_only: true,
                        supports_clear_history: true,
                    },
                    record_path,
                ));
            }
        }

        let calls = Arc::new(AtomicUsize::new(0));
        let (first_started_tx, first_started_rx) = std::sync::mpsc::sync_channel(1);
        let (second_started_tx, second_started_rx) = std::sync::mpsc::sync_channel(1);
        let (release_tx, release_rx) = std::sync::mpsc::sync_channel(1);
        let release_rx = Arc::new(Mutex::new(release_rx));
        *mux.terminal_adoption_surface_factory.lock().unwrap() = Some(Arc::new({
            let mux = Arc::downgrade(&mux);
            let options = options.clone();
            move |id| {
                let call = calls.fetch_add(1, Ordering::AcqRel);
                if call == 0 {
                    first_started_tx.send(()).unwrap();
                    release_rx.lock().unwrap().recv().unwrap();
                } else {
                    second_started_tx.send(()).unwrap();
                }
                Surface::spawn_for_test(id, options.clone(), mux.clone())
            }
        }));

        let (first_record, first_path) = records.remove(0);
        mux.schedule_terminal_adoption(options.clone(), first_record, first_path);
        first_started_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        let (second_record, second_path) = records.remove(0);
        mux.schedule_terminal_adoption(options, second_record, second_path);
        let second_progressed = second_started_rx.recv_timeout(Duration::from_millis(300)).is_ok();
        release_tx.send(()).unwrap();

        let deadline = Instant::now() + Duration::from_secs(2);
        while !mux.terminal_adoptions.lock().unwrap().is_empty() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(10));
        }
        mux.shutdown().unwrap();
        let _ = std::fs::remove_dir_all(root);

        assert!(
            second_progressed,
            "one blocked terminal adoption stalled an unrelated queued terminal"
        );
    }

    #[cfg(unix)]
    #[test]
    fn daemon_handoff_does_not_terminate_an_in_flight_terminal_adoption() {
        let options = SurfaceOptions::default();
        let mux = Mux::new_for_test("adoption-handoff", options.clone());
        let workspace = mux.create_empty_workspace(Some("survivor".into()), None, None).unwrap();
        let terminal_id = TerminalId::random().unwrap();
        let terminal_hex = terminal_id.to_hex();
        let incarnation = crate::terminal_host::HostIncarnation::random().unwrap().to_hex();
        let record_path = std::env::temp_dir().join(format!("{terminal_hex}.json"));
        let record = crate::terminal_host_runtime::TerminalHostRecord {
            record_version: 2,
            terminal_id: terminal_hex.clone(),
            incarnation: incarnation.clone(),
            endpoint: record_path.with_extension("sock").to_string_lossy().into_owned(),
            owner_token: "00".repeat(crate::terminal_host::CAPABILITY_TOKEN_LEN),
            host_pid: 0,
            host_start_nonce: String::new(),
            workspace_key: workspace.key.clone(),
            supports_set_defaults: true,
            supports_terminate_only: true,
            supports_clear_history: true,
        };
        {
            let mut registry = mux.workspace_registry.lock().unwrap();
            commit_terminal_transition(
                &mut registry,
                "terminal-reserved",
                "adoption-handoff-reserve",
                &RegistryTerminal {
                    terminal_id: terminal_hex.clone(),
                    workspace_key: workspace.key,
                    incarnation: None,
                    lifecycle: TerminalLifecycle::Launching,
                    launch_spec: serde_json::json!({}),
                    exit: None,
                },
            )
            .unwrap();
            commit_terminal_lifecycle(
                &mut registry,
                "terminal-adopting",
                "adoption-handoff-adopting",
                &terminal_hex,
                TerminalLifecycle::Adopting,
                Some(&incarnation),
                None,
            )
            .unwrap();
        }
        let kill_attempts = Arc::new(Mutex::new(None));
        *mux.terminal_adoption_surface_factory.lock().unwrap() = Some(Arc::new({
            let mux = Arc::downgrade(&mux);
            let options = options.clone();
            let kill_attempts = kill_attempts.clone();
            move |id| {
                let surface = Surface::spawn_for_test(id, options.clone(), mux.clone())?;
                let (_, attempts) = surface.set_recovering_server_shutdown_for_test();
                *kill_attempts.lock().unwrap() = Some(attempts);
                Ok(surface)
            }
        }));
        let (attached_tx, attached_rx) = std::sync::mpsc::sync_channel(1);
        let (release_tx, release_rx) = std::sync::mpsc::sync_channel(1);
        let release_rx = Arc::new(Mutex::new(release_rx));
        *mux.terminal_adoption_after_attach.lock().unwrap() = Some(Arc::new({
            move || {
                attached_tx.send(()).unwrap();
                release_rx.lock().unwrap().recv().unwrap();
            }
        }));

        mux.schedule_terminal_adoption(options, record, record_path);
        attached_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        mux.request_daemon_shutdown();
        release_tx.send(()).unwrap();
        let deadline = Instant::now() + Duration::from_secs(2);
        while !mux.terminal_adoptions.lock().unwrap().is_empty() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(10));
        }
        let attempts = kill_attempts
            .lock()
            .unwrap()
            .clone()
            .expect("adoption surface was not created")
            .load(Ordering::Acquire);

        assert_eq!(
            attempts, 0,
            "daemon handoff terminated the surface attached to the durable host"
        );
    }

    #[test]
    fn ordinary_browser_close_terminates_the_owner_staged_during_removal() {
        fn read_ws_json(ws: &mut tungstenite::WebSocket<std::net::TcpStream>) -> Value {
            loop {
                match ws.read().unwrap() {
                    tungstenite::Message::Text(text) => {
                        return serde_json::from_str(&text).unwrap();
                    }
                    tungstenite::Message::Binary(bytes) => {
                        return serde_json::from_slice(&bytes).unwrap();
                    }
                    _ => {}
                }
            }
        }

        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let (query_tx, query_rx) = std::sync::mpsc::sync_channel(1);
        let server = std::thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut ws = tungstenite::accept(stream).unwrap();
            let discover = read_ws_json(&mut ws);
            assert_eq!(discover["method"], "Target.setDiscoverTargets");
            ws.send(tungstenite::Message::Text(
                serde_json::json!({"id": discover["id"], "result": {}}).to_string().into(),
            ))
            .unwrap();

            let query = read_ws_json(&mut ws);
            assert_eq!(query["method"], "Target.getTargets");
            query_tx.send(()).unwrap();
            ws.send(tungstenite::Message::Text(
                serde_json::json!({
                    "id": query["id"],
                    "result": {"targetInfos": []}
                })
                .to_string()
                .into(),
            ))
            .unwrap();
        });
        let runtime = BrowserRuntime::connect_external_for_test(&format!(
            "ws://{address}/devtools/browser/fake"
        ))
        .unwrap();
        let mux = test_mux();
        let options = mux.surface_options.lock().unwrap().clone();
        let surface = browser::new_surface(
            999,
            "about:blank".to_string(),
            (80, 24),
            (8, 16),
            &options,
            Arc::downgrade(&mux),
        )
        .unwrap();
        surface.as_browser().unwrap().install_shutdown_session_for_test(
            runtime.clone(),
            "target-1",
            "session-1",
        );
        insert_surface_checked(&mux, &mut mux.state.lock().unwrap(), surface.clone()).unwrap();

        let removed =
            take_surface_for_retirement(&mux, &mut mux.state.lock().unwrap(), surface.id).unwrap();
        mux.retire_surface_runtime(removed);
        let attempted_during_close = query_rx.recv_timeout(Duration::from_millis(200)).is_ok();

        if !attempted_during_close {
            mux.terminate_staged_shutdown_owners_until(Instant::now() + Duration::from_secs(1));
            query_rx
                .recv_timeout(Duration::from_secs(1))
                .expect("cleanup retry did not reach the staged browser owner");
        }
        runtime.shutdown();
        server.join().unwrap();

        assert!(
            attempted_during_close,
            "ordinary close lost the consume-once browser owner staged during removal"
        );
        assert!(mux.shutdown_owners.is_empty());
    }

    #[test]
    fn shutdown_batches_target_discovery_per_browser_runtime() {
        fn read_ws_json(ws: &mut tungstenite::WebSocket<std::net::TcpStream>) -> Value {
            loop {
                match ws.read().unwrap() {
                    tungstenite::Message::Text(text) => {
                        return serde_json::from_str(&text).unwrap();
                    }
                    tungstenite::Message::Binary(bytes) => {
                        return serde_json::from_slice(&bytes).unwrap();
                    }
                    _ => {}
                }
            }
        }

        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let (query_count_tx, query_count_rx) = std::sync::mpsc::sync_channel(1);
        let server = std::thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut ws = tungstenite::accept(stream).unwrap();
            let discover = read_ws_json(&mut ws);
            assert_eq!(discover["method"], "Target.setDiscoverTargets");
            ws.send(tungstenite::Message::Text(
                serde_json::json!({"id": discover["id"], "result": {}}).to_string().into(),
            ))
            .unwrap();

            let mut query_count = 0;
            let mut closed_targets = HashSet::new();
            while closed_targets.len() < 2 {
                let request = read_ws_json(&mut ws);
                match request["method"].as_str().unwrap() {
                    "Target.getTargets" => {
                        query_count += 1;
                        ws.send(tungstenite::Message::Text(
                            serde_json::json!({
                                "id": request["id"],
                                "result": {
                                    "targetInfos": [
                                        {"targetId": "target-1"},
                                        {"targetId": "target-2"}
                                    ]
                                }
                            })
                            .to_string()
                            .into(),
                        ))
                        .unwrap();
                    }
                    "Target.closeTarget" => {
                        closed_targets
                            .insert(request["params"]["targetId"].as_str().unwrap().to_string());
                        ws.send(tungstenite::Message::Text(
                            serde_json::json!({
                                "id": request["id"],
                                "result": {"success": true}
                            })
                            .to_string()
                            .into(),
                        ))
                        .unwrap();
                    }
                    method => panic!("unexpected browser shutdown request: {method}"),
                }
            }
            query_count_tx.send(query_count).unwrap();
        });
        let runtime = BrowserRuntime::connect_external_for_test(&format!(
            "ws://{address}/devtools/browser/fake"
        ))
        .unwrap();
        let mux = test_mux();
        let options = mux.surface_options.lock().unwrap().clone();
        for (id, target_id, session_id) in
            [(999, "target-1", "session-1"), (1000, "target-2", "session-2")]
        {
            let surface = browser::new_surface(
                id,
                "about:blank".to_string(),
                (80, 24),
                (8, 16),
                &options,
                Arc::downgrade(&mux),
            )
            .unwrap();
            surface.as_browser().unwrap().install_shutdown_session_for_test(
                runtime.clone(),
                target_id,
                session_id,
            );
            assert!(mux.shutdown_owners.stage_surface(&surface).is_some());
        }

        let failed =
            mux.terminate_staged_shutdown_owners_until(Instant::now() + Duration::from_secs(1));
        let query_count = query_count_rx.recv_timeout(Duration::from_secs(1)).unwrap();

        runtime.shutdown();
        server.join().unwrap();
        assert!(!failed);
        assert!(mux.shutdown_owners.is_empty());
        assert_eq!(
            query_count, 1,
            "shutdown repeated full target discovery for each browser surface"
        );
    }

    #[test]
    fn server_shutdown_uses_launched_runtime_when_target_confirmation_is_unreachable() {
        fn read_ws_json(ws: &mut tungstenite::WebSocket<std::net::TcpStream>) -> Value {
            loop {
                match ws.read().unwrap() {
                    tungstenite::Message::Text(text) => {
                        return serde_json::from_str(&text).unwrap();
                    }
                    tungstenite::Message::Binary(bytes) => {
                        return serde_json::from_slice(&bytes).unwrap();
                    }
                    _ => {}
                }
            }
        }

        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = std::thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut ws = tungstenite::accept(stream).unwrap();
            let version = read_ws_json(&mut ws);
            assert_eq!(version["method"], "Browser.getVersion");
            ws.send(tungstenite::Message::Text(
                serde_json::json!({
                    "id": version["id"],
                    "error": {"code": -32000, "message": "unavailable"}
                })
                .to_string()
                .into(),
            ))
            .unwrap();
            let discover = read_ws_json(&mut ws);
            assert_eq!(discover["method"], "Target.setDiscoverTargets");
            ws.send(tungstenite::Message::Text(
                serde_json::json!({"id": discover["id"], "result": {}}).to_string().into(),
            ))
            .unwrap();
        });
        let runtime = BrowserRuntime::connect_launched_for_test(&format!(
            "ws://{address}/devtools/browser/fake"
        ))
        .unwrap();
        server.join().unwrap();
        let disconnect_deadline = Instant::now() + Duration::from_secs(1);
        while !runtime.is_closed() && Instant::now() < disconnect_deadline {
            std::thread::yield_now();
        }
        assert!(runtime.is_closed(), "fixture did not make target confirmation unreachable");

        let mux = test_mux();
        let options = mux.surface_options.lock().unwrap().clone();
        let surface = browser::new_surface(
            999,
            "about:blank".to_string(),
            (80, 24),
            (8, 16),
            &options,
            Arc::downgrade(&mux),
        )
        .unwrap();
        surface.as_browser().unwrap().install_shutdown_session_for_test(
            runtime.clone(),
            "target-1",
            "session-1",
        );
        insert_surface_checked(&mux, &mut mux.state.lock().unwrap(), surface).unwrap();
        mux.browser_runtime.install_for_test(runtime);

        let result = mux.close_all_surfaces_for_shutdown();

        assert!(
            result.is_ok(),
            "owned launched browser was not used as the authoritative shutdown fallback: {result:?}"
        );
        assert!(mux.shutdown_owners.is_empty());
        assert!(!mux.browser_runtime.has_runtime_for_test());
    }

    #[test]
    fn server_shutdown_cannot_pass_an_in_flight_surface_retirement() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
        let surface_id = surface.id;
        let owned = mux.surface(surface.id).unwrap();
        owned.set_server_shutdown_delay_for_test(Duration::from_millis(150));
        let close = std::thread::spawn({
            let mux = mux.clone();
            move || mux.close_surface(surface_id).unwrap()
        });
        let removal_deadline = Instant::now() + Duration::from_secs(1);
        while mux.surface(surface_id).is_some() && Instant::now() < removal_deadline {
            std::thread::yield_now();
        }
        assert!(mux.surface(surface_id).is_none(), "ordinary close did not remove its surface");

        let shutdown = mux.close_all_surfaces_for_shutdown();

        assert!(close.join().unwrap());
        owned.set_server_shutdown_failure_for_test(false);
        mux.close_all_surfaces_for_shutdown().unwrap();
        assert!(mux.shutdown_owners.is_empty());
        let error = shutdown.expect_err("server shutdown passed an untracked retirement owner");
        assert!(error.to_string().contains("could not terminate 1 surface process"));
    }

    #[test]
    fn shutdown_request_watch_is_signaled_and_cancellable() {
        let mux = test_mux();
        let watch = mux.watch_shutdown_request();
        let (result_tx, result_rx) = std::sync::mpsc::sync_channel(1);
        let waiter = std::thread::spawn(move || result_tx.send(watch.wait()).unwrap());
        assert!(result_rx.recv_timeout(Duration::from_millis(50)).is_err());

        mux.request_shutdown();

        assert!(result_rx.recv_timeout(Duration::from_secs(1)).unwrap());
        waiter.join().unwrap();
        assert!(mux.watch_shutdown_request().wait());

        let next = mux.watch_next_shutdown_request();
        let (next_tx, next_rx) = std::sync::mpsc::sync_channel(1);
        let next_waiter = std::thread::spawn(move || next_tx.send(next.wait()).unwrap());
        assert!(next_rx.recv_timeout(Duration::from_millis(50)).is_err());
        mux.request_shutdown();
        assert!(next_rx.recv_timeout(Duration::from_secs(1)).unwrap());
        next_waiter.join().unwrap();

        let fresh = test_mux();
        let watch = fresh.watch_shutdown_request();
        let cancel = watch.clone();
        let (result_tx, result_rx) = std::sync::mpsc::sync_channel(1);
        let waiter = std::thread::spawn(move || result_tx.send(watch.wait()).unwrap());
        cancel.cancel();
        assert!(!result_rx.recv_timeout(Duration::from_secs(1)).unwrap());
        waiter.join().unwrap();
    }

    #[test]
    fn ordinary_surface_close_does_not_retain_terminal_render_state() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
        let owned = mux.surface(surface.id).unwrap();
        owned.set_server_shutdown_failure_for_test(true);
        let before_close = Arc::strong_count(&owned);

        assert!(mux.close_surface(surface.id).unwrap());

        assert!(
            Arc::strong_count(&owned) < before_close,
            "shutdown escrow retained the heavyweight Surface"
        );
    }

    #[test]
    fn bulk_surface_close_uses_one_shared_termination_deadline() {
        let mux = test_mux();
        let first = mux.new_workspace(None, Some((80, 24))).unwrap();
        let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        for _ in 1..64 {
            mux.new_tab(Some(pane), None, None).unwrap();
        }
        let surfaces = mux.with_state(|state| {
            state.panes[&pane]
                .tabs
                .iter()
                .map(|surface| state.surfaces[surface].clone())
                .collect::<Vec<_>>()
        });
        for surface in &surfaces {
            surface.set_server_shutdown_delay_for_test(Duration::from_millis(50));
        }

        let started = Instant::now();
        assert!(mux.close_pane(pane).unwrap());

        assert!(
            started.elapsed() < Duration::from_millis(500),
            "bulk close multiplied the per-surface shutdown timeout: {:?}",
            started.elapsed()
        );
    }

    #[cfg(unix)]
    #[test]
    fn server_shutdown_reuses_one_deadline_bounded_record_scan() {
        let root = std::env::temp_dir().join(format!(
            "cmux-shutdown-record-scan-{}",
            crate::workspace_registry::new_uuid_v4()
        ));
        std::fs::create_dir_all(&root).unwrap();
        let mux = Mux::new_for_test(
            "shutdown-record-scan",
            SurfaceOptions { terminal_host_root: Some(root.clone()), ..SurfaceOptions::default() },
        );
        let calls = Arc::new(AtomicUsize::new(0));
        let (started_tx, started_rx) = std::sync::mpsc::sync_channel(1);
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        let release_rx = Arc::new(Mutex::new(release_rx));
        *mux.terminal_host_record_loader.lock().unwrap() = Some(Arc::new({
            let calls = calls.clone();
            move |_, _, _| {
                calls.fetch_add(1, Ordering::AcqRel);
                started_tx.send(()).unwrap();
                release_rx.lock().unwrap().recv().unwrap();
                Ok(Vec::new())
            }
        }));

        let (done_tx, done_rx) = std::sync::mpsc::sync_channel(1);
        let first = std::thread::spawn({
            let mux = mux.clone();
            move || {
                done_tx
                    .send(mux.close_all_surfaces_for_shutdown_until(
                        Instant::now() + Duration::from_millis(50),
                    ))
                    .unwrap();
            }
        });
        started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        let first_result = done_rx.recv_timeout(Duration::from_millis(150)).ok();
        let completed_at_deadline = first_result.as_ref().is_some_and(Result::is_err);
        let reused_scan = if completed_at_deadline {
            let second = mux
                .close_all_surfaces_for_shutdown_until(Instant::now() + Duration::from_millis(50));
            let starts = calls.load(Ordering::Acquire);
            for _ in 0..2 {
                release_tx.send(()).unwrap();
            }
            let third =
                mux.close_all_surfaces_for_shutdown_until(Instant::now() + Duration::from_secs(1));
            second.is_err() && starts == 1 && third.is_ok()
        } else {
            for _ in 0..3 {
                release_tx.send(()).unwrap();
            }
            let _ = done_rx.recv_timeout(Duration::from_secs(1)).unwrap();
            false
        };
        first.join().unwrap();
        let _ = std::fs::remove_dir_all(root);

        assert!(
            completed_at_deadline,
            "server shutdown remained blocked inside the terminal-host record scan"
        );
        assert!(reused_scan, "a shutdown retry spawned another blocked terminal-host record scan");
    }

    #[cfg(unix)]
    #[test]
    fn server_shutdown_rejects_malformed_host_records_before_removing_topology() {
        let root = std::env::temp_dir().join(format!(
            "cmux-shutdown-host-record-{}",
            crate::workspace_registry::new_uuid_v4()
        ));
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("00000000000040008000000000000031.json"), b"{not-valid-json")
            .unwrap();
        let mux = Mux::new_for_test(
            "strict-shutdown-records",
            SurfaceOptions { terminal_host_root: Some(root.clone()), ..SurfaceOptions::default() },
        );
        let surface = mux.new_workspace(None, Some((80, 24))).unwrap();

        let result = mux.close_all_surfaces_for_shutdown();
        let topology_retained = mux.surface(surface.id).is_some();
        let _ = std::fs::remove_dir_all(&root);

        let error = result.unwrap_err();
        assert!(format!("{error:#}").contains("load terminal hosts for server shutdown"));
        assert!(topology_retained);
    }

    #[cfg(unix)]
    #[test]
    fn server_shutdown_rejects_host_records_beyond_owner_capacity() {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};

        let root = std::env::temp_dir().join(format!(
            "cmux-shutdown-host-capacity-{}",
            crate::workspace_registry::new_uuid_v4()
        ));
        std::fs::create_dir_all(&root).unwrap();
        let terminal_id = TerminalId::random().unwrap().to_hex();
        let record = crate::terminal_host_runtime::TerminalHostRecord {
            record_version: 1,
            terminal_id: terminal_id.clone(),
            incarnation: crate::terminal_host::HostIncarnation::random().unwrap().to_hex(),
            endpoint: format!(
                "/tmp/cmux-th-{}/{}.sock",
                std::fs::metadata(&root).unwrap().uid(),
                terminal_id
            ),
            owner_token: "01".repeat(crate::terminal_host::CAPABILITY_TOKEN_LEN),
            host_pid: 0,
            host_start_nonce: String::new(),
            workspace_key: String::new(),
            supports_set_defaults: false,
            supports_terminate_only: false,
            supports_clear_history: false,
        };
        let record_path = record.record_path(&root);
        std::fs::write(&record_path, serde_json::to_vec(&record).unwrap()).unwrap();
        std::fs::set_permissions(&record_path, std::fs::Permissions::from_mode(0o600)).unwrap();
        let mux = Mux::new_for_test(
            "strict-shutdown-capacity",
            SurfaceOptions { terminal_host_root: Some(root.clone()), ..SurfaceOptions::default() },
        );
        mux.set_shutdown_owner_capacity_for_test(0);

        let error = mux.close_all_surfaces_for_shutdown().unwrap_err();
        let _ = std::fs::remove_dir_all(&root);

        assert!(
            format!("{error:#}").contains("capacity"),
            "shutdown staged a host beyond owner capacity: {error:#}"
        );
    }

    #[cfg(unix)]
    #[test]
    fn rejected_shutdown_preflight_preserves_browser_ownership() {
        fn read_ws_json(ws: &mut tungstenite::WebSocket<std::net::TcpStream>) -> Value {
            loop {
                match ws.read().unwrap() {
                    tungstenite::Message::Text(text) => {
                        return serde_json::from_str(&text).unwrap();
                    }
                    tungstenite::Message::Binary(bytes) => {
                        return serde_json::from_slice(&bytes).unwrap();
                    }
                    _ => {}
                }
            }
        }

        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = std::thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut ws = tungstenite::accept(stream).unwrap();
            let discover = read_ws_json(&mut ws);
            assert_eq!(discover["method"], "Target.setDiscoverTargets");
            ws.send(tungstenite::Message::Text(
                serde_json::json!({"id": discover["id"], "result": {}}).to_string().into(),
            ))
            .unwrap();
        });
        let runtime = BrowserRuntime::connect_external_for_test(&format!(
            "ws://{address}/devtools/browser/fake"
        ))
        .unwrap();
        server.join().unwrap();
        let disconnect_deadline = Instant::now() + Duration::from_secs(1);
        while !runtime.is_closed() && Instant::now() < disconnect_deadline {
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(runtime.is_closed(), "test browser runtime did not observe disconnect");
        let mux = test_mux();
        let options = mux.surface_options.lock().unwrap().clone();
        let surface = browser::new_surface(
            999,
            "about:blank".to_string(),
            (80, 24),
            (8, 16),
            &options,
            Arc::downgrade(&mux),
        )
        .unwrap();
        surface.as_browser().unwrap().install_shutdown_session_for_test(
            runtime.clone(),
            "target-preflight",
            "session-preflight",
        );
        insert_surface_checked(&mux, &mut mux.state.lock().unwrap(), surface.clone()).unwrap();
        mux.set_shutdown_owner_capacity_for_test(0);

        let error = mux.close_all_surfaces_for_shutdown().unwrap_err();
        let topology_retained = mux.surface(surface.id).is_some();
        let surface_was_live = !surface.is_dead();
        let owner_retained = surface.shutdown_owner().is_some();
        runtime.shutdown();

        assert!(format!("{error:#}").contains("capacity"));
        assert!(topology_retained, "shutdown preflight removed the browser surface");
        assert!(surface_was_live, "shutdown preflight killed the retained browser surface");
        assert!(owner_retained, "shutdown preflight consumed the browser target owner");
    }

    #[cfg(unix)]
    #[test]
    fn server_shutdown_preflights_process_control_before_removing_topology() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
        crate::process_session::set_process_session_preflight_failure_for_test(true);

        let result = mux.close_all_surfaces_for_shutdown();

        crate::process_session::set_process_session_preflight_failure_for_test(false);
        assert!(result.is_err(), "server shutdown ignored an unavailable process-control runtime");
        assert!(
            mux.surface(surface.id).is_some(),
            "server shutdown removed topology before process-control preflight"
        );
    }

    #[test]
    fn server_shutdown_waits_for_async_browser_bootstrap() {
        let mux = test_mux();
        let (bootstrap_reached_tx, bootstrap_reached_rx) = std::sync::mpsc::sync_channel(1);
        let (release_bootstrap_tx, release_bootstrap_rx) = std::sync::mpsc::sync_channel(1);
        let release_bootstrap_rx = Arc::new(Mutex::new(release_bootstrap_rx));
        *mux.browser_bootstrap_before_runtime.lock().unwrap() = Some(Arc::new({
            move || {
                bootstrap_reached_tx.send(()).unwrap();
                release_bootstrap_rx.lock().unwrap().recv().unwrap();
            }
        }));
        mux.new_browser_tab("about:blank".into(), None, Some((80, 24))).unwrap();
        bootstrap_reached_rx.recv_timeout(Duration::from_secs(1)).unwrap();

        let (shutdown_done_tx, shutdown_done_rx) = std::sync::mpsc::sync_channel(1);
        let shutdown = std::thread::spawn({
            let mux = mux.clone();
            move || {
                shutdown_done_tx.send(mux.close_all_surfaces_for_shutdown()).unwrap();
            }
        });
        assert!(shutdown_done_rx.recv_timeout(Duration::from_millis(100)).is_err());

        release_bootstrap_tx.send(()).unwrap();
        assert_eq!(shutdown_done_rx.recv_timeout(Duration::from_secs(1)).unwrap().unwrap(), 1);
        shutdown.join().unwrap();
        assert!(!mux.browser_runtime.has_runtime_for_test());
    }

    #[test]
    fn daemon_exit_retries_until_async_browser_bootstrap_releases_ownership() {
        let mux = test_mux();
        mux.set_shutdown_attempt_timeout_for_test(crate::test_timeout(Duration::from_millis(25)));
        let (bootstrap_reached_tx, bootstrap_reached_rx) = std::sync::mpsc::sync_channel(1);
        let (release_bootstrap_tx, release_bootstrap_rx) = std::sync::mpsc::sync_channel(1);
        let release_bootstrap_rx = Arc::new(Mutex::new(release_bootstrap_rx));
        *mux.browser_bootstrap_before_runtime.lock().unwrap() = Some(Arc::new({
            move || {
                bootstrap_reached_tx.send(()).unwrap();
                release_bootstrap_rx.lock().unwrap().recv().unwrap();
            }
        }));
        mux.new_browser_tab("about:blank".into(), None, Some((80, 24))).unwrap();
        bootstrap_reached_rx.recv_timeout(Duration::from_secs(1)).unwrap();

        let (shutdown_done_tx, shutdown_done_rx) = std::sync::mpsc::sync_channel(1);
        let shutdown = std::thread::spawn({
            let mux = mux.clone();
            move || {
                mux.shutdown().unwrap();
                shutdown_done_tx.send(()).unwrap();
            }
        });
        let finished_early =
            shutdown_done_rx.recv_timeout(crate::test_timeout(Duration::from_millis(100))).is_ok();
        release_bootstrap_tx.send(()).unwrap();
        if !finished_early {
            shutdown_done_rx.recv_timeout(crate::test_timeout(Duration::from_secs(2))).unwrap();
        }
        shutdown.join().unwrap();

        assert!(
            !finished_early,
            "daemon exit completed while browser bootstrap still owned in-flight work"
        );
        assert!(!mux.browser_runtime.has_runtime_for_test());
    }

    #[test]
    fn daemon_exit_retains_active_local_owner_until_termination_succeeds() {
        let mux = test_mux();
        mux.set_shutdown_attempt_timeout_for_test(Duration::from_millis(25));
        let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
        let (failing, attempts) = surface.set_recovering_server_shutdown_for_test();
        let (shutdown_done_tx, shutdown_done_rx) = std::sync::mpsc::sync_channel(1);
        let shutdown = std::thread::spawn({
            let mux = mux.clone();
            move || {
                mux.shutdown().unwrap();
                shutdown_done_tx.send(()).unwrap();
            }
        });
        let deadline = Instant::now() + Duration::from_secs(1);
        while attempts.load(Ordering::Acquire) == 0 && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(5));
        }
        let retained = mux.shutdown_owners.len();

        failing.store(false, Ordering::Release);
        shutdown_done_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        shutdown.join().unwrap();

        assert_eq!(
            retained, 1,
            "daemon exit discarded the active local process owner after termination failed"
        );
        assert!(mux.shutdown_owners.is_empty());
    }

    #[test]
    fn daemon_exit_bounds_permanent_cleanup_failures() {
        let mux = test_mux();
        mux.set_shutdown_attempt_timeout_for_test(Duration::from_millis(25));
        let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
        let (failing, _attempts) = surface.set_recovering_server_shutdown_for_test();
        let (shutdown_done_tx, shutdown_done_rx) = std::sync::mpsc::sync_channel(1);
        let shutdown = std::thread::spawn(move || {
            shutdown_done_tx.send(mux.shutdown()).unwrap();
        });

        let completed_before_deadline =
            shutdown_done_rx.recv_timeout(Duration::from_millis(400)).is_ok();
        failing.store(false, Ordering::Release);
        if !completed_before_deadline {
            let _ = shutdown_done_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        }
        shutdown.join().unwrap();

        assert!(
            completed_before_deadline,
            "daemon exit retried a permanent cleanup failure without a total deadline"
        );
    }

    #[test]
    fn browser_runtime_connection_does_not_hold_the_shared_slot() {
        let mux = Mux::new_for_test(
            "browser-runtime-slot",
            SurfaceOptions {
                cdp_url: Some("ws://127.0.0.1:9/devtools/browser/unreachable".into()),
                ..SurfaceOptions::default()
            },
        );
        let (connect_started_tx, connect_started_rx) = std::sync::mpsc::sync_channel(1);
        let (release_connect_tx, release_connect_rx) = std::sync::mpsc::sync_channel(1);
        let release_connect_rx = Arc::new(Mutex::new(release_connect_rx));
        *mux.browser_runtime_connect.lock().unwrap() = Some(Arc::new({
            move || {
                connect_started_tx.send(()).unwrap();
                release_connect_rx.lock().unwrap().recv().unwrap();
            }
        }));
        mux.new_browser_tab("about:blank".into(), None, Some((80, 24))).unwrap();
        connect_started_rx.recv_timeout(Duration::from_secs(1)).unwrap();

        let slot_available = mux.browser_runtime.lock_available_for_test();
        release_connect_tx.send(()).unwrap();
        let deadline = Instant::now() + Duration::from_secs(1);
        loop {
            if mux.async_surface_creations.inner.state.lock().unwrap().active == 0
                || Instant::now() >= deadline
            {
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        mux.request_daemon_shutdown();
        mux.shutdown().unwrap();

        assert!(
            slot_available,
            "browser connection setup held the shared runtime slot across blocking work"
        );
    }

    #[test]
    fn shutdown_fanout_runs_terminations_concurrently() {
        let gate = Arc::new((Mutex::new(false), Condvar::new()));
        let (started_tx, started_rx) = std::sync::mpsc::sync_channel(8);
        let worker = std::thread::spawn({
            let gate = gate.clone();
            move || {
                bounded_shutdown_fanout(
                    &[(); 8],
                    Instant::now() + Duration::from_secs(1),
                    |_, _| {
                        started_tx.send(()).unwrap();
                        let (released, wake) = &*gate;
                        let released = wake
                            .wait_while(released.lock().unwrap(), |released| !*released)
                            .unwrap();
                        drop(released);
                    },
                );
            }
        });

        let deadline = Instant::now() + Duration::from_secs(1);
        let mut started = 0;
        while started < 8 {
            let Some(remaining) = deadline.checked_duration_since(Instant::now()) else { break };
            if started_rx.recv_timeout(remaining).is_err() {
                break;
            }
            started += 1;
        }
        let (released, wake) = &*gate;
        *released.lock().unwrap() = true;
        wake.notify_all();
        worker.join().unwrap();
        assert_eq!(started, 8);
    }

    #[test]
    fn shutdown_fanout_reuses_one_deadline_across_worker_batches() {
        let deadline = Instant::now() + Duration::from_secs(1);
        let observed = Mutex::new(Vec::new());

        bounded_shutdown_fanout(
            &[(); SHUTDOWN_FANOUT_WORKERS * 2 + 1],
            deadline,
            |_, item_deadline| {
                observed.lock().unwrap().push(item_deadline);
            },
        );

        let observed = observed.into_inner().unwrap();
        assert_eq!(observed.len(), SHUTDOWN_FANOUT_WORKERS * 2 + 1);
        assert!(observed.into_iter().all(|item_deadline| item_deadline == deadline));
    }

    #[test]
    fn shutdown_fanout_does_not_claim_another_batch_after_the_deadline() {
        let gate = Arc::new((Mutex::new(false), Condvar::new()));
        let (started_tx, started_rx) = std::sync::mpsc::sync_channel(SHUTDOWN_FANOUT_WORKERS + 1);
        let deadline = Instant::now() + Duration::from_millis(250);
        let worker = std::thread::spawn({
            let gate = gate.clone();
            move || {
                bounded_shutdown_fanout(&[(); SHUTDOWN_FANOUT_WORKERS + 1], deadline, |_, _| {
                    started_tx.send(()).unwrap();
                    let (released, wake) = &*gate;
                    let released =
                        wake.wait_while(released.lock().unwrap(), |released| !*released).unwrap();
                    drop(released);
                });
            }
        });

        for _ in 0..SHUTDOWN_FANOUT_WORKERS {
            started_rx.recv_timeout(Duration::from_millis(200)).unwrap();
        }
        std::thread::sleep(deadline.saturating_duration_since(Instant::now()));
        let (released, wake) = &*gate;
        *released.lock().unwrap() = true;
        wake.notify_all();
        worker.join().unwrap();

        assert_eq!(started_rx.try_iter().count(), 0);
    }

    #[test]
    fn surface_creation_fence_has_a_bounded_wait() {
        let gate = SurfaceCreationGate::default();
        let creation = gate.begin().unwrap();
        let started = Instant::now();

        assert!(!gate.stop_and_wait_until(started + Duration::from_millis(25)));

        drop(creation);
        assert!(started.elapsed() < Duration::from_millis(250));
    }

    #[test]
    fn server_shutdown_waits_for_in_flight_surface_creation() {
        let mux = test_mux();
        let workspace = mux.create_empty_workspace(Some("race".into()), None, None).unwrap();
        let (creation_reached_tx, creation_reached_rx) = std::sync::mpsc::sync_channel(1);
        let (release_creation_tx, release_creation_rx) = std::sync::mpsc::sync_channel(1);
        let release_creation_rx = Arc::new(Mutex::new(release_creation_rx));
        *mux.terminal_create_after_materialization_lock.lock().unwrap() = Some(Arc::new({
            move || {
                creation_reached_tx.send(()).unwrap();
                release_creation_rx.lock().unwrap().recv().unwrap();
            }
        }));

        let create = std::thread::spawn({
            let mux = mux.clone();
            move || {
                mux.create_terminal_surface_in_workspace(
                    workspace.workspace,
                    None,
                    None,
                    None,
                    Some((80, 24)),
                )
                .unwrap()
                .0
                .id
            }
        });
        creation_reached_rx.recv_timeout(Duration::from_secs(1)).unwrap();

        let (shutdown_done_tx, shutdown_done_rx) = std::sync::mpsc::sync_channel(1);
        let shutdown = std::thread::spawn({
            let mux = mux.clone();
            move || {
                shutdown_done_tx.send(mux.close_all_surfaces_for_shutdown().unwrap()).unwrap();
            }
        });
        assert!(shutdown_done_rx.recv_timeout(Duration::from_millis(100)).is_err());

        release_creation_tx.send(()).unwrap();
        let created = create.join().unwrap();
        assert_eq!(shutdown_done_rx.recv_timeout(Duration::from_secs(1)).unwrap(), 1);
        shutdown.join().unwrap();
        assert!(mux.surface(created).is_none());
        assert_eq!(
            mux.new_tab(None, None, None).unwrap_err().to_string(),
            "server is shutting down"
        );
        *mux.terminal_create_after_materialization_lock.lock().unwrap() = None;
    }

    #[cfg(unix)]
    #[test]
    fn server_shutdown_keeps_topology_when_terminal_batch_commit_fails() {
        let mux = test_mux();
        let workspace = mux.create_empty_workspace(Some("durable".into()), None, None).unwrap();
        let terminal_id = "00000000000040008000000000000021";
        let incarnation = "10000000000040008000000000000021";
        let surface =
            mux.seed_running_terminal_for_test(terminal_id, incarnation, &workspace.key).unwrap();
        mux.set_terminal_close_failure_for_test(true).unwrap();

        let error = mux.close_all_surfaces_for_shutdown().unwrap_err();

        assert!(format!("{error:#}").contains("forced terminal close failure"));
        assert!(!mux.shutdown_requested());
        assert!(!mux.daemon_shutdown_requested());
        assert!(mux.surface(surface).is_some());
        assert!(mux.with_state(|state| state.pane_of(surface).is_some()));
        mux.set_terminal_close_failure_for_test(false).unwrap();
        assert_eq!(mux.close_all_surfaces_for_shutdown().unwrap(), 1);
        assert!(!mux.shutdown_requested());
        assert!(!mux.daemon_shutdown_requested());
        assert!(mux.surface(surface).is_none());
    }

    #[cfg(unix)]
    #[test]
    fn server_stop_persists_a_restartable_empty_topology() {
        const TERMINAL: &str = "00000000000040008000000000000022";
        const INCARNATION: &str = "10000000000040008000000000000022";
        let root = std::env::temp_dir()
            .join(format!("cmux-server-stop-restart-{}", crate::workspace_registry::new_uuid_v4()));
        let session = "server-stop-restart";
        {
            let registry = WorkspaceRegistry::open(&root, session).unwrap();
            let mux = Mux::from_workspace_registry(
                session.into(),
                SurfaceOptions::default(),
                registry,
                ProviderWorkspaceState::default(),
                true,
            )
            .unwrap();
            let workspace = mux.create_empty_workspace(Some("durable".into()), None, None).unwrap();
            mux.seed_running_terminal_for_test(TERMINAL, INCARNATION, &workspace.key).unwrap();

            assert_eq!(mux.close_all_surfaces_for_shutdown().unwrap(), 1);
        }

        let reopened = Mux::open_persistent(session, SurfaceOptions::default(), &root)
            .expect("server stop must leave a restartable durable session");
        reopened.with_state(|state| {
            assert_eq!(state.workspaces.len(), 1);
            assert!(state.workspaces[0].screens.is_empty());
            assert!(state.panes.is_empty());
            assert!(state.surfaces.is_empty());
        });
        reopened.shutdown().unwrap();
        drop(reopened);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn closing_active_pane_focuses_most_recent_remaining_pane() {
        let mux = test_mux();
        let s1 = mux.new_workspace(None, None).unwrap();
        let p1 = mux.with_state(|s| s.pane_of(s1.id).unwrap());
        let s2 = mux.split(p1, SplitDir::Right, None).unwrap();
        let p2 = mux.with_state(|s| s.pane_of(s2.id).unwrap());
        let s3 = mux.split(p2, SplitDir::Down, None).unwrap();
        let p3 = mux.with_state(|s| s.pane_of(s3.id).unwrap());

        assert!(mux.focus_pane(p1));
        assert!(mux.focus_pane(p3));
        let previous_p1_focus = mux.with_state(|state| state.panes[&p1].focused_at);
        let events = mux.subscribe();
        mux.close_pane(p3).unwrap();

        let deadline = Instant::now() + Duration::from_secs(1);
        let mut saw_closed = false;
        loop {
            let remaining = deadline.saturating_duration_since(Instant::now());
            match events.recv_timeout(remaining).expect("pane close events arrive before timeout") {
                MuxEvent::TreeDelta(TreeDelta {
                    kind: TreeDeltaKind::PaneClosed, pane, ..
                }) if pane == Some(p3) => saw_closed = true,
                MuxEvent::TreeSelectionChanged if saw_closed => break,
                MuxEvent::TreeSelectionChanged => {
                    panic!("selection resync arrived before the pane-closed delta")
                }
                _ => {}
            }
        }
        mux.with_state(|s| {
            assert_eq!(s.workspaces[0].screens[0].active_pane, p1);
            assert!(s.panes.contains_key(&p2));
            assert!(s.panes[&p1].focused_at > previous_p1_focus);
        });
    }

    #[test]
    fn tabs_within_pane() {
        let mux = test_mux();
        let s1 = mux.new_workspace(None, None).unwrap();
        let pane = mux.with_state(|s| s.pane_of(s1.id).unwrap());
        let s2 = mux.new_tab(Some(pane), None, None).unwrap();

        mux.with_state(|s| {
            let p = &s.panes[&pane];
            assert_eq!(p.tabs, vec![s1.id, s2.id]);
            assert_eq!(p.active_tab, 1);
        });

        // Closing the active tab activates the previous one; the pane stays.
        mux.close_surface(s2.id).unwrap();
        mux.with_state(|s| {
            let p = &s.panes[&pane];
            assert_eq!(p.tabs, vec![s1.id]);
            assert_eq!(p.active_tab, 0);
            assert_eq!(s.workspaces.len(), 1);
        });

        // Closing the last tab collapses the pane and screen, while the
        // canonical workspace remains until an explicit close-workspace.
        mux.close_surface(s1.id).unwrap();
        mux.with_state(|s| {
            assert_eq!(s.workspaces.len(), 1);
            assert!(s.workspaces[0].screens.is_empty());
            assert_eq!(s.workspace_revision, 1);
        });
    }

    #[test]
    fn closing_an_ordinary_tab_does_not_rebuild_the_split_index() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        mux.split(pane, SplitDir::Right, None).unwrap();
        let ordinary_tab = mux.new_tab(Some(pane), None, None).unwrap();
        let sentinel = SplitId::MAX;
        {
            let mut state = mux.state.lock().unwrap();
            state.split_screens.insert(sentinel, (usize::MAX, usize::MAX, ScreenId::MAX));
        }

        mux.close_surface(ordinary_tab.id).unwrap();

        mux.with_state(|state| assert!(state.split_screens.contains_key(&sentinel)));
        mux.close_surface(first.id).unwrap();
        mux.with_state(|state| assert!(!state.split_screens.contains_key(&sentinel)));
    }

    #[test]
    fn move_tab_within_pane_clamps_and_tracks_active_tab() {
        let mux = test_mux();
        let s1 = mux.new_workspace(None, None).unwrap();
        let pane = mux.with_state(|s| s.pane_of(s1.id).unwrap());
        let s2 = mux.new_tab(Some(pane), None, None).unwrap();
        let s3 = mux.new_tab(Some(pane), None, None).unwrap();
        let pane_revision = mux.with_state(|s| s.pane_revision);

        assert!(mux.move_tab(s3.id, pane, 0));
        mux.with_state(|s| {
            let pane = &s.panes[&pane];
            assert_eq!(pane.tabs, vec![s3.id, s1.id, s2.id]);
            assert_eq!(pane.active_tab, 0);
        });

        assert!(mux.move_tab(s3.id, pane, 99));
        mux.with_state(|s| {
            let pane = &s.panes[&pane];
            assert_eq!(pane.tabs, vec![s1.id, s2.id, s3.id]);
            assert_eq!(pane.active_tab, 2);
            assert_eq!(s.pane_revision, pane_revision);
        });
    }

    #[test]
    fn ordinary_tab_moves_do_not_rebuild_the_split_index() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let second = mux.split(first_pane, SplitDir::Right, None).unwrap();
        let second_pane = mux.with_state(|state| state.pane_of(second.id).unwrap());
        let extra = mux.new_tab(Some(first_pane), None, None).unwrap();
        let sentinel = SplitId::MAX;
        {
            let mut state = mux.state.lock().unwrap();
            state.split_screens.insert(sentinel, (usize::MAX, usize::MAX, ScreenId::MAX));
        }

        assert!(mux.move_tab(extra.id, first_pane, 0));
        mux.with_state(|state| assert!(state.split_screens.contains_key(&sentinel)));
        let events = mux.subscribe();
        assert!(mux.move_tab(extra.id, second_pane, 0));
        mux.with_state(|state| assert!(state.split_screens.contains_key(&sentinel)));
        assert!(matches!(events.recv().unwrap(), MuxEvent::TreeChanged));
        assert!(events.try_recv().is_err());
    }

    #[test]
    fn move_tab_same_position_preserves_active_tab_and_emits_no_event() {
        let mux = test_mux();
        let s1 = mux.new_workspace(None, None).unwrap();
        let pane = mux.with_state(|s| s.pane_of(s1.id).unwrap());
        let s2 = mux.new_tab(Some(pane), None, None).unwrap();
        let s3 = mux.new_tab(Some(pane), None, None).unwrap();
        mux.select_tab(Some(pane), Some(0), None);
        let events = mux.subscribe();

        assert!(!mux.move_tab(s2.id, pane, 1));
        mux.with_state(|s| {
            let pane = &s.panes[&pane];
            assert_eq!(pane.tabs, vec![s1.id, s2.id, s3.id]);
            assert_eq!(pane.active_tab, 0);
        });
        assert!(events.try_iter().all(|event| !matches!(event, MuxEvent::TreeChanged)));
    }

    #[test]
    fn move_tab_across_panes_collapses_empty_source_and_preserves_surface() {
        let mux = test_mux();
        let s1 = mux.new_workspace(None, None).unwrap();
        let p1 = mux.with_state(|s| s.pane_of(s1.id).unwrap());
        let s2 = mux.split(p1, SplitDir::Right, None).unwrap();
        let p2 = mux.with_state(|s| s.pane_of(s2.id).unwrap());
        let original_count = mux.surface_count();
        let pane_revision = mux.with_state(|s| s.pane_revision);

        assert!(mux.move_tab(s1.id, p2, 0));
        mux.with_state(|s| {
            assert!(!s.panes.contains_key(&p1));
            let target = &s.panes[&p2];
            assert_eq!(target.tabs, vec![s1.id, s2.id]);
            assert_eq!(target.active_tab, 0);
            assert!(s.surfaces.contains_key(&s1.id));
            let mut ids = Vec::new();
            s.workspaces[0].screens[0].root.pane_ids(&mut ids);
            assert_eq!(ids, vec![p2]);
            assert_eq!(s.pane_revision, pane_revision + 1);
        });
        assert_eq!(mux.surface_count(), original_count);
    }

    #[test]
    fn surface_session_subscription_tracks_real_tab_moves_without_layout_churn() {
        let mux = test_mux();
        mux.create_empty_workspace(None, None, None).unwrap();
        let target =
            mux.new_browser_tab("about:blank#target".into(), None, Some((80, 24))).unwrap();
        mux.create_empty_workspace(None, None, None).unwrap();
        let destination =
            mux.new_browser_tab("about:blank#destination".into(), None, Some((80, 24))).unwrap();
        let (source_screen, destination_screen, destination_pane) = mux.with_state(|state| {
            let source_pane = state.pane_of(target.id).unwrap();
            let destination_pane = state.pane_of(destination.id).unwrap();
            let (source_workspace_index, source_screen_index) =
                state.screen_of(source_pane).unwrap();
            let (destination_workspace_index, destination_screen_index) =
                state.screen_of(destination_pane).unwrap();
            (
                state.workspaces[source_workspace_index].screens[source_screen_index].id,
                state.workspaces[destination_workspace_index].screens[destination_screen_index].id,
                destination_pane,
            )
        });
        let events = mux.subscribe_surface_session(target.id).unwrap();

        assert!(mux.move_tab(target.id, destination_pane, 0));
        mux.emit(MuxEvent::LayoutChanged(source_screen));
        mux.emit(MuxEvent::LayoutChanged(destination_screen));

        let received = events.try_iter().collect::<Vec<_>>();
        assert!(received.iter().any(|event| matches!(event, MuxEvent::TreeChanged)));
        let layouts = received
            .iter()
            .filter_map(|event| match event {
                MuxEvent::LayoutChanged(screen) => Some(*screen),
                _ => None,
            })
            .collect::<Vec<_>>();
        assert!(layouts.is_empty());
        mux.shutdown().unwrap();
    }

    #[test]
    fn move_tab_does_not_emit_layout_for_a_removed_source_screen() {
        let mux = test_mux();
        let source = mux.new_workspace(None, None).unwrap();
        let (workspace, source_screen) =
            mux.with_state(|state| (state.workspaces[0].id, state.workspaces[0].screens[0].id));
        let target = mux.new_screen(Some(workspace), None).unwrap();
        let target_pane = mux.with_state(|state| state.pane_of(target.id).unwrap());
        let events = mux.subscribe();

        assert!(mux.move_tab(source.id, target_pane, 0));
        mux.with_state(|state| {
            assert!(state.workspaces[0].screens.iter().all(|screen| screen.id != source_screen));
        });
        assert!(matches!(events.recv().unwrap(), MuxEvent::TreeChanged));
        assert!(events.try_iter().all(
            |event| !matches!(event, MuxEvent::LayoutChanged(screen) if screen == source_screen)
        ));
    }

    #[test]
    fn set_ratio_updates_deepest_split_and_clamps() {
        let mux = test_mux();
        let (p1, p2, p3, _, _) = seed_split_ratio_tree(&mux);

        assert!(mux.set_ratio_checked(p1, SplitDir::Right, 0.8).is_ok());
        mux.with_state(|s| {
            let root = &s.workspaces[0].screens[0].root;
            let Node::Split { ratio: root_ratio, a, .. } = root else {
                panic!("root should be split");
            };
            assert_eq!(*root_ratio, 0.5);
            let Node::Split { ratio: inner_ratio, .. } = a.as_ref() else {
                panic!("first child should be split");
            };
            assert_eq!(*inner_ratio, 0.8);
        });

        assert!(mux.set_ratio_checked(p2, SplitDir::Right, -1.0).is_ok());
        mux.with_state(|s| {
            let Node::Split { ratio, .. } = &s.workspaces[0].screens[0].root else {
                panic!("root should be split");
            };
            assert_eq!(*ratio, 0.05);
        });

        assert!(mux.set_ratio_checked(p3, SplitDir::Right, 2.0).is_ok());
        mux.with_state(|s| {
            let Node::Split { a, .. } = &s.workspaces[0].screens[0].root else {
                panic!("root should be split");
            };
            let Node::Split { ratio, .. } = a.as_ref() else {
                panic!("first child should be split");
            };
            assert_eq!(*ratio, 0.95);
        });

        assert!(matches!(
            mux.set_ratio_checked(9999, SplitDir::Right, 0.4),
            Err(LayoutRatioError::UnknownPaneSplit { pane: 9999 })
        ));
    }

    #[test]
    fn unchanged_ratio_commands_preserve_undo_metadata_revision_and_events() {
        let mux = test_mux();
        let (p1, _, _, root_split, inner_split) = seed_split_ratio_tree(&mux);
        mux.state.lock().unwrap().workspaces[0].screens[0].zellij_auto_layout = Some(vec![1, 2, 3]);
        let before = mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            (screen.layout_revision, screen.layout_undo.len(), screen.zellij_auto_layout.clone())
        });
        let events = mux.subscribe();

        assert!(mux.set_split_ratio_checked(root_split, 0.5).is_ok());
        assert!(mux.set_ratio_checked(p1, SplitDir::Right, 0.5).is_ok());

        mux.with_state(|state| {
            let screen = &state.workspaces[0].screens[0];
            assert_eq!(
                (
                    screen.layout_revision,
                    screen.layout_undo.len(),
                    screen.zellij_auto_layout.clone(),
                ),
                before
            );
            assert!(state.split_screens.contains_key(&root_split));
            assert!(state.split_screens.contains_key(&inner_split));
        });
        assert!(events.try_iter().next().is_none());
    }

    #[test]
    fn set_split_ratio_updates_only_the_exact_split_and_clamps() {
        let mux = test_mux();
        let (_, _, _, root_split, inner_split) = seed_split_ratio_tree(&mux);
        mux.state.lock().unwrap().workspaces[0].screens[0].zellij_auto_layout = Some(vec![1, 2, 3]);
        let events = mux.subscribe();

        assert!(mux.set_split_ratio_checked(root_split, 2.0).is_ok());
        mux.with_state(|s| {
            let Node::Split { id, ratio: root_ratio, a, .. } = &s.workspaces[0].screens[0].root
            else {
                panic!("root should be split");
            };
            assert_eq!(*id, root_split);
            assert_eq!(*root_ratio, 0.95);
            let Node::Split { id, ratio: inner_ratio, .. } = a.as_ref() else {
                panic!("first child should be split");
            };
            assert_eq!(*id, inner_split);
            assert_eq!(*inner_ratio, 0.5);
            assert!(s.workspaces[0].screens[0].zellij_auto_layout.is_none());
        });
        assert!(matches!(events.recv().unwrap(), MuxEvent::LayoutChanged(_)));
        assert!(events.try_recv().is_err());
        assert!(matches!(
            mux.set_split_ratio_checked(9999, 0.4),
            Err(LayoutRatioError::UnknownSplit { split: 9999 })
        ));
    }

    #[test]
    fn dynamically_created_split_ids_remain_stable_across_tree_edits() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let p1 = mux.with_state(|s| s.pane_of(first.id).unwrap());
        let second = mux.split(p1, SplitDir::Right, None).unwrap();
        let p2 = mux.with_state(|s| s.pane_of(second.id).unwrap());
        let original = mux.with_state(|s| {
            let Node::Split { id, .. } = &s.workspaces[0].screens[0].root else {
                panic!("root should be split");
            };
            *id
        });

        let third = mux.split(p2, SplitDir::Down, None).unwrap();
        let p3 = mux.with_state(|s| s.pane_of(third.id).unwrap());
        let nested = mux.with_state(|s| {
            let Node::Split { b, .. } = &s.workspaces[0].screens[0].root else {
                panic!("root should remain split");
            };
            let Node::Split { id, .. } = b.as_ref() else {
                panic!("second child should be split");
            };
            *id
        });
        let screen = mux.with_state(|state| state.workspaces[0].screens[0].id);
        mux.with_state(|state| {
            assert_eq!(state.split_screens.get(&original).map(|location| location.2), Some(screen));
            assert_eq!(state.split_screens.get(&nested).map(|location| location.2), Some(screen));
        });
        assert!(mux.swap_panes(p1, p3));
        assert!(mux.set_split_ratio_checked(original, 0.7).is_ok());

        mux.with_state(|s| {
            let Node::Split { id, ratio, .. } = &s.workspaces[0].screens[0].root else {
                panic!("root should remain split");
            };
            assert_eq!(*id, original);
            assert_eq!(*ratio, 0.7);
        });

        mux.close_surface(third.id).unwrap();
        mux.with_state(|state| {
            assert!(!state.split_screens.contains_key(&original));
            assert!(state.split_screens.contains_key(&nested));
        });
    }

    #[test]
    fn screens_within_workspace() {
        let mux = test_mux();
        mux.new_workspace(None, None).unwrap();
        let s2 = mux.new_screen(None, None).unwrap();

        let (screen1, screen2) = mux.with_state(|s| {
            let ws = &s.workspaces[0];
            assert_eq!(ws.screens.len(), 2);
            assert_eq!(ws.active_screen, 1);
            (ws.screens[0].id, ws.screens[1].id)
        });

        // Select back to screen 1; screen 2 keeps running.
        mux.select_screen(Some(0), None);
        mux.with_state(|s| assert_eq!(s.workspaces[0].active_screen, 0));

        // Renaming a screen sticks; clearing falls back.
        assert!(mux.rename_screen(screen2, "logs".into()));
        mux.with_state(|s| {
            assert_eq!(s.workspaces[0].screens[1].name.as_deref(), Some("logs"));
        });

        // Focusing a pane in screen 2 activates that screen.
        let p2 = mux.with_state(|s| s.pane_of(s2.id).unwrap());
        assert!(mux.focus_pane(p2));
        mux.with_state(|s| assert_eq!(s.workspaces[0].active_screen, 1));

        // Closing screen 2 keeps the workspace with screen 1.
        assert!(mux.close_screen(screen2).unwrap());
        mux.with_state(|s| {
            let ws = &s.workspaces[0];
            assert_eq!(ws.screens.len(), 1);
            assert_eq!(ws.screens[0].id, screen1);
            assert_eq!(ws.active_screen, 0);
        });
    }

    #[test]
    fn workspaces_and_renames() {
        let mux = test_mux();
        let events = mux.subscribe();
        mux.new_workspace(None, None).unwrap();
        mux.new_workspace(Some("dev".into()), None).unwrap();

        let (ws0, ws1, pane1, surface1) = mux.with_state(|s| {
            assert_eq!(s.workspaces.len(), 2);
            assert_eq!(s.workspaces[0].name, "0");
            assert_eq!(s.workspaces[1].name, "dev");
            assert_eq!(s.active_workspace, 1);
            let pane = s.workspaces[1].screens[0].active_pane;
            let surface = s.panes[&pane].tabs[0];
            (s.workspaces[0].id, s.workspaces[1].id, pane, surface)
        });

        assert!(mux.rename_workspace(ws0, "ops".into()));
        assert!(mux.rename_pane(pane1, "logs".into()));
        assert!(mux.rename_surface(surface1, "api".into()));
        mux.with_state(|s| {
            assert_eq!(s.workspaces[0].name, "ops");
            assert_eq!(s.panes[&pane1].name.as_deref(), Some("logs"));
            assert_eq!(s.surfaces[&surface1].name().as_deref(), Some("api"));
        });
        // Clearing the names falls back to the generated labels.
        assert!(mux.rename_pane(pane1, String::new()));
        assert!(mux.rename_surface(surface1, String::new()));
        mux.with_state(|s| {
            assert_eq!(s.panes[&pane1].name, None);
            assert_eq!(s.surfaces[&surface1].name(), None);
        });

        assert!(mux.close_workspace(ws1));
        mux.with_state(|s| {
            assert_eq!(s.workspaces.len(), 1);
            assert_eq!(s.workspaces[0].id, ws0);
            assert_eq!(s.active_workspace, 0);
        });
        assert!(events.try_iter().count() > 0);
    }

    #[test]
    fn empty_workspace_registry_has_stable_keys_revisions_and_close() {
        let mux = test_mux();
        let events = mux.subscribe();
        let invalid = mux
            .create_empty_workspace(
                Some("invalid".into()),
                Some("frontend-scaling-not-a-uuid".into()),
                None,
            )
            .expect_err("noncanonical workspace key must fail");
        assert_eq!(invalid.to_string(), "workspace key must be a lowercase UUID");
        mux.with_state(|state| {
            assert_eq!(state.workspace_revision, 0);
            assert!(state.workspaces.is_empty());
        });
        let key = "018f6e21-7b70-7e70-8000-000000000001".to_string();
        let first = mux
            .create_empty_workspace(Some("empty".into()), Some(key.clone()), None)
            .expect("create empty workspace");
        assert_eq!(first.key, key);
        assert_eq!(first.index, 0);
        assert_eq!(first.revision, 1);
        mux.with_state(|state| {
            assert_eq!(state.workspace_revision, 1);
            assert_eq!(state.workspaces.len(), 1);
            assert_eq!(state.workspaces[0].key, key);
            assert!(state.workspaces[0].screens.is_empty());
            assert_eq!(state.workspace_index(first.workspace), Some(0));
            assert_eq!(
                state.workspace_by_key(&key).map(|workspace| workspace.id),
                Some(first.workspace)
            );
        });
        let MuxEvent::TreeDelta(added) = events.recv().expect("workspace-added delta") else {
            panic!("expected workspace-added delta");
        };
        assert_eq!(added.kind, TreeDeltaKind::WorkspaceAdded);
        assert_eq!(added.workspace_revision, Some(1));
        assert_eq!(added.entity["key"], key);

        assert!(
            mux.create_empty_workspace(None, Some(first.key.clone()), None)
                .expect_err("duplicate stable key must fail")
                .to_string()
                .contains("already exists")
        );
        let conflict = mux
            .rename_workspace_at_revision(first.workspace, "stale".into(), Some(0))
            .expect_err("stale registry mutation must fail");
        assert_eq!(conflict.to_string(), "workspace revision conflict: expected 0, current 1");
        assert_eq!(
            mux.rename_workspace_at_revision(first.workspace, "renamed".into(), Some(1)).unwrap(),
            Some(2)
        );
        assert_eq!(mux.close_workspace_at_revision(first.workspace, Some(2)).unwrap(), Some(3));
        mux.with_state(|state| {
            assert!(state.workspaces.is_empty());
            assert_eq!(state.workspace_revision, 3);
            assert!(state.workspace_by_id(first.workspace).is_none());
            assert!(state.workspace_by_key(&key).is_none());
        });
        let MuxEvent::TreeDelta(closed) = events.recv().expect("workspace-closed delta") else {
            panic!("expected workspace-closed delta");
        };
        assert_eq!(closed.kind, TreeDeltaKind::WorkspaceClosed);
        assert_eq!(closed.workspace_revision, Some(3));
        assert!(matches!(events.recv().expect("empty event"), MuxEvent::Empty));
    }

    #[test]
    fn empty_workspace_registry_enforces_count_and_string_limits() {
        let mux = test_mux();
        let boundary_key = "k".repeat(WORKSPACE_KEY_MAX_BYTES);
        Mux::validate_workspace_key(&boundary_key).expect("boundary-sized workspace key");
        let key = "018f6e21-7b70-7e70-8000-000000001020".to_string();
        let name = "n".repeat(WORKSPACE_NAME_MAX_BYTES);
        let placement = mux
            .create_empty_workspace(Some(name.clone()), Some(key.clone()), None)
            .expect("boundary-sized workspace fields");
        mux.with_state(|state| {
            let workspace = state.workspace_by_id(placement.workspace).unwrap();
            assert_eq!(workspace.key, key);
            assert_eq!(workspace.name, name);
        });

        let oversized_key = "k".repeat(WORKSPACE_KEY_MAX_BYTES + 1);
        assert_eq!(
            Mux::validate_workspace_key(&oversized_key)
                .expect_err("oversized key must fail")
                .to_string(),
            format!("workspace key exceeds {WORKSPACE_KEY_MAX_BYTES} bytes")
        );
        let oversized_name = "n".repeat(WORKSPACE_NAME_MAX_BYTES + 1);
        assert_eq!(
            mux.create_empty_workspace(Some(oversized_name.clone()), None, None)
                .expect_err("oversized name must fail")
                .to_string(),
            format!("workspace name exceeds {WORKSPACE_NAME_MAX_BYTES} bytes")
        );
        assert_eq!(
            mux.rename_workspace_at_revision(placement.workspace, oversized_name, Some(1))
                .expect_err("oversized rename must fail")
                .to_string(),
            format!("workspace name exceeds {WORKSPACE_NAME_MAX_BYTES} bytes")
        );
        mux.with_state(|state| {
            assert_eq!(state.workspace_revision, 1);
            assert_eq!(state.workspace_by_id(placement.workspace).unwrap().name, name);
        });

        let full_mux = test_mux();
        {
            let mut state = full_mux.state.lock().unwrap();
            for index in 0..WORKSPACE_REGISTRY_LIMIT {
                state.push_workspace(Workspace {
                    id: index as u64 + 1,
                    public_id: WorkspacePublicId::random().unwrap(),
                    key: format!("key-{index}"),
                    name: format!("workspace-{index}"),
                    screens: Vec::new(),
                    active_screen: 0,
                });
            }
        }
        assert_eq!(
            full_mux
                .create_empty_workspace(None, None, None)
                .expect_err("full registry must reject another workspace")
                .to_string(),
            format!("workspace limit reached ({WORKSPACE_REGISTRY_LIMIT})")
        );
        full_mux.with_state(|state| {
            assert_eq!(state.workspaces.len(), WORKSPACE_REGISTRY_LIMIT);
            assert_eq!(state.workspace_revision, 0);
        });
    }

    #[test]
    fn concurrent_workspace_creation_suppresses_stale_empty_event() {
        let mux = test_mux();
        let initial = mux.create_empty_workspace(None, None, None).unwrap();
        let events = mux.subscribe();
        let close_ready = Arc::new(std::sync::Barrier::new(2));
        let resume_close = Arc::new(std::sync::Barrier::new(2));
        *mux.workspace_close_before_empty_check.lock().unwrap() = Some(Arc::new({
            let close_ready = close_ready.clone();
            let resume_close = resume_close.clone();
            move || {
                close_ready.wait();
                resume_close.wait();
            }
        }));

        let close_mux = mux.clone();
        let close = std::thread::spawn(move || {
            close_mux.close_workspace_at_revision(initial.workspace, Some(1)).unwrap()
        });
        close_ready.wait();
        let replacement = mux.create_empty_workspace(None, None, Some(2)).unwrap();
        *mux.workspace_close_before_empty_check.lock().unwrap() = None;
        resume_close.wait();
        assert_eq!(close.join().unwrap(), Some(2));

        let emitted = events.try_iter().collect::<Vec<_>>();
        assert!(emitted.iter().any(|event| matches!(
            event,
            MuxEvent::TreeDelta(TreeDelta { kind: TreeDeltaKind::WorkspaceClosed, .. })
        )));
        assert!(emitted.iter().any(|event| matches!(
            event,
            MuxEvent::TreeDelta(TreeDelta {
                kind: TreeDeltaKind::WorkspaceAdded,
                workspace,
                ..
            }) if *workspace == replacement.workspace
        )));
        assert!(!emitted.iter().any(|event| matches!(event, MuxEvent::Empty)));
        mux.with_state(|state| {
            assert_eq!(state.workspaces.len(), 1);
            assert_eq!(state.workspaces[0].id, replacement.workspace);
        });
    }

    #[test]
    fn registry_active_workspace_changes_emit_resync_barriers() {
        let mux = test_mux();
        let events = mux.subscribe();
        let first = mux.create_empty_workspace(Some("first".into()), None, None).unwrap();
        assert!(matches!(events.recv().unwrap(), MuxEvent::TreeDelta(_)));

        let second = mux.create_empty_workspace(Some("second".into()), None, None).unwrap();
        assert!(matches!(
            events.recv().unwrap(),
            MuxEvent::TreeDelta(TreeDelta { kind: TreeDeltaKind::WorkspaceAdded, .. })
        ));
        assert!(matches!(events.recv().unwrap(), MuxEvent::TreeSelectionChanged));

        mux.close_workspace_at_revision(second.workspace, Some(2)).unwrap();
        assert!(matches!(
            events.recv().unwrap(),
            MuxEvent::TreeDelta(TreeDelta { kind: TreeDeltaKind::WorkspaceClosed, .. })
        ));
        assert!(matches!(events.recv().unwrap(), MuxEvent::TreeSelectionChanged));
        mux.with_state(|state| {
            assert_eq!(state.workspaces[state.active_workspace].id, first.workspace);
        });
    }

    #[test]
    fn reaped_surface_close_preserves_durable_empty_workspace() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
        let events = mux.subscribe();
        let previous_revision = mux.with_state(|state| state.workspace_revision);

        let reaped = mux.state.lock().unwrap().surfaces.remove(&surface.id);
        assert!(reaped.is_some(), "surface must exist before simulating the early-exit race");
        assert!(mux.close_surface(surface.id).unwrap());

        mux.with_state(|state| {
            assert_eq!(state.workspaces.len(), 1);
            assert!(state.workspaces[0].screens.is_empty());
            assert_eq!(state.workspace_revision, previous_revision);
        });
        let deadline = Instant::now() + Duration::from_secs(1);
        loop {
            let remaining = deadline.saturating_duration_since(Instant::now());
            match events.recv_timeout(remaining).expect("screen-close event arrives") {
                MuxEvent::TreeDelta(TreeDelta {
                    kind: TreeDeltaKind::ScreenClosed,
                    workspace_revision: None,
                    ..
                }) => break,
                MuxEvent::Empty => panic!("closing a reaped surface emptied its workspace"),
                _ => {}
            }
        }
        assert!(!events.try_iter().any(|event| matches!(event, MuxEvent::Empty)));
        surface.kill();
    }

    #[test]
    fn reaped_surface_tree_target_close_preserves_durable_empty_workspace() {
        for close_screen in [false, true] {
            let mux = test_mux();
            let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
            let (pane, screen, previous_revision) = mux.with_state(|state| {
                let pane = state.pane_of(surface.id).unwrap();
                let (wi, si) = state.screen_of(pane).unwrap();
                (pane, state.workspaces[wi].screens[si].id, state.workspace_revision)
            });
            let events = mux.subscribe();
            let reaped = mux.state.lock().unwrap().surfaces.remove(&surface.id);
            assert!(reaped.is_some(), "surface must exist before simulating the race");

            if close_screen {
                assert!(mux.close_screen(screen).unwrap());
            } else {
                mux.close_pane(pane).unwrap();
            }

            mux.with_state(|state| {
                assert_eq!(state.workspaces.len(), 1);
                assert!(state.workspaces[0].screens.is_empty());
                assert_eq!(state.workspace_revision, previous_revision);
            });
            let deadline = Instant::now() + Duration::from_secs(1);
            loop {
                let remaining = deadline.saturating_duration_since(Instant::now());
                match events.recv_timeout(remaining).expect("screen-close event arrives") {
                    MuxEvent::TreeDelta(TreeDelta {
                        kind: TreeDeltaKind::ScreenClosed,
                        workspace_revision: None,
                        ..
                    }) => break,
                    MuxEvent::Empty => panic!("closing a reaped tree target emptied its workspace"),
                    _ => {}
                }
            }
            assert!(!events.try_iter().any(|event| matches!(event, MuxEvent::Empty)));
            surface.kill();
        }
    }

    #[test]
    fn persistent_workspace_registry_recovers_exact_identity_order_and_revision() {
        let root = std::env::temp_dir()
            .join(format!("cmux-mux-persistent-{}", crate::workspace_registry::new_uuid_v4()));
        let (registry_id, generation) = {
            let mux = Mux::open_persistent("recover", SurfaceOptions::default(), &root).unwrap();
            let first = mux
                .create_empty_workspace(
                    Some("one".into()),
                    Some("018f6e21-7b70-7e70-8000-000000001004".into()),
                    Some(0),
                )
                .unwrap();
            let second = mux
                .create_empty_workspace(
                    Some("two".into()),
                    Some("018f6e21-7b70-7e70-8000-000000001005".into()),
                    Some(1),
                )
                .unwrap();
            assert_eq!(
                mux.rename_workspace_at_revision(second.workspace, "renamed".into(), Some(2))
                    .unwrap(),
                Some(3)
            );
            assert_eq!(
                mux.move_workspace_at_revision(second.workspace, 0, Some(3)).unwrap(),
                Some((4, true))
            );
            assert_eq!(first.workspace, 1);
            mux.registry_identity()
        };

        let recovered = Mux::open_persistent("recover", SurfaceOptions::default(), &root).unwrap();
        let (recovered_registry_id, recovered_generation) = recovered.registry_identity();
        assert_eq!(recovered_registry_id, registry_id);
        assert_ne!(recovered_generation, generation);
        recovered.with_state(|state| {
            assert_eq!(state.workspace_revision, 4);
            assert_eq!(state.workspaces.len(), 2);
            assert_eq!(state.workspaces[0].key, "018f6e21-7b70-7e70-8000-000000001005");
            assert_eq!(state.workspaces[0].name, "renamed");
            assert_eq!(state.workspaces[1].key, "018f6e21-7b70-7e70-8000-000000001004");
            assert!(state.workspaces.iter().all(|workspace| workspace.screens.is_empty()));
        });
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn persistent_provider_managed_mux_keeps_registry_durable_and_lifecycle_guarded() {
        let root = std::env::temp_dir().join(format!(
            "cmux-mux-persistent-provider-{}",
            crate::workspace_registry::new_uuid_v4()
        ));
        let key = "018f6e21-7b70-7e70-8000-000000001019";
        {
            let mux = Mux::open_persistent_provider_managed(
                "recover-provider",
                SurfaceOptions::default(),
                &root,
                ProviderWorkspaceAuthority::new("persistent-provider-authority-00000001").unwrap(),
            )
            .unwrap();
            let workspace =
                mux.create_empty_workspace(Some("managed".into()), Some(key.into()), None).unwrap();
            let error = mux
                .rename_workspace_at_revision(workspace.workspace, "escaped".into(), None)
                .unwrap_err();
            assert!(error.to_string().contains("provider-managed workspace directly"));
            assert_eq!(
                mux.rename_provider_managed_workspace(
                    workspace.workspace,
                    key,
                    "provider rename".into(),
                )
                .unwrap(),
                Some(2)
            );
            mux.shutdown().unwrap();
        }

        let recovered = Mux::open_persistent_provider_managed(
            "recover-provider",
            SurfaceOptions::default(),
            &root,
            ProviderWorkspaceAuthority::new("replacement-process-authority-00001").unwrap(),
        )
        .unwrap();
        recovered.with_state(|state| {
            assert_eq!(state.workspace_revision, 2);
            assert_eq!(state.workspaces.len(), 1);
            assert_eq!(state.workspaces[0].key, key);
            assert_eq!(state.workspaces[0].name, "provider rename");
        });
        let error = recovered.close_workspace_at_revision(1, None).unwrap_err();
        assert!(error.to_string().contains("provider-managed workspace directly"));
        recovered.shutdown().unwrap();
        drop(recovered);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn restart_marks_reserved_terminal_without_host_record_exited_without_respawn() {
        const TERMINAL: &str = "00000000000040008000000000000001";
        let root = std::env::temp_dir().join(format!(
            "cmux-mux-terminal-crash-window-{}",
            crate::workspace_registry::new_uuid_v4()
        ));
        {
            let mut registry = WorkspaceRegistry::open(&root, "recover-terminal").unwrap();
            registry
                .commit(
                    &WorkspaceMutation::new("workspace", "test").unwrap(),
                    &serde_json::json!({"op":"create-workspace"}),
                    None,
                    Some(0),
                    "workspace-added",
                    "workspace-one",
                    &[RegistryWorkspace {
                        id: 1,
                        public_id: WorkspacePublicId::random().unwrap(),
                        key: "workspace-one".into(),
                        name: "One".into(),
                        group_key: "recover-terminal".into(),
                    }],
                    &serde_json::json!({"workspace":1,"key":"workspace-one"}),
                )
                .unwrap();
            registry
                .commit_terminal(
                    &WorkspaceMutation::new("reserve", "test").unwrap(),
                    &serde_json::json!({"op":"create-terminal","terminal_id":TERMINAL}),
                    None,
                    Some(0),
                    "terminal-reserved",
                    &RegistryTerminal {
                        terminal_id: TERMINAL.into(),
                        workspace_key: "workspace-one".into(),
                        incarnation: None,
                        lifecycle: TerminalLifecycle::Launching,
                        launch_spec: serde_json::json!({"command_present":true}),
                        exit: None,
                    },
                    &serde_json::json!({"terminal_id":TERMINAL}),
                )
                .unwrap();
        }
        let options = SurfaceOptions {
            terminal_host_root: Some(crate::terminal_host_runtime::terminal_host_root(
                &root,
                "recover-terminal",
            )),
            ..SurfaceOptions::default()
        };
        let mux = Mux::open_persistent("recover-terminal", options, &root).unwrap();
        let resolved = mux.resolve_terminal(TERMINAL).unwrap().unwrap();
        assert_eq!(resolved.surface, None);
        assert_eq!(resolved.terminal.lifecycle, TerminalLifecycle::Exited);
        let exit = resolved.terminal.exit.unwrap();
        assert_eq!(exit["outcome"]["kind"], "unknown");
        assert_eq!(exit["outcome"]["reason"], "missing-host-record");
        assert!(exit["exited_at"].as_str().is_some());
        assert_eq!(exit["revision"], "1");
        assert_eq!(resolved.terminal_revision, 2);
        mux.shutdown().unwrap();
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn dead_public_terminal_adoption_wakes_wait_exit() {
        const TERMINAL: &str = "00000000000040008000000000000011";
        const INCARNATION: &str = "10000000000040008000000000000011";
        let mux = test_mux();
        let workspace = mux
            .create_empty_workspace(
                Some("adoption-exit".into()),
                Some("018f6e21-7b70-7e70-8000-000000001011".into()),
                None,
            )
            .unwrap();
        let surface_id =
            mux.seed_running_terminal_for_test(TERMINAL, INCARNATION, &workspace.key).unwrap();
        let surface = mux.surface(surface_id).unwrap();
        assert!(surface.is_dead(), "the adoption fixture must model an already-dead host");
        let public_id = mux
            .workspace_registry
            .lock()
            .unwrap()
            .terminal_resource_id(TERMINAL)
            .unwrap()
            .expect("seeded terminal has a public identity");

        mux.reset_terminal_exit_state_query_count_for_test();
        let waiting_mux = mux.clone();
        let waiting_id = public_id.clone();
        let waiter = std::thread::spawn(move || {
            waiting_mux.wait_for_terminal_exit(&waiting_id, Some(Duration::from_secs(2)))
        });
        let waiting_deadline = Instant::now() + Duration::from_secs(1);
        while mux.terminal_exit_waiter_count_for_test(&public_id) != 1
            || mux.terminal_exit_state_query_count_for_test() != 1
        {
            assert!(Instant::now() < waiting_deadline, "exit wait did not subscribe");
            std::thread::yield_now();
        }

        let mut owner_reservation = mux.reserve_surface_owner().unwrap();
        let error = mux
            .finish_terminal_adoption(TERMINAL, INCARNATION, surface, &mut owner_reservation)
            .expect_err("dead adoption must fail after persisting its exit");
        assert!(error.to_string().contains("exited during adoption"));

        let exited = waiter.join().unwrap().unwrap();
        assert_eq!(exited["state"], "exited");
        assert_eq!(
            exited["outcome"],
            serde_json::json!({
                "kind":"unknown",
                "reason":"host-exited-during-adoption",
            })
        );
        assert_eq!(mux.terminal_exit_state_query_count_for_test(), 2);
        assert_eq!(mux.terminal_exit_waiter_count_for_test(&public_id), 0);
    }

    #[cfg(unix)]
    #[test]
    fn restart_sidecar_restores_exact_wait_exit_and_emits_one_public_event() {
        use std::fs::{File, OpenOptions};
        use std::io::Write;
        use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};

        const TERMINAL: &str = "0000000000004000800000000000002a";
        const INCARNATION: &str = "1000000000004000800000000000002a";
        let root = std::env::temp_dir().join(format!(
            "cmux-mux-terminal-exit-sidecar-{}",
            crate::workspace_registry::new_uuid_v4()
        ));
        let session = "recover-exact-exit";
        let workspace = RegistryWorkspace {
            id: 1,
            public_id: restore_workspace_id(42),
            key: "workspace-exit".into(),
            name: "Exit".into(),
            group_key: session.into(),
        };
        let screen = restore_screen_id(42);
        let pane = restore_pane_id(42);
        let tab = restore_tab_id(42);
        let terminal_public_id = restore_terminal_id(42);
        let terminal = RegistryTerminal {
            terminal_id: TERMINAL.into(),
            workspace_key: workspace.key.clone(),
            incarnation: None,
            lifecycle: TerminalLifecycle::Launching,
            launch_spec: serde_json::json!({"command":["/bin/sh"]}),
            exit: None,
        };
        {
            let mut registry = WorkspaceRegistry::open(&root, session).unwrap();
            registry
                .commit_resource_patch(
                    &WorkspaceMutation::new("seed-terminal-exit", "test").unwrap(),
                    "workspace.create",
                    &serde_json::json!({"fixture":"terminal-exit"}),
                    None,
                    Some(0),
                    &ResourcePatch {
                        changes: vec![
                            ResourceChange::UpsertWorkspace {
                                workspace: workspace.clone(),
                                position: 0,
                                active_screen: Some(screen.clone()),
                            },
                            ResourceChange::UpsertScreen(RegistryScreen {
                                public_id: screen.clone(),
                                workspace_id: workspace.public_id.clone(),
                                position: 0,
                                name: None,
                                layout: RegistryLayoutNode::Leaf { pane: pane.clone() },
                                active_pane: pane.clone(),
                                zoomed_pane: None,
                                auto_layout: None,
                                viewport: RegistryViewport::default(),
                            }),
                            ResourceChange::UpsertPane(RegistryPane {
                                public_id: pane.clone(),
                                screen_id: screen.clone(),
                                name: None,
                                active_tab: Some(tab.clone()),
                                creation_ordinal: 1,
                            }),
                            ResourceChange::UpsertTerminal {
                                public_id: terminal_public_id.clone(),
                                terminal,
                            },
                            ResourceChange::UpsertTab(RegistryTab {
                                public_id: tab.clone(),
                                pane_id: pane.clone(),
                                position: 0,
                                content_id: ContentPublicId::Terminal(terminal_public_id.clone()),
                                name: None,
                                browser_url: None,
                                terminal_id: Some(TERMINAL.into()),
                            }),
                            ResourceChange::SetWorkspaceOrder {
                                workspace_ids: vec![workspace.public_id.clone()],
                            },
                            ResourceChange::SetScreenOrder {
                                workspace_id: workspace.public_id.clone(),
                                screen_ids: vec![screen],
                            },
                            ResourceChange::SetTabOrder { pane_id: pane, tab_ids: vec![tab] },
                            ResourceChange::SetActiveWorkspace {
                                workspace_id: Some(workspace.public_id),
                            },
                        ],
                    },
                    &serde_json::json!({"created":true}),
                    &serde_json::json!([{"kind":"fixture.created"}]),
                )
                .unwrap();
            commit_terminal_lifecycle(
                &mut registry,
                "terminal-ready",
                "seed-running-terminal",
                TERMINAL,
                TerminalLifecycle::Running,
                Some(INCARNATION),
                None,
            )
            .unwrap();
        }

        let host_root = crate::terminal_host_runtime::terminal_host_root(&root, session);
        std::fs::create_dir_all(&host_root).unwrap();
        std::fs::set_permissions(&host_root, std::fs::Permissions::from_mode(0o700)).unwrap();
        let exit = TerminalExit {
            outcome: crate::terminal_host_protocol::TerminalExitOutcome::Signal {
                signal: libc::SIGTERM,
                core_dumped: false,
            },
            exited_at_ms: 1_234_567,
        };
        let sidecar = crate::terminal_host_runtime::TerminalHostExitRecord::new(
            &TerminalHostIdentity { terminal_id: TERMINAL.into(), incarnation: INCARNATION.into() },
            exit,
        );
        let sidecar_path = sidecar.record_path(&host_root);
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&sidecar_path)
            .unwrap();
        file.write_all(&serde_json::to_vec(&sidecar).unwrap()).unwrap();
        file.sync_all().unwrap();
        File::open(&host_root).unwrap().sync_all().unwrap();

        let options =
            SurfaceOptions { terminal_host_root: Some(host_root), ..SurfaceOptions::default() };
        let failing_registry = {
            let registry = WorkspaceRegistry::open(&root, session).unwrap();
            registry.set_resource_patch_failure(true).unwrap();
            registry
        };
        let failure = Mux::from_workspace_registry(
            session.to_string(),
            options.clone(),
            failing_registry,
            ProviderWorkspaceState::default(),
            false,
        )
        .err()
        .expect("injected resource event failure must abort sidecar recovery");
        assert!(failure.to_string().contains("forced resource patch failure"));
        assert!(
            sidecar_path.exists(),
            "a rolled-back SQLite transaction must retain restart evidence"
        );

        let mux = Mux::open_persistent(session, options.clone(), &root).unwrap();
        let waited = mux.wait_for_terminal_exit(&terminal_public_id, Some(Duration::ZERO)).unwrap();
        assert_eq!(waited["state"], "exited");
        assert_eq!(
            waited["outcome"],
            serde_json::json!({
                "kind":"signal",
                "signal":libc::SIGTERM,
                "core_dumped":false,
            })
        );
        assert_eq!(waited["exited_at"], "1234567");
        assert_eq!(waited["revision"], "2");
        assert!(!sidecar_path.exists(), "SQLite commit acknowledges the exact sidecar");
        let events = mux.resource_events_after(1).unwrap();
        assert_eq!(events.batches.len(), 1);
        assert_eq!(events.batches[0].changes.as_array().unwrap().len(), 1);
        let _ = mux.shutdown();
        drop(mux);

        let reopened = Mux::open_persistent(session, options, &root).unwrap();
        assert_eq!(
            reopened.wait_for_terminal_exit(&terminal_public_id, Some(Duration::ZERO)).unwrap(),
            waited
        );
        assert_eq!(reopened.resource_events_after(1).unwrap().batches.len(), 1);
        let _ = reopened.shutdown();
        drop(reopened);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn restart_materializes_exited_terminal_until_explicit_close() {
        const TERMINAL: &str = "0000000000004000800000000000000c";
        const INCARNATION: &str = "1000000000004000800000000000000c";
        let root = std::env::temp_dir().join(format!(
            "cmux-mux-exited-placeholder-{}",
            crate::workspace_registry::new_uuid_v4()
        ));
        {
            let mut registry = WorkspaceRegistry::open(&root, "recover-exited").unwrap();
            registry
                .commit(
                    &WorkspaceMutation::new("workspace", "test").unwrap(),
                    &serde_json::json!({"op":"create-workspace"}),
                    None,
                    Some(0),
                    "workspace-added",
                    "workspace-one",
                    &[RegistryWorkspace {
                        id: 1,
                        public_id: WorkspacePublicId::random().unwrap(),
                        key: "workspace-one".into(),
                        name: "One".into(),
                        group_key: "recover-exited".into(),
                    }],
                    &serde_json::json!({"workspace":1,"key":"workspace-one"}),
                )
                .unwrap();
            let reserved = RegistryTerminal {
                terminal_id: TERMINAL.into(),
                workspace_key: "workspace-one".into(),
                incarnation: None,
                lifecycle: TerminalLifecycle::Launching,
                launch_spec: serde_json::json!({}),
                exit: None,
            };
            commit_terminal_transition(
                &mut registry,
                "terminal-reserved",
                "reserve-terminal",
                &reserved,
            )
            .unwrap();
            commit_terminal_lifecycle(
                &mut registry,
                "terminal-exited",
                "host-exited",
                TERMINAL,
                TerminalLifecycle::Exited,
                Some(INCARNATION),
                Some(serde_json::json!({
                    "outcome":{"kind":"unknown","reason":"persisted-exit"},
                    "exited_at":"1234567",
                    "revision":"0",
                })),
            )
            .unwrap();
        }
        let options = SurfaceOptions {
            terminal_host_root: Some(crate::terminal_host_runtime::terminal_host_root(
                &root,
                "recover-exited",
            )),
            ..SurfaceOptions::default()
        };
        let mux = Mux::open_persistent("recover-exited", options.clone(), &root).unwrap();
        let resolved = mux.resolve_terminal(TERMINAL).unwrap().unwrap();
        assert_eq!(resolved.terminal.lifecycle, TerminalLifecycle::Exited);
        assert_eq!(resolved.terminal.exit.as_ref().unwrap()["outcome"]["reason"], "persisted-exit");
        let surface = resolved.surface.expect("Exited terminal remains addressable");
        let placement = mux
            .with_state(|state| run_placement_for_surface(state, surface))
            .expect("Exited terminal remains in topology");
        assert_eq!(placement.workspace, 1);

        // Duplicate exit observations preserve both the tab and first exit
        // metadata. Only an explicit close removes it and burns the UUID.
        mux.surface_exited(surface);
        let after_exit = mux.resolve_terminal(TERMINAL).unwrap().unwrap();
        assert_eq!(after_exit.surface, Some(surface));
        assert_eq!(after_exit.terminal.exit.unwrap()["outcome"]["reason"], "persisted-exit");
        let closed = mux.close_terminal(TERMINAL, INCARNATION).unwrap();
        assert_eq!(closed.surface, Some(surface));
        let closed = mux.resolve_terminal(TERMINAL).unwrap().unwrap();
        assert_eq!(closed.surface, None);
        assert_eq!(closed.terminal.lifecycle, TerminalLifecycle::Tombstoned);
        mux.shutdown().unwrap();
        drop(mux);

        let reopened = Mux::open_persistent("recover-exited", options, &root).unwrap();
        let closed = reopened.resolve_terminal(TERMINAL).unwrap().unwrap();
        assert_eq!(closed.surface, None);
        assert_eq!(closed.terminal.lifecycle, TerminalLifecycle::Tombstoned);
        reopened.shutdown().unwrap();
        drop(reopened);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn create_move_during_launch_binds_only_latest_canonical_workspace() {
        const TERMINAL: &str = "0000000000004000800000000000000d";
        const INCARNATION: &str = "1000000000004000800000000000000d";
        let mux = test_mux();
        let first = mux
            .create_empty_workspace(None, Some("018f6e21-7b70-7e70-8000-000000001006".into()), None)
            .unwrap();
        let second = mux
            .create_empty_workspace(None, Some("018f6e21-7b70-7e70-8000-000000001007".into()), None)
            .unwrap();
        commit_terminal_transition(
            &mut mux.workspace_registry.lock().unwrap(),
            "terminal-reserved",
            "reserve-terminal",
            &RegistryTerminal {
                terminal_id: TERMINAL.into(),
                workspace_key: first.key,
                incarnation: None,
                lifecycle: TerminalLifecycle::Launching,
                launch_spec: serde_json::json!({}),
                exit: None,
            },
        )
        .unwrap();

        // The GUI move commits while process launch has released the writer
        // lock and before the daemon-local surface exists.
        let moved = mux
            .move_terminal_with_mutation(
                TERMINAL,
                &second.key,
                None,
                None,
                Some(1),
                &WorkspaceMutation::new("move-during-launch", "browser").unwrap(),
            )
            .unwrap();
        assert_eq!(moved.placement, None);
        let (_, ready_revision) = commit_terminal_lifecycle(
            &mut mux.workspace_registry.lock().unwrap(),
            "terminal-ready",
            "terminal-ready",
            TERMINAL,
            TerminalLifecycle::Running,
            Some(INCARNATION),
            None,
        )
        .unwrap();
        assert_eq!(ready_revision, 3);

        let surface = Surface::exited_terminal_placeholder(
            mux.next_id(),
            mux.surface_options.lock().unwrap().clone(),
            Arc::downgrade(&mux),
            TerminalHostIdentity { terminal_id: TERMINAL.into(), incarnation: INCARNATION.into() },
        )
        .unwrap();
        insert_surface_checked(&mux, &mut mux.state.lock().unwrap(), surface.clone()).unwrap();
        let (placement, canonical_workspace, changed) =
            mux.bind_running_terminal_to_canonical_workspace(&surface).unwrap();
        assert!(changed);
        assert_eq!(canonical_workspace, second.key);
        assert_eq!(placement.workspace, second.workspace);
        mux.with_state(|state| {
            assert_eq!(state.pane_of(surface.id), Some(placement.pane));
            assert_eq!(
                state
                    .surfaces
                    .values()
                    .filter_map(|surface| surface.terminal_host_identity())
                    .filter(|identity| identity.terminal_id == TERMINAL)
                    .count(),
                1
            );
        });
    }

    #[test]
    fn late_lifecycle_transition_preserves_latest_canonical_workspace_move() {
        const TERMINAL: &str = "00000000000040008000000000000002";
        const INCARNATION: &str = "10000000000040008000000000000001";
        let mux = test_mux();
        let first = mux
            .create_empty_workspace(None, Some("018f6e21-7b70-7e70-8000-000000001008".into()), None)
            .unwrap();
        let second = mux
            .create_empty_workspace(None, Some("018f6e21-7b70-7e70-8000-000000001009".into()), None)
            .unwrap();
        {
            let mut registry = mux.workspace_registry.lock().unwrap();
            let reserved = RegistryTerminal {
                terminal_id: TERMINAL.into(),
                workspace_key: first.key,
                incarnation: None,
                lifecycle: TerminalLifecycle::Launching,
                launch_spec: serde_json::json!({"command_present":true}),
                exit: None,
            };
            commit_terminal_transition(
                &mut registry,
                "terminal-reserved",
                "reserve-terminal",
                &reserved,
            )
            .unwrap();
            commit_terminal_lifecycle(
                &mut registry,
                "terminal-ready",
                "terminal-ready",
                TERMINAL,
                TerminalLifecycle::Running,
                Some(INCARNATION),
                None,
            )
            .unwrap();
            commit_terminal_workspace(&mut registry, TERMINAL, &second.key).unwrap();
        }
        mux.persist_terminal_exit(TERMINAL, Some(INCARNATION), &TerminalExit::unknown("test"))
            .unwrap();
        let terminal = mux.resolve_terminal(TERMINAL).unwrap().unwrap().terminal;
        assert_eq!(terminal.workspace_key, second.key);
        assert_eq!(terminal.lifecycle, TerminalLifecycle::Exited);
        assert_eq!(terminal.launch_spec, serde_json::json!({"command_present":true}));
    }

    #[test]
    fn stale_move_replay_projects_the_latest_canonical_workspace() {
        const TERMINAL: &str = "00000000000040008000000000000003";
        let mux = test_mux();
        let first = mux
            .create_empty_workspace(None, Some("018f6e21-7b70-7e70-8000-000000001010".into()), None)
            .unwrap();
        let second = mux
            .create_empty_workspace(None, Some("018f6e21-7b70-7e70-8000-000000001011".into()), None)
            .unwrap();
        let third = mux
            .create_empty_workspace(None, Some("018f6e21-7b70-7e70-8000-000000001012".into()), None)
            .unwrap();
        {
            let mut registry = mux.workspace_registry.lock().unwrap();
            commit_terminal_transition(
                &mut registry,
                "terminal-reserved",
                "reserve-terminal",
                &RegistryTerminal {
                    terminal_id: TERMINAL.into(),
                    workspace_key: first.key,
                    incarnation: None,
                    lifecycle: TerminalLifecycle::Launching,
                    launch_spec: serde_json::json!({"command_present":true}),
                    exit: None,
                },
            )
            .unwrap();
        }
        let events = mux.subscribe();
        let first_move = WorkspaceMutation::new("move-one", "browser").unwrap();
        let moved = mux
            .move_terminal_with_mutation(TERMINAL, &second.key, None, None, Some(1), &first_move)
            .unwrap();
        assert_eq!(moved.terminal.workspace_key, second.key);
        let MuxEvent::TerminalRegistryChanged { terminal_revision, .. } = events.recv().unwrap()
        else {
            panic!("expected terminal registry barrier");
        };
        assert_eq!(terminal_revision, 2);
        mux.move_terminal_with_mutation(
            TERMINAL,
            &third.key,
            None,
            None,
            Some(2),
            &WorkspaceMutation::new("move-two", "browser").unwrap(),
        )
        .unwrap();
        let replay = mux
            .move_terminal_with_mutation(TERMINAL, &second.key, None, None, Some(1), &first_move)
            .unwrap();
        assert!(replay.replayed);
        assert_eq!(replay.terminal.workspace_key, third.key);
        assert_eq!(
            mux.resolve_terminal(TERMINAL).unwrap().unwrap().terminal.workspace_key,
            third.key
        );
    }

    #[cfg(unix)]
    #[test]
    fn concurrent_terminal_moves_cannot_project_out_of_commit_order() {
        const TERMINAL: &str = "0000000000004000800000000000000a";
        const INCARNATION: &str = "1000000000004000800000000000000a";
        let mux = test_mux();
        let first = mux
            .create_empty_workspace(None, Some("018f6e21-7b70-7e70-8000-000000001013".into()), None)
            .unwrap();
        let second = mux
            .create_empty_workspace(None, Some("018f6e21-7b70-7e70-8000-000000001014".into()), None)
            .unwrap();
        let third = mux
            .create_empty_workspace(None, Some("018f6e21-7b70-7e70-8000-000000001015".into()), None)
            .unwrap();
        commit_terminal_transition(
            &mut mux.workspace_registry.lock().unwrap(),
            "terminal-reserved",
            "reserve-terminal",
            &RegistryTerminal {
                terminal_id: TERMINAL.into(),
                workspace_key: first.key.clone(),
                incarnation: None,
                lifecycle: TerminalLifecycle::Launching,
                launch_spec: serde_json::json!({}),
                exit: None,
            },
        )
        .unwrap();
        let surface = insert_terminal_identity_surface(&mux, TERMINAL, INCARNATION, &first.key);

        let calls = Arc::new(AtomicUsize::new(0));
        let (entered_tx, entered_rx) = std::sync::mpsc::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        let release_rx = Arc::new(Mutex::new(release_rx));
        mux.set_terminal_move_before_projection(Some(Arc::new(move || {
            if calls.fetch_add(1, Ordering::SeqCst) == 0 {
                entered_tx.send(()).unwrap();
                release_rx.lock().unwrap().recv().unwrap();
            }
        })));

        let moving_to_second = {
            let mux = mux.clone();
            let key = second.key.clone();
            std::thread::spawn(move || {
                mux.move_terminal_with_mutation(
                    TERMINAL,
                    &key,
                    None,
                    None,
                    Some(1),
                    &WorkspaceMutation::new("move-race-one", "browser").unwrap(),
                )
            })
        };
        entered_rx.recv().unwrap();
        let (second_attempted_tx, second_attempted_rx) = std::sync::mpsc::channel();
        let (second_done_tx, second_done_rx) = std::sync::mpsc::channel();
        let moving_to_third = {
            let mux = mux.clone();
            let key = third.key.clone();
            std::thread::spawn(move || {
                second_attempted_tx.send(()).unwrap();
                let result = mux.move_terminal_with_mutation(
                    TERMINAL,
                    &key,
                    None,
                    None,
                    None,
                    &WorkspaceMutation::new("move-race-two", "browser").unwrap(),
                );
                second_done_tx.send(result).unwrap();
            })
        };
        second_attempted_rx.recv().unwrap();
        assert!(second_done_rx.recv_timeout(Duration::from_millis(100)).is_err());
        release_tx.send(()).unwrap();
        assert_eq!(moving_to_second.join().unwrap().unwrap().terminal.workspace_key, second.key);
        assert_eq!(second_done_rx.recv().unwrap().unwrap().terminal.workspace_key, third.key);
        moving_to_third.join().unwrap();
        mux.set_terminal_move_before_projection(None);
        assert_eq!(
            mux.resolve_terminal(TERMINAL).unwrap().unwrap().terminal.workspace_key,
            third.key
        );
        let placement = mux
            .with_state(|state| run_placement_for_surface(state, surface.id))
            .expect("terminal has one final topology binding");
        assert_eq!(placement.workspace, third.workspace);
    }

    #[cfg(unix)]
    #[test]
    fn terminal_move_and_destination_close_have_one_registry_topology_order() {
        const TERMINAL: &str = "0000000000004000800000000000000b";
        const INCARNATION: &str = "1000000000004000800000000000000b";
        let mux = test_mux();
        let first = mux
            .create_empty_workspace(None, Some("018f6e21-7b70-7e70-8000-000000001016".into()), None)
            .unwrap();
        let second = mux
            .create_empty_workspace(None, Some("018f6e21-7b70-7e70-8000-000000001017".into()), None)
            .unwrap();
        commit_terminal_transition(
            &mut mux.workspace_registry.lock().unwrap(),
            "terminal-reserved",
            "reserve-terminal",
            &RegistryTerminal {
                terminal_id: TERMINAL.into(),
                workspace_key: first.key.clone(),
                incarnation: None,
                lifecycle: TerminalLifecycle::Launching,
                launch_spec: serde_json::json!({}),
                exit: None,
            },
        )
        .unwrap();
        let surface = insert_terminal_identity_surface(&mux, TERMINAL, INCARNATION, &first.key);

        let (entered_tx, entered_rx) = std::sync::mpsc::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        let release_rx = Arc::new(Mutex::new(release_rx));
        mux.set_terminal_move_before_projection(Some(Arc::new(move || {
            entered_tx.send(()).unwrap();
            release_rx.lock().unwrap().recv().unwrap();
        })));
        let move_thread = {
            let mux = mux.clone();
            let key = second.key.clone();
            std::thread::spawn(move || {
                mux.move_terminal_with_mutation(
                    TERMINAL,
                    &key,
                    None,
                    None,
                    Some(1),
                    &WorkspaceMutation::new("move-before-close", "browser").unwrap(),
                )
            })
        };
        entered_rx.recv().unwrap();
        let (close_attempted_tx, close_attempted_rx) = std::sync::mpsc::channel();
        let (close_done_tx, close_done_rx) = std::sync::mpsc::channel();
        let close_thread = {
            let mux = mux.clone();
            std::thread::spawn(move || {
                close_attempted_tx.send(()).unwrap();
                close_done_tx
                    .send(mux.close_workspace_at_revision(second.workspace, Some(2)))
                    .unwrap();
            })
        };
        close_attempted_rx.recv().unwrap();
        assert!(close_done_rx.recv_timeout(Duration::from_millis(100)).is_err());
        release_tx.send(()).unwrap();
        assert_eq!(move_thread.join().unwrap().unwrap().terminal.workspace_key, second.key);
        assert_eq!(close_done_rx.recv().unwrap().unwrap(), Some(3));
        close_thread.join().unwrap();
        mux.set_terminal_move_before_projection(None);
        assert_eq!(
            mux.workspace_registry
                .lock()
                .unwrap()
                .terminal_record(TERMINAL)
                .unwrap()
                .unwrap()
                .lifecycle,
            TerminalLifecycle::Tombstoned
        );
        assert!(mux.with_state(|state| state.workspace_by_key(&second.key).is_none()));
        assert_eq!(mux.resolve_terminal(TERMINAL).unwrap().unwrap().surface, None);
        assert!(mux.surface(surface.id).is_none());
    }

    #[test]
    fn move_terminal_to_missing_workspace_fails_without_changing_placement() {
        const TERMINAL: &str = "00000000000040008000000000000004";
        let mux = test_mux();
        let first = mux
            .create_empty_workspace(None, Some("018f6e21-7b70-7e70-8000-000000001018".into()), None)
            .unwrap();
        {
            let mut registry = mux.workspace_registry.lock().unwrap();
            commit_terminal_transition(
                &mut registry,
                "terminal-reserved",
                "reserve-terminal",
                &RegistryTerminal {
                    terminal_id: TERMINAL.into(),
                    workspace_key: first.key.clone(),
                    incarnation: None,
                    lifecycle: TerminalLifecycle::Launching,
                    launch_spec: serde_json::json!({}),
                    exit: None,
                },
            )
            .unwrap();
        }
        let error = mux
            .move_terminal_with_mutation(
                TERMINAL,
                "missing-workspace",
                None,
                None,
                Some(1),
                &WorkspaceMutation::new("move-missing", "browser").unwrap(),
            )
            .unwrap_err();
        assert!(error.to_string().contains("workspace is missing or closed"));
        assert_eq!(
            mux.resolve_terminal(TERMINAL).unwrap().unwrap().terminal.workspace_key,
            first.key
        );
    }

    #[test]
    fn remote_terminal_projection_restores_unrelated_tui_focus() {
        let mux = test_mux();
        let moving = mux.new_workspace(Some("source".into()), None).unwrap();
        let destination = mux.new_workspace(Some("destination".into()), None).unwrap();
        let focused = mux.new_workspace(Some("focused".into()), None).unwrap();
        let (destination_pane, focused_pane) = mux.with_state(|state| {
            (state.pane_of(destination.id).unwrap(), state.pane_of(focused.id).unwrap())
        });
        assert!(mux.focus_pane(focused_pane));
        let before = mux.with_state(current_focus_identity);
        {
            let mut state = mux.state.lock().unwrap();
            let preserved = current_focus_identity(&state);
            assert!(
                move_tab_in_state(&mux, &mut state, moving.id, destination_pane, usize::MAX,).0
            );
            restore_focus_identity(&mut state, preserved);
        }
        assert_eq!(mux.with_state(current_focus_identity), before);
        assert_eq!(mux.with_state(|state| state.pane_of(moving.id)), Some(destination_pane));
    }

    #[test]
    fn concurrent_workspace_commits_publish_in_exact_revision_order() {
        let mux = test_mux();
        let events = mux.subscribe();
        let mut workers = Vec::new();
        for index in 0..16 {
            let mux = mux.clone();
            workers.push(std::thread::spawn(move || {
                mux.create_empty_workspace(
                    Some(format!("workspace-{index}")),
                    Some(format!("00000000-0000-4000-8000-{index:012x}")),
                    None,
                )
                .unwrap()
            }));
        }
        let mut committed =
            workers.into_iter().map(|worker| worker.join().unwrap().revision).collect::<Vec<_>>();
        committed.sort_unstable();
        assert_eq!(committed, (1..=16).collect::<Vec<_>>());

        let mut published = Vec::new();
        while published.len() < 16 {
            match events.recv().unwrap() {
                MuxEvent::TreeDelta(delta) => {
                    published.push(delta.workspace_revision.unwrap());
                }
                MuxEvent::TreeSelectionChanged => {}
                event => panic!("unexpected event: {event:?}"),
            }
        }
        assert_eq!(published, (1..=16).collect::<Vec<_>>());
        mux.with_state(|state| {
            assert_eq!(state.workspace_revision, 16);
            assert_eq!(state.workspaces.len(), 16);
        });
    }

    #[test]
    fn new_tab_materializes_selected_empty_workspace() {
        let mux = test_mux();
        let placement = mux.create_empty_workspace(Some("gui".into()), None, None).unwrap();
        let surface = mux.new_tab(None, Some("/tmp".into()), Some((80, 24))).unwrap();
        assert_eq!(surface.spawn_cwd().as_deref(), Some("/tmp"));
        mux.with_state(|state| {
            assert_eq!(state.workspaces.len(), 1);
            assert_eq!(state.workspaces[0].id, placement.workspace);
            assert_eq!(state.workspaces[0].screens.len(), 1);
            assert_eq!(state.pane_of(surface.id), state.active_pane());
            assert_eq!(state.workspace_revision, 1);
        });
    }

    #[test]
    fn concurrent_new_tabs_materialize_one_empty_workspace_screen() {
        let mux = test_mux();
        let placement = mux.create_empty_workspace(Some("gui".into()), None, None).unwrap();
        let barrier = Arc::new(std::sync::Barrier::new(9));
        let mut threads = Vec::new();
        for _ in 0..8 {
            let mux = mux.clone();
            let barrier = barrier.clone();
            threads.push(std::thread::spawn(move || {
                barrier.wait();
                mux.new_tab(None, None, Some((80, 24))).unwrap()
            }));
        }
        barrier.wait();
        let surfaces = threads.into_iter().map(|thread| thread.join().unwrap()).collect::<Vec<_>>();

        mux.with_state(|state| {
            let workspace = state.workspace_by_id(placement.workspace).unwrap();
            assert_eq!(workspace.screens.len(), 1);
            let pane = workspace.screens[0].active_pane;
            assert_eq!(state.panes[&pane].tabs.len(), surfaces.len());
        });
        for surface in surfaces {
            surface.kill();
        }
    }

    #[test]
    fn concurrent_empty_workspace_terminal_inherits_the_first_terminals_cwd() {
        let mux = test_mux();
        let workspace = mux.create_empty_workspace(Some("shared".into()), None, None).unwrap();
        let first_reserved = Arc::new(AtomicBool::new(false));
        let (first_reserved_tx, first_reserved_rx) = std::sync::mpsc::sync_channel(1);
        let (release_tx, release_rx) = std::sync::mpsc::sync_channel(1);
        let release_rx = Arc::new(Mutex::new(release_rx));
        mux.set_resource_terminal_reservation_hook_for_test(Some(Arc::new({
            let first_reserved = Arc::clone(&first_reserved);
            move |_| {
                if !first_reserved.swap(true, Ordering::SeqCst) {
                    first_reserved_tx.send(()).unwrap();
                    release_rx.lock().unwrap().recv().unwrap();
                }
            }
        })));

        let first = std::thread::spawn({
            let mux = mux.clone();
            move || {
                mux.create_terminal_surface_in_workspace(
                    workspace.workspace,
                    None,
                    Some("/tmp".into()),
                    None,
                    Some((80, 24)),
                )
                .unwrap()
            }
        });
        first_reserved_rx.recv().unwrap();
        let second = std::thread::spawn({
            let mux = mux.clone();
            move || {
                mux.create_terminal_surface_in_workspace(
                    workspace.workspace,
                    None,
                    None,
                    None,
                    Some((80, 24)),
                )
                .unwrap()
            }
        });
        release_tx.send(()).unwrap();

        let (first_surface, _) = first.join().unwrap();
        let (second_surface, _) = second.join().unwrap();
        assert_eq!(first_surface.spawn_cwd().as_deref(), Some("/tmp"));
        assert_eq!(second_surface.spawn_cwd().as_deref(), Some("/tmp"));
        mux.set_resource_terminal_reservation_hook_for_test(None);
        mux.shutdown().unwrap();
    }

    #[test]
    fn workspace_mutation_close_waits_for_targeted_terminal_commit_and_replays() {
        let mux = test_mux();
        let workspace = mux.create_empty_workspace(Some("target".into()), None, None).unwrap();
        let unrelated = mux.create_empty_workspace(Some("unrelated".into()), None, None).unwrap();
        let (reserved_tx, reserved_rx) = std::sync::mpsc::sync_channel(1);
        let (release_tx, release_rx) = std::sync::mpsc::sync_channel(1);
        let release_rx = Arc::new(Mutex::new(release_rx));
        *mux.terminal_create_after_workspace_reservation.lock().unwrap() = Some(Arc::new({
            move || {
                reserved_tx.send(()).unwrap();
                release_rx.lock().unwrap().recv().unwrap();
            }
        }));

        let create = std::thread::spawn({
            let mux = mux.clone();
            move || {
                mux.create_terminal_surface_in_workspace(
                    workspace.workspace,
                    None,
                    None,
                    None,
                    Some((80, 24)),
                )
            }
        });
        reserved_rx.recv().unwrap();
        assert!(mux.workspace_lifecycle(workspace.workspace).try_lock().is_err());
        let unrelated_lifecycle = mux.workspace_lifecycle(unrelated.workspace);
        assert!(unrelated_lifecycle.try_lock().is_ok());

        let (close_started_tx, close_started_rx) = std::sync::mpsc::sync_channel(1);
        let (close_done_tx, close_done_rx) = std::sync::mpsc::sync_channel(1);
        let close_mutation = WorkspaceMutation::new("close-target", "browser").unwrap();
        let close = std::thread::spawn({
            let mux = mux.clone();
            let close_mutation = close_mutation.clone();
            move || {
                close_started_tx.send(()).unwrap();
                let result = mux.close_workspace_with_mutation(
                    Some(workspace.workspace),
                    None,
                    None,
                    Some(2),
                    &close_mutation,
                );
                close_done_tx.send(result).unwrap();
            }
        });
        close_started_rx.recv().unwrap();
        for _ in 0..1_000 {
            std::thread::yield_now();
        }
        assert!(matches!(close_done_rx.try_recv(), Err(std::sync::mpsc::TryRecvError::Empty)));

        release_tx.send(()).unwrap();
        let (surface, placement) = create.join().unwrap().unwrap();
        assert_eq!(placement.workspace, workspace.workspace);
        let result = close_done_rx.recv().unwrap().unwrap();
        assert_eq!(result.workspace, Some(workspace.workspace));
        assert_eq!(result.revision, 3);
        assert!(!result.replayed);
        close.join().unwrap();
        let replay = mux
            .close_workspace_with_mutation(
                Some(workspace.workspace),
                None,
                None,
                Some(2),
                &close_mutation,
            )
            .unwrap();
        assert_eq!(replay.revision, result.revision);
        assert!(replay.replayed);
        *mux.terminal_create_after_workspace_reservation.lock().unwrap() = None;
        surface.kill();
        mux.shutdown().unwrap();
    }

    #[test]
    fn pane_and_screen_close_wait_for_targeted_terminal_commit() {
        for close_screen in [false, true] {
            let mux = test_mux();
            let initial = mux.new_workspace(None, Some((80, 24))).unwrap();
            let (workspace, pane, screen) = mux.with_state(|state| {
                let pane = state.pane_of(initial.id).unwrap();
                let (wi, si) = state.screen_of(pane).unwrap();
                (state.workspaces[wi].id, pane, state.workspaces[wi].screens[si].id)
            });
            let (reserved_tx, reserved_rx) = std::sync::mpsc::sync_channel(1);
            let (release_tx, release_rx) = std::sync::mpsc::sync_channel(1);
            let release_rx = Arc::new(Mutex::new(release_rx));
            mux.set_resource_terminal_reservation_hook_for_test(Some(Arc::new({
                move |_| {
                    reserved_tx.send(()).unwrap();
                    release_rx.lock().unwrap().recv().unwrap();
                }
            })));

            let create = std::thread::spawn({
                let mux = mux.clone();
                move || {
                    mux.create_terminal_surface_in_workspace(
                        workspace,
                        None,
                        None,
                        None,
                        Some((80, 24)),
                    )
                }
            });
            reserved_rx.recv().unwrap();

            let (close_started_tx, close_started_rx) = std::sync::mpsc::sync_channel(1);
            let (close_done_tx, close_done_rx) = std::sync::mpsc::sync_channel(1);
            let close = std::thread::spawn({
                let mux = mux.clone();
                move || {
                    close_started_tx.send(()).unwrap();
                    let result =
                        if close_screen { mux.close_screen(screen) } else { mux.close_pane(pane) };
                    close_done_tx.send(result).unwrap();
                }
            });
            close_started_rx.recv().unwrap();
            for _ in 0..1_000 {
                std::thread::yield_now();
            }
            assert!(matches!(close_done_rx.try_recv(), Err(std::sync::mpsc::TryRecvError::Empty)));

            release_tx.send(()).unwrap();
            let (created, placement) = create.join().unwrap().unwrap();
            assert_eq!(placement.workspace, workspace);
            assert!(close_done_rx.recv().unwrap().unwrap());
            close.join().unwrap();
            mux.with_state(|state| {
                assert_eq!(state.workspaces.len(), 1);
                assert_eq!(state.workspaces[0].id, workspace);
                assert!(state.workspaces[0].screens.is_empty());
            });
            mux.set_resource_terminal_reservation_hook_for_test(None);
            initial.kill();
            created.kill();
            mux.shutdown().unwrap();
        }
    }

    #[test]
    fn key_close_cannot_rebind_a_live_durable_workspace_identity() {
        let mux = test_mux();
        let key = "018f6e21-7b70-7e70-8000-000000001021".to_string();
        let original =
            mux.create_empty_workspace(Some("original".into()), Some(key.clone()), None).unwrap();
        let original_lifecycle = mux.workspace_lifecycle(original.workspace);
        let original_guard = original_lifecycle.lock().unwrap();

        let selector_resolved = Arc::new(AtomicBool::new(false));
        let (resolved_tx, resolved_rx) = std::sync::mpsc::sync_channel(1);
        *mux.workspace_close_after_selector_resolution.lock().unwrap() = Some(Arc::new({
            move || {
                if !selector_resolved.swap(true, Ordering::SeqCst) {
                    resolved_tx.send(()).unwrap();
                }
            }
        }));
        let (close_done_tx, close_done_rx) = std::sync::mpsc::sync_channel(1);
        let close = std::thread::spawn({
            let mux = mux.clone();
            let key = key.clone();
            move || {
                close_done_tx
                    .send(mux.close_workspace_selector_at_revision(None, Some(&key), None))
                    .unwrap();
            }
        });
        resolved_rx.recv().unwrap();

        {
            let mut state = mux.state.lock().unwrap();
            let index = state.workspace_index(original.workspace).unwrap();
            state.remove_workspace(index);
            state.workspace_revision = state.workspace_revision.saturating_add(1);
        }
        let replacement_error =
            mux.create_empty_workspace(Some("replacement".into()), Some(key), None).unwrap_err();
        assert!(replacement_error.to_string().contains("is already bound to public id"));
        drop(original_guard);

        let close_result = close_done_rx.recv().unwrap();
        close.join().unwrap();
        *mux.workspace_close_after_selector_resolution.lock().unwrap() = None;
        assert!(close_result.unwrap_err().to_string().contains("unknown workspace key"));
        mux.shutdown().unwrap();
    }

    #[test]
    fn provider_ownership_handoff_waits_for_an_entered_ordinary_close() {
        let mux = test_mux();
        let workspace = mux
            .create_empty_workspace(
                Some("ordinary".into()),
                Some("018f6e21-7b70-7e70-8000-00000000aa07".into()),
                None,
            )
            .unwrap();
        let entered = Arc::new(AtomicBool::new(false));
        let (entered_tx, entered_rx) = std::sync::mpsc::sync_channel(1);
        let (release_tx, release_rx) = std::sync::mpsc::sync_channel(1);
        let release_rx = Arc::new(Mutex::new(release_rx));
        *mux.workspace_close_after_selector_resolution.lock().unwrap() = Some(Arc::new({
            move || {
                if !entered.swap(true, Ordering::SeqCst) {
                    entered_tx.send(()).unwrap();
                    release_rx.lock().unwrap().recv().unwrap();
                }
            }
        }));

        let close = std::thread::spawn({
            let mux = mux.clone();
            move || mux.close_workspace_at_revision(workspace.workspace, None)
        });
        entered_rx.recv().unwrap();

        let (marked_tx, marked_rx) = std::sync::mpsc::sync_channel(1);
        let mark = std::thread::spawn({
            let mux = mux.clone();
            move || {
                mux.mark_workspaces_provider_managed_internal();
                marked_tx.send(()).unwrap();
            }
        });
        for _ in 0..1_000 {
            std::thread::yield_now();
        }
        assert!(matches!(marked_rx.try_recv(), Err(std::sync::mpsc::TryRecvError::Empty)));

        release_tx.send(()).unwrap();
        assert_eq!(close.join().unwrap().unwrap(), Some(2));
        marked_rx.recv().unwrap();
        mark.join().unwrap();

        let managed = mux
            .create_empty_workspace(
                Some("managed".into()),
                Some("018f6e21-7b70-7e70-8000-00000000aa02".into()),
                None,
            )
            .unwrap();
        assert!(!mux.rename_workspace(managed.workspace, "raw rename".into()));
        assert!(!mux.close_workspace(managed.workspace));

        *mux.workspace_close_after_selector_resolution.lock().unwrap() = None;
        mux.shutdown().unwrap();
    }

    #[test]
    fn create_terminal_targets_inactive_empty_workspace() {
        let mux = test_mux();
        let target = mux.create_empty_workspace(Some("target".into()), None, None).unwrap();
        let active = mux.create_empty_workspace(Some("active".into()), None, None).unwrap();
        let placement = mux
            .create_terminal_in_workspace(target.workspace, None, None, None, Some((80, 24)))
            .unwrap();
        mux.with_state(|state| {
            assert_eq!(state.active_workspace, 1);
            assert_eq!(state.workspaces[1].id, active.workspace);
            assert!(state.workspaces[1].screens.is_empty());
            assert_eq!(placement.workspace, target.workspace);
            assert_eq!(state.workspaces[0].screens.len(), 1);
            assert_eq!(state.pane_of(placement.surface), Some(placement.pane));
            assert_eq!(state.workspace_revision, 2);
        });
    }

    #[test]
    fn create_terminal_in_existing_pane_emits_selection_resync() {
        let mux = test_mux();
        let initial = mux.new_workspace(None, Some((80, 24))).unwrap();
        let workspace = mux.with_state(|state| state.workspaces[0].id);
        let events = mux.subscribe();

        let placement =
            mux.create_terminal_in_workspace(workspace, None, None, None, Some((80, 24))).unwrap();

        assert_ne!(placement.surface, initial.id);
        let deadline = Instant::now() + Duration::from_secs(1);
        let mut saw_added = false;
        loop {
            let remaining = deadline.saturating_duration_since(Instant::now());
            match events.recv_timeout(remaining).expect("tab events arrive before timeout") {
                MuxEvent::TreeDelta(TreeDelta {
                    kind: TreeDeltaKind::TabAdded, surface, ..
                }) if surface == Some(placement.surface) => saw_added = true,
                MuxEvent::TreeSelectionChanged if saw_added => break,
                MuxEvent::TreeSelectionChanged => {
                    panic!("selection resync arrived before the tab-added delta")
                }
                _ => {}
            }
        }
    }

    #[test]
    fn run_materializes_active_empty_workspace() {
        let mux = test_mux();
        let placement = mux
            .create_empty_workspace(
                Some("gui".into()),
                Some("018f6e21-7b70-7e70-8000-000000001019".into()),
                None,
            )
            .unwrap();
        let run = mux
            .run_command_surface(
                vec!["/bin/echo".into(), "ready".into()],
                None,
                false,
                Some("/tmp".into()),
                Some("runner".into()),
                Some((80, 24)),
            )
            .unwrap();

        assert_eq!(run.workspace, placement.workspace);
        mux.with_state(|state| {
            assert_eq!(state.workspaces.len(), 1);
            assert_eq!(state.workspaces[0].id, placement.workspace);
            assert_eq!(state.workspaces[0].screens.len(), 1);
            assert_eq!(state.workspace_revision, 1);
        });
        mux.shutdown().unwrap();
    }

    #[test]
    fn run_new_workspace_accepts_a_stable_caller_key() {
        let mux = test_mux();
        let key = "019c0000-0000-7000-8000-000000000001".to_string();
        let run = mux
            .run_command_surface_with_options(
                vec!["/bin/echo".into(), "ready".into()],
                RunCommandOptions {
                    pane: None,
                    new_workspace: true,
                    workspace_key: Some(key.clone()),
                    cwd: Some("/tmp".into()),
                    name: Some("cloud-workspace".into()),
                    size: Some((80, 24)),
                },
            )
            .unwrap();

        mux.with_state(|state| {
            let workspace = state.workspace_by_key(&key).expect("workspace uses caller key");
            assert_eq!(workspace.id, run.workspace);
            assert_eq!(workspace.name, "cloud-workspace");
        });
        let duplicate = mux
            .run_command_surface_with_options(
                vec!["/bin/echo".into(), "duplicate".into()],
                RunCommandOptions {
                    pane: None,
                    new_workspace: true,
                    workspace_key: Some(key),
                    cwd: None,
                    name: None,
                    size: Some((80, 24)),
                },
            )
            .expect_err("duplicate stable key must fail");
        assert!(duplicate.to_string().contains("already exists"));
        mux.with_state(|state| assert_eq!(state.workspaces.len(), 1));
        mux.shutdown().unwrap();
    }

    #[test]
    fn new_browser_tab_materializes_selected_empty_workspace() {
        let mux = test_mux();
        let target = mux.create_empty_workspace(Some("browser".into()), None, None).unwrap();
        let surface = mux.new_browser_tab("about:blank".into(), None, Some((80, 24))).unwrap();

        mux.with_state(|state| {
            assert_eq!(state.workspaces.len(), 1);
            assert_eq!(state.workspaces[0].id, target.workspace);
            assert_eq!(state.workspaces[0].screens.len(), 1);
            assert_eq!(state.pane_of(surface.id), Some(state.workspaces[0].screens[0].active_pane));
            assert_eq!(state.workspace_revision, 1);
        });
        mux.shutdown().unwrap();
    }

    #[test]
    fn concurrent_browser_tabs_materialize_one_empty_workspace_screen() {
        let mux = test_mux();
        let target = mux.create_empty_workspace(Some("browser".into()), None, None).unwrap();
        let barrier = Arc::new(std::sync::Barrier::new(9));
        let mut threads = Vec::new();
        for index in 0..8 {
            let mux = mux.clone();
            let barrier = barrier.clone();
            threads.push(std::thread::spawn(move || {
                barrier.wait();
                mux.new_browser_tab(format!("about:blank#{index}"), None, Some((80, 24)))
            }));
        }
        barrier.wait();
        let surfaces = threads
            .into_iter()
            .map(|thread| thread.join().unwrap().expect("concurrent browser creation"))
            .collect::<Vec<_>>();

        mux.with_state(|state| {
            let workspace = state.workspace_by_id(target.workspace).unwrap();
            assert_eq!(workspace.screens.len(), 1);
            let pane = workspace.screens[0].active_pane;
            assert_eq!(state.panes[&pane].tabs.len(), surfaces.len());
        });
        mux.shutdown().unwrap();
    }

    #[test]
    fn browser_tab_in_existing_workspace_pane_emits_selection_resync() {
        let mux = test_mux();
        let workspace = mux.create_empty_workspace(None, None, None).unwrap();
        let first = mux
            .create_browser_surface_in_workspace(
                workspace.workspace,
                "about:blank#first".into(),
                Some((80, 24)),
                None,
            )
            .unwrap();
        let events = mux.subscribe();

        let second = mux
            .create_browser_surface_in_workspace(
                workspace.workspace,
                "about:blank#second".into(),
                Some((80, 24)),
                None,
            )
            .unwrap();

        let deadline = Instant::now() + Duration::from_secs(1);
        let mut saw_added = false;
        loop {
            let remaining = deadline.saturating_duration_since(Instant::now());
            let event = events.recv_timeout(remaining).expect("tab events arrive before timeout");
            match event {
                MuxEvent::TreeDelta(TreeDelta {
                    kind: TreeDeltaKind::TabAdded, surface, ..
                }) if surface == Some(second.id) => saw_added = true,
                MuxEvent::TreeSelectionChanged if saw_added => break,
                MuxEvent::TreeSelectionChanged => {
                    panic!("selection resync arrived before the tab-added delta")
                }
                _ => {
                    // The browser worker may emit state telemetry between the
                    // synchronous tree events. It does not affect their order.
                }
            }
        }
        first.kill();
        second.kill();
    }

    #[test]
    fn concurrent_browser_and_terminal_share_empty_workspace_screen() {
        let mux = test_mux();
        let target = mux.create_empty_workspace(Some("mixed".into()), None, None).unwrap();
        let barrier = Arc::new(std::sync::Barrier::new(3));
        let browser = {
            let mux = mux.clone();
            let barrier = barrier.clone();
            std::thread::spawn(move || {
                barrier.wait();
                mux.new_browser_tab("about:blank".into(), None, Some((80, 24)))
            })
        };
        let terminal = {
            let mux = mux.clone();
            let barrier = barrier.clone();
            std::thread::spawn(move || {
                barrier.wait();
                mux.create_terminal_in_workspace(target.workspace, None, None, None, Some((80, 24)))
            })
        };
        barrier.wait();
        let browser = browser.join().unwrap().expect("concurrent browser creation");
        let terminal = terminal.join().unwrap().expect("concurrent terminal creation");

        mux.with_state(|state| {
            let workspace = state.workspace_by_id(target.workspace).unwrap();
            assert_eq!(workspace.screens.len(), 1);
            let pane = workspace.screens[0].active_pane;
            assert_eq!(state.panes[&pane].tabs.len(), 2);
            assert_eq!(state.pane_of(browser.id), Some(pane));
            assert_eq!(state.pane_of(terminal.surface), Some(pane));
        });
        mux.shutdown().unwrap();
    }

    #[test]
    fn move_workspace_reorders_and_tracks_active_workspace() {
        let mux = test_mux();
        let events = mux.subscribe();
        mux.new_workspace(Some("one".into()), None).unwrap();
        mux.new_workspace(Some("two".into()), None).unwrap();
        mux.new_workspace(Some("three".into()), None).unwrap();
        let (ws1, ws2, ws3) =
            mux.with_state(|s| (s.workspaces[0].id, s.workspaces[1].id, s.workspaces[2].id));

        assert_eq!(mux.move_workspace_at_revision(ws3, 2, Some(3)).unwrap(), Some((3, false)));
        assert!(!mux.move_workspace(ws3, 2));
        assert!(mux.move_workspace(ws3, 0));
        let mut deltas = events.try_iter().filter_map(|event| match event {
            MuxEvent::TreeDelta(delta) => Some(delta),
            _ => None,
        });
        let moved = deltas
            .find(|delta| delta.kind == TreeDeltaKind::WorkspaceMoved)
            .expect("workspace-moved delta");
        assert_eq!(moved.workspace, ws3);
        assert_eq!(moved.index, Some(0));
        assert_eq!(moved.workspace_revision, Some(4));
        mux.with_state(|s| {
            assert_eq!(
                s.workspaces.iter().map(|ws| ws.id).collect::<Vec<_>>(),
                vec![ws3, ws1, ws2]
            );
            assert_eq!(s.active_workspace, 0);
            assert_eq!(s.workspace_index(ws3), Some(0));
            assert_eq!(s.workspace_index(ws1), Some(1));
            assert_eq!(s.workspace_index(ws2), Some(2));
        });

        assert!(mux.move_workspace(ws1, 99));
        mux.with_state(|s| {
            assert_eq!(
                s.workspaces.iter().map(|ws| ws.id).collect::<Vec<_>>(),
                vec![ws3, ws2, ws1]
            );
            assert_eq!(s.active_workspace, 0);
            assert_eq!(s.workspace_index(ws1), Some(2));
        });
    }

    #[test]
    fn move_workspace_right_uses_insertion_index() {
        let mux = test_mux();
        mux.new_workspace(Some("one".into()), None).unwrap();
        mux.new_workspace(Some("two".into()), None).unwrap();
        mux.new_workspace(Some("three".into()), None).unwrap();
        let (ws1, ws2, ws3) = mux.with_state(|state| {
            (state.workspaces[0].id, state.workspaces[1].id, state.workspaces[2].id)
        });

        assert_eq!(mux.move_workspace_at_revision(ws1, 1, Some(3)).unwrap(), Some((3, false)));
        mux.with_state(|state| {
            assert_eq!(
                state.workspaces.iter().map(|workspace| workspace.id).collect::<Vec<_>>(),
                vec![ws1, ws2, ws3]
            );
        });

        assert_eq!(mux.move_workspace_at_revision(ws1, 2, Some(3)).unwrap(), Some((4, true)));
        mux.with_state(|state| {
            assert_eq!(
                state.workspaces.iter().map(|workspace| workspace.id).collect::<Vec<_>>(),
                vec![ws2, ws1, ws3]
            );
        });

        assert_eq!(mux.move_workspace_at_revision(ws1, 3, Some(4)).unwrap(), Some((5, true)));
        mux.with_state(|state| {
            assert_eq!(
                state.workspaces.iter().map(|workspace| workspace.id).collect::<Vec<_>>(),
                vec![ws2, ws3, ws1]
            );
        });
    }

    #[cfg(unix)]
    #[test]
    fn live_authority_install_and_rotation_preserve_open_pty() {
        const MUX_GENERATION: &str = "0123456789abcdef0123456789abcdef";
        const AUTHORITY_ONE: &str = "live-authority-one-00000000000000000001";
        const AUTHORITY_TWO: &str = "live-authority-two-00000000000000000002";

        fn wait_for_text(surface: &Surface, needle: &str) {
            let deadline = Instant::now() + Duration::from_secs(5);
            loop {
                let text =
                    surface.with_terminal(|terminal| terminal.plain_text()).unwrap().unwrap();
                if text.contains(needle) {
                    return;
                }
                assert!(Instant::now() < deadline, "PTY did not emit {needle:?}; output: {text:?}");
                std::thread::sleep(Duration::from_millis(20));
            }
        }

        let mux = Mux::new_provider_managed_pending(
            "authority-pty-test",
            SurfaceOptions::default(),
            MUX_GENERATION,
        )
        .unwrap();
        let workspace = mux.create_empty_workspace(Some("pty".into()), None, None).unwrap();
        let (surface, _) = mux
            .create_terminal_surface_in_workspace(
                workspace.workspace,
                Some(vec![
                    "sh".into(),
                    "-c".into(),
                    "while IFS= read -r line; do printf 'authority-test:%s\\n' \"$line\"; done"
                        .into(),
                ]),
                None,
                None,
                Some((80, 24)),
            )
            .unwrap();
        let process_id = surface.process_id();
        surface.write_bytes(b"before\n").unwrap();
        wait_for_text(&surface, "authority-test:before");

        mux.install_or_rotate_provider_workspace_authority(
            MUX_GENERATION,
            0,
            41,
            ProviderWorkspaceAuthority::new(AUTHORITY_ONE).unwrap(),
        )
        .unwrap();
        mux.install_or_rotate_provider_workspace_authority(
            MUX_GENERATION,
            41,
            42,
            ProviderWorkspaceAuthority::new(AUTHORITY_TWO).unwrap(),
        )
        .unwrap();

        surface.write_bytes(b"after\n").unwrap();
        wait_for_text(&surface, "authority-test:after");
        assert_eq!(surface.process_id(), process_id);
        assert!(!surface.is_dead());
        mux.shutdown().unwrap();
    }

    #[test]
    fn authority_rotation_waits_for_an_authorized_lifecycle_mutation() {
        const MUX_GENERATION: &str = "0123456789abcdef0123456789abcdef";
        const AUTHORITY_ONE: &str = "locked-authority-one-0000000000000000001";
        const AUTHORITY_TWO: &str = "locked-authority-two-0000000000000000002";

        let mux = Mux::new_provider_managed_pending_for_test(
            "authority-lock-test",
            SurfaceOptions::default(),
            MUX_GENERATION,
        );
        mux.install_or_rotate_provider_workspace_authority(
            MUX_GENERATION,
            0,
            1,
            ProviderWorkspaceAuthority::new(AUTHORITY_ONE).unwrap(),
        )
        .unwrap();
        let workspace = mux.create_empty_workspace(Some("managed".into()), None, None).unwrap();
        let (locked_tx, locked_rx) = std::sync::mpsc::sync_channel(1);
        let (release_tx, release_rx) = std::sync::mpsc::sync_channel(1);
        let release_rx = Arc::new(Mutex::new(release_rx));
        *mux.workspace_close_after_selector_resolution.lock().unwrap() =
            Some(Arc::new(move || {
                locked_tx.send(()).unwrap();
                release_rx.lock().unwrap().recv().unwrap();
            }));

        let close = std::thread::spawn({
            let mux = mux.clone();
            let key = workspace.key.clone();
            move || {
                mux.close_provider_managed_workspace_authorized(
                    workspace.workspace,
                    &key,
                    AUTHORITY_ONE,
                )
                .unwrap()
            }
        });
        locked_rx.recv().unwrap();
        let (started_tx, started_rx) = std::sync::mpsc::sync_channel(1);
        let (rotated_tx, rotated_rx) = std::sync::mpsc::sync_channel(1);
        let rotate = std::thread::spawn({
            let mux = mux.clone();
            move || {
                started_tx.send(()).unwrap();
                let result = mux.install_or_rotate_provider_workspace_authority(
                    MUX_GENERATION,
                    1,
                    2,
                    ProviderWorkspaceAuthority::new(AUTHORITY_TWO).unwrap(),
                );
                rotated_tx.send(()).unwrap();
                result
            }
        });
        started_rx.recv().unwrap();
        assert!(rotated_rx.recv_timeout(Duration::from_millis(50)).is_err());
        release_tx.send(()).unwrap();
        assert_eq!(close.join().unwrap(), Some(2));
        rotate.join().unwrap().unwrap();
        rotated_rx.recv().unwrap();
        mux.authorize_provider_workspace_authority(AUTHORITY_TWO).unwrap();
        *mux.workspace_close_after_selector_resolution.lock().unwrap() = None;
    }
}

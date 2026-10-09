//! The multiplexer: owns the session [`State`] and every surface runtime,
//! and broadcasts [`MuxEvent`]s to subscribed frontends.

mod agent_hook_errors;
mod agent_reports;
mod agent_roster_fold;
mod agent_roster_restore;
mod browser_create;
mod browser_providers;
mod browser_tab_create;
mod closed_workspace_replay;
#[cfg(test)]
mod legacy_actor_test_wrappers;
#[cfg(test)]
mod test_actor_wrappers;
mod test_hooks;
mod topology_edit;
mod topology_ops;
pub(crate) use browser_tab_create::{
    FRONTEND_BROWSER_ACTIVATE_CAPABILITY, FRONTEND_BROWSER_INSERT_AFTER_CAPABILITY,
    FrontendTabPlacement, frontend_fields as frontend_browser_fields,
};
pub(crate) mod app_terminals;
mod cell_pixels;
mod client_resize;
mod cloud_conversations;
mod construct;
mod conversations;
mod deadline_fanout;
#[cfg(test)]
use deadline_fanout::DeadlineCompletion;
use deadline_fanout::{
    CELL_PIXEL_FANOUT_MAX_WORKERS, DeadlineFanoutPool, DeadlineMapResult, DeadlinePending,
    bounded_deadline_map,
};
mod dock_columns;
mod event_emit;
mod exit_settle;
mod frontend_projection;
mod host_close;
#[cfg(all(test, unix))]
mod host_death_tests;
mod idle_close;
mod journal;
mod journal_maintenance;
mod journal_plugin_host;
mod journal_retention;
mod kitty_budget;
mod kitty_reservation;
use kitty_reservation::{kitty_image_limits_exceed, kitty_image_limits_within};
mod agent_types;
pub use agent_types::{AgentRecord, AgentSource, AgentState};
use agent_types::{
    AgentReportOrigin, AgentReportTarget, AgentRosterHost, TerminalAgentRecord,
    agent_hook_notification, agent_provider_identity, agent_state_for_hook_kind,
    legacy_hook_session_id, parse_projection_agent_state, published_agent_session_id,
};
mod events;
pub(crate) mod layout_invariants;
mod layout_ratio_error;
mod layout_types;
mod lifecycle;
pub use layout_types::{
    AppliedLayout, AppliedPane, Direction, LayoutLeafSpec, LayoutSpec, LayoutUndoError,
    LayoutUndoResult, ViewportWidthError, ZoomMode, ZoomState,
};
mod layout_undo_commit;
pub use events::{GraphicsStatus, MachineUsage, MuxEvent, TreeDelta, TreeDeltaKind};
mod notification_types;
mod notifications;
pub use notification_types::{
    NotificationEvent, NotificationSource, ResourceNotification, SurfaceNotification,
};
mod notification_level;
pub use notification_level::NotificationLevel;
mod pairing_requests;
mod personal;
mod presentation;
mod provider_authority;
pub(crate) use provider_authority::ProviderWorkspaceState;
pub use provider_authority::{
    ProviderWorkspaceAuthority, ProviderWorkspaceAuthorityStatus,
    ProviderWorkspaceAuthorityUpdateError,
};
use provider_authority::{constant_time_eq, validate_mux_generation};
mod public_projections;
mod registry_viewport;
mod resource_content;
mod resource_effects;
mod resource_tab_deltas;
#[cfg(test)]
mod resource_tab_deltas_tests;
mod resource_topology;
mod resource_workspace;
mod rows;
mod screen_changed;
pub(crate) mod screen_groups;
mod signaled_mutex;
pub(crate) use signaled_mutex::SignaledMutex;
mod session_paths;
mod shell_history_feed;
mod sidebar_plugin;
mod surface_spawn;
pub(crate) mod tab_drag;
pub(crate) mod tab_groups;
pub(crate) mod tab_strip;
mod tab_workspace_name;
mod time;
pub(crate) use time::now_ms;

pub(crate) use crate::state::{PersonalChange, ScreenChange, WorkspaceStatusChange};
pub(crate) use tab_strip::StripRequest;
mod loss_causes;
mod orphan_hosts;
mod pending_terminals;
mod terminal_adoption;
pub(crate) mod terminal_archive;
mod terminal_catalog_index;
mod terminal_close;
mod terminal_create;
mod terminal_defaults;
mod terminal_directory;
mod terminal_lifecycle_commit;
use terminal_lifecycle_commit::commit_terminal_lifecycle;
mod terminal_exit;
mod terminal_exit_wait;
mod terminal_host_link;
mod terminal_move_topology;
mod terminal_progress;
mod terminal_reap;
#[cfg(unix)]
mod terminal_rehost;
mod terminal_relaunch;
mod terminal_respawn;
mod terminal_sizing;
mod terminal_work;
mod topology_result;
mod tree_close;
mod workspace_create;
mod workspace_identity;
mod workspace_rename;

use agent_hook_errors::{
    AGENT_HOOK_RETRY_ERROR, AgentHookTerminalGone, AgentHookTerminalUnavailable,
    agent_hook_retry_class, agent_hook_terminal_gone,
};

pub use dock_columns::{
    ColumnDockError, ColumnDockOutcome, PERMANENT_COLUMN_CODE, parse_column_dock,
};
pub(crate) use dock_columns::{ensure_permanent_columns_kept, permanent_columns};
pub use idle_close::{IDLE_CLOSE_REAP_INTERVAL, IdleTerminalReaper, start_idle_terminal_reaper};
pub use layout_ratio_error::LayoutRatioError;
pub use presentation::{
    PendingTerminal, TabDirectory, TabNotificationAck, TabPinChange, TreeDecorations,
    WorkspaceGroupChange,
};
pub(crate) use resource_content::ResourceEffectProjection;
pub(crate) use resource_topology::{BatchCloseOutcome, BatchCloseTarget, CloseReason};
pub use rows::{RowHeightsOutcome, RowsError};
pub(crate) use screen_groups::workspace_screen_groups;
pub use screen_groups::{
    ScreenDestination, ScreenGroupOutcome, ScreenMoveOutcome, ScreenSpec, WorkspaceScreenGroup,
};
use tab_drag::restore_dragged_tab;
pub use tab_drag::{ColumnMove, SplitRespawn, TabDragOutcome, TabDropEdge};
pub(crate) use tab_groups::{PaneTabGroup, pane_tab_groups};
pub use tab_groups::{TabGroupDestination, TabGroupOutcome};
pub use terminal_reap::{
    DEFAULT_TERMINAL_REAP_GRACE, MAX_TERMINAL_REAP_GRACE, TerminalReaper, start_terminal_reaper,
    validate_terminal_reap_grace,
};

use public_projections::{RestoredPublicProjections, restore_public_projections};
use registry_viewport::restore_registry_viewport;
use std::collections::{BTreeSet, HashMap, HashSet, VecDeque};
use std::fmt;
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc::{Receiver, SyncSender};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, OnceLock, PoisonError, Weak};
use std::time::{Duration, Instant};
use topology_result::persist_public_topology_result;

use anyhow::Context;
use ghostty_vt::KittyGraphicsLimits;
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};

use crate::Actor;
use crate::browser::{self, BrowserBootstrap, BrowserRuntime};
use crate::browser_provider::{
    BrowserProviderRegistration, BrowserProviderRegistry, BrowserProviderSnapshot,
    BrowserProviderTargetLease,
};
use crate::event_bus::{MuxEventBroadcaster, MuxEventReceiver};
use crate::journal_reducers::{DirectHookTransition, HookFence, JournalHookTransition};
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
    ScreenPublicId, Selector, SessionPublicId, SidebarViewPublicId, SplitPublicId, TabPublicId,
    TabResourceIdentity, TerminalPublicId, WorkspacePublicId,
};
use crate::resource_mutation::{ResourceMutationMetrics, ResourceMutationPlan};
use crate::resource_selector::{
    ResolvedResourceSlots, ResourceSelectorContext, resolve_resource_selectors,
};
use crate::sizing_policy::{
    TerminalDeviceKind, TerminalGridSize, TerminalSizingEngine, TerminalSizingParticipant,
    TerminalSizingPolicy, TerminalSizingReason, TerminalSizingState,
};
use crate::surface::{DefaultColors, Surface, SurfaceOptions};
use crate::terminal_end::TerminalEnd;
use crate::terminal_host::TerminalId;
#[cfg(test)]
use crate::terminal_host_protocol::TerminalExit;
use crate::terminal_host_runtime::TerminalHostIdentity;
#[cfg(unix)]
use crate::terminal_host_runtime::TerminalHostLiveness;
use crate::workspace_registry::{
    AgentHookPendingFailure, FrontendProjection, ProjectionCommit,
    RESOURCE_API_FRONTEND_PROJECTION_SCHEMA_VERSION, RegistryBrowser, RegistryBrowserReconnect,
    RegistryCommit, RegistryLayoutNode, RegistryPane, RegistrySnapshot, RegistryTab,
    RegistryTerminal, RegistryViewport, RegistryWorkspace, ResourceChange, ResourceEffectOutcome,
    ResourceEffectPreparation, ResourcePatch, ResourcePatchCommit, ResourceTopologySnapshot,
    ResourceWorkspaceLedger, TerminalLifecycle, TerminalOnExit, TerminalRegistrySnapshot,
    WorkspaceMutation, WorkspaceRegistry,
};
use crate::{
    PairingChallenge, PairingDecision, PairingError, PaneId, ScreenId, SplitDir, SplitId,
    SurfaceId, SurfaceKind, WorkspaceId,
};

pub type SurfaceResizeReporter = Arc<dyn Fn(SurfaceId, (u16, u16), Option<u64>) + Send + Sync>;

/// Receives diagnostics that must not be written to a frontend's terminal.
///
/// The core can report from reconnect worker threads while a client owns a
/// raw terminal. The frontend supplies a durable sink, such as its client
/// log, so the core does not need to know how diagnostics are persisted.
pub type DiagnosticReporter = Arc<dyn Fn(&str) + Send + Sync + 'static>;

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
type WorkspaceDeltaBeforeEmitHook = Arc<dyn Fn(u64) + Send + Sync>;
#[cfg(test)]
type TerminalReservationHook = Arc<dyn Fn(&str) + Send + Sync>;
type RestoredViewport = (std::collections::BTreeMap<SplitId, f32>, Option<f32>, Vec<LayoutColumn>);

/// Startup diagnostics kept until the frontend installs its sink.
const MAX_PENDING_DIAGNOSTICS: usize = 8;
const TERMINAL_DIMENSION_MAX: u16 = 10_000;
const WORKSPACE_REGISTRY_LIMIT: usize = 4_096;
const WORKSPACE_KEY_MAX_BYTES: usize = 256;
const WORKSPACE_NAME_MAX_BYTES: usize = 1_024;
const CELL_PIXEL_RETRY_INITIAL: Duration = Duration::from_millis(25);
const CELL_PIXEL_RETRY_MAX: Duration = Duration::from_millis(250);
const CELL_PIXEL_RETRY_MAX_ATTEMPTS: u8 = 4;
const KITTY_IMAGE_BUDGET_RETRY_INITIAL: Duration = Duration::from_millis(25);
const KITTY_IMAGE_BUDGET_RETRY_MAX: Duration = Duration::from_secs(1);
const KITTY_IMAGE_BUDGET_RETRY_MAX_ATTEMPTS: u32 = 4;
const TERMINAL_HOST_CLOSE_WAIT: Duration = Duration::from_secs(4);
const TERMINAL_READER_SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(1);
pub(crate) const RENDER_ATTACHMENT_LIMIT: usize = 64;
const KITTY_IMAGE_PROCESS_BUDGET_BYTES: u64 = 128 * 1024 * 1024;
// libghostty owns independent primary and alternate screen stores. cmux also
// keeps one replay pixel cache and one render pixel cache per PTY surface.
// A grayscale native image expands by up to 3x in either RGB pixel cache.
const KITTY_IMAGE_PERSISTENT_COPIES_PER_SURFACE: u64 = 2 + 3 + 3;
// Image and placement limits are independent on the primary and alternate screens.
const KITTY_OBJECT_OWNERS_PER_SURFACE: u64 = 2;
const KITTY_IMAGE_PROCESS_BUDGET_COUNT: u64 = ghostty_vt::MAX_KITTY_IMAGES;
const KITTY_PLACEMENT_PROCESS_BUDGET_COUNT: u64 = ghostty_vt::MAX_KITTY_PLACEMENTS;
const KITTY_IMAGE_BUDGET_OWNER_LIMIT: usize = {
    let image_limit = KITTY_IMAGE_PROCESS_BUDGET_COUNT / KITTY_OBJECT_OWNERS_PER_SURFACE;
    let placement_limit = KITTY_PLACEMENT_PROCESS_BUDGET_COUNT / KITTY_OBJECT_OWNERS_PER_SURFACE;
    if image_limit < placement_limit { image_limit as usize } else { placement_limit as usize }
};

fn cell_pixel_retry_delay(attempts: u8) -> Duration {
    let multiplier = 1_u32.checked_shl(u32::from(attempts.saturating_sub(1))).unwrap_or(u32::MAX);
    CELL_PIXEL_RETRY_INITIAL.saturating_mul(multiplier).min(CELL_PIXEL_RETRY_MAX)
}

fn kitty_image_budget_capacity(surface_count: usize, current: usize) -> usize {
    if surface_count == 0 {
        return 0;
    }
    // Keep hysteresis for larger buckets, but always restore the sole
    // survivor's full share instead of stranding it in the two-surface bucket.
    if current == 0
        || surface_count > current
        || surface_count <= current / 4
        || (surface_count == 1 && current > 1)
    {
        return surface_count.checked_next_power_of_two().unwrap_or(usize::MAX);
    }
    current
}

fn kitty_surface_byte_reservation(image_bytes: u64) -> u64 {
    image_bytes
        .saturating_mul(KITTY_IMAGE_PERSISTENT_COPIES_PER_SURFACE)
        .saturating_add(ghostty_vt::kitty_inflight_replay_limit_for_image_bytes(image_bytes))
}

fn kitty_image_bytes_for_process_share(process_share: u64) -> u64 {
    let mut lower = 0;
    let mut upper = process_share.min(ghostty_vt::MAX_KITTY_IMAGE_BYTES as u64);
    while lower < upper {
        let candidate = lower + (upper - lower).div_ceil(2);
        if kitty_surface_byte_reservation(candidate) <= process_share {
            lower = candidate;
        } else {
            upper = candidate - 1;
        }
    }
    lower
}

fn kitty_image_limits_for_capacity(capacity: usize) -> KittyGraphicsLimits {
    if capacity == 0 {
        return KittyGraphicsLimits::disabled();
    }
    let surface_count = u64::try_from(capacity).unwrap_or(u64::MAX);
    let process_share = KITTY_IMAGE_PROCESS_BUDGET_BYTES.checked_div(surface_count).unwrap_or(0);
    let image_bytes = kitty_image_bytes_for_process_share(process_share);
    let inflight_bytes = ghostty_vt::kitty_inflight_replay_limit_for_image_bytes(image_bytes);
    let object_owners = surface_count.saturating_mul(KITTY_OBJECT_OWNERS_PER_SURFACE);
    let images = KITTY_IMAGE_PROCESS_BUDGET_COUNT
        .checked_div(object_owners)
        .unwrap_or(0)
        .min(ghostty_vt::MAX_KITTY_IMAGES);
    let placements = KITTY_PLACEMENT_PROCESS_BUDGET_COUNT
        .checked_div(object_owners)
        .unwrap_or(0)
        .min(ghostty_vt::MAX_KITTY_PLACEMENTS);
    KittyGraphicsLimits { image_bytes, inflight_bytes, images, placements }
}

#[derive(Clone)]
struct KittyImageBudgetEntry {
    surface: Option<Weak<Surface>>,
    applied: KittyGraphicsLimits,
    owns_quota: bool,
    removing: bool,
}

#[derive(Default)]
struct KittyImageBudgetState {
    entries: HashMap<SurfaceId, KittyImageBudgetEntry>,
    blocked_surfaces: HashSet<SurfaceId>,
    capacity: usize,
    worker_running: bool,
    expansion_in_flight: bool,
}

struct PendingKittyImageBudgetOperation {
    surface_id: SurfaceId,
    surface: Weak<Surface>,
    limits: KittyGraphicsLimits,
    expanding: bool,
    result: DeadlinePending<anyhow::Result<()>>,
}

pub(crate) struct KittyImageBudgetReservation {
    mux: Weak<Mux>,
    surface: SurfaceId,
    initial_limits: KittyGraphicsLimits,
    committed: bool,
}

#[cfg(unix)]
pub(crate) struct PendingTerminalHostBinding {
    mux: Weak<Mux>,
    surface_id: SurfaceId,
    identity: TerminalHostIdentity,
}

#[cfg(unix)]
impl Drop for PendingTerminalHostBinding {
    fn drop(&mut self) {
        let Some(mux) = self.mux.upgrade() else { return };
        let mut pending = mux.pending_terminal_hosts.lock().unwrap();
        if pending.get(&self.surface_id) == Some(&self.identity) {
            pending.remove(&self.surface_id);
        }
    }
}

#[cfg(unix)]
struct PendingTerminalHostRelease(Arc<Surface>);

#[cfg(unix)]
impl Drop for PendingTerminalHostRelease {
    fn drop(&mut self) {
        self.0.release_pending_terminal_host_binding();
    }
}

impl KittyImageBudgetReservation {
    pub(crate) fn initial_limits(&self) -> KittyGraphicsLimits {
        self.initial_limits
    }

    pub(crate) fn commit(
        mut self,
        surface: &Arc<Surface>,
        applied: KittyGraphicsLimits,
    ) -> anyhow::Result<()> {
        if let Some(mux) = self.mux.upgrade() {
            mux.commit_kitty_image_surface(self.surface, surface, applied)?;
        }
        self.committed = true;
        Ok(())
    }
}

impl Drop for KittyImageBudgetReservation {
    fn drop(&mut self) {
        if self.committed {
            return;
        }
        if let Some(mux) = self.mux.upgrade() {
            mux.cancel_kitty_image_surface_reservation(self.surface);
        }
    }
}

pub(crate) struct RenderAttachmentPermit {
    active: Arc<AtomicUsize>,
}

impl Drop for RenderAttachmentPermit {
    fn drop(&mut self) {
        self.active.fetch_sub(1, Ordering::AcqRel);
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
    pub deferred: bool,
}

#[derive(Debug)]
struct PendingCellPixelUpdate {
    generation: u64,
    target: (u16, u16),
    failures: HashSet<SurfaceId>,
    use_for_creation: bool,
}

struct CellPixelCompletionTracker {
    generation: u64,
    target: (u16, u16),
    publishing: AtomicBool,
    completed: Mutex<HashSet<SurfaceId>>,
}

/// A durable client install identity: non-empty, at most 128 ASCII graphic
/// bytes. Shared by per-client focus memory and per-client notification reads.
pub(crate) fn validate_client_id(client_id: &str) -> anyhow::Result<()> {
    if client_id.is_empty()
        || client_id.len() > 128
        || !client_id.bytes().all(|byte| byte.is_ascii_graphic())
    {
        anyhow::bail!("bad request: invalid client_id");
    }
    Ok(())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RunPlacement {
    pub surface: SurfaceId,
    pub pane: PaneId,
    pub screen: ScreenId,
    pub workspace: WorkspaceId,
}

#[derive(Debug, Clone, PartialEq)]
pub(crate) struct RunCommandResult {
    pub placement: Option<RunPlacement>,
    pub terminal: RegistryTerminal,
    pub terminal_revision: u64,
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

/// A precondition checked atomically with a terminal close.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum TerminalCloseGuard {
    None,
    /// The terminal has no tab placement and is not marked `keep`
    /// (`terminal-reap-v1`).
    UnplacedAndNotKept,
}

/// The close guard did not hold, so nothing changed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct TerminalCloseGuardFailed;

impl fmt::Display for TerminalCloseGuardFailed {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("terminal_close_guard_failed")
    }
}

impl std::error::Error for TerminalCloseGuardFailed {}

#[derive(Debug, Clone, PartialEq)]
pub struct TerminalResolution {
    pub surface: Option<SurfaceId>,
    pub terminal: RegistryTerminal,
    pub terminal_revision: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalPlacementResult {
    pub placement: Option<RunPlacement>,
    pub terminal_id: String,
    pub terminal_incarnation: Option<String>,
    pub terminal_revision: u64,
    pub replayed: bool,
    pub(crate) created_path: Option<Value>,
    pub(crate) created_surface: Option<SurfaceId>,
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
    on_exit: TerminalOnExit,
    /// Extra environment for this terminal's child only (such as the
    /// frontend user's login-shell environment), applied at spawn. Like
    /// argv and cwd it is kept with the creation receipt in the local state
    /// directory so a recovered creation spawns identically.
    env: Vec<(String, String)>,
}

/// Longest accepted per-terminal environment: entries and total bytes.
const MAX_TERMINAL_ENV_ENTRIES: usize = 1024;
const MAX_TERMINAL_ENV_BYTES: usize = 256 * 1024;

/// Validate a per-terminal environment and return it as ordered pairs.
pub(crate) fn validate_terminal_env(
    env: &std::collections::BTreeMap<String, String>,
) -> anyhow::Result<Vec<(String, String)>> {
    anyhow::ensure!(
        env.len() <= MAX_TERMINAL_ENV_ENTRIES,
        "bad request: env has more than {MAX_TERMINAL_ENV_ENTRIES} entries"
    );
    let mut bytes = 0usize;
    for (key, value) in env {
        anyhow::ensure!(
            !key.is_empty() && !key.contains('=') && !key.contains('\0') && !value.contains('\0'),
            "bad request: env names must be nonempty without '=' or NUL, and values without NUL"
        );
        bytes = bytes.saturating_add(key.len()).saturating_add(value.len());
    }
    anyhow::ensure!(
        bytes <= MAX_TERMINAL_ENV_BYTES,
        "bad request: env exceeds {MAX_TERMINAL_ENV_BYTES} bytes"
    );
    Ok(env.iter().map(|(key, value)| (key.clone(), value.clone())).collect())
}

/// Internal creation field carrying a caller-chosen terminal host id.
pub(crate) const RESERVED_TERMINAL_ID_FIELD: &str = "reserved_terminal_id";

/// How to start the terminal a placement command creates.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TerminalSpawnOptions {
    pub cwd: Option<String>,
    /// Extra environment for the new terminal's child only.
    pub env: Vec<(String, String)>,
    /// Caller-chosen terminal host id (32 lowercase hex, UUIDv4), so the
    /// caller can put it in `env` before the child starts.
    pub terminal_id: Option<String>,
    /// The program and arguments to run instead of the bare default shell
    /// (`terminal-shell-args-v1` resolves `shell_args` into it).
    pub argv: Option<Vec<String>>,
}

impl TerminalSpawnOptions {
    pub fn new(cwd: Option<String>, env: Vec<(String, String)>) -> Self {
        Self { cwd, env, terminal_id: None, argv: None }
    }
}

/// Environment pairs stored in a creation's `env` field.
fn terminal_env_field(fields: &Value) -> Vec<(String, String)> {
    fields
        .get("env")
        .and_then(Value::as_object)
        .map(|env| {
            env.iter()
                .filter_map(|(key, value)| Some((key.clone(), value.as_str()?.to_string())))
                .collect()
        })
        .unwrap_or_default()
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
    Attached(Option<TreeDelta>),
}

type ClientSurfaceSizes = HashMap<SurfaceId, HashMap<u64, (u16, u16)>>;
type SurfaceResizeAcceptance = (bool, Option<u64>);
type AppliedClientSize = (SurfaceResizeAcceptance, Option<(u16, u16)>, ClientSizeRollback);
type SurfaceResizeOutcome = Result<(), Arc<str>>;
type SurfaceResizeCompletion = SyncSender<SurfaceResizeOutcome>;

struct ClientResizeRequest {
    surface: SurfaceId,
    client: u64,
    requested: (u16, u16),
    completion: Option<SurfaceResizeCompletion>,
    terminal_runtime: Option<SurfaceId>,
}

struct PreparedControlClientResize {
    request: ClientResizeRequest,
    attached: Option<crate::server::ClientSizeUpdate>,
}

struct PendingWorkspaceSurface<'a> {
    pending: &'a Mutex<HashMap<SurfaceId, WorkspaceId>>,
    surface: SurfaceId,
}

impl Drop for PendingWorkspaceSurface<'_> {
    fn drop(&mut self) {
        self.pending.lock().unwrap().remove(&self.surface);
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

/// Shared sizing state of one terminal runtime (one PTY grid). Every client
/// view of every placement of the runtime and every relay sub-view is one
/// participant of `engine`; see `docs/shared-terminal-sizing.md`.
struct TerminalSizingEntry {
    engine: TerminalSizingEngine,
    /// Placements whose views joined this runtime. Size-state events fan out
    /// to each of them.
    placements: BTreeSet<SurfaceId>,
    /// Every participant of `engine`, keyed by participant id.
    members: HashMap<String, SizingMember>,
    /// The grid this engine last applied. The engine resizes the PTY only
    /// when its decision changes, so it never fights a resize it did not
    /// make (for example a direct terminal-host renderer).
    applied: std::cell::Cell<Option<(u16, u16)>>,
}

/// Which connection and placement one engine participant belongs to.
#[derive(Clone, Debug, PartialEq, Eq)]
struct SizingMember {
    client: u64,
    placement: SurfaceId,
    /// Relay sub-view name; `None` for the connection's own view.
    view: Option<String>,
}

/// Identity of one control connection for the sizing engine.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct ClientSizingIdentity {
    pub(crate) user_id: Option<String>,
    pub(crate) display_name: Option<String>,
    pub(crate) device_kind: TerminalDeviceKind,
    pub(crate) device_name: Option<String>,
    pub(crate) device_id: Option<String>,
}

/// Where a size-state publication goes after the sizing lock is released.
struct SizeStatePublication {
    runtime: SurfaceId,
    placements: Vec<SurfaceId>,
    state: Arc<TerminalSizingState>,
}

#[derive(Default)]
struct ClientSizingState {
    surfaces: ClientSurfaceSizes,
    report_order: HashMap<(SurfaceId, u64), u64>,
    latest_explicit_size: Option<(u64, (u16, u16))>,
    next_size_order: u64,
    policies: HashMap<SurfaceId, SurfaceClientSizing>,
    terminal_runtime_by_placement: HashMap<SurfaceId, SurfaceId>,
    /// Shared sizing engines keyed by terminal runtime id.
    terminal_sizing: HashMap<SurfaceId, TerminalSizingEntry>,
    /// Per-terminal policy overrides keyed by terminal runtime id.
    terminal_size_policies: HashMap<SurfaceId, TerminalSizingPolicy>,
    /// Workspace default policies for terminals without an override.
    workspace_size_policies: HashMap<WorkspaceId, TerminalSizingPolicy>,
    /// Runtimes whose published state changed since the last flush.
    pending_size_states: BTreeSet<SurfaceId>,
    /// Own views (connection, placement) someone detached with a view
    /// detach. The connection stays attached; its view is not a participant
    /// until `reattach-view`.
    detached_views: HashSet<(u64, SurfaceId)>,
}

/// Host participant id of one client's view of one terminal placement. The
/// runtime's own placement keeps the short `c<client>` form.
pub(crate) fn view_participant_id(runtime: SurfaceId, placement: SurfaceId, client: u64) -> String {
    if placement == runtime { format!("c{client}") } else { format!("c{client}@{placement}") }
}

fn entry_owns(sizing: &ClientSizingState, runtime: SurfaceId, participant: &str) -> bool {
    sizing
        .terminal_sizing
        .get(&runtime)
        .is_some_and(|entry| entry.engine.state().owners.iter().any(|owner| owner == participant))
}

/// Host participant id of one relay sub-view.
pub(crate) fn sub_view_participant_id(client: u64, view: &str) -> String {
    format!("c{client}/{view}")
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

    /// Whether this client's view of `surface` currently sets a dimension of
    /// the runtime's shared grid.
    fn owns_terminal_geometry(&self, runtime: SurfaceId, surface: SurfaceId, client: u64) -> bool {
        let id = view_participant_id(runtime, surface, client);
        self.terminal_sizing
            .get(&runtime)
            .is_some_and(|entry| entry.engine.state().owners.contains(&id))
    }

    /// Connections whose views or relay sub-views set a dimension of the grid.
    fn terminal_owner_clients(&self, runtime: SurfaceId) -> HashSet<u64> {
        let Some(entry) = self.terminal_sizing.get(&runtime) else { return HashSet::new() };
        entry
            .engine
            .state()
            .owners
            .iter()
            .filter_map(|owner| entry.members.get(owner).map(|member| member.client))
            .collect()
    }

    fn note_size_state(&mut self, runtime: SurfaceId, changed: bool) {
        if changed {
            self.pending_size_states.insert(runtime);
        }
    }

    fn take_size_state_publications(&mut self) -> Vec<SizeStatePublication> {
        std::mem::take(&mut self.pending_size_states)
            .into_iter()
            .filter_map(|runtime| {
                let entry = self.terminal_sizing.get(&runtime)?;
                Some(SizeStatePublication {
                    runtime,
                    placements: entry.placements.iter().copied().collect(),
                    state: Arc::new(entry.engine.state().clone()),
                })
            })
            .collect()
    }

    fn report_participates(&self, surface: SurfaceId, client: u64) -> bool {
        if let Some(runtime) = self.terminal_runtime_by_placement.get(&surface) {
            return self.owns_terminal_geometry(*runtime, surface, client);
        }
        self.client_participates(surface, client)
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
        // The default for a newly created surface follows the latest
        // authoritative terminal report or the latest effective browser
        // report. Passive terminal viewports never influence future PTYs.
        // Cache browser fallback once per surface to keep this scan linear.
        let mut fallback_by_surface = HashMap::<SurfaceId, bool>::new();
        let ((surface, reporter), order) = self
            .report_order
            .iter()
            .filter(|((surface, client), _)| {
                let surface = *surface;
                let client = *client;
                if let Some(runtime) = self.terminal_runtime_by_placement.get(&surface) {
                    return self.owns_terminal_geometry(*runtime, surface, client)
                        && self
                            .surfaces
                            .get(&surface)
                            .is_some_and(|viewers| viewers.contains_key(&client));
                }
                let use_excluded = *fallback_by_surface.entry(surface).or_insert_with(|| {
                    self.uses_excluded_fallback(surface, attached_clients.get(&surface))
                });
                self.surfaces.get(&surface).is_some_and(|viewers| viewers.contains_key(&client))
                    && (use_excluded || self.client_participates(surface, client))
            })
            .max_by_key(|(_, order)| *order)
            .map(|(key, order)| (*key, *order))?;
        let size = if self.terminal_runtime_by_placement.contains_key(&surface) {
            self.surfaces.get(&surface).and_then(|viewers| viewers.get(&reporter)).copied()
        } else {
            let use_excluded = fallback_by_surface[&surface];
            self.effective_size(surface, use_excluded)
        }?;
        Some((order, size))
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

#[cfg(test)]
type CellPixelBeforePublishHook = Arc<dyn Fn((u16, u16)) + Send + Sync>;
#[cfg(test)]
type CellPixelOperationHook =
    Arc<dyn Fn(&Arc<Surface>, (u16, u16), Instant) -> anyhow::Result<Option<u64>> + Send + Sync>;
#[cfg(test)]
type KittyImageBudgetOperationHook =
    Arc<dyn Fn(&Arc<Surface>, KittyGraphicsLimits, Instant) -> anyhow::Result<()> + Send + Sync>;
#[cfg(test)]
type TerminalSpawnAfterCellPixelSnapshotHook = Arc<dyn Fn(bool) + Send + Sync>;
#[cfg(test)]
type TerminalSpawnBeforeCellPixelReconcileHook = Arc<dyn Fn(&Arc<Surface>) + Send + Sync>;

type CellPixelSurfaceResult = (SurfaceId, (u16, u16), anyhow::Result<Option<u64>>, bool);

struct PendingCellPixelOperation {
    surface: Weak<Surface>,
    result: DeadlinePending<CellPixelSurfaceResult>,
}

struct CellPixelRetryTask {
    surfaces: Vec<Weak<Surface>>,
    pending: Vec<PendingCellPixelOperation>,
    attempts: u8,
    generation: u64,
    target: (u16, u16),
    completion: Arc<CellPixelCompletionTracker>,
    report: SurfaceResizeReporter,
    timeout: Duration,
    #[cfg(test)]
    operation_hook: Option<CellPixelOperationHook>,
}

#[derive(Default)]
struct CellPixelRetryQueue {
    pending: Option<CellPixelRetryTask>,
    worker_running: bool,
}

fn apply_cell_pixel_size_until(
    surface: &Arc<Surface>,
    target: (u16, u16),
    deadline: Instant,
    report: &SurfaceResizeReporter,
    #[cfg(test)] operation_hook: Option<&CellPixelOperationHook>,
) -> CellPixelSurfaceResult {
    let id = surface.id;
    let size = surface.size();
    let callback = report.clone();
    #[cfg(test)]
    if let Some(hook) = operation_hook {
        let result =
            validate_cell_pixel_convergence(surface, target, hook(surface, target, deadline));
        callback(id, size, result.as_ref().ok().copied().flatten());
        let deferred = result.as_ref().err().is_some_and(|error| {
            error.downcast_ref::<crate::terminal_host_runtime::DeferredCellPixelAck>().is_some()
        });
        return (id, size, result, deferred);
    }
    let result = validate_cell_pixel_convergence(
        surface,
        target,
        surface.set_cell_pixel_size_reporting_until(
            target.0,
            target.1,
            deadline,
            Box::new(move |accepted| callback(id, size, accepted)),
        ),
    );
    let deferred = result.as_ref().err().is_some_and(|error| {
        error.downcast_ref::<crate::terminal_host_runtime::DeferredCellPixelAck>().is_some()
    });
    (id, size, result, deferred)
}

fn validate_cell_pixel_convergence(
    surface: &Surface,
    target: (u16, u16),
    result: anyhow::Result<Option<u64>>,
) -> anyhow::Result<Option<u64>> {
    let reservation = result?;
    if reservation.is_none() && surface.cell_pixel_size() != target {
        anyhow::bail!("cell pixel update did not converge to {}x{} pixels", target.0, target.1);
    }
    Ok(reservation)
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
struct TerminalExitDetachTracker {
    active: Mutex<HashSet<String>>,
    changed: Condvar,
}

impl TerminalExitDetachTracker {
    fn acquire(self: &Arc<Self>, terminal_id: String) -> Option<TerminalExitDetachLease> {
        if !self.active.lock().unwrap().insert(terminal_id.clone()) {
            return None;
        }
        Some(TerminalExitDetachLease { tracker: self.clone(), terminal_id })
    }

    fn finish(&self, terminal_id: &str) {
        let mut active = self.active.lock().unwrap();
        if active.remove(terminal_id) {
            self.changed.notify_all();
        }
    }

    #[cfg(test)]
    fn contains(&self, terminal_id: &str) -> bool {
        self.active.lock().unwrap().contains(terminal_id)
    }

    #[cfg(test)]
    fn wait_until_finished(&self, terminal_id: &str, deadline: Instant) -> bool {
        let mut active = self.active.lock().unwrap();
        while active.contains(terminal_id) {
            let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
                return false;
            };
            let (next, timeout) = self.changed.wait_timeout(active, remaining).unwrap();
            active = next;
            if timeout.timed_out() && active.contains(terminal_id) {
                return false;
            }
        }
        true
    }
}

struct TerminalExitDetachLease {
    tracker: Arc<TerminalExitDetachTracker>,
    terminal_id: String,
}

impl Drop for TerminalExitDetachLease {
    fn drop(&mut self) {
        self.tracker.finish(&self.terminal_id);
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
#[derive(Default)]
struct ConfigReloadState {
    requested: u64,
    applied: u64,
}

/// Describes why an owner did not confirm a requested configuration reload.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ConfigReloadError {
    /// The owner stopped before it could apply the request.
    OwnerStopped,
    /// The owner did not confirm the request before the failure deadline.
    TimedOut,
}

impl fmt::Display for ConfigReloadError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::OwnerStopped => "configuration reload owner stopped before applying the request",
            Self::TimedOut => "configuration reload owner did not apply the request",
        })
    }
}

impl std::error::Error for ConfigReloadError {}

/// One client's most recently reported focus (client-focus-v1).
#[derive(Clone)]
struct ClientFocusRecord {
    client_id: String,
    pane: PaneId,
    tab: Option<usize>,
}

/// Bounded size of the per-client focus memory.
const CLIENT_FOCUS_MEMORY_LIMIT: usize = 64;

#[cfg(test)]
type ScreenCreatedHook = Box<dyn FnOnce(SurfaceId) + Send>;

pub struct Mux {
    /// Serializes durable workspace commits, their in-memory projection, and
    /// publication of revisioned workspace deltas. Lock order is always
    /// registry, then state.
    pub(crate) workspace_registry: SignaledMutex<WorkspaceRegistry>,
    pub(crate) session_public_id: SessionPublicId,
    pub(crate) machine_public_id: crate::resource::MachinePublicId,
    /// Control-socket admission counters, shared with the accept loop.
    connection_stats: Arc<crate::diagnostics::ConnectionStats>,
    /// Clone of the registry's projection spans, read without its lock.
    resource_projection_stats: Arc<crate::diagnostics::ResourceProjectionStats>,
    started_at: Instant,
    pub(crate) state: Mutex<State>,
    subscribers: MuxEventBroadcaster,
    config_reload: Mutex<ConfigReloadState>,
    config_reload_changed: Condvar,
    next_id: AtomicU64,
    next_notification_id: AtomicU64,
    next_active_at: AtomicU64,
    next_in_process_resize_owner: AtomicU64,
    surface_options: Mutex<SurfaceOptions>,
    provider_workspace: Mutex<ProviderWorkspaceState>,
    /// `provider_workspace.managed`, readable under the registry and state
    /// locks (the provider lock orders before them; the flag is one-way).
    provider_managed: AtomicBool,
    workspace_lifecycles: Mutex<HashMap<WorkspaceId, Weak<Mutex<()>>>>,
    pending_workspace_surfaces: Mutex<HashMap<SurfaceId, WorkspaceId>>,
    client_sizing_lifecycle: Mutex<()>,
    client_sizing: Mutex<ClientSizingState>,
    /// Per-client focus memory (client-focus-v1): the most recent focus each
    /// client id reported, so a reconnecting client restores its own view
    /// instead of the shared session focus. In-memory and bounded; a mux
    /// restart degrades to the tree's own focus markers.
    client_focus_memory: Mutex<Vec<ClientFocusRecord>>,
    /// The session's most recently reported focus from any client
    /// (client-focus-v1): the adoption default for a later attach that has
    /// no per-client memory. Focus reports only write this record and the
    /// per-client memory; they never move the live shared focus, so other
    /// attached clients stay where they are.
    last_reported_focus: Mutex<Option<(PaneId, Option<usize>)>>,
    conversations: crate::conversation_store::ConversationHost,
    /// The cloud conversations proxy (`cloud-conversations-v1`), installed by
    /// a binary that has a cloud transport; absent otherwise.
    cloud_conversations: OnceLock<crate::cloud_conversations::CloudConversations>,
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
    workspace_delta_before_emit: Mutex<Option<WorkspaceDeltaBeforeEmitHook>>,
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
    terminal_spawn_after_cell_pixel_snapshot:
        Mutex<Option<TerminalSpawnAfterCellPixelSnapshotHook>>,
    #[cfg(test)]
    terminal_spawn_before_cell_pixel_reconcile:
        Mutex<Option<TerminalSpawnBeforeCellPixelReconcileHook>>,
    #[cfg(test)]
    terminal_create_after_terminal_reservation: Mutex<Option<TerminalReservationHook>>,
    pending_terminal_hosts: Mutex<HashMap<SurfaceId, TerminalHostIdentity>>,
    reserved_in_process_terminals: Mutex<HashMap<SurfaceId, TerminalHostIdentity>>,
    #[cfg(test)]
    viewport_split_after_spawn: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
    #[cfg(test)]
    resource_mutation_metrics: Mutex<Option<ResourceMutationMetrics>>,
    #[cfg(test)]
    resource_projection_before_commit: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
    #[cfg(test)]
    resource_close_after_commit: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
    #[cfg(test)]
    layout_undo_before_commit: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
    #[cfg(test)]
    resource_close_cleanup: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
    browser_providers: Arc<BrowserProviderRegistry>,
    browser_runtime: Mutex<Option<Arc<BrowserRuntime>>>,
    active_render_attachments: Arc<AtomicUsize>,
    deadline_fanout_pool: DeadlineFanoutPool,
    kitty_image_budget: Mutex<KittyImageBudgetState>,
    kitty_image_budget_changed: Condvar,
    /// App byte-backend terminals (`app_terminals.rs`), by catalog surface.
    app_terminals: Mutex<HashSet<SurfaceId>>,
    #[cfg(debug_assertions)]
    terminal_host_reconnect_completion_failures: AtomicU64,
    #[cfg(debug_assertions)]
    terminal_host_test_disconnect_after_spawn_ms: AtomicU64,
    #[cfg(test)]
    kitty_image_budget_operation: Mutex<Option<KittyImageBudgetOperationHook>>,
    cell_pixel_lifecycle: Mutex<()>,
    next_cell_pixel_generation: AtomicU64,
    cell_pixels: Mutex<(u16, u16)>,
    pending_cell_pixels: Mutex<Option<PendingCellPixelUpdate>>,
    cell_pixel_retries: Mutex<CellPixelRetryQueue>,
    #[cfg(test)]
    cell_pixel_before_publish: Mutex<Option<CellPixelBeforePublishHook>>,
    #[cfg(test)]
    cell_pixel_operation: Mutex<Option<CellPixelOperationHook>>,
    #[cfg(test)]
    cell_pixel_fanout_timeout: Mutex<Option<Duration>>,
    default_colors: Mutex<DefaultColors>,
    durable_terminal_defaults: AtomicBool,
    sidebar_plugin: Mutex<SidebarPluginRuntime>,
    journal_plugin: crate::journal_plugin::JournalPluginRuntime,
    machine_usage: Mutex<Option<MachineUsage>>,
    agent_records: Mutex<HashMap<TerminalPublicId, TerminalAgentRecord>>,
    agent_hook_fences: Mutex<HashMap<TerminalPublicId, HookFence>>,
    agent_roster: Mutex<AgentRosterHost>,
    agent_roster_fold: Mutex<()>,
    /// Nonterminal notifications remain placement-local. Terminal unread
    /// state is keyed separately by stable content identity so every view of
    /// one terminal shares the same attention marker.
    placement_notifications: Mutex<HashMap<SurfaceId, SurfaceNotification>>,
    terminal_notifications: Mutex<HashMap<TerminalPublicId, SurfaceNotification>>,
    /// Records finished shell commands in the journal
    /// (`terminal-command-journal-v1`). Off until a trusted client turns it
    /// on (`set-terminal-command-history`); never persisted, so a restarted
    /// daemon records nothing until asked again.
    terminal_command_history: AtomicBool,
    /// The shell command journal worker's bounded queue (started on first use).
    shell_command_journal:
        Mutex<Option<SyncSender<(TerminalPublicId, crate::shell_history::FinishedCommand)>>>,
    notification_ledger: Mutex<VecDeque<ResourceNotification>>,
    /// Per-client read marks. The shared unread marker above answers "does
    /// this terminal need attention on the shared console"; this map answers
    /// "has this client install seen this notification", so several remote
    /// clients of one session keep independent unread state.
    notification_reads: Mutex<HashMap<NotificationPublicId, BTreeSet<String>>>,
    /// Notification ids the in-memory ledger evicted whose durable read marks
    /// are still to be pruned. Pruning happens only after a create commits,
    /// and only for ids the committed receipts no longer retain, so a failed
    /// create cannot orphan marks the next restart would rebuild.
    notification_read_prunes: Mutex<Vec<NotificationPublicId>>,
    /// Shared presentation metadata (workspace groups and workspace
    /// presentation fields), replaced after each registry commit.
    presentation: Mutex<Arc<crate::workspace_registry::PresentationSnapshot>>,
    /// Git HEAD lookups keyed by directory, with the time they were read.
    git_heads: Mutex<HashMap<String, (Instant, Option<presentation::GitHead>)>>,
    resource_machine_service: OnceLock<Arc<dyn crate::ResourceMachineService>>,
    journal_kernel: Arc<crate::journal_kernel::JournalKernel>,
    journal_ingress: crate::journal_ingress::JournalIngressSender,
    journal_hook_dispatcher_started: AtomicBool,
    journal_hook_runtime: Arc<crate::journal_hooks::JournalHookRuntime>,
    /// Wake-only signal for durable journal subscribers. Consumers always
    /// reread SQLite by cursor, so missed or coalesced notifications are safe.
    journal_event_epoch: Mutex<u64>,
    journal_event_changed: Condvar,
    /// True once a skipped terminal-host reconnect checkpoint has been logged.
    /// A machine resume reconnects every hosted terminal at once, so
    /// per-terminal reporting would emit N warnings for one underlying
    /// condition. Cleared when a reconnect checkpoint succeeds again.
    reconnect_checkpoint_skip_reported: AtomicBool,
    journal_retention: journal_retention::JournalRetention,
    /// Frontend-owned sink for diagnostics emitted by background core work.
    /// `OnceLock` keeps the callback immutable after startup and avoids a
    /// mutex on the reconnect hot path. Startup can adopt a hosted surface
    /// before the frontend installs the sink, so the first diagnostics are
    /// retained per mux until the first reporter arrives.
    diagnostic_reporter: OnceLock<DiagnosticReporter>,
    pending_diagnostics: Mutex<Vec<String>>,
    #[cfg(test)]
    journal_segment_prepare_hook: Mutex<Option<Box<dyn FnOnce() + Send>>>,
    /// Runs right after a new screen's creation handoff is released, where a
    /// terminal that exits at once can already close its screen.
    #[cfg(test)]
    screen_created_hook: Mutex<Option<ScreenCreatedHook>>,
    terminal_exit_waiters: TerminalExitWaiters,
    #[cfg(test)]
    terminal_exit_state_queries: AtomicU64,
    /// Keeps a close from removing a just-created surface before legacy
    /// callers have resolved the committed public result back to its runtime.
    resource_creation_handoff: Mutex<()>,
    /// Serializes the check-and-create sequence used when an attached local
    /// frontend bootstraps an otherwise empty session.
    initial_bootstrap: Mutex<()>,
    resource_creation_execution: Mutex<()>,
    resource_creation_active: AtomicBool,
    terminal_adoptions: Mutex<HashSet<String>>,
    /// Terminals with a possibly live host and no runtime surface (R41),
    /// keyed by public terminal id (`term_…`, what the tab JSON reads), with
    /// the host terminal id. A leaf lock: nothing else is locked under it.
    pending_terminals: Mutex<HashMap<String, (String, PendingTerminal)>>,
    /// Typed ends (`TerminalEnd::wire_json`) of ended terminals that have no
    /// runtime surface, keyed by public terminal id. A leaf lock.
    terminal_ends: Mutex<HashMap<String, Value>>,
    /// Cause of each terminal's last host loss, by public id (cx-0tgl).
    terminal_loss_causes: Mutex<loss_causes::LossCauses>,
    terminal_exit_detaches: Arc<TerminalExitDetachTracker>,
    terminal_adoption_insert_failures: AtomicU64,
    template_completion_failures: AtomicU64,
    server_lifecycle_ready: AtomicBool,
    shutting_down: AtomicBool,
    /// When this owner's session (and the previous owner's) was shutting
    /// down: signal exits then are host losses (`session-shutdown`).
    session_shutdown: crate::session_shutdown::SessionShutdownClock,
    /// Detaches of live signal exits that wait out the session shutdown
    /// lead (`session-shutdown`, logout race).
    exit_settles: Arc<exit_settle::ExitSettleTimer>,
    terminal_respawns: terminal_respawn::TerminalRespawns,
    /// Called after `request_daemon_shutdown`, so the owner loop that waits
    /// for it blocks instead of polling the flag.
    daemon_shutdown_waker: Mutex<Option<Box<dyn Fn() + Send + Sync>>>,
    pub(crate) control_clients: crate::server::ClientRegistry,
    /// VM activity facts for `subscribe-activity` (server/activity.rs).
    pub(crate) activity: crate::server::activity::ActivityStream,
    idle_close: Mutex<idle_close::IdleCloseTracker>,
    /// Wakes the idle-close reaper when a policy changes.
    idle_close_waker: Mutex<Option<std::sync::mpsc::Sender<idle_close::ReaperMessage>>>,
    /// Hosts of closed terminals that were asked to exit.
    terminal_host_closes: Arc<host_close::TerminalHostCloses>,
    /// Reap grace period for unplaced terminals, in milliseconds.
    terminal_reap_grace_ms: AtomicU64,
    /// The running reaper's event receiver, so keep and grace changes can
    /// wake it.
    terminal_reaper_events: Mutex<Option<MuxEventReceiver>>,
    /// The launch snapshot file while its writer runs (`launch-snapshot-v1`).
    launch_snapshot_path: Mutex<Option<std::path::PathBuf>>,
    /// Parallel terminal host launches and reaps (`terminal_work`).
    terminal_work: terminal_work::TerminalWorkPool,
    /// Hosts launched ahead of their creation, by reserved terminal id.
    #[cfg(unix)]
    prelaunched_terminals: Mutex<HashMap<String, terminal_work::PrelaunchedTerminal>>,
    #[cfg(unix)]
    pub(crate) image_pastes: crate::image_paste::ImagePasteStore,
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

#[cfg(unix)]
struct RestoredTerminalBinding {
    public_id: TerminalPublicId,
    placements: Vec<(SurfaceId, TabResourceIdentity)>,
}

impl Mux {
    fn default_workspace_name(state: &State) -> String {
        // Provider-created workspaces use a stable, human-readable sequence.
        // Existing names (including user-renamed workspaces) are left untouched;
        // only the next automatically generated name is derived here. The
        // sequence never restarts below the number of workspaces that exist:
        // renaming `workspace-1` to `shell` and creating another one yields
        // `workspace-2` (the second workspace), not a second `workspace-1`.
        let highest = state
            .workspaces
            .iter()
            .filter_map(|workspace| {
                workspace.name.strip_prefix("workspace-")?.parse::<usize>().ok()
            })
            .max()
            .unwrap_or(0);
        let next = highest.max(state.workspaces.len()).saturating_add(1);
        format!("workspace-{next}")
    }

    /// Resolve one public resource path from a single live-state snapshot.
    /// Direct content IDs use the reverse resource indexes and never trigger
    /// a registry snapshot or process query.
    pub fn resolve_resource_path(
        &self,
        target: crate::ResourceTarget,
        selectors: &crate::ResourceSelectors,
    ) -> Result<crate::ResolvedResourcePath, ResourceError> {
        // Session and machine identity never change for the life of a mux, so
        // selector resolution must not queue behind the registry mutex, which
        // the journal writer holds across every fsync.
        let state = self.state.lock().unwrap();
        resolve_resource_selectors(
            &state,
            ResourceSelectorContext {
                machine_id: &self.machine_public_id,
                machine_name: None,
                session_id: &self.session_public_id,
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

    fn retry_pending_agent_hooks(&self) -> anyhow::Result<()> {
        let mut cursor = None;
        // Keep startup work bounded. Remaining rows stay durable for a later
        // availability signal or restart.
        for _ in 0..crate::workspace_registry::AGENT_HOOK_MAX_RETRY_PAGES_PER_WAKE {
            let (pending, next_cursor) = self
                .workspace_registry
                .lock()
                .unwrap()
                .pending_agent_hook_projections_page(cursor.clone())?;
            let Some(next_cursor) = next_cursor else { break };
            cursor = Some(next_cursor);
            self.retry_pending_agent_hooks_rows(pending)?;
        }
        Ok(())
    }

    fn retry_pending_agent_hooks_for_terminal(
        &self,
        terminal_id: &TerminalPublicId,
    ) -> anyhow::Result<()> {
        // Drain in fixed-size pages, with a hard per-signal cap. Rows beyond
        // the cap remain durable for the next terminal availability signal.
        for _ in 0..crate::workspace_registry::AGENT_HOOK_MAX_RETRY_PAGES_PER_WAKE {
            let pending = self
                .workspace_registry
                .lock()
                .unwrap()
                .pending_agent_hook_projections_for_terminal(terminal_id)?;
            if pending.is_empty() {
                break;
            }
            let applied = self.retry_pending_agent_hooks_rows(pending)?;
            if applied == 0 {
                break;
            }
        }
        Ok(())
    }

    fn retry_pending_agent_hooks_rows(
        &self,
        pending: Vec<(String, String, String, u64, crate::JournalIngress)>,
    ) -> anyhow::Result<usize> {
        let mut applied = 0;
        for (producer_id, origin, key, sequence, ingress) in pending {
            match self.apply_agent_hook_record(&ingress, sequence) {
                Ok(()) => {
                    if self
                        .workspace_registry
                        .lock()
                        .unwrap()
                        .clear_agent_hook_pending(&producer_id, &origin, &key)
                        .is_ok()
                    {
                        applied += 1;
                    } else {
                        self.report_internal_diagnostic("agent hook retry cleanup deferred");
                    }
                }
                Err(error) if agent_hook_terminal_gone(&error) => {
                    if self
                        .workspace_registry
                        .lock()
                        .unwrap()
                        .clear_agent_hook_pending(&producer_id, &origin, &key)
                        .is_ok()
                    {
                        applied += 1;
                    } else {
                        self.report_internal_diagnostic("agent hook retry cleanup deferred");
                    }
                }
                Err(error) => {
                    if self
                        .workspace_registry
                        .lock()
                        .unwrap()
                        .enqueue_agent_hook_pending(
                            &producer_id,
                            &origin,
                            &key,
                            sequence,
                            &ingress,
                            AgentHookPendingFailure {
                                error: AGENT_HOOK_RETRY_ERROR,
                                retry_class: agent_hook_retry_class(&error),
                            },
                        )
                        .is_err()
                    {
                        self.report_internal_diagnostic("agent hook retry bookkeeping deferred");
                    }
                }
            }
        }
        Ok(applied)
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
        let presentation = self.presentation_snapshot();
        for content in contents {
            let Some(browser) = content.browser.clone() else { continue };
            let size = (browser.cols, browser.rows);
            let frontend = presentation.frontend_browsers.get(browser.public_id.as_str());
            let url = frontend.map(|record| record.url.clone()).unwrap_or(browser.url);
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
            if let (Some(record), Some(runtime)) = (frontend, surface.as_browser()) {
                runtime.set_frontend_location(None, record.title.clone());
            }
            insert_surface_checked(&mut self.state.lock().unwrap(), surface.clone())?;
            match browser.reconnect {
                RegistryBrowserReconnect::Recreate => {
                    self.start_browser_bootstrap(
                        surface,
                        BrowserBootstrap::Provider { tab_id: content.identity.tab_id.clone(), url },
                        None,
                    );
                }
            }
        }
        Ok(())
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
        let state = self.state.lock().unwrap();
        state.surfaces.get(&id).or_else(|| state.terminal_runtime_by_id(id)).cloned()
    }

    pub(crate) fn terminal_resource_surface(
        &self,
        terminal_id: &TerminalPublicId,
    ) -> Option<Arc<Surface>> {
        self.state.lock().unwrap().terminal_catalog.get(terminal_id).cloned()
    }

    #[cfg(test)]
    pub(crate) fn remove_surface_runtime_for_test(&self, id: SurfaceId) -> Option<Arc<Surface>> {
        self.state.lock().unwrap().surfaces.remove(&id)
    }

    #[cfg(test)]
    pub(crate) fn insert_surface_runtime_for_test(&self, surface: Arc<Surface>) {
        let previous = self.state.lock().unwrap().surfaces.insert(surface.id, surface);
        assert!(previous.is_none(), "test surface id already exists");
    }

    #[cfg(test)]
    pub(crate) fn remove_terminal_catalog_for_test(
        &self,
        terminal_id: &TerminalPublicId,
    ) -> Option<Arc<Surface>> {
        let mut state = self.state.lock().unwrap();
        state.remove_catalog_terminal(terminal_id)
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

    fn active_surface_in_state(state: &State) -> Option<SurfaceId> {
        let pane = state.active_pane()?;
        state.panes.get(&pane)?.active_surface()
    }

    pub fn active_surface(&self) -> Option<SurfaceId> {
        self.with_state(Self::active_surface_in_state)
    }

    /// Scroll one backend-owned view without mutating the terminal runtime
    /// shared by the terminal's other placements.
    pub fn scroll_surface_viewport(&self, surface: &Surface, delta: isize) -> anyhow::Result<()> {
        let before = surface.view_scrollbar();
        let after = surface.view_scroll_delta(delta)?;
        if after != before
            && let Some(scrollbar) = after
        {
            self.emit(MuxEvent::ScrollChanged {
                surface: surface.id,
                offset: scrollbar.offset,
                at_bottom: !scrollbar.scrolled_back(),
            });
        }
        Ok(())
    }

    /// Working directory of a pane's active surface, if reported.
    fn pane_cwd(&self, pane: PaneId) -> Option<String> {
        let surface = {
            let state = self.state.lock().unwrap();
            let active = state.panes.get(&pane)?.active_surface()?;
            state.surfaces.get(&active).cloned()
        };
        surface.and_then(|surface| surface.local_cwd())
    }

    fn workspace_key_for_pane(&self, pane: PaneId) -> Option<String> {
        let state = self.state.lock().unwrap();
        let (workspace, _) = state.screen_of(pane)?;
        Some(state.workspaces[workspace].key.clone())
    }

    /// Reconcile a surface whose child exited before its tree insert
    /// completed. Hosted terminals commit their exit and detach every view;
    /// local terminals are reaped after the creator closes the insert race.
    fn reap_if_dead(self: &Arc<Self>, surface: &Arc<Surface>) {
        if surface.is_dead() {
            if self.resource_creation_active.load(Ordering::Acquire) {
                // The reader's exit callback is fenced by the creation
                // execution lock. It will reap this surface after the public
                // creation batch and any legacy runtime handoff complete.
                return;
            }
            if let Some(identity) = self.resource_terminal_host_identity(surface) {
                if let Err(error) =
                    self.mark_hosted_surface_exited(surface, "host-exited-before-attach")
                {
                    self.emit(MuxEvent::Status(format!(
                        "could not persist terminal {} exit: {error}",
                        surface.id
                    )));
                    self.schedule_exited_terminal_detach(
                        identity.terminal_id,
                        surface,
                        "host-exited-before-attach",
                    );
                    return;
                }
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
        self.state.lock().unwrap().surfaces.remove(&id);
        true
    }

    /// Set the deepest split ratio in `dir` on the path to `pane`.
    pub fn set_ratio_as(
        self: &Arc<Self>,
        actor: &Actor,
        pane: PaneId,
        dir: SplitDir,
        ratio: f32,
    ) -> bool {
        self.set_ratio_checked_as(actor, pane, dir, ratio).is_ok()
    }

    /// Set a pane-addressed split ratio while preserving rejection details.
    pub fn set_ratio_checked_as(
        self: &Arc<Self>,
        actor: &Actor,
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
        self.set_split_ratio_inner(actor, split, ratio, None, true).map_err(|error| match error {
            LayoutRatioError::UnknownSplit { .. } => LayoutRatioError::UnknownPaneSplit { pane },
            error => error,
        })
    }

    /// Set one split ratio by its stable split-tree node id.
    pub fn set_split_ratio_as(self: &Arc<Self>, actor: &Actor, split: SplitId, ratio: f32) -> bool {
        self.set_split_ratio_checked_as(actor, split, ratio).is_ok()
    }

    /// Set one split ratio while preserving rejection details.
    pub fn set_split_ratio_checked_as(
        self: &Arc<Self>,
        actor: &Actor,
        split: SplitId,
        ratio: f32,
    ) -> Result<(), LayoutRatioError> {
        self.set_split_ratio_inner(actor, split, ratio, None, false)
    }

    /// Set one split ratio as part of a client-scoped resize transaction.
    pub fn set_split_ratio_in_transaction_as(
        self: &Arc<Self>,
        actor: &Actor,
        split: SplitId,
        ratio: f32,
        client: u64,
        transaction: u64,
    ) -> bool {
        self.set_split_ratio_in_transaction_checked_as(actor, split, ratio, client, transaction)
            .is_ok()
    }

    /// Set one transactional split ratio while preserving rejection details.
    pub fn set_split_ratio_in_transaction_checked_as(
        self: &Arc<Self>,
        actor: &Actor,
        split: SplitId,
        ratio: f32,
        client: u64,
        transaction: u64,
    ) -> Result<(), LayoutRatioError> {
        self.set_split_ratio_inner(
            actor,
            split,
            ratio,
            Some((LayoutResizeOwner::ControlClient(client), transaction)),
            false,
        )
    }

    /// Set one in-process transactional split ratio without sharing the
    /// control-client ownership namespace.
    pub fn set_split_ratio_in_process_transaction_checked_as(
        self: &Arc<Self>,
        actor: &Actor,
        split: SplitId,
        ratio: f32,
        owner: u64,
        transaction: u64,
    ) -> Result<(), LayoutRatioError> {
        self.set_split_ratio_inner(
            actor,
            split,
            ratio,
            Some((LayoutResizeOwner::InProcess(owner), transaction)),
            false,
        )
    }

    fn set_split_ratio_inner(
        self: &Arc<Self>,
        actor: &Actor,
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
            if screen.layout_columns.iter().any(|column| column.is_row_split(split)) {
                return Err(LayoutRatioError::RowSplitCompatReadonly { split });
            }
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
            .commit_ordinary_topology_operation_by(
                actor,
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
    pub fn set_viewport_pane_width_as(
        self: &Arc<Self>,
        actor: &Actor,
        pane: PaneId,
        width: f32,
    ) -> bool {
        self.set_viewport_pane_width_checked_as(actor, pane, width).is_ok()
    }

    /// Set a viewport column width while preserving rejection details.
    pub fn set_viewport_pane_width_checked_as(
        self: &Arc<Self>,
        actor: &Actor,
        pane: PaneId,
        width: f32,
    ) -> Result<(), ViewportWidthError> {
        self.set_viewport_pane_width_inner(actor, pane, width, None)
    }

    /// Set a viewport column width as part of a client-scoped resize transaction.
    pub fn set_viewport_pane_width_in_transaction_as(
        self: &Arc<Self>,
        actor: &Actor,
        pane: PaneId,
        width: f32,
        client: u64,
        transaction: u64,
    ) -> bool {
        self.set_viewport_pane_width_in_transaction_checked_as(
            actor,
            pane,
            width,
            client,
            transaction,
        )
        .is_ok()
    }

    /// Set a transactional viewport width while preserving rejection details.
    pub fn set_viewport_pane_width_in_transaction_checked_as(
        self: &Arc<Self>,
        actor: &Actor,
        pane: PaneId,
        width: f32,
        client: u64,
        transaction: u64,
    ) -> Result<(), ViewportWidthError> {
        self.set_viewport_pane_width_inner(
            actor,
            pane,
            width,
            Some((LayoutResizeOwner::ControlClient(client), transaction)),
        )
    }

    /// Set one in-process transactional viewport width without sharing the
    /// control-client ownership namespace.
    pub fn set_viewport_pane_width_in_process_transaction_checked_as(
        self: &Arc<Self>,
        actor: &Actor,
        pane: PaneId,
        width: f32,
        owner: u64,
        transaction: u64,
    ) -> Result<(), ViewportWidthError> {
        self.set_viewport_pane_width_inner(
            actor,
            pane,
            width,
            Some((LayoutResizeOwner::InProcess(owner), transaction)),
        )
    }

    fn set_viewport_pane_width_inner(
        self: &Arc<Self>,
        actor: &Actor,
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
            .commit_ordinary_topology_operation_by(
                actor,
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

    /// Undo the latest structural layout transaction on `pane`'s screen.
    ///
    /// Transactions that created panes return a confirmation preview first.
    /// The preview is read only. The caller must retry with its exact current
    /// layout revision and `confirm_close=true`; structural or created-pane tab
    /// membership changes advance that revision before the retry can commit.
    pub fn undo_layout_as(
        self: &Arc<Self>,
        actor: &Actor,
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
        // The confirmation token fences exactly what closes; it is computed
        // once. The resource revision is only the commit's precondition, so a
        // conflict from an unrelated commit between reading it and committing
        // is retried (bounded) with the same token: the commit re-checks the
        // token against the state it commits on.
        if !created_panes.is_empty() {
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
        }
        let commit =
            self.commit_confirmed_layout_undo(actor, selectors, fields, !created_panes.is_empty())?;
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
                let entry = {
                    let screen = &mut state.workspaces[workspace_index].screens[screen_index];
                    let Some(entry) = screen.layout_undo.pop_back() else {
                        return Err(
                            LayoutUndoError::Stale("layout undo disappeared".to_string()).into()
                        );
                    };
                    if entry.after_revision != screen.layout_revision
                        || expected_revision
                            .is_some_and(|expected| expected != entry.after_revision)
                    {
                        screen.layout_undo.push_back(entry);
                        return Err(LayoutUndoError::Stale(
                            "layout changed before undo could commit".to_string(),
                        )
                        .into());
                    }
                    entry
                };
                if let Some(restore) = entry.tab_restore
                    && let Err(error) = restore_dragged_tab(
                        self,
                        &mut state,
                        workspace_index,
                        screen_index,
                        restore,
                    )
                {
                    state.workspaces[workspace_index].screens[screen_index]
                        .layout_undo
                        .push_back(entry);
                    return Err(error);
                }
                let screen = &mut state.workspaces[workspace_index].screens[screen_index];
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
        let notifications = self.tree_decorations();
        let registry = self.workspace_registry.lock().unwrap();
        let (removed, deltas, selection_resync, revision) = {
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
            (removed, deltas, selection_resync, revision)
        };
        drop(registry);

        for surface in removed {
            self.purge_surface_side_tables(surface.id);
            if surface.kind() == SurfaceKind::Browser {
                surface.kill();
            }
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

    pub fn apply_layout_as(
        self: &Arc<Self>,
        actor: &Actor,
        workspace: Option<WorkspaceId>,
        name: Option<String>,
        layout: &LayoutSpec,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<AppliedLayout> {
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
                    &WorkspaceMutation::local("cmux-tui-layout-workspace", actor.clone()),
                    false,
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
            actor,
            layout,
            size,
            &workspace_key,
            &mut panes,
            &mut created,
            &mut spawned,
        ) {
            Ok(root) => root,
            Err(err) => {
                self.discard_spawned(actor, spawned);
                if created_workspace {
                    drop(workspace_lifecycle_guard);
                    let _ = self
                        .close_workspace_at_revision_for_resource_effect(actor, target_workspace);
                }
                return Err(err);
            }
        };
        if created.is_empty() {
            self.discard_spawned(actor, spawned);
            if created_workspace {
                drop(workspace_lifecycle_guard);
                let _ =
                    self.close_workspace_at_revision_for_resource_effect(actor, target_workspace);
            }
            anyhow::bail!("layout must contain at least one leaf");
        }
        let active_pane = root.first_visible_pane();
        let screen_id = self.next_id();
        let notifications = self.tree_decorations();
        let delta = {
            let mut state = self.state.lock().unwrap();
            let Some(workspace_index) = state.workspace_index(target_workspace) else {
                drop(state);
                self.discard_spawned(actor, spawned);
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
                creation_order_auto_layout: None,
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
                transaction: None,
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
        if let Err(error) = self.commit_ordinary_full_resource_projection(
            actor,
            "screen.layout.create",
            projection_result,
        ) {
            drop(workspace_lifecycle_guard);
            let rollback = self.close_screen_for_resource_effect(screen_id);
            if created_workspace {
                let _ =
                    self.close_workspace_at_revision_for_resource_effect(actor, target_workspace);
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
        for surface in &spawned {
            surface.activate_hosted_launch_stream()?;
        }
        self.emit(MuxEvent::TreeDelta(delta));
        self.emit(MuxEvent::LayoutChanged(screen_id));
        for surface in spawned {
            self.reap_if_dead(&surface);
        }
        Ok(AppliedLayout { screen: screen_id, panes: created })
    }

    #[allow(clippy::too_many_arguments)]
    fn instantiate_layout(
        self: &Arc<Self>,
        actor: &Actor,
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
                let mutation = WorkspaceMutation::local("cmux-tui-layout-terminal", actor.clone());
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
                        None,
                    )?,
                    expected_generation: None,
                    expected_revision: None,
                    on_exit: TerminalOnExit::Close,
                    env: Vec::new(),
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
                    actor,
                    a,
                    size,
                    workspace_key,
                    panes,
                    created,
                    spawned,
                )?),
                b: Box::new(self.instantiate_layout(
                    actor,
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
                        actor,
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

    fn discard_spawned(&self, actor: &Actor, spawned: Vec<Arc<Surface>>) {
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
                        &WorkspaceMutation::local("cmux-tui-layout-discard", actor.clone()),
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
        let removed = {
            let mut state = self.state.lock().unwrap();
            let mut removed = Vec::new();
            for surface in &spawned {
                removed.extend(remove_terminal_runtime_from_state(self, &mut state, surface).0);
            }
            removed
        };
        if batch.closed != 0 {
            self.emit_terminal_registry_changed(&registry, batch.revision);
        }
        drop(registry);
        self.notify_terminal_exit_waiters(closed_public_ids);
        for placement in removed {
            self.purge_surface_side_tables(placement.id);
        }
        for surface in spawned {
            self.purge_terminal_runtime_side_tables(&surface);
            if !surface.is_dead() {
                surface.kill();
            }
        }
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
                let current_revision = registry.terminal_revision()?;
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
                if topology_changed {
                    self.commit_full_resource_projection_locked(
                        &mut registry,
                        &mut state,
                        &mutation.actor,
                        "terminal.move",
                    )?;
                }
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
                // The projection moved the terminal's view between panes;
                // the resource topology must record that move under the
                // same locks, or a restore reverts it and later tab moves
                // plan from a placement that memory no longer has.
                if topology_changed {
                    self.commit_full_resource_projection_locked(
                        &mut registry,
                        &mut state,
                        &mutation.actor,
                        "terminal.move",
                    )?;
                }
                (terminal, commit.revision, false, changed, placement, topology_changed)
            }
        };
        if placement.is_some()
            && let Some(surface) = placement.and_then(|placement| self.surface(placement.surface))
        {
            let _ = surface.persist_host_workspace(&terminal.workspace_key);
        }
        if topology_changed {
            self.publish_resource_event();
            self.publish_pending_terminal_directories();
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
        let Some(runtime) = self.catalog_terminal_by_host(state, terminal_id)? else {
            // Still validate the in-memory projection while both writer locks
            // are held; a missing destination indicates registry/state drift.
            if state.workspaces.iter().all(|workspace| workspace.key != workspace_key) {
                anyhow::bail!("unknown workspace key {workspace_key}");
            }
            return Ok((None, false));
        };
        let surface = terminal_placement_for_runtime(state, &runtime);
        let Some(surface) = surface else {
            // A terminal with no view remains alive. Creating another view is
            // an explicit `terminal.project` operation, not an implicit move.
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
                creation_order_auto_layout: Some(vec![pane]),
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
            state.resource_indexes.tab_pane.insert(surface, target_pane);
            fence_layout_undo_for_tab_membership(state, &[target_pane]);
        }
        restore_focus_identity(state, preserved_focus);
        let placement = run_placement_for_surface(state, surface)
            .ok_or_else(|| anyhow::anyhow!("terminal move did not produce a binding"))?;
        Ok((Some(placement), true))
    }

    /// Reorder a workspace as `actor`. The active workspace follows the
    /// moved entry.
    pub fn move_workspace_at_revision_as(
        &self,
        actor: &Actor,
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
        let mutation = WorkspaceMutation::local("cmux-tui", actor.clone());
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
        let notifications = self.tree_decorations();
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
                    transaction: None,
                },
                workspace_mutation_result(&commit)?,
            )
        };
        self.emit_committed_workspace_delta(&registry, delta, false);
        drop(registry);
        self.publish_resource_event();
        Ok(result)
    }

    /// Select a tab within a pane (default: the active pane) by index or
    /// relative delta.
    pub fn select_tab_as(
        self: &Arc<Self>,
        actor: &Actor,
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
        if self.commit_ordinary_tab_selection(actor, selectors).is_err() {
            return;
        }
        let viewed = self.with_state(Self::active_surface_in_state);
        self.clear_viewed_notification(viewed);
        self.emit(MuxEvent::TreeChanged);
    }

    /// Remember one client's reported focus for its own later reconnection.
    /// Most-recent-first eviction keeps the memory bounded.
    pub fn remember_client_focus(&self, client_id: String, pane: PaneId, tab: Option<usize>) {
        let mut memory = self.client_focus_memory.lock().unwrap();
        memory.retain(|record| record.client_id != client_id);
        memory.push(ClientFocusRecord { client_id, pane, tab });
        if memory.len() > CLIENT_FOCUS_MEMORY_LIMIT {
            let excess = memory.len() - CLIENT_FOCUS_MEMORY_LIMIT;
            memory.drain(..excess);
        }
    }

    /// The remembered focus for one client, if its pane is still alive.
    pub fn client_focus(&self, client_id: &str) -> Option<(PaneId, Option<usize>)> {
        let record = {
            let memory = self.client_focus_memory.lock().unwrap();
            memory.iter().find(|record| record.client_id == client_id).cloned()?
        };
        self.with_state(|state| state.panes.contains_key(&record.pane))
            .then_some((record.pane, record.tab))
    }

    /// Record the session's last reported focus from any client: the
    /// adoption default for a later attach without per-client memory.
    /// Never moves the live shared focus.
    pub fn record_session_focus(&self, pane: PaneId, tab: Option<usize>) {
        *self.last_reported_focus.lock().unwrap() = Some((pane, tab));
    }

    /// The session's last reported focus, if its pane is still alive.
    pub fn session_focus(&self) -> Option<(PaneId, Option<usize>)> {
        let record = (*self.last_reported_focus.lock().unwrap())?;
        self.with_state(|state| state.panes.contains_key(&record.0)).then_some(record)
    }
}

/// Render raw terminal output bytes to plain text by replaying them through
/// a fresh terminal emulator sized to the recorded geometry, then formatting
/// the full page list without escapes ([`ghostty_vt::Terminal::plain_text`]).
/// The scrollback budget is the window's own byte count, so no row of the
/// bounded window is evicted before formatting.
fn render_terminal_output_plain<'a>(
    chunks: impl Iterator<Item = &'a [u8]> + Clone,
    cols: u16,
    rows: u16,
) -> anyhow::Result<String> {
    let scrollback: usize = chunks.clone().map(<[u8]>::len).sum();
    let mut terminal = ghostty_vt::Terminal::new(
        cols.max(1),
        rows.max(1),
        scrollback,
        ghostty_vt::Callbacks::default(),
    )?;
    for chunk in chunks {
        terminal.vt_write(chunk);
    }
    Ok(terminal.plain_text()?)
}

fn terminal_output_read_result(
    text: String,
    start_offset: u64,
    next_offset: u64,
    complete: bool,
) -> Value {
    serde_json::json!({
        "text": text,
        "start_offset": start_offset.to_string(),
        "next_offset": next_offset.to_string(),
        "complete": complete,
    })
}

fn terminal_launch_spec(options: &SurfaceOptions) -> Value {
    let cmux_env = options
        .extra_env
        .iter()
        .map(|(key, _)| key.as_str())
        .filter(|key| {
            matches!(
                *key,
                "CMUX_TUI_SOCKET"
                    | "CMUX_MUX_SOCKET"
                    | "CMUX_TUI_HOOK"
                    | "CMUX_TUI_SESSION_ID"
                    | "CMUX_TUI_TERMINAL_ID"
                    | "CMUX_SIDEBAR"
            )
        })
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
    on_exit: Option<TerminalOnExit>,
) -> anyhow::Result<Value> {
    let mut request = serde_json::json!({
        "argv": argv,
        "cwd": cwd,
        "name": name,
        "size": size,
    });
    // Absent stays absent: a stored creation intent minted before the exit
    // policy existed must recompute its original digest after an upgrade.
    if let Some(on_exit) = on_exit {
        request["on_exit"] = Value::String(on_exit.as_str().to_string());
    }
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
    let tab_ids = topology
        .tabs
        .iter()
        .filter(|tab| tab.content_id == content_id)
        .map(|tab| tab.public_id.clone())
        .collect::<Vec<_>>();
    let surface = state.surface_by_content_public_id(&content_id);
    let (cols, rows) = surface.map(|surface| surface.size()).unwrap_or((80, 24));
    let mut snapshot = serde_json::json!({
        "id": public_id,
        "tab_id": tab_ids.first(),
        "tab_ids": tab_ids,
        "title": surface.map(|surface| surface.title()).unwrap_or_default(),
        "cols": cols.max(1),
        "rows": rows.max(1),
        "running": false,
    });
    if let Some(cwd) = surface.and_then(|surface| surface.published_directory()) {
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

/// Launch spec of a Cloud snapshot's warm terminal host claimed by a fresh
/// registry (Mux::claim_template_terminal).
fn template_terminal_launch_spec() -> Value {
    serde_json::json!({"template_terminal": true})
}

fn is_template_terminal(terminal: &RegistryTerminal) -> bool {
    terminal.launch_spec == template_terminal_launch_spec()
}

fn commit_terminal_transition(
    registry: &mut WorkspaceRegistry,
    event_kind: &str,
    operation: &str,
    terminal: &RegistryTerminal,
) -> anyhow::Result<u64> {
    let mutation = WorkspaceMutation::daemon_local("cmux-tui-runtime");
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
    let mutation = WorkspaceMutation::daemon_local("cmux-tui-runtime");
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

/// Terminate every host record under `root` for one terminal and
/// acknowledge its exit sidecar.
#[cfg(unix)]
fn terminate_discovered_terminal_host_in(
    root: &Path,
    terminal_id: &str,
    incarnation: Option<&str>,
) {
    let Ok(records) = crate::terminal_host_runtime::load_terminal_host_records(root) else {
        return;
    };
    for (path, record) in records {
        if record.terminal_id == terminal_id
            && incarnation.is_none_or(|expected| record.incarnation == expected)
            && !terminate_host_record(record.clone(), path.clone())
        {
            schedule_terminal_host_record_cleanup(record, path);
        }
    }
    pending_terminals::terminate_unadoptable_hosts_in(root, terminal_id);
    let record_path = root.join(format!("{terminal_id}.json"));
    let _ = acknowledge_terminal_exit_sidecar(&record_path, terminal_id, incarnation);
}

#[cfg(unix)]
fn terminate_host_record(
    record: crate::terminal_host_runtime::TerminalHostRecord,
    record_path: std::path::PathBuf,
) -> bool {
    let Ok(mut host) = crate::terminal_host_runtime::adopt_terminal_host(record, record_path)
    else {
        return false;
    };
    let exit_path = host.exit_record_path();
    let exit = host.terminate_and_wait_for_exit();
    host.disconnect();
    let Ok(exit) = exit else { return false };
    acknowledge_exact_terminal_host_exit(&exit_path, &exit)
}

#[cfg(unix)]
fn acknowledge_exact_terminal_host_exit(
    exit_path: &Path,
    exit: &crate::terminal_host_runtime::TerminalHostExitRecord,
) -> bool {
    match crate::terminal_host_runtime::acknowledge_terminal_host_exit_record(exit_path, exit) {
        Ok(true) => true,
        Ok(false) => !exit_path.exists(),
        Err(_) => false,
    }
}

#[cfg(unix)]
fn acknowledge_terminal_exit_sidecar(
    record_path: &Path,
    terminal_id: &str,
    incarnation: Option<&str>,
) -> bool {
    let exit_path = record_path.with_extension("exit");
    let exit = match crate::terminal_host_runtime::terminal_host_exit_record(record_path) {
        Ok(Some((_, exit))) => exit,
        Ok(None) => return !exit_path.exists(),
        Err(_) => return false,
    };
    if exit.terminal_id != terminal_id
        || incarnation.is_some_and(|expected| exit.incarnation != expected)
    {
        return false;
    }
    match crate::terminal_host_runtime::acknowledge_terminal_host_exit_record(&exit_path, &exit) {
        Ok(true) => true,
        Ok(false) => !exit_path.exists(),
        Err(_) => false,
    }
}

#[cfg(unix)]
fn schedule_terminal_host_record_cleanup(
    record: crate::terminal_host_runtime::TerminalHostRecord,
    record_path: std::path::PathBuf,
) {
    let fallback_record = record.clone();
    let fallback_path = record_path.clone();
    let name = format!("terminal-clean-{}", record.terminal_id);
    if std::thread::Builder::new()
        .name(name)
        .spawn(move || retry_terminal_host_record_cleanup(record, record_path))
        .is_err()
    {
        // Thread exhaustion cannot turn a durable close into a permanent
        // orphan. The request may remain blocked, but the exact host keeps
        // being reconciled until it accepts termination or proves itself dead.
        retry_terminal_host_record_cleanup(fallback_record, fallback_path);
    }
}

#[cfg(unix)]
fn retry_terminal_host_record_cleanup(
    record: crate::terminal_host_runtime::TerminalHostRecord,
    record_path: std::path::PathBuf,
) {
    let mut delay = Duration::from_millis(25);
    loop {
        std::thread::sleep(delay);
        if cleanup_terminal_host_record(&record, &record_path) {
            return;
        }
        delay = (delay * 2).min(Duration::from_secs(5));
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

fn insert_surface_checked(state: &mut State, surface: Arc<Surface>) -> anyhow::Result<()> {
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
        if matches!(identity.content_id, ContentPublicId::Browser(_))
            && state.resource_indexes.content_placements.contains_key(&identity.content_id)
        {
            anyhow::bail!("duplicate_content_id");
        }
    }
    if let Some(identity) = surface.resource_identity()
        && let ContentPublicId::Terminal(terminal_id) = &identity.content_id
    {
        anyhow::ensure!(
            surface.terminal_public_id() == Some(terminal_id),
            "terminal placement identity does not match its runtime"
        );
    }
    register_terminal_runtime_checked(state, &surface)?;
    // Surface insertion is the only way a tab placement enters live state, so
    // it is also where the topology takes ownership of that tab's identity.
    // Every later reader takes identity from the topology, never from here.
    if let Some(identity) = surface.resource_identity().cloned() {
        state.register_tab_identity(surface.id, &identity);
    }
    state.surfaces.insert(surface.id, surface);
    Ok(())
}

fn insert_terminal_runtime_checked(state: &mut State, surface: Arc<Surface>) -> anyhow::Result<()> {
    anyhow::ensure!(surface.kind() == SurfaceKind::Pty, "terminal catalog requires a PTY");
    anyhow::ensure!(
        surface.resource_identity().is_none(),
        "unplaced terminal runtime cannot carry a tab identity"
    );
    register_terminal_runtime_checked(state, &surface)
}

fn insert_restored_terminal_runtime_checked(
    state: &mut State,
    surface: Arc<Surface>,
) -> anyhow::Result<()> {
    let terminal_id = surface
        .terminal_public_id()
        .cloned()
        .context("restored terminal omitted its public content identity")?;
    let content_id = ContentPublicId::Terminal(terminal_id);
    let placements = state.placements_of_content(&content_id).to_vec();
    if placements.is_empty() {
        return insert_terminal_runtime_checked(state, surface);
    }

    anyhow::ensure!(
        placements.contains(&surface.id),
        "restored terminal runtime is not one of its durable placements"
    );
    insert_surface_checked(state, surface.clone())?;
    for placement in placements.into_iter().filter(|placement| *placement != surface.id) {
        anyhow::ensure!(
            !state.surfaces.contains_key(&placement),
            "restored terminal placement is already materialized"
        );
        let tab_id = state
            .resource_indexes
            .tab_ids
            .get(&placement)
            .cloned()
            .context("restored terminal placement has no tab identity")?;
        let projected = surface
            .project_terminal(placement, TabResourceIdentity::new(tab_id, content_id.clone()))?;
        insert_surface_checked(state, projected)?;
    }
    Ok(())
}

fn register_terminal_runtime_checked(
    state: &mut State,
    surface: &Arc<Surface>,
) -> anyhow::Result<()> {
    let Some(terminal_id) = surface.terminal_public_id() else {
        return Ok(());
    };
    let runtime_id = surface
        .terminal_runtime_id()
        .context("terminal content identity requires a PTY runtime")?;
    if let Some(existing) = state.terminal_catalog_by_runtime.get(&runtime_id) {
        anyhow::ensure!(existing == terminal_id, "terminal runtime has two content identities");
    }
    if let Some(existing) = state.terminal_catalog.get(terminal_id) {
        anyhow::ensure!(
            existing.shares_terminal_runtime(surface),
            "terminal content identity points at two runtimes"
        );
    } else {
        state.insert_catalog_terminal(terminal_id, surface)?;
    }
    state.terminal_catalog_by_runtime.insert(runtime_id, terminal_id.clone());
    Ok(())
}

/// Remove a terminal catalog owner and every view that projects it. Durable
/// exit and explicit close share this path so multiview teardown cannot leave
/// a reverse catalog entry or a secondary placement behind. The runtime is
/// optional because restored topology exists before host adoption.
fn remove_terminal_content_from_state(
    mux: &Mux,
    state: &mut State,
    terminal_id: &TerminalPublicId,
) -> (Option<Arc<Surface>>, Vec<Arc<Surface>>, bool) {
    let runtime = state.remove_catalog_terminal(terminal_id);
    let mut targets =
        state.placements_of_content(&ContentPublicId::Terminal(terminal_id.clone())).to_vec();
    if let Some(runtime_id) = runtime.as_ref().and_then(|runtime| runtime.terminal_runtime_id()) {
        targets.extend(state.surfaces.iter().filter_map(|(placement, candidate)| {
            (candidate.terminal_runtime_id() == Some(runtime_id)).then_some(*placement)
        }));
    }
    targets.sort_unstable();
    targets.dedup();
    let mut removed = Vec::with_capacity(targets.len());
    let mut split_index_dirty = false;
    for target in targets {
        let (candidate, topology_changed) = remove_surface(mux, state, target);
        split_index_dirty |= topology_changed;
        if let Some(candidate) = candidate {
            removed.push(candidate);
        }
    }
    if split_index_dirty {
        Mux::rebuild_split_screen_index(state);
    }
    (runtime, removed, split_index_dirty)
}

/// Remove one known terminal runtime and every placement that projects it.
/// Ordinary topology removal must leave the catalog owner alive so a terminal
/// can have zero views and be projected again later.
fn remove_terminal_runtime_from_state(
    mux: &Mux,
    state: &mut State,
    runtime: &Surface,
) -> (Vec<Arc<Surface>>, bool) {
    let Some(terminal_id) = runtime.terminal_public_id().cloned() else {
        return (Vec::new(), false);
    };
    if !state
        .terminal_catalog
        .get(&terminal_id)
        .is_some_and(|catalogued| catalogued.shares_terminal_runtime(runtime))
    {
        return (Vec::new(), false);
    }
    let (_, removed, split_index_dirty) =
        remove_terminal_content_from_state(mux, state, &terminal_id);
    (removed, split_index_dirty)
}

fn validate_terminal_hex(value: &str, error: &'static str) -> anyhow::Result<()> {
    if TerminalId::from_hex(value).is_none() {
        anyhow::bail!(error);
    }
    Ok(())
}

fn unique_terminal_match<T>(
    terminal_id: &str,
    identities: impl IntoIterator<Item = (T, TerminalHostIdentity)>,
) -> anyhow::Result<Option<(T, TerminalHostIdentity)>> {
    let mut found = None;
    for (value, identity) in identities {
        if identity.terminal_id != terminal_id {
            continue;
        }
        anyhow::ensure!(found.is_none(), "duplicate_terminal_id");
        found = Some((value, identity));
    }
    Ok(found)
}

/// Return one materialized view of `runtime`. The public reverse index is the
/// steady-state fast path. The runtime scan also admits a newly-created view
/// before it has been inserted into a pane: creation must bind that reserved
/// tab exactly once, while a detached zero-view terminal has no entry in
/// `state.surfaces` and therefore remains detached.
fn terminal_placement_for_runtime(state: &State, runtime: &Surface) -> Option<SurfaceId> {
    let terminal_id = runtime.terminal_public_id()?;
    state
        .placements_of_content(&ContentPublicId::Terminal(terminal_id.clone()))
        .iter()
        .copied()
        .find(|placement| {
            state
                .surfaces
                .get(placement)
                .is_some_and(|surface| surface.shares_terminal_runtime(runtime))
        })
        .or_else(|| {
            state
                .surfaces
                .iter()
                .filter_map(|(placement, surface)| {
                    (surface.shares_terminal_runtime(runtime)
                        && surface.resource_identity().is_some())
                    .then_some(*placement)
                })
                .min()
        })
}

/// Return one representative for each content runtime plus every nonterminal
/// surface. Runtime-wide mutations must not repeat host I/O or render work for
/// every terminal view, and catalog-only terminals still need those updates.
fn unique_surface_runtimes(state: &State) -> Vec<Arc<Surface>> {
    let mut seen_terminals = HashSet::new();
    state
        .terminal_catalog
        .values()
        .chain(state.surfaces.values())
        .filter(|surface| {
            surface.terminal_runtime_id().is_none_or(|runtime| seen_terminals.insert(runtime))
        })
        .cloned()
        .collect()
}

fn sidebar_retry_delay(failures: u32) -> Duration {
    let shift = failures.saturating_sub(1).min(5);
    Duration::from_secs(1u64 << shift)
}

impl Drop for Mux {
    fn drop(&mut self) {
        self.journal_plugin.shutdown();
        self.finalize_terminal_journal("mux drop");
        self.journal_kernel.shutdown();
        if let Ok(runtime) = self.browser_runtime.get_mut()
            && let Some(runtime) = runtime.take()
        {
            runtime.shutdown();
        }
    }
}

fn expected_panes_by_screen(
    panes: &[RegistryPane],
) -> HashMap<ScreenPublicId, HashSet<PanePublicId>> {
    let mut panes_by_screen: HashMap<ScreenPublicId, HashSet<PanePublicId>> = HashMap::new();
    for pane in panes {
        panes_by_screen.entry(pane.screen_id.clone()).or_default().insert(pane.public_id.clone());
    }
    panes_by_screen
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
        indexes.content_placements.entry(tab.content_id.clone()).or_default().push(slot);
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
    let panes_by_screen = expected_panes_by_screen(&topology.panes);
    let empty_expected_panes = HashSet::new();
    for screen in &topology.screens {
        let expected_panes =
            panes_by_screen.get(&screen.public_id).unwrap_or(&empty_expected_panes);
        crate::workspace_registry::validate_registry_screen_projection(screen, expected_panes)?;
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
        let creation_order_auto_layout = screen
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
            creation_order_auto_layout,
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
            terminal_catalog: HashMap::new(),
            terminal_catalog_by_runtime: HashMap::new(),
            terminal_catalog_by_host: HashMap::new(),
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
                if let Some(panes) = column.creation_order_auto_layout.as_mut() {
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
                        column.creation_order_auto_layout = None;
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
    if let Some(panes) = screen.creation_order_auto_layout.as_mut() {
        panes.retain(|candidate| *candidate != pane);
        if let Some(layout) =
            crate::layout::zellij_default_pane_layout_with_ids(panes, &mut || mux.next_id())
        {
            root = layout;
            if let Some(expanded) = stack_expanded {
                root.expand_stack_pane(expanded);
            }
        } else {
            screen.creation_order_auto_layout = None;
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
    notifications: &TreeDecorations,
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
            transaction: None,
        });
    }
    close_pane_delta(state, notifications, pane_id)
}

fn close_pane_delta(
    state: &State,
    notifications: &TreeDecorations,
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
            transaction: None,
        });
    }
    close_screen_delta(state, notifications, screen.id)
}

fn close_screen_delta(
    state: &State,
    notifications: &TreeDecorations,
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
        transaction: None,
    })
}

fn close_workspace_delta(
    state: &State,
    notifications: &TreeDecorations,
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
        transaction: None,
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
/// pane, and collapse emptied panes/screens. An emptied workspace stays
/// here; the close plan closes it (`close_emptied_workspaces_locked`). Returns the removed surface and whether
/// split ownership or positional indexes changed. Runs under the state lock.
fn remove_surface(mux: &Mux, state: &mut State, target: SurfaceId) -> (Option<Arc<Surface>>, bool) {
    let previous_active = state.active_pane();
    // Capture the placement and its screen before removing reverse indexes.
    // Teardown often removes many last-tab panes in a row, so resolving these
    // relationships from the topology after index deletion would repeatedly
    // scan every pane and split tree.
    let pane_id = state
        .resource_indexes
        .tab_pane
        .get(&target)
        .copied()
        .filter(|pane| state.panes.get(pane).is_some_and(|pane| pane.tabs.contains(&target)))
        .or_else(|| {
            state.panes.values().find(|pane| pane.tabs.contains(&target)).map(|pane| pane.id)
        });
    let screen_location = pane_id.and_then(|pane| state.screen_of(pane));
    let removed = state.surfaces.remove(&target);
    if let Some(tab_id) = state.resource_indexes.tab_ids.remove(&target) {
        state.resource_indexes.tabs.remove(&tab_id);
    }
    if let Some(content_id) = state.resource_indexes.content_ids.remove(&target) {
        let remove_content = if let Some(placements) =
            state.resource_indexes.content_placements.get_mut(&content_id)
        {
            placements.retain(|placement| *placement != target);
            placements.is_empty()
        } else {
            false
        };
        if remove_content {
            state.resource_indexes.content_placements.remove(&content_id);
        }
    }
    state.resource_indexes.tab_pane.remove(&target);
    let Some(pane_id) = pane_id else {
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
    let Some((wi, si)) = screen_location else {
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
    state.resource_indexes.tab_pane.insert(surface, target_pane);
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
mod tests;

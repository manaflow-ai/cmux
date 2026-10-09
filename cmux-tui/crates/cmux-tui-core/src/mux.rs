//! The multiplexer: owns the session [`State`] and every surface runtime,
//! and broadcasts [`MuxEvent`]s to subscribed frontends.

mod agent_hook_errors;
mod terminal_exit_snapshot;
use terminal_exit_snapshot::{
    render_terminal_output_plain, run_placement_for_surface, terminal_exit_snapshot_in_state,
    terminal_output_read_result,
};
mod terminal_records;
#[cfg(test)]
use terminal_records::commit_terminal_workspace;
use terminal_records::{
    commit_terminal_transition, is_template_terminal, template_terminal_launch_spec,
    terminal_create_fingerprint, terminal_launch_spec, terminal_lifecycle_name,
};
#[cfg(unix)]
mod terminal_host_records;
#[cfg(unix)]
use terminal_host_records::{
    acknowledge_exact_terminal_host_exit, cleanup_terminal_host_record,
    terminal_host_record_liveness, terminate_discovered_terminal_host_in,
};
mod terminal_runtime_index;
use terminal_runtime_index::{
    insert_restored_terminal_runtime_checked, insert_surface_checked,
    remove_terminal_content_from_state, remove_terminal_runtime_from_state,
    terminal_placement_for_runtime, unique_surface_runtimes, unique_terminal_match,
    validate_terminal_hex,
};
mod restore;
#[cfg(test)]
use restore::expected_panes_by_screen;
use restore::{restore_layout_node_from_known_splits, restore_resource_state};
mod tree_edit;
use tree_edit::{
    active_tree_selection, append_to_auto_layout, clamp_split_ratio, close_pane_delta,
    close_screen_delta, close_surface_delta, close_workspace_delta, collapse_empty_pane,
    current_focus_identity, fence_layout_undo_for_tab_membership, layout_undo_confirmation_details,
    move_tab_in_state, remove_surface, resolve_workspace_index, restore_focus_identity,
    screen_tabs, stamp_changed_active_pane, stamp_pane_focus, surface_screen_id, unique_screen_ids,
    workspace_mutation_result,
};
mod agent_reports;
mod agent_roster_fold;
mod agent_roster_restore;
mod apply_layout;
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
mod focus;
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
mod layout_resize;
mod layout_types;
mod layout_undo;
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
mod startup_restore;
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
mod terminal_move;
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
mod workspace_move;
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

#[cfg(test)]
mod tests;

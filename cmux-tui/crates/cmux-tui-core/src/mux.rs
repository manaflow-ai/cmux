//! The multiplexer: owns the session [`State`] and every surface runtime,
//! and broadcasts [`MuxEvent`]s to subscribed frontends.

mod agent_hook_errors;
mod agent_roster_restore;
mod browser_tab_create;
mod closed_workspace_replay;
#[cfg(test)]
mod legacy_actor_test_wrappers;
#[cfg(test)]
mod test_actor_wrappers;
mod topology_edit;
mod topology_ops;
pub(crate) use browser_tab_create::{
    FRONTEND_BROWSER_ACTIVATE_CAPABILITY, FRONTEND_BROWSER_INSERT_AFTER_CAPABILITY,
    FrontendTabPlacement, frontend_fields as frontend_browser_fields,
};
pub(crate) mod app_terminals;
mod cloud_conversations;
mod conversations;
mod deadline_fanout;
#[cfg(test)]
use deadline_fanout::DeadlineCompletion;
use deadline_fanout::{
    CELL_PIXEL_FANOUT_MAX_WORKERS, DeadlineFanoutPool, DeadlineMapResult, DeadlinePending,
    bounded_deadline_map,
};
mod dock_columns;
mod exit_settle;
mod host_close;
#[cfg(all(test, unix))]
mod host_death_tests;
mod idle_close;
mod journal_plugin_host;
mod journal_retention;
mod kitty_reservation;
use kitty_reservation::{kitty_image_limits_exceed, kitty_image_limits_within};
pub(crate) mod layout_invariants;
mod layout_ratio_error;
mod layout_undo_commit;
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
mod resource_tab_deltas;
#[cfg(test)]
mod resource_tab_deltas_tests;
mod resource_topology;
mod rows;
mod screen_changed;
pub(crate) mod screen_groups;
mod signaled_mutex;
pub(crate) use signaled_mutex::SignaledMutex;
mod session_paths;
pub(crate) mod tab_drag;
pub(crate) mod tab_groups;
pub(crate) mod tab_strip;
mod tab_workspace_name;

pub(crate) use crate::state::{PersonalChange, ScreenChange, WorkspaceStatusChange};
pub(crate) use tab_strip::StripRequest;
mod loss_causes;
mod orphan_hosts;
mod pending_terminals;
pub(crate) mod terminal_archive;
mod terminal_directory;
mod terminal_lifecycle_commit;
use terminal_lifecycle_commit::commit_terminal_lifecycle;
mod terminal_exit;
mod terminal_move_topology;
mod terminal_progress;
mod terminal_reap;
#[cfg(unix)]
mod terminal_rehost;
mod terminal_relaunch;
mod terminal_respawn;
mod terminal_work;
mod topology_result;

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
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
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

/// Structured graphics failures localized by the presentation frontend.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GraphicsStatus {
    KittyImageBudgetWorkerStartFailed { error: Arc<str> },
    KittyImageBudgetUpdateFailed { retry_exhausted: bool, summary: Arc<str> },
    CellPixelUpdateRetriesExhausted { attempts: u8, remaining: usize, cell_pixels: (u16, u16) },
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
    /// A surface's child exited. Hosted terminal views have been atomically
    /// detached while their durable exit receipt remains queryable; local
    /// terminals have already been reaped when this arrives.
    SurfaceExited(SurfaceId),
    TitleChanged {
        surface: SurfaceId,
        title: Arc<str>,
    },
    /// The latest agent state for one surface changed.
    AgentChanged {
        surface: SurfaceId,
        state: Arc<str>,
        source: Arc<str>,
        session: Option<Arc<str>>,
        agent: Option<Arc<str>>,
        updated_at_ms: u64,
    },
    Bell(SurfaceId),
    Notification(NotificationEvent),
    GraphicsStatus(GraphicsStatus),
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
    /// The home session's personal state (rooms, sessions, personal groups
    /// and order; `profiles-v1`) changed. Consumers refetch `list-personal`.
    PersonalChanged {
        personal_revision: u64,
    },
    BookmarksChanged(personal::BookmarksChange),
    Conversation(Arc<crate::conversation_store::ConversationEvent>),
    /// An event of the cloud conversations proxy (`cloud-conversations-v1`).
    CloudConversation(Arc<crate::cloud_conversations::CloudEvent>),
    /// A durable terminal-registry mutation committed. Consumers use this as
    /// a barrier, then fetch `terminal-events` or a fresh snapshot.
    TerminalRegistryChanged {
        registry_id: String,
        generation: String,
        terminal_revision: u64,
    },
    /// The owner ended a terminal that had no tab placement for the reap
    /// grace period and was not marked `keep` (`terminal-reap-v1`).
    TerminalReaped {
        /// Stable terminal host id.
        terminal_id: String,
        /// Public `term_` resource id, when the terminal had one.
        terminal: Option<String>,
        grace_ms: u64,
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
    /// The shared sizing state of a terminal changed. Emitted once per
    /// placement of the terminal runtime; `generation` orders the states.
    SizeStateChanged {
        surface: SurfaceId,
        runtime: SurfaceId,
        state: Arc<TerminalSizingState>,
    },
    /// A recovered event subscription may have missed client lifecycle
    /// events, so consumers must reload the authoritative client list.
    ClientListInvalidated,
    /// An unauthenticated browser is waiting for a trusted TUI decision.
    PairingRequested(PairingChallenge),
    /// A pairing request was approved, denied, disconnected, or expired.
    PairingResolved {
        request: u64,
    },
    /// The daemon's machine-level model spend readout changed. `None` means
    /// the readout is unavailable and frontends must hide it.
    MachineUsageChanged(Option<MachineUsage>),
    /// Every workspace is gone.
    Empty,
}

/// Machine-level model spend for the machine hosting this daemon, as
/// reported by coderouter for the trailing `period_days` window. Frontends
/// show it as an informational readout beside the machine identity.
#[derive(Debug, Clone, PartialEq)]
pub struct MachineUsage {
    pub vm_id: String,
    pub period_days: u32,
    pub total_tokens: u64,
    pub api_equivalent_usd: f64,
    /// Server-side timestamp of the snapshot, when known.
    pub as_of: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TreeDeltaKind {
    WorkspaceAdded,
    WorkspaceClosed,
    WorkspaceRenamed,
    WorkspaceMoved,
    /// Workspace presentation (color, icon, title) changed.
    WorkspaceChanged,
    ScreenAdded,
    ScreenClosed,
    ScreenRenamed,
    /// Screen presentation (color, icon, pin, group) or position changed.
    ScreenChanged,
    PaneAdded,
    PaneClosed,
    TabAdded,
    TabClosed,
    TabRenamed,
    /// Tab metadata (pinned flag, directory, git HEAD, unread marker)
    /// changed.
    TabChanged,
}

impl TreeDeltaKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::WorkspaceAdded => "workspace-added",
            Self::WorkspaceClosed => "workspace-closed",
            Self::WorkspaceRenamed => "workspace-renamed",
            Self::WorkspaceMoved => "workspace-moved",
            Self::WorkspaceChanged => "workspace-changed",
            Self::ScreenAdded => "screen-added",
            Self::ScreenClosed => "screen-closed",
            Self::ScreenRenamed => "screen-renamed",
            Self::ScreenChanged => "screen-changed",
            Self::PaneAdded => "pane-added",
            Self::PaneClosed => "pane-closed",
            Self::TabAdded => "tab-added",
            Self::TabClosed => "tab-closed",
            Self::TabRenamed => "tab-renamed",
            Self::TabChanged => "tab-changed",
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
    /// The client transaction id of the command that caused this delta, so
    /// a frontend can reconcile its optimistic UI.
    pub transaction: Option<Arc<str>>,
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

/// Who posted a notification (`notification-source-v1`). Frontends apply
/// per-source preferences from it instead of guessing.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum NotificationSource {
    /// `cmux notify`, the `notify` verb without a source, or
    /// `notification.create`.
    Cli,
    /// A program in the terminal: OSC 9, OSC 777 `notify` or kitty OSC 99,
    /// parsed by the daemon from the terminal's output.
    Terminal,
    /// An agent hook (Claude Code, Codex, ...), daemon-side or reported by a
    /// frontend.
    Agent,
    /// Any other daemon producer.
    Daemon,
}

impl NotificationSource {
    pub fn as_str(self) -> &'static str {
        match self {
            NotificationSource::Cli => "cli",
            NotificationSource::Terminal => "terminal",
            NotificationSource::Agent => "agent",
            NotificationSource::Daemon => "daemon",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "cli" => Some(NotificationSource::Cli),
            "terminal" => Some(NotificationSource::Terminal),
            "agent" => Some(NotificationSource::Agent),
            "daemon" => Some(NotificationSource::Daemon),
            _ => None,
        }
    }

    /// The source of a durable notification written before sources existed,
    /// from its idempotency key: agent hooks mint `agent-hook-notification-*`;
    /// every other producer then was `notify` or `notification.create`.
    pub(crate) fn from_legacy_key(idempotency_key: &str) -> Self {
        if idempotency_key.starts_with("agent-hook-notification-") {
            NotificationSource::Agent
        } else {
            NotificationSource::Cli
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
    pub source: NotificationSource,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResourceNotification {
    pub id: NotificationPublicId,
    pub title: String,
    /// Second line under the title, as `cmux notify --subtitle`.
    pub subtitle: Option<String>,
    pub body: String,
    pub level: NotificationLevel,
    pub terminal_id: Option<TerminalPublicId>,
    pub created_at_ms: u64,
    pub source: NotificationSource,
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
    /// An installed userland agent plugin wrote the observation.
    Plugin,
    /// Legacy source value emitted by pre-userland screen detection. Current
    /// core code never emits it; the reducer keeps it so old journals replay
    /// after screen detection moves to a userland plugin.
    Detected,
    Socket,
    Hook,
}

impl AgentSource {
    pub fn as_str(self) -> &'static str {
        match self {
            AgentSource::Plugin => "plugin",
            AgentSource::Detected => "detected",
            AgentSource::Socket => "socket",
            AgentSource::Hook => "hook",
        }
    }
}

/// The agent-record state a committed hook journal event implies, or `None`
/// for events that carry no lifecycle transition (child agents, unclassified
/// state changes) so they never churn the record.
fn agent_state_for_hook_kind(kind: &str) -> Option<AgentState> {
    Some(match kind {
        // A freshly started session sits at its prompt; a completed turn
        // returns to it.
        "agent.session.started" | "agent.turn.completed" => AgentState::Idle,
        "agent.turn.started" => AgentState::Working,
        "agent.approval.requested"
        | "agent.question.requested"
        | "agent.plan_review.requested"
        | "agent.error.reported" => AgentState::Blocked,
        "agent.session.ended" => AgentState::Done,
        _ => return None,
    })
}

/// Title, body, and level for the notification an agent hook event earns,
/// or `None` for transitions that need no attention (session start, turn
/// start, child lifecycle, session end).
fn agent_hook_notification(
    ingress: &crate::JournalIngress,
) -> Option<(String, String, NotificationLevel)> {
    const BODY_MAX_CHARS: usize = 512;
    let (verb, level) = match ingress.kind.as_str() {
        "agent.turn.completed" => ("finished", NotificationLevel::Info),
        "agent.approval.requested" => ("needs approval", NotificationLevel::Warning),
        "agent.question.requested" => ("asked a question", NotificationLevel::Warning),
        "agent.plan_review.requested" => ("requested plan review", NotificationLevel::Warning),
        "agent.error.reported" => ("reported an error", NotificationLevel::Error),
        _ => return None,
    };
    let adapter = ingress
        .payload
        .get("adapter")
        .and_then(|adapter| adapter.get("id"))
        .and_then(Value::as_str)
        .filter(|id| !id.is_empty())
        .unwrap_or("Agent");
    let mut agent = String::with_capacity(adapter.len());
    let mut chars = adapter.chars();
    if let Some(first) = chars.next() {
        agent.extend(first.to_uppercase());
        agent.push_str(chars.as_str());
    }
    // Prompt and message text is redacted before the journal accepts it, so
    // the body is the one structural field a viewer can act on: the tool an
    // approval is waiting on. Everything else stays empty rather than leaking
    // a redaction marker into the notification feed.
    let normalized = ingress.payload.get("normalized");
    let body = ["tool_name"]
        .into_iter()
        .filter_map(|field| normalized.and_then(|value| value.get(field)).and_then(Value::as_str))
        .map(str::trim)
        .find(|text| !text.is_empty() && *text != "[redacted]")
        .map(|text| text.chars().take(BODY_MAX_CHARS).collect::<String>())
        .unwrap_or_default();
    Some((format!("{agent} {verb}"), body, level))
}

/// A stored projection state string as its typed form; unknown spellings
/// degrade to `Unknown`, which every agents view hides.
fn parse_projection_agent_state(value: &str) -> AgentState {
    match value {
        "working" => AgentState::Working,
        "blocked" => AgentState::Blocked,
        "idle" => AgentState::Idle,
        "done" => AgentState::Done,
        _ => AgentState::Unknown,
    }
}

/// The agent roster host: reducer state plus its journal fold cursor.
/// Lock ordering rule: never acquire another `Mux` lock while holding this
/// one - fold paths release it before persisting, and commit paths only
/// take a read after their registry/state locks, so `registry -> roster`
/// is the single global order.
#[derive(Debug, Default)]
struct AgentRosterHost {
    roster: crate::journal_reducers::AgentRoster,
    cursor: u64,
}

fn agent_provider_identity(ingress: &crate::JournalIngress) -> Option<String> {
    ingress
        .payload
        .get("normalized")
        .and_then(|normalized| normalized.get("agent_type"))
        .and_then(Value::as_str)
        .or_else(|| {
            ingress
                .payload
                .get("adapter")
                .and_then(|adapter| adapter.get("id"))
                .and_then(Value::as_str)
        })
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_ascii_lowercase)
}

#[derive(Debug, Clone)]
pub struct AgentRecord {
    pub surface: SurfaceId,
    pub terminal_id: TerminalPublicId,
    pub state: AgentState,
    pub source: AgentSource,
    pub session: Option<String>,
    /// The reporting adapter id (`claude`, `codex`, ...) when a hook has
    /// claimed the terminal; absent for socket-only reports.
    pub agent: Option<String>,
    pub updated_at_ms: u64,
}

/// Longest hook session id published for resume. Claude session ids are
/// UUIDs; longer values are dropped rather than truncated into a wrong id.
const MAX_PUBLISHED_AGENT_SESSION_ID_BYTES: usize = 256;

/// The hook session id a client may use to resume the agent, or `None` for
/// the local generation token that session-less adapters receive and for ids
/// that are too long or contain anything beyond `[A-Za-z0-9._:-]`. Hook
/// payloads can come from remote hosts, and clients pass the id to a resume
/// command.
fn published_agent_session_id(terminal_id: &TerminalPublicId, session_id: &str) -> Option<String> {
    let portable = !session_id.is_empty()
        && session_id.len() <= MAX_PUBLISHED_AGENT_SESSION_ID_BYTES
        && session_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b':' | b'-'));
    (portable && !session_id.starts_with(&format!("legacy:{terminal_id}:")))
        .then(|| session_id.to_owned())
}

/// Session-less adapters get a local generation token. The journal sequence
/// is durable and strictly increasing, so a new legacy lifecycle cannot reuse
/// the previous fence identity after restart.
pub(super) fn legacy_hook_session_id(terminal_id: &TerminalPublicId, sequence: u64) -> String {
    crate::journal_reducers::legacy_hook_session_id(terminal_id.as_str(), sequence)
}

#[derive(Debug, Clone)]
struct TerminalAgentRecord {
    state: AgentState,
    source: AgentSource,
    session: Option<String>,
    agent: Option<String>,
    /// The agent's own session id from its hook stream (Claude's
    /// `session_id`), published as `extra.agent_session_id` so clients can
    /// resume it. Absent for agents without a native hook session.
    agent_session_id: Option<String>,
    updated_at_ms: u64,
}

/// Who initiated an agent projection commit: a direct socket/SDK report
/// (which must echo its intent into the journal so the roster fold sees
/// it), or the roster fold itself applying a journal-derived delta (which
/// must not echo, or every hook event would append a second record).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum AgentReportOrigin {
    Direct,
    RosterFold,
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
    pub source: NotificationSource,
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

    pub(crate) fn from_workspace_registry(
        session: String,
        surface_options: SurfaceOptions,
        registry: WorkspaceRegistry,
        provider_workspace: ProviderWorkspaceState,
        #[cfg_attr(not(test), allow(unused_variables))] test_surface_runtime: bool,
    ) -> anyhow::Result<Arc<Self>> {
        let snapshot = registry.snapshot()?;
        let topology = registry.resource_topology_snapshot()?;
        let session_shutdown = crate::session_shutdown::SessionShutdownClock::open(
            registry
                .session_journal_database_path()
                .map(|database| crate::session_shutdown::owner_shutdown_marker_path(&database)),
            crate::session_shutdown::unix_now_ms(),
        );
        let RestoredResourceState { mut state, next_id, contents } =
            restore_resource_state(snapshot, topology)?;
        let RestoredPublicProjections {
            default_colors,
            has_terminal_defaults,
            next_notification_id,
            agent_records,
            agent_hook_fences,
            terminal_notifications,
            notification_ledger,
            notification_reads,
        } = restore_public_projections(&state, registry.public_projections()?)?;
        let agent_roster_restore::RestoredAgentRoster {
            host: agent_roster,
            diagnostic: agent_roster_diagnostic,
        } = agent_roster_restore::restore_agent_roster(&registry)?;
        let presentation = registry.presentation_snapshot()?;
        let journal_producers = registry.journal_producer_manifests()?;
        let session_public_id = registry.session_id().clone();
        let machine_public_id = registry.machine_id().clone();
        let journal_kernel = crate::journal_kernel::JournalKernel::new(
            registry.session_journal_database_path(),
            &journal_producers,
        )?;
        let (journal_ingress, journal_ingress_receiver) =
            crate::journal_ingress::JournalIngressSender::new(
                registry.session_journal_database_path().is_some(),
            );
        Self::rebuild_split_screen_index(&mut state);
        let resource_projection_stats = registry.resource_projection_stats().clone();
        let mux = Arc::new(Mux {
            workspace_registry: SignaledMutex::new(registry),
            session_public_id,
            machine_public_id,
            connection_stats: Arc::default(),
            resource_projection_stats,
            started_at: Instant::now(),
            state: Mutex::new(state),
            subscribers: MuxEventBroadcaster::default(),
            config_reload: Mutex::new(ConfigReloadState::default()),
            config_reload_changed: Condvar::new(),
            next_id: AtomicU64::new(next_id),
            next_notification_id: AtomicU64::new(next_notification_id),
            next_active_at: AtomicU64::new(1),
            next_in_process_resize_owner: AtomicU64::new(1),
            surface_options: Mutex::new(surface_options),
            provider_managed: AtomicBool::new(provider_workspace.managed),
            provider_workspace: Mutex::new(provider_workspace),
            workspace_lifecycles: Mutex::new(HashMap::new()),
            pending_workspace_surfaces: Mutex::new(HashMap::new()),
            client_sizing_lifecycle: Mutex::new(()),
            client_sizing: Mutex::new(ClientSizingState::default()),
            client_focus_memory: Mutex::new(Vec::new()),
            last_reported_focus: Mutex::new(None),
            conversations: Default::default(),
            cloud_conversations: OnceLock::new(),
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
            workspace_delta_before_emit: Mutex::new(None),
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
            terminal_spawn_after_cell_pixel_snapshot: Mutex::new(None),
            #[cfg(test)]
            terminal_spawn_before_cell_pixel_reconcile: Mutex::new(None),
            #[cfg(test)]
            terminal_create_after_terminal_reservation: Mutex::new(None),
            pending_terminal_hosts: Mutex::new(HashMap::new()),
            reserved_in_process_terminals: Mutex::new(HashMap::new()),
            #[cfg(test)]
            viewport_split_after_spawn: Mutex::new(None),
            #[cfg(test)]
            resource_mutation_metrics: Mutex::new(None),
            #[cfg(test)]
            resource_projection_before_commit: Mutex::new(None),
            #[cfg(test)]
            resource_close_after_commit: Mutex::new(None),
            #[cfg(test)]
            layout_undo_before_commit: Mutex::new(None),
            #[cfg(test)]
            resource_close_cleanup: Mutex::new(None),
            browser_providers: Arc::new(BrowserProviderRegistry::default()),
            browser_runtime: Mutex::new(None),
            active_render_attachments: Arc::new(AtomicUsize::new(0)),
            deadline_fanout_pool: DeadlineFanoutPool::new(),
            kitty_image_budget: Mutex::new(KittyImageBudgetState::default()),
            kitty_image_budget_changed: Condvar::new(),
            app_terminals: Mutex::default(),
            #[cfg(debug_assertions)]
            terminal_host_reconnect_completion_failures: AtomicU64::new(
                std::env::var("CMUX_TUI_TEST_RECONNECT_COMPLETION_FAILURES")
                    .ok()
                    .and_then(|value| value.parse().ok())
                    .unwrap_or(0),
            ),
            #[cfg(debug_assertions)]
            terminal_host_test_disconnect_after_spawn_ms: AtomicU64::new(
                std::env::var("CMUX_TUI_TEST_DISCONNECT_HOST_AFTER_SPAWN_MS")
                    .ok()
                    .and_then(|value| value.parse().ok())
                    .unwrap_or(0),
            ),
            #[cfg(test)]
            kitty_image_budget_operation: Mutex::new(None),
            cell_pixel_lifecycle: Mutex::new(()),
            next_cell_pixel_generation: AtomicU64::new(1),
            cell_pixels: Mutex::new((8, 16)),
            pending_cell_pixels: Mutex::new(None),
            cell_pixel_retries: Mutex::new(CellPixelRetryQueue::default()),
            #[cfg(test)]
            cell_pixel_before_publish: Mutex::new(None),
            #[cfg(test)]
            cell_pixel_operation: Mutex::new(None),
            #[cfg(test)]
            cell_pixel_fanout_timeout: Mutex::new(None),
            default_colors: Mutex::new(default_colors),
            durable_terminal_defaults: AtomicBool::new(has_terminal_defaults),
            sidebar_plugin: Mutex::new(SidebarPluginRuntime::default()),
            journal_plugin: crate::journal_plugin::JournalPluginRuntime::default(),
            machine_usage: Mutex::new(None),
            agent_records: Mutex::new(agent_records),
            agent_hook_fences: Mutex::new(agent_hook_fences),
            agent_roster: Mutex::new(agent_roster),
            agent_roster_fold: Mutex::new(()),
            placement_notifications: Mutex::new(HashMap::new()),
            terminal_notifications: Mutex::new(terminal_notifications),
            terminal_command_history: AtomicBool::new(false),
            shell_command_journal: Mutex::new(None),
            notification_ledger: Mutex::new(notification_ledger),
            notification_reads: Mutex::new(notification_reads),
            notification_read_prunes: Mutex::new(Vec::new()),
            presentation: Mutex::new(Arc::new(presentation)),
            git_heads: Mutex::new(HashMap::new()),
            resource_machine_service: OnceLock::new(),
            journal_kernel,
            journal_ingress,
            journal_hook_dispatcher_started: AtomicBool::new(false),
            journal_hook_runtime: Arc::new(crate::journal_hooks::JournalHookRuntime::default()),
            journal_event_epoch: Mutex::new(0),
            journal_event_changed: Condvar::new(),
            reconnect_checkpoint_skip_reported: AtomicBool::new(false),
            journal_retention: Default::default(),
            diagnostic_reporter: OnceLock::new(),
            pending_diagnostics: Mutex::new(Vec::new()),
            #[cfg(test)]
            journal_segment_prepare_hook: Mutex::new(None),
            #[cfg(test)]
            screen_created_hook: Mutex::new(None),
            terminal_exit_waiters: TerminalExitWaiters::default(),
            #[cfg(test)]
            terminal_exit_state_queries: AtomicU64::new(0),
            resource_creation_handoff: Mutex::new(()),
            initial_bootstrap: Mutex::new(()),
            resource_creation_execution: Mutex::new(()),
            resource_creation_active: AtomicBool::new(false),
            terminal_adoptions: Mutex::new(HashSet::new()),
            pending_terminals: Mutex::new(HashMap::new()),
            terminal_ends: Mutex::new(HashMap::new()),
            terminal_loss_causes: Mutex::new(loss_causes::LossCauses::default()),
            terminal_exit_detaches: Arc::new(TerminalExitDetachTracker::default()),
            terminal_adoption_insert_failures: AtomicU64::new(
                std::env::var("CMUX_TUI_TEST_ADOPTION_INSERT_FAILURES")
                    .ok()
                    .and_then(|value| value.parse().ok())
                    .unwrap_or(0),
            ),
            template_completion_failures: AtomicU64::new(
                std::env::var("CMUX_TUI_TEST_TEMPLATE_COMPLETION_FAILURES")
                    .ok()
                    .and_then(|value| value.parse().ok())
                    .unwrap_or(0),
            ),
            server_lifecycle_ready: AtomicBool::new(false),
            shutting_down: AtomicBool::new(false),
            session_shutdown,
            exit_settles: Arc::default(),
            terminal_respawns: terminal_respawn::TerminalRespawns::from_env(),
            daemon_shutdown_waker: Mutex::new(None),
            control_clients: crate::server::ClientRegistry::new(),
            activity: Default::default(),
            idle_close: Mutex::new(idle_close::IdleCloseTracker::default()),
            idle_close_waker: Mutex::new(None),
            terminal_host_closes: Arc::new(host_close::TerminalHostCloses::default()),
            terminal_reap_grace_ms: AtomicU64::new(
                u64::try_from(DEFAULT_TERMINAL_REAP_GRACE.as_millis()).unwrap_or(u64::MAX),
            ),
            terminal_reaper_events: Mutex::new(None),
            launch_snapshot_path: Mutex::new(None),
            terminal_work: terminal_work::TerminalWorkPool::default(),
            #[cfg(unix)]
            prelaunched_terminals: Mutex::new(HashMap::new()),
            #[cfg(unix)]
            image_pastes: crate::image_paste::ImagePasteStore::default(),
            surface_operation_admission: Arc::new(
                crate::server::ServerSurfaceOperationAdmission::default(),
            ),
            pairing: PairingBroker::new(),
            #[cfg(test)]
            test_surface_runtime,
            session,
        });
        mux.exit_settles.bind(Arc::downgrade(&mux));
        let weak_mux = Arc::downgrade(&mux);
        mux.journal_plugin.set_exit_handler(Some(Arc::new(move |plugin_id, generation| {
            let Some(mux) = weak_mux.upgrade() else { return };
            // Do not drop a late exit callback here. The reducer uses the
            // child generation to fence a replacement process.
            mux.record_journal_plugin_exit(plugin_id, generation);
        })));
        crate::journal_ingress::start(&mux, journal_ingress_receiver)?;
        mux.materialize_interrupted_resource_workspaces()?;
        mux.materialize_restored_browsers(&contents)?;
        #[cfg(unix)]
        mux.adopt_terminal_hosts()?;
        {
            let mut state = mux.state.lock().unwrap();
            state.rebuild_resource_indexes();
            for content in &contents {
                if let Some(surface) = state.surfaces.get(&content.slot) {
                    surface.set_name(content.name.clone());
                }
            }
        }
        // The roster reducer and the public projection are durable in
        // separate transactions. A crash can therefore leave a plugin row in
        // the roster while dropping the projection side effect. Reconcile
        // after restored surfaces exist, and repeat at the end of asynchronous
        // terminal adoption for hosts that were not available yet.
        mux.reconcile_agent_roster_projections();
        if let Some(diagnostic) = agent_roster_diagnostic {
            mux.report_internal_diagnostic(diagnostic);
        }
        let recovery_deadline = Instant::now() + Duration::from_secs(15);
        while mux.reconcile_interrupted_resource_creations()? {
            if Instant::now() >= recovery_deadline {
                mux.shutdown();
                anyhow::bail!("interrupted resource creation did not settle during startup");
            }
            std::thread::sleep(Duration::from_millis(25));
        }
        mux.close_ephemeral_workspaces()?;
        mux.retry_pending_agent_hooks()?;
        crate::journal_hooks::start(&mux)?;
        Ok(mux)
    }

    pub fn lock_initial_bootstrap(&self) -> MutexGuard<'_, ()> {
        self.initial_bootstrap.lock().unwrap()
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

    #[cfg(unix)]
    fn restored_terminal_binding(
        &self,
        terminal_id: &str,
    ) -> anyhow::Result<Option<RestoredTerminalBinding>> {
        let registry = self.workspace_registry.lock().unwrap();
        let Some(public_id) = registry.terminal_resource_id(terminal_id)? else {
            return Ok(None);
        };
        drop(registry);
        let state = self.state.lock().unwrap();
        let content_id = ContentPublicId::Terminal(public_id.clone());
        let placements = state
            .placements_of_content(&content_id)
            .iter()
            .map(|slot| {
                let tab_id =
                    state.resource_indexes.tab_ids.get(slot).cloned().with_context(|| {
                        format!("restored terminal placement {slot} has no tab identity")
                    })?;
                Ok((*slot, TabResourceIdentity::new(tab_id, content_id.clone())))
            })
            .collect::<anyhow::Result<Vec<_>>>()?;
        Ok(Some(RestoredTerminalBinding { public_id, placements }))
    }

    #[cfg(unix)]
    fn adopt_restored_terminal(
        self: &Arc<Self>,
        binding: Option<RestoredTerminalBinding>,
        options: &SurfaceOptions,
        record: &crate::terminal_host_runtime::TerminalHostRecord,
        record_path: &Path,
    ) -> anyhow::Result<Arc<Surface>> {
        let id = binding
            .as_ref()
            .and_then(|binding| binding.placements.first().map(|(slot, _)| *slot))
            .unwrap_or_else(|| self.next_id());
        match binding {
            Some(binding) if !binding.placements.is_empty() => {
                let (_, identity) = binding.placements.first().expect("checked placement");
                Surface::adopt_hosted_with_resource_identity(
                    id,
                    options.clone(),
                    Arc::downgrade(self),
                    record.clone(),
                    record_path.to_path_buf(),
                    identity.clone(),
                )
            }
            Some(binding) => Surface::adopt_hosted_with_terminal_public_id(
                id,
                options.clone(),
                Arc::downgrade(self),
                record.clone(),
                record_path.to_path_buf(),
                binding.public_id,
            ),
            None => Surface::adopt_hosted(
                id,
                options.clone(),
                Arc::downgrade(self),
                record.clone(),
                record_path.to_path_buf(),
            ),
        }
    }

    #[cfg(unix)]
    fn adopt_terminal_hosts(self: &Arc<Self>) -> anyhow::Result<()> {
        let options = self.surface_options.lock().unwrap().clone();
        let exit_records = match options.terminal_host_root.as_deref() {
            Some(root) => crate::terminal_host_runtime::load_terminal_host_exit_records(root)?,
            None => Vec::new(),
        };
        if let Some(root) = options.terminal_host_root.as_deref() {
            crate::terminal_host_runtime::sweep_released_pty_locks(root);
        }
        let records = match options.terminal_host_root.as_deref() {
            Some(root) => crate::terminal_host_runtime::load_terminal_host_records(root)?,
            None => Vec::new(),
        };
        let mut handled_terminals = HashSet::new();
        // At most one warm snapshot host becomes the first terminal of a
        // fresh registry (SurfaceOptions::adopt_template_terminal).
        let mut template_claimed = false;
        let mut recovery_workspace = None;
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
            // The host's durable sidecar records the child's end.
            self.persist_terminal_exit(
                &record.terminal_id,
                Some(&record.incarnation),
                &TerminalEnd::ProcessEnded(record.exit.clone()),
            )?;
            self.detach_exited_terminal_topology(&record.terminal_id)?;
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
            if terminal.is_none()
                && !template_claimed
                && options.adopt_template_terminal
                && !record.workspace_key.is_empty()
                && self.state.lock().unwrap().workspaces.is_empty()
                && terminal_host_record_liveness(&record_path, &record)
                    == TerminalHostLiveness::Live
            {
                terminal = Some(self.claim_template_terminal(&options, &record)?);
                template_claimed = true;
            }
            if terminal.is_none() {
                // One-release migration path for hosts launched before SQLite
                // became placement authority. Never trust the JSON hint when
                // its workspace no longer exists.
                let workspace_exists = !record.workspace_key.is_empty()
                    && self.state.lock().unwrap().workspace_by_key(&record.workspace_key).is_some();
                if workspace_exists {
                    let imported = RegistryTerminal {
                        terminal_id: terminal_id.clone(),
                        workspace_key: record.workspace_key.clone(),
                        incarnation: None,
                        lifecycle: TerminalLifecycle::Launching,
                        launch_spec: serde_json::json!({"legacy_import":true}),
                        exit: None,
                        on_exit: TerminalOnExit::Close,
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
                } else if orphan_hosts::recoverable(&options, &record_path, &record) {
                    match self.recover_orphan_terminal(&record, &mut recovery_workspace) {
                        Ok(recovered) => terminal = Some(recovered),
                        Err(error) => {
                            // The host and its record stay for a later start.
                            eprintln!("cmux-tui: terminal {terminal_id} not recovered: {error:#}");
                            continue;
                        }
                    }
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
                self.detach_exited_terminal_topology(&terminal.terminal_id)?;
                handled_terminals.insert(terminal_id.clone());
                if !cleanup_terminal_host_record(&record, &record_path) {
                    self.schedule_terminal_adoption(options.clone(), record, record_path);
                }
                continue;
            }
            if terminal.incarnation.as_deref().is_some_and(|value| value != record.incarnation) {
                self.mark_terminal_ended(
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
                        self.detach_exited_terminal_topology(&terminal_id)?;
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
                // Commit the durable exit before deleting the record. The
                // record is the only proof that this host ever existed, so a
                // failed commit must leave the next startup able to retry
                // instead of facing a lifecycle row with no evidence.
                self.mark_terminal_ended(
                    &terminal_id,
                    "terminal-host-proven-dead",
                    "host-process-ended-before-adoption",
                    &options,
                )?;
                let _ = crate::terminal_host_runtime::remove_stale_terminal_host_record(
                    &record_path,
                    &record,
                );
                handled_terminals.insert(terminal_id.clone());
                continue;
            }
            let restored_binding = self.restored_terminal_binding(&terminal_id)?;
            // Bound startup head-of-line blocking per host. One handshake is
            // enough for healthy hosts; live or indeterminate failures
            // continue on the asynchronous adoption loop instead of retrying
            // serially ahead of every later terminal.
            let adopted = self
                .adopt_restored_terminal(restored_binding, &options, &record, &record_path)
                .ok();
            let surface = match adopted {
                Some(surface) => surface,
                None => {
                    if terminal_host_record_liveness(&record_path, &record)
                        == TerminalHostLiveness::Dead
                    {
                        self.mark_terminal_ended(
                            &terminal_id,
                            "terminal-host-proven-dead",
                            "host-process-ended-before-adoption",
                            &options,
                        )?;
                        let _ = crate::terminal_host_runtime::remove_stale_terminal_host_record(
                            &record_path,
                            &record,
                        );
                        handled_terminals.insert(terminal_id.clone());
                    } else {
                        // Socket loss and descriptor pressure are not process
                        // death proof. Keep the capability and retry the same
                        // host rather than spawning a replacement shell. The
                        // tab has no surface meanwhile; it is adopting, not
                        // dead (R41).
                        handled_terminals.insert(terminal_id.clone());
                        self.set_pending_terminal(&terminal_id, PendingTerminal::Adopting);
                        self.schedule_terminal_adoption(options.clone(), record, record_path);
                    }
                    continue;
                }
            };
            if self
                .finish_terminal_adoption(&terminal_id, &record.incarnation, surface.clone())
                .is_err()
            {
                let host_is_dead = surface.is_dead()
                    || terminal_host_record_liveness(&record_path, &record)
                        == TerminalHostLiveness::Dead;
                surface.disconnect_for_daemon_shutdown();
                handled_terminals.insert(terminal_id.clone());
                if host_is_dead {
                    self.mark_terminal_ended(
                        &terminal_id,
                        "terminal-adoption-failed",
                        "host-exited-during-adoption",
                        &options,
                    )?;
                    let _ = crate::terminal_host_runtime::remove_stale_terminal_host_record(
                        &record_path,
                        &record,
                    );
                } else {
                    self.set_pending_terminal(&terminal_id, PendingTerminal::Adopting);
                    self.schedule_terminal_adoption(options.clone(), record, record_path);
                }
                continue;
            }
            self.ensure_template_adoption_completed(&terminal_id);
            handled_terminals.insert(terminal_id);
            self.reap_if_dead(&surface);
        }

        self.mark_unadoptable_terminal_hosts(&options, &mut handled_terminals)?;

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
                self.detach_exited_terminal_topology(&terminal.terminal_id)?;
                self.record_terminal_end(&terminal.terminal_id);
                continue;
            }
            self.mark_terminal_ended(
                &terminal.terminal_id,
                "terminal-record-missing",
                "missing-host-record",
                &options,
            )?;
        }
        Ok(())
    }

    /// Complete an adopted template terminal (complete_template_adoption),
    /// retrying in the background until it succeeds or the daemon shuts down.
    /// Adoption itself has already committed, so a failure here must neither
    /// abort startup nor leave the terminal without its public placement and
    /// binding.
    #[cfg(unix)]
    fn ensure_template_adoption_completed(self: &Arc<Self>, terminal_id: &str) {
        let Err(error) = self.complete_template_adoption(terminal_id) else {
            return;
        };
        eprintln!("cmux-tui: template terminal {terminal_id} not published yet: {error:#}");
        let mux = Arc::clone(self);
        let terminal_id = terminal_id.to_string();
        let spawned = std::thread::Builder::new()
            .name(format!("template-complete-{terminal_id}"))
            .spawn(move || {
                let mut delay = Duration::from_millis(100);
                loop {
                    std::thread::sleep(delay);
                    if mux.shutting_down.load(Ordering::Acquire) {
                        break;
                    }
                    match mux.complete_template_adoption(&terminal_id) {
                        Ok(()) => break,
                        Err(error) => {
                            eprintln!(
                                "cmux-tui: template terminal {terminal_id} not published yet: \
                                 {error:#}"
                            );
                            delay = (delay * 2).min(Duration::from_secs(5));
                        }
                    }
                }
            });
        if let Err(error) = spawned {
            eprintln!("cmux-tui: could not schedule template completion: {error}");
        }
    }

    /// Finish a template terminal once its host is adopted, on the startup
    /// pass or the asynchronous retry: commit its new placement to the public
    /// topology, then tell the template shell its new identity. The binding is
    /// written only after the commit, so the first `terminal.list` after it
    /// appears includes the terminal it names.
    #[cfg(unix)]
    fn complete_template_adoption(&self, terminal_id: &str) -> anyhow::Result<()> {
        let terminal = self.workspace_registry.lock().unwrap().terminal_record(terminal_id)?;
        // A recovered terminal (cx-0tgl LC) is placed the same way; only a
        // Cloud template gets the identity binding below.
        let Some(terminal) = terminal.filter(orphan_hosts::placed_on_adoption) else {
            return Ok(());
        };
        anyhow::ensure!(
            !self.consume_template_completion_failure(),
            "injected template completion failure"
        );
        self.commit_ordinary_full_resource_projection(
            &Actor::Daemon,
            "terminal.adopt-template",
            serde_json::json!({}),
        )?;
        let bound_file = self.surface_options.lock().unwrap().template_bound_file.clone();
        if let Some(path) = bound_file.filter(|_| is_template_terminal(&terminal)) {
            self.publish_template_binding(terminal_id, &path)?;
        }
        Ok(())
    }

    /// Claim a Cloud snapshot's warm terminal host as the first terminal of
    /// this fresh registry (SurfaceOptions::adopt_template_terminal). The
    /// host's workspace is recreated under its recorded key and named from
    /// the options; the durable row is marked as a template terminal so
    /// finish_terminal_adoption gives it a new placement with fresh public
    /// ids. The ordinary adoption handshake follows.
    #[cfg(unix)]
    fn claim_template_terminal(
        &self,
        options: &SurfaceOptions,
        record: &crate::terminal_host_runtime::TerminalHostRecord,
    ) -> anyhow::Result<RegistryTerminal> {
        self.create_empty_workspace(
            options.template_workspace_name.clone(),
            Some(record.workspace_key.clone()),
            None,
        )?;
        let claimed = RegistryTerminal {
            terminal_id: record.terminal_id.clone(),
            workspace_key: record.workspace_key.clone(),
            incarnation: None,
            lifecycle: TerminalLifecycle::Launching,
            launch_spec: template_terminal_launch_spec(),
            exit: None,
            on_exit: TerminalOnExit::Close,
        };
        let mut registry = self.workspace_registry.lock().unwrap();
        let revision = commit_terminal_transition(
            &mut registry,
            "terminal-template-claimed",
            "claim-template-terminal",
            &claimed,
        )?;
        self.emit_terminal_registry_changed(&registry, revision);
        Ok(claimed)
    }

    /// Tell the warm template shell its new identity. The shell was spawned
    /// by the snapshot builder's daemon, so its CMUX_TUI_SESSION_ID and
    /// CMUX_TUI_TERMINAL_ID name the builder's session and terminal. Its
    /// first prompt waits for this file and re-exports both before any user
    /// command (or agent hook) runs. Written only after the adoption above
    /// committed, and atomically, so its presence means the clone is bound.
    #[cfg(unix)]
    fn publish_template_binding(&self, terminal_id: &str, path: &Path) -> anyhow::Result<()> {
        let session_id = self.session_public_id();
        let terminal_public_id = {
            let state = self.state.lock().unwrap();
            state
                .surfaces
                .iter()
                .find(|(_, surface)| {
                    surface
                        .terminal_host_identity()
                        .is_some_and(|identity| identity.terminal_id == terminal_id)
                })
                .and_then(|(surface_id, _)| state.resource_indexes.content_ids.get(surface_id))
                .and_then(|content| match content {
                    ContentPublicId::Terminal(id) => Some(id.clone()),
                    _ => None,
                })
        };
        // Adoption may have fallen back to the asynchronous retry loop; the
        // shell's bounded wait then clears the builder's values instead.
        let Some(terminal_public_id) = terminal_public_id else { return Ok(()) };
        let contents = format!(
            "CMUX_TUI_SESSION_ID={}\nCMUX_TUI_TERMINAL_ID={}\n",
            session_id.as_str(),
            terminal_public_id.as_str()
        );
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let temporary = path.with_extension("tmp");
        std::fs::write(&temporary, contents)?;
        std::fs::rename(&temporary, path)?;
        Ok(())
    }

    /// Startup and adoption-loop reconciliation of a host that is gone or no
    /// longer matches its row. Commits the exit receipt (the host's sidecar
    /// when it left one) and detaches the terminal's tabs only when that
    /// receipt proves a process end; a host loss leaves them dead.
    #[cfg(unix)]
    fn mark_terminal_ended(
        self: &Arc<Self>,
        terminal_id: &str,
        _operation: &str,
        reason: &str,
        options: &SurfaceOptions,
    ) -> anyhow::Result<()> {
        self.clear_pending_terminal(terminal_id);
        if self.terminal_is_respawning(terminal_id) {
            return Ok(());
        }
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
            // A sidecar is the host's record of the child's end. Without one
            // the host died with an unknown outcome: the terminal is exited
            // but its tabs stay, dead (invariant 3).
            let observed = sidecar
                .as_ref()
                .map(|(_, record)| TerminalEnd::ProcessEnded(record.exit.clone()))
                .unwrap_or_else(|| TerminalEnd::host_lost(reason));
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
        self.detach_exited_terminal_topology(terminal_id)?;
        self.record_terminal_end(terminal_id);
        Ok(())
    }

    #[cfg(unix)]
    fn finish_terminal_adoption(
        &self,
        terminal_id: &str,
        incarnation: &str,
        surface: Arc<Surface>,
    ) -> anyhow::Result<()> {
        let _pending_host_release = PendingTerminalHostRelease(surface.clone());
        if surface.is_dead() {
            let end = surface
                .terminal_end()
                .unwrap_or_else(|| TerminalEnd::host_lost("host-exited-during-adoption"));
            self.persist_terminal_exit(terminal_id, Some(incarnation), &end)?;
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
        let restored_public_id = surface.terminal_public_id().cloned();
        let has_restored_placements = restored_public_id.as_ref().is_some_and(|public_id| {
            !state.placements_of_content(&ContentPublicId::Terminal(public_id.clone())).is_empty()
        });
        if orphan_hosts::placed_on_adoption(&terminal) && !has_restored_placements {
            // Cloud snapshot template, first adoption: its builder's placement
            // was wiped with the builder's registry, so it gets a new one here.
            // The template marker stays on the durable row, so a later daemon
            // start (crash, in-place upgrade) finds the placement this one
            // committed and restores it below instead of placing it twice.
            self.place_adopted_terminal_in_new_screen(
                &mut state,
                &terminal.workspace_key,
                surface,
            )?;
        } else if has_restored_placements || surface.resource_identity().is_none() {
            anyhow::ensure!(
                !self.consume_terminal_adoption_insert_failure(),
                "injected terminal adoption topology failure"
            );
            insert_restored_terminal_runtime_checked(&mut state, surface)?;
        } else {
            // One-release import path for a host that predates public content
            // identities. Give it a real initial placement so the normal
            // resource projection can persist its generated identities.
            self.place_adopted_terminal_in_new_screen(
                &mut state,
                &terminal.workspace_key,
                surface,
            )?;
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
        drop(state);
        self.emit_terminal_registry_changed(&registry, revision);
        drop(registry);
        // Clients read tab liveness from the tree: an adopting tab is live now.
        if self.clear_pending_terminal(terminal_id) {
            self.emit(MuxEvent::TreeChanged);
        }
        // Adoption makes the terminal's resource surface available. Retry
        // only hooks scoped to this terminal, not the entire pending table.
        if let Ok(terminal_id) = TerminalPublicId::parse(terminal_id) {
            let _ = self.retry_pending_agent_hooks_for_terminal(&terminal_id);
            self.reconcile_agent_roster_projections_for_terminal(&terminal_id);
        }
        Ok(())
    }

    /// Give an adopted terminal host a new screen and pane in the workspace
    /// with `workspace_key`, without stealing focus. The resource projection
    /// then generates and persists its public ids.
    #[cfg(unix)]
    fn place_adopted_terminal_in_new_screen(
        &self,
        state: &mut State,
        workspace_key: &str,
        surface: Arc<Surface>,
    ) -> anyhow::Result<()> {
        let workspace_index = state
            .workspaces
            .iter()
            .position(|workspace| workspace.key == workspace_key)
            .ok_or_else(|| anyhow::anyhow!("terminal workspace disappeared during adoption"))?;
        let (pane_id, pane) = self.make_pane(surface.id)?;
        let screen_id = self.next_id();
        let screen_public_id = ScreenPublicId::random()?;
        anyhow::ensure!(
            !self.consume_terminal_adoption_insert_failure(),
            "injected terminal adoption topology failure"
        );
        insert_surface_checked(state, surface)?;
        {
            let workspace = &mut state.workspaces[workspace_index];
            workspace.screens.push(Screen {
                id: screen_id,
                public_id: screen_public_id,
                name: None,
                root: Node::Leaf(pane_id),
                active_pane: pane_id,
                zoomed_pane: None,
                creation_order_auto_layout: Some(vec![pane_id]),
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
        Ok(())
    }

    #[cfg(unix)]
    fn consume_template_completion_failure(&self) -> bool {
        self.template_completion_failures
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |remaining| remaining.checked_sub(1))
            .is_ok()
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
        let terminal_id = record.terminal_id.clone();
        if !self.terminal_adoptions.lock().unwrap().insert(terminal_id.clone()) {
            return;
        }
        let cleanup_id = terminal_id.clone();
        let mux = self.clone();
        let spawn_result = std::thread::Builder::new()
            .name(format!("terminal-adopt-{terminal_id}"))
            .spawn(move || {
                let mut delay = Duration::from_millis(100);
                loop {
                    if mux.shutting_down.load(Ordering::Acquire) {
                        break;
                    }
                    std::thread::sleep(delay);
                    if mux.shutting_down.load(Ordering::Acquire) {
                        break;
                    }
                    // A failed read proves nothing about the host: retry.
                    let Ok(terminal) =
                        mux.workspace_registry.lock().unwrap().terminal_record(&terminal_id)
                    else {
                        delay = (delay * 2).min(Duration::from_secs(5));
                        continue;
                    };
                    let Some(terminal) = terminal else {
                        if cleanup_terminal_host_record(&record, &record_path) {
                            break;
                        }
                        delay = (delay * 2).min(Duration::from_secs(5));
                        continue;
                    };
                    if matches!(
                        terminal.lifecycle,
                        TerminalLifecycle::Exited | TerminalLifecycle::Tombstoned
                    ) {
                        if terminal.lifecycle == TerminalLifecycle::Exited
                            && let Err(error) = mux.detach_exited_terminal_topology(&terminal_id)
                        {
                            eprintln!(
                                "cmux-tui: could not detach exited terminal \
                                 {terminal_id}: {error:#}"
                            );
                            delay = (delay * 2).min(Duration::from_secs(5));
                            continue;
                        }
                        if cleanup_terminal_host_record(&record, &record_path) {
                            break;
                        }
                        delay = (delay * 2).min(Duration::from_secs(5));
                        continue;
                    }
                    if terminal
                        .incarnation
                        .as_deref()
                        .is_some_and(|incarnation| incarnation != record.incarnation)
                    {
                        if let Err(error) = mux.mark_terminal_ended(
                            &terminal_id,
                            "terminal-incarnation-mismatch",
                            "host-incarnation-mismatch",
                            &options,
                        ) {
                            eprintln!(
                                "cmux-tui: could not reconcile exited terminal \
                                 {terminal_id}: {error:#}"
                            );
                            delay = (delay * 2).min(Duration::from_secs(5));
                            continue;
                        }
                        if cleanup_terminal_host_record(&record, &record_path) {
                            break;
                        }
                        delay = (delay * 2).min(Duration::from_secs(5));
                        continue;
                    }
                    if terminal.lifecycle == TerminalLifecycle::Running {
                        let already_live = mux
                            .resolve_terminal(&terminal_id)
                            .ok()
                            .flatten()
                            .is_some_and(|resolution| resolution.surface.is_some());
                        if already_live {
                            break;
                        }
                        if mux
                            .transition_terminal_lifecycle(
                                "terminal-adopting",
                                "retry-terminal-adoption",
                                &terminal_id,
                                TerminalLifecycle::Adopting,
                                Some(&record.incarnation),
                            )
                            .is_err()
                        {
                            break;
                        }
                    }
                    if terminal_host_record_liveness(&record_path, &record)
                        == TerminalHostLiveness::Dead
                    {
                        if let Err(error) = mux.mark_terminal_ended(
                            &terminal_id,
                            "terminal-host-proven-dead",
                            "host-process-ended-before-adoption",
                            &options,
                        ) {
                            eprintln!(
                                "cmux-tui: could not reconcile exited terminal \
                                 {terminal_id}: {error:#}"
                            );
                            delay = (delay * 2).min(Duration::from_secs(5));
                            continue;
                        }
                        let _ = crate::terminal_host_runtime::remove_stale_terminal_host_record(
                            &record_path,
                            &record,
                        );
                        break;
                    }
                    let restored_binding = match mux.restored_terminal_binding(&terminal_id) {
                        Ok(binding) => binding,
                        Err(_) => {
                            delay = (delay * 2).min(Duration::from_secs(5));
                            continue;
                        }
                    };
                    let adopted = mux.adopt_restored_terminal(
                        restored_binding,
                        &options,
                        &record,
                        &record_path,
                    );
                    if let Ok(surface) = adopted {
                        if mux
                            .finish_terminal_adoption(
                                &terminal_id,
                                &record.incarnation,
                                surface.clone(),
                            )
                            .is_ok()
                        {
                            mux.ensure_template_adoption_completed(&terminal_id);
                            mux.reap_if_dead(&surface);
                            break;
                        }
                        let host_is_dead = surface.is_dead()
                            || terminal_host_record_liveness(&record_path, &record)
                                == TerminalHostLiveness::Dead;
                        surface.disconnect_for_daemon_shutdown();
                        if host_is_dead {
                            if let Err(error) = mux.mark_terminal_ended(
                                &terminal_id,
                                "terminal-adoption-failed",
                                "host-exited-during-adoption",
                                &options,
                            ) {
                                eprintln!(
                                    "cmux-tui: could not reconcile exited terminal \
                                     {terminal_id}: {error:#}"
                                );
                                delay = (delay * 2).min(Duration::from_secs(5));
                                continue;
                            }
                            let _ = crate::terminal_host_runtime::remove_stale_terminal_host_record(
                                &record_path,
                                &record,
                            );
                            break;
                        }
                        delay = (delay * 2).min(Duration::from_secs(5));
                        continue;
                    }
                    if terminal_host_record_liveness(&record_path, &record)
                        == TerminalHostLiveness::Dead
                    {
                        if let Err(error) = mux.mark_terminal_ended(
                            &terminal_id,
                            "terminal-host-proven-dead",
                            "host-process-ended-before-adoption",
                            &options,
                        ) {
                            eprintln!(
                                "cmux-tui: could not reconcile exited terminal \
                                 {terminal_id}: {error:#}"
                            );
                            delay = (delay * 2).min(Duration::from_secs(5));
                            continue;
                        }
                        let _ = crate::terminal_host_runtime::remove_stale_terminal_host_record(
                            &record_path,
                            &record,
                        );
                        break;
                    }
                    delay = (delay * 2).min(Duration::from_secs(5));
                }
                mux.clear_adopting_marker(&terminal_id);
                mux.terminal_adoptions.lock().unwrap().remove(&terminal_id);
            });
        if spawn_result.is_err() {
            self.terminal_adoptions.lock().unwrap().remove(&cleanup_id);
            self.clear_pending_terminal(&cleanup_id);
        }
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
        self.provider_managed.store(true, Ordering::Release);
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

    pub(crate) fn registry_projection(&self, state: &State) -> Vec<RegistryWorkspace> {
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

    pub(crate) fn ordinary_resource_selectors() -> crate::ResourceSelectors {
        crate::ResourceSelectors {
            machine: Some("current".into()),
            session: Some("current".into()),
            ..crate::ResourceSelectors::default()
        }
    }

    pub(crate) fn ordinary_workspace_selectors(
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

    fn nullable_name_fields(name: String) -> Map<String, Value> {
        Map::from_iter([(
            "name".into(),
            if name.is_empty() { Value::Null } else { Value::String(name) },
        )])
    }

    fn insert_terminal_env(fields: &mut Map<String, Value>, env: Vec<(String, String)>) {
        if !env.is_empty() {
            fields.insert(
                "env".into(),
                Value::Object(
                    env.into_iter().map(|(key, value)| (key, Value::String(value))).collect(),
                ),
            );
        }
    }

    fn insert_spawn_options(fields: &mut Map<String, Value>, spawn: TerminalSpawnOptions) {
        Self::insert_optional_string(fields, "cwd", spawn.cwd);
        Self::insert_terminal_env(fields, spawn.env);
        Self::insert_optional_string(fields, RESERVED_TERMINAL_ID_FIELD, spawn.terminal_id);
        if let Some(argv) = spawn.argv {
            fields
                .insert("argv".into(), Value::Array(argv.into_iter().map(Value::String).collect()));
        }
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

    pub(crate) fn ordinary_created_surface(
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

    /// Report an agent state for a selected terminal resource and reconcile
    /// any durable hook projections waiting for that terminal.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn commit_resource_mutation_plan(
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
        // Prepare and stage run before the durable commit, so subscribers
        // see a tab's new session path only once that commit succeeds.
        let (prepared, session_paths) = crate::event_bus::defer_session_paths(|| {
            let mut plan = prepare(&mut state, &registry)?;
            let tabs = resource_tab_deltas::TabMembership::capture(&state, &plan.patch);
            let before = plan.stage_checked(&mut state, operation)?;
            anyhow::Ok((plan, before, tabs))
        });
        let (mut plan, before, tabs) = prepared?;
        let committed = persist_public_topology_result(operation, &mut plan.result, &plan.deltas)
            .and_then(|()| {
                #[cfg(test)]
                {
                    *self.resource_mutation_metrics.lock().unwrap() = Some(plan.metrics);
                }
                registry.commit_resource_patch_with_workspace_ledger(
                    mutation,
                    operation,
                    fingerprint,
                    expected_generation,
                    expected_revision,
                    &plan.patch,
                    &plan.result,
                    &plan.deltas,
                    plan.workspace_ledger.as_ref(),
                    plan.state_write.take(),
                )
            });
        let (commit, workspace_revision) = match committed {
            Ok(committed) => committed,
            Err(error) => {
                if let Some(before) = before {
                    *state = before;
                }
                return Err(error);
            }
        };
        if commit.replayed {
            if let Some(before) = before {
                *state = before;
            }
        } else {
            self.subscribers.publish_deferred_session_paths(session_paths);
        }
        plan.apply(&mut state, &commit, workspace_revision);
        let tab_deltas = tabs.and_then(|tabs| tabs.deltas(self, &state, &commit));
        drop(state);
        drop(registry);
        if !commit.replayed {
            self.publish_resource_event();
            // A commit can create the resource row that a shell's first
            // directory report was waiting for.
            self.publish_pending_terminal_directories();
        }
        self.emit_resource_tab_deltas(tab_deltas);
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
                let durable = RegistryWorkspace {
                    id: workspace.id,
                    public_id: public_id.clone(),
                    key: key.clone(),
                    name,
                    group_key: self.session.clone(),
                };
                let mut desired = self.registry_projection(state);
                desired.push(durable.clone());
                Ok(ResourceMutationPlan::new(
                    ResourcePatch {
                        changes: vec![
                            ResourceChange::UpsertWorkspace {
                                workspace: durable,
                                position: index,
                                active_screen: None,
                            },
                            ResourceChange::SetWorkspaceOrder { workspace_ids: order },
                            ResourceChange::SetActiveWorkspace { workspace_id: Some(public_id) },
                        ],
                    },
                    result.clone(),
                    Value::Array(deltas),
                    move |state| {
                        state.push_workspace(workspace);
                        state.active_workspace = index;
                    },
                )
                .with_workspace_ledger(ResourceWorkspaceLedger {
                    event_kind: "workspace-added",
                    workspace_key: key,
                    workspaces: desired,
                    legacy_result: result,
                    presentation: None,
                })
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
                let mut desired = self.registry_projection(state);
                desired[index] = durable.clone();
                let workspace_key = durable.key.clone();
                Ok(ResourceMutationPlan::new(
                    ResourcePatch {
                        changes: vec![ResourceChange::UpsertWorkspace {
                            workspace: durable,
                            position: index,
                            active_screen,
                        }],
                    },
                    result.clone(),
                    deltas,
                    move |state| {
                        state.workspaces[index].name = name;
                    },
                )
                .with_workspace_ledger(ResourceWorkspaceLedger {
                    event_kind: "workspace-renamed",
                    workspace_key,
                    workspaces: desired,
                    legacy_result: result,
                    presentation: None,
                })
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
                let mut desired = self.registry_projection(state);
                desired[index] = durable.clone();
                let workspace_key = durable.key.clone();
                Ok(ResourceMutationPlan::new(
                    ResourcePatch {
                        changes: vec![ResourceChange::UpsertWorkspace {
                            workspace: durable,
                            position: index,
                            active_screen,
                        }],
                    },
                    result.clone(),
                    deltas,
                    move |state| {
                        state.workspaces[index].name = name;
                    },
                )
                .with_workspace_ledger(ResourceWorkspaceLedger {
                    event_kind: "workspace-renamed",
                    workspace_key,
                    workspaces: desired,
                    legacy_result: result,
                    presentation: None,
                })
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
                let projection = self.registry_projection(state);
                let desired = order
                    .iter()
                    .map(|workspace_id| {
                        projection
                            .iter()
                            .find(|workspace| &workspace.public_id == workspace_id)
                            .expect("workspace order was built from live workspaces")
                            .clone()
                    })
                    .collect::<Vec<_>>();
                let workspace_key = state.workspaces[old_index].key.clone();
                Ok(ResourceMutationPlan::new(
                    ResourcePatch { changes },
                    result.clone(),
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
                    },
                )
                .with_workspace_ledger(ResourceWorkspaceLedger {
                    event_kind: "workspace-moved",
                    workspace_key,
                    workspaces: desired,
                    legacy_result: result,
                    presentation: None,
                })
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
                let projection = self.registry_projection(state);
                let desired = order
                    .iter()
                    .map(|workspace_id| {
                        projection
                            .iter()
                            .find(|workspace| &workspace.public_id == workspace_id)
                            .expect("workspace order was built from live workspaces")
                            .clone()
                    })
                    .collect::<Vec<_>>();
                let workspace_key = state.workspaces[old_index].key.clone();
                Ok(ResourceMutationPlan::new(
                    ResourcePatch { changes },
                    result.clone(),
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
                    },
                )
                .with_workspace_ledger(ResourceWorkspaceLedger {
                    event_kind: "workspace-moved",
                    workspace_key,
                    workspaces: desired,
                    legacy_result: result,
                    presentation: None,
                })
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

    /// Commit an agent report and its resource projection under the sequence
    /// fence used to preserve hook ordering across retries and restarts.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn prepare_resource_effect(
        &self,
        mutation: &WorkspaceMutation,
        operation: &str,
        fingerprint: &Value,
        intent: &Value,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
    ) -> anyhow::Result<ResourceEffectPreparation> {
        self.workspace_registry.lock().unwrap().prepare_resource_effect_for(
            mutation,
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
            self.publish_journal_event();
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
            projection.restates_all,
        )?;
        state.resource_revision = commit.revision;
        drop(state);
        drop(registry);
        self.publish_resource_event();
        self.publish_pending_terminal_directories();
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
            |registry, state| self.created_view_projection_locked(registry, state, result),
        )
    }

    /// Reconcile an already-committed local mutation into one public topology
    /// revision. This is reserved for legacy/internal paths whose durable
    /// side effect predates the resource coordinator.
    fn commit_ordinary_full_resource_projection(
        &self,
        actor: &Actor,
        operation: &'static str,
        result: Value,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let mutation = WorkspaceMutation::local("cmux-tui", actor.clone());
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
        self.state.lock().unwrap().terminal_catalog.get(terminal_id).map(|surface| surface.id)
    }

    pub(crate) fn resource_selectors_for_pane(
        &self,
        pane: Option<PaneId>,
    ) -> anyhow::Result<crate::ResourceSelectors> {
        let state = self.state.lock().unwrap();
        let pane = pane.or_else(|| state.active_pane()).context("session has no active pane")?;
        let (workspace_index, screen_index) =
            state.screen_of(pane).context("pane has no containing screen")?;
        let workspace = &state.workspaces[workspace_index];
        let screen = &workspace.screens[screen_index];
        let pane =
            state.resource_indexes.pane_ids.get(&pane).context("pane has no public identity")?;
        Ok(crate::ResourceSelectors {
            machine: Some("current".to_string()),
            session: Some("current".to_string()),
            workspace: Some(workspace.public_id.to_string()),
            screen: Some(screen.public_id.to_string()),
            pane: Some(pane.to_string()),
            ..crate::ResourceSelectors::default()
        })
    }

    pub(crate) fn resource_selectors_for_workspace(
        &self,
        workspace: Option<WorkspaceId>,
    ) -> anyhow::Result<crate::ResourceSelectors> {
        let state = self.state.lock().unwrap();
        let workspace = match workspace {
            Some(workspace) => state
                .workspaces
                .iter()
                .find(|candidate| candidate.id == workspace)
                .context("workspace does not exist")?,
            None => state
                .workspaces
                .get(state.active_workspace)
                .context("session has no active workspace")?,
        };
        Ok(crate::ResourceSelectors {
            machine: Some("current".to_string()),
            session: Some("current".to_string()),
            workspace: Some(workspace.public_id.to_string()),
            ..crate::ResourceSelectors::default()
        })
    }

    pub(crate) fn resource_surface_for_created_path(
        &self,
        result: &Value,
    ) -> anyhow::Result<SurfaceId> {
        let tab = TabPublicId::parse(
            result["tab_id"]
                .as_str()
                .context("creation receipt omitted its tab identity")?
                .to_string(),
        )
        .map_err(anyhow::Error::new)?;
        self.state
            .lock()
            .unwrap()
            .resource_indexes
            .tabs
            .get(&tab)
            .copied()
            .context("created tab no longer has a live view")
    }

    pub(crate) fn has_durable_terminal_receipt(
        &self,
        terminal_id: &TerminalPublicId,
    ) -> anyhow::Result<bool> {
        let registry = self.workspace_registry.lock().unwrap();
        let Some(host_id) = registry.terminal_host_id(terminal_id)? else {
            return Ok(false);
        };
        Ok(registry
            .terminal_record(&host_id)?
            .is_some_and(|terminal| terminal.lifecycle != TerminalLifecycle::Tombstoned))
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
                return Err(ResourceError::terminal_closed(terminal_id).into());
            }
        };
        Ok(serde_json::json!({
            "state": "pending",
            "terminal_id": terminal_id,
            "lifecycle": lifecycle,
            "revision": revision.to_string(),
        }))
    }

    /// Bounded plain-text projection of one terminal's journaled output
    /// stream. It works while the process runs and after it exits; callers
    /// resolve exited terminals through the same durable receipt as
    /// `terminal.wait_exit`.
    ///
    /// Offsets are `terminal.output` stream byte offsets of the terminal's
    /// most recent journal generation. A cursor before the exit snapshot's
    /// coverage answers with the snapshot's screen projection (start_offset
    /// 0, next_offset at the coverage end); at or past it, the window is the
    /// retained records after the cursor, rendered through a fresh terminal,
    /// never splitting one record and never exceeding `max_bytes` beyond the
    /// window's first record.
    pub(crate) fn terminal_output_read(
        &self,
        terminal_id: &TerminalPublicId,
        after: Option<u64>,
        max_bytes: u64,
    ) -> anyhow::Result<Value> {
        // Fence asynchronous output ingress so the read observes everything
        // the terminal emitted before this request.
        self.flush_terminal_journal()?;
        let requested = after.unwrap_or(0);
        let surface = self
            .terminal_resource_surface(terminal_id)
            .filter(|surface| surface.kind() == SurfaceKind::Pty);
        let (stream, snapshot, spec_geometry) = {
            let registry = self.workspace_registry.lock().unwrap();
            let stream = registry.terminal_stream_latest(terminal_id.as_str())?;
            let snapshot = registry.terminal_exit_snapshot(terminal_id.as_str())?;
            let spec_geometry = registry
                .terminal_host_id(terminal_id)?
                .map(|host_id| registry.terminal_record(&host_id))
                .transpose()?
                .flatten()
                .and_then(|terminal| {
                    Some((
                        u16::try_from(terminal.launch_spec["cols"].as_u64()?).ok()?,
                        u16::try_from(terminal.launch_spec["rows"].as_u64()?).ok()?,
                    ))
                });
            (stream, snapshot, spec_geometry)
        };
        let generation = stream
            .as_ref()
            .map(|(generation, _)| generation.clone())
            .or_else(|| snapshot.as_ref().map(|snapshot| snapshot.generation.clone()));
        let Some(generation) = generation else {
            // Nothing was ever journaled: an empty, complete stream.
            return Ok(terminal_output_read_result(String::new(), requested, requested, true));
        };
        // Offsets are per journal generation. Reads serve the most recent
        // stream; the snapshot participates only when it belongs to it.
        let snapshot = snapshot.filter(|snapshot| snapshot.generation == generation);
        let stream_end = stream.map(|(_, next_offset)| next_offset).unwrap_or(0);
        if let Some(snapshot) = &snapshot
            && requested < snapshot.covered_through
        {
            // The requested bytes are covered by the exit snapshot; earlier
            // records may already be pruned, and rendering the bounded
            // snapshot keeps the read O(snapshot) instead of O(history).
            let text = render_terminal_output_plain(
                std::iter::once(snapshot.replay_bytes.as_slice()),
                snapshot.cols,
                snapshot.rows,
            )?;
            let complete = snapshot.covered_through >= stream_end;
            return Ok(terminal_output_read_result(text, 0, snapshot.covered_through, complete));
        }
        let window = self.workspace_registry.lock().unwrap().terminal_output_records_after(
            terminal_id.as_str(),
            &generation,
            requested,
            max_bytes,
        )?;
        let Some((first, last)) = window.chunks.first().zip(window.chunks.last()) else {
            // Everything journaled so far is at or before the cursor.
            return Ok(terminal_output_read_result(String::new(), requested, requested, true));
        };
        let (cols, rows) = surface
            .as_ref()
            .map(|surface| surface.size())
            .or_else(|| snapshot.as_ref().map(|snapshot| (snapshot.cols, snapshot.rows)))
            .or(spec_geometry)
            .unwrap_or((80, 24));
        let start_offset = first.stream_offset_start;
        let next_offset = last.stream_offset_end;
        let text = render_terminal_output_plain(
            window.chunks.iter().map(|chunk| chunk.bytes.as_ref()),
            cols,
            rows,
        )?;
        Ok(terminal_output_read_result(text, start_offset, next_offset, !window.truncated))
    }

    /// Best-effort capture of a terminal's final screen as one bounded,
    /// compressed vt-replay blob. `None` whenever the runtime surface is
    /// unavailable (dead-host reconciliation, daemon restart) or any capture
    /// step fails; exit persistence never depends on it.
    fn capture_terminal_exit_replay(
        &self,
        terminal_id: &str,
        generation: &str,
    ) -> Option<(TerminalPublicId, String, crate::workspace_registry::JournalContentBlob)> {
        let public_terminal_id =
            self.workspace_registry.lock().unwrap().terminal_resource_id(terminal_id).ok()??;
        let surface = self.terminal_resource_surface(&public_terminal_id)?;
        if surface.kind() != SurfaceKind::Pty {
            return None;
        }
        // Fence asynchronous output ingress so the journaled stream offset
        // recorded as the snapshot's coverage matches the captured VT state.
        self.flush_terminal_journal().ok()?;
        let blob =
            crate::journal_checkpoint::terminal_replay_blob(&surface, &public_terminal_id).ok()?;
        Some((public_terminal_id, generation.to_string(), blob))
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

    pub(crate) fn publish_resource_event(&self) {
        self.publish_journal_event();
    }

    pub(crate) fn publish_journal_event(&self) {
        self.journal_kernel.notify_commit();
        let mut epoch = self.journal_event_epoch.lock().unwrap();
        *epoch = epoch.wrapping_add(1);
        self.journal_event_changed.notify_all();
    }

    #[cfg_attr(not(test), allow(dead_code))]
    pub(crate) fn journal_terminal_output(
        &self,
        terminal_id: Arc<TerminalPublicId>,
        generation: Arc<str>,
        bytes: Vec<u8>,
    ) {
        if bytes.is_empty() {
            return;
        }
        self.journal_ingress.send(crate::journal_ingress::JournalIngressEvent::TerminalOutput {
            terminal_id,
            generation,
            occurred_at_ms: crate::workspace_registry::unix_epoch_ms().unwrap_or(0),
            bytes,
        });
    }

    pub(crate) fn try_journal_terminal_output(
        &self,
        terminal_id: Arc<TerminalPublicId>,
        generation: Arc<str>,
        occurred_at_ms: u64,
        bytes: Vec<u8>,
    ) -> Result<Option<(Vec<u8>, u64)>, String> {
        if bytes.is_empty() {
            return Ok(None);
        }
        match self.journal_ingress.try_send(
            crate::journal_ingress::JournalIngressEvent::TerminalOutput {
                terminal_id,
                generation,
                occurred_at_ms,
                bytes,
            },
        ) {
            Ok(()) => Ok(None),
            Err(crate::journal_ingress::JournalIngressTrySendError::Full {
                event,
                space_epoch,
            }) => Ok(match *event {
                crate::journal_ingress::JournalIngressEvent::TerminalOutput { bytes, .. } => {
                    Some((bytes, space_epoch))
                }
                _ => None,
            }),
            Err(crate::journal_ingress::JournalIngressTrySendError::Failed { event, error }) => {
                debug_assert!(matches!(
                    *event,
                    crate::journal_ingress::JournalIngressEvent::TerminalOutput { .. }
                ));
                Err(error)
            }
        }
    }

    pub(crate) fn wait_for_terminal_journal_space(&self, observed: u64) -> Result<(), String> {
        self.journal_ingress.wait_for_queue_space(observed)
    }

    pub(crate) fn flush_terminal_journal(&self) -> anyhow::Result<()> {
        self.journal_ingress.flush_terminal()
    }

    pub(crate) fn spawn_journal_writer(
        &self,
        name: &str,
        task: impl FnOnce() + Send + 'static,
    ) -> anyhow::Result<()> {
        self.journal_ingress.spawn_writer(name, task)
    }

    #[cfg(test)]
    pub(crate) fn install_journal_failure_notifier_for_test(&self, notifier: SyncSender<String>) {
        self.journal_ingress.install_failure_notifier_for_test(notifier);
    }

    #[cfg(test)]
    pub(crate) fn install_journal_nonretryable_failure_hook_for_test(
        &self,
        entered: SyncSender<()>,
        release: Receiver<()>,
    ) {
        self.journal_ingress.install_nonretryable_failure_hook_for_test(entered, release);
    }

    pub(crate) fn terminal_journal_enabled(&self) -> bool {
        self.journal_ingress.enabled()
    }

    pub fn journal_local_frontend_event(
        &self,
        event: crate::FrontendJournalEvent,
    ) -> anyhow::Result<()> {
        let principal_id = crate::server::public_client_id(&self.session_public_id, 0)?.to_string();
        self.journal_frontend_event(principal_id, event)
    }

    pub(crate) fn session_public_id(&self) -> SessionPublicId {
        self.session_public_id.clone()
    }

    pub(crate) fn journal_frontend_event(
        &self,
        principal_id: String,
        event: crate::FrontendJournalEvent,
    ) -> anyhow::Result<()> {
        self.journal_ingress.send_durable(crate::journal_ingress::JournalIngressEvent::Frontend {
            principal_id,
            occurred_at_ms: crate::workspace_registry::unix_epoch_ms()?,
            event,
        })
    }

    pub(crate) fn journal_terminal_resize(
        &self,
        terminal_id: Arc<TerminalPublicId>,
        generation: Arc<str>,
        cols: u16,
        rows: u16,
        cell_width: u16,
        cell_height: u16,
    ) {
        self.journal_ingress.send(crate::journal_ingress::JournalIngressEvent::TerminalResize {
            terminal_id,
            generation,
            occurred_at_ms: crate::workspace_registry::unix_epoch_ms().unwrap_or(0),
            cols,
            rows,
            cell_width,
            cell_height,
        });
    }

    pub(crate) fn commit_session_journal_events<F>(
        &self,
        events: &[&crate::journal_ingress::JournalIngressEvent],
        deadline: Instant,
        sqlite_wait_cap: Duration,
        admit_commit: F,
    ) -> anyhow::Result<Vec<Option<crate::JournalAppendCommit>>>
    where
        F: FnOnce() -> anyhow::Result<()>,
    {
        let stats = self.journal_ingress.stats();
        stats.set_phase(crate::diagnostics::WriterPhase::WaitingLock);
        let lock_wait_from = Instant::now();
        let lock_result = self
            .workspace_registry
            .lock_until(deadline)
            .context("waiting for the workspace registry journal writer");
        let lock_wait = lock_wait_from.elapsed();
        let mut registry = match lock_result {
            Ok(registry) => registry,
            Err(error) => {
                stats.commit_finished(lock_wait, Duration::ZERO);
                stats.set_phase(crate::diagnostics::WriterPhase::Idle);
                return Err(error);
            }
        };
        stats.set_phase(crate::diagnostics::WriterPhase::Committing);
        let commit_from = Instant::now();
        let remaining = deadline.saturating_duration_since(Instant::now());
        let commits = if remaining.is_zero() {
            Err(crate::JournalContention::COMMIT_DEADLINE.into())
        } else {
            registry.append_journal_ingress_events_with_deadline(
                events,
                deadline,
                remaining.min(sqlite_wait_cap),
                admit_commit,
            )
        };
        drop(registry);
        stats.commit_finished(lock_wait, commit_from.elapsed());
        stats.set_phase(crate::diagnostics::WriterPhase::Idle);
        let commits = commits?;
        self.publish_journal_event();
        Ok(commits)
    }

    /// Registry mutex contention, see [`crate::diagnostics::LockStats`].
    pub fn registry_lock_stats(&self) -> crate::diagnostics::LockStatsSnapshot {
        self.workspace_registry.stats().snapshot()
    }

    /// Journal writer metrics, `None` for ephemeral sessions without a
    /// durable journal.
    pub fn journal_writer_stats(&self) -> Option<crate::diagnostics::JournalWriterSnapshot> {
        self.journal_ingress.enabled().then(|| self.journal_ingress.stats().snapshot())
    }

    /// Resource projection and commit spans, see
    /// [`crate::diagnostics::ResourceProjectionStats`].
    pub fn resource_projection_stats(&self) -> crate::diagnostics::ResourceProjectionSnapshot {
        self.resource_projection_stats.snapshot()
    }

    pub(crate) fn connection_stats(&self) -> &Arc<crate::diagnostics::ConnectionStats> {
        &self.connection_stats
    }

    pub fn uptime(&self) -> Duration {
        self.started_at.elapsed()
    }

    #[cfg(test)]
    pub(crate) fn hold_workspace_registry_for_test(
        &self,
        entered: SyncSender<()>,
        release: Receiver<()>,
    ) {
        let _registry = self.workspace_registry.lock().unwrap();
        entered.send(()).unwrap();
        release.recv().unwrap();
    }

    #[cfg(test)]
    pub(crate) fn install_journal_before_commit_for_test(
        &self,
        entered: SyncSender<()>,
        release: Receiver<()>,
    ) {
        self.workspace_registry
            .lock()
            .unwrap()
            .set_journal_before_commit_for_test(entered, release);
    }

    #[cfg(test)]
    pub(crate) fn install_journal_after_commit_admission_for_test(
        &self,
        entered: SyncSender<()>,
        release: Receiver<()>,
    ) {
        self.workspace_registry
            .lock()
            .unwrap()
            .set_journal_after_commit_admission_for_test(entered, release);
    }

    pub(crate) fn journal_event_epoch(&self) -> u64 {
        *self.journal_event_epoch.lock().unwrap()
    }

    #[cfg(test)]
    pub(crate) fn wait_for_journal_event(&self, epoch: u64, timeout: Duration) -> u64 {
        let current = self.journal_event_epoch.lock().unwrap();
        if *current != epoch {
            return *current;
        }
        let (current, _) = self.journal_event_changed.wait_timeout(current, timeout).unwrap();
        *current
    }

    /// Like `wait_for_journal_event`, with no timeout: returns the new
    /// epoch, or `epoch` once `interrupt` has fired.
    pub(crate) fn wait_for_journal_event_until_interrupted(
        &self,
        epoch: u64,
        interrupt: &crate::stream_interrupt::StreamInterrupt,
    ) -> u64 {
        let mut current = self.journal_event_epoch.lock().unwrap();
        while *current == epoch && !interrupt.is_fired() {
            current = self.journal_event_changed.wait(current).unwrap();
        }
        *current
    }

    /// Like `wait_for_shared_journal`, with no timeout.
    pub(crate) fn wait_for_shared_journal_until_interrupted(
        &self,
        epoch: u64,
        interrupt: &crate::stream_interrupt::StreamInterrupt,
    ) -> u64 {
        self.journal_kernel.wait_until_interrupted(epoch, interrupt)
    }

    /// Wakes this mux's journal waiters when `interrupt` fires, so a
    /// session stream blocks until an event or its own close.
    pub(crate) fn wake_journal_waiters_on(
        self: &Arc<Self>,
        interrupt: &crate::stream_interrupt::StreamInterrupt,
    ) {
        let mux = Arc::downgrade(self);
        interrupt.on_fire(move || {
            if let Some(mux) = mux.upgrade() {
                {
                    let _epoch =
                        mux.journal_event_epoch.lock().unwrap_or_else(|error| error.into_inner());
                    mux.journal_event_changed.notify_all();
                }
                mux.journal_kernel.notify_waiters();
            }
        });
    }

    pub(crate) fn resource_event_epoch(&self) -> u64 {
        self.journal_event_epoch()
    }

    #[cfg(test)]
    pub(crate) fn wait_for_resource_event(&self, epoch: u64, timeout: Duration) -> u64 {
        self.wait_for_journal_event(epoch, timeout)
    }

    pub(crate) fn resource_events_after(
        &self,
        revision: u64,
    ) -> anyhow::Result<crate::workspace_registry::ResourceEventPage> {
        self.workspace_registry.lock().unwrap().resource_events_after(revision)
    }

    /// The journal head without decoding any record or sealed segment.
    pub(crate) fn session_journal_head(&self) -> anyhow::Result<u64> {
        self.workspace_registry.lock().unwrap().session_journal_head()
    }

    pub(crate) fn session_journal_after(
        &self,
        sequence: u64,
        limit: usize,
    ) -> anyhow::Result<crate::workspace_registry::SessionJournalPage> {
        self.workspace_registry.lock().unwrap().session_journal_after(sequence, limit)
    }

    pub(crate) fn session_journal_reader(
        &self,
    ) -> anyhow::Result<Option<crate::workspace_registry::SessionJournalReader>> {
        let database_path = self.workspace_registry.lock().unwrap().session_journal_database_path();
        database_path
            .as_deref()
            .map(crate::workspace_registry::SessionJournalReader::open)
            .transpose()
    }

    pub(crate) fn shared_journal_enabled(&self) -> bool {
        self.journal_kernel.enabled()
    }

    pub(crate) fn shared_journal_epoch(&self) -> u64 {
        self.journal_kernel.epoch()
    }

    pub(crate) fn shared_journal_handle(&self) -> Arc<crate::journal_kernel::JournalKernel> {
        self.journal_kernel.clone()
    }

    #[cfg(test)]
    pub(crate) fn wait_for_shared_journal(&self, epoch: u64, timeout: Duration) -> u64 {
        self.journal_kernel.wait(epoch, timeout)
    }

    pub(crate) fn shared_journal_after(
        &self,
        sequence: u64,
        limit: usize,
    ) -> crate::journal_kernel::SharedJournalRead {
        self.journal_kernel.read_after(sequence, limit)
    }

    pub(crate) fn journal_producer_manifests(
        &self,
    ) -> anyhow::Result<Vec<crate::JournalProducerManifest>> {
        self.workspace_registry.lock().unwrap().journal_producer_manifests()
    }

    pub(crate) fn userland_journal_producer_manifests(
        &self,
    ) -> anyhow::Result<Vec<crate::JournalProducerManifest>> {
        self.workspace_registry.lock().unwrap().userland_journal_producer_manifests()
    }

    pub(crate) fn put_journal_producer(
        &self,
        manifest: &crate::JournalProducerManifest,
        origin: &str,
        idempotency_key: &str,
    ) -> anyhow::Result<crate::JournalAppendCommit> {
        let prepared = crate::journal_kernel::JournalKernel::prepare_producer(manifest)?;
        let commit = self.workspace_registry.lock().unwrap().put_journal_producer(
            manifest,
            origin,
            idempotency_key,
        )?;
        if !commit.replayed {
            // Installation is version-monotonic, so concurrent successful
            // updates cannot publish their compiled validators out of order.
            self.journal_kernel.install_prepared_producer(prepared);
            self.publish_journal_event();
        }
        Ok(commit)
    }

    pub(crate) fn append_journal_ingress(
        &self,
        ingress: &crate::JournalIngress,
        origin: &str,
        idempotency_key: &str,
    ) -> anyhow::Result<crate::JournalAppendCommit> {
        let validated = match self.journal_kernel.validate_ingress(ingress) {
            Ok(validated) => validated,
            Err(validation_error) => {
                // A receipt is authoritative for an exact retry. Its ingress
                // may name a superseded manifest after a producer upgrade,
                // while a new ingress must still pass current validation.
                let replay = {
                    let registry = self.workspace_registry.lock().unwrap();
                    registry.replay_journal_ingress(ingress, origin, idempotency_key)?
                };
                if let Some(commit) = replay {
                    return self.finish_journal_ingress(ingress, origin, idempotency_key, commit);
                }
                return Err(validation_error);
            }
        };
        let commit = if self.journal_ingress.enabled() {
            self.journal_ingress.send_producer(
                ingress.clone(),
                validated,
                origin.into(),
                idempotency_key.into(),
            )?
        } else {
            let commit = self.workspace_registry.lock().unwrap().append_journal_ingress(
                ingress,
                &validated,
                origin,
                idempotency_key,
            )?;
            if !commit.replayed {
                self.publish_journal_event();
            }
            commit
        };
        if !commit.replayed && ingress.producer_id == crate::AGENT_HOOK_PRODUCER_ID {
            self.activity.note_agent_action();
        }
        self.finish_journal_ingress(ingress, origin, idempotency_key, commit)
    }

    fn finish_journal_ingress(
        &self,
        ingress: &crate::JournalIngress,
        origin: &str,
        idempotency_key: &str,
        commit: crate::JournalAppendCommit,
    ) -> anyhow::Result<crate::JournalAppendCommit> {
        // Replayed journal commits still need projection reconciliation. A
        // process can crash after the durable journal commit and before the
        // in-memory/resource projection update. The sequence guard makes this
        // a no-op for already-applied events while allowing restart repair.
        if let Err(error) = self.apply_agent_hook_record(ingress, commit.sequence) {
            if agent_hook_terminal_gone(&error) {
                if let Err(_bookkeeping_error) = self
                    .workspace_registry
                    .lock()
                    .unwrap()
                    .clear_agent_hook_pending(&ingress.producer_id, origin, idempotency_key)
                {
                    self.report_internal_diagnostic("terminal-gone agent hook cleanup deferred");
                }
            } else {
                if let Err(_bookkeeping_error) =
                    self.workspace_registry.lock().unwrap().enqueue_agent_hook_pending(
                        &ingress.producer_id,
                        origin,
                        idempotency_key,
                        commit.sequence,
                        ingress,
                        AgentHookPendingFailure {
                            error: AGENT_HOOK_RETRY_ERROR,
                            retry_class: agent_hook_retry_class(&error),
                        },
                    )
                {
                    self.report_internal_diagnostic(
                        "durable agent hook receipt remains staged after retry bookkeeping failure",
                    );
                }
            }
        } else if let Err(_bookkeeping_error) = self
            .workspace_registry
            .lock()
            .unwrap()
            .clear_agent_hook_pending(&ingress.producer_id, origin, idempotency_key)
        {
            self.report_internal_diagnostic(
                "agent hook projection applied; retry bookkeeping cleanup deferred",
            );
        }
        // A replayed plugin event can repair a projection after a process
        // crash between the durable journal commit and the in-memory fold.
        // Hook replay remains owned by its durable retry projector, while the
        // generic plugin envelope is safe to fold repeatedly because the
        // reducer fences by journal sequence and observed timestamp.
        let is_plugin_event = ingress.payload.get("format").and_then(Value::as_str)
            == Some(crate::journal_reducers::AGENT_PLUGIN_FORMAT);
        // A replay can follow a crash before either projection or reducer
        // side effects. The reducer cursor makes folding an already-applied
        // sequence a no-op, so replay every agent event and repair a missing
        // roster fold without duplicating live deltas.
        if !commit.replayed
            || is_plugin_event
            || ingress.producer_id == crate::agent_hooks::AGENT_HOOK_PRODUCER_ID
        {
            self.fold_agent_roster(ingress, &commit);
        }
        Ok(commit)
    }

    /// Committed agent hook events double as the live agent-status feed:
    /// a fresh `agent.*` journal event updates its terminal's agent record,
    /// so agents views show working/blocked/idle/done without a separate
    /// reporting channel. The journal commit remains durable even when the
    /// projection fails. The ingress path catches the projection error, stages
    /// a durable pending row, and still returns the journal receipt so callers
    /// can retain exactly-once semantics while the terminal becomes available.
    fn apply_agent_hook_record(
        &self,
        ingress: &crate::JournalIngress,
        sequence: u64,
    ) -> anyhow::Result<()> {
        if ingress.producer_id != crate::agent_hooks::AGENT_HOOK_PRODUCER_ID {
            return Ok(());
        }
        // Screen-detection events reuse the agent-hook envelope and the
        // `agent.session.ended` kind for process exits. They are owned by
        // the roster reducer, not the hook fence projector; otherwise a
        // detected process exit would create a Hook `Done` fence and could
        // suppress a later real hook lifecycle.
        if ingress.payload.get("native_event").and_then(Value::as_str)
            == Some(crate::journal_reducers::LEGACY_SCREEN_DETECT_NATIVE_EVENT)
        {
            return Ok(());
        }
        let Some(state) = agent_state_for_hook_kind(&ingress.kind) else { return Ok(()) };
        let Some(terminal_subject) =
            ingress.subjects.iter().find(|subject| subject.kind == "terminal")
        else {
            return Ok(());
        };
        let terminal_id = TerminalPublicId::parse(&terminal_subject.id)
            .with_context(|| format!("invalid terminal subject {:?}", terminal_subject.id))?;
        let Some(surface) = self.resource_surface_for_terminal(&terminal_id) else {
            // A durable terminal that is still live may be between journal
            // commit and host materialization. A missing or tombstoned
            // terminal cannot become available, so do not retain its receipt
            // in the retry queue forever.
            let terminal_is_retryable = self
                .workspace_registry
                .lock()
                .unwrap()
                .agent_hook_terminal_retryable(&terminal_id)?;
            if !terminal_is_retryable {
                return Err(anyhow::Error::new(AgentHookTerminalGone));
            }
            return Err(anyhow::Error::new(AgentHookTerminalUnavailable).context(format!(
                "terminal {terminal_id} is not available for agent hook projection"
            )));
        };
        // Serialize the sequence check, projection commit, and sequence
        // update as one operation. The projection path takes registry, state,
        // then agent-record locks, so teardown acquires sequence before those
        // locks as well.
        let mut fences = self.agent_hook_fences.lock().unwrap();
        let explicit_session_id = ingress
            .payload
            .get("normalized")
            .and_then(|value| value.get("agent_session_id"))
            .and_then(Value::as_str)
            .filter(|session_id| !session_id.is_empty());
        let is_session_start = ingress.kind == "agent.session.started";
        let observed_at_ms = crate::journal_reducers::hook_observed_at_ms(&ingress.payload);
        let previous_fence = fences.get(&terminal_id).cloned();
        let JournalHookTransition::Apply(agent_session_id) = HookFence::journal_transition(
            previous_fence.as_ref(),
            terminal_id.as_str(),
            explicit_session_id,
            is_session_start,
            sequence,
            observed_at_ms,
        ) else {
            return Ok(());
        };
        let next_fence = HookFence::next(
            previous_fence.as_ref(),
            agent_session_id.clone(),
            sequence,
            state == AgentState::Done,
            observed_at_ms,
        );
        // Attention-worthy transitions become durable notifications before
        // the agent report commits. The notification key is derived from the
        // journal sequence, so a retry after a crash between the two commits
        // replays the notification instead of posting it twice, and the fence
        // (stored by the report) still advances exactly once.
        if let Some((title, body, level)) = agent_hook_notification(ingress) {
            self.create_durable_notification(
                &Actor::Daemon,
                &format!("agent-hook-notification-{sequence}"),
                title,
                None,
                body,
                level,
                Some(surface),
                NotificationSource::Agent,
            )
            .with_context(|| format!("agent hook notification for sequence {sequence}"))?;
        }
        // The record's session field is a human-facing label; native agent
        // session ids are opaque, so views fall back to their own context.
        let marker = if state == AgentState::Done {
            format!("cmux-hook-ended:{sequence}")
        } else {
            format!("cmux-hook-sequence:{sequence}")
        };
        let (harness, ended) = (agent_provider_identity(ingress), state == AgentState::Done);
        self.note_relaunch_agent(&terminal_id, harness, explicit_session_id, ended);
        let hook_state = crate::workspace_registry::AgentHookProjectionState {
            agent_session_id,
            applied_sequence: sequence,
            ended: state == AgentState::Done,
            ended_at_ms: next_fence.ended_at_ms,
        };
        self.report_agent_with_sequence_lock(
            surface,
            state,
            AgentSource::Hook,
            Some(marker),
            true,
            Some(hook_state),
            Some(sequence),
            AgentReportOrigin::RosterFold,
            agent_provider_identity(ingress),
        )?;
        fences.insert(terminal_id.clone(), next_fence);
        // Projection ordering is complete. Do not carry the fence guard into
        // cleanup or any retry/reentrant path.
        drop(fences);
        // An ended session leaves the roster entirely: the done state was
        // committed and broadcast above (so remote caches converge), and the
        // live record is dropped so agents views stop listing the terminal
        // and a fresh agent there starts clean. Hooks of one terminal are
        // sequential (they follow one agent process's lifecycle), so nothing
        // races this removal.
        if state == AgentState::Done {
            let mut records = self.agent_records.lock().unwrap();
            if records.get(&terminal_id).is_some_and(|record| record.state == AgentState::Done) {
                records.remove(&terminal_id);
            }
        }
        Ok(())
    }

    /// Fold one fresh `agent.*` journal commit into the roster reducer and
    /// apply the resulting deltas (projection commits, change broadcasts).
    /// The roster is derived state: this fold plus the startup tail replay
    /// are its only writers, so the journal fully determines it. Best
    /// effort by design: a hook may outlive its terminal, and a journal
    /// append must never start failing because a view cannot update.
    fn fold_agent_roster(
        &self,
        ingress: &crate::JournalIngress,
        commit: &crate::JournalAppendCommit,
    ) {
        use crate::journal_reducers::{
            AGENT_ROSTER_REDUCER_ID, AGENT_ROSTER_REDUCER_VERSION, RosterEvent,
        };
        if ingress.producer_id != crate::agent_hooks::AGENT_HOOK_PRODUCER_ID
            && ingress.payload.get("format").and_then(Value::as_str)
                != Some(crate::journal_reducers::AGENT_PLUGIN_FORMAT)
        {
            return;
        }
        let _fold = self.agent_roster_fold.lock().unwrap();
        // Consume every intervening committed record under registry -> roster
        // lock order. Concurrent appends and delayed hook retries cannot jump
        // the cursor over a record that startup replay would have consumed.
        let (deltas, cursor, snapshot) = {
            let registry = self.workspace_registry.lock().unwrap();
            let mut host = self.agent_roster.lock().unwrap();
            if commit.sequence <= host.cursor {
                return;
            }
            let mut deltas = Vec::new();
            while host.cursor < commit.sequence {
                let page = match registry.session_journal_after(host.cursor, 512) {
                    Ok(page) => page,
                    Err(error) => {
                        eprintln!("cmux-tui: reading agent journal tail failed: {error}");
                        return;
                    }
                };
                if page.records.is_empty() {
                    break;
                }
                for record in
                    page.records.iter().take_while(|record| record.sequence <= commit.sequence)
                {
                    let changes = host.roster.apply(&RosterEvent::from_record(record));
                    // Hooks already use the durable projector, which decides
                    // events with the same session fence as this fold.
                    // Applying their reducer delta again would duplicate its
                    // projection mutations.
                    if record.payload.get("format").and_then(Value::as_str)
                        == Some(crate::journal_reducers::AGENT_PLUGIN_FORMAT)
                    {
                        deltas.extend(changes);
                    }
                    host.cursor = record.sequence;
                }
            }
            (deltas, host.cursor, host.roster.snapshot().to_string())
        };
        if let Err(error) = self.workspace_registry.lock().unwrap().put_journal_reducer_state(
            AGENT_ROSTER_REDUCER_ID,
            AGENT_ROSTER_REDUCER_VERSION,
            cursor,
            &snapshot,
        ) {
            eprintln!("cmux-tui: persisting the agent roster snapshot failed: {error}");
        }
        for delta in deltas {
            self.apply_roster_delta(delta, &ingress.kind);
        }
    }

    /// Repair public projections whose plugin roster event was folded before
    /// the daemon stopped. The roster is the canonical live view; the
    /// projection is a separately committed compatibility view for clients.
    /// Compare durable values first so a healthy restart emits no mutations.
    fn reconcile_agent_roster_projections(&self) {
        let entries = self
            .agent_roster
            .lock()
            .unwrap()
            .roster
            .entries
            .iter()
            .filter(|(_, entry)| entry.agent_source() == AgentSource::Plugin)
            .map(|(terminal_id, entry)| (terminal_id.clone(), entry.clone()))
            .collect::<Vec<_>>();
        for (terminal_id, entry) in entries {
            let Ok(terminal_id) = TerminalPublicId::parse(&terminal_id) else { continue };
            self.reconcile_agent_roster_projection_for_entry(&terminal_id, entry);
        }
    }

    fn reconcile_agent_roster_projections_for_terminal(&self, terminal_id: &TerminalPublicId) {
        let entry = self
            .agent_roster
            .lock()
            .unwrap()
            .roster
            .entries
            .get(terminal_id.as_str())
            .filter(|entry| entry.agent_source() == AgentSource::Plugin)
            .cloned();
        if let Some(entry) = entry {
            self.reconcile_agent_roster_projection_for_entry(terminal_id, entry);
        }
    }

    fn reconcile_agent_roster_projection_for_entry(
        &self,
        terminal_id: &TerminalPublicId,
        entry: crate::journal_reducers::RosterEntry,
    ) {
        let registry = match self.workspace_registry.lock() {
            Ok(registry) => registry,
            Err(_) => {
                eprintln!(
                    "cmux-tui: could not inspect agent projection for {terminal_id} during startup reconciliation: workspace registry mutex is poisoned"
                );
                return;
            }
        };
        let projection = match registry.public_agent_projections(Some(terminal_id), None) {
            Ok(projections) => projections.into_iter().next(),
            Err(error) => {
                eprintln!(
                    "cmux-tui: could not inspect agent projection for {terminal_id} during startup reconciliation: {error}"
                );
                return;
            }
        };
        drop(registry);
        let matches = projection.as_ref().is_some_and(|projection| {
            projection.state == entry.state
                && projection.source == entry.source
                && projection.source_session == entry.session
                && projection.agent == entry.agent
        });
        if matches {
            return;
        }
        self.apply_roster_delta(
            crate::journal_reducers::RosterDelta::Upsert {
                terminal_id: terminal_id.to_string(),
                entry,
            },
            "startup-reconcile",
        );
    }

    /// Apply one roster delta's side effects: the durable agent projection
    /// commit and the agent-changed broadcast remote frontends converge on.
    /// A removal commits the done state (history keeps the exit; the roster
    /// already dropped the live entry).
    fn apply_roster_delta(&self, delta: crate::journal_reducers::RosterDelta, kind: &str) {
        use crate::journal_reducers::RosterDelta;
        let (terminal_id, state, source, session, agent_adapter) = match delta {
            RosterDelta::Upsert { terminal_id, entry } => (
                terminal_id,
                entry.agent_state(),
                entry.agent_source(),
                entry.session.clone(),
                entry.agent,
            ),
            RosterDelta::Remove { terminal_id, source } => {
                (terminal_id, AgentState::Done, source, None, None)
            }
        };
        let Ok(terminal_id) = TerminalPublicId::parse(&terminal_id) else { return };
        let Some(surface) = self.resource_surface_for_terminal(&terminal_id) else { return };
        let mutation = match WorkspaceMutation::daemon(
            format!("roster-{}", crate::workspace_registry::new_uuid_v4()),
            "journal-reducer",
        ) {
            Ok(mutation) => mutation,
            Err(_) => return,
        };
        let fingerprint = serde_json::json!({
            "operation":"agent.report",
            "surface":surface,
            "state":state.as_str(),
            "source":source.as_str(),
            "source_session":session,
        });
        if let Err(error) = self.commit_agent_report(
            AgentReportTarget::Surface(surface),
            state,
            source,
            session,
            None,
            &mutation,
            &fingerprint,
            false,
            None,
            None,
            AgentReportOrigin::RosterFold,
            agent_adapter,
        ) {
            eprintln!(
                "cmux-tui: agent projection update for {terminal_id} ({kind}) failed: {error}"
            );
        }
    }

    /// Record a direct socket/SDK agent report in the journal so the roster
    /// reducer (and any future reducer) sees every agent intent in one log.
    /// The event wears the agent-hook payload shape with a dedicated
    /// adapter, and the fold recognizes that adapter as an echo whose
    /// projection commit already happened.
    fn append_agent_report_echo(
        &self,
        terminal_id: &TerminalPublicId,
        state: AgentState,
        source: AgentSource,
        session: Option<&str>,
        updated_at_ms: u64,
    ) {
        use crate::journal_reducers::{SOCKET_REPORT_ADAPTER, SOCKET_REPORT_NATIVE_EVENT};
        let ingress = crate::JournalIngress {
            producer_id: crate::agent_hooks::AGENT_HOOK_PRODUCER_ID.into(),
            manifest_version: crate::agent_hooks::AGENT_HOOK_MANIFEST_VERSION,
            kind: "agent.state.changed".into(),
            schema_version: 1,
            occurred_at_ms: None,
            subjects: vec![crate::JournalSubject {
                kind: "terminal".into(),
                id: terminal_id.to_string(),
            }],
            sensitivity: Some(crate::JournalSensitivity::Sensitive),
            payload: serde_json::json!({
                "format": crate::agent_hooks::AGENT_HOOK_FORMAT,
                "adapter": {"id": SOCKET_REPORT_ADAPTER, "version": 1},
                "native_event": SOCKET_REPORT_NATIVE_EVENT,
                "normalized": {
                    "state": state.as_str(),
                    "source": source.as_str(),
                    "source_session": session,
                    // The direct commit's timestamp, so the roster mirrors
                    // the projection exactly instead of stamping fold time.
                    "updated_at_ms": updated_at_ms.to_string(),
                },
                "native": {},
            }),
            causation_id: None,
            correlation_id: None,
        };
        let idempotency_key =
            format!("agent-report-echo-{}", crate::workspace_registry::new_uuid_v4());
        if let Err(error) = self.append_journal_ingress(&ingress, "agent-report", &idempotency_key)
        {
            eprintln!("cmux-tui: journaling an agent report for {terminal_id} failed: {error}");
        }
    }

    pub(crate) fn journal_hook_states(
        &self,
    ) -> anyhow::Result<Vec<crate::workspace_registry::JournalHookState>> {
        self.workspace_registry.lock().unwrap().journal_hook_states()
    }

    pub(crate) fn journal_events_caused_by_hooks(
        &self,
        hook_ids: &[String],
        event_ids: &[String],
    ) -> anyhow::Result<HashSet<(String, String)>> {
        self.workspace_registry.lock().unwrap().journal_events_caused_by_hooks(hook_ids, event_ids)
    }

    pub(crate) fn put_journal_hook(
        self: &Arc<Self>,
        manifest: &crate::JournalHookManifest,
        origin: &str,
        idempotency_key: &str,
    ) -> anyhow::Result<crate::JournalAppendCommit> {
        let commit = self.workspace_registry.lock().unwrap().put_journal_hook(
            manifest,
            origin,
            idempotency_key,
        )?;
        if !commit.replayed {
            self.publish_journal_event();
        }
        crate::journal_hooks::start(self)?;
        Ok(commit)
    }

    pub(crate) fn try_claim_journal_hook_dispatcher(&self) -> bool {
        self.journal_hook_dispatcher_started
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_ok()
    }

    pub(crate) fn journal_hook_runtime(&self) -> Arc<crate::journal_hooks::JournalHookRuntime> {
        self.journal_hook_runtime.clone()
    }

    pub(crate) fn release_journal_hook_dispatcher(&self) {
        self.journal_hook_dispatcher_started.store(false, Ordering::Release);
    }

    pub(crate) fn schedule_journal_hook_deliveries(
        &self,
        scans: &[crate::workspace_registry::JournalHookScan],
    ) -> anyhow::Result<Vec<bool>> {
        self.workspace_registry.lock().unwrap().schedule_journal_hook_deliveries(scans)
    }

    /// When the next scheduled hook retry is due, if any.
    pub(crate) fn next_journal_hook_attempt_deadline(&self) -> anyhow::Result<Option<Instant>> {
        let now_ms = crate::workspace_registry::unix_epoch_ms()?;
        let next = self.workspace_registry.lock().unwrap().next_journal_hook_attempt_at_ms()?;
        Ok(next.map(|at| Instant::now() + Duration::from_millis(at.saturating_sub(now_ms))))
    }

    pub(crate) fn pending_journal_hook_deliveries(
        &self,
        limit: usize,
    ) -> anyhow::Result<Vec<crate::workspace_registry::JournalHookDelivery>> {
        let now_ms = crate::workspace_registry::unix_epoch_ms()?;
        self.workspace_registry.lock().unwrap().pending_journal_hook_deliveries(now_ms, limit)
    }

    pub(crate) fn start_journal_hook_deliveries(
        &self,
        deliveries: &[crate::workspace_registry::JournalHookDelivery],
    ) -> anyhow::Result<Vec<crate::workspace_registry::JournalHookAttempt>> {
        let attempts =
            self.workspace_registry.lock().unwrap().start_journal_hook_deliveries(deliveries)?;
        if !attempts.is_empty() {
            self.publish_journal_event();
        }
        Ok(attempts)
    }

    pub(crate) fn finish_journal_hook_deliveries(
        &self,
        results: &[crate::workspace_registry::JournalHookDeliveryResult],
    ) -> anyhow::Result<()> {
        self.workspace_registry.lock().unwrap().finish_journal_hook_deliveries(results)?;
        if !results.is_empty() {
            self.publish_journal_event();
        }
        Ok(())
    }

    /// Sends a diagnostic to the frontend-owned sink without writing to a
    /// frontend terminal. The first messages are retained when startup races
    /// sink installation, so a later startup message cannot replace an
    /// earlier one (the agent roster restore reports before hook retries).
    pub(crate) fn report_internal_diagnostic(&self, message: impl Into<String>) {
        let message = message.into();
        if let Some(reporter) = self.diagnostic_reporter.get().cloned() {
            reporter(&message);
            return;
        }

        // Mux construction can start hosted-surface readers before the
        // frontend has a chance to install its reporter. Recheck under the
        // pending slot lock so a concurrent setter cannot leave this message
        // stranded between the initial lookup and the store.
        let mut pending = self.pending_diagnostics.lock().unwrap();
        if let Some(reporter) = self.diagnostic_reporter.get().cloned() {
            drop(pending);
            reporter(&message);
        } else if pending.len() < MAX_PENDING_DIAGNOSTICS {
            pending.push(message);
        }
    }

    /// Logs a skipped terminal-host reconnect checkpoint at most once
    /// until a later reconnect checkpoint succeeds. A checkpoint is a
    /// journal-replay optimization: skipping one only moves the next replay
    /// boundary back, so repeated skips are daemon-log noise, not per-toast
    /// news.
    pub(crate) fn report_skipped_reconnect_checkpoint(
        &self,
        terminal_id: impl fmt::Display,
        error: &anyhow::Error,
    ) {
        let message = format!(
            "skipped terminal {terminal_id} reconnect checkpoint (replay starts from the previous boundary): {error:#}"
        );
        if self.reconnect_checkpoint_skip_reported.swap(true, Ordering::AcqRel) {
            return;
        }
        self.report_internal_diagnostic(message);
    }

    /// Installs the frontend-owned sink for diagnostics emitted by the mux.
    ///
    /// A mux has one owner for its lifetime, so accepting the first reporter
    /// avoids replacing a sink while a reconnect worker is reporting. A
    /// caller that tries to install a second sink receives `false` and must
    /// keep the original owner unchanged.
    pub fn set_diagnostic_reporter(&self, reporter: DiagnosticReporter) -> bool {
        let pending_reporter = reporter.clone();
        if self.diagnostic_reporter.set(reporter).is_err() {
            return false;
        }
        let pending = std::mem::take(&mut *self.pending_diagnostics.lock().unwrap());
        for message in pending {
            pending_reporter(&message);
        }
        true
    }

    pub(crate) fn note_reconnect_checkpoint_captured(&self) {
        self.reconnect_checkpoint_skip_reported.store(false, Ordering::Release);
    }

    pub(crate) fn create_journal_checkpoint(
        &self,
        origin: &str,
        idempotency_key: &str,
    ) -> anyhow::Result<crate::workspace_registry::JournalCheckpointCommit> {
        if let Some(commit) = self
            .workspace_registry
            .lock()
            .unwrap()
            .journal_checkpoint_receipt(origin, idempotency_key)?
        {
            return Ok(commit);
        }
        let captured = crate::journal_checkpoint::capture(self)?;
        let commit = self.workspace_registry.lock().unwrap().create_journal_checkpoint(
            captured.source_sequence,
            crate::journal_checkpoint::JOURNAL_REDUCER_VERSION,
            &captured.state,
            &captured.blobs,
            origin,
            idempotency_key,
        )?;
        if !commit.journal.replayed {
            self.publish_journal_event();
        }
        Ok(commit)
    }

    pub(crate) fn journal_checkpoints(
        &self,
    ) -> anyhow::Result<Vec<crate::workspace_registry::JournalCheckpointSummary>> {
        self.workspace_registry.lock().unwrap().journal_checkpoints()
    }

    pub(crate) fn journal_restore_preview(&self, selector: &str) -> anyhow::Result<Value> {
        let checkpoint = self
            .workspace_registry
            .lock()
            .unwrap()
            .journal_checkpoint(selector)?
            .with_context(|| format!("journal checkpoint {selector:?} does not exist"))?;
        let mut reducer = crate::journal_checkpoint::RestoreReducer::new(&checkpoint)?;

        let database_path = self.workspace_registry.lock().unwrap().session_journal_database_path();
        if let Some(database_path) = database_path {
            let reader = crate::workspace_registry::SessionJournalReader::open(&database_path)?;
            let mut cursor = reader.restore_cursor(checkpoint.source_sequence)?;
            let head_sequence = loop {
                let page = cursor.next_page(1024)?;
                let head = page.head_sequence;
                let empty = page.records.is_empty();
                for record in page.records {
                    reducer.apply(&record)?;
                }
                if empty {
                    break head;
                }
            };
            cursor.finish()?;
            return reducer.finish(head_sequence);
        }

        let mut sequence = checkpoint.source_sequence;
        let mut target_head = None;
        let head_sequence = loop {
            let page = self.session_journal_after(sequence, 1024)?;
            let head = *target_head.get_or_insert(page.head_sequence);
            let empty = page.records.is_empty();
            for record in page.records {
                if record.sequence > head {
                    break;
                }
                sequence = record.sequence;
                reducer.apply(&record)?;
            }
            if empty || sequence >= head {
                break head;
            }
        };
        reducer.finish(head_sequence)
    }

    pub(crate) fn journal_segments(&self) -> anyhow::Result<Vec<crate::JournalSegment>> {
        self.workspace_registry.lock().unwrap().journal_segments()
    }

    pub(crate) fn seal_journal_segments(
        &self,
        through_sequence: u64,
        origin: &str,
        idempotency_key: &str,
    ) -> anyhow::Result<crate::workspace_registry::JournalSegmentSealCommit> {
        let database_path = self
            .workspace_registry
            .lock()
            .unwrap()
            .session_journal_database_path()
            .context("journal segment sealing requires a persistent session")?;
        let reader = crate::workspace_registry::SessionJournalReader::open(&database_path)?;
        for _ in 0..4 {
            let start = self.workspace_registry.lock().unwrap().begin_journal_segment_seal(
                through_sequence,
                origin,
                idempotency_key,
            )?;
            let plan = match start {
                crate::workspace_registry::JournalSegmentSealStart::Replay(commit) => {
                    return Ok(commit);
                }
                crate::workspace_registry::JournalSegmentSealStart::Prepare(plan) => plan,
            };
            #[cfg(test)]
            if let Some(hook) = self.journal_segment_prepare_hook.lock().unwrap().take() {
                hook();
            }
            let prepared = plan.prepare(&reader)?;
            let commit = self.workspace_registry.lock().unwrap().commit_journal_segment_seal(
                prepared,
                origin,
                idempotency_key,
            )?;
            if let Some(commit) = commit {
                if !commit.journal.replayed {
                    self.publish_journal_event();
                }
                return Ok(commit);
            }
        }
        anyhow::bail!("journal segment boundary changed repeatedly during sealing")
    }

    #[cfg(test)]
    pub(crate) fn set_screen_created_hook_for_test(
        &self,
        hook: impl FnOnce(SurfaceId) + Send + 'static,
    ) {
        *self.screen_created_hook.lock().unwrap_or_else(PoisonError::into_inner) =
            Some(Box::new(hook));
    }

    #[cfg(test)]
    pub(crate) fn set_journal_segment_prepare_hook_for_test(
        &self,
        hook: impl FnOnce() + Send + 'static,
    ) {
        *self.journal_segment_prepare_hook.lock().unwrap() = Some(Box::new(hook));
    }

    #[cfg(test)]
    pub(crate) fn journal_database_reader_count_for_test(&self) -> u64 {
        self.journal_kernel.database_reader_count()
    }

    #[cfg(test)]
    pub(crate) fn resource_mutation_count_for_test(&self) -> anyhow::Result<u64> {
        self.workspace_registry.lock().unwrap().resource_mutation_count_for_test()
    }

    #[cfg(test)]
    pub(crate) fn resource_agent_projection_count_for_test(&self) -> anyhow::Result<u64> {
        self.workspace_registry.lock().unwrap().resource_agent_projection_count_for_test()
    }

    #[cfg(test)]
    pub(crate) fn corrupt_agent_projection_for_test(&self, terminal_id: &TerminalPublicId) {
        self.workspace_registry.lock().unwrap().corrupt_agent_projection_for_test(terminal_id);
    }

    pub fn terminal_registry_snapshot(&self) -> anyhow::Result<TerminalRegistrySnapshot> {
        self.workspace_registry.lock().unwrap().terminal_snapshot()
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
        expected_projection_revision: Option<u64>,
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
        let projection_revision = registry
            .get_frontend_projection("resource-api", "session", projection_id.as_str())?
            .map(|projection| projection.projection_revision)
            .unwrap_or(0)
            .checked_add(1)
            .context("frontend projection revision exhausted")?;
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
            "frontend_id":projection["frontend_id"],
            "window_id":projection["window_id"],
            "generation":projection["generation"],
            "projection":projection["projection"],
            "projection_revision":projection_revision.to_string(),
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
            expected_projection_revision,
            "resource-api",
            "session",
            projection_id.as_str(),
            RESOURCE_API_FRONTEND_PROJECTION_SCHEMA_VERSION,
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

    pub fn subscribe_config_reload(&self) -> MuxEventReceiver {
        self.subscribers.subscribe_config_reload()
    }

    /// Request one owner config reload and wait until the owner applies it.
    pub fn request_config_reload(&self) -> Result<(), ConfigReloadError> {
        const APPLY_TIMEOUT: Duration = Duration::from_secs(5);

        let request = {
            let mut state = self.config_reload.lock().unwrap();
            state.requested = state.requested.saturating_add(1);
            state.requested
        };
        self.emit(MuxEvent::ConfigReloadRequested);

        let deadline = Instant::now() + APPLY_TIMEOUT;
        let mut state = self.config_reload.lock().unwrap();
        while state.applied < request {
            if self.shutting_down.load(Ordering::Acquire) {
                return Err(ConfigReloadError::OwnerStopped);
            }
            let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
                return Err(ConfigReloadError::TimedOut);
            };
            let (next, timeout) =
                self.config_reload_changed.wait_timeout(state, remaining).unwrap();
            state = next;
            if timeout.timed_out() && state.applied < request {
                return Err(ConfigReloadError::TimedOut);
            }
        }
        Ok(())
    }

    /// Capture the newest request that the owner is about to apply.
    pub fn begin_config_reload_application(&self) -> u64 {
        self.config_reload.lock().unwrap().requested
    }

    /// Publish completion after the owner applies the captured request.
    pub fn complete_config_reload_application(&self, request: u64) {
        let mut state = self.config_reload.lock().unwrap();
        state.applied = state.applied.max(request);
        drop(state);
        self.config_reload_changed.notify_all();
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
        self.activity.observe(&event);
        self.subscribers.emit(event);
    }

    pub(crate) fn emit_terminal_output(&self, runtime_id: SurfaceId) {
        for placement in self.terminal_event_placements(runtime_id) {
            self.emit(MuxEvent::SurfaceOutput(placement));
        }
    }

    fn terminal_event_placements(&self, surface_id: SurfaceId) -> Vec<SurfaceId> {
        let state = self.state.lock().unwrap();
        let Some(surface) =
            state.surfaces.get(&surface_id).or_else(|| state.terminal_runtime_by_id(surface_id))
        else {
            return vec![surface_id];
        };
        let Some(runtime_id) = surface.terminal_runtime_id() else { return vec![surface_id] };
        let Some(terminal_id) = surface.terminal_public_id() else { return vec![surface_id] };
        let placements = state
            .placements_of_content(&ContentPublicId::Terminal(terminal_id.clone()))
            .iter()
            .copied()
            .filter(|placement| {
                state
                    .surfaces
                    .get(placement)
                    .is_some_and(|surface| surface.terminal_runtime_id() == Some(runtime_id))
            })
            .collect::<Vec<_>>();
        if placements.is_empty() && state.surfaces.contains_key(&surface_id) {
            vec![surface_id]
        } else {
            placements
        }
    }

    pub(crate) fn emit_terminal_title(&self, surface: SurfaceId, title: Arc<str>) {
        for placement in self.terminal_event_placements(surface) {
            self.emit(MuxEvent::TitleChanged { surface: placement, title: title.clone() });
        }
    }

    pub(crate) fn emit_terminal_bell(&self, surface: SurfaceId) {
        for placement in self.terminal_event_placements(surface) {
            self.emit(MuxEvent::Bell(placement));
        }
    }

    pub(crate) fn emit_terminal_resized(
        &self,
        surface: SurfaceId,
        cols: u16,
        rows: u16,
        reservation_id: Option<u64>,
    ) {
        for placement in self.terminal_event_placements(surface) {
            self.emit(MuxEvent::SurfaceResized { surface: placement, cols, rows, reservation_id });
        }
    }

    pub(crate) fn emit_terminal_scroll(&self, surface: SurfaceId, offset: u64, at_bottom: bool) {
        for placement in self.terminal_event_placements(surface) {
            self.emit(MuxEvent::ScrollChanged { surface: placement, offset, at_bottom });
        }
    }

    #[cfg(test)]
    fn emit_terminal_exited(&self, surface: SurfaceId) {
        for placement in self.terminal_event_placements(surface) {
            self.emit(MuxEvent::SurfaceExited(placement));
        }
    }

    fn emit_tree_delta(&self, delta: TreeDelta, selection_resync: bool) {
        #[cfg(test)]
        if let Some(revision) = delta.workspace_revision
            && let Some(hook) = self.workspace_delta_before_emit.lock().unwrap().clone()
        {
            hook(revision);
        }
        self.emit(MuxEvent::TreeDelta(delta));
        if selection_resync {
            self.emit(MuxEvent::TreeSelectionChanged);
        }
    }

    fn emit_committed_workspace_delta(
        &self,
        _registry: &WorkspaceRegistry,
        delta: TreeDelta,
        selection_resync: bool,
    ) {
        debug_assert!(delta.workspace_revision.is_some());
        self.emit_tree_delta(delta, selection_resync);
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

    pub(crate) fn rebuild_split_screen_index(state: &mut State) {
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
            None,
        )?;
        self.emit_terminal_registry_changed(&registry, result.1);
        Ok(result)
    }

    #[cfg(unix)]
    pub(crate) fn register_pending_terminal_host(
        self: &Arc<Self>,
        surface_id: SurfaceId,
        identity: TerminalHostIdentity,
    ) -> anyhow::Result<PendingTerminalHostBinding> {
        let registry = self.workspace_registry.lock().unwrap();
        let terminal = registry
            .terminal_record(&identity.terminal_id)?
            .ok_or_else(|| anyhow::anyhow!("pending terminal host is not registered"))?;
        match terminal.lifecycle {
            TerminalLifecycle::Launching => anyhow::ensure!(
                terminal.incarnation.is_none(),
                "launching terminal has an unexpected durable incarnation"
            ),
            TerminalLifecycle::Adopting => anyhow::ensure!(
                terminal.incarnation.as_deref() == Some(identity.incarnation.as_str()),
                "adopting terminal does not match the pending host incarnation"
            ),
            _ => anyhow::bail!("terminal is not awaiting host topology publication"),
        }
        drop(registry);

        let mut pending = self.pending_terminal_hosts.lock().unwrap();
        anyhow::ensure!(
            !pending.contains_key(&surface_id),
            "surface already has a pending terminal host"
        );
        pending.insert(surface_id, identity.clone());
        Ok(PendingTerminalHostBinding { mux: Arc::downgrade(self), surface_id, identity })
    }

    /// A hosted reader can lose and restore its admin stream before its
    /// runtime enters the topology. Accept only the exact surface and host
    /// incarnation that the launch or adoption path stored before the reader
    /// started. Registered runtimes still use the strict state checks below.
    fn pending_terminal_host_callback_matches(
        &self,
        state: &State,
        surface_id: SurfaceId,
        surface_registered: bool,
        terminal: &RegistryTerminal,
        identity: &TerminalHostIdentity,
    ) -> bool {
        let expected = self.pending_terminal_hosts.lock().unwrap().get(&surface_id).cloned();
        let Some(expected) = expected else { return false };
        !surface_registered
            && expected == *identity
            && terminal.terminal_id == expected.terminal_id
            && !state.terminal_catalog.values().any(|candidate| {
                candidate
                    .terminal_host_identity()
                    .is_some_and(|current| current.terminal_id == identity.terminal_id)
            })
            && matches!(
                terminal.lifecycle,
                TerminalLifecycle::Launching
                    | TerminalLifecycle::Adopting
                    | TerminalLifecycle::Running
            )
            && match terminal.lifecycle {
                TerminalLifecycle::Launching => terminal.incarnation.is_none(),
                TerminalLifecycle::Adopting | TerminalLifecycle::Running => {
                    terminal.incarnation.as_deref() == Some(expected.incarnation.as_str())
                }
                _ => false,
            }
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
        let Ok(Some(terminal)) = registry.terminal_record(&identity.terminal_id) else {
            return false;
        };
        let state = self.state.lock().unwrap();
        let surface =
            state.surfaces.get(&surface_id).or_else(|| state.terminal_runtime_by_id(surface_id));
        let identity_matches = surface
            .and_then(|surface| surface.terminal_host_identity())
            .is_some_and(|current| current == *identity);
        let topology_pending = self.pending_terminal_host_callback_matches(
            &state,
            surface_id,
            surface.is_some(),
            &terminal,
            identity,
        );
        drop(state);
        if topology_pending {
            return true;
        }
        if !identity_matches {
            return false;
        }
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
        self: &Arc<Self>,
        surface_id: SurfaceId,
        identity: &TerminalHostIdentity,
        applied_kitty_limits: KittyGraphicsLimits,
    ) -> bool {
        if self.shutting_down.load(Ordering::Acquire) {
            return false;
        }
        let mut registry = self.workspace_registry.lock().unwrap();
        let Ok(Some(terminal)) = registry.terminal_record(&identity.terminal_id) else {
            return false;
        };
        let state = self.state.lock().unwrap();
        let surface = state
            .surfaces
            .get(&surface_id)
            .or_else(|| state.terminal_runtime_by_id(surface_id))
            .cloned();
        let identity_matches = surface
            .as_ref()
            .and_then(|surface| surface.terminal_host_identity())
            .is_some_and(|current| current == *identity);
        let topology_pending = self.pending_terminal_host_callback_matches(
            &state,
            surface_id,
            surface.is_some(),
            &terminal,
            identity,
        );
        drop(state);
        if topology_pending {
            return true;
        }
        if !identity_matches {
            return false;
        }
        if terminal.incarnation.as_deref() != Some(identity.incarnation.as_str())
            || matches!(
                terminal.lifecycle,
                TerminalLifecycle::Exited | TerminalLifecycle::Tombstoned
            )
        {
            return false;
        }
        let lifecycle_ready = if terminal.lifecycle == TerminalLifecycle::Running {
            true
        } else {
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
        };
        drop(registry);
        if !lifecycle_ready {
            return false;
        }
        #[cfg(debug_assertions)]
        if self
            .terminal_host_reconnect_completion_failures
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |remaining| {
                (remaining > 0).then(|| remaining - 1)
            })
            .is_ok()
        {
            return false;
        }
        surface.is_some_and(|surface| {
            self.reconcile_reconnected_kitty_image_surface(&surface, applied_kitty_limits)
        })
    }

    pub(crate) fn lock_client_sizing_lifecycle(&self) -> MutexGuard<'_, ()> {
        self.client_sizing_lifecycle.lock().unwrap()
    }

    #[cfg(debug_assertions)]
    pub(crate) fn take_test_terminal_host_disconnect_after_spawn(&self) -> Option<Duration> {
        let delay_ms = self.terminal_host_test_disconnect_after_spawn_ms.swap(0, Ordering::AcqRel);
        (delay_ms > 0).then(|| Duration::from_millis(delay_ms))
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

    fn persist_terminal_cell_pixel_reconcile_failure(
        &self,
        terminal_id: &str,
        incarnation: Option<&str>,
        error: &anyhow::Error,
    ) -> anyhow::Result<()> {
        let detail = format!("{error:#}");
        eprintln!(
            "cmux-tui: terminal {terminal_id} cell-pixel reconciliation failed before \
             publication: {}",
            detail.escape_debug()
        );
        self.persist_terminal_exit(
            terminal_id,
            incarnation,
            &TerminalEnd::launch_failed("cell-pixel-reconcile-failed"),
        )
        .context("could not persist terminal exit after cell-pixel reconciliation failed")?;
        Ok(())
    }

    fn spawn_surface_with(
        self: &Arc<Self>,
        cwd: Option<String>,
        command: Option<Vec<String>>,
        size: Option<(u16, u16)>,
        workspace_key: Option<&str>,
        reservation: Option<TerminalReservationRequest>,
    ) -> anyhow::Result<Arc<Surface>> {
        let id = self.next_id();
        let reservation_env =
            reservation.as_ref().map(|reservation| reservation.env.as_slice()).unwrap_or_default();
        let (opts, cell_pixels) = self.terminal_spawn_options(cwd, command, size, reservation_env);
        #[cfg(test)]
        if let Some(hook) = self.terminal_spawn_after_cell_pixel_snapshot.lock().unwrap().clone() {
            let unlocked = match self.cell_pixel_lifecycle.try_lock() {
                Ok(lifecycle) => {
                    drop(lifecycle);
                    true
                }
                Err(_) => false,
            };
            hook(unlocked);
        }
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
            // A host launched ahead of this creation for the same reserved
            // id (`terminal_work`): adopt it instead of launching one.
            let prelaunched = self.take_prelaunched_terminal(&terminal_hex);
            let launch_spec = terminal_launch_spec(
                prelaunched.as_ref().map_or(&opts, |prelaunched| prelaunched.launch_opts()),
            );
            let terminal = RegistryTerminal {
                terminal_id: terminal_hex.clone(),
                workspace_key: workspace_key.to_string(),
                incarnation: None,
                lifecycle: TerminalLifecycle::Launching,
                launch_spec,
                exit: None,
                on_exit: reservation
                    .as_ref()
                    .map(|reservation| reservation.on_exit)
                    .unwrap_or_default(),
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
            let launched =
                prelaunched.as_ref().map_or(&opts, |prelaunched| prelaunched.launch_opts());
            self.record_terminal_relaunch(&terminal_hex, launched);
            let spawned = match prelaunched {
                Some(prelaunched) => {
                    Surface::spawn_prelaunched(prelaunched.into_host(), Arc::downgrade(self))
                }
                None => Surface::spawn_with_terminal_id_at_cell_pixels(
                    id,
                    opts,
                    Arc::downgrade(self),
                    Some(terminal_id),
                    cell_pixels,
                    // Reopen Closed of an archived terminal (ARCHIVE-1).
                    &self.terminal_respawns.take_seed(&terminal_hex).unwrap_or_default(),
                ),
            };
            let surface = match spawned {
                Ok(surface) => surface,
                Err(error) => {
                    let _ = self.persist_terminal_exit(
                        &terminal_hex,
                        None,
                        &TerminalEnd::launch_failed(format!("launch-failed: {error}")),
                    );
                    return Err(error);
                }
            };
            let _pending_host_release = PendingTerminalHostRelease(surface.clone());
            let identity = surface
                .terminal_host_identity()
                .ok_or_else(|| anyhow::anyhow!("reserved terminal did not return host identity"))?;
            if identity.terminal_id != terminal_hex {
                let _ = self.persist_terminal_exit(
                    &terminal_hex,
                    None,
                    &TerminalEnd::launch_failed("host-identity-mismatch"),
                );
                surface.kill();
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
                        surface.kill();
                        return Err(error);
                    }
                };
                self.emit_terminal_registry_changed(&registry, ready_revision);
            }
            let cell_pixel_lifecycle =
                match self.reconcile_surface_cell_pixels_for_publish(&surface) {
                    Ok(lifecycle) => lifecycle,
                    Err(error) => {
                        let persistence = self.persist_terminal_cell_pixel_reconcile_failure(
                            &terminal_hex,
                            Some(&identity.incarnation),
                            &error,
                        );
                        surface.kill();
                        persistence?;
                        return Err(error);
                    }
                };
            let insert_result =
                insert_surface_checked(&mut self.state.lock().unwrap(), surface.clone());
            drop(cell_pixel_lifecycle);
            if let Err(error) = insert_result {
                let _ = self.persist_terminal_exit(
                    &terminal_hex,
                    Some(&identity.incarnation),
                    &TerminalEnd::launch_failed("surface-insert-failed"),
                );
                surface.kill();
                return Err(error);
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
                on_exit: reservation.on_exit,
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
            self.record_terminal_relaunch(&terminal_hex, &opts);
            #[cfg(test)]
            if let Some(hook) =
                self.terminal_create_after_terminal_reservation.lock().unwrap().clone()
            {
                hook(&terminal_hex);
            }
            #[cfg(test)]
            let surface_result = if self.test_surface_runtime {
                Surface::spawn_for_test_at_cell_pixels(id, opts, Arc::downgrade(self), cell_pixels)
            } else {
                Surface::spawn_at_cell_pixels(id, opts, Arc::downgrade(self), cell_pixels)
            };
            #[cfg(not(test))]
            let surface_result =
                Surface::spawn_at_cell_pixels(id, opts, Arc::downgrade(self), cell_pixels);
            let surface = match surface_result {
                Ok(surface) => surface,
                Err(error) => {
                    let _ = self.persist_terminal_exit(
                        &terminal_hex,
                        None,
                        &TerminalEnd::launch_failed(format!("launch-failed: {error}")),
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
                        surface.kill();
                        return Err(error);
                    }
                };
                self.emit_terminal_registry_changed(&registry, revision);
            }
            #[cfg(test)]
            if let Some(hook) =
                self.terminal_spawn_before_cell_pixel_reconcile.lock().unwrap().clone()
            {
                hook(&surface);
            }
            let cell_pixel_lifecycle =
                match self.reconcile_surface_cell_pixels_for_publish(&surface) {
                    Ok(lifecycle) => lifecycle,
                    Err(error) => {
                        let persistence = self.persist_terminal_cell_pixel_reconcile_failure(
                            &terminal_hex,
                            Some(&incarnation),
                            &error,
                        );
                        surface.kill();
                        persistence?;
                        return Err(error);
                    }
                };
            let insert_result =
                insert_surface_checked(&mut self.state.lock().unwrap(), surface.clone());
            drop(cell_pixel_lifecycle);
            if let Err(error) = insert_result {
                let _ = self.persist_terminal_exit(
                    &terminal_hex,
                    Some(&incarnation),
                    &TerminalEnd::launch_failed("surface-insert-failed"),
                );
                surface.kill();
                return Err(error);
            }
            self.reserved_in_process_terminals.lock().unwrap().insert(surface.id, identity);
            return Ok(surface);
        }
        #[cfg(test)]
        let surface_result = if self.test_surface_runtime {
            Surface::spawn_for_test_at_cell_pixels(id, opts, Arc::downgrade(self), cell_pixels)
        } else {
            Surface::spawn_at_cell_pixels(id, opts, Arc::downgrade(self), cell_pixels)
        };
        #[cfg(not(test))]
        let surface_result =
            Surface::spawn_at_cell_pixels(id, opts, Arc::downgrade(self), cell_pixels);
        let surface = match surface_result {
            Ok(surface) => surface,
            Err(error) => {
                self.pending_workspace_surfaces.lock().unwrap().remove(&id);
                return Err(error);
            }
        };
        let cell_pixel_lifecycle = match self.reconcile_surface_cell_pixels_for_publish(&surface) {
            Ok(lifecycle) => lifecycle,
            Err(error) => {
                self.pending_workspace_surfaces.lock().unwrap().remove(&id);
                surface.kill();
                return Err(error);
            }
        };
        let insert_result =
            insert_surface_checked(&mut self.state.lock().unwrap(), surface.clone());
        drop(cell_pixel_lifecycle);
        if let Err(error) = insert_result {
            self.pending_workspace_surfaces.lock().unwrap().remove(&id);
            surface.kill();
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
        let id = self.next_id();
        let mut opts = self.surface_options.lock().unwrap().clone();
        opts.command = Some(options.command.clone());
        opts.cwd = options.cwd.clone();
        opts.cols = size.0.max(1);
        opts.rows = size.1.max(1);
        opts.extra_env.push(("CMUX_SIDEBAR".to_string(), "1".to_string()));
        let cell_pixels = {
            let cell_pixel_lifecycle = self.cell_pixel_lifecycle.lock().unwrap();
            let cell_pixels = self.cell_pixel_creation_size();
            drop(cell_pixel_lifecycle);
            cell_pixels
        };
        #[cfg(test)]
        let surface = if self.test_surface_runtime {
            Surface::spawn_auxiliary_for_test_at_cell_pixels(
                id,
                opts,
                Arc::downgrade(self),
                cell_pixels,
            )?
        } else {
            Surface::spawn_auxiliary_at_cell_pixels(id, opts, Arc::downgrade(self), cell_pixels)?
        };
        #[cfg(not(test))]
        let surface =
            Surface::spawn_auxiliary_at_cell_pixels(id, opts, Arc::downgrade(self), cell_pixels)?;
        let cell_pixel_lifecycle = match self.reconcile_surface_cell_pixels_for_publish(&surface) {
            Ok(lifecycle) => lifecycle,
            Err(error) => {
                surface.kill();
                return Err(error);
            }
        };
        let insert_result =
            insert_surface_checked(&mut self.state.lock().unwrap(), surface.clone());
        drop(cell_pixel_lifecycle);
        if let Err(error) = insert_result {
            surface.kill();
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
        let _cell_pixel_lifecycle = self.cell_pixel_lifecycle.lock().unwrap();
        let id = self.next_id();
        if let Some(workspace) = pending_workspace {
            self.pending_workspace_surfaces.lock().unwrap().insert(id, workspace);
        }
        let opts = self.surface_options.lock().unwrap().clone();
        let size = self.resolve_client_size(size, (opts.cols, opts.rows));
        let cell_pixels = self.cell_pixel_creation_size();
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
        insert_surface_checked(&mut self.state.lock().unwrap(), surface.clone())?;
        let tab_id = surface
            .resource_identity()
            .context("browser surface omitted its public tab identity")?
            .tab_id
            .clone();
        self.start_browser_bootstrap(
            surface.clone(),
            BrowserBootstrap::Provider { tab_id, url },
            None,
        );
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

    /// Record one viewer's available grid. A terminal report feeds the shared
    /// sizing engine and changes the PTY only when the engine's policy lets
    /// it; browser surfaces retain their existing shared-size reducer.
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
        let terminal_runtime = self.surface(id).and_then(|surface| surface.terminal_runtime_id());
        // Serialize the report and its application. Otherwise an older
        // effective size can reach the PTY after a newer shared minimum.
        let mut sizing = self.client_sizing.lock().unwrap();
        let attached_clients = self.control_clients.attached_client_ids_for_surface(id);
        let result = self.resize_surface_for_client_locked(
            &mut sizing,
            Some(&attached_clients),
            ClientResizeRequest {
                surface: id,
                client,
                requested,
                completion: None,
                terminal_runtime,
            },
        )?;
        sizing.note_applied_report(
            id,
            client,
            &attached_clients,
            result.1,
            result.2.applied_report_order,
        );
        drop(sizing);
        self.publish_size_states();
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
        let _lifecycle = self.lock_client_sizing_lifecycle();
        anyhow::ensure!(
            !self.control_clients.surface_attachment_is_retired_without_current(client, id),
            "surface {id} attachment was superseded"
        );
        let requested = clamp_terminal_size(cols, rows);
        let terminal_runtime = self.surface(id).and_then(|surface| surface.terminal_runtime_id());
        // Keep registration, report insertion, and reducer insertion in one
        // critical section. Disconnect and final stream detach remove their
        // leases through this same sizing lock after dropping the registry lock.
        let mut sizing = self.client_sizing.lock().unwrap();
        let attached = self.control_clients.record_size(client, id, requested.0, requested.1)?;
        let result = self.resize_surface_for_prepared_control_client_locked(
            &mut sizing,
            PreparedControlClientResize {
                request: ClientResizeRequest {
                    surface: id,
                    client,
                    requested,
                    completion,
                    terminal_runtime,
                },
                attached: attached.clone(),
            },
        );
        if result.is_err()
            && let Some((_, _, _, previous)) = attached.as_ref()
        {
            self.control_clients.restore_size(client, id, *previous);
        }
        drop(sizing);
        self.publish_size_states();
        result
    }

    pub(crate) fn resize_surface_for_prepared_control_client_with_completion(
        &self,
        id: SurfaceId,
        client: u64,
        requested: (u16, u16),
        completion: Option<SurfaceResizeCompletion>,
        attached: Option<crate::server::ClientSizeUpdate>,
    ) -> anyhow::Result<ControlClientResize> {
        let requested = clamp_terminal_size(requested.0, requested.1);
        let terminal_runtime = self.surface(id).and_then(|surface| surface.terminal_runtime_id());
        let mut sizing = self.client_sizing.lock().unwrap();
        let result = self.resize_surface_for_prepared_control_client_locked(
            &mut sizing,
            PreparedControlClientResize {
                request: ClientResizeRequest {
                    surface: id,
                    client,
                    requested,
                    completion,
                    terminal_runtime,
                },
                attached,
            },
        );
        drop(sizing);
        self.publish_size_states();
        result
    }

    fn resize_surface_for_prepared_control_client_locked(
        &self,
        sizing: &mut ClientSizingState,
        prepared: PreparedControlClientResize,
    ) -> anyhow::Result<ControlClientResize> {
        let PreparedControlClientResize { request, attached } = prepared;
        let id = request.surface;
        let client = request.client;
        let attached_clients = self.control_clients.attached_client_ids_for_surface(id);
        let result =
            self.resize_surface_for_client_locked(sizing, Some(&attached_clients), request);
        let result = result?;
        self.control_clients.set_report_order(client, id, result.2.applied_report_order);
        sizing.note_applied_report(
            id,
            client,
            &attached_clients,
            result.1,
            result.2.applied_report_order,
        );
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
        request: ClientResizeRequest,
    ) -> anyhow::Result<AppliedClientSize> {
        let ClientResizeRequest { surface: id, client, requested, completion, terminal_runtime } =
            request;
        let previous_geometry = self.surface(id).map(|surface| surface.size());
        if terminal_runtime.is_none()
            && sizing
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
        if let Some(runtime) = terminal_runtime {
            sizing.terminal_runtime_by_placement.insert(id, runtime);
            self.sync_terminal_view_locked(sizing, runtime, id, client);
            let authoritative = sizing.owns_terminal_geometry(runtime, id, client);
            if !authoritative {
                // The report may still move the grid through another owner,
                // for example when it stops being the smallest viewport.
                self.apply_terminal_grid(sizing, runtime);
                return Ok((
                    (false, None),
                    previous_geometry,
                    ClientSizeRollback {
                        previous_size: previous,
                        previous_report_order: previous_order,
                        previous_geometry,
                        applied_report_order: report_order,
                    },
                ));
            }
            let (target, applied) =
                sizing.terminal_sizing.get(&runtime).map_or((requested, None), |entry| {
                    ((entry.engine.state().cols, entry.engine.state().rows), Some(&entry.applied))
                });
            if applied.is_some_and(|applied| applied.get() == Some(target))
                || previous_geometry == Some(target)
            {
                // The owner's decision is already in effect. Re-applying it
                // would override a resize this engine did not make.
                if let Some(applied) = applied {
                    applied.set(Some(target));
                }
                return Ok((
                    (false, None),
                    Some(target),
                    ClientSizeRollback {
                        previous_size: previous,
                        previous_report_order: previous_order,
                        previous_geometry,
                        applied_report_order: report_order,
                    },
                ));
            }
            if let Some(applied) = applied {
                applied.set(Some(target));
            }
            return match self.resize_surface_with_completion(id, target.0, target.1, completion) {
                Ok(changed) => Ok((
                    changed,
                    Some(target),
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
                    }
                    if sizing.surfaces.get(&id).is_some_and(HashMap::is_empty) {
                        sizing.surfaces.remove(&id);
                        sizing.terminal_runtime_by_placement.remove(&id);
                    }
                    match previous_order {
                        Some(order) => {
                            sizing.report_order.insert((id, client), order);
                        }
                        None => {
                            sizing.report_order.remove(&(id, client));
                        }
                    }
                    if let Some(entry) = sizing.terminal_sizing.get(&runtime) {
                        entry.applied.set(previous_geometry);
                    }
                    self.sync_terminal_view_locked(sizing, runtime, id, client);
                    Err(error)
                }
            };
        }
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
        let terminal_runtime = self.surface(id).and_then(|surface| surface.terminal_runtime_id());
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
        if let Some(runtime) = terminal_runtime {
            let owned_geometry = sizing.owns_terminal_geometry(runtime, id, client);
            self.sync_terminal_view_locked(&mut sizing, runtime, id, client);
            self.apply_terminal_grid(&sizing, runtime);
            // A failed first attach whose provisional report owned the grid
            // restores the preceding geometry when nobody else can take over.
            let held = sizing
                .terminal_sizing
                .get(&runtime)
                .is_some_and(|entry| entry.engine.state().reason == TerminalSizingReason::Held);
            let desired_geometry = (owned_geometry && held)
                .then_some(rollback.previous_size.or(rollback.previous_geometry))
                .flatten();
            drop(sizing);
            drop(lifecycle);
            if let Some((cols, rows)) = desired_geometry {
                let _ = self.resize_surface(id, cols, rows);
            }
            self.publish_size_states();
            return;
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
        if let Some(runtime) =
            self.surface(surface_id).and_then(|surface| surface.terminal_runtime_id())
        {
            self.apply_terminal_grid(sizing, runtime);
            return;
        }
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
        let terminal_runtime = self.surface(id).and_then(|surface| surface.terminal_runtime_id());
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
                sizing.terminal_runtime_by_placement.remove(&id);
            }
            removed
        };
        sizing.report_order.remove(&(id, client));
        if let Some(runtime) = terminal_runtime {
            let owners_before = sizing.terminal_owner_clients(runtime);
            // A released view keeps its participant while its stream stays
            // attached; a final detach removes it and elects the next owner.
            self.sync_terminal_view_locked(&mut sizing, runtime, id, client);
            self.apply_terminal_grid(&sizing, runtime);
            let owners_after = sizing.terminal_owner_clients(runtime);
            drop(sizing);
            self.publish_size_states();
            self.emit_client_sizing_changes(
                owners_before.symmetric_difference(&owners_after).copied(),
            );
            return;
        }
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
        sizing.detached_views.retain(|(viewer, _)| *viewer != client);
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
        let reported_placements = sizing.surfaces.keys().copied().collect::<HashSet<_>>();
        sizing
            .terminal_runtime_by_placement
            .retain(|surface, _| reported_placements.contains(surface));
        sizing.report_order.retain(|(surface, reporter), _| {
            if *reporter != client {
                return true;
            }
            affected.insert(*surface);
            false
        });
        // Drop every view and relay sub-view of the departed client. Each
        // engine elects its next owner in the same step, so the grid follows
        // the remaining viewers instead of freezing.
        let runtimes = sizing.terminal_sizing.keys().copied().collect::<Vec<_>>();
        let mut owner_changes = HashSet::new();
        for runtime in runtimes {
            let owners_before = sizing.terminal_owner_clients(runtime);
            let Some(entry) = sizing.terminal_sizing.get_mut(&runtime) else { continue };
            let departed = entry
                .members
                .iter()
                .filter(|(_, member)| member.client == client)
                .map(|(id, _)| id.clone())
                .collect::<Vec<_>>();
            if departed.is_empty() {
                continue;
            }
            let mut changed = false;
            for id in departed {
                entry.members.remove(&id);
                changed |= entry.engine.detach(&id);
            }
            sizing.note_size_state(runtime, changed);
            self.apply_terminal_grid(&sizing, runtime);
            let owners_after = sizing.terminal_owner_clients(runtime);
            owner_changes.extend(owners_before.symmetric_difference(&owners_after).copied());
        }
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
        changed_clients.extend(owner_changes);
        changed_clients.remove(&client);
        self.apply_effective_client_sizes(&sizing, affected, &attached_clients);
        drop(sizing);
        self.publish_size_states();
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

    /// Activity by one client view: attach, explicit focus-click, or keyboard,
    /// paste or mouse input. Under the default `latest` policy the view takes
    /// the grid when it has reported a viewport. Returns whether the
    /// published size state changed.
    pub fn claim_terminal_geometry(&self, surface: SurfaceId, client: u64) -> Option<bool> {
        let _lifecycle = self.lock_client_sizing_lifecycle();
        let runtime = self.surface(surface)?.terminal_runtime_id()?;
        if client != 0 && !self.control_clients.contains(client) {
            return None;
        }
        Some(self.mutate_terminal_sizing(runtime, |mux, sizing| {
            if sizing.detached_views.contains(&(client, surface)) {
                return false;
            }
            sizing.terminal_runtime_by_placement.insert(surface, runtime);
            let id = view_participant_id(runtime, surface, client);
            let participant = mux.view_participant(sizing, runtime, surface, client);
            let entry = mux.terminal_sizing_entry(sizing, runtime, surface);
            entry
                .members
                .insert(id.clone(), SizingMember { client, placement: surface, view: None });
            let changed = if entry.engine.contains(&id) {
                entry.engine.note_activity(&id)
            } else {
                entry.engine.attach(participant)
            };
            sizing.note_size_state(runtime, changed);
            changed
        }))
    }

    /// Keyboard, paste or mouse input from an attached client. Unlike
    /// [`Self::claim_terminal_geometry`] it never adds a participant, so a
    /// one-shot `send` from an unattached connection cannot take the grid.
    pub(crate) fn note_terminal_input(&self, surface: SurfaceId, client: u64) {
        if self.note_terminal_activity(surface, client, None).is_some() {
            self.activity.note_user_input();
        }
    }

    /// Activity of the caller's own view (`view:None`) or of one of its relay
    /// sub-views, for example a phone whose input a Mac mirror forwards.
    /// `None` means the terminal or participant does not exist; otherwise
    /// whether the published size state changed.
    pub(crate) fn note_terminal_activity(
        &self,
        surface: SurfaceId,
        client: u64,
        view: Option<&str>,
    ) -> Option<bool> {
        let runtime = self.surface(surface)?.terminal_runtime_id()?;
        let id = match view {
            Some(view) => sub_view_participant_id(client, view),
            None => view_participant_id(runtime, surface, client),
        };
        self.mutate_terminal_sizing(runtime, |_, sizing| {
            let entry = sizing.terminal_sizing.get_mut(&runtime)?;
            if entry.members.get(&id).is_none_or(|member| member.client != client) {
                return None;
            }
            let changed = entry.engine.note_activity(&id);
            sizing.note_size_state(runtime, changed);
            Some(changed)
        })
    }

    /// Restore the automatic counts rule for every view of this terminal.
    /// This is the terminal meaning of the legacy "use all client sizes".
    pub fn release_terminal_geometry(&self, surface: SurfaceId) -> Option<bool> {
        let _lifecycle = self.lock_client_sizing_lifecycle();
        let runtime = self.surface(surface)?.terminal_runtime_id()?;
        Some(self.mutate_terminal_sizing(runtime, |_, sizing| {
            let Some(entry) = sizing.terminal_sizing.get_mut(&runtime) else { return false };
            let ids = entry.engine.participant_ids().map(str::to_owned).collect::<Vec<_>>();
            let mut changed = false;
            for id in ids {
                if entry.engine.participant(&id).is_some_and(|p| p.counts_override.is_some()) {
                    changed |= entry.engine.set_counts_override(&id, None);
                }
            }
            sizing.note_size_state(runtime, changed);
            changed
        }))
    }

    /// Mirror a client view's attachment and latest report into the sizing
    /// engine after an attach commits. Idempotent.
    pub(crate) fn sync_terminal_client_view(&self, surface: SurfaceId, client: u64) {
        let Some(runtime) = self.surface(surface).and_then(|surface| surface.terminal_runtime_id())
        else {
            return;
        };
        self.mutate_terminal_sizing(runtime, |mux, sizing| {
            mux.sync_terminal_view_locked(sizing, runtime, surface, client);
        });
    }

    /// Push a client's changed identity into every engine it participates in.
    pub(crate) fn refresh_terminal_client_identity(&self, client: u64) {
        let mut sizing = self.client_sizing.lock().unwrap();
        let identity = self.client_sizing_identity(client);
        let runtimes = sizing.terminal_sizing.keys().copied().collect::<Vec<_>>();
        for runtime in runtimes {
            let Some(entry) = sizing.terminal_sizing.get_mut(&runtime) else { continue };
            let views = entry
                .members
                .iter()
                .filter(|(_, member)| member.client == client && member.view.is_none())
                .map(|(id, _)| id.clone())
                .collect::<Vec<_>>();
            let mut changed = false;
            for id in views {
                let mut participant = TerminalSizingParticipant::new(id, identity.device_kind);
                participant.user_id = identity.user_id.clone();
                participant.display_name = identity.display_name.clone();
                participant.device_name = identity.device_name.clone();
                participant.device_id = identity.device_id.clone();
                changed |= entry.engine.update_identity(&participant);
            }
            sizing.note_size_state(runtime, changed);
            // The same-user handheld rule may change who counts.
            self.apply_terminal_grid(&sizing, runtime);
        }
        drop(sizing);
        self.publish_size_states();
    }

    /// Create or update one relay sub-view (for example a phone behind a Mac
    /// mirror) and record its viewport. Returns the host participant id and
    /// whether the view now sets a dimension of the grid.
    pub(crate) fn report_terminal_sub_view(
        &self,
        surface: SurfaceId,
        client: u64,
        view: &str,
        identity: Option<ClientSizingIdentity>,
        viewport: Option<(u16, u16)>,
    ) -> anyhow::Result<(String, bool)> {
        let runtime = self
            .surface(surface)
            .ok_or_else(|| anyhow::anyhow!("unknown surface {surface}"))?
            .terminal_runtime_id()
            .ok_or_else(|| anyhow::anyhow!("relay views are supported only for terminals"))?;
        anyhow::ensure!(
            self.control_clients.attached_client_ids_for_surface(surface).contains(&client),
            "relay views require an attached relay connection for surface {surface}"
        );
        let id = sub_view_participant_id(client, view);
        let via = view_participant_id(runtime, surface, client);
        let owns = self.mutate_terminal_sizing(runtime, |mux, sizing| {
            let entry = mux.terminal_sizing_entry(sizing, runtime, surface);
            entry.members.insert(
                id.clone(),
                SizingMember { client, placement: surface, view: Some(view.to_string()) },
            );
            let has_identity = identity.is_some();
            let identity = identity.unwrap_or_default();
            let participant = TerminalSizingParticipant {
                id: id.clone(),
                user_id: identity.user_id,
                display_name: identity.display_name,
                device_kind: identity.device_kind,
                device_name: identity.device_name,
                device_id: identity.device_id,
                via: Some(via),
                viewport: viewport.map(|(cols, rows)| TerminalGridSize::new(cols, rows)),
                counts_override: None,
            };
            let changed = if entry.engine.contains(&id) {
                let mut changed = has_identity && entry.engine.update_identity(&participant);
                changed |= match participant.viewport {
                    Some(viewport) => entry.engine.report(&id, viewport),
                    None => false,
                };
                changed
            } else {
                entry.engine.attach(participant)
            };
            sizing.note_size_state(runtime, changed);
            entry_owns(sizing, runtime, &id)
        });
        Ok((id, owns))
    }

    /// Forget one relay sub-view's viewport and keep it attached.
    pub(crate) fn release_terminal_sub_view(
        &self,
        surface: SurfaceId,
        client: u64,
        view: &str,
    ) -> Option<bool> {
        let runtime = self.surface(surface)?.terminal_runtime_id()?;
        let id = sub_view_participant_id(client, view);
        self.mutate_terminal_sizing(runtime, |_, sizing| {
            let entry = sizing.terminal_sizing.get_mut(&runtime)?;
            if entry.members.get(&id).is_none_or(|member| member.client != client) {
                return None;
            }
            let changed = entry.engine.clear_viewport(&id);
            sizing.note_size_state(runtime, changed);
            Some(changed)
        })
    }

    /// Remove one relay sub-view. The next owner takes the grid.
    pub(crate) fn detach_terminal_sub_view(
        &self,
        surface: SurfaceId,
        client: u64,
        view: &str,
    ) -> Option<bool> {
        let runtime = self.surface(surface)?.terminal_runtime_id()?;
        let id = sub_view_participant_id(client, view);
        self.mutate_terminal_sizing(runtime, |_, sizing| {
            let entry = sizing.terminal_sizing.get_mut(&runtime)?;
            if entry.members.get(&id).is_none_or(|member| member.client != client) {
                return None;
            }
            entry.members.remove(&id);
            let changed = entry.engine.detach(&id);
            sizing.note_size_state(runtime, changed);
            Some(changed)
        })
    }

    /// Resolve a host participant id on any terminal to its connection,
    /// placement and relay sub-view name.
    pub(crate) fn terminal_participant_member(
        &self,
        participant: &str,
    ) -> Option<(u64, SurfaceId, Option<String>)> {
        let sizing = self.client_sizing.lock().unwrap();
        sizing.terminal_sizing.values().find_map(|entry| {
            entry
                .members
                .get(participant)
                .map(|member| (member.client, member.placement, member.view.clone()))
        })
    }

    /// Resolve a host participant id on one terminal (participant ids are
    /// per terminal, so the same `c<client>` can name views of several).
    pub(crate) fn terminal_participant_member_on(
        &self,
        surface: SurfaceId,
        participant: &str,
    ) -> Option<(u64, SurfaceId, Option<String>)> {
        let runtime = self.surface(surface)?.terminal_runtime_id()?;
        let sizing = self.client_sizing.lock().unwrap();
        sizing
            .terminal_sizing
            .get(&runtime)?
            .members
            .get(participant)
            .map(|member| (member.client, member.placement, member.view.clone()))
    }

    /// Detach one connection's own view of a terminal placement, keeping the
    /// connection, its stream and its relay sub-views. The view stays out of
    /// the engine until [`Self::reattach_terminal_own_view`].
    pub(crate) fn detach_terminal_own_view(
        &self,
        placement: SurfaceId,
        client: u64,
    ) -> Option<bool> {
        let _lifecycle = self.lock_client_sizing_lifecycle();
        let runtime = self.surface(placement)?.terminal_runtime_id()?;
        Some(self.mutate_terminal_sizing(runtime, |mux, sizing| {
            sizing.detached_views.insert((client, placement));
            let before =
                sizing.terminal_sizing.get(&runtime).map(|entry| entry.engine.state().generation);
            mux.sync_terminal_view_locked(sizing, runtime, placement, client);
            before
                != sizing.terminal_sizing.get(&runtime).map(|entry| entry.engine.state().generation)
        }))
    }

    /// Restore a view detached by [`Self::detach_terminal_own_view`], with
    /// its latest report. `counts` sets its counts override (a viewer
    /// reattaches with `Some(false)`). Returns the view's participant id.
    pub(crate) fn reattach_terminal_own_view(
        &self,
        placement: SurfaceId,
        client: u64,
        counts: Option<bool>,
    ) -> anyhow::Result<String> {
        let _lifecycle = self.lock_client_sizing_lifecycle();
        let runtime = self
            .surface(placement)
            .and_then(|surface| surface.terminal_runtime_id())
            .ok_or_else(|| anyhow::anyhow!("surface {placement} is not a terminal"))?;
        let id = view_participant_id(runtime, placement, client);
        self.mutate_terminal_sizing(runtime, |mux, sizing| {
            anyhow::ensure!(
                sizing.detached_views.remove(&(client, placement)),
                "view of surface {placement} is not detached"
            );
            mux.sync_terminal_view_locked(sizing, runtime, placement, client);
            if let Some(entry) = sizing.terminal_sizing.get_mut(&runtime)
                && entry.engine.contains(&id)
                && counts.is_some()
            {
                let changed = entry.engine.set_counts_override(&id, counts);
                sizing.note_size_state(runtime, changed);
            }
            Ok(id.clone())
        })
    }

    /// Set or clear one participant's explicit counts choice.
    pub fn set_terminal_size_counts(
        &self,
        surface: SurfaceId,
        participant: &str,
        counts: Option<bool>,
    ) -> Option<bool> {
        let runtime = self.surface(surface)?.terminal_runtime_id()?;
        self.mutate_terminal_sizing(runtime, |_, sizing| {
            let entry = sizing.terminal_sizing.get_mut(&runtime)?;
            if !entry.engine.contains(participant) {
                return None;
            }
            let changed = entry.engine.set_counts_override(participant, counts);
            sizing.note_size_state(runtime, changed);
            Some(changed)
        })
    }

    /// Set (`Some`) or clear (`None`) a terminal's policy override.
    pub fn set_terminal_size_policy(
        &self,
        surface: SurfaceId,
        policy: Option<TerminalSizingPolicy>,
    ) -> Option<TerminalSizingState> {
        let runtime = self.surface(surface)?.terminal_runtime_id()?;
        Some(self.mutate_terminal_sizing(runtime, |mux, sizing| {
            match policy {
                Some(policy) => sizing.terminal_size_policies.insert(runtime, policy),
                None => sizing.terminal_size_policies.remove(&runtime),
            };
            let resolved = mux.resolved_size_policy(sizing, runtime, surface);
            let entry = mux.terminal_sizing_entry(sizing, runtime, surface);
            let changed = entry.engine.set_policy(resolved);
            sizing.note_size_state(runtime, changed);
            sizing.terminal_sizing[&runtime].engine.state().clone()
        }))
    }

    /// Pins the `latest` policy on the workspace that shows `surface`, for
    /// tests about latest-activity semantics (the default is `smallest`).
    #[cfg(test)]
    pub(crate) fn pin_latest_size_policy_for_test(&self, surface: SurfaceId) {
        let workspace = self.surface_workspace(surface).expect("surface has a workspace");
        self.set_workspace_size_policy(
            workspace,
            Some(TerminalSizingPolicy::new(
                crate::sizing_policy::TerminalSizingMode::Latest,
                Vec::new(),
                None,
            )),
        )
        .expect("pin latest size policy");
    }

    /// Set (`Some`) or clear (`None`) a workspace's default policy and apply
    /// it to every live terminal in that workspace without an override.
    pub(crate) fn set_workspace_size_policy(
        &self,
        workspace: WorkspaceId,
        policy: Option<TerminalSizingPolicy>,
    ) -> anyhow::Result<()> {
        anyhow::ensure!(
            self.with_state(|state| state.workspaces.iter().any(|w| w.id == workspace)),
            "unknown workspace {workspace}"
        );
        let mut sizing = self.client_sizing.lock().unwrap();
        match policy {
            Some(policy) => sizing.workspace_size_policies.insert(workspace, policy),
            None => sizing.workspace_size_policies.remove(&workspace),
        };
        let affected = sizing
            .terminal_sizing
            .iter()
            .filter(|(runtime, _)| !sizing.terminal_size_policies.contains_key(runtime))
            .filter_map(|(runtime, entry)| {
                let placement = entry.placements.iter().next().copied().unwrap_or(*runtime);
                (self.surface_workspace(placement) == Some(workspace))
                    .then_some((*runtime, placement))
            })
            .collect::<Vec<_>>();
        let mut owner_changes = HashSet::new();
        for (runtime, placement) in affected {
            let owners_before = sizing.terminal_owner_clients(runtime);
            let resolved = self.resolved_size_policy(&sizing, runtime, placement);
            let Some(entry) = sizing.terminal_sizing.get_mut(&runtime) else { continue };
            let changed = entry.engine.set_policy(resolved);
            sizing.note_size_state(runtime, changed);
            self.apply_terminal_grid(&sizing, runtime);
            owner_changes.extend(
                owners_before
                    .symmetric_difference(&sizing.terminal_owner_clients(runtime))
                    .copied(),
            );
        }
        drop(sizing);
        self.publish_size_states();
        self.emit_client_sizing_changes(owner_changes);
        Ok(())
    }

    /// The terminal's published size state, creating its engine on demand.
    pub fn terminal_size_state(&self, surface: SurfaceId) -> Option<TerminalSizingState> {
        let runtime = self.surface(surface)?.terminal_runtime_id()?;
        let mut sizing = self.client_sizing.lock().unwrap();
        Some(self.terminal_sizing_entry(&mut sizing, runtime, surface).engine.state().clone())
    }

    /// The host participant id of `client`'s own view of `surface`.
    pub fn terminal_view_participant_id(&self, surface: SurfaceId, client: u64) -> Option<String> {
        let runtime = self.surface(surface)?.terminal_runtime_id()?;
        Some(view_participant_id(runtime, surface, client))
    }

    fn client_sizing_identity(&self, client: u64) -> ClientSizingIdentity {
        if client == 0 {
            // The in-process frontend, named after its host like a remote TUI.
            static DEVICE_NAME: OnceLock<String> = OnceLock::new();
            let device_name = DEVICE_NAME.get_or_init(|| {
                crate::platform::local_hostname().unwrap_or_else(|| "cmux-tui".to_string())
            });
            return ClientSizingIdentity {
                device_kind: TerminalDeviceKind::Tui,
                device_name: Some(device_name.clone()),
                ..ClientSizingIdentity::default()
            };
        }
        self.control_clients.sizing_identity(client).unwrap_or_default()
    }

    fn view_participant(
        &self,
        sizing: &ClientSizingState,
        runtime: SurfaceId,
        placement: SurfaceId,
        client: u64,
    ) -> TerminalSizingParticipant {
        let identity = self.client_sizing_identity(client);
        TerminalSizingParticipant {
            id: view_participant_id(runtime, placement, client),
            user_id: identity.user_id,
            display_name: identity.display_name,
            device_kind: identity.device_kind,
            device_name: identity.device_name,
            device_id: identity.device_id,
            via: None,
            viewport: sizing
                .surfaces
                .get(&placement)
                .and_then(|viewers| viewers.get(&client))
                .map(|&(cols, rows)| TerminalGridSize::new(cols, rows)),
            counts_override: None,
        }
    }

    fn resolved_size_policy(
        &self,
        sizing: &ClientSizingState,
        runtime: SurfaceId,
        placement: SurfaceId,
    ) -> TerminalSizingPolicy {
        if let Some(policy) = sizing.terminal_size_policies.get(&runtime) {
            return policy.clone();
        }
        self.surface_workspace(placement)
            .and_then(|workspace| sizing.workspace_size_policies.get(&workspace).cloned())
            .unwrap_or_default()
    }

    fn terminal_sizing_entry<'a>(
        &self,
        sizing: &'a mut ClientSizingState,
        runtime: SurfaceId,
        placement: SurfaceId,
    ) -> &'a mut TerminalSizingEntry {
        if !sizing.terminal_sizing.contains_key(&runtime) {
            let (cols, rows) = self
                .surface(placement)
                .or_else(|| self.surface(runtime))
                .map_or((80, 24), |surface| surface.size());
            let policy = self.resolved_size_policy(sizing, runtime, placement);
            sizing.terminal_sizing.insert(
                runtime,
                TerminalSizingEntry {
                    engine: TerminalSizingEngine::new(TerminalGridSize::new(cols, rows), policy),
                    placements: BTreeSet::new(),
                    members: HashMap::new(),
                    applied: std::cell::Cell::new(None),
                },
            );
        }
        let entry = sizing.terminal_sizing.get_mut(&runtime).expect("inserted above");
        entry.placements.insert(placement);
        entry
    }

    /// Mirror one client view's attachment and latest report into the
    /// engine. A view is present while its connection is attached to the
    /// placement or while it has a retained report.
    fn sync_terminal_view_locked(
        &self,
        sizing: &mut ClientSizingState,
        runtime: SurfaceId,
        placement: SurfaceId,
        client: u64,
    ) {
        let id = view_participant_id(runtime, placement, client);
        let has_report =
            sizing.surfaces.get(&placement).is_some_and(|viewers| viewers.contains_key(&client));
        let attached = client != 0
            && self.control_clients.attached_client_ids_for_surface(placement).contains(&client);
        let present =
            (attached || has_report) && !sizing.detached_views.contains(&(client, placement));
        let known =
            sizing.terminal_sizing.get(&runtime).is_some_and(|entry| entry.engine.contains(&id));
        if !present && !known {
            return;
        }
        let participant =
            present.then(|| self.view_participant(sizing, runtime, placement, client));
        let entry = self.terminal_sizing_entry(sizing, runtime, placement);
        let changed = match participant {
            None => {
                entry.members.remove(&id);
                entry.engine.detach(&id)
            }
            Some(participant) => {
                entry.members.insert(id.clone(), SizingMember { client, placement, view: None });
                let viewport = participant.viewport.map(TerminalGridSize::clamped);
                match entry.engine.participant(&id).map(|current| current.viewport) {
                    None => entry.engine.attach(participant),
                    Some(current) if current == viewport => false,
                    Some(_) => match viewport {
                        Some(viewport) => entry.engine.report(&id, viewport),
                        None => entry.engine.clear_viewport(&id),
                    },
                }
            }
        };
        sizing.note_size_state(runtime, changed);
    }

    /// Resize the PTY to the engine's decision when that decision changed.
    /// A held grid is left alone.
    fn apply_terminal_grid(&self, sizing: &ClientSizingState, runtime: SurfaceId) {
        let Some(entry) = sizing.terminal_sizing.get(&runtime) else { return };
        let state = entry.engine.state();
        if state.reason == TerminalSizingReason::Held
            || entry.applied.get() == Some((state.cols, state.rows))
        {
            return;
        }
        entry.applied.set(Some((state.cols, state.rows)));
        let Some(surface) = entry
            .placements
            .iter()
            .find_map(|placement| self.surface(*placement))
            .or_else(|| self.surface(runtime))
        else {
            return;
        };
        if surface.size() != (state.cols, state.rows) {
            let _ = self.resize_surface(surface.id, state.cols, state.rows);
        }
    }

    /// Run one engine mutation, apply the resulting grid, then publish size
    /// state and client ownership changes after the sizing lock is released.
    fn mutate_terminal_sizing<R>(
        &self,
        runtime: SurfaceId,
        mutate: impl FnOnce(&Self, &mut ClientSizingState) -> R,
    ) -> R {
        let mut sizing = self.client_sizing.lock().unwrap();
        let owners_before = sizing.terminal_owner_clients(runtime);
        let result = mutate(self, &mut sizing);
        self.apply_terminal_grid(&sizing, runtime);
        let owners_after = sizing.terminal_owner_clients(runtime);
        drop(sizing);
        self.publish_size_states();
        self.emit_client_sizing_changes(owners_before.symmetric_difference(&owners_after).copied());
        result
    }

    /// Deliver pending size states to subscribers and attach streams. Call
    /// only without the sizing lock held.
    fn publish_size_states(&self) {
        let publications = self.client_sizing.lock().unwrap().take_size_state_publications();
        for publication in publications {
            for placement in publication.placements {
                if self.surface(placement).is_none() {
                    continue;
                }
                self.control_clients.send_size_state(
                    placement,
                    publication.runtime,
                    &publication.state,
                );
                self.emit(MuxEvent::SizeStateChanged {
                    surface: placement,
                    runtime: publication.runtime,
                    state: publication.state.clone(),
                });
            }
        }
    }

    fn emit_client_sizing_changes(&self, clients: impl IntoIterator<Item = u64>) {
        for client in clients {
            let (name, kind) = self.control_clients.client_info(client).unwrap_or((None, None));
            self.emit(MuxEvent::ClientChanged { client, name, kind });
        }
    }

    /// Claim or release a terminal's canonical geometry for one live client,
    /// or update the legacy shared-size policy for a non-terminal surface.
    pub fn set_client_size_participation(
        &self,
        surface: SurfaceId,
        client: u64,
        participating: bool,
    ) -> Option<bool> {
        if let Some(runtime) = self.surface(surface)?.terminal_runtime_id() {
            // Terminals map the legacy participation switch onto the shared
            // engine: disabling sets `counts_override:false`; enabling clears
            // that choice and counts as activity.
            let id = view_participant_id(runtime, surface, client);
            if participating {
                {
                    let _lifecycle = self.lock_client_sizing_lifecycle();
                    if client != 0 && !self.control_clients.contains(client) {
                        return None;
                    }
                }
                let cleared = self
                    .client_sizing
                    .lock()
                    .unwrap()
                    .terminal_sizing
                    .get(&runtime)
                    .and_then(|entry| entry.engine.participant(&id))
                    .is_some_and(|participant| participant.counts_override == Some(false));
                if cleared {
                    self.set_terminal_size_counts(surface, &id, None);
                }
                return self
                    .claim_terminal_geometry(surface, client)
                    .map(|changed| changed || cleared);
            }
            let _lifecycle = self.lock_client_sizing_lifecycle();
            // Revalidate after acquiring the sizing lifecycle fence. A
            // disconnect may have removed the client while this action was
            // waiting for the fence, and a stale release must not report a
            // successful no-op against a dead client.
            if client != 0 && !self.control_clients.contains(client) {
                return None;
            }
            return Some(self.mutate_terminal_sizing(runtime, |mux, sizing| {
                sizing.terminal_runtime_by_placement.insert(surface, runtime);
                let participant = mux.view_participant(sizing, runtime, surface, client);
                let entry = mux.terminal_sizing_entry(sizing, runtime, surface);
                let mut attached = false;
                if !entry.engine.contains(&id) {
                    entry.members.insert(
                        id.clone(),
                        SizingMember { client, placement: surface, view: None },
                    );
                    attached = entry.engine.attach(participant);
                }
                let changed = entry.engine.set_counts_override(&id, Some(false));
                sizing.note_size_state(runtime, attached || changed);
                changed
            }));
        }
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

    /// Atomically grant one client/placement canonical terminal geometry.
    pub fn use_only_client_size(&self, surface: SurfaceId, target: u64) -> Option<bool> {
        if self.surface(surface)?.terminal_runtime_id().is_some() {
            if target != 0
                && !self.control_clients.attached_client_ids_for_surface(surface).contains(&target)
            {
                return None;
            }
            self.client_surface_size(surface, target)?;
            return self.set_client_size_participation(surface, target, true);
        }
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

    /// Restore automatic sizing: terminals clear every counts override,
    /// browsers drop their include/exclude policy.
    pub fn use_all_client_sizes(&self, surface: SurfaceId) -> Option<bool> {
        if self.surface(surface)?.terminal_runtime_id().is_some() {
            return self.release_terminal_geometry(surface);
        }
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
        if let Some(runtime) =
            self.surface(surface).and_then(|surface| surface.terminal_runtime_id())
        {
            return self
                .client_sizing
                .lock()
                .unwrap()
                .owns_terminal_geometry(runtime, surface, client);
        }
        self.client_sizing.lock().unwrap().client_participates(surface, client)
    }

    pub fn control_clients_json(&self, requesting_client: u64) -> Value {
        let mut clients = self.control_clients.list_json(requesting_client);
        if let Some(clients) = clients.as_array_mut() {
            for info in clients {
                let id = info.get("client").and_then(Value::as_u64).unwrap_or_default();
                if let Some(sizes) = info.get_mut("sizes").and_then(Value::as_array_mut) {
                    for size in sizes {
                        let surface =
                            size.get("surface").and_then(Value::as_u64).unwrap_or_default();
                        size["size_participating"] =
                            serde_json::json!(self.client_size_participates(surface, id));
                    }
                }
            }
        }
        let sizing = self.client_sizing.lock().unwrap();
        let local_sizes = sizing
            .surfaces
            .iter()
            .filter_map(|(surface, viewers)| {
                viewers.get(&0).map(|(cols, rows)| {
                    serde_json::json!({
                        "surface": surface,
                        "cols": cols,
                        "rows": rows,
                        "size_participating": sizing.report_participates(*surface, 0),
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
    fn last_resource_mutation_metrics(&self) -> ResourceMutationMetrics {
        self.resource_mutation_metrics
            .lock()
            .unwrap()
            .expect("resource mutation did not record metrics")
    }

    #[cfg(all(test, unix))]
    pub(crate) fn seed_launching_terminal_for_test(
        &self,
        terminal_id: &str,
        workspace_key: &str,
    ) -> anyhow::Result<()> {
        let mut registry = self.workspace_registry.lock().unwrap();
        commit_terminal_transition(
            &mut registry,
            "terminal-reserved",
            "seed-launching-terminal",
            &RegistryTerminal {
                terminal_id: terminal_id.to_string(),
                workspace_key: workspace_key.to_string(),
                incarnation: None,
                lifecycle: TerminalLifecycle::Launching,
                launch_spec: serde_json::json!({}),
                exit: None,
                on_exit: TerminalOnExit::Close,
            },
        )?;
        Ok(())
    }

    #[cfg(all(test, unix))]
    pub(crate) fn seed_running_terminal_for_test(
        self: &Arc<Self>,
        terminal_id: &str,
        incarnation: &str,
        workspace_key: &str,
    ) -> anyhow::Result<SurfaceId> {
        self.seed_running_terminal_with_on_exit_for_test(
            terminal_id,
            incarnation,
            workspace_key,
            TerminalOnExit::Close,
        )
    }

    #[cfg(all(test, unix))]
    pub(crate) fn seed_running_terminal_with_on_exit_for_test(
        self: &Arc<Self>,
        terminal_id: &str,
        incarnation: &str,
        workspace_key: &str,
        on_exit: TerminalOnExit,
    ) -> anyhow::Result<SurfaceId> {
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
                on_exit,
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
        insert_surface_checked(&mut state, surface.clone())?;
        let (placement, changed) =
            self.project_terminal_to_workspace_in_state(&mut state, terminal_id, workspace_key)?;
        anyhow::ensure!(changed, "seeded terminal did not change topology");
        anyhow::ensure!(
            placement.is_some_and(|placement| placement.surface == surface.id),
            "seeded terminal projection returned the wrong surface"
        );
        drop(state);
        drop(registry);
        self.commit_ordinary_full_resource_projection(
            &Actor::Daemon,
            "test.terminal.seed",
            serde_json::json!({}),
        )?;
        Ok(surface.id)
    }

    #[cfg(test)]
    pub(crate) fn set_terminal_close_failure_for_test(&self, enabled: bool) -> anyhow::Result<()> {
        self.workspace_registry.lock().unwrap().set_terminal_close_failure(enabled)
    }

    fn browser_runtime(&self) -> anyhow::Result<Arc<BrowserRuntime>> {
        let mut runtime = self.browser_runtime.lock().unwrap();
        if let Some(existing) = runtime.as_ref().filter(|existing| {
            !existing.is_closed() && existing.source() != crate::BrowserSource::Provider
        }) {
            return Ok(existing.clone());
        }
        let opts = self.surface_options.lock().unwrap().clone();
        let created = BrowserRuntime::connect(&opts)?;
        *runtime = Some(created.clone());
        Ok(created)
    }

    pub(crate) fn register_browser_provider(
        self: &Arc<Self>,
        client: u64,
        registration: BrowserProviderRegistration,
    ) -> anyhow::Result<BrowserProviderSnapshot> {
        let snapshot = self.browser_providers.register(client, registration)?;
        self.reconcile_provider_browser_surfaces();
        Ok(snapshot)
    }

    pub(crate) fn unregister_browser_provider(self: &Arc<Self>, client: u64) -> bool {
        let removed = self.browser_providers.unregister(client);
        if removed {
            self.reconcile_provider_browser_surfaces();
        }
        removed
    }

    pub(crate) fn browser_provider_snapshot(&self) -> Option<BrowserProviderSnapshot> {
        self.browser_providers.snapshot()
    }

    fn reconcile_provider_browser_surfaces(self: &Arc<Self>) {
        let surfaces = {
            let state = self.state.lock().unwrap();
            state
                .surfaces
                .values()
                .filter_map(|surface| {
                    let identity = surface.resource_identity()?;
                    matches!(&identity.content_id, ContentPublicId::Browser(_))
                        .then(|| (surface.clone(), identity.tab_id.clone()))
                })
                .collect::<Vec<_>>()
        };
        for (surface, tab_id) in surfaces {
            let lease = self.browser_providers.target(&tab_id);
            let Surface::Browser(browser) = surface.as_ref() else { continue };
            if browser.prepare_provider_lease_replacement(lease.as_ref()) {
                self.restart_provider_browser_surface(surface);
            }
        }
    }

    fn browser_runtime_for_provider(
        &self,
        lease: &BrowserProviderTargetLease,
    ) -> anyhow::Result<Arc<BrowserRuntime>> {
        let mut runtime = self.browser_runtime.lock().unwrap();
        if let Some(existing) = runtime.as_ref().filter(|existing| {
            !existing.is_closed()
                && existing.matches_provider(&lease.endpoint, &lease.authentication)
        }) {
            return Ok(existing.clone());
        }
        let created = BrowserRuntime::connect_provider(&lease.endpoint, &lease.authentication)?;
        *runtime = Some(created.clone());
        Ok(created)
    }

    fn start_browser_bootstrap(
        self: &Arc<Self>,
        surface: Arc<Surface>,
        bootstrap: BrowserBootstrap,
        runtime: Option<Arc<BrowserRuntime>>,
    ) {
        let provider_bootstrap = matches!(&bootstrap, BrowserBootstrap::Provider { .. });
        // The frontend renders this page itself; the daemon never waits for
        // or attaches a CDP target for it.
        if provider_bootstrap && self.is_frontend_browser_surface(&surface) {
            return;
        }
        let weak_mux = Arc::downgrade(self);
        let providers = self.browser_providers.clone();
        let id = surface.id;
        let thread_surface = surface.clone();
        let spawn = std::thread::Builder::new()
            .name(format!("browser-surface-{id}-bootstrap"))
            .spawn(move || {
                let result = (|| -> anyhow::Result<()> {
                    match bootstrap {
                        BrowserBootstrap::Provider { tab_id, url } => {
                            anyhow::ensure!(
                                runtime.is_none(),
                                "provider bootstrap cannot override its CDP runtime"
                            );
                            let mut retry_delay = Duration::from_millis(250);
                            loop {
                                let canceled = || {
                                    thread_surface.is_dead()
                                        || weak_mux.upgrade().is_none_or(|mux| {
                                            mux.shutting_down.load(Ordering::Acquire)
                                        })
                                };
                                let lease =
                                    providers.wait_for_target(&tab_id, canceled).ok_or_else(
                                        || anyhow::anyhow!("browser provider wait was canceled"),
                                    )?;
                                let attempt = (|| -> anyhow::Result<()> {
                                    let mux = weak_mux.upgrade().ok_or_else(|| {
                                        anyhow::anyhow!("browser mux was dropped")
                                    })?;
                                    let runtime = mux.browser_runtime_for_provider(&lease)?;
                                    let Surface::Browser(browser) = thread_surface.as_ref() else {
                                        anyhow::bail!(
                                            "browser bootstrap got a non-browser surface"
                                        );
                                    };
                                    anyhow::ensure!(
                                        browser.prepare_provider_bootstrap_attempt(),
                                        "browser provider wait was canceled"
                                    );
                                    runtime.bootstrap_surface_sync(
                                        thread_surface.clone(),
                                        BrowserBootstrap::ExistingTarget {
                                            target_id: lease.target_id.clone(),
                                            url: url.clone(),
                                        },
                                        weak_mux.clone(),
                                    )
                                })();
                                match attempt {
                                    Ok(()) => {
                                        let current_lease = providers.target(&tab_id);
                                        let Surface::Browser(browser) = thread_surface.as_ref()
                                        else {
                                            anyhow::bail!(
                                                "browser bootstrap got a non-browser surface"
                                            );
                                        };
                                        // Registration can change while CDP
                                        // setup is in flight. Never publish a
                                        // now-stale target merely because its
                                        // attach finished after the provider
                                        // revision advanced.
                                        if browser.prepare_provider_lease_replacement(
                                            current_lease.as_ref(),
                                        ) {
                                            retry_delay = Duration::from_millis(250);
                                            continue;
                                        }
                                        return Ok(());
                                    }
                                    Err(error) if !canceled() => {
                                        let message = error.to_string();
                                        let Surface::Browser(browser) = thread_surface.as_ref()
                                        else {
                                            return Err(error);
                                        };
                                        let changed = browser.status()
                                            != crate::BrowserStatus::Failed(message.clone());
                                        if changed {
                                            browser.mark_failed(message.clone());
                                            if let Some(mux) = weak_mux.upgrade() {
                                                mux.emit(MuxEvent::Status(format!(
                                                    "cmux-browser provider unavailable: {message}"
                                                )));
                                                mux.emit(MuxEvent::TitleChanged {
                                                    surface: id,
                                                    title: thread_surface.title().into(),
                                                });
                                                mux.emit(MuxEvent::SurfaceOutput(id));
                                            }
                                        }
                                        if !providers.wait_for_revision_change(
                                            lease.revision,
                                            canceled,
                                            retry_delay,
                                        ) {
                                            anyhow::bail!("browser provider wait was canceled");
                                        }
                                        retry_delay = retry_delay
                                            .saturating_mul(2)
                                            .min(Duration::from_secs(2));
                                    }
                                    Err(error) => return Err(error),
                                }
                            }
                        }
                        bootstrap => {
                            let mux = weak_mux
                                .upgrade()
                                .ok_or_else(|| anyhow::anyhow!("browser mux was dropped"))?;
                            let runtime = match runtime {
                                Some(runtime) => runtime,
                                None => mux.browser_runtime()?,
                            };
                            runtime.bootstrap_surface_sync(
                                thread_surface.clone(),
                                bootstrap,
                                weak_mux.clone(),
                            )
                        }
                    }
                })();
                if let Err(err) = result {
                    if !thread_surface.is_dead()
                        && !provider_bootstrap
                        && let Surface::Browser(browser) = thread_surface.as_ref()
                    {
                        browser.abandon_attach(err.to_string());
                    }
                    if !provider_bootstrap
                        && let Some(mux) = weak_mux.upgrade()
                        && !thread_surface.is_dead()
                    {
                        mux.emit(MuxEvent::Status(format!("browser failed: {err}")));
                        mux.emit(MuxEvent::TitleChanged {
                            surface: id,
                            title: thread_surface.title().into(),
                        });
                        mux.emit(MuxEvent::SurfaceOutput(id));
                    }
                }
            });
        if let Err(error) = spawn
            && !surface.is_dead()
            && let Surface::Browser(browser) = surface.as_ref()
        {
            browser.abandon_attach(format!("could not start browser bootstrap: {error}"));
        }
    }

    pub(crate) fn restart_provider_browser_surface(self: &Arc<Self>, surface: Arc<Surface>) {
        let Some(identity) = surface.resource_identity() else { return };
        if !matches!(identity.content_id, ContentPublicId::Browser(_)) {
            return;
        }
        let tab_id = identity.tab_id.clone();
        let url = surface.browser_url().unwrap_or_else(|| "about:blank".to_string());
        self.start_browser_bootstrap(surface, BrowserBootstrap::Provider { tab_id, url }, None);
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
        let removed = state.terminal_catalog.remove(terminal_id)?;
        if let Some(runtime_id) = removed.terminal_runtime_id() {
            state.terminal_catalog_by_runtime.remove(&runtime_id);
        }
        Some(removed)
    }

    /// Resolve a terminal identity to its durable record and one live view
    /// placement. A catalog-owned terminal with zero views resolves
    /// successfully with a null surface. This is lookup-only and never creates
    /// a replacement shell.
    ///
    /// Either identity a client can hold is accepted: the process-stable
    /// terminal host UUID, or the public `term_…` resource id every resource
    /// command reports (with or without its prefix). A public id maps through
    /// the registry, including after close, so a tombstone still answers.
    /// Clients such as the Mac app only ever hold public ids; validating them
    /// as host ids answered `invalid_terminal_id` and left a detached
    /// terminal unresolvable by construction (#12362).
    pub fn resolve_terminal(
        &self,
        terminal_id: &str,
    ) -> anyhow::Result<Option<TerminalResolution>> {
        let (terminal, terminal_revision) = {
            let registry = self.workspace_registry.lock().unwrap();
            let Some(host_id) = Self::resolve_terminal_host_id(&registry, terminal_id)? else {
                return Ok(None);
            };
            (registry.terminal_record(&host_id)?, registry.terminal_revision()?)
        };
        let Some(terminal) = terminal else {
            return Ok(None);
        };
        let state = self.state.lock().unwrap();
        let surface = self
            .catalog_terminal_by_host(&state, &terminal.terminal_id)?
            .and_then(|runtime| terminal_placement_for_runtime(&state, &runtime));
        Ok(Some(TerminalResolution { surface, terminal, terminal_revision }))
    }

    /// The host id behind a resolver input, or `None` when no registered
    /// terminal carries that identity. A UUIDv4-shaped value is tried as a host
    /// id first; about one public id in 64 has that shape by chance, so on a
    /// miss it is retried as a public id before being reported unknown.
    fn resolve_terminal_host_id(
        registry: &WorkspaceRegistry,
        terminal_id: &str,
    ) -> anyhow::Result<Option<String>> {
        let payload = terminal_id.strip_prefix("term_").unwrap_or(terminal_id);
        let is_hex = payload.len() == crate::terminal_host::TERMINAL_ID_LEN * 2
            && payload.bytes().all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f'));
        anyhow::ensure!(is_hex, "invalid_terminal_id");
        if !terminal_id.starts_with("term_")
            && TerminalId::from_hex(payload).is_some()
            && registry.terminal_record(payload)?.is_some()
        {
            return Ok(Some(payload.to_string()));
        }
        let public_id = TerminalPublicId::parse(format!("term_{payload}"))?;
        registry.terminal_host_id(&public_id)
    }

    /// Atomically resolve, incarnation-check, and remove a hosted terminal by
    /// process-stable identity. The host is terminated only after the state
    /// lock has made the removal authoritative for this daemon generation.
    /// Tests only: production closes name their mutation (and actor) with
    /// [`Self::close_terminal_with_mutation`] (P8 landing 3b).
    #[cfg(test)]
    pub(crate) fn close_terminal(
        &self,
        terminal_id: &str,
        terminal_incarnation: &str,
    ) -> anyhow::Result<TerminalCloseResult> {
        self.close_terminal_with_mutation(
            terminal_id,
            Some(terminal_incarnation),
            None,
            None,
            &WorkspaceMutation::daemon_local("cmux-tui"),
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
        self.close_terminal_guarded(
            terminal_id,
            terminal_incarnation,
            expected_generation,
            expected_revision,
            mutation,
            TerminalCloseGuard::None,
        )
    }

    /// Close a hosted terminal after checking `guard` under the registry
    /// lock, which serializes every placement commit. A failed guard returns
    /// [`TerminalCloseGuardFailed`] and changes nothing.
    pub(crate) fn close_terminal_guarded(
        &self,
        terminal_id: &str,
        terminal_incarnation: Option<&str>,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
        guard: TerminalCloseGuard,
    ) -> anyhow::Result<TerminalCloseResult> {
        validate_terminal_hex(terminal_id, "invalid_terminal_id")?;
        if let Some(incarnation) = terminal_incarnation {
            validate_terminal_hex(incarnation, "invalid_terminal_incarnation")?;
        }
        if let Some(result) = self.commit_legacy_terminal_close(
            terminal_id,
            terminal_incarnation,
            expected_generation,
            expected_revision,
            mutation,
            guard,
        )? {
            return Ok(result);
        }
        let (commit, terminal_incarnation, public_id, notify_public_id) = {
            let mut registry = self.workspace_registry.lock().unwrap();
            if guard == TerminalCloseGuard::UnplacedAndNotKept {
                let placed = {
                    let state = self.state.lock().unwrap();
                    state.surfaces.values().any(|surface| {
                        self.resource_terminal_host_identity(surface)
                            .is_some_and(|identity| identity.terminal_id == terminal_id)
                    })
                };
                if placed || registry.terminal_keep(terminal_id)? {
                    return Err(TerminalCloseGuardFailed.into());
                }
            }
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
            (commit, incarnation, public_id.clone(), newly_closed.then_some(public_id).flatten())
        };
        self.notify_terminal_exit_waiters(notify_public_id);
        let (target, removed, runtime, changed_screens, empty_revision) = {
            let mut state = self.state.lock().unwrap();
            let catalog_public_id = public_id.or_else(|| {
                state.terminal_catalog.iter().find_map(|(public_id, surface)| {
                    self.resource_terminal_host_identity(surface)
                        .is_some_and(|identity| identity.terminal_id == terminal_id)
                        .then(|| public_id.clone())
                })
            });
            let runtime = catalog_public_id
                .as_ref()
                .and_then(|public_id| state.terminal_catalog.get(public_id))
                .cloned();
            // The durable close has committed. From this point cleanup must
            // finish even if an in-memory host incarnation was stale; leaving
            // a live runtime behind would contradict the terminal tombstone.
            let content_id = catalog_public_id.map(ContentPublicId::Terminal);
            let mut targets = content_id
                .as_ref()
                .map(|content_id| state.placements_of_content(content_id).to_vec())
                .unwrap_or_default();
            if targets.is_empty() {
                targets.extend(state.surfaces.iter().filter_map(|(surface_id, surface)| {
                    self.resource_terminal_host_identity(surface)
                        .is_some_and(|identity| identity.terminal_id == terminal_id)
                        .then_some(*surface_id)
                }));
            }
            let target = targets.first().copied();
            let changed_screens = unique_screen_ids(
                targets.iter().filter_map(|surface| surface_screen_id(&state, *surface)),
            );
            let removed = if let Some(runtime) = runtime.as_ref() {
                remove_terminal_runtime_from_state(self, &mut state, runtime).0
            } else {
                let mut removed = Vec::with_capacity(targets.len());
                let mut split_index_dirty = false;
                for target in targets {
                    let (surface, topology_changed) = remove_surface(self, &mut state, target);
                    split_index_dirty |= topology_changed;
                    if let Some(surface) = surface {
                        removed.push(surface);
                    }
                }
                if split_index_dirty {
                    Self::rebuild_split_screen_index(&mut state);
                }
                removed
            };
            let empty_revision = state.workspaces.is_empty().then_some(state.workspace_revision);
            (target, removed, runtime, changed_screens, empty_revision)
        };
        for surface in removed {
            self.purge_surface_side_tables(surface.id);
        }
        let had_runtime = runtime.is_some();
        if let Some(runtime) = runtime {
            self.purge_terminal_runtime_side_tables(&runtime);
            self.terminate_terminal_runtime(&runtime);
        }
        if target.is_some() {
            self.emit(MuxEvent::TreeChanged);
        }
        for screen in changed_screens {
            self.emit(MuxEvent::LayoutChanged(screen));
        }
        if !had_runtime {
            self.terminate_discovered_terminal_host(terminal_id, terminal_incarnation.as_deref());
        }
        self.emit_empty_if_current(empty_revision);
        Ok(TerminalCloseResult {
            surface: target,
            terminal_id: terminal_id.to_string(),
            terminal_incarnation,
            already_closed: commit.result["already_closed"].as_bool().unwrap_or(commit.replayed),
            terminal_revision: commit.revision,
        })
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
                remove_terminal_runtime_from_state(self, &mut state, surface).0
            };
            for placement in removed {
                self.purge_surface_side_tables(placement.id);
            }
            self.purge_terminal_runtime_side_tables(surface);
            if !surface.is_dead() {
                surface.kill();
            }
            return Ok(());
        };
        self.persist_terminal_exit(
            &identity.terminal_id,
            Some(&identity.incarnation),
            &TerminalEnd::launch_failed(reason),
        )?;
        let removed = {
            let mut state = self.state.lock().unwrap();
            remove_terminal_runtime_from_state(self, &mut state, surface).0
        };
        for placement in removed {
            self.purge_surface_side_tables(placement.id);
        }
        self.purge_terminal_runtime_side_tables(surface);
        if !surface.is_dead() {
            surface.kill();
        }
        Ok(())
    }

    pub(crate) fn terminate_discovered_terminal_host(
        &self,
        terminal_id: &str,
        incarnation: Option<&str>,
    ) {
        #[cfg(unix)]
        {
            self.clear_pending_terminal(terminal_id);
            let root = self.surface_options.lock().unwrap().terminal_host_root.clone();
            let Some(root) = root else { return };
            terminate_discovered_terminal_host_in(&root, terminal_id, incarnation);
        }
        #[cfg(not(unix))]
        let _ = (terminal_id, incarnation);
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
        let state = self.state.lock().unwrap();
        let terminal_id = state
            .surfaces
            .get(&surface)
            .or_else(|| state.terminal_runtime_by_id(surface))
            .and_then(|surface| surface.terminal_public_id().cloned());
        drop(state);
        match terminal_id {
            Some(terminal_id) => {
                self.terminal_notifications.lock().unwrap().get(&terminal_id).copied()
            }
            None => self.placement_notifications.lock().unwrap().get(&surface).copied(),
        }
    }

    pub(crate) fn terminal_notification(
        &self,
        terminal_id: &TerminalPublicId,
    ) -> Option<SurfaceNotification> {
        self.terminal_notifications.lock().unwrap().get(terminal_id).copied()
    }

    pub fn surface_notifications(&self) -> HashMap<SurfaceId, SurfaceNotification> {
        let state = self.state.lock().unwrap();
        self.surface_notifications_in_state(&state)
    }

    fn surface_notifications_in_state(
        &self,
        state: &State,
    ) -> HashMap<SurfaceId, SurfaceNotification> {
        let placement_notifications = self.placement_notifications.lock().unwrap();
        let terminal_notifications = self.terminal_notifications.lock().unwrap();
        let mut result = HashMap::new();
        for (surface_id, surface) in &state.surfaces {
            let notification = match surface.terminal_public_id() {
                Some(terminal_id) => terminal_notifications.get(terminal_id),
                None => placement_notifications.get(surface_id),
            };
            if let Some(notification) = notification {
                result.insert(*surface_id, *notification);
            }
        }
        result
    }

    pub fn clear_surface_notification(&self, surface: SurfaceId) -> bool {
        let state = self.state.lock().unwrap();
        let terminal_id = state
            .surfaces
            .get(&surface)
            .or_else(|| state.terminal_runtime_by_id(surface))
            .and_then(|surface| surface.terminal_public_id().cloned());
        drop(state);
        let cleared = match &terminal_id {
            Some(terminal_id) => {
                self.terminal_notifications.lock().unwrap().remove(terminal_id).is_some()
            }
            None => self.placement_notifications.lock().unwrap().remove(&surface).is_some(),
        };
        if cleared
            && let Some(terminal_id) = &terminal_id
            && self.persist_notification_acks(Some(terminal_id), surface).is_err()
        {
            self.report_internal_diagnostic("notification acknowledgement not persisted");
        }
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

    fn clear_viewed_notification(&self, surface: Option<SurfaceId>) {
        let Some(surface) = surface else { return };
        let state = self.state.lock().unwrap();
        let terminal_id = state
            .surfaces
            .get(&surface)
            .or_else(|| state.terminal_runtime_by_id(surface))
            .and_then(|surface| surface.terminal_public_id().cloned());
        drop(state);
        if let Some(terminal_id) = terminal_id {
            let removed =
                self.terminal_notifications.lock().unwrap().remove(&terminal_id).is_some();
            // Selecting a tab is a legacy acknowledgement; persist it like
            // `ack-tab-notifications` so a restart keeps it read.
            if removed && self.persist_notification_acks(Some(&terminal_id), surface).is_err() {
                self.report_internal_diagnostic("notification acknowledgement not persisted");
            }
        } else {
            let _ = self.placement_notifications.lock().unwrap().remove(&surface);
        }
    }

    /// The launch snapshot file (`launch-snapshot-v1`) while its writer runs.
    pub fn launch_snapshot_path(&self) -> Option<std::path::PathBuf> {
        self.launch_snapshot_path.lock().unwrap().clone()
    }

    pub(crate) fn set_launch_snapshot_path(&self, path: Option<std::path::PathBuf>) {
        *self.launch_snapshot_path.lock().unwrap() = path;
    }

    /// Events that can change the launch snapshot.
    pub(crate) fn subscribe_launch_snapshot(&self) -> MuxEventReceiver {
        self.subscribers.subscribe_launch_snapshot()
    }

    /// Post a notification from the legacy `notify` verb. This is the same
    /// durable path as `notification.create`, under a fresh key, so remote
    /// subscribers of the resource feed and a restarted daemon see it too.
    #[cfg(test)]
    pub(crate) fn post_notification(
        &self,
        title: String,
        body: String,
        level: NotificationLevel,
        surface: Option<SurfaceId>,
    ) -> anyhow::Result<u64> {
        self.post_notification_as(
            &Actor::Daemon,
            title,
            body,
            level,
            surface,
            NotificationSource::Cli,
        )
    }

    /// A fresh notification that `actor` posts, with an explicit source.
    pub fn post_notification_as(
        &self,
        actor: &Actor,
        title: String,
        body: String,
        level: NotificationLevel,
        surface: Option<SurfaceId>,
        source: NotificationSource,
    ) -> anyhow::Result<u64> {
        let key = format!("notify-{}", crate::workspace_registry::new_uuid_v4());
        self.create_durable_notification(actor, &key, title, None, body, level, surface, source)?
            .context("fresh notify key unexpectedly replayed")
    }

    /// Whether this daemon records finished shell commands (in memory, off
    /// at start; a global switch that any trusted local client sets: a gap
    /// recorded in plans/cmux-next/COORDINATION.md).
    pub(crate) fn terminal_command_history_enabled(&self) -> bool {
        self.terminal_command_history.load(Ordering::Acquire)
    }

    pub(crate) fn set_terminal_command_history(&self, enabled: bool) {
        self.terminal_command_history.store(enabled, Ordering::Release);
    }

    /// Queues finished shell commands of `terminal` for the journal
    /// (`shell.command.finished`). One long-lived worker per daemon appends
    /// them in order; the caller (a PTY reader) never waits for the journal
    /// writer. The queue is bounded: when it is full, records drop and a
    /// diagnostic counts it.
    pub(crate) fn append_shell_commands(
        self: &Arc<Self>,
        terminal: TerminalPublicId,
        commands: Vec<crate::shell_history::FinishedCommand>,
    ) {
        if !self.terminal_command_history_enabled() {
            return;
        }
        let Some(sender) = self.shell_command_sender() else {
            self.report_internal_diagnostic("shell command journal worker not started");
            return;
        };
        for command in commands {
            if sender.try_send((terminal.clone(), command)).is_err() {
                self.report_internal_diagnostic("shell command journal queue full; record dropped");
            }
        }
    }

    /// The journal worker's queue, started on first use.
    fn shell_command_sender(
        self: &Arc<Self>,
    ) -> Option<SyncSender<(TerminalPublicId, crate::shell_history::FinishedCommand)>> {
        let mut slot = self.shell_command_journal.lock().unwrap();
        if let Some(sender) = slot.as_ref() {
            return Some(sender.clone());
        }
        let (sender, receiver) = std::sync::mpsc::sync_channel::<(
            TerminalPublicId,
            crate::shell_history::FinishedCommand,
        )>(crate::shell_history::MAX_QUEUED_COMMANDS);
        let mux = Arc::downgrade(self);
        std::thread::Builder::new()
            .name("shell-command-journal".into())
            .spawn(move || {
                while let Ok((terminal, command)) = receiver.recv() {
                    let Some(mux) = mux.upgrade() else { return };
                    let ingress =
                        crate::shell_history::command_journal_ingress(&terminal, &command);
                    let key = format!("shell-command-{}", crate::workspace_registry::new_uuid_v4());
                    if let Err(error) = mux.append_journal_ingress(&ingress, "shell-command", &key)
                    {
                        eprintln!(
                            "cmux-tui: journaling a shell command for {terminal} failed: {error}"
                        );
                    }
                }
            })
            .ok()?;
        *slot = Some(sender.clone());
        Some(sender)
    }

    /// Post what a program in `surface`'s terminal asked for with OSC 9,
    /// OSC 777 or OSC 99, or an OSC 7501 record's alert. Called by the terminal's output reader after it
    /// released the terminal lock; the reader already applied the rate limit.
    pub(crate) fn post_terminal_notifications(
        &self,
        surface: SurfaceId,
        notifications: Vec<crate::terminal_metadata::TerminalNotification>,
    ) {
        for notification in notifications {
            if self
                .post_notification_as(
                    &Actor::Daemon,
                    notification.title,
                    notification.body,
                    notification.level,
                    Some(surface),
                    NotificationSource::Terminal,
                )
                .is_err()
            {
                self.report_internal_diagnostic("terminal notification not posted");
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    pub(crate) fn post_resource_notification(
        &self,
        public_id: NotificationPublicId,
        title: String,
        subtitle: Option<String>,
        body: String,
        level: NotificationLevel,
        surface: Option<SurfaceId>,
        terminal_id: Option<TerminalPublicId>,
        created_at_ms: u64,
        source: NotificationSource,
    ) -> u64 {
        let id = self.next_notification_id();
        {
            const NOTIFICATION_LEDGER_CAPACITY: usize = 256;
            let mut ledger = self.notification_ledger.lock().unwrap();
            ledger.push_back(ResourceNotification {
                id: public_id,
                title: title.clone(),
                subtitle,
                body: body.clone(),
                level,
                terminal_id: terminal_id.clone(),
                created_at_ms,
                source,
                surface,
            });
            let mut evicted = Vec::new();
            while ledger.len() > NOTIFICATION_LEDGER_CAPACITY {
                if let Some(old) = ledger.pop_front() {
                    evicted.push(old.id);
                }
            }
            if !evicted.is_empty() {
                let mut reads = self.notification_reads.lock().unwrap();
                for id in &evicted {
                    reads.remove(id);
                }
                self.notification_read_prunes.lock().unwrap().extend(evicted);
            }
        }
        // Shared topology focus is only a default projection. A frontend must
        // explicitly acknowledge a viewed notification through its selection
        // action, so local focus in one client cannot hide attention from the
        // others.
        let mut unread_changed = false;
        match terminal_id {
            Some(terminal_id) => {
                self.terminal_notifications.lock().unwrap().insert(
                    terminal_id,
                    SurfaceNotification { notification: id, level, unread: true, source },
                );
                unread_changed = true;
            }
            None if surface.is_some() => {
                let surface = surface.expect("checked notification surface");
                self.placement_notifications.lock().unwrap().insert(
                    surface,
                    SurfaceNotification { notification: id, level, unread: true, source },
                );
                unread_changed = true;
            }
            None => {}
        }
        self.emit(MuxEvent::Notification(NotificationEvent {
            notification: id,
            title,
            body,
            level,
            surface,
            source,
        }));
        if unread_changed {
            self.emit(MuxEvent::TreeChanged);
        }
        id
    }

    pub fn resource_notifications(&self, limit: usize) -> Vec<ResourceNotification> {
        let mut notifications = self
            .notification_ledger
            .lock()
            .unwrap()
            .iter()
            .rev()
            .take(limit.min(256))
            .cloned()
            .collect::<Vec<_>>();
        let state = self.state.lock().unwrap();
        for notification in &mut notifications {
            if let Some(terminal_id) = &notification.terminal_id {
                notification.surface = state
                    .placements_of_content(&ContentPublicId::Terminal(terminal_id.clone()))
                    .first()
                    .copied()
                    .or_else(|| state.terminal_catalog.get(terminal_id).map(|surface| surface.id));
            }
        }
        notifications
    }

    /// Client ids that acknowledged `notification`, sorted and unique.
    pub fn notification_read_by(&self, notification: &NotificationPublicId) -> Vec<String> {
        self.notification_reads
            .lock()
            .unwrap()
            .get(notification)
            .map(|clients| clients.iter().cloned().collect())
            .unwrap_or_default()
    }

    /// The public snapshot row for one ledger entry. Every producer of a
    /// `notification` resource value goes through here so create results,
    /// acknowledgement deltas, and session snapshots cannot drift.
    pub(crate) fn notification_snapshot_value(
        &self,
        notification: &ResourceNotification,
        session_id: &SessionPublicId,
        read_by: &[String],
    ) -> Value {
        let unread = notification
            .terminal_id
            .as_ref()
            .and_then(|terminal_id| self.terminal_notification(terminal_id))
            .is_some_and(|marker| marker.unread);
        let mut value = serde_json::json!({
            "id": notification.id,
            "session_id": session_id,
            "title": notification.title,
            "body": notification.body,
            "level": notification.level.as_str(),
            "created_at_ms": notification.created_at_ms.to_string(),
            "unread": unread,
            "read_by": read_by,
        });
        if let Some(terminal_id) = &notification.terminal_id {
            value["terminal_id"] = serde_json::json!(terminal_id);
        }
        if let Some(subtitle) = &notification.subtitle {
            value["subtitle"] = serde_json::json!(subtitle);
        }
        // Stored under `extra`, which every registry schema already accepts,
        // so a downgraded daemon still opens the receipt.
        value["extra"] = serde_json::json!({"source": notification.source.as_str()});
        value
    }

    /// Post a notification through the durable `notification.create` effect
    /// path under a caller-owned idempotency key. Replaying the same key
    /// returns `None` without posting again, so journal-driven producers
    /// (agent hooks) and the legacy `notify` verb share one durable ledger
    /// with the resource API and survive a daemon restart. A fresh post
    /// returns the session-local legacy notification id.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn create_durable_notification(
        &self,
        actor: &Actor,
        idempotency_key: &str,
        title: String,
        subtitle: Option<String>,
        body: String,
        level: NotificationLevel,
        surface: Option<SurfaceId>,
        source: NotificationSource,
    ) -> anyhow::Result<Option<u64>> {
        const OPERATION: &str = "notification.create";
        let terminal_id = surface.and_then(|surface| {
            let state = self.state.lock().unwrap();
            state
                .surfaces
                .get(&surface)
                .or_else(|| state.terminal_runtime_by_id(surface))
                .and_then(|surface| surface.terminal_public_id().cloned())
        });
        // The fingerprint names the subtitle only when one was given, so a key
        // minted before subtitles existed (an agent-hook retry across an
        // upgrade) still matches its stored receipt.
        let mut fingerprint = serde_json::json!({
            "operation": OPERATION,
            "origin": "durable-notification",
            "title": title,
            "body": body,
            "level": level.as_str(),
            "terminal_id": terminal_id,
        });
        if let Some(subtitle) = &subtitle {
            fingerprint["subtitle"] = serde_json::json!(subtitle);
        }
        let committed = |outcome: ResourceEffectOutcome| match outcome {
            ResourceEffectOutcome::Success(_) => Ok(None),
            ResourceEffectOutcome::Failure(error) => Err(anyhow::Error::new(error)),
        };
        let preparation = match self.lookup_resource_effect(
            idempotency_key,
            OPERATION,
            &fingerprint,
        )? {
            Some(preparation) => preparation,
            None => {
                let intent = serde_json::json!({
                    "notification_id": NotificationPublicId::random().map_err(anyhow::Error::new)?,
                    "title": title,
                    "subtitle": subtitle,
                    "body": body,
                    "level": level.as_str(),
                    "terminal_id": terminal_id,
                    "created_at_ms": now_ms(),
                    "source": source.as_str(),
                });
                self.prepare_resource_effect(
                    &WorkspaceMutation::new(idempotency_key, "resource-api", actor.clone())?,
                    OPERATION,
                    &fingerprint,
                    &intent,
                    None,
                    None,
                )?
            }
        };
        let intent = match preparation {
            ResourceEffectPreparation::Committed { outcome, .. } => {
                return committed(outcome);
            }
            ResourceEffectPreparation::Indeterminate => {
                // The post may or may not have happened before a crash. A
                // notification is advisory, so the caller proceeds without it
                // rather than retrying the same key forever; the agent-hook
                // fold in particular must still commit its report and fence.
                self.report_internal_diagnostic("notification effect indeterminate, skipped");
                return Ok(None);
            }
            ResourceEffectPreparation::Execute { .. } => {
                self.mark_resource_effect_executing(idempotency_key, OPERATION, &fingerprint)?
            }
        };
        let notification_id: NotificationPublicId =
            serde_json::from_value(intent["notification_id"].clone())
                .context("stored notification intent has an invalid identity")?;
        let created_at_ms = intent
            .get("created_at_ms")
            .and_then(Value::as_u64)
            .context("stored notification intent has an invalid timestamp")?;
        // An intent prepared by a daemon without sources has none; the
        // producer retrying it now names it.
        let source = intent
            .get("source")
            .and_then(Value::as_str)
            .and_then(NotificationSource::parse)
            .unwrap_or(source);
        let numeric_id = self.post_resource_notification(
            notification_id.clone(),
            title.clone(),
            subtitle.clone(),
            body.clone(),
            level,
            surface,
            terminal_id.clone(),
            created_at_ms,
            source,
        );
        let session_id = self.workspace_registry.lock().unwrap().session_id().clone();
        let value = self.notification_snapshot_value(
            &ResourceNotification {
                id: notification_id.clone(),
                title,
                subtitle,
                body,
                level,
                terminal_id,
                created_at_ms,
                source,
                surface,
            },
            &session_id,
            &[],
        );
        let outcome = ResourceEffectOutcome::Success(value.clone());
        let deltas = serde_json::json!([{
            "kind":"upsert",
            "sequence":0,
            "resource":"notification",
            "id":notification_id,
            "value":value,
        }]);
        if let Err(error) = self.commit_resource_effect(
            idempotency_key,
            OPERATION,
            &fingerprint,
            &outcome,
            Some(&deltas),
        ) {
            let _ = self.mark_resource_effect_indeterminate(idempotency_key);
            return Err(error.context("notification effect commit failed"));
        }
        self.prune_evicted_notification_reads();
        Ok(Some(numeric_id))
    }

    /// Delete durable read marks for evicted notifications that the committed
    /// receipts no longer retain. Called after a notification create commits;
    /// ids still retained durably stay queued for a later create.
    pub(crate) fn prune_evicted_notification_reads(&self) {
        let candidates = std::mem::take(&mut *self.notification_read_prunes.lock().unwrap());
        if candidates.is_empty() {
            return;
        }
        let remaining =
            match self.workspace_registry.lock().unwrap().prune_notification_reads(&candidates) {
                Ok(remaining) => remaining,
                Err(_) => {
                    self.report_internal_diagnostic("notification read-mark prune deferred");
                    candidates
                }
            };
        if !remaining.is_empty() {
            self.notification_read_prunes.lock().unwrap().extend(remaining);
        }
    }

    /// Record that `client_id` read `notifications`. Unknown ids are reported,
    /// not rejected: a bounded ledger may have evicted them, and an
    /// acknowledgement of something already gone is complete by definition.
    /// The refreshed rows are published as one resource revision so every
    /// subscribed client converges on the same `read_by` sets.
    pub(crate) fn ack_notifications(
        &self,
        mutation: &WorkspaceMutation,
        expected_revision: Option<u64>,
        client_id: &str,
        notifications: &[NotificationPublicId],
    ) -> anyhow::Result<ResourcePatchCommit> {
        const OPERATION: &str = "notification.ack";
        validate_client_id(client_id)?;
        let fingerprint = serde_json::json!({
            "operation": OPERATION,
            "client_id": client_id,
            "notifications": notifications,
        });
        let mut registry = self.workspace_registry.lock().unwrap();
        if let Some(replay) = registry.replay_resource_patch(mutation, OPERATION, &fingerprint)? {
            return Ok(replay);
        }
        let session_id = registry.session_id().clone();
        let mut acknowledged: Vec<NotificationPublicId> = Vec::new();
        let mut unknown: Vec<NotificationPublicId> = Vec::new();
        let mut deltas = Vec::new();
        {
            let ledger = self.notification_ledger.lock().unwrap();
            let reads = self.notification_reads.lock().unwrap();
            for id in notifications {
                if acknowledged.contains(id) || unknown.contains(id) {
                    continue;
                }
                match ledger.iter().find(|entry| &entry.id == id) {
                    Some(entry) => {
                        let mut read_by = reads.get(id).cloned().unwrap_or_default();
                        read_by.insert(client_id.to_string());
                        let read_by = read_by.into_iter().collect::<Vec<_>>();
                        let value = self.notification_snapshot_value(entry, &session_id, &read_by);
                        deltas.push(serde_json::json!({
                            "kind":"upsert",
                            "sequence":0,
                            "resource":"notification",
                            "id":id,
                            "value":value,
                        }));
                        acknowledged.push(id.clone());
                    }
                    None => unknown.push(id.clone()),
                }
            }
        }
        let result = serde_json::json!({
            "client_id": client_id,
            "acknowledged": acknowledged,
            "unknown": unknown,
        });
        let commit = registry.commit_notification_ack(
            mutation,
            &fingerprint,
            expected_revision,
            client_id,
            &acknowledged,
            now_ms(),
            &result,
            &Value::Array(deltas),
        )?;
        if !commit.replayed {
            {
                let mut reads = self.notification_reads.lock().unwrap();
                for id in &acknowledged {
                    reads.entry(id.clone()).or_default().insert(client_id.to_string());
                }
            }
            self.state.lock().unwrap().resource_revision = commit.revision;
        }
        drop(registry);
        if !commit.replayed {
            self.publish_resource_event();
        }
        Ok(commit)
    }

    /// Remove retained notifications, for one terminal or the whole session.
    /// This is the source-of-truth form of a local `cmux notify --clear`: the
    /// rows leave the ledger, their durable receipts are masked by a clear
    /// record, every client receives a delete delta, and the console marker
    /// for the terminal is dropped.
    pub(crate) fn clear_notifications(
        &self,
        mutation: &WorkspaceMutation,
        expected_revision: Option<u64>,
        terminal_id: Option<&TerminalPublicId>,
    ) -> anyhow::Result<ResourcePatchCommit> {
        const OPERATION: &str = "notification.clear";
        let fingerprint = serde_json::json!({
            "operation": OPERATION,
            "terminal_id": terminal_id,
        });
        let mut registry = self.workspace_registry.lock().unwrap();
        if let Some(replay) = registry.replay_resource_patch(mutation, OPERATION, &fingerprint)? {
            return Ok(replay);
        }
        let candidates: Vec<NotificationPublicId> = {
            let ledger = self.notification_ledger.lock().unwrap();
            ledger
                .iter()
                .filter(|entry| {
                    terminal_id.is_none_or(|wanted| entry.terminal_id.as_ref() == Some(wanted))
                })
                .map(|entry| entry.id.clone())
                .collect()
        };
        // Only durably committed rows are cleared. A row whose create receipt
        // is still in flight stays, so the clear cannot mask a receipt that
        // commits after it (the registry lock held here serializes the two).
        let cleared = registry.committed_notification_ids(&candidates)?;
        let deltas = cleared
            .iter()
            .map(|id| {
                serde_json::json!({
                    "kind":"delete",
                    "sequence":0,
                    "resource":"notification",
                    "id":id,
                })
            })
            .collect::<Vec<_>>();
        let result = serde_json::json!({ "cleared": cleared });
        let commit = registry.commit_notification_clear(
            mutation,
            &fingerprint,
            expected_revision,
            &cleared,
            &result,
            &Value::Array(deltas),
        )?;
        if !commit.replayed {
            {
                let mut ledger = self.notification_ledger.lock().unwrap();
                ledger.retain(|entry| !cleared.contains(&entry.id));
            }
            {
                let mut reads = self.notification_reads.lock().unwrap();
                for id in &cleared {
                    reads.remove(id);
                }
            }
            match terminal_id {
                Some(terminal_id) => {
                    self.terminal_notifications.lock().unwrap().remove(terminal_id);
                }
                None => {
                    self.terminal_notifications.lock().unwrap().clear();
                    self.placement_notifications.lock().unwrap().clear();
                }
            }
            self.state.lock().unwrap().resource_revision = commit.revision;
        }
        drop(registry);
        if !commit.replayed {
            self.emit(MuxEvent::TreeChanged);
            self.publish_resource_event();
        }
        Ok(commit)
    }

    pub fn report_agent(
        &self,
        surface: SurfaceId,
        state: AgentState,
        source: AgentSource,
        session: Option<String>,
    ) -> anyhow::Result<AgentRecord> {
        self.report_agent_with_sequence_lock(
            surface,
            state,
            source,
            session,
            false,
            None,
            None,
            AgentReportOrigin::Direct,
            None,
        )
    }

    // Keep the sequence lock, hook fence, and origin explicit at this
    // internal transaction boundary. Grouping them into a bag would hide the
    // lock-order contract that protects journal replay.
    #[allow(clippy::too_many_arguments)]
    fn report_agent_with_sequence_lock(
        &self,
        surface: SurfaceId,
        state: AgentState,
        source: AgentSource,
        session: Option<String>,
        sequence_lock_held: bool,
        hook_state: Option<crate::workspace_registry::AgentHookProjectionState>,
        journal_sequence: Option<u64>,
        origin: AgentReportOrigin,
        agent_adapter: Option<String>,
    ) -> anyhow::Result<AgentRecord> {
        let mutation = WorkspaceMutation::daemon(
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
            sequence_lock_held,
            hook_state.as_ref(),
            journal_sequence,
            origin,
            agent_adapter,
        )?;
        let record = record.context("fresh raw agent report unexpectedly replayed")?;
        if source != AgentSource::Hook {
            // A successful report means this terminal is available. Retry only
            // durable hooks for that terminal, never the entire pending table.
            let _ = self.retry_pending_agent_hooks_for_terminal(&record.terminal_id);
        }
        Ok(record)
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
        let result = self.commit_agent_report(
            AgentReportTarget::Resource { selectors: &selectors, terminal_id },
            agent_state,
            source,
            source_session,
            expected_revision,
            mutation,
            &fingerprint,
            false,
            None,
            None,
            AgentReportOrigin::Direct,
            None,
        );
        if result.is_ok() && source != AgentSource::Hook {
            let _ = self.retry_pending_agent_hooks_for_terminal(terminal_id);
        }
        result.map(|(commit, _)| commit)
    }

    /// Commit one agent report as the terminal's durable projection and
    /// publish its upsert or delete. Hook reports carry the agent's native
    /// session id into `extra.agent_session_id`.
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
        sequence_lock_held: bool,
        hook_state: Option<&crate::workspace_registry::AgentHookProjectionState>,
        journal_sequence: Option<u64>,
        origin: AgentReportOrigin,
        agent_adapter: Option<String>,
    ) -> anyhow::Result<(ResourcePatchCommit, Option<AgentRecord>)> {
        // Hook replay already owns this guard to serialize sequence checks and
        // projection commits. Other report sources acquire it before the
        // registry/state locks, so all paths use one lock order.
        let mut sequence_guard =
            (!sequence_lock_held).then(|| self.agent_hook_fences.lock().unwrap());
        let mut registry = self.workspace_registry.lock().unwrap();
        if let Some(replay) =
            registry.replay_resource_patch(mutation, "agent.report", fingerprint)?
        {
            if let Some(sequence) = journal_sequence {
                // The projection transaction committed before this replay was
                // observed. Repair the durable apply watermark separately.
                registry.advance_agent_hook_apply_cursor(sequence)?;
            }
            return Ok((replay, None));
        }
        let mut state = self.state.lock().unwrap();
        let (surface, terminal_id) = match target {
            AgentReportTarget::Surface(surface) => {
                let runtime = state
                    .surfaces
                    .get(&surface)
                    .or_else(|| state.terminal_runtime_by_id(surface))
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
                    .placements_of_content(&ContentPublicId::Terminal((*terminal_id).clone()))
                    .first()
                    .copied()
                    .or_else(|| state.terminal_catalog.get(terminal_id).map(|surface| surface.id))
                    .with_context(|| format!("unknown terminal {terminal_id}"))?;
                (surface, (*terminal_id).clone())
            }
        };
        let mut direct_hook_state = None;
        if source != AgentSource::Hook {
            let ended_fence = sequence_guard
                .as_ref()
                .and_then(|guard| guard.get(&terminal_id))
                .filter(|fence| fence.ended);
            let fresh_session = source_session.as_deref().filter(|session| {
                !session.starts_with("cmux-hook-sequence:")
                    && !session.starts_with("cmux-hook-ended:")
            });
            if ended_fence.is_some_and(|fence| {
                fresh_session.is_none_or(|session| session == fence.session_id)
            }) {
                anyhow::bail!("agent_session_ended");
            }
        } else if hook_state.is_none()
            && let Some(fence) = sequence_guard.as_ref().and_then(|guard| guard.get(&terminal_id))
        {
            match fence
                .direct_transition(source_session.as_deref())
                .map_err(|rejection| anyhow::anyhow!(rejection.as_str()))?
            {
                DirectHookTransition::Continue => {}
                DirectHookTransition::Restart(agent_session_id) => {
                    let restarted =
                        HookFence::next(Some(fence), agent_session_id, fence.sequence, false, None);
                    direct_hook_state = Some(crate::workspace_registry::AgentHookProjectionState {
                        agent_session_id: restarted.session_id,
                        applied_sequence: restarted.sequence,
                        ended: false,
                        ended_at_ms: restarted.ended_at_ms,
                    });
                }
            }
        }
        let effective_hook_state = direct_hook_state.as_ref().or(hook_state);
        let persisted_source_session = if source == AgentSource::Hook {
            source_session.clone().filter(|value| {
                !value.starts_with("cmux-hook-sequence:") && !value.starts_with("cmux-hook-ended:")
            })
        } else {
            if source_session.as_deref().is_some_and(|value| {
                value.starts_with("cmux-hook-sequence:") || value.starts_with("cmux-hook-ended:")
            }) {
                anyhow::bail!("reserved hook marker is invalid for non-hook agent source");
            }
            // Preserve a valid fresh socket identity. The internal hook
            // marker is only a compatibility fallback when no identity was
            // supplied, while durable hook state carries the fence itself.
            source_session.clone().or_else(|| {
                sequence_guard
                    .as_ref()
                    .and_then(|guard| guard.get(&terminal_id))
                    .map(|fence| format!("cmux-hook-sequence:{}", fence.sequence))
            })
        };
        let source_session = source_session.filter(|value| {
            !value.starts_with("cmux-hook-sequence:") && !value.starts_with("cmux-hook-ended:")
        });
        let now = now_ms();
        let mut records = self.agent_records.lock().unwrap();
        // Hook and plugin observations are stronger agent truth than a direct
        // socket report. Check the durable projection as well as the
        // in-memory cache so arbitration survives a restart.
        let durable_stronger =
            registry.public_agent_projections(Some(&terminal_id), None)?.into_iter().next().filter(
                |projection| {
                    (projection.source == AgentSource::Hook.as_str()
                        || projection.source == AgentSource::Plugin.as_str()
                        || projection.source == AgentSource::Detected.as_str())
                        && projection.state != AgentState::Done.as_str()
                        && source == AgentSource::Socket
                },
            );
        let socket_report_ignored = source == AgentSource::Socket
            && !effective_hook_state.is_some_and(|state| state.ended)
            && (records.get(&terminal_id).is_some_and(|existing| {
                existing.source == AgentSource::Hook
                    || existing.source == AgentSource::Detected
                    || existing.source == AgentSource::Plugin
            }) || durable_stronger.is_some());
        let agent_adapter = agent_adapter
            .or_else(|| records.get(&terminal_id).and_then(|record| record.agent.clone()));
        // Only hook-owned records carry the native session id: the journal
        // or restart state for this report, else the live fence it continues.
        let hook_session_id = if source == AgentSource::Hook {
            effective_hook_state.map(|state| state.agent_session_id.clone()).or_else(|| {
                sequence_guard
                    .as_ref()
                    .and_then(|guard| guard.get(&terminal_id))
                    .filter(|fence| !fence.ended)
                    .map(|fence| fence.session_id.clone())
            })
        } else {
            None
        };
        let agent_session_id = hook_session_id
            .and_then(|session_id| published_agent_session_id(&terminal_id, &session_id));
        let record = match records.get(&terminal_id) {
            Some(existing) if socket_report_ignored => existing.clone(),
            None if socket_report_ignored => match durable_stronger {
                Some(existing) => TerminalAgentRecord {
                    state: parse_projection_agent_state(&existing.state),
                    source: if existing.source == AgentSource::Plugin.as_str() {
                        AgentSource::Plugin
                    } else if existing.source == AgentSource::Detected.as_str() {
                        AgentSource::Detected
                    } else {
                        AgentSource::Hook
                    },
                    session: existing.source_session,
                    agent: existing.agent,
                    agent_session_id: existing.agent_session_id,
                    updated_at_ms: existing.updated_at_ms,
                },
                None => TerminalAgentRecord {
                    state: agent_state,
                    source,
                    session: source_session,
                    agent: agent_adapter,
                    agent_session_id,
                    updated_at_ms: now,
                },
            },
            _ => TerminalAgentRecord {
                state: agent_state,
                source,
                session: source_session,
                agent: agent_adapter,
                agent_session_id,
                updated_at_ms: now,
            },
        };
        // A socket report that is intentionally ignored by the hook-owned
        // record must persist that effective record, not the discarded socket
        // identity. Otherwise durable and in-memory projections diverge.
        let persisted_source_session =
            if socket_report_ignored { record.session.clone() } else { persisted_source_session };
        let digest = Sha256::digest(format!("cmux.protocol/2/agent/{terminal_id}").as_bytes());
        let payload = digest[..16].iter().map(|byte| format!("{byte:02x}")).collect::<String>();
        let agent_id =
            AgentPublicId::parse(format!("agent_{payload}")).map_err(anyhow::Error::new)?;
        let session_id = registry.session_id().clone();
        let extra = crate::workspace_registry::agent_projection_extra(
            record.agent.as_deref(),
            record.agent_session_id.as_deref(),
        );
        let value = serde_json::json!({
            "id":agent_id,
            "session_id":session_id,
            "terminal_id":terminal_id,
            "state":record.state.as_str(),
            "source":record.source.as_str(),
            "updated_at_ms":record.updated_at_ms.to_string(),
            "source_session":persisted_source_session.as_deref().or(record.session.as_deref()),
            "extra":extra,
        });
        let mut public_value = value.clone();
        public_value["source_session"] = serde_json::json!(record.session.as_deref());
        let deltas = if effective_hook_state.is_some_and(|state| state.ended) {
            serde_json::json!([{
                "kind":"delete",
                "sequence":0,
                "resource":"agent",
                "id":agent_id,
            }])
        } else {
            serde_json::json!([{
                "kind":"upsert",
                "sequence":0,
                "resource":"agent",
                "id":agent_id,
                "value":public_value,
            }])
        };
        let commit = registry.commit_agent_projection_with_hook_state(
            mutation,
            fingerprint,
            expected_revision,
            &terminal_id,
            &value,
            &deltas,
            effective_hook_state,
            journal_sequence,
        )?;
        if !commit.replayed
            && let (Some(direct_state), Some(sequence_guard)) =
                (direct_hook_state.as_ref(), sequence_guard.as_mut())
        {
            sequence_guard.insert(
                terminal_id.clone(),
                HookFence {
                    session_id: direct_state.agent_session_id.clone(),
                    sequence: direct_state.applied_sequence,
                    ended: false,
                    ended_at_ms: direct_state.ended_at_ms,
                },
            );
        }
        records.insert(terminal_id.clone(), record.clone());
        drop(records);
        state.resource_revision = commit.revision;
        drop(state);
        drop(registry);
        drop(sequence_guard);
        let agent = AgentRecord {
            surface,
            terminal_id,
            state: record.state,
            source: record.source,
            session: record.session,
            agent: record.agent,
            updated_at_ms: record.updated_at_ms,
        };
        if !commit.replayed {
            self.publish_resource_event();
            self.emit(MuxEvent::AgentChanged {
                surface: agent.surface,
                state: Arc::from(agent.state.as_str()),
                source: Arc::from(agent.source.as_str()),
                session: agent.session.as_deref().map(Arc::from),
                agent: agent.agent.as_deref().map(Arc::from),
                updated_at_ms: agent.updated_at_ms,
            });
            if origin == AgentReportOrigin::Direct {
                // The roster only folds journal events, so a direct report
                // records its intent in the log; the fold recognizes the
                // echo adapter and applies it roster-only.
                self.append_agent_report_echo(
                    &agent.terminal_id,
                    agent.state,
                    agent.source,
                    agent.session.as_deref(),
                    agent.updated_at_ms,
                );
            }
        }
        Ok((commit, Some(agent)))
    }

    /// Drop per-surface metadata for a surface that has left the tree.
    /// `SurfaceId` is monotonic, so without this every closed tab would
    /// leak an entry forever and `list-agents` would keep reporting dead
    /// surfaces as live agents.
    fn purge_surface_side_tables(&self, surface: SurfaceId) {
        let _lifecycle = self.lock_client_sizing_lifecycle();
        let mut sizing = self.client_sizing.lock().unwrap();
        sizing.surfaces.remove(&surface);
        sizing.report_order.retain(|(reported_surface, _), _| *reported_surface != surface);
        sizing.policies.remove(&surface);
        sizing.terminal_runtime_by_placement.remove(&surface);
        // Views of a closed placement leave their runtime's engine; the
        // engine itself lives while another placement still shows it.
        let runtimes = sizing.terminal_sizing.keys().copied().collect::<Vec<_>>();
        for runtime in runtimes {
            let Some(entry) = sizing.terminal_sizing.get_mut(&runtime) else { continue };
            if !entry.placements.remove(&surface) {
                continue;
            }
            let departed = entry
                .members
                .iter()
                .filter(|(_, member)| member.placement == surface)
                .map(|(id, _)| id.clone())
                .collect::<Vec<_>>();
            let mut changed = false;
            for id in departed {
                entry.members.remove(&id);
                changed |= entry.engine.detach(&id);
            }
            if entry.placements.is_empty() {
                sizing.terminal_sizing.remove(&runtime);
                sizing.terminal_size_policies.remove(&runtime);
            } else {
                sizing.note_size_state(runtime, changed);
                self.apply_terminal_grid(&sizing, runtime);
            }
        }
        drop(sizing);
        self.publish_size_states();
        self.placement_notifications.lock().unwrap().remove(&surface);
        self.control_clients.forget_surface_attach_epoch(surface);
    }

    fn purge_terminal_side_tables(&self, terminal_id: &TerminalPublicId) {
        let pending_cleanup = {
            let mut registry = self.workspace_registry.lock().unwrap();
            registry.purge_agent_hook_pending_for_terminal(terminal_id)
        };
        if pending_cleanup.is_err() {
            self.report_internal_diagnostic("terminal agent hook cleanup deferred");
        }
        // The registry guard is dropped before acquiring the fence guard.
        self.agent_hook_fences.lock().unwrap().remove(terminal_id);
        self.agent_records.lock().unwrap().remove(terminal_id);
        // Terminal lifecycle does not flow through `agent.*` journal events
        // yet, so a closed terminal retires its roster entry explicitly.
        // The snapshot persists so a restart does not resurrect the entry;
        // the roster lock is released before the registry lock per the
        // host's lock-ordering rule.
        let retired = {
            let mut host = self.agent_roster.lock().unwrap();
            let retired = host.roster.retire_terminal(terminal_id.as_str());
            retired.then(|| (host.cursor, host.roster.snapshot().to_string()))
        };
        if let Some((cursor, snapshot)) = retired
            && let Err(error) = self.workspace_registry.lock().unwrap().put_journal_reducer_state(
                crate::journal_reducers::AGENT_ROSTER_REDUCER_ID,
                crate::journal_reducers::AGENT_ROSTER_REDUCER_VERSION,
                cursor,
                &snapshot,
            )
        {
            eprintln!("cmux-tui: persisting the agent roster snapshot failed: {error}");
        }
        self.terminal_notifications.lock().unwrap().remove(terminal_id);
    }

    fn purge_terminal_runtime_side_tables(&self, runtime: &Surface) {
        if let Some(runtime_id) = runtime.terminal_runtime_id() {
            self.reserved_in_process_terminals.lock().unwrap().remove(&runtime_id);
            let _cell_pixel_lifecycle = self.cell_pixel_lifecycle.lock().unwrap();
            let mut pending = self.pending_cell_pixels.lock().unwrap();
            if let Some(update) = pending.as_mut() {
                update.failures.remove(&runtime_id);
                if update.failures.is_empty() {
                    let target = update.target;
                    *self.cell_pixels.lock().unwrap() = target;
                    *pending = None;
                }
            }
        }
        if let Some(terminal_id) = runtime.terminal_public_id() {
            #[cfg(unix)]
            self.image_pastes.close_terminal(terminal_id.as_str());
            self.purge_terminal_side_tables(terminal_id);
        }
    }

    pub fn list_agents(
        &self,
        surface: Option<SurfaceId>,
        state: Option<AgentState>,
    ) -> Vec<AgentRecord> {
        let entries = self.agent_roster.lock().unwrap().roster.entries.clone();
        let state_snapshot = self.state.lock().unwrap();
        let requested_terminal = surface.and_then(|surface| {
            state_snapshot
                .surfaces
                .get(&surface)
                .or_else(|| state_snapshot.terminal_runtime_by_id(surface))
                .and_then(|surface| surface.terminal_public_id().cloned())
        });
        let mut records = entries
            .into_iter()
            .filter_map(|(terminal_id, entry)| {
                let terminal_id = TerminalPublicId::parse(terminal_id).ok()?;
                // A terminal without a runtime runs no agent: its tabs are
                // dead (a host loss keeps them, invariant 3) or kept.
                state_snapshot.terminal_catalog.get(&terminal_id)?;
                let representative = state_snapshot
                    .placements_of_content(&ContentPublicId::Terminal(terminal_id.clone()))
                    .first()
                    .copied()
                    .or_else(|| {
                        state_snapshot.terminal_catalog.get(&terminal_id).map(|surface| surface.id)
                    })?;
                Some(AgentRecord {
                    surface: representative,
                    terminal_id,
                    state: entry.agent_state(),
                    source: entry.agent_source(),
                    session: entry.session,
                    agent: entry.agent,
                    updated_at_ms: entry.updated_at_ms,
                })
            })
            .collect::<Vec<_>>();
        records.sort_by(|left, right| left.terminal_id.as_str().cmp(right.terminal_id.as_str()));
        records
            .into_iter()
            .filter(|record| {
                requested_terminal
                    .as_ref()
                    .is_none_or(|terminal_id| &record.terminal_id == terminal_id)
            })
            .filter(|record| state.is_none_or(|state| record.state == state))
            .collect()
    }

    pub fn shutdown(&self) {
        self.shutting_down.store(true, Ordering::Release);
        self.begin_session_shutdown();
        // Hosts of closed terminals were already asked to exit; give them
        // their close deadline so this owner acknowledges their exits.
        if !self.wait_for_terminal_host_closes(
            TERMINAL_HOST_CLOSE_WAIT,
            Instant::now() + TERMINAL_HOST_CLOSE_WAIT,
        ) {
            eprintln!("cmux-tui: closed terminal hosts did not exit before shutdown");
        }
        self.config_reload_changed.notify_all();
        self.journal_plugin.shutdown();
        self.journal_kernel.wake_waiters();
        let hook_deadline = Instant::now() + crate::journal_hooks::SHUTDOWN_WAIT;
        if !self.journal_hook_runtime.shutdown_until(hook_deadline) {
            eprintln!("cmux-tui: journal hook workers did not stop before the shutdown deadline");
        }
        self.finalize_terminal_journal("shutdown");
        self.journal_kernel.shutdown();
        if let Some(runtime) = self.browser_runtime.lock().unwrap().take() {
            runtime.shutdown();
        }
    }

    fn finalize_terminal_journal(&self, context: &str) {
        if self.journal_ingress.is_closed() {
            if let Err(error) = self.journal_ingress.close_and_join() {
                eprintln!("cmux-tui: await session journal writer during {context}: {error:#}");
            }
            return;
        }
        // Finalization can run while unwinding from a failed operation. A
        // panic while holding the state lock poisons it, but cleanup must not
        // panic again (for example, when a test simulates a daemon crash).
        let surfaces =
            unique_surface_runtimes(&self.state.lock().unwrap_or_else(PoisonError::into_inner));
        let terminal_reader_deadline = Instant::now() + TERMINAL_READER_SHUTDOWN_TIMEOUT;
        let mut terminal_gaps = surfaces
            .iter()
            .filter_map(|surface| surface.shutdown_for_daemon(terminal_reader_deadline))
            .collect::<Vec<_>>();
        for surface in surfaces {
            terminal_gaps.extend(surface.finish_terminal_reader(terminal_reader_deadline));
        }
        if self.journal_ingress.is_current_writer_thread() {
            if !terminal_gaps.is_empty() {
                eprintln!(
                    "cmux-tui: {context} on the session journal writer could not durably record \
                     {} terminal output gap(s)",
                    terminal_gaps.len()
                );
            }
            if let Err(error) = self.journal_ingress.close_and_join() {
                eprintln!("cmux-tui: stop session journal writer during {context}: {error:#}");
            }
            return;
        }
        for gap in terminal_gaps {
            if let Err(error) = self.journal_ingress.send_durable(
                crate::journal_ingress::JournalIngressEvent::TerminalOutputGap {
                    terminal_id: gap.terminal_id,
                    generation: gap.generation,
                    occurred_at_ms: crate::workspace_registry::unix_epoch_ms().unwrap_or(0),
                    reason: gap.reason,
                },
            ) {
                eprintln!("cmux-tui: record terminal output gap during {context}: {error:#}");
            }
        }
        // Each terminal reader has drained or its journal capture gate has
        // closed. An update that exceeded the extra active-update grace has a
        // durable gap above. Fence the terminal ingress lane while this Mux
        // still owns the registry; the closed gate prevents a timed-out reader
        // from inserting output after the barrier.
        if let Err(error) = self.flush_terminal_journal() {
            eprintln!("cmux-tui: flush terminal journal during {context}: {error:#}");
        }
        if let Err(error) = self.journal_ingress.close_and_join() {
            eprintln!("cmux-tui: stop session journal writer during {context}: {error:#}");
        }
    }

    /// Publish that every owner needed by canonical server lifecycle commands
    /// is installed. Ordinary control clients may connect before this point.
    pub fn mark_server_lifecycle_ready(&self) {
        self.server_lifecycle_ready.store(true, Ordering::Release);
    }

    pub fn server_lifecycle_ready(&self) -> bool {
        self.server_lifecycle_ready.load(Ordering::Acquire)
    }

    /// Validate the target daemon and atomically reserve its handoff. Unless
    /// forced, this proves no other native browser owns the mux. New control
    /// clients and native-browser ownership changes are rejected until the
    /// reservation is cancelled or shutdown completes.
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
        self.control_clients.begin_daemon_handoff(requesting_client, request.force)?;
        Ok(actual_identity)
    }

    pub(crate) fn commit_daemon_handoff_after_ack(
        &self,
        requesting_client: u64,
        acknowledge: impl FnOnce() -> std::io::Result<()>,
    ) -> anyhow::Result<()> {
        self.control_clients.commit_daemon_handoff_after_ack(requesting_client, acknowledge)
    }

    pub(crate) fn daemon_handoff_in_progress(&self) -> bool {
        self.control_clients.daemon_handoff_in_progress()
    }

    /// The handoff was acknowledged to its requester; it can no longer be
    /// cancelled.
    pub(crate) fn daemon_handoff_committed(&self) -> bool {
        self.control_clients.daemon_handoff_committed()
    }

    pub fn cancel_daemon_handoff(&self, requesting_client: u64) {
        self.control_clients.cancel_daemon_handoff(requesting_client);
    }

    /// Ask the owning frontend loop to leave through the normal daemon
    /// shutdown path. Durable terminal hosts are disconnected by `shutdown`
    /// and remain available for the replacement daemon to adopt.
    pub fn request_daemon_shutdown(&self) {
        self.shutting_down.store(true, Ordering::Release);
        self.begin_session_shutdown();
        // The journal hook dispatcher waits on the shared journal.
        self.journal_kernel.wake_waiters();
        if let Some(waker) = self.daemon_shutdown_waker.lock().unwrap().as_ref() {
            waker();
        }
    }

    /// Install the callback that `request_daemon_shutdown` runs after it
    /// sets the flag (the headless owner loop's wake).
    pub fn set_daemon_shutdown_waker(&self, waker: impl Fn() + Send + Sync + 'static) {
        *self.daemon_shutdown_waker.lock().unwrap() = Some(Box::new(waker));
    }

    pub fn daemon_shutdown_requested(&self) -> bool {
        self.shutting_down.load(Ordering::Acquire)
    }

    /// Update options used for future surface/browser launches.
    pub fn update_surface_options(&self, update: impl FnOnce(&mut SurfaceOptions)) {
        let mut options = self.surface_options.lock().unwrap();
        update(&mut options);
    }

    /// The latest machine-level model spend readout, or `None` when the
    /// daemon has no usable readout.
    pub fn machine_usage(&self) -> Option<MachineUsage> {
        self.machine_usage.lock().unwrap().clone()
    }

    /// Replace the machine-level spend readout. Subscribers are told only
    /// when the readout actually changed, so a steady poll stays silent.
    pub fn set_machine_usage(&self, usage: Option<MachineUsage>) {
        {
            let mut current = self.machine_usage.lock().unwrap();
            if *current == usage {
                return;
            }
            *current = usage.clone();
        }
        self.emit(MuxEvent::MachineUsageChanged(usage));
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
        if let Some(surface) =
            old_surface.and_then(|id| self.state.lock().unwrap().surfaces.remove(&id))
        {
            surface.kill();
            self.emit(MuxEvent::SurfaceExited(surface.id));
        }
    }

    pub fn ensure_sidebar_plugin(
        self: &Arc<Self>,
        cols: u16,
        rows: u16,
        relaunch: bool,
    ) -> SidebarPluginStatus {
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
        if let Some(surface) =
            old_surface.and_then(|id| self.state.lock().unwrap().surfaces.remove(&id))
        {
            self.purge_surface_side_tables(surface.id);
            surface.kill();
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

    pub fn set_cell_pixel_size(self: &Arc<Self>, width_px: u16, height_px: u16) -> CellPixelUpdate {
        self.set_cell_pixel_size_reporting(width_px, height_px, Arc::new(|_, _, _| {}))
    }

    pub fn cell_pixel_size(&self) -> (u16, u16) {
        *self.cell_pixels.lock().unwrap()
    }

    pub(crate) fn claim_render_attachment(&self) -> Option<RenderAttachmentPermit> {
        self.active_render_attachments
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |active| {
                (active < RENDER_ATTACHMENT_LIMIT).then_some(active + 1)
            })
            .ok()?;
        Some(RenderAttachmentPermit { active: self.active_render_attachments.clone() })
    }

    /// Reserve a Kitty image budget entry that owns no quota yet, without
    /// waiting. For a host launched ahead of its creation
    /// (`terminal_work`): an uncommitted entry cannot shrink when later
    /// reservations do, so owning quota before the commit would make every
    /// concurrent launch wait on it. The committed surface is promoted to a
    /// quota owner and the budget worker applies its limits then.
    pub(crate) fn reserve_kitty_image_surface_without_quota(
        self: &Arc<Self>,
        surface: SurfaceId,
    ) -> anyhow::Result<KittyImageBudgetReservation> {
        let mut budget = self.kitty_image_budget.lock().unwrap();
        Self::prune_dead_kitty_image_surfaces(&mut budget);
        anyhow::ensure!(
            !budget.entries.contains_key(&surface),
            "Kitty image budget already reserved for surface {surface}"
        );
        budget.entries.insert(
            surface,
            KittyImageBudgetEntry {
                surface: None,
                applied: KittyGraphicsLimits::disabled(),
                owns_quota: false,
                removing: false,
            },
        );
        Ok(KittyImageBudgetReservation {
            mux: Arc::downgrade(self),
            surface,
            initial_limits: KittyGraphicsLimits::disabled(),
            committed: false,
        })
    }

    fn commit_kitty_image_surface(
        self: &Arc<Self>,
        id: SurfaceId,
        surface: &Arc<Surface>,
        applied: KittyGraphicsLimits,
    ) -> anyhow::Result<()> {
        {
            let mut budget = self.kitty_image_budget.lock().unwrap();
            let entry = budget
                .entries
                .get_mut(&id)
                .ok_or_else(|| anyhow::anyhow!("Kitty image budget reservation disappeared"))?;
            anyhow::ensure!(
                entry.surface.is_none() && !entry.removing,
                "Kitty image budget reservation is no longer pending"
            );
            entry.surface = Some(Arc::downgrade(surface));
            entry.applied = applied;
            Self::rebalance_kitty_image_budget_owners(&mut budget);
        }
        self.start_kitty_image_budget_worker();
        Ok(())
    }

    fn cancel_kitty_image_surface_reservation(self: &Arc<Self>, id: SurfaceId) {
        {
            let mut budget = self.kitty_image_budget.lock().unwrap();
            if budget.entries.get(&id).is_some_and(|entry| entry.surface.is_none()) {
                budget.entries.remove(&id);
                Self::rebalance_kitty_image_budget_owners(&mut budget);
            }
        }
        self.kitty_image_budget_changed.notify_all();
        self.start_kitty_image_budget_worker();
    }

    pub(crate) fn unregister_kitty_image_surface(
        self: &Arc<Self>,
        surface: &Surface,
    ) -> anyhow::Result<()> {
        let runtime_id = surface.terminal_runtime_id().unwrap_or(surface.id);
        {
            let mut budget = self.kitty_image_budget.lock().unwrap();
            let removed_current_surface = budget
                .entries
                .get(&runtime_id)
                .and_then(|entry| entry.surface.as_ref())
                .and_then(Weak::upgrade)
                .is_some_and(|registered| std::ptr::eq(registered.as_ref(), surface));
            if removed_current_surface {
                budget.entries.remove(&runtime_id);
                budget.blocked_surfaces.remove(&runtime_id);
                Self::rebalance_kitty_image_budget_owners(&mut budget);
            }
        }
        self.kitty_image_budget_changed.notify_all();
        self.start_kitty_image_budget_worker();
        Ok(())
    }

    pub(crate) fn resource_terminal_host_identity(
        &self,
        surface: &Surface,
    ) -> Option<TerminalHostIdentity> {
        surface.terminal_host_identity().or_else(|| {
            let runtime = surface.terminal_runtime_id()?;
            self.reserved_in_process_terminals.lock().unwrap().get(&runtime).cloned()
        })
    }

    fn catalog_terminal_by_host(
        &self,
        state: &State,
        terminal_id: &str,
    ) -> anyhow::Result<Option<Arc<Surface>>> {
        unique_terminal_match(
            terminal_id,
            state.terminal_catalog.values().filter_map(|surface| {
                self.resource_terminal_host_identity(surface)
                    .map(|identity| (surface.clone(), identity))
            }),
        )
        .map(|matched| matched.map(|(surface, _)| surface))
    }

    pub(crate) fn kitty_image_limits_for_reconnect(
        &self,
        surface: &Arc<Surface>,
    ) -> anyhow::Result<KittyGraphicsLimits> {
        let mut budget = self.kitty_image_budget.lock().unwrap();
        Self::prune_dead_kitty_image_surfaces(&mut budget);
        let target = kitty_image_limits_for_capacity(budget.capacity);
        let entry = budget
            .entries
            .get(&surface.id)
            .ok_or_else(|| anyhow::anyhow!("Kitty image budget entry disappeared on reconnect"))?;
        anyhow::ensure!(
            entry
                .surface
                .as_ref()
                .and_then(Weak::upgrade)
                .is_some_and(|registered| Arc::ptr_eq(&registered, surface)),
            "Kitty image budget entry changed ownership on reconnect"
        );
        Ok(if entry.removing || !entry.owns_quota {
            KittyGraphicsLimits::disabled()
        } else {
            target
        })
    }

    fn reconcile_reconnected_kitty_image_surface(
        self: &Arc<Self>,
        surface: &Arc<Surface>,
        applied: KittyGraphicsLimits,
    ) -> bool {
        let reconciled = {
            let mut budget = self.kitty_image_budget.lock().unwrap();
            Self::prune_dead_kitty_image_surfaces(&mut budget);
            let target = kitty_image_limits_for_capacity(budget.capacity);
            let Some(entry) = budget.entries.get_mut(&surface.id) else { return false };
            let owns_entry = entry
                .surface
                .as_ref()
                .and_then(Weak::upgrade)
                .is_some_and(|registered| Arc::ptr_eq(&registered, surface));
            let desired = if entry.removing || !entry.owns_quota {
                KittyGraphicsLimits::disabled()
            } else {
                target
            };
            if !owns_entry || !kitty_image_limits_within(applied, desired) {
                false
            } else {
                entry.applied = applied;
                budget.blocked_surfaces.remove(&surface.id);
                true
            }
        };
        if reconciled {
            self.kitty_image_budget_changed.notify_all();
            self.start_kitty_image_budget_worker();
        }
        reconciled
    }

    fn prune_dead_kitty_image_surfaces(budget: &mut KittyImageBudgetState) {
        budget.entries.retain(|_, entry| {
            entry.surface.as_ref().is_none_or(|surface| surface.strong_count() > 0)
        });
        let live_ids = budget.entries.keys().copied().collect::<HashSet<_>>();
        budget.blocked_surfaces.retain(|id| live_ids.contains(id));
        Self::rebalance_kitty_image_budget_owners(budget);
    }

    fn kitty_image_budget_owner_count(budget: &KittyImageBudgetState) -> usize {
        budget.entries.values().filter(|entry| entry.owns_quota).count()
    }

    fn rebalance_kitty_image_budget_owners(budget: &mut KittyImageBudgetState) {
        let owner_count = Self::kitty_image_budget_owner_count(budget);
        debug_assert!(owner_count <= KITTY_IMAGE_BUDGET_OWNER_LIMIT);
        let available = KITTY_IMAGE_BUDGET_OWNER_LIMIT.saturating_sub(owner_count);
        if budget.blocked_surfaces.is_empty() && available > 0 && owner_count < budget.entries.len()
        {
            let mut candidates = budget
                .entries
                .iter()
                .filter_map(|(&id, entry)| {
                    (!entry.owns_quota
                        && !entry.removing
                        && entry.surface.as_ref().is_some_and(|surface| surface.strong_count() > 0))
                    .then_some(id)
                })
                .collect::<Vec<_>>();
            candidates.sort_unstable();
            for id in candidates.into_iter().take(available) {
                if let Some(entry) = budget.entries.get_mut(&id) {
                    entry.owns_quota = true;
                }
            }
        }
        budget.capacity = kitty_image_budget_capacity(
            Self::kitty_image_budget_owner_count(budget),
            budget.capacity,
        );
    }

    fn start_kitty_image_budget_worker(self: &Arc<Self>) {
        let should_start = {
            let mut budget = self.kitty_image_budget.lock().unwrap();
            Self::prune_dead_kitty_image_surfaces(&mut budget);
            let target = kitty_image_limits_for_capacity(budget.capacity);
            let has_work = budget.entries.values().any(|entry| {
                entry.surface.as_ref().is_some_and(|surface| surface.strong_count() > 0)
                    && entry.applied
                        != if entry.removing || !entry.owns_quota {
                            KittyGraphicsLimits::disabled()
                        } else {
                            target
                        }
            });
            if budget.worker_running || !budget.blocked_surfaces.is_empty() || !has_work {
                false
            } else {
                budget.worker_running = true;
                true
            }
        };
        if !should_start {
            return;
        }
        let mux = Arc::downgrade(self);
        if let Err(error) = std::thread::Builder::new()
            .name("kitty-image-budget".into())
            .spawn(move || Self::run_kitty_image_budget_worker(mux))
        {
            self.kitty_image_budget.lock().unwrap().worker_running = false;
            self.kitty_image_budget_changed.notify_all();
            self.emit(MuxEvent::GraphicsStatus(
                GraphicsStatus::KittyImageBudgetWorkerStartFailed {
                    error: Arc::<str>::from(error.to_string()),
                },
            ));
        }
    }

    fn run_kitty_image_budget_worker(mux: Weak<Self>) {
        let mut failure_streak = 0_u32;
        let mut pending_operations = Vec::<PendingKittyImageBudgetOperation>::new();
        // The last wave's (surface, limits). An identical next wave with no
        // failure means an applied result did not stick (the surface was
        // replaced): treat it as a failure so the retry is spaced instead of
        // re-running the same wave in a hot loop.
        let mut previous_wave = Vec::<(SurfaceId, KittyGraphicsLimits)>::new();
        loop {
            let Some(mux) = mux.upgrade() else { return };
            if mux.shutting_down.load(Ordering::Acquire) {
                let mut budget = mux.kitty_image_budget.lock().unwrap();
                budget.expansion_in_flight = false;
                budget.worker_running = false;
                drop(budget);
                mux.kitty_image_budget_changed.notify_all();
                return;
            }

            let mut failures = Vec::new();
            let mut failed_operations = HashSet::new();
            let mut failed_surface_ids = HashSet::new();
            let mut retained_pending = Vec::new();
            let mut pending_completed = false;
            {
                let mut budget = mux.kitty_image_budget.lock().unwrap();
                for pending in pending_operations.drain(..) {
                    let Some(result) = pending.result.try_take() else {
                        retained_pending.push(pending);
                        continue;
                    };
                    pending_completed = true;
                    match result {
                        Ok(()) => {
                            if let Some(entry) = budget.entries.get_mut(&pending.surface_id)
                                && entry
                                    .surface
                                    .as_ref()
                                    .and_then(Weak::upgrade)
                                    .zip(pending.surface.upgrade())
                                    .is_some_and(|(registered, completed)| {
                                        Arc::ptr_eq(&registered, &completed)
                                    })
                            {
                                entry.applied = pending.limits;
                            }
                        }
                        Err(error) => {
                            failed_operations.insert(pending.surface_id);
                            failed_surface_ids.insert(pending.surface_id);
                            failures.push(format!("surface {}: {error:#}", pending.surface_id));
                        }
                    }
                }
                budget.expansion_in_flight =
                    retained_pending.iter().any(|pending| pending.expanding);
            }
            pending_operations = retained_pending;
            if pending_completed {
                mux.kitty_image_budget_changed.notify_all();
            }

            let pending_ids =
                pending_operations.iter().map(|pending| pending.surface_id).collect::<HashSet<_>>();
            let (tasks, deferred_expansion) = {
                let mut budget = mux.kitty_image_budget.lock().unwrap();
                Self::prune_dead_kitty_image_surfaces(&mut budget);
                let target = kitty_image_limits_for_capacity(budget.capacity);
                let mut tasks = Vec::new();
                for (&id, entry) in &budget.entries {
                    if pending_ids.contains(&id) || failed_operations.contains(&id) {
                        continue;
                    }
                    let Some(surface) = entry.surface.as_ref().and_then(Weak::upgrade) else {
                        continue;
                    };
                    let desired = if entry.removing || !entry.owns_quota {
                        KittyGraphicsLimits::disabled()
                    } else {
                        target
                    };
                    if entry.applied != desired
                        && (entry.removing
                            || !entry.owns_quota
                            || kitty_image_limits_exceed(entry.applied, desired))
                    {
                        tasks.push((id, surface, desired, false));
                    }
                }
                if tasks.is_empty() {
                    budget.entries.retain(|id, entry| {
                        pending_ids.contains(id)
                            || !(entry.removing
                                && (entry.surface.is_none()
                                    || entry.applied == KittyGraphicsLimits::disabled()))
                    });
                    let previous_capacity = budget.capacity;
                    Self::rebalance_kitty_image_budget_owners(&mut budget);
                    if budget.capacity != previous_capacity {
                        continue;
                    }
                    let target = kitty_image_limits_for_capacity(budget.capacity);
                    for (&id, entry) in &budget.entries {
                        if pending_ids.contains(&id) || failed_operations.contains(&id) {
                            continue;
                        }
                        let Some(surface) = entry.surface.as_ref().and_then(Weak::upgrade) else {
                            continue;
                        };
                        if entry.owns_quota && !entry.removing && entry.applied != target {
                            tasks.push((
                                id,
                                surface,
                                target,
                                kitty_image_limits_exceed(target, entry.applied),
                            ));
                        }
                    }
                }
                budget.expansion_in_flight =
                    pending_operations.iter().any(|pending| pending.expanding)
                        || tasks.iter().any(|task| task.3);
                if tasks.is_empty() && pending_operations.is_empty() && failed_operations.is_empty()
                {
                    budget.expansion_in_flight = false;
                    budget.worker_running = false;
                    drop(budget);
                    mux.kitty_image_budget_changed.notify_all();
                    return;
                }
                // The deadline pool deliberately bounds admitted operations.
                // Submit at most one pool-width wave, then recompute desired
                // limits before the next wave so large topology bursts cannot
                // turn ordinary queueing into false saturation failures.
                tasks.sort_unstable_by_key(|task| task.0);
                let deferred_expansion =
                    tasks.iter().skip(CELL_PIXEL_FANOUT_MAX_WORKERS).any(|task| task.3);
                tasks.truncate(CELL_PIXEL_FANOUT_MAX_WORKERS);
                (tasks, deferred_expansion)
            };

            if !tasks.is_empty() {
                let deadline =
                    Instant::now() + crate::terminal_host_runtime::CONTROL_RESPONSE_TIMEOUT;
                let operation_mux = Arc::downgrade(&mux);
                let results = bounded_deadline_map(
                    &mux.deadline_fanout_pool,
                    &tasks,
                    deadline,
                    move |(_, surface, limits, _), deadline| {
                        let Some(mux) = operation_mux.upgrade() else {
                            anyhow::bail!("multiplexer shut down before Kitty quota update");
                        };
                        mux.apply_kitty_image_limits(surface, *limits, deadline)
                    },
                );
                let mut budget = mux.kitty_image_budget.lock().unwrap();
                let mut retry_expansion = false;
                for ((id, surface, limits, expanding), result) in tasks.iter().zip(results) {
                    match result {
                        DeadlineMapResult::Complete(Ok(())) => {
                            if let Some(entry) = budget.entries.get_mut(id)
                                && entry
                                    .surface
                                    .as_ref()
                                    .and_then(Weak::upgrade)
                                    .is_some_and(|registered| Arc::ptr_eq(&registered, surface))
                            {
                                entry.applied = *limits;
                            }
                        }
                        DeadlineMapResult::Complete(Err(error)) => {
                            retry_expansion |= *expanding;
                            failed_surface_ids.insert(*id);
                            failures.push(format!("surface {id}: {error:#}"));
                        }
                        DeadlineMapResult::Pending(result) => {
                            pending_operations.push(PendingKittyImageBudgetOperation {
                                surface_id: *id,
                                surface: Arc::downgrade(surface),
                                limits: *limits,
                                expanding: *expanding,
                                result,
                            });
                        }
                        DeadlineMapResult::Unscheduled => {
                            retry_expansion |= *expanding;
                            failed_surface_ids.insert(*id);
                            failures.push(format!(
                                "surface {id}: update was rejected because the deadline worker \
                                 pool is saturated"
                            ));
                        }
                    }
                }
                budget.expansion_in_flight = deferred_expansion
                    || retry_expansion
                    || pending_operations.iter().any(|pending| pending.expanding);
            }
            for pending in &pending_operations {
                if failed_surface_ids.insert(pending.surface_id) {
                    failures.push(format!(
                        "surface {}: update did not complete before its deadline",
                        pending.surface_id
                    ));
                }
            }
            mux.kitty_image_budget_changed.notify_all();
            let wave = tasks.iter().map(|(id, _, limits, _)| (*id, *limits)).collect::<Vec<_>>();
            if failures.is_empty() && !wave.is_empty() && wave == previous_wave {
                failures.push("Kitty quota update did not converge".to_string());
            }
            previous_wave = wave;
            if failures.is_empty() {
                failure_streak = 0;
                continue;
            }

            failure_streak = failure_streak.saturating_add(1);
            let retry_exhausted = failure_streak >= KITTY_IMAGE_BUDGET_RETRY_MAX_ATTEMPTS;
            // A transient retry is internal recovery. Publishing it as a
            // graphics status overwrites the user's status bar for a routine
            // topology change, even when the next attempt succeeds. Surface
            // only the terminal failure after the retry budget is exhausted.
            if retry_exhausted {
                let omitted = failures.len().saturating_sub(8);
                let mut summary = failures.into_iter().take(8).collect::<Vec<_>>().join("; ");
                if omitted > 0 {
                    summary.push_str(&format!("; {omitted} more"));
                }
                mux.emit(MuxEvent::GraphicsStatus(GraphicsStatus::KittyImageBudgetUpdateFailed {
                    retry_exhausted,
                    summary: Arc::<str>::from(summary),
                }));
            }
            if retry_exhausted {
                let mut budget = mux.kitty_image_budget.lock().unwrap();
                let blocked = failed_surface_ids
                    .into_iter()
                    .filter(|id| budget.entries.contains_key(id))
                    .collect::<Vec<_>>();
                budget.blocked_surfaces.extend(blocked);
                budget.expansion_in_flight = false;
                budget.worker_running = false;
                drop(budget);
                mux.kitty_image_budget_changed.notify_all();
                return;
            }
            let multiplier =
                1_u32.checked_shl(failure_streak.saturating_sub(1).min(16)).unwrap_or(u32::MAX);
            let delay = KITTY_IMAGE_BUDGET_RETRY_INITIAL
                .saturating_mul(multiplier)
                .min(KITTY_IMAGE_BUDGET_RETRY_MAX);
            drop(mux);
            std::thread::sleep(delay);
        }
    }

    fn apply_kitty_image_limits(
        &self,
        surface: &Arc<Surface>,
        limits: KittyGraphicsLimits,
        deadline: Instant,
    ) -> anyhow::Result<()> {
        #[cfg(test)]
        if let Some(operation) = self.kitty_image_budget_operation.lock().unwrap().clone() {
            return operation(surface, limits, deadline);
        }
        surface.set_kitty_graphics_limits_until(limits, deadline)
    }

    #[cfg(test)]
    fn wait_for_kitty_image_budget_idle_for_test(&self, timeout: Duration) -> bool {
        let deadline = Instant::now() + timeout;
        let mut budget = self.kitty_image_budget.lock().unwrap();
        loop {
            let target = kitty_image_limits_for_capacity(budget.capacity);
            let idle = !budget.worker_running
                && budget.entries.values().all(|entry| {
                    entry.surface.is_some()
                        && !entry.removing
                        && entry.applied
                            == if entry.owns_quota {
                                target
                            } else {
                                KittyGraphicsLimits::disabled()
                            }
                });
            if idle {
                return true;
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return false;
            }
            let (next, timed_out) =
                self.kitty_image_budget_changed.wait_timeout(budget, remaining).unwrap();
            budget = next;
            if timed_out.timed_out() && Instant::now() >= deadline {
                return false;
            }
        }
    }

    pub(crate) fn cell_pixel_creation_size(&self) -> (u16, u16) {
        if let Some(target) = self
            .pending_cell_pixels
            .lock()
            .unwrap()
            .as_ref()
            .filter(|pending| pending.use_for_creation)
            .map(|pending| pending.target)
        {
            return target;
        }
        self.cell_pixel_size()
    }

    fn reconcile_surface_cell_pixels_for_publish<'a>(
        &'a self,
        surface: &Arc<Surface>,
    ) -> anyhow::Result<MutexGuard<'a, ()>> {
        loop {
            let lifecycle = self.cell_pixel_lifecycle.lock().unwrap();
            let target = self.cell_pixel_creation_size();
            if surface.cell_pixel_size() == target {
                return Ok(lifecycle);
            }
            drop(lifecycle);
            validate_cell_pixel_convergence(
                surface,
                target,
                surface.set_cell_pixel_size_reporting_until(
                    target.0,
                    target.1,
                    Instant::now() + crate::terminal_host_runtime::CONTROL_RESPONSE_TIMEOUT,
                    Box::new(|_| {}),
                ),
            )?;
        }
    }

    pub(crate) fn reconcile_deferred_cell_pixel_ack(&self, surface: SurfaceId, target: (u16, u16)) {
        let _cell_pixel_lifecycle = self.cell_pixel_lifecycle.lock().unwrap();
        self.reconcile_cell_pixel_ack_locked(surface, target);
    }

    pub(crate) fn submit_deferred_cell_pixel_ack(
        &self,
        task: impl FnOnce() + Send + 'static,
    ) -> bool {
        self.deadline_fanout_pool.submit(Box::new(task))
    }

    fn reconcile_cell_pixel_ack_locked(&self, surface: SurfaceId, target: (u16, u16)) {
        let mut pending = self.pending_cell_pixels.lock().unwrap();
        let Some(update) = pending.as_mut().filter(|update| update.target == target) else {
            return;
        };
        update.failures.remove(&surface);
        if !update.failures.is_empty() {
            return;
        }
        *self.cell_pixels.lock().unwrap() = target;
        *pending = None;
    }

    fn reconcile_cell_pixel_completion_locked(
        &self,
        surface: SurfaceId,
        generation: u64,
        target: (u16, u16),
    ) {
        let mut pending = self.pending_cell_pixels.lock().unwrap();
        let Some(update) = pending
            .as_mut()
            .filter(|update| update.generation == generation && update.target == target)
        else {
            return;
        };
        update.failures.remove(&surface);
        if !update.failures.is_empty() {
            return;
        }
        *self.cell_pixels.lock().unwrap() = target;
        *pending = None;
    }

    fn record_cell_pixel_completion(
        self: &Arc<Self>,
        completion: &Arc<CellPixelCompletionTracker>,
        surface: SurfaceId,
    ) {
        completion.completed.lock().unwrap().insert(surface);
        if completion.publishing.load(Ordering::Acquire) {
            return;
        }
        let _lifecycle = self.cell_pixel_lifecycle.lock().unwrap();
        if completion.completed.lock().unwrap().remove(&surface) {
            self.reconcile_cell_pixel_completion_locked(
                surface,
                completion.generation,
                completion.target,
            );
        }
    }

    fn enqueue_cell_pixel_retries(
        self: &Arc<Self>,
        task: CellPixelRetryTask,
    ) -> std::io::Result<()> {
        let mut retries = self.cell_pixel_retries.lock().unwrap();
        if retries.pending.as_ref().is_some_and(|pending| pending.generation > task.generation) {
            return Ok(());
        }
        retries.pending = Some(task);
        if retries.worker_running {
            return Ok(());
        }
        retries.worker_running = true;
        let mux = Arc::downgrade(self);
        match std::thread::Builder::new()
            .name("cell-pixel-retry".to_string())
            .spawn(move || Self::run_cell_pixel_retry_worker(mux))
        {
            Ok(_) => Ok(()),
            Err(error) => {
                retries.worker_running = false;
                retries.pending = None;
                Err(error)
            }
        }
    }

    fn run_cell_pixel_retry_worker(mux: Weak<Self>) {
        loop {
            let task = {
                let Some(mux) = mux.upgrade() else { return };
                let mut retries = mux.cell_pixel_retries.lock().unwrap();
                if mux.shutting_down.load(Ordering::Acquire) {
                    retries.pending = None;
                    retries.worker_running = false;
                    return;
                }
                match retries.pending.take() {
                    Some(task) => task,
                    None => {
                        retries.worker_running = false;
                        return;
                    }
                }
            };
            if let Some(mut task) = Self::run_cell_pixel_retry_task(&mux, task) {
                task.attempts = task.attempts.saturating_add(1);
                if task.attempts >= CELL_PIXEL_RETRY_MAX_ATTEMPTS {
                    if let Some(mux) = mux.upgrade() {
                        mux.finish_cell_pixel_retries(&task);
                    }
                    continue;
                }
                std::thread::sleep(cell_pixel_retry_delay(task.attempts));
                let Some(mux) = mux.upgrade() else { return };
                let mut retries = mux.cell_pixel_retries.lock().unwrap();
                if retries.pending.is_none() {
                    retries.pending = Some(task);
                }
            }
        }
    }

    fn finish_cell_pixel_retries(&self, task: &CellPixelRetryTask) {
        let remaining = {
            let _cell_pixel_lifecycle = self.cell_pixel_lifecycle.lock().unwrap();
            let mut pending = self.pending_cell_pixels.lock().unwrap();
            let Some(pending) = pending.as_mut().filter(|pending| {
                pending.generation == task.generation && pending.target == task.target
            }) else {
                return;
            };
            pending.use_for_creation = false;
            pending.failures.len()
        };
        self.emit(MuxEvent::GraphicsStatus(GraphicsStatus::CellPixelUpdateRetriesExhausted {
            attempts: task.attempts,
            remaining,
            cell_pixels: task.target,
        }));
    }

    fn run_cell_pixel_retry_task(
        mux: &Weak<Self>,
        task: CellPixelRetryTask,
    ) -> Option<CellPixelRetryTask> {
        let mut retry_candidates = task.surfaces;
        let mut pending_operations = Vec::new();
        for pending in task.pending {
            let Some(result) = pending.result.try_take() else {
                pending_operations.push(pending);
                continue;
            };
            let mux = mux.upgrade()?;
            let _cell_pixel_lifecycle = mux.cell_pixel_lifecycle.lock().unwrap();
            if !mux.pending_cell_pixels.lock().unwrap().as_ref().is_some_and(|update| {
                update.generation == task.generation && update.target == task.target
            }) {
                return None;
            }
            let (surface_id, _, result, deferred) = result;
            match result {
                Ok(_) => mux.reconcile_cell_pixel_completion_locked(
                    surface_id,
                    task.generation,
                    task.target,
                ),
                Err(_) if deferred => {}
                Err(_) => retry_candidates.push(pending.surface),
            }
        }
        let mut unique = HashSet::new();
        retry_candidates
            .retain(|surface| surface.upgrade().is_some_and(|surface| unique.insert(surface.id)));
        let mut remaining = Vec::new();
        for retry_wave in retry_candidates.chunks(CELL_PIXEL_FANOUT_MAX_WORKERS) {
            let mux = mux.upgrade()?;
            let active = {
                let _cell_pixel_lifecycle = mux.cell_pixel_lifecycle.lock().unwrap();
                let pending = mux.pending_cell_pixels.lock().unwrap();
                let pending = pending.as_ref().filter(|pending| {
                    pending.generation == task.generation
                        && pending.target == task.target
                        && !pending.failures.is_empty()
                })?;
                retry_wave
                    .iter()
                    .filter_map(Weak::upgrade)
                    .filter(|surface| pending.failures.contains(&surface.id))
                    .collect::<Vec<_>>()
            };
            let deadline = Instant::now() + task.timeout;
            let report = task.report.clone();
            #[cfg(test)]
            let operation_hook = task.operation_hook.clone();
            let target = task.target;
            let completion = task.completion.clone();
            let completion_mux = Arc::downgrade(&mux);
            let results = bounded_deadline_map(
                &mux.deadline_fanout_pool,
                &active,
                deadline,
                move |surface, deadline| {
                    let result = apply_cell_pixel_size_until(
                        surface,
                        target,
                        deadline,
                        &report,
                        #[cfg(test)]
                        operation_hook.as_ref(),
                    );
                    let completed_at = Instant::now();
                    if completed_at <= deadline
                        && result.2.is_ok()
                        && let Some(mux) = completion_mux.upgrade()
                    {
                        mux.record_cell_pixel_completion(&completion, surface.id);
                    }
                    result
                },
            );
            let _cell_pixel_lifecycle = mux.cell_pixel_lifecycle.lock().unwrap();
            if !mux.pending_cell_pixels.lock().unwrap().as_ref().is_some_and(|pending| {
                pending.generation == task.generation && pending.target == task.target
            }) {
                return None;
            }
            for (surface, result) in active.iter().zip(results) {
                let (surface_id, result, deferred) = match result {
                    DeadlineMapResult::Complete((surface_id, _, result, deferred)) => {
                        (surface_id, Some(result), deferred)
                    }
                    DeadlineMapResult::Pending(result) => {
                        pending_operations.push(PendingCellPixelOperation {
                            surface: Arc::downgrade(surface),
                            result,
                        });
                        continue;
                    }
                    DeadlineMapResult::Unscheduled => {
                        remaining.push(Arc::downgrade(surface));
                        continue;
                    }
                };
                match result.expect("complete deadline result has an operation result") {
                    Ok(_) => mux.reconcile_cell_pixel_completion_locked(
                        surface_id,
                        task.generation,
                        task.target,
                    ),
                    Err(_) if deferred => {}
                    Err(error)
                        if error
                            .downcast_ref::<
                                crate::terminal_host_runtime::CellPixelRequestDeadlineElapsed,
                            >()
                            .is_some() =>
                    {
                        remaining.push(Arc::downgrade(surface));
                    }
                    Err(_) => {
                        if let Some(pending) = mux
                            .pending_cell_pixels
                            .lock()
                            .unwrap()
                            .as_mut()
                            .filter(|pending| {
                                pending.generation == task.generation
                                    && pending.target == task.target
                            })
                        {
                            pending.use_for_creation = false;
                        }
                    }
                }
            }
        }
        let pending_ids = pending_operations
            .iter()
            .filter_map(|pending| pending.surface.upgrade())
            .map(|surface| surface.id)
            .collect::<HashSet<_>>();
        let mut unique = HashSet::new();
        remaining.retain(|surface| {
            surface.upgrade().is_some_and(|surface| {
                !pending_ids.contains(&surface.id) && unique.insert(surface.id)
            })
        });
        (!remaining.is_empty() || !pending_operations.is_empty()).then_some(CellPixelRetryTask {
            surfaces: remaining,
            pending: pending_operations,
            attempts: task.attempts,
            generation: task.generation,
            target: task.target,
            completion: task.completion,
            report: task.report,
            timeout: task.timeout,
            #[cfg(test)]
            operation_hook: task.operation_hook,
        })
    }

    pub fn set_cell_pixel_size_reporting(
        self: &Arc<Self>,
        width_px: u16,
        height_px: u16,
        report: SurfaceResizeReporter,
    ) -> CellPixelUpdate {
        let cell_pixel_lifecycle = self.cell_pixel_lifecycle.lock().unwrap();
        let generation = self.next_cell_pixel_generation.fetch_add(1, Ordering::Relaxed);
        let next = (width_px.max(1), height_px.max(1));
        let completion = Arc::new(CellPixelCompletionTracker {
            generation,
            target: next,
            publishing: AtomicBool::new(true),
            completed: Mutex::new(HashSet::new()),
        });
        let mut surfaces = unique_surface_runtimes(&self.state.lock().unwrap());
        surfaces.sort_unstable_by_key(|surface| surface.id);
        #[cfg(test)]
        let timeout = self
            .cell_pixel_fanout_timeout
            .lock()
            .unwrap()
            .unwrap_or(crate::terminal_host_runtime::CONTROL_RESPONSE_TIMEOUT);
        #[cfg(not(test))]
        let timeout = crate::terminal_host_runtime::CONTROL_RESPONSE_TIMEOUT;
        let deadline = Instant::now() + timeout;
        #[cfg(test)]
        let operation_hook = self.cell_pixel_operation.lock().unwrap().clone();
        #[cfg(test)]
        let fanout_operation_hook = operation_hook.clone();
        let operation_report = report.clone();
        let operation_completion = completion.clone();
        let operation_mux = Arc::downgrade(self);
        let results = bounded_deadline_map(
            &self.deadline_fanout_pool,
            &surfaces,
            deadline,
            move |surface, deadline| {
                let result = apply_cell_pixel_size_until(
                    surface,
                    next,
                    deadline,
                    &operation_report,
                    #[cfg(test)]
                    fanout_operation_hook.as_ref(),
                );
                let completed_at = Instant::now();
                if completed_at <= deadline
                    && result.2.is_ok()
                    && let Some(mux) = operation_mux.upgrade()
                {
                    mux.record_cell_pixel_completion(&operation_completion, surface.id);
                }
                result
            },
        );
        let mut update = CellPixelUpdate::default();
        let mut retry_surfaces = Vec::new();
        let mut pending_operations = Vec::new();
        for (surface, result) in surfaces.iter().zip(results) {
            let (id, size, result, deferred) = match result {
                DeadlineMapResult::Complete(result) => result,
                DeadlineMapResult::Pending(result) => {
                    pending_operations.push(PendingCellPixelOperation {
                        surface: Arc::downgrade(surface),
                        result,
                    });
                    update.failures.push(CellPixelUpdateFailure {
                        surface: surface.id,
                        error: "cell pixel update is still running after the shared deadline"
                            .to_string(),
                        deferred: true,
                    });
                    continue;
                }
                DeadlineMapResult::Unscheduled => {
                    retry_surfaces.push(Arc::downgrade(surface));
                    update.failures.push(CellPixelUpdateFailure {
                        surface: surface.id,
                        error: "cell pixel update was deferred because the deadline worker pool \
                                is saturated"
                            .to_string(),
                        deferred: true,
                    });
                    continue;
                }
            };
            match result {
                Ok(Some(reservation_id)) => update.resizes.push((id, size, reservation_id)),
                Ok(None) => {}
                Err(error) => {
                    let retry = error
                        .downcast_ref::<
                            crate::terminal_host_runtime::CellPixelRequestDeadlineElapsed,
                        >()
                        .is_some();
                    if retry {
                        retry_surfaces.push(Arc::downgrade(surface));
                    }
                    update.failures.push(CellPixelUpdateFailure {
                        surface: id,
                        error: error.to_string(),
                        deferred: deferred || retry,
                    });
                }
            }
        }
        let completed = std::mem::take(&mut *completion.completed.lock().unwrap());
        if !completed.is_empty() {
            update.failures.retain(|failure| !completed.contains(&failure.surface));
            retry_surfaces.retain(|surface| {
                surface.upgrade().is_some_and(|surface| !completed.contains(&surface.id))
            });
            pending_operations.retain(|pending| {
                pending.surface.upgrade().is_some_and(|surface| !completed.contains(&surface.id))
            });
        }
        #[cfg(test)]
        if let Some(hook) = self.cell_pixel_before_publish.lock().unwrap().clone() {
            hook(self.cell_pixel_size());
        }
        // Keep the published value at the last fully converged metric. New
        // surfaces use the pending target, and late hosted acknowledgements
        // remove their exact failure before publishing it globally.
        if update.failures.is_empty() {
            *self.cell_pixels.lock().unwrap() = next;
            *self.pending_cell_pixels.lock().unwrap() = None;
        } else {
            *self.pending_cell_pixels.lock().unwrap() = Some(PendingCellPixelUpdate {
                generation,
                target: next,
                failures: update.failures.iter().map(|failure| failure.surface).collect(),
                use_for_creation: update.failures.iter().all(|failure| failure.deferred),
            });
        }
        completion.publishing.store(false, Ordering::Release);
        let raced_completions = std::mem::take(&mut *completion.completed.lock().unwrap());
        for surface in &raced_completions {
            self.reconcile_cell_pixel_completion_locked(*surface, generation, next);
        }
        if !raced_completions.is_empty() {
            update.failures.retain(|failure| !raced_completions.contains(&failure.surface));
            retry_surfaces.retain(|surface| {
                surface.upgrade().is_some_and(|surface| !raced_completions.contains(&surface.id))
            });
            pending_operations.retain(|pending| {
                pending
                    .surface
                    .upgrade()
                    .is_some_and(|surface| !raced_completions.contains(&surface.id))
            });
        }
        let retry_ids = retry_surfaces
            .iter()
            .filter_map(Weak::upgrade)
            .map(|surface| surface.id)
            .chain(
                pending_operations
                    .iter()
                    .filter_map(|pending| pending.surface.upgrade())
                    .map(|surface| surface.id),
            )
            .collect::<HashSet<_>>();
        let retry_spawn = if retry_surfaces.is_empty() && pending_operations.is_empty() {
            Ok(())
        } else {
            self.enqueue_cell_pixel_retries(CellPixelRetryTask {
                surfaces: retry_surfaces,
                pending: pending_operations,
                attempts: 0,
                generation,
                target: next,
                completion,
                report,
                timeout,
                #[cfg(test)]
                operation_hook,
            })
        };
        if let Err(error) = retry_spawn {
            for failure in &mut update.failures {
                if retry_ids.contains(&failure.surface) {
                    failure.deferred = false;
                    failure.error = format!("{}; could not schedule retry: {error}", failure.error);
                }
            }
            if let Some(pending) = self.pending_cell_pixels.lock().unwrap().as_mut() {
                pending.use_for_creation = update.failures.iter().all(|failure| failure.deferred);
            }
        }
        drop(cell_pixel_lifecycle);
        update
    }

    pub fn default_colors(&self) -> DefaultColors {
        *self.default_colors.lock().unwrap()
    }

    pub fn set_default_colors(&self, colors: DefaultColors) {
        let surfaces = {
            let state = self.state.lock().unwrap();
            let mut current = self.default_colors.lock().unwrap();
            if *current == colors {
                return;
            }
            *current = colors;
            unique_surface_runtimes(&state)
        };
        for surface in surfaces {
            surface.set_default_colors(colors);
            self.emit_terminal_output(surface.id);
        }
    }

    pub fn seed_default_colors_if_no_durable_override(&self, colors: DefaultColors) {
        let surfaces = {
            let state = self.state.lock().unwrap();
            let mut current = self.default_colors.lock().unwrap();
            if self.durable_terminal_defaults.load(Ordering::Acquire) || *current == colors {
                return;
            }
            *current = colors;
            unique_surface_runtimes(&state)
        };
        for surface in surfaces {
            surface.set_default_colors(colors);
            self.emit_terminal_output(surface.id);
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
        let surfaces = unique_surface_runtimes(&state);
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
        for surface in &surfaces {
            surface.set_default_colors(colors);
        }
        drop(state);
        drop(registry);
        for surface in surfaces {
            self.emit_terminal_output(surface.id);
        }
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
        self.emit_terminal_resized(id, cols, rows, None);
        Ok((true, None))
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
        let mutation = WorkspaceMutation::daemon_local("cmux-tui");
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
            false,
        )
    }

    /// Stage an empty workspace for a resource effect. `ephemeral` marks it
    /// in the same transaction, so no reader sees it without the flag.
    fn create_empty_workspace_for_resource_effect(
        &self,
        name: Option<String>,
        requested_key: Option<String>,
        public_id: WorkspacePublicId,
        mutation: &WorkspaceMutation,
        ephemeral: bool,
    ) -> anyhow::Result<WorkspacePlacement> {
        self.create_empty_workspace_with_mutation_inner(
            name,
            requested_key,
            Some(public_id),
            None,
            None,
            mutation,
            false,
            ephemeral,
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
        ephemeral: bool,
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
        let notifications = self.tree_decorations();
        let mut registry = self.workspace_registry.lock().unwrap();
        let mut fingerprint = serde_json::json!({
            "op": "create-workspace",
            "name": requested_name,
            "requested_key": requested_key,
        });
        if ephemeral {
            fingerprint["ephemeral"] = Value::Bool(true);
        }
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
                let marked = workspace_public_id.as_str().to_string();
                let mark = move |tx: &rusqlite::Transaction<'_>| {
                    crate::state::store::mark_workspace_ephemeral(tx, &marked)
                };
                registry.commit_for_resource_effect_with(
                    mutation,
                    &fingerprint,
                    expected_generation,
                    expected_revision,
                    "workspace-added",
                    &key,
                    &desired,
                    Some(&workspace_public_id),
                    &result,
                    ephemeral.then_some(
                        &mark as crate::workspace_registry::RegistryTransactionWrite<'_>,
                    ),
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
                    transaction: None,
                },
                selection_resync,
            )
        };
        self.emit_committed_workspace_delta(&registry, delta, selection_resync);
        drop(registry);
        if project_resource {
            self.publish_resource_event();
        }
        Ok(placement)
    }

    fn created_terminal_host_id(&self, created_path: &Value) -> anyhow::Result<String> {
        let terminal_id = TerminalPublicId::parse(
            created_path["terminal_id"]
                .as_str()
                .context("created terminal result omitted its public terminal id")?
                .to_string(),
        )?;
        self.workspace_registry
            .lock()
            .unwrap()
            .terminal_host_id(&terminal_id)?
            .context("created terminal result has no durable host id")
    }

    pub(crate) fn created_terminal_run_result(
        &self,
        terminal_id: &str,
    ) -> anyhow::Result<RunCommandResult> {
        for _ in 0..2 {
            let resolution = self
                .resolve_terminal(terminal_id)?
                .context("created terminal result has no durable terminal row")?;
            let placement = resolution.surface.and_then(|surface| {
                self.with_state(|state| run_placement_for_surface(state, surface))
            });
            match resolution.terminal.lifecycle {
                TerminalLifecycle::Exited => {
                    anyhow::ensure!(
                        resolution.terminal.exit.is_some(),
                        "exited terminal omitted durable exit metadata"
                    );
                    return Ok(RunCommandResult {
                        placement: None,
                        terminal: resolution.terminal,
                        terminal_revision: resolution.terminal_revision,
                    });
                }
                TerminalLifecycle::Running => {
                    if let Some(placement) = placement {
                        return Ok(RunCommandResult {
                            placement: Some(placement),
                            terminal: resolution.terminal,
                            terminal_revision: resolution.terminal_revision,
                        });
                    }
                    // Exit commits lifecycle before installing the detached
                    // state. Re-read once if that transition landed between
                    // resolve_terminal's registry and state snapshots.
                }
                lifecycle => anyhow::bail!(
                    "created terminal is {} before its run result could be returned",
                    terminal_lifecycle_name(lifecycle)
                ),
            }
        }
        anyhow::bail!("created running terminal has no placement")
    }

    pub(crate) fn reap_created_terminal_surface(self: &Arc<Self>, surface: Option<SurfaceId>) {
        if let Some(surface) = surface.and_then(|surface| self.surface(surface)) {
            self.reap_if_dead(&surface);
        }
    }

    pub(crate) fn activate_created_terminal_surface(
        &self,
        surface: Option<SurfaceId>,
    ) -> anyhow::Result<()> {
        if let Some(surface) = surface.and_then(|surface| self.surface(surface)) {
            surface.activate_hosted_launch_stream()?;
        }
        Ok(())
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
        on_exit: Option<TerminalOnExit>,
    ) -> anyhow::Result<TerminalPlacementResult> {
        self.create_terminal_in_workspace_with_mutation_env(
            workspace,
            argv,
            cwd,
            name,
            size,
            requested_terminal_id,
            expected_generation,
            expected_revision,
            mutation,
            on_exit,
            Vec::new(),
        )
    }

    #[allow(clippy::too_many_arguments)]
    fn create_terminal_in_workspace_with_mutation_env(
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
        on_exit: Option<TerminalOnExit>,
        env: Vec<(String, String)>,
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
            on_exit,
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
            on_exit: on_exit.unwrap_or_default(),
            env,
        };
        let (placement, surface, created_path) = self.create_terminal_in_workspace_impl(
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
        let terminal_revision = self.workspace_registry.lock().unwrap().terminal_revision()?;
        Ok(TerminalPlacementResult {
            placement: Some(placement),
            terminal_id: identity.terminal_id,
            terminal_incarnation: Some(identity.incarnation),
            terminal_revision,
            replayed: false,
            created_path: Some(created_path),
            created_surface: Some(surface.id),
        })
    }

    fn replayed_terminal_placement(
        &self,
        terminal_id: &str,
    ) -> anyhow::Result<TerminalPlacementResult> {
        let resolved = self.created_terminal_run_result(terminal_id)?;
        let placement = resolved.placement;
        let surface = placement.map(|placement| placement.surface);
        let created_path =
            surface.map(|surface| self.created_resource_path(surface)).transpose()?;
        Ok(TerminalPlacementResult {
            placement,
            terminal_id: resolved.terminal.terminal_id,
            terminal_incarnation: resolved.terminal.incarnation,
            terminal_revision: resolved.terminal_revision,
            replayed: true,
            created_path,
            created_surface: surface,
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
    ) -> anyhow::Result<(RunPlacement, Arc<Surface>, Value)> {
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
            let (placement, canonical_workspace, changed, created_path) = match projected {
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
            return Ok((placement, surface, created_path));
        }
        let notifications = self.tree_decorations();
        let active_at = self.next_active_at();
        let mut rollback_removed = Vec::new();
        let attached = {
            let mut state = self.state.lock().unwrap();
            let result = (|| -> anyhow::Result<_> {
                anyhow::ensure!(
                    state.surfaces.contains_key(&surface.id),
                    "terminal closed while its topology binding was being created"
                );
                let wi = state
                    .workspace_index(workspace)
                    .context("workspace disappeared while creating terminal")?;
                let target =
                    state.workspaces[wi].active_screen_ref().map(|screen| screen.active_pane);
                if let Some(target) = target {
                    let (_, si) = state
                        .screen_of(target)
                        .context("workspace active pane disappeared while creating terminal")?;
                    let pane = state
                        .panes
                        .get_mut(&target)
                        .context("workspace active pane disappeared while creating terminal")?;
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
                    let placement =
                        RunPlacement { surface: surface.id, pane: target, screen, workspace };
                    let created_path = self.created_resource_path_in_state(&state, surface.id)?;
                    Ok((
                        placement,
                        TreeDelta {
                            kind: TreeDeltaKind::TabAdded,
                            workspace,
                            screen: Some(screen),
                            pane: Some(target),
                            surface: Some(surface.id),
                            index: Some(index),
                            entity,
                            workspace_revision: None,
                            transaction: None,
                        },
                        true,
                        created_path,
                    ))
                } else {
                    let (pane_id, pane) = self.make_pane(surface.id)?;
                    let screen_id = self.next_id();
                    let screen_public_id = ScreenPublicId::random()?;
                    state.insert_pane(pane);
                    stamp_pane_focus(self, &mut state, pane_id);
                    state.workspaces[wi].screens.push(Screen {
                        id: screen_id,
                        public_id: screen_public_id,
                        name: None,
                        root: Node::Leaf(pane_id),
                        active_pane: pane_id,
                        zoomed_pane: None,
                        creation_order_auto_layout: Some(vec![pane_id]),
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
                    let placement = RunPlacement {
                        surface: surface.id,
                        pane: pane_id,
                        screen: screen_id,
                        workspace,
                    };
                    let created_path = self.created_resource_path_in_state(&state, surface.id)?;
                    Ok((
                        placement,
                        TreeDelta {
                            kind: TreeDeltaKind::ScreenAdded,
                            workspace,
                            screen: Some(screen_id),
                            pane: None,
                            surface: None,
                            index: Some(0),
                            entity,
                            workspace_revision: None,
                            transaction: None,
                        },
                        false,
                        created_path,
                    ))
                }
            })();
            if result.is_err() {
                rollback_removed = remove_terminal_runtime_from_state(self, &mut state, &surface).0;
            }
            result
        };
        let attached = match attached {
            Ok(attached) => attached,
            Err(error) => {
                drop(pending_surface);
                for placement in rollback_removed {
                    self.purge_surface_side_tables(placement.id);
                }
                self.purge_terminal_runtime_side_tables(&surface);
                if !surface.is_dead() {
                    surface.kill();
                }
                return Err(error);
            }
        };
        drop(pending_surface);
        self.emit_tree_delta(attached.1, attached.2);
        drop(workspace_lifecycle);
        Ok((attached.0, surface, attached.3))
    }

    /// Bind a just-launched hosted surface using the latest durable row, not
    /// the workspace requested before process launch. Holding registry ->
    /// state through projection is the create/move serialization fence.
    fn bind_running_terminal_to_canonical_workspace(
        &self,
        surface: &Arc<Surface>,
    ) -> anyhow::Result<(RunPlacement, String, bool, Value)> {
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
        let created_path = self.created_resource_path_in_state(&state, surface.id)?;
        Ok((placement, terminal.workspace_key, changed, created_path))
    }

    fn create_browser_surface_in_workspace(
        self: &Arc<Self>,
        workspace: WorkspaceId,
        url: String,
        size: Option<(u16, u16)>,
        resource_identity: Option<TabResourceIdentity>,
    ) -> anyhow::Result<Arc<Surface>> {
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
        let notifications = self.tree_decorations();
        let active_at = self.next_active_at();
        let (delta, selection_resync) = {
            let mut state = self.state.lock().unwrap();
            let Some(wi) = state.workspace_index(workspace) else {
                state.surfaces.remove(&surface.id);
                surface.kill();
                anyhow::bail!("workspace disappeared while creating browser tab");
            };
            let target = state.workspaces[wi].active_screen_ref().map(|screen| screen.active_pane);
            if let Some(target) = target {
                let Some((_, si)) = state.screen_of(target) else {
                    state.surfaces.remove(&surface.id);
                    surface.kill();
                    anyhow::bail!("workspace active pane disappeared while creating browser tab");
                };
                let Some(pane) = state.panes.get_mut(&target) else {
                    state.surfaces.remove(&surface.id);
                    surface.kill();
                    anyhow::bail!("workspace active pane disappeared while creating browser tab");
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
                (
                    TreeDelta {
                        kind: TreeDeltaKind::TabAdded,
                        workspace,
                        screen: Some(screen),
                        pane: Some(target),
                        surface: Some(surface.id),
                        index: Some(index),
                        entity,
                        workspace_revision: None,
                        transaction: None,
                    },
                    true,
                )
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
                    creation_order_auto_layout: Some(vec![pane_id]),
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
                (
                    TreeDelta {
                        kind: TreeDeltaKind::ScreenAdded,
                        workspace,
                        screen: Some(screen_id),
                        pane: None,
                        surface: None,
                        index: Some(0),
                        entity,
                        workspace_revision: None,
                        transaction: None,
                    },
                    false,
                )
            }
        };
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
        let _cell_pixel_lifecycle = self.cell_pixel_lifecycle.lock().unwrap();
        let (pane_id, size) = {
            let state = self.state.lock().unwrap();
            let Some(pane_id) = state.pane_of(opener_surface) else {
                return Ok(false);
            };
            let size = state.surfaces.get(&opener_surface).map(|surface| surface.size());
            (pane_id, size)
        };
        let id = self.next_id();
        let opts = self.surface_options.lock().unwrap().clone();
        let size = size.unwrap_or((opts.cols, opts.rows));
        let cell_pixels = self.cell_pixel_creation_size();
        let surface =
            browser::new_surface(id, url.clone(), size, cell_pixels, &opts, Arc::downgrade(self))?;
        let active_at = self.next_active_at();
        let attached =
            match self.attach_browser_surface_to_pane_or_kill(pane_id, &surface, active_at) {
                BrowserSurfaceAttach::MissingPane => return Ok(false),
                BrowserSurfaceAttach::Attached(delta) => delta,
            };
        let identity = surface
            .resource_identity()
            .context("adopted browser surface omitted its public identity")?;
        let result = serde_json::json!({
            "tab_id":identity.tab_id,
            "browser_id":identity.content_id,
        });
        if let Err(error) = self.commit_ordinary_full_resource_projection(
            &Actor::Daemon,
            "browser.target.adopt",
            result,
        ) {
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
    ) -> BrowserSurfaceAttach {
        let notifications = self.tree_decorations();
        let attached = {
            let mut state = self.state.lock().unwrap();
            match state.panes.get_mut(&pane_id) {
                Some(pane) => {
                    pane.tabs.push(surface.id);
                    pane.active_tab = pane.tabs.len() - 1;
                    pane.active_at = active_at;
                    fence_layout_undo_for_tab_membership(&mut state, &[pane_id]);
                    if let Some(identity) = surface.resource_identity().cloned() {
                        state.register_tab_identity(surface.id, &identity);
                    }
                    state.surfaces.insert(surface.id, surface.clone());
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
                            transaction: None,
                        })
                    })();
                    BrowserSurfaceAttach::Attached(delta)
                }
                None => BrowserSurfaceAttach::MissingPane,
            }
        };
        if matches!(attached, BrowserSurfaceAttach::MissingPane) {
            surface.kill();
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
        surface.and_then(|surface| surface.local_cwd())
    }

    fn workspace_key_for_pane(&self, pane: PaneId) -> Option<String> {
        let state = self.state.lock().unwrap();
        let (workspace, _) = state.screen_of(pane)?;
        Some(state.workspaces[workspace].key.clone())
    }

    pub(crate) fn close_surface_for_resource_effect(
        &self,
        target: SurfaceId,
    ) -> anyhow::Result<bool> {
        Ok(self.remove_surface_after_registry(target))
    }

    fn remove_surface_after_registry(&self, target: SurfaceId) -> bool {
        let notifications = self.tree_decorations();
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
            if surface.kind() == SurfaceKind::Browser {
                surface.kill();
            }
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
    /// lock. Tabs are detached view items; terminal content remains in the
    /// catalog until an explicit terminal close.
    fn close_tree_target(&self, target: TreeCloseTarget) -> anyhow::Result<bool> {
        let notifications = self.tree_decorations();
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
                )))
            })();
            let result = result?;
            drop(workspace_lifecycle);
            break result;
        };
        let Some((removed, changed_screens, empty_revision, delta, tree_removed, selection_resync)) =
            result
        else {
            return Ok(false);
        };
        for surface in removed {
            self.purge_surface_side_tables(surface.id);
            if surface.kind() == SurfaceKind::Browser {
                surface.kill();
            }
        }
        if tree_removed {
            self.emit_tree_delta(delta, selection_resync);
            for screen in changed_screens {
                self.emit(MuxEvent::LayoutChanged(screen));
            }
        }
        self.emit_empty_if_current(empty_revision);
        Ok(true)
    }

    pub(crate) fn close_pane_for_resource_effect(&self, target: PaneId) -> anyhow::Result<bool> {
        self.close_tree_target(TreeCloseTarget::Pane(target))
            .with_context(|| format!("close pane {target}"))
    }

    pub(crate) fn close_screen_for_resource_effect(
        &self,
        target: ScreenId,
    ) -> anyhow::Result<bool> {
        self.close_tree_target(TreeCloseTarget::Screen(target))
            .with_context(|| format!("close screen {target}"))
    }

    /// Close a workspace and every screen/pane/tab in it, as `actor`.
    pub fn close_workspace_as(&self, actor: &Actor, target: WorkspaceId) -> bool {
        self.close_workspace_at_revision_as(actor, target, None)
            .map(|revision| revision.is_some())
            .unwrap_or(false)
    }

    /// Atomically close one workspace if the caller's registry snapshot is
    /// still current. Returns the resulting revision when the workspace was
    /// present and closed.
    pub fn close_workspace_at_revision_as(
        &self,
        actor: &Actor,
        target: WorkspaceId,
        expected_revision: Option<u64>,
    ) -> anyhow::Result<Option<u64>> {
        Ok(self
            .close_workspace_selector_at_revision(actor, Some(target), None, expected_revision)?
            .map(|(_, _, revision)| revision))
    }

    pub(crate) fn close_workspace_selector_at_revision(
        &self,
        actor: &Actor,
        id: Option<WorkspaceId>,
        key: Option<&str>,
        expected_revision: Option<u64>,
    ) -> anyhow::Result<Option<(WorkspaceId, String, u64)>> {
        let authority = WorkspaceMutationAuthority::Ordinary;
        self.close_workspace_selector_with_authority(
            actor,
            id,
            key,
            expected_revision,
            authority,
            true,
        )
    }

    pub(crate) fn close_workspace_at_revision_for_resource_effect(
        &self,
        actor: &Actor,
        target: WorkspaceId,
    ) -> anyhow::Result<Option<u64>> {
        Ok(self
            .close_workspace_selector_with_authority(
                actor,
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

    pub fn close_provider_managed_workspace_as(
        &self,
        actor: &Actor,
        id: WorkspaceId,
        key: &str,
    ) -> anyhow::Result<Option<u64>> {
        Ok(self
            .close_workspace_selector_with_authority(
                actor,
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
        actor: &Actor,
        id: WorkspaceId,
        key: &str,
        authority: &str,
    ) -> anyhow::Result<Option<u64>> {
        Ok(self
            .close_workspace_selector_with_authority(
                actor,
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
        actor: &Actor,
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
        let mutation = WorkspaceMutation::local("cmux-tui", actor.clone());
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
        let notifications = self.tree_decorations();
        let mut registry = self.workspace_registry.lock().unwrap();
        if let Some(commit) = registry.replay(mutation, fingerprint)? {
            let result = workspace_mutation_result(&commit)?;
            return Ok(result);
        }
        let (removed, delta, empty_revision, selection_resync, result) = {
            let mut state = self.state.lock().unwrap();
            Self::require_workspace_revision(&state, expected_revision)?;
            let index = resolve_workspace_index(&state, target, requested_key)?;
            let workspace_id = state.workspaces[index].id;
            if workspace_id != resolved_target {
                anyhow::bail!("workspace selector changed while closing");
            }
            let previous_active = state.active_pane();
            let key = state.workspaces[index].key.clone();
            registry.read_state(|db| crate::state::home_store::refuse_close_key(db, &key))?;
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
                        if let Some(surface) = state.surfaces.remove(&surface) {
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
            (removed, delta, empty_revision, selection_resync, result)
        };
        self.emit_committed_workspace_delta(&registry, delta, selection_resync);
        drop(registry);
        if project_resource {
            self.publish_resource_event();
        }
        for surface in removed {
            self.purge_surface_side_tables(surface.id);
            if surface.kind() == SurfaceKind::Browser {
                surface.kill();
            }
        }
        self.emit_empty_if_current(empty_revision);
        Ok(result)
    }

    pub fn rename_workspace_at_revision_as(
        &self,
        actor: &Actor,
        target: WorkspaceId,
        name: String,
        expected_revision: Option<u64>,
    ) -> anyhow::Result<Option<u64>> {
        Ok(self
            .rename_workspace_selector_with_authority(
                actor,
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

    pub fn rename_provider_managed_workspace_as(
        &self,
        actor: &Actor,
        id: WorkspaceId,
        key: &str,
        name: String,
    ) -> anyhow::Result<Option<u64>> {
        Ok(self
            .rename_workspace_selector_with_authority(
                actor,
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
        actor: &Actor,
        id: WorkspaceId,
        key: &str,
        name: String,
        authority: &str,
    ) -> anyhow::Result<Option<u64>> {
        Ok(self
            .rename_workspace_selector_with_authority(
                actor,
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
        actor: &Actor,
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
        let mutation = WorkspaceMutation::local("cmux-tui", actor.clone());
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
        let notifications = self.tree_decorations();
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
                    transaction: None,
                },
                workspace_mutation_result(&commit)?,
            )
        };
        self.emit_committed_workspace_delta(&registry, renamed, false);
        drop(registry);
        self.publish_resource_event();
        Ok(result)
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
        if let Some(identity) = surface.terminal_host_identity() {
            for existing in state.terminal_catalog.values().filter(|existing| {
                existing
                    .terminal_host_identity()
                    .is_some_and(|candidate| candidate.terminal_id == identity.terminal_id)
            }) {
                anyhow::ensure!(existing.shares_terminal_runtime(surface), "duplicate_terminal_id");
            }
        }
        state.terminal_catalog.insert(terminal_id.clone(), surface.clone());
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
    let runtime = state.terminal_catalog.remove(terminal_id);
    if let Some(runtime_id) = runtime.as_ref().and_then(|runtime| runtime.terminal_runtime_id()) {
        state.terminal_catalog_by_runtime.remove(&runtime_id);
    }
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

pub(crate) fn now_ms() -> u64 {
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

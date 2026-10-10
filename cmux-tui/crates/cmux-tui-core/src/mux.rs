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
mod kitty_budget_state;
use kitty_budget_state::KITTY_IMAGE_BUDGET_OWNER_LIMIT;
use kitty_budget_state::KITTY_IMAGE_BUDGET_RETRY_INITIAL;
use kitty_budget_state::KITTY_IMAGE_BUDGET_RETRY_MAX;
use kitty_budget_state::KITTY_IMAGE_BUDGET_RETRY_MAX_ATTEMPTS;
#[cfg(test)]
use kitty_budget_state::KITTY_IMAGE_PERSISTENT_COPIES_PER_SURFACE;
#[cfg(test)]
use kitty_budget_state::KITTY_IMAGE_PROCESS_BUDGET_BYTES;
#[cfg(test)]
use kitty_budget_state::KITTY_IMAGE_PROCESS_BUDGET_COUNT;
#[cfg(test)]
use kitty_budget_state::KITTY_OBJECT_OWNERS_PER_SURFACE;
use kitty_budget_state::KittyImageBudgetEntry;
pub(crate) use kitty_budget_state::KittyImageBudgetReservation;
use kitty_budget_state::KittyImageBudgetState;
use kitty_budget_state::PendingKittyImageBudgetOperation;
pub(crate) use kitty_budget_state::RENDER_ATTACHMENT_LIMIT;
pub(crate) use kitty_budget_state::RenderAttachmentPermit;
use kitty_budget_state::kitty_image_budget_capacity;
use kitty_budget_state::kitty_image_limits_for_capacity;
#[cfg(test)]
use kitty_budget_state::kitty_surface_byte_reservation;
mod cell_pixel_state;
use cell_pixel_state::CELL_PIXEL_RETRY_MAX_ATTEMPTS;
#[cfg(test)]
use cell_pixel_state::CellPixelBeforePublishHook;
use cell_pixel_state::CellPixelCompletionTracker;
#[cfg(test)]
use cell_pixel_state::CellPixelOperationHook;
use cell_pixel_state::CellPixelRetryQueue;
use cell_pixel_state::CellPixelRetryTask;
pub use cell_pixel_state::CellPixelUpdate;
pub use cell_pixel_state::CellPixelUpdateFailure;
#[cfg(test)]
use cell_pixel_state::KittyImageBudgetOperationHook;
use cell_pixel_state::PendingCellPixelOperation;
use cell_pixel_state::PendingCellPixelUpdate;
#[cfg(test)]
use cell_pixel_state::TerminalSpawnAfterCellPixelSnapshotHook;
#[cfg(test)]
use cell_pixel_state::TerminalSpawnBeforeCellPixelReconcileHook;
use cell_pixel_state::apply_cell_pixel_size_until;
use cell_pixel_state::cell_pixel_retry_delay;
use cell_pixel_state::validate_cell_pixel_convergence;
mod client_sizing_state;
use client_sizing_state::AppliedClientSize;
use client_sizing_state::ClientResizeRequest;
pub(crate) use client_sizing_state::ClientSizeRollback;
pub(crate) use client_sizing_state::ClientSizingIdentity;
use client_sizing_state::ClientSizingRollbackToken;
use client_sizing_state::ClientSizingState;
pub(crate) use client_sizing_state::ControlClientResize;
use client_sizing_state::PreparedControlClientResize;
use client_sizing_state::SizingMember;
use client_sizing_state::SurfaceResizeCompletion;
use client_sizing_state::SurfaceResizeRestore;
use client_sizing_state::TerminalSizingEntry;
use client_sizing_state::entry_owns;
pub(crate) use client_sizing_state::sub_view_participant_id;
pub(crate) use client_sizing_state::view_participant_id;
mod terminal_exit_waiters;
use terminal_exit_waiters::TerminalExitDetachTracker;
#[cfg(test)]
use terminal_exit_waiters::TerminalExitStateQueryGuard;
pub(crate) use terminal_exit_waiters::TerminalExitSubscription;
use terminal_exit_waiters::TerminalExitWaiters;
mod results;
use results::BrowserSurfaceAttach;
pub use results::ConfigReloadError;
pub(crate) use results::DaemonHandoffRequest;
pub(crate) use results::DaemonIdentity;
pub(crate) use results::RESERVED_TERMINAL_ID_FIELD;
pub(crate) use results::RunCommandOptions;
pub(crate) use results::RunCommandResult;
pub use results::RunPlacement;
pub use results::SidebarPluginOptions;
use results::SidebarPluginRuntime;
pub use results::SidebarPluginStatus;
pub(crate) use results::TerminalCloseGuard;
pub(crate) use results::TerminalCloseGuardFailed;
pub use results::TerminalCloseResult;
pub use results::TerminalMoveResult;
pub use results::TerminalPlacementResult;
use results::TerminalReservationRequest;
pub use results::TerminalResolution;
use results::TreeCloseTarget;
use results::WorkspaceMutationAuthority;
pub use results::WorkspaceMutationResult;
pub use results::WorkspacePlacement;
use results::terminal_env_field;
pub(crate) use results::validate_terminal_env;
mod guards;
use guards::CLIENT_FOCUS_MEMORY_LIMIT;
use guards::ClientFocusRecord;
use guards::ConfigReloadState;
#[cfg(unix)]
pub(crate) use guards::PendingTerminalHostBinding;
#[cfg(unix)]
use guards::PendingTerminalHostRelease;
use guards::PendingWorkspaceSurface;
pub(crate) use guards::ResourceWaitWake;
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
mod spawn_options;
#[cfg(test)]
mod test_actor_wrappers;
mod test_hooks;
mod topology_edit;
mod topology_ops;
pub(crate) use browser_tab_create::{
    FRONTEND_BROWSER_ACTIVATE_CAPABILITY, FRONTEND_BROWSER_INSERT_AFTER_CAPABILITY,
    FrontendTabPlacement, frontend_fields as frontend_browser_fields,
};
pub(crate) use spawn_options::{CLIENT_PANE_ID_FIELD, CLIENT_TAB_ID_FIELD, terminal_identity};
pub use spawn_options::{PaneSurfaceCreation, TerminalSpawnOptions};
mod agent_chat_columns;
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
pub(crate) mod feed_local;
mod focus;
mod frontend_projection;
mod history_search;
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

pub use agent_chat_columns::AGENT_CHAT_COLUMN_CODE;
pub(crate) use agent_chat_columns::{
    agent_chat_columns, ensure_agent_chat_columns_unsplit, ensure_pane_column_not_agent_chat,
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

use crate::lock_rank::{Condvar, Mutex, MutexGuard, RankedMutex, rank};
use public_projections::{RestoredPublicProjections, restore_public_projections};
use registry_viewport::restore_registry_viewport;
use std::collections::{BTreeSet, HashMap, HashSet, VecDeque};
use std::fmt;
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc::{Receiver, SyncSender};
use std::sync::{Arc, OnceLock, PoisonError, Weak};
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
const TERMINAL_HOST_CLOSE_WAIT: Duration = Duration::from_secs(4);
const TERMINAL_READER_SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(1);
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

#[cfg(test)]
type ScreenCreatedHook = Box<dyn FnOnce(SurfaceId) + Send>;

pub struct Mux {
    /// The journal writer's only lock; declared first to drop first (see `RegistryConnection`).
    pub(crate) registry_connection: Arc<crate::workspace_registry::RegistryConnection>,
    /// Serializes durable commits and their projection; lock order: registry, connection, state.
    pub(crate) workspace_registry: SignaledMutex<WorkspaceRegistry>,
    pub(crate) session_public_id: SessionPublicId,
    pub(crate) machine_public_id: crate::resource::MachinePublicId,
    /// Control-socket admission counters, shared with the accept loop.
    connection_stats: Arc<crate::diagnostics::ConnectionStats>,
    /// Clone of the registry's projection spans, read without its lock.
    resource_projection_stats: Arc<crate::diagnostics::ResourceProjectionStats>,
    started_at: Instant,
    pub(crate) state: signaled_mutex::StateMutex,
    subscribers: MuxEventBroadcaster,
    config_reload: Mutex<ConfigReloadState>,
    config_reload_changed: Condvar,
    next_id: AtomicU64,
    next_notification_id: AtomicU64,
    next_active_at: AtomicU64,
    next_in_process_resize_owner: AtomicU64,
    surface_options: RankedMutex<SurfaceOptions, { rank::MUX_SURFACE_OPTIONS }>,
    provider_workspace: RankedMutex<ProviderWorkspaceState, { rank::MUX_PROVIDER_WORKSPACE }>,
    /// `provider_workspace.managed`, readable under the registry and state
    /// locks (the provider lock orders before them; the flag is one-way).
    provider_managed: AtomicBool,
    workspace_lifecycles: RankedMutex<
        HashMap<WorkspaceId, Weak<RankedMutex<(), { rank::MUX_WORKSPACE_LIFECYCLE }>>>,
        { rank::LEAF },
    >,
    pending_workspace_surfaces:
        RankedMutex<HashMap<SurfaceId, WorkspaceId>, { rank::MUX_PENDING_WORKSPACE_SURFACES }>,
    client_sizing_lifecycle: RankedMutex<(), { rank::MUX_CLIENT_SIZING_LIFECYCLE }>,
    client_sizing: RankedMutex<ClientSizingState, { rank::MUX_CLIENT_SIZING }>,
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
    /// The history search index (`history-search-v1`), installed by the
    /// binary with its feeds; absent otherwise.
    history_search: OnceLock<crate::history_search::HistorySearch>,
    #[cfg(test)]
    client_resize_before_apply: RankedMutex<Option<Arc<dyn Fn() + Send + Sync>>, { rank::LEAF }>,
    #[cfg(test)]
    terminal_move_before_projection:
        RankedMutex<Option<Arc<dyn Fn() + Send + Sync>>, { rank::LEAF }>,
    #[cfg(test)]
    client_rollback_before_wait: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
    #[cfg(test)]
    workspace_close_before_empty_check:
        RankedMutex<Option<Arc<dyn Fn() + Send + Sync>>, { rank::LEAF }>,
    #[cfg(test)]
    workspace_close_after_selector_resolution:
        RankedMutex<Option<Arc<dyn Fn() + Send + Sync>>, { rank::LEAF }>,
    #[cfg(test)]
    workspace_delta_before_emit: RankedMutex<Option<WorkspaceDeltaBeforeEmitHook>, { rank::LEAF }>,
    #[cfg(test)]
    resource_rename_after_selector_resolution:
        RankedMutex<Option<WorkspaceRenameHook>, { rank::LEAF }>,
    #[cfg(test)]
    layout_apply_after_workspace_reservation:
        RankedMutex<Option<Arc<dyn Fn() + Send + Sync>>, { rank::LEAF }>,
    #[cfg(test)]
    terminal_create_after_empty_check:
        RankedMutex<Option<Arc<dyn Fn() + Send + Sync>>, { rank::LEAF }>,
    #[cfg(test)]
    terminal_create_after_materialization_lock:
        RankedMutex<Option<Arc<dyn Fn() + Send + Sync>>, { rank::LEAF }>,
    #[cfg(test)]
    terminal_create_after_workspace_reservation:
        RankedMutex<Option<Arc<dyn Fn() + Send + Sync>>, { rank::LEAF }>,
    #[cfg(test)]
    terminal_spawn_after_cell_pixel_snapshot: RankedMutex<
        Option<TerminalSpawnAfterCellPixelSnapshotHook>,
        { rank::MUX_TERMINAL_SPAWN_AFTER_CELL_PIXEL_SNAPSHOT_HOOK },
    >,
    #[cfg(test)]
    terminal_spawn_before_cell_pixel_reconcile: RankedMutex<
        Option<TerminalSpawnBeforeCellPixelReconcileHook>,
        { rank::MUX_TERMINAL_SPAWN_BEFORE_CELL_PIXEL_RECONCILE_HOOK },
    >,
    #[cfg(test)]
    terminal_create_after_terminal_reservation: RankedMutex<
        Option<TerminalReservationHook>,
        { rank::MUX_TERMINAL_CREATE_AFTER_RESERVATION_HOOK },
    >,
    pending_terminal_hosts: RankedMutex<HashMap<SurfaceId, TerminalHostIdentity>, { rank::LEAF }>,
    reserved_in_process_terminals:
        RankedMutex<HashMap<SurfaceId, TerminalHostIdentity>, { rank::LEAF }>,
    #[cfg(test)]
    viewport_split_after_spawn: RankedMutex<
        Option<Arc<dyn Fn() + Send + Sync>>,
        { rank::MUX_VIEWPORT_SPLIT_AFTER_SPAWN_HOOK },
    >,
    #[cfg(test)]
    resource_mutation_metrics: RankedMutex<Option<ResourceMutationMetrics>, { rank::LEAF }>,
    #[cfg(test)]
    resource_projection_before_commit:
        RankedMutex<Option<Arc<dyn Fn() + Send + Sync>>, { rank::LEAF }>,
    #[cfg(test)]
    resource_close_after_commit: RankedMutex<Option<Arc<dyn Fn() + Send + Sync>>, { rank::LEAF }>,
    #[cfg(test)]
    layout_undo_before_commit: RankedMutex<
        Option<Arc<dyn Fn() + Send + Sync>>,
        { rank::MUX_LAYOUT_UNDO_BEFORE_COMMIT_HOOK },
    >,
    #[cfg(test)]
    resource_close_cleanup: RankedMutex<Option<Arc<dyn Fn() + Send + Sync>>, { rank::LEAF }>,
    browser_providers: Arc<BrowserProviderRegistry>,
    browser_runtime: RankedMutex<Option<Arc<BrowserRuntime>>, { rank::MUX_BROWSER_RUNTIME }>,
    active_render_attachments: Arc<AtomicUsize>,
    deadline_fanout_pool: DeadlineFanoutPool,
    kitty_image_budget: RankedMutex<KittyImageBudgetState, { rank::MUX_KITTY_IMAGE_BUDGET }>,
    kitty_image_budget_changed: Condvar,
    /// App byte-backend terminals (`app_terminals.rs`), by catalog surface.
    app_terminals: RankedMutex<HashSet<SurfaceId>, { rank::LEAF }>,
    #[cfg(debug_assertions)]
    terminal_host_reconnect_completion_failures: AtomicU64,
    #[cfg(debug_assertions)]
    terminal_host_test_disconnect_after_spawn_ms: AtomicU64,
    #[cfg(test)]
    kitty_image_budget_operation: RankedMutex<
        Option<KittyImageBudgetOperationHook>,
        { rank::MUX_KITTY_IMAGE_BUDGET_OPERATION_HOOK },
    >,
    cell_pixel_lifecycle: RankedMutex<(), { rank::MUX_CELL_PIXEL_LIFECYCLE }>,
    next_cell_pixel_generation: AtomicU64,
    cell_pixels: RankedMutex<(u16, u16), { rank::LEAF }>,
    pending_cell_pixels:
        RankedMutex<Option<PendingCellPixelUpdate>, { rank::MUX_PENDING_CELL_PIXELS }>,
    cell_pixel_retries: RankedMutex<CellPixelRetryQueue, { rank::LEAF }>,
    #[cfg(test)]
    cell_pixel_before_publish: RankedMutex<
        Option<CellPixelBeforePublishHook>,
        { rank::MUX_CELL_PIXEL_BEFORE_PUBLISH_HOOK },
    >,
    #[cfg(test)]
    cell_pixel_operation: RankedMutex<Option<CellPixelOperationHook>, { rank::LEAF }>,
    #[cfg(test)]
    cell_pixel_fanout_timeout: RankedMutex<Option<Duration>, { rank::LEAF }>,
    default_colors: RankedMutex<DefaultColors, { rank::LEAF }>,
    durable_terminal_defaults: AtomicBool,
    sidebar_plugin: RankedMutex<SidebarPluginRuntime, { rank::MUX_SIDEBAR_PLUGIN }>,
    journal_plugin: crate::journal_plugin::JournalPluginRuntime,
    machine_usage: Mutex<Option<MachineUsage>>,
    agent_records: RankedMutex<HashMap<TerminalPublicId, TerminalAgentRecord>, { rank::LEAF }>,
    agent_hook_fences:
        RankedMutex<HashMap<TerminalPublicId, HookFence>, { rank::MUX_AGENT_HOOK_FENCES }>,
    agent_roster: RankedMutex<AgentRosterHost, { rank::MUX_AGENT_ROSTER }>,
    agent_roster_fold: RankedMutex<(), { rank::MUX_AGENT_ROSTER_FOLD }>,
    /// Nonterminal notifications remain placement-local. Terminal unread state is keyed by
    /// stable content identity so every view of one terminal shares the same attention marker.
    placement_notifications:
        RankedMutex<HashMap<SurfaceId, SurfaceNotification>, { rank::MUX_PLACEMENT_NOTIFICATIONS }>,
    terminal_notifications:
        RankedMutex<HashMap<TerminalPublicId, SurfaceNotification>, { rank::LEAF }>,
    /// Records finished shell commands in the journal (`terminal-command-journal-v1`). Off until
    /// a trusted client turns it on (`set-terminal-command-history`); never persisted, so a
    /// restarted daemon records nothing until asked again.
    terminal_command_history: AtomicBool,
    /// The shell command journal worker's bounded queue (started on first use).
    shell_command_journal:
        Mutex<Option<SyncSender<(TerminalPublicId, crate::shell_history::FinishedCommand)>>>,
    notification_ledger:
        RankedMutex<VecDeque<ResourceNotification>, { rank::MUX_NOTIFICATION_LEDGER }>,
    /// Per-client read marks. The shared unread marker above answers "does this terminal need
    /// attention on the shared console"; this map answers "has this client install seen this
    /// notification", so several remote clients of one session keep independent unread state.
    notification_reads: RankedMutex<
        HashMap<NotificationPublicId, BTreeSet<String>>,
        { rank::MUX_NOTIFICATION_READS },
    >,
    /// Notification ids the in-memory ledger evicted whose durable read marks are still to be
    /// pruned: only after a create commits, and only for ids the committed receipts no longer
    /// retain, so a failed create cannot orphan marks the next restart would rebuild.
    notification_read_prunes: RankedMutex<Vec<NotificationPublicId>, { rank::LEAF }>,
    /// The local feed owner's items (mux/feed_local.rs). Lock order: this, then
    /// `workspace_registry`, then `state`; never take it while holding either.
    feed_local: RankedMutex<cmux_feed_core::Feed, { rank::MUX_FEED_LOCAL }>,
    /// Shared presentation metadata (workspace groups and workspace
    /// presentation fields), replaced after each registry commit.
    presentation: RankedMutex<Arc<crate::workspace_registry::PresentationSnapshot>, { rank::LEAF }>,
    /// Git HEAD lookups keyed by directory, with the time they were read.
    git_heads:
        RankedMutex<HashMap<String, (Instant, Option<presentation::GitHead>)>, { rank::LEAF }>,
    resource_machine_service: OnceLock<Arc<dyn crate::ResourceMachineService>>,
    journal_kernel: Arc<crate::journal_kernel::JournalKernel>,
    journal_ingress: crate::journal_ingress::JournalIngressSender,
    journal_hook_dispatcher_started: AtomicBool,
    journal_hook_runtime: Arc<crate::journal_hooks::JournalHookRuntime>,
    /// Wake-only signal for durable journal subscribers. Consumers always
    /// reread SQLite by cursor, so missed or coalesced notifications are safe.
    journal_event_epoch: RankedMutex<u64, { rank::LEAF }>,
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
    screen_created_hook: RankedMutex<Option<ScreenCreatedHook>, { rank::MUX_SCREEN_CREATED_HOOK }>,
    terminal_exit_waiters: TerminalExitWaiters,
    #[cfg(test)]
    terminal_exit_state_queries: AtomicU64,
    /// Keeps a close from removing a just-created surface before legacy
    /// callers have resolved the committed public result back to its runtime.
    resource_creation_handoff: RankedMutex<(), { rank::MUX_RESOURCE_CREATION_HANDOFF }>,
    /// Serializes the check-and-create sequence used when an attached local
    /// frontend bootstraps an otherwise empty session.
    initial_bootstrap: Mutex<()>,
    resource_creation_execution: RankedMutex<(), { rank::MUX_RESOURCE_CREATION_EXECUTION }>,
    resource_creation_active: AtomicBool,
    terminal_adoptions: Mutex<HashSet<String>>,
    /// Terminals with a possibly live host and no runtime surface (R41),
    /// keyed by public terminal id (`term_…`, what the tab JSON reads), with
    /// the host terminal id. A leaf lock: nothing else is locked under it.
    pending_terminals:
        RankedMutex<HashMap<String, (String, PendingTerminal)>, { rank::MUX_PENDING_TERMINALS }>,
    /// Typed ends (`TerminalEnd::wire_json`) of ended terminals that have no
    /// runtime surface, keyed by public terminal id. A leaf lock.
    terminal_ends: RankedMutex<HashMap<String, Value>, { rank::LEAF }>,
    /// Cause of each terminal's last host loss, by public id (cx-0tgl).
    terminal_loss_causes: RankedMutex<loss_causes::LossCauses, { rank::LEAF }>,
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
    terminal_reaper_events:
        RankedMutex<Option<MuxEventReceiver>, { rank::MUX_TERMINAL_REAPER_EVENTS }>,
    /// The launch snapshot file while its writer runs (`launch-snapshot-v1`).
    launch_snapshot_path: Mutex<Option<std::path::PathBuf>>,
    /// Parallel terminal host launches and reaps (`terminal_work`).
    terminal_work: terminal_work::TerminalWorkPool,
    /// Hosts launched ahead of their creation, by reserved terminal id.
    #[cfg(unix)]
    prelaunched_terminals:
        RankedMutex<HashMap<String, terminal_work::PrelaunchedTerminal>, { rank::LEAF }>,
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

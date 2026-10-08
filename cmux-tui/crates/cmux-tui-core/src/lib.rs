//! Terminal multiplexer core.
//!
//! Owns the workspace → screen → pane → tab tree and each tab's runtime
//! (a PTY child whose output feeds a libghostty-vt terminal). A workspace
//! holds screens; each screen is a binary split tree of panes; each pane
//! holds one or more tabs, and each tab is a [`Surface`]. Frontends (the
//! bundled TUI, or the cmux app over the control socket) subscribe to
//! [`MuxEvent`]s and read surface state; they never own terminal state
//! themselves, which is what makes the backend attachable.

mod agent_hooks;
mod apps;
pub mod backoff;
mod browser;
pub mod browser_host;
mod browser_provider;
pub mod cloud_conversations;
mod conversation_search;
mod conversation_store;
pub mod daemon_env;
mod debug_spans;
pub mod diagnostics;
mod event_bus;
#[cfg(unix)]
pub mod fs_ops;
mod git_ops;
#[cfg(unix)]
mod image_paste;
#[cfg(unix)]
mod image_paste_file;
#[cfg(unix)]
mod image_paste_ownership;
#[cfg(unix)]
mod image_paste_recovery;
#[cfg(unix)]
mod image_paste_storage;
mod journal_checkpoint;
mod journal_hooks;
mod journal_ingress;
mod journal_kernel;
mod journal_plugin;
mod journal_reducers;
mod machine_name;
mod model;
mod mux;
mod pairing;
mod program_status;
pub mod provider_management;
#[cfg(unix)]
mod pty_write;
mod remote_relay_state;
mod request_origin;
pub mod resource;
mod resource_api;
mod resource_mutation;
pub mod resource_name;
mod resource_router;
mod resource_screen;
mod resource_selector;
mod resource_tab;
mod session_shutdown;
mod shell_history;
mod shell_integration;
mod short_id;
mod sidebar_resource;
pub mod sizing_policy;
mod state;
pub mod store_schemas;
mod stream_interrupt;
mod surface;
#[cfg(unix)]
mod terminal_backend;
mod terminal_end;
#[cfg(unix)]
mod terminal_loss_cause;
#[cfg(unix)]
mod terminal_loss_log;
mod terminal_metadata;
pub mod terminal_respawn_text;
#[cfg(windows)]
mod windows_processes;
mod workspace_registry;

pub mod layout;
pub mod platform;
#[cfg(unix)]
mod process_identity;
pub mod process_resources;
pub mod server;
pub mod terminal_host;
pub mod terminal_host_protocol;
pub mod terminal_host_runtime;
#[cfg(unix)]
pub mod unix_process_scope;
pub mod user_settings;

pub use agent_hooks::{
    AGENT_HOOK_MANIFEST_VERSION, AGENT_HOOK_PRODUCER_ID, agent_hook_journal_ingress,
    stamp_agent_hook_observed_now,
};
pub use browser::{BrowserFailure, TRANSPORT_SAFE_CAPTURE_MEGAPIXELS, normalize_url};
/// The owner raises its open-file soft limit at start; terminal hosts and
/// PTY children get the original back (`cmux_pty::open_files`).
#[cfg(unix)]
pub use cmux_pty::{OPEN_FILE_LIMIT_CEILING, OpenFileLimit, raise_open_file_limit};
pub use event_bus::{MuxEventBroadcaster, MuxEventReceiver};
pub(crate) use journal_ingress::contention::JournalContention;
pub use journal_ingress::{FrontendFocusTarget, FrontendJournalEvent};
pub use journal_plugin::{JournalPluginOptions, JournalPluginRuntime};
pub use layout::{
    DEFAULT_VIEWPORT_PANE_WIDTH, ExactSplitResize, ExactViewportSplitResize, LayoutResult,
    MAX_VIEWPORT_PANE_WIDTH, MIN_VIEWPORT_PANE_WIDTH, Rect, SplitEdge, SplitResize,
    ViewportColumnRect, ViewportLayoutResult, VirtualRect, directional_neighbor,
    exact_split_for_pane_edge, exact_split_for_pane_edge_with_viewport, layout_screen,
    layout_screen_with_viewport, split_for_pane_edge, split_sides, zellij_default_pane_layout,
};
pub use model::{
    ColumnDock, DockEdge, DockMode, DockRole, Node, Pane, Screen, State, ViewportColumn, Workspace,
};
pub(crate) use mux::BatchCloseTarget;
pub use mux::{
    AgentRecord, AgentSource, AgentState, AppliedLayout, AppliedPane, CellPixelUpdate,
    CellPixelUpdateFailure, ColumnDockError, ColumnDockOutcome, ConfigReloadError,
    DiagnosticReporter, Direction, GraphicsStatus, LayoutLeafSpec, LayoutRatioError, LayoutSpec,
    LayoutUndoError, LayoutUndoResult, MachineUsage, Mux, MuxEvent, NotificationEvent,
    NotificationLevel, NotificationSource, ProviderWorkspaceAuthority,
    ProviderWorkspaceAuthorityStatus, ProviderWorkspaceAuthorityUpdateError, ResourceNotification,
    RowHeightsOutcome, RowsError, RunPlacement, ScreenDestination, ScreenGroupOutcome,
    ScreenMoveOutcome, ScreenSpec, SidebarPluginOptions, SidebarPluginStatus, SurfaceNotification,
    SurfaceResizeReporter, TabDirectory, TabDragOutcome, TabDropEdge, TabGroupDestination,
    TabGroupOutcome, TabNotificationAck, TabPinChange, TerminalSpawnOptions, TreeDecorations,
    TreeDelta, TreeDeltaKind, ViewportWidthError, WorkspaceGroupChange, WorkspaceMutationResult,
    WorkspacePlacement, ZoomMode, ZoomState,
};
pub use mux::{
    DEFAULT_TERMINAL_REAP_GRACE, IDLE_CLOSE_REAP_INTERVAL, IdleTerminalReaper,
    MAX_TERMINAL_REAP_GRACE, TerminalReaper, start_idle_terminal_reaper, start_terminal_reaper,
    validate_terminal_reap_grace,
};
pub use pairing::{PairingChallenge, PairingDecision, PairingError};
pub use remote_relay_state::{
    BindRefused, CLOSE_STREAMS_AFTER, PairingRecords, RECHECK_INTERVAL, REFUSE_NEW_STREAMS_AFTER,
    RelayLock, RelayStateError, RevocationClock,
};
pub use resource_api::{ResourceMachineRequest, ResourceMachineService};
pub use resource_selector::{ResolvedResourcePath, ResourceSelectors, ResourceTarget};
pub use short_id::assign_short_ids;
pub use surface::{
    AttachFrame, AttachFrameReceiver, AttachStream, BrowserAttachState, BrowserFrame,
    BrowserFrameStream, BrowserFrameUpdate, BrowserSource, BrowserStatus,
    CLEAR_HISTORY_FALLBACK_UNREPRESENTABLE_ERROR, CLEAR_HISTORY_FALLBACK_WRITE_TIMEOUT_ERROR,
    CLEAR_HISTORY_PRESERVATION_ERROR, CLEAR_HISTORY_STREAM_TIMEOUT_ERROR, ClearHistoryDelivery,
    ClearHistoryFailure, DEFAULT_SCROLLBACK_LIMIT_BYTES, DefaultColors, GuardedMouseEncode,
    PointerSemanticProbe, PointerSnapshotProbe, RenderAttachFrame, RenderAttachStream, Surface,
    SurfaceKind, SurfaceOptions, SurfaceRenderFrame, TerminalColors, TerminalHostConnectionState,
    TerminalPointerSnapshot,
};
pub use surface::{apply_terminal_color_overrides, default_child_term};
pub use workspace_registry::{
    Actor, FrontendProjection, JournalAppendCommit, JournalAuthority, JournalCheckpoint,
    JournalClass, JournalContentRef, JournalEventSchema, JournalHookDeliveryPolicy,
    JournalHookExec, JournalHookFilter, JournalHookManifest, JournalHookRegex, JournalHookRetry,
    JournalIngress, JournalProducer, JournalProducerManifest, JournalReplayPolicy, JournalSegment,
    JournalSensitivity, JournalSubject, PersistentSessionStateReset,
    PersistentSessionStateResetPreview, PersistentSessionStateResetter, ProjectionCommit,
    RegistryCommit, RegistryEvent, RegistrySnapshot, RegistryWorkspace, SessionJournalPage,
    SessionJournalRecord, UnsupportedWorkspaceRegistrySchema, WorkspaceMutation, WorkspaceRegistry,
};

pub use cmux_remote_protocol::{REMOTE_CLIENT_MESSAGE_MAX_BYTES, REMOTE_SESSION_MESSAGE_MAX_BYTES};
pub use ghostty_vt::{CursorShape, Rgb};

pub type SurfaceId = u64;
pub type PaneId = u64;
pub type SplitId = u64;
pub type ScreenId = u64;
pub type WorkspaceId = u64;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SplitDir {
    /// Split into left/right columns.
    Right,
    /// Split into top/bottom rows.
    Down,
}

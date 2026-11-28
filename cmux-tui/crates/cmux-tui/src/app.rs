//! TUI event loop and tmux-like command handling.
//!
//! Runs against a [`Session`], which is either the in-process mux or a
//! remote session attached over the control socket. All state mutations
//! go through the session; the app only owns presentation state (render
//! snapshots, prefix arming, the current layout, hit map, selection, and
//! menu/prompt overlays).

mod ordered_session;
pub(crate) mod pairing_confirm;

mod remote_attach;
mod session_mutation;
mod surface_sync;

mod events;
mod frontend_journal;
mod host_input;
mod mux_ingress;

mod layout;
mod menu;
mod overlays;

mod graphics;
mod pane_projection;
mod pointer;
mod selection;
mod viewport;

mod frame_geometry;
mod machine_worker;
mod run;
mod status_command;
mod status_segments;
mod terminal_guard;

mod durable_notice;
mod machine_controller;
mod machine_ui;
mod sidebar_rails;

mod deferred_replay;
mod dispatch;
mod event_loop;
mod pointer_frame;
mod presentation;
mod session_apply;

mod config_status;
mod graphics_emit;
mod layout_sync;
mod render;

mod drag_resize;
mod input_admission;
mod input_dispatch;
mod selection_ops;
mod surface_focus;

mod keyboard;
mod machine_menus;
mod managed_ops;
mod pane_ops;
mod sidebar_keys;

mod actions;
mod browser_ops;
mod focus_nav;
mod menu_activate;
mod prompt_keys;

mod key_forward;
mod mouse_dispatch;
mod pty_mouse;
mod pty_write;
mod tab_moves;

mod clipboard;
mod left_down;
mod left_drag;
mod pointer_hover;

mod menu_build;
mod scroll_browser;
mod scrollbar_resize;

mod action_policy;
mod browser_keys;
mod clear_history;
mod client_view;
mod focus_history;
mod host_modes;
mod presentation_snapshot;
mod rail_selection;
mod render_pacing;

#[cfg(test)]
use std::cell::Cell;
use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

#[cfg(test)]
use cmux_tui_core::GuardedMouseEncode;
use cmux_tui_core::resource::FrontendProjectionPublicId;
use cmux_tui_core::sizing_policy::TerminalSizingMode;
use cmux_tui_core::{
    GraphicsStatus, MachineUsage, Mux, MuxEvent, PairingChallenge, PaneId, Rect, ScreenId,
    SurfaceId, VirtualRect, WorkspaceId,
};
use crossbeam_channel::Sender as SyncSender;
use crossterm::event::{MouseButton, MouseEvent, MouseEventKind};
use ghostty_vt::{KeyEncoder, KittyGraphicsSnapshot, RenderState, TerminalPointerSemanticSnapshot};

use self::action_policy::{
    action_available_in_mode, action_creates_destination, action_for_binding,
    action_is_frontend_local, action_prepares_pty_release, binding_matches, browser_only_action,
    deferred_paste_bytes, menu_action_prepares_pty_release, modeless_action_for_binding,
    provider_action_error_message, publishes_global_cell_metrics,
};
use self::browser_keys::{
    BrowserMouseDispatch, browser_hover_forward_allowed, browser_key_mapping, browser_modifiers,
};
use self::clear_history::{
    adjust_active_tab_after_removal, classify_clear_history_failure,
    localized_clear_history_failure, should_claim_clear_history_shortcut,
};
use self::client_view::{client_focus_identity, preserve_client_view};
use self::events::{
    AppEvent, OwnerReloadWorker, SessionEventSender, SessionEventWorker, SessionTrySendError,
};
#[cfg(test)]
use self::events::{EventCancellation, send_bounded_cancelable};
use self::focus_history::PaneFocusHistory;
#[cfg(test)]
use self::frame_geometry::{
    SidebarWidthOverrides, browser_content_size_for_rect, clamp_split_ratio_for_tab_bars,
    content_size_for_rect, rail_drag_width, sidebar_layout_for, sidebar_layout_for_state,
};
use self::frame_geometry::{pane_parts_for_rect, stacked_header_parts_for_rect};
#[cfg(test)]
use self::frontend_journal::FrontendJournalQueue;
use self::frontend_journal::FrontendJournalWorker;
use self::graphics::{GraphicIdentity, GraphicsSceneCache};
#[cfg(test)]
use self::host_input::{
    HostInputIngress, HostInputMessage, InputClass, read_crossterm_event,
    read_crossterm_event_with_clock,
};
use self::host_input::{HostInputRuntime, KeyboardIngress, TerminalInput};
#[cfg(test)]
use self::host_modes::outer_cursor_escape;
use self::host_modes::{
    canonical_terminal_content, host_mouse_capture_escape_if_changed, host_startup_input_modes,
    initial_applied_outer_cursor, initial_host_mouse_capture, outer_cursor_escape_if_changed,
};
use self::layout::SidebarLayout;
pub(crate) use self::layout::{
    FocusTarget, Hit, OmnibarHit, PaneArea, PaneEdge, RailKind, SidebarActionTarget,
};
#[cfg(test)]
use self::layout::{PaneViewportClip, RailPlacement, first_pane_by_id};
pub(crate) use self::machine_worker::install_mux_diagnostic_logger;
use self::machine_worker::{
    MachineActionWorker, MachineControllerCompletion, MachineUpdatePump, PendingMachineReplacement,
};
#[cfg(test)]
use self::machine_worker::{
    MachineSessionPreparation, MachineSubmitError, PreparedMachineAction, PreparedMachineSession,
    ensure_initial_for_machine_ui, recover_initial_workspace_failure,
    send_machine_controller_completion,
};
pub(crate) use self::menu::MenuItem;
pub(crate) use self::menu::context_menu::ContextMenu;
#[cfg(test)]
use self::menu::context_menu::pane_context_menu_groups;
#[cfg(test)]
use self::menu::items::{client_menu_item, size_menu_item};
use self::menu::items::{participant_key, size_mode_label};
#[cfg(test)]
use self::mux_ingress::{
    ForwardMuxOutcome, forward_mux_event, forward_mux_events, prepare_ordered_session,
    start_ordered_session,
};
use self::mux_ingress::{MuxTitleIngress, PtyFailureIngress};
use self::ordered_session::OrderedSession;
pub(crate) use self::overlays::{ConnectionDialogPhase, ConnectionTransaction, Prompt};
use self::overlays::{OmnibarState, PairingDialog, PromptTarget, ShortcutHelp, Toast};
use self::pane_projection::ViewportPaneAreaProjection;
#[cfg(test)]
use self::pane_projection::{
    PaneAreaProjection, browser_frame_source_crop, browser_source_crop, clip_horizontal_rect,
    rebuild_pane_areas, swept_viewport_size_leases,
};
pub(crate) use self::pointer::PaneContentGeneration;
#[cfg(test)]
use self::pointer::deferred::{DeferredInput, DeferredInputAdmission, DeferredReplayDisposition};
use self::pointer::deferred::{
    DeferredInputQueue, OuterCursorSpec, PendingPointerMotion, PointerRoutePhase,
    ReplayedInputContext, SemanticDestinationOutcome,
};
use self::pointer::route::{MachinePointerContext, MenuActionResource, RenderedPointerFrame};
#[cfg(test)]
use self::pointer::route::{
    PointerHitIdentity, PointerRouteIdentity, RenderedMenuLevel, RenderedPaneRoute,
};
use self::pointer::{Drag, TerminalPointerAdmissionResult};
#[cfg(test)]
use self::pointer::{
    PaneResizeDragTarget, PtyMousePressResult, TerminalPointerAdmission, TerminalPointerEncoding,
};
use self::presentation_snapshot::{
    FrontendFocusSnapshot, FrontendPresentationSnapshot, FrontendResizeSnapshot,
    FrontendViewportSnapshot, frontend_journal_event_id,
};
pub(crate) use self::rail_selection::WorkspaceRailSelection;
use self::rail_selection::{
    MachineRailCommand, WorkspaceRailTarget, rail_navigation_index, rail_page_size,
    workspace_creation_selection,
};
#[cfg(test)]
use self::remote_attach::{REMOTE_ATTACH_WORKER_LIMIT, remote_attach_background_limit};
use self::remote_attach::{
    RemoteSurfaceAttachAdmission, RemoteSurfaceAttachExecutor, RemoteSurfaceAttachJob,
};
#[cfg(test)]
use self::render_pacing::TERMINAL_PAINT_CADENCE;
use self::render_pacing::{RenderAction, TerminalPaintPacer};
#[cfg(test)]
use self::run::report_after_unwind;
pub(crate) use self::run::{RunOutcome, RunRequest, run_with_machine_updates};
pub(crate) use self::selection::Selection;
use self::selection::{
    RenderedStatusMessage, SelectionClickSequence, SelectionMode, SemanticSelectionCache,
    StatusMessageSelection,
};
use self::session_mutation::{
    MutationImpact, PendingSessionMutation, PendingSessionMutationState, SessionCompletion,
    SessionCompletionAction, SessionMutationOutcome, layout_undo_error_completion,
};
pub(crate) use self::status_segments::StatusSegmentView;
use self::status_segments::{ResolvedStatusSegments, StatusWorkerStop};
#[cfg(test)]
use self::status_segments::{StatusTemplateValues, expand_status_tokens, run_status_command};
#[cfg(test)]
use self::surface_sync::SurfaceAttachAfterObsoleteCheckHook;
use self::surface_sync::{
    RemoteRefreshClaim, SidebarPluginSyncClaim, SidebarPluginSyncState, SurfaceAttachClaim,
    SurfaceAttachClaimState, SurfaceAttachOutcome, SurfaceResizeClaim, SurfaceResizeClaimState,
    SurfaceResizeDecision, SurfaceResizeFailure, SurfaceResizeOwnership, SurfaceSyncFailureState,
    next_surface_sync_failure, record_surface_resize_dispatch_result,
    sidebar_plugin_status_settles_passive_claim, surface_sync_failure_blocks,
};
#[cfg(test)]
use self::terminal_guard::{
    HOST_KEYBOARD_QUERY_TIMEOUT, HostKeyboardProtocolOwnership, catch_renderer_panic,
    disable_host_keyboard_protocol, enable_host_keyboard_protocol, forward_host_input,
    keyboard_protocol_accepts, negotiate_host_keyboard_protocol_with, with_panic_stdout_lock,
};
use self::viewport::ViewportMotion;
#[cfg(test)]
use self::viewport::{
    VIEWPORT_ANIMATION_DURATION, pane_area_projection_work, reset_pane_area_projection_work,
};
use crate::browser_input::BrowserInputDispatcher;
#[cfg(test)]
use crate::browser_input::BrowserResizeFailure;
use crate::config::{Action, ChromeTheme, Config, SidebarView};
use crate::localization;
#[cfg(test)]
use crate::machine::MachineConnectRoute;
use crate::machine::{
    DurableNoticeDelivery, DurableProviderNotice, MachineKey, MachineRequest, MachineUiState,
    MachineUpdate,
};
use crate::pty_input::PtyInputDispatcher;
#[cfg(test)]
use crate::session::Session;
use crate::session::{ClientInfo, TreeView};
use crate::sidebar_files::FileBrowser;
use crate::sidebar_projection::{AgentOrderCache, ProjectionRailState};
use crate::ui::ReusableRowBuffer;
#[cfg(test)]
use crate::ui::graphics::{GraphicPlacement, GraphicSourceRect};
use crate::ui::graphics_writer::{GraphicsWriter, StdoutLock};
use crate::ui::input::TextInput;
#[cfg(test)]
use crate::ui::thumb_geometry;

#[cfg(test)]
thread_local! {
    static GRAPHICS_ROUTE_COMPARISONS: Cell<usize> = const { Cell::new(0) };
}

const DEFERRED_INPUT_CAPACITY: usize = 512;
const DEFERRED_INPUT_FIXED_BYTES: usize = 64;
const BRACKETED_PASTE_MARKER_BYTES: usize = 12;
const MAX_DEFERRED_INPUT_BYTES: usize = 4 * 1024 * 1024;
const LAYOUT_REFRESH_RETRIES: u8 = 1;
const BACKGROUND_REFRESH_RETRIES: u8 = 6;
const APP_EVENT_CAPACITY: usize = 4_096;
const PTY_FAILURE_CAPACITY: usize = 512;
const MACHINE_PROVIDER_RECONNECT_MAX_BACKOFF_EXPONENT: u8 = 5;
const DURABLE_NOTICE_RECENT_CAPACITY: usize = 64;
const DURABLE_NOTICE_QUEUE_CAPACITY: usize = 64;
const DURABLE_NOTICE_DISPLAY_DURATION: Duration = Duration::from_secs(4);
const DURABLE_NOTICE_ACK_MAX_BACKOFF_EXPONENT: u8 = 5;

/// A context-menu entry: what activating it does (the label is derived).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MenuAction {
    RenameClientMachine(MachineKey),
    RenameManagedMachine(MachineKey),
    DeleteManagedMachine(MachineKey),
    RestoreManagedMachine(MachineKey),
    PurgeManagedMachine(MachineKey),
    RenameWorkspace(WorkspaceId),
    RenameManagedWorkspace(WorkspaceId),
    CopyWorkspaceId(WorkspaceId),
    CloseWorkspace(WorkspaceId),
    DeleteManagedWorkspace(WorkspaceId),
    RestoreManagedWorkspace(usize),
    PurgeManagedWorkspace(usize),
    RenameScreen(ScreenId),
    CloseScreen(ScreenId),
    BrowserBack(PaneId),
    BrowserForward(PaneId),
    BrowserReload(PaneId),
    BrowserEditUrl(PaneId),
    BrowserCopyUrl(PaneId),
    BrowserActivate(PaneId),
    RenameTab(PaneId),
    RenameSurface(SurfaceId),
    MoveTabToWorkspace {
        surface: SurfaceId,
        workspace: Option<WorkspaceId>,
    },
    CopyTabId(PaneId),
    CopyPaneId(PaneId),
    CopyStatusMessage,
    NewPaneSmart(PaneId),
    NewTab(PaneId),
    NewBrowserTab(PaneId),
    SplitRight(PaneId),
    SplitDown(PaneId),
    CloseTab(PaneId),
    ClosePane(PaneId),
    TogglePaneZoom {
        pane: PaneId,
        zoomed: bool,
    },
    ToggleSidebar {
        visible: bool,
    },
    ToggleSidebarCompact {
        compact: bool,
    },
    FocusSidebar,
    ActivateSidebarProfile(usize),
    SetSidebarViewVisible {
        view: usize,
        visible: bool,
    },
    ShowShortcuts,
    SetClientSizing {
        surface: SurfaceId,
        client: u64,
        enabled: bool,
    },
    UseClientSize {
        surface: SurfaceId,
        client: u64,
    },
    RestoreAllClientSizing(SurfaceId),
    DisconnectClient(u64),
    /// Shared sizing (docs/shared-terminal-sizing.md): the terminal's mode.
    SetSizeMode {
        surface: SurfaceId,
        mode: TerminalSizingMode,
    },
    /// Toggle one participant's counts-toward-size choice. `participant`
    /// indexes the size state of `generation`, the one the menu showed.
    SetSizeCounts {
        surface: SurfaceId,
        generation: u64,
        participant: usize,
        counts: bool,
    },
    /// Disconnect one participant of the size state of `generation`.
    DisconnectSizeParticipant {
        surface: SurfaceId,
        generation: u64,
        participant: usize,
    },
    SelectProviderScope(usize),
    InvokeProviderAction(usize),
    CreateMachineFrom(usize),
    ConnectMachineTarget(usize),
    ConnectOtherMachine,
    /// A configured action from a customizable menu (for example a `+`
    /// button's right-click menu), targeting an optional pane.
    RunConfigured {
        action: Action,
        pane: Option<PaneId>,
    },
}

impl MenuAction {
    pub fn label(&self) -> &'static str {
        let menu = &localization::catalog().menu;
        match self {
            // Menus always wrap this variant in a labeled item; the catalog
            // label is the keyboard-help fallback only.
            MenuAction::RunConfigured { action, .. } => {
                localization::catalog().action_label(*action)
            }
            MenuAction::RenameClientMachine(_) | MenuAction::RenameManagedMachine(_) => {
                localization::catalog().sidebar.rename_machine
            }
            MenuAction::DeleteManagedMachine(_) => localization::catalog().sidebar.delete_machine,
            MenuAction::RestoreManagedMachine(_) => localization::catalog().sidebar.restore_machine,
            MenuAction::PurgeManagedMachine(_) => localization::catalog().sidebar.purge_machine,
            MenuAction::RenameWorkspace(_) => {
                localization::catalog().action_label(Action::RenameWorkspace)
            }
            MenuAction::RenameManagedWorkspace(_) => {
                localization::catalog().sidebar.rename_workspace
            }
            MenuAction::CopyWorkspaceId(_) => menu.copy_workspace_id,
            MenuAction::CloseWorkspace(_) => {
                localization::catalog().action_label(Action::CloseWorkspace)
            }
            MenuAction::DeleteManagedWorkspace(_) => {
                localization::catalog().sidebar.delete_workspace
            }
            MenuAction::RestoreManagedWorkspace(_) => {
                localization::catalog().sidebar.restore_workspace
            }
            MenuAction::PurgeManagedWorkspace(_) => localization::catalog().sidebar.purge_workspace,
            MenuAction::RenameScreen(_) => {
                localization::catalog().action_label(Action::RenameScreen)
            }
            MenuAction::CloseScreen(_) => localization::catalog().action_label(Action::CloseScreen),
            MenuAction::BrowserBack(_) => localization::catalog().action_label(Action::BrowserBack),
            MenuAction::BrowserForward(_) => {
                localization::catalog().action_label(Action::BrowserForward)
            }
            MenuAction::BrowserReload(_) => {
                localization::catalog().action_label(Action::BrowserReload)
            }
            MenuAction::BrowserEditUrl(_) => {
                localization::catalog().action_label(Action::BrowserEditUrl)
            }
            MenuAction::BrowserCopyUrl(_) => menu.copy_url,
            MenuAction::BrowserActivate(_) => menu.show_in_chrome,
            MenuAction::RenameTab(_) | MenuAction::RenameSurface(_) => {
                localization::catalog().action_label(Action::RenameTab)
            }
            MenuAction::MoveTabToWorkspace { workspace: None, .. } => menu.move_tab_new_workspace,
            MenuAction::MoveTabToWorkspace { .. } => menu.move_tab_workspace,
            MenuAction::CopyTabId(_) => menu.copy_tab_id,
            MenuAction::CopyPaneId(_) => menu.copy_pane_id,
            MenuAction::CopyStatusMessage => menu.copy_message,
            MenuAction::NewPaneSmart(_) => {
                localization::catalog().action_label(Action::NewPaneSmart)
            }
            MenuAction::NewTab(_) => localization::catalog().action_label(Action::NewTab),
            MenuAction::NewBrowserTab(_) => {
                localization::catalog().action_label(Action::NewBrowserTab)
            }
            MenuAction::SplitRight(_) => localization::catalog().action_label(Action::SplitRight),
            MenuAction::SplitDown(_) => localization::catalog().action_label(Action::SplitDown),
            MenuAction::CloseTab(_) => localization::catalog().action_label(Action::CloseTab),
            MenuAction::ClosePane(_) => localization::catalog().action_label(Action::ClosePane),
            MenuAction::TogglePaneZoom { zoomed: false, .. } => menu.maximize_pane,
            MenuAction::TogglePaneZoom { zoomed: true, .. } => menu.restore_pane_layout,
            MenuAction::ToggleSidebar { visible: false } => menu.show_sidebar,
            MenuAction::ToggleSidebar { visible: true } => menu.hide_sidebar,
            MenuAction::ToggleSidebarCompact { compact: false } => menu.compact_sidebar,
            MenuAction::ToggleSidebarCompact { compact: true } => menu.full_sidebar,
            MenuAction::FocusSidebar => menu.focus_sidebar,
            MenuAction::ActivateSidebarProfile(_) => menu.sidebar_profiles,
            MenuAction::SetSidebarViewVisible { visible: true, .. } => menu.show_sidebar_view,
            MenuAction::SetSidebarViewVisible { visible: false, .. } => menu.hide_sidebar_view,
            MenuAction::ShowShortcuts => {
                localization::catalog().action_label(Action::ShowShortcuts)
            }
            MenuAction::SetClientSizing { enabled: true, .. } => menu.include_client_size,
            MenuAction::SetClientSizing { enabled: false, .. } => menu.excluded,
            MenuAction::UseClientSize { .. } => menu.use_only_client_size,
            MenuAction::RestoreAllClientSizing(_) => menu.restore_all_client_sizing,
            MenuAction::DisconnectClient(_) => menu.disconnect_client,
            MenuAction::SetSizeMode { mode, .. } => size_mode_label(*mode),
            MenuAction::SetSizeCounts { .. } => menu.size_counts,
            MenuAction::DisconnectSizeParticipant { .. } => menu.size_disconnect,
            MenuAction::SelectProviderScope(_) | MenuAction::InvokeProviderAction(_) => {
                localization::catalog().sidebar.provider_actions
            }
            MenuAction::CreateMachineFrom(_) => localization::catalog().sidebar.new_machine,
            MenuAction::ConnectMachineTarget(_) => localization::catalog().sidebar.connect_machine,
            MenuAction::ConnectOtherMachine => localization::catalog().sidebar.other_host,
        }
    }
}

fn keyboard_action_for_menu(action: MenuAction) -> Option<Action> {
    match action {
        MenuAction::RenameWorkspace(_) => Some(Action::RenameWorkspace),
        MenuAction::CloseWorkspace(_) => Some(Action::CloseWorkspace),
        MenuAction::RenameScreen(_) => Some(Action::RenameScreen),
        MenuAction::CloseScreen(_) => Some(Action::CloseScreen),
        MenuAction::BrowserBack(_) => Some(Action::BrowserBack),
        MenuAction::BrowserForward(_) => Some(Action::BrowserForward),
        MenuAction::BrowserReload(_) => Some(Action::BrowserReload),
        MenuAction::BrowserEditUrl(_) => Some(Action::BrowserEditUrl),
        MenuAction::RenameTab(_) => Some(Action::RenameTab),
        MenuAction::NewPaneSmart(_) => Some(Action::NewPaneSmart),
        MenuAction::NewTab(_) => Some(Action::NewTab),
        MenuAction::NewBrowserTab(_) => Some(Action::NewBrowserTab),
        MenuAction::SplitRight(_) => Some(Action::SplitRight),
        MenuAction::SplitDown(_) => Some(Action::SplitDown),
        MenuAction::CloseTab(_) => Some(Action::CloseTab),
        MenuAction::ClosePane(_) => Some(Action::ClosePane),
        MenuAction::TogglePaneZoom { .. } => Some(Action::ZoomPane),
        MenuAction::ToggleSidebar { .. } => Some(Action::ToggleSidebar),
        MenuAction::ToggleSidebarCompact { .. } => Some(Action::ToggleSidebarCompact),
        MenuAction::FocusSidebar => Some(Action::FocusSidebar),
        MenuAction::ShowShortcuts => Some(Action::ShowShortcuts),
        _ => None,
    }
}

impl Prompt {
    fn new(label: impl Into<String>, buffer: String, target: PromptTarget) -> Self {
        Prompt {
            label: label.into(),
            input: TextInput::new(buffer),
            target,
            rect: Rect::default(),
            input_rect: Rect::default(),
            clear: Rect::default(),
            ok: Rect::default(),
            cancel: Rect::default(),
        }
    }
}

#[cfg(test)]
type TimeoutDrainHook = Box<dyn FnOnce(&mut App) + Send>;

pub struct App {
    pub session: OrderedSession,
    /// The local mux owned by this process. Unlike `session`, this does not
    /// change when the machine controller replaces the presented session.
    owner_mux: Option<Arc<Mux>>,
    /// The machine-catalog key that presents `owner_mux`, when machine mode is active.
    owner_machine: Option<MachineKey>,
    owner_reload_worker: Option<OwnerReloadWorker>,
    session_event_worker: Option<SessionEventWorker>,
    session_generation: u64,
    app_events: SyncSender<AppEvent>,
    frontend_journal: FrontendJournalWorker,
    frontend_projection_id: FrontendProjectionPublicId,
    last_frontend_presentation: Option<FrontendPresentationSnapshot>,
    outer_size: (u16, u16),
    host_input: HostInputRuntime,
    machine_action_worker: Option<MachineActionWorker>,
    machine_action_in_flight: bool,
    machine_action_request: Option<MachineRequest>,
    machine_action_connection_attempt: Option<u64>,
    canceled_machine_connection_attempt: Option<u64>,
    machine_action_intent_generation: Option<u64>,
    machine_selection_intent: Option<MachineKey>,
    machine_selection_generation: u64,
    machine_presented: Option<MachineKey>,
    machine_deleted_rail_index: Option<usize>,
    machine_provider_reconnect_attempts: u8,
    machine_provider_reconnect_retry_at: Option<Instant>,
    pending_machine_replacement: Option<PendingMachineReplacement>,
    machine_update_pump: Option<MachineUpdatePump>,
    machine_update_generation: u64,
    durable_notices: VecDeque<QueuedDurableNotice>,
    recent_durable_notices: VecDeque<DurableNoticeDelivery>,
    painted_durable_notice_this_frame: Option<DurableNoticeDelivery>,
    pending_durable_notice_acks: VecDeque<DurableNoticeDelivery>,
    durable_notice_ack_in_flight: Option<DurableNoticeDelivery>,
    durable_notice_ack_failures: u8,
    durable_notice_ack_retry_at: Option<Instant>,
    pub config: Config,
    #[cfg(test)]
    config_reload_applications: usize,
    pub chrome: ChromeTheme,
    pub tree: TreeView,
    tab_locations: HashMap<SurfaceId, [usize; 4]>,
    pub render_states: HashMap<SurfaceId, RenderState>,
    pub(crate) chrome_row_scratch: ReusableRowBuffer,
    /// Reusable storage for the ordered sidebar kind snapshot taken during a
    /// frame. The draw loop takes this out while dispatching so mutable rail
    /// renderers do not borrow the layout across calls.
    pub(crate) sidebar_kind_scratch: Vec<RailKind>,
    /// Terminal grid dimensions from the frame actually drawn for each
    /// surface. Pointer routing uses this snapshot so resize transitions do
    /// not target blank pane margins or wait on the PTY's terminal lock.
    pub rendered_terminal_sizes: HashMap<SurfaceId, (u16, u16)>,
    /// Pointer-routing semantics captured under the same terminal lock as
    /// each rendered frame.
    pub(crate) rendered_terminal_pointer_semantics:
        HashMap<SurfaceId, TerminalPointerSemanticSnapshot>,
    /// Content identity captured from the terminal or browser frame that was
    /// actually drawn for each pane.
    pub(crate) rendered_pane_content_generations: HashMap<SurfaceId, PaneContentGeneration>,
    desired_outer_cursor: OuterCursorSpec,
    applied_outer_cursor: Option<OuterCursorSpec>,
    /// Host mouse-capture state this client last asserted. Full-TUI clients
    /// always capture; a scoped attach client mirrors the inner terminal's
    /// mouse-tracking state so the host owns clicks and selection whenever
    /// the inner application did not request mouse input.
    host_mouse_capture_applied: Option<bool>,
    pub graphics_writer: Option<GraphicsWriter>,
    next_graphics_submission: u64,
    pending_graphics_submission: Option<u64>,
    pending_graphics_snapshot: Option<Vec<GraphicIdentity>>,
    pending_graphics_affected_rect: Option<Rect>,
    /// Graphics placements confirmed written to the outer terminal.
    last_graphics_snapshot: Vec<GraphicIdentity>,
    pub graphics_supported: bool,
    graphics_host_scene_reset_pending: bool,
    graphics_scene_cache: GraphicsSceneCache,
    graphics_dirty_surfaces: HashSet<SurfaceId>,
    stdout_lock: Arc<StdoutLock>,
    pub pane_areas: Vec<PaneArea>,
    viewport_projection: ViewportPaneAreaProjection,
    viewport_layout: Vec<(PaneId, VirtualRect)>,
    viewport_stacked_headers: HashSet<PaneId>,
    viewport_states: HashMap<ScreenId, ViewportMotion>,
    viewport_virtual_width: u64,
    viewport_offset: u64,
    pane_focus_history: PaneFocusHistory,
    /// Last focus reported to the mux, None until a baseline is adopted from
    /// the session's own tree so adoption never echoes back as a mutation.
    reported_focus: Option<crate::session::ClientFocus>,
    /// Durable identity for per-client focus memory on the mux
    /// (client-focus-v1); None when no config directory is available.
    client_focus_id: Option<String>,
    /// Terminal cells actually represented by the last rendered snapshot.
    /// Foreign-viewer padding outside these bounds is display-only.
    pub(crate) rendered_terminal_bounds: HashMap<SurfaceId, Rect>,
    /// Kitty graphics captured from the exact immutable terminal frame drawn
    /// for each visible surface. Graphics emission must not render again,
    /// because doing so would consume remote damage independently of text.
    pub(crate) rendered_kitty_graphics: HashMap<SurfaceId, Arc<KittyGraphicsSnapshot>>,
    /// Surfaces whose active tabs occupy the current viewport or an active
    /// animation sweep. Attach streams may outlive this set, but only members
    /// hold size leases.
    visible_size_surfaces: HashSet<SurfaceId>,
    /// Hidden leases stay owned until the server confirms their idempotent
    /// release. Failures clear this set so a later layout pass retries them.
    pending_size_releases: HashSet<SurfaceId>,
    geometry_authority_surface: Option<SurfaceId>,
    pub prefix_armed: bool,
    pub session_label: String,
    /// Machine-level model spend readout from the session's daemon; `None`
    /// hides the sidebar readout.
    pub machine_usage: Option<MachineUsage>,
    /// When set, render only this PTY surface without session chrome.
    surface_only: Option<SurfaceId>,
    pub sidebar_visible: bool,
    pub sidebar_compact: bool,
    pub focus: FocusTarget,
    pub sidebar_focus_pending: bool,
    pub machine_ui: Option<MachineUiState>,
    machine_pointer_context_cache: Option<Arc<MachinePointerContext>>,
    pub sidebar_view: SidebarView,
    pub sidebar_files: FileBrowser,
    pub sidebar_workspace_selection: usize,
    pub(crate) sidebar_recoverable_workspace_selection: usize,
    pub(crate) workspace_rail_selection: WorkspaceRailSelection,
    pub(crate) machine_rail_scroll: usize,
    pub(crate) machine_footer_scroll: usize,
    pub(crate) workspace_rail_scroll: usize,
    pub(crate) workspace_footer_scroll: usize,
    pub(crate) tabs_rail_selection: usize,
    pub(crate) tabs_rail_scroll: usize,
    pub(crate) tabs_footer_scroll: usize,
    projection_rails: HashMap<String, ProjectionRailState>,
    projection_order_cache: AgentOrderCache,
    pub(crate) machine_rail_follow_selection: bool,
    pub(crate) workspace_rail_follow_selection: bool,
    pub(crate) tabs_rail_follow_selection: bool,
    sidebar_followed_surface: Option<SurfaceId>,
    /// Width of the sidebar in the current frame (0 when hidden).
    pub sidebar_width: u16,
    pub machine_sidebar_width: u16,
    pub tabs_sidebar_width: u16,
    pub sidebar_layout: SidebarLayout,
    pub sidebar_plugin_surface: Option<SurfaceId>,
    pub sidebar_plugin_error: Option<String>,
    pub sidebar_plugin_retry_after_ms: Option<u64>,
    sidebar_plugin_retry_at: Option<Instant>,
    sidebar_width_override: Option<u16>,
    machine_sidebar_width_override: Option<u16>,
    tabs_sidebar_width_override: Option<u16>,
    projection_sidebar_width_overrides: HashMap<String, u16>,
    /// Session-local visibility overrides, keyed by profile and stable view id.
    hidden_sidebar_views: HashMap<String, HashSet<String>>,
    /// Pane region of the current frame (screen minus sidebar/status).
    pub content_area: Rect,
    /// Clickable regions of the current frame, rebuilt by the renderers.
    pub hits: Vec<(Rect, Hit)>,
    /// Per-pane tab-bar scroll offset (first visible tab index), for
    /// panes whose tabs overflow the bar. Presentation state only.
    pub tab_scroll: HashMap<PaneId, usize>,
    /// Last mouse position; tab-bar controls (+, ‹, ›) under it render
    /// a hover highlight.
    pub hover: Option<(u16, u16)>,
    pub menu: Option<ContextMenu>,
    pub clients: Vec<ClientInfo>,
    pub client_border_labels: HashMap<SurfaceId, String>,
    /// Shared-sizing border labels by terminal; `None` hides the label.
    /// Takes precedence over `client_border_labels` for its terminals.
    pub size_state_labels: HashMap<SurfaceId, Option<String>>,
    pub prompt: Option<Prompt>,
    pub(crate) connection_transaction: Option<ConnectionTransaction>,
    next_connection_attempt: u64,
    pending_provider_action: Option<MachineRequest>,
    pub pairing_dialog: Option<PairingDialog>,
    pairing_queue: VecDeque<PairingChallenge>,
    pub shortcut_help: Option<ShortcutHelp>,
    pub omnibar: Option<OmnibarState>,
    pub toast: Option<Toast>,
    pub(crate) shake_frames: u8,
    pub selection: Option<Selection>,
    selection_generation: u64,
    selection_mode: SelectionMode,
    selection_mode_surface: Option<SurfaceId>,
    selection_click_sequence: Option<SelectionClickSequence>,
    semantic_selection_cache: Option<SemanticSelectionCache>,
    status_selection: Option<StatusMessageSelection>,
    rendered_status_message: Option<RenderedStatusMessage>,
    /// The last status message written to the client log, so a message that
    /// stays on screen across frames is recorded once.
    logged_status_message: Option<String>,
    /// The most recent informational provider notice routed through the
    /// status line, so the client log records it as INFO, not ERROR.
    status_notice_text: Option<String>,
    input_revision: u64,
    pub status_message: Option<String>,
    pub cell_pixels: (u16, u16),
    /// Whether the terminal pointer is currently the hand shape (over a
    /// clickable element); tracked to avoid re-emitting OSC 22.
    pointer_shape: bool,
    last_browser_hover: Option<(SurfaceId, u16, u16, u64)>,
    /// Off-loop forwarder for browser input: CDP/socket round trips must
    /// never run on the event-loop thread (see `browser_input`).
    browser_input: BrowserInputDispatcher,
    pty_input: PtyInputDispatcher,
    deferred_input: DeferredInputQueue,
    /// Latest passive pointer position retained while the rendered hit map is stale.
    pending_pointer_motion: Option<PendingPointerMotion>,
    deferred_input_sequence: u64,
    next_semantic_destination_intent: u64,
    latest_semantic_destination_intent: Option<u64>,
    semantic_destination_outcomes: HashMap<u64, SemanticDestinationOutcome>,
    /// Pointer routing snapshot for the frame that was last committed to the terminal.
    rendered_pointer_frame: RenderedPointerFrame,
    pointer_route_phase: PointerRoutePhase,
    pointer_focus_generation: u64,
    layout_refresh_retries_remaining: u8,
    background_refresh_attempts: u8,
    background_refresh_retry_at: Option<Instant>,
    last_applied_refresh_sequence: u64,
    applied_destination_generation: u64,
    pending_session_completions: VecDeque<SessionCompletion>,
    mux_titles: Arc<MuxTitleIngress>,
    pty_failures: Arc<PtyFailureIngress>,
    mux_recovery_generation: Arc<AtomicU64>,
    drag: Option<Drag>,
    active_pointer_buttons: HashSet<MouseButton>,
    ignored_pty_mouse_buttons: HashSet<MouseButton>,
    #[cfg(test)]
    timeout_drain_hook: Option<TimeoutDrainHook>,
    encoder: KeyEncoder,
    encode_buf: Vec<u8>,
    quit: bool,
    /// Latest output per status-bar command segment, keyed by the segment's
    /// combined left-then-right index. Written by the status command worker.
    status_command_outputs: Arc<Mutex<HashMap<usize, String>>>,
    /// Stop signal for the running status segment workers, if any.
    status_command_worker_stop: Option<Arc<StatusWorkerStop>>,
    /// Coalesces status redraw pokes across workers: set when an event is
    /// in flight, cleared when the event loop consumes it.
    status_poke_pending: Arc<AtomicBool>,
    /// One worker thread per configured status command segment.
    status_command_workers: Vec<JoinHandle<()>>,
    /// Stopped worker generations that have not finished yet; bounded, so
    /// reload storms cannot stack live workers.
    retiring_status_workers: Vec<JoinHandle<()>>,
    /// Bumped by segment workers when any command output changes; part of
    /// the resolved-segment cache fingerprint.
    status_outputs_generation: Arc<AtomicU64>,
    /// Resolved status segments, rebuilt only when the fingerprint of their
    /// inputs changes, so drawing does not re-expand templates every frame.
    status_segments_cache: Option<(u64, Arc<ResolvedStatusSegments>)>,
}

struct QueuedDurableNotice {
    notice: DurableProviderNotice,
    painted_at: Option<Instant>,
}

impl App {
    pub fn is_surface_only(&self) -> bool {
        self.surface_only.is_some()
    }

    fn presenting_owner_session(&self) -> bool {
        if self.owner_mux.is_none() {
            return false;
        }
        match self.owner_machine {
            Some(owner) => self.machine_presented == Some(owner),
            None => self.machine_presented.is_none(),
        }
    }

    fn owner_shutdown_requested(&self) -> bool {
        self.owner_mux.as_ref().is_some_and(|mux| mux.daemon_shutdown_requested())
    }

    pub fn session_available(&self) -> bool {
        self.machine_ui.as_ref().is_none_or(|machine| {
            machine.session_available && self.machine_selection_intent == self.machine_presented
        })
    }

    fn handle(&mut self, event: AppEvent) -> anyhow::Result<RenderAction> {
        let action = self.handle_inner(event, None, None)?;
        self.mark_pointer_route_for_rebuild(action);
        Ok(action)
    }

    fn handle_replayed_input(
        &mut self,
        input: TerminalInput,
        sequence: u64,
        replay_context: Option<ReplayedInputContext>,
    ) -> anyhow::Result<RenderAction> {
        let action =
            self.handle_inner(AppEvent::NormalizedInput(input), Some(sequence), replay_context)?;
        self.mark_pointer_route_for_rebuild(action);
        Ok(action)
    }

    fn handle_inner(
        &mut self,
        event: AppEvent,
        input_sequence: Option<u64>,
        replay_context: Option<ReplayedInputContext>,
    ) -> anyhow::Result<RenderAction> {
        let event = match event {
            AppEvent::SessionScoped { generation, event }
                if generation == self.session_generation =>
            {
                *event
            }
            AppEvent::SessionScoped { .. } => return Ok(RenderAction::None),
            event => event,
        };
        let event = match event {
            AppEvent::Input(input) => {
                let mut input = TerminalInput::from_event(input);
                if let TerminalInput::Keyboard(key) = &mut input {
                    key.resolve_macos_option_as_alt(self.config.keys.macos_option_as_alt);
                    if key.is_composing() || key.is_modifier_only() {
                        return Ok(RenderAction::None);
                    }
                }
                self.input_revision = self.input_revision.wrapping_add(1);
                input = match input {
                    TerminalInput::Keyboard(key) => match self.resolve_keyboard_ingress(key) {
                        KeyboardIngress::Routed(input) => input,
                        KeyboardIngress::Handled(action) => {
                            let dismissed = self.dismiss_painted_durable_notice();
                            return Ok(if dismissed {
                                action.merge(RenderAction::Draw)
                            } else {
                                action
                            });
                        }
                        KeyboardIngress::Ignored => return Ok(RenderAction::None),
                    },
                    input => input,
                };
                if input.retained_bytes() > MAX_DEFERRED_INPUT_BYTES {
                    self.status_message = Some(
                        match &input {
                            TerminalInput::Paste(_) => {
                                localization::catalog().terminal.paste_text_too_large
                            }
                            TerminalInput::Keyboard(_) | TerminalInput::ClearHistoryKey(_) => {
                                localization::catalog().terminal.keyboard_text_too_large
                            }
                            _ => unreachable!("fixed-size input cannot exceed the byte limit"),
                        }
                        .to_string(),
                    );
                    return Ok(RenderAction::Draw);
                }
                AppEvent::NormalizedInput(input)
            }
            event => event,
        };
        if let AppEvent::NormalizedInput(input) = &event
            && input.is_keyboard_or_paste()
        {
            let current_pairing = self.pairing_dialog.as_ref().map(|dialog| dialog.challenge.id);
            let replayed_pairing_changed = replay_context
                .as_ref()
                .and_then(|context| context.admission.as_ref())
                .is_some_and(|admission| admission.pairing_request != current_pairing);
            if replayed_pairing_changed || !self.pairing_identity_matches_rendered_frame() {
                // Pairing approval is a trusted action. Input captured before
                // the current pairing identity was visible must never approve
                // it or reach UI covered by a replacement dialog.
                return Ok(RenderAction::None);
            }
        }
        match &event {
            AppEvent::Mux(MuxEvent::LayoutChanged(_)) => {
                self.session.refresh_remote_tree_if_stale();
            }
            AppEvent::NormalizedInput(input) if input.is_routable() => {
                self.session.refresh_remote_tree_if_stale();
            }
            AppEvent::Mux(MuxEvent::TreeChanged) => {
                if self.session.remote_tree_is_stale() {
                    self.session.refresh_remote_tree_if_stale();
                } else {
                    self.session.refresh_remote_tree_background();
                }
            }
            _ => {}
        }
        if matches!(&event, AppEvent::Mux(MuxEvent::TreeChanged | MuxEvent::LayoutChanged(_))) {
            self.session.clear_surface_sync_failures();
        }
        if let AppEvent::NormalizedInput(TerminalInput::Mouse(
            mouse @ MouseEvent { kind: MouseEventKind::Moved, .. },
        )) = &event
        {
            let mouse = *mouse;
            if self.pointer_route_is_stale_for_mouse(&mouse)
                || self.fresh_pointer_motion_must_follow_deferred(input_sequence)
            {
                self.retain_pointer_motion_with_sequence(
                    mouse,
                    input_sequence,
                    replay_context
                        .as_ref()
                        .and_then(|context| context.pointer.as_ref())
                        .map(|pointer| pointer.focus_generation),
                );
                return Ok(RenderAction::None);
            }
        }
        let event = match event {
            AppEvent::NormalizedInput(input @ TerminalInput::Mouse(mouse))
                if self.pointer_route_is_stale_for_mouse(&mouse)
                    && !self.input_can_update_pending_mutation(&input) =>
            {
                return Ok(self.defer_input_with_sequence(
                    input,
                    input_sequence,
                    replay_context.as_ref().and_then(|context| context.pointer.clone()),
                    replay_context.as_ref().and_then(|context| context.admission.clone()),
                ));
            }
            event => event,
        };
        let event = match event {
            AppEvent::NormalizedInput(input)
                if input.is_routable()
                    && self.fresh_input_must_follow_deferred(&input, input_sequence)
                    && !self.input_can_overtake_deferred(&input) =>
            {
                return Ok(self.defer_input_with_sequence(
                    input,
                    input_sequence,
                    replay_context.as_ref().and_then(|context| context.pointer.clone()),
                    replay_context.as_ref().and_then(|context| context.admission.clone()),
                ));
            }
            event => event,
        };
        let client_owned = match &event {
            AppEvent::NormalizedInput(input) => {
                replay_context.as_ref().and_then(|context| context.admission.as_ref()).map_or_else(
                    || self.input_is_client_owned(input),
                    |admission| admission.client_owned,
                )
            }
            _ => false,
        };
        let missing_surface = match &event {
            AppEvent::NormalizedInput(input) if !client_owned => self
                .missing_input_surface_for_admission(
                    input,
                    replay_context.as_ref().and_then(|context| context.admission.as_ref()),
                ),
            _ => None,
        };
        let mut terminal_pointer_admission = None;
        if let AppEvent::NormalizedInput(input) = &event {
            let pointer_has_capture = match input {
                TerminalInput::Mouse(mouse) => self.pointer_has_capture(mouse.kind),
                _ => false,
            };
            if let TerminalInput::Mouse(mouse) = input
                && !pointer_has_capture
            {
                let rendered_route = self.rendered_pointer_route_for_mouse(mouse);
                let replayed_route_changed = replay_context
                    .as_ref()
                    .and_then(|context| context.pointer.as_ref())
                    .is_some_and(|pointer| {
                        pointer.route.as_ref().is_some_and(|expected| {
                            pointer.pointer_map_generation
                                != self.rendered_pointer_frame.pointer_map_generation
                                || expected != &rendered_route
                        })
                    });
                if replayed_route_changed {
                    return Ok(RenderAction::None);
                }
                if !Self::mouse_opens_cmux_context_menu(mouse)
                    && let Some((surface, expected_generation)) =
                        rendered_route.browser_content_generation()
                    && missing_surface != Some(surface)
                {
                    let Some(expected_generation) = expected_generation else {
                        return Ok(RenderAction::None);
                    };
                    if !self.session.surface(surface).is_some_and(|surface| {
                        surface.browser_accepts_pointer_frame(expected_generation)
                    }) {
                        return Ok(RenderAction::None);
                    }
                }
                match self.terminal_pointer_admission_for_route(
                    &rendered_route,
                    mouse,
                    missing_surface,
                ) {
                    TerminalPointerAdmissionResult::NotTerminal => {}
                    TerminalPointerAdmissionResult::Ready(admission) => {
                        terminal_pointer_admission = Some(admission);
                    }
                    TerminalPointerAdmissionResult::Rejected => {
                        return Ok(RenderAction::None);
                    }
                    TerminalPointerAdmissionResult::Contended => {
                        if mouse.kind == MouseEventKind::Moved {
                            self.retain_pointer_motion_with_sequence(
                                *mouse,
                                input_sequence,
                                replay_context
                                    .as_ref()
                                    .and_then(|context| context.pointer.as_ref())
                                    .map(|pointer| pointer.focus_generation),
                            );
                        } else {
                            self.defer_input_with_sequence(
                                TerminalInput::Mouse(*mouse),
                                input_sequence,
                                replay_context.as_ref().and_then(|context| context.pointer.clone()),
                                replay_context
                                    .as_ref()
                                    .and_then(|context| context.admission.clone()),
                            );
                        }
                        // Parsing will release the semantic lock and normally
                        // wake us through SurfaceOutput. The idle replay tick
                        // is the bounded fallback, so do not synchronously
                        // paint through the same blocking terminal lock.
                        return Ok(RenderAction::None);
                    }
                }
            }
            if let Some(admission) =
                replay_context.as_ref().and_then(|context| context.admission.as_ref())
                && !pointer_has_capture
            {
                let follows_pending_route = input.is_keyboard_or_paste()
                    && admission.destination_intent.is_some_and(|intent| {
                        self.session.destination_mutation_committed() >= intent
                            && self.session.destination_mutation_started() == intent
                    });
                let follows_semantic_route = admission.semantic_dependency.is_some_and(|intent| {
                    matches!(
                        self.semantic_destination_outcomes.get(&intent),
                        Some(SemanticDestinationOutcome::Resolved(surface))
                            if Self::input_accepts_semantic_destination(input)
                                && self.tab_locations.contains_key(surface)
                    )
                });
                let follows_captured_action_route = matches!(
                    input,
                    TerminalInput::FrontendAction { action, .. }
                        if !action_is_frontend_local(*action)
                            && admission.destination.is_some_and(|surface| {
                                self.tab_locations.contains_key(&surface)
                            })
                );
                let follows_sidebar_focus =
                    admission.sidebar_focus_intent && self.workspace_sidebar_focused();
                if !admission.client_owned
                    && !follows_pending_route
                    && !follows_semantic_route
                    && !follows_captured_action_route
                    && !follows_sidebar_focus
                    && self.input_destination(input) != admission.destination
                {
                    if !matches!(input, TerminalInput::Mouse(_)) {
                        self.status_message = Some(
                            localization::catalog()
                                .terminal
                                .deferred_input_destination_changed
                                .to_string(),
                        );
                        return Ok(RenderAction::Draw);
                    }
                    return Ok(RenderAction::None);
                }
            }
        }
        if let AppEvent::NormalizedInput(TerminalInput::Mouse(
            mouse @ MouseEvent { kind: MouseEventKind::Moved, .. },
        )) = &event
            && let Some(surface) = missing_surface
        {
            self.queue_surface_attach(surface);
            self.retain_pointer_motion_with_sequence(
                *mouse,
                input_sequence,
                replay_context
                    .as_ref()
                    .and_then(|context| context.pointer.as_ref())
                    .map(|pointer| pointer.focus_generation),
            );
            return Ok(RenderAction::None);
        }
        let event = match event {
            AppEvent::NormalizedInput(input)
                if input.is_routable()
                    && missing_surface.is_some()
                    && !self.input_can_update_pending_mutation(&input) =>
            {
                let surface = missing_surface.unwrap();
                self.queue_surface_attach(surface);
                return Ok(self.defer_input_with_sequence(
                    input,
                    input_sequence,
                    replay_context.as_ref().and_then(|context| context.pointer.clone()),
                    replay_context.as_ref().and_then(|context| context.admission.clone()),
                ));
            }
            AppEvent::NormalizedInput(input)
                if input.is_routable()
                    && !matches!(
                        &input,
                        TerminalInput::Mouse(MouseEvent { kind: MouseEventKind::Moved, .. })
                    )
                    && (self.session.has_pending_mutations()
                        || self.session.remote_tree_is_stale()
                        || self.mux_recovery_generation.load(Ordering::Acquire) != 0
                        || matches!(&input, TerminalInput::Mouse(mouse) if self.pointer_route_is_stale_for_mouse(mouse)))
                    && !self.input_can_update_pending_mutation(&input) =>
            {
                return Ok(self.defer_input_with_sequence(
                    input,
                    input_sequence,
                    replay_context.as_ref().and_then(|context| context.pointer.clone()),
                    replay_context.as_ref().and_then(|context| context.admission.clone()),
                ));
            }
            event => event,
        };
        self.dispatch_event(event, input_sequence, replay_context, terminal_pointer_admission)
    }
}

fn clear_omnibar_selection(state: &mut OmnibarState) {
    if state.select_all {
        state.input.clear();
        state.select_all = false;
    }
}

fn rects_intersect(a: Rect, b: Rect) -> bool {
    let ax2 = a.x.saturating_add(a.width);
    let ay2 = a.y.saturating_add(a.height);
    let bx2 = b.x.saturating_add(b.width);
    let by2 = b.y.saturating_add(b.height);
    a.x < bx2 && ax2 > b.x && a.y < by2 && ay2 > b.y
}

#[cfg(test)]
mod tests;

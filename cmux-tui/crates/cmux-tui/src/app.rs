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
    BrowserStatus, ClearHistoryDelivery, ClearHistoryFailure, FrontendFocusTarget, GraphicsStatus,
    MachineUsage, Mux, MuxEvent, PairingChallenge, PaneId, Rect, ScreenId, SurfaceId, SurfaceKind,
    VirtualRect, WorkspaceId,
};
use crossbeam_channel::Sender as SyncSender;
use crossterm::event::{
    DisableMouseCapture, EnableBracketedPaste, EnableFocusChange, EnableMouseCapture, KeyCode,
    KeyEvent, KeyModifiers, MouseButton, MouseEvent, MouseEventKind,
};
use ghostty_vt::{
    CursorShape, KeyEncoder, KittyGraphicsSnapshot, RenderState, TerminalPointerSemanticSnapshot,
};

use self::events::{
    AppEvent, OwnerReloadWorker, SessionEventSender, SessionEventWorker, SessionTrySendError,
};
#[cfg(test)]
use self::events::{EventCancellation, send_bounded_cancelable};
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
#[cfg(test)]
use self::remote_attach::{REMOTE_ATTACH_WORKER_LIMIT, remote_attach_background_limit};
use self::remote_attach::{
    RemoteSurfaceAttachAdmission, RemoteSurfaceAttachExecutor, RemoteSurfaceAttachJob,
};
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
#[cfg(test)]
use crate::browser_input::BrowserResizeFailure;
use crate::browser_input::{BrowserInputDispatcher, BrowserKey};
use crate::config::{Action, ChromeTheme, Config, SidebarView};
use crate::localization;
#[cfg(test)]
use crate::machine::MachineConnectRoute;
use crate::machine::{
    DurableNoticeDelivery, DurableProviderNotice, MachineKey, MachineRequest, MachineUiState,
    MachineUpdate, ProviderActionInputError, WorkspaceCreationMode,
};
use crate::pty_input::{PtyInputDispatcher, mark_operation_known_not_delivered};
#[cfg(test)]
use crate::session::Session;
use crate::session::tree::PaneView;
use crate::session::{CLEAR_HISTORY_UNSUPPORTED_ERROR, ClientInfo, TreeView};
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RenderAction {
    None,
    Graphics,
    Paint,
    Draw,
}

const TERMINAL_PAINT_CADENCE: Duration = Duration::from_millis(16);

/// Keep terminal parsing lossless while collapsing presentation-only wakes to
/// the host's frame cadence. Structural draws remain immediate.
struct TerminalPaintPacer {
    next_paint_at: Instant,
    pending: bool,
}

impl TerminalPaintPacer {
    fn after_paint(now: Instant) -> Self {
        Self { next_paint_at: now + TERMINAL_PAINT_CADENCE, pending: false }
    }

    fn wait_timeout(&self, timeout: Duration, now: Instant) -> Duration {
        if self.pending {
            timeout.min(self.next_paint_at.saturating_duration_since(now))
        } else {
            timeout
        }
    }

    fn schedule(&mut self, action: RenderAction, now: Instant) -> RenderAction {
        let action = if self.pending && now >= self.next_paint_at {
            action.merge(RenderAction::Paint)
        } else {
            action
        };
        match action {
            RenderAction::Paint if now < self.next_paint_at => {
                self.pending = true;
                RenderAction::None
            }
            RenderAction::Paint | RenderAction::Draw => {
                self.pending = false;
                self.next_paint_at = now + TERMINAL_PAINT_CADENCE;
                action
            }
            RenderAction::None | RenderAction::Graphics => action,
        }
    }

    fn render_immediately(&mut self, action: RenderAction, now: Instant) -> RenderAction {
        let action = if self.pending { action.merge(RenderAction::Paint) } else { action };
        if matches!(action, RenderAction::Paint | RenderAction::Draw) {
            self.pending = false;
            self.next_paint_at = now + TERMINAL_PAINT_CADENCE;
        }
        action
    }
}

impl RenderAction {
    fn rebuilds_pointer_route(self) -> bool {
        matches!(self, Self::Paint | Self::Draw)
    }
}

enum MachineRailCommand {
    Activate(MachineKey),
    Rename(MachineKey),
    Delete(MachineKey),
    Purge(MachineKey),
    Create,
    Connect,
    ProviderMenu,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) enum WorkspaceRailSelection {
    #[default]
    Workspace,
    Recoverable,
    Action(SidebarActionTarget),
}

impl WorkspaceRailSelection {
    pub(crate) fn matches_action(self, target: SidebarActionTarget) -> bool {
        self == Self::Action(target)
    }
}

fn workspace_creation_selection(mode: Option<WorkspaceCreationMode>) -> WorkspaceRailSelection {
    WorkspaceRailSelection::Action(SidebarActionTarget::CreateWorkspace(mode))
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum WorkspaceRailTarget {
    Workspace(WorkspaceId),
    Recoverable(String),
    Action(SidebarActionTarget),
}

fn rail_page_size(area: Option<Rect>) -> usize {
    area.map_or(1, |area| usize::from(area.height.saturating_sub(1)).saturating_div(3).max(1))
}

fn rail_navigation_index(key: &KeyEvent, current: usize, len: usize, page: usize) -> Option<usize> {
    if len == 0 {
        return None;
    }
    match key.code {
        KeyCode::Up | KeyCode::Char('k') => Some(current.saturating_sub(1)),
        KeyCode::Down | KeyCode::Char('j') => Some((current + 1).min(len - 1)),
        KeyCode::Home => Some(0),
        KeyCode::End => Some(len - 1),
        KeyCode::PageUp => Some(current.saturating_sub(page)),
        KeyCode::PageDown => Some(current.saturating_add(page).min(len - 1)),
        _ => None,
    }
}

impl RenderAction {
    fn merge(self, other: Self) -> Self {
        match (self, other) {
            (RenderAction::Draw, _) | (_, RenderAction::Draw) => RenderAction::Draw,
            (RenderAction::Paint, _) | (_, RenderAction::Paint) => RenderAction::Paint,
            (RenderAction::Graphics, _) | (_, RenderAction::Graphics) => RenderAction::Graphics,
            (RenderAction::None, RenderAction::None) => RenderAction::None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct FrontendFocusSnapshot {
    target: FrontendFocusTarget,
    workspace_id: Option<cmux_tui_core::resource::WorkspacePublicId>,
    screen_id: Option<cmux_tui_core::resource::ScreenPublicId>,
    pane_id: Option<cmux_tui_core::resource::PanePublicId>,
    tab_id: Option<cmux_tui_core::resource::TabPublicId>,
    content_id: Option<cmux_tui_core::resource::ContentPublicId>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct FrontendResizeSnapshot {
    cols: u16,
    rows: u16,
    cell_width: u16,
    cell_height: u16,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct FrontendViewportSnapshot {
    screen_id: Option<cmux_tui_core::resource::ScreenPublicId>,
    offset: u64,
    target: u64,
    settled: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct FrontendPresentationSnapshot {
    focus: FrontendFocusSnapshot,
    resize: FrontendResizeSnapshot,
    viewport: FrontendViewportSnapshot,
}

fn frontend_journal_event_id() -> String {
    format!("event_frontend_{}", uuid::Uuid::new_v4().simple())
}

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

#[derive(Debug, Clone, Copy)]
struct BrowserMouseDispatch {
    event_type: &'static str,
    button: Option<&'static str>,
    click_count: Option<u32>,
}

impl BrowserMouseDispatch {
    const fn new(
        event_type: &'static str,
        button: Option<&'static str>,
        click_count: Option<u32>,
    ) -> Self {
        Self { event_type, button, click_count }
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

#[derive(Default)]
struct PaneFocusHistory {
    next_sequence: u64,
    recency: HashMap<PaneId, u64>,
    baseline: HashMap<PaneId, u64>,
    membership_revision: Option<u64>,
    membership_initialized: bool,
}

impl PaneFocusHistory {
    fn record(&mut self, pane: PaneId) {
        self.next_sequence = self.next_sequence.saturating_add(1);
        self.recency.insert(pane, self.next_sequence);
    }

    fn recency(&self, pane: PaneId) -> (bool, u64) {
        self.recency
            .get(&pane)
            .copied()
            .map(|sequence| (true, sequence))
            .unwrap_or_else(|| (false, self.baseline.get(&pane).copied().unwrap_or_default()))
    }

    fn reconcile_membership(&mut self, tree: &TreeView) {
        let live = tree
            .workspaces()
            .iter()
            .flat_map(|workspace| workspace.screens.iter())
            .flat_map(|screen| screen.panes.iter())
            .map(|pane| pane.id)
            .collect::<HashSet<_>>();
        self.recency.retain(|pane, _| live.contains(pane));
        self.baseline.retain(|pane, _| live.contains(pane));
        for pane in tree
            .workspaces()
            .iter()
            .flat_map(|workspace| workspace.screens.iter())
            .flat_map(|screen| screen.panes.iter())
        {
            self.baseline.entry(pane.id).or_insert(pane.focused_at);
        }
        self.membership_revision = tree.pane_revision;
        self.membership_initialized = true;
    }

    fn sync_membership(&mut self, tree: &TreeView) {
        if !self.membership_initialized
            || tree.pane_revision.is_some() && self.membership_revision != tree.pane_revision
        {
            self.reconcile_membership(tree);
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

/// A durable random id naming this client install for per-client focus
/// memory on the mux (client-focus-v1). Stored next to the TUI config;
/// created on first use.
fn client_focus_identity() -> Option<String> {
    let path = crate::config::config_path().ok()?.parent()?.join("client-id");
    if let Ok(existing) = std::fs::read_to_string(&path) {
        let existing = existing.trim();
        if !existing.is_empty()
            && existing.len() <= 128
            && existing.bytes().all(|byte| byte.is_ascii_graphic())
        {
            return Some(existing.to_string());
        }
    }
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes).ok()?;
    let mut id = String::with_capacity(39);
    id.push_str("client-");
    use std::fmt::Write as _;
    for byte in bytes {
        write!(&mut id, "{byte:02x}").ok()?;
    }
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    std::fs::write(&path, format!("{id}\n")).ok()?;
    Some(id)
}

fn preserve_client_view(previous: &TreeView, next: &mut TreeView) {
    let workspace_indices = next
        .workspaces()
        .iter()
        .enumerate()
        .map(|(index, workspace)| (workspace.id, index))
        .collect::<HashMap<_, _>>();
    if let Some(active) = previous.active_workspace().map(|workspace| workspace.id)
        && let Some(index) = workspace_indices.get(&active).copied()
    {
        next.active_workspace = index;
    }

    let mut screen_updates = Vec::new();
    let mut pane_updates = Vec::new();
    let mut tab_updates = Vec::new();
    for previous_workspace in previous.workspaces() {
        let Some(next_workspace_index) = workspace_indices.get(&previous_workspace.id).copied()
        else {
            continue;
        };
        let Some(screen_indices) = next.workspaces().get(next_workspace_index).map(|workspace| {
            workspace
                .screens
                .iter()
                .enumerate()
                .map(|(index, screen)| (screen.id, index))
                .collect::<HashMap<_, _>>()
        }) else {
            continue;
        };
        if let Some(active) =
            previous_workspace.screens.get(previous_workspace.active_screen).map(|screen| screen.id)
            && let Some(index) = screen_indices.get(&active).copied()
        {
            screen_updates.push((next_workspace_index, index));
        }

        for previous_screen in &previous_workspace.screens {
            let Some(next_screen_index) = screen_indices.get(&previous_screen.id).copied() else {
                continue;
            };
            let Some((zoomed_pane, pane_indices)) = next
                .workspaces()
                .get(next_workspace_index)
                .and_then(|workspace| workspace.screens.get(next_screen_index))
                .map(|screen| {
                    (
                        screen.zoomed_pane,
                        screen
                            .panes
                            .iter()
                            .enumerate()
                            .map(|(index, pane)| (pane.id, index))
                            .collect::<HashMap<_, _>>(),
                    )
                })
            else {
                continue;
            };
            if let Some(zoomed_pane) =
                zoomed_pane.filter(|zoomed| pane_indices.contains_key(zoomed))
            {
                pane_updates.push((next_workspace_index, next_screen_index, zoomed_pane));
            } else if zoomed_pane.is_none()
                && pane_indices.contains_key(&previous_screen.active_pane)
            {
                pane_updates.push((
                    next_workspace_index,
                    next_screen_index,
                    previous_screen.active_pane,
                ));
            }

            for previous_pane in &previous_screen.panes {
                let Some(next_pane_index) = pane_indices.get(&previous_pane.id).copied() else {
                    continue;
                };
                let Some((pane_id, tab_indices)) = next
                    .workspaces()
                    .get(next_workspace_index)
                    .and_then(|workspace| workspace.screens.get(next_screen_index))
                    .and_then(|screen| screen.panes.get(next_pane_index))
                    .map(|pane| {
                        (
                            pane.id,
                            pane.tabs
                                .iter()
                                .enumerate()
                                .map(|(index, tab)| (tab.surface, index))
                                .collect::<HashMap<_, _>>(),
                        )
                    })
                else {
                    continue;
                };
                if let Some(active) = previous_pane.active_surface()
                    && let Some(index) = tab_indices.get(&active).copied()
                {
                    tab_updates.push((next_workspace_index, next_screen_index, pane_id, index));
                }
            }
        }
    }
    for (workspace_index, screen_index) in screen_updates {
        next.set_active_screen(workspace_index, screen_index);
    }
    for (workspace_index, screen_index, pane_id) in pane_updates {
        next.set_active_pane(workspace_index, screen_index, pane_id);
    }
    for (workspace_index, screen_index, pane_id, tab_index) in tab_updates {
        next.set_active_tab(workspace_index, screen_index, pane_id, tab_index);
    }
}

fn localized_clear_history_failure(error: &str) -> &'static str {
    let messages = &localization::catalog().terminal;
    match error {
        CLEAR_HISTORY_UNSUPPORTED_ERROR => messages.clear_history_unsupported,
        cmux_tui_core::CLEAR_HISTORY_FALLBACK_UNREPRESENTABLE_ERROR => {
            messages.clear_history_fallback_unrepresentable
        }
        cmux_tui_core::CLEAR_HISTORY_PRESERVATION_ERROR => {
            messages.clear_history_preservation_impossible
        }
        cmux_tui_core::CLEAR_HISTORY_STREAM_TIMEOUT_ERROR => messages.clear_history_stream_timeout,
        cmux_tui_core::CLEAR_HISTORY_FALLBACK_WRITE_TIMEOUT_ERROR => {
            messages.clear_history_fallback_write_timeout
        }
        "terminal host does not support clear-history" => messages.clear_history_host_unsupported,
        "terminal host has exited" => messages.clear_history_host_exited,
        "terminal host failed to apply clear-history" => messages.clear_history_host_failed,
        "terminal host returned a malformed clear-history response" => {
            messages.clear_history_host_malformed_response
        }
        "remote session did not respond" => messages.clear_history_remote_no_response,
        "remote response wait canceled for shutdown" => messages.clear_history_remote_disconnected,
        _ if error.starts_with("terminal host did not acknowledge ClearHistory:") => {
            messages.clear_history_host_no_response
        }
        _ if error.starts_with("remote transport write failed:") => {
            messages.clear_history_remote_disconnected
        }
        _ if error.starts_with("remote command rejected:") => {
            messages.clear_history_remote_rejected
        }
        _ => messages.clear_history_unexpected,
    }
}

fn classify_clear_history_failure(failure: ClearHistoryFailure) -> anyhow::Error {
    let delivery = failure.delivery();
    let error = failure.into_error();
    if delivery == ClearHistoryDelivery::KnownNotDelivered {
        mark_operation_known_not_delivered(error)
    } else {
        error
    }
}

fn should_claim_clear_history_shortcut(
    surface_kind: SurfaceKind,
    supports_atomic_fallback: bool,
) -> bool {
    surface_kind == SurfaceKind::Pty && supports_atomic_fallback
}

fn adjust_active_tab_after_removal(pane: &mut PaneView, removed_tab_index: usize) {
    if pane.active_tab > removed_tab_index {
        pane.active_tab -= 1;
    } else if pane.active_tab >= pane.tabs.len() {
        pane.active_tab = pane.tabs.len().saturating_sub(1);
    }
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
        match event {
            AppEvent::HostInputReady => Ok(RenderAction::None),
            AppEvent::GraphicsWriterReady => Ok(self.apply_graphics_completion()),
            AppEvent::MuxTitlesReady => {
                Ok(if self.apply_mux_titles() { RenderAction::Paint } else { RenderAction::None })
            }
            AppEvent::StatusCommandsUpdated => {
                self.status_poke_pending.store(false, Ordering::Release);
                Ok(if self.config.status_bar.visible && !self.is_surface_only() {
                    RenderAction::Draw
                } else {
                    RenderAction::None
                })
            }
            AppEvent::MuxSubscriptionRecovered {
                recovery_generation,
                destination_generation,
                result,
            } => {
                if recovery_generation != self.mux_recovery_generation.load(Ordering::Acquire) {
                    return Ok(RenderAction::None);
                }
                match result {
                    Ok(tree) => {
                        let empty = tree.workspaces().is_empty();
                        self.replace_authoritative_tree(tree, destination_generation);
                        self.session.refresh_clients_background();
                        if empty {
                            if self.request_current_machine_session() {
                                return Ok(RenderAction::Draw);
                            }
                            self.quit = true;
                            return Ok(RenderAction::None);
                        }
                        self.status_message = Some(
                            localization::catalog().session.mux_subscription_recovered.to_string(),
                        );
                    }
                    Err(error) => {
                        if self
                            .mux_recovery_generation
                            .compare_exchange(
                                recovery_generation,
                                0,
                                Ordering::AcqRel,
                                Ordering::Acquire,
                            )
                            .is_err()
                        {
                            return Ok(RenderAction::None);
                        }
                        self.deferred_input.clear();
                        self.latest_semantic_destination_intent = None;
                        self.semantic_destination_outcomes.clear();
                        self.prefix_armed = false;
                        self.session.invalidate_remote_tree();
                        self.session.refresh_remote_tree_if_stale();
                        self.status_message = Some(
                            localization::catalog()
                                .session
                                .mux_subscription_recovery_failed(&error),
                        );
                    }
                }
                Ok(RenderAction::Draw)
            }
            AppEvent::MuxRecoveryComplete { recovery_generation } => {
                if recovery_generation != self.mux_recovery_generation.load(Ordering::Acquire) {
                    return Ok(RenderAction::None);
                }
                if self
                    .mux_recovery_generation
                    .compare_exchange(recovery_generation, 0, Ordering::AcqRel, Ordering::Acquire)
                    .is_err()
                {
                    return Ok(RenderAction::None);
                }
                Ok(RenderAction::Draw)
            }
            AppEvent::SidebarPluginUpdated { status, relaunch } => {
                self.apply_sidebar_plugin_status(status, relaunch);
                Ok(RenderAction::Draw)
            }
            #[cfg(test)]
            AppEvent::MachineUiUpdated(update) => Ok(self.apply_machine_ui_update(*update)),
            AppEvent::MachineUpdatedForGeneration { generation, update } => {
                if generation != self.machine_update_generation {
                    return Ok(RenderAction::None);
                }
                Ok(match *update {
                    MachineUpdate::Ui(update) => self.apply_machine_ui_update(*update),
                    MachineUpdate::DurableNotice(notice) => self.accept_durable_notice(notice),
                    MachineUpdate::ConnectionProgress { machine_id, latest } => {
                        self.apply_connection_progress(machine_id, latest)
                    }
                })
            }
            AppEvent::MachineControllerCompleted(completion) => {
                Ok(self.apply_machine_controller_completion(*completion))
            }
            AppEvent::Mux(MuxEvent::Empty) => {
                // A genuinely emptied workspace list and a dead event
                // transport both end the event stream with this event, but
                // only the former is a clean exit. The remote reader records
                // why it stopped; consult that BEFORE any machine-session
                // request so a machine or provider surface cannot swallow the
                // dead transport into a stuck reconnect (issue 11042). A
                // deliberate local disconnect records no reason. The one
                // machine response that outranks the error is a sleeping or
                // stopped machine, whose stream loss is the designed result
                // of pausing it.
                if let Some(reason) = self.session.transport_disconnect_reason() {
                    if self.present_machine_as_asleep_after_stream_loss() {
                        return Ok(RenderAction::Draw);
                    }
                    crate::client_log::error(
                        "session",
                        &format!("remote event transport lost: {reason}"),
                    );
                    anyhow::bail!(localization::catalog().runtime.session_transport_lost());
                }
                if self.request_current_machine_session() {
                    return Ok(RenderAction::Draw);
                }
                self.quit = true;
                Ok(RenderAction::None)
            }
            AppEvent::Mux(MuxEvent::SurfaceExited(id)) => {
                self.retire_surface_state(id);
                self.remove_surface_from_cached_tree(id);
                if self.surface_only == Some(id) {
                    self.quit = true;
                    return Ok(RenderAction::None);
                }
                Ok(RenderAction::Draw)
            }
            AppEvent::Mux(MuxEvent::SurfaceResized { surface, cols, rows, reservation_id }) => {
                self.session.confirm_surface_resize(surface, (cols, rows), reservation_id);
                // This acknowledges geometry already computed by the host-resize draw.
                // Re-running layout here creates an acknowledgement feedback loop while
                // the outer terminal is being dragged; only repaint terminal content.
                Ok(RenderAction::Paint)
            }
            AppEvent::Mux(MuxEvent::SurfaceResizeFailed {
                surface,
                cols,
                rows,
                error,
                retry_after_ms,
                reservation_id,
            }) => {
                if self.session.note_surface_resize_failure(
                    surface,
                    (cols, rows),
                    retry_after_ms,
                    reservation_id,
                ) {
                    self.status_message = Some(
                        localization::catalog()
                            .graphics
                            .browser_surface_resize_failed(surface, cols, rows, &error),
                    );
                    Ok(RenderAction::Draw)
                } else {
                    Ok(RenderAction::None)
                }
            }
            AppEvent::Mux(MuxEvent::Status(message)) => {
                self.status_message = Some(message);
                Ok(RenderAction::Draw)
            }
            AppEvent::Mux(MuxEvent::GraphicsStatus(status)) => {
                let messages = &localization::catalog().graphics;
                let message = match status {
                    GraphicsStatus::KittyImageBudgetWorkerStartFailed { error } => {
                        messages.kitty_image_budget_worker_start_failed(&error)
                    }
                    // Kitty quota updates are advisory: the mux disables graphics
                    // for an unresponsive surface and the terminal remains usable.
                    // Keep the structured event available to logs and remote
                    // observers, but do not replace user-facing command status
                    // with a diagnostic the user cannot act on.
                    GraphicsStatus::KittyImageBudgetUpdateFailed { retry_exhausted, summary } => {
                        crate::client_log::log(
                            "WARN",
                            "kitty-graphics",
                            &messages.kitty_image_budget_update_failed(retry_exhausted, &summary),
                        );
                        return Ok(RenderAction::None);
                    }
                    GraphicsStatus::CellPixelUpdateRetriesExhausted {
                        attempts,
                        remaining,
                        cell_pixels,
                    } => messages.cell_pixel_update_retries_exhausted(
                        attempts,
                        remaining,
                        cell_pixels,
                    ),
                };
                self.status_message = Some(message);
                Ok(RenderAction::Draw)
            }
            AppEvent::Mux(MuxEvent::ConfigReloadRequested) => {
                if self.presenting_owner_session() {
                    return Ok(RenderAction::None);
                }
                self.reload_config();
                Ok(RenderAction::Draw)
            }
            AppEvent::OwnerConfigReloadRequested => {
                let owner = self.owner_mux.clone();
                let request = owner.as_ref().map(|mux| mux.begin_config_reload_application());
                self.reload_config();
                if let (Some(owner), Some(request)) = (owner, request) {
                    crate::session::apply_config_to_local_owner(&owner, &self.config);
                    owner.complete_config_reload_application(request);
                }
                Ok(RenderAction::Draw)
            }
            AppEvent::Mux(MuxEvent::WindowTitleRequested(title)) => {
                self.write_window_title(&title)?;
                Ok(RenderAction::None)
            }
            AppEvent::Mux(MuxEvent::MachineUsageChanged(usage)) => {
                if self.machine_usage == usage {
                    return Ok(RenderAction::None);
                }
                self.machine_usage = usage;
                Ok(RenderAction::Draw)
            }
            AppEvent::Mux(MuxEvent::SurfaceOutput(id)) => {
                self.graphics_dirty_surfaces.insert(id);
                if self.sidebar_plugin_surface == Some(id) {
                    return Ok(RenderAction::Paint);
                }
                if self.frame_only_browser_update(id) {
                    Ok(RenderAction::Graphics)
                } else {
                    Ok(RenderAction::Paint)
                }
            }
            AppEvent::Mux(MuxEvent::PairingRequested(challenge)) => {
                let duplicate = self
                    .pairing_dialog
                    .as_ref()
                    .is_some_and(|dialog| dialog.challenge.id == challenge.id)
                    || self.pairing_queue.iter().any(|queued| queued.id == challenge.id);
                if !duplicate {
                    if self.pairing_dialog.is_none() {
                        self.cancel_pointer_interaction();
                        self.pairing_dialog = Some(PairingDialog::new(challenge));
                    } else {
                        self.pairing_queue.push_back(challenge);
                    }
                }
                Ok(RenderAction::Draw)
            }
            AppEvent::Mux(MuxEvent::PairingResolved { request }) => {
                self.pairing_queue.retain(|challenge| challenge.id != request);
                if self.pairing_dialog.as_ref().is_some_and(|dialog| dialog.challenge.id == request)
                {
                    self.cancel_pointer_interaction();
                    self.pairing_dialog = self.pairing_queue.pop_front().map(PairingDialog::new);
                }
                Ok(RenderAction::Draw)
            }
            AppEvent::Mux(
                MuxEvent::ClientAttached { .. }
                | MuxEvent::ClientChanged { .. }
                | MuxEvent::ClientDetached(_)
                | MuxEvent::ClientListInvalidated,
            ) => {
                self.session.refresh_clients_background();
                Ok(RenderAction::Draw)
            }
            AppEvent::Mux(MuxEvent::SizeStateChanged { surface, .. }) => {
                self.refresh_size_state_label(surface);
                Ok(RenderAction::Draw)
            }
            AppEvent::Mux(_) => Ok(RenderAction::Draw),
            AppEvent::BrowserResizeFailed(failure) => {
                self.status_message =
                    Some(localization::catalog().graphics.browser_surface_resize_failed(
                        failure.surface_id,
                        failure.cols,
                        failure.rows,
                        &failure.error,
                    ));
                Ok(RenderAction::Draw)
            }
            AppEvent::PtyFailuresReady => Ok(self.apply_pty_failures()),
            AppEvent::PtyOperationFailed(failure) => Ok(self.apply_pty_operation_failure(failure)),
            AppEvent::SurfaceAttachSettled { outcome } => {
                match outcome {
                    SurfaceAttachOutcome::Attached => {
                        self.claim_active_terminal_geometry(false);
                    }
                    SurfaceAttachOutcome::Deferred => {}
                    SurfaceAttachOutcome::Retired { surface } => {
                        self.retire_surface_state(surface);
                        self.remove_surface_from_cached_tree(surface);
                        self.session.refresh_remote_tree_if_stale();
                    }
                    SurfaceAttachOutcome::Failed {
                        surface,
                        operation,
                        error,
                        reconnect_required,
                    } => {
                        if reconnect_required {
                            self.deferred_input
                                .retain(|input| input.admission.destination != Some(surface));
                            self.status_message = Some(
                                localization::catalog()
                                    .attach
                                    .surface_sync_unknown(surface, operation, &error),
                            );
                        } else {
                            self.status_message = Some(
                                localization::catalog()
                                    .attach
                                    .surface_sync_failed(surface, operation, &error),
                            );
                        }
                    }
                }
                if !self.session.has_pending_mutations()
                    && !self.session.remote_tree_is_stale()
                    && !self.deferred_input.is_empty()
                {
                    self.pointer_route_phase = PointerRoutePhase::DrawPending;
                }
                Ok(RenderAction::Draw)
            }
            AppEvent::ClearHistorySucceeded {
                surface,
                input_revision,
                selection_at_invocation,
                selection_generation,
            } => {
                let Some(handle) = self.session.surface(surface) else {
                    return Ok(RenderAction::None);
                };
                if self.input_revision == input_revision {
                    let _ = handle.scroll_to_bottom();
                }
                self.render_states.remove(&surface);
                if self.selection_generation == selection_generation
                    && self.selection == selection_at_invocation
                    && self.selection.is_some_and(|selection| selection.surface == surface)
                {
                    self.replace_selection(None);
                }
                Ok(RenderAction::Draw)
            }
            AppEvent::SessionMutationSettled { outcome, impact } => {
                self.session.settle_pending_mutation(impact);
                let (semantic_intent, outcome) = match outcome {
                    SessionMutationOutcome::SemanticIntent { intent, outcome } => {
                        (Some(intent), *outcome)
                    }
                    outcome => (None, outcome),
                };
                match outcome {
                    SessionMutationOutcome::SemanticIntent { .. } => {
                        unreachable!("semantic mutation outcomes are unwrapped once")
                    }
                    SessionMutationOutcome::Success { tree } => {
                        if let Some(tree) = tree {
                            self.replace_tree(tree);
                        }
                        // A visible remote surface can require a separate
                        // resize after attach when the peer lacks atomic
                        // initial sizing. Retry the deferred authority claim
                        // after that resize settles.
                        self.claim_active_terminal_geometry(false);
                        self.layout_refresh_retries_remaining = 0;
                    }
                    SessionMutationOutcome::AuthoritativeMutationSucceeded {
                        tree,
                        authoritative_generation,
                        destination_generation,
                        completion,
                    } => {
                        self.session.clear_surface_sync_failures();
                        self.replace_authoritative_tree(tree, destination_generation);
                        self.layout_refresh_retries_remaining = 0;
                        if let Some(completion) = completion {
                            self.pending_session_completions.push_back(completion);
                        }
                        self.apply_session_completions_through(authoritative_generation);
                    }
                    SessionMutationOutcome::IdentityRefreshSucceeded {
                        tree,
                        authoritative_generation,
                        destination_generation,
                        refresh_sequence,
                    } => {
                        if !self.accept_refresh_sequence(refresh_sequence) {
                            let applied_completion =
                                self.apply_session_completions_through(authoritative_generation);
                            return Ok(if applied_completion {
                                RenderAction::Draw
                            } else {
                                RenderAction::None
                            });
                        }
                        self.session.clear_surface_sync_failures();
                        self.session.reconcile_retired_surfaces(&tree);
                        self.replace_authoritative_tree(tree, destination_generation);
                        self.layout_refresh_retries_remaining = 0;
                        self.background_refresh_attempts = 0;
                        self.background_refresh_retry_at = None;
                        self.apply_session_completions_through(authoritative_generation);
                        self.complete_remote_tree_refresh(true);
                        self.session.reconcile_ambiguous_creations();
                    }
                    SessionMutationOutcome::CommittedTreeStale { error, completion } => {
                        if let Some(completion) = completion {
                            self.pending_session_completions.push_back(completion);
                        }
                        self.layout_refresh_retries_remaining = LAYOUT_REFRESH_RETRIES;
                        if let Some(error) = error {
                            self.status_message = Some(
                                localization::catalog()
                                    .sidebar
                                    .layout_refresh_failed
                                    .replace("{error}", error.as_str()),
                            );
                        }
                        self.session.invalidate_remote_tree();
                        self.session.refresh_remote_tree_if_stale();
                    }
                    SessionMutationOutcome::IdentityRefreshFailed { error, refresh_sequence } => {
                        if !self.accept_refresh_sequence(refresh_sequence) {
                            return Ok(RenderAction::None);
                        }
                        self.status_message = Some(
                            localization::catalog()
                                .sidebar
                                .layout_stale
                                .replace("{error}", error.as_str()),
                        );
                        let refresh_stale = self.layout_refresh_retries_remaining > 0;
                        if refresh_stale {
                            self.layout_refresh_retries_remaining -= 1;
                            self.session.invalidate_remote_tree();
                        }
                        self.complete_remote_tree_refresh(refresh_stale);
                        return Ok(RenderAction::Draw);
                    }
                    SessionMutationOutcome::SurfaceSyncFailed {
                        surface,
                        operation,
                        error,
                        reconnect_required,
                    } => {
                        if self
                            .pending_pointer_motion
                            .is_some_and(|pointer| pointer.destination == Some(surface))
                        {
                            self.pending_pointer_motion = None;
                        }
                        if reconnect_required {
                            self.deferred_input
                                .retain(|input| input.admission.destination != Some(surface));
                            self.status_message = Some(
                                localization::catalog()
                                    .attach
                                    .surface_sync_unknown(surface, operation, &error),
                            );
                        } else {
                            self.status_message = Some(
                                localization::catalog()
                                    .attach
                                    .surface_sync_failed(surface, operation, &error),
                            );
                        }
                    }
                    SessionMutationOutcome::SurfaceSizeReleased { surface } => {
                        let expected = self.pending_size_releases.remove(&surface);
                        if expected {
                            self.visible_size_surfaces.remove(&surface);
                        } else if self.visible_size_surfaces.remove(&surface) {
                            // A release already in flight can settle after the
                            // pane becomes visible. Force the next draw to
                            // reclaim its lease even if geometry is unchanged.
                            self.session.invalidate_surface_size_report(surface);
                        }
                    }
                    SessionMutationOutcome::SurfaceSizeReleaseFailed { surface, error } => {
                        if self.pending_size_releases.remove(&surface) {
                            self.session.invalidate_surface_size_report(surface);
                            if self.pane_areas.iter().any(|area| area.surface == surface) {
                                self.visible_size_surfaces.remove(&surface);
                            }
                            self.status_message = Some(
                                localization::catalog()
                                    .layout
                                    .surface_size_release_failed(surface, &error),
                            );
                        }
                    }
                    SessionMutationOutcome::SurfaceSizeReleaseCanceled { surface } => {
                        self.pending_size_releases.remove(&surface);
                    }
                    SessionMutationOutcome::ClientSizingChanged => {
                        self.session.refresh_clients_background();
                    }
                    SessionMutationOutcome::CreationResponseAmbiguous(error) => {
                        crate::client_log::stderr_log!(
                            "session",
                            "{BIN}: session creation response was ambiguous: {error}"
                        );
                        self.status_message =
                            Some(localization::catalog().session.creation_reconciling.to_string());
                        self.layout_refresh_retries_remaining = LAYOUT_REFRESH_RETRIES;
                        self.session.invalidate_remote_tree();
                        self.session.refresh_remote_tree_if_stale();
                        return Ok(RenderAction::Draw);
                    }
                    SessionMutationOutcome::MutationTimedOut(error) => {
                        crate::client_log::stderr_log!(
                            "session",
                            "{BIN}: session operation timed out: {error}"
                        );
                        if let Some(intent) = semantic_intent {
                            // A peer without creation receipts cannot identify
                            // which surface, if any, a timed-out creation made.
                            // Fail only that route so dependent input is never
                            // guessed onto whichever surface became active.
                            self.mark_semantic_destination_failed(intent);
                        }
                        self.status_message =
                            Some(localization::catalog().session.operation_reconciling.to_string());
                        self.layout_refresh_retries_remaining = LAYOUT_REFRESH_RETRIES;
                        self.session.invalidate_remote_tree();
                        self.session.refresh_remote_tree_if_stale();
                        return Ok(RenderAction::Draw);
                    }
                    SessionMutationOutcome::Failed(error) => {
                        crate::client_log::stderr_log!(
                            "session",
                            "{BIN}: session operation failed: {error}"
                        );
                        if let Some(intent) = semantic_intent {
                            self.mark_semantic_destination_failed(intent);
                            self.status_message =
                                Some(localization::catalog().session.operation_failed.to_string());
                            return Ok(RenderAction::Draw);
                        }
                        self.deferred_input.clear();
                        self.prefix_armed = false;
                        self.pending_session_completions.clear();
                        self.status_message =
                            Some(localization::catalog().session.operation_failed.to_string());
                        return Ok(RenderAction::Draw);
                    }
                    SessionMutationOutcome::Canceled => {
                        if let Some(intent) = semantic_intent {
                            self.mark_semantic_destination_failed(intent);
                            self.status_message = Some(
                                localization::catalog().session.operation_canceled.to_string(),
                            );
                            return Ok(RenderAction::Draw);
                        }
                        if self.session.has_pending_mutations() {
                            self.session.defer_cancellation();
                            return Ok(RenderAction::None);
                        }
                        self.apply_session_cancellation();
                        return Ok(RenderAction::Draw);
                    }
                }
                self.session.refresh_remote_tree_if_stale();
                if self.session.has_pending_mutations() || self.session.remote_tree_is_stale() {
                    return Ok(RenderAction::Draw);
                }
                Ok(RenderAction::Draw)
            }
            AppEvent::RemoteTreeUpdated { refresh_sequence, destination_generation, result } => {
                if !self.accept_refresh_sequence(refresh_sequence) {
                    return Ok(RenderAction::None);
                }
                let refreshed = match result {
                    Ok(tree) => {
                        self.session.reconcile_retired_surfaces(&tree);
                        self.replace_authoritative_tree(tree, destination_generation);
                        self.layout_refresh_retries_remaining = 0;
                        self.background_refresh_attempts = 0;
                        self.background_refresh_retry_at = None;
                        true
                    }
                    Err(error) => {
                        let retrying = self.schedule_background_refresh_retry();
                        let template = if retrying {
                            localization::catalog().sidebar.refresh_remote_tree_retrying
                        } else {
                            localization::catalog().sidebar.refresh_remote_tree_stopped
                        };
                        self.status_message = Some(
                            template
                                .replace("{attempts}", &BACKGROUND_REFRESH_RETRIES.to_string())
                                .replace("{error}", error.as_str()),
                        );
                        let _ = self.session.take_background_refresh_dirty();
                        false
                    }
                };
                if refreshed {
                    self.complete_remote_tree_refresh(true);
                    self.session.reconcile_ambiguous_creations();
                }
                Ok(RenderAction::Draw)
            }
            AppEvent::ClientsUpdated { generation, result } => {
                if generation != self.session.client_refresh_generation() {
                    return Ok(RenderAction::None);
                }
                match result {
                    Ok(clients) => self.replace_clients(clients),
                    Err(error) => {
                        self.status_message = Some(
                            localization::catalog()
                                .sidebar
                                .clients_list_failed
                                .replace("{error}", error.as_str()),
                        );
                    }
                }
                Ok(RenderAction::Draw)
            }
            AppEvent::NormalizedInput(input) => {
                let admission =
                    replay_context.as_ref().and_then(|context| context.admission.as_ref());
                let semantic_result = admission.and_then(|value| value.semantic_result);
                let semantic_destination = self.semantic_destination_for_input(&input, admission);
                let action_destination = if matches!(&input, TerminalInput::FrontendAction { .. }) {
                    semantic_destination.or_else(|| admission.and_then(|value| value.destination))
                } else {
                    semantic_destination
                };
                let action_fallback_destination = self
                    .input_creates_session_destination(&input)
                    .then(|| admission.and_then(|value| value.destination))
                    .flatten()
                    .filter(|fallback| Some(*fallback) != action_destination);
                self.dispatch_terminal_input(
                    input,
                    input_sequence,
                    terminal_pointer_admission,
                    semantic_result,
                    action_destination,
                    action_fallback_destination,
                )
            }
            AppEvent::HostInputFailed(error) => {
                anyhow::bail!(localization::catalog().runtime.host_input_failed(&error))
            }
            AppEvent::Input(_) => unreachable!("raw input is normalized before dispatch"),
            AppEvent::SessionScoped { .. } => {
                unreachable!("session-scoped events are unwrapped before dispatch")
            }
        }
    }
}

fn canonical_terminal_content(content: Rect, rendered_size: Option<(u16, u16)>) -> Rect {
    let (cols, rows) = rendered_size.unwrap_or((content.width, content.height));
    Rect {
        x: content.x,
        y: content.y,
        width: content.width.min(cols),
        height: content.height.min(rows),
    }
}

fn outer_cursor_escape_if_changed(
    applied: Option<OuterCursorSpec>,
    desired: OuterCursorSpec,
) -> Option<String> {
    (applied != Some(desired)).then(|| outer_cursor_escape(desired))
}

/// Host input modes asserted at client startup, before any inner-terminal
/// state is known. A scoped single-terminal attach (`attach --terminal`) is a
/// transparent passthrough: it must not assert mouse capture or the
/// shift-bypass report on the host, because the host terminal owns clicks and
/// selection until the inner application requests mouse tracking. Focus
/// reporting and bracketed paste stay enabled in both modes: the client
/// consumes those events itself and re-encodes paste for the inner terminal
/// according to the mode the inner application actually requested, so they
/// are transparent to the user.
fn host_startup_input_modes(surface_only: bool) -> String {
    let mut out = String::new();
    if !surface_only {
        out.push_str(&host_mouse_capture_sequence(true));
    }
    let _ = crossterm::Command::write_ansi(&EnableFocusChange, &mut out);
    let _ = crossterm::Command::write_ansi(&EnableBracketedPaste, &mut out);
    out
}

fn host_mouse_capture_sequence(enable: bool) -> String {
    let mut out = String::new();
    if enable {
        let _ = crossterm::Command::write_ansi(&EnableMouseCapture, &mut out);
        // Ask the host terminal to report Shift-modified mouse events so
        // Shift remains cmux's selection/context-menu escape while the inner
        // application owns ordinary mouse input.
        out.push_str("\x1b[>1s");
    } else {
        // Restore the conventional behavior where Shift bypasses capture.
        out.push_str("\x1b[>0s");
        let _ = crossterm::Command::write_ansi(&DisableMouseCapture, &mut out);
    }
    out
}

fn host_mouse_capture_escape_if_changed(applied: Option<bool>, desired: bool) -> Option<String> {
    (applied != Some(desired)).then(|| host_mouse_capture_sequence(desired))
}

/// Initial host-cursor bookkeeping. A full TUI starts with unknown applied
/// state, so its first frame restores host cursor globals to defaults. A
/// scoped attach starts from an applied Reset so it emits no cursor escapes
/// until the inner application authors a cursor style.
fn initial_applied_outer_cursor(surface_only: bool) -> Option<OuterCursorSpec> {
    surface_only.then_some(OuterCursorSpec::Reset)
}

/// Startup already asserted capture for full-TUI clients and asserted
/// nothing for scoped attach clients.
fn initial_host_mouse_capture(surface_only: bool) -> Option<bool> {
    Some(!surface_only)
}

fn outer_cursor_escape(spec: OuterCursorSpec) -> String {
    match spec {
        OuterCursorSpec::Reset => "\x1b]112\x07\x1b[0 q".to_string(),
        OuterCursorSpec::Terminal { color, shape, blinking } => {
            let style = match (shape, blinking) {
                (CursorShape::Block, true) => 1,
                (CursorShape::Block, false) => 2,
                (CursorShape::Underline, true) => 3,
                (CursorShape::Underline, false) => 4,
                (CursorShape::Bar, true) => 5,
                (CursorShape::Bar, false) => 6,
                // DECSCUSR has no hollow-block form. A steady block preserves
                // shape and avoids inventing blink behavior.
                (CursorShape::BlockHollow, _) => 2,
            };
            format!("\x1b]12;#{:02x}{:02x}{:02x}\x07\x1b[{style} q", color.r, color.g, color.b)
        }
    }
}

fn browser_modifiers(modifiers: KeyModifiers) -> Option<u32> {
    if modifiers.contains(KeyModifiers::HYPER) {
        return None;
    }
    let mut out = 0;
    if modifiers.contains(KeyModifiers::ALT) {
        out |= 1;
    }
    if modifiers.contains(KeyModifiers::CONTROL) {
        out |= 2;
    }
    if modifiers.intersects(KeyModifiers::SUPER | KeyModifiers::META) {
        out |= 4;
    }
    if modifiers.contains(KeyModifiers::SHIFT) {
        out |= 8;
    }
    Some(out)
}

fn browser_only_action(action: Action) -> bool {
    matches!(
        action,
        Action::BrowserBack
            | Action::BrowserForward
            | Action::BrowserReload
            | Action::BrowserEditUrl
    )
}

fn action_is_frontend_local(action: Action) -> bool {
    matches!(
        action,
        Action::NextTab
            | Action::PrevTab
            | Action::SelectTab(_)
            | Action::PrevScreen
            | Action::NextScreen
            | Action::SelectScreen(_)
            | Action::PrevWorkspace
            | Action::NextWorkspace
            | Action::ToggleSidebar
            | Action::ToggleSidebarCompact
            | Action::ToggleSidebarView
            | Action::FocusSidebar
            | Action::ProviderMenu
            | Action::FocusLeft
            | Action::FocusRight
            | Action::FocusUp
            | Action::FocusDown
            | Action::FocusNextPane
            | Action::ScrollUp
            | Action::ScrollDown
            | Action::BrowserEditUrl
            | Action::ShowShortcuts
    )
}

fn action_creates_destination(action: Action) -> bool {
    matches!(
        action,
        Action::NewTab
            | Action::NewBrowserTab
            | Action::NewPaneSmart
            | Action::SplitRight
            | Action::SplitDown
            | Action::NewScreen
            | Action::NewWorkspace
            | Action::NewPaneRight
    )
}

fn publishes_global_cell_metrics(surface_only: Option<SurfaceId>) -> bool {
    surface_only.is_none()
}

fn action_available_in_mode(action: Action, surface_only: bool) -> bool {
    !surface_only
        || matches!(
            action,
            Action::SendPrefix
                | Action::CloseTab
                | Action::RenameTab
                | Action::ScrollUp
                | Action::ScrollDown
                | Action::ClearHistory
                | Action::ShowShortcuts
                | Action::Detach
        )
}

fn action_prepares_pty_release(action: Action) -> bool {
    !matches!(
        action,
        Action::SendPrefix
            | Action::RenameTab
            | Action::RenameScreen
            | Action::RenameWorkspace
            | Action::NewWorkspace
            | Action::NewPaneRight
            | Action::ScrollUp
            | Action::ScrollDown
            | Action::BrowserEditUrl
            | Action::ShowShortcuts
    )
}

fn menu_action_prepares_pty_release(action: MenuAction) -> bool {
    !matches!(
        action,
        MenuAction::RenameClientMachine(_)
            | MenuAction::RenameManagedMachine(_)
            | MenuAction::DeleteManagedMachine(_)
            | MenuAction::RestoreManagedMachine(_)
            | MenuAction::PurgeManagedMachine(_)
            | MenuAction::RenameWorkspace(_)
            | MenuAction::RenameManagedWorkspace(_)
            | MenuAction::DeleteManagedWorkspace(_)
            | MenuAction::RestoreManagedWorkspace(_)
            | MenuAction::PurgeManagedWorkspace(_)
            | MenuAction::CopyWorkspaceId(_)
            | MenuAction::RenameScreen(_)
            | MenuAction::BrowserEditUrl(_)
            | MenuAction::BrowserCopyUrl(_)
            | MenuAction::RenameTab(_)
            | MenuAction::RenameSurface(_)
            | MenuAction::CopyTabId(_)
            | MenuAction::CopyPaneId(_)
            | MenuAction::CopyStatusMessage
            | MenuAction::SelectProviderScope(_)
            | MenuAction::InvokeProviderAction(_)
            | MenuAction::ConnectMachineTarget(_)
            | MenuAction::ConnectOtherMachine
            | MenuAction::ActivateSidebarProfile(_)
            | MenuAction::SetSidebarViewVisible { .. }
    )
}

fn provider_action_error_message(error: ProviderActionInputError) -> &'static str {
    let messages = &localization::catalog().sidebar;
    match error {
        ProviderActionInputError::Required => messages.action_required,
        ProviderActionInputError::TooLong => messages.action_too_long,
        ProviderActionInputError::InvalidEmail => messages.action_invalid_email,
        ProviderActionInputError::InvalidInteger => messages.action_invalid_integer,
        ProviderActionInputError::BelowMinimum => messages.action_below_minimum,
        ProviderActionInputError::AboveMaximum => messages.action_above_maximum,
        ProviderActionInputError::MissingSelectedMachine => {
            messages.action_missing_selected_machine
        }
        ProviderActionInputError::MissingSelectedWorkspace => {
            messages.action_missing_selected_workspace
        }
        ProviderActionInputError::UnsupportedFieldCount => {
            messages.action_multiple_fields_unsupported
        }
    }
}

fn deferred_paste_bytes(text: &str) -> usize {
    text.len().saturating_add(BRACKETED_PASTE_MARKER_BYTES)
}

fn binding_matches(
    chord: &crate::config::Chord,
    key: &KeyEvent,
    fallback: Option<&KeyEvent>,
) -> bool {
    chord.matches(key) || fallback.is_some_and(|fallback| chord.matches(fallback))
}

fn action_for_binding(
    keys: &crate::config::Keys,
    key: &KeyEvent,
    fallback: Option<&KeyEvent>,
) -> Option<Action> {
    keys.action_for(key).or_else(|| fallback.and_then(|fallback| keys.action_for(fallback)))
}

fn modeless_action_for_binding(
    keys: &crate::config::Keys,
    key: &KeyEvent,
    fallback: Option<&KeyEvent>,
) -> Option<Action> {
    keys.modeless_action_for(key)
        .or_else(|| fallback.and_then(|fallback| keys.modeless_action_for(fallback)))
}

fn browser_hover_forward_allowed(status: Option<BrowserStatus>, editing_same_pane: bool) -> bool {
    !editing_same_pane && matches!(status, Some(BrowserStatus::Live))
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

fn browser_key_mapping(
    code: KeyCode,
    base_layout_key: Option<char>,
) -> Option<(BrowserKey, &'static str, u32, Option<&'static str>)> {
    match code {
        KeyCode::Char(character) => {
            // Preserve the logical key without claiming a physical DOM code
            // when the host did not report an authoritative base-layout key.
            let (code, vk) = base_layout_key.map(browser_character_code).unwrap_or(("", 0));
            Some((BrowserKey::Character(character), code, vk, None))
        }
        KeyCode::Enter => Some((BrowserKey::Named("Enter"), "Enter", 13, Some("\r"))),
        KeyCode::Backspace => Some((BrowserKey::Named("Backspace"), "Backspace", 8, None)),
        KeyCode::Tab | KeyCode::BackTab => Some((BrowserKey::Named("Tab"), "Tab", 9, None)),
        KeyCode::Esc => Some((BrowserKey::Named("Escape"), "Escape", 27, None)),
        KeyCode::Left => Some((BrowserKey::Named("ArrowLeft"), "ArrowLeft", 37, None)),
        KeyCode::Up => Some((BrowserKey::Named("ArrowUp"), "ArrowUp", 38, None)),
        KeyCode::Right => Some((BrowserKey::Named("ArrowRight"), "ArrowRight", 39, None)),
        KeyCode::Down => Some((BrowserKey::Named("ArrowDown"), "ArrowDown", 40, None)),
        KeyCode::Home => Some((BrowserKey::Named("Home"), "Home", 36, None)),
        KeyCode::End => Some((BrowserKey::Named("End"), "End", 35, None)),
        KeyCode::PageUp => Some((BrowserKey::Named("PageUp"), "PageUp", 33, None)),
        KeyCode::PageDown => Some((BrowserKey::Named("PageDown"), "PageDown", 34, None)),
        KeyCode::Delete => Some((BrowserKey::Named("Delete"), "Delete", 46, None)),
        _ => None,
    }
}

const BROWSER_LETTER_CODES: [&str; 26] = [
    "KeyA", "KeyB", "KeyC", "KeyD", "KeyE", "KeyF", "KeyG", "KeyH", "KeyI", "KeyJ", "KeyK", "KeyL",
    "KeyM", "KeyN", "KeyO", "KeyP", "KeyQ", "KeyR", "KeyS", "KeyT", "KeyU", "KeyV", "KeyW", "KeyX",
    "KeyY", "KeyZ",
];

const BROWSER_DIGIT_CODES: [&str; 10] = [
    "Digit0", "Digit1", "Digit2", "Digit3", "Digit4", "Digit5", "Digit6", "Digit7", "Digit8",
    "Digit9",
];

fn browser_character_code(character: char) -> (&'static str, u32) {
    match character {
        'a'..='z' | 'A'..='Z' => {
            let upper = character.to_ascii_uppercase();
            (BROWSER_LETTER_CODES[(upper as u8 - b'A') as usize], upper as u32)
        }
        '0'..='9' => (BROWSER_DIGIT_CODES[(character as u8 - b'0') as usize], character as u32),
        ' ' => ("Space", 32),
        ';' => ("Semicolon", 186),
        '=' => ("Equal", 187),
        ',' => ("Comma", 188),
        '-' => ("Minus", 189),
        '.' => ("Period", 190),
        '/' => ("Slash", 191),
        '`' => ("Backquote", 192),
        '[' => ("BracketLeft", 219),
        '\\' => ("Backslash", 220),
        ']' => ("BracketRight", 221),
        '\'' => ("Quote", 222),
        _ => ("", 0),
    }
}

#[cfg(test)]
mod tests;

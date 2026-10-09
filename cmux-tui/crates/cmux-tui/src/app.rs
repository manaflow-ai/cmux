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
mod tests {
    mod deferred_input;
    mod graphics_pointer;
    mod host_input;
    mod machine_sidebar;
    mod menus_browser;
    mod mux_recovery;
    mod pty_mouse;
    mod remote_pointer;
    mod selection_clicks;
    mod shortcuts_menus;
    mod surface_attach;
    mod viewport_history;

    use super::{
        AgentOrderCache, App, AppEvent, BACKGROUND_REFRESH_RETRIES, BrowserResizeFailure,
        ContextMenu, DEFERRED_INPUT_CAPACITY, DeferredInput, DeferredInputAdmission,
        DeferredInputQueue, DeferredReplayDisposition, Drag, EventCancellation, FocusTarget,
        ForwardMuxOutcome, FrontendJournalQueue, FrontendJournalWorker, GraphicIdentity,
        GraphicPlacement, GraphicSourceRect, GraphicsSceneCache, GuardedMouseEncode,
        HostInputIngress, HostInputMessage, HostInputRuntime, MachineActionWorker,
        MachineConnectRoute, MenuAction, MenuItem, MutationImpact, MuxTitleIngress, OmnibarHit,
        OmnibarState, OrderedSession, OuterCursorSpec, PaneArea, PaneAreaProjection,
        PaneContentGeneration, PaneEdge, PaneFocusHistory, PaneResizeDragTarget, PaneViewportClip,
        PendingSessionMutation, PendingSessionMutationState, PointerHitIdentity,
        PointerRouteIdentity, PointerRoutePhase, Prompt, PromptTarget, PtyFailureIngress,
        PtyMousePressResult, RailKind, RenderAction, RenderedMenuLevel, RenderedPaneRoute,
        RenderedPointerFrame, Selection, SelectionMode, SessionCompletion, SessionCompletionAction,
        SessionEventSender, ShortcutHelp, SidebarActionTarget, SidebarLayout,
        SidebarPluginSyncClaim, SidebarPluginSyncState, SidebarWidthOverrides,
        StatusTemplateValues, StatusWorkerStop, StdoutLock, SurfaceAttachClaimState,
        SurfaceResizeDecision, SurfaceResizeOwnership, TERMINAL_PAINT_CADENCE, TerminalInput,
        TerminalPaintPacer, TerminalPointerAdmission, TerminalPointerAdmissionResult,
        TerminalPointerEncoding, TextInput, Toast, VIEWPORT_ANIMATION_DURATION, ViewportMotion,
        ViewportPaneAreaProjection, WorkspaceRailSelection, action_available_in_mode,
        browser_content_size_for_rect, browser_frame_source_crop, browser_hover_forward_allowed,
        browser_source_crop, canonical_terminal_content, catch_renderer_panic,
        clamp_split_ratio_for_tab_bars, client_menu_item, clip_horizontal_rect,
        content_size_for_rect, disable_host_keyboard_protocol, enable_host_keyboard_protocol,
        expand_status_tokens, first_pane_by_id, forward_host_input, forward_mux_event,
        forward_mux_events, host_mouse_capture_escape_if_changed, host_startup_input_modes,
        initial_applied_outer_cursor, initial_host_mouse_capture, keyboard_protocol_accepts,
        layout_undo_error_completion, negotiate_host_keyboard_protocol_with, outer_cursor_escape,
        outer_cursor_escape_if_changed, pane_area_projection_work, pane_context_menu_groups,
        pane_parts_for_rect, prepare_ordered_session, preserve_client_view, rail_drag_width,
        rebuild_pane_areas, record_surface_resize_dispatch_result, report_after_unwind,
        reset_pane_area_projection_work, run_status_command, send_bounded_cancelable,
        should_claim_clear_history_shortcut, sidebar_layout_for, sidebar_layout_for_state,
        sidebar_plugin_status_settles_passive_claim, start_ordered_session,
        swept_viewport_size_leases, thumb_geometry, with_panic_stdout_lock,
        workspace_creation_selection,
    };
    use cmux_tui_core::{FrontendFocusTarget, FrontendJournalEvent};
    use serde_json::Value;
    use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
    use std::sync::mpsc::Receiver as StdReceiver;
    use std::sync::{Arc, Barrier, Mutex};
    use std::time::{Duration, Instant};
    use {crate::local_actor::TuiMuxOps, crossbeam_channel::Receiver};

    use cmux_tui_core::resource::FrontendProjectionPublicId;
    use cmux_tui_core::{
        AgentSource, AgentState, BrowserFrame, BrowserStatus, Direction, LayoutUndoError, Mux,
        MuxEvent, Node, PointerSnapshotProbe, Rect, SplitDir, SurfaceId, SurfaceKind,
        SurfaceOptions, VirtualRect, ZoomMode, layout_screen, server,
    };
    use crossterm::event::{
        EnhancedKeyEvent, Event, KeyCode, KeyEvent, KeyModifiers, KeyboardEnhancementFlags,
        ModifierKeyCode, MouseButton, MouseEvent, MouseEventKind,
    };
    use ghostty_vt::{
        CursorShape, KeyEncoder, KeyInput, KittyGraphicsSnapshot, KittyImage, KittyImageFormat,
        KittyPlacement, KittyPlacementKey, Mods, MouseAction, MouseButton as GhosttyMouseButton,
        MouseInput, RenderState, Rgb, Screen,
    };
    use ratatui::Terminal;
    use ratatui::backend::TestBackend;
    use ratatui::style::{Color, Modifier};
    use unicode_width::UnicodeWidthStr;

    use crate::browser_input::{BrowserInputDispatcher, BrowserInputEvent, BrowserInputKind};
    use crate::config::{
        Action, ChromeTheme, Config, ScrollbarPosition, SidebarColumnKind, SidebarProfileSpec,
        SidebarResourceKind, SidebarView, SidebarViewSpec, action_definitions,
    };
    use crate::localization;
    use crate::machine::{
        DurableNoticeDelivery, DurableNoticeLevel, DurableProviderNotice, MachineActionResult,
        MachineCapabilities, MachineConnectionPhase, MachineConnectionTarget, MachineController,
        MachineCreationSource, MachineDescriptor, MachineKey, MachineRailSelection, MachineRequest,
        MachineSnapshot, MachineStatus, MachineUiState, MachineUpdate, ManagedMachineCapabilities,
        ManagedMachineDescriptor, ManagedMachineStatus, ManagedWorkspaceCapabilities,
        ManagedWorkspaceDescriptor, ManagedWorkspaceSessionMutation, ManagedWorkspaceStatus,
        ProviderActionContext, ProviderActionDescriptor, ProviderActionFieldDescriptor,
        ProviderActionFieldKind, ProviderActionTarget, ProviderActionValue, ProviderPresentation,
        ProviderScopeDescriptor, ProviderScopeKind, WorkspaceCreationMode, WorkspaceCreationPolicy,
    };
    use crate::pty_input::{
        PtyInputBytes, PtyInputDispatcher, PtyInputEnqueueResult, PtyInputEvent, PtyInputKind,
        PtyOperationDelivery, PtyOperationFailure,
    };
    use crate::session::tree::{PaneView, ScreenView, TabNotificationView, TabView, WorkspaceView};
    use crate::session::{
        ClientInfo, ClientSizeInfo, RemoteSession, Session, SidebarPluginSurface, SurfaceAttach,
        SurfaceHandle, TreeView, test_remote_session_with_deferred_attach,
        test_remote_session_with_deferred_attach_and_first_resize_failure,
        test_remote_session_with_deferred_sized_attach, test_remote_session_with_lost_transport,
    };

    use crate::sidebar_files::FileBrowser;

    fn settled(outcome: super::SessionMutationOutcome) -> AppEvent {
        AppEvent::SessionMutationSettled { outcome, impact: MutationImpact::Ordered }
    }

    fn queued_input(
        event: impl Into<TerminalInput>,
        destination: Option<SurfaceId>,
        sequence: u64,
    ) -> DeferredInput {
        DeferredInput {
            event: event.into(),
            admission: DeferredInputAdmission {
                destination,
                destination_intent: None,
                semantic_dependency: None,
                semantic_result: None,
                sidebar_focus_intent: false,
                pairing_request: None,
                client_owned: false,
            },
            pointer: None,
            sequence,
        }
    }

    use super::size_menu_item;
    use crate::session::SurfaceSizeState;
    use cmux_tui_core::sizing_policy::{TerminalSizingMode, TerminalSizingPolicy};

    fn test_mouse_motion() -> MouseInput {
        MouseInput {
            action: MouseAction::Motion,
            button: None,
            mods: Mods::default(),
            position: (36.0, 40.0),
            screen_size: (640, 384),
            cell_size: (8, 16),
            any_button_pressed: false,
        }
    }

    fn encode_test_mouse_motion(surface: &SurfaceHandle, input: MouseInput) -> Vec<u8> {
        let mut output = Vec::new();
        surface.encode_mouse(input, &mut output).unwrap().unwrap();
        output
    }

    fn browser_completion_area(surface: SurfaceId) -> PaneArea {
        PaneArea {
            pane: 2,
            surface,
            rect: Rect { x: 0, y: 0, width: 40, height: 12 },
            bar: Some(Rect { x: 0, y: 0, width: 40, height: 1 }),
            omnibar: Some(Rect { x: 0, y: 1, width: 40, height: 1 }),
            content: Rect { x: 0, y: 2, width: 40, height: 10 },
            track: None,
            viewport: None,
        }
    }

    fn browser_completion_tree(created_surface: SurfaceId, active_surface: SurfaceId) -> TreeView {
        let tab = |surface| TabView {
            surface,
            public_id: None,
            content_id: None,
            terminal_id: None,
            short_id: format!("{surface:06}"),
            name: None,
            title: String::new(),
            kind: SurfaceKind::Browser,
            browser_source: None,
            browser_frames_stalled: false,
            supports_clear_history_key_fallback: false,
            notification: None,
        };
        let mut tabs = vec![tab(created_surface)];
        if active_surface != created_surface {
            tabs.push(tab(active_surface));
        }
        TreeView::from_parts(
            vec![WorkspaceView {
                id: 4,
                resource_id: None,
                key: "00000000-0000-4000-8000-000000000004".to_string(),
                short_id: "000004".to_string(),
                name: "work".to_string(),
                active_screen: 0,
                screens: vec![ScreenView {
                    id: 3,
                    resource_id: None,
                    short_id: "000003".to_string(),
                    name: None,
                    layout: Node::Leaf(2),
                    active_pane: 2,
                    zoomed_pane: None,
                    viewport_base_width: None,
                    viewport_splits: BTreeMap::new(),
                    panes: vec![PaneView {
                        id: 2,
                        resource_id: None,
                        short_id: "000002".to_string(),
                        name: None,
                        tabs,
                        active_tab: usize::from(active_surface != created_surface),
                        focused_at: 0,
                    }],
                }],
            }],
            0,
            Some(1),
            0,
        )
    }

    fn provider_machine_ui() -> MachineUiState {
        provider_machine_ui_with_policy(
            WorkspaceCreationMode::Isolated,
            vec![WorkspaceCreationMode::Isolated, WorkspaceCreationMode::Host],
        )
    }

    fn provider_machine_ui_with_lifecycle() -> MachineUiState {
        let mut ui = provider_machine_ui();
        ui.set_managed_workspaces(
            MachineKey(41),
            vec![
                ManagedWorkspaceDescriptor {
                    id: "00000000-0000-4000-8000-000000000004".into(),
                    name: "work".into(),
                    mode: WorkspaceCreationMode::Isolated,
                    status: ManagedWorkspaceStatus::Active,
                    version: 7,
                    recoverable_until: None,
                    capabilities: ManagedWorkspaceCapabilities {
                        rename: true,
                        delete: true,
                        restore: false,
                        purge: false,
                    },
                },
                ManagedWorkspaceDescriptor {
                    id: "00000000-0000-4000-8000-000000000099".into(),
                    name: "quiet-forest".into(),
                    mode: WorkspaceCreationMode::Host,
                    status: ManagedWorkspaceStatus::Recoverable,
                    version: 12,
                    recoverable_until: Some("2030-01-02T03:04:05Z".into()),
                    capabilities: ManagedWorkspaceCapabilities {
                        rename: false,
                        delete: false,
                        restore: true,
                        purge: true,
                    },
                },
            ],
        );
        ui
    }

    fn provider_machine_ui_with_machine_lifecycle() -> MachineUiState {
        let mut ui = MachineUiState::new(MachineSnapshot {
            machines: vec![
                MachineDescriptor {
                    key: MachineKey(41),
                    id: "00000000-0000-4000-8000-000000000041".into(),
                    name: "managed".into(),
                    subtitle: "cloud".into(),
                    status: MachineStatus::Running,
                },
                MachineDescriptor {
                    key: MachineKey(42),
                    id: "00000000-0000-4000-8000-000000000042".into(),
                    name: "quiet-forest".into(),
                    subtitle: String::new(),
                    status: MachineStatus::Stopped,
                },
            ],
            active: Some(MachineKey(41)),
            capabilities: MachineCapabilities { create: true, connect: true },
        });
        ui.set_managed_machines(vec![
            ManagedMachineDescriptor {
                key: MachineKey(41),
                id: "00000000-0000-4000-8000-000000000041".into(),
                name: "managed".into(),
                status: ManagedMachineStatus::Active,
                version: 7,
                recoverable_until: None,
                capabilities: ManagedMachineCapabilities {
                    rename: true,
                    delete: true,
                    restore: false,
                    purge: false,
                },
            },
            ManagedMachineDescriptor {
                key: MachineKey(42),
                id: "00000000-0000-4000-8000-000000000042".into(),
                name: "quiet-forest".into(),
                status: ManagedMachineStatus::Recoverable,
                version: 12,
                recoverable_until: Some("2030-01-02T03:04:05Z".into()),
                capabilities: ManagedMachineCapabilities {
                    rename: false,
                    delete: false,
                    restore: true,
                    purge: true,
                },
            },
        ]);
        ui
    }

    fn provider_machine_ui_with_changed_second_machine() -> MachineUiState {
        let mut ui = provider_machine_ui_with_machine_lifecycle();
        let mut machines = ui.managed_machines().to_vec();
        let machine = machines
            .iter_mut()
            .find(|machine| machine.key == MachineKey(42))
            .expect("second managed machine");
        machine.status = ManagedMachineStatus::Active;
        machine.version = 13;
        machine.recoverable_until = None;
        machine.capabilities =
            ManagedMachineCapabilities { rename: true, delete: true, restore: false, purge: false };
        ui.set_managed_machines(machines);
        ui
    }

    #[test]
    fn switching_away_from_a_dead_machine_keeps_interstitial_and_input_safe() {
        let mux = Mux::new("machine-dead-switch-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        let mut ui = MachineUiState::new(MachineSnapshot {
            machines: vec![
                MachineDescriptor {
                    key: MachineKey(9),
                    id: "vm-9".into(),
                    name: "maple".into(),
                    subtitle: "freestyle · paused".into(),
                    status: MachineStatus::Sleeping,
                },
                MachineDescriptor {
                    key: MachineKey(10),
                    id: "vm-10".into(),
                    name: "oak".into(),
                    subtitle: "freestyle".into(),
                    status: MachineStatus::Running,
                },
            ],
            active: Some(MachineKey(9)),
            capabilities: MachineCapabilities::default(),
        });
        ui.session_available = false;
        ui.set_connection_phase(MachineKey(10), MachineConnectionPhase::Ready);
        app.machine_ui = Some(ui);
        app.machine_presented = Some(MachineKey(9));
        app.machine_selection_intent = Some(MachineKey(10));

        // The presented machine is dead, so the warm-target shortcut must
        // not hide that a switch is running.
        assert!(app.machine_transition().is_some(), "interstitial must render");

        // A keystroke mid-switch must not re-aim (and wake) the old paused
        // machine.
        app.forward_key(KeyEvent::new(KeyCode::Char('a'), KeyModifiers::NONE).into());
        let ui = app.machine_ui.as_ref().unwrap();
        assert!(ui.request.is_none(), "no wake switch back to the old machine");
        assert!(app.status_message.is_none());
    }

    #[test]
    fn keystrokes_never_reach_the_old_machine_during_a_warm_switch() {
        // While a warm switch is in flight the OLD machine is still live and
        // on screen (session_available field true), but the aim mismatch must
        // gate input away from it: session_available() requires
        // selection_intent == presented, and the wake gate consumes the key
        // instead of forwarding or re-aiming.
        let mux = Mux::new("machine-warm-switch-input-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        let mut ui = MachineUiState::new(MachineSnapshot {
            machines: vec![
                MachineDescriptor {
                    key: MachineKey(9),
                    id: "vm-9".into(),
                    name: "maple".into(),
                    subtitle: "freestyle".into(),
                    status: MachineStatus::Running,
                },
                MachineDescriptor {
                    key: MachineKey(10),
                    id: "vm-10".into(),
                    name: "oak".into(),
                    subtitle: "freestyle".into(),
                    status: MachineStatus::Running,
                },
            ],
            active: Some(MachineKey(9)),
            capabilities: MachineCapabilities::default(),
        });
        ui.session_available = true;
        ui.set_connection_phase(MachineKey(10), MachineConnectionPhase::Ready);
        app.machine_ui = Some(ui);
        app.machine_presented = Some(MachineKey(9));
        app.machine_selection_intent = Some(MachineKey(10));

        assert!(!app.session_available(), "aim mismatch must gate the old session");
        app.forward_key(KeyEvent::new(KeyCode::Char('a'), KeyModifiers::NONE).into());
        let ui = app.machine_ui.as_ref().unwrap();
        assert!(ui.request.is_none(), "the key must not queue any machine request");
        assert!(app.status_message.is_none(), "the key is consumed silently mid-switch");
    }

    #[test]
    fn progress_for_a_stale_ready_target_reveals_the_reconnect() {
        let mux = Mux::new("machine-stale-ready-progress-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        let mut ui = MachineUiState::new(MachineSnapshot {
            machines: vec![
                MachineDescriptor {
                    key: MachineKey(9),
                    id: "vm-9".into(),
                    name: "maple".into(),
                    subtitle: "freestyle".into(),
                    status: MachineStatus::Running,
                },
                MachineDescriptor {
                    key: MachineKey(10),
                    id: "vm-10".into(),
                    name: "oak".into(),
                    subtitle: "freestyle".into(),
                    status: MachineStatus::Running,
                },
            ],
            active: Some(MachineKey(9)),
            capabilities: MachineCapabilities::default(),
        });
        ui.session_available = true;
        // The aim trusted a warm connection, but the pooled session was dead:
        // the provider starts narrating a real open.
        ui.set_connection_phase(MachineKey(10), MachineConnectionPhase::Ready);
        app.machine_ui = Some(ui);
        app.machine_presented = Some(MachineKey(9));
        app.machine_selection_intent = Some(MachineKey(10));
        assert!(app.machine_transition().is_none(), "warm shortcut hides the interstitial");

        let action = app.apply_connection_progress(
            "vm-10".into(),
            Arc::new(Mutex::new(Some("waiting for sshd".into()))),
        );
        assert_eq!(action, RenderAction::Draw);
        let view = app.machine_transition().expect("reconnect must surface");
        assert_eq!(view.phase, MachineConnectionPhase::Connecting);
        assert_eq!(view.progress, Some("waiting for sshd"));
    }

    #[test]
    fn deleting_the_presented_machine_switches_to_the_next_available_one() {
        let mux = Mux::new("machine-delete-focus-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        let descriptor = |key: u64, name: &str| MachineDescriptor {
            key: MachineKey(key),
            id: format!("vm-{key}"),
            name: name.into(),
            subtitle: String::new(),
            status: MachineStatus::Running,
        };
        app.machine_ui = Some(MachineUiState::new(MachineSnapshot {
            machines: vec![descriptor(1, "ash"), descriptor(2, "birch"), descriptor(3, "cedar")],
            active: Some(MachineKey(2)),
            capabilities: MachineCapabilities::default(),
        }));
        app.machine_presented = Some(MachineKey(2));
        app.machine_selection_intent = Some(MachineKey(2));

        // The presented middle machine is deleted: the update must aim at the
        // machine that took its slot (cedar), not leave a dead session up.
        let update = MachineUiState::new(MachineSnapshot {
            machines: vec![descriptor(1, "ash"), descriptor(3, "cedar")],
            active: None,
            capabilities: MachineCapabilities::default(),
        });
        app.apply_machine_ui_update(update);
        let ui = app.machine_ui.as_ref().unwrap();
        assert_eq!(ui.request, Some(MachineRequest::Switch(MachineKey(3))));
        assert!(!ui.session_available, "input must not reach the deleted machine's session");
        assert_eq!(
            ui.rail_target(),
            Some(crate::machine::MachineRailTarget::Machine(MachineKey(3)))
        );

        // Deleting the LAST machine clamps to the new last one.
        app.machine_presented = Some(MachineKey(3));
        app.machine_selection_intent = Some(MachineKey(3));
        app.machine_ui.as_mut().unwrap().request = None;
        let update = MachineUiState::new(MachineSnapshot {
            machines: vec![descriptor(1, "ash")],
            active: None,
            capabilities: MachineCapabilities::default(),
        });
        app.apply_machine_ui_update(update);
        let ui = app.machine_ui.as_ref().unwrap();
        assert_eq!(ui.request, Some(MachineRequest::Switch(MachineKey(1))));

        // Deleting the only remaining machine drops the presentation and
        // lands the rail on the first action row, not the SSH footer that
        // happens to share the old index.
        app.machine_presented = Some(MachineKey(1));
        app.machine_selection_intent = Some(MachineKey(1));
        app.machine_ui.as_mut().unwrap().request = None;
        let update = MachineUiState::new(MachineSnapshot {
            machines: Vec::new(),
            active: None,
            capabilities: MachineCapabilities { create: true, connect: true },
        });
        app.apply_machine_ui_update(update);
        assert_eq!(app.machine_presented, None);
        let ui = app.machine_ui.as_ref().unwrap();
        assert_eq!(ui.request, None);
        assert!(!ui.session_available);
        assert_eq!(ui.rail_target(), Some(crate::machine::MachineRailTarget::NewVm));
    }

    #[test]
    fn m_on_the_machine_rail_opens_the_provider_menu_with_active_scope_selected() {
        let mux = Mux::new("provider-menu-keyboard-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.machine_ui = Some(provider_controls_ui());
        app.focus = FocusTarget::MachineRail;
        app.sync_layout((100, 16));

        app.handle_key(KeyEvent::new(KeyCode::Char('m'), KeyModifiers::NONE)).unwrap();
        assert_eq!(
            app.menu.as_ref().and_then(ContextMenu::selected_action),
            Some(MenuAction::SelectProviderScope(1)),
            "the ACTIVE scope starts selected"
        );
        app.handle_menu_key(KeyEvent::new(KeyCode::Up, KeyModifiers::NONE)).unwrap();
        app.handle_menu_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)).unwrap();
        assert_eq!(
            app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
            Some(&MachineRequest::SelectProviderScope("personal".into()))
        );
    }

    #[test]
    fn modified_m_on_the_machine_rail_does_not_open_the_provider_menu() {
        let mux = Mux::new("provider-menu-modified-key-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.machine_ui = Some(provider_controls_ui());
        app.focus = FocusTarget::MachineRail;
        app.sync_layout((100, 16));

        app.handle_key(KeyEvent::new(KeyCode::Char('m'), KeyModifiers::ALT)).unwrap();
        assert!(app.menu.is_none(), "Alt-m must not open the provider menu");
        app.handle_key(KeyEvent::new(KeyCode::Char('m'), KeyModifiers::CONTROL)).unwrap();
        assert!(app.menu.is_none(), "Ctrl-m must not open the provider menu");
    }

    #[test]
    fn configured_provider_menu_binding_opens_from_the_machine_rail() {
        let mux = Mux::new("provider-menu-configured-key-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.machine_ui = Some(provider_controls_ui());
        app.focus = FocusTarget::MachineRail;
        app.config.keys.apply_for_test(&HashMap::from([(
            "provider-menu".to_string(),
            Value::String("x".to_string()),
        )]));

        app.handle_key(KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE)).unwrap();
        assert!(app.menu.is_some(), "configured provider-menu chord must open on the rail");
    }

    #[test]
    fn configured_provider_menu_navigation_chord_wins_over_rail_navigation() {
        let mux = Mux::new("provider-menu-navigation-key-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.machine_ui = Some(provider_controls_ui());
        app.focus = FocusTarget::MachineRail;
        app.sync_layout((100, 16));
        app.config.keys.apply_for_test(&HashMap::from([(
            "provider-menu".to_string(),
            Value::String("j".to_string()),
        )]));

        app.handle_key(KeyEvent::new(KeyCode::Char('j'), KeyModifiers::NONE)).unwrap();
        assert!(app.menu.is_some(), "configured navigation chord must open the provider menu");
    }

    #[test]
    fn single_provider_scope_menu_starts_inert() {
        let mux = Mux::new("provider-menu-single-scope-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        let mut ui = provider_controls_ui();
        ui.provider.as_mut().unwrap().scopes.truncate(1);
        app.machine_ui = Some(ui);

        assert!(app.open_provider_rail_menu(1, 2));
        let menu = app.menu.as_ref().unwrap();
        assert!(!menu.levels[0].selection_active);
        assert_eq!(menu.selected_action(), None);
    }

    #[test]
    fn soft_deleting_the_presented_machine_switches_to_the_next_usable_one() {
        // Recovery-capable providers (Freestyle) keep a deleted machine in
        // the catalog as a Recoverable row; failover must treat that exactly
        // like a hard delete and must skip other recoverable rows.
        let mux = Mux::new("machine-soft-delete-focus-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        let descriptor = |key: u64, name: &str| MachineDescriptor {
            key: MachineKey(key),
            id: format!("vm-{key}"),
            name: name.into(),
            subtitle: String::new(),
            status: MachineStatus::Running,
        };
        let managed = |key: u64, status: ManagedMachineStatus| ManagedMachineDescriptor {
            key: MachineKey(key),
            id: format!("vm-{key}"),
            name: format!("vm-{key}"),
            status,
            version: 1,
            recoverable_until: None,
            capabilities: ManagedMachineCapabilities {
                rename: false,
                delete: false,
                restore: true,
                purge: true,
            },
        };
        app.machine_ui = Some(MachineUiState::new(MachineSnapshot {
            machines: vec![descriptor(1, "ash"), descriptor(2, "cedar"), descriptor(3, "oak")],
            active: Some(MachineKey(2)),
            capabilities: MachineCapabilities::default(),
        }));
        app.machine_presented = Some(MachineKey(2));
        app.machine_selection_intent = Some(MachineKey(2));

        // cedar is soft deleted; oak (the next slot) is ALSO a recoverable
        // leftover, so the failover must land on ash.
        let mut update = MachineUiState::new(MachineSnapshot {
            machines: vec![descriptor(1, "ash"), descriptor(2, "cedar"), descriptor(3, "oak")],
            active: None,
            capabilities: MachineCapabilities::default(),
        });
        update.set_managed_machines(vec![
            managed(2, ManagedMachineStatus::Recoverable),
            managed(3, ManagedMachineStatus::Recoverable),
        ]);
        // The deletion races its own stream death: live Freestyle dogfood
        // queued a provider RECONNECT for the dying machine (snapshot.active
        // was already gone), which is not a Switch and must equally not
        // block the failover.
        app.machine_ui.as_mut().unwrap().request = Some(MachineRequest::ReconnectProvider);
        app.apply_machine_ui_update(update);
        let ui = app.machine_ui.as_ref().unwrap();
        assert_eq!(ui.request, Some(MachineRequest::Switch(MachineKey(1))));
        assert!(!ui.session_available);
        assert_eq!(
            ui.rail_target(),
            Some(crate::machine::MachineRailTarget::Machine(MachineKey(1)))
        );
    }

    #[test]
    fn deleting_a_switch_target_falls_back_to_the_still_usable_presented_machine() {
        // A queued switch whose target is deleted before it dispatches must
        // not strand the selection intent on the dead machine: input would
        // stay gated forever (intent != presented, nothing queued).
        let mux = Mux::new("machine-doomed-switch-intent-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        let descriptor = |key: u64, name: &str| MachineDescriptor {
            key: MachineKey(key),
            id: format!("vm-{key}"),
            name: name.into(),
            subtitle: String::new(),
            status: MachineStatus::Running,
        };
        app.machine_ui = Some(MachineUiState::new(MachineSnapshot {
            machines: vec![descriptor(1, "ash"), descriptor(2, "cedar")],
            active: Some(MachineKey(1)),
            capabilities: MachineCapabilities::default(),
        }));
        app.machine_presented = Some(MachineKey(1));
        app.machine_selection_intent = Some(MachineKey(2));

        // cedar vanishes while its switch is still queued; ash stays healthy.
        let mut update = MachineUiState::new(MachineSnapshot {
            machines: vec![descriptor(1, "ash")],
            active: Some(MachineKey(1)),
            capabilities: MachineCapabilities::default(),
        });
        update.request = Some(MachineRequest::Switch(MachineKey(2)));
        update.session_available = true;
        app.apply_machine_ui_update(update);
        let ui = app.machine_ui.as_ref().unwrap();
        assert_eq!(ui.request, None);
        assert_eq!(app.machine_selection_intent, Some(MachineKey(1)));
        assert_eq!(app.machine_presented, Some(MachineKey(1)));
        assert!(ui.session_available, "input keeps flowing to the presented machine");
    }

    #[test]
    fn deleting_the_presented_machine_behind_a_queued_request_gates_input_then_fails_over() {
        // The failover cannot use the request slot while an unrelated
        // request occupies it, but input must be gated away from the deleted
        // machine's dead session immediately, and the switch must happen on
        // the next free-slot update.
        let mux = Mux::new("machine-delete-queued-request-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        let descriptor = |key: u64, name: &str| MachineDescriptor {
            key: MachineKey(key),
            id: format!("vm-{key}"),
            name: name.into(),
            subtitle: String::new(),
            status: MachineStatus::Running,
        };
        let snapshot = || MachineSnapshot {
            machines: vec![descriptor(1, "ash"), descriptor(2, "cedar")],
            active: None,
            capabilities: MachineCapabilities::default(),
        };
        let recoverable_cedar = || ManagedMachineDescriptor {
            key: MachineKey(2),
            id: "vm-2".into(),
            name: "vm-2".into(),
            status: ManagedMachineStatus::Recoverable,
            version: 1,
            recoverable_until: None,
            capabilities: ManagedMachineCapabilities {
                rename: false,
                delete: false,
                restore: true,
                purge: true,
            },
        };
        app.machine_ui = Some(MachineUiState::new(MachineSnapshot {
            machines: vec![descriptor(1, "ash"), descriptor(2, "cedar")],
            active: Some(MachineKey(2)),
            capabilities: MachineCapabilities::default(),
        }));
        app.machine_presented = Some(MachineKey(2));
        app.machine_selection_intent = Some(MachineKey(2));

        // cedar is soft deleted while a scope selection is still queued.
        let mut update = MachineUiState::new(snapshot());
        update.set_managed_machines(vec![recoverable_cedar()]);
        update.request = Some(MachineRequest::SelectProviderScope("personal".into()));
        update.session_available = true;
        app.apply_machine_ui_update(update);
        let ui = app.machine_ui.as_ref().unwrap();
        assert_eq!(
            ui.request,
            Some(MachineRequest::SelectProviderScope("personal".into())),
            "the queued request keeps the slot"
        );
        assert!(!ui.session_available, "input must not reach the deleted machine's session");
        assert_eq!(app.machine_presented, Some(MachineKey(2)));

        // The queued request settles; the next update has a free slot and
        // the deferred failover fires.
        let mut update = MachineUiState::new(snapshot());
        update.set_managed_machines(vec![recoverable_cedar()]);
        update.session_available = true;
        app.apply_machine_ui_update(update);
        let ui = app.machine_ui.as_ref().unwrap();
        assert_eq!(ui.request, Some(MachineRequest::Switch(MachineKey(1))));
        assert!(!ui.session_available);
        assert_eq!(
            ui.rail_target(),
            Some(crate::machine::MachineRailTarget::Machine(MachineKey(1)))
        );
    }

    #[test]
    fn deleting_presented_machine_retries_failover_after_failed_switch() {
        let mux = Mux::new("machine-failed-switch-failover-test", SurfaceOptions::default());
        let descriptor = |key: u64| MachineDescriptor {
            key: MachineKey(key),
            id: format!("vm-{key}"),
            name: format!("vm-{key}"),
            subtitle: String::new(),
            status: MachineStatus::Running,
        };
        let mut app = test_app(Session::Local(mux));
        let mut previous = MachineUiState::new(MachineSnapshot {
            machines: vec![descriptor(1), descriptor(2)],
            active: Some(MachineKey(1)),
            capabilities: MachineCapabilities::default(),
        });
        previous.set_connection_phase(MachineKey(2), MachineConnectionPhase::Failed);
        app.machine_ui = Some(previous);
        app.machine_presented = Some(MachineKey(1));
        app.machine_selection_intent = Some(MachineKey(2));

        let update = MachineUiState::new(MachineSnapshot {
            machines: vec![descriptor(2)],
            active: None,
            capabilities: MachineCapabilities::default(),
        });
        app.apply_machine_ui_update(update);

        let ui = app.machine_ui.as_ref().unwrap();
        assert_eq!(ui.request, Some(MachineRequest::Switch(MachineKey(2))));
        assert!(!ui.session_available);
    }

    #[test]
    fn machine_keyboard_switch_returns_focus_to_pane() {
        let mux = Mux::new("machine-keyboard-switch-focus-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        let mut ui = MachineUiState::new(MachineSnapshot {
            machines: vec![
                MachineDescriptor {
                    key: MachineKey(41),
                    id: "machine-41".into(),
                    name: "active".into(),
                    subtitle: "local".into(),
                    status: MachineStatus::Running,
                },
                MachineDescriptor {
                    key: MachineKey(42),
                    id: "machine-42".into(),
                    name: "remote".into(),
                    subtitle: "ssh".into(),
                    status: MachineStatus::Running,
                },
            ],
            active: Some(MachineKey(41)),
            capabilities: MachineCapabilities::default(),
        });
        ui.select_rail_target(crate::machine::MachineRailTarget::Machine(MachineKey(42)));
        app.machine_ui = Some(ui);
        app.machine_selection_intent = Some(MachineKey(41));
        app.machine_presented = Some(MachineKey(41));
        app.focus = FocusTarget::MachineRail;

        app.handle_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)).unwrap();

        assert_eq!(
            app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
            Some(&MachineRequest::Switch(MachineKey(42)))
        );
        assert_eq!(app.focus, FocusTarget::Pane);
    }

    #[test]
    fn machine_switch_is_requested_on_mouse_down() {
        let mux = Mux::new("machine-mouse-down-switch-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.machine_ui = Some(MachineUiState::new(MachineSnapshot {
            machines: vec![
                MachineDescriptor {
                    key: MachineKey(41),
                    id: "machine-41".into(),
                    name: "active".into(),
                    subtitle: "local".into(),
                    status: MachineStatus::Running,
                },
                MachineDescriptor {
                    key: MachineKey(42),
                    id: "machine-42".into(),
                    name: "remote".into(),
                    subtitle: "ssh".into(),
                    status: MachineStatus::Running,
                },
            ],
            active: Some(MachineKey(41)),
            capabilities: MachineCapabilities::default(),
        }));
        app.machine_selection_intent = Some(MachineKey(41));
        app.machine_presented = Some(MachineKey(41));
        app.sync_layout((100, 14));

        let mut terminal = Terminal::new(TestBackend::new(100, 14)).unwrap();
        terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
        let hit = app
            .hits
            .iter()
            .find_map(|(rect, hit)| {
                matches!(hit, super::Hit::Machine { key: MachineKey(42), .. }).then_some(*rect)
            })
            .unwrap();

        app.handle_left_down(hit.x, hit.y, KeyModifiers::NONE).unwrap();

        assert_eq!(
            app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
            Some(&MachineRequest::Switch(MachineKey(42)))
        );
        assert_eq!(app.machine_ui.as_ref().unwrap().snapshot.active, Some(MachineKey(41)));
        assert_eq!(app.focus, FocusTarget::Pane);

        terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
        let selected = &terminal.backend().buffer()[(hit.x + 3, hit.y)];
        assert_eq!(
            selected.style().bg,
            Some(app.chrome.sidebar_selected_bg),
            "mouse-down must paint the selected machine before its connection commits"
        );

        let active_hit = app
            .hits
            .iter()
            .find_map(|(rect, hit)| {
                matches!(hit, super::Hit::Machine { key: MachineKey(41), .. }).then_some(*rect)
            })
            .unwrap();
        app.handle_left_down(active_hit.x, active_hit.y, KeyModifiers::NONE).unwrap();
        assert!(
            app.machine_ui.as_ref().unwrap().request.is_none(),
            "returning to the presented machine must cancel an unsubmitted remote switch"
        );
        assert_eq!(app.selected_machine(), Some(MachineKey(41)));
        assert!(app.session_available());
    }

    #[test]
    fn recoverable_machine_activates_on_mouse_down_and_remains_purgeable() {
        let mux = Mux::new("managed-machine-mouse-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.machine_ui = Some(provider_machine_ui_with_machine_lifecycle());
        app.focus = FocusTarget::MachineRail;
        app.sync_layout((100, 14));

        let mut terminal = Terminal::new(TestBackend::new(100, 14)).unwrap();
        terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
        let text = buffer_text(terminal.backend().buffer());
        assert!(text.contains("quiet-forest"), "{text}");
        assert!(text.contains(localization::catalog().sidebar.recoverable_machine), "{text}");
        let hit = app
            .hits
            .iter()
            .find_map(|(rect, hit)| {
                matches!(hit, super::Hit::Machine { key: MachineKey(42), .. }).then_some(*rect)
            })
            .unwrap();

        app.handle_left_down(hit.x, hit.y, KeyModifiers::NONE).unwrap();
        assert_eq!(
            app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
            Some(&MachineRequest::RestoreManagedMachine {
                machine: MachineKey(42),
                expected_version: 12,
            })
        );
        app.handle_left_up(hit.x, hit.y).unwrap();
        assert_eq!(
            app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
            Some(&MachineRequest::RestoreManagedMachine {
                machine: MachineKey(42),
                expected_version: 12,
            })
        );

        app.machine_ui.as_mut().unwrap().request = None;
        app.open_context_menu(hit.x, hit.y);
        let menu_items = app.menu.as_ref().unwrap().levels[0].items.to_vec();
        assert!(
            matches!(
                menu_items.as_slice(),
                [
                    MenuItem::Action(MenuAction::RestoreManagedMachine(MachineKey(42))),
                    MenuItem::Action(MenuAction::PurgeManagedMachine(MachineKey(42))),
                    ..
                ]
            ),
            "recoverable machine actions: {menu_items:?}"
        );
        app.activate_menu(MenuAction::PurgeManagedMachine(MachineKey(42))).unwrap();
        app.prompt.as_mut().unwrap().input.insert_str("CONFIRM");
        app.commit_prompt();
        assert_eq!(
            app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
            Some(&MachineRequest::PurgeManagedMachine {
                machine: MachineKey(42),
                expected_version: 12,
            })
        );
    }

    #[test]
    fn deferred_machine_press_cannot_retarget_changed_provider_semantics() {
        let mux = Mux::new("managed-machine-deferred-identity-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.machine_ui = Some(provider_machine_ui_with_machine_lifecycle());
        app.focus = FocusTarget::MachineRail;
        let mut terminal = Terminal::new(TestBackend::new(100, 14)).unwrap();
        app.render_action(&mut terminal, RenderAction::Draw).unwrap();
        let hit = app
            .hits
            .iter()
            .find_map(|(rect, hit)| {
                matches!(hit, super::Hit::Machine { key: MachineKey(42), .. }).then_some(*rect)
            })
            .unwrap();

        app.pointer_route_phase = PointerRoutePhase::DrawPending;
        app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
            kind: MouseEventKind::Down(MouseButton::Left),
            column: hit.x,
            row: hit.y,
            modifiers: KeyModifiers::NONE,
        })))
        .unwrap();
        assert_eq!(app.deferred_input.len(), 1);

        let action = app
            .handle(AppEvent::MachineUiUpdated(Box::new(
                provider_machine_ui_with_changed_second_machine(),
            )))
            .unwrap();
        app.render_action(&mut terminal, action).unwrap();
        app.replay_deferred_input().unwrap();

        assert!(
            app.machine_ui.as_ref().unwrap().request.is_none(),
            "a deferred press must not activate a row whose provider semantics changed"
        );
    }

    #[test]
    fn machine_release_does_not_reactivate_after_provider_update() {
        let mux = Mux::new("managed-machine-held-identity-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.machine_ui = Some(provider_machine_ui_with_machine_lifecycle());
        app.focus = FocusTarget::MachineRail;
        let mut terminal = Terminal::new(TestBackend::new(100, 14)).unwrap();
        app.render_action(&mut terminal, RenderAction::Draw).unwrap();
        let hit = app
            .hits
            .iter()
            .find_map(|(rect, hit)| {
                matches!(hit, super::Hit::Machine { key: MachineKey(42), .. }).then_some(*rect)
            })
            .unwrap();

        app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
            kind: MouseEventKind::Down(MouseButton::Left),
            column: hit.x,
            row: hit.y,
            modifiers: KeyModifiers::NONE,
        })))
        .unwrap();
        assert_eq!(
            app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
            Some(&MachineRequest::RestoreManagedMachine {
                machine: MachineKey(42),
                expected_version: 12,
            })
        );

        let action = app
            .handle(AppEvent::MachineUiUpdated(Box::new(
                provider_machine_ui_with_changed_second_machine(),
            )))
            .unwrap();
        app.render_action(&mut terminal, action).unwrap();
        app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
            kind: MouseEventKind::Up(MouseButton::Left),
            column: hit.x,
            row: hit.y,
            modifiers: KeyModifiers::NONE,
        })))
        .unwrap();

        assert!(app.drag.is_none());
        assert!(app.machine_ui.as_ref().unwrap().request.is_none());
    }

    #[test]
    fn replayed_machine_action_is_submitted_before_the_batch_drains() {
        let mux = Mux::new("replayed-machine-action-submit-test", SurfaceOptions::default());
        let (mut app, _events) = test_app_with_events(Session::Local(mux));
        app.machine_ui = Some(provider_machine_ui_with_machine_lifecycle());
        let mut terminal = Terminal::new(TestBackend::new(100, 14)).unwrap();
        app.render_action(&mut terminal, RenderAction::Draw).unwrap();
        let hit = app
            .hits
            .iter()
            .find_map(|(rect, hit)| {
                matches!(hit, super::Hit::Machine { key: MachineKey(42), .. }).then_some(*rect)
            })
            .unwrap();
        let (controller, _requests) = fake_controller(FakeMachineAction::Fail("expected failure"));
        install_machine_controller(&mut app, controller);
        app.deferred_input.push_back(queued_input(
            TerminalInput::Mouse(MouseEvent {
                kind: MouseEventKind::Down(MouseButton::Left),
                column: hit.x,
                row: hit.y,
                modifiers: KeyModifiers::NONE,
            }),
            None,
            1,
        ));
        app.deferred_input_sequence = 1;

        app.replay_deferred_input_batch().unwrap();

        assert!(
            app.machine_action_in_flight,
            "replay must submit a generated machine request before receiving another event"
        );
        assert!(app.machine_ui.as_ref().unwrap().request.is_none());
    }

    #[test]
    fn unmanaged_machine_ignores_provider_lifecycle_shortcuts() {
        let mux = Mux::new("unmanaged-machine-shortcuts-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.machine_ui = Some(provider_machine_ui());
        app.focus = FocusTarget::MachineRail;
        app.sync_layout((100, 14));

        app.handle_key(KeyEvent::new(KeyCode::Char('r'), KeyModifiers::NONE)).unwrap();
        app.handle_key(KeyEvent::new(KeyCode::Char('d'), KeyModifiers::NONE)).unwrap();
        app.handle_key(KeyEvent::new(KeyCode::Char('p'), KeyModifiers::NONE)).unwrap();
        assert!(app.prompt.is_none());
        assert!(app.machine_ui.as_ref().unwrap().request.is_none());
    }

    #[test]
    fn provider_owned_workspace_actions_use_stable_key_and_version() {
        let mux = Mux::new("managed-workspace-actions-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.tree = notify_tree(1, false);
        app.machine_ui = Some(provider_machine_ui_with_lifecycle());

        app.open_rename_workspace_prompt_for(4);
        assert!(matches!(
            app.prompt.as_ref().map(|prompt| prompt.target),
            Some(PromptTarget::ManagedWorkspace(4))
        ));
        app.prompt.as_mut().unwrap().input.clear();
        app.prompt.as_mut().unwrap().input.insert_str("renamed work");
        app.commit_prompt();
        assert_eq!(
            app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
            Some(&MachineRequest::RenameManagedWorkspace {
                machine: MachineKey(41),
                workspace_id: "00000000-0000-4000-8000-000000000004".into(),
                expected_version: 7,
                name: "renamed work".into(),
            })
        );

        app.machine_ui.as_mut().unwrap().request = None;
        app.request_delete_workspace(4);
        assert_eq!(
            app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
            Some(&MachineRequest::DeleteManagedWorkspace {
                machine: MachineKey(41),
                workspace_id: "00000000-0000-4000-8000-000000000004".into(),
                expected_version: 7,
            })
        );

        app.machine_ui.as_mut().unwrap().request = None;
        app.tree.workspaces_mut()[0].key = "local-workspace".into();
        app.open_rename_workspace_prompt_for(4);
        assert!(app.prompt.is_none());
        assert!(app.status_message.is_some());
        app.request_delete_workspace(4);
        assert!(app.machine_ui.as_ref().unwrap().request.is_none());
    }

    #[test]
    fn provider_denied_workspace_actions_do_not_recommend_refreshing() {
        let mux = Mux::new("managed-workspace-denied-action-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.tree = notify_tree(1, false);
        let mut ui = provider_machine_ui();
        ui.set_managed_workspaces(
            MachineKey(41),
            vec![ManagedWorkspaceDescriptor {
                id: "00000000-0000-4000-8000-000000000004".into(),
                name: "work".into(),
                mode: WorkspaceCreationMode::Isolated,
                status: ManagedWorkspaceStatus::Active,
                version: 7,
                recoverable_until: None,
                capabilities: ManagedWorkspaceCapabilities::default(),
            }],
        );
        app.machine_ui = Some(ui);

        app.open_rename_workspace_prompt_for(4);
        assert!(app.prompt.is_none());
        assert_eq!(
            app.status_message.as_deref(),
            Some(localization::catalog().sidebar.managed_workspace_operation_not_allowed)
        );

        app.status_message = None;
        app.request_delete_workspace(4);
        assert!(app.machine_ui.as_ref().unwrap().request.is_none());
        assert_eq!(
            app.status_message.as_deref(),
            Some(localization::catalog().sidebar.managed_workspace_operation_not_allowed)
        );
    }

    #[test]
    fn inactive_provider_machine_blocks_workspace_mutations_with_actionable_status() {
        let mux = Mux::new("inactive-provider-machine-workspace-test", SurfaceOptions::default());
        let workspace = mux
            .create_empty_workspace(
                Some("work".into()),
                Some("00000000-0000-4000-8000-000000000004".into()),
                None,
            )
            .unwrap();
        let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
        app.replace_tree(app.session.tree());
        app.apply_machine_ui_update(provider_machine_ui_with_lifecycle());
        let mut inactive = provider_machine_ui_with_lifecycle();
        inactive.snapshot.active = None;
        app.machine_ui = Some(inactive);

        app.open_rename_workspace_prompt_for(workspace.workspace);
        assert!(app.prompt.is_none());
        assert_eq!(
            app.status_message.as_deref(),
            Some(localization::catalog().sidebar.managed_workspace_machine_inactive)
        );

        app.status_message = None;
        app.request_delete_workspace(workspace.workspace);
        while app.session.has_pending_mutations() {
            app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
        }
        assert!(mux.with_state(|state| {
            state.workspaces.iter().any(|candidate| candidate.id == workspace.workspace)
        }));
        assert_eq!(
            app.status_message.as_deref(),
            Some(localization::catalog().sidebar.managed_workspace_machine_inactive)
        );
    }

    #[test]
    fn provider_workspace_policy_blocks_raw_mux_rename_and_close() {
        let mux = Mux::new("managed-workspace-raw-mutation-test", SurfaceOptions::default());
        let placement = mux
            .create_empty_workspace(
                Some("work".into()),
                Some("00000000-0000-4000-8000-000000000004".into()),
                None,
            )
            .unwrap();
        let mut app = test_app(Session::Local(mux.clone()));
        app.replace_tree(app.session.tree());
        app.apply_machine_ui_update(provider_machine_ui_with_lifecycle());

        assert!(!mux.rename_workspace(placement.workspace, "raw rename".into()));
        assert!(!mux.close_workspace(placement.workspace));
        mux.with_state(|state| {
            let workspace = state
                .workspaces
                .iter()
                .find(|workspace| workspace.id == placement.workspace)
                .unwrap();
            assert_eq!(workspace.name, "work");
        });
    }

    #[test]
    fn provider_authority_without_remote_guard_disables_the_managed_session() {
        let session = crate::session::test_remote_session_with_provider_authority_without_guard();
        let mut app = test_app(session);

        app.apply_machine_ui_update(provider_machine_ui_with_lifecycle());

        assert_eq!(
            app.machine_ui.as_ref().map(|machine| machine.session_available),
            Some(false),
            "an unguarded remote session must not expose provider-managed workspace mutations"
        );
        assert_eq!(
            app.status_message.as_deref(),
            Some(
                "remote cmux server cannot guard provider-managed workspaces; upgrade the server before attaching"
            )
        );
        assert!(
            !app.session.workspaces_are_provider_managed(),
            "provider authority alone must not mark an older remote session as guarded"
        );
    }

    #[test]
    fn missing_managed_descriptor_fails_closed_without_local_close() {
        let mux = Mux::new("managed-workspace-missing-descriptor-test", SurfaceOptions::default());
        let placement = mux
            .create_empty_workspace(
                Some("work".into()),
                Some("00000000-0000-4000-8000-000000000004".into()),
                None,
            )
            .unwrap();
        let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
        app.replace_tree(app.session.tree());
        app.machine_ui = Some(provider_machine_ui());

        app.request_delete_workspace(placement.workspace);
        while app.session.has_pending_mutations() {
            app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
        }

        assert!(mux.with_state(|state| {
            state.workspaces.iter().any(|workspace| workspace.id == placement.workspace)
        }));
        assert!(app.machine_ui.as_ref().unwrap().request.is_none());
        assert_eq!(
            app.status_message.as_deref(),
            Some(localization::catalog().sidebar.managed_workspace_unavailable)
        );
    }

    #[test]
    fn provider_failure_never_mutates_the_local_workspace_mirror() {
        let mux = Mux::new("managed-workspace-provider-failure-test", SurfaceOptions::default());
        let placement = mux
            .create_empty_workspace(
                Some("work".into()),
                Some("00000000-0000-4000-8000-000000000004".into()),
                None,
            )
            .unwrap();
        let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
        app.replace_tree(app.session.tree());
        app.machine_ui = Some(provider_machine_ui_with_lifecycle());
        install_machine_controller(
            &mut app,
            Box::new(FakeMachineController {
                actions: VecDeque::from([
                    FakeMachineAction::Fail("provider rename failed"),
                    FakeMachineAction::Fail("provider delete failed"),
                ]),
                requests: Arc::new(Mutex::new(Vec::new())),
            }),
        );

        app.request_rename_managed_workspace(placement.workspace, "renamed".into());
        settle_machine_action(&mut app, &events);
        app.request_delete_workspace(placement.workspace);
        settle_machine_action(&mut app, &events);

        mux.with_state(|state| {
            let workspace = state
                .workspaces
                .iter()
                .find(|workspace| workspace.id == placement.workspace)
                .unwrap();
            assert_eq!(workspace.name, "work");
        });
        assert!(!app.session.has_pending_mutations());
    }

    #[test]
    fn missing_provider_workspace_mirror_surfaces_an_explicit_error() {
        let mux = Mux::new("managed-workspace-missing-mirror-test", SurfaceOptions::default());
        mux.create_empty_workspace(
            Some("work".into()),
            Some("00000000-0000-4000-8000-000000000004".into()),
            None,
        )
        .unwrap();
        let mut app = test_app(Session::Local(mux));
        app.replace_tree(app.session.tree());

        for mutation in [
            ManagedWorkspaceSessionMutation::Rename {
                workspace_key: "00000000-0000-4000-8000-000000000099".into(),
                name: "renamed".into(),
            },
            ManagedWorkspaceSessionMutation::Close {
                workspace_key: "00000000-0000-4000-8000-000000000099".into(),
            },
        ] {
            app.status_message = None;
            app.apply_managed_workspace_session_mutation(mutation);
            assert_eq!(
                app.status_message.as_deref(),
                Some(localization::catalog().sidebar.managed_workspace_unavailable)
            );
        }
    }

    #[test]
    fn provider_notice_cannot_mask_missing_workspace_mirror_error() {
        let mux = Mux::new("managed-workspace-notice-masking-test", SurfaceOptions::default());
        mux.create_empty_workspace(
            Some("work".into()),
            Some("00000000-0000-4000-8000-000000000004".into()),
            None,
        )
        .unwrap();
        let (mut app, events) = test_app_with_events(Session::Local(mux));
        app.replace_tree(app.session.tree());
        app.apply_machine_ui_update(provider_machine_ui_with_lifecycle());
        let mut update = provider_machine_ui_with_lifecycle();
        update.notice = Some("provider accepted the rename".into());
        install_machine_controller(
            &mut app,
            Box::new(FakeMachineController {
                actions: VecDeque::from([FakeMachineAction::Return(Box::new(
                    MachineActionResult::ui(update).with_session_mutation(
                        ManagedWorkspaceSessionMutation::Rename {
                            workspace_key: "00000000-0000-4000-8000-000000000099".into(),
                            name: "renamed".into(),
                        },
                    ),
                ))]),
                requests: Arc::new(Mutex::new(Vec::new())),
            }),
        );
        app.machine_ui.as_mut().unwrap().request = Some(MachineRequest::ReconnectProvider);

        settle_machine_action(&mut app, &events);

        assert_eq!(
            app.status_message.as_deref(),
            Some(localization::catalog().sidebar.managed_workspace_unavailable)
        );
    }

    #[test]
    fn failed_provider_reconnect_remains_pending_for_retry() {
        let mux = Mux::new("provider-reconnect-retry-test", SurfaceOptions::default());
        let (mut app, events) = test_app_with_events(Session::Local(mux));
        app.machine_ui = Some(provider_machine_ui());
        let requests = Arc::new(Mutex::new(Vec::new()));
        install_machine_controller(
            &mut app,
            Box::new(FakeMachineController {
                actions: VecDeque::from([
                    FakeMachineAction::Fail("provider is still offline"),
                    FakeMachineAction::Return(Box::new(MachineActionResult::ui(
                        provider_machine_ui(),
                    ))),
                ]),
                requests: requests.clone(),
            }),
        );
        app.machine_ui.as_mut().unwrap().request = Some(MachineRequest::ReconnectProvider);

        settle_machine_action(&mut app, &events);

        assert_eq!(
            app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
            Some(&MachineRequest::ReconnectProvider)
        );
        assert_eq!(requests.lock().unwrap().as_slice(), &[MachineRequest::ReconnectProvider]);
        assert_eq!(app.machine_provider_reconnect_attempts, 1);
        assert!(app.machine_provider_reconnect_retry_at.is_some());
        assert_eq!(app.process_machine_requests(), RenderAction::None);
        assert_eq!(requests.lock().unwrap().len(), 1);

        app.machine_provider_reconnect_retry_at = Some(Instant::now() - Duration::from_millis(1));
        settle_machine_action(&mut app, &events);

        assert_eq!(
            requests.lock().unwrap().as_slice(),
            &[MachineRequest::ReconnectProvider, MachineRequest::ReconnectProvider]
        );
        assert_eq!(app.machine_provider_reconnect_attempts, 0);
        assert!(app.machine_provider_reconnect_retry_at.is_none());
    }

    #[test]
    fn queued_user_action_runs_before_failed_provider_reconnect_retry() {
        let mux = Mux::new("provider-reconnect-user-action-test", SurfaceOptions::default());
        let (mut app, events) = test_app_with_events(Session::Local(mux));
        app.machine_ui = Some(provider_machine_ui());
        let requests = Arc::new(Mutex::new(Vec::new()));
        install_machine_controller(
            &mut app,
            Box::new(FakeMachineController {
                actions: VecDeque::from([
                    FakeMachineAction::Return(Box::new(MachineActionResult::ui(
                        provider_machine_ui(),
                    ))),
                    FakeMachineAction::Return(Box::new(MachineActionResult::ui(
                        provider_machine_ui(),
                    ))),
                ]),
                requests: requests.clone(),
            }),
        );
        let user_request = MachineRequest::SelectProviderScope("team".into());
        app.machine_action_in_flight = true;
        app.machine_action_request = Some(MachineRequest::ReconnectProvider);
        app.machine_ui.as_mut().unwrap().request = Some(user_request.clone());

        app.apply_machine_controller_completion(super::MachineControllerCompletion::Action {
            result: Err("provider is still offline".into()),
            updates: None,
        });

        assert_eq!(app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()), Some(&user_request));
        app.machine_provider_reconnect_retry_at = Some(Instant::now() - Duration::from_millis(1));

        settle_machine_action(&mut app, &events);
        assert_eq!(requests.lock().unwrap().as_slice(), &[user_request]);
        assert!(app.machine_provider_reconnect_retry_at.is_some());

        settle_machine_action(&mut app, &events);
        assert_eq!(
            requests.lock().unwrap().as_slice(),
            &[
                MachineRequest::SelectProviderScope("team".into()),
                MachineRequest::ReconnectProvider,
            ]
        );
        assert_eq!(app.machine_provider_reconnect_attempts, 0);
        assert!(app.machine_provider_reconnect_retry_at.is_none());
    }

    #[test]
    fn stale_replacement_settlement_preserves_newer_reconnect_action() {
        for (case, committed) in [
            ("committed", Ok(true)),
            ("rejected", Ok(false)),
            ("failed", Err("stale failure".into())),
        ] {
            let mux = Mux::new(format!("stale-replacement-{case}"), SurfaceOptions::default());
            let mut app = test_app(Session::Local(mux));
            app.machine_ui = Some(provider_machine_ui());
            app.machine_action_in_flight = true;
            app.machine_action_request = Some(MachineRequest::ReconnectProvider);
            app.machine_provider_reconnect_attempts = 3;
            let retry_at = Instant::now() + Duration::from_secs(10);
            app.machine_provider_reconnect_retry_at = Some(retry_at);
            app.pending_machine_replacement =
                Some(pending_machine_replacement(&app, 2, &format!("newer-replacement-{case}")));

            let action = app.apply_machine_controller_completion(
                super::MachineControllerCompletion::ReplacementSettled {
                    action_id: 1,
                    committed,
                    updates: None,
                },
            );

            assert_eq!(action, RenderAction::Draw);
            assert_eq!(
                app.pending_machine_replacement.as_ref().map(|pending| pending.action_id),
                Some(2)
            );
            assert!(app.machine_action_in_flight);
            assert_eq!(app.machine_action_request, Some(MachineRequest::ReconnectProvider));
            assert_eq!(app.machine_provider_reconnect_attempts, 3);
            assert_eq!(app.machine_provider_reconnect_retry_at, Some(retry_at));
            assert_eq!(
                app.status_message.as_deref(),
                Some(
                    format!(
                        "{}: {}",
                        localization::catalog().sidebar.machine_action_failed,
                        localization::catalog().sidebar.machine_replacement_stale
                    )
                    .as_str()
                )
            );
        }
    }

    #[test]
    fn rejected_provider_workspace_mirror_commit_surfaces_the_session_error() {
        let mux = Mux::new("managed-workspace-rejected-mirror-test", SurfaceOptions::default());
        let placement = mux
            .create_empty_workspace(
                Some("work".into()),
                Some("00000000-0000-4000-8000-000000000004".into()),
                None,
            )
            .unwrap();
        let (mut app, events) = test_app_with_events(Session::Local(mux));
        app.replace_tree(app.session.tree());
        app.apply_machine_ui_update(provider_machine_ui_with_lifecycle());
        let stale_key = "00000000-0000-4000-8000-000000000099";
        app.tree.workspaces_mut()[0].key = stale_key.into();

        app.apply_managed_workspace_session_mutation(ManagedWorkspaceSessionMutation::Rename {
            workspace_key: stale_key.into(),
            name: "renamed".into(),
        });
        app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
        while app.session.has_pending_mutations() {
            app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
        }

        assert_eq!(
            app.status_message.as_deref(),
            Some(localization::catalog().session.operation_failed)
        );
        assert!(app.tree.workspaces().iter().any(|workspace| workspace.id == placement.workspace));
    }

    #[test]
    fn provider_success_commits_through_the_managed_workspace_boundary() {
        let mux = Mux::new("managed-workspace-provider-success-test", SurfaceOptions::default());
        let workspace_key = "00000000-0000-4000-8000-000000000004";
        let placement = mux
            .create_empty_workspace(Some("work".into()), Some(workspace_key.into()), None)
            .unwrap();
        let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
        app.replace_tree(app.session.tree());
        app.apply_machine_ui_update(provider_machine_ui_with_lifecycle());
        let requests = Arc::new(Mutex::new(Vec::new()));
        install_machine_controller(
            &mut app,
            Box::new(FakeMachineController {
                actions: VecDeque::from([
                    FakeMachineAction::Return(Box::new(
                        MachineActionResult::ui(provider_machine_ui_with_lifecycle())
                            .with_session_mutation(ManagedWorkspaceSessionMutation::Rename {
                                workspace_key: workspace_key.into(),
                                name: "renamed".into(),
                            }),
                    )),
                    FakeMachineAction::Return(Box::new(
                        MachineActionResult::ui(provider_machine_ui_with_lifecycle())
                            .with_session_mutation(ManagedWorkspaceSessionMutation::Close {
                                workspace_key: workspace_key.into(),
                            }),
                    )),
                ]),
                requests: requests.clone(),
            }),
        );

        app.request_rename_managed_workspace(placement.workspace, "renamed".into());
        settle_machine_action(&mut app, &events);
        while app.session.has_pending_mutations() {
            app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
        }
        assert!(mux.with_state(|state| {
            state
                .workspaces
                .iter()
                .find(|workspace| workspace.id == placement.workspace)
                .is_some_and(|workspace| workspace.name == "renamed")
        }));

        app.request_delete_workspace(placement.workspace);
        settle_machine_action(&mut app, &events);
        while app.session.has_pending_mutations() {
            app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
        }
        assert!(!mux.with_state(|state| {
            state.workspaces.iter().any(|workspace| workspace.id == placement.workspace)
        }));
        assert!(matches!(
            requests.lock().unwrap().as_slice(),
            [
                MachineRequest::RenameManagedWorkspace { workspace_id, .. },
                MachineRequest::DeleteManagedWorkspace {
                    workspace_id: delete_workspace_id,
                    ..
                }
            ] if workspace_id == workspace_key && delete_workspace_id == workspace_key
        ));
    }

    #[test]
    fn recoverable_workspace_activates_on_mouse_down_and_keyboard() {
        let mux = Mux::new("recoverable-workspace-rail-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.tree = notify_tree(1, false);
        app.sidebar_view = SidebarView::Workspaces;
        app.machine_ui = Some(provider_machine_ui_with_lifecycle());
        app.focus = FocusTarget::WorkspaceRail;
        app.sync_layout((100, 14));

        let mut terminal = Terminal::new(TestBackend::new(100, 14)).unwrap();
        terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
        let text = buffer_text(terminal.backend().buffer());
        assert!(text.contains("quiet-forest"), "{text}");
        assert!(text.contains(localization::catalog().sidebar.recoverable_workspace));
        let hit = app
            .hits
            .iter()
            .find_map(|(rect, hit)| {
                matches!(hit, super::Hit::RecoverableWorkspace { index: 0 }).then_some(*rect)
            })
            .unwrap();

        app.handle_left_down(hit.x, hit.y, KeyModifiers::NONE).unwrap();
        assert_eq!(app.workspace_rail_selection, WorkspaceRailSelection::Recoverable);
        assert_eq!(app.focus, FocusTarget::Pane);
        assert_eq!(
            app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
            Some(&MachineRequest::RestoreManagedWorkspace {
                machine: MachineKey(41),
                workspace_id: "00000000-0000-4000-8000-000000000099".into(),
                expected_version: 12,
            })
        );

        app.machine_ui.as_mut().unwrap().request = None;
        let pad = app
            .hits
            .iter()
            .find_map(|(rect, hit)| {
                matches!(hit, super::Hit::RailPad(RailKind::Workspace)).then_some(*rect)
            })
            .unwrap();
        app.handle_left_down(pad.x, pad.y, KeyModifiers::NONE).unwrap();
        assert_eq!(app.focus, FocusTarget::WorkspaceRail);
        app.handle_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)).unwrap();
        assert_eq!(
            app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
            Some(&MachineRequest::RestoreManagedWorkspace {
                machine: MachineKey(41),
                workspace_id: "00000000-0000-4000-8000-000000000099".into(),
                expected_version: 12,
            })
        );

        app.machine_ui.as_mut().unwrap().request = None;
        app.open_context_menu(hit.x, hit.y);
        assert!(app.menu.as_ref().is_some_and(ContextMenu::targets_provider_state));
        app.activate_menu(MenuAction::PurgeManagedWorkspace(0)).unwrap();
        app.prompt.as_mut().unwrap().input.insert_str("CONFIRM");
        app.commit_prompt();
        assert_eq!(
            app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
            Some(&MachineRequest::PurgeManagedWorkspace {
                machine: MachineKey(41),
                workspace_id: "00000000-0000-4000-8000-000000000099".into(),
                expected_version: 12,
            })
        );
    }

    fn provider_machine_ui_with_policy(
        default_mode: WorkspaceCreationMode,
        modes: Vec<WorkspaceCreationMode>,
    ) -> MachineUiState {
        let machine = MachineKey(41);
        let mut ui = MachineUiState::new(MachineSnapshot {
            machines: vec![MachineDescriptor {
                key: machine,
                id: "managed-41".into(),
                name: "managed".into(),
                subtitle: "cloud".into(),
                status: MachineStatus::Running,
            }],
            active: Some(machine),
            capabilities: MachineCapabilities { create: true, connect: true },
        });
        ui.connect_accepts_pairing_code = true;
        ui.session_available = false;
        ui.set_workspace_creation_policy(
            machine,
            WorkspaceCreationPolicy::ProviderOwned { default_mode, modes },
        );
        ui
    }

    fn provider_controls_ui() -> MachineUiState {
        let mut ui = provider_machine_ui();
        ui.set_provider_presentation(ProviderPresentation {
            scopes: vec![
                ProviderScopeDescriptor {
                    id: "personal".into(),
                    name: "Personal".into(),
                    kind: ProviderScopeKind::Personal,
                    can_admin: false,
                },
                ProviderScopeDescriptor {
                    id: "team-acme".into(),
                    name: "Acme".into(),
                    kind: ProviderScopeKind::Team,
                    can_admin: true,
                },
            ],
            selected_scope_id: "team-acme".into(),
            actions: vec![
                ProviderActionDescriptor {
                    id: "invite-member".into(),
                    label: "Invite member".into(),
                    target: ProviderActionTarget::Scope,
                    destructive: false,
                    fields: vec![ProviderActionFieldDescriptor {
                        id: "email".into(),
                        label: "Member email".into(),
                        kind: ProviderActionFieldKind::Email,
                        required: true,
                        max_length: Some(254),
                        minimum: None,
                        maximum: None,
                        placeholder: None,
                    }],
                },
                ProviderActionDescriptor {
                    id: "manage-billing".into(),
                    label: "Manage billing".into(),
                    target: ProviderActionTarget::Scope,
                    destructive: false,
                    fields: Vec::new(),
                },
            ],
        });
        ui
    }

    /// Draw the app and open the context menu on the "+ new vm" row - the
    /// home of the provider scope and action entries now that their rail
    /// rows are gone.
    fn open_new_vm_context_menu(app: &mut App) {
        app.sync_layout((100, 16));
        let mut terminal = Terminal::new(TestBackend::new(100, 16)).unwrap();
        terminal.draw(|frame| crate::ui::draw(app, frame)).unwrap();
        let rect = app
            .hits
            .iter()
            .find_map(|(rect, hit)| matches!(hit, super::Hit::NewVm).then_some(*rect))
            .expect("new vm row");
        app.open_context_menu(rect.x, rect.y);
    }

    #[test]
    fn provider_scope_switches_from_the_new_vm_context_menu() {
        let mux = Mux::new("provider-scope-keyboard-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.machine_ui = Some(provider_controls_ui());
        open_new_vm_context_menu(&mut app);

        let menu = app.menu.as_ref().expect("new vm context menu");
        assert_eq!(
            menu.levels[0].items.first(),
            Some(&MenuItem::LabeledAction {
                label: "  Personal (personal)".into(),
                action: MenuAction::SelectProviderScope(0),
            })
        );
        // The ACTIVE scope starts selected, so Enter alone changes nothing.
        assert_eq!(
            app.menu.as_ref().and_then(ContextMenu::selected_action),
            Some(MenuAction::SelectProviderScope(1))
        );
        app.handle_menu_key(KeyEvent::new(KeyCode::Up, KeyModifiers::NONE)).unwrap();
        app.handle_menu_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)).unwrap();
        assert_eq!(
            app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
            Some(&MachineRequest::SelectProviderScope("personal".into()))
        );
        assert!(!app.quit);
    }

    #[test]
    fn provider_actions_and_prompt_are_reachable_from_the_new_vm_menu() {
        let mux = Mux::new("provider-actions-mouse-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.machine_ui = Some(provider_controls_ui());
        open_new_vm_context_menu(&mut app);

        let menu = app.menu.as_ref().expect("new vm context menu");
        let invite = MenuItem::LabeledAction {
            label: "Invite member".into(),
            action: MenuAction::InvokeProviderAction(0),
        };
        let index = menu.levels[0]
            .items
            .iter()
            .position(|item| *item == invite)
            .expect("provider action in the new vm menu");
        let item_x = menu.levels[0].rect.x + 2;
        let item_y = menu.levels[0].rect.y + 1 + index as u16;
        app.handle_left_down(item_x, item_y, KeyModifiers::NONE).unwrap();
        assert_eq!(app.prompt.as_ref().map(|prompt| prompt.label.as_str()), Some("Member email"));

        app.prompt.as_mut().unwrap().input.insert_str("invalid");
        app.commit_prompt();
        assert!(app.prompt.is_some(), "invalid input keeps the editable prompt open");
        assert_eq!(
            app.status_message.as_deref(),
            Some(localization::catalog().sidebar.action_invalid_email)
        );

        let prompt = app.prompt.as_mut().unwrap();
        prompt.input.clear();
        prompt.input.insert_str("person@example.com");
        app.commit_prompt();
        assert_eq!(
            app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
            Some(&MachineRequest::InvokeProviderAction {
                action_id: "invite-member".into(),
                values: BTreeMap::from([(
                    "email".into(),
                    ProviderActionValue::Text("person@example.com".into())
                )]),
                machine_id: None,
                workspace_id: None,
            })
        );
        assert!(!app.quit);
    }

    #[test]
    fn destructive_workspace_action_binds_context_before_confirmation() {
        let mux = Mux::new("provider-workspace-action-test", SurfaceOptions::default());
        let workspace_key = "00000000-0000-4000-8000-000000000123";
        mux.create_empty_workspace(Some("ports".into()), Some(workspace_key.into()), None).unwrap();
        let mut app = test_app(Session::Local(mux));
        app.replace_tree(app.session.tree());
        let mut ui = provider_controls_ui();
        ui.provider.as_mut().unwrap().actions.push(ProviderActionDescriptor {
            id: "workspace.port.make_public".into(),
            label: "Make workspace port public".into(),
            target: ProviderActionTarget::SelectedWorkspace,
            destructive: true,
            fields: vec![ProviderActionFieldDescriptor {
                id: "port".into(),
                label: "Port".into(),
                kind: ProviderActionFieldKind::Integer,
                required: true,
                max_length: None,
                minimum: Some(1),
                maximum: Some(i64::from(u16::MAX)),
                placeholder: None,
            }],
        });
        ui.set_managed_workspaces(
            MachineKey(41),
            vec![ManagedWorkspaceDescriptor {
                id: workspace_key.into(),
                name: "ports".into(),
                mode: WorkspaceCreationMode::Isolated,
                status: ManagedWorkspaceStatus::Active,
                version: 1,
                recoverable_until: None,
                capabilities: ManagedWorkspaceCapabilities::default(),
            }],
        );
        ui.session_available = true;
        app.machine_ui = Some(ui);

        app.begin_provider_action(2);
        let mut terminal = Terminal::new(TestBackend::new(100, 20)).unwrap();
        terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
        let input = app.prompt.as_ref().unwrap().input_rect;
        terminal.backend_mut().assert_cursor_position((input.x, input.y));
        app.prompt.as_mut().unwrap().input.insert_str("3000");
        app.handle_prompt_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)).unwrap();
        assert!(matches!(
            app.prompt.as_ref().map(|prompt| &prompt.target),
            Some(PromptTarget::ConfirmProviderAction)
        ));
        assert!(
            app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()).is_none(),
            "destructive action must wait for explicit confirmation"
        );

        app.prompt.as_mut().unwrap().input.insert_str("CONFIRM");
        terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
        let ok = app.prompt.as_ref().unwrap().ok;
        app.handle_prompt_click(ok.x, ok.y).unwrap();
        assert_eq!(
            app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
            Some(&MachineRequest::InvokeProviderAction {
                action_id: "workspace.port.make_public".into(),
                values: BTreeMap::from([("port".into(), ProviderActionValue::Integer(3_000))]),
                machine_id: Some("managed-41".into()),
                workspace_id: Some(workspace_key.into()),
            })
        );
    }

    #[test]
    fn provider_action_context_excludes_a_client_local_overlay_machine() {
        let mux = Mux::new("provider-action-local-overlay-test", SurfaceOptions::default());
        mux.create_empty_workspace(
            Some("local".into()),
            Some("00000000-0000-4000-8000-000000000123".into()),
            None,
        )
        .unwrap();
        let mut app = test_app(Session::Local(mux));
        app.replace_tree(app.session.tree());
        let mut ui = provider_controls_ui();
        let local_key = MachineKey(crate::machine_runtime::CLIENT_MACHINE_KEY_START);
        ui.snapshot.machines.push(MachineDescriptor {
            key: local_key,
            id: "managed-41".into(),
            name: "Local".into(),
            subtitle: "client local".into(),
            status: MachineStatus::Running,
        });
        ui.snapshot.active = Some(local_key);
        ui.selection = ui.snapshot.active_index().unwrap();
        ui.session_available = true;
        app.machine_ui = Some(ui);

        assert_eq!(app.provider_action_context(), ProviderActionContext::default());
    }

    #[test]
    fn provider_action_context_binds_only_the_active_provider_session_workspace() {
        let mux = Mux::new("provider-action-workspace-ownership-test", SurfaceOptions::default());
        let session_workspace = "00000000-0000-4000-8000-000000000123";
        mux.create_empty_workspace(Some("active".into()), Some(session_workspace.into()), None)
            .unwrap();
        let mut app = test_app(Session::Local(mux));
        app.replace_tree(app.session.tree());
        let mut ui = provider_controls_ui();
        ui.session_available = false;
        app.machine_ui = Some(ui.clone());

        assert_eq!(
            app.provider_action_context(),
            ProviderActionContext { machine_id: Some("managed-41".into()), workspace_id: None }
        );

        ui.session_available = true;
        app.machine_ui = Some(ui);
        assert_eq!(
            app.provider_action_context(),
            ProviderActionContext {
                machine_id: Some("managed-41".into()),
                workspace_id: Some(session_workspace.into()),
            }
        );
    }

    #[test]
    fn provider_snapshot_update_invalidates_stale_menu_and_prompt() {
        let mux = Mux::new("provider-overlay-invalidation-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.machine_ui = Some(provider_controls_ui());
        open_new_vm_context_menu(&mut app);
        assert!(app.menu.as_ref().is_some_and(ContextMenu::targets_provider_state));

        let mut update = provider_controls_ui();
        update.provider.as_mut().unwrap().actions.remove(0);
        app.handle(AppEvent::MachineUiUpdated(Box::new(update))).unwrap();
        assert!(app.menu.is_none(), "a menu cannot retain provider action indexes across updates");

        app.machine_ui = Some(provider_controls_ui());
        app.begin_provider_action(0);
        assert!(matches!(
            app.prompt.as_ref().map(|prompt| &prompt.target),
            Some(PromptTarget::ProviderAction(0))
        ));

        let mut update = provider_controls_ui();
        update.provider.as_mut().unwrap().actions.swap(0, 1);
        app.handle(AppEvent::MachineUiUpdated(Box::new(update))).unwrap();
        assert!(app.prompt.is_none(), "a prompt cannot submit against a reordered action index");
    }

    #[test]
    fn provider_action_menu_resource_blocks_index_retargeting() {
        let mux = Mux::new("provider-action-menu-identity-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.machine_ui = Some(provider_controls_ui());
        open_new_vm_context_menu(&mut app);

        let action = MenuAction::InvokeProviderAction(0);
        assert!(
            matches!(
                app.menu.as_ref().and_then(|menu| menu.captured_resource(action)),
                Some(Some(_))
            ),
            "provider actions must capture the stable action behind their displayed index"
        );
        // The combined menu leads with scope entries; move the selection onto
        // the displayed action before the provider array changes.
        for _ in 0..16 {
            if app.menu.as_ref().and_then(ContextMenu::selected_action) == Some(action) {
                break;
            }
            app.handle_menu_key(KeyEvent::new(KeyCode::Down, KeyModifiers::NONE)).unwrap();
        }
        assert_eq!(app.menu.as_ref().and_then(ContextMenu::selected_action), Some(action));

        app.machine_ui.as_mut().unwrap().provider.as_mut().unwrap().actions.swap(0, 1);
        app.handle_menu_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)).unwrap();

        assert!(
            app.machine_ui.as_ref().unwrap().request.is_none(),
            "the displayed action cannot retarget after the provider array changes"
        );
    }

    #[test]
    fn provider_scope_menu_resource_blocks_index_retargeting() {
        let mux = Mux::new("provider-scope-menu-identity-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.machine_ui = Some(provider_controls_ui());
        open_new_vm_context_menu(&mut app);

        let action = MenuAction::SelectProviderScope(1);
        assert!(
            matches!(
                app.menu.as_ref().and_then(|menu| menu.captured_resource(action)),
                Some(Some(_))
            ),
            "provider scopes must capture the stable scope behind their displayed index"
        );

        app.machine_ui.as_mut().unwrap().provider.as_mut().unwrap().scopes.swap(0, 1);
        app.handle_menu_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)).unwrap();

        assert!(
            app.machine_ui.as_ref().unwrap().request.is_none(),
            "the displayed scope cannot retarget after the provider array changes"
        );
    }

    #[test]
    fn recoverable_workspace_menu_resource_blocks_index_retargeting() {
        let mux = Mux::new("recoverable-workspace-menu-identity-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        let mut ui = provider_machine_ui_with_lifecycle();
        let mut workspaces = ui.managed_workspaces().to_vec();
        workspaces.push(ManagedWorkspaceDescriptor {
            id: "00000000-0000-4000-8000-000000000100".into(),
            name: "second-recoverable".into(),
            mode: WorkspaceCreationMode::Host,
            status: ManagedWorkspaceStatus::Recoverable,
            version: 13,
            recoverable_until: Some("2030-01-03T03:04:05Z".into()),
            capabilities: ManagedWorkspaceCapabilities {
                rename: false,
                delete: false,
                restore: true,
                purge: true,
            },
        });
        ui.set_managed_workspaces(MachineKey(41), workspaces.clone());
        app.machine_ui = Some(ui);
        app.sidebar_view = SidebarView::Workspaces;
        app.sidebar_width = 20;
        app.hits.push((
            Rect { x: 2, y: 2, width: 8, height: 1 },
            super::Hit::RecoverableWorkspace { index: 0 },
        ));
        app.open_context_menu(2, 2);

        let action = MenuAction::RestoreManagedWorkspace(0);
        assert!(
            matches!(
                app.menu.as_ref().and_then(|menu| menu.captured_resource(action)),
                Some(Some(_))
            ),
            "recoverable workspaces must capture the stable workspace behind their displayed index"
        );

        workspaces.swap(1, 2);
        app.machine_ui.as_mut().unwrap().set_managed_workspaces(MachineKey(41), workspaces);
        app.handle_menu_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)).unwrap();

        assert!(
            app.machine_ui.as_ref().unwrap().request.is_none(),
            "the displayed workspace cannot retarget after the recoverable array changes"
        );
    }

    #[test]
    fn unavailable_zero_machine_state_skips_initial_workspace_and_renders_both_rails() {
        let mux = Mux::new("provider-zero-state-test", SurfaceOptions::default());
        let unavailable = MachineUiState::new(MachineSnapshot {
            machines: Vec::new(),
            active: None,
            capabilities: MachineCapabilities { create: true, connect: true },
        });
        super::ensure_initial_for_machine_ui(
            &Session::Local(mux.clone()),
            Some((40, 12)),
            Some(&unavailable),
        )
        .unwrap();
        assert!(Session::Local(mux.clone()).tree().workspaces().is_empty());

        let mut app = test_app(Session::Local(mux));
        app.sidebar_view = SidebarView::Workspaces;
        app.machine_ui = Some(MachineUiState::new(MachineSnapshot {
            machines: Vec::new(),
            active: None,
            capabilities: MachineCapabilities { create: true, connect: true },
        }));
        app.sync_layout((100, 16));
        assert!(app.sidebar_layout.machine.is_some());
        assert!(app.sidebar_layout.workspace.is_some());
        assert!(!app.session_available());

        let mut terminal = Terminal::new(TestBackend::new(100, 16)).unwrap();
        terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
        let text = buffer_text(terminal.backend().buffer());
        assert!(text.contains("no machines"), "{text}");
        assert!(text.contains("+ new vm"), "{text}");
        assert!(text.contains("+ ssh host"), "{text}");
        assert!(!text.contains("+ +"), "the renderer owns the plus prefix: {text}");
        assert!(
            !app.hits.iter().any(|(_, hit)| { matches!(hit, super::Hit::CreateWorkspace { .. }) })
        );

        app.focus = FocusTarget::MachineRail;
        app.handle_key(KeyEvent::new(KeyCode::End, KeyModifiers::NONE)).unwrap();
        app.handle_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)).unwrap();
        assert!(app.machine_ui.as_ref().is_some_and(|ui| ui.request.is_none()));
        assert!(app.prompt.is_some(), "connect machine is keyboard reachable");
        assert_eq!(
            app.prompt.as_ref().map(|prompt| prompt.label.as_str()),
            Some(localization::catalog().sidebar.connect_host_prompt)
        );
        app.prompt = None;
        app.handle_key(KeyEvent::new(KeyCode::Right, KeyModifiers::NONE)).unwrap();
        assert_eq!(app.focus, FocusTarget::WorkspaceRail);
    }

    #[test]
    fn machine_ui_survives_initial_pty_exhaustion_with_an_actionable_status() {
        let machine_ui = provider_machine_ui();
        let failure = anyhow::anyhow!(
            "remote command rejected: failed to open PTY: Device not configured (os error 6)"
        );

        let status = super::recover_initial_workspace_failure(Err(failure), Some(&machine_ui))
            .unwrap()
            .expect("machine mode keeps the launch failure as status");
        assert_eq!(status, localization::catalog().runtime.terminal_capacity_exhausted);

        let plain_failure = anyhow::anyhow!("failed to open PTY: Device not configured");
        assert!(
            super::recover_initial_workspace_failure(Err(plain_failure), None).is_err(),
            "plain mode must still fail before switching the host terminal into raw mode"
        );
    }

    #[test]
    fn connect_machine_footer_captures_the_route_shown_by_each_entrypoint() {
        let mux = Mux::new("connect-machine-footer-input-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.sidebar_view = SidebarView::Workspaces;
        app.machine_ui = Some(provider_machine_ui());
        app.sync_layout((100, 16));
        let mut terminal = Terminal::new(TestBackend::new(100, 16)).unwrap();
        terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();

        let connect = app
            .hits
            .iter()
            .find_map(|(rect, hit)| {
                matches!(hit, super::Hit::ConnectMachine).then_some((rect.x, rect.y))
            })
            .unwrap();
        app.handle_left_down(connect.0, connect.1, KeyModifiers::NONE).unwrap();
        assert_eq!(
            app.prompt.as_ref().map(|prompt| prompt.label.as_str()),
            Some(localization::catalog().sidebar.connect_prompt)
        );
        app.prompt.as_mut().unwrap().input.insert_str("PAIR 4J7K");
        let mut update = app.machine_ui.clone().unwrap();
        update.connect_accepts_pairing_code = false;
        app.apply_machine_ui_update(update);
        app.commit_prompt();
        assert!(app.prompt.is_some(), "connection prompt must become a loading dialog");
        assert_eq!(
            app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
            Some(&MachineRequest::Connect {
                target: "PAIR 4J7K".into(),
                route: MachineConnectRoute::Provider,
            })
        );
        app.close_prompt();

        let machine = app.machine_ui.as_mut().unwrap();
        machine.request = None;
        machine.connect_accepts_pairing_code = false;
        app.focus = FocusTarget::MachineRail;
        app.handle_key(KeyEvent::new(KeyCode::End, KeyModifiers::NONE)).unwrap();
        app.handle_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)).unwrap();
        assert_eq!(
            app.prompt.as_ref().map(|prompt| prompt.label.as_str()),
            Some(localization::catalog().sidebar.connect_host_prompt)
        );
        app.prompt.as_mut().unwrap().input.insert_str("mini.local");
        let mut update = app.machine_ui.clone().unwrap();
        update.connect_accepts_pairing_code = true;
        app.apply_machine_ui_update(update);
        app.commit_prompt();
        assert!(app.prompt.is_some(), "connection prompt must become a loading dialog");
        assert_eq!(
            app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
            Some(&MachineRequest::Connect {
                target: "mini.local".into(),
                route: MachineConnectRoute::Local,
            })
        );
    }

    #[test]
    fn stale_connection_completion_cannot_settle_a_retry_to_the_same_host() {
        let mux = Mux::new("connection-attempt-correlation-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        let request = MachineRequest::Connect {
            target: "mini.local".into(),
            route: MachineConnectRoute::Local,
        };
        app.connection_transaction = Some(super::ConnectionTransaction {
            attempt: 2,
            target: "mini.local".into(),
            route: MachineConnectRoute::Local,
            phase: super::ConnectionDialogPhase::Connecting,
        });

        app.report_machine_action_failure(Some(&request), Some(1), "old failure".into());
        assert_eq!(
            app.connection_transaction.as_ref().map(|transaction| &transaction.phase),
            Some(&super::ConnectionDialogPhase::Connecting)
        );
        assert!(app.status_message.is_none());

        app.report_machine_action_failure(Some(&request), Some(2), "current failure".into());
        assert!(matches!(
            app.connection_transaction.as_ref().map(|transaction| &transaction.phase),
            Some(super::ConnectionDialogPhase::Failed(error)) if error == "current failure"
        ));
        assert_eq!(app.status_message.as_deref(), Some("current failure"));
    }

    #[test]
    fn connection_dialog_renders_loading_error_retry_and_copy_states() {
        let mux = Mux::new("connection-dialog-state-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.machine_ui = Some(provider_machine_ui());
        app.begin_machine_connection("mini.local".into(), MachineConnectRoute::Local);
        app.sync_layout((100, 24));
        let mut terminal = Terminal::new(TestBackend::new(100, 24)).unwrap();

        terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
        let rendered = buffer_text(terminal.backend().buffer());
        assert!(rendered.contains("Connecting to mini.local"), "{rendered}");

        let request = MachineRequest::Connect {
            target: "mini.local".into(),
            route: MachineConnectRoute::Local,
        };
        let attempt = app.connection_transaction.as_ref().unwrap().attempt;
        app.fail_connection_transaction(
            Some(&request),
            Some(attempt),
            "permission denied by remote host".into(),
        );
        terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
        let rendered = buffer_text(terminal.backend().buffer());
        assert!(rendered.contains("Could not connect to mini.local"), "{rendered}");
        assert!(rendered.contains("permission denied by remote host"), "{rendered}");
        assert!(rendered.contains("Retry"), "{rendered}");
        assert!(rendered.contains("Copy message"), "{rendered}");
        let prompt = app.prompt.as_ref().unwrap();
        assert!(prompt.ok.width > 0);
        assert!(prompt.clear.width > 0);
    }

    #[test]
    fn closing_connection_dialog_removes_the_queued_connect_request() {
        let mux = Mux::new("connection-dialog-queued-cancel-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.machine_ui = Some(provider_machine_ui());
        app.begin_machine_connection("mini.local".into(), MachineConnectRoute::Local);

        app.close_prompt();

        assert!(app.prompt.is_none());
        assert!(app.connection_transaction.is_none());
        assert!(app.machine_ui.as_ref().is_some_and(|ui| ui.request.is_none()));
        assert!(!app.machine_action_in_flight);
    }

    #[test]
    fn provider_owned_workspace_policy_never_creates_an_untracked_session_workspace() {
        let mux = Mux::new("provider-owned-initial-workspace-test", SurfaceOptions::default());
        let mut ui = provider_machine_ui();
        ui.session_available = true;
        super::ensure_initial_for_machine_ui(
            &Session::Local(mux.clone()),
            Some((40, 12)),
            Some(&ui),
        )
        .unwrap();
        assert!(Session::Local(mux).tree().workspaces().is_empty());
    }

    #[test]
    fn unavailable_placeholder_blocks_session_mutations() {
        let mux = Mux::new("provider-mutation-guard-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux.clone()));
        app.machine_ui = Some(MachineUiState::new(MachineSnapshot {
            machines: Vec::new(),
            active: None,
            capabilities: MachineCapabilities::default(),
        }));

        app.run_action(Action::NewScreen).unwrap();

        assert!(Session::Local(mux).tree().workspaces().is_empty());
        assert_eq!(
            app.status_message.as_deref(),
            Some(localization::catalog().sidebar.no_active_session)
        );
    }

    #[test]
    fn provider_workspace_keyboard_action_requests_isolated_workspace() {
        let mux = Mux::new("provider-workspace-key-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux.clone()));
        app.machine_ui = Some(provider_machine_ui());

        app.run_action(Action::NewWorkspace).unwrap();

        assert!(matches!(
            app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
            Some(MachineRequest::CreateManagedIsolatedWorkspace(MachineKey(41)))
        ));
        assert!(!app.quit);
        assert!(Session::Local(mux).tree().workspaces().is_empty());
    }

    #[test]
    fn provider_workspace_footer_exposes_isolated_and_shared_mouse_actions() {
        let mux = Mux::new("provider-workspace-mouse-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.sidebar_view = SidebarView::Workspaces;
        app.machine_ui = Some(provider_machine_ui());
        app.sync_layout((100, 16));

        let mut terminal = Terminal::new(TestBackend::new(100, 16)).unwrap();
        terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
        let text = buffer_text(terminal.backend().buffer());
        assert!(text.contains("new isolated"), "{text}");
        assert!(text.contains("new shared"), "{text}");
        let isolated = app
            .hits
            .iter()
            .find_map(|(rect, hit)| {
                matches!(
                    hit,
                    super::Hit::CreateWorkspace { mode: Some(WorkspaceCreationMode::Isolated) }
                )
                .then_some(*rect)
            })
            .expect("isolated workspace action hit");
        let shared = app
            .hits
            .iter()
            .find_map(|(rect, hit)| {
                matches!(
                    hit,
                    super::Hit::CreateWorkspace { mode: Some(WorkspaceCreationMode::Host) }
                )
                .then_some(*rect)
            })
            .expect("shared workspace action hit");

        app.handle_left_down(isolated.x, isolated.y, KeyModifiers::NONE).unwrap();
        assert!(matches!(
            app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
            Some(MachineRequest::CreateManagedIsolatedWorkspace(MachineKey(41)))
        ));

        app.quit = false;
        app.machine_ui.as_mut().unwrap().request = None;
        app.handle_left_down(shared.x, shared.y, KeyModifiers::NONE).unwrap();
        assert!(matches!(
            app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
            Some(MachineRequest::CreateManagedHostWorkspace(MachineKey(41)))
        ));
        assert!(!app.quit);
    }

    #[test]
    fn provider_workspace_subset_and_default_drive_footer_and_new_workspace_action() {
        let mux = Mux::new("provider-workspace-subset-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.sidebar_view = SidebarView::Workspaces;
        app.machine_ui = Some(provider_machine_ui_with_policy(
            WorkspaceCreationMode::Host,
            vec![WorkspaceCreationMode::Host],
        ));
        app.sync_layout((100, 12));

        let mut terminal = Terminal::new(TestBackend::new(100, 12)).unwrap();
        terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
        let text = buffer_text(terminal.backend().buffer());
        assert!(text.contains("new shared"), "{text}");
        assert!(!text.contains("new isolated"), "{text}");

        app.run_action(Action::NewWorkspace).unwrap();
        assert_eq!(
            app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
            Some(&MachineRequest::CreateManagedHostWorkspace(MachineKey(41)))
        );
    }

    #[test]
    fn provider_workspace_default_is_independent_of_advertised_mode_order() {
        let mux = Mux::new("provider-workspace-default-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.sidebar_view = SidebarView::Workspaces;
        app.machine_ui = Some(provider_machine_ui_with_policy(
            WorkspaceCreationMode::Isolated,
            vec![WorkspaceCreationMode::Host, WorkspaceCreationMode::Isolated],
        ));
        app.sync_layout((100, 12));

        let mut terminal = Terminal::new(TestBackend::new(100, 12)).unwrap();
        terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
        let host_y = app
            .hits
            .iter()
            .find_map(|(rect, hit)| {
                matches!(
                    hit,
                    super::Hit::CreateWorkspace { mode: Some(WorkspaceCreationMode::Host) }
                )
                .then_some(rect.y)
            })
            .unwrap();
        let isolated_y = app
            .hits
            .iter()
            .find_map(|(rect, hit)| {
                matches!(
                    hit,
                    super::Hit::CreateWorkspace { mode: Some(WorkspaceCreationMode::Isolated) }
                )
                .then_some(rect.y)
            })
            .unwrap();
        assert!(host_y < isolated_y, "provider mode order must be preserved");

        app.run_action(Action::NewWorkspace).unwrap();
        assert_eq!(
            app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
            Some(&MachineRequest::CreateManagedIsolatedWorkspace(MachineKey(41)))
        );
    }

    #[test]
    fn keyboard_traverses_machine_controls_catalog_and_pinned_actions() {
        let mux = Mux::new("machine-rail-keyboard-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.machine_ui = Some(provider_controls_ui());
        app.focus = FocusTarget::MachineRail;
        app.sync_layout((100, 9));

        app.handle_key(KeyEvent::new(KeyCode::Home, KeyModifiers::NONE)).unwrap();
        assert!(matches!(
            app.machine_ui.as_ref().and_then(MachineUiState::rail_target),
            Some(crate::machine::MachineRailTarget::Machine(_))
        ));
        app.handle_key(KeyEvent::new(KeyCode::Down, KeyModifiers::NONE)).unwrap();
        assert_eq!(
            app.machine_ui.as_ref().and_then(MachineUiState::rail_target),
            Some(crate::machine::MachineRailTarget::NewVm)
        );
        app.handle_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)).unwrap();
        assert_eq!(
            app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
            Some(&MachineRequest::Create)
        );

        app.machine_ui.as_mut().unwrap().request = None;
        app.handle_key(KeyEvent::new(KeyCode::End, KeyModifiers::NONE)).unwrap();
        app.handle_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)).unwrap();
        assert_eq!(
            app.machine_ui.as_ref().and_then(MachineUiState::rail_target),
            Some(crate::machine::MachineRailTarget::ConnectMachine)
        );
        assert!(app.prompt.is_some());
    }

    #[test]
    fn new_machine_opens_native_source_picker_and_routes_stable_source_id() {
        let mux = Mux::new("machine-source-picker-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        let mut ui = MachineUiState::new(MachineSnapshot {
            machines: vec![MachineDescriptor {
                key: MachineKey(1),
                id: "current".into(),
                name: "local".into(),
                subtitle: "local".into(),
                status: MachineStatus::Running,
            }],
            active: Some(MachineKey(1)),
            capabilities: MachineCapabilities { create: true, connect: false },
        });
        ui.creation_sources = vec![
            MachineCreationSource {
                id: "docker".into(),
                name: "Docker".into(),
                subtitle: "container prototype".into(),
            },
            MachineCreationSource {
                id: "firecracker".into(),
                name: "Firecracker".into(),
                subtitle: "microVM prototype".into(),
            },
        ];
        ui.rail_selection = MachineRailSelection::NewVm;
        app.machine_ui = Some(ui);
        app.focus = FocusTarget::MachineRail;
        app.sync_layout((100, 12));

        app.handle_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)).unwrap();
        assert!(app.menu.is_some());
        app.handle_menu_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)).unwrap();
        assert_eq!(
            app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
            Some(&MachineRequest::CreateFrom { source_id: "docker".into() })
        );
    }

    #[test]
    fn keyboard_traverses_every_advertised_workspace_creation_mode() {
        let mux = Mux::new("workspace-rail-keyboard-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.sidebar_view = SidebarView::Workspaces;
        app.machine_ui = Some(provider_machine_ui_with_policy(
            WorkspaceCreationMode::Isolated,
            vec![WorkspaceCreationMode::Host, WorkspaceCreationMode::Isolated],
        ));
        app.focus = FocusTarget::WorkspaceRail;
        app.sync_layout((100, 6));

        app.handle_key(KeyEvent::new(KeyCode::Home, KeyModifiers::NONE)).unwrap();
        assert_eq!(
            app.workspace_rail_selection,
            workspace_creation_selection(Some(WorkspaceCreationMode::Host))
        );
        app.handle_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)).unwrap();
        assert_eq!(
            app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
            Some(&MachineRequest::CreateManagedHostWorkspace(MachineKey(41)))
        );

        app.machine_ui.as_mut().unwrap().request = None;
        app.handle_key(KeyEvent::new(KeyCode::Down, KeyModifiers::NONE)).unwrap();
        assert_eq!(
            app.workspace_rail_selection,
            workspace_creation_selection(Some(WorkspaceCreationMode::Isolated))
        );
        app.handle_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)).unwrap();
        assert_eq!(
            app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
            Some(&MachineRequest::CreateManagedIsolatedWorkspace(MachineKey(41)))
        );
    }

    #[test]
    fn short_terminal_keeps_both_rails_footer_actions_clickable() {
        let mux = Mux::new("short-rail-footer-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.sidebar_view = SidebarView::Workspaces;
        app.machine_ui = Some(provider_machine_ui());
        app.sync_layout((100, 5));

        let mut terminal = Terminal::new(TestBackend::new(100, 5)).unwrap();
        terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();

        assert!(app.hits.iter().any(|(_, hit)| matches!(hit, super::Hit::NewVm)));
        assert!(app.hits.iter().any(|(_, hit)| matches!(hit, super::Hit::ConnectMachine)));
        assert!(app.hits.iter().any(|(_, hit)| {
            matches!(
                hit,
                super::Hit::CreateWorkspace { mode: Some(WorkspaceCreationMode::Isolated) }
            )
        }));
        assert!(app.hits.iter().any(|(_, hit)| {
            matches!(hit, super::Hit::CreateWorkspace { mode: Some(WorkspaceCreationMode::Host) })
        }));
    }

    #[test]
    fn alt_directional_focus_traverses_sidebar_at_the_pane_boundary() {
        let (mux, surface) = test_mux("alt-sidebar-boundary-test", None);
        let mut app = test_app(Session::Local(mux.clone()));
        let mut machine_ui = provider_machine_ui();
        machine_ui.session_available = true;
        app.machine_ui = Some(machine_ui);
        app.sidebar_view = SidebarView::Workspaces;
        app.replace_tree(app.session.tree());
        app.sync_layout((100, 16));

        app.handle_key(KeyEvent::new(KeyCode::Left, KeyModifiers::ALT)).unwrap();
        assert_eq!(app.focus, FocusTarget::WorkspaceRail);

        app.handle_key(KeyEvent::new(KeyCode::Char('h'), KeyModifiers::ALT)).unwrap();
        assert_eq!(app.focus, FocusTarget::MachineRail);
        app.handle_key(KeyEvent::new(KeyCode::Char('l'), KeyModifiers::ALT)).unwrap();
        assert_eq!(app.focus, FocusTarget::WorkspaceRail);

        app.handle_key(KeyEvent::new(KeyCode::Right, KeyModifiers::ALT)).unwrap();
        assert_eq!(app.focus, FocusTarget::Pane);

        app.sidebar_view = SidebarView::Files;
        app.focus = FocusTarget::WorkspaceRail;
        app.handle_key(KeyEvent::new(KeyCode::Right, KeyModifiers::ALT)).unwrap();
        assert_eq!(app.focus, FocusTarget::Pane);

        mux.close_surface(surface.id).unwrap();
    }

    #[test]
    fn sidebar_top_pads_are_the_only_pointer_entrypoint_for_rail_focus() {
        let (mux, surface) = test_mux("sidebar-pointer-focus-test", None);
        let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
        let mut machine_ui = provider_machine_ui();
        machine_ui.session_available = true;
        app.machine_ui = Some(machine_ui);
        app.sidebar_view = SidebarView::Workspaces;
        app.replace_tree(app.session.tree());
        app.sync_layout((100, 16));

        let mut terminal = Terminal::new(TestBackend::new(100, 16)).unwrap();
        terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
        let machine_row = app
            .hits
            .iter()
            .find_map(|(rect, hit)| matches!(hit, super::Hit::Machine { .. }).then_some(*rect))
            .unwrap();
        let workspace_row = app
            .hits
            .iter()
            .find_map(|(rect, hit)| matches!(hit, super::Hit::Workspace { .. }).then_some(*rect))
            .unwrap();
        let machine_area = app.sidebar_layout.machine.unwrap();
        let workspace_area = app.sidebar_layout.workspace.unwrap();

        app.focus = FocusTarget::WorkspaceRail;
        app.handle_left_down(workspace_row.x, workspace_row.y, KeyModifiers::NONE).unwrap();
        app.handle_left_up(workspace_row.x, workspace_row.y).unwrap();
        assert_eq!(app.focus, FocusTarget::Pane);
        while app.session.has_pending_mutations() {
            app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
        }

        app.handle_left_down(workspace_area.x + 1, workspace_area.y, KeyModifiers::NONE).unwrap();
        app.handle_left_up(workspace_area.x + 1, workspace_area.y).unwrap();
        assert_eq!(app.focus, FocusTarget::WorkspaceRail);

        app.handle_left_down(machine_row.x, machine_row.y, KeyModifiers::NONE).unwrap();
        app.handle_left_up(machine_row.x, machine_row.y).unwrap();
        assert_eq!(app.focus, FocusTarget::Pane);

        app.handle_left_down(machine_area.x + 1, machine_area.y, KeyModifiers::NONE).unwrap();
        app.handle_left_up(machine_area.x + 1, machine_area.y).unwrap();
        assert_eq!(app.focus, FocusTarget::MachineRail);

        mux.close_surface(surface.id).unwrap();
    }

    #[test]
    fn mouse_drag_resizes_machine_and_workspace_rails_independently() {
        let mux = Mux::new("rail-mouse-resize-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.sidebar_view = SidebarView::Workspaces;
        app.machine_ui = Some(provider_machine_ui());
        app.sync_layout((100, 12));

        let mut terminal = Terminal::new(TestBackend::new(100, 12)).unwrap();
        terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
        let divider = |app: &App, kind| {
            app.hits
                .iter()
                .find_map(|(rect, hit)| (*hit == super::Hit::RailResize(kind)).then_some(*rect))
                .unwrap()
        };

        for kind in [RailKind::Machine, RailKind::Workspace] {
            let rect = divider(&app, kind);
            let target_x = rect.x + 3;
            let expected =
                rail_drag_width(&app.config, &app.sidebar_layout, kind, target_x).unwrap();
            app.handle_mouse(MouseEvent {
                kind: MouseEventKind::Down(MouseButton::Left),
                column: rect.x,
                row: rect.y + 1,
                modifiers: KeyModifiers::NONE,
            })
            .unwrap();
            app.handle_mouse(MouseEvent {
                kind: MouseEventKind::Drag(MouseButton::Left),
                column: target_x,
                row: rect.y + 1,
                modifiers: KeyModifiers::NONE,
            })
            .unwrap();
            app.handle_mouse(MouseEvent {
                kind: MouseEventKind::Up(MouseButton::Left),
                column: target_x,
                row: rect.y + 1,
                modifiers: KeyModifiers::NONE,
            })
            .unwrap();

            match kind {
                RailKind::Machine => {
                    assert_eq!(app.machine_sidebar_width_override, Some(expected));
                    assert_eq!(app.sidebar_width_override, None);
                }
                RailKind::Workspace => {
                    assert_eq!(app.sidebar_width_override, Some(expected));
                }
                RailKind::Tabs => unreachable!("tabs rail is not configured in this test"),
                RailKind::Projection(_) => {
                    unreachable!("projection rail is not configured in this test")
                }
            }
        }
    }

    #[test]
    fn mouse_wheel_scrolls_machine_and_workspace_rail_viewports_independently() {
        let mux = Mux::new("rail-wheel-test", SurfaceOptions::default());
        for index in 0..6 {
            mux.new_workspace(Some(format!("workspace-{index}")), None).unwrap();
        }
        let mut app = test_app(Session::Local(mux));
        app.sidebar_view = SidebarView::Workspaces;
        app.replace_tree(app.session.tree());
        let machines = (0..6)
            .map(|index| MachineDescriptor {
                key: MachineKey(index + 1),
                id: format!("machine-{index}"),
                name: format!("machine-{index}"),
                subtitle: "cloud".into(),
                status: MachineStatus::Running,
            })
            .collect();
        app.machine_ui = Some(MachineUiState::new(MachineSnapshot {
            machines,
            active: Some(MachineKey(1)),
            capabilities: MachineCapabilities { create: true, connect: true },
        }));
        app.sync_layout((100, 10));

        let mut terminal = Terminal::new(TestBackend::new(100, 10)).unwrap();
        terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
        let first_machine = app.hits.iter().find_map(|(_, hit)| match hit {
            super::Hit::Machine { key, .. } => Some(*key),
            _ => None,
        });
        let first_workspace = app.hits.iter().find_map(|(_, hit)| match hit {
            super::Hit::Workspace { id, .. } => Some(*id),
            _ => None,
        });
        let machine_area = app.sidebar_layout.machine.unwrap();
        let workspace_area = app.sidebar_layout.workspace.unwrap();

        app.focus = FocusTarget::MachineRail;
        app.handle_scroll(machine_area.x + 1, machine_area.y + 2, true, KeyModifiers::NONE)
            .unwrap();
        app.focus = FocusTarget::WorkspaceRail;
        app.handle_scroll(workspace_area.x + 1, workspace_area.y + 2, true, KeyModifiers::NONE)
            .unwrap();
        terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();

        let scrolled_machine = app.hits.iter().find_map(|(_, hit)| match hit {
            super::Hit::Machine { key, .. } => Some(*key),
            _ => None,
        });
        let scrolled_workspace = app.hits.iter().find_map(|(_, hit)| match hit {
            super::Hit::Workspace { id, .. } => Some(*id),
            _ => None,
        });
        assert_ne!(scrolled_machine, first_machine);
        assert_ne!(scrolled_workspace, first_workspace);
        assert!(app.machine_rail_scroll > 0);
        assert!(app.workspace_rail_scroll > 0);
    }

    #[test]
    fn workspace_rail_scrollbar_is_visible_clickable_and_draggable() {
        let mux = Mux::new("workspace-rail-scrollbar-test", SurfaceOptions::default());
        for index in 0..6 {
            mux.new_workspace(Some(format!("workspace-{index}")), None).unwrap();
        }
        let mut app = test_app(Session::Local(mux));
        app.sidebar_view = SidebarView::Workspaces;
        app.replace_tree(app.session.tree());
        app.sync_layout((80, 10));

        let mut terminal = Terminal::new(TestBackend::new(80, 10)).unwrap();
        terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
        let (track, total_rows, visible_rows) = app
            .hits
            .iter()
            .find_map(|(_, hit)| match hit {
                super::Hit::WorkspaceScrollbar { track, total_rows, visible_rows } => {
                    Some((*track, *total_rows, *visible_rows))
                }
                _ => None,
            })
            .unwrap();
        let divider = app
            .hits
            .iter()
            .find_map(|(rect, hit)| {
                (*hit == super::Hit::RailResize(RailKind::Workspace)).then_some(*rect)
            })
            .unwrap();
        let (thumb_y, _) = crate::ui::viewport_thumb_geometry(
            total_rows,
            visible_rows,
            app.workspace_rail_scroll,
            track.height,
        );
        assert_eq!(track.x + 1, divider.x);
        assert_eq!(terminal.backend().buffer()[(track.x, track.y + thumb_y)].symbol(), "▕");

        app.handle_mouse(MouseEvent {
            kind: MouseEventKind::Down(MouseButton::Left),
            column: track.x,
            row: track.y + track.height - 1,
            modifiers: KeyModifiers::NONE,
        })
        .unwrap();
        let jumped = app.workspace_rail_scroll;
        assert!(jumped > 0);
        assert!(!app.workspace_rail_follow_selection);
        assert_eq!(app.focus, FocusTarget::Pane);

        app.handle_mouse(MouseEvent {
            kind: MouseEventKind::Drag(MouseButton::Left),
            column: track.x,
            row: track.y,
            modifiers: KeyModifiers::NONE,
        })
        .unwrap();
        assert!(app.workspace_rail_scroll < jumped);
        app.handle_mouse(MouseEvent {
            kind: MouseEventKind::Up(MouseButton::Left),
            column: track.x,
            row: track.y,
            modifiers: KeyModifiers::NONE,
        })
        .unwrap();
    }

    #[test]
    fn workspace_rail_hides_scrollbar_when_every_row_fits() {
        let mux = Mux::new("workspace-rail-no-scrollbar-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.sidebar_view = SidebarView::Workspaces;
        app.replace_tree(app.session.tree());
        app.sync_layout((80, 30));

        let mut terminal = Terminal::new(TestBackend::new(80, 30)).unwrap();
        terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();

        assert!(
            !app.hits.iter().any(|(_, hit)| matches!(hit, super::Hit::WorkspaceScrollbar { .. }))
        );
        let divider = app
            .hits
            .iter()
            .find_map(|(rect, hit)| {
                (*hit == super::Hit::RailResize(RailKind::Workspace)).then_some(*rect)
            })
            .unwrap();
        let scrollbar_x = divider.x - 1;
        assert!(
            (1..29).all(|y| !matches!(
                terminal.backend().buffer()[(scrollbar_x, y)].symbol(),
                "▕" | "▐"
            ))
        );
    }

    #[test]
    fn tabs_column_renders_selected_workspace_tabs_and_activates_through_native_focus() {
        let (mux, first) = test_mux("tabs-column-test", None);
        let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let second = mux.new_tab(Some(pane), None, Some((80, 24))).unwrap();
        let mut app = test_app(Session::Local(mux.clone()));
        app.config.sidebar.columns_explicit = true;
        app.config.sidebar.columns = vec![
            crate::config::SidebarColumn {
                kind: SidebarColumnKind::Workspaces,
                width: 22,
                max_width: 0,
            },
            crate::config::SidebarColumn { kind: SidebarColumnKind::Tabs, width: 24, max_width: 0 },
        ];
        app.config.sidebar.views = app
            .config
            .sidebar
            .columns
            .iter()
            .map(|column| SidebarViewSpec::legacy(column.kind, column.width, column.max_width))
            .collect();
        app.config.sidebar.views_explicit = true;
        app.sidebar_view = SidebarView::Workspaces;
        app.replace_tree(app.session.tree());
        app.sync_layout((100, 20));

        let mut terminal = Terminal::new(TestBackend::new(100, 20)).unwrap();
        terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
        assert!(app.sidebar_layout.tabs.is_some());
        assert_eq!(app.sidebar_tab_targets().len(), 2);
        assert!(app.hits.iter().any(|(_, hit)| {
            matches!(hit, super::Hit::SidebarTab { surface, .. } if *surface == first.id)
        }));

        let first_row = app
            .hits
            .iter()
            .find_map(|(rect, hit)| {
                matches!(hit, super::Hit::SidebarTab { surface, .. } if *surface == first.id)
                    .then_some(*rect)
            })
            .unwrap();
        app.handle_left_down(first_row.x, first_row.y, KeyModifiers::NONE).unwrap();
        assert_eq!(app.tree.active_surface(), Some(first.id));
        assert_eq!(app.focus, FocusTarget::Pane);

        app.focus = FocusTarget::WorkspaceRail;
        app.handle_key(KeyEvent::new(KeyCode::Right, KeyModifiers::NONE)).unwrap();
        assert_eq!(app.focus, FocusTarget::TabsRail);
        app.tabs_rail_selection = 0;
        app.handle_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)).unwrap();
        assert_eq!(app.tree.active_surface(), Some(first.id));
        assert_eq!(app.focus, FocusTarget::Pane);

        for surface in [first.id, second.id] {
            mux.close_surface(surface).unwrap();
        }
    }

    #[test]
    fn projection_workspace_row_activates_on_mouse_down() {
        let mux = Mux::new("projection-workspace-mouse-down-test", SurfaceOptions::default());
        let first = mux.new_workspace(Some("Alpha".into()), Some((80, 24))).unwrap();
        let second = mux.new_workspace(Some("Beta".into()), Some((80, 24))).unwrap();
        let mut app = test_app(Session::Local(mux.clone()));
        app.config.sidebar.columns.clear();
        app.config.sidebar.views = vec![SidebarViewSpec {
            id: "workspace-agents".into(),
            levels: vec![SidebarResourceKind::Workspaces, SidebarResourceKind::Agents],
            actions: Vec::new(),
            actions_position: crate::config::ActionsPosition::Bottom,
            width: 40,
            max_width: 0,
            collapse_priority: 30,
        }];
        app.config.sidebar.views_explicit = true;
        app.replace_tree(app.session.tree());
        app.sync_layout((100, 20));

        let mut terminal = Terminal::new(TestBackend::new(100, 20)).unwrap();
        terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
        assert_eq!(app.tree.active_workspace, 1);
        let first_row = app
            .hits
            .iter()
            .find_map(|(rect, hit)| {
                matches!(
                    hit,
                    super::Hit::ProjectionRow {
                        target: crate::sidebar_projection::ProjectionTarget::Workspace {
                            index: 0,
                            ..
                        },
                        ..
                    }
                )
                .then_some(*rect)
            })
            .unwrap();

        app.handle_left_down(first_row.x, first_row.y, KeyModifiers::NONE).unwrap();

        assert_eq!(app.tree.active_workspace, 0);
        assert_eq!(app.focus, FocusTarget::Pane);

        for surface in [first.id, second.id] {
            mux.close_surface(surface).unwrap();
        }
    }

    #[test]
    fn projection_workspace_target_follows_id_after_tree_reorder() {
        let mux = Mux::new("projection-workspace-target-reorder-test", SurfaceOptions::default());
        let first = mux.new_workspace(Some("Alpha".into()), Some((80, 24))).unwrap();
        let second = mux.new_workspace(Some("Beta".into()), Some((80, 24))).unwrap();
        let mut app = test_app(Session::Local(mux.clone()));
        app.replace_tree(app.session.tree());

        let target = crate::sidebar_projection::ProjectionTarget::Workspace {
            index: 0,
            id: app.tree.workspaces()[0].id,
        };
        app.tree.workspaces_mut().swap(0, 1);
        app.activate_projection_target(target).unwrap();

        assert_eq!(app.tree.active_workspace, 1);
        assert_eq!(
            app.tree.active_workspace().map(|workspace| workspace.id),
            Some(target_id(target))
        );

        for surface in [first.id, second.id] {
            mux.close_surface(surface).unwrap();
        }
    }

    fn target_id(
        target: crate::sidebar_projection::ProjectionTarget,
    ) -> cmux_tui_core::WorkspaceId {
        match target {
            crate::sidebar_projection::ProjectionTarget::Workspace { id, .. } => id,
            _ => unreachable!("workspace target expected"),
        }
    }

    #[test]
    fn empty_projection_uses_its_leaf_resource_label() {
        let mux = Mux::new("projection-empty-leaf-label-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.config.sidebar.columns.clear();
        app.config.sidebar.views = vec![SidebarViewSpec {
            id: "workspace-tabs".into(),
            levels: vec![SidebarResourceKind::Workspaces, SidebarResourceKind::Tabs],
            actions: Vec::new(),
            actions_position: crate::config::ActionsPosition::Bottom,
            width: 40,
            max_width: 0,
            collapse_priority: 30,
        }];
        app.config.sidebar.views_explicit = true;
        app.sync_layout((100, 12));

        let mut terminal = Terminal::new(TestBackend::new(100, 12)).unwrap();
        terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
        let rendered = buffer_text(terminal.backend().buffer());

        assert!(rendered.contains("no tabs"), "{rendered}");
        assert!(!rendered.contains("no workspaces"), "{rendered}");
    }

    #[test]
    fn workspace_keyboard_enter_returns_focus_to_pane() {
        let mux = Mux::new("workspace-keyboard-enter-focus-test", SurfaceOptions::default());
        let first = mux.new_workspace(Some("Alpha".into()), Some((80, 24))).unwrap();
        let second = mux.new_workspace(Some("Beta".into()), Some((80, 24))).unwrap();
        let mut app = test_app(Session::Local(mux.clone()));
        app.sidebar_view = SidebarView::Workspaces;
        app.replace_tree(app.session.tree());
        app.sync_layout((100, 20));
        app.sidebar_workspace_selection = 0;
        app.workspace_rail_selection = WorkspaceRailSelection::Workspace;
        app.focus = FocusTarget::WorkspaceRail;

        app.handle_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)).unwrap();

        assert_eq!(app.focus, FocusTarget::Pane);

        for surface in [first.id, second.id] {
            mux.close_surface(surface).unwrap();
        }
    }

    #[test]
    fn projection_enter_on_active_surface_returns_focus_to_pane() {
        let (mux, surface) = test_mux("projection-active-surface-enter-test", None);
        mux.report_agent(
            surface.id,
            AgentState::Working,
            AgentSource::Hook,
            Some("agent-session".into()),
        )
        .unwrap();
        let mut app = test_app(Session::Local(mux.clone()));
        app.config.sidebar.columns.clear();
        app.config.sidebar.views = vec![SidebarViewSpec {
            id: "workspace-agents".into(),
            levels: vec![SidebarResourceKind::Workspaces, SidebarResourceKind::Agents],
            actions: Vec::new(),
            actions_position: crate::config::ActionsPosition::Bottom,
            width: 40,
            max_width: 0,
            collapse_priority: 30,
        }];
        app.config.sidebar.views_explicit = true;
        app.replace_tree(app.session.tree());
        app.sync_layout((100, 20));
        app.projection_rail_state_mut(0).selected = 1;
        app.focus = FocusTarget::ProjectionRail(0);

        app.handle_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)).unwrap();

        assert_eq!(app.tree.active_surface(), Some(surface.id));
        assert_eq!(app.focus, FocusTarget::Pane);

        mux.close_surface(surface.id).unwrap();
    }

    #[test]
    fn projection_stale_action_selection_does_not_retarget_resource_row() {
        let (mux, surface) = test_mux("projection-stale-action-selection-test", None);
        mux.report_agent(
            surface.id,
            AgentState::Working,
            AgentSource::Hook,
            Some("agent-session".into()),
        )
        .unwrap();
        let mut app = test_app(Session::Local(mux.clone()));
        app.config.sidebar.columns.clear();
        app.config.sidebar.views = vec![SidebarViewSpec {
            id: "workspace-agents".into(),
            levels: vec![SidebarResourceKind::Workspaces, SidebarResourceKind::Agents],
            actions: Vec::new(),
            actions_position: crate::config::ActionsPosition::Bottom,
            width: 40,
            max_width: 0,
            collapse_priority: 30,
        }];
        app.config.sidebar.views_explicit = true;
        app.replace_tree(app.session.tree());
        let state = app.projection_rail_state_mut(0);
        state.selected = 0;
        state.selected_action = Some(99);
        app.focus = FocusTarget::ProjectionRail(0);

        app.handle_key(KeyEvent::new(KeyCode::Left, KeyModifiers::NONE)).unwrap();

        assert!(
            app.projection_rail_state_mut(0).collapsed.is_empty(),
            "stale action selection must not collapse the selected resource row"
        );

        mux.close_surface(surface.id).unwrap();
    }

    #[test]
    fn projection_agent_rows_hide_finished_reports() {
        let (mux, surface) = test_mux("projection-finished-agent-test", None);
        mux.report_agent(
            surface.id,
            AgentState::Done,
            AgentSource::Hook,
            Some("agent-session".into()),
        )
        .unwrap();
        let mut app = test_app(Session::Local(mux.clone()));
        app.config.sidebar.columns.clear();
        app.config.sidebar.views = vec![SidebarViewSpec {
            id: "agents".into(),
            levels: vec![SidebarResourceKind::Agents],
            actions: Vec::new(),
            actions_position: crate::config::ActionsPosition::Bottom,
            width: 40,
            max_width: 0,
            collapse_priority: 30,
        }];
        app.config.sidebar.views_explicit = true;
        app.replace_tree(app.session.tree());

        assert!(
            app.projection_rows(0).is_empty(),
            "finished reports must not leave stale agent rows"
        );

        mux.close_surface(surface.id).unwrap();
    }

    #[test]
    fn tabs_column_context_menu_renames_the_exact_clicked_tab() {
        let (mux, first) = test_mux("tabs-column-rename-test", None);
        let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let second = mux.new_tab(Some(pane), None, Some((80, 24))).unwrap();
        let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
        app.config.sidebar.columns_explicit = true;
        app.config.sidebar.columns = vec![
            crate::config::SidebarColumn {
                kind: SidebarColumnKind::Workspaces,
                width: 22,
                max_width: 0,
            },
            crate::config::SidebarColumn { kind: SidebarColumnKind::Tabs, width: 24, max_width: 0 },
        ];
        app.config.sidebar.views = app
            .config
            .sidebar
            .columns
            .iter()
            .map(|column| SidebarViewSpec::legacy(column.kind, column.width, column.max_width))
            .collect();
        app.config.sidebar.views_explicit = true;
        app.sidebar_view = SidebarView::Workspaces;
        app.replace_tree(app.session.tree());
        app.sync_layout((100, 20));

        let mut terminal = Terminal::new(TestBackend::new(100, 20)).unwrap();
        terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
        assert_eq!(app.tree.active_surface(), Some(second.id));
        let clicked = app
            .hits
            .iter()
            .find_map(|(rect, hit)| {
                matches!(hit, super::Hit::SidebarTab { surface, .. } if *surface == first.id)
                    .then_some(*rect)
            })
            .unwrap();

        app.open_context_menu(clicked.x, clicked.y);
        assert!(
            app.menu.as_ref().unwrap().levels[0]
                .items
                .iter()
                .any(|item| item.action() == Some(MenuAction::RenameSurface(first.id)))
        );
        app.activate_menu(MenuAction::RenameSurface(first.id)).unwrap();
        assert_eq!(
            app.prompt.as_ref().map(|prompt| prompt.target),
            Some(PromptTarget::Surface(first.id))
        );
        app.prompt.as_mut().unwrap().input.insert_str("first renamed");
        app.commit_prompt();
        while app.session.has_pending_mutations() {
            app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
        }

        let tree = app.session.tree();
        let renamed = tree
            .workspaces()
            .iter()
            .flat_map(|workspace| workspace.screens.iter())
            .flat_map(|screen| screen.panes.iter())
            .flat_map(|pane| pane.tabs.iter())
            .find(|tab| tab.surface == first.id)
            .and_then(|tab| tab.name.as_deref());
        assert_eq!(renamed, Some("first renamed"));
        assert_eq!(mux.active_surface(), Some(second.id));
    }

    #[test]
    fn pane_tab_context_menu_renames_the_exact_inactive_tab() {
        let (mux, first) = test_mux("pane-tab-rename-test", None);
        let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let second = mux.new_tab(Some(pane), None, Some((80, 24))).unwrap();
        let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
        app.sidebar_visible = false;
        app.replace_tree(app.session.tree());
        app.sync_layout((100, 20));

        let mut terminal = Terminal::new(TestBackend::new(100, 20)).unwrap();
        terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
        assert_eq!(app.tree.active_surface(), Some(second.id));
        let clicked = app
            .hits
            .iter()
            .find_map(|(rect, hit)| {
                matches!(hit, super::Hit::Tab { pane: hit_pane, index: 0 } if *hit_pane == pane)
                    .then_some(*rect)
            })
            .unwrap();

        app.open_context_menu(clicked.x, clicked.y);
        assert!(
            app.menu.as_ref().unwrap().levels[0]
                .items
                .iter()
                .any(|item| item.action() == Some(MenuAction::RenameSurface(first.id)))
        );
        app.activate_menu(MenuAction::RenameSurface(first.id)).unwrap();
        app.prompt.as_mut().unwrap().input.insert_str("inactive renamed");
        app.commit_prompt();
        while app.session.has_pending_mutations() {
            app.handle(events.recv_timeout(crate::test_wait::EVENT).unwrap()).unwrap();
        }

        let tree = app.session.tree();
        let renamed = tree
            .workspaces()
            .iter()
            .flat_map(|workspace| workspace.screens.iter())
            .flat_map(|screen| screen.panes.iter())
            .flat_map(|pane| pane.tabs.iter())
            .find(|tab| tab.surface == first.id)
            .and_then(|tab| tab.name.as_deref());
        assert_eq!(renamed, Some("inactive renamed"));
        assert_eq!(mux.active_surface(), Some(second.id));
    }

    #[test]
    fn workspace_agent_tree_renders_collapses_and_renames_the_exact_surface() {
        let (mux, surface) = test_mux("workspace-agent-tree-test", None);
        mux.report_agent(
            surface.id,
            AgentState::Working,
            AgentSource::Hook,
            Some("agent-session".into()),
        )
        .unwrap();
        let mut app = test_app(Session::Local(mux.clone()));
        app.config.sidebar.columns.clear();
        app.config.sidebar.views = vec![SidebarViewSpec {
            id: "workspace-agents".into(),
            levels: vec![SidebarResourceKind::Workspaces, SidebarResourceKind::Agents],
            actions: vec![crate::config::SidebarActionSpec::plain(Action::NewWorkspace)],
            actions_position: crate::config::ActionsPosition::Bottom,
            width: 40,
            max_width: 0,
            collapse_priority: 30,
        }];
        app.config.sidebar.views_explicit = true;
        app.replace_tree(app.session.tree());
        app.sync_layout((100, 20));

        let mut terminal = Terminal::new(TestBackend::new(100, 20)).unwrap();
        terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
        let rendered = buffer_text(terminal.backend().buffer());
        assert!(rendered.contains("working · agent-session"), "{rendered}");
        assert!(
            rendered.contains("+ new workspace"),
            "a configured workspace representation must preserve its native creation action: {rendered}"
        );
        assert!(app.hits.iter().any(|(_, hit)| matches!(
            hit,
            super::Hit::SidebarAction {
                view: 0,
                action: SidebarActionTarget::CreateWorkspace(None),
            }
        )));
        let surface_row = app
            .hits
            .iter()
            .find_map(|(rect, hit)| {
                matches!(
                    hit,
                    super::Hit::ProjectionRow {
                        target: crate::sidebar_projection::ProjectionTarget::Surface {
                            surface: hit_surface,
                            ..
                        },
                        ..
                    } if *hit_surface == surface.id
                )
                .then_some(*rect)
            })
            .unwrap();
        app.open_context_menu(surface_row.x, surface_row.y);
        assert!(
            app.menu.as_ref().unwrap().levels[0]
                .items
                .iter()
                .any(|item| item.action() == Some(MenuAction::RenameSurface(surface.id)))
        );

        app.menu = None;
        let disclosure = app
            .hits
            .iter()
            .find_map(|(rect, hit)| {
                matches!(
                    hit,
                    super::Hit::ProjectionToggle {
                        branch: crate::sidebar_projection::ProjectionBranch::Workspace(_),
                        ..
                    }
                )
                .then_some(*rect)
            })
            .unwrap();
        app.handle_left_down(disclosure.x, disclosure.y, KeyModifiers::NONE).unwrap();
        terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
        assert_eq!(app.focus, FocusTarget::Pane);
        assert!(!app.hits.iter().any(|(_, hit)| matches!(
            hit,
            super::Hit::ProjectionRow {
                target: crate::sidebar_projection::ProjectionTarget::Surface {
                    surface: hit_surface,
                    ..
                },
                ..
            } if *hit_surface == surface.id
        )));

        let area = app.sidebar_layout.rail(RailKind::Projection(0)).unwrap();
        app.handle_left_down(area.x + 1, area.y + 10, KeyModifiers::NONE).unwrap();
        assert_eq!(app.focus, FocusTarget::Pane);
        app.handle_left_down(area.x + 1, area.y, KeyModifiers::NONE).unwrap();
        assert_eq!(app.focus, FocusTarget::ProjectionRail(0));
        app.handle_key(KeyEvent::new(KeyCode::Right, KeyModifiers::ALT)).unwrap();
        assert_eq!(app.focus, FocusTarget::Pane);

        mux.close_surface(surface.id).unwrap();
    }

    #[test]
    fn workspace_projection_actions_expand_provider_capabilities_and_can_be_hidden() {
        let mux = Mux::new("workspace-projection-action-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.machine_ui = Some(provider_machine_ui());
        app.config.sidebar.columns.clear();
        app.config.sidebar.views = vec![SidebarViewSpec {
            id: "workspace-agents".into(),
            levels: vec![SidebarResourceKind::Workspaces, SidebarResourceKind::Agents],
            actions: vec![crate::config::SidebarActionSpec::plain(Action::NewWorkspace)],
            actions_position: crate::config::ActionsPosition::Bottom,
            width: 40,
            max_width: 0,
            collapse_priority: 30,
        }];
        app.config.sidebar.views_explicit = true;
        app.sync_layout((100, 12));

        let mut terminal = Terminal::new(TestBackend::new(100, 12)).unwrap();
        terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
        let rendered = buffer_text(terminal.backend().buffer());
        assert!(rendered.contains("new isolated"), "{rendered}");
        assert!(rendered.contains("new shared"), "{rendered}");
        let isolated = app
            .hits
            .iter()
            .find_map(|(rect, hit)| {
                matches!(
                    hit,
                    super::Hit::SidebarAction {
                        action: SidebarActionTarget::CreateWorkspace(Some(
                            WorkspaceCreationMode::Isolated
                        )),
                        ..
                    }
                )
                .then_some(*rect)
            })
            .expect("isolated action hit");

        app.handle_left_down(isolated.x, isolated.y, KeyModifiers::NONE).unwrap();
        assert_eq!(app.focus, FocusTarget::Pane);
        assert_eq!(
            app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
            Some(&MachineRequest::CreateManagedIsolatedWorkspace(MachineKey(41)))
        );

        app.machine_ui.as_mut().unwrap().request = None;
        app.focus = FocusTarget::ProjectionRail(0);
        app.handle_key(KeyEvent::new(KeyCode::End, KeyModifiers::NONE)).unwrap();
        app.handle_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)).unwrap();
        assert_eq!(
            app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
            Some(&MachineRequest::CreateManagedHostWorkspace(MachineKey(41)))
        );

        app.config.sidebar.views[0].actions.clear();
        terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
        let rendered = buffer_text(terminal.backend().buffer());
        assert!(!rendered.contains("new isolated"), "{rendered}");
        assert!(!rendered.contains("new shared"), "{rendered}");
        assert!(!app.hits.iter().any(|(_, hit)| matches!(hit, super::Hit::SidebarAction { .. })));
    }

    #[test]
    fn client_machine_context_menu_renames_without_provider_mutation() {
        let mux = Mux::new("client-machine-rename-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        let key = MachineKey(7);
        let mut ui = MachineUiState::new(MachineSnapshot {
            machines: vec![MachineDescriptor {
                key,
                id: "current".into(),
                name: "Build host".into(),
                subtitle: "local".into(),
                status: MachineStatus::Running,
            }],
            active: Some(key),
            capabilities: MachineCapabilities { create: false, connect: true },
        });
        ui.set_client_renamable_machines([key]);
        app.machine_ui = Some(ui);
        app.sync_layout((100, 14));
        let mut terminal = Terminal::new(TestBackend::new(100, 14)).unwrap();
        terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
        let clicked = app
            .hits
            .iter()
            .find_map(|(rect, hit)| {
                matches!(hit, super::Hit::Machine { key: hit_key, .. } if *hit_key == key)
                    .then_some(*rect)
            })
            .unwrap();

        app.open_context_menu(clicked.x, clicked.y);
        assert!(
            app.menu.as_ref().unwrap().levels[0]
                .items
                .iter()
                .any(|item| item.action() == Some(MenuAction::RenameClientMachine(key)))
        );
        app.activate_menu(MenuAction::RenameClientMachine(key)).unwrap();
        assert_eq!(
            app.prompt.as_ref().map(|prompt| prompt.target),
            Some(PromptTarget::ClientMachine(key))
        );
        app.prompt.as_mut().unwrap().input.clear();
        app.prompt.as_mut().unwrap().input.insert_str("Renamed host");
        app.commit_prompt();
        assert_eq!(
            app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
            Some(&MachineRequest::RenameClientMachine {
                machine: key,
                name: "Renamed host".into(),
            })
        );
    }

    #[test]
    fn ssh_config_connection_menu_binds_the_selected_alias() {
        let mux = Mux::new("ssh-config-picker-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        let mut ui = MachineUiState::new(MachineSnapshot {
            machines: Vec::new(),
            active: None,
            capabilities: MachineCapabilities { create: false, connect: true },
        });
        ui.connection_targets = vec![
            MachineConnectionTarget { target: "buildbox".into(), name: "buildbox".into() },
            MachineConnectionTarget { target: "mini".into(), name: "mini".into() },
        ];
        app.machine_ui = Some(ui);

        app.open_machine_connection_menu(1, 3);
        let items = &app.menu.as_ref().unwrap().levels[0].items;
        assert_eq!(items[0].label(), Some("Add SSH host…"));
        assert_eq!(items[1], MenuItem::Separator);
        assert_eq!(items[2].label(), Some("buildbox"));
        assert_eq!(items.last().and_then(MenuItem::label), Some("mini"));
        assert_eq!(
            app.menu
                .as_ref()
                .and_then(|menu| menu.search.as_ref())
                .map(|search| search.label.as_str()),
            Some("SSH hosts")
        );
        assert!(matches!(
            app.menu
                .as_ref()
                .and_then(|menu| menu.captured_resource(MenuAction::ConnectMachineTarget(0))),
            Some(Some(super::MenuActionResource::MachineConnectionTarget(target)))
                if target == "buildbox"
        ));
        for character in "mini".chars() {
            app.handle_key(KeyEvent::new(KeyCode::Char(character), KeyModifiers::NONE)).unwrap();
        }
        let items = &app.menu.as_ref().unwrap().levels[0].items;
        assert_eq!(items[0].label(), Some("Add SSH host…"));
        assert_eq!(items[1], MenuItem::Separator);
        assert_eq!(items[2].label(), Some("mini"));
        app.handle_menu_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)).unwrap();
        assert_eq!(
            app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
            Some(&MachineRequest::Connect {
                target: "mini".into(),
                route: MachineConnectRoute::Local,
            })
        );

        app.machine_ui.as_mut().unwrap().request = None;
        app.activate_menu(MenuAction::ConnectOtherMachine).unwrap();
        assert_eq!(
            app.prompt.as_ref().map(|prompt| prompt.target),
            Some(PromptTarget::ConnectMachine(MachineConnectRoute::Local))
        );
    }

    #[test]
    fn catalog_refresh_preserves_machine_and_workspace_selection_identity_and_scroll() {
        let descriptor = |key| MachineDescriptor {
            key: MachineKey(key),
            id: key.to_string(),
            name: format!("machine-{key}"),
            subtitle: "cloud".into(),
            status: MachineStatus::Running,
        };
        let mux = Mux::new("rail-refresh-test", SurfaceOptions::default());
        mux.new_workspace(Some("first".into()), None).unwrap();
        mux.new_workspace(Some("second".into()), None).unwrap();
        let mut app = test_app(Session::Local(mux));
        app.replace_tree(app.session.tree());
        app.sidebar_workspace_selection = 1;
        app.workspace_rail_scroll = 3;
        let selected_workspace = app.tree.workspaces()[1].id;
        let mut initial = MachineUiState::new(MachineSnapshot {
            machines: vec![descriptor(1), descriptor(2), descriptor(3)],
            active: Some(MachineKey(1)),
            capabilities: MachineCapabilities::default(),
        });
        initial.select_rail_target(crate::machine::MachineRailTarget::Machine(MachineKey(2)));
        app.machine_ui = Some(initial);
        app.machine_rail_scroll = 6;

        let update = MachineUiState::new(MachineSnapshot {
            machines: vec![descriptor(3), descriptor(2), descriptor(1)],
            active: Some(MachineKey(1)),
            capabilities: MachineCapabilities::default(),
        });
        app.apply_machine_ui_update(update);
        let mut reordered = app.tree.clone();
        reordered.workspaces_mut().swap(0, 1);
        app.replace_tree(reordered);

        assert_eq!(
            app.machine_ui.as_ref().and_then(MachineUiState::rail_target),
            Some(crate::machine::MachineRailTarget::Machine(MachineKey(2)))
        );
        assert_eq!(app.machine_rail_scroll, 6);
        assert_eq!(app.tree.workspaces()[app.sidebar_workspace_selection].id, selected_workspace);
        assert_eq!(app.workspace_rail_scroll, 3);
    }

    enum FakeMachineAction {
        Return(Box<MachineActionResult>),
        Fail(&'static str),
    }

    struct FakeMachineController {
        actions: VecDeque<FakeMachineAction>,
        requests: Arc<Mutex<Vec<MachineRequest>>>,
    }

    impl MachineController for FakeMachineController {
        fn perform(&mut self, request: MachineRequest) -> anyhow::Result<MachineActionResult> {
            self.requests.lock().unwrap().push(request);
            match self.actions.pop_front().expect("fake machine action") {
                FakeMachineAction::Return(result) => Ok(*result),
                FakeMachineAction::Fail(message) => anyhow::bail!(message),
            }
        }
    }

    fn fake_controller(
        action: FakeMachineAction,
    ) -> (Box<dyn MachineController>, Arc<Mutex<Vec<MachineRequest>>>) {
        let requests = Arc::new(Mutex::new(Vec::new()));
        (
            Box::new(FakeMachineController {
                actions: VecDeque::from([action]),
                requests: requests.clone(),
            }),
            requests,
        )
    }

    fn durable_notice(id: &str, sequence: u64, message: &str) -> DurableProviderNotice {
        DurableProviderNotice {
            delivery: DurableNoticeDelivery { notice_id: id.into(), sequence },
            level: DurableNoticeLevel::Warning,
            message: message.into(),
        }
    }

    fn install_machine_controller(app: &mut App, controller: Box<dyn MachineController>) {
        app.machine_action_worker =
            Some(MachineActionWorker::spawn(controller, app.app_events.clone()).unwrap());
    }

    fn unused_machine_preparation() -> super::MachineSessionPreparation {
        let dispatcher = PtyInputDispatcher::spawn(|_| {}).unwrap();
        super::MachineSessionPreparation {
            initial_size: None,
            generation: 2,
            pty_input: dispatcher.sender(),
            surface_filter: None,
        }
    }

    fn pending_machine_replacement(
        app: &App,
        action_id: u64,
        label: &str,
    ) -> super::PendingMachineReplacement {
        let mux = Mux::new(label, SurfaceOptions::default());
        let dispatcher = PtyInputDispatcher::spawn(|_| {}).unwrap();
        let generation = app.session_generation.wrapping_add(1).max(1);
        let (session, event_worker, mux_titles, mux_recovery_generation) = prepare_ordered_session(
            Session::Local(mux),
            dispatcher.sender(),
            app.app_events.clone(),
            generation,
            None,
        )
        .unwrap();
        let tree = session.tree();
        super::PendingMachineReplacement {
            action_id,
            present: true,
            action: super::PreparedMachineAction {
                ui: provider_machine_ui(),
                session_mutation: None,
                session_label: None,
                session: super::PreparedMachineSession {
                    session,
                    event_worker,
                    generation,
                    mux_titles,
                    mux_recovery_generation,
                    tree,
                    label: label.into(),
                    session_available: true,
                    machine: None,
                },
            },
        }
    }

    fn settle_machine_action(app: &mut App, events: &Receiver<AppEvent>) -> RenderAction {
        let mut action = app.process_machine_requests();
        while app.machine_action_in_flight {
            let event = events.recv_timeout(crate::test_wait::EVENT).unwrap();
            action = action.merge(app.handle(event).unwrap());
        }
        action
    }

    struct BlockingMachineController {
        release: StdReceiver<()>,
    }

    impl MachineController for BlockingMachineController {
        fn perform(&mut self, _request: MachineRequest) -> anyhow::Result<MachineActionResult> {
            self.release.recv().expect("release blocked machine action");
            Ok(MachineActionResult::ui(provider_machine_ui()))
        }
    }

    struct AckMachineController {
        acknowledgements: std::sync::mpsc::Sender<DurableNoticeDelivery>,
        fail: bool,
    }

    impl MachineController for AckMachineController {
        fn perform(&mut self, _request: MachineRequest) -> anyhow::Result<MachineActionResult> {
            unreachable!("ack controller does not perform machine actions")
        }

        fn acknowledge_durable_notice(
            &mut self,
            delivery: &DurableNoticeDelivery,
        ) -> anyhow::Result<()> {
            self.acknowledgements.send(delivery.clone()).unwrap();
            if self.fail {
                anyhow::bail!("ack failed");
            }
            Ok(())
        }
    }

    #[test]
    fn machine_worker_preserves_exact_durable_notice_ack_result() {
        for fail in [false, true] {
            let (events, event_receiver) = crossbeam_channel::bounded(4);
            let (acknowledgements, acknowledged) = std::sync::mpsc::channel();
            let mut worker = MachineActionWorker::spawn(
                Box::new(AckMachineController { acknowledgements, fail }),
                events,
            )
            .unwrap();
            let delivery =
                DurableNoticeDelivery { notice_id: format!("notice-{fail}"), sequence: 41 };

            worker.acknowledge_durable_notice(delivery.clone()).unwrap();

            assert_eq!(acknowledged.recv_timeout(Duration::from_secs(1)).unwrap(), delivery);
            let AppEvent::MachineControllerCompleted(completion) =
                event_receiver.recv_timeout(Duration::from_secs(1)).unwrap()
            else {
                panic!("expected durable notice acknowledgement completion");
            };
            match *completion {
                super::MachineControllerCompletion::DurableNoticeAcknowledged {
                    delivery: completed,
                    result,
                } => {
                    assert_eq!(completed, delivery);
                    assert_eq!(result.is_err(), fail);
                }
                _ => panic!("expected durable notice acknowledgement completion"),
            }
            worker.shutdown();
        }
    }

    #[test]
    fn durable_notice_ack_waits_for_machine_action_settlement() {
        let mux = Mux::new("durable-ack-action-order", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        let (acknowledgements, acknowledged) = std::sync::mpsc::channel();
        install_machine_controller(
            &mut app,
            Box::new(AckMachineController { acknowledgements, fail: false }),
        );
        let delivery =
            DurableNoticeDelivery { notice_id: "usage-during-switch".into(), sequence: 42 };
        app.queue_durable_notice_ack(delivery.clone());
        app.machine_action_in_flight = true;

        app.submit_pending_durable_notice_ack();

        assert!(app.durable_notice_ack_in_flight.is_none());
        assert_eq!(app.pending_durable_notice_acks.front(), Some(&delivery));
        assert_eq!(
            acknowledged.recv_timeout(Duration::from_millis(20)),
            Err(std::sync::mpsc::RecvTimeoutError::Timeout)
        );

        app.machine_action_in_flight = false;
        app.submit_pending_durable_notice_ack();
        assert_eq!(acknowledged.recv_timeout(Duration::from_secs(1)).unwrap(), delivery);
        app.shutdown_background_workers();
    }

    struct OrderedBlockingMachineController {
        started: std::sync::mpsc::Sender<MachineKey>,
        release: StdReceiver<()>,
        closed: Option<std::sync::mpsc::Sender<()>>,
    }

    impl MachineController for OrderedBlockingMachineController {
        fn perform(&mut self, request: MachineRequest) -> anyhow::Result<MachineActionResult> {
            let MachineRequest::Switch(machine) = request else {
                panic!("ordered fake received a non-switch request");
            };
            self.started.send(machine).unwrap();
            self.release.recv().expect("release ordered machine action");
            Ok(MachineActionResult::ui(provider_machine_ui()))
        }

        fn close(&mut self) {
            if let Some(closed) = self.closed.take() {
                let _ = closed.send(());
            }
        }
    }

    #[test]
    fn blocked_machine_action_does_not_block_the_app_event_loop() {
        let mux = Mux::new("machine-action-responsive", SurfaceOptions::default());
        let (mut app, _events) = test_app_with_events(Session::Local(mux));
        app.machine_ui = Some(provider_machine_ui());
        let (release, blocked) = std::sync::mpsc::channel();
        install_machine_controller(
            &mut app,
            Box::new(BlockingMachineController { release: blocked }),
        );
        app.machine_ui.as_mut().unwrap().request = Some(MachineRequest::Switch(MachineKey(41)));
        let releaser = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(200));
            release.send(()).unwrap();
        });

        let started = Instant::now();
        let action = app.process_machine_requests();

        assert!(started.elapsed() < Duration::from_millis(50));
        assert_eq!(action, RenderAction::None);
        releaser.join().unwrap();
    }

    #[test]
    fn machine_action_worker_serializes_requests_in_submission_order() {
        let (events, event_receiver) = crossbeam_channel::bounded(4);
        let (started, starts) = std::sync::mpsc::channel();
        let (release, releases) = std::sync::mpsc::channel();
        let mut worker = MachineActionWorker::spawn(
            Box::new(OrderedBlockingMachineController { started, release: releases, closed: None }),
            events,
        )
        .unwrap();

        worker
            .perform(MachineRequest::Switch(MachineKey(1)), unused_machine_preparation())
            .unwrap();

        assert_eq!(starts.recv_timeout(Duration::from_secs(1)).unwrap(), MachineKey(1));
        worker
            .perform(MachineRequest::Switch(MachineKey(2)), unused_machine_preparation())
            .unwrap();
        assert!(matches!(
            worker.perform(MachineRequest::Switch(MachineKey(3)), unused_machine_preparation()),
            Err(super::MachineSubmitError::Busy(MachineRequest::Switch(MachineKey(3))))
        ));
        assert!(starts.try_recv().is_err(), "second action started before the first completed");
        release.send(()).unwrap();
        assert!(matches!(
            event_receiver.recv_timeout(Duration::from_secs(1)).unwrap(),
            AppEvent::MachineControllerCompleted(_)
        ));
        assert_eq!(starts.recv_timeout(Duration::from_secs(1)).unwrap(), MachineKey(2));
        release.send(()).unwrap();
        assert!(matches!(
            event_receiver.recv_timeout(Duration::from_secs(1)).unwrap(),
            AppEvent::MachineControllerCompleted(_)
        ));
        assert!(
            starts.try_recv().is_err(),
            "rejected stale action replayed after the queue drained"
        );
        worker.shutdown();
    }

    #[test]
    fn machine_action_worker_shutdown_never_joins_a_blocked_action() {
        let (events, _event_receiver) = crossbeam_channel::bounded(4);
        let (started, starts) = std::sync::mpsc::channel();
        let (release, releases) = std::sync::mpsc::channel();
        let (closed, closes) = std::sync::mpsc::channel();
        let mut worker = MachineActionWorker::spawn(
            Box::new(OrderedBlockingMachineController {
                started,
                release: releases,
                closed: Some(closed),
            }),
            events,
        )
        .unwrap();
        worker
            .perform(MachineRequest::Switch(MachineKey(1)), unused_machine_preparation())
            .unwrap();
        assert_eq!(starts.recv_timeout(Duration::from_secs(1)).unwrap(), MachineKey(1));

        let started_shutdown = Instant::now();
        worker.shutdown();

        assert!(started_shutdown.elapsed() < Duration::from_millis(50));
        release.send(()).unwrap();
        closes.recv_timeout(Duration::from_secs(1)).unwrap();
    }

    #[test]
    fn canceling_machine_controller_completion_send_unblocks_when_queue_is_full() {
        let (events, receiver) = crossbeam_channel::bounded(1);
        events.send(AppEvent::Mux(MuxEvent::Empty)).unwrap();
        let cancellation = EventCancellation::new();
        let worker_cancellation = cancellation.clone();
        let (started_tx, started_rx) = std::sync::mpsc::sync_channel(1);
        let (completed_tx, completed_rx) = std::sync::mpsc::sync_channel(1);
        let worker = std::thread::spawn(move || {
            started_tx.send(()).unwrap();
            let completed = super::send_machine_controller_completion(
                &events,
                super::MachineControllerCompletion::Updates(Err("cancelled".into())),
                &worker_cancellation,
            );
            completed_tx.send(completed).unwrap();
        });

        started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(matches!(
            completed_rx.recv_timeout(Duration::from_millis(50)),
            Err(std::sync::mpsc::RecvTimeoutError::Timeout)
        ));
        cancellation.cancel();
        assert!(!completed_rx.recv_timeout(Duration::from_secs(1)).unwrap());
        worker.join().unwrap();
        drop(receiver);
    }

    #[test]
    fn in_place_machine_switch_preserves_rail_view_focus_and_widths() {
        let first = Mux::new("machine-switch-first", SurfaceOptions::default());
        first.new_workspace(None, None).unwrap();
        let second = Mux::new("machine-switch-second", SurfaceOptions::default());
        let (mut app, events) = test_app_with_events(Session::Local(first));
        app.replace_tree(app.session.tree());
        app.machine_ui = Some(provider_machine_ui());
        app.sidebar_view = SidebarView::Workspaces;
        app.focus = FocusTarget::MachineRail;
        app.sidebar_width_override = Some(27);
        app.machine_sidebar_width_override = Some(19);
        app.machine_rail_scroll = 3;
        app.workspace_rail_scroll = 6;

        let next_ui = provider_machine_ui();
        let (controller, requests) = fake_controller(FakeMachineAction::Return(Box::new(
            MachineActionResult::replace(next_ui, Session::Local(second), "second".into()),
        )));
        install_machine_controller(&mut app, controller);
        app.machine_ui.as_mut().unwrap().request = Some(MachineRequest::Switch(MachineKey(41)));

        assert!(matches!(settle_machine_action(&mut app, &events), RenderAction::Draw));
        assert_eq!(app.session_generation, 2);
        assert_eq!(app.session_label, "second");
        assert_eq!(app.sidebar_view, SidebarView::Workspaces);
        assert_eq!(app.focus, FocusTarget::MachineRail);
        assert_eq!(app.sidebar_width_override, Some(27));
        assert_eq!(app.machine_sidebar_width_override, Some(19));
        assert_eq!(app.machine_rail_scroll, 3);
        assert_eq!(app.workspace_rail_scroll, 6);
        assert!(!app.quit);
        assert_eq!(requests.lock().unwrap().as_slice(), &[MachineRequest::Switch(MachineKey(41))]);
    }

    #[test]
    fn closing_connection_dialog_prevents_an_active_connect_from_replacing_the_session() {
        let first = Mux::new("connection-dialog-active-cancel-first", SurfaceOptions::default());
        first.new_workspace(None, None).unwrap();
        let second = Mux::new("connection-dialog-active-cancel-second", SurfaceOptions::default());
        second.new_workspace(None, None).unwrap();
        let (mut app, events) = test_app_with_events(Session::Local(first));
        app.replace_tree(app.session.tree());
        app.machine_ui = Some(provider_machine_ui());
        let (controller, requests) =
            fake_controller(FakeMachineAction::Return(Box::new(MachineActionResult::replace(
                provider_machine_ui(),
                Session::Local(second),
                "second".into(),
            ))));
        install_machine_controller(&mut app, controller);
        app.begin_machine_connection("mini.local".into(), MachineConnectRoute::Local);
        let request = MachineRequest::Connect {
            target: "mini.local".into(),
            route: MachineConnectRoute::Local,
        };

        assert_eq!(app.process_machine_requests(), RenderAction::None);
        assert!(app.machine_action_in_flight);
        app.close_prompt();
        assert!(matches!(settle_machine_action(&mut app, &events), RenderAction::Draw));

        assert_eq!(app.session_generation, 1);
        assert_eq!(app.session_label, "test");
        assert!(app.prompt.is_none());
        assert!(app.connection_transaction.is_none());
        assert!(app.canceled_machine_connection_attempt.is_none());
        assert_eq!(requests.lock().unwrap().as_slice(), &[request]);
    }

    #[test]
    fn machine_session_replacement_settles_pointer_capture_on_the_old_session() {
        let first = Mux::new("machine-pointer-reset-first", SurfaceOptions::default());
        first.new_workspace(None, None).unwrap();
        let second = Mux::new("machine-pointer-reset-second", SurfaceOptions::default());
        let (mut app, _events) = test_app_with_events(Session::Local(first));
        let (started_tx, started_rx) = std::sync::mpsc::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        app.session.operations.enqueue_session_mutation(
            "block old session before pointer settlement",
            false,
            move || {
                started_tx.send(()).unwrap();
                release_rx.recv().unwrap();
                Ok(())
            },
        );
        started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        app.drag = Some(Drag::ResizeSplit {
            horizontal: Some(PaneResizeDragTarget::ViewportColumn {
                pane: 1,
                edge: PaneEdge::Right,
                column_x: 0,
                viewport_x: 0,
                viewport_width: 1,
                viewport_offset: 0,
            }),
            vertical: None,
        });
        app.active_pointer_buttons.insert(MouseButton::Left);
        let old_pending_pointer_mutations = app.session.pending_pointer_mutations.clone();
        let (session, event_worker, mux_titles, mux_recovery_generation) = prepare_ordered_session(
            Session::Local(second),
            app.pty_input.sender(),
            app.app_events.clone(),
            2,
            None,
        )
        .unwrap();
        let tree = session.tree();

        app.install_prepared_machine_session(
            super::PreparedMachineSession {
                session,
                event_worker,
                generation: 2,
                mux_titles,
                mux_recovery_generation,
                tree,
                label: "second".into(),
                session_available: true,
                machine: None,
            },
            true,
        );

        let pending_pointer_settlement = old_pending_pointer_mutations.load(Ordering::Acquire);
        release_tx.send(()).unwrap();
        assert_eq!(
            pending_pointer_settlement, 1,
            "the split settlement must be queued against the old session before replacement"
        );
        assert!(app.drag.is_none());
        assert!(app.active_pointer_buttons.is_empty());
    }

    #[test]
    fn machine_session_replacement_preserves_only_the_old_browser_release() {
        let first = Mux::new("machine-browser-release-first", SurfaceOptions::default());
        let browser =
            first.new_browser_tab("about:blank".to_string(), None, Some((20, 8))).unwrap();
        let second = Mux::new("machine-browser-release-second", SurfaceOptions::default());
        let mut app = test_app(Session::Local(first.clone()));
        app.replace_tree(app.session.tree());
        assert!(app.tab_locations.contains_key(&browser.id));
        let (dispatcher, blocked) = BrowserInputDispatcher::blocked(2);
        app.browser_input = dispatcher;
        assert!(app.browser_input.enqueue(BrowserInputEvent {
            surface_id: browser.id,
            surface: app.session.surface(browser.id).unwrap(),
            kind: BrowserInputKind::Mouse {
                event_type: "mousePressed",
                x: 3.0,
                y: 2.0,
                button: Some("left"),
                click_count: Some(1),
                frame_seq: 1,
            },
        }));
        assert_eq!(blocked.drain_mouse_lifetimes(), vec![("mousePressed", false)]);
        assert!(app.browser_input.enqueue(BrowserInputEvent {
            surface_id: browser.id,
            surface: app.session.surface(browser.id).unwrap(),
            kind: BrowserInputKind::Mouse {
                event_type: "mouseMoved",
                x: 1.0,
                y: 1.0,
                button: Some("none"),
                click_count: None,
                frame_seq: 1,
            },
        }));
        app.drag = Some(Drag::Browser {
            surface: browser.id,
            content: Rect { x: 2, y: 3, width: 20, height: 8 },
            position: (5, 5),
            frame_seq: 1,
        });
        let (session, event_worker, mux_titles, mux_recovery_generation) = prepare_ordered_session(
            Session::Local(second),
            app.pty_input.sender(),
            app.app_events.clone(),
            2,
            None,
        )
        .unwrap();
        let tree = session.tree();

        app.install_prepared_machine_session(
            super::PreparedMachineSession {
                session,
                event_worker,
                generation: 2,
                mux_titles,
                mux_recovery_generation,
                tree,
                label: "second".into(),
                session_available: true,
                machine: None,
            },
            true,
        );

        assert_eq!(
            blocked.drain_mouse_lifetimes(),
            vec![("mouseMoved", true), ("mouseReleased", false)],
            "session replacement must cancel stale browser input but preserve the release that closes the old press"
        );
        first.close_surface(browser.id).unwrap();
    }

    #[test]
    fn replacement_provider_notice_cannot_mask_missing_workspace_mirror_error() {
        let first = Mux::new("machine-replacement-notice-first", SurfaceOptions::default());
        first.new_workspace(None, None).unwrap();
        let second = Mux::new("machine-replacement-notice-second", SurfaceOptions::default());
        second
            .create_empty_workspace(
                Some("work".into()),
                Some("00000000-0000-4000-8000-000000000004".into()),
                None,
            )
            .unwrap();
        let (mut app, events) = test_app_with_events(Session::Local(first));
        app.replace_tree(app.session.tree());
        app.apply_machine_ui_update(provider_machine_ui_with_lifecycle());
        let mut update = provider_machine_ui_with_lifecycle();
        update.notice = Some("provider accepted the rename".into());
        let result = MachineActionResult::replace(update, Session::Local(second), "second".into())
            .with_session_mutation(ManagedWorkspaceSessionMutation::Rename {
                workspace_key: "00000000-0000-4000-8000-000000000099".into(),
                name: "renamed".into(),
            });
        let (controller, _) = fake_controller(FakeMachineAction::Return(Box::new(result)));
        install_machine_controller(&mut app, controller);
        app.machine_ui.as_mut().unwrap().request = Some(MachineRequest::Switch(MachineKey(41)));

        settle_machine_action(&mut app, &events);

        assert_eq!(
            app.status_message.as_deref(),
            Some(localization::catalog().sidebar.managed_workspace_unavailable)
        );
    }

    #[test]
    fn replaced_session_ignores_old_surface_lane_completion() {
        let first = Mux::new("surface-lane-generation-first", SurfaceOptions::default());
        let first_surface = first.new_workspace(None, Some((80, 24))).unwrap();
        let second = Mux::new("surface-lane-generation-second", SurfaceOptions::default());
        let second_surface = second.new_workspace(None, Some((80, 24))).unwrap();
        assert_eq!(first_surface.id, second_surface.id, "test requires a reused surface id");
        let (mut app, _events) = test_app_with_events(Session::Local(first.clone()));
        let (started_tx, started_rx) = std::sync::mpsc::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();

        assert_eq!(
            app.session.operations.enqueue_surface_operation_with_retained_bytes(
                "old session clear",
                first_surface.id,
                false,
                0,
                move || {
                    started_tx.send(()).unwrap();
                    release_rx.recv().unwrap();
                    Err(anyhow::anyhow!("ambiguous old session completion"))
                },
            ),
            PtyInputEnqueueResult::Accepted
        );
        started_rx.recv_timeout(Duration::from_secs(1)).unwrap();

        let (session, event_worker, mux_titles, mux_recovery_generation) = prepare_ordered_session(
            Session::Local(second.clone()),
            app.pty_input.sender(),
            app.app_events.clone(),
            2,
            None,
        )
        .unwrap();
        let tree = session.tree();
        app.install_prepared_machine_session(
            super::PreparedMachineSession {
                session,
                event_worker,
                generation: 2,
                mux_titles,
                mux_recovery_generation,
                tree,
                label: "second".into(),
                session_available: true,
                machine: None,
            },
            true,
        );

        release_tx.send(()).unwrap();
        let deadline = Instant::now() + Duration::from_secs(1);
        while app.pty_failures.state.lock().unwrap().failures.is_empty()
            && Instant::now() < deadline
        {
            std::thread::yield_now();
        }
        assert!(!app.pty_failures.state.lock().unwrap().failures.is_empty());
        app.apply_pty_failures();

        let forwarded = app.enqueue_pty_bytes(
            second_surface.id,
            app.session.surface(second_surface.id).unwrap(),
            PtyInputBytes::from_slice(b"x"),
            PtyInputKind::Ordered,
        );
        assert!(forwarded.accepted, "old session lane state blocked the replacement session");
        assert!(
            app.status_message.is_none(),
            "old session completion surfaced an error in the replacement session"
        );

        let _ = first.close_surface(first_surface.id);
        let _ = second.close_surface(second_surface.id);
    }

    #[test]
    fn retiring_surface_state_releases_its_failed_input_lane() {
        let mux = Mux::new("retired-surface-input-lane-test", SurfaceOptions::default());
        let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
        let (mut app, _events) = test_app_with_events(Session::Local(mux.clone()));

        assert_eq!(
            app.session.operations.enqueue_coalescing_surface_operation(
                "failed surface operation",
                surface.id,
                false,
                || Err(anyhow::anyhow!("ambiguous delivery")),
            ),
            PtyInputEnqueueResult::Accepted
        );
        let deadline = Instant::now() + Duration::from_secs(1);
        while app.pty_failures.state.lock().unwrap().failures.is_empty()
            && Instant::now() < deadline
        {
            std::thread::yield_now();
        }
        assert!(!app.pty_failures.state.lock().unwrap().failures.is_empty());
        assert!(
            !app.enqueue_pty_bytes(
                surface.id,
                app.session.surface(surface.id).unwrap(),
                PtyInputBytes::from_slice(b"x"),
                PtyInputKind::Ordered,
            )
            .accepted
        );

        app.retire_surface_state(surface.id);

        assert!(
            app.enqueue_pty_bytes(
                surface.id,
                app.session.surface(surface.id).unwrap(),
                PtyInputBytes::from_slice(b"x"),
                PtyInputKind::Ordered,
            )
            .accepted
        );
        assert!(app.pty_input.shutdown(Duration::from_secs(1)));
        mux.close_surface(surface.id).unwrap();
    }

    #[test]
    fn terminal_input_failure_statuses_use_the_selected_locale() {
        const CHILD_ENV: &str = "CMUX_TERMINAL_INPUT_FAILURE_LOCALE_CHILD";
        if std::env::var_os(CHILD_ENV).is_none() {
            let output = std::process::Command::new(std::env::current_exe().unwrap())
                .arg("app::tests::terminal_input_failure_statuses_use_the_selected_locale")
                .arg("--exact")
                .arg("--nocapture")
                .env(CHILD_ENV, "1")
                .env("LC_ALL", "ja_JP.UTF-8")
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "Japanese terminal input failure child failed:\nstdout:\n{}\nstderr:\n{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
            return;
        }

        let mux = Mux::new("terminal-input-failure-locale", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        let oversized =
            "x".repeat(super::MAX_DEFERRED_INPUT_BYTES - super::BRACKETED_PASTE_MARKER_BYTES + 1);
        app.handle(AppEvent::Input(Event::Paste(oversized))).unwrap();
        assert_eq!(
            app.status_message.as_deref(),
            Some("貼り付けテキストが 4 MiB の PTY バッファ上限を超えています")
        );

        let half = "x".repeat(super::MAX_DEFERRED_INPUT_BYTES / 2);
        app.defer_input(TerminalInput::Paste(half.clone()));
        app.defer_input(TerminalInput::Paste(half));
        assert_eq!(
            app.status_message.as_deref(),
            Some("セッション変更の保留中に入力キューのバイト上限に達しました")
        );

        let motion = MouseEvent {
            kind: MouseEventKind::Moved,
            column: 9,
            row: 3,
            modifiers: KeyModifiers::NONE,
        };
        app.session.pending_pointer_mutations.store(1, Ordering::Release);
        app.handle(AppEvent::Input(Event::Mouse(motion))).unwrap();
        app.session.pending_pointer_mutations.store(0, Ordering::Release);
        assert_eq!(
            app.pending_pointer_motion.map(|pending| pending.event),
            Some(motion),
            "layout changes retain the latest pointer motion instead of discarding it"
        );

        for (result, expected) in [
            (PtyInputEnqueueResult::Oversized, "入力が 4 MiB の PTY バッファ上限を超えています"),
            (
                PtyInputEnqueueResult::Saturated,
                "PTY 入力キューがいっぱいのため、入力は送信されませんでした",
            ),
            (PtyInputEnqueueResult::Failed, "転送エラー後のため PTY 入力を使用できません"),
        ] {
            assert!(!app.handle_pty_enqueue_result(result));
            assert_eq!(app.status_message.as_deref(), Some(expected));
        }

        app.apply_pty_operation_failure(PtyOperationFailure {
            session_generation: 1,
            surface_id: Some(1),
            kind: None,
            reservation_id: None,
            label: "attach surface",
            error: "timeout detail".into(),
            lane_failed: true,
            delivery: PtyOperationDelivery::Ambiguous,
        });
        assert_eq!(
            app.status_message.as_deref(),
            Some(
                "サーフェスの接続結果を確認できません。入力を再開する前に切断して再接続してください: timeout detail"
            )
        );

        app.apply_pty_operation_failure(PtyOperationFailure {
            session_generation: 1,
            surface_id: Some(1),
            kind: Some(PtyInputKind::Ordered),
            reservation_id: None,
            label: "PTY input",
            error: "write failed".into(),
            lane_failed: false,
            delivery: PtyOperationDelivery::KnownNotDelivered,
        });
        assert_eq!(
            app.status_message.as_deref(),
            Some("ターミナル入力に失敗しました: write failed")
        );

        let destination_mux =
            Mux::new("deferred-destination-failure-locale", SurfaceOptions::default());
        let destination = destination_mux.new_workspace(None, None).unwrap();
        let mut destination_app = test_app(Session::Local(destination_mux));
        destination_app.replace_tree(destination_app.session.tree());
        destination_app.session.pending_mutations.store(1, Ordering::Release);
        destination_app
            .handle(AppEvent::Input(Event::Key(KeyEvent::new(
                KeyCode::Char('x'),
                KeyModifiers::NONE,
            ))))
            .unwrap();
        destination_app.session.pending_mutations.store(0, Ordering::Release);
        destination_app.replace_tree(notify_tree(destination.id + 1, false));
        destination_app.replay_deferred_input().unwrap();
        assert_eq!(
            destination_app.status_message.as_deref(),
            Some("遅延入力は送信先が変更されたため破棄されました")
        );
    }

    #[test]
    fn clear_history_failure_status_uses_the_selected_locale() {
        const CHILD_ENV: &str = "CMUX_CLEAR_HISTORY_FAILURE_LOCALE_CHILD";
        if std::env::var_os(CHILD_ENV).is_none() {
            let output = std::process::Command::new(std::env::current_exe().unwrap())
                .arg("app::tests::clear_history_failure_status_uses_the_selected_locale")
                .arg("--exact")
                .arg("--nocapture")
                .env(CHILD_ENV, "1")
                .env("LC_ALL", "ja_JP.UTF-8")
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "Japanese clear-history failure child failed:\nstdout:\n{}\nstderr:\n{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
            return;
        }

        let mux = Mux::new("clear-history-failure-locale", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        let cases = [
            (
                "remote server does not support clear-history; restart the cmux-tui server",
                "このサーバーでは clear-history を使用できません。cmux-tui サーバーを再起動してください",
            ),
            (
                "terminal keyboard mode cannot encode clear-history fallback key",
                "現在のターミナルキーボードモードでは代替キーを送信できません",
            ),
            (
                "active terminal input extends into retained history",
                "アクティブなターミナル入力が保持中の履歴にまたがっています",
            ),
            (
                "terminal output did not reach a safe clear-history boundary",
                "ターミナル出力が履歴を安全に消去できる境界に達しませんでした",
            ),
            (
                "terminal host does not support clear-history",
                "ターミナルホストが clear-history に対応していません。セッションを再接続してください",
            ),
            (
                "terminal host has exited",
                "ターミナルホストが終了しました。セッションを再接続してください",
            ),
            (
                "terminal host failed to apply clear-history",
                "ターミナルホストで履歴の消去に失敗しました",
            ),
            (
                "terminal host returned a malformed clear-history response",
                "ターミナルホストから無効な応答が返されました。セッションを再接続してください",
            ),
            (
                "terminal host did not acknowledge ClearHistory: timed out waiting on channel",
                "ターミナルホストから clear-history の応答がありませんでした。セッションを再接続してください",
            ),
            ("remote session did not respond", "リモートセッションから応答がありませんでした"),
            (
                "remote transport write failed: socket closed",
                "リモートセッションとの接続が切れました。再接続してください",
            ),
            (
                "remote command rejected: unknown surface",
                "リモートサーバーが clear-history を拒否しました",
            ),
            ("unexpected implementation detail", "予期しないターミナルエラーが発生しました"),
        ];

        for (error, detail) in cases {
            app.apply_pty_operation_failure(PtyOperationFailure {
                session_generation: 1,
                surface_id: Some(1),
                kind: None,
                reservation_id: None,
                label: "clear terminal history",
                error: error.into(),
                lane_failed: false,
                delivery: PtyOperationDelivery::KnownNotDelivered,
            });

            assert_eq!(
                app.status_message.as_deref(),
                Some(format!("ターミナル履歴を消去できませんでした: {detail}").as_str()),
                "unlocalized clear-history failure: {error}"
            );
        }

        app.apply_pty_operation_failure(PtyOperationFailure {
            session_generation: 1,
            surface_id: Some(1),
            kind: None,
            reservation_id: None,
            label: "clear terminal history",
            error: "remote session did not respond".into(),
            lane_failed: false,
            delivery: PtyOperationDelivery::Ambiguous,
        });
        assert_eq!(
            app.status_message.as_deref(),
            Some(
                "ターミナル履歴の消去結果を確認できません。再試行する前にセッションを再接続してください。"
            )
        );
    }

    #[test]
    fn single_surface_machine_session_install_does_not_publish_global_cell_metrics() {
        let first = Mux::new("surface-only-cell-metrics-first", SurfaceOptions::default());
        let first_surface = first.new_workspace(None, Some((80, 24))).unwrap();
        let second = Mux::new("surface-only-cell-metrics-second", SurfaceOptions::default());
        let second_surface = second.new_workspace(None, Some((80, 24))).unwrap();
        let (mut app, events) = test_app_with_events(Session::Local(first.clone()));
        app.surface_only = Some(second_surface.id);
        app.cell_pixels = (13, 27);
        let pty_input = PtyInputDispatcher::spawn(|_| {}).unwrap();
        let (session, event_worker, mux_titles, mux_recovery_generation) = prepare_ordered_session(
            Session::Local(second.clone()),
            pty_input.sender(),
            app.app_events.clone(),
            2,
            Some(second_surface.id),
        )
        .unwrap();
        let tree = session.tree();

        app.install_prepared_machine_session(
            super::PreparedMachineSession {
                session,
                event_worker,
                generation: 2,
                mux_titles,
                mux_recovery_generation,
                tree,
                label: "second".into(),
                session_available: true,
                machine: None,
            },
            true,
        );
        while app.session.has_pending_mutations() {
            let event = events.recv_timeout(Duration::from_secs(5)).unwrap();
            app.handle(event).unwrap();
        }

        assert_eq!(
            second.cell_pixel_size(),
            (8, 16),
            "surface-only attach published host metrics to the shared session"
        );
        let _ = first.close_surface(first_surface.id);
        let _ = second.close_surface(second_surface.id);
    }

    #[test]
    fn non_switch_machine_action_keeps_the_current_session_and_rails() {
        let mux = Mux::new("machine-non-switch", SurfaceOptions::default());
        mux.new_workspace(None, None).unwrap();
        let (mut app, events) = test_app_with_events(Session::Local(mux));
        app.replace_tree(app.session.tree());
        let original_workspace_count = app.tree.workspaces().len();
        let original_surface = app.tree.active_surface();
        app.machine_ui = Some(provider_machine_ui());
        app.sidebar_width_override = Some(25);
        app.machine_sidebar_width_override = Some(17);
        let mut next_ui = provider_machine_ui();
        next_ui.notice = Some("team selected".into());
        let (controller, requests) =
            fake_controller(FakeMachineAction::Return(Box::new(MachineActionResult::ui(next_ui))));
        install_machine_controller(&mut app, controller);
        app.machine_ui.as_mut().unwrap().request =
            Some(MachineRequest::SelectProviderScope("team".into()));

        settle_machine_action(&mut app, &events);

        assert_eq!(app.session_generation, 1);
        assert_eq!(app.tree.workspaces().len(), original_workspace_count);
        assert_eq!(app.tree.active_surface(), original_surface);
        assert_eq!(app.sidebar_width_override, Some(25));
        assert_eq!(app.machine_sidebar_width_override, Some(17));
        assert_eq!(app.status_message.as_deref(), Some("team selected"));
        assert!(!app.quit);
        assert!(matches!(
            requests.lock().unwrap().as_slice(),
            [MachineRequest::SelectProviderScope(scope)] if scope == "team"
        ));
    }

    #[test]
    fn failed_machine_switch_preserves_the_current_session() {
        let mux = Mux::new("machine-failed-switch", SurfaceOptions::default());
        mux.new_workspace(None, None).unwrap();
        let (mut app, events) = test_app_with_events(Session::Local(mux));
        app.replace_tree(app.session.tree());
        let original_workspace_count = app.tree.workspaces().len();
        let original_surface = app.tree.active_surface();
        app.machine_ui = Some(provider_machine_ui());
        let (controller, _) = fake_controller(FakeMachineAction::Fail("candidate refused"));
        install_machine_controller(&mut app, controller);
        app.machine_ui.as_mut().unwrap().request = Some(MachineRequest::Switch(MachineKey(99)));

        settle_machine_action(&mut app, &events);

        assert_eq!(app.session_generation, 1);
        assert_eq!(app.session_label, "test");
        assert_eq!(app.tree.workspaces().len(), original_workspace_count);
        assert_eq!(app.tree.active_surface(), original_surface);
        let expected =
            format!("{}: candidate refused", localization::catalog().sidebar.machine_action_failed);
        assert_eq!(app.status_message.as_deref(), Some(expected.as_str()));
        assert!(!app.quit);
    }

    #[test]
    fn stale_session_events_are_ignored_after_an_in_place_switch() {
        let first = Mux::new("machine-stale-first", SurfaceOptions::default());
        first.new_workspace(None, None).unwrap();
        let second = Mux::new("machine-stale-second", SurfaceOptions::default());
        let (mut app, events) = test_app_with_events(Session::Local(first));
        app.machine_ui = Some(provider_machine_ui());
        let (controller, _) =
            fake_controller(FakeMachineAction::Return(Box::new(MachineActionResult::replace(
                provider_machine_ui(),
                Session::Local(second),
                "second".into(),
            ))));
        install_machine_controller(&mut app, controller);
        app.machine_ui.as_mut().unwrap().request = Some(MachineRequest::Switch(MachineKey(41)));
        settle_machine_action(&mut app, &events);
        app.machine_ui.as_mut().unwrap().request = None;

        let action = app
            .handle(AppEvent::SessionScoped {
                generation: 1,
                event: Box::new(AppEvent::Mux(MuxEvent::Empty)),
            })
            .unwrap();

        assert_eq!(action, RenderAction::None);
        assert_eq!(app.session_generation, 2);
        assert!(app.machine_ui.as_ref().unwrap().request.is_none());
        assert!(!app.quit);
    }

    /// Regression test for issue 11042: when a remote event transport dies,
    /// the reader thread records the reason and synthesizes `MuxEvent::Empty`.
    /// That must surface the transport failure as an error, never the "session
    /// has no workspaces" clean quit (exit code 0) it produces today.
    #[test]
    fn transport_loss_empty_event_is_an_error_not_a_clean_quit() {
        let reason = "the daemon closed the connection";
        let mut app = test_app(test_remote_session_with_lost_transport(reason));

        let result = app.handle(AppEvent::Mux(MuxEvent::Empty));

        let error = result.expect_err("a lost event transport must not report an empty session");
        assert_eq!(error.to_string(), "session connection lost. Reconnect and retry.");
        assert!(!error.to_string().contains(reason));
        assert!(!app.quit, "a lost transport must not use the clean-quit path");
    }

    /// The transport check must run BEFORE any machine-session request: with
    /// machine/provider authority present, `request_current_machine_session`
    /// returns true and would otherwise swallow the dead transport into a
    /// stuck reconnect state.
    #[test]
    fn transport_loss_outranks_a_machine_session_request() {
        let reason = "the daemon closed the connection";
        let mut app = test_app(test_remote_session_with_lost_transport(reason));
        app.machine_ui = Some(provider_machine_ui());

        let result = app.handle(AppEvent::Mux(MuxEvent::Empty));

        let error = result.expect_err("machine authority must not hide a lost transport");
        assert_eq!(error.to_string(), "session connection lost. Reconnect and retry.");
        assert!(!error.to_string().contains(reason));
        assert!(!app.quit);
        let machine = app.machine_ui.as_ref().unwrap();
        assert!(
            machine.request.is_none(),
            "no reconnect request may be queued for a dead transport"
        );
    }

    /// A sleeping or stopped machine loses its stream because it was paused;
    /// that deliberate loss keeps presenting the machine as asleep instead of
    /// failing the client, even though a transport reason is recorded.
    #[test]
    fn sleeping_machine_stream_loss_still_presents_as_asleep() {
        let mut app =
            test_app(test_remote_session_with_lost_transport("the daemon closed the connection"));
        let mut ui = provider_machine_ui();
        ui.snapshot.machines[0].status = MachineStatus::Sleeping;
        app.machine_ui = Some(ui);

        let action = app.handle(AppEvent::Mux(MuxEvent::Empty)).unwrap();

        assert_eq!(action, RenderAction::Draw);
        assert!(!app.quit);
        let machine = app.machine_ui.as_ref().unwrap();
        assert!(!machine.session_available);
        assert!(machine.request.is_none());
    }

    /// A genuinely emptied session (all workspaces closed) still exits
    /// cleanly: `MuxEvent::Empty` without a recorded transport failure keeps
    /// the quiet quit path.
    #[test]
    fn empty_session_without_transport_loss_still_quits_cleanly() {
        let mux = Mux::new("empty-clean-quit-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));

        let action = app.handle(AppEvent::Mux(MuxEvent::Empty)).unwrap();

        assert_eq!(action, RenderAction::None);
        assert!(app.quit);
    }

    #[test]
    fn stale_machine_updates_are_ignored_after_subscription_replacement() {
        let mux = Mux::new("machine-stale-provider-update", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.machine_ui = Some(provider_machine_ui());
        app.machine_update_generation = 2;
        let mut stale = provider_machine_ui();
        stale.notice = Some("stale provider update".into());

        let action = app
            .handle(AppEvent::MachineUpdatedForGeneration {
                generation: 1,
                update: Box::new(MachineUpdate::Ui(Box::new(stale))),
            })
            .unwrap();

        assert_eq!(action, RenderAction::None);
        assert_ne!(app.status_message.as_deref(), Some("stale provider update"));
    }

    #[test]
    fn durable_notices_wait_for_exact_successful_paint_and_advance_in_fifo_order() {
        let mux = Mux::new("durable-notice-fifo", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        let first = durable_notice("usage-80", 7, "Usage reached 80%");
        let second = durable_notice("usage-90", 8, "Usage reached 90%");

        assert_eq!(app.accept_durable_notice(first.clone()), RenderAction::Draw);
        assert_eq!(app.accept_durable_notice(second.clone()), RenderAction::Draw);
        assert!(!app.dismiss_painted_durable_notice());

        let mut terminal = Terminal::new(TestBackend::new(16, 3)).unwrap();
        terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();

        assert_eq!(app.painted_durable_notice_this_frame.as_ref(), Some(&first.delivery));
        assert!(app.pending_durable_notice_acks.is_empty());
        assert_eq!(app.durable_notice().map(|notice| &notice.delivery), Some(&first.delivery));

        app.commit_successful_durable_notice_paint();
        assert_eq!(app.pending_durable_notice_acks.front(), Some(&first.delivery));
        assert!(app.dismiss_painted_durable_notice());
        assert_eq!(app.durable_notice().map(|notice| &notice.delivery), Some(&second.delivery));
        assert!(!app.dismiss_painted_durable_notice());
    }

    #[test]
    fn durable_notice_banner_overrides_prefix_and_empty_status_bar() {
        let mux = Mux::new("durable-notice-banner", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        let notice = durable_notice("usage-80", 9, "quota");
        app.prefix_armed = true;
        app.accept_durable_notice(notice.clone());

        let mut terminal = Terminal::new(TestBackend::new(8, 3)).unwrap();
        terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();

        let buffer = terminal.backend().buffer();
        let bottom = (0..8).map(|x| buffer[(x, 2)].symbol()).collect::<String>();
        assert!(bottom.starts_with("! quota"), "{bottom:?}");
        assert_eq!(buffer[(0, 2)].fg, app.chrome.status_bg);
        assert_eq!(buffer[(0, 2)].bg, app.config.theme.notification_warning);
        assert_eq!(app.painted_durable_notice_this_frame.as_ref(), Some(&notice.delivery));
    }

    #[test]
    fn durable_notice_banner_is_visible_in_a_one_cell_terminal() {
        let mux = Mux::new("durable-notice-one-cell", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        let notice = durable_notice("usage-95", 10, "quota");
        app.accept_durable_notice(notice.clone());

        let mut terminal = Terminal::new(TestBackend::new(1, 1)).unwrap();
        terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();

        let cell = &terminal.backend().buffer()[(0, 0)];
        assert_eq!(cell.symbol(), "!");
        assert_eq!(cell.fg, app.chrome.status_bg);
        assert_eq!(cell.bg, app.config.theme.notification_warning);
        assert_eq!(app.painted_durable_notice_this_frame.as_ref(), Some(&notice.delivery));
    }

    #[test]
    fn durable_notice_auto_advance_waits_until_after_a_readable_interval() {
        let mux = Mux::new("durable-notice-auto-advance", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        let first = durable_notice("usage-80", 10, "first");
        let second = durable_notice("usage-90", 11, "second");
        app.accept_durable_notice(first.clone());
        app.accept_durable_notice(second.clone());
        app.record_durable_notice_painted(first.delivery);
        app.commit_successful_durable_notice_paint();

        assert!(!app.advance_expired_durable_notice());
        app.durable_notices.front_mut().unwrap().painted_at =
            Some(Instant::now() - super::DURABLE_NOTICE_DISPLAY_DURATION);
        assert!(app.advance_expired_durable_notice());
        assert_eq!(app.durable_notice().map(|notice| &notice.delivery), Some(&second.delivery));
    }

    #[test]
    fn durable_notice_dismissal_preserves_text_and_mouse_input() {
        let mux = Mux::new("durable-notice-input", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.prompt = Some(Prompt::new(
            "Rename",
            String::new(),
            PromptTarget::ConnectMachine(MachineConnectRoute::Local),
        ));

        let keyboard = durable_notice("keyboard", 12, "keyboard");
        app.accept_durable_notice(keyboard.clone());
        app.record_durable_notice_painted(keyboard.delivery);
        app.commit_successful_durable_notice_paint();
        app.handle(AppEvent::Input(Event::Key(KeyEvent::new(
            KeyCode::Char('é'),
            KeyModifiers::NONE,
        ))))
        .unwrap();
        assert_eq!(app.prompt.as_ref().unwrap().input.as_str(), "é");
        assert!(app.durable_notice().is_none());

        let paste = durable_notice("paste", 13, "paste");
        app.accept_durable_notice(paste.clone());
        app.record_durable_notice_painted(paste.delivery);
        app.commit_successful_durable_notice_paint();
        app.handle(AppEvent::Input(Event::Paste("文".into()))).unwrap();
        assert_eq!(app.prompt.as_ref().unwrap().input.as_str(), "é文");
        assert!(app.durable_notice().is_none());

        app.prompt = None;
        app.machine_ui = Some(provider_machine_ui());
        app.content_area = Rect { x: 0, y: 0, width: 5, height: 2 };
        app.hits.push((Rect { x: 0, y: 0, width: 1, height: 1 }, super::Hit::ConnectMachine));
        app.commit_rendered_pointer_frame();
        app.pointer_route_phase = PointerRoutePhase::Fresh;
        let outside_banner = durable_notice("mouse-outside", 14, "mouse");
        app.accept_durable_notice(outside_banner.clone());
        app.record_durable_notice_painted(outside_banner.delivery);
        app.commit_successful_durable_notice_paint();
        app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
            kind: MouseEventKind::Moved,
            column: 0,
            row: 0,
            modifiers: KeyModifiers::NONE,
        })))
        .unwrap();
        assert!(app.durable_notice().is_some());
        app.commit_rendered_pointer_frame();
        app.pointer_route_phase = PointerRoutePhase::Fresh;
        app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
            kind: MouseEventKind::Down(MouseButton::Left),
            column: 0,
            row: 0,
            modifiers: KeyModifiers::NONE,
        })))
        .unwrap();
        assert!(app.durable_notice().is_none());
        assert!(app.prompt.is_some(), "mouse presses outside the banner must be preserved");

        app.prompt = None;
        app.hits.clear();
        app.hits.push((Rect { x: 0, y: 2, width: 1, height: 1 }, super::Hit::ConnectMachine));
        app.commit_rendered_pointer_frame();
        app.pointer_route_phase = PointerRoutePhase::Fresh;
        let on_banner = durable_notice("mouse-banner", 15, "mouse");
        app.accept_durable_notice(on_banner.clone());
        app.record_durable_notice_painted(on_banner.delivery);
        app.commit_successful_durable_notice_paint();
        app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
            kind: MouseEventKind::Down(MouseButton::Left),
            column: 0,
            row: 2,
            modifiers: KeyModifiers::NONE,
        })))
        .unwrap();
        assert!(app.durable_notice().is_none());
        assert!(app.prompt.is_none(), "banner presses must not activate covered hits");
    }

    #[test]
    fn durable_notice_recent_ledger_is_bounded_to_provider_retention() {
        let mux = Mux::new("durable-notice-ledger", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        for sequence in 0..=super::DURABLE_NOTICE_RECENT_CAPACITY as u64 {
            let notice = durable_notice(&format!("notice-{sequence}"), sequence, "notice");
            app.accept_durable_notice(notice.clone());
            app.record_durable_notice_painted(notice.delivery);
            app.commit_successful_durable_notice_paint();
            assert!(app.dismiss_painted_durable_notice());
        }

        assert_eq!(app.recent_durable_notices.len(), super::DURABLE_NOTICE_RECENT_CAPACITY);
        assert_eq!(app.recent_durable_notices.front().map(|delivery| delivery.sequence), Some(1));
    }

    #[test]
    fn durable_notice_queue_overflow_reconnects_without_acknowledging_or_growing() {
        let mux = Mux::new("durable-notice-queue-bound", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.machine_ui = Some(provider_machine_ui());
        for sequence in 1..=super::DURABLE_NOTICE_QUEUE_CAPACITY as u64 {
            assert_eq!(
                app.accept_durable_notice(durable_notice(
                    &format!("notice-{sequence}"),
                    sequence,
                    "notice",
                )),
                RenderAction::Draw
            );
        }
        assert_eq!(
            app.accept_durable_notice(durable_notice(
                "overflow",
                super::DURABLE_NOTICE_QUEUE_CAPACITY as u64 + 1,
                "overflow",
            )),
            RenderAction::None
        );

        assert_eq!(app.durable_notices.len(), super::DURABLE_NOTICE_QUEUE_CAPACITY);
        assert!(app.pending_durable_notice_acks.is_empty());
        assert!(app.machine_provider_reconnect_retry_at.is_some());
        assert!(matches!(
            app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
            Some(MachineRequest::ReconnectProvider)
        ));
    }

    #[test]
    fn stale_durable_notice_is_neither_displayed_nor_acknowledged() {
        let mux = Mux::new("stale-durable-notice", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.machine_update_generation = 2;
        let notice = durable_notice("stale", 12, "stale");

        let action = app
            .handle(AppEvent::MachineUpdatedForGeneration {
                generation: 1,
                update: Box::new(MachineUpdate::DurableNotice(notice)),
            })
            .unwrap();

        assert_eq!(action, RenderAction::None);
        assert!(app.durable_notices.is_empty());
        assert!(app.recent_durable_notices.is_empty());
        assert!(app.pending_durable_notice_acks.is_empty());
        assert!(app.durable_notice_ack_in_flight.is_none());
    }

    #[test]
    fn failed_durable_notice_ack_reconnects_and_replay_is_not_redisplayed() {
        let mux = Mux::new("failed-durable-notice-ack", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.machine_ui = Some(provider_machine_ui());
        let notice = durable_notice("usage-80", 13, "quota");
        app.remember_durable_notice(notice.delivery.clone());
        app.durable_notice_ack_in_flight = Some(notice.delivery.clone());

        app.apply_machine_controller_completion(
            super::MachineControllerCompletion::DurableNoticeAcknowledged {
                delivery: notice.delivery.clone(),
                result: Err("permission revoked".into()),
            },
        );

        assert!(app.durable_notice_ack_in_flight.is_none());
        assert!(app.durable_notice_ack_retry_at.is_some());
        assert!(app.machine_provider_reconnect_retry_at.is_some());
        assert!(matches!(
            app.machine_ui.as_ref().and_then(|ui| ui.request.as_ref()),
            Some(MachineRequest::ReconnectProvider)
        ));
        assert_eq!(app.accept_durable_notice(notice.clone()), RenderAction::None);
        assert!(app.durable_notices.is_empty());
        assert_eq!(
            app.pending_durable_notice_acks.iter().collect::<Vec<_>>(),
            vec![&notice.delivery]
        );

        let ack_retry_at = app.durable_notice_ack_retry_at;
        app.clear_machine_provider_reconnect();
        assert_eq!(app.durable_notice_ack_retry_at, ack_retry_at);
        assert_eq!(app.durable_notice_ack_failures, 1);

        app.durable_notice_ack_retry_at = Some(Instant::now() - Duration::from_millis(1));
        app.submit_pending_durable_notice_ack();
        assert!(app.durable_notice_ack_retry_at.is_none());
        assert_eq!(app.durable_notice_ack_failures, 1);

        app.pending_durable_notice_acks.clear();
        app.durable_notice_ack_in_flight = Some(notice.delivery.clone());
        app.apply_machine_controller_completion(
            super::MachineControllerCompletion::DurableNoticeAcknowledged {
                delivery: notice.delivery,
                result: Ok(()),
            },
        );
        assert_eq!(app.durable_notice_ack_failures, 0);
        assert!(app.durable_notice_ack_retry_at.is_none());
    }

    #[test]
    fn canceling_a_session_event_worker_joins_a_blocked_mux_reader() {
        let mux = Mux::new("machine-worker-cancel", SurfaceOptions::default());
        let pty_input = PtyInputDispatcher::spawn(|_| {}).unwrap();
        let (events, _receiver) = crossbeam_channel::bounded(4_096);
        let (_session, mut worker, _, _) =
            start_ordered_session(Session::Local(mux), pty_input.sender(), events, 7, None)
                .unwrap();

        worker.stop_and_join();

        assert!(worker.mux.is_none());
    }

    #[test]
    fn canceling_a_bounded_event_send_unblocks_before_join_when_queue_is_full() {
        let (events, receiver) = crossbeam_channel::bounded(1);
        events.send(AppEvent::Mux(MuxEvent::Empty)).unwrap();
        let cancellation = EventCancellation::new();
        let worker_cancellation = cancellation.clone();
        let (started_tx, started_rx) = std::sync::mpsc::sync_channel(1);
        let (completed_tx, completed_rx) = std::sync::mpsc::sync_channel(1);
        let worker = std::thread::spawn(move || {
            started_tx.send(()).unwrap();
            let result = send_bounded_cancelable(
                &events,
                AppEvent::Mux(MuxEvent::Empty),
                &worker_cancellation,
            );
            completed_tx.send(result).unwrap();
        });

        started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(matches!(
            completed_rx.recv_timeout(Duration::from_millis(50)),
            Err(std::sync::mpsc::RecvTimeoutError::Timeout)
        ));
        cancellation.cancel();
        assert_eq!(completed_rx.recv_timeout(Duration::from_secs(1)).unwrap(), Err(()));
        worker.join().unwrap();
        drop(receiver);
    }

    #[test]
    fn prepared_machine_session_events_stay_paused_until_commit_activation() {
        let mux = Mux::new("prepared-machine-session-events", SurfaceOptions::default());
        let pty_input = PtyInputDispatcher::spawn(|_| {}).unwrap();
        let (events, receiver) = crossbeam_channel::bounded(4_096);
        let (_session, mut worker, _, _) = prepare_ordered_session(
            Session::Local(mux.clone()),
            pty_input.sender(),
            events,
            7,
            None,
        )
        .unwrap();

        mux.new_workspace(None, None).unwrap();
        assert!(matches!(
            receiver.recv_timeout(Duration::from_millis(50)),
            Err(crossbeam_channel::RecvTimeoutError::Timeout)
        ));

        worker.activate();
        assert!(matches!(
            receiver.recv_timeout(Duration::from_secs(1)).unwrap(),
            AppEvent::SessionScoped { generation: 7, .. }
        ));
        worker.stop_and_join();
    }

    #[test]
    fn presented_local_owner_applies_one_reload_for_both_event_paths() {
        let owner = Mux::new("owner-reload-deduplication", SurfaceOptions::default());
        let session = crate::session::test_remote_session_with_browser_pointer_range(7, 1, 1);
        let (mut app, _) = test_app_with_events(session);
        app.owner_mux = Some(owner);

        app.handle(AppEvent::Mux(MuxEvent::ConfigReloadRequested)).unwrap();
        app.handle(AppEvent::OwnerConfigReloadRequested).unwrap();

        assert_eq!(app.config_reload_applications, 1);
    }

    #[test]
    fn local_owner_without_an_active_machine_applies_one_reload_for_both_event_paths() {
        let owner = Mux::new("owner-reload-without-active-machine", SurfaceOptions::default());
        let session = crate::session::test_remote_session_with_browser_pointer_range(7, 1, 1);
        let (mut app, _) = test_app_with_events(session);
        let mut machine_ui = provider_machine_ui();
        machine_ui.snapshot.active = None;
        app.owner_mux = Some(owner);
        app.machine_ui = Some(machine_ui);
        app.machine_presented = None;

        app.handle(AppEvent::Mux(MuxEvent::ConfigReloadRequested)).unwrap();
        app.handle(AppEvent::OwnerConfigReloadRequested).unwrap();

        assert_eq!(app.config_reload_applications, 1);
    }

    #[test]
    fn local_owner_shutdown_survives_machine_session_replacement() {
        let owner = Mux::new("owner-shutdown-source", SurfaceOptions::default());
        let initial = crate::session::test_remote_session_with_browser_pointer_range(7, 1, 1);
        let replacement = crate::session::test_remote_session_with_browser_pointer_range(8, 2, 2);
        let (mut app, events) = test_app_with_events(initial);
        app.owner_mux = Some(owner.clone());
        app.owner_reload_worker =
            Some(super::OwnerReloadWorker::spawn(&owner, app.app_events.clone()).unwrap());
        let (session, event_worker, mux_titles, mux_recovery_generation) = prepare_ordered_session(
            replacement,
            app.pty_input.sender(),
            app.app_events.clone(),
            2,
            None,
        )
        .unwrap();
        let tree = session.tree();
        app.install_prepared_machine_session(
            super::PreparedMachineSession {
                session,
                event_worker,
                generation: 2,
                mux_titles,
                mux_recovery_generation,
                tree,
                label: "replacement".into(),
                session_available: true,
                machine: None,
            },
            true,
        );

        owner.emit(MuxEvent::ConfigReloadRequested);
        let deadline = Instant::now() + Duration::from_secs(1);
        let reload = loop {
            let remaining = deadline.saturating_duration_since(Instant::now());
            let event = events.recv_timeout(remaining).expect("owner reload was not delivered");
            if matches!(event, AppEvent::OwnerConfigReloadRequested) {
                break event;
            }
        };
        app.handle(reload).unwrap();

        assert!(!app.session.daemon_shutdown_requested());
        assert!(!app.owner_shutdown_requested());

        owner.request_daemon_shutdown();

        assert!(!app.session.daemon_shutdown_requested());
        assert!(app.owner_shutdown_requested());
    }

    pub(super) fn test_app(session: Session) -> App {
        test_app_with_events(session).0
    }

    fn test_app_with_events(session: Session) -> (App, Receiver<AppEvent>) {
        let pty_failures = Arc::new(PtyFailureIngress::default());
        let failure_ingress = pty_failures.clone();
        let pty_input = PtyInputDispatcher::spawn(move |failure| {
            failure_ingress.push(failure);
        })
        .unwrap();
        let (events, receiver) = crossbeam_channel::bounded(4_096);
        let layout_resize_owner = session.allocate_layout_resize_owner();
        let session =
            OrderedSession::new(session, pty_input.sender(), events.clone(), layout_resize_owner);
        let app = App {
            session,
            owner_mux: None,
            owner_machine: None,
            owner_reload_worker: None,
            session_event_worker: None,
            session_generation: 1,
            app_events: events,
            frontend_journal: FrontendJournalWorker::disabled(),
            frontend_projection_id: FrontendProjectionPublicId::parse(
                "projection_00000000000000000000000000000001",
            )
            .unwrap(),
            last_frontend_presentation: None,
            outer_size: (0, 0),
            host_input: HostInputRuntime::new(),
            machine_action_worker: None,
            machine_action_in_flight: false,
            machine_action_request: None,
            machine_action_connection_attempt: None,
            canceled_machine_connection_attempt: None,
            machine_action_intent_generation: None,
            machine_selection_intent: None,
            machine_selection_generation: 0,
            machine_presented: None,
            machine_deleted_rail_index: None,
            machine_provider_reconnect_attempts: 0,
            machine_provider_reconnect_retry_at: None,
            pending_machine_replacement: None,
            machine_update_pump: None,
            machine_update_generation: 0,
            durable_notices: VecDeque::new(),
            recent_durable_notices: VecDeque::new(),
            painted_durable_notice_this_frame: None,
            pending_durable_notice_acks: VecDeque::new(),
            durable_notice_ack_in_flight: None,
            durable_notice_ack_failures: 0,
            durable_notice_ack_retry_at: None,
            config: Config::default(),
            config_reload_applications: 0,
            chrome: ChromeTheme::dark(),
            tree: TreeView::default(),
            tab_locations: HashMap::new(),
            render_states: HashMap::<u64, RenderState>::new(),
            chrome_row_scratch: crate::ui::ReusableRowBuffer::default(),
            sidebar_kind_scratch: Vec::new(),
            rendered_terminal_sizes: HashMap::new(),
            rendered_terminal_pointer_semantics: HashMap::new(),
            rendered_pane_content_generations: HashMap::new(),
            desired_outer_cursor: OuterCursorSpec::Reset,
            applied_outer_cursor: None,
            host_mouse_capture_applied: Some(true),
            graphics_writer: None,
            next_graphics_submission: 0,
            pending_graphics_submission: None,
            pending_graphics_snapshot: None,
            pending_graphics_affected_rect: None,
            last_graphics_snapshot: Vec::new(),
            graphics_supported: false,
            graphics_host_scene_reset_pending: false,
            graphics_scene_cache: GraphicsSceneCache::default(),
            graphics_dirty_surfaces: HashSet::new(),
            stdout_lock: Arc::new(StdoutLock::new(())),
            pane_areas: Vec::new(),
            viewport_projection: ViewportPaneAreaProjection::default(),
            viewport_layout: Vec::new(),
            viewport_stacked_headers: HashSet::new(),
            viewport_states: HashMap::new(),
            viewport_virtual_width: 0,
            viewport_offset: 0,
            pane_focus_history: PaneFocusHistory::default(),
            reported_focus: None,
            client_focus_id: None,
            rendered_terminal_bounds: HashMap::new(),
            rendered_kitty_graphics: HashMap::new(),
            visible_size_surfaces: HashSet::new(),
            pending_size_releases: HashSet::new(),
            geometry_authority_surface: None,
            prefix_armed: false,
            session_label: "test".to_string(),
            surface_only: None,
            sidebar_visible: true,
            sidebar_compact: false,
            focus: FocusTarget::Pane,
            sidebar_focus_pending: false,
            machine_ui: None,
            machine_pointer_context_cache: None,
            sidebar_view: SidebarView::Files,
            sidebar_files: FileBrowser::new(std::env::temp_dir()),
            sidebar_workspace_selection: 0,
            sidebar_recoverable_workspace_selection: 0,
            workspace_rail_selection: WorkspaceRailSelection::default(),
            machine_rail_scroll: 0,
            machine_footer_scroll: 0,
            workspace_rail_scroll: 0,
            workspace_footer_scroll: 0,
            tabs_rail_selection: 0,
            tabs_rail_scroll: 0,
            tabs_footer_scroll: 0,
            projection_rails: HashMap::new(),
            projection_order_cache: AgentOrderCache::default(),
            machine_rail_follow_selection: true,
            workspace_rail_follow_selection: true,
            tabs_rail_follow_selection: true,
            sidebar_followed_surface: None,
            sidebar_width: 0,
            machine_sidebar_width: 0,
            tabs_sidebar_width: 0,
            sidebar_layout: SidebarLayout::default(),
            sidebar_plugin_surface: None,
            sidebar_plugin_error: None,
            sidebar_plugin_retry_after_ms: None,
            sidebar_plugin_retry_at: None,
            sidebar_width_override: None,
            machine_sidebar_width_override: None,
            tabs_sidebar_width_override: None,
            projection_sidebar_width_overrides: HashMap::new(),
            hidden_sidebar_views: HashMap::new(),
            content_area: Rect::default(),
            hits: Vec::new(),
            tab_scroll: HashMap::new(),
            hover: None,
            menu: None,
            clients: Vec::new(),
            client_border_labels: HashMap::new(),
            size_state_labels: HashMap::new(),
            prompt: None,
            connection_transaction: None,
            next_connection_attempt: 1,
            pending_provider_action: None,
            pairing_dialog: None,
            pairing_queue: VecDeque::new(),
            shortcut_help: None,
            omnibar: None,
            toast: None,
            shake_frames: 0,
            selection: None,
            selection_generation: 0,
            selection_mode: SelectionMode::Cell,
            selection_mode_surface: None,
            selection_click_sequence: None,
            semantic_selection_cache: None,
            status_selection: None,
            rendered_status_message: None,
            logged_status_message: None,
            status_notice_text: None,
            input_revision: 0,
            status_message: None,
            cell_pixels: (8, 16),
            pointer_shape: false,
            last_browser_hover: None,
            browser_input: BrowserInputDispatcher::spawn(|_| {}, |_| {}).unwrap(),
            pty_input,
            deferred_input: DeferredInputQueue::default(),
            pending_pointer_motion: None,
            deferred_input_sequence: 0,
            next_semantic_destination_intent: 0,
            latest_semantic_destination_intent: None,
            semantic_destination_outcomes: HashMap::new(),
            rendered_pointer_frame: RenderedPointerFrame::default(),
            pointer_route_phase: PointerRoutePhase::Fresh,
            pointer_focus_generation: 0,
            layout_refresh_retries_remaining: 0,
            background_refresh_attempts: 0,
            background_refresh_retry_at: None,
            last_applied_refresh_sequence: 0,
            applied_destination_generation: 0,
            pending_session_completions: VecDeque::new(),
            mux_titles: Arc::new(MuxTitleIngress::default()),
            pty_failures,
            mux_recovery_generation: Arc::new(AtomicU64::new(0)),
            drag: None,
            active_pointer_buttons: HashSet::new(),
            ignored_pty_mouse_buttons: HashSet::new(),
            timeout_drain_hook: None,
            encoder: KeyEncoder::new().unwrap(),
            encode_buf: Vec::new(),
            quit: false,
            status_command_outputs: Arc::new(Mutex::new(HashMap::new())),
            status_command_worker_stop: None,
            status_poke_pending: Arc::new(AtomicBool::new(false)),
            status_command_workers: Vec::new(),
            retiring_status_workers: Vec::new(),
            status_outputs_generation: Arc::new(AtomicU64::new(0)),
            status_segments_cache: None,
            machine_usage: None,
        };
        (app, receiver)
    }

    fn notify_tree(surface: u64, unread: bool) -> TreeView {
        TreeView::from_parts(
            vec![WorkspaceView {
                id: 4,
                resource_id: None,
                key: "00000000-0000-4000-8000-000000000004".to_string(),
                short_id: "000004".to_string(),
                name: "work".to_string(),
                active_screen: 0,
                screens: vec![ScreenView {
                    id: 3,
                    resource_id: None,
                    short_id: "000003".to_string(),
                    name: None,
                    layout: Node::Leaf(2),
                    active_pane: 2,
                    zoomed_pane: None,
                    viewport_base_width: None,
                    viewport_splits: BTreeMap::new(),
                    panes: vec![PaneView {
                        id: 2,
                        resource_id: None,
                        short_id: "000002".to_string(),
                        name: None,
                        active_tab: 0,
                        focused_at: 0,
                        tabs: vec![TabView {
                            surface,
                            public_id: None,
                            content_id: None,
                            terminal_id: None,
                            short_id: "000001".to_string(),
                            name: Some("tab".to_string()),
                            title: "shell".to_string(),
                            kind: SurfaceKind::Pty,
                            browser_source: None,
                            browser_frames_stalled: false,
                            supports_clear_history_key_fallback: false,
                            notification: unread
                                .then_some(TabNotificationView { unread: true, level: "warning" }),
                        }],
                    }],
                }],
            }],
            0,
            Some(1),
            0,
        )
    }

    #[test]
    fn remote_tree_refresh_preserves_this_clients_tab() {
        let mut previous = notify_tree(11, false);
        let pane = &mut previous.workspaces_mut()[0].screens[0].panes[0];
        let mut second = pane.tabs[0].clone();
        second.surface = 12;
        pane.tabs.push(second);
        pane.active_tab = 0;

        let mut other_client_selection = previous.clone();
        other_client_selection.workspaces_mut()[0].screens[0].panes[0].active_tab = 1;
        preserve_client_view(&previous, &mut other_client_selection);
        assert_eq!(
            other_client_selection.workspaces()[0].screens[0].panes[0].active_surface(),
            Some(11)
        );
    }

    #[test]
    fn remote_tree_refresh_scales_to_one_thousand_workspaces() {
        let mut previous = TreeView::default();
        for index in 0..1_000_u64 {
            let mut workspace = notify_tree(40_000 + index * 2, false).workspaces_mut().remove(0);
            workspace.id = 10_000 + index;
            workspace.key = format!("workspace-{index}");
            let screen = &mut workspace.screens[0];
            screen.id = 20_000 + index;
            let pane = &mut screen.panes[0];
            pane.id = 30_000 + index;
            screen.active_pane = pane.id;
            screen.layout = Node::Leaf(pane.id);
            let mut second = pane.tabs[0].clone();
            second.surface += 1;
            pane.tabs.push(second);
            pane.active_tab = (index % 2) as usize;
            previous.workspaces_mut().push(workspace);
        }
        previous.active_workspace = 999;

        let expected_active_workspace = previous.active_workspace().unwrap().id;
        let expected_surfaces = previous
            .workspaces()
            .iter()
            .map(|workspace| {
                let pane = &workspace.screens[0].panes[0];
                (workspace.id, pane.active_surface().unwrap())
            })
            .collect::<HashMap<_, _>>();
        let mut refreshed = previous.clone();
        refreshed.workspaces_mut().reverse();
        refreshed.active_workspace = 0;
        for workspace in refreshed.workspaces_mut() {
            workspace.screens[0].panes[0].active_tab ^= 1;
        }

        preserve_client_view(&previous, &mut refreshed);

        assert_eq!(refreshed.active_workspace().unwrap().id, expected_active_workspace);
        for workspace in refreshed.workspaces() {
            let pane = &workspace.screens[0].panes[0];
            assert_eq!(pane.active_surface(), expected_surfaces.get(&workspace.id).copied());
        }
    }

    #[test]
    fn missing_pane_resource_identity_is_deferred_to_the_session_worker() {
        let mux = Mux::new("missing-pane-resource-identity", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.tree = notify_tree(11, false);

        assert_eq!(
            app.pane_creation_selector_candidates(2, None)
                .expect("a transient missing selector must not terminate the event loop"),
            Vec::new()
        );
    }

    #[test]
    fn remote_tree_refresh_keeps_restored_zoom_and_focus_aligned() {
        let mut previous = notify_tree(11, false);
        let screen = &mut previous.workspaces_mut()[0].screens[0];
        let mut second = screen.panes[0].clone();
        second.id = 5;
        second.tabs[0].surface = 12;
        screen.panes.push(second);
        screen.layout = Node::Split {
            id: 9,
            dir: SplitDir::Right,
            ratio: 0.5,
            a: Box::new(Node::Leaf(2)),
            b: Box::new(Node::Leaf(5)),
        };
        screen.active_pane = 5;

        let mut restored = previous.clone();
        let restored_screen = &mut restored.workspaces_mut()[0].screens[0];
        restored_screen.zoomed_pane = Some(2);
        restored_screen.active_pane = 2;

        preserve_client_view(&previous, &mut restored);

        let restored_screen = &restored.workspaces()[0].screens[0];
        assert_eq!(restored_screen.zoomed_pane, Some(2));
        assert_eq!(restored_screen.active_pane, 2);
    }

    fn row_contains(buffer: &ratatui::buffer::Buffer, y: u16, needle: &str) -> bool {
        (0..buffer.area.width).any(|x| buffer[(x, y)].symbol() == needle)
    }

    fn buffer_text(buffer: &ratatui::buffer::Buffer) -> String {
        (0..buffer.area.height)
            .map(|y| (0..buffer.area.width).map(|x| buffer[(x, y)].symbol()).collect::<String>())
            .collect::<Vec<_>>()
            .join("\n")
    }

    fn test_temp_dir(name: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "cmux-tui-app-{name}-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).unwrap();
        path
    }

    fn test_mux(
        name: &str,
        cwd: Option<&std::path::Path>,
    ) -> (Arc<Mux>, Arc<cmux_tui_core::Surface>) {
        let mux = Mux::new(
            name,
            SurfaceOptions {
                command: Some(vec!["/bin/sleep".to_string(), "300".to_string()]),
                cwd: cwd.map(|path| path.to_string_lossy().into_owned()),
                ..Default::default()
            },
        );
        let surface = mux.new_workspace(Some("work".to_string()), Some((20, 8))).unwrap();
        (mux, surface)
    }
}

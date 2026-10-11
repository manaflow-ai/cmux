//! Unit tests for the TUI app, one topic file per area under `app/tests/`.
//! This root holds the shared imports and test helpers (test apps, fake
//! machine controllers, tree and buffer helpers) that the topic files reach
//! through `use super::*`.

mod deferred_input;
mod graphics_pointer;
mod host_input;
mod machine_sidebar;
mod menus_browser;
mod mux_recovery;
mod projection_actions;
mod provider_switch;
mod provider_workspaces;
mod pty_mouse;
mod remote_pointer;
mod selection_clicks;
mod session_notices;
mod shortcuts_menus;
mod surface_attach;
mod viewport_history;

use super::{
    AgentOrderCache, App, AppEvent, BACKGROUND_REFRESH_RETRIES, BrowserResizeFailure, ContextMenu,
    DEFERRED_INPUT_CAPACITY, DeferredInput, DeferredInputAdmission, DeferredInputQueue,
    DeferredReplayDisposition, Drag, EventCancellation, FocusTarget, ForwardMuxOutcome,
    FrontendJournalQueue, FrontendJournalWorker, GraphicIdentity, GraphicPlacement,
    GraphicSourceRect, GraphicsSceneCache, GuardedMouseEncode, HostInputIngress, HostInputMessage,
    HostInputRuntime, MachineActionWorker, MachineConnectRoute, MenuAction, MenuItem,
    MutationImpact, MuxTitleIngress, OmnibarHit, OmnibarState, OrderedSession, OuterCursorSpec,
    PaneArea, PaneAreaProjection, PaneContentGeneration, PaneEdge, PaneFocusHistory,
    PaneResizeDragTarget, PaneViewportClip, PendingSessionMutation, PendingSessionMutationState,
    PointerHitIdentity, PointerRouteIdentity, PointerRoutePhase, Prompt, PromptTarget,
    PtyFailureIngress, PtyMousePressResult, RailKind, RenderAction, RenderedMenuLevel,
    RenderedPaneRoute, RenderedPointerFrame, Selection, SelectionMode, SessionCompletion,
    SessionCompletionAction, SessionEventSender, ShortcutHelp, SidebarActionTarget, SidebarLayout,
    SidebarPluginSyncClaim, SidebarPluginSyncState, SidebarWidthOverrides, StatusTemplateValues,
    StatusWorkerStop, StdoutLock, SurfaceAttachClaimState, SurfaceResizeDecision,
    SurfaceResizeOwnership, TERMINAL_PAINT_CADENCE, TerminalInput, TerminalPaintPacer,
    TerminalPointerAdmission, TerminalPointerAdmissionResult, TerminalPointerEncoding, TextInput,
    Toast, VIEWPORT_ANIMATION_DURATION, ViewportMotion, ViewportPaneAreaProjection,
    WorkspaceRailSelection, action_available_in_mode, browser_content_size_for_rect,
    browser_frame_source_crop, browser_hover_forward_allowed, browser_source_crop,
    canonical_terminal_content, catch_renderer_panic, clamp_split_ratio_for_tab_bars,
    client_menu_item, clip_horizontal_rect, content_size_for_rect, disable_host_keyboard_protocol,
    enable_host_keyboard_protocol, expand_status_tokens, first_pane_by_id, forward_host_input,
    forward_mux_event, forward_mux_events, host_mouse_capture_escape_if_changed,
    host_startup_input_modes, initial_applied_outer_cursor, initial_host_mouse_capture,
    keyboard_protocol_accepts, layout_undo_error_completion, negotiate_host_keyboard_protocol_with,
    outer_cursor_escape, outer_cursor_escape_if_changed, pane_area_projection_work,
    pane_context_menu_groups, pane_parts_for_rect, prepare_ordered_session, preserve_client_view,
    rail_drag_width, rebuild_pane_areas, record_surface_resize_dispatch_result,
    report_after_unwind, reset_pane_area_projection_work, run_status_command,
    send_bounded_cancelable, should_claim_clear_history_shortcut, sidebar_layout_for,
    sidebar_layout_for_state, sidebar_plugin_status_settles_passive_claim, start_ordered_session,
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
    MuxEvent, Node, PointerSnapshotProbe, Rect, SplitDir, SurfaceId, SurfaceKind, SurfaceOptions,
    VirtualRect, ZoomMode, layout_screen, server,
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

enum FakeMachineAction {
    Return(Box<MachineActionResult>),
    Fail(&'static str),
}

struct FakeMachineController {
    actions: VecDeque<FakeMachineAction>,
    requests: Arc<Mutex<Vec<MachineRequest>>>,
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

pub(super) fn test_app(session: Session) -> App {
    test_app_with_events(session).0
}

/// Handles app events until no session mutation is pending. Each wait is
/// bounded by [`crate::test_wait::EVENT`]; a timeout names the pending
/// counts, the elapsed time and the settlements already handled, so a lost
/// settlement can be told apart from a slow one (a full-suite failure of
/// right_button_capture_cannot_cross_a_new_pairing_dialog, not reproduced).
fn settle_pending_mutations(app: &mut App, events: &Receiver<AppEvent>) {
    let started = Instant::now();
    let mut handled = Vec::new();
    while app.session.has_pending_mutations() {
        let event = events.recv_timeout(crate::test_wait::EVENT).unwrap_or_else(|error| {
            panic!(
                "no session mutation settlement within {:?} ({error}): pending={} \
                 pending_pointer={} elapsed={:?} handled={handled:?}",
                crate::test_wait::EVENT,
                app.session.pending_mutations.load(Ordering::Acquire),
                app.session.pending_pointer_mutations.load(Ordering::Acquire),
                started.elapsed(),
            )
        });
        handled.push(match &event {
            AppEvent::SessionMutationSettled { impact, .. } => format!("settled {impact:?}"),
            other => format!("{:?}", std::mem::discriminant(other)),
        });
        app.handle(event).unwrap();
    }
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

fn test_mux(name: &str, cwd: Option<&std::path::Path>) -> (Arc<Mux>, Arc<cmux_tui_core::Surface>) {
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

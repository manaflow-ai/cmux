//! TUI entry point: `RunRequest`, `run_with_machine_updates` and its inner
//! loop setup, plus panic diagnostics around the renderer.

use std::collections::{HashMap, HashSet, VecDeque};
use std::io::Write;
use std::panic::AssertUnwindSafe;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64};
use std::sync::{Arc, Mutex};

use cmux_tui_cdp::CDP_CONNECTION_UNAVAILABLE_MESSAGE;
use cmux_tui_core::resource::FrontendProjectionPublicId;
use cmux_tui_core::{Mux, MuxEvent, Rect, SurfaceId};
use crossbeam_channel::bounded as sync_channel;
use crossterm::ExecutableCommand;
use crossterm::terminal::{EnterAlternateScreen, enable_raw_mode};
use ghostty_vt::KeyEncoder;
use ratatui::Terminal as RatatuiTerminal;
use ratatui::backend::CrosstermBackend;

use crate::app::events::{AppEvent, OwnerReloadWorker};
use crate::app::frame_geometry::{
    SidebarWidthOverrides, content_size_for_rect, sidebar_layout_for,
};
use crate::app::frontend_journal::FrontendJournalWorker;
use crate::app::graphics::GraphicsSceneCache;
use crate::app::host_input::{HostInputRuntime, read_crossterm_event};
use crate::app::layout::{FocusTarget, SidebarLayout};
use crate::app::machine_worker::{
    MachineActionWorker, ensure_initial_for_machine_ui, ensure_managed_workspace_guard,
    install_mux_diagnostic_logger, recover_initial_workspace_failure,
};
use crate::app::mux_ingress::{PtyFailureIngress, start_ordered_session};
use crate::app::pane_projection::ViewportPaneAreaProjection;
use crate::app::pointer::deferred::{DeferredInputQueue, OuterCursorSpec, PointerRoutePhase};
use crate::app::pointer::route::RenderedPointerFrame;
use crate::app::selection::SelectionMode;
use crate::app::terminal_guard::{
    TerminalRestoreGuard, negotiate_host_keyboard_protocol, restore_terminal_unlocked,
    terminal_restore_error, with_panic_stdout_lock,
};
use crate::app::{
    APP_EVENT_CAPACITY, App, PaneFocusHistory, WorkspaceRailSelection, client_focus_identity,
    host_startup_input_modes, initial_applied_outer_cursor, initial_host_mouse_capture,
    publishes_global_cell_metrics,
};
use crate::browser_input::BrowserInputDispatcher;
use crate::config::ChromeTheme;
use crate::localization;
use crate::machine::{MachineController, MachineRequest, MachineUiState};
use crate::pty_input::PtyInputDispatcher;
use crate::session::{Session, TreeView};
use crate::sidebar_files::FileBrowser;
use crate::sidebar_projection::AgentOrderCache;
use crate::ui::ReusableRowBuffer;
use crate::ui::graphics_writer::{
    GraphicsResponseFilter, GraphicsWriter, StdoutLock, graphics_fence_channel,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RunOutcome {
    Quit,
    Machine(MachineRequest),
}

/// Everything one interactive TUI run receives from the launcher.
pub struct RunRequest {
    pub session: Session,
    pub session_label: String,
    pub default_colors: cmux_tui_core::DefaultColors,
    pub surface_only: Option<SurfaceId>,
    pub owner_mux: Option<Arc<Mux>>,
    pub machine_ui: Option<MachineUiState>,
    pub machine_controller: Option<Box<dyn MachineController>>,
    pub startup_config: crate::config::StartupConfigSnapshot,
}

pub fn run_with_machine_updates(request: RunRequest) -> anyhow::Result<RunOutcome> {
    type PanicHook = dyn for<'a> Fn(&std::panic::PanicHookInfo<'a>) + Send + Sync + 'static;
    let previous_panic_hook: Arc<PanicHook> = Arc::from(std::panic::take_hook());
    let previous_panic_hook_for_threads = previous_panic_hook.clone();
    let run_thread = std::thread::current().id();
    let panic_diagnostic = Arc::new(Mutex::new(None));
    let panic_diagnostic_hook = panic_diagnostic.clone();
    std::panic::set_hook(Box::new(move |info| {
        if std::thread::current().id() == run_thread {
            *panic_diagnostic_hook.lock().unwrap() = Some(format_panic_diagnostic(info));
        } else {
            previous_panic_hook_for_threads(info);
        }
    }));
    let result =
        std::panic::catch_unwind(AssertUnwindSafe(|| run_with_machine_updates_inner(request)));
    let _ = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| previous_panic_hook(info)));

    let result = report_after_unwind(result, || {
        if let Some(diagnostic) = panic_diagnostic.lock().unwrap().take() {
            eprint!("{diagnostic}");
        }
    });
    match result {
        Ok(result) => result,
        Err(payload) => std::panic::resume_unwind(payload),
    }
}

pub(super) fn run_with_machine_updates_inner(request: RunRequest) -> anyhow::Result<RunOutcome> {
    let RunRequest {
        session,
        session_label,
        default_colors,
        surface_only,
        owner_mux,
        machine_ui,
        machine_controller,
        startup_config,
    } = request;
    if let Session::Local(mux) = &session {
        install_mux_diagnostic_logger(mux);
    }
    if let Some(mux) = owner_mux.as_ref() {
        install_mux_diagnostic_logger(mux);
    }
    let mut config = startup_config.into_config();
    let chrome = ChromeTheme::for_defaults(config.chrome, default_colors);
    config.apply_chrome_defaults(chrome);
    let session_available = machine_ui.as_ref().is_none_or(|machine| machine.session_available);
    // First workspace before the terminal switches modes, so a spawn
    // failure prints a normal error. Spawn at the size the first pane
    // will actually render at (a post-spawn resize makes shells like zsh
    // repaint their prompt, leaving a reverse-video % artifact). The
    // pane's border box eats one cell on every side.
    let initial_size = crossterm::terminal::size().ok().map(|(w, h)| {
        if surface_only.is_some() {
            return (w.max(1), h.max(1));
        }
        let pane = sidebar_layout_for(
            &config,
            true,
            false,
            machine_ui.is_some(),
            (w, h),
            SidebarWidthOverrides::default(),
        )
        .content;
        content_size_for_rect(pane, config.scrollbar.position, config.pane.padding)
            .unwrap_or((1, 1))
    });
    ensure_managed_workspace_guard(&session, machine_ui.as_ref())?;
    let initial_workspace_error = recover_initial_workspace_failure(
        ensure_initial_for_machine_ui(&session, initial_size, machine_ui.as_ref()),
        machine_ui.as_ref(),
    )?;
    let encoder = KeyEncoder::new()?;
    let (tx, rx) = sync_channel::<AppEvent>(APP_EVENT_CAPACITY);
    let owner_reload_worker =
        owner_mux.as_deref().map(|mux| OwnerReloadWorker::spawn(mux, tx.clone())).transpose()?;
    let host_input = HostInputRuntime::new();
    let browser_failure_tx = tx.clone();
    let browser_control_tx = tx.clone();
    let browser_input = BrowserInputDispatcher::spawn(
        move |failure| {
            let _ = browser_failure_tx.send(AppEvent::BrowserResizeFailed(failure));
        },
        move |error| {
            crate::client_log::error("browser-control", &error);
            // The dispatcher exposes only a string. Match the one stable CDP
            // classification and discard every other internal detail before
            // creating a user-facing status event.
            let browser = &localization::catalog().browser;
            let message = if error == CDP_CONNECTION_UNAVAILABLE_MESSAGE {
                localization::catalog().browser.control_unavailable()
            } else if error == browser.attach_unsupported {
                browser.control_failed(browser.attach_unsupported)
            } else {
                // Keep the failure category stable. The raw error is already
                // in the private diagnostic log and must not cross this UI boundary.
                browser.control_failed("browser operation failed")
            };
            let _ = browser_control_tx.send(AppEvent::Mux(MuxEvent::Status(message)));
        },
    )?;
    let failure_tx = tx.clone();
    let pty_failures = Arc::new(PtyFailureIngress::default());
    let failure_ingress = pty_failures.clone();
    let pty_input = PtyInputDispatcher::spawn(move |failure| {
        if failure_ingress.push(failure) {
            // This is a latency hint, not the ownership path. The event loop
            // drains the ingress after every batch and timeout, including
            // when this bounded app channel is currently full.
            let _ = failure_tx.try_send(AppEvent::PtyFailuresReady);
        }
    })?;
    let session_generation = 1;
    let (session, session_event_worker, mux_titles, mux_recovery_generation) =
        start_ordered_session(
            session,
            pty_input.sender(),
            tx.clone(),
            session_generation,
            surface_only,
        )?;
    let stdout_lock = Arc::new(StdoutLock::new(()));
    let machine_action_worker = machine_controller
        .map(|controller| MachineActionWorker::spawn(controller, tx.clone()))
        .transpose()?;

    // One line per launch, so every stretch of the log names the build that
    // produced it. Sink initialization is asynchronous (writer thread), so
    // this never blocks startup however slow the log target is.
    crate::client_log::info("startup", &crate::version_string());
    enable_raw_mode()?;
    // The TUI owns the terminal now: stray stderr writes (panics, libraries)
    // would corrupt the raw-mode screen, so route fd 2 into the client log.
    crate::client_log::redirect_stderr_into_log();
    let mut terminal_restore = TerminalRestoreGuard::new(stdout_lock.clone());
    terminal_restore.set_host_input_shutdown(host_input.shutdown_control());
    if let Err(e) = (|| -> anyhow::Result<()> {
        let _guard = stdout_lock.lock();
        stdout_lock.recover_stream_locked()?;
        let mut stdout = std::io::stdout();
        stdout.execute(EnterAlternateScreen)?;
        Ok(())
    })() {
        return Err(terminal_restore.restore_after_error(e));
    }

    // Probe before enabling application input modes. Any keys read alongside
    // terminal replies are parsed and queued into the same app channel below.
    let terminal_probe = crate::ui::graphics::probe_terminal(None);
    let cell_pixels = terminal_probe.cell_pixels;
    if session_available && publishes_global_cell_metrics(surface_only) {
        session.set_cell_pixel_size(cell_pixels.0, cell_pixels.1);
    }
    let graphics_supported =
        terminal_probe.graphics_supported && GraphicsWriter::platform_supported();
    let pending_input = terminal_probe.pending_input;
    let (graphics_fence_waiter, graphics_fence_notifier) = graphics_fence_channel();

    if let Err(e) = (|| -> anyhow::Result<()> {
        let _guard = stdout_lock.lock();
        let mut stdout = std::io::stdout();
        negotiate_host_keyboard_protocol(
            &mut stdout,
            terminal_restore.host_keyboard_protocol_mut(),
        )?;
        stdout.write_all(host_startup_input_modes(surface_only.is_some()).as_bytes())?;
        stdout.flush()?;
        Ok(())
    })() {
        return Err(terminal_restore.restore_after_error(e));
    }

    // Crossterm input has a separate retained ingress. Start this after
    // startup terminal probes so their replies cannot be consumed as key
    // input. Backpressure here must never block mutation completions.
    let input = host_input.producer(tx.clone());
    let input_reader = match std::thread::Builder::new().name("input".into()).spawn(move || {
        for event in crate::ui::graphics::finish_startup_input(pending_input) {
            if !input.send(event) {
                return;
            }
        }
        let mut graphics_responses = GraphicsResponseFilter::new(graphics_fence_notifier);
        'input: loop {
            if input.ingress.is_closed() {
                break 'input;
            }
            let events = match read_crossterm_event(
                graphics_responses.time_until_expiry(),
                crossterm::event::poll,
                crossterm::event::read,
            ) {
                Ok(Some(event)) => graphics_responses.filter(event),
                Ok(None) => graphics_responses.take_expired(),
                Err(error) => {
                    input.fail(error.to_string());
                    break 'input;
                }
            };
            for event in events {
                if !input.send(event) {
                    break 'input;
                }
            }
        }
    }) {
        Ok(reader) => reader,
        Err(error) => return Err(terminal_restore.restore_after_error(error.into())),
    };
    host_input.attach_reader(input_reader);

    let graphics_writer = if graphics_supported {
        let graphics_ready = tx.clone();
        match GraphicsWriter::spawn(stdout_lock.clone(), graphics_fence_waiter, move || {
            // Latency hint only. The completion stays in GraphicsWriter, and
            // the event loop drains it after every event batch and timeout.
            let _ = graphics_ready.try_send(AppEvent::GraphicsWriterReady);
        }) {
            Ok(writer) => Some(writer),
            Err(error) => return Err(terminal_restore.restore_after_error(error.into())),
        }
    } else {
        None
    };
    let graphics_shutdown = graphics_writer.as_ref().map(GraphicsWriter::shutdown_control);
    terminal_restore.set_graphics_shutdown(graphics_shutdown.clone());

    // Restore the host terminal even if we panic mid-frame.
    let default_hook = std::panic::take_hook();
    let restore_lock = stdout_lock.clone();
    let panic_keyboard_protocol = terminal_restore.host_keyboard_protocol().clone();
    let panic_host_input_shutdown = host_input.shutdown_control();
    let panic_graphics_shutdown = graphics_shutdown;
    std::panic::set_hook(Box::new(move |info| {
        panic_host_input_shutdown.shutdown();
        if let Some(graphics_shutdown) = &panic_graphics_shutdown {
            graphics_shutdown.cancel_for_panic_hook();
        }
        with_panic_stdout_lock(&restore_lock, || {
            let _ = restore_terminal_unlocked(&panic_keyboard_protocol);
        });
        default_hook(info);
    }));

    let backend = CrosstermBackend::new(std::io::stdout());
    let mut terminal = match RatatuiTerminal::new(backend) {
        Ok(terminal) => terminal,
        Err(e) => {
            return Err(terminal_restore.restore_after_error(e.into()));
        }
    };
    let sidebar_view = config.sidebar.view;
    let fallback_cwd = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    let initial_machine_notice = initial_workspace_error
        .or_else(|| machine_ui.as_ref().and_then(|machine| machine.notice.clone()));
    let machine_selection_intent = machine_ui.as_ref().and_then(|machine| machine.snapshot.active);
    let machine_presented = machine_ui.as_ref().and_then(|machine| machine.snapshot.active);
    let owner_machine = owner_mux
        .as_ref()
        .and_then(|_| machine_ui.as_ref().and_then(|machine| machine.snapshot.active));
    let frontend_journal = match FrontendJournalWorker::spawn() {
        Ok(worker) => worker,
        Err(error) => return Err(terminal_restore.restore_after_error(error)),
    };
    let frontend_projection_id = match FrontendProjectionPublicId::random() {
        Ok(id) => id,
        Err(error) => return Err(terminal_restore.restore_after_error(error.into())),
    };
    let mut app = App {
        session,
        owner_mux,
        owner_machine,
        owner_reload_worker,
        session_event_worker: Some(session_event_worker),
        session_generation,
        app_events: tx,
        frontend_journal,
        frontend_projection_id,
        last_frontend_presentation: None,
        outer_size: (0, 0),
        host_input,
        machine_action_worker,
        machine_action_in_flight: false,
        machine_action_request: None,
        machine_action_connection_attempt: None,
        canceled_machine_connection_attempt: None,
        machine_action_intent_generation: None,
        machine_selection_intent,
        machine_selection_generation: 0,
        machine_presented,
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
        config,
        #[cfg(test)]
        config_reload_applications: 0,
        chrome,
        tree: TreeView::default(),
        tab_locations: HashMap::new(),
        render_states: HashMap::new(),
        chrome_row_scratch: ReusableRowBuffer::default(),
        sidebar_kind_scratch: Vec::new(),
        rendered_terminal_sizes: HashMap::new(),
        rendered_terminal_pointer_semantics: HashMap::new(),
        rendered_pane_content_generations: HashMap::new(),
        desired_outer_cursor: OuterCursorSpec::Reset,
        applied_outer_cursor: initial_applied_outer_cursor(surface_only.is_some()),
        host_mouse_capture_applied: initial_host_mouse_capture(surface_only.is_some()),
        graphics_writer,
        next_graphics_submission: 0,
        pending_graphics_submission: None,
        pending_graphics_snapshot: None,
        pending_graphics_affected_rect: None,
        last_graphics_snapshot: Vec::new(),
        graphics_supported,
        graphics_host_scene_reset_pending: false,
        graphics_scene_cache: GraphicsSceneCache::default(),
        graphics_dirty_surfaces: HashSet::new(),
        stdout_lock,
        pane_areas: Vec::new(),
        viewport_projection: ViewportPaneAreaProjection::default(),
        viewport_layout: Vec::new(),
        viewport_stacked_headers: HashSet::new(),
        viewport_states: HashMap::new(),
        viewport_virtual_width: 0,
        viewport_offset: 0,
        pane_focus_history: PaneFocusHistory::default(),
        reported_focus: None,
        client_focus_id: client_focus_identity(),
        rendered_terminal_bounds: HashMap::new(),
        rendered_kitty_graphics: HashMap::new(),
        visible_size_surfaces: HashSet::new(),
        pending_size_releases: HashSet::new(),
        geometry_authority_surface: None,
        prefix_armed: false,
        session_label,
        surface_only,
        sidebar_visible: surface_only.is_none(),
        sidebar_compact: false,
        focus: FocusTarget::Pane,
        sidebar_focus_pending: false,
        machine_ui,
        machine_pointer_context_cache: None,
        sidebar_view,
        sidebar_files: FileBrowser::new(fallback_cwd),
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
        status_message: initial_machine_notice,
        cell_pixels,
        pointer_shape: false,
        last_browser_hover: None,
        browser_input,
        pty_input,
        deferred_input: DeferredInputQueue::default(),
        pending_pointer_motion: None,
        deferred_input_sequence: 0,
        next_semantic_destination_intent: 0,
        latest_semantic_destination_intent: None,
        semantic_destination_outcomes: HashMap::new(),
        rendered_pointer_frame: RenderedPointerFrame::default(),
        pointer_route_phase: PointerRoutePhase::DrawPending,
        pointer_focus_generation: 0,
        layout_refresh_retries_remaining: 0,
        background_refresh_attempts: 0,
        background_refresh_retry_at: None,
        last_applied_refresh_sequence: 0,
        applied_destination_generation: 0,
        pending_session_completions: VecDeque::new(),
        mux_titles,
        pty_failures,
        mux_recovery_generation,
        drag: None,
        active_pointer_buttons: HashSet::new(),
        ignored_pty_mouse_buttons: HashSet::new(),
        #[cfg(test)]
        timeout_drain_hook: None,
        encoder,
        encode_buf: Vec::with_capacity(64),
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
    app.ensure_status_command_worker();
    if app.session_available() {
        app.session.refresh_clients_background();
        app.session.refresh_machine_usage_background();
    }

    if let Err(error) = app.restart_machine_updates() {
        app.shutdown_runtime_components();
        return Err(terminal_restore.restore_after_error(error));
    }

    if let Some(owner) = app.owner_mux.as_ref() {
        owner.mark_server_lifecycle_ready();
    }

    let result = app.event_loop(&mut terminal, rx);
    app.shutdown_runtime_components();
    let restore_result = terminal_restore.restore();
    match (result, restore_result) {
        (Ok(()), Ok(())) => {}
        (Ok(()), Err(error)) | (Err(error), Ok(())) => return Err(error),
        (Err(error), Err(restore_error)) => {
            return Err(terminal_restore_error(error, restore_error));
        }
    }
    let outcome = app
        .machine_ui
        .and_then(|machine| machine.request)
        .map(RunOutcome::Machine)
        .unwrap_or(RunOutcome::Quit);
    Ok(outcome)
}

pub(super) fn format_panic_diagnostic(info: &std::panic::PanicHookInfo<'_>) -> String {
    let payload = info
        .payload()
        .downcast_ref::<&str>()
        .copied()
        .or_else(|| info.payload().downcast_ref::<String>().map(String::as_str))
        .unwrap_or("Box<dyn Any>");
    let thread = std::thread::current();
    let thread_name = thread.name().unwrap_or("<unnamed>");
    let location = info
        .location()
        .map(|location| location.to_string())
        .unwrap_or_else(|| "<unknown>".to_string());
    let mut diagnostic = format!("thread '{thread_name}' panicked at {location}:\n{payload}\n");
    let backtrace = std::backtrace::Backtrace::capture();
    if backtrace.status() == std::backtrace::BacktraceStatus::Captured {
        diagnostic.push_str(&format!("{backtrace}\n"));
    }
    diagnostic
}

pub(super) fn report_after_unwind<T>(
    result: std::thread::Result<T>,
    report: impl FnOnce(),
) -> std::thread::Result<T> {
    if result.is_err() {
        report();
    }
    result
}

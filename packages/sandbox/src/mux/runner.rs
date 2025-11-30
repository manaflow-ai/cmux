use anyhow::Result;
use crossterm::{
    cursor::SetCursorStyle,
    event::{
        DisableBracketedPaste, DisableMouseCapture, EnableBracketedPaste, EnableMouseCapture,
        Event, EventStream, KeyCode, KeyEventKind, KeyModifiers, KeyboardEnhancementFlags,
        PopKeyboardEnhancementFlags, PushKeyboardEnhancementFlags,
    },
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
};
use futures::StreamExt;
use ratatui::{backend::CrosstermBackend, Terminal};
use std::path::PathBuf;
use std::time::Duration;
use tokio::sync::mpsc;
use tokio::time::MissedTickBehavior;

use crate::mux::commands::MuxCommand;
use crate::mux::events::MuxEvent;
use crate::mux::layout::{ClosedTabInfo, PaneContent, PaneExitOutcome, SandboxId, TabId};
use crate::mux::state::{FocusArea, MuxApp};
use crate::mux::terminal::{connect_to_sandbox, create_terminal_manager, request_list_sandboxes};
use crate::mux::ui::ui;
use crate::sync_files::{detect_sync_files, upload_sync_files_with_list};

/// Run the multiplexer TUI.
///
/// If `workspace_path` is provided, sandboxes created during the session will upload
/// that directory (defaulting to the current working directory).
pub async fn run_mux_tui(base_url: String, workspace_path: Option<PathBuf>) -> Result<()> {
    let mut stdout = std::io::stdout();
    execute!(
        stdout,
        EnterAlternateScreen,
        EnableMouseCapture,
        EnableBracketedPaste,
        PushKeyboardEnhancementFlags(KeyboardEnhancementFlags::all())
    )?;
    enable_raw_mode()?;

    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend)?;

    let result = run_main_loop(&mut terminal, base_url, workspace_path).await;

    // Cleanup must happen in reverse order, and PopKeyboardEnhancementFlags
    // must be sent BEFORE LeaveAlternateScreen to properly restore terminal state.
    // Print errors but continue cleanup to ensure all steps run.
    if let Err(e) = disable_raw_mode() {
        eprintln!("Warning: failed to disable raw mode: {e}");
    }
    if let Err(e) = execute!(
        terminal.backend_mut(),
        PopKeyboardEnhancementFlags,
        DisableBracketedPaste,
        DisableMouseCapture,
        LeaveAlternateScreen
    ) {
        eprintln!("Warning: failed to restore terminal state: {e}");
    }
    if let Err(e) = terminal.show_cursor() {
        eprintln!("Warning: failed to show cursor: {e}");
    }

    result
}

async fn run_main_loop<B: ratatui::backend::Backend + std::io::Write>(
    terminal: &mut Terminal<B>,
    base_url: String,
    workspace_path: Option<PathBuf>,
) -> Result<()> {
    let workspace = workspace_path
        .unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")));
    let (event_tx, event_rx) = mpsc::unbounded_channel();

    let mut app = MuxApp::new(base_url.clone(), event_tx.clone(), workspace.clone());

    // Create terminal manager
    let terminal_manager = create_terminal_manager(base_url.clone(), event_tx.clone());
    app.set_terminal_manager(terminal_manager.clone());

    // Start background task to periodically refresh sandboxes
    let refresh_tx = event_tx.clone();
    let refresh_url = base_url.clone();
    tokio::spawn(async move {
        refresh_sandboxes_periodically(refresh_url, refresh_tx).await;
    });

    // Always create a new sandbox on startup with the current working directory
    let init_tx = event_tx.clone();
    let init_url = base_url.clone();
    let initial_workspace = workspace.clone();
    tokio::spawn(async move {
        // First refresh to populate sidebar
        let _ = refresh_sandboxes(&init_url, &init_tx).await;

        let _ = init_tx.send(MuxEvent::CreateSandboxWithWorkspace {
            workspace_path: initial_workspace,
            tab_id: Some(TabId::new().to_string()),
        });
    });

    run_app(terminal, app, event_rx, terminal_manager).await
}

async fn run_app<B: ratatui::backend::Backend + std::io::Write>(
    terminal: &mut Terminal<B>,
    mut app: MuxApp<'_>,
    mut event_rx: mpsc::UnboundedReceiver<MuxEvent>,
    terminal_manager: crate::mux::terminal::SharedTerminalManager,
) -> Result<()> {
    let mut reader = EventStream::new();
    let mut redraw_needed = true;
    let mut status_tick = tokio::time::interval(Duration::from_millis(33));
    let mut render_tick = tokio::time::interval(Duration::from_millis(8));
    render_tick.set_missed_tick_behavior(MissedTickBehavior::Skip);

    loop {
        tokio::select! {
            _ = status_tick.tick() => {
                let had_status = app.status_message.is_some();
                app.clear_expired_status();
                if had_status && app.status_message.is_none() {
                    redraw_needed = true;
                }
            }
            _ = render_tick.tick(), if redraw_needed => {
                terminal.draw(|f| ui(f, &mut app))?;
                // Apply cursor style based on terminal's cursor blink mode
                let cursor_style = if app.cursor_blink {
                    SetCursorStyle::BlinkingBlock
                } else {
                    SetCursorStyle::SteadyBlock
                };
                let _ = execute!(terminal.backend_mut(), cursor_style);
                sync_terminal_sizes(&app, &terminal_manager);
                redraw_needed = false;
            }
            Some(event) = event_rx.recv() => {
                match &event {
                    MuxEvent::ConnectToSandbox { sandbox_id } => {
                        app.pending_connect = Some(sandbox_id.clone());
                        try_consume_pending_connection(&mut app, &terminal_manager);
                    }
                    MuxEvent::CreateSandboxWithWorkspace {
                        workspace_path,
                        tab_id,
                    } => {
                        let event_tx = app.event_tx.clone();
                        let base_url = app.base_url.clone();
                        let workspace_path = workspace_path.clone();
                        let tab_id_value =
                            tab_id.clone().unwrap_or_else(|| TabId::new().to_string());
                        if let Ok(uuid) = uuid::Uuid::parse_str(&tab_id_value) {
                            app.pending_creation_tab_ids
                                .push_back(TabId::from_uuid(uuid));
                        }
                        tokio::spawn(async move {
                            if let Err(error) = create_sandbox_with_workspace(
                                base_url,
                                workspace_path,
                                Some(tab_id_value),
                                event_tx.clone(),
                            )
                            .await
                            {
                                let _ = event_tx.send(MuxEvent::Error(format!(
                                    "Failed to create sandbox: {}",
                                    error
                                )));
                            }
                        });
                    }
                    MuxEvent::ConnectActivePaneToSandbox => {
                        let target = app
                            .selected_sandbox_id_string()
                            .or_else(|| app.pending_connect.clone());
                        if let Some(sandbox_id) = target {
                            app.pending_connect = Some(sandbox_id);
                            try_consume_pending_connection(&mut app, &terminal_manager);
                        }
                    }
                    MuxEvent::StatusMessage { message } if message.contains("Refreshing sandboxes") => {
                        // Request sandbox list via WebSocket - server responds with SandboxList
                        let manager = terminal_manager.clone();
                        let event_tx = app.event_tx.clone();
                        tokio::spawn(async move {
                            if let Err(e) = request_list_sandboxes(manager).await {
                                let _ = event_tx.send(MuxEvent::Error(format!(
                                    "Failed to refresh sandboxes: {}",
                                    e
                                )));
                            }
                        });
                        app.set_status(message.clone());
                    }
                    MuxEvent::TerminalExited { pane_id, sandbox_id } => {
                        handle_terminal_exit_for_pane(
                            &mut app,
                            &terminal_manager,
                            *pane_id,
                            sandbox_id,
                        );
                    }
                    _ => {}
                }
                app.handle_event(event);
                try_consume_pending_connection(&mut app, &terminal_manager);
                redraw_needed = true;
            }
            Some(Ok(event)) = reader.next() => {
                if handle_input(&mut app, event, &terminal_manager) {
                    break;
                }
                redraw_needed = true;
            }
        }
    }

    Ok(())
}

fn fallback_terminal_size() -> (u16, u16) {
    let (fallback_cols, fallback_rows) = crossterm::terminal::size().unwrap_or((80, 24));
    (fallback_rows, fallback_cols)
}

fn connect_active_pane_to_sandbox(
    app: &MuxApp<'_>,
    terminal_manager: &crate::mux::terminal::SharedTerminalManager,
    sandbox_id: &str,
) {
    let Some(pane_id) = app.active_pane_id() else {
        return;
    };

    if let Ok(guard) = terminal_manager.try_lock() {
        if guard.is_connected(pane_id) {
            return;
        }
    }

    let (rows, cols) = preferred_size_for_pane(app, pane_id).unwrap_or_else(fallback_terminal_size);
    let manager = terminal_manager.clone();
    let event_tx = app.event_tx.clone();
    let sandbox_id = sandbox_id.to_string();
    let tab_id = app.workspace_manager.active_tab_id();

    tokio::spawn(async move {
        if let Err(e) = connect_to_sandbox(manager, pane_id, sandbox_id, tab_id, cols, rows).await {
            let _ = event_tx.send(MuxEvent::Error(format!(
                "Failed to connect to sandbox: {}",
                e
            )));
        }
    });
}

fn try_consume_pending_connection(
    app: &mut MuxApp<'_>,
    terminal_manager: &crate::mux::terminal::SharedTerminalManager,
) {
    let Some(sandbox_id) = app.pending_connect.clone() else {
        return;
    };

    if !app.select_sandbox(&sandbox_id) {
        return;
    }

    app.sidebar.select_by_id(&sandbox_id);

    let Some(pane_id) = app.active_pane_id() else {
        return;
    };

    if let Some(tab) = app.active_tab_mut() {
        if let Some(pane) = tab.layout.find_pane_mut(pane_id) {
            if let PaneContent::Terminal {
                sandbox_id: pane_sandbox,
                ..
            } = &mut pane.content
            {
                *pane_sandbox = Some(sandbox_id.clone());
            }
        }
    }

    let already_connected = terminal_manager
        .try_lock()
        .map(|guard| guard.is_connected(pane_id))
        .unwrap_or(false);

    if already_connected {
        app.pending_connect = None;
        return;
    }

    connect_active_pane_to_sandbox(app, terminal_manager, &sandbox_id);
    app.pending_connect = None;
}

fn pane_content_dimensions(pane: &crate::mux::layout::Pane) -> Option<(u16, u16)> {
    let area = pane.area?;
    let cols = area.width.saturating_sub(2);
    let rows = area.height.saturating_sub(2);

    if cols == 0 || rows == 0 {
        return None;
    }

    Some((rows, cols))
}

fn preferred_size_for_pane(
    app: &MuxApp<'_>,
    pane_id: crate::mux::layout::PaneId,
) -> Option<(u16, u16)> {
    let tab = app.active_tab()?;
    let pane = tab.layout.find_pane(pane_id)?;
    pane_content_dimensions(pane)
}

fn sync_terminal_sizes(
    app: &MuxApp<'_>,
    terminal_manager: &crate::mux::terminal::SharedTerminalManager,
) {
    let Some(tab) = app.active_tab() else {
        return;
    };

    let mut targets: Vec<(crate::mux::layout::PaneId, u16, u16)> = Vec::new();
    for pane in tab.layout.panes() {
        if !matches!(pane.content, PaneContent::Terminal { .. }) {
            continue;
        }
        if let Some((rows, cols)) = pane_content_dimensions(pane) {
            targets.push((pane.id, rows, cols));
        }
    }

    if targets.is_empty() {
        return;
    }

    if let Ok(mut guard) = terminal_manager.try_lock() {
        for (pane_id, rows, cols) in targets {
            let _ = guard.update_view_size(pane_id, rows, cols);
        }
    }
}

fn handle_terminal_exit_for_pane(
    app: &mut MuxApp<'_>,
    terminal_manager: &crate::mux::terminal::SharedTerminalManager,
    pane_id: crate::mux::layout::PaneId,
    sandbox_id: &str,
) {
    let mut pane_ids_to_cleanup = vec![pane_id];

    match app.workspace_manager.handle_pane_exit(pane_id) {
        Some(PaneExitOutcome::TabClosed(info)) => {
            let ClosedTabInfo {
                sandbox_id: info_sandbox,
                sandbox_name,
                tab_name,
                was_active_tab,
                pane_ids,
            } = info;

            pane_ids_to_cleanup = pane_ids;
            app.set_status(format!(
                "Closed tab '{}' in {} (terminal exited)",
                tab_name, sandbox_name
            ));

            if was_active_tab && app.workspace_manager.active_sandbox_id == Some(info_sandbox) {
                app.focus = FocusArea::MainArea;
            }
        }
        Some(PaneExitOutcome::PaneRemoved {
            sandbox_name,
            tab_name,
            ..
        }) => {
            app.set_status(format!(
                "Terminal exited in {} / {} (pane removed)",
                sandbox_name, tab_name
            ));
        }
        None => {
            if !sandbox_id.is_empty() {
                app.set_status(format!("Terminal exited in sandbox {}", sandbox_id));
            }
        }
    }

    if pane_ids_to_cleanup
        .iter()
        .any(|id| Some(*id) == app.zoomed_pane)
    {
        app.zoomed_pane = None;
    }

    if let Ok(mut guard) = terminal_manager.try_lock() {
        for id in pane_ids_to_cleanup {
            guard.remove_pane_state(id);
        }
    }
}

/// Handle input events. Returns true if the app should quit.
fn handle_input(
    app: &mut MuxApp<'_>,
    event: Event,
    terminal_manager: &crate::mux::terminal::SharedTerminalManager,
) -> bool {
    match event {
        Event::Key(key) => {
            if !matches!(key.kind, KeyEventKind::Press | KeyEventKind::Repeat) {
                return false;
            }
            // Handle tab rename mode
            if app.renaming_tab {
                match key.code {
                    KeyCode::Enter => {
                        app.finish_tab_rename(true);
                        return false;
                    }
                    KeyCode::Esc => {
                        app.finish_tab_rename(false);
                        return false;
                    }
                    _ => {
                        if let Some(input) = &mut app.rename_input {
                            input.input(key);
                        }
                        return false;
                    }
                }
            }

            // Handle notifications overlay
            if app.notifications.is_open && app.focus == FocusArea::Notifications {
                match key.code {
                    KeyCode::Esc => {
                        app.close_notifications();
                    }
                    KeyCode::Up | KeyCode::Char('k') => {
                        app.notifications.select_previous();
                    }
                    KeyCode::Down | KeyCode::Char('j') => {
                        app.notifications.select_next();
                    }
                    KeyCode::Enter => {
                        app.notifications.mark_read();
                        if let Some(entry) = app.notifications.selected_item().cloned() {
                            app.open_notification_target(&entry);
                        }
                        app.close_notifications();
                    }
                    KeyCode::Char(' ') => {
                        app.notifications.toggle_read();
                    }
                    KeyCode::Char('r') => {
                        app.notifications.mark_read();
                    }
                    KeyCode::Char('u') => {
                        app.notifications.mark_unread();
                    }
                    _ => {}
                }
                return false;
            }

            // Handle command palette mode
            if app.focus == FocusArea::CommandPalette {
                match key.code {
                    KeyCode::Esc => {
                        app.close_command_palette();
                        return false;
                    }
                    KeyCode::Enter => {
                        if let Some(cmd) = app.command_palette.execute_selection() {
                            app.focus = FocusArea::MainArea;
                            if cmd == MuxCommand::Quit {
                                return true;
                            }
                            app.execute_command(cmd);
                        }
                        return false;
                    }
                    KeyCode::Up => {
                        app.command_palette.select_up();
                        return false;
                    }
                    KeyCode::Down => {
                        app.command_palette.select_down();
                        return false;
                    }
                    _ if key.modifiers.contains(KeyModifiers::CONTROL) => {
                        match key.code {
                            KeyCode::Char('p') | KeyCode::Char('k') => {
                                app.command_palette.select_up();
                            }
                            KeyCode::Char('n') | KeyCode::Char('j') => {
                                app.command_palette.select_down();
                            }
                            KeyCode::Char('c') => {
                                app.close_command_palette();
                            }
                            _ => {
                                app.command_palette.handle_input(key);
                            }
                        }
                        return false;
                    }
                    _ => {
                        app.command_palette.handle_input(key);
                        return false;
                    }
                }
            }

            // Check for command keybindings first
            if let Some(cmd) = MuxCommand::from_key(key.modifiers, key.code) {
                if cmd == MuxCommand::Quit {
                    return true;
                }
                app.execute_command(cmd);
                return false;
            }

            // Handle focus-specific inputs
            match app.focus {
                FocusArea::Sidebar => {
                    match key.code {
                        KeyCode::Up | KeyCode::Char('k') => {
                            app.sidebar.select_previous();
                            // Auto-switch workspace on selection change
                            select_sidebar_sandbox(app);
                        }
                        KeyCode::Down | KeyCode::Char('j') => {
                            app.sidebar.select_next();
                            // Auto-switch workspace on selection change
                            select_sidebar_sandbox(app);
                        }
                        KeyCode::Backspace => {
                            if let Some((sandbox_id, sandbox_name)) = remove_selected_sandbox(app) {
                                let base_url = app.base_url.clone();
                                let event_tx = app.event_tx.clone();

                                app.set_status(format!("Deleting sandbox: {}", sandbox_name));

                                tokio::spawn(async move {
                                    delete_sidebar_sandbox(base_url, sandbox_id, event_tx).await;
                                });
                            }
                        }
                        KeyCode::Enter | KeyCode::Esc | KeyCode::Tab => {
                            // Just focus the main area
                            app.focus = FocusArea::MainArea;
                        }
                        _ => {}
                    }
                }
                FocusArea::MainArea => {
                    // Check if we should forward input to the terminal
                    let should_forward = if let Some(pane_id) = app.active_pane_id() {
                        let guard = terminal_manager.try_lock();
                        guard.map(|g| g.is_connected(pane_id)).unwrap_or(false)
                    } else {
                        false
                    };

                    if should_forward {
                        // Forward input to terminal
                        if let Some(pane_id) = app.active_pane_id() {
                            let input = key_to_terminal_input(key.modifiers, key.code);
                            if !input.is_empty() {
                                if let Ok(guard) = terminal_manager.try_lock() {
                                    guard.send_input(pane_id, input);
                                }
                            }
                        }
                    } else {
                        // Handle vim-style navigation when not connected
                        match key.code {
                            KeyCode::Char('h')
                                if !key.modifiers.contains(KeyModifiers::CONTROL) =>
                            {
                                if let Some(tab) = app.active_tab_mut() {
                                    tab.navigate(crate::mux::layout::NavDirection::Left);
                                }
                            }
                            KeyCode::Char('j')
                                if !key.modifiers.contains(KeyModifiers::CONTROL) =>
                            {
                                if let Some(tab) = app.active_tab_mut() {
                                    tab.navigate(crate::mux::layout::NavDirection::Down);
                                }
                            }
                            KeyCode::Char('k')
                                if !key.modifiers.contains(KeyModifiers::CONTROL) =>
                            {
                                if let Some(tab) = app.active_tab_mut() {
                                    tab.navigate(crate::mux::layout::NavDirection::Up);
                                }
                            }
                            KeyCode::Char('l')
                                if !key.modifiers.contains(KeyModifiers::CONTROL) =>
                            {
                                if let Some(tab) = app.active_tab_mut() {
                                    tab.navigate(crate::mux::layout::NavDirection::Right);
                                }
                            }
                            KeyCode::Tab => {
                                if app.sidebar.visible {
                                    app.focus = FocusArea::Sidebar;
                                }
                            }
                            _ => {}
                        }
                    }
                }
                FocusArea::CommandPalette => {
                    // Already handled above
                }
                FocusArea::Notifications => {
                    // Notifications overlay is handled before focus-specific input.
                }
            }
        }
        Event::Mouse(mouse_event) => {
            // Handle mouse events (scrolling, clicking)
            use crossterm::event::{MouseButton, MouseEventKind};

            // First check if terminal has mouse mode enabled and we should forward
            if let Some(pane_id) = app.active_pane_id() {
                if app.focus == FocusArea::MainArea {
                    // Get the pane's area to check if mouse is inside and compute relative coords
                    let pane_area = app
                        .active_tab()
                        .and_then(|tab| tab.layout.find_pane(pane_id).and_then(|p| p.area));

                    if let Some(area) = pane_area {
                        // Account for border (1 cell)
                        let inner_x = area.x.saturating_add(1);
                        let inner_y = area.y.saturating_add(1);
                        let inner_w = area.width.saturating_sub(2);
                        let inner_h = area.height.saturating_sub(2);

                        // Check if mouse is inside pane content area
                        if mouse_event.column >= inner_x
                            && mouse_event.column < inner_x + inner_w
                            && mouse_event.row >= inner_y
                            && mouse_event.row < inner_y + inner_h
                        {
                            // Compute relative coordinates (0-indexed for URL detection, 1-indexed for protocol)
                            let rel_col_0 = mouse_event.column.saturating_sub(inner_x) as usize;
                            let rel_row_0 = mouse_event.row.saturating_sub(inner_y) as usize;
                            let rel_col = (rel_col_0 + 1) as u16;
                            let rel_row = (rel_row_0 + 1) as u16;

                            // Handle Cmd+Click (macOS) or Ctrl+Click (other platforms) to open URLs
                            #[cfg(target_os = "macos")]
                            let open_url_modifier = KeyModifiers::SUPER;
                            #[cfg(not(target_os = "macos"))]
                            let open_url_modifier = KeyModifiers::CONTROL;

                            if matches!(mouse_event.kind, MouseEventKind::Down(MouseButton::Left))
                                && mouse_event.modifiers.contains(open_url_modifier)
                            {
                                tracing::debug!(
                                    "URL click: row={}, col={}, pane={:?}",
                                    rel_row_0,
                                    rel_col_0,
                                    pane_id
                                );

                                // Use catch_unwind to prevent panics from crashing the TUI
                                let url_result =
                                    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                                        if let Ok(guard) = terminal_manager.try_lock() {
                                            if let Some(buffer) = guard.get_buffer(pane_id) {
                                                tracing::debug!(
                                                    "Buffer found, grid size: {}",
                                                    buffer.rows()
                                                );
                                                return buffer
                                                    .url_at_position(rel_row_0, rel_col_0);
                                            } else {
                                                tracing::debug!("No buffer for pane {:?}", pane_id);
                                            }
                                        } else {
                                            tracing::debug!("Failed to lock terminal_manager");
                                        }
                                        None
                                    }));

                                match url_result {
                                    Ok(Some(url)) => {
                                        tracing::info!("Opening URL: {}", url);
                                        let _ = open::that(&url);
                                        app.set_status(format!("Opening: {}", url));
                                        return false;
                                    }
                                    Ok(None) => {
                                        tracing::debug!("No URL found at position");
                                        // No URL found at position, continue
                                    }
                                    Err(e) => {
                                        tracing::error!("URL detection panicked: {:?}", e);
                                        app.set_status(
                                            "Error: URL detection failed (internal error)"
                                                .to_string(),
                                        );
                                        return false;
                                    }
                                }
                            }

                            if let Ok(guard) = terminal_manager.try_lock() {
                                let (mouse_mode, sgr_mode) = guard
                                    .get_buffer(pane_id)
                                    .map(|b| (b.mouse_tracking(), b.sgr_mouse_mode()))
                                    .unwrap_or((None, false));

                                if let Some(mode) = mouse_mode {
                                    // Forward mouse event to terminal
                                    if let Some(seq) = encode_mouse_event(
                                        mouse_event.kind,
                                        mouse_event.modifiers,
                                        rel_col,
                                        rel_row,
                                        mode,
                                        sgr_mode,
                                    ) {
                                        guard.send_input(pane_id, seq);
                                        return false; // Event handled, don't process locally
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // Handle locally if not forwarded to terminal
            match mouse_event.kind {
                MouseEventKind::ScrollUp => {
                    if let Some(pane_id) = app.active_pane_id() {
                        if let Ok(mut guard) = terminal_manager.try_lock() {
                            if let Some(buffer) = guard.get_buffer_mut(pane_id) {
                                buffer.scroll_up(3);
                            }
                        }
                    }
                }
                MouseEventKind::ScrollDown => {
                    if let Some(pane_id) = app.active_pane_id() {
                        if let Ok(mut guard) = terminal_manager.try_lock() {
                            if let Some(buffer) = guard.get_buffer_mut(pane_id) {
                                buffer.scroll_down(3);
                            }
                        }
                    }
                }
                _ => {}
            }
        }
        Event::Paste(text) => {
            // Forward paste to active terminal
            if let Some(pane_id) = app.active_pane_id() {
                if let Ok(guard) = terminal_manager.try_lock() {
                    guard.send_input(pane_id, text.into_bytes());
                }
            }
        }
        _ => {}
    }

    false
}

/// Select the currently highlighted sandbox in the sidebar and switch to its workspace.
fn select_sidebar_sandbox(app: &mut MuxApp<'_>) {
    if let Some(sandbox) = app.sidebar.selected_sandbox() {
        let sandbox_id = sandbox.id.to_string();
        let sandbox_name = sandbox.name.clone();

        // Select the sandbox (switches workspace to this sandbox)
        if app.select_sandbox(&sandbox_id) {
            app.set_status(format!("Selected: {}", sandbox_name));
        }
    }
}

async fn delete_sidebar_sandbox(
    base_url: String,
    sandbox_id: String,
    event_tx: mpsc::UnboundedSender<MuxEvent>,
) {
    let client = reqwest::Client::new();
    let url = format!(
        "{}/sandboxes/{}",
        base_url.trim_end_matches('/'),
        sandbox_id
    );

    let result = client.delete(&url).send().await;

    match result {
        Ok(response) if response.status().is_success() => {
            let _ = event_tx.send(MuxEvent::SandboxDeleted(sandbox_id.clone()));
            if let Err(error) = refresh_sandboxes(&base_url, &event_tx).await {
                let _ = event_tx.send(MuxEvent::Error(format!(
                    "Failed to refresh sandboxes: {}",
                    error
                )));
            }
        }
        Ok(response) => {
            let _ = event_tx.send(MuxEvent::Error(format!(
                "Failed to delete sandbox: {}",
                response.status()
            )));
            if let Err(error) = refresh_sandboxes(&base_url, &event_tx).await {
                let _ = event_tx.send(MuxEvent::Error(format!(
                    "Failed to refresh sandboxes: {}",
                    error
                )));
            }
        }
        Err(error) => {
            let _ = event_tx.send(MuxEvent::Error(format!(
                "Failed to delete sandbox: {}",
                error
            )));
        }
    }
}

fn remove_selected_sandbox(app: &mut MuxApp<'_>) -> Option<(String, String)> {
    if app.sidebar.sandboxes.is_empty() {
        return None;
    }

    let current_index = app
        .sidebar
        .selected_index
        .min(app.sidebar.sandboxes.len().saturating_sub(1));

    let sandbox = app.sidebar.sandboxes.remove(current_index);
    let sandbox_id = sandbox.id.to_string();
    let sandbox_name = sandbox.name.clone();
    let sandbox_uuid = SandboxId::from_uuid(sandbox.id);

    app.workspace_manager.remove_sandbox(sandbox_uuid);
    app.focus = FocusArea::Sidebar;

    if let Some(pending) = &app.pending_connect {
        if pending == &sandbox_id {
            app.pending_connect = None;
        }
    }

    if app.sidebar.sandboxes.is_empty() {
        app.sidebar.selected_index = 0;
        app.workspace_manager.active_sandbox_id = None;
        return Some((sandbox_id, sandbox_name));
    }

    let next_index = if current_index < app.sidebar.sandboxes.len() {
        current_index
    } else {
        app.sidebar.sandboxes.len() - 1
    };

    app.sidebar.selected_index = next_index;

    let next_selected_id = app.sidebar.sandboxes[next_index].id.to_string();
    let _ = app.select_sandbox(&next_selected_id);
    app.sidebar.select_by_id(&next_selected_id);

    Some((sandbox_id, sandbox_name))
}

/// Convert a key event to terminal input bytes
fn key_to_terminal_input(modifiers: KeyModifiers, code: KeyCode) -> Vec<u8> {
    match code {
        KeyCode::Char(c) => {
            if modifiers.contains(KeyModifiers::CONTROL) {
                // Ctrl+A = 0x01, Ctrl+B = 0x02, etc.
                let ctrl_code = (c.to_ascii_lowercase() as u8).saturating_sub(b'a' - 1);
                if (1..=26).contains(&ctrl_code) {
                    return vec![ctrl_code];
                }
            }
            let mut buf = [0u8; 4];
            let s = c.encode_utf8(&mut buf);
            s.as_bytes().to_vec()
        }
        KeyCode::Enter => vec![b'\r'],
        KeyCode::Backspace => {
            // Command+Backspace (macOS) / Super+Backspace: delete to beginning of line (Ctrl+U)
            if modifiers.contains(KeyModifiers::SUPER) {
                return vec![0x15]; // Ctrl+U
            }
            // Option+Backspace (macOS) / Alt+Backspace: delete previous word (Ctrl+W)
            if modifiers.contains(KeyModifiers::ALT) {
                return vec![0x17]; // Ctrl+W
            }
            vec![0x7f]
        }
        KeyCode::Tab => vec![b'\t'],
        KeyCode::Esc => vec![0x1b],
        KeyCode::Up => vec![0x1b, b'[', b'A'],
        KeyCode::Down => vec![0x1b, b'[', b'B'],
        KeyCode::Right => vec![0x1b, b'[', b'C'],
        KeyCode::Left => vec![0x1b, b'[', b'D'],
        KeyCode::Home => vec![0x1b, b'[', b'H'],
        KeyCode::End => vec![0x1b, b'[', b'F'],
        KeyCode::PageUp => vec![0x1b, b'[', b'5', b'~'],
        KeyCode::PageDown => vec![0x1b, b'[', b'6', b'~'],
        KeyCode::Delete => vec![0x1b, b'[', b'3', b'~'],
        KeyCode::Insert => vec![0x1b, b'[', b'2', b'~'],
        KeyCode::F(n) => {
            // F1-F4 use different sequences than F5+
            match n {
                1 => vec![0x1b, b'O', b'P'],
                2 => vec![0x1b, b'O', b'Q'],
                3 => vec![0x1b, b'O', b'R'],
                4 => vec![0x1b, b'O', b'S'],
                5 => vec![0x1b, b'[', b'1', b'5', b'~'],
                6 => vec![0x1b, b'[', b'1', b'7', b'~'],
                7 => vec![0x1b, b'[', b'1', b'8', b'~'],
                8 => vec![0x1b, b'[', b'1', b'9', b'~'],
                9 => vec![0x1b, b'[', b'2', b'0', b'~'],
                10 => vec![0x1b, b'[', b'2', b'1', b'~'],
                11 => vec![0x1b, b'[', b'2', b'3', b'~'],
                12 => vec![0x1b, b'[', b'2', b'4', b'~'],
                _ => vec![],
            }
        }
        _ => vec![],
    }
}

async fn create_sandbox_with_workspace(
    base_url: String,
    workspace_path: PathBuf,
    tab_id: Option<String>,
    event_tx: mpsc::UnboundedSender<MuxEvent>,
) -> Result<(), anyhow::Error> {
    let client = reqwest::Client::new();
    let trimmed_base = base_url.trim_end_matches('/').to_string();
    let tab_id = tab_id.unwrap_or_else(|| TabId::new().to_string());

    let dir_name = workspace_path
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "workspace".to_string());

    let _ = event_tx.send(MuxEvent::StatusMessage {
        message: format!("Creating sandbox: {}", dir_name),
    });

    let request_tab_id = tab_id.clone();
    let body = crate::models::CreateSandboxRequest {
        name: Some(dir_name.clone()),
        workspace: None,
        tab_id: Some(request_tab_id),
        read_only_paths: vec![],
        tmpfs: vec![],
        env: crate::keyring::build_default_env_vars(),
    };

    let response = client
        .post(format!("{}/sandboxes", trimmed_base))
        .json(&body)
        .send()
        .await?;

    let status = response.status();
    if !status.is_success() {
        let text = response
            .text()
            .await
            .unwrap_or_else(|_| String::from("unknown error"));
        return Err(anyhow::anyhow!(format!(
            "Failed to create sandbox: {} - {}",
            status, text
        )));
    }

    let summary: crate::models::SandboxSummary = response.json().await?;
    let sandbox_id = summary.id.to_string();

    let _ = event_tx.send(MuxEvent::StatusMessage {
        message: format!("Uploading {}...", dir_name),
    });

    if let Err(error) = upload_workspace(&client, &trimmed_base, &sandbox_id, &workspace_path).await
    {
        let _ = event_tx.send(MuxEvent::Error(format!(
            "Failed to upload workspace: {}",
            error
        )));
    }

    let sync_files = detect_sync_files();
    if !sync_files.is_empty() {
        let _ = event_tx.send(MuxEvent::StatusMessage {
            message: format!("Syncing {} file(s)...", sync_files.len()),
        });

        if let Err(error) =
            upload_sync_files_with_list(&client, &trimmed_base, &sandbox_id, sync_files, false)
                .await
        {
            let _ = event_tx.send(MuxEvent::Error(format!("Failed to sync files: {}", error)));
        }
    }

    let _ = event_tx.send(MuxEvent::SandboxCreated(summary.clone()));
    let _ = event_tx.send(MuxEvent::StatusMessage {
        message: format!("Created sandbox: {}", sandbox_id),
    });
    let _ = event_tx.send(MuxEvent::ConnectToSandbox { sandbox_id });

    if let Err(error) = refresh_sandboxes(&trimmed_base, &event_tx).await {
        let _ = event_tx.send(MuxEvent::SandboxRefreshFailed(error.to_string()));
    }

    Ok(())
}

/// Periodically refresh the sandbox list.
async fn refresh_sandboxes_periodically(base_url: String, tx: mpsc::UnboundedSender<MuxEvent>) {
    let mut interval = tokio::time::interval(Duration::from_secs(10));
    loop {
        interval.tick().await;
        if let Err(e) = refresh_sandboxes(&base_url, &tx).await {
            let _ = tx.send(MuxEvent::SandboxRefreshFailed(e.to_string()));
        }
    }
}

/// Refresh the sandbox list from the server.
async fn refresh_sandboxes(
    base_url: &str,
    tx: &mpsc::UnboundedSender<MuxEvent>,
) -> Result<Vec<crate::models::SandboxSummary>, anyhow::Error> {
    let client = reqwest::Client::new();
    let url = format!("{}/sandboxes", base_url.trim_end_matches('/'));

    let response = client
        .get(&url)
        .timeout(Duration::from_secs(5))
        .send()
        .await?;

    if !response.status().is_success() {
        return Err(anyhow::anyhow!(
            "Failed to fetch sandboxes: {}",
            response.status()
        ));
    }

    let sandboxes: Vec<crate::models::SandboxSummary> = response.json().await?;
    let _ = tx.send(MuxEvent::SandboxesRefreshed(sandboxes.clone()));

    Ok(sandboxes)
}

/// Upload a workspace directory to a sandbox.
async fn upload_workspace(
    client: &reqwest::Client,
    base_url: &str,
    sandbox_id: &str,
    workspace: &std::path::Path,
) -> Result<(), anyhow::Error> {
    use std::io::Write;

    let (tx, rx) = tokio::sync::mpsc::channel::<Result<Vec<u8>, std::io::Error>>(10);

    // Clone workspace path for the blocking task
    let workspace_owned = workspace.to_path_buf();

    tokio::task::spawn_blocking(move || {
        struct ChunkedWriter {
            sender: tokio::sync::mpsc::Sender<Result<Vec<u8>, std::io::Error>>,
        }

        impl Write for ChunkedWriter {
            fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
                let data = buf.to_vec();
                match self.sender.blocking_send(Ok(data)) {
                    Ok(_) => Ok(buf.len()),
                    Err(_) => Err(std::io::Error::new(
                        std::io::ErrorKind::BrokenPipe,
                        "Channel closed",
                    )),
                }
            }

            fn flush(&mut self) -> std::io::Result<()> {
                Ok(())
            }
        }

        let writer = ChunkedWriter { sender: tx.clone() };
        let mut tar = tar::Builder::new(writer);
        tar.follow_symlinks(false);

        let root = match workspace_owned.canonicalize() {
            Ok(p) => p,
            Err(e) => {
                let _ = tx.blocking_send(Err(std::io::Error::other(e)));
                return;
            }
        };

        // Use ignore crate to respect .gitignore
        let walker = ignore::WalkBuilder::new(&root)
            .hidden(false)
            .git_ignore(true)
            .build();

        for result in walker {
            let entry = match result {
                Ok(entry) => entry,
                Err(err) => {
                    let _ = tx.blocking_send(Err(std::io::Error::other(err)));
                    return;
                }
            };

            let entry_path = entry.path();
            if entry_path == root {
                continue;
            }

            let relative_path = match entry_path.strip_prefix(&root) {
                Ok(p) => p,
                Err(err) => {
                    let _ = tx.blocking_send(Err(std::io::Error::other(err)));
                    return;
                }
            };

            let metadata = match std::fs::symlink_metadata(entry_path) {
                Ok(m) => m,
                Err(err) => {
                    let _ = tx.blocking_send(Err(err));
                    return;
                }
            };

            let file_type = metadata.file_type();

            let append_result = if file_type.is_dir() {
                tar.append_dir(relative_path, entry_path)
            } else {
                tar.append_path_with_name(entry_path, relative_path)
            };

            if let Err(e) = append_result {
                let _ = tx.blocking_send(Err(e));
                return;
            }
        }

        if let Err(e) = tar.finish() {
            let _ = tx.blocking_send(Err(e));
        }
    });

    let body = reqwest::Body::wrap_stream(futures::stream::unfold(rx, |mut rx| async move {
        rx.recv().await.map(|msg| (msg, rx))
    }));

    let url = format!(
        "{}/sandboxes/{}/files",
        base_url.trim_end_matches('/'),
        sandbox_id
    );
    let response = client.post(&url).body(body).send().await?;

    if !response.status().is_success() {
        return Err(anyhow::anyhow!(
            "Failed to upload workspace: {}",
            response.status()
        ));
    }

    Ok(())
}

/// Encode a mouse event as terminal escape sequence.
/// Returns None if the event type shouldn't be reported for the given mode.
fn encode_mouse_event(
    kind: crossterm::event::MouseEventKind,
    modifiers: KeyModifiers,
    col: u16,
    row: u16,
    mode: u16,
    sgr_mode: bool,
) -> Option<Vec<u8>> {
    use crossterm::event::{MouseButton, MouseEventKind};

    // Compute button code based on event type
    let (button_code, is_release) = match kind {
        MouseEventKind::Down(button) => {
            let code = match button {
                MouseButton::Left => 0,
                MouseButton::Middle => 1,
                MouseButton::Right => 2,
            };
            (code, false)
        }
        MouseEventKind::Up(button) => {
            let code = match button {
                MouseButton::Left => 0,
                MouseButton::Middle => 1,
                MouseButton::Right => 2,
            };
            (code, true)
        }
        MouseEventKind::Drag(button) => {
            // Drag events are only reported in mode 1002 (button-event) or 1003 (any-event)
            if mode < 1002 {
                return None;
            }
            let code = match button {
                MouseButton::Left => 32, // 0 + 32 (motion flag)
                MouseButton::Middle => 33,
                MouseButton::Right => 34,
            };
            (code, false)
        }
        MouseEventKind::Moved => {
            // Motion events without button are only reported in mode 1003 (any-event)
            if mode != 1003 {
                return None;
            }
            (35, false) // 3 + 32 (motion flag, no button)
        }
        MouseEventKind::ScrollUp => (64, false), // Button 4
        MouseEventKind::ScrollDown => (65, false), // Button 5
        MouseEventKind::ScrollLeft => (66, false), // Button 6
        MouseEventKind::ScrollRight => (67, false), // Button 7
    };

    // Add modifier flags
    let mut cb = button_code;
    if modifiers.contains(KeyModifiers::SHIFT) {
        cb |= 4;
    }
    if modifiers.contains(KeyModifiers::ALT) {
        cb |= 8;
    }
    if modifiers.contains(KeyModifiers::CONTROL) {
        cb |= 16;
    }

    if sgr_mode {
        // SGR extended mode: CSI < Cb ; Cx ; Cy M/m
        // M for press, m for release
        let terminator = if is_release { 'm' } else { 'M' };
        Some(format!("\x1b[<{};{};{}{}", cb, col, row, terminator).into_bytes())
    } else {
        // X10/normal mode: CSI M Cb Cx Cy (all +32, max 223)
        // Release events send button 3 (no button)
        let cb = if is_release { 3 } else { cb };
        // X10 encoding adds 32 to all values and caps at 255
        let cb = (cb + 32).min(255) as u8;
        let cx = ((col as u32) + 32).min(255) as u8;
        let cy = ((row as u32) + 32).min(255) as u8;
        Some(vec![0x1b, b'[', b'M', cb, cx, cy])
    }
}

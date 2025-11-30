use agent_client_protocol::ModelId;
use anyhow::Result;
use crossterm::{
    event::{
        DisableBracketedPaste, DisableMouseCapture, EnableBracketedPaste, EnableMouseCapture,
        Event, EventStream, KeyCode, KeyModifiers, MouseEventKind,
    },
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
};
use futures::StreamExt;
use ratatui::{backend::CrosstermBackend, Terminal};
use tokio::sync::mpsc;

use crate::acp_client::config::{load_last_model, save_last_model, save_last_provider};
use crate::acp_client::connection::{connect_to_provider, fetch_provider_models};
use crate::acp_client::events::AppEvent;
use crate::acp_client::logging::log_debug;
use crate::acp_client::provider::AcpProvider;
use crate::acp_client::state::{App, ConnectionState, PaletteCommand, UiMode};
use crate::acp_client::ui::ui;
use crate::acp_client::workspace_sync::WorkspaceSyncStatus;

fn spawn_provider_tasks(
    tx: mpsc::UnboundedSender<AppEvent>,
    base_url: String,
    sandbox_id: String,
    initial_provider: AcpProvider,
) {
    for provider in AcpProvider::all() {
        let tx_clone = tx.clone();
        let base_url_clone = base_url.clone();
        let sandbox_id_clone = sandbox_id.clone();
        let provider = *provider;

        if provider == initial_provider {
            tokio::task::spawn_local(async move {
                match connect_to_provider(
                    &base_url_clone,
                    &sandbox_id_clone,
                    provider,
                    tx_clone.clone(),
                )
                .await
                {
                    Ok((connection, session_id, model_state)) => {
                        let _ = tx_clone.send(AppEvent::ProviderSwitchComplete {
                            provider,
                            connection,
                            session_id,
                            model_state,
                        });
                    }
                    Err(e) => {
                        log_debug(&format!("Initial provider connection failed: {}", e));
                        let _ = tx_clone.send(AppEvent::ProviderSwitchFailed {
                            provider,
                            error: e.to_string(),
                        });
                    }
                }
            });
        } else {
            tokio::task::spawn_local(async move {
                fetch_provider_models(&base_url_clone, &sandbox_id_clone, provider, tx_clone).await;
            });
        }
    }
}

pub async fn run_chat_tui(
    base_url: String,
    sandbox_id: String,
    provider: AcpProvider,
) -> Result<()> {
    run_chat_tui_with_workspace_status(base_url, sandbox_id, provider, None).await
}

pub async fn run_chat_tui_with_workspace_status(
    base_url: String,
    sandbox_id: String,
    provider: AcpProvider,
    workspace_status_rx: Option<mpsc::UnboundedReceiver<WorkspaceSyncStatus>>,
) -> Result<()> {
    let mut stdout = std::io::stdout();
    execute!(
        stdout,
        EnterAlternateScreen,
        EnableMouseCapture,
        EnableBracketedPaste
    )?;
    enable_raw_mode()?;

    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend)?;

    let local = tokio::task::LocalSet::new();
    let res = local
        .run_until(run_main_loop(
            &mut terminal,
            base_url,
            sandbox_id,
            provider,
            workspace_status_rx,
        ))
        .await;

    disable_raw_mode()?;
    execute!(
        terminal.backend_mut(),
        DisableMouseCapture,
        LeaveAlternateScreen,
        DisableBracketedPaste
    )?;
    terminal.show_cursor()?;

    match res {
        Ok(_) => Ok(()),
        Err(e) => {
            eprintln!("\n\x1b[31mError: {}\x1b[0m", e);
            if let Ok(logs) = std::fs::read_to_string("/tmp/cmux-chat.log") {
                let lines: Vec<&str> = logs.lines().rev().take(5).collect();
                if !lines.is_empty() {
                    eprintln!("\nRecent logs:");
                    for line in lines.iter().rev() {
                        eprintln!("  {}", line);
                    }
                }
            }
            Err(anyhow::anyhow!(e))
        }
    }
}

async fn run_main_loop<B: ratatui::backend::Backend>(
    terminal: &mut Terminal<B>,
    base_url: String,
    sandbox_id: String,
    initial_provider: AcpProvider,
    workspace_status_rx: Option<mpsc::UnboundedReceiver<WorkspaceSyncStatus>>,
) -> Result<()> {
    log_debug(&format!(
        "Starting run_main_loop with provider: {}",
        initial_provider.display_name()
    ));
    let (tx, rx) = mpsc::unbounded_channel();

    let provider_tasks_started = workspace_status_rx.is_none();

    if let Some(mut workspace_rx) = workspace_status_rx {
        let tx_clone = tx.clone();
        let base_url_clone = base_url.clone();
        let sandbox_id_clone = sandbox_id.clone();
        let initial_provider_clone = initial_provider;
        let mut tasks_started = provider_tasks_started;
        tokio::task::spawn_local(async move {
            while let Some(status) = workspace_rx.recv().await {
                let is_done = matches!(
                    status,
                    WorkspaceSyncStatus::Completed | WorkspaceSyncStatus::Failed(_)
                );
                let _ = tx_clone.send(AppEvent::WorkspaceSyncStatus(status));
                if !tasks_started && is_done {
                    tasks_started = true;
                    spawn_provider_tasks(
                        tx_clone.clone(),
                        base_url_clone.clone(),
                        sandbox_id_clone.clone(),
                        initial_provider_clone,
                    );
                }
            }
            if !tasks_started {
                spawn_provider_tasks(
                    tx_clone,
                    base_url_clone,
                    sandbox_id_clone,
                    initial_provider_clone,
                );
            }
        });
    }

    let mut app = App::new(
        initial_provider,
        tx.clone(),
        base_url.clone(),
        sandbox_id.clone(),
    );
    app.connection_state = ConnectionState::Connecting;

    for provider in AcpProvider::all() {
        app.providers_loading.push(*provider);
    }

    if provider_tasks_started {
        spawn_provider_tasks(
            tx.clone(),
            base_url.clone(),
            sandbox_id.clone(),
            initial_provider,
        );
    }

    log_debug("Running App UI loop...");
    run_app(terminal, app, rx).await?;
    log_debug("App UI loop finished - exiting");
    Ok(())
}

async fn run_app<B: ratatui::backend::Backend>(
    terminal: &mut Terminal<B>,
    mut app: App<'_>,
    mut rx: mpsc::UnboundedReceiver<AppEvent>,
) -> std::io::Result<()> {
    let mut reader = EventStream::new();

    loop {
        terminal.draw(|f| ui(f, &mut app))?;

        tokio::select! {
            Some(event) = rx.recv() => {
                match event {
                    AppEvent::SessionUpdate(notification) => app.on_session_update(*notification),
                    AppEvent::DebugMessage { direction, message } => {
                        app.add_debug_message(&direction, &message);
                    }
                    AppEvent::WorkspaceSyncStatus(status) => {
                        app.update_workspace_sync_state(status);
                    }
                    AppEvent::ProviderSwitchComplete { provider, connection, session_id, model_state } => {
                        log_debug(&format!("Provider switch complete: {}", provider.display_name()));
                        let was_initial_connection = app.connection_state == ConnectionState::Connecting;
                        app.current_provider = provider;
                        app.client_connection = Some(connection);
                        app.session_id = Some(session_id);
                        app.model_state = model_state.clone();
                        app.connection_state = ConnectionState::Connected;

                        if let Some(ref state) = model_state {
                            let models: Vec<(String, String)> = state
                                .available_models
                                .iter()
                                .map(|m| (m.model_id.0.to_string(), m.name.clone()))
                                .collect();
                            app.provider_models.insert(provider, Some(models));
                        }
                        app.providers_loading.retain(|p| *p != provider);

                        if !was_initial_connection {
                            app.history.clear();
                        }

                        save_last_provider(provider);

                        if let Some(pending_model) = app.pending_model_switch.take() {
                            app.model_switching = true;
                            app.start_model_switch(pending_model);
                        } else if let Some(ref state) = model_state {
                            if let Some(last_model_id) = load_last_model(provider) {
                                if state.available_models.iter().any(|m| *m.model_id.0 == last_model_id)
                                    && *state.current_model_id.0 != last_model_id
                                {
                                    app.model_switching = true;
                                    app.start_model_switch(ModelId::from(last_model_id));
                                }
                            }
                        }
                    }
                    AppEvent::ProviderSwitchFailed { provider, error } => {
                        log_debug(&format!("Provider switch failed for {}: {}", provider.display_name(), error));
                        let was_initial_connection = app.connection_state == ConnectionState::Connecting;
                        if let ConnectionState::SwitchingProvider(old_provider) = app.connection_state {
                            app.current_provider = old_provider;
                            app.connection_state = ConnectionState::Connected;
                        } else if was_initial_connection {
                            app.connection_state = ConnectionState::Connected;
                        }
                        app.providers_loading.retain(|p| *p != provider);
                        app.provider_models.insert(provider, Some(vec![]));
                        app.pending_model_switch = None;
                        if provider == app.current_provider {
                            app.history.push(crate::acp_client::state::ChatEntry::Message {
                                role: "System".to_string(),
                                text: format!("Failed to connect to {}: {}", provider.display_name(), error),
                                normalized_markdown: None,
                            });
                        }
                    }
                    AppEvent::ModelSwitchComplete { model_id } => {
                        log_debug(&format!("Model switch complete: {}", model_id));
                        app.model_switching = false;
                        if let Some(ref mut model_state) = app.model_state {
                            model_state.current_model_id = model_id.clone();
                        }
                        save_last_model(app.current_provider, &model_id.0);
                    }
                    AppEvent::ModelSwitchFailed { error } => {
                        log_debug(&format!("Model switch failed: {}", error));
                        app.model_switching = false;
                        app.history.push(crate::acp_client::state::ChatEntry::Message {
                            role: "System".to_string(),
                            text: format!("Failed to switch model: {}", error),
                            normalized_markdown: None,
                        });
                    }
                    AppEvent::RequestError { error } => {
                        log_debug(&format!("Request error: {}", error));
                        app.history.push(crate::acp_client::state::ChatEntry::Message {
                            role: "Error".to_string(),
                            text: error,
                            normalized_markdown: None,
                        });
                    }
                    AppEvent::ProviderModelsLoaded { provider, models } => {
                        log_debug(&format!("Loaded {} models for {}", models.len(), provider.display_name()));
                        app.provider_models.insert(provider, Some(models));
                        app.providers_loading.retain(|p| *p != provider);
                    }
                    AppEvent::ProviderModelsLoadFailed { provider } => {
                        log_debug(&format!("Failed to load models for {}", provider.display_name()));
                        app.provider_models.insert(provider, Some(vec![]));
                        app.providers_loading.retain(|p| *p != provider);
                    }
                }
            }
            Some(Ok(event)) = reader.next() => {
                match app.ui_mode {
                    UiMode::MainPalette => {
                        if let Event::Key(key) = event {
                            if key.modifiers.contains(KeyModifiers::CONTROL) {
                                match key.code {
                                    KeyCode::Char('p') | KeyCode::Char('k') => app.palette_up(),
                                    KeyCode::Char('n') | KeyCode::Char('j') => app.palette_down(),
                                    KeyCode::Char('c') | KeyCode::Char('g') => app.close_palette(),
                                    KeyCode::Char('o') => app.close_palette(),
                                    KeyCode::Char('u') | KeyCode::Char('r') |
                                    KeyCode::Char('w') | KeyCode::Char('a') | KeyCode::Char('e') |
                                    KeyCode::Char('h') | KeyCode::Char('d') => {
                                        app.palette_handle_input(key);
                                    }
                                    _ => {}
                                }
                            } else {
                                match key.code {
                                    KeyCode::Esc => app.close_palette(),
                                    KeyCode::Up => app.palette_up(),
                                    KeyCode::Down => app.palette_down(),
                                    KeyCode::Enter => {
                                        if let Some(cmd) = app.execute_main_palette_selection() {
                                            match cmd {
                                                PaletteCommand::ToggleDebugMode => {
                                                    app.toggle_debug_mode();
                                                }
                                                PaletteCommand::SwitchProviderModel => {
                                                    app.open_switch_palette();
                                                }
                                            }
                                        }
                                    }
                                    _ => { app.palette_handle_input(key); }
                                }
                            }
                        }
                    }
                    UiMode::SwitchPalette => {
                        if let Event::Key(key) = event {
                            if key.modifiers.contains(KeyModifiers::CONTROL) {
                                match key.code {
                                    KeyCode::Char('p') | KeyCode::Char('k') => app.palette_up(),
                                    KeyCode::Char('n') | KeyCode::Char('j') => app.palette_down(),
                                    KeyCode::Char('c') | KeyCode::Char('g') => app.close_palette(),
                                    KeyCode::Char('m') => app.close_palette(),
                                    KeyCode::Char('u') | KeyCode::Char('r') |
                                    KeyCode::Char('w') | KeyCode::Char('a') | KeyCode::Char('e') |
                                    KeyCode::Char('h') | KeyCode::Char('d') => {
                                        app.palette_handle_input(key);
                                    }
                                    _ => {}
                                }
                            } else {
                                match key.code {
                                    KeyCode::Esc => app.close_palette(),
                                    KeyCode::Up => app.palette_up(),
                                    KeyCode::Down => app.palette_down(),
                                    KeyCode::Enter => {
                                        app.execute_switch_palette_selection();
                                    }
                                    _ => { app.palette_handle_input(key); }
                                }
                            }
                        }
                    }
                    UiMode::Chat => {
                        match event {
                            Event::Key(key) => {
                                if key.modifiers.contains(KeyModifiers::CONTROL) {
                                    match key.code {
                                        KeyCode::Char('q') | KeyCode::Char('c') | KeyCode::Char('d') => {
                                            return Ok(());
                                        }
                                        KeyCode::Char('j') => { app.textarea.insert_newline(); },
                                        KeyCode::Char('m') => { app.open_switch_palette(); },
                                        KeyCode::Char('o') => { app.open_main_palette(); },
                                        _ => { app.textarea.input(key); }
                                    }
                                } else {
                                    match key.code {
                                        KeyCode::Enter => {
                                            if app.connection_state == ConnectionState::Connected {
                                                app.send_message().await;
                                            }
                                        }
                                        KeyCode::PageUp => {
                                            app.scroll_up(10);
                                        }
                                        KeyCode::PageDown => {
                                            app.scroll_down(10);
                                        }
                                        KeyCode::Home => {
                                            app.scroll_to_top();
                                        }
                                        KeyCode::End => {
                                            app.scroll_to_bottom();
                                        }
                                        _ => {
                                            app.textarea.input(key);
                                        }
                                    }
                                }
                            }
                            Event::Paste(text) => {
                                app.textarea.insert_str(&text);
                            }
                            Event::Mouse(mouse_event) => {
                                match mouse_event.kind {
                                    MouseEventKind::ScrollUp => {
                                        app.scroll_up(1);
                                    }
                                    MouseEventKind::ScrollDown => {
                                        app.scroll_down(1);
                                    }
                                    _ => {}
                                }
                            }
                            _ => {}
                        }
                    }
                }
            }
        }
    }
}

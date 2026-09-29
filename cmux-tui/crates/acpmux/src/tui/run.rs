//! The TUI event loop: terminal setup, input, drawing, teardown.

use super::*;

pub async fn run(client: Arc<Client>, initial: Option<String>) -> Result<()> {
    let mut client = client;
    // Read UI preferences without probing or changing harness configuration.
    let path = crate::config::Config::path();
    let cfg: crate::config::Config = if path.exists() {
        serde_json::from_str(&std::fs::read_to_string(&path)?)?
    } else { Default::default() };
    let mut notes = client
        .notifications()
        .await
        .ok_or_else(|| anyhow::anyhow!("notifications already taken"))?;
    let (tx, mut rx) = mpsc::unbounded_channel::<AppMsg>();
    let watch = client.request(method::MUX_WATCH, json!({"enabled": true})).await?;
    let mut app = make_app(client.clone(), tx.clone(), watch.get("sessions").and_then(Value::as_array).cloned().unwrap_or_default(), cfg)?;
    app.sort_sessions();
    {
        let c = client.clone();
        let tx = tx.clone();
        tokio::spawn(async move {
            if let Ok(v) = c.request(method::MUX_HARNESSES, json!({})).await {
                let names: Vec<String> = v.get("harnesses").and_then(Value::as_object).map(|o| o.keys().cloned().collect()).unwrap_or_default();
                let _ = tx.send(AppMsg::Agents(names, v.get("defaultHarness").and_then(Value::as_str).map(str::to_owned)));
            }
            if let Ok(v) = c.request(method::MUX_STATUS, json!({})).await {
                let _ = tx.send(AppMsg::Status(v));
            }
        });
    }
    if let Some(id) = initial {
        if let Some(i) = app.sessions.iter().position(|s| s.get("sessionId").and_then(Value::as_str) == Some(&id)) {
            app.select(i);
        }
    } else if !app.sessions.is_empty() {
        app.select(0);
    }

    let mut terminal = terminal::TerminalOutput::init()?;
    let _ = crossterm::execute!(
        std::io::stdout(),
        crossterm::event::EnableMouseCapture,
        crossterm::event::EnableBracketedPaste,
        crossterm::event::EnableFocusChange,
        crossterm::event::PushKeyboardEnhancementFlags(crossterm::event::KeyboardEnhancementFlags::DISAMBIGUATE_ESCAPE_CODES)
    );
    let mut events = EventStream::new();
    let mut tick = tokio::time::interval(std::time::Duration::from_millis(80));
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut frames = scheduler::FrameSchedule::new(Instant::now());
    let result: Result<()> = loop {
        // First paint with no sessions: open the form so the empty screen is not a dead end.
        if !app.initial_empty_checked && !app.harnesses.is_empty() {
            app.initial_empty_checked = true;
            if app.sessions.is_empty() && matches!(app.overlay, Overlay::None) {
                app.open_new_session();
                frames.request();
            }
        }
        if frames.ready(Instant::now()) {
            if let Err(e) = terminal.draw(&mut app) {
                break Err(e.into());
            }
            frames.presented(Instant::now());
        }
        tokio::select! {
            biased;
            ev = events.next() => {
                match ev {
                    // `as_key_event` also unwraps the cmux crossterm patch's
                    // `EnhancedKey`, which carries Alt+letter and layout keys.
                    Some(Ok(e)) if e.as_key_event().is_some_and(|k| k.kind != crossterm::event::KeyEventKind::Release) => {
                        if let Some(k) = e.as_key_event() { app.on_key(k); }
                        frames.request();
                    }
                    Some(Ok(Event::Mouse(m))) => { app.on_mouse(m); frames.request(); }
                    Some(Ok(Event::Resize(..))) | Some(Ok(Event::FocusGained)) => frames.request(),
                    Some(Ok(Event::Paste(s))) => {
                        frames.request();
                        if matches!(app.overlay, Overlay::None) && app.paste_images(&s) {
                            // The terminal pasted an image path from a file
                            // drag; it is an attachment, not editor text.
                        } else { match &mut app.overlay {
                            Overlay::NewSession(f) => match f.field {
                                2 => f.cwd.insert_str(s.trim()),
                                4 => f.prompt.insert_str(&s),
                                1 => f.name.insert_str(s.trim()),
                                _ => {}
                            },
                            Overlay::Picker(p) => {
                                p.filter.insert_str(s.trim());
                                p.refilter();
                            }
                            Overlay::AddHost { text } | Overlay::Directory { text } => text.insert_str(s.trim()),
                            _ => app.editor_mut().insert_str(&s),
                        }}
                    }
                    Some(Err(e)) => break Err(e.into()),
                    None => break Ok(()),
                    _ => {}
                }
            }
            // This deadline cannot be starved by a continuous daemon stream.
            _ = tokio::time::sleep_until(frames.deadline.into()), if frames.dirty => {}
            _ = tick.tick() => {
                app.tick = app.tick.wrapping_add(1);
                if app.keymap.expire() && app.status.starts_with("chord · ") {
                    app.status = DEFAULT_STATUS.into();
                    frames.request();
                }
                if app.drag_autoscroll.is_some() {
                    app.autoscroll_step();
                    frames.request();
                }
                let animated = app.draft().map(|d| d.creating).unwrap_or(false)
                    || app.selected_id().and_then(|id| app.transcripts.get(&id)).map(|t| t.status == "running").unwrap_or(false);
                if animated { frames.request(); }
                if app.tick % 50 == 0 {
                    let c = client.clone();
                    let tx = tx.clone();
                    tokio::spawn(async move {
                        if let Ok(v) = c.request(method::MUX_STATUS, json!({})).await {
                            let _ = tx.send(AppMsg::Status(v));
                        }
                    });
                }
                if app.toast.as_ref().map(|(_, at)| at.elapsed().as_millis() > 1800).unwrap_or(false) {
                    app.toast = None;
                    frames.request();
                }
            }
            m = rx.recv() => {
                if let Some(m) = m {
                    let status_only = matches!(m, AppMsg::Status(_));
                    let before = status_only.then(|| (app.web_url.clone(), app.hosts.clone()));
                    app.on_msg(m);
                    if before.as_ref().map(|(url, hosts)| url != &app.web_url || hosts != &app.hosts).unwrap_or(true) {
                        frames.request();
                    }
                }
            }
            n = notes.recv() => {
                match n {
                    Some(Message::Notification { method: m, params }) if m != method::MUX_DISCONNECTED => {
                        let p = params.unwrap_or(Value::Null);
                        let selected = p.get("sessionId").and_then(Value::as_str) == app.selected_id().as_deref();
                        let visible = match m.as_str() {
                            method::SESSION_UPDATE => selected,
                            method::MUX_EVENT => selected || matches!(p.get("kind").and_then(Value::as_str), Some("turn_end" | "turn_error")),
                            method::MUX_SESSION_CHANGED | method::MUX_PERMISSION_PENDING | "_acpmux/lagged" => true,
                            _ => false,
                        };
                        app.on_notification(&m, p);
                        if visible { frames.request(); }
                    }
                    Some(Message::Request { .. }) | Some(Message::Response { .. }) => {}
                    Some(Message::Notification { .. }) | None => {
                        // The daemon went away (restart, update, crash). Come
                        // back on the new one instead of dying with a bare
                        // "connection closed".
                        let reason = client.closed("attached to the daemon").to_string();
                        app.report_error(reason.clone());
                        app.status = "daemon connection closed; reconnecting…".into();
                        if let Err(e) = terminal.draw(&mut app) { break Err(e.into()); }
                        match reconnect(&mut app).await {
                            Ok(new_notes) => {
                                notes = new_notes;
                                client = app.client.clone();
                                frames.request();
                            }
                            Err(e) => break Err(e),
                        }
                    }
                }
            }
        }
        if let Some(id) = app.pending_select.take() {
            if let Some(i) = app.sessions.iter().position(|s| s.get("sessionId").and_then(Value::as_str) == Some(&id)) {
                app.drafts.retain(|d| !d.creating);
                app.select(i + app.drafts.len());
                app.focus = Focus::Input;
                frames.request();
            } else {
                app.pending_select = Some(id);
            }
        }
        if app.quit {
            break Ok(());
        }
    };
    app.set_pointer(false);
    let _ = crossterm::execute!(
        std::io::stdout(),
        crossterm::event::PopKeyboardEnhancementFlags,
        crossterm::event::DisableFocusChange,
        crossterm::event::DisableBracketedPaste,
        crossterm::event::DisableMouseCapture
    );
    ratatui::restore();
    if let Some(u) = &app.web_url {
        println!("acpmux: agents keep running. Web dashboard: {u}");
    }
    result
}

pub(super) fn make_app(client: Arc<Client>, tx: mpsc::UnboundedSender<AppMsg>, sessions: Vec<Value>, cfg: crate::config::Config) -> Result<App> {
    let tui = cfg.tui.clone();
    for p in std::iter::once(&tui.palette_prefix).chain(tui.palette_aliases.iter()).chain(std::iter::once(&tui.skill_prefix)) {
        anyhow::ensure!(p.chars().count() == 1 && !p.chars().next().unwrap().is_whitespace(), "TUI prefixes must each be one non-space character");
    }
    anyhow::ensure!(tui.palette_prefix != tui.skill_prefix && !tui.palette_aliases.contains(&tui.skill_prefix), "Skill and palette prefixes must differ");
    let keymap = keymap::Keymap::new(&tui)?;
    let palette_aliases = tui.palette_aliases.clone();
    Ok(App {
        client: client.clone(),
        tx: tx.clone(),
        sessions,
        selected: 0,
        transcripts: HashMap::new(),
        details: HashMap::new(),
        attached: HashSet::new(),
        input: Editor::default(),
        input_images: Vec::new(),
        command: Editor::default(),
        drafts: Vec::new(),
        next_draft_id: 1,
        focus: Focus::Input,
        overlay: Overlay::None,
        parked_form: None,
        status: DEFAULT_STATUS.into(),
        web_url: None,
        hosts: Vec::new(),
        host_filter: None,
        host_chips: Vec::new(),
        harnesses: Vec::new(),
        default_harness: None,
        model_picker_current_only: false,
        skills: Vec::new(),
        palette_prefix: tui.palette_prefix.chars().next().map(|c| c.to_string()).unwrap_or_else(|| "/".into()),
        palette_aliases,
        skill_prefix: tui.skill_prefix.chars().next().map(|c| c.to_string()).unwrap_or_else(|| "$".into()),
        keymap,
        skill_paths: tui.skill_paths,
        previous_directory: None,
        show_thoughts: false,
        show_system: false,
        quit: false,
        pending_select: None,
        initial_empty_checked: false,
        tick: 0,
        chrome: Chrome::detect(),
        areas: Areas::default(),
        viewport: HashMap::new(),
        dialog: dialog::DialogState::default(),
        sidebar_width: None,
        sidebar_hidden: false,
        attention: HashMap::new(),
        sidebar_drag: None,
        last_overlay: 0,
        hover: None,
        menu_pressed: false,
        selection: None,
        rows_cache: Vec::new(),
        transcript_cache: render::TranscriptCache::default(),
        row_meta: Vec::new(),
        transcript_hitboxes: Vec::new(),
        transcript_anchor: None,
        toggled: HashMap::new(),
        composer_sel: None,
        link_cells: Vec::new(),
        cursor_pos: None,
        drag_autoscroll: None,
        composer_max_rows: std::env::var("ACPMUX_COMPOSER_ROWS").ok().and_then(|v| v.parse().ok()).or(cfg.composer_max_rows).unwrap_or(12).clamp(1, 40),
        sidebar_rows: Vec::new(),
        expanded_groups: std::collections::HashSet::new(),
        sidebar_order: Vec::new(),
        sidebar_nav: Vec::new(),
        sidebar_nav_pos: 0,
        sidebar_offset: 0,
        toast: None,
        last_click: None,
        pointer_shape: false,
        buttons: Vec::new(),
        perm_rows: Vec::new(),
        dialog_rect: Rect::default(),
    })
}

/// Wait for a daemon to come back (starting one if none does), then rebuild
/// the client side: watch, session list, harness list, and the attachment
/// of the selected session with its transcript replayed.
async fn reconnect(app: &mut App) -> Result<tokio::sync::mpsc::Receiver<Message>> {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(60);
    let mut delay = std::time::Duration::from_millis(300);
    loop {
        tokio::time::sleep(delay).await;
        match crate::daemon::connect(true).await {
            Ok(c) => {
                c.request(method::MUX_WATCH, json!({"enabled": true})).await?;
                let sessions = c.request(method::MUX_SESSIONS, json!({})).await?;
                let notes = c.notifications().await.ok_or_else(|| anyhow::anyhow!("notifications already taken"))?;
                let build = c.daemon_build().unwrap_or_else(|| "?".into());
                app.client = c;
                app.sessions = sessions.get("sessions").and_then(Value::as_array).cloned().unwrap_or_default();
                app.sort_sessions();
                app.refresh_harnesses();
                if let Some(id) = app.selected_id() {
                    app.attach(&id);
                }
                app.status = format!("reconnected to the daemon (build {build})");
                return Ok(notes);
            }
            Err(e) => {
                if std::time::Instant::now() > deadline {
                    return Err(anyhow::anyhow!("daemon connection closed and no daemon came back within 60s: {e}"));
                }
                delay = (delay * 2).min(std::time::Duration::from_secs(3));
            }
        }
    }
}

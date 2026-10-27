//! The TUI event loop: terminal setup, input, drawing, teardown.

use super::*;

pub async fn run(client: Arc<Client>, initial: Option<String>) -> Result<()> {
    let mut client = client;
    // Read UI preferences without probing or changing harness configuration.
    let path = crate::config::Config::path();
    let cfg: crate::config::Config = if tokio::fs::try_exists(&path).await.unwrap_or(false) {
        serde_json::from_str(&tokio::fs::read_to_string(&path).await?)?
    } else {
        Default::default()
    };
    let mut notes = client
        .notifications()
        .await
        .ok_or_else(|| anyhow::anyhow!("notifications already taken"))?;
    let (tx, mut rx) = mpsc::unbounded_channel::<AppMsg>();
    // This process's memory pressure empties the transcript layout (`tui_memory.rs`).
    let memory = super::tui_memory::TuiMemory::start(tx.clone());
    let watch = client.request(method::MUX_WATCH, json!({"enabled": true})).await?;
    let mut app = make_app(
        client.clone(),
        tx.clone(),
        watch.get("sessions").and_then(Value::as_array).cloned().unwrap_or_default(),
        cfg,
    )?;
    app.sort_sessions();
    {
        let c = client.clone();
        let tx = tx.clone();
        tokio::spawn(async move {
            if let Ok(v) = c.request(method::MUX_HARNESSES, json!({})).await {
                let names: Vec<String> = v
                    .get("harnesses")
                    .and_then(Value::as_object)
                    .map(|o| o.keys().cloned().collect())
                    .unwrap_or_default();
                let _ = tx.send(AppMsg::Agents(
                    names,
                    v.get("defaultHarness").and_then(Value::as_str).map(str::to_owned),
                ));
            }
            if let Ok(v) = c.request(method::MUX_STATUS, json!({})).await {
                let _ = tx.send(AppMsg::Status(v));
            }
        });
    }
    if let Some(id) = initial {
        if let Some(i) = app
            .sessions
            .iter()
            .position(|s| s.get("sessionId").and_then(Value::as_str) == Some(&id))
        {
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
        crossterm::event::PushKeyboardEnhancementFlags(
            crossterm::event::KeyboardEnhancementFlags::DISAMBIGUATE_ESCAPE_CODES
        )
    );
    let mut events = EventStream::new();
    let mut ticker = scheduler::Ticker::default();
    let mut frames = scheduler::FrameSchedule::new(Instant::now());
    let status = StatusReads::start(client.clone(), tx.clone());
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
            memory.drew(&app.transcript_cache);
            frames.presented(Instant::now());
        }
        let moving = app.drag_autoscroll.is_some() || animated(&app);
        let toast_ends = app.toast.as_ref().map(|(_, at)| *at + scheduler::TOAST_FOR);
        let wake = ticker.due(Instant::now(), moving, &[app.keymap.expires_at(), toast_ends]);
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
                    Some(Ok(Event::Resize(..))) => frames.request(),
                    // The person looks again: host chips and the web URL may have changed meanwhile.
                    Some(Ok(Event::FocusGained)) => {
                        frames.request();
                        status.read_again();
                    }
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
            // wakeup-allow: deadline the next animation step while something moves, else a chord's
            // or toast's expiry; a quiet screen has no wake (`scheduler::Ticker`)
            _ = tokio::time::sleep_until(wake.unwrap_or_else(Instant::now).into()), if wake.is_some() => {
                ticker.fired(Instant::now());
                if app.keymap.expire() && app.status.starts_with("chord · ") {
                    app.status = DEFAULT_STATUS.into();
                    frames.request();
                }
                if app.drag_autoscroll.is_some() {
                    app.autoscroll_step();
                    frames.request();
                }
                if animated(&app) { frames.request(); }
                if app.toast.as_ref().is_some_and(|(_, at)| at.elapsed() >= scheduler::TOAST_FOR) {
                    app.toast = None;
                    frames.request();
                }
            }
            m = rx.recv() => {
                if let Some(m) = m {
                    let status_only = matches!(m, AppMsg::Status(_));
                    // An emptied cache stays empty until something else draws.
                    let released = matches!(m, AppMsg::MemoryPressure);
                    let before = status_only.then(|| (app.web_url.clone(), app.hosts.clone()));
                    app.on_msg(m);
                    if !released && before.as_ref().map(|(url, hosts)| url != &app.web_url || hosts != &app.hosts).unwrap_or(true) {
                        frames.request();
                    }
                }
            }
            n = notes.recv() => {
                match n {
                    Some(Message::Notification { method: m, params }) if m != method::MUX_DISCONNECTED => {
                        let p = params.unwrap_or(Value::Null);
                        let selected = p.get("sessionId").and_then(Value::as_str) == app.selected_id().as_deref();
                        // A peer's sessions change when it connects or drops: its host chip may too.
                        if (m == method::MUX_SESSION_CHANGED && p.get("peer").is_some()) || m == "_acpmux/lagged" {
                            status.read_again();
                        }
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
                                status.use_client(client.clone());
                                status.read_again();
                                frames.request();
                            }
                            Err(e) => break Err(e),
                        }
                    }
                }
            }
        }
        if let Some(id) = app.pending_select.take() {
            if let Some(i) = app
                .sessions
                .iter()
                .position(|s| s.get("sessionId").and_then(Value::as_str) == Some(&id))
            {
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

pub(super) fn make_app(
    client: Arc<Client>,
    tx: mpsc::UnboundedSender<AppMsg>,
    sessions: Vec<Value>,
    cfg: crate::config::Config,
) -> Result<App> {
    let tui = cfg.tui.clone();
    for p in std::iter::once(&tui.palette_prefix)
        .chain(tui.palette_aliases.iter())
        .chain(std::iter::once(&tui.skill_prefix))
    {
        anyhow::ensure!(
            p.chars().count() == 1 && !p.chars().next().unwrap().is_whitespace(),
            "TUI prefixes must each be one non-space character"
        );
    }
    anyhow::ensure!(
        tui.palette_prefix != tui.skill_prefix && !tui.palette_aliases.contains(&tui.skill_prefix),
        "Skill and palette prefixes must differ"
    );
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
        recovery_in_flight: HashSet::new(),
        recovery_pages: HashMap::new(),
        recovery_replayed: HashMap::new(),
        recovery_start: HashMap::new(),
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
        palette_prefix: tui
            .palette_prefix
            .chars()
            .next()
            .map(|c| c.to_string())
            .unwrap_or_else(|| "/".into()),
        palette_aliases,
        skill_prefix: tui
            .skill_prefix
            .chars()
            .next()
            .map(|c| c.to_string())
            .unwrap_or_else(|| "$".into()),
        keymap,
        skill_paths: tui.skill_paths,
        show_thoughts: false,
        show_system: false,
        quit: false,
        pending_select: None,
        initial_empty_checked: false,
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
        composer_max_rows: std::env::var("ACPMUX_COMPOSER_ROWS")
            .ok()
            .and_then(|v| v.parse().ok())
            .or(cfg.composer_max_rows)
            .unwrap_or(12)
            .clamp(1, 40),
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
        answering: None,
    })
}

/// What moves on screen: a draft being created, or the selected session's running turn.
fn animated(app: &App) -> bool {
    app.draft().is_some_and(|d| d.creating)
        || app
            .selected_id()
            .and_then(|id| app.transcripts.get(&id))
            .is_some_and(|t| t.status == "running")
}

/// Daemon status (host chips, the web URL), read again on the events that can change it:
/// focus, a peer's session change, a lagged stream, a reconnect. No poll. Asks made while
/// a read is in flight fold into one more read (`Notify` keeps one permit).
struct StatusReads {
    wanted: Arc<tokio::sync::Notify>,
    client: tokio::sync::watch::Sender<Arc<Client>>,
}

impl StatusReads {
    fn start(client: Arc<Client>, tx: mpsc::UnboundedSender<AppMsg>) -> Self {
        let wanted = Arc::new(tokio::sync::Notify::new());
        let (client, mut current) = tokio::sync::watch::channel(client);
        let asked = wanted.clone();
        // task-owner: the TUI; it ends when the TUI drops its sender or its messages.
        tokio::spawn(async move {
            loop {
                tokio::select! {
                    () = asked.notified() => {}
                    changed = current.changed() => {
                        if changed.is_err() { return; }
                        continue;
                    }
                }
                let c = current.borrow_and_update().clone();
                if let Ok(v) = c.request(method::MUX_STATUS, json!({})).await
                    && tx.send(AppMsg::Status(v)).is_err()
                {
                    return;
                }
            }
        });
        Self { wanted, client }
    }

    fn read_again(&self) {
        self.wanted.notify_one();
    }

    fn use_client(&self, client: Arc<Client>) {
        self.client.send_replace(client);
    }
}

/// Wait for a daemon to come back (starting one if none does), then rebuild
/// the client side: watch, session list, harness list, and the attachment
/// of the selected session with its transcript replayed.
async fn reconnect(app: &mut App) -> Result<tokio::sync::mpsc::Receiver<Message>> {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(60);
    let mut delay = std::time::Duration::from_millis(300);
    loop {
        // wakeup-allow: backoff the doubling reconnect delay (0.3 to 3 s) after the daemon went
        // away, at most 60 s
        tokio::time::sleep(delay).await;
        match crate::daemon::connect(true).await {
            Ok(c) => {
                c.request(method::MUX_WATCH, json!({"enabled": true})).await?;
                let sessions = c.request(method::MUX_SESSIONS, json!({})).await?;
                let notes = c
                    .notifications()
                    .await
                    .ok_or_else(|| anyhow::anyhow!("notifications already taken"))?;
                let build = c.daemon_build().unwrap_or_else(|| "?".into());
                app.client = c;
                app.sessions =
                    sessions.get("sessions").and_then(Value::as_array).cloned().unwrap_or_default();
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
                    return Err(anyhow::anyhow!(
                        "daemon connection closed and no daemon came back within 60s: {e}"
                    ));
                }
                delay = (delay * 2).min(std::time::Duration::from_secs(3));
            }
        }
    }
}

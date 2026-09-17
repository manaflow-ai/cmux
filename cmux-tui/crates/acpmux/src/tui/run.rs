//! The TUI event loop: terminal setup, input, drawing, teardown.

use super::*;

pub async fn run(client: Arc<Client>, initial: Option<String>) -> Result<()> {
    let mut notes = client
        .notifications()
        .await
        .ok_or_else(|| anyhow::anyhow!("notifications already taken"))?;
    let (tx, mut rx) = mpsc::unbounded_channel::<AppMsg>();
    let watch = client.request(method::MUX_WATCH, json!({"enabled": true})).await?;
    let mut app = App {
        client: client.clone(),
        tx: tx.clone(),
        sessions: watch.get("sessions").and_then(Value::as_array).cloned().unwrap_or_default(),
        selected: 0,
        transcripts: HashMap::new(),
        details: HashMap::new(),
        attached: HashSet::new(),
        input: Editor::default(),
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
        agents: Vec::new(),
        default_agent: None,
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
        selection: None,
        rows_cache: Vec::new(),
        row_meta: Vec::new(),
        toggled: HashMap::new(),
        composer_sel: None,
        link_cells: Vec::new(),
        cursor_pos: None,
        drag_autoscroll: None,
        composer_max_rows: std::env::var("ACPMUX_COMPOSER_ROWS").ok().and_then(|v| v.parse().ok()).or_else(|| crate::config::Config::load().ok().and_then(|c| c.composer_max_rows)).unwrap_or(12).clamp(1, 40),
        sidebar_rows: Vec::new(),
        sidebar_offset: 0,
        toast: None,
        last_click: None,
        pointer_shape: false,
        buttons: Vec::new(),
        perm_rows: Vec::new(),
        dialog_rect: Rect::default(),
    };
    app.sort_sessions();
    {
        let c = client.clone();
        let tx = tx.clone();
        tokio::spawn(async move {
            if let Ok(v) = c.request(method::MUX_AGENTS, json!({})).await {
                let names: Vec<String> = v.get("agents").and_then(Value::as_object).map(|o| o.keys().cloned().collect()).unwrap_or_default();
                let _ = tx.send(AppMsg::Agents(names, v.get("defaultAgent").and_then(Value::as_str).map(str::to_owned)));
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

    let mut terminal = ratatui::init();
    let _ = crossterm::execute!(
        std::io::stdout(),
        crossterm::event::EnableMouseCapture,
        crossterm::event::EnableBracketedPaste,
        crossterm::event::EnableFocusChange,
        crossterm::event::PushKeyboardEnhancementFlags(crossterm::event::KeyboardEnhancementFlags::DISAMBIGUATE_ESCAPE_CODES)
    );
    let mut events = EventStream::new();
    let mut tick = tokio::time::interval(std::time::Duration::from_millis(80));
    let result: Result<()> = loop {
        // First paint with no sessions: open the form so the empty screen is not a dead end.
        if !app.initial_empty_checked && !app.agents.is_empty() {
            app.initial_empty_checked = true;
            if app.sessions.is_empty() && matches!(app.overlay, Overlay::None) {
                app.open_new_session();
            }
        }
        if let Err(e) = terminal.draw(|f| draw(f, &mut app)) {
            break Err(e.into());
        }
        if let Err(e) = links::paint(&mut std::io::stdout(), &app.link_cells, app.cursor_pos) {
            break Err(e.into());
        }
        tokio::select! {
            ev = events.next() => {
                match ev {
                    Some(Ok(Event::Key(k))) if k.kind != crossterm::event::KeyEventKind::Release => app.on_key(k),
                    Some(Ok(Event::Mouse(m))) => app.on_mouse(m),
                    Some(Ok(Event::Paste(s))) => {
                        match &mut app.overlay {
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
                        }
                    }
                    Some(Err(e)) => break Err(e.into()),
                    None => break Ok(()),
                    _ => {}
                }
            }
            n = notes.recv() => {
                match n {
                    Some(Message::Notification { method: m, params }) => app.on_notification(&m, params.unwrap_or(Value::Null)),
                    Some(_) => {}
                    None => { app.status = "daemon connection closed".into(); break Ok(()); }
                }
            }
            m = rx.recv() => {
                if let Some(m) = m { app.on_msg(m); }
            }
            _ = tick.tick() => {
                app.tick = app.tick.wrapping_add(1);
                app.autoscroll_step();
                if app.tick % 50 == 0 {
                    let c = client.clone();
                    let tx = tx.clone();
                    tokio::spawn(async move {
                        if let Ok(v) = c.request(method::MUX_STATUS, json!({})).await {
                            let _ = tx.send(AppMsg::Status(v));
                        }
                    });
                }
                if let Some((_, at)) = &app.toast {
                    if at.elapsed().as_millis() > 1800 {
                        app.toast = None;
                    }
                }
            }
        }
        if let Some(id) = app.pending_select.take() {
            if let Some(i) = app.sessions.iter().position(|s| s.get("sessionId").and_then(Value::as_str) == Some(&id)) {
                app.drafts.retain(|d| !d.creating);
                app.select(i + app.drafts.len());
                app.focus = Focus::Input;
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

//! Server events: subscriptions, surface event scopes, and the line handler.

use super::*;

impl RemoteSession {
    pub(super) fn emit(&self, event: MuxEvent) {
        self.subscribers.emit(event);
    }

    fn invalidate_tree_once(&self) -> bool {
        !self.tree_stale.swap(true, Ordering::AcqRel)
    }

    pub fn subscribe(&self) -> MuxEventReceiver {
        self.primed_subscription
            .lock()
            .unwrap()
            .take()
            .unwrap_or_else(|| self.subscribers.subscribe())
    }

    pub(super) fn prime_local_subscription(&self) {
        let receiver = self.subscribers.subscribe();
        let previous = self.primed_subscription.lock().unwrap().replace(receiver);
        debug_assert!(previous.is_none(), "event receiver must be consumed before re-priming");
    }

    /// Limit this connection to events that can affect one attached terminal.
    /// Surface IDs are allocated from one, so zero is the unscoped sentinel.
    pub fn scope_events_to_surface(&self, surface: SurfaceId) -> anyhow::Result<()> {
        debug_assert_ne!(surface, 0);
        if !self.supports_surface_subscription_filter() {
            anyhow::bail!("remote server does not support filtered surface subscriptions");
        }
        if self
            .subscription_started
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            anyhow::bail!("event subscription already started");
        }
        self.event_surface_filter.store(surface, Ordering::Release);
        self.prime_local_subscription();
        if let Err(error) = self.request(self.subscription_request()) {
            self.primed_subscription.lock().unwrap().take();
            self.event_surface_filter.store(0, Ordering::Release);
            self.subscription_started.store(false, Ordering::Release);
            return Err(error);
        }
        Ok(())
    }

    pub(super) fn subscription_request(&self) -> Value {
        let surface = self.event_surface_filter.load(Ordering::Acquire);
        if surface == 0 {
            json!({"cmd": "subscribe"})
        } else {
            json!({"cmd": "subscribe", "surface": surface})
        }
    }

    fn accepts_event_in_surface_scope(&self, event: &str, value: &Value) -> bool {
        let target = self.event_surface_filter.load(Ordering::Acquire);
        if target == 0 {
            return true;
        }
        let surface = value.get("surface").and_then(Value::as_u64);
        match event {
            "client-attached"
            | "client-changed"
            | "client-detached"
            | "client-list-invalidated" => false,
            "notification" => surface.is_none_or(|surface| surface == target),
            "overflow" if value.get("scope").and_then(Value::as_str) == Some("surface") => {
                surface == Some(target)
            }
            "vt-state"
            | "surface-output"
            | "surface-resized"
            | "surface-resize-failed"
            | "output"
            | "resized"
            | "colors-changed"
            | "browser-state"
            | "frame"
            | "detached"
            | "surface-exited"
            | "agent-changed"
            | "title-changed"
            | "bell"
            | "size-state"
            | "scroll-changed" => surface == Some(target),
            _ => true,
        }
    }

    pub(super) fn report_read_progress(&self, partial: &[u8]) {
        let Some(target) = remote_progress_target(partial) else { return };
        let pending = self.pending.lock().unwrap();
        let attach_progressed = match target {
            RemoteProgressTarget::Request(id) => {
                if let Some(request) = pending.get(&id) {
                    request.progress.fetch_add(1, Ordering::Release);
                    request.attach_surface.is_some()
                } else {
                    false
                }
            }
            RemoteProgressTarget::AttachSurface(surface) => {
                pending.progress_for_attach_surface(surface)
            }
        };
        drop(pending);
        if attach_progressed {
            // A JSON-lines transport serializes complete messages. An attach
            // queued behind this progressing snapshot cannot receive its own
            // bytes yet, so its pre-response idle window follows this epoch.
            self.attach_progress.fetch_add(1, Ordering::Release);
        }
    }

    pub(super) fn handle_line(self: &Arc<Self>, value: Value) {
        let surface_id = || value.get("surface").and_then(|v| v.as_u64());
        let event = value.get("event").and_then(Value::as_str);
        if event.is_some_and(|event| !self.accepts_event_in_surface_scope(event, &value)) {
            return;
        }
        match event {
            None => {
                // Response: route to the waiting request.
                let Some(id) = value.get("id").and_then(|v| v.as_u64()) else { return };
                if let Some(request) = self.pending.lock().unwrap().remove(&id) {
                    let _ = request.response.send(value);
                }
            }
            Some("vt-state") => {
                let Some(id) = surface_id() else { return };
                let Some((cols, rows)) = remote_terminal_size(&value) else { return };
                let Some(data) = value.get("data").and_then(|v| v.as_str()) else { return };
                let Ok(replay) = base64::engine::general_purpose::STANDARD.decode(data) else {
                    return;
                };
                let colors = value.get("colors").and_then(parse_terminal_colors);
                let Ok(pending_sequence) = parse_pending_sequence(&value) else {
                    self.disconnect_transport();
                    return;
                };
                self.log_frame(
                    id,
                    format_args!("vt-state cols={cols} rows={rows} bytes={}", replay.len()),
                );
                let Ok(kitty_image_aliases) = parse_kitty_image_aliases(&value) else {
                    self.disconnect_transport();
                    return;
                };
                let Ok(kitty_state) = parse_kitty_replay_state(&value) else {
                    self.disconnect_transport();
                    return;
                };
                if let Some(surface) = self.surfaces.lock().unwrap().get(&id).cloned() {
                    if surface
                        .apply_stream_resize_with_colors(
                            cols,
                            rows,
                            Some(&replay),
                            &kitty_image_aliases,
                            Some(kitty_state),
                            colors.as_ref(),
                            &pending_sequence,
                        )
                        .is_err()
                    {
                        self.disconnect_transport();
                        return;
                    }
                    surface.dirty.store(true, Ordering::Release);
                }
                self.emit(MuxEvent::SurfaceOutput(id));
            }
            Some("surface-resized") => {
                let Some(id) = surface_id() else { return };
                let Some((cols, rows)) = remote_terminal_size(&value) else { return };
                self.emit(MuxEvent::SurfaceResized {
                    surface: id,
                    cols,
                    rows,
                    reservation_id: value.get("reservation_id").and_then(Value::as_u64),
                });
            }
            Some("surface-resize-failed") => {
                let Some(id) = surface_id() else { return };
                let Some((cols, rows)) = remote_terminal_size(&value) else { return };
                let error =
                    value.get("error").and_then(Value::as_str).unwrap_or("browser resize failed");
                let retry_after_ms = value.get("retry_after_ms").and_then(Value::as_u64);
                let reservation_id = value.get("reservation_id").and_then(Value::as_u64);
                if let Some(surface) = self.surfaces.lock().unwrap().get(&id).cloned() {
                    surface.clear_reported_size_if((cols.max(1), rows.max(1)));
                }
                self.emit(MuxEvent::SurfaceResizeFailed {
                    surface: id,
                    cols,
                    rows,
                    error: Arc::<str>::from(error),
                    retry_after_ms,
                    reservation_id,
                });
            }
            Some("output") => {
                let Some(id) = surface_id() else { return };
                let Some(data) = value.get("data").and_then(|v| v.as_str()) else { return };
                let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(data) else {
                    return;
                };
                let colors = value.get("colors").and_then(parse_terminal_colors);
                self.log_frame(id, format_args!("output bytes={}", bytes.len()));
                if let Some(surface) = self.surfaces.lock().unwrap().get(&id).cloned() {
                    surface.scan_cursor_provenance(&bytes);
                    let mut term = surface.term.lock().unwrap();
                    term.vt_write(&bytes);
                    if let Some(colors) = colors.as_ref() {
                        apply_terminal_colors(&mut term, colors);
                    }
                    surface.sync_mouse_encoders(&term);
                    surface.content_generation.fetch_add(1, Ordering::AcqRel);
                    drop(term);
                    if !surface.dirty.swap(true, Ordering::AcqRel) {
                        self.emit(MuxEvent::SurfaceOutput(id));
                    }
                }
            }
            Some("resized") => {
                let Some(id) = surface_id() else { return };
                let Some((cols, rows)) = remote_terminal_size(&value) else { return };
                let replay = match value.get("replay").or_else(|| value.get("data")) {
                    Some(data) => {
                        let Some(data) = data.as_str() else {
                            self.disconnect_transport();
                            return;
                        };
                        let Ok(replay) = base64::engine::general_purpose::STANDARD.decode(data)
                        else {
                            self.disconnect_transport();
                            return;
                        };
                        Some(replay)
                    }
                    None => None,
                };
                let Ok(kitty_image_aliases) = parse_kitty_image_aliases(&value) else {
                    self.disconnect_transport();
                    return;
                };
                let Ok(kitty_state) = parse_kitty_replay_state(&value) else {
                    self.disconnect_transport();
                    return;
                };
                let colors = value.get("colors").and_then(parse_terminal_colors);
                let Ok(pending_sequence) = parse_pending_sequence(&value) else {
                    self.disconnect_transport();
                    return;
                };
                self.log_frame(
                    id,
                    format_args!(
                        "resized cols={cols} rows={rows} bytes={}",
                        replay.as_ref().map(|bytes| bytes.len()).unwrap_or(0)
                    ),
                );
                if let Some(surface) = self.surfaces.lock().unwrap().get(&id).cloned() {
                    if surface
                        .apply_stream_resize_with_colors(
                            cols,
                            rows,
                            replay.as_deref(),
                            &kitty_image_aliases,
                            Some(kitty_state),
                            colors.as_ref(),
                            &pending_sequence,
                        )
                        .is_err()
                    {
                        self.disconnect_transport();
                        return;
                    }
                    surface.dirty.store(true, Ordering::Release);
                    self.emit(MuxEvent::SurfaceResized {
                        surface: id,
                        cols,
                        rows,
                        reservation_id: None,
                    });
                    self.emit(MuxEvent::SurfaceOutput(id));
                }
            }
            Some("colors-changed") => {
                let Some(id) = surface_id() else { return };
                let Some(colors) = parse_terminal_colors(&value) else { return };
                if let Some(surface) = self.surfaces.lock().unwrap().get(&id).cloned() {
                    let mut term = surface.term.lock().unwrap();
                    apply_terminal_colors(&mut term, &colors);
                    surface.sync_mouse_encoders(&term);
                    surface.content_generation.fetch_add(1, Ordering::AcqRel);
                    drop(term);
                    if !surface.dirty.swap(true, Ordering::AcqRel) {
                        self.emit(MuxEvent::SurfaceOutput(id));
                    }
                }
            }
            Some("browser-state") => {
                let Some(id) = surface_id() else { return };
                if let Some(surface) = self.surfaces.lock().unwrap().get(&id).cloned() {
                    let Some((cols, rows)) = remote_terminal_size(&value) else { return };
                    if surface.apply_stream_resize(cols, rows, None, &[]).is_err() {
                        self.disconnect_transport();
                        return;
                    }
                    surface.update_browser_state(&value);
                    surface.dirty.store(true, Ordering::Release);
                }
                if let Some(title) = value.get("title").and_then(Value::as_str) {
                    self.emit(MuxEvent::TitleChanged {
                        surface: id,
                        title: Arc::<str>::from(title),
                    });
                }
                self.emit(MuxEvent::SurfaceOutput(id));
            }
            Some("frame") => {
                let Some(id) = surface_id() else { return };
                if let Some(surface) = self.surfaces.lock().unwrap().get(&id).cloned() {
                    surface.update_browser_frame(&value);
                    if !surface.dirty.swap(true, Ordering::AcqRel) {
                        self.emit(MuxEvent::SurfaceOutput(id));
                    }
                }
            }
            Some("detached") => {
                if let Some(id) = surface_id() {
                    self.surfaces.lock().unwrap().remove(&id);
                    self.size_states.lock().unwrap().remove(&id);
                    self.emit(MuxEvent::SurfaceOutput(id));
                }
            }
            Some(cmux_tui_core::server::DAEMON_SHUTDOWN_EVENT) => {
                let mut state = self.disconnect_state.lock().unwrap();
                if matches!(&*state, DisconnectState::Active) {
                    *state = DisconnectState::ExpectedRemoteShutdown;
                }
                drop(state);
                self.disconnect_state.notify();
                // Wake every request that was already admitted before the
                // daemon announced its shutdown. The synthetic response is
                // classified with the expected-remote state, so callers get
                // DaemonShutdown instead of a timeout when EOF follows.
                self.begin_shutdown();
                self.emit(MuxEvent::Empty);
            }
            Some("tree-changed") => {
                self.tree_stale.store(true, Ordering::Release);
                self.emit(MuxEvent::TreeChanged);
            }
            Some("size-state") => {
                let Some(surface) = surface_id() else { return };
                let Some(state) = value
                    .get("state")
                    .cloned()
                    .and_then(|state| serde_json::from_value::<TerminalSizingState>(state).ok())
                else {
                    return;
                };
                let self_participant =
                    value.get("self_participant").and_then(Value::as_str).map(str::to_string);
                if !self.store_size_state(surface, state.clone(), self_participant) {
                    return;
                }
                self.emit(MuxEvent::SizeStateChanged {
                    surface,
                    runtime: surface,
                    state: Arc::new(state),
                });
            }
            Some("agent-changed") => {
                let Some(surface) = surface_id() else { return };
                let Some(state) = value.get("state").and_then(Value::as_str) else { return };
                let Some(source) = value.get("source").and_then(Value::as_str) else { return };
                let Some(updated_at_ms) = value.get("updated_at_ms").and_then(Value::as_u64) else {
                    return;
                };
                let session = value.get("session").and_then(Value::as_str).map(str::to_string);
                let agent_adapter = value.get("agent").and_then(Value::as_str).map(str::to_string);
                let agent = AgentInfo {
                    surface,
                    state: state.to_string(),
                    source: source.to_string(),
                    session,
                    agent: agent_adapter,
                    updated_at_ms,
                };
                let event = MuxEvent::AgentChanged {
                    surface,
                    state: Arc::from(agent.state.as_str()),
                    source: Arc::from(agent.source.as_str()),
                    session: agent.session.as_deref().map(Arc::from),
                    agent: agent.agent.as_deref().map(Arc::from),
                    updated_at_ms,
                };
                {
                    let retired_surfaces = self.retired_surfaces.lock().unwrap();
                    if retired_surfaces.contains(&surface) {
                        return;
                    }
                    self.tree.lock().unwrap().update_agent(agent, &retired_surfaces);
                }
                self.emit(event);
            }
            Some("layout-changed") => {
                self.tree_stale.store(true, Ordering::Release);
                if let Some(screen) = value.get("screen").and_then(|v| v.as_u64()) {
                    self.emit(MuxEvent::LayoutChanged(screen));
                } else {
                    self.emit(MuxEvent::TreeChanged);
                }
            }
            Some("surface-exited") => {
                if let Some(id) = surface_id() {
                    // Retire the mirror immediately. The authoritative tree
                    // refresh may lag this event, but input and reattach must
                    // already fail closed for a known-exited surface.
                    self.drop_surface(id);
                    self.tree_stale.store(true, Ordering::Release);
                    self.emit(MuxEvent::SurfaceExited(id));
                }
            }
            Some("title-changed") => {
                if let Some(id) = surface_id() {
                    if let Some(title) = value.get("title").and_then(Value::as_str) {
                        let updated = self.tree.lock().unwrap().update_title(id, title.to_string());
                        if !updated && self.invalidate_tree_once() {
                            self.emit(MuxEvent::TreeChanged);
                        }
                        self.emit(MuxEvent::TitleChanged {
                            surface: id,
                            title: Arc::<str>::from(title),
                        });
                    } else if self.invalidate_tree_once() {
                        self.emit(MuxEvent::TreeChanged);
                    }
                }
            }
            Some("bell") => {
                if let Some(id) = surface_id() {
                    self.emit(MuxEvent::Bell(id));
                }
            }
            Some("notification") => {
                let Some(notification) = value.get("notification").and_then(Value::as_u64) else {
                    return;
                };
                let level = match value.get("level").and_then(Value::as_str) {
                    Some("warning") => NotificationLevel::Warning,
                    Some("error") => NotificationLevel::Error,
                    _ => NotificationLevel::Info,
                };
                self.emit(MuxEvent::Notification(NotificationEvent {
                    notification,
                    title: value
                        .get("title")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string(),
                    body: value.get("body").and_then(Value::as_str).unwrap_or_default().to_string(),
                    level,
                    surface: surface_id(),
                    source: value
                        .get("source")
                        .and_then(Value::as_str)
                        .and_then(NotificationSource::parse)
                        .unwrap_or(NotificationSource::Daemon),
                }));
            }
            Some("overflow") => {
                if value.get("scope").and_then(Value::as_str) == Some("surface") {
                    let surface_id = surface_id().filter(|surface_id| *surface_id != 0);
                    if let Some(surface_id) = surface_id {
                        let was_attached =
                            self.surfaces.lock().unwrap().remove(&surface_id).is_some();
                        if !was_attached {
                            return;
                        }
                        let reconnect_was_required =
                            self.surface_overflow_reconnect_required.load(Ordering::Acquire);
                        let (delay, stopped) = self.record_surface_overflow(surface_id);
                        self.emit(MuxEvent::SurfaceOutput(surface_id));
                        let reconnect_required =
                            self.surface_overflow_reconnect_required.load(Ordering::Acquire);
                        if !reconnect_required || !reconnect_was_required {
                            self.emit(MuxEvent::Status(if reconnect_required {
                                "surface overflow recovery capacity was exhausted; detach and reconnect to recover"
                                    .to_string()
                            } else if stopped {
                                format!(
                                    "surface {surface_id} event stream repeatedly overflowed; detach and reconnect to recover"
                                )
                            } else {
                                format!(
                                    "surface {surface_id} event stream overflowed; retrying in {} ms",
                                    delay.unwrap_or_default().as_millis()
                                )
                            }));
                        }
                    }
                    return;
                }
                self.tree_stale.store(true, Ordering::Release);
                self.start_subscription_recovery();
            }
            Some("status") => {
                if let Some(message) = value.get("message").and_then(|v| v.as_str()) {
                    self.emit(MuxEvent::Status(message.to_string()));
                }
            }
            Some("graphics-status") => {
                if let Some(status) = parse_graphics_status(&value) {
                    self.emit(MuxEvent::GraphicsStatus(status));
                }
            }
            Some("machine-usage-changed") => {
                self.emit(MuxEvent::MachineUsageChanged(super::super::parse_machine_usage(&value)));
            }
            Some("config-reload-requested") => self.emit(MuxEvent::ConfigReloadRequested),
            Some("window-title-requested") => {
                if let Some(title) = value.get("title").and_then(|v| v.as_str()) {
                    self.emit(MuxEvent::WindowTitleRequested(title.to_string()));
                }
            }
            Some("scroll-changed") => {
                if let (Some(surface), Some(offset), Some(at_bottom)) = (
                    surface_id(),
                    value.get("offset").and_then(|v| v.as_u64()),
                    value.get("at_bottom").and_then(|v| v.as_bool()),
                ) {
                    self.emit(MuxEvent::ScrollChanged { surface, offset, at_bottom });
                }
            }
            Some("client-attached") => {
                let Some(client) = value.get("client").and_then(Value::as_u64) else {
                    return;
                };
                self.emit(MuxEvent::ClientAttached {
                    client,
                    transport: value
                        .get("transport")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string(),
                    name: value.get("name").and_then(Value::as_str).map(str::to_string),
                    kind: value.get("kind").and_then(Value::as_str).map(str::to_string),
                });
            }
            Some("client-changed") => {
                let Some(client) = value.get("client").and_then(Value::as_u64) else {
                    return;
                };
                self.emit(MuxEvent::ClientChanged {
                    client,
                    name: value.get("name").and_then(Value::as_str).map(str::to_string),
                    kind: value.get("kind").and_then(Value::as_str).map(str::to_string),
                });
            }
            Some("client-detached") => {
                if let Some(client) = value.get("client").and_then(Value::as_u64) {
                    self.emit(MuxEvent::ClientDetached(client));
                }
            }
            Some("client-list-invalidated") => self.emit(MuxEvent::ClientListInvalidated),
            Some("pairing-requested") => {
                let challenge = PairingChallenge {
                    id: value.get("request").and_then(Value::as_u64).unwrap_or_default(),
                    code: value.get("code").and_then(Value::as_str).unwrap_or_default().to_string(),
                    peer: value.get("peer").and_then(Value::as_str).unwrap_or_default().to_string(),
                    expires_in: value.get("expires_in").and_then(Value::as_u64).unwrap_or_default(),
                };
                if challenge.id != 0 && !challenge.code.is_empty() {
                    self.emit(MuxEvent::PairingRequested(challenge));
                }
            }
            Some("pairing-resolved") => {
                if let Some(request) = value.get("request").and_then(Value::as_u64) {
                    self.emit(MuxEvent::PairingResolved { request });
                }
            }
            Some("empty") => self.emit(MuxEvent::Empty),
            Some(_) => {}
        }
    }

    fn start_subscription_recovery(self: &Arc<Self>) {
        {
            let mut recovery = self.subscription_recovery.lock().unwrap();
            recovery.generation = recovery.generation.wrapping_add(1).max(1);
            if recovery.in_flight {
                return;
            }
            recovery.in_flight = true;
        }
        self.emit(MuxEvent::Status("event subscription overflowed; resubscribing".to_string()));
        let session = self.clone();
        let spawn =
            std::thread::Builder::new().name("remote-resubscribe".into()).spawn(move || {
                loop {
                    let recovery_generation =
                        session.subscription_recovery.lock().unwrap().generation;
                    let first = session.request(session.subscription_request());
                    let result = match first {
                        Err(error) if Self::subscription_recovery_is_retryable(&error) => {
                            session.request(session.subscription_request())
                        }
                        result => result,
                    };
                    let mut recovery = session.subscription_recovery.lock().unwrap();
                    if recovery.generation != recovery_generation {
                        drop(recovery);
                        continue;
                    }
                    match result {
                        Ok(_) => {
                            session.emit(MuxEvent::Status(
                                "event subscription overflowed; resubscribed".to_string(),
                            ));
                            session.emit(MuxEvent::TreeChanged);
                            session.emit(MuxEvent::ClientListInvalidated);
                        }
                        Err(error) => {
                            session.emit(MuxEvent::Status(format!(
                                "event subscription overflowed; resubscribe failed: {error}"
                            )));
                            session.emit(MuxEvent::Empty);
                        }
                    }
                    recovery.in_flight = false;
                    return;
                }
            });
        if let Err(error) = spawn {
            let mut recovery = self.subscription_recovery.lock().unwrap();
            self.emit(MuxEvent::Status(format!(
                "event subscription overflowed; resubscribe failed: {error}"
            )));
            self.emit(MuxEvent::Empty);
            recovery.in_flight = false;
        }
    }

    pub(super) fn subscription_recovery_is_retryable(error: &anyhow::Error) -> bool {
        matches!(
            error.downcast_ref::<RemoteRequestError>(),
            Some(RemoteRequestError::Rejected { .. })
        )
    }

    pub(super) fn log_frame(&self, surface: SurfaceId, line: std::fmt::Arguments<'_>) {
        if self.frame_dump_dir.is_none() {
            return;
        }
        self.frame_logs.lock().unwrap().push(surface, line.to_string());
    }
}

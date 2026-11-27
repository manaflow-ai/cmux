//! Frame I/O: opening and reopening a terminal stream, receiving its frames and supervising resizes.

use super::*;

impl TerminalOpenOptions {
    pub(super) fn requests_priority(&self) -> bool {
        self.viewer_size_priority && !self.priority_unsupported.load(Ordering::Acquire)
    }
}

impl TerminalOpenError {
    pub(super) fn into_message(self) -> String {
        match self {
            Self::Rejected { code, message } => {
                format!("terminal service rejected the open ({code}): {message}")
            }
            Self::Failed(message) => message,
        }
    }
}

pub(super) async fn open_terminal_stream(
    multiplexer: &Arc<ServiceMultiplexer>,
    terminal_id: &TerminalPublicId,
    options: &TerminalOpenOptions,
) -> Result<Arc<ServiceStream>, String> {
    open_terminal_stream_with_timeout(multiplexer, terminal_id, options, None).await
}

pub(super) async fn open_terminal_stream_with_timeout(
    multiplexer: &Arc<ServiceMultiplexer>,
    terminal_id: &TerminalPublicId,
    options: &TerminalOpenOptions,
    timeout: Option<StdDuration>,
) -> Result<Arc<ServiceStream>, String> {
    open_terminal_stream_typed_with_timeout(multiplexer, terminal_id, options, timeout)
        .await
        .map_err(TerminalOpenError::into_message)
}

/// [`open_terminal_stream`], keeping whether the daemon refused the open.
pub(super) async fn open_terminal_stream_typed(
    multiplexer: &Arc<ServiceMultiplexer>,
    terminal_id: &TerminalPublicId,
    options: &TerminalOpenOptions,
) -> Result<Arc<ServiceStream>, TerminalOpenError> {
    open_terminal_stream_typed_with_timeout(multiplexer, terminal_id, options, None).await
}

pub(super) async fn open_terminal_stream_typed_with_timeout(
    multiplexer: &Arc<ServiceMultiplexer>,
    terminal_id: &TerminalPublicId,
    options: &TerminalOpenOptions,
    timeout: Option<StdDuration>,
) -> Result<Arc<ServiceStream>, TerminalOpenError> {
    let started = Instant::now();
    let remaining = || timeout.map(|limit| limit.saturating_sub(started.elapsed()));
    if options.requests_priority() {
        match open_terminal_stream_once(multiplexer, terminal_id, true, remaining()).await {
            Err(TerminalOpenError::Rejected { code, .. }) if code == INVALID_ARGUMENT => {}
            result => return result,
        }
        // A daemon that predates viewer-size priority rejects the key but
        // still serves the ordinary smallest-viewer stream.
        let stream =
            open_terminal_stream_once(multiplexer, terminal_id, false, remaining()).await?;
        options.priority_unsupported.store(true, Ordering::Release);
        return Ok(stream);
    }
    open_terminal_stream_once(multiplexer, terminal_id, false, remaining()).await
}

/// Whether a dropped terminal stream's reopen should stop, after `refused` refusals in a row:
/// see [`TERMINAL_REOPEN_REFUSALS`]. Anything else (a slow or dropped link) is tried again,
/// however many times it takes.
pub(super) fn reconnect_is_over(multiplexer: &ServiceMultiplexer, refused: u32) -> bool {
    refused >= TERMINAL_REOPEN_REFUSALS
        || multiplexer.session_unavailable()
        || multiplexer.subscribe_fatal().borrow().is_some()
}

pub(super) async fn open_terminal_stream_once(
    multiplexer: &Arc<ServiceMultiplexer>,
    terminal_id: &TerminalPublicId,
    viewer_size_priority: bool,
    timeout: Option<StdDuration>,
) -> Result<Arc<ServiceStream>, TerminalOpenError> {
    let started = Instant::now();
    let mut metadata = BTreeMap::from([("terminal".to_string(), terminal_id.to_string())]);
    if viewer_size_priority {
        metadata.insert(
            TERMINAL_BYTES_VIEWER_SIZE_PRIORITY.into(),
            TERMINAL_BYTES_VIEWER_SIZE_PRIORITY_PREFERRED.into(),
        );
    }
    let open = async {
        multiplexer
            .open(Service::TerminalBytes, metadata)
            .await
            .map_err(|error| format!("open terminal-bytes-v1: {error}"))
    };
    let opened = match timeout {
        Some(timeout) => connect_with_timeout(open, timeout).await,
        None => open.await,
    };
    let stream = Arc::new(opened.map_err(TerminalOpenError::Failed)?);
    let handshake = async {
        let opened = stream
            .receive()
            .await
            .map_err(|error| error.to_string())?
            .ok_or_else(|| "terminal service closed before Opened".to_string())?;
        let control: ServiceControl =
            serde_json::from_slice(&opened.payload).map_err(|error| error.to_string())?;
        Ok::<_, String>((opened.lane, control))
    };
    let handshake = match timeout {
        Some(timeout) => {
            connect_with_timeout(handshake, timeout.saturating_sub(started.elapsed())).await
        }
        None => handshake.await,
    };
    let error = match handshake {
        Ok((Lane::Interactive, ServiceControl::Opened { service: Service::TerminalBytes })) => {
            return Ok(stream);
        }
        Ok((_, ServiceControl::Rejected { code, message })) => {
            TerminalOpenError::Rejected { code, message }
        }
        Ok(_) => TerminalOpenError::Failed(INVALID_OPENED.into()),
        Err(error) => TerminalOpenError::Failed(error),
    };
    let _ = stream.close().await;
    Err(error)
}

pub(super) async fn connect_client(
    invitation_uri: &str,
    terminal_id: TerminalPublicId,
) -> Result<
    (
        Arc<ServiceStream>,
        Arc<ClientConnection>,
        Arc<IrohProvider>,
        Arc<ServiceMultiplexer>,
        Arc<Mutex<ClientState>>,
    ),
    String,
> {
    let invitation = EnrollmentInvitation::from_uri(invitation_uri)
        .map_err(|error| format!("invitation: {error}"))?;
    let route = invitation
        .route_hints
        .iter()
        .find(|route| route.starts_with("iroh://"))
        .ok_or_else(|| "invitation has no Iroh route".to_string())?;
    let (endpoint, routing) = resolve_iroh_route(route)?;
    let mut session_bytes = [0u8; 16];
    getrandom::fill(&mut session_bytes).map_err(|error| error.to_string())?;
    let session = SessionId(session_bytes);
    let provider = Arc::new(
        IrohProvider::new(IrohProviderConfig {
            discovery_n0: true,
            ..IrohProviderConfig::default()
        })
        .map_err(|error| error.to_string())?,
    );
    let group = provider
        .connect(ConnectRequest { endpoint, session, lane_policy: LanePolicy::Isolated, routing })
        .await
        .map_err(|error| format!("Iroh connect: {error}"))?;
    let daemon_key = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(&invitation.daemon_public_key)
        .map_err(|error| format!("daemon key: {error}"))?
        .try_into()
        .map_err(|bytes: Vec<u8>| format!("daemon key is {} bytes", bytes.len()))?;
    let invitation_secret = invitation.secret_bytes().map_err(|error| error.to_string())?;
    let connection = ClientConnection::connect(
        group,
        ClientConnectionConfig {
            identity: StaticIdentity::generate().map_err(|error| error.to_string())?,
            expected_daemon: Some(daemon_key),
            auth: ClientAuthMode::Invitation {
                id: invitation.id,
                secret: Zeroizing::new(invitation_secret),
            },
            device_name: "TerminalBytes Demo".into(),
            session,
            lane_policy: LanePolicy::Isolated,
            limits: Default::default(),
            reconnect: ReconnectPolicy::default(),
        },
    )
    .await
    .map_err(|error| format!("Noise enrollment: {error}"))?;
    let snapshot = connection.snapshot().await;
    let path = snapshot
        .transport
        .selected_path
        .as_ref()
        .map(|path| format!("{:?}", path.kind).to_lowercase())
        .unwrap_or_else(|| snapshot.transport.route.clone());
    let state = Arc::new(Mutex::new(
        ClientState::new(
            snapshot.transport.provider,
            path,
            snapshot.generation,
            terminal_id.clone(),
        )
        .map_err(|error| format!("libghostty: {error}"))?,
    ));
    let multiplexer = ServiceMultiplexer::new(connection.clone(), EndpointRole::Client);
    let stream =
        open_terminal_stream(&multiplexer, &terminal_id, &TerminalOpenOptions::default()).await?;
    Ok((stream, connection, provider, multiplexer, state))
}

pub(super) fn set_client_status(
    state: &Arc<Mutex<ClientState>>,
    updates: &ClientUpdates,
    status: String,
) {
    state.lock().unwrap().status = status;
    updates.notify();
}

pub(super) fn finish_decoder(
    decoder: &FrameDecoder,
    state: &Arc<Mutex<ClientState>>,
    updates: &ClientUpdates,
) -> bool {
    match decoder.finish() {
        Ok(()) => true,
        Err(error) => {
            set_client_status(state, updates, format!("codec: {error}"));
            false
        }
    }
}

pub(super) async fn receive_frames(
    stream: Arc<ServiceStream>,
    state: Arc<Mutex<ClientState>>,
    updates: Arc<ClientUpdates>,
    raw_output: Arc<RawOutput>,
) -> StreamOutcome {
    let mut decoder = FrameDecoder::new(MAX_FRAME_PAYLOAD);
    loop {
        match stream.receive().await {
            Ok(Some(chunk)) => {
                if chunk.lane != Lane::Interactive {
                    set_client_status(&state, &updates, "wrong-lane".into());
                    let _ = finish_decoder(&decoder, &state, &updates);
                    return StreamOutcome::Restart;
                }
                match decoder.push(&chunk.payload) {
                    Ok(frames) => {
                        let mut outcome = None;
                        for frame in frames {
                            let applied = state.lock().unwrap().apply(frame);
                            // The state lock is released before the embedding
                            // renderer runs, so a callback may call back into
                            // this API without deadlocking.
                            if let Ok((_, Some(event))) = &applied {
                                raw_output.emit(event);
                            }
                            updates.notify();
                            match applied.map(|(effect, _)| effect) {
                                Ok(FrameEffect::Continue) => {}
                                Ok(FrameEffect::Restart) => {
                                    outcome = Some(StreamOutcome::Restart);
                                    break;
                                }
                                Ok(FrameEffect::Stop) => {
                                    outcome = Some(StreamOutcome::Stop);
                                    break;
                                }
                                Err(error) => {
                                    set_client_status(&state, &updates, error);
                                    let _ = finish_decoder(&decoder, &state, &updates);
                                    return StreamOutcome::Restart;
                                }
                            }
                        }
                        if let Some(outcome) = outcome {
                            let _ = finish_decoder(&decoder, &state, &updates);
                            return outcome;
                        }
                    }
                    Err(error) => {
                        set_client_status(&state, &updates, format!("codec: {error}"));
                        let _ = finish_decoder(&decoder, &state, &updates);
                        return StreamOutcome::Restart;
                    }
                }
                if chunk.finished || chunk.reset {
                    if finish_decoder(&decoder, &state, &updates) {
                        set_client_status(
                            &state,
                            &updates,
                            if chunk.reset { "stream-reset" } else { "stream-closed" }.into(),
                        );
                    }
                    return StreamOutcome::Restart;
                }
            }
            Ok(None) => {
                if finish_decoder(&decoder, &state, &updates) {
                    set_client_status(&state, &updates, "stream-closed".into());
                }
                return StreamOutcome::Restart;
            }
            Err(error) => {
                if finish_decoder(&decoder, &state, &updates) {
                    set_client_status(&state, &updates, format!("stream: {error}"));
                }
                return StreamOutcome::Restart;
            }
        }
    }
}

impl TerminalStreamSupervisor {
    pub(super) async fn run(self) {
        let Self {
            multiplexer,
            terminal_id,
            initial_stream,
            streams,
            closed,
            close_notify,
            state,
            updates,
            raw_output,
            open_options,
        } = self;
        let mut stream = initial_stream;
        loop {
            let outcome =
                receive_frames(stream.clone(), state.clone(), updates.clone(), raw_output.clone())
                    .await;
            let current = streams.send_replace(None);
            if let Some(current) = current {
                let _ = current.close().await;
            }
            if outcome == StreamOutcome::Stop {
                closed.store(true, Ordering::Release);
                close_notify.notify_waiters();
                return;
            }
            if closed.load(Ordering::Acquire) {
                return;
            }
            if let Err(error) = state.lock().unwrap().prepare_handshake(terminal_id.clone()) {
                set_client_status(&state, &updates, format!("resync: {error}"));
                return;
            }
            updates.notify();
            let mut attempt: u32 = 0;
            let mut refused: u32 = 0;
            loop {
                if closed.load(Ordering::Acquire) {
                    return;
                }
                match open_terminal_stream_typed(&multiplexer, &terminal_id, &open_options).await {
                    Ok(next) => {
                        stream = next;
                        streams.send_replace(Some(stream.clone()));
                        break;
                    }
                    Err(error) => {
                        attempt = attempt.saturating_add(1);
                        refused = match error {
                            TerminalOpenError::Rejected { .. } => refused.saturating_add(1),
                            TerminalOpenError::Failed(_) => 0,
                        };
                        if reconnect_is_over(&multiplexer, refused) {
                            set_client_status(
                                &state,
                                &updates,
                                format!("reconnect-failed: {}", error.into_message()),
                            );
                            closed.store(true, Ordering::Release);
                            close_notify.notify_waiters();
                            return;
                        }
                        set_client_status(
                            &state,
                            &updates,
                            format!("reconnect {attempt}: {}", error.into_message()),
                        );
                        tokio::select! {
                            _ = tokio::time::sleep(terminal_reconnect_delay(&terminal_id, attempt)) => {}
                            _ = close_notify.notified() => return,
                        }
                    }
                }
            }
        }
    }
}

pub(super) fn terminal_reconnect_delay(
    terminal_id: &TerminalPublicId,
    attempt: u32,
) -> StdDuration {
    let multiplier = 1_u32.checked_shl(attempt.saturating_sub(1).min(16)).unwrap_or(u32::MAX);
    let base = TERMINAL_RECONNECT_INITIAL_DELAY
        .saturating_mul(multiplier)
        .min(TERMINAL_RECONNECT_MAX_DELAY);
    let identity_jitter =
        terminal_id.as_str().bytes().fold(u64::from(attempt), |hash, byte| {
            hash.wrapping_mul(33).wrapping_add(u64::from(byte))
        }) % 101;
    base.saturating_add(StdDuration::from_millis(identity_jitter))
}

pub(super) async fn supervise_resizes(
    mut streams: tokio::sync::watch::Receiver<Option<Arc<ServiceStream>>>,
    closed: Arc<AtomicBool>,
    delivery: Arc<ResizeDelivery>,
    send_lock: Arc<tokio::sync::Mutex<()>>,
    state: Arc<Mutex<ClientState>>,
    updates: Arc<ClientUpdates>,
) {
    loop {
        if closed.load(Ordering::Acquire) {
            return;
        }
        let Some(request) = delivery.desired() else {
            let changed = delivery.changed.notified();
            if delivery.desired().is_some() {
                continue;
            }
            tokio::select! {
                _ = changed => {}
                result = streams.changed() => {
                    if result.is_err() {
                        return;
                    }
                }
            }
            continue;
        };
        let Some(stream) = streams.borrow().clone() else {
            if streams.changed().await.is_err() {
                return;
            }
            continue;
        };

        let mut payload = Vec::with_capacity(4);
        payload.extend_from_slice(&request.cols.to_le_bytes());
        payload.extend_from_slice(&request.rows.to_le_bytes());
        let mut frame = Frame::new(MessageKind::ViewerSize, payload);
        frame.request_id = request.request_id;
        let encoded = match encode_frame(&frame) {
            Ok(encoded) => Bytes::from(encoded),
            Err(error) => {
                set_client_status(&state, &updates, format!("resize: {error}"));
                delivery.complete_if_current(request.request_id);
                continue;
            }
        };

        let send_result = {
            let _guard = send_lock.lock().await;
            stream.send(encoded).await
        };
        if let Err(error) = send_result {
            set_client_status(&state, &updates, format!("resize-write: {error}"));
            let failed = stream.id();
            loop {
                if closed.load(Ordering::Acquire) {
                    return;
                }
                let replaced = streams.borrow().as_ref().is_none_or(|stream| stream.id() != failed);
                if replaced {
                    break;
                }
                if streams.changed().await.is_err() {
                    return;
                }
            }
            continue;
        }

        loop {
            let acknowledged = delivery.changed.notified();
            if delivery.is_acknowledged(request.request_id) {
                delivery.complete_if_current(request.request_id);
                break;
            }
            let stream_changed = streams.changed();
            tokio::pin!(stream_changed);
            tokio::select! {
                _ = acknowledged => {}
                result = &mut stream_changed => {
                    if result.is_err() {
                        return;
                    }
                    break;
                }
            }
            if closed.load(Ordering::Acquire) {
                return;
            }
        }
    }
}

#[allow(clippy::too_many_arguments)]
pub(super) fn start_terminal_tasks(
    runtime: &Runtime,
    stream: Arc<ServiceStream>,
    multiplexer: Arc<ServiceMultiplexer>,
    terminal_id: TerminalPublicId,
    state: Arc<Mutex<ClientState>>,
    updates: Arc<ClientUpdates>,
    raw_output: Arc<RawOutput>,
    open_options: TerminalOpenOptions,
) -> ActiveTerminal {
    let closed = Arc::new(AtomicBool::new(false));
    let close_notify = Arc::new(tokio::sync::Notify::new());
    let (streams, mut command_streams) = tokio::sync::watch::channel(Some(stream.clone()));
    let resize_streams = streams.subscribe();
    let resize_delivery = Arc::new(ResizeDelivery::default());
    {
        let mut state = state.lock().unwrap();
        state.resize_delivery = Some(resize_delivery.clone());
        state.resize_acknowledgement = None;
    }
    let receiver_task = runtime.spawn(
        TerminalStreamSupervisor {
            multiplexer,
            terminal_id: terminal_id.clone(),
            initial_stream: stream,
            streams: streams.clone(),
            closed: closed.clone(),
            close_notify: close_notify.clone(),
            state: state.clone(),
            updates: updates.clone(),
            raw_output,
            open_options,
        }
        .run(),
    );
    let (command_sender, mut commands) = tokio::sync::mpsc::channel::<Bytes>(256);
    let command_state = state.clone();
    let command_updates = updates.clone();
    let command_closed = closed.clone();
    let send_lock = Arc::new(tokio::sync::Mutex::new(()));
    let command_send_lock = send_lock.clone();
    let command_task = runtime.spawn(async move {
        while let Some(command) = commands.recv().await {
            loop {
                if command_closed.load(Ordering::Acquire) {
                    return;
                }
                let current = command_streams.borrow().clone();
                let Some(current) = current else {
                    if command_streams.changed().await.is_err() {
                        return;
                    }
                    continue;
                };
                let send_result = {
                    let _guard = command_send_lock.lock().await;
                    current.send(command.clone()).await
                };
                match send_result {
                    Ok(()) => break,
                    Err(error) => {
                        set_client_status(
                            &command_state,
                            &command_updates,
                            format!("write: {error}"),
                        );
                        let failed = current.id();
                        loop {
                            if command_closed.load(Ordering::Acquire) {
                                return;
                            }
                            let replaced = command_streams
                                .borrow()
                                .as_ref()
                                .is_none_or(|stream| stream.id() != failed);
                            if replaced {
                                break;
                            }
                            if command_streams.changed().await.is_err() {
                                return;
                            }
                        }
                    }
                }
            }
        }
    });
    let resize_task = runtime.spawn(supervise_resizes(
        resize_streams,
        closed.clone(),
        resize_delivery.clone(),
        send_lock,
        state,
        updates,
    ));
    ActiveTerminal {
        terminal_id,
        streams,
        closed,
        close_notify,
        command_sender,
        resize_delivery,
        receiver_task,
        command_task,
        resize_task,
    }
}

//! One connection's read loop: requests in, replies and hub records out, until it ends.

use super::*;

/// `serve_connection_authed` for a unix socket peer named by its audit token.
pub(super) async fn serve_connection_from(
    hub: Arc<Hub>,
    mut inbound: mpsc::Receiver<String>,
    out: mpsc::Sender<String>,
    origin: Origin,
    auth: ConnAuth,
    peer: Option<cmux_link::app_caller::PeerToken>,
    transport: Transport,
    socket_peer: SocketPeer,
    device: Option<String>,
    wire: Option<Arc<crate::frame_compress::Wire>>,
    carrier: Option<carrier::Attested>,
    uploads: Option<upload_frames::Replies>,
    link: Option<Arc<crate::link_v2::Slot>>,
    page_origin: Option<String>,
) {
    // A carrier proof comes with the person the carrier socket read, and only with it.
    let carried = matches!(auth, ConnAuth::CarrierOwner | ConnAuth::CarrierTeam);
    let auth = if carried != carrier.is_some() { ConnAuth::None } else { auth };
    if !auth.authenticated() {
        refuse_unauthenticated(&mut inbound, &out, origin).await;
        return;
    }
    // Counted while it is served: a daemon with none stops once unused (`daemon/unused_exit.rs`).
    let client = crate::daemon::unused_exit::client();
    let raw_text = !peer_text::masks(origin);
    let (out, gate) = outbound::start(&hub.scope, hub.store.durability(), out);
    // The upload worker's answers (`upload_frames.rs`) go into the same queue: it holds no sender
    // of the transport, so the pump stays its only one.
    if let Some(uploads) = &uploads {
        uploads.send_replace(Some(Arc::downgrade(&out)));
    }
    // The listener's own peer link: the only transport with a writer that compresses (`wire`)
    // and a peer token checked at its upgrade; not a paired machine, nor an in-process carrier.
    let dual_principal = (wire.is_some() && auth == ConnAuth::PeerToken && device.is_none())
        .then_some(dual_requests::PEER_LINK);
    // The v2 list stream rides a link transport's connection that v1 answers a peer's watch
    // for, with `list` and `peers` on (`link_v2.rs`). Every other connection drops its frames.
    let mut link_v2 = link
        .filter(|_| origin == Origin::Peer)
        .and_then(|slot| link_v2_serve::Link::serving(&hub, slot));
    // Opt-in usage patterns: connections by listener, and distinct paired machines (an opaque
    // stand-in for the device id, never the id).
    if cmux_usage_patterns::enabled() {
        cmux_usage_patterns::count("acpmux-connection", origin_usage_key(origin));
        if let Some(device) = device.as_deref() {
            cmux_usage_patterns::count("machine", &cmux_usage_patterns::opaque_id(device));
        }
    }
    let (fan_flush, flushes) = fanout::Flush::channel();
    let conn = Arc::new(Conn {
        scope: hub.scope.child("acpmux conn"),
        id: uuid::Uuid::now_v7().to_string(),
        origin,
        auth,
        device,
        carrier,
        raw_text,
        name: StdMutex::new(String::new()),
        presence: client.presence(),
        out,
        gate,
        subs: StdMutex::new(HashMap::new()),
        stream_cursors: Default::default(),
        held_rows: Default::default(),
        follows: Default::default(),
        message_notices: StdMutex::new(MessageNoticeBook::default()),
        mailbox_bindings: StdMutex::new(HashMap::new()),
        controls: Default::default(),
        created: StdMutex::default(),
        interest: interest::Interest::new(hub.fanout_router()),
        watch_all: AtomicBool::new(false),
        watch_tools: AtomicBool::new(false),
        peer_row_batches: AtomicBool::new(false),
        client_features: Default::default(),
        chunk_deltas: Default::default(),
        session_delta: AtomicBool::new(false),
        sent_rows: StdMutex::default(),
        omit_time_breakdown: AtomicBool::new(false),
        rows_left_out: AtomicU64::new(0),
        watch_inventory: StdMutex::new(false),
        peer,
        socket_peer,
        transport,
        requests: std::sync::atomic::AtomicU64::new(0),
        challenged: AtomicBool::new(false),
        nonce: crate::hub::person::new_nonce(),
        person: AtomicBool::new(false),
        trigger: StdMutex::new(None),
        holds_calls: std::sync::atomic::AtomicU32::new(0),
        prove_calls: std::sync::atomic::AtomicU32::new(0),
        caller: std::sync::OnceLock::new(),
        unproven_caller: std::sync::OnceLock::new(),
        declared: std::sync::OnceLock::new(),
        peer_leases: StdMutex::new(Some(Vec::new())),
        ephemeral: StdMutex::new(Some(Vec::new())),
        ended: tokio::sync::watch::Sender::new(false),
        preparation_cancels: StdMutex::new(HashMap::new()),
        media: crate::hub::media_handles::Handles::default(),
        remote_media: media_forward::RemoteMedia::default(),
        client_requests: Default::default(),
        in_flight: in_flight::InFlight::counted(hub.requests_in_flight.clone()),
        chat_windows: Default::default(),
        wire,
        dual_principal,
        list_stream: link_v2.is_some(),
        device_mesh: StdMutex::new(web_device::Slot::Empty),
        page_origin: page_origin.filter(|_| web_device::keeps_page_origin(origin, auth)),
        browser_sign_in: StdMutex::new(None),
        fan_flush,
    });
    if auth == ConnAuth::BrowserApp && !web_device::admit(&hub, &conn, &mut inbound).await {
        return;
    }
    let device_ended = web_device::credential_ended(&hub, &conn);
    tokio::pin!(device_ended);
    queue_gauge::register(&conn);
    // A peer daemon's link mirrors the list and reads it again only when it links again: its
    // list notices are never left out (`outbound.rs`). Named again at its `initialize`.
    conn.out.describe(format!("{} {}", origin_usage_key(origin), conn.id), origin != Origin::Peer);
    tracing::debug!(conn = %conn.id, "client connected");

    let mut fan = fanout::start(hub.clone(), conn.clone(), flushes);
    let request_slots = Arc::new(Semaphore::new(REQUEST_WORK_LIMIT));
    let (notification_tx, notification_rx) =
        mpsc::channel::<(String, Value)>(NOTIFICATION_QUEUE_LIMIT);
    let (cancel_tx, cancel_rx) = mpsc::channel::<(String, Value)>(NOTIFICATION_QUEUE_LIMIT);
    let notification_handler = {
        let hub = hub.clone();
        let conn = conn.clone();
        move |method: String, params| {
            let hub = hub.clone();
            let conn = conn.clone();
            async move { handle_notification(&hub, &conn, &method, params).await }
        }
    };
    let notification_worker =
        spawn_notification_worker(notification_rx, notification_handler.clone());
    // A channel's frames, one at a time in the order they came (`channels.rs`): the worker above
    // runs notifications side by side, which would reorder a byte stream.
    let (channel_tx, channel_worker) = channels::spawn_worker(hub.clone(), conn.clone());
    let cancel_worker = spawn_notification_worker(cancel_rx, notification_handler);

    let notification_waiters = Arc::new(Semaphore::new(NOTIFICATION_WAIT_LIMIT));
    let mut notification_waits: Vec<tokio::task::JoinHandle<()>> = Vec::new();
    let cancel_waiters = Arc::new(Semaphore::new(NOTIFICATION_WAIT_LIMIT));
    let mut cancel_waits: Vec<tokio::task::JoinHandle<()>> = Vec::new();
    let dropped_notifications = Arc::new(AtomicU64::new(0));
    loop {
        // A reader past its byte bound is disconnected (`outbound.rs`): it reads again from its
        // cursor on a new connection, so nothing this one would still ask is answered. So is one
        // whose output ended (its reader gone, the journal's writer ended). So is one whose
        // fan-out task ended (a panic, the hub's feed closed): it would answer requests and never
        // push another record, so an attached client would wait on a chat that never moves. Its
        // reader sees the connection end and attaches again from its cursor.
        let line = tokio::select! {
            biased;
            () = conn.out.closed() => None,
            () = &mut device_ended => None,
            ended = &mut fan => {
                fanout::ended(&conn, ended);
                None
            }
            line = inbound.recv() => line,
        };
        let Some(line) = line else { break };
        if line.trim().is_empty() {
            continue;
        }
        // A v2 frame, known by its first bytes and never parsed into a `Value` (`link_v2.rs`).
        // Its wait for the connection to read the frame before it ends when the link does.
        if crate::link_v2::is_frame_line(&line) {
            // The wait also ends when the transport's reader does (a revoked credential).
            match link_v2.as_mut() {
                Some(link) => {
                    let slot = link.slot();
                    let reader_ended = tokio::select! {
                        biased;
                        () = conn.out.closed() => break,
                        () = slot.reader_ended() => true,
                        () = link.take(&line) => false,
                    };
                    if reader_ended {
                        link.end();
                    }
                }
                None => hub.link_v2.counters.drop_one(),
            }
            continue;
        }
        let line_bytes = line.len();
        let msg = match Message::parse(&line) {
            Ok(m) => m,
            Err(e) => {
                conn.send(&Message::err(Value::Null, e));
                continue;
            }
        };
        match msg {
            // Which of this connection's requests still run (`in_flight.rs` `states`): answered
            // here, in order with the requests read before it, and never queued for a slot, so a
            // client whose slots are all taken by slow requests still gets its proof. Only this
            // connection's own requests, like a `$/cancel_request`: any client may ask.
            Message::Request { id, method: m, .. } if m == method::MUX_REQUEST_STATE => {
                let (running, answered) = conn.in_flight.states();
                conn.send_replying(
                    &Message::ok(id, json!({"running": running, "answered": answered})),
                    Some(&m),
                );
            }
            Message::Request { id, method: m, mut params } => {
                // Every request its caller sent, refused ones too (`caller_stats.rs`); an
                // `initialize` once it named the client, below.
                if m != method::INITIALIZE {
                    crate::caller_stats::global().observe_request(
                        &conn.stats_caller(),
                        &m,
                        line_bytes,
                    );
                }
                // An open of a chat's view is timed from here to its reply (`gauges.attach`).
                let attach_from = crate::gauges::opens_a_chat(&m).then(std::time::Instant::now);
                // Once a local connection has been admitted as a trigger
                // principal it is a single-purpose channel. In particular,
                // the local socket must not keep granting ordinary person
                // RPCs after trigger authentication.
                if conn.is_trigger() && !m.starts_with("trigger/chat.") {
                    conn.send(&Message::err(
                        id,
                        RpcError::new(
                            -32001,
                            "trigger connection accepts trigger/chat operations only",
                        )
                        .with_data(json!({"reason": "trigger.connection_scope"})),
                    ));
                    continue;
                }
                let slot = match try_request_slot(&request_slots, &m) {
                    Ok(slot) => slot,
                    Err(()) => {
                        let error = RpcError::new(-32000, "connection request limit reached")
                            .with_data(json!({
                                "reason": "connection.busy",
                                "retryable": true,
                            }));
                        // In the lane of its method's answer: a busy refusal of a cheap read (the
                        // pane's liveness probe) proves the daemon alive only if it arrives, and
                        // a tool call's refusal is its answer.
                        let reply_to = outbound::reads_ahead(&m).then_some(m.as_str());
                        conn.send_replying(&Message::err(id, error), reply_to);
                        continue;
                    }
                };
                // In order, before the request is spawned: a later request
                // on this connection sees the person decided.
                if m == method::INITIALIZE
                    && conn.origin == Origin::Local
                    && let Some(caller) =
                        params.as_ref().and_then(|p| p.pointer("/_meta/acpmux/callerSession"))
                    && let Some(id) = caller.get("sessionId").and_then(Value::as_str)
                {
                    hub.session_meta(id).await;
                    // Known once adoption has read the earlier run's token (`settle_caller`).
                    if let Some(token) = caller.get("token").and_then(Value::as_str) {
                        hub.settle_caller(id, token).await;
                    }
                }
                // The host's sender token (`sender_token.rs`) leaves the request here, before
                // anything reads, stores, logs or forwards it; only a send's checks see it.
                let sender_token = params.as_mut().and_then(crate::sender_token::take);
                conn.bind_person(&hub, &m, &mut params);
                if m == method::INITIALIZE {
                    requests::note_initialize(&conn, params.as_ref().unwrap_or(&Value::Null));
                }
                // After it named the client: an `initialize` counts under that name.
                if m == method::INITIALIZE {
                    crate::caller_stats::global().observe_request(
                        &conn.stats_caller(),
                        &m,
                        line_bytes,
                    );
                }
                // Before its reply is built: the reply says whether large messages go compressed.
                if m == method::INITIALIZE
                    && let Some(wire) = &conn.wire
                    && crate::frame_compress::offered(params.as_ref())
                {
                    wire.enable();
                }
                // A peer link sent this request on two paths (`dual_requests.rs`): in order, so
                // the copy read first runs it and the other answers with its answer.
                let seen = dual_requests::key_for(conn.dual_principal, &m, params.as_ref());
                let dual_key = seen.as_ref().map(|(key, _)| key.clone());
                let dual = seen.and_then(dual_requests::admit);
                let dual_key = dual_key.filter(|_| dual.is_some());
                // Registered in order, before the request is spawned: a `$/cancel_request` read
                // after it finds it, and taking it frees its slot (`in_flight.rs`).
                let mut ticket = conn.in_flight.begin(&id, &m, slot, dual_key);
                #[cfg(test)]
                cancel_classes_tests::after_begin(&conn);
                let owner = conn.clone();
                let hub = hub.clone();
                let conn = conn.clone();
                owner.scope.spawn_named("conn-request", async move {
                    let perf_started = crate::perf_watch::request_started();
                    let mut first = match dual_requests::before_run(dual).await {
                        Ok(first) => first,
                        Err(answer) => {
                            // A cancel's part on this connection is its own (`dual_requests.rs`).
                            if m == method::SESSION_CANCEL {
                                requests::cancel_on_connection(&hub, &conn, params.as_ref());
                            }
                            if conn.in_flight.finish(&ticket) {
                                conn.send_replying(&dual_requests::reply(id, answer), Some(&m));
                            }
                            return;
                        }
                    };
                    // Read after the daemon's stop drained this connection's requests
                    // (`shutdown_drain.rs`): not served, answered as the drained ones were.
                    if ticket.refused() {
                        let answer = Err(shutdown_drain::restarting_error());
                        dual_requests::finish(first, Some(&answer));
                        conn.send_replying(&dual_requests::reply(id, answer), Some(&m));
                        return;
                    }
                    // One span per request, with the caller's end-to-end trace id
                    // (`params._meta.traceId`), for the Perfetto trace (`perf_trace.rs`).
                    let rpc_span = crate::perf_trace::request_span(&m, params.as_ref());
                    let route = || {
                        chats::route(&hub, &conn, &m, params.unwrap_or(Value::Null), sender_token)
                    };
                    let cancel =
                        std::mem::replace(&mut ticket.cancel, tokio::sync::oneshot::channel().1);
                    let claim = ticket.claim();
                    let serve = async {
                        let stage = crate::hub::RequestStage::Dispatch;
                        hub.request_hold(stage, &m, &id).await;
                        list_reply::scope(id.clone(), &m, claim, route).await
                    };
                    let serve = tracing::Instrument::instrument(serve, rpc_span);
                    // A cancel of its copy on another connection stops it too (`dual_requests.rs`).
                    let also = first.as_mut().and_then(dual_requests::First::take_stop);
                    let served = crate::request_cancel::until_either(cancel, also, serve).await;
                    // Cancelled: the cancel answered it, and a copy sent on another path gets
                    // that answer too (`dual_requests.rs`).
                    let Some((result, sent)) = served.filter(|_| conn.in_flight.finish(&ticket))
                    else {
                        // Stopped by a cancel of its copy on another connection: this copy's
                        // answer here is still owed, and is the cancel's.
                        if conn.in_flight.finish(&ticket) {
                            let cancelled = Err(crate::request_cancel::cancelled_error());
                            conn.send_replying(
                                &dual_requests::reply(id.clone(), cancelled),
                                Some(&m),
                            );
                        }
                        tracing::debug!(
                            target: crate::request_cancel::LOG_TARGET,
                            conn = %conn.id,
                            id = %id,
                            method = %m,
                            "dropped the answer to a request its client cancelled"
                        );
                        dual_requests::finish(
                            first,
                            Some(&Err(crate::request_cancel::cancelled_error())),
                        );
                        return;
                    };
                    // Opt-in usage patterns: methods this daemon serves (an unknown name a client
                    // made up is no key), `/` as `.` so `_acpmux/chat/list` is one key.
                    if cmux_usage_patterns::enabled()
                        && result.as_ref().err().is_none_or(|e| e.code != -32601)
                    {
                        cmux_usage_patterns::count("acpmux-method", &m.replace('/', "."));
                    }
                    // Its answer went whole into an open queue: one sent as its too-large error, or
                    // to a reader that is gone, opened nothing.
                    let watched = m == method::MUX_WATCH && result.is_ok() && sent == Some(true);
                    // A turn's answer after its updates (`fanout::Flush`).
                    if m == method::SESSION_PROMPT {
                        conn.fan_flush.sent().await;
                    }
                    // A shared session list, sent already as the bytes it was serialized to.
                    if !(sent.is_some() && result.is_ok()) {
                        let answer = result.map_err(|mut e| {
                            // What kind of failure, and what to do (`recovery.rs`).
                            crate::recovery::annotate(&mut e, None);
                            e
                        });
                        dual_requests::finish(first, Some(&answer));
                        conn.send_replying(&dual_requests::reply(id, answer), Some(&m));
                    } else {
                        dual_requests::finish(first, None);
                    }
                    crate::perf_watch::request_done(perf_started, &m, conn.origin);
                    if let Some(from) = attach_from {
                        crate::gauges::attach_latency().record(from.elapsed());
                    }
                    // A Mac that lends GitHub counts from here: its watch answer is queued, so
                    // no action reaches it before the answer that opens its side.
                    if watched
                        && conn.watch_all.load(Ordering::SeqCst)
                        && conn.client_requests.lends_github.load(Ordering::SeqCst)
                    {
                        hub.add_github_owner(&conn);
                    }
                });
            }
            // The client gives up on one of its requests: answered as cancelled at once, its
            // slot freed, and its work dropped, which tells the agent or peer it waited on
            // (`request_cancel.rs`). In order: it finds every request read before it. Before
            // every class's own filter (review F3 of #41285): it touches only this connection's
            // own requests, so a read-only machine, a teammate and a trigger may send it.
            Message::Notification { method: m, params } if m == method::CANCEL_REQUEST => {
                if let Some(id) = params.as_ref().and_then(crate::request_cancel::named_id)
                    && let Some((cancelled, dual)) = conn.in_flight.cancel(id)
                {
                    // One copy of a request sent on two paths: the copy that runs stops,
                    // whichever connection it came on, and a later one never runs.
                    if let Some(key) = dual {
                        dual_requests::cancel(&key);
                    }
                    let error = crate::request_cancel::cancelled_error();
                    conn.send_replying(&Message::err(id.clone(), error), Some(&cancelled));
                }
            }
            // A `_acpmux/v2` notification not in a frame line's form is no frame (`link_v2.rs`).
            Message::Notification { method: m, .. } if m == method::MUX_V2 => {
                hub.link_v2.counters.value_parses.fetch_add(1, Ordering::Relaxed);
                hub.link_v2.counters.drop_one();
            }
            // A read-only machine's other notifications (a session cancel) change nothing.
            Message::Notification { .. } if conn.auth == ConnAuth::ReadOnlyDevice => {}
            // A teammate through the carrier stops a turn, nothing else (`carrier.rs`).
            Message::Notification { method: m, params }
                if !carrier::takes_notification(&hub, &conn, &m, params.as_ref()) => {}
            Message::Notification { method: m, params: _ } if conn.is_trigger() => {
                tracing::debug!(conn = %conn.id, method = %m, "ignoring notification on trigger connection");
            }
            // The second copy of a notification a peer link sent on two paths.
            Message::Notification { method: m, params }
                if dual_requests::key_for(conn.dual_principal, m.as_str(), params.as_ref())
                    .is_some_and(|seen| !dual_requests::first_notification(seen)) =>
            {
                if m == method::SESSION_CANCEL {
                    requests::cancel_on_connection(&hub, &conn, params.as_ref());
                }
            }
            // A full channel queue holds this reader: backpressure on the sender, never a
            // dropped or reordered frame.
            Message::Notification { method: m, params } if channels::takes(&m) => {
                if channel_tx.send((m, params.unwrap_or(Value::Null))).await.is_err() {
                    break;
                }
            }
            Message::Notification { method: m, params } => {
                let params = params.unwrap_or(Value::Null);
                if m == method::SESSION_CANCEL {
                    match admit_notification(
                        &cancel_tx,
                        &cancel_waiters,
                        &mut cancel_waits,
                        (method::SESSION_CANCEL.to_owned(), params),
                    ) {
                        NotificationAdmission::Accepted => {}
                        NotificationAdmission::Closed => break,
                        NotificationAdmission::Dropped => {
                            if dropped_notifications.fetch_add(1, Ordering::Relaxed) == 0 {
                                tracing::warn!(conn = %conn.id, "dropping notifications after bounded admission waiters are full");
                            }
                        }
                    }
                    continue;
                }
                match admit_notification(
                    &notification_tx,
                    &notification_waiters,
                    &mut notification_waits,
                    (m, params),
                ) {
                    NotificationAdmission::Accepted => {}
                    NotificationAdmission::Closed => break,
                    NotificationAdmission::Dropped => {
                        if dropped_notifications.fetch_add(1, Ordering::Relaxed) == 0 {
                            tracing::warn!(conn = %conn.id, "dropping notifications after bounded admission waiters are full");
                        }
                    }
                }
            }
            // An answer to a request this daemon sent the client (`client_request.rs`).
            Message::Response { id, result, error } => {
                if !conn.is_trigger() && conn.auth != ConnAuth::CarrierTeam {
                    conn.settle_client_request(&id, result, error);
                }
            }
        }
    }
    conn.ended.send_replace(true);
    // Its listeners go and its channels close on their other side (`channels.rs`).
    channels::conn_ended(&hub, &conn).await;
    // The link's v2 connection ends with it.
    drop(link_v2);
    let preparations: Vec<_> =
        conn.preparation_cancels.lock().unwrap_or_else(|e| e.into_inner()).drain().collect();
    for (session, cancel) in preparations {
        cancel.send_replace(true);
        if let Ok(session) = hub.resolve(&session) {
            session.abandon_prepared_connection(&conn.id);
        }
    }
    // Cancellation has to reach the hub even when ordinary notifications are
    // still draining. Its worker is bounded independently and must never be
    // aborted by connection cleanup.
    for waiter in cancel_waits {
        let _ = waiter.await;
    }
    drop(cancel_tx);
    let _ = cancel_worker.await;
    drop(channel_tx);
    let _ = channel_worker.await;

    let deadline = tokio::time::Instant::now() + WORK_BACKPRESSURE_WAIT;
    let mut waiters = notification_waits.into_iter();
    while let Some(mut waiter) = waiters.next() {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if tokio::time::timeout(remaining, &mut waiter).await.is_err() {
            waiter.abort();
            let _ = waiter.await;
            for waiter in waiters {
                waiter.abort();
                let _ = waiter.await;
            }
            tracing::debug!(conn = %conn.id, "notification admission waiters did not drain");
            break;
        }
    }
    drop(notification_tx);
    let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
    let mut notification_worker = notification_worker;
    if tokio::time::timeout(remaining, &mut notification_worker).await.is_err() {
        notification_worker.abort();
        let _ = notification_worker.await;
    }
    let dropped = dropped_notifications.load(Ordering::Relaxed);
    if dropped > 0 {
        tracing::debug!(conn = %conn.id, dropped, "notification admission drops during connection");
    }
    fan.abort();
    conn.interest.forget();
    conn.media.close_all();
    conn.remote_media.close_all();
    view::release_all(&hub, &conn);
    // Leases first: ending one is cheap and synchronous, while the ephemeral
    // release awaits each session's kill. A leased peer must not keep
    // reconnecting to a forward port its bridge already closed, which another
    // process could bind (`hub/peer_lease.rs`).
    conn.end_peer_leases(&hub);
    // The phones the owner's peer daemon vouched for on this link end with it (fail closed).
    if hub.pairing.unvouch(&conn.id, None, None, 0) {
        hub.hold_policies_again().await;
    }
    ephemeral::release_all(&hub, &conn).await;
    tracing::debug!(conn = %conn.id, "client disconnected");
}

/// An unauthenticated connection: no hub subscription, no session, no
/// data. The first request gets the refusal, then the connection ends.
async fn refuse_unauthenticated(
    inbound: &mut mpsc::Receiver<String>,
    out: &mpsc::Sender<String>,
    origin: Origin,
) {
    tracing::warn!("refusing an unauthenticated {origin:?} connection");
    // Bounded: a client that never sends a request does not hold the task.
    let _ = tokio::time::timeout(FIRST_FRAME, async {
        while let Some(line) = inbound.recv().await {
            match Message::parse(&line) {
                Ok(Message::Request { id, .. }) => {
                    let _ = out.send(Message::err(id, conn_auth::refused()).to_line()).await;
                    return;
                }
                Ok(_) => continue,
                Err(_) if line.trim().is_empty() => continue,
                Err(_) => return,
            }
        }
    })
    .await;
}

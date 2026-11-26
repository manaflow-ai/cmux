//! Peer request, notification, and link-loop operations.

use super::*;

// One link, dialed and served until it ends (`connect_once`, `serve_heard`).
#[path = "peer_link_serve.rs"]
mod link_serve;

impl Peer {
    /// [`Self::send_request`]; `retry`: sent again on the next link if this one switches paths
    /// before it answers (`peer_carried.rs`).
    pub(super) async fn send_request_with(
        &self,
        m: &str,
        params: Value,
        epoch: Option<u64>,
        list: ListKey,
        retry: bool,
    ) -> Result<Value, RpcError> {
        // One deadline from here: a request that waits for room in the queue (a stalled link,
        // or a full queue ahead of it) times out on the schedule of one the peer is slow to
        // answer, never later.
        let started = tokio::time::Instant::now();
        let turn_wait = waits_on_turn(m)
            || (m == method::MUX_DISPATCH
                && params.get("durable").and_then(Value::as_bool) == Some(true)
                && params.get("wait").and_then(Value::as_bool) == Some(true));
        // A forwarded session/new gets its dedicated start hazard envelope as
        // well as the generic request budget. Keep the larger one so a caller
        // cannot reintroduce the old short start cutoff through
        // `ACPMUX_PEER_REQUEST_SECS`.
        let budget = self.timings.request.max(if m == method::SESSION_NEW {
            self.timings.start
        } else {
            Duration::ZERO
        });
        let deadline = started + budget;
        // The `initialize` that left with the upgrade request (`early_initialize`) is already on
        // the wire and registered: this takes its answer, and sends nothing.
        let early =
            if m == method::INITIALIZE { self.early_init.lock_or_recover().take() } else { None };
        let sent_early = early.is_some();
        let (id, rx) = match early {
            Some(early) => early,
            None => {
                let id = self.next_id.fetch_add(1, Ordering::SeqCst);
                let (tx, rx) = oneshot::channel();
                self.pending.lock().await.insert(Value::from(id).to_string(), tx);
                (id, rx)
            }
        };
        let key = Value::from(id).to_string();
        if let Some(session) = params.get("sessionId").and_then(Value::as_str) {
            self.replay_tail.lock_or_recover().remove(session);
        }
        // A load streams its chat's history: until it answers, the replay goes to the hub as
        // it comes, never through the merger's drop below the cursor
        // (`Peer::replay_start`).
        let replaying = match params.get("sessionId").and_then(Value::as_str) {
            Some(session) if dual::replays(m) => Some(self.replay_start(session).await),
            _ => None,
        };
        if m == method::SESSION_PROMPT
            && let (Some(session), Some(prompt)) = (
                params.get("sessionId").and_then(Value::as_str),
                params.pointer("/_meta/acpmux/promptId").and_then(Value::as_str),
            )
        {
            self.prompts.lock_or_recover().insert(
                key.clone(),
                PendingPrompt {
                    session: session.to_owned(),
                    prompt: prompt.to_owned(),
                    accepted: false,
                },
            );
        }
        // A request that times out, or whose caller stops waiting, takes its
        // entry with it rather than leaving it until the connection drops.
        let mut forget = ForgetPending {
            pending: self.pending.clone(),
            on_wire: self.on_wire.clone(),
            prompts: self.prompts.clone(),
            key: Some(key.clone()),
            cancel: None,
            carried: self.carried.clone(),
        };
        // The link it was admitted on went down before it was registered: `run`
        // already failed what waited, and the next link drops its frame, so a
        // prompt (which has no deadline) would wait for good.
        if epoch.is_some_and(|e| e != self.link_epoch() || !self.open.load(Ordering::SeqCst)) {
            return Err(self.unreachable_error());
        }
        // Only on its own link, checked again under the lock: a request of a link gone down
        // (whose task may still run after its abort) never takes the key of the next link's
        // list. The next handshake sets its key after the epoch moved on, under the same lock.
        if list != ListKey::None {
            let mut held = self.watch_key.lock_or_recover();
            if epoch.is_some_and(|e| e != self.link_epoch()) {
                return Err(self.unreachable_error());
            }
            *held = Some(key.clone());
            if list == ListKey::Pipelined {
                *self.pipelined_key.lock_or_recover() = Some(key.clone());
            }
        }
        if m == crate::server::controls::METHOD && params.get("live") == Some(&Value::Bool(true)) {
            self.controls_request(epoch.unwrap_or_else(|| self.link_epoch()), &key);
        }
        // Only this link stamps a `dualId` (`peer_dual.rs`).
        let mut params = params;
        dual::drop_foreign_id(&mut params);
        // One frame larger than the peer reads with would drop the link and every chat on it.
        let line = Message::request(id, m, params).bounded_line().map_err(RpcError::too_large)?;
        let tag = epoch.unwrap_or_else(|| self.link_epoch());
        // The link of `tag` carries it; bound to the link's connection, it is sent again on the
        // next link if this one switches paths before it answers, never raced on two
        // (`Peer::resend_switched`). Its entry goes with `forget`.
        self.carried.lock_or_recover().sent(key.clone(), tag, retry.then(|| line.clone()));
        // Its client may cancel it from here: every link that still carries it hears
        // `$/cancel_request`, when the peer says it takes one (an older peer ignores the
        // notification), and each late answer is dropped and logged either way.
        let cancel = Some(carried::PeerCancel {
            out: self.out.clone(),
            link_epoch: self.link_epoch.clone(),
            carried: self.carried.clone(),
            id,
            method: m.to_owned(),
            cancelled: self.cancelled.clone(),
            tell: self.lists(crate::request_cancel::FEATURE),
            peer: self.name.clone(),
        });
        let frame = Outbound { epoch: tag, key: Some(key), line };
        let sending = async {
            if sent_early {
                Ok(Ok(()))
            } else {
                tokio::time::timeout_at(deadline, self.out.send(frame)).await
            }
        };
        match sending.await {
            Ok(Ok(())) => forget.cancel = cancel,
            Ok(Err(_)) => {
                return Err(RpcError::internal(format!("peer {} connection closed", self.name)));
            }
            Err(_) => return Err(queue_timed_out(&self.name, started.elapsed())),
        }
        // A prompt or a wait answers when the peer's turn ends, however long that is; the
        // keepalive drops a link that stops answering. Accepted prompts retain their caller
        // across that drop; a forwarder whose client left drops it (`server/peer_forward.rs`).
        let answer =
            if turn_wait { Ok(rx.await) } else { tokio::time::timeout_at(deadline, rx).await };
        // Its replay came before its answer on the link: the cursor is past it now.
        if let Some(mark) = replaying {
            mark.finish().await;
        }
        match answer {
            // A full disk the peer reports is the peer's, not this machine's (`recovery.rs`).
            // No display line of the peer's own reaches this daemon's clients, on any route that
            // returns a peer's reply or its error's data (`hub::drop_display_lines`).
            Ok(Ok(r)) => r
                .map(|mut result| {
                    crate::hub::drop_display_lines(&mut result);
                    result
                })
                .map_err(|mut e| {
                    crate::recovery::annotate_peer(&mut e, &self.name);
                    if let Some(data) = e.data.as_mut() {
                        crate::hub::drop_display_lines(data);
                    }
                    e
                }),
            Ok(Err(_)) => {
                Err(RpcError::internal(format!("peer {} dropped the request", self.name)))
            }
            Err(_) => Err(RpcError::internal(format!(
                "peer {} timed out after {}s",
                self.name,
                started.elapsed().as_secs()
            ))),
        }
    }

    /// After a link that switched paths: the requests bound to the old link's connection that
    /// it never answered, sent again on link `link` (`peer_carried.rs`).
    pub(super) async fn resend_switched(&self, link: u64) {
        // Only those an earlier link carried: one made on this link went out on it already.
        let due: Vec<String> = {
            let pending = self.pending.lock().await;
            let due = self.carried.lock_or_recover().bound_before(link);
            due.into_iter().filter(|key| pending.contains_key(key)).collect()
        };
        for key in due {
            let Ok(permit) = self.out.reserve().await else { return };
            // Queued under the record's lock: a cancel that took the request first leaves
            // nothing to send, and one after it finds the request on this link, behind its frame.
            let mut carried = self.carried.lock_or_recover();
            let Some(line) = carried.resend(&key, link) else { continue };
            tracing::debug!(peer = %self.name, key = %key, "sending a bound request again after a path switch");
            permit.send(Outbound { epoch: link, key: Some(key), line });
        }
    }

    /// The peer accepted a prompt (`_acpmux/prompt_accepted`, on the link or the shadow): a
    /// drop of the link from now on recovers its caller rather than failing it.
    pub(super) fn note_prompt_accepted(&self, p: &Value) {
        let mut prompts = self.prompts.lock_or_recover();
        for prompt in prompts.values_mut() {
            if p.get("sessionId").and_then(Value::as_str) == Some(&prompt.session)
                && p.get("promptId").and_then(Value::as_str) == Some(&prompt.prompt)
            {
                prompt.accepted = true;
            }
        }
    }

    pub async fn notify(&self, m: &str, mut params: Value) -> Result<(), RpcError> {
        dual::drop_foreign_id(&mut params);
        // Read before the check, as in `request`: a frame tagged with a link
        // that went down is dropped by `serve`, never sent on the next one.
        let epoch = self.link_epoch();
        if !self.connected.load(Ordering::SeqCst) || self.admitting.load(Ordering::SeqCst) {
            return Err(self.unreachable_error());
        }
        let line = Message::notification(m, params).bounded_line().map_err(RpcError::too_large)?;
        let started = tokio::time::Instant::now();
        let frame = Outbound { epoch, key: None, line };
        match tokio::time::timeout(self.timings.request, self.out.send(frame)).await {
            Ok(Ok(())) => Ok(()),
            Ok(Err(_)) => Err(RpcError::internal(format!("peer {} connection closed", self.name))),
            Err(_) => Err(queue_timed_out(&self.name, started.elapsed())),
        }
    }

    /// Run the connect loop until `stop`.
    pub async fn run(self: Arc<Self>) {
        let mut backoff = Backoff::default();
        // Refused ssh logins in a row (`Backoff::login_refused`).
        let mut login_refusals = 0u32;
        let Some(mut out_rx) = self.out_rx.lock().await.take() else {
            // A second run: the first owns the outbound queue and the link.
            tracing::warn!(peer = %self.name, "peer link already running");
            return;
        };
        // The wait goes out as `nextRetryAt` (`park_at_start`), never as a countdown in the
        // error text, which is read long after it was written (a frozen "retry in 2519s").
        if !self.retry_immediately.load(Ordering::SeqCst)
            && let Some(wait) = self.with_link(|l| l.park_at_start(crate::store::now_ms()))
        {
            let reason = "peer unreachable for over a day; retried hourly".to_owned();
            *self.last_error.lock_or_recover() = Some(reason.clone());
            // Settle startup watchers now; no SSH is spawned just because this daemon updated.
            let _ = self
                .notices
                .send((self.name.clone(), self.generation, PeerNotice::Disconnected(reason)))
                .await;
            // Sleep-aware, like the reconnect backoff: a wake past the saved deadline tries now.
            if matches!(self.wait_backoff(wait).await, BackoffWait::Stopped) {
                return;
            }
        }
        self.watch_tailnet();
        let mut immediate_redial = false;
        while !self.stop.load(Ordering::SeqCst) {
            crate::gauges::bump(&crate::gauges::links().link_dials);
            if immediate_redial {
                crate::gauges::bump(&crate::gauges::links().link_redials);
            }
            let outcome = self.connect_once(&mut out_rx).await;
            let restarting = matches!(&outcome, Ok(LinkEnd::Restarting | LinkEnd::Switching));
            let was_ready = self.link().is_ready();
            let notice = self.finish_link(outcome, &mut backoff);
            // A ready link that just died (a dropped network, a wake from sleep) redials at once:
            // chats are open on it. Only with no failure counted since its backoff last started
            // over, so a link that drops after each handshake waits its backoff from the second.
            let redial_now = was_ready && backoff.failures() == 0;
            // The remote refused this computer's ssh login: the next attempt waits minutes, not
            // the doubling seconds, and no open chat or ask cuts that wait (`wait_backoff`).
            login_refusals = if self.login_refused.load(Ordering::SeqCst) {
                login_refusals.saturating_add(1)
            } else {
                0
            };
            // A peer down for a day or more is parked on an hourly retry (`PeerLink::retry_delay`).
            // Scheduled before the notice goes out: the hub saves `next_retry_at` to the peer
            // cache while handling it, so a daemon restart mid-wait keeps the parked deadline.
            let delay = (!restarting).then(|| {
                self.with_link(|l| {
                    let now = crate::store::now_ms();
                    let mut delay = l.schedule_retry(&mut backoff, now, crate::peer_link::jitter());
                    if login_refusals > 0 {
                        let least =
                            Backoff::login_refused(login_refusals, crate::peer_link::jitter());
                        delay = delay.max(least);
                    }
                    // Reported only (`nextRetryAt`): the wait below keeps its own delay.
                    let waits = if redial_now { Duration::ZERO } else { delay };
                    l.retry_at = Some(now.saturating_add(waits.as_millis() as u64));
                    delay
                })
            });
            if let Some(notice) = notice {
                let _ = self.notices.send((self.name.clone(), self.generation, notice)).await;
            }
            self.fail_link_requests(&mut out_rx).await;
            if self.stop.load(Ordering::SeqCst) {
                break;
            }
            // One immediate attempt for this Close 1012. If that attempt fails, it follows
            // the unchanged real-failure backoff; restarting is not a persistent retry mode.
            immediate_redial = redial_now || (was_ready && restarting);
            let Some(delay) = delay else {
                continue;
            };
            let delay = if redial_now { Duration::ZERO } else { delay };
            match self.wait_backoff(delay).await {
                BackoffWait::Done => {}
                // The network that failed before the sleep may take a moment to come back: the
                // next attempts are quick ones again.
                BackoffWait::Woke => backoff.reset(),
                BackoffWait::Stopped => break,
            }
        }
        // Stopping during backoff (or before the loop starts) also retires
        // accepted callers retained by the previous link. No reconnect owns them now.
        self.fail_link_requests(&mut out_rx).await;
    }

    /// Publish the link ending before settling requests. Restart neither increments failed
    /// attempts nor draws from backoff; it starts backoff over when the previous link was stable.
    pub(super) fn finish_link(
        &self,
        outcome: Result<LinkEnd, String>,
        backoff: &mut Backoff,
    ) -> Option<PeerNotice> {
        *self.last_error.lock_or_recover() = outcome.as_ref().err().cloned();
        if matches!(&outcome, Ok(LinkEnd::Switching)) {
            // Another path of this peer answers: like a restart, its rows stay usable and the
            // next connect runs at once, but the remote's tokens are still good, and the backoff
            // stays as it is.
            self.switched.store(true, Ordering::SeqCst);
            self.link_ending(true);
            self.link_ended();
            self.open.store(false, Ordering::SeqCst);
            self.connected.store(false, Ordering::SeqCst);
            self.with_link(|l| l.restarting(crate::store::now_ms()));
            return Some(PeerNotice::Restarting);
        }
        self.link_ending(matches!(&outcome, Ok(LinkEnd::Restarting)));
        // The epoch moves first: a finishing handshake cannot leave a dead link ready.
        self.link_ended();
        self.open.store(false, Ordering::SeqCst);
        self.connected.store(false, Ordering::SeqCst);
        if matches!(&outcome, Ok(LinkEnd::Restarting)) {
            // The peer's daemon restarts (an update): a stable link's backoff starts over, as at
            // its drop, or each restart's failures add up and the next waits out a minute.
            let now = crate::store::now_ms();
            if self.link().ready_for(now).is_some_and(|up| up >= self.timings.stable_after) {
                backoff.reset();
            }
            self.with_link(|l| l.restarting(now));
            // Its next launch writes a new peer token.
            self.read_tokens.forget();
            return Some(PeerNotice::Restarting);
        }
        // An outage marks the rows stale: the next link reads its list (from its cursor) first.
        self.whole_list.store(false, Ordering::SeqCst);
        // A genuinely stable link starts failure backoff over; a flapping one does not.
        if self.with_link(|l| l.down(crate::store::now_ms(), self.timings.stable_after)) {
            backoff.reset();
        }
        outcome.err().map(PeerNotice::Disconnected)
    }

    /// The link ended. A request that never went out on it (still queued, or waiting for room
    /// in the queue) fails as not sent (`peer_unreachable`, retryable), and its frame is dropped,
    /// never sent on the next link. One that went out fails as `peer_disconnected`: the peer
    /// may have run it. An accepted prompt instead keeps its original waiter for recovery.
    pub(super) async fn fail_link_requests(&self, out_rx: &mut mpsc::Receiver<Outbound>) {
        let mut pending = self.pending.lock().await;
        while out_rx.try_recv().is_ok() {}
        let on_wire = std::mem::take(&mut *self.on_wire.lock_or_recover());
        // A link that switched paths keeps the requests bound to its connection: the next link
        // sends them again (`resend_switched`).
        let switched = self.switched.swap(false, Ordering::SeqCst);
        let mut survivors = HashMap::new();
        for (key, tx) in pending.drain() {
            // An accepted prompt is recovered on the next link; a request sent on both paths
            // waits for the other path's answer (`peer_dual.rs`).
            if !self.stop.load(Ordering::SeqCst)
                && !tx.is_closed()
                && (self.prompts.lock_or_recover().get(&key).is_some_and(|p| p.accepted)
                    || self.dual_carried(&key)
                    || (switched && self.carried.lock_or_recover().is_bound(&key)))
            {
                survivors.insert(key, tx);
                continue;
            }
            let _ = tx.send(Err(if on_wire.contains(&key) {
                RpcError::internal("peer disconnected").with_data(json!({
                    "reason": "peer_disconnected",
                    "detail": "the request went out before the link dropped; the peer may have run it",
                    "peer": self.name,
                }))
            } else {
                self.unreachable_error()
            }));
        }
        *pending = survivors;
        // What no live link carries leaves the record, but for what a switch sends again.
        self.carried.lock_or_recover().link_ended(self.link_epoch(), switched);
    }

    /// Rebind the original caller to the ledger's result, never resend its prompt.
    /// Replays chat `sid` of link `link` from `cursor`, page by page, before the link is
    /// ready: its records go through the hub as live events would. A chat that fails loses
    /// its baseline and is attached without history after connect (`attach_hidden`).
    pub(super) async fn replay_chat(
        &self,
        sid: String,
        cursor: u64,
        link: u64,
    ) -> Result<(), RpcError> {
        let mut after = cursor;
        let mut rewound = false;
        loop {
            // Pin every bounded page to this connection. Replay its records through
            // the same hub path as live events before releasing this session's gate.
            let ticket = self.attached.lock_or_recover().get(&sid).copied();
            let page = match self
                .link_request_on(method::MUX_ATTACH, hidden_attach_after(&sid, after), Some(link))
                .await
            {
                Ok(page) => page,
                // One chat must not fail replay and reconnect every other chat forever.
                // It loses its baseline and is attached without history after connect,
                // as `attach_hidden` does; one the peer refused is no longer marked,
                // unless a client marked it again meanwhile.
                Err(e) => {
                    let refused = refuses_attach(&e);
                    tracing::warn!(peer = %self.name, session = %sid, refused, "the peer's chat was not replayed: {}", e.message);
                    self.clear_attached(&sid);
                    if refused {
                        let mut marks = self.attached.lock_or_recover();
                        if marks.get(&sid).copied() == ticket {
                            marks.remove(&sid);
                        }
                    }
                    break;
                }
            };
            // A restored journal may be shorter than the copy we saw on
            // the previous link. Reset both cursors before requesting its
            // bounded pages, or every new live event below `after` is lost.
            if page.get("lastSeq").and_then(Value::as_u64).is_some_and(|last| last < after) {
                if rewound {
                    tracing::warn!(peer = %self.name, session = %sid, "the peer's journal kept moving backwards during replay");
                    self.clear_attached(&sid);
                    break;
                }
                let mut highwater = self.replay_highwater.lock_or_recover();
                self.cursors.lock_or_recover().insert(sid.clone(), 0);
                // Replayed from its start: 0 is its baseline now.
                self.baselined.lock_or_recover().insert(sid.clone());
                highwater.insert(sid.clone(), 0);
                after = 0;
                rewound = true;
                continue;
            }
            let mut progressed = false;
            if let Some(events) = page.get("events").and_then(Value::as_array) {
                for event in events {
                    if let Some(seq) = event.get("seq").and_then(Value::as_u64) {
                        progressed |= seq > after;
                        after = after.max(seq);
                    }
                    if self
                        .notices
                        .send((
                            self.name.clone(),
                            self.generation,
                            PeerNotice::Notification {
                                method: method::MUX_EVENT.to_owned(),
                                params: event.clone(),
                                link,
                            },
                        ))
                        .await
                        .is_err()
                    {
                        return Err(RpcError::internal("peer replay notice channel closed"));
                    }
                    self.note_live(event);
                }
            }
            let caught_up = {
                let mut highwater = self.replay_highwater.lock_or_recover();
                let caught_up = page.get("hasMore") != Some(&Value::Bool(true))
                    && highwater.get(&sid).copied().unwrap_or(after) <= after;
                if caught_up {
                    highwater.remove(&sid);
                    self.replay_tail.lock_or_recover().insert(sid.clone(), after);
                }
                caught_up
            };
            if caught_up {
                break;
            }
            if !progressed {
                tracing::warn!(peer = %self.name, session = %sid, "a replay page made no progress");
                self.clear_attached(&sid);
                break;
            }
        }
        Ok(())
    }

    pub(super) async fn recover_prompts(&self, link: u64) -> Result<(), RpcError> {
        let prompts: Vec<_> = self
            .prompts
            .lock_or_recover()
            .iter()
            .filter(|(_, p)| p.accepted)
            .map(|(k, p)| (k.clone(), p.clone()))
            .collect();
        for (key, prompt) in prompts {
            if !self.pending.lock().await.contains_key(&key) {
                continue;
            }
            let id: Value =
                serde_json::from_str(&key).map_err(|e| RpcError::internal(e.to_string()))?;
            let line = Message::request(id, method::MUX_WAIT,
                json!({"sessionId": prompt.session, "promptId": prompt.prompt, "until": ["promptOutcome"]}))
                .bounded_line().map_err(RpcError::too_large)?;
            self.out
                .send(Outbound { epoch: link, key: Some(key), line })
                .await
                .map_err(|_| RpcError::internal("peer connection closed"))?;
        }
        Ok(())
    }

    /// The `initialize` this peer link opens with.
    pub(super) fn initialize_hello(&self) -> Value {
        let mut hello = json!({"protocolVersion": 1, "clientCapabilities": {}, "clientInfo": {"name": CLIENT_NAME, "version": crate::hub::VERSION},
            // Large replies (the session list) may come compressed (`frame_compress.rs`).
            "_meta": {"acpmux": {"compression": crate::frame_compress::offer(),
                // Each chat's row change after the first as a patch, which the read loop makes
                // whole again (`peer_row_patch.rs`); a peer before version 2 sends whole rows.
                "sessionChangedDelta": crate::peer_row_patch::VERSION,
                // What this build reads (`server/client_features.rs`): the peer sends a gated
                // notification only once it is listed.
                crate::server::client_features::FIELD: crate::server::client_features::own()}}});
        // This Mac lends the peer its GitHub login (`hub/github_owner.rs` on the peer).
        if self.github_broker() {
            hello.set_path(&["_meta", "acpmux", "githubBroker"], json!(true));
        }
        hello
    }

    /// Asks the peer for `id`'s row whole (`_acpmux/session_resync`): a patch of it did not apply
    /// to what this link holds. Its answer is not waited for here: the row comes as a
    /// `session_changed` on this link, which the read loop holds.
    pub(super) fn resync_row(self: &Arc<Self>, link: u64, id: String) {
        let me = self.clone();
        self.scope.spawn_named("peer-row-resync", async move {
            let asked = json!({"sessionId": id});
            if let Err(e) = me
                .send_request(method::MUX_SESSION_RESYNC, asked, Some(link), ListKey::None)
                .await
            {
                tracing::debug!(peer = %me.name, session = %id, error = %e.message, "row resync not sent");
            }
        });
    }

    /// The `initialize` request for the upgrade's own flight: its id, and its masked WebSocket
    /// frame (`Heard::wrap_early`). The listener reads the bytes behind the upgrade request
    /// once it has answered 101, so the answer comes back one round trip sooner. None when the
    /// frame would not fit a request line.
    pub(super) fn early_initialize(&self) -> Option<(i64, Vec<u8>)> {
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let line = Message::request(id, method::INITIALIZE, self.initialize_hello())
            .bounded_line()
            .ok()?;
        Some((id, crate::peer_link::masked_text_frame(line.as_bytes())))
    }

    /// Register the answer of the `initialize` sent early (`id`) before the link reads, so a
    /// reply that arrived with the 101 finds its request.
    pub(super) async fn adopt_early_initialize(&self, id: i64) {
        let (tx, rx) = oneshot::channel();
        self.pending.lock().await.insert(Value::from(id).to_string(), tx);
        *self.early_init.lock_or_recover() = Some((id, rx));
    }
}

/// How late a timer of a link's loop may fire before the loop counts as stuck, not the peer
/// silent (`stalled`).
pub(crate) const LOOP_STALL: Duration = Duration::from_secs(1);

/// Whether a timer due at `due` that fired at `now` shows this link's loop stuck: on a Mac at
/// load 100 a task waits seconds for a thread, and the peer's answer waits unread meanwhile.
pub(crate) fn stalled(now: tokio::time::Instant, due: tokio::time::Instant) -> bool {
    now.saturating_duration_since(due) >= LOOP_STALL
}

/// Whether GitHub may be lent over a link to `url`: ssh (what Add Machine saves) or TLS, or a
/// plain WebSocket only on this machine's loopback. Over plain `ws://` to another host the
/// handshake that makes a link a peer could come from anything on the path.
pub(crate) fn lends_over(url: &str) -> bool {
    let Ok(u) = reqwest::Url::parse(url) else { return false };
    let host = u.host_str().unwrap_or("").trim_start_matches('[').trim_end_matches(']');
    match u.scheme() {
        "ssh" => ssh_target(url).is_ok(),
        "wss" => true,
        "ws" => {
            host == "localhost" || host.parse::<std::net::IpAddr>().is_ok_and(|ip| ip.is_loopback())
        }
        _ => false,
    }
}

/// How many of a link's chats its handshake attaches again at once after a reconnect.
pub(crate) const REATTACHES_AT_ONCE: usize = 16;

/// How long a link waits before each attach it tries again after one failed on it
/// ([`Peer::retry_attach`]): about a minute in all, then the chat waits for the next link.
pub(crate) const ATTACH_RETRY_AFTER: [Duration; 6] = [
    Duration::from_secs(1),
    Duration::from_secs(2),
    Duration::from_secs(4),
    Duration::from_secs(8),
    Duration::from_secs(16),
    Duration::from_secs(30),
];

/// The chats a reconnect replays from their cursor. A cursor still at 0 has no baseline yet
/// unless a page settled it (`baselined`: the chat held nothing then); one with none (its first
/// attach did not answer, or an older peer gave no `pageThrough`) would send its whole history
/// again as live events if replayed, so it is attached without history after connect.
pub(crate) fn replayable(
    cursors: &HashMap<String, u64>,
    baselined: &HashSet<String>,
) -> Vec<(String, u64)> {
    cursors
        .iter()
        .filter(|(sid, c)| **c > 0 || baselined.contains(*sid))
        .map(|(sid, c)| (sid.clone(), *c))
        .collect()
}

/// The greatest event sequence an `_acpmux/attach` page holds, if it holds any.
pub(crate) fn page_max_seq(page: &Value) -> Option<u64> {
    page.get("events")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|e| e.get("seq").and_then(Value::as_u64))
        .max()
}

/// Whether the peer itself refused an attach (`Peer::attach_hidden`): the chat is not there, or
/// the peer takes no such request. The link's own failures (dropped, timed out, too large, a
/// full queue) are internal errors or carry `peer_unreachable` / `peer_disconnected`, never
/// these codes.
pub(crate) fn refuses_attach(e: &RpcError) -> bool {
    matches!(e.code, -32002 | -32601 | -32602)
}

/// The list position an `_acpmux/watch` reply is current to (`hub/row_log.rs`): its
/// `listEpoch` and `listSeq`; None from a peer that keeps no row log.
pub(crate) fn list_position(reply: &Value) -> Option<(String, u64)> {
    let epoch = reply.get("listEpoch").and_then(Value::as_str)?;
    Some((epoch.to_owned(), reply.get("listSeq").and_then(Value::as_u64)?))
}

/// The peer's own ids of the rows a follow says went, without the rows it mirrors.
pub(crate) fn gone_ids(reply: &Value) -> Vec<String> {
    let gone = reply.get("gone").and_then(Value::as_array).into_iter().flatten();
    gone.filter(|row| row.get("peer").is_none_or(Value::is_null))
        .filter_map(|row| row.get("sessionId").and_then(Value::as_str).map(str::to_owned))
        .collect()
}

/// The sessions an `_acpmux/watch` reply lists, without the rows the peer itself mirrors, each
/// as its text: no row is copied as a `Value`.
pub(crate) fn watch_sessions(reply: &Value) -> Vec<Arc<str>> {
    reply
        .get("sessions")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|session| session.is_object() && !is_mirrored_session(session))
        .map(row_text)
        .collect()
}

/// `fut`'s output once it is set and done; never while it is not set.
async fn pending_or<F: std::future::Future + Unpin>(fut: &mut Option<F>) -> F::Output {
    match fut {
        Some(fut) => fut.await,
        None => std::future::pending().await,
    }
}

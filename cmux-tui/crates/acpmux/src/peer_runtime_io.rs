//! Peer request, notification, and link-loop operations.

use super::*;

impl Peer {
    /// [`Self::send_request`]; `retry`: sent again on the next link if this one switches paths
    /// before it answers (`peer_carried.rs`).
    async fn send_request_with(
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
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let (tx, rx) = oneshot::channel();
        let key = Value::from(id).to_string();
        self.pending.lock().await.insert(key.clone(), tx);
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
        match tokio::time::timeout_at(deadline, self.out.send(frame)).await {
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
    async fn resend_switched(&self, link: u64) {
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
    fn note_prompt_accepted(&self, p: &Value) {
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
        let Some(mut out_rx) = self.out_rx.lock().await.take() else {
            // A second run: the first owns the outbound queue and the link.
            tracing::warn!(peer = %self.name, "peer link already running");
            return;
        };
        if !self.retry_immediately.load(Ordering::SeqCst)
            && let Some(wait) = self.link().parked_retry_wait(crate::store::now_ms())
        {
            let reason = format!("peer unavailable; next automatic retry in {}s", wait.as_secs());
            *self.last_error.lock_or_recover() = Some(reason.clone());
            self.with_link(|_| ());
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
        while !self.stop.load(Ordering::SeqCst) {
            let outcome = self.connect_once(&mut out_rx).await;
            let restarting = matches!(&outcome, Ok(LinkEnd::Restarting | LinkEnd::Switching));
            let was_ready = self.link().is_ready();
            let notice = self.finish_link(outcome, &mut backoff);
            // A ready link that just died (a dropped network, a wake from sleep) redials at once:
            // chats are open on it. Only with no failure counted since its backoff last started
            // over, so a link that drops after each handshake waits its backoff from the second.
            let redial_now = was_ready && backoff.failures() == 0;
            // A peer down for a day or more is parked on an hourly retry (`PeerLink::retry_delay`).
            // Scheduled before the notice goes out: the hub saves `next_retry_at` to the peer
            // cache while handling it, so a daemon restart mid-wait keeps the parked deadline.
            let delay = (!restarting).then(|| {
                self.with_link(|l| {
                    let now = crate::store::now_ms();
                    let delay = l.schedule_retry(&mut backoff, now, crate::peer_link::jitter());
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
    fn finish_link(
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
    async fn fail_link_requests(&self, out_rx: &mut mpsc::Receiver<Outbound>) {
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
    async fn replay_chat(&self, sid: String, cursor: u64, link: u64) -> Result<(), RpcError> {
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

    async fn recover_prompts(&self, link: u64) -> Result<(), RpcError> {
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

    /// One link: dial this peer's paths (`peer_carriers.rs`), the one that carried it last
    /// first and each other one `STAGGER` later, and serve the first that opens until it ends.
    async fn connect_once(
        self: &Arc<Self>,
        out_rx: &mut mpsc::Receiver<Outbound>,
    ) -> Result<LinkEnd, String> {
        use crate::peer_paths::Via;
        self.facts.lock_or_recover().refused = false;
        #[cfg(test)]
        if test_dial::refused() {
            return Err("refused (test)".into());
        }
        let (via, opened) = self.open_first().await?;
        // A losing ssh attempt's process ends now.
        if via != Via::Ssh {
            self.end_tunnel().await;
        }
        *self.presented.lock().unwrap_or_else(|e| e.into_inner()) = opened.presented;
        self.carried_by(via.carrier().wire());
        self.set_serving(Some(via));
        self.start_probes();
        let heard = Some(opened.heard);
        let end = match opened.ws {
            carriers::OpenedWs::Boxed(ws) => self.serve_heard(*ws, out_rx, heard).await,
            carriers::OpenedWs::Url(ws) => self.serve_heard(*ws, out_rx, heard).await,
        };
        self.set_serving(None);
        self.dual_link_ended();
        let end = match (end, opened.ssh_errors) {
            (Err(error), Some(errors)) => {
                // End the owned SSH process now, including when its next attempt is an hour away.
                self.end_tunnel().await;
                let reason = errors.finish().await;
                self.note_ssh_failure(reason);
                Err(ssh_errors::describe(error, reason))
            }
            (end, errors) => {
                if errors.is_some() {
                    self.end_tunnel().await;
                }
                end
            }
        };
        match end {
            // The path died while another answers: the link moves there without an outage.
            Err(error) if !self.stop.load(Ordering::SeqCst) => {
                self.path_failed(via);
                if self.another_path_alive(via) && self.link().is_ready() {
                    tracing::info!(peer = %self.name, via = via.as_str(), "the link's path failed ({error}); moving to another path");
                    return Ok(LinkEnd::Switching);
                }
                Err(error)
            }
            end => end,
        }
    }

    fn ws_request(
        &self,
        url: &str,
        token: Option<&str>,
        peer_token: Option<&str>,
    ) -> Result<tokio_tungstenite::tungstenite::handshake::client::Request, String> {
        // A peer URL saved with `?token=` in it: the listener takes the token
        // only from a header, so it moves there and out of the URL.
        let (url, query_token) = lift_query_token(url);
        let token = token.or(query_token.as_deref());
        let mut req = url.as_str().into_client_request().map_err(|e| e.to_string())?;
        if let Some(t) = token {
            req.headers_mut().insert(
                "authorization",
                format!("Bearer {t}").parse().map_err(|_| "bad token".to_owned())?,
            );
        }
        if let Some(p) = peer_token {
            req.headers_mut().insert(
                crate::server::peer_auth::HEADER,
                p.parse().map_err(|_| "bad peer token".to_owned())?,
            );
        }
        Ok(req)
    }

    /// Run one connected WebSocket until it closes; its silence is counted from its frames.
    #[cfg(test)]
    async fn serve<S>(
        self: &Arc<Self>,
        ws: tokio_tungstenite::WebSocketStream<S>,
        out_rx: &mut mpsc::Receiver<Outbound>,
    ) -> Result<LinkEnd, String>
    where
        S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
    {
        self.serve_heard(ws, out_rx, None).await
    }

    /// Run one connected WebSocket until it closes. With `heard` (its transport's reads), the
    /// link is silent only while no byte arrives, so a large frame on a slow link keeps it up.
    async fn serve_heard<S>(
        self: &Arc<Self>,
        ws: tokio_tungstenite::WebSocketStream<S>,
        out_rx: &mut mpsc::Receiver<Outbound>,
        heard: Option<crate::peer_link::Heard>,
    ) -> Result<LinkEnd, String>
    where
        S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
    {
        use tokio_tungstenite::tungstenite::Message as Frame;
        let (mut sink, mut source) = ws.split();
        // Open, not connected: callers' requests are refused until the handshake finished
        // (`connected`), and only the handshake's own go out on this link (`link`).
        let link = self.link_epoch();
        self.admitting.store(true, Ordering::SeqCst);
        self.open.store(true, Ordering::SeqCst);
        // Gate existing streams before initialize/watch or outcome recovery can
        // produce events. A live record must not move the replay cursor past a gap.
        let replay_cursors =
            replayable(&self.cursors.lock_or_recover(), &self.baselined.lock_or_recover());
        *self.replay_highwater.lock_or_recover() = replay_cursors.into_iter().collect();
        self.replay_tail.lock_or_recover().clear();
        *self.last_error.lock_or_recover() = None;
        self.received.reset();
        self.with_link(|l| l.opened(crate::store::now_ms()));
        tracing::info!(peer = %self.name, "link open to {}; handshaking", lift_query_token(&self.url).0);

        // Handshake in a task so the read loop below can serve the responses.
        let me = self.clone();
        let (stale_tx, mut stale_rx) = oneshot::channel::<String>();
        // Whether the handshake kept the watch it sent with `initialize` (`pipelined_key`).
        let (kept_tx, mut kept_rx) = oneshot::channel::<bool>();
        *self.pipelined_key.lock_or_recover() = None;
        let mut handshake = tokio::spawn(async move {
            let mut hello = json!({"protocolVersion": 1, "clientCapabilities": {}, "clientInfo": {"name": CLIENT_NAME, "version": crate::hub::VERSION},
                // Large replies (the session list) may come compressed (`frame_compress.rs`).
                "_meta": {"acpmux": {"compression": crate::frame_compress::offer()}}});
            // This Mac lends the peer its GitHub login (`hub/github_owner.rs` on the peer).
            if me.github_broker() {
                hello.set_path(&["_meta", "acpmux", "githubBroker"], json!(true));
            }
            // The watch goes out with `initialize`, not a round trip after it, when the last link
            // says which it will be (`pipelined_watch`); its reply waits in the reader until the
            // initialize reply says it was the one to ask (`keep_pipelined`).
            let pipelined = me.pipelined_watch();
            let sent = futures::future::maybe_done(async {
                let params = pipelined.clone()?;
                Some(
                    me.send_request(method::MUX_WATCH, params, Some(link), ListKey::Pipelined)
                        .await,
                )
            });
            tokio::pin!(sent);
            let init = me.link_request_on(method::INITIALIZE, hello, Some(link));
            tokio::pin!(init);
            // Polled in this order: `initialize` is queued first.
            let init = std::future::poll_fn(|cx| {
                let init = std::future::Future::poll(init.as_mut(), cx);
                let _ = std::future::Future::poll(sent.as_mut(), cx);
                init
            })
            .await?;
            let v = init
                .pointer("/_meta/acpmux/version")
                .and_then(Value::as_str)
                .unwrap_or("?")
                .to_owned();
            let b = init
                .pointer("/_meta/acpmux/build")
                .and_then(Value::as_str)
                .unwrap_or("unknown")
                .to_owned();
            let build = (b != "unknown").then(|| b.clone());
            *me.remote_version.lock_or_recover() = Some((v, b));
            *me.served_as.lock().unwrap_or_else(|e| e.into_inner()) =
                init.pointer("/_meta/acpmux/origin").and_then(Value::as_str).map(str::to_owned);
            // Before any session is watched or attached on this link.
            if let Some(why) = me.stale_token().await {
                let _ = stale_tx.send(why);
                return Ok(());
            }
            me.admitting.store(false, Ordering::SeqCst);
            *me.person_instance.lock().unwrap_or_else(|e| e.into_inner()) = init
                .pointer("/_meta/acpmux/personInstance")
                .and_then(Value::as_str)
                .map(str::to_owned);
            let lists = |feature: &str| {
                init.pointer("/_meta/acpmux/features")
                    .and_then(Value::as_array)
                    .is_some_and(|features| features.iter().any(|f| f.as_str() == Some(feature)))
            };
            let advertised = lists("trustGate")
                || init.pointer("/_meta/acpmux/trustGate").and_then(Value::as_bool) == Some(true);
            me.trust_gate.store(advertised, Ordering::SeqCst);
            let set =
                |flag: &AtomicBool, feature: &str| flag.store(lists(feature), Ordering::SeqCst);
            set(&me.file_put, crate::hub::FILE_PUT_FEATURE);
            set(&me.file_put_chunks, crate::hub::file_uploads::CHUNKS_FEATURE);
            set(&me.media_read, crate::hub::MEDIA_READ_FEATURE);
            set(&me.subagent_transcript, crate::hub::SUBAGENT_TRANSCRIPT_FEATURE);
            set(&me.native_history, crate::hub::NATIVE_HISTORY_FEATURE);
            set(&me.session_auth, crate::hub::session_auth::FEATURE);
            set(&me.person_stop, crate::hub::cancel::PERSON_STOP_FEATURE);
            set(&me.pipelines, HANDSHAKE_PIPELINE_FEATURE);
            // The rest are read from the list (`lists`): attachments, uploads, upload status,
            // and holding a prompt for the owner.
            let listed = init.pointer("/_meta/acpmux/features").and_then(Value::as_array);
            let listed = listed.into_iter().flatten().filter_map(Value::as_str);
            *me.features.lock_or_recover() = listed.map(str::to_owned).collect();
            // Whether this daemon takes this link as its peer principal (`peer_dual.rs`):
            // its own answer on this connection, read again on each link.
            if let Some(via) = me.serving() {
                let principal = init.pointer("/_meta/acpmux/dualPrincipal");
                me.note_token_path(via, principal == Some(&Value::Bool(true)));
            }
            let resumes = lists(crate::server::SESSION_RESUME_FEATURE);
            me.session_resume_link.store(if resumes { link + 1 } else { 0 }, Ordering::SeqCst);
            let messages = init
                .pointer("/_meta/acpmux/capabilities")
                .and_then(Value::as_array)
                .is_some_and(|ids| {
                    ids.iter().any(|id| id.as_str() == Some(crate::capabilities::SESSION_MESSAGES))
                });
            me.session_messages.store(messages, Ordering::SeqCst);
            let follows =
                init.pointer("/_meta/acpmux/capabilities").and_then(Value::as_array).is_some_and(
                    |ids| ids.iter().any(|id| id.as_str() == Some(crate::hub::row_log::CAPABILITY)),
                );
            me.list_follow.store(follows, Ordering::SeqCst);
            let kept = me.keep_pipelined(pipelined.as_ref(), build.as_ref());
            let _ = kept_tx.send(kept);
            let mut sent = if kept {
                sent.as_mut().await;
                sent.as_mut().take_output().flatten()
            } else {
                None
            };
            // The reader published the reply's list (`watch_key`), so Connected follows it.
            // Without tools: an inventory is read per session, on an attachment (whose
            // `session_changed` notices carry it) or `_acpmux/info`, never in the list. With
            // them one host's list was 23 MB for 3,700 rows (2026-10-31), past the message
            // limit, and every link to it built and was refused one list before reading it
            // again without them; without them 16.6 MB. A follow is asked for as the list it
            // patches was read (`cursor_tools`).
            let watch = |tools: bool| json!({"enabled": true, "withTools": tools});
            let row_pages = build.is_some() && *me.row_pages_for.lock_or_recover() == build;
            // A link that read the list before reads only what changed since its cursor
            // (`hub/row_log.rs`), with or without tools as that list was (`first_watch`). A peer
            // that cannot follow it answers with the whole list, marked `reset`.
            let mut answered = None;
            if let Some((asked, tools)) =
                me.first_watch(build.as_ref()).filter(|(asked, _)| asked.get("afterSeq").is_some())
            {
                match me.watch_first(asked, link, sent.take()).await {
                    Err(e) if too_large(&e) => {
                        tracing::warn!(peer = %me.name, "the watch follow is too large ({}); reading the whole list", e.message);
                    }
                    answer => answered = Some((answer?, tools)),
                }
            }
            let first = if answered.is_some() {
                answered
            } else if row_pages {
                tracing::info!(peer = %me.name, "the watch list needed pages of rows last time; reading it so");
                me.watch_row_pages(link).await?;
                None
            } else {
                match me.watch_first(watch(false), link, sent.take()).await {
                    // A peer from before #28182 sends a whole list in one message or not at
                    // all (cosmic-gray's NIGHTLY, 16.4 MB without tools, on 2026-10-30): it is
                    // read in pages of a count of rows, which such a peer serves.
                    Err(e) if too_large(&e) => {
                        tracing::warn!(peer = %me.name, "the watch list is too large ({}); reading it in pages", e.message);
                        me.watch_row_pages(link).await?;
                        *me.row_pages_for.lock_or_recover() = build.clone();
                        None
                    }
                    answer => Some((answer?, false)),
                }
            };
            // A list too large for one message comes in pages (a peer served as Web, over
            // plain ws://, gets the whole list): every page is read before the link connects,
            // and the reader publishes the list once, whole, after the last.
            let tools = first.as_ref().is_some_and(|(_, tools)| *tools);
            if let Some((first, tools)) = first {
                me.watch_pages(first, tools, link).await?;
            }
            // Read whole (its last page too, or the follow): the next follow is asked for as this
            // list was read.
            me.cursor_tools.store(tools, Ordering::SeqCst);
            me.recover_prompts(link).await?;
            let attached =
                replayable(&me.cursors.lock_or_recover(), &me.baselined.lock_or_recover());
            // Forwarders can register an attachment during the handshake before
            // request_on refuses their request. Gate those sessions too, without
            // replacing high-water marks already observed on this connection.
            {
                let mut highwater = me.replay_highwater.lock_or_recover();
                for (sid, cursor) in &attached {
                    highwater.entry(sid.clone()).or_insert(*cursor);
                }
            }
            // Several chats at once, each page by page: a reconnect with many chats waits one
            // round trip per page of the longest, not per page of all of them in turn.
            let replays = futures::stream::iter(attached)
                .map(|(sid, cursor)| me.replay_chat(sid, cursor, link))
                .buffer_unordered(REATTACHES_AT_ONCE);
            tokio::pin!(replays);
            while let Some(replayed) = replays.next().await {
                replayed?;
            }

            // Connected only now, and ready with it, so its state note follows `connected`.
            // Admit new requests only after all replay pages have reached subscribers.
            // Otherwise a fresh attach can return those pages before replay emits them again.
            // `run` moves the epoch on before it clears `connected` and takes the link down, so
            // a link that dropped meanwhile is seen here: it is not made ready again, and never
            // left reading connected.
            let live = me.with_link(|l| {
                let live = me.link_epoch() == link;
                if live {
                    me.connected.store(true, Ordering::SeqCst);
                    me.linked_once.store(true, Ordering::SeqCst);
                    me.slow_banner.store(false, Ordering::SeqCst);
                    l.ready(crate::store::now_ms());
                }
                live
            });
            if !live || me.link_epoch() != link {
                me.connected.store(false, Ordering::SeqCst);
                return Ok(());
            }
            let (frames, text) = me.received.read();
            tracing::info!(
                peer = %me.name,
                frame_bytes = frames,
                text_bytes = text,
                "connected to {}",
                lift_query_token(&me.url).0
            );
            me.listed_links.lock_or_recover().push_back(link);
            let _ = me.notices.send((me.name.clone(), me.generation, PeerNotice::Connected)).await;
            // The path it is ready on is the one to dial first next time, also after a restart.
            me.note_ready_path();
            // What the last link bound to its connection and never answered, on this one.
            me.resend_switched(link).await;
            // Several at once: a chat the peer is slow on holds up no other's stream, and a
            // link with many chats does not fill its send queue with them.
            // Chats with a cursor were replayed above; the rest have no baseline yet.
            let attached: Vec<String> = {
                let marks = me.attached.lock_or_recover();
                let cursors = me.cursors.lock_or_recover();
                let baselined = me.baselined.lock_or_recover();
                let replayed = |sid: &String| {
                    cursors.get(sid).is_some_and(|c| *c > 0 || baselined.contains(sid))
                };
                marks.keys().filter(|sid| !replayed(sid)).cloned().collect()
            };
            // Each starts its stream anew at the peer's present, so what the peer sent since the
            // last link is a hole: its clients are told they lagged, and read it themselves.
            let (peer, epoch) = (&me, link);
            futures::stream::iter(attached.iter())
                .for_each_concurrent(REATTACHES_AT_ONCE, |sid| async move {
                    if peer.attach_hidden(sid).await.is_ok() && peer.link_epoch() == epoch {
                        peer.tell_reattached(sid, epoch).await;
                    }
                })
                .await;
            me.refresh_health();
            Ok::<(), RpcError>(())
        });

        // Keepalive: a ping each interval; any byte is an answer. A peer
        // silent for the whole silence budget (`SilenceBudget`: longer for one
        // that answers late), or one that stops reading so a send cannot go
        // out within the send budget, is dropped and reconnected; one interval
        // of silence only marks it degraded.
        let timings = self.timings;
        let (was, silence) = self.with_silence(|b| {
            let was = b.current();
            b.opened(tokio::time::Instant::now());
            (was, b.current())
        });
        if silence != was {
            tracing::info!(peer = %self.name, "silence budget {}s (was {}s; a link dropped for silence opened again: the peer is slow, not gone)", silence.as_secs(), was.as_secs());
        }
        // The first read's gap is the connect, not an answer.
        if let Some(heard) = &heard {
            heard.take_gap();
        }
        let mut frame_gap = Duration::ZERO;
        let budget = timings.send;
        let mut ping = tokio::time::interval_at(
            tokio::time::Instant::now() + timings.ping_every,
            timings.ping_every,
        );
        ping.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        let mut last_frame = tokio::time::Instant::now();
        let mut stale_settled = false;
        let mut handshake_ended = false;
        let mut ticks: u64 = 0;
        // Moved on by each page of a watch list read in pages, up to `HANDSHAKE_MOST` in all: a
        // peer that paces its lists still links, one that stops answering does not hold it.
        let handshake_started = tokio::time::Instant::now();
        let handshake_deadline = tokio::time::sleep(timings.handshake);
        tokio::pin!(handshake_deadline);
        // After this computer slept, the link's monotonic timers say its last frame came moments
        // ago, while its ssh tunnel has often died: a ping goes out at once, and the link is
        // dropped (and redialed) when nothing answers within `WAKE_PROBE`, rather than after the
        // ssh keepalive or the whole silence budget. Stops with the link.
        let mut wake_watch = SleepWatch::now();
        let mut wake_check = tokio::time::interval_at(
            tokio::time::Instant::now() + SleepWatch::EVERY,
            SleepWatch::EVERY,
        );
        wake_check.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        let mut wake_probe: Option<tokio::time::Instant> = None;
        // The clocks are read before every write too, not only on `wake_check`'s tick: after a wake
        // the regular ping's tick may be served first, and its write must be held to the probe's
        // deadline, never the whole send budget.
        macro_rules! check_wake {
            () => {
                if let Some(slept) = wake_watch.check() {
                    tracing::info!(peer = %self.name, "this computer slept {}s; checking the link", slept.as_secs());
                    // One deadline for the ping to go out and its answer to come back.
                    let deadline = tokio::time::Instant::now() + WAKE_PROBE;
                    match tokio::time::timeout_at(deadline, sink.send(Frame::Ping(Vec::new().into()))).await {
                        Ok(Ok(())) => wake_probe = Some(deadline),
                        Ok(Err(e)) => break Err(e.to_string()),
                        Err(_) => break Err(stopped_reading(WAKE_PROBE)),
                    }
                }
            };
        }
        // The rows of a watch list read in pages so far, and the changes the peer sent
        // meanwhile: published once the last page is in, the list first. A link that drops
        // before then publishes neither, so the hub keeps its last whole list.
        let mut paged: Option<(Vec<Arc<str>>, Vec<PeerNotice>)> = None;
        // The position the watch list read so far is current to (`list_position`), and whether
        // this link's list reached the hub: until it does, a change moves no cursor, since the
        // hub holds the last link's list and misses what changed while no link was up.
        let mut list_at: Option<(String, u64)> = None;
        let mut listed = false;
        // A reply to this daemon's request: a watch list's (`watch_key`) is published here, before
        // the next frame is read.
        macro_rules! watch_reply {
            ($key:expr, $reply:expr, $tx:expr) => {{
                let (key, reply, tx): (
                    String,
                    Result<Value, RpcError>,
                    oneshot::Sender<Result<Value, RpcError>>,
                ) = ($key, $reply, $tx);
                let watch = self.watch_key.lock_or_recover().take_if(|k| *k == key).is_some();
                // The handshake's last step answered on this link, as a peer serving
                // this daemon: GitHub actions are taken from here on, and the
                // added machine asks only after sending this answer
                // (`hub/github_owner.rs`).
                if watch && reply.is_ok() && self.served_as().as_deref() == Some("peer") {
                    self.github_link.store(link + 1, Ordering::SeqCst);
                }
                if let (true, Ok(list)) = (watch, &reply) {
                    let (mut rows, held) = paged.take().unwrap_or_default();
                    rows.extend(watch_sessions(list));
                    // The position the list is current to comes with its first page (the watch's
                    // reply); the hub holds it once the last page is applied (`hub/row_log.rs`).
                    if let Some(at) = list_position(list) {
                        list_at = Some(at);
                    }
                    let follow = list.get("follow") == Some(&Value::Bool(true));
                    match page_cursor(list) {
                        // More pages: the handshake asks for them.
                        Ok(Some(_)) => {
                            paged = Some((rows, held));
                            let until = (tokio::time::Instant::now() + timings.handshake)
                                .min(handshake_started + HANDSHAKE_MOST.max(timings.handshake));
                            handshake_deadline.as_mut().reset(until);
                        }
                        // A bad cursor: the handshake fails and the link drops.
                        Err(_) => {}
                        Ok(None) => {
                            let mut stopped = false;
                            *self.list_cursor.lock_or_recover() = list_at.take();
                            listed = true;
                            let list = if follow {
                                PeerNotice::SessionsPatch { rows, gone: gone_ids(list) }
                            } else {
                                PeerNotice::Sessions(rows)
                            };
                            for notice in std::iter::once(list).chain(held) {
                                if self
                                    .notices
                                    .send((self.name.clone(), self.generation, notice))
                                    .await
                                    .is_err()
                                {
                                    stopped = true;
                                    break;
                                }
                            }
                            if stopped {
                                break Ok(LinkEnd::Stopped);
                            }
                        }
                    }
                }
                let _ = tx.send(reply);
            }};
        }
        // The reply to the watch sent with `initialize`, held until the handshake settles it.
        let mut pipelined: Option<(
            String,
            Result<Value, RpcError>,
            oneshot::Sender<Result<Value, RpcError>>,
        )> = None;
        let mut pipelined_settled = false;
        // GitHub actions the peer asked for after the held watch reply: the peer asks only after
        // sending that answer (`hub/github_owner.rs`), so they wait for the handshake to settle
        // it, and are admitted or refused then, in order. At most `OWNER_SLOTS` wait; any more
        // are judged at once, as they would be anyway.
        let mut deferred_github: Vec<(Value, Option<Value>)> = Vec::new();
        // A request from the peer for a GitHub action, admitted or refused on this link now.
        macro_rules! github_request {
            // `$link` is the reader loop's label, named at the call (labels are hygienic).
            ($link:lifetime, $id:expr, $params:expr) => {{
                let (id, params): (Value, Option<Value>) = ($id, $params);
                // Refused here, before anything is spawned, unless this Mac lends the peer
                // GitHub, the handshake on this link finished, and a slot is free.
                let admitted = crate::github_broker::admit_owner(&self.name, self.github_ready(link), &self.github_slots);
                match admitted {
                    Ok(slot) => self.serve_github_action(id, params.unwrap_or(Value::Null), slot, link),
                    Err(e) => {
                        // Bounded like any frame: a peer that asks and never reads cannot hold
                        // this loop.
                        let refusal = Frame::Text(Message::err(id, e).to_value().to_string().into());
                        match tokio::time::timeout(budget, sink.send(refusal)).await {
                            Ok(Ok(())) => {}
                            Ok(Err(e)) => break $link Err(e.to_string()),
                            Err(_) => break $link Err(stopped_reading(budget)),
                        }
                    }
                }
            }};
        }
        let result = 'link: loop {
            if self.stop.load(Ordering::SeqCst) {
                break Ok(LinkEnd::Stopped);
            }
            tokio::select! {
                _ = self.stop_signal.notified() => break Ok(LinkEnd::Stopped),
                _ = wake_check.tick() => check_wake!(),
                _ = tokio::time::sleep_until(wake_probe.unwrap_or_else(tokio::time::Instant::now)), if wake_probe.is_some() => {
                    break Err(format!("no answer {}s after this computer woke", WAKE_PROBE.as_secs()));
                }
                // Once only. A watch the handshake dropped is never published, and the changes
                // held after it wait for the list asked for instead (`paged`).
                kept = &mut kept_rx, if !pipelined_settled => {
                    pipelined_settled = true;
                    if let Some((key, reply, tx)) = pipelined.take()
                        && kept == Ok(true)
                    {
                        watch_reply!(key, reply, tx);
                    }
                    for (id, params) in std::mem::take(&mut deferred_github) {
                        github_request!('link, id, params);
                    }
                }
                // Once only: a finished oneshot is not polled again.
                stale = &mut stale_rx, if !stale_settled => {
                    stale_settled = true;
                    if let Ok(why) = stale {
                        break Err(why);
                    }
                }
                // A handshake that ended without making the link ready ends the link now, with
                // why: a step the peer refused (or that failed on this link), a stale token, a
                // link that dropped meanwhile, or a task that panicked. The deadline below would
                // only say the handshake timed out.
                ended = &mut handshake, if !handshake_ended => {
                    handshake_ended = true;
                    match ended {
                        Ok(Err(e)) => break Err(format!("handshake failed: {}", e.message)),
                        Err(e) => break Err(format!("handshake failed: {e}")),
                        Ok(Ok(())) if !self.link().is_ready() => {
                            // The stale-token path sends its reason before it returns.
                            if !stale_settled && let Ok(why) = stale_rx.try_recv() {
                                break Err(why);
                            }
                            break Err("handshake ended before the link was ready".to_owned());
                        }
                        Ok(Ok(())) => {}
                    }
                }
                _ = &mut handshake_deadline, if !self.link().is_ready() => {
                    break Err(timed_out(handshake_started));
                }
                _ = ping.tick() => {
                    // The selector moved the session to a faster path: the link moves while no
                    // request is out on it.
                    self.paths_tick();
                    if self.link().is_ready() && self.switch_due() {
                        break Ok(LinkEnd::Switching);
                    }
                    let now = tokio::time::Instant::now();
                    let gap = heard.as_ref().map_or_else(|| std::mem::take(&mut frame_gap), Heard::take_gap);
                    let (was, silence) = self.with_silence(|b| {
                        let was = b.current();
                        b.answered_after(gap, now);
                        b.settle(now);
                        (was, b.current())
                    });
                    if silence != was {
                        tracing::info!(peer = %self.name, "silence budget {}s (was {}s; longest wait for an answer {}ms)", silence.as_secs(), was.as_secs(), gap.as_millis());
                    }
                    let silent = heard.as_ref().map_or(last_frame.elapsed(), |h| h.silent().min(last_frame.elapsed()));
                    if silent >= silence {
                        self.with_silence(|b| b.dropped(now));
                        break Err(format!("peer stopped answering ({}s without a frame)", silent.as_secs()));
                    }
                    if silent >= timings.ping_every {
                        self.with_link(Link::overdue);
                    }
                    check_wake!();
                    let until = write_deadline(tokio::time::Instant::now(), budget, wake_probe);
                    // Stamped, so its pong measures this path's round trip (`peer_paths.rs`).
                    match tokio::time::timeout_at(until, sink.send(Frame::Ping(carriers::ping_stamp().into()))).await {
                        Ok(Ok(())) => {}
                        Ok(Err(e)) => break Err(e.to_string()),
                        Err(_) => break Err(write_late(budget, wake_probe)),
                    }
                    ticks += 1;
                    if ticks.is_multiple_of(health::HEALTH_EVERY) && self.link().is_ready() {
                        self.refresh_health();
                    }
                }
                frame = source.next() => {
                    let Some(frame) = frame else { break Err("peer closed the connection".to_owned()) };
                    let frame = match frame { Ok(f) => f, Err(e) => break Err(e.to_string()) };
                    // `select!` is unbiased: a frame read as the deadline passes may not finish
                    // the handshake (or move the deadline on past its cap).
                    if !self.link().is_ready() && handshake_deadline.is_elapsed() {
                        break Err(timed_out(handshake_started));
                    }
                    frame_gap = frame_gap.max(last_frame.elapsed());
                    last_frame = tokio::time::Instant::now();
                    wake_probe = None;
                    self.with_link(|l| l.heard(crate::store::now_ms()));
                    let (text, compressed) = match frame {
                        tokio_tungstenite::tungstenite::Message::Text(t) => {
                            self.received.add(t.len(), t.len());
                            (t.to_string(), false)
                        }
                        // Asked for in `initialize` (`frame_compress.rs`). One that does not
                        // inflate would lose a reply its caller waits on: the link starts over.
                        Frame::Binary(b) => match crate::frame_compress::inflate(&b, crate::server::WS_MAX_MESSAGE_BYTES) {
                            Ok(text) => {
                                self.received.add(b.len(), text.len());
                                (text, true)
                            }
                            Err(e) => break Err(e),
                        },
                        Frame::Close(Some(close)) if close.code == tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode::Restart => {
                            break Ok(LinkEnd::Restarting);
                        }
                        Frame::Close(_) => break Err("peer closed the connection".to_owned()),
                        Frame::Pong(payload) => {
                            if let (Some(rtt), Some(via)) = (carriers::pong_rtt(&payload), self.serving()) {
                                self.path_pong(via, rtt);
                            }
                            continue;
                        }
                        _ => continue,
                    };
                    let msg = match Message::parse(&text) {
                        Ok(msg) => msg,
                        // Only large messages are compressed, and a reply among them would be
                        // lost while its caller waits: the link starts over, as for a frame
                        // that does not inflate.
                        Err(e) if compressed => break Err(format!("a compressed frame is not a JSON-RPC message: {e}")),
                        Err(_) => continue,
                    };
                    match msg {
                        Message::Response { id, result, error } => {
                            let key = id.to_string();
                            // Not held while a notice waits for room: a caller registers under it.
                            let tx = self.pending.lock().await.remove(&key);
                            self.on_wire.lock_or_recover().remove(&key);
                            let Some(tx) = tx else {
                                self.cancelled.lock_or_recover().take_late(&key, "peer");
                                continue;
                            };
                            let reply = match error { Some(e) => Err(e), None => Ok(result.unwrap_or(Value::Null)) };
                            // A watch sent with `initialize` waits for the handshake to read that
                            // reply, and the changes after it wait with it (`paged`).
                            if self.pipelined_key.lock_or_recover().as_deref() == Some(key.as_str()) {
                                paged.get_or_insert_default();
                                pipelined = Some((key, reply, tx));
                                continue;
                            }
                            watch_reply!(key, reply, tx);
                        }
                        Message::Notification { method: m, params } => {
                            let p = params.unwrap_or(Value::Null);
                            if matches!(m.as_str(), method::MUX_EVENT | method::SESSION_UPDATE) {
                                let mut highwater = self.replay_highwater.lock_or_recover();
                                let id = p.get("sessionId").and_then(Value::as_str);
                                let seq = p.get("seq").and_then(Value::as_u64)
                                    .or_else(|| p.pointer("/_meta/acpmux/seq").and_then(Value::as_u64));
                                if let (Some(id), Some(seq)) = (id, seq)
                                    && let Some(high) = highwater.get_mut(id)
                                {
                                    *high = (*high).max(seq);
                                    continue;
                                }
                                drop(highwater);
                            }
                            // Record before publishing the acceptance: a link can drop before the
                            // hub consumes its notice, but the original client still owns the turn.
                            if m == method::MUX_PROMPT_ACCEPTED {
                                self.note_prompt_accepted(&p);
                            }
                            let cursor_event = matches!(m.as_str(), method::MUX_EVENT | method::SESSION_UPDATE)
                                .then(|| {
                                    let id = p.get("sessionId")?.as_str()?.to_owned();
                                    let seq = p.get("seq").and_then(Value::as_u64)
                                        .or_else(|| p.pointer("/_meta/acpmux/seq").and_then(Value::as_u64))?;
                                    Some((id, seq))
                                }).flatten();
                            // A live frame can have been queued before the final replay page,
                            // yet be read after the gate opens. Its sequence already arrived.
                            if let Some((id, seq)) = &cursor_event {
                                let replayed = {
                                    let mut tails = self.replay_tail.lock_or_recover();
                                    match tails.get(id) {
                                        Some(tail) if *seq > 0 && tail >= seq => true,
                                        Some(_) => { tails.remove(id); false }
                                        None => false,
                                    }
                                };
                                if replayed {
                                    continue;
                                }
                                // Sent on two paths while this one was in doubt: one merger
                                // hands each event to the hub once and in order, and moves the
                                // cursor as it does (`peer_dual.rs`).
                                let link = self.link_epoch();
                                let merged =
                                    self.merge_event(id, *seq, m, p, dual::Source::Link, link).await;
                                if merged == dual::Merged::Closed {
                                    break Ok(LinkEnd::Stopped);
                                }
                                continue;
                            }
                            // Only the link itself says a chat was attached again.
                            if m == REATTACHED_NOTICE {
                                continue;
                            }
                            // The peer left out notices (a full queue, one too large, a lagging
                            // reader): the hub's copy is no longer current to any position, so
                            // the next link reads the whole list.
                            if m == "_acpmux/lagged" {
                                *self.list_cursor.lock_or_recover() = None;
                            }
                            let notice = if m == method::MUX_SESSION_CHANGED {
                                let session = p.get("session").cloned().unwrap_or(Value::Null);
                                // Remote session_changed notifications carry the
                                // peer name at the top level; older summaries
                                // also carry it inside `session`.
                                if p.get("peer").and_then(Value::as_str).is_some()
                                    || is_mirrored_session(&session)
                                {
                                    continue;
                                }
                                // The hub's copy of the list is current to here, once this link's
                                // list reached it (`listed`).
                                if listed
                                    && let Some(seq) = p.get("listSeq").and_then(Value::as_u64)
                                    && let Some((_, at)) = self.list_cursor.lock_or_recover().as_mut()
                                {
                                    *at = (*at).max(seq);
                                }
                                PeerNotice::SessionChanged {
                                    session,
                                    kind: p.get("kind").and_then(Value::as_str).unwrap_or("").to_owned(),
                                    seq: p.get("seq").and_then(Value::as_u64).unwrap_or(0),
                                }
                            } else {
                                PeerNotice::Notification { method: m, params: p, link: self.link_epoch() }
                            };
                            // A change during a paged watch list goes after that list.
                            if let (Some((_, held)), PeerNotice::SessionChanged { .. }) = (paged.as_mut(), &notice) {
                                held.push(notice);
                                continue;
                            }
                            if self.notices.send((self.name.clone(), self.generation, notice)).await.is_err() {
                                break Ok(LinkEnd::Stopped);
                            }
                            if let Some((id, seq)) = cursor_event
                                && let Some(last) = self.cursors.lock_or_recover().get_mut(&id)
                            { *last = (*last).max(seq); }
                        }
                        Message::Request { id, method: m, params } if m == method::MUX_GITHUB_ACTION => {
                            // Asked after the watch reply the handshake holds: it waits for that
                            // reply to be settled (`deferred_github`).
                            if pipelined.is_some()
                                && !pipelined_settled
                                && deferred_github.len() < crate::github_broker::OWNER_SLOTS
                            {
                                deferred_github.push((id, params));
                                continue;
                            }
                            github_request!('link, id, params);
                        }
                        Message::Request { id, .. } => {
                            // Any other request from the peer: the broker's is the only one.
                            let refusal = Frame::Text(
                                Message::err(id, RpcError::method_not_found("client-side request")).to_value().to_string().into(),
                            );
                            match tokio::time::timeout(budget, sink.send(refusal)).await {
                                Ok(Ok(())) => {}
                                Ok(Err(e)) => break Err(e.to_string()),
                                Err(_) => break Err(stopped_reading(budget)),
                            }
                        }
                    }
                }
                line = out_rx.recv() => {
                    let Some(Outbound { epoch, key, line }) = line else { break Ok(LinkEnd::Stopped) };
                    // Admitted on a link that went down: its caller was failed
                    // with that link, so it never goes out on this one.
                    if epoch != self.link_epoch() {
                        continue;
                    }
                    // Before the frame is marked: a link a wake check drops never had it.
                    check_wake!();
                    // Marked before the write: a frame that is partly written may still run.
                    let prompt_key = key.as_ref();
                    if let Some(key) = prompt_key {
                        self.on_wire.lock_or_recover().insert(key.clone());
                    }
                    let text = line.trim_end_matches('\n').to_owned();
                    // While this path is in doubt the frame goes on another path too.
                    let text = self.dual_copy(text, prompt_key.map(String::as_str), link);
                    let until = write_deadline(tokio::time::Instant::now(), budget, wake_probe);
                    match tokio::time::timeout_at(until, sink.send(Frame::Text(text.into()))).await {
                        Ok(Ok(())) => {
                            // Once the prompt frame reaches the socket, the remote may have
                            // accepted it even if its acceptance notification is still queued
                            // behind the frame that caused this link to drop. Retain it for the
                            // durable outcome lookup across reconnects.
                            if let Some(key) = prompt_key
                                && let Some(prompt) = self.prompts.lock_or_recover().get_mut(key)
                            {
                                prompt.accepted = true;
                            }
                        }
                        Ok(Err(e)) => break Err(e.to_string()),
                        Err(_) => break Err(write_late(budget, wake_probe)),
                    }
                }
            }
        };
        handshake.abort();
        result
    }
}

/// Whether GitHub may be lent over a link to `url`: ssh (what Add Machine saves) or TLS, or a
/// plain WebSocket only on this machine's loopback. Over plain `ws://` to another host the
/// handshake that makes a link a peer could come from anything on the path.
fn lends_over(url: &str) -> bool {
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
const REATTACHES_AT_ONCE: usize = 16;

/// How long a link waits before each attach it tries again after one failed on it
/// ([`Peer::retry_attach`]): about a minute in all, then the chat waits for the next link.
const ATTACH_RETRY_AFTER: [Duration; 6] = [
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
fn replayable(cursors: &HashMap<String, u64>, baselined: &HashSet<String>) -> Vec<(String, u64)> {
    cursors
        .iter()
        .filter(|(sid, c)| **c > 0 || baselined.contains(*sid))
        .map(|(sid, c)| (sid.clone(), *c))
        .collect()
}

/// The greatest event sequence an `_acpmux/attach` page holds, if it holds any.
fn page_max_seq(page: &Value) -> Option<u64> {
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
fn list_position(reply: &Value) -> Option<(String, u64)> {
    let epoch = reply.get("listEpoch").and_then(Value::as_str)?;
    Some((epoch.to_owned(), reply.get("listSeq").and_then(Value::as_u64)?))
}

/// The peer's own ids of the rows a follow says went, without the rows it mirrors.
fn gone_ids(reply: &Value) -> Vec<String> {
    let gone = reply.get("gone").and_then(Value::as_array).into_iter().flatten();
    gone.filter(|row| row.get("peer").is_none_or(Value::is_null))
        .filter_map(|row| row.get("sessionId").and_then(Value::as_str).map(str::to_owned))
        .collect()
}

/// The sessions an `_acpmux/watch` reply lists, without the rows the peer itself mirrors, each
/// as its text: no row is copied as a `Value`.
fn watch_sessions(reply: &Value) -> Vec<Arc<str>> {
    reply
        .get("sessions")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|session| session.is_object() && !is_mirrored_session(session))
        .map(row_text)
        .collect()
}

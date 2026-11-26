//! Peer requests and notifications, and the requests and prompts a link that ended leaves
//! behind: failed, replayed or recovered on the next link.

use super::*;

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
            // `data.reason` names the wait past its deadline for the callers that sort the
            // failure by kind (`attach_failure_class`); the message is unchanged.
            Err(_) => Err(RpcError::internal(format!(
                "peer {} timed out after {}s",
                self.name,
                started.elapsed().as_secs()
            ))
            .with_data(json!({"reason": "deadline_exceeded", "peer": self.name}))),
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
                    let class = attach_failure_class(&e);
                    tracing::warn!(peer = %self.name, session = %sid, refused, class = %class, "the peer's chat was not replayed: {}", e.message);
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
                    self.received.add_replay(serde_json::to_string(event).map_or(0, |t| t.len()));
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
}

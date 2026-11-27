//! Peer link-loop operations; requests and notifications are in `peer_runtime_requests.rs`.

use super::*;

tokio::task_local! {
    /// Set while a link that heard nothing for this long dials its replacement
    /// (`dial_replacement!`): the hub dial then skips a kept circuit just as silent
    /// (`HubCarrier::dial_past_silent`, `peer_hub.rs`). `open_first` races its paths in this
    /// task, so the hub dial sees it.
    pub(super) static REPLACING_SILENT: Duration;
}

impl Peer {
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
            && !self.idle_parked()
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
        // A peer nothing uses waits here instead of dialing (`peer_demand.rs`).
        while !self.stop.load(Ordering::SeqCst) && self.await_demand().await {
            crate::gauges::bump(&crate::gauges::links().link_dials);
            if immediate_redial {
                crate::gauges::bump(&crate::gauges::links().link_redials);
            }
            let outcome = self.connect_once(&mut out_rx).await;
            let restarting =
                matches!(&outcome, Ok(LinkEnd::Restarting | LinkEnd::Switching | LinkEnd::Idle));
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
        if matches!(&outcome, Ok(LinkEnd::Idle)) {
            return self.idle_ended();
        }
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

    /// One link: dial this peer's paths (`peer_carriers.rs`), the one that carried it last
    /// first and each other one `STAGGER` later, and serve the first that opens until it ends.
    pub(super) async fn connect_once(
        self: &Arc<Self>,
        out_rx: &mut mpsc::Receiver<Outbound>,
    ) -> Result<LinkEnd, String> {
        use crate::peer_paths::Via;
        self.facts.lock_or_recover().refused = false;
        self.login_refused.store(false, Ordering::SeqCst);
        #[cfg(test)]
        if test_dial::refused() {
            if test_dial::login_refused() {
                let reason =
                    ssh_errors::reason(b"leo@box: Permission denied (publickey,password).");
                self.note_ssh_failure(reason);
                return Err(ssh_errors::describe("ssh to box failed (test)".into(), reason));
            }
            return Err("refused (test)".into());
        }
        // One host-wide gate for every peer's dial (`peer_dial_gate.rs`): a link dropping on its
        // own dials at once; 40 dropping together go a few at a time, wanted peers first.
        // A replacement the last link dialed while it sat silent opened first: no dial.
        let replaced = self.replacement.lock_or_recover().take();
        let first = if let Some(replaced) = replaced {
            Ok(replaced)
        } else {
            let mut stopped = self.stop_changed.subscribe();
            let gate = crate::peer_dial_gate::global();
            let dial = gate.pass(self.is_wanted(), crate::peer_link::jitter(), self.open_first());
            tokio::select! {
                biased;
                _ = stopped.wait_for(|stopped| *stopped) => return Err("peer stopped".to_owned()),
                first = dial => first,
            }
        };
        let (via, opened) = match first {
            Ok(opened) => opened,
            Err(error) => {
                // No path opened: the network, not a slow peer (`SilenceBudget::dial_struggled`).
                self.with_silence(SilenceBudget::dial_struggled);
                return Err(error);
            }
        };
        // A losing ssh attempt's process ends now.
        if via != Via::Ssh {
            self.end_tunnel().await;
        }
        *self.presented.lock().unwrap_or_else(|e| e.into_inner()) = opened.presented;
        *self.early_init.lock_or_recover() = None;
        if let Some(id) = opened.early_id {
            self.adopt_early_initialize(id).await;
        }
        self.carried_by(via.carrier().wire());
        // Held while this link's connection is: `gauges.links.linksOpen`.
        let _open = crate::gauges::Held::on(&crate::gauges::links().links_open);
        self.set_serving(Some(via));
        self.start_probes();
        // The transport's reads, also after the link ends: how long it heard nothing.
        #[cfg(feature = "hub-carrier")]
        let link_heard = opened.heard.clone();
        *self.link_read.lock().unwrap_or_else(std::sync::PoisonError::into_inner) =
            opened.heard.read().clone();
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
                // A hub link that went silent leaves no dead kept circuit for its redial to
                // wait `ANSWER_SUSPECT` on (`HubCarrier::close_kept_silent_for`).
                #[cfg(feature = "hub-carrier")]
                if via == Via::Hub {
                    self.hub_link_ended_silent(link_heard.silent()).await;
                }
                self.path_failed(via);
                if self.another_path_alive(via) && self.link().is_ready() {
                    self.went_down(Some(crate::protocol::peer_state::DialFail::PathChanged));
                    tracing::info!(peer = %self.name, via = via.as_str(), "the link's path failed ({error}); moving to another path");
                    return Ok(LinkEnd::Switching);
                }
                Err(error)
            }
            end => end,
        }
    }

    /// A link silent past its budget dials a replacement before it drops (`serve_heard`): one with
    /// no other path up (with one, it moves there at once), and not over ssh, whose dial starts a
    /// process. Ready or still in its handshake alike: `serve` clears ready on every open, and a
    /// handshake stuck behind a blackout is the same silence.
    fn may_replace(&self) -> bool {
        use crate::peer_paths::Via;
        self.serving().is_some_and(|via| via != Via::Ssh && !self.another_path_alive(via))
    }

    pub(super) fn ws_request(
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
    pub(super) async fn serve<S>(
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
    pub(super) async fn serve_heard<S>(
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
        let mut handshake = self.scope.spawn_named("peer-handshake", async move {
            let hello = me.initialize_hello();
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
            let channels = init
                .pointer("/_meta/acpmux/capabilities")
                .and_then(Value::as_array)
                .is_some_and(|ids| {
                    ids.iter().any(|id| id.as_str() == Some(crate::server::channels::CAPABILITY))
                });
            me.agent_channels.store(channels, Ordering::SeqCst);
            let follows =
                init.pointer("/_meta/acpmux/capabilities").and_then(Value::as_array).is_some_and(
                    |ids| ids.iter().any(|id| id.as_str() == Some(crate::hub::row_log::CAPABILITY)),
                );
            me.list_follow.store(follows, Ordering::SeqCst);
            // Every link in this cut asks for the legacy watch at handshake time. Cut E clears
            // this for a watchless link after feature negotiation.
            me.set_watch_active(true);
            let kept = me.keep_pipelined(pipelined.as_ref(), build.as_ref());
            let _ = kept_tx.send(kept);
            // The reader publishes the list (`watch_key`) once it is whole, then `Listed`. A
            // link reads it before it is ready, so Connected follows it; one after a far restart
            // or a path switch is ready first and reads it beside the steps after Connected,
            // while the hub keeps the last whole list (`lists_after_ready`). An error reading it
            // ends the link.
            let list = async {
                let sent = if kept {
                    sent.as_mut().await;
                    sent.as_mut().take_output().flatten()
                } else {
                    None
                };
                me.read_list(link, build.as_ref(), sent).await
            };
            let mut list = std::pin::pin!(list);
            let after_ready = me.lists_after_ready();
            if !after_ready {
                list.as_mut().await?;
            }
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
            let mut down_ms = None;
            let live = me.with_link(|l| {
                let live = me.link_epoch() == link;
                if live {
                    me.connected.store(true, Ordering::SeqCst);
                    me.linked_once.store(true, Ordering::SeqCst);
                    me.slow_banner.store(false, Ordering::SeqCst);
                    let now = crate::store::now_ms();
                    // The outage this link ends, drop to ready (none on a first connect).
                    down_ms = l.down_since.map(|at| now.saturating_sub(at));
                    l.ready(now);
                }
                live
            });
            if !live || me.link_epoch() != link {
                me.connected.store(false, Ordering::SeqCst);
                return Ok(());
            }
            let (frames, text) = me.received.read();
            // `down_ms`: the outage, drop to ready. `reconnect_ms`: from the sleep or network
            // change that sent the attempt (`reconnect_cause`) to ready. Both absent when unknown.
            let took = me.reconnect_took();
            tracing::info!(
                peer = %me.name,
                frame_bytes = frames,
                text_bytes = text,
                down_ms,
                reconnect_ms = took.map(|(d, _)| d.as_millis() as u64),
                reconnect_cause = took.map(|(_, c)| c),
                "connected to {}",
                lift_query_token(&me.url).0
            );
            let _ = me.notices.send((me.name.clone(), me.generation, PeerNotice::Connected)).await;
            let steps = async {
                // The peer's list stream feeds the index from here, when it lists one.
                me.start_mirror(link);
                // The watch is asked before either starts; controls stay state-only until cut E.
                me.start_controls(link);
                // The path it is ready on is the one to dial first next time, also after a
                // restart.
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
                // Each starts its stream anew at the peer's present, so what the peer sent since
                // the last link is a hole: its clients are told they lagged, and read it
                // themselves.
                let (peer, epoch) = (&me, link);
                futures::stream::iter(attached.iter())
                    .for_each_concurrent(REATTACHES_AT_ONCE, |sid| async move {
                        if peer.attach_hidden(sid).await.is_ok() && peer.link_epoch() == epoch {
                            peer.tell_reattached(sid, epoch).await;
                        }
                    })
                    .await;
                me.refresh_health();
            };
            if after_ready {
                let (listed, ()) = futures::join!(list, steps);
                listed?;
            } else {
                steps.await;
            }
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
        if silence > was {
            tracing::info!(peer = %self.name, "silence budget {}s (was {}s; a link dropped for silence opened again: the peer is slow, not gone)", silence.as_secs(), was.as_secs());
        } else if silence < was {
            tracing::info!(peer = %self.name, "silence budget {}s (was {}s; the redial failed first: the network was gone, not the peer slow)", silence.as_secs(), was.as_secs());
        }
        // The first read's gap is the connect, not an answer.
        if let Some(heard) = &heard {
            heard.take_gap();
        }
        let mut frame_gap = Duration::ZERO;
        let budget = timings.send;
        let wrote = heard.as_ref().map(Heard::wrote);
        let mut ping = tokio::time::interval_at(
            tokio::time::Instant::now() + timings.ping_every,
            timings.ping_every,
        );
        ping.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        let mut last_frame = tokio::time::Instant::now();
        // When the silence budget runs out if nothing comes before then, set by a ping tick that
        // finds less than a ping interval of it left. Checked then, not on the next tick: a dead
        // link is dropped at its budget, not up to `ping_every` after it (a 5G/LTE handoff took
        // 7.5 s to notice of a 6 s budget, about 8 of its 8 s direct handoff).
        let mut silence_due: Option<tokio::time::Instant> = None;
        // A link dialed when this one sat silent past its budget with no other path up, while
        // this one keeps reading. TCP holds a blackout's bytes on its retransmission ladder: a
        // ping sent in the first second of a 4 s blackout lands 6.2 s after it began (200 ms,
        // doubling), past a 6 s budget counted from the last frame before it, and every byte
        // after it waits behind it. Dropping then cost a backoff and a whole handshake. Whichever
        // answers first wins: a frame here drops the dial, the dial opening first moves the link
        // to it (`LinkEnd::Switching`, no outage). The link drops as before when the dial fails,
        // or at twice the budget.
        //
        // A frame is not an answer: the first frames after a blackout are the backlog the peer
        // wrote into it, and everything sent after them (the content the person waits for) sits
        // behind them on that ladder. At duress (a chat streaming 20 chunks each 250 ms, a 5 s
        // blackout) the first one came 1.2 s after the blackout, the content B sent at its end
        // 3.0 s (direct) to 3.9 s (relay) after it, while a replacement opened and replayed by
        // 1.3 s (job ce049556). So only a pong for a ping sent after the dial began drops it:
        // the peer wrote that pong after everything before it, so the link is current again.
        // On the std clock: a ping's stamp (`carriers::ping_stamp`) is, and its pong carries it.
        let mut replacing_since: Option<std::time::Instant> = None;
        // A frame came on this link while its replacement dialed: a dial that fails then keeps it.
        let mut heard_while_replacing = false;
        let mut replacing: Option<
            std::pin::Pin<
                Box<
                    dyn std::future::Future<
                            Output = Result<(crate::peer_paths::Via, carriers::Opened), String>,
                        > + Send
                        + '_,
                >,
            >,
        > = None;
        // Dial a replacement for a link silent `$silent` while it still reads. The hub dial in it
        // skips a kept circuit as silent (`REPLACING_SILENT`): that circuit is the stalled one.
        macro_rules! dial_replacement {
            ($silent:expr, $why:expr) => {{
                let silent: Duration = $silent;
                tracing::info!(peer = %self.name, "silent {}ms, {}; dialing a replacement while this link still reads", silent.as_millis(), $why);
                let gate = crate::peer_dial_gate::global();
                replacing = Some(Box::pin(gate.pass(self.is_wanted(), crate::peer_link::jitter(), REPLACING_SILENT.scope(silent, self.open_first()))));
                replacing_since = Some(std::time::Instant::now());
                heard_while_replacing = false;
            }};
        }
        // `replace_after` (off by default) passed, the budget not yet: dial the replacement now;
        // the budget still decides the drop.
        macro_rules! replace_early {
            ($silent:expr, $silence:expr, $now:expr) => {{
                let (silent, silence, now): (Duration, Duration, tokio::time::Instant) =
                    ($silent, $silence, $now);
                if replacing.is_none() && self.may_replace() {
                    dial_replacement!(
                        silent,
                        format!(
                            "past its {}ms replace setting",
                            timings.replace_at(silence).as_millis()
                        )
                    );
                }
                silence_due = Some(now + silence.saturating_sub(silent));
            }};
        }
        // The budget ran out (`$silent`, measured as the drop rule measures it): drop the link, or
        // keep it while a replacement dials.
        macro_rules! out_of_silence {
            ($silent:expr, $silence:expr, $now:expr) => {{
                let (silent, silence, now): (Duration, Duration, tokio::time::Instant) =
                    ($silent, $silence, $now);
                let cap = silence.saturating_mul(2);
                if replacing.is_none() && silent < cap && self.may_replace() {
                    dial_replacement!(silent, format!("past its {}s budget", silence.as_secs()));
                }
                if replacing.is_some() && silent < cap {
                    silence_due = Some(now + (cap - silent));
                } else {
                    self.with_silence(|b| b.dropped(now));
                    break Err(self.deadline_passed(format!(
                        "peer stopped answering ({}s without a frame)",
                        silent.as_secs()
                    )));
                }
            }};
        }
        // Time this daemon kept the loop from reading is not the peer's silence (`ReaderHeld`).
        let mut reader = crate::peer_link::ReaderHeld::default();
        let mut stale_settled = false;
        let mut handshake_ended = false;
        let mut health_asked: Option<tokio::time::Instant> = None;
        // Holds until the link is ready and its list is in (`listed`), also a list read after
        // ready. Moved on by each page of a list read in pages, with no cap in all: a peer that
        // paces its lists still links however long the list, one that stops answering for a
        // whole `timings.handshake` does not hold it.
        let handshake_started = tokio::time::Instant::now();
        let handshake_deadline = tokio::time::sleep(timings.handshake);
        tokio::pin!(handshake_deadline);
        // After this computer slept, the link's monotonic timers say its last frame came moments
        // ago, while its ssh tunnel has often died: a ping goes out at once, and the link is
        // dropped (and redialed) when nothing answers within `peer_link::wake_probe` (2 s; 30 s
        // for a peer that proved slow), rather than after the ssh keepalive or the whole silence
        // budget. Stops with the link.
        let mut wake_watch = SleepWatch::now();
        let mut wake_check = tokio::time::interval_at(
            tokio::time::Instant::now() + SleepWatch::EVERY,
            SleepWatch::EVERY,
        );
        wake_check.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        let mut wake_probe: Option<tokio::time::Instant> = None;
        // Why `wake_probe` is set when a network change set it, not a wake.
        let mut probe_cause: Option<String> = None;
        // `wake_probe` was set by a request sent on a link already silent a ping interval: a link
        // it drops tells the budget (`SilenceBudget::probe_dropped`).
        let mut request_probe = false;
        // When the oldest stamped ping still without its pong went out: its pong measures how
        // late the peer answers (`SilenceBudget::answered_in`). A peer that answers only its
        // latest ping makes this the time it stayed silent, which is what the probe must wait.
        let mut ping_out: Option<tokio::time::Instant> = None;
        // The clocks are read before every write too, not only on `wake_check`'s tick: after a wake
        // the regular ping's tick may be served first, and its write must be held to the probe's
        // deadline, never the whole send budget.
        macro_rules! check_wake {
            () => {
                if let Some(slept) = wake_watch.check() {
                    tracing::info!(peer = %self.name, "this computer slept {}s; checking the link", slept.as_secs());
                    // One deadline for the ping to go out and its answer to come back: 2 s, or
                    // `WAKE_PROBE` for a peer that proved slow (`peer_link::wake_probe`).
                    let short = self.with_silence(|b| b.may_probe());
                    let probe = crate::peer_link::wake_probe(short, network::NETWORK_PROBE);
                    let deadline = tokio::time::Instant::now() + probe;
                    match tokio::time::timeout_at(deadline, sink.send(Frame::Ping(Vec::new().into()))).await {
                        // A short probe that drops the link tells the budget, as a request's does:
                        // if the link reopens at once the peer was slow, and its next wake gets
                        // the long bound. It also waits on while bytes still arrive.
                        Ok(Ok(())) => {
                            wake_probe = Some(deadline);
                            request_probe = short;
                            probe_cause = Some(format!("no answer {}s after this computer woke", probe.as_secs()));
                        }
                        Ok(Err(e)) => break Err(e.to_string()),
                        Err(_) => break Err(self.deadline_passed(stopped_reading(probe))),
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
        // Each chat's last row this link heard, which the peer's patches apply to
        // (`peer_row_patch.rs`): the peer forgets what it sent at each `initialize`, so this does too.
        let mut held_rows = crate::peer_row_patch::HeldRows::default();
        // A reply to this daemon's request: a watch list's (`watch_key`) is published here, before
        // the next frame is read.
        macro_rules! watch_reply {
            ($key:expr, $reply:expr, $tx:expr) => {{
                let (key, reply, tx): (
                    String,
                    Result<Value, RpcError>,
                    oneshot::Sender<Result<Value, RpcError>>,
                ) = ($key, $reply, $tx);
                self.controls_reply(link, &key, &reply);
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
                            let until = tokio::time::Instant::now() + timings.handshake;
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
                            if let Some(bytes) = list.list_bytes() {
                                crate::gauges::peer_lists().queued(bytes);
                            }
                            // `Listed` last: the hub takes this link's list as applied with it.
                            self.listed_links.lock_or_recover().push_back(link);
                            self.whole_list.store(true, Ordering::SeqCst);
                            let notices = std::iter::once(list).chain(held);
                            for notice in notices.chain([PeerNotice::Listed]) {
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
                        match write_within(sink.send(refusal), budget, None, wrote).await.ok_or(()) {
                            Ok(Ok(())) => {}
                            Ok(Err(e)) => break $link Err(e.to_string()),
                            Err(_) => break $link Err(self.deadline_passed(stopped_reading(budget))),
                        }
                    }
                }
            }};
        }
        let result = 'link: loop {
            if self.stop.load(Ordering::SeqCst) {
                break Ok(LinkEnd::Stopped);
            }
            if let Some(held) = reader.resume()
                && held >= timings.ping_every
            {
                tracing::info!(peer = %self.name, "this daemon kept the link from reading for {}ms; its silence counts from now", held.as_millis());
            }
            tokio::select! {
                _ = self.stop_signal.notified() => break Ok(LinkEnd::Stopped),
                _ = wake_check.tick() => check_wake!(),
                _ = tokio::time::sleep_until(wake_probe.unwrap_or_else(tokio::time::Instant::now)), if wake_probe.is_some() => {
                    let now = tokio::time::Instant::now();
                    let wait = self.with_silence(|b| b.probe_wait(network::NETWORK_PROBE));
                    // A request's probe on a link still reading bytes (a large frame on its way, the
                    // pong queued behind it) is moving: wait another probe, not drop it.
                    if request_probe && heard.as_ref().is_some_and(|h| h.silent() < wait) {
                        wake_probe = Some(now + wait);
                        continue;
                    }
                    // This loop ran late (`stalled`): this computer, not the peer, was stuck, and
                    // the answer may wait unread. Read first; the next probe that runs on time
                    // decides.
                    if request_probe && wake_probe.is_some_and(|due| stalled(now, due)) {
                        tracing::debug!(peer = %self.name, "the link's loop ran {}ms late; its probe waits again", now.saturating_duration_since(wake_probe.unwrap_or(now)).as_millis());
                        wake_probe = Some(now + wait);
                        continue;
                    }
                    // This daemon did not read for part of the probe's wait: the answer may be
                    // in, unread. The probe waits its whole time from when reading resumed.
                    if reader.reading() < network::NETWORK_PROBE {
                        wake_probe = Some(tokio::time::Instant::now() + network::NETWORK_PROBE - reader.reading());
                        continue;
                    }
                    if request_probe {
                        self.with_silence(SilenceBudget::probe_dropped);
                    }
                    break Err(self.deadline_passed(match probe_cause {
                        Some(why) => why,
                        None => format!("no answer {}s after this computer woke", WAKE_PROBE.as_secs()),
                    }));
                }
                // This computer's network changed (`peer_network.rs`): the link may ride a route that
                // is gone. A ping goes out at once and the link is dropped and redialed when nothing
                // answers within `NETWORK_PROBE`, not after the whole silence budget.
                () = self.network_changed() => {
                    let deadline = tokio::time::Instant::now() + network::NETWORK_PROBE;
                    if wake_probe.is_none_or(|probe| probe > deadline) {
                        tracing::info!(peer = %self.name, "this computer's network changed; checking the link");
                        match tokio::time::timeout_at(deadline, sink.send(Frame::Ping(Vec::new().into()))).await {
                            Ok(Ok(())) => {
                                wake_probe = Some(deadline);
                                request_probe = false;
                                probe_cause = Some(format!(
                                    "no answer {}s after this computer's network changed",
                                    network::NETWORK_PROBE.as_secs()
                                ));
                            }
                            Ok(Err(e)) => break Err(e.to_string()),
                            Err(_) => break Err(self.deadline_passed(stopped_reading(network::NETWORK_PROBE))),
                        }
                    }
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
                _ = &mut handshake_deadline, if !self.link().is_ready() || !listed => {
                    break Err(self.deadline_passed(timed_out(handshake_started)));
                }
                // The silence budget ran out between two ping ticks (`silence_due`). The same rule
                // as the tick's: a frame since then, or time this daemon did not read, keeps it.
                _ = tokio::time::sleep_until(silence_due.unwrap_or_else(tokio::time::Instant::now)), if silence_due.is_some() => {
                    let now = tokio::time::Instant::now();
                    let late = now.saturating_duration_since(silence_due.take().unwrap_or(now));
                    let silence = self.with_silence(|b| b.current());
                    let silent = heard.as_ref().map_or(last_frame.elapsed(), |h| h.silent().min(last_frame.elapsed())).min(reader.reading());
                    if silent.saturating_sub(late) >= silence {
                        out_of_silence!(silent, silence, now);
                    } else if silent.saturating_sub(late) >= timings.replace_at(silence) {
                        replace_early!(silent, silence, now);
                    }
                }
                // The replacement dialed for a silent link (`replacing`) opened first.
                opened = pending_or(&mut replacing) => {
                    match opened {
                        Ok(opened) => {
                            tracing::info!(peer = %self.name, via = opened.0.as_str(), "a replacement opened while the link sat silent; moving the link to it");
                            *self.replacement.lock_or_recover() = Some(opened);
                            break Ok(LinkEnd::Switching);
                        }
                        Err(e) if heard_while_replacing => {
                            tracing::info!(peer = %self.name, "a replacement did not open ({e}); the link answers again, so it stays");
                            replacing = None;
                            replacing_since = None;
                            silence_due = None;
                        }
                        Err(e) => {
                            let now = tokio::time::Instant::now();
                            self.with_silence(|b| b.dropped(now));
                            break Err(self.deadline_passed(format!("peer stopped answering, and a replacement did not open ({e})")));
                        }
                    }
                }
                due = ping.tick() => {
                    self.paths_tick();
                    // Unused for `IDLE_CLOSE_AFTER`: it closes, and the next use dials again.
                    if self.link().is_ready() && listed && self.idle_due() {
                        break Ok(LinkEnd::Idle);
                    }
                    // The selector moved the session to a faster path: the link moves while no
                    // request is out on it, and its list is in (one read after ready has no
                    // request out between its pages).
                    if self.link().is_ready() && listed && self.switch_due() {
                        break Ok(LinkEnd::Switching);
                    }
                    let now = tokio::time::Instant::now();
                    // A gap this daemon made by not reading teaches the budget nothing.
                    let gap = heard.as_ref().map_or_else(|| std::mem::take(&mut frame_gap), Heard::take_gap).min(reader.reading());
                    let (was, silence) = self.with_silence(|b| {
                        let was = b.current();
                        b.answered_after(gap, now);
                        b.settle(now);
                        (was, b.current())
                    });
                    if silence != was {
                        tracing::info!(peer = %self.name, "silence budget {}s (was {}s; longest wait for an answer {}ms)", silence.as_secs(), was.as_secs(), gap.as_millis());
                    }
                    let silent = heard.as_ref().map_or(last_frame.elapsed(), |h| h.silent().min(last_frame.elapsed())).min(reader.reading());
                    // The time this tick came late, this loop stuck (a loaded Mac, a write or a
                    // full notice queue), was no read of the peer: not its silence. Bytes it sent
                    // meanwhile wait unread. cosmic-gray at load 100 dropped 493 links in 3 h for
                    // 6 to 19 s of such "silence".
                    let late = now.saturating_duration_since(due);
                    if silent.saturating_sub(late) >= silence {
                        out_of_silence!(silent, silence, now);
                    } else if replacing.is_none() && silent.saturating_sub(late) >= timings.replace_at(silence) {
                        replace_early!(silent, silence, now);
                    } else {
                        // The next deadline: the replace setting's while no replacement dials,
                        // else the budget's.
                        let due_at = if replacing.is_none() { timings.replace_at(silence) } else { silence };
                        let left = due_at.saturating_sub(silent.saturating_sub(late));
                        silence_due = (left < timings.ping_every).then(|| now + left);
                    }
                    if silent >= timings.ping_every {
                        self.with_link(Link::overdue);
                    }
                    check_wake!();
                    // Stamped, so its pong measures this path's round trip (`peer_paths.rs`).
                    match write_within(sink.send(Frame::Ping(carriers::ping_stamp().into())), budget, wake_probe, wrote).await.ok_or(()) {
                        Ok(Ok(())) => {
                            ping_out.get_or_insert_with(tokio::time::Instant::now);
                        }
                        Ok(Err(e)) => break Err(e.to_string()),
                        Err(_) => break Err(self.deadline_passed(write_late(budget, wake_probe))),
                    }
                    let now = tokio::time::Instant::now();
                    if self.link().is_ready() && health::health_due(health_asked, now) {
                        health_asked = Some(now);
                        self.refresh_health();
                    }
                }
                frame = reader.listen(source.next()) => {
                    let Some(frame) = frame else { break Err("peer closed the connection".to_owned()) };
                    let frame = match frame { Ok(f) => f, Err(e) => break Err(e.to_string()) };
                    // `select!` is unbiased: a frame read as the deadline passes may not finish
                    // the handshake (or move the deadline on past its cap).
                    if (!self.link().is_ready() || !listed) && handshake_deadline.is_elapsed() {
                        break Err(self.deadline_passed(timed_out(handshake_started)));
                    }
                    frame_gap = frame_gap.max(last_frame.elapsed());
                    last_frame = tokio::time::Instant::now();
                    heard_while_replacing |= replacing.is_some();
                    wake_probe = None;
                    request_probe = false;
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
                            let rtt = carriers::pong_rtt(&payload);
                            if let (Some(rtt), Some(via)) = (rtt, self.serving()) {
                                self.path_pong(via, rtt);
                            }
                            // Measured on this loop's clock, from the ping's send to its pong's
                            // read: what the probe and the budget must wait for.
                            if rtt.is_some() && let Some(at) = ping_out.take() {
                                let now = tokio::time::Instant::now();
                                self.with_silence(|b| b.answered_in(now.saturating_duration_since(at), now));
                            }
                            if let (Some(rtt), Some(since)) = (rtt, replacing_since)
                                && rtt <= since.elapsed()
                                && replacing.take().is_some()
                            {
                                tracing::info!(peer = %self.name, "the silent link answered a ping sent after its replacement dial began; the dial is dropped");
                                replacing_since = None;
                                silence_due = None;
                            }
                            continue;
                        }
                        _ => continue,
                    };
                    // A v2 frame of the peer's list stream goes to this link's mirror.
                    if crate::link_v2::is_frame_line(&text) {
                        self.received.add_kind("list", text.len());
                        self.mirror_frame(link, text);
                        continue;
                    }
                    let msg = match Message::parse(&text) {
                        Ok(msg) => msg,
                        // Only large messages are compressed, and a reply among them would be
                        // lost while its caller waits: the link starts over, as for a frame
                        // that does not inflate.
                        Err(e) if compressed => break Err(format!("a compressed frame is not a JSON-RPC message: {e}")),
                        Err(_) => continue,
                    };
                    self.received.add_kind(match &msg {
                        Message::Notification { method, .. } => method.as_str(),
                        Message::Response { .. } => "reply",
                        Message::Request { .. } => "request",
                    }, text.len());
                    // A large row patch, by the fields it carries (three levels): which part of a
                    // row a backed-up link spends its bytes on. Small patches are not walked.
                    if text.len() > 4096
                        && let Message::Notification { method: m, params: Some(p) } = &msg
                        && m == method::MUX_SESSION_PATCH
                    {
                        self.received.add_patch_fields(&p["patch"]);
                    }
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
                        Message::Notification { method: mut m, params } => {
                            let mut p = params.unwrap_or(Value::Null);
                            // A patch of a row this link holds is that row whole again, as the
                            // `session_changed` the hub reads; one that does not apply asks for
                            // the row whole (`peer_row_patch.rs`).
                            match held_rows.read(&m, &mut p, text.len()) {
                                crate::peer_row_patch::Read::Pass => {}
                                crate::peer_row_patch::Read::Changed => {
                                    m = method::MUX_SESSION_CHANGED.to_owned();
                                }
                                crate::peer_row_patch::Read::Drop(ask) => {
                                    if let Some(id) = ask {
                                        self.resync_row(link, id);
                                    }
                                    continue;
                                }
                            }
                            self.note_link_activity(&m);
                            if m == crate::server::controls::NOTICE {
                                if let Err(error) = self.controls_notice(link, p).await {
                                    tracing::warn!(peer = %self.name, error = %error.message, "controls stream ended; keeping link up");
                                    self.stop_controls(link);
                                    self.start_controls(link);
                                }
                                continue;
                            }
                            if matches!(m.as_str(), method::MUX_EVENT | method::SESSION_UPDATE) {
                                let mut highwater = self.replay_highwater.lock_or_recover();
                                let id = p.get("sessionId").and_then(Value::as_str);
                                let seq = p.get("seq").and_then(Value::as_u64)
                                    .or_else(|| p.pointer("/_meta/acpmux/seq").and_then(Value::as_u64));
                                if let (Some(id), Some(seq)) = (id, seq)
                                    && let Some(high) = highwater.get_mut(id)
                                {
                                    *high = (*high).max(seq);
                                    self.received.add_gated(text.len());
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
                                // Taken, not copied: nothing below reads it from `p`.
                                let session = p.get_mut("session").map(Value::take).unwrap_or(Value::Null);
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
                            match write_within(sink.send(refusal), budget, None, wrote).await.ok_or(()) {
                                Ok(Ok(())) => {}
                                Ok(Err(e)) => break Err(e.to_string()),
                                Err(_) => break Err(self.deadline_passed(stopped_reading(budget))),
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
                    // Read before the write: a large frame's write is not the peer's silence.
                    let silent = heard.as_ref().map_or(last_frame.elapsed(), |h| h.silent().min(last_frame.elapsed())).min(reader.reading());
                    // Marked before the write: a frame that is partly written may still run.
                    let prompt_key = key.as_ref();
                    if let Some(key) = prompt_key {
                        self.on_wire.lock_or_recover().insert(key.clone());
                    }
                    let text = line.trim_end_matches('\n').to_owned();
                    // While this path is in doubt the frame goes on another path too.
                    let text = self.dual_copy(text, prompt_key.map(String::as_str), link);
                    // A large frame on a slow uplink keeps going while its bytes move
                    // (`write_within`): only `budget` with no byte taken drops the link.
                    match write_within(sink.send(Frame::Text(text.into())), budget, wake_probe, wrote).await.ok_or(()) {
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
                        Err(_) => break Err(self.deadline_passed(write_late(budget, wake_probe))),
                    }
                    // A request on a link silent for a ping interval: a network gone without a
                    // reset takes the write into the kernel's buffer and answers nothing. A ping
                    // goes out with it and the link is dropped and redialed when nothing answers
                    // within `NETWORK_PROBE`, not after the whole silence budget. Not for a peer
                    // that proved slow (`SilenceBudget::may_probe`).
                    // It waits what this peer's measured round trip needs (`SilenceBudget::probe_wait`):
                    // 2 s at first and for a fast peer, longer for one that answers late.
                    let wait = self.with_silence(|b| b.probe_wait(network::NETWORK_PROBE));
                    if wake_probe.is_none() && silent >= timings.ping_every.max(wait) && self.with_silence(|b| b.may_probe()) {
                        let deadline = tokio::time::Instant::now() + wait;
                        match tokio::time::timeout_at(deadline, sink.send(Frame::Ping(Vec::new().into()))).await {
                            Ok(Ok(())) => {
                                wake_probe = Some(deadline);
                                request_probe = true;
                                probe_cause = Some(format!(
                                    "no answer {}s after a request on a link silent {}s",
                                    wait.as_secs(),
                                    silent.as_secs()
                                ));
                            }
                            Ok(Err(e)) => break Err(e.to_string()),
                            Err(_) => {
                                self.with_silence(SilenceBudget::probe_dropped);
                                break Err(self.deadline_passed(stopped_reading(wait)));
                            }
                        }
                    }
                }
            }
        };
        handshake.abort();
        self.stop_controls(link);
        result
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

//! A chat's inbound side: the loop that drains its agents' notifications and requests, and
//! `on_update`, which applies a `session/update` to the chat. Moved out of `permissions.rs`.

use super::*;

impl Hub {
    // ------------------------------------------------------------- inbound

    /// The chat's inbound loop, spawned once per start in the hub's scope (`spawn_inbound_loop`):
    /// it ends when the hub closes, or once the chat is closed and its producers are done: nothing
    /// queued, and no agent (or its reader) still holds a sender, so a late `Exited` and the last
    /// updates of an agent a close killed are still handled (#41081 F1). Then it hands the
    /// receiver back, so the start that reopens the chat starts it again; a chat reopened before
    /// the hand-back keeps this loop.
    pub(crate) async fn inbound_loop(
        self: Arc<Self>,
        session: Arc<Session>,
        mut rx: mpsc::Receiver<Inbound>,
    ) {
        let stop = self.scope.token();
        // Its current value counts: a loop that first runs after the close sees it (#41081 F2).
        let mut closed = session.closed.subscribe();
        // Between items the loop holds the chat weakly: an idle chat may leave memory
        // (`evict.rs`), and its own sender goes with it, which ends `rx` and this loop.
        let weak = Arc::downgrade(&session);
        let own = session.inbound_tx().downgrade();
        drop(session);
        loop {
            self.clone().inbound_items(&weak, &own, &mut rx, &stop, &mut closed).await;
            if stop.is_cancelled() {
                return;
            }
            let Some(session) = weak.upgrade() else { return };
            let mut slot = session.inbound_rx().lock().await;
            if session.status() == SessionStatus::Closed
                && rx.is_empty()
                && !producers_live(session.inbound_tx())
            {
                *slot = Some(rx);
                return;
            }
        }
    }

    /// Start the chat's inbound loop when no loop holds its receiver.
    pub(crate) async fn spawn_inbound_loop(self: &Arc<Self>, session: &Arc<Session>) {
        if let Some(rx) = session.inbound_rx().lock().await.take() {
            let (hub, s) = (self.clone(), session.clone());
            self.scope.spawn_named("inbound-loop", async move { hub.inbound_loop(s, rx).await });
        }
    }

    async fn inbound_items(
        self: Arc<Self>,
        weak: &std::sync::Weak<Session>,
        own: &mpsc::WeakSender<Inbound>,
        rx: &mut mpsc::Receiver<Inbound>,
        stop: &tokio_util::sync::CancellationToken,
        closed: &mut tokio::sync::watch::Receiver<bool>,
    ) {
        while let Some(item) = next_inbound(rx, stop, closed, own).await {
            // Held for this item only (see `inbound_loop`).
            let Some(session) = weak.upgrade() else { return };
            // An agent's stream allocates without any request: its pages go back once it stops.
            cmux_tui_platform::malloc_quiet_trim::note_activity();
            match item {
                Inbound::Notification {
                    method: m,
                    params,
                    agent,
                    host_incarnation,
                    host_seq,
                    persisted,
                    ..
                } => {
                    if m == method::SESSION_UPDATE {
                        // What an agent a Stop ended still had in flight is not the next turn's
                        // (`cancel.rs`): none of it lands in the turn that runs now.
                        if agent == session.stopped_agent.load(Ordering::SeqCst) {
                            continue;
                        }
                        // The replay of a session its `session/fork` made (`fork_replay.rs`).
                        if params
                            .as_ref()
                            .is_some_and(|p| super::fork_replay::update_of_the_fork(&session, p))
                        {
                            continue;
                        }
                        // Debug builds only: `ACPMUX_TEST_UPDATE_DELAY_MS` holds each update
                        // before it is applied (the log has it already), as a busy inbound loop
                        // does, so the daemon's integration tests can reach an agent first.
                        // Bounded; release builds have no seam.
                        #[cfg(debug_assertions)]
                        if let Some(ms) = std::env::var("ACPMUX_TEST_UPDATE_DELAY_MS")
                            .ok()
                            .and_then(|v| v.parse::<u64>().ok())
                        {
                            tokio::time::sleep(std::time::Duration::from_millis(ms.min(2_000)))
                                .await;
                        }
                        // A /context breakdown or usage limits from an agent that was replaced
                        // (a failover's dying primary answering late) are not the chat's now. The
                        // child lock is held while it is applied: a failover takes it to retire
                        // the old agent, and again to detach it, before it clears the
                        // breakdown, so the check and the write cannot straddle the failover.
                        if params.as_ref().is_some_and(crate::agent::process_state) {
                            let child = session.child.lock().await;
                            if child
                                .as_ref()
                                .is_some_and(|c| c.generation == agent && !c.is_retired())
                            {
                                self.on_update(&session, params.as_ref(), false);
                            }
                            continue;
                        }
                        // A mode or option report of an agent MDM's off ended, or of one older, is
                        // not the next agent's: only a newer agent's is applied
                        // (`FloorState::retired_through`). Checked and applied under the agent
                        // slot's lock, which that end takes, so no end comes between the two
                        // (reviews 3, 5 and 6 of #26052).
                        let kind =
                            params.as_ref().and_then(|p| p["update"]["sessionUpdate"].as_str());
                        let slot =
                            if matches!(kind, Some("current_mode_update" | "config_option_update"))
                            {
                                Some(session.child.lock().await)
                            } else {
                                None
                            };
                        if slot.is_some()
                            && agent <= session.floor.retired_through.load(Ordering::SeqCst)
                        {
                            continue;
                        }
                        let replayed = session
                            .replaying
                            .lock()
                            .unwrap_or_else(|e| e.into_inner())
                            .contains(&agent);
                        self.arm_auto_background(&session, params.as_ref(), replayed);
                        self.on_update_cache(&session, params.as_ref(), replayed);
                        self.surgery_on_update(&session, params.as_ref(), replayed);
                        self.spend_burn_on_update(&session, params.as_ref(), replayed);
                        self.notice_overlaps(&session);
                    } else if m == method::CANCEL_REQUEST
                        && let Some(id) = params.as_ref().and_then(|p| p.get("requestId"))
                    {
                        // A hosted reader waits for this marker before it
                        // acknowledges the host entry. A later daemon can
                        // therefore recover the cancellation even if this
                        // process dies before the request task runs.
                        let stored = self
                            .append_logged(
                                &session,
                                "mux",
                                "permission_withdrawn",
                                json!({
                                    "agentRequestId": id,
                                    "incarnation": host_incarnation.clone(),
                                }),
                                host_seq,
                            )
                            .1;
                        if let Some(done) = persisted {
                            let _ = done.send(stored);
                        }
                        if !stored {
                            continue;
                        }
                        let hub = self.clone();
                        let session = session.clone();
                        let id = id.clone();
                        tokio::spawn(async move {
                            hub.withdraw_permission(&session, host_incarnation.as_deref(), &id);
                        });
                    }
                }
                Inbound::Request { id, method: m, params, host_incarnation, .. } => {
                    let hub = self.clone();
                    let s = session.clone();
                    let epoch = session.permission_epoch.load(Ordering::SeqCst);
                    let turn_id = session.turn().map(|t| t.turn_id);
                    // Counted here, in the agent's order, as this loop
                    // reads it: a group's timer waits for every request
                    // read so far (`AskInFlight`). One this loop has not
                    // read within the group's 100 ms still forms a group
                    // of its own.
                    let ask = (m == method::SESSION_REQUEST_PERMISSION)
                        .then(|| super::permission_groups::AskInFlight::new(&session));
                    if m == method::SESSION_REQUEST_PERMISSION {
                        hub.register_agent_request(&s, &id, host_incarnation.as_deref());
                    }
                    let request_id = id.clone();
                    // Counted until its task ends: the idle exit never ends an agent that
                    // waits on an answer to one of its own requests (`idle.rs`).
                    let busy = super::idle::AgentRequest::new(&session);
                    tokio::spawn(async move {
                        let finish_hub = hub.clone();
                        hub.on_agent_request(
                            s.clone(),
                            id,
                            m,
                            params,
                            epoch,
                            turn_id,
                            ask,
                            host_incarnation.clone(),
                            None,
                        )
                        .await;
                        finish_hub.finish_agent_request(
                            &s,
                            &request_id,
                            host_incarnation.as_deref(),
                        );
                        drop(busy);
                    });
                }
                Inbound::Stderr(raw, host_seq, agent) => {
                    let line = short_text(&raw, STDERR_LINE_CAP);
                    tracing::debug!(session = %session.id, "stderr: {line}");
                    // Each pipe of each agent process is its own stream; a line with no agent is
                    // a line of its own.
                    let clean = match agent {
                        Some(source) => session
                            .stderr_stream
                            .lock()
                            .unwrap_or_else(|e| e.into_inner())
                            .clean_line(source, &raw),
                        None => crate::stderr::StderrStream::default().clean_line_of(&raw),
                    };
                    remember_stderr(
                        &mut session.stderr_tail.lock().unwrap_or_else(|e| e.into_inner()),
                        &clean,
                    );
                    session
                        .exit_line
                        .lock()
                        .unwrap_or_else(|e| e.into_inner())
                        .heard(&short_text(&clean, STDERR_LINE_CAP));
                    // An agent host's stderr was logged before its ack.
                    if host_seq.is_none() {
                        self.append(&session, "mux", "stderr", json!({"text": line}));
                    }
                }
                Inbound::Barrier(done) => {
                    let _ = done.send(());
                }
                Inbound::ReplayDone { agent } => session.end_replay(agent),
                // Under MDM's off an unheard agent ends now (review 65 of #23322): the background
                // check ends it (`end_every_managed_full_access`, `host_unheard`). What waits on it
                // is answered first, as its stopped reader never will: a start waiting on its
                // `initialize` holds the spawn lock that check takes (review 1 of #26059), unless a
                // reattach replaced the link since (review 2).
                Inbound::LinkBroken { agent } => {
                    let child =
                        session.child.lock().await.clone().filter(|c| c.generation == agent);
                    if let Some(child) = child.filter(|c| c.is_broken()) {
                        // An entry from its host could not be stored: every request open on it is
                        // answered now, with the store's refusal (`disk.full` on a full disk) or
                        // the link's own error, never left to the client's limit. The next request
                        // reattaches; the host keeps the entry for it.
                        let full = self.store.durability().and_then(|d| (d.full)());
                        let why = full.as_deref().unwrap_or(crate::agent::LINK_UNLOGGED);
                        child.fail_pending_if_unheard_with(why).await;
                    }
                    if self.full_access_managed_off() {
                        let child = session.child.lock().await.clone();
                        if let Some(child) = child.filter(|c| c.generation == agent) {
                            child.fail_pending_if_unheard().await;
                        }
                        self.idle_wake.notify_one();
                    } else if let Some(child) = session
                        .child
                        .lock()
                        .await
                        .clone()
                        .filter(|c| c.generation == agent && c.is_broken())
                    {
                        // Broken on an entry the store could not log: retried until it logs
                        // (`reach_broken_link`), one retry per link; the hub's scope owns it.
                        if child.claim_broken_retry() {
                            let (hub, s) = (self.clone(), session.clone());
                            self.scope.spawn_named("broken-link-reattach", async move {
                                hub.reach_broken_link(&s, &child).await;
                            });
                        }
                    } else if let Some(child) = session
                        .child
                        .lock()
                        .await
                        .clone()
                        .filter(|c| c.generation == agent && !c.is_broken())
                    {
                        // A lost link of a live host: reached again at once, and its open requests
                        // get their real answers (`ChildAgent::start_reader` kept them). Not
                        // reached: they fail now, as before. Off this loop, which the reattach's
                        // replay comes through.
                        // One reattach try per lost link, bounded by its host's hello and the
                        // 2 s death proof; the hub's scope owns it and ends it at shutdown.
                        let (hub, s) = (self.clone(), session.clone());
                        self.scope.spawn_named("lost-link-reattach", async move {
                            if !hub.reach_lost_link(&s, &child).await {
                                child.fail_pending_if_unheard().await;
                            }
                        });
                    }
                }
                Inbound::Exited { pid, code, host_seq } => {
                    {
                        let mut slot = session.child.lock().await;
                        // A late exit from a process that was already replaced
                        // must not detach the new one.
                        if slot.as_ref().is_some_and(|c| c.pid != pid) {
                            continue;
                        }
                        *slot = None;
                    }
                    self.cancel_pending_permissions(&session);
                    self.revoke_permission_chat(&session);
                    // A new agent holds no grant and no undeclared mode.
                    session.floor.harness_grant.store(false, Ordering::SeqCst);
                    session.floor.unsandboxed.store(false, Ordering::SeqCst);
                    *session.floor.undeclared_mode.lock().unwrap_or_else(|e| e.into_inner()) = None;
                    session.floor.asked_options.lock().unwrap_or_else(|e| e.into_inner()).clear();
                    // Its background processes ended with it (`processes.rs`).
                    self.processes_lost(&session, processes::HARNESS_EXIT);
                    // So did its background subagents (`work_below.rs`).
                    self.end_background_subagents(&session);
                    // And its loops, also when a forced Stop dropped its own clear (`loop_goal.rs`).
                    self.end_loop_goal(&session);
                    // And a turn it ran on its own: its line ends here, as a hosted agent's does on
                    // the host's exit (`tap.rs`), so a direct agent's never spins on in the pane
                    // (`background_turn.rs`). One the host's exit ended already is no second record.
                    session.harness_turn.store(false, Ordering::SeqCst);
                    self.end_background_turn(&session, "exit");
                    // The idle exit marked it before it ended the harness (`idle.rs`); a stop clears the mark.
                    let hibernating = session.hibernated_at.load(Ordering::SeqCst) != 0
                        && session.status() != SessionStatus::Closed;
                    let intentional = hibernating
                        || matches!(session.status(), SessionStatus::Idle | SessionStatus::Closed);
                    // This process's line, taken at every exit so the next process starts with none.
                    let last = session.exit_line.lock().unwrap_or_else(|e| e.into_inner()).take();
                    // An agent host's exit was logged before its ack.
                    if host_seq.is_none() {
                        self.append(
                            &session,
                            "mux",
                            if intentional { "stopped" } else { "exited" },
                            if hibernating {
                                json!({"code": code, "hibernated": true})
                            } else if intentional {
                                json!({"code": code})
                            } else {
                                // Its stderr was queued before its exit (`agent.rs`): the line is
                                // what it said last since its last good turn (`exit_reason.rs`).
                                super::exit_reason::exited_data(code, last.as_deref())
                            },
                        );
                    }
                    if !intentional {
                        self.set_status(&session, NotWaiting::Disconnected);
                        // Quit on the account's limit: held until its reset, then started
                        // again with no prompt (`rate_hold.rs` `hold_at_exit`).
                        // This process's own line (`exit_line`), not `stderr_tail`, which still
                        // holds a 429 an earlier turn retried past.
                        let limit = last
                            .as_deref()
                            .filter(|l| super::exit_reason::exit_cause(l) == "rate_limit");
                        if let Some(line) = limit {
                            self.hold_at_exit(&session, line).await;
                        }
                    }
                }
            }
        }
    }

    /// `replayed`: the update is history an agent's load replays (`Session::replaying`).
    pub(crate) fn on_update(&self, session: &Session, params: Option<&Value>, replayed: bool) {
        let Some(update) = params.and_then(|p| p.get("update")) else {
            return;
        };
        // The tap persists a redacted receipt for ambiguous hosted metadata; the
        // same fence must also keep its original update out of in-memory state.
        if session.fences_compaction_update(update) {
            return;
        }
        // A subagent's messages and settings are not the session's own.
        let sid = params.and_then(|p| p.get("sessionId")).and_then(Value::as_str);
        let owned = sid.is_some_and(|sid| {
            session.subagents.lock().unwrap_or_else(|e| e.into_inner()).owns(sid)
        });
        if owned {
            return;
        }
        // An agent to-do list changes nothing here (`todo_tools.rs`).
        if crate::todo_tools::drops(&session.id, update) {
            return;
        }
        let kind = update.get("sessionUpdate").and_then(Value::as_str).unwrap_or("");
        self.note_activity(session, update);
        // Work the model streams live says the pool answers again (`capacity_gate.rs`). Not a
        // message chunk: a harness words its 529 as one ("API Error: 529 ..."); a turn of
        // text alone tells the gate when it ends well (`turns.rs`).
        if !replayed && matches!(kind, "agent_thought_chunk" | "tool_call" | "plan") {
            self.capacity_gate_answered(session);
        }
        // A mode or option change goes through the one setter below.
        let mut mode_write = None;
        let mut reported_tools = None;
        let mut goal_write = false;
        let mut mark_cleared = false;
        let mut breakdown_changed = false;
        let mut limits_changed = false;
        let mut retitled = false;
        let background = kind == "agent_message_chunk" && self.background_message(session, update);
        let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
        match kind {
            "agent_message_chunk" => {
                // History a load replays is logged (`.replay`) but is not the chat's newest
                // reply: a session resumed from stopped had every earlier reply, then the new
                // one, as its `lastMessage` (remote-ergo walk 4, 2026-10-26).
                if let Some(text) = update
                    .get("content")
                    .and_then(|c| c.get("text"))
                    .and_then(Value::as_str)
                    .filter(|_| !replayed)
                    // A turn the person did not start leaves the preview as it was
                    // (`background_turn.rs`).
                    .filter(|_| !background)
                {
                    // In place: the preview was copied whole on every streamed chunk.
                    let preview = m.preview.get_or_insert_with(String::new);
                    preview.push_str(text);
                    if preview.len() > 2000 {
                        let mut idx = preview.len() - 2000;
                        while !preview.is_char_boundary(idx) {
                            idx += 1;
                        }
                        preview.drain(..idx);
                    }
                }
            }
            "tool_call" | "tool_call_update" => {
                let at = now_ms();
                if let Some(created) = super::pull_requests::absorb(session, update, &mut m, at) {
                    let url = created.url;
                    self.review_index.note_pr(&session.id, &url, at);
                    self.ledger.note_pull_request(&session.id, &url);
                    // The asks its body named link to it (`hub/asks`).
                    self.asks.note_created(&url, created.traces, at);
                }
                for (target, merged) in super::pull_requests::absorb_closed(session, update) {
                    let url = match target {
                        super::pull_requests::Target::Url(url) => Some(url),
                        super::pull_requests::Target::Number(n) => {
                            self.review_index.pr_by_number(n)
                        }
                    };
                    if let Some(url) = url {
                        super::pull_requests::record_closed(&mut m, &url);
                        self.review_index.note_closed(&url);
                        self.asks.note_settled(&url, merged, at);
                        if !replayed {
                            super::auto_settle::pr_changed(&url);
                        }
                    }
                }
                super::touched::absorb(session, update, &mut m, replayed);
                super::lineage::note_tool_call(session, update);
            }
            "usage_update" => m.usage = Some(update.clone()),
            // History a load replays says nothing about what Claude Code holds now.
            super::native_messaging::HOLD_UPDATE if !replayed => {
                self.note_peer_message_hold(session, update);
            }
            "available_commands_update" => m.available_commands = Some(update.clone().into()),
            "current_mode_update" => {
                // A mode the harness moves to by itself is not cmux's: a full-access mark goes, so
                // moving back to it later is not cmux's either (`trust_wait.rs`
                // `full_access_by_cmux`). A narrower mark stays: it is the mode the person or a
                // policy picked, which a harness that moves itself into full access does not
                // erase, so its asks still go to the person (`full_access_allow`).
                let reported = update.get("currentModeId").and_then(Value::as_str);
                if m.mode_set_by_cmux.as_deref().is_some_and(super::start_mode::is_full_access)
                    && reported != m.mode_set_by_cmux.as_deref()
                {
                    m.mode_set_by_cmux = None;
                    // Saved now, so a restart does not load the mark back.
                    mark_cleared = true;
                }
                mode_write = update.get("currentModeId").cloned().map(ModeWrite::CurrentMode);
            }
            "config_option_update" => {
                mode_write = update.get("configOptions").cloned().map(ModeWrite::ConfigOptions);
            }
            "session_info_update" => {
                if let Some(goal) = update.pointer("/_meta/goal") {
                    m.goal = crate::goal::GoalState::from_value(goal, m.family.as_deref());
                    goal_write = true;
                    // The agent's own word on its loops (`agent_timer.rs`); a replay is history.
                    if !replayed {
                        super::agent_timer::note_agent_goal(session, goal);
                    }
                }
                // A harness title made from the first input stops before a client context
                // (prompt_context.rs), so a Cmd-I chat titles from the person's words.
                // A chat someone named (`titles::NAMED`: a rename, a starter's name) keeps the
                // title its name gave: a harness title after it put the old name back in every
                // list (Leo, 2026-11-22: "I DON'T KNOW WHO'S BEEN RENAMED TO WHAT").
                // A fork keeps its inherited title over one its harness made from the fork's
                // first prompt alone, which may be acpmux's sender banner (#50098, `titles.rs`).
                let named = m.title_source.as_deref() == Some(super::titles::NAMED);
                if let Some(title) = update.get("title").and_then(Value::as_str).filter(|_| !named)
                    && super::titles::takes_harness_title(m.title_source.as_deref())
                {
                    let title = cmux_chat_index::without_client_context(title).trim_end();
                    // A title made from acpmux's own mark of who wrote the prompt names nothing.
                    if !title.is_empty() && !super::prompt_attribution::is_mark_title(title) {
                        retitled = m.title.as_deref() != Some(title);
                        if retitled {
                            super::title_log::record(
                                session,
                                &m.harness,
                                None,
                                "harness",
                                m.title_source.as_deref(),
                                title.split_whitespace().count(),
                                0,
                            );
                        }
                        m.title = Some(title.to_owned());
                        m.title_source = Some(super::titles::HARNESS.to_owned());
                        // The ledger's copy (one map entry; a line only when a field changed).
                        self.ledger.note_session_info(
                            &session.id,
                            super::ledger::TurnContext::of(&m).info,
                        );
                    }
                }
                // Claude Code's /context breakdown, sent after each turn (`claude_stdio`). It comes
                // after the turn's own save, so it is saved here (below), or a restart loses it.
                if let Some(breakdown) = update.pointer("/_meta/acpmux/contextBreakdown") {
                    m.context_breakdown = Some(breakdown.clone());
                    breakdown_changed = true;
                }
                // The account's plan usage limits, merged by window (`claude_stdio`).
                if let Some(limits) = update.pointer("/_meta/acpmux/usageLimits") {
                    let merged =
                        crate::claude_stdio::merge_usage_limits(m.usage_limits.as_ref(), limits);
                    limits_changed |= m.usage_limits.as_ref() != Some(&merged);
                    m.usage_limits = Some(merged);
                }
                // Codex's, as cmux-codex-acp passes `account/rateLimits/updated` on: each is
                // every window it knows, so it replaces the last, and one that reports nothing
                // clears it (`codex_app_server`). Another limit's snapshot changes nothing.
                if let Some(snapshot) = update
                    .pointer("/_meta/codexAppServer/rateLimits")
                    .filter(|s| crate::codex_app_server::is_plan_snapshot(s))
                {
                    let limits = crate::codex_app_server::usage_limits(snapshot);
                    limits_changed |= m.usage_limits != limits;
                    m.usage_limits = limits;
                }
                // Claude Code's system/init: its MCP servers, plugins and skills.
                reported_tools = update
                    .pointer("/_meta/claude")
                    .filter(|c| c.get("mcp_servers").is_some_and(Value::is_array))
                    .cloned();
            }
            _ => {}
        }
        let limits = limits_changed.then(|| m.usage_limits.clone().unwrap_or(Value::Null));
        drop(m);
        // Goal state must survive a daemon restart even when the turn has not settled yet. So
        // must a title the harness gave: the chat shows it now, and before it waited for the
        // turn's end or the stop's flush, so a hard exit in between took it back.
        if goal_write || breakdown_changed || retitled || limits.is_some() {
            self.save_meta(session);
        }
        // The plan limits as merged above, whole (null once Codex reports none): an open pane
        // applies them as they are, so its plan ring moves without reading the detail again.
        if let Some(limits) = limits {
            self.append(session, "mux", USAGE_LIMITS_KIND, json!({"usageLimits": limits}));
        }
        if let Some(claude) = reported_tools {
            self.absorb_reported_tools(session, &claude);
        }
        // Applied: the tap's count of it goes, under the lock the write publishes its mode under
        // (`FloorState::unapplied_full_access`, review 5 of #26052).
        let settles =
            params.is_some_and(|p| super::full_access_bound::own_full_access_report(session, p));
        // Default deny on drift: also a mode the harness changes by itself.
        if let Some(w) = mode_write {
            self.write_mode_state_settling(session, [w], settles);
        } else if settles {
            let _m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            settle_full_access_report(session);
        }
        if mark_cleared {
            self.save_meta(session);
        }
    }
}

//! Part of `Hub`; see `hub/mod.rs`.

use super::person::ANSWERED_BY_SLOT;
use super::*;
use cmux_json::JsonSet as _;

tokio::task_local! {
    /// The fence of the ancestor's answer the agent's request in this task got, until its
    /// write takes it (`respond_answer`).
    static ANSWER_FENCE: std::cell::RefCell<AnswerFence>;
}

/// An ancestor's answer's fence no write took: cut when dropped, as the request's task ends, so
/// no push waits on it (review 84 of #23322).
#[derive(Default)]
struct AnswerFence(Option<crate::agent::Fence>);

impl Drop for AnswerFence {
    fn drop(&mut self) {
        if let Some(f) = self.0.take() {
            f.cut();
        }
    }
}

/// Gives the agent's request in this task the fence of the ancestor's answer it got. A fence
/// with no request task to write it (a trust card's own task), or one it replaces, is cut.
fn keep_answer_fence(fence: crate::agent::Fence) {
    match ANSWER_FENCE.try_with(|f| f.borrow_mut().0.replace(fence.clone())) {
        Ok(None) => {}
        Ok(Some(replaced)) => {
            replaced.cut();
        }
        Err(_) => {
            fence.cut();
        }
    }
}

// A losing answer is told the first one (`respond_permission`).
#[path = "permission_settled.rs"]
pub(super) mod settled;

/// The person-readable line on a request (`toolCall._meta.acpmux.display`).
mod display;
pub(crate) use display::{ChildTags, drop_display_lines};

mod pending;

impl Hub {
    // ------------------------------------------------------------- inbound

    pub(super) async fn inbound_loop(
        self: Arc<Self>,
        session: Arc<Session>,
        mut rx: mpsc::Receiver<Inbound>,
    ) {
        while let Some(item) = rx.recv().await {
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
                        self.on_update(&session, params.as_ref(), replayed);
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
                    if self.full_access_managed_off() {
                        let child = session.child.lock().await.clone();
                        if let Some(child) = child.filter(|c| c.generation == agent) {
                            child.fail_pending_if_unheard().await;
                        }
                        self.idle_wake.notify_one();
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
                    // The idle exit marked it before it ended the harness (`idle.rs`); a stop clears the mark.
                    let hibernating = session.hibernated_at.load(Ordering::SeqCst) != 0
                        && session.status() != SessionStatus::Closed;
                    let intentional = hibernating
                        || matches!(session.status(), SessionStatus::Idle | SessionStatus::Closed);
                    // An agent host's exit was logged before its ack.
                    if host_seq.is_none() {
                        self.append(
                            &session,
                            "mux",
                            if intentional { "stopped" } else { "exited" },
                            if hibernating {
                                json!({"code": code, "hibernated": true})
                            } else {
                                json!({"code": code})
                            },
                        );
                    }
                    if !intentional {
                        self.set_status(&session, SessionStatus::Disconnected);
                    }
                }
            }
        }
    }

    /// `replayed`: the update is history an agent's load replays (`Session::replaying`).
    pub(super) fn on_update(&self, session: &Session, params: Option<&Value>, replayed: bool) {
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
        let kind = update.get("sessionUpdate").and_then(Value::as_str).unwrap_or("");
        self.note_activity(session, update);
        // A mode or option change goes through the one setter below.
        let mut mode_write = None;
        let mut reported_tools = None;
        let mut goal_write = false;
        let mut mark_cleared = false;
        let mut breakdown_changed = false;
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
                super::pull_requests::absorb(session, update, &mut m);
                super::lineage::note_tool_call(session, update);
            }
            "usage_update" => m.usage = Some(update.clone()),
            "available_commands_update" => m.available_commands = Some(update.clone()),
            "current_mode_update" => {
                // A mode the harness moves to by itself is not cmux's: the mark goes, so moving
                // back to it later is not cmux's either (`trust_wait.rs` `full_access_by_cmux`).
                let reported = update.get("currentModeId").and_then(Value::as_str);
                if m.mode_set_by_cmux.is_some() && reported != m.mode_set_by_cmux.as_deref() {
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
                    m.goal = goal.as_object().map(|_| goal.clone());
                    goal_write = true;
                }
                // A harness title made from the first input stops before a client context
                // (prompt_context.rs), so a Cmd-I chat titles from the person's words.
                if let Some(title) = update.get("title").and_then(Value::as_str) {
                    let title = cmux_chat_index::without_client_context(title).trim_end();
                    if !title.is_empty() {
                        m.title = Some(title.to_owned());
                        m.title_source = Some(super::titles::HARNESS.to_owned());
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
                    breakdown_changed |= m.usage_limits.as_ref() != Some(&merged);
                    m.usage_limits = Some(merged);
                }
                // Claude Code's system/init: its MCP servers, plugins and skills.
                reported_tools = update
                    .pointer("/_meta/claude")
                    .filter(|c| c.get("mcp_servers").is_some_and(Value::is_array))
                    .cloned();
            }
            _ => {}
        }
        drop(m);
        // Goal state must survive a daemon restart even when the turn has not settled yet.
        if goal_write || breakdown_changed {
            self.save_meta(session);
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

    /// Answers the agent's request `id` with `result`, under the fence of the ancestor's answer
    /// it carries (`ANSWER_FENCE`), and returns once its writer took it or an off push cut it.
    /// An answer cut while it was queued never reaches the agent, which still waits: the request
    /// is handled again (`again`: its method, params, permission epoch, turn and host
    /// incarnation), so it is asked under the bound now, or cancelled when a stop, a new turn or
    /// the agent's withdrawal came since (reviews 84 and 88 of #23322). The request stays open
    /// (`register_agent_request`) the whole time, in this task, so a withdrawal while the answer
    /// waits is kept for the ask again (review 88, round 7).
    async fn respond_answer(
        self: &Arc<Self>,
        session: &Arc<Session>,
        child: &Arc<ChildAgent>,
        id: Id,
        result: Result<Value, RpcError>,
        again: (String, Option<Value>, u64, Option<String>, Option<String>),
    ) {
        let fence = ANSWER_FENCE.try_with(|f| f.borrow_mut().0.take()).ok().flatten();
        let _ = child.respond_fenced(id.clone(), result, fence.as_ref()).await;
        let Some(fence) = fence else { return };
        fence.taken().await;
        // A writer that stopped cuts what it still had: its agent is gone and asks nothing.
        if fence.is_cut() && child.is_alive().await {
            let (m, params, epoch, turn_id, incarnation) = again;
            let s = session.clone();
            let c = Some(child.clone());
            self.clone()
                .on_agent_request(s, id, m, params, epoch, turn_id, None, incarnation, c)
                .await;
        }
    }

    /// [`Self::on_agent_request_in`], where an ancestor's answer finds the fence of its write
    /// (`ANSWER_FENCE`). Boxed: a cut answer's request is handled again from inside it, for
    /// `asked_of`, the agent that asked it.
    pub(super) fn on_agent_request(
        self: Arc<Self>,
        session: Arc<Session>,
        id: Id,
        m: String,
        params: Option<Value>,
        epoch: u64,
        turn_id: Option<String>,
        ask: Option<super::permission_groups::AskInFlight>,
        host_incarnation: Option<String>,
        asked_of: Option<Arc<ChildAgent>>,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>> {
        Box::pin(async move {
            let request = self.on_agent_request_in(
                session,
                id,
                m,
                params,
                epoch,
                turn_id,
                ask,
                host_incarnation,
                asked_of,
            );
            ANSWER_FENCE.scope(Default::default(), request).await;
        })
    }

    async fn on_agent_request_in(
        self: Arc<Self>,
        session: Arc<Session>,
        id: Id,
        m: String,
        params: Option<Value>,
        epoch: u64,
        turn_id: Option<String>,
        ask: Option<super::permission_groups::AskInFlight>,
        host_incarnation: Option<String>,
        asked_of: Option<Arc<ChildAgent>>,
    ) {
        // Context was captured before spawning this request task, so cancel
        // or a new turn cannot make a delayed request join the new ask.
        let current = session.child.lock().await.clone();
        // A request handled again is answered only to the agent that asked it, while it still
        // has the session: a failover's agent starts its request ids over (review 88 of #23322).
        let child = match (asked_of, current) {
            (Some(asked), Some(now)) if Arc::ptr_eq(&asked, &now) => asked,
            (None, Some(now)) => now,
            _ => return,
        };
        // Grok's x.ai extension requests: a question or a plan approval,
        // asked through the same permission path (xai.rs).
        let again = (m.clone(), params.clone(), epoch, turn_id.clone(), host_incarnation.clone());
        if let Some(kind) = super::xai::request_kind(&m) {
            let result = self
                .handle_xai_request(&session, kind, params.unwrap_or(Value::Null), epoch, turn_id)
                .await;
            self.respond_answer(&session, &child, id, result, again).await;
            return;
        }
        // Cursor's cursor/ requests: a question or a plan approval (cursor_ext.rs).
        if let Some(kind) = super::cursor_ext::request_kind(&m) {
            let result = self
                .handle_cursor_request(
                    &session,
                    kind,
                    params.unwrap_or(Value::Null),
                    epoch,
                    turn_id,
                )
                .await;
            self.respond_answer(&session, &child, id, result, again).await;
            return;
        }
        if m == method::SESSION_REQUEST_PERMISSION {
            let params = params.unwrap_or(Value::Null);
            let result = self
                .handle_permission_for(
                    &session,
                    params,
                    epoch,
                    turn_id,
                    Some(&id),
                    host_incarnation.as_deref(),
                    ask,
                )
                .await;
            self.respond_answer(&session, &child, id, Ok(result), again).await;
            return;
        }
        // ACP file-system methods: the harness delegates reads and writes to
        // the client. Writes go through the permission policy like any edit
        // tool; reads are refused only by deny-all or a deny rule.
        if m == "fs/write_text_file" {
            let result =
                self.handle_fs_write(&session, params.unwrap_or(Value::Null), epoch, turn_id).await;
            let _ = child.respond(id, result).await;
            return;
        }
        if m == "fs/read_text_file" {
            let result =
                self.handle_fs_read(&session, params.unwrap_or(Value::Null), epoch, turn_id).await;
            let _ = child.respond(id, result).await;
            return;
        }
        let _ = child.respond(id, Err(RpcError::method_not_found(&m))).await;
    }

    fn fs_path(session: &Session, params: &Value) -> Result<std::path::PathBuf, RpcError> {
        let raw = params
            .get("path")
            .and_then(Value::as_str)
            .ok_or_else(|| RpcError::invalid_params("path is required"))?;
        let p = std::path::PathBuf::from(raw);
        let p = if p.is_absolute() { p } else { session.meta().cwd.join(p) };
        // Rules match the path text: resolve `.` and `..` first so
        // `src/../../secret` is judged (and written) as where it lands.
        Ok(normalize_path(&p))
    }

    async fn handle_fs_write(
        self: &Arc<Self>,
        session: &Arc<Session>,
        params: Value,
        epoch: u64,
        turn_id: Option<String>,
    ) -> Result<Value, RpcError> {
        let mut path = Self::fs_path(session, &params)?;
        // The remote floor: never through a symlink, the question names the
        // resolved path, and only that file is written (`write_approved`).
        let web_turn = Self::web_turn(session);
        if web_turn {
            path = super::remote_floor::write_target(&path)
                .map_err(|e| RpcError::new(-32000, format!("write refused: {e}")))?;
        }
        let content = params
            .get("content")
            .and_then(Value::as_str)
            .ok_or_else(|| RpcError::invalid_params("content is required"))?
            .to_owned();
        // Show the path relative to the session directory; the harness may
        // hand back the canonical form (/private/var vs /var on macOS).
        let cwd = session.meta().cwd;
        let cwd_canon = cwd.canonicalize().unwrap_or_else(|_| cwd.clone());
        let shown = path
            .strip_prefix(&cwd)
            .or_else(|_| path.strip_prefix(&cwd_canon))
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_else(|_| path.to_string_lossy().into_owned());
        let request = json!({
            "sessionId": session.meta().agent_session_id.clone().unwrap_or_else(|| session.id.clone()),
            "toolCall": {"toolCallId": format!("fs-{}", uuid::Uuid::now_v7()), "title": format!("Write {shown}"), "kind": "edit", "status": "pending", "rawInput": {"path": path, "bytes": content.len()}, "locations": [{"path": path}]},
            "options": [
                {"optionId": "allow_once", "name": "Allow", "kind": "allow_once"},
                {"optionId": "reject_once", "name": "Reject", "kind": "reject_once"}
            ]
        });
        let outcome = self.handle_permission(session, request, epoch, turn_id).await;
        if !outcome_allows(&outcome) {
            return Err(RpcError::new(
                -32000,
                format!("write to {shown} rejected by the acpmux permission policy"),
            ));
        }
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| RpcError::internal(format!("create {}: {e}", parent.display())))?;
        }
        let written = if web_turn {
            super::remote_floor::write_approved(&path, content.as_bytes())
        } else {
            std::fs::write(&path, content.as_bytes())
        };
        written.map_err(|e| RpcError::internal(format!("write {}: {e}", path.display())))?;
        Ok(Value::Null)
    }

    async fn handle_fs_read(
        self: &Arc<Self>,
        session: &Arc<Session>,
        params: Value,
        epoch: u64,
        turn_id: Option<String>,
    ) -> Result<Value, RpcError> {
        let mut path = Self::fs_path(session, &params)?;
        // A read from a cancelled turn, or one that arrived before another
        // turn began, is refused, as a permission request from it is cancelled.
        if session.permission_epoch.load(Ordering::SeqCst) != epoch || stale_turn(session, &turn_id)
        {
            return Err(RpcError::new(-32000, "the turn of this read ended"));
        }
        // The remote floor: a Web turn judges, asks about and reads the
        // resolved file; outside its folder it asks first.
        let target = if Self::web_turn(session) {
            let t = super::remote_floor::read_target(&path, &session.meta().cwd);
            if let Some(t) = &t {
                path.clone_from(&t.real);
            }
            Some(t)
        } else {
            None
        };
        let outside = target.as_ref().is_some_and(|t| !t.as_ref().is_some_and(|t| t.inside));
        // Only deny-all matters here, which MDM's off never makes: the policy as stored, with no read
        // of the off (review 121). A read that asks reads it once there (`handle_permission_for`).
        let config_policy = self.config.read().await.permission_policy;
        let policy = Self::stored_policy_for(session, config_policy);
        let probe = json!({"toolCall": {"title": format!("Read {}", path.display()), "kind": "read", "rawInput": {"path": path}}});
        let rule =
            session.meta().permission_rules.as_ref().and_then(|r| super::rules::decide(r, &probe));
        let mut denied = matches!(rule, Some(super::rules::RuleDecision::Deny))
            || (rule.is_none() && policy == PermissionPolicy::DenyAll);
        if !denied && (outside || matches!(rule, Some(super::rules::RuleDecision::Ask))) {
            // An `ask` rule prompts for the read like any other tool call.
            let request = json!({
                "sessionId": session.meta().agent_session_id.clone().unwrap_or_else(|| session.id.clone()),
                "toolCall": {"toolCallId": format!("fs-{}", uuid::Uuid::now_v7()), "title": format!("Read {}", path.display()), "kind": "read", "status": "pending", "rawInput": {"path": path}, "locations": [{"path": path}]},
                "options": [
                    {"optionId": "allow_once", "name": "Allow", "kind": "allow_once"},
                    {"optionId": "reject_once", "name": "Reject", "kind": "reject_once"}
                ]
            });
            denied =
                !outcome_allows(&self.handle_permission(session, request, epoch, turn_id).await);
        }
        if denied {
            return Err(RpcError::new(
                -32000,
                format!("read of {} rejected by the acpmux permission policy", path.display()),
            ));
        }
        let read =
            |e: std::io::Error| RpcError::new(-32000, format!("read {}: {e}", path.display()));
        let text = match target {
            Some(Some(t)) => {
                use std::io::Read;
                let mut text = String::new();
                let mut file = super::remote_floor::open_read_target(&t).map_err(read)?;
                file.read_to_string(&mut text).map_err(read)?;
                text
            }
            Some(None) => return Err(read(std::io::Error::other("the path cannot be resolved"))),
            None => std::fs::read_to_string(&path).map_err(read)?,
        };
        let line = params.get("line").and_then(Value::as_u64).map(|l| l.max(1) as usize);
        let limit = params.get("limit").and_then(Value::as_u64).map(|l| l as usize);
        let content = match (line, limit) {
            (None, None) => text,
            (l, n) => {
                let start = l.unwrap_or(1) - 1;
                let lines: Vec<&str> = text.lines().collect();
                let end = n.map_or(lines.len(), |n| start.saturating_add(n).min(lines.len()));
                if start >= lines.len() { String::new() } else { lines[start..end].join("\n") }
            }
        };
        Ok(json!({"content": content}))
    }

    /// The policy that answers `session`'s permission requests: its own, else the daemon's
    /// (`config_policy`). While MDM or the team policy forces `sessions.allowFullAccess` off,
    /// approve-all (the policy form of full access, from config.json `permissionPolicy`, a
    /// preset, a profile default or a session set before the push) answers nothing itself: it
    /// runs as `ask` (`approve_all_allowed`).
    pub(super) fn policy_for(
        &self,
        session: &Session,
        config_policy: PermissionPolicy,
    ) -> PermissionPolicy {
        capped_policy(
            Self::stored_policy_for(session, config_policy),
            self.full_access_managed_off(),
        )
    }

    /// `policy_for` as stored, before MDM's off caps it: for the person rule, which must not
    /// treat an approve-all session as asking while MDM forces full access off.
    pub(super) fn stored_policy_for(
        session: &Session,
        config_policy: PermissionPolicy,
    ) -> PermissionPolicy {
        session
            .meta()
            .permission_policy
            .as_deref()
            .and_then(|p| p.parse().ok())
            .unwrap_or(config_policy)
    }

    /// `epoch` is `permission_epoch` read when the agent's request arrived.
    pub(super) async fn handle_permission(
        self: &Arc<Self>,
        session: &Arc<Session>,
        request: Value,
        epoch: u64,
        turn_id: Option<String>,
    ) -> Value {
        self.handle_permission_for(session, request, epoch, turn_id, None, None, None).await
    }

    /// `handle_permission` for the agent's own `session/request_permission`
    /// with JSON-RPC id `agent_request_id`, recorded so a controller that
    /// adopts the agent's host can still answer it.
    pub(super) async fn handle_permission_for(
        self: &Arc<Self>,
        session: &Arc<Session>,
        mut request: Value,
        epoch: u64,
        turn_id: Option<String>,
        agent_request_id: Option<&Id>,
        agent_host_incarnation: Option<&str>,
        ask: Option<super::permission_groups::AskInFlight>,
    ) -> Value {
        // MDM's off as this ask begins: its one read, before anything it waits on (review 123),
        // which every decision below takes, so an off that comes and goes while it is judged still
        // holds for it (reviews 73, 75 and 77 of #23322). Read without a lock, so also under the
        // permission lock.
        let off = self.off_latch();
        #[cfg(test)]
        super::full_access_bound::operation_entry(self);
        // One harness-neutral copy of any questions, before rules and the
        // record see the request (questions.rs).
        super::questions::normalize(&mut request, Self::preview_format(session));
        // A person-readable line for a tool whose name and JSON mean nothing
        // to a person (permissions/display.rs), before anything shows the request.
        self.stamp_permission_display(session, &mut request);
        let needs_person = super::questions::needs_person(&request);
        // A shell command that only reads (`shell_readonly.rs`), judged before the lock and off
        // the async workers: its git reads look at the repositories on disk.
        // Only under approve-reads: approve-edits writes files unasked, so a command's own
        // program could be one the agent wrote.
        let reads_policy = {
            let cfg = self.config.read().await;
            capped_policy(Self::stored_policy_for(session, cfg.permission_policy), off.off())
                == PermissionPolicy::ApproveReads
        };
        // Judged in the environment the harness runs it with: the daemon's, the allow-listed
        // login values, then the env its agent was started with (`ensure_child`). An agent this
        // daemon did not start (re-adopted after a restart) asks.
        let launched = session.launch_env.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let shell_reads = reads_policy
            && request.pointer("/toolCall/kind").and_then(Value::as_str) == Some("execute")
            && match launched {
                None => false,
                Some(own) => {
                    let meta = session.meta();
                    let family = self.config.read().await.family(&meta.harness);
                    let mut env = crate::login_env::effective_for(family.as_deref(), &own);
                    // The agent's PATH, unless its own env names one (`apply_tokio_for`).
                    if let Some(path) = crate::login_env::agent_path()
                        && !own.contains_key("PATH")
                    {
                        env.insert("PATH".to_owned(), path.to_string_lossy().into_owned());
                    }
                    let (request, cwd) = (request.clone(), meta.cwd);
                    // A probe that takes too long asks; its thread finishes on its own.
                    let probe = tokio::task::spawn_blocking(move || {
                        super::shell_readonly::request_is_read_only(&request, &cwd, &env)
                    });
                    matches!(
                        tokio::time::timeout(super::shell_readonly::PROBE_TIMEOUT, probe).await,
                        Ok(Ok(true))
                    )
                }
            };
        // Read before the locks (it reads the settings file); the mode is read again under them.
        // Do not cache whether the mode is bypass here: a successful mode switch can drain
        // pending asks before this request takes the lock and inserts itself. Judge its mode
        // only under the permission lock below, so that request cannot miss the switch.
        let full_access_on = off.allows_full_access();
        let (rx, prev, grouping, permission_id) = {
            let cfg = self.config.read().await;
            let mut state = session.permissions.lock().unwrap_or_else(|e| e.into_inner());
            if session.permission_epoch.load(Ordering::SeqCst) != epoch
                || stale_turn(session, &turn_id)
            {
                return json!({"outcome":{"outcome":"cancelled"}});
            }
            if let Some(agent_request_id) = agent_request_id
                && state.cancelled_requests.remove(&super::permission_groups::AgentRequestKey::new(
                    agent_host_incarnation,
                    agent_request_id,
                ))
            {
                return json!({"outcome":{"outcome":"cancelled"}});
            }
            // The remote floor (`remote_floor.rs`): a Web turn whose mode left
            // the asking table is cancelled, and nothing in it approves itself.
            let web_turn = Self::web_turn(session);
            if web_turn && let Some(reason) = self.remote_floor_breach(session) {
                self.append(session,"mux","permission_auto",json!({"permissionId":uuid::Uuid::now_v7().to_string(),"request":request,"cancelled":true,"reason":reason}));
                drop(state);
                drop(cfg);
                // The turn ends too (a config reload can end the asking
                // mode with no mode write).
                self.remote_floor_cancel(session, reason);
                return json!({"outcome":{"outcome":"cancelled"}});
            }
            let policy =
                capped_policy(Self::stored_policy_for(session, cfg.permission_policy), off.off());
            let options =
                request.get("options").and_then(Value::as_array).cloned().unwrap_or_default();
            let pick = |kinds: &[&str]| -> Option<String> {
                for k in kinds {
                    if let Some(o) =
                        options.iter().find(|o| o.get("kind").and_then(Value::as_str) == Some(k))
                    {
                        return o.get("optionId").and_then(Value::as_str).map(str::to_owned);
                    }
                }
                None
            };
            let tool_kind = request
                .get("toolCall")
                .and_then(|t| t.get("kind"))
                .and_then(Value::as_str)
                .unwrap_or("");
            let rule = session
                .meta()
                .permission_rules
                .as_ref()
                .and_then(|r| super::rules::decide(r, &request));
            let auto = match rule {
                Some(super::rules::RuleDecision::Approve) => pick(&["allow_once", "allow_always"]),
                Some(super::rules::RuleDecision::Deny) => pick(&["reject_once", "reject_always"]),
                Some(super::rules::RuleDecision::Ask) => None,
                None => match policy {
                    PermissionPolicy::ApproveAll => pick(&["allow_once", "allow_always"]),
                    PermissionPolicy::DenyAll => pick(&["reject_once", "reject_always"]),
                    PermissionPolicy::ApproveReads | PermissionPolicy::ApproveEdits => {
                        let edits = policy == PermissionPolicy::ApproveEdits;
                        if matches!(tool_kind, "read" | "search" | "fetch" | "think")
                            || (edits && tool_kind == "edit")
                        {
                            pick(&["allow_once", "allow_always"])
                        } else if tool_kind == "execute"
                            && shell_reads
                            && policy == PermissionPolicy::ApproveReads
                        {
                            // Judged under approve-reads before the lock; the policy read here
                            // must still be it.
                            // A shell command that only reads (`shell_readonly.rs`), once:
                            // allow_always would widen later asks and set the harness grant.
                            pick(&["allow_once"])
                        } else {
                            None
                        }
                    }
                    PermissionPolicy::Ask => None,
                },
            };
            let denied = policy == PermissionPolicy::DenyAll
                || rule == Some(super::rules::RuleDecision::Deny);
            // The chat allowance never answers in a Web turn, nor what an `ask` rule sends to the person.
            let chat_option = if state.chat_allowed
                && !denied
                && rule != Some(super::rules::RuleDecision::Ask)
                && session.turn().is_some_and(|t| t.control != Control::Web)
                && super::permission_groups::eligible(&request)
            {
                super::permission_groups::option(&request, "allow_once")
            } else {
                None
            };
            let floored = web_turn && !denied && auto.is_some();
            // Full access answers what the harness still asks, unless a rule decided it. The ask's
            // off is looked at again here (memory only): a push since the read above answers
            // nothing.
            let full_access = (full_access_on && !off.off() && rule.is_none() && !denied)
                .then(|| full_access_allow(session, &request))
                .flatten();
            let auto = if denied {
                pick(&["reject_once", "reject_always"])
            } else if needs_person || web_turn {
                // Policy never answers a question: only a person does.
                None
            } else if let Some((_, option_id)) = &full_access {
                Some(option_id.clone())
            } else {
                chat_option.clone().or(auto)
            };
            let permission_id = uuid::Uuid::now_v7().to_string();
            if let Some(option_id) = auto {
                if option_kind(&options, &option_id) == Some("allow_always") {
                    session.floor.harness_grant.store(true, Ordering::SeqCst);
                }
                let mut record = json!({"permissionId": permission_id, "policy": policy.to_string(), "rule": rule.map(|r| format!("{r:?}").to_lowercase()), "optionId": option_id, "chatAllowance": chat_option.is_some() && full_access.is_none(), "request": request});
                // The mode that answered it, for the transcript's "Approved: … (Full access)".
                if let Some((mode, _)) = &full_access {
                    record.set("fullAccess", json!(mode));
                    tracing::info!(session = %session.id, %mode, "full access approved a request the harness raised");
                }
                self.append(session, "mux", "permission_auto", record);
                return json!({"outcome": {"outcome": "selected", "optionId": option_id}});
            }
            // No safe rejection option means cancel, never fall through to an allow ask.
            if denied {
                self.append(session,"mux","permission_auto",json!({"permissionId":permission_id,"policy":policy.to_string(),"request":request,"cancelled":true}));
                return json!({"outcome":{"outcome":"cancelled"}});
            }
            let (tx, rx) = oneshot::channel();
            let grouping = if super::permission_groups::eligible(&request) && turn_id.is_some() {
                match state.register(
                    &permission_id,
                    &request,
                    turn_id.clone(),
                    epoch,
                    std::time::Instant::now(),
                ) {
                    Ok(g) => Some(g),
                    Err(error) => {
                        self.append(session,"mux","permission_auto",json!({"permissionId":permission_id,"request":request,"cancelled":true,"reason":error.message}));
                        return json!({"outcome":{"outcome":"cancelled"}});
                    }
                }
            } else {
                None
            };
            let decision_nonce = super::person::new_nonce();
            let prev = session.status();
            state.pending.insert(
                permission_id.clone(),
                PendingPermission {
                    // Who asked: acpmux itself (Grok's, Cursor's asks) or the agent.
                    ancestor_may_answer: super::questions::ancestor_answerable(
                        &request,
                        agent_request_id.is_some(),
                    ),
                    request: request.clone(),
                    reply: tx,
                    decision_nonce: decision_nonce.clone(),
                    prev_status: prev,
                    agent_request: agent_request_id.cloned(),
                    agent_host_incarnation: agent_host_incarnation.map(str::to_owned),
                },
            );
            self.append(session,"mux","permission_request",json!({"permissionId":permission_id,"decisionNonce":decision_nonce,"personInstance":self.person.instance(),"request":request,"groupId":grouping.as_ref().map(|(id,_)|id),"turnId":turn_id,"agentRequestId":agent_request_id,"remoteFloor":floored}));
            self.background_attention(session);
            self.set_status(session, SessionStatus::Waiting);
            (rx, prev, grouping, permission_id)
        };
        // Joined its group (or none): the group's timer need not wait for it.
        drop(ask);
        if let Some((id, true)) = grouping {
            self.start_permission_group_timer(session, id);
        }
        let mut outcome = rx.await.unwrap_or_else(|_| json!({"outcome":"cancelled"}));
        // An ancestor's answer: written under its fence (`subsession_answer.rs`).
        if let Some(fence) = self.answer_fences.lock().unwrap().remove(&permission_id) {
            keep_answer_fence(fence);
        }
        // Who answered for the person (`hub/person.rs` answered_by): audit
        // only, never sent to the agent.
        let answered_by = outcome.as_object_mut().and_then(|o| o.remove(ANSWERED_BY_SLOT));
        self.settle_permission(session, &permission_id, outcome.clone(), answered_by, prev);
        let mut out = json!({"outcome": outcome});
        if let Some(m) = out["outcome"].get("_meta").cloned() {
            out.set("_meta", m);
            if let Some(o) = out["outcome"].as_object_mut() {
                o.remove("_meta");
            }
        }
        out
    }

    /// Logs the answer `outcome` to the prompt `permission_id` (the record the chat drops its
    /// card on) and, once the session asks nothing else, takes back its Waiting status
    /// (`status_after_ask` from `prev`, the status before the prompt). Every prompt this process
    /// raised ends here, also a trust card withdrawn without its task (`trust_wait.rs`).
    pub(super) fn settle_permission(
        &self,
        session: &Session,
        permission_id: &str,
        outcome: Value,
        answered_by: Option<Value>,
        prev: SessionStatus,
    ) {
        let mut decision = json!({"permissionId": permission_id, "outcome": outcome});
        if let Some(by) = answered_by {
            decision.set("answeredBy", by);
        }
        self.append(session, "mux", "permission_decision", decision.clone());
        let mut state = session.permissions.lock().unwrap_or_else(|e| e.into_inner());
        state.settled.remember(permission_id, decision.get("answeredBy"), &decision["outcome"]);
        if state.pending.is_empty()
            && session.status() == SessionStatus::Waiting
            && !self.secrets.waiting_in(&session.id)
        {
            self.set_status(session, status_after_ask(session, prev));
        }
    }

    /// Answer a pending permission. `option_id = None` cancels. `answers`
    /// carries user input for interactive tools (AskUserQuestion), keyed by
    /// question text.
    pub async fn respond_permission(
        &self,
        session: &Session,
        permission_id: &str,
        option_id: Option<String>,
        answers: Option<Value>,
        answered_by: Option<Value>,
        answerer: super::person::Answerer<'_>,
        control: Control,
    ) -> Result<(), RpcError> {
        self.respond_permission_annotated(
            session,
            permission_id,
            option_id,
            answers,
            None,
            answered_by,
            answerer,
            control,
        )
        .await
    }

    /// `respond_permission` with a question's `annotations` (the chosen
    /// preview and notes, `questions::check_annotations`): only the person's
    /// own answer carries them, or a relayed one under the person's decision
    /// proof over them (`person/decision_answers.rs`); never a phone's signed
    /// one (its signature covers the answers alone) or a session's.
    pub async fn respond_permission_annotated(
        &self,
        session: &Session,
        permission_id: &str,
        option_id: Option<String>,
        answers: Option<Value>,
        annotations: Option<Value>,
        answered_by: Option<Value>,
        answerer: super::person::Answerer<'_>,
        control: Control,
    ) -> Result<(), RpcError> {
        // The Web's asking rule, checked here at the answer, where its option
        // and proof are known (`Hub::web_answer_check`); the prompt's own
        // checks below run again under its lock.
        if control == Control::Web {
            let (narrows, proved) = {
                let state = session.permissions.lock().unwrap_or_else(|e| e.into_inner());
                state.pending.get(permission_id).map_or((false, false), |p| {
                    let options = p.request["options"].as_array().map_or(&[][..], Vec::as_slice);
                    let narrows = option_id.as_deref().is_none_or(|o| {
                        matches!(option_kind(options, o), Some("reject_once" | "reject_always"))
                    });
                    let (proved, signed) = self.answer_proof(
                        session,
                        permission_id,
                        p,
                        option_id.as_deref(),
                        answers.as_ref(),
                        annotations.as_ref(),
                        answered_by.is_some(),
                        &answerer,
                    );
                    (narrows, proved || signed)
                })
            };
            self.web_answer_check(session, control, narrows, proved)?;
        }
        let cfg = self.config.read().await;
        let (pending, answered_by, annotations) = {
            let mut guard = session.permissions.lock().unwrap_or_else(|e| e.into_inner());
            let state = &mut *guard;
            let map = &mut state.pending;
            // Answered already: the first answer won, and this one is told who gave it and how.
            let p = map.get(permission_id).ok_or_else(|| {
                let lost = RpcError::not_found(format!("no pending permission {permission_id}"));
                match state.settled.lost(permission_id) {
                    Some(data) => lost.with_data(data),
                    None => lost,
                }
            })?;
            // A question's annotations, after the lookup so a losing answer still learns who
            // won: only the person's own answer, or one with the person's decision proof (which
            // must cover them, below), and only beside its answers.
            if annotations.is_some() && !answerer.person && answerer.decision.is_none() {
                return Err(super::person::person_required("annotations"));
            }
            if annotations.is_some() && answers.is_none() {
                return Err(RpcError::invalid_params("annotations go only with answers"));
            }
            // Legacy clients may answer items in a group, but cannot bypass
            // a policy edit or choose an absent/ambiguous option.
            if let Some(o) = &option_id {
                let offered: Vec<_> = p.request["options"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter(|x| x["optionId"] == *o)
                    .collect();
                if offered.len() != 1 {
                    return Err(RpcError::invalid_params(format!(
                        "option {o:?} was not uniquely offered for permission {permission_id}"
                    )));
                }
                let kind = offered[0]["kind"].as_str();
                // A Web answer allows once or denies once: never a lasting grant.
                if control == Control::Web && !matches!(kind, Some("allow_once" | "reject_once")) {
                    return Err(super::web_control::lasting_grant_refused(kind.unwrap_or("?")));
                }
                let is_reject = matches!(kind, Some("reject_once" | "reject_always"));
                // A remote browser cannot trust a folder on this machine
                // (`acp.trust.set` is refused for it too, `remote_guard.rs`).
                if control == Control::Web
                    && !is_reject
                    && super::questions::trust_cwd(&p.request).is_some()
                {
                    return Err(RpcError::invalid_params(
                        "trust.web_cannot_answer: trust the folder in the app or the CLI",
                    )
                    .with_data(json!({"reason": "trust.web_cannot_answer"})));
                }
                let denied = self.policy_for(session, cfg.permission_policy)
                    == PermissionPolicy::DenyAll
                    || session
                        .meta()
                        .permission_rules
                        .as_ref()
                        .and_then(|r| super::rules::decide(r, &p.request))
                        == Some(super::rules::RuleDecision::Deny);
                if !is_reject && denied {
                    return Err(RpcError::new(-32000, "policy_changed")
                        .with_data(json!({"reason":"policy_changed"})));
                }
                if kind == Some("allow_always") {
                    session.floor.harness_grant.store(true, Ordering::SeqCst);
                }
            }
            super::questions::check_reply(&p.request, option_id.as_deref(), answers.as_ref())?;
            let checked_annotations = match &annotations {
                Some(a) => super::questions::check_annotations(&p.request, a)?,
                None => None,
            };
            // The authoritative person rule (`person.rs`), here under the
            // prompt's lock, whatever the request check saw: a client that
            // is not the person may cancel or reject; an allow, or who
            // answered, needs the person's decision proof for this very
            // prompt, which is checked again and spent with the answer.
            if !answerer.person {
                let rejects = option_id.as_ref().is_some_and(|o| {
                    p.request["options"].as_array().into_iter().flatten().any(|x| {
                        x["optionId"] == *o
                            && matches!(x["kind"].as_str(), Some("reject_once" | "reject_always"))
                    })
                });
                let allows = option_id.is_some() && !rejects;
                // An ancestor session's answer to a question
                // (`subsession_answer.rs`): answers to a prompt recorded as a
                // question when it was asked (`questions::ancestor_answerable`,
                // never from its input's shape), with its one-time allow and
                // the hub's own `answeredBy`; never a permission prompt, a
                // lasting grant or a plan.
                let ancestor_answers = answerer.ancestor.is_some()
                    && answered_by.is_some()
                    && answers.is_some()
                    && p.ancestor_may_answer
                    && super::questions::trust_cwd(&p.request).is_none()
                    && option_id.as_deref().is_some_and(|o| {
                        option_kind(p.request["options"].as_array().map_or(&[], Vec::as_slice), o)
                            == Some("allow_once")
                    });
                let needs_proof = (allows || answered_by.is_some()) && !ancestor_answers;
                // Annotations from a connection that is not the person count only under the
                // person's proof over them, so never on a reject or an ancestor's answer.
                if annotations.is_some() && !needs_proof {
                    return Err(super::person::person_required("annotations"));
                }
                if needs_proof {
                    let (proved, signed) = self.answer_proof(
                        session,
                        permission_id,
                        p,
                        option_id.as_deref(),
                        answers.as_ref(),
                        annotations.as_ref(),
                        answered_by.is_some(),
                        &answerer,
                    );
                    // A phone's signature counts only while its phone is still enrolled, checked
                    // again as the nonce is spent (`approver_spends`: lock order there).
                    let spent = (proved
                        && answerer.decision.is_some_and(|(n, _)| self.person.spend_decision(n)))
                        || (signed
                            && option_id.as_deref().zip(answerer.approver).is_some_and(
                                |(o, (n, d))| {
                                    self.person.approver_spends(
                                        &session.id,
                                        permission_id,
                                        &p.request,
                                        o,
                                        n,
                                        answers.as_ref(),
                                        d,
                                    )
                                },
                            ));
                    if !spent {
                        return Err(super::person::person_required("allowing a permission"));
                    }
                }
            }
            let p = map.remove(permission_id).unwrap();
            // An ancestor's answer that won: its fence goes to the asking task, which writes it
            // (`ANSWER_FENCE`), here under the prompt's lock, where it won, so a losing answer
            // never takes it away (review 81 of #23322).
            if let Some(fence) = answerer.fence {
                self.answer_fences.lock().unwrap().insert(permission_id.to_owned(), fence.clone());
            }
            // A person's answer names them beside any device (`author.rs`), after the person
            // rule above, which it never satisfies.
            let answered_by = crate::author::answered_by(answered_by, answerer.author);
            let decided = match &option_id {
                Some(o) => json!({"outcome": "selected", "optionId": o}),
                None => json!({"outcome": "cancelled"}),
            };
            // Told to a later answer at once, before the asking task logs the decision.
            state.settled.remember(permission_id, answered_by.as_ref(), &decided);
            if let Some(group) = state.finish_item(&session.id, permission_id, option_id.is_none())
            {
                self.append(session, "mux", "permission_group", json!({"group":group}));
            }
            (p, answered_by, checked_annotations)
        };
        let mut outcome = match option_id {
            Some(o) => json!({"outcome": "selected", "optionId": o}),
            None => json!({"outcome": "cancelled"}),
        };
        if let Some(a) = answers {
            let mut input =
                pending.request.pointer("/toolCall/rawInput").cloned().unwrap_or(json!({}));
            input.set("answers", a);
            if let Some(notes) = annotations {
                input.set("annotations", notes);
            }
            outcome.set("_meta", json!({"updatedInput": input}));
        }
        if let Some(by) = answered_by {
            outcome[ANSWERED_BY_SLOT] = by;
        }
        // The asking task is gone: nothing writes the answer, so its fence is cut.
        if pending.reply.send(outcome).is_err()
            && let Some(fence) = answerer.fence
        {
            self.answer_fences.lock().unwrap().remove(permission_id);
            fence.cut();
        }
        Ok(())
    }

    pub(super) fn register_agent_request(
        &self,
        session: &Session,
        agent_request: &Id,
        host_incarnation: Option<&str>,
    ) {
        let key = super::permission_groups::AgentRequestKey::new(host_incarnation, agent_request);
        let mut state = session.permissions.lock().unwrap_or_else(|e| e.into_inner());
        state.active_requests.insert(key);
    }

    pub(super) fn finish_agent_request(
        &self,
        session: &Session,
        agent_request: &Id,
        host_incarnation: Option<&str>,
    ) {
        let key = super::permission_groups::AgentRequestKey::new(host_incarnation, agent_request);
        let mut state = session.permissions.lock().unwrap_or_else(|e| e.into_inner());
        state.active_requests.remove(&key);
        state.cancelled_requests.remove(&key);
    }

    /// Withdraw the pending prompt raised by one agent request. Cancellation
    /// markers are retained only while the matching request task is active,
    /// so late or duplicate notifications cannot grow process memory.
    pub(super) fn withdraw_permission(
        &self,
        session: &Session,
        host_incarnation: Option<&str>,
        agent_request: &Value,
    ) {
        let key = super::permission_groups::AgentRequestKey::new(host_incarnation, agent_request);
        let withdrawn = {
            let mut state = session.permissions.lock().unwrap_or_else(|e| e.into_inner());
            let id = state
                .pending
                .iter()
                .find(|(_, p)| {
                    p.agent_request.as_ref() == Some(agent_request)
                        && p.agent_host_incarnation.as_deref() == host_incarnation
                })
                .map(|(id, _)| id.clone());
            let Some(id) = id else {
                if state.active_requests.contains(&key) {
                    state.cancelled_requests.insert(key);
                }
                return;
            };
            state.settled.remember(&id, None, &json!({"outcome": "cancelled"}));
            if let Some(group) = state.finish_item(&session.id, &id, true) {
                self.append(session, "mux", "permission_group", json!({"group": group}));
            }
            state.pending.remove(&id)
        };
        if let Some(p) = withdrawn {
            let _ = p.reply.send(json!({"outcome": "cancelled"}));
        }
    }

    pub(super) fn cancel_pending_permissions(&self, session: &Session) {
        let drained: Vec<_> = {
            let mut state = session.permissions.lock().unwrap_or_else(|e| e.into_inner());
            session.permission_epoch.fetch_add(1, Ordering::SeqCst);
            state.active_requests.clear();
            state.cancelled_requests.clear();
            let drained: Vec<_> = state.pending.drain().collect();
            for (id, _) in &drained {
                // Told to a later answer at once (`permission_settled.rs`): no one answered.
                state.settled.remember(id, None, &json!({"outcome": "cancelled"}));
                if let Some(group) = state.finish_item(&session.id, id, true) {
                    self.append(session, "mux", "permission_group", json!({"group":group}));
                }
            }
            drained
        };
        for (_, p) in drained {
            let _ = p.reply.send(json!({"outcome": "cancelled"}));
        }
        // A secret card waits on the same turn (`secrets.rs`).
        self.cancel_pending_secrets(session);
    }
}

/// `policy`, capped while MDM forces full access off (`managed_off`): approve-all, the policy form
/// of full access, runs as `ask` (`Hub::approve_all_allowed`).
fn capped_policy(policy: PermissionPolicy, managed_off: bool) -> PermissionPolicy {
    if managed_off && super::full_access_bound::policy_is_full_access(policy) {
        return PermissionPolicy::Ask;
    }
    policy
}

/// The Full access mode chat `m` runs in now: its current mode, when the shared rule
/// (`spec/full-access-modes.json`, `start_mode::is_full_access`) names it full access and cmux set
/// it itself (`SessionMeta::mode_set_by_cmux`: the person's pick or start mode, never a mode the
/// harness reported on its own, `trust_wait.rs` `full_access_by_cmux`).
fn full_access_mode(m: &SessionMeta) -> Option<String> {
    let mode = crate::web_modes::mode_of(m)?;
    (m.mode_set_by_cmux.as_deref() == Some(mode.as_str())
        && super::start_mode::is_full_access(&mode))
    .then_some(mode)
}

/// The Full access mode and the one-time allow with which a chat in Full access answers `request`
/// unasked (Leo, 2026-10-25, on what Claude Code still asks in bypassPermissions, such as
/// "Dangerous rm operation on statically-unresolvable target": "i think it should... idk like if
/// it is on bypass permissions, that's not auto"): bypass means no prompts, for the harness's own
/// guards and plain tool approvals alike. Only a plain tool ask (`plain_tool_ask`: never a
/// question, a plan approval or a folder-trust card, which stay the person's), only while the
/// current mode is Full access (a chat switched out of it asks again from its next request), and
/// only with a one-time allow: never an "always" option, which writes a rule. The caller keeps
/// deny-all, rules and Web turns ahead of it.
fn full_access_allow(session: &Session, request: &Value) -> Option<(String, String)> {
    if !super::permission_groups::plain_tool_ask(request) {
        return None;
    }
    let mode = full_access_mode(&session.meta())?;
    Some((mode, super::permission_groups::option(request, "allow_once")?))
}

/// The kind of the offered option `id`.
impl Hub {
    /// Whether `answerer`'s answer `option` to the pending prompt `p` carries
    /// the person's decision proof (`.0`), or else an enrolled approver's
    /// signature (`.1`, `approvers.rs`: it covers the answers, never
    /// `answeredBy` or annotations), that counts now. Nothing is spent: the answer that
    /// counts spends the nonce under the prompt's lock.
    #[allow(clippy::too_many_arguments)]
    fn answer_proof(
        &self,
        session: &Session,
        permission_id: &str,
        p: &PendingPermission,
        option: Option<&str>,
        answers: Option<&Value>,
        annotations: Option<&Value>,
        answered_by: bool,
        answerer: &super::person::Answerer<'_>,
    ) -> (bool, bool) {
        let proved = match (option, answerer.decision) {
            (Some(o), Some((nonce, proof))) => {
                cmux_local_auth::tokens_match(nonce, &p.decision_nonce)
                    && self.person.decision_proves(
                        &session.id,
                        permission_id,
                        o,
                        nonce,
                        answers,
                        annotations,
                        proof,
                    )
            }
            _ => false,
        };
        let signed = !proved
            && !answered_by
            && annotations.is_none()
            && match (option, answerer.approver) {
                (Some(o), Some((nonce, decision))) => {
                    cmux_local_auth::tokens_match(nonce, &p.decision_nonce)
                        && self.person.approver_proves(
                            &session.id,
                            permission_id,
                            &p.request,
                            o,
                            nonce,
                            answers,
                            decision,
                        )
                }
                _ => false,
            };
        (proved, signed)
    }
}

fn option_kind<'a>(options: &'a [Value], id: &str) -> Option<&'a str> {
    options
        .iter()
        .find(|o| o.get("optionId").and_then(Value::as_str) == Some(id))
        .and_then(|o| o.get("kind").and_then(Value::as_str))
}

/// Whether a permission outcome selected an allow option.
fn outcome_allows(outcome: &Value) -> bool {
    outcome
        .pointer("/outcome/optionId")
        .and_then(Value::as_str)
        .map(|o| o.starts_with("allow"))
        .unwrap_or(false)
}

/// `path` with `.` and `..` resolved lexically (`..` at the root stays there).
fn normalize_path(path: &std::path::Path) -> std::path::PathBuf {
    use std::path::Component;
    let mut out = std::path::PathBuf::new();
    for part in path.components() {
        match part {
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            other => out.push(other.as_os_str()),
        }
    }
    out
}

/// Whether a request that arrived during turn `then` (None: between turns) is
/// stale: another turn runs now, and the request must not join its ask. A turn
/// that only ended keeps it (cx-jo8yo): subagents and background shells outlive
/// their turn and still ask, often in the moment between the harness's end of
/// turn and acpmux's. A cancel bumps `permission_epoch`, and the remote floor
/// still judges a request after a Web turn by that turn (`web_turn`).
pub(super) fn stale_turn(session: &Session, then: &Option<String>) -> bool {
    // A turn the remote floor cancelled stays cancelled for every request
    // from it, also after it ended and a local client restored an asking mode.
    if then.is_some()
        && *session.floor.floor_cancelled_turn.lock().unwrap_or_else(|e| e.into_inner()) == *then
    {
        return true;
    }
    session.turn().is_some_and(|now| Some(&now.turn_id) != then.as_ref())
}

/// The status of a chat whose last ask (a permission or a secret) was just
/// answered, from `prev`, its status when that ask came: running in a turn,
/// ready between turns (an ask that outlived its turn), else as it was.
pub(super) fn status_after_ask(session: &Session, prev: SessionStatus) -> SessionStatus {
    match (session.turn().is_some(), prev) {
        (true, _) => SessionStatus::Running,
        (false, SessionStatus::Running | SessionStatus::Waiting) => SessionStatus::Ready,
        (false, prev) => prev,
    }
}

/// Takes back one count of a full-access report the inbound loop applied
/// (`FloorState::unapplied_full_access`); the caller holds the session's meta lock.
pub(super) fn settle_full_access_report(session: &Session) {
    let _ =
        session
            .floor
            .unapplied_full_access
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |n| n.checked_sub(1));
}

/// How long a stderr line the tail keeps is (the event log keeps the same cut).
const STDERR_LINE_CAP: usize = 4000;

/// Keeps cleaned stderr line `clean` (`Session::stderr_stream`) in the session's tail, which
/// explains a failed start or exit. A line that is empty once cleaned (a terminal reset, a string
/// control's payload) never evicts an explanation.
fn remember_stderr(tail: &mut std::collections::VecDeque<String>, clean: &str) {
    if clean.is_empty() {
        return;
    }
    if tail.len() >= 6 {
        tail.pop_front();
    }
    tail.push_back(short_text(clean, STDERR_LINE_CAP));
}

#[cfg(test)]
mod stderr_tests {
    /// Each raw line through one session's stream into its tail, as `Inbound::Stderr` does.
    fn feed(lines: &[String]) -> Vec<String> {
        let mut stream = crate::hub::session::SessionStderr::default();
        let mut tail = std::collections::VecDeque::new();
        for line in lines {
            super::remember_stderr(
                &mut tail,
                &stream.clean_line((1, crate::agent::StderrPipe::Stderr), line),
            );
        }
        tail.into_iter().collect()
    }

    #[test]
    fn a_long_payload_neither_grows_the_tail_nor_hides_later_lines() {
        let mut lines = vec!["\x1bPstart".to_owned()];
        lines.extend(std::iter::repeat_n("A".repeat(4096), 1000));
        lines.push(format!("{}\x1b\\", "B".repeat(5000)));
        lines.push("error: request timed out".to_owned());
        assert_eq!(feed(&lines), vec!["error: request timed out"]);
    }

    #[test]
    fn a_long_line_keeps_the_control_it_ends_in() {
        // The opener sits past where the tail cuts a line: the lines after it are still payload.
        let lines = [
            format!("{} \x1b]8;;https://x", "w".repeat(4100)),
            "leaked payload".to_owned(),
            "end\x07error: request timed out".to_owned(),
        ];
        let tail = feed(&lines);
        assert!(tail.iter().all(|line| !line.contains("leaked")), "{tail:?}");
        assert_eq!(tail.last().map(String::as_str), Some("error: request timed out"));
        // A DCS closed and an OSC opened late in a long line: a BEL on the next line ends the OSC.
        let lines = [
            format!("\x1bP{}\x1b\\\x1b]title", "d".repeat(5000)),
            "\x07error: request timed out".to_owned(),
        ];
        assert_eq!(feed(&lines), vec!["error: request timed out"]);
    }

    #[test]
    fn a_turn_boundary_keeps_the_open_control() {
        // The tail is cleared at each turn; the stream is not, so a payload that runs into the
        // next turn stays hidden.
        let mut stream = crate::hub::session::SessionStderr::default();
        let mut tail = std::collections::VecDeque::new();
        super::remember_stderr(
            &mut tail,
            &stream.clean_line((1, crate::agent::StderrPipe::Stderr), "\x1bPsecret"),
        );
        tail.clear();
        super::remember_stderr(
            &mut tail,
            &stream.clean_line((1, crate::agent::StderrPipe::Stderr), "leaked payload"),
        );
        super::remember_stderr(
            &mut tail,
            &stream.clean_line(
                (1, crate::agent::StderrPipe::Stderr),
                "\x1b\\error: request timed out",
            ),
        );
        assert_eq!(tail.into_iter().collect::<Vec<_>>(), vec!["error: request timed out"]);
    }

    #[test]
    fn an_old_agents_late_line_keeps_its_open_control_however_many_agents_followed() {
        let mut stream = crate::hub::session::SessionStderr::default();
        let mut tail = std::collections::VecDeque::new();
        super::remember_stderr(
            &mut tail,
            &stream.clean_line((1, crate::agent::StderrPipe::Stderr), "\x1bPsecret"),
        );
        for generation in 2..10 {
            super::remember_stderr(
                &mut tail,
                &stream.clean_line((generation, crate::agent::StderrPipe::Stderr), "ok"),
            );
        }
        super::remember_stderr(
            &mut tail,
            &stream.clean_line((1, crate::agent::StderrPipe::Stderr), "late payload"),
        );
        assert!(tail.iter().all(|line| !line.contains("payload")), "{tail:?}");
        // Its open control lasts until its own terminator, even after it exited.
        assert_eq!(stream.clean_line((1, crate::agent::StderrPipe::Stderr), "\x1b\\done"), "done");
    }

    #[test]
    fn many_agents_left_inside_a_control_never_free_an_older_ones_state() {
        let mut stream = crate::hub::session::SessionStderr::default();
        let err = |generation| (generation, crate::agent::StderrPipe::Stderr);
        for generation in 1..200 {
            assert_eq!(stream.clean_line(err(generation), "\x1bPsecret"), "");
        }
        assert_eq!(stream.clean_line(err(1), "late payload"), "");
        assert_eq!(stream.clean_line(err(1), "\x1b\\shown"), "shown");
    }

    #[test]
    fn an_agents_stdout_notes_are_their_own_stream() {
        let mut stream = crate::hub::session::SessionStderr::default();
        let out = (1, crate::agent::StderrPipe::Stdout);
        let err = (1, crate::agent::StderrPipe::Stderr);
        assert_eq!(stream.clean_line(out, "[non-json stdout] \x1bPsecret"), "[non-json stdout]");
        assert_eq!(stream.clean_line(err, "error: on stderr"), "error: on stderr");
        assert_eq!(stream.clean_line(out, "[non-json stdout] more payload"), "");
        assert_eq!(stream.clean_line(out, "[non-json stdout] \x1b\\shown"), "shown");
    }

    #[test]
    fn a_new_agent_starts_a_new_stream() {
        // The old agent left a control open; the agent that replaced it starts clean, and a late
        // line of the old one stays in the old one's stream.
        let mut stream = crate::hub::session::SessionStderr::default();
        let mut tail = std::collections::VecDeque::new();
        super::remember_stderr(
            &mut tail,
            &stream.clean_line((1, crate::agent::StderrPipe::Stderr), "\x1bPsecret"),
        );
        super::remember_stderr(
            &mut tail,
            &stream.clean_line((2, crate::agent::StderrPipe::Stderr), "error: request timed out"),
        );
        super::remember_stderr(
            &mut tail,
            &stream.clean_line((1, crate::agent::StderrPipe::Stderr), "late payload"),
        );
        assert_eq!(tail.into_iter().collect::<Vec<_>>(), vec!["error: request timed out"]);
    }

    #[test]
    fn stderr_resets_do_not_evict_the_explanation() {
        let mut lines = vec!["\x1b[31mERROR failed to refresh models\x1b[0m".to_owned()];
        lines.extend(std::iter::repeat_n("\x1b[0m".to_owned(), 8));
        assert_eq!(feed(&lines), vec!["failed to refresh models"]);
    }
}

//! Part of `Hub`; see `hub/mod.rs`.

use super::*;
use std::sync::atomic::Ordering;

impl Hub {
    // --------------------------------------------------------------- turns

    /// Run one prompt turn. Waits for any running turn unless `steer` is set
    /// and the agent supports steering. Returns the agent's prompt response.
    pub async fn prompt(
        self: &Arc<Self>,
        session: &Arc<Session>,
        blocks: Vec<Value>,
        client: &str,
        steer: bool,
    ) -> Result<Value, RpcError> {
        self.prompt_with(session, blocks, client, steer, PromptOptions::default()).await
    }

    /// `prompt` with a client prompt id and an acceptance callback. The
    /// response gains `_meta.acpmux {promptId, turnId, turnSeq}` next to the
    /// agent's own `_meta`.
    ///
    /// A client prompt id is run once: the same id again (a resend after the
    /// connection closed) answers with the first run's outcome, marked
    /// `_meta.acpmux.duplicate`, waiting for it when it is still running.
    pub async fn prompt_with(
        self: &Arc<Self>,
        session: &Arc<Session>,
        blocks: Vec<Value>,
        client: &str,
        steer: bool,
        mut opts: PromptOptions,
    ) -> Result<Value, RpcError> {
        let Some(prompt_id) = opts.prompt_id.clone() else {
            return self.run_prompt(session, blocks, client, steer, opts).await;
        };
        let duplicate = |v: Value| json!({"sessionId": session.id, "promptId": prompt_id, "duplicate": true, "queued": false, "turnId": v.pointer("/_meta/acpmux/turnId")});
        let seen = {
            let mut ledger = session.prompts.lock().unwrap();
            match ledger.iter().find(|(id, _)| *id == prompt_id) {
                Some((_, outcome)) => Err(outcome.subscribe()),
                None => {
                    let outcome = Arc::new(tokio::sync::watch::channel(None).0);
                    ledger.push_back((prompt_id.clone(), outcome.clone()));
                    if ledger.len() > PROMPT_LEDGER {
                        ledger.pop_front();
                    }
                    Ok(outcome)
                }
            }
        };
        let outcome = match seen {
            Err(mut first) => {
                if let Some(f) = opts.on_accepted.take() {
                    f(duplicate(Value::Null));
                }
                let result = first
                    .wait_for(Option::is_some)
                    .await
                    .map_err(|_| RpcError::internal("the first run of this prompt was dropped"))?
                    .clone()
                    .expect("waited for an outcome");
                return result.map(|mut v| {
                    merge_mux_meta(&mut v, json!({"duplicate": true}));
                    v
                });
            }
            Ok(outcome) => outcome,
        };
        if opts.resend
            && let Some(logged) = self.logged_prompt(session, &prompt_id)
        {
            if let Some(f) = opts.on_accepted.take() {
                f(duplicate(logged.clone()));
            }
            outcome.send_replace(Some(Ok(logged.clone())));
            return Ok(logged);
        }
        // Remember the outcome only for a prompt that reached the session:
        // one refused before that (no agent, a bad session) may be sent again.
        let accepted = Arc::new(AtomicBool::new(false));
        if let Some(f) = opts.on_accepted.take() {
            let accepted = accepted.clone();
            opts.on_accepted = Some(Box::new(move |v| {
                accepted.store(true, Ordering::SeqCst);
                f(v);
            }));
        } else {
            let accepted = accepted.clone();
            opts.on_accepted = Some(Box::new(move |_| accepted.store(true, Ordering::SeqCst)));
        }
        let result = self.run_prompt(session, blocks, client, steer, opts).await;
        if !accepted.load(Ordering::SeqCst) {
            session.prompts.lock().unwrap().retain(|(id, _)| *id != prompt_id);
        }
        outcome.send_replace(Some(result.clone()));
        result
    }

    /// A prompt id the session's log already holds (`user_message` or
    /// `queued`), answered from the log: its turn's result when it ended,
    /// else `interrupted` (the daemon stopped during the turn).
    fn logged_prompt(&self, session: &Session, prompt_id: &str) -> Option<Value> {
        let last = session.meta().last_turn;
        if let Some(last) =
            last.filter(|l| l.get("promptId").and_then(Value::as_str) == Some(prompt_id))
        {
            return Some(json!({
                "stopReason": last.get("stopReason").cloned().unwrap_or(Value::Null),
                "_meta": {"acpmux": {"promptId": prompt_id, "turnId": last.get("turnId"), "status": last.get("status"), "duplicate": true}},
            }));
        }
        let mut turn_id: Option<String> = None;
        let mut ended: Option<Value> = None;
        let _ = self.store.scan(&session.id, 0, &mut |rec| {
            match (rec.kind.as_str(), &turn_id) {
                ("user_message" | "queued", None)
                    if rec.msg.get("promptId").and_then(Value::as_str) == Some(prompt_id) =>
                {
                    turn_id = rec.msg.get("turnId").and_then(Value::as_str).map(str::to_owned);
                }
                ("turn_result", Some(id))
                    if rec.msg.get("turnId").and_then(Value::as_str) == Some(id) =>
                {
                    ended = Some(rec.msg);
                    return false;
                }
                _ => {}
            }
            true
        });
        let turn_id = turn_id?;
        let status = ended
            .as_ref()
            .and_then(|e| e.get("status").cloned())
            .unwrap_or_else(|| json!("interrupted"));
        Some(json!({
            "stopReason": ended.as_ref().and_then(|e| e.get("stopReason").cloned()).unwrap_or(Value::Null),
            "_meta": {"acpmux": {"promptId": prompt_id, "turnId": turn_id, "status": status, "duplicate": true}},
        }))
    }

    async fn run_prompt(
        self: &Arc<Self>,
        session: &Arc<Session>,
        mut blocks: Vec<Value>,
        client: &str,
        steer: bool,
        opts: PromptOptions,
    ) -> Result<Value, RpcError> {
        let prompt_id = opts.prompt_id.unwrap_or_else(|| uuid::Uuid::now_v7().to_string());
        let control = opts.control;
        let trust_gate = opts.trust_gate;
        let mut on_accepted = opts.on_accepted;
        let mut accept = |v: Value| {
            if let Some(f) = on_accepted.take() {
                f(v);
            }
        };
        // A prompt that cannot reach any agent (none running, and its harness is gone) is
        // refused before it is recorded, so a caller may send it again (handoff start).
        let live = match session.child.lock().await.as_ref() {
            Some(child) => child.is_alive().await,
            None => false,
        };
        let m = session.meta();
        if !live {
            let cfg = self.config.read().await;
            super::resolve::session_profile(&cfg, &m.harness, &m.cwd, m.remote_origin)
                .map_err(RpcError::invalid_params)?;
        }
        let text = prompt_text(&blocks);
        let running = session.turn();
        let steer_now = steer && session.steering.load(Ordering::SeqCst) && running.is_some();
        if steer && opts.steer_only && !steer_now {
            return Err(RpcError::invalid_params(
                "steer.unavailable: the session has no running turn that its agent can steer",
            )
            .with_data(json!({"reason": "steer.unavailable"})));
        }
        if steer_now {
            self.check_steer(session, control)?;
            // A running turn has a live agent.
            let child = self.child_for(session).await?;
            let agent_sid = session
                .meta()
                .agent_session_id
                .ok_or_else(|| RpcError::internal("no agent session"))?;
            let turn_id = running.map(|t| t.turn_id).unwrap_or_default();
            self.append(
                session,
                "mux",
                "user_message",
                json!({"text": text, "steer": true, "client": client, "promptId": prompt_id, "turnId": turn_id}),
            );
            accept(
                json!({"sessionId": session.id, "promptId": prompt_id, "turnId": turn_id, "queued": false, "steer": true}),
            );
            // The turn may end between this check and the agent: without
            // steerOnly the message then becomes the next prompt, as before.
            let fallback = (!opts.steer_only).then(|| blocks.clone());
            let mut params = json!({"sessionId": agent_sid, "prompt": blocks});
            params["_meta"] = json!({"steer": true});
            let mut r = match child.request(method::SESSION_PROMPT, params).await {
                Err(e) if e.message.starts_with(crate::claude_stdio::STEER_NO_TURN) => {
                    let Some(blocks) = fallback else { return Err(e) };
                    let opts = PromptOptions {
                        prompt_id: Some(prompt_id),
                        control,
                        trust_gate,
                        ..PromptOptions::default()
                    };
                    return Box::pin(self.run_prompt(session, blocks, client, false, opts)).await;
                }
                r => r?,
            };
            merge_mux_meta(
                &mut r,
                json!({"promptId": prompt_id, "turnId": turn_id, "steer": true}),
            );
            return Ok(r);
        }
        let turn_id = uuid::Uuid::now_v7().to_string();
        let waiting = session.turn().is_some() || session.queued() > 0;
        let position = session.queued.fetch_add(1, Ordering::SeqCst) + 1;
        if waiting {
            session.queue.lock().unwrap().push(QueuedPrompt {
                prompt_id: prompt_id.clone(),
                turn_id: turn_id.clone(),
                client: client.to_owned(),
                preview: short_text(&text, 200),
                queued_at: now_ms(),
            });
            // Tell every client right away; the turn itself starts when the lock frees.
            self.append(
                session,
                "mux",
                "queued",
                json!({"text": text, "client": client, "position": position, "promptId": prompt_id, "turnId": turn_id}),
            );
            accept(
                json!({"sessionId": session.id, "promptId": prompt_id, "turnId": turn_id, "queued": true, "position": position}),
            );
        }
        let guard = session.turn_lock.lock().await;
        session.queued.fetch_sub(1, Ordering::SeqCst);
        if waiting {
            session.queue.lock().unwrap().retain(|q| q.turn_id != turn_id);
            self.append(
                session,
                "mux",
                "dequeued",
                json!({"promptId": prompt_id, "turnId": turn_id, "queued": session.queued()}),
            );
        }
        if let Err(e) =
            self.check_dispatch(session, control, trust_gate, &prompt_id, &turn_id, client).await
        {
            drop(guard);
            return Err(e);
        }
        {
            let mut m = session.meta.lock().unwrap();
            m.last_prompt = Some(short_text(&text, 200));
            if m.title.is_none() {
                let first = text.lines().find(|l| !l.trim().is_empty()).unwrap_or("").trim();
                if !first.is_empty() {
                    m.title = Some(short_text(first, 80));
                }
            }
            m.preview = Some(String::new());
            m.turn_count += 1;
        }
        *session.turn.lock().unwrap() = Some(TurnInfo {
            started_at: now_ms(),
            client: client.to_owned(),
            prompt_preview: short_text(&text, 200),
            turn_id: turn_id.clone(),
            prompt_id: prompt_id.clone(),
            turn_seq: 0,
            control,
        });
        session.floor.last_turn_web.store(control == Control::Web, Ordering::SeqCst);
        self.reset_stream(session);
        self.append(
            session,
            "mux",
            "user_message",
            json!({"text": text, "client": client, "promptId": prompt_id, "turnId": turn_id}),
        );
        if !waiting {
            accept(
                json!({"sessionId": session.id, "promptId": prompt_id, "turnId": turn_id, "queued": false}),
            );
        }
        // The prompt is recorded and acknowledged above before the agent is started again (it
        // died, or the daemon restarted), so a client hears prompt_accepted at once.
        let started = match self.child_for(session).await {
            Ok(child) => session
                .meta()
                .agent_session_id
                .map(|sid| (child, sid))
                .ok_or_else(|| RpcError::internal("no agent session")),
            Err(e) => Err(e),
        };
        let (child, agent_sid) = match started {
            Ok(started) => started,
            Err(e) => {
                self.fail_unstarted_turn(session, &prompt_id, &turn_id, &e);
                drop(guard);
                return Err(e);
            }
        };
        // A Web steer while the agent started made this a Web turn.
        let control = session.turn().map_or(control, |t| t.control);
        // Starting the agent may have changed its mode (a spawn, a resume, a
        // pool claim, a replayed config): checked again before the prompt.
        if let Err(e) =
            self.check_dispatch(session, control, trust_gate, &prompt_id, &turn_id, client).await
        {
            self.refuse_started_turn(session, &prompt_id, &turn_id, &e);
            drop(guard);
            return Err(e);
        }
        if session.rehydrate.swap(false, Ordering::SeqCst)
            && let Some(transcript) = self.transcript(session, 24_000)
        {
            blocks.insert(
                    0,
                    json!({"type": "text", "text": format!("<restored_transcript note=\"acpmux restored this conversation on a new agent session; tool state was not restored\">\n{transcript}\n</restored_transcript>\n")}),
                );
        }
        session.stderr_tail.lock().unwrap().clear();
        let turn_seq = self
            .append(
                session,
                "mux",
                "turn_started",
                json!({"prompt": short_text(&text, 200), "client": client, "promptId": prompt_id, "turnId": turn_id, "control": control.as_str()}),
            )
            .seq;
        let control = {
            let mut turn = session.turn.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(t) = turn.as_mut() {
                t.turn_seq = turn_seq;
            }
            turn.as_ref().map_or(control, |t| t.control)
        };
        // The remote floor fired before the prompt went out (a mode write
        // in the gap): the prompt is not sent. After this point the floor's
        // cancel reaches the agent after the prompt (`remote_floor.rs`).
        if control == Control::Web
            && let Some(reason) = self.remote_floor_breach(session)
        {
            let e = RpcError::new(-32000, "the remote floor cancelled this turn before its prompt")
                .with_data(json!({"reason": reason}));
            self.refuse_started_turn(session, &prompt_id, &turn_id, &e);
            drop(guard);
            return Err(e);
        }
        self.set_status(session, SessionStatus::Running);
        let mut result = child
            .request(
                method::SESSION_PROMPT,
                json!({"sessionId": agent_sid, "prompt": blocks.clone()}),
            )
            .await;
        // The account behind this harness is exhausted: move the session
        // onto its fallback profile (the subrouter pool for Claude), which
        // resumes the same agent session, and run the prompt once more.
        if let Err(e) = &result {
            // A pool launcher that dies on the prompt (its proxy is down)
            // moves the session too, not only a usage or auth limit.
            if (is_limit_error(&e.message) || e.message.starts_with("agent process closed"))
                && let Some(to) = self.fallback_profile(session).await
            {
                let from = session.meta().harness;
                self.append(
                    session,
                    "mux",
                    "failover",
                    json!({"from": from, "to": to, "reason": e.message, "turnId": turn_id}),
                );
                self.detach_child(session).await;
                session.meta.lock().unwrap().harness = to.clone();
                self.save_meta(session);
                let control = session.turn().map_or(control, |t| t.control);
                let fallback = self.child_for(session).await;
                let refusal = match &fallback {
                    Ok(_) => self
                        .check_dispatch(session, control, trust_gate, &prompt_id, &turn_id, client)
                        .await
                        .err(),
                    Err(_) => None,
                };
                match (fallback, refusal) {
                    // The fallback is checked as a new dispatch; its own
                    // refusal (folder trust, mode, D13) is the turn's error.
                    (Ok(_), Some(e)) => result = Err(e),
                    (Ok(child2), None) => {
                        if let Some(sid2) = session.meta().agent_session_id {
                            result = child2
                                .request(
                                    method::SESSION_PROMPT,
                                    json!({"sessionId": sid2, "prompt": blocks}),
                                )
                                .await;
                        }
                    }
                    (Err(e2), _) => result = Err(e2),
                }
            }
        }
        let ids = json!({"promptId": prompt_id, "turnId": turn_id, "turnSeq": turn_seq});
        let mut result =
            self.finish_turn(session, &child, result, &prompt_id, &turn_id, turn_seq).await;
        drop(guard);
        if let Ok(v) = &mut result {
            merge_mux_meta(v, ids);
        }
        result
    }

    /// Settle a turn once its `session/prompt` answered (or failed): record
    /// `turn_end`/`turn_error` and `turn_result`, and the session status.
    /// Also settles a turn recovered from an adopted agent host.
    pub(super) async fn finish_turn(
        self: &Arc<Self>,
        session: &Arc<Session>,
        child: &Arc<ChildAgent>,
        mut result: Result<Value, RpcError>,
        prompt_id: &str,
        turn_id: &str,
        turn_seq: u64,
    ) -> Result<Value, RpcError> {
        *session.turn.lock().unwrap() = None;
        // A turn Claude answered is in its store: a respawn resumes it.
        if result.is_ok() {
            let was_unstored = std::mem::take(&mut session.meta.lock().unwrap().claude_unstored);
            if was_unstored {
                self.save_meta(session);
            }
        }
        // Quit Everything already recorded this turn as cancelled.
        if self.settled_by_shutdown.lock().unwrap().contains(turn_id) {
            return result;
        }
        // A process that died without answering: say what it printed last.
        if let Err(e) = &mut result {
            let bare = e.message == "agent process closed"
                || e.message == "Internal error"
                || (e.code == -32603 && e.message.len() < 40);
            if bare {
                let tail: Vec<String> =
                    session.stderr_tail.lock().unwrap().iter().cloned().collect();
                // The last stderr line that is not a stack frame or a wrapper tag.
                if let Some(last) = tail.iter().rev().map(|l| l.trim()).find(|l| {
                    !l.is_empty() && !l.starts_with("at ") && !l.starts_with("[SYSTEM_ERROR]")
                }) {
                    let agent = session.meta().harness;
                    e.message = format!("{} ({agent}): {last}", e.message);
                }
            }
        }
        // A harness that reported a terminal error in-band (Codex
        // `_meta.codex.error` without willRetry) and then ended the turn
        // normally still failed it: answer the prompt with that error.
        let harness_error = session.stream.lock().unwrap().harness_error.clone();
        let harness_failure = match (&result, &harness_error) {
            (Ok(v), Some(h))
                if v.get("stopReason").and_then(Value::as_str) != Some("cancelled") =>
            {
                let text = h.get("text").and_then(Value::as_str).unwrap_or("");
                let text =
                    if text.is_empty() { "the harness reported an error" } else { text }.to_owned();
                let data = json!({"errorSource": h.get("source"), "errorCode": h.get("code"), "stopReason": v.get("stopReason")});
                Some(RpcError::new(-32000, text).with_data(data))
            }
            _ => None,
        };
        let harness_failed = harness_failure.is_some();
        if let Some(e) = harness_failure {
            result = Err(e);
        }
        match &result {
            Ok(v) => {
                self.note_reply_refusal(session);
                let stop = v.get("stopReason").cloned().unwrap_or(Value::Null);
                self.append(
                    session,
                    "mux",
                    "turn_end",
                    json!({"stopReason": stop, "turnId": turn_id, "turnSeq": turn_seq}),
                );
                let status =
                    if stop.as_str() == Some("cancelled") { "cancelled" } else { "completed" };
                let mut msg = json!({"status": status, "stopReason": stop, "turnSeq": turn_seq, "turnId": turn_id, "promptId": prompt_id});
                if let Some(o) = msg.as_object_mut() {
                    o.extend(self.turn_error_fields(session, None));
                }
                self.record_last_turn(session, &msg);
                self.append(session, "mux", "turn_result", msg);
            }
            Err(e) => {
                self.append(
                    session,
                    "mux",
                    "turn_error",
                    json!({"error": e.message, "code": e.code, "turnId": turn_id, "turnSeq": turn_seq}),
                );
                self.note_model_refusal(session, &e.message);
                let mut msg = json!({"status": "failed", "error": e.message, "code": e.code, "turnSeq": turn_seq, "turnId": turn_id, "promptId": prompt_id});
                if let Some(o) = msg.as_object_mut() {
                    let agent_error =
                        (!harness_failed).then(|| (e.message.as_str(), json!(e.code)));
                    o.extend(self.turn_error_fields(session, agent_error));
                }
                self.record_last_turn(session, &msg);
                self.append(session, "mux", "turn_result", msg);
            }
        }
        self.reset_stream(session);
        // Nobody watching: the sidebar dot and `wait --until done` see it.
        if session.attached.load(Ordering::SeqCst) == 0 {
            session.meta.lock().unwrap().unread = true;
        }
        if session.status() != SessionStatus::Closed {
            let alive = child.is_alive().await;
            self.set_status(
                session,
                if alive { SessionStatus::Ready } else { SessionStatus::Disconnected },
            );
        }
        self.save_meta(session);
        result
    }

    /// A recorded prompt whose agent could not start: the turn ends failed, so every client
    /// sees the prompt settle instead of a turn that never starts.
    /// A turn refused after it was accepted (the dispatch check again, or
    /// the remote floor): failed as an unstarted turn, the agent kept.
    fn refuse_started_turn(
        &self,
        session: &Arc<Session>,
        prompt_id: &str,
        turn_id: &str,
        e: &RpcError,
    ) {
        self.fail_unstarted_turn(session, prompt_id, turn_id, e);
        if session.status() == SessionStatus::Disconnected {
            self.set_status(session, SessionStatus::Ready);
        }
    }

    fn fail_unstarted_turn(
        &self,
        session: &Arc<Session>,
        prompt_id: &str,
        turn_id: &str,
        e: &RpcError,
    ) {
        *session.turn.lock().unwrap() = None;
        self.append(
            session,
            "mux",
            "turn_error",
            json!({"error": e.message, "code": e.code, "turnId": turn_id, "turnSeq": 0}),
        );
        let msg = json!({"status": "failed", "error": e.message, "code": e.code, "turnSeq": 0, "turnId": turn_id, "promptId": prompt_id});
        self.record_last_turn(session, &msg);
        self.append(session, "mux", "turn_result", msg);
        self.reset_stream(session);
        if session.status() != SessionStatus::Closed {
            self.set_status(session, SessionStatus::Disconnected);
        }
        self.save_meta(session);
    }

    /// Keep the outcome of the last turn on the session (`lastTurn` in the
    /// summary), so `wait` can report a failed turn after it resolves.
    fn record_last_turn(&self, session: &Session, turn_result: &Value) {
        let mut last = serde_json::Map::new();
        for k in ["turnId", "promptId", "status", "stopReason", "errorText", "errorSource"] {
            if let Some(v) = turn_result.get(k) {
                last.insert(k.to_owned(), v.clone());
            }
        }
        last.insert("endedAt".into(), json!(now_ms()));
        session.meta.lock().unwrap().last_turn = Some(Value::Object(last));
    }

    /// The profile to fall over to, when the current one names one that exists.
    async fn fallback_profile(&self, session: &Session) -> Option<String> {
        let cfg = self.config.read().await;
        let agent = session.meta().harness;
        let to = cfg.harnesses.get(&agent)?.fallback.clone()?;
        if to == agent || !cfg.harnesses.contains_key(&to) {
            return None;
        }
        Some(to)
    }

    /// Build a plain-text transcript from the log for rehydration.
    pub(super) fn transcript(&self, session: &Session, max_chars: usize) -> Option<String> {
        let events = self.store.events(&session.id, 0, 200_000).ok()?;
        let mut lines: Vec<String> = Vec::new();
        let mut agent_buf = String::new();
        let flush = |agent_buf: &mut String, lines: &mut Vec<String>| {
            if !agent_buf.trim().is_empty() {
                lines.push(format!("assistant: {}", agent_buf.trim()));
            }
            agent_buf.clear();
        };
        for e in events {
            match e.kind.as_str() {
                "user_message" => {
                    flush(&mut agent_buf, &mut lines);
                    if let Some(t) = e.msg.get("text").and_then(Value::as_str) {
                        lines.push(format!("user: {t}"));
                    }
                }
                "agent_message_chunk" => {
                    if let Some(t) =
                        e.msg.pointer("/params/update/content/text").and_then(Value::as_str)
                    {
                        agent_buf.push_str(t);
                    }
                }
                _ => {}
            }
        }
        flush(&mut agent_buf, &mut lines);
        if lines.is_empty() {
            return None;
        }
        let mut text = lines.join("\n\n");
        if text.chars().count() > max_chars {
            let skip = text.chars().count() - max_chars;
            text = format!(
                "[… {skip} earlier characters omitted …]\n{}",
                text.chars().skip(skip).collect::<String>()
            );
        }
        Some(text)
    }

    pub async fn cancel(&self, session: &Arc<Session>) -> Result<(), RpcError> {
        let child = session
            .child
            .lock()
            .await
            .clone()
            .ok_or_else(|| RpcError::invalid_params("session has no live agent"))?;
        let sid = session
            .meta()
            .agent_session_id
            .ok_or_else(|| RpcError::internal("no agent session"))?;
        self.cancel_pending_permissions(session);
        child
            .notify(method::SESSION_CANCEL, json!({"sessionId": sid}))
            .await
            .map_err(|e| RpcError::internal(e.to_string()))
    }

    /// Pass a session-scoped request to the child, rewriting the session id.
    pub async fn forward(
        self: &Arc<Self>,
        session: &Arc<Session>,
        m: &str,
        mut params: Value,
    ) -> Result<Value, RpcError> {
        let child = self.child_for(session).await?;
        let sid = session
            .meta()
            .agent_session_id
            .ok_or_else(|| RpcError::internal("no agent session"))?;
        if params.is_null() {
            params = json!({});
        }
        params["sessionId"] = Value::String(sid);
        let res = match child.request(m, params).await {
            Ok(v) => v,
            Err(mut e) => {
                // A process that died on this request: quote its last stderr
                // line, as prompt() does, so "agent process closed" says why.
                if e.message == "agent process closed" {
                    let tail: Vec<String> =
                        session.stderr_tail.lock().unwrap().iter().cloned().collect();
                    if let Some(last) = tail.iter().rev().map(|l| l.trim()).find(|l| {
                        !l.is_empty() && !l.starts_with("at ") && !l.starts_with("[SYSTEM_ERROR]")
                    }) {
                        e.message =
                            format!("agent process closed ({}): {last}", session.meta().harness);
                    }
                }
                return Err(e);
            }
        };
        match m {
            method::SESSION_SET_MODE => {
                if let Some(mode) = res.get("currentModeId").or(res.get("modeId")).cloned() {
                    self.write_mode_state(session, [ModeWrite::CurrentMode(mode)]);
                }
            }
            method::SESSION_SET_CONFIG_OPTION => {
                if let Some(opts) = res.get("configOptions") {
                    self.write_mode_state(session, [ModeWrite::ConfigOptions(opts.clone())]);
                }
            }
            method::SESSION_SET_MODEL => {
                if let Some(models) = res.get("models") {
                    session.meta.lock().unwrap().models = Some(models.clone());
                }
            }
            _ => {}
        }
        self.save_meta(session);
        Ok(res)
    }

    pub async fn set_mode(
        self: &Arc<Self>,
        session: &Arc<Session>,
        mode_id: &str,
    ) -> Result<Value, RpcError> {
        let r = self.forward(session, method::SESSION_SET_MODE, json!({"modeId": mode_id})).await?;
        self.write_mode_state(session, [ModeWrite::CurrentMode(json!(mode_id))]);
        self.append(session, "mux", "mode", json!({"modeId": mode_id}));
        self.save_meta(session);
        Ok(r)
    }

    pub async fn set_config(
        self: &Arc<Self>,
        session: &Arc<Session>,
        config_id: &str,
        value: Value,
    ) -> Result<Value, RpcError> {
        // Make sure the child is up so its option list is known, then map
        // portable names (effort) onto the harness's own id.
        let _ = self.child_for(session).await?;
        let config_id = resolve_config_id(&session.meta(), config_id);
        let config_id = config_id.as_str();
        let r = self
            .forward(
                session,
                method::SESSION_SET_CONFIG_OPTION,
                json!({"configId": config_id, "value": value}),
            )
            .await?;
        self.append(session, "mux", "config", json!({"configId": config_id, "value": value}));
        Ok(r)
    }

    pub async fn set_model(
        self: &Arc<Self>,
        session: &Arc<Session>,
        model_id: &str,
    ) -> Result<Value, RpcError> {
        // A harness that takes its model on the command line or in env
        // gets it at the next spawn: record it and drop the current process.
        // Same test as `new_session`: the profile, its defaults' env, or the
        // session's preset env may carry `${model}`.
        let at_spawn = {
            let cfg = self.config.read().await;
            let meta = session.meta();
            let in_env = |env: &std::collections::BTreeMap<String, String>| {
                env.values().any(|v| v.contains("${model}"))
            };
            cfg.profile(&meta.harness)
                .map(super::lifecycle::profile_takes_model_at_spawn)
                .unwrap_or(false)
                || in_env(&cfg.defaults_for(&meta.harness).env)
                || meta
                    .preset
                    .as_ref()
                    .and_then(|n| cfg.presets.get(n))
                    .map(|p| in_env(&p.env) || p.args.iter().any(|a| a.contains("${model}")))
                    .unwrap_or(false)
        };
        if at_spawn {
            session.meta.lock().unwrap().model_request = Some(model_id.to_owned());
            self.save_meta(session);
            self.detach_child(session).await;
            self.append(session, "mux", "model", json!({"modelId": model_id, "atSpawn": true}));
            return Ok(json!({}));
        }
        // Prefer the config option named "model" when the agent exposes one.
        let has_model_option = session
            .meta()
            .config_options
            .as_ref()
            .and_then(Value::as_array)
            .map(|opts| opts.iter().any(|o| o.get("id").and_then(Value::as_str) == Some("model")))
            .unwrap_or(false);
        if has_model_option {
            let meta = session.meta();
            let option = meta
                .config_options
                .as_ref()
                .and_then(Value::as_array)
                .and_then(|opts| opts.iter().find(|o| o["id"] == "model"))
                .unwrap();
            let value = Value::String(
                crate::model_catalog::resolve(option, model_id)
                    .map_err(RpcError::invalid_params)?,
            );
            return self.set_config(session, "model", value).await;
        }
        let r =
            self.forward(session, method::SESSION_SET_MODEL, json!({"modelId": model_id})).await?;
        self.append(session, "mux", "model", json!({"modelId": model_id}));
        Ok(r)
    }

    pub async fn rename(&self, session: &Arc<Session>, name: String) -> Result<(), RpcError> {
        if self
            .sessions
            .lock()
            .unwrap()
            .values()
            .any(|s| s.id != session.id && s.meta().name == name)
        {
            return Err(RpcError::invalid_params(format!("session name {name:?} is taken")));
        }
        let old = {
            let mut m = session.meta.lock().unwrap();
            std::mem::replace(&mut m.name, name.clone())
        };
        self.append(session, "mux", "renamed", json!({"from": old, "to": name}));
        self.save_meta(session);
        Ok(())
    }

    pub async fn set_policy(&self, session: &Arc<Session>, policy: PermissionPolicy) {
        self.permission_policy_changed(session, |m| m.permission_policy = Some(policy.to_string()));
        self.append(session, "mux", "policy", json!({"policy": policy.to_string()}));
        self.save_meta(session);
    }

    /// Stop the child. The log stays. `purge` also deletes the log.
    pub async fn kill(&self, session: &Arc<Session>, purge: bool) -> Result<(), RpcError> {
        self.revoke_permission_chat(session);
        self.cancel_pending_permissions(session);
        if let Some(child) = session.child.lock().await.take() {
            if let Some(sid) = session.meta().agent_session_id {
                let _ = tokio::time::timeout(
                    std::time::Duration::from_millis(500),
                    child.notify(method::SESSION_CANCEL, json!({"sessionId": sid})),
                )
                .await;
            }
            let link_lost = child.host_record().is_some() && !child.is_alive().await;
            child.kill().await;
            // A host whose link was lost cannot take a Terminate frame.
            if link_lost {
                self.end_unadopted_host(session).await;
            }
        } else {
            // A host this daemon could not adopt keeps running until the user
            // ends the session: end it without its protocol (frozen path).
            self.end_unadopted_host(session).await;
        }
        *session.turn.lock().unwrap() = None;
        self.set_status(session, SessionStatus::Closed);
        // The session's Claude Code MCP config holds the helper token.
        crate::agent_tools::remove_mcp_config(&crate::config::home(), &session.id);
        if purge {
            session.purged.store(true, Ordering::SeqCst);
            self.sessions.lock().unwrap().remove(&session.id);
            // Tell watchers (peers, TUIs) the session is gone.
            let _ = self.events.send(HubEvent {
                session_id: session.id.clone(),
                record: EventRecord {
                    seq: session.meta().last_seq + 1,
                    at: now_ms(),
                    dir: "mux".into(),
                    kind: "purged".into(),
                    msg: json!({"sessionId": session.id}),
                    host_seq: None,
                },
                remote: None,
            });
            self.store.delete(&session.id).map_err(|e| RpcError::internal(e.to_string()))?;
        }
        Ok(())
    }

    /// Stop the child but keep the session resumable.
    pub async fn detach_child(&self, session: &Arc<Session>) {
        self.revoke_permission_chat(session);
        self.cancel_pending_permissions(session);
        if let Some(child) = session.child.lock().await.take() {
            child.kill().await;
        }
        *session.turn.lock().unwrap() = None;
        if session.status() != SessionStatus::Closed {
            self.set_status(session, SessionStatus::Idle);
        }
    }
}

/// Add `fields` under `_meta.acpmux` of an object, keeping any `_meta` the
/// agent sent.
pub(crate) fn merge_mux_meta(v: &mut Value, fields: Value) {
    let Some(obj) = v.as_object_mut() else { return };
    let meta = obj.entry("_meta").or_insert_with(|| json!({}));
    if !meta.is_object() {
        *meta = json!({});
    }
    let mux = meta.as_object_mut().unwrap().entry("acpmux").or_insert_with(|| json!({}));
    if !mux.is_object() {
        *mux = json!({});
    }
    if let (Some(dst), Some(src)) = (mux.as_object_mut(), fields.as_object()) {
        for (k, v) in src {
            dst.insert(k.clone(), v.clone());
        }
    }
}

/// Does an agent error mean the account cannot serve, not that the prompt
/// was wrong? Usage and rate limits, and missing or rejected credentials:
/// all of them are solved by another account, which the fallback provides.
pub fn is_limit_error(message: &str) -> bool {
    let m = message.to_lowercase();
    m.contains("not logged in")
        || m.contains("/login")
        || m.contains("unauthorized")
        || m.contains("authentication")
        || m.contains("invalid api key")
        || m.contains("401")
        || (m.contains("reached your") && m.contains("limit"))
        || m.contains("usage limit")
        || m.contains("rate limit")
        || m.contains("rate_limit")
        || m.contains("out of credits")
        || m.contains("insufficient credits")
        || m.contains("quota")
        || m.contains("overloaded")
        || m.contains("429")
}

#[cfg(test)]
mod limit_tests {
    #[test]
    fn recognizes_limit_messages() {
        assert!(super::is_limit_error("You've reached your Fable limit. Switch to another model"));
        assert!(super::is_limit_error("rate_limit_error: too many requests"));
        assert!(super::is_limit_error("HTTP 429 overloaded"));
        assert!(super::is_limit_error("Not logged in · Please run /login"));
        assert!(!super::is_limit_error("simulated internal error"));
        assert!(!super::is_limit_error("permission denied"));
    }
}

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
    pub async fn prompt_with(
        self: &Arc<Self>,
        session: &Arc<Session>,
        mut blocks: Vec<Value>,
        client: &str,
        steer: bool,
        opts: PromptOptions,
    ) -> Result<Value, RpcError> {
        let prompt_id = opts.prompt_id.unwrap_or_else(|| uuid::Uuid::now_v7().to_string());
        let mut on_accepted = opts.on_accepted;
        let mut accept = |v: Value| {
            if let Some(f) = on_accepted.take() {
                f(v);
            }
        };
        let child = self.child_for(session).await?;
        let agent_sid = session
            .meta()
            .agent_session_id
            .ok_or_else(|| RpcError::internal("no agent session"))?;
        let text = prompt_text(&blocks);
        let running = session.turn();
        let steer_now = steer && session.steering.load(Ordering::SeqCst) && running.is_some();
        if steer_now {
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
            let mut params = json!({"sessionId": agent_sid, "prompt": blocks});
            params["_meta"] = json!({"steer": true});
            let mut r = child.request(method::SESSION_PROMPT, params).await?;
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
        // The child may have died while we waited.
        let child = self.child_for(session).await?;
        let agent_sid = session
            .meta()
            .agent_session_id
            .ok_or_else(|| RpcError::internal("no agent session"))?;
        if session.rehydrate.swap(false, Ordering::SeqCst)
            && let Some(transcript) = self.transcript(session, 24_000)
        {
            blocks.insert(
                    0,
                    json!({"type": "text", "text": format!("<restored_transcript note=\"acpmux restored this conversation on a new agent session; tool state was not restored\">\n{transcript}\n</restored_transcript>\n")}),
                );
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
        });
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
        session.stderr_tail.lock().unwrap().clear();
        let turn_seq = self
            .append(
                session,
                "mux",
                "turn_started",
                json!({"prompt": short_text(&text, 200), "client": client, "promptId": prompt_id, "turnId": turn_id}),
            )
            .seq;
        if let Some(t) = session.turn.lock().unwrap().as_mut() {
            t.turn_seq = turn_seq;
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
                match self.child_for(session).await {
                    Ok(child2) => {
                        if let Some(sid2) = session.meta().agent_session_id {
                            result = child2
                                .request(
                                    method::SESSION_PROMPT,
                                    json!({"sessionId": sid2, "prompt": blocks}),
                                )
                                .await;
                        }
                    }
                    Err(e2) => result = Err(e2),
                }
            }
        }
        *session.turn.lock().unwrap() = None;
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
        let ids = json!({"promptId": prompt_id, "turnId": turn_id, "turnSeq": turn_seq});
        match &result {
            Ok(v) => {
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
        drop(guard);
        if let Ok(v) = &mut result {
            merge_mux_meta(v, ids);
        }
        result
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
                    let mut meta = session.meta.lock().unwrap();
                    if let Some(modes) = meta.modes.as_mut() {
                        modes["currentModeId"] = mode;
                    }
                }
            }
            method::SESSION_SET_CONFIG_OPTION => {
                if let Some(opts) = res.get("configOptions") {
                    session.meta.lock().unwrap().config_options = Some(opts.clone());
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
        {
            let mut meta = session.meta.lock().unwrap();
            if let Some(modes) = meta.modes.as_mut() {
                modes["currentModeId"] = Value::String(mode_id.to_owned());
            }
        }
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
        let at_spawn = {
            let cfg = self.config.read().await;
            cfg.profile(&session.meta().harness)
                .map(super::lifecycle::profile_takes_model_at_spawn)
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

    pub async fn fork(
        self: &Arc<Self>,
        session: &Arc<Session>,
        name: Option<String>,
        cwd: Option<PathBuf>,
    ) -> Result<Arc<Session>, RpcError> {
        let parent_meta = session.meta();
        let is_claude = self
            .config
            .read()
            .await
            .profile(&parent_meta.harness)
            .map(|p| p.kind == crate::config::HarnessKind::ClaudeStdio)
            .unwrap_or(false);
        let sid = parent_meta
            .agent_session_id
            .clone()
            .ok_or_else(|| RpcError::internal("no agent session"))?;
        let cwd = cwd.unwrap_or_else(|| parent_meta.cwd.clone());
        let (res, new_sid) = if is_claude {
            // The fork happens when the new session's process starts with
            // --resume <parent> --fork-session; no agent call now.
            (json!({}), String::new())
        } else {
            let child = self.child_for(session).await?;
            let res = child
                .request(
                    method::SESSION_FORK,
                    json!({"sessionId": sid, "cwd": cwd, "mcpServers": []}),
                )
                .await?;
            let new_sid = res
                .get("sessionId")
                .and_then(Value::as_str)
                .ok_or_else(|| RpcError::internal("session/fork returned no sessionId"))?
                .to_owned();
            (res, new_sid)
        };
        let fork_seq = session.seq.load(Ordering::SeqCst);
        let id = uuid::Uuid::now_v7().to_string();
        let name = name.unwrap_or_else(|| self.unique_name(&format!("{}-fork", parent_meta.name)));
        let now = now_ms();
        let meta = SessionMeta {
            schema: META_SCHEMA.into(),
            id: id.clone(),
            name,
            harness: parent_meta.harness.clone(),
            harness_argv: parent_meta.harness_argv.clone(),
            family: parent_meta.family.clone(),
            preset: parent_meta.preset.clone(),
            model_request: parent_meta.model_request.clone(),
            cwd,
            agent_session_id: if is_claude { None } else { Some(new_sid) },
            status: SessionStatus::Idle,
            created_at: now,
            updated_at: now,
            last_seq: 0,
            parent_id: Some(session.id.clone()),
            fork_seq: Some(fork_seq),
            agent_info: parent_meta.agent_info.clone(),
            agent_capabilities: parent_meta.agent_capabilities.clone(),
            modes: res.get("modes").cloned().filter(|v| !v.is_null()).or(parent_meta.modes.clone()),
            config_options: res
                .get("configOptions")
                .cloned()
                .filter(|v| !v.is_null())
                .or(parent_meta.config_options.clone()),
            models: parent_meta.models.clone(),
            permission_policy: parent_meta.permission_policy.clone(),
            title: None,
            last_prompt: parent_meta.last_prompt.clone(),
            preview: parent_meta.preview.clone(),
            event_count: 0,
            turn_count: parent_meta.turn_count,
            usage: None,
            permission_rules: None,
            tags: Default::default(),
            unread: false,
            last_turn: None,
        };
        let new = self.make_session(meta);
        if is_claude {
            *new.fork_from.lock().unwrap() = Some(sid.clone());
        }
        self.store.save(&new.meta()).map_err(|e| RpcError::internal(e.to_string()))?;
        self.sessions.lock().unwrap().insert(id.clone(), new.clone());
        // Copy the transcript-relevant history so attach replays it.
        if let Ok(history) = self.store.events(&session.id, 0, 500_000) {
            for e in history {
                if e.seq > fork_seq {
                    break;
                }
                if matches!(
                    e.kind.as_str(),
                    "user_message"
                        | "agent_message_chunk"
                        | "agent_thought_chunk"
                        | "tool_call"
                        | "tool_call_update"
                        | "plan"
                        | "turn_end"
                ) {
                    self.append(&new, &e.dir, &e.kind, e.msg);
                }
            }
        }
        self.append(&new, "mux", "forked", json!({"parentId": session.id, "forkSeq": fork_seq}));
        self.append(session, "mux", "fork_child", json!({"childId": id}));
        // The forked agent session lives in the parent's process. Load it in
        // its own process so one session keeps one child.
        match self.child_for(&new).await {
            Ok(_) => {}
            Err(e) => tracing::warn!(session = %new.id, "fork child start failed: {e}"),
        }
        self.save_meta(&new);
        Ok(new)
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
        session.meta.lock().unwrap().permission_policy = Some(policy.to_string());
        self.append(session, "mux", "policy", json!({"policy": policy.to_string()}));
        self.save_meta(session);
    }

    /// Stop the child. The log stays. `purge` also deletes the log.
    pub async fn kill(&self, session: &Arc<Session>, purge: bool) -> Result<(), RpcError> {
        self.cancel_pending_permissions(session);
        if let Some(child) = session.child.lock().await.take() {
            if let Some(sid) = session.meta().agent_session_id {
                let _ = tokio::time::timeout(
                    std::time::Duration::from_millis(500),
                    child.notify(method::SESSION_CANCEL, json!({"sessionId": sid})),
                )
                .await;
            }
            child.kill().await;
        }
        *session.turn.lock().unwrap() = None;
        self.set_status(session, SessionStatus::Closed);
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
                },
                remote: None,
            });
            self.store.delete(&session.id).map_err(|e| RpcError::internal(e.to_string()))?;
        }
        Ok(())
    }

    /// Stop the child but keep the session resumable.
    pub async fn detach_child(&self, session: &Arc<Session>) {
        self.cancel_pending_permissions(session);
        if let Some(child) = session.child.lock().await.take() {
            child.kill().await;
        }
        *session.turn.lock().unwrap() = None;
        if session.status() != SessionStatus::Closed {
            self.set_status(session, SessionStatus::Idle);
        }
    }

    /// Stop every agent at once and save. Each agent's process group gets
    /// SIGTERM, then SIGKILL after `SHUTDOWN_GRACE`; every wait here has a
    /// deadline, so this returns within about `SHUTDOWN_GRACE` + 1 s.
    pub async fn shutdown_all(&self) {
        const LOCK: std::time::Duration = std::time::Duration::from_millis(200);
        let sessions = self.sessions();
        let mut children = Vec::new();
        for s in &sessions {
            self.cancel_pending_permissions(s);
            if let Ok(mut slot) = tokio::time::timeout(LOCK, s.child.lock()).await
                && let Some(child) = slot.take()
            {
                children.push(child);
            }
            *s.turn.lock().unwrap() = None;
            if s.status() != SessionStatus::Closed {
                self.set_status(s, SessionStatus::Idle);
            }
        }
        let stop = futures::future::join_all(children.iter().map(|c| c.terminate(SHUTDOWN_GRACE)));
        if tokio::time::timeout(SHUTDOWN_GRACE + LOCK * 2, stop).await.is_err() {
            tracing::warn!("agents did not stop within {SHUTDOWN_GRACE:?}");
        }
        self.flush();
    }

    /// Save every session's meta and sync the event log to disk.
    pub fn flush(&self) {
        for s in self.sessions() {
            self.save_meta(&s);
        }
        if let Err(e) = self.store.flush() {
            tracing::warn!("store flush failed: {e}");
        }
    }
}

/// How long agents get between SIGTERM and SIGKILL when the daemon stops.
pub const SHUTDOWN_GRACE: std::time::Duration = std::time::Duration::from_secs(2);

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

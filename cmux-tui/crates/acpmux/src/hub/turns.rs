//! Part of `Hub`; see `hub/mod.rs`.

use std::sync::atomic::Ordering;
use super::*;

impl Hub {
    // --------------------------------------------------------------- turns

    /// Run one prompt turn. Waits for any running turn unless `steer` is set
    /// and the agent supports steering. Returns the agent's prompt response.
    pub async fn prompt(
        self: &Arc<Self>,
        session: &Arc<Session>,
        mut blocks: Vec<Value>,
        client: &str,
        steer: bool,
    ) -> Result<Value, RpcError> {
        let child = self.child_for(session).await?;
        let agent_sid = session
            .meta()
            .agent_session_id
            .ok_or_else(|| RpcError::internal("no agent session"))?;
        let text = prompt_text(&blocks);
        let steer_now = steer && session.steering.load(Ordering::SeqCst) && session.turn().is_some();
        if steer_now {
            self.append(session, "mux", "user_message", json!({"text": text, "steer": true, "client": client}));
            let mut params = json!({"sessionId": agent_sid, "prompt": blocks});
            params["_meta"] = json!({"steer": true});
            return child.request(method::SESSION_PROMPT, params).await;
        }
        let waiting = session.turn().is_some() || session.queued() > 0;
        let position = session.queued.fetch_add(1, Ordering::SeqCst) + 1;
        if waiting {
            // Tell every client right away; the turn itself starts when the lock frees.
            self.append(session, "mux", "queued", json!({"text": text, "client": client, "position": position}));
        }
        let guard = session.turn_lock.lock().await;
        session.queued.fetch_sub(1, Ordering::SeqCst);
        // The child may have died while we waited.
        let child = self.child_for(session).await?;
        let agent_sid = session
            .meta()
            .agent_session_id
            .ok_or_else(|| RpcError::internal("no agent session"))?;
        if session.rehydrate.swap(false, Ordering::SeqCst) {
            if let Some(transcript) = self.transcript(session, 24_000) {
                blocks.insert(
                    0,
                    json!({"type": "text", "text": format!("<restored_transcript note=\"acpmux restored this conversation on a new agent session; tool state was not restored\">\n{transcript}\n</restored_transcript>\n")}),
                );
            }
        }
        {
            let mut m = session.meta.lock().unwrap();
            m.last_prompt = Some(short_text(&text, 200));
            m.preview = Some(String::new());
            m.turn_count += 1;
        }
        *session.turn.lock().unwrap() = Some(TurnInfo {
            started_at: now_ms(),
            client: client.to_owned(),
            prompt_preview: short_text(&text, 200),
        });
        self.append(session, "mux", "user_message", json!({"text": text, "client": client}));
        self.set_status(session, SessionStatus::Running);
        let result = child
            .request(method::SESSION_PROMPT, json!({"sessionId": agent_sid, "prompt": blocks}))
            .await;
        *session.turn.lock().unwrap() = None;
        match &result {
            Ok(v) => {
                let stop = v.get("stopReason").cloned().unwrap_or(Value::Null);
                self.append(session, "mux", "turn_end", json!({"stopReason": stop}));
            }
            Err(e) => {
                self.append(session, "mux", "turn_error", json!({"error": e.message, "code": e.code}));
            }
        }
        if session.status() != SessionStatus::Closed {
            let alive = child.is_alive().await;
            self.set_status(session, if alive { SessionStatus::Ready } else { SessionStatus::Disconnected });
        }
        self.save_meta(session);
        drop(guard);
        result
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
                    if let Some(t) = e
                        .msg
                        .pointer("/params/update/content/text")
                        .and_then(Value::as_str)
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
            text = format!("[… {skip} earlier characters omitted …]\n{}", text.chars().skip(skip).collect::<String>());
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
        let res = child.request(m, params).await?;
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

    pub async fn set_mode(self: &Arc<Self>, session: &Arc<Session>, mode_id: &str) -> Result<Value, RpcError> {
        let r = self
            .forward(session, method::SESSION_SET_MODE, json!({"modeId": mode_id}))
            .await?;
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

    pub async fn set_config(self: &Arc<Self>, session: &Arc<Session>, config_id: &str, value: Value) -> Result<Value, RpcError> {
        let r = self
            .forward(session, method::SESSION_SET_CONFIG_OPTION, json!({"configId": config_id, "value": value}))
            .await?;
        self.append(session, "mux", "config", json!({"configId": config_id, "value": value}));
        Ok(r)
    }

    pub async fn set_model(self: &Arc<Self>, session: &Arc<Session>, model_id: &str) -> Result<Value, RpcError> {
        // Prefer the config option named "model" when the agent exposes one.
        let has_model_option = session
            .meta()
            .config_options
            .as_ref()
            .and_then(Value::as_array)
            .map(|opts| opts.iter().any(|o| o.get("id").and_then(Value::as_str) == Some("model")))
            .unwrap_or(false);
        if has_model_option {
            return self.set_config(session, "model", Value::String(model_id.to_owned())).await;
        }
        let r = self
            .forward(session, method::SESSION_SET_MODEL, json!({"modelId": model_id}))
            .await?;
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
            .agent(&parent_meta.agent)
            .map(|p| p.kind == crate::config::AgentKind::ClaudeStdio)
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
                .request(method::SESSION_FORK, json!({"sessionId": sid, "cwd": cwd, "mcpServers": []}))
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
            agent: parent_meta.agent.clone(),
            agent_argv: parent_meta.agent_argv.clone(),
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
            config_options: res.get("configOptions").cloned().filter(|v| !v.is_null()).or(parent_meta.config_options.clone()),
            models: parent_meta.models.clone(),
            permission_policy: parent_meta.permission_policy.clone(),
            title: None,
            last_prompt: parent_meta.last_prompt.clone(),
            preview: parent_meta.preview.clone(),
            event_count: 0,
            turn_count: parent_meta.turn_count,
            usage: None,
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
                if matches!(e.kind.as_str(), "user_message" | "agent_message_chunk" | "agent_thought_chunk" | "tool_call" | "tool_call_update" | "plan" | "turn_end") {
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
            self.store
                .delete(&session.id)
                .map_err(|e| RpcError::internal(e.to_string()))?;
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

    pub async fn shutdown_all(&self) {
        for s in self.sessions() {
            self.detach_child(&s).await;
        }
    }

}

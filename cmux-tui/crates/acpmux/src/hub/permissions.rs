//! Part of `Hub`; see `hub/mod.rs`.

use super::*;

impl Hub {
    // ------------------------------------------------------------- inbound

    pub(super) async fn inbound_loop(
        self: Arc<Self>,
        session: Arc<Session>,
        mut rx: mpsc::Receiver<Inbound>,
    ) {
        while let Some(item) = rx.recv().await {
            match item {
                Inbound::Notification { method: m, params } => {
                    if m == method::SESSION_UPDATE {
                        self.on_update(&session, params.as_ref());
                    }
                }
                Inbound::Request { id, method: m, params } => {
                    let hub = self.clone();
                    let s = session.clone();
                    let epoch = session.permission_epoch.load(Ordering::SeqCst);
                    let turn_id = session.turn().map(|t| t.turn_id);
                    tokio::spawn(async move {
                        hub.on_agent_request(s, id, m, params, epoch, turn_id).await
                    });
                }
                Inbound::Stderr(line, host_seq) => {
                    let line = short_text(&line, 4000);
                    tracing::debug!(session = %session.id, "stderr: {line}");
                    if !line.trim().is_empty() {
                        let mut tail = session.stderr_tail.lock().unwrap();
                        if tail.len() >= 6 {
                            tail.pop_front();
                        }
                        tail.push_back(line.clone());
                    }
                    // An agent host's stderr was logged before its ack.
                    if host_seq.is_none() {
                        self.append(&session, "mux", "stderr", json!({"text": line}));
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
                    let intentional =
                        matches!(session.status(), SessionStatus::Idle | SessionStatus::Closed);
                    // An agent host's exit was logged before its ack.
                    if host_seq.is_none() {
                        self.append(
                            &session,
                            "mux",
                            if intentional { "stopped" } else { "exited" },
                            json!({"code": code}),
                        );
                    }
                    if !intentional {
                        self.set_status(&session, SessionStatus::Disconnected);
                    }
                }
            }
        }
    }

    pub(super) fn on_update(&self, session: &Session, params: Option<&Value>) {
        let Some(update) = params.and_then(|p| p.get("update")) else {
            return;
        };
        let kind = update.get("sessionUpdate").and_then(Value::as_str).unwrap_or("");
        let mut m = session.meta.lock().unwrap();
        match kind {
            "agent_message_chunk" => {
                if let Some(text) =
                    update.get("content").and_then(|c| c.get("text")).and_then(Value::as_str)
                {
                    let mut preview = m.preview.clone().unwrap_or_default();
                    preview.push_str(text);
                    if preview.len() > 2000 {
                        let cut = preview.len() - 2000;
                        let mut idx = cut;
                        while !preview.is_char_boundary(idx) {
                            idx += 1;
                        }
                        preview = preview[idx..].to_owned();
                    }
                    m.preview = Some(preview);
                }
            }
            "usage_update" => m.usage = Some(update.clone()),
            "current_mode_update" => {
                if let Some(mode_id) = update.get("currentModeId").cloned()
                    && let Some(modes) = m.modes.as_mut()
                {
                    modes["currentModeId"] = mode_id;
                }
            }
            "config_option_update" => {
                if let Some(opts) = update.get("configOptions") {
                    m.config_options = Some(opts.clone());
                }
            }
            "session_info_update" => {
                if let Some(title) = update.get("title").and_then(Value::as_str) {
                    m.title = Some(title.to_owned());
                }
            }
            _ => {}
        }
        drop(m);
        // Default deny on drift: also a mode the harness changes by itself.
        if matches!(kind, "current_mode_update" | "config_option_update") {
            self.note_mode(session, false);
        }
    }

    pub(super) async fn on_agent_request(
        self: Arc<Self>,
        session: Arc<Session>,
        id: Id,
        m: String,
        params: Option<Value>,
        epoch: u64,
        turn_id: Option<String>,
    ) {
        // Context was captured before spawning this request task, so cancel
        // or a new turn cannot make a delayed request join the new ask.
        let Some(child) = session.child.lock().await.clone() else {
            return;
        };
        if m == method::SESSION_REQUEST_PERMISSION {
            let params = params.unwrap_or(Value::Null);
            let result =
                self.handle_permission_for(&session, params, epoch, turn_id, Some(&id)).await;
            let _ = child.respond(id, Ok(result)).await;
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
        let path = Self::fs_path(session, &params)?;
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
        std::fs::write(&path, content.as_bytes())
            .map_err(|e| RpcError::internal(format!("write {}: {e}", path.display())))?;
        Ok(Value::Null)
    }

    async fn handle_fs_read(
        self: &Arc<Self>,
        session: &Arc<Session>,
        params: Value,
        epoch: u64,
        turn_id: Option<String>,
    ) -> Result<Value, RpcError> {
        let path = Self::fs_path(session, &params)?;
        let config_policy = self.config.read().await.permission_policy;
        let policy = self.policy_for(session, config_policy);
        let probe = json!({"toolCall": {"title": format!("Read {}", path.display()), "kind": "read", "rawInput": {"path": path}}});
        let rule =
            session.meta().permission_rules.as_ref().and_then(|r| super::rules::decide(r, &probe));
        let mut denied = matches!(rule, Some(super::rules::RuleDecision::Deny))
            || (rule.is_none() && policy == PermissionPolicy::DenyAll);
        if matches!(rule, Some(super::rules::RuleDecision::Ask)) {
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
        let text = std::fs::read_to_string(&path)
            .map_err(|e| RpcError::new(-32000, format!("read {}: {e}", path.display())))?;
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

    pub(super) fn policy_for(
        &self,
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
        self.handle_permission_for(session, request, epoch, turn_id, None).await
    }

    /// `handle_permission` for the agent's own `session/request_permission`
    /// with JSON-RPC id `agent_request_id`, recorded so a controller that
    /// adopts the agent's host can still answer it.
    pub(super) async fn handle_permission_for(
        self: &Arc<Self>,
        session: &Arc<Session>,
        request: Value,
        epoch: u64,
        turn_id: Option<String>,
        agent_request_id: Option<&Id>,
    ) -> Value {
        let (rx, prev, grouping, permission_id) = {
            let cfg = self.config.read().await;
            let mut state = session.permissions.lock().unwrap();
            if session.permission_epoch.load(Ordering::SeqCst) != epoch
                || session.turn().map(|t| t.turn_id) != turn_id
            {
                return json!({"outcome":{"outcome":"cancelled"}});
            }
            let policy = self.policy_for(session, cfg.permission_policy);
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
                    PermissionPolicy::ApproveReads => {
                        if matches!(tool_kind, "read" | "search" | "fetch" | "think") {
                            pick(&["allow_once", "allow_always"])
                        } else {
                            None
                        }
                    }
                    PermissionPolicy::ApproveEdits => {
                        if matches!(tool_kind, "read" | "search" | "fetch" | "think" | "edit") {
                            pick(&["allow_once", "allow_always"])
                        } else {
                            None
                        }
                    }
                    PermissionPolicy::Ask => None,
                },
            };
            let denied = policy == PermissionPolicy::DenyAll
                || rule == Some(super::rules::RuleDecision::Deny);
            let chat_option = if state.chat_allowed
                && !denied
                && session.turn().is_some()
                && super::permission_groups::eligible(&request)
            {
                super::permission_groups::option(&request, "allow_once")
            } else {
                None
            };
            let auto = if denied {
                pick(&["reject_once", "reject_always"])
            } else {
                chat_option.clone().or(auto)
            };
            let permission_id = uuid::Uuid::now_v7().to_string();
            if let Some(option_id) = auto {
                self.append(
                session,
                "mux",
                "permission_auto",
                json!({"permissionId": permission_id, "policy": policy.to_string(), "rule": rule.map(|r| format!("{r:?}").to_lowercase()), "optionId": option_id, "chatAllowance":chat_option.is_some(), "request": request}),
            );
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
            state.pending.insert(
                permission_id.clone(),
                PendingPermission { request: request.clone(), reply: tx },
            );
            self.append(session,"mux","permission_request",json!({"permissionId":permission_id,"request":request,"groupId":grouping.as_ref().map(|(id,_)|id),"turnId":turn_id,"agentRequestId":agent_request_id}));
            let prev = session.status();
            self.set_status(session, SessionStatus::Waiting);
            (rx, prev, grouping, permission_id)
        };
        if let Some((id, true)) = grouping {
            self.start_permission_group_timer(session, id);
        }
        let outcome = rx.await.unwrap_or_else(|_| json!({"outcome":"cancelled"}));
        self.append(
            session,
            "mux",
            "permission_decision",
            json!({"permissionId":permission_id,"outcome":outcome}),
        );
        {
            let state = session.permissions.lock().unwrap();
            if state.pending.is_empty() && session.status() == SessionStatus::Waiting {
                let next = if session.turn().is_some() { SessionStatus::Running } else { prev };
                self.set_status(session, next);
            }
        }
        let mut out = json!({"outcome": outcome});
        if let Some(m) = out["outcome"].get("_meta").cloned() {
            out["_meta"] = m;
            if let Some(o) = out["outcome"].as_object_mut() {
                o.remove("_meta");
            }
        }
        out
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
    ) -> Result<(), RpcError> {
        let cfg = self.config.read().await;
        let pending = {
            let mut state = session.permissions.lock().unwrap();
            let map = &mut state.pending;
            let p = map.get(permission_id).ok_or_else(|| {
                RpcError::not_found(format!("no pending permission {permission_id}"))
            })?;
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
                let is_reject =
                    matches!(offered[0]["kind"].as_str(), Some("reject_once" | "reject_always"));
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
            }
            let p = map.remove(permission_id).unwrap();
            if let Some(group) = state.finish_item(&session.id, permission_id, option_id.is_none())
            {
                self.append(session, "mux", "permission_group", json!({"group":group}));
            }
            p
        };
        let mut outcome = match option_id {
            Some(o) => json!({"outcome": "selected", "optionId": o}),
            None => json!({"outcome": "cancelled"}),
        };
        if let Some(a) = answers {
            let mut input =
                pending.request.pointer("/toolCall/rawInput").cloned().unwrap_or(json!({}));
            input["answers"] = a;
            outcome["_meta"] = json!({"updatedInput": input});
        }
        let _ = pending.reply.send(outcome);
        Ok(())
    }

    pub(super) fn cancel_pending_permissions(&self, session: &Session) {
        let drained: Vec<_> = {
            let mut state = session.permissions.lock().unwrap();
            session.permission_epoch.fetch_add(1, Ordering::SeqCst);
            let drained: Vec<_> = state.pending.drain().collect();
            for (id, _) in &drained {
                if let Some(group) = state.finish_item(&session.id, id, true) {
                    self.append(session, "mux", "permission_group", json!({"group":group}));
                }
            }
            drained
        };
        for (_, p) in drained {
            let _ = p.reply.send(json!({"outcome": "cancelled"}));
        }
    }
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

#[cfg(test)]
mod tests {
    use super::normalize_path;
    use std::path::Path;

    #[test]
    fn normalize_resolves_parent_components() {
        assert_eq!(normalize_path(Path::new("/w/src/../../secret")), Path::new("/secret"));
        assert_eq!(normalize_path(Path::new("/w/./src/a.rs")), Path::new("/w/src/a.rs"));
        assert_eq!(normalize_path(Path::new("/../x")), Path::new("/x"));
    }
}

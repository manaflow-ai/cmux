//! Part of `Hub`; see `hub/mod.rs`.

use super::*;

impl Hub {
    // ------------------------------------------------------------- inbound

    pub(super) async fn inbound_loop(self: Arc<Self>, session: Arc<Session>, mut rx: mpsc::Receiver<Inbound>) {
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
                    tokio::spawn(async move { hub.on_agent_request(s, id, m, params).await });
                }
                Inbound::Stderr(line) => {
                    let line = short_text(&line, 4000);
                    tracing::debug!(session = %session.id, "stderr: {line}");
                    self.append(&session, "mux", "stderr", json!({"text": line}));
                }
                Inbound::Exited(code) => {
                    *session.child.lock().await = None;
                    self.cancel_pending_permissions(&session);
                    let intentional = matches!(session.status(), SessionStatus::Idle | SessionStatus::Closed);
                    self.append(&session, "mux", if intentional { "stopped" } else { "exited" }, json!({"code": code}));
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
                if let Some(text) = update.get("content").and_then(|c| c.get("text")).and_then(Value::as_str) {
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
                if let Some(mode_id) = update.get("currentModeId").cloned() {
                    if let Some(modes) = m.modes.as_mut() {
                        modes["currentModeId"] = mode_id;
                    }
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
    }

    pub(super) async fn on_agent_request(self: Arc<Self>, session: Arc<Session>, id: Id, m: String, params: Option<Value>) {
        let Some(child) = session.child.lock().await.clone() else {
            return;
        };
        if m == method::SESSION_REQUEST_PERMISSION {
            let params = params.unwrap_or(Value::Null);
            let result = self.handle_permission(&session, params).await;
            let _ = child.respond(id, Ok(result)).await;
            return;
        }
        let _ = child.respond(id, Err(RpcError::method_not_found(&m))).await;
    }

    pub(super) fn policy_for(&self, session: &Session, config_policy: PermissionPolicy) -> PermissionPolicy {
        session
            .meta()
            .permission_policy
            .as_deref()
            .and_then(|p| p.parse().ok())
            .unwrap_or(config_policy)
    }

    pub(super) async fn handle_permission(&self, session: &Arc<Session>, request: Value) -> Value {
        let config_policy = self.config.read().await.permission_policy;
        let policy = self.policy_for(session, config_policy);
        let options = request
            .get("options")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        let pick = |kinds: &[&str]| -> Option<String> {
            for k in kinds {
                if let Some(o) = options.iter().find(|o| o.get("kind").and_then(Value::as_str) == Some(k)) {
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
        let auto = match policy {
            PermissionPolicy::ApproveAll => pick(&["allow_once", "allow_always"]),
            PermissionPolicy::DenyAll => pick(&["reject_once", "reject_always"]),
            PermissionPolicy::ApproveReads => {
                if matches!(tool_kind, "read" | "search" | "fetch" | "think") {
                    pick(&["allow_once", "allow_always"])
                } else {
                    None
                }
            }
            PermissionPolicy::Ask => None,
        };
        let permission_id = uuid::Uuid::now_v7().to_string();
        if let Some(option_id) = auto {
            self.append(
                session,
                "mux",
                "permission_auto",
                json!({"permissionId": permission_id, "policy": policy.to_string(), "optionId": option_id, "request": request}),
            );
            return json!({"outcome": {"outcome": "selected", "optionId": option_id}});
        }
        let (tx, rx) = oneshot::channel();
        session.pending_permissions.lock().unwrap().insert(
            permission_id.clone(),
            PendingPermission {
                request: request.clone(),
                reply: tx,
            },
        );
        self.append(
            session,
            "mux",
            "permission_request",
            json!({"permissionId": permission_id, "request": request}),
        );
        let prev = session.status();
        self.set_status(session, SessionStatus::Waiting);
        let outcome = rx.await.unwrap_or_else(|_| json!({"outcome": "cancelled"}));
        session.pending_permissions.lock().unwrap().remove(&permission_id);
        self.append(
            session,
            "mux",
            "permission_decision",
            json!({"permissionId": permission_id, "outcome": outcome}),
        );
        if session.status() == SessionStatus::Waiting {
            let next = if session.turn().is_some() { SessionStatus::Running } else { prev };
            self.set_status(session, next);
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
    pub fn respond_permission(&self, session: &Session, permission_id: &str, option_id: Option<String>, answers: Option<Value>) -> Result<(), RpcError> {
        let pending = session
            .pending_permissions
            .lock()
            .unwrap()
            .remove(permission_id)
            .ok_or_else(|| RpcError::not_found(format!("no pending permission {permission_id}")))?;
        let mut outcome = match option_id {
            Some(o) => json!({"outcome": "selected", "optionId": o}),
            None => json!({"outcome": "cancelled"}),
        };
        if let Some(a) = answers {
            let mut input = pending.request.pointer("/toolCall/rawInput").cloned().unwrap_or(json!({}));
            input["answers"] = a;
            outcome["_meta"] = json!({"updatedInput": input});
        }
        let _ = pending.reply.send(outcome);
        Ok(())
    }

    pub(super) fn cancel_pending_permissions(&self, session: &Session) {
        let drained: Vec<_> = session.pending_permissions.lock().unwrap().drain().collect();
        for (_, p) in drained {
            let _ = p.reply.send(json!({"outcome": "cancelled"}));
        }
    }

}

//! Part of `Hub`; see `hub/mod.rs`.

use super::*;

/// What limits a session's agent as far as acpmux can tell. `policy` is
/// always the acpmux permission policy (the session's own, else
/// `default_policy`), so sessions on different harnesses compare; the
/// harness's mode is only named in `detail`. Host isolation is never
/// claimed, and no sandbox is inferred from a mode name.
pub(super) fn enforcement(m: &SessionMeta, default_policy: Option<PermissionPolicy>) -> Value {
    let policy = m
        .permission_policy
        .clone()
        .or_else(|| default_policy.map(|p| p.to_string()))
        .unwrap_or_else(|| "unknown".into());
    let mode = m.modes.as_ref().and_then(|x| x.get("currentModeId")).and_then(Value::as_str);
    let harness = m.family.as_deref().unwrap_or(&m.harness);
    json!({
        "policy": policy,
        "label": "native_policy",
        "isolation": "unverified",
        "detail": format!(
            "{harness} mode {}; acpmux policy {policy}{}; host isolation unverified",
            mode.unwrap_or("unknown"),
            if m.permission_policy.is_none() { " (the daemon default)" } else { "" }
        ),
    })
}

impl Hub {
    // ------------------------------------------------------------- views

    /// `enforcement` with the daemon's default policy (unknown only while
    /// the configuration is being written).
    pub(super) fn session_enforcement(&self, m: &SessionMeta) -> Value {
        enforcement(m, self.config.try_read().ok().map(|c| c.permission_policy))
    }

    pub fn session_summary(&self, session: &Session) -> Value {
        let m = session.meta();
        let turn = session.turn();
        json!({
            "sessionId": m.id,
            "name": m.name,
            "harness": m.harness,
            "family": m.family,
            "cwd": m.cwd,
            "status": m.status.to_string(),
            "agentSessionId": m.agent_session_id,
            "createdAt": m.created_at,
            "updatedAt": m.updated_at,
            "lastSeq": m.last_seq,
            "eventCount": m.event_count,
            "turnCount": m.turn_count,
            "parentId": m.parent_id,
            "title": m.title,
            "lastPrompt": m.last_prompt,
            "preview": m.preview.as_deref().map(|p| short_text(p, 160)),
            "queued": session.queued(),
            "turn": turn.map(|t| json!({"startedAt": t.started_at, "client": t.client, "prompt": t.prompt_preview, "turnId": t.turn_id, "promptId": t.prompt_id, "turnSeq": t.turn_seq})),
            "queue": session.queue().into_iter().map(|q| json!({"promptId": q.prompt_id, "turnId": q.turn_id, "client": q.client, "prompt": q.preview, "queuedAt": q.queued_at})).collect::<Vec<_>>(),
            "pendingPermissions": session.pending_permissions().len(),
            "currentModeId": m.modes.as_ref().and_then(|x| x.get("currentModeId")).cloned(),
            "model": current_model(&m),
            "policy": m.permission_policy,
            "enforcement": self.session_enforcement(&m),
            "rules": m.permission_rules.is_some(),
            "tags": live_tags(&m),
            "stateSeq": session.state_seq.load(Ordering::SeqCst),
            "unread": m.unread,
            "lastTurn": m.last_turn,
            "attached": session.attached.load(Ordering::SeqCst),
        })
    }

    pub fn session_detail(&self, session: &Session) -> Value {
        let m = session.meta();
        let mut v = self.session_summary(session);
        v["modes"] = m.modes.clone().unwrap_or(Value::Null);
        v["configOptions"] = m.config_options.clone().unwrap_or(Value::Null);
        v["models"] = m.models.clone().unwrap_or(Value::Null);
        v["agentInfo"] = m.agent_info.clone().unwrap_or(Value::Null);
        v["agentCapabilities"] = m.agent_capabilities.clone().unwrap_or(Value::Null);
        v["usage"] = m.usage.clone().unwrap_or(Value::Null);
        v["forkSeq"] = json!(m.fork_seq);
        v["rulesJson"] = m.permission_rules.clone().unwrap_or(Value::Null);
        v["pending"] = Value::Array(session.permissions.lock().unwrap().pending_records());
        v
    }

    pub async fn status(&self) -> Value {
        let cfg = self.config.read().await;
        let sessions = self.sessions();
        let mut live = 0;
        for s in &sessions {
            if s.child.lock().await.is_some() {
                live += 1;
            }
        }
        json!({
            "version": VERSION,
            "build": BUILD,
            "pid": std::process::id(),
            "startedAt": self.started_at,
            "home": crate::config::home(),
            "userHome": dirs::home_dir(),
            "socket": crate::config::socket_path(),
            "store": cfg.store,
            "sessions": sessions.len(),
            "liveAgents": live,
            // Hidden pre-created sessions; never counted above.
            "pool": self.pool_view_json(),
            // New agents outlive this daemon (agent hosts): a restart for an
            // update keeps them running.
            "agentHosts": self.agent_hosts_enabled(),
            "harnesses": cfg.harnesses.keys().collect::<Vec<_>>(),
            "defaultHarness": cfg.default_harness,
            "permissionPolicy": cfg.permission_policy.to_string(),
            "peers": self.peers(),
            "remoteSessions": self.remote_sessions.lock().unwrap().len(),
            "webUrl": cfg.web_listener().map(web_url),
            "listen": cfg.web_listener().map(|w| w.listen.clone()),
            "ready": self.startup_complete(),
            "loginEnv": crate::login_env::state(self.login_env_requested.load(Ordering::SeqCst)),
        })
    }
}

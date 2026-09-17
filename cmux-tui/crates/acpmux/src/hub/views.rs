//! Part of `Hub`; see `hub/mod.rs`.

use super::*;

impl Hub {
    // ------------------------------------------------------------- views

    pub fn session_summary(&self, session: &Session) -> Value {
        let m = session.meta();
        let turn = session.turn();
        json!({
            "sessionId": m.id,
            "name": m.name,
            "agent": m.agent,
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
            "turn": turn.map(|t| json!({"startedAt": t.started_at, "client": t.client, "prompt": t.prompt_preview})),
            "pendingPermissions": session.pending_permissions().len(),
            "currentModeId": m.modes.as_ref().and_then(|x| x.get("currentModeId")).cloned(),
            "model": current_model(&m),
            "policy": m.permission_policy,
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
        v["pending"] = Value::Array(
            session
                .pending_permissions()
                .into_iter()
                .map(|(id, req)| json!({"permissionId": id, "request": req}))
                .collect(),
        );
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
            "pid": std::process::id(),
            "startedAt": self.started_at,
            "home": crate::config::home(),
            "socket": crate::config::socket_path(),
            "store": cfg.store,
            "sessions": sessions.len(),
            "liveAgents": live,
            "agents": cfg.agents.keys().collect::<Vec<_>>(),
            "defaultAgent": cfg.default_agent,
            "permissionPolicy": cfg.permission_policy.to_string(),
            "peers": self.peers(),
            "remoteSessions": self.remote_sessions.lock().unwrap().len(),
            "webUrl": cfg.websocket.as_ref().map(|w| web_url(w)),
        })
    }
}

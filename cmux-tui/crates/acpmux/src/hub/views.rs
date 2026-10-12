//! Part of `Hub`; see `hub/mod.rs`.

use super::*;

/// The session's status dot, decided here once so every client draws the
/// same one (cx-zlox). First match wins:
///
/// - `input`: a permission or question waits for the person.
/// - `working`: a turn runs.
/// - `failed`: the last turn failed (also when the agent then exited).
/// - `lost`: the agent process is gone (`disconnected`, or a peer's
///   `unreachable`) and the chat's last turn did not answer. A chat with
///   no turn yet has nothing to lose.
/// - `done`: the last turn answered. Whether the person saw it is each
///   client's own record.
/// - null: nothing to show (no turn yet, a cancelled turn, closed).
///
/// A peer's session that is `unreachable` mid-turn or with a question
/// waiting is `lost`: that turn cannot answer, nor the question be answered.
/// So is a `disconnected` one whose turn has not ended yet (the agent died
/// before its turn recorded `lastTurn`).
///
/// Reads only the summary's own fields, so a summary whose `status` changes
/// afterwards (a peer going unreachable) is re-decided from it.
pub fn status_indicator(summary: &Value) -> Option<&'static str> {
    let status = summary["status"].as_str().unwrap_or_default();
    let last = summary["lastTurn"]["status"].as_str();
    let answered = last == Some("completed");
    let pending = summary["pendingPermissions"].as_u64().unwrap_or(0) > 0;
    match status {
        "closed" => None,
        "unreachable" if pending || !summary["turn"].is_null() => Some("lost"),
        "disconnected" if !summary["turn"].is_null() => Some("lost"),
        "waiting" => Some("input"),
        _ if pending => Some("input"),
        "running" => Some("working"),
        _ if last == Some("failed") => Some("failed"),
        "disconnected" | "unreachable" if last.is_some() && !answered => Some("lost"),
        _ if answered => Some("done"),
        _ => None,
    }
}

/// The summary's `lastMessage`, one sidebar line: the last line of words in
/// the agent's reply, or the prompt while the turn has not answered yet.
/// Null before the first prompt.
fn last_message(m: &SessionMeta) -> Value {
    let reply = m
        .preview
        .as_deref()
        .and_then(|p| p.lines().rev().find(|l| l.chars().any(char::is_alphanumeric)));
    if let Some(line) = reply {
        return json!({"role": "agent", "text": short_text(line, 160)});
    }
    match m.last_prompt.as_deref().filter(|p| !p.trim().is_empty()) {
        Some(prompt) => json!({"role": "user", "text": short_text(prompt, 160)}),
        None => Value::Null,
    }
}

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
        let mut summary = json!({
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
            // Where a fork branched off its parent (the pane's < 1/2 > arrows, cx-ncc.61).
            "forkSeq": m.fork_seq,
            "title": m.title,
            "lastPrompt": m.last_prompt,
            "preview": m.preview.as_deref().map(|p| short_text(p, 160)),
            "lastMessage": last_message(&m),
            "queued": session.queued(),
            // A turn failed: the prompts that waited behind it wait for a client to resume them.
            "queuePaused": session.queue_paused(),
            // Being moved to another daemon (`transfer_out.rs`): it takes no prompt meanwhile.
            "moving": session.moving().is_some(),
            // The agent takes a prompt mid-turn (`_meta.acpmux.steer`); else a steer waits, or
            // with `interrupt` stops the turn and runs next.
            "steering": session.steering.load(Ordering::SeqCst),
            "turn": turn.map(|t| json!({"startedAt": t.started_at, "client": t.client, "prompt": t.prompt_preview, "turnId": t.turn_id, "promptId": t.prompt_id, "turnSeq": t.turn_seq})),
            "queue": session.queue().into_iter().map(|q| json!({"promptId": q.prompt_id, "turnId": q.turn_id, "client": q.client, "prompt": q.preview, "queuedAt": q.queued_at, "held": q.held})).collect::<Vec<_>>(),
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
            // Some attached client shows the chat (`hub/seen.rs`).
            "shown": self.shown(session),
        });
        summary["indicator"] = status_indicator(&summary).map_or(Value::Null, Value::from);
        summary
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
        let mut pending = session.permissions.lock().unwrap().pending_records();
        for p in &mut pending {
            p["personInstance"] = Value::String(self.person.instance().to_owned());
        }
        v["pending"] = Value::Array(pending);
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
            // Whether this run holds a person key, and its id (`hub/person.rs`):
            // the app checks that a daemon it started with a key still runs.
            "personKey": self.person.has_key(),
            "personInstance": self.person.instance(),
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
            "webUrl": web_url(&cfg),
            "listen": cfg.web_listener().map(|w| w.listen.clone()),
            "ready": self.startup_complete(),
            "loginEnv": crate::login_env::state(self.login_env_requested.load(Ordering::SeqCst)),
            // The Chief home the built-in Chief presets use (`config/chief_builtins.rs`),
            // from this daemon's own environment; the app hands off a Chief-home
            // daemon that lacks it.
            "chiefMuxHome": crate::config::chief_builtins::Context::current().chief_home,
        })
    }
}

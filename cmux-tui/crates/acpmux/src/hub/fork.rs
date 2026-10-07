//! Part of `Hub`; see `hub/mod.rs`. `session/fork`: a new session from a
//! parent's conversation. Its per-session env is the fork request's own,
//! never the parent's (session_env.rs).

use super::*;
use std::sync::atomic::Ordering;

impl Hub {
    pub async fn fork(
        self: &Arc<Self>,
        session: &Arc<Session>,
        name: Option<String>,
        cwd: Option<PathBuf>,
        session_env: std::collections::BTreeMap<String, String>,
    ) -> Result<Arc<Session>, RpcError> {
        let parent_meta = session.meta();
        // The profile env plus the preset's, for `agent_tools::left_out`.
        let (is_claude, fork_env) = {
            let cfg = self.config.read().await;
            let profile = cfg.profile(&parent_meta.harness);
            let mut env = profile.map(|p| p.env.clone()).unwrap_or_default();
            if let Some(preset) = parent_meta.preset.as_ref().and_then(|n| cfg.presets.get(n)) {
                env.extend(preset.env.clone());
            }
            (profile.is_some_and(|p| p.kind == crate::config::HarnessKind::ClaudeStdio), env)
        };
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
                    json!({"sessionId": sid, "cwd": cwd, "mcpServers": crate::agent_tools::acp_servers_for(parent_meta.remote_origin, &fork_env)}),
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
            // A fork of a remote-origin session stays remote-origin.
            remote_origin: parent_meta.remote_origin,
            // Never inherited: the fork request sets its own or runs without one.
            session_env,
            harness_roots: vec![],
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
}

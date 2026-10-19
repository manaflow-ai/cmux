//! Part of `Hub`; see `hub/mod.rs`. `session/fork`: a new session from a
//! parent's conversation. Its per-session env is the fork request's own,
//! never the parent's (session_env.rs). `through` (a Claude or Codex chat
//! only) forks through an earlier turn instead of the chat's end (`fork_at.rs`).

use super::*;
use std::sync::atomic::Ordering;

impl Hub {
    /// Whether the session runs Claude Code, and its profile env plus its
    /// preset's (`agent_tools::left_out`, where Claude keeps its store).
    pub(super) async fn harness_env(
        &self,
        meta: &SessionMeta,
    ) -> (bool, std::collections::BTreeMap<String, String>) {
        let cfg = self.config.read().await;
        let profile = cfg.profile(&meta.harness);
        let mut env = profile.map(|p| p.env.clone()).unwrap_or_default();
        if let Some(preset) = meta.preset.as_ref().and_then(|n| cfg.presets.get(n)) {
            env.extend(preset.env.clone());
        }
        meta.apply_chat_store(&mut env);
        (profile.is_some_and(|p| p.kind == crate::config::HarnessKind::ClaudeStdio), env)
    }

    pub async fn fork(
        self: &Arc<Self>,
        session: &Arc<Session>,
        name: Option<String>,
        cwd: Option<PathBuf>,
        session_env: std::collections::BTreeMap<String, String>,
        workspace_id: Option<String>,
        through: Option<u64>,
    ) -> Result<Arc<Session>, RpcError> {
        let parent_meta = session.meta();
        let (is_claude, mut fork_env) = self.harness_env(&parent_meta).await;
        // The fork's workspace: the one the request names (typed or in its
        // env, `session_env::workspace_id`), else its parent's.
        let workspace_id = workspace_id.or_else(|| parent_meta.workspace_id.clone());
        crate::agent_displays::mark(&mut fork_env, workspace_id.as_deref());
        let sid = parent_meta
            .agent_session_id
            .clone()
            .ok_or_else(|| RpcError::internal("no agent session"))?;
        let cwd = cwd.unwrap_or_else(|| parent_meta.cwd.clone());
        // The fork's own folder as it is now, not the parent's start (`git_state.rs`).
        let git = {
            let cwd = cwd.clone();
            tokio::task::spawn_blocking(move || crate::git_state::GitState::read(&cwd))
                .await
                .unwrap_or_default()
        };
        let id = uuid::Uuid::now_v7().to_string();
        let turn_cut = {
            let cfg = self.config.read().await;
            cfg.profile(&parent_meta.harness)
                .and_then(|p| crate::config::turn_cut(&parent_meta.harness, p))
        };
        let cut = through.filter(|_| turn_cut.is_some());
        let mut turn_count = parent_meta.turn_count;
        let (res, new_sid) = if let Some(through) = cut {
            // The fork resumes a copy of the agent's transcript through that turn.
            let history = self
                .store
                .events(&session.id, 0, 500_000)
                .map_err(|e| RpcError::internal(e.to_string()))?;
            // The chat moved past that turn at its next event, which acpmux logs
            // before the next prompt reaches Claude.
            let cut_ms = history.iter().find(|e| e.seq > through).map_or(u64::MAX, |e| e.at);
            turn_count =
                history.iter().filter(|e| e.seq <= through && e.kind == "turn_result").count()
                    as u64;
            // Claude resumes from the project directory the copy sits in, and
            // Codex from the folder its rollout names.
            if cwd != parent_meta.cwd {
                return Err(RpcError::invalid_params(
                    "a fork through an earlier turn keeps the chat's folder",
                ));
            }
            let homes = self.harness_homes().with_env(&[&fork_env]);
            let copy = match turn_cut {
                Some(crate::config::TurnCut::Codex) => {
                    super::fork_at::codex_rollout_through(&homes.codex, &sid, cut_ms)
                }
                _ => super::fork_at::claude_transcript_through(&homes.claude, &sid, cut_ms),
            }
            .map_err(|e| RpcError::internal(format!("fork through turn: {e}")))?;
            (json!({}), copy)
        } else if is_claude {
            // The fork happens when the new session's process starts with
            // --resume <parent> --fork-session; no agent call now.
            (json!({}), String::new())
        } else {
            let child = self.child_for(session).await?;
            let all = self.config.read().await.profile(&parent_meta.harness).is_some_and(|p| {
                crate::agent_tools::lists_all_tools(&parent_meta.harness, p, &fork_env)
            });
            let res = child
                .request(
                    method::SESSION_FORK,
                    json!({"sessionId": sid, "cwd": cwd, "mcpServers": crate::agent_tools::acp_servers_for(parent_meta.remote_origin, &fork_env, &id, all)}),
                )
                .await?;
            let new_sid = res
                .get("sessionId")
                .and_then(Value::as_str)
                .ok_or_else(|| RpcError::internal("session/fork returned no sessionId"))?
                .to_owned();
            (res, new_sid)
        };
        let fork_seq = cut.unwrap_or_else(|| session.seq.load(Ordering::SeqCst));
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
            agent_session_id: if is_claude && cut.is_none() { None } else { Some(new_sid) },
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
            title_source: None,
            title_prompt: None,
            last_prompt: parent_meta.last_prompt.clone(),
            preview: parent_meta.preview.clone(),
            event_count: 0,
            turn_count,
            usage: None,
            permission_rules: None,
            tags: Default::default(),
            unread: false,
            claude_unstored: false,
            claude_profile: None,
            last_turn: None,
            // A fork of a remote-origin session stays remote-origin.
            remote_origin: parent_meta.remote_origin,
            // Never inherited: the fork request sets its own or runs without one.
            session_env,
            workspace_id,
            // The fork resumes the parent from its store, and its conversation lands there.
            chat_store: parent_meta.chat_store.clone(),
            adopted_cwd: None,
            harness_roots: vec![],
            composer_draft: None,
            // It runs the parent's mode: a spawn from other preset contents leaves it too.
            preset_mode_approval: parent_meta.preset_mode_approval.clone(),
            // Filled below with the fork's own seqs of the marked prompts it copies.
            bookmarks: Default::default(),
            // The fork keeps the chat's tools off (`hub/tools.rs`); its spawn lists them again.
            tools: crate::store::ToolInventory {
                off: parent_meta.tools.off.clone(),
                ..Default::default()
            },
            git_branch: git.branch,
            git_head: git.head,
            // The fork's own spend. Claude Code restores the parent's running cost into a
            // whole-chat fork; a fork through an earlier turn has no known baseline.
            totals: None,
            harness_cost_usd: if cut.is_none() { parent_meta.harness_cost_usd } else { None },
            // A fork is the person's new chat, never a sub-session of the parent's parent.
            subsession: None,
            subsession_limits: Default::default(),
        };
        let new = self.make_session(meta);
        if is_claude && cut.is_none() {
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
                        | "turn_started"
                        | "turn_result"
                        | "turn_end"
                ) {
                    // Each keeps its time: a later fork through it cuts Claude's
                    // transcript there (`fork_at.rs`), and a replay plays it then.
                    let marked = parent_meta.bookmarks.contains(&e.seq) && e.kind == "user_message";
                    let (copy, _) = self.append_at(&new, &e.dir, &e.kind, e.msg, None, Some(e.at));
                    if marked {
                        new.meta
                            .lock()
                            .unwrap_or_else(|e| e.into_inner())
                            .bookmarks
                            .insert(copy.seq);
                    }
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

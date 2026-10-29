//! Part of `Hub`; see `hub/mod.rs`. `session/fork`: a new session from a
//! parent's conversation. Its per-session env is the fork request's own,
//! never the parent's (session_env.rs). `through` (a Claude or Codex chat
//! only) forks through an earlier turn instead of the chat's end (`fork_at.rs`).
//!
//! A chat whose turn runs forks now, as it is (never "fork when the turn ends"):
//! a Claude or Codex chat resumes a copy of its transcript as it stands, another
//! agent forks by its own `session/fork`, and one that fails that mid-turn (OMP)
//! gets a new agent session that reads the chat's transcript with its first
//! prompt. The fork is idle: its copy of the running turn ends there as
//! cancelled, a tool call still running shown failed. The chat is not touched.

use super::*;
use std::sync::atomic::Ordering;

/// Why a chat with no turn cannot fork: its agent holds no conversation to copy yet.
const NOTHING_TO_FORK: &str =
    "the chat has no turn yet, so there is nothing to fork; send a message first";

/// How the fork's agent gets the chat's conversation.
enum Made {
    /// A copy of the agent's own transcript (Claude, Codex), under this id.
    Copy(String),
    /// Claude's `--resume <parent> --fork-session` when the fork's process starts.
    ClaudeResume,
    /// The agent's `session/fork` answer and its new session id.
    Agent(Value, String),
    /// A new agent session that gets acpmux's transcript of the chat with its first
    /// prompt (`rehydrate`): the agent could not fork the working chat.
    Fresh,
}

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
        let working = matches!(parent_meta.status, SessionStatus::Running | SessionStatus::Waiting);
        // The chat's running turn, which the fork copies cut off now.
        let running = if working && cut.is_none() { session.turn() } else { None };
        // Claude forks by `--resume <parent> --fork-session`, which needs a stored
        // conversation; a chat with no turn has none, and its fork would fail at its
        // first prompt ("No conversation found"). Refuse before a chat is made.
        if is_claude && cut.is_none() && parent_meta.turn_count == 0 && !working {
            return Err(RpcError::invalid_params(NOTHING_TO_FORK));
        }
        let mut turn_count = parent_meta.turn_count;
        let mut note: Option<String> = None;
        let fresh_note = |harness: &str| {
            format!(
                "{harness} cannot fork a chat mid-turn, so this fork's agent starts from the chat's transcript"
            )
        };
        let made = if let Some(through) = cut {
            // The fork resumes a copy of the agent's transcript through that turn.
            // The chat moved past that turn at its next event, which acpmux logs
            // before the next prompt reaches Claude. One pass that stops there; no
            // record is kept.
            let mut cut_ms = u64::MAX;
            let mut turns = 0u64;
            self.store
                .scan(&session.id, 0, &mut |e: EventRecord| {
                    if e.seq > through {
                        cut_ms = e.at;
                        return false;
                    }
                    turns += u64::from(e.kind == "turn_result");
                    true
                })
                .map_err(|e| RpcError::internal(e.to_string()))?;
            turn_count = turns;
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
            Made::Copy(copy)
        } else if running.is_some() && turn_cut.is_some() && cwd == parent_meta.cwd {
            // A working Claude or Codex chat: a copy of its transcript as it stands now.
            let homes = self.harness_homes().with_env(&[&fork_env]);
            let copy = match turn_cut {
                Some(crate::config::TurnCut::Codex) => {
                    super::fork_at::codex_rollout_through(&homes.codex, &sid, u64::MAX)
                }
                _ => super::fork_at::claude_transcript_now(&homes.claude, &sid),
            };
            match copy {
                Ok(copy) => Made::Copy(copy),
                // Nothing stored yet (its first turn just began): acpmux's transcript.
                Err(e) => {
                    tracing::info!(session = %session.id, "fork of a working chat from acpmux's transcript: {e}");
                    note = Some(fresh_note(&parent_meta.harness));
                    Made::Fresh
                }
            }
        } else if is_claude {
            // The fork happens when the new session's process starts with
            // --resume <parent> --fork-session; no agent call now.
            Made::ClaudeResume
        } else if working && !offers_fork(session.meta().agent_capabilities.as_ref()) {
            note = Some(fresh_note(&parent_meta.harness));
            Made::Fresh
        } else {
            // The idle pass never ends the parent's harness under its session/fork (`idle.rs`).
            self.touch(session);
            let _using = session.harness_use.read().await;
            let child = self.child_for(session).await?;
            // An agent that does not offer session/fork (Kimi, DeepSeek) answers it
            // with a bare internal error: refuse with the reason instead.
            if !offers_fork(session.meta().agent_capabilities.as_ref()) {
                return Err(RpcError::invalid_params(format!(
                    "{} cannot fork a chat: its agent does not offer session/fork",
                    parent_meta.harness
                )));
            }
            // The list the parent's agent got at its start (`spawn.rs`).
            let all = child.all_tools.load(std::sync::atomic::Ordering::Relaxed);
            let asked = child
                .request(
                    method::SESSION_FORK,
                    json!({"sessionId": sid, "cwd": cwd, "mcpServers": crate::agent_tools::acp_servers_for(parent_meta.remote_origin, &fork_env, &id, all)}),
                )
                .await;
            let working_now =
                matches!(session.meta().status, SessionStatus::Running | SessionStatus::Waiting);
            match asked {
                Ok(res) => {
                    let new_sid = res
                        .get("sessionId")
                        .and_then(Value::as_str)
                        .ok_or_else(|| RpcError::internal("session/fork returned no sessionId"))?
                        .to_owned();
                    Made::Agent(res, new_sid)
                }
                // An agent that fails a fork while the chat works (OMP answers a bare
                // "Internal error"): the fork is made from acpmux's transcript instead.
                Err(e) if working || working_now => {
                    tracing::info!(session = %session.id, "agent fork mid-turn failed, forking from the transcript: {}", e.message);
                    note = Some(fresh_note(&parent_meta.harness));
                    Made::Fresh
                }
                // The agent's own error is often bare ("Internal error"): say whose fork failed,
                // and why when the chat has no turn (Claude's ACP adapter fails those).
                Err(e) => {
                    let why = if parent_meta.turn_count == 0 {
                        NOTHING_TO_FORK.to_owned()
                    } else {
                        e.message.clone()
                    };
                    return Err(RpcError {
                        message: format!("{} could not fork this chat: {why}", parent_meta.harness),
                        ..e
                    });
                }
            }
        };
        let (res, new_sid) = match &made {
            Made::Agent(res, sid) => (res.clone(), Some(sid.clone())),
            Made::Copy(copy) => (json!({}), Some(copy.clone())),
            Made::ClaudeResume | Made::Fresh => (json!({}), None),
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
            spawn_argv: None,
            family: parent_meta.family.clone(),
            preset: parent_meta.preset.clone(),
            model_request: parent_meta.model_request.clone(),
            cwd,
            // A fork is a new chat. Its parent transcript is authorized through parent_id; it
            // must not inherit the parent's historical native session ids as its own.
            previous_agent_session_ids: Vec::new(),
            // The id was produced by this fork's actual harness, not by the parent's creation
            // family (which can be stale after a profile switch).
            agent_session_family: new_sid
                .as_ref()
                .map(|_| if is_claude { "claude".to_owned() } else { "non-claude".to_owned() }),
            agent_session_id: new_sid,
            status: SessionStatus::Idle,
            created_at: now,
            updated_at: now,
            last_seq: 0,
            parent_id: Some(session.id.clone()),
            fork_seq: Some(fork_seq),
            fork_parent_verified: Some(true),
            agent_info: parent_meta.agent_info.clone(),
            agent_capabilities: parent_meta.agent_capabilities.clone(),
            steering: parent_meta.steering,
            html_previews: parent_meta.html_previews,
            // The chat's own mode, model and effort, which the fork's agent is told again when it
            // loads (`replay_config`): an agent may answer session/fork with its defaults
            // instead (Codex), and the fork would then run another model than the chat.
            // A mode cmux set on the chat stays cmux's on its fork, which runs it too; the fork's
            // agent gets the mark back once it is put in that mode (`restore_mode_mark`).
            mode_set_by_cmux: parent_meta.mode_set_by_cmux.clone().filter(|mode| {
                crate::web_modes::mode_of(&parent_meta).as_deref() == Some(mode.as_str())
            }),
            modes: parent_meta
                .modes
                .clone()
                .or_else(|| res.get("modes").cloned().filter(|v| !v.is_null())),
            config_options: parent_meta
                .config_options
                .clone()
                .or_else(|| res.get("configOptions").cloned().filter(|v| !v.is_null())),
            models: parent_meta.models.clone(),
            permission_policy: parent_meta.permission_policy.clone(),
            policy_source: parent_meta.policy_source.clone(),
            title: None,
            title_source: None,
            title_prompt: None,
            title_asking: false,
            title_failures: 0,
            title_thin: false,
            last_prompt: parent_meta.last_prompt.clone(),
            preview: parent_meta.preview.clone(),
            event_count: 0,
            turn_count,
            usage: None,
            context_breakdown: None,
            // The account's limits, which the fork shares.
            usage_limits: parent_meta.usage_limits.clone(),
            available_commands: parent_meta.available_commands.clone(),
            goal: None,
            permission_rules: None,
            tags: Default::default(),
            unread: false,
            claude_unstored: false,
            hibernated_ms: 0,
            claude_profile: None,
            last_turn: None,
            // A fork of a remote-origin session stays remote-origin.
            remote_origin: parent_meta.remote_origin,
            vm_boundary: parent_meta.vm_boundary,
            // Never inherited: the fork request sets its own or runs without one.
            session_env,
            workspace_id,
            // The fork resumes the parent from its store, and its conversation lands there.
            chat_store: parent_meta.chat_store.clone(),
            adopted_cwd: None,
            harness_roots: vec![],
            watching: None,
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
            // Read for the fork's own folder when its agent starts.
            worktree: None,
            // The fork's own spend. Claude Code restores the parent's running cost into a
            // whole-chat fork; a fork through an earlier turn has no known baseline.
            totals: None,
            pull_requests: vec![],
            harness_cost_usd: if matches!(made, Made::ClaudeResume) {
                parent_meta.harness_cost_usd
            } else {
                None
            },
            // A fork is the person's new chat, never a sub-session of the parent's parent.
            subsession: None,
            subsession_limits: Default::default(),
            // A fork is the person's branch of the chat, never a spawn (`lineage.rs`).
            lineage: None,
            subagent_retry_open: false,
        };
        let new = self.make_session(meta);
        match made {
            Made::ClaudeResume => *new.fork_from.lock().unwrap() = Some(sid.clone()),
            // Its first prompt carries the chat's transcript (`hub/turns.rs`).
            Made::Fresh => new.rehydrate.store(true, Ordering::SeqCst),
            Made::Copy(_) | Made::Agent(..) => {}
        }
        self.store.save(&new.meta()).map_err(|e| RpcError::internal(e.to_string()))?;
        // The fork copies transcript records, never the parent's reported Git branch.
        self.restore_git_branch(&new, new.meta().git_branch);
        {
            let mut sessions = self.sessions.lock().unwrap();
            sessions.insert(id.clone(), new.clone());
            super::admission::claim(&id);
        }
        // Indexed again once published (`transfer.rs` `import_into`).
        self.child_tags.note(&new);
        // Copy the transcript-relevant history so attach replays it.
        // Read one record at a time; only these kinds are parsed.
        const COPIED: &[&str] = &[
            "user_message",
            "agent_message_chunk",
            "agent_thought_chunk",
            "tool_call",
            "tool_call_update",
            "plan",
            "turn_started",
            "turn_result",
            "turn_end",
        ];
        // The running turn's tool calls not settled yet, and its start's seq in the fork.
        let mut open_tools: Vec<(String, String)> = Vec::new();
        let mut running_turn_seq: Option<u64> = None;
        {
            let _ = self.store.scan_kinds(&session.id, COPIED, &mut |e: EventRecord| {
                if e.seq > fork_seq {
                    return false;
                }
                if running.is_some() {
                    let update = e.msg.pointer("/params/update");
                    let call = update.and_then(|u| u.get("toolCallId")).and_then(Value::as_str);
                    let settled = update
                        .and_then(|u| u.get("status"))
                        .and_then(Value::as_str)
                        .is_some_and(|s| matches!(s, "completed" | "failed"));
                    match (e.kind.as_str(), call) {
                        ("tool_call", Some(call)) if !settled => {
                            open_tools.push((call.to_owned(), e.dir.clone()));
                        }
                        ("tool_call" | "tool_call_update", Some(call)) if settled => {
                            open_tools.retain(|(c, _)| c != call);
                        }
                        _ => {}
                    }
                }
                let starts_running = e.kind == "turn_started"
                    && running.as_ref().is_some_and(|t| t.turn_seq == e.seq);
                {
                    // Each keeps its time: a later fork through it cuts Claude's
                    // transcript there (`fork_at.rs`), and a replay plays it then.
                    // A prompt's mark, or an answer's Pin (its `turn_result`), follows it.
                    let marked = parent_meta.bookmarks.contains(&e.seq)
                        && matches!(e.kind.as_str(), "user_message" | "turn_result");
                    let (copy, _) = self.append_at(&new, &e.dir, &e.kind, e.msg, None, Some(e.at));
                    if starts_running {
                        running_turn_seq = Some(copy.seq);
                    }
                    if marked {
                        new.meta
                            .lock()
                            .unwrap_or_else(|e| e.into_inner())
                            .bookmarks
                            .insert(copy.seq);
                    }
                }
                true
            });
        }
        // The fork's copy of the running turn ends now: its tool calls still running did not
        // finish here, and the turn is cancelled, so the fork is idle and its partial reply
        // reads as cut off. The chat's own turn goes on.
        if let Some(turn) = &running {
            for (call, dir) in &open_tools {
                let update = json!({"sessionUpdate": "tool_call_update", "toolCallId": call, "status": "failed", "_meta": {"acpmux": {"forkCut": true}}});
                let msg = json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": update}});
                self.append(&new, dir, "tool_call_update", msg);
            }
            let result = json!({"status": "cancelled", "stopReason": "cancelled", "detail": "forked", "turnId": turn.turn_id, "promptId": turn.prompt_id, "turnSeq": running_turn_seq});
            self.append(&new, "mux", "turn_result", result);
        }
        let mut forked = json!({"parentId": session.id, "forkSeq": fork_seq});
        if running.is_some() {
            forked["midTurn"] = json!(true);
        }
        if let Some(note) = &note {
            forked["note"] = json!(note);
            forked["from"] = json!("transcript");
            forked["harness"] = json!(parent_meta.harness);
        }
        self.append(&new, "mux", "forked", forked);
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

/// Whether an ACP agent's `initialize` capabilities offer `session/fork`. Capabilities
/// not known yet (the agent never started) count as offered: the agent then answers.
pub(crate) fn offers_fork(caps: Option<&Value>) -> bool {
    caps.is_none_or(|c| c.pointer("/sessionCapabilities/fork").is_some_and(|f| !f.is_null()))
}

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
use cmux_json::JsonSet as _;
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
    /// An explicit empty prefix: no native resume and no transcript rehydration.
    Empty,
}

/// A fork onto another harness (`session/fork` with `_meta.acpmux.harness`): the person picked
/// another harness's model in a started chat and sent a message (Leo 2026-11-11: "if i switch to
/// a different model in a chat, it should just be able to seamlesly within the same pane do
/// stuff"). The fork runs that harness, starts on `model`, shows the chat's history by reference
/// as any fork does, and its first prompt carries the chat's transcript to the new agent
/// (`rehydrate`): no agent can resume another harness's conversation.
#[derive(Debug, Clone, Default)]
pub struct Retarget {
    /// A family or profile name, as `session/new` takes it.
    pub harness: String,
    pub model: Option<String>,
    /// A remote device (the Web, or a peer forwarding for it) asked: the new harness starts as a
    /// chat that device starts would (`session/new`), remote-origin and in a reviewed asking
    /// mode the server settles (`remote_guard.rs` `settle_web_session_mode`), never in this
    /// Mac's start mode.
    pub remote: bool,
}

/// The new harness a [`Retarget`] resolves to.
struct Target {
    /// The fork runs as a remote-origin chat ([`Retarget::remote`], or its parent was one).
    remote: bool,
    agent: String,
    profile: crate::config::HarnessProfile,
    family: String,
    spawn_model: bool,
    model: Option<String>,
    /// The switch named its model (`Retarget::model`): a harness that cannot run it fails the
    /// switch, as an explicit model fails `session/new`, rather than running its own default.
    explicit_model: bool,
}

impl Hub {
    /// A fork's own turns: the turn results in its log after its `forked` record (the ones
    /// before it are the parent's, copied); its meta's `turn_count` starts at the parent's. None
    /// for a chat that is not a fork. Read once, at a first start that seeds the cost ledger
    /// (`hub/ledger` `seed`), parsing only those two kinds.
    pub(super) fn fork_own_turns(&self, meta: &SessionMeta) -> Option<u64> {
        meta.parent_id.as_ref()?;
        let (mut forked, mut turns) = (false, 0u64);
        let kinds = ["forked", "turn_result"];
        let scanned = self.store.scan_kinds(&meta.id, &kinds, &mut |e: EventRecord| {
            match e.kind.as_str() {
                "forked" => {
                    forked = true;
                    turns = 0;
                }
                _ => turns += u64::from(forked && e.dir == "mux"),
            }
            true
        });
        match scanned {
            Ok(()) => Some(turns),
            Err(e) => {
                tracing::debug!(session = %meta.id, "ledger seed: fork log: {e}");
                Some(0)
            }
        }
    }

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

    #[allow(clippy::too_many_arguments)]
    pub async fn fork(
        self: &Arc<Self>,
        session: &Arc<Session>,
        name: Option<String>,
        cwd: Option<PathBuf>,
        session_env: std::collections::BTreeMap<String, String>,
        workspace_id: Option<String>,
        through: Option<u64>,
        start_later: bool,
    ) -> Result<Arc<Session>, RpcError> {
        // The shared create future is large. Keep the public wrapper pointer-sized for
        // callers such as side sessions, which already nest several async operations.
        Box::pin(self.fork_with_boundary(
            session,
            name,
            cwd,
            session_env,
            workspace_id,
            through,
            None,
            start_later,
            None,
            None,
        ))
        .await
    }

    /// [`Hub::fork`] onto another harness ([`Retarget`]). A harness that resolves to the chat's
    /// own profile is an ordinary fork; its model is the caller's to set.
    #[allow(clippy::too_many_arguments)]
    pub async fn fork_to(
        self: &Arc<Self>,
        session: &Arc<Session>,
        retarget: Retarget,
        name: Option<String>,
        cwd: Option<PathBuf>,
        session_env: std::collections::BTreeMap<String, String>,
        workspace_id: Option<String>,
        start_later: bool,
    ) -> Result<Arc<Session>, RpcError> {
        Box::pin(self.fork_with_boundary(
            session,
            name,
            cwd,
            session_env,
            workspace_id,
            None,
            None,
            start_later,
            None,
            Some(retarget),
        ))
        .await
    }

    /// The harness a [`Retarget`] names, or None when it is the chat's own profile.
    async fn retarget_to(
        &self,
        parent: &SessionMeta,
        retarget: Retarget,
        cwd: &Path,
    ) -> Result<Option<Target>, RpcError> {
        let cfg = self.config.read().await;
        let remote = parent.remote_origin || retarget.remote;
        let r = self.resolve_new(
            &cfg,
            Some(retarget.harness.clone()),
            &None,
            retarget.model.as_deref(),
            remote,
            Some(cwd),
        )?;
        if r.agent == parent.harness {
            return Ok(None);
        }
        if r.profile.kind == crate::config::HarnessKind::Terminal {
            return Err(super::new_request::terminal_harness_refusal(&r.agent));
        }
        let family = crate::config::derive_family(&r.agent, &r.profile);
        // `${model}` in the profile or in its defaults' env, as `session/new` decides it
        // (`lifecycle.rs`): the model is a spawn parameter there, not a set_model call.
        let spawn_model = super::new_request::profile_takes_model_at_spawn(&r.profile)
            || r.defaults.env.values().any(|v| v.contains("${model}"));
        let explicit_model = retarget.model.is_some();
        Ok(Some(Target {
            remote,
            agent: r.agent.clone(),
            profile: r.profile.clone(),
            family,
            spawn_model,
            model: retarget.model.or_else(|| r.profile.model.clone()),
            explicit_model,
        }))
    }

    /// [`Hub::fork`] with an optional boundary (`fork_before.rs`), and with `sub` a fork that is
    /// `session`'s sub-session (`start_session` with `fork`, `hub/subsessions.rs`): its link and
    /// lineage are in its meta from the start, and its harness starts in the folder the start
    /// checked, pinned (`ensure_checked_child`), or the fork is closed and refused.
    #[allow(clippy::too_many_arguments)]
    pub(super) async fn fork_with_boundary(
        self: &Arc<Self>,
        session: &Arc<Session>,
        name: Option<String>,
        cwd: Option<PathBuf>,
        session_env: std::collections::BTreeMap<String, String>,
        workspace_id: Option<String>,
        through: Option<u64>,
        before: Option<(String, crate::store::ForkBefore)>,
        start_later: bool,
        sub: Option<SubsessionFork<'_>>,
        retarget: Option<Retarget>,
    ) -> Result<Arc<Session>, RpcError> {
        let empty = before.as_ref().is_some_and(|(_, b)| b.through_seq.is_none());
        let (subsession, lineage, checked) = match sub {
            Some(SubsessionFork { link, lineage, checked }) => {
                (Some(link), Some(lineage), Some(checked))
            }
            None => (None, None, None),
        };
        let parent_meta = session.meta();
        // Tests only: the parent's turn records its rules while the fork is being made.
        #[cfg(test)]
        {
            let seam = self.fork_seam.lock().unwrap_or_else(|e| e.into_inner()).take();
            if let Some((arrived, release)) = seam {
                let _ = arrived.send(());
                let _ = release.await;
            }
        }
        // Its agent started it (`created_by.rs`); a fork the person made records none.
        let created_by =
            lineage.as_ref().map(|l| super::created_by::agent(&l.parent, &parent_meta));
        let (is_claude, mut fork_env) = self.harness_env(&parent_meta).await;
        // The fork's workspace: the one the request names (typed or in its
        // env, `session_env::workspace_id`), else its parent's.
        let workspace_id = workspace_id.or_else(|| parent_meta.workspace_id.clone());
        crate::agent_displays::mark(&mut fork_env, workspace_id.as_deref());
        let cwd = cwd.unwrap_or_else(|| parent_meta.cwd.clone());
        // Onto another harness: its agent starts from the chat's transcript (`Made::Fresh`).
        let target = match retarget {
            Some(r) if before.is_none() && !empty && through.is_none() => {
                self.retarget_to(&parent_meta, r, &cwd).await?
            }
            Some(_) => {
                return Err(RpcError::invalid_params(
                    "a fork onto another harness forks the whole chat as it is now",
                ));
            }
            None => None,
        };
        let sid = parent_meta
            .agent_session_id
            .clone()
            .or_else(|| (empty || target.is_some()).then(String::new))
            .ok_or_else(|| {
                if before.is_some() {
                    super::fork_before::refused(
                        "fork.unreconstructable",
                        "no native conversation for the retained prefix",
                    )
                } else {
                    RpcError::internal("no agent session")
                }
            })?;
        // The fork's own folder as it is now, not the parent's start (`git_state.rs`).
        let git = {
            let cwd = cwd.clone();
            tokio::task::spawn_blocking(move || crate::git_state::GitState::read(&cwd))
                .await
                .unwrap_or_default()
        };
        let id = before
            .as_ref()
            .map(|(id, _)| id.clone())
            .unwrap_or_else(|| uuid::Uuid::now_v7().to_string());
        let turn_cut = {
            let cfg = self.config.read().await;
            cfg.profile(&parent_meta.harness)
                .and_then(|p| crate::config::turn_cut(&parent_meta.harness, p))
        };
        if before.is_some() && turn_cut.is_none() {
            return Err(super::fork_before::refused(
                "fork.unsupported",
                "the source harness no longer supports prompt boundaries",
            ));
        }
        let cut = through.filter(|_| turn_cut.is_some());
        let working = matches!(parent_meta.status, SessionStatus::Running | SessionStatus::Waiting);
        // The chat's running turn, which the fork copies cut off now.
        let running = if !empty && working && cut.is_none() { session.turn() } else { None };
        // Claude forks by `--resume <parent> --fork-session`, which needs a stored
        // conversation; a chat with no turn has none, and its fork would fail at its
        // first prompt ("No conversation found"). Refuse before a chat is made.
        if !empty
            && target.is_none()
            && is_claude
            && cut.is_none()
            && parent_meta.turn_count == 0
            && !working
        {
            return Err(RpcError::invalid_params(NOTHING_TO_FORK));
        }
        let mut turn_count = parent_meta.turn_count;
        let mut note: Option<String> = None;
        let fresh_note = |harness: &str| {
            format!(
                "{harness} cannot fork a chat mid-turn, so this fork's agent starts from the chat's transcript"
            )
        };
        // The parent's recorded rules as its agent's transcript was copied, read under
        // `input_handoff`: a prompt written before the copy has recorded what it carried
        // (`steer_end.rs` runs its `on_sent` under the handoff), and one written after it is
        // not in the copy. The handoff is held for a file copy, and for `session/fork` only
        // until its request is written: never while an agent answers.
        let rules_of = |m: &SessionMeta| (m.cmux_rules_in_transcript, m.cmux_rules_seq);
        let mut rules_at_copy = None;
        // A fork through a turn copies through its `turn_result`, before which the log holds
        // nothing back. A fork of now copies the tool output the log holds back too
        // (`store/deferred.rs`), read with the seq it copies through.
        // The fork shows the chat's history by reference: none of it is copied, so a fork costs
        // the same however long the chat (`store/fork_view.rs`). A fork before a prompt keeps its
        // copy and its durable journal (`fork_before.rs`); a store that cannot write a fork's
        // history later copies it too.
        let referenced = !empty && before.is_none() && self.store.writes_history();
        // The fork's cut, its held output and its reference to the chat's history, taken
        // together under the chat's append lock.
        let take_cut = || -> Result<(u64, Vec<Value>, Option<Reserved>), RpcError> {
            let _order = session.append_lock.lock().unwrap_or_else(|e| e.into_inner());
            let (fork_seq, held) = match cut {
                Some(cut) => (cut, Vec::new()),
                None => (
                    session.seq.load(Ordering::SeqCst),
                    session.log_deferral.lock().unwrap_or_else(|e| e.into_inner()).pending(),
                ),
            };
            // Named the chat's fork now, under the lock its records are appended under: a delete
            // or compaction of the chat from here on writes the history into the fork first.
            let reserved = if referenced {
                let reference =
                    crate::store::HistoryRef { session: session.id.clone(), through_seq: fork_seq };
                self.store
                    .reserve_reference(&id, &reference)
                    .map_err(|e| RpcError::internal(e.to_string()))?;
                Some(Reserved { store: &*self.store, fork: Some(id.clone()) })
            } else {
                None
            };
            Ok((fork_seq, held, reserved))
        };
        let mut cut_at_request = None;
        let made = if empty {
            turn_count = 0;
            Made::Empty
        } else if target.is_some() {
            // No agent resumes another harness's conversation: the new one reads the chat's.
            rules_at_copy = Some(session.read_meta(rules_of));
            Made::Fresh
        } else if let Some(through) = cut {
            // The fork resumes a copy of the agent's transcript through that turn.
            // The chat moved past that turn at its next event, which acpmux logs
            // before the next prompt reaches Claude. One pass that stops there; no
            // record is kept.
            let mut cut_ms = u64::MAX;
            let mut turns = 0u64;
            let mut prompts = 0usize;
            self.store
                .scan(&session.id, 0, &mut |e: EventRecord| {
                    if e.seq > through {
                        cut_ms = e.at;
                        return false;
                    }
                    turns += u64::from(e.kind == "turn_result");
                    prompts += usize::from(e.kind == "user_message");
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
            let handoff = session.input_handoff.clone().lock_owned().await;
            let copy = match turn_cut {
                Some(crate::config::TurnCut::Codex) => {
                    super::fork_at::codex_rollout_through_checked(
                        &homes.codex,
                        &sid,
                        cut_ms,
                        before.as_ref().map(|_| prompts),
                    )
                }
                _ if before.is_none() => {
                    super::fork_at::claude_transcript_through(&homes.claude, &sid, cut_ms)
                }
                _ => super::fork_at::claude_transcript_through_checked(
                    &homes.claude,
                    &sid,
                    cut_ms,
                    Some(prompts),
                ),
            }
            .map_err(|e| {
                if before.is_some() {
                    super::fork_before::refused(
                        "fork.unreconstructable",
                        &format!("fork through turn: {e}"),
                    )
                } else {
                    RpcError::internal(format!("fork through turn: {e}"))
                }
            })?;
            rules_at_copy = Some(session.read_meta(rules_of));
            drop(handoff);
            Made::Copy(copy)
        } else if running.is_some() && turn_cut.is_some() && cwd == parent_meta.cwd {
            // A working Claude or Codex chat: a copy of its transcript as it stands now.
            let homes = self.harness_homes().with_env(&[&fork_env]);
            let handoff = session.input_handoff.clone().lock_owned().await;
            let copy = match turn_cut {
                Some(crate::config::TurnCut::Codex) => {
                    super::fork_at::codex_rollout_through(&homes.codex, &sid, u64::MAX)
                }
                _ => super::fork_at::claude_transcript_now(&homes.claude, &sid),
            };
            rules_at_copy = Some(session.read_meta(rules_of));
            drop(handoff);
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
            let mut fork_params = json!({"sessionId": sid, "cwd": cwd, "mcpServers": crate::agent_tools::acp_servers_for(parent_meta.remote_origin, &fork_env, &id, all)});
            // The parent's folders, as its own start gave them (`additional_dirs.rs`).
            if let Some(dirs) = super::additional_dirs::acp_value(&parent_meta) {
                fork_params.set(super::additional_dirs::FIELD, dirs);
            }
            // Let go once the request is written: an agent may take long to answer, or never.
            // The cut is taken then too: the agent's fork holds what it read before this request,
            // so a prompt the chat takes while it answers is not in the fork's history either.
            let handoff = session.input_handoff.clone().lock_owned().await;
            let seen = std::sync::Mutex::new(None);
            let asked = child
                .request_with_hook(method::SESSION_FORK, fork_params, None, || {
                    *seen.lock().unwrap_or_else(|e| e.into_inner()) =
                        Some((session.read_meta(rules_of), take_cut()));
                    drop(handoff);
                })
                .await;
            if let Some((rules, cut)) = seen.into_inner().unwrap_or_else(|e| e.into_inner()) {
                rules_at_copy = Some(rules);
                cut_at_request = Some(cut);
            }
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
            Made::ClaudeResume | Made::Fresh | Made::Empty => (json!({}), None),
        };
        // An agent's `session/fork` took its cut as its request was written (above); any other
        // fork takes it now.
        let (fork_seq, held_output, reserved) = match cut_at_request {
            Some(taken) => taken?,
            None => take_cut()?,
        };
        let name_given = name.is_some();
        let name = name.unwrap_or_else(|| self.unique_name(&format!("{}-fork", parent_meta.name)));
        let now = now_ms();
        let fork_dirs =
            super::additional_dirs::without_cwd(parent_meta.additional_directories.clone(), &cwd);
        // A fork into another folder takes that folder's guidance and instructions, sent with
        // its first turn even when the parent had already sent its own.
        let moved = !parent_meta.remote_origin && !same_folder(&cwd, &parent_meta.cwd);
        let cmux_context = if !parent_meta.remote_origin
            && (empty
                || moved
                || (matches!(made, Made::Fresh) && parent_meta.cmux_context.is_none()))
        {
            let cfg = self.config.read().await;
            let family = crate::context_inventory::family_for_folder(&cfg, &parent_meta.harness);
            let parts =
                crate::context_inventory::snapshot_for(&cfg, &cwd, &parent_meta.harness, false);
            // A native fork's agent keeps the parent's transcript, the old folder's
            // instructions in it: the new ones say those no longer apply.
            if moved && matches!(made, Made::Agent(..) | Made::ClaudeResume) {
                Some(crate::folder_instructions::moved(parts, &family, &cwd, &parent_meta.cwd))
            } else {
                Some(crate::folder_instructions::retarget(parts, &family, &cwd))
            }
        } else {
            parent_meta.cmux_context.clone()
        };
        // A fork that copied nothing now (`--resume --fork-session` at its start) reads them
        // after the cut: its parent's turn may have recorded its rules since `parent_meta`.
        let (recorded, recorded_seq) = rules_at_copy.unwrap_or_else(|| session.read_meta(rules_of));
        let rules_kept = !matches!(made, Made::Fresh | Made::Empty)
            && !moved
            && crate::context_inventory::fork_keeps_rules(recorded, recorded_seq, fork_seq);
        let mut meta = SessionMeta {
            schema: META_SCHEMA.into(),
            id: id.clone(),
            name,
            name_given,
            harness: parent_meta.harness.clone(),
            harness_argv: parent_meta.harness_argv.clone(),
            spawn_argv: None,
            launch_digest: None,
            family: parent_meta.family.clone(),
            preset: parent_meta.preset.clone(),
            model_request: parent_meta.model_request.clone(),
            cwd,
            // A fork sees what its parent saw, but never its own folder twice.
            additional_directories: fork_dirs,
            // A fork is a new chat. Its parent transcript is authorized through parent_id; it
            // must not inherit the parent's historical native session ids as its own.
            previous_agent_session_ids: Vec::new(),
            retired_agent_session_ids: Vec::new(),
            // The id was produced by this fork's actual harness, not by the parent's creation
            // family (which can be stale after a profile switch).
            agent_session_family: new_sid
                .as_ref()
                .map(|_| if is_claude { "claude".to_owned() } else { "non-claude".to_owned() }),
            agent_session_id: new_sid,
            status: SessionStatus::Idle,
            created_at: now,
            updated_at: now,
            // A referencing fork's own records follow the history it shows.
            last_seq: if referenced { fork_seq } else { 0 },
            transcript_seq: if referenced { fork_seq } else { 0 },
            parent_id: Some(session.id.clone()),
            fork_seq: if empty { None } else { Some(fork_seq) },
            fork_before: before.as_ref().map(|(_, b)| b.clone()),
            history_from: referenced.then(|| crate::store::HistoryRef {
                session: session.id.clone(),
                through_seq: fork_seq,
            }),
            history_kept_through: None,
            fork_requests: Default::default(),
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
            config_options: parent_meta.config_options.clone().or_else(|| {
                res.get("configOptions").cloned().filter(|v| !v.is_null()).map(Into::into)
            }),
            models: parent_meta.models.clone(),
            permission_policy: parent_meta.permission_policy.clone(),
            policy_source: parent_meta.policy_source.clone(),
            title: None,
            title_source: None,
            title_prompt: None,
            title_asking: false,
            title_failures: 0,
            title_thin: false,
            last_prompt: if before.is_some() { None } else { parent_meta.last_prompt.clone() },
            preview: if before.is_some() { None } else { parent_meta.preview.clone() },
            event_count: 0,
            turn_count,
            usage: None,
            context_breakdown: None,
            cmux_context,
            cmux_preset_prompt: parent_meta.cmux_preset_prompt.clone(),
            // Fresh reconstruction copies visible history only; hidden guidance must
            // reach the new harness again. Native transcript forks already retain it.
            cmux_context_delivered: !matches!(made, Made::Fresh | Made::Empty)
                && !moved
                && parent_meta.cmux_context_delivered,
            // Rules the parent's transcript carries, which a native fork keeps when its cut is
            // after the turn that carried them; from its own start on, so its own forks keep
            // them at any cut.
            cmux_rules_in_transcript: rules_kept,
            cmux_rules_seq: rules_kept.then_some(0),
            // The account's limits, which the fork shares.
            usage_limits: parent_meta.usage_limits.clone(),
            available_commands: parent_meta.available_commands.clone(),
            goal: None,
            permission_rules: None,
            tags: Default::default(),
            unread: false,
            seen_seq: None,
            unread_turns: 0,
            last_return: None,
            claude_unstored: false,
            // Never the parent's: only its creator asks (`SessionMeta::wait_start`).
            wait_start: false,
            hibernated_ms: 0,
            idle_launch: None,
            moved_to: None,
            claude_profile: None,
            last_turn: None,
            auth_change: None,
            harness_failures: Default::default(),
            harness_sandbox: Default::default(),
            // A fork of a remote-origin session stays remote-origin, and a remote device's switch
            // onto another harness is that device's new chat ([`Retarget::remote`]).
            remote_origin: parent_meta.remote_origin || target.as_ref().is_some_and(|t| t.remote),
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
            // The chat's marks on the history the fork shows by reference, under their own seqs;
            // a copy fills them below with the fork's seqs of the marked prompts it copies.
            bookmarks: if referenced {
                parent_meta.bookmarks.iter().copied().filter(|seq| *seq <= fork_seq).collect()
            } else {
                Default::default()
            },
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
            pull_request_times: Default::default(),
            touched_files: vec![],
            harness_cost_usd: if matches!(made, Made::ClaudeResume) {
                parent_meta.harness_cost_usd
            } else {
                None
            },
            // A fork is the person's new chat, never a sub-session of the parent's parent; one
            // an agent started of its own chat is that chat's sub-session (`sub`).
            subsession,
            subsession_limits: Default::default(),
            races: Default::default(),
            plan_builds: Default::default(),
            // A fork is the person's branch of the chat, never a spawn (`lineage.rs`), unless
            // its agent started it (`sub`).
            created_by,
            lineage,
            subagent_retry_open: false,
            // The person's setting for the chat it came from, not for the fork.
            turn_cap_ms: None,
            turn_cap_noticed: None,
            delegator: None,
            cold: None,
        };
        // Onto another harness: the new one's own launch, and nothing its agent would not know
        // (the old agent's modes, options, models, commands and store). The mode and model are
        // set once it is up (below).
        if let Some(t) = &target {
            meta.harness = t.agent.clone();
            meta.harness_argv = t.profile.argv.clone();
            meta.family = Some(t.family.clone());
            meta.preset = None;
            meta.model_request = if t.spawn_model { t.model.clone() } else { None };
            meta.agent_info = None;
            meta.agent_capabilities = None;
            meta.mode_set_by_cmux = None;
            meta.modes = None;
            meta.config_options = None;
            meta.models = None;
            meta.usage_limits = None;
            meta.available_commands = None;
            meta.chat_store = None;
            meta.preset_mode_approval = None;
            meta.harness_cost_usd = None;
        }
        if (empty || target.is_some()) && !meta.remote_origin {
            let cfg = self.config.read().await;
            meta.cmux_preset_prompt = crate::context_inventory::preset_override(&meta, &cfg);
            meta.cmux_context = Some(crate::context_inventory::snapshot_session(&meta, &cfg));
        }
        let new = self.make_session(meta);
        match made {
            Made::ClaudeResume => *new.fork_from.lock().unwrap() = Some(sid.clone()),
            // Its first prompt carries the chat's transcript (`hub/turns.rs`).
            Made::Fresh => {
                // A fork onto another harness: its agent is told it was forked from the chat, and
                // whose the earlier replies are (Leo, 2026-11-11: "ChatGPT can have, like, a small
                // little briefing of, like, you were forked from this chat").
                if new.meta().harness != parent_meta.harness {
                    *new.rehydrate_note.lock().unwrap_or_else(|e| e.into_inner()) = Some(format!(
                        "this chat was forked from {} chat {} ({}) when the person switched to you; the conversation so far is below, and the earlier replies are {}'s, not yours; carry on from where it ended; tool state was not restored",
                        parent_meta.harness, parent_meta.name, session.id, parent_meta.harness
                    ));
                }
                new.rehydrate.store(true, Ordering::SeqCst)
            }
            Made::Copy(_) | Made::Agent(..) | Made::Empty => {}
        }
        if let Err(e) = self.write_meta(&new) {
            // Never published: no session owns the conversation this fork copied or its agent
            // made, so remove it rather than leave a discoverable orphan (an inline /btw's fork
            // asks about a chat that must not outlive the question).
            if let Some(copied) = new.meta().agent_session_id.filter(|copied| *copied != sid) {
                let family =
                    parent_meta.family.clone().unwrap_or_else(|| parent_meta.harness.clone());
                let homes = self.harness_homes().with_env(&[&fork_env]);
                super::btw::remove_transcript_in(&homes, &family, &copied);
            }
            return Err(RpcError::internal(e.to_string()));
        }
        // The fork copies transcript records, never the parent's reported Git branch.
        self.restore_git_branch(&new, new.meta().git_branch);
        {
            let mut sessions = self.sessions.lock().unwrap();
            sessions.insert(id.clone(), new.clone());
            super::admission::claim(&id);
        }
        self.update_live_session_index(&new);
        // A session that came may be another row's parent: every closed row is built again.
        self.events.changed();
        // Indexed again once published (`transfer.rs` `import_into`).
        self.child_tags.note(&new);
        let creation_guard = super::lifecycle::CreationGuard::new(self.clone(), new.clone(), 0);
        // From here a failed fork is purged, and its reference with it.
        if let Some(reserved) = reserved {
            reserved.disarm();
        }
        // Copy the transcript-relevant history so attach replays it.
        // Read one record at a time; only these kinds are parsed. The copies are stored under one
        // hold of the fork's append lock and sent to no client one by one: nothing is attached
        // to the fork yet, and every watcher of every chat heard each copied turn's records (a
        // summary per record, the app's whole list lagging past 8192). Watchers hear of the
        // fork once, from its `forked` record; an attach replays the copy from the log. Each
        // record's paths were made canonical when its chat stored it.
        const COPIED: &[&str] = crate::store::HISTORY_KINDS;
        // The running turn's tool calls not settled yet, and its start's seq in the fork.
        let mut open_tools: Vec<(String, String)> = Vec::new();
        let mut running_turn_seq: Option<u64> = None;
        // Cancel stops the copy where it is; the fork is then discarded whole (`fork_cancel.rs`).
        let mut cancelled = false;
        if referenced {
            // Only the running turn is read, from its start: which of its tool calls still run.
            if let Some(turn) = &running {
                running_turn_seq = Some(turn.turn_seq);
                self.store
                    .scan(&session.id, turn.turn_seq.saturating_sub(1), &mut |e: EventRecord| {
                        if e.seq > fork_seq {
                            return false;
                        }
                        note_open_tool(&mut open_tools, &e);
                        true
                    })
                    .map_err(|e| RpcError::internal(e.to_string()))?;
            }
        } else {
            // The copies are the parent's turns: they count in the parent's cost, not here, until
            // the fork's own `forked` record below.
            self.ledger.suppress(&new.id);
            let order = new.append_lock.lock().unwrap_or_else(|e| e.into_inner());
            self.catch_up_locked(&new);
            let copied = self.store.scan_kinds(&session.id, COPIED, &mut |e: EventRecord| {
                if empty || e.seq > fork_seq {
                    return false;
                }
                if super::fork_cancel::cancelled() {
                    cancelled = true;
                    return false;
                }
                if running.is_some() {
                    note_open_tool(&mut open_tools, &e);
                }
                let starts_running = e.kind == "turn_started"
                    && running.as_ref().is_some_and(|t| t.turn_seq == e.seq);
                {
                    // Each keeps its time: a later fork through it cuts Claude's
                    // transcript there (`fork_at.rs`), and a replay plays it then.
                    // A prompt's mark, or an answer's Pin (its `turn_result`), follows it.
                    let marked = parent_meta.bookmarks.contains(&e.seq)
                        && matches!(e.kind.as_str(), "user_message" | "turn_result");
                    if before.is_some() && e.kind == "user_message" {
                        new.meta.lock().unwrap_or_else(|e| e.into_inner()).last_prompt = e
                            .msg
                            .get("text")
                            .and_then(Value::as_str)
                            .map(|text| short_text(text, 200));
                    }
                    let (copy, _) = self.append_at_locked(
                        &new,
                        &e.dir,
                        &e.kind,
                        e.msg,
                        None,
                        Some(e.at),
                        false,
                        false,
                    );
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
            drop(order);
            if cancelled {
                self.ledger.unsuppress(&new.id);
                return Err(super::fork_cancel::cancelled_refusal());
            }
            if before.is_some()
                && let Err(e) = copied
            {
                self.ledger.unsuppress(&new.id);
                return Err(super::fork_before::refused("fork.incomplete", &e.to_string()));
            }
        }
        // These too go to no watcher: the `forked` record below is the first one heard.
        for output in held_output {
            self.append_quiet(&new, "in", "tool_call_update", output);
        }
        // The fork's copy of the running turn ends now: its tool calls still running did not
        // finish here, and the turn is cancelled, so the fork is idle and its partial reply
        // reads as cut off. The chat's own turn goes on.
        if let Some(turn) = &running {
            for (call, dir) in &open_tools {
                let update = json!({"sessionUpdate": "tool_call_update", "toolCallId": call, "status": "failed", "_meta": {"acpmux": {"forkCut": true}}});
                let msg = json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": update}});
                self.append_quiet(&new, dir, "tool_call_update", msg);
            }
            let result = json!({"status": "cancelled", "stopReason": "cancelled", "detail": "forked", "turnId": turn.turn_id, "promptId": turn.prompt_id, "turnSeq": running_turn_seq});
            self.append_quiet(&new, "mux", "turn_result", result);
        }
        // The copied turn results are the parent's attempts, not the fork's: it starts unstuck,
        // and a restore scans only past them.
        {
            let mut m = new.meta.lock().unwrap_or_else(|e| e.into_inner());
            m.harness_failures = crate::session_liveness::HarnessFailures::after(m.last_seq);
            // Its own harness: a refusal the parent's records carry is not the fork's.
            m.harness_sandbox = Default::default();
        }
        let mut forked = json!({"parentId": session.id, "forkSeq": new.meta().fork_seq});
        if let Some((_, b)) = &before {
            forked.set("beforePromptId", json!(b.prompt_id));
            forked.set("promptSeq", json!(b.prompt_seq));
        }
        if running.is_some() {
            forked.set("midTurn", json!(true));
        }
        if let Some(note) = &note {
            forked.set("note", json!(note));
            forked.set("from", json!("transcript"));
            forked.set("harness", json!(parent_meta.harness));
        }
        if let Some(t) = &target {
            forked.set("from", json!("transcript"));
            forked.set("harness", json!(t.agent));
            forked.set("fromHarness", json!(parent_meta.harness));
        }
        self.ledger.unsuppress(&new.id);
        self.append(&new, "mux", "forked", forked);
        if before.is_none() {
            self.append(session, "mux", "fork_child", json!({"childId": id}));
        } else {
            // Publish the durable result before any await can lose the reply. A partial
            // journal stays reserved and is never mistaken for a completed child on retry.
            if new.append_errors.load(Ordering::SeqCst) != 0 {
                return Err(super::fork_before::refused(
                    "fork.incomplete",
                    "child journal could not be stored",
                ));
            }
            self.store
                .flush_session(&new.id)
                .map_err(|e| super::fork_before::refused("fork.incomplete", &e.to_string()))?;
            let mut meta = new.meta.lock().unwrap_or_else(|e| e.into_inner());
            let mut ready = meta.clone();
            if let Some(boundary) = ready.fork_before.as_mut() {
                boundary.ready = true;
            }
            self.store
                .save(&ready)
                .and_then(|()| self.store.flush_session(&new.id))
                .map_err(|e| super::fork_before::refused("fork.incomplete", &e.to_string()))?;
            *meta = ready;
        }
        // The forked agent session lives in the parent's process. Load it in
        // its own process so one session keeps one child. Fork Conversation
        // (`start_later`) answers first: the fork's model, effort, env and
        // history are all in its meta and log by now, a harness start takes
        // seconds, and the fork's first prompt waits for this start (`child_for`
        // holds the spawn lock). A start that fails says why at that prompt.
        // Cancelled once the copy was done: still discarded whole, before its agent starts.
        if super::fork_cancel::cancelled() {
            return Err(super::fork_cancel::cancelled_refusal());
        }
        self.save_meta(&new);
        creation_guard.disarm();
        if let Some(checked) = checked {
            // A sub-session's harness runs only in the folder its start checked, or not at all.
            if let Err(e) = self.start_checked_child(&new, checked).await {
                return Err(self.close_refused(&new, e).await);
            }
        } else if let Some(t) = &target {
            // Onto another harness: up, on the picked model and in the mode a new chat of it
            // starts in, before the reply, so the first prompt runs there (as `new_session`).
            if let Err(e) = self.start_retargeted(&new, t).await {
                return Err(self.close_refused(&new, e).await);
            }
        } else if start_later {
            let hub = self.clone();
            let fork = new.clone();
            tokio::spawn(async move {
                if let Err(e) = hub.child_for(&fork).await {
                    tracing::warn!(session = %fork.id, "fork child start failed: {e}");
                    // In the fork too, not only the log: a fork whose agent never started looked
                    // like a fork that worked (Leo's, 2026-11-06, agent session "-"). Its first
                    // prompt starts the agent again.
                    hub.append(&fork, "mux", "fork_start_failed", json!({"error": e.message}));
                }
            });
        } else if let Err(e) = self.child_for(&new).await {
            tracing::warn!(session = %new.id, "fork child start failed: {e}");
        }
        Ok(new)
    }
}

impl Hub {
    /// Starts a fork onto another harness ([`Retarget`]): its agent, its model when the
    /// harness takes it after spawn, and the mode a new chat of that harness starts in
    /// (`start_mode.rs`). Soft, as a new chat's start defaults: a step that fails is recorded
    /// on the fork, and its first prompt starts the agent again. Except a model the switch named
    /// that the harness takes over ACP: its agent must be up and take it, or the switch fails
    /// (the caller closes the fork), since the next prompt's start would run the harness's own
    /// default, another model than the one picked (review of cmux#41030, F2). A model taken at
    /// spawn is in the fork's `model_request`, which every start of its agent uses.
    async fn start_retargeted(
        self: &Arc<Self>,
        fork: &Arc<Session>,
        target: &Target,
    ) -> Result<(), RpcError> {
        let must_set = target.explicit_model && !target.spawn_model;
        if let Err(e) = self.child_for(fork).await {
            tracing::warn!(session = %fork.id, "fork child start failed: {e}");
            if must_set {
                return Err(e);
            }
            self.append(fork, "mux", "fork_start_failed", json!({"error": e.message}));
            return Ok(());
        }
        if !target.spawn_model
            && let Some(model) = &target.model
            && let Err(e) = Box::pin(self.set_model(fork, model)).await
        {
            if must_set {
                return Err(RpcError::invalid_params(format!(
                    "model {model:?} for {}: {}",
                    target.agent, e.message
                )));
            }
            tracing::warn!(session = %fork.id, model = %model, "fork model skipped: {}", e.message);
            self.append(
                fork,
                "mux",
                "start_default_skipped",
                json!({"model": model, "error": e.message}),
            );
        }
        // The start mode only where `session/new` would set one (`start_mode::mode_eligible`): never
        // over a profile that pins its mode (`--permission-mode default`), nor on a remote chain,
        // whose mode the remote guard settles.
        let remote = fork.meta().remote_origin;
        if super::start_mode::mode_eligible(true, remote, false, &target.profile)
            && let Some(mode) = Box::pin(self.start_mode(fork)).await
            && let Err(e) = Box::pin(self.set_mode(fork, &mode)).await
        {
            tracing::warn!(session = %fork.id, mode = %mode, "fork mode skipped: {}", e.message);
            self.append(
                fork,
                "mux",
                "start_default_skipped",
                json!({"modeId": mode, "error": e.message}),
            );
        }
        Ok(())
    }
}

/// A fork that is its parent's sub-session ([`Hub::fork_with_boundary`]).
pub(super) struct SubsessionFork<'a> {
    pub link: crate::store::SubsessionLink,
    pub lineage: crate::store::Lineage,
    /// The folder `start_session` checked, the parent's.
    pub checked: &'a super::subsession_guard::CheckedFolder,
}

/// A tool call `e` starts that has not settled, or one it settles: the running turn's calls
/// still open when the fork cuts it.
fn note_open_tool(open_tools: &mut Vec<(String, String)>, e: &EventRecord) {
    let update = e.msg.pointer("/params/update");
    let call = update.and_then(|u| u.get("toolCallId")).and_then(Value::as_str);
    let settled = update
        .and_then(|u| u.get("status"))
        .and_then(Value::as_str)
        .is_some_and(|s| matches!(s, "completed" | "failed"));
    match (e.kind.as_str(), call) {
        ("tool_call", Some(call)) if !settled => open_tools.push((call.to_owned(), e.dir.clone())),
        ("tool_call" | "tool_call_update", Some(call)) if settled => {
            open_tools.retain(|(c, _)| c != call);
        }
        _ => {}
    }
}

/// Whether an ACP agent's `initialize` capabilities offer `session/fork`. Capabilities
/// not known yet (the agent never started) count as offered: the agent then answers.
pub(crate) fn offers_fork(caps: Option<&Value>) -> bool {
    caps.is_none_or(|c| c.pointer("/sessionCapabilities/fork").is_some_and(|f| !f.is_null()))
}

/// Whether two session folders are the same folder: `/repo` and `/repo/.` or a link to it
/// are one folder, compared by where they resolve, or as written when one cannot resolve.
fn same_folder(a: &Path, b: &Path) -> bool {
    match (std::fs::canonicalize(a), std::fs::canonicalize(b)) {
        (Ok(a), Ok(b)) => a == b,
        _ => a == b,
    }
}

/// A fork's reservation of its chat's history ([`Store::reserve_reference`]), taken back if the
/// fork is not made before its creation guard takes over.
struct Reserved<'a> {
    store: &'a dyn crate::store::Store,
    /// None once disarmed.
    fork: Option<String>,
}

impl Reserved<'_> {
    fn disarm(mut self) {
        self.fork = None;
    }
}

impl Drop for Reserved<'_> {
    fn drop(&mut self) {
        if let Some(fork) = &self.fork {
            self.store.forget_reference(fork);
        }
    }
}

#[cfg(test)]
mod same_folder_tests {
    use super::same_folder;

    #[test]
    fn the_same_folder_spelled_another_way_is_not_a_move() {
        let dir = tempfile::tempdir().unwrap();
        let other = tempfile::tempdir().unwrap();
        assert!(same_folder(dir.path(), &dir.path().join(".")));
        assert!(!same_folder(dir.path(), other.path()));
    }
}

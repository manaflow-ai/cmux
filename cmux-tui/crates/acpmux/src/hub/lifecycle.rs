//! Part of `Hub`; see `hub/mod.rs`.

use super::*;

use super::adoption::{Adoption, adopted_in, start_folder};
use super::new_request::{claude_resume_refusal, unique_name_among};
// `turns.rs` names it here.
pub(super) use super::new_request::profile_takes_model_at_spawn;
use super::resolve::{Draft, Resolved, draft_meta};

impl Hub {
    // --------------------------------------------------------- lifecycle

    pub async fn new_session(self: &Arc<Self>, req: NewRequest) -> Result<Arc<Session>, RpcError> {
        // Harness discovery and launcher checks finish in the background.
        self.wait_startup().await;
        let NewRequest {
            harness,
            preset,
            name,
            cwd,
            policy,
            model,
            effort,
            adopt,
            remote,
            env: session_env,
            workspace_id,
            keep_harness_mode,
            starter,
            route,
            subsession,
            disallowed_tools,
            checked_cwd,
        } = req;
        // The proven agent session that asked for this one, as it is now; never for a remote
        // chat, and never one a remote connection started (`remote_origin`).
        let starter = starter
            .filter(|_| !remote)
            .and_then(|id| self.resolve(&id).ok().filter(|s| s.id == id))
            .filter(|s| !s.meta().remote_origin)
            .map(|s| s.id.clone());
        // An adopted session's harness names the head unless one was given.
        let harness = harness.or_else(|| adopt.as_ref().and_then(|a| a.harness.clone()));
        // Resolution is a lookup, never a guess: preset → head (family or
        // profile) → defaults chain → explicit values on top.
        let Resolved { agent, profile, defaults, head, preset_name, folder_root, preset_digest } = {
            let cfg = self.config.read().await;
            self.resolve_new(&cfg, harness, &preset, model.as_deref(), remote, cwd.as_deref())?
        };
        let agent = agent.as_str();
        if profile.kind == crate::config::HarnessKind::Terminal {
            return Err(terminal_harness_refusal(agent));
        }
        let family = crate::config::derive_family(agent, &profile);
        // No policy asked: the defaults' when it is no wider than a starter's, else the starter's
        // own (`start_mode.rs`, "Inherit").
        let inherits_policy = policy.is_none() && starter.is_some();
        let policy = match (policy, starter.as_deref()) {
            (Some(asked), _) => Some(asked),
            (None, Some(id)) => {
                let daemon = self.config.read().await.permission_policy;
                super::start_mode::inherited_policy(defaults.policy, self.own_policy(id), daemon)
            }
            (None, None) => defaults.policy,
        };
        // `${model}` in argv or env: the model is a spawn parameter, not a
        // set_model call.
        let spawn_model = profile_takes_model_at_spawn(&profile)
            || defaults.env.values().any(|v| v.contains("${model}"));
        // What a new chat starts on when nothing pins it (start_defaults.rs):
        // the saved default (acpmux defaults or the person's pick), else the catalog default.
        // A request value, a preset, a folder profile, a profile's own
        // model/effort (or a model in its argv or env) and an adopted
        // conversation keep today's chain (request, then `defaults`).
        let eligible = adopt.is_none() && preset_name.is_none() && folder_root.is_none();
        // The start mode also skips a remote-origin session (the remote
        // guard settles its mode) and a profile that pins its mode.
        let mode_eligible =
            super::start_mode::mode_eligible(eligible, remote, keep_harness_mode, &profile);
        // A harness that takes its model at spawn (Claude Code's `--model`)
        // gets the start model there (`model_request` below).
        let model_pinned = model.is_some()
            || !eligible
            || profile.model.is_some()
            || super::start_defaults::profile_sets_model(&profile, &defaults.env);
        let effort_pinned = effort.is_some() || !eligible || profile.effort.is_some();
        let pinned_model =
            if model_pinned { model.or_else(|| defaults.model.clone()) } else { None };
        let (start_model, start_effort) = if eligible {
            self.start_defaults(agent, &profile, &defaults, pinned_model.as_deref())
        } else {
            (None, None)
        };
        // A catalog default (not a saved pick) is skipped when the harness doesn't offer it.
        let model_from_catalog = !model_pinned
            && start_model
                .as_ref()
                .is_some_and(|s| s.source == super::start_defaults::StartSource::Catalog);
        let (model, model_soft) = match (model_pinned, start_model) {
            (true, _) | (false, None) => (pinned_model, false),
            (false, Some(start)) => (Some(start.value), true),
        };
        let (effort, effort_soft) = match (effort_pinned, start_effort) {
            (true, _) | (false, None) => (effort.or_else(|| defaults.effort.clone()), false),
            (false, Some(start)) => (Some(start.value), true),
        };
        // Adopting checks the id against the harness's own store before
        // anything is created, and takes the conversation's recorded cwd.
        let env = [&defaults.env, &profile.env];
        let (recorded, fork, adopted_file, chat_store) =
            match self.adoption(adopt.as_ref(), agent, &family, &env, remote).await? {
                Adoption::Existing(existing) => return Ok(existing),
                Adoption::Found { cwd, fork, file, store } => (cwd, fork, file, store),
            };
        // A fork resumes nothing as itself: it forks the adopted id into a new conversation.
        let fork_from = adopt.as_ref().filter(|_| fork).map(|a| a.agent_session_id.clone());
        // A gone recorded folder may be remapped: git runs to compare repositories.
        let cwd_map = adopt.as_ref().map(|a| a.cwd_map.clone()).unwrap_or_default();
        let fam = family.clone();
        let (cwd, adopted_cwd, git) =
            tokio::task::spawn_blocking(move || start_folder(cwd, recorded, &fam, &cwd_map))
                .await
                .map_err(|e| RpcError::internal(e.to_string()))??;
        // A folder profile runs only in chats whose folder is inside its folder (H4).
        if let Some(root) = &folder_root
            && !std::fs::canonicalize(&cwd).unwrap_or_else(|_| cwd.clone()).starts_with(root)
        {
            return Err(RpcError::invalid_params(format!(
                "harness {agent} is a folder profile of {}; the chat folder must be inside it",
                root.display()
            )));
        }
        let mut meta = draft_meta(Draft {
            id: String::new(),
            agent,
            profile: &profile,
            family: &family,
            preset: preset_name.clone(),
            model_request: if spawn_model { model.clone() } else { None },
            cwd,
            // Set before the first spawn, so the harness resumes it.
            agent_session_id: adopt
                .as_ref()
                .filter(|_| fork_from.is_none())
                .map(|a| a.agent_session_id.clone()),
            policy,
            remote,
        });
        (meta.session_env, meta.chat_store, meta.adopted_cwd, meta.git_branch, meta.git_head) =
            (session_env, chat_store, adopted_cwd, git.branch, git.head);
        meta.workspace_id = workspace_id;
        meta.subsession = subsession;
        meta.tools
            .off
            .extend(disallowed_tools.iter().map(|t| format!("{}{t}", super::tools::BUILT_IN)));
        // A pooled session of exactly this shape (`pool/`) gives the session its id; `ensure_child`
        // then takes it instead of starting cold. Never with this session's own env, route or
        // disallowed tools, nor in a folder a sub-session start checked: a pooled harness started
        // wherever the path led.
        let pooled = match &adopt {
            None if meta.session_env.is_empty()
                && route.is_none()
                && meta.tools.off.is_empty()
                && checked_cwd.is_none() =>
            {
                self.pool_claim(&meta, &profile, &defaults.env).await
            }
            _ => None,
        };
        // Every way out of here (an error, or this future dropped) before
        // `ensure_child` took the entry puts it back or ends it.
        let _claim = pooled.as_ref().map(|id| self.pool_claim_guard(id.clone()));
        let id = pooled.unwrap_or_else(|| uuid::Uuid::now_v7().to_string());
        meta.id = id.clone();
        // A named route is checked before anything is created: it exists and
        // serves this chat's harness family.
        if let Some(route_id) = &route {
            self.check_new_route(route_id, &family).await?;
        }
        // Pick or check the name and insert under one lock, so concurrent
        // creations can never publish the same name twice.
        let session = {
            let mut sessions = self.sessions.lock().unwrap();
            // The shutdown reads the sessions after it starts: a session
            // inserted after that is never ended, so none is (shutdown.rs).
            if self.shutting_down() {
                return Err(super::shutdown::shutting_down_error());
            }
            // Checked again under the insert lock: two concurrent adopts of
            // one id get one session.
            if let Some(a) = adopt.as_ref().filter(|_| fork_from.is_none())
                && let Some(existing) = adopted_in(&sessions, &family, &a.agent_session_id)
            {
                return Ok(existing);
            }
            meta.name = match name {
                Some(n) => {
                    if sessions.values().any(|s| s.meta().name == n) {
                        return Err(RpcError::invalid_params(format!(
                            "session name {n:?} is taken"
                        )));
                    }
                    // Named by the person: no generated title (`titles.rs`).
                    meta.title_source = Some(super::titles::NAMED.to_owned());
                    n
                }
                // A pooled harness was started under its name: keep it.
                None => match self
                    .pool_claimed_name(&id)
                    .filter(|n| !sessions.values().any(|s| s.meta().name == *n))
                {
                    Some(n) => n,
                    None => unique_name_among(&sessions, agent),
                },
            };
            let session = self.make_session(meta);
            *session.fork_from.lock().unwrap_or_else(std::sync::PoisonError::into_inner) =
                fork_from.clone();
            sessions.insert(id.clone(), session.clone());
            session
        };
        if let Err(e) = self.store.save(&session.meta()) {
            self.sessions.lock().unwrap().remove(&id);
            return Err(RpcError::internal(e.to_string()));
        }
        // The chat's route is bound once the session exists and before its
        // harness starts, so its first spawn already runs on it (route_switch.rs).
        if let Some(route_id) = &route {
            let (_, state) = crate::routes::places(&*self.config.read().await);
            if let Err(e) =
                crate::routes::set_binding(&state, &format!("chat:{id}"), Some(route_id))
            {
                self.sessions.lock().unwrap().remove(&id);
                return Err(RpcError::invalid_params(e.message().to_owned()));
            }
        }
        // No `git` record exists yet; retain that baseline even if the chat grows before attach.
        self.restore_git_branch(&session, session.meta().git_branch);
        self.append(&session, "mux", "created", json!({"harness": agent, "preset": preset_name}));
        if let Some(a) = &adopt {
            let adopted = if fork_from.is_some() {
                json!({"agentSessionId": a.agent_session_id, "fork": true})
            } else {
                json!({"agentSessionId": a.agent_session_id})
            };
            self.append(&session, "mux", "adopted", adopted);
        }
        self.note_preset_resolved(&session, preset_digest);
        // A watch starts no harness: it shows and follows the transcript (`watch.rs`).
        if let (Some(file), true) = (&adopted_file, adopt.as_ref().is_some_and(|a| a.watch)) {
            return Ok(self.begin_watch(&session, &family, file.clone()));
        }
        let spawned = match self.spawn_profile(&session, &profile, &defaults.env).await {
            Ok(spawn) => self.ensure_checked_child(&session, &spawn, checked_cwd.as_ref()).await,
            Err(e) => Err(e),
        };
        if let Err(e) = spawned {
            // A session whose agent never started is not left behind, and
            // neither is a child that spawned but failed to initialize.
            let _ = self.kill(&session, true).await;
            return Err(e);
        }
        // An agent that started fresh instead of resuming fails creation.
        if let Some(a) = adopt.as_ref().filter(|_| fork_from.is_none()) {
            self.check_resumed(&session, a, agent).await?;
            // The adopted chat shows its past at once: Claude Code's resume replays nothing, and a
            // Codex session/load's history is logged as `.replay` records no client shows, so both
            // replay their own transcript (OpenCode's store is a database: not replayed).
            if matches!(family.as_str(), "claude" | "codex")
                && let Some(file) = adopted_file.clone()
            {
                self.replay_adopted(&session, &family, file).await;
            }
        }
        // Defaults and explicit values, applied once the harness is up. A bad
        // value fails creation loudly rather than starting a session that
        // silently runs another model.
        let applied: Result<(), RpcError> = async {
            if let Some(m) = &model
                && !spawn_model {
                    // `opencode/big-pickle` was written as `-m opencode/big-pickle`:
                    // the harness lacks `big-pickle` but lists `opencode/big-pickle`.
                    let catalog = self.catalog_ids(agent).await;
                    let full = format!("{head}/{m}");
                    let m = if !catalog.is_empty() && !catalog.iter().any(|id| id == m) && catalog.contains(&full) { full } else { m.clone() };
                    // A start value this session's harness does not list (its account
                    // lacks it): the harness accepts set_model, then fails every prompt.
                    if model_from_catalog && !self.harness_offers(agent, &profile, &m) {
                        tracing::warn!(harness = agent, model = %m, "start model skipped: not offered by the harness");
                        self.append(&session, "mux", "start_default_skipped", json!({"modelId": m, "error": "the harness does not offer this model"}));
                    } else if let Err(e) = self.set_model(&session, &m).await {
                        // A start value the harness refuses (start_defaults.rs): the
                        // chat runs the harness's own default instead.
                        if model_soft {
                            tracing::warn!(harness = agent, model = %m, "start model skipped: {}", e.message);
                            self.append(&session, "mux", "start_default_skipped", json!({"modelId": m, "error": e.message}));
                        } else if e.message.contains("Method not found") {
                            return Err(RpcError::invalid_params(format!(
                                "harness {agent} takes no model over ACP (no session/set_model); choose it in the harness's own settings, or give its profile a `${{model}}` argv or env entry in config.json"
                            )));
                        } else {
                            let hint = if catalog.is_empty() { String::new() } else { format!("; models: {}", catalog.join(", ")) };
                            return Err(RpcError::invalid_params(format!("model {m:?} for {agent}: {}{hint}", e.message)));
                        }
                    }
                }
            if let Some(e) = &effort {
                match self.set_config(&session, "effort", json!(e)).await {
                    Ok(_) => {}
                    Err(err) if effort_soft => {
                        tracing::warn!(harness = agent, effort = %e, "start effort skipped: {}", err.message);
                        self.append(&session, "mux", "start_default_skipped", json!({"effort": e, "error": err.message}));
                    }
                    Err(err) => return Err(RpcError::invalid_params(format!("effort {e:?} for {agent}: {}", err.message))),
                }
            }
            // The permission mode a new chat starts in (start_mode.rs): full
            // access unless the person picked or set otherwise. Soft.
            // A proven agent starter's instead, never wider (`start_mode.rs`, "Inherit").
            let start_mode = if mode_eligible {
                // Boxed, as the hold below: inline they outgrow a debug build's 2 MiB stack.
                Box::pin(self.start_mode_for(&session, starter.as_deref())).await
            } else {
                None
            };
            if let Some(mode) = start_mode {
                match self.set_mode(&session, &mode).await {
                    Ok(_) => {
                        let starter = starter.as_deref();
                        self.inherited_full_access_is_cmux_only_if_theirs(&session, starter);
                    }
                    Err(err) => {
                        tracing::warn!(harness = agent, mode = %mode, "start mode skipped: {}", err.message);
                        self.append(&session, "mux", "start_default_skipped", json!({"modeId": mode, "error": err.message}));
                    }
                }
            }
            // Never asking less than the starter as it is now (it may have narrowed or left full
            // access meanwhile, or the child's family has no mode that asks): an inherited policy
            // is narrowed to the starter's, and the harness moved, else refused.
            let starter = starter.as_deref();
            Box::pin(self.hold_to_starter(&session, starter, inherits_policy, mode_eligible))
                .await?;
            // Every chat, eligible or not: a preset's or a pinned profile's policy holds too.
            let default = self.config.read().await.permission_policy;
            self.note_unenforced_policy(&session, default);
            Ok(())
        }
        .await;
        if let Err(e) = applied {
            // Never leave a half-configured session behind.
            let _ = self.kill(&session, true).await;
            return Err(e);
        }
        if adopt.is_none() {
            self.pool_note_used(&session);
        }
        Ok(session)
    }

    /// A chat `starter` started, held to it as it is now (`start_mode.rs`, "Inherit"): an
    /// inherited policy (`inherits_policy`) laxer than the starter's is narrowed to it, and a
    /// harness whose mode the inheritance chose (`mode_eligible`) moved, else refused. The
    /// starter is read again after each round: one that changed meanwhile is held to again, and
    /// one that keeps changing refuses the start.
    async fn hold_to_starter(
        self: &Arc<Self>,
        session: &Arc<Session>,
        starter: Option<&str>,
        inherits_policy: bool,
        mode_eligible: bool,
    ) -> Result<(), RpcError> {
        const ROUNDS: usize = 4;
        let live = || {
            let theirs = starter.and_then(|id| self.resolve(id).ok().filter(|s| s.id == id));
            theirs.map(|s| s.meta())
        };
        let level = |m: &SessionMeta| (m.permission_policy.clone(), crate::web_modes::mode_of(m));
        for _ in 0..ROUNDS {
            let Some(theirs) = live() else { return Ok(()) };
            if inherits_policy && self.policy_laxer(&session.meta(), &theirs).await {
                let narrowed = self.effective_policy(&theirs).await;
                self.set_policy(session, narrowed).await;
            }
            if mode_eligible {
                self.hold_mode(&theirs, session).await?;
            }
            if live().is_none_or(|now| level(&now) == level(&theirs)) {
                return Ok(());
            }
        }
        Err(super::subsession_guard::refusal(
            "start.starter_changing",
            "session/new refused: the session that started this one kept changing its permissions while it started; start it again".into(),
            json!({"starter": starter}),
        ))
    }

    /// Every model id a profile can run: declared in config, then reported
    /// (Claude's static list for the stdio backend).
    pub async fn catalog_ids(&self, profile: &str) -> Vec<String> {
        let cfg = self.config.read().await;
        let Some(p) = cfg.harnesses.get(profile) else { return vec![] };
        let mut ids: Vec<String> = p.models.iter().map(|m| m.id().to_owned()).collect();
        match p.kind {
            crate::config::HarnessKind::ClaudeStdio => {
                ids.extend(crate::claude_stdio::models().iter().map(|(id, _)| id.to_string()))
            }
            crate::config::HarnessKind::Acp => ids.extend(
                self.known_models
                    .lock()
                    .unwrap()
                    .get(profile)
                    .into_iter()
                    .flatten()
                    .map(|(id, _)| id.clone()),
            ),
            crate::config::HarnessKind::Terminal => {}
        }
        ids.extend(super::models_view::curated_ids(&self.catalog, profile, p));
        ids.dedup();
        ids
    }

    pub(super) fn unique_name(&self, agent: &str) -> String {
        unique_name_among(&self.sessions.lock().unwrap(), agent)
    }

    pub(super) async fn ensure_child(
        self: &Arc<Self>,
        session: &Arc<Session>,
        profile: &super::spawn::Spawn,
    ) -> Result<Arc<ChildAgent>, RpcError> {
        // One spawn at a time per session; a caller that waited here finds
        // the child the previous holder started.
        let _spawning = session.spawn_lock.lock().await;
        if self.shutting_down() {
            return Err(super::shutdown::shutting_down_error());
        }
        if let Some(child) = session.child.lock().await.as_ref()
            && child.is_alive().await
        {
            return Ok(child.clone());
        }
        // A running agent host for this session is reached again, never
        // started or initialized a second time.
        if Self::host_record_live(&session.id) {
            match self.readopt(session).await {
                Some(child) if child.is_alive().await => {
                    // Reached again, not started: no start below decides its Ctrl-B.
                    self.note_host_kind(session, &child, Some(profile.kind)).await;
                    session.closing.store(false, Ordering::SeqCst);
                    return Ok(child);
                }
                // The host ended meanwhile: start a fresh agent below.
                _ if !Self::host_record_live(&session.id) => {}
                // Live but unreachable even after a reconnect: end it (nonce
                // proof) and start a fresh agent, so the session never locks.
                _ => {
                    self.end_unadopted_host(session).await;
                    if Self::host_record_live(&session.id) {
                        return Err(RpcError::internal(
                            "this session's agent host is still running, cannot be reached and did not end; close the session to end it",
                        ));
                    }
                    self.append(session, "mux", "host_unreachable_ended", json!({}));
                }
            }
        }

        let current = self.opencode_ask_now(session, profile).await;
        let profile = current.as_ref().unwrap_or(profile);
        self.record_spawn_inputs(session, profile).await;
        *session.launch_env.lock().unwrap_or_else(|e| e.into_inner()) = Some(profile.env.clone());
        let moves = super::processes::backgrounds_work(profile.kind);
        session.backgrounds_work.store(moves, Ordering::SeqCst);
        // A fresh agent: what acpmux set on the last one is replayed, not assumed.
        self.fresh_agent(session, profile);
        session.closing.store(false, Ordering::SeqCst);
        // A pooled session claimed for this id (`pool/`): its host already
        // runs with the harness initialized and its session created.
        if let Some(pooled) = self.pool_take_claimed_for(&session.id, profile) {
            match self.adopt_pooled(session, pooled).await {
                // A harness whose own settings started it in full access: capped like a cold
                // start, under the same budget. Its `session/set_mode` would otherwise wait
                // forever on a harness that stays alive but never answers, holding `spawn_lock`.
                Ok(child) => {
                    let budget = self.config.read().await.agent_start_timeout();
                    return match tokio::time::timeout(
                        budget,
                        self.cap_full_access(session, &child, profile),
                    )
                    .await
                    {
                        Ok(result) => {
                            result.map(|()| self.keep_account_home(session, profile, child))
                        }
                        Err(_) => {
                            self.abandon_cold_start(session, budget).await;
                            Err(RpcError::deadline_exceeded("agent_start", budget))
                        }
                    };
                }
                // Not promotable: it was ended; start cold below.
                Err(e) => tracing::warn!(session = %session.id, "pooled session not taken: {e:#}"),
            }
        }

        // A cold start is bounded (cx-m5up): an agent that stays alive but
        // never answers `initialize`, `session/load` or `session/new` would
        // otherwise hold `spawn_lock`, and every later request of this
        // session, forever. Re-adoption and pool adoption above keep their
        // own bounds: they serve agents that may be mid-turn.
        let budget = self.config.read().await.agent_start_timeout();
        match tokio::time::timeout(budget, self.cold_start(session, profile)).await {
            Ok(result) => result.map(|child| self.keep_account_home(session, profile, child)),
            Err(_) => {
                self.abandon_cold_start(session, budget).await;
                Err(RpcError::deadline_exceeded("agent_start", budget))
            }
        }
    }

    /// End what a cold start that missed its budget left: the agent it
    /// spawned (in `session.child` or only as a live host record) and its
    /// half-way flags. The session stays open and idle; a later request
    /// starts the agent again.
    async fn abandon_cold_start(
        self: &Arc<Self>,
        session: &Arc<Session>,
        budget: std::time::Duration,
    ) {
        let started = session.child.lock().await.take();
        if let Some(child) = &started {
            child.terminate(super::shutdown::SHUTDOWN_GRACE).await;
        }
        if Self::host_record_live(&session.id) {
            self.end_unadopted_host(session).await;
        }
        session.loading.store(false, Ordering::SeqCst);
        if session.status() != SessionStatus::Closed {
            self.set_status(session, SessionStatus::Idle);
        }
        self.append(
            session,
            "mux",
            "agent_start_timed_out",
            json!({"timeoutMs": u64::try_from(budget.as_millis()).unwrap_or(u64::MAX)}),
        );
    }

    /// The cold-start half of `ensure_child`, under `spawn_lock`: spawn the
    /// agent, initialize it, load or create its session, replay its config.
    async fn cold_start(
        self: &Arc<Self>,
        session: &Arc<Session>,
        profile: &HarnessProfile,
    ) -> Result<Arc<ChildAgent>, RpcError> {
        // Its worktree back if cleanup reclaimed it, and reopened if stopped.
        self.ready_to_start(session).await?;
        let meta = session.meta();
        let tap = self.session_tap(session);
        let is_claude = profile.kind == crate::config::HarnessKind::ClaudeStdio;
        let mut existing_sid = session.meta().agent_session_id.clone();
        // Cleared only once the fork has started; a failed start retries it.
        let fork_from = session.fork_from.lock().unwrap().clone();
        // Resume a Claude conversation only from a store that has it: one
        // that never finished a turn may not be stored at all, and one that
        // another profile ran lives in that profile's store (a failover onto
        // a fallback with its own CLAUDE_CONFIG_DIR). Else a fresh one starts
        // with the restored transcript, never a turn failed on `--resume`.
        if is_claude
            && fork_from.is_none()
            && let Some(why) =
                existing_sid.as_deref().and_then(|sid| claude_resume_refusal(&meta, profile, sid))
            && let Some(sid) = existing_sid.take()
        {
            tracing::info!(session = %session.id, agent_session = %sid, "starting a fresh Claude conversation: {why}");
            self.append(
                session,
                "mux",
                "resume_failed",
                json!({"error": format!("Claude conversation {sid} {why}, so a fresh one starts")}),
            );
            {
                let mut m = session.meta.lock().unwrap();
                m.agent_session_id = None;
                m.claude_unstored = false;
            }
            session.rehydrate.store(true, Ordering::SeqCst);
        }
        // The --permission-mode acpmux started a Claude process in.
        let mut started_mode = None;
        let child = if is_claude {
            // Claude carries its own session in the process: resume by id, or
            // fork from a parent id into a fresh session.
            let (resume, fork) = match (&fork_from, &existing_sid) {
                (Some(parent), _) => (Some(parent.as_str()), true),
                (None, Some(sid)) => (Some(sid.as_str()), false),
                (None, None) => (None, false),
            };
            let fresh_id =
                if resume.is_none() { Some(uuid::Uuid::now_v7().to_string()) } else { None };
            let effort = current_effort(&meta).unwrap_or_else(|| "default".into());
            let fast = current_option(&meta, "fast-mode").as_deref() == Some("on");
            let mode = meta
                .modes
                .as_ref()
                .and_then(|m| m.get("currentModeId"))
                .and_then(Value::as_str)
                .unwrap_or("default")
                .to_owned();
            // A remote chain never runs in full access (remote_sandbox.rs),
            // even when a transfer moved a full-access chat here.
            let mode = if meta.remote_origin && mode == "bypassPermissions" {
                "default".to_owned()
            } else {
                mode
            };
            // Nor does any chat saved in full access while sessions.allowFullAccess is off.
            // A profile pinning --permission-mode keeps it (spawn_plan adds none), so its record does too.
            let saved_mode = mode.clone();
            let mode = if super::start_mode::profile_sets_mode(profile) {
                mode
            } else {
                super::start_mode::resumable_mode(mode, "default")
            };
            if mode != saved_mode {
                tracing::info!(session = %session.id, "resume: full access is off; {saved_mode} runs as {mode}");
                self.write_mode_state(session, [ModeWrite::CurrentMode(json!(mode))]);
            }
            // Nor does a chat whose policy is narrower than approve-all start in a mode that never
            // asks (`policy_mode.rs`); a pinned argv mode is moved after the start.
            let default = self.config.read().await.permission_policy;
            let mode = match super::policy_mode::claude_spawn_mode(&meta, default, &mode) {
                Some(asking) => {
                    self.write_mode_state(session, [ModeWrite::CurrentMode(json!(asking))]);
                    asking
                }
                None => mode,
            };
            if !super::start_mode::profile_sets_mode(profile) {
                started_mode = Some(mode.clone());
            }
            let model = current_model(&meta).unwrap_or_else(|| "default".into());
            let plan = crate::claude_stdio::spawn_plan(
                profile,
                resume,
                fork,
                fresh_id.as_deref(),
                Some(&effort),
                &mode,
                Some(&model),
            );
            let (plan, profile) = self.remote_chain_plan(session, profile, plan).await?;
            // A fresh process was given its id; a resumed one already has it.
            let known = if fork { None } else { fresh_id.clone().or_else(|| existing_sid.clone()) };
            if self.agent_hosts_enabled() {
                let translator = crate::agent_host::TranslatorSpec {
                    acp_session_id: session.id.clone(),
                    mode: mode.clone(),
                    model: model.clone(),
                    effort: effort.clone(),
                    fast,
                    claude_session_id: known.clone(),
                };
                self.spawn_hosted_child(
                    session,
                    &profile,
                    &meta,
                    Some((plan.program.clone(), plan.args.clone())),
                    Some(translator),
                    tap,
                )
                .await?
            } else {
                let tr = crate::claude_stdio::Translator::new(
                    session.id.clone(),
                    &mode,
                    &model,
                    &effort,
                );
                *tr.fast.lock().await = fast;
                if let Some(sid) = known {
                    *tr.session_id.lock().await = Some(sid);
                }
                let program = plan.program.clone();
                ChildAgent::spawn_with(
                    &meta.harness,
                    &profile,
                    &meta.cwd,
                    session.inbound_tx.clone(),
                    tap,
                    Some((plan.program, plan.args)),
                    Some(tr),
                    Some((&session.id, &meta.name)),
                )
                .await
                .map_err(|e| {
                    crate::launch_policy::spawn_error(e, |e| {
                        crate::recovery::spawn_failed(&e, &meta.harness, &program, &meta.cwd)
                    })
                })?
            }
        } else if self.agent_hosts_enabled() {
            self.spawn_hosted_child(session, profile, &meta, None, None, tap).await?
        } else {
            ChildAgent::spawn_with(
                &meta.harness,
                profile,
                &meta.cwd,
                session.inbound_tx.clone(),
                tap,
                None,
                None,
                Some((&session.id, &meta.name)),
            )
            .await
            .map_err(|e| {
                crate::launch_policy::spawn_error(e, |e| {
                    let program = profile.argv.first().map(String::as_str).unwrap_or_default();
                    crate::recovery::spawn_failed(&e, &meta.harness, program, &meta.cwd)
                })
            })?
        };
        // A direct start records the format its command was pinned to (a host's: hosts.rs).
        if let Some(format) = child.preview_format {
            self.record_preview_format(session, format);
        }
        {
            // The shutdown marks itself started, then takes each session's
            // child: checked under that lock, either the shutdown finds this
            // child or this spawn sees the shutdown and ends what it started.
            let mut slot = session.child.lock().await;
            if self.shutting_down() {
                drop(slot);
                child.terminate(super::shutdown::SHUTDOWN_GRACE).await;
                if child.host_record().is_some() {
                    self.end_unadopted_host(session).await;
                }
                return Err(super::shutdown::shutting_down_error());
            }
            *slot = Some(child.clone());
        }
        self.wake_idle_reaper();

        // Start the inbound loop for this session once.
        if let Some(rx) = session.inbound_rx.lock().await.take() {
            let hub = self.clone();
            let s = session.clone();
            tokio::spawn(async move { hub.inbound_loop(s, rx).await });
        }

        let init = match child.request(method::INITIALIZE, super::pool::initialize_params()).await {
            Ok(v) => v,
            Err(e) => return Err(Self::explain_start_failure(session, e).await),
        };
        let supports_load = init
            .get("agentCapabilities")
            .and_then(|c| c.get("loadSession"))
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let steering = init
            .get("_meta")
            .and_then(|m| m.get("steering"))
            .and_then(|s| s.get("supported"))
            .and_then(Value::as_bool)
            .unwrap_or(false);
        session.steering.store(steering, Ordering::SeqCst);
        {
            let mut m = session.meta.lock().unwrap();
            m.agent_info = init.get("agentInfo").cloned();
            m.agent_capabilities = init.get("agentCapabilities").cloned();
            m.steering = steering;
        }

        if is_claude {
            // A forked process only learns its new id from system/init on the
            // first turn. Prime it then; fresh and resumed ids are known already.
            let known = child.claude_state().await.and_then(|state| state.session_id);
            if known.is_none() {
                session.loading.store(true, Ordering::SeqCst);
                let primed = child
                    .request(method::SESSION_PROMPT, json!({"sessionId": session.id, "prompt": [{"type": "text", "text": "This session was just forked. Reply with exactly: ready"}]}))
                    .await;
                session.loading.store(false, Ordering::SeqCst);
                if let Err(e) = primed {
                    let e = Self::explain_start_failure(session, e).await;
                    return Err(RpcError::internal(format!("claude did not start: {}", e.message)));
                }
            }
            let state = child.claude_state().await.unwrap_or_default();
            let (sid, modes, opts) = (state.session_id, state.modes, state.config_options);
            {
                let mut m = session.meta.lock().unwrap();
                let level = if fork_from.is_some() {
                    "fork"
                } else if existing_sid.is_some() {
                    "exact"
                } else {
                    "new"
                };
                m.agent_session_id = sid.clone();
                m.claude_unstored = level == "new";
                if level != "exact" {
                    m.claude_profile = Some(m.harness.clone());
                }
                drop(m);
                self.write_mode_state(
                    session,
                    [ModeWrite::Modes(modes), ModeWrite::ConfigOptions(opts)],
                );
                if let Some(mode) = started_mode.as_deref() {
                    self.restore_mode_mark(session, mode);
                }
                if fork_from.is_some() {
                    session.fork_from.lock().unwrap().take();
                }
                if level != "new" {
                    self.append(session, "mux", "resumed", json!({"level": level}));
                }
            }
            // A profile that pins its mode in argv (`--permission-mode`, a skip flag) started in it.
            self.hold_policy_mode(session, &child, super::start_mode::profile_sets_mode(profile))
                .await;
            self.set_status(session, SessionStatus::Ready);
            self.save_meta(session);
            let meta_now = session.meta();
            self.remember_models(&meta_now.harness, &meta_now);
            return Ok(child);
        }
        let existing = session.meta().agent_session_id;
        // What the user had chosen before; replayed after load or new.
        let saved = session.meta();
        let loaded = match existing {
            Some(sid) if supports_load => {
                session.loading.store(true, Ordering::SeqCst);
                let res = child
                    .request(
                        method::SESSION_LOAD,
                        self.acp_params(&session.id, &meta, profile, Some(&sid), &child),
                    )
                    .await;
                session.loading.store(false, Ordering::SeqCst);
                match res {
                    Ok(v) => {
                        self.absorb_session_response(session, &v);
                        self.append(session, "mux", "resumed", json!({"level": "exact"}));
                        true
                    }
                    Err(e) => {
                        tracing::warn!(session = %session.id, "session/load failed: {e}");
                        self.note_load_failed(session, &e);
                        if meta.harness == "cmux-harness" {
                            return Err(Self::explain_start_failure(session, e).await);
                        }
                        false
                    }
                }
            }
            Some(_) => false,
            None => false,
        };
        if !loaded {
            let had_history = session.meta().agent_session_id.is_some();
            let res = match child
                .request(
                    method::SESSION_NEW,
                    self.acp_params(&session.id, &meta, profile, None, &child),
                )
                .await
            {
                Ok(v) => v,
                Err(e) => return Err(Self::explain_start_failure(session, e).await),
            };
            let sid = res
                .get("sessionId")
                .and_then(Value::as_str)
                .ok_or_else(|| RpcError::internal("session/new returned no sessionId"))?
                .to_owned();
            {
                let mut m = session.meta.lock().unwrap();
                m.agent_session_id = Some(sid);
            }
            self.absorb_session_response(session, &res);
            if had_history {
                session.rehydrate.store(true, Ordering::SeqCst);
                self.append(session, "mux", "resumed", json!({"level": "rehydrate"}));
            }
        }
        if saved.agent_session_id.is_some() {
            self.replay_config(session, &child, &saved).await;
        }
        self.cap_full_access(session, &child, profile).await?;
        self.set_status(session, SessionStatus::Ready);
        self.save_meta(session);
        let meta_now = session.meta();
        self.remember_models(&meta_now.harness, &meta_now);
        Ok(child)
    }

    /// Marks `mode` as set by cmux again when it is the mode cmux had put the
    /// last agent in and this agent now reports it (`fresh_agent`).
    fn restore_mode_mark(&self, session: &Session, mode: &str) {
        let last = session.applied.lock().unwrap_or_else(|e| e.into_inner()).replay_mark.clone();
        let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
        if last.as_deref() == Some(mode) && crate::web_modes::mode_of(&m).as_deref() == Some(mode) {
            m.mode_set_by_cmux = last;
        }
    }

    /// Re-assert the saved mode, then model, then every config option on a
    /// respawned ACP session, in that order. The model is sent even when
    /// unchanged: its acknowledgement reconciles sibling options such as
    /// Codex's reasoning effort. Failures are logged, never fatal.
    async fn replay_config(
        &self,
        session: &Arc<Session>,
        child: &Arc<ChildAgent>,
        saved: &SessionMeta,
    ) {
        let Some(sid) = session.meta().agent_session_id else { return };
        // A resumed chat saved in a full-access mode does not get it back while the setting is off.
        if let Some(mode) = saved
            .modes
            .as_ref()
            .and_then(|m| m.get("currentModeId"))
            .and_then(Value::as_str)
            .filter(|mode| {
                !super::start_mode::is_full_access(mode) || super::start_mode::full_access_allowed()
            })
        {
            if let Err(e) = child
                .request(method::SESSION_SET_MODE, json!({"sessionId": sid, "modeId": mode}))
                .await
            {
                tracing::warn!(session = %session.id, "replay mode {mode}: {}", e.message);
            } else {
                self.write_mode_state(session, [ModeWrite::CurrentMode(json!(mode))]);
                self.restore_mode_mark(session, mode);
            }
        }
        let opts: Vec<(String, Value)> = saved
            .config_options
            .as_ref()
            .and_then(Value::as_array)
            .map(|a| {
                a.iter()
                    .filter_map(|o| {
                        Some((o.get("id")?.as_str()?.to_owned(), o.get("currentValue")?.clone()))
                    })
                    .collect()
            })
            .unwrap_or_default();
        // Model first.
        let ordered: Vec<(String, Value)> = opts
            .iter()
            .filter(|(k, _)| k == "model")
            .chain(opts.iter().filter(|(k, _)| k != "model"))
            .cloned()
            .collect();
        for (id, value) in ordered {
            if value.is_null() {
                continue;
            }
            if value.as_str().is_some_and(super::start_mode::is_full_access)
                && !super::start_mode::full_access_allowed()
            {
                tracing::info!(session = %session.id, "replay {id}: full access is off; kept the harness's own mode");
                continue;
            }
            match child
                .request(
                    method::SESSION_SET_CONFIG_OPTION,
                    json!({"sessionId": sid, "configId": id, "value": value}),
                )
                .await
            {
                Ok(res) => {
                    if let Some(o) = res.get("configOptions") {
                        self.write_mode_state(session, [ModeWrite::ConfigOptions(o.clone())]);
                    }
                    // A mode that is its `mode` option is cmux's again once this agent runs it.
                    if id == "mode"
                        && let Some(mode) = value.as_str()
                    {
                        self.restore_mode_mark(session, mode);
                    }
                }
                Err(e) => tracing::warn!(session = %session.id, "replay {id}: {}", e.message),
            }
        }
        // No model option was replayed (the agent may list other options,
        // such as effort, without one): restore the legacy model id.
        if !opts.iter().any(|(k, v)| k == "model" && !v.is_null())
            && let Some(model) =
                saved.models.as_ref().and_then(|m| m.get("currentModelId")).and_then(Value::as_str)
            && let Err(e) = child
                .request(method::SESSION_SET_MODEL, json!({"sessionId": sid, "modelId": model}))
                .await
        {
            tracing::warn!(session = %session.id, "replay model {model}: {}", e.message);
        }
        self.append(session, "mux", "config", json!({"replayed": true}));
    }

    /// Remember the models an agent lists so the picker can show them for
    /// harnesses without a live session.
    pub(super) fn remember_models(&self, agent: &str, meta: &SessionMeta) {
        self.remember_models_from(agent, meta.config_options.as_ref(), meta.models.as_ref());
    }

    fn remember_models_from(
        &self,
        agent: &str,
        config_options: Option<&Value>,
        models: Option<&Value>,
    ) {
        let mut list: Vec<(String, String)> = Vec::new();
        if let Some(opts) = config_options.and_then(Value::as_array)
            && let Some(o) =
                opts.iter().find(|o| o.get("id").and_then(Value::as_str) == Some("model"))
        {
            list.extend(crate::model_catalog::choices(o));
        }
        if list.is_empty()
            && let Some(models) =
                models.and_then(|m| m.get("availableModels")).and_then(Value::as_array)
        {
            for m in models {
                let v = m.get("modelId").and_then(Value::as_str).unwrap_or("").to_owned();
                let n = m.get("name").and_then(Value::as_str).unwrap_or(&v).to_owned();
                list.push((v, n));
            }
        }
        if !list.is_empty() {
            self.known_models.lock().unwrap().insert(agent.to_owned(), list);
        }
    }

    /// Ask every ACP harness for its model list once, without creating an
    /// acpmux session: spawn, `initialize`, `session/new`, read the models,
    /// kill. Codex, OpenCode and Gemini only reveal models this way. Runs in
    /// the background at daemon start so the picker is full before the first
    /// session exists.
    pub async fn probe_models(self: &Arc<Self>) {
        self.probe_models_with(false, false, None).await;
    }

    /// `daemon models --refresh`: forget every reported catalog, probe every
    /// ACP harness again, and wait for the answers (bounded).
    pub async fn refresh_models(self: &Arc<Self>) {
        self.known_models.lock().unwrap().clear();
        self.probe_models_with(true, true, None).await;
    }

    /// `only`: probe these harnesses alone (`allow_probes`); None: every
    /// harness the probe list allows.
    pub(super) async fn probe_models_with(
        self: &Arc<Self>,
        force: bool,
        wait: bool,
        only: Option<std::collections::BTreeSet<String>>,
    ) {
        // A probe starts the agent: none while launches are off (cx-9ettq).
        if crate::launch_policy::agent_launch_disabled() {
            tracing::info!("agent launch is disabled; model probes skipped");
            return;
        }
        let picked = |n: &str| only.as_ref().is_none_or(|o| o.contains(n));
        let agents: Vec<(String, HarnessProfile)> = {
            let cfg = self.config.read().await;
            let known = self.known_models.lock().unwrap();
            cfg.harnesses
                .iter()
                .filter(|(n, p)| {
                    p.kind == crate::config::HarnessKind::Acp
                        && (force || !known.contains_key(*n))
                        && self.probes(n)
                        && picked(n)
                })
                .map(|(n, p)| (n.clone(), p.clone()))
                .collect()
        };
        // Claude Code's and Codex's own lists, beside the ACP probes.
        let live = {
            let hub = self.clone();
            let only = only.clone();
            tokio::spawn(async move { hub.probe_live_models(wait, only).await })
        };
        let mut handles = vec![live];
        for (name, profile) in agents {
            let hub = self.clone();
            handles.push(tokio::spawn(async move {
                // Probes spawn agents: wait for the login environment.
                hub.wait_startup().await;
                // Resolved here, once, so neither this probe nor a later
                // session spawn launches through npx.
                hub.resolve_launcher(&profile.argv).await;
                match tokio::time::timeout(
                    std::time::Duration::from_secs(60),
                    hub.probe_one(&name, &profile),
                )
                .await
                {
                    Ok(Ok(n)) => {
                        tracing::info!(agent = %name, models = n, "model probe done");
                        hub.probe_errors.lock().unwrap().remove(&name);
                    }
                    Ok(Err(e)) => {
                        tracing::warn!(agent = %name, error = %e, "model probe failed");
                        hub.probe_errors.lock().unwrap().insert(name, format!("{e:#}"));
                    }
                    Err(_) => {
                        tracing::warn!(agent = %name, "model probe timed out");
                        hub.probe_errors
                            .lock()
                            .unwrap()
                            .insert(name, "the model probe timed out after 60 s".into());
                    }
                }
            }));
        }
        if wait {
            for h in handles {
                let _ = h.await;
            }
        }
    }

    async fn probe_one(
        self: &Arc<Self>,
        name: &str,
        profile: &HarnessProfile,
    ) -> anyhow::Result<usize> {
        let (tx, mut rx) = tokio::sync::mpsc::channel(64);
        let tap: crate::agent::Tap = Arc::new(|_, _, _| true);
        // Never the home folder: the agent scans its folder at start (LAUNCH-NO-TCC-PROMPTS).
        let cwd = tokio::task::spawn_blocking(crate::protected_folders::unattended_cwd)
            .await
            .unwrap_or_else(|_| std::env::temp_dir());
        let mut resolved = profile.clone();
        resolved.argv = self.resolved_launcher_argv(resolved.argv);
        let child = crate::agent::ChildAgent::spawn(name, &resolved, &cwd, tx, tap).await?;
        // Drain anything the agent sends so its writer never blocks.
        let drain = tokio::spawn(async move { while rx.recv().await.is_some() {} });
        let result = tokio::time::timeout(std::time::Duration::from_secs(50), async {
            child
                .request(method::INITIALIZE, json!({"protocolVersion": 1, "clientCapabilities": {}, "clientInfo": {"name": "acpmux", "version": env!("CARGO_PKG_VERSION")}}))
                .await
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let res = child
                .request(method::SESSION_NEW, json!({"cwd": cwd, "mcpServers": []}))
                .await
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let cfg = self.config.read().await;
            if cfg.harnesses.get(name) == Some(profile) {
                self.remember_models_from(name, res.get("configOptions").filter(|v| !v.is_null()), res.get("models").filter(|v| !v.is_null()));
            }
            Ok(self.known_models.lock().unwrap().get(name).map(|l| l.len()).unwrap_or(0))
        }).await;
        child.kill().await;
        drain.abort();
        // The probe's session leaves no transcript behind (it listed as an empty chat).
        let folder = cwd.clone();
        let _ = tokio::task::spawn_blocking(move || {
            crate::probe_cleanup::remove_probe_transcripts(&folder)
        })
        .await;
        result.map_err(|_| anyhow::anyhow!("model probe timed out"))?
    }

    pub(super) fn absorb_session_response(&self, session: &Session, v: &Value) {
        let present = |k: &str| v.get(k).filter(|x| !x.is_null()).cloned();
        let mut writes = Vec::new();
        writes.extend(present("modes").map(ModeWrite::Modes));
        writes.extend(present("configOptions").map(ModeWrite::ConfigOptions));
        self.write_mode_state(session, writes);
        if let Some(models) = present("models") {
            session.meta.lock().unwrap().models = Some(models);
        }
    }

    pub(super) async fn child_for(
        self: &Arc<Self>,
        session: &Arc<Session>,
    ) -> Result<Arc<ChildAgent>, RpcError> {
        // A watched chat starts no agent until Take Over: every lazy start (warm, model, mode, fork).
        if session.meta().watching.is_some() {
            return Err(super::watch::read_only());
        }
        // `ensure_child` publishes the child before `initialize` and
        // `session/load` answer (the inbound loop needs it to answer the
        // agent's own requests meanwhile). A live child is ready only while
        // no start holds the spawn lock; otherwise wait for that start below.
        if let Ok(_idle) = session.spawn_lock.try_lock()
            && let Some(child) = session.child.lock().await.as_ref()
            && child.is_alive().await
        {
            return Ok(child.clone());
        }
        self.wait_startup().await;
        let meta = session.meta();
        let agent = meta.harness.clone();
        let (profile, defaults) = {
            let cfg = self.config.read().await;
            let profile =
                super::resolve::session_profile(&cfg, &agent, &meta.cwd, meta.remote_origin)
                    .map_err(RpcError::invalid_params)?;
            (profile, cfg.defaults_for(&agent))
        };
        let spawn = self.spawn_profile(session, &profile, &defaults.env).await?;
        self.ensure_child(session, &spawn).await
    }
}

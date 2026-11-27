//! Part of `Hub`: an agent's cold start and the config replay after it; see `hub/mod.rs`.

use super::lifecycle::START_PROGRESS;
use super::new_request::claude_resume_refusal;
use super::policy_mode::refusal_record;
use super::start_watch::StartWatch;
use super::*;

impl Hub {
    /// Its starting harness while the start itself is not being polled: the start may hold the
    /// locks this reads, so a held one answers None (nothing known this tick) rather than waiting.
    async fn harness_now(session: &Session) -> Option<crate::cpu_class::HarnessSeen> {
        let child = session.child.try_lock().ok()?.clone();
        let Some(child) = child else {
            return Some(crate::cpu_class::HarnessSeen::NotStarted);
        };
        tokio::time::timeout(std::time::Duration::from_secs(1), child.harness_seen()).await.ok()
    }

    /// Its starting harness, as a deadline error says it (`cpu_class::HarnessSeen`).
    pub(super) async fn starting_harness(session: &Session) -> crate::cpu_class::HarnessSeen {
        let child = session.child.lock().await.clone();
        match child {
            Some(child) => child.harness_seen().await,
            None => crate::cpu_class::HarnessSeen::NotStarted,
        }
    }

    /// End what a failed cold start left before it is retried: as `abandon_cold_start`, with no
    /// event of its own (the retry logs one).
    pub(super) async fn end_cold_start(self: &Arc<Self>, session: &Arc<Session>) {
        let started = session.child.lock().await.take();
        if let Some(child) = &started {
            child.terminate(super::shutdown::SHUTDOWN_GRACE).await;
        }
        if Self::host_record_live(&session.id) {
            self.end_unadopted_host(session).await;
        }
        session.loading.store(false, Ordering::SeqCst);
        if session.status() != SessionStatus::Closed {
            self.set_status(session, NotWaiting::Idle);
        }
    }

    /// The person's agent start (`Session::person`) has no deadline: a loaded host may take
    /// minutes, and Leo: "I TSHOULDN'T FUCKING MATTER IF MY COMPUTER IS LOADED" / "I SHOULD BE
    /// ALWAYS ABLE TO SATRT NEW FUCKGN CHATS". It ends as the start does: answered, or failed
    /// because its harness exited, its spawn failed or a stop ended it; or when its harness did
    /// no work at all for `START_HUNG` (`StartWatch`, no-hangs 2026-11-24: a harness waiting on
    /// input or a lock held the person's new chat "starting" forever, and Linux read no harness
    /// state, so nothing ended it there). A loaded host still does work, so it still waits. Every `START_PROGRESS`
    /// (sooner when `agentStartTimeoutMs` is shorter) its log says it is still starting
    /// (`agent_start_waiting`, `waitedMs`), so the app can show that the host is busy. An agent's
    /// or a lane's start keeps `agentStartTimeoutMs` (cx-m5up).
    ///
    /// A start that asked to wait on its harness (`Session::wait_start`) waits the same way. Under
    /// `watch` it answers None when its harness stopped working (`StartWatch`), which the caller
    /// ends as `harness_hung`.
    pub(super) async fn waiting_start<T>(
        &self,
        session: &Arc<Session>,
        budget: std::time::Duration,
        start: impl std::future::Future<Output = T>,
        mut watch: Option<StartWatch>,
    ) -> Option<T> {
        let every = START_PROGRESS.min(budget).max(std::time::Duration::from_millis(100));
        let began = tokio::time::Instant::now();
        let mut tick = tokio::time::interval_at(began + every, every);
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        tokio::pin!(start);
        let mut said = false;
        loop {
            tokio::select! {
                done = &mut start => return Some(done),
                _ = tick.tick() => {
                    let waited = began.elapsed();
                    if !said && waited >= budget {
                        said = true;
                        tracing::warn!(
                            session = %session.id,
                            "the agent start is past {budget:?}; it keeps waiting"
                        );
                    }
                    if let Some(watch) = &mut watch
                        && let Some(seen) = Self::harness_now(session).await
                        && watch.hung(&seen, waited)
                    {
                        tracing::warn!(session = %session.id, "the agent start's harness stopped working ({seen:?})");
                        return None;
                    }
                    let waited_ms = u64::try_from(waited.as_millis()).unwrap_or(u64::MAX);
                    let waiting = json!({"waitedMs": waited_ms});
                    self.append(session, "mux", "agent_start_waiting", waiting);
                }
            }
        }
    }

    /// End what a cold start that missed its budget left: the agent it
    /// spawned (in `session.child` or only as a live host record) and its
    /// half-way flags. The session stays open and idle; a later request
    /// starts the agent again.
    pub(super) async fn abandon_cold_start(
        self: &Arc<Self>,
        session: &Arc<Session>,
        budget: std::time::Duration,
    ) {
        self.end_cold_start(session).await;
        self.append(
            session,
            "mux",
            "agent_start_timed_out",
            json!({"timeoutMs": u64::try_from(budget.as_millis()).unwrap_or(u64::MAX)}),
        );
    }

    /// The cold-start half of `ensure_child`, under `spawn_lock`: spawn the
    /// agent, initialize it, load or create its session, replay its config.
    pub(super) async fn cold_start(
        self: &Arc<Self>,
        session: &Arc<Session>,
        profile: &HarnessProfile,
        stops: u64,
        off: &super::full_access_bound::OffLatch,
    ) -> Result<Arc<ChildAgent>, RpcError> {
        // Its worktree back if cleanup reclaimed it, and reopened if stopped.
        self.ready_to_start(session, stops).await?;
        let meta = session.meta();
        // Its requests say interactive (the person's chat, a coordinator) or background
        // (subrouter_priority.rs), so the gateways keep a share for the chats Leo talks to.
        let for_person = super::host_level::made_for_a_person(
            meta.created_by.as_ref(),
            session.person.load(std::sync::atomic::Ordering::SeqCst),
        );
        let profile = &crate::subrouter_priority::profile_with(
            profile,
            self.subrouter_priority(session, &meta, for_person),
        );
        let tap = self.session_tap(session);
        let is_claude = profile.kind == crate::config::HarnessKind::ClaudeStdio;
        let mut existing_sid = session.meta().agent_session_id.clone();
        // Cleared only once the fork has started; a failed start retries it.
        let fork_from = session.fork_from.lock().unwrap().clone();
        // Resume a Claude conversation only from a store that has it: one
        // that never finished a turn may not be stored at all, one that
        // another profile ran lives in that profile's store (a failover onto
        // a fallback with its own CLAUDE_CONFIG_DIR), and a transcript can be
        // gone from its own profile's store (the compactor deletes one it
        // folded; a store can be pruned or deleted). Else a fresh one starts
        // with the restored transcript, never a turn failed on `--resume`.
        if is_claude
            && fork_from.is_none()
            && let Some(why) =
                existing_sid.as_deref().and_then(|sid| claude_resume_refusal(&meta, profile, sid))
            && let Some(sid) = existing_sid.take()
        {
            tracing::info!(session = %session.id, agent_session = %sid, "starting a fresh Claude conversation: {why}");
            // A chat woken from hibernation had no turn when it hibernated (`idle.rs` keeps one
            // with turns but none stored awake), so it has nothing to restore: it starts fresh
            // with no row and no restored transcript. (The prompt waking it is counted already.)
            let untouched = self.waking(session);
            if !untouched {
                self.append(
                    session,
                    "mux",
                    "resume_failed",
                    json!({"error": format!("Claude conversation {sid} {why}, so a fresh one starts")}),
                );
            }
            {
                let mut m = session.meta.lock().unwrap();
                m.set_agent_session_id(None, "claude");
                m.claude_unstored = false;
                m.claude_unstored_work = false;
            }
            if !untouched {
                session.rehydrate.store(true, Ordering::SeqCst);
            }
        }
        // The --permission-mode acpmux started a Claude process in.
        let mut started_mode = None;
        // What a Claude process was started in: its profile's argv and the mode it was given.
        let mut spawned = super::full_access_bound::FullAccessView::default();
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
            let effort = spawn_effort(&meta).unwrap_or_else(|| "default".into());
            let fast = current_option(&meta, "fast-mode").as_deref() == Some("on");
            let suggestions = crate::claude_stdio::prompt_suggestions::chat_pick(current_option(
                &meta,
                crate::claude_stdio::prompt_suggestions::OPTION,
            ));
            let recap = current_option(&meta, crate::claude_stdio::RECAP_OPTION);
            let mode = meta
                .modes
                .as_ref()
                .and_then(|m| m.get("currentModeId"))
                .and_then(Value::as_str)
                // A Web start begins in Manual until the remote guard settles it.
                .unwrap_or(if meta.remote_origin {
                    "default"
                } else {
                    crate::claude_stdio::OWN_MODE
                })
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
                super::start_mode::resumable_mode(mode, "default", off.allows_full_access())
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
            spawned = super::full_access_bound::FullAccessView {
                argv: profile.argv.clone(),
                mode: Some(mode.clone()),
                ..Default::default()
            };
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
            // The translator starts in the mode the process runs in, also over a profile that
            // pins its own: Claude Code reports it only with the first turn's `system/init`.
            let run_mode = crate::claude_stdio::spawn_mode(profile, &mode).to_owned();
            // The chat's Sources (`additional_dirs.rs`), at every start.
            let mut plan = plan;
            plan.args.extend(super::additional_dirs::claude_args(&meta));
            // Its stop condition, at every start (a resume or respawn too: `stop_condition.rs`).
            plan.args.extend(super::stop_condition::claude_args(&meta));
            // A restricted chat's folder settings and MCP servers stay off (`restricted.rs`).
            plan.args.extend(super::restricted::claude_args(&meta));
            let (plan, mut profile) = self.remote_chain_plan(session, profile, plan).await?;
            // The continuation of a turn a move cut at a tool boundary starts this process: it
            // goes on from its own transcript, once the Stop's line is out of it
            // (`claude_stdio/resume_cut.rs`). A transcript that does not end at a tool result
            // keeps the continuation's text.
            let resumes_cut_turn = session.resume_cut_ask.load(Ordering::SeqCst)
                && resume.is_some()
                && !fork
                && crate::native::locate(&meta).into_iter().any(|(label, path)| {
                    label == "claude-project"
                        && crate::claude_stdio::resume_cut::prepare(&path).unwrap_or(false)
                });
            session.resumed_cut.store(resumes_cut_turn, Ordering::SeqCst);
            if resumes_cut_turn {
                let env = &mut profile.to_mut().env;
                for (key, value) in crate::claude_stdio::resume_cut::env() {
                    env.insert(key.into(), value.into());
                }
            }
            // A fresh process was given its id; a resumed one already has it.
            let known = if fork { None } else { fresh_id.clone().or_else(|| existing_sid.clone()) };
            if self.agent_hosts_enabled() {
                let translator = crate::agent_host::TranslatorSpec {
                    acp_session_id: session.id.clone(),
                    mode: run_mode.clone(),
                    model: model.clone(),
                    effort: effort.clone(),
                    fast,
                    prompt_suggestions: suggestions,
                    recap: recap.clone(),
                    claude_session_id: known.clone(),
                    resumes_cut_turn,
                    stop_condition: meta.stop_condition.is_some(),
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
                    &run_mode,
                    &model,
                    &effort,
                );
                *tr.fast.lock().await = fast;
                tr.prompt_suggestions.store(suggestions, std::sync::atomic::Ordering::SeqCst);
                tr.stop_condition.store(meta.stop_condition.is_some(), Ordering::Relaxed);
                tr.set_recap(recap.as_deref());
                if resumes_cut_turn {
                    tr.owe_resumed();
                }
                if let Some(sid) = known {
                    *tr.session_id.lock().await = Some(sid);
                }
                let program = plan.program.clone();
                ChildAgent::spawn_with(
                    &meta.harness,
                    &profile,
                    &meta.cwd,
                    session.inbound_tx().clone(),
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
                session.inbound_tx().clone(),
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
        // An agent with no host ends with this run, so no earlier run's token is its own
        // (`caller_registry.rs`).
        if !self.agent_hosts_enabled() {
            self.caller_registry.forget(&session.id);
        }
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
        // A new harness runs none of the background subagents of one it replaced.
        self.end_background_subagents(session);
        // Nor has its sandbox refused anything yet (`harness_sandbox.rs`).
        self.harness_sandbox_recovered(session, "respawn");
        self.wake_idle_reaper();

        // Start the inbound loop for this session once.
        self.spawn_inbound_loop(session).await;

        let init = match child.request(method::INITIALIZE, self.start_params(session)).await {
            Ok(v) => v,
            Err(e) => {
                // An agent CLI that refuses to start signed out exits before it answers
                // `initialize` ("agent process closed (grok): Authentication required"): typed
                // the same as a `session/new` auth_required, so the start names it (hq#11225).
                let mut e = Self::explain_start_failure(session, e).await;
                crate::recovery::start_sign_in(&mut e, &meta.harness);
                return Err(e);
            }
        };
        // An agent signed in by its key says so before its session (`acp_key_auth.rs`); one
        // that refuses it names the sign-in as `initialize`'s failure does.
        let family = crate::config::derive_family(&meta.harness, profile);
        if let Some(params) = crate::acp_key_auth::authenticate_params(&family, &init, |k| {
            crate::acp_key_auth::launch_var(&profile.env, &family, k)
        }) && let Err(e) = child.request(method::AUTHENTICATE, params).await
        {
            let mut e = Self::explain_start_failure(session, e).await;
            crate::recovery::start_sign_in(&mut e, &meta.harness);
            return Err(e);
        }
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
        // What it says about asking before its tools, and whether acpmux believes it.
        self.note_asks_claim(session).await;

        if is_claude {
            // MDM may have forced full access off since `ensure_child` checked the profile: the
            // process runs nothing, not even a fork's priming turn, in full access (review 31).
            self.refuse_started_in_full_access(session, off, &spawned).await?;
            // A forked process only learns its new id from system/init on the
            // first turn. Prime it then; fresh and resumed ids are known already.
            let known = child.claude_state().await.and_then(|state| state.session_id);
            if known.is_none() {
                let hold = ReplayHold::start(session, &child);
                session.loading.store(true, Ordering::SeqCst);
                let primed = child
                    .request(method::SESSION_PROMPT, json!({"sessionId": session.id, "prompt": [{"type": "text", "text": "This session was just forked. Reply with exactly: ready"}]}))
                    .await;
                session.loading.store(false, Ordering::SeqCst);
                hold.end().await;
                if let Err(e) = primed {
                    let e = Self::explain_start_failure(session, e).await;
                    return Err(RpcError::internal(format!("claude did not start: {}", e.message)));
                }
            }
            // A hosted agent's host that did not answer (the shutdown detached it, or it ended)
            // told nothing of its session: the start fails, never recording no id over the one
            // it was given and handing out an agent with none ("no agent session").
            let Some(state) = child.claude_state().await else {
                return Err(if self.shutting_down() {
                    super::shutdown::shutting_down_error()
                } else {
                    RpcError::internal("the agent host did not answer as its agent started")
                });
            };
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
                m.set_agent_session_id(sid.clone(), "claude");
                m.claude_unstored = level == "new";
                m.claude_unstored_work = false;
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
                    session.fork_resumed();
                }
                if level != "new" {
                    self.append(
                        session,
                        "mux",
                        "resumed",
                        self.wake_marked(session, json!({"level": level})),
                    );
                }
            }
            // Nor is it handed out in full access by any form it now reports (`cap_full_access`).
            self.refuse_started_in_full_access(
                session,
                off,
                &super::full_access_bound::FullAccessView::of_session(session),
            )
            .await?;
            // A profile that pins its mode in argv (`--permission-mode`, a skip flag) started in it.
            // An agent that cannot keep the chat's policy is stopped and the start fails.
            let pinned = super::start_mode::profile_sets_mode(profile);
            if let Err(e) = self.hold_policy_mode(session, &child, pinned).await {
                let record = refusal_record(&e);
                self.stop_started_agent(session, false, "policy_refused", record).await;
                return Err(e);
            }
            self.set_status(session, NotWaiting::Ready);
            self.note_launch(session, &child);
            self.note_start_level(session, &child, true);
            self.save_meta(session);
            let meta_now = session.meta();
            self.remember_models(&meta_now.harness, &meta_now);
            return Ok(child);
        }
        let existing = session.meta().agent_session_id;
        // This start's answer for the person's own `cmux` entry (`record_spawn_inputs`).
        let codex_answer = session.codex_answer.lock().unwrap_or_else(|e| e.into_inner()).clone();
        // What the user had chosen before; replayed after load or new.
        let saved = session.meta();
        let loaded = match existing {
            Some(sid) if supports_load => {
                let hold = ReplayHold::start(session, &child);
                session.loading.store(true, Ordering::SeqCst);
                let res = child
                    .request(
                        method::SESSION_LOAD,
                        self.acp_params(
                            &session.id,
                            &meta,
                            profile,
                            Some(&sid),
                            &child,
                            &codex_answer,
                            &init,
                        ),
                    )
                    .await;
                session.loading.store(false, Ordering::SeqCst);
                hold.end().await;
                match res {
                    Ok(v) => {
                        self.absorb_session_response(session, &v);
                        self.health.record_acp_auth_success(
                            &meta.harness,
                            "ACP session/load authenticated the harness",
                        );
                        self.append(
                            session,
                            "mux",
                            "resumed",
                            self.wake_marked(session, json!({"level": "exact"})),
                        );
                        true
                    }
                    Err(e) => {
                        tracing::warn!(session = %session.id, "session/load failed: {e}");
                        if let Some(e) = super::adoption::unavailable_resume(&e) {
                            self.note_load_failed(session, &e);
                            self.end_cold_start(session).await;
                            return Err(e);
                        }
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
                    self.acp_params(
                        &session.id,
                        &meta,
                        profile,
                        None,
                        &child,
                        &codex_answer,
                        &init,
                    ),
                )
                .await
            {
                Ok(v) => v,
                Err(e) => {
                    // An agent with no sign-in answers with ACP's auth_required: typed, so the
                    // start names the agent and its sign-in, not a bare refusal (hq#11225).
                    let mut e = Self::explain_start_failure(session, e).await;
                    crate::recovery::start_sign_in(&mut e, &meta.harness);
                    return Err(e);
                }
            };
            let sid = res
                .get("sessionId")
                .and_then(Value::as_str)
                .ok_or_else(|| RpcError::internal("session/new returned no sessionId"))?
                .to_owned();
            {
                let mut m = session.meta.lock().unwrap();
                m.set_agent_session_id(Some(sid), "non-claude");
            }
            self.absorb_session_response(session, &res);
            self.health.record_acp_auth_success(
                &meta.harness,
                "ACP session/new authenticated the harness",
            );
            if had_history {
                session.rehydrate.store(true, Ordering::SeqCst);
                self.append(
                    session,
                    "mux",
                    "resumed",
                    self.wake_marked(session, json!({"level": "rehydrate"})),
                );
            }
        }
        // A guarded relay import may retire the source ACP id when its native agent files are
        // absent. Its carried choices still need replaying after the fresh session/new, just as
        // they do for an ordinary respawn or fork.
        if saved.agent_session_id.is_some() || saved.fork_before.is_some() || saved.remote_origin {
            self.replay_config(session, &child, &saved, off).await;
        }
        self.cap_full_access(session, &child, profile, off).await?;
        self.set_status(session, NotWaiting::Ready);
        self.note_launch(session, &child);
        self.note_start_level(session, &child, true);
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
        off: &super::full_access_bound::OffLatch,
    ) {
        let Some(sid) = session.meta().agent_session_id else { return };
        // A resumed chat saved in a full-access mode does not get it back while the setting is off.
        if let Some(mode) = saved
            .modes
            .as_ref()
            .and_then(|m| m.get("currentModeId"))
            .and_then(Value::as_str)
            .filter(|mode| !super::start_mode::is_full_access(mode) || off.allows_full_access())
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
            .as_deref()
            .and_then(Value::as_array)
            .map(|a| {
                a.iter()
                    .filter_map(|o| {
                        Some((o.get("id")?.as_str()?.to_owned(), o.get("currentValue")?.clone()))
                    })
                    .collect()
            })
            .unwrap_or_default();
        // A legacy ACP model report is the selected model for harnesses such as Codex. It can
        // coexist with a config-option model that only reflects the fresh harness's default, so
        // let the carried report win and skip that stale option.
        let legacy_model = saved
            .models
            .as_ref()
            .and_then(|m| m.get("currentModelId"))
            .and_then(Value::as_str)
            .map(str::to_owned);
        if let Some(model) = legacy_model.as_deref() {
            match child
                .request(method::SESSION_SET_MODEL, json!({"sessionId": sid, "modelId": model}))
                .await
            {
                Ok(res) => {
                    let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
                    if let Some(reported) = res.get("models").filter(|v| !v.is_null()) {
                        meta.models = Some(reported.clone());
                    }
                    if let Some(models) = meta.models.as_mut().and_then(Value::as_object_mut) {
                        models.insert("currentModelId".into(), json!(model));
                    } else {
                        meta.models = Some(json!({"currentModelId": model}));
                    }
                }
                Err(e) => {
                    tracing::warn!(session = %session.id, "replay model {model}: {}", e.message)
                }
            }
        }
        let ordered: Vec<(String, Value)> =
            opts.iter().filter(|(k, _)| legacy_model.is_none() || k != "model").cloned().collect();
        for (id, value) in ordered {
            if value.is_null() {
                continue;
            }
            if value.as_str().is_some_and(super::start_mode::is_full_access)
                && !off.allows_full_access()
            {
                tracing::info!(session = %session.id, "replay {id}: full access is off; kept the harness's own mode");
                continue;
            }
            let params = json!({"sessionId": sid, "configId": id, "value": value});
            let asked = super::full_access_bound::asked_option(&params);
            match child.request(method::SESSION_SET_CONFIG_OPTION, params).await {
                Ok(res) => {
                    // A bare answer took the value asked, as a client's does: under an MDM off
                    // pushed while it was asked, `cap_full_access` then counts it (#26340).
                    super::full_access_bound::record_option_answer(session, &res, asked);
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
        self.append(session, "mux", "config", json!({"replayed": true}));
    }
}

/// The agent messages of a `session/load` (or a Claude fork's prime) never reach the session's
/// preview, so its `lastMessage` stays the chat's own newest reply, as `wait --print` reads it
/// from the log. ACP answers a load once its history is sent, and every reader (direct, Codex
/// bridge, agent host, a pooled agent's hold) queues an agent's notifications in order before
/// it resolves the answer, so the `ReplayDone` that `end` queues lands behind the whole replay,
/// and before the next prompt is even written. The hold names the agent's generation: another
/// agent's updates and markers never touch it. A start abandoned mid-load never ends it, so
/// what that agent still had queued stays out of the preview as well, beside the next agent's
/// own hold (`Session::replaying` keeps both).
struct ReplayHold<'a> {
    session: &'a Session,
    agent: &'a crate::agent::ChildAgent,
}

impl<'a> ReplayHold<'a> {
    fn start(session: &'a Session, agent: &'a crate::agent::ChildAgent) -> Self {
        session.replaying.lock().unwrap_or_else(|e| e.into_inner()).push(agent.generation);
        Self { session, agent }
    }

    /// Lifts the hold once the inbound loop reaches what the agent sent so far; at once when
    /// its queue is closed (nothing more can arrive).
    async fn end(self) {
        if !self.agent.queue_replay_done().await {
            self.session.end_replay(self.agent.generation);
        }
    }
}

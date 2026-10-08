//! Part of `Hub`; see `hub/mod.rs`.

use super::*;

use super::adoption::{Adoption, adopted_in, session_cwd};
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
        } = req;
        // An adopted session's harness names the head unless one was given.
        let harness = harness.or_else(|| adopt.as_ref().and_then(|a| a.harness.clone()));
        // Resolution is a lookup, never a guess: preset → head (family or
        // profile) → defaults chain → explicit values on top.
        let Resolved { agent, profile, defaults, head, preset_name, folder_root } = {
            let cfg = self.config.read().await;
            self.resolve_new(&cfg, harness, &preset, model.as_deref(), remote, cwd.as_deref())?
        };
        let agent = agent.as_str();
        if profile.kind == crate::config::HarnessKind::Terminal {
            return Err(terminal_harness_refusal(agent));
        }
        let family = crate::config::derive_family(agent, &profile);
        let policy = policy.or(defaults.policy);
        let model = model.or(defaults.model);
        let effort = effort.or(defaults.effort);
        // `${model}` in argv or env: the model is a spawn parameter, not a
        // set_model call.
        let spawn_model = profile_takes_model_at_spawn(&profile)
            || defaults.env.values().any(|v| v.contains("${model}"));
        // Adopting checks the id against the harness's own store before
        // anything is created, and takes the conversation's recorded cwd.
        let env = [&defaults.env, &profile.env];
        let (recorded, fork) = match self.adoption(adopt.as_ref(), agent, &family, &env).await? {
            Adoption::Existing(existing) => return Ok(existing),
            Adoption::Found { cwd, fork } => (cwd, fork),
        };
        // A fork resumes nothing as itself: its process forks the adopted id
        // into a new conversation, so the adopted id is not this session's.
        let fork_from = adopt.as_ref().filter(|_| fork).map(|a| a.agent_session_id.clone());
        let cwd = session_cwd(cwd, recorded, &family)?;
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
        meta.session_env = session_env;
        // A pooled session of exactly this shape (`pool/`) gives the session
        // its id; `ensure_child` then takes it instead of starting cold.
        // A pooled harness started without this session's env: never claimed.
        let pooled = match &adopt {
            None if meta.session_env.is_empty() => {
                self.pool_claim(&meta, &profile, &defaults.env).await
            }
            _ => None,
        };
        // Every way out of here (an error, or this future dropped) before
        // `ensure_child` took the entry puts it back or ends it.
        let _claim = pooled.as_ref().map(|id| self.pool_claim_guard(id.clone()));
        let id = pooled.unwrap_or_else(|| uuid::Uuid::now_v7().to_string());
        meta.id = id.clone();
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
        self.append(&session, "mux", "created", json!({"harness": agent, "preset": preset_name}));
        if let Some(a) = &adopt {
            let adopted = if fork_from.is_some() {
                json!({"agentSessionId": a.agent_session_id, "fork": true})
            } else {
                json!({"agentSessionId": a.agent_session_id})
            };
            self.append(&session, "mux", "adopted", adopted);
        }
        let spawned = match self.spawn_profile(&session, &profile, &defaults.env).await {
            Ok(spawn) => self.ensure_child(&session, &spawn).await,
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
                    if let Err(e) = self.set_model(&session, &m).await {
                        if e.message.contains("Method not found") {
                            return Err(RpcError::invalid_params(format!(
                                "harness {agent} takes no model over ACP (no session/set_model); choose it in the harness's own settings, or give its profile a `${{model}}` argv or env entry in config.json"
                            )));
                        }
                        let hint = if catalog.is_empty() { String::new() } else { format!("; models: {}", catalog.join(", ")) };
                        return Err(RpcError::invalid_params(format!("model {m:?} for {agent}: {}{hint}", e.message)));
                    }
                }
            if let Some(e) = &effort {
                self.set_config(&session, "effort", json!(e)).await.map_err(|err| RpcError::invalid_params(format!("effort {e:?} for {agent}: {}", err.message)))?;
            }
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
        profile: &HarnessProfile,
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
                Some(child) if child.is_alive().await => return Ok(child),
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

        self.record_launch_roots(session, profile).await;
        // A pooled session claimed for this id (`pool/`): its host already
        // runs with the harness initialized and its session created.
        if let Some(pooled) = self.pool_take_claimed(&session.id) {
            match self.adopt_pooled(session, pooled).await {
                Ok(child) => return Ok(child),
                // Not promotable: it was ended; start cold below.
                Err(e) => tracing::warn!(session = %session.id, "pooled session not taken: {e:#}"),
            }
        }

        // A stopped session reopens on demand. Only a purge is final.
        if session.status() == SessionStatus::Closed {
            self.append(session, "mux", "reopened", json!({}));
            self.set_status(session, SessionStatus::Idle);
        }
        let meta = session.meta();
        let tap = self.session_tap(session);
        let is_claude = profile.kind == crate::config::HarnessKind::ClaudeStdio;
        let mut existing_sid = session.meta().agent_session_id.clone();
        // Cleared only once the fork has started; a failed start retries it.
        let fork_from = session.fork_from.lock().unwrap().clone();
        // A Claude conversation that never finished a turn may not exist in
        // Claude's store: start a fresh one rather than fail on `--resume`.
        if is_claude
            && fork_from.is_none()
            && session.meta().claude_unstored
            && let Some(sid) = existing_sid.take()
        {
            tracing::info!(session = %session.id, agent_session = %sid, "starting a fresh Claude conversation: the one to resume never finished a turn");
            self.append(
                session,
                "mux",
                "resume_failed",
                json!({"error": format!("Claude conversation {sid} never finished a turn, so a fresh one starts")}),
            );
            session.meta.lock().unwrap().agent_session_id = None;
        }
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
            let effort = current_option(&meta, "effort").unwrap_or_else(|| "default".into());
            let mode = meta
                .modes
                .as_ref()
                .and_then(|m| m.get("currentModeId"))
                .and_then(Value::as_str)
                .unwrap_or("default")
                .to_owned();
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
                if let Some(sid) = known {
                    *tr.session_id.lock().await = Some(sid);
                }
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
                .map_err(|e| RpcError::internal(e.to_string()))?
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
            .map_err(|e| RpcError::internal(e.to_string()))?
        };
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

        let init = child
            .request(
                method::INITIALIZE,
                json!({
                    "protocolVersion": 1,
                    "clientCapabilities": {
                        // File reads and writes come through acpmux, so the
                        // permission policy and rules gate every harness's
                        // edits, not only the ones it chooses to ask about.
                        "fs": {"readTextFile": true, "writeTextFile": true},
                        // Subagents arrive as their own sessions (ACP draft #1992),
                        // attributed by `crate::subagents`.
                        "subagents": {},
                        "terminal": false
                    },
                    "clientInfo": {"name": "acpmux", "version": VERSION}
                }),
            )
            .await?;
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
                drop(m);
                self.write_mode_state(
                    session,
                    [ModeWrite::Modes(modes), ModeWrite::ConfigOptions(opts)],
                );
                if fork_from.is_some() {
                    session.fork_from.lock().unwrap().take();
                }
                if level != "new" {
                    self.append(session, "mux", "resumed", json!({"level": level}));
                }
            }
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
                    .request(method::SESSION_LOAD, self.acp_params(&meta, profile, Some(&sid)))
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
                        self.append(session, "mux", "resume_failed", json!({"error": e.message}));
                        false
                    }
                }
            }
            Some(_) => false,
            None => false,
        };
        if !loaded {
            let had_history = session.meta().agent_session_id.is_some();
            let res =
                child.request(method::SESSION_NEW, self.acp_params(&meta, profile, None)).await?;
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
        self.set_status(session, SessionStatus::Ready);
        self.save_meta(session);
        let meta_now = session.meta();
        self.remember_models(&meta_now.harness, &meta_now);
        Ok(child)
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
        if let Some(mode) =
            saved.modes.as_ref().and_then(|m| m.get("currentModeId")).and_then(Value::as_str)
        {
            if let Err(e) = child
                .request(method::SESSION_SET_MODE, json!({"sessionId": sid, "modeId": mode}))
                .await
            {
                tracing::warn!(session = %session.id, "replay mode {mode}: {}", e.message);
            } else {
                self.write_mode_state(session, [ModeWrite::CurrentMode(json!(mode))]);
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
        self.probe_models_with(false, false).await;
    }

    /// `daemon models --refresh`: forget every reported catalog, probe every
    /// ACP harness again, and wait for the answers (bounded).
    pub async fn refresh_models(self: &Arc<Self>) {
        self.known_models.lock().unwrap().clear();
        self.probe_models_with(true, true).await;
    }

    pub(super) async fn probe_models_with(self: &Arc<Self>, force: bool, wait: bool) {
        let agents: Vec<(String, HarnessProfile)> = {
            let cfg = self.config.read().await;
            let known = self.known_models.lock().unwrap();
            cfg.harnesses
                .iter()
                .filter(|(n, p)| {
                    p.kind == crate::config::HarnessKind::Acp && (force || !known.contains_key(*n))
                })
                .map(|(n, p)| (n.clone(), p.clone()))
                .collect()
        };
        let mut handles = Vec::new();
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
        let cwd = dirs::home_dir().unwrap_or_else(|| std::path::PathBuf::from("/"));
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

/// The agent name, or `agent-N` for the first N not taken in `sessions`.
fn unique_name_among(sessions: &HashMap<String, Arc<Session>>, agent: &str) -> String {
    let taken: Vec<String> = sessions.values().map(|s| s.meta().name).collect();
    for n in 0.. {
        let candidate = if n == 0 { agent.to_owned() } else { format!("{agent}-{n}") };
        if !taken.contains(&candidate) {
            return candidate;
        }
    }
    unreachable!()
}

/// Whether the harness takes its model on the command line or in env.
/// A declared model as `_acpmux/models` lists it: id, name, `declared`, and
/// the catalog fields its profile file gave (shortName, family, efforts…).
pub fn declared_model_json(
    model: &crate::config::DeclaredModel,
    meta: Option<&crate::config::ProfileMeta>,
) -> Value {
    let mut v = json!({"id": model.id(), "name": model.name(), "declared": true});
    if let Some(detail) = meta.and_then(|m| m.model_details.iter().find(|d| d.id == model.id()))
        && let (Some(out), Ok(Value::Object(extra))) =
            (v.as_object_mut(), serde_json::to_value(detail))
    {
        for (k, x) in extra {
            if k != "id" && k != "name" {
                out.insert(k, x);
            }
        }
    }
    v
}

/// `session/new` for a terminal harness: it runs in a terminal tab.
pub fn terminal_harness_refusal(name: &str) -> RpcError {
    RpcError::invalid_params(format!(
        "harness.terminal: {name} is a terminal harness without ACP; open it with `cmux harness run {name}`"
    ))
    .with_data(json!({"reason": "harness.terminal", "harness": name}))
}

pub fn profile_takes_model_at_spawn(profile: &HarnessProfile) -> bool {
    profile.argv.iter().any(|a| a.contains("${model}"))
        || profile.env.values().any(|v| v.contains("${model}"))
}

/// What `session/new` carries: `harness` is a family or profile name
/// (the head of `-m HEAD/MODEL`), `preset` a `presets` entry. Explicit
/// values win over the preset, which wins over the defaults chain.
#[derive(Debug, Clone, Default)]
pub struct NewRequest {
    pub harness: Option<String>,
    pub preset: Option<String>,
    pub name: Option<String>,
    /// None: the adopted session's recorded cwd, else the home directory.
    pub cwd: Option<PathBuf>,
    pub policy: Option<PermissionPolicy>,
    pub model: Option<String>,
    pub effort: Option<String>,
    /// Requested over a remote-origin connection (the WebSocket listener).
    pub remote: bool,
    /// A harness session to resume instead of starting a new one.
    pub adopt: Option<crate::adopt::AdoptRequest>,
    /// Per-session env (`session_env.rs`), already checked by the caller.
    pub env: std::collections::BTreeMap<String, String>,
}

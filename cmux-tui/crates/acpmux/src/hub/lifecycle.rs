//! Part of `Hub`; see `hub/mod.rs`.

use super::*;

impl Hub {
    // --------------------------------------------------------- lifecycle

    /// Refresh the configured catalog while keeping all session processes alive.
    pub async fn reload_catalog(self: &Arc<Self>) -> Result<Value, RpcError> {
        let path = self.config.read().await.path.clone()
            .ok_or_else(|| RpcError::invalid_params("this daemon has no config file to reload"))?;
        // Disk reads and PATH discovery run outside the async executor. An
        // invalid/missing file never replaces the last accepted configuration.
        let mut next = tokio::task::spawn_blocking(move || {
            std::fs::metadata(&path)?;
            crate::config::Config::load_from(&path)
        }).await.map_err(|e| RpcError::internal(e.to_string()))?
            .map_err(|e| RpcError::invalid_params(format!("reload config: {e}")))?;
        let (harnesses, default_harness, retained) = {
            let mut current = self.config.write().await;
            let mut retained = Vec::new();
            for session in self.sessions.lock().unwrap().values() {
                let name = session.meta().harness;
                if !next.harnesses.contains_key(&name)
                    && let Some(old) = current.harnesses.get(&name) {
                        next.harnesses.insert(name.clone(), old.clone());
                        // Do not resurrect a deleted profile in config.json on
                        // the next preset/default save.
                        next.discovered.insert(name.clone());
                        retained.push(name);
                    }
            }
            // Only unchanged launchers inherit a startup validation failure.
            next.unavailable = current.unavailable.iter()
                .filter(|(n, _)| current.harnesses.get(*n) == next.harnesses.get(*n))
                .map(|(n, reason)| (n.clone(), reason.clone())).collect();
            // Keep cached models until fresh probes finish, invalidating only
            // changed/removed profiles. Listeners, peers, store and policy stay put.
            self.known_models.lock().unwrap().retain(|name, _|
                current.harnesses.get(name) == next.harnesses.get(name));
            current.harnesses = next.harnesses;
            current.default_harness = next.default_harness;
            current.defaults = next.defaults;
            current.presets = next.presets;
            current.discovered = next.discovered;
            current.auto_fallback = next.auto_fallback;
            current.auto_default = next.auto_default;
            current.auto_prefer = next.auto_prefer;
            current.unavailable = next.unavailable;
            (current.harnesses.keys().cloned().collect::<Vec<_>>(), current.default_harness.clone(), retained)
        };
        self.probe_models_with(true, false).await;
        Ok(json!({"reloaded": true, "harnesses": harnesses, "defaultHarness": default_harness,
            "retainedProfiles": retained, "modelProbePending": true}))
    }

    pub async fn new_session(self: &Arc<Self>, req: NewRequest) -> Result<Arc<Session>, RpcError> {
        let NewRequest { harness, preset, name, cwd, policy, model, effort } = req;
        // Resolution is a lookup, never a guess: preset → head (family or
        // profile) → defaults chain → explicit values on top.
        let (agent, profile, defaults, head, preset_name) = {
            let cfg = self.config.read().await;
            let preset_cfg = match &preset {
                Some(n) => Some(cfg.presets.get(n).cloned().ok_or_else(|| {
                    RpcError::invalid_params(format!("unknown preset {n:?}; presets: {}", if cfg.presets.is_empty() { "none".to_owned() } else { cfg.presets.keys().cloned().collect::<Vec<_>>().join(", ") }))
                })?),
                None => None,
            };
            let head = harness
                .clone()
                .or_else(|| preset_cfg.as_ref().map(|p| p.harness.clone()))
                .or_else(|| cfg.default_harness.clone())
                .ok_or_else(|| RpcError::invalid_params("no harnesses configured; add one to config.json"))?;
            let resolved = cfg.resolve_harness(&head).map_err(|e| RpcError::invalid_params(self.with_model_hint(&cfg, &head, model.as_deref(), e)))?;
            if let Some(reason) = cfg.unavailable.get(&resolved) {
                return Err(RpcError::invalid_params(format!("harness {resolved} is unavailable: {reason}")));
            }
            let profile = cfg.harnesses[&resolved].clone();
            let mut d = cfg.defaults_for(&resolved);
            if let Some(p) = &preset_cfg {
                d.overlay(&crate::config::SessionDefaults { model: p.model.clone(), effort: p.effort.clone(), policy: p.policy, prefer: vec![], env: p.env.clone() });
            }
            (resolved, profile, d, head, preset)
        };
        let agent = agent.as_str();
        let family = crate::config::derive_family(agent, &profile);
        let policy = policy.or(defaults.policy);
        let model = model.or(defaults.model);
        let effort = effort.or(defaults.effort);
        // `${model}` in argv or env: the model is a spawn parameter, not a
        // set_model call.
        let spawn_model = profile_takes_model_at_spawn(&profile) || defaults.env.values().any(|v| v.contains("${model}"));
        let cwd = if cwd.is_absolute() {
            cwd
        } else {
            std::env::current_dir().unwrap_or_default().join(cwd)
        };
        if !cwd.is_dir() {
            return Err(RpcError::invalid_params(format!(
                "cwd {} is not a directory",
                cwd.display()
            )));
        }
        let id = uuid::Uuid::now_v7().to_string();
        let name = name.unwrap_or_else(|| self.unique_name(agent));
        if self.sessions.lock().unwrap().values().any(|s| s.meta().name == name) {
            return Err(RpcError::invalid_params(format!("session name {name:?} is taken")));
        }
        let now = now_ms();
        let meta = SessionMeta {
            schema: META_SCHEMA.into(),
            id: id.clone(),
            name,
            harness: agent.into(),
            harness_argv: profile.argv.clone(),
            family: Some(family),
            preset: preset_name.clone(),
            model_request: if spawn_model { model.clone() } else { None },
            cwd,
            agent_session_id: None,
            status: SessionStatus::Idle,
            created_at: now,
            updated_at: now,
            last_seq: 0,
            parent_id: None,
            fork_seq: None,
            agent_info: None,
            agent_capabilities: None,
            modes: None,
            config_options: None,
            models: None,
            permission_policy: policy.map(|p| p.to_string()),
            title: None,
            last_prompt: None,
            preview: None,
            event_count: 0,
            turn_count: 0,
            usage: None,
            permission_rules: None,
            tags: Default::default(),
            unread: false,
        };
        let session = self.make_session(meta);
        self.store
            .save(&session.meta())
            .map_err(|e| RpcError::internal(e.to_string()))?;
        self.sessions
            .lock()
            .unwrap()
            .insert(id.clone(), session.clone());
        self.append(&session, "mux", "created", json!({"harness": agent, "preset": preset_name}));
        self.ensure_child(&session, &self.spawn_profile(&session, &profile, &defaults.env).await).await?;
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
        Ok(session)
    }

    /// "did you mean codex/gpt-5.5": a `-m` head that is no harness may be a
    /// bare model id, or `HEAD/MODEL` may be a full id such as
    /// `opencode-go/deepseek-v4-flash`.
    fn with_model_hint(&self, cfg: &crate::config::Config, head: &str, model: Option<&str>, err: String) -> String {
        let spec = match model { Some(m) => format!("{head}/{m}"), None => head.to_owned() };
        let known = self.known_models.lock().unwrap();
        let mut hits: Vec<String> = Vec::new();
        for (name, p) in &cfg.harnesses {
            let mut ids: Vec<String> = p.models.iter().map(|m| m.id().to_owned()).collect();
            match p.kind {
                crate::config::HarnessKind::ClaudeStdio => ids.extend(crate::claude_stdio::models().iter().map(|(id, _)| id.to_string())),
                crate::config::HarnessKind::Acp => ids.extend(known.get(name).into_iter().flatten().map(|(id, _)| id.clone())),
            }
            if ids.contains(&spec) || (p.kind == crate::config::HarnessKind::ClaudeStdio && spec.starts_with("claude")) {
                hits.push(format!("{name}/{spec}"));
            }
        }
        if hits.is_empty() { err } else { format!("{err}. {spec:?} is a model id: write {}", hits.join(" or ")) }
    }

    /// Every model id a profile can run: declared in config, then reported
    /// (Claude's static list for the stdio backend).
    pub async fn catalog_ids(&self, profile: &str) -> Vec<String> {
        let cfg = self.config.read().await;
        let Some(p) = cfg.harnesses.get(profile) else { return vec![] };
        let mut ids: Vec<String> = p.models.iter().map(|m| m.id().to_owned()).collect();
        match p.kind {
            crate::config::HarnessKind::ClaudeStdio => ids.extend(crate::claude_stdio::models().iter().map(|(id, _)| id.to_string())),
            crate::config::HarnessKind::Acp => ids.extend(self.known_models.lock().unwrap().get(profile).into_iter().flatten().map(|(id, _)| id.clone())),
        }
        ids.dedup();
        ids
    }

    pub(super) fn unique_name(&self, agent: &str) -> String {
        let taken: Vec<String> = self
            .sessions
            .lock()
            .unwrap()
            .values()
            .map(|s| s.meta().name)
            .collect();
        for n in 0.. {
            let candidate = if n == 0 {
                agent.to_owned()
            } else {
                format!("{agent}-{n}")
            };
            if !taken.contains(&candidate) {
                return candidate;
            }
        }
        unreachable!()
    }

    /// Make sure a live child process exists for the session. Spawns, runs
    /// `initialize`, and either creates or loads the agent session.
    pub(super) async fn ensure_child(
        self: &Arc<Self>,
        session: &Arc<Session>,
        profile: &HarnessProfile,
    ) -> Result<Arc<ChildAgent>, RpcError> {
        if let Some(child) = session.child.lock().await.as_ref()
            && child.is_alive().await {
                return Ok(child.clone());
            }
        // A stopped session reopens on demand. Only a purge is final.
        if session.status() == SessionStatus::Closed {
            self.append(session, "mux", "reopened", json!({}));
            self.set_status(session, SessionStatus::Idle);
        }
        let meta = session.meta();
        let tap_session = session.clone();
        let tap_hub = self.clone();
        let tap: crate::agent::Tap = Arc::new(move |dir: Direction, msg: &Message| {
            let (d, kind) = match (dir, msg) {
                (Direction::In, Message::Notification { method, params }) => {
                    let mut kind = method.clone();
                    if method.starts_with("claude.") {
                        // Raw stream-json line; translated messages follow.
                        tap_hub.append(&tap_session, "in", &kind, params.clone().unwrap_or(Value::Null));
                        return;
                    }
                    if method == crate::rpc::method::SESSION_UPDATE {
                        if let Some(su) = params
                            .as_ref()
                            .and_then(|p| p.get("update"))
                            .and_then(|u| u.get("sessionUpdate"))
                            .and_then(Value::as_str)
                        {
                            kind = su.to_owned();
                        }
                        if tap_session.loading.load(Ordering::SeqCst) {
                            kind.push_str(".replay");
                        }
                    }
                    ("in", kind)
                }
                (Direction::In, Message::Request { method, .. }) => ("in", method.clone()),
                (Direction::In, Message::Response { .. }) => ("in", "response".to_owned()),
                (Direction::Out, Message::Request { method, .. }) => ("out", method.clone()),
                (Direction::Out, Message::Notification { method, params }) if method == "claude.stdin" => {
                    tap_hub.append(&tap_session, "out", "claude.stdin", params.clone().unwrap_or(Value::Null));
                    return;
                }
                (Direction::Out, Message::Notification { method, .. }) => ("out", method.clone()),
                (Direction::Out, Message::Response { .. }) => ("out", "response".to_owned()),
            };
            tap_hub.append(&tap_session, d, &kind, msg.to_value());
        });
        let is_claude = profile.kind == crate::config::HarnessKind::ClaudeStdio;
        let existing_sid = session.meta().agent_session_id.clone();
        let fork_from = session.fork_from.lock().unwrap().take();
        let child = if is_claude {
            // Claude carries its own session in the process: resume by id, or
            // fork from a parent id into a fresh session.
            let (resume, fork) = match (&fork_from, &existing_sid) {
                (Some(parent), _) => (Some(parent.as_str()), true),
                (None, Some(sid)) => (Some(sid.as_str()), false),
                (None, None) => (None, false),
            };
            let fresh_id = if resume.is_none() { Some(uuid::Uuid::now_v7().to_string()) } else { None };
            let effort = current_option(&meta, "effort").unwrap_or_else(|| "default".into());
            let mode = meta.modes.as_ref().and_then(|m| m.get("currentModeId")).and_then(Value::as_str).unwrap_or("default").to_owned();
            let plan = crate::claude_stdio::spawn_plan(profile, resume, fork, fresh_id.as_deref(), Some(&effort), &mode);
            let model = current_model(&meta).unwrap_or_else(|| "default".into());
            let tr = crate::claude_stdio::Translator::new(session.id.clone(), &mode, &model, &effort);
            if !fork {
                // A fresh process was given its id; a resumed one already has it.
                let known = fresh_id.clone().or_else(|| existing_sid.clone());
                if let Some(sid) = known {
                    *tr.session_id.lock().await = Some(sid);
                }
            }
            ChildAgent::spawn_with(&meta.harness, profile, &meta.cwd, session.inbound_tx.clone(), tap, Some((plan.program, plan.args)), Some(tr), Some((&session.id, &meta.name)))
                .await
                .map_err(|e| RpcError::internal(e.to_string()))?
        } else {
            ChildAgent::spawn_with(&meta.harness, profile, &meta.cwd, session.inbound_tx.clone(), tap, None, None, Some((&session.id, &meta.name)))
                .await
                .map_err(|e| RpcError::internal(e.to_string()))?
        };
        *session.child.lock().await = Some(child.clone());

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
            let known = child.translator.as_ref().unwrap().session_id.lock().await.clone();
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
            let sid = child.translator.as_ref().unwrap().session_id.lock().await.clone();
            let modes = child.translator.as_ref().unwrap().modes_value().await;
            let opts = child.translator.as_ref().unwrap().config_options_value().await;
            {
                let mut m = session.meta.lock().unwrap();
                let level = if fork_from.is_some() { "fork" } else if existing_sid.is_some() { "exact" } else { "new" };
                m.agent_session_id = sid.clone();
                m.modes = Some(modes);
                m.config_options = Some(opts);
                drop(m);
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
                    .request(
                        method::SESSION_LOAD,
                        json!({"sessionId": sid, "cwd": meta.cwd, "mcpServers": []}),
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
                        self.append(
                            session,
                            "mux",
                            "resume_failed",
                            json!({"error": e.message}),
                        );
                        false
                    }
                }
            }
            Some(_) => false,
            None => false,
        };
        if !loaded {
            let had_history = session.meta().agent_session_id.is_some();
            let res = child
                .request(
                    method::SESSION_NEW,
                    json!({"cwd": meta.cwd, "mcpServers": []}),
                )
                .await?;
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
    async fn replay_config(&self, session: &Arc<Session>, child: &Arc<ChildAgent>, saved: &SessionMeta) {
        let Some(sid) = session.meta().agent_session_id else { return };
        if let Some(mode) = saved.modes.as_ref().and_then(|m| m.get("currentModeId")).and_then(Value::as_str) {
            if let Err(e) = child.request(method::SESSION_SET_MODE, json!({"sessionId": sid, "modeId": mode})).await {
                tracing::warn!(session = %session.id, "replay mode {mode}: {}", e.message);
            } else if let Some(m) = session.meta.lock().unwrap().modes.as_mut() {
                m["currentModeId"] = json!(mode);
            }
        }
        let opts: Vec<(String, Value)> = saved
            .config_options
            .as_ref()
            .and_then(Value::as_array)
            .map(|a| a.iter().filter_map(|o| Some((o.get("id")?.as_str()?.to_owned(), o.get("currentValue")?.clone()))).collect())
            .unwrap_or_default();
        // Model first.
        let ordered: Vec<(String, Value)> = opts.iter().filter(|(k, _)| k == "model").chain(opts.iter().filter(|(k, _)| k != "model")).cloned().collect();
        for (id, value) in ordered {
            if value.is_null() {
                continue;
            }
            match child.request(method::SESSION_SET_CONFIG_OPTION, json!({"sessionId": sid, "configId": id, "value": value})).await {
                Ok(res) => {
                    if let Some(o) = res.get("configOptions") {
                        session.meta.lock().unwrap().config_options = Some(o.clone());
                    }
                }
                Err(e) => tracing::warn!(session = %session.id, "replay {id}: {}", e.message),
            }
        }
        if opts.is_empty()
            && let Some(model) = saved.models.as_ref().and_then(|m| m.get("currentModelId")).and_then(Value::as_str)
                && let Err(e) = child.request(method::SESSION_SET_MODEL, json!({"sessionId": sid, "modelId": model})).await {
                    tracing::warn!(session = %session.id, "replay model {model}: {}", e.message);
                }
        self.append(session, "mux", "config", json!({"replayed": true}));
    }

    /// Remember the models an agent lists so the picker can show them for
    /// harnesses without a live session.
    pub(super) fn remember_models(&self, agent: &str, meta: &SessionMeta) {
        self.remember_models_from(agent, meta.config_options.as_ref(), meta.models.as_ref());
    }

    fn remember_models_from(&self, agent: &str, config_options: Option<&Value>, models: Option<&Value>) {
        let mut list: Vec<(String, String)> = Vec::new();
        if let Some(opts) = config_options.and_then(Value::as_array)
            && let Some(o) = opts.iter().find(|o| o.get("id").and_then(Value::as_str) == Some("model")) {
                list.extend(crate::model_catalog::choices(o));
            }
        if list.is_empty()
            && let Some(models) = models.and_then(|m| m.get("availableModels")).and_then(Value::as_array) {
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

    async fn probe_models_with(self: &Arc<Self>, force: bool, wait: bool) {
        let agents: Vec<(String, HarnessProfile)> = {
            let cfg = self.config.read().await;
            let known = self.known_models.lock().unwrap();
            cfg.harnesses
                .iter()
                .filter(|(n, p)| p.kind == crate::config::HarnessKind::Acp && (force || !known.contains_key(*n)))
                .map(|(n, p)| (n.clone(), p.clone()))
                .collect()
        };
        let mut handles = Vec::new();
        for (name, profile) in agents {
            let hub = self.clone();
            handles.push(tokio::spawn(async move {
                match tokio::time::timeout(std::time::Duration::from_secs(60), hub.probe_one(&name, &profile)).await {
                    Ok(Ok(n)) => tracing::info!(agent = %name, models = n, "model probe done"),
                    Ok(Err(e)) => tracing::warn!(agent = %name, error = %e, "model probe failed"),
                    Err(_) => tracing::warn!(agent = %name, "model probe timed out"),
                }
            }));
        }
        if wait {
            for h in handles {
                let _ = h.await;
            }
        }
    }

    async fn probe_one(self: &Arc<Self>, name: &str, profile: &HarnessProfile) -> anyhow::Result<usize> {
        let (tx, mut rx) = tokio::sync::mpsc::channel(64);
        let tap: crate::agent::Tap = Arc::new(|_, _| {});
        let cwd = dirs::home_dir().unwrap_or_else(|| std::path::PathBuf::from("/"));
        let child = crate::agent::ChildAgent::spawn(name, profile, &cwd, tx, tap).await?;
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

    /// Every configured harness with the models known for it.
    pub async fn models_catalog(&self) -> Value {
        let cfg = self.config.read().await;
        let known = self.known_models.lock().unwrap().clone();
        let mut out = Vec::new();
        for (name, profile) in &cfg.harnesses {
            let mut models: Vec<Value> = profile.models.iter().map(|m| json!({"id": m.id(), "name": m.name(), "declared": true})).collect();
            let reported: Vec<Value> = match profile.kind {
                crate::config::HarnessKind::ClaudeStdio => crate::claude_stdio::models().iter().map(|(v, n)| json!({"id": v, "name": n})).collect(),
                crate::config::HarnessKind::Acp => known.get(name).map(|l| l.iter().map(|(v, n)| json!({"id": v, "name": n})).collect()).unwrap_or_default(),
            };
            for r in reported {
                if !models.iter().any(|m| m["id"] == r["id"]) {
                    models.push(r);
                }
            }
            if models.is_empty() {
                models.push(json!({"id": "default", "name": "default (agent's choice)"}));
            }
            out.push(json!({"harness": name, "kind": profile.kind, "isDefault": cfg.default_harness.as_deref() == Some(name), "models": models}));
        }
        json!({"harnesses": out})
    }

    pub(super) fn absorb_session_response(&self, session: &Session, v: &Value) {
        let mut m = session.meta.lock().unwrap();
        if let Some(modes) = v.get("modes")
            && !modes.is_null() {
                m.modes = Some(modes.clone());
            }
        if let Some(opts) = v.get("configOptions")
            && !opts.is_null() {
                m.config_options = Some(opts.clone());
            }
        if let Some(models) = v.get("models")
            && !models.is_null() {
                m.models = Some(models.clone());
            }
    }

    pub(super) async fn child_for(self: &Arc<Self>, session: &Arc<Session>) -> Result<Arc<ChildAgent>, RpcError> {
        if let Some(child) = session.child.lock().await.as_ref()
            && child.is_alive().await { return Ok(child.clone()); }
        let agent = session.meta().harness;
        let (profile, defaults) = {
            let cfg = self.config.read().await;
            let profile = cfg.profile(&agent).cloned().ok_or_else(|| RpcError::invalid_params(format!("unknown harness {agent:?}")))?;
            (profile, cfg.defaults_for(&agent))
        };
        let spawn = self.spawn_profile(session, &profile, &defaults.env).await;
        self.ensure_child(session, &spawn).await
    }

    /// The profile as it is spawned for this session: family and profile
    /// default env underneath the profile's own, the preset's env on top,
    /// then `${cwd}`, `${home}`, `${model}` and a leading `~/` expanded in
    /// every env value and argv word.
    pub(super) async fn spawn_profile(&self, session: &Session, profile: &HarnessProfile, defaults_env: &std::collections::BTreeMap<String, String>) -> HarnessProfile {
        let meta = session.meta();
        let mut p = profile.clone();
        for (k, v) in defaults_env {
            p.env.entry(k.clone()).or_insert_with(|| v.clone());
        }
        if let Some(name) = &meta.preset
            && let Some(preset) = self.config.read().await.presets.get(name) {
                for (k, v) in &preset.env {
                    p.env.insert(k.clone(), v.clone());
                }
            }
        let home = dirs::home_dir().unwrap_or_default();
        let model = meta.model_request.clone().unwrap_or_default();
        for v in p.env.values_mut() {
            *v = expand_env_value(v, &meta.cwd, &home, &model);
        }
        for a in p.argv.iter_mut() {
            *a = expand_env_value(a, &meta.cwd, &home, &model);
        }
        p
    }

}

/// Whether the harness takes its model on the command line or in env.
pub fn profile_takes_model_at_spawn(profile: &HarnessProfile) -> bool {
    profile.argv.iter().any(|a| a.contains("${model}")) || profile.env.values().any(|v| v.contains("${model}"))
}

/// What `session/new` carries: `harness` is a family or profile name
/// (the head of `-m HEAD/MODEL`), `preset` a `presets` entry. Explicit
/// values win over the preset, which wins over the defaults chain.
#[derive(Debug, Clone, Default)]
pub struct NewRequest {
    pub harness: Option<String>,
    pub preset: Option<String>,
    pub name: Option<String>,
    pub cwd: PathBuf,
    pub policy: Option<PermissionPolicy>,
    pub model: Option<String>,
    pub effort: Option<String>,
}

/// `${cwd}`, `${home}`, `${model}` and a leading `~/` in a profile env value or argv word.
pub fn expand_env_value(value: &str, cwd: &std::path::Path, home: &std::path::Path, model: &str) -> String {
    let mut out = value.replace("${cwd}", &cwd.to_string_lossy()).replace("${home}", &home.to_string_lossy()).replace("${model}", model);
    if let Some(rest) = out.strip_prefix("~/") {
        out = format!("{}/{rest}", home.to_string_lossy());
    }
    out
}

#[cfg(test)]
mod env_tests {
    #[test]
    fn expands_cwd_and_home() {
        let cwd = std::path::Path::new("/work/proj");
        let home = std::path::Path::new("/Users/me");
        assert_eq!(super::expand_env_value("${cwd}/.codex", cwd, home, ""), "/work/proj/.codex");
        assert_eq!(super::expand_env_value("~/.omp", cwd, home, ""), "/Users/me/.omp");
        assert_eq!(super::expand_env_value("${home}/x:${cwd}", cwd, home, ""), "/Users/me/x:/work/proj");
        assert_eq!(super::expand_env_value("--model=${model}", cwd, home, "gpt-5.5"), "--model=gpt-5.5");
        assert_eq!(super::expand_env_value("plain", cwd, home, ""), "plain");
    }
}

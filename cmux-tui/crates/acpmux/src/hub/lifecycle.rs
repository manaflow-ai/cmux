//! Part of `Hub`; see `hub/mod.rs`.

use super::*;

impl Hub {
    // --------------------------------------------------------- lifecycle

    pub async fn new_session(
        self: &Arc<Self>,
        agent: &str,
        name: Option<String>,
        cwd: PathBuf,
        policy: Option<PermissionPolicy>,
        model: Option<String>,
        effort: Option<String>,
    ) -> Result<Arc<Session>, RpcError> {
        // `agent` may be a family (`claude`, `codex`): the family's prefer
        // list, then an exact profile, then the first profile in the family.
        let requested = agent;
        let (agent, profile, defaults) = {
            let cfg = self.config.read().await;
            let resolved = self.resolve_harness_in(&cfg, requested).ok_or_else(|| {
                let fams: Vec<String> = cfg.families().keys().cloned().collect();
                let aliases = cfg.aliases();
                RpcError::invalid_params(format!(
                    "unknown harness {requested:?}; profiles: {}; families: {}{}",
                    cfg.harnesses.keys().cloned().collect::<Vec<_>>().join(", "),
                    fams.join(", "),
                    if aliases.is_empty() { String::new() } else { format!("; aliases: {}", aliases.join(", ")) }
                ))
            })?;
            let profile = cfg.harnesses[&resolved].clone();
            let defaults = cfg.defaults_for_request(requested, &resolved);
            (resolved, profile, defaults)
        };
        let agent = agent.as_str();
        let family = crate::config::derive_family(agent, &profile);
        let policy = policy.or(defaults.policy);
        let model = model.or_else(|| defaults.model_for(agent));
        let effort = effort.or(defaults.effort);
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
        self.append(&session, "mux", "created", json!({"harness": agent}));
        let cwd_for_env = session.meta().cwd;
        self.ensure_child(&session, &self.with_default_env(&profile, &defaults.env, &cwd_for_env)).await?;
        // Family or profile defaults, applied once the harness is up. A bad
        // default fails creation loudly rather than starting a session that
        // silently runs another model.
        let applied: Result<(), RpcError> = async {
            if let Some(m) = &model {
                if let Err(e) = self.set_model(&session, m).await {
                    let known: Vec<String> = self.known_models.lock().unwrap().get(agent).map(|l| l.iter().map(|(id, _)| id.clone()).collect()).unwrap_or_default();
                    let hint = if known.is_empty() { String::new() } else { format!("; models: {}", known.join(", ")) };
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
        if let Some(child) = session.child.lock().await.as_ref() {
            if child.is_alive().await {
                return Ok(child.clone());
            }
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
        if opts.is_empty() {
            if let Some(model) = saved.models.as_ref().and_then(|m| m.get("currentModelId")).and_then(Value::as_str) {
                if let Err(e) = child.request(method::SESSION_SET_MODEL, json!({"sessionId": sid, "modelId": model})).await {
                    tracing::warn!(session = %session.id, "replay model {model}: {}", e.message);
                }
            }
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
        if let Some(opts) = config_options.and_then(Value::as_array) {
            if let Some(o) = opts.iter().find(|o| o.get("id").and_then(Value::as_str) == Some("model")) {
                for c in o.get("options").and_then(Value::as_array).cloned().unwrap_or_default() {
                    let v = c.get("value").and_then(Value::as_str).unwrap_or("").to_owned();
                    let n = c.get("name").and_then(Value::as_str).unwrap_or(&v).to_owned();
                    list.push((v, n));
                }
            }
        }
        if list.is_empty() {
            if let Some(models) = models.and_then(|m| m.get("availableModels")).and_then(Value::as_array) {
                for m in models {
                    let v = m.get("modelId").and_then(Value::as_str).unwrap_or("").to_owned();
                    let n = m.get("name").and_then(Value::as_str).unwrap_or(&v).to_owned();
                    list.push((v, n));
                }
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
        let agents: Vec<(String, HarnessProfile)> = {
            let cfg = self.config.read().await;
            let known = self.known_models.lock().unwrap();
            cfg.harnesses
                .iter()
                .filter(|(n, p)| p.kind == crate::config::HarnessKind::Acp && !known.contains_key(*n))
                .map(|(n, p)| (n.clone(), p.clone()))
                .collect()
        };
        for (name, profile) in agents {
            let hub = self.clone();
            tokio::spawn(async move {
                match tokio::time::timeout(std::time::Duration::from_secs(60), hub.probe_one(&name, &profile)).await {
                    Ok(Ok(n)) => tracing::info!(agent = %name, models = n, "model probe done"),
                    Ok(Err(e)) => tracing::warn!(agent = %name, error = %e, "model probe failed"),
                    Err(_) => tracing::warn!(agent = %name, "model probe timed out"),
                }
            });
        }
    }

    async fn probe_one(self: &Arc<Self>, name: &str, profile: &HarnessProfile) -> anyhow::Result<usize> {
        let (tx, mut rx) = tokio::sync::mpsc::channel(64);
        let tap: crate::agent::Tap = Arc::new(|_, _| {});
        let cwd = dirs::home_dir().unwrap_or_else(|| std::path::PathBuf::from("/"));
        let child = crate::agent::ChildAgent::spawn(name, profile, &cwd, tx, tap).await?;
        // Drain anything the agent sends so its writer never blocks.
        let drain = tokio::spawn(async move { while rx.recv().await.is_some() {} });
        let result: anyhow::Result<usize> = async {
            child
                .request(method::INITIALIZE, json!({"protocolVersion": 1, "clientCapabilities": {}, "clientInfo": {"name": "acpmux", "version": env!("CARGO_PKG_VERSION")}}))
                .await
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let res = child
                .request(method::SESSION_NEW, json!({"cwd": cwd, "mcpServers": []}))
                .await
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            self.remember_models_from(name, res.get("configOptions").filter(|v| !v.is_null()), res.get("models").filter(|v| !v.is_null()));
            Ok(self.known_models.lock().unwrap().get(name).map(|l| l.len()).unwrap_or(0))
        }
        .await;
        child.kill().await;
        drain.abort();
        result
    }

    /// Every configured harness with the models known for it.
    pub async fn models_catalog(&self) -> Value {
        let cfg = self.config.read().await;
        let known = self.known_models.lock().unwrap().clone();
        let mut out = Vec::new();
        for (name, profile) in &cfg.harnesses {
            let mut models: Vec<Value> = match profile.kind {
                crate::config::HarnessKind::ClaudeStdio => crate::claude_stdio::models().iter().map(|(v, n)| json!({"id": v, "name": n})).collect(),
                crate::config::HarnessKind::Acp => known.get(name).map(|l| l.iter().map(|(v, n)| json!({"id": v, "name": n})).collect()).unwrap_or_default(),
            };
            if models.is_empty() {
                models.push(json!({"id": "default", "name": "default (agent's choice)"}));
            }
            out.push(json!({"harness": name, "kind": profile.kind, "isDefault": cfg.default_harness.as_deref() == Some(name), "models": models}));
        }
        json!({"harnesses": out})
    }

    pub(super) fn absorb_session_response(&self, session: &Session, v: &Value) {
        let mut m = session.meta.lock().unwrap();
        if let Some(modes) = v.get("modes") {
            if !modes.is_null() {
                m.modes = Some(modes.clone());
            }
        }
        if let Some(opts) = v.get("configOptions") {
            if !opts.is_null() {
                m.config_options = Some(opts.clone());
            }
        }
        if let Some(models) = v.get("models") {
            if !models.is_null() {
                m.models = Some(models.clone());
            }
        }
    }

    pub(super) async fn child_for(self: &Arc<Self>, session: &Arc<Session>) -> Result<Arc<ChildAgent>, RpcError> {
        let agent = session.meta().harness;
        let (profile, defaults) = {
            let cfg = self.config.read().await;
            let profile = cfg.profile(&agent).cloned().ok_or_else(|| RpcError::invalid_params(format!("unknown harness {agent:?}")))?;
            (profile, cfg.defaults_for(&agent))
        };
        let cwd = session.meta().cwd;
        self.ensure_child(session, &self.with_default_env(&profile, &defaults.env, &cwd)).await
    }

    /// Whether a profile can run a model, judged by the model list it
    /// reported (Claude and unprobed harnesses accept anything).
    pub fn knows_model(&self, profile: &str, model: Option<&str>) -> bool {
        let Some(m) = model else { return true };
        let known = self.known_models.lock().unwrap();
        match known.get(profile).filter(|l| !l.is_empty()) {
            Some(list) => list.iter().any(|(id, _)| id == m),
            None => true,
        }
    }

    /// The profile for a family, profile or alias name, skipping preferred
    /// profiles whose reported model list lacks the model they would get.
    pub fn resolve_harness_in(&self, cfg: &crate::config::Config, requested: &str) -> Option<String> {
        cfg.resolve_harness_where(requested, |p, m| self.knows_model(p, m))
    }

    /// The profile to run a model when the request named no agent: the
    /// profiles whose reported catalog lists it (Claude profiles for Claude
    /// aliases and ids), narrowed to the default agent, then family
    /// preference, then name order. None when nothing knows the model.
    pub fn resolve_by_model(&self, cfg: &crate::config::Config, model: &str) -> Option<String> {
        let known = self.known_models.lock().unwrap();
        let claude_like = model.starts_with("claude") || crate::claude_stdio::models().iter().any(|(id, _)| *id == model);
        let candidates: Vec<String> = cfg
            .harnesses
            .iter()
            .filter(|(name, p)| match p.kind {
                crate::config::HarnessKind::ClaudeStdio => claude_like,
                crate::config::HarnessKind::Acp => known.get(*name).map(|l| l.iter().any(|(id, _)| id == model)).unwrap_or(false),
            })
            .map(|(n, _)| n.clone())
            .collect();
        drop(known);
        if candidates.is_empty() {
            return None;
        }
        if let Some(d) = &cfg.default_harness {
            if candidates.contains(d) {
                return Some(d.clone());
            }
        }
        // The family's preferred profile when it is a candidate.
        for c in &candidates {
            if let Some(f) = cfg.family(c) {
                if let Some(p) = cfg.resolve_harness(&f) {
                    if candidates.contains(&p) {
                        return Some(p);
                    }
                }
            }
        }
        candidates.into_iter().next()
    }

    /// The profile with the family's default env underneath its own, and
    /// `${cwd}`, `${home}` and a leading `~/` expanded in every value, so an
    /// alias can point a harness at a per-project home
    /// (`CODEX_HOME=${cwd}/.codex`).
    fn with_default_env(&self, profile: &HarnessProfile, env: &std::collections::BTreeMap<String, String>, cwd: &std::path::Path) -> HarnessProfile {
        let mut p = profile.clone();
        for (k, v) in env {
            p.env.entry(k.clone()).or_insert_with(|| v.clone());
        }
        let home = dirs::home_dir().unwrap_or_default();
        for v in p.env.values_mut() {
            *v = expand_env_value(v, cwd, &home);
        }
        p
    }

}

/// `${cwd}`, `${home}` and a leading `~/` in a profile env value.
pub fn expand_env_value(value: &str, cwd: &std::path::Path, home: &std::path::Path) -> String {
    let mut out = value.replace("${cwd}", &cwd.to_string_lossy()).replace("${home}", &home.to_string_lossy());
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
        assert_eq!(super::expand_env_value("${cwd}/.codex", cwd, home), "/work/proj/.codex");
        assert_eq!(super::expand_env_value("~/.omp", cwd, home), "/Users/me/.omp");
        assert_eq!(super::expand_env_value("${home}/x:${cwd}", cwd, home), "/Users/me/x:/work/proj");
        assert_eq!(super::expand_env_value("plain", cwd, home), "plain");
    }
}

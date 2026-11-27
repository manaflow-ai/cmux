//! A chat's controls between turns: forward, mode, config, model and rename (part of `hub/turns.rs`).

use super::*;

impl Hub {
    /// Whether the failover onto profile `to` is skipped because it runs through the local
    /// CodeRouter (the built-in `cmux` profile or route) and this chat is on a Cloud machine or
    /// came over a remote connection (`fallback_start::coderouter_fallback_skipped`).
    pub(super) async fn no_coderouter_fallback(&self, session: &Session, to: &str) -> bool {
        let cfg = self.config.read().await;
        let Some(profile) = cfg.harnesses.get(to) else { return false };
        let remote = session.meta().remote_origin;
        super::fallback_start::coderouter_fallback_skipped(cfg.cloud_host, remote, to, profile)
    }

    /// The profile to fall over to, when the current one names one that exists.
    pub(super) async fn fallback_profile(&self, session: &Session) -> Option<String> {
        let cfg = self.config.read().await;
        let agent = session.meta().harness;
        let to = cfg.harnesses.get(&agent)?.fallback.clone()?;
        if to == agent || !cfg.harnesses.contains_key(&to) {
            return None;
        }
        Some(to)
    }

    /// Pass a session-scoped request to the child, rewriting the session id.
    pub async fn forward(
        self: &Arc<Self>,
        session: &Arc<Session>,
        m: &str,
        params: Value,
    ) -> Result<Value, RpcError> {
        self.forward_as(session, m, params, false).await
    }

    /// `forward`; `granted`: a paired machine's Full-access setting covers the
    /// request (`crate::pairing`), so only a deny-all policy holds the mode.
    pub(crate) async fn forward_as(
        self: &Arc<Self>,
        session: &Arc<Session>,
        m: &str,
        mut params: Value,
        granted: bool,
    ) -> Result<Value, RpcError> {
        // MDM's off as this switch begins: its one read, which every check below takes, so an off
        // that comes and goes while it waits on the agent still holds for it (reviews 73, 75 and
        // 77 of #23322).
        let off = self.off_latch();
        // The idle pass never ends the harness under a mode change (`idle.rs`).
        self.touch(session);
        let _using = session.harness_use.read().await;
        // Every switch into a mode that skips approvals, from any client (the app, the CLI, a
        // script), passes here: refused while `sessions.allowFullAccess` is off.
        if super::start_mode::requests_full_access(m, &params) && !off.allows_full_access() {
            return Err(super::start_mode::full_access_off());
        }
        // Nor does a switch out of the mode a narrower policy needs (`policy_mode.rs`).
        self.refuse_wider_mode_as(session, m, &params, granted).await?;
        let child = self.child_for(session).await?;
        // Again once the agent is there (its start can take seconds): MDM may have forced full
        // access off since. A push after this ends the agent at the next prompt (`child_for`).
        if super::start_mode::requests_full_access(m, &params) && !off.allows_full_access() {
            return Err(super::start_mode::full_access_off());
        }
        let sid = session
            .meta()
            .agent_session_id
            .ok_or_else(|| RpcError::internal("no agent session"))?;
        if params.is_null() {
            params = json!({});
        }
        params["sessionId"] = Value::String(sid);
        let asked_mode = (m == method::SESSION_SET_MODE)
            .then(|| params.get("modeId").and_then(Value::as_str).map(str::to_owned))
            .flatten();
        // A mode picked through the harness's `mode` option (Claude Code's, or a harness whose
        // mode is only that option).
        let asked_option_mode = (m == method::SESSION_SET_CONFIG_OPTION
            && params.get("configId").and_then(Value::as_str) == Some("mode"))
        .then(|| params.get("value").and_then(Value::as_str).map(str::to_owned))
        .flatten();
        let asked_option = (m == method::SESSION_SET_CONFIG_OPTION)
            .then(|| super::full_access_bound::asked_option(&params))
            .flatten();
        // Bounded (`forward_wait.rs`): an agent alive that never answers ends this request, and
        // the `harness_use` read it holds, at its start budget instead of never.
        let bound = self.config.read().await.agent_start_timeout();
        let mut wait =
            cmux_bounded::Driver::<super::forward_wait::ForwardWait, tokio::time::Instant>::new(
                super::forward_wait::ForwardWait::asked(bound),
            );
        let answer = tokio::select! {
            answer = child.request(m, params) => {
                wait.feed(super::forward_wait::Event::Answered);
                answer
            }
            () = wait.expired() => {
                wait.expire_due();
                Err(super::forward_wait::no_answer(m, bound))
            }
        };
        let res = match answer {
            Ok(v) => v,
            Err(mut e) => {
                // A process that died on this request: quote its last stderr
                // line, as prompt() does, so "agent process closed" says why.
                if e.message == "agent process closed" {
                    let tail: Vec<String> =
                        session.stderr_tail.lock().unwrap().iter().cloned().collect();
                    if let Some(last) = tail.iter().rev().find(|line| explains_exit(line)).cloned()
                    {
                        e.message =
                            format!("agent process closed ({}): {last}", session.meta().harness);
                    }
                }
                return Err(e);
            }
        };
        match m {
            method::SESSION_SET_MODE => {
                // The mode first, then the mark, under the lock, only while the chat runs it:
                // a write that moves the mode takes the mark (`write_mode_state`).
                let reported = res.get("currentModeId").or(res.get("modeId")).cloned();
                let mut writes = Vec::new();
                // Claude Code answers with its options too, the `mode` option now at the new
                // mode: kept with it, so the option never shows the mode the chat started in.
                if let Some(opts) = res.get("configOptions").filter(|o| o.is_array()) {
                    writes.push(ModeWrite::ConfigOptions(opts.clone()));
                }
                if let Some(mode) = reported.or_else(|| asked_mode.clone().map(Value::String)) {
                    writes.push(ModeWrite::CurrentMode(mode));
                }
                if !writes.is_empty() {
                    self.write_mode_state(session, writes);
                }
                let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
                if asked_mode.is_some() && crate::web_modes::mode_of(&meta) == asked_mode {
                    meta.mode_set_by_cmux = asked_mode;
                }
            }
            method::SESSION_SET_CONFIG_OPTION => {
                let mut writes = Vec::new();
                if let Some(opts) = res.get("configOptions") {
                    writes.push(ModeWrite::ConfigOptions(opts.clone()));
                }
                // A bare answer took the value asked (`record_option_answer`).
                super::full_access_bound::record_option_answer(session, &res, asked_option);
                // Claude Code answers a `mode` option with the mode it now runs.
                if asked_option_mode.is_some()
                    && let Some(mode) = res.get("currentModeId").cloned()
                {
                    writes.push(ModeWrite::CurrentMode(mode));
                }
                if !writes.is_empty() {
                    self.write_mode_state(session, writes);
                }
                // A mode picked through its option is cmux's as a `set_mode` one is, once the
                // harness runs it (`trust_wait.rs` `full_access_by_cmux`).
                if let Some(mode) = &asked_option_mode {
                    let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
                    if crate::web_modes::mode_of(&meta).as_deref() == Some(mode.as_str()) {
                        meta.mode_set_by_cmux = Some(mode.clone());
                    }
                }
            }
            method::SESSION_SET_MODEL => {
                if let Some(models) = res.get("models") {
                    session.meta.lock().unwrap().models = Some(models.clone());
                }
            }
            _ => {}
        }
        self.save_meta(session);
        // MDM forced full access off while this switch waited on the harness (after both checks
        // above). The mode is written before this reads the off, and the push writes the off
        // before its teardown reads modes (`end_every_managed_full_access`): either way the
        // agent ends.
        if self.managed_off_runs_full_access(&off, session) {
            let _spawning = session.spawn_lock.lock().await;
            self.end_if_runs_full_access(session, true).await;
            return Err(super::start_mode::full_access_off());
        }
        if m == method::SESSION_SET_MODE
            || (m == method::SESSION_SET_CONFIG_OPTION && asked_option_mode.is_some())
        {
            self.approve_pending_tools(session).await;
        }
        Ok(res)
    }

    pub async fn set_mode(
        self: &Arc<Self>,
        session: &Arc<Session>,
        mode_id: &str,
    ) -> Result<Value, RpcError> {
        self.set_mode_as(session, mode_id, false).await
    }

    /// `set_mode`; `granted` as in `forward_as`.
    pub(crate) async fn set_mode_as(
        self: &Arc<Self>,
        session: &Arc<Session>,
        mode_id: &str,
        granted: bool,
    ) -> Result<Value, RpcError> {
        // The mode the chat already records (a start's, a wake's or a policy's set of the same
        // mode), read before the harness's answer writes it: the harness is still told, but the
        // log gets no `mode` record (idle-gpu-disk). Only a declared mode: a harness's undeclared
        // one is kept in memory alone, its record the one trace of it. The save stays: it
        // journals nothing when the image is unchanged (`store/journal_store/meta.rs`), and it
        // keeps a harness's move that lands between this read and the writes below.
        let recorded_mode = |m: &SessionMeta| {
            m.modes
                .as_ref()
                .and_then(|modes| modes.get("currentModeId"))
                .and_then(Value::as_str)
                .map(str::to_owned)
        };
        let before = session.read_meta(recorded_mode);
        let r = self
            .forward_as(session, method::SESSION_SET_MODE, json!({"modeId": mode_id}), granted)
            .await?;
        // forward_as applied the harness's answer (or the requested mode for an empty ACP
        // acknowledgement). Never replace a different reported mode with the request here.
        let applied = session
            .read_meta(recorded_mode)
            .or_else(|| {
                r.get("currentModeId")
                    .or_else(|| r.get("modeId"))
                    .and_then(Value::as_str)
                    .map(str::to_owned)
            })
            .unwrap_or_else(|| mode_id.to_owned());
        if before.as_deref() != Some(applied.as_str()) {
            self.append(session, "mux", "mode", json!({"modeId": applied}));
        }
        self.save_meta_answered(session)?;
        Ok(r)
    }

    pub async fn set_config(
        self: &Arc<Self>,
        session: &Arc<Session>,
        config_id: &str,
        value: Value,
    ) -> Result<Value, RpcError> {
        self.set_config_as(session, config_id, value, false).await
    }

    /// `set_config`; `granted` as in `forward_as`.
    pub(crate) async fn set_config_as(
        self: &Arc<Self>,
        session: &Arc<Session>,
        config_id: &str,
        value: Value,
        granted: bool,
    ) -> Result<Value, RpcError> {
        // Make sure the child is up so its option list is known, then map
        // portable names (effort) onto the harness's own id.
        let _ = self.child_for(session).await?;
        let config_id = resolve_config_id(&session.meta(), config_id);
        let config_id = config_id.as_str();
        // A model the option does not list exactly, as the catalog names it (`model_alias.rs`).
        let value = match value.as_str() {
            Some(model)
                if config_id == "model" && !super::model_alias::option_lists(session, model) =>
            {
                Value::String(self.rewrite_session_model(session, model, "set_config").await?)
            }
            _ => value,
        };
        let r = self
            .forward_as(
                session,
                method::SESSION_SET_CONFIG_OPTION,
                json!({"configId": config_id, "value": value}),
                granted,
            )
            .await?;
        self.append(session, "mux", "config", json!({"configId": config_id, "value": value}));
        {
            let mut applied =
                session.applied.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            if let Some(effort) = super::start_defaults::effort_of(config_id, &value) {
                applied.effort = Some(effort.to_owned());
            }
        }
        Ok(r)
    }

    pub async fn set_model(
        self: &Arc<Self>,
        session: &Arc<Session>,
        model_id: &str,
    ) -> Result<Value, RpcError> {
        // Every switch (ACP `session/set_model`, `acpmux session set model=`, a fork's or a
        // start's model) as the catalog names it: `fable-5.2` runs as `claude-fable-5-2`.
        let model_id = &self.rewrite_session_model(session, model_id, "set_model").await?;
        let model_id = model_id.as_str();
        // A harness that takes its model on the command line or in env
        // gets it at the next spawn: record it and drop the current process.
        // Same test as `new_session`: the profile, its defaults' env, or the
        // session's preset env may carry `${model}`.
        let at_spawn = {
            let cfg = self.config.read().await;
            let meta = session.meta();
            let in_env = |env: &std::collections::BTreeMap<String, String>| {
                env.values().any(|v| v.contains("${model}"))
            };
            cfg.profile(&meta.harness)
                .map(super::lifecycle::profile_takes_model_at_spawn)
                .unwrap_or(false)
                || in_env(&cfg.defaults_for(&meta.harness).env)
                || meta
                    .preset
                    .as_ref()
                    .and_then(|n| cfg.presets.get(n))
                    .map(|p| in_env(&p.env) || p.args.iter().any(|a| a.contains("${model}")))
                    .unwrap_or(false)
        };
        if at_spawn {
            session.meta.lock().unwrap().model_request = Some(model_id.to_owned());
            self.save_meta_answered(session)?;
            // A switch never stops a running turn or cuts an open permission prompt (Leo
            // 2026-10-22: "switching model/harness/whatever shouldnt immediately stop
            // things"): the agent restarts on the new model when the turn ends, as a route
            // switch does (`route_switch.rs`), so the next prompt runs on it. Between turns
            // the process ends now, under the turn lock, and the next prompt starts it.
            let idle = || {
                if session.turn().is_none() && session.pending_permissions().is_empty() {
                    session.turn_lock.try_lock().ok()
                } else {
                    None
                }
            };
            let mut turn = idle();
            if turn.is_none() {
                session.route_switch.store(true, std::sync::atomic::Ordering::SeqCst);
                // The turn may have ended before the flag was seen: then now.
                turn = idle().filter(|_| {
                    session.route_switch.swap(false, std::sync::atomic::Ordering::SeqCst)
                });
            }
            let applied = if let Some(_turn) = turn {
                self.detach_child(session).await;
                "now"
            } else {
                "afterTurn"
            };
            self.append(
                session,
                "mux",
                "model",
                json!({"modelId": model_id, "atSpawn": true, "applied": applied}),
            );
            super::start_defaults::model_applied(session, model_id);
            return Ok(json!({"applied": applied}));
        }
        // Prefer the config option named "model" when the agent exposes one.
        let has_model_option = session
            .meta()
            .config_options
            .as_deref()
            .and_then(Value::as_array)
            .map(|opts| opts.iter().any(|o| o.get("id").and_then(Value::as_str) == Some("model")))
            .unwrap_or(false);
        if has_model_option {
            let meta = session.meta();
            let option = meta
                .config_options
                .as_deref()
                .and_then(Value::as_array)
                .and_then(|opts| opts.iter().find(|o| o["id"] == "model"))
                .unwrap();
            let value = Value::String(
                crate::model_catalog::resolve(option, model_id)
                    .map_err(RpcError::invalid_params)?,
            );
            let r = self.set_config(session, "model", value).await?;
            super::start_defaults::model_applied(session, model_id);
            return Ok(r);
        }
        let r =
            self.forward(session, method::SESSION_SET_MODEL, json!({"modelId": model_id})).await?;
        self.append(session, "mux", "model", json!({"modelId": model_id}));
        super::start_defaults::model_applied(session, model_id);
        // The harness runs this model now, also when its reply lists no models.
        let reported = match session.meta.lock().unwrap().models.as_mut() {
            Some(Value::Object(models)) => {
                models.insert("currentModelId".into(), json!(model_id));
                true
            }
            _ => false,
        };
        if reported {
            self.save_meta_answered(session)?;
        }
        Ok(r)
    }

    pub async fn rename(&self, session: &Arc<Session>, name: String) -> Result<(), RpcError> {
        self.rename_as(session, name, super::task_names::Naming::Hand).await
    }

    /// `rename`, saying who names it (`task_names::Naming`): a person's or an agent's rename
    /// titles it by the name in words, a task's by the task's title, an address (`register`)
    /// leaves its title as it is. Every one keeps the old name as a former name
    /// (`former_names.rs`); a name another session has now is refused, one it had is taken.
    pub(in crate::hub) async fn rename_as(
        &self,
        session: &Arc<Session>,
        name: String,
        naming: super::task_names::Naming<'_>,
    ) -> Result<(), RpcError> {
        use super::task_names::Naming;
        if self
            .sessions
            .lock()
            .unwrap()
            .values()
            .any(|s| s.id != session.id && s.read_meta(|m| m.name == name))
        {
            return Err(RpcError::invalid_params(format!("session name {name:?} is taken")));
        }
        let old = session.read_meta(|m| m.name.clone());
        self.release_former_names(session, &name, &old);
        let (old, titled) = {
            let mut m = session.meta.lock().unwrap();
            let prev_source = m.title_source.clone();
            // A chat renamed before it was titled asks no model for a title (`titles.rs`).
            super::titles::title_renamed(&mut m);
            let titled = match naming {
                Naming::Hand => super::task_names::name_in_words(&name).inspect(|title| {
                    super::title_log::renamed(session, &m.harness, prev_source.as_deref());
                    m.title = Some(title.clone());
                    m.title_source = Some(super::titles::NAMED.to_owned());
                    m.title_prompt = None;
                }),
                Naming::Task(title) => {
                    m.title = Some(title.to_owned());
                    m.title_source = Some(super::task_names::TASK.to_owned());
                    m.title_prompt = None;
                    Some(title.to_owned())
                }
                Naming::Address => None,
            };
            m.name_given = true;
            let old = std::mem::replace(&mut m.name, name.clone());
            super::former_names::push_former(&mut m.former_names, &old, &name);
            (old, titled)
        };
        // Both kept (`store/durability.rs`): the answer waits until they are written, not synced.
        self.append(session, "mux", "renamed", json!({"from": old, "to": name}));
        if let Some(title) = titled {
            self.append(session, "mux", "titled", json!({"title": title}));
        }
        self.save_meta_kept(session)?;
        // Its running Claude Code takes the name too (`live_name.rs`).
        self.rename_live_claude(session);
        Ok(())
    }
}

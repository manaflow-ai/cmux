//! Part of `Hub`; see `hub/mod.rs`. The model catalog of each harness: the ids a profile can
//! run, the lists agents report (`known_models`), and the probe that asks every ACP harness for
//! its models without creating a session.

use super::*;

impl Hub {
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

    /// Remember the models an agent lists so the picker can show them for
    /// harnesses without a live session.
    pub(super) fn remember_models(&self, agent: &str, meta: &SessionMeta) {
        self.remember_models_from(agent, meta.config_options.as_deref(), meta.models.as_ref());
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
            self.recheck_live_models(agent, &list);
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

    pub(super) async fn probe_one(
        self: &Arc<Self>,
        name: &str,
        profile: &HarnessProfile,
    ) -> anyhow::Result<usize> {
        // MDM's off as the probe starts: its one read, taken first (review 120). An off that holds
        // or begins while it runs ends it once its harness reported full access, an unset after it
        // too (reviews 71 and 73 of #23322).
        let latch = self.off_latch();
        let (tx, mut rx) = tokio::sync::mpsc::channel(64);
        // What the harness reports while its session starts (`StartReports`, reviews 41 and 46 of
        // #23322). The tap sees each line before its answer is handed back, so none sent before
        // that answer is missed.
        let reports =
            Arc::new(std::sync::Mutex::new(super::full_access_bound::StartReports::default()));
        // Notified on each report of full access: a probe ends on one under MDM's off (review 71).
        let reported = Arc::new(tokio::sync::Notify::new());
        let (seen, notify) = (reports.clone(), reported.clone());
        let tap: crate::agent::Tap = Arc::new(move |dir, msg, _| {
            if let (Direction::In, Message::Notification { method: m, params: Some(params) }) =
                (dir, msg)
                && m == method::SESSION_UPDATE
            {
                seen.lock().unwrap_or_else(|e| e.into_inner()).note(params);
                if super::full_access_bound::StartReports::reports_full_access(params) {
                    notify.notify_one();
                }
            }
            true
        });
        // Never the home folder: the agent scans its folder at start (LAUNCH-NO-TCC-PROMPTS).
        let cwd = tokio::task::spawn_blocking(crate::protected_folders::unattended_cwd)
            .await
            .unwrap_or_else(|_| std::env::temp_dir());
        // MDM forces full access off (#23322): a profile pinning it is never started to probe,
        // and a probe that runs when the off lands ends then (`probe_bound`).
        let mut bound =
            self.probe_bound(&latch, &profile.argv).map_err(|e| anyhow::anyhow!("{name}: {e}"))?;
        let mut resolved = profile.clone();
        resolved.argv = self.resolved_launcher_argv(resolved.argv);
        let child = crate::agent::ChildAgent::spawn(name, &resolved, &cwd, tx, tap).await?;
        // Drain anything the agent sends so its writer never blocks.
        let drain = tokio::spawn(async move { while rx.recv().await.is_some() {} });
        let listed = tokio::time::timeout(std::time::Duration::from_secs(50), async {
            child
                .request(method::INITIALIZE, json!({"protocolVersion": 1, "clientCapabilities": {}, "clientInfo": {"name": "acpmux", "version": env!("CARGO_PKG_VERSION")}}))
                .await
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let res = child
                .request(method::SESSION_NEW, json!({"cwd": cwd, "mcpServers": []}))
                .await
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            // MDM forces full access off (#23322, review 32): a session that came up in it (its
            // mode or a config option, a profile that pins nothing included) keeps nothing. Read
            // once it answered, so an off that landed during the handshake counts.
            let mut view =
                super::full_access_bound::FullAccessView::of_session_new(&profile.argv, Some(&res));
            view.reported = reports.lock().unwrap_or_else(|e| e.into_inner()).of_answer(Some(&res));
            if latch.off() && super::full_access_bound::runs_full_access(&view).is_some() {
                anyhow::bail!("{name}: its session came up in full access, which MDM forces off");
            }
            let cfg = self.config.read().await;
            if cfg.harnesses.get(name) == Some(profile) {
                self.remember_models_from(
                    name,
                    res.get("configOptions").filter(|v| !v.is_null()),
                    res.get("models").filter(|v| !v.is_null()),
                );
            }
            Ok(self.known_models.lock().unwrap().get(name).map(|l| l.len()).unwrap_or(0))
        });
        let result = tokio::select! {
            listed = listed => listed,
            () = super::full_access_bound::full_access_forced_off(bound.as_mut()) => {
                Ok(Err(anyhow::anyhow!("{name}: MDM forced full access off, which its profile pins")))
            }
            () = latch.reported_under_off(&reported, || {
                reports.lock().unwrap_or_else(|e| e.into_inner()).of(None)
            }) => {
                Ok(Err(anyhow::anyhow!("{name}: its harness reported full access, which MDM forces off")))
            }
        };
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
}

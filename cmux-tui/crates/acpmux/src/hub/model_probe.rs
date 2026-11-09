//! Part of `Hub`; see `hub/mod.rs`. The model catalog of each harness: the ids a profile can
//! run, the lists agents report (`known_models`), and the probe that asks every ACP harness for
//! its models without creating a session.

use super::*;
use std::sync::PoisonError;

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

    /// Whether the list `agent` reported is not the one served before (none, the disk copy, or
    /// an earlier report): only then do watchers hear of it (`keep_probed_models`).
    fn remember_models_from(
        &self,
        agent: &str,
        config_options: Option<&Value>,
        models: Option<&Value>,
    ) -> bool {
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
        if list.is_empty() {
            return false;
        }
        self.recheck_live_models(agent, &list);
        let old = self.known_models.lock().unwrap().insert(agent.to_owned(), list.clone());
        self.acp_from_disk.lock().unwrap_or_else(PoisonError::into_inner).remove(agent);
        old.is_none_or(|old| old != list)
    }

    /// Reads the ACP lists earlier probes kept (`live_models::AcpCache`) and serves each whose
    /// profile is unchanged. Daemon start, before the login environment and the probes, so the
    /// first `_acpmux/models` names OpenCode's or Gemini's models, not only "default"; the
    /// probe still runs and replaces the list. A pane that read `_acpmux/models` before this
    /// ran hears `_acpmux/harnesses_changed` once, when some harness was served its disk list.
    pub(super) async fn load_acp_cache(&self) {
        self.load_acp_cache_from(crate::live_models::AcpCache::default_dir()).await;
    }

    pub(super) async fn load_acp_cache_from(&self, dir: std::path::PathBuf) {
        // A capture fixture's harnesses show no list of this host's (`harness_fixture.rs`).
        if crate::harness_fixture::active().is_some() {
            return;
        }
        let cached =
            tokio::task::spawn_blocking(move || crate::live_models::AcpCache::new(dir).load_all())
                .await
                .unwrap_or_default();
        *self.acp_cached.lock().unwrap_or_else(PoisonError::into_inner) =
            cached.into_iter().collect();
        let served = self.serve_acp_cache(&self.config.read().await.harnesses);
        if served {
            self.announce_harnesses().await;
        }
    }

    /// Fills `known_models` from the disk copy for each ACP profile that has no list yet and
    /// was probed under the same profile. Also after a catalog reload: a profile found on the
    /// login PATH appears only then. True when it served some harness a list.
    pub(super) fn serve_acp_cache(
        &self,
        harnesses: &std::collections::BTreeMap<String, HarnessProfile>,
    ) -> bool {
        let cached = self.acp_cached.lock().unwrap_or_else(PoisonError::into_inner);
        if cached.is_empty() {
            return false;
        }
        let mut served = false;
        let mut known = self.known_models.lock().unwrap_or_else(PoisonError::into_inner);
        let mut from_disk = self.acp_from_disk.lock().unwrap_or_else(PoisonError::into_inner);
        for (name, profile) in harnesses {
            if profile.kind != crate::config::HarnessKind::Acp || known.contains_key(name) {
                continue;
            }
            let Some((key, list)) = cached.get(name) else { continue };
            if *key != crate::live_models::AcpCache::profile_key(profile) {
                continue;
            }
            known.insert(name.clone(), list.clone());
            from_disk.insert(name.clone());
            served = true;
        }
        served
    }

    /// A probe of `name` under `profile` answered: its list goes to disk when the disk copy is
    /// not the same, and watchers hear `_acpmux/harnesses_changed` only when the served list
    /// `changed`, so a probe that confirms the cached list, or a repeat probe, announces nothing.
    async fn keep_probed_models(&self, name: &str, profile: &HarnessProfile, changed: bool) {
        let dir = crate::live_models::AcpCache::default_dir();
        self.keep_probed_models_in(dir, name, profile, changed).await;
    }

    pub(super) async fn keep_probed_models_in(
        &self,
        dir: std::path::PathBuf,
        name: &str,
        profile: &HarnessProfile,
        changed: bool,
    ) {
        let Some(list) =
            self.known_models.lock().unwrap_or_else(PoisonError::into_inner).get(name).cloned()
        else {
            return;
        };
        let entry = (crate::live_models::AcpCache::profile_key(profile), list);
        let on_disk = self.acp_cached.lock().unwrap_or_else(PoisonError::into_inner).get(name)
            == Some(&entry);
        if !on_disk {
            let (harness, (key, list)) = (name.to_owned(), entry.clone());
            let stored = tokio::task::spawn_blocking(move || {
                crate::live_models::AcpCache::new(dir).store(&harness, &key, &list)
            })
            .await;
            match stored {
                Ok(Ok(())) => {
                    self.acp_cached
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner)
                        .insert(name.to_owned(), entry);
                }
                Ok(Err(e)) => tracing::warn!(agent = %name, error = %e, "model list not kept"),
                Err(_) => {}
            }
        }
        if changed {
            self.announce_harnesses().await;
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
        self.acp_from_disk.lock().unwrap_or_else(PoisonError::into_inner).clear();
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
            // A list served from disk is probed again all the same (stale while revalidating).
            let from_disk = self.acp_from_disk.lock().unwrap_or_else(PoisonError::into_inner);
            cfg.harnesses
                .iter()
                .filter(|(n, p)| {
                    p.kind == crate::config::HarnessKind::Acp
                        && (force || !known.contains_key(*n) || from_disk.contains(*n))
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
            // The config read ends before the announcement, which reads it again.
            let remembered = {
                let cfg = self.config.read().await;
                (cfg.harnesses.get(name) == Some(profile)).then(|| {
                    self.remember_models_from(
                        name,
                        res.get("configOptions").filter(|v| !v.is_null()),
                        res.get("models").filter(|v| !v.is_null()),
                    )
                })
            };
            if let Some(changed) = remembered {
                self.keep_probed_models(name, profile, changed).await;
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::StoreMode;

    fn hub(argv: &[&str]) -> Arc<Hub> {
        let mut cfg: Config =
            serde_json::from_value(json!({"harnesses": {"acme": {"argv": argv}}})).unwrap();
        cfg.store.mode = StoreMode::Memory;
        let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
        Hub::new(cfg, store)
    }

    fn listed(ids: &[&str]) -> Value {
        json!({"availableModels": ids.iter().map(|id| json!({"modelId": id, "name": id.to_uppercase()})).collect::<Vec<_>>()})
    }

    async fn model_ids(hub: &Hub) -> Vec<String> {
        let catalog = hub.models_catalog().await;
        let row = catalog["harnesses"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|h| h["harness"] == "acme")
            .cloned()
            .unwrap_or_default();
        row["models"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|m| m["id"].as_str().map(str::to_owned))
            .collect()
    }

    async fn probed(hub: &Hub, dir: &std::path::Path, ids: &[&str]) -> bool {
        let profile = hub.config.read().await.harnesses["acme"].clone();
        let changed = hub.remember_models_from("acme", None, Some(&listed(ids)));
        hub.keep_probed_models_in(dir.to_path_buf(), "acme", &profile, changed).await;
        changed
    }

    /// Leo (2026-11-08): "why is there no models … we know what the models are." An ACP
    /// agent's list came only from a live probe, so a restarted daemon showed "default" until
    /// it answered. The last probed list is now served from disk at once.
    #[tokio::test]
    async fn a_restarted_daemon_serves_the_last_probed_acp_list_at_once() {
        let dir = tempfile::tempdir().unwrap();
        let first = hub(&["acme-acp"]);
        assert!(probed(&first, dir.path(), &["m-one", "m-two"]).await);

        let next = hub(&["acme-acp"]);
        assert_eq!(model_ids(&next).await, vec!["default".to_owned()]);
        next.load_acp_cache_from(dir.path().to_path_buf()).await;
        assert_eq!(model_ids(&next).await, vec!["m-one".to_owned(), "m-two".to_owned()]);
        // Served from disk, so the probe still runs for it, and its answer replaces the copy.
        assert!(next.acp_from_disk.lock().unwrap().contains("acme"));
        assert!(probed(&next, dir.path(), &["m-three"]).await);
        assert!(!next.acp_from_disk.lock().unwrap().contains("acme"));
        assert_eq!(model_ids(&next).await, vec!["m-three".to_owned()]);

        let third = hub(&["acme-acp"]);
        third.load_acp_cache_from(dir.path().to_path_buf()).await;
        assert_eq!(model_ids(&third).await, vec!["m-three".to_owned()]);
    }

    /// A list probed under another profile (another argv here) is never served.
    #[tokio::test]
    async fn a_changed_profile_gets_no_cached_list() {
        let dir = tempfile::tempdir().unwrap();
        assert!(probed(&hub(&["acme-acp"]), dir.path(), &["m-one"]).await);
        let other = hub(&["acme-acp", "--other"]);
        other.load_acp_cache_from(dir.path().to_path_buf()).await;
        assert_eq!(model_ids(&other).await, vec!["default".to_owned()]);
        assert!(other.acp_from_disk.lock().unwrap().is_empty());
    }

    /// A probe that changed the served list tells the watchers (`_acpmux/harnesses_changed`);
    /// one that confirms it (the disk copy, or the same probe again) tells nobody.
    #[tokio::test]
    async fn only_a_probe_that_changed_the_list_announces_it() {
        let dir = tempfile::tempdir().unwrap();
        let first = hub(&["acme-acp"]);
        let mut changes = first.subscribe_harness_changes();
        assert!(probed(&first, dir.path(), &["m-one"]).await);
        let note = changes.try_recv().unwrap();
        assert_eq!(note["harnesses"], json!(["acme"]), "{note}");
        assert!(!probed(&first, dir.path(), &["m-one"]).await);
        assert!(changes.try_recv().is_err());

        let next = hub(&["acme-acp"]);
        let mut changes = next.subscribe_harness_changes();
        next.load_acp_cache_from(dir.path().to_path_buf()).await;
        // The disk list served at start is announced once (below); the confirming probe is not.
        assert!(changes.try_recv().is_ok());
        assert!(!probed(&next, dir.path(), &["m-one"]).await);
        assert!(changes.try_recv().is_err());
        assert!(probed(&next, dir.path(), &["m-two"]).await);
        assert!(changes.try_recv().is_ok());
    }

    /// Review F2 on #39080: serving the disk list at start was silent, so a pane that read
    /// `_acpmux/models` before it ("default" only) heard nothing until the probe ended. A start
    /// that served some harness its disk list announces `_acpmux/harnesses_changed` once; one
    /// that served none announces nothing.
    #[tokio::test]
    async fn serving_the_disk_list_at_start_announces_it_once() {
        let dir = tempfile::tempdir().unwrap();
        assert!(probed(&hub(&["acme-acp"]), dir.path(), &["m-one"]).await);

        let next = hub(&["acme-acp"]);
        let mut changes = next.subscribe_harness_changes();
        next.load_acp_cache_from(dir.path().to_path_buf()).await;
        let note = changes.try_recv().expect("a served disk list is announced");
        assert_eq!(note["harnesses"], json!(["acme"]), "{note}");
        assert!(changes.try_recv().is_err(), "announced once");

        // Another profile is served nothing, so nothing is announced.
        let other = hub(&["acme-acp", "--other"]);
        let mut changes = other.subscribe_harness_changes();
        other.load_acp_cache_from(dir.path().to_path_buf()).await;
        assert!(changes.try_recv().is_err());
    }
}

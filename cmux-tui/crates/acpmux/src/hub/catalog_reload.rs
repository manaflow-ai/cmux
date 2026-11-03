//! Part of `Hub`; see `hub/mod.rs`. Catalog reload: config.json, the
//! harness profile files and PATH discovery read again, sessions kept.
//! Called by `_acpmux/reload_config`, `cmux harness reload` and the profile
//! watcher (`harness_watch.rs`).

use super::*;

impl Hub {
    /// Refresh the configured catalog while keeping all session processes alive.
    pub async fn reload_catalog(self: &Arc<Self>) -> Result<Value, RpcError> {
        // One reload at a time: each drops idle pooled sessions and probes the
        // model lists again, and several pages (or the profile watcher) may
        // ask at once after an install. The next waits for the one running.
        static RELOADING: std::sync::OnceLock<tokio::sync::Mutex<()>> = std::sync::OnceLock::new();
        let _one = RELOADING.get_or_init(|| tokio::sync::Mutex::new(())).lock().await;
        let (path, sources) = self.config_sources().await?;
        let peers_read = self.peer_read_gen().await;
        // Disk reads and PATH discovery run outside the async executor. An
        // invalid/missing file never replaces the last accepted configuration.
        let mut next = tokio::task::spawn_blocking(move || {
            std::fs::metadata(&path)?;
            crate::config::Config::load_from_with(&path, &sources)
        })
        .await
        .map_err(|e| RpcError::internal(e.to_string()))?
        .map_err(|e| RpcError::invalid_params(format!("reload config: {e}")))?;
        let (harnesses, default_harness, retained) = {
            let mut current = self.config.write().await;
            let mut retained = Vec::new();
            for session in self.sessions.lock().unwrap().values() {
                let name = session.meta().harness;
                if !next.harnesses.contains_key(&name)
                    && let Some(old) = current.harnesses.get(&name)
                {
                    next.harnesses.insert(name.clone(), old.clone());
                    // Do not resurrect a deleted profile in config.json on
                    // the next preset/default save.
                    next.discovered.insert(name.clone());
                    retained.push(name);
                }
            }
            // Only unchanged launchers inherit a startup validation failure.
            next.unavailable = current
                .unavailable
                .iter()
                .filter(|(n, _)| current.harnesses.get(*n) == next.harnesses.get(*n))
                .map(|(n, reason)| (n.clone(), reason.clone()))
                .collect();
            // Keep cached models until fresh probes finish, invalidating only
            // changed/removed profiles. Listeners, peers, store and policy stay put.
            self.known_models
                .lock()
                .unwrap()
                .retain(|name, _| current.harnesses.get(name) == next.harnesses.get(name));
            current.harnesses = next.harnesses;
            current.default_harness = next.default_harness;
            current.defaults = next.defaults;
            current.session = next.session;
            current.presets = next.presets;
            current.discovered = next.discovered;
            current.auto_fallback = next.auto_fallback;
            current.auto_default = next.auto_default;
            current.auto_prefer = next.auto_prefer;
            current.unavailable = next.unavailable;
            current.profile_meta = next.profile_meta;
            current.profile_diagnostics = next.profile_diagnostics;
            current.shadowed_config = next.shadowed_config;
            current.pool = next.pool;
            current.web_roots = next.web_roots;
            current.vm_host = next.vm_host;
            // The peers stay put, but a saved peer's VM boundary follows the file at once: a
            // `false` there is the caller taking it back (`vm_boundary.rs`).
            // So does whether this Mac lends it GitHub (`github_broker.rs`).
            self.reload_saved_peers(&mut current, &next.peers, peers_read);
            current.web_asking_modes = next.web_asking_modes;
            // The start budget applies from the next start, like a restart would.
            current.agent_start_timeout_ms = next.agent_start_timeout_ms;
            current.uploads_max_age_days = next.uploads_max_age_days;
            current.silent_turn_ms = next.silent_turn_ms;
            // The next prompt that would wait is held to the new queue limits.
            current.queue_max_prompts = next.queue_max_prompts;
            current.queue_max_bytes = next.queue_max_bytes;
            current.stalled_turn_ms = next.stalled_turn_ms;
            current.stalled_turn_end_ms = next.stalled_turn_end_ms;
            // The next summary read warns by the new thresholds (`usage_warnings.rs`).
            *self.usage_limits.lock().unwrap_or_else(|e| e.into_inner()) =
                next.usage_warnings.limits();
            current.usage_warnings = next.usage_warnings;
            let start_changed = current.default_permission_mode != next.default_permission_mode;
            current.default_permission_mode = next.default_permission_mode;
            if start_changed {
                self.start_mode_changed();
            }
            self.refresh_web_modes(&current);
            (
                current.harnesses.keys().cloned().collect::<Vec<_>>(),
                current.default_harness.clone(),
                retained,
            )
        };
        // A new `stalledTurnEndMs` moves the stalled turns' deadlines (`stalled_turn.rs`).
        self.idle_wake.notify_one();
        // Pooled sessions started under the old catalog are never served.
        self.drain_pool();
        // Nor do live agents keep running a profile's old launch: each restarts on the new
        // one between turns (`profile_respawn.rs`).
        self.spawn_profile_respawns();
        self.probe_models_with(true, false, None).await;
        Ok(json!({"reloaded": true, "harnesses": harnesses, "defaultHarness": default_harness,
            "retainedProfiles": retained, "modelProbePending": true}))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{Config, ProfileSources, SessionResourceConfig, StoreMode};

    #[tokio::test]
    async fn reloaded_session_limits_survive_a_later_daemon_config_save() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("config.json");
        let config = Config {
            path: Some(path.clone()),
            profile_sources: ProfileSources::none(),
            ..Config::default()
        };
        config.save().unwrap();
        let mut config = config;
        config.store.mode = StoreMode::Memory;
        let store = crate::store::open(&config.store, root.path()).unwrap();
        let hub = Hub::new(config, store);
        // Reload may discover installed profiles, but this test starts none.
        *hub.probe_only.lock().unwrap() = Some(Default::default());

        for expected in [
            SessionResourceConfig {
                memory_mb: Some(6144),
                swap_mb: Some(2048),
                tasks_max: Some(8192),
                sessions_tasks_max: Some(131_072),
                cpu_class: Some(crate::cpu_class::CpuClass::Normal),
            },
            SessionResourceConfig::default(),
        ] {
            let mut changed = Config::load_from_with(&path, &ProfileSources::none()).unwrap();
            changed.session = expected.clone();
            changed.save().unwrap();

            hub.reload_catalog().await.unwrap();
            let current = hub.config.read().await;
            assert_eq!(current.session, expected);
            current.save().unwrap();
            drop(current);

            let saved: Config = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
            assert_eq!(saved.session, expected, "daemon save must retain the reloaded limits");
        }
    }

    /// Edited `usageWarnings` thresholds apply at the next reload: summaries warn by them, and a
    /// later daemon save keeps them in the file.
    #[tokio::test]
    async fn reloaded_usage_warnings_apply_and_survive_a_later_daemon_config_save() {
        use crate::config::{UsageLimits, UsageWarningsConfig};
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("config.json");
        let config = Config {
            path: Some(path.clone()),
            profile_sources: ProfileSources::none(),
            ..Config::default()
        };
        config.save().unwrap();
        let mut config = config;
        config.store.mode = StoreMode::Memory;
        let store = crate::store::open(&config.store, root.path()).unwrap();
        let hub = Hub::new(config, store);
        *hub.probe_only.lock().unwrap() = Some(Default::default());
        assert_eq!(*hub.usage_limits.lock().unwrap(), UsageLimits::default());

        for expected in [
            UsageWarningsConfig {
                context_tokens: Some(1_000_000),
                subagents_per_hour: Some(0),
                autocompact_cap: Some(false),
            },
            UsageWarningsConfig::default(),
        ] {
            let mut changed = Config::load_from_with(&path, &ProfileSources::none()).unwrap();
            changed.usage_warnings = expected.clone();
            changed.save().unwrap();

            hub.reload_catalog().await.unwrap();
            assert_eq!(*hub.usage_limits.lock().unwrap(), expected.limits());
            let current = hub.config.read().await;
            assert_eq!(current.usage_warnings, expected);
            current.save().unwrap();
            drop(current);

            let saved: Config = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
            assert_eq!(
                saved.usage_warnings, expected,
                "daemon save must retain the reloaded thresholds"
            );
        }
    }
}

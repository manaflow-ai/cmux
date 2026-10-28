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
            current.stalled_turn_ms = next.stalled_turn_ms;
            current.stalled_turn_end_ms = next.stalled_turn_end_ms;
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
        self.probe_models_with(true, false, None).await;
        Ok(json!({"reloaded": true, "harnesses": harnesses, "defaultHarness": default_harness,
            "retainedProfiles": retained, "modelProbePending": true}))
    }
}

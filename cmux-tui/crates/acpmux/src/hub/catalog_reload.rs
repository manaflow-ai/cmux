//! Part of `Hub`; see `hub/mod.rs`. Catalog reload: config.json, the
//! harness profile files and PATH discovery read again, sessions kept.
//! Called by `_acpmux/reload_config`, `cmux harness reload` and the profile
//! watcher (`harness_watch.rs`).

use super::*;

impl Hub {
    /// Refresh the configured catalog while keeping all session processes alive.
    pub async fn reload_catalog(self: &Arc<Self>) -> Result<Value, RpcError> {
        let (path, sources) = self.config_sources().await?;
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
            current.web_asking_modes = next.web_asking_modes;
            self.refresh_web_modes(&current);
            (
                current.harnesses.keys().cloned().collect::<Vec<_>>(),
                current.default_harness.clone(),
                retained,
            )
        };
        // Pooled sessions started under the old catalog are never served.
        self.drain_pool();
        self.probe_models_with(true, false).await;
        Ok(json!({"reloaded": true, "harnesses": harnesses, "defaultHarness": default_harness,
            "retainedProfiles": retained, "modelProbePending": true}))
    }
}

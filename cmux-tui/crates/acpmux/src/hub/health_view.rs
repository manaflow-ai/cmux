//! Part of `Hub`; see `hub/mod.rs`. Agent CLI health (`harness_health`):
//! `_acpmux/harness/health` and the daemon's periodic check.

use super::*;

use crate::harness_health::{REFRESH_EVERY, Subject};

impl Hub {
    /// Every configured harness as the health check sees it.
    pub async fn health_subjects(&self) -> Vec<Subject> {
        let cfg = self.config.read().await;
        let probe_errors = self.probe_errors.lock().unwrap_or_else(|e| e.into_inner()).clone();
        cfg.harnesses
            .iter()
            .filter_map(|(id, p)| {
                let auth = cfg.profile_meta.get(id).and_then(|m| m.auth.as_ref());
                Some(Subject {
                    id: id.clone(),
                    program: p.argv.first()?.clone(),
                    family: crate::config::derive_family(id, p),
                    check: auth.map(|a| a.check.clone()).unwrap_or_default(),
                    env: p
                        .env
                        .iter()
                        .filter(|(_, v)| !v.contains("${"))
                        .map(|(k, v)| (k.clone(), v.clone()))
                        .collect(),
                    login: auth.and_then(|a| a.login.clone()),
                    probe_error: probe_errors.get(id).cloned(),
                })
            })
            .collect()
    }

    /// `_acpmux/harness/health {refresh?, checkLatest?, autoUpdate?}`: the last
    /// check, or a new one with `refresh` (after an update) or when none ran
    /// yet; `checkLatest` also asks every channel for its newest version again.
    /// `autoUpdate: {id, on}` turns auto-update on or off for a configured
    /// harness first (`harness_health/auto.rs`). Turning it on, `refresh` and
    /// `checkLatest` then run auto-update in the background.
    pub async fn harness_health(self: &Arc<Self>, params: &Value) -> Result<Value, RpcError> {
        let flag = |key: &str| params.get(key).and_then(Value::as_bool).unwrap_or(false);
        let check_latest = flag("checkLatest");
        let mut update = flag("refresh") || check_latest;
        if let Some(choice) = params.get("autoUpdate") {
            let id = choice.get("id").and_then(Value::as_str).unwrap_or("");
            let on = choice.get("on").and_then(Value::as_bool);
            let (Some(on), true) = (on, self.config.read().await.harnesses.contains_key(id)) else {
                return Err(RpcError::invalid_params(
                    "autoUpdate needs a configured harness id and on",
                ));
            };
            self.health.set_auto_update(id, on).map_err(RpcError::internal)?;
            update |= on;
        }
        let mut rows = self.health.rows();
        if flag("refresh") || check_latest {
            rows = self.health.check(self.health_subjects().await, check_latest).await;
        } else if rows.is_empty() {
            rows = self.health.first_check(self.health_subjects().await).await;
        }
        if update {
            let hub = self.clone();
            tokio::spawn(async move { hub.auto_update_harnesses().await });
        }
        Ok(json!({"harnesses": rows}))
    }

    /// Runs auto-update for the harnesses that want it, and checks again after any ran.
    pub async fn auto_update_harnesses(&self) -> Vec<String> {
        let ran = self.health.run_auto_updates().await;
        if !ran.is_empty() {
            self.health.check(self.health_subjects().await, false).await;
        }
        ran
    }

    /// The daemon's background harness checks.
    ///
    /// The ACP Registry (`registry.rs`): fetched once per daemon start; a copy
    /// that changes which installed agents are harnesses reloads them (and
    /// only then: a reload restarts pooled sessions).
    /// `ACPMUX_REGISTRY_FETCH=0` keeps the cached copy.
    ///
    /// Agent CLI health: checked once startup has read the login environment
    /// (call after `begin_startup`), then every `REFRESH_EVERY`.
    /// `ACPMUX_HEALTH_FETCH=0` or `ACPMUX_CATALOG_FETCH=0` keeps newest-version
    /// lookups off (the local checks still run).
    pub fn start_harness_checks(self: &Arc<Self>) {
        if !std::env::var("ACPMUX_REGISTRY_FETCH").is_ok_and(|v| v == "0") {
            let hub = self.clone();
            tokio::spawn(async move {
                let installed = || {
                    tokio::task::spawn_blocking(|| {
                        crate::registry::installed(&crate::config::home())
                    })
                };
                let before = installed().await.ok();
                match crate::registry::refresh(&crate::config::home()).await {
                    Ok(true) if installed().await.ok() != before => {
                        if let Err(e) = hub.reload_catalog().await {
                            tracing::warn!(error = %e.message, "harness reload after the ACP Registry refresh");
                        }
                    }
                    Ok(_) => {}
                    Err(e) => tracing::info!(error = %e, "ACP Registry not refreshed"),
                }
            });
        }
        let fetch_latest = !["ACPMUX_HEALTH_FETCH", "ACPMUX_CATALOG_FETCH"]
            .iter()
            .any(|key| std::env::var(key).is_ok_and(|v| v == "0"));
        self.health.attach(crate::harness_health::Settings {
            sources: fetch_latest.then(crate::harness_health::latest::Sources::public),
            cache: Some(crate::config::home().join("harness-health.json")),
            auto_update: Some(crate::config::home().join("harness-auto-update.json")),
            home: dirs::home_dir().unwrap_or_default(),
        });
        tokio::spawn(self.clone().run_health());
    }

    /// The health check: after startup, then every `REFRESH_EVERY`. Before
    /// the login environment is read, PATH may miss the harnesses.
    async fn run_health(self: Arc<Self>) {
        self.wait_startup().await;
        let mut every = tokio::time::interval(REFRESH_EVERY);
        every.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            every.tick().await;
            self.health.check(self.health_subjects().await, false).await;
            self.auto_update_harnesses().await;
        }
    }
}

//! Part of `Hub`; see `hub/mod.rs`. Agent CLI health (`harness_health`):
//! `_acpmux/harness/health` and the daemon's periodic check.

use super::*;

use crate::harness_health::{REFRESH_EVERY, Subject};
use cmux_json::JsonSet as _;

impl Hub {
    /// Every configured harness as the health check sees it.
    pub async fn health_subjects(&self) -> Vec<Subject> {
        let cfg = self.config.read().await;
        let probe_errors = self.probe_errors.lock().unwrap_or_else(|e| e.into_inner()).clone();
        cfg.harnesses
            .iter()
            .filter_map(|(id, p)| {
                let auth = cfg.profile_meta.get(id).and_then(|m| m.auth.as_ref());
                let probe_error = probe_errors.get(id).cloned();
                Subject::of(id, p, auth).map(|s| Subject { probe_error, ..s })
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
        // `rescan`: look for harnesses again (profiles and PATH) first, after an
        // install from the Harnesses page. A daemon without a config file
        // refuses the reload; the check still runs.
        if flag("rescan")
            && let Err(e) = self.reload_catalog().await
        {
            tracing::debug!("harness health rescan: {}", e.message);
        }
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
        let rows;
        if flag("refresh") || check_latest {
            // Before the login environment is read, PATH may miss harnesses
            // and a sign-in the login shell exports is not seen: a check
            // waits for startup, as the daemon's own does (`run_health`).
            self.wait_startup().await;
            rows = self.health.check(self.health_subjects().await, check_latest).await;
        } else {
            // Even a persisted health snapshot needs the current profile's login command:
            // account-home changes are not reflected in the cached row.
            self.wait_startup().await;
            rows = self.health.first_check(self.health_subjects().await).await;
        }
        if update {
            let hub = self.clone();
            tokio::spawn(async move { hub.auto_update_harnesses().await });
        }
        Ok(json!({"harnesses": rows}))
    }

    /// `_acpmux/harness/update {ids?}` (Update Everything, cx-1mbnu): checks
    /// this machine's harnesses again (newest versions as last read), runs
    /// now the updater of each named one (every outdated one without `ids`)
    /// that needs no sudo (`harness_health::auto::run_updates`), waits for
    /// them and checks again. Answers `{results: [{id, ok, version?,
    /// error?}]}`; a harness already current is `ok` without a run. The
    /// caller names only harness ids, never a command. Sessions keep their
    /// process (`restart_harnesses` moves them); pooled ones end, so new
    /// chats start the new version.
    pub async fn update_harnesses(&self, params: &Value) -> Result<Value, RpcError> {
        let ids = match params.get("ids") {
            None | Some(Value::Null) => None,
            Some(Value::Array(list)) => Some(
                list.iter()
                    .map(|v| v.as_str().map(str::to_owned))
                    .collect::<Option<std::collections::BTreeSet<String>>>()
                    .ok_or_else(|| RpcError::invalid_params("ids must be harness ids"))?,
            ),
            Some(_) => return Err(RpcError::invalid_params("ids must be harness ids")),
        };
        let check = async { self.health.check(self.health_subjects().await, false).await };
        let (rows, ran) = self.health.run_updates(check, ids.as_ref()).await;
        use crate::harness_health::auto::Requested;
        let any_ran = ran.iter().any(|(_, r)| matches!(r, Requested::Ran { .. }));
        let rows = if any_ran {
            if ran.iter().any(|(_, r)| matches!(r, Requested::Ran { ok: true, .. })) {
                self.drain_pool();
            }
            self.health.check(self.health_subjects().await, false).await
        } else {
            rows
        };
        let row = |id: &str| rows.iter().find(|r| r.id == id);
        let version = |id: &str| row(id).and_then(|r| r.version.clone());
        let results: Vec<Value> = ran
            .into_iter()
            .map(|(id, requested)| {
                let (ok, error) = match requested {
                    // An updater that exits 0 but leaves the old version on PATH (an npm
                    // prefix other than the one PATH finds) did not update it.
                    Requested::Ran { ok: true, .. } if row(&id).is_some_and(|r| r.outdated) => (
                        false,
                        Some(format!(
                            "the update ran, but {} still reports {}",
                            row(&id).map_or(id.as_str(), |r| r.program.as_str()),
                            version(&id).unwrap_or_default()
                        )),
                    ),
                    Requested::Ran { ok: true, .. } | Requested::Current => (true, None),
                    Requested::Ran { ok: false, detail } if detail.is_empty() => {
                        (false, Some("the update failed".to_owned()))
                    }
                    Requested::Ran { ok: false, detail } => (false, Some(detail)),
                    Requested::Refused(why) => (false, Some(why)),
                };
                let mut out = json!({"id": id, "ok": ok});
                if let Some(v) = version(&id) {
                    out.set("version", json!(v));
                }
                if let Some(e) = error {
                    out.set("error", json!(e));
                }
                out
            })
            .collect();
        Ok(json!({"results": results}))
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
    ///
    /// A capture fixture (`ACPMUX_HARNESS_FIXTURE`, `harness_fixture.rs`)
    /// replaces all of it: its rows are the check, and neither the registry
    /// nor a newest version is fetched, nor a copy saved.
    pub fn start_harness_checks(self: &Arc<Self>) {
        if let Some(fixture) = crate::harness_fixture::active() {
            self.health.attach(crate::harness_health::Settings {
                home: dirs::home_dir().unwrap_or_default(),
                fixture: Some(fixture.health.clone()),
                ..Default::default()
            });
            return;
        }
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
            fixture: None,
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

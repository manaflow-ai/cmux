//! Part of `Hub`; see `hub/mod.rs`. Agent CLI health (`harness_health`):
//! `_acpmux/harness/health` and the daemon's periodic check.

use super::*;

use crate::harness_health::{REFRESH_EVERY, Subject};

impl Hub {
    /// Every configured harness as the health check sees it.
    pub async fn health_subjects(&self) -> Vec<Subject> {
        let cfg = self.config.read().await;
        let probe_errors = self.probe_errors.lock().unwrap().clone();
        cfg.harnesses
            .iter()
            .filter_map(|(id, p)| {
                let auth = cfg.profile_meta.get(id).and_then(|m| m.auth.as_ref());
                Some(Subject {
                    id: id.clone(),
                    program: p.argv.first()?.clone(),
                    family: crate::config::derive_family(id, p),
                    check: auth.map(|a| a.check.clone()).unwrap_or_default(),
                    login: auth.and_then(|a| a.login.clone()),
                    probe_error: probe_errors.get(id).cloned(),
                })
            })
            .collect()
    }

    /// `_acpmux/harness/health {refresh?, checkLatest?}`: the last check, or a
    /// new one with `refresh` (after an update) or when none ran yet;
    /// `checkLatest` also asks every channel for its newest version again.
    pub async fn harness_health(&self, params: &Value) -> Value {
        let flag = |key: &str| params.get(key).and_then(Value::as_bool).unwrap_or(false);
        let check_latest = flag("checkLatest");
        let mut rows = self.health.rows();
        if rows.is_empty() || flag("refresh") || check_latest {
            rows = self.health.check(self.health_subjects().await, check_latest).await;
        }
        json!({"harnesses": rows})
    }

    /// The daemon's check: at start, then every `REFRESH_EVERY`.
    pub async fn run_health(self: Arc<Self>) {
        let mut every = tokio::time::interval(REFRESH_EVERY);
        every.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            every.tick().await;
            self.health.check(self.health_subjects().await, false).await;
        }
    }
}

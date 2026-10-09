//! Part of `Hub`; see `hub/mod.rs`. Live model lists from Claude Code's and
//! Codex's own CLIs (`crate::live_models`): which harnesses get one, the
//! cached lists served at startup, and the probes, all at once.
//!
//! Stale while revalidating: a cached list (its program unchanged) is served
//! from the first `_acpmux/models` on; every probe runs in the background and
//! replaces it. A list that changed is kept on disk and announced to
//! `_acpmux/watch` connections as `_acpmux/harnesses_changed`. Nothing waits
//! on a probe except `_acpmux/models {refresh: true}`.

use super::Hub;
use crate::config::{HarnessKind, HarnessProfile};
use crate::live_models::{Cache, CacheKey, Cli, LiveModel, PROBE_TIMEOUT};
use serde_json::json;
use std::collections::BTreeMap;
use std::sync::{Arc, PoisonError};

/// One live probe: the harness it fills, the CLI, and how to start it.
struct Target {
    harness: String,
    cli: Cli,
    argv: Vec<String>,
    env: BTreeMap<String, String>,
}

/// The harnesses with a live list: every Claude Code (stdio) profile, through
/// its own argv, and every Codex-family ACP profile, through the real `codex`
/// (the adapter's `CODEX_PATH`, else `codex` on the login PATH).
fn targets(harnesses: &BTreeMap<String, HarnessProfile>) -> Vec<Target> {
    let codex = || crate::config::which("codex");
    harnesses
        .iter()
        .filter_map(|(name, profile)| {
            let (cli, argv) = match profile.kind {
                HarnessKind::ClaudeStdio if !profile.argv.is_empty() => {
                    (Cli::Claude, profile.argv.clone())
                }
                HarnessKind::Acp if crate::config::derive_family(name, profile) == "codex" => {
                    let bin = profile.env.get("CODEX_PATH").cloned().or_else(codex)?;
                    (Cli::Codex, vec![bin])
                }
                _ => return None,
            };
            Some(Target { harness: name.clone(), cli, argv, env: profile.env.clone() })
        })
        .collect()
}

impl Hub {
    /// The live list for `harness`, when one arrived or was cached.
    pub(super) fn live_models_for(&self, harness: &str) -> Option<Vec<LiveModel>> {
        self.live_models.lock().unwrap_or_else(PoisonError::into_inner).get(harness).cloned()
    }

    /// Serves the cached lists whose programs are unchanged. Daemon start,
    /// before the login environment and the probes.
    pub(super) async fn load_live_cache(&self) {
        let cached = tokio::task::spawn_blocking(|| Cache::new(Cache::default_dir()).load_all())
            .await
            .unwrap_or_default();
        let mut live = self.live_models.lock().unwrap_or_else(PoisonError::into_inner);
        for (harness, models) in cached {
            live.entry(harness).or_insert(models);
        }
    }

    /// Probes every live-list harness at once; with `wait`, returns when all
    /// have answered or timed out. Runs beside the ACP probes.
    pub(super) async fn probe_live_models(self: &Arc<Self>, wait: bool) {
        let handles: Vec<_> = {
            let cfg = self.config.read().await;
            targets(&cfg.harnesses)
        }
        .into_iter()
        .map(|target| {
            let hub = self.clone();
            tokio::spawn(async move { hub.probe_live(target).await })
        })
        .collect();
        if wait {
            for handle in handles {
                let _ = handle.await;
            }
        }
    }

    async fn probe_live(self: &Arc<Self>, target: Target) {
        // The CLIs need the login environment (PATH, API keys).
        self.wait_startup().await;
        let program = target.argv.first().map(std::path::PathBuf::from);
        let cwd = dirs::home_dir().unwrap_or_else(|| std::path::PathBuf::from("/"));
        let started = std::time::Instant::now();
        let listed =
            crate::live_models::probe(target.cli, &target.argv, &target.env, &cwd, PROBE_TIMEOUT)
                .await;
        let harness = target.harness;
        let models = match listed {
            Ok(models) => models,
            Err(e) => {
                tracing::warn!(agent = %harness, error = %format!("{e:#}"), "live model list failed");
                // A cached or reported list stays; the reason shows beside it.
                self.probe_errors
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .insert(harness, format!("{e:#}"));
                return;
            }
        };
        tracing::info!(agent = %harness, models = models.len(), ms = started.elapsed().as_millis() as u64, "live model list");
        self.probe_errors.lock().unwrap_or_else(PoisonError::into_inner).remove(&harness);
        if let Some(key) = program.as_deref().and_then(CacheKey::of) {
            let (name, list) = (harness.clone(), models.clone());
            let _ = tokio::task::spawn_blocking(move || {
                Cache::new(Cache::default_dir()).store(&name, &key, &list)
            })
            .await;
        }
        let changed = self
            .live_models
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(harness, models.clone())
            .is_none_or(|old| old != models);
        if changed {
            self.announce_harnesses().await;
        }
    }

    /// `_acpmux/harnesses_changed` with the current harness names: a model
    /// list changed, so watchers read `_acpmux/models` again.
    async fn announce_harnesses(&self) {
        let cfg = self.config.read().await;
        let names: Vec<&String> = cfg.harnesses.keys().collect();
        self.send_harness_change(
            json!({"harnesses": names, "diagnostics": cfg.profile_diagnostics}),
        );
    }
}

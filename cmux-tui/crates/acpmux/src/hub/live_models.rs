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
use crate::supervised::{Fatal, ShutdownBehavior};
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
    /// Limits the model probes to `names` (None: every harness), so a
    /// client that uses a few harnesses (the Chief) never starts the others'
    /// agents at daemon start. Set before `begin_startup`.
    pub fn set_probe_only(&self, names: Option<std::collections::BTreeSet<String>>) {
        *self.probe_only.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = names;
    }

    /// A client now uses `names` too (the Chief's engine set): they join the
    /// probe list and are probed now, in the background, so their model
    /// lists arrive without a daemon restart.
    pub async fn allow_probes(self: &Arc<Self>, names: std::collections::BTreeSet<String>) {
        if let Some(list) =
            self.probe_only.lock().unwrap_or_else(std::sync::PoisonError::into_inner).as_mut()
        {
            list.extend(names.iter().cloned());
        }
        let hub = self.clone();
        self.supervise("hub.model-probes", Fatal, ShutdownBehavior::Skip, async move {
            hub.probe_models_with(false, false, Some(names)).await
        });
    }

    /// Whether the model probes may start harness `name`.
    pub(super) fn probes(&self, name: &str) -> bool {
        self.probe_only
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
            .is_none_or(|names| names.contains(name))
    }

    /// `ACPMUX_PROBE_HARNESSES`: comma-separated harness names; unset, every harness.
    pub fn probe_only_from_env(value: Option<&str>) -> Option<std::collections::BTreeSet<String>> {
        value.map(|v| {
            v.split(',').map(str::trim).filter(|n| !n.is_empty()).map(str::to_owned).collect()
        })
    }

    /// The live list for `harness`, when one arrived or was cached.
    pub(super) fn live_models_for(&self, harness: &str) -> Option<Vec<LiveModel>> {
        self.live_models.lock().unwrap_or_else(PoisonError::into_inner).get(harness).cloned()
    }

    /// Serves the cached lists whose programs are unchanged: at daemon start,
    /// before the login environment and the probes, and after memory
    /// pressure emptied them (`memory_consumers.rs`). Whether it added a list.
    pub(super) async fn load_live_cache(&self) -> bool {
        let cached = crate::daemon::spawn_blocking(|| Cache::new(Cache::default_dir()).load_all())
            .await
            .unwrap_or_default();
        self.add_live_lists(cached)
    }

    /// Adds each list for a harness that has none; whether it added one.
    pub(super) fn add_live_lists(&self, lists: BTreeMap<String, Vec<LiveModel>>) -> bool {
        let mut live = self.live_models.lock().unwrap_or_else(PoisonError::into_inner);
        let mut added = false;
        for (harness, models) in lists {
            if let std::collections::hash_map::Entry::Vacant(slot) = live.entry(harness) {
                slot.insert(models);
                added = true;
            }
        }
        added
    }

    /// Probes every live-list harness at once; with `wait`, returns when all
    /// have answered or timed out. Runs beside the ACP probes.
    pub(super) async fn probe_live_models(
        self: &Arc<Self>,
        wait: bool,
        only: Option<std::collections::BTreeSet<String>>,
    ) {
        // A live list starts the CLI with its credentials: none while
        // launches are off (cx-9ettq).
        if crate::launch_policy::agent_launch_disabled() {
            tracing::info!("agent launch is disabled; live model probes skipped");
            return;
        }
        let handles: Vec<_> = {
            let cfg = self.config.read().await;
            targets(&cfg.harnesses)
        }
        .into_iter()
        .filter(|target| self.probes(&target.harness))
        .filter(|target| only.as_ref().is_none_or(|o| o.contains(&target.harness)))
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
        // Never the home folder: the agent scans its folder at start (LAUNCH-NO-TCC-PROMPTS).
        let cwd = crate::daemon::spawn_blocking(crate::protected_folders::unattended_cwd)
            .await
            .unwrap_or_else(|_| std::env::temp_dir());
        let started = std::time::Instant::now();
        let listed =
            crate::live_models::probe(target.cli, &target.argv, &target.env, &cwd, PROBE_TIMEOUT)
                .await;
        // A list call that started a session leaves no transcript behind.
        let folder = cwd.clone();
        let _ = crate::daemon::spawn_blocking(move || {
            crate::probe_cleanup::remove_probe_transcripts(&folder)
        })
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
            let _ = crate::daemon::spawn_blocking(move || {
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
    pub(super) async fn announce_harnesses(&self) {
        let cfg = self.config.read().await;
        let names: Vec<&String> = cfg.harnesses.keys().collect();
        self.send_harness_change(
            json!({"harnesses": names, "diagnostics": cfg.profile_diagnostics}),
        );
    }
}

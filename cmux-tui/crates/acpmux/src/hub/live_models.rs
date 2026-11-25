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
    let codex = crate::managed_codex::codex_binary;
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

/// Folds `target` into `groups`: a harness whose CLI, argv and env equal an earlier target's
/// rides on that probe (`also`) instead of starting its own. The `codex`, `codex-acp` and
/// `codex-app-server` profiles all list through the same `codex app-server`; each started one
/// at every daemon start (bench gap 7 of cmuxterm-hq#25113).
fn same_cli_once(
    mut groups: Vec<(Target, Vec<String>)>,
    target: Target,
) -> Vec<(Target, Vec<String>)> {
    match groups
        .iter_mut()
        .find(|(t, _)| t.cli == target.cli && t.argv == target.argv && t.env == target.env)
    {
        Some((_, also)) => also.push(target.harness),
        None => groups.push((target, Vec::new())),
    }
    groups
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
        tokio::spawn(async move { hub.probe_models_with(false, false, Some(names)).await });
    }

    /// Whether the model probes may start harness `name`: never a capture
    /// fixture's (`harness_fixture.rs`), which names no installed program.
    pub(super) fn probes(&self, name: &str) -> bool {
        !crate::harness_fixture::active().is_some_and(|fixture| fixture.names(name))
            && self
                .probe_only
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

    /// A Codex chat of `harness` reported its model choices (`listed`, from the Codex that runs
    /// it). When they name a model its live list lacks, Codex changed under an unchanged
    /// program: an update behind a launcher or wrapper script (npm's `codex.js`, whose size and
    /// mtime stay the same, or a `cmux-codex` that execs the real binary), which keeps the cache
    /// key, or a new server catalog. The list is probed again in the background, so a stale
    /// list (GPT-6.1 Sol under Legacy beside GPT-5.6 as current, #38044) lasts until the next
    /// Codex chat starts, not until the daemon restarts. Each missing id causes one probe at
    /// most: the bridge also lists a session's own model when `model/list` hides it, which no
    /// probe will ever add. Claude Code's chats report a fixed list, so only Codex rechecks.
    pub(super) fn recheck_live_models(&self, harness: &str, listed: &[(String, String)]) {
        let Some(live) = self.live_models_for(harness) else { return };
        let missing: Vec<String> = listed
            .iter()
            .map(|(id, _)| id)
            .filter(|id| !id.is_empty() && *id != "default" && !live.iter().any(|m| &m.id == *id))
            .cloned()
            .collect();
        if missing.is_empty() {
            return;
        }
        // Only a Codex-family ACP profile has a Codex live list (`targets`). A config being
        // written now is skipped; the next report rechecks.
        let codex = self.config.try_read().is_ok_and(|cfg| {
            cfg.harnesses.get(harness).is_some_and(|profile| {
                profile.kind == HarnessKind::Acp
                    && crate::config::derive_family(harness, profile) == "codex"
            })
        });
        if !codex {
            return;
        }
        {
            let mut seen = self.live_rechecks.lock().unwrap_or_else(PoisonError::into_inner);
            let probed = seen.entry(harness.to_owned()).or_default();
            if missing.iter().all(|id| probed.contains(id)) {
                return;
            }
            probed.extend(missing);
        }
        let (Some(hub), Ok(runtime)) = (
            self.hub_ref.get().and_then(std::sync::Weak::upgrade),
            tokio::runtime::Handle::try_current(),
        ) else {
            return;
        };
        tracing::info!(agent = %harness, "a Codex chat lists models the live list lacks; probing again");
        let name = harness.to_owned();
        runtime.spawn(async move {
            let before = hub.live_models_for(&name);
            let only = std::collections::BTreeSet::from([name.clone()]);
            hub.probe_live_models(true, Some(only)).await;
            let after = hub.live_models_for(&name);
            // Codex changed: pooled sessions still run the Codex that was there before (a
            // spare outlives an update), so none of them is served (as on a config reload).
            if after.is_some() && after != before {
                hub.drain_pool();
            }
        });
    }

    /// The live-list harnesses whose last probe started `LIVE_MAX_AGE` or more
    /// before `now`, claimed so concurrent reads start one probe each.
    pub(super) async fn stale_live_probes(
        &self,
        now: std::time::Instant,
    ) -> std::collections::BTreeSet<String> {
        let names: Vec<String> = {
            let cfg = self.config.read().await;
            targets(&cfg.harnesses).into_iter().map(|target| target.harness).collect()
        };
        let names = names.iter().filter(|name| self.probes(name)).map(String::as_str);
        self.live_ages.lock().unwrap_or_else(PoisonError::into_inner).claim_due(names, now)
    }

    /// Stale while revalidating, by age: a read of `_acpmux/models` probes each
    /// live list `LIVE_MAX_AGE` old again in the background. A model the CLI
    /// learned since (a new release on the account or the gateway) reaches
    /// open pickers through `_acpmux/harnesses_changed`, with no daemon restart.
    pub(crate) async fn revalidate_live_models(self: &Arc<Self>) {
        self.revalidate_acp_models().await;
        let due = self.stale_live_probes(std::time::Instant::now()).await;
        if due.is_empty() {
            return;
        }
        tracing::info!(agents = ?due, "live model lists are old; probing again");
        let hub = self.clone();
        tokio::spawn(async move { hub.probe_live_models(false, Some(due)).await });
    }

    /// Serves the cached lists whose programs are unchanged. Daemon start,
    /// before the login environment and the probes.
    pub(super) async fn load_live_cache(&self) {
        // A capture fixture's harnesses show no list of this host's (`harness_fixture.rs`).
        if crate::harness_fixture::active().is_some() {
            return;
        }
        self.load_live_cache_from(Cache::default_dir()).await;
    }

    /// Each kept list counts as probed when its file was written (`live_ages`), and its program
    /// is noted (`live_disk_keys`): the start probes none whose program is unchanged, and a
    /// models read probes it once it is `LIVE_MAX_AGE` old.
    pub(super) async fn load_live_cache_from(&self, dir: std::path::PathBuf) {
        let cached = tokio::task::spawn_blocking(move || {
            let cache = Cache::new(dir);
            cache
                .load_all()
                .into_iter()
                .map(|(harness, models)| {
                    let (key, at) = (cache.key_of(&harness), cache.stored_at(&harness));
                    (harness, (models, key, at))
                })
                .collect::<Vec<_>>()
        })
        .await
        .unwrap_or_default();
        let (now_s, now_i) = (std::time::SystemTime::now(), std::time::Instant::now());
        let mut live = self.live_models.lock().unwrap_or_else(PoisonError::into_inner);
        let mut keys = self.live_disk_keys.lock().unwrap_or_else(PoisonError::into_inner);
        let mut ages = self.live_ages.lock().unwrap_or_else(PoisonError::into_inner);
        for (harness, (models, key, at)) in cached {
            if let (Some(key), Some(at)) =
                (key, at.and_then(|at| super::live_ages::instant_of(at, now_s, now_i)))
            {
                keys.insert(harness.clone(), key);
                ages.started(&harness, at);
            }
            live.entry(harness).or_insert(models);
        }
    }

    /// The live-list harnesses (of `only`, when set) the start must probe: those with no kept
    /// list, or one another program listed. Every daemon start probed every one before, three
    /// `codex app-server`s and two `claude`s on a machine with a few profiles of each.
    pub(super) async fn live_probes_at_start(
        &self,
        only: Option<&std::collections::BTreeSet<String>>,
    ) -> std::collections::BTreeSet<String> {
        let targets = {
            let cfg = self.config.read().await;
            targets(&cfg.harnesses)
        };
        let keys = self.live_disk_keys.lock().unwrap_or_else(PoisonError::into_inner).clone();
        targets
            .into_iter()
            .filter(|t| only.is_none_or(|o| o.contains(&t.harness)))
            .filter(|t| {
                let kept = keys.get(&t.harness);
                let now = t.argv.first().and_then(|p| CacheKey::of(std::path::Path::new(p)));
                kept.is_none() || kept != now.as_ref()
            })
            .map(|t| t.harness)
            .collect()
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
        // Nor for a capture fixture (`harness_fixture.rs`): its harnesses run nothing,
        // and finding the CLIs would read this host's PATH.
        if crate::harness_fixture::active().is_some() {
            return;
        }
        let handles: Vec<_> = {
            let cfg = self.config.read().await;
            targets(&cfg.harnesses)
        }
        .into_iter()
        .filter(|target| self.probes(&target.harness))
        .filter(|target| only.as_ref().is_none_or(|o| o.contains(&target.harness)))
        .fold(Vec::<(Target, Vec<String>)>::new(), same_cli_once)
        .into_iter()
        .map(|(target, also)| {
            let hub = self.clone();
            tokio::spawn(async move { hub.probe_live(target, also).await })
        })
        .collect();
        if wait {
            for handle in handles {
                let _ = handle.await;
            }
        }
    }

    /// Lists `target`'s models and serves them for it and for `also`, the harnesses that run
    /// the same CLI the same way (`same_cli_once`).
    async fn probe_live(self: &Arc<Self>, target: Target, also: Vec<String>) {
        // MDM's off as the list starts: its one read, taken first (review 120 of #23322).
        let latch = self.off_latch();
        // The CLIs need the login environment (PATH, API keys).
        self.wait_startup().await;
        let program = target.argv.first().map(std::path::PathBuf::from);
        {
            let mut ages = self.live_ages.lock().unwrap_or_else(PoisonError::into_inner);
            for name in std::iter::once(&target.harness).chain(&also) {
                ages.started(name, std::time::Instant::now());
            }
        }
        // Never the home folder: the agent scans its folder at start (LAUNCH-NO-TCC-PROMPTS).
        let cwd = tokio::task::spawn_blocking(crate::protected_folders::unattended_cwd)
            .await
            .unwrap_or_else(|_| std::env::temp_dir());
        let started = std::time::Instant::now();
        // MDM forces full access off (#23322): a profile pinning it is never started to list its
        // models, and a list that runs when the off lands ends then (`probe_bound`).
        let listed = match self.probe_bound(&latch, &target.argv) {
            Err(e) => Err(e),
            Ok(mut bound) => {
                let probe = crate::live_models::probe(
                    target.cli,
                    &target.argv,
                    &target.env,
                    &cwd,
                    PROBE_TIMEOUT,
                );
                tokio::select! {
                    listed = probe => listed,
                    () = super::full_access_bound::full_access_forced_off(bound.as_mut()) => {
                        Err(anyhow::anyhow!("MDM forced full access off, which its profile pins"))
                    }
                }
            }
        };
        // A list call that started a session leaves no transcript behind.
        let folder = cwd.clone();
        let _ = tokio::task::spawn_blocking(move || {
            crate::probe_cleanup::remove_probe_transcripts(&folder)
        })
        .await;
        let names: Vec<String> = std::iter::once(target.harness).chain(also).collect();
        let models = match listed {
            Ok(models) => models,
            Err(e) => {
                tracing::warn!(agents = ?names, error = %format!("{e:#}"), "live model list failed");
                // A cached or reported list stays; the reason shows beside it.
                let mut errors = self.probe_errors.lock().unwrap_or_else(PoisonError::into_inner);
                for name in names {
                    errors.insert(name, format!("{e:#}"));
                }
                return;
            }
        };
        tracing::info!(agents = ?names, models = models.len(), ms = u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX), "live model list");
        let key = program.as_deref().and_then(CacheKey::of);
        let mut changed = false;
        for harness in names {
            self.probe_errors.lock().unwrap_or_else(PoisonError::into_inner).remove(&harness);
            if let Some(key) = key.clone() {
                let (name, list) = (harness.clone(), models.clone());
                let _ = tokio::task::spawn_blocking(move || {
                    Cache::new(Cache::default_dir()).store(&name, &key, &list)
                })
                .await;
            }
            changed |= self
                .live_models
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .insert(harness, models.clone())
                .is_none_or(|old| old != models);
        }
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

#[cfg(test)]
#[path = "live_models_tests.rs"]
mod tests;

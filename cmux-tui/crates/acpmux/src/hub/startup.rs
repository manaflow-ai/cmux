//! The hub's startup: hold spawns until the login environment and the
//! catalog are ready, check launchers, then let agents start (moved from
//! `hub/mod.rs` unchanged).

use super::Hub;
use crate::config::Config;
use std::sync::Arc;
use std::sync::atomic::Ordering;

impl Hub {
    /// Hold session creation and agent spawns until `finish_startup`.
    pub fn begin_startup(&self, login_env: bool) {
        self.login_env_requested.store(login_env, Ordering::SeqCst);
        self.startup_ready.send_replace(false);
        self.catalog_ready.send_replace(false);
    }

    /// Background startup: import the login environment (when requested),
    /// reload the catalog so PATH discovery sees it, check launchers, then
    /// let spawns through and probe models.
    pub async fn finish_startup(self: &Arc<Self>) {
        // deny-all as the default policy in config.json, a lockdown (`policy_mode.rs`): every chat
        // without a policy of its own follows it. A stopped chat's saved mode is written now; an
        // adopted agent is reached once startup is done (`child_for` waits for it).
        if self.config.read().await.permission_policy == crate::config::PermissionPolicy::DenyAll {
            let hub = self.clone();
            tokio::spawn(async move { hub.follow_default_policy().await });
        }
        // Prompts queued under the previous daemon, after any adopted turn (`queue.rs`).
        self.resume_queues();
        // The last live model lists, before anything slow.
        self.load_live_cache().await;
        let login_env = self.login_env_requested.load(Ordering::SeqCst);
        let mut reloaded = false;
        if login_env {
            // A cache whose fingerprint matches applies at once; the shell
            // runs only when needed, and agent spawns wait for it (at most
            // two `login_env::TIMEOUT` reads) only when nothing else can stand in.
            let plan = tokio::task::spawn_blocking(crate::login_env::begin)
                .await
                .unwrap_or(crate::login_env::Plan { run_shell: true, wait: true });
            // An edit to a startup file reads the shell again (D26).
            crate::login_env::watch_startup_files();
            let cached = crate::login_env::outcome() == crate::login_env::Outcome::Cached;
            if cached {
                reloaded = self.after_login_env().await;
            }
            if plan.run_shell && plan.wait {
                if crate::login_env::import().await {
                    reloaded = self.after_login_env().await || reloaded;
                }
            } else if plan.run_shell {
                let hub = self.clone();
                tokio::spawn(async move {
                    if crate::login_env::import().await {
                        hub.after_login_env().await;
                    }
                });
            }
        }
        self.catalog_ready.send_replace(true);
        self.verify_launchers().await;
        self.startup_ready.send_replace(true);
        self.care_worker();
        tracing::info!("startup complete; agents may spawn");
        // Probes and one-shots of earlier runs left files behind: remove them.
        let _ = tokio::task::spawn_blocking(|| {
            crate::qos::background(crate::probe_cleanup::at_daemon_start)
        })
        .await;
        // A catalog reload already started fresh probes.
        if !reloaded {
            self.probe_models().await;
        }
    }

    /// The login environment changed: `CLAUDE_CONFIG_DIR` / `CODEX_HOME`
    /// and harnesses on the login PATH may come from it only. Watchers hear
    /// the new catalog, so a client that listed the old one catches up.
    async fn after_login_env(self: &Arc<Self>) -> bool {
        self.set_harness_homes(crate::adopt::HarnessHomes::from_env());
        self.reload_and_announce().await
    }

    pub fn startup_complete(&self) -> bool {
        *self.startup_ready.borrow()
    }

    /// Whether the chat logs are read (`load_logs`; always outside a deferred start).
    pub fn logs_loaded(&self) -> bool {
        *self.logs_ready.borrow()
    }

    /// Wait until background startup has finished (immediate outside a daemon).
    pub(crate) async fn wait_startup(&self) {
        let mut rx = self.startup_ready.subscribe();
        let _ = rx.wait_for(|ready| *ready).await;
    }

    /// Run `--version` on proxy launchers off the executor and mark the ones
    /// that fail unavailable (and drop fallbacks that point at them).
    async fn verify_launchers(&self) {
        let mut probe = self.config.read().await.clone();
        let before = probe.harnesses.clone();
        let Ok(probe) = tokio::task::spawn_blocking(move || {
            crate::config::verify_launchers(&mut probe);
            probe
        })
        .await
        else {
            return;
        };
        let mut cfg = self.config.write().await;
        // Launchers the probe rerouted (claude-sr through the subrouter server), unless a
        // reload changed them meanwhile.
        for (name, routed) in &probe.harnesses {
            let unchanged =
                cfg.harnesses.get(name).map(|p| &p.argv) == before.get(name).map(|p| &p.argv);
            if unchanged
                && before.get(name).map(|p| &p.argv) != Some(&routed.argv)
                && before.contains_key(name)
            {
                cfg.harnesses.insert(name.clone(), routed.clone());
            }
        }
        for (name, reason) in &probe.unavailable {
            let argv = |c: &Config| c.harnesses.get(name).map(|p| p.argv.clone());
            if argv(&cfg) != argv(&probe) || cfg.unavailable.contains_key(name) {
                continue;
            }
            for p in cfg.harnesses.values_mut() {
                if p.fallback.as_deref() == Some(name.as_str()) {
                    p.fallback = None;
                }
            }
            cfg.unavailable.insert(name.clone(), reason.clone());
        }
    }
}

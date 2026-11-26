//! Part of `Hub`; see `hub/mod.rs`. A harness resolved when a new session starts, not frozen when
//! the daemon started: a session start whose head names a harness this catalog lacks, but that
//! PATH discovery adds once its program is installed (`claude`, `codex`, ...), reads the login
//! PATH again when it was never imported and reloads the catalog (sessions kept), then resolves.
//!
//! hq#12175: a Cloud machine's daemon started before Claude was on its PATH (the image's store
//! bin is on PATH only through a login profile, and the 3 s login shell read can fail), so its
//! catalog had no `claude` and every `ensure -m claude` was refused in 13 ms for the life of the
//! daemon although Claude was installed. Warm spares and the login spare start early, so a start
//! order can no longer decide which harnesses a chat may use.

use super::*;

/// Login shell reads asked for by a start (`refresh_login_path`) at most this often: a host whose
/// shell never answers does not run one for every start.
const LOGIN_RETRY: std::time::Duration = std::time::Duration::from_secs(30);

impl Hub {
    /// Before a new session resolves `harness`/`preset` (`resolve_new`): when its head names a
    /// harness this catalog lacks and discovery could add, read the login PATH again if it was
    /// never imported, and reload the catalog when discovery now finds it. Once per call, never
    /// in a loop; free when the head resolves, and a name discovery never adds (a typo, a
    /// profile this host was never given) keeps its refusal at once.
    pub(super) async fn rediscover_head(&self, harness: Option<&str>, preset: Option<&str>) {
        if crate::harness_fixture::active().is_some() {
            return;
        }
        let missing = |cfg: &Config| {
            let head = harness
                .map(str::to_owned)
                .or_else(|| preset.and_then(|p| cfg.presets.get(p)).map(|p| p.harness.clone()))
                .or_else(|| cfg.default_harness.clone())?;
            (cfg.resolve_harness(&head).is_err() && crate::config::discoverable(&head))
                .then_some(head)
        };
        let Some(head) = missing(&*self.config.read().await) else { return };
        let Some(hub) = self.hub_ref.get().and_then(std::sync::Weak::upgrade) else { return };
        self.refresh_login_path().await;
        // Discovery alone first: a reload drops the warm pool and probes every model list again,
        // so it runs only when it serves this head (a pool refill asking for a CLI that is not
        // installed reloads nothing).
        let probe = self.config.read().await.clone();
        let found = tokio::task::spawn_blocking(move || {
            let mut probe = probe;
            probe.join_discovered(crate::config::discover_harnesses());
            probe
        })
        .await;
        let Ok(probe) = found else { return };
        if probe.resolve_harness(&head).is_err() {
            return;
        }
        // Another start may have reloaded meanwhile.
        if missing(&*self.config.read().await).is_none() {
            return;
        }
        tracing::info!(
            harness = %head,
            "a start names a harness installed since the catalog loaded; reloading it"
        );
        hub.reload_and_announce().await;
    }

    /// The login environment read once more when it never was (its read failed or has not run),
    /// at most every `LOGIN_RETRY`: its PATH is where a profile puts a CLI the daemon's own PATH
    /// lacks. Bounded by the read's own limit (`login_env::import`).
    async fn refresh_login_path(&self) {
        static LAST: std::sync::Mutex<Option<std::time::Instant>> = std::sync::Mutex::new(None);
        if !self.login_env_requested.load(std::sync::atomic::Ordering::SeqCst)
            || matches!(
                crate::login_env::outcome(),
                crate::login_env::Outcome::Cached | crate::login_env::Outcome::Shell
            )
        {
            return;
        }
        {
            let mut last = LAST.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            if last.is_some_and(|t| t.elapsed() < LOGIN_RETRY) {
                return;
            }
            *last = Some(std::time::Instant::now());
        }
        crate::login_env::import().await;
    }

    /// Why a harness discovery could add may still be missing, for its refusal: the login PATH,
    /// where a profile puts an agent CLI, was not read. None when it was.
    pub(super) fn login_path_note(&self) -> Option<String> {
        if !self.login_env_requested.load(std::sync::atomic::Ordering::SeqCst) {
            return Some(
                "the login shell PATH was not imported: this daemon does not read it \
                 (ACPMUX_LOGIN_ENV=0, or not started as the daemon)"
                    .into(),
            );
        }
        match crate::login_env::outcome() {
            crate::login_env::Outcome::Failed => Some(
                "the login shell PATH was not imported: the login shell did not answer in time"
                    .into(),
            ),
            crate::login_env::Outcome::None => {
                Some("the login shell PATH was not imported: its read has not finished".into())
            }
            crate::login_env::Outcome::Cached | crate::login_env::Outcome::Shell => None,
        }
    }
}

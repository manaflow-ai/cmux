//! Part of `Hub`; see `hub/mod.rs`. A live agent whose harness profile's launch (its argv and
//! env, `HarnessProfile::launch_digest`) changed since it started restarts on the new profile
//! and resumes the same conversation (`claude --resume`, ACP `session/load`), the way an update's
//! restart does (`route_switch.rs` `restart_harnesses`): between turns now, in a turn when the
//! turn ends, never cancelled. Checked when the catalog reloads (a profile file changed,
//! `cmux harness reload`, `_acpmux/reload_config`) and once the daemon has adopted the agents
//! the previous one left, by the digest each session keeps on disk (`SessionMeta::launch_digest`).
//! Until the new agent starts, lists say `respawn pending: profile changed`.
//!
//! Why (Leo, 2026-10-31, on a session at 650k of a 1M context: "why were you on high and on 1m
//! context??? i thought we fixed that???"): a session that never went idle never hibernated, so
//! it kept the argv it started with, from before its profile gained `--autocompact`.

use super::*;

use std::collections::{BTreeMap, BTreeSet};

/// What `respawnPending` says while a respawn waits for the turn to end.
pub(crate) const PROFILE_CHANGED: &str = "profile changed";

/// The log record a respawn's mark writes, a change every list and watcher sees.
pub(crate) const RECORD_KIND: &str = "respawn_pending";

impl Hub {
    /// Restarts every live local agent whose profile's launch differs from the one it started
    /// from. A Home Chief session, or one whose harness is no longer in the catalog, is left as it
    /// is; one with no recorded digest (started by an older build) is judged by its argv
    /// (`legacy_stale`).
    pub(crate) async fn respawn_changed_profiles(self: &Arc<Self>) -> HarnessRestarts {
        type Launch = (String, HarnessProfile, BTreeMap<String, String>);
        let profiles: BTreeMap<String, Launch> = {
            let cfg = self.config.read().await;
            cfg.harnesses
                .iter()
                .map(|(name, p)| {
                    (name.clone(), (p.launch_digest(), p.clone(), cfg.defaults_for(name).env))
                })
                .collect()
        };
        let mut stale = BTreeSet::new();
        for session in self.sessions() {
            let meta = session.meta();
            // A Home Chief session is never swept, as Update Everything never sweeps one.
            if super::route_switch::is_chief(&meta) {
                continue;
            }
            let Some((now, profile, defaults)) = profiles.get(&meta.harness) else { continue };
            let changed = match meta.launch_digest.as_deref() {
                Some(started) => started != now,
                None => self.legacy_stale(profile, &meta, defaults).await,
            };
            if !changed || session.child.lock().await.is_none() {
                continue;
            }
            tracing::info!(session = %session.id, harness = %meta.harness, "harness profile changed since its agent started: respawning it at its turn end");
            self.mark_profile_respawn(&session);
            stale.insert(session.id.clone());
        }
        if stale.is_empty() {
            return HarnessRestarts::default();
        }
        self.restart_harnesses(None, Some(&stale)).await
    }

    /// The session's agent restarts on its profile's new launch at its turn end. Lists and
    /// watchers see it (`respawnPending`, a `respawn_pending` record) until the new agent starts.
    pub(super) fn mark_profile_respawn(&self, session: &Session) {
        if !session.profile_respawn.swap(true, Ordering::SeqCst) {
            self.append(session, "mux", RECORD_KIND, json!({"reason": PROFILE_CHANGED}));
        }
    }

    /// The session's agent ended or a start runs the profile as it is now: no respawn waits.
    pub(super) fn settle_profile_respawn(&self, session: &Session) {
        if session.profile_respawn.swap(false, Ordering::SeqCst) {
            // The next list is built anew; the start's own records follow.
            session.state_seq.fetch_add(1, Ordering::SeqCst);
            self.events.changed();
        }
    }

    /// [`Self::respawn_changed_profiles`] on a task of its own: a restart between turns waits
    /// for the new agent to start, which a catalog reload's answer does not.
    pub(crate) fn spawn_profile_respawns(self: &Arc<Self>) {
        let hub = self.clone();
        tokio::spawn(async move {
            let out = hub.respawn_changed_profiles().await;
            for (session, error) in &out.failed {
                tracing::warn!(%session, %error, "profile respawn");
            }
        });
    }
}

impl Hub {
    /// A session started before agents kept their launch digest: stale when the argv its agent
    /// last started with (`spawn_argv`, kept on disk since #23322) is not, word for word, the
    /// argv a start would build now (`spawn_profile_for`: the profile expanded, the launcher
    /// resolved, then the preset's args, the system prompt file and the tools it turned off).
    /// Any word gained, lost or changed is a change; a start this daemon could not build (a
    /// route that is gone, a preset refused) is left to the next start. Only the argv is judged:
    /// such an agent's env was never kept, so an env-only change reaches it at its next start. A
    /// remote-origin session is admitted differently (`admit_remote_profile`), and a cmux-harness
    /// one would migrate its state as it is built: neither is judged.
    async fn legacy_stale(
        &self,
        profile: &HarnessProfile,
        meta: &SessionMeta,
        defaults: &BTreeMap<String, String>,
    ) -> bool {
        let Some(started) = meta.spawn_argv.as_deref() else { return false };
        if meta.remote_origin || profile.family.as_deref() == Some("cmux-harness") {
            return false;
        }
        match self.spawn_profile_for(meta, profile, defaults).await {
            Ok(now) => now.argv != started,
            Err(_) => false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hub(argv: &[&str]) -> Arc<Hub> {
        let mut config: crate::config::Config = serde_json::from_value(serde_json::json!({
            "harnesses": {"lane": {"argv": argv, "family": "claude"}},
        }))
        .unwrap();
        config.store.mode = crate::config::StoreMode::Memory;
        config.profile_sources = crate::config::ProfileSources::none();
        let store = crate::store::open(&config.store, std::path::Path::new("/unused")).unwrap();
        Hub::new(config, store)
    }

    fn meta(spawn_argv: Option<&[&str]>) -> SessionMeta {
        let mut m: SessionMeta = serde_json::from_value(serde_json::json!({
            "schema": crate::store::META_SCHEMA, "id": "s", "name": "s", "harness": "lane",
            "cwd": "/w", "status": "ready", "createdAt": 0, "updatedAt": 0,
        }))
        .unwrap();
        m.spawn_argv = spawn_argv.map(|a| a.iter().map(|w| (*w).to_owned()).collect());
        m
    }

    async fn stale(profile: &[&str], started: Option<&[&str]>) -> bool {
        let hub = hub(profile);
        let p = hub.config.read().await.harnesses["lane"].clone();
        hub.legacy_stale(&p, &meta(started), &BTreeMap::new()).await
    }

    #[tokio::test]
    async fn a_legacy_agent_is_stale_unless_its_argv_is_what_a_start_builds_now() {
        let capped = ["/u/bin/claude", "--autocompact", "402530"];
        // Started before the profile gained the flag (the 2026-10-31 session at 650k of 1M).
        assert!(stale(&capped, Some(&["/u/bin/claude"])).await);
        // Started after: the same argv.
        assert!(!stale(&capped, Some(&capped)).await);
        // A different cap, another program, a word the profile dropped at its end (review 3).
        assert!(stale(&capped, Some(&["/u/bin/claude", "--autocompact", "300000"])).await);
        assert!(stale(&capped, Some(&["/other/claude", "--autocompact", "402530"])).await);
        assert!(stale(&["/u/bin/claude"], Some(&capped)).await);
        // `${cwd}` is expanded as a start expands it.
        let at = ["/u/bin/agent", "--cwd", "${cwd}"];
        assert!(!stale(&at, Some(&["/u/bin/agent", "--cwd", "/w"])).await);
        // Nothing to judge: no recorded argv.
        assert!(!stale(&capped, None).await);
    }

    #[tokio::test]
    async fn a_remote_origin_legacy_agent_is_not_judged() {
        let hub = hub(&["/u/bin/claude", "--autocompact", "402530"]);
        let p = hub.config.read().await.harnesses["lane"].clone();
        let mut m = meta(Some(&["/u/bin/claude"]));
        m.remote_origin = true;
        assert!(!hub.legacy_stale(&p, &m, &BTreeMap::new()).await);
    }
}

//! Part of `Hub`; see `hub/mod.rs`. A live agent whose harness profile's launch (its kind, argv
//! and env, `HarnessProfile::launch_digest`) changed since it started restarts on the new profile
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

impl Hub {
    /// Restarts every live local agent whose profile's launch differs from the one it started
    /// from. A session with no recorded digest (started by an older build) or whose harness is
    /// no longer in the catalog is left as it is.
    pub(crate) async fn respawn_changed_profiles(self: &Arc<Self>) -> HarnessRestarts {
        let digests: BTreeMap<String, String> = {
            let cfg = self.config.read().await;
            cfg.harnesses.iter().map(|(name, p)| (name.clone(), p.launch_digest())).collect()
        };
        let mut stale = BTreeSet::new();
        for session in self.sessions() {
            let meta = session.meta();
            let Some(started) = meta.launch_digest.as_deref() else { continue };
            if digests.get(&meta.harness).is_none_or(|now| now == started)
                || session.child.lock().await.is_none()
            {
                continue;
            }
            tracing::info!(session = %session.id, harness = %meta.harness, "harness profile changed since its agent started: respawning it at its turn end");
            session.profile_respawn.store(true, Ordering::SeqCst);
            stale.insert(session.id.clone());
        }
        if stale.is_empty() {
            return HarnessRestarts::default();
        }
        self.restart_harnesses(None, Some(&stale)).await
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

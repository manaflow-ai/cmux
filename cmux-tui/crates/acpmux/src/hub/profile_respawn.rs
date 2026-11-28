//! Part of `Hub`; see `hub/mod.rs`. A live agent whose harness profile's launch (its argv and
//! env, `HarnessProfile::launch_digest`) changed since it started restarts on the new profile
//! and resumes the same conversation (`claude --resume`, ACP `session/load`). Every idle gate
//! and the process census must find it quiet (`idle.rs`); it then hibernates until the next
//! prompt. Never cancelled. Checked when the catalog reloads (a profile file changed,
//! `cmux harness reload`, `_acpmux/reload_config`) and once the daemon has adopted the agents
//! the previous one left, by the digest each session keeps on disk (`SessionMeta::launch_digest`).
//! Until the new agent starts, lists say `respawn pending: profile changed`.
//!
//! Why (Leo, 2026-10-31, on a session at 650k of a 1M context: "why were you on high and on 1m
//! context??? i thought we fixed that???"): a session that never went idle never hibernated, so
//! it kept the argv it started with, from before its profile gained `--autocompact`.

use super::*;

use std::collections::BTreeMap;

/// What `respawnPending` says while a respawn waits for all work to end.
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
        let mut marked = 0;
        for session in self.sessions() {
            let meta = session.meta();
            // A Home Chief session is never swept, as Update Everything never sweeps one.
            if super::route_switch::is_chief(&meta) {
                continue;
            }
            let Some((now, profile, defaults)) = profiles.get(&meta.harness) else { continue };
            // A hibernated chat starts on the profile as it is then: nothing to judge, and no
            // launch built for it.
            if session.child.lock().await.is_none() {
                continue;
            }
            if !self.launch_changed(&session, &meta, now, profile, defaults).await {
                continue;
            }
            tracing::info!(session = %session.id, harness = %meta.harness, "harness profile changed: hibernating now if quiet, otherwise waiting");
            self.mark_profile_respawn(&session);
            // A reload of an idle chat should take effect immediately. Work can start after
            // this snapshot, including an unreported child; the shared quietness/census path
            // rechecks every gate before ending it and leaves a mark when it refuses.
            if !self.end_quiet_stale(&session, "profile-changed", None).await {
                self.respawn_when_quiet(&session);
                marked += 1;
            }
        }
        HarnessRestarts { after_turn: marked, ..HarnessRestarts::default() }
    }

    /// The session's agent hibernates when quiet, then starts on its profile's new launch. Lists and
    /// watchers see it (`respawnPending`, a `respawn_pending` record) until the new agent starts.
    pub(super) fn mark_profile_respawn(&self, session: &Session) {
        if !session.profile_respawn.swap(true, Ordering::SeqCst) {
            self.append(session, "mux", RECORD_KIND, json!({"reason": PROFILE_CHANGED}));
        }
    }

    /// The session's agent ended or a start runs the profile as it is now: no respawn waits.
    pub(super) fn settle_profile_respawn(&self, session: &Session) {
        // So does a restart that waited for its agent to be quiet (`idle.rs` `quiet_respawn`).
        let quiet_was = session.respawn_when_quiet.swap(false, Ordering::SeqCst);
        session.respawn_required.store(false, Ordering::SeqCst);
        // Clear both marks independently: a quiet restart can be set alongside the profile mark,
        // and short-circuiting the second swap leaves `profile_respawn` stuck until a later spawn.
        let profile_was = session.profile_respawn.swap(false, Ordering::SeqCst);
        if quiet_was || profile_was {
            // The next list is built anew; the start's own records follow.
            session.state_seq.fetch_add(1, Ordering::SeqCst);
            self.events.row_changed(session);
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

#[cfg(test)]
thread_local! {
    /// Launches `legacy_stale` built on this thread (tests are single-threaded runtimes).
    pub(super) static LEGACY_BUILDS: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}

impl Hub {
    /// Whether the session's live agent started from a launch other than `now`, the digest of
    /// its profile as the catalog holds it. One with no recorded digest is judged by its argv
    /// (`legacy_stale`, a whole launch built); found current, it keeps `now` as its digest, so
    /// the next sweep compares two strings instead of building that launch again. Without
    /// that, every catalog reload rebuilt one launch per adopted agent (one daemon,
    /// 2026-11-28: 48 adopted chats, 1,170 builds in 3 minutes).
    async fn launch_changed(
        &self,
        session: &Session,
        meta: &SessionMeta,
        now: &str,
        profile: &HarnessProfile,
        defaults: &BTreeMap<String, String>,
    ) -> bool {
        if let Some(started) = meta.launch_digest.as_deref() {
            return started != now;
        }
        match self.legacy_stale(profile, meta, defaults).await {
            Some(true) => return true,
            // Not judged (no argv, a remote or cmux-harness chat, a launch not built now): the
            // next sweep judges it again.
            None => return false,
            Some(false) => {}
        }
        {
            let recorded = {
                let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
                let fresh = m.launch_digest.is_none() && m.spawn_argv == meta.spawn_argv;
                if fresh {
                    m.launch_digest = Some(now.to_owned());
                }
                fresh
            };
            if recorded {
                self.save_meta(session);
            }
        }
        false
    }

    /// A session started before agents kept their launch digest (`None`: not judged): stale when the argv its agent
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
    ) -> Option<bool> {
        let started = meta.spawn_argv.as_deref()?;
        if meta.remote_origin || profile.family.as_deref() == Some("cmux-harness") {
            return None;
        }
        #[cfg(test)]
        LEGACY_BUILDS.with(|n| n.set(n.get() + 1));
        match self.spawn_profile_for(meta, profile, defaults).await {
            Ok(now) => Some(now.argv != started),
            Err(_) => None,
        }
    }
}

#[cfg(test)]
#[path = "profile_respawn_tests.rs"]
mod tests;

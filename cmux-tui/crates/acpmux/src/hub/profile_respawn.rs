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
        let profiles: BTreeMap<String, (String, HarnessProfile)> = {
            let cfg = self.config.read().await;
            cfg.harnesses
                .iter()
                .map(|(name, p)| (name.clone(), (p.launch_digest(), p.clone())))
                .collect()
        };
        let mut stale = BTreeSet::new();
        for session in self.sessions() {
            let meta = session.meta();
            // A Home Chief session is never swept, as Update Everything never sweeps one.
            if super::route_switch::is_chief(&meta) {
                continue;
            }
            let Some((now, profile)) = profiles.get(&meta.harness) else { continue };
            let changed = match meta.launch_digest.as_deref() {
                Some(started) => started != now,
                None => legacy_stale(profile, &meta, |argv| self.resolved_launcher_argv(argv)),
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

/// A session started before agents kept their launch digest: stale when the argv its agent last
/// started with (`spawn_argv`, kept on disk since #23322) does not begin with the profile's argv
/// as a start builds it (`spawn_profile_read`: every word expanded, then `resolve` for a resolved
/// `npx -y PACKAGE` launcher). The preset's and acpmux's own words come after it, so an unchanged
/// profile matches, and any word gained, lost or changed (the program, the package, a flag such as
/// `--autocompact 402530`) does not. Only the argv is judged: such an agent's env was never kept,
/// so an env-only change reaches it at its next start. A remote-origin session's argv is admitted
/// differently (`admit_remote_profile`) and is not judged.
fn legacy_stale(
    profile: &HarnessProfile,
    meta: &SessionMeta,
    resolve: impl FnOnce(Vec<String>) -> Vec<String>,
) -> bool {
    let Some(started) = meta.spawn_argv.as_deref().filter(|_| !meta.remote_origin) else {
        return false;
    };
    let home = dirs::home_dir().unwrap_or_default();
    let model = meta.model_request.clone().unwrap_or_default();
    let own: Vec<String> = profile
        .argv
        .iter()
        .map(|a| super::spawn::expand_env_value(a, &meta.cwd, &home, &model))
        .collect();
    !started.starts_with(&resolve(own))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn profile(argv: &[&str]) -> HarnessProfile {
        serde_json::from_value(serde_json::json!({"argv": argv})).unwrap()
    }

    fn meta(spawn_argv: Option<&[&str]>) -> SessionMeta {
        let mut m: SessionMeta = serde_json::from_value(serde_json::json!({
            "schema": "acpmux.session.v1", "id": "s", "name": "s", "harness": "claude",
            "cwd": "/w", "status": "ready", "createdAt": 0, "updatedAt": 0,
        }))
        .unwrap();
        m.spawn_argv = spawn_argv.map(|a| a.iter().map(|w| (*w).to_owned()).collect());
        m
    }

    fn same(argv: Vec<String>) -> Vec<String> {
        argv
    }

    #[test]
    fn a_legacy_agent_is_stale_unless_its_argv_begins_with_the_profiles() {
        let capped = profile(&["/u/bin/claude", "--autocompact", "402530"]);
        // Started before the profile gained the flag (the 2026-10-31 session at 650k of 1M).
        let old = meta(Some(&["/u/bin/claude", "--disallowedTools", "mcp__x"]));
        assert!(legacy_stale(&capped, &old, same));
        // Started after: the preset's and acpmux's words follow the profile's own.
        let new =
            meta(Some(&["/u/bin/claude", "--autocompact", "402530", "--disallowedTools", "x"]));
        assert!(!legacy_stale(&capped, &new, same));
        // A different cap, another program, or a word the profile lost: each is a change.
        let other_cap = meta(Some(&["/u/bin/claude", "--autocompact", "300000"]));
        assert!(legacy_stale(&capped, &other_cap, same));
        let other_program = meta(Some(&["/other/claude", "--autocompact", "402530"]));
        assert!(legacy_stale(&capped, &other_program, same));
        let lost = meta(Some(&["/u/bin/claude", "--verbose", "--autocompact", "402530"]));
        assert!(legacy_stale(&capped, &lost, same));
        // Nothing to judge: no recorded argv, a remote-origin session.
        assert!(!legacy_stale(&capped, &meta(None), same));
        let mut remote = old.clone();
        remote.remote_origin = true;
        assert!(!legacy_stale(&capped, &remote, same));
    }

    #[test]
    fn a_legacy_agent_is_judged_by_its_expanded_and_resolved_argv() {
        let npx = profile(&["/u/bin/npx", "-y", "@zed-industries/codex-acp", "--cwd", "${cwd}"]);
        // A resolved launcher replaced `npx -y PACKAGE` with its binary; `${cwd}` was expanded.
        let resolve = |argv: Vec<String>| {
            std::iter::once("/cache/codex-acp".to_owned()).chain(argv.into_iter().skip(3)).collect()
        };
        assert!(!legacy_stale(&npx, &meta(Some(&["/cache/codex-acp", "--cwd", "/w"])), resolve));
        assert!(legacy_stale(&npx, &meta(Some(&["/cache/codex-acp"])), resolve));
        // Another package resolves to another binary.
        assert!(legacy_stale(&npx, &meta(Some(&["/cache/other-acp", "--cwd", "/w"])), resolve));
    }
}

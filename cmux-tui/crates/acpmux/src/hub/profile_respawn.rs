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

impl Hub {
    /// Restarts every live local agent whose profile's launch differs from the one it started
    /// from. A Home Chief session, or one whose harness is no longer in the catalog, is left as it
    /// is; one with no
    /// recorded digest (started by an older build) is judged by its argv (`legacy_stale`).
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
                None => legacy_stale(profile, &meta),
            };
            if !changed || session.child.lock().await.is_none() {
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

/// A session started before agents kept their launch digest: stale when the argv its agent last
/// started with (`spawn_argv`, kept on disk since #23322) does not hold the profile's own words
/// after its program (after `npx -y PACKAGE`, which a resolved launcher replaces), expanded as a
/// start expands them, in one run. The preset's and acpmux's own words come after them, so an
/// unchanged profile always matches; a word the profile gained, such as `--autocompact 402530`,
/// does not. A remote-origin session's argv is admitted differently (`admit_remote_profile`), and
/// a profile with no words of its own says nothing: neither is judged.
fn legacy_stale(profile: &HarnessProfile, meta: &SessionMeta) -> bool {
    let Some(started) = meta.spawn_argv.as_deref().filter(|_| !meta.remote_origin) else {
        return false;
    };
    let program =
        if crate::config::adapter_package_launch(&profile.argv).is_some() { 3 } else { 1 };
    let home = dirs::home_dir().unwrap_or_default();
    let model = meta.model_request.clone().unwrap_or_default();
    let own: Vec<String> = profile
        .argv
        .iter()
        .skip(program)
        .map(|a| super::spawn::expand_env_value(a, &meta.cwd, &home, &model))
        .collect();
    if own.is_empty() {
        return false;
    }
    !started.get(1..).unwrap_or_default().windows(own.len()).any(|run| run == own.as_slice())
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

    #[test]
    fn a_legacy_agent_is_stale_only_when_its_argv_lacks_the_profiles_own_words() {
        let capped = profile(&["/u/bin/claude", "--autocompact", "402530"]);
        // Started before the profile gained the flag (the 2026-10-31 session at 650k of 1M).
        let old = meta(Some(&["/u/bin/claude", "--disallowedTools", "mcp__x"]));
        assert!(legacy_stale(&capped, &old));
        // Started after: the preset's and acpmux's words follow the profile's own.
        let new =
            meta(Some(&["/u/bin/claude", "--autocompact", "402530", "--disallowedTools", "x"]));
        assert!(!legacy_stale(&capped, &new));
        // A different cap is a change too; the program's own path is not judged.
        assert!(legacy_stale(&capped, &meta(Some(&["/u/bin/claude", "--autocompact", "300000"]))));
        assert!(!legacy_stale(&capped, &meta(Some(&["/other/claude", "--autocompact", "402530"]))));
        // Nothing to judge: no recorded argv, a remote-origin session, a profile of one word.
        assert!(!legacy_stale(&capped, &meta(None)));
        let mut remote = old.clone();
        remote.remote_origin = true;
        assert!(!legacy_stale(&capped, &remote));
        assert!(!legacy_stale(&profile(&["/u/bin/claude"]), &old));
    }

    #[test]
    fn a_legacy_agent_matches_by_expanded_words_after_an_npx_launcher() {
        let npx = profile(&["/u/bin/npx", "-y", "@zed-industries/codex-acp", "--cwd", "${cwd}"]);
        // A resolved launcher replaced `npx -y PACKAGE` with its binary; `${cwd}` was expanded.
        assert!(!legacy_stale(&npx, &meta(Some(&["/cache/codex-acp", "--cwd", "/w"]))));
        assert!(legacy_stale(&npx, &meta(Some(&["/cache/codex-acp"]))));
    }
}

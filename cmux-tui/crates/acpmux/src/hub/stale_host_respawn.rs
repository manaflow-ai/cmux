//! Part of `Hub`; see `hub/mod.rs`. An agent host running from an executable other than this
//! daemon's own restarts on this daemon's binary and resumes the same conversation (`claude
//! --resume`, ACP `session/load`), the way an update's restart does (`route_switch.rs`
//! `restart_harnesses`): between turns now, in a turn when the turn ends, never cancelled, and
//! never across an open permission prompt. Checked once the daemon has adopted the agents the
//! previous one left (`daemon.rs`).
//!
//! An app update moves the bundle that every running host was started from: nightly-update swaps
//! `/Applications/cmux NIGHTLY.app` and keeps the old bundle in its backup folder, so each host
//! (and the MCP servers under its harness) then runs from the backup, which the kernel reports
//! (`proc_pidpath`) although `ps` still shows the old argv. A daemon started after the update
//! runs the installed binary and spawns new hosts from it (`HostLauncher::current`), but the hosts
//! it adopts stay on the old one until their chat restarts. On cosmic-gray (2026-11-04) 46 such
//! processes outlived the update by hours. Leo, on "If an old chat acts oddly, restarting that
//! chat fixes it": "Surely we can do things gracefully and efficiently/effectively".
//!
//! Every host this daemon starts runs its own binary, so a host on another one was started by an
//! earlier daemon from a binary that has since moved or been replaced: the restart puts it on
//! the one installed now. A Home Chief session is included (unlike Update Everything): its Chief
//! refuses an acpmux peer that runs from outside the installed app.

use super::*;

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

impl Hub {
    /// Restarts every live local agent whose host runs an executable other than this daemon's.
    /// A host whose executable cannot be read is left alone (unknown is not stale), as is a
    /// session with no running agent (it starts on this binary at its next prompt).
    pub(crate) async fn respawn_stale_hosts(self: &Arc<Self>) -> HarnessRestarts {
        let Some(own) = crate::agent_host::tree::exe(std::process::id()) else {
            return HarnessRestarts::default();
        };
        let mut hosts = Vec::new();
        for session in self.sessions() {
            let pid = session
                .child
                .lock()
                .await
                .as_ref()
                .and_then(|c| c.host_record())
                .map(|r| r.host_pid);
            if let Some(pid) = pid {
                hosts.push((session.id.clone(), crate::agent_host::tree::exe(pid)));
            }
        }
        let stale = stale_hosts(&own, hosts);
        if stale.is_empty() {
            return HarnessRestarts::default();
        }
        tracing::info!(count = stale.len(), exe = %own.display(), "agent hosts run another executable than this daemon: restarting them between turns");
        self.restart_harnesses(None, Some(&stale)).await
    }

    /// Once the agents the previous daemon left are adopted, on a task of its own: an agent whose
    /// harness profile changed (`profile_respawn.rs`), then one whose host runs a stale
    /// executable, restarts between turns. One after the other, so a session both would restart
    /// restarts once: the second pass finds it already on this binary, or already marked for its
    /// turn end.
    pub(crate) fn spawn_startup_respawns(self: &Arc<Self>) {
        let hub = self.clone();
        tokio::spawn(async move {
            let profiles = hub.respawn_changed_profiles().await;
            for (session, error) in &profiles.failed {
                tracing::warn!(%session, %error, "profile respawn");
            }
            let stale = hub.respawn_stale_hosts().await;
            for (session, error) in &stale.failed {
                tracing::warn!(%session, %error, "stale host respawn");
            }
            if stale.now + stale.after_turn > 0 {
                tracing::info!(
                    now = stale.now,
                    after_turn = stale.after_turn,
                    failed = stale.failed.len(),
                    "stale host respawn"
                );
            }
        });
    }
}

/// The sessions whose host runs an executable other than `own`; one whose executable could not
/// be read is not counted.
fn stale_hosts(
    own: &Path,
    hosts: impl IntoIterator<Item = (String, Option<PathBuf>)>,
) -> BTreeSet<String> {
    hosts
        .into_iter()
        .filter(|(_, exe)| exe.as_deref().is_some_and(|exe| exe != own))
        .map(|(id, _)| id)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const INSTALLED: &str = "/Applications/cmux NIGHTLY.app/Contents/Resources/bin/cmux";
    const BACKUP: &str = "/Users/leo/.local/state/nightly-update/backup/cmux NIGHTLY.app/Contents/Resources/bin/cmux";

    #[test]
    fn a_host_on_the_moved_bundle_is_stale_and_one_on_this_binary_or_unknown_is_not() {
        let stale = stale_hosts(
            Path::new(INSTALLED),
            [
                ("moved".to_owned(), Some(PathBuf::from(BACKUP))),
                ("current".to_owned(), Some(PathBuf::from(INSTALLED))),
                ("unreadable".to_owned(), None),
            ],
        );
        assert_eq!(stale, BTreeSet::from(["moved".to_owned()]));
    }

    #[test]
    fn this_process_is_never_stale_against_itself() {
        let own = crate::agent_host::tree::exe(std::process::id());
        if let Some(own) = own {
            let stale = stale_hosts(
                &own,
                [("self".to_owned(), crate::agent_host::tree::exe(std::process::id()))],
            );
            assert!(stale.is_empty());
        }
    }

    #[tokio::test]
    async fn a_daemon_with_no_running_agents_restarts_nothing() {
        let mut config: crate::config::Config =
            serde_json::from_value(serde_json::json!({"harnesses": {}})).unwrap();
        config.store.mode = crate::config::StoreMode::Memory;
        config.profile_sources = crate::config::ProfileSources::none();
        let store = crate::store::open(&config.store, Path::new("/unused")).unwrap();
        let out = Hub::new(config, store).respawn_stale_hosts().await;
        assert_eq!((out.now, out.after_turn, out.failed.len()), (0, 0, 0));
    }
}

//! Part of `Hub`; see `hub/mod.rs`. An agent host whose binary was moved or replaced since it
//! started restarts on the binary installed now and resumes the same conversation (`claude
//! --resume`, ACP `session/load`), the way an update's restart does (`route_switch.rs`
//! `restart_harnesses`): between turns now, in a turn when the turn ends, never cancelled, and
//! never across an open permission prompt. Checked once the daemon has adopted the agents the
//! previous one left (`daemon.rs`).
//!
//! An app update moves the bundle that every running host was started from: nightly-update swaps
//! `/Applications/cmux NIGHTLY.app` and keeps the old bundle in its backup folder, so each host
//! (and the MCP servers under its harness) then runs the old file from the backup while the path
//! it was started as (its argv0) now names the new one. On cosmic-gray (2026-11-04) 46 such
//! processes outlived the update by hours, and a Chief refuses an acpmux peer that runs from
//! outside the installed app. Leo, on "If an old chat acts oddly, restarting that chat fixes
//! it": "Surely we can do things gracefully and efficiently/effectively".
//!
//! Stale is judged per host, by file identity (device and inode), never by comparing paths or
//! this daemon's own binary: the file the host runs against the file now at the path it was
//! started as. A symlink or hard link to the same binary is the same file, and a DEV daemon
//! adopting hosts the installed app started leaves them alone while their binary is still the
//! installed one, so switching daemons does not cycle every chat. A host whose identity cannot be
//! read, or whose argv0 is not an absolute path, is left alone (unknown is not stale). A Home
//! Chief session is included (unlike Update Everything), for the refusal above.

use super::*;

use std::collections::BTreeSet;
use std::path::Path;

/// A file's identity: (device, inode).
type FileId = (u64, u64);

impl Hub {
    /// Restarts every live local agent whose host runs a binary other than the one now at the
    /// path it was started as. A session with no running agent is left alone: it starts on the
    /// installed binary at its next prompt.
    pub(crate) async fn respawn_stale_hosts(self: &Arc<Self>) -> HarnessRestarts {
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
                hosts.push((session.id.clone(), running_file(pid), launched_file(pid)));
            }
        }
        let stale = stale_hosts(hosts);
        if stale.is_empty() {
            return HarnessRestarts::default();
        }
        tracing::info!(
            count = stale.len(),
            "agent hosts run a binary that was moved or replaced since they started: restarting them between turns"
        );
        self.restart_harnesses(None, Some(&stale)).await
    }

    /// Once the agents the previous daemon left are adopted, on a task of its own: an agent whose
    /// harness profile changed (`profile_respawn.rs`), then one whose host runs a moved or
    /// replaced binary, restarts between turns. One after the other, so a session both would
    /// restart restarts once: the second pass finds it already on the new binary, or already
    /// marked for its turn end.
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

/// The sessions whose host's running file is known and differs from the file at the path it was
/// started as.
fn stale_hosts(
    hosts: impl IntoIterator<Item = (String, Option<FileId>, Option<FileId>)>,
) -> BTreeSet<String> {
    hosts
        .into_iter()
        .filter(
            |(_, running, launched)| matches!((running, launched), (Some(r), Some(l)) if r != l),
        )
        .map(|(id, _, _)| id)
        .collect()
}

#[cfg(unix)]
fn file_id(path: &Path) -> Option<FileId> {
    use std::os::unix::fs::MetadataExt as _;
    std::fs::metadata(path).ok().map(|m| (m.dev(), m.ino()))
}

#[cfg(not(unix))]
fn file_id(_path: &Path) -> Option<FileId> {
    None
}

/// The file `pid` runs: the path the kernel reports for it now (`proc_pidpath` on macOS, the
/// `/proc/<pid>/exe` link on Linux, both of which follow a rename of the file or its bundle). A binary
/// replaced in place rather than moved reads as the new file there, so it is left to the next restart.
#[cfg(unix)]
fn running_file(pid: u32) -> Option<FileId> {
    file_id(&crate::agent_host::tree::exe(pid)?)
}

/// Windows has no process tree reader here, so no host reads as stale.
#[cfg(not(unix))]
fn running_file(_pid: u32) -> Option<FileId> {
    None
}

/// The file now at the path `pid` was started as (its argv0, absolute only), symlinks followed.
#[cfg(unix)]
fn launched_file(pid: u32) -> Option<FileId> {
    let argv0 = crate::agent_host::tree::argv(pid)?.into_iter().next()?;
    let path = Path::new(&argv0);
    path.is_absolute().then(|| file_id(path)).flatten()
}

#[cfg(not(unix))]
fn launched_file(_pid: u32) -> Option<FileId> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_host_whose_running_file_differs_from_its_launch_path_is_stale() {
        let stale = stale_hosts([
            ("moved".to_owned(), Some((1, 10)), Some((1, 20))),
            ("current".to_owned(), Some((1, 20)), Some((1, 20))),
            ("unreadable".to_owned(), None, Some((1, 20))),
            ("relative".to_owned(), Some((1, 10)), None),
        ]);
        assert_eq!(stale, BTreeSet::from(["moved".to_owned()]));
    }

    #[cfg(unix)]
    #[test]
    fn a_moved_file_is_stale_and_a_symlink_or_hard_link_to_it_is_not() {
        let dir = tempfile::tempdir().unwrap();
        let bin = dir.path().join("cmux");
        std::fs::write(&bin, b"old").unwrap();
        let link = dir.path().join("acpmux");
        std::os::unix::fs::symlink(&bin, &link).unwrap();
        let hard = dir.path().join("hard");
        std::fs::hard_link(&bin, &hard).unwrap();
        let running = file_id(&bin);
        assert_eq!(running, file_id(&link));
        assert_eq!(running, file_id(&hard));
        // The update: the old file moves away and a new one takes its path.
        std::fs::rename(&bin, dir.path().join("backup-cmux")).unwrap();
        std::fs::write(&bin, b"new").unwrap();
        assert_ne!(running, file_id(&link));
    }

    #[test]
    fn this_process_is_not_stale() {
        let pid = std::process::id();
        if let (Some(running), Some(launched)) = (running_file(pid), launched_file(pid)) {
            assert_eq!(running, launched);
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

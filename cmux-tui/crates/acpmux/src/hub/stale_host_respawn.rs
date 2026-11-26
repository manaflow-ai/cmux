//! Part of `Hub`; see `hub/mod.rs`. An agent host whose binary was moved or replaced since it
//! started restarts on the binary installed now and resumes the same conversation (`claude
//! --resume`, ACP `session/load`) once nothing runs in it: no turn, no question, no background
//! process or subagent, nothing under it but its MCP servers (`idle.rs` `respawn_when_quiet`).
//! Never cancelled, never cut mid-work. Checked once the daemon has adopted the agents the
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
    /// Every live local agent whose host runs a binary other than the one now at the path it was
    /// started as: an idle one ends at once and stays asleep (`end_idle_stale`); any other is
    /// marked to restart once nothing runs in it (`Session::respawn_when_quiet`): the idle pass
    /// ends it after a short quiet period, under every gate an idle exit has (no turn, nothing
    /// queued, no question, no background process or subagent, no sub-session at work, the
    /// census of what runs under it), and its next prompt starts it on the installed binary, as a
    /// hibernated chat wakes. A session with no running agent is left alone: it starts on the
    /// installed binary at its next prompt.
    ///
    /// Before, an agent at work restarted at once when no turn was open, or when its turn ended,
    /// whatever ran in it: each cmux NIGHTLY install (every 20-30 min, 2026-11-17) restarted a
    /// coordinator 10-20 s after the new daemon adopted its host, its 10-15 background subagents
    /// and waits cut mid-task. The host it ran on was alive and adopted. Leo: "the dream is
    /// infinite chats of infinite length".
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
        // An idle one ends and stays asleep: its next open or prompt starts it on the installed
        // binary, as a hibernated chat wakes (`idle.rs`). Restarting it at once started an agent
        // for every chat that was up at an update, the idle Chief sub-sessions among them: 30 at
        // one cmux NIGHTLY relaunch (2026-11-15), each a Claude process for its two idle minutes.
        let (mut slept, mut marked): (usize, usize) = (0, 0);
        for id in &stale {
            let Ok(session) = self.resolve(id) else { continue };
            if self.end_idle_stale(&session).await {
                slept = slept.saturating_add(1);
            } else {
                self.respawn_when_quiet(&session);
                marked = marked.saturating_add(1);
            }
        }
        tracing::info!(
            count = marked,
            slept,
            "agent hosts run a binary that was moved or replaced since they started: the idle \
             ones ended, the rest end once nothing runs in them; each starts on the installed one \
             when opened or sent to"
        );
        HarnessRestarts { after_turn: marked, ..HarnessRestarts::default() }
    }

    /// Restarts every live local agent sent through a vault egress proxy start other than this
    /// daemon's (`vault/egress.rs` `stale_proxy_env`): the previous daemon's proxy, whose port
    /// may be closed and whose CA the agent trusts, is gone with it. On one machine
    /// (2026-11-21 21:44Z) 20 chats went `harness_unavailable` on `ECONNREFUSED` this way after
    /// daemon restarts, each retried in the same process until the retries ran out. Idle ones
    /// hibernate only after the idle gates and census find no work, then start fresh when
    /// opened or sent to.
    pub(crate) async fn respawn_stale_proxies(self: &Arc<Self>) -> HarnessRestarts {
        let mut stale = BTreeSet::new();
        for session in self.sessions() {
            if self.proxy_stale(&session).await {
                stale.insert(session.id.clone());
            }
        }
        if stale.is_empty() {
            return HarnessRestarts::default();
        }
        let marked = stale.len();
        for id in &stale {
            if let Ok(session) = self.resolve(id) {
                self.respawn_when_quiet(&session);
            }
        }
        tracing::info!(
            code = "vault.egress_stale_agents",
            count = marked,
            "agents on a stale proxy wait for quiet and hibernate before their next prompt"
        );
        HarnessRestarts { after_turn: marked, ..HarnessRestarts::default() }
    }

    /// Whether `session`'s live agent was started on another start of this machine's vault
    /// egress proxy (`vault::egress::stale_proxy_pid`, read from its harness's environment).
    pub(super) async fn proxy_stale(&self, session: &Session) -> bool {
        let pid =
            session.child.lock().await.as_ref().and_then(|c| {
                c.host_record().map(|r| r.harness_pid.unwrap_or(r.host_pid)).or(c.pid)
            });
        pid.is_some_and(crate::vault::egress::stale_proxy_pid)
    }

    /// Before an automatic retry of a cut turn (`auto_resume.rs`): an agent [`Self::proxy_stale`]
    /// ends first, so the retry's prompt starts a fresh one on this daemon's proxy and resumes
    /// the same conversation, instead of sending the retry into the process that cannot reach
    /// it. The idle gates and census must find no work; only this firing continuation is
    /// exempt, since its prompt starts the replacement. Whether it ended the agent.
    pub(super) async fn end_stale_proxy_before_retry(
        self: &Arc<Self>,
        session: &Arc<Session>,
    ) -> bool {
        if !self.proxy_stale(session).await {
            return false;
        }
        let ended = self.end_quiet_stale(session, "stale-proxy-retry", true).await;
        if !ended {
            self.respawn_when_quiet(session);
        }
        ended
    }

    /// Ends `session`'s agent when it is idle as the idle pass judges it (`idle.rs`
    /// `idle_eligible`, under the same leases) and marks the chat hibernated, so a person's open
    /// wakes it. A turn, a queued prompt, a question, a background process or subagent, or any
    /// start under way keeps it for the restart once quiet (`respawn_when_quiet`).
    async fn end_idle_stale(&self, session: &Arc<Session>) -> bool {
        self.end_idle_stale_for(session, "stale-binary").await
    }

    async fn end_idle_stale_for(&self, session: &Arc<Session>, cause: &'static str) -> bool {
        self.end_quiet_stale(session, cause, false).await
    }

    /// The immediate automatic exit uses the same leases, activity checks, census and
    /// hibernation as the idle pass. Unknown descendants keep the agent alive. Only the
    /// firing retry caller may omit its own continuation from the eligibility check.
    pub(super) async fn end_quiet_stale(
        &self,
        session: &Arc<Session>,
        cause: &'static str,
        firing_retry: bool,
    ) -> bool {
        let eligible = || {
            if firing_retry {
                self.retry_restart_eligible(session)
            } else {
                self.idle_eligible(session)
            }
        };
        if !eligible() {
            return false;
        }
        let Some(child) = session.child.lock().await.clone() else { return false };
        let sidecars = self.sidecars(session, &child).await;
        let turn = session.turn_lock.try_lock();
        let using = session.harness_use.try_write();
        let spawning = session.spawn_lock.try_lock();
        let same = session.child.lock().await.as_ref().is_some_and(|c| Arc::ptr_eq(c, &child));
        if turn.is_err() || using.is_err() || spawning.is_err() || !same || !eligible() {
            return false;
        }
        let seen = session.last_active.load(Ordering::SeqCst);
        let census = self.idle_census(child.pid, sidecars).await;
        if !matches!(census, super::idle_census::Census::Clear) {
            self.note_refusal(session, &census);
            return false;
        }
        Self::drain_inbound(session).await;
        if session.last_active.load(Ordering::SeqCst) != seen || !eligible() {
            return false;
        }
        let link_lost = child.host_record().is_some() && !child.is_alive().await;
        if !self.hibernate_held(session, link_lost, Some(seen)).await {
            return false;
        }
        tracing::info!(session = %session.id, cause, "hibernated: stale agent passed every quietness gate and the census");
        true
    }

    /// Once the agents the previous daemon left are adopted, on a task of its own: an agent whose
    /// harness profile changed (`profile_respawn.rs`), then one whose host runs a moved or
    /// replaced binary, then one sent through an earlier daemon's vault egress proxy, restarts
    /// between turns. One after the other, so a session both would
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
            let proxies = hub.respawn_stale_proxies().await;
            for (session, error) in &proxies.failed {
                tracing::warn!(%session, %error, "stale proxy respawn");
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

    async fn live_chat() -> (Arc<Hub>, Arc<Session>) {
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        let mut config: crate::config::Config = serde_json::from_value(json!({
            "harnesses": {"fake": {"argv": ["python3", fake]}},
            "defaultHarness": "fake",
        }))
        .unwrap();
        config.store.mode = crate::config::StoreMode::Memory;
        config.profile_sources = crate::config::ProfileSources::none();
        let store = crate::store::open(&config.store, Path::new("/unused")).unwrap();
        let hub = Hub::new(config, store);
        let session = hub
            .new_session(NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() })
            .await
            .unwrap();
        hub.prompt(&session, vec![json!({"type": "text", "text": "hello"})], "test", false)
            .await
            .unwrap();
        (hub, session)
    }

    #[tokio::test]
    async fn automatic_restart_keeps_queued_prompts_and_work_below_even_before_retry() {
        let (hub, session) = live_chat().await;
        let first = session.child.lock().await.clone().unwrap();
        session.queued.fetch_add(1, Ordering::SeqCst);
        for retry in [false, true] {
            assert!(!hub.end_quiet_stale(&session, "test", retry).await);
        }
        session.queued.fetch_sub(1, Ordering::SeqCst);
        *session.work_below_since.lock().unwrap() = 1;
        for retry in [false, true] {
            assert!(!hub.end_quiet_stale(&session, "test", retry).await);
        }
        assert!(Arc::ptr_eq(&first, session.child.lock().await.as_ref().unwrap()));
        *session.work_below_since.lock().unwrap() = 0;
        assert!(hub.end_quiet_stale(&session, "test", false).await);
        assert!(session.child.lock().await.is_none());
        assert_ne!(session.meta().hibernated_ms, 0);
        hub.shutdown_all().await;
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn automatic_restart_censuses_unreported_work_before_ending_a_stale_agent() {
        let (hub, session) = live_chat().await;
        let dir = tempfile::tempdir().unwrap();
        let probe = dir.path().join("child.json");
        hub.prompt(
            &session,
            vec![json!({"type": "text",
            "text": format!("class-probe: {}", probe.display())})],
            "test",
            false,
        )
        .await
        .unwrap();
        assert!(hub.idle_eligible(&session), "the child is absent from the agent's work tables");
        let first = session.child.lock().await.clone().unwrap();
        for retry in [false, true] {
            assert!(
                !hub.end_quiet_stale(&session, "test", retry).await,
                "an automatic restart cut an unreported child (retry={retry})"
            );
        }
        assert!(Arc::ptr_eq(&first, session.child.lock().await.as_ref().unwrap()));
        assert_eq!(session.meta().hibernated_ms, 0);
        hub.shutdown_all().await;
    }

    #[tokio::test]
    async fn a_daemon_with_no_running_agents_restarts_no_stale_proxy_agent() {
        let mut config: crate::config::Config =
            serde_json::from_value(serde_json::json!({"harnesses": {}})).unwrap();
        config.store.mode = crate::config::StoreMode::Memory;
        config.profile_sources = crate::config::ProfileSources::none();
        let store = crate::store::open(&config.store, Path::new("/unused")).unwrap();
        let out = Hub::new(config, store).respawn_stale_proxies().await;
        assert_eq!((out.now, out.after_turn, out.failed.len()), (0, 0, 0));
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

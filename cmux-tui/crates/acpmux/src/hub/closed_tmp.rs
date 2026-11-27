//! A closed session's temporary folder (`agent/session_tmp.rs`) is freed: at its close, and every
//! hour for closed sessions whose folder is still there (one an open session worked in, one closed
//! before this daemon started). Before, a folder went only with a purge, so a closed chat kept its
//! agents' scratch forever (gcp-agent-lane-14, 2026-11-24: 12.4 GiB in 106 folders, the largest
//! 4.9 GiB of a closed `ask-...` chat, all test scratch).
//!
//! Each folder is moved aside under its session's `spawn_lock`, which every agent start holds
//! while it makes the folder (`ensure_child`), with the session read again as closed under it: a
//! reopen either comes first (the session is no longer closed, its folder stays) or after (its
//! start makes a new, empty folder). The removal of what was moved aside runs after the lock is
//! let go, on a blocking thread. A folder an open session's folder is inside stays, and the log
//! says which. Processes are not scanned (cmux-next never scans processes): the ones acpmux holds
//! end with the close.

use super::*;

/// How often closed sessions' folders still there are tried again.
const SWEEP_EVERY: std::time::Duration = std::time::Duration::from_secs(60 * 60);

/// How long a pass waits for a session's `spawn_lock`.
const LOCK_WAIT: std::time::Duration = std::time::Duration::from_secs(30);

/// What one pass did, for its log line and the tests.
#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct FreedTmp {
    pub(crate) freed: usize,
    pub(crate) kept: usize,
}

impl Hub {
    /// After `session`'s close: free its temporary folder, on a task of its own.
    pub(super) fn free_closed_tmp_soon(&self, session: &Arc<Session>) {
        let Some(hub) = self.hub_ref.get().and_then(std::sync::Weak::upgrade) else { return };
        let session = session.clone();
        self.scope.spawn_until_cancelled("closed-session-tmp", async move {
            hub.free_closed_tmps(vec![session]).await;
        });
    }

    /// Every hour from now (the first pass at once), free the folders of closed sessions.
    pub(super) fn sweep_closed_tmps(self: &Arc<Self>) {
        let hub = Arc::downgrade(self);
        self.scope.spawn_until_cancelled("closed-session-tmp-sweep", async move {
            let mut every = tokio::time::interval(SWEEP_EVERY);
            every.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            loop {
                every.tick().await;
                let Some(hub) = hub.upgrade() else { return };
                let sessions = hub.session_handles();
                let pass = hub.free_closed_tmps(sessions).await;
                if pass != FreedTmp::default() {
                    tracing::info!(
                        freed = pass.freed,
                        kept = pass.kept,
                        "closed sessions' temporary folders swept"
                    );
                }
            }
        });
    }

    /// Free the temporary folder of each closed session of `sessions` that has one.
    pub(crate) async fn free_closed_tmps(&self, sessions: Vec<Arc<Session>>) -> FreedTmp {
        let closed = |s: &Session| {
            s.status() == SessionStatus::Closed
                && !s.purged.load(Ordering::SeqCst)
                && !s.replaced.load(Ordering::SeqCst)
        };
        let candidates: Vec<_> = sessions.into_iter().filter(|s| closed(s)).collect();
        if candidates.is_empty() {
            return FreedTmp::default();
        }
        // A stat each, off the runtime.
        let ids: Vec<String> = candidates.iter().map(|s| s.id.clone()).collect();
        let Ok(with_folder) = tokio::task::spawn_blocking(move || {
            ids.into_iter()
                .filter(|id| crate::agent::session_tmp::has_folder(id))
                .collect::<std::collections::HashSet<String>>()
        })
        .await
        else {
            return FreedTmp::default();
        };
        if with_folder.is_empty() {
            return FreedTmp::default();
        }
        // Each open session's folder: a probe chat may work in another chat's temporary folder.
        let open_cwds: Vec<(String, std::path::PathBuf)> = self
            .session_handles()
            .iter()
            .filter(|s| s.status() != SessionStatus::Closed)
            .map(|s| (s.id.clone(), s.meta().cwd))
            .collect();
        let mut pass = FreedTmp::default();
        let mut aside = Vec::new();
        for session in candidates.iter().filter(|s| with_folder.contains(&s.id)) {
            // A start under way holds it, and the session is read as closed again below; one that
            // holds it longer than this is left to the next pass.
            let Ok(_spawning) = tokio::time::timeout(LOCK_WAIT, session.spawn_lock.lock()).await
            else {
                continue;
            };
            let current = self
                .sessions
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .get(&session.id)
                .is_some_and(|c| Arc::ptr_eq(c, session));
            if !current || !closed(session) {
                continue;
            }
            let mut cwds = open_cwds.clone();
            cwds.push((session.id.clone(), session.meta().cwd));
            use crate::agent::session_tmp::Freed;
            match crate::agent::session_tmp::free_closed_session(&session.id, &cwds) {
                Freed::Aside(dir) => {
                    pass.freed += 1;
                    aside.push(dir);
                }
                Freed::Kept(why) => {
                    pass.kept += 1;
                    tracing::info!(
                        session = %session.id,
                        "kept a closed session's temporary folder: {why}"
                    );
                }
                Freed::Absent | Freed::Failed => {}
            }
        }
        if !aside.is_empty() {
            let _ =
                tokio::task::spawn_blocking(move || crate::agent::session_tmp::remove_all(&aside))
                    .await;
        }
        pass
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::super::former_names::tests::{chat, hub};
    use super::*;

    #[tokio::test]
    async fn a_closed_chats_folder_goes_and_an_open_ones_stays() {
        let hub = hub();
        let [closed, idle, held, probe] = std::array::from_fn(|_| uuid::Uuid::now_v7().to_string());
        let base = crate::agent::session_tmp::per_user_base();
        let home = crate::config::home();
        let make = |id: &str| crate::agent::session_tmp::make(&base, &home, id).unwrap();
        let (closed_dir, idle_dir, held_dir) = (make(&closed), make(&idle), make(&held));
        std::fs::write(closed_dir.join("scratch"), "x").unwrap();
        // An open probe chat works in the held chat's folder.
        let probe_cwd = held_dir.join("probe-1");
        std::fs::create_dir(&probe_cwd).unwrap();
        let sessions: Vec<_> = [&closed, &idle, &held, &probe].map(|id| chat(&hub, id, id)).into();
        hub.edit_test_meta(&sessions[0], |m| m.status = SessionStatus::Closed);
        hub.edit_test_meta(&sessions[2], |m| m.status = SessionStatus::Closed);
        hub.edit_test_meta(&sessions[3], |m| m.cwd = probe_cwd.clone());

        let pass = hub.free_closed_tmps(hub.session_handles()).await;
        assert_eq!(pass, FreedTmp { freed: 1, kept: 1 });
        assert!(!closed_dir.exists(), "the closed chat's folder stayed");
        assert!(idle_dir.is_dir(), "the idle chat's folder went");
        assert!(probe_cwd.is_dir(), "the folder an open chat works in went");
        // Nothing moved aside is left behind.
        let leftovers: Vec<_> = std::fs::read_dir(closed_dir.parent().unwrap())
            .unwrap()
            .flatten()
            .filter(|e| e.file_name().to_string_lossy().starts_with(".gone-"))
            .collect();
        assert!(leftovers.is_empty(), "{leftovers:?}");

        // Reopened, the chat's next start gets a new, empty folder.
        let again = make(&closed);
        assert_eq!(again, closed_dir);
        assert_eq!(std::fs::read_dir(&again).unwrap().count(), 0);
        hub.edit_test_meta(&sessions[0], |m| m.status = SessionStatus::Idle);
        assert_eq!(
            hub.free_closed_tmps(hub.session_handles()).await,
            FreedTmp { freed: 0, kept: 1 }
        );
        assert!(again.is_dir(), "the reopened chat's folder went");

        // The probe chat moves on: the held chat's folder goes at the next pass.
        hub.edit_test_meta(&sessions[3], |m| m.cwd = "/tmp".into());
        assert_eq!(
            hub.free_closed_tmps(hub.session_handles()).await,
            FreedTmp { freed: 1, kept: 0 }
        );
        assert!(!held_dir.exists());

        // A stop frees the folder on its own.
        let stopped = uuid::Uuid::now_v7().to_string();
        let stopped_dir = make(&stopped);
        let session = chat(&hub, &stopped, &stopped);
        hub.kill(&session, false).await.unwrap();
        assert_eq!(session.status(), SessionStatus::Closed);
        let until = std::time::Instant::now() + std::time::Duration::from_secs(10);
        while stopped_dir.exists() && std::time::Instant::now() < until {
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
        assert!(!stopped_dir.exists(), "the stop left its folder");

        hub.shutdown_all().await;
        for dir in [again, idle_dir] {
            let _ = std::fs::remove_dir_all(dir);
        }
    }
}

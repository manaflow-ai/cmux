//! A closed session's temporary folder (`agent/session_tmp.rs`) is freed: at its close, and every
//! hour for closed sessions whose folder is still there (one a live process kept, one closed
//! before this daemon started). Before, a folder went only with a purge, so a closed chat kept its
//! agents' scratch forever (gcp-agent-lane-14, 2026-11-24: 12.4 GiB in 106 folders, the largest
//! 4.9 GiB of a closed `ask-...` chat, all test scratch).
//!
//! Each folder is moved aside under its session's `spawn_lock`, which every agent start holds
//! while it makes the folder (`ensure_child`), with the session read again as closed under it: a
//! reopen either comes first (the session is no longer closed, its folder stays) or after (its
//! start makes a new, empty folder). The removal of what was moved aside runs after the lock is
//! let go, on a blocking thread. A folder a live process works in, or an open session's folder is
//! inside, stays, and the log says which and why.

use super::*;

/// How often closed sessions' folders still there are tried again.
const SWEEP_EVERY: std::time::Duration = std::time::Duration::from_secs(60 * 60);

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
        // A stat each, then one process scan, only when some closed session has a folder.
        let ids: Vec<String> = candidates.iter().map(|s| s.id.clone()).collect();
        let Ok((with_folder, holders)) = tokio::task::spawn_blocking(move || {
            let with: std::collections::HashSet<String> =
                ids.into_iter().filter(|id| crate::agent::session_tmp::has_folder(id)).collect();
            let holders =
                if with.is_empty() { None } else { crate::agent::session_tmp::Holders::scan() };
            (with, holders)
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
            // A start under way holds it: that session is not closed for long.
            let Ok(_spawning) = session.spawn_lock.try_lock() else { continue };
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
            match crate::agent::session_tmp::free_closed_session(
                &session.id,
                holders.as_ref(),
                &cwds,
            ) {
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
    use super::*;
    use crate::config::{Config, StoreMode};

    #[tokio::test]
    async fn a_closed_chats_folder_goes_and_an_open_ones_stays() {
        let root = std::env::temp_dir().join(format!("acpmux-closed-tmp-{}", uuid::Uuid::now_v7()));
        let mut cfg = Config::default();
        cfg.store.mode = StoreMode::Local;
        let store = crate::store::open(&cfg.store, &root).unwrap();
        let closed = uuid::Uuid::now_v7().to_string();
        let idle = uuid::Uuid::now_v7().to_string();
        let probe = uuid::Uuid::now_v7().to_string();
        let held = uuid::Uuid::now_v7().to_string();
        let base = crate::agent::session_tmp::per_user_base();
        let home = crate::config::home();
        let make = |id: &str| crate::agent::session_tmp::make(&base, &home, id).unwrap();
        let (closed_dir, idle_dir, held_dir) = (make(&closed), make(&idle), make(&held));
        std::fs::write(closed_dir.join("scratch"), "x").unwrap();
        // An open probe chat works in the held chat's folder.
        let probe_cwd = held_dir.join("probe-1");
        std::fs::create_dir(&probe_cwd).unwrap();
        for (id, status, cwd) in [
            (&closed, "closed", std::path::Path::new("/tmp")),
            (&idle, "idle", std::path::Path::new("/tmp")),
            (&held, "closed", std::path::Path::new("/tmp")),
            (&probe, "idle", probe_cwd.as_path()),
        ] {
            let meta = json!({
                "schema": crate::store::META_SCHEMA, "id": id, "name": id, "harness": "claude",
                "cwd": cwd, "status": status, "createdAt": 1, "updatedAt": 2,
            });
            store.save(&serde_json::from_value(meta).unwrap()).unwrap();
        }
        drop(store);
        let hub = Hub::new(cfg.clone(), crate::store::open(&cfg.store, &root).unwrap());

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

        hub.shutdown_all().await;
        for dir in [again, idle_dir, held_dir] {
            let _ = std::fs::remove_dir_all(dir);
        }
        let _ = std::fs::remove_dir_all(&root);
    }
}

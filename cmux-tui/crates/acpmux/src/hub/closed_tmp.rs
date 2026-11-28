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
//!
//! An open session's folder is kept under `session.tmpMaxMb` every `TRIM_EVERY`
//! (`agent/session_tmp/trim.rs`): its oldest top-level entries untouched for
//! `session.tmpIdleMinutes` that no process holds open go until it is under again.

use super::*;

/// How often closed sessions' folders still there are tried again.
const SWEEP_EVERY: std::time::Duration = std::time::Duration::from_secs(60 * 60);

/// How often open sessions' folders are measured against their cap.
#[cfg(target_os = "linux")]
const TRIM_EVERY: std::time::Duration = std::time::Duration::from_secs(10 * 60);

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

    /// Every hour from now (the first pass at once), free the folders of closed sessions; every
    /// `TRIM_EVERY`, keep open sessions' folders under their cap.
    pub(super) fn sweep_closed_tmps(self: &Arc<Self>) {
        #[cfg(target_os = "linux")]
        let weak = Arc::downgrade(self);
        #[cfg(target_os = "linux")]
        self.scope.spawn_until_cancelled("open-session-tmp-trim", async move {
            let mut every = tokio::time::interval(TRIM_EVERY);
            every.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            loop {
                every.tick().await;
                let Some(hub) = weak.upgrade() else { return };
                hub.trim_open_tmps().await;
            }
        });
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

    /// Keep each open session's folder under `session.tmpMaxMb` (module docs), off the runtime.
    /// What each folder the pass changed or left over the cap had, by session.
    #[cfg(target_os = "linux")]
    pub(crate) async fn trim_open_tmps(&self) -> Vec<(String, crate::agent::session_tmp::Trimmed)> {
        let session_cfg = self.config.read().await.session.clone();
        use crate::agent::session_tmp::trim as t;
        let Some(cap) = t::cap_bytes(&session_cfg) else { return Vec::new() };
        let idle = t::idle(&session_cfg);
        let open: Vec<String> = self
            .session_handles()
            .iter()
            .filter(|s| {
                s.status() != SessionStatus::Closed
                    && !s.purged.load(Ordering::SeqCst)
                    && !s.replaced.load(Ordering::SeqCst)
            })
            .map(|s| s.id.clone())
            .collect();
        let pass = tokio::task::spawn_blocking(move || {
            open.into_iter()
                .filter_map(|id| {
                    let out = crate::agent::session_tmp::trim_session(&id, cap, idle)?;
                    (out.evicted > 0 || out.after > cap).then_some((id, out))
                })
                .collect::<Vec<_>>()
        })
        .await
        .unwrap_or_default();
        for (id, out) in &pass {
            tracing::info!(session = %id, cap, "open session's temporary folder trimmed: {out:?}");
        }
        pass
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

    #[cfg(target_os = "linux")]
    #[tokio::test]
    async fn an_open_chats_folder_is_kept_under_its_cap_and_a_closed_ones_is_not_trimmed() {
        let hub = hub();
        let [open, closed] = std::array::from_fn(|_| uuid::Uuid::now_v7().to_string());
        let base = crate::agent::session_tmp::per_user_base();
        let home = crate::config::home();
        let make = |id: &str| crate::agent::session_tmp::make(&base, &home, id).unwrap();
        let (open_dir, closed_dir) = (make(&open), make(&closed));
        for dir in [&open_dir, &closed_dir] {
            std::fs::create_dir(dir.join("cmux-web-lint-1")).unwrap();
            std::fs::write(dir.join("cmux-web-lint-1/blob"), vec![7u8; 2 << 20]).unwrap();
        }
        let sessions: Vec<_> = [&open, &closed].map(|id| chat(&hub, id, id)).into();
        hub.edit_test_meta(&sessions[1], |m| m.status = SessionStatus::Closed);
        {
            let mut cfg = hub.config.write().await;
            cfg.session.tmp_max_mb = Some(1);
            cfg.session.tmp_idle_minutes = Some(0);
        }
        let pass = hub.trim_open_tmps().await;
        assert_eq!(pass.len(), 1, "{pass:?}");
        assert_eq!((pass[0].0.as_str(), pass[0].1.evicted), (open.as_str(), 1));
        assert!(!open_dir.join("cmux-web-lint-1").exists());
        assert!(
            closed_dir.join("cmux-web-lint-1").exists(),
            "a closed chat's folder is the close's"
        );
        // Off: nothing is measured.
        hub.config.write().await.session.tmp_max_mb = Some(0);
        assert!(hub.trim_open_tmps().await.is_empty());

        hub.shutdown_all().await;
        for dir in [open_dir, closed_dir] {
            let _ = std::fs::remove_dir_all(dir);
        }
    }
}

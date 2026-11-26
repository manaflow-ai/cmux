//! Part of `Hub`; see `hub/mod.rs`. A session's status: set, waiting, reopened, and the one
//! write each goes through.

use super::*;

impl Hub {
    /// Sets `session`'s status. A stopped (closed) session stays closed: only a close writes
    /// Closed, and only [`Self::reopen`] leaves it. `acpmux session stop` cancels the turn and its
    /// asks and closes the session while that turn's task, its asks and an agent start are still
    /// ending; each of them read the session as open before it waited, and its write came after
    /// the close: a stopped session listed as ready again (ergo-walk2, 2026-10-25: "session stop
    /// says closed but acpmux ls still shows it ready"). The check and the write are one lock.
    ///
    /// Every status but Waiting ([`NotWaiting`]): a chat waits only through [`Self::set_waiting`],
    /// with what it waits for, so no Waiting is ever bare.
    pub(crate) fn set_status(&self, session: &Session, status: NotWaiting) {
        self.write_status(session, status.into(), None, None);
    }

    /// Sets `session` Waiting on the person for `reason`, the summary's `waitingOn` while no
    /// open ask says more (`subsession_send.rs` `waiting_on`). The only way into Waiting.
    pub(crate) fn set_waiting(&self, session: &Session, reason: WaitReason) {
        self.write_status(session, SessionStatus::Waiting, Some(reason), None);
    }

    #[cfg(test)]
    pub(crate) fn test_reopen(&self, id: &str) -> bool {
        let Ok(session) = self.resolve(id) else { return false };
        let stops = session.stops.load(Ordering::SeqCst);
        self.reopen(&session, stops)
    }

    /// A stopped session starts again, for a request that came after its last stop: `stops` is
    /// [`Session::stops`] when the request came. Its status leaves Closed for Idle, logged
    /// `reopened`. False when it was not closed, or was stopped again since: it stays closed.
    pub(crate) fn reopen(&self, session: &Session, stops: u64) -> bool {
        // A chat being deleted stays closed (`Session::purging`).
        if session.purging.load(Ordering::SeqCst) {
            return false;
        }
        let reopened = self.write_status(session, SessionStatus::Idle, None, Some(stops));
        if reopened {
            self.append(session, "mux", "reopened", json!({}));
        }
        reopened
    }

    /// `reopen` is the stop count a reopen is for ([`Self::reopen`]), checked under the meta lock,
    /// which `kill`'s close takes after it counts the stop.
    /// `reason` is what a Waiting waits for, and only a Waiting has one ([`Self::set_waiting`]).
    fn write_status(
        &self,
        session: &Session,
        status: SessionStatus,
        reason: Option<WaitReason>,
        reopen: Option<u64>,
    ) -> bool {
        debug_assert_eq!(status == SessionStatus::Waiting, reason.is_some());
        // From before the status is set to after it is logged.
        session.status_writes.fetch_add(1, Ordering::SeqCst);
        struct Done<'a>(&'a AtomicU64);
        impl Drop for Done<'_> {
            fn drop(&mut self) {
                self.0.fetch_sub(1, Ordering::SeqCst);
            }
        }
        let _done = Done(&session.status_writes);
        let (was, link) = {
            let mut m = session.meta.lock().unwrap();
            let was = m.status;
            let reopens = reopen.is_some_and(|stops| session.stops.load(Ordering::SeqCst) == stops);
            if (was == SessionStatus::Closed && status != SessionStatus::Closed && !reopens)
                || (reopen.is_some() && was != SessionStatus::Closed)
            {
                return false;
            }
            m.status = status;
            // Under the meta lock with the status, so no read sees Waiting without its reason.
            *session.wait_reason.lock().unwrap_or_else(|e| e.into_inner()) = reason;
            if was != status {
                session.status_changes.fetch_add(1, Ordering::SeqCst);
            }
            // Only a change dates the chat: stopping a closed chat again logs nothing and leaves
            // it as old as it was, or a chat stopped every day would never be old enough for log
            // retention (`retention.rs`) and would move up the lists that sort by it.
            if was != status {
                m.updated_at = now_ms();
            }
            // The parent's slot follows the status under the same lock, so
            // concurrent status writes and the index never disagree (the
            // index is a leaf lock, `subsessions.rs`).
            if let Some(link) = &m.subsession {
                self.subsessions.note_status(&link.started_by, &session.id, status);
            }
            (was, m.subsession.clone())
        };
        self.update_live_session_index(session);
        if was != status {
            // Its inbound loop parks once the chat closes, and a reopen starts it again.
            session.closed.send_replace(status == SessionStatus::Closed);
            // A closed snapshot partitions sessions by status. Invalidate on both sides of a
            // closed transition, including reopen before its `reopened` record is appended, so a
            // build that observed the old partition cannot publish it after the transition.
            if was == SessionStatus::Closed || status == SessionStatus::Closed {
                self.chat_activity_cache.invalidate();
            }
            if let Some(link) = &link {
                self.subsession_status(&session.id, link, was, status);
            }
            session.mark_waiting(status == SessionStatus::Waiting);
            self.append(session, "mux", "status", json!({"status": status.to_string()}));
            self.save_meta(session);
            self.care_status(status);
            self.lock_bridge_wake();
            // A sub-session that starts or ends a turn, or closes, changes its parent's work.
            self.refresh_parent_work_below(session);
            // One that starts or stops waiting on the person changes its parent's asks below.
            self.refresh_parent_asks_below(session);
            if status == SessionStatus::Closed {
                self.retention_wake();
            }
        }
        true
    }
}

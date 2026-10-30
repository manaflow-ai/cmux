//! The append path's hold on tool output snapshots a newer one may replace (`store/deferred.rs`).

use super::*;

impl Hub {
    /// Appends one record under the session's append lock. A tool output snapshot a newer one may
    /// replace is stored without its content and held; the held ones a record makes due are
    /// appended before it. A copy (`at`) is never held. Clients hear every record as sent.
    ///
    /// `stored_only`: see [`Hub::append_record_locked`].
    #[allow(clippy::too_many_arguments)]
    pub(super) fn append_at_locked(
        &self,
        session: &Session,
        dir: &str,
        kind: &str,
        msg: Value,
        host_seq: Option<u64>,
        at: Option<u64>,
        stored_only: bool,
    ) -> (EventRecord, bool) {
        let keep = session.log_deferral.lock().unwrap_or_else(|e| e.into_inner()).keep(
            dir,
            kind,
            &msg,
            at.unwrap_or_else(now_ms),
            at.is_none(),
        );
        for (late_kind, late) in keep.before {
            self.append_record_locked(session, "in", late_kind, late, None, None, false, None);
        }
        self.append_record_locked(session, dir, kind, msg, host_seq, at, stored_only, keep.stored)
    }

    /// Stores every snapshot the session holds back, now: at shutdown, since a hosted agent's
    /// next daemon resumes after the stubs' `hostSeq` and never hears them again.
    pub(super) fn store_deferred(&self, session: &Session) {
        let _order = session.append_lock.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let held = session.log_deferral.lock().unwrap_or_else(|e| e.into_inner()).take_all();
        for (kind, late) in held {
            self.append_record_locked(session, "in", kind, late, None, None, false, None);
        }
    }
}

#[cfg(test)]
#[path = "log_deferral_tests.rs"]
mod tests;

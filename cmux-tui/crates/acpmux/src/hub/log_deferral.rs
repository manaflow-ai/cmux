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
        notify: bool,
    ) -> (EventRecord, bool) {
        let keep = session.log_deferral.lock().unwrap_or_else(|e| e.into_inner()).keep(
            dir,
            kind,
            &msg,
            at.unwrap_or_else(now_ms),
            at.is_none(),
        );
        self.store_late(session, keep.before);
        let kept = keep.stored.map_or(Kept::Sent, Kept::Stub);
        let (record, stored) = self.append_record_locked(
            session,
            dir,
            kind,
            msg,
            host_seq,
            at,
            stored_only,
            kept,
            notify,
        );
        if stored {
            let mut deferral = session.log_deferral.lock().unwrap_or_else(|e| e.into_inner());
            deferral.stored(&record.dir, &record.kind, &record.msg);
        }
        (record, stored)
    }

    /// Stores held records made due, in order. When the store refuses one, it and those after it
    /// are stored first at the next record (`Deferral::retry`); false then.
    fn store_late(&self, session: &Session, late: Vec<(&'static str, Value)>) -> bool {
        let mut late = late.into_iter();
        while let Some((kind, msg)) = late.next() {
            let (record, stored) = self.append_record_locked(
                session,
                "in",
                kind,
                msg,
                None,
                None,
                true,
                Kept::Sent,
                true,
            );
            if !stored {
                let mut refused = vec![(kind, record.msg)];
                refused.extend(late);
                let mut deferral = session.log_deferral.lock().unwrap_or_else(|e| e.into_inner());
                deferral.retry(refused);
                return false;
            }
        }
        true
    }

    /// Stores every snapshot the session holds back, now: before an export copies the log, and
    /// at shutdown, since a hosted agent's next daemon resumes after the stubs' `hostSeq` and
    /// never hears them again. False when the store refused one.
    pub(super) fn store_deferred(&self, session: &Session) -> bool {
        let _order = session.append_lock.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let held = session.log_deferral.lock().unwrap_or_else(|e| e.into_inner()).take_all();
        self.store_late(session, held)
    }
}

/// What the log stores for a record ([`Hub::append_record_locked`]).
pub(super) enum Kept {
    /// The record as sent.
    Sent,
    /// This message in its place (`store/deferred.rs`).
    Stub(Value),
}

#[cfg(test)]
#[path = "log_deferral_tests.rs"]
mod tests;

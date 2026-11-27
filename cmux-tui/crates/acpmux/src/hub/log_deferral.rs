//! The append path's hold on tool output snapshots a newer one may replace (`store/deferred.rs`).

use super::*;

impl Hub {
    /// Appends one record under the session's append lock. A tool output snapshot a newer one may
    /// replace is stored without its content and held; the held ones a record makes due are
    /// appended before it. A copy (`at`) is never held. Clients hear every record the store
    /// keeps, as sent; one it refused is not published ([`Hub::append_record_locked`]).
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
        let now = at.unwrap_or_else(now_ms);
        let mut keep = session.log_deferral.lock().unwrap_or_else(|e| e.into_inner()).keep(
            dir,
            kind,
            &msg,
            now,
            at.is_none(),
        );
        let late_stored = self.store_late(session, std::mem::take(&mut keep.before));
        // A held body is on disk before its stub is in the log: a kill after the stub loses
        // nothing the stream showed (`Hub::take_back_held`).
        if keep.stored.is_some() && !self.keep_held_body(session, kind, &msg, late_stored) {
            // Not held, stored whole. With `may_hold` false `keep` takes the path of a record
            // that is not held: a snapshot's call drops what it held (this replaces it) and
            // counts this one as its last stored; a diff's turn is the held one, so nothing goes
            // before it and the diff is dropped. What it gives to store first is only what the
            // store refused just now.
            let again = session
                .log_deferral
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .keep(dir, kind, &msg, now, false);
            self.store_late(session, again.before);
            keep.stored = again.stored;
        }
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
        let settled = {
            let mut deferral = session.log_deferral.lock().unwrap_or_else(|e| e.into_inner());
            if stored {
                deferral.stored(&record.dir, &record.kind, &record.msg);
            }
            deferral.settled()
        };
        // A body this record replaced while the store refused the record stays on disk: the next
        // start stores it, unless its log holds something newer by then.
        if stored {
            self.remove_held(session, settled);
        }
        (record, stored)
    }

    /// Writes `msg`, a record of kind `kind` the session holds back, beside the log as its slot's
    /// body (`Store::keep_held`), as of the session's seq now: a record past it may replace it.
    /// True when it is written, or needs no file: a purged chat stores nothing. False when it is
    /// not written (the store refused it, the chat has no slot free, or it is not caught up), or
    /// `late_stored` is false: what the store refused before it is stored after its stub, and an
    /// older body of its call stored after the file could read as replacing it.
    fn keep_held_body(
        &self,
        session: &Session,
        kind: &str,
        msg: &Value,
        late_stored: bool,
    ) -> bool {
        if session.purged.load(Ordering::SeqCst) {
            return true;
        }
        // Nor before what an earlier run left is read (`take_back_held`): a slot may hold it still.
        if !late_stored || !session.caught_up.load(Ordering::SeqCst) {
            return false;
        }
        // The slot is taken whether or not the write lands: stored whole, its body is held no
        // more, and the slot settles (and what an older write left in it is removed) with it.
        let slot = session.log_deferral.lock().unwrap_or_else(|e| e.into_inner()).slot(kind, msg);
        let Some(slot) = slot else { return false };
        let after = session.seq.load(Ordering::SeqCst);
        let written = crate::store::held_file(after, kind, msg)
            .map_err(anyhow::Error::from)
            .and_then(|bytes| self.store.keep_held(&session.id, &slot, Some(bytes.as_slice())));
        if let Err(e) = &written {
            tracing::warn!(session = %session.id, kind, "a held tool output was not written beside the log, so it is stored whole: {e:#}");
        }
        written.is_ok()
    }

    /// Removes the files of `slots`, bodies the session no longer holds. One that stays is read
    /// past at the next start: the log holds what replaces it.
    fn remove_held(&self, session: &Session, slots: Vec<String>) {
        for slot in slots {
            if let Err(e) = self.store.keep_held(&session.id, &slot, None) {
                tracing::warn!(session = %session.id, slot = %slot, "a held tool output's file was not removed: {e:#}");
            }
        }
    }

    /// After a restart, the bodies an earlier run held back and wrote beside the log
    /// ([`Self::keep_held_body`]) are stored now, oldest written first, unless a record the log
    /// holds past where each was written replaces it; their files are removed once stored. The
    /// caller holds `append_lock` (`catch_up_locked`, which raised the session's seq to the log's
    /// end first); once read, or found absent, they are not read again. One the store refuses now
    /// waits as any refused record does (`Deferral::retry`), its file kept.
    ///
    /// Answers whether they read: until they do the chat is not caught up, as with
    /// [`Hub::take_back_kept`], so no record of this run lands before them.
    pub(super) fn take_back_held(&self, session: &Session) -> bool {
        if session.held_read.load(Ordering::SeqCst) {
            return true;
        }
        let files = match self.store.kept_held(&session.id) {
            Ok(files) => files,
            Err(e) => {
                tracing::warn!(session = %session.id, "held tool output an earlier run left does not read; the chat waits for it: {e:#}");
                return false;
            }
        };
        if files.is_empty() {
            session.held_read.store(true, Ordering::SeqCst);
            return true;
        }
        let mut back = crate::store::HeldBack::read(files);
        if let Some(after) = back.after() {
            let scanned = self.store.scan(&session.id, after, &mut |record| back.saw(&record));
            if let Err(e) = scanned {
                tracing::warn!(session = %session.id, "the log does not read to match the held tool output an earlier run left: {e:#}");
                return false;
            }
        }
        let unread = std::mem::take(&mut back.unread);
        let (late, replaced) = back.into_late();
        tracing::info!(session = %session.id, stored = late.len(), replaced = replaced.len(), unread = unread.len(), "held tool output an earlier run left is stored");
        self.remove_held(session, unread.into_iter().chain(replaced).collect());
        {
            let mut deferral = session.log_deferral.lock().unwrap_or_else(|e| e.into_inner());
            for (slot, kind, msg) in &late {
                deferral.adopt(slot, kind, msg);
            }
        }
        session.held_read.store(true, Ordering::SeqCst);
        let late = late.into_iter().map(|(_, kind, msg)| (kind, msg)).collect();
        if self.store_late(session, late) {
            let settled = session.log_deferral.lock().unwrap_or_else(|e| e.into_inner()).settled();
            self.remove_held(session, settled);
        }
        true
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
        let stored = self.store_late(session, held);
        let settled = session.log_deferral.lock().unwrap_or_else(|e| e.into_inner()).settled();
        self.remove_held(session, settled);
        stored
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

//! A chat's restore point: where its next log load begins (cmuxterm-hq
//! `docs/design/acpmux-per-chat-startup.md`).
//!
//! Leo, 2026-11-12: "even if a chat is long, there should be no percievable difference".
//!
//! A log load (`log_load.rs`) folds the chat's log: its ownership epoch, its transfer authority,
//! an open turn, a subagent retry, its queue, the message copies a crash left unwritten. Each
//! fold read the whole log, so a god chat's first prompt after a start waited for about ten
//! reads of its history. A load whose folds ended quiet, and that appended nothing, saves the seq
//! it read to in `restore-point.json`, with the few values that carry across it (the epoch, the
//! authority, the queue's branch, holds and order, `QueueCarry`). The next load folds only the
//! records after that seq from those values. Quiet means nothing waited: no queued prompt, no
//! prompt between the queue and its turn, no open turn, no move, no agent pair, no subagent
//! retry, no message copy still to write. Every other part of each fold was empty there, so the
//! fold of what follows gives what a fold of the whole log gives (`restore_point_tests.rs`
//! folds both ways).
//!
//! A load that did not end quiet keeps the point it began from: still right, since nothing
//! before that seq changed. A point that does not match its log (the record at its seq differs,
//! or its seq is past the log's end) is not used; the load reads the whole log.

use super::*;

/// The point's format. Another one is not read: the load reads the whole log and saves this one.
const VERSION: u32 = 1;

#[derive(Debug, Clone, Default, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RestorePoint {
    pub(crate) v: u32,
    /// The last record the load that saved it read.
    pub(crate) seq: u64,
    /// That record's time and kind: a log replaced since (an import) does not match.
    pub(crate) at: u64,
    pub(crate) kind: String,
    /// The highest transfer fencing epoch through `seq` (`transfer_authority.rs`).
    pub(crate) ownership_epoch: u64,
    /// The last transfer record through `seq` that decides authority, as `(seq, blocked)`.
    pub(crate) transfer_authority: Option<(u64, bool)>,
    pub(crate) queue: super::queue::QueueCarry,
}

impl Hub {
    /// `session`'s restore point, when it matches its log; none for a chat read whole.
    pub(super) fn read_restore_point(&self, session: &Session) -> Option<RestorePoint> {
        let bytes = self.store.restore_point(&session.id)?;
        let point: RestorePoint = serde_json::from_slice(&bytes).ok()?;
        if point.v != VERSION || point.seq == 0 || point.seq > session.seq.load(Ordering::SeqCst) {
            return None;
        }
        // A fork's log joins its parent's (`store/fork_view.rs`): it is read whole.
        if session.meta().fork_seq.is_some() {
            return None;
        }
        let record = self.record_at(session, point.seq)?;
        (record.at == point.at && record.kind == point.kind).then_some(point)
    }

    /// The record at `seq`, read from the end of the records before `seq + 1`: a page of the log,
    /// never the segment that holds it (`Store::scan_back`). `events` from `seq - 1` parsed that
    /// whole segment, as much as a fold of the log the point is there to skip.
    fn record_at(&self, session: &Session, seq: u64) -> Option<EventRecord> {
        let mut found = None;
        self.store
            .scan_back(&session.id, seq - 1, seq + 1, &|_, _| false, &mut |rec| {
                found = Some(rec);
                false
            })
            .ok()?;
        found.filter(|r| r.seq == seq)
    }

    /// Saves `point` for `session`'s next load. A failed write leaves the last one, which is
    /// still right.
    pub(super) fn save_restore_point(&self, session: &Session, mut point: RestorePoint) {
        if session.meta().fork_seq.is_some() || point.seq == 0 {
            return;
        }
        let Some(record) = self.record_at(session, point.seq) else { return };
        point.v = VERSION;
        point.at = record.at;
        point.kind = record.kind;
        let Ok(bytes) = serde_json::to_vec(&point) else { return };
        if let Err(error) = self.store.save_restore_point(&session.id, &bytes) {
            tracing::debug!(session = %session.id, "restore point not saved: {error:#}");
        }
    }

    /// `session`'s last seq, read while no append is under way: a load that reads the same
    /// before and after its folds appended nothing, and its folds read every record through it.
    pub(super) fn settled_seq(&self, session: &Session) -> u64 {
        let _order = session.append_lock.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        session.seq.load(Ordering::SeqCst)
    }
}

#[cfg(test)]
#[path = "restore_point_tests.rs"]
mod tests;

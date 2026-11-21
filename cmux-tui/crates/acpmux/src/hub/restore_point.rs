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

// Rolling the point forward while the chat runs.
//
// Goal infinite-chats (Leo, 2026-11-19: "infinitely long chats"): the point is saved only by a
// load, so a chat that ran for days on one daemon had its next start read everything written
// since the last one (4.58 GB for a 4 GB chat, 9.5 s). A chat that has gone quiet, with its log
// [`ROLL_BYTES`] or more past its point, moves the point to the log's end in the background, so
// the next start reads the records written since, not since the last start.
//
// The new point comes from the same folds a load runs, over the records from the old point to the
// end, with nothing restored or written by them but the message copies a load also writes
// (`fold_*`, `queue_carry_after`): a running chat's own epoch, authority, queue and branch are live
// already, and a fold that put them back would overwrite what ran since. Quiet is read from the log
// as a load reads it (no open turn, nothing waiting, no move, no pair, no copy to write), so the
// point at the log's end carries what a load of the whole log would, and the chat's live state
// only says when to try (`busy_with`) and what is kept apart from the log (`keeps_unstored`, the
// saved meta's open subagent retry). The strict folds fail closed as a load's do: an unreadable
// line moves nothing. A chat that is not quiet, or that logged anything while the folds read,
// keeps the point it has; the next turn's end tries again.

/// The log a start would read from the point, in bytes (the segment that holds the point's next
/// record and every later one, `Store::log_bytes_after`), at which a running chat moves it. A
/// move reads about that much once, in the background; the start it saves reads the same, in the
/// foreground, about every 8 MiB segment past it.
pub(crate) const ROLL_BYTES: u64 = 16 << 20;
/// Records a chat logs between two checks of that size, which lists its segments.
const ROLL_RECORDS: u64 = 512;
/// How long a chat stays quiet before the move reads its log: a turn's end is mostly followed by
/// the next turn within it.
const ROLL_QUIET: std::time::Duration = std::time::Duration::from_secs(30);

/// A running chat's state for [`Hub::roll_restore_point_soon`].
#[derive(Default)]
pub(crate) struct Roll {
    /// The seq the last check was made at.
    checked: AtomicU64,
    /// A check is waiting or running: one at a time per chat, and it ends (its stop condition)
    /// after one try.
    running: AtomicBool,
}

impl Hub {
    /// At a turn's end (`turns.rs`): when the chat has logged [`ROLL_RECORDS`] since its last check
    /// (two atomic reads otherwise), moves its restore point once it has been quiet for
    /// [`ROLL_QUIET`] and its log is [`ROLL_BYTES`] past it. Off the executor; none in a hub
    /// outside a runtime.
    pub(super) fn roll_restore_point_soon(self: &Arc<Self>, session: &Arc<Session>) {
        let seq = session.seq.load(Ordering::SeqCst);
        if seq < session.roll.checked.load(Ordering::Relaxed).saturating_add(ROLL_RECORDS)
            || tokio::runtime::Handle::try_current().is_err()
            || session.roll.running.swap(true, Ordering::SeqCst)
        {
            return;
        }
        let (hub, session) = (self.clone(), session.clone());
        self.scope.spawn_until_cancelled("roll-restore-point", async move {
            tokio::time::sleep(ROLL_QUIET).await;
            let (h, s) = (hub.clone(), session.clone());
            let moved = tokio::task::spawn_blocking(move || {
                crate::qos::background(|| h.roll_restore_point(&s, ROLL_BYTES))
            })
            .await;
            if let Err(error) = moved {
                tracing::debug!(session = %session.id, "restore point not moved: {error}");
            }
            session.roll.checked.store(seq, Ordering::Relaxed);
            session.roll.running.store(false, Ordering::SeqCst);
        });
    }

    /// Moves `session`'s restore point to the log's end, when the chat is quiet and a start from
    /// the point would read `min_bytes` or more (a store that cannot say reads as none, but for a
    /// `min_bytes` of 0). Returns whether it saved one. Blocking; reads the log from the point.
    pub(crate) fn roll_restore_point(
        self: &Arc<Self>,
        session: &Arc<Session>,
        min_bytes: u64,
    ) -> bool {
        if !self.rollable(session) {
            return false;
        }
        let point = self.read_restore_point(session);
        let after = point.as_ref().map_or(0, |p| p.seq);
        let past = self.store.log_bytes_after(&session.id, after);
        if !past.map_or(min_bytes == 0, |bytes| bytes >= min_bytes) {
            return false;
        }
        let read_to = self.settled_seq(session);
        if read_to == 0 || read_to <= after {
            return false;
        }
        let Ok(ownership_epoch) = self.fold_ownership_epoch(session, point.as_ref()) else {
            return false;
        };
        let Some(transfer_authority) = self.fold_transfer_authority(session, point.as_ref()) else {
            return false;
        };
        // No turn open at the end, as a load's `open_turn` reads it.
        if !matches!(self.open_turn(session, after), Some(None)) {
            return false;
        }
        let from = point.as_ref().map(|p| (p.seq, &p.queue));
        let Some(queue) = self.queue_carry_after(session, from) else { return false };
        // Every copy of a message is written, as a load requires; the append path keeps one per
        // message id, so a copy its own acceptance writes meanwhile is not a second.
        if !super::message_events::recover_message_events_after(self, session, after) {
            return false;
        }
        // Nothing logged while the folds read, and nothing began since that `rollable` did not
        // see: the folds then read every record through `read_to`.
        if self.settled_seq(session) != read_to || !self.rollable(session) {
            return false;
        }
        self.save_restore_point(
            session,
            RestorePoint {
                seq: read_to,
                ownership_epoch,
                transfer_authority,
                queue,
                ..Default::default()
            },
        );
        true
    }

    /// Whether `session` is quiet enough to move its point: its log read, nothing running or
    /// waiting (`busy_with`), nothing kept apart from the log, and no state a load settles that
    /// the log does not show.
    fn rollable(&self, session: &Arc<Session>) -> bool {
        let meta = session.meta();
        session.log_loaded.load(Ordering::SeqCst)
            && !session.log_skipped.load(Ordering::SeqCst)
            && session.caught_up.load(Ordering::SeqCst)
            && !session.restoring.load(Ordering::SeqCst)
            && !session.recovery_pending.load(Ordering::SeqCst)
            && session.ownership_epoch_valid.load(Ordering::SeqCst)
            && meta.fork_seq.is_none()
            && meta.watching.is_none()
            && meta.status != SessionStatus::Closed
            && !meta.subagent_retry_open
            && self.clone_of().is_none()
            && !self.shutting_down()
            && !Self::keeps_unstored(session)
            && self.busy_with(session).is_none()
    }
}

#[cfg(test)]
#[path = "restore_point_tests.rs"]
mod tests;

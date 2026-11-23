//! Which journal record holds a chat's line, for as long as it is not durable
//! (`Store::sync_log_through`). v2's book asks for its chat's log through the place it read
//! before each checkpoint; waiting for the journal's newest record instead held the book behind
//! every line appended since, the next turn's among them, and the actor draws nothing of that
//! turn until the checkpoint returns.

use super::*;
use std::collections::VecDeque;

/// The most records one chat holds here. Past it the oldest leaves and its LSN stays as a bound,
/// so an answer is never earlier than the record, only later.
const HELD: usize = 1024;

/// One chat's log records not yet known durable, in seq order.
#[derive(Default)]
pub(super) struct LogLsns {
    pending: VecDeque<(u64, Lsn)>,
    /// An LSN at or past every record of this chat that is not in `pending` and may not be
    /// durable: one dropped past `HELD`, one out of seq order, or a replay's.
    bound: Lsn,
}

impl LogLsns {
    /// The record at `seq` was appended at `lsn`.
    pub(super) fn note(&mut self, seq: u64, lsn: Lsn, durable: Lsn) {
        self.prune(durable);
        if self.pending.back().is_some_and(|&(last, _)| last >= seq) {
            // Out of seq order (a log written again): every record held so far becomes a bound.
            let newest = self.pending.back().map_or(0, |&(_, lsn)| lsn);
            self.bound = self.bound.max(newest);
            self.pending.clear();
        }
        self.pending.push_back((seq, lsn));
        if self.pending.len() > HELD
            && let Some((_, lsn)) = self.pending.pop_front()
        {
            self.bound = self.bound.max(lsn);
        }
    }

    /// Records of this chat up to `lsn` were journaled without a seq here (a replay's repair).
    pub(super) fn bound(&mut self, lsn: Lsn) {
        self.bound = self.bound.max(lsn);
    }

    /// The LSN to wait for so that the record at `seq` is durable, or `None` when it is already.
    pub(super) fn through(&mut self, seq: u64, durable: Lsn) -> Option<Lsn> {
        self.prune(durable);
        match self.pending.iter().find(|&&(held, _)| held >= seq) {
            Some(&(held, lsn)) if held == seq => Some(lsn),
            // Not held: durable and pruned, or under the bound.
            _ => (self.bound > durable).then_some(self.bound),
        }
    }

    /// Nothing left that may not be durable: the chat's entry can go.
    pub(super) fn done(&self, durable: Lsn) -> bool {
        self.pending.is_empty() && self.bound <= durable
    }

    fn prune(&mut self, durable: Lsn) {
        while self.pending.front().is_some_and(|&(_, lsn)| lsn <= durable) {
            self.pending.pop_front();
        }
    }
}

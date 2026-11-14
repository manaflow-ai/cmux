//! Terminal-lane records are offered, never waited for (main #39865).
//!
//! A terminal's reader and its resize path journal a record while they hold
//! the terminal's geometry and parser locks. A wait for room in the terminal
//! lane there has no time limit, and the writer that makes room can wait
//! behind a request thread that needs the same geometry lock (the request
//! holds the registry, the registry connection and the state lock, then
//! reads the terminal's size). Those three threads then wait on each other
//! for ever, and with them every request of the daemon.
//!
//! So a geometry change and a `terminal.output.gap` marker enter the lane
//! only when it has room. A refused record leaves one owed marker for its
//! terminal generation: reason `journal_queue_full` for a geometry change,
//! the marker's own reason for a marker. The owed marker enters the lane
//! ahead of the terminal's next record once the lane has room (after a full
//! lane: once it has drained to half), ahead of a coalesced checkpoint
//! (mux/journal_retention.rs) and ahead of the last barrier of a shutdown
//! (mux/lifecycle.rs: when the lane is still full there, again after the
//! barrier that empties it).
//! Records refused while a marker is owed are covered by that one marker.

use std::collections::BTreeMap;
use std::sync::Arc;
use std::sync::mpsc::{SyncSender, TrySendError};

use super::{
    JOURNAL_TERMINAL_QUEUE_CAPACITY, JournalIngressEvent, JournalIngressSender, JournalLane,
    QueuedJournalEvent,
};
use crate::panic_free::RecoverPoison;
use crate::resource::TerminalPublicId;

/// The reason of the marker that a refused geometry change leaves.
const QUEUE_FULL_REASON: &str = "journal_queue_full";
/// A terminal that lost a record to a full lane journals again when the lane
/// has drained to half. Resuming at the first free slot would put one marker
/// and one record into every writer batch for as long as a flood lasts.
const RESUME_DEPTH: usize = JOURNAL_TERMINAL_QUEUE_CAPACITY / 2;

/// One terminal generation: the stream a marker belongs to.
type TerminalStream = (Arc<TerminalPublicId>, Arc<str>);

/// The markers the lane owes, at most one per terminal generation.
#[derive(Default)]
pub(super) struct OwedTerminalGaps(BTreeMap<TerminalStream, &'static str>);

/// What became of a record offered to the terminal lane.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum TerminalOffer {
    /// The record is in the lane (or no journal will ever record it: an
    /// ephemeral session, a closed or failed writer).
    Queued,
    /// The record is in the lane, behind the marker the lane owed its
    /// terminal.
    QueuedAfterGap,
    /// The lane was full: the record is not journaled, and the lane now owes
    /// its terminal a marker.
    Owed,
    /// The record is not journaled; a marker the lane already owes its
    /// terminal covers it.
    Covered,
}

impl TerminalOffer {
    /// Whether the terminal's replay boundary moved, so that a later
    /// checkpoint must cover it.
    pub(crate) fn needs_checkpoint(self) -> bool {
        matches!(self, Self::QueuedAfterGap | Self::Owed)
    }
}

enum LaneAnswer {
    Queued,
    Full,
    /// The writer is gone: nothing will record the event.
    Closed,
}

impl JournalIngressSender {
    /// Offers a geometry change or a `terminal.output.gap` marker to the
    /// terminal lane without waiting for room. Callers hold terminal locks.
    pub(crate) fn offer_terminal(&self, event: JournalIngressEvent) -> TerminalOffer {
        let Some(sender) = &self.terminal_sender else { return TerminalOffer::Queued };
        let (stream, reason) = match &event {
            JournalIngressEvent::TerminalResize { terminal_id, generation, .. } => {
                ((terminal_id.clone(), generation.clone()), QUEUE_FULL_REASON)
            }
            JournalIngressEvent::TerminalOutputGap { terminal_id, generation, reason, .. } => {
                ((terminal_id.clone(), generation.clone()), *reason)
            }
            other => {
                debug_assert!(
                    matches!(other, JournalIngressEvent::TerminalResize { .. }),
                    "not reached: only geometry changes and gap markers are offered"
                );
                return TerminalOffer::Queued;
            }
        };
        let _admission = self.state.enqueue_admission.lock().recover_poison();
        if self.state.admission_error().is_some() {
            return TerminalOffer::Queued;
        }
        let mut owed = self.state.owed_terminal_gaps.lock().recover_poison();
        let mut after_gap = false;
        if let Some(owed_reason) = owed.0.get(&stream).copied() {
            let waits_for_half = owed_reason == QUEUE_FULL_REASON
                && self.state.stats.queued_depth(JournalLane::Terminal) > RESUME_DEPTH;
            if waits_for_half
                || matches!(
                    self.try_enqueue_terminal(sender, gap_marker(&stream, owed_reason)),
                    LaneAnswer::Full
                )
            {
                return TerminalOffer::Covered;
            }
            owed.0.remove(&stream);
            after_gap = true;
        }
        match self.try_enqueue_terminal(sender, event) {
            LaneAnswer::Full => {
                owed.0.insert(stream, reason);
                TerminalOffer::Owed
            }
            LaneAnswer::Queued | LaneAnswer::Closed if after_gap => TerminalOffer::QueuedAfterGap,
            LaneAnswer::Queued | LaneAnswer::Closed => TerminalOffer::Queued,
        }
    }

    /// Offers every owed marker to the lane, also above the resume depth: a
    /// checkpoint or the last barrier of a shutdown follows, not a flood.
    /// Returns how many markers the lane still owes.
    pub(crate) fn offer_owed_terminal_gaps(&self) -> usize {
        let Some(sender) = &self.terminal_sender else { return 0 };
        let _admission = self.state.enqueue_admission.lock().recover_poison();
        let mut owed = self.state.owed_terminal_gaps.lock().recover_poison();
        if self.state.admission_error().is_some() {
            owed.0.clear();
            return 0;
        }
        owed.0.retain(|stream, &mut reason| {
            matches!(
                self.try_enqueue_terminal(sender, gap_marker(stream, reason)),
                LaneAnswer::Full
            )
        });
        owed.0.len()
    }

    fn try_enqueue_terminal(
        &self,
        sender: &SyncSender<QueuedJournalEvent>,
        event: JournalIngressEvent,
    ) -> LaneAnswer {
        // Count before the event is visible to the writer, which may drain
        // it before `try_send` returns.
        self.state.stats.enqueued(JournalLane::Terminal);
        match sender.try_send(QueuedJournalEvent { event, completion: None }) {
            Ok(()) => {
                if let Some(wake) = &self.wake_sender {
                    // A full wake channel already holds a wake.
                    let _ = wake.try_send(());
                }
                LaneAnswer::Queued
            }
            Err(TrySendError::Full(_)) => {
                self.state.stats.enqueue_failed(JournalLane::Terminal);
                if self.state.disk_full.is_full() {
                    // Counted with the events a full disk dropped.
                    let _ = self.state.disk_full.drop_event();
                }
                LaneAnswer::Full
            }
            Err(TrySendError::Disconnected(_)) => {
                self.state.stats.enqueue_failed(JournalLane::Terminal);
                LaneAnswer::Closed
            }
        }
    }
}

/// The reason of the marker that a record the writer dropped for good leaves (the store rejected
/// it every time, and nobody waited on it).
const COMMIT_FAILED_REASON: &str = "journal_commit_failed";

impl super::JournalIngressState {
    /// The writer dropped `event` for good. A terminal record leaves an owed marker for its
    /// terminal generation, offered ahead of that terminal's next record or checkpoint, and the
    /// terminal is returned so that its next checkpoint states it again from memory. An owed
    /// marker already there covers it. Other events (barriers) have no row to state again.
    pub(super) fn owe_gap_for_dropped(
        &self,
        event: &JournalIngressEvent,
    ) -> Option<Arc<TerminalPublicId>> {
        let stream = match event {
            JournalIngressEvent::TerminalResize { terminal_id, generation, .. }
            | JournalIngressEvent::TerminalOutputGap { terminal_id, generation, .. } => {
                (terminal_id.clone(), generation.clone())
            }
            #[cfg(test)]
            JournalIngressEvent::TerminalOutput { terminal_id, generation, .. } => {
                (terminal_id.clone(), generation.clone())
            }
            _ => return None,
        };
        let terminal = stream.0.clone();
        self.owed_terminal_gaps
            .lock()
            .recover_poison()
            .0
            .entry(stream)
            .or_insert(COMMIT_FAILED_REASON);
        Some(terminal)
    }
}

fn gap_marker(stream: &TerminalStream, reason: &'static str) -> JournalIngressEvent {
    JournalIngressEvent::TerminalOutputGap {
        terminal_id: stream.0.clone(),
        generation: stream.1.clone(),
        occurred_at_ms: crate::workspace_registry::unix_epoch_ms().unwrap_or(0),
        reason,
    }
}

#[cfg(test)]
mod tests;

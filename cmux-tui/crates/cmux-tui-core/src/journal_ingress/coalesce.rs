//! Terminal output coalescing: a bound on journal records and commits.
//!
//! An agent TUI redraws its cursor about 40 times a second while it waits
//! (`ESC[?2026h ... ESC[?25h ESC[?2026l`, 43 bytes). Each redraw is one PTY
//! read, and the writer committed each read alone as one `terminal.output`
//! row: about 1.2 KiB of metadata, six subject index rows, an event index
//! row, and one `F_FULLFSYNC` commit. On a NIGHTLY daemon with three agent
//! terminals that was 100 commits a second of one record each (server-stats
//! `journal_writer.batch_size` p50 1), and SQLite's WAL checkpoints made it
//! about 21-28 MB/s of disk writes (macOS disk-write reports, 2026-10-20).
//!
//! A batch of plain terminal output now waits up to
//! [`TERMINAL_OUTPUT_COALESCE_WINDOW`] for more output, and output of one
//! terminal folds into that terminal's earlier record in the batch. The
//! writer then commits at most one output-only batch per window, and each
//! batch holds at most one record per terminal run of output. The journal
//! keeps every byte; only the record and commit count changes.
//!
//! The wait ends early for anything that orders against the output or waits
//! for a receipt: a barrier, a resize or gap, any durable-lane event, writer
//! shutdown, or a batch that reaches its byte or chunk bound.

use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};

use super::{
    JOURNAL_DURABLE_BATCH_BYTES, JOURNAL_DURABLE_QUEUE_CAPACITY, JOURNAL_TERMINAL_BATCH_CHUNKS,
    JOURNAL_TERMINAL_QUEUE_CAPACITY, JournalIngressEvent, JournalIngressReceivers, JournalLane,
    QueuedJournalEvent, TERMINAL_OUTPUT_INGRESS_BYTES, drain_lane,
};

/// How long a batch of plain terminal output waits for more output before it
/// commits. A crash can lose at most this much output that no caller waited
/// on; a barrier (`flush_terminal`) still commits at once.
#[cfg(not(test))]
pub(super) const TERMINAL_OUTPUT_COALESCE_WINDOW: Duration = Duration::from_millis(250);
/// Short in unit tests: they read the journal right after sending output and
/// must not each pay the production window.
#[cfg(test)]
pub(super) const TERMINAL_OUTPUT_COALESCE_WINDOW: Duration = Duration::from_millis(20);

/// Unmerged terminal input one held batch may collect: the same 4 MiB bound
/// as an unheld batch of [`JOURNAL_TERMINAL_BATCH_CHUNKS`] full chunks.
const COALESCE_MAX_BYTES: usize = JOURNAL_TERMINAL_BATCH_CHUNKS * TERMINAL_OUTPUT_INGRESS_BYTES;
/// Chunks one held batch may collect: half the terminal queue, so readers
/// keep queue space while the writer holds a batch.
const COALESCE_MAX_CHUNKS: usize = JOURNAL_TERMINAL_QUEUE_CAPACITY / 2;

/// Pushes `next` onto `batch`, folding terminal output into the latest
/// earlier output record of the same terminal and generation. The fold skips
/// back only over other terminals' terminal-lane events. It stops at a
/// barrier, a durable-lane event, or any other event of the same terminal
/// (resize, gap, another generation, or a record with a receipt), so each
/// terminal's stream order and every fence stay as they were sent.
pub(super) fn push_coalesced(batch: &mut Vec<QueuedJournalEvent>, next: QueuedJournalEvent) {
    let target = match (&next.event, &next.completion) {
        (JournalIngressEvent::TerminalOutput { terminal_id, .. }, None) => {
            batch.iter().rposition(|queued| match &queued.event {
                JournalIngressEvent::TerminalOutput { terminal_id: other, .. }
                | JournalIngressEvent::TerminalResize { terminal_id: other, .. }
                | JournalIngressEvent::TerminalOutputGap { terminal_id: other, .. } => {
                    other.as_ref() == terminal_id.as_ref()
                }
                JournalIngressEvent::TerminalBarrier
                | JournalIngressEvent::Frontend { .. }
                | JournalIngressEvent::Producer { .. }
                | JournalIngressEvent::Effect(_) => true,
            })
        }
        _ => None,
    };
    let next = match target {
        Some(index) => match batch[index].merge_output(next) {
            None => return,
            Some(next) => next,
        },
        None => next,
    };
    batch.push(next);
}

/// Holds a batch of plain terminal output for up to
/// [`TERMINAL_OUTPUT_COALESCE_WINDOW`], draining more terminal output into
/// it as readers send it. Durable-lane events drained meanwhile go to
/// `durable`, and their arrival ends the wait.
pub(super) fn hold_terminal_output(
    receivers: &JournalIngressReceivers,
    batch: &mut Vec<QueuedJournalEvent>,
    durable: &mut Vec<QueuedJournalEvent>,
    mut terminal_chunks: usize,
) {
    let deadline = Instant::now() + TERMINAL_OUTPUT_COALESCE_WINDOW;
    loop {
        if !durable.is_empty()
            || receivers.state.closed.load(Ordering::Acquire)
            || terminal_chunks >= COALESCE_MAX_CHUNKS
            || !holds_only_plain_output(batch)
        {
            return;
        }
        let bytes = batch.iter().map(|queued| queued.event.estimated_bytes()).sum::<usize>();
        if bytes >= COALESCE_MAX_BYTES {
            return;
        }
        // Drain first: the first drain of the batch takes at most
        // JOURNAL_TERMINAL_BATCH_CHUNKS events, and the wake for any event
        // queued behind them was already consumed. Waiting before this drain
        // would hold a queued barrier or receipt for the whole window.
        let terminal_drained = drain_lane(
            &receivers.terminal,
            batch,
            COALESCE_MAX_CHUNKS - terminal_chunks,
            COALESCE_MAX_BYTES - bytes,
        );
        let durable_drained = drain_lane(
            &receivers.durable,
            durable,
            JOURNAL_DURABLE_QUEUE_CAPACITY,
            JOURNAL_DURABLE_BATCH_BYTES,
        );
        terminal_chunks += terminal_drained;
        receivers.state.stats.drained(JournalLane::Terminal, terminal_drained);
        receivers.state.stats.drained(JournalLane::Durable, durable_drained);
        if terminal_drained + durable_drained != 0 {
            receivers.state.publish_queue_space();
            continue;
        }
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return;
        }
        // Both lanes were empty after this drain, so any later event posts a
        // new wake; so does writer shutdown. A disconnected wake channel
        // means every sender is gone.
        if receivers.wake.recv_timeout(remaining).is_err() {
            return;
        }
    }
}

/// Whether nothing in `batch` orders against later output or waits for a
/// receipt: only terminal output with no completion.
fn holds_only_plain_output(batch: &[QueuedJournalEvent]) -> bool {
    !batch.is_empty()
        && batch.iter().all(|queued| {
            queued.completion.is_none()
                && matches!(queued.event, JournalIngressEvent::TerminalOutput { .. })
        })
}

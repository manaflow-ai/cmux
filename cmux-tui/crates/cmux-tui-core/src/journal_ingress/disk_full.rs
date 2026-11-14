//! A full disk is not a broken store: `SQLITE_FULL` passes once there is
//! room. The writer keeps the events nobody waits on (at most one batch's
//! worth; more are dropped and counted) and retries them 1 s after the first
//! failure, doubling to every 60 s, until a commit succeeds; journaling then
//! resumes with no restart. Meanwhile every waiter (barrier, producer,
//! frontend event, registry intent) gets the disk-full error at once, whether
//! in the batch, queued or new, and a refused waiter wakes the retry (at most
//! once a second). A background event that finds its queue full is dropped
//! and counted rather than blocking its producer. Shutdown ends the wait.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::Duration;

use super::{JournalIngressReceivers, JournalIngressState, QueuedJournalEvent};
use crate::panic_free::RecoverPoison;

const RETRY_INITIAL: Duration = Duration::from_secs(1);
/// Background events kept while the disk is full: one batch's worth.
const KEEP_MAX: usize =
    super::JOURNAL_TERMINAL_BATCH_CHUNKS + super::JOURNAL_DURABLE_QUEUE_CAPACITY;
/// What a waiter gets while background events wait for disk space.
pub(super) const WAITER_ERROR: &str =
    "the session journal is out of disk space; try again once there is room";
const RETRY_MAX: Duration = Duration::from_secs(60);

/// The schedule, scaled down in tests so the writer tests stay fast.
fn retry_bounds() -> (Duration, Duration) {
    if cfg!(test) {
        (Duration::from_millis(20), Duration::from_millis(200))
    } else {
        (RETRY_INITIAL, RETRY_MAX)
    }
}

fn next_retry_delay(delay: Duration, max: Duration) -> Duration {
    delay.saturating_mul(2).min(max)
}

/// Whether the writer holds background events for a full disk (waiters are
/// refused meanwhile), whether that was logged, and how many background
/// events were dropped since.
#[derive(Default)]
pub(super) struct DiskFullState {
    full: AtomicBool,
    announced: AtomicBool,
    dropped: AtomicU64,
    last_nudge: std::sync::Mutex<Option<std::time::Instant>>,
}

impl DiskFullState {
    pub(super) fn is_full(&self) -> bool {
        self.full.load(Ordering::Acquire)
    }

    /// A waiter was refused: wake the writer's retry wait, at most once per
    /// `RETRY_INITIAL`, so recovery does not wait out the backoff.
    pub(super) fn refused_waiter(&self, state: &JournalIngressState) {
        let now = std::time::Instant::now();
        let mut last = self.last_nudge.lock().recover_poison();
        if last.is_some_and(|last| now.duration_since(last) < retry_bounds().0) {
            return;
        }
        *last = Some(now);
        drop(last);
        state.publish_queue_space();
    }

    /// A background event found its queue full while the disk is full.
    pub(super) fn drop_event(&self) -> String {
        self.dropped.fetch_add(1, Ordering::Relaxed);
        "the session journal is waiting for disk space; this background event was dropped".into()
    }
}

/// `SQLITE_FULL`, or an I/O error for a full disk or quota, anywhere in the
/// chain, also inside an `io::Error` that wraps it (`io::Error::other(e)`:
/// its `source()` skips the payload, `get_ref()` does not).
pub(super) fn is_disk_full(error: &anyhow::Error) -> bool {
    error.chain().any(|cause| is_full_cause(cause, 0))
}

fn is_full_cause(cause: &(dyn std::error::Error + 'static), depth: usize) -> bool {
    if depth > 16 {
        return false;
    }
    if let Some(rusqlite::Error::SqliteFailure(failure, _)) = cause.downcast_ref() {
        return failure.code == rusqlite::ErrorCode::DiskFull;
    }
    let Some(error) = cause.downcast_ref::<std::io::Error>() else { return false };
    #[cfg(unix)]
    if matches!(error.raw_os_error(), Some(libc::ENOSPC | libc::EDQUOT)) {
        return true;
    }
    error.kind() == std::io::ErrorKind::StorageFull
        || error.get_ref().is_some_and(|inner| is_full_cause(inner, depth + 1))
}

/// The writer's backoff while the disk is full. It lives as long as the
/// writer thread; `recovered` resets it at the first successful commit.
pub(super) struct DiskFullRetry {
    delay: Duration,
}

impl DiskFullRetry {
    pub(super) fn new() -> Self {
        Self { delay: retry_bounds().0 }
    }

    /// The batch failed on a full disk: answer the callers that wait on it,
    /// keep the rest, and wait for the next try. The caller holds no mux
    /// and no registry lock. Returns false when admission closed: the
    /// writer has failed what it held and must stop.
    pub(super) fn wait(
        &mut self,
        receivers: &JournalIngressReceivers,
        batch: &mut Vec<QueuedJournalEvent>,
        pending: &mut VecDeque<Vec<QueuedJournalEvent>>,
        summary: &str,
    ) -> bool {
        let state = &receivers.state;
        if !state.disk_full.announced.swap(true, Ordering::AcqRel) {
            let (initial, max) = retry_bounds();
            eprintln!(
                "cmux-tui: the session journal is out of disk space; it retries after {} ms, up \
                 to every {} s, until there is room",
                initial.as_millis(),
                max.as_secs_f32()
            );
        }
        // Under the admission lock: a waiter either sees the flag (refused)
        // or is already queued, so the drain below answers it.
        let raised = {
            let _admission = state.enqueue_admission.lock().recover_poison();
            !state.disk_full.full.swap(true, Ordering::AcqRel)
        };
        if raised {
            // Waiters and producers blocked on a full queue re-check: a
            // waiter is refused, a background event is dropped.
            state.publish_queue_space();
        }
        let error = format!("the session journal is out of disk space: {summary}");
        self.answer_waiters(receivers, batch, pending, &error);
        if batch.is_empty() {
            // Nothing to retry: the next waiter's own commit answers it.
            state.disk_full.full.store(false, Ordering::Release);
            return true;
        }
        let observed = state.queue_space_epoch();
        if !state.closed.load(Ordering::Acquire) {
            wait_for_change(state, observed, self.delay);
        }
        self.delay = next_retry_delay(self.delay, retry_bounds().1);
        if state.closed.load(Ordering::Acquire) {
            let detail = format!("journal commit: {summary}");
            super::stop_writer_after_retry_deadline(
                receivers,
                batch,
                std::mem::take(pending),
                &detail,
            );
            return false;
        }
        true
    }

    /// Fails every waiter in `batch`, `pending` and the queues, and keeps at
    /// most [`KEEP_MAX`] background events in `batch` (the rest are dropped
    /// and counted). Each queue is drained at most its capacity, so a
    /// producer that refills it meanwhile never makes this longer.
    fn answer_waiters(
        &self,
        receivers: &JournalIngressReceivers,
        batch: &mut Vec<QueuedJournalEvent>,
        pending: &mut VecDeque<Vec<QueuedJournalEvent>>,
        error: &str,
    ) {
        let state = &receivers.state;
        let held = std::mem::take(batch).into_iter().chain(pending.drain(..).flatten());
        let (mut kept, mut dropped) = (Vec::new(), 0_u64);
        let mut sort = |queued: QueuedJournalEvent| {
            if queued.completion.is_some() {
                super::complete_batch_error(std::slice::from_ref(&queued), error.to_string());
            } else if kept.len() < KEEP_MAX {
                kept.push(queued);
            } else {
                // Its terminal owes a gap marker, offered ahead of its next record, a
                // checkpoint or the last barrier of a shutdown (terminal_offer.rs).
                state.owe_gap_for_dropped(&queued.event);
                dropped += 1;
            }
        };
        held.for_each(&mut sort);
        let mut drained = [0_usize; 2];
        let lanes = [
            (&receivers.terminal, super::JOURNAL_TERMINAL_QUEUE_CAPACITY),
            (&receivers.durable, super::JOURNAL_DURABLE_QUEUE_CAPACITY),
        ];
        for (count, (lane, capacity)) in drained.iter_mut().zip(lanes) {
            while *count < capacity
                && let Ok(queued) = lane.try_recv()
            {
                *count += 1;
                sort(queued);
            }
        }
        state.stats.drained(super::JournalLane::Terminal, drained[0]);
        state.stats.drained(super::JournalLane::Durable, drained[1]);
        if drained[0] + drained[1] != 0 {
            state.publish_queue_space();
        }
        state.disk_full.dropped.fetch_add(dropped, Ordering::Relaxed);
        *batch = kept;
    }

    /// A commit succeeded.
    pub(super) fn recovered(&mut self, state: &JournalIngressState) {
        self.delay = retry_bounds().0;
        state.disk_full.full.store(false, Ordering::Release);
        if state.disk_full.announced.swap(false, Ordering::AcqRel) {
            let dropped = state.disk_full.dropped.swap(0, Ordering::Relaxed);
            eprintln!(
                "cmux-tui: the session journal has disk space again and resumed ({dropped} \
                 background event(s) dropped meanwhile)"
            );
        }
    }
}

#[cfg(test)]
impl super::JournalIngressSender {
    pub(crate) fn disk_full_for_test(&self) -> bool {
        self.state.disk_full.is_full()
    }
}

/// Sleeps `timeout`, or less when the queue-space epoch moves (admission
/// closed, the writer failed).
fn wait_for_change(state: &JournalIngressState, observed: u64, timeout: Duration) {
    let epoch = state.queue_space_epoch.lock().recover_poison();
    let _ = state
        .queue_space_changed
        .wait_timeout_while(epoch, timeout, |epoch| *epoch == observed)
        .recover_poison();
}

#[cfg(test)]
mod tests;

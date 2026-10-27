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
mod tests {
    use std::sync::Arc;
    use std::sync::mpsc::sync_channel;
    use std::time::Instant;

    use super::*;
    use crate::Mux;
    use crate::journal_ingress::{
        JOURNAL_TERMINAL_QUEUE_CAPACITY, JournalIngressEvent, JournalIngressSender,
    };
    use crate::resource::TerminalPublicId;

    #[test]
    fn the_retry_schedule_runs_from_one_second_to_a_minute() {
        let mut delay = RETRY_INITIAL;
        let mut seen = vec![delay.as_secs()];
        for _ in 0..8 {
            delay = next_retry_delay(delay, RETRY_MAX);
            seen.push(delay.as_secs());
        }
        assert_eq!(seen, [1, 2, 4, 8, 16, 32, 60, 60, 60]);
    }

    #[test]
    fn a_full_disk_is_told_from_a_store_error() {
        use std::io::{Error, ErrorKind};
        let sqlite = |code| rusqlite::Error::SqliteFailure(rusqlite::ffi::Error::new(code), None);
        let full = || sqlite(rusqlite::ffi::SQLITE_FULL);
        assert!(is_disk_full(&anyhow::Error::from(full()).context("append session journal")));
        assert!(!is_disk_full(&sqlite(rusqlite::ffi::SQLITE_CONSTRAINT).into()));
        assert!(!is_disk_full(&anyhow::anyhow!("database or disk is full")));
        // Also wrapped in another io::Error, whose `source()` skips the payload.
        let mut wrapped = vec![Error::from(ErrorKind::StorageFull), Error::other(full())];
        #[cfg(unix)]
        wrapped.extend([libc::ENOSPC, libc::EDQUOT].map(Error::from_raw_os_error));
        for error in wrapped.into_iter().map(Error::other) {
            let text = error.to_string();
            assert!(is_disk_full(&anyhow::Error::from(error).context("write")), "{text}");
        }
        assert!(!is_disk_full(&Error::other(Error::from(ErrorKind::NotFound)).into()));
    }

    #[test]
    fn a_background_event_is_dropped_not_blocked_while_the_disk_is_full() {
        let (sender, _receivers) = JournalIngressSender::new(true);
        sender.state.disk_full.full.store(true, Ordering::Release);
        let terminal_id = Arc::new(term(31));
        let event = || JournalIngressEvent::TerminalOutput {
            terminal_id: terminal_id.clone(),
            generation: Arc::from("disk-full-generation"),
            occurred_at_ms: 1,
            bytes: b"x".to_vec(),
        };
        for _ in 0..JOURNAL_TERMINAL_QUEUE_CAPACITY {
            sender.send(event());
        }
        assert_eq!(sender.state.disk_full.dropped.load(Ordering::Relaxed), 0);
        // The queue is full and nothing drains it: this returned only by
        // dropping the event (before, it waited for room forever).
        sender.send(event());
        assert_eq!(sender.state.disk_full.dropped.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn answering_waiters_drains_a_bounded_amount_while_producers_refill() {
        let (sender, receivers) = JournalIngressSender::new(true);
        let receivers = receivers.unwrap();
        let terminal_id = Arc::new(term(33));
        let event = move || JournalIngressEvent::TerminalOutput {
            terminal_id: terminal_id.clone(),
            generation: Arc::from("refill-generation"),
            occurred_at_ms: 1,
            bytes: b"x".to_vec(),
        };
        // A waiter queued behind the background events.
        let (completion, result) = sync_channel(1);
        let barrier = QueuedJournalEvent {
            event: JournalIngressEvent::TerminalBarrier,
            completion: Some(super::super::JournalIngressCompletion::Durable {
                sender: completion,
                deadline: Instant::now() + Duration::from_secs(30),
                commit_fence: Arc::default(),
            }),
        };
        let terminal = sender.terminal_sender.as_ref().unwrap().clone();
        terminal.try_send(barrier).ok().unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let refill = {
            let (stop, sender) = (stop.clone(), terminal);
            std::thread::spawn(move || {
                while !stop.load(Ordering::Acquire) {
                    let queued = QueuedJournalEvent { event: event(), completion: None };
                    let _ = sender.try_send(queued);
                }
            })
        };
        let (mut batch, mut pending) = (Vec::new(), VecDeque::new());
        let started = Instant::now();
        DiskFullRetry::new().answer_waiters(&receivers, &mut batch, &mut pending, "full");
        let elapsed = started.elapsed();
        stop.store(true, Ordering::Release);
        refill.join().unwrap();
        assert!(elapsed < Duration::from_secs(1), "{elapsed:?}");
        assert!(batch.len() <= KEEP_MAX && batch.iter().all(|queued| queued.completion.is_none()));
        assert_eq!(result.try_recv().expect("the waiter is answered").unwrap_err(), "full");
    }

    #[test]
    fn a_full_disk_pauses_the_journal_writer_until_there_is_room() {
        let id = crate::workspace_registry::new_uuid_v4();
        let root = std::env::temp_dir().join(format!("cmux-journal-disk-full-{id}"));
        let mux =
            Mux::open_persistent("disk-full", crate::SurfaceOptions::default(), &root).unwrap();
        let (failed, failed_receiver) = sync_channel(1);
        mux.install_journal_failure_notifier_for_test(failed);
        mux.flush_terminal_journal().unwrap();
        // The database may not grow: a commit that needs a page fails with
        // SQLITE_FULL, as on a full disk.
        mux.set_registry_max_page_count_for_test(None).unwrap();
        let (terminal_id, generation) = (Arc::new(term(32)), Arc::<str>::from("disk-full"));
        let while_full = vec![b'f'; 1024 * 1024];
        mux.journal_terminal_output(terminal_id.clone(), generation.clone(), while_full.clone());
        // A barrier sent before the writer holds the output, and one after,
        // are answered at once; the writer does not stop.
        for _ in 0..2 {
            let started = Instant::now();
            let error = mux.flush_terminal_journal().unwrap_err().to_string();
            assert!(error.contains("out of disk space"), "{error}");
            assert!(started.elapsed() < Duration::from_secs(1), "{:?}", started.elapsed());
        }
        assert!(mux.journal_disk_full_for_test() && failed_receiver.try_recv().is_err());
        // Room again: a refused waiter wakes the writer, whose next try
        // commits the kept output; new output follows it.
        mux.set_registry_max_page_count_for_test(Some(1 << 30)).unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        while mux.journal_disk_full_for_test() {
            assert!(Instant::now() < deadline, "the writer did not resume once there was room");
            let _ = mux.flush_terminal_journal();
            std::thread::sleep(Duration::from_millis(20));
        }
        mux.journal_terminal_output(terminal_id, generation, b"after".to_vec());
        mux.flush_terminal_journal().unwrap();
        let records = mux.session_journal_after(0, 1024).unwrap().records.into_iter();
        let output = records.filter_map(|record| record.terminal_output).collect::<Vec<_>>();
        assert_eq!(output.concat(), [while_full, b"after".to_vec()].concat());
        assert!(failed_receiver.try_recv().is_err() && !mux.daemon_shutdown_requested());
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }

    fn term(index: u128) -> TerminalPublicId {
        TerminalPublicId::parse(format!("term_{index:032x}")).unwrap()
    }
}

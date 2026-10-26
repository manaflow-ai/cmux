//! A full disk is not a broken store.
//!
//! SQLite answers `SQLITE_FULL` while the disk (or the user's quota) is
//! full, and the same write succeeds once there is room again. Before, the
//! writer treated it like a store that rejects the write: a batch of
//! background events failed six quick retries, the writer stopped, and the
//! session journal stayed off until the daemon restarted. Now the writer
//! keeps the batch and tries it again, 1 s after the first failure and
//! doubling to every 60 s, for as long as the disk stays full; the first
//! commit that succeeds turns journaling back on.
//!
//! What stays bounded meanwhile:
//! - Callers that wait on a receipt (barriers, producers, frontend events,
//!   registry intents) are answered at once with the disk-full error, as a
//!   store error answered them before. Only events nobody waits on are kept.
//! - The kept batch is one batch (at most 64 terminal chunks and 256
//!   durable events), and the lanes keep their bounded queues.
//! - A background event (terminal resize or output gap) that finds its full
//!   queue while the disk is full is dropped and counted, instead of
//!   blocking its producer until there is room. The count is logged when
//!   journaling resumes.
//!
//! The retry wait ends early when admission closes (shutdown), and the
//! writer then stops as it does at a deadline during shutdown.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::Duration;

use super::{JournalIngressReceivers, JournalIngressState, QueuedJournalEvent};
use crate::panic_free::RecoverPoison;

const RETRY_INITIAL: Duration = Duration::from_secs(1);
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

/// Whether the last commit failed on a full disk, and how many background
/// events were dropped since.
#[derive(Default)]
pub(super) struct DiskFullState {
    full: AtomicBool,
    dropped: AtomicU64,
}

impl DiskFullState {
    pub(super) fn is_full(&self) -> bool {
        self.full.load(Ordering::Acquire)
    }

    /// A background event found its queue full while the disk is full.
    pub(super) fn drop_event(&self) -> String {
        self.dropped.fetch_add(1, Ordering::Relaxed);
        "the session journal is waiting for disk space; this background event was dropped".into()
    }
}

/// `SQLITE_FULL`, or an I/O error for a full disk or quota, anywhere in the
/// chain.
pub(super) fn is_disk_full(error: &anyhow::Error) -> bool {
    error.chain().any(|cause| {
        if let Some(rusqlite::Error::SqliteFailure(failure, _)) = cause.downcast_ref() {
            return failure.code == rusqlite::ErrorCode::DiskFull;
        }
        cause.downcast_ref::<std::io::Error>().is_some_and(is_storage_full)
    })
}

fn is_storage_full(error: &std::io::Error) -> bool {
    #[cfg(unix)]
    if matches!(error.raw_os_error(), Some(libc::ENOSPC | libc::EDQUOT)) {
        return true;
    }
    error.kind() == std::io::ErrorKind::StorageFull
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
        if !state.disk_full.full.swap(true, Ordering::AcqRel) {
            let (initial, max) = retry_bounds();
            eprintln!(
                "cmux-tui: the session journal is out of disk space; it retries after {} ms, up \
                 to every {} s, until there is room",
                initial.as_millis(),
                max.as_secs_f32()
            );
            // Producers blocked on a full queue re-check, and drop.
            state.publish_queue_space();
        }
        let (waiting, kept): (Vec<_>, Vec<_>) =
            std::mem::take(batch).into_iter().partition(|queued| queued.completion.is_some());
        super::complete_batch_error(
            &waiting,
            format!("the session journal is out of disk space: {summary}"),
        );
        *batch = kept;
        if batch.is_empty() {
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

    /// A commit succeeded.
    pub(super) fn recovered(&mut self, state: &JournalIngressState) {
        self.delay = retry_bounds().0;
        if state.disk_full.full.swap(false, Ordering::AcqRel) {
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
        let full = rusqlite::Error::SqliteFailure(
            rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_FULL),
            Some("database or disk is full".into()),
        );
        assert!(is_disk_full(&anyhow::Error::from(full).context("append session journal")));
        #[cfg(unix)]
        assert!(is_disk_full(&std::io::Error::from_raw_os_error(libc::ENOSPC).into()));
        let constraint = rusqlite::Error::SqliteFailure(
            rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_CONSTRAINT),
            None,
        );
        assert!(!is_disk_full(&constraint.into()));
        assert!(!is_disk_full(&anyhow::anyhow!("database or disk is full")));
    }

    #[test]
    fn a_background_event_is_dropped_not_blocked_while_the_disk_is_full() {
        let (sender, _receivers) = JournalIngressSender::new(true);
        sender.state.disk_full.full.store(true, Ordering::Release);
        let terminal_id = Arc::new(TerminalPublicId::parse(format!("term_{:032x}", 31)).unwrap());
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
    fn a_full_disk_pauses_the_journal_writer_until_there_is_room() {
        let root = std::env::temp_dir().join(format!(
            "cmux-journal-disk-full-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        let mux =
            Mux::open_persistent("journal-disk-full", crate::SurfaceOptions::default(), &root)
                .unwrap();
        let (failed, failed_receiver) = sync_channel(1);
        mux.install_journal_failure_notifier_for_test(failed);
        mux.flush_terminal_journal().unwrap();

        // The database may not grow: every commit that needs a page fails
        // with SQLITE_FULL, as on a full disk.
        mux.set_registry_max_page_count_for_test(None);
        let terminal_id = Arc::new(TerminalPublicId::parse(format!("term_{:032x}", 32)).unwrap());
        let generation: Arc<str> = Arc::from("disk-full-generation");
        let while_full = vec![b'f'; 1024 * 1024];
        mux.journal_terminal_output(terminal_id.clone(), generation.clone(), while_full.clone());
        // A barrier behind it fails (disk full, or its deadline while the
        // writer holds the output), and the writer does not stop.
        let started = Instant::now();
        assert!(mux.flush_terminal_journal().is_err());
        assert!(started.elapsed() < Duration::from_secs(5));
        assert!(mux.journal_disk_full_for_test());
        assert!(
            failed_receiver.try_recv().is_err(),
            "a full disk must not fail the journal writer for good"
        );

        // Room again: the kept output commits, and new output follows it.
        mux.set_registry_max_page_count_for_test(Some(1 << 30));
        mux.flush_terminal_journal().unwrap();
        mux.journal_terminal_output(terminal_id, generation, b"after".to_vec());
        mux.flush_terminal_journal().unwrap();
        assert!(!mux.journal_disk_full_for_test());
        let outputs = mux
            .session_journal_after(0, 4096)
            .unwrap()
            .records
            .into_iter()
            .filter(|record| record.kind == "terminal.output")
            .filter_map(|record| record.terminal_output)
            .collect::<Vec<_>>();
        let mut expected = while_full;
        expected.extend_from_slice(b"after");
        assert_eq!(outputs.concat(), expected, "the output kept while the disk was full commits");
        assert!(failed_receiver.try_recv().is_err());
        assert!(!mux.daemon_shutdown_requested());
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }
}

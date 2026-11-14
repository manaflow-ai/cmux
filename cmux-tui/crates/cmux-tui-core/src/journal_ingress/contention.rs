//! Contention on the session journal is transient.
//!
//! The journal writer shares the workspace registry mutex and the SQLite
//! database with every other mutation. Under load (hundreds of terminals
//! starting at once) a batch can wait past its deadline for that lock. That
//! is congestion, not a broken store: the writer gives the callers that wait
//! on the batch their timeout, keeps the terminal output that nobody waits
//! on, and retries it. Only other errors (a store that rejects the write) can
//! fail the writer for good. Before, one 2 s wait failed the writer, every
//! terminal reader then stopped the daemon, and its hosts were left without
//! an owner (about 260 terminals on a 32-vCPU Linux VM).

use std::collections::VecDeque;
use std::sync::atomic::Ordering;
use std::time::Instant;

use super::{JournalIngressReceivers, QueuedJournalEvent};

/// A lock or commit deadline that expired while another writer held the
/// workspace registry. Callers downcast to tell it from a store error.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct JournalContention(pub(crate) &'static str);

impl JournalContention {
    pub(crate) const MUTEX_DEADLINE: Self = Self("mutex deadline expired");
    pub(crate) const COMMIT_DEADLINE: Self = Self("session journal commit deadline expired");
}

impl std::fmt::Display for JournalContention {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.0)
    }
}

impl std::error::Error for JournalContention {}

/// Whether `error` is congestion that a later attempt can succeed past: a
/// registry lock or commit deadline, a busy or locked SQLite database, or the
/// deadline's own progress-handler interrupt (once `deadline` passed). All of
/// them end before `COMMIT`, so the transaction rolled back and a retry
/// cannot duplicate a row.
pub(super) fn is_transient(error: &anyhow::Error, deadline: Instant) -> bool {
    error.chain().any(|cause| {
        if cause.downcast_ref::<JournalContention>().is_some() {
            return true;
        }
        let Some(rusqlite::Error::SqliteFailure(failure, _)) = cause.downcast_ref() else {
            return false;
        };
        match failure.code {
            rusqlite::ErrorCode::DatabaseBusy | rusqlite::ErrorCode::DatabaseLocked => true,
            rusqlite::ErrorCode::OperationInterrupted => Instant::now() >= deadline,
            _ => false,
        }
    })
}

/// A batch passed its deadline under contention: fail the events whose
/// callers wait (they get the timeout), keep the terminal output nobody
/// waits on, and give it a new deadline. Once admission is closed
/// (shutdown) it stops the writer as before and returns false, so no output
/// commits after the shutdown's final barrier.
pub(super) fn expire(
    receivers: &JournalIngressReceivers,
    batch: &mut Vec<QueuedJournalEvent>,
    pending: &mut VecDeque<Vec<QueuedJournalEvent>>,
    retry_deadline: &mut Instant,
    detail: &str,
) -> bool {
    if receivers.state.closed.load(Ordering::Acquire) {
        super::stop_writer_after_retry_deadline(receivers, batch, std::mem::take(pending), detail);
        return false;
    }
    receivers.state.stats.deadline_expired();
    receivers.state.stats.commit_late(format!(
        "a commit passed its {} ms deadline: {detail}",
        receivers.state.durable_wait().as_millis()
    ));
    let (waiting, kept): (Vec<_>, Vec<_>) =
        std::mem::take(batch).into_iter().partition(|queued| queued.completion.is_some());
    super::complete_batch_error(
        &waiting,
        format!(
            "session journal writer timed out after {} ms: {detail}",
            receivers.state.durable_wait().as_millis()
        ),
    );
    *batch = kept;
    *retry_deadline = Instant::now() + receivers.state.durable_wait();
    true
}

#[cfg(test)]
mod tests;

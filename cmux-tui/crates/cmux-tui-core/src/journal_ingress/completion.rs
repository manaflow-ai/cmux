//! Delivering a batch's results to the requests that wait on them.

use super::{JournalIngressCompletion, QueuedJournalEvent};

/// The writer's result for one batch event, in batch order.
#[derive(Debug)]
pub(crate) enum JournalBatchReceipt {
    /// Terminal bytes, barriers and frontend events: durable, no receipt.
    None,
}

pub(super) fn complete_batch_success(
    batch: &[QueuedJournalEvent],
    commits: Vec<JournalBatchReceipt>,
) {
    if commits.len() != batch.len() {
        complete_batch_error(batch, "session journal returned an incomplete batch".into());
        return;
    }
    for (queued, _commit) in batch.iter().zip(commits) {
        match &queued.completion {
            Some(JournalIngressCompletion::Durable { sender, .. }) => {
                let _ = sender.send(Ok(()));
            }
            None => {}
        }
    }
}

pub(super) fn complete_batch_error(batch: &[QueuedJournalEvent], error: String) {
    for queued in batch {
        match &queued.completion {
            Some(JournalIngressCompletion::Durable { sender, .. }) => {
                let _ = sender.send(Err(error.clone()));
            }
            None => {}
        }
    }
}

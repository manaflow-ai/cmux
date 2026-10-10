//! Delivering a batch's results to the requests that wait on them.

use super::{JournalIngressCompletion, QueuedJournalEvent};

/// The writer's result for one batch event, in batch order.
#[derive(Debug)]
pub(crate) enum JournalBatchReceipt {
    /// Terminal bytes, barriers and frontend events: durable, no receipt.
    None,
    /// A producer append receipt.
    Append(crate::JournalAppendCommit),
    /// An effect receipt commit: its receipt, or the error of an intent the
    /// writer rolled back to its savepoint while the rest of the batch
    /// committed.
    Effect(Result<crate::workspace_registry::EffectCommitReceipt, String>),
}

pub(super) fn complete_batch_success(
    batch: &[QueuedJournalEvent],
    commits: Vec<JournalBatchReceipt>,
) {
    if commits.len() != batch.len() {
        complete_batch_error(batch, "session journal returned an incomplete batch".into());
        return;
    }
    for (queued, commit) in batch.iter().zip(commits) {
        match &queued.completion {
            Some(JournalIngressCompletion::Durable { sender, .. }) => {
                let _ = sender.send(Ok(()));
            }
            Some(JournalIngressCompletion::Producer { sender, .. }) => {
                let result = match commit {
                    JournalBatchReceipt::Append(commit) => Ok(commit),
                    _ => Err("session journal omitted a producer append receipt".into()),
                };
                let _ = sender.send(result);
            }
            Some(JournalIngressCompletion::Effect { sender, .. }) => {
                let result = match commit {
                    JournalBatchReceipt::Effect(result) => result,
                    _ => Err("session journal omitted an effect commit receipt".into()),
                };
                let _ = sender.send(result);
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
            Some(JournalIngressCompletion::Producer { sender, .. }) => {
                let _ = sender.send(Err(error.clone()));
            }
            Some(JournalIngressCompletion::Effect { sender, .. }) => {
                let _ = sender.send(Err(error.clone()));
            }
            None => {}
        }
    }
}

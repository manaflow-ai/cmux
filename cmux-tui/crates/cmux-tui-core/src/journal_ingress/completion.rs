//! Delivering a batch's results to the requests that wait on them.

use std::sync::Arc;
use std::sync::atomic::AtomicU8;
use std::time::Instant;

use cmux_threads::sync::mpsc::SyncSender;

use super::QueuedJournalEvent;

/// Where the writer answers a request that waits for its event: a channel
/// that carries the writer's QoS (`cmux_threads::sync`), so a receipt sent
/// below the waiting request is a recorded `priority-inversion` site.
#[derive(Debug)]
pub(super) enum JournalIngressCompletion {
    Durable {
        sender: SyncSender<Result<(), String>>,
        deadline: Instant,
        commit_fence: Arc<AtomicU8>,
    },
    Producer {
        sender: SyncSender<Result<crate::JournalAppendCommit, String>>,
        deadline: Instant,
        commit_fence: Arc<AtomicU8>,
    },
    Effect {
        sender: SyncSender<Result<crate::workspace_registry::RegistryReceipt, String>>,
        deadline: Instant,
        commit_fence: Arc<AtomicU8>,
        /// Admitted (admit then reply): its request replied before this
        /// commit, so no reply asks for the commit's flush; the writer does.
        admitted: bool,
    },
}

impl JournalIngressCompletion {
    pub(super) fn deadline(&self) -> Instant {
        match self {
            Self::Durable { deadline, .. }
            | Self::Producer { deadline, .. }
            | Self::Effect { deadline, .. } => *deadline,
        }
    }

    /// True when no request waits for this commit to reply: it asks for
    /// its own flush once committed.
    pub(super) fn replied_before_commit(&self) -> bool {
        matches!(self, Self::Effect { admitted: true, .. })
    }

    pub(super) fn commit_fence(&self) -> &AtomicU8 {
        match self {
            Self::Durable { commit_fence, .. }
            | Self::Producer { commit_fence, .. }
            | Self::Effect { commit_fence, .. } => commit_fence,
        }
    }
}

/// The writer's result for one batch event, in batch order.
#[derive(Debug)]
pub(crate) enum JournalBatchReceipt {
    /// Terminal bytes, barriers and frontend events: durable, no receipt.
    None,
    /// A producer append receipt.
    Append(crate::JournalAppendCommit),
    /// A registry commit intent: its receipt, or the error of an intent the
    /// writer rolled back to its savepoint while the rest of the batch
    /// committed.
    Effect(Result<crate::workspace_registry::RegistryReceipt, String>),
}

/// True when no request reply asks for the flush of `batch` once it
/// committed: no request waits for it (background events), or it carries an
/// admitted commit, whose request replied before the commit.
pub(super) fn no_reply_flushes(batch: &[QueuedJournalEvent]) -> bool {
    batch.iter().all(|queued| queued.completion.is_none())
        || batch.iter().any(|queued| {
            queued.completion.as_ref().is_some_and(JournalIngressCompletion::replied_before_commit)
        })
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

#[cfg(test)]
mod tests {
    use cmux_threads::sync::mpsc::sync_channel;

    use super::super::{COMMIT_PENDING, JournalIngressEvent};
    use super::*;

    fn queued(completion: Option<JournalIngressCompletion>) -> QueuedJournalEvent {
        QueuedJournalEvent { event: JournalIngressEvent::TerminalBarrier, completion }
    }

    fn effect(admitted: bool) -> Option<JournalIngressCompletion> {
        let (sender, _receiver) = sync_channel(1);
        Some(JournalIngressCompletion::Effect {
            sender,
            deadline: Instant::now(),
            commit_fence: Arc::new(AtomicU8::new(COMMIT_PENDING)),
            admitted,
        })
    }

    /// An admitted commit's request replied before the commit, so the
    /// writer asks for the flush that reply used to ask for (p05-ipc-120).
    #[test]
    fn the_writer_flushes_a_batch_no_reply_follows() {
        assert!(no_reply_flushes(&[queued(None)]), "background events");
        assert!(!no_reply_flushes(&[queued(None), queued(effect(false))]), "a waiting request");
        assert!(no_reply_flushes(&[queued(effect(false)), queued(effect(true))]), "admitted");
    }
}

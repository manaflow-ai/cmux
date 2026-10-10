//! Registry commits sent to the journal writer as batch intents (effect
//! receipts, terminal records, workspace registry revisions).
//!
//! The request thread waits for the receipt with the same bounded deadline
//! and commit fence as a producer receipt (`JOURNAL_DURABLE_WAIT`, then at
//! most `JOURNAL_COMMIT_RESULT_WAIT` for a commit the writer already
//! admitted). A writer error, a dropped receipt or an expired deadline
//! returns an error; nothing waits without a bound. A commit the writer
//! admitted but did not answer in time is indeterminate: the caller keeps
//! its receipt channel ([`PendingRegistryReceipt`]) and settles it later.

use std::sync::Arc;
use std::sync::atomic::AtomicU8;
use std::sync::mpsc::{Receiver, TryRecvError, sync_channel};
use std::time::Instant;

use super::{
    COMMIT_PENDING, JOURNAL_DURABLE_WAIT, JournalCommitIndeterminate, JournalIngressCompletion,
    JournalIngressEvent, JournalIngressSender, JournalWriterOwner, QueuedJournalEvent,
};
use crate::workspace_registry::{RegistryIntent, RegistryReceipt};

/// The result of offering a registry commit to the journal writer.
pub(crate) enum EffectSend {
    /// The writer took the intent; its receipt or the error (bounded wait).
    Sent(anyhow::Result<RegistryReceipt>),
    /// The writer admitted the intent's batch but its result did not arrive
    /// in time: it may still commit. The receipt arrives on the channel.
    Indeterminate(anyhow::Error, PendingRegistryReceipt),
    /// The writer is disabled, stopped, failed, not running yet, or this is
    /// the writer thread itself, or the durable lane refused the event
    /// (deadline, admission closed). Nothing was queued: commit it locally.
    NotQueued(Box<RegistryIntent>),
}

/// The receipt channel of an indeterminate registry commit.
pub(crate) struct PendingRegistryReceipt(Receiver<Result<RegistryReceipt, String>>);

impl PendingRegistryReceipt {
    /// The receipt once the writer answered, `None` while it has not. A
    /// writer that dropped the channel without an answer reports an error.
    pub(crate) fn try_take(&self) -> Option<Result<RegistryReceipt, String>> {
        match self.0.try_recv() {
            Ok(result) => Some(result),
            Err(TryRecvError::Empty) => None,
            Err(TryRecvError::Disconnected) => {
                Some(Err("the session journal writer dropped the receipt".into()))
            }
        }
    }

    /// [`Self::try_take`], waiting at most `timeout` for the answer.
    pub(crate) fn wait_take(
        &self,
        timeout: std::time::Duration,
    ) -> Option<Result<RegistryReceipt, String>> {
        match self.0.recv_timeout(timeout) {
            Ok(result) => Some(result),
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => None,
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                Some(Err("the session journal writer dropped the receipt".into()))
            }
        }
    }
}

impl JournalIngressSender {
    /// True when [`Self::send_effect`] would queue: the durable lane exists,
    /// the writer runs, and the caller is not the writer thread.
    pub(crate) fn accepts_effects(&self) -> bool {
        self.durable_sender.is_some()
            && self.state.admission_error().is_none()
            && self.writer.lock().is_ok_and(|owner| {
                matches!(
                    &*owner,
                    JournalWriterOwner::Running(writer)
                        if writer.thread.thread().id() != std::thread::current().id()
                )
            })
    }

    pub(crate) fn send_effect(&self, intent: RegistryIntent) -> EffectSend {
        let intent = Box::new(intent);
        let Some(sender) = &self.durable_sender else { return EffectSend::NotQueued(intent) };
        if !self.accepts_effects() {
            return EffectSend::NotQueued(intent);
        }
        let (completion, result) = sync_channel(1);
        let deadline = Instant::now() + JOURNAL_DURABLE_WAIT;
        let commit_fence = Arc::new(AtomicU8::new(COMMIT_PENDING));
        if let Err((error, event)) = self.enqueue_until_or_return(
            sender,
            QueuedJournalEvent {
                event: JournalIngressEvent::Effect(intent),
                completion: Some(JournalIngressCompletion::Effect {
                    sender: completion,
                    deadline,
                    commit_fence: commit_fence.clone(),
                }),
            },
            deadline,
        ) {
            // Not queued (deadline, admission closed, writer gone): hand the
            // intent back so a caller without state can commit it locally,
            // as before the writer took registry commits.
            return match event.event {
                JournalIngressEvent::Effect(intent) => EffectSend::NotQueued(intent),
                _ => {
                    debug_assert!(false, "the durable lane returned a different event");
                    EffectSend::Sent(Err(anyhow::Error::msg(error)))
                }
            };
        }
        let waited = Instant::now();
        let outcome = self.wait_for_commit_result(
            &result,
            deadline,
            &commit_fence,
            "waiting for a session journal registry commit receipt",
        );
        self.state.stats.receipt_waited(waited.elapsed());
        match outcome {
            Err(error) if error.downcast_ref::<JournalCommitIndeterminate>().is_some() => {
                EffectSend::Indeterminate(error, PendingRegistryReceipt(result))
            }
            outcome => EffectSend::Sent(outcome),
        }
    }
}

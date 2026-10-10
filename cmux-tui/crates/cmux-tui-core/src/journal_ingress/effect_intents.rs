//! Effect receipt commits sent to the journal writer as batch intents.
//!
//! The request thread waits for the receipt with the same bounded deadline
//! and commit fence as a producer receipt (`JOURNAL_DURABLE_WAIT`, then at
//! most `JOURNAL_COMMIT_RESULT_WAIT` for a commit the writer already
//! admitted). A writer error, a dropped receipt or an expired deadline
//! returns an error; nothing waits without a bound.

use std::sync::Arc;
use std::sync::atomic::AtomicU8;
use std::sync::mpsc::sync_channel;
use std::time::Instant;

use super::{
    COMMIT_PENDING, JOURNAL_DURABLE_WAIT, JournalIngressCompletion, JournalIngressEvent,
    JournalIngressSender, JournalWriterOwner, QueuedJournalEvent,
};
use crate::workspace_registry::{EffectCommitIntent, EffectCommitReceipt};

/// The result of offering an effect commit to the journal writer.
pub(crate) enum EffectSend {
    /// The writer took the intent; its receipt or the error (bounded wait).
    Sent(anyhow::Result<EffectCommitReceipt>),
    /// The writer is disabled, stopped, failed, not running yet, or this is
    /// the writer thread itself. Nothing was queued: commit it locally.
    NotQueued(Box<EffectCommitIntent>),
}

impl JournalIngressSender {
    pub(crate) fn send_effect(&self, intent: EffectCommitIntent) -> EffectSend {
        let intent = Box::new(intent);
        let Some(sender) = &self.durable_sender else { return EffectSend::NotQueued(intent) };
        let writer_running = self.writer.lock().is_ok_and(|owner| {
            matches!(
                &*owner,
                JournalWriterOwner::Running(writer)
                    if writer.thread.thread().id() != std::thread::current().id()
            )
        });
        if !writer_running || self.state.admission_error().is_some() {
            return EffectSend::NotQueued(intent);
        }
        let (completion, result) = sync_channel(1);
        let deadline = Instant::now() + JOURNAL_DURABLE_WAIT;
        let commit_fence = Arc::new(AtomicU8::new(COMMIT_PENDING));
        if let Err(error) = self.enqueue_until(
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
            return EffectSend::Sent(Err(anyhow::Error::msg(error)));
        }
        let waited = Instant::now();
        let outcome = self.wait_for_commit_result(
            result,
            deadline,
            &commit_fence,
            "waiting for a session journal effect commit receipt",
        );
        self.state.stats.receipt_waited(waited.elapsed());
        EffectSend::Sent(outcome)
    }
}

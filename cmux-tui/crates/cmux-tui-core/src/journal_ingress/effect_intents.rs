//! Registry commits sent to the journal writer as batch intents (effect
//! receipts, terminal records, workspace registry revisions).
//!
//! The request thread waits for the receipt with the same bounded deadline
//! and commit fence as a producer receipt (`journal_durable_wait()`, then at
//! most `JOURNAL_COMMIT_RESULT_WAIT` for a commit the writer already
//! admitted). A writer error, a dropped receipt or an expired deadline
//! returns an error; nothing waits without a bound. A commit the writer
//! admitted but did not answer in time is indeterminate: the caller keeps
//! its receipt channel ([`PendingRegistryReceipt`]) and settles it later.

use std::sync::Arc;
use std::sync::atomic::AtomicU8;
use std::time::Instant;

use cmux_threads::sync::mpsc::{Receiver, RecvTimeoutError, TryRecvError, sync_channel};

use super::writer_qos::RequestWait;
use super::{
    COMMIT_PENDING, JournalCommitIndeterminate, JournalIngressCompletion, JournalIngressEvent,
    JournalIngressSender, JournalWriterOwner, QueuedJournalEvent, journal_durable_wait,
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

/// The receipt channel of an indeterminate registry commit. Until its answer
/// is taken it counts as a request wait (`writer_qos`): a later request
/// blocks on it in `drain_unsettled`, so the writer attempt that answers it
/// runs at the writer's class, not at utility.
pub(crate) struct PendingRegistryReceipt {
    receiver: Receiver<Result<RegistryReceipt, String>>,
    wait: Option<RequestWait>,
}

impl PendingRegistryReceipt {
    /// A receipt whose answer arrives on `receiver`, counted by `wait` until
    /// that answer is taken.
    pub(super) fn counted(
        receiver: Receiver<Result<RegistryReceipt, String>>,
        wait: RequestWait,
    ) -> Self {
        Self { receiver, wait: Some(wait) }
    }

    /// A receipt whose answer arrives on `receiver` (registry tests).
    #[cfg(test)]
    pub(crate) fn for_test(receiver: Receiver<Result<RegistryReceipt, String>>) -> Self {
        Self { receiver, wait: None }
    }

    /// The receipt once the writer answered, `None` while it has not. A
    /// writer that dropped the channel without an answer reports an error.
    pub(crate) fn try_take(&mut self) -> Option<Result<RegistryReceipt, String>> {
        let taken = match self.receiver.try_recv() {
            Ok(result) => Some(result),
            Err(TryRecvError::Empty) => None,
            Err(TryRecvError::Disconnected) => {
                Some(Err("the session journal writer dropped the receipt".into()))
            }
        };
        self.settle_wait(taken)
    }

    /// [`Self::try_take`], waiting at most `timeout` for the answer: a
    /// `journal_wait` (`request_path`) at `site`.
    pub(crate) fn wait_take(
        &mut self,
        timeout: std::time::Duration,
        site: &'static std::panic::Location<'static>,
    ) -> Option<Result<RegistryReceipt, String>> {
        crate::request_path::note_at(crate::request_path::BlockingKind::JournalWait, site);
        // wakeup-allow: deadline the caller's own timeout, forwarded unchanged
        let taken = match self.receiver.recv_timeout(timeout) {
            Ok(result) => Some(result),
            Err(RecvTimeoutError::Timeout) => None,
            Err(RecvTimeoutError::Disconnected) => {
                Some(Err("the session journal writer dropped the receipt".into()))
            }
        };
        self.settle_wait(taken)
    }

    /// Stops counting the wait once the answer is taken.
    fn settle_wait(
        &mut self,
        taken: Option<Result<RegistryReceipt, String>>,
    ) -> Option<Result<RegistryReceipt, String>> {
        if taken.is_some() {
            self.wait = None;
        }
        taken
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
                        if !writer.thread.is_current()
                )
            })
    }

    /// Offer `intent` to the writer and wait for its receipt. The waits are
    /// `journal_wait` notes (`request_path`) at `site`: the registry call
    /// that committed it, which reaches here through the dyn intent sink.
    pub(crate) fn send_effect(
        &self,
        intent: RegistryIntent,
        site: &'static std::panic::Location<'static>,
    ) -> EffectSend {
        let intent = Box::new(intent);
        let Some(sender) = &self.durable_sender else { return EffectSend::NotQueued(intent) };
        if !self.accepts_effects() {
            return EffectSend::NotQueued(intent);
        }
        if self.state.disk_full.is_full() {
            self.state.disk_full.refused_waiter(&self.state);
            return EffectSend::Sent(Err(anyhow::anyhow!(super::disk_full::WAITER_ERROR)));
        }
        let wait = self.state.request_waits.enter();
        let (completion, result) = sync_channel(1);
        let deadline = Instant::now() + journal_durable_wait();
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
            site,
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
            site,
        );
        self.state.stats.receipt_waited(waited.elapsed());
        match outcome {
            Err(error) if error.downcast_ref::<JournalCommitIndeterminate>().is_some() => {
                EffectSend::Indeterminate(error, PendingRegistryReceipt::counted(result, wait))
            }
            outcome => EffectSend::Sent(outcome),
        }
    }
}

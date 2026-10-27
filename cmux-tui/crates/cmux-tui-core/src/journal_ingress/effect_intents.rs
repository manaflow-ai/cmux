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
//!
//! [`JournalIngressSender::admit_effect`] queues the same intent and returns
//! at once (admit then reply, p05-ipc-120): the request replies with the
//! receipt it decided at prepare, and the writer's answer arrives on the
//! returned channel for the registry's read barrier and its journal-degraded
//! check (`workspace_registry::admitted_reply`).

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

/// The result of admitting a registry commit to the journal writer without
/// waiting for its receipt ([`JournalIngressSender::admit_effect`]).
#[cfg_attr(not(test), allow(dead_code, reason = "Q3 sites p05-ipc-121..126 adopt admit"))]
pub(crate) enum AdmitSend {
    /// The durable lane holds the intent; the writer's answer arrives on
    /// the channel.
    Admitted(PendingRegistryReceipt),
    /// Nothing was queued, as [`EffectSend::NotQueued`]: commit it locally.
    NotQueued(Box<RegistryIntent>),
    /// Nothing was queued and the intent is lost (a lane defect).
    Failed(anyhow::Error),
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
                        if writer.thread.thread().id() != std::thread::current().id()
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
        let queued = match self.queue_effect(intent, false, site) {
            Ok(queued) => queued,
            Err(QueueRefused::NotQueued(intent)) => return EffectSend::NotQueued(intent),
            Err(QueueRefused::Failed(error)) => return EffectSend::Sent(Err(error)),
        };
        let waited = Instant::now();
        let outcome = self.wait_for_commit_result(
            &queued.result,
            queued.deadline,
            &queued.commit_fence,
            "waiting for a session journal registry commit receipt",
            site,
        );
        self.state.stats.receipt_waited(waited.elapsed());
        match outcome {
            Err(error) if error.downcast_ref::<JournalCommitIndeterminate>().is_some() => {
                EffectSend::Indeterminate(
                    error,
                    PendingRegistryReceipt::counted(queued.result, queued.wait),
                )
            }
            outcome => EffectSend::Sent(outcome),
        }
    }

    /// Queue `intent` and return without its receipt (admit then reply,
    /// p05-ipc-120). The only wait is the bounded enqueue when the durable
    /// lane is full, a `journal_wait` at `site` as in [`Self::send_effect`].
    /// The writer applies the intent within the durable deadline or answers
    /// with the error. The receipt counts as a request wait until it is
    /// taken: the registry's read barrier waits for it, so the writer
    /// attempt that answers it runs at the writer's class, not at utility.
    #[cfg_attr(not(test), allow(dead_code, reason = "Q3 sites p05-ipc-121..126 adopt admit"))]
    pub(crate) fn admit_effect(
        &self,
        intent: RegistryIntent,
        site: &'static std::panic::Location<'static>,
    ) -> AdmitSend {
        match self.queue_effect(intent, true, site) {
            Ok(queued) => {
                AdmitSend::Admitted(PendingRegistryReceipt::counted(queued.result, queued.wait))
            }
            Err(QueueRefused::NotQueued(intent)) => AdmitSend::NotQueued(intent),
            Err(QueueRefused::Failed(error)) => AdmitSend::Failed(error),
        }
    }

    /// Put `intent` on the durable lane with a receipt channel; `admitted`
    /// when its request replies without waiting for the commit.
    fn queue_effect(
        &self,
        intent: RegistryIntent,
        admitted: bool,
        site: &'static std::panic::Location<'static>,
    ) -> Result<QueuedEffect, QueueRefused> {
        let intent = Box::new(intent);
        let Some(sender) = &self.durable_sender else {
            return Err(QueueRefused::NotQueued(intent));
        };
        if !self.accepts_effects() {
            return Err(QueueRefused::NotQueued(intent));
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
                    admitted,
                }),
            },
            deadline,
            site,
        ) {
            // Not queued (deadline, admission closed, writer gone): hand the
            // intent back so a caller without state can commit it locally,
            // as before the writer took registry commits.
            return Err(match event.event {
                JournalIngressEvent::Effect(intent) => QueueRefused::NotQueued(intent),
                _ => {
                    debug_assert!(false, "the durable lane returned a different event");
                    QueueRefused::Failed(anyhow::Error::msg(error))
                }
            });
        }
        Ok(QueuedEffect { result, wait, deadline, commit_fence })
    }
}

/// An intent the durable lane took: where and by when its receipt arrives.
struct QueuedEffect {
    result: Receiver<Result<RegistryReceipt, String>>,
    wait: RequestWait,
    deadline: Instant,
    commit_fence: Arc<AtomicU8>,
}

/// Why [`JournalIngressSender::queue_effect`] queued nothing.
enum QueueRefused {
    /// The intent, handed back to commit locally.
    NotQueued(Box<RegistryIntent>),
    /// The lane returned a different event (a defect; debug builds assert).
    Failed(anyhow::Error),
}

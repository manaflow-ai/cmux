//! Registry commits as journal writer intents (plans/cmux-tui-journal-write-path.md:
//! PR4b effect receipts; PR5 terminal records and workspace registry commits).
//!
//! A request thread prepares a [`RegistryIntent`] while it holds the
//! workspace registry: validation, canonical JSON and any reads stay
//! request-side. The journal writer applies the intent inside its batch
//! transaction under a SAVEPOINT, so many commits share one fsync, and
//! answers with a [`RegistryReceipt`].
//!
//! Lock order is unchanged: workspace registry -> registry connection ->
//! state. While it waits for the receipt the request thread holds the
//! registry (topology writers stay serialized) and may hold state, but never
//! the connection: the writer needs it, and the writer takes neither the
//! registry nor state (`server-stats` `write_path.writer_registry_locks`).
//!
//! An indeterminate receipt (the writer admitted the batch, the result did
//! not arrive in time) is kept on the connection with the state update the
//! request could not apply. The next request that pins state settles it
//! (`Mux::lock_state_pinned`): a committed receipt applies its state update
//! and raises the in-memory revisions to the journal head (cx-g1fa.3).
//!
//! An admitted intent (admit then reply, `admitted_reply`) is kept the same
//! way with the receipt its reply already gave; it owes no state update. A
//! cold read waits for it (`RegistryConnection::read_barrier`), and a writer
//! answer that does not repeat the reply is a journal-degraded note.

use std::sync::Arc;

use super::admitted_reply::{
    Admission, AdmitState, AdmitStatsSnapshot, AdmittedReply, FallbackReason, ReceiptRevisions,
};
use super::*;
use crate::journal_ingress::{AdmitSend, EffectSend, PendingRegistryReceipt};

/// The SAVEPOINT that scopes one intent inside a writer batch.
const REGISTRY_INTENT_SAVEPOINT: &str = "cmux_registry_intent";

/// Extra rows an intent writes in its transaction. `Fn`, not `FnOnce`: the
/// writer can retry or split a failed batch and apply the intent again.
pub(crate) type OwnedTransactionWrite =
    Box<dyn Fn(&Transaction<'_>) -> anyhow::Result<()> + Send + Sync>;

/// The state update of a request whose receipt was indeterminate, applied
/// when the receipt arrives (see the module docs).
pub(crate) type SettleState = Box<dyn FnOnce(&mut crate::State, &RegistryReceipt) + Send>;

/// One registry commit, ready for any thread that holds the connection: the
/// journal writer batch, or a request-side transaction.
#[derive(Debug)]
pub(crate) enum RegistryIntent {
    Effect(EffectCommitIntent),
    Terminal(TerminalCommitIntent),
    Workspace(WorkspaceCommitIntent),
}

/// The writer's (or a local transaction's) answer for one intent.
#[derive(Debug)]
pub(crate) enum RegistryReceipt {
    Effect(EffectCommitReceipt),
    Terminal(TerminalRegistryCommit),
    Workspace(WorkspaceCommitReceipt),
}

/// Where requests send registry intents: the journal writer, installed by
/// the mux when its writer starts.
pub(crate) trait RegistryIntentSink: Send + Sync {
    /// True when the journal writer runs and the caller is not its thread.
    fn accepts(&self) -> bool;
    /// Commit `intent` through the writer. `site` is the registry call that
    /// committed it: the dyn call breaks `#[track_caller]`, so the receipt
    /// wait is noted there (`request_path`) explicitly.
    fn send(
        &self,
        intent: RegistryIntent,
        site: &'static std::panic::Location<'static>,
    ) -> EffectSend;
    /// Queue `intent` on the writer without waiting for its receipt (admit
    /// then reply); `site` as for [`Self::send`].
    #[cfg_attr(not(test), allow(dead_code, reason = "Q3 sites p05-ipc-121..126 adopt admit"))]
    fn admit(
        &self,
        intent: RegistryIntent,
        site: &'static std::panic::Location<'static>,
    ) -> AdmitSend;
}

/// An indeterminate receipt and the state update it still owes, or an
/// admitted intent and the receipt its reply gave.
pub(crate) struct UnsettledReceipt {
    pending: PendingRegistryReceipt,
    /// The writer's answer once it arrived (see `drain_unsettled`).
    resolved: Option<Result<RegistryReceipt, String>>,
    settle: Option<SettleState>,
    /// Set for an admitted intent: it owes no state, only the check.
    admitted: Option<AdmittedReply>,
}

impl UnsettledReceipt {
    /// Keep the writer's `answer`. For an admitted intent, count it and
    /// note it in `degraded` when the journal does not hold the reply.
    fn resolve(
        &mut self,
        answer: Result<RegistryReceipt, String>,
        admit: &AdmitState,
        degraded: &mut Vec<String>,
    ) {
        if let Some(admitted) = &self.admitted {
            let note = admitted.degraded_note(&answer);
            admit.resolved(note.is_some(), note.is_some() && answer.is_ok());
            if let Some(note) = note {
                eprintln!("cmux-tui: journal-degraded: {note}");
                degraded.push(note);
            }
        }
        self.resolved = Some(answer);
    }

    /// An admitted intent with its answer: nothing is left to settle.
    fn is_spent_admission(&self) -> bool {
        self.admitted.is_some() && self.resolved.is_some()
    }
}

/// The connection's unsettled receipts and the journal-degraded notes of
/// admitted intents, behind the connection's `unsettled` mutex.
#[derive(Default)]
pub(crate) struct Unsettled {
    receipts: Vec<UnsettledReceipt>,
    degraded: Vec<String>,
}

/// How long a new registry commit waits for an earlier indeterminate one.
const UNSETTLED_DRAIN_WAIT: std::time::Duration = std::time::Duration::from_secs(2);

impl RegistryIntent {
    /// Resident size for the writer's durable batch byte cap.
    pub(crate) fn estimated_bytes(&self) -> usize {
        match self {
            Self::Effect(intent) => intent.estimated_bytes(),
            Self::Terminal(intent) => intent.estimated_bytes(),
            Self::Workspace(intent) => intent.estimated_bytes(),
        }
    }

    /// Apply inside `transaction` (no savepoint).
    fn apply(&self, transaction: &Transaction<'_>) -> anyhow::Result<RegistryReceipt> {
        Ok(match self {
            Self::Effect(intent) => RegistryReceipt::Effect(intent.apply(transaction)?),
            Self::Terminal(intent) => RegistryReceipt::Terminal(intent.apply(transaction)?),
            Self::Workspace(intent) => RegistryReceipt::Workspace(intent.apply(transaction, None)?),
        })
    }

    /// Apply inside a journal writer batch under its own SAVEPOINT.
    ///
    /// `Ok(Err(_))`: this intent failed (for example a revision conflict, or
    /// a row it reads is missing); its writes were rolled back and only its
    /// request gets the error. `Err(_)`: a failure of the connection itself
    /// (busy, locked, I/O, full, corrupt, the batch deadline interrupt; see
    /// [`fails_the_batch`]); the whole batch fails and the writer retries or
    /// splits it as for any other batch error.
    pub(crate) fn apply_in_savepoint(
        &self,
        transaction: &Transaction<'_>,
    ) -> anyhow::Result<Result<RegistryReceipt, String>> {
        transaction.execute_batch(&format!("SAVEPOINT {REGISTRY_INTENT_SAVEPOINT}"))?;
        match self.apply(transaction) {
            Ok(receipt) => {
                transaction.execute_batch(&format!("RELEASE {REGISTRY_INTENT_SAVEPOINT}"))?;
                Ok(Ok(receipt))
            }
            Err(error) if fails_the_batch(&error) => Err(error),
            Err(error) => {
                transaction.execute_batch(&format!(
                    "ROLLBACK TO {REGISTRY_INTENT_SAVEPOINT}; RELEASE {REGISTRY_INTENT_SAVEPOINT}"
                ))?;
                Ok(Err(format!("{error:#}")))
            }
        }
    }
}

impl RegistryReceipt {
    /// The resource revision this commit installed, if it advanced one.
    pub(crate) fn resource_revision(&self) -> Option<u64> {
        match self {
            Self::Effect(receipt) => Some(receipt.revision()),
            Self::Terminal(_) => None,
            Self::Workspace(receipt) => receipt.resource_revision,
        }
    }

    pub(crate) fn into_effect(self) -> anyhow::Result<EffectCommitReceipt> {
        match self {
            Self::Effect(receipt) => Ok(receipt),
            _ => anyhow::bail!("registry receipt is not an effect receipt"),
        }
    }

    pub(crate) fn into_terminal(self) -> anyhow::Result<TerminalRegistryCommit> {
        match self {
            Self::Terminal(commit) => Ok(commit),
            _ => anyhow::bail!("registry receipt is not a terminal commit"),
        }
    }

    pub(crate) fn into_workspace(self) -> anyhow::Result<WorkspaceCommitReceipt> {
        match self {
            Self::Workspace(receipt) => Ok(receipt),
            _ => anyhow::bail!("registry receipt is not a workspace registry commit"),
        }
    }
}

/// True when `error` is a failure of the connection or the batch (busy,
/// locked, I/O, full, corrupt, interrupted by the batch deadline) rather
/// than of this one intent. Data errors (a missing row, a constraint, a
/// conversion) fail only the intent, as they failed only its request when
/// it committed alone.
fn fails_the_batch(error: &anyhow::Error) -> bool {
    use rusqlite::ErrorCode;
    error.chain().any(|cause| {
        matches!(
            cause.downcast_ref::<rusqlite::Error>(),
            Some(rusqlite::Error::SqliteFailure(failure, _)) if matches!(
                failure.code,
                ErrorCode::DatabaseBusy
                    | ErrorCode::DatabaseLocked
                    | ErrorCode::OperationInterrupted
                    | ErrorCode::SystemIoFailure
                    | ErrorCode::DiskFull
                    | ErrorCode::DatabaseCorrupt
                    | ErrorCode::NotADatabase
                    | ErrorCode::OutOfMemory
                    | ErrorCode::CannotOpen
                    | ErrorCode::FileLockingProtocolFailed
                    | ErrorCode::ReadOnly
            )
        )
    })
}

impl RegistryConnection {
    /// Install the journal writer as the target of registry intents. The
    /// first install wins (one writer per session database).
    pub(crate) fn install_intent_sink(&self, sink: Arc<dyn RegistryIntentSink>) {
        let _ = self.intent_sink.set(sink);
    }

    fn accepting_sink(&self) -> Option<&Arc<dyn RegistryIntentSink>> {
        self.intent_sink.get().filter(|sink| sink.accepts())
    }

    fn lock_unsettled(&self) -> std::sync::MutexGuard<'_, Unsettled> {
        self.unsettled.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    fn hold_unsettled(&self, pending: PendingRegistryReceipt, settle: Option<SettleState>) {
        self.lock_unsettled().receipts.push(UnsettledReceipt {
            pending,
            resolved: None,
            settle,
            admitted: None,
        });
    }

    /// Keep an admitted intent's receipt channel with the receipt its reply
    /// gives; its admit sequence.
    pub(super) fn hold_admitted(
        &self,
        pending: PendingRegistryReceipt,
        replied: ReceiptRevisions,
    ) -> u64 {
        let mut unsettled = self.lock_unsettled();
        let sequence = self.admit.admit();
        unsettled.receipts.push(UnsettledReceipt {
            pending,
            resolved: None,
            settle: None,
            admitted: Some(AdmittedReply { sequence, replied }),
        });
        sequence
    }

    /// The read barrier of a first connection acquisition at `site`: wait,
    /// bounded, until every admitted intent has its writer answer, so a cold
    /// read sees what earlier replies said (read-your-writes). Each wait is a
    /// `journal_wait` (`request_path`) at `site` and a `read_barrier_waits`
    /// count. Reads must not fail here: at the bound the read goes ahead
    /// without the answer and counts `read_barrier_timeouts`.
    ///
    /// One atomic load when nothing is admitted. Never on the journal writer
    /// (it answers them) and never while this thread holds the connection
    /// (the writer needs it): the caller checks reentry. Holding the
    /// `unsettled` mutex across the wait is safe for the reason
    /// [`Self::drain_unsettled`] gives.
    pub(super) fn read_barrier(&self, site: &'static std::panic::Location<'static>) {
        if !self.admit.has_unresolved() || registry_connection::in_journal_writer_commit() {
            return;
        }
        let mut unsettled = self.lock_unsettled();
        let Unsettled { receipts, degraded } = &mut *unsettled;
        let deadline = std::time::Instant::now() + UNSETTLED_DRAIN_WAIT;
        let (mut waited, mut timed_out) = (false, false);
        for entry in receipts.iter_mut().filter(|entry| entry.admitted.is_some()) {
            if entry.resolved.is_some() {
                continue;
            }
            let answer = entry.pending.try_take().or_else(|| {
                waited = true;
                let left = deadline.saturating_duration_since(std::time::Instant::now());
                entry.pending.wait_take(left, site)
            });
            match answer {
                Some(answer) => entry.resolve(answer, &self.admit, degraded),
                None => {
                    timed_out = true;
                    break;
                }
            }
        }
        receipts.retain(|entry| !entry.is_spent_admission());
        if waited {
            self.admit.barrier_waited(timed_out);
        }
    }

    /// Journal-degraded notes of admitted intents since the last call, for
    /// the next state holder to publish (`Mux::emit_journal_degraded`).
    pub(crate) fn take_journal_degraded(&self) -> Vec<String> {
        std::mem::take(&mut self.lock_unsettled().degraded)
    }

    /// Admit then reply counters (`admitted_reply`).
    #[cfg_attr(not(test), allow(dead_code, reason = "Q3 sites p05-ipc-121..126 adopt admit"))]
    pub(crate) fn admit_stats(&self) -> AdmitStatsSnapshot {
        self.admit.snapshot()
    }

    /// Wait (bounded) until every earlier indeterminate commit has its
    /// answer, keeping the answers for the next state holder to settle. A
    /// new commit prepared before then could read a topology, a fold or a
    /// revision that the late commit is about to change. Errors when one is
    /// still unanswered after the wait. Admitted intents are only checked,
    /// never waited for.
    ///
    /// It holds the `unsettled` mutex across the wait. Callers must hold the
    /// workspace registry (all do): the writer takes neither the registry
    /// nor this mutex, so the wait cannot form a cycle. Each unanswered
    /// receipt it waits for is a `journal_wait` (`request_path`) at the
    /// caller.
    #[track_caller]
    pub(crate) fn drain_unsettled(&self) -> anyhow::Result<()> {
        let site = std::panic::Location::caller();
        let mut unsettled = self.lock_unsettled();
        let Unsettled { receipts, degraded } = &mut *unsettled;
        let deadline = std::time::Instant::now() + UNSETTLED_DRAIN_WAIT;
        let mut drained = Ok(());
        for entry in receipts.iter_mut().filter(|entry| entry.resolved.is_none()) {
            let answer = entry.pending.try_take().or_else(|| {
                // An admitted intent is not waited for: the writer applies
                // the next one after it in lane order, and the in-memory
                // base already holds it (p05-ipc-132/133). Cold reads wait
                // in `read_barrier`.
                entry.admitted.is_none().then(|| {
                    let left = deadline.saturating_duration_since(std::time::Instant::now());
                    entry.pending.wait_take(left, site)
                })?
            });
            match answer {
                Some(answer) => entry.resolve(answer, &self.admit, degraded),
                None if entry.admitted.is_some() => {}
                None => {
                    drained = Err(anyhow::anyhow!(
                        "an earlier session journal registry commit is still indeterminate; retry"
                    ));
                    break;
                }
            }
        }
        receipts.retain(|entry| !entry.is_spent_admission());
        drained
    }

    /// Receipts that arrived for earlier indeterminate commits, with the
    /// state updates they owe. A receipt that resolved to an error owes
    /// nothing: the writer rolled the intent back. Admitted intents owe
    /// nothing either (their state was applied at admit); their answers only
    /// feed the journal-degraded check. Unresolved ones stay.
    pub(crate) fn take_settled_receipts(&self) -> Vec<(RegistryReceipt, Option<SettleState>)> {
        let mut unsettled = self.lock_unsettled();
        let Unsettled { receipts, degraded } = &mut *unsettled;
        if receipts.is_empty() {
            return Vec::new();
        }
        let mut settled = Vec::new();
        let mut kept = Vec::with_capacity(receipts.len());
        for mut entry in receipts.drain(..) {
            if entry.resolved.is_none()
                && let Some(answer) = entry.pending.try_take()
            {
                entry.resolve(answer, &self.admit, degraded);
            }
            if entry.admitted.is_some() {
                if entry.resolved.is_none() {
                    kept.push(entry);
                }
                continue;
            }
            match entry.resolved.take() {
                None => kept.push(entry),
                Some(Ok(receipt)) => settled.push((receipt, entry.settle)),
                Some(Err(error)) => {
                    eprintln!("cmux-tui: an indeterminate registry commit did not commit: {error}");
                }
            }
        }
        *receipts = kept;
        settled
    }
}

impl WorkspaceRegistry {
    /// Commit `intent` through the journal writer batch when the writer runs
    /// and this thread does not hold the connection; otherwise in its own
    /// request-side transaction. The caller holds the registry, and must not
    /// hold state unless it pinned the connection first.
    #[track_caller]
    pub(crate) fn commit_registry_intent(
        &mut self,
        intent: RegistryIntent,
    ) -> anyhow::Result<RegistryReceipt> {
        self.commit_registry_intent_with(intent, || {}, None)
    }

    /// [`Self::commit_registry_intent`] for a caller that holds state on a
    /// pinned connection. `release_pin` drops that pin once the intent goes
    /// to the writer (the caller keeps state across the receipt wait; the
    /// writer takes neither the registry nor state). `settle` is the state
    /// update to apply if the receipt is indeterminate and arrives later.
    #[track_caller]
    pub(crate) fn commit_registry_intent_with(
        &mut self,
        intent: RegistryIntent,
        release_pin: impl FnOnce(),
        settle: Option<SettleState>,
    ) -> anyhow::Result<RegistryReceipt> {
        let site = std::panic::Location::caller();
        // Every prepare drains earlier indeterminate commits first (bounded),
        // so `intent` is not built on a base a late commit changes; this
        // second drain covers one that went indeterminate meanwhile.
        self.connection.drain_unsettled()?;
        let Some(sink) = self.connection.accepting_sink().cloned() else {
            return self.commit_registry_intent_locally(&intent);
        };
        release_pin();
        // A thread that still holds the connection (an outer pin or guard)
        // would block the writer it waits for: commit locally instead. The
        // request_effect_commits counter makes any such caller visible.
        if self.connection.is_held_by_current_thread() {
            return self.commit_registry_intent_locally(&intent);
        }
        match sink.send(intent, site) {
            EffectSend::Sent(Ok(receipt)) => Ok(receipt),
            EffectSend::Sent(Err(error)) => {
                self.abandon_effect_commit();
                Err(error)
            }
            EffectSend::Indeterminate(error, pending) => {
                // The writer can still commit after this request gives up:
                // forget the public fold, and keep the receipt so the next
                // state holder installs what it committed.
                self.abandon_effect_commit();
                self.connection.hold_unsettled(pending, settle);
                Err(error)
            }
            EffectSend::NotQueued(intent) => {
                // The writer stopped between the check and the send. A
                // thread that holds state cannot take the connection now.
                anyhow::ensure!(
                    !registry_connection::current_thread_holds_state(),
                    "the session journal writer stopped before it took a registry commit"
                );
                self.commit_registry_intent_locally(&intent)
            }
        }
    }

    /// Admit `intent` and return `prepared`, the receipt decided at prepare,
    /// without waiting for the journal writer (admit then reply,
    /// `admitted_reply`). The caller applies its state and emits its events
    /// with that receipt before it replies, so events still go out before
    /// the reply. It holds the registry as for
    /// [`Self::commit_registry_intent_with`] (same `release_pin`, and
    /// `settle` for a fallback whose receipt is indeterminate).
    ///
    /// `prepared` must be exactly what the writer will commit: that is the
    /// in-memory revisions and ledger's contract (p05-ipc-132). A writer
    /// answer that differs, or an error, is journal-degraded; the in-memory
    /// state keeps the reply.
    ///
    /// With the feature off, no running writer, a held connection or a lane
    /// that refuses the intent, it commits and waits as
    /// [`Self::commit_registry_intent_with`] does, counted by reason, and
    /// returns the committed receipt.
    #[track_caller]
    #[cfg_attr(not(test), allow(dead_code, reason = "Q3 sites p05-ipc-121..126 adopt admit"))]
    pub(crate) fn admit_registry_intent(
        &mut self,
        intent: RegistryIntent,
        prepared: RegistryReceipt,
        release_pin: impl FnOnce(),
        settle: Option<SettleState>,
    ) -> anyhow::Result<Admission> {
        let site = std::panic::Location::caller();
        let refused = if !self.connection.admit.enabled() {
            Some(FallbackReason::Disabled)
        } else if self.connection.accepting_sink().is_none() {
            Some(FallbackReason::WriterNotRunning)
        } else {
            None
        };
        if let Some(reason) = refused {
            self.connection.admit.fell_back(reason);
            return self
                .commit_registry_intent_with(intent, release_pin, settle)
                .map(Admission::Committed);
        }
        // An intent admitted after a late indeterminate commit must not be
        // built on the base that commit changes (as in the commit path);
        // earlier admitted intents are ahead of it on the lane, no wait.
        self.connection.drain_unsettled()?;
        let Some(sink) = self.connection.accepting_sink().cloned() else {
            self.connection.admit.fell_back(FallbackReason::WriterNotRunning);
            return self.commit_registry_intent_locally(&intent).map(Admission::Committed);
        };
        release_pin();
        if self.connection.is_held_by_current_thread() {
            self.connection.admit.fell_back(FallbackReason::ConnectionHeld);
            return self.commit_registry_intent_locally(&intent).map(Admission::Committed);
        }
        match sink.admit(intent, site) {
            AdmitSend::Admitted(pending) => {
                let sequence =
                    self.connection.hold_admitted(pending, ReceiptRevisions::of(&prepared));
                Ok(Admission::Admitted { sequence, receipt: prepared })
            }
            AdmitSend::NotQueued(intent) => {
                self.connection.admit.fell_back(FallbackReason::NotQueued);
                anyhow::ensure!(
                    !registry_connection::current_thread_holds_state(),
                    "the session journal writer stopped before it took a registry commit"
                );
                self.commit_registry_intent_locally(&intent).map(Admission::Committed)
            }
            AdmitSend::Failed(error) => {
                self.abandon_effect_commit();
                Err(error)
            }
        }
    }

    /// Commit an intent in its own request-side transaction and fsync: the
    /// writer is disabled, stopped, or not running, or the caller holds the
    /// connection.
    #[track_caller]
    pub(crate) fn commit_registry_intent_locally(
        &self,
        intent: &RegistryIntent,
    ) -> anyhow::Result<RegistryReceipt> {
        let db = self.connection.get();
        let tx = db.unchecked_transaction()?;
        let receipt = intent.apply(&tx)?;
        tx.commit()?;
        drop(db);
        self.connection.write_path_stats().request_effect_committed();
        Ok(receipt)
    }
}

#[cfg(test)]
#[path = "registry_intent_tests.rs"]
mod tests;

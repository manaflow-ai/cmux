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

use std::sync::Arc;

use super::*;
use crate::journal_ingress::{EffectSend, PendingRegistryReceipt};

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
    fn send(&self, intent: RegistryIntent) -> EffectSend;
}

/// An indeterminate receipt and the state update it still owes.
pub(crate) struct UnsettledReceipt {
    pending: PendingRegistryReceipt,
    /// The writer's answer once it arrived (see `drain_unsettled`).
    resolved: Option<Result<RegistryReceipt, String>>,
    settle: Option<SettleState>,
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

    fn hold_unsettled(&self, pending: PendingRegistryReceipt, settle: Option<SettleState>) {
        self.unsettled
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .push(UnsettledReceipt { pending, resolved: None, settle });
    }

    /// Wait (bounded) until every earlier indeterminate commit has its
    /// answer, keeping the answers for the next state holder to settle. A
    /// new commit prepared before then could read a topology, a fold or a
    /// revision that the late commit is about to change. Errors when one is
    /// still unanswered after the wait.
    pub(crate) fn drain_unsettled(&self) -> anyhow::Result<()> {
        let mut unsettled =
            self.unsettled.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let deadline = std::time::Instant::now() + UNSETTLED_DRAIN_WAIT;
        for entry in unsettled.iter_mut().filter(|entry| entry.resolved.is_none()) {
            let left = deadline.saturating_duration_since(std::time::Instant::now());
            entry.resolved = entry.pending.wait_take(left);
            anyhow::ensure!(
                entry.resolved.is_some(),
                "an earlier session journal registry commit is still indeterminate; retry"
            );
        }
        Ok(())
    }

    /// Receipts that arrived for earlier indeterminate commits, with the
    /// state updates they owe. A receipt that resolved to an error owes
    /// nothing: the writer rolled the intent back. Unresolved ones stay.
    pub(crate) fn take_settled_receipts(&self) -> Vec<(RegistryReceipt, Option<SettleState>)> {
        let mut unsettled =
            self.unsettled.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if unsettled.is_empty() {
            return Vec::new();
        }
        let mut settled = Vec::new();
        let mut kept = Vec::with_capacity(unsettled.len());
        for mut entry in unsettled.drain(..) {
            match entry.resolved.take().or_else(|| entry.pending.try_take()) {
                None => kept.push(entry),
                Some(Ok(receipt)) => settled.push((receipt, entry.settle)),
                Some(Err(error)) => {
                    eprintln!("cmux-tui: an indeterminate registry commit did not commit: {error}");
                }
            }
        }
        *unsettled = kept;
        settled
    }
}

impl WorkspaceRegistry {
    /// Commit `intent` through the journal writer batch when the writer runs
    /// and this thread does not hold the connection; otherwise in its own
    /// request-side transaction. The caller holds the registry, and must not
    /// hold state unless it pinned the connection first.
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
    pub(crate) fn commit_registry_intent_with(
        &mut self,
        intent: RegistryIntent,
        release_pin: impl FnOnce(),
        settle: Option<SettleState>,
    ) -> anyhow::Result<RegistryReceipt> {
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
        match sink.send(intent) {
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

    /// Commit an intent in its own request-side transaction and fsync: the
    /// writer is disabled, stopped, or not running, or the caller holds the
    /// connection.
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

//! Registry commits as intents (plans/cmux-tui-journal-write-path.md PR4b,
//! PR5): effect receipts, terminal records and workspace registry commits.
//!
//! A request thread prepares a [`RegistryIntent`] while it holds the
//! workspace registry (validation, canonical JSON and any reads) and commits
//! it in its own transaction on the same thread. With `synchronous=NORMAL`
//! (`wal_durability`) that commit is a WAL page-cache write, well under a
//! millisecond, so no request waits for the journal writer, its queue or its
//! other events (PL-daemon; perf-lead.md D1). Lock order: workspace registry
//! -> registry connection -> state.

use super::*;

/// The SAVEPOINT that scopes one intent inside a writer batch.
const REGISTRY_INTENT_SAVEPOINT: &str = "cmux_registry_intent";

/// Extra rows an intent writes in its transaction. `Fn`, not `FnOnce`: the
/// writer can retry or split a failed batch and apply the intent again.
pub(crate) type OwnedTransactionWrite =
    Box<dyn Fn(&Transaction<'_>) -> anyhow::Result<()> + Send + Sync>;

/// One registry commit, ready for a request-side transaction.
#[derive(Debug)]
pub(crate) enum RegistryIntent {
    Effect(EffectCommitIntent),
    Terminal(TerminalCommitIntent),
    Workspace(WorkspaceCommitIntent),
}

/// The answer for one intent.
#[derive(Debug)]
pub(crate) enum RegistryReceipt {
    Effect(EffectCommitReceipt),
    Terminal(TerminalRegistryCommit),
    Workspace(WorkspaceCommitReceipt),
}

impl RegistryIntent {
    /// Apply inside `transaction` (no savepoint).
    fn apply(&self, transaction: &Transaction<'_>) -> anyhow::Result<RegistryReceipt> {
        Ok(match self {
            Self::Effect(intent) => RegistryReceipt::Effect(intent.apply(transaction)?),
            Self::Terminal(intent) => RegistryReceipt::Terminal(intent.apply(transaction)?),
            Self::Workspace(intent) => RegistryReceipt::Workspace(intent.apply(transaction, None)?),
        })
    }

    /// Apply inside a larger transaction under its own SAVEPOINT.
    ///
    /// `Ok(Err(_))`: this intent failed (for example a revision conflict, or
    /// a row it reads is missing); its writes were rolled back and only its
    /// request gets the error. `Err(_)`: a failure of the connection itself
    /// (busy, locked, I/O, full, corrupt, interrupted; see
    /// [`fails_the_batch`]); the whole transaction fails.
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

impl WorkspaceRegistry {
    /// Commit `intent` through the journal writer batch when the writer runs
    /// and this thread does not hold the connection; otherwise in its own
    /// request-side transaction. The caller holds the registry, and must not
    /// hold state unless it pinned the connection first.
    pub(crate) fn commit_registry_intent(
        &mut self,
        intent: RegistryIntent,
    ) -> anyhow::Result<RegistryReceipt> {
        self.commit_registry_intent_with(intent, || {})
    }

    /// [`Self::commit_registry_intent`] for a caller that holds state on a
    /// pinned connection: `release_pin` drops that pin once the commit is in
    /// (the caller keeps state).
    pub(crate) fn commit_registry_intent_with(
        &mut self,
        intent: RegistryIntent,
        release_pin: impl FnOnce(),
    ) -> anyhow::Result<RegistryReceipt> {
        let receipt = self.commit_registry_intent_locally(&intent);
        release_pin();
        receipt
    }

    /// Commit an intent in its own request-side transaction (no fsync:
    /// `wal_durability`).
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

//! Registry commits (effect receipts, terminal records, workspace registry
//! revisions) as prepared intents.
//!
//! A request thread prepares a [`RegistryIntent`] while it holds the
//! workspace registry: validation, canonical JSON and any reads. It then
//! commits the intent in its own transaction, on its own thread, and gets a
//! [`RegistryReceipt`] at once. The registry runs with `synchronous=NORMAL`
//! in WAL mode (`wal_durability.rs`), so a commit is a WAL page-cache write,
//! well under a millisecond, and no request waits for the journal writer
//! (PL-daemon b5; `journal_writer_stall`: with the writer busy 1 s per
//! batch, a new workspace waited 3 s for its receipt when intents rode the
//! writer's batch).
//!
//! Lock order: workspace registry -> registry connection -> state.

use super::*;

/// Extra rows an intent writes in its transaction. `Fn`, not `FnOnce`: the
/// writer can retry or split a failed batch and apply the intent again.
pub(crate) type OwnedTransactionWrite =
    Box<dyn Fn(&Transaction<'_>) -> anyhow::Result<()> + Send + Sync>;

/// One registry commit, ready for any thread that holds the connection: the
/// journal writer batch, or a request-side transaction.
#[derive(Debug)]
pub(crate) enum RegistryIntent {
    Effect(EffectCommitIntent),
    /// Effect intents that commit together, in order: the creations of one
    /// creation group (`Mux::commit_created_views_projection`).
    EffectGroup(Vec<EffectCommitIntent>),
    Terminal(TerminalCommitIntent),
    Workspace(WorkspaceCommitIntent),
}

/// The writer's (or a local transaction's) answer for one intent.
#[derive(Debug)]
pub(crate) enum RegistryReceipt {
    Effect(EffectCommitReceipt),
    EffectGroup(Vec<EffectCommitReceipt>),
    Terminal(TerminalRegistryCommit),
    Workspace(WorkspaceCommitReceipt),
}

impl RegistryIntent {
    /// Apply inside `transaction` (no savepoint).
    fn apply(&self, transaction: &Transaction<'_>) -> anyhow::Result<RegistryReceipt> {
        Ok(match self {
            Self::Effect(intent) => RegistryReceipt::Effect(intent.apply(transaction)?),
            Self::EffectGroup(intents) => RegistryReceipt::EffectGroup(
                intents
                    .iter()
                    .map(|intent| intent.apply(transaction))
                    .collect::<anyhow::Result<Vec<_>>>()?,
            ),
            Self::Terminal(intent) => RegistryReceipt::Terminal(intent.apply(transaction)?),
            Self::Workspace(intent) => RegistryReceipt::Workspace(intent.apply(transaction, None)?),
        })
    }
}

impl RegistryReceipt {
    pub(crate) fn into_effect(self) -> anyhow::Result<EffectCommitReceipt> {
        match self {
            Self::Effect(receipt) => Ok(receipt),
            _ => anyhow::bail!("registry receipt is not an effect receipt"),
        }
    }

    pub(crate) fn into_effect_group(self) -> anyhow::Result<Vec<EffectCommitReceipt>> {
        match self {
            Self::EffectGroup(receipts) => Ok(receipts),
            _ => anyhow::bail!("registry receipt is not an effect group receipt"),
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

impl WorkspaceRegistry {
    /// Commit `intent` in a request-side transaction, on this thread. The
    /// caller holds the registry, and must not hold state unless it pinned
    /// the connection first.
    pub(crate) fn commit_registry_intent(
        &mut self,
        intent: RegistryIntent,
    ) -> anyhow::Result<RegistryReceipt> {
        self.commit_registry_intent_locally(&intent)
    }

    /// Commit an intent in its own request-side transaction.
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

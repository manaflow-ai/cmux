//! Effect receipt commits as journal writer intents (PR4b of
//! plans/cmux-tui-journal-write-path.md).
//!
//! A request thread prepares an [`EffectCommitIntent`] while it holds the
//! workspace registry: validation, the stored fingerprint and public-fold
//! pruning stay request-side. The journal writer applies the intent inside
//! its batch transaction (`RegistryIntent::Effect`, see `registry_intent`),
//! so many receipts share one fsync, and answers with an
//! [`EffectCommitReceipt`]. The request thread then finishes the commit
//! (`finish_effect_commit`: projection stats and the public fold) under the
//! same registry hold.
//!
//! Lock order is unchanged: workspace registry -> registry connection ->
//! state. While it waits for the receipt the request thread holds the
//! registry, which keeps topology writers serialized, but neither the
//! connection (the writer needs it) nor state. The writer takes only the
//! connection; `server-stats` `write_path.writer_registry_locks` proves it.
//!
//! Prepare and executing transitions stay request-side: they must be durable
//! before the effect runs.

use std::sync::Arc;

use super::*;
use crate::user_settings::NewWorkspacePlacement;

/// One effect receipt commit, ready for any thread that holds the
/// connection: the journal writer batch, or a request-side transaction.
#[derive(Debug)]
pub(crate) struct EffectCommitIntent {
    idempotency_key: String,
    operation: String,
    /// The stored (redacted, canonical) fingerprint.
    fingerprint: String,
    generation: String,
    outcome_json: String,
    kind: EffectCommitKind,
    /// Rows written in the same transaction after the receipt (a
    /// notification's local feed rows, B2).
    extra: Option<ExtraRows>,
}

/// [`OwnedTransactionWrite`] with a `Debug` for the intent.
struct ExtraRows(OwnedTransactionWrite);

impl std::fmt::Debug for ExtraRows {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("ExtraRows")
    }
}

#[derive(Debug)]
enum EffectCommitKind {
    /// `commit_resource_effect`: an outcome, with optional public deltas.
    Outcome { outcome: ResourceEffectOutcome, outcome_value: Value, deltas: Option<Value> },
    /// `commit_resource_effect_patch`: a projected topology patch.
    /// `placement` is the request thread's `NewWorkspacePlacement` (a
    /// thread-scoped choice the writer thread cannot see), captured at
    /// prepare and scoped again where the patch applies.
    Patch {
        patch: ResourcePatch,
        result: Value,
        outcome: Value,
        deltas: Arc<Value>,
        placement: NewWorkspacePlacement,
    },
}

/// The writer's (or a local transaction's) answer for one intent.
#[derive(Debug)]
pub(crate) enum EffectCommitReceipt {
    Outcome { revision: u64 },
    Patch { commit: ResourcePatchCommit, spans: CommitSpans },
}

/// What the request thread keeps to finish a commit after its receipt.
pub(crate) enum EffectCommitFinish {
    Outcome,
    Patch { deltas: Arc<Value>, restates_all: bool },
}

impl EffectCommitIntent {
    /// Resident size for the writer's durable batch byte cap.
    pub(crate) fn estimated_bytes(&self) -> usize {
        let fixed = self
            .idempotency_key
            .len()
            .saturating_add(self.operation.len())
            .saturating_add(self.fingerprint.len())
            .saturating_add(self.generation.len())
            .saturating_add(self.outcome_json.len())
            .saturating_add(512);
        match &self.kind {
            EffectCommitKind::Outcome { deltas, .. } => {
                fixed.saturating_add(self.outcome_json.len()).saturating_add(
                    deltas
                        .as_ref()
                        .and_then(Value::as_array)
                        .map_or(0, Vec::len)
                        .saturating_mul(256),
                )
            }
            EffectCommitKind::Patch { patch, deltas, .. } => fixed
                .saturating_add(self.outcome_json.len().saturating_mul(2))
                .saturating_add(patch.changes.len().saturating_mul(256))
                .saturating_add(deltas.as_array().map_or(0, Vec::len).saturating_mul(256)),
        }
    }

    /// Write `extra` in the same transaction as this receipt.
    pub(crate) fn with_extra_rows(mut self, extra: OwnedTransactionWrite) -> Self {
        self.extra = Some(ExtraRows(extra));
        self
    }

    /// Apply inside `transaction` (the writer's savepoint, or a request-side
    /// transaction), then the extra rows.
    pub(crate) fn apply(
        &self,
        transaction: &Transaction<'_>,
    ) -> anyhow::Result<EffectCommitReceipt> {
        let receipt = self.apply_receipt(transaction)?;
        if let Some(ExtraRows(extra)) = &self.extra {
            extra(transaction)?;
        }
        Ok(receipt)
    }

    fn apply_receipt(&self, transaction: &Transaction<'_>) -> anyhow::Result<EffectCommitReceipt> {
        match &self.kind {
            EffectCommitKind::Outcome { outcome, outcome_value, deltas } => {
                let revision = commit_effect_outcome_in_transaction(
                    transaction,
                    &self.generation,
                    &self.idempotency_key,
                    &self.operation,
                    &self.fingerprint,
                    outcome,
                    outcome_value,
                    &self.outcome_json,
                    deltas.as_ref(),
                )?;
                Ok(EffectCommitReceipt::Outcome { revision })
            }
            EffectCommitKind::Patch { patch, result, outcome, deltas, placement } => {
                let (started, mut spans) = (std::time::Instant::now(), CommitSpans::default());
                let commit = placement.scoped(|| {
                    commit_resource_effect_patch_in_transaction(
                        transaction,
                        &self.generation,
                        &self.idempotency_key,
                        &self.operation,
                        &self.fingerprint,
                        patch,
                        result,
                        outcome,
                        &self.outcome_json,
                        deltas,
                        &mut spans,
                    )
                })?;
                // The batch's shared fsync is not part of one intent's span.
                spans.total = started.elapsed();
                Ok(EffectCommitReceipt::Patch { commit, spans })
            }
        }
    }
}

impl WorkspaceRegistry {
    /// A sent intent returned an error. The writer may still commit it
    /// later (an indeterminate receipt), after this request released the
    /// registry: forget the public fold so the next commit cannot prune its
    /// deltas against a revision that is no longer the journal head.
    pub(crate) fn abandon_effect_commit(&mut self) {
        self.public_fold = None;
    }

    /// Validate and prepare a `commit_resource_effect` intent.
    pub(crate) fn prepare_effect_outcome_intent(
        &self,
        idempotency_key: &str,
        operation: &str,
        fingerprint: &Value,
        outcome: &ResourceEffectOutcome,
        deltas: Option<&Value>,
    ) -> anyhow::Result<(EffectCommitIntent, EffectCommitFinish)> {
        validate_identifier("idempotency key", idempotency_key)?;
        validate_identifier("resource operation", operation)?;
        let fingerprint = self.stored_fingerprint(fingerprint)?;
        let outcome_value = serde_json::to_value(outcome)?;
        let outcome_json = canonical_json(&outcome_value)?;
        let intent = EffectCommitIntent {
            idempotency_key: idempotency_key.to_string(),
            operation: operation.to_string(),
            fingerprint,
            generation: self.generation.clone(),
            outcome_json,
            extra: None,
            kind: EffectCommitKind::Outcome {
                outcome: outcome.clone(),
                outcome_value,
                deltas: deltas.cloned(),
            },
        };
        Ok((intent, EffectCommitFinish::Outcome))
    }

    /// Validate and prepare a `commit_resource_effect_patch` intent. Public
    /// `deltas` the journal already states are dropped here.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn prepare_effect_patch_intent(
        &mut self,
        idempotency_key: &str,
        operation: &str,
        fingerprint: &Value,
        patch: &ResourcePatch,
        result: &Value,
        deltas: &Value,
        restates_all: bool,
    ) -> anyhow::Result<(EffectCommitIntent, EffectCommitFinish)> {
        validate_identifier("idempotency key", idempotency_key)?;
        validate_identifier("resource operation", operation)?;
        validate_resource_patch(patch)?;
        #[cfg(test)]
        if self.resource_patch_failures_remaining.get() > 0 {
            self.resource_patch_failures_remaining
                .set(self.resource_patch_failures_remaining.get() - 1);
            anyhow::bail!("forced one-shot resource patch failure");
        }
        let fingerprint = self.stored_fingerprint(fingerprint)?;
        let outcome = serde_json::to_value(ResourceEffectOutcome::Success(result.clone()))?;
        let outcome_json = canonical_json(&outcome)?;
        let deltas = Arc::new(self.prune_stated_topology_deltas(deltas)?);
        let intent = EffectCommitIntent {
            idempotency_key: idempotency_key.to_string(),
            operation: operation.to_string(),
            fingerprint,
            generation: self.generation.clone(),
            outcome_json,
            extra: None,
            kind: EffectCommitKind::Patch {
                patch: patch.clone(),
                result: result.clone(),
                outcome,
                deltas: deltas.clone(),
                placement: NewWorkspacePlacement::current(),
            },
        };
        Ok((intent, EffectCommitFinish::Patch { deltas, restates_all }))
    }

    /// Commit an intent in its own request-side transaction and fsync. The
    /// journal writer path is preferred (`Mux::commit_effect_intent`); this
    /// runs when the writer is disabled, stopped, or not running.
    pub(crate) fn commit_effect_intent_locally(
        &self,
        intent: EffectCommitIntent,
    ) -> anyhow::Result<EffectCommitReceipt> {
        self.commit_registry_intent_locally(&RegistryIntent::Effect(intent))?.into_effect()
    }

    /// Request-side bookkeeping after a durable receipt: projection commit
    /// spans and the public fold. The caller held the registry since prepare.
    pub(crate) fn finish_effect_commit(
        &mut self,
        finish: EffectCommitFinish,
        receipt: EffectCommitReceipt,
    ) -> anyhow::Result<EffectCommitReceipt> {
        match (finish, receipt) {
            (EffectCommitFinish::Outcome, receipt @ EffectCommitReceipt::Outcome { .. }) => {
                Ok(receipt)
            }
            (
                EffectCommitFinish::Patch { deltas, restates_all },
                EffectCommitReceipt::Patch { commit, spans },
            ) => {
                self.resource_projection_stats.committed(spans);
                self.record_public_fold(
                    commit.revision.saturating_sub(1),
                    commit.revision,
                    &deltas,
                    restates_all,
                );
                Ok(EffectCommitReceipt::Patch { commit, spans })
            }
            _ => anyhow::bail!("effect commit receipt does not match its intent"),
        }
    }
}

impl EffectCommitReceipt {
    pub(crate) fn revision(&self) -> u64 {
        match self {
            Self::Outcome { revision } => *revision,
            Self::Patch { commit, .. } => commit.revision,
        }
    }

    pub(crate) fn into_patch_commit(self) -> anyhow::Result<ResourcePatchCommit> {
        match self {
            Self::Patch { commit, .. } => Ok(commit),
            Self::Outcome { .. } => anyhow::bail!("effect commit receipt is not a patch commit"),
        }
    }
}

/// The body of `commit_resource_effect` inside a caller's transaction.
#[allow(clippy::too_many_arguments)]
fn commit_effect_outcome_in_transaction(
    tx: &Transaction<'_>,
    generation: &str,
    idempotency_key: &str,
    operation: &str,
    fingerprint: &str,
    outcome: &ResourceEffectOutcome,
    outcome_value: &Value,
    outcome_json: &str,
    deltas: Option<&Value>,
) -> anyhow::Result<u64> {
    let (stored_operation, stored_fingerprint, state, intent_json) =
        read_effect_record(tx, idempotency_key)?.ok_or_else(|| {
            anyhow::anyhow!("resource effect intent {idempotency_key:?} is missing")
        })?;
    require_effect_identity(
        idempotency_key,
        operation,
        fingerprint,
        &stored_operation,
        &stored_fingerprint,
    )?;
    anyhow::ensure!(
        state == "executing",
        "resource effect {idempotency_key:?} cannot commit from state {state:?}"
    );
    let previous_revision = transaction_resource_revision(tx)?;
    let revision = if let Some(deltas) = deltas {
        let revision = previous_revision
            .checked_add(1)
            .ok_or_else(|| anyhow::anyhow!("resource revision exhausted"))?;
        tx.execute(
            "UPDATE meta SET value = ?1 WHERE key = 'resource_revision'",
            [revision.to_string()],
        )?;
        append_resource_journal_record(
            tx,
            revision,
            previous_revision,
            "resource-api",
            idempotency_key,
            operation,
            None,
            outcome_value,
            deltas,
        )?;
        resource_store::prune_resource_mutations(tx)?;
        revision
    } else {
        append_resource_effect_journal_record(
            tx,
            idempotency_key,
            operation,
            &serde_json::from_str(&intent_json)?,
            Some(outcome_value),
            match outcome {
                ResourceEffectOutcome::Success(_) => ResourceEffectJournalState::Succeeded,
                ResourceEffectOutcome::Failure(_) => ResourceEffectJournalState::Failed,
            },
        )?;
        previous_revision
    };
    tx.execute(
        "UPDATE resource_effect_receipts
         SET state = 'committed', outcome_json = ?2, committed_revision = ?3
         WHERE idempotency_key = ?1 AND state = 'executing'",
        params![
            idempotency_key,
            outcome_json,
            i64::try_from(revision).context("resource revision exceeds SQLite range")?,
        ],
    )?;
    let correlated = match outcome {
        ResourceEffectOutcome::Success(created_path) => tx.execute(
            "UPDATE resource_creation_receipts
             SET state = 'created', execution_generation = NULL,
                 created_path_json = ?2, generation = ?3, committed_revision = ?4
             WHERE idempotency_key = ?1 AND execution_kind = 'effect'
               AND state = 'executing'",
            params![
                idempotency_key,
                canonical_json(created_path)?,
                generation,
                i64::try_from(revision).context("resource revision exceeds SQLite range")?,
            ],
        )?,
        ResourceEffectOutcome::Failure(_) => tx.execute(
            "UPDATE resource_creation_receipts
             SET state = 'not_applied', execution_generation = NULL,
                 created_path_json = NULL, generation = NULL, committed_revision = NULL
             WHERE idempotency_key = ?1 AND execution_kind = 'effect'
               AND state = 'executing'",
            [idempotency_key],
        )?,
    };
    let creation_count: i64 = tx.query_row(
        "SELECT COUNT(*) FROM resource_creation_receipts WHERE idempotency_key = ?1",
        [idempotency_key],
        |row| row.get(0),
    )?;
    anyhow::ensure!(
        creation_count == 0 || correlated == 1,
        "correlated resource effect could not commit its outcome"
    );
    record_resource_input_receipt_completion(tx, idempotency_key, operation)?;
    Ok(revision)
}

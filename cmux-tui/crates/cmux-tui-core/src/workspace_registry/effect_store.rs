use super::resource_store::{
    apply_resource_patch, complete_terminal_close_patch, validate_resource_patch,
};
use super::*;
use crate::resource::ResourceError;
use serde_json::json;

/// Transient input and viewport interactions keep a finite exactly-once replay
/// window. Cleanup runs in batches so high-frequency traffic does not pay for
/// a pruning query on every event. A running registry may temporarily retain
/// this many extra committed rows; startup always removes the slack.
const RESOURCE_INPUT_RECEIPT_CAPACITY: usize = 4096;
const RESOURCE_INPUT_RECEIPT_PRUNE_INTERVAL: usize = 128;
const TRANSIENT_INPUT_EFFECT_SQL: &str = "(
  effect.operation GLOB 'terminal.input.*'
  OR effect.operation GLOB 'browser.input.*'
  OR effect.operation = 'sidebar_view.input'
  OR effect.operation = 'terminal.viewport.scroll'
)";

#[derive(Debug, Clone, PartialEq)]
pub enum ResourceEffectPreparation {
    Execute { intent: Value, resumed: bool },
    Committed { outcome: ResourceEffectOutcome, revision: u64 },
    Indeterminate,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "value", rename_all = "snake_case")]
pub enum ResourceEffectOutcome {
    Success(Value),
    Failure(ResourceError),
}

#[derive(Debug, Clone, PartialEq)]
pub enum ResourceCreationPreparation {
    Execute { idempotency_key: String, intent: Value, resumed: bool },
    Created { created_path: Value, generation: String, revision: u64 },
    Failed { error: ResourceError, revision: u64 },
    Blocked { idempotency_key: String, operation: String },
}

#[derive(Debug, Clone, PartialEq)]
pub struct ResourceCreationRecovery {
    pub correlation_key: String,
    pub operation: String,
    pub idempotency_key: String,
    pub fingerprint: Value,
    pub intent: Value,
    pub attempt: u64,
    pub interrupted: bool,
}

#[derive(Debug, Clone)]
pub(crate) struct ResourceWorkspaceClose {
    pub workspace_key: String,
    pub remaining_workspaces: Vec<RegistryWorkspace>,
    pub active_workspace: Option<WorkspacePublicId>,
    pub legacy_result: Value,
}

#[derive(Debug, Clone)]
pub(crate) struct ResourceCloseCommit {
    pub resource: ResourcePatchCommit,
    pub workspace_revision: Option<u64>,
    pub terminal_batch: TerminalBatchClose,
}

pub(super) fn create_resource_effect_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS resource_effect_receipts (
           idempotency_key TEXT PRIMARY KEY NOT NULL,
           operation TEXT NOT NULL,
           fingerprint TEXT NOT NULL,
           intent_json TEXT NOT NULL,
           state TEXT NOT NULL CHECK(
             state IN ('pending', 'executing', 'committed', 'indeterminate')
           ),
           outcome_json TEXT,
           committed_revision INTEGER,
           CHECK (
             (state = 'committed' AND outcome_json IS NOT NULL
               AND committed_revision IS NOT NULL) OR
             (state != 'committed' AND outcome_json IS NULL
               AND committed_revision IS NULL)
             )
         );
         CREATE TABLE IF NOT EXISTS resource_creation_receipts (
           correlation_key TEXT PRIMARY KEY NOT NULL,
           operation TEXT NOT NULL,
           fingerprint TEXT NOT NULL,
           idempotency_key TEXT NOT NULL,
           intent_json TEXT NOT NULL,
           execution_kind TEXT NOT NULL CHECK(execution_kind IN ('pure', 'effect')),
           attempt INTEGER NOT NULL CHECK(attempt >= 1),
           state TEXT NOT NULL CHECK(
             state IN ('prepared', 'executing', 'created', 'not_applied', 'indeterminate')
           ),
           execution_generation TEXT,
           created_path_json TEXT,
           generation TEXT,
           committed_revision INTEGER,
           CHECK (
             (state = 'created' AND created_path_json IS NOT NULL
               AND generation IS NOT NULL AND committed_revision IS NOT NULL) OR
             (state != 'created' AND created_path_json IS NULL
               AND generation IS NULL AND committed_revision IS NULL)
           )
         );
         CREATE INDEX IF NOT EXISTS resource_creation_receipts_idempotency
           ON resource_creation_receipts(idempotency_key);
         CREATE INDEX IF NOT EXISTS resource_effect_receipts_by_operation_revision
           ON resource_effect_receipts(operation, committed_revision DESC)
           WHERE state = 'committed';
         CREATE TABLE IF NOT EXISTS resource_input_receipt_completions (
           sequence INTEGER PRIMARY KEY AUTOINCREMENT,
           idempotency_key TEXT UNIQUE NOT NULL,
           FOREIGN KEY(idempotency_key) REFERENCES resource_effect_receipts(idempotency_key)
             ON DELETE CASCADE
         );",
    )?;
    Ok(())
}

/// Adds completion ordering for pre-retention databases and enforces the
/// startup bound. `committed_revision` cannot provide this order because
/// receipt-only interactions deliberately do not advance the public revision.
pub(super) fn initialize_resource_input_receipt_retention(
    transaction: &Transaction<'_>,
) -> anyhow::Result<()> {
    transaction.execute(
        &format!(
            "INSERT INTO resource_input_receipt_completions(idempotency_key)
             SELECT effect.idempotency_key
             FROM resource_effect_receipts AS effect
             WHERE effect.state = 'committed'
               AND {TRANSIENT_INPUT_EFFECT_SQL}
               AND NOT EXISTS (
                 SELECT 1
                 FROM resource_input_receipt_completions AS completion
                 WHERE completion.idempotency_key = effect.idempotency_key
               )
             ORDER BY effect.committed_revision ASC, effect.rowid ASC"
        ),
        [],
    )?;
    prune_resource_input_receipts(transaction)?;
    Ok(())
}

/// Schema 6 and earlier stored raw interactive input in effect fingerprints
/// and intents. Those rows cannot be re-keyed without retaining the secret,
/// so the prelaunch migration discards them before the database is vacuumed.
/// Browser navigation is deliberately excluded because its URL is public,
/// durable browser topology rather than transient input.
pub(super) fn delete_legacy_sensitive_effect_receipts(
    transaction: &Transaction<'_>,
) -> anyhow::Result<()> {
    const SENSITIVE_EFFECTS: &str = "operation GLOB 'terminal.input.*'
         OR operation GLOB 'browser.input.*'
         OR operation = 'sidebar_view.input'";
    transaction.execute(
        "DELETE FROM resource_creation_receipts
         WHERE EXISTS (
           SELECT 1 FROM resource_effect_receipts AS effect
           WHERE effect.idempotency_key = resource_creation_receipts.idempotency_key
             AND effect.operation = resource_creation_receipts.operation
             AND (
               effect.operation GLOB 'terminal.input.*'
               OR effect.operation GLOB 'browser.input.*'
               OR effect.operation = 'sidebar_view.input'
             )
         )",
        [],
    )?;
    transaction
        .execute(&format!("DELETE FROM resource_effect_receipts WHERE {SENSITIVE_EFFECTS}"), [])?;
    Ok(())
}

pub(super) fn recover_resource_effects(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    let interrupted = {
        let mut statement = transaction.prepare(
            "SELECT idempotency_key, operation, intent_json
             FROM resource_effect_receipts
             WHERE state = 'executing'
               AND NOT EXISTS (
                 SELECT 1 FROM resource_creation_receipts creation
                 WHERE creation.idempotency_key = resource_effect_receipts.idempotency_key
                   AND creation.execution_kind = 'effect'
                   AND creation.state = 'executing'
               )
             ORDER BY idempotency_key",
        )?;
        statement
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?, row.get::<_, String>(2)?))
            })?
            .collect::<Result<Vec<_>, _>>()?
    };
    transaction.execute(
        "UPDATE resource_effect_receipts
         SET state = 'indeterminate'
         WHERE state = 'executing'
           AND NOT EXISTS (
             SELECT 1 FROM resource_creation_receipts creation
             WHERE creation.idempotency_key = resource_effect_receipts.idempotency_key
               AND creation.execution_kind = 'effect'
               AND creation.state = 'executing'
           )",
        [],
    )?;
    for (idempotency_key, operation, intent_json) in interrupted {
        append_resource_effect_journal_record(
            transaction,
            &idempotency_key,
            &operation,
            &serde_json::from_str(&intent_json)?,
            None,
            ResourceEffectJournalState::Indeterminate,
        )?;
    }
    transaction.execute(
        "UPDATE resource_creation_receipts
         SET state = 'prepared', execution_generation = NULL
         WHERE state = 'executing' AND execution_kind = 'pure'",
        [],
    )?;
    Ok(())
}

impl WorkspaceRegistry {
    pub fn lookup_resource_effect(
        &self,
        idempotency_key: &str,
        operation: &str,
        fingerprint: &Value,
    ) -> anyhow::Result<Option<ResourceEffectPreparation>> {
        validate_identifier("idempotency key", idempotency_key)?;
        validate_identifier("resource operation", operation)?;
        let fingerprint = canonical_json(fingerprint)?;
        read_effect_preparation(&self.connection, idempotency_key, operation, &fingerprint)
    }

    pub fn lookup_resource_creation(
        &self,
        correlation_key: &str,
        idempotency_key: &str,
        operation: &str,
        fingerprint: &Value,
        effectful: bool,
    ) -> anyhow::Result<Option<ResourceCreationPreparation>> {
        validate_correlation_key(correlation_key)?;
        validate_identifier("idempotency key", idempotency_key)?;
        validate_identifier("resource operation", operation)?;
        let fingerprint = canonical_json(fingerprint)?;
        let Some(stored) = read_creation_record(&self.connection, correlation_key)? else {
            return Ok(None);
        };
        require_creation_identity(
            correlation_key,
            operation,
            &fingerprint,
            &stored.operation,
            &stored.fingerprint,
        )?;
        anyhow::ensure!(
            stored.execution_kind == if effectful { "effect" } else { "pure" },
            "creation receipt {correlation_key:?} changed execution kind"
        );
        if effectful
            && stored.idempotency_key != idempotency_key
            && let Some(ResourceEffectPreparation::Committed {
                outcome: ResourceEffectOutcome::Failure(error),
                revision,
            }) =
                read_effect_preparation(&self.connection, idempotency_key, operation, &fingerprint)?
        {
            return Ok(Some(ResourceCreationPreparation::Failed { error, revision }));
        }
        let preparation = match stored.state.as_str() {
            "created" => ResourceCreationPreparation::Created {
                created_path: serde_json::from_str(
                    stored
                        .created_path_json
                        .as_deref()
                        .ok_or_else(|| anyhow::anyhow!("created resource omitted its path"))?,
                )?,
                generation: stored
                    .generation
                    .ok_or_else(|| anyhow::anyhow!("created resource omitted its generation"))?,
                revision: u64::try_from(
                    stored
                        .committed_revision
                        .ok_or_else(|| anyhow::anyhow!("created resource omitted its revision"))?,
                )
                .context("stored creation revision is negative")?,
            },
            "prepared" if stored.idempotency_key == idempotency_key => {
                if effectful {
                    match read_effect_preparation(
                        &self.connection,
                        idempotency_key,
                        operation,
                        &fingerprint,
                    )? {
                        Some(ResourceEffectPreparation::Execute { .. }) => {}
                        Some(
                            ResourceEffectPreparation::Committed { .. }
                            | ResourceEffectPreparation::Indeterminate,
                        ) => {
                            return Ok(Some(ResourceCreationPreparation::Blocked {
                                idempotency_key: stored.idempotency_key,
                                operation: stored.operation,
                            }));
                        }
                        None => {
                            anyhow::bail!("creation effect receipt {idempotency_key:?} is missing");
                        }
                    }
                }
                ResourceCreationPreparation::Execute {
                    idempotency_key: stored.idempotency_key,
                    intent: serde_json::from_str(&stored.intent_json)?,
                    resumed: true,
                }
            }
            "not_applied" if stored.idempotency_key == idempotency_key => {
                let Some(ResourceEffectPreparation::Committed {
                    outcome: ResourceEffectOutcome::Failure(error),
                    revision,
                }) = read_effect_preparation(
                    &self.connection,
                    idempotency_key,
                    operation,
                    &fingerprint,
                )?
                else {
                    anyhow::bail!(
                        "not-applied creation {correlation_key:?} omitted its failed effect receipt"
                    );
                };
                ResourceCreationPreparation::Failed { error, revision }
            }
            "not_applied" => return Ok(None),
            "prepared" | "executing" | "indeterminate" => ResourceCreationPreparation::Blocked {
                idempotency_key: stored.idempotency_key,
                operation: stored.operation,
            },
            other => anyhow::bail!("invalid resource creation state {other:?}"),
        };
        Ok(Some(preparation))
    }

    #[allow(clippy::too_many_arguments)]
    pub fn prepare_resource_creation(
        &mut self,
        correlation_key: &str,
        idempotency_key: &str,
        operation: &str,
        fingerprint: &Value,
        intent: &Value,
        effectful: bool,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
    ) -> anyhow::Result<ResourceCreationPreparation> {
        validate_correlation_key(correlation_key)?;
        validate_identifier("idempotency key", idempotency_key)?;
        validate_identifier("resource operation", operation)?;
        let fingerprint = canonical_json(fingerprint)?;
        let intent_json = canonical_json(intent)?;
        let execution_kind = if effectful { "effect" } else { "pure" };
        let tx = self.connection.transaction()?;
        if let Some(stored) = read_creation_record(&tx, correlation_key)? {
            require_creation_identity(
                correlation_key,
                operation,
                &fingerprint,
                &stored.operation,
                &stored.fingerprint,
            )?;
            anyhow::ensure!(
                stored.execution_kind == execution_kind,
                "creation receipt {correlation_key:?} changed execution kind"
            );
            if effectful
                && stored.idempotency_key != idempotency_key
                && let Some(ResourceEffectPreparation::Committed {
                    outcome: ResourceEffectOutcome::Failure(error),
                    revision,
                }) = read_effect_preparation(&tx, idempotency_key, operation, &fingerprint)?
            {
                tx.commit()?;
                return Ok(ResourceCreationPreparation::Failed { error, revision });
            }
            let preparation = match stored.state.as_str() {
                "created" => {
                    ResourceCreationPreparation::Created {
                        created_path: serde_json::from_str(
                            stored.created_path_json.as_deref().ok_or_else(|| {
                                anyhow::anyhow!("created resource omitted its path")
                            })?,
                        )?,
                        generation: stored.generation.ok_or_else(|| {
                            anyhow::anyhow!("created resource omitted its generation")
                        })?,
                        revision: u64::try_from(stored.committed_revision.ok_or_else(|| {
                            anyhow::anyhow!("created resource omitted its revision")
                        })?)
                        .context("stored creation revision is negative")?,
                    }
                }
                "prepared" if stored.idempotency_key == idempotency_key => {
                    require_creation_preconditions(
                        &tx,
                        &self.generation,
                        expected_generation,
                        expected_revision,
                    )?;
                    if effectful {
                        match read_effect_preparation(
                            &tx,
                            idempotency_key,
                            operation,
                            &fingerprint,
                        )? {
                            Some(ResourceEffectPreparation::Execute { .. }) => {}
                            Some(
                                ResourceEffectPreparation::Committed { .. }
                                | ResourceEffectPreparation::Indeterminate,
                            ) => {
                                tx.commit()?;
                                return Ok(ResourceCreationPreparation::Blocked {
                                    idempotency_key: stored.idempotency_key,
                                    operation: stored.operation,
                                });
                            }
                            None => {
                                anyhow::bail!(
                                    "creation effect receipt {idempotency_key:?} is missing"
                                );
                            }
                        }
                    }
                    ResourceCreationPreparation::Execute {
                        idempotency_key: stored.idempotency_key,
                        intent: serde_json::from_str(&stored.intent_json)?,
                        resumed: true,
                    }
                }
                "not_applied" if stored.idempotency_key == idempotency_key => {
                    let Some(ResourceEffectPreparation::Committed {
                        outcome: ResourceEffectOutcome::Failure(error),
                        revision,
                    }) = read_effect_preparation(&tx, idempotency_key, operation, &fingerprint)?
                    else {
                        anyhow::bail!(
                            "not-applied creation {correlation_key:?} omitted its failed effect receipt"
                        );
                    };
                    ResourceCreationPreparation::Failed { error, revision }
                }
                "not_applied" if effectful => {
                    require_creation_preconditions(
                        &tx,
                        &self.generation,
                        expected_generation,
                        expected_revision,
                    )?;
                    anyhow::ensure!(
                        read_effect_record(&tx, idempotency_key)?.is_none(),
                        "resource effect receipt {idempotency_key:?} already exists without its creation correlation"
                    );
                    tx.execute(
                        "INSERT INTO resource_effect_receipts(
                           idempotency_key, operation, fingerprint, intent_json, state,
                           outcome_json, committed_revision
                         ) VALUES(?1, ?2, ?3, ?4, 'pending', NULL, NULL)",
                        params![idempotency_key, operation, fingerprint, &stored.intent_json,],
                    )?;
                    let changed = tx.execute(
                        "UPDATE resource_creation_receipts
                         SET idempotency_key = ?2, state = 'prepared',
                             execution_generation = NULL, attempt = attempt + 1
                         WHERE correlation_key = ?1 AND state = 'not_applied'",
                        params![correlation_key, idempotency_key],
                    )?;
                    anyhow::ensure!(changed == 1, "creation attempt changed while rebinding");
                    let stable_intent: Value = serde_json::from_str(&stored.intent_json)?;
                    tx.commit()?;
                    return Ok(ResourceCreationPreparation::Execute {
                        idempotency_key: idempotency_key.to_string(),
                        intent: stable_intent,
                        resumed: false,
                    });
                }
                "prepared" | "executing" | "indeterminate" => {
                    ResourceCreationPreparation::Blocked {
                        idempotency_key: stored.idempotency_key,
                        operation: stored.operation,
                    }
                }
                other => anyhow::bail!("invalid resource creation state {other:?}"),
            };
            tx.commit()?;
            return Ok(preparation);
        }
        require_creation_preconditions(
            &tx,
            &self.generation,
            expected_generation,
            expected_revision,
        )?;
        if effectful {
            anyhow::ensure!(
                read_effect_record(&tx, idempotency_key)?.is_none(),
                "resource effect receipt {idempotency_key:?} already exists without its creation correlation"
            );
            tx.execute(
                "INSERT INTO resource_effect_receipts(
                   idempotency_key, operation, fingerprint, intent_json, state,
                   outcome_json, committed_revision
                 ) VALUES(?1, ?2, ?3, ?4, 'pending', NULL, NULL)",
                params![idempotency_key, operation, fingerprint, intent_json],
            )?;
        }
        tx.execute(
            "INSERT INTO resource_creation_receipts(
               correlation_key, operation, fingerprint, idempotency_key, intent_json,
               execution_kind, attempt, state, execution_generation, created_path_json,
               generation, committed_revision
             ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, 1, 'prepared', NULL, NULL, NULL, NULL)",
            params![
                correlation_key,
                operation,
                fingerprint,
                idempotency_key,
                intent_json,
                execution_kind,
            ],
        )?;
        tx.commit()?;
        Ok(ResourceCreationPreparation::Execute {
            idempotency_key: idempotency_key.to_string(),
            intent: intent.clone(),
            resumed: false,
        })
    }

    pub fn resolve_resource_creation(&self, correlation_key: &str) -> anyhow::Result<Value> {
        validate_correlation_key(correlation_key)?;
        let Some(stored) = read_creation_record(&self.connection, correlation_key)? else {
            return Ok(json!({
                "correlation_key":correlation_key,
                "state":"not_applied",
                "recovery":"retry_new_idempotency_key",
            }));
        };
        let mut result = json!({
            "correlation_key":correlation_key,
            "operation":stored.operation,
            "idempotency_key":stored.idempotency_key,
        });
        match stored.state.as_str() {
            "prepared" => {
                result["state"] = json!("not_applied");
                result["recovery"] = json!("retry_same_idempotency_key");
            }
            "not_applied" => {
                result["state"] = json!("not_applied");
                result["recovery"] = json!("retry_new_idempotency_key");
            }
            "executing"
                if stored.execution_generation.as_deref() == Some(self.generation.as_str()) =>
            {
                result["state"] = json!("pending");
                result["recovery"] = json!("wait");
            }
            "executing" | "indeterminate" => {
                result["state"] = json!("indeterminate");
                result["recovery"] = json!("do_not_retry");
            }
            "created" => {
                result["state"] = json!("created");
                result["recovery"] = json!("none");
                result["created_path"] = serde_json::from_str(
                    stored
                        .created_path_json
                        .as_deref()
                        .ok_or_else(|| anyhow::anyhow!("created resource omitted its path"))?,
                )?;
                result["generation"] = json!(stored.generation.ok_or_else(|| {
                    anyhow::anyhow!("created resource omitted its generation")
                })?);
                result["revision"] = json!(
                    u64::try_from(stored.committed_revision.ok_or_else(|| {
                        anyhow::anyhow!("created resource omitted its revision")
                    })?)
                    .context("stored creation revision is negative")?
                    .to_string()
                );
            }
            other => anyhow::bail!("invalid resource creation state {other:?}"),
        }
        Ok(result)
    }

    pub fn resource_creation_recovery(
        &self,
        correlation_key: &str,
    ) -> anyhow::Result<Option<ResourceCreationRecovery>> {
        validate_correlation_key(correlation_key)?;
        let Some(stored) = read_creation_record(&self.connection, correlation_key)? else {
            return Ok(None);
        };
        if stored.state != "executing" || stored.execution_kind != "effect" {
            return Ok(None);
        }
        let interrupted = stored.execution_generation.as_deref() != Some(self.generation.as_str());
        Ok(Some(ResourceCreationRecovery {
            correlation_key: correlation_key.to_string(),
            operation: stored.operation,
            idempotency_key: stored.idempotency_key,
            fingerprint: serde_json::from_str(&stored.fingerprint)?,
            intent: serde_json::from_str(&stored.intent_json)?,
            attempt: stored.attempt,
            interrupted,
        }))
    }

    pub fn interrupted_resource_creation_recoveries(
        &self,
    ) -> anyhow::Result<Vec<ResourceCreationRecovery>> {
        let mut statement = self.connection.prepare(
            "SELECT correlation_key
             FROM resource_creation_receipts
             WHERE state = 'executing' AND execution_kind = 'effect'
               AND (execution_generation IS NULL OR execution_generation != ?1)
             ORDER BY correlation_key",
        )?;
        let correlations = statement
            .query_map([self.generation.as_str()], |row| row.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        correlations
            .into_iter()
            .map(|correlation_key| {
                self.resource_creation_recovery(&correlation_key)?.with_context(|| {
                    format!("interrupted resource creation {correlation_key:?} disappeared")
                })
            })
            .collect()
    }

    #[allow(clippy::too_many_arguments)]
    pub fn commit_resource_creation_patch(
        &mut self,
        correlation_key: &str,
        mutation: &WorkspaceMutation,
        operation: &str,
        fingerprint: &Value,
        patch: &ResourcePatch,
        result: &Value,
        created_path: &Value,
        deltas: &Value,
        workspace_ledger: Option<&ResourceWorkspaceLedger>,
        extra: Option<RegistryTransactionWrite<'_>>,
    ) -> anyhow::Result<(ResourcePatchCommit, Option<u64>)> {
        validate_correlation_key(correlation_key)?;
        validate_identifier("mutation id", &mutation.id)?;
        validate_identifier("mutation origin", &mutation.origin)?;
        validate_identifier("resource operation", operation)?;
        validate_resource_patch(patch)?;
        let fingerprint = canonical_json(fingerprint)?;
        let result_json = canonical_json(result)?;
        let created_path_json = canonical_json(created_path)?;
        let generation = self.generation.clone();
        let tx = self.connection.transaction()?;
        let stored = read_creation_record(&tx, correlation_key)?.ok_or_else(|| {
            anyhow::anyhow!("resource creation intent {correlation_key:?} is missing")
        })?;
        require_creation_identity(
            correlation_key,
            operation,
            &fingerprint,
            &stored.operation,
            &stored.fingerprint,
        )?;
        anyhow::ensure!(
            stored.idempotency_key == mutation.id,
            "creation receipt {correlation_key:?} belongs to another idempotency key"
        );
        anyhow::ensure!(
            stored.execution_kind == "pure" && stored.state == "prepared",
            "pure creation {correlation_key:?} cannot commit from state {:?}",
            stored.state
        );

        let previous_revision = transaction_resource_revision(&tx)?;
        let revision = previous_revision
            .checked_add(1)
            .ok_or_else(|| anyhow::anyhow!("resource revision exhausted"))?;
        let sqlite_revision =
            i64::try_from(revision).context("resource revision exceeds SQLite range")?;
        // Workspace-projection creations must advance the legacy workspace
        // ledger in this same transaction (the resource close path already
        // does); otherwise later legacy CAS mutations conflict forever.
        let workspace_revision = workspace_ledger
            .map(|ledger| {
                commit_workspace_registry_in_transaction(
                    &tx,
                    mutation,
                    &fingerprint,
                    None,
                    ledger.event_kind,
                    &ledger.workspace_key,
                    &ledger.workspaces,
                    &canonical_json(&ledger.legacy_result)?,
                )
                .map(|(revision, _)| revision)
            })
            .transpose()?;
        let patch = &apply_resource_patch(&tx, patch, sqlite_revision)?;
        // State rows (the ephemeral flag) land before the journal record, so
        // the batch's upserts already carry them.
        if let Some(extra) = extra {
            extra(&tx)?;
        }
        tx.execute(
            "UPDATE meta SET value = ?1 WHERE key = 'resource_revision'",
            [revision.to_string()],
        )?;
        tx.execute(
            "INSERT INTO resource_mutations(
               origin, idempotency_key, operation, fingerprint, result_json, committed_revision, actor_json
             ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![
                mutation.origin,
                mutation.id,
                operation,
                fingerprint,
                result_json,
                sqlite_revision,
                crate::workspace_registry::mutation_actor_json(&mutation.actor),
            ],
        )?;
        append_resource_journal_record(
            &tx,
            revision,
            previous_revision,
            &mutation.origin,
            &mutation.id,
            operation,
            Some(patch),
            result,
            deltas,
        )?;
        let changed = tx.execute(
            "UPDATE resource_creation_receipts
             SET state = 'created', created_path_json = ?2, generation = ?3,
                 committed_revision = ?4
             WHERE correlation_key = ?1 AND state = 'prepared'",
            params![correlation_key, created_path_json, generation, sqlite_revision],
        )?;
        anyhow::ensure!(changed == 1, "resource creation receipt changed during commit");
        // Once the receipt is terminal, this mutation belongs to the ordinary
        // replay window and must count toward a boundary compaction.
        resource_store::prune_resource_mutations(&tx)?;
        tx.commit()?;
        Ok((
            ResourcePatchCommit { revision, result: result.clone(), replayed: false },
            workspace_revision,
        ))
    }

    pub fn prepare_resource_effect(
        &mut self,
        idempotency_key: &str,
        operation: &str,
        fingerprint: &Value,
        intent: &Value,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
    ) -> anyhow::Result<ResourceEffectPreparation> {
        validate_identifier("idempotency key", idempotency_key)?;
        validate_identifier("resource operation", operation)?;
        let fingerprint = canonical_json(fingerprint)?;
        let intent_json = canonical_json(intent)?;
        let tx = self.connection.transaction()?;
        if let Some(preparation) =
            read_effect_preparation(&tx, idempotency_key, operation, &fingerprint)?
        {
            tx.commit()?;
            return Ok(preparation);
        }
        if let Some(expected) = expected_generation
            && expected != self.generation
        {
            anyhow::bail!(
                "resource generation conflict: expected {expected}, current {}",
                self.generation
            );
        }
        let revision = transaction_resource_revision(&tx)?;
        if let Some(expected) = expected_revision
            && expected != revision
        {
            anyhow::bail!("resource revision conflict: expected {expected}, current {revision}");
        }
        tx.execute(
            "INSERT INTO resource_effect_receipts(
               idempotency_key, operation, fingerprint, intent_json, state,
               outcome_json, committed_revision
             ) VALUES(?1, ?2, ?3, ?4, 'pending', NULL, NULL)",
            params![idempotency_key, operation, fingerprint, intent_json],
        )?;
        tx.commit()?;
        Ok(ResourceEffectPreparation::Execute { intent: intent.clone(), resumed: false })
    }

    pub fn mark_resource_effect_executing(
        &mut self,
        idempotency_key: &str,
        operation: &str,
        fingerprint: &Value,
    ) -> anyhow::Result<Value> {
        validate_identifier("idempotency key", idempotency_key)?;
        validate_identifier("resource operation", operation)?;
        let fingerprint = canonical_json(fingerprint)?;
        let generation = self.generation.clone();
        let tx = self.connection.transaction()?;
        let (stored_operation, stored_fingerprint, state, intent_json) =
            read_effect_record(&tx, idempotency_key)?.ok_or_else(|| {
                anyhow::anyhow!("resource effect intent {idempotency_key:?} is missing")
            })?;
        require_effect_identity(
            idempotency_key,
            operation,
            &fingerprint,
            &stored_operation,
            &stored_fingerprint,
        )?;
        anyhow::ensure!(
            state == "pending",
            "resource effect {idempotency_key:?} cannot execute from state {state:?}"
        );
        tx.execute(
            "UPDATE resource_effect_receipts
             SET state = 'executing'
             WHERE idempotency_key = ?1 AND state = 'pending'",
            [idempotency_key],
        )?;
        let correlated = tx.execute(
            "UPDATE resource_creation_receipts
             SET state = 'executing', execution_generation = ?2
             WHERE idempotency_key = ?1 AND execution_kind = 'effect' AND state = 'prepared'",
            params![idempotency_key, generation],
        )?;
        let creation_count: i64 = tx.query_row(
            "SELECT COUNT(*) FROM resource_creation_receipts WHERE idempotency_key = ?1",
            [idempotency_key],
            |row| row.get(0),
        )?;
        anyhow::ensure!(
            creation_count == 0 || correlated == 1,
            "correlated resource effect could not enter executing state"
        );
        tx.commit()?;
        Ok(serde_json::from_str(&intent_json)?)
    }

    pub fn commit_resource_effect(
        &mut self,
        idempotency_key: &str,
        operation: &str,
        fingerprint: &Value,
        outcome: &ResourceEffectOutcome,
        deltas: Option<&Value>,
    ) -> anyhow::Result<u64> {
        validate_identifier("idempotency key", idempotency_key)?;
        validate_identifier("resource operation", operation)?;
        let fingerprint = canonical_json(fingerprint)?;
        let outcome_value = serde_json::to_value(outcome)?;
        let outcome_json = canonical_json(&outcome_value)?;
        let generation = self.generation.clone();
        let tx = self.connection.transaction()?;
        let (stored_operation, stored_fingerprint, state, intent_json) =
            read_effect_record(&tx, idempotency_key)?.ok_or_else(|| {
                anyhow::anyhow!("resource effect intent {idempotency_key:?} is missing")
            })?;
        require_effect_identity(
            idempotency_key,
            operation,
            &fingerprint,
            &stored_operation,
            &stored_fingerprint,
        )?;
        anyhow::ensure!(
            state == "executing",
            "resource effect {idempotency_key:?} cannot commit from state {state:?}"
        );

        let previous_revision = transaction_resource_revision(&tx)?;
        let revision = if let Some(deltas) = deltas {
            let revision = previous_revision
                .checked_add(1)
                .ok_or_else(|| anyhow::anyhow!("resource revision exhausted"))?;
            tx.execute(
                "UPDATE meta SET value = ?1 WHERE key = 'resource_revision'",
                [revision.to_string()],
            )?;
            append_resource_journal_record(
                &tx,
                revision,
                previous_revision,
                "resource-api",
                idempotency_key,
                operation,
                None,
                &outcome_value,
                deltas,
            )?;
            resource_store::prune_resource_mutations(&tx)?;
            revision
        } else {
            append_resource_effect_journal_record(
                &tx,
                idempotency_key,
                operation,
                &serde_json::from_str(&intent_json)?,
                Some(&outcome_value),
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
        record_resource_input_receipt_completion(&tx, idempotency_key, operation)?;
        tx.commit()?;
        Ok(revision)
    }

    /// Atomically persists the durable topology produced by an external
    /// effect, its typed event delta, and the effect receipt outcome.
    ///
    /// Callers must transition the receipt to `executing` before performing
    /// the effect. A transaction failure leaves that receipt executing, so a
    /// restart converts it to `indeterminate` and never repeats the effect
    /// under the same key.
    pub fn commit_resource_effect_patch(
        &mut self,
        idempotency_key: &str,
        operation: &str,
        fingerprint: &Value,
        patch: &ResourcePatch,
        result: &Value,
        deltas: &Value,
    ) -> anyhow::Result<ResourcePatchCommit> {
        validate_identifier("idempotency key", idempotency_key)?;
        validate_identifier("resource operation", operation)?;
        validate_resource_patch(patch)?;
        #[cfg(test)]
        if self.resource_patch_failures_remaining.get() > 0 {
            self.resource_patch_failures_remaining
                .set(self.resource_patch_failures_remaining.get() - 1);
            anyhow::bail!("forced one-shot resource patch failure");
        }
        let fingerprint = canonical_json(fingerprint)?;
        let outcome = ResourceEffectOutcome::Success(result.clone());
        let outcome = serde_json::to_value(&outcome)?;
        let outcome_json = canonical_json(&outcome)?;
        let generation = self.generation.clone();
        let tx = self.connection.transaction()?;
        let commit = commit_resource_effect_patch_in_transaction(
            &tx,
            &generation,
            idempotency_key,
            operation,
            &fingerprint,
            patch,
            result,
            &outcome,
            &outcome_json,
            deltas,
        )?;
        tx.commit()?;
        Ok(commit)
    }

    #[cfg(test)]
    pub(crate) fn set_resource_patch_failures_remaining(&self, failures: u64) {
        self.resource_patch_failures_remaining.set(failures);
    }

    /// Commit every durable side of a topology close before the mux detaches
    /// the corresponding live surfaces. Legacy workspace and terminal event
    /// streams advance in this same transaction as the public tombstones and
    /// effect receipt, so a crash can observe only the complete old or new
    /// topology.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn commit_resource_close_patch(
        &mut self,
        idempotency_key: &str,
        operation: &str,
        fingerprint: &Value,
        patch: &ResourcePatch,
        result: &Value,
        deltas: &Value,
        terminals: &[(String, Option<String>)],
        workspace_close: Option<&ResourceWorkspaceClose>,
    ) -> anyhow::Result<ResourceCloseCommit> {
        validate_identifier("idempotency key", idempotency_key)?;
        validate_identifier("resource operation", operation)?;
        let mutation = WorkspaceMutation::new(idempotency_key, "resource-api")?;
        validate_terminal_batch_close(&mutation, terminals)?;
        let fingerprint = canonical_json(fingerprint)?;
        let outcome = ResourceEffectOutcome::Success(result.clone());
        let outcome = serde_json::to_value(&outcome)?;
        let outcome_json = canonical_json(&outcome)?;
        let generation = self.generation.clone();
        let deltas = &self.prune_stated_topology_deltas(deltas)?;
        let tx = self.connection.transaction()?;
        let (patch, deltas) = complete_terminal_close_patch(&tx, terminals, patch, deltas)?;

        let (workspace_revision, terminal_batch) = if let Some(close) = workspace_close {
            if let Some(active_workspace) = close.active_workspace.as_ref() {
                anyhow::ensure!(
                    close
                        .remaining_workspaces
                        .iter()
                        .any(|workspace| &workspace.public_id == active_workspace),
                    "active workspace is absent from the post-close registry: {active_workspace}"
                );
            }
            let result_json = canonical_json(&close.legacy_result)?;
            let (revision, terminal_batch) = commit_workspace_registry_in_transaction(
                &tx,
                &mutation,
                &fingerprint,
                None,
                "workspace-closed",
                &close.workspace_key,
                &close.remaining_workspaces,
                &result_json,
            )?;
            (Some(revision), terminal_batch)
        } else {
            (None, close_terminals_in_transaction(&tx, &mutation, terminals, "topology-closed")?)
        };
        let resource = commit_resource_effect_patch_in_transaction(
            &tx,
            &generation,
            idempotency_key,
            operation,
            &fingerprint,
            &patch,
            result,
            &outcome,
            &outcome_json,
            &deltas,
        )?;
        tx.commit()?;
        self.record_public_fold(
            resource.revision.saturating_sub(1),
            resource.revision,
            &deltas,
            true,
        );
        Ok(ResourceCloseCommit { resource, workspace_revision, terminal_batch })
    }

    pub fn mark_resource_effect_indeterminate(
        &mut self,
        idempotency_key: &str,
    ) -> anyhow::Result<()> {
        validate_identifier("idempotency key", idempotency_key)?;
        let tx = self.connection.transaction()?;
        let Some((operation, _, state, intent_json)) = read_effect_record(&tx, idempotency_key)?
        else {
            anyhow::bail!("resource effect intent {idempotency_key:?} is missing");
        };
        if state != "executing" {
            tx.commit()?;
            return Ok(());
        }
        let changed = tx.execute(
            "UPDATE resource_effect_receipts
             SET state = 'indeterminate', outcome_json = NULL, committed_revision = NULL
             WHERE idempotency_key = ?1 AND state = 'executing'",
            [idempotency_key],
        )?;
        anyhow::ensure!(changed == 1, "resource effect changed while marking indeterminate");
        tx.execute(
            "UPDATE resource_creation_receipts
             SET state = 'indeterminate', execution_generation = NULL,
                 created_path_json = NULL, generation = NULL, committed_revision = NULL
             WHERE idempotency_key = ?1 AND execution_kind = 'effect'
               AND state = 'executing'",
            [idempotency_key],
        )?;
        append_resource_effect_journal_record(
            &tx,
            idempotency_key,
            &operation,
            &serde_json::from_str(&intent_json)?,
            None,
            ResourceEffectJournalState::Indeterminate,
        )?;
        tx.commit()?;
        Ok(())
    }
}

#[allow(clippy::too_many_arguments)]
fn commit_resource_effect_patch_in_transaction(
    transaction: &Transaction<'_>,
    generation: &str,
    idempotency_key: &str,
    operation: &str,
    fingerprint: &str,
    patch: &ResourcePatch,
    result: &Value,
    outcome: &Value,
    outcome_json: &str,
    deltas: &Value,
) -> anyhow::Result<ResourcePatchCommit> {
    let (stored_operation, stored_fingerprint, state, _) =
        read_effect_record(transaction, idempotency_key)?.ok_or_else(|| {
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

    let previous_revision = transaction_resource_revision(transaction)?;
    let revision = previous_revision
        .checked_add(1)
        .ok_or_else(|| anyhow::anyhow!("resource revision exhausted"))?;
    let sqlite_revision =
        i64::try_from(revision).context("resource revision exceeds SQLite range")?;
    let patch = &apply_resource_patch(transaction, patch, sqlite_revision)?;
    transaction.execute(
        "UPDATE meta SET value = ?1 WHERE key = 'resource_revision'",
        [revision.to_string()],
    )?;
    append_resource_journal_record(
        transaction,
        revision,
        previous_revision,
        "resource-api",
        idempotency_key,
        operation,
        Some(patch),
        outcome,
        deltas,
    )?;
    resource_store::prune_resource_mutations(transaction)?;
    transaction.execute(
        "UPDATE resource_effect_receipts
         SET state = 'committed', outcome_json = ?2, committed_revision = ?3
         WHERE idempotency_key = ?1 AND state = 'executing'",
        params![idempotency_key, outcome_json, sqlite_revision],
    )?;
    let correlated = transaction.execute(
        "UPDATE resource_creation_receipts
         SET state = 'created', execution_generation = NULL,
             created_path_json = ?2, generation = ?3, committed_revision = ?4
         WHERE idempotency_key = ?1 AND execution_kind = 'effect'
           AND state = 'executing'",
        params![idempotency_key, canonical_json(result)?, generation, sqlite_revision],
    )?;
    let creation_count: i64 = transaction.query_row(
        "SELECT COUNT(*) FROM resource_creation_receipts WHERE idempotency_key = ?1",
        [idempotency_key],
        |row| row.get(0),
    )?;
    anyhow::ensure!(
        creation_count == 0 || correlated == 1,
        "correlated resource effect could not enter created state"
    );
    record_resource_input_receipt_completion(transaction, idempotency_key, operation)?;
    Ok(ResourcePatchCommit { revision, result: result.clone(), replayed: false })
}

struct StoredCreation {
    operation: String,
    fingerprint: String,
    idempotency_key: String,
    intent_json: String,
    execution_kind: String,
    attempt: u64,
    state: String,
    execution_generation: Option<String>,
    created_path_json: Option<String>,
    generation: Option<String>,
    committed_revision: Option<i64>,
}

fn read_creation_record(
    connection: &Connection,
    correlation_key: &str,
) -> anyhow::Result<Option<StoredCreation>> {
    connection
        .query_row(
            "SELECT operation, fingerprint, idempotency_key, intent_json, execution_kind,
                    attempt, state, execution_generation, created_path_json, generation,
                    committed_revision
             FROM resource_creation_receipts
             WHERE correlation_key = ?1",
            [correlation_key],
            |row| {
                Ok(StoredCreation {
                    operation: row.get(0)?,
                    fingerprint: row.get(1)?,
                    idempotency_key: row.get(2)?,
                    intent_json: row.get(3)?,
                    execution_kind: row.get(4)?,
                    attempt: u64::try_from(row.get::<_, i64>(5)?)
                        .map_err(|_| rusqlite::Error::IntegralValueOutOfRange(5, i64::MAX))?,
                    state: row.get(6)?,
                    execution_generation: row.get(7)?,
                    created_path_json: row.get(8)?,
                    generation: row.get(9)?,
                    committed_revision: row.get(10)?,
                })
            },
        )
        .optional()
        .map_err(Into::into)
}

fn require_creation_identity(
    correlation_key: &str,
    operation: &str,
    fingerprint: &str,
    stored_operation: &str,
    stored_fingerprint: &str,
) -> anyhow::Result<()> {
    if operation != stored_operation || fingerprint != stored_fingerprint {
        return Err(anyhow::Error::new(ResourceError::creation_conflict(
            correlation_key,
            stored_operation,
            operation,
            stored_fingerprint,
            fingerprint,
        )));
    }
    Ok(())
}

fn require_creation_preconditions(
    transaction: &Transaction<'_>,
    generation: &str,
    expected_generation: Option<&str>,
    expected_revision: Option<u64>,
) -> anyhow::Result<()> {
    if let Some(expected) = expected_generation
        && expected != generation
    {
        anyhow::bail!("resource generation conflict: expected {expected}, current {generation}");
    }
    let revision = transaction_resource_revision(transaction)?;
    if let Some(expected) = expected_revision
        && expected != revision
    {
        anyhow::bail!("resource revision conflict: expected {expected}, current {revision}");
    }
    Ok(())
}

fn validate_correlation_key(correlation_key: &str) -> anyhow::Result<()> {
    let bytes = correlation_key.len();
    if !(1..=128).contains(&bytes) {
        return Err(anyhow::Error::new(ResourceError::validation_invalid(
            Some("correlation_key"),
            "correlation_key must contain 1 to 128 UTF-8 bytes",
        )));
    }
    Ok(())
}

fn read_effect_preparation(
    connection: &Connection,
    idempotency_key: &str,
    operation: &str,
    fingerprint: &str,
) -> anyhow::Result<Option<ResourceEffectPreparation>> {
    let stored = connection
        .query_row(
            "SELECT operation, fingerprint, intent_json, state, outcome_json,
                    committed_revision
             FROM resource_effect_receipts
             WHERE idempotency_key = ?1",
            [idempotency_key],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, Option<String>>(4)?,
                    row.get::<_, Option<i64>>(5)?,
                ))
            },
        )
        .optional()?;
    let Some((
        stored_operation,
        stored_fingerprint,
        intent_json,
        state,
        outcome_json,
        committed_revision,
    )) = stored
    else {
        return Ok(None);
    };
    require_effect_identity(
        idempotency_key,
        operation,
        fingerprint,
        &stored_operation,
        &stored_fingerprint,
    )?;
    let preparation =
        match state.as_str() {
            "pending" => ResourceEffectPreparation::Execute {
                intent: serde_json::from_str(&intent_json)?,
                resumed: true,
            },
            "executing" | "indeterminate" => ResourceEffectPreparation::Indeterminate,
            "committed" => {
                let outcome = serde_json::from_str(outcome_json.as_deref().ok_or_else(|| {
                    anyhow::anyhow!("committed resource effect omitted outcome")
                })?)?;
                let revision = u64::try_from(committed_revision.ok_or_else(|| {
                    anyhow::anyhow!("committed resource effect omitted revision")
                })?)
                .context("stored resource effect revision is negative")?;
                ResourceEffectPreparation::Committed { outcome, revision }
            }
            other => anyhow::bail!("invalid resource effect state {other:?}"),
        };
    Ok(Some(preparation))
}

fn read_effect_record(
    connection: &Connection,
    idempotency_key: &str,
) -> anyhow::Result<Option<(String, String, String, String)>> {
    connection
        .query_row(
            "SELECT operation, fingerprint, state, intent_json
             FROM resource_effect_receipts
             WHERE idempotency_key = ?1",
            [idempotency_key],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        )
        .optional()
        .map_err(Into::into)
}

fn require_effect_identity(
    idempotency_key: &str,
    operation: &str,
    fingerprint: &str,
    stored_operation: &str,
    stored_fingerprint: &str,
) -> anyhow::Result<()> {
    if operation != stored_operation || fingerprint != stored_fingerprint {
        anyhow::bail!(
            "idempotency.conflict: key {idempotency_key} committed_operation {stored_operation} was reused with different input"
        );
    }
    Ok(())
}

fn is_transient_input_operation(operation: &str) -> bool {
    operation.starts_with("terminal.input.")
        || operation.starts_with("browser.input.")
        || operation == "sidebar_view.input"
        || operation == "terminal.viewport.scroll"
}

fn record_resource_input_receipt_completion(
    transaction: &Transaction<'_>,
    idempotency_key: &str,
    operation: &str,
) -> anyhow::Result<()> {
    if !is_transient_input_operation(operation) {
        return Ok(());
    }
    transaction.execute(
        "INSERT INTO resource_input_receipt_completions(idempotency_key) VALUES(?1)",
        [idempotency_key],
    )?;
    let sequence = u64::try_from(transaction.last_insert_rowid())
        .context("resource input receipt completion sequence is negative")?;
    if sequence % u64::try_from(RESOURCE_INPUT_RECEIPT_PRUNE_INTERVAL)? == 0 {
        prune_resource_input_receipts(transaction)?;
    }
    Ok(())
}

fn prune_resource_input_receipts(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute(
        &format!(
            "DELETE FROM resource_effect_receipts
             WHERE idempotency_key IN (
               SELECT completion.idempotency_key
               FROM resource_input_receipt_completions AS completion
               JOIN resource_effect_receipts AS effect
                 ON effect.idempotency_key = completion.idempotency_key
               WHERE effect.state = 'committed'
                 AND {TRANSIENT_INPUT_EFFECT_SQL}
                 AND NOT EXISTS (
                   SELECT 1
                   FROM resource_creation_receipts AS creation
                   WHERE creation.idempotency_key = effect.idempotency_key
                 )
               ORDER BY completion.sequence DESC
               LIMIT -1 OFFSET ?1
             )"
        ),
        [i64::try_from(RESOURCE_INPUT_RECEIPT_CAPACITY)?],
    )?;
    Ok(())
}

#[cfg(test)]
mod tests;

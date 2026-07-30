use super::resource_store::{apply_resource_patch, validate_resource_patch};
use super::*;
use crate::resource::ResourceError;
use serde_json::json;

const RESOURCE_EVENT_CAPACITY: usize = 4096;
const RESOURCE_EVENT_BYTE_CAPACITY: usize = 16 * 1024 * 1024;

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
           WHERE state = 'committed';",
    )?;
    Ok(())
}

pub(super) fn recover_resource_effects(transaction: &Transaction<'_>) -> anyhow::Result<()> {
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
    ) -> anyhow::Result<ResourcePatchCommit> {
        validate_correlation_key(correlation_key)?;
        validate_identifier("mutation id", &mutation.id)?;
        validate_identifier("mutation origin", &mutation.origin)?;
        validate_identifier("resource operation", operation)?;
        validate_resource_patch(patch)?;
        let fingerprint = canonical_json(fingerprint)?;
        let result_json = canonical_json(result)?;
        let created_path_json = canonical_json(created_path)?;
        let deltas_json = canonical_json(deltas)?;
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
        apply_resource_patch(&tx, patch, sqlite_revision)?;
        tx.execute(
            "UPDATE meta SET value = ?1 WHERE key = 'resource_revision'",
            [revision.to_string()],
        )?;
        tx.execute(
            "INSERT INTO resource_mutations(
               origin, idempotency_key, operation, fingerprint, result_json, committed_revision
             ) VALUES(?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                mutation.origin,
                mutation.id,
                operation,
                fingerprint,
                result_json,
                sqlite_revision,
            ],
        )?;
        tx.execute(
            "INSERT INTO resource_events(
               revision, previous_revision, origin, idempotency_key, deltas_json
             ) VALUES(?1, ?2, ?3, ?4, ?5)",
            params![
                sqlite_revision,
                i64::try_from(previous_revision)
                    .context("resource revision exceeds SQLite range")?,
                mutation.origin,
                mutation.id,
                deltas_json,
            ],
        )?;
        prune_resource_events(&tx)?;
        let changed = tx.execute(
            "UPDATE resource_creation_receipts
             SET state = 'created', created_path_json = ?2, generation = ?3,
                 committed_revision = ?4
             WHERE correlation_key = ?1 AND state = 'prepared'",
            params![correlation_key, created_path_json, generation, sqlite_revision],
        )?;
        anyhow::ensure!(changed == 1, "resource creation receipt changed during commit");
        tx.commit()?;
        Ok(ResourcePatchCommit { revision, result: result.clone(), replayed: false })
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
        let outcome_json = canonical_json(&serde_json::to_value(outcome)?)?;
        let generation = self.generation.clone();
        let tx = self.connection.transaction()?;
        let (stored_operation, stored_fingerprint, state, _) =
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
            let sqlite_revision =
                i64::try_from(revision).context("resource revision exceeds SQLite range")?;
            let deltas_json = canonical_json(deltas)?;
            tx.execute(
                "UPDATE meta SET value = ?1 WHERE key = 'resource_revision'",
                [revision.to_string()],
            )?;
            tx.execute(
                "INSERT INTO resource_events(
                   revision, previous_revision, origin, idempotency_key, deltas_json
                 ) VALUES(?1, ?2, 'resource-api', ?3, ?4)",
                params![
                    sqlite_revision,
                    i64::try_from(previous_revision)
                        .context("resource revision exceeds SQLite range")?,
                    idempotency_key,
                    deltas_json,
                ],
            )?;
            prune_resource_events(&tx)?;
            revision
        } else {
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
        let outcome_json = canonical_json(&serde_json::to_value(&outcome)?)?;
        let deltas_json = canonical_json(deltas)?;
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
            &outcome_json,
            &deltas_json,
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
        validate_resource_patch(patch)?;
        let mutation = WorkspaceMutation::new(idempotency_key, "resource-api")?;
        validate_terminal_batch_close(&mutation, terminals)?;
        let fingerprint = canonical_json(fingerprint)?;
        let outcome = ResourceEffectOutcome::Success(result.clone());
        let outcome_json = canonical_json(&serde_json::to_value(&outcome)?)?;
        let deltas_json = canonical_json(deltas)?;
        let generation = self.generation.clone();
        let tx = self.connection.transaction()?;

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
            patch,
            result,
            &outcome_json,
            &deltas_json,
        )?;
        tx.commit()?;
        Ok(ResourceCloseCommit { resource, workspace_revision, terminal_batch })
    }

    pub fn mark_resource_effect_indeterminate(
        &mut self,
        idempotency_key: &str,
    ) -> anyhow::Result<()> {
        validate_identifier("idempotency key", idempotency_key)?;
        let tx = self.connection.transaction()?;
        tx.execute(
            "UPDATE resource_effect_receipts
             SET state = 'indeterminate', outcome_json = NULL, committed_revision = NULL
             WHERE idempotency_key = ?1 AND state = 'executing'",
            [idempotency_key],
        )?;
        tx.execute(
            "UPDATE resource_creation_receipts
             SET state = 'indeterminate', execution_generation = NULL,
                 created_path_json = NULL, generation = NULL, committed_revision = NULL
             WHERE idempotency_key = ?1 AND execution_kind = 'effect'
               AND state = 'executing'",
            [idempotency_key],
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
    outcome_json: &str,
    deltas_json: &str,
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
    apply_resource_patch(transaction, patch, sqlite_revision)?;
    transaction.execute(
        "UPDATE meta SET value = ?1 WHERE key = 'resource_revision'",
        [revision.to_string()],
    )?;
    transaction.execute(
        "INSERT INTO resource_events(
           revision, previous_revision, origin, idempotency_key, deltas_json
         ) VALUES(?1, ?2, 'resource-api', ?3, ?4)",
        params![
            sqlite_revision,
            i64::try_from(previous_revision).context("resource revision exceeds SQLite range")?,
            idempotency_key,
            deltas_json,
        ],
    )?;
    prune_resource_events(transaction)?;
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

pub(super) fn prune_resource_events(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    let rows = {
        let mut statement = transaction.prepare(
            "SELECT revision, length(deltas_json)
             FROM resource_events
             ORDER BY revision DESC
             LIMIT ?1",
        )?;
        statement
            .query_map([i64::try_from(RESOURCE_EVENT_CAPACITY)?], |row| {
                Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?))
            })?
            .collect::<Result<Vec<_>, _>>()?
    };
    let mut retained_bytes = 0usize;
    let mut oldest_retained = None;
    for (revision, bytes) in rows {
        let bytes = usize::try_from(bytes).context("resource event size is negative")?;
        if oldest_retained.is_some()
            && bytes > RESOURCE_EVENT_BYTE_CAPACITY.saturating_sub(retained_bytes)
        {
            break;
        }
        retained_bytes = retained_bytes.saturating_add(bytes);
        oldest_retained = Some(revision);
    }
    if let Some(oldest_retained) = oldest_retained {
        transaction
            .execute("DELETE FROM resource_events WHERE revision < ?1", [oldest_retained])?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pending_effect_resumes_and_committed_effect_replays() {
        let mut registry = WorkspaceRegistry::in_memory("effects").unwrap();
        let fingerprint = serde_json::json!({"title":"hello"});
        let intent = serde_json::json!({"notification_id":"notification_reserved"});
        assert_eq!(
            registry
                .prepare_resource_effect(
                    "effect-key",
                    "notification.create",
                    &fingerprint,
                    &intent,
                    None,
                    Some(0),
                )
                .unwrap(),
            ResourceEffectPreparation::Execute { intent: intent.clone(), resumed: false }
        );
        assert_eq!(
            registry
                .prepare_resource_effect(
                    "effect-key",
                    "notification.create",
                    &fingerprint,
                    &serde_json::json!({"ignored":"new allocation"}),
                    None,
                    Some(99),
                )
                .unwrap(),
            ResourceEffectPreparation::Execute { intent: intent.clone(), resumed: true }
        );
        assert_eq!(
            registry
                .mark_resource_effect_executing("effect-key", "notification.create", &fingerprint,)
                .unwrap(),
            intent
        );
        let outcome = ResourceEffectOutcome::Success(serde_json::json!({"id":"notice"}));
        let revision = registry
            .commit_resource_effect(
                "effect-key",
                "notification.create",
                &fingerprint,
                &outcome,
                Some(&serde_json::json!([{"kind":"upsert"}])),
            )
            .unwrap();
        assert_eq!(revision, 1);
        assert_eq!(
            registry
                .prepare_resource_effect(
                    "effect-key",
                    "notification.create",
                    &fingerprint,
                    &intent,
                    None,
                    Some(0),
                )
                .unwrap(),
            ResourceEffectPreparation::Committed { outcome, revision: 1 }
        );
    }

    #[test]
    fn restart_turns_executing_without_outcome_indeterminate() {
        let root = std::env::temp_dir().join(format!("cmux-effect-{}", new_uuid_v4()));
        let fingerprint = serde_json::json!({"text":"effect"});
        {
            let mut registry = WorkspaceRegistry::open(&root, "restart").unwrap();
            registry
                .prepare_resource_effect(
                    "crash-key",
                    "terminal.input.write",
                    &fingerprint,
                    &serde_json::json!({}),
                    None,
                    None,
                )
                .unwrap();
            registry
                .mark_resource_effect_executing("crash-key", "terminal.input.write", &fingerprint)
                .unwrap();
        }
        let mut reopened = WorkspaceRegistry::open(&root, "restart").unwrap();
        assert_eq!(
            reopened
                .prepare_resource_effect(
                    "crash-key",
                    "terminal.input.write",
                    &fingerprint,
                    &serde_json::json!({}),
                    None,
                    None,
                )
                .unwrap(),
            ResourceEffectPreparation::Indeterminate
        );
        drop(reopened);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn effect_patch_commits_topology_event_and_receipt_together() {
        let mut registry = WorkspaceRegistry::in_memory("effect-patch").unwrap();
        let fingerprint = serde_json::json!({"name":"one"});
        let intent = serde_json::json!({"reserved":"workspace"});
        registry
            .prepare_resource_effect(
                "effect-patch-key",
                "workspace.create",
                &fingerprint,
                &intent,
                None,
                Some(0),
            )
            .unwrap();
        registry
            .mark_resource_effect_executing("effect-patch-key", "workspace.create", &fingerprint)
            .unwrap();
        let workspace = RegistryWorkspace {
            id: 1,
            public_id: WorkspacePublicId::parse(format!("ws_{}", "1".repeat(32))).unwrap(),
            key: "one".into(),
            name: "One".into(),
            group_key: "effect-patch".into(),
        };
        let patch = ResourcePatch {
            changes: vec![
                ResourceChange::UpsertWorkspace {
                    workspace: workspace.clone(),
                    position: 0,
                    active_screen: None,
                },
                ResourceChange::SetWorkspaceOrder {
                    workspace_ids: vec![workspace.public_id.clone()],
                },
                ResourceChange::SetActiveWorkspace {
                    workspace_id: Some(workspace.public_id.clone()),
                },
            ],
        };
        let result = serde_json::json!({"workspace_id":workspace.public_id});
        let deltas = serde_json::json!([{"kind":"upsert","resource":"workspace"}]);
        let commit = registry
            .commit_resource_effect_patch(
                "effect-patch-key",
                "workspace.create",
                &fingerprint,
                &patch,
                &result,
                &deltas,
            )
            .unwrap();
        assert_eq!(commit.revision, 1);
        assert_eq!(registry.resource_topology_snapshot().unwrap().revision, 1);
        assert_eq!(registry.resource_events_after(0).unwrap().batches[0].changes, deltas);
        assert_eq!(
            registry
                .lookup_resource_effect("effect-patch-key", "workspace.create", &fingerprint,)
                .unwrap(),
            Some(ResourceEffectPreparation::Committed {
                outcome: ResourceEffectOutcome::Success(result),
                revision: 1,
            })
        );
    }

    #[test]
    fn restart_resumes_pending_and_replays_committed_outcome() {
        let root = std::env::temp_dir().join(format!("cmux-effect-{}", new_uuid_v4()));
        let fingerprint = serde_json::json!({"title":"resume"});
        let intent = serde_json::json!({"reserved_id":"notice"});
        {
            let mut registry = WorkspaceRegistry::open(&root, "resume").unwrap();
            registry
                .prepare_resource_effect(
                    "resume-key",
                    "notification.create",
                    &fingerprint,
                    &intent,
                    None,
                    None,
                )
                .unwrap();
        }
        let outcome = ResourceEffectOutcome::Success(serde_json::json!({"id":"notice"}));
        {
            let mut reopened = WorkspaceRegistry::open(&root, "resume").unwrap();
            assert_eq!(
                reopened
                    .prepare_resource_effect(
                        "resume-key",
                        "notification.create",
                        &fingerprint,
                        &serde_json::json!({"reserved_id":"replacement"}),
                        None,
                        None,
                    )
                    .unwrap(),
                ResourceEffectPreparation::Execute { intent: intent.clone(), resumed: true }
            );
            reopened
                .mark_resource_effect_executing("resume-key", "notification.create", &fingerprint)
                .unwrap();
            reopened
                .commit_resource_effect(
                    "resume-key",
                    "notification.create",
                    &fingerprint,
                    &outcome,
                    Some(&serde_json::json!([{"kind":"upsert"}])),
                )
                .unwrap();
        }
        let mut replay = WorkspaceRegistry::open(&root, "resume").unwrap();
        assert_eq!(
            replay
                .prepare_resource_effect(
                    "resume-key",
                    "notification.create",
                    &fingerprint,
                    &intent,
                    None,
                    Some(0),
                )
                .unwrap(),
            ResourceEffectPreparation::Committed { outcome, revision: 1 }
        );
        drop(replay);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn correlation_keys_validate_utf8_byte_length_only() {
        let registry = WorkspaceRegistry::in_memory("correlation-validation").unwrap();
        for accepted in [" ", "\0", &"é".repeat(64)] {
            assert_eq!(
                registry.resolve_resource_creation(accepted).unwrap(),
                json!({
                    "correlation_key":accepted,
                    "state":"not_applied",
                    "recovery":"retry_new_idempotency_key",
                })
            );
        }
        for rejected in ["".to_string(), format!("{}a", "é".repeat(64))] {
            let error = registry.resolve_resource_creation(&rejected).unwrap_err();
            let error = error.downcast_ref::<ResourceError>().unwrap();
            assert_eq!(error.code, "validation.invalid");
            assert_eq!(error.details["field"], "correlation_key");
        }
    }

    #[test]
    fn correlated_creation_resolves_prepared_executing_and_created() {
        let mut registry = WorkspaceRegistry::in_memory("creation-states").unwrap();
        let fingerprint = json!({"url":"https://example.test"});
        let intent = json!({
            "browser_reservation":{"tab_id":"tab_reserved","browser_id":"browser_reserved"}
        });
        assert_eq!(
            registry
                .prepare_resource_creation(
                    "correlation",
                    "attempt-one",
                    "tab.create_browser",
                    &fingerprint,
                    &intent,
                    true,
                    None,
                    None,
                )
                .unwrap(),
            ResourceCreationPreparation::Execute {
                idempotency_key: "attempt-one".to_string(),
                intent: intent.clone(),
                resumed: false,
            }
        );
        assert_eq!(
            registry.resolve_resource_creation("correlation").unwrap(),
            json!({
                "correlation_key":"correlation",
                "operation":"tab.create_browser",
                "idempotency_key":"attempt-one",
                "state":"not_applied",
                "recovery":"retry_same_idempotency_key",
            })
        );
        registry
            .mark_resource_effect_executing("attempt-one", "tab.create_browser", &fingerprint)
            .unwrap();
        assert_eq!(
            registry.resolve_resource_creation("correlation").unwrap(),
            json!({
                "correlation_key":"correlation",
                "operation":"tab.create_browser",
                "idempotency_key":"attempt-one",
                "state":"pending",
                "recovery":"wait",
            })
        );
        let created_path = json!({
            "kind":"browser",
            "workspace_id":"ws_one",
            "screen_id":"screen_one",
            "pane_id":"pane_one",
            "tab_id":"tab_reserved",
            "browser_id":"browser_reserved",
        });
        registry
            .commit_resource_effect(
                "attempt-one",
                "tab.create_browser",
                &fingerprint,
                &ResourceEffectOutcome::Success(created_path.clone()),
                None,
            )
            .unwrap();
        assert_eq!(
            registry.resolve_resource_creation("correlation").unwrap(),
            json!({
                "correlation_key":"correlation",
                "operation":"tab.create_browser",
                "idempotency_key":"attempt-one",
                "state":"created",
                "recovery":"none",
                "created_path":created_path,
                "generation":registry.generation(),
                "revision":"0",
            })
        );
    }

    #[test]
    fn definite_failure_rebinds_but_old_attempt_replays_exact_failure() {
        let mut registry = WorkspaceRegistry::in_memory("creation-rebind").unwrap();
        let fingerprint = json!({"command":["false"]});
        let intent = json!({"terminal_reservation":{"terminal_id":"1".repeat(32)}});
        registry
            .prepare_resource_creation(
                "correlation",
                "attempt-one",
                "workspace.run",
                &fingerprint,
                &intent,
                true,
                None,
                None,
            )
            .unwrap();
        registry
            .mark_resource_effect_executing("attempt-one", "workspace.run", &fingerprint)
            .unwrap();
        let failure = ResourceError::operation_failed(
            "workspace.run",
            "process launch failed",
            json!({"stage":"spawn"}),
        );
        registry
            .commit_resource_effect(
                "attempt-one",
                "workspace.run",
                &fingerprint,
                &ResourceEffectOutcome::Failure(failure.clone()),
                None,
            )
            .unwrap();
        assert_eq!(
            registry.resolve_resource_creation("correlation").unwrap()["recovery"],
            "retry_new_idempotency_key"
        );
        assert_eq!(
            registry
                .prepare_resource_creation(
                    "correlation",
                    "attempt-two",
                    "workspace.run",
                    &fingerprint,
                    &json!({"ignored":"new reservation"}),
                    true,
                    None,
                    None,
                )
                .unwrap(),
            ResourceCreationPreparation::Execute {
                idempotency_key: "attempt-two".to_string(),
                intent: intent.clone(),
                resumed: false,
            }
        );
        assert_eq!(
            registry
                .lookup_resource_creation(
                    "correlation",
                    "attempt-one",
                    "workspace.run",
                    &fingerprint,
                    true,
                )
                .unwrap(),
            Some(ResourceCreationPreparation::Failed { error: failure, revision: 0 })
        );
        assert_eq!(
            read_creation_record(&registry.connection, "correlation").unwrap().unwrap().attempt,
            2
        );
        assert!(matches!(
            registry
                .prepare_resource_creation(
                    "correlation",
                    "attempt-three",
                    "workspace.run",
                    &fingerprint,
                    &intent,
                    true,
                    None,
                    None,
                )
                .unwrap(),
            ResourceCreationPreparation::Blocked { .. }
        ));
    }

    #[test]
    fn correlation_conflict_is_typed_and_reports_both_semantics() {
        let mut registry = WorkspaceRegistry::in_memory("creation-conflict").unwrap();
        registry
            .prepare_resource_creation(
                "same-correlation",
                "attempt-one",
                "workspace.run",
                &json!({"command":["one"]}),
                &json!({}),
                true,
                None,
                None,
            )
            .unwrap();
        let error = registry
            .prepare_resource_creation(
                "same-correlation",
                "attempt-two",
                "pane.run",
                &json!({"command":["two"]}),
                &json!({}),
                true,
                None,
                None,
            )
            .unwrap_err();
        let error = error.downcast_ref::<ResourceError>().unwrap();
        assert_eq!(error.code, "creation.conflict");
        assert_eq!(error.details["correlation_key"], "same-correlation");
        assert_eq!(error.details["existing_operation"], "workspace.run");
        assert_eq!(error.details["requested_operation"], "pane.run");
    }

    #[test]
    fn restart_preserves_all_created_path_operations_for_evidence_reconciliation() {
        let root = std::env::temp_dir().join(format!("cmux-creation-{}", new_uuid_v4()));
        let operations = [
            "workspace.create",
            "workspace.run",
            "screen.create",
            "pane.create",
            "pane.split",
            "pane.run",
            "tab.create_terminal",
            "tab.create_browser",
        ];
        {
            let mut registry = WorkspaceRegistry::open(&root, "creation-recovery").unwrap();
            for (index, operation) in operations.iter().enumerate() {
                let correlation = format!("correlation-{index}");
                let idempotency = format!("attempt-{index}");
                let fingerprint = json!({"operation":operation});
                let intent = json!({
                    "terminal_reservation":{"terminal_id":format!("{index:032x}")},
                    "workspace_reservation":{"workspace_key":format!(
                        "00000000-0000-0000-0000-{index:012x}"
                    )},
                    "browser_reservation":{
                        "tab_id":format!("tab-{index}"),
                        "browser_id":format!("browser-{index}"),
                    },
                });
                registry
                    .prepare_resource_creation(
                        &correlation,
                        &idempotency,
                        operation,
                        &fingerprint,
                        &intent,
                        true,
                        None,
                        None,
                    )
                    .unwrap();
                registry
                    .mark_resource_effect_executing(&idempotency, operation, &fingerprint)
                    .unwrap();
            }
        }
        let registry = WorkspaceRegistry::open(&root, "creation-recovery").unwrap();
        let recoveries = registry.interrupted_resource_creation_recoveries().unwrap();
        assert_eq!(recoveries.len(), operations.len());
        assert_eq!(
            recoveries.iter().map(|recovery| recovery.operation.as_str()).collect::<Vec<_>>(),
            operations
        );
        assert!(recoveries.iter().all(|recovery| recovery.interrupted));
        drop(registry);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn effect_key_conflicts_across_operations_and_payloads() {
        let mut registry = WorkspaceRegistry::in_memory("conflict").unwrap();
        registry
            .prepare_resource_effect(
                "same-key",
                "notification.create",
                &serde_json::json!({"body":"a"}),
                &serde_json::json!({}),
                None,
                None,
            )
            .unwrap();
        let error = registry
            .prepare_resource_effect(
                "same-key",
                "terminal.input.write",
                &serde_json::json!({"body":"b"}),
                &serde_json::json!({}),
                None,
                None,
            )
            .unwrap_err();
        assert!(error.to_string().starts_with("idempotency.conflict:"));
    }
}

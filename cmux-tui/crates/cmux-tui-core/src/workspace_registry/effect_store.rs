use super::*;
use crate::resource::ResourceError;

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
         );",
    )?;
    Ok(())
}

pub(super) fn recover_resource_effects(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute(
        "UPDATE resource_effect_receipts
         SET state = 'indeterminate'
         WHERE state = 'executing'",
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
        tx.commit()?;
        Ok(revision)
    }

    pub fn mark_resource_effect_indeterminate(
        &mut self,
        idempotency_key: &str,
    ) -> anyhow::Result<()> {
        validate_identifier("idempotency key", idempotency_key)?;
        self.connection.execute(
            "UPDATE resource_effect_receipts
             SET state = 'indeterminate', outcome_json = NULL, committed_revision = NULL
             WHERE idempotency_key = ?1 AND state = 'executing'",
            [idempotency_key],
        )?;
        Ok(())
    }
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
            "idempotency.conflict: key {idempotency_key} was reused with different input"
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

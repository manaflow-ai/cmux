//! Resource creation lookup (moved out of effect_store.rs).

use super::*;

impl WorkspaceRegistry {
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
        let fingerprint = self.stored_fingerprint(fingerprint)?;
        let Some(stored) = read_creation_record(&self.connection.get(), correlation_key)? else {
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
            }) = read_effect_preparation(
                &self.connection.get(),
                idempotency_key,
                operation,
                &fingerprint,
            )?
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
                        &self.connection.get(),
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
                    &self.connection.get(),
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
}

use std::sync::Arc;

use serde_json::{Value, json};

use super::{
    ParsedResourceRequest, expected_revision, mutation_result, operation_name,
    resource_operation_error,
};
use crate::Mux;
use crate::resource::ResourceError;
use crate::workspace_registry::{ResourceEffectOutcome, ResourceEffectPreparation};

pub(super) struct PreparedEffect {
    pub idempotency_key: String,
    pub operation: String,
    pub fingerprint: Value,
    pub intent: Value,
}

pub(super) enum EffectPreparation {
    Complete(Result<Value, ResourceError>),
    Execute(PreparedEffect),
}

pub(super) fn prepare(
    mux: &Arc<Mux>,
    request: &ParsedResourceRequest,
    make_intent: impl FnOnce() -> Result<Value, ResourceError>,
) -> Result<EffectPreparation, ResourceError> {
    let operation = operation_name(request.envelope.operation);
    let idempotency_key = request
        .envelope
        .idempotency_key
        .as_deref()
        .expect("catalog-validated mutations have an idempotency key");
    let fingerprint = json!({
        "operation":operation,
        "selectors":request.selectors,
        "fields":request.fields,
    });
    if let Some(preparation) = mux
        .lookup_resource_effect(idempotency_key, &operation, &fingerprint)
        .map_err(resource_operation_error)?
    {
        return resolve_preparation(mux, idempotency_key, operation, fingerprint, preparation);
    }

    let intent = make_intent()?;
    let preparation = mux
        .prepare_resource_effect(
            idempotency_key,
            &operation,
            &fingerprint,
            &intent,
            None,
            expected_revision(&request.fields)?,
        )
        .map_err(resource_operation_error)?;
    resolve_preparation(mux, idempotency_key, operation, fingerprint, preparation)
}

fn resolve_preparation(
    mux: &Arc<Mux>,
    idempotency_key: &str,
    operation: String,
    fingerprint: Value,
    preparation: ResourceEffectPreparation,
) -> Result<EffectPreparation, ResourceError> {
    match preparation {
        ResourceEffectPreparation::Committed { outcome, revision } => {
            let result = match outcome {
                ResourceEffectOutcome::Success(value) => {
                    mutation_result(mux, value, revision, true)
                }
                ResourceEffectOutcome::Failure(error) => Err(error),
            };
            Ok(EffectPreparation::Complete(result))
        }
        ResourceEffectPreparation::Indeterminate => {
            Ok(EffectPreparation::Complete(Err(indeterminate_error(idempotency_key, &operation))))
        }
        ResourceEffectPreparation::Execute { .. } => {
            let intent = mux
                .mark_resource_effect_executing(idempotency_key, &operation, &fingerprint)
                .map_err(resource_operation_error)?;
            Ok(EffectPreparation::Execute(PreparedEffect {
                idempotency_key: idempotency_key.to_string(),
                operation,
                fingerprint,
                intent,
            }))
        }
    }
}

pub(super) fn commit_success(
    mux: &Arc<Mux>,
    prepared: PreparedEffect,
    value: Value,
    changes: Value,
) -> Result<Value, ResourceError> {
    let outcome = ResourceEffectOutcome::Success(value.clone());
    let revision = match mux.commit_resource_effect(
        &prepared.idempotency_key,
        &prepared.operation,
        &prepared.fingerprint,
        &outcome,
        Some(&changes),
    ) {
        Ok(revision) => revision,
        Err(_) => {
            let _ = mux.mark_resource_effect_indeterminate(&prepared.idempotency_key);
            return Err(indeterminate_error(&prepared.idempotency_key, &prepared.operation));
        }
    };
    mutation_result(mux, value, revision, false)
}

pub(super) fn commit_known_failure(
    mux: &Arc<Mux>,
    prepared: PreparedEffect,
    error: ResourceError,
) -> Result<Value, ResourceError> {
    let outcome = ResourceEffectOutcome::Failure(error.clone());
    if mux
        .commit_resource_effect(
            &prepared.idempotency_key,
            &prepared.operation,
            &prepared.fingerprint,
            &outcome,
            None,
        )
        .is_err()
    {
        let _ = mux.mark_resource_effect_indeterminate(&prepared.idempotency_key);
        return Err(indeterminate_error(&prepared.idempotency_key, &prepared.operation));
    }
    Err(error)
}

pub(super) fn mark_indeterminate(mux: &Arc<Mux>, prepared: PreparedEffect) -> ResourceError {
    let _ = mux.mark_resource_effect_indeterminate(&prepared.idempotency_key);
    indeterminate_error(&prepared.idempotency_key, &prepared.operation)
}

pub(super) fn indeterminate_error(idempotency_key: &str, operation: &str) -> ResourceError {
    ResourceError::new(
        "mutation.indeterminate",
        "the external effect may have run before its outcome was recorded",
        json!({
            "idempotency_key":idempotency_key,
            "operation":operation,
            "recovery":"inspect_state_then_retry_with_new_key",
        }),
        false,
    )
}

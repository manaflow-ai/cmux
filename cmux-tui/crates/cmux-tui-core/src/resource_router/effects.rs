use std::sync::Arc;

use serde_json::{Map, Value, json};
use zeroize::Zeroize;

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
    let fingerprint = durable_fingerprint(mux, request, &operation, idempotency_key)?;
    if let Some(preparation) = mux
        .lookup_resource_effect(idempotency_key, &operation, &fingerprint)
        .map_err(resource_operation_error)?
    {
        return resolve_preparation(
            mux,
            idempotency_key,
            operation,
            fingerprint,
            &request.fields,
            preparation,
        );
    }

    let intent = make_intent()?;
    let durable_intent = durable_intent(&intent, &operation)?;
    // A new intent is recorded as executing in the same commit: each commit
    // is a full fsync, and this one runs before the reply.
    let (preparation, executing) = mux
        .prepare_resource_effect_executing(
            &request.mutation().map_err(resource_operation_error)?,
            &operation,
            &fingerprint,
            &durable_intent,
            expected_revision(&request.fields)?,
        )
        .map_err(resource_operation_error)?;
    match preparation {
        ResourceEffectPreparation::Execute { intent, .. } if executing => {
            start_execution(mux, idempotency_key, operation, fingerprint, &request.fields, intent)
        }
        preparation => resolve_preparation(
            mux,
            idempotency_key,
            operation,
            fingerprint,
            &request.fields,
            preparation,
        ),
    }
}

fn resolve_preparation(
    mux: &Arc<Mux>,
    idempotency_key: &str,
    operation: String,
    fingerprint: Value,
    request_fields: &Map<String, Value>,
    preparation: ResourceEffectPreparation,
) -> Result<EffectPreparation, ResourceError> {
    match preparation {
        ResourceEffectPreparation::Committed { outcome, revision } => {
            let result = match outcome {
                ResourceEffectOutcome::Success(value) => {
                    mutation_result_for_operation(mux, &operation, value, revision, true)
                }
                ResourceEffectOutcome::Failure(error) => Err(error),
            };
            Ok(EffectPreparation::Complete(result))
        }
        ResourceEffectPreparation::Indeterminate => {
            report_indeterminate_cause(
                mux,
                idempotency_key,
                &operation,
                crate::resource_api::EARLIER_ATTEMPT_CAUSE,
            );
            Ok(EffectPreparation::Complete(Err(indeterminate_error(idempotency_key, &operation))))
        }
        ResourceEffectPreparation::Execute { .. } => {
            let intent = mux
                .mark_resource_effect_executing(idempotency_key, &operation, &fingerprint)
                .map_err(resource_operation_error)?;
            start_execution(mux, idempotency_key, operation, fingerprint, request_fields, intent)
        }
    }
}

/// The intent is durably `executing`: restore the runtime-only fields of
/// sensitive input and hand the effect to the caller.
fn start_execution(
    mux: &Arc<Mux>,
    idempotency_key: &str,
    operation: String,
    fingerprint: Value,
    request_fields: &Map<String, Value>,
    mut intent: Value,
) -> Result<EffectPreparation, ResourceError> {
    if sensitive_input_operation(&operation)
        && restore_runtime_fields(&mut intent, &operation, request_fields).is_err()
    {
        report_indeterminate_cause(
            mux,
            idempotency_key,
            &operation,
            "the stored input could not be restored",
        );
        let _ = mux.mark_resource_effect_indeterminate(idempotency_key);
        return Ok(EffectPreparation::Complete(Err(indeterminate_error(
            idempotency_key,
            &operation,
        ))));
    }
    Ok(EffectPreparation::Execute(PreparedEffect {
        idempotency_key: idempotency_key.to_string(),
        operation,
        fingerprint,
        intent,
    }))
}

pub(super) fn commit_success(
    mux: &Arc<Mux>,
    prepared: PreparedEffect,
    value: Value,
    changes: Value,
) -> Result<Value, ResourceError> {
    commit_success_inner(mux, prepared, value, Some(changes))
}

/// Commits an exactly-once receipt for an effect that changed only ephemeral
/// terminal or browser runtime state. No public topology revision or event is
/// minted for keystrokes, pointer input, focus reports, viewport scrolling,
/// or history clearing.
pub(super) fn commit_success_without_changes(
    mux: &Arc<Mux>,
    prepared: PreparedEffect,
    value: Value,
) -> Result<Value, ResourceError> {
    commit_success_inner(mux, prepared, value, None)
}

fn commit_success_inner(
    mux: &Arc<Mux>,
    prepared: PreparedEffect,
    value: Value,
    changes: Option<Value>,
) -> Result<Value, ResourceError> {
    let outcome = ResourceEffectOutcome::Success(value.clone());
    let revision = match mux.commit_resource_effect(
        &prepared.idempotency_key,
        &prepared.operation,
        &prepared.fingerprint,
        &outcome,
        changes.as_ref(),
    ) {
        Ok(revision) => revision,
        Err(error) => {
            return Err(mark_indeterminate(
                mux,
                prepared,
                &format!("the outcome commit failed: {error:#}"),
            ));
        }
    };
    mutation_result_for_operation(mux, &prepared.operation, value, revision, false)
}

pub(super) fn commit_known_failure(
    mux: &Arc<Mux>,
    prepared: PreparedEffect,
    error: ResourceError,
) -> Result<Value, ResourceError> {
    let outcome = ResourceEffectOutcome::Failure(error.clone());
    if let Err(commit_error) = mux.commit_resource_effect(
        &prepared.idempotency_key,
        &prepared.operation,
        &prepared.fingerprint,
        &outcome,
        None,
    ) {
        return Err(mark_indeterminate(
            mux,
            prepared,
            &format!("the failure outcome commit failed: {commit_error:#}"),
        ));
    }
    Err(error)
}

/// Marks an executing effect indeterminate and returns the public error.
///
/// `cause` goes only to the daemon diagnostic log: the API error stays
/// generic, and a caller must not pass raw transport text that can name
/// private sockets or credentials.
pub(super) fn mark_indeterminate(
    mux: &Arc<Mux>,
    prepared: PreparedEffect,
    cause: &str,
) -> ResourceError {
    report_indeterminate_cause(mux, &prepared.idempotency_key, &prepared.operation, cause);
    let _ = mux.mark_resource_effect_indeterminate(&prepared.idempotency_key);
    indeterminate_error(&prepared.idempotency_key, &prepared.operation)
}

/// Records why an effect's outcome is unknown. A `mutation.indeterminate`
/// response carries no cause, so this log line is the only evidence of it.
pub(super) fn report_indeterminate_cause(
    mux: &Mux,
    idempotency_key: &str,
    operation: &str,
    cause: &str,
) {
    mux.report_resource_effect_indeterminate(idempotency_key, operation, cause);
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

fn mutation_result_for_operation(
    mux: &Mux,
    operation: &str,
    value: Value,
    revision: u64,
    replayed: bool,
) -> Result<Value, ResourceError> {
    if snapshot_free_result_operation(operation) {
        let (_, generation) = mux.registry_identity();
        return Ok(json!({
            "value":value,
            "generation":generation,
            "revision":revision.to_string(),
            "replayed":replayed,
        }));
    }
    mutation_result(mux, value, revision, replayed)
}

pub(super) fn receipt_only_operation(operation: &str) -> bool {
    matches!(
        operation,
        "terminal.input.write"
            | "terminal.input.keys"
            | "terminal.input.mouse"
            | "terminal.input.focus"
            | "terminal.history.clear"
            | "terminal.viewport.scroll"
            | "browser.input.key"
            | "browser.input.text"
            | "browser.input.mouse"
            | "browser.input.wheel"
    )
}

fn snapshot_free_result_operation(operation: &str) -> bool {
    receipt_only_operation(operation) || operation == "sidebar_view.input"
}

/// Input payloads can contain passwords and bearer tokens. The receipt keeps
/// selectors and resolved resource IDs, but persists only a request-bound
/// digest of the fields. Pending receipts rehydrate those fields from the
/// retried request after the digest has matched, preserving target recovery
/// without turning the durable registry into an input log.
fn sensitive_input_operation(operation: &str) -> bool {
    operation.starts_with("terminal.input.")
        || operation.starts_with("browser.input.")
        || operation == "sidebar_view.input"
}

fn durable_fingerprint(
    mux: &Mux,
    request: &ParsedResourceRequest,
    operation: &str,
    idempotency_key: &str,
) -> Result<Value, ResourceError> {
    let fields = if sensitive_input_operation(operation) {
        redacted_fields_fingerprint(mux, operation, idempotency_key, &request.fields)?
    } else {
        Value::Object(request.fields.clone())
    };
    Ok(json!({
        "operation":operation,
        "selectors":request.selectors,
        "fields":fields,
    }))
}

fn durable_intent(intent: &Value, operation: &str) -> Result<Value, ResourceError> {
    if !sensitive_input_operation(operation) {
        return Ok(intent.clone());
    }
    let mut durable = intent.clone();
    let intent = durable.as_object_mut().ok_or_else(|| {
        ResourceError::operation_failed(operation, "content effect intent is malformed", json!({}))
    })?;
    if operation == "sidebar_view.input" {
        intent.remove("data_base64");
        intent.insert("$cmux_redacted".to_string(), json!({"kind":"request_fields","version":1}));
    } else {
        intent.insert(
            "fields".to_string(),
            json!({"$cmux_redacted":{"kind":"request_fields","version":1}}),
        );
    }
    Ok(durable)
}

fn restore_runtime_fields(
    intent: &mut Value,
    operation: &str,
    request_fields: &Map<String, Value>,
) -> Result<(), ()> {
    let intent = intent.as_object_mut().ok_or(())?;
    if operation == "sidebar_view.input" {
        let data = request_fields.get("data_base64").cloned().ok_or(())?;
        intent.remove("$cmux_redacted");
        intent.insert("data_base64".to_string(), data);
    } else {
        intent.insert("fields".to_string(), Value::Object(request_fields.clone()));
    }
    Ok(())
}

fn redacted_fields_fingerprint(
    mux: &Mux,
    operation: &str,
    idempotency_key: &str,
    fields: &Map<String, Value>,
) -> Result<Value, ResourceError> {
    let mut encoded = canonical_fields_json(fields)
        .map_err(|error| resource_operation_error(anyhow::Error::new(error)))?;
    let digest = mux.resource_input_receipt_hmac(idempotency_key, operation, &encoded);
    encoded.zeroize();
    Ok(json!({
        "$cmux_redacted":{
            "algorithm":"hmac-sha256",
            "digest":hex_digest(&digest),
            "kind":"request_fields",
            "version":2,
        }
    }))
}

fn canonical_fields_json(fields: &Map<String, Value>) -> serde_json::Result<Vec<u8>> {
    fn write_object(fields: &Map<String, Value>, output: &mut Vec<u8>) -> serde_json::Result<()> {
        output.push(b'{');
        let mut entries = fields.iter().collect::<Vec<_>>();
        entries.sort_unstable_by_key(|(key, _)| *key);
        for (index, (key, value)) in entries.into_iter().enumerate() {
            if index != 0 {
                output.push(b',');
            }
            serde_json::to_writer(&mut *output, key)?;
            output.push(b':');
            write_value(value, output)?;
        }
        output.push(b'}');
        Ok(())
    }

    fn write_value(value: &Value, output: &mut Vec<u8>) -> serde_json::Result<()> {
        match value {
            Value::Object(fields) => write_object(fields, output),
            Value::Array(values) => {
                output.push(b'[');
                for (index, value) in values.iter().enumerate() {
                    if index != 0 {
                        output.push(b',');
                    }
                    write_value(value, output)?;
                }
                output.push(b']');
                Ok(())
            }
            primitive => serde_json::to_writer(output, primitive),
        }
    }

    let mut encoded = Vec::new();
    write_object(fields, &mut encoded)?;
    Ok(encoded)
}

fn hex_digest(digest: &[u8; 32]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut encoded = String::with_capacity(64);
    for byte in digest {
        encoded.push(char::from(HEX[usize::from(byte >> 4)]));
        encoded.push(char::from(HEX[usize::from(byte & 0x0f)]));
    }
    encoded
}

#[cfg(test)]
mod tests;

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
    let preparation = mux
        .prepare_resource_effect(
            idempotency_key,
            &operation,
            &fingerprint,
            &durable_intent,
            None,
            expected_revision(&request.fields)?,
        )
        .map_err(resource_operation_error)?;
    resolve_preparation(mux, idempotency_key, operation, fingerprint, &request.fields, preparation)
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
            Ok(EffectPreparation::Complete(Err(indeterminate_error(idempotency_key, &operation))))
        }
        ResourceEffectPreparation::Execute { .. } => {
            let mut intent = mux
                .mark_resource_effect_executing(idempotency_key, &operation, &fingerprint)
                .map_err(resource_operation_error)?;
            if sensitive_input_operation(&operation)
                && restore_runtime_fields(&mut intent, &operation, request_fields).is_err()
            {
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
    }
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
        Err(_) => {
            let _ = mux.mark_resource_effect_indeterminate(&prepared.idempotency_key);
            return Err(indeterminate_error(&prepared.idempotency_key, &prepared.operation));
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
mod tests {
    use super::*;
    use crate::SurfaceOptions;

    fn input_request(fields: Value) -> ParsedResourceRequest {
        let mut params = json!({
            "machine":"current",
            "session":"current",
            "terminal":"term_00000000000000000000000000000001",
        })
        .as_object()
        .unwrap()
        .clone();
        params.extend(fields.as_object().unwrap().clone());
        super::super::parse_resource_request(
            &json!({
                "protocol":"cmux.protocol/2",
                "type":"request",
                "id":"security-test",
                "operation":"terminal.input.write",
                "params":params,
                "idempotency_key":"sensitive-input-key",
            })
            .to_string(),
        )
        .unwrap()
    }

    #[test]
    fn sensitive_input_receipts_persist_only_request_bound_digests() {
        let mux = Mux::new_for_test("input-receipt-digest", SurfaceOptions::default());
        let sentinel = "password-secret-sentinel";
        let first = input_request(json!({"text":sentinel}));
        let same = input_request(json!({"text":sentinel}));
        let changed = input_request(json!({"text":"different-secret"}));
        let first_fingerprint =
            durable_fingerprint(&mux, &first, "terminal.input.write", "sensitive-input-key")
                .unwrap();
        let same_fingerprint =
            durable_fingerprint(&mux, &same, "terminal.input.write", "sensitive-input-key")
                .unwrap();
        let changed_fingerprint =
            durable_fingerprint(&mux, &changed, "terminal.input.write", "sensitive-input-key")
                .unwrap();
        assert_eq!(first_fingerprint, same_fingerprint);
        assert_ne!(first_fingerprint, changed_fingerprint);

        let intent = json!({
            "terminal_id":"term_00000000000000000000000000000001",
            "fields":{"text":sentinel},
        });
        let persisted_intent = durable_intent(&intent, "terminal.input.write").unwrap();
        let durable = serde_json::to_string(&(first_fingerprint, persisted_intent)).unwrap();
        assert!(!durable.contains(sentinel));
        assert!(!durable.contains("different-secret"));
        assert!(durable.contains("hmac-sha256"));
        assert!(durable.contains("$cmux_redacted"));
    }

    #[test]
    fn sensitive_input_hmac_fields_use_recursive_canonical_json() {
        let fields = json!({
            "z":1,
            "a":{"z":2,"a":[{"z":3,"a":4}]},
        })
        .as_object()
        .unwrap()
        .clone();
        assert_eq!(
            canonical_fields_json(&fields).unwrap(),
            br#"{"a":{"a":[{"a":4,"z":3}],"z":2},"z":1}"#
        );
    }

    #[test]
    fn only_ephemeral_interaction_operations_are_receipt_only() {
        for operation in [
            "terminal.input.write",
            "terminal.input.keys",
            "terminal.input.mouse",
            "terminal.input.focus",
            "terminal.history.clear",
            "terminal.viewport.scroll",
            "browser.input.key",
            "browser.input.text",
            "browser.input.mouse",
            "browser.input.wheel",
        ] {
            assert!(receipt_only_operation(operation), "{operation}");
            assert!(snapshot_free_result_operation(operation), "{operation}");
        }
        for operation in [
            "browser.navigate",
            "browser.back",
            "browser.forward",
            "browser.reload",
            "browser.activate",
            "terminal.close",
            "browser.close",
            "sidebar_view.input",
        ] {
            assert!(!receipt_only_operation(operation), "{operation}");
        }
        assert!(snapshot_free_result_operation("sidebar_view.input"));
        assert!(!snapshot_free_result_operation("browser.navigate"));
        assert!(!sensitive_input_operation("browser.navigate"));
    }

    #[test]
    fn sensitive_input_receipt_never_writes_plaintext_to_sqlite() {
        let sentinel = "sqlite-password-sentinel-do-not-persist";
        let root = std::env::temp_dir()
            .join(format!("cmux-input-receipt-{}", crate::workspace_registry::new_uuid_v4()));
        let request = input_request(json!({"text":sentinel}));
        let intent = durable_intent(
            &json!({
                "terminal_id":"term_00000000000000000000000000000001",
                "fields":{"text":sentinel},
            }),
            "terminal.input.write",
        )
        .unwrap();

        let fingerprint = {
            let mux =
                Mux::open_persistent("input-receipt-security", SurfaceOptions::default(), &root)
                    .unwrap();
            let fingerprint =
                durable_fingerprint(&mux, &request, "terminal.input.write", "persistent-input-key")
                    .unwrap();
            assert!(matches!(
                mux.prepare_resource_effect(
                    "persistent-input-key",
                    "terminal.input.write",
                    &fingerprint,
                    &intent,
                    None,
                    None,
                )
                .unwrap(),
                ResourceEffectPreparation::Execute { resumed: false, .. }
            ));
            mux.shutdown();
            drop(mux);
            fingerprint
        };

        {
            let mux =
                Mux::open_persistent("input-receipt-security", SurfaceOptions::default(), &root)
                    .unwrap();
            let pending = mux
                .lookup_resource_effect(
                    "persistent-input-key",
                    "terminal.input.write",
                    &fingerprint,
                )
                .unwrap();
            assert!(matches!(
                pending,
                Some(ResourceEffectPreparation::Execute {
                    ref intent,
                    resumed: true,
                }) if !intent.to_string().contains(sentinel)
            ));
            let mut executing = mux
                .mark_resource_effect_executing(
                    "persistent-input-key",
                    "terminal.input.write",
                    &fingerprint,
                )
                .unwrap();
            assert!(!executing.to_string().contains(sentinel));
            restore_runtime_fields(&mut executing, "terminal.input.write", &request.fields)
                .unwrap();
            assert_eq!(executing["fields"]["text"], sentinel);
            mux.commit_resource_effect(
                "persistent-input-key",
                "terminal.input.write",
                &fingerprint,
                &ResourceEffectOutcome::Success(json!({})),
                None,
            )
            .unwrap();
            mux.shutdown();
        }

        {
            let mux =
                Mux::open_persistent("input-receipt-security", SurfaceOptions::default(), &root)
                    .unwrap();
            assert!(matches!(
                mux.lookup_resource_effect(
                    "persistent-input-key",
                    "terminal.input.write",
                    &fingerprint,
                )
                .unwrap(),
                Some(ResourceEffectPreparation::Committed { revision: 0, .. })
            ));
            mux.shutdown();
        }

        fn assert_tree_excludes(path: &std::path::Path, needle: &[u8]) {
            for entry in std::fs::read_dir(path).unwrap() {
                let path = entry.unwrap().path();
                if path.is_dir() {
                    assert_tree_excludes(&path, needle);
                } else {
                    let bytes = std::fs::read(&path).unwrap();
                    assert!(
                        !bytes.windows(needle.len()).any(|window| window == needle),
                        "sensitive input persisted in {}",
                        path.display()
                    );
                }
            }
        }
        assert_tree_excludes(&root, sentinel.as_bytes());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn sidebar_input_intent_redacts_and_rehydrates_base64_payload() {
        let sentinel = "c2lkZWJhci1zZWNyZXQtc2VudGluZWw=";
        let mut intent = durable_intent(
            &json!({
                "sidebar_id":"sidebar_00000000000000000000000000000001",
                "session_id":"session_00000000000000000000000000000001",
                "data_base64":sentinel,
            }),
            "sidebar_view.input",
        )
        .unwrap();
        assert!(!intent.to_string().contains(sentinel));
        restore_runtime_fields(
            &mut intent,
            "sidebar_view.input",
            json!({"data_base64":sentinel}).as_object().unwrap(),
        )
        .unwrap();
        assert_eq!(intent["data_base64"], sentinel);
        assert!(intent.get("$cmux_redacted").is_none());
    }

    #[test]
    fn sensitive_pending_intent_rehydrates_only_after_fingerprint_match() {
        let fields = json!({"text":"retry-secret"}).as_object().unwrap().clone();
        let mut intent = durable_intent(
            &json!({
                "terminal_id":"term_00000000000000000000000000000001",
                "fields":{"text":"retry-secret"},
            }),
            "terminal.input.write",
        )
        .unwrap();
        assert!(!intent.to_string().contains("retry-secret"));
        restore_runtime_fields(&mut intent, "terminal.input.write", &fields).unwrap();
        assert_eq!(intent["fields"], json!({"text":"retry-secret"}));
        assert_eq!(intent["terminal_id"], "term_00000000000000000000000000000001");
    }
}

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
        durable_fingerprint(&mux, &first, "terminal.input.write", "sensitive-input-key").unwrap();
    let same_fingerprint =
        durable_fingerprint(&mux, &same, "terminal.input.write", "sensitive-input-key").unwrap();
    let changed_fingerprint =
        durable_fingerprint(&mux, &changed, "terminal.input.write", "sensitive-input-key").unwrap();
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
        let mux = Mux::open_persistent("input-receipt-security", SurfaceOptions::default(), &root)
            .unwrap();
        let fingerprint =
            durable_fingerprint(&mux, &request, "terminal.input.write", "persistent-input-key")
                .unwrap();
        assert!(matches!(
            mux.prepare_resource_effect(
                &crate::WorkspaceMutation::daemon("persistent-input-key", "test").unwrap(),
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
        let mux = Mux::open_persistent("input-receipt-security", SurfaceOptions::default(), &root)
            .unwrap();
        let pending = mux
            .lookup_resource_effect("persistent-input-key", "terminal.input.write", &fingerprint)
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
        restore_runtime_fields(&mut executing, "terminal.input.write", &request.fields).unwrap();
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
        let mux = Mux::open_persistent("input-receipt-security", SurfaceOptions::default(), &root)
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

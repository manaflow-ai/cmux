use super::*;

#[test]
fn locally_emittable_error_codes_exactly_match_the_catalog() {
    let catalog: Value =
        serde_json::from_str(include_str!("../../../../spec/resource-operations-v2.json")).unwrap();
    let mut declared =
        catalog["errors"].as_object().unwrap().keys().map(String::as_str).collect::<Vec<_>>();
    let mut emitted = RESOURCE_ERROR_CODES.to_vec();
    declared.sort_unstable();
    emitted.sort_unstable();
    assert_eq!(emitted, declared);
    for code in declared {
        assert!(is_catalog_error_code(code));
    }
}

#[test]
fn catalog_error_details_and_retryability_are_recursively_enforced() {
    let cursor = json!({"generation":"generation","revision":"4"});
    let cases = [
        (
            "confirmation.required",
            json!({
                "confirmation_token":"layout-confirmation-token",
                "revision":"4",
                "closes_panes":[format!("pane_{}", "0".repeat(32))]
            }),
            false,
        ),
        (
            "creation.conflict",
            json!({
                "correlation_key":"create-42",
                "existing_operation":"workspace.create",
                "requested_operation":"screen.create",
                "existing_fingerprint":"fingerprint-a",
                "requested_fingerprint":"fingerprint-b",
            }),
            false,
        ),
        (
            "cursor.gap",
            json!({
                "requested":cursor,
                "current":cursor,
                "oldest_revision":"2",
            }),
            true,
        ),
        ("cursor.invalid", json!({"requested":cursor,"current":cursor,"reason":"ahead"}), false),
        (
            "idempotency.conflict",
            json!({"idempotency_key":"key","committed_operation":"workspace.rename"}),
            false,
        ),
        ("local.io", json!({"path":"/tmp/socket","reason":"closed"}), false),
        (
            "mutation.indeterminate",
            json!({
                "idempotency_key":"key",
                "operation":"browser.navigate",
                "recovery":"inspect_state_then_retry_with_new_key",
            }),
            false,
        ),
        (
            "operation.failed",
            json!({"operation":"workspace.close","reason":"failed","extra":{"errno":5}}),
            false,
        ),
        (
            "operation.unsupported",
            json!({"capability":"session-journal-v1","action":"restart_session"}),
            false,
        ),
        (
            "resource.not_found",
            json!({"scope":"terminal","id":format!("term_{}", "0".repeat(32))}),
            false,
        ),
        ("revision.conflict", json!({"expected":"3","actual":"4"}), true),
        (
            "selector.ambiguous",
            json!({"scope":"workspace","selector":"name:api","candidates":["a","b"]}),
            false,
        ),
        ("selector.invalid", json!({"scope":"workspace","selector":"_","reason":"invalid"}), false),
        ("selector.not_found", json!({"scope":"workspace","selector":"name:missing"}), false),
        (
            "selector.wrong_parent",
            json!({
                "scope":"pane",
                "selector":"current",
                "parent_scope":"screen",
                "expected_parent":"screen-a",
                "actual_parent":"screen-b",
            }),
            false,
        ),
        ("transport.closed", json!({"reason":"closed"}), true),
        ("validation.invalid", json!({"field":"rows","reason":"must be positive"}), false),
    ];
    for (code, details, retryable) in cases {
        assert!(catalog_error_contract_matches(code, &details, retryable), "{code}: {details}");
    }
    assert!(!catalog_error_contract_matches(
        "operation.failed",
        &json!({"operation":"workspace.close","required_context":"connection"}),
        false,
    ));
    assert!(!catalog_error_contract_matches(
        "transport.closed",
        &json!({"reason":"closed"}),
        false,
    ));
}

#[test]
fn response_invariant_is_checked() {
    ResponseEnvelope::success(RequestId::parse("ok").unwrap(), json!({"value":1}))
        .validate()
        .unwrap();
    ResponseEnvelope::failure(
        RequestId::parse("error").unwrap(),
        ResourceError::not_found("workspace", "missing"),
    )
    .validate()
    .unwrap();

    let invalid = ResponseEnvelope {
        protocol: PROTOCOL.into(),
        envelope_type: EnvelopeType::Response,
        id: RequestId::parse("invalid").unwrap(),
        ok: true,
        result: None,
        error: None,
    };
    assert_eq!(invalid.validate().unwrap_err().code, "validation.invalid");
}

#[test]
fn oversized_journal_commit_does_not_advance_revision() {
    let mut journal = ResourceJournal::new("generation".into(), 4);
    journal.byte_capacity = 32;
    assert!(journal.commit(vec![("event".into(), json!({"large":"x".repeat(128)}))]).is_err());
    assert_eq!(journal.revision(), 4);
    assert!(journal.after(4).unwrap().is_empty());
}

#[test]
fn no_current_selector_names_the_flags_and_the_list_instead_of_matching_current() {
    let error = ResourceError::not_found("screen", "current");
    assert!(!error.message.contains("matches \"current\""), "{}", error.message);
    assert!(error.message.contains("no current screen"), "{}", error.message);
    assert!(error.message.contains("outside a cmux terminal"), "{}", error.message);
    assert!(error.message.contains("--workspace or --screen"), "{}", error.message);
    assert!(error.message.contains("`cmux screen list`"), "{}", error.message);
    assert_eq!(error.code, "selector.not_found");
    assert_eq!(error.details["selector"], "current");
    // Any other selector keeps the plain message.
    assert_eq!(ResourceError::not_found("screen", "x").message, "no screen matches \"x\"");
}

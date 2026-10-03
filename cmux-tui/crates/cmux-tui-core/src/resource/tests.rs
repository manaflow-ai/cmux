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
fn ids_reject_uppercase_wrong_prefix_and_wrong_width() {
    let id = WorkspacePublicId::random().unwrap();
    assert_eq!(WorkspacePublicId::parse(id.to_string()).unwrap(), id);
    assert!(WorkspacePublicId::parse(format!("ws_{}", "A".repeat(32))).is_err());
    assert!(WorkspacePublicId::parse(format!("term_{}", "a".repeat(32))).is_err());
    assert!(WorkspacePublicId::parse(format!("ws_{}", "a".repeat(31))).is_err());
}

#[test]
fn projection_and_pairing_ids_use_the_canonical_prefix_registry() {
    let payload = "0".repeat(32);
    assert_eq!(
        FrontendProjectionPublicId::parse(format!("projection_{payload}")).unwrap().as_str(),
        format!("projection_{payload}")
    );
    assert!(PairingRequestPublicId::parse(format!("pairing_{payload}")).is_ok());
}

#[test]
fn name_escape_selects_reserved_and_id_shaped_names() {
    assert_eq!(Selector::parse("current").unwrap(), Selector::Current);
    assert_eq!(Selector::parse("name:current").unwrap(), Selector::Name("current".into()));
    assert!(matches!(
        Selector::parse(&WorkspacePublicId::random().unwrap().to_string()).unwrap(),
        Selector::Id(_)
    ));
    assert_eq!(
        Selector::parse(&format!("name:ws_{}", "a".repeat(32))).unwrap(),
        Selector::Name(format!("ws_{}", "a".repeat(32)))
    );
    assert_eq!(Selector::parse("name:hello_world").unwrap(), Selector::Name("hello_world".into()));
    assert_eq!(Selector::parse("hello_world").unwrap_err().code, "validation.invalid");
    for reserved in ["create", "show", "close", "screen", "pane", "tab"] {
        assert_eq!(Selector::parse(reserved).unwrap_err().code, "validation.invalid");
        assert_eq!(
            Selector::parse(&format!("name:{reserved}")).unwrap(),
            Selector::Name(reserved.into())
        );
    }
    for legacy in ["send-key", "clear-history", "vt-state", "focus-direction"] {
        assert_eq!(Selector::parse(legacy).unwrap(), Selector::Name(legacy.into()));
    }
}

#[test]
fn terminal_public_identity_is_independent_from_host_uuid_bits() {
    let terminal = TerminalPublicId::parse("term_ffffffffffffffffffffffffffffffff").unwrap();
    let tab = TabPublicId::parse("tab_00000000000000000000000000000001").unwrap();
    let identity = TabResourceIdentity::persisted_terminal(tab, terminal.clone());
    assert_eq!(identity.content_id, ContentPublicId::Terminal(terminal));
}

#[test]
fn duplicate_names_return_every_candidate_without_selecting() {
    let result = resolve_name(
        "workspace",
        "api",
        [("ws_1".into(), Some("api".into()), 1), ("ws_2".into(), Some("api".into()), 2)],
    )
    .unwrap_err();
    assert_eq!(result.code, "selector.ambiguous");
    assert_eq!(result.details["candidates"], json!(["ws_1", "ws_2"]));
}

#[test]
fn journal_revision_is_per_atomic_commit_and_detects_gaps() {
    let mut journal = ResourceJournal::new("generation".into(), 8);
    assert_eq!(
        journal
            .commit(vec![
                ("pane.created".into(), json!({"id":"pane"})),
                ("tab.created".into(), json!({"id":"tab"})),
            ])
            .unwrap(),
        9
    );
    let batches = journal.after(8).unwrap();
    assert_eq!(batches.len(), 1);
    assert_eq!(batches[0].previous_revision.get(), 8);
    assert_eq!(batches[0].revision.get(), 9);
    assert_eq!(batches[0].deltas[0].sequence, 0);
    assert_eq!(batches[0].deltas[1].sequence, 1);
}

#[test]
fn wire_decimals_are_strings_and_reject_noncanonical_values() {
    assert_eq!(serde_json::to_value(WireDecimal::new(42)).unwrap(), json!("42"));
    assert_eq!(serde_json::from_value::<WireDecimal>(json!("0")).unwrap().get(), 0);
    for invalid in [json!(42), json!(""), json!("01"), json!("-1"), json!("18446744073709551616")] {
        assert!(serde_json::from_value::<WireDecimal>(invalid).is_err());
    }
}

#[test]
fn terminal_multiview_uses_a_new_public_protocol_version() {
    assert_eq!(PROTOCOL, "cmux.protocol/2");
}

#[test]
fn requests_enforce_envelope_and_idempotency_rules() {
    let read: RequestEnvelope = serde_json::from_value(json!({
        "protocol": PROTOCOL,
        "type": "request",
        "id": "read-1",
        "operation": "workspace.list",
        "params": {}
    }))
    .unwrap();
    read.validate().unwrap();

    let mutation: RequestEnvelope = serde_json::from_value(json!({
        "protocol": PROTOCOL,
        "type": "request",
        "id": "write-1",
        "operation": "workspace.create",
        "params": {"name":"api"},
        "idempotency_key": "create-api"
    }))
    .unwrap();
    mutation.validate().unwrap();

    let mut missing_key = mutation;
    missing_key.idempotency_key = None;
    assert_eq!(missing_key.validate().unwrap_err().code, "validation.invalid");

    let mut read_with_key = read;
    read_with_key.idempotency_key = Some("unexpected".into());
    assert_eq!(read_with_key.validate().unwrap_err().code, "validation.invalid");

    for invalid in [
        "".to_string(),
        " \u{00a0}\u{3000}".to_string(),
        "key\nwith-control".to_string(),
        "key\u{0085}with-control".to_string(),
        "\u{00e9}".repeat(65),
    ] {
        let invalid_request: RequestEnvelope = serde_json::from_value(json!({
            "protocol": PROTOCOL,
            "type": "request",
            "id": "write-invalid",
            "operation": "workspace.create",
            "params": {"name":"api"},
            "idempotency_key": invalid,
        }))
        .unwrap();
        let error = invalid_request.validate().unwrap_err();
        assert_eq!(error.code, "validation.invalid");
        assert_eq!(error.details["field"], "idempotency_key");
    }

    for valid in [
        "key".to_string(),
        " \u{00a0}key\u{3000} ".to_string(),
        "\u{feff}".to_string(),
        "\u{00e9}".repeat(64),
    ] {
        let request: RequestEnvelope = serde_json::from_value(json!({
            "protocol": PROTOCOL,
            "type": "request",
            "id": "write-valid",
            "operation": "workspace.create",
            "params": {"name":"api"},
            "idempotency_key": valid,
        }))
        .unwrap();
        request.validate().unwrap();
    }
}

#[test]
fn operation_classes_keep_stream_and_connection_control_out_of_durable_idempotency() {
    for operation in [
        ResourceOperation::SessionEvents,
        ResourceOperation::SessionJournalSubscribe,
        ResourceOperation::TerminalAttach,
        ResourceOperation::BrowserAttach,
        ResourceOperation::SidebarViewAttach,
    ] {
        assert_eq!(operation.class(), OperationClass::StreamOpen);
    }
    assert_eq!(ResourceOperation::RequestCancel.class(), OperationClass::ConnectionControl);
    assert_eq!(ResourceOperation::StreamCancel.class(), OperationClass::ConnectionControl);
    let connection_control = [
        ResourceOperation::ClientMetadataUpdate,
        ResourceOperation::ClientSizingSet,
        ResourceOperation::ClientSizingRelease,
        ResourceOperation::ClientCellPixelsSet,
        ResourceOperation::ClientDetach,
        ResourceOperation::TerminalRendererGrantCreate,
        ResourceOperation::TerminalViewerResize,
        ResourceOperation::TerminalViewerRelease,
        ResourceOperation::BrowserViewerResize,
        ResourceOperation::BrowserViewerRelease,
    ];
    for operation in connection_control {
        assert_eq!(operation.class(), OperationClass::ConnectionControl);
    }
    assert_eq!(ResourceOperation::WorkspaceList.class(), OperationClass::Read);
    assert_eq!(ResourceOperation::WorkspaceCreate.class(), OperationClass::Mutation);
    assert_eq!(ResourceOperation::TabCreateTerminal.class(), OperationClass::Mutation);
    assert_eq!(ResourceOperation::TabCreateBrowser.class(), OperationClass::Mutation);
    assert_eq!(ResourceOperation::TerminalCopy.class(), OperationClass::Read);
    assert_eq!(LocalOperation::SidebarPluginUseBuiltin.class(), OperationClass::Local);

    for operation in [
        ResourceOperation::SessionEvents,
        ResourceOperation::SessionJournalSubscribe,
        ResourceOperation::RequestCancel,
        ResourceOperation::StreamCancel,
        ResourceOperation::ClientMetadataUpdate,
        ResourceOperation::ClientDetach,
    ] {
        let request = RequestEnvelope {
            protocol: PROTOCOL.into(),
            envelope_type: EnvelopeType::Request,
            id: RequestId::parse("class").unwrap(),
            operation,
            params: json!({}),
            idempotency_key: None,
        };
        request.validate().unwrap();
        let mut keyed = request;
        keyed.idempotency_key = Some("forbidden".into());
        assert_eq!(keyed.validate().unwrap_err().code, "validation.invalid");
    }
}

#[test]
fn envelopes_reject_unknown_fields_and_non_string_request_ids() {
    assert!(
        serde_json::from_value::<RequestEnvelope>(json!({
            "protocol": PROTOCOL,
            "type": "request",
            "id": "request",
            "operation": "workspace.list",
            "params": {},
            "extra": true
        }))
        .is_err()
    );
    assert!(
        serde_json::from_value::<RequestEnvelope>(json!({
            "protocol": PROTOCOL,
            "type": "request",
            "id": 1,
            "operation": "workspace.list",
            "params": {}
        }))
        .is_err()
    );
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

use super::*;

fn journal_record_for_effect(
    registry: &WorkspaceRegistry,
    idempotency_key: &str,
) -> SessionJournalRecord {
    registry
        .session_journal_after(0, 64)
        .unwrap()
        .records
        .into_iter()
        .find(|record| record.payload["idempotency_key"] == idempotency_key)
        .unwrap_or_else(|| panic!("missing journal outcome for {idempotency_key}"))
}

fn scale_input_operation(index: usize) -> &'static str {
    if index == 0 {
        return "terminal.viewport.scroll";
    }
    match index % 3 {
        0 => "terminal.input.write",
        1 => "browser.input.mouse",
        _ => "sidebar_view.input",
    }
}

fn scale_input_fingerprint(index: usize) -> Value {
    json!({"sequence":index})
}

fn scale_input_outcome(index: usize) -> ResourceEffectOutcome {
    ResourceEffectOutcome::Success(json!({"sequence":index}))
}

fn insert_committed_input_receipts(registry: &mut WorkspaceRegistry, start: usize, count: usize) {
    let tx = registry.connection.transaction().unwrap();
    for index in start..start + count {
        let key = format!("scale-input-{index:08}");
        let operation = scale_input_operation(index);
        tx.execute(
            "INSERT INTO resource_effect_receipts(
                   idempotency_key, operation, fingerprint, intent_json, state,
                   outcome_json, committed_revision
                 ) VALUES(?1, ?2, ?3, '{}', 'committed', ?4, 0)",
            params![
                key,
                operation,
                canonical_json(&scale_input_fingerprint(index)).unwrap(),
                canonical_json(&serde_json::to_value(scale_input_outcome(index)).unwrap()).unwrap(),
            ],
        )
        .unwrap();
        record_resource_input_receipt_completion(&tx, &key, operation).unwrap();
    }
    tx.commit().unwrap();
}

fn uncorrelated_committed_input_count(registry: &WorkspaceRegistry) -> usize {
    let count = registry
        .connection
        .query_row(
            &format!(
                "SELECT COUNT(*)
                     FROM resource_effect_receipts AS effect
                     WHERE effect.state = 'committed'
                       AND {TRANSIENT_INPUT_EFFECT_SQL}
                       AND NOT EXISTS (
                         SELECT 1 FROM resource_creation_receipts AS creation
                         WHERE creation.idempotency_key = effect.idempotency_key
                       )"
            ),
            [],
            |row| row.get::<_, i64>(0),
        )
        .unwrap();
    usize::try_from(count).unwrap()
}

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
fn receipt_only_success_appends_a_nonreplayable_effect_outcome() {
    let mut registry = WorkspaceRegistry::in_memory("effect-success-journal").unwrap();
    let fingerprint = json!({"title":"hello"});
    let intent = json!({
        "notification_id":"notification_11111111111111111111111111111111",
    });
    registry
        .prepare_resource_effect(
            "effect-success-key",
            "notification.create",
            &fingerprint,
            &intent,
            None,
            None,
        )
        .unwrap();
    registry
        .mark_resource_effect_executing("effect-success-key", "notification.create", &fingerprint)
        .unwrap();
    let outcome = ResourceEffectOutcome::Success(json!({
        "id":"notification_11111111111111111111111111111111",
    }));
    assert_eq!(
        registry
            .commit_resource_effect(
                "effect-success-key",
                "notification.create",
                &fingerprint,
                &outcome,
                None,
            )
            .unwrap(),
        0
    );

    let record = journal_record_for_effect(&registry, "effect-success-key");
    assert_eq!(record.kind, "notification.create.effect.succeeded");
    assert_eq!(record.class, JournalClass::Effect);
    assert_eq!(record.replay, JournalReplayPolicy::Never);
    assert_eq!(record.resource_revision, None);
    assert_eq!(record.payload["state"], "succeeded");
    assert_eq!(record.payload["intent"], intent);
    assert_eq!(record.payload["outcome"], serde_json::to_value(outcome).unwrap());
    assert!(record.subjects.contains(&JournalSubject {
        kind: "notification".into(),
        id: "notification_11111111111111111111111111111111".into(),
    }));
}

#[test]
fn failed_creation_appends_its_correlation_attempt_and_reserved_subjects() {
    let mut registry = WorkspaceRegistry::in_memory("effect-failure-journal").unwrap();
    let fingerprint = json!({"url":"https://example.test"});
    let intent = json!({
        "path":{
            "workspace":"ws_11111111111111111111111111111111",
            "pane":"pane_22222222222222222222222222222222",
        },
        "browser_reservation":{
            "tab_id":"tab_33333333333333333333333333333333",
            "browser_id":"browser_44444444444444444444444444444444",
        },
    });
    registry
        .prepare_resource_creation(
            "creation-correlation",
            "creation-attempt-one",
            "tab.create_browser",
            &fingerprint,
            &intent,
            true,
            None,
            None,
        )
        .unwrap();
    registry
        .mark_resource_effect_executing("creation-attempt-one", "tab.create_browser", &fingerprint)
        .unwrap();
    let failure = ResourceError::operation_failed(
        "tab.create_browser",
        "browser launch failed",
        json!({"stage":"spawn"}),
    );
    registry
        .commit_resource_effect(
            "creation-attempt-one",
            "tab.create_browser",
            &fingerprint,
            &ResourceEffectOutcome::Failure(failure.clone()),
            None,
        )
        .unwrap();

    let record = journal_record_for_effect(&registry, "creation-attempt-one");
    assert_eq!(record.kind, "tab.create_browser.effect.failed");
    assert_eq!(record.class, JournalClass::Effect);
    assert_eq!(record.replay, JournalReplayPolicy::Never);
    assert_eq!(record.correlation_id.as_deref(), Some("creation-correlation"));
    assert_eq!(record.payload["state"], "failed");
    assert_eq!(record.payload["attempt"], "1");
    assert_eq!(
        record.payload["outcome"],
        serde_json::to_value(ResourceEffectOutcome::Failure(failure)).unwrap()
    );
    for (kind, id) in [
        ("workspace", "ws_11111111111111111111111111111111"),
        ("pane", "pane_22222222222222222222222222222222"),
        ("tab", "tab_33333333333333333333333333333333"),
        ("browser", "browser_44444444444444444444444444444444"),
    ] {
        assert!(record.subjects.contains(&JournalSubject { kind: kind.into(), id: id.into() }));
    }
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
    let record = journal_record_for_effect(&reopened, "crash-key");
    assert_eq!(record.kind, "terminal.input.write.effect.indeterminate");
    assert_eq!(record.class, JournalClass::Effect);
    assert_eq!(record.replay, JournalReplayPolicy::Never);
    assert_eq!(record.payload["state"], "indeterminate");
    assert_eq!(record.payload["outcome"], Value::Null);
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
            ResourceChange::SetWorkspaceOrder { workspace_ids: vec![workspace.public_id.clone()] },
            ResourceChange::SetActiveWorkspace { workspace_id: Some(workspace.public_id.clone()) },
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
    // The topology delta, then the new workspace's personal placement.
    let changes = registry.resource_events_after(0).unwrap().batches[0].changes.clone();
    assert_eq!(changes[0], deltas[0]);
    assert_eq!(
        (changes[1]["kind"].as_str(), changes[1]["resource"].as_str()),
        (Some("state_upsert"), Some("workspace_placement"))
    );
    assert_eq!(changes.as_array().unwrap().len(), 2);
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
fn prepared_creation_rechecks_its_execution_precondition() {
    let mut registry = WorkspaceRegistry::in_memory("creation-precondition").unwrap();
    let fingerprint = json!({"url":"https://example.test"});
    let intent = json!({"browser_id":"browser_reserved"});
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
                Some(0),
            )
            .unwrap(),
        ResourceCreationPreparation::Execute {
            idempotency_key: "attempt-one".to_string(),
            intent: intent.clone(),
            resumed: false,
        }
    );
    registry
        .connection
        .execute("UPDATE meta SET value = '1' WHERE key = 'resource_revision'", [])
        .unwrap();

    let stale = registry
        .prepare_resource_creation(
            "correlation",
            "attempt-one",
            "tab.create_browser",
            &fingerprint,
            &intent,
            true,
            None,
            Some(0),
        )
        .unwrap_err();
    assert_eq!(stale.to_string(), "resource revision conflict: expected 0, current 1");
    assert_eq!(
        registry.resolve_resource_creation("correlation").unwrap()["recovery"],
        "retry_same_idempotency_key"
    );
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
                Some(1),
            )
            .unwrap(),
        ResourceCreationPreparation::Execute {
            idempotency_key: "attempt-one".to_string(),
            intent,
            resumed: true,
        }
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
    registry.mark_resource_effect_executing("attempt-one", "workspace.run", &fingerprint).unwrap();
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
            registry.mark_resource_effect_executing(&idempotency, operation, &fingerprint).unwrap();
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

#[test]
fn input_receipt_retention_is_bounded_and_preserves_nonterminal_and_correlated_rows() {
    let root = std::env::temp_dir().join(format!("cmux-effect-retention-{}", new_uuid_v4()));
    let active_fingerprint = json!({"active":true});
    let mut registry = WorkspaceRegistry::open(&root, "receipt-retention").unwrap();
    for key in ["pending-input", "executing-input", "indeterminate-input"] {
        registry
            .prepare_resource_effect(
                key,
                "terminal.input.write",
                &active_fingerprint,
                &json!({}),
                None,
                None,
            )
            .unwrap();
    }
    registry
        .mark_resource_effect_executing(
            "executing-input",
            "terminal.input.write",
            &active_fingerprint,
        )
        .unwrap();
    registry
        .mark_resource_effect_executing(
            "indeterminate-input",
            "terminal.input.write",
            &active_fingerprint,
        )
        .unwrap();
    registry.mark_resource_effect_indeterminate("indeterminate-input").unwrap();

    let before_startup =
        RESOURCE_INPUT_RECEIPT_CAPACITY + RESOURCE_INPUT_RECEIPT_PRUNE_INTERVAL - 1;
    insert_committed_input_receipts(&mut registry, 0, before_startup);
    assert_eq!(uncorrelated_committed_input_count(&registry), before_startup);

    registry
        .connection
        .execute(
            "INSERT INTO resource_effect_receipts(
                   idempotency_key, operation, fingerprint, intent_json, state,
                   outcome_json, committed_revision
                 ) VALUES('correlated-input', 'terminal.input.write', '{}', '{}',
                          'committed', '{\"kind\":\"success\",\"value\":{}}', 0)",
            [],
        )
        .unwrap();
    registry
        .connection
        .execute(
            "INSERT INTO resource_creation_receipts(
                   correlation_key, operation, fingerprint, idempotency_key, intent_json,
                   execution_kind, attempt, state, execution_generation, created_path_json,
                   generation, committed_revision
                 ) VALUES('correlated-creation', 'terminal.input.write', '{}',
                          'correlated-input', '{}', 'effect', 1, 'created', NULL, '{}',
                          'generation', 0)",
            [],
        )
        .unwrap();
    drop(registry);

    let mut reopened = WorkspaceRegistry::open(&root, "receipt-retention").unwrap();
    assert_eq!(uncorrelated_committed_input_count(&reopened), RESOURCE_INPUT_RECEIPT_CAPACITY);
    for (key, expected_state) in [
        ("pending-input", "pending"),
        ("executing-input", "indeterminate"),
        ("indeterminate-input", "indeterminate"),
        ("correlated-input", "committed"),
    ] {
        let state: String = reopened
            .connection
            .query_row(
                "SELECT state FROM resource_effect_receipts WHERE idempotency_key = ?1",
                [key],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(state, expected_state, "{key}");
    }

    assert_eq!(
        reopened
            .prepare_resource_effect(
                "scale-input-00000000",
                scale_input_operation(0),
                &scale_input_fingerprint(0),
                &json!({}),
                None,
                None,
            )
            .unwrap(),
        ResourceEffectPreparation::Execute { intent: json!({}), resumed: false }
    );
    reopened
        .mark_resource_effect_executing(
            "scale-input-00000000",
            scale_input_operation(0),
            &scale_input_fingerprint(0),
        )
        .unwrap();
    reopened
        .commit_resource_effect(
            "scale-input-00000000",
            scale_input_operation(0),
            &scale_input_fingerprint(0),
            &scale_input_outcome(0),
            None,
        )
        .unwrap();
    assert_eq!(
        reopened
            .lookup_resource_effect(
                "scale-input-00000000",
                scale_input_operation(0),
                &scale_input_fingerprint(0),
            )
            .unwrap(),
        Some(ResourceEffectPreparation::Committed { outcome: scale_input_outcome(0), revision: 0 })
    );
    let newest = before_startup - 1;
    assert_eq!(
        reopened
            .prepare_resource_effect(
                &format!("scale-input-{newest:08}"),
                scale_input_operation(newest),
                &scale_input_fingerprint(newest),
                &json!({}),
                None,
                None,
            )
            .unwrap(),
        ResourceEffectPreparation::Committed { outcome: scale_input_outcome(newest), revision: 0 }
    );
    drop(reopened);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn input_receipt_pruning_reuses_database_pages_at_steady_state() {
    let mut registry = WorkspaceRegistry::in_memory("receipt-page-reuse").unwrap();
    let wave = RESOURCE_INPUT_RECEIPT_CAPACITY + RESOURCE_INPUT_RECEIPT_PRUNE_INTERVAL;
    insert_committed_input_receipts(&mut registry, 0, wave);
    let pages_after_first_wave: i64 =
        registry.connection.query_row("PRAGMA page_count", [], |row| row.get(0)).unwrap();

    insert_committed_input_receipts(&mut registry, wave, wave);
    let pages_after_second_wave: i64 =
        registry.connection.query_row("PRAGMA page_count", [], |row| row.get(0)).unwrap();
    insert_committed_input_receipts(&mut registry, wave * 2, wave);
    let pages_after_third_wave: i64 =
        registry.connection.query_row("PRAGMA page_count", [], |row| row.get(0)).unwrap();

    assert_eq!(uncorrelated_committed_input_count(&registry), RESOURCE_INPUT_RECEIPT_CAPACITY);
    assert!(
        pages_after_second_wave <= pages_after_first_wave + 8,
        "first={pages_after_first_wave} second={pages_after_second_wave}"
    );
    assert!(
        pages_after_third_wave <= pages_after_second_wave + 8,
        "second={pages_after_second_wave} third={pages_after_third_wave}"
    );
}

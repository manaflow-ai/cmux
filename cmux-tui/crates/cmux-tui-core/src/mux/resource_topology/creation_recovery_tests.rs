//! Recovery of interrupted resource creations: resumed creations recheck their resource revision.

use super::*;

#[test]
fn resumed_correlated_creation_rechecks_its_resource_revision() {
    let registry = WorkspaceRegistry::in_memory("creation-resume-precondition").unwrap();
    let mux = Mux::from_workspace_registry(
        "creation-resume-precondition".into(),
        SurfaceOptions::default(),
        registry,
        ProviderWorkspaceState::default(),
        true,
    )
    .unwrap();
    let operation = ResourceOperation::TabCreateBrowser;
    let operation_name = operation_name(operation);
    let correlation_key = "correlation";
    let mutation = WorkspaceMutation::daemon("attempt-one", "test").unwrap();
    let fingerprint = json!({"operation":operation_name});
    let intent = json!({
        "browser_reservation":{
            "tab_id":TabPublicId::random().unwrap(),
            "browser_id":BrowserPublicId::random().unwrap(),
        },
    });
    mux.workspace_registry
        .lock()
        .unwrap()
        .prepare_resource_creation_for(
            correlation_key,
            &mutation,
            &operation_name,
            &fingerprint,
            &intent,
            true,
            None,
            Some(0),
        )
        .unwrap();
    mux.resource_create_empty_workspace(
        None,
        None,
        None,
        &WorkspaceMutation::daemon_local("concurrent-test"),
    )
    .unwrap();

    let error = mux
        .resource_correlated_creation_operation(
            operation,
            vec![ResourceSelectors::default()],
            json!({
                "correlation_key":correlation_key,
                "url":"https://example.test",
            })
            .as_object()
            .unwrap()
            .clone(),
            Some(0),
            &mutation,
            &fingerprint,
        )
        .unwrap_err();
    assert_eq!(error.to_string(), "resource revision conflict: expected 0, current 1");
    mux.shutdown();
}

#[test]
fn restart_reconciles_absent_effects_for_every_created_path_operation() {
    let operations = [
        ResourceOperation::WorkspaceCreate,
        ResourceOperation::WorkspaceRun,
        ResourceOperation::ScreenCreate,
        ResourceOperation::PaneCreate,
        ResourceOperation::PaneSplit,
        ResourceOperation::PaneRun,
        ResourceOperation::TabCreateTerminal,
        ResourceOperation::TabCreateBrowser,
    ];
    for (index, operation) in operations.into_iter().enumerate() {
        let root = std::env::temp_dir().join(format!(
            "cmux-created-path-recovery-{index}-{}",
            crate::workspace_registry::new_uuid_v4()
        ));
        let session = format!("creation-recovery-{index}");
        let operation_name = operation_name(operation);
        let correlation_key = format!("correlation-{index}");
        let idempotency_key = format!("attempt-{index}");
        let fingerprint = json!({"operation":operation_name});
        let intent = match created_identity_kind(operation).unwrap() {
            CreatedIdentityKind::Terminal => json!({
                "terminal_reservation":{
                    "terminal_id":TerminalId::random().unwrap().to_hex(),
                },
            }),
            CreatedIdentityKind::Browser => json!({
                "browser_reservation":{
                    "tab_id":TabPublicId::random().unwrap(),
                    "browser_id":BrowserPublicId::random().unwrap(),
                },
            }),
        };
        {
            let mut registry = WorkspaceRegistry::open(&root, &session).unwrap();
            registry
                .prepare_resource_creation(
                    &correlation_key,
                    &idempotency_key,
                    &operation_name,
                    &fingerprint,
                    &intent,
                    true,
                    None,
                    None,
                )
                .unwrap();
            registry
                .mark_resource_effect_executing(&idempotency_key, &operation_name, &fingerprint)
                .unwrap();
        }
        let registry = WorkspaceRegistry::open(&root, &session).unwrap();
        let mux = Mux::from_workspace_registry(
            session,
            SurfaceOptions::default(),
            registry,
            ProviderWorkspaceState::default(),
            true,
        )
        .unwrap();
        assert_eq!(
            mux.resource_creation_resolution(&correlation_key).unwrap(),
            json!({
                "correlation_key":correlation_key,
                "operation":operation_name,
                "idempotency_key":idempotency_key,
                "state":"not_applied",
                "recovery":"retry_new_idempotency_key",
            })
        );
        mux.shutdown();
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }
}

#[test]
fn restart_rejects_multiple_interrupted_creation_receipts() {
    let root = std::env::temp_dir()
        .join(format!("cmux-created-path-multiple-{}", crate::workspace_registry::new_uuid_v4()));
    let session = "creation-recovery-multiple";
    {
        let mut registry = WorkspaceRegistry::open(&root, session).unwrap();
        for index in 0..2 {
            let correlation_key = format!("correlation-{index}");
            let idempotency_key = format!("attempt-{index}");
            let fingerprint = json!({"operation":"tab.create_browser","index":index});
            let intent = json!({
                "browser_reservation":{
                    "tab_id":TabPublicId::random().unwrap(),
                    "browser_id":BrowserPublicId::random().unwrap(),
                },
            });
            registry
                .prepare_resource_creation(
                    &correlation_key,
                    &idempotency_key,
                    "tab.create_browser",
                    &fingerprint,
                    &intent,
                    true,
                    None,
                    None,
                )
                .unwrap();
            registry
                .mark_resource_effect_executing(
                    &idempotency_key,
                    "tab.create_browser",
                    &fingerprint,
                )
                .unwrap();
        }
    }
    let registry = WorkspaceRegistry::open(&root, session).unwrap();
    let error = match Mux::from_workspace_registry(
        session.into(),
        SurfaceOptions::default(),
        registry,
        ProviderWorkspaceState::default(),
        true,
    ) {
        Ok(mux) => {
            mux.shutdown();
            panic!("multiple interrupted creations unexpectedly started")
        }
        Err(error) => error,
    };
    assert!(
        error
            .to_string()
            .contains("multiple interrupted resource creations cannot be recovered atomically")
    );
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn all_created_path_operations_have_restart_evidence_identity() {
    let operations = [
        (ResourceOperation::WorkspaceCreate, CreatedIdentityKind::Terminal),
        (ResourceOperation::WorkspaceRun, CreatedIdentityKind::Terminal),
        (ResourceOperation::ScreenCreate, CreatedIdentityKind::Terminal),
        (ResourceOperation::PaneCreate, CreatedIdentityKind::Terminal),
        (ResourceOperation::PaneSplit, CreatedIdentityKind::Terminal),
        (ResourceOperation::PaneRun, CreatedIdentityKind::Terminal),
        (ResourceOperation::TabCreateTerminal, CreatedIdentityKind::Terminal),
        (ResourceOperation::TabCreateBrowser, CreatedIdentityKind::Browser),
    ];
    for (operation, expected) in operations {
        assert!(is_created_path_operation(operation));
        assert_eq!(created_identity_kind(operation), Some(expected));
    }
    assert_eq!(created_identity_kind(ResourceOperation::WorkspaceClose), None);
    assert_eq!(created_identity_kind(ResourceOperation::TabClose), None);
}

#[test]
fn creation_fingerprint_excludes_delivery_metadata_only() {
    let fields = json!({
        "correlation_key":"correlation-one",
        "idempotency_key":"attempt-one",
        "expected_revision":"42",
        "url":"https://example.test",
        "name":"Example",
    })
    .as_object()
    .unwrap()
    .clone();
    assert_eq!(
        semantic_creation_fields(&fields),
        json!({
            "url":"https://example.test",
            "name":"Example",
        })
        .as_object()
        .unwrap()
        .clone()
    );
}

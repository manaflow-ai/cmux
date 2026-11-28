use super::*;

#[test]
fn ui_selection_starts_on_the_active_machine() {
    let snapshot = MachineSnapshot {
        machines: vec![
            MachineDescriptor {
                key: MachineKey(1),
                id: "one".into(),
                name: "one".into(),
                subtitle: String::new(),
                status: MachineStatus::Running,
                platform: None,
                capabilities: Vec::new(),
            },
            MachineDescriptor {
                key: MachineKey(2),
                id: "two".into(),
                name: "two".into(),
                subtitle: String::new(),
                status: MachineStatus::Sleeping,
                platform: None,
                capabilities: Vec::new(),
            },
        ],
        active: Some(MachineKey(2)),
        capabilities: MachineCapabilities::default(),
    };

    let ui = MachineUiState::new(snapshot);
    assert_eq!(ui.selection, 1);
    assert_eq!(ui.selected().map(|machine| machine.key), Some(MachineKey(2)));
    assert!(ui.session_available);
    assert_eq!(ui.workspace_creation_policy(), Some(WorkspaceCreationPolicy::SessionOwned));
}

#[test]
fn zero_machine_snapshot_has_no_active_session_or_workspace_policy() {
    let ui = MachineUiState::new(MachineSnapshot {
        machines: Vec::new(),
        active: None,
        capabilities: MachineCapabilities { create: true, connect: true },
    });

    assert_eq!(ui.selection, 0);
    assert!(ui.selected().is_none());
    assert!(!ui.session_available);
    assert_eq!(ui.workspace_creation_policy(), None);
}

#[test]
fn workspace_creation_policy_is_scoped_to_the_active_machine() {
    let first = MachineKey(1);
    let second = MachineKey(2);
    let mut ui = MachineUiState::new(MachineSnapshot {
        machines: vec![
            MachineDescriptor {
                key: first,
                id: "one".into(),
                name: "one".into(),
                subtitle: String::new(),
                status: MachineStatus::Running,
                platform: None,
                capabilities: Vec::new(),
            },
            MachineDescriptor {
                key: second,
                id: "two".into(),
                name: "two".into(),
                subtitle: String::new(),
                status: MachineStatus::Running,
                platform: None,
                capabilities: Vec::new(),
            },
        ],
        active: Some(first),
        capabilities: MachineCapabilities::default(),
    });
    let provider_policy = WorkspaceCreationPolicy::ProviderOwned {
        default_mode: WorkspaceCreationMode::Host,
        modes: vec![WorkspaceCreationMode::Host, WorkspaceCreationMode::Isolated],
    };
    ui.set_workspace_creation_policy(first, provider_policy.clone());

    assert_eq!(ui.workspace_creation_policy(), Some(provider_policy));
    ui.snapshot.active = Some(second);
    assert_eq!(ui.workspace_creation_policy(), Some(WorkspaceCreationPolicy::SessionOwned));
}

#[test]
fn rail_targets_include_controls_catalog_and_pinned_actions_in_visual_order() {
    let mut ui = MachineUiState::new(MachineSnapshot {
        machines: vec![MachineDescriptor {
            key: MachineKey(7),
            id: "seven".into(),
            name: "seven".into(),
            subtitle: String::new(),
            status: MachineStatus::Running,
            platform: None,
            capabilities: Vec::new(),
        }],
        active: Some(MachineKey(7)),
        capabilities: MachineCapabilities { create: true, connect: true },
    });
    ui.set_provider_presentation(ProviderPresentation {
        scopes: vec![ProviderScopeDescriptor {
            id: "personal".into(),
            name: "Personal".into(),
            kind: ProviderScopeKind::Personal,
            can_admin: false,
        }],
        selected_scope_id: "personal".into(),
        actions: vec![ProviderActionDescriptor {
            id: "billing".into(),
            label: "Billing".into(),
            target: ProviderActionTarget::Scope,
            destructive: false,
            fields: Vec::new(),
        }],
    });

    assert_eq!(
        ui.rail_targets(),
        vec![
            MachineRailTarget::Machine(MachineKey(7)),
            MachineRailTarget::NewVm,
            MachineRailTarget::ConnectMachine,
        ]
    );
}

#[test]
fn catalog_refresh_preserves_selection_by_machine_key_after_reorder() {
    let descriptor = |key| MachineDescriptor {
        key: MachineKey(key),
        id: key.to_string(),
        name: key.to_string(),
        subtitle: String::new(),
        status: MachineStatus::Running,
        platform: None,
        capabilities: Vec::new(),
    };
    let mut previous = MachineUiState::new(MachineSnapshot {
        machines: vec![descriptor(1), descriptor(2)],
        active: Some(MachineKey(1)),
        capabilities: MachineCapabilities::default(),
    });
    previous.select_rail_target(MachineRailTarget::Machine(MachineKey(2)));
    let mut update = MachineUiState::new(MachineSnapshot {
        machines: vec![descriptor(2), descriptor(1)],
        active: Some(MachineKey(1)),
        capabilities: MachineCapabilities::default(),
    });

    update.reconcile_navigation_from(&previous);

    assert_eq!(update.rail_target(), Some(MachineRailTarget::Machine(MachineKey(2))));
    assert_eq!(update.selection, 0);
}

fn action_field(kind: ProviderActionFieldKind) -> ProviderActionFieldDescriptor {
    ProviderActionFieldDescriptor {
        id: "value".into(),
        label: "Value".into(),
        kind,
        required: true,
        max_length: None,
        minimum: None,
        maximum: None,
        placeholder: None,
    }
}

fn action(fields: Vec<ProviderActionFieldDescriptor>) -> ProviderActionDescriptor {
    ProviderActionDescriptor {
        id: "action".into(),
        label: "Action".into(),
        target: ProviderActionTarget::Scope,
        destructive: false,
        fields,
    }
}

#[test]
fn provider_presentation_resolves_selected_scope_by_opaque_id() {
    let mut ui = MachineUiState::new(MachineSnapshot {
        machines: Vec::new(),
        active: None,
        capabilities: MachineCapabilities::default(),
    });
    ui.set_provider_presentation(ProviderPresentation {
        scopes: vec![
            ProviderScopeDescriptor {
                id: "personal-id".into(),
                name: "Personal".into(),
                kind: ProviderScopeKind::Personal,
                can_admin: false,
            },
            ProviderScopeDescriptor {
                id: "team-id".into(),
                name: "Acme".into(),
                kind: ProviderScopeKind::Team,
                can_admin: true,
            },
        ],
        selected_scope_id: "team-id".into(),
        actions: Vec::new(),
    });

    assert_eq!(ui.selected_scope().map(|scope| scope.name.as_str()), Some("Acme"));
    assert_eq!(ui.rail_selection, MachineRailSelection::Machine);
}

#[test]
fn provider_action_builds_zero_and_one_field_typed_requests() {
    assert_eq!(
        action(Vec::new()).request(None, &ProviderActionContext::default()),
        Ok(MachineRequest::InvokeProviderAction {
            action_id: "action".into(),
            values: BTreeMap::new(),
            machine_id: None,
            workspace_id: None,
        })
    );

    let request = action(vec![action_field(ProviderActionFieldKind::Email)])
        .request(Some("  person@example.com  "), &ProviderActionContext::default())
        .unwrap();
    assert_eq!(
        request,
        MachineRequest::InvokeProviderAction {
            action_id: "action".into(),
            values: BTreeMap::from([(
                "value".into(),
                ProviderActionValue::Text("person@example.com".into())
            )]),
            machine_id: None,
            workspace_id: None,
        }
    );
}

#[test]
fn provider_action_validates_required_email_integer_and_field_count() {
    assert_eq!(
        action(vec![action_field(ProviderActionFieldKind::Text)])
            .request(Some(""), &ProviderActionContext::default()),
        Err(ProviderActionInputError::Required)
    );
    assert_eq!(
        action(vec![action_field(ProviderActionFieldKind::Email)])
            .request(Some("not-an-email"), &ProviderActionContext::default()),
        Err(ProviderActionInputError::InvalidEmail)
    );

    let mut integer = action_field(ProviderActionFieldKind::Integer);
    integer.minimum = Some(2);
    integer.maximum = Some(4);
    assert_eq!(
        action(vec![integer.clone()]).request(Some("one"), &ProviderActionContext::default()),
        Err(ProviderActionInputError::InvalidInteger)
    );
    assert_eq!(
        action(vec![integer.clone()]).request(Some("1"), &ProviderActionContext::default()),
        Err(ProviderActionInputError::BelowMinimum)
    );
    assert_eq!(
        action(vec![integer.clone()]).request(Some("5"), &ProviderActionContext::default()),
        Err(ProviderActionInputError::AboveMaximum)
    );
    assert_eq!(
        action(vec![integer, action_field(ProviderActionFieldKind::Text)])
            .request(None, &ProviderActionContext::default()),
        Err(ProviderActionInputError::UnsupportedFieldCount)
    );
}

#[test]
fn provider_action_binds_selected_workspace_context() {
    let mut descriptor = action(Vec::new());
    descriptor.target = ProviderActionTarget::SelectedWorkspace;
    let context = ProviderActionContext {
        machine_id: Some("machine-1".into()),
        workspace_id: Some("workspace-1".into()),
    };
    assert_eq!(
        descriptor.request(None, &context),
        Ok(MachineRequest::InvokeProviderAction {
            action_id: "action".into(),
            values: BTreeMap::new(),
            machine_id: Some("machine-1".into()),
            workspace_id: Some("workspace-1".into()),
        })
    );
    assert_eq!(
        descriptor.request(
            None,
            &ProviderActionContext { machine_id: Some("machine-1".into()), workspace_id: None }
        ),
        Err(ProviderActionInputError::MissingSelectedWorkspace)
    );
    assert_eq!(
        descriptor.request(None, &ProviderActionContext::default()),
        Err(ProviderActionInputError::MissingSelectedMachine)
    );

    let mut machine_scoped = action(Vec::new());
    machine_scoped.target = ProviderActionTarget::SelectedMachine;
    assert_eq!(
        machine_scoped.request(None, &context),
        Ok(MachineRequest::InvokeProviderAction {
            action_id: "action".into(),
            values: BTreeMap::new(),
            machine_id: Some("machine-1".into()),
            workspace_id: None,
        })
    );
    assert_eq!(
        machine_scoped.request(None, &ProviderActionContext::default()),
        Err(ProviderActionInputError::MissingSelectedMachine)
    );
}

#[test]
fn dropping_update_stream_cancels_and_joins_a_blocked_worker() {
    let update = MachineUiState::new(MachineSnapshot {
        machines: Vec::new(),
        active: None,
        capabilities: MachineCapabilities::default(),
    });
    let (sender, receiver) = std::sync::mpsc::sync_channel(1);
    sender.send(MachineUpdate::Ui(Box::new(update.clone()))).unwrap();
    let stop = Arc::new(AtomicBool::new(false));
    let exited = Arc::new(AtomicBool::new(false));
    let worker_exited = exited.clone();
    let worker = std::thread::spawn(move || {
        // This blocks until MachineUpdateStream drops its receiver.
        let _ = sender.send(MachineUpdate::Ui(Box::new(update)));
        worker_exited.store(true, Ordering::Release);
    });
    let stream = MachineUpdateStream::new(receiver, stop.clone(), worker);

    drop(stream);

    assert!(stop.load(Ordering::Acquire));
    assert!(exited.load(Ordering::Acquire));
}

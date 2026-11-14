use serde::de::DeserializeOwned;
use serde_json::{Value, json};

use super::*;

fn id(value: &str) -> OpaqueId {
    OpaqueId::new(value).unwrap()
}

fn token(value: &str) -> BearerToken {
    BearerToken::new(value).unwrap()
}

fn specifier(value: &str) -> ExternalMachineSpecifier {
    ExternalMachineSpecifier::new(value).unwrap()
}

#[test]
fn credential_wrappers_compare_without_exposing_values() {
    assert_eq!(token("single-use-ticket"), token("single-use-ticket"));
    assert_ne!(token("single-use-ticket"), token("different-ticket"));
    assert_eq!(specifier("PAIR 4J7K"), specifier("PAIR 4J7K"));
    assert_ne!(specifier("PAIR 4J7K"), specifier("PAIR 9Q2M"));
}

fn empty_snapshot() -> SnapshotResult {
    SnapshotResult {
        revision: 21,
        scopes: vec![ScopeDescriptor {
            id: id("personal"),
            display_name: "Personal".into(),
            kind: ScopeKind::Personal,
            can_admin: false,
        }],
        selected_scope_id: id("personal"),
        machines: Vec::new(),
        selected_machine_id: None,
        capabilities: ProviderCapabilities::default(),
        actions: Vec::new(),
        notice: None,
    }
}

fn assert_response_round_trip<T>(result: T)
where
    T: fmt::Debug + Clone + PartialEq + Eq + Serialize + DeserializeOwned,
{
    let response = ResponseEnvelope::success(id("response-id"), result);
    let encoded = serde_json::to_value(&response).unwrap();
    let decoded: ResponseEnvelope<T> = serde_json::from_value(encoded).unwrap();
    assert_eq!(decoded, response);
}

#[test]
fn response_capabilities_are_additive_and_legacy_compatible() {
    #[derive(Debug, Deserialize, PartialEq, Eq)]
    struct LegacyHelloResponse {
        protocol: Protocol,
        version: Version,
        id: OpaqueId,
        result: HelloResult,
    }

    let hello = HelloResult {
        provider_id: id("cmux-cloud"),
        provider_name: "cmux Cloud".into(),
        negotiated_version: Version,
    };
    let response = ResponseEnvelope::success(id("hello-response"), hello.clone())
        .with_capabilities([
            MACHINE_LIFECYCLE_CAPABILITY,
            WORKSPACE_LIFECYCLE_CAPABILITY,
            "future-provider-feature-v1",
        ]);
    let encoded = serde_json::to_value(&response).unwrap();
    assert_eq!(
        encoded["capabilities"],
        json!(["machine-lifecycle-v1", "workspace-lifecycle-v1", "future-provider-feature-v1"])
    );

    let decoded: ResponseEnvelope<HelloResult> = serde_json::from_value(encoded.clone()).unwrap();
    assert_eq!(decoded, response);

    let legacy: LegacyHelloResponse = serde_json::from_value(encoded).unwrap();
    assert_eq!(legacy.protocol, Protocol);
    assert_eq!(legacy.version, Version);
    assert_eq!(legacy.id, id("hello-response"));
    assert_eq!(legacy.result, hello);

    let legacy_wire = json!({
        "protocol": "cmux.machine-provider",
        "version": 1,
        "id": "hello-response",
        "result": hello
    });
    let decoded: ResponseEnvelope<HelloResult> = serde_json::from_value(legacy_wire).unwrap();
    assert!(decoded.capabilities.is_empty());
}

#[test]
fn provider_action_context_is_additive_and_legacy_compatible() {
    let legacy: ProviderAction = serde_json::from_value(serde_json::json!({
        "id": "legacy.action",
        "label": "Legacy action"
    }))
    .unwrap();
    assert_eq!(legacy.target, ProviderActionTarget::Scope);
    let encoded = serde_json::to_value(&legacy).unwrap();
    assert!(encoded.get("target").is_none());

    let params: InvokeActionParams = serde_json::from_value(serde_json::json!({
        "action_id": "legacy.action",
        "mutation_id": "mutation-1"
    }))
    .unwrap();
    assert_eq!(params.machine_id, None);
    assert_eq!(params.workspace_id, None);
}

#[test]
fn client_capability_negotiation_matches_the_v1_golden_document() {
    let request = RequestEnvelope::new(
        id("capabilities-1"),
        ProviderRequest::NegotiateClientCapabilities(NegotiateClientCapabilitiesParams {
            capabilities: vec![PROVIDER_ACTION_TARGETS_CLIENT_CAPABILITY.to_string()],
        }),
    );
    let document = json!({
        "protocol": "cmux.machine-provider",
        "version": 1,
        "id": "capabilities-1",
        "method": "negotiate_client_capabilities",
        "params": {
            "capabilities": ["provider-action-targets-v1"]
        }
    });
    assert_eq!(serde_json::to_value(&request).unwrap(), document);
    assert_eq!(serde_json::from_value::<RequestEnvelope>(document).unwrap(), request);
    assert_response_round_trip(NegotiateClientCapabilitiesResult {
        capabilities: vec![PROVIDER_ACTION_TARGETS_CLIENT_CAPABILITY.to_string()],
    });
}

#[test]
fn targeted_actions_are_removed_until_the_client_capability_is_negotiated() {
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct LegacyProviderAction {
        id: OpaqueId,
        label: String,
        #[serde(default)]
        destructive: bool,
        #[serde(default)]
        fields: Vec<ActionField>,
    }

    let scope = ProviderAction {
        id: id("scope.action"),
        label: "Scope action".into(),
        target: ProviderActionTarget::Scope,
        destructive: false,
        fields: Vec::new(),
    };
    let targeted = ProviderAction {
        id: id("workspace.action"),
        label: "Workspace action".into(),
        target: ProviderActionTarget::SelectedWorkspace,
        destructive: false,
        fields: Vec::new(),
    };
    assert_eq!(serde_json::to_value(&targeted).unwrap()["target"], json!("selected_workspace"));
    let mut snapshot = empty_snapshot();
    snapshot.actions = vec![scope.clone(), targeted.clone()];
    snapshot.retain_actions_for_client_capabilities(&[]);
    assert_eq!(snapshot.actions, vec![scope.clone()]);

    let legacy: LegacyProviderAction =
        serde_json::from_value(serde_json::to_value(scope).unwrap()).unwrap();
    assert_eq!(legacy.id, id("scope.action"));
    assert_eq!(legacy.label, "Scope action");
    assert!(!legacy.destructive);
    assert!(legacy.fields.is_empty());
    assert!(
        serde_json::from_value::<LegacyProviderAction>(
            serde_json::to_value(targeted.clone()).unwrap()
        )
        .is_err()
    );

    let mut negotiated = empty_snapshot();
    negotiated.actions = vec![targeted.clone()];
    negotiated.retain_actions_for_client_capabilities(&[
        PROVIDER_ACTION_TARGETS_CLIENT_CAPABILITY.to_string()
    ]);
    assert_eq!(negotiated.actions, vec![targeted]);
}

#[test]
fn unknown_provider_action_targets_do_not_reject_the_action_list() {
    let actions: Vec<ProviderAction> = serde_json::from_value(serde_json::json!([
        {
            "id": "workspace.pane.inspect",
            "label": "Inspect selected pane",
            "target": "selected_pane"
        }
    ]))
    .unwrap();

    assert_eq!(serde_json::to_value(actions[0].target).unwrap(), serde_json::json!("unsupported"));
}

#[test]
fn snapshot_request_matches_the_v1_golden_document() {
    let request = RequestEnvelope::new(
        id("17"),
        ProviderRequest::Snapshot(SnapshotParams { known_revision: Some(11) }),
    );
    let expected = json!({
        "protocol": "cmux.machine-provider",
        "version": 1,
        "id": "17",
        "method": "snapshot",
        "params": { "known_revision": 11 }
    });

    let encoded = serde_json::to_value(&request).unwrap();
    assert_eq!(encoded, expected);
    assert_eq!(serde_json::from_value::<RequestEnvelope>(expected).unwrap(), request);
}

#[test]
fn durable_notice_requests_match_the_v1_golden_documents() {
    let subscribe = RequestEnvelope::new(
        id("subscribe-1"),
        ProviderRequest::SubscribeNotices(SubscribeNoticesParams {
            consumer_id: id("cmux-process-1"),
        }),
    );
    let subscribe_document = json!({
        "protocol": "cmux.machine-provider",
        "version": 1,
        "id": "subscribe-1",
        "method": "subscribe_notices",
        "params": {
            "consumer_id": "cmux-process-1"
        }
    });
    assert_eq!(serde_json::to_value(&subscribe).unwrap(), subscribe_document);
    assert_eq!(serde_json::from_value::<RequestEnvelope>(subscribe_document).unwrap(), subscribe);

    let acknowledge = RequestEnvelope::new(
        id("ack-1"),
        ProviderRequest::AcknowledgeNotice(AcknowledgeNoticeParams {
            notice_id: id("usage-warning-80"),
            sequence: 42,
        }),
    );
    let acknowledge_document = json!({
        "protocol": "cmux.machine-provider",
        "version": 1,
        "id": "ack-1",
        "method": "acknowledge_notice",
        "params": {
            "notice_id": "usage-warning-80",
            "sequence": 42
        }
    });
    assert_eq!(serde_json::to_value(&acknowledge).unwrap(), acknowledge_document);
    assert_eq!(
        serde_json::from_value::<RequestEnvelope>(acknowledge_document).unwrap(),
        acknowledge
    );

    assert_response_round_trip(SubscribeNoticesResult { sequence: 41 });
    assert_response_round_trip(AcknowledgeNoticeResult { sequence: 42 });
}

#[test]
fn connect_external_machine_request_matches_the_v1_golden_document() {
    let request = RequestEnvelope::new(
        id("connect-17"),
        ProviderRequest::ConnectExternalMachine(ConnectExternalMachineParams {
            scope_id: id("team"),
            specifier: specifier("PAIR 4J7K"),
            mutation_id: id("mutation-connect-17"),
        }),
    );
    let expected = json!({
        "protocol": "cmux.machine-provider",
        "version": 1,
        "id": "connect-17",
        "method": "connect_external_machine",
        "params": {
            "scope_id": "team",
            "specifier": "PAIR 4J7K",
            "mutation_id": "mutation-connect-17"
        }
    });

    let encoded = serde_json::to_value(&request).unwrap();
    assert_eq!(encoded, expected);
    assert_eq!(serde_json::from_value::<RequestEnvelope>(expected).unwrap(), request);
    let debug = format!("{request:?}");
    assert!(debug.contains("ExternalMachineSpecifier([redacted])"));
    assert!(!debug.contains("PAIR 4J7K"));
}

#[test]
fn external_machine_specifiers_are_bounded_and_unambiguous() {
    assert!(ExternalMachineSpecifier::new("mini.local").is_ok());
    assert!(ExternalMachineSpecifier::new("PAIR 4J7K").is_ok());
    for invalid in [
        String::new(),
        " ".to_string(),
        " mini.local".to_string(),
        "mini.local ".to_string(),
        "PAIR\n4J7K".to_string(),
        "x".repeat(MAX_EXTERNAL_MACHINE_SPECIFIER_BYTES + 1),
    ] {
        assert!(
            ExternalMachineSpecifier::new(invalid).is_err(),
            "invalid external-machine specifier was accepted"
        );
    }

    let unknown = json!({
        "protocol": "cmux.machine-provider",
        "version": 1,
        "id": "connect-17",
        "method": "connect_external_machine",
        "params": {
            "scope_id": "team",
            "specifier": "mini.local",
            "mutation_id": "mutation-connect-17",
            "shell": "ssh"
        }
    });
    assert!(serde_json::from_value::<RequestEnvelope>(unknown).is_err());
}

#[test]
fn snapshot_response_round_trips_the_full_provider_model() {
    let snapshot = SnapshotResult {
        revision: 13,
        scopes: vec![ScopeDescriptor {
            id: id("subject-uuid"),
            display_name: "Acme".into(),
            kind: ScopeKind::Team,
            can_admin: true,
        }],
        selected_scope_id: id("subject-uuid"),
        machines: vec![MachineDescriptor {
            id: id("vm-uuid"),
            display_name: "Sirius".into(),
            subtitle: "Freestyle".into(),
            status: MachineStatus::Running,
            connectable: true,
            workspace_create: WorkspaceCreatePolicy::Provider {
                default_mode: WorkspaceCreateMode::Isolated,
                modes: vec![WorkspaceCreateMode::Isolated, WorkspaceCreateMode::Host],
            },
            platform: Some(MachinePlatform {
                os: Some("linux".into()),
                arch: Some("x86_64".into()),
            }),
            capabilities: vec!["terminal".into(), "workspace".into(), "agent_session".into()],
        }],
        selected_machine_id: Some(id("vm-uuid")),
        capabilities: ProviderCapabilities {
            create_machine: true,
            connect_external_machine: false,
        },
        actions: vec![ProviderAction {
            id: id("team.invite"),
            label: "Invite member".into(),
            target: ProviderActionTarget::Scope,
            destructive: false,
            fields: vec![ActionField {
                id: "email".into(),
                kind: ActionFieldKind::Email,
                label: "Email address".into(),
                required: true,
                max_length: Some(254),
                minimum: None,
                maximum: None,
                placeholder: None,
            }],
        }],
        notice: None,
    };
    let response = ResponseEnvelope::success(id("17"), snapshot);
    let encoded = serde_json::to_value(&response).unwrap();
    let expected = json!({
        "protocol": "cmux.machine-provider",
        "version": 1,
        "id": "17",
        "result": {
            "revision": 13,
            "scopes": [{
                "id": "subject-uuid",
                "display_name": "Acme",
                "kind": "team",
                "can_admin": true
            }],
            "selected_scope_id": "subject-uuid",
            "machines": [{
                "id": "vm-uuid",
                "display_name": "Sirius",
                "subtitle": "Freestyle",
                "status": "running",
                "connectable": true,
                "workspace_create": {
                    "owner": "provider",
                    "default_mode": "isolated",
                    "modes": ["isolated", "host"]
                },
                "platform": {"os": "linux", "arch": "x86_64"},
                "capabilities": ["terminal", "workspace", "agent_session"]
            }],
            "selected_machine_id": "vm-uuid",
            "capabilities": {
                "create_machine": true,
                "connect_external_machine": false
            },
            "actions": [{
                "id": "team.invite",
                "label": "Invite member",
                "destructive": false,
                "fields": [{
                    "id": "email",
                    "kind": "email",
                    "label": "Email address",
                    "required": true,
                    "max_length": 254
                }]
            }]
        }
    });
    assert_eq!(encoded, expected);

    let decoded: ResponseEnvelope<SnapshotResult> = serde_json::from_value(expected).unwrap();
    assert_eq!(decoded, response);

    let mut legacy = serde_json::to_value(&response).unwrap();
    let machine = legacy["result"]["machines"][0].as_object_mut().unwrap();
    machine.remove("platform");
    machine.remove("capabilities");
    let legacy: ResponseEnvelope<SnapshotResult> = serde_json::from_value(legacy).unwrap();
    let ProviderResponse::Success(result) = legacy.response else {
        panic!("expected a legacy snapshot result");
    };
    assert!(result.machines[0].platform.is_none());
    assert!(result.machines[0].capabilities.is_empty());
}

#[test]
fn open_transport_and_events_match_the_v1_golden_documents() {
    let response = ResponseEnvelope::success(
        id("open-1"),
        OpenMachineResult {
            connection_id: id("connection-uuid"),
            transport: TransportDescriptor::ProviderStream {
                ticket: token("single-use-ticket"),
                expires_at: "2026-07-21T22:00:30Z".into(),
            },
            workspace_mirror_authority: Some(token(
                "provider-workspace-authority-0000000000000001",
            )),
        },
    );
    let debug = format!("{response:?}");
    assert!(debug.contains("BearerToken([redacted])"));
    assert!(!debug.contains("provider-workspace-authority-0000000000000001"));
    assert_eq!(
        serde_json::to_value(response).unwrap(),
        json!({
            "protocol": "cmux.machine-provider",
            "version": 1,
            "id": "open-1",
            "result": {
                "connection_id": "connection-uuid",
                "transport": {
                    "kind": "provider_stream",
                    "ticket": "single-use-ticket",
                    "expires_at": "2026-07-21T22:00:30Z"
                },
                "workspace_mirror_authority": "provider-workspace-authority-0000000000000001"
            }
        })
    );

    let event =
        EventEnvelope::new(ProviderEvent::SnapshotChanged(SnapshotChangedEvent { revision: 14 }));
    assert_eq!(
        serde_json::to_value(event).unwrap(),
        json!({
            "protocol": "cmux.machine-provider",
            "version": 1,
            "event": "snapshot_changed",
            "params": { "revision": 14 }
        })
    );
}

#[test]
fn connection_progress_matches_the_wire_document() {
    let event = EventEnvelope::new(ProviderEvent::ConnectionProgress(ConnectionProgressEvent {
        machine_id: id("vm-1"),
        message: "resuming the machine".into(),
    }));
    let document = json!({
        "protocol": "cmux.machine-provider",
        "version": 1,
        "event": "connection_progress",
        "params": {
            "machine_id": "vm-1",
            "message": "resuming the machine"
        }
    });
    assert_eq!(serde_json::to_value(&event).unwrap(), document);
    assert_eq!(serde_json::from_value::<EventEnvelope>(document).unwrap(), event);
}

#[test]
fn durable_notice_metadata_is_additive_to_the_legacy_notice_event() {
    #[derive(Debug, Deserialize, PartialEq, Eq)]
    struct LegacyEventEnvelope {
        protocol: Protocol,
        version: Version,
        #[serde(flatten)]
        event: ProviderEvent,
    }

    let event = EventEnvelope::with_delivery(
        ProviderEvent::Notice(ProviderNotice {
            level: NoticeLevel::Warning,
            message: "Trial compute is almost exhausted".into(),
        }),
        NoticeDelivery { notice_id: id("usage-warning-80"), sequence: 42 },
    );
    let document = json!({
        "protocol": "cmux.machine-provider",
        "version": 1,
        "delivery": {
            "notice_id": "usage-warning-80",
            "sequence": 42
        },
        "event": "notice",
        "params": {
            "level": "warning",
            "message": "Trial compute is almost exhausted"
        }
    });
    assert_eq!(serde_json::to_value(&event).unwrap(), document);
    assert_eq!(serde_json::from_value::<EventEnvelope>(document.clone()).unwrap(), event);

    let legacy: LegacyEventEnvelope = serde_json::from_value(document).unwrap();
    assert_eq!(legacy.protocol, Protocol);
    assert_eq!(legacy.version, Version);
    assert_eq!(legacy.event, event.event);

    let legacy_event = EventEnvelope::new(ProviderEvent::Notice(ProviderNotice {
        level: NoticeLevel::Info,
        message: "Legacy notice".into(),
    }));
    assert_eq!(
        serde_json::to_value(legacy_event).unwrap(),
        json!({
            "protocol": "cmux.machine-provider",
            "version": 1,
            "event": "notice",
            "params": {
                "level": "info",
                "message": "Legacy notice"
            }
        })
    );
}

#[test]
fn durable_notice_metadata_is_strict_while_event_metadata_remains_additive() {
    let future_metadata = json!({
        "protocol": "cmux.machine-provider",
        "version": 1,
        "delivery": {
            "notice_id": "usage-warning-80",
            "sequence": 42
        },
        "future_trace": "trace-1",
        "event": "notice",
        "params": {
            "level": "warning",
            "message": "Trial compute is almost exhausted"
        }
    });
    assert!(serde_json::from_value::<EventEnvelope>(future_metadata).is_ok());

    for invalid_delivery in [
        json!({ "notice_id": "usage-warning-80" }),
        json!({ "notice_id": "usage-warning-80", "sequence": 42, "future": true }),
        json!({ "notice_id": "", "sequence": 42 }),
    ] {
        let document = json!({
            "protocol": "cmux.machine-provider",
            "version": 1,
            "delivery": invalid_delivery,
            "event": "notice",
            "params": {
                "level": "warning",
                "message": "Trial compute is almost exhausted"
            }
        });
        assert!(serde_json::from_value::<EventEnvelope>(document).is_err());
    }
}

#[test]
fn open_machine_authority_opt_in_preserves_legacy_v1_shape() {
    let legacy = RequestEnvelope::new(
        id("legacy-open"),
        ProviderRequest::OpenMachine(OpenMachineParams {
            machine_id: id("machine"),
            workspace_mirror_authority: false,
        }),
    );
    assert_eq!(
        serde_json::to_value(legacy).unwrap(),
        json!({
            "protocol": "cmux.machine-provider",
            "version": 1,
            "id": "legacy-open",
            "method": "open_machine",
            "params": { "machine_id": "machine" }
        })
    );

    let opted_in = RequestEnvelope::new(
        id("authority-open"),
        ProviderRequest::OpenMachine(OpenMachineParams {
            machine_id: id("machine"),
            workspace_mirror_authority: true,
        }),
    );
    assert_eq!(
        serde_json::to_value(opted_in).unwrap(),
        json!({
            "protocol": "cmux.machine-provider",
            "version": 1,
            "id": "authority-open",
            "method": "open_machine",
            "params": {
                "machine_id": "machine",
                "workspace_mirror_authority": true
            }
        })
    );
}

#[test]
fn every_v1_control_method_and_result_round_trips() {
    let mut action_values = BTreeMap::new();
    action_values.insert("email".into(), ActionValue::Text("member@example.com".into()));
    action_values.insert("seats".into(), ActionValue::Integer(4));
    let requests = vec![
        ProviderRequest::Hello(HelloParams {
            token: token("provider-token"),
            client: ClientDescriptor {
                name: "cmux-tui".into(),
                version: "0.1.0".into(),
                supported_versions: vec![1],
            },
        }),
        ProviderRequest::OpenMachine(OpenMachineParams {
            machine_id: id("machine"),
            workspace_mirror_authority: false,
        }),
        ProviderRequest::SelectScope(SelectScopeParams { scope_id: id("team") }),
        ProviderRequest::CreateMachine(CreateMachineParams {
            scope_id: id("team"),
            mutation_id: id("mutation-machine"),
        }),
        ProviderRequest::ConnectExternalMachine(ConnectExternalMachineParams {
            scope_id: id("team"),
            specifier: specifier("PAIR 4J7K"),
            mutation_id: id("mutation-connect-machine"),
        }),
        ProviderRequest::MachineLifecycleSnapshot(MachineLifecycleSnapshotParams {
            scope_id: id("team"),
            known_revision: Some(22),
        }),
        ProviderRequest::RenameMachine(RenameMachineParams {
            scope_id: id("team"),
            machine_id: id("machine"),
            expected_version: 3,
            display_name: "new-machine-name".into(),
            mutation_id: id("mutation-rename-machine"),
        }),
        ProviderRequest::DeleteMachine(MachineMutationParams {
            scope_id: id("team"),
            machine_id: id("machine"),
            expected_version: 4,
            mutation_id: id("mutation-delete-machine"),
        }),
        ProviderRequest::RestoreMachine(MachineMutationParams {
            scope_id: id("team"),
            machine_id: id("machine"),
            expected_version: 5,
            mutation_id: id("mutation-restore-machine"),
        }),
        ProviderRequest::PurgeMachine(MachineMutationParams {
            scope_id: id("team"),
            machine_id: id("machine"),
            expected_version: 6,
            mutation_id: id("mutation-purge-machine"),
        }),
        ProviderRequest::CreateWorkspace(CreateWorkspaceParams {
            machine_id: id("machine"),
            mode: WorkspaceCreateMode::Host,
            mutation_id: id("mutation-workspace"),
        }),
        ProviderRequest::WorkspaceSnapshot(WorkspaceSnapshotParams {
            machine_id: id("machine"),
            known_revision: Some(23),
        }),
        ProviderRequest::RenameWorkspace(RenameWorkspaceParams {
            machine_id: id("machine"),
            workspace_id: id("workspace"),
            expected_version: 4,
            display_name: "new-name".into(),
            mutation_id: id("mutation-rename-workspace"),
        }),
        ProviderRequest::DeleteWorkspace(WorkspaceMutationParams {
            machine_id: id("machine"),
            workspace_id: id("workspace"),
            expected_version: 5,
            mutation_id: id("mutation-delete-workspace"),
        }),
        ProviderRequest::RestoreWorkspace(WorkspaceMutationParams {
            machine_id: id("machine"),
            workspace_id: id("workspace"),
            expected_version: 6,
            mutation_id: id("mutation-restore-workspace"),
        }),
        ProviderRequest::PurgeWorkspace(WorkspaceMutationParams {
            machine_id: id("machine"),
            workspace_id: id("workspace"),
            expected_version: 7,
            mutation_id: id("mutation-purge-workspace"),
        }),
        ProviderRequest::InvokeAction(InvokeActionParams {
            action_id: id("team.invite"),
            values: action_values,
            machine_id: Some(id("machine")),
            workspace_id: Some(id("workspace")),
            mutation_id: id("mutation-action"),
        }),
        ProviderRequest::CloseMachine(CloseMachineParams { connection_id: id("connection") }),
    ];
    for (index, request) in requests.into_iter().enumerate() {
        let envelope = RequestEnvelope::new(id(&format!("request-{index}")), request);
        let encoded = serde_json::to_value(&envelope).unwrap();
        let decoded: RequestEnvelope = serde_json::from_value(encoded).unwrap();
        assert_eq!(decoded, envelope);
    }

    assert_response_round_trip(HelloResult {
        provider_id: id("cmux-cloud"),
        provider_name: "cmux Cloud".into(),
        negotiated_version: Version,
    });
    assert_response_round_trip(SelectScopeResult { snapshot: empty_snapshot() });
    assert_response_round_trip(CreateMachineResult {
        machine_id: id("new-machine"),
        revision: 22,
        notice: Some(ProviderNotice {
            level: NoticeLevel::Info,
            message: "VM provisioning".into(),
        }),
    });
    assert_response_round_trip(ConnectExternalMachineResult {
        machine_id: id("paired-machine"),
        revision: 23,
        notice: Some(ProviderNotice {
            level: NoticeLevel::Info,
            message: "Machine connected".into(),
        }),
    });
    assert_response_round_trip(MachineLifecycleSnapshotResult {
        revision: 23,
        scope_id: id("team"),
        machines: vec![MachineLifecycleDescriptor {
            id: id("machine"),
            display_name: "earth".into(),
            status: MachineLifecycleStatus::Recoverable,
            version: 7,
            recoverable_until: Some("2026-07-28T22:00:30Z".into()),
            capabilities: MachineLifecycleCapabilities {
                rename: false,
                delete: false,
                restore: true,
                purge: true,
            },
        }],
    });
    assert_response_round_trip(MachineMutationResult {
        machine_id: id("machine"),
        version: 8,
        revision: 24,
        notice: Some(ProviderNotice {
            level: NoticeLevel::Info,
            message: "Machine restore requested".into(),
        }),
    });
    assert_response_round_trip(CreateWorkspaceResult {
        revision: 23,
        notice: Some(ProviderNotice {
            level: NoticeLevel::Info,
            message: "Workspace creation requested".into(),
        }),
    });
    assert_response_round_trip(WorkspaceSnapshotResult {
        revision: 24,
        machine_id: id("machine"),
        workspaces: vec![WorkspaceLifecycleDescriptor {
            id: id("workspace"),
            display_name: "earth".into(),
            mode: WorkspaceCreateMode::Isolated,
            status: WorkspaceLifecycleStatus::Recoverable,
            version: 7,
            recoverable_until: Some("2026-07-28T22:00:30Z".into()),
            capabilities: WorkspaceLifecycleCapabilities {
                rename: false,
                delete: false,
                restore: true,
                purge: true,
            },
        }],
    });
    assert_response_round_trip(WorkspaceMutationResult {
        workspace_id: id("workspace"),
        version: 8,
        revision: 25,
        notice: Some(ProviderNotice {
            level: NoticeLevel::Info,
            message: "Workspace restore requested".into(),
        }),
    });
    assert_response_round_trip(InvokeActionResult {
        revision: 24,
        notice: None,
        url: Some("https://checkout.stripe.com/c/pay/test".into()),
        selected_scope_id: Some(id("team")),
        selected_machine_id: Some(id("machine")),
    });
    assert_response_round_trip(CloseMachineResult { revision: 25 });
}

#[test]
fn future_error_codes_round_trip_without_weakening_known_codes() {
    let document = json!({
        "protocol": "cmux.machine-provider",
        "version": 1,
        "id": "19",
        "error": {
            "code": "provider_rate_limited",
            "message": "Try again later",
            "retryable": true
        }
    });
    let decoded: ResponseEnvelope<SnapshotResult> =
        serde_json::from_value(document.clone()).unwrap();
    assert_eq!(
        decoded.response,
        ProviderResponse::Failure(ProviderError {
            code: ProviderErrorCode::Other("provider_rate_limited".into()),
            message: "Try again later".into(),
            retryable: true,
        })
    );
    assert_eq!(serde_json::to_value(decoded).unwrap(), document);
}

#[test]
fn envelopes_allow_future_metadata_but_params_and_results_stay_strict() {
    let request = json!({
        "protocol": "cmux.machine-provider",
        "version": 1,
        "id": "17",
        "method": "snapshot",
        "params": {},
        "trace_id": "future-metadata"
    });
    assert!(serde_json::from_value::<RequestEnvelope>(request).is_ok());

    let unknown_param = json!({
        "protocol": "cmux.machine-provider",
        "version": 1,
        "id": "17",
        "method": "snapshot",
        "params": { "surprise": true }
    });
    assert!(serde_json::from_value::<RequestEnvelope>(unknown_param).is_err());

    let unknown_result = json!({
        "protocol": "cmux.machine-provider",
        "version": 1,
        "id": "17",
        "result": {
            "connection_id": "connection-uuid",
            "transport": {
                "kind": "provider_stream",
                "ticket": "ticket",
                "expires_at": "soon"
            },
            "surprise": true
        }
    });
    assert!(serde_json::from_value::<ResponseEnvelope<OpenMachineResult>>(unknown_result).is_err());
}

#[test]
fn rejects_wrong_protocol_versions_invalid_ids_and_ambiguous_responses() {
    let base = json!({
        "protocol": "cmux.machine-provider",
        "version": 1,
        "id": "17",
        "method": "snapshot",
        "params": {}
    });

    let mut wrong_protocol = base.clone();
    wrong_protocol["protocol"] = Value::String("other.protocol".into());
    assert!(serde_json::from_value::<RequestEnvelope>(wrong_protocol).is_err());

    let mut wrong_version = base.clone();
    wrong_version["version"] = json!(2);
    assert!(serde_json::from_value::<RequestEnvelope>(wrong_version).is_err());

    let mut numeric_id = base.clone();
    numeric_id["id"] = json!(17);
    assert!(serde_json::from_value::<RequestEnvelope>(numeric_id).is_err());

    let mut empty_id = base;
    empty_id["id"] = Value::String(String::new());
    assert!(serde_json::from_value::<RequestEnvelope>(empty_id).is_err());

    let both = json!({
        "protocol": "cmux.machine-provider",
        "version": 1,
        "id": "17",
        "result": { "revision": 1 },
        "error": {
            "code": "internal",
            "message": "broken",
            "retryable": false
        }
    });
    assert!(serde_json::from_value::<ResponseEnvelope<CloseMachineResult>>(both).is_err());

    let neither = json!({
        "protocol": "cmux.machine-provider",
        "version": 1,
        "id": "17"
    });
    assert!(serde_json::from_value::<ResponseEnvelope<CloseMachineResult>>(neither).is_err());
}

#[test]
fn transport_handshake_is_strict_and_redacts_credentials_in_debug_output() {
    let handshake = TransportHandshake {
        protocol: Protocol,
        version: Version,
        role: TransportRole::Transport,
        token: token("provider-token"),
        ticket: token("transport-ticket"),
    };
    assert_eq!(
        serde_json::to_value(&handshake).unwrap(),
        json!({
            "protocol": "cmux.machine-provider",
            "version": 1,
            "role": "transport",
            "token": "provider-token",
            "ticket": "transport-ticket"
        })
    );
    assert!(!format!("{handshake:?}").contains("provider-token"));
    assert!(!format!("{handshake:?}").contains("transport-ticket"));

    let invalid = json!({
        "protocol": "cmux.machine-provider",
        "version": 1,
        "role": "transport",
        "token": "provider-token",
        "ticket": "transport-ticket",
        "ignored": true
    });
    assert!(serde_json::from_value::<TransportHandshake>(invalid).is_err());
}

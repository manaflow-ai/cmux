use cmux_tui_machine_protocol::{
    MachineDescriptor, MachinePlatform, MachineStatus, OpaqueId, ProviderCapabilities,
    SnapshotResult, WorkspaceCreatePolicy,
};
use serde::Deserialize;

// Frozen provider-v1 descriptor from the target base, before metadata was added.
// The external decoder's unknown-field rule is the compatibility oracle.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct LegacyMachine {
    id: OpaqueId,
    display_name: String,
    #[serde(default)]
    subtitle: String,
    status: MachineStatus,
    connectable: bool,
    workspace_create: WorkspaceCreatePolicy,
}

fn snapshot() -> SnapshotResult {
    SnapshotResult {
        revision: 1,
        scopes: Vec::new(),
        selected_scope_id: OpaqueId::new("personal").unwrap(),
        machines: vec![MachineDescriptor {
            id: OpaqueId::new("server-1").unwrap(),
            display_name: "Server".into(),
            subtitle: "existing route".into(),
            status: MachineStatus::Running,
            connectable: true,
            workspace_create: WorkspaceCreatePolicy::Session,
            platform: Some(MachinePlatform {
                os: Some("linux".into()),
                arch: Some("aarch64".into()),
            }),
            capabilities: vec!["terminal".into(), "agent_session".into()],
        }],
        selected_machine_id: None,
        capabilities: ProviderCapabilities {
            create_machine: false,
            connect_external_machine: false,
        },
        actions: Vec::new(),
        notice: None,
    }
}

#[test]
fn cmux_next_machine_metadata_preserves_the_strict_legacy_wire_contract() {
    let mut snapshot = snapshot();
    snapshot.retain_actions_for_client_capabilities(&[]);
    let wire = serde_json::to_value(&snapshot.machines[0]).unwrap();
    let legacy = serde_json::from_value::<LegacyMachine>(wire);
    assert!(
        legacy.is_ok(),
        "a pre-negotiation snapshot must decode in a strict v1 client: {legacy:?}"
    );
    let legacy = legacy.unwrap();
    assert_eq!(legacy.id.as_str(), "server-1");
    assert_eq!(legacy.display_name, "Server");
    assert_eq!(legacy.subtitle, "existing route");
    assert_eq!(legacy.status, MachineStatus::Running);
    assert!(legacy.connectable);
    assert_eq!(legacy.workspace_create, WorkspaceCreatePolicy::Session);
}

#[test]
fn cmux_next_machine_metadata_is_not_enabled_by_other_client_capabilities() {
    let mut snapshot = snapshot();
    snapshot.retain_actions_for_client_capabilities(&[
        "provider-action-targets-v1".into(),
        "connection-progress-v1".into(),
    ]);
    let wire = serde_json::to_value(&snapshot.machines[0]).unwrap();
    assert!(wire.get("platform").is_none());
    assert!(wire.get("capabilities").is_none());
    assert!(serde_json::from_value::<LegacyMachine>(wire).is_ok());
}

#[test]
fn cmux_next_machine_metadata_survives_an_explicit_client_opt_in() {
    let mut snapshot = snapshot();
    let expected = snapshot.machines[0].clone();
    snapshot.retain_actions_for_client_capabilities(&["machine-metadata-v1".into()]);
    let wire = serde_json::to_value(&snapshot.machines[0]).unwrap();
    assert!(serde_json::from_value::<LegacyMachine>(wire.clone()).is_err());
    assert_eq!(serde_json::from_value::<MachineDescriptor>(wire).unwrap(), expected);
}

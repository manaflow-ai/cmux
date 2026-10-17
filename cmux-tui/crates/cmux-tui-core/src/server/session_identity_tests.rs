//! Wire tests for session identity (`session-identity-v1`,
//! plans/cmux-next/data-model.md section 2).

use super::*;

fn run(mux: &Arc<Mux>, request: Value) -> anyhow::Result<Value> {
    let writer = MessageWriter::new(QueuedSink {
        outbound: Arc::new(BoundedOutbound::default()),
        control: None,
    });
    let command: Command = serde_json::from_value(request)?;
    handle_command(mux, mux.local_test_client(0), command, &writer)
}

fn identity_mux() -> Arc<Mux> {
    Mux::new_for_test("session-identity", crate::SurfaceOptions::default())
}

#[test]
fn identify_reports_session_identity() {
    let mux = identity_mux();
    let identity = run(&mux, json!({"cmd":"identify"})).unwrap();
    let capabilities = identity["capabilities"].as_array().unwrap();
    assert!(capabilities.iter().any(|value| value == "session-identity-v1"));
    assert_eq!(identity["session_id"], identity["registry_id"]);
    let machine = identity["machine_name"].as_str().unwrap();
    assert!(!machine.is_empty() && machine.len() <= 255);
    assert!(!machine.chars().any(char::is_control));
}

fn listed_machine(mux: &Arc<Mux>) -> Value {
    mux.resource_machine_service()
        .dispatch(&crate::resource_api::ResourceMachineRequest {
            operation: ResourceOperation::MachineList,
            selectors: crate::ResourceSelectors::default(),
            fields: serde_json::Map::new(),
            idempotency_key: None,
            actor: crate::Actor::local_user(),
        })
        .unwrap()[0]
        .clone()
}

#[test]
fn cmux_next_machine_owner_identity_matches_the_public_machine_catalog() {
    let mux = identity_mux();
    let listed = listed_machine(&mux);
    let identity = run(&mux, json!({"cmd":"identify"})).unwrap();
    assert!(listed["id"].is_string());
    assert_eq!(identity["machine_id"], listed["id"]);
    assert_ne!(identity["machine_id"], identity["registry_id"]);
    let another = Mux::new_for_test("another-machine-owner", crate::SurfaceOptions::default());
    assert_ne!(listed["id"], listed_machine(&another)["id"]);
}

#[test]
fn cmux_next_machine_owner_identity_survives_a_persistent_daemon_reopen() {
    let root = std::env::temp_dir()
        .join(format!("cmux-machine-identity-{}", crate::workspace_registry::new_uuid_v4()));
    let first = {
        let mux = Mux::open_persistent("owner", crate::SurfaceOptions::default(), &root).unwrap();
        run(&mux, json!({"cmd":"identify"})).unwrap()
    };
    let (second, listed) = {
        let mux = Mux::open_persistent("owner", crate::SurfaceOptions::default(), &root).unwrap();
        (run(&mux, json!({"cmd":"identify"})).unwrap(), listed_machine(&mux))
    };
    // Clean before the assertions so the deliberately red revision leaves no fixture behind.
    std::fs::remove_dir_all(root).unwrap();
    assert_eq!(first["machine_id"], listed["id"]);
    assert_eq!(second["machine_id"], listed["id"]);
    assert_eq!(first["registry_id"], second["registry_id"]);
    assert_ne!(first["generation"], second["generation"]);
}

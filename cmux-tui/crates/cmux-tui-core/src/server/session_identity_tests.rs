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

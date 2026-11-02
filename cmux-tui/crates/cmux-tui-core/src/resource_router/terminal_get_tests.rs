//! `terminal.get` reads that terminal's own rows, never a snapshot of the
//! whole session. The bundled screen detector reads one terminal per output
//! burst; a session-wide snapshot per read (every workspace, screen and tab,
//! each decorated from SQLite, under the projection lock) made every command
//! of a large session wait behind it, so a classic migration of 512
//! workspaces slowed with each workspace it made (O(n²)).

use serde_json::{Value, json};

use super::*;
use crate::SurfaceOptions;
use crate::workspace_registry::WorkspaceRegistry;

fn envelope(operation: &str, fields: Value, key: Option<&str>) -> String {
    let mut params = json!({"machine":"current","session":"current"});
    params.as_object_mut().unwrap().extend(fields.as_object().unwrap().clone());
    let mut envelope = json!({
        "protocol":"cmux.protocol/2",
        "type":"request",
        "id":format!("terminal-get-{operation}"),
        "operation":operation,
        "params":params,
    });
    if let Some(key) = key {
        envelope["idempotency_key"] = json!(key);
    }
    serde_json::to_string(&envelope).unwrap()
}

fn call(mux: &Arc<Mux>, operation: &str, fields: Value, key: Option<&str>) -> Value {
    let response = handle_resource_message(mux, &envelope(operation, fields, key))
        .unwrap_or_else(|error| panic!("{operation}: {error:?}"));
    assert_eq!(response["ok"], true, "{operation} failed: {response}");
    response["result"].clone()
}

/// The fields of a terminal value that hold still between two reads (no
/// activity clocks).
fn stable(terminal: &Value) -> Value {
    json!({
        "id": terminal["id"],
        "tab_id": terminal["tab_id"],
        "tab_ids": terminal["tab_ids"],
        "cols": terminal["cols"],
        "rows": terminal["rows"],
        "running": terminal["running"],
        "lifecycle": terminal["lifecycle"],
    })
}

#[test]
fn terminal_get_reads_no_full_topology_and_matches_the_snapshot() {
    let mux = Mux::new_for_test("terminal-get", SurfaceOptions::default());
    let mut terminals = Vec::new();
    for index in 0..4 {
        let key = format!("terminal-get-{index}");
        let created = call(
            &mux,
            "workspace.create",
            json!({"initial_content":"terminal","name":key}),
            Some(&key),
        );
        terminals.push(created["value"]["terminal_id"].as_str().unwrap().to_string());
    }
    let snapshot = call(&mux, "session.snapshot", json!({}), None);

    let reads = WorkspaceRegistry::full_topology_reads_for_test();
    let got = terminals
        .iter()
        .map(|terminal| call(&mux, "terminal.get", json!({"terminal":terminal}), None))
        .collect::<Vec<_>>();
    assert_eq!(
        WorkspaceRegistry::full_topology_reads_for_test(),
        reads,
        "terminal.get read the whole session topology"
    );

    for (terminal, value) in terminals.iter().zip(&got) {
        let listed = snapshot["terminals"]
            .as_array()
            .unwrap()
            .iter()
            .find(|listed| listed["id"] == terminal.as_str())
            .unwrap_or_else(|| panic!("{terminal} is not in the session snapshot"));
        assert_eq!(stable(value), stable(listed), "terminal.get differs from the snapshot");
    }
    mux.shutdown();
}

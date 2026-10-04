//! A workspace create that fails leaves no half-created workspace: the
//! workspace and its first terminal become visible together, or the
//! workspace is rolled back (live report: "new workspace: create-terminal
//! failed: …" left an empty workspace in the sidebar).

use serde_json::{Value, json};

use super::*;
use crate::SurfaceOptions;
use crate::resource_api::public_session_snapshot;

fn parsed_request(operation: &str, fields: Value, idempotency_key: &str) -> ParsedResourceRequest {
    let mut params = json!({"machine":"current","session":"current"});
    params.as_object_mut().unwrap().extend(fields.as_object().unwrap().clone());
    let envelope = json!({
        "protocol":"cmux.protocol/2",
        "type":"request",
        "id":format!("test-{operation}"),
        "operation":operation,
        "params":params,
        "idempotency_key":idempotency_key,
    });
    parse_resource_request(&serde_json::to_string(&envelope).unwrap()).unwrap()
}

#[test]
fn a_create_whose_commit_fails_leaves_no_workspace_or_terminal() {
    let mux = Mux::new_for_test("partial-create", SurfaceOptions::default());
    let workspaces = |mux: &Mux| mux.with_state(|state| state.workspaces.len());
    let terminals = |mux: &Mux| mux.with_state(|state| state.terminal_catalog.len());
    let public = |mux: &Mux| {
        public_session_snapshot(mux).unwrap()["workspaces"].as_array().unwrap().len()
    };
    let (before_workspaces, before_terminals, before_public) =
        (workspaces(&mux), terminals(&mux), public(&mux));
    // Both projection attempts of the create fail, after the workspace row
    // and the terminal were committed.
    mux.set_resource_patch_failures_remaining_for_test(2);
    let created = topology::dispatch(
        &mux,
        parsed_request(
            "workspace.create",
            json!({"initial_content":"terminal","name":"partial"}),
            "partial-create",
        ),
    );
    assert!(created.is_err(), "a create whose commit failed reported success: {created:?}");
    assert_eq!(workspaces(&mux), before_workspaces, "a half-created workspace stayed in memory");
    assert_eq!(terminals(&mux), before_terminals, "the failed create left its terminal running");
    assert_eq!(public(&mux), before_public);
    mux.shutdown();
}

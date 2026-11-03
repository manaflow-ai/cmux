//! A `workspace.create` names the workspace it made by its request's
//! idempotency key on the workspace-added event (`mutation_id`), with a
//! terminal or empty. The app files a CLI create into the window it came
//! from by that key (#32989); a terminal create's workspace got a fresh
//! random id, so it always opened in the most recent window instead.

use serde_json::{Value, json};

use super::*;
use crate::SurfaceOptions;
use crate::workspace_registry::WORKSPACE_RESERVATION_SUFFIX;

fn create(mux: &Arc<Mux>, fields: Value, key: &str) {
    let mut params = json!({"machine":"current","session":"current"});
    params.as_object_mut().unwrap().extend(fields.as_object().unwrap().clone());
    let envelope = json!({
        "protocol":"cmux.protocol/2",
        "type":"request",
        "id":format!("create-{key}"),
        "operation":"workspace.create",
        "params":params,
        "idempotency_key":key,
    });
    let response = handle_resource_message(mux, &serde_json::to_string(&envelope).unwrap())
        .unwrap_or_else(|error| panic!("workspace.create: {error:?}"));
    assert_eq!(response["ok"], true, "workspace.create failed: {response}");
}

/// The `mutation_id`s of the workspace registry's `resource-api` events.
fn resource_mutation_ids(mux: &Arc<Mux>) -> Vec<String> {
    (1..=500)
        .filter_map(|revision| mux.workspace_registry_event(revision).unwrap())
        .filter(|event| event.origin == "resource-api")
        .map(|event| event.mutation_id)
        .collect()
}

#[test]
fn a_terminal_create_names_its_key_on_the_workspace_it_made() {
    let mux = Mux::new_for_test("create-mutation-terminal", SurfaceOptions::default());
    create(&mux, json!({"initial_content":"terminal","name":"chief"}), "chief-create");
    let ids = resource_mutation_ids(&mux);
    let expected = format!("chief-create{WORKSPACE_RESERVATION_SUFFIX}");
    assert!(ids.contains(&expected), "no workspace event names {expected}: {ids:?}");
}

#[test]
fn an_empty_create_names_its_key_itself() {
    let mux = Mux::new_for_test("create-mutation-empty", SurfaceOptions::default());
    create(&mux, json!({"initial_content":"empty","name":"chief"}), "chief-empty");
    let ids = resource_mutation_ids(&mux);
    assert!(ids.contains(&"chief-empty".to_owned()), "{ids:?}");
}

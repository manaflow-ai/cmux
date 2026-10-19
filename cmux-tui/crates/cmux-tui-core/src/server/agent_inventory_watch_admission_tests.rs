//! Refusal receipts distinguish an absent lease from an existing pending admission.
use super::super::agent_session_attach_tests::{Client, assert_code};
use super::super::*;
use super::Owner;
use serde_json::{Value, json};

fn snapshot() -> Value {
    json!({"view":"inventory","cached":true,"harnesses":[],"revision":1})
}

fn request(mux: &Mux) -> Value {
    json!({"cmd":"agent-inventory-watch","expected_machine_id":mux.machine_public_id,
        "enabled":true,"admission_receipt":true})
}

fn absent(reply: &Value, mux: &Mux, code: &str) {
    assert_code(reply, code);
    assert_eq!(reply["data"], json!({"machine":mux.machine_public_id,"admission":"not_admitted"}));
}

#[test]
fn cmux_next_inventory_admission_missing_socket_can_retry_without_reconnecting() {
    let owner = Owner::new(json!(["harnessInventoryWatch"]), snapshot());
    let mux = owner.mux("inventory-admission-absent");
    let mut client = Client::connect(&mux, "inventory-admission-absent");
    mux.set_acpmux_socket(None);
    absent(&client.request(request(&mux)), &mux, "agent_inventory.unavailable");
    mux.set_acpmux_socket(Some(owner.socket.clone()));
    let accepted = client.request(request(&mux));
    assert_eq!(accepted["ok"], true, "{accepted}");
    assert_eq!(accepted["data"]["revision"], 1);
}

#[test]
fn cmux_next_inventory_admission_capacity_busy_proves_absence() {
    let owner = Owner::new(json!(["harnessInventoryWatch"]), snapshot());
    let mux = owner.mux("inventory-admission-capacity");
    let mut client = Client::connect(&mux, "inventory-admission-capacity");
    let reads: Vec<_> = (0..8).map(|_| agent_inventory::reserve(&mux).unwrap()).collect();
    absent(&client.request(request(&mux)), &mux, "agent_inventory.busy");
    assert!(owner.methods().is_empty());
    drop(reads);
    assert_eq!(client.request(request(&mux))["ok"], true);
}

#[test]
fn cmux_next_inventory_admission_existing_pending_busy_has_no_absence_proof() {
    let owner = Owner::paused(json!(["harnessInventoryWatch"]), snapshot());
    let mux = owner.mux("inventory-admission-pending");
    let mut client = Client::connect(&mux, "inventory-admission-pending");
    let pending = client.send(request(&mux));
    owner.wait_for_watch();
    let refused = client.request(request(&mux));
    assert_code(&refused, "agent_inventory.busy");
    assert!(refused.get("data").is_none_or(Value::is_null), "{refused}");
    owner.release_watch();
    assert_eq!(client.answer(pending)["ok"], true);
}

#[test]
fn cmux_next_inventory_admission_worker_refusal_proves_cleanup() {
    let owner = Owner::new(json!([]), snapshot());
    let mux = owner.mux("inventory-admission-unsupported");
    let mut client = Client::connect(&mux, "inventory-admission-unsupported");
    absent(&client.request(request(&mux)), &mux, "agent_inventory.unsupported");
    owner.wait_closed();
    assert_eq!(owner.methods(), ["initialize"]);
}

#[test]
fn cmux_next_inventory_admission_legacy_and_bad_optin_keep_refusal_shape() {
    let owner = Owner::new(json!(["harnessInventoryWatch"]), snapshot());
    let mux = owner.mux("inventory-admission-legacy");
    let mut client = Client::connect(&mux, "inventory-admission-legacy");
    mux.set_acpmux_socket(None);
    let mut legacy = request(&mux);
    legacy.as_object_mut().unwrap().remove("admission_receipt");
    let refused = client.request(legacy);
    assert_code(&refused, "agent_inventory.unavailable");
    assert!(refused.get("data").is_none_or(Value::is_null));
    for value in [json!("true"), json!(1), Value::Null] {
        let mut malformed = request(&mux);
        malformed["admission_receipt"] = value;
        let refused = client.request(malformed);
        assert_code(&refused, "agent_inventory.bad_request");
        assert!(refused.get("data").is_none_or(Value::is_null));
    }
    let mut disable = request(&mux);
    disable["enabled"] = json!(false);
    assert_code(&client.request(disable), "agent_inventory.bad_request");
    assert!(owner.methods().is_empty());
}

#[test]
fn cmux_next_inventory_admission_capability_is_independent() {
    let owner = Owner::new(json!(["harnessInventoryWatch"]), snapshot());
    let mux = owner.mux("inventory-admission-capability");
    let mut client = Client::connect(&mux, "inventory-admission-capability");
    let identity = client.request(json!({"cmd":"identify"}));
    assert!(
        identity["data"]["capabilities"]
            .as_array()
            .unwrap()
            .contains(&json!("agent-inventory-watch-admission-v1"))
    );
    assert!(owner.methods().is_empty());
}

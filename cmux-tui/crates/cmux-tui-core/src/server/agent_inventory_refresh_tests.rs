//! Registry refresh uses the captured machine and the separately negotiated
//! raw operation. It cannot become a legacy health call or start an owner.

use super::*;
use std::sync::atomic::AtomicUsize;

const COMMAND: &str = "agent-inventory-refresh";
const FEATURE: &str = "agent-inventory-refresh-v1";

fn refreshed() -> Value {
    let mut value = snapshot();
    let row = &mut value["harnesses"][0];
    row["channel"] = json!("native");
    row["family"] = json!("claude");
    row["version"] = json!("2.0.5");
    row["latest"] = json!("2.0.9");
    row["latestCheckedAt"] = json!(456);
    row["outdated"] = json!(true);
    value
}

fn identity(client: &mut Client) -> Value {
    client.request(json!({"cmd":"identify","machine_metadata":true}))["data"]["machine_id"].clone()
}

#[test]
fn cmux_next_agent_inventory_refresh_uses_the_captured_owner_and_fixed_registry_method() {
    let owner = Owner::new(json!(["harnessInventoryRefresh"]), refreshed());
    let mux = owner.mux("inventory-refresh-native");
    let mut client = Client::connect(&mux, "inventory-refresh-native");
    let machine = identity(&mut client);
    let reply = client.request(json!({"cmd":COMMAND,"expected_machine_id":machine}));
    assert_eq!(reply["ok"], true, "{reply}");
    assert_eq!(reply["data"]["machine"], machine, "{reply}");
    assert_eq!(reply["data"]["harnesses"][0]["version"], "2.0.5");
    assert_eq!(reply["data"]["harnesses"][0]["latest"], "2.0.9");
    assert_eq!(reply["data"]["harnesses"][0]["checkedAt"], 123);
    assert!(!reply.to_string().contains("private"), "diagnostics escaped: {reply}");
    let frames: Vec<_> = owner.frames.try_iter().collect();
    assert_eq!(frames.len(), 2, "{frames:?}");
    assert_eq!(frames[0]["method"], "initialize");
    assert_eq!(frames[1]["method"], "_acpmux/harness/inventory/refresh");
    assert_eq!(frames[1]["params"], json!({}), "no caller fields may reach acpmux");
}

#[test]
fn cmux_next_agent_inventory_refresh_old_or_malformed_capabilities_never_fall_back() {
    for features in [
        Value::Null,
        json!([]),
        json!(["harnessInventory"]),
        json!(["harnessInventoryRefreshExtra"]),
        json!(["harnessInventoryRefresh", 42]),
    ] {
        let owner = Owner::new(features, refreshed());
        let mux = owner.mux("inventory-refresh-legacy");
        let mut client = Client::connect(&mux, "inventory-refresh-legacy");
        let machine = identity(&mut client);
        assert_code(
            &client.request(json!({"cmd":COMMAND,"expected_machine_id":machine})),
            "agent_inventory.unsupported",
        );
        assert_eq!(owner.methods(), vec!["initialize"]);
    }
}

#[test]
fn cmux_next_agent_inventory_refresh_requires_a_canonical_condition_and_no_controls() {
    let owner = Owner::new(json!(["harnessInventoryRefresh"]), refreshed());
    let mux = owner.mux("inventory-refresh-params");
    let mut client = Client::connect(&mux, "inventory-refresh-params");
    let machine = identity(&mut client);
    assert_code(&client.request(json!({"cmd":COMMAND})), "agent_inventory.bad_request");
    for expected in [Value::Null, json!(false), json!(42), json!(""), json!("current")] {
        assert_code(
            &client.request(json!({"cmd":COMMAND,"expected_machine_id":expected})),
            "agent_inventory.bad_request",
        );
    }
    for params in [
        json!({"view":"inventory"}),
        json!({"socket":"/tmp/foreign.sock"}),
        json!({"checkLatest":true}),
        json!({"autoUpdate":{"id":"claude","on":true}}),
        json!({"command":"echo should-not-run"}),
    ] {
        let mut request = params;
        request["cmd"] = json!(COMMAND);
        request["expected_machine_id"] = machine.clone();
        assert_code(&client.request(request), "agent_inventory.bad_request");
    }
    assert!(owner.methods().is_empty());
}

#[test]
fn cmux_next_agent_inventory_refresh_foreign_owner_precedes_socket_and_capacity() {
    let owner = Owner::new(json!(["harnessInventoryRefresh"]), refreshed());
    let mux = owner.mux("inventory-refresh-replacement");
    let previous = Mux::new_for_test("previous-owner", crate::SurfaceOptions::default());
    let machine =
        run(&previous, json!({"cmd":"identify","machine_metadata":true}))["machine_id"].clone();
    let mut client = Client::connect(&mux, "inventory-refresh-replacement");
    mux.control_clients.agent_sessions.inventory_reads.store(8, Ordering::Release);
    for available in [true, false] {
        if !available {
            mux.set_acpmux_socket(None);
        }
        let reply = client.request(json!({"cmd":COMMAND,"expected_machine_id":machine}));
        assert_code(&reply, "agent_inventory.owner_mismatch");
        assert!(reply.get("data").is_none_or(Value::is_null));
        assert!(!reply.to_string().contains(mux.machine_public_id.as_str()));
    }
    mux.control_clients.agent_sessions.inventory_reads.store(0, Ordering::Release);
    assert!(owner.methods().is_empty());
}

#[test]
fn cmux_next_agent_inventory_refresh_never_starts_an_unavailable_owner() {
    let mux = Mux::new_for_test("inventory-refresh-missing", crate::SurfaceOptions::default());
    let starts = Arc::new(AtomicUsize::new(0));
    let counted = starts.clone();
    mux.set_acpmux_starter(Some(Arc::new(move || {
        counted.fetch_add(1, Ordering::SeqCst);
        Err("refresh must not start acpmux".into())
    })));
    let mut client = Client::connect(&mux, "inventory-refresh-missing");
    let machine = identity(&mut client);
    assert_code(
        &client.request(json!({"cmd":COMMAND,"expected_machine_id":machine})),
        "agent_inventory.unavailable",
    );
    assert_eq!(starts.load(Ordering::SeqCst), 0);
}

#[test]
fn cmux_next_agent_inventory_refresh_uses_the_shared_read_budget() {
    let owner = Owner::new(json!(["harnessInventoryRefresh"]), refreshed());
    let mux = owner.mux("inventory-refresh-budget");
    let mut client = Client::connect(&mux, "inventory-refresh-budget");
    let machine = identity(&mut client);
    mux.control_clients.agent_sessions.inventory_reads.store(8, Ordering::Release);
    assert_code(
        &client.request(json!({"cmd":COMMAND,"expected_machine_id":machine})),
        "agent_inventory.busy",
    );
    mux.control_clients.agent_sessions.inventory_reads.store(0, Ordering::Release);
    assert!(owner.methods().is_empty());
}

#[test]
fn cmux_next_agent_inventory_refresh_capability_tracks_the_configured_carrier() {
    let owner = Owner::new(json!(["harnessInventoryRefresh"]), refreshed());
    let mux = owner.mux("inventory-refresh-capability");
    assert!(
        run(&mux, json!({"cmd":"identify"}))["capabilities"]
            .as_array()
            .unwrap()
            .contains(&json!(FEATURE))
    );
    mux.set_acpmux_socket(None);
    assert!(
        !run(&mux, json!({"cmd":"identify"}))["capabilities"]
            .as_array()
            .unwrap()
            .contains(&json!(FEATURE))
    );
    assert!(owner.methods().is_empty());
}

#[test]
fn cmux_next_agent_inventory_refresh_keeps_legacy_reads_cache_only() {
    let owner = Owner::new(json!(["harnessInventory"]), refreshed());
    let mux = owner.mux("inventory-refresh-cache-control");
    let mut client = Client::connect(&mux, "inventory-refresh-cache-control");
    let reply = client.request(json!({"cmd":"agent-inventory"}));
    assert_eq!(reply["ok"], true, "{reply}");
    assert!(reply["data"].get("machine").is_none());
    let frames: Vec<_> = owner.frames.try_iter().collect();
    assert_eq!(frames.len(), 2);
    assert_eq!(frames[1]["method"], "_acpmux/harness/health");
    assert_eq!(frames[1]["params"], json!({"view":"inventory"}));
}

#[test]
fn cmux_next_agent_inventory_refresh_trust_and_relay_denial_precede_params() {
    let owner = Owner::new(json!(["harnessInventoryRefresh"]), refreshed());
    let mux = owner.mux("inventory-refresh-trust");
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    for (transport, code) in [
        (ClientTransport::WebSocket, "agent_inventory.not_trusted"),
        (ClientTransport::Remote, "remote_denied"),
    ] {
        let client = mux.control_clients.register(transport, writer.clone());
        let request = json!({"id":1,"cmd":COMMAND,"expected_machine_id":null,"command":"no"});
        assert!(handle_connection_frame(
            &mux,
            client,
            transport,
            &request.to_string(),
            &writer,
            &scheduler
        ));
        let reply: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_code(&reply, code);
    }
    assert!(owner.methods().is_empty());
}

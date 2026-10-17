//! Native owner and connection fences of the cache-only watch carrier.
use super::agent_inventory_tests::Owner;
use super::agent_session_attach_tests::{Client, WAIT, assert_code};
use super::*;
use serde_json::{Value, json};

fn snapshot(revision: u64) -> Value {
    json!({"view":"inventory","cached":true,"harnesses":[],"revision":revision,
        "diagnostics":"private@example.test secret-token"})
}

fn request(mux: &Mux, enabled: bool) -> Value {
    json!({"cmd":"agent-inventory-watch","expected_machine_id":mux.machine_public_id,"enabled":enabled})
}

#[test]
fn cmux_next_inventory_native_watch_negotiates_and_emits_only_owner_invalidations() {
    let mut owner = Owner::new(json!(["harnessInventoryWatch"]), snapshot(4));
    let mux = owner.mux("inventory-watch");
    let mut client = Client::connect(&mux, "inventory-watch");
    let ack = client.request(request(&mux, true));
    assert_eq!(ack["ok"], true, "{ack}");
    assert_eq!(ack["data"]["machine"], json!(mux.machine_public_id));
    assert_eq!(ack["data"]["revision"], 4);
    assert!(ack["data"]["watch_id"].as_str().is_some_and(|v| !v.is_empty()));
    owner.notify(snapshot(5));
    let event = client.named_event("agent-inventory-changed", WAIT).expect("cache invalidation");
    assert_eq!(
        event,
        json!({"event":"agent-inventory-changed","machine":mux.machine_public_id,
        "watch_id":ack["data"]["watch_id"],"revision":5})
    );
    assert_eq!(owner.methods(), ["initialize", "_acpmux/harness/inventory/watch"]);
}

#[test]
fn cmux_next_inventory_native_watch_rejects_wrong_owner_and_controls_before_connecting() {
    let owner = Owner::new(json!(["harnessInventoryWatch"]), snapshot(1));
    let mux = owner.mux("inventory-watch-fence");
    let mut client = Client::connect(&mux, "inventory-watch-fence");
    let mut wrong = request(&mux, true);
    wrong["expected_machine_id"] = json!("machine_00000000000000000000000000000000");
    assert_code(&client.request(wrong), "agent_inventory.owner_mismatch");
    for field in ["command", "machine", "socket", "session", "refresh", "rescan", "checkLatest"] {
        let mut bad = request(&mux, true);
        bad[field] = json!(true);
        assert_code(&client.request(bad), "agent_inventory.bad_request");
    }
    let mut bad = request(&mux, true);
    bad["enabled"] = json!("true");
    assert_code(&client.request(bad), "agent_inventory.bad_request");
    assert!(owner.methods().is_empty());
}

#[test]
fn cmux_next_inventory_native_watch_never_falls_back_on_legacy_or_malformed_features() {
    for features in [json!([]), json!(["harnessInventory"]), json!(["harnessInventoryWatch", 1])] {
        let owner = Owner::new(features, snapshot(1));
        let mux = owner.mux("inventory-watch-legacy");
        let mut client = Client::connect(&mux, "inventory-watch-legacy");
        assert_code(&client.request(request(&mux, true)), "agent_inventory.unsupported");
        assert_eq!(owner.methods(), ["initialize"]);
    }
}

#[test]
fn cmux_next_inventory_native_watch_is_idempotent_and_disable_retires_the_lease() {
    let owner = Owner::new(json!(["harnessInventoryWatch"]), snapshot(3));
    let mux = owner.mux("inventory-watch-stop");
    let mut client = Client::connect(&mux, "inventory-watch-stop");
    let first = client.request(request(&mux, true));
    assert_eq!(first["ok"], true, "{first}");
    assert_eq!(client.request(request(&mux, true))["data"], first["data"]);
    assert_eq!(client.request(request(&mux, false))["data"], json!({}));
    assert_eq!(client.request(request(&mux, false))["data"], json!({}));
    assert!(client.named_event("agent-inventory-changed", Duration::from_millis(100)).is_none());
    assert_eq!(owner.methods(), ["initialize", "_acpmux/harness/inventory/watch"]);
}

#[test]
fn cmux_next_inventory_native_watch_ignores_replays_and_retires_on_socket_replacement() {
    let mut owner = Owner::new(json!(["harnessInventoryWatch"]), snapshot(3));
    let mux = owner.mux("inventory-watch-replace");
    let mut client = Client::connect(&mux, "inventory-watch-replace");
    let ack = client.request(request(&mux, true));
    assert_eq!(ack["ok"], true, "{ack}");
    owner.notify(snapshot(3));
    owner.notify(snapshot(2));
    assert!(client.named_event("agent-inventory-changed", Duration::from_millis(100)).is_none());
    mux.set_acpmux_socket(None);
    let end = client.named_event("agent-inventory-watch-ended", WAIT).expect("retired watch");
    assert_eq!(end["watch_id"], ack["data"]["watch_id"]);
    assert_eq!(end["machine"], json!(mux.machine_public_id));
    assert!(client.named_event("agent-inventory-changed", Duration::from_millis(100)).is_none());
}

#[test]
fn cmux_next_inventory_native_watch_disallows_websocket_and_remote_carriers() {
    let owner = Owner::new(json!(["harnessInventoryWatch"]), snapshot(1));
    let mux = owner.mux("inventory-watch-policy");
    let (writer, outbound) = MessageWriter::queued();
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    for (transport, code) in [
        (ClientTransport::WebSocket, "agent_inventory.not_trusted"),
        (ClientTransport::Remote, "remote_denied"),
    ] {
        let client = mux.control_clients.register(transport, writer.clone());
        assert!(handle_connection_frame(
            &mux,
            client,
            transport,
            &request(&mux, true).to_string(),
            &writer,
            &scheduler
        ));
        let reply: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_code(&reply, code);
    }
    assert!(owner.methods().is_empty());
}

#[test]
fn cmux_next_inventory_native_watch_advertises_its_independent_capability() {
    let owner = Owner::new(json!(["harnessInventoryWatch"]), snapshot(1));
    let mux = owner.mux("inventory-watch-capability");
    let mut client = Client::connect(&mux, "inventory-watch-capability");
    let identity = client.request(json!({"cmd":"identify"}));
    assert!(
        identity["data"]["capabilities"]
            .as_array()
            .unwrap()
            .contains(&json!("agent-inventory-watch-v1"))
    );
    assert!(owner.methods().is_empty());
}

#[test]
fn cmux_next_inventory_native_watch_disconnect_closes_the_owner_link() {
    let owner = Owner::new(json!(["harnessInventoryWatch"]), snapshot(1));
    let mux = owner.mux("inventory-watch-disconnect");
    let mut client = Client::connect(&mux, "inventory-watch-disconnect");
    let ack = client.request(request(&mux, true));
    assert_eq!(ack["ok"], true, "{ack}");
    drop(client);
    owner.wait_closed();
    assert!(mux.serves_agent_session_attach());
}

#[test]
fn cmux_next_inventory_native_watch_preserves_owner_fenced_cached_reads() {
    let owner = Owner::new(json!(["harnessInventory"]), snapshot(2));
    let mux = owner.mux("inventory-watch-read-control");
    let mut client = Client::connect(&mux, "inventory-watch-read-control");
    let reply = client
        .request(json!({"cmd":"agent-inventory","expected_machine_id":mux.machine_public_id}));
    assert_eq!(reply["ok"], true, "{reply}");
    assert_eq!(reply["data"], json!({"view":"inventory","cached":true,"harnesses":[]}));
    assert_eq!(owner.methods(), ["initialize", "_acpmux/harness/health"]);
}

//! Native owner and connection fences of the cache-only watch carrier.
use super::super::agent_session_attach_tests::{Client, WAIT, assert_code};
use super::super::*;
use super::Owner;
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
    // The ack and the event are the schema's AgentInventoryWatchActive and event payload.
    let ack_fields = agent_inventory::schema::type_fields("AgentInventoryWatchActive");
    assert_eq!(agent_inventory::schema::keys(&ack["data"]), ack_fields);
    let event_fields = agent_inventory::schema::event_fields("agent-inventory-changed");
    assert_eq!(agent_inventory::schema::keys(&event), event_fields);
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
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
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
    assert!(
        identity["data"]["capabilities"]
            .as_array()
            .unwrap()
            .contains(&json!("agent-inventory-watch-fence-v1"))
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

#[test]
fn cmux_next_inventory_native_watch_refuses_malformed_initial_snapshots() {
    for initial in [
        json!({"revision":1}),
        json!({"view":"inventory","cached":false,"harnesses":[],"revision":1}),
        json!({"view":"inventory","cached":true,"harnesses":[],"revision":"1"}),
    ] {
        let owner = Owner::new(json!(["harnessInventoryWatch"]), initial);
        let mux = owner.mux("inventory-watch-malformed");
        let mut client = Client::connect(&mux, "inventory-watch-malformed");
        assert_code(&client.request(request(&mux, true)), "agent_inventory.invalid_response");
        owner.wait_closed();
        assert!(
            client.named_event("agent-inventory-changed", Duration::from_millis(100)).is_none()
        );
    }
}

#[test]
fn cmux_next_inventory_native_watch_invalid_notifications_end_the_current_lease() {
    let mut owner = Owner::new(json!(["harnessInventoryWatch"]), snapshot(1));
    let mux = owner.mux("inventory-watch-invalid-event");
    let mut client = Client::connect(&mux, "inventory-watch-invalid-event");
    let ack = client.request(request(&mux, true));
    assert_eq!(ack["ok"], true, "{ack}");
    owner.notify(json!({"revision":2,"diagnostics":"private@example.test secret-token"}));
    let ended =
        client.named_event("agent-inventory-watch-ended", WAIT).expect("invalid watch ended");
    assert_eq!(
        ended,
        json!({"event":"agent-inventory-watch-ended","machine":mux.machine_public_id,
        "watch_id":ack["data"]["watch_id"],"reason":"agent_inventory.invalid_response"})
    );
    let ended_fields = agent_inventory::schema::event_fields("agent-inventory-watch-ended");
    assert_eq!(agent_inventory::schema::keys(&ended), ended_fields);
    owner.wait_closed();
    assert!(client.named_event("agent-inventory-changed", Duration::from_millis(100)).is_none());
}

#[test]
fn cmux_next_inventory_native_watch_shares_the_bounded_read_worker_budget() {
    let owner = Owner::new(json!(["harnessInventoryWatch"]), snapshot(1));
    let mux = owner.mux("inventory-watch-budget");
    let mut client = Client::connect(&mux, "inventory-watch-budget");
    let reads: Vec<_> = (0..8).map(|_| agent_inventory::reserve(&mux).unwrap()).collect();
    assert_code(&client.request(request(&mux, true)), "agent_inventory.busy");
    assert!(owner.methods().is_empty());
    drop(reads);
    assert_eq!(client.request(request(&mux, true))["ok"], true);
    drop(client);
    owner.wait_closed();
}

#[test]
fn cmux_next_inventory_native_watch_socket_replacement_cancels_a_pending_handshake() {
    let mut owner = Owner::paused(json!(["harnessInventoryWatch"]), snapshot(1));
    let mux = owner.mux("inventory-watch-pending");
    let mut client = Client::connect(&mux, "inventory-watch-pending");
    let pending = client.send(request(&mux, true));
    owner.wait_for_watch();
    mux.set_acpmux_socket(None);
    // The peer is holding its reply. Replacement must close the transport
    // now, rather than waiting for a deadline or accepting its later ACK.
    owner.assert_transport_closed();
    assert_code(&client.answer(pending), "agent_inventory.unavailable");
    owner.release_watch();
    owner.wait_closed();
    assert!(client.named_event("agent-inventory-changed", Duration::from_millis(100)).is_none());
}

#[test]
fn cmux_next_inventory_native_watch_replacement_cleanup_preserves_a_new_socket_lease() {
    let old = Owner::new(json!(["harnessInventoryWatch"]), snapshot(1));
    let mut next = Owner::new(json!(["harnessInventoryWatch"]), snapshot(1));
    let mux = old.mux("inventory-watch-replacement-race");
    let (entered, changed) = std::sync::mpsc::channel();
    let (release, resume) = std::sync::mpsc::channel();
    mux.control_clients.agent_sessions.set_inventory_socket_test_hook(Box::new(move || {
        entered.send(()).unwrap();
        resume.recv_timeout(WAIT).expect("replacement barrier was not released");
    }));
    let replacing = mux.clone();
    let next_socket = next.socket.clone();
    let replacement = std::thread::spawn(move || replacing.set_acpmux_socket(Some(next_socket)));
    changed.recv_timeout(WAIT).expect("socket was not replaced");
    let mut client = Client::connect(&mux, "inventory-watch-new-during-cleanup");
    let ack = client.request(request(&mux, true));
    // Always release/join the setter, even if an enabling assertion fails.
    release.send(()).unwrap();
    replacement.join().unwrap();
    assert_eq!(ack["ok"], true, "{ack}");
    assert!(
        client.named_event("agent-inventory-watch-ended", Duration::from_millis(100)).is_none(),
        "old replacement cleanup retired a newly admitted lease"
    );
    next.notify(snapshot(2));
    let event =
        client.named_event("agent-inventory-changed", WAIT).expect("new lease invalidation");
    assert_eq!(event["watch_id"], ack["data"]["watch_id"]);
    assert_eq!(event["revision"], 2);
}

#[test]
fn cmux_next_inventory_native_watch_stale_disable_cannot_retire_a_new_lease() {
    let old = Owner::new(json!(["harnessInventoryWatch"]), snapshot(1));
    let mut next = Owner::new(json!(["harnessInventoryWatch"]), snapshot(1));
    let mux = old.mux("inventory-watch-stale-disable");
    let mut client = Client::connect(&mux, "inventory-watch-stale-disable");
    let first = client.request(request(&mux, true));
    assert_eq!(first["ok"], true, "{first}");
    mux.set_acpmux_socket(Some(next.socket.clone()));
    client.named_event("agent-inventory-watch-ended", WAIT).expect("old lease retired");
    let current = client.request(request(&mux, true));
    assert_eq!(current["ok"], true, "{current}");
    assert_ne!(first["data"]["watch_id"], current["data"]["watch_id"]);
    let mut disable = request(&mux, false);
    disable["expected_watch_id"] = first["data"]["watch_id"].clone();
    let ignored = client.request(disable);
    assert_eq!(ignored["ok"], true, "conditional cleanup must be idempotent: {ignored}");
    assert!(
        client.named_event("agent-inventory-watch-ended", Duration::from_millis(100)).is_none()
    );
    next.notify(snapshot(2));
    let changed = client.named_event("agent-inventory-changed", WAIT).expect("current lease live");
    assert_eq!(changed["watch_id"], current["data"]["watch_id"]);
    let mut disable = request(&mux, false);
    disable["expected_watch_id"] = current["data"]["watch_id"].clone();
    assert_eq!(client.request(disable)["ok"], true);
    next.wait_closed();
}

#[test]
fn cmux_next_inventory_native_watch_disable_fence_never_selects_another_client() {
    let mut owner = Owner::new(json!(["harnessInventoryWatch"]), snapshot(1));
    let mux = owner.mux("inventory-watch-other-client-stop");
    let mut subscriber = Client::connect(&mux, "inventory-watch-subscriber");
    let ack = subscriber.request(request(&mux, true));
    assert_eq!(ack["ok"], true, "{ack}");
    let mut other = Client::connect(&mux, "inventory-watch-other-client");
    let mut disable = request(&mux, false);
    disable["expected_watch_id"] = ack["data"]["watch_id"].clone();
    assert_eq!(other.request(disable)["ok"], true);
    owner.notify(snapshot(2));
    let event =
        subscriber.named_event("agent-inventory-changed", WAIT).expect("original lease live");
    assert_eq!(event["watch_id"], ack["data"]["watch_id"]);
    assert!(other.named_event("agent-inventory-changed", Duration::from_millis(100)).is_none());
}

#[test]
fn cmux_next_inventory_native_watch_malformed_disable_fences_are_refused_before_connecting() {
    let owner = Owner::new(json!(["harnessInventoryWatch"]), snapshot(1));
    let mux = owner.mux("inventory-watch-bad-stop-fence");
    let mut client = Client::connect(&mux, "inventory-watch-bad-stop-fence");
    for value in [
        json!(true),
        json!(1),
        json!("short"),
        json!("inventory_watch_0123456789ABCDEF0123456789ABCDEF"),
    ] {
        let mut disable = request(&mux, false);
        disable["expected_watch_id"] = value;
        assert_code(&client.request(disable), "agent_inventory.bad_request");
    }
    let mut enable = request(&mux, true);
    enable["expected_watch_id"] = json!("inventory_watch_0123456789abcdef0123456789abcdef");
    assert_code(&client.request(enable), "agent_inventory.bad_request");
    assert!(owner.methods().is_empty());
}

//! Captured owner identity is a condition, never a machine selector or
//! permission to start acpmux, read health, or run an updater elsewhere.

use crate::mux::Mux;
use crate::server::agent_inventory_tests::Owner;
use crate::server::agent_session_attach_tests::{Client, assert_code, run};
use crate::server::*;
use serde_json::{Value, json};
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

fn missing_socket() -> PathBuf {
    static NEXT: AtomicUsize = AtomicUsize::new(0);
    let path = PathBuf::from(format!(
        "/tmp/cmux-auo-missing-{}-{}.sock",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    assert!(!path.exists());
    path
}

fn foreign_owner() -> Value {
    let previous = Mux::new_for_test("agent-update-previous", crate::SurfaceOptions::default());
    run(&previous, json!({"cmd":"identify", "machine_metadata":true}))["machine_id"].clone()
}

#[test]
fn cmux_next_agent_update_owner_matches_and_echoes_without_starting_acpmux() {
    let mux = Mux::new_for_test("agent-update-owned", crate::SurfaceOptions::default());
    mux.set_acpmux_socket(Some(missing_socket()));
    let starts = Arc::new(AtomicUsize::new(0));
    let counted = starts.clone();
    mux.set_acpmux_starter(Some(Arc::new(move || {
        counted.fetch_add(1, Ordering::SeqCst);
        Err("the plan must not start acpmux".into())
    })));
    let mut client = Client::connect(&mux, "agent-update-owned");
    let identity = client.request(json!({"cmd":"identify", "machine_metadata":true}));
    let owner = identity["data"]["machine_id"].clone();
    let reply = client.request(json!({"cmd":"agent-update-plan", "expected_machine_id":owner}));
    assert_eq!(reply["ok"], true, "{reply}");
    assert_eq!(
        reply["data"],
        json!({"machine":owner,"harnesses":[],"live_threads":0,"running_threads":0})
    );
    assert_eq!(starts.load(Ordering::SeqCst), 0);
}

#[test]
fn cmux_next_agent_update_owner_mismatch_precedes_every_acpmux_call() {
    let owner = Owner::new(json!([]), json!({"harnesses":[]}));
    let mux = owner.mux("agent-update-replacement");
    let selected = foreign_owner();
    assert_ne!(selected, json!(mux.machine_public_id));
    let mut client = Client::connect(&mux, "agent-update-replacement");
    for mut request in
        [json!({"cmd":"agent-update-plan"}), json!({"cmd":"agent-update-apply","ids":["codex"]})]
    {
        request["expected_machine_id"] = selected.clone();
        let reply = client.request(request);
        assert_code(&reply, "agent_update.owner_mismatch");
        assert!(reply.get("data").is_none_or(Value::is_null));
        assert!(!reply.to_string().contains(mux.machine_public_id.as_str()));
    }
    assert!(owner.methods().is_empty());
    mux.set_acpmux_socket(None);
    let reply = client.request(json!({"cmd":"agent-update-plan","expected_machine_id":selected}));
    assert_code(&reply, "agent_update.owner_mismatch");
}

#[test]
fn cmux_next_agent_update_owner_mismatch_cannot_start_the_replacement_owner() {
    let mux = Mux::new_for_test("agent-update-start-fence", crate::SurfaceOptions::default());
    mux.set_acpmux_socket(Some(missing_socket()));
    let starts = Arc::new(AtomicUsize::new(0));
    let counted = starts.clone();
    mux.set_acpmux_starter(Some(Arc::new(move || {
        counted.fetch_add(1, Ordering::SeqCst);
        Err("a foreign request reached the starter".into())
    })));
    let mut client = Client::connect(&mux, "agent-update-start-fence");
    let reply = client.request(json!({
        "cmd":"agent-update-apply","ids":["codex"],"expected_machine_id":foreign_owner()
    }));
    assert_code(&reply, "agent_update.owner_mismatch");
    assert_eq!(starts.load(Ordering::SeqCst), 0);
}

#[test]
fn cmux_next_agent_update_owner_rejects_malformed_fences_before_reading() {
    let owner = Owner::new(json!([]), json!({"harnesses":[]}));
    let mux = owner.mux("agent-update-malformed");
    let mut client = Client::connect(&mux, "agent-update-malformed");
    for expected in [
        Value::Null,
        json!(true),
        json!(42),
        json!({}),
        json!([]),
        json!(""),
        json!("current"),
        json!("machine_bad"),
    ] {
        for mut request in [
            json!({"cmd":"agent-update-plan"}),
            json!({"cmd":"agent-update-apply","ids":["codex"]}),
        ] {
            request["expected_machine_id"] = expected.clone();
            assert_code(&client.request(request), "agent_update.bad_request");
        }
    }
    assert!(owner.methods().is_empty());
}

#[test]
fn cmux_next_agent_update_owner_capability_requires_an_update_carrier() {
    let owner = Owner::new(json!([]), json!({"harnesses":[]}));
    let mux = owner.mux("agent-update-capability");
    let mut client = Client::connect(&mux, "agent-update-capability");
    let identity = client.request(json!({"cmd":"identify"}));
    let caps = identity["data"]["capabilities"].as_array().unwrap();
    assert!(caps.contains(&json!("agent-update-v1")));
    assert!(caps.contains(&json!("agent-update-owner-v1")));
    mux.set_acpmux_socket(None);
    let identity = client.request(json!({"cmd":"identify"}));
    assert!(
        !identity["data"]["capabilities"]
            .as_array()
            .unwrap()
            .contains(&json!("agent-update-owner-v1"))
    );
    assert!(owner.methods().is_empty());
}

#[test]
fn cmux_next_agent_update_owner_legacy_plan_keeps_its_exact_shape() {
    let mux = Mux::new_for_test("agent-update-legacy", crate::SurfaceOptions::default());
    mux.set_acpmux_socket(Some(missing_socket()));
    let mut client = Client::connect(&mux, "agent-update-legacy");
    let reply = client.request(json!({"cmd":"agent-update-plan"}));
    assert_eq!(reply["ok"], true, "{reply}");
    assert_eq!(reply["data"], json!({"harnesses":[],"live_threads":0,"running_threads":0}));
}

#[test]
fn cmux_next_agent_update_owner_trust_precedes_the_fence_and_relay_stays_denied() {
    let owner = Owner::new(json!([]), json!({"harnesses":[]}));
    let mux = owner.mux("agent-update-trust-fence");
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    for (transport, code) in [
        (ClientTransport::WebSocket, "agent_update.not_trusted"),
        (ClientTransport::Remote, "remote_denied"),
    ] {
        let client = mux.control_clients.register(transport, writer.clone());
        for mut request in [
            json!({"id":1,"cmd":"agent-update-plan"}),
            json!({"id":2,"cmd":"agent-update-apply","ids":["codex"]}),
        ] {
            request["expected_machine_id"] = Value::Null;
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
    }
    assert!(owner.methods().is_empty());
}

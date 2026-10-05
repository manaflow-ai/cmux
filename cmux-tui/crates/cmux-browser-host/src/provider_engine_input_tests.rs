//! automation.input v1 on provider sessions: a lease-refused act emits
//! nothing and takes no seq (refused input emits nothing; the lease is the
//! provider engine's last check, so the gate publishes after it).

use super::tests::{FakeApp, session, tab};
use super::*;
use crate::gate::{Gate, Grants};
use crate::provider::Frame;
use crate::vm::VmHost;
use std::sync::Mutex;

/// A gate on a provider session whose own sink records automation.input.
fn input_gate(provider: &Arc<ProviderDriver>, name: &str) -> (Gate, Arc<Mutex<Vec<Value>>>) {
    let seen: Arc<Mutex<Vec<Value>>> = Arc::default();
    let record = seen.clone();
    let events: EventSink = Arc::new(move |event: DriverEvent| {
        if event.name == crate::automation_input::EVENT {
            record.lock().unwrap().push(event.payload);
        }
    });
    let lease = LeaseCaller {
        session: name.into(),
        actor: "uid:501".into(),
        on_behalf_of: None,
        origin: "mcp".into(),
        label: "task".into(),
        ..LeaseCaller::default()
    };
    let engine =
        ProviderEngine::new(provider.clone(), "webkit", Arc::from("/* agent */"), events, lease)
            .unwrap();
    let gate = Gate::new(Arc::new(engine), Grants::default())
        .with_input_events(name, crate::driver::discard_events());
    (gate, seen)
}

#[test]
fn a_lease_refused_input_emits_nothing_and_takes_no_seq() {
    let (app, provider) =
        FakeApp::start(vec![tab("W", "webkit"), tab("X", "webkit"), tab("Y", "webkit")]);
    let first = session(&provider, "webkit", "s1");
    let (gate, seen) = input_gate(&provider, "s2");
    let act = |target: &str| {
        gate.driver_call("input.key", json!({"targetId": target, "type": "down", "key": "a"}))
    };
    // The app has handled every frame sent before this call's reply.
    let barrier = || provider.call("tab.info", &json!({"targetId": "Y"})).unwrap();
    let refused = |target: &str, name: &str| {
        let error = act(target).unwrap_err();
        assert_eq!(error.error_name.as_deref(), Some(name), "{error}");
        assert_eq!(seen.lock().unwrap().len(), 1, "{name}: a refused input emits nothing");
    };

    act("W").unwrap();
    first.call("tab.navigate", &json!({"targetId": "X", "url": "https://b.test/"})).unwrap();
    refused("X", "lease_held");
    app.send(Frame::UserInput { target_id: "W".into() });
    barrier();
    refused("W", "paused_by_user");
    app.send(Frame::LeaseUser { op: "take_over".into(), target_id: Some("W".into()), actor: None });
    barrier();
    refused("W", "user_driving");
    app.send(Frame::LeaseUser { op: "stop".into(), target_id: Some("W".into()), actor: None });
    barrier();
    refused("W", "stopped_by_user");
    app.send(Frame::LeaseUser {
        op: "allow".into(),
        target_id: None,
        actor: Some("uid:501".into()),
    });
    barrier();
    act("Y").unwrap();

    let seen = seen.lock().unwrap();
    let summary: Vec<(u64, &str, &str)> = seen
        .iter()
        .map(|e| {
            (e["seq"].as_u64().unwrap(), e["target_id"].as_str().unwrap(), e["kind"].as_str().unwrap())
        })
        .collect();
    assert_eq!(summary, vec![(0, "W", "key"), (1, "Y", "key")], "gap-free over published inputs");
}

#[test]
fn an_ended_session_emits_no_input() {
    let (_app, provider) = FakeApp::start(vec![tab("W", "webkit")]);
    let (gate, seen) = input_gate(&provider, "s2");
    gate.end_session();
    let error = gate
        .driver_call("input.key", json!({"targetId": "W", "type": "down", "key": "a"}))
        .unwrap_err();
    assert_eq!(error.code, crate::protocol::ErrorCode::Closed, "{error}");
    assert!(seen.lock().unwrap().is_empty(), "an ended session emits nothing");
}

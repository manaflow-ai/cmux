//! A machine leaves the projection on a 404 only when the 404 carries the
//! Cloud API's `vm_not_found` code. A bare 404 (a missing route) or a 404
//! with another code leaves the projection as it was; the op answers its
//! typed `not_found` with the status and the upstream code.

mod common;

use cmux_cloud::ops::WatchEvent;
use cmux_cloud::{Origin, Request, Server};
use common::FakeControlPlane;
use serde_json::{Value, json};

fn listed() -> Server<FakeControlPlane> {
    let mut s = Server::new(FakeControlPlane::with(&["vm-list"]));
    s.handle(&Request::new("cloud.machine.list", json!({}))).expect("list");
    assert!(s.projection().get("vm-alpha01").is_some());
    s.take_events();
    s
}

fn get() -> Request {
    Request::new("cloud.machine.get", json!({ "machine": "vm-alpha01" }))
}

fn delete(key: &str) -> Request {
    Request::new("cloud.machine.delete", json!({ "machine": "vm-alpha01" }))
        .origin(Origin::User)
        .key(key)
}

fn removed(events: &[WatchEvent]) -> usize {
    events
        .iter()
        .filter(|e| matches!(e, WatchEvent::Removed { id, .. } if id == "vm-alpha01"))
        .count()
}

fn answer(s: &mut Server<FakeControlPlane>, method: &str, body: Value) {
    s.control_plane_mut().respond(method, "/api/vm/vm-alpha01", 404, body);
}

#[test]
fn a_get_with_a_bare_404_keeps_the_machine_and_emits_nothing() {
    for body in [json!({}), json!({ "error": "vm_snapshot_not_found" })] {
        let mut s = listed();
        answer(&mut s, "GET", body.clone());
        let error = s.handle(&get()).unwrap_err();
        assert_eq!(error.code, "cmux.cloud.not_found");
        assert_eq!(error.status, Some(404));
        assert_eq!(error.upstream_code.as_deref(), body["error"].as_str());
        assert!(s.projection().get("vm-alpha01").is_some(), "{body}: the machine stays");
        assert!(s.take_events().is_empty(), "{body}: no watch event");
    }
}

#[test]
fn a_get_with_vm_not_found_removes_the_machine_once() {
    let mut s = listed();
    answer(&mut s, "GET", json!({ "error": "vm_not_found", "message": "Not found." }));
    let error = s.handle(&get()).unwrap_err();
    assert_eq!(
        (error.code, error.upstream_code.as_deref()),
        ("cmux.cloud.not_found", Some("vm_not_found"))
    );
    assert!(s.projection().get("vm-alpha01").is_none(), "the machine is gone");
    assert_eq!(removed(&s.take_events()), 1, "exactly one removed event");
    s.handle(&get()).unwrap_err();
    assert!(s.take_events().is_empty(), "removed once");
}

#[test]
fn a_delete_with_a_bare_404_keeps_the_machine_and_emits_nothing() {
    for (n, body) in
        [json!({}), json!({ "error": "vm_snapshot_not_found" })].into_iter().enumerate()
    {
        let mut s = listed();
        answer(&mut s, "DELETE", body.clone());
        let error = s.handle(&delete(&format!("d-{n}"))).unwrap_err();
        assert_eq!(error.code, "cmux.cloud.not_found");
        assert_eq!(error.status, Some(404));
        assert!(s.projection().get("vm-alpha01").is_some(), "{body}: the machine stays");
        assert!(s.take_events().is_empty(), "{body}: no watch event");
    }
}

#[test]
fn a_delete_with_vm_not_found_removes_the_machine_once() {
    let mut s = listed();
    answer(&mut s, "DELETE", json!({ "error": "vm_not_found" }));
    assert_eq!(s.handle(&delete("d-1")).unwrap_err().code, "cmux.cloud.not_found");
    assert!(s.projection().get("vm-alpha01").is_none());
    assert_eq!(removed(&s.take_events()), 1);
}

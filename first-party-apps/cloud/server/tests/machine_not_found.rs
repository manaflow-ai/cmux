//! `cloud.machine.not_found` means the machine is gone: a get or a delete
//! that answers it removes the machine from the projection, once. Any other
//! error leaves the projection as it is.

mod common;

use cmux_cloud::ops::WatchEvent;
use cmux_cloud::{Origin, Request, Server};
use common::{FakeControlPlane, vm};
use serde_json::json;

fn listed() -> Server<FakeControlPlane> {
    let mut s = Server::new(FakeControlPlane::with(&[]));
    s.handle(&Request::new("cloud.machine.list", json!({}))).expect("list");
    s.take_events();
    s
}

fn removed(events: &[WatchEvent]) -> usize {
    events.iter().filter(|e| matches!(e, WatchEvent::Removed { .. })).count()
}

#[test]
fn a_get_with_not_found_removes_the_machine_once() {
    let mut s = listed();
    let get = Request::new("cloud.machine.get", json!({ "machine": vm(3) }));
    assert_eq!(s.handle(&get).unwrap_err().code, "cmux.cloud.not_found");
    assert!(s.projection().get(&vm(3)).is_none());
    assert_eq!(removed(&s.take_events()), 1);
    assert_eq!(s.handle(&get).unwrap_err().code, "cmux.cloud.not_found");
    assert!(s.take_events().is_empty(), "removed once");
}

#[test]
fn a_delete_with_not_found_removes_the_machine_once() {
    let mut s = listed();
    s.control_plane_mut().wire.answer(
        "cloud.machine.delete",
        json!({ "machine": vm(1) }),
        Some("d-1"),
        json!({ "error": { "code": "cloud.machine.not_found", "message": "gone", "retryable": false } }),
    );
    let req = Request::new("cloud.machine.delete", json!({ "machine": vm(1) }))
        .origin(Origin::User)
        .key("d-1");
    assert_eq!(s.handle(&req).unwrap_err().code, "cmux.cloud.not_found");
    assert!(s.projection().get(&vm(1)).is_none());
    assert_eq!(removed(&s.take_events()), 1);
}

#[test]
fn another_error_keeps_the_machine_and_emits_nothing() {
    let mut s = listed();
    s.control_plane_mut().wire.answer(
        "cloud.machine.get",
        json!({ "machine": vm(1) }),
        None,
        json!({ "error": { "code": "auth.forbidden", "message": "not yours", "retryable": false } }),
    );
    let get = Request::new("cloud.machine.get", json!({ "machine": vm(1) }));
    assert_eq!(s.handle(&get).unwrap_err().code, "cmux.cloud.forbidden");
    assert!(s.projection().get(&vm(1)).is_some(), "only the machine's own code removes it");
    assert!(s.take_events().is_empty());
}

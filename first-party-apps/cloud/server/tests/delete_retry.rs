//! The one retry rule (OWNERSHIP-PRINCIPLES invariant 5, contract 1.1):
//! when a mutation's outcome is unknown (`mutation.indeterminate`, or the
//! relay lost the answer), the caller retries with the SAME key, the server
//! sends that same key again, and the backend's ledger answers. A delete
//! retry after the delete answers `{deleted: true}` (the tombstone).

mod common;

use cmux_cloud::{Origin, Request, Server};
use common::{FakeControlPlane, snap, vm};
use serde_json::{Value, json};

fn listed() -> Server<FakeControlPlane> {
    let mut s = Server::new(FakeControlPlane::with(&[]));
    s.handle(&Request::new("cloud.machine.list", json!({}))).expect("list");
    s.take_events();
    s
}

fn delete(op: &str, args: Value, key: &str) -> Request {
    Request::new(op, args).origin(Origin::User).key(key)
}

#[test]
fn an_indeterminate_delete_keeps_the_machine_until_the_same_key_retry_answers() {
    let mut s = listed();
    let req = delete("cloud.machine.delete", json!({ "machine": vm(3) }), "key-delete-cut");
    let err = s.handle(&req).unwrap_err();
    assert_eq!(err.code, "cmux.cloud.indeterminate");
    assert!(err.retryable);
    assert!(err.message.contains("same idempotency key"), "{}", err.message);
    assert!(s.projection().get(&vm(3)).is_some());
    assert_eq!(s.handle(&req), Ok(json!({ "deleted": true })));
    assert_eq!(s.control_plane().wire.keys("cloud.machine.delete").len(), 2);
    assert!(s.projection().get(&vm(3)).is_none());
}

#[test]
fn a_lost_delete_answer_is_retried_with_the_same_key() {
    for (op, args, key) in [
        ("cloud.machine.delete", json!({ "machine": vm(2) }), "key-delete-1"),
        ("cloud.snapshot.delete", json!({ "snapshot": snap(1) }), "key-snap-delete-1"),
    ] {
        let mut s = listed();
        s.control_plane_mut().wire.lose_next = 1;
        let req = delete(op, args, key);
        let lost = s.handle(&req).unwrap_err();
        assert_eq!(lost.code, "cmux.cloud.relay_unavailable", "{op}");
        assert!(lost.retryable);
        // The backend acted; the retry gets its replay with the same key.
        assert_eq!(s.handle(&req), Ok(json!({ "deleted": true })), "{op}");
        let keys = s.control_plane().wire.keys(op);
        assert_eq!(keys, [Some(key.to_owned()), Some(key.to_owned())], "{op}");
    }
}

#[test]
fn a_first_delete_of_a_missing_machine_stays_not_found() {
    let mut s = listed();
    s.control_plane_mut().wire.answer(
        "cloud.machine.delete",
        json!({ "machine": vm(9) }),
        Some("key-delete-9"),
        json!({ "error": { "code": "cloud.machine.not_found", "message": "no such machine", "retryable": false } }),
    );
    let req = delete("cloud.machine.delete", json!({ "machine": vm(9) }), "key-delete-9");
    assert_eq!(s.handle(&req).unwrap_err().code, "cmux.cloud.not_found");
    assert_eq!(s.projection().len(), 3, "a wrong id changes nothing here");
}

#[test]
fn a_retry_with_other_args_is_still_a_conflict() {
    let mut s = listed();
    let req = delete("cloud.machine.delete", json!({ "machine": vm(3) }), "key-delete-cut");
    s.handle(&req).unwrap_err();
    let other = delete("cloud.machine.delete", json!({ "machine": vm(1) }), "key-delete-cut");
    assert_eq!(s.handle(&other).unwrap_err().code, "cmux.cloud.idempotency_conflict");
    assert_eq!(s.control_plane().wire.count("cloud.machine.delete"), 1);
}

#[test]
fn a_replayed_delete_emits_nothing_new() {
    let mut s = listed();
    let req = delete("cloud.machine.delete", json!({ "machine": vm(2) }), "key-delete-1");
    assert_eq!(s.handle(&req), Ok(json!({ "deleted": true })));
    assert_eq!(s.take_events().len(), 1);
    assert_eq!(s.handle(&req), Ok(json!({ "deleted": true })));
    assert!(s.take_events().is_empty(), "a replay emits nothing");
}

#[test]
fn port_close_is_idempotent_without_the_backend() {
    // `cloud.port.close` closes a local listener; no forward is not an error.
    let mut s = Server::new(FakeControlPlane::with(&[]));
    let req = Request::new("cloud.port.close", json!({ "machine": "vm-alpha01", "port": 3000 }))
        .key("pc-1");
    let first = s.handle(&req).expect("close");
    assert_eq!(first["closed"], false);
    assert_eq!(s.handle(&req).expect("again"), first);
    assert!(s.control_plane().no_calls());
}

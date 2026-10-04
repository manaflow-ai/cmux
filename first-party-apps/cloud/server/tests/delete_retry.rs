//! A delete retried after a lost answer (OWNERSHIP-PRINCIPLES invariant 5).
//!
//! Rule: a delete with the same idempotency key, op and args as an earlier
//! attempt whose outcome is unknown (no answer, or a 5xx answer) answers
//! `{ok: true}` when the Cloud API now answers 404: the resource is gone,
//! which is the outcome the caller asked for. A first delete of a missing
//! resource, or a retry after a definite 4xx answer, stays `not_found`, so a
//! wrong id is never hidden.
//!
//! "Gone" is the kind's own not-found code in the 404 answer, never any
//! 404: a bare 404 (a missing route), a 404 with no code or with another
//! kind's code stays the typed error.

mod common;

use cmux_cloud::ops::WatchEvent;
use cmux_cloud::{Origin, Request, Server};
use common::FakeControlPlane;
use serde_json::{Value, json};

const PUB_1: &str = "00000000-0000-4000-8000-000000000001";

/// One delete op of the server: its args, the fixture that answers 200 and
/// the route it calls.
struct Case {
    op: &'static str,
    args: Value,
    fixture: &'static str,
    path: String,
    /// The `{ok: true}` answer of a successful delete.
    answer: Value,
    /// The Cloud API's not-found code for this kind (the only 404 that
    /// counts as gone) and the fixture that answers it.
    gone: &'static str,
    gone_fixture: &'static str,
    /// Another kind's not-found code (never gone for this kind).
    other: &'static str,
}

fn cases() -> Vec<Case> {
    vec![
        Case {
            op: "cloud.machine.delete",
            args: json!({ "machine": "vm-alpha01" }),
            fixture: "vm-delete",
            path: "/api/vm/vm-alpha01".into(),
            answer: json!({ "ok": true }),
            gone: "vm_not_found",
            gone_fixture: "vm-delete-gone",
            other: "vm_snapshot_not_found",
        },
        Case {
            op: "cloud.snapshot.delete",
            args: json!({ "machine": "vm-alpha01", "snapshot": "snap-one" }),
            fixture: "vm-snapshot-delete",
            path: "/api/vm/vm-alpha01/snapshots/snap-one".into(),
            answer: json!({ "ok": true }),
            gone: "vm_snapshot_not_found",
            gone_fixture: "vm-snapshot-delete-gone",
            other: "vm_not_found",
        },
        Case {
            op: "cloud.firewall.delete",
            args: json!({ "rule": "fw-test01" }),
            fixture: "firewall-delete",
            path: "/api/vm/firewall?ruleId=fw-test01".into(),
            answer: json!({ "ok": true }),
            // `vm_not_found` here means the VM is missing, not the rule.
            gone: "vm_firewall_rule_not_found",
            gone_fixture: "firewall-delete-gone",
            other: "vm_not_found",
        },
        Case {
            op: "cloud.publication.delete",
            args: json!({ "publication": PUB_1 }),
            fixture: "publication-delete",
            path: format!("/api/vm/publications/{PUB_1}"),
            answer: json!({ "ok": true }),
            gone: "vm_publication_not_found",
            gone_fixture: "publication-delete-gone",
            other: "vm_not_found",
        },
        Case {
            op: "cloud.fs.remove",
            args: json!({ "machine": "vm-alpha01", "path": "/home/cmux/old.txt" }),
            fixture: "fs-remove",
            path: "/api/vm/vm-alpha01/fs/remove?path=/home/cmux/old.txt".into(),
            answer: json!({ "ok": true, "path": "/home/cmux/old.txt" }),
            gone: "vm_file_not_found",
            gone_fixture: "fs-remove-gone",
            other: "vm_not_found",
        },
    ]
}

fn delete(case: &Case, key: &str) -> Request {
    Request::new(case.op, case.args.clone()).origin(Origin::User).key(key)
}

/// The Cloud API now answers 404 with the kind's own not-found code.
fn not_found(s: &mut Server<FakeControlPlane>, case: &Case) {
    let body = FakeControlPlane::fixture_body(case.gone_fixture);
    assert_eq!(body["error"], case.gone, "{}", case.gone_fixture);
    s.control_plane_mut().serve(case.gone_fixture);
}

/// The first attempt reaches the Cloud API, but its answer is lost; then
/// the route answers 404 with `body`.
fn lost_then_404(case: &Case, key: &str, body: Value) -> Server<FakeControlPlane> {
    let mut s = Server::new(FakeControlPlane::with(&[case.fixture]));
    s.control_plane_mut().lose_next = 1;
    let lost = s.handle(&delete(case, key)).unwrap_err();
    assert_eq!(lost.code, "cmux.cloud.relay_unavailable", "{}", case.op);
    s.control_plane_mut().respond("DELETE", &case.path, 404, body);
    s
}

#[test]
fn only_the_kinds_own_not_found_code_counts_as_gone() {
    for case in cases() {
        let mut s = lost_then_404(&case, "g-1", json!({}));
        not_found(&mut s, &case);
        assert_eq!(s.handle(&delete(&case, "g-1")), Ok(case.answer.clone()), "{}", case.op);
    }
}

#[test]
fn a_bare_404_after_a_lost_answer_stays_an_error() {
    // A 404 with no code is a missing route (production has no fs routes
    // today), not a gone resource. Every kind is checked before the assert,
    // so a red run names each kind that fails.
    let mut wrong = Vec::new();
    for body in [json!({}), Value::Null] {
        for case in cases() {
            let mut s = lost_then_404(&case, "b-1", body.clone());
            let retry = s.handle(&delete(&case, "b-1"));
            if !matches!(&retry, Err(e) if e.code == "cmux.cloud.not_found") {
                wrong.push(format!("{} with {body}: {retry:?}", case.op));
            }
        }
    }
    assert!(wrong.is_empty(), "a bare 404 counted as gone: {wrong:#?}");
}

#[test]
fn a_404_with_another_kinds_code_after_a_lost_answer_stays_an_error() {
    // Includes a firewall delete that gets `vm_not_found` (the VM is
    // missing, not the rule).
    let mut wrong = Vec::new();
    for case in cases() {
        let mut s = lost_then_404(&case, "o-1", json!({ "error": case.other }));
        let retry = s.handle(&delete(&case, "o-1"));
        let typed = matches!(&retry, Err(e) if e.code == "cmux.cloud.not_found"
            && e.upstream_code.as_deref() == Some(case.other));
        if !typed {
            wrong.push(format!("{} with {}: {retry:?}", case.op, case.other));
        }
    }
    assert!(wrong.is_empty(), "another kind's code counted as gone: {wrong:#?}");
}

#[test]
fn a_retry_after_a_lost_answer_is_ok_when_the_resource_is_gone() {
    for case in cases() {
        let mut s = Server::new(FakeControlPlane::with(&[case.fixture]));
        // The first attempt reaches the Cloud API (the resource is deleted),
        // but its answer is lost.
        s.control_plane_mut().lose_next = 1;
        let lost = s.handle(&delete(&case, "d-1")).unwrap_err();
        assert_eq!(lost.code, "cmux.cloud.relay_unavailable", "{}", case.op);
        not_found(&mut s, &case);
        let retry = s.handle(&delete(&case, "d-1"));
        assert_eq!(retry, Ok(case.answer.clone()), "{}", case.op);
        assert_eq!(s.control_plane().count("DELETE", &case.path), 2, "{}", case.op);
        // A later replay answers the same and calls nothing.
        assert_eq!(s.handle(&delete(&case, "d-1")), Ok(case.answer.clone()), "{}", case.op);
        assert_eq!(s.control_plane().count("DELETE", &case.path), 2, "{}", case.op);
    }
}

#[test]
fn a_retry_after_a_5xx_answer_is_ok_when_the_resource_is_gone() {
    for case in cases() {
        let mut s = Server::new(FakeControlPlane::with(&[]));
        s.control_plane_mut().respond("DELETE", &case.path, 502, json!({ "error": "gateway" }));
        let failed = s.handle(&delete(&case, "d-5")).unwrap_err();
        assert_eq!(failed.code, "cmux.cloud.upstream_error", "{}", case.op);
        not_found(&mut s, &case);
        assert_eq!(s.handle(&delete(&case, "d-5")), Ok(case.answer.clone()), "{}", case.op);
    }
}

#[test]
fn a_first_delete_of_a_missing_resource_stays_not_found() {
    for case in cases() {
        let mut s = Server::new(FakeControlPlane::with(&[]));
        not_found(&mut s, &case);
        let err = s.handle(&delete(&case, "f-1")).unwrap_err();
        assert_eq!(err.code, "cmux.cloud.not_found", "{}", case.op);
    }
}

#[test]
fn a_retry_after_a_definite_not_found_stays_not_found() {
    // The first attempt got a real 404 (a wrong id): the same key again must
    // not turn that into success.
    for case in cases() {
        let mut s = Server::new(FakeControlPlane::with(&[]));
        not_found(&mut s, &case);
        assert_eq!(s.handle(&delete(&case, "w-1")).unwrap_err().code, "cmux.cloud.not_found");
        let again = s.handle(&delete(&case, "w-1")).unwrap_err();
        assert_eq!(again.code, "cmux.cloud.not_found", "{}", case.op);
    }
}

#[test]
fn a_retry_with_other_args_is_still_a_conflict() {
    let mut s = Server::new(FakeControlPlane::with(&["vm-delete"]));
    s.control_plane_mut().lose_next = 1;
    let first = Request::new("cloud.machine.delete", json!({ "machine": "vm-alpha01" }))
        .origin(Origin::User)
        .key("c-1");
    s.handle(&first).unwrap_err();
    let other = Request::new("cloud.machine.delete", json!({ "machine": "vm-beta02" }))
        .origin(Origin::User)
        .key("c-1");
    assert_eq!(s.handle(&other).unwrap_err().code, "cmux.cloud.idempotency_conflict");
}

#[test]
fn a_gone_machine_is_removed_from_the_projection_exactly_once() {
    let mut s = Server::new(FakeControlPlane::with(&["vm-list", "vm-delete"]));
    s.handle(&Request::new("cloud.machine.list", json!({}))).expect("list");
    assert!(s.projection().get("vm-alpha01").is_some());
    s.take_events();
    let req = Request::new("cloud.machine.delete", json!({ "machine": "vm-alpha01" }))
        .origin(Origin::User)
        .key("p-1");
    s.control_plane_mut().lose_next = 1;
    s.handle(&req).unwrap_err();
    assert!(s.take_events().is_empty(), "a lost answer changes nothing here");
    assert!(s.projection().get("vm-alpha01").is_some());
    s.control_plane_mut().respond(
        "DELETE",
        "/api/vm/vm-alpha01",
        404,
        json!({ "error": "vm_not_found" }),
    );
    assert_eq!(s.handle(&req), Ok(json!({ "ok": true })));
    let events = s.take_events();
    assert_eq!(events.len(), 1, "{events:?}");
    assert!(matches!(&events[0], WatchEvent::Removed { id, .. } if id == "vm-alpha01"));
    assert!(s.projection().get("vm-alpha01").is_none());
    assert_eq!(s.handle(&req), Ok(json!({ "ok": true })));
    assert!(s.take_events().is_empty(), "a replay emits nothing");
}

#[test]
fn port_close_is_idempotent_without_the_cloud_api() {
    // `cloud.port.close` closes a local listener; no forward is not an error.
    let mut s = Server::new(FakeControlPlane::with(&[]));
    let req = Request::new("cloud.port.close", json!({ "machine": "vm-alpha01", "port": 3000 }))
        .key("pc-1");
    let first = s.handle(&req).expect("close");
    assert_eq!(first["closed"], false);
    assert_eq!(s.handle(&req).expect("again"), first);
    assert!(s.control_plane().calls.is_empty());
}

#[test]
fn an_unknown_outcome_stays_known_after_a_later_definite_failure() {
    // Lost answer, then a 429 and a 400 on retries, then a 404: the first
    // attempt may have deleted it, so the 404 is still success.
    for case in cases() {
        let mut s = Server::new(FakeControlPlane::with(&[case.fixture]));
        s.control_plane_mut().lose_next = 1;
        s.handle(&delete(&case, "u-1")).unwrap_err();
        for status in [429, 400] {
            s.control_plane_mut().respond("DELETE", &case.path, status, json!({}));
            s.handle(&delete(&case, "u-1")).unwrap_err();
        }
        not_found(&mut s, &case);
        assert_eq!(s.handle(&delete(&case, "u-1")), Ok(case.answer.clone()), "{}", case.op);
    }
}

#[test]
fn a_501_is_a_definite_answer() {
    for case in cases() {
        let mut s = Server::new(FakeControlPlane::with(&[]));
        s.control_plane_mut().respond("DELETE", &case.path, 501, json!({}));
        assert_eq!(s.handle(&delete(&case, "n-1")).unwrap_err().code, "cmux.cloud.unsupported");
        not_found(&mut s, &case);
        let again = s.handle(&delete(&case, "n-1")).unwrap_err();
        assert_eq!(again.code, "cmux.cloud.not_found", "{}", case.op);
    }
}

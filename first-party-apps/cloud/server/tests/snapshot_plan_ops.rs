//! Snapshot, plan and auth ops against the vectors fake.

mod common;

use cmux_cloud::{Origin, Request, Server};
use common::{FakeControlPlane, snap, vm};
use serde_json::json;

fn server() -> Server<FakeControlPlane> {
    Server::new(FakeControlPlane::with(&[]))
}

#[test]
fn snapshot_list_and_create() {
    let mut s = server();
    let list =
        s.handle(&Request::new("cloud.snapshot.list", json!({ "machine": vm(1) }))).expect("list");
    assert_eq!(list["snapshots"][0]["id"], snap(1));
    assert_eq!(list["snapshots"][0]["revision"], "3");
    let created = s
        .handle(
            &Request::new(
                "cloud.snapshot.create",
                json!({ "machine": vm(1), "name": "checkpoint" }),
            )
            .key("key-snap-1"),
        )
        .expect("create");
    assert_eq!(created["snapshot"]["status"], "creating");
}

#[test]
fn restore_adds_a_machine_once_per_key() {
    let mut s = server();
    let req = Request::new(
        "cloud.snapshot.restore",
        json!({ "snapshot": snap(1), "name": "restored box" }),
    )
    .key("key-restore-1")
    .origin(Origin::User);
    let first = s.handle(&req).expect("restore");
    assert_eq!(s.handle(&req).expect("replay"), first);
    assert_eq!(first["machine"]["id"], vm(6));
    assert_eq!(s.projection().len(), 1);
    assert_eq!(s.control_plane().wire.count("cloud.snapshot.restore"), 1);
}

#[test]
fn snapshot_delete_needs_origin_user() {
    let mut s = server();
    let req = Request::new("cloud.snapshot.delete", json!({ "snapshot": snap(1) }))
        .key("key-snap-delete-1");
    assert_eq!(s.handle(&req).unwrap_err().code, "cmux.cloud.origin_refused");
    assert!(s.control_plane().no_calls());
    assert_eq!(s.handle(&req.origin(Origin::User)), Ok(json!({ "deleted": true })));
}

#[test]
fn the_plan_carries_limits_and_usage() {
    let mut s = server();
    let plan = s.handle(&Request::new("cloud.plan.get", json!({}))).expect("plan");
    assert_eq!(plan["plan_id"], "pro");
    assert_eq!(plan["limits"]["locked_memory_options_mb"], json!([65536]));
    assert_eq!(plan["usage"]["vm_hours_used"], 41.5);
    assert!(s.projection().is_empty(), "the plan read changes no machine");
}

#[test]
fn a_checkout_url_that_is_not_https_is_refused() {
    let mut s = server();
    s.control_plane_mut().wire.answer(
        "cloud.billing.checkout",
        json!({ "plan": "pro" }),
        Some("c-http"),
        json!({ "url": "http://checkout.example.com/x" }),
    );
    let req = Request::new("cloud.billing.checkout", json!({ "plan": "pro" }))
        .origin(Origin::User)
        .key("c-http");
    assert_eq!(s.handle(&req).unwrap_err().code, "cmux.cloud.bad_response");
}

#[test]
fn auth_status_comes_from_the_host() {
    let mut s = server();
    let status = s.handle(&Request::new("cloud.auth.status", json!({}))).expect("status");
    assert_eq!(status, json!({ "signedIn": true, "team": "team_t0000000000000000001" }));
    assert!(s.control_plane().no_calls(), "no backend call");
}

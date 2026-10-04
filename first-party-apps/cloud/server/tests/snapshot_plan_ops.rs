//! Snapshot, plan and usage ops against recorded fixtures.

mod common;

use cmux_cloud::{Origin, Request, Server};
use common::FakeControlPlane;
use serde_json::json;

fn server(fixtures: &[&str]) -> Server<FakeControlPlane> {
    Server::new(FakeControlPlane::with(fixtures))
}

#[test]
fn snapshot_list_and_create() {
    let mut s = server(&["vm-snapshots", "vm-snapshot-create"]);
    let list = s
        .handle(&Request::new("cloud.snapshot.list", json!({ "machine": "vm-alpha01" })))
        .expect("list");
    assert_eq!(list["snapshots"][0]["id"], "snap-two");
    assert_eq!(list["snapshots"][1]["name"], json!(null));
    let made = s
        .handle(
            &Request::new(
                "cloud.snapshot.create",
                json!({ "machine": "vm-alpha01", "name": "nightly" }),
            )
            .key("s-1"),
        )
        .expect("create");
    assert_eq!(made["id"], "snap-three");
    assert_eq!(made["name"], "nightly");
}

#[test]
fn restore_and_fork_add_a_machine_once_per_key() {
    let mut s = server(&["vm-restore", "vm-fork"]);
    let restore =
        Request::new("cloud.snapshot.restore", json!({ "snapshot": "snap-two" })).key("r-1");
    let a = s.handle(&restore).expect("restore");
    let b = s.handle(&restore).expect("retry");
    assert_eq!(a, b);
    assert_eq!(s.control_plane().count("POST", "/api/vm/restore"), 1);
    assert_eq!(s.control_plane().calls[0].body, Some(json!({ "snapshotId": "snap-two" })));
    assert!(s.projection().get("vm-restored05").is_some());
    let fork = Request::new("cloud.snapshot.fork", json!({ "machine": "vm-alpha01" })).key("f-1");
    let forked = s.handle(&fork).expect("fork");
    assert_eq!(forked["id"], "vm-fork06");
    assert_eq!(forked["snapshotId"], "snap-fork");
    assert!(s.projection().get("vm-fork06").is_some());
}

#[test]
fn snapshot_delete_needs_origin_user() {
    let args = json!({ "machine": "vm-alpha01", "snapshot": "snap-one" });
    let mut s = server(&["vm-snapshot-delete"]);
    let agent = Request::new("cloud.snapshot.delete", args.clone()).origin(Origin::Mcp).key("x-1");
    assert_eq!(s.handle(&agent).unwrap_err().code, "cmux.cloud.origin_refused");
    assert!(s.control_plane().calls.is_empty());
    let user = Request::new("cloud.snapshot.delete", args).origin(Origin::User).key("x-1");
    assert_eq!(s.handle(&user).expect("delete"), json!({ "ok": true }));
    assert_eq!(s.control_plane().count("DELETE", "/api/vm/vm-alpha01/snapshots/snap-one"), 1);
}

#[test]
fn plan_and_usage_come_from_the_list_limits() {
    let mut s = server(&["vm-list"]);
    let plan = s.handle(&Request::new("cloud.plan.get", json!({}))).expect("plan");
    assert_eq!(plan["planId"], "go");
    assert_eq!(plan["maxActiveVms"], 3);
    assert_eq!(plan["memoryOptionsMb"], json!([4096, 8192]));
    assert_eq!(plan["memoryUpgradePlanId"], "pro");
    let usage = s.handle(&Request::new("cloud.usage.get", json!({}))).expect("usage");
    assert_eq!(usage["vmHoursUsed"], 12.5);
    assert_eq!(usage["vmHoursIncluded"], 40.0);
    assert_eq!(s.projection().len(), 2, "the same read refreshed the projection");
}

#[test]
fn auth_status_comes_from_the_host() {
    let mut s = server(&[]);
    let status = s.handle(&Request::new("cloud.auth.status", json!({}))).expect("status");
    assert_eq!(status, json!({ "signedIn": true, "team": "team-test" }));
    assert!(s.control_plane().calls.is_empty(), "no Cloud API call");
}

/// The Cloud API has no dedup for snapshot create yet (web route gap). The
/// server must still send the derived key on every attempt, and the same key
/// again after a lost answer, so the route can dedup once it supports keys.
#[test]
fn snapshot_create_sends_the_same_derived_key_after_a_lost_answer() {
    let mut s = server(&["vm-snapshot-create"]);
    let args = json!({ "machine": "vm-alpha01", "name": "nightly" });
    let request = Request::new("cloud.snapshot.create", args.clone()).key("s-lost");
    s.control_plane_mut().fail_next = 1;
    assert!(s.handle(&request).is_err());
    s.handle(&request).expect("retry");
    let expected = cmux_cloud::api::upstream_key("cloud.snapshot.create", &args, "s-lost");
    let keys: Vec<_> = s.control_plane().calls.iter().map(|c| c.idempotency_key.clone()).collect();
    assert_eq!(keys, vec![Some(expected.clone()), Some(expected)]);
}

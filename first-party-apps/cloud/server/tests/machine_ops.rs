//! Machine ops against the fake control plane and recorded fixtures.

mod common;

use cmux_cloud::api::models::{Machine, MachineStatus};
use cmux_cloud::ops::Change;
use cmux_cloud::{Origin, Request, Server};
use common::FakeControlPlane;
use serde_json::json;

fn server(fixtures: &[&str]) -> Server<FakeControlPlane> {
    Server::new(FakeControlPlane::with(fixtures))
}

#[test]
fn create_without_an_idempotency_key_is_refused() {
    let mut s = server(&["vm-create"]);
    let err = s.handle(&Request::new("cloud.machine.create", json!({}))).unwrap_err();
    assert_eq!(err.code, "cmux.cloud.idempotency_key_required");
    assert!(s.control_plane().calls.is_empty(), "nothing reached the Cloud API");
}

#[test]
fn a_retry_with_the_same_key_returns_the_same_machine() {
    let mut s = server(&["vm-create"]);
    let create =
        Request::new("cloud.machine.create", json!({ "displayName": "scratch" })).key("k-1");
    let first = s.handle(&create).expect("create");
    let second = s.handle(&create).expect("retry");
    assert_eq!(first, second);
    assert_eq!(first["id"], "vm-new04");
    assert_eq!(first["status"], "provisioning");
    assert_eq!(s.control_plane().count("POST", "/api/vm"), 1, "one provider create");
    let call = &s.control_plane().calls[0];
    assert_eq!(call.idempotency_key.as_deref(), Some("k-1"), "the key reaches the Cloud API");
    assert_eq!(call.body, Some(json!({ "displayName": "scratch" })));
}

#[test]
fn the_same_key_for_other_args_is_a_conflict() {
    let mut s = server(&["vm-create"]);
    s.handle(&Request::new("cloud.machine.create", json!({})).key("k-1")).expect("create");
    let other = Request::new("cloud.machine.create", json!({ "displayName": "x" })).key("k-1");
    assert_eq!(s.handle(&other).unwrap_err().code, "cmux.cloud.idempotency_conflict");
    assert_eq!(s.control_plane().count("POST", "/api/vm"), 1);
}

#[test]
fn delete_needs_origin_user() {
    for origin in [Origin::Mcp, Origin::Cli, Origin::Script, Origin::Agent, Origin::Remote] {
        let mut s = server(&["vm-list", "vm-delete"]);
        let req = Request::new("cloud.machine.delete", json!({ "machine": "vm-alpha01" }))
            .origin(origin)
            .key("d-1");
        assert_eq!(s.handle(&req).unwrap_err().code, "cmux.cloud.origin_refused", "{origin:?}");
        assert_eq!(s.control_plane().count("DELETE", "/api/vm/vm-alpha01"), 0);
    }
    let mut s = server(&["vm-list", "vm-delete"]);
    s.handle(&Request::new("cloud.machine.list", json!({}))).expect("list");
    assert!(s.projection().get("vm-alpha01").is_some());
    let req = Request::new("cloud.machine.delete", json!({ "machine": "vm-alpha01" }))
        .origin(Origin::User)
        .key("d-1");
    assert_eq!(s.handle(&req).expect("delete"), json!({ "ok": true }));
    assert_eq!(s.control_plane().count("DELETE", "/api/vm/vm-alpha01"), 1);
    assert!(s.projection().get("vm-alpha01").is_none(), "the projection drops the machine");
}

#[test]
fn unauthorized_maps_to_auth_required() {
    let mut s = server(&["vm-list"]);
    s.handle(&Request::new("cloud.machine.list", json!({}))).expect("list");
    assert!(!s.projection().is_empty());
    s.control_plane_mut().serve("unauthorized");
    let err = s.handle(&Request::new("cloud.machine.list", json!({}))).unwrap_err();
    assert_eq!(err.code, "cmux.cloud.auth_required");
    assert_eq!(err.status, Some(401));
    assert!(s.projection().is_empty(), "a signed-out Mac shows no machines");
}

#[test]
fn no_sign_in_at_the_host_maps_to_auth_required() {
    let mut s = server(&["vm-list"]);
    s.control_plane_mut().signed_in = false;
    let err = s.handle(&Request::new("cloud.machine.list", json!({}))).unwrap_err();
    assert_eq!(err.code, "cmux.cloud.auth_required");
    let status = s.handle(&Request::new("cloud.auth.status", json!({}))).expect("status");
    assert_eq!(status["signedIn"], false);
}

#[test]
fn the_list_fixture_maps_to_typed_records() {
    let mut s = server(&["vm-list"]);
    let out = s.handle(&Request::new("cloud.machine.list", json!({}))).expect("list");
    let machines: Vec<Machine> = serde_json::from_value(out["machines"].clone()).expect("typed");
    assert_eq!(machines.len(), 2, "destroyed machines are not listed");
    let alpha = &machines[0];
    assert_eq!(alpha.id, "vm-alpha01");
    assert_eq!(alpha.status, MachineStatus::Running);
    assert_eq!(alpha.display_name.as_deref(), Some("build box"));
    assert_eq!(alpha.created_at, Some(1_790_000_000_000.0));
    assert_eq!(alpha.address.as_ref().and_then(|a| a.ipv4.as_deref()), Some("10.200.0.2"));
    assert_eq!(alpha.created_by.as_ref().map(|c| c.user_id.as_str()), Some("user-test-1"));
    assert_eq!(machines[1].status, MachineStatus::Paused);
    assert_eq!(out["revision"], 1);
}

#[test]
fn a_mutation_updates_the_projection_at_once() {
    let mut s = server(&["vm-list", "vm-pause", "vm-rename"]);
    s.handle(&Request::new("cloud.machine.list", json!({}))).expect("list");
    let before = s.projection().revision();
    s.take_events();
    let paused = s
        .handle(&Request::new("cloud.machine.pause", json!({ "machine": "vm-alpha01" })).key("p-1"))
        .expect("pause");
    assert_eq!(paused["status"], "paused");
    assert_eq!(paused["displayName"], "build box", "fields the answer lacks are kept");
    let alpha = s.projection().get("vm-alpha01").expect("known");
    assert_eq!(alpha.status, MachineStatus::Paused);
    assert_eq!(s.projection().revision(), before + 1);
    let events = s.take_events();
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].change, Change::Upsert);
    assert_eq!(events[0].machine.as_deref(), Some("vm-alpha01"));
    assert_eq!(s.control_plane().count("GET", "/api/vm"), 1, "no extra list read");
    s.handle(
        &Request::new(
            "cloud.machine.rename",
            json!({ "machine": "vm-alpha01", "displayName": "renamed" }),
        )
        .key("r-1"),
    )
    .expect("rename");
    assert_eq!(
        s.projection().get("vm-alpha01").expect("known").display_name.as_deref(),
        Some("renamed")
    );
}

#[test]
fn start_answers_to_resume_and_the_relay_names() {
    for name in [
        "cloud.machine.start",
        "cloud.machine.resume",
        "cmux.cloud.machine.start",
        "vm.resume",
        "vm.start",
    ] {
        let mut s = server(&["vm-resume"]);
        let out = s
            .handle(&Request::new(name, json!({ "machine": "vm-beta02" })).key("s-1"))
            .unwrap_or_else(|e| panic!("{name}: {e}"));
        assert_eq!(out["status"], "running", "{name}");
        assert_eq!(s.control_plane().count("POST", "/api/vm/vm-beta02/resume"), 1, "{name}");
    }
}

#[test]
fn ids_cannot_change_the_path() {
    let mut s = server(&[]);
    for bad in ["../billing", "vm-1/pause", "vm-1?x=1", "", " vm"] {
        let err =
            s.handle(&Request::new("cloud.machine.get", json!({ "machine": bad }))).unwrap_err();
        assert_eq!(err.code, "cmux.cloud.invalid_args", "{bad:?}");
    }
    assert!(s.control_plane().calls.is_empty());
}

#[test]
fn reads_refuse_keys_and_unknown_ops_are_refused() {
    let mut s = server(&["vm-list"]);
    let read = Request::new("cloud.machine.list", json!({})).key("x");
    assert_eq!(s.handle(&read).unwrap_err().code, "cmux.cloud.idempotency_key_forbidden");
    let err = s.handle(&Request::new("cloud.machine.exec", json!({}))).unwrap_err();
    assert_eq!(err.code, "cmux.cloud.unknown_op");
}

#[test]
fn resize_stats_and_idle_policy() {
    let mut s = server(&["vm-resize", "vm-stats"]);
    let resize = Request::new("cloud.machine.resize", json!({ "machine": "vm-alpha01", "cpu": 8 }))
        .key("z-1");
    let out = s.handle(&resize).expect("resize");
    assert_eq!(out["cpus"], 8.0);
    assert_eq!(out["maxVcpus"], 8.0);
    let bad =
        Request::new("cloud.machine.resize", json!({ "machine": "vm-alpha01", "memoryMb": 5000 }))
            .key("z-2");
    assert_eq!(s.handle(&bad).unwrap_err().code, "cmux.cloud.invalid_args");
    let stats = s
        .handle(&Request::new("cloud.machine.stats", json!({ "machine": "vm-alpha01" })))
        .expect("stats");
    assert_eq!(stats["state"], "awake");
    let idle = Request::new(
        "cloud.machine.idle_policy.set",
        json!({ "machine": "vm-alpha01", "idleTimeoutSeconds": 300 }),
    )
    .key("i-1");
    assert_eq!(s.handle(&idle).unwrap_err().code, "cmux.cloud.unsupported");
}

#[test]
fn a_plan_limit_is_typed() {
    let mut s = server(&["vm-create-plan-limit"]);
    let err = s.handle(&Request::new("cloud.machine.create", json!({})).key("c-9")).unwrap_err();
    assert_eq!(err.code, "cmux.cloud.plan_limit");
    assert_eq!(err.upstream_code.as_deref(), Some("vm_requires_pro"));
    assert_eq!(err.message, "Cloud machines need a paid plan.");
}

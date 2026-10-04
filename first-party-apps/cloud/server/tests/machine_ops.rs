//! Machine ops against the fake control plane and recorded fixtures.

mod common;

use cmux_cloud::api::models::{Machine, MachineStatus};
use cmux_cloud::api::upstream_key;
use cmux_cloud::ops::WatchEvent;
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
    let derived = upstream_key("cloud.machine.create", &json!({ "displayName": "scratch" }), "k-1");
    assert_eq!(derived.len(), 64);
    assert_eq!(
        call.idempotency_key.as_deref(),
        Some(derived.as_str()),
        "a derived key reaches the Cloud API"
    );
    assert_eq!(call.body, Some(json!({ "displayName": "scratch" })));
}

#[test]
fn a_retry_after_a_lost_answer_resends_the_same_key() {
    let mut s = server(&["vm-create"]);
    let create =
        Request::new("cloud.machine.create", json!({ "displayName": "scratch" })).key("k-2");
    s.control_plane_mut().fail_next = 1;
    assert_eq!(s.handle(&create).unwrap_err().code, "cmux.cloud.relay_unavailable");
    // The Cloud API created the machine but the answer was lost: simulate it.
    s.control_plane_mut().fail_next = 0;
    let first = s.handle(&create).expect("retry");
    let again = s.handle(&create).expect("replay");
    assert_eq!(first, again);
    let keys: Vec<_> = s.control_plane().calls.iter().map(|c| c.idempotency_key.clone()).collect();
    assert_eq!(keys.len(), 2, "the replay made no call");
    assert_eq!(keys[0], keys[1], "the retry sent the same key");
    assert_eq!(s.control_plane().provider_posts, 1);
    let other = Request::new("cloud.machine.create", json!({})).key("k-2");
    assert_eq!(s.handle(&other).unwrap_err().code, "cmux.cloud.idempotency_conflict");
}

#[test]
fn a_failed_attempt_still_holds_its_key() {
    let mut s = server(&["vm-create"]);
    s.control_plane_mut().fail_next = 1;
    let create = Request::new("cloud.machine.create", json!({})).key("k-3");
    assert!(s.handle(&create).is_err());
    let fork = Request::new("cloud.snapshot.fork", json!({ "machine": "vm-alpha01" })).key("k-3");
    assert_eq!(s.handle(&fork).unwrap_err().code, "cmux.cloud.idempotency_conflict");
    let bad = Request::new("cloud.machine.create", json!({ "displayName": "" })).key("k-4");
    assert_eq!(s.handle(&bad).unwrap_err().code, "cmux.cloud.invalid_args");
    let fixed = Request::new("cloud.machine.create", json!({ "displayName": "ok" })).key("k-4");
    assert!(s.handle(&fixed).is_ok(), "refused args leave the key free");
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
    assert_eq!(alpha.created_at, Some(1_790_000_000_000.0), "the ISO string becomes epoch ms");
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
    assert!(
        matches!(&events[0], WatchEvent::Upsert { machine, .. } if machine.id == "vm-alpha01"),
        "{events:?}"
    );
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
        let mut s = server(&["vm-list", "vm-resume"]);
        s.handle(&Request::new("cloud.machine.list", json!({}))).expect("list");
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

#[test]
fn a_partial_answer_for_an_unknown_machine_reads_the_full_record() {
    let mut s = server(&["vm-get", "vm-pause"]);
    let out = s
        .handle(&Request::new("cloud.machine.pause", json!({ "machine": "vm-alpha01" })).key("p-9"))
        .expect("pause");
    assert_eq!(out["status"], "paused");
    assert_eq!(out["provider"], "freestyle");
    assert_eq!(out["displayName"], "build box");
    assert_eq!(s.control_plane().count("GET", "/api/vm/vm-alpha01"), 1);
    assert_eq!(
        s.control_plane()
            .calls
            .iter()
            .find(|c| c.method == "GET")
            .and_then(|c| c.idempotency_key.clone()),
        None
    );
}

#[test]
fn relay_names_take_their_own_args() {
    let mut s = server(&["vm-list", "vm-pause", "vm-restore"]);
    s.handle(&Request::new("vm.list", json!({}))).expect("list");
    let out = s
        .handle(&Request::new("vm.pause", json!({ "vm_id": "vm-alpha01" })).key("v-1"))
        .expect("pause");
    assert_eq!(out["status"], "paused");
    let restore = Request::new(
        "vm.snapshot.restore",
        json!({ "vm_id": "vm-alpha01", "snapshot_id": "snap-two" }),
    )
    .key("v-2");
    assert_eq!(s.handle(&restore).expect("restore")["id"], "vm-restored05");
}

#[test]
fn a_delete_of_a_gone_machine_drops_it_here_too() {
    let mut s = server(&["vm-list"]);
    s.handle(&Request::new("cloud.machine.list", json!({}))).expect("list");
    let req = Request::new("cloud.machine.delete", json!({ "machine": "vm-beta02" }))
        .origin(Origin::User)
        .key("g-1");
    assert_eq!(s.handle(&req).unwrap_err().code, "cmux.cloud.not_found");
    assert!(s.projection().get("vm-beta02").is_none());
}

#[test]
fn display_names_follow_the_cloud_api_rules() {
    let mut s = server(&["vm-list", "vm-rename"]);
    for bad in [json!("x".repeat(65)), json!("a\u{7}b"), json!("   "), json!(3)] {
        let req = Request::new(
            "cloud.machine.rename",
            json!({ "machine": "vm-alpha01", "displayName": bad }),
        );
        assert_eq!(s.handle(&req.key("n-1")).unwrap_err().code, "cmux.cloud.invalid_args", "{bad}");
    }
    let kind = Request::new("cloud.machine.create", json!({ "kind": "Bad Kind" })).key("n-2");
    assert_eq!(s.handle(&kind).unwrap_err().code, "cmux.cloud.invalid_args");
    assert!(s.control_plane().calls.is_empty());
}

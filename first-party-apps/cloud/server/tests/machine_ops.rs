//! Machine op guards and shapes against the vectors fake: keys, origins,
//! aliases, argument checks and typed records.

mod common;

use cmux_cloud::api::models::MachineStatus;
use cmux_cloud::ops::WatchEvent;
use cmux_cloud::{Origin, Request, Server};
use common::{FakeControlPlane, vm};
use serde_json::{Value, json};

fn server() -> Server<FakeControlPlane> {
    Server::new(FakeControlPlane::with(&[]))
}

fn size() -> Value {
    json!({ "cpu": 2, "memory_mb": 4096, "disk_mb": 16384 })
}

fn create(name: &str, key: &str) -> Request {
    Request::new("cloud.machine.create", json!({ "name": name, "size": size() }))
        .key(key)
        .origin(Origin::User)
}

#[test]
fn create_without_an_idempotency_key_is_refused() {
    let mut s = server();
    let req = Request::new("cloud.machine.create", json!({ "size": size() })).origin(Origin::User);
    assert_eq!(s.handle(&req).unwrap_err().code, "cmux.cloud.idempotency_key_required");
    assert!(s.control_plane().no_calls(), "nothing reached the backend");
}

#[test]
fn a_failed_attempt_still_holds_its_key_and_refused_args_free_it() {
    let mut s = server();
    s.control_plane_mut().wire.fail_next = 1;
    assert_eq!(
        s.handle(&create("new box", "k-3")).unwrap_err().code,
        "cmux.cloud.relay_unavailable"
    );
    let rename =
        Request::new("cloud.machine.rename", json!({ "machine": vm(1), "name": "x" })).key("k-3");
    assert_eq!(s.handle(&rename).unwrap_err().code, "cmux.cloud.idempotency_conflict");
    let bad = create("\u{7}bell", "key-create-1");
    assert_eq!(s.handle(&bad).unwrap_err().code, "cmux.cloud.invalid_args");
    assert!(
        s.handle(&create("new box", "key-create-1")).is_ok(),
        "refused args leave the key free"
    );
}

#[test]
fn the_same_key_for_other_args_is_a_local_conflict_with_no_call() {
    let mut s = server();
    s.handle(&create("new box", "key-create-1")).expect("create");
    let calls = s.control_plane().wire.calls.len();
    assert_eq!(
        s.handle(&create("other box", "key-create-1")).unwrap_err().code,
        "cmux.cloud.idempotency_conflict"
    );
    assert_eq!(s.control_plane().wire.calls.len(), calls, "the ledger answered");
}

#[test]
fn money_and_destructive_ops_need_origin_user() {
    let cases = [
        ("cloud.machine.create", json!({ "size": size() })),
        ("cloud.machine.resize", json!({ "machine": vm(1), "size": size() })),
        ("cloud.machine.delete", json!({ "machine": vm(1) })),
        ("cloud.snapshot.delete", json!({ "snapshot": "snap_s0000000000000000001" })),
        ("cloud.billing.checkout", json!({ "plan": "pro" })),
        ("cloud.migration.start", json!({})),
        ("cloud.machine.upgrade", json!({ "machine": vm(7) })),
    ];
    for (op, args) in cases {
        for origin in [Origin::Mcp, Origin::Cli, Origin::Script, Origin::Agent, Origin::Remote] {
            let mut s = server();
            let req = Request::new(op, args.clone()).origin(origin).key("u-1");
            assert_eq!(
                s.handle(&req).unwrap_err().code,
                "cmux.cloud.origin_refused",
                "{op} {origin:?}"
            );
            assert!(s.control_plane().no_calls(), "{op}");
        }
    }
}

#[test]
fn no_sign_in_at_the_host_maps_to_auth_required() {
    let mut s = server();
    s.handle(&Request::new("cloud.machine.list", json!({}))).expect("list");
    s.control_plane_mut().wire.signed_in = false;
    let err = s.handle(&Request::new("cloud.machine.list", json!({}))).unwrap_err();
    assert_eq!(err.code, "cmux.cloud.auth_required");
    assert!(s.projection().is_empty(), "a signed-out Mac shows no machines");
    let status = s.handle(&Request::new("cloud.auth.status", json!({}))).expect("status");
    assert_eq!(status["signedIn"], false);
}

#[test]
fn the_list_maps_to_typed_records() {
    let mut s = server();
    let out = s.handle(&Request::new("cloud.machine.list", json!({}))).expect("list");
    let machines: Vec<_> = s.projection().machines().collect();
    assert_eq!(machines.len(), 3);
    let first = machines[0];
    assert_eq!(first.id, vm(1));
    assert_eq!(first.status, MachineStatus::Running);
    assert_eq!(first.name.as_deref(), Some("build box"));
    assert_eq!(first.created_at, Some(1_790_000_001_000));
    assert_eq!(first.host.as_deref(), Some("host_h0000000000000000001"));
    assert_eq!(first.revision.as_str(), "7");
    assert_eq!(machines[1].status, MachineStatus::Paused);
    assert_eq!(out["revision"], 1, "the projection revision");
    assert_eq!(out["next_cursor"], Value::Null);
}

#[test]
fn a_mutation_updates_the_projection_at_once() {
    let mut s = server();
    s.handle(&Request::new("cloud.machine.list", json!({}))).expect("list");
    s.take_events();
    let before = s.projection().revision();
    let out = s
        .handle(
            &Request::new("cloud.machine.pause", json!({ "machine": vm(1) })).key("key-pause-1"),
        )
        .expect("pause");
    assert_eq!(out["machine"]["status"], "pausing");
    assert_eq!(out["revision"], before + 1);
    assert_eq!(s.projection().get(&vm(1)).expect("known").status, MachineStatus::Pausing);
    let events = s.take_events();
    assert!(matches!(&events[..], [WatchEvent::Upsert { machine, .. }] if machine.id == vm(1)));
    assert_eq!(s.control_plane().wire.count("cloud.machine.list"), 1, "no extra list read");
}

#[test]
fn start_answers_to_resume_and_the_relay_names() {
    for (name, args) in [
        ("cloud.machine.start", json!({ "machine": vm(2) })),
        ("cloud.machine.resume", json!({ "machine": vm(2) })),
        ("cmux.cloud.machine.start", json!({ "machine": vm(2) })),
        ("vm.start", json!({ "vm_id": vm(2) })),
        ("vm.resume", json!({ "vm_id": vm(2) })),
    ] {
        let mut s = server();
        let out = s.handle(&Request::new(name, args).key("key-start-1")).expect(name);
        assert_eq!(out["machine"]["status"], "starting", "{name}");
        assert_eq!(s.control_plane().ops(), ["cloud.machine.start"], "{name}");
    }
}

#[test]
fn relay_names_take_their_own_args() {
    let mut s = server();
    let delete = Request::new(
        "vm.snapshot.delete",
        json!({ "vm_id": vm(1), "snapshot_id": "snap_s0000000000000000001" }),
    )
    .key("key-snap-delete-1")
    .origin(Origin::User);
    assert_eq!(s.handle(&delete), Ok(json!({ "deleted": true })));
    assert_eq!(
        s.control_plane().wire.calls[0].params,
        json!({ "snapshot": "snap_s0000000000000000001" }),
        "a snapshot delete needs only the snapshot"
    );
}

#[test]
fn bad_args_are_refused_before_any_call() {
    let mut s = server();
    let bad = [
        ("cloud.machine.get", json!({ "machine": "../etc" })),
        ("cloud.machine.get", json!({ "machine": "-flag" })),
        ("cloud.machine.get", json!({})),
        ("cloud.machine.get", json!({ "machine": vm(1), "extra": 1 })),
        ("cloud.machine.connect_info", json!({ "machine": "a b" })),
        ("cloud.machine.list", json!({ "limit": "2" })),
        ("cloud.snapshot.list", json!({ "machine": 7 })),
    ];
    for (op, args) in bad {
        assert_eq!(
            s.handle(&Request::new(op, args.clone())).unwrap_err().code,
            "cmux.cloud.invalid_args",
            "{op} {args}"
        );
    }
    let mutations = [
        ("cloud.machine.create", json!({ "name": "x" })),
        ("cloud.machine.create", json!({ "size": {} })),
        ("cloud.machine.create", json!({ "size": { "cpu": 0 } })),
        ("cloud.machine.create", json!({ "size": { "gpu": 1 } })),
        ("cloud.machine.create", json!({ "size": size(), "name": "x".repeat(81) })),
        ("cloud.machine.create", json!({ "size": size(), "name": "  " })),
        ("cloud.machine.rename", json!({ "machine": vm(1) })),
        ("cloud.machine.idle_policy.set", json!({ "machine": vm(1), "idle_seconds": -1 })),
        ("cloud.billing.checkout", json!({ "plan": "pro plan" })),
    ];
    for (op, args) in mutations {
        let req = Request::new(op, args.clone()).key("bad-1").origin(Origin::User);
        assert_eq!(s.handle(&req).unwrap_err().code, "cmux.cloud.invalid_args", "{op} {args}");
    }
    assert!(s.control_plane().no_calls());
}

#[test]
fn reads_refuse_keys_and_unknown_ops_are_refused() {
    let mut s = server();
    let read = Request::new("cloud.machine.list", json!({})).key("k");
    assert_eq!(s.handle(&read).unwrap_err().code, "cmux.cloud.idempotency_key_forbidden");
    for gone in
        ["cloud.machine.stats", "cloud.snapshot.fork", "cloud.usage.get", "cloud.network.list"]
    {
        let err = s.handle(&Request::new(gone, json!({}))).unwrap_err();
        assert_eq!(err.code, "cmux.cloud.unknown_op", "{gone}");
    }
}

#[test]
fn a_name_is_trimmed_before_it_is_sent() {
    let mut s = server();
    let req =
        Request::new("cloud.machine.rename", json!({ "machine": vm(1), "name": "  renamed box " }))
            .key("key-rename-1");
    assert!(s.handle(&req).is_ok());
    assert_eq!(s.control_plane().wire.calls[0].params["name"], "renamed box");
}

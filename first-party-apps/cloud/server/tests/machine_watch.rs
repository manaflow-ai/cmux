//! `cloud.machine.watch`: the projection is the single writer of the
//! stream. Each projection change raises the revision once and queues one
//! event per changed record (`upsert` or `removed`) from the code path that
//! changed it. Mutation results carry the revision their change reached.

mod common;

use cmux_cloud::ops::WatchEvent;
use cmux_cloud::{Origin, Request, Server};
use common::FakeControlPlane;
use serde_json::{Value, json};

fn listed(fixtures: &[&str]) -> Server<FakeControlPlane> {
    let mut s = Server::new(FakeControlPlane::with(fixtures));
    s.handle(&Request::new("cloud.machine.list", json!({}))).expect("list");
    s.take_events();
    s
}

fn ids(events: &[WatchEvent]) -> Vec<(String, &'static str, u64)> {
    events
        .iter()
        .map(|e| match e {
            WatchEvent::Upsert { revision, machine } => (machine.id.clone(), "upsert", *revision),
            WatchEvent::Removed { revision, id } => (id.clone(), "removed", *revision),
        })
        .collect()
}

#[test]
fn watch_is_a_read_that_answers_the_current_revision() {
    let mut s = listed(&["vm-list"]);
    let out = s.handle(&Request::new("cloud.machine.watch", json!({}))).expect("watch");
    assert_eq!(out, json!({ "revision": 1 }));
    let keyed = Request::new("cmux.cloud.machine.watch", json!({})).key("w-1");
    assert_eq!(s.handle(&keyed).unwrap_err().code, "cmux.cloud.idempotency_key_forbidden");
    assert!(s.take_events().is_empty(), "a watch read changes nothing");
    assert_eq!(s.control_plane().count("GET", "/api/vm"), 1, "a watch read calls nothing");
}

#[test]
fn a_mutation_raises_the_revision_once_and_emits_one_event() {
    let mut s = listed(&["vm-list", "vm-pause"]);
    let before = s.projection().revision();
    let paused = s
        .handle(&Request::new("cloud.machine.pause", json!({ "machine": "vm-alpha01" })).key("p-1"))
        .expect("pause");
    assert_eq!(s.projection().revision(), before + 1);
    assert_eq!(paused["revision"], before + 1, "the result names the revision of its change");
    assert_eq!(paused["id"], "vm-alpha01", "machine fields stay at the top level");
    let events = s.take_events();
    assert_eq!(ids(&events), [("vm-alpha01".to_owned(), "upsert", before + 1)]);
    let WatchEvent::Upsert { machine, .. } = &events[0] else { unreachable!() };
    assert_eq!(machine.display_name.as_deref(), Some("build box"), "the event carries the record");
}

#[test]
fn a_replay_with_the_same_key_emits_nothing_new() {
    let mut s = listed(&["vm-list", "vm-pause"]);
    let pause = Request::new("cloud.machine.pause", json!({ "machine": "vm-alpha01" })).key("p-1");
    let first = s.handle(&pause).expect("pause");
    s.take_events();
    let revision = s.projection().revision();
    let again = s.handle(&pause).expect("replay");
    assert_eq!(first, again, "the replay answers the recorded result and revision");
    assert!(s.take_events().is_empty());
    assert_eq!(s.projection().revision(), revision);
}

#[test]
fn a_mutation_with_no_effect_keeps_the_revision() {
    let mut s = listed(&["vm-list", "vm-resume"]);
    // vm-alpha01 is running already: the answer changes nothing.
    s.control_plane_mut().respond(
        "POST",
        "/api/vm/vm-alpha01/resume",
        200,
        json!({ "id": "vm-alpha01", "status": "running" }),
    );
    let before = s.projection().revision();
    let out = s
        .handle(&Request::new("cloud.machine.start", json!({ "machine": "vm-alpha01" })).key("s-1"))
        .expect("start");
    assert_eq!(out["revision"], before);
    assert!(s.take_events().is_empty());
}

#[test]
fn a_refresh_that_drops_a_machine_emits_removed() {
    let mut s = listed(&["vm-list"]);
    let before = s.projection().revision();
    let mut body = FakeControlPlane::fixture_body("vm-list");
    body["vms"].as_array_mut().expect("vms").retain(|m| m["id"] != "vm-beta02");
    s.control_plane_mut().respond("GET", "/api/vm", 200, body);
    let out = s.handle(&Request::new("cloud.machine.list", json!({}))).expect("list");
    assert_eq!(out["revision"], before + 1);
    assert_eq!(ids(&s.take_events()), [("vm-beta02".to_owned(), "removed", before + 1)]);
}

#[test]
fn a_refresh_diff_emits_one_event_per_changed_record_under_one_revision() {
    let mut s = listed(&["vm-list"]);
    let before = s.projection().revision();
    let mut body = FakeControlPlane::fixture_body("vm-list");
    let vms = body["vms"].as_array_mut().expect("vms");
    vms.retain(|m| m["id"] != "vm-alpha01");
    vms[0]["status"] = json!("running");
    let mut fresh = vms[0].clone();
    fresh["id"] = json!("vm-new09");
    vms.push(fresh);
    s.control_plane_mut().respond("GET", "/api/vm", 200, body);
    s.handle(&Request::new("cloud.machine.list", json!({}))).expect("list");
    let r = before + 1;
    assert_eq!(
        ids(&s.take_events()),
        [
            ("vm-alpha01".to_owned(), "removed", r),
            ("vm-beta02".to_owned(), "upsert", r),
            ("vm-new09".to_owned(), "upsert", r),
        ]
    );
    assert_eq!(s.projection().revision(), r);
}

#[test]
fn a_refresh_with_no_change_emits_nothing() {
    let mut s = listed(&["vm-list"]);
    let before = s.projection().revision();
    let out = s.handle(&Request::new("cloud.machine.list", json!({}))).expect("list");
    assert_eq!(out["revision"], before);
    assert!(s.take_events().is_empty());
    s.handle(&Request::new("cloud.plan.get", json!({}))).expect("plan reads the same list");
    assert!(s.take_events().is_empty());
}

#[test]
fn delete_emits_removed() {
    // The delete result stays `{ok: true}` (C1 contract); the `removed`
    // event for the id is the echo that settles a delete intent.
    let mut s = listed(&["vm-list", "vm-delete"]);
    let before = s.projection().revision();
    let req = Request::new("cloud.machine.delete", json!({ "machine": "vm-alpha01" }))
        .origin(Origin::User)
        .key("d-1");
    let out = s.handle(&req).expect("delete");
    assert_eq!(out, json!({ "ok": true }));
    assert_eq!(ids(&s.take_events()), [("vm-alpha01".to_owned(), "removed", before + 1)]);
}

#[test]
fn every_machine_mutation_result_carries_a_revision() {
    let mut s =
        listed(&["vm-list", "vm-create", "vm-rename", "vm-resize", "vm-restore", "vm-fork"]);
    let cases: [(&str, Value); 5] = [
        ("cloud.machine.create", json!({ "displayName": "scratch" })),
        ("cloud.machine.rename", json!({ "machine": "vm-alpha01", "displayName": "renamed" })),
        ("cloud.machine.resize", json!({ "machine": "vm-alpha01", "cpu": 8 })),
        ("cloud.snapshot.restore", json!({ "snapshot": "snap-two" })),
        ("cloud.snapshot.fork", json!({ "machine": "vm-alpha01" })),
    ];
    for (i, (op, args)) in cases.into_iter().enumerate() {
        let out = s.handle(&Request::new(op, args).key(&format!("m-{i}"))).expect(op);
        assert_eq!(out["revision"], s.projection().revision(), "{op}");
    }
}

#[test]
fn a_partial_answer_for_an_unknown_machine_is_one_change() {
    let mut s = Server::new(FakeControlPlane::with(&["vm-get", "vm-pause"]));
    let out = s
        .handle(&Request::new("cloud.machine.pause", json!({ "machine": "vm-alpha01" })).key("p-9"))
        .expect("pause");
    assert_eq!(out["revision"], 1);
    let events = s.take_events();
    assert_eq!(ids(&events), [("vm-alpha01".to_owned(), "upsert", 1)]);
    let WatchEvent::Upsert { machine, .. } = &events[0] else { unreachable!() };
    assert_eq!(machine.status, cmux_cloud::api::models::MachineStatus::Paused);
}

#[test]
fn a_sign_out_removes_every_machine_under_one_revision() {
    let mut s = listed(&["vm-list"]);
    s.control_plane_mut().serve("unauthorized");
    assert!(s.handle(&Request::new("cloud.machine.list", json!({}))).is_err());
    assert_eq!(
        ids(&s.take_events()),
        [("vm-alpha01".to_owned(), "removed", 2), ("vm-beta02".to_owned(), "removed", 2)]
    );
}

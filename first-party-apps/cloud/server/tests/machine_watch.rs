//! `cloud.machine.watch`: the projection is the single writer of the
//! stream. Each projection change raises the revision once and queues one
//! event per changed record (`upsert` or `removed`) from the code path that
//! changed it. Mutation results carry the revision their change reached.
//! A full listing (first page to last) removes machines it did not see.

mod common;

use cmux_cloud::ops::WatchEvent;
use cmux_cloud::{Origin, Request, Server};
use common::{FakeControlPlane, WireFake, vm};
use serde_json::{Value, json};

fn listed() -> Server<FakeControlPlane> {
    let mut s = Server::new(FakeControlPlane::with(&[]));
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

/// The vectors' default list with `edit` applied, served for `list {}`.
fn relist(s: &mut Server<FakeControlPlane>, edit: impl FnOnce(&mut Vec<Value>)) {
    let doc = common::wire_common::vectors();
    let case = doc["cases"]
        .as_array()
        .expect("cases")
        .iter()
        .find(|c| c["name"] == "machine.list.default")
        .expect("default list")
        .clone();
    let mut value = case["responses"][0]["body"]["value"].clone();
    edit(value["machines"].as_array_mut().expect("machines"));
    s.control_plane_mut().wire.answer("cloud.machine.list", json!({}), None, value);
}

#[test]
fn watch_is_a_read_that_answers_the_current_revision() {
    let mut s = listed();
    let out = s.handle(&Request::new("cloud.machine.watch", json!({}))).expect("watch");
    assert_eq!(out, json!({ "revision": 1 }));
    let keyed = Request::new("cmux.cloud.machine.watch", json!({})).key("w-1");
    assert_eq!(s.handle(&keyed).unwrap_err().code, "cmux.cloud.idempotency_key_forbidden");
    assert!(s.take_events().is_empty(), "a watch read changes nothing");
    assert_eq!(s.control_plane().wire.calls.len(), 1, "a watch read calls nothing");
}

#[test]
fn a_mutation_raises_the_revision_once_and_emits_one_event() {
    let mut s = listed();
    let before = s.projection().revision();
    let paused = s
        .handle(
            &Request::new("cloud.machine.pause", json!({ "machine": vm(1) })).key("key-pause-1"),
        )
        .expect("pause");
    assert_eq!(s.projection().revision(), before + 1);
    assert_eq!(paused["revision"], before + 1, "the result names the revision of its change");
    let events = s.take_events();
    assert_eq!(ids(&events), [(vm(1), "upsert", before + 1)]);
    let WatchEvent::Upsert { machine, .. } = &events[0] else { unreachable!() };
    assert_eq!(machine.name.as_deref(), Some("build box"), "the event carries the record");
}

#[test]
fn a_replay_with_the_same_key_emits_nothing_new() {
    let mut s = listed();
    let pause = Request::new("cloud.machine.pause", json!({ "machine": vm(1) })).key("key-pause-1");
    let first = s.handle(&pause).expect("pause");
    s.take_events();
    let revision = s.projection().revision();
    let again = s.handle(&pause).expect("replay");
    assert_eq!(first, again, "the replay answers the recorded result and revision");
    assert!(s.take_events().is_empty());
    assert_eq!(s.projection().revision(), revision);
    assert_eq!(s.control_plane().wire.count("cloud.machine.pause"), 1, "replayed here");
}

#[test]
fn a_full_listing_that_drops_a_machine_emits_removed() {
    let mut s = listed();
    let before = s.projection().revision();
    relist(&mut s, |machines| machines.retain(|m| m["id"] != vm(2)));
    let out = s.handle(&Request::new("cloud.machine.list", json!({}))).expect("list");
    assert_eq!(out["revision"], before + 1);
    assert_eq!(ids(&s.take_events()), [(vm(2), "removed", before + 1)]);
}

#[test]
fn a_listing_diff_emits_one_event_per_changed_record_under_one_revision() {
    let mut s = listed();
    let before = s.projection().revision();
    relist(&mut s, |machines| {
        machines.retain(|m| m["id"] != vm(1));
        machines[0]["status"] = json!("running");
        machines[0]["revision"] = json!("5");
        let mut fresh = machines[0].clone();
        fresh["id"] = json!(vm(9));
        machines.push(fresh);
    });
    s.handle(&Request::new("cloud.machine.list", json!({}))).expect("list");
    let r = before + 1;
    assert_eq!(
        ids(&s.take_events()),
        [(vm(1), "removed", r), (vm(2), "upsert", r), (vm(9), "upsert", r)]
    );
    assert_eq!(s.projection().revision(), r);
}

#[test]
fn a_machine_newer_than_the_listing_is_kept() {
    let mut s = listed();
    // An event brought machine 8 at revision 45; a full listing read at
    // team revision 41 cannot have seen it, so it stays. Machines at or
    // below 41 that the listing did not see are gone.
    let (event, data) = WireFake::event("machine.upsert.new");
    s.team_event(&event, &data).expect("event");
    s.control_plane_mut().wire.answer(
        "cloud.machine.list",
        json!({}),
        None,
        json!({ "machines": [], "next_cursor": null, "revision": "41" }),
    );
    s.handle(&Request::new("cloud.machine.list", json!({}))).expect("list");
    assert!(s.projection().get(&vm(8)).is_some(), "newer than the listing");
    assert_eq!(s.projection().len(), 1, "older ones the listing missed are gone");
}

#[test]
fn a_listing_with_no_change_emits_nothing() {
    let mut s = listed();
    let before = s.projection().revision();
    let out = s.handle(&Request::new("cloud.machine.list", json!({}))).expect("list");
    assert_eq!(out["revision"], before);
    assert!(s.take_events().is_empty());
    s.handle(&Request::new("cloud.plan.get", json!({}))).expect("plan");
    assert!(s.take_events().is_empty(), "the plan read changes no machine");
}

#[test]
fn a_page_out_of_order_removes_nothing() {
    let mut s = listed();
    let out = s
        .handle(&Request::new("cloud.machine.list", json!({ "cursor": "cur_page2", "limit": 2 })))
        .expect("page 2");
    assert_eq!(out["next_cursor"], Value::Null);
    assert_eq!(s.projection().len(), 3, "a last page without its first proves nothing");
    assert!(s.take_events().is_empty());
}

#[test]
fn delete_emits_removed() {
    let mut s = listed();
    let before = s.projection().revision();
    let req = Request::new("cloud.machine.delete", json!({ "machine": vm(2) }))
        .origin(Origin::User)
        .key("key-delete-1");
    assert_eq!(s.handle(&req), Ok(json!({ "deleted": true })));
    assert_eq!(ids(&s.take_events()), [(vm(2), "removed", before + 1)]);
    // An older upsert after the delete never brings the machine back.
    let mut stale =
        common::wire_common::vectors()["cases"][0]["responses"][0]["body"]["value"]["machines"][1]
            .clone();
    stale["revision"] = json!("6");
    s.team_event("cloud.machine.upsert", &json!({ "machine": stale })).expect("event");
    assert!(s.projection().get(&vm(2)).is_none(), "the removal was at revision 6");
}

#[test]
fn every_machine_mutation_result_carries_a_revision() {
    let mut s = listed();
    let size = json!({ "cpu": 2, "memory_mb": 4096, "disk_mb": 16384 });
    let big = json!({ "cpu": 4, "memory_mb": 8192, "disk_mb": 32768 });
    let cases: [(&str, Value, &str); 6] = [
        ("cloud.machine.create", json!({ "name": "new box", "size": size }), "key-create-1"),
        (
            "cloud.machine.rename",
            json!({ "machine": vm(1), "name": "renamed box" }),
            "key-rename-1",
        ),
        ("cloud.machine.resize", json!({ "machine": vm(1), "size": big }), "key-resize-1"),
        (
            "cloud.machine.idle_policy.set",
            json!({ "machine": vm(1), "idle_seconds": 3600 }),
            "key-idle-1",
        ),
        (
            "cloud.snapshot.restore",
            json!({ "snapshot": "snap_s0000000000000000001", "name": "restored box" }),
            "key-restore-1",
        ),
        ("cloud.machine.upgrade", json!({ "machine": vm(7) }), "key-upgrade-1"),
    ];
    for (op, args, key) in cases {
        let out = s.handle(&Request::new(op, args).key(key).origin(Origin::User)).expect(op);
        assert_eq!(out["revision"], s.projection().revision(), "{op}");
    }
}

#[test]
fn a_sign_out_removes_every_machine_under_one_revision() {
    let mut s = listed();
    let out = s.handle(&Request::new("cloud.machine.list", json!({ "limit": 1 })));
    assert_eq!(out.unwrap_err().code, "cmux.cloud.auth_required");
    assert_eq!(
        ids(&s.take_events()),
        [(vm(1), "removed", 2), (vm(2), "removed", 2), (vm(3), "removed", 2)]
    );
}

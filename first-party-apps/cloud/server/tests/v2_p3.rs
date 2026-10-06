//! Open P3s from the v2 wire review: a sign-out forgets every replayable
//! result and every cached link fact, and each connect attempt starts a
//! paused machine with its own key.

mod attach_common;
mod common;
mod edge_common;

use attach_common::{FakeSpawner, FakeTransport, attach};
use cmux_cloud::{Request, Server};
use common::{FakeControlPlane, link_machine};
use edge_common::rig;
use serde_json::json;

#[test]
fn a_sign_out_forgets_replayable_results_and_cached_link_facts() {
    let mut rig = rig(&["vm-get", "connect-info-fs"]);
    rig.files.answer("fs.write", json!({ "entry": { "revision": "s2-m1" } }));
    let write = Request::new(
        "cloud.fs.write",
        json!({ "machine": "vm-alpha01", "path": "/home/cmux/a.txt", "dataBase64": "aGk=" }),
    )
    .key("w-1");
    rig.server.handle(&write).expect("write");
    // Signed out: an op answers auth_required.
    rig.server.control_plane_mut().wire.signed_in = false;
    let err = rig.server.handle(&Request::new("cloud.machine.list", json!({}))).unwrap_err();
    assert_eq!(err.code, "cmux.cloud.auth_required");
    rig.server.control_plane_mut().wire.signed_in = true;
    let reads_before = rig
        .server
        .control_plane()
        .ops()
        .iter()
        .filter(|o| *o == "cloud.machine.connect_info")
        .count();
    rig.server.handle(&write).expect("write again");
    assert_eq!(rig.files.ops(), ["fs.write", "fs.write"], "no replay of a result from before");
    let reads_after = rig
        .server
        .control_plane()
        .ops()
        .iter()
        .filter(|o| *o == "cloud.machine.connect_info")
        .count();
    assert_eq!(reads_after, reads_before + 1, "the link facts are read again after a sign-in");
}

#[test]
fn each_connect_attempt_starts_a_paused_machine_with_its_own_key() {
    let spawner = FakeSpawner::default();
    let mut s = Server::with_attach(
        FakeControlPlane::with(&["vm-list", "vm-resume"]),
        attach(&spawner, &FakeTransport::default()),
    );
    s.handle(&Request::new("cloud.machine.list", json!({}))).expect("list");
    let connect =
        Request::new("cloud.machine.connect", json!({ "machine": "vm-beta02" })).key("c-1");
    s.handle(&connect).expect("first connect");
    s.handle(
        &Request::new("cloud.machine.disconnect", json!({ "machine": "vm-beta02" })).key("d-1"),
    )
    .expect("disconnect");
    // The machine paused again (a team event), and the user retries with
    // the same intent key.
    let mut paused = link_machine("vm-beta02", "paused");
    paused["revision"] = json!("5");
    s.team_event("cloud.machine.upsert", &json!({ "machine": paused })).expect("event");
    s.handle(&connect).expect("second connect");
    let keys = s.control_plane().wire.keys("cloud.machine.start");
    assert_eq!(keys.len(), 2, "two starts: {keys:?}");
    assert_ne!(keys[0], keys[1], "each attempt has its own start key: {keys:?}");
}

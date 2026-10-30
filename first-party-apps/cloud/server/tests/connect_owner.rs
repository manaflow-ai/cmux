//! `cloud.machine.connect` answers the signed-in caller's `vm_kind` from the
//! Worker's `connect_info` for that link (cmux-platform#89): `owner` only on
//! the exact value, `team` otherwise, also from a Worker that predates it.
//! The answer belongs to one link generation: a new link reads it fresh,
//! never from an earlier link's cached read.

mod attach_common;
mod common;
mod edge_common;

use attach_common::{FakeSpawner, FakeTransport, attach};
use cmux_cloud::{Request, Server};
use common::FakeControlPlane;
use serde_json::{Value, json};

fn connect(s: &mut Server<FakeControlPlane>, key: &str) -> Value {
    let request =
        Request::new("cloud.machine.connect", json!({ "machine": "vm-alpha01" })).key(key);
    let answer = s.handle(&request).expect("connect");
    assert_eq!(answer["state"], "up", "{answer}");
    answer
}

fn connect_answer(names: &[&str]) -> Value {
    let spawner = FakeSpawner::default();
    let mut s = Server::with_attach(
        FakeControlPlane::with(names),
        attach(&spawner, &FakeTransport::default()),
    );
    connect(&mut s, "c-1")
}

#[test]
fn the_owner_answer_of_connect_info_reaches_the_connect_answer() {
    assert_eq!(connect_answer(&["vm-get", "connect-info-owner"])["vm_kind"], "owner");
}

#[test]
fn a_team_answer_is_team() {
    assert_eq!(connect_answer(&["vm-get", "connect-info-team"])["vm_kind"], "team");
}

#[test]
fn a_worker_without_vm_kind_answers_team() {
    assert_eq!(connect_answer(&["vm-get"])["vm_kind"], "team");
}

#[test]
fn the_answer_belongs_to_its_link_generation_and_a_new_link_reads_it_fresh() {
    let spawner = FakeSpawner::default();
    let mut s = Server::with_attach(
        FakeControlPlane::with(&["vm-get", "connect-info-owner"]),
        attach(&spawner, &FakeTransport::default()),
    );
    let first = connect(&mut s, "c-1");
    assert_eq!(first["vm_kind"], "owner");
    // The Worker's answer changes (another sign-in) while the link is up.
    s.control_plane_mut().set_vm_kind(Some("team"));
    let same = connect(&mut s, "c-2");
    assert_eq!(same["generation"], first["generation"], "the same link: {same}");
    assert_eq!(same["vm_kind"], "owner", "the answer of the link it goes over");
    // The link ends; the reconnect comes before any link event is drained,
    // so the old link's cached connect_info is still there.
    spawner.exit("vm-alpha01", 1);
    let next = connect(&mut s, "c-3");
    assert_ne!(next["generation"], first["generation"], "a new link: {next}");
    assert_eq!(next["vm_kind"], "team", "a new link never keeps an old link's answer");
}

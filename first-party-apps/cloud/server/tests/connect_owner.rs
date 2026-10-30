//! `cloud.machine.connect` answers the signed-in caller's `vm_kind` from the
//! Worker's `connect_info` for that link (cmux-platform#89): `owner` only on
//! the exact value, `team` otherwise, also from a Worker that predates it.

mod attach_common;
mod common;
mod edge_common;

use attach_common::{FakeSpawner, FakeTransport, attach};
use cmux_cloud::{Request, Server};
use common::FakeControlPlane;
use serde_json::{Value, json};

fn connect_answer(names: &[&str]) -> Value {
    let spawner = FakeSpawner::default();
    let mut s = Server::with_attach(
        FakeControlPlane::with(names),
        attach(&spawner, &FakeTransport::default()),
    );
    let request =
        Request::new("cloud.machine.connect", json!({ "machine": "vm-alpha01" })).key("c-1");
    let answer = s.handle(&request).expect("connect");
    assert_eq!(answer["state"], "up", "{answer}");
    answer
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

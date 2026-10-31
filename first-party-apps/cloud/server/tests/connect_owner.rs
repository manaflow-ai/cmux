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
fn an_up_carrier_reuses_the_owner_answer_for_the_same_identity() {
    let spawner = FakeSpawner::default();
    let mut s = Server::with_attach(
        FakeControlPlane::with(&["vm-get", "connect-info-owner"]),
        attach(&spawner, &FakeTransport::default()),
    );
    let first = connect(&mut s, "c-1");
    assert_eq!(first["vm_kind"], "owner");
    let reads = s.control_plane().wire.count("cloud.machine.connect_info");
    s.control_plane_mut().set_vm_kind(Some("team"));
    let same = connect(&mut s, "c-2");
    assert_eq!(same["generation"], first["generation"], "the same link: {same}");
    assert_eq!(same["vm_kind"], "owner", "the cached answer: {same}");
    assert_eq!(s.control_plane().wire.count("cloud.machine.connect_info"), reads);
}

#[test]
fn a_link_that_exits_during_the_session_exchange_cannot_return_its_cached_owner() {
    for unavailable in [false, true] {
        let spawner = FakeSpawner::default();
        let mut s = Server::with_attach(
            FakeControlPlane::with(&["vm-get", "connect-info-owner"]),
            attach(&spawner, &FakeTransport::default()),
        );
        assert_eq!(connect(&mut s, "c-1")["vm_kind"], "owner");
        let reads = s.control_plane().wire.count("cloud.machine.connect_info");
        let exiting = spawner.clone();
        s.control_plane_mut().on_next_session(move || exiting.exit("vm-alpha01", 1));
        if unavailable {
            s.control_plane_mut().fail_session_unavailable();
        }
        let error = s
            .handle(
                &Request::new("cloud.machine.connect", json!({ "machine": "vm-alpha01" }))
                    .key("c-2"),
            )
            .expect_err("a carrier that exited during session() must not be returned");
        assert_eq!(error.code, "cmux.cloud.link_down");
        assert!(matches!(
            s.attach().supervisor().state("vm-alpha01"),
            Some(cmux_cloud::link::LinkState::Down { .. })
        ));
        assert_eq!(spawner.spawns(), 1, "the failed connect does not restart the link");
        assert_eq!(s.control_plane().wire.count("cloud.machine.connect_info"), reads);
    }
}

#[test]
fn a_link_that_exits_during_connect_info_cannot_return_or_cache_its_owner() {
    let spawner = FakeSpawner::default();
    let mut s = Server::with_attach(
        FakeControlPlane::with(&["vm-get", "connect-info-owner"]),
        attach(&spawner, &FakeTransport::default()),
    );
    let first = connect(&mut s, "c-1");
    assert_eq!(first["vm_kind"], "owner");
    let reads = s.control_plane().wire.count("cloud.machine.connect_info");
    // Force an owner cache miss on the up carrier without restarting it.
    s.control_plane_mut().set_team("team_t0000000000000000002");
    let exiting = spawner.clone();
    s.control_plane_mut().on_next_connect_info(move || exiting.exit("vm-alpha01", 1));
    let error = s
        .handle(
            &Request::new("cloud.machine.connect", json!({ "machine": "vm-alpha01" }))
                .key("c-2"),
        )
        .expect_err("a carrier that exited during connect_info must not be returned");
    assert_eq!(error.code, "cmux.cloud.link_down");
    assert!(matches!(
        s.attach().supervisor().state("vm-alpha01"),
        Some(cmux_cloud::link::LinkState::Down { .. })
    ));
    assert_eq!(spawner.spawns(), 1);
    assert_eq!(s.control_plane().wire.count("cloud.machine.connect_info"), reads + 1);

    // Reconnect before draining link events: neither cache may preserve
    // the owner answer from the exchange that lost its carrier.
    s.control_plane_mut().set_vm_kind(Some("team"));
    let next = connect(&mut s, "c-3");
    assert_ne!(next["generation"], first["generation"]);
    assert_eq!(next["vm_kind"], "team");
    assert_eq!(s.control_plane().wire.count("cloud.machine.connect_info"), reads + 2);
}

#[test]
fn a_switched_identity_rereads_the_owner_answer() {
    let spawner = FakeSpawner::default();
    let mut s = Server::with_attach(
        FakeControlPlane::with(&["vm-get", "connect-info-owner"]),
        attach(&spawner, &FakeTransport::default()),
    );
    let first = connect(&mut s, "c-1");
    assert_eq!(first["vm_kind"], "owner");
    let reads = s.control_plane().wire.count("cloud.machine.connect_info");
    s.control_plane_mut().set_vm_kind(Some("team"));
    s.control_plane_mut().set_team("team_t0000000000000000002");
    let same = connect(&mut s, "c-2");
    assert_eq!(same["generation"], first["generation"], "the same link: {same}");
    assert_eq!(same["vm_kind"], "team", "the switched identity was reread: {same}");
    assert_eq!(s.control_plane().wire.count("cloud.machine.connect_info"), reads + 1);
}

#[test]
fn a_new_link_reads_the_answer_again() {
    let spawner = FakeSpawner::default();
    let mut s = Server::with_attach(
        FakeControlPlane::with(&["vm-get", "connect-info-owner"]),
        attach(&spawner, &FakeTransport::default()),
    );
    let first = connect(&mut s, "c-1");
    s.control_plane_mut().set_vm_kind(Some("owner"));
    // The link ends; the reconnect comes before any link event is drained.
    spawner.exit("vm-alpha01", 1);
    let next = connect(&mut s, "c-3");
    assert_ne!(next["generation"], first["generation"], "a new link: {next}");
    assert_eq!(next["vm_kind"], "owner");
}

#[test]
fn a_not_bound_or_protocol_error_fails_an_up_connect_closed() {
    for code in ["cloud.machine.not_bound", "vector.missing"] {
        let spawner = FakeSpawner::default();
        let mut s = Server::with_attach(
            FakeControlPlane::with(&["vm-get", "connect-info-owner"]),
            attach(&spawner, &FakeTransport::default()),
        );
        connect(&mut s, "c-1");
        s.control_plane_mut().set_team("team_t0000000000000000002");
        s.control_plane_mut().fail_connect_info(code);
        let error = s
            .handle(
                &Request::new("cloud.machine.connect", json!({ "machine": "vm-alpha01" }))
                    .key("c-2"),
            )
            .expect_err("a non-transient owner read must fail closed");
        let expected = if code == "vector.missing" {
            "cmux.cloud.protocol_error"
        } else {
            "cmux.cloud.not_bound"
        };
        assert_eq!(error.code, expected);
    }
}

#[test]
fn access_that_ended_fails_the_connect_and_revokes_the_up_link() {
    let spawner = FakeSpawner::default();
    let mut s = Server::with_attach(
        FakeControlPlane::with(&["vm-get", "connect-info-owner"]),
        attach(&spawner, &FakeTransport::default()),
    );
    assert_eq!(connect(&mut s, "c-1")["vm_kind"], "owner");
    s.control_plane_mut().set_team("team_t0000000000000000002");
    s.control_plane_mut().fail_connect_info("cloud.machine.not_found");
    let request =
        Request::new("cloud.machine.connect", json!({ "machine": "vm-alpha01" })).key("c-2");
    let refused = s.handle(&request).expect_err("no carrier once access ended");
    assert_eq!(refused.code, "cmux.cloud.not_found", "{refused:?}");
    let again = s.handle(&request.clone().key("c-3")).expect_err("the link stays revoked");
    assert_ne!(again.code, "", "{again:?}");
}

#[test]
fn a_sign_out_fails_the_connect_of_an_up_link_and_ends_it() {
    let spawner = FakeSpawner::default();
    let mut s = Server::with_attach(
        FakeControlPlane::with(&["vm-get", "connect-info-owner"]),
        attach(&spawner, &FakeTransport::default()),
    );
    assert_eq!(connect(&mut s, "c-1")["vm_kind"], "owner");
    s.control_plane_mut().wire.signed_in = false;
    let request =
        Request::new("cloud.machine.connect", json!({ "machine": "vm-alpha01" })).key("c-2");
    let refused = s.handle(&request).expect_err("no carrier after a sign-out");
    assert_eq!(refused.code, "cmux.cloud.auth_required", "{refused:?}");
    assert!(!spawner.log().terminated.is_empty(), "the link ended with the sign-in");
}

#[test]
fn an_unavailable_identity_read_answers_team_without_caching() {
    let spawner = FakeSpawner::default();
    let mut s = Server::with_attach(
        FakeControlPlane::with(&["vm-get", "connect-info-owner"]),
        attach(&spawner, &FakeTransport::default()),
    );
    let first = connect(&mut s, "c-1");
    assert_eq!(first["vm_kind"], "owner");
    let reads = s.control_plane().wire.count("cloud.machine.connect_info");
    s.control_plane_mut().fail_session_unavailable();
    let second = connect(&mut s, "c-2");
    assert_eq!(second["vm_kind"], "team");
    assert_eq!(s.control_plane().wire.count("cloud.machine.connect_info"), reads);
}

//! `cmux.terminal.connector/1` (mirror) for kind `cloud-vm`.

mod attach_common;
mod common;

use attach_common::{FakeSpawner, FakeTransport, attach};
use cmux_cloud::Server;
use cmux_cloud::connector::iface::{BackendError, ConnectRequest, TerminalConnector};
use common::FakeControlPlane;

fn server(spawner: &FakeSpawner) -> Server<FakeControlPlane> {
    Server::with_attach(
        FakeControlPlane::with(&["vm-get", "attach_endpoint_alpha"]),
        attach(spawner, &FakeTransport::default()),
    )
}

fn request(kind: &str, target: &str) -> ConnectRequest {
    ConnectRequest { kind: kind.into(), target: target.into(), actor: None }
}

#[test]
fn the_connector_refuses_kind_ssh() {
    let spawner = FakeSpawner::default();
    let mut s = server(&spawner);
    let err = s.connector().connect(request("ssh", "vm-alpha01")).err().expect("refused");
    assert_eq!(err, BackendError::KindRefused { kind: "ssh".into() });
    assert_eq!(spawner.spawns(), 0);
    assert!(s.control_plane().calls.is_empty(), "nothing reached the Cloud API");
}

#[test]
fn the_connector_declares_its_id_and_one_kind() {
    let spawner = FakeSpawner::default();
    let mut s = server(&spawner);
    let connector = s.connector();
    assert_eq!(connector.id().as_str(), "app:cmux/cloud/machine");
    let kinds: Vec<&str> = connector.kinds().iter().map(|k| k.as_str()).collect();
    assert_eq!(kinds, ["cloud-vm"]);
}

#[test]
fn connect_gives_at_most_one_carrier_per_target() {
    let spawner = FakeSpawner::default();
    let mut s = server(&spawner);
    let first = s.connector().connect(request("cloud-vm", "vm-alpha01")).expect("connect");
    let second = s.connector().connect(request("cloud-vm", "vm-alpha01")).expect("again");
    assert_eq!(first.carrier(), second.carrier());
    assert_eq!(first.carrier().id, "cloud-vm/vm-alpha01#1");
    assert_eq!(spawner.spawns(), 1);
}

#[test]
fn a_target_that_is_not_a_machine_id_is_refused_before_any_call() {
    let spawner = FakeSpawner::default();
    let mut s = server(&spawner);
    for target in ["../vm-alpha01", "vm-alpha01/attach", "-flag", ""] {
        let err = s.connector().connect(request("cloud-vm", target)).err().expect("refused");
        assert!(matches!(err, BackendError::Invalid(_)), "{target}: {err:?}");
    }
    assert!(s.control_plane().calls.is_empty());
    assert_eq!(spawner.spawns(), 0);
}

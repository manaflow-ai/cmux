//! The link slice (contract 1.7 and 2.4): attach dials the machine's
//! overlay host id through `cmux link dial`, and files go to the machine's
//! daemon on the link behind the `fs-v1` capability. No op reaches a classic
//! Cloud API route.

mod attach_common;
mod common;

use attach_common::{FakeSpawner, FakeTransport, Script, attach};
use cmux_cloud::link::LinkState;
use cmux_cloud::{Origin, Request, Server};
use common::FakeControlPlane;
use serde_json::json;

fn server(fixtures: &[&str], spawner: &FakeSpawner) -> Server<FakeControlPlane> {
    Server::with_attach(
        FakeControlPlane::with(fixtures),
        attach(spawner, &FakeTransport::default()),
    )
}

fn connect(machine: &str, key: &str) -> Request {
    Request::new("cloud.machine.connect", json!({ "machine": machine })).key(key)
}

fn no_classic_call(s: &Server<FakeControlPlane>) {
    assert!(s.control_plane().calls.is_empty(), "classic calls: {:?}", s.control_plane().calls);
}

#[test]
fn connect_dials_the_machine_host_id_through_cmux_link() {
    let spawner = FakeSpawner::default();
    let mut s = server(&["vm-get"], &spawner);
    let carrier = s.handle(&connect("vm-alpha01", "c-1")).expect("connect");
    assert_eq!(carrier["state"], "up");
    no_classic_call(&s);
    let log = spawner.log();
    assert_eq!(log.commands.len(), 1, "one carrier");
    assert_eq!(
        log.commands[0].args,
        ["link", "dial", "--host", "host-vm-alpha01"],
        "the carrier dials the host id, with no route and no credential"
    );
}

#[test]
fn a_machine_with_no_host_yet_is_not_bound_and_starts_no_carrier() {
    let spawner = FakeSpawner::default();
    let mut s = server(&["vm-get-unbound"], &spawner);
    let err = s.handle(&connect("vm-alpha01", "c-1")).unwrap_err();
    assert_eq!(err.code, "cmux.cloud.not_bound");
    assert_eq!(spawner.spawns(), 0);
    no_classic_call(&s);
}

#[test]
fn host_paused_starts_the_machine_once_and_dials_again() {
    let spawner = FakeSpawner::default();
    spawner.log().script.extend([Script::DialFailed("host_paused"), Script::Ready]);
    let mut s = server(&["vm-get", "vm-resume"], &spawner);
    let carrier = s.handle(&connect("vm-alpha01", "c-1")).expect("connect after start");
    assert_eq!(carrier["state"], "up");
    let starts =
        s.control_plane().ops().iter().filter(|op| *op == "cloud.machine.start").count();
    assert_eq!(starts, 1, "one start");
    assert_eq!(spawner.spawns(), 2, "a second dial after the start");
    no_classic_call(&s);
}

#[test]
fn dial_refusals_map_to_typed_errors() {
    for (code, expected, revoked) in [
        ("not_authorized", "cmux.cloud.forbidden", true),
        ("unknown_host", "cmux.cloud.not_found", true),
        ("unreachable", "cmux.cloud.link_down", false),
    ] {
        let spawner = FakeSpawner::default();
        spawner.log().script.push_back(Script::DialFailed(code));
        let mut s = server(&["vm-get"], &spawner);
        let err = s.handle(&connect("vm-alpha01", "c-1")).unwrap_err();
        assert_eq!(err.code, expected, "{code}");
        assert_eq!(err.retryable, !revoked, "{code}: retryable");
        let state = s.attach().supervisor().state("vm-alpha01").cloned();
        assert_eq!(matches!(state, Some(LinkState::Revoked { .. })), revoked, "{code}: {state:?}");
        assert_eq!(spawner.spawns(), 1, "{code}: no second dial");
    }
}

#[test]
fn files_need_the_daemon_fs_capability_and_never_use_classic_routes() {
    let spawner = FakeSpawner::default();
    let mut s = server(&["vm-get", "connect-info-nofs"], &spawner);
    for (name, args) in [
        ("cloud.fs.list", json!({ "machine": "vm-alpha01", "path": "/home/cmux" })),
        ("cloud.fs.stat", json!({ "machine": "vm-alpha01", "path": "/home/cmux/a.txt" })),
        ("cloud.fs.read", json!({ "machine": "vm-alpha01", "path": "/home/cmux/a.txt" })),
    ] {
        let err = s.handle(&Request::new(name, args)).unwrap_err();
        assert_eq!(err.code, "cmux.cloud.unsupported", "{name}");
        assert!(err.message.contains("fs-v1"), "{name}: names the capability: {}", err.message);
    }
    no_classic_call(&s);
    assert_eq!(spawner.spawns(), 0, "no dial without the capability");
}

#[test]
fn transfers_need_the_daemon_fs_capability() {
    let spawner = FakeSpawner::default();
    let mut s = server(&["vm-get", "connect-info-nofs"], &spawner);
    let folder = std::env::temp_dir().join(format!("cmux-link-dial-{}", std::process::id()));
    std::fs::create_dir_all(&folder).expect("scratch folder");
    let pushed = folder.join("push.txt");
    std::fs::write(&pushed, b"hello").expect("scratch file");
    let pulled = folder.join("pull.txt");
    for (name, local) in [("cloud.file.push", &pushed), ("cloud.file.pull", &pulled)] {
        let request = Request::new(
            name,
            json!({ "machine": "vm-alpha01", "localPath": local.to_str().unwrap(),
                "path": "/home/cmux/notes.txt" }),
        )
        .key(&format!("t-{name}"))
        .origin(Origin::User);
        let err = s.handle(&request).unwrap_err();
        assert_eq!(err.code, "cmux.cloud.unsupported", "{name}");
        assert!(err.message.contains("fs-v1"), "{name}: {}", err.message);
    }
    assert!(!pulled.exists(), "a refused pull writes nothing");
    no_classic_call(&s);
    let _ = std::fs::remove_dir_all(&folder);
}

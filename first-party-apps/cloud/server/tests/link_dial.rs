//! The link slice (contract 1.7 and 2.4): attach dials the machine's
//! overlay host id through `cmux link dial`, and files go to the machine's
//! daemon on the link behind the `fs-v1` capability. The classic Cloud API
//! channel no longer exists, so no op can reach it.

mod attach_common;
mod common;

use attach_common::{FakeSpawner, FakeTransport, attach};
use cmux_cloud::link::LinkState;
use cmux_cloud::link::dial::DialCode;
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

#[test]
fn connect_dials_the_machine_host_id_through_cmux_link() {
    let spawner = FakeSpawner::default();
    let mut s = server(&["vm-get"], &spawner);
    let carrier = s.handle(&connect("vm-alpha01", "c-1")).expect("connect");
    assert_eq!(carrier["state"], "up");
    let log = spawner.log();
    assert_eq!(log.commands.len(), 1, "one carrier");
    assert_eq!(
        log.commands[0].args,
        ["link", "dial", "--host", "host-vm-alpha01", "--socket", "/tmp/cmux-test/link.sock"],
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
}

/// Connect (the carrier listens), then its first stream is refused.
fn connect_then_refused(
    s: &mut Server<FakeControlPlane>,
    spawner: &FakeSpawner,
    key: &str,
    code: &str,
) {
    let carrier = s.handle(&connect("vm-alpha01", key)).expect("the carrier listens");
    assert_eq!(carrier["state"], "up");
    spawner.refuse("vm-alpha01", code);
    s.attach_mut().supervisor_mut().pump();
}

#[test]
fn host_paused_ends_the_link_and_the_next_connect_starts_the_machine_once() {
    let spawner = FakeSpawner::default();
    let mut s = server(&["vm-get", "vm-resume"], &spawner);
    connect_then_refused(&mut s, &spawner, "c-1", "host_paused");
    let supervisor = s.attach().supervisor();
    assert!(matches!(supervisor.state("vm-alpha01"), Some(LinkState::Down { .. })));
    assert_eq!(supervisor.refusal("vm-alpha01"), Some(&DialCode::HostPaused), "typed");
    let starts = |s: &Server<FakeControlPlane>| {
        s.control_plane().ops().iter().filter(|op| *op == "cloud.machine.start").count()
    };
    assert_eq!(starts(&s), 0, "the first connect saw a running record");
    // The next connect starts the machine once; its stream finds it paused again.
    connect_then_refused(&mut s, &spawner, "c-2", "host_paused");
    assert_eq!(starts(&s), 1);
    // A second paused answer in a row is an error once, never a loop.
    let err = s.handle(&connect("vm-alpha01", "c-3")).unwrap_err();
    assert_eq!(err.code, "cmux.cloud.machine_paused");
    assert_eq!(starts(&s), 1, "no start loop");
    // After that, a connect may start again.
    s.handle(&connect("vm-alpha01", "c-4")).expect("connect");
    assert_eq!(starts(&s), 2);
    assert_eq!(spawner.spawns(), 3);
}

#[test]
fn a_refusal_that_ends_access_revokes_the_link_typed() {
    for code in ["not_authorized", "unknown_host"] {
        let spawner = FakeSpawner::default();
        let mut s = server(&["vm-get"], &spawner);
        connect_then_refused(&mut s, &spawner, "c-1", code);
        let supervisor = s.attach().supervisor();
        assert!(
            matches!(supervisor.state("vm-alpha01"), Some(LinkState::Revoked { .. })),
            "{code}"
        );
        assert_eq!(supervisor.refusal("vm-alpha01").map(DialCode::as_str), Some(code));
        let err = s.handle(&connect("vm-alpha01", "c-2")).unwrap_err();
        assert_eq!(err.code, "cmux.cloud.link_revoked", "{code}");
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
    let _ = std::fs::remove_dir_all(&folder);
}

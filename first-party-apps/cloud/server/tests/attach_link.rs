//! The link supervisor through `cloud.machine.connect` and `disconnect`,
//! against the fake control plane and a fake link spawner.

mod attach_common;
mod common;

use attach_common::{FakeSpawner, FakeTransport, Script, attach, link_events, socket_for};
use cmux_cloud::connector::iface::CarrierEvent;
use cmux_cloud::link::{LinkState, LinkTag};
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
fn two_connects_for_one_machine_give_one_carrier_and_one_spawn() {
    let spawner = FakeSpawner::default();
    let mut s = server(&["vm-get"], &spawner);
    let first = s.handle(&connect("vm-alpha01", "c-1")).expect("connect");
    let second = s.handle(&connect("vm-alpha01", "c-2")).expect("second connect");
    assert_eq!(first, second, "one carrier");
    assert_eq!(first["carrier"], "cloud-vm/vm-alpha01#1");
    assert_eq!(first["state"], "up");
    let tag = LinkTag { machine: "vm-alpha01".into(), generation: 1 };
    assert_eq!(first["socket"], socket_for(&tag));
    assert_eq!(spawner.spawns(), 1, "one link process");
    assert_eq!(
        s.control_plane().ops(),
        ["cloud.machine.get", "cloud.machine.connect_info"],
        "one machine read and one connect_info read, no route call and no token"
    );
}

#[test]
fn a_paused_machine_is_started_first() {
    let spawner = FakeSpawner::default();
    let mut s = server(&["vm-list", "vm-resume"], &spawner);
    s.handle(&Request::new("cloud.machine.list", json!({}))).expect("list");
    s.handle(&connect("vm-beta02", "c-1")).expect("connect");
    assert_eq!(
        s.control_plane().ops(),
        ["cloud.machine.list", "cloud.machine.start", "cloud.machine.connect_info"],
        "start, then the readiness read"
    );
    assert_eq!(spawner.spawns(), 1);
}

#[test]
fn a_signed_out_connect_is_auth_required() {
    let spawner = FakeSpawner::default();
    let mut s = server(&["vm-get"], &spawner);
    s.control_plane_mut().wire.signed_in = false;
    let err = s.handle(&connect("vm-alpha01", "c-1")).unwrap_err();
    assert_eq!(err.code, "cmux.cloud.auth_required");
    assert_eq!(spawner.spawns(), 0, "no link process");
    assert!(s.projection().is_empty(), "a signed-out Mac shows no machines");
}

#[test]
fn link_exit_gives_down_retryable_and_a_later_connect_respawns_once() {
    let spawner = FakeSpawner::default();
    let mut s = server(&["vm-get"], &spawner);
    s.handle(&connect("vm-alpha01", "c-1")).expect("connect");
    spawner.exit("vm-alpha01", 1);
    let events = link_events(&mut s);
    assert!(
        events.iter().any(|e| matches!(
            e,
            CarrierEvent::Down { target, retryable: true, generation: 1, .. } if target == "vm-alpha01"
        )),
        "{events:?}"
    );
    assert!(matches!(
        s.attach().supervisor().state("vm-alpha01"),
        Some(LinkState::Down { retryable: true, .. })
    ));
    assert_eq!(spawner.spawns(), 1, "nothing reconnects by itself");
    let again = s.handle(&connect("vm-alpha01", "c-2")).expect("reconnect");
    assert_eq!(again["carrier"], "cloud-vm/vm-alpha01#2");
    s.handle(&connect("vm-alpha01", "c-3")).expect("still up");
    assert_eq!(spawner.spawns(), 2, "one respawn");
}

#[test]
fn a_link_that_exits_before_it_is_ready_is_down() {
    let spawner = FakeSpawner::default();
    spawner.log().script.push_back(Script::ExitEarly(3));
    let mut s = server(&["vm-get"], &spawner);
    let err = s.handle(&connect("vm-alpha01", "c-1")).unwrap_err();
    assert_eq!(err.code, "cmux.cloud.link_down");
    assert!(err.retryable);
    s.handle(&connect("vm-alpha01", "c-2")).expect("a later connect works");
    assert_eq!(spawner.spawns(), 2);
}

#[test]
fn revoked_does_not_respawn() {
    let spawner = FakeSpawner::default();
    let mut s = server(&["vm-get"], &spawner);
    s.handle(&connect("vm-alpha01", "c-1")).expect("connect");
    spawner.exit("vm-alpha01", 1);
    s.handle(&connect("vm-alpha01", "c-2")).expect("a new carrier listens");
    spawner.refuse("vm-alpha01", "not_authorized");
    let events = link_events(&mut s);
    assert!(events.iter().any(|e| matches!(e, CarrierEvent::Revoked { .. })), "{events:?}");
    let err = s.handle(&connect("vm-alpha01", "c-3")).unwrap_err();
    assert_eq!(err.code, "cmux.cloud.link_revoked");
    assert_eq!(spawner.spawns(), 2, "no dial after the revoke");
    // A disconnect forgets the revocation; the next connect dials again.
    s.handle(
        &Request::new("cloud.machine.disconnect", json!({ "machine": "vm-alpha01" })).key("d-1"),
    )
    .expect("disconnect");
    s.handle(&connect("vm-alpha01", "c-4")).expect("connect after disconnect");
    assert_eq!(spawner.spawns(), 3);
}

#[test]
fn revoke_all_stops_links_and_refuses_new_ones() {
    let spawner = FakeSpawner::default();
    let mut s = server(&["vm-get"], &spawner);
    s.handle(&connect("vm-alpha01", "c-1")).expect("connect");
    s.attach_mut().supervisor_mut().revoke_all("the app's permission was revoked");
    assert_eq!(spawner.log().terminated.len(), 1, "the link process ended");
    let err = s.handle(&connect("vm-alpha01", "c-2")).unwrap_err();
    assert_eq!(err.code, "cmux.cloud.link_revoked");
    assert_eq!(spawner.spawns(), 1);
}

#[test]
fn the_carrier_dials_the_host_id_and_carries_no_credential() {
    let spawner = FakeSpawner::default();
    let mut s = server(&["vm-get"], &spawner);
    s.handle(&connect("vm-alpha01", "c-1")).expect("connect");
    let log = spawner.log();
    let command = &log.commands[0];
    assert_eq!(command.binary.to_str(), Some("/opt/cmux/bin/cmux-tui"));
    let socket = command.local_socket.to_str().expect("utf8").to_owned();
    assert!(socket.starts_with("/tmp/cmux-test/cmux-link-") && socket.ends_with(".sock"));
    assert_eq!(command.args, ["link", "dial", "--host", "host-vm-alpha01"]);
    let all = format!("{:?} {:?}", command.args, command.env).to_lowercase();
    assert!(!all.contains("token"), "no token on argv or env: {all}");
}

#[test]
fn connect_without_link_settings_is_link_unavailable_and_calls_nothing() {
    let mut s = Server::new(FakeControlPlane::with(&["vm-get"]));
    let err = s.handle(&connect("vm-alpha01", "c-1")).unwrap_err();
    assert_eq!(err.code, "cmux.cloud.link_unavailable");
    assert!(s.control_plane().no_calls());
}

#[test]
fn connect_needs_an_idempotency_key_and_any_origin_may_call_it() {
    let spawner = FakeSpawner::default();
    let mut s = server(&["vm-get"], &spawner);
    let bare = Request::new("cloud.machine.connect", json!({ "machine": "vm-alpha01" }));
    assert_eq!(s.handle(&bare).unwrap_err().code, "cmux.cloud.idempotency_key_required");
    let from_mcp = connect("vm-alpha01", "c-1").origin(Origin::Mcp);
    s.handle(&from_mcp).expect("connect is not a person-only op");
}

#[test]
fn disconnect_ends_the_link_process_and_reports_down() {
    let spawner = FakeSpawner::default();
    let mut s = server(&["vm-get"], &spawner);
    s.handle(&connect("vm-alpha01", "c-1")).expect("connect");
    link_events(&mut s);
    let done = s
        .handle(
            &Request::new("cloud.machine.disconnect", json!({ "machine": "vm-alpha01" }))
                .key("d-1"),
        )
        .expect("disconnect");
    assert_eq!(done, json!({ "machine": "vm-alpha01", "disconnected": true }));
    assert_eq!(spawner.log().terminated.len(), 1);
    let events = link_events(&mut s);
    assert!(matches!(&events[..], [CarrierEvent::Down { retryable: true, .. }]), "{events:?}");
    // The old process's late exit changes nothing.
    spawner.exit("vm-alpha01", 0);
    assert!(link_events(&mut s).is_empty());
    assert!(s.attach().supervisor().state("vm-alpha01").is_none());
}

#[test]
fn a_retry_with_the_same_key_after_down_opens_a_new_link() {
    let spawner = FakeSpawner::default();
    let mut s = server(&["vm-get"], &spawner);
    let first = s.handle(&connect("vm-alpha01", "same-key")).expect("connect");
    spawner.exit("vm-alpha01", 1);
    let again = s.handle(&connect("vm-alpha01", "same-key")).expect("same key again");
    assert_ne!(first["carrier"], again["carrier"], "never a replayed dead carrier");
    assert_eq!(spawner.spawns(), 2);
}

#[test]
fn a_sign_out_on_attach_ends_every_link_without_revoking() {
    let spawner = FakeSpawner::default();
    let mut s = server(&["vm-list", "vm-resume", "vm-get"], &spawner);
    s.handle(&Request::new("cloud.machine.list", json!({}))).expect("list");
    s.handle(&connect("vm-beta02", "c-1")).expect("beta link");
    // A machine the projection does not know is read first: signed out.
    s.control_plane_mut().wire.signed_in = false;
    let err = s.handle(&connect("vm-gamma03", "c-2")).unwrap_err();
    assert_eq!(err.code, "cmux.cloud.auth_required");
    assert_eq!(spawner.log().terminated.len(), 1, "the beta link ended");
    assert!(s.attach().supervisor().state("vm-beta02").is_none(), "forgotten, not revoked");
}

/// The real carrier with `/bin/sh` standing in for `cmux link dial` (no
/// network): the script writes the dial's reply line on stderr, then
/// carries the stream on stdin and stdout.
#[cfg(unix)]
mod real_process {
    use cmux_cloud::link::dial::DialCode;
    use cmux_cloud::link::{CarrierSpawner, LinkCommand, LinkFailure, LinkSupervisor};
    use std::io::{Read, Write};
    use std::path::PathBuf;

    const OK: &str =
        r#"printf '%s\n' '{"ok":true,"path_state":"direct","relay_available":false}' >&2"#;

    fn command(script: &str, dir: &str) -> LinkCommand {
        // A short folder: a socket path has at most 104 bytes on macOS.
        let dir = PathBuf::from("/tmp").join(format!("cx-{dir}-{}", std::process::id()));
        LinkCommand {
            binary: PathBuf::from("/bin/sh"),
            args: vec!["-c".into(), script.into()],
            env: vec![("CMUX_TEST_DIAL".into(), "1".into())],
            state_dir: dir.join("state"),
            local_socket: dir.join("link.sock"),
        }
    }

    #[test]
    fn a_ready_carrier_carries_each_stream_over_one_dial() {
        let mut supervisor = LinkSupervisor::new(Box::new(CarrierSpawner));
        let script = format!("{OK}; exec cat");
        let command = command(&script, "ready");
        let carrier = supervisor.spawn_and_wait("vm-real01", &command).expect("carrier");
        assert_eq!(carrier.socket, command.local_socket);
        assert_eq!(carrier.id, "cloud-vm/vm-real01#1");
        let mut stream =
            std::os::unix::net::UnixStream::connect(&carrier.socket).expect("dial the carrier");
        stream.write_all(b"ping").expect("write");
        stream.shutdown(std::net::Shutdown::Write).expect("half close");
        let mut echoed = Vec::new();
        stream.read_to_end(&mut echoed).expect("read");
        assert_eq!(echoed, b"ping", "the dial child carries the bytes");
        supervisor.disconnect("vm-real01");
    }

    /// Opens one stream on the carrier, writes nothing, reads to the end.
    fn one_stream(socket: &std::path::Path) -> Vec<u8> {
        let mut stream = std::os::unix::net::UnixStream::connect(socket).expect("dial");
        stream.shutdown(std::net::Shutdown::Write).expect("half close");
        let mut out = Vec::new();
        let _ = stream.read_to_end(&mut out);
        out
    }

    /// Waits (tests may sleep) until generation 1 of `machine` ended.
    fn ended(supervisor: &mut LinkSupervisor, machine: &str) -> LinkFailure {
        for _ in 0..500 {
            supervisor.pump();
            if let Some(Err(failure)) = supervisor.outcome(machine, 1) {
                return failure;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        panic!("the link of {machine} did not end");
    }

    #[test]
    fn a_refused_stream_ends_the_link_with_the_typed_code() {
        let mut supervisor = LinkSupervisor::new(Box::new(CarrierSpawner));
        let script = r#"printf '%s\n' '{"ok":false,"error_code":"host_paused","path_state":"unreachable","relay_available":false}' >&2; exit 1"#;
        let carrier =
            supervisor.spawn_and_wait("vm-real02", &command(script, "paused")).expect("listening");
        assert!(one_stream(&carrier.socket).is_empty(), "the refused stream carries nothing");
        assert_eq!(ended(&mut supervisor, "vm-real02"), LinkFailure::Dial(DialCode::HostPaused));
    }

    #[test]
    fn a_dial_with_no_reply_line_ends_only_that_stream() {
        // An older or absent link writes no reply line: that stream ends,
        // the link stays up (only access-ending and paused refusals end it).
        let mut supervisor = LinkSupervisor::new(Box::new(CarrierSpawner));
        let carrier =
            supervisor.spawn_and_wait("vm-real03", &command("exit 7", "exit")).expect("listening");
        assert!(one_stream(&carrier.socket).is_empty());
        assert!(one_stream(&carrier.socket).is_empty(), "the next stream still dials");
        supervisor.pump();
        assert!(supervisor.carrier("vm-real03").is_some(), "the link is still up");
        supervisor.disconnect("vm-real03");
    }

    #[test]
    fn a_respawned_carrier_keeps_its_socket_file() {
        // The old carrier's end must never delete the new carrier's file at
        // the same path.
        let mut supervisor = LinkSupervisor::new(Box::new(CarrierSpawner));
        let script = format!("{OK}; exec cat");
        let command = command(&script, "respawn");
        supervisor.spawn_and_wait("vm-real06", &command).expect("first carrier");
        let generation = supervisor.respawn("vm-real06", &command).expect("respawn");
        let carrier = supervisor.wait_connect("vm-real06", generation).expect("second carrier");
        // Give the old accept thread time to end (tests may sleep).
        std::thread::sleep(std::time::Duration::from_millis(200));
        assert!(carrier.socket.exists(), "the new socket file is still there");
        let mut stream = std::os::unix::net::UnixStream::connect(&carrier.socket).expect("dial");
        stream.write_all(b"ok").expect("write");
        stream.shutdown(std::net::Shutdown::Write).expect("half close");
        let mut echoed = Vec::new();
        stream.read_to_end(&mut echoed).expect("read");
        assert_eq!(echoed, b"ok");
        supervisor.disconnect("vm-real06");
    }

    #[test]
    fn the_carrier_is_ready_without_any_dial() {
        // No probe: a dial would mint a link token for nothing.
        let mut supervisor = LinkSupervisor::new(Box::new(CarrierSpawner));
        let marker = std::env::temp_dir().join(format!("cx-dialed-marker-{}", std::process::id()));
        let script = format!("touch {}", marker.display());
        let carrier = supervisor.spawn_and_wait("vm-real04", &command(&script, "noprobe"));
        assert!(carrier.is_ok(), "{carrier:?}");
        assert!(!marker.exists(), "no dial ran before a stream");
        supervisor.disconnect("vm-real04");
    }

    #[test]
    fn the_dial_gets_a_cleared_environment() {
        // cargo sets CARGO_MANIFEST_DIR for this test process; the dial must not inherit it.
        assert!(std::env::var_os("CARGO_MANIFEST_DIR").is_some());
        let mut supervisor = LinkSupervisor::new(Box::new(CarrierSpawner));
        let script = format!(
            r#"test -z "${{CARGO_MANIFEST_DIR:-}}" && test -n "$CMUX_TEST_DIAL" && {OK} && printf clean"#
        );
        let carrier =
            supervisor.spawn_and_wait("vm-real05", &command(&script, "env")).expect("carrier");
        assert_eq!(one_stream(&carrier.socket), b"clean", "the dial saw only the command's env");
        supervisor.disconnect("vm-real05");
    }
}

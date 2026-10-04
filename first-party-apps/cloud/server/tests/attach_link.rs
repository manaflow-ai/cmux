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

const ENDPOINT: &str = "/api/vm/vm-alpha01/attach-endpoint";

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
    let mut s = server(&["vm-get", "attach_endpoint_alpha"], &spawner);
    let first = s.handle(&connect("vm-alpha01", "c-1")).expect("connect");
    let second = s.handle(&connect("vm-alpha01", "c-2")).expect("second connect");
    assert_eq!(first, second, "one carrier");
    assert_eq!(first["carrier"], "cloud-vm/vm-alpha01#1");
    assert_eq!(first["state"], "up");
    let tag = LinkTag { machine: "vm-alpha01".into(), generation: 1 };
    assert_eq!(first["socket"], socket_for(&tag));
    assert_eq!(spawner.spawns(), 1, "one link process");
    assert_eq!(s.control_plane().count("POST", ENDPOINT), 1, "one attach endpoint");
}

#[test]
fn a_paused_machine_is_started_first() {
    let spawner = FakeSpawner::default();
    let mut s = server(&["vm-list", "vm-resume", "attach_endpoint_beta"], &spawner);
    s.handle(&Request::new("cloud.machine.list", json!({}))).expect("list");
    s.handle(&connect("vm-beta02", "c-1")).expect("connect");
    assert_eq!(s.control_plane().ops(), ["cloud.machine.list", "cloud.machine.start"], "start");
    let calls: Vec<String> =
        s.control_plane().calls.iter().map(|c| format!("{} {}", c.method, c.path)).collect();
    assert_eq!(calls, ["POST /api/vm/vm-beta02/attach-endpoint"], "then attach");
    assert_eq!(spawner.spawns(), 1);
}

#[test]
fn attach_endpoint_401_is_auth_required() {
    let spawner = FakeSpawner::default();
    let mut s = server(&["vm-get", "attach_endpoint_401"], &spawner);
    let err = s.handle(&connect("vm-alpha01", "c-1")).unwrap_err();
    assert_eq!(err.code, "cmux.cloud.auth_required");
    assert_eq!(spawner.spawns(), 0, "no link process");
    assert!(s.projection().is_empty(), "a signed-out Mac shows no machines");
}

#[test]
fn link_exit_gives_down_retryable_and_a_later_connect_respawns_once() {
    let spawner = FakeSpawner::default();
    let mut s = server(&["vm-get", "attach_endpoint_alpha"], &spawner);
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
    let mut s = server(&["vm-get", "attach_endpoint_alpha"], &spawner);
    let err = s.handle(&connect("vm-alpha01", "c-1")).unwrap_err();
    assert_eq!(err.code, "cmux.cloud.link_down");
    assert!(err.retryable);
    s.handle(&connect("vm-alpha01", "c-2")).expect("a later connect works");
    assert_eq!(spawner.spawns(), 2);
}

#[test]
fn revoked_does_not_respawn() {
    let spawner = FakeSpawner::default();
    let mut s = server(&["vm-get", "attach_endpoint_alpha"], &spawner);
    s.handle(&connect("vm-alpha01", "c-1")).expect("connect");
    spawner.exit("vm-alpha01", 1);
    s.control_plane_mut().serve("attach_endpoint_403");
    let err = s.handle(&connect("vm-alpha01", "c-2")).unwrap_err();
    assert_eq!(err.code, "cmux.cloud.forbidden");
    let events = link_events(&mut s);
    assert!(events.iter().any(|e| matches!(e, CarrierEvent::Revoked { .. })), "{events:?}");
    let err = s.handle(&connect("vm-alpha01", "c-3")).unwrap_err();
    assert_eq!(err.code, "cmux.cloud.link_revoked");
    assert_eq!(spawner.spawns(), 1, "no new link process");
    assert_eq!(s.control_plane().count("POST", ENDPOINT), 2, "no attach call after revoke");
    // A disconnect forgets the revocation; the next connect asks again.
    s.handle(
        &Request::new("cloud.machine.disconnect", json!({ "machine": "vm-alpha01" })).key("d-1"),
    )
    .expect("disconnect");
    s.control_plane_mut().serve("attach_endpoint_alpha");
    s.handle(&connect("vm-alpha01", "c-4")).expect("connect after disconnect");
    assert_eq!(spawner.spawns(), 2);
}

#[test]
fn revoke_all_stops_links_and_refuses_new_ones() {
    let spawner = FakeSpawner::default();
    let mut s = server(&["vm-get", "attach_endpoint_alpha"], &spawner);
    s.handle(&connect("vm-alpha01", "c-1")).expect("connect");
    s.attach_mut().supervisor_mut().revoke_all("the app's permission was revoked");
    assert_eq!(spawner.log().terminated.len(), 1, "the link process ended");
    let err = s.handle(&connect("vm-alpha01", "c-2")).unwrap_err();
    assert_eq!(err.code, "cmux.cloud.link_revoked");
    assert_eq!(spawner.spawns(), 1);
}

#[test]
fn the_link_argv_is_the_swift_argv_and_carries_no_token() {
    let spawner = FakeSpawner::default();
    let mut s = server(&["vm-get", "attach_endpoint_alpha"], &spawner);
    s.handle(&connect("vm-alpha01", "c-1")).expect("connect");
    let log = spawner.log();
    let command = &log.commands[0];
    assert_eq!(command.binary.to_str(), Some("/opt/cmux/bin/cmux-tui"));
    let socket = command.local_socket.to_str().expect("utf8").to_owned();
    assert!(socket.starts_with("/tmp/cmux-test/cmux-link-") && socket.ends_with(".sock"));
    let expected: Vec<String> = [
        "remote",
        "connect",
        "ws://10.200.0.2:1337/v1/link",
        "--device-name",
        "test-mac",
        "--state-dir",
        "/tmp/cmux-test/link-state",
        "--local-socket",
        &socket,
        "--headless",
        "--json",
        "--exit-with-parent",
        "--lanes",
        "single",
        "--connect-timeout-seconds",
        "20",
        "--carrier",
        "--wireguard-hub",
        "/tmp/cmux-test/wg-hub.sock",
    ]
    .iter()
    .map(|a| (*a).to_owned())
    .collect();
    assert_eq!(command.args, expected);
    let all = format!("{:?} {:?}", command.args, command.env);
    assert!(!all.contains("fake-attach-token"), "no token on argv or env");
    let attach_call = s.control_plane().calls.iter().find(|c| c.path == ENDPOINT).expect("call");
    assert_eq!(attach_call.body, Some(json!({ "transport": "cmux-remote" })));
}

#[test]
fn a_route_that_reads_as_a_flag_is_refused_before_any_spawn() {
    let spawner = FakeSpawner::default();
    let mut s = server(&["vm-get", "attach_endpoint_bad_route"], &spawner);
    let err = s.handle(&connect("vm-alpha01", "c-1")).unwrap_err();
    assert_eq!(err.code, "cmux.cloud.bad_response");
    assert!(!err.message.contains("fake-attach-token"), "no token in the error");
    assert_eq!(spawner.spawns(), 0);
}

#[test]
fn connect_without_link_settings_is_link_unavailable_and_calls_nothing() {
    let mut s = Server::new(FakeControlPlane::with(&["vm-get", "attach_endpoint_alpha"]));
    let err = s.handle(&connect("vm-alpha01", "c-1")).unwrap_err();
    assert_eq!(err.code, "cmux.cloud.link_unavailable");
    assert!(s.control_plane().no_calls());
}

#[test]
fn connect_needs_an_idempotency_key_and_any_origin_may_call_it() {
    let spawner = FakeSpawner::default();
    let mut s = server(&["vm-get", "attach_endpoint_alpha"], &spawner);
    let bare = Request::new("cloud.machine.connect", json!({ "machine": "vm-alpha01" }));
    assert_eq!(s.handle(&bare).unwrap_err().code, "cmux.cloud.idempotency_key_required");
    let from_mcp = connect("vm-alpha01", "c-1").origin(Origin::Mcp);
    s.handle(&from_mcp).expect("connect is not a person-only op");
}

#[test]
fn disconnect_ends_the_link_process_and_reports_down() {
    let spawner = FakeSpawner::default();
    let mut s = server(&["vm-get", "attach_endpoint_alpha"], &spawner);
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
    let mut s = server(&["vm-get", "attach_endpoint_alpha"], &spawner);
    let first = s.handle(&connect("vm-alpha01", "same-key")).expect("connect");
    spawner.exit("vm-alpha01", 1);
    let again = s.handle(&connect("vm-alpha01", "same-key")).expect("same key again");
    assert_ne!(first["carrier"], again["carrier"], "never a replayed dead carrier");
    assert_eq!(spawner.spawns(), 2);
}

#[test]
fn a_sign_out_on_attach_ends_every_link_without_revoking() {
    let spawner = FakeSpawner::default();
    let mut s =
        server(&["vm-list", "vm-resume", "attach_endpoint_beta", "attach_endpoint_401"], &spawner);
    s.handle(&Request::new("cloud.machine.list", json!({}))).expect("list");
    s.handle(&connect("vm-beta02", "c-1")).expect("beta link");
    let err = s.handle(&connect("vm-alpha01", "c-2")).unwrap_err();
    assert_eq!(err.code, "cmux.cloud.auth_required");
    assert_eq!(spawner.log().terminated.len(), 1, "the beta link ended");
    assert!(s.attach().supervisor().state("vm-beta02").is_none(), "forgotten, not revoked");
}

/// The real spawner with `/bin/sh` standing in for `cmux-tui` (no network).
#[cfg(unix)]
mod real_process {
    use cmux_cloud::link::{LinkCommand, LinkFailure, LinkSupervisor, ProcessSpawner};
    use std::path::PathBuf;

    fn command(script: &str, dir: &str) -> LinkCommand {
        let dir = std::env::temp_dir().join(format!("cmux-c2-{dir}-{}", std::process::id()));
        LinkCommand {
            binary: PathBuf::from("/bin/sh"),
            args: vec!["-c".into(), script.into()],
            env: vec![("CMUX_REMOTE_STATE_DIR".into(), dir.join("state").display().to_string())],
            state_dir: dir.join("state"),
            local_socket: dir.join("link.sock"),
        }
    }

    #[test]
    fn a_ready_line_gives_the_carrier_and_the_exit_is_reported() {
        let mut supervisor = LinkSupervisor::new(Box::new(ProcessSpawner));
        let ready =
            r#"printf '%s\n' '{"event":"connection-snapshot","local_socket":"/tmp/c2.sock"}'"#;
        let carrier =
            supervisor.spawn_and_wait("vm-real01", &command(ready, "ready")).expect("carrier");
        assert_eq!(carrier.socket, PathBuf::from("/tmp/c2.sock"));
        assert_eq!(carrier.id, "cloud-vm/vm-real01#1");
    }

    #[test]
    fn an_early_exit_is_down_with_its_status() {
        let mut supervisor = LinkSupervisor::new(Box::new(ProcessSpawner));
        let err = supervisor.spawn_and_wait("vm-real02", &command("exit 7", "exit")).unwrap_err();
        match err {
            LinkFailure::Down { retryable: true, reason } => {
                assert!(reason.contains('7'), "{reason}");
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn a_link_that_never_gets_ready_is_ended_and_down() {
        let mut supervisor = LinkSupervisor::new(Box::new(ProcessSpawner))
            .with_ready_deadline(std::time::Duration::from_millis(300));
        let err =
            supervisor.spawn_and_wait("vm-real04", &command("exec sleep 30", "stall")).unwrap_err();
        match err {
            LinkFailure::Down { retryable: true, reason } => {
                assert!(reason.contains("no connection"), "{reason}");
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn the_child_gets_a_cleared_environment() {
        // cargo sets CARGO_MANIFEST_DIR for this test process; the link must not inherit it.
        assert!(std::env::var_os("CARGO_MANIFEST_DIR").is_some());
        let mut supervisor = LinkSupervisor::new(Box::new(ProcessSpawner));
        let script = r#"test -z "${CARGO_MANIFEST_DIR:-}" && test -n "$CMUX_REMOTE_STATE_DIR" && printf '%s\n' '{"event":"connection-snapshot","local_socket":"/tmp/c2-env.sock"}'"#;
        let carrier = supervisor.spawn_and_wait("vm-real03", &command(script, "env"));
        assert!(carrier.is_ok(), "{carrier:?}");
    }
}

//! `cmux.terminal.connector/1` (mirror of the landed interface,
//! cmux-tui/crates/cmux-app-host/interfaces/cmux.terminal.connector/1.json)
//! for kind `cloud-vm`: `connect {kind, target, open_token} -> {channel,
//! window_bytes}`, `close {channel}`, `end {channel, lost}` and the shared
//! errors and local ids of `cmux.terminal.backend/1`.

mod attach_common;
mod common;

use attach_common::{FakeSpawner, FakeTransport, attach};
use cmux_cloud::Server;
use cmux_cloud::connector::iface::{
    BackendError, ConnectRequest, ConnectorEvent, LocalId, Lost, TerminalConnector,
};
use cmux_cloud::rescue::iface::OpenToken;
use common::FakeControlPlane;

fn server(spawner: &FakeSpawner) -> Server<FakeControlPlane> {
    Server::with_attach(
        FakeControlPlane::with(&["vm-get"]),
        attach(spawner, &FakeTransport::default()),
    )
}

fn request(kind: &str, target: &str) -> ConnectRequest {
    ConnectRequest {
        kind: kind.into(),
        target: target.into(),
        open_token: OpenToken("open-token-test".into()),
    }
}

const CHANNEL: &str = "cloud-vm/vm-alpha01#1";

#[test]
fn the_connector_denies_kind_ssh() {
    let spawner = FakeSpawner::default();
    let mut s = server(&spawner);
    let err = s.connector().connect(request("ssh", "vm-alpha01")).err().expect("refused");
    assert!(matches!(err, BackendError::Denied { .. }), "a kind not in options.kinds: {err:?}");
    assert_eq!(spawner.spawns(), 0);
    assert!(s.control_plane().no_calls(), "nothing reached the Cloud API");
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
fn local_ids_follow_the_landed_pattern() {
    // `^[a-z][a-zA-Z0-9-]{0,63}$`: at most 64 characters.
    let longest = format!("a{}", "b".repeat(63));
    assert!(LocalId::new(&longest).is_ok(), "64 characters are accepted");
    assert!(LocalId::new(&format!("{longest}c")).is_err(), "65 characters are refused");
    assert!(LocalId::new("cloudVm-2").is_ok(), "mixed case after the first letter");
    for bad in ["", "Cloud", "9vm", "-vm", "vm_1", "vm.1", "vm 1", "vé"] {
        assert!(LocalId::new(bad).is_err(), "{bad:?}");
    }
}

#[test]
fn connect_answers_a_channel_and_a_window() {
    let spawner = FakeSpawner::default();
    let mut s = server(&spawner);
    let link = s.connector().connect(request("cloud-vm", "vm-alpha01")).expect("connect");
    assert_eq!(link.channel(), CHANNEL, "the channel is the connector link");
    assert_eq!(link.window_bytes(), 256 * 1024, "the default window");
    assert_eq!(link.carrier().id, CHANNEL);
}

#[test]
fn connect_gives_at_most_one_channel_per_target() {
    let spawner = FakeSpawner::default();
    let mut s = server(&spawner);
    let first = s.connector().connect(request("cloud-vm", "vm-alpha01")).expect("connect");
    let second = s.connector().connect(request("cloud-vm", "vm-alpha01")).expect("again");
    assert_eq!(first.channel(), second.channel());
    assert_eq!(first.carrier(), second.carrier());
    assert_eq!(spawner.spawns(), 1);
}

#[test]
fn close_ends_the_link_once_and_a_second_close_is_invalid() {
    let spawner = FakeSpawner::default();
    let mut s = server(&spawner);
    s.connector().connect(request("cloud-vm", "vm-alpha01")).expect("connect");
    s.connector().close(CHANNEL).expect("close");
    assert_eq!(spawner.log().terminated.len(), 1, "the link process ended");
    let events = s.connector().take_events();
    assert!(
        matches!(&events[..], [ConnectorEvent::End { channel, .. }] if channel == CHANNEL),
        "one end for the channel: {events:?}"
    );
    let again = s.connector().close(CHANNEL);
    assert!(matches!(again, Err(BackendError::Invalid { .. })), "{again:?}");
    assert!(s.connector().take_events().is_empty());
}

#[test]
fn a_link_exit_ends_the_channel_with_lost() {
    let spawner = FakeSpawner::default();
    let mut s = server(&spawner);
    s.connector().connect(request("cloud-vm", "vm-alpha01")).expect("connect");
    spawner.exit("vm-alpha01", 1);
    let events = s.connector().take_events();
    match &events[..] {
        [ConnectorEvent::End { channel, lost: Lost { reason, retryable: true } }] => {
            assert_eq!(channel, CHANNEL);
            assert!(!reason.is_empty());
        }
        other => panic!("one retryable end, no up event: {other:?}"),
    }
}

#[test]
fn a_revoke_ends_the_live_channel_and_later_connects_are_denied() {
    let spawner = FakeSpawner::default();
    let mut s = server(&spawner);
    s.connector().connect(request("cloud-vm", "vm-alpha01")).expect("connect");
    s.attach_mut().supervisor_mut().revoke_all("the app's permission was revoked");
    let events = s.connector().take_events();
    assert!(
        matches!(&events[..], [ConnectorEvent::End { channel, lost: Lost { retryable: false, .. } }]
            if channel == CHANNEL),
        "{events:?}"
    );
    let err = s.connector().connect(request("cloud-vm", "vm-alpha01")).err().expect("refused");
    assert!(matches!(err, BackendError::Denied { .. }), "a revoked target: {err:?}");
    // A second revoke ends nothing new.
    s.attach_mut().supervisor_mut().revoke_all("again");
    assert!(s.connector().take_events().is_empty());
}

#[test]
fn a_target_that_is_not_a_machine_id_is_refused_before_any_call() {
    let spawner = FakeSpawner::default();
    let mut s = server(&spawner);
    for target in ["../vm-alpha01", "vm-alpha01/attach", "-flag", ""] {
        let err = s.connector().connect(request("cloud-vm", target)).err().expect("refused");
        assert!(matches!(err, BackendError::Invalid { .. }), "{target}: {err:?}");
    }
    assert!(s.control_plane().no_calls());
    assert_eq!(spawner.spawns(), 0);
}

#[test]
fn a_missing_or_empty_open_token_is_refused_before_any_call_or_spawn() {
    let spawner = FakeSpawner::default();
    let mut s = server(&spawner);
    for token in ["", "   "] {
        let mut req = request("cloud-vm", "vm-alpha01");
        req.open_token = OpenToken(token.into());
        let answer = s.connector().connect(req).map(|link| link.channel().to_owned());
        assert!(matches!(answer, Err(BackendError::Invalid { .. })), "{token:?}: {answer:?}");
    }
    assert_eq!(spawner.spawns(), 0, "no link process");
    assert!(s.control_plane().no_calls(), "nothing reached the Cloud API");
}

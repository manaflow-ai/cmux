//! SSH-specific behavior: host key refusal before any byte, handles, the
//! registry id and the PTY details. Generic interface behavior is in
//! conformance.rs.

mod common;

use common::{Trust, fixture, request};
use ssh_terminal::iface::{
    BackendError, ByteTerminal, Close, Grid, Input, Signal, TerminalBackend,
};
use ssh_terminal::{ANSWERS_QUERIES, SSH_KIND};
use std::sync::atomic::Ordering;

const GRID: Grid = Grid { cols: 80, rows: 24 };

fn refused_reason(trust: Trust) -> (String, common::Fixture) {
    let mut f = fixture(trust);
    let result = f.backend.open(request(SSH_KIND, "t-key", GRID));
    let Err(BackendError::Unavailable { reason, retryable }) = result.map(|_| ()) else {
        panic!("open must be refused for {trust:?}");
    };
    assert!(!retryable, "a host key refusal is not retried by itself");
    (reason, f)
}

fn assert_nothing_flowed(f: &common::Fixture) {
    let log = f.server.log();
    assert_eq!(log.connections, 1, "the key exchange happened: {log:?}");
    assert_eq!(log.auth_attempts, 0, "no auth after a refused key: {log:?}");
    assert_eq!(log.channels, 0, "no channel after a refused key: {log:?}");
    assert!(log.input.is_empty() && log.pty.is_none(), "no byte flowed: {log:?}");
    assert_eq!(f.credential.signs.load(Ordering::SeqCst), 0, "the credential never signed");
}

#[test]
fn unknown_host_key_is_refused_before_any_byte() {
    let (reason, f) = refused_reason(Trust::Unknown);
    assert!(reason.starts_with("host-key-unknown SHA256:"), "{reason}");
    assert_nothing_flowed(&f);
}

#[test]
fn changed_host_key_is_refused_before_any_byte() {
    let (reason, f) = refused_reason(Trust::Changed);
    assert!(reason.starts_with("host-key-changed SHA256:"), "{reason}");
    assert_nothing_flowed(&f);
}

#[test]
fn unknown_connection_handle_never_connects() {
    let mut f = fixture(Trust::Known);
    let mut req = request(SSH_KIND, "t-handle", GRID);
    req.target = "conn_other".into();
    let refused = f.backend.open(req).err();
    assert!(matches!(refused, Some(BackendError::Revoked { .. })), "{refused:?}");
    assert_eq!(f.server.log().connections, 0);
}

#[test]
fn known_key_authenticates_through_the_credential_handle() {
    let mut f = fixture(Trust::Known);
    let t = f.backend.open(request(SSH_KIND, "t-auth", GRID)).expect("open");
    assert!(f.credential.signs.load(Ordering::SeqCst) >= 1, "the handle signed the auth");
    let log = f.server.wait_for("the pty", |l| l.pty.is_some());
    assert_eq!(log.pty, Some((80, 24)));
    t.close(Close::Now).expect("close");
}

#[test]
fn command_and_cwd_are_refused() {
    let mut f = fixture(Trust::Known);
    let mut req = request(SSH_KIND, "t-cmd", GRID);
    req.command = Some(vec!["rm".into(), "-rf".into(), "/".into()]);
    assert!(matches!(f.backend.open(req).err(), Some(BackendError::Unsupported(_))));
    assert_eq!(f.server.log().connections, 0);
}

#[test]
fn signal_reaches_the_server() {
    let mut f = fixture(Trust::Known);
    let t = f.backend.open(request(SSH_KIND, "t-sig", GRID)).expect("open");
    t.signal(Signal::Interrupt).expect("signal");
    f.server.wait_for("INT", |l| l.signals.iter().any(|s| s == "INT"));
}

#[test]
fn identity_and_capabilities() {
    let f = fixture(Trust::Known);
    assert_eq!(f.backend.id().as_str(), "app:example/ssh-terminal/ssh");
    let kinds: Vec<&str> = f.backend.kinds().iter().map(|k| k.as_str()).collect();
    assert_eq!(kinds, ["ssh"]);
    let caps = f.backend.capabilities();
    assert!(caps.resize && caps.signals && caps.exit_status && caps.resume && !caps.cwd_reports);
    assert_eq!(caps.max_write_bytes, 64 * 1024);
    assert!(
        !std::hint::black_box(ANSWERS_QUERIES),
        "plain SSH: the local session host answers DA/DSR"
    );
}

#[test]
fn oversized_and_far_ahead_writes_are_refused() {
    let mut f = fixture(Trust::Known);
    let t = f.backend.open(request(SSH_KIND, "t-big", GRID)).expect("open");
    let big = Input { seq: 0, bytes: vec![b'x'; 64 * 1024 + 1] };
    assert!(matches!(t.write(big), Err(BackendError::Invalid(_))));
    let ahead = Input { seq: 10_000, bytes: b"x".to_vec() };
    assert!(matches!(t.write(ahead), Err(BackendError::Invalid(_))));
    assert!(f.server.log().input.is_empty());
}

#[test]
fn a_terminal_id_is_opened_once() {
    let mut f = fixture(Trust::Known);
    let _t: Box<dyn ByteTerminal> =
        f.backend.open(request(SSH_KIND, "t-once", GRID)).expect("open");
    let again = f.backend.open(request(SSH_KIND, "t-once", GRID)).err();
    assert!(matches!(again, Some(BackendError::Invalid(_))), "{again:?}");
}

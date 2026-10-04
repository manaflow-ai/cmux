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

// --- Review regressions (backpressure, leaks, stale handles, tokens, RSA). ---

/// Writes until the backend refuses; returns the refusal. Fails if a write
/// blocks for longer than the wait (the old code waited forever).
fn write_until_refused(t: Box<dyn ByteTerminal>) -> (Box<dyn ByteTerminal>, BackendError) {
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let chunk = vec![b'w'; 32 * 1024];
        for seq in 1.. {
            if let Err(error) = t.write(Input { seq, bytes: chunk.clone() }) {
                let _ = tx.send((t, error));
                return;
            }
        }
    });
    rx.recv_timeout(std::time::Duration::from_secs(20)).expect("a write blocked")
}

#[test]
fn writes_never_block_while_output_is_not_taken() {
    let mut f = fixture(Trust::Known);
    let t = f.backend.open(request(SSH_KIND, "t-flood", GRID)).expect("open");
    t.write(Input { seq: 0, bytes: b"flood 8192\n".to_vec() }).expect("write");
    let (mut t, refused) = write_until_refused(t);
    assert!(
        matches!(refused, BackendError::Unavailable { retryable: true, .. }),
        "a full queue is a retryable answer: {refused:?}"
    );
    let events = common::events_until(t.as_mut(), "8 MiB", |e| common::output(e).len() >= 8 << 20);
    assert!(common::output(&events).iter().all(|&b| b == b'f'));
}

#[test]
fn closing_a_terminal_with_untaken_output_drops_the_connection() {
    let mut f = fixture(Trust::Known);
    let t = f.backend.open(request(SSH_KIND, "t-close-full", GRID)).expect("open");
    t.write(Input { seq: 0, bytes: b"flood 4096\n".to_vec() }).expect("write");
    f.server.wait_for("the flood command", |l| common::contains(&l.input, "flood"));
    std::thread::sleep(std::time::Duration::from_millis(200));
    t.close(Close::Now).expect("close");
    f.server.wait_for("the connection to end", |l| l.closed_connections == 1);
}

#[test]
fn an_ended_session_drops_its_connection_without_close() {
    let mut f = fixture(Trust::Known);
    let mut t = f.backend.open(request(SSH_KIND, "t-ended", GRID)).expect("open");
    t.write(Input { seq: 0, bytes: b"exit 0\n".to_vec() }).expect("write");
    common::events_until(t.as_mut(), "exit", |e| {
        e.iter().any(|e| matches!(e, ssh_terminal::iface::ByteEvent::Exit(_)))
    });
    f.server.wait_for("the connection to end", |l| l.closed_connections == 1);
}

#[test]
fn a_stale_handle_never_touches_a_new_terminal_with_the_same_id() {
    let mut f = fixture(Trust::Known);
    let old = f.backend.open(request(SSH_KIND, "t-same", GRID)).expect("open");
    old.close(Close::Now).expect("close");
    let new = f.backend.open(request(SSH_KIND, "t-same", GRID)).expect("open again");
    assert_eq!(old.close(Close::Now), Err(BackendError::Closed));
    drop(old);
    // The new terminal is still registered: a drop detaches it and its
    // token resumes it.
    let token = new.resume_token().expect("token");
    drop(new);
    let mut again = f.backend.resume(&token).expect("resume");
    again.write(Input { seq: 0, bytes: b"echo alive\n".to_vec() }).expect("write");
    common::events_until(again.as_mut(), "alive", |e| {
        common::contains(&common::output(e), "alive")
    });
}

#[test]
fn a_resume_token_needs_its_nonce() {
    let mut f = fixture(Trust::Known);
    let t = f.backend.open(request(SSH_KIND, "t-nonce", GRID)).expect("open");
    let token = t.resume_token().expect("token").0;
    drop(t);
    let guessed = ssh_terminal::iface::ResumeToken("ssh:t-nonce@0#0".into());
    let mut lost = f.backend.resume(&guessed).expect("resume answers");
    let events = common::events_until(lost.as_mut(), "lost", |e| !e.is_empty());
    assert!(matches!(events.as_slice(), [ssh_terminal::iface::ByteEvent::Lost(_)]));
    assert!(!token.ends_with("#0"), "the token carries a random nonce");
}

#[test]
fn detached_sessions_past_the_limit_are_closed() {
    let mut f = fixture(Trust::Known);
    let mut tokens = Vec::new();
    for i in 0..=ssh_terminal::MAX_DETACHED {
        let t = f.backend.open(request(SSH_KIND, &format!("t-d{i}"), GRID)).expect("open");
        tokens.push(t.resume_token().expect("token"));
    }
    f.server.wait_for("the oldest connection to end", |l| l.closed_connections == 1);
    let mut first = f.backend.resume(&tokens[0]).expect("resume answers");
    let events = common::events_until(first.as_mut(), "lost", |e| !e.is_empty());
    assert!(matches!(events.as_slice(), [ssh_terminal::iface::ByteEvent::Lost(_)]));
    let mut last = f.backend.resume(tokens.last().expect("last")).expect("resume");
    last.write(Input { seq: 0, bytes: b"echo kept\n".to_vec() }).expect("write");
    common::events_until(last.as_mut(), "kept", |e| common::contains(&common::output(e), "kept"));
}

#[test]
fn rsa_keys_sign_with_a_sha2_hash() {
    let mut f = common::fixture_with(Trust::Known, common::rsa_key());
    let t = f.backend.open(request(SSH_KIND, "t-rsa", GRID)).expect("open with an rsa key");
    let hash = *f.credential.last_hash.lock().expect("hash");
    assert!(
        matches!(hash, Some(russh::keys::HashAlg::Sha256 | russh::keys::HashAlg::Sha512)),
        "{hash:?}"
    );
    t.close(Close::Now).expect("close");
}

#[test]
fn calls_from_inside_an_async_runtime_are_refused_not_a_panic() {
    let f = fixture(Trust::Known);
    let runtime = tokio::runtime::Builder::new_current_thread().build().expect("runtime");
    let mut backend = f.backend;
    let refused = runtime.block_on(async move {
        let refused = backend.open(request(SSH_KIND, "t-async", GRID)).err();
        drop(backend);
        refused
    });
    assert!(matches!(refused, Some(BackendError::Unsupported(_))), "{refused:?}");
}

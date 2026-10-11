//! SSH-specific behavior over the host-owned channel: the open token and
//! the PTY reach the host, the typed host key refusal, no signing, bounded
//! buffers, the exit shape, stale handles and resume tokens. Generic
//! interface behavior is in conformance.rs.

mod common;

use common::{FINGERPRINT, HANDLE, Trust, contains, events_until, fixture, output, ssh_request};
use ssh_terminal::iface::{
    BackendError, ByteEvent, ByteTerminal, ChannelOpenRequest, Close, ExitStatus, Grid,
    HostKeyRefusal, Input, MAX_EXIT_MESSAGE, OpenToken, PtyRequest, ResumeRequest, ResumeToken,
    Signal, TerminalBackend,
};
use ssh_terminal::{DEFAULT_TERM, MAX_BUFFERED_BYTES, MAX_DETACHED, MAX_UNREAD, MAX_WRITE_BYTES};

fn input(seq: u64, text: &str) -> Input {
    Input { seq, bytes: text.as_bytes().to_vec() }
}

/// Host ops that exist. There is no signing op and no key op.
const HOST_OPS: [&str; 4] = ["open", "resize", "signal", "close"];

#[test]
fn open_passes_the_open_token_and_the_pty_to_the_host_and_never_signs() {
    let mut f = fixture(Trust::Known);
    let mut req = ssh_request(&f, "t-open");
    req.grid = Grid::new(100, 30);
    req.env = vec![("TERM".into(), "xterm-ghostty".into()), ("LANG".into(), "C".into())];
    let token = req.open_token.clone();
    let t = f.backend.open(req).expect("open");
    let log = f.host.log();
    let want = ChannelOpenRequest {
        connection: HANDLE.into(),
        open_token: token,
        pty: PtyRequest { term: "xterm-ghostty".into(), cols: 100, rows: 30 },
        command: None,
    };
    assert_eq!(log.opens, vec![want], "the handle, token and pty pass through unchanged");
    assert_eq!(log.channels, 1);
    assert!(log.ops.iter().all(|op| HOST_OPS.contains(op)), "only channel ops: {:?}", log.ops);
    t.close(Close::Now).expect("close");
}

#[test]
fn the_default_term_and_a_command_pass_through() {
    let mut f = fixture(Trust::Known);
    let mut req = ssh_request(&f, "t-cmd");
    req.command = Some(vec!["htop".into(), "-d".into(), "10".into()]);
    let _t = f.backend.open(req).expect("open");
    let open = &f.host.log().opens[0];
    assert_eq!(open.pty.term, DEFAULT_TERM);
    assert_eq!(open.command, Some(vec!["htop".into(), "-d".into(), "10".into()]));
}

#[test]
fn cwd_is_unsupported_and_reaches_no_host_op() {
    let mut f = fixture(Trust::Known);
    let mut req = ssh_request(&f, "t-cwd");
    req.cwd = Some("/tmp".into());
    assert_eq!(f.backend.open(req).err(), Some(BackendError::Unsupported));
    assert!(f.host.log().ops.is_empty());
}

fn assert_host_key_refusal(trust: Trust, decision: HostKeyRefusal) {
    let mut f = fixture(trust);
    let refused = f.backend.open(ssh_request(&f, "t-key")).err();
    assert_eq!(
        refused,
        Some(BackendError::HostKey { decision, fingerprint: FINGERPRINT.into() }),
        "the typed refusal passes through unchanged"
    );
    let log = f.host.log();
    assert_eq!(log.ops, ["open"], "nothing after the refused open: {log:?}");
    assert_eq!(log.channels, 0, "no channel after a refused key");
    assert!(log.input.is_empty() && log.grids.is_empty(), "no byte reached the shell: {log:?}");
    // After the user accepts, the same backend opens the same terminal id;
    // no event of the refused open ever shows up.
    f.host.set_trust(Trust::Known);
    let mut t = f.backend.open(ssh_request(&f, "t-key")).expect("open after accept");
    assert!(t.take_events().is_empty(), "no output event from the refused open");
    assert_eq!(f.host.log().channels, 1);
}

#[test]
fn an_unknown_host_key_is_a_typed_refusal_before_any_byte() {
    assert_host_key_refusal(Trust::Unknown, HostKeyRefusal::Unknown);
}

#[test]
fn a_changed_host_key_is_a_typed_refusal_before_any_byte() {
    assert_host_key_refusal(Trust::Changed, HostKeyRefusal::Changed);
}

#[test]
fn a_reused_open_token_is_refused_by_the_host() {
    let mut f = fixture(Trust::Known);
    let req = ssh_request(&f, "t-reuse");
    let again = req.clone();
    f.backend.open(req).expect("open").close(Close::Now).expect("close");
    let refused = f.backend.open(again).err();
    assert!(matches!(refused, Some(BackendError::Denied { .. })), "{refused:?}");
    assert_eq!(f.host.log().channels, 1);
}

#[test]
fn an_unknown_connection_handle_is_denied() {
    let mut f = fixture(Trust::Known);
    let mut req = ssh_request(&f, "t-handle");
    req.target = "conn_other".into();
    let refused = f.backend.open(req).err();
    assert!(matches!(refused, Some(BackendError::Denied { .. })), "{refused:?}");
    assert_eq!(f.host.log().channels, 0);
}

#[test]
fn an_exit_signal_gives_the_full_exit_shape_with_a_bounded_message() {
    let mut f = fixture(Trust::Known);
    let mut t = f.backend.open(ssh_request(&f, "t-die")).expect("open");
    t.write(input(0, "die TERM\n")).expect("write");
    let events = events_until(t.as_mut(), "exit", |e| e.iter().any(common::is_end));
    let Some(ByteEvent::Exit(exit)) = events.last() else { panic!("{events:?}") };
    let message = exit.message.clone().expect("message");
    // 3-byte characters: the cut lands on the char boundary below 4 KiB.
    assert_eq!(message.len(), MAX_EXIT_MESSAGE - MAX_EXIT_MESSAGE % 3, "{} bytes", message.len());
    let want = ExitStatus {
        code: None,
        signal: Some("TERM".into()),
        core_dumped: true,
        message: Some(message),
    };
    assert_eq!(exit, &want);
}

#[test]
fn an_ended_channel_is_closed_on_the_host() {
    let mut f = fixture(Trust::Known);
    let mut t = f.backend.open(ssh_request(&f, "t-ended")).expect("open");
    t.write(input(0, "exit 0\n")).expect("write");
    events_until(t.as_mut(), "exit", |e| e.iter().any(common::is_end));
    assert_eq!(f.host.log().closes, 1, "the backend releases the ended channel");
}

#[test]
fn graceful_close_sends_buffered_input_first_and_close_now_drops_it() {
    for (how, sent) in [(Close::Graceful, true), (Close::Now, false)] {
        let mut f = fixture(Trust::Known);
        let t = f.backend.open(ssh_request(&f, "t-close")).expect("open");
        f.host.stall_input(true);
        t.write(input(0, "echo bye\n")).expect("buffered");
        f.host.stall_input(false);
        t.close(how).expect("close");
        let log = f.host.log();
        assert_eq!(log.input.is_empty(), !sent, "{how:?}: {log:?}");
        assert_eq!(log.ops.last(), Some(&"close"), "{how:?}: close comes last");
        assert_eq!(log.closes, 1);
    }
}

#[test]
fn a_full_input_buffer_is_a_retryable_answer_and_keeps_order() {
    let mut f = fixture(Trust::Known);
    let mut t = f.backend.open(ssh_request(&f, "t-full")).expect("open");
    f.host.stall_input(true);
    let chunk = vec![b'w'; 32 * 1024];
    let mut accepted = 0;
    let refused = loop {
        match t.write(Input { seq: accepted, bytes: chunk.clone() }) {
            Ok(()) => accepted += 1,
            Err(error) => break error,
        }
    };
    assert!(
        matches!(refused, BackendError::Unavailable { retryable: true, .. }),
        "a full buffer is a retryable answer: {refused:?}"
    );
    let buffered = accepted as usize * chunk.len();
    assert!(buffered <= MAX_BUFFERED_BYTES, "the buffer is bounded: {buffered}");
    assert!(f.host.log().input.is_empty());
    f.host.stall_input(false);
    t.take_events();
    t.write(Input { seq: accepted, bytes: b"!".to_vec() }).expect("room again");
    let log = f.host.wait_for("every chunk", |l| l.input.len() == buffered + 1);
    assert_eq!(log.input.last(), Some(&b'!'), "the refused write changed nothing");
}

#[test]
fn resize_and_signal_wait_behind_buffered_input() {
    let mut f = fixture(Trust::Known);
    let mut t = f.backend.open(ssh_request(&f, "t-ordered")).expect("open");
    f.host.stall_input(true);
    t.write(input(0, "echo a\n")).expect("buffered");
    t.resize(Grid::new(90, 20)).expect("resize queued");
    t.signal(Signal::Hangup).expect("signal queued");
    f.host.stall_input(false);
    t.take_events();
    let log = f.host.log();
    assert_eq!(log.ops, ["open", "resize", "signal"], "{log:?}");
    assert_eq!(log.input, b"echo a\n");
    assert_eq!(log.grids.last(), Some(&(90, 20)));
    assert_eq!(log.signals, ["HUP"]);
}

#[test]
fn output_waits_in_the_host_while_the_session_host_does_not_read() {
    let mut f = fixture(Trust::Known);
    let mut t = f.backend.open(ssh_request(&f, "t-flood")).expect("open");
    t.write(input(0, "flood 1024\n")).expect("write");
    let first = t.take_events();
    assert!(output(&first).len() <= MAX_UNREAD, "one take is bounded: {}", output(&first).len());
    let all =
        events_until(t.as_mut(), "1 MiB", |e| output(e).len() + output(&first).len() >= 1 << 20);
    assert!(output(&all).iter().all(|&b| b == b'f'));
}

#[test]
fn oversized_and_far_ahead_writes_are_refused() {
    let mut f = fixture(Trust::Known);
    let t = f.backend.open(ssh_request(&f, "t-big")).expect("open");
    let big = Input { seq: 0, bytes: vec![b'x'; MAX_WRITE_BYTES + 1] };
    assert!(matches!(t.write(big), Err(BackendError::Invalid { .. })));
    let ahead = Input { seq: 10_000, bytes: b"x".to_vec() };
    assert!(matches!(t.write(ahead), Err(BackendError::Invalid { .. })));
    assert!(f.host.log().input.is_empty());
}

#[test]
fn a_terminal_id_is_opened_once() {
    let mut f = fixture(Trust::Known);
    let _t: Box<dyn ByteTerminal> = f.backend.open(ssh_request(&f, "t-once")).expect("open");
    let again = f.backend.open(ssh_request(&f, "t-once")).err();
    assert!(matches!(again, Some(BackendError::Invalid { .. })), "{again:?}");
    assert_eq!(f.host.log().channels, 1, "the second open reached no host op");
}

#[test]
fn identity_and_capabilities() {
    let f = fixture(Trust::Known);
    assert_eq!(f.backend.id().as_str(), "app:manaflow-ai/ssh-terminal/ssh");
    let kinds: Vec<&str> = f.backend.kinds().iter().map(|k| k.as_str()).collect();
    assert_eq!(kinds, ["ssh"]);
    let caps = f.backend.capabilities();
    assert!(caps.resize && caps.signals && caps.exit_status && caps.resume);
    assert!(!caps.cwd_reports);
    assert!(!caps.answers_queries, "plain SSH: the local session host answers DA/DSR");
    assert_eq!(caps.max_write_bytes as usize, MAX_WRITE_BYTES);
}

#[test]
fn a_stale_handle_never_touches_a_new_terminal_with_the_same_id() {
    let mut f = fixture(Trust::Known);
    let old = f.backend.open(ssh_request(&f, "t-same")).expect("open");
    old.close(Close::Now).expect("close");
    let new = f.backend.open(ssh_request(&f, "t-same")).expect("open again");
    assert!(matches!(old.close(Close::Now), Err(BackendError::Invalid { .. })));
    drop(old);
    // The new terminal is still registered: a drop detaches it and its
    // token resumes it.
    let token = new.resume_token().expect("token");
    drop(new);
    let request = ResumeRequest { resume_token: token, open_token: f.host.issue_token() };
    let mut again = f.backend.resume(request).expect("resume").terminal;
    again.write(input(0, "echo alive\n")).expect("write");
    events_until(again.as_mut(), "alive", |e| contains(&output(e), "alive"));
}

#[test]
fn a_resume_token_needs_its_nonce() {
    let mut f = fixture(Trust::Known);
    let t = f.backend.open(ssh_request(&f, "t-nonce")).expect("open");
    let token = t.resume_token().expect("token").0;
    drop(t);
    let guessed = ResumeToken("ssh:t-nonce@0#0".into());
    let request = ResumeRequest { resume_token: guessed, open_token: f.host.issue_token() };
    let mut lost = f.backend.resume(request).expect("resume answers").terminal;
    let events = events_until(lost.as_mut(), "lost", |e| !e.is_empty());
    assert!(matches!(events.as_slice(), [ByteEvent::Lost { retryable: false, .. }]));
    assert!(!token.ends_with("#0"), "the token carries a random nonce");
}

#[test]
fn resume_without_an_open_token_is_invalid() {
    let mut f = fixture(Trust::Known);
    let t = f.backend.open(ssh_request(&f, "t-notoken")).expect("open");
    let token = t.resume_token().expect("token");
    drop(t);
    let request = ResumeRequest { resume_token: token, open_token: OpenToken(String::new()) };
    assert!(matches!(f.backend.resume(request).err(), Some(BackendError::Invalid { .. })));
}

#[test]
fn detached_sessions_past_the_limit_are_closed() {
    let mut f = fixture(Trust::Known);
    let mut tokens = Vec::new();
    for i in 0..=MAX_DETACHED {
        let t = f.backend.open(ssh_request(&f, &format!("t-d{i}"))).expect("open");
        tokens.push(t.resume_token().expect("token"));
    }
    assert_eq!(f.host.log().closes, 1, "the oldest detached channel is closed");
    let resume = |f: &mut common::Fixture, token: &ResumeToken| {
        let request =
            ResumeRequest { resume_token: token.clone(), open_token: f.host.issue_token() };
        f.backend.resume(request).expect("resume answers").terminal
    };
    let mut first = resume(&mut f, &tokens[0]);
    let events = events_until(first.as_mut(), "lost", |e| !e.is_empty());
    assert!(matches!(events.as_slice(), [ByteEvent::Lost { .. }]));
    let mut last = resume(&mut f, tokens.last().expect("last"));
    last.write(input(0, "echo kept\n")).expect("write");
    events_until(last.as_mut(), "kept", |e| contains(&output(e), "kept"));
}

#[test]
fn dropping_the_backend_closes_every_channel() {
    let mut f = fixture(Trust::Known);
    let _a = f.backend.open(ssh_request(&f, "t-a")).expect("open");
    let b = f.backend.open(ssh_request(&f, "t-b")).expect("open");
    drop(b);
    let host = f.host.clone();
    drop(f.backend);
    assert_eq!(host.log().closes, 2);
    assert!(matches!(_a.close(Close::Now), Err(BackendError::Invalid { .. })));
    assert_eq!(host.log().closes, 2, "each channel is closed once");
}

#[test]
fn a_refused_signal_leaves_the_shell_running() {
    let mut f = fixture(Trust::Known);
    let mut t = f.backend.open(ssh_request(&f, "t-nosig")).expect("open");
    f.host.refuse_signals(true);
    t.signal(Signal::Interrupt).expect("accepted; the host refusal is dropped");
    t.write(input(0, "echo still\n")).expect("write");
    events_until(t.as_mut(), "still", |e| contains(&output(e), "still"));
    assert_eq!(f.host.log().closes, 0);
}

#[test]
fn a_host_that_sends_more_than_the_room_ends_the_terminal_as_lost() {
    let mut f = fixture(Trust::Known);
    let mut t = f.backend.open(ssh_request(&f, "t-over")).expect("open");
    t.write(input(0, "flood 128\n")).expect("write");
    f.host.oversend(true);
    let events = events_until(t.as_mut(), "lost", |e| e.iter().any(common::is_end));
    assert!(matches!(events.last(), Some(ByteEvent::Lost { retryable: false, .. })), "{events:?}");
    assert!(output(&events).len() <= MAX_UNREAD, "no byte past the room was kept");
    assert_eq!(f.host.log().closes, 1);
}

#[test]
fn tokens_never_show_in_debug_output() {
    let f = fixture(Trust::Known);
    let request = ssh_request(&f, "t-debug");
    let secret = request.open_token.0.clone();
    let resume = ResumeRequest {
        resume_token: ResumeToken("ssh:t@0#00ff".into()),
        open_token: request.open_token.clone(),
    };
    let printed = format!("{request:?} {resume:?}");
    assert!(!printed.contains(&secret) && !printed.contains("00ff"), "{printed}");
}

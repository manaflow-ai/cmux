//! Rescue backend rules that no conformance vector or attach test caught
//! under a mutation run (first-party-apps/cloud/README.md "Test notes"):
//! each test here fails on its assertion when its rule is removed from
//! `src/rescue/backend.rs` or `src/rescue/stream.rs`.

mod attach_common;
mod frames_common;

use attach_common::FakeTransport;
use cmux_cloud::rescue::{RescueBackend, TransportEvent};
use cmux_terminal_iface::{
    BackendError, ByteTerminal, Close, Direction, End, ExitStatus, FrameBody, Grid, OpenRequest,
    OpenToken, TerminalBackend,
};
use frames_common::{Host, exit, lost, not_open, output};

fn request() -> OpenRequest {
    OpenRequest {
        kind: "cloud-vm-rescue".into(),
        terminal: "t-1".into(),
        target: "vm-alpha01".into(),
        open_token: OpenToken("open-token-test".into()),
        command: None,
        cwd: None,
        env: Vec::new(),
        grid: Grid::new(80, 24),
        actor: None,
    }
}

fn open(transport: &FakeTransport) -> (RescueBackend, Box<dyn ByteTerminal>) {
    let mut backend = RescueBackend::new(Box::new(transport.clone()));
    let terminal = backend.open(request()).expect("open");
    (backend, terminal)
}

fn invalid(result: Result<(), BackendError>) -> bool {
    matches!(result, Err(BackendError::Invalid { .. }))
}

#[test]
fn written_input_is_credited_back() {
    let transport = FakeTransport::default();
    let (_backend, terminal) = open(&transport);
    let mut host = Host::new(terminal);
    host.write(b"abc").expect("write");
    assert_eq!(transport.written(1), b"abc");
    assert_eq!(host.take(), [FrameBody::Credit { direction: Direction::In, bytes: 3 }]);
}

#[test]
fn nothing_follows_the_end_event() {
    let transport = FakeTransport::default();
    let (_backend, mut terminal) = open(&transport);
    let status = ExitStatus { code: Some(0), ..ExitStatus::default() };
    transport.emit(1, TransportEvent::Closed(status.clone()));
    transport.emit(1, TransportEvent::Output(b"late".to_vec()));
    transport.emit(1, TransportEvent::Dropped { reason: "late".into(), retryable: true });
    assert_eq!(terminal.take_frames(), [exit(status)], "one end, then nothing");
    assert!(terminal.take_frames().is_empty());
}

#[test]
fn empty_output_gives_no_event() {
    let transport = FakeTransport::default();
    let (_backend, mut terminal) = open(&transport);
    transport.emit(1, TransportEvent::Output(Vec::new()));
    transport.emit(1, TransportEvent::Output(b"a".to_vec()));
    assert_eq!(
        terminal.take_frames(),
        [FrameBody::Data { offset: 1, bytes: b"a".to_vec() }],
        "a data frame always carries bytes"
    );
}

#[test]
fn a_write_over_max_write_bytes_is_invalid() {
    let transport = FakeTransport::default();
    let (backend, mut terminal) = open(&transport);
    let max = usize::try_from(backend.capabilities().max_write_bytes).expect("usize");
    let over = FrameBody::Data { offset: max as u64 + 1, bytes: vec![b'x'; max + 1] };
    assert!(invalid(terminal.push(over)));
    assert!(transport.written(1).is_empty(), "nothing reached the transport");
    let bound = FrameBody::Data { offset: max as u64, bytes: vec![b'x'; max] };
    terminal.push(bound).expect("the bound itself");
    assert_eq!(transport.written(1).len(), max);
}

#[test]
fn a_lost_reason_from_the_far_end_is_bounded() {
    let transport = FakeTransport::default();
    let (_backend, mut terminal) = open(&transport);
    let reason = "r".repeat(10_000);
    transport.emit(1, TransportEvent::Dropped { reason, retryable: false });
    let frames = terminal.take_frames();
    let [FrameBody::End(End::Lost(far))] = frames.as_slice() else { panic!("{frames:?}") };
    assert!(!far.retryable);
    assert_eq!(far.reason.len(), 4096);
}

#[test]
fn a_stream_the_far_end_closed_is_never_closed_again() {
    let transport = FakeTransport::default();
    let (_backend, mut terminal) = open(&transport);
    transport.emit(1, TransportEvent::Closed(ExitStatus::default()));
    assert_eq!(terminal.take_frames().len(), 1);
    terminal.close(Close::Now).expect("the session host closes its side");
    drop(terminal);
    assert!(transport.log().closes.is_empty(), "the transport already freed the stream");
}

#[test]
fn dropping_an_open_terminal_closes_the_far_shell() {
    let transport = FakeTransport::default();
    let (_backend, terminal) = open(&transport);
    drop(terminal);
    assert_eq!(transport.log().closes, [1]);
}

#[test]
fn close_drops_output_that_was_not_taken() {
    let transport = FakeTransport::default();
    let (_backend, mut terminal) = open(&transport);
    transport.emit(1, TransportEvent::Output(b"before close".to_vec()));
    terminal.close(Close::Graceful).expect("close");
    assert!(terminal.take_frames().is_empty(), "nothing is delivered after close");
}

#[test]
fn a_command_is_unsupported() {
    let transport = FakeTransport::default();
    let mut backend = RescueBackend::new(Box::new(transport.clone()));
    let mut with_command = request();
    with_command.command = Some(vec!["ls".into()]);
    let err = backend.open(with_command).err();
    assert!(matches!(err, Some(BackendError::Unsupported)), "login shell only: {err:?}");
    assert!(transport.log().opened.is_empty());
}

#[test]
fn a_grid_without_columns_or_rows_is_invalid() {
    let transport = FakeTransport::default();
    let (_backend, mut terminal) = open(&transport);
    assert!(invalid(terminal.resize(Grid::new(0, 24))));
    assert!(invalid(terminal.resize(Grid::new(80, 0))));
    assert!(transport.log().resizes.is_empty());
}

#[test]
fn an_ending_terminal_takes_out_credit_for_its_last_output() {
    let transport = FakeTransport::default();
    let (_backend, terminal) = open(&transport);
    let mut host = Host::new(terminal);
    let window = host.terminal.window_bytes() as usize;
    host.grant = false;
    transport.emit(1, TransportEvent::Output(vec![b'x'; window + 10]));
    transport.emit(1, TransportEvent::Closed(ExitStatus::default()));
    let first = host.take();
    assert_eq!(output(&first).len(), window);
    assert!(!first.iter().any(|f| matches!(f, FrameBody::End(_))), "the end waits: {first:?}");
    assert!(not_open(host.write(b"late")), "no input once the far end ended");
    host.consume();
    let last = host.take();
    assert_eq!(output(&last).len(), 10);
    assert_eq!(last.last(), Some(&exit(ExitStatus::default())), "the end comes after the output");
}

#[test]
fn a_violation_while_ending_gives_one_end_only() {
    // The far end exited while output waits for credit; then the host breaks
    // the credit rule. The terminal ends once, with lost, never also exit.
    let transport = FakeTransport::default();
    let (_backend, terminal) = open(&transport);
    let mut host = Host::new(terminal);
    let window = host.terminal.window_bytes() as usize;
    host.grant = false;
    transport.emit(1, TransportEvent::Output(vec![b'x'; window + 10]));
    transport.emit(1, TransportEvent::Closed(ExitStatus::default()));
    let _ = host.take();
    let _ = host.terminal.push(FrameBody::Credit { direction: Direction::In, bytes: 1 });
    let frames = host.take();
    let ends: Vec<_> = frames.iter().filter(|f| matches!(f, FrameBody::End(_))).collect();
    assert_eq!(ends.len(), 1, "exactly one end: {frames:?}");
    assert!(!ends.contains(&&exit(ExitStatus::default())), "no exit after the lost: {frames:?}");
}

#[test]
fn a_violation_closes_the_transport_stream_once() {
    let transport = FakeTransport::default();
    let (_backend, mut terminal) = open(&transport);
    terminal.push(FrameBody::Data { offset: 9, bytes: b"x".to_vec() }).expect("answered by end");
    assert_eq!(terminal.take_frames(), [lost("gap", false)]);
    assert_eq!(transport.log().closes, [1]);
    drop(terminal);
    assert_eq!(transport.log().closes, [1], "and not again on drop");
}

#[test]
fn an_end_frame_from_the_host_closes_the_terminal() {
    let transport = FakeTransport::default();
    let (_backend, mut terminal) = open(&transport);
    terminal.push(lost("the viewer left", true)).expect("closed");
    assert_eq!(transport.log().closes, [1]);
    assert!(invalid(terminal.push(FrameBody::Data { offset: 1, bytes: b"x".to_vec() })));
    assert!(invalid(terminal.close(Close::Now)));
}

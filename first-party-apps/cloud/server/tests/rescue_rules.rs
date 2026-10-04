//! Rescue backend rules that no conformance vector or attach test caught
//! under a mutation run (first-party-apps/cloud/README.md "Test notes"):
//! each test here fails on its assertion when its rule is removed from
//! `src/rescue/backend.rs`.

mod attach_common;

use attach_common::FakeTransport;
use cmux_cloud::rescue::iface::{
    BackendError, ByteEvent, ByteTerminal, Close, ExitStatus, Grid, Input, OpenRequest, OpenToken,
    TerminalBackend,
};
use cmux_cloud::rescue::{RescueBackend, TransportEvent};

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

fn input(seq: u64, bytes: &[u8]) -> Input {
    Input { seq, bytes: bytes.to_vec() }
}

fn invalid(result: Result<(), BackendError>) -> bool {
    matches!(result, Err(BackendError::Invalid { .. }))
}

#[test]
fn a_held_seq_is_written_once() {
    let transport = FakeTransport::default();
    let (_backend, terminal) = open(&transport);
    terminal.write(input(2, b"x")).expect("held for seq 0 and 1");
    assert!(invalid(terminal.write(input(2, b"y"))), "a held seq is written once");
    terminal.write(input(0, b"a")).expect("seq 0");
    terminal.write(input(1, b"b")).expect("seq 1");
    assert_eq!(transport.written(1), b"abx");
}

#[test]
fn nothing_follows_the_end_event() {
    let transport = FakeTransport::default();
    let (_backend, mut terminal) = open(&transport);
    let status = ExitStatus { code: Some(0), ..ExitStatus::default() };
    transport.emit(1, TransportEvent::Closed(status.clone()));
    transport.emit(1, TransportEvent::Output(b"late".to_vec()));
    transport.emit(1, TransportEvent::Dropped { reason: "late".into(), retryable: true });
    assert_eq!(terminal.take_events(), [ByteEvent::Exit(status)], "one end event, then nothing");
    assert!(terminal.take_events().is_empty());
}

#[test]
fn empty_output_gives_no_event() {
    let transport = FakeTransport::default();
    let (_backend, mut terminal) = open(&transport);
    transport.emit(1, TransportEvent::Output(Vec::new()));
    transport.emit(1, TransportEvent::Output(b"a".to_vec()));
    assert_eq!(
        terminal.take_events(),
        [ByteEvent::Output { offset: 1, bytes: b"a".to_vec() }],
        "an output event always carries bytes"
    );
}

#[test]
fn a_seq_too_far_ahead_is_refused() {
    let transport = FakeTransport::default();
    let (_backend, terminal) = open(&transport);
    assert!(invalid(terminal.write(input(257, b"x"))), "more than 256 ahead of seq 0");
    terminal.write(input(256, b"y")).expect("256 ahead is held");
    assert!(transport.written(1).is_empty());
}

#[test]
fn a_write_over_max_write_bytes_is_invalid() {
    let transport = FakeTransport::default();
    let (backend, terminal) = open(&transport);
    let max = usize::try_from(backend.capabilities().max_write_bytes).expect("usize");
    assert!(invalid(terminal.write(Input { seq: 0, bytes: vec![b'x'; max + 1] })));
    assert!(transport.written(1).is_empty(), "nothing reached the transport");
    terminal.write(Input { seq: 0, bytes: vec![b'x'; max] }).expect("the bound itself");
    assert_eq!(transport.written(1).len(), max);
}

#[test]
fn a_lost_reason_from_the_far_end_is_bounded() {
    let transport = FakeTransport::default();
    let (_backend, mut terminal) = open(&transport);
    let reason = "r".repeat(10_000);
    transport.emit(1, TransportEvent::Dropped { reason, retryable: false });
    let events = terminal.take_events();
    let [ByteEvent::Lost { reason, retryable: false }] = events.as_slice() else {
        panic!("{events:?}")
    };
    assert_eq!(reason.len(), 4096);
}

#[test]
fn a_stream_the_far_end_closed_is_never_closed_again() {
    let transport = FakeTransport::default();
    let (_backend, mut terminal) = open(&transport);
    transport.emit(1, TransportEvent::Closed(ExitStatus::default()));
    assert_eq!(terminal.take_events().len(), 1);
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
    assert!(terminal.take_events().is_empty(), "nothing is delivered after close");
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
    let (_backend, terminal) = open(&transport);
    assert!(invalid(terminal.resize(Grid::new(0, 24))));
    assert!(invalid(terminal.resize(Grid::new(80, 0))));
    assert!(transport.log().resizes.is_empty());
}

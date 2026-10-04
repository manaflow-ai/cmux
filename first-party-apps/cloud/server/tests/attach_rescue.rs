//! The rescue shell: `cmux.terminal.backend/1` (mirror) for kind
//! `cloud-vm-rescue`, against a fake transport, and `cloud.rescue.open`.

mod attach_common;
mod common;

use attach_common::{FakeSpawner, FakeTransport, attach};
use cmux_cloud::rescue::iface::{
    BackendError, ByteEvent, ByteTerminal, Close, ExitStatus, Grid, Input, LocalId, OpenRequest,
    OpenToken, ResumeRequest, ResumeToken, Signal, TerminalBackend,
};
use cmux_cloud::rescue::{RescueBackend, TransportEvent};
use cmux_cloud::{Origin, Request, Server};
use common::FakeControlPlane;
use serde_json::json;

fn open_request(kind: &str) -> OpenRequest {
    OpenRequest {
        kind: kind.into(),
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
    let terminal = backend.open(open_request("cloud-vm-rescue")).expect("open");
    (backend, terminal)
}

fn input(seq: u64, text: &str) -> Input {
    Input { seq, bytes: text.as_bytes().to_vec() }
}

#[test]
fn write_order_is_kept_by_seq() {
    let transport = FakeTransport::default();
    let (_backend, terminal) = open(&transport);
    terminal.write(input(1, "b")).expect("ahead is held");
    assert!(transport.written(1).is_empty(), "nothing before seq 0");
    terminal.write(input(0, "a")).expect("seq 0");
    terminal.write(input(2, "c")).expect("seq 2");
    let again = terminal.write(input(1, "b"));
    assert!(matches!(again, Err(BackendError::Invalid { .. })), "a seq is written once: {again:?}");
    assert_eq!(transport.written(1), b"abc");
}

#[test]
fn resize_reaches_the_transport() {
    let transport = FakeTransport::default();
    let (_backend, terminal) = open(&transport);
    terminal.resize(Grid::new(132, 43)).expect("resize");
    assert_eq!(transport.log().resizes, [(1, Grid::new(132, 43))]);
    terminal.signal(Signal::Interrupt).expect("signal");
    assert_eq!(transport.log().signals, [(1, Signal::Interrupt)]);
}

#[test]
fn output_reaches_the_terminal() {
    let transport = FakeTransport::default();
    let (_backend, mut terminal) = open(&transport);
    transport.emit(1, TransportEvent::Output(b"root@vm:~# ".to_vec()));
    transport.emit(1, TransportEvent::Output(b"ls".to_vec()));
    assert_eq!(
        terminal.take_events(),
        [
            ByteEvent::Output { offset: 11, bytes: b"root@vm:~# ".to_vec() },
            ByteEvent::Output { offset: 13, bytes: b"ls".to_vec() },
        ]
    );
}

#[test]
fn transport_close_gives_the_full_exit_status() {
    let transport = FakeTransport::default();
    let (_backend, mut terminal) = open(&transport);
    let status = ExitStatus {
        code: None,
        signal: Some("KILL".into()),
        core_dumped: true,
        message: Some("killed".into()),
    };
    transport.emit(1, TransportEvent::Closed(status.clone()));
    assert_eq!(terminal.take_events(), [ByteEvent::Exit(status)]);
    assert!(matches!(terminal.write(input(0, "x")), Err(BackendError::Invalid { .. })));
    assert!(terminal.take_events().is_empty(), "nothing after the end event");
}

#[test]
fn close_ends_the_terminal_at_once() {
    let transport = FakeTransport::default();
    let (_backend, mut terminal) = open(&transport);
    terminal.write(input(1, "held")).expect("held for seq 0");
    terminal.close(Close::Graceful).expect("close");
    assert_eq!(transport.log().closes, [1]);
    assert!(transport.log().writes.is_empty(), "held input is never sent after close");
    assert!(matches!(terminal.write(input(0, "a")), Err(BackendError::Invalid { .. })));
    assert!(matches!(terminal.close(Close::Now), Err(BackendError::Invalid { .. })));
    transport.emit(1, TransportEvent::Output(b"late".to_vec()));
    assert!(terminal.take_events().is_empty(), "no output after close");
}

#[test]
fn far_end_text_is_bounded() {
    let transport = FakeTransport::default();
    let (_backend, mut terminal) = open(&transport);
    let status = ExitStatus {
        code: Some(1),
        signal: Some("S".repeat(100)),
        core_dumped: false,
        message: Some("m".repeat(10_000)),
    };
    transport.emit(1, TransportEvent::Closed(status));
    let events = terminal.take_events();
    let [ByteEvent::Exit(exit)] = events.as_slice() else { panic!("{events:?}") };
    assert_eq!(exit.message.as_deref().map(str::len), Some(4096));
    assert_eq!(exit.signal.as_deref().map(str::len), Some(32));
}

#[test]
fn transport_drop_gives_lost_and_no_input_queues() {
    let transport = FakeTransport::default();
    let (_backend, mut terminal) = open(&transport);
    terminal.write(input(1, "held")).expect("held for seq 0");
    transport.emit(1, TransportEvent::Dropped { reason: "network".into(), retryable: true });
    assert_eq!(
        terminal.take_events(),
        [ByteEvent::Lost { reason: "network".into(), retryable: true }]
    );
    assert!(matches!(terminal.write(input(0, "a")), Err(BackendError::Invalid { .. })));
    assert!(matches!(terminal.resize(Grid::new(10, 10)), Err(BackendError::Invalid { .. })));
    assert!(transport.log().writes.is_empty(), "nothing reached the transport");
}

#[test]
fn the_backend_refuses_kind_ssh_and_resume() {
    let transport = FakeTransport::default();
    let mut backend = RescueBackend::new(Box::new(transport.clone()));
    let err = backend.open(open_request("ssh")).err().expect("refused");
    assert!(matches!(err, BackendError::Denied { .. }), "{err:?}");
    assert!(transport.log().opened.is_empty());
    assert_eq!(backend.id().as_str(), "app:cmux/cloud/rescue");
    let caps = backend.capabilities();
    assert!(!caps.resume);
    assert!(!caps.answers_queries, "the session host answers terminal queries");
    let resume = ResumeRequest {
        resume_token: ResumeToken("rescue:t-1".into()),
        open_token: OpenToken("open-token-test".into()),
    };
    assert!(matches!(backend.resume(resume).err(), Some(BackendError::Unsupported)));
}

#[test]
fn local_ids_follow_the_interface_pattern() {
    assert!(LocalId::new(&format!("a{}", "b".repeat(63))).is_ok(), "64 characters");
    assert!(LocalId::new(&format!("a{}", "b".repeat(64))).is_err(), "65 characters");
    assert!(LocalId::new("cloud-vmRescue2").is_ok(), "upper case after the first letter");
    assert!(LocalId::new("Cloud").is_err());
}

#[test]
fn a_transport_failure_is_a_typed_error_and_ends_the_terminal() {
    let transport = FakeTransport::default();
    let (_backend, mut terminal) = open(&transport);
    transport.log().fail_writes = true;
    let err = terminal.write(input(0, "a")).unwrap_err();
    assert!(matches!(err, BackendError::Unavailable { retryable: true, .. }), "{err:?}");
    let events = terminal.take_events();
    assert!(matches!(events.as_slice(), [ByteEvent::Lost { retryable: true, .. }]), "{events:?}");
}

#[test]
fn rescue_open_answers_unsupported_without_a_route() {
    let mut s = Server::new(FakeControlPlane::with(&["vm-get"]));
    let request = Request::new("cloud.rescue.open", json!({ "machine": "vm-alpha01" }))
        .origin(Origin::User)
        .key("r-1");
    let err = s.handle(&request).unwrap_err();
    assert_eq!(err.code, "cmux.cloud.unsupported");
    assert!(s.control_plane().calls.is_empty(), "no Cloud API call, no machine start");
}

#[test]
fn rescue_open_focuses_only_for_a_person_or_an_explicit_ask() {
    let transport = FakeTransport::default();
    let mut s = Server::with_attach(
        FakeControlPlane::with(&["vm-get"]),
        attach(&FakeSpawner::default(), &transport),
    );
    let open = |origin, focus: Option<bool>, key: &str| {
        let mut args = json!({ "machine": "vm-alpha01", "cols": 100, "rows": 30 });
        if let Some(f) = focus {
            args["focus"] = json!(f);
        }
        Request::new("cloud.rescue.open", args).origin(origin).key(key)
    };
    let by_user = s.handle(&open(Origin::User, None, "r-1")).expect("user");
    assert_eq!(by_user["focus"], true);
    assert_eq!(by_user["kind"], "cloud-vm-rescue");
    assert_eq!(by_user["backend"], "app:cmux/cloud/rescue");
    let by_agent = s.handle(&open(Origin::Mcp, None, "r-2")).expect("mcp");
    assert_eq!(by_agent["focus"], false);
    let explicit = s.handle(&open(Origin::Cli, Some(true), "r-3")).expect("cli");
    assert_eq!(explicit["focus"], true);
    assert_eq!(transport.log().opened[0], ("vm-alpha01".to_owned(), Grid::new(100, 30)));
    let id = by_user["terminal"].as_str().expect("terminal id").to_owned();
    let terminal = s.attach_mut().rescue_terminal(&id).expect("kept for the daemon");
    terminal.write(input(0, "ls\r")).expect("write");
    assert_eq!(transport.written(1), b"ls\r");
}

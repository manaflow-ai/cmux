//! The rescue shell: `cmux.terminal.backend/1` (mirror) for kind
//! `cloud-vm-rescue`, against a fake transport, and `cloud.rescue.open`.

mod attach_common;
mod common;

use attach_common::{FakeSpawner, FakeTransport, attach};
use cmux_cloud::rescue::iface::{
    BackendError, ByteEvent, ByteTerminal, Close, ExitStatus, Grid, Input, OpenRequest, Signal,
    TerminalBackend,
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
        command: None,
        cwd: None,
        env: Vec::new(),
        grid: Grid { cols: 80, rows: 24 },
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
    terminal.write(input(1, "b")).expect("a replay has no effect");
    assert_eq!(transport.written(1), b"abc");
}

#[test]
fn resize_reaches_the_transport() {
    let transport = FakeTransport::default();
    let (_backend, terminal) = open(&transport);
    terminal.resize(Grid { cols: 132, rows: 43 }).expect("resize");
    assert_eq!(transport.log().resizes, [(1, Grid { cols: 132, rows: 43 })]);
    terminal.signal(Signal::Interrupt).expect("signal");
    assert_eq!(transport.log().signals, [(1, Signal::Interrupt)]);
}

#[test]
fn output_reaches_the_terminal() {
    let transport = FakeTransport::default();
    let (_backend, mut terminal) = open(&transport);
    transport.emit(1, TransportEvent::Output(b"root@vm:~# ".to_vec()));
    assert_eq!(terminal.take_events(), [ByteEvent::Output(b"root@vm:~# ".to_vec())]);
}

#[test]
fn transport_close_gives_exit() {
    let transport = FakeTransport::default();
    let (_backend, mut terminal) = open(&transport);
    terminal.close(Close::Graceful).expect("close");
    assert_eq!(transport.log().closes, [1]);
    transport.emit(1, TransportEvent::Closed { code: Some(0) });
    assert_eq!(terminal.take_events(), [ByteEvent::Exit(ExitStatus { code: Some(0) })]);
    assert_eq!(terminal.write(input(0, "x")), Err(BackendError::Closed));
}

#[test]
fn transport_drop_gives_lost_and_no_input_queues() {
    let transport = FakeTransport::default();
    let (_backend, mut terminal) = open(&transport);
    terminal.write(input(1, "held")).expect("held for seq 0");
    transport.emit(1, TransportEvent::Dropped { reason: "network".into() });
    assert_eq!(terminal.take_events(), [ByteEvent::Lost("network".into())]);
    assert_eq!(terminal.write(input(0, "a")), Err(BackendError::Closed));
    assert_eq!(terminal.resize(Grid { cols: 10, rows: 10 }), Err(BackendError::Closed));
    assert!(transport.log().writes.is_empty(), "nothing reached the transport");
}

#[test]
fn the_backend_refuses_kind_ssh_and_resume() {
    let transport = FakeTransport::default();
    let mut backend = RescueBackend::new(Box::new(transport.clone()));
    let err = backend.open(open_request("ssh")).err().expect("refused");
    assert_eq!(err, BackendError::KindRefused { kind: "ssh".into() });
    assert!(transport.log().opened.is_empty());
    assert_eq!(backend.id().as_str(), "app:cmux/cloud/rescue");
    assert!(!backend.capabilities().resume);
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
    assert_eq!(transport.log().opened[0], ("vm-alpha01".to_owned(), Grid { cols: 100, rows: 30 }));
    let id = by_user["terminal"].as_str().expect("terminal id").to_owned();
    let terminal = s.attach_mut().rescue_terminal(&id).expect("kept for the daemon");
    terminal.write(input(0, "ls\r")).expect("write");
    assert_eq!(transport.written(1), b"ls\r");
}

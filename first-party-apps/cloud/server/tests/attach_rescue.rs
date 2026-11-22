//! The rescue shell: `cmux.terminal.backend/1` (the shared
//! `cmux-terminal-iface` crate) for kind `cloud-vm-rescue`, against a fake
//! transport, and `cloud.rescue.open`.

mod attach_common;
mod common;
mod frames_common;

use attach_common::{FakeSpawner, FakeTransport, attach};
use cmux_cloud::rescue::{RescueBackend, TransportEvent};
use cmux_cloud::{Origin, Request, Server};
use cmux_terminal_iface::{
    BackendError, ByteTerminal, Close, End, ExitStatus, FrameBody, Grid, LocalId, OpenRequest,
    OpenToken, ResumeRequest, ResumeToken, Signal, TerminalBackend,
};
use common::FakeControlPlane;
use frames_common::{Host, exit, lost, not_open};
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

#[test]
fn input_frames_reach_the_transport_in_order() {
    let transport = FakeTransport::default();
    let (_backend, terminal) = open(&transport);
    let mut host = Host::new(terminal);
    for text in ["a", "b", "c"] {
        host.write(text.as_bytes()).expect("write");
    }
    assert_eq!(transport.written(1), b"abc");
}

#[test]
fn resize_reaches_the_transport() {
    let transport = FakeTransport::default();
    let (_backend, mut terminal) = open(&transport);
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
        terminal.take_frames(),
        [
            FrameBody::Data { offset: 11, bytes: b"root@vm:~# ".to_vec() },
            FrameBody::Data { offset: 13, bytes: b"ls".to_vec() },
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
    assert_eq!(terminal.take_frames(), [exit(status)]);
    let late = FrameBody::Data { offset: 1, bytes: b"x".to_vec() };
    assert!(not_open(terminal.push(late)));
    assert!(terminal.take_frames().is_empty(), "nothing after the end");
}

#[test]
fn close_ends_the_terminal_at_once() {
    let transport = FakeTransport::default();
    let (_backend, terminal) = open(&transport);
    let mut host = Host::new(terminal);
    host.write(b"a").expect("write");
    host.terminal.close(Close::Graceful).expect("close");
    assert_eq!(transport.log().closes, [1]);
    assert!(not_open(host.write(b"b")));
    assert_eq!(transport.written(1), b"a", "nothing is sent after close");
    assert!(not_open(host.terminal.close(Close::Now)));
    transport.emit(1, TransportEvent::Output(b"late".to_vec()));
    assert!(host.take().is_empty(), "no output after close");
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
    let frames = terminal.take_frames();
    let [FrameBody::End(End::Exit(status))] = frames.as_slice() else { panic!("{frames:?}") };
    assert_eq!(status.message.as_deref().map(str::len), Some(4096));
    assert_eq!(status.signal.as_deref().map(str::len), Some(32));
}

#[test]
fn transport_drop_gives_lost_and_no_input_queues() {
    let transport = FakeTransport::default();
    let (_backend, terminal) = open(&transport);
    let mut host = Host::new(terminal);
    transport.emit(1, TransportEvent::Dropped { reason: "network".into(), retryable: true });
    assert_eq!(host.take(), [lost("network", true)]);
    assert!(not_open(host.write(b"a")));
    assert!(not_open(host.terminal.resize(Grid::new(10, 10))));
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
        terminal: "t-1".into(),
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
    let (_backend, terminal) = open(&transport);
    let mut host = Host::new(terminal);
    transport.log().fail_writes = true;
    let err = host.write(b"a").unwrap_err();
    assert!(matches!(err, BackendError::Unavailable { retryable: true, .. }), "{err:?}");
    let frames = host.take();
    let [FrameBody::End(End::Lost(far))] = frames.as_slice() else { panic!("{frames:?}") };
    assert!(far.retryable);
    assert_eq!(transport.log().closes, [1], "the lost stream is closed once");
    drop(host);
    assert_eq!(transport.log().closes, [1], "and not again on drop");
}

#[test]
fn rescue_open_answers_unsupported_without_a_route() {
    let mut s = Server::new(FakeControlPlane::with(&["vm-get"]));
    let request = Request::new("cloud.rescue.open", json!({ "machine": "vm-alpha01" }))
        .origin(Origin::User)
        .key("r-1");
    let err = s.handle(&request).unwrap_err();
    assert_eq!(err.code, "cmux.cloud.unsupported");
    assert!(s.control_plane().no_calls(), "no Cloud API call, no machine start");
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
        Request::new("cloud.rescue.open", args)
            .origin(origin)
            .key(key)
            .open_token("open-token-test")
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
    let input = FrameBody::Data { offset: 3, bytes: b"ls\r".to_vec() };
    terminal.push(input).expect("write");
    assert_eq!(transport.written(1), b"ls\r");
}

#[test]
fn the_rescue_backend_refuses_an_empty_open_token_before_any_open() {
    let transport = FakeTransport::default();
    let mut backend = RescueBackend::new(Box::new(transport.clone()));
    for token in ["", " "] {
        let mut request = open_request("cloud-vm-rescue");
        request.open_token = OpenToken(token.into());
        let answer = backend.open(request).map(|_| "opened");
        assert!(matches!(answer, Err(BackendError::Invalid { .. })), "{token:?}: {answer:?}");
    }
    assert!(transport.log().opened.is_empty(), "no stream opened");
}

#[test]
fn rescue_open_without_the_hosts_open_token_is_refused_before_any_call() {
    let transport = FakeTransport::default();
    let mut s = Server::with_attach(
        FakeControlPlane::with(&["vm-get"]),
        attach(&FakeSpawner::default(), &transport),
    );
    let bare = Request::new("cloud.rescue.open", json!({ "machine": "vm-alpha01" }))
        .origin(Origin::User)
        .key("r-1");
    let empty = bare.clone().key("r-2").open_token("");
    for request in [bare, empty] {
        let code = s.handle(&request).map_err(|e| e.code);
        assert_eq!(code, Err("cmux.cloud.invalid_args"), "{code:?}");
    }
    assert!(transport.log().opened.is_empty(), "no stream opened");
    assert!(s.control_plane().no_calls(), "no Cloud API call, no machine start");
}

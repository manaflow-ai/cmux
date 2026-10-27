//! REQUEST and CANCEL frames over a real socket pair, on a connection the
//! production lane serves after a real `set-client-info` granted frames:
//! a framed request gets the reply body its line gets, as a REPLY or ERROR
//! frame; a frame the method table refuses closes with `bad_message`; a
//! CANCEL ends a `wait-for`.

use std::io::Write;
use std::net::Shutdown;
use std::os::unix::net::UnixStream;
use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use cmux_ipc::{
    Aux, CallAux, CallFlags, FrameHeader, FrameKind, FrameReader, Message, MethodAttrs,
    MethodTables, PriorityHint, ReaderLimits,
};
use serde_json::{Value, json};

use super::{CallRefusal, METHOD_NOT_FRAMED, RequestFrames};
use crate::server::line_connection::{ConnectionBadMessage, ConnectionEnd, serve_connection};
use crate::server::*;

/// What the daemon sent: a line, or a frame and its JSON payload.
#[derive(Debug)]
enum Got {
    Line(Value),
    Frame(FrameHeader, Value),
}

struct Client {
    mux: Arc<Mux>,
    socket: UnixStream,
    read_half: UnixStream,
    reader: FrameReader,
    served: JoinHandle<ConnectionEnd>,
}

fn method(name: &str) -> &'static MethodAttrs {
    let tables = MethodTables::schema();
    tables.v12_id(name).and_then(|id| tables.method(id)).expect("a v12 method")
}

fn call_frame(
    kind: FrameKind,
    request_id: u32,
    method_id: u16,
    priority: PriorityHint,
    body: &[u8],
) -> Vec<u8> {
    let aux = Aux::Call(CallAux { request_id, method_id, priority, flags: CallFlags::empty() });
    let header = FrameHeader::new(kind, 0, u32::try_from(body.len()).unwrap(), aux).unwrap();
    let mut bytes = header.encode().to_vec();
    bytes.extend_from_slice(body);
    bytes
}

/// A REQUEST frame for `body`'s `cmd`, with its table priority.
fn request(request_id: u32, body: &Value) -> Vec<u8> {
    let method = method(body["cmd"].as_str().unwrap());
    call_frame(
        FrameKind::Request,
        request_id,
        method.id.raw(),
        method.priority,
        body.to_string().as_bytes(),
    )
}

fn cancel(request_id: u32, name: &str) -> Vec<u8> {
    let method = method(name);
    call_frame(FrameKind::Cancel, request_id, method.id.raw(), method.priority, b"")
}

impl Client {
    /// A same-user local peer whose `set-client-info` declared frames.
    fn granted(label: &str) -> Client {
        let mux =
            Mux::new_for_test(format!("frame-dispatch-{label}"), crate::SurfaceOptions::default());
        let (socket, server) = UnixStream::pair().unwrap();
        let served_mux = mux.clone();
        let served = std::thread::spawn(move || {
            let stream: Box<dyn transport::Stream> = Box::new(server);
            serve_connection(
                served_mux,
                stream,
                Arc::new(RenderService::new()),
                None,
                ClientTransport::Unix,
                &admission::LocalAdmission,
                &mut RequestFrames::default(),
            )
        });
        let read_half = socket.try_clone().unwrap();
        read_half.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        let mut reader = FrameReader::new(ReaderLimits::default());
        reader.negotiate_frames();
        let mut client = Client { mux, socket, read_half, reader, served };
        client.line(&json!({"id": 99, "cmd": "ping"}));
        assert!(matches!(client.next(), Some(Got::Line(reply)) if reply["id"] == json!(99)));
        let id = client.client_id();
        client.mux.control_clients.ipc_transports.bind_all_for_test();
        origin_gate::set_peer_process_for_test(
            &client.mux,
            id,
            crate::request_origin::PeerProcess::SameUser,
        );
        let (current, _) = api_revision_wire::identify_fields();
        client.line(&json!({
            "id": 1,
            "cmd": "set-client-info",
            "name": "frames",
            "capabilities": ["ipc-frames-v2"],
            "api_revision": current,
        }));
        match client.next() {
            Some(Got::Line(reply)) => assert_eq!(reply["ok"], json!(true), "{reply}"),
            other => panic!("set-client-info: {other:?}"),
        }
        client
    }

    /// The connection's client (a fresh test mux has no other Unix client).
    fn client_id(&self) -> u64 {
        let state = self.mux.control_clients.state.lock().unwrap();
        let mut unix = state
            .clients
            .iter()
            .filter(|(_, record)| matches!(record.transport, ClientTransport::Unix))
            .map(|(client, _)| *client);
        let client = unix.next().expect("the connection's client");
        assert_eq!(unix.next(), None, "one Unix client");
        client
    }

    fn line(&mut self, value: &Value) {
        self.socket.write_all(format!("{value}\n").as_bytes()).unwrap();
    }

    fn send(&mut self, bytes: &[u8]) {
        self.socket.write_all(bytes).unwrap();
    }

    /// The next reply (events skipped); `None` once the daemon closed.
    fn next(&mut self) -> Option<Got> {
        loop {
            match self.reader.next_message().unwrap() {
                Some(Message::Json(line)) if line.trim().is_empty() => {}
                Some(Message::Json(line)) => {
                    let value: Value = serde_json::from_str(line).unwrap();
                    if value.get("event").is_none() {
                        return Some(Got::Line(value));
                    }
                }
                Some(Message::Frame(frame)) => {
                    let value = serde_json::from_slice(frame.payload()).unwrap();
                    return Some(Got::Frame(*frame.header(), value));
                }
                None => {
                    if self.reader.read_from(&mut self.read_half).unwrap() == 0 {
                        return None;
                    }
                }
            }
        }
    }

    fn line_reply(&mut self, body: &Value) -> Value {
        self.line(body);
        match self.next() {
            Some(Got::Line(reply)) => reply,
            other => panic!("expected a line reply to {body}: {other:?}"),
        }
    }

    fn frame_reply(&mut self, request_id: u32, body: &Value) -> (FrameHeader, Value) {
        self.send(&request(request_id, body));
        match self.next() {
            Some(Got::Frame(header, reply)) => (header, reply),
            other => panic!("expected a frame reply to {body}: {other:?}"),
        }
    }

    fn finish(self) -> ConnectionEnd {
        let _ = self.socket.shutdown(Shutdown::Write);
        self.served.join().unwrap()
    }

    /// The daemon closes at once, and says why.
    fn closed_with(mut self, refusal: CallRefusal) {
        assert!(self.next().is_none(), "the daemon answered a bad message");
        assert_eq!(self.finish(), ConnectionEnd::BadMessage(ConnectionBadMessage::Call(refusal)));
    }
}

fn assert_answers(header: &FrameHeader, kind: FrameKind, request_id: u32, name: &str) {
    let method = method(name);
    assert_eq!(header.kind(), kind);
    assert_eq!(header.stream(), 0);
    let call = header.call().unwrap();
    assert_eq!(
        (call.request_id, call.method_id, call.priority, call.flags),
        (request_id, method.id.raw(), method.priority, CallFlags::empty())
    );
}

#[test]
fn frame_dispatch_replies_equal_the_line_replies() {
    let mut client = Client::granted("equal");
    let ok = json!({"id": 7, "cmd": "ping"});
    let line = client.line_reply(&ok);
    let (header, framed) = client.frame_reply(70, &ok);
    assert_answers(&header, FrameKind::Reply, 70, "ping");
    assert_eq!(framed, line);

    // An id-less request: the request id in the header is the only match.
    let bare = json!({"cmd": "ping"});
    let line = client.line_reply(&bare);
    let (header, framed) = client.frame_reply(71, &bare);
    assert_answers(&header, FrameKind::Reply, 71, "ping");
    assert_eq!(framed, line);

    // A failed command: the same error body, as an ERROR frame.
    let failing = json!({"id": 8, "cmd": "read-screen", "surface": 987_654});
    let line = client.line_reply(&failing);
    assert_eq!(line["ok"], json!(false), "{line}");
    let (header, framed) = client.frame_reply(80, &failing);
    assert_answers(&header, FrameKind::Error, 80, "read-screen");
    assert_eq!(framed, line);

    // Bad parameters fail like their line.
    let bad = json!({"id": 9, "cmd": "read-screen", "surface": "not-a-surface"});
    let line = client.line_reply(&bad);
    let (header, framed) = client.frame_reply(90, &bad);
    assert_answers(&header, FrameKind::Error, 90, "read-screen");
    assert_eq!(framed, line);

    // An answered id is free again.
    let (header, _) = client.frame_reply(70, &ok);
    assert_answers(&header, FrameKind::Reply, 70, "ping");
    assert_eq!(client.finish(), ConnectionEnd::PeerClosed);
}

#[test]
fn frame_dispatch_a_feature_route_answers_method_not_framed() {
    let mut client = Client::granted("not-framed");
    let (header, reply) = client.frame_reply(5, &json!({"id": 5, "cmd": "apps-list"}));
    assert_answers(&header, FrameKind::Error, 5, "apps-list");
    assert_eq!(reply["error_code"], json!(METHOD_NOT_FRAMED), "{reply}");
    // The connection stays up.
    let (header, _) = client.frame_reply(6, &json!({"cmd": "ping"}));
    assert_answers(&header, FrameKind::Reply, 6, "ping");
    assert_eq!(client.finish(), ConnectionEnd::PeerClosed);
}

#[test]
fn frame_dispatch_an_unknown_method_id_closes_with_bad_message() {
    let mut client = Client::granted("unknown");
    assert!(MethodTables::schema().method(cmux_ipc::MethodId::new(0x01FF)).is_none());
    client.send(&call_frame(FrameKind::Request, 1, 0x01FF, PriorityHint::Control, b"{}"));
    client.closed_with(CallRefusal::UnknownMethod { method_id: 0x01FF });
}

#[test]
fn frame_dispatch_a_priority_hint_off_the_table_closes_with_bad_message() {
    let mut client = Client::granted("priority");
    let ping = method("ping");
    assert_eq!(ping.priority, PriorityHint::Control);
    let body = json!({"cmd": "ping"}).to_string();
    client.send(&call_frame(
        FrameKind::Request,
        1,
        ping.id.raw(),
        PriorityHint::Bulk,
        body.as_bytes(),
    ));
    client.closed_with(CallRefusal::PriorityMismatch {
        method_id: ping.id.raw(),
        hint: PriorityHint::Bulk,
        table: PriorityHint::Control,
    });
}

#[test]
fn frame_dispatch_a_body_that_names_another_method_closes_with_bad_message() {
    let ping = method("ping");
    for (label, body) in [
        ("other-cmd", json!({"cmd": "identify"}).to_string()),
        ("no-cmd", json!({"id": 1}).to_string()),
        ("v2-envelope", json!({"cmd": "ping", "protocol": null}).to_string()),
        ("not-json", "ping".to_string()),
    ] {
        let mut client = Client::granted(label);
        client.send(&call_frame(
            FrameKind::Request,
            1,
            ping.id.raw(),
            ping.priority,
            body.as_bytes(),
        ));
        client.closed_with(CallRefusal::MethodMismatch { method_id: ping.id.raw() });
    }
}

#[test]
fn frame_dispatch_a_client_sent_reply_frame_closes_with_bad_message() {
    let mut client = Client::granted("reply-kind");
    let ping = method("ping");
    client.send(&call_frame(FrameKind::Reply, 1, ping.id.raw(), ping.priority, b"{}"));
    assert!(client.next().is_none());
    assert_eq!(
        client.finish(),
        ConnectionEnd::BadMessage(ConnectionBadMessage::UnroutedKind { kind: FrameKind::Reply })
    );
}

fn wait_for(client: &Client, timeout_ms: u64) -> Value {
    let surface = client.mux.new_workspace(None, Some((80, 24))).unwrap();
    json!({
        "cmd": "wait-for",
        "surface": surface.id,
        "pattern": "frame-dispatch-never-printed",
        "timeout_ms": timeout_ms,
    })
}

#[test]
fn frame_dispatch_cancel_ends_wait_for() {
    let mut client = Client::granted("cancel");
    let wait = wait_for(&client, 60_000);
    let started = Instant::now();
    client.send(&request(3, &wait));
    // A CANCEL of an id not in flight lost a race with its reply: dropped.
    client.send(&cancel(4, "wait-for"));
    client.send(&cancel(3, "wait-for"));
    match client.next() {
        Some(Got::Frame(header, reply)) => {
            assert_answers(&header, FrameKind::Error, 3, "wait-for");
            let error = reply["error"].as_str().unwrap();
            assert!(
                ["cancelled while waiting for pattern", "request cancelled"].contains(&error),
                "{reply}"
            );
        }
        other => panic!("expected the wait's ERROR frame: {other:?}"),
    }
    assert!(started.elapsed() < Duration::from_secs(30), "the wait ran to its timeout");
    // The connection's dispatcher is free again.
    let (header, _) = client.frame_reply(5, &json!({"cmd": "ping"}));
    assert_answers(&header, FrameKind::Reply, 5, "ping");
    assert_eq!(client.finish(), ConnectionEnd::PeerClosed);
}

#[test]
fn frame_dispatch_an_id_in_flight_closes_with_bad_message() {
    let mut client = Client::granted("duplicate");
    let wait = wait_for(&client, 60_000);
    client.send(&request(3, &wait));
    client.send(&request(3, &json!({"cmd": "ping"})));
    // The close cancels the wait, so the connection ends promptly.
    client.closed_with(CallRefusal::DuplicateRequest { request_id: 3 });
}

#[test]
fn frame_dispatch_a_cancel_must_name_its_request_method() {
    let mut client = Client::granted("cancel-mismatch");
    let wait = wait_for(&client, 60_000);
    client.send(&request(3, &wait));
    client.send(&cancel(3, "ping"));
    client.closed_with(CallRefusal::CancelMismatch {
        request_id: 3,
        method_id: method("ping").id.raw(),
    });

    let mut client = Client::granted("cancel-payload");
    let ping = method("ping");
    client.send(&call_frame(FrameKind::Cancel, 3, ping.id.raw(), ping.priority, b"{}"));
    client.closed_with(CallRefusal::CancelPayload { request_id: 3 });
}

/// While a daemon handoff is pending, a framed request is refused unexecuted
/// with its line's body (the same `daemon_shutdown_pending` code) as an
/// ERROR frame (a body with bad parameters gets its line's bad request); it
/// never runs, and the connection stays up.
#[test]
fn frame_dispatch_pending_handoff_refuses_with_the_line_error() {
    let mut client = Client::granted("pending-handoff");
    let mux = client.mux.clone();
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    mux.mark_server_lifecycle_ready();
    mux.begin_daemon_handoff(client.client_id(), DaemonHandoffRequest::unfenced(false)).unwrap();

    let workspaces = mux.with_state(|state| state.workspaces.len());
    for (request_id, body, name) in [
        (1, json!({"id": 7, "cmd": "new-workspace", "name": "must-not-exist"}), "new-workspace"),
        (2, json!({"cmd": "ping"}), "ping"),
        (3, json!({"id": "c", "cmd": "clear-history", "surface": surface.id}), "clear-history"),
    ] {
        let line = client.line_reply(&body);
        assert_eq!(line["error_code"], json!(DAEMON_SHUTDOWN_PENDING_CODE), "{line}");
        let (header, framed) = client.frame_reply(request_id, &body);
        assert_answers(&header, FrameKind::Error, request_id, name);
        assert_eq!(framed, line);
    }
    assert_eq!(
        client.line_reply(&json!({"id": 4, "cmd": "clear-history", "surface": surface.id}))["error_delivery"],
        json!("known-not-delivered")
    );
    assert_eq!(mux.with_state(|state| state.workspaces.len()), workspaces);

    // Bad parameters fail like their line: a bad request, not a refusal to
    // retry after the handoff.
    let bad = json!({"id": 9, "cmd": "read-screen", "surface": "not-a-surface"});
    let line = client.line_reply(&bad);
    assert_ne!(line["error_code"], json!(DAEMON_SHUTDOWN_PENDING_CODE), "{line}");
    let (header, framed) = client.frame_reply(9, &bad);
    assert_answers(&header, FrameKind::Error, 9, "read-screen");
    assert_eq!(framed, line);

    // The header check's body parse and the refusal's `Request` parse, per
    // frame (no resource-envelope probe), and the bad request's `id` read.
    let parses = mux.ipc_stats().snapshot().parses.frames;
    assert_eq!((parses.requests, parses.json_parses), (4, 9), "{parses:?}");

    // A failed handoff leaves the connection serving frames.
    mux.cancel_daemon_handoff(client.client_id());
    let (header, reply) = client.frame_reply(10, &json!({"cmd": "ping"}));
    assert_answers(&header, FrameKind::Reply, 10, "ping");
    assert_eq!(reply["ok"], json!(true), "{reply}");
    assert_eq!(client.finish(), ConnectionEnd::PeerClosed);
}

/// A client that declared another revision than this daemon's is granted no
/// frames: its REQUEST frame closes the connection before any parse, and its
/// lines are served.
#[test]
fn api_revision_frames_are_not_granted_at_another_revision() {
    let mut client = Client::granted("other-revision");
    let (current, _) = api_revision_wire::identify_fields();
    let reply = client.line_reply(&json!({
        "id": 2,
        "cmd": "set-client-info",
        "name": "frames",
        "capabilities": ["ipc-frames-v2"],
        "api_revision": current + 1,
    }));
    assert_eq!(reply["ok"], json!(true), "{reply}");
    let id = client.client_id();
    assert!(!client.mux.control_clients.supports_capability(id, "ipc-frames-v2"));
    assert_eq!(client.line_reply(&json!({"id": 3, "cmd": "ping"}))["ok"], json!(true));

    client.send(&request(4, &json!({"cmd": "ping"})));
    assert!(client.next().is_none(), "the daemon answered an ungranted frame");
    assert_eq!(
        client.finish(),
        ConnectionEnd::BadMessage(ConnectionBadMessage::Wire(
            cmux_ipc::BadMessage::FramesNotNegotiated
        ))
    );
}

/// `server-stats` `ipc` counts a framed connection like a line one: the
/// REQUEST frames that arrived and the REPLY frames sent, by kind, the
/// framed requests and their parses, and a refused frame as a bad message.
#[test]
fn frame_dispatch_ipc_counts_frames_their_parses_and_bad_frames() {
    let mut client = Client::granted("ipc");
    let mux = client.mux.clone();
    let ping = json!({"cmd": "ping"});
    let request_bytes = request(1, &ping).len();
    for request_id in [1, 2] {
        let (header, _) = client.frame_reply(request_id, &ping);
        assert_answers(&header, FrameKind::Reply, request_id, "ping");
    }
    let full = client.line_reply(&json!({"id": 3, "cmd": "server-stats", "include": ["ipc"]}));
    let ipc = &full["data"]["ipc"];
    let row = |direction: &str, kind: &str| {
        ipc[direction]
            .as_array()
            .and_then(|rows| rows.iter().find(|row| row["kind"] == kind).cloned())
            .unwrap_or_else(|| panic!("no {kind} row in {direction}: {ipc}"))
    };
    let received = row("received", "request");
    assert_eq!(received["messages"], json!(2), "{ipc}");
    assert_eq!(received["bytes"], json!(2 * request_bytes), "{ipc}");
    let sent = row("sent", "reply");
    assert_eq!(sent["messages"], json!(2), "{ipc}");
    assert!(sent["bytes"].as_u64().unwrap() > 2 * 16, "header and payload: {ipc}");
    let frames = &ipc["parses"]["frames"];
    assert_eq!(frames["requests"], json!(2), "{ipc}");
    assert!(
        frames["json_parses"].as_u64().unwrap() >= 2 * 2,
        "the header check's body parse and the line path's: {ipc}"
    );
    assert_eq!(ipc["bad_message"], json!(0), "{ipc}");

    client.send(&call_frame(FrameKind::Request, 4, 0x01FF, PriorityHint::Control, b"{}"));
    client.closed_with(CallRefusal::UnknownMethod { method_id: 0x01FF });
    let ipc = mux.ipc_stats().snapshot();
    assert_eq!(ipc.bad_message, 1);
    assert_eq!(ipc.streams.open, 0);
}

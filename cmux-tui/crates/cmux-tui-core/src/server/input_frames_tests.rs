//! INPUT frames over a real socket pair, on streams a real
//! `attach-surface {stream}` opened: the bytes reach the terminal in order
//! on their stream's sequence under the connection's cause, nothing answers
//! them and nothing parses them; an ended terminal gives one `input-failed`
//! until a write reaches a terminal again or the stream is opened again;
//! INPUT obeys a line's shutdown, handoff and remote gates.
//!
//! A `send` with no bytes on the stream is the fence: its reply comes after
//! every item queued on the stream before it ran, and every `input-failed`
//! those items sent.

use std::io::Write;
use std::sync::Arc;
use std::sync::mpsc::{self, Receiver, Sender};

use cmux_ipc::{Aux, CallAux, CallFlags, FrameHeader, FrameKind, Message};
use serde_json::{Value, json};

use super::CallRefusal;
use super::tests::{Client, method};
use crate::SurfaceId;
use crate::diagnostics::IpcSnapshot;
use crate::event_cause::EventCause;
use crate::mux::DaemonHandoffRequest;
use crate::remote_relay_state::LinkPeer;
use crate::server::VIEW_ATTACHMENT_LEASE_CAPABILITY;
use crate::server::line_connection::{ConnectionBadMessage, ConnectionEnd};

/// What the daemon sent: an event line, or the answer to a request.
#[derive(Debug)]
enum Seen {
    Event(Value),
    Answer { kind: FrameKind, request_id: u32, body: Value },
    Line(Value),
}

fn next_seen(client: &mut Client) -> Option<Seen> {
    loop {
        match client.reader.next_message().unwrap() {
            Some(Message::Json(line)) if line.trim().is_empty() => {}
            Some(Message::Json(line)) => {
                let value: Value = serde_json::from_str(line).unwrap();
                return Some(if value.get("event").is_some() {
                    Seen::Event(value)
                } else {
                    Seen::Line(value)
                });
            }
            Some(Message::Frame(frame)) => {
                let header = *frame.header();
                if let Some(call) = header.call() {
                    let body = serde_json::from_slice(frame.payload()).unwrap();
                    return Some(Seen::Answer {
                        kind: header.kind(),
                        request_id: call.request_id,
                        body,
                    });
                }
            }
            None => {
                if client.reader.read_from(&mut client.read_half).unwrap() == 0 {
                    return None;
                }
            }
        }
    }
}

/// The `input-failed` events read up to the answer to `request_id`, and
/// that answer.
fn until_answer(client: &mut Client, request_id: u32) -> (Vec<Value>, FrameKind, Value) {
    let mut failed = Vec::new();
    loop {
        match next_seen(client).expect("the daemon closed before the answer") {
            Seen::Event(event) if event["event"] == "input-failed" => failed.push(event),
            Seen::Answer { kind, request_id: id, body } if id == request_id => {
                return (failed, kind, body);
            }
            Seen::Event(_) | Seen::Answer { .. } | Seen::Line(_) => {}
        }
    }
}

fn stream_request(stream: u16, request_id: u32, body: &Value) -> Vec<u8> {
    let method = method(body["cmd"].as_str().unwrap());
    let payload = body.to_string();
    let aux = Aux::Call(CallAux {
        request_id,
        method_id: method.id.raw(),
        priority: method.priority,
        flags: CallFlags::empty(),
    });
    let header =
        FrameHeader::new(FrameKind::Request, stream, u32::try_from(payload.len()).unwrap(), aux)
            .unwrap();
    let mut bytes = header.encode().to_vec();
    bytes.extend_from_slice(payload.as_bytes());
    bytes
}

fn input(stream: u16, flow: u64, bytes: &[u8]) -> Vec<u8> {
    let len = u32::try_from(bytes.len()).unwrap();
    let header = FrameHeader::new(FrameKind::Input, stream, len, Aux::FlowId(flow)).unwrap();
    let mut frame = header.encode().to_vec();
    frame.extend_from_slice(bytes);
    frame
}

fn failed(stream: u16, reason: &str, bytes: u64) -> Value {
    json!({"event": "input-failed", "stream": stream, "reason": reason, "bytes": bytes})
}

fn input_kind(ipc: &IpcSnapshot) -> u64 {
    ipc.received.iter().find(|row| row.kind == "input").map_or(0, |row| row.messages)
}

/// A connection that may attach views, and a terminal whose PTY input the
/// test reads.
fn terminal_client(label: &str) -> (Client, Arc<crate::Surface>, Receiver<Vec<u8>>) {
    let client =
        Client::granted_with(&format!("input-frames-{label}"), &[VIEW_ATTACHMENT_LEASE_CAPABILITY]);
    let surface = client.mux.new_workspace(None, Some((80, 24))).unwrap();
    let typed = record_input(&surface);
    (client, surface, typed)
}

/// Opens `stream` on `surface` and waits for its READY reply; returns the
/// view's lease.
fn open(client: &mut Client, stream: u16, request_id: u32, surface: SurfaceId) -> String {
    client.send(&stream_request(
        stream,
        request_id,
        &json!({"cmd": "attach-surface", "surface": surface}),
    ));
    let (failed, kind, reply) = until_answer(client, request_id);
    assert_eq!(kind, FrameKind::Reply, "{reply}");
    assert_eq!(failed, Vec::<Value>::new());
    reply["data"]["lease"].as_str().expect("a view lease").to_owned()
}

/// Every `input-failed` the stream's items queued before the fence sent.
fn fence(client: &mut Client, stream: u16, request_id: u32, surface: SurfaceId) -> Vec<Value> {
    client.send(&stream_request(
        stream,
        request_id,
        &json!({"cmd": "send", "surface": surface, "text": ""}),
    ));
    let (failed, kind, reply) = until_answer(client, request_id);
    assert_eq!(kind, FrameKind::Reply, "{reply}");
    failed
}

/// The respawn's delay of `surface`'s slot (terminal_respawn.rs): the mux
/// has no runtime for its SurfaceId, so its terminal ended.
fn detach_runtime(client: &Client, surface: &crate::Surface) -> Arc<crate::Surface> {
    let terminal = surface.terminal_public_id().cloned().expect("a terminal");
    // Absent after an earlier detach: the test puts back only the runtime.
    let _ = client.mux.remove_terminal_catalog_for_test(&terminal);
    let runtime = client.mux.remove_surface_runtime_for_test(surface.id).expect("its runtime");
    client.mux.unregister_kitty_image_surface(&runtime).unwrap();
    assert!(client.mux.surface(surface.id).is_none(), "the slot has no runtime");
    runtime
}

fn record_input(surface: &crate::Surface) -> Receiver<Vec<u8>> {
    let (written, typed) = mpsc::channel();
    surface.replace_input_writer_for_test(Box::new(InputRecorder { written, causes: None }));
    typed
}

/// The PTY input writer of a test terminal: each write is one message, with
/// the cause in force on the thread that wrote it when `causes` is set.
struct InputRecorder {
    written: Sender<Vec<u8>>,
    causes: Option<Sender<EventCause>>,
}

impl Write for InputRecorder {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        if let Some(causes) = &self.causes {
            let _ = causes.send(EventCause::current());
        }
        let _ = self.written.send(bytes.to_vec());
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

fn typed_bytes(typed: &Receiver<Vec<u8>>) -> Vec<u8> {
    typed.try_iter().flatten().collect()
}

#[test]
fn input_frames_reach_the_terminal_in_order_with_no_reply_and_no_parse() {
    const KEYS: usize = 10_000;
    let (mut client, surface, typed) = terminal_client("order");
    open(&mut client, 7, 10, surface.id);

    // What one fence costs, so the INPUT frames' share is what is left.
    let before = client.mux.ipc_stats().snapshot();
    assert_eq!(fence(&mut client, 7, 11, surface.id), Vec::<Value>::new());
    let one_fence = client.mux.ipc_stats().snapshot();
    let fence_parses = one_fence.parses.frames.json_parses - before.parses.frames.json_parses;

    let mut expected = String::new();
    for key in 0..KEYS {
        let line = format!("k{key:05}\n");
        expected.push_str(&line);
        client.send(&input(7, key as u64 + 1, line.as_bytes()));
    }
    // Nothing answered an INPUT: the next answer is the fence's.
    assert_eq!(fence(&mut client, 7, 12, surface.id), Vec::<Value>::new(), "nothing failed");
    let after = client.mux.ipc_stats().snapshot();
    assert_eq!(input_kind(&after) - input_kind(&one_fence), KEYS as u64);
    assert_eq!(after.parses.frames.requests - one_fence.parses.frames.requests, 1, "the fence");
    assert_eq!(
        after.parses.frames.json_parses - one_fence.parses.frames.json_parses,
        fence_parses,
        "an INPUT frame is never parsed"
    );
    assert_eq!(after.parses.lines.requests, one_fence.parses.lines.requests);
    assert_eq!(after.bad_message, 0);

    let written = typed_bytes(&typed);
    assert_eq!(String::from_utf8(written).unwrap(), expected, "the keys arrived out of order");
    assert_eq!(client.finish(), ConnectionEnd::PeerClosed);
}

#[test]
fn input_frames_an_ended_terminal_fails_once() {
    let (mut client, surface, typed) = terminal_client("ended");
    open(&mut client, 9, 10, surface.id);
    client.send(&input(9, 1, b"before\n"));
    assert_eq!(fence(&mut client, 9, 11, surface.id), Vec::<Value>::new());
    assert_eq!(typed_bytes(&typed), b"before\n");

    surface.mark_dead_for_test();
    for key in [b"one".as_slice(), b"two", b"three"] {
        client.send(&input(9, 0, key));
    }
    // The fence itself is a `send` to the ended terminal: it may fail, so
    // only the events matter here.
    client.send(&stream_request(9, 12, &json!({"cmd": "send", "surface": surface.id, "text": ""})));
    let (events, _, _) = until_answer(&mut client, 12);
    assert_eq!(events, [failed(9, "terminal_ended", 3)]);
    // Later INPUT on the stream is dropped with no second event.
    client.send(&input(9, 0, b"four"));
    client.send(&stream_request(9, 13, &json!({"cmd": "send", "surface": surface.id, "text": ""})));
    let (events, _, _) = until_answer(&mut client, 13);
    assert_eq!(events, Vec::<Value>::new());
    assert_eq!(typed.try_iter().count(), 0, "nothing reached the ended terminal");
    assert_eq!(client.finish(), ConnectionEnd::PeerClosed);
}

#[test]
fn input_frames_on_a_never_announced_stream_close_with_bad_message() {
    let (mut client, _surface, typed) = terminal_client("unknown");
    client.send(&input(5, 0, b"x"));
    assert!(next_seen(&mut client).is_none(), "the daemon answered a bad message");
    assert_eq!(
        client.finish(),
        ConnectionEnd::BadMessage(ConnectionBadMessage::UnknownStream {
            kind: FrameKind::Input,
            stream: 5
        })
    );
    assert_eq!(typed.try_iter().count(), 0);
}

#[test]
fn input_frames_reach_a_respawned_terminal_under_the_same_surface_id() {
    let (mut client, surface, _typed) = terminal_client("respawn");
    let id = surface.id;
    open(&mut client, 7, 10, id);

    // The respawn's delay: the slot has no runtime, so the terminal ended.
    let ended = detach_runtime(&client, &surface);
    client.send(&input(7, 0, b"lost"));
    client.send(&input(7, 0, b"lost too"));
    client.send(&stream_request(7, 11, &json!({"cmd": "send", "surface": id, "text": ""})));
    let (events, _, _) = until_answer(&mut client, 11);
    assert_eq!(events, [failed(7, "terminal_ended", 4)]);

    let respawned = crate::Surface::spawn_for_test(
        id,
        crate::SurfaceOptions::default(),
        Arc::downgrade(&client.mux),
    )
    .unwrap();
    let typed = record_input(&respawned);
    client.mux.insert_surface_runtime_for_test(respawned.clone());
    client.send(&input(7, 0, b"typed\n"));
    assert_eq!(
        fence(&mut client, 7, 12, id),
        Vec::<Value>::new(),
        "a delivered write sends no event"
    );
    assert_eq!(typed_bytes(&typed), b"typed\n", "the keys went nowhere");

    // The latch reset on that write: the next end is reported again.
    respawned.mark_dead_for_test();
    client.send(&input(7, 0, b"again"));
    client.send(&stream_request(7, 13, &json!({"cmd": "send", "surface": id, "text": ""})));
    let (events, _, _) = until_answer(&mut client, 13);
    assert_eq!(events, [failed(7, "terminal_ended", 5)]);
    drop(ended);
    assert_eq!(client.finish(), ConnectionEnd::PeerClosed);
}

#[test]
fn input_frames_a_reopened_stream_on_the_same_surface_is_a_new_view() {
    let (mut client, surface, _typed) = terminal_client("reopen");
    let id = surface.id;
    let lease = open(&mut client, 7, 10, id);
    let removed = detach_runtime(&client, &surface);
    client.send(&input(7, 0, b"one"));
    client.send(&stream_request(7, 11, &json!({"cmd": "send", "surface": id, "text": ""})));
    let (events, _, _) = until_answer(&mut client, 11);
    assert_eq!(events, [failed(7, "terminal_ended", 3)]);

    // The view detaches (stream-end), then the client opens id 7 on the
    // same surface again: the new view hears that its terminal ended.
    client.mux.insert_surface_runtime_for_test(removed);
    client.send(&super::tests::request(
        12,
        &json!({"cmd": "detach-attached-view", "surface": id, "lease": lease}),
    ));
    let (_, kind, body) = until_answer(&mut client, 12);
    assert_eq!(kind, FrameKind::Reply, "{body}");
    open(&mut client, 7, 13, id);
    let removed = detach_runtime(&client, &surface);
    client.send(&input(7, 0, b"two!"));
    client.send(&stream_request(7, 14, &json!({"cmd": "send", "surface": id, "text": ""})));
    let (events, _, _) = until_answer(&mut client, 14);
    assert_eq!(events, [failed(7, "terminal_ended", 4)]);

    // Back on the reopened view, a live terminal takes the bytes.
    client.mux.insert_surface_runtime_for_test(removed);
    let typed = record_input(&surface);
    client.send(&input(7, 0, b"three"));
    assert_eq!(fence(&mut client, 7, 15, id), Vec::<Value>::new());
    assert_eq!(typed_bytes(&typed), b"three");
    assert_eq!(client.finish(), ConnectionEnd::PeerClosed);
}

#[test]
fn input_frames_run_under_the_connections_cause() {
    let (mut client, surface, _typed) = terminal_client("cause");
    let (causes_tx, causes) = mpsc::channel();
    let (written, _written) = mpsc::channel();
    surface.replace_input_writer_for_test(Box::new(InputRecorder {
        written,
        causes: Some(causes_tx),
    }));
    open(&mut client, 3, 10, surface.id);
    let (_, expected) = client.mux.frame_client(client.client_id());
    assert_ne!(expected, EventCause::Program, "the connection has a cause of its own");
    client.send(&input(3, 0, b"x"));
    assert_eq!(fence(&mut client, 3, 11, surface.id), Vec::<Value>::new());
    assert_eq!(causes.try_iter().collect::<Vec<_>>(), [expected]);
    assert_eq!(client.finish(), ConnectionEnd::PeerClosed);
}

#[test]
fn input_frames_after_shutdown_requested_close_without_writing() {
    let (mut client, surface, typed) = terminal_client("shutdown");
    open(&mut client, 2, 10, surface.id);
    client.mux.request_daemon_shutdown();
    client.send(&input(2, 0, b"rm -rf\n"));
    while next_seen(&mut client).is_some() {}
    let end = client.finish();
    assert!(!matches!(end, ConnectionEnd::BadMessage(_)), "{end:?}");
    assert_eq!(typed.try_iter().count(), 0, "no input ran after the shutdown");
}

#[test]
fn input_frames_during_a_pending_handoff_are_refused_and_the_connection_stays() {
    let (mut client, surface, typed) = terminal_client("handoff");
    open(&mut client, 6, 10, surface.id);
    let requester = client.client_id();
    client.mux.begin_daemon_handoff(requester, DaemonHandoffRequest::unfenced(true)).unwrap();
    client.send(&input(6, 0, b"held"));
    // A line meanwhile is refused too, and its refusal comes after the
    // INPUT's refusal, which the reader sent as it read the frame.
    client.line(&json!({"id": 5, "cmd": "ping"}));
    let mut events = Vec::new();
    let refused = loop {
        match next_seen(&mut client).expect("the line's refusal") {
            Seen::Event(event) if event["event"] == "input-failed" => events.push(event),
            Seen::Line(reply) if reply["id"] == json!(5) => break reply,
            Seen::Event(_) | Seen::Answer { .. } | Seen::Line(_) => {}
        }
    };
    assert_eq!(refused["ok"], json!(false), "{refused}");
    assert_eq!(events, [failed(6, "daemon_handoff", 4)]);
    client.mux.cancel_daemon_handoff(requester);
    assert_eq!(typed.try_iter().count(), 0, "nothing was written during the handoff");

    client.send(&input(6, 0, b"after"));
    assert_eq!(fence(&mut client, 6, 11, surface.id), Vec::<Value>::new());
    assert_eq!(typed_bytes(&typed), b"after");
    assert_eq!(client.finish(), ConnectionEnd::PeerClosed);
}

#[test]
fn input_frames_from_a_remote_relay_client_close_with_bad_message() {
    let (mut client, surface, typed) = terminal_client("remote");
    open(&mut client, 8, 10, surface.id);
    let install = "install_input_frames";
    client.mux.record_remote_check(install).unwrap();
    let peer = LinkPeer { install: install.into(), user: "user_a".into(), team: "team_a".into() };
    client.mux.bind_remote_peer(client.client_id(), &peer).unwrap();
    assert!(client.mux.frame_client(client.client_id()).0, "classified remote");
    client.send(&input(8, 0, b"remote keys"));
    while next_seen(&mut client).is_some() {}
    assert_eq!(
        client.finish(),
        ConnectionEnd::BadMessage(ConnectionBadMessage::Call(CallRefusal::RemoteInput {
            stream: 8
        }))
    );
    assert_eq!(typed.try_iter().count(), 0, "no remote input reached the terminal");
}

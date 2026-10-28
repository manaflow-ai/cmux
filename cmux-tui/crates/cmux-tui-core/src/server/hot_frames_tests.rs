//! BINARY REQUEST frames of the hot methods (p05-ipc-183) over a real
//! socket pair: the body decodes from its layout with no JSON parse, runs
//! the handler its line runs and gets the reply its JSON frame gets; a value
//! over its layout's bounds goes as a JSON frame of the same method; a body
//! that is not its layout, a BINARY flag on a JSON-only method, and a
//! remote-relay client's BINARY request close the connection.

use cmux_ipc::hot::{
    HotEncodeError, SCROLL_SURFACE_REQUEST, SNAPSHOT_REQUEST_REQUEST, ScrollSurfaceRequest,
    SnapshotRequestRequest,
};
use cmux_ipc::{Aux, CallAux, CallFlags, FrameHeader, FrameKind, Message, MethodTables};
use serde_json::{Value, json};

use super::tests::{Client, Got, method, request};
use super::{CallRefusal, framed_method_ids};
use crate::remote_relay_state::LinkPeer;
use crate::server::line_connection::{ConnectionBadMessage, ConnectionEnd};

const HOT: [&str; 4] =
    ["resize-attached-view", "set-client-sizing", "scroll-surface", "snapshot-request"];

/// A REQUEST frame of `name` on `stream` with the BINARY flag and `body`.
fn binary_request(stream: u16, request_id: u32, name: &str, body: &[u8]) -> Vec<u8> {
    let method = method(name);
    let aux = Aux::Call(CallAux {
        request_id,
        method_id: method.id.raw(),
        priority: method.priority,
        flags: CallFlags::BINARY,
    });
    let header =
        FrameHeader::new(FrameKind::Request, stream, u32::try_from(body.len()).unwrap(), aux)
            .unwrap();
    let mut bytes = header.encode().to_vec();
    bytes.extend_from_slice(body);
    bytes
}

fn scroll_body(surface: u64, delta: i64) -> Vec<u8> {
    let mut out = Vec::new();
    SCROLL_SURFACE_REQUEST.encode(&ScrollSurfaceRequest { delta, surface }, &mut out).unwrap();
    out
}

/// The reply frame to `request_id`, its body, and that it answers with the
/// request's call fields (flags cleared: a reply is JSON).
fn reply_to(client: &mut Client, request_id: u32, name: &str) -> (FrameKind, Value) {
    match client.next() {
        Some(Got::Frame(header, body)) => {
            let call = header.call().unwrap();
            let method = method(name);
            assert_eq!(
                (call.request_id, call.method_id, call.flags),
                (request_id, method.id.raw(), CallFlags::empty())
            );
            (header.kind(), body)
        }
        other => panic!("expected the reply to {request_id}: {other:?}"),
    }
}

fn frame_parses(client: &Client) -> (u64, u64) {
    let parses = client.mux.ipc_stats().snapshot().parses.frames;
    (parses.requests, parses.json_parses)
}

/// The hot methods stay framed: `identify {revisions}` lists them, so a
/// client may frame them with either body.
#[test]
fn hot_frames_the_hot_methods_stay_framed() {
    let framed = framed_method_ids();
    for name in HOT {
        assert!(framed.contains(&method(name).id.raw()), "{name} is framed");
    }
}

/// A BINARY scroll-surface runs the handler its JSON frame runs and gets the
/// same reply, and the daemon parses no JSON for it.
#[test]
fn hot_frames_a_binary_request_parses_no_json_and_answers_like_json() {
    let mut client = Client::granted_with("hot-binary", &[]);
    let surface = client.mux.new_workspace(None, Some((80, 24))).unwrap().id;

    let before = frame_parses(&client);
    client.send(&binary_request(0, 1, "scroll-surface", &scroll_body(surface, -3)));
    let (kind, binary) = reply_to(&mut client, 1, "scroll-surface");
    assert_eq!(kind, FrameKind::Reply, "{binary}");
    let after = frame_parses(&client);
    assert_eq!((after.0 - before.0, after.1 - before.1), (1, 0), "one request, no JSON parse");

    let json = json!({"cmd": "scroll-surface", "surface": surface, "delta": -3});
    client.send(&request(2, &json));
    let (kind, framed) = reply_to(&mut client, 2, "scroll-surface");
    assert_eq!(kind, FrameKind::Reply);
    assert_eq!(binary, framed);
    let json_parses = frame_parses(&client).1 - after.1;
    assert!(json_parses >= 2, "the JSON body parses (header check and handler): {json_parses}");

    // A failing request: the same ERROR body as its JSON frame.
    client.send(&binary_request(0, 3, "scroll-surface", &scroll_body(987_654, 1)));
    let (kind, binary) = reply_to(&mut client, 3, "scroll-surface");
    assert_eq!(kind, FrameKind::Error);
    client.send(&request(4, &json!({"cmd": "scroll-surface", "surface": 987_654, "delta": 1})));
    assert_eq!(reply_to(&mut client, 4, "scroll-surface"), (FrameKind::Error, binary));
    assert_eq!(client.mux.ipc_stats().snapshot().bad_message, 0);
    assert_eq!(client.finish(), ConnectionEnd::PeerClosed);
}

/// A value over its layout's bounds cannot be encoded; its sender writes the
/// method's JSON body on a frame without the BINARY flag, which the daemon
/// serves like its line.
#[test]
fn hot_frames_an_over_bound_value_falls_back_to_a_json_frame() {
    let mut client = Client::granted_with("hot-fallback", &[]);
    let surface = client.mux.new_workspace(None, Some((80, 24))).unwrap().id;
    let long_id = "r".repeat(129);
    let body = SnapshotRequestRequest {
        have: None,
        reason: None,
        request_id: Some(long_id.clone()),
        stream: None,
        surface,
    };
    let mut out = vec![0xAA];
    assert_eq!(
        SNAPSHOT_REQUEST_REQUEST.encode(&body, &mut out),
        Err(HotEncodeError::StringTooLong { len: 129, max: 128 })
    );
    assert_eq!(out, [0xAA]);

    let json = json!({"cmd": "snapshot-request", "surface": surface, "request_id": long_id});
    let line = client.line_reply(&json);
    client.send(&request(5, &json));
    let (kind, framed) = reply_to(&mut client, 5, "snapshot-request");
    assert_eq!(kind, FrameKind::Error, "{framed}");
    assert_eq!(framed, line);
    assert_eq!(client.finish(), ConnectionEnd::PeerClosed);
}

/// A BINARY request on an attach stream runs in the stream's order, decoded.
#[test]
fn hot_frames_a_binary_request_runs_on_its_stream() {
    let mut client = Client::granted_with("hot-stream", &[]);
    let surface = client.mux.new_workspace(None, Some((80, 24))).unwrap().id;
    let attach = json!({"cmd": "attach-surface", "surface": surface});
    let opener = method("attach-surface");
    let body = attach.to_string();
    let aux = Aux::Call(CallAux {
        request_id: 10,
        method_id: opener.id.raw(),
        priority: opener.priority,
        flags: CallFlags::empty(),
    });
    let header =
        FrameHeader::new(FrameKind::Request, 7, u32::try_from(body.len()).unwrap(), aux).unwrap();
    let mut bytes = header.encode().to_vec();
    bytes.extend_from_slice(body.as_bytes());
    client.send(&bytes);
    client.send(&binary_request(7, 11, "scroll-surface", &scroll_body(surface, -1)));

    let mut answers = Vec::new();
    while answers.len() < 2 {
        match client.reader.next_message().unwrap() {
            Some(Message::Frame(frame)) => {
                let header = *frame.header();
                if let Some(call) = header.call() {
                    let body: Value = serde_json::from_slice(frame.payload()).unwrap();
                    answers.push((call.request_id, header.kind(), header.stream(), body));
                }
            }
            Some(Message::Json(_)) => {}
            None => {
                assert!(client.reader.read_from(&mut client.read_half).unwrap() > 0, "closed");
            }
        }
    }
    assert_eq!((answers[0].0, answers[0].1, answers[0].2), (10, FrameKind::Reply, 7));
    let (request_id, kind, stream, body) = &answers[1];
    assert_eq!((*request_id, *kind, *stream), (11, FrameKind::Reply, 7), "{body}");
    assert_eq!(body["ok"], json!(true), "{body}");
    assert_eq!(client.mux.ipc_stats().snapshot().bad_message, 0);
    assert_eq!(client.finish(), ConnectionEnd::PeerClosed);
}

fn closed_with(mut client: Client, refusal: CallRefusal) {
    assert!(client.next().is_none(), "the daemon answered a bad message");
    assert_eq!(client.finish(), ConnectionEnd::BadMessage(ConnectionBadMessage::Call(refusal)));
}

/// A BINARY body that is not its layout is a bad message, also when it is
/// not UTF-8 (it is never read as a line).
#[test]
fn hot_frames_a_body_that_is_not_its_layout_closes_with_bad_message() {
    let mut client = Client::granted_with("hot-bad-layout", &[]);
    let mut body = scroll_body(5, 1);
    body[0] = 2;
    client.send(&binary_request(0, 1, "scroll-surface", &body));
    let method_id = method("scroll-surface").id.raw();
    let error =
        cmux_ipc::hot::HotDecodeError::Version { name: "scroll-surface", expected: 1, found: 2 };
    closed_with(client, CallRefusal::BadLayout { method_id, error });

    let mut client = Client::granted_with("hot-bad-utf8", &[]);
    client.send(&binary_request(0, 1, "scroll-surface", &[0x01, 0xFF]));
    let error = cmux_ipc::hot::HotDecodeError::Truncated;
    closed_with(client, CallRefusal::BadLayout { method_id, error });
}

/// Only a method with a layout takes the BINARY flag.
#[test]
fn hot_frames_binary_on_a_json_method_closes_with_bad_message() {
    let mut client = Client::granted_with("hot-json-method", &[]);
    client.send(&binary_request(0, 1, "ping", b"{\"cmd\":\"ping\"}"));
    let ping = method("ping").id.raw();
    closed_with(
        client,
        CallRefusal::FlagsRefused { method_id: ping, flags: CallFlags::BINARY.bits() },
    );
}

/// Every binary method of the table is served on frames with either body.
#[test]
fn hot_frames_every_binary_method_takes_both_bodies() {
    let tables = MethodTables::schema();
    let framed = framed_method_ids();
    for method in tables.v12_families().flat_map(|family| family.iter()) {
        if matches!(method.payload, cmux_ipc::Payload::Binary { .. }) {
            assert!(framed.contains(&method.id.raw()), "{}", method.name);
            assert!(super::request_flags(method, CallFlags::BINARY).is_ok(), "{}", method.name);
            assert!(super::request_flags(method, CallFlags::empty()).is_ok(), "{}", method.name);
        }
    }
}

/// A remote-relay client's BINARY request is a bad message: its relay
/// policy reads lines only, so it sends the JSON body.
#[test]
fn hot_frames_a_remote_relay_clients_binary_request_closes_with_bad_message() {
    let mut client = Client::granted_with("hot-remote", &[]);
    let install = "install_hot_frames";
    client.mux.record_remote_check(install).unwrap();
    let peer = LinkPeer { install: install.into(), user: "user_a".into(), team: "team_a".into() };
    client.mux.bind_remote_peer(client.client_id(), &peer).unwrap();
    assert!(client.mux.frame_client(client.client_id()).0, "classified remote");
    client.send(&binary_request(0, 1, "scroll-surface", &scroll_body(5, 1)));
    let method_id = method("scroll-surface").id.raw();
    closed_with(client, CallRefusal::RemoteBinary { method_id });
}

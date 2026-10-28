//! Pending streams over a real socket pair: INPUT and stream
//! requests sent right behind `attach-surface{stream}` wait for its reply
//! and then reach the PTY in order; a stream that was never announced is a
//! bad message; an overflow ends only its own stream.
//!
//! Each test that opens a stream holds the connection's control sequence
//! with a `wait-for`, so the opener is still queued while the reader takes
//! the stream's frames: the stream is Pending for certain, not by timing.

use std::sync::{Arc, mpsc};
use std::time::Duration;

use crate::panic_free::RecoverPoison;
use crate::surface::PtyInputCapture;
use cmux_ipc::{Aux, CallAux, CallFlags, FrameHeader, FrameKind, Message};
use cmux_threads::sync::Mutex;
use serde_json::{Value, json};

use super::{STREAM_INPUT_CAPACITY, STREAM_REQUEST_CAPACITY, StreamProbe};
use crate::server::VIEW_ATTACHMENT_LEASE_CAPABILITY;
use crate::server::frame_dispatch::CallRefusal;
use crate::server::frame_dispatch::RequestFrames;
use crate::server::frame_dispatch::tests::{Client, cancel, method, request};
use crate::server::line_connection::{ConnectionBadMessage, ConnectionEnd};

/// What the daemon sent that the tests read: an event line, or the REPLY or
/// ERROR frame of a request. Other frames (attach output) are skipped.
#[derive(Debug)]
enum Seen {
    Event(Value),
    Answer { kind: FrameKind, stream: u16, request_id: u32, body: Value },
}

fn next_seen(client: &mut Client) -> Option<Seen> {
    loop {
        match client.reader.next_message().unwrap() {
            Some(Message::Json(line)) if line.trim().is_empty() => {}
            Some(Message::Json(line)) => {
                let value: Value = serde_json::from_str(line).unwrap();
                if value.get("event").is_some() {
                    return Some(Seen::Event(value));
                }
            }
            Some(Message::Frame(frame)) => {
                let header = *frame.header();
                if let Some(call) = header.call() {
                    let body = serde_json::from_slice(frame.payload()).unwrap();
                    return Some(Seen::Answer {
                        kind: header.kind(),
                        stream: header.stream(),
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

/// Everything read up to and including the answer to `request_id`.
fn until_answer(client: &mut Client, request_id: u32) -> Vec<Seen> {
    let mut seen = Vec::new();
    loop {
        let next = next_seen(client).expect("the daemon closed before the answer");
        let done = matches!(&next, Seen::Answer { request_id: id, .. } if *id == request_id);
        seen.push(next);
        if done {
            return seen;
        }
    }
}

fn answer(seen: &[Seen], request_id: u32) -> (FrameKind, u16, &Value) {
    seen.iter()
        .find_map(|seen| match seen {
            Seen::Answer { kind, stream, request_id: id, body } if *id == request_id => {
                Some((*kind, *stream, body))
            }
            _ => None,
        })
        .unwrap_or_else(|| panic!("no answer to {request_id}: {seen:?}"))
}

fn position(seen: &[Seen], matches: impl Fn(&Seen) -> bool) -> usize {
    seen.iter().position(matches).unwrap_or_else(|| panic!("not seen: {seen:?}"))
}

fn is_event(seen: &Seen, event: &str, stream: u16) -> bool {
    matches!(seen, Seen::Event(value) if value["event"] == event && value["stream"] == stream)
}

fn is_answer(seen: &Seen, request_id: u32) -> bool {
    matches!(seen, Seen::Answer { request_id: id, .. } if *id == request_id)
}

/// A REQUEST frame for `body` on `stream`.
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

fn input(stream: u16, flow: u64, payload: &[u8]) -> Vec<u8> {
    let header = FrameHeader::new(
        FrameKind::Input,
        stream,
        u32::try_from(payload.len()).unwrap(),
        Aux::FlowId(flow),
    )
    .unwrap();
    let mut bytes = header.encode().to_vec();
    bytes.extend_from_slice(payload);
    bytes
}

/// A connection, and one terminal whose PTY input the test reads.
fn terminal_client(label: &str) -> (Client, u64, PtyInputCapture) {
    let client = Client::granted_with(label, &[VIEW_ATTACHMENT_LEASE_CAPABILITY]);
    let surface = client.mux.new_workspace(None, Some((80, 24))).unwrap();
    let written = surface.capture_pty_input_for_test();
    (client, surface.id, written)
}

fn written(capture: &PtyInputCapture) -> String {
    String::from_utf8(capture.written()).unwrap()
}

/// Holds the control sequence: a `wait-for` that only its CANCEL ends.
fn hold_control(client: &mut Client, request_id: u32, surface: u64) {
    client.send(&request(
        request_id,
        &json!({"cmd": "wait-for", "surface": surface,
                "pattern": "pending-streams-never-printed", "timeout_ms": 60_000}),
    ));
}

fn attach(surface: u64) -> Value {
    json!({"cmd": "attach-surface", "surface": surface})
}

/// A `send` on the stream with no bytes: its reply comes after every item
/// queued on the stream before it ran.
fn fence(surface: u64) -> Value {
    json!({"cmd": "send", "surface": surface, "text": ""})
}

#[test]
fn stream_pending_input_sent_behind_attach_reaches_the_pty_in_order_after_ready() {
    let (mut client, surface, capture) = terminal_client("pending-order");
    hold_control(&mut client, 3, surface);
    client.send(&stream_request(7, 10, &attach(surface)));
    client.send(&input(7, 0, b"alpha-1\r"));
    // A stream request between them keeps its place in the stream's order.
    client.send(&stream_request(
        7,
        11,
        &json!({"cmd": "send", "surface": surface, "text": "bravo-2\r"}),
    ));
    client.send(&input(7, 0, b"charlie-3\r"));
    client.send(&stream_request(7, 12, &fence(surface)));
    // Nothing on stream 7 ran while its opener waited.
    assert_eq!(written(&capture), "");
    client.send(&cancel(3, "wait-for"));

    let seen = until_answer(&mut client, 12);
    let (kind, stream, body) = answer(&seen, 10);
    assert_eq!((kind, stream), (FrameKind::Reply, 7), "the attach is READY on stream 7: {body}");
    for request_id in [11, 12] {
        let (kind, stream, body) = answer(&seen, request_id);
        assert_eq!((kind, stream), (FrameKind::Reply, 7), "{body}");
    }
    assert!(
        position(&seen, |seen| is_answer(seen, 10)) < position(&seen, |seen| is_answer(seen, 11)),
        "the stream's request ran after its opener: {seen:?}"
    );
    assert!(
        !seen
            .iter()
            .any(|seen| is_event(seen, "stream-end", 7) || is_event(seen, "input-failed", 7)),
        "{seen:?}"
    );
    assert_eq!(written(&capture), "alpha-1\rbravo-2\rcharlie-3\r");

    // Items after the opener's reply go straight to the stream, in order.
    client.send(&input(7, 0, b"delta-4\r"));
    client.send(&stream_request(7, 13, &fence(surface)));
    until_answer(&mut client, 13);
    assert_eq!(written(&capture), "alpha-1\rbravo-2\rcharlie-3\rdelta-4\r");
    assert_eq!(client.mux.ipc_stats().snapshot().bad_message, 0);
    assert_eq!(client.finish(), ConnectionEnd::PeerClosed);
}

#[test]
fn stream_pending_a_never_announced_stream_is_a_bad_message() {
    let (mut client, _, capture) = terminal_client("pending-unknown-input");
    let mux = client.mux.clone();
    client.send(&input(9, 0, b"nobody-opened-9"));
    assert!(next_seen(&mut client).is_none(), "the daemon answered a bad message");
    assert_eq!(
        client.finish(),
        ConnectionEnd::BadMessage(ConnectionBadMessage::UnknownStream {
            kind: FrameKind::Input,
            stream: 9,
        })
    );
    assert_eq!(mux.ipc_stats().snapshot().bad_message, 1);
    assert_eq!(written(&capture), "");

    let (mut client, surface, _) = terminal_client("pending-unknown-request");
    let mux = client.mux.clone();
    client.send(&stream_request(9, 4, &json!({"cmd": "send", "surface": surface, "text": "x"})));
    assert!(next_seen(&mut client).is_none(), "the daemon answered a bad message");
    assert_eq!(
        client.finish(),
        ConnectionEnd::BadMessage(ConnectionBadMessage::Call(CallRefusal::UnknownStream {
            stream: 9
        }))
    );
    assert_eq!(mux.ipc_stats().snapshot().bad_message, 1);
}

#[test]
fn stream_pending_a_control_method_on_a_stream_is_a_bad_message() {
    let (mut client, _, _) = terminal_client("pending-not-stream-scoped");
    let ping = method("ping");
    assert!(!ping.stream_scoped);
    client.send(&stream_request(7, 4, &json!({"cmd": "ping"})));
    assert!(next_seen(&mut client).is_none());
    assert_eq!(
        client.finish(),
        ConnectionEnd::BadMessage(ConnectionBadMessage::Call(CallRefusal::NotStreamScoped {
            stream: 7,
            method_id: ping.id.raw(),
        }))
    );
}

#[test]
fn stream_pending_overflow_ends_only_its_stream() {
    let (mut client, surface, capture) = terminal_client("pending-overflow");
    let mux = client.mux.clone();
    hold_control(&mut client, 3, surface);
    client.send(&stream_request(7, 10, &attach(surface)));
    client.send(&stream_request(8, 12, &attach(surface)));
    client.send(&stream_request(
        7,
        13,
        &json!({"cmd": "send", "surface": surface, "text": "never-written"}),
    ));
    // Exactly the cap is held; one byte more overflows stream 7.
    client.send(&input(7, 0, &vec![b'z'; STREAM_INPUT_CAPACITY]));
    client.send(&input(7, 0, b"z"));
    // After its overflow, stream 7 is still an announced id: refused into
    // its end, not bad.
    client.send(&input(7, 0, b"late"));
    client.send(&input(8, 0, b"kilo-8\r"));
    client.send(&stream_request(8, 14, &fence(surface)));
    client.send(&cancel(3, "wait-for"));

    let seen = until_answer(&mut client, 14);
    assert!(!seen.iter().any(|seen| is_answer(seen, 13)), "stream-end answers it: {seen:?}");
    let failed = position(&seen, |seen| is_event(seen, "input-failed", 7));
    let Seen::Event(event) = &seen[failed] else { unreachable!() };
    assert_eq!(event["reason"], json!("overflow"), "{event}");
    assert_eq!(event["bytes"], json!(STREAM_INPUT_CAPACITY + 1 + 4), "one report for every byte");
    assert_eq!(seen.iter().filter(|seen| is_event(seen, "input-failed", 7)).count(), 1);
    let end = position(&seen, |seen| is_event(seen, "stream-end", 7));
    let Seen::Event(event) = &seen[end] else { unreachable!() };
    assert_eq!(event["reason"], json!("overflow"), "{event}");
    assert!(failed < end, "{seen:?}");
    // The opener of the ended stream fails instead of attaching.
    let (kind, stream, body) = answer(&seen, 10);
    assert_eq!((kind, stream), (FrameKind::Error, 7), "{body}");
    // Stream 8 and the connection go on.
    let (kind, stream, body) = answer(&seen, 12);
    assert_eq!((kind, stream), (FrameKind::Reply, 8), "{body}");
    assert!(!seen.iter().any(|seen| is_event(seen, "stream-end", 8)), "{seen:?}");
    assert_eq!(written(&capture), "kilo-8\r", "only stream 8 reached the PTY");
    // A request after the end is answered, not dropped.
    client.send(&stream_request(7, 15, &fence(surface)));
    let seen = until_answer(&mut client, 15);
    let (kind, stream, body) = answer(&seen, 15);
    assert_eq!((kind, stream), (FrameKind::Error, 7));
    assert_eq!(body["error_code"], json!("stream_ended"), "{body}");
    assert_eq!(mux.ipc_stats().snapshot().bad_message, 0);
    assert_eq!(client.finish(), ConnectionEnd::PeerClosed);
}

#[test]
fn stream_pending_request_cap_ends_the_stream_and_frees_its_request_ids() {
    let (mut client, surface, _) = terminal_client("pending-request-cap");
    hold_control(&mut client, 3, surface);
    client.send(&stream_request(7, 10, &attach(surface)));
    let first = 100u32;
    let count = u32::try_from(STREAM_REQUEST_CAPACITY).unwrap() + 1;
    for request_id in first..first + count {
        client.send(&stream_request(7, request_id, &fence(surface)));
    }
    client.send(&cancel(3, "wait-for"));
    let seen = until_answer(&mut client, 10);
    let (kind, stream, _) = answer(&seen, 10);
    assert_eq!((kind, stream), (FrameKind::Error, 7), "the ended stream's opener fails");
    // One `stream-end` answers every queued request: no reply per request.
    let end = position(&seen, |seen| is_event(seen, "stream-end", 7));
    let Seen::Event(event) = &seen[end] else { unreachable!() };
    assert_eq!(event["reason"], json!("overflow"), "{event}");
    assert!(!seen.iter().any(|seen| is_event(seen, "input-failed", 7)), "no INPUT was queued");
    assert!(
        !seen
            .iter()
            .any(|seen| matches!(seen, Seen::Answer { request_id, .. } if *request_id >= first)),
        "{seen:?}"
    );
    // Their ids are free: reusing one is not a duplicate.
    let (header, reply) = client.frame_reply(first, &json!({"cmd": "ping"}));
    assert_eq!(header.kind(), FrameKind::Reply, "{reply}");
    assert_eq!(client.mux.ipc_stats().snapshot().bad_message, 0);
    assert_eq!(client.finish(), ConnectionEnd::PeerClosed);
}

#[test]
fn stream_pending_a_failed_attach_ends_its_stream_before_its_error() {
    let (mut client, surface, capture) = terminal_client("pending-attach-failed");
    hold_control(&mut client, 3, surface);
    client.send(&stream_request(7, 10, &attach(987_654)));
    client.send(&input(7, 0, b"lost"));
    client.send(&cancel(3, "wait-for"));
    let seen = until_answer(&mut client, 10);
    let failed = position(&seen, |seen| is_event(seen, "input-failed", 7));
    let Seen::Event(event) = &seen[failed] else { unreachable!() };
    assert_eq!((&event["reason"], &event["bytes"]), (&json!("attach_failed"), &json!(4)));
    let end = position(&seen, |seen| is_event(seen, "stream-end", 7));
    let Seen::Event(event) = &seen[end] else { unreachable!() };
    assert_eq!(event["reason"], json!("attach_failed"), "{event}");
    let (kind, stream, _) = answer(&seen, 10);
    assert_eq!((kind, stream), (FrameKind::Error, 7));
    assert!(failed < end && end < position(&seen, |seen| is_answer(seen, 10)), "{seen:?}");

    // The id is free again: a new opener on 7 announces a new stream.
    client.send(&stream_request(7, 11, &attach(surface)));
    client.send(&input(7, 0, b"again-7\r"));
    client.send(&stream_request(7, 12, &fence(surface)));
    let seen = until_answer(&mut client, 12);
    let (kind, stream, body) = answer(&seen, 11);
    assert_eq!((kind, stream), (FrameKind::Reply, 7), "{body}");
    assert_eq!(written(&capture), "again-7\r", "the failed stream's INPUT never ran");

    // A live stream's id is in use.
    client.send(&stream_request(7, 13, &attach(surface)));
    let seen = until_answer(&mut client, 13);
    let (kind, _, body) = answer(&seen, 13);
    assert_eq!(kind, FrameKind::Error);
    assert_eq!(body["error_code"], json!("stream_in_use"), "{body}");
    assert_eq!(client.finish(), ConnectionEnd::PeerClosed);
}

#[test]
fn stream_pending_a_detached_view_frees_its_stream_id() {
    let (mut client, surface, capture) = terminal_client("pending-detached");
    client.send(&stream_request(7, 10, &attach(surface)));
    let seen = until_answer(&mut client, 10);
    let (kind, stream, reply) = answer(&seen, 10);
    assert_eq!((kind, stream), (FrameKind::Reply, 7), "{reply}");
    let lease = reply["data"]["lease"].as_str().expect("a view lease").to_owned();

    // While the view is attached its id is in use.
    client.send(&stream_request(7, 11, &attach(surface)));
    let seen = until_answer(&mut client, 11);
    let (kind, _, body) = answer(&seen, 11);
    assert_eq!(kind, FrameKind::Error);
    assert_eq!(body["error_code"], json!("stream_in_use"), "{body}");

    client.send(&request(
        12,
        &json!({"cmd": "detach-attached-view", "surface": surface, "lease": lease}),
    ));
    let seen = until_answer(&mut client, 12);
    let (kind, _, body) = answer(&seen, 12);
    assert_eq!(kind, FrameKind::Reply, "{body}");

    // The detached view's stream takes nothing more: INPUT is dropped and a
    // request is answered `stream_ended`.
    client.send(&input(7, 0, b"after-detach"));
    client.send(&stream_request(7, 13, &fence(surface)));
    let seen = until_answer(&mut client, 13);
    let (kind, _, body) = answer(&seen, 13);
    assert_eq!(kind, FrameKind::Error);
    assert_eq!(body["error_code"], json!("stream_ended"), "{body}");

    // The id opens again for a new view.
    client.send(&stream_request(7, 14, &attach(surface)));
    client.send(&input(7, 0, b"reopened-7\r"));
    client.send(&stream_request(7, 15, &fence(surface)));
    let seen = until_answer(&mut client, 15);
    let (kind, stream, body) = answer(&seen, 14);
    assert_eq!((kind, stream), (FrameKind::Reply, 7), "{body}");
    assert_eq!(written(&capture), "reopened-7\r");
    assert_eq!(client.finish(), ConnectionEnd::PeerClosed);
}

const PROBE_WAIT: Duration = Duration::from_secs(10);

/// Holds the first opener's handler in `target` until the test lets it go,
/// and tells the test each item the reader posts.
struct HoldFirstTarget {
    targeted: mpsc::Sender<()>,
    release: Mutex<Option<mpsc::Receiver<()>>>,
    posted: mpsc::Sender<()>,
}

impl StreamProbe for HoldFirstTarget {
    fn targeted(&self) {
        let Some(release) = self.release.lock().recover_poison().take() else { return };
        let _ = self.targeted.send(());
        let _ = release.recv_timeout(PROBE_WAIT);
    }

    fn posted(&self) {
        let _ = self.posted.send(());
    }
}

fn is_surface_event(seen: &Seen, surface: u64) -> bool {
    matches!(seen, Seen::Event(value) if value["surface"] == surface)
}

#[test]
fn stream_pending_an_overflow_after_target_ends_the_view_and_fails_the_opener() {
    let (targeted_tx, targeted) = mpsc::channel();
    let (release, release_rx) = mpsc::channel();
    let (posted_tx, posted) = mpsc::channel();
    let probe = Arc::new(HoldFirstTarget {
        targeted: targeted_tx,
        release: Mutex::new(Some(release_rx)),
        posted: posted_tx,
    });
    let mut client = Client::granted_with_frames(
        "pending-overflow-after-target",
        &[VIEW_ATTACHMENT_LEASE_CAPABILITY],
        move || RequestFrames::with_stream_probe(probe),
    );
    let terminal = client.mux.new_workspace(None, Some((80, 24))).unwrap();
    let capture = terminal.capture_pty_input_for_test();
    let surface = terminal.id;
    client.send(&stream_request(7, 10, &attach(surface)));
    // The opener's handler named its surface; the stream overflows before
    // the handler attaches the view and replies.
    targeted.recv_timeout(PROBE_WAIT).expect("the opener targets its stream");
    client.send(&input(7, 0, &vec![b'z'; STREAM_INPUT_CAPACITY]));
    client.send(&input(7, 0, b"z"));
    for _ in 0..2 {
        posted.recv_timeout(PROBE_WAIT).expect("the reader posts the INPUT");
    }
    release.send(()).unwrap();

    let seen = until_answer(&mut client, 10);
    let failed = position(&seen, |seen| is_event(seen, "input-failed", 7));
    let Seen::Event(event) = &seen[failed] else { unreachable!() };
    assert_eq!(event["reason"], json!("overflow"), "{event}");
    assert_eq!(event["bytes"], json!(STREAM_INPUT_CAPACITY + 1), "{event}");
    let end = position(&seen, |seen| is_event(seen, "stream-end", 7));
    let Seen::Event(event) = &seen[end] else { unreachable!() };
    assert_eq!(event["reason"], json!("overflow"), "{event}");
    assert!(failed < end, "{seen:?}");
    // The opener is answered ERROR, not OK, and nothing of its view comes
    // after the stream's end.
    let (kind, stream, body) = answer(&seen, 10);
    assert_eq!((kind, stream), (FrameKind::Error, 7), "{body}");
    assert_eq!(body["error_code"], json!("stream_ended"), "{body}");
    assert!(!seen[end..].iter().any(|seen| is_surface_event(seen, surface)), "{seen:?}");
    // The view is detached before the opener's answer.
    let views = client.mux.control_clients.surface_view_streams(client.client_id(), surface);
    assert!(views.is_none_or(|(_, views)| views.is_empty()), "the ended stream's view stays");
    assert_eq!(written(&capture), "");

    // The id is free: a new opener on 7 attaches and carries its INPUT.
    client.send(&stream_request(7, 11, &attach(surface)));
    client.send(&input(7, 0, b"after-7\r"));
    client.send(&stream_request(7, 12, &fence(surface)));
    let seen = until_answer(&mut client, 12);
    let (kind, stream, body) = answer(&seen, 11);
    assert_eq!((kind, stream), (FrameKind::Reply, 7), "{body}");
    assert!(!seen.iter().any(|seen| is_event(seen, "stream-end", 7)), "{seen:?}");
    assert_eq!(written(&capture), "after-7\r");
    assert_eq!(client.mux.ipc_stats().snapshot().bad_message, 0);
    assert_eq!(client.finish(), ConnectionEnd::PeerClosed);
}

#[test]
fn stream_pending_a_bound_stream_carries_input_past_the_pending_cap() {
    let (mut client, surface, capture) = terminal_client("pending-bound-uncapped");
    client.send(&stream_request(7, 10, &attach(surface)));
    let seen = until_answer(&mut client, 10);
    let (kind, stream, body) = answer(&seen, 10);
    assert_eq!((kind, stream), (FrameKind::Reply, 7), "{body}");

    // The caps hold only while the opener waits: a bound stream's INPUT
    // goes to its PTY as it comes.
    client.send(&input(7, 0, &vec![b'y'; STREAM_INPUT_CAPACITY]));
    client.send(&input(7, 0, b"y"));
    client.send(&stream_request(7, 11, &fence(surface)));
    let seen = until_answer(&mut client, 11);
    let (kind, stream, body) = answer(&seen, 11);
    assert_eq!((kind, stream), (FrameKind::Reply, 7), "{body}");
    assert!(
        !seen
            .iter()
            .any(|seen| is_event(seen, "stream-end", 7) || is_event(seen, "input-failed", 7)),
        "{seen:?}"
    );
    assert_eq!(capture.written().len(), STREAM_INPUT_CAPACITY + 1);
    assert_eq!(client.finish(), ConnectionEnd::PeerClosed);
}

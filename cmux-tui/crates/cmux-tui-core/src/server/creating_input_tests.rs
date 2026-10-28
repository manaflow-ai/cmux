//! A terminal create's stream over a real socket pair (p05-ipc-153): a
//! `split` REQUEST frame on stream S, on a connection granted
//! `creating-input-streams-v1`, binds S to the terminal id it minted when
//! the daemon takes it. INPUT frames sent while the terminal starts join its
//! creating queue in order, with no reply and no JSON parse; INPUT after it
//! is live is written in order; the view's `attach-surface` on S takes S
//! over, so no key passes another. INPUT the daemon cannot queue or write
//! comes back as `terminal-input-unclaimed`, with every later key, and S
//! ends: nothing of S follows its `stream-end`.
//!
//! Each test that needs the terminal creating holds the create inside its
//! spawn (a test hook that blocks until the test releases it), so the
//! terminal is creating for certain while the stream's frames arrive, not
//! by timing. The test runtime's terminals are in-process: their identity is
//! the mux's, found by the minted id like a hosted terminal's.

use std::sync::{Arc, mpsc};
use std::time::Duration;

use base64::Engine as _;
use cmux_ipc::{Aux, CallAux, CallFlags, FrameHeader, FrameKind, Message};
use cmux_threads::sync::Mutex;
use serde_json::{Value, json};

use crate::mux::creating_input::CREATING_INPUT_LIMIT;
use crate::panic_free::RecoverPoison;
use crate::server::frame_dispatch::CallRefusal;
use crate::server::frame_dispatch::tests::{Client, cancel, method, request};
use crate::server::line_connection::{ConnectionBadMessage, ConnectionEnd};
use crate::surface::PtyInputCapture;

/// The keys typed while the terminal starts.
const KEYS: usize = 200;

/// A terminal id the create mints (32 hex digits).
const TERMINAL_ID: &str = "0000000000004000800000000000153a";

/// The stream the create opens.
const STREAM: u16 = 9;

/// The grants a creating stream needs.
const GRANTS: [&str; 2] = ["attach-streams-v1", "creating-input-streams-v1"];

/// What the daemon sent that the tests read: an event line, or the REPLY or
/// ERROR frame of a request.
#[derive(Debug)]
enum Seen {
    Event(Value),
    Answer { kind: FrameKind, stream: u16, request_id: u32, body: Value },
}

fn next_seen(client: &mut Client) -> Seen {
    loop {
        match client.reader.next_message().unwrap() {
            Some(Message::Json(line)) if line.trim().is_empty() => {}
            Some(Message::Json(line)) => {
                let value: Value = serde_json::from_str(line).unwrap();
                if value.get("event").is_some() {
                    return Seen::Event(value);
                }
            }
            Some(Message::Frame(frame)) => {
                let header = *frame.header();
                if let Some(call) = header.call() {
                    return Seen::Answer {
                        kind: header.kind(),
                        stream: header.stream(),
                        request_id: call.request_id,
                        body: serde_json::from_slice(frame.payload()).unwrap(),
                    };
                }
            }
            None => {
                assert!(
                    client.reader.read_from(&mut client.read_half).unwrap() > 0,
                    "the daemon closed the connection"
                );
            }
        }
    }
}

/// Everything read until `done` matches, that one included.
fn read_until(client: &mut Client, done: impl Fn(&Seen) -> bool) -> Vec<Seen> {
    let mut seen = Vec::new();
    loop {
        let next = next_seen(client);
        let last = done(&next);
        seen.push(next);
        if last {
            return seen;
        }
    }
}

fn is_answer(seen: &Seen, request_id: u32) -> bool {
    matches!(seen, Seen::Answer { request_id: id, .. } if *id == request_id)
}

fn is_event(seen: &Seen, event: &str) -> bool {
    matches!(seen, Seen::Event(value) if value["event"] == event)
}

/// An event that names stream `stream`.
fn names_stream(seen: &Seen, stream: u16) -> bool {
    matches!(seen, Seen::Event(value) if value["stream"] == stream)
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

/// The bytes every `terminal-input-unclaimed` in `seen` gave back, in order.
fn given_back(seen: &[Seen]) -> Vec<u8> {
    seen.iter()
        .filter_map(|seen| match seen {
            Seen::Event(value) if value["event"] == "terminal-input-unclaimed" => {
                assert_eq!(value["terminal_id"], TERMINAL_ID, "{value}");
                Some(
                    base64::engine::general_purpose::STANDARD
                        .decode(value["bytes_base64"].as_str().unwrap())
                        .unwrap(),
                )
            }
            _ => None,
        })
        .flatten()
        .collect()
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

/// Sends `count` keys on the stream from key `first` on; returns their bytes.
fn type_keys(client: &mut Client, first: usize, count: usize) -> Vec<u8> {
    let mut typed = Vec::new();
    for key in first..first + count {
        let bytes = format!("k{key:03};");
        client.send(&input(STREAM, key as u64 + 1, bytes.as_bytes()));
        typed.extend_from_slice(bytes.as_bytes());
    }
    typed
}

/// A create held in its spawn until `release` is sent to or dropped;
/// `started` gets one message once it is held. `spawned` gets the PTY
/// capture of the terminal it spawned, installed before it is published.
struct HeldSpawn {
    release: mpsc::Sender<()>,
    started: mpsc::Receiver<()>,
    spawned: mpsc::Receiver<PtyInputCapture>,
}

fn hold_spawns(client: &Client) -> HeldSpawn {
    let (release, released) = mpsc::channel::<()>();
    let (start, started) = mpsc::channel::<()>();
    let held = Arc::new(Mutex::new((start, released)));
    client.mux.set_terminal_spawn_start_hook_for_test(Some(Arc::new(move || {
        let held = held.lock().recover_poison();
        let _ = held.0.send(());
        let _ = held.1.recv_timeout(Duration::from_secs(30));
    })));
    let (spawn, spawned) = mpsc::channel::<PtyInputCapture>();
    let spawn = Mutex::new(spawn);
    client.mux.set_terminal_spawned_hook_for_test(Some(Arc::new(move |surface| {
        let _ = spawn.lock().recover_poison().send(surface.capture_pty_input_for_test());
    })));
    HeldSpawn { release, started, spawned }
}

impl HeldSpawn {
    fn wait_started(&self) {
        self.started.recv_timeout(Duration::from_secs(10)).expect("the create never spawned");
    }

    fn capture(&self) -> PtyInputCapture {
        self.spawned.recv_timeout(Duration::from_secs(10)).expect("the create spawned no terminal")
    }
}

fn unhook(client: &Client) {
    client.mux.set_terminal_spawn_start_hook_for_test(None);
    client.mux.set_terminal_spawned_hook_for_test(None);
}

/// The first workspace's pane and terminal surface.
fn first_pane(client: &mut Client) -> (u64, u64) {
    let first = client.mux.new_workspace(None, Some((80, 24))).unwrap();
    let pane = client.mux.with_state(|state| state.pane_of(first.id)).expect("a pane");
    (pane, first.id)
}

fn split(pane: u64) -> Value {
    json!({"cmd": "split", "pane": pane, "dir": "right", "terminal_id": TERMINAL_ID})
}

/// A stream request whose answer comes after every item queued on the
/// stream before it: `send` by the creating terminal's id, no bytes.
fn fence() -> Value {
    json!({"cmd": "send", "terminal_id": TERMINAL_ID, "text": ""})
}

/// A stream request that also waits until the creating queue of `surface`'s
/// terminal was written: `send {surface}` with no bytes.
fn flush_fence(surface: u64) -> Value {
    json!({"cmd": "send", "surface": surface, "text": ""})
}

/// The surface a create's reply names.
fn created_surface(reply: &Value) -> u64 {
    reply["data"]["surface"].as_u64().unwrap_or_else(|| panic!("no surface: {reply}"))
}

fn frame_parses(client: &Client) -> (u64, u64) {
    let parses = client.mux.ipc_stats().snapshot().parses;
    (
        parses.frames.requests + parses.lines.requests,
        parses.frames.json_parses + parses.lines.json_parses,
    )
}

fn text(bytes: Vec<u8>) -> String {
    String::from_utf8(bytes).unwrap()
}

#[test]
fn creating_input_keys_reach_the_terminal_in_order_through_its_start_and_the_take_over() {
    let mut client = Client::granted_with("creating-input-order", &GRANTS);
    let (pane, _) = first_pane(&mut client);
    let held = hold_spawns(&client);
    client.send(&stream_request(STREAM, 10, &split(pane)));
    held.wait_started();

    // One fence alone: what a stream request costs in parses.
    let before = frame_parses(&client);
    client.send(&stream_request(STREAM, 11, &fence()));
    let seen = read_until(&mut client, |seen| is_answer(seen, 11));
    let one_fence = frame_parses(&client);
    assert_eq!(answer(&seen, 11).0, FrameKind::Reply, "{seen:?}");

    // N keys while the terminal starts, then a fence: they add no request
    // and no parse, and get no answer.
    let mut typed = type_keys(&mut client, 0, KEYS);
    client.send(&stream_request(STREAM, 12, &fence()));
    let mut seen = read_until(&mut client, |seen| is_answer(seen, 12));
    let after = frame_parses(&client);
    assert_eq!(
        (after.0 - one_fence.0, after.1 - one_fence.1),
        (one_fence.0 - before.0, one_fence.1 - before.1),
        "{KEYS} INPUT frames added requests or JSON parses"
    );
    let answers = seen.iter().filter(|seen| matches!(seen, Seen::Answer { .. })).count();
    assert_eq!(answers, 1, "only the fence answers: {seen:?}");
    let received = client.mux.ipc_stats().snapshot().received;
    let inputs = received.iter().find(|kind| kind.kind == FrameKind::Input.name());
    assert_eq!(inputs.map(|kind| kind.messages), Some(KEYS as u64), "{received:?}");

    // The create commits: its reply on S, and the queue goes to the live
    // terminal. M keys after it, then a fence that waits for that queue.
    held.release.send(()).unwrap();
    let capture = held.capture();
    seen.extend(read_until(&mut client, |seen| is_answer(seen, 10)));
    let (kind, stream, body) = answer(&seen, 10);
    assert_eq!((kind, stream), (FrameKind::Reply, STREAM), "{body}");
    let surface = created_surface(body);
    typed.extend(type_keys(&mut client, KEYS, KEYS / 2));
    client.send(&stream_request(STREAM, 13, &flush_fence(surface)));
    seen.extend(read_until(&mut client, |seen| is_answer(seen, 13)));
    assert_eq!(text(capture.written()), text(typed.clone()), "the queue, then the live keys");

    // The view's attach on S takes the stream over; its keys follow.
    client.send(&stream_request(STREAM, 14, &json!({"cmd": "attach-surface", "surface": surface})));
    seen.extend(read_until(&mut client, |seen| is_answer(seen, 14)));
    assert_eq!(answer(&seen, 14).0, FrameKind::Reply, "{seen:?}");
    typed.extend(type_keys(&mut client, KEYS + KEYS / 2, KEYS / 2));
    client.send(&stream_request(STREAM, 15, &flush_fence(surface)));
    seen.extend(read_until(&mut client, |seen| is_answer(seen, 15)));
    assert_eq!(text(capture.written()), text(typed));
    for event in ["input-failed", "stream-end", "terminal-input-unclaimed"] {
        assert!(!seen.iter().any(|seen| is_event(seen, event)), "{event}: {seen:?}");
    }
    unhook(&client);
}

#[test]
fn creating_input_stream_is_in_use_while_its_terminal_creates() {
    let mut client = Client::granted_with("creating-input-in-use", &GRANTS);
    let (pane, _) = first_pane(&mut client);
    let other = client.mux.new_workspace(None, Some((80, 24))).unwrap().id;
    let held = hold_spawns(&client);
    client.send(&stream_request(STREAM, 10, &split(pane)));
    held.wait_started();

    // A second create may not take the id of a stream that carries keys.
    client.send(&stream_request(STREAM, 11, &split(pane)));
    let seen = read_until(&mut client, |seen| is_answer(seen, 11));
    let (kind, stream, body) = answer(&seen, 11);
    assert_eq!((kind, stream), (FrameKind::Error, STREAM), "{body}");
    assert_eq!(body["error_code"], "stream_in_use", "{body}");

    // An attach takes it over only for the create's own terminal: another
    // surface is refused, and that attach's stream ends before its error.
    client.send(&stream_request(STREAM, 12, &json!({"cmd": "attach-surface", "surface": other})));
    let seen = read_until(&mut client, |seen| is_answer(seen, 12));
    let (kind, _, body) = answer(&seen, 12);
    assert_eq!(kind, FrameKind::Error, "{body}");
    assert!(body["error"].as_str().is_some_and(|error| error.contains(TERMINAL_ID)), "{body}");
    let end = seen.iter().position(|seen| is_event(seen, "stream-end"));
    let error = seen.iter().position(|seen| is_answer(seen, 12));
    assert!(end.is_some() && end < error, "{seen:?}");

    held.release.send(()).unwrap();
    read_until(&mut client, |seen| is_answer(seen, 10));
    unhook(&client);
}

#[test]
fn creating_input_past_the_creating_limit_comes_back_with_every_later_key() {
    let mut client = Client::granted_with("creating-input-overflow", &GRANTS);
    let (pane, _) = first_pane(&mut client);
    let held = hold_spawns(&client);
    client.send(&stream_request(STREAM, 10, &split(pane)));
    held.wait_started();

    // A paste of more than the creating queue holds, in 1 KiB frames, then
    // keys behind it.
    let chunk = vec![b'p'; 1024];
    let chunks = CREATING_INPUT_LIMIT / chunk.len() + 4;
    let mut typed = Vec::new();
    for _ in 0..chunks {
        client.send(&input(STREAM, 0, &chunk));
        typed.extend_from_slice(&chunk);
    }
    typed.extend(type_keys(&mut client, 0, 8));
    held.release.send(()).unwrap();
    let capture = held.capture();
    let mut seen = read_until(&mut client, |seen| is_answer(seen, 10));
    let surface = created_surface(answer(&seen, 10).2);
    client.send(&request(20, &flush_fence(surface)));
    seen.extend(read_until(&mut client, |seen| is_answer(seen, 20)));

    // The bytes the queue held were written; the first refused frame and
    // every byte after it came back, in order, and the stream ended there.
    let written = capture.written();
    assert_eq!(written.len(), CREATING_INPUT_LIMIT);
    let mut delivered = written;
    delivered.extend(given_back(&seen));
    assert_eq!(text(delivered), text(typed));
    let end = seen
        .iter()
        .position(|seen| {
            matches!(seen, Seen::Event(value)
                if value["event"] == "stream-end" && value["reason"] == "overflow")
        })
        .unwrap_or_else(|| panic!("no stream-end: {seen:?}"));
    assert!(!seen[end + 1..].iter().any(|seen| names_stream(seen, STREAM)), "{seen:?}");
    assert!(!seen.iter().any(|seen| is_event(seen, "input-failed")), "{seen:?}");
    unhook(&client);
}

#[test]
fn creating_input_a_pending_create_holds_at_most_the_creating_limit() {
    let mut client = Client::granted_with("creating-input-pending-overflow", &GRANTS);
    let (pane, surface) = first_pane(&mut client);
    // The control sequence is held, so the create waits there: its stream
    // is Pending, not yet bound to its terminal.
    client.send(&request(
        3,
        &json!({"cmd": "wait-for", "surface": surface,
                "pattern": "creating-input-never-printed", "timeout_ms": 60_000}),
    ));
    client.send(&stream_request(STREAM, 10, &split(pane)));
    let mut typed = Vec::new();
    let chunk = vec![b'q'; 1024];
    for _ in 0..CREATING_INPUT_LIMIT / chunk.len() + 1 {
        client.send(&input(STREAM, 0, &chunk));
        typed.extend_from_slice(&chunk);
    }
    // Nothing of it was written, so all of it comes back, then the end.
    let mut seen = read_until(&mut client, |seen| is_event(seen, "stream-end"));
    assert_eq!(text(given_back(&seen)), text(typed));
    let Some(Seen::Event(end)) = seen.last() else { unreachable!() };
    assert_eq!(end["reason"], "overflow", "{end}");

    // The create still runs, after the hold, and answers.
    client.send(&cancel(3, "wait-for"));
    seen.extend(read_until(&mut client, |seen| is_answer(seen, 10)));
    assert_eq!(answer(&seen, 10).0, FrameKind::Reply, "{seen:?}");
}

#[test]
fn creating_input_a_failed_create_ends_its_stream_and_nothing_of_it_follows() {
    let mut client = Client::granted_with("creating-input-failed", &GRANTS);
    let (_, surface) = first_pane(&mut client);
    // No such pane: the daemon takes the create (its stream binds), then
    // the create fails. A stream request that waits a while holds the
    // stream's sequence, so the INPUT behind it is still there when the
    // create fails, and runs after the end.
    client.send(&stream_request(STREAM, 10, &split(424_242)));
    client.send(&stream_request(
        STREAM,
        11,
        &json!({"cmd": "wait-for", "surface": surface,
                "pattern": "creating-input-never-printed", "timeout_ms": 1_000}),
    ));
    client.send(&input(STREAM, 1, b"late"));
    let mut seen = read_until(&mut client, |seen| is_answer(seen, 10));
    let (kind, stream, body) = answer(&seen, 10);
    assert_eq!((kind, stream), (FrameKind::Error, STREAM), "{body}");
    let end = seen
        .iter()
        .position(|seen| {
            matches!(seen, Seen::Event(value)
                if value["event"] == "stream-end" && value["reason"] == "attach_failed")
        })
        .unwrap_or_else(|| panic!("no stream-end: {seen:?}"));
    assert!(end < seen.len() - 1, "the end comes before the error: {seen:?}");

    // The INPUT comes back by its terminal id, and no event names the
    // stream after its end.
    seen.extend(read_until(&mut client, |seen| is_event(seen, "terminal-input-unclaimed")));
    assert_eq!(text(given_back(&seen)), "late");
    assert!(!seen[end + 1..].iter().any(|seen| names_stream(seen, STREAM)), "{seen:?}");
}

#[test]
fn creating_input_a_create_on_a_stream_names_its_terminal_id() {
    let mut client = Client::granted_with("creating-input-no-id", &GRANTS);
    let (pane, _) = first_pane(&mut client);
    let surfaces = client.mux.with_state(|state| state.surfaces.len());
    client.send(&stream_request(
        STREAM,
        10,
        &json!({"cmd": "split", "pane": pane, "dir": "right"}),
    ));
    let seen = read_until(&mut client, |seen| is_answer(seen, 10));
    let (kind, stream, body) = answer(&seen, 10);
    assert_eq!((kind, stream), (FrameKind::Error, STREAM), "{body}");
    assert_eq!(body["error_code"], "stream_needs_terminal_id", "{body}");
    let after = client.mux.with_state(|state| state.surfaces.len());
    assert_eq!(after, surfaces, "the create did not run");
}

#[test]
fn creating_input_a_create_on_a_stream_needs_the_grant() {
    let mut client = Client::granted_with("creating-input-ungranted", &["attach-streams-v1"]);
    let (pane, _) = first_pane(&mut client);
    client.send(&stream_request(STREAM, 10, &split(pane)));
    let method_id = method("split").id.raw();
    let got = client.next();
    assert!(got.is_none(), "a create on a stream without the grant was answered: {got:?}");
    assert_eq!(
        client.finish(),
        ConnectionEnd::BadMessage(ConnectionBadMessage::Call(CallRefusal::NotStreamScoped {
            stream: STREAM,
            method_id,
        }))
    );
}

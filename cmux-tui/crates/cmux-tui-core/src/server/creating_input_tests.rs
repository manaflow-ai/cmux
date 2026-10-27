//! A terminal create's stream over a real socket pair (p05-ipc-153): a
//! `split` REQUEST frame on stream S binds S to the terminal id it minted
//! when the daemon takes it, so INPUT frames sent while the terminal starts
//! join its creating queue in order, with no reply and no JSON parse.
//!
//! Each test holds the create inside its spawn (a test hook that blocks
//! until the test releases it), so the terminal is creating for certain
//! while the stream's frames arrive, not by timing. The test runtime's
//! terminals carry no host identity, so the commit finds no live terminal
//! for the minted id and gives the queue back: the one
//! `terminal-input-unclaimed` notice carries every byte in arrival order.

use std::sync::{Arc, mpsc};
use std::time::Duration;

use base64::Engine as _;
use cmux_ipc::{Aux, CallAux, CallFlags, FrameHeader, FrameKind, Message};
use cmux_threads::sync::Mutex;
use serde_json::{Value, json};

use crate::panic_free::RecoverPoison;
use crate::server::frame_dispatch::tests::{Client, method};

/// The keys typed while the terminal starts.
const KEYS: usize = 200;

/// A terminal id the create mints (32 hex digits).
const TERMINAL_ID: &str = "0000000000004000800000000000153a";

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

/// A create held in its spawn until the returned sender is dropped or sent
/// to; `started` gets one message once it is held.
struct HeldSpawn {
    release: mpsc::Sender<()>,
    started: mpsc::Receiver<()>,
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
    HeldSpawn { release, started }
}

impl HeldSpawn {
    fn wait_started(&self) {
        self.started.recv_timeout(Duration::from_secs(10)).expect("the create never spawned");
    }
}

fn first_pane(client: &mut Client) -> u64 {
    let first = client.mux.new_workspace(None, Some((80, 24))).unwrap();
    client.mux.with_state(|state| state.pane_of(first.id)).expect("a pane")
}

fn split(pane: u64) -> Value {
    json!({"cmd": "split", "pane": pane, "dir": "right", "terminal_id": TERMINAL_ID})
}

/// A stream request whose answer comes after every item queued on the
/// stream before it: `send` by the creating terminal's id, no bytes.
fn fence() -> Value {
    json!({"cmd": "send", "terminal_id": TERMINAL_ID, "text": ""})
}

fn frame_parses(client: &Client) -> (u64, u64) {
    let parses = client.mux.ipc_stats().snapshot().parses;
    (
        parses.frames.requests + parses.lines.requests,
        parses.frames.json_parses + parses.lines.json_parses,
    )
}

#[test]
fn creating_input_keys_sent_while_the_terminal_starts_queue_in_order_with_no_reply() {
    let mut client = Client::granted_with("creating-input-order", &[]);
    let pane = first_pane(&mut client);
    let held = hold_spawns(&client);
    client.send(&stream_request(9, 10, &split(pane)));
    held.wait_started();

    // One fence alone: what a stream request costs in parses.
    let before = frame_parses(&client);
    client.send(&stream_request(9, 11, &fence()));
    let seen = read_until(&mut client, |seen| is_answer(seen, 11));
    let one_fence = frame_parses(&client);
    assert_eq!(answer(&seen, 11).0, FrameKind::Reply, "{seen:?}");

    // The keys, then a fence: they add no request and no parse.
    let mut typed = Vec::new();
    for key in 0..KEYS {
        let bytes = format!("k{key:03};");
        client.send(&input(9, key as u64 + 1, bytes.as_bytes()));
        typed.extend_from_slice(bytes.as_bytes());
    }
    client.send(&stream_request(9, 12, &fence()));
    let seen = read_until(&mut client, |seen| is_answer(seen, 12));
    let after = frame_parses(&client);
    assert_eq!(
        (after.0 - one_fence.0, after.1 - one_fence.1),
        (one_fence.0 - before.0, one_fence.1 - before.1),
        "{KEYS} INPUT frames added requests or JSON parses"
    );
    // The only answer is the fence's: no key got a reply or a failure, and
    // the create is still starting.
    let answers: Vec<_> = seen.iter().filter(|seen| matches!(seen, Seen::Answer { .. })).collect();
    assert_eq!(answers.len(), 1, "{answers:?}");
    assert!(!seen.iter().any(|seen| is_event(seen, "input-failed")), "{seen:?}");
    let received = client.mux.ipc_stats().snapshot().received;
    let inputs = received.iter().find(|kind| kind.kind == FrameKind::Input.name());
    assert_eq!(inputs.map(|kind| kind.messages), Some(KEYS as u64), "{received:?}");

    // The create commits: its reply, then the queue goes to the terminal
    // (here given back, the test terminal has no host id), every key in
    // the order typed.
    held.release.send(()).unwrap();
    let seen = read_until(&mut client, |seen| is_event(seen, "terminal-input-unclaimed"));
    let (kind, stream, body) = answer(&seen, 10);
    assert_eq!((kind, stream), (FrameKind::Reply, 9), "{body}");
    let Some(Seen::Event(unclaimed)) = seen.last() else { unreachable!() };
    assert_eq!(unclaimed["terminal_id"], TERMINAL_ID, "{unclaimed}");
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(unclaimed["bytes_base64"].as_str().unwrap())
        .unwrap();
    assert_eq!(String::from_utf8(bytes).unwrap(), String::from_utf8(typed).unwrap());
    client.mux.set_terminal_spawn_start_hook_for_test(None);
}

#[test]
fn creating_input_stream_is_in_use_while_its_terminal_creates() {
    let mut client = Client::granted_with("creating-input-in-use", &[]);
    let pane = first_pane(&mut client);
    let other = client.mux.new_workspace(None, Some((80, 24))).unwrap().id;
    let held = hold_spawns(&client);
    client.send(&stream_request(9, 10, &split(pane)));
    held.wait_started();

    // A second create may not take the id of a stream that carries keys.
    client.send(&stream_request(9, 11, &split(pane)));
    let seen = read_until(&mut client, |seen| is_answer(seen, 11));
    let (kind, stream, body) = answer(&seen, 11);
    assert_eq!((kind, stream), (FrameKind::Error, 9), "{body}");
    assert_eq!(body["error_code"], "stream_in_use", "{body}");

    // An attach takes it over only for the create's own terminal: another
    // surface is refused, and that attach's stream ends before its error.
    client.send(&stream_request(9, 12, &json!({"cmd": "attach-surface", "surface": other})));
    let seen = read_until(&mut client, |seen| is_answer(seen, 12));
    let (kind, _, body) = answer(&seen, 12);
    assert_eq!(kind, FrameKind::Error, "{body}");
    assert!(body["error"].as_str().is_some_and(|error| error.contains(TERMINAL_ID)), "{body}");
    let end = seen.iter().position(|seen| is_event(seen, "stream-end"));
    let error = seen.iter().position(|seen| is_answer(seen, 12));
    assert!(end.is_some() && end < error, "{seen:?}");

    held.release.send(()).unwrap();
    read_until(&mut client, |seen| is_answer(seen, 10));
    client.mux.set_terminal_spawn_start_hook_for_test(None);
}

#[test]
fn creating_input_a_failed_create_ends_its_stream_before_its_error() {
    let mut client = Client::granted_with("creating-input-failed", &[]);
    // No such pane: the create fails, and its stream with it.
    client.send(&stream_request(9, 10, &split(424_242)));
    client.send(&input(9, 1, b"lost"));
    let seen = read_until(&mut client, |seen| is_answer(seen, 10));
    let (kind, stream, body) = answer(&seen, 10);
    assert_eq!((kind, stream), (FrameKind::Error, 9), "{body}");
    let end = seen
        .iter()
        .position(|seen| {
            matches!(seen, Seen::Event(value)
                if value["event"] == "stream-end" && value["reason"] == "attach_failed")
        })
        .unwrap_or_else(|| panic!("no stream-end: {seen:?}"));
    assert!(end < seen.len() - 1, "{seen:?}");
}

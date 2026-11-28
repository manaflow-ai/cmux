//! `attach-frames-v1` over the raw v12 command path: the bytes a client reads
//! from its socket, written by the connection's own line writer
//! (`write_line_outbound_item`), with and without the capability.

use std::collections::VecDeque;
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::tests::captured_writer;
use super::{
    BoundedOutbound, ClientTransport, Command, MessageWriter, disconnect_client, handle_command,
    write_line_outbound_item,
};
use crate::panic_free::RecoverPoison;
use crate::{Mux, Surface, SurfaceOptions};

const FRAMES: &str = "attach-frames-v1";

fn command(value: Value) -> Command {
    serde_json::from_value(value).expect("raw command")
}

/// A surface whose program prints nothing: every byte the viewer reads is
/// one the test injected.
fn quiet_surface(name: &str) -> (Arc<Mux>, Arc<Surface>) {
    let options = SurfaceOptions {
        command: Some(vec!["/bin/sh".into(), "-c".into(), "exec sleep 600".into()]),
        ..SurfaceOptions::default()
    };
    let mux = Mux::new_for_test(name, options);
    let surface = mux.new_workspace(None, None).unwrap();
    (mux, surface)
}

/// One message as a client cuts it from the socket.
#[derive(Debug)]
enum Message {
    Json(Value),
    Frame { kind: u8, stream: u16, offset: u64, payload: Vec<u8> },
}

/// The client end of a captured connection: the socket bytes the writer
/// thread would write, cut into JSON lines and `0xFF` frames.
struct Wire {
    outbound: Arc<BoundedOutbound>,
    bytes: Vec<u8>,
    messages: VecDeque<Message>,
}

impl Wire {
    fn new(outbound: Arc<BoundedOutbound>) -> Self {
        Self { outbound, bytes: Vec::new(), messages: VecDeque::new() }
    }

    /// Writes every queued item the way the connection's writer does.
    fn drain(&mut self) {
        loop {
            let item = {
                let mut state = self.outbound.state.lock().recover_poison();
                BoundedOutbound::pop_locked(&mut state)
            };
            // A backpressured sender waits for room in its stream.
            self.outbound.changed.notify_all();
            let Some(item) = item else { break };
            write_line_outbound_item(&mut self.bytes, item).expect("write to the wire");
        }
        self.cut();
    }

    fn cut(&mut self) {
        loop {
            match self.bytes.first() {
                None => return,
                Some(0xFF) => {
                    let Some(header) = self.bytes.get(..16) else { return };
                    let kind = header[1];
                    let stream = u16::from_le_bytes([header[2], header[3]]);
                    let len = u32::from_le_bytes(header[4..8].try_into().unwrap()) as usize;
                    let offset = u64::from_le_bytes(header[8..16].try_into().unwrap());
                    if self.bytes.len() < 16 + len {
                        return;
                    }
                    let payload = self.bytes[16..16 + len].to_vec();
                    self.bytes.drain(..16 + len);
                    self.messages.push_back(Message::Frame { kind, stream, offset, payload });
                }
                Some(_) => {
                    let Some(end) = self.bytes.iter().position(|byte| *byte == b'\n') else {
                        return;
                    };
                    let line: Vec<u8> = self.bytes.drain(..=end).collect();
                    let value: Value = serde_json::from_slice(&line[..end])
                        .unwrap_or_else(|error| panic!("a JSON line: {error}: {line:?}"));
                    self.messages.push_back(Message::Json(value));
                }
            }
        }
    }

    /// The next message other than a notification, within `timeout`.
    fn next(&mut self, timeout: Duration) -> Option<Message> {
        let deadline = Instant::now() + timeout;
        loop {
            self.drain();
            while let Some(message) = self.messages.pop_front() {
                if matches!(&message, Message::Json(value) if value["event"] == "notification") {
                    continue;
                }
                return Some(message);
            }
            if Instant::now() >= deadline {
                return None;
            }
            std::thread::sleep(Duration::from_millis(2));
        }
    }
}

struct Viewer {
    client: u64,
    writer: MessageWriter,
    wire: Wire,
}

fn connect(mux: &Arc<Mux>, transport: ClientTransport, capabilities: &[&str]) -> Viewer {
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(transport, writer.clone());
    if !capabilities.is_empty() {
        // The registry's filter `set-client-info` applies; the request's other gates (a
        // WebSocket's hello, the remote entry's admission) are not what this tests.
        let capabilities = capabilities.iter().map(|capability| capability.to_string()).collect();
        mux.control_clients
            .set_info(client, Some("frames test".into()), None, Some(capabilities))
            .unwrap();
    }
    Viewer { client, writer, wire: Wire::new(outbound) }
}

/// Reads until `want` payload bytes arrived in OUTPUT frames, skipping JSON
/// events a quiet terminal may still send (`colors-changed`, history chunks).
/// Panics on an `output` JSON line: a frames client never gets one.
fn read_frames(wire: &mut Wire, want: usize) -> Vec<(u16, u64, Vec<u8>)> {
    let mut frames = Vec::new();
    let mut got = 0;
    while got < want {
        match wire.next(Duration::from_secs(5)).expect("an OUTPUT frame") {
            Message::Frame { kind, stream, offset, payload } => {
                assert_eq!(kind, 1, "OUTPUT");
                got += payload.len();
                frames.push((stream, offset, payload));
            }
            Message::Json(value) => {
                assert_ne!(value["event"], "output", "a frames client got JSON output: {value}");
                assert!(
                    value["event"] == "colors-changed"
                        || value["event"] == "scroll-changed"
                        || (value["event"] == "snapshot" && value["phase"] == "history"),
                    "unexpected event before the output: {value}"
                );
            }
        }
    }
    frames
}

/// Concatenated payloads, checking each frame starts where the last ended.
fn contiguous(frames: &[(u16, u64, Vec<u8>)], start: u64) -> Vec<u8> {
    let mut offset = start;
    let mut bytes = Vec::new();
    for (stream, frame_offset, payload) in frames {
        assert_eq!(*stream, 0, "the connection's only attach");
        assert_eq!(*frame_offset, offset, "offset of the first payload byte, contiguous");
        offset += payload.len() as u64;
        bytes.extend_from_slice(payload);
    }
    bytes
}

#[test]
fn a_frames_snapshot_viewer_gets_output_frames_in_stream_order() {
    let (mux, surface) = quiet_surface("attach-frames-snapshot");
    let mut viewer = connect(&mux, ClientTransport::Unix, &[FRAMES]);
    handle_command(
        &mux,
        viewer.client,
        command(json!({
            "cmd": "attach-surface", "surface": surface.id,
            "snapshot": "ghostsnp", "snapshot_version": ghostty_vt::snapshot_version(),
        })),
        &viewer.writer,
    )
    .unwrap();
    // The READY stays a JSON line; its offset is where the frames start.
    let ready = match viewer.wire.next(Duration::from_secs(5)).expect("READY") {
        Message::Json(value) => value,
        frame => panic!("READY first, got {frame:?}"),
    };
    assert_eq!(ready["event"], "snapshot", "{ready}");
    let start = ready["offset"].as_u64().expect("READY offset");

    let first = b"first frame bytes\r\n";
    surface.inject_output_for_test(first);
    let frames = read_frames(&mut viewer.wire, first.len());
    assert_eq!(contiguous(&frames, start), first);
    let after_first = start + first.len() as u64;

    // A JSON event between two outputs keeps its place in the stream.
    let reply = handle_command(
        &mux,
        viewer.client,
        command(json!({
            "cmd": "snapshot-request", "surface": surface.id,
            "reason": "digest_mismatch", "request_id": "between",
        })),
        &viewer.writer,
    )
    .unwrap();
    // Accepted now, or throttled after the first READY and fired at the interval's end:
    // either way the READY follows on the stream.
    assert!(reply["status"] == "accepted" || reply["status"] == "snapshot_throttled", "{reply}");
    let snapshot = loop {
        match viewer.wire.next(Duration::from_secs(5)).expect("the requested snapshot") {
            Message::Json(value) if value["event"] == "snapshot" && value["phase"] == "ready" => {
                break value;
            }
            Message::Json(value) => {
                assert_ne!(value["event"], "output", "{value}");
            }
            frame => panic!("no output was written, got {frame:?}"),
        }
    };
    assert_eq!(snapshot["offset"].as_u64(), Some(after_first), "{snapshot}");

    let second = b"second \x1b[1mframe\x1b[0m\r\n";
    surface.inject_output_for_test(second);
    let frames = read_frames(&mut viewer.wire, second.len());
    assert_eq!(contiguous(&frames, after_first), second);

    disconnect_client(&mux, viewer.client, false);
    mux.shutdown();
}

#[test]
fn a_frames_byte_viewer_gets_output_frames_at_the_stream_offset() {
    let (mux, surface) = quiet_surface("attach-frames-bytes");
    let mut viewer = connect(&mux, ClientTransport::Unix, &[FRAMES]);
    handle_command(
        &mux,
        viewer.client,
        command(json!({"cmd": "attach-surface", "surface": surface.id})),
        &viewer.writer,
    )
    .unwrap();
    match viewer.wire.next(Duration::from_secs(5)).expect("vt-state") {
        Message::Json(value) => assert_eq!(value["event"], "vt-state", "{value}"),
        frame => panic!("vt-state first, got {frame:?}"),
    }
    let (_, start) = surface.snapshot_stream_position().expect("a PTY");
    let chunks: [&[u8]; 3] = [b"one\r\n", b"two \xe2\x94\x80 and a split \xe2", b"\x94\x80\r\n"];
    for chunk in chunks {
        surface.inject_output_for_test(chunk);
    }
    let want: Vec<u8> = chunks.concat();
    let frames = read_frames(&mut viewer.wire, want.len());
    assert_eq!(contiguous(&frames, start), want, "raw bytes, a split UTF-8 sequence intact");

    disconnect_client(&mux, viewer.client, false);
    mux.shutdown();
}

#[test]
fn a_client_without_the_capability_reads_only_json_lines() {
    let (mux, surface) = quiet_surface("attach-frames-none");
    for snapshot in [true, false] {
        let mut viewer = connect(&mux, ClientTransport::Unix, &[]);
        let mut request = json!({"cmd": "attach-surface", "surface": surface.id});
        if snapshot {
            request["snapshot"] = json!("ghostsnp");
            request["snapshot_version"] = json!(ghostty_vt::snapshot_version());
        }
        handle_command(&mux, viewer.client, command(request), &viewer.writer).unwrap();
        surface.inject_output_for_test(b"json only\r\n");
        let output = loop {
            match viewer.wire.next(Duration::from_secs(5)).expect("an output event") {
                Message::Json(value) if value["event"] == "output" => break value,
                Message::Json(_) => {}
                frame => panic!("a frame without the capability: {frame:?}"),
            }
        };
        assert!(output["data"].is_string(), "{output}");
        disconnect_client(&mux, viewer.client, false);
    }
    mux.shutdown();
}

#[test]
fn only_a_local_unix_connection_negotiates_frames() {
    let (mux, _surface) = quiet_surface("attach-frames-transports");
    for (transport, granted) in [
        (ClientTransport::Unix, true),
        (ClientTransport::WebSocket, false),
        (ClientTransport::Remote, false),
    ] {
        let viewer = connect(&mux, transport, &[FRAMES]);
        assert_eq!(
            mux.control_clients.supports_capability(viewer.client, FRAMES),
            granted,
            "{}",
            transport.as_str()
        );
        disconnect_client(&mux, viewer.client, false);
    }
    mux.shutdown();
}

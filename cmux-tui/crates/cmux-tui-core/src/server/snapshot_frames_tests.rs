//! SNAPSHOT/SNAPSHOT_MORE/REPLAY frames: on five fixture
//! terminals, every snapshot event (READY, history and images chunks, a
//! local-history READY) and the `vt-state` replay, sent as frames through the
//! connection's chunking writer and read back by the frame reader, equal the
//! JSON line of the same event.

use base64::Engine as _;
use cmux_ipc::{Frame, FrameKind, FrameReader, LaneWriter, LaneWriterConfig, Message, StreamLane};

use super::*;
use crate::SurfaceOptions;
use crate::server::render_messages::snapshot_frames::{BULK_META_LEN_BYTES, bulk_frame};
use crate::server::{RenderService, VtStateMessage};

const STREAM: u16 = 7;

/// One bulk event read back from frames.
#[derive(Debug)]
struct Assembled {
    kind: FrameKind,
    offset: u64,
    meta: Value,
    raw: Vec<u8>,
}

impl Assembled {
    /// The JSON line this event stands for: the meta without the lengths,
    /// with `data` (and `pending`) in base64.
    fn as_json(&self) -> Value {
        let mut value = self.meta.clone();
        let object = value.as_object_mut().expect("meta is an object");
        assert!(!object.contains_key("data"), "the meta carries no base64 data");
        assert!(!object.contains_key("pending"), "the meta carries no base64 pending");
        let data_len = object.remove("data_len").and_then(|len| len.as_u64()).unwrap() as usize;
        let pending_len = object.remove("pending_len").map_or(0, |len| len.as_u64().unwrap());
        assert_eq!(self.raw.len(), data_len + pending_len as usize, "raw is data then pending");
        let (data, pending) = self.raw.split_at(data_len);
        object.insert("data".into(), json!(base64_of(data)));
        if !pending.is_empty() {
            object.insert("pending".into(), json!(base64_of(pending)));
        }
        value
    }
}

fn base64_of(bytes: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

/// Bytes of the whole event once its meta is in: prefix, meta and raw.
fn event_len(payload: &[u8]) -> Option<usize> {
    let prefix: [u8; BULK_META_LEN_BYTES] = payload.get(..BULK_META_LEN_BYTES)?.try_into().ok()?;
    let meta_end = BULK_META_LEN_BYTES + u32::from_le_bytes(prefix) as usize;
    let meta: Value = serde_json::from_slice(payload.get(BULK_META_LEN_BYTES..meta_end)?).unwrap();
    let raw = meta["data_len"].as_u64().unwrap() + meta["pending_len"].as_u64().unwrap_or(0);
    Some(meta_end + raw as usize)
}

/// Reassembles the events of `frames` the way a reader does: a SNAPSHOT
/// continues with SNAPSHOT_MORE and a REPLAY with REPLAY chunks, each at the
/// same aux, until the meta's length.
fn assemble(frames: &[Frame]) -> Vec<Assembled> {
    let mut events = Vec::new();
    let mut open: Option<(FrameKind, u64, Vec<u8>)> = None;
    for frame in frames {
        let header = frame.header();
        assert_eq!(header.stream(), STREAM);
        let cmux_ipc::Aux::Offset(aux) = header.aux() else { panic!("bulk aux is an offset") };
        let (kind, offset, mut payload) = match open.take() {
            None => {
                assert!(matches!(header.kind(), FrameKind::Snapshot | FrameKind::Replay));
                (header.kind(), aux, Vec::new())
            }
            Some((FrameKind::Snapshot, offset, payload)) => {
                assert_eq!((header.kind(), aux), (FrameKind::SnapshotMore, offset));
                (FrameKind::Snapshot, offset, payload)
            }
            Some((kind, offset, payload)) => {
                assert_eq!((header.kind(), aux), (kind, offset), "a chunk keeps the cut offset");
                (kind, offset, payload)
            }
        };
        payload.extend_from_slice(frame.payload());
        match event_len(&payload) {
            Some(len) if len == payload.len() => {
                let meta_end = len - event_raw_len(&payload);
                let meta = serde_json::from_slice(&payload[BULK_META_LEN_BYTES..meta_end]).unwrap();
                let raw = payload.split_off(meta_end);
                events.push(Assembled { kind, offset, meta, raw });
            }
            Some(len) => {
                assert!(payload.len() < len, "a frame ran past its event");
                open = Some((kind, offset, payload));
            }
            None => open = Some((kind, offset, payload)),
        }
    }
    assert!(open.is_none(), "an event was left unfinished");
    events
}

/// The meta JSON of one whole bulk payload.
fn meta_of(payload: &[u8]) -> Value {
    let meta_len = u32::from_le_bytes(payload[..BULK_META_LEN_BYTES].try_into().unwrap()) as usize;
    serde_json::from_slice(&payload[BULK_META_LEN_BYTES..BULK_META_LEN_BYTES + meta_len]).unwrap()
}

fn event_raw_len(payload: &[u8]) -> usize {
    let meta_end = BULK_META_LEN_BYTES
        + u32::from_le_bytes(payload[..BULK_META_LEN_BYTES].try_into().unwrap()) as usize;
    payload.len() - meta_end
}

/// `frames` through a bulk stream of the chunking writer, onto the wire and
/// back through the frame reader.
fn over_the_wire(frames: Vec<Frame>, chunk_bytes: usize) -> Vec<Frame> {
    let mut writer = LaneWriter::new(LaneWriterConfig { chunk_bytes, ..Default::default() });
    writer.open_stream(STREAM, StreamLane::Bulk).unwrap();
    let mut wire = Vec::new();
    for frame in frames {
        writer.push_stream(frame).unwrap();
        while let Some(chunk) = writer.pop() {
            assert!(chunk.payload().len() <= chunk_bytes, "the writer cuts at its chunk size");
            wire.extend_from_slice(&chunk.header().encode());
            wire.extend_from_slice(chunk.payload());
        }
    }
    let mut reader = FrameReader::new(Default::default());
    reader.negotiate_frames();
    reader.push(&wire);
    reader.mark_eof();
    let mut read = Vec::new();
    while let Some(message) = reader.next_message().unwrap() {
        match message {
            Message::Frame(frame) => read.push(frame),
            Message::Json(line) => panic!("a JSON line on a framed stream: {line}"),
        }
    }
    read
}

/// The `snapshot` events of one READY: the READY, then its history and
/// images chunks, as the worker sends them (JSON form).
fn ready_and_tail_json(surface: SurfaceId, frame: &TerminalSnapshotFrame) -> Vec<Value> {
    let mut frame = frame.clone();
    let mut events = vec![ready_event(surface, &frame).into_json()];
    let mut tail = PendingTail::of(&mut frame);
    while let Some((event, done)) = tail.next_chunk(surface).unwrap() {
        events.push(event.into_json());
        if done {
            break;
        }
    }
    events
}

/// The same events as SNAPSHOT frames.
fn ready_and_tail_frames(surface: SurfaceId, frame: &TerminalSnapshotFrame) -> Vec<Frame> {
    let mut frame = frame.clone();
    let mut frames = vec![ready_event(surface, &frame).into_frame(STREAM).unwrap()];
    let mut tail = PendingTail::of(&mut frame);
    while let Some((event, done)) = tail.next_chunk(surface).unwrap() {
        frames.push(event.into_frame(STREAM).unwrap());
        if done {
            break;
        }
    }
    frames
}

struct Fixture {
    name: &'static str,
    output: Vec<u8>,
}

fn fixtures() -> Vec<Fixture> {
    let mut styled = Vec::new();
    for row in 0..20 {
        styled.extend_from_slice(
            format!("\x1b[1;3{}m row {row} \x1b[0;48;5;{}m bg \x1b[0m\r\n", row % 8, row * 7)
                .as_bytes(),
        );
    }
    styled.extend_from_slice(b"\x1b]0;styled title\x07\x1b[5;10H\x1b[?25l");
    let mut scrollback = Vec::new();
    for line in 0..20_000 {
        scrollback.extend_from_slice(format!("{line:06} {}\r\n", "s".repeat(110)).as_bytes());
    }
    let unicode =
        "\u{4f60}\u{597d} \u{1f600} e\u{301} \u{fe0f}\r\n\x1b[?1049halt screen \u{2603}\x1b[3"
            .as_bytes()
            .to_vec();
    let pixels = format!("{}AA==", "A".repeat(84));
    let mut images = Vec::new();
    for id in [1, 2] {
        images.extend_from_slice(
            format!("\x1b_Ga=T,t=d,f=32,i={id},p=1,s=4,v=4,c=2,r=1,q=2;{pixels}\x1b\\\r\n")
                .as_bytes(),
        );
    }
    vec![
        Fixture { name: "empty", output: Vec::new() },
        Fixture { name: "styled", output: styled },
        Fixture { name: "scrollback", output: scrollback },
        Fixture { name: "unicode-alt-screen-pending", output: unicode },
        Fixture { name: "kitty-images", output: images },
    ]
}

fn quiet_surface(name: &str) -> (Arc<Mux>, Arc<Surface>) {
    let options = SurfaceOptions {
        command: Some(vec!["/bin/sh".into(), "-c".into(), "exec sleep 60".into()]),
        // Room for the scrollback fixture to need several history chunks.
        scrollback: 64 << 20,
        ..SurfaceOptions::default()
    };
    let mux = Mux::new_for_test(name, options.clone());
    let surface = Surface::spawn_for_test(1, options, Arc::downgrade(&mux)).unwrap();
    (mux, surface)
}

/// Round trip on five fixture terminals, at a chunk smaller than a meta
/// (so the meta spans frames) and at the daemon's BULK_FRAME_MAX.
#[test]
fn snapshot_frames_round_trip_equals_the_json_path_on_five_fixtures() {
    for fixture in fixtures() {
        let (_mux, surface) = quiet_surface(fixture.name);
        surface.inject_output_for_test(&fixture.output);
        let stream =
            surface.attach_snapshot_stream(AttachLifecycle::default(), 1 << 20, false).unwrap();
        let ready = surface.take_viewer_snapshot(&stream.receiver, Some(u64::MAX)).unwrap();
        let name = fixture.name;
        let json = ready_and_tail_json(surface.id, &ready);
        if name == "scrollback" {
            assert!(
                json.len() > 2,
                "{name}: history comes in several chunks ({} B)",
                ready.history.len()
            );
        }
        if name == "kitty-images" {
            assert!(json.iter().any(|event| event["phase"] == "images"), "{name}: images phase");
        }
        let local = LocalReadySnapshot {
            frame: TerminalSnapshotFrame { history: Vec::new(), images: None, ..ready.clone() },
            history_rows: 12,
            history_digest: vec![0xab; 32],
        };
        let mut expected = json;
        expected.push(local_ready_event(surface.id, &local).into_json());
        let mut frames = ready_and_tail_frames(surface.id, &ready);
        frames.push(local_ready_event(surface.id, &local).into_frame(STREAM).unwrap());

        for chunk_bytes in [64, cmux_ipc::lane_writer::BULK_FRAME_MAX] {
            let events = assemble(&over_the_wire(frames.clone(), chunk_bytes));
            assert_eq!(events.len(), expected.len(), "{name} at {chunk_bytes}: one per event");
            for (event, json) in events.iter().zip(&expected) {
                assert_eq!(event.kind, FrameKind::Snapshot, "{name}");
                assert_eq!(event.offset, ready.offset, "{name}: aux is the READY's offset");
                assert_eq!(&event.as_json(), json, "{name} at {chunk_bytes}");
            }
        }
        drop(stream);
        surface.kill();
    }
}

/// The `vt-state` replay of each fixture as one REPLAY frame equals its JSON
/// line, pending sequence included, with every chunk's aux at the cut offset.
#[test]
fn snapshot_frames_vt_state_replay_round_trips_on_five_fixtures() {
    let render = RenderService::new();
    for fixture in fixtures() {
        let (_mux, surface) = quiet_surface(fixture.name);
        surface.inject_output_for_test(&fixture.output);
        let attach = surface.attach_stream_with_lifecycle(AttachLifecycle::default()).unwrap();
        let (_, offset) = surface.snapshot_stream_position().unwrap();
        let message = VtStateMessage {
            surface: surface.id,
            cols: attach.cols,
            rows: attach.rows,
            replay: attach.replay.clone(),
            kitty_image_aliases: attach.kitty_image_aliases.clone(),
            kitty_state: attach.kitty_state,
            colors: terminal_colors_json(attach.colors, true),
            pending_sequence: attach.pending_sequence.clone(),
        };
        let name = fixture.name;
        if name == "unicode-alt-screen-pending" {
            assert!(!message.pending_sequence.is_empty(), "{name}: the replay has a pending tail");
        }
        let line = render.serialize_vt_state(&message).unwrap();
        let json: Value = serde_json::from_str(&line).unwrap();
        let frame = message.replay_frame(STREAM, offset).unwrap();
        let meta = meta_of(frame.payload());
        assert!(meta.get("data").is_none(), "{name}: no base64 data in the meta");
        assert!(meta.get("pending").is_none(), "{name}: no base64 pending in the meta");
        assert_eq!(meta["data_len"], json!(message.replay.len()), "{name}: data is raw");
        let raw = [&message.replay[..], &message.pending_sequence[..]].concat();
        assert!(frame.payload().ends_with(&raw), "{name}: replay then pending, raw");
        for chunk_bytes in [64, cmux_ipc::lane_writer::BULK_FRAME_MAX] {
            let events = assemble(&over_the_wire(vec![frame.clone()], chunk_bytes));
            assert_eq!(events.len(), 1, "{name}");
            assert_eq!((events[0].kind, events[0].offset), (FrameKind::Replay, offset), "{name}");
            assert_eq!(events[0].as_json(), json, "{name} at {chunk_bytes}");
        }
        surface.kill();
    }
}

/// The raw bytes of a SNAPSHOT frame are `data` itself: a history chunk
/// carries its DEFLATE bytes, not their base64.
#[test]
fn snapshot_frames_carry_data_raw_after_the_meta() {
    let data: Vec<u8> = (0..=255).collect();
    let meta = json!({"event": "snapshot", "phase": "history", "offset": 9});
    let frame = SnapshotEvent::new(9, meta, data.as_slice()).into_frame(STREAM).unwrap();
    let payload = frame.payload();
    let meta = meta_of(payload);
    assert_eq!(meta["data_len"], 256);
    assert!(meta.get("data").is_none());
    assert_eq!(&payload[payload.len() - data.len()..], data.as_slice());
    assert_eq!(frame.header().aux(), cmux_ipc::Aux::Offset(9));
}

/// A payload over the frame cap and a frame on stream 0 have no frame form;
/// the caller keeps the JSON line.
#[test]
fn snapshot_frames_refuse_oversize_and_the_control_stream() {
    let big = vec![0u8; cmux_ipc::MAX_FRAME_PAYLOAD as usize];
    assert!(matches!(
        bulk_frame(FrameKind::Snapshot, STREAM, 0, b"{}", &[&big]),
        Err(crate::server::render_messages::snapshot_frames::BulkFrameError::Oversize { .. })
    ));
    assert!(matches!(
        bulk_frame(FrameKind::Replay, 0, 0, b"{}", &[b"x"]),
        Err(crate::server::render_messages::snapshot_frames::BulkFrameError::Frame(_))
    ));
}

//! Attach frames (p05-ipc-076): OUTPUT offsets stay contiguous over 10k
//! chunks of a real terminal's attach tap, and decoding the OUTPUT, GRID and
//! EVENT frames gives back the JSON attach events of the line path.

use std::sync::Arc;

use base64::Engine;
use cmux_ipc::{Aux, FrameKind, FrameReader, Message, ReaderLimits};
use ghostty_vt::{KittyReplayState, Rgb};
use serde_json::{Value, json};

use super::{AttachFrameEncoder, AttachFrameError, BudgetedFrame, EncodedAttachFrame};
use crate::server::render_service::OutboundByteBudget;
use crate::server::{AttachWireShape, RenderService};
use crate::{AttachFrame, Mux, Surface, SurfaceOptions, TerminalColors};

const STREAM: u16 = 3;
const SURFACE: u64 = 7;

fn base64(bytes: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

fn shapes() -> [AttachWireShape; 4] {
    [(false, false), (true, false), (false, true), (true, true)].map(
        |(color_overrides, pending_sequence)| AttachWireShape { color_overrides, pending_sequence },
    )
}

fn colors() -> Box<TerminalColors> {
    let mut colors = TerminalColors {
        fg: Some(Rgb { r: 1, g: 2, b: 3 }),
        bg_override: Some(Rgb { r: 9, g: 8, b: 7 }),
        ..TerminalColors::default()
    };
    colors.palette[4] = Some(Rgb { r: 40, g: 50, b: 60 });
    Box::new(colors)
}

fn resized(colors: Option<Box<TerminalColors>>, pending: &[u8]) -> AttachFrame {
    let (cols, rows) = (100, 30);
    let replay: Arc<[u8]> = Arc::from(&b"\x1b[2Jscreen \xce\xbb"[..]);
    let kitty_image_aliases = vec![ghostty_vt::KittyImageAlias { image_id: 5, image_number: 9 }];
    let kitty_state = KittyReplayState::disabled();
    let pending_sequence: Arc<[u8]> = Arc::from(pending);
    match colors {
        None => AttachFrame::Resized {
            cols,
            rows,
            replay,
            kitty_image_aliases,
            kitty_state,
            pending_sequence,
        },
        Some(colors) => AttachFrame::ResizedWithColors {
            cols,
            rows,
            replay,
            kitty_image_aliases,
            kitty_state,
            colors,
            pending_sequence,
        },
    }
}

/// Every attach frame the tap delivers, with the binary payload edge cases.
fn fixtures() -> Vec<AttachFrame> {
    vec![
        AttachFrame::Output(b"plain \xff\x00 bytes\r\n".to_vec()),
        AttachFrame::Output(Vec::new()),
        AttachFrame::FlowOutput { output: b"echo".to_vec(), flow: 42 },
        AttachFrame::OutputWithColors {
            output: b"\x1b]10;#010203\x07".to_vec(),
            colors: colors(),
            flow: 0,
        },
        AttachFrame::OutputWithColors { output: b"x".to_vec(), colors: colors(), flow: 77 },
        resized(None, b""),
        resized(None, b"\x1b[1;3"),
        resized(Some(colors()), b""),
        resized(Some(colors()), b"\xce"),
        AttachFrame::ColorsChanged(Arc::new(*colors())),
    ]
}

/// The JSON event the frames of one attach frame decode to, as the text a
/// client would read on the line path: an OUTPUT payload goes back into its
/// sidecar as `data`, a GRID's replay and pending bytes back into its meta.
fn decode(encoded: &EncodedAttachFrame) -> String {
    let frame = &encoded.frame;
    match frame.header().kind() {
        FrameKind::Output => {
            let prefix = format!("{{\"event\":\"output\",\"surface\":{SURFACE}");
            let data = format!(",\"data\":\"{}\"", base64(frame.payload()));
            match &encoded.sidecar {
                None => format!("{prefix}{data}}}"),
                Some(sidecar) => {
                    assert_eq!(sidecar.header().kind(), FrameKind::Event);
                    assert_eq!(sidecar.offset(), frame.offset(), "the sidecar names its bytes");
                    let text = std::str::from_utf8(sidecar.payload()).unwrap();
                    let rest = text.strip_prefix(&prefix).expect("sidecar is an output event");
                    format!("{prefix}{data}{rest}")
                }
            }
        }
        FrameKind::Grid => {
            assert!(encoded.sidecar.is_none());
            let payload = frame.payload();
            let meta_len = u32::from_le_bytes(payload[..4].try_into().unwrap()) as usize;
            let mut meta: serde_json::Map<String, Value> =
                serde_json::from_slice(&payload[4..4 + meta_len]).unwrap();
            let raw = &payload[4 + meta_len..];
            let pending_len =
                meta.remove("pending_len").map_or(0, |len| len.as_u64().unwrap() as usize);
            let (replay, pending) = raw.split_at(raw.len() - pending_len);
            meta.insert("replay".into(), json!(base64(replay)));
            if !pending.is_empty() {
                meta.insert("pending".into(), json!(base64(pending)));
            }
            Value::Object(meta).to_string()
        }
        FrameKind::Event => {
            assert!(encoded.sidecar.is_none());
            String::from_utf8(frame.payload().to_vec()).unwrap()
        }
        other => panic!("unexpected attach frame kind {other:?}"),
    }
}

/// The frames' wire bytes read back through the cmux-ipc reader.
fn read_back(frames: &[&BudgetedFrame]) -> Vec<(FrameKind, u16, Aux, Vec<u8>)> {
    let mut reader = FrameReader::new(ReaderLimits::default());
    reader.negotiate_frames();
    for frame in frames {
        reader.push(&frame.header().encode());
        reader.push(frame.payload());
    }
    let mut read = Vec::new();
    while let Some(message) = reader.next_message().unwrap() {
        let Message::Frame(frame) = message else { panic!("a JSON line among attach frames") };
        let header = *frame.header();
        read.push((header.kind(), header.stream(), header.aux(), frame.payload().to_vec()));
    }
    read
}

#[test]
fn decoded_frames_equal_the_json_attach_events() {
    let service = RenderService::new();
    for shape in shapes() {
        for fixture in fixtures() {
            let line = service.serialize_attach_frame(SURFACE, &fixture, shape).unwrap();
            let mut encoder = AttachFrameEncoder::new(STREAM, SURFACE, shape, 1_000).unwrap();
            let encoded = service.encode_attach_frame(&mut encoder, fixture.clone()).unwrap();
            let decoded = decode(&encoded);
            if encoded.frame.header().kind() == FrameKind::Grid {
                let expected: Value = serde_json::from_str(&line).unwrap();
                let decoded: Value = serde_json::from_str(&decoded).unwrap();
                assert_eq!(decoded, expected, "{fixture:?} with {shape:?}");
            } else {
                assert_eq!(decoded.as_str(), &**line, "{fixture:?} with {shape:?}");
            }
            let frames = encoded.frames().collect::<Vec<_>>();
            for (frame, (kind, stream, aux, payload)) in frames.iter().zip(read_back(&frames)) {
                assert_eq!(kind, frame.header().kind());
                assert_eq!((stream, aux), (STREAM, Aux::Offset(1_000)));
                assert_eq!(payload, frame.payload().to_vec());
            }
        }
    }
}

#[test]
fn output_frames_share_the_tap_buffer() {
    let service = RenderService::new();
    let output = b"no copy".to_vec();
    let address = output.as_ptr();
    let mut encoder =
        AttachFrameEncoder::new(STREAM, SURFACE, AttachWireShape::default(), 0).unwrap();
    let encoded = service.encode_attach_frame(&mut encoder, AttachFrame::Output(output)).unwrap();
    assert_eq!(encoded.frame.payload().as_ptr(), address, "OUTPUT copied the PTY bytes");
}

#[test]
fn grid_and_events_carry_the_offset_they_follow() {
    let service = RenderService::new();
    let mut encoder =
        AttachFrameEncoder::new(STREAM, SURFACE, AttachWireShape::default(), 10).unwrap();
    service.encode_attach_frame(&mut encoder, AttachFrame::Output(b"abcde".to_vec())).unwrap();
    let grid = service.encode_attach_frame(&mut encoder, resized(None, b"")).unwrap();
    assert_eq!((grid.frame.header().kind(), grid.frame.offset()), (FrameKind::Grid, Some(15)));
    let event = service
        .encode_attach_event(&encoder, &json!({"event": "detached", "surface": SURFACE}))
        .unwrap();
    assert_eq!((event.header().kind(), event.offset()), (FrameKind::Event, Some(15)));
    assert_eq!(&event.payload()[..], br#"{"event":"detached","surface":7}"#);
    assert_eq!(encoder.offset(), 15, "only output advances the offset");
}

#[test]
fn the_control_stream_takes_no_attach_frames() {
    assert!(matches!(
        AttachFrameEncoder::new(0, SURFACE, AttachWireShape::default(), 0),
        Err(AttachFrameError::ControlStream)
    ));
}

#[test]
fn frames_hold_their_budget_and_a_refused_frame_leaves_no_gap() {
    let budget = Arc::new(OutboundByteBudget::new(64));
    let mut encoder =
        AttachFrameEncoder::new(STREAM, SURFACE, AttachWireShape::default(), 0).unwrap();
    let held = encoder.encode(AttachFrame::Output(vec![b'a'; 40]), &budget).unwrap();
    assert_eq!(budget.retained_bytes.load(std::sync::atomic::Ordering::Acquire), 40);
    let refused = encoder.encode(AttachFrame::Output(vec![b'b'; 40]), &budget);
    assert!(matches!(&refused, Err(AttachFrameError::Write(error))
        if error.kind() == std::io::ErrorKind::WouldBlock));
    assert_eq!(encoder.offset(), 40, "a refused output must not move the offset");
    drop(held);
    assert_eq!(budget.retained_bytes.load(std::sync::atomic::Ordering::Acquire), 0);
    let next = encoder.encode(AttachFrame::Output(vec![b'c'; 40]), &budget).unwrap();
    assert_eq!(next.frame.offset(), Some(40));
    let grid = encoder.encode(resized(Some(colors()), b"\xce"), &budget);
    assert!(grid.is_err(), "a GRID over the budget is refused");
    drop(next);
    assert_eq!(budget.retained_bytes.load(std::sync::atomic::Ordering::Acquire), 0);
}

/// 10k PTY output chunks of a real terminal through its attach tap: every
/// OUTPUT starts where the one before it ended, the first at the attach's
/// offset, and the payloads are the bytes the JSON `output` events carry.
#[test]
fn offsets_stay_contiguous_over_ten_thousand_chunks() {
    let mux = Mux::new_for_test("attach-frames-offsets", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    surface.apply_local_pty_output_for_test(b"before the attach\r\n").unwrap();
    let attach = surface.attach_stream().unwrap();
    assert_eq!(attach.offset, b"before the attach\r\n".len() as u64);

    let service = RenderService::new();
    let shape = AttachWireShape::default();
    let mut encoder = AttachFrameEncoder::new(STREAM, SURFACE, shape, attach.offset).unwrap();
    let mut expected_offset = attach.offset;
    let mut sent = Vec::new();
    let mut framed = Vec::new();
    let mut from_json = Vec::new();
    for chunk in 0..10_000_usize {
        let bytes = format!("chunk {chunk} {}\r\n", "x".repeat(chunk % 97)).into_bytes();
        sent.extend_from_slice(&bytes);
        surface.apply_local_pty_output_for_test(&bytes).unwrap();
        while let Ok(frame) = attach.stream.try_recv() {
            let line = service.serialize_attach_frame(SURFACE, &frame, shape).unwrap();
            let line: Value = serde_json::from_str(&line).unwrap();
            from_json.extend(
                base64::engine::general_purpose::STANDARD
                    .decode(line["data"].as_str().unwrap())
                    .unwrap(),
            );
            let encoded = service.encode_attach_frame(&mut encoder, frame).unwrap();
            assert_eq!(encoded.frame.header().kind(), FrameKind::Output);
            assert_eq!(encoded.frame.offset(), Some(expected_offset), "gap at chunk {chunk}");
            expected_offset += encoded.frame.payload().len() as u64;
            framed.extend_from_slice(encoded.frame.payload());
        }
    }
    assert_eq!(framed, from_json, "OUTPUT payloads differ from the JSON path");
    assert_eq!(framed, sent);
    assert_eq!(encoder.offset(), expected_offset);
    assert_eq!(expected_offset, attach.offset + sent.len() as u64);
}

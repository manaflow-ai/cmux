//! Golden vectors in spec/fixtures/ipc-frames, shared with the Swift reader.
//!
//! `manifest.json` describes every `.bin` in plain fields (u64 values as hex
//! strings, payloads as hex) so another implementation can rebuild and decode
//! them without this crate. `CMUX_IPC_BLESS=1` rewrites the files from the
//! encoder; without it the test fails when the encoder and a file disagree.

use std::path::PathBuf;

use bytes::{Bytes, BytesMut};
use serde_json::{Value, json};

use super::{Got, drain, framed_reader, one_of_each_kind};
use crate::{Aux, BadMessage, Frame, FrameHeader, FrameKind, HEADER_LEN, ReaderLimits};

fn fixture_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../spec/fixtures/ipc-frames")
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn aux_json(aux: Aux) -> Value {
    match aux {
        Aux::Offset(value) => json!({ "offset": format!("{value:#018x}") }),
        Aux::FlowId(value) => json!({ "flow_id": format!("{value:#018x}") }),
        Aux::SharedBufferSize(value) => json!({ "shared_buffer_size": format!("{value:#018x}") }),
        Aux::Call(call) => json!({
            "request_id": call.request_id,
            "method_id": format!("{:#06x}", call.method_id),
            "priority": call.priority.wire(),
            "flags": call.flags.bits(),
        }),
    }
}

fn frame_json(frame: &Frame) -> Value {
    json!({
        "kind": frame.header().kind().name(),
        "kind_wire": frame.header().kind().wire(),
        "stream": frame.header().stream(),
        "aux": aux_json(frame.header().aux()),
        "payload_hex": hex(frame.payload()),
    })
}

struct Vector {
    file: String,
    bytes: Vec<u8>,
    describe: Value,
}

fn good_vectors() -> Vec<Vector> {
    let mut vectors: Vec<Vector> = one_of_each_kind()
        .into_iter()
        .map(|frame| {
            let mut bytes = BytesMut::new();
            frame.encode_into(&mut bytes);
            Vector {
                file: format!("{}.bin", frame.header().kind().name()),
                bytes: bytes.to_vec(),
                describe: json!({ "messages": [ { "frame": frame_json(&frame) } ] }),
            }
        })
        .collect();
    let mut mixed = BytesMut::new();
    let mut messages = Vec::new();
    for (line, frame) in ["{\"cmd\":\"identify\",\"id\":1}", ""].into_iter().zip(one_of_each_kind())
    {
        mixed.extend_from_slice(line.as_bytes());
        mixed.extend_from_slice(b"\n");
        messages.push(json!({ "json": line }));
        frame.encode_into(&mut mixed);
        messages.push(json!({ "frame": frame_json(&frame) }));
    }
    vectors.push(Vector {
        file: "mixed-lines-and-frames.bin".into(),
        bytes: mixed.to_vec(),
        describe: json!({ "messages": messages }),
    });
    vectors
}

fn bad_vectors() -> Vec<Vector> {
    let output = |payload: &'static [u8]| {
        let frame =
            Frame::new(FrameKind::Output, 1, Aux::Offset(0), Bytes::from_static(payload)).unwrap();
        let mut bytes = BytesMut::new();
        frame.encode_into(&mut bytes);
        bytes.to_vec()
    };
    let request =
        FrameHeader::new(FrameKind::Request, 0, 0, super::sample_aux(FrameKind::Request, 0))
            .unwrap()
            .encode();
    let mut unknown_kind = output(b"");
    unknown_kind[1] = 12;
    let mut oversize = output(b"");
    oversize[4..8].copy_from_slice(&(crate::MAX_FRAME_PAYLOAD + 1).to_le_bytes());
    let mut control_output = output(b"");
    control_output[2] = 0;
    let mut unknown_flags = request.to_vec();
    unknown_flags[15] = 0x80;
    let mut unknown_priority = request.to_vec();
    unknown_priority[14] = 9;
    let mut truncated = output(b"abcdef");
    truncated.truncate(HEADER_LEN + 3);
    [
        ("bad-unknown-kind.bin", unknown_kind, BadMessage::UnknownKind { kind: 12 }),
        (
            "bad-oversize.bin",
            oversize,
            BadMessage::Oversize {
                len: crate::MAX_FRAME_PAYLOAD + 1,
                max: crate::MAX_FRAME_PAYLOAD,
            },
        ),
        (
            "bad-output-on-stream-0.bin",
            control_output,
            BadMessage::DataOnControlStream { kind: FrameKind::Output },
        ),
        ("bad-unknown-flags.bin", unknown_flags, BadMessage::UnknownFlags { flags: 0x80 }),
        ("bad-unknown-priority.bin", unknown_priority, BadMessage::UnknownPriority { hint: 9 }),
        (
            "bad-truncated.bin",
            truncated,
            BadMessage::Truncated { have: HEADER_LEN + 3, need: HEADER_LEN + 6 },
        ),
    ]
    .into_iter()
    .map(|(file, bytes, bad)| Vector {
        file: file.into(),
        bytes,
        describe: json!({ "bad_message": bad.reason() }),
    })
    .collect()
}

fn decode_vector(bytes: &[u8]) -> Result<Vec<Got>, BadMessage> {
    let mut reader = framed_reader();
    reader.push(bytes);
    reader.mark_eof();
    drain(&mut reader)
}

fn manifest(vectors: &[Vector]) -> Value {
    let entries: Vec<Value> = vectors
        .iter()
        .map(|vector| {
            let mut entry = vector.describe.clone();
            entry["file"] = json!(vector.file);
            entry
        })
        .collect();
    json!({
        "_doc": "Golden cmux-ipc frames (cmux-tui/spec/transports.md, Binary frames). Rewrite with CMUX_IPC_BLESS=1 cargo test -p cmux-ipc golden.",
        "header_len": HEADER_LEN,
        "max_frame_payload": crate::MAX_FRAME_PAYLOAD,
        "max_json_line": ReaderLimits::default().max_line,
        "vectors": entries,
    })
}

#[test]
fn golden_bin_files_equal_encoder_output() {
    let dir = fixture_dir();
    let mut vectors = good_vectors();
    vectors.extend(bad_vectors());
    let manifest_text = format!("{}\n", serde_json::to_string_pretty(&manifest(&vectors)).unwrap());
    if std::env::var_os("CMUX_IPC_BLESS").is_some() {
        std::fs::create_dir_all(&dir).unwrap();
        for vector in &vectors {
            std::fs::write(dir.join(&vector.file), &vector.bytes).unwrap();
        }
        std::fs::write(dir.join("manifest.json"), &manifest_text).unwrap();
    }
    for vector in &vectors {
        let on_disk = std::fs::read(dir.join(&vector.file)).unwrap_or_else(|error| {
            panic!("{}: {error}; bless with CMUX_IPC_BLESS=1", vector.file)
        });
        assert_eq!(on_disk, vector.bytes, "{} differs from the encoder", vector.file);
    }
    let on_disk_manifest = std::fs::read_to_string(dir.join("manifest.json")).unwrap();
    assert_eq!(on_disk_manifest, manifest_text, "manifest.json differs");
    let mut listed: Vec<String> = std::fs::read_dir(&dir)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .filter(|name| name.ends_with(".bin"))
        .collect();
    listed.sort();
    let mut expected: Vec<String> = vectors.iter().map(|vector| vector.file.clone()).collect();
    expected.sort();
    assert_eq!(listed, expected, "stale .bin files in {}", dir.display());
}

#[test]
fn golden_vectors_decode_as_the_manifest_says() {
    let manifest: Value = serde_json::from_str(
        &std::fs::read_to_string(fixture_dir().join("manifest.json")).unwrap(),
    )
    .unwrap();
    for entry in manifest["vectors"].as_array().unwrap() {
        let file = entry["file"].as_str().unwrap();
        let bytes = std::fs::read(fixture_dir().join(file)).unwrap();
        let decoded = decode_vector(&bytes);
        if let Some(reason) = entry["bad_message"].as_str() {
            assert_eq!(decoded.map_err(|bad| bad.reason()), Err(reason), "{file}");
            continue;
        }
        let described: Vec<Value> = decoded
            .unwrap_or_else(|bad| panic!("{file}: {bad}"))
            .iter()
            .map(|got| match got {
                Got::Line(line) => json!({ "json": line }),
                Got::Frame(frame) => json!({ "frame": frame_json(frame) }),
            })
            .collect();
        assert_eq!(Value::Array(described), entry["messages"], "{file}");
    }
}

//! The binary IPC reader (`cmux_ipc::FrameReader`, the daemon's and the
//! app's connection reader; p05-ipc-182), fed in chunks, against a reference
//! cutter written from the wire's rules (spec/transports.md, "Binary
//! frames"): it must return the same JSON lines and frames, in order, and
//! stop at the same `BadMessage`, whatever the chunk sizes. Mojo's channel
//! fuzzer checks its read loop the same way, on split reads
//! (chromium mojo/core/channel_fuzzer.cc).
//!
//! The reference shares only `FrameHeader::decode` with the reader (its
//! golden vectors in spec/fixtures/ipc-frames pin it), and checks that a
//! decoded header encodes back to its bytes.
//!
//! Input:
//! - byte 0, flags: bit 0 frames are negotiated from the start; bit 1 they
//!   are negotiated after `byte 1` messages (a `set-client-info` reply);
//!   bit 2 the rest is structured (below), else raw; bit 3 chunks go
//!   through `read_with`, else `push`.
//! - byte 2: the line limit, 0 for the daemon's 16 MiB, else 4 * N bytes.
//! - byte 3: the frame payload limit, 0 for 32 MiB, else 16 * N bytes.
//! - bytes 4..8: four chunk sizes (N + 1), used in turn.
//! - the rest: the stream, or with bit 2 a list of pieces built with
//!   `arbitrary` (lines, frames with valid or broken headers, call frames
//!   naming methods of the schema's table, raw bytes).

#![no_main]

use std::io;

use arbitrary::{Arbitrary, Unstructured};
use cmux_ipc::{
    BadMessage, FrameHeader, FrameKind, FrameReader, HEADER_LEN, MAGIC, Message, MethodTables,
    PriorityHint, ReaderLimits,
};
use libfuzzer_sys::fuzz_target;

/// One message the reader returned, owned.
#[derive(Debug, PartialEq, Eq)]
enum Got {
    Line(Vec<u8>),
    Frame([u8; HEADER_LEN], Vec<u8>),
}

/// What the reference expects of the whole stream.
struct Expected {
    messages: Vec<Got>,
    /// The bad message that ends the stream, if any.
    error: Option<BadMessage>,
}

/// Cuts `stream` as the wire's rules say. `negotiated(i)` tells whether
/// frames are allowed when message `i` is cut.
fn reference(stream: &[u8], limits: ReaderLimits, negotiated: impl Fn(usize) -> bool) -> Expected {
    let mut messages = Vec::new();
    let mut at = 0;
    let error = loop {
        let rest = &stream[at..];
        let Some(&first) = rest.first() else {
            break None;
        };
        if first == MAGIC {
            if !negotiated(messages.len()) {
                break Some(BadMessage::FramesNotNegotiated);
            }
            let Some(head) = rest.get(..HEADER_LEN) else {
                break Some(BadMessage::Truncated { have: rest.len(), need: HEADER_LEN });
            };
            let bytes: [u8; HEADER_LEN] = head.try_into().expect("16 bytes");
            let header = match FrameHeader::decode(bytes, limits.max_frame_payload) {
                Ok(header) => header,
                Err(bad) => break Some(bad),
            };
            assert_eq!(header.encode(), bytes, "a decoded header does not encode to its bytes");
            let need = HEADER_LEN + header.len() as usize;
            let Some(frame) = rest.get(..need) else {
                break Some(BadMessage::Truncated { have: rest.len(), need });
            };
            messages.push(Got::Frame(bytes, frame[HEADER_LEN..].to_vec()));
            at += need;
            continue;
        }
        let (line, consumed) = match rest.iter().position(|&byte| byte == b'\n') {
            Some(end) => (&rest[..end], end + 1),
            None => (rest, rest.len()),
        };
        if line.len() > limits.max_line {
            break Some(BadMessage::LineTooLong { max: limits.max_line });
        }
        if let Err(error) = std::str::from_utf8(line) {
            break Some(BadMessage::InvalidUtf8 { valid_up_to: error.valid_up_to() });
        }
        messages.push(Got::Line(line.to_vec()));
        at += consumed;
    };
    Expected { messages, error }
}

/// One piece of a structured stream.
#[derive(Arbitrary, Debug)]
enum Piece {
    Line(String),
    /// A frame whose header the encoder accepts.
    Frame {
        kind: u8,
        stream: u16,
        aux: u64,
        payload: Vec<u8>,
    },
    /// A call frame naming a method of the table, with its table priority.
    Call {
        method: u16,
        request_id: u32,
        flags: u8,
        payload: Vec<u8>,
    },
    /// A header with any fields and a declared length that may lie.
    RawHeader {
        kind: u8,
        stream: u16,
        len: u32,
        aux: u64,
    },
    Bytes(Vec<u8>),
}

fn header_bytes(kind: u8, stream: u16, len: u32, aux: u64) -> [u8; HEADER_LEN] {
    let mut bytes = [0; HEADER_LEN];
    bytes[0] = MAGIC;
    bytes[1] = kind;
    bytes[2..4].copy_from_slice(&stream.to_le_bytes());
    bytes[4..8].copy_from_slice(&len.to_le_bytes());
    bytes[8..16].copy_from_slice(&aux.to_le_bytes());
    bytes
}

fn structured(data: &[u8]) -> Vec<u8> {
    let methods: Vec<_> = MethodTables::schema()
        .v12_families()
        .chain(MethodTables::schema().v2_families())
        .flat_map(|family| family.iter())
        .collect();
    let mut u = Unstructured::new(data);
    let pieces: Vec<Piece> = Vec::arbitrary(&mut u).unwrap_or_default();
    let mut out = Vec::new();
    for piece in pieces {
        match piece {
            Piece::Line(line) => {
                out.extend_from_slice(line.as_bytes());
                out.push(b'\n');
            }
            Piece::Frame { kind, stream, aux, payload } => {
                let kind = FrameKind::ALL[usize::from(kind) % FrameKind::ALL.len()].wire();
                let stream =
                    if stream == 0 && kind < FrameKind::Request.wire() { 1 } else { stream };
                let len = u32::try_from(payload.len()).unwrap_or(u32::MAX);
                out.extend_from_slice(&header_bytes(kind, stream, len, aux));
                out.extend_from_slice(&payload);
            }
            Piece::Call { method, request_id, flags, payload } => {
                let Some(method) = methods.get(usize::from(method) % methods.len().max(1)) else {
                    continue;
                };
                let priority: PriorityHint = method.priority;
                let aux = u64::from(request_id)
                    | (u64::from(method.id.raw()) << 32)
                    | (u64::from(priority.wire()) << 48)
                    | (u64::from(flags & 0b1_1111) << 56);
                let len = u32::try_from(payload.len()).unwrap_or(u32::MAX);
                out.extend_from_slice(&header_bytes(FrameKind::Request.wire(), 0, len, aux));
                out.extend_from_slice(&payload);
            }
            Piece::RawHeader { kind, stream, len, aux } => {
                out.extend_from_slice(&header_bytes(kind, stream, len, aux));
            }
            Piece::Bytes(bytes) => out.extend_from_slice(&bytes),
        }
    }
    out
}

fn owned(message: Message<'_>) -> Got {
    match message {
        Message::Json(line) => Got::Line(line.as_bytes().to_vec()),
        Message::Frame(frame) => Got::Frame(frame.header().encode(), frame.payload().to_vec()),
    }
}

fn message_len(got: &Got) -> usize {
    match got {
        Got::Line(line) => line.len(),
        Got::Frame(_, payload) => HEADER_LEN + payload.len(),
    }
}

fuzz_target!(|data: &[u8]| {
    let [flags, negotiate_after, line_limit, frame_limit, c0, c1, c2, c3, rest @ ..] = data else {
        return;
    };
    let from_start = flags & 1 != 0;
    let after = (flags & 2 != 0).then_some(usize::from(*negotiate_after));
    let negotiated = |index: usize| from_start || after.is_some_and(|after| index >= after);
    let limits = ReaderLimits {
        max_line: match line_limit {
            0 => cmux_ipc::MAX_JSON_LINE,
            n => 4 * usize::from(*n),
        },
        max_frame_payload: match frame_limit {
            0 => cmux_ipc::MAX_FRAME_PAYLOAD,
            n => 16 * u32::from(*n),
        },
    };
    let owned_stream;
    let stream: &[u8] = if flags & 4 != 0 {
        owned_stream = structured(rest);
        &owned_stream
    } else {
        rest
    };
    let read_with = flags & 8 != 0;
    let chunks = [*c0, *c1, *c2, *c3].map(|size| usize::from(size) + 1);

    let expected = reference(stream, limits, negotiated);

    let mut reader = FrameReader::new(limits);
    if from_start {
        reader.negotiate_frames();
    }
    let mut got = Vec::new();
    let mut error = None;
    let mut delivered = 0;
    let mut consumed = 0;
    let mut turn = 0;
    // Drains what the reader has; `Some` once it stopped on a bad message.
    let drain = |reader: &mut FrameReader,
                 got: &mut Vec<Got>,
                 delivered: usize,
                 consumed: &mut usize|
     -> Option<BadMessage> {
        loop {
            if after == Some(got.len()) {
                reader.negotiate_frames();
            }
            assert_eq!(reader.buffered_len(), delivered - *consumed, "buffered bytes drifted");
            if let Some(&next) = stream.get(*consumed).filter(|_| *consumed < delivered) {
                assert_eq!(reader.next_is_frame(), next == MAGIC, "next_is_frame is wrong");
            }
            match reader.next_message() {
                Ok(Some(message)) => {
                    let message = owned(message);
                    *consumed += message_len(&message)
                        + usize::from(
                            matches!(message, Got::Line(_))
                                && stream.get(*consumed + message_len(&message)) == Some(&b'\n'),
                        );
                    got.push(message);
                }
                Ok(None) => return None,
                Err(bad) => {
                    assert_eq!(
                        reader.next_message().err(),
                        Some(bad),
                        "a bad message is not sticky"
                    );
                    return Some(bad);
                }
            }
        }
    };
    while delivered < stream.len() && error.is_none() {
        let size = chunks[turn % chunks.len()].min(stream.len() - delivered);
        turn += 1;
        let chunk = &stream[delivered..delivered + size];
        if read_with {
            let read = reader
                .read_with(|room| {
                    let count = chunk.len().min(room.len());
                    room[..count].copy_from_slice(&chunk[..count]);
                    Ok::<usize, io::Error>(count)
                })
                .expect("an in-memory read cannot fail");
            assert_eq!(read, size, "read_with dropped bytes");
        } else {
            reader.push(chunk);
        }
        delivered += size;
        error = drain(&mut reader, &mut got, delivered, &mut consumed);
    }
    if error.is_none() {
        reader.mark_eof();
        error = drain(&mut reader, &mut got, delivered, &mut consumed);
    }
    assert_eq!(got, expected.messages, "the reader cut the stream differently");
    assert_eq!(error, expected.error, "the reader stopped differently");
});

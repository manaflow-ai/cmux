use std::io::{self, Read};

use bytes::{Bytes, BytesMut};

use super::{Got, drain, encode_all, framed_reader, one_of_each_kind};
use crate::{
    Aux, BadMessage, Frame, FrameHeader, FrameKind, FrameReader, HEADER_LEN, MAX_FRAME_PAYLOAD,
    Message, ReaderLimits,
};

/// Lines and every kind of frame, interleaved, as one byte stream.
fn mixed_stream() -> (BytesMut, Vec<Got>) {
    let mut bytes = BytesMut::new();
    let mut expected = Vec::new();
    let lines = ["{\"cmd\":\"identify\",\"id\":1}", "", "{\"event\":\"ünïcødé\"}"];
    for (index, frame) in one_of_each_kind().into_iter().enumerate() {
        let line = lines[index % lines.len()];
        bytes.extend_from_slice(line.as_bytes());
        bytes.extend_from_slice(b"\n");
        expected.push(Got::Line(line.to_owned()));
        frame.encode_into(&mut bytes);
        expected.push(Got::Frame(frame));
    }
    let empty = Frame::new(FrameKind::RingAck, 9, Aux::Offset(42), Bytes::new()).unwrap();
    empty.encode_into(&mut bytes);
    expected.push(Got::Frame(empty));
    (bytes, expected)
}

#[test]
fn round_trip_per_kind() {
    for frame in one_of_each_kind() {
        let mut reader = framed_reader();
        reader.push(&encode_all(std::slice::from_ref(&frame)));
        assert_eq!(drain(&mut reader), Ok(vec![Got::Frame(frame)]));
        assert_eq!(reader.buffered_len(), 0);
    }
}

#[test]
fn split_read_at_every_byte_boundary() {
    let (bytes, expected) = mixed_stream();
    for split in 0..=bytes.len() {
        let mut reader = framed_reader();
        let mut got = Vec::new();
        reader.push(&bytes[..split]);
        got.extend(drain(&mut reader).unwrap());
        reader.push(&bytes[split..]);
        got.extend(drain(&mut reader).unwrap());
        assert_eq!(got, expected, "split at {split}");
        assert_eq!(reader.buffered_len(), 0, "split at {split}");
    }
}

#[test]
fn one_byte_at_a_time() {
    let (bytes, expected) = mixed_stream();
    let mut reader = framed_reader();
    let mut got = Vec::new();
    for byte in bytes.iter() {
        reader.push(std::slice::from_ref(byte));
        got.extend(drain(&mut reader).unwrap());
    }
    assert_eq!(got, expected);
}

/// Hands out its bytes in fixed-size reads, like a socket under load.
struct Chunked {
    bytes: Bytes,
    chunk: usize,
}

impl Read for Chunked {
    fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
        let n = self.chunk.min(out.len()).min(self.bytes.len());
        out[..n].copy_from_slice(&self.bytes.split_to(n));
        Ok(n)
    }
}

#[test]
fn read_from_cuts_the_same_messages_and_marks_eof() {
    let (bytes, expected) = mixed_stream();
    for chunk in [1, 7, HEADER_LEN, 4096] {
        let mut source = Chunked { bytes: bytes.clone().freeze(), chunk };
        let mut reader = framed_reader();
        let mut got = Vec::new();
        while reader.read_from(&mut source).unwrap() > 0 {
            got.extend(drain(&mut reader).unwrap());
        }
        got.extend(drain(&mut reader).unwrap());
        assert_eq!(got, expected, "chunk {chunk}");
    }
}

#[test]
fn frame_payloads_share_the_read_buffer() {
    let first =
        Frame::new(FrameKind::Output, 1, Aux::Offset(0), Bytes::from(vec![1u8; 70_000])).unwrap();
    let second =
        Frame::new(FrameKind::Output, 1, Aux::Offset(70_000), Bytes::from(vec![2u8; 9])).unwrap();
    let bytes = encode_all(&[first, second]).freeze();
    let mut source = Chunked { bytes: bytes.clone(), chunk: bytes.len() };
    let mut reader = framed_reader();
    // One read pulls both frames into the reader's own buffer.
    while reader.buffered_len() < bytes.len() {
        assert!(reader.read_from(&mut source).unwrap() > 0);
    }
    let Some(Message::Frame(a)) = reader.next_message().unwrap() else { panic!("frame") };
    let Some(Message::Frame(b)) = reader.next_message().unwrap() else { panic!("frame") };
    // Contiguous payloads prove neither was copied out of the buffer.
    let gap = b.payload().as_ptr() as usize - a.payload().as_ptr() as usize;
    assert_eq!(gap, a.payload().len() + HEADER_LEN);
    assert!(a.payload().iter().all(|byte| *byte == 1));
    assert_eq!(b.payload().as_ref(), &[2u8; 9]);
    // The payloads outlive the reader.
    drop(reader);
    assert_eq!(a.payload().len(), 70_000);
}

#[test]
fn frame_payloads_are_zeroed_when_their_last_handle_drops() {
    let wiped = || crate::reader::WIPED_BYTES.with(std::cell::Cell::get);
    let secret = br#"{"cmd":"send","text":"hunter2"}"#;
    let request = Frame::new(
        FrameKind::Request,
        0,
        Aux::Call(crate::CallAux {
            request_id: 1,
            method_id: 0x0101,
            priority: crate::PriorityHint::Control,
            flags: crate::CallFlags::empty(),
        }),
        Bytes::from_static(secret),
    )
    .unwrap();
    let mut bytes = encode_all(&[request]);
    // A line behind the frame keeps the read buffer's allocation shared.
    bytes.extend_from_slice(b"{\"cmd\":\"ping\"}\n");
    let mut reader = framed_reader();
    reader.push(&bytes);
    let Some(Message::Frame(frame)) = reader.next_message().unwrap() else { panic!("frame") };
    let before = wiped();
    let copy = frame.payload().clone();
    drop(frame);
    assert_eq!(wiped(), before, "a clone still shares the payload");
    assert_eq!(copy.as_ref(), secret);
    drop(copy);
    assert_eq!(wiped(), before + secret.len(), "the last drop zeroes the payload");
    assert_eq!(drain(&mut reader), Ok(vec![Got::Line("{\"cmd\":\"ping\"}".into())]));
}

#[test]
fn json_lines_pass_through_verbatim() {
    let mut reader = FrameReader::new(ReaderLimits::default());
    reader.push(b"{\"a\":1}\r\n  \n\n{\"b\":2}");
    assert_eq!(
        drain(&mut reader),
        Ok(vec![Got::Line("{\"a\":1}\r".into()), Got::Line("  ".into()), Got::Line(String::new())])
    );
    // A trailing line without a delimiter is a message at EOF, as read_line returns it.
    reader.mark_eof();
    assert_eq!(drain(&mut reader), Ok(vec![Got::Line("{\"b\":2}".into())]));
}

#[test]
fn frame_before_negotiation_is_bad_message() {
    let frame = Frame::new(FrameKind::Output, 1, Aux::Offset(0), Bytes::from_static(b"x")).unwrap();
    let mut reader = FrameReader::new(ReaderLimits::default());
    reader.push(b"{\"cmd\":\"hello\"}\n");
    reader.push(&encode_all(&[frame]));
    assert_eq!(drain(&mut reader), Err(BadMessage::FramesNotNegotiated));
}

#[test]
fn bad_magic_in_frame_position_is_not_utf8() {
    // 0xFE starts neither a frame nor UTF-8 text.
    let mut reader = framed_reader();
    reader.push(&[0xFE, b'a', b'\n']);
    assert_eq!(drain(&mut reader), Err(BadMessage::InvalidUtf8 { valid_up_to: 0 }));
}

#[test]
fn unknown_kind_is_refused_from_the_header_alone() {
    let mut header = FrameHeader::new(FrameKind::Output, 1, 0, Aux::Offset(0)).unwrap().encode();
    header[1] = 0x7F;
    let mut reader = framed_reader();
    reader.push(&header);
    assert_eq!(drain(&mut reader), Err(BadMessage::UnknownKind { kind: 0x7F }));
}

#[test]
fn oversize_frame_is_refused_before_its_payload() {
    let mut header = FrameHeader::new(FrameKind::Output, 1, 0, Aux::Offset(0)).unwrap().encode();
    header[4..8].copy_from_slice(&u32::MAX.to_le_bytes());
    let mut reader = framed_reader();
    reader.push(&header);
    assert_eq!(
        drain(&mut reader),
        Err(BadMessage::Oversize { len: u32::MAX, max: MAX_FRAME_PAYLOAD })
    );
    let mut small = FrameReader::new(ReaderLimits { max_line: 64, max_frame_payload: 8 });
    small.negotiate_frames();
    let frame =
        Frame::new(FrameKind::Input, 1, Aux::FlowId(0), Bytes::from_static(b"123456789")).unwrap();
    small.push(&encode_all(&[frame])[..HEADER_LEN]);
    assert_eq!(drain(&mut small), Err(BadMessage::Oversize { len: 9, max: 8 }));
}

#[test]
fn long_line_is_refused_before_its_delimiter() {
    let mut reader = FrameReader::new(ReaderLimits { max_line: 8, max_frame_payload: 1024 });
    reader.push(b"12345678\n");
    assert_eq!(drain(&mut reader), Ok(vec![Got::Line("12345678".into())]));
    reader.push(b"123456789");
    assert_eq!(drain(&mut reader), Err(BadMessage::LineTooLong { max: 8 }));
    let mut split = FrameReader::new(ReaderLimits { max_line: 8, max_frame_payload: 1024 });
    split.push(b"12345");
    assert_eq!(drain(&mut split), Ok(vec![]));
    split.push(b"6789\n");
    assert_eq!(drain(&mut split), Err(BadMessage::LineTooLong { max: 8 }));
}

#[test]
fn eof_inside_a_frame_is_truncated() {
    let frame =
        Frame::new(FrameKind::Snapshot, 2, Aux::Offset(5), Bytes::from_static(b"abcdef")).unwrap();
    let bytes = encode_all(&[frame]);
    for cut in 1..bytes.len() {
        let mut reader = framed_reader();
        reader.push(&bytes[..cut]);
        assert_eq!(drain(&mut reader), Ok(vec![]), "cut {cut}");
        reader.mark_eof();
        let need = if cut < HEADER_LEN { HEADER_LEN } else { bytes.len() };
        assert_eq!(drain(&mut reader), Err(BadMessage::Truncated { have: cut, need }), "cut {cut}");
    }
}

#[test]
fn reader_stays_failed_after_a_bad_message() {
    let mut reader = framed_reader();
    reader.push(&[0xFF, 0x00]);
    reader.push(&[0u8; 14]);
    let first = drain(&mut reader);
    assert_eq!(first, Err(BadMessage::UnknownKind { kind: 0 }));
    reader.push(b"{\"cmd\":\"ok\"}\n");
    assert_eq!(drain(&mut reader), first);
}

#[test]
fn arbitrary_bytes_never_panic() {
    // A small deterministic fuzz pass; the coverage-guided targets run on the fleet.
    let (stream, _) = mixed_stream();
    let mut state = 0x9E37_79B9_7F4A_7C15_u64;
    for _ in 0..2_000 {
        let mut bytes = stream.to_vec();
        for _ in 0..4 {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            let at = (state as usize) % bytes.len();
            bytes[at] = (state >> 32) as u8;
        }
        let mut reader = FrameReader::new(ReaderLimits { max_line: 4096, max_frame_payload: 4096 });
        reader.negotiate_frames();
        reader.push(&bytes);
        reader.mark_eof();
        while let Ok(Some(_)) = reader.next_message() {}
    }
}

#[test]
fn an_idle_reader_frees_the_room_a_long_message_grew() {
    let mut reader = FrameReader::new(ReaderLimits::default());
    let line = "x".repeat(4 * 1024 * 1024);
    reader.push(line.as_bytes());
    reader.push(b"\n");
    assert!(reader.capacity() > line.len());
    assert_eq!(reader.next_message(), Ok(Some(Message::Json(&line))));
    assert_eq!(reader.next_message(), Ok(None));
    assert!(reader.capacity() <= 1024 * 1024, "idle capacity {}", reader.capacity());

    let frame =
        Frame::new(FrameKind::Output, 1, Aux::Offset(0), Bytes::from(vec![3u8; 3 << 20])).unwrap();
    let mut reader = framed_reader();
    reader.push(&encode_all(std::slice::from_ref(&frame)));
    assert_eq!(drain(&mut reader), Ok(vec![Got::Frame(frame)]));
    reader.push(b"{}\n");
    assert!(reader.capacity() <= 1024 * 1024, "idle capacity {}", reader.capacity());
    assert_eq!(drain(&mut reader), Ok(vec![Got::Line("{}".to_owned())]));
}

#[test]
fn read_with_lends_room_sized_to_the_pending_frame() {
    let frame =
        Frame::new(FrameKind::Output, 1, Aux::Offset(0), Bytes::from(vec![5u8; 200_000])).unwrap();
    let encoded = encode_all(std::slice::from_ref(&frame));
    let mut reader = framed_reader();
    let mut lent = 0;
    let header = reader
        .read_with(|room| {
            lent = room.len();
            room[..HEADER_LEN].copy_from_slice(&encoded[..HEADER_LEN]);
            Ok(HEADER_LEN)
        })
        .unwrap();
    assert_eq!((header, lent), (HEADER_LEN, 64 * 1024), "no frame pending: the minimum");
    assert_eq!(reader.next_message(), Ok(None));
    let rest = reader
        .read_with(|room| {
            lent = room.len();
            room[..200_000].copy_from_slice(&encoded[HEADER_LEN..]);
            Ok(200_000)
        })
        .unwrap();
    assert_eq!((rest, lent), (200_000, 200_000), "the header sizes the next read");
    assert_eq!(drain(&mut reader), Ok(vec![Got::Frame(frame)]));

    // A source that claims more than it was lent is held to the room.
    let mut reader = FrameReader::new(ReaderLimits::default());
    assert_eq!(reader.read_with(|room| Ok(room.len() + 10)).unwrap(), 64 * 1024);
    assert_eq!(reader.buffered_len(), 64 * 1024);
}

#[test]
fn next_is_frame_looks_past_the_lent_line() {
    let mut reader = FrameReader::new(ReaderLimits::default());
    assert!(!reader.next_is_frame());
    reader.push(b"{}\n");
    reader.push(&[0xFF]);
    assert!(!reader.next_is_frame());
    assert_eq!(reader.next_message(), Ok(Some(Message::Json("{}"))));
    assert!(reader.next_is_frame());
    assert_eq!(reader.next_message(), Err(BadMessage::FramesNotNegotiated));
}

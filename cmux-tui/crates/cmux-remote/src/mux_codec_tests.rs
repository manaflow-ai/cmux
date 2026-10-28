//! Frames across the bridge codec: read by header, cut into
//! packets, joined back byte for byte, per stream in order.

use std::collections::HashMap;

use cmux_ipc::{Aux, BadMessage, FrameHeader, FrameKind};
use tokio::io::BufReader;

use super::*;

fn frame(kind: FrameKind, stream: u16, aux: Aux, payload: &[u8]) -> Vec<u8> {
    let header =
        FrameHeader::new(kind, stream, u32::try_from(payload.len()).unwrap(), aux).unwrap();
    let mut bytes = header.encode().to_vec();
    bytes.extend_from_slice(payload);
    bytes
}

fn output(stream: u16, offset: u64, payload: &[u8]) -> Vec<u8> {
    frame(FrameKind::Output, stream, Aux::Offset(offset), payload)
}

/// Reads every message of `wire`, as the bridge reads its local socket.
async fn read_all(wire: &[u8], maximum: usize) -> io::Result<Vec<(MuxMessage, Vec<u8>)>> {
    let mut reader = BufReader::with_capacity(7, wire);
    let mut messages = Vec::new();
    let mut message = Vec::new();
    loop {
        let read = read_mux_message(&mut reader, &mut message, maximum).await?;
        if read == MuxMessage::End {
            return Ok(messages);
        }
        messages.push((read, message.clone()));
    }
}

#[tokio::test]
async fn frames_are_read_by_header_never_cut_at_a_newline() {
    // The payload holds LFs and 0xFF bytes; a line reader would cut it.
    let payload = b"one\ntwo\n\xff\xfe\nthree".repeat(100);
    let frame = output(1, 0, &payload);
    let line = b"{\"id\":1,\"ok\":true}\n".to_vec();
    let mut wire = line.clone();
    wire.extend_from_slice(&frame);
    wire.extend_from_slice(&line);

    let messages = read_all(&wire, MAX_MUX_DOWNLOAD_LINE_BYTES).await.unwrap();
    assert_eq!(messages.len(), 3);
    assert_eq!(messages[0], (MuxMessage::Line, line.clone()));
    let MuxMessage::Frame(header) = messages[1].0 else { panic!("not a frame: {messages:?}") };
    assert_eq!((header.kind(), header.stream()), (FrameKind::Output, 1));
    assert_eq!(messages[1].1, frame);
    assert_eq!(messages[2], (MuxMessage::Line, line));
}

#[tokio::test]
async fn interleaved_frames_of_three_streams_keep_per_stream_order_and_bytes() {
    // OUTPUT and EVENT frames of three streams, interleaved with JSON lines,
    // cross the codec on the lanes the bridge picks; each stream's messages
    // come out in order and byte for byte.
    let mut wire = Vec::new();
    let mut sent: HashMap<u16, Vec<Vec<u8>>> = HashMap::new();
    let mut offsets = [0_u64; 4];
    for round in 0..40_u16 {
        for stream in 1..=3_u16 {
            // Sizes that cross the packet chunk size.
            let len = usize::from(round % 7) * CHUNK_BYTES / 3 + usize::from(stream);
            let payload: Vec<u8> = (0..len).map(|byte| (byte as u8) ^ (stream as u8)).collect();
            let output = output(stream, offsets[usize::from(stream)], &payload);
            offsets[usize::from(stream)] += payload.len() as u64;
            let event = frame(
                FrameKind::Event,
                stream,
                Aux::Offset(offsets[usize::from(stream)]),
                format!("{{\"event\":\"output\",\"surface\":{stream},\"flow\":{round}}}")
                    .as_bytes(),
            );
            for message in [output, event] {
                wire.extend_from_slice(&message);
                sent.entry(stream).or_default().push(message);
            }
        }
        wire.extend_from_slice(format!("{{\"event\":\"bell\",\"surface\":{round}}}\n").as_bytes());
    }

    let tracker = crate::mux_lanes::MuxLaneTracker::default();
    let mut assembler = MuxLineAssembler::<()>::default();
    let mut received: HashMap<u16, Vec<Vec<u8>>> = HashMap::new();
    let mut lanes: HashMap<u16, Lane> = HashMap::new();
    let mut by_lane: HashMap<Lane, Vec<Bytes>> = HashMap::new();
    for (id, (message, bytes)) in
        read_all(&wire, MAX_MUX_DOWNLOAD_LINE_BYTES).await.unwrap().into_iter().enumerate()
    {
        let lane = match message {
            MuxMessage::Frame(header) => {
                let lane = crate::mux_lanes::classify_server_frame(&header);
                assert_eq!(*lanes.entry(header.stream()).or_insert(lane), lane);
                lane
            }
            MuxMessage::Line => tracker.classify_server_line(&bytes).unwrap(),
            MuxMessage::End => unreachable!(),
        };
        let packets =
            encode_line_with_limit(id as u64 + 1, &bytes, MAX_MUX_DOWNLOAD_LINE_BYTES).unwrap();
        by_lane.entry(lane).or_default().extend(packets);
    }
    // Lanes are independent carriers: deliver one lane after the other.
    for (lane, packets) in by_lane {
        for packet in packets {
            if let Some(line) = assembler.push_retaining(lane, packet, ()).unwrap() {
                let payload = line.payload();
                if is_mux_frame(payload) {
                    let header = validate_frame(payload, MAX_MUX_DOWNLOAD_LINE_BYTES).unwrap();
                    received.entry(header.stream()).or_default().push(payload.to_vec());
                }
            }
        }
    }
    assert_eq!(received, sent);
}

#[tokio::test]
async fn a_bad_header_is_refused_before_its_payload_is_read() {
    let mut header = output(1, 0, b"x")[..FRAME_HEADER_BYTES].to_vec();
    header[1] = 0xEE;
    let error = read_all(&header, MAX_MUX_DOWNLOAD_LINE_BYTES).await.unwrap_err();
    assert_eq!(error.kind(), io::ErrorKind::InvalidData);
    let inner = error.get_ref().and_then(|inner| inner.downcast_ref::<BadMessage>());
    assert_eq!(inner, Some(&BadMessage::UnknownKind { kind: 0xEE }));

    // A data frame on control stream 0 is a bad message.
    let mut header = output(1, 0, b"")[..FRAME_HEADER_BYTES].to_vec();
    header[2] = 0;
    let error = read_all(&header, MAX_MUX_DOWNLOAD_LINE_BYTES).await.unwrap_err();
    assert_eq!(error.kind(), io::ErrorKind::InvalidData);
}

#[tokio::test]
async fn a_frame_over_the_direction_budget_is_refused_by_its_header() {
    // Only the header is sent: the declared length alone is refused.
    let header = FrameHeader::new(FrameKind::Output, 1, 4096, Aux::Offset(0)).unwrap().encode();
    let error = read_all(&header, 1024).await.unwrap_err();
    assert_eq!(error.kind(), io::ErrorKind::InvalidData);
    let inner = error.get_ref().and_then(|inner| inner.downcast_ref::<BadMessage>());
    assert_eq!(inner, Some(&BadMessage::Oversize { len: 4096, max: 1023 }));
}

#[tokio::test]
async fn a_reader_that_ends_inside_a_frame_is_truncated() {
    let frame = output(2, 0, b"abcdef");
    for cut in [1, FRAME_HEADER_BYTES - 1, FRAME_HEADER_BYTES + 3] {
        let error = read_all(&frame[..cut], MAX_MUX_DOWNLOAD_LINE_BYTES).await.unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::UnexpectedEof, "cut at {cut}");
    }
}

#[test]
fn a_joined_frame_whose_header_disagrees_with_its_length_is_refused() {
    // A peer that cuts a frame into packets cannot change its length.
    let mut frame = output(1, 0, b"abcdef");
    frame.pop();
    let mut assembler = MuxLineAssembler::<()>::default();
    let packets = encode_line_with_limit(1, &frame, MAX_MUX_DOWNLOAD_LINE_BYTES).unwrap();
    let mut result = Ok(None);
    for packet in packets {
        result = assembler.push_retaining(Lane::Bulk, packet, ());
    }
    assert!(matches!(
        result,
        Err(MuxCodecError::BadFrame(BadMessage::Truncated { have: 21, need: 22 }))
    ));
}

#[test]
fn a_frame_may_use_the_whole_payload_budget() {
    // The budget is the payload's: a line of `maximum - 1` bytes plus LF
    // fits, and so does a frame of `maximum - 1` payload bytes plus header.
    let maximum = CHUNK_BYTES * 2;
    let frame = output(1, 0, &vec![b'\n'; maximum - 1]);
    let packets = encode_line_with_limit(9, &frame, maximum).unwrap();
    let mut assembler = MuxLineAssembler::<()>::with_maximum(maximum);
    let mut joined = None;
    for packet in packets {
        joined = assembler.push_retaining(Lane::Bulk, packet, ()).unwrap();
    }
    assert_eq!(joined.unwrap().payload().as_ref(), frame.as_slice());

    let too_large = output(1, 0, &vec![b'x'; maximum]);
    assert!(matches!(
        encode_line_with_limit(10, &too_large, maximum),
        Err(MuxCodecError::LineTooLarge(_))
    ));
}

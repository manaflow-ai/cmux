//! LaneWriter policy (p05-ipc-052): seeded property tests over random push,
//! pop and lane-change interleavings, plus the shape of chunks, the byte bound
//! and the coalesce hook. The allocation check is tests/lane_writer_alloc.rs.

use std::collections::HashMap;

use bytes::Bytes;

use crate::frame::HEADER_LEN;
use crate::lane_writer::BULK_FRAME_MAX;
use crate::{
    Aux, CallAux, CallFlags, CoalesceKey, EndReason, Frame, FrameKind, Lane, LaneError, LaneWriter,
    LaneWriterConfig, PriorityHint, Pushed, StreamLane,
};

/// xorshift64*: deterministic, so a failing seed replays.
struct Rng(u64);

impl Rng {
    fn new(seed: u64) -> Rng {
        Rng(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1)
    }

    fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    fn below(&mut self, n: u64) -> u64 {
        self.next() % n.max(1)
    }
}

fn call(request_id: u32, flags: CallFlags) -> Aux {
    Aux::Call(CallAux { request_id, method_id: 0x0101, priority: PriorityHint::Control, flags })
}

/// A payload whose bytes name its message, so concatenations compare order.
fn payload(message: u32, len: usize) -> Bytes {
    let tag = message.to_le_bytes();
    Bytes::from((0..len).map(|i| tag[i % 4] ^ (i / 4) as u8).collect::<Vec<u8>>())
}

fn control_frame(message: u32, len: usize, kind: FrameKind) -> Frame {
    Frame::new(kind, 0, call(message, CallFlags::empty()), payload(message, len)).unwrap()
}

fn stream_frame(stream: u16, message: u32, len: usize, pick: u64) -> Frame {
    let bytes = payload(message, len);
    match pick % 4 {
        0 => Frame::new(FrameKind::Output, stream, Aux::Offset(u64::from(message) << 32), bytes),
        1 => Frame::new(FrameKind::Reply, stream, call(message, CallFlags::BINARY), bytes),
        2 => Frame::new(FrameKind::Snapshot, stream, Aux::Offset(u64::from(message)), bytes),
        _ => Frame::new(FrameKind::Grid, stream, Aux::Offset(u64::from(message)), bytes),
    }
    .unwrap()
}

fn small_chunks() -> LaneWriterConfig {
    LaneWriterConfig { chunk_bytes: 1024, ..LaneWriterConfig::default() }
}

/// Pushed and written bytes per FIFO (stream 0 is the control sequence).
#[derive(Default)]
struct Ledger {
    pushed: HashMap<u16, Vec<u8>>,
    written: HashMap<u16, Vec<u8>>,
}

impl Ledger {
    fn pushed(&mut self, frame: &Frame) {
        let target = frame.header().stream();
        self.pushed.entry(target).or_default().extend_from_slice(frame.payload());
    }

    fn written(&mut self, frame: &Frame, chunk_bytes: usize) {
        let header = frame.header();
        if matches!(header.kind(), FrameKind::Output | FrameKind::Reply | FrameKind::Snapshot) {
            assert!(frame.payload().len() <= chunk_bytes, "chunk longer than the chunk size");
        }
        let target = header.stream();
        self.written.entry(target).or_default().extend_from_slice(frame.payload());
    }

    fn assert_equal(&self) {
        for (stream, pushed) in &self.pushed {
            let written = self.written.get(stream).map(Vec::as_slice).unwrap_or_default();
            assert!(written == pushed.as_slice(), "FIFO {stream} wrote its bytes out of order");
        }
    }
}

#[test]
fn lane_writer_keeps_per_stream_fifo_and_control_emit_order() {
    for seed in 0..300 {
        let mut rng = Rng::new(seed);
        let mut writer = LaneWriter::new(small_chunks());
        let mut ledger = Ledger::default();
        let lanes = [StreamLane::Input, StreamLane::Bulk, StreamLane::Background];
        for stream in 1..=6_u16 {
            writer.open_stream(stream, lanes[rng.below(3) as usize]).unwrap();
        }
        let mut message = 0_u32;
        for _ in 0..400 {
            message += 1;
            match rng.below(10) {
                0..=2 => {
                    let kind =
                        if rng.below(2) == 0 { FrameKind::Reply } else { FrameKind::TypedEvent };
                    let frame = control_frame(message, rng.below(3000) as usize, kind);
                    ledger.pushed(&frame);
                    assert_eq!(writer.push_control(frame), Ok(Pushed::Queued));
                }
                3..=5 => {
                    let stream = 1 + rng.below(6) as u16;
                    let frame = stream_frame(stream, message, rng.below(5000) as usize, rng.next());
                    ledger.pushed(&frame);
                    assert_eq!(writer.push_stream(frame), Ok(Pushed::Queued));
                }
                6 => {
                    let stream = 1 + rng.below(6) as u16;
                    writer.set_stream_lane(stream, lanes[rng.below(3) as usize]).unwrap();
                }
                _ => {
                    for _ in 0..rng.below(6) {
                        if let Some(frame) = writer.pop() {
                            ledger.written(&frame, 1024);
                        }
                    }
                }
            }
        }
        while let Some(frame) = writer.pop() {
            ledger.written(&frame, 1024);
        }
        assert_eq!(writer.queued_bytes(), 0, "seed {seed}: byte accounting drifted");
        assert!(writer.is_empty());
        assert_eq!(writer.take_ended(), None);
        ledger.assert_equal();
    }
}

#[test]
fn lane_writer_input_behind_100_mib_bulk_leaves_within_one_chunk() {
    let mut writer = LaneWriter::default();
    writer.open_stream(1, StreamLane::Bulk).unwrap();
    writer.open_stream(2, StreamLane::Input).unwrap();
    writer.open_stream(3, StreamLane::Background).unwrap();
    let quarter = 25 * 1024 * 1024;
    for part in 0..4_u32 {
        let offset = u64::from(part) * quarter as u64;
        let bulk = Frame::new(FrameKind::Snapshot, 1, Aux::Offset(offset), payload(part, quarter));
        writer.push_stream(bulk.unwrap()).unwrap();
    }
    writer.push_stream(stream_frame(3, 99, 4 * BULK_FRAME_MAX, 0)).unwrap();
    let mut rng = Rng::new(7);
    for input in 0..200_u64 {
        for _ in 0..rng.below(20) {
            let frame = writer.pop().unwrap();
            assert!(frame.payload().len() <= BULK_FRAME_MAX);
        }
        let frame = Frame::new(FrameKind::Input, 2, Aux::FlowId(input), Bytes::from_static(b"k"));
        writer.push_stream(frame.unwrap()).unwrap();
        if input % 3 == 0 {
            writer.push_control(control_frame(input as u32, 10, FrameKind::Reply)).unwrap();
        }
        let mut lower = 0;
        loop {
            let frame = writer.pop().unwrap();
            if frame.header().kind() == FrameKind::Input {
                assert_eq!(frame.header().aux(), Aux::FlowId(input));
                break;
            }
            assert!(frame.payload().len() <= BULK_FRAME_MAX, "a lower frame was not chunked");
            lower += 1;
        }
        assert!(lower <= 1, "input {input} waited {lower} lower frames");
    }
}

#[test]
fn lane_writer_starvation_bound_and_stream_credit_hold() {
    let config = LaneWriterConfig { chunk_bytes: 256, ..LaneWriterConfig::default() };
    let mut writer = LaneWriter::new(config);
    writer.open_stream(1, StreamLane::Input).unwrap();
    for stream in [2, 3, 4] {
        writer.open_stream(stream, StreamLane::Bulk).unwrap();
        writer.push_stream(stream_frame(stream, u32::from(stream), 64 * 256, 0)).unwrap();
    }
    writer.open_stream(5, StreamLane::Background).unwrap();
    writer.push_stream(stream_frame(5, 5, 64 * 256, 0)).unwrap();
    for message in 0..400 {
        let input = Frame::new(FrameKind::Input, 1, Aux::FlowId(message), Bytes::new()).unwrap();
        writer.push_stream(input).unwrap();
        writer.push_control(control_frame(message as u32, 8, FrameKind::TypedEvent)).unwrap();
    }
    let (mut over_bulk, mut over_background) = (0, 0);
    let (mut last_bulk, mut run) = (0_u16, 0);
    let mut seen_bulk_streams = 0;
    while let Some(frame) = writer.pop() {
        let bulk_waits = !writer.is_empty() && writer.stream_lane(2).is_some();
        let lane = match frame.header().stream() {
            0 => Lane::Control,
            1 => Lane::Input,
            5 => Lane::Background,
            _ => Lane::Bulk,
        };
        if lane < Lane::Bulk {
            over_bulk += 1;
        } else if lane == Lane::Bulk {
            over_bulk = 0;
        }
        if lane < Lane::Background {
            over_background += 1;
        } else {
            over_background = 0;
        }
        if bulk_waits && writer.queued_bytes() > 64 * 256 * 3 {
            assert!(over_bulk <= 8, "bulk waited {over_bulk} higher frames");
            assert!(over_background <= 10, "background waited {over_background} frames");
        }
        if lane == Lane::Bulk {
            let stream = frame.header().stream();
            run = if stream == last_bulk { run + 1 } else { 1 };
            seen_bulk_streams += usize::from(stream != last_bulk);
            last_bulk = stream;
            if seen_bulk_streams < 40 {
                assert!(run <= 2, "bulk stream {stream} wrote {run} frames in a row");
            }
        }
    }
}

#[test]
fn lane_writer_chunks_carry_more_offsets_and_snapshot_more() {
    let mut writer = LaneWriter::new(small_chunks());
    writer.open_stream(4, StreamLane::Bulk).unwrap();
    writer.push_control(control_frame(9, 2500, FrameKind::Reply)).unwrap();
    let output = Frame::new(FrameKind::Output, 4, Aux::Offset(1000), payload(1, 2048)).unwrap();
    writer.push_stream(output).unwrap();
    writer.push_stream(stream_frame(4, 2, 1500, 2)).unwrap();
    writer.push_stream(stream_frame(4, 3, 5000, 3)).unwrap();
    let frames: Vec<Frame> = std::iter::from_fn(|| writer.pop()).collect();
    let shape: Vec<(FrameKind, Aux, usize)> =
        frames.iter().map(|f| (f.header().kind(), f.header().aux(), f.payload().len())).collect();
    assert_eq!(
        shape,
        vec![
            (FrameKind::Reply, call(9, CallFlags::MORE), 1024),
            (FrameKind::Reply, call(9, CallFlags::MORE), 1024),
            (FrameKind::Reply, call(9, CallFlags::empty()), 452),
            (FrameKind::Output, Aux::Offset(1000), 1024),
            (FrameKind::Output, Aux::Offset(2024), 1024),
            (FrameKind::Snapshot, Aux::Offset(2), 1024),
            (FrameKind::SnapshotMore, Aux::Offset(2), 476),
            (FrameKind::Grid, Aux::Offset(3), 5000),
        ]
    );
}

#[test]
fn lane_writer_byte_bound_ends_largest_droppable_stream() {
    for seed in 0..200 {
        let mut rng = Rng::new(seed);
        let max = 64 * 1024;
        let config =
            LaneWriterConfig { chunk_bytes: 1024, max_queued_bytes: max, ..Default::default() };
        let mut writer = LaneWriter::new(config);
        let lanes = [StreamLane::Input, StreamLane::Bulk, StreamLane::Background];
        let mut lane_of = HashMap::new();
        for stream in 1..=5_u16 {
            let lane = lanes[rng.below(3) as usize];
            writer.open_stream(stream, lane).unwrap();
            lane_of.insert(stream, lane);
        }
        let mut message = 0;
        for _ in 0..300 {
            message += 1;
            let stream = rng.below(6) as u16;
            let len = rng.below(12 * 1024) as usize;
            let before = writer.queued_bytes();
            let result = if stream == 0 {
                writer.push_control(control_frame(message, len, FrameKind::TypedEvent))
            } else {
                writer.push_stream(stream_frame(stream, message, len, rng.next()))
            };
            match result {
                Ok(_) => {}
                Err(LaneError::Overflow { queued, need, max: bound }) => {
                    assert_eq!(bound, max);
                    assert!(queued + need > max);
                }
                Err(LaneError::StreamEnded { stream: ended }) => {
                    assert_eq!(ended, stream, "only the pushing stream is refused as ended");
                }
                Err(other) => panic!("seed {seed}: unexpected {other}"),
            }
            assert!(writer.queued_bytes() <= max, "seed {seed}: bound broken");
            while let Some(ended) = writer.take_ended() {
                assert_eq!(ended.reason, EndReason::Overflow);
                assert!(ended.dropped_bytes > 0 && ended.dropped_bytes <= before);
                assert_ne!(lane_of[&ended.stream], StreamLane::Input, "an input stream was ended");
                let frame = stream_frame(ended.stream, 0, 1, 0);
                assert_eq!(
                    writer.push_stream(frame),
                    Err(LaneError::StreamEnded { stream: ended.stream })
                );
                writer.open_stream(ended.stream, StreamLane::Bulk).unwrap();
                lane_of.insert(ended.stream, StreamLane::Bulk);
            }
            for _ in 0..rng.below(4) {
                writer.pop();
            }
        }
        while writer.pop().is_some() {}
        assert_eq!(writer.queued_bytes(), 0, "seed {seed}: byte accounting drifted");
    }
}

#[test]
fn lane_writer_overflow_never_drops_input_or_control() {
    let config = LaneWriterConfig { max_queued_bytes: 4 * 1024, ..Default::default() };
    let mut writer = LaneWriter::new(config);
    writer.open_stream(1, StreamLane::Input).unwrap();
    writer.push_stream(stream_frame(1, 1, 2000, 0)).unwrap();
    writer.push_control(control_frame(2, 1500, FrameKind::Reply)).unwrap();
    let queued = writer.queued_bytes();
    assert_eq!(queued, 2 * HEADER_LEN + 3500);
    assert_eq!(
        writer.push_control(control_frame(3, 1000, FrameKind::Reply)),
        Err(LaneError::Overflow { queued, need: HEADER_LEN + 1000, max: 4 * 1024 })
    );
    assert_eq!(writer.take_ended(), None);
    assert_eq!(writer.queued_bytes(), queued);
}

#[test]
fn lane_writer_coalesce_hook_replaces_unsent_frame_in_place() {
    let mut writer = LaneWriter::new(small_chunks());
    let key = CoalesceKey(0xC0_01);
    let keep_newer = |_: &Frame, newer: Frame| newer;
    let event = |message: u32| control_frame(message, 10, FrameKind::TypedEvent);
    assert_eq!(writer.push_control_coalescing(event(1), key, keep_newer), Ok(Pushed::Queued));
    writer.push_control(event(2)).unwrap();
    for message in 3..1000 {
        assert_eq!(
            writer.push_control_coalescing(event(message), key, keep_newer),
            Ok(Pushed::Coalesced)
        );
    }
    let ids: Vec<u32> = std::iter::from_fn(|| writer.pop())
        .map(|frame| frame.header().call().unwrap().request_id)
        .collect();
    assert_eq!(ids, vec![999, 2], "the coalesced frame keeps its place");
    assert_eq!(writer.queued_bytes(), 0);

    writer.open_stream(7, StreamLane::Bulk).unwrap();
    let big = |message: u32| stream_frame(7, message, 3000, 1);
    writer.push_stream_coalescing(big(1), key, keep_newer).unwrap();
    writer.pop().unwrap();
    assert_eq!(
        writer.push_stream_coalescing(big(2), key, keep_newer),
        Ok(Pushed::Queued),
        "a partly written frame is never replaced"
    );
    let moved = |_: &Frame, newer: Frame| stream_frame(8, 0, newer.payload().len(), 0);
    assert_eq!(
        writer.push_stream_coalescing(big(3), key, moved),
        Err(LaneError::CoalesceChangedStream { stream: 7 })
    );
}

#[test]
fn lane_writer_stream_lifecycle() {
    let mut writer = LaneWriter::default();
    assert_eq!(writer.open_stream(0, StreamLane::Bulk), Err(LaneError::ControlStream));
    assert_eq!(
        writer.push_stream(stream_frame(5, 1, 1, 0)),
        Err(LaneError::UnknownStream { stream: 5 })
    );
    writer.open_stream(5, StreamLane::Bulk).unwrap();
    assert_eq!(writer.open_stream(5, StreamLane::Input), Err(LaneError::StreamOpen { stream: 5 }));
    let on_five = Frame::new(FrameKind::Reply, 5, call(1, CallFlags::empty()), Bytes::new());
    assert_eq!(
        writer.push_control(on_five.unwrap()),
        Err(LaneError::NotControlSequence { stream: 5 })
    );
    writer.push_stream(stream_frame(5, 1, 10, 0)).unwrap();
    writer.close_stream(5);
    assert_eq!(
        writer.push_stream(stream_frame(5, 2, 10, 0)),
        Err(LaneError::StreamClosing { stream: 5 })
    );
    assert!(writer.pop().is_some());
    assert_eq!(writer.stream_lane(5), None, "a drained closing stream is removed");
    writer.open_stream(5, StreamLane::Background).unwrap();
    writer.push_stream(stream_frame(5, 3, 100, 0)).unwrap();
    assert_eq!(writer.abort_stream(5), HEADER_LEN + 100);
    assert!(writer.is_empty());
    assert_eq!(writer.queued_bytes(), 0);
}

#[test]
fn lane_writer_pop_batch_respects_budget() {
    let mut writer = LaneWriter::new(small_chunks());
    writer.push_control(control_frame(1, 10_000, FrameKind::Reply)).unwrap();
    let mut batch = Vec::new();
    let bytes = writer.pop_batch(&mut batch, 2048);
    assert_eq!(batch.len(), 2);
    assert_eq!(bytes, 2 * (HEADER_LEN + 1024));
}

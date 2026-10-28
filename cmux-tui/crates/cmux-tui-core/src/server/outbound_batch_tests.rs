//! Write batching: queued messages leave in one gathered write
//! per 256 KiB, in the order single pops write them, and a chunk of a long
//! frame ends its batch so a reply waits for at most one chunk.

use super::*;
use crate::server::bounded_outbound::ControlOutbound;
use crate::server::{BudgetedText, OutboundStream, RenderService};
use cmux_ipc::lane_writer::BULK_FRAME_MAX;
use cmux_ipc::{Aux, FrameHeader, FrameKind, MAX_FRAME_PAYLOAD, StreamLane};
use serde_json::json;
use std::io::{self, IoSlice};
use std::sync::Arc;

/// A payload of exactly `len` bytes (a JSON string of `len - 2` letters).
fn payload(service: &RenderService, len: usize) -> Arc<BudgetedText> {
    let text = service.serialize(&"x".repeat(len - 2)).unwrap();
    assert_eq!(text.len(), len);
    text
}

fn stream_on(service: &RenderService, id: u64, lane: StreamLane) -> OutboundStream {
    let overflow = service.serialize_control(&json!({"event": "overflow", "stream": id})).unwrap();
    OutboundStream::with_sequence(id, overflow, false, lane)
}

/// Queues `count` messages on `outbound`: replies, stream lines and frames
/// on the input and bulk lanes, `frame_len` payload bytes each frame.
fn queue_mixed(
    service: &RenderService,
    outbound: &BoundedOutbound,
    count: usize,
    frame_len: usize,
) {
    let lines = stream_on(service, 1, StreamLane::Bulk);
    let output = stream_on(service, 2, StreamLane::Bulk);
    let input = stream_on(service, 3, StreamLane::Input);
    for index in 0..count {
        match index % 4 {
            0 => {
                let reply = json!({"id": index, "ok": true});
                outbound.push_control(service.serialize_control(&reply).unwrap()).unwrap();
            }
            1 => outbound.push_regular(payload(service, 40 + index), &lines).unwrap(),
            2 => {
                let len = frame_len + index;
                let header =
                    FrameHeader::new(FrameKind::Output, 2, len as u32, Aux::Offset(index as u64));
                outbound
                    .push_stream_frame(header.unwrap(), payload(service, len), &output)
                    .unwrap();
            }
            _ => {
                let header = FrameHeader::new(FrameKind::Output, 3, 64, Aux::Offset(0)).unwrap();
                outbound.push_stream_frame(header, payload(service, 64), &input).unwrap();
            }
        }
    }
    outbound.close();
}

/// The bytes single pops write, one `write_line_outbound_item` each.
fn written_one_by_one(outbound: &BoundedOutbound) -> Vec<u8> {
    let mut bytes = Vec::new();
    loop {
        let Some(item) = outbound.state.lock().unwrap().pop() else { return bytes };
        write_line_outbound_item(&mut bytes, item).unwrap();
    }
}

/// Every batch of `outbound` written to `writer` and counted in `ipc`.
fn write_batches<W: Write>(outbound: &BoundedOutbound, writer: &mut W, ipc: &IpcStats) -> usize {
    let mut batch = Vec::new();
    let mut batches = 0;
    while outbound.recv_batch(&mut batch) {
        assert!(batch.len() <= WRITE_BATCH_ITEMS);
        write_counted_batch(writer, ipc, &batch).unwrap();
        batches += 1;
    }
    batches
}

#[test]
fn outbound_batch_writes_100_messages_in_one_writev_per_256_kib_in_pop_order() {
    let service = RenderService::new();
    for frame_len in [64, 20_000] {
        let (single, batched) = (BoundedOutbound::default(), BoundedOutbound::default());
        queue_mixed(&service, &single, 100, frame_len);
        queue_mixed(&service, &batched, 100, frame_len);
        let expected = written_one_by_one(&single);

        let ipc = IpcStats::default();
        let mut bytes = Vec::new();
        write_batches(&batched, &mut bytes, &ipc);

        assert_eq!(bytes, expected, "frame_len {frame_len}: batching changed the bytes or order");
        let writes = ipc.snapshot().writes;
        assert_eq!(writes.messages, 100);
        let bound = 1 + expected.len().div_ceil(WRITE_BATCH_BYTES) as u64;
        assert!(
            writes.syscalls <= bound,
            "frame_len {frame_len}: {} writes for {} bytes (at most {bound})",
            writes.syscalls,
            expected.len()
        );
        assert!(writes.syscalls_per_message < 0.2, "{}", writes.syscalls_per_message);
    }
}

/// Takes at most `limit` bytes a call and refuses every third call as
/// interrupted, as a socket under a signal and a full buffer would.
struct ShortWriter {
    bytes: Vec<u8>,
    limit: usize,
    calls: usize,
}

impl Write for ShortWriter {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.write_vectored(&[IoSlice::new(buf)])
    }

    fn write_vectored(&mut self, bufs: &[IoSlice<'_>]) -> io::Result<usize> {
        self.calls += 1;
        if self.calls.is_multiple_of(3) {
            return Err(ErrorKind::Interrupted.into());
        }
        let mut room = self.limit;
        for buf in bufs {
            let take = buf.len().min(room);
            self.bytes.extend_from_slice(&buf[..take]);
            room -= take;
            if room == 0 {
                break;
            }
        }
        Ok(self.limit - room)
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[test]
fn outbound_batch_short_and_interrupted_writes_keep_every_byte_of_chunked_frames() {
    let service = RenderService::new();
    let (single, batched) = (BoundedOutbound::default(), BoundedOutbound::default());
    for outbound in [&single, &batched] {
        let snapshot = stream_on(&service, 4, StreamLane::Bulk);
        let len = 100_000;
        let header = FrameHeader::new(FrameKind::Snapshot, 4, len as u32, Aux::Offset(9)).unwrap();
        outbound.push_stream_frame(header, payload(&service, len), &snapshot).unwrap();
        queue_mixed(&service, outbound, 40, 3_000);
    }
    let expected = written_one_by_one(&single);

    let mut writer = ShortWriter { bytes: Vec::new(), limit: 777, calls: 0 };
    write_batches(&batched, &mut writer, &IpcStats::default());

    assert_eq!(writer.bytes, expected);
}

/// Records how many bytes had been written at each flush.
#[derive(Default)]
struct FlushRecorder {
    bytes: Vec<u8>,
    flushed_at: Vec<usize>,
}

impl Write for FlushRecorder {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.bytes.extend_from_slice(buf);
        Ok(buf.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        self.flushed_at.push(self.bytes.len());
        Ok(())
    }
}

#[test]
fn outbound_batch_flush_ends_its_batch_after_the_bytes_before_it() {
    let service = RenderService::new();
    let outbound = BoundedOutbound::default();
    let first = service.serialize_control(&json!({"id": 1, "ok": true})).unwrap();
    let second = service.serialize_control(&json!({"id": 2, "ok": true})).unwrap();
    let (flushed_tx, flushed_rx) = std::sync::mpsc::sync_channel(1);
    outbound.push_control(first.clone()).unwrap();
    outbound.state.lock().unwrap().enqueue_control(ControlOutbound::Flush(flushed_tx));
    outbound.push_control(second.clone()).unwrap();

    let mut batch = Vec::new();
    assert!(outbound.recv_batch(&mut batch));
    assert_eq!(batch.len(), 2, "the flush ends the batch");
    let mut writer = FlushRecorder::default();
    write_line_outbound_batch(&mut writer, &batch).unwrap();
    assert_eq!(writer.flushed_at, [first.len() + 1]);
    flushed_rx.try_recv().expect("the flush is answered once its bytes are written");

    assert!(outbound.recv_batch(&mut batch));
    assert_eq!(batch.len(), 1);
    write_line_outbound_batch(&mut writer, &batch).unwrap();
    assert_eq!(writer.bytes.len(), first.len() + second.len() + 2);
}

#[test]
fn outbound_batch_stops_at_its_item_and_byte_bounds() {
    let service = RenderService::new();
    let outbound = BoundedOutbound::default();
    let streams = (1..=3).map(|id| stream_on(&service, id, StreamLane::Bulk)).collect::<Vec<_>>();
    for _ in 0..200 {
        for stream in &streams {
            outbound.push_regular(payload(&service, 8), stream).unwrap();
        }
    }
    let mut batch = Vec::new();
    assert!(outbound.recv_batch(&mut batch));
    assert_eq!(batch.len(), WRITE_BATCH_ITEMS);
    assert!(outbound.recv_batch(&mut batch));
    assert_eq!(batch.len(), 600 - WRITE_BATCH_ITEMS);

    let big = stream_on(&service, 9, StreamLane::Bulk);
    for _ in 0..12 {
        let header = FrameHeader::new(FrameKind::Output, 9, 30_000, Aux::Offset(0)).unwrap();
        outbound.push_stream_frame(header, payload(&service, 30_000), &big).unwrap();
    }
    assert!(outbound.recv_batch(&mut batch));
    let bytes = batch.iter().map(OutboundItem::wire_len).sum::<usize>();
    assert!(bytes >= WRITE_BATCH_BYTES, "{bytes}");
    let last = batch.last().map_or(0, OutboundItem::wire_len);
    assert!(bytes - last < WRITE_BATCH_BYTES, "the batch took an item past its bound");
}

#[test]
fn outbound_batch_ping_reply_waits_at_most_one_chunk_of_a_32_mib_snapshot() {
    let service = RenderService::new();
    let outbound = BoundedOutbound::default();
    let snapshot = stream_on(&service, 1, StreamLane::Bulk);
    let len = MAX_FRAME_PAYLOAD as usize;
    let header = FrameHeader::new(FrameKind::Snapshot, 3, len as u32, Aux::Offset(77)).unwrap();
    outbound.push_stream_frame(header, payload(&service, len), &snapshot).unwrap();

    let mut batch = Vec::new();
    assert!(outbound.recv_batch(&mut batch));
    assert!(
        matches!(batch.as_slice(), [OutboundItem::Chunk { range, .. }] if range.len() == BULK_FRAME_MAX),
        "the first batch took more than one chunk of the snapshot"
    );
    let ping = service.serialize_control(&json!({"id": 9, "ok": true})).unwrap();
    outbound.push_control(ping).unwrap();

    assert!(outbound.recv_batch(&mut batch));
    assert!(
        matches!(batch.first(), Some(OutboundItem::Text(text)) if text.contains("\"id\":9")),
        "the ping reply waited for more than one chunk"
    );
    let chunks = batch.iter().filter(|item| matches!(item, OutboundItem::Chunk { .. })).count();
    assert!(chunks <= 1, "{chunks} chunks in one batch");
}

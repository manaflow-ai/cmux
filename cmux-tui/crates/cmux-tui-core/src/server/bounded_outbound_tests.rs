//! Lane order and frame chunking of the bounded outbound queue:
//! a reply waits for at most one chunk of a queued snapshot, the pop order is
//! `cmux_ipc::LaneWriter`'s, and the frame cut comes from the environment.

use super::super::cmd_server::IdentifyParams;
use super::lanes::{BULK_FRAME_MIN, parse_bulk_frame_max};
use super::*;
use crate::server::{MessageWriter, RenderService};
use cmux_ipc::lane_writer::{BULK_FRAME_MAX, STARVATION_BOUND};
use cmux_ipc::{
    Aux, CallAux, CallFlags, Frame, FrameKind, LaneWriter, LaneWriterConfig, MAX_FRAME_PAYLOAD,
    PriorityHint, StreamLane,
};
use serde_json::json;
use std::io::Read;

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

fn reply(service: &RenderService, id: u64) -> Arc<BudgetedText> {
    service.serialize_control(&json!({"id": id, "ok": true})).unwrap()
}

/// What a popped item is: stream 0 for a line or a control frame, then the
/// header's kind, payload length and aux.
#[derive(Debug, PartialEq, Eq)]
struct Written {
    stream: u16,
    kind: Option<FrameKind>,
    len: usize,
    aux: Option<Aux>,
}

fn written(item: OutboundItem) -> Written {
    match item {
        OutboundItem::Text(text) => Written { stream: 0, kind: None, len: text.len(), aux: None },
        OutboundItem::Frame(header, _) | OutboundItem::Chunk { header, .. } => Written {
            stream: header.stream(),
            kind: Some(header.kind()),
            len: header.len() as usize,
            aux: Some(header.aux()),
        },
        OutboundItem::Flush(_) => panic!("no flush was queued"),
    }
}

fn pop(outbound: &BoundedOutbound) -> Option<OutboundItem> {
    outbound.state.lock().unwrap().pop()
}

const SNAPSHOT_BYTES: usize = MAX_FRAME_PAYLOAD as usize;

/// p02-threads 308: a connection's writer (`mux-line-out`, an echo thread
/// with blocking disallowed) waits for its next item at the top of its loop.
/// That wait is the thread being idle, not a blocking call (Chromium's
/// `WaitableEvent::declare_only_used_while_idle`): in the detector's panic
/// mode the writer takes an item queued after it began to wait, then sees
/// the close, and nothing panics.
#[test]
fn the_writer_waits_for_its_next_item_on_an_echo_thread_without_a_violation() {
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = {
        let outbound = outbound.clone();
        crate::echo_thread::spawn("outbound-idle-test", move || {
            cmux_threads::blocking::with_mode(cmux_threads::BlockingMode::Panic, || {
                let first = outbound.recv().map(written);
                (first, outbound.recv().is_none())
            })
        })
        .unwrap()
    };
    // The queue is empty: the writer reaches its wait before the push.
    std::thread::sleep(Duration::from_millis(100));
    let service = RenderService::new();
    let text = reply(&service, 1);
    let len = text.len();
    outbound.push_control(text).unwrap();
    std::thread::sleep(Duration::from_millis(50));
    outbound.close();
    let (first, closed) = writer.join().expect("the writer's idle wait is not a violation");
    assert_eq!(first, Some(Written { stream: 0, kind: None, len, aux: None }));
    assert!(closed, "the writer sees the close after the last item");
}

#[test]
fn bounded_outbound_ping_reply_waits_at_most_one_chunk_of_a_32_mib_snapshot() {
    let service = RenderService::new();
    let outbound = BoundedOutbound::default();
    let stream = stream_on(&service, 1, StreamLane::Bulk);
    let header =
        FrameHeader::new(FrameKind::Snapshot, 3, SNAPSHOT_BYTES as u32, Aux::Offset(77)).unwrap();
    outbound.push_stream_frame(header, payload(&service, SNAPSHOT_BYTES), &stream).unwrap();

    let first = written(pop(&outbound).unwrap());
    assert_eq!(first.kind, Some(FrameKind::Snapshot));
    assert_eq!(first.len, BULK_FRAME_MAX);
    outbound.push_control(reply(&service, 9)).unwrap();
    let next = pop(&outbound).unwrap();
    assert!(
        matches!(&next, OutboundItem::Text(text) if text.contains("\"id\":9")),
        "the ping reply waited for more than one chunk"
    );

    let mut total = first.len;
    let mut chunks = 1;
    while let Some(item) = pop(&outbound) {
        let chunk = written(item);
        assert_eq!(chunk.stream, 3);
        assert_eq!(chunk.kind, Some(FrameKind::SnapshotMore));
        assert_eq!(chunk.aux, Some(Aux::Offset(77)));
        assert!(chunk.len <= BULK_FRAME_MAX);
        total += chunk.len;
        chunks += 1;
    }
    assert_eq!(total, SNAPSHOT_BYTES);
    assert_eq!(chunks, SNAPSHOT_BYTES.div_ceil(BULK_FRAME_MAX));
    let state = outbound.state.lock().unwrap();
    assert!(state.stream_usage.is_empty(), "the snapshot's budget was released");
    assert_eq!(state.regular_bytes, 0);
}

#[test]
fn bounded_outbound_chunks_follow_the_lane_writer_rules() {
    let service = RenderService::new();
    let outbound = BoundedOutbound::with_chunk_bytes(BULK_FRAME_MIN);
    let output = stream_on(&service, 1, StreamLane::Bulk);
    let len = BULK_FRAME_MIN * 2 + 10;
    let header = FrameHeader::new(FrameKind::Output, 5, len as u32, Aux::Offset(1_000)).unwrap();
    outbound.push_stream_frame(header, payload(&service, len), &output).unwrap();
    let offsets = (0..3)
        .map(|_| written(pop(&outbound).unwrap()))
        .map(|chunk| (chunk.aux, chunk.len))
        .collect::<Vec<_>>();
    let start = |offset: usize| Some(Aux::Offset(1_000 + offset as u64));
    assert_eq!(
        offsets,
        [
            (start(0), BULK_FRAME_MIN),
            (start(BULK_FRAME_MIN), BULK_FRAME_MIN),
            (start(2 * BULK_FRAME_MIN), 10)
        ]
    );

    let call = CallAux {
        request_id: 4,
        method_id: 0x0101,
        priority: PriorityHint::Bulk,
        flags: CallFlags::FDS,
    };
    let typed = FrameHeader::new(FrameKind::TypedEvent, 5, len as u32, Aux::Call(call)).unwrap();
    outbound.push_stream_frame(typed, payload(&service, len), &output).unwrap();
    let flags = (0..3)
        .map(|_| match written(pop(&outbound).unwrap()).aux {
            Some(Aux::Call(call)) => call.flags,
            other => panic!("not a call aux: {other:?}"),
        })
        .collect::<Vec<_>>();
    assert_eq!(flags, [CallFlags::FDS.with(CallFlags::MORE), CallFlags::MORE, CallFlags::empty()]);

    let grid = FrameHeader::new(FrameKind::Grid, 5, len as u32, Aux::Offset(0)).unwrap();
    outbound.push_stream_frame(grid, payload(&service, len), &output).unwrap();
    assert_eq!(written(pop(&outbound).unwrap()).len, len, "GRID is written whole");
    assert!(pop(&outbound).is_none());
}

#[test]
fn bounded_outbound_input_lane_passes_control_and_bulk_gets_its_grant() {
    let service = RenderService::new();
    let outbound = BoundedOutbound::default();
    let input = stream_on(&service, 1, StreamLane::Input);
    let bulk = stream_on(&service, 2, StreamLane::Bulk);
    for id in 0..20 {
        outbound.push_control(reply(&service, id)).unwrap();
    }
    outbound.push_regular(payload(&service, 10), &bulk).unwrap();
    outbound.push_regular(payload(&service, 12), &input).unwrap();

    let order = std::iter::from_fn(|| pop(&outbound)).map(written).collect::<Vec<_>>();
    assert_eq!(order[0].len, 12, "the input item went first");
    let bulk_at = order.iter().position(|item| item.len == 10).unwrap();
    // Bulk waits STARVATION_BOUND higher items (the input item and control
    // replies), then gets its grant.
    assert_eq!(bulk_at, STARVATION_BOUND as usize);
    assert_eq!(order.len(), 22);
}

/// A step of the equivalence workload.
enum Step {
    Control,
    Stream { stream: u16, len: usize },
    Pop,
}

/// xorshift64: a fixed workload without a randomness dependency.
fn workload(seed: u64, steps: usize) -> Vec<Step> {
    let mut state = seed;
    let mut next = move || {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        state
    };
    (0..steps)
        .map(|_| match next() % 10 {
            0 => Step::Control,
            1..=3 => {
                let stream = (next() % 6 + 1) as u16;
                let len = if next() % 3 == 0 { 2 + (next() % 20_000) as usize } else { 40 };
                Step::Stream { stream, len }
            }
            _ => Step::Pop,
        })
        .collect()
}

fn lane_of(stream: u16) -> StreamLane {
    match stream % 3 {
        0 => StreamLane::Input,
        1 => StreamLane::Bulk,
        _ => StreamLane::Background,
    }
}

#[test]
fn bounded_outbound_pop_order_is_the_lane_writers() {
    let chunk_bytes = BULK_FRAME_MIN;
    let service = RenderService::new();
    for seed in [1_u64, 7, 0x9e37_79b9, 0xdead_beef] {
        let outbound = BoundedOutbound::with_chunk_bytes(chunk_bytes);
        let mut lanes = LaneWriter::new(LaneWriterConfig {
            chunk_bytes,
            max_queued_bytes: usize::MAX / 4,
            ..LaneWriterConfig::default()
        });
        let streams = (1..=6_u16)
            .map(|id| {
                lanes.open_stream(id, lane_of(id)).unwrap();
                stream_on(&service, u64::from(id), lane_of(id))
            })
            .collect::<Vec<_>>();
        let (mut ours, mut theirs) = (Vec::new(), Vec::new());
        let mut take = |outbound: &BoundedOutbound, lanes: &mut LaneWriter| {
            let popped = pop(outbound).map(written);
            let done = popped.is_none();
            ours.push(popped);
            theirs.push(lanes.pop().map(|frame| Written {
                stream: frame.header().stream(),
                kind: (frame.header().stream() != 0).then(|| frame.header().kind()),
                len: frame.payload().len(),
                aux: (frame.header().stream() != 0).then(|| frame.header().aux()),
            }));
            done
        };
        for step in workload(seed, 3_000) {
            match step {
                Step::Control => {
                    let text = reply(&service, 1);
                    let call = CallAux {
                        request_id: 1,
                        method_id: 0x0101,
                        priority: PriorityHint::Control,
                        flags: CallFlags::empty(),
                    };
                    let bytes = text.as_bytes().to_vec().into();
                    let frame = Frame::new(FrameKind::Reply, 0, Aux::Call(call), bytes).unwrap();
                    outbound.push_control(text).unwrap();
                    lanes.push_control(frame).unwrap();
                }
                Step::Stream { stream, len } => {
                    let aux = Aux::Offset(len as u64);
                    let header = FrameHeader::new(FrameKind::Output, stream, len as u32, aux);
                    let owner = &streams[usize::from(stream) - 1];
                    outbound
                        .push_stream_frame(header.unwrap(), payload(&service, len), owner)
                        .unwrap();
                    let frame = Frame::new(FrameKind::Output, stream, aux, vec![b'x'; len].into());
                    lanes.push_stream(frame.unwrap()).unwrap();
                }
                Step::Pop => {
                    take(&outbound, &mut lanes);
                }
            }
        }
        while !take(&outbound, &mut lanes) {}
        assert_eq!(ours, theirs, "seed {seed}");
    }
}

#[test]
fn bounded_outbound_overflow_drops_the_unsent_chunks_of_its_stream() {
    let service = RenderService::new();
    let outbound = BoundedOutbound::default();
    let stream = stream_on(&service, 1, StreamLane::Bulk);
    let header =
        FrameHeader::new(FrameKind::Snapshot, 3, SNAPSHOT_BYTES as u32, Aux::Offset(0)).unwrap();
    outbound.push_stream_frame(header, payload(&service, SNAPSHOT_BYTES), &stream).unwrap();
    assert!(matches!(pop(&outbound), Some(OutboundItem::Chunk { .. })));

    outbound.push_terminal(reply(&service, 5), &stream).unwrap();
    assert!(matches!(pop(&outbound), Some(OutboundItem::Text(text)) if text.contains("\"id\":5")));
    assert!(pop(&outbound).is_none(), "the rest of the snapshot was dropped");
    let state = outbound.state.lock().unwrap();
    assert_eq!((state.regular_bytes, state.stream_items), (0, 0));
}

#[test]
fn bounded_outbound_stream_frames_need_a_matching_length_and_a_unix_sink() {
    let service = RenderService::new();
    let outbound = Arc::new(BoundedOutbound::default());
    let stream = stream_on(&service, 1, StreamLane::Bulk);
    let header = FrameHeader::new(FrameKind::Output, 2, 99, Aux::Offset(0)).unwrap();
    let error = outbound.push_stream_frame(header, payload(&service, 50), &stream).unwrap_err();
    assert_eq!(error.kind(), std::io::ErrorKind::InvalidData);

    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let header = FrameHeader::new(FrameKind::Output, 2, 50, Aux::Offset(0)).unwrap();
    let error = writer.send_stream_frame(header, payload(&service, 50), &stream).unwrap_err();
    assert_eq!(error.kind(), std::io::ErrorKind::Unsupported);
    assert!(pop(&outbound).is_none());
}

#[test]
fn bounded_outbound_frame_cut_comes_from_the_environment_value() {
    assert_eq!(parse_bulk_frame_max(None), BULK_FRAME_MAX);
    assert_eq!(parse_bulk_frame_max(Some("16384")), 16 * 1024);
    assert_eq!(parse_bulk_frame_max(Some(" 65536 ")), 64 * 1024);
    assert_eq!(parse_bulk_frame_max(Some("100")), BULK_FRAME_MAX, "below BULK_FRAME_MIN");
    assert_eq!(parse_bulk_frame_max(Some("68719476736")), BULK_FRAME_MAX, "above a frame");
    assert_eq!(parse_bulk_frame_max(Some("32k")), BULK_FRAME_MAX);
}

/// The bench reads the cut from identify: only with `revisions`, so the
/// default reply keeps its frozen shape (machine_identity_reader_tests.rs).
#[test]
fn bounded_outbound_identify_reports_the_frame_cut_with_revisions() {
    let mux = crate::Mux::new_for_test("bulk-frame-max-identify", crate::SurfaceOptions::default());
    let client = mux.local_test_client(0);
    let identify = |revisions| {
        let params = IdentifyParams { revisions, ..IdentifyParams::default() };
        super::super::cmd_server::identify(&mux, client, params)
    };
    assert!(identify(false).unwrap().get("bulk_frame_max").is_none());
    assert_eq!(identify(true).unwrap()["bulk_frame_max"], json!(mux.bulk_frame_max()));
    mux.shutdown();
}

/// IdentifyResult is closed (`additional_properties: false`), so a strict
/// generated decoder refuses a reply key the schema does not declare.
#[test]
fn bounded_outbound_identify_revisions_reply_keys_are_in_the_schema() {
    let schema: serde_json::Value =
        serde_json::from_str(include_str!("../../../../spec/sdk-schema.json")).unwrap();
    let declared = schema["types"]["IdentifyResult"]["fields"].as_object().unwrap();
    assert_eq!(declared["bulk_frame_max"]["type"]["name"], "uint32");
    let mux = crate::Mux::new_for_test("bulk-frame-max-schema", crate::SurfaceOptions::default());
    let client = mux.local_test_client(0);
    let params = IdentifyParams { revisions: true, ..IdentifyParams::default() };
    let reply = super::super::cmd_server::identify(&mux, client, params).unwrap();
    let undeclared: Vec<&String> =
        reply.as_object().unwrap().keys().filter(|key| !declared.contains_key(*key)).collect();
    assert!(undeclared.is_empty(), "identify keys missing from IdentifyResult: {undeclared:?}");
    mux.shutdown();
}

/// The 16/32/64 KiB measurement behind BULK_FRAME_MAX: over a Unix socket
/// pair whose reader drains at full speed, the delay from queueing a ping
/// reply behind a 32 MiB snapshot that started writing to reading it, and
/// the snapshot's throughput. Run with
/// `cargo test -p cmux-tui-core --lib bounded_outbound_frame_cut_bench -- --ignored --nocapture`.
#[cfg(unix)]
#[test]
#[ignore = "measurement; run by hand"]
fn bounded_outbound_frame_cut_bench() {
    for chunk in [16 * 1024, 32 * 1024, 64 * 1024] {
        let (delays, mib_per_s) = frame_cut_run(chunk, 100);
        let pick = |q: f64| delays[((delays.len() - 1) as f64 * q) as usize];
        println!(
            "BULK_FRAME_MAX {} KiB: ping wait p50 {:.3} ms p99 {:.3} ms max {:.3} ms; snapshot {mib_per_s:.0} MiB/s",
            chunk / 1024,
            pick(0.5),
            pick(0.99),
            pick(1.0),
        );
    }
}

/// What the bench's reader saw.
#[cfg(unix)]
enum Seen {
    Frame(FrameKind),
    Line,
}

/// `rounds` snapshots through a writer thread like line_connection.rs's;
/// returns the sorted ping waits in ms and the snapshot MiB/s.
#[cfg(unix)]
fn frame_cut_run(chunk: usize, rounds: usize) -> (Vec<f64>, f64) {
    use std::io::BufRead;
    use std::io::BufReader;
    use std::os::unix::net::UnixStream;
    use std::time::Instant;
    let (mut write_half, read_half) = UnixStream::pair().unwrap();
    let outbound = Arc::new(BoundedOutbound::with_chunk_bytes(chunk));
    let writer_outbound = outbound.clone();
    let writer = std::thread::spawn(move || {
        while let Some(item) = writer_outbound.recv() {
            write_line_outbound_item(&mut write_half, item).unwrap();
        }
    });
    let (seen_tx, seen_rx) = std::sync::mpsc::channel::<(Seen, Instant)>();
    let reader = std::thread::spawn(move || {
        let mut read = BufReader::with_capacity(1 << 20, read_half);
        let mut head = [0_u8; cmux_ipc::HEADER_LEN];
        while read.read_exact(&mut head[..1]).is_ok() {
            let seen = if head[0] == cmux_ipc::MAGIC {
                read.read_exact(&mut head[1..]).unwrap();
                let header = FrameHeader::decode(head, MAX_FRAME_PAYLOAD).unwrap();
                let mut body = (&mut read).take(u64::from(header.len()));
                std::io::copy(&mut body, &mut std::io::sink()).unwrap();
                Seen::Frame(header.kind())
            } else {
                read.read_until(b'\n', &mut Vec::new()).unwrap();
                Seen::Line
            };
            let _ = seen_tx.send((seen, Instant::now()));
        }
    });
    let service = RenderService::new();
    let stream = stream_on(&service, 1, StreamLane::Bulk);
    let header =
        FrameHeader::new(FrameKind::Snapshot, 3, SNAPSHOT_BYTES as u32, Aux::Offset(0)).unwrap();
    let chunks = SNAPSHOT_BYTES.div_ceil(chunk);
    let (mut delays, mut elapsed) = (Vec::new(), 0.0);
    for _ in 0..rounds {
        let started = Instant::now();
        outbound.push_stream_frame(header, payload(&service, SNAPSHOT_BYTES), &stream).unwrap();
        while !matches!(seen_rx.recv().unwrap().0, Seen::Frame(FrameKind::Snapshot)) {}
        let queued = Instant::now();
        outbound.push_control(reply(&service, 1)).unwrap();
        let (mut frames, mut reply_at) = (1, None);
        while frames < chunks || reply_at.is_none() {
            match seen_rx.recv().unwrap() {
                (Seen::Line, at) => reply_at = Some(at),
                (Seen::Frame(_), _) => frames += 1,
            }
        }
        delays.push(reply_at.unwrap().duration_since(queued).as_secs_f64() * 1e3);
        elapsed += started.elapsed().as_secs_f64();
    }
    outbound.close();
    writer.join().unwrap();
    reader.join().unwrap();
    delays.sort_by(f64::total_cmp);
    (delays, (rounds * SNAPSHOT_BYTES) as f64 / (1 << 20) as f64 / elapsed)
}

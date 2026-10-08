//! The per-stream viewer session through the C ABI (rd change C6): datagrams
//! routed by the header's stream to one reassembler each, feedback and
//! keyframe requests per stream, only opened streams accepted.

use super::*;
use cmux_rd_core::packetize::Packetizer;
use cmux_rd_proto::{
    DatagramHeader, DatagramKind, Feedback, FrameBody, MAX_DATAGRAM_VPC, REF_NONE, STREAM_DATAGRAM,
    StreamDeframer, encode_stream_frame, flags,
};

struct Owned(*mut CmuxRdSession);
impl Drop for Owned {
    fn drop(&mut self) {
        // SAFETY: created by cmux_rd_session_new and freed once here.
        unsafe { cmux_rd_session_free(self.0) };
    }
}

fn session(carrier: u32) -> Owned {
    let s = cmux_rd_session_new(carrier, 200_000, 5_000);
    assert!(!s.is_null());
    Owned(s)
}

/// Datagrams of frames 1..=n on `stream` (frame 1 a keyframe); the access
/// unit bytes name the stream so mixing is visible.
fn frames(stream: u16, n: u32, len: usize) -> Vec<Vec<u8>> {
    let mut p = Packetizer::new(stream, MAX_DATAGRAM_VPC);
    (1..=n)
        .flat_map(|f| {
            let body = FrameBody {
                t_capture_us: u64::from(f),
                ref_frame: if f == 1 { REF_NONE } else { f - 1 },
                access_unit: vec![stream as u8; len],
            };
            let fl = if f == 1 { flags::KEYFRAME } else { 0 };
            p.packetize(f, fl, &body, 0).expect("packetize").datagrams
        })
        .collect()
}

fn push(s: &Owned, d: &[u8], now: u64) -> i32 {
    // SAFETY: live session, readable slice.
    unsafe { cmux_rd_session_push_datagram(s.0, d.as_ptr(), d.len(), now) }
}

fn open(s: &Owned, stream: u16) -> i32 {
    // SAFETY: live session.
    unsafe { cmux_rd_session_open_stream(s.0, stream) }
}

fn pop_all(s: &Owned) -> Vec<(u16, u32, Vec<u8>)> {
    let mut out = Vec::new();
    loop {
        let mut f = CmuxRdFrame {
            t_capture_us: 0,
            data: std::ptr::null(),
            len: 0,
            frame: 0,
            ref_frame: 0,
            flags: 0,
        };
        let mut stream = u16::MAX;
        // SAFETY: live session, writable outs.
        match unsafe { cmux_rd_session_pop_frame(s.0, &mut f, &mut stream) } {
            0 => return out,
            1 => {
                // SAFETY: data is valid for len bytes until the next call.
                let bytes = unsafe { std::slice::from_raw_parts(f.data, f.len) }.to_vec();
                out.push((stream, f.frame, bytes));
            }
            code => panic!("pop_frame returned {code}"),
        }
    }
}

/// Every feedback due at `now`, as (stream, feedback).
fn feedbacks(s: &Owned, now: u64, stream_carrier: bool) -> Vec<(u16, Feedback)> {
    let mut out = Vec::new();
    loop {
        let mut buf = vec![0u8; 2048];
        let mut len = 0usize;
        // SAFETY: live session, writable buffer and length.
        let rc =
            unsafe { cmux_rd_session_feedback(s.0, now, buf.as_mut_ptr(), buf.len(), &mut len) };
        match rc {
            0 => return out,
            1 => {
                let mut datagram = buf[..len].to_vec();
                if stream_carrier {
                    let mut d = StreamDeframer::default();
                    d.extend(&datagram);
                    let (kind, payload) = d.next_frame().expect("frame").expect("whole");
                    assert_eq!(kind, STREAM_DATAGRAM);
                    datagram = payload;
                }
                let (h, payload) = DatagramHeader::decode(&datagram).expect("header");
                assert_eq!(h.kind, DatagramKind::Feedback);
                out.push((h.stream, Feedback::decode(payload).expect("feedback")));
            }
            code => panic!("feedback returned {code}"),
        }
    }
}

#[test]
fn two_streams_reassemble_independently() {
    let s = session(CMUX_RD_CARRIER_DATAGRAM);
    assert_eq!(open(&s, 1), CMUX_RD_OK);
    let a = frames(0, 3, 2500);
    let b = frames(1, 3, 1800);
    // Interleave the streams' datagrams: same frame numbers on both.
    let mut now = 0;
    for d in a.iter().zip(&b).flat_map(|(x, y)| [x, y]).chain(a.iter().skip(b.len())) {
        assert!(push(&s, d, now) >= 0);
        now += 10;
    }
    let got = pop_all(&s);
    assert_eq!(got.len(), 6);
    for stream in [0u16, 1] {
        let frames: Vec<u32> = got.iter().filter(|g| g.0 == stream).map(|g| g.1).collect();
        assert_eq!(frames, vec![1, 2, 3], "stream {stream}");
    }
    for (stream, _, bytes) in &got {
        assert!(
            bytes.iter().all(|b| *b == *stream as u8),
            "stream {stream} got another stream's bytes"
        );
    }
    // One feedback per stream, each naming its stream and its newest frame.
    let fb = feedbacks(&s, now, false);
    assert_eq!(fb.iter().map(|f| (f.0, f.1.acked_frame)).collect::<Vec<_>>(), vec![(0, 3), (1, 3)]);
}

#[test]
fn only_opened_streams_are_accepted_and_the_count_is_bounded() {
    let s = session(CMUX_RD_CARRIER_DATAGRAM);
    let other = frames(2, 1, 100);
    assert_eq!(push(&s, &other[0], 0), CMUX_RD_ERR_STREAM);
    assert!(pop_all(&s).is_empty());
    // Opening is idempotent; stream 0 is open from the start.
    assert_eq!(open(&s, 0), CMUX_RD_OK);
    for stream in 1..CMUX_RD_SESSION_MAX_STREAMS as u16 {
        assert_eq!(open(&s, stream), CMUX_RD_OK);
    }
    assert_eq!(open(&s, 999), CMUX_RD_ERR_STREAM);
    // SAFETY: live session.
    assert_eq!(unsafe { cmux_rd_session_close_stream(s.0, 5) }, CMUX_RD_OK);
    assert_eq!(open(&s, 999), CMUX_RD_OK);
    // SAFETY: live session; stream 5 is closed now.
    assert_eq!(unsafe { cmux_rd_session_note_decode(s.0, 5, 100) }, CMUX_RD_ERR_STREAM);
}

#[test]
fn a_keyframe_request_rides_only_its_streams_feedback() {
    let s = session(CMUX_RD_CARRIER_DATAGRAM);
    open(&s, 3);
    for d in frames(0, 1, 100).iter().chain(&frames(3, 1, 100)) {
        push(&s, d, 0);
    }
    pop_all(&s);
    feedbacks(&s, 0, false);
    // SAFETY: live session.
    assert_eq!(unsafe { cmux_rd_session_request_keyframe(s.0, 3) }, CMUX_RD_OK);
    let fb = feedbacks(&s, 60_000, false);
    let by_stream: Vec<(u16, bool)> = fb.iter().map(|f| (f.0, f.1.need_recovery)).collect();
    assert!(by_stream.contains(&(3, true)));
    assert!(!by_stream.contains(&(0, true)));
    let mut stats = CmuxRdStats::default();
    // SAFETY: live session, writable out.
    assert_eq!(unsafe { cmux_rd_session_stats(s.0, 3, &mut stats) }, CMUX_RD_OK);
    assert!(stats.need_recovery);
    // SAFETY: as above.
    assert_eq!(unsafe { cmux_rd_session_stats(s.0, 0, &mut stats) }, CMUX_RD_OK);
    assert!(!stats.need_recovery);
}

#[test]
fn stream_carrier_routes_frames_and_queues_other_messages() {
    let s = session(CMUX_RD_CARRIER_STREAM);
    open(&s, 1);
    let mut bytes = Vec::new();
    let control = br#"{"t":"welcome"}"#;
    encode_stream_frame(1, control, &mut bytes).expect("frame");
    for d in frames(1, 2, 3000).iter().chain(&frames(0, 1, 500)) {
        encode_stream_frame(STREAM_DATAGRAM, d, &mut bytes).expect("frame");
    }
    // An InputAck datagram is a message, not a frame.
    let mut ack = Vec::new();
    DatagramHeader {
        flags: 0,
        kind: DatagramKind::InputAck,
        stream: 0,
        frame: 0,
        index: 0,
        count: 0,
        fec_count: 0,
        transport_seq: 0,
    }
    .encode_into(&mut ack);
    ack.extend_from_slice(&1u32.to_le_bytes());
    encode_stream_frame(STREAM_DATAGRAM, &ack, &mut bytes).expect("frame");
    // Arbitrary chunking.
    for chunk in bytes.chunks(777) {
        // SAFETY: live session, readable slice.
        let rc = unsafe { cmux_rd_session_push_stream(s.0, chunk.as_ptr(), chunk.len(), 0) };
        assert!(rc >= 0, "push_stream {rc}");
    }
    let got = pop_all(&s);
    assert_eq!(got.iter().map(|g| (g.0, g.1)).collect::<Vec<_>>(), vec![(1, 1), (1, 2), (0, 1)]);
    let mut kinds = Vec::new();
    loop {
        let mut m = CmuxRdMessage { data: std::ptr::null(), len: 0, kind: 0 };
        // SAFETY: live session, writable out.
        if unsafe { cmux_rd_session_pop_message(s.0, &mut m) } != 1 {
            break;
        }
        kinds.push(m.kind);
    }
    assert_eq!(kinds, vec![1, STREAM_DATAGRAM]);
    let fb = feedbacks(&s, 0, true);
    assert_eq!(fb.iter().map(|f| f.0).collect::<Vec<_>>(), vec![0, 1]);
    // The datagram call refuses on the stream carrier.
    assert_eq!(push(&s, &frames(0, 1, 10)[0], 0), CMUX_RD_ERR_CARRIER);
}

#[test]
fn closing_a_stream_drops_its_frames_and_its_timer() {
    let s = session(CMUX_RD_CARRIER_DATAGRAM);
    open(&s, 1);
    for d in frames(1, 2, 400) {
        push(&s, &d, 0);
    }
    // SAFETY: live session.
    assert_eq!(unsafe { cmux_rd_session_close_stream(s.0, 1) }, CMUX_RD_OK);
    assert!(pop_all(&s).is_empty());
    // SAFETY: live session.
    assert_eq!(unsafe { cmux_rd_session_close_stream(s.0, 1) }, CMUX_RD_ERR_STREAM);
    // SAFETY: NULL is refused.
    assert_eq!(unsafe { cmux_rd_session_next_deadline_us(std::ptr::null()) }, u64::MAX);
}

#[test]
fn the_session_clock_pings_and_estimates_once_enabled() {
    let s = session(CMUX_RD_CARRIER_DATAGRAM);
    // Not enabled: no ping (an older host refuses the kind).
    assert!(feedbacks_raw(&s, 0).iter().all(|d| d[1] != DatagramKind::ClockPing as u8));
    // SAFETY: live session.
    assert_eq!(unsafe { cmux_rd_session_enable_clock(s.0) }, CMUX_RD_OK);
    let sent = feedbacks_raw(&s, 1_000);
    let ping_bytes = sent.iter().find(|d| d[1] == DatagramKind::ClockPing as u8).expect("a ping");
    let (_, payload) = DatagramHeader::decode(ping_bytes).expect("header");
    let ping = cmux_rd_proto::ClockPing::decode(payload).expect("ping");
    // The host clock is 5 ms ahead; 2 ms each way.
    let rx = ping.t_viewer_us + 2_000 + 5_000;
    let pong = cmux_rd_proto::ClockPong {
        seq: ping.seq,
        t_viewer_us: ping.t_viewer_us,
        t_host_rx_us: rx,
        t_host_tx_us: rx,
    };
    let mut d = DatagramHeader {
        flags: 0,
        kind: DatagramKind::ClockPong,
        stream: 0,
        frame: 0,
        index: 0,
        count: 0,
        fec_count: 0,
        transport_seq: 0,
    }
    .encode()
    .to_vec();
    d.extend_from_slice(&pong.encode());
    assert!(push(&s, &d, ping.t_viewer_us + 4_000) >= 0);
    let (mut offset, mut rtt) = (0i64, 0u32);
    // SAFETY: live session, writable outs.
    assert_eq!(unsafe { cmux_rd_session_clock(s.0, &mut offset, &mut rtt) }, 1);
    assert_eq!((offset, rtt), (5_000, 4_000));
    // The pong is consumed, not queued as a message.
    let mut m = CmuxRdMessage { data: std::ptr::null(), len: 0, kind: 0 };
    // SAFETY: live session, writable out.
    assert_eq!(unsafe { cmux_rd_session_pop_message(s.0, &mut m) }, 0);
}

/// Every datagram the feedback call writes at `now` (datagram carrier).
fn feedbacks_raw(s: &Owned, now: u64) -> Vec<Vec<u8>> {
    let mut out = Vec::new();
    loop {
        let mut buf = vec![0u8; 2048];
        let mut len = 0usize;
        // SAFETY: live session, writable buffer and length.
        match unsafe { cmux_rd_session_feedback(s.0, now, buf.as_mut_ptr(), buf.len(), &mut len) } {
            1 => out.push(buf[..len].to_vec()),
            _ => return out,
        }
    }
}

#[test]
fn a_tile_frame_is_released_with_its_flag_and_its_video_reference() {
    let s = session(CMUX_RD_CARRIER_DATAGRAM);
    open(&s, 8);
    let mut p = Packetizer::new(8, MAX_DATAGRAM_VPC);
    let body = FrameBody { t_capture_us: 1, ref_frame: 900, access_unit: vec![5; 2_000] };
    for d in p.packetize(1, flags::TILE, &body, 0).expect("packetize").datagrams {
        push(&s, &d, 0);
    }
    let mut f = CmuxRdFrame {
        t_capture_us: 0,
        data: std::ptr::null(),
        len: 0,
        frame: 0,
        ref_frame: 0,
        flags: 0,
    };
    let mut stream = 0u16;
    // SAFETY: live session, writable outs.
    assert_eq!(
        unsafe { cmux_rd_session_pop_frame(s.0, &mut f, &mut stream) },
        1,
        "a tile frame is released"
    );
    assert_eq!((stream, f.ref_frame), (8, 900));
    assert_eq!(u32::from(f.flags) & CMUX_RD_FLAG_TILE, CMUX_RD_FLAG_TILE);
}

#[test]
fn bulk_frames_on_the_stream_carrier_are_queued_as_bulk_messages() {
    let s = session(CMUX_RD_CARRIER_STREAM);
    let chunk = cmux_rd_proto::BulkFrame { transfer: 2, offset: 0, bytes: vec![3; 1_000] };
    let mut bytes = Vec::new();
    encode_stream_frame(STREAM_BULK, &chunk.encode(), &mut bytes).expect("bulk frame");
    // SAFETY: live session, readable slice.
    let rc = unsafe { cmux_rd_session_push_stream(s.0, bytes.as_ptr(), bytes.len(), 0) };
    assert!(rc >= 0, "a bulk frame does not end the session: {rc}");
    let mut m = CmuxRdMessage { data: std::ptr::null(), len: 0, kind: 0 };
    // SAFETY: live session, writable out.
    assert_eq!(unsafe { cmux_rd_session_pop_message(s.0, &mut m) }, 1);
    assert_eq!(u32::from(m.kind), CMUX_RD_MESSAGE_BULK);
    // SAFETY: valid until the next call.
    let payload = unsafe { std::slice::from_raw_parts(m.data, m.len) };
    assert_eq!(cmux_rd_proto::BulkFrame::decode(payload).expect("bulk"), chunk);
    // The viewer frames its own upload chunks with the same call.
    let mut out = vec![0u8; 2_048];
    let mut len = 0usize;
    let p = chunk.encode();
    // SAFETY: readable payload, writable buffer and length.
    let rc = unsafe {
        cmux_rd_encode_stream_frame(
            CMUX_RD_MESSAGE_BULK,
            p.as_ptr(),
            p.len(),
            out.as_mut_ptr(),
            out.len(),
            &mut len,
        )
    };
    assert_eq!(rc, CMUX_RD_OK);
    assert_eq!(&out[..len], &bytes[..]);
}

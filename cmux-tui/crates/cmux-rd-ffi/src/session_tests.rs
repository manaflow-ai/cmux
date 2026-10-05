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

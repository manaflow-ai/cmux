//! The upstream sender's C ABI (rd change C4b): frames in, UpMedia datagrams
//! out on both carriers, host feedback in through a session's messages.

use super::*;
use cmux_rd_core::reassembly::Reassembler;
use cmux_rd_proto::{
    DatagramHeader, DatagramKind, Feedback, MAX_DATAGRAM_VPC, Nack, STREAM_DATAGRAM, StreamDeframer,
};

const CAM: u16 = 101;

struct Up(*mut CmuxRdUpstream);

impl Drop for Up {
    fn drop(&mut self) {
        // SAFETY: created by cmux_rd_upstream_new and freed once here.
        unsafe { cmux_rd_upstream_free(self.0) };
    }
}

fn upstream(carrier: u32) -> Up {
    let h = cmux_rd_upstream_new(
        carrier,
        CAM,
        MAX_DATAGRAM_VPC as u32,
        CMUX_RD_PATH_DIRECT_WAN,
        0,
        0,
        0,
        true,
    );
    assert!(!h.is_null());
    Up(h)
}

fn send(u: &Up, data: &[u8], independent: bool, now_us: u64) -> i32 {
    // SAFETY: live sender, readable bytes.
    unsafe { cmux_rd_upstream_send_frame(u.0, data.as_ptr(), data.len(), 7, independent, now_us) }
}

fn drain(u: &Up) -> Vec<Vec<u8>> {
    let mut out = Vec::new();
    let mut buf = vec![0u8; 2_048];
    loop {
        let mut len = 0usize;
        // SAFETY: live sender, writable buffer and length.
        let rc =
            unsafe { cmux_rd_upstream_pop_datagram(u.0, buf.as_mut_ptr(), buf.len(), &mut len) };
        match rc {
            1 => out.push(buf[..len].to_vec()),
            0 => return out,
            other => panic!("pop_datagram: {other}"),
        }
    }
}

fn stats(u: &Up) -> CmuxRdUpstreamStats {
    let mut s = CmuxRdUpstreamStats::default();
    // SAFETY: live sender, writable stats.
    assert_eq!(unsafe { cmux_rd_upstream_stats(u.0, &mut s) }, CMUX_RD_OK);
    s
}

fn feedback(stream: u16, fb: &Feedback) -> Vec<u8> {
    let mut d = DatagramHeader {
        flags: 0,
        kind: DatagramKind::Feedback,
        stream,
        frame: 0,
        index: 0,
        count: 0,
        fec_count: 0,
        transport_seq: 0,
    }
    .encode()
    .to_vec();
    d.extend_from_slice(&fb.encode());
    d
}

#[test]
fn frames_leave_as_upmedia_datagrams_the_host_reassembles() {
    let u = upstream(CMUX_RD_CARRIER_DATAGRAM);
    assert!(stats(&u).keyframe_requested);
    let n = send(&u, &[9u8; 3_000], true, 0);
    assert!(n > 1, "a 3 KB frame spans several shards: {n}");
    let datagrams = drain(&u);
    assert_eq!(datagrams.len(), n as usize);
    let mut host = Reassembler::new(200_000);
    let mut released = Vec::new();
    for d in &datagrams {
        let (h, payload) = DatagramHeader::decode(d).expect("header");
        assert_eq!((h.kind, h.stream), (DatagramKind::UpMedia, CAM));
        released.extend(host.push(&h, payload, 1_000));
    }
    assert_eq!(released.len(), 1);
    assert_eq!(released[0].body.access_unit, vec![9u8; 3_000]);
    let s = stats(&u);
    assert_eq!((s.frames_sent, s.frames_dropped, s.keyframe_requested), (1, 0, false));
    // SAFETY: live sender.
    assert_eq!(unsafe { cmux_rd_upstream_target_bps(u.0, 1_000) }, 8_000_000);
}

#[test]
fn the_stream_carrier_frames_each_datagram() {
    let u = upstream(CMUX_RD_CARRIER_STREAM);
    let n = send(&u, &[1u8; 200], true, 0);
    assert_eq!(n, 1);
    let mut deframer = StreamDeframer::default();
    deframer.extend(&drain(&u).concat());
    let (kind, payload) = deframer.next_frame().expect("frame").expect("one frame");
    assert_eq!(kind, STREAM_DATAGRAM);
    assert_eq!(DatagramHeader::decode(&payload).expect("header").0.kind, DatagramKind::UpMedia);
}

#[test]
fn a_dependent_frame_before_a_keyframe_is_dropped() {
    let u = upstream(CMUX_RD_CARRIER_DATAGRAM);
    assert_eq!(send(&u, &[1u8; 200], false, 0), 0);
    assert!(drain(&u).is_empty());
    let s = stats(&u);
    assert_eq!((s.frames_dropped, s.keyframe_requested), (1, true));
}

#[test]
fn host_feedback_resends_nacked_shards_and_other_streams_are_refused() {
    let u = upstream(CMUX_RD_CARRIER_DATAGRAM);
    send(&u, &[2u8; 3_000], true, 0);
    let sent = drain(&u);
    let nack = feedback(
        CAM,
        &Feedback { nacks: vec![Nack { frame: 1, indexes: vec![0] }], ..Feedback::default() },
    );
    // SAFETY: live sender, readable bytes.
    let rc = unsafe { cmux_rd_upstream_on_datagram(u.0, nack.as_ptr(), nack.len(), 10_000) };
    assert_eq!(rc, 1);
    assert_eq!(drain(&u), vec![sent[0].clone()]);
    let other = feedback(CAM + 1, &Feedback::default());
    // SAFETY: as above.
    let rc = unsafe { cmux_rd_upstream_on_datagram(u.0, other.as_ptr(), other.len(), 10_000) };
    assert_eq!(rc, CMUX_RD_ERR_STREAM);
    // SAFETY: as above.
    let rc = unsafe { cmux_rd_upstream_on_datagram(u.0, [0xffu8; 3].as_ptr(), 3, 10_000) };
    assert_eq!(rc, CMUX_RD_ERR_INVALID);
    let ack =
        feedback(CAM, &Feedback { acked_frame: 1, need_recovery: true, ..Feedback::default() });
    // SAFETY: as above.
    assert_eq!(unsafe { cmux_rd_upstream_on_datagram(u.0, ack.as_ptr(), ack.len(), 20_000) }, 0);
    let s = stats(&u);
    assert_eq!((s.acked_frame, s.keyframe_requested), (1, true));
}

#[test]
fn a_small_buffer_keeps_the_datagram_queued() {
    let u = upstream(CMUX_RD_CARRIER_DATAGRAM);
    send(&u, &[3u8; 100], true, 0);
    let mut len = usize::MAX;
    let mut tiny = [0u8; 4];
    // SAFETY: live sender, writable buffer and length.
    let rc = unsafe { cmux_rd_upstream_pop_datagram(u.0, tiny.as_mut_ptr(), tiny.len(), &mut len) };
    assert_eq!(rc, CMUX_RD_ERR_BUFFER);
    assert!(len > tiny.len());
    assert_eq!(drain(&u).len(), 1, "the datagram is still queued");
}

#[test]
fn invalid_arguments_and_null_handles_are_refused() {
    let bad = |carrier, max_datagram, path, min_bps, max_bps| {
        cmux_rd_upstream_new(carrier, 1, max_datagram, path, 0, min_bps, max_bps, true).is_null()
    };
    assert!(bad(9, 1152, CMUX_RD_PATH_DIRECT_LAN, 0, 0), "carrier");
    assert!(bad(CMUX_RD_CARRIER_DATAGRAM, 1152, 9, 0, 0), "path");
    assert!(bad(CMUX_RD_CARRIER_DATAGRAM, 63, CMUX_RD_PATH_DIRECT_LAN, 0, 0), "datagram size");
    assert!(bad(CMUX_RD_CARRIER_DATAGRAM, 1152, CMUX_RD_PATH_DIRECT_LAN, 5, 4), "min above max");
    let u = upstream(CMUX_RD_CARRIER_DATAGRAM);
    // SAFETY: live sender.
    assert_eq!(unsafe { cmux_rd_upstream_set_path(u.0, 9) }, CMUX_RD_ERR_INVALID);
    // SAFETY: as above.
    assert_eq!(unsafe { cmux_rd_upstream_set_path(u.0, CMUX_RD_PATH_DO_RELAY) }, CMUX_RD_OK);
    // SAFETY: as above.
    assert!(unsafe { cmux_rd_upstream_target_bps(u.0, 0) } <= 4_000_000, "relay cap");
    let null = std::ptr::null_mut();
    // SAFETY: NULL handles are allowed and refused.
    unsafe {
        assert_eq!(
            cmux_rd_upstream_send_frame(null, [1u8].as_ptr(), 1, 0, true, 0),
            CMUX_RD_ERR_NULL
        );
        assert_eq!(cmux_rd_upstream_target_bps(null, 0), 0);
        let mut len = 7usize;
        assert_eq!(cmux_rd_upstream_pop_datagram(null, null.cast(), 0, &mut len), CMUX_RD_ERR_NULL);
        assert_eq!(len, 0);
        cmux_rd_upstream_free(null);
    }
}

#[test]
fn a_full_queue_drops_new_frames() {
    let u = upstream(CMUX_RD_CARRIER_DATAGRAM);
    let frame = vec![4u8; 200];
    let mut sent = 0usize;
    let mut now = 0;
    // Nobody pops; one small frame every 2 ms stays inside the pacing budget.
    for _ in 0..100_000 {
        now += 2_000;
        if send(&u, &frame, true, now) == 0 {
            break;
        }
        sent += 1;
    }
    // Each frame is one unpadded 232-byte datagram.
    assert!(
        sent * 232 >= CMUX_RD_UPSTREAM_MAX_QUEUED,
        "frames went out until the queue filled: {sent}"
    );
    assert_eq!(send(&u, &frame, true, now + 2_000), 0, "the queue is full");
    assert!(stats(&u).frames_dropped >= 1);
}

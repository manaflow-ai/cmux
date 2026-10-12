//! The viewer's upstream media sender (rd change C4b): UpMedia shards out,
//! the host's upstream feedback in (acks, NACKs, arrival times, recovery).

use cmux_rd_core::cc::{CcConfig, PathKind};
use cmux_rd_core::reassembly::Reassembler;
use cmux_rd_core::upstream::{UpstreamConfig, UpstreamError, UpstreamSender};
use cmux_rd_proto::{
    Arrival, DatagramHeader, DatagramKind, FRAME_PREFIX_LEN, Feedback, FrameBody, HEADER_LEN,
    MAX_DATAGRAM_VPC, Nack, REF_NONE, flags,
};

const MIC: u16 = 100;
const CAM: u16 = 101;

fn config(stream: u16, min_bps: u64, start_bps: u64, max_bps: u64) -> UpstreamConfig {
    UpstreamConfig {
        stream,
        max_datagram: MAX_DATAGRAM_VPC,
        cc: CcConfig { min_bps, start_bps, max_bps, ..CcConfig::default() },
        path: PathKind::DirectWan,
        fec: stream != MIC,
    }
}

fn camera() -> UpstreamSender {
    UpstreamSender::new(config(CAM, 1_000_000, 8_000_000, 80_000_000))
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

fn seqs(datagrams: &[Vec<u8>]) -> Vec<u16> {
    datagrams.iter().map(|d| DatagramHeader::decode(d).expect("header").0.transport_seq).collect()
}

#[test]
fn frames_go_out_as_upmedia_shards_the_host_reassembles() {
    let mut s = camera();
    let key = s.send_frame(&[7u8; 3_000], 11, true, 0).expect("packetize").expect("sent");
    let delta = s.send_frame(&[8u8; 500], 12, false, 1_000).expect("packetize").expect("sent");
    let mut host = Reassembler::new(200_000);
    let mut released = Vec::new();
    for d in key.iter().chain(delta.iter()) {
        let (h, payload) = DatagramHeader::decode(d).expect("header");
        assert_eq!((h.kind, h.stream), (DatagramKind::UpMedia, CAM));
        released.extend(host.push(&h, payload, 2_000));
    }
    assert_eq!(released.len(), 2);
    assert_eq!(released[0].frame, 1);
    assert_eq!(released[0].flags & flags::KEYFRAME, flags::KEYFRAME);
    assert_eq!(
        released[0].body,
        FrameBody { t_capture_us: 11, ref_frame: REF_NONE, access_unit: vec![7u8; 3_000] }
    );
    assert_eq!((released[1].frame, released[1].body.ref_frame), (2, 1));
    assert_eq!(s.stats().frames_sent, 2);
}

#[test]
fn a_dependent_frame_without_a_keyframe_is_dropped_and_asks_for_one() {
    let mut s = camera();
    assert!(s.keyframe_requested(), "the encoder starts with a keyframe");
    assert_eq!(s.send_frame(&[1u8; 100], 0, false, 0).expect("packetize"), None);
    assert!(s.keyframe_requested());
    assert_eq!(s.stats().frames_dropped, 1);
    assert!(s.send_frame(&[1u8; 100], 0, true, 1).expect("packetize").is_some());
    assert!(!s.keyframe_requested(), "an independent frame answers the request");
}

#[test]
fn nacked_shards_are_resent_until_their_frame_is_acked() {
    let mut s = camera();
    let sent = s.send_frame(&[3u8; 3_000], 0, true, 0).expect("packetize").expect("sent");
    let nack = Feedback { nacks: vec![Nack { frame: 1, indexes: vec![1] }], ..Feedback::default() };
    let resent = s.on_datagram(&feedback(CAM, &nack), 10_000).expect("feedback");
    assert_eq!(resent, vec![sent[1].clone()]);
    let ack = Feedback { acked_frame: 1, ..Feedback::default() };
    assert!(s.on_datagram(&feedback(CAM, &ack), 20_000).expect("feedback").is_empty());
    assert_eq!(s.stats().acked_frame, 1);
    let late = s.on_datagram(&feedback(CAM, &nack), 30_000).expect("feedback");
    assert!(late.is_empty(), "an acked frame leaves the history");
}

#[test]
fn feedback_of_another_stream_or_kind_is_not_taken() {
    let mut s = camera();
    let fb = Feedback::default();
    assert_eq!(s.on_datagram(&feedback(MIC, &fb), 0), Err(UpstreamError::NotMine));
    assert!(matches!(s.on_datagram(&[0xff; 4], 0), Err(UpstreamError::Invalid(_))));
}

#[test]
fn host_recovery_requests_a_keyframe_once_per_loss() {
    let mut s = camera();
    s.send_frame(&[1u8; 100], 0, true, 0).expect("packetize").expect("sent");
    assert!(!s.keyframe_requested());
    // The host still asks while keyframe 1 is on its way: already answered.
    let stale = Feedback { need_recovery: true, ..Feedback::default() };
    s.on_datagram(&feedback(CAM, &stale), 1_000).expect("feedback");
    assert!(!s.keyframe_requested(), "a request older than the keyframe is answered");
    // After the host acknowledged keyframe 1, a new request is a new loss.
    let fresh = Feedback { acked_frame: 1, need_recovery: true, ..Feedback::default() };
    s.on_datagram(&feedback(CAM, &fresh), 2_000).expect("feedback");
    assert!(s.keyframe_requested());
}

#[test]
fn a_lost_keyframe_is_requested_again_after_the_retry_time() {
    let mut s = camera();
    s.send_frame(&[1u8; 100], 0, true, 0).expect("packetize").expect("sent");
    let ask = Feedback { need_recovery: true, ..Feedback::default() };
    s.on_datagram(&feedback(CAM, &ask), 100_000).expect("feedback");
    assert!(!s.keyframe_requested());
    s.on_datagram(&feedback(CAM, &ask), 300_000).expect("feedback");
    assert!(s.keyframe_requested(), "keyframe 1 never arrived");
}

#[test]
fn resends_spend_the_pacing_budget() {
    // 1 Mbit/s: a 20 KB keyframe overdraws the 100 kbit burst.
    let mut s = UpstreamSender::new(config(CAM, 1_000_000, 1_000_000, 1_000_000));
    let sent = s.send_frame(&[1u8; 20_000], 0, true, 0).expect("packetize").expect("sent");
    let all: Vec<u16> = (0..sent.len() as u16).collect();
    let nack = Feedback { nacks: vec![Nack { frame: 1, indexes: all }], ..Feedback::default() };
    let now = s.on_datagram(&feedback(CAM, &nack), 1_000).expect("feedback");
    assert!(now.is_empty(), "an overdrawn budget resends nothing: {}", now.len());
    // 300 ms later the budget is back: a burst's worth goes out, not the whole frame.
    let later = s.on_datagram(&feedback(CAM, &nack), 300_000).expect("feedback");
    assert!(!later.is_empty() && later.len() < sent.len(), "{} of {}", later.len(), sent.len());
}

/// Sends one small frame every 20 ms and answers each with feedback whose
/// one-way delay grows by `growth_us` per frame; returns the final target.
fn run(growth_us: i64) -> u64 {
    let mut s = camera();
    let mut delay = 10_000i64;
    for i in 0..50u64 {
        let now = i * 20_000;
        let sent = s.send_frame(&[1u8; 200], now, true, now).expect("packetize").expect("sent");
        let arrivals = seqs(&sent)
            .into_iter()
            .map(|transport_seq| Arrival { transport_seq, arrival_us: (now as i64 + delay) as u32 })
            .collect();
        let fb = Feedback { acked_frame: (i + 1) as u32, arrivals, ..Feedback::default() };
        s.on_datagram(&feedback(CAM, &fb), now + delay as u64).expect("feedback");
        delay += growth_us;
    }
    s.target_bps(1_000_000)
}

#[test]
fn a_growing_queue_lowers_the_target_and_a_flat_path_raises_it() {
    let start = 8_000_000;
    let flat = run(0);
    let queued = run(5_000);
    assert!(flat > start, "flat delay grows the target: {flat}");
    assert!(queued < start, "a building queue lowers the target: {queued}");
}

#[test]
fn measured_loss_adds_parity() {
    let mut s = camera();
    let first = s.send_frame(&[1u8; 5_000], 0, true, 0).expect("packetize").expect("sent");
    let parity = |d: &[Vec<u8>]| DatagramHeader::decode(&d[0]).expect("header").0.fec_count;
    assert_eq!(parity(&first), 0, "a clean path sends no parity");
    // The host reports only every other shard of a long run of frames.
    // One frame per 100 ms keeps the frames inside the pacing budget at the floor.
    let mut now = 0;
    for _ in 0..10 {
        now += 100_000;
        let sent = s.send_frame(&[1u8; 5_000], now, true, now).expect("packetize").expect("sent");
        let arrivals = seqs(&sent)
            .into_iter()
            .step_by(2)
            .map(|transport_seq| Arrival { transport_seq, arrival_us: now as u32 })
            .collect();
        let fb = Feedback { arrivals, ..Feedback::default() };
        s.on_datagram(&feedback(CAM, &fb), now).expect("feedback");
    }
    now += 100_000;
    let lossy = s.send_frame(&[1u8; 5_000], now, true, now).expect("packetize").expect("sent");
    assert!(parity(&lossy) > 0, "loss adds parity");
    assert!(s.stats().loss > 0.1);
}

#[test]
fn frames_over_the_pacing_budget_are_dropped_and_break_the_chain() {
    // 1 Mbit/s: the 100 ms burst is 100 kbit, about 12 KB.
    let mut s = UpstreamSender::new(config(CAM, 1_000_000, 1_000_000, 1_000_000));
    assert!(s.send_frame(&[1u8; 20_000], 0, true, 0).expect("packetize").is_some());
    assert_eq!(s.send_frame(&[1u8; 500], 0, false, 1_000).expect("packetize"), None);
    assert!(s.keyframe_requested());
    // The budget refills, but a dependent frame still references the dropped one.
    assert_eq!(s.send_frame(&[1u8; 500], 0, false, 400_000).expect("packetize"), None);
    assert!(s.send_frame(&[1u8; 500], 0, true, 401_000).expect("packetize").is_some());
    assert!(s.send_frame(&[1u8; 500], 0, false, 402_000).expect("packetize").is_some());
    assert_eq!(s.stats().frames_dropped, 2);
}

#[test]
fn a_silent_host_drops_the_target_to_the_floor() {
    let mut s = camera();
    s.send_frame(&[1u8; 100], 0, true, 0).expect("packetize").expect("sent");
    assert_eq!(s.target_bps(100_000), 8_000_000);
    assert_eq!(s.target_bps(600_000), 1_000_000, "no feedback for 500 ms");
    let ack = Feedback { acked_frame: 1, ..Feedback::default() };
    s.on_datagram(&feedback(CAM, &ack), 650_000).expect("feedback");
    assert_eq!(s.target_bps(2_000_000), 8_000_000, "nothing unacked: not silent");
}

#[test]
fn audio_packets_are_independent_and_never_wait_for_a_keyframe() {
    let mut mic = UpstreamSender::new(config(MIC, 16_000, 64_000, 128_000));
    for i in 0..5u64 {
        let sent = mic.send_frame(&[2u8; 120], i, true, i * 10_000).expect("packetize");
        let sent = sent.expect("an Opus packet goes out");
        let (h, _) = DatagramHeader::decode(&sent[0]).expect("header");
        assert_eq!((h.stream, h.frame, h.count, h.fec_count), (MIC, (i + 1) as u32, 1, 0));
        // A lone shard is not padded: 120 bytes of Opus cost 152 bytes, not a full datagram.
        assert_eq!(sent[0].len(), HEADER_LEN + FRAME_PREFIX_LEN + 120);
    }
    assert_eq!(mic.stats().frames_dropped, 0);
}

//! Upstream media (rd change C4): the viewer's microphone, camera or screen
//! share as UpMedia shards with FEC; the host reassembles them per upstream
//! stream and acknowledges and NACKs them in feedback.

use cmux_rd_core::packetize::Packetizer;
use cmux_rd_engine::{EngineConfig, MediaEngine};
use cmux_rd_proto::{
    DatagramHeader, DatagramKind, Feedback, FrameBody, MAX_DATAGRAM_VPC, REF_NONE,
};

const MIC: u16 = 100;

fn frames(p: &mut Packetizer, frame: u32, len: usize, parity: usize) -> Vec<Vec<u8>> {
    let body = FrameBody {
        t_capture_us: u64::from(frame),
        ref_frame: REF_NONE,
        access_unit: vec![frame as u8; len],
    };
    p.packetize(frame, 0, &body, parity).expect("packetize").datagrams
}

#[test]
fn upstream_shards_use_their_own_kind() {
    let mut p = Packetizer::new(MIC, MAX_DATAGRAM_VPC);
    p.set_upstream(true);
    for d in frames(&mut p, 1, 3_000, 1) {
        let (h, _) = DatagramHeader::decode(&d).expect("an upstream shard decodes");
        assert_eq!(h.kind, DatagramKind::UpMedia);
        assert_eq!(h.stream, MIC);
    }
}

#[test]
fn the_host_reassembles_upstream_frames_and_acknowledges_them() {
    let mut e = MediaEngine::new(EngineConfig::default(), 0);
    e.add_upstream(MIC).expect("upstream stream");
    let mut p = Packetizer::new(MIC, MAX_DATAGRAM_VPC);
    p.set_upstream(true);
    let shards = frames(&mut p, 1, 3_000, 1);
    let mut got = Vec::new();
    // One data shard lost: parity rebuilds it.
    for d in shards.iter().skip(1) {
        got.extend(e.on_datagram(d, false, 1_000).upstream);
    }
    assert_eq!(got.len(), 1, "one complete upstream frame, even without control");
    assert_eq!(got[0].0, MIC);
    assert_eq!(got[0].1.body.access_unit, vec![1u8; 3_000]);
    // Feedback for the upstream stream acknowledges the frame.
    let fb = e.upstream_feedback(1_000).expect("feedback after a release");
    let (h, payload) = DatagramHeader::decode(&fb).expect("header");
    assert_eq!((h.kind, h.stream), (DatagramKind::Feedback, MIC));
    assert_eq!(Feedback::decode(payload).expect("feedback").acked_frame, 1);
    assert!(e.upstream_feedback(1_001).is_none(), "nothing new to report");
}

#[test]
fn unregistered_upstream_streams_are_ignored() {
    let mut e = MediaEngine::new(EngineConfig::default(), 0);
    let mut p = Packetizer::new(MIC, MAX_DATAGRAM_VPC);
    p.set_upstream(true);
    for d in frames(&mut p, 1, 500, 0) {
        assert!(e.on_datagram(&d, true, 0).upstream.is_empty());
    }
    assert!(e.upstream_feedback(0).is_none());
}

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

#[test]
fn the_viewer_sender_recovers_a_lost_shard_through_the_hosts_nack() {
    use cmux_rd_core::cc::{CcConfig, PathKind};
    use cmux_rd_core::upstream::{UpstreamConfig, UpstreamSender};

    let mut host = MediaEngine::new(EngineConfig::default(), 0);
    host.add_upstream(MIC).expect("upstream stream");
    let mut viewer = UpstreamSender::new(UpstreamConfig {
        stream: MIC,
        max_datagram: MAX_DATAGRAM_VPC,
        cc: CcConfig::default(),
        path: PathKind::DirectWan,
        fec: true,
    });
    let sent = viewer.send_frame(&[5u8; 4_000], 9, true, 0).expect("packetize").expect("sent");
    assert_eq!(DatagramHeader::decode(&sent[0]).expect("header").0.fec_count, 0, "clean path");
    // Shard 1 is lost on the way.
    for (i, d) in sent.iter().enumerate() {
        if i != 1 {
            assert!(host.on_datagram(d, false, 1_000).upstream.is_empty());
        }
    }
    // After the NACK delay the host's feedback names the gap; the viewer resends it.
    let fb = host.upstream_feedback(10_000).expect("feedback with a NACK");
    let resent = viewer.on_datagram(&fb, 11_000).expect("feedback for this stream");
    assert_eq!(resent, vec![sent[1].clone()]);
    let got = host.on_datagram(&resent[0], false, 12_000).upstream;
    assert_eq!(got.len(), 1);
    assert_eq!(got[0].1.body.access_unit, vec![5u8; 4_000]);
    // The acknowledgement clears the viewer's history.
    let ack = host.upstream_feedback(70_000).expect("feedback after the release");
    viewer.on_datagram(&ack, 71_000).expect("feedback for this stream");
    assert_eq!(viewer.stats().acked_frame, 1);
}

#[test]
fn an_upstream_cannot_reuse_a_display_stream_id() {
    use cmux_rd_engine::{MAX_UPSTREAMS, StreamError};
    let mut e = MediaEngine::new(EngineConfig::default(), 0);
    // Stream 0 is the main display: the viewer routes feedback by id.
    assert_eq!(e.add_upstream(0), Err(StreamError::Exists(0)));
    assert_eq!(StreamError::Exists(0).reason(), "in_use");
    for s in 0..MAX_UPSTREAMS as u16 {
        e.add_upstream(MIC + s).expect("upstream");
    }
    assert_eq!(e.add_upstream(MIC + 10), Err(StreamError::TooMany));
    assert_eq!(StreamError::TooMany.reason(), "too_many");
    // A display or tile stream cannot take an upstream's id either.
    assert_eq!(e.add_stream(MIC, 64, 64), Err(StreamError::Exists(MIC)));
    assert_eq!(e.add_tile_stream(MIC + 1, 0, 64, 64), Err(StreamError::Exists(MIC + 1)));
    // Removing one frees its slot and its id.
    e.remove_upstream(MIC);
    e.add_upstream(MIC).expect("the slot is free again");
}

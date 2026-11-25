//! Exercise alternate-decoder accounting through the real packet/reassembly path.
use super::*;
use cmux_encode::{Codec, VideoDecoder, I420};
use cmux_rd_core::packetize::Packetizer;
use cmux_rd_proto::{flags, FrameBody, REF_NONE};
use std::net::TcpListener;

const FRAME: u32 = 7;
const RELEASE_US: u64 = 123_456;
const ACCESS_UNIT: [u8; 2048] = [0x5a; 2048];

enum Outcome {
    Picture,
    Buffered,
    Error,
}

struct FakeDecoder(Outcome);

impl VideoDecoder for FakeDecoder {
    fn decode(&mut self, au: &[u8], out: &mut I420) -> cmux_encode::Res<bool> {
        assert_eq!(au, ACCESS_UNIT, "the decoder must receive the reassembled access unit");
        match self.0 {
            Outcome::Picture => {
                *out = I420::new(640, 128);
                out.y.fill(90);
                Ok(true)
            }
            Outcome::Buffered => Ok(false),
            Outcome::Error => Err("controlled decoder failure".into()),
        }
    }

    fn codec(&self) -> Codec {
        Codec::Vp9
    }

    fn name(&self) -> String {
        "controlled alternate decoder".into()
    }
}

fn viewer(outcome: Outcome) -> (Viewer, TcpStream) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind local control socket");
    let tcp = TcpStream::connect(listener.local_addr().expect("listener address"))
        .expect("connect local control socket");
    let (peer, _) = listener.accept().expect("accept local control socket");
    let viewer = Viewer {
        io: ViewerIo::Socket { tcp, reader: FrameReader::default(), udp: None },
        reassembler: Reassembler::new(200_000),
        decoder: Decoder::new().expect("create fallback decoder"),
        sender: InputSender::new(),
        arrivals: Vec::new(),
        marker: None,
        marker_at_ns: 0,
        marker_capture_us: 0,
        frames: 0,
        decoded_frames: 0,
        eval_decode: Some(crate::eval::DecodeLog::default()),
        eval_quality: None,
        bytes: 0,
        decode_ms: Vec::new(),
        decode_errors: 0,
        last_feedback_ns: 0,
        released_since_feedback: false,
        stats: Vec::new(),
        ended: None,
        welcome: None,
        max_datagram: MAX_DATAGRAM_VPC,
        upstream: None,
        stream_answer: None,
        upstream_closed_by_host: false,
        snapshot: None,
        #[cfg(target_os = "macos")]
        newest_picture: None,
        want_snapshot: false,
        record: None,
        marker_origin: (0, 0),
        #[cfg(target_os = "macos")]
        vt: None,
        alt: Some((Box::new(FakeDecoder(outcome)), I420::new(2, 2))),
    };
    (viewer, peer)
}

fn deliver_frame(viewer: &mut Viewer) {
    let body = FrameBody {
        t_capture_us: RELEASE_US,
        ref_frame: REF_NONE,
        access_unit: ACCESS_UNIT.to_vec(),
    };
    let packets = Packetizer::new(0, 256)
        .packetize(FRAME, flags::KEYFRAME, &body, 0)
        .expect("packetize fixture frame");
    assert!(packets.datagrams.len() > 1, "exercise real fragmented reassembly");
    let last = packets.datagrams.len() - 1;
    for (index, packet) in packets.datagrams.iter().enumerate() {
        viewer.on_datagram(packet);
        if index < last {
            assert_eq!(viewer.decoded_frames, 0, "incomplete frame is not decoded");
            assert!(viewer.eval_decode.as_ref().unwrap().records.is_empty());
        }
    }
    assert_eq!(viewer.frames, 1, "fixture must reach the decoder branch");
    assert_eq!(viewer.decode_ms.len(), 1, "exactly one decode attempt");
}

#[test]
fn alternate_picture_counts_and_retains_decode_identity() {
    let (mut viewer, _peer) = viewer(Outcome::Picture);
    let before_us = now_ns() / 1000;
    deliver_frame(&mut viewer);
    let after_us = now_ns() / 1000;
    assert_eq!(viewer.decoded_frames, 1, "passive first-frame wait must be satisfied");
    assert_eq!(viewer.decode_errors, 0);
    let log = viewer.eval_decode.as_ref().unwrap();
    assert!(!log.truncated);
    assert_eq!(log.records.len(), 1);
    let record = &log.records[0];
    assert_eq!(record["frame_id"], FRAME);
    assert_eq!(record["release_us"], RELEASE_US);
    let decoded_us = record["decoded_us"].as_u64().expect("decode completion timestamp");
    assert!((before_us..=after_us).contains(&decoded_us));
}

#[test]
fn alternate_buffered_unit_is_not_a_decoded_frame() {
    let (mut viewer, _peer) = viewer(Outcome::Buffered);
    deliver_frame(&mut viewer);
    assert_eq!(viewer.decoded_frames, 0);
    assert_eq!(viewer.decode_errors, 0);
    assert!(viewer.eval_decode.as_ref().unwrap().records.is_empty());
}

#[test]
fn alternate_decode_error_is_not_a_decoded_frame() {
    let (mut viewer, _peer) = viewer(Outcome::Error);
    deliver_frame(&mut viewer);
    assert_eq!(viewer.decoded_frames, 0);
    assert_eq!(viewer.decode_errors, 1);
    assert!(viewer.eval_decode.as_ref().unwrap().records.is_empty());
}

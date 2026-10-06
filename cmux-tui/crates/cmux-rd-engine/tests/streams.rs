//! Several display streams per peer (remote-tab-r2.md B3.1, B3.5): one
//! congestion controller and transport sequence space, a frame gate, NACK
//! history and recovery per stream, the bitrate split page first, and no
//! deadline while nothing is pending.

use std::collections::BTreeSet;

use cmux_rd_core::flow::Rect;
use cmux_rd_engine::{EncodeRequest, Encoded, EngineConfig, MediaEngine, StreamError};
use cmux_rd_proto::{DatagramHeader, DatagramKind, Feedback, InputEvent, InputPacket, Nack};

fn engine() -> MediaEngine {
    MediaEngine::new(EngineConfig { width: 640, height: 480, max_fps: 60, ..EngineConfig::default() }, 0)
}

fn dgram(kind: DatagramKind, stream: u16, payload: &[u8]) -> Vec<u8> {
    let mut d = DatagramHeader {
        flags: 0,
        kind,
        stream,
        frame: 0,
        index: 0,
        count: 0,
        fec_count: 0,
        transport_seq: 0,
    }
    .encode()
    .to_vec();
    d.extend_from_slice(payload);
    d
}

fn send(e: &mut MediaEngine, req: &EncodeRequest, len: usize, now: u64) -> Vec<Vec<u8>> {
    let enc = Encoded { access_unit: vec![7; len], idr: req.force_idr, t_capture_us: now };
    e.encoded(req, Some(enc), now).expect("encoded").datagrams
}

const POPUP: u16 = 3;
const SMALL: Rect = Rect { x: 0, y: 0, width: 8, height: 8 };

#[test]
fn each_stream_has_its_own_gate_and_frames_in_one_sequence_space() {
    let mut e = engine();
    e.add_stream(POPUP, 200, 100).expect("popup");
    let main = e.start(0).expect("main");
    let popup = e.damage(POPUP, SMALL, 0).expect("the popup's first frame");
    assert_eq!((main.stream, popup.stream), (0, POPUP));
    assert!(popup.force_idr, "a new stream starts with an IDR");
    assert_eq!(popup.damage, Rect { x: 0, y: 0, width: 200, height: 100 }, "the whole popup first");
    let a = send(&mut e, &main, 3_000, 0);
    let b = send(&mut e, &popup, 3_000, 0);
    let mut seqs = BTreeSet::new();
    for d in a.iter().chain(&b) {
        let (h, _) = DatagramHeader::decode(d).expect("header");
        assert!(seqs.insert(h.transport_seq), "transport sequence numbers are shared");
    }
    for d in &b {
        assert_eq!(DatagramHeader::decode(d).expect("header").0.stream, POPUP);
    }
    // The popup's ack releases only the popup's gate.
    assert!(e.damage(0, SMALL, 20_000).is_none(), "main waits for its own ack");
    let ack = Feedback { acked_frame: popup.frame, ..Feedback::default() };
    let out = e.on_datagram(&dgram(DatagramKind::Feedback, POPUP, &ack.encode()), true, 30_000);
    assert!(out.encode.is_none(), "no popup damage is pending");
    assert!(e.damage(POPUP, SMALL, 40_000).is_some(), "the popup gate is open again");
}

#[test]
fn nacks_and_recovery_are_per_stream() {
    let mut e = engine();
    e.add_stream(POPUP, 200, 100).expect("popup");
    let main = e.start(0).expect("main");
    let popup = e.damage(POPUP, SMALL, 0).expect("popup");
    send(&mut e, &main, 6_000, 0);
    let sent = send(&mut e, &popup, 6_000, 0);
    let nack = Feedback { nacks: vec![Nack { frame: popup.frame, indexes: vec![2] }], ..Feedback::default() };
    let out = e.on_datagram(&dgram(DatagramKind::Feedback, POPUP, &nack.encode()), true, 10_000);
    assert_eq!(out.datagrams, vec![sent[2].clone()]);
    let ask = Feedback { acked_frame: popup.frame, need_recovery: true, ..Feedback::default() };
    let out = e.on_datagram(&dgram(DatagramKind::Feedback, POPUP, &ask.encode()), true, 300_000);
    let idr = out.encode.expect("recovery");
    assert_eq!(idr.stream, POPUP);
    assert!(idr.force_idr);
}

#[test]
fn the_page_gets_the_bitrate_first() {
    let mut e = engine();
    let alone = e.start(0).expect("main").target_kbps;
    let mut e = engine();
    e.add_stream(POPUP, 200, 100).expect("popup");
    let main = e.start(0).expect("main");
    let popup = e.damage(POPUP, SMALL, 0).expect("popup");
    assert!(popup.target_kbps >= 300, "a popup gets at least 300 kbit/s");
    assert!(popup.target_kbps <= alone / 5 + 1, "popups share at most 20 %");
    assert_eq!(main.target_kbps + popup.target_kbps, alone, "the split adds up");
}

#[test]
fn streams_are_bounded_and_removal_drops_their_state() {
    let mut e = engine();
    for s in 1..16 {
        e.add_stream(s, 10, 10).expect("stream");
    }
    assert_eq!(e.add_stream(16, 10, 10), Err(StreamError::TooMany));
    assert_eq!(e.add_stream(1, 10, 10), Err(StreamError::Exists(1)));
    e.remove_stream(5);
    assert!(e.damage(5, SMALL, 0).is_none(), "a removed stream encodes nothing");
    assert!(e.add_stream(16, 10, 10).is_ok());
}

#[test]
fn idle_means_no_deadline_and_a_held_input_gap_means_one() {
    let mut e = engine();
    let main = e.start(0).expect("main");
    send(&mut e, &main, 100, 0);
    let ack = Feedback { acked_frame: main.frame, ..Feedback::default() };
    e.on_datagram(&dgram(DatagramKind::Feedback, 0, &ack.encode()), true, 1_000);
    assert_eq!(e.next_deadline_us(), None, "nothing pending: no wakeup");
    // Sequence 2 arrives without 1: the applier holds it until the gap timeout.
    let packet = InputPacket { first_seq: 2, events: vec![InputEvent::Key { usage: 4, down: true }] };
    let out = e.on_datagram(&dgram(DatagramKind::Input, 0, &packet.encode()), true, 2_000);
    assert!(out.inject.is_empty());
    assert_eq!(e.next_deadline_us(), Some(2_000 + 200_000), "wake when the gap times out");
    assert_eq!(e.tick(true, 202_000).inject, packet.events);
    assert_eq!(e.next_deadline_us(), None);
}

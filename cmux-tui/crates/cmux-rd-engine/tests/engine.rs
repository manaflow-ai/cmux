//! The media engine every rd source shares (rd change C7 step 2): requests
//! encodes from damage under the one-frame-in-flight gate, packetizes with
//! FEC, resends NACKed shards from a bounded history, recovers on request
//! (rate-limited), and applies input exactly once with acks.

use cmux_rd_core::flow::Rect;
use cmux_rd_engine::{EncodeRequest, Encoded, EngineConfig, MediaEngine};
use cmux_rd_proto::{
    DatagramHeader, DatagramKind, Feedback, HEADER_LEN, InputEvent, InputPacket, Nack, flags,
};

fn engine() -> MediaEngine {
    MediaEngine::new(
        EngineConfig { width: 640, height: 480, max_fps: 60, ..EngineConfig::default() },
        0,
    )
}

fn au(len: usize) -> Vec<u8> {
    (0..len).map(|i| i as u8).collect()
}

fn header(kind: DatagramKind) -> Vec<u8> {
    DatagramHeader {
        flags: 0,
        kind,
        stream: 0,
        frame: 0,
        index: 0,
        count: 0,
        fec_count: 0,
        transport_seq: 0,
    }
    .encode()
    .to_vec()
}

fn feedback(fb: &Feedback) -> Vec<u8> {
    let mut d = header(DatagramKind::Feedback);
    d.extend_from_slice(&fb.encode());
    d
}

fn input(packet: &InputPacket) -> Vec<u8> {
    let mut d = header(DatagramKind::Input);
    d.extend_from_slice(&packet.encode());
    d
}

fn send(e: &mut MediaEngine, req: &EncodeRequest, idr: bool, len: usize, now: u64) -> Vec<Vec<u8>> {
    e.encoded(req, Some(Encoded { access_unit: au(len), idr, t_capture_us: now }), now)
        .expect("encoded")
        .datagrams
}

#[test]
fn the_first_frame_is_a_full_screen_keyframe() {
    let mut e = engine();
    let req = e.start(0).expect("first frame");
    assert!(req.force_idr);
    assert_eq!(req.damage, Rect { x: 0, y: 0, width: 640, height: 480 });
    let datagrams = send(&mut e, &req, true, 5_000, 0);
    assert!(datagrams.len() >= 5);
    let (h, _) = DatagramHeader::decode(&datagrams[0]).expect("header");
    assert_eq!(h.frame, req.frame);
    assert_ne!(h.flags & flags::KEYFRAME, 0);
}

#[test]
fn one_frame_in_flight_until_the_viewer_acknowledges() {
    let mut e = engine();
    let first = e.start(0).expect("first");
    send(&mut e, &first, true, 1_000, 0);
    let small = Rect { x: 1, y: 1, width: 10, height: 10 };
    assert!(e.damage(0, small, 20_000).is_none(), "a second frame waits for the ack");
    let out = e.on_datagram(
        &feedback(&Feedback { acked_frame: first.frame, ..Feedback::default() }),
        true,
        30_000,
    );
    let next = out.encode.expect("the ack releases the coalesced damage");
    assert!(!next.force_idr);
    assert!(next.frame > first.frame);
}

#[test]
fn nacked_shards_are_resent_from_history() {
    let mut e = engine();
    let first = e.start(0).expect("first");
    let sent = send(&mut e, &first, true, 6_000, 0);
    let fb = Feedback {
        nacks: vec![Nack { frame: first.frame, indexes: vec![1, 3] }],
        ..Feedback::default()
    };
    let out = e.on_datagram(&feedback(&fb), true, 10_000);
    assert_eq!(out.datagrams, vec![sent[1].clone(), sent[3].clone()]);
}

#[test]
fn a_recovery_request_forces_a_keyframe_at_most_every_250_ms() {
    let mut e = engine();
    let first = e.start(0).expect("first");
    send(&mut e, &first, true, 500, 0);
    let ask = feedback(&Feedback {
        acked_frame: first.frame,
        need_recovery: true,
        ..Feedback::default()
    });
    let out = e.on_datagram(&ask, true, 300_000);
    let idr = out.encode.expect("recovery encode");
    assert!(idr.force_idr);
    send(&mut e, &idr, true, 500, 300_000);
    let again =
        feedback(&Feedback { acked_frame: idr.frame, need_recovery: true, ..Feedback::default() });
    let out = e.on_datagram(&again, true, 400_000);
    assert!(out.encode.is_none_or(|r| !r.force_idr), "a second forced keyframe within 250 ms");
}

#[test]
fn input_is_applied_once_and_acknowledged_and_refused_input_is_acknowledged_too() {
    let mut e = engine();
    let packet = InputPacket {
        first_seq: 1,
        events: vec![
            InputEvent::Key { usage: 4, down: true },
            InputEvent::Key { usage: 4, down: false },
        ],
    };
    let out = e.on_datagram(&input(&packet), true, 0);
    assert_eq!(out.inject, packet.events);
    assert_eq!(out.datagrams.len(), 1);
    let (h, payload) = DatagramHeader::decode(&out.datagrams[0]).expect("ack");
    assert_eq!(h.kind, DatagramKind::InputAck);
    assert_eq!(payload, 2u32.to_le_bytes());
    // A repeat is not applied again.
    assert!(e.on_datagram(&input(&packet), true, 10).inject.is_empty());
    // Without control: nothing injected, still acknowledged through the refused events.
    let later = InputPacket { first_seq: 3, events: vec![InputEvent::Text("x".into())] };
    let out = e.on_datagram(&input(&later), false, 20);
    assert!(out.inject.is_empty());
    let (_, payload) = DatagramHeader::decode(&out.datagrams[0]).expect("ack");
    assert_eq!(payload, 3u32.to_le_bytes());
    assert_eq!(out.datagrams[0].len(), HEADER_LEN + 4);
}

#[test]
fn a_frame_too_large_halves_the_bitrate_and_restarts_from_a_keyframe() {
    let mut e = MediaEngine::new(
        EngineConfig { width: 64, height: 64, max_datagram: 64, ..EngineConfig::default() },
        0,
    );
    let first = e.start(0).expect("first");
    // 4096 shards of 48 bytes is the limit at this datagram size.
    let out = e
        .encoded(&first, Some(Encoded { access_unit: au(300_000), idr: true, t_capture_us: 0 }), 0)
        .expect("ok");
    assert!(out.datagrams.is_empty());
    assert!(out.halve_bitrate);
    let next = e.damage(0, Rect { x: 0, y: 0, width: 1, height: 1 }, 20_000).expect("gate open again");
    assert!(next.force_idr);
}

#[test]
fn an_empty_encode_reopens_the_gate_and_silence_is_measured() {
    let mut e = engine();
    let first = e.start(0).expect("first");
    let out = e.encoded(&first, None, 0).expect("ok");
    assert!(out.datagrams.is_empty());
    assert!(e.damage(0, Rect { x: 0, y: 0, width: 2, height: 2 }, 20_000).is_some());
    assert_eq!(e.silent_for_us(3_000_000), 3_000_000);
    e.on_datagram(&feedback(&Feedback::default()), true, 3_000_000);
    assert_eq!(e.silent_for_us(3_000_010), 10);
}

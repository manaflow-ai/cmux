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
    e.encoded(
        req,
        Some(Encoded { access_unit: au(len), idr, t_capture_us: now, ltr_token: None }),
        now,
    )
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
fn loss_after_an_acknowledged_ltr_requests_refresh_instead_of_idr() {
    let mut e = MediaEngine::new(
        EngineConfig { width: 640, height: 480, ltr_enabled: true, ..EngineConfig::default() },
        0,
    );
    let first = e.start(0).expect("first");
    let mut encoded =
        Encoded { access_unit: au(1_000), idr: true, t_capture_us: 0, ltr_token: Some(7) };
    e.encoded(&first, Some(encoded.clone()), 0).expect("first packet");
    let out = e.on_datagram(
        &feedback(&Feedback {
            acked_frame: first.frame,
            acked_ltr_tokens: vec![7],
            need_recovery: true,
            ..Feedback::default()
        }),
        true,
        30_000,
    );
    let recovery = out.encode.expect("loss asks for recovery");
    assert!(recovery.force_ltr_refresh);
    assert!(!recovery.force_idr);
    encoded =
        Encoded { access_unit: au(900), idr: false, t_capture_us: 30_000, ltr_token: Some(8) };
    let packets = e.encoded(&recovery, Some(encoded), 30_000).expect("recovery packet");
    let (header, payload) = DatagramHeader::decode(&packets.datagrams[0]).expect("header");
    assert_ne!(header.flags & flags::RECOVERY, 0);
    let body = cmux_rd_proto::FrameBody::decode(payload).expect("body");
    assert_eq!(body.ref_frame, first.frame);
}

#[test]
fn a_viewer_without_ltr_gets_frames_in_the_plain_layout() {
    // VideoToolbox hands back an LTR token whenever the OS has LTR; a viewer that did not
    // negotiate it reads the 16-byte prefix, so the token must not reach the wire.
    let mut e = MediaEngine::new(
        EngineConfig { width: 640, height: 480, ltr_enabled: false, ..EngineConfig::default() },
        0,
    );
    let first = e.start(0).expect("first");
    let access_unit = au(200);
    let encoded = Encoded {
        access_unit: access_unit.clone(),
        idr: true,
        t_capture_us: 0,
        ltr_token: Some(7),
    };
    let packets = e.encoded(&first, Some(encoded), 0).expect("packet");
    let (_, payload) = DatagramHeader::decode(&packets.datagrams[0]).expect("header");
    assert_eq!(
        payload.get(cmux_rd_proto::FRAME_PREFIX_LEN..cmux_rd_proto::FRAME_PREFIX_LEN + 4),
        access_unit.get(..4),
        "the access unit starts right after the plain prefix"
    );
    let body = cmux_rd_proto::FrameBody::decode(payload).expect("body");
    assert_eq!(body.ltr_token, None);
    assert_eq!(body.access_unit, access_unit);
}

#[test]
fn changing_frames_in_flight_updates_every_live_stream() {
    let mut e = engine();
    const POPUP: u16 = 3;
    let damage = Rect { x: 1, y: 1, width: 10, height: 10 };
    e.add_stream(POPUP, 200, 100).expect("popup");

    let main = e.start(0).expect("main");
    send(&mut e, &main, true, 1_000, 0);
    let popup = e.damage(POPUP, damage, 0).expect("popup");
    send(&mut e, &popup, true, 1_000, 0);

    e.set_frames_in_flight(2);
    assert!(e.damage(0, damage, 20_000).is_some(), "main gate updated");
    assert!(e.damage(POPUP, damage, 20_000).is_some(), "popup gate updated");
}

#[test]
fn cumulative_frame_ack_measures_rtt_for_socket_carriers() {
    let mut e = engine();
    let first = e.start(1_000).expect("first");
    send(&mut e, &first, true, 1_000, 1_000);
    assert_eq!(e.ack_rtt_us(), None);

    e.on_datagram(
        &feedback(&Feedback { acked_frame: first.frame, ..Feedback::default() }),
        true,
        51_000,
    );
    assert_eq!(e.ack_rtt_us(), Some(50_000));
}

#[test]
fn ack_rtt_tracks_a_slower_path_after_old_samples_expire() {
    let mut e = engine();
    let first = e.start(0).expect("first");
    send(&mut e, &first, true, 1_000, 0);
    e.on_datagram(
        &feedback(&Feedback { acked_frame: first.frame, ..Feedback::default() }),
        true,
        10_000,
    );
    assert_eq!(e.ack_rtt_us(), Some(10_000));

    let next = e
        .damage(0, Rect { x: 0, y: 0, width: 8, height: 8 }, 2_000_000)
        .expect("frame after the path slows");
    send(&mut e, &next, false, 1_000, 2_000_000);
    e.on_datagram(
        &feedback(&Feedback { acked_frame: next.frame, ..Feedback::default() }),
        true,
        2_050_000,
    );
    assert_eq!(e.ack_rtt_us(), Some(50_000), "the old short path must age out");
}

#[test]
fn repeated_and_reordered_acks_do_not_refresh_rtt_samples() {
    let mut e = engine();
    e.set_frames_in_flight(2);
    let first = e.start(0).expect("first");
    send(&mut e, &first, true, 1_000, 0);
    let second = e.damage(0, Rect { x: 0, y: 0, width: 8, height: 8 }, 20_000).expect("second");
    send(&mut e, &second, false, 1_000, 20_000);
    e.on_datagram(
        &feedback(&Feedback { acked_frame: second.frame, ..Feedback::default() }),
        true,
        70_000,
    );
    assert_eq!(e.ack_rtt_us(), Some(50_000));
    for (frame, now) in [(first.frame, 2_000_000), (second.frame, 3_000_000)] {
        e.on_datagram(
            &feedback(&Feedback { acked_frame: frame, ..Feedback::default() }),
            true,
            now,
        );
        assert_eq!(e.ack_rtt_us(), Some(50_000), "old ACKs are not new samples");
    }
}

#[test]
fn carrier_rtt_survives_later_acks_and_updates_existing_and_new_streams() {
    let mut e = engine();
    let first = e.start(0).expect("first");
    send(&mut e, &first, true, 1_000, 0);
    e.on_datagram(
        &feedback(&Feedback { acked_frame: first.frame, ..Feedback::default() }),
        true,
        10_000,
    );
    e.update_frames_in_flight_from_rtt(Some(10_000));
    e.update_frames_in_flight_from_rtt(Some(50_000));
    e.update_frames_in_flight_from_rtt(Some(50_000));
    assert_eq!(e.ack_rtt_us(), Some(10_000), "older fallback is still present");
    e.add_stream(3, 200, 100).expect("new popup inherits the window");
    let damage = Rect { x: 0, y: 0, width: 8, height: 8 };
    for i in 1..=5 {
        for stream in [0, 3] {
            let req = e
                .damage(stream, damage, i * 20_000)
                .expect("five frames fit the measured path despite the old ACK");
            send(&mut e, &req, i == 1, 1_000, i * 20_000);
        }
        e.update_frames_in_flight_from_rtt(Some(50_000));
    }
    for stream in [0, 3] {
        assert!(e.damage(stream, damage, 120_000).is_none(), "window stays bounded");
    }
}

#[test]
fn socket_fallback_replaces_the_old_link_window_with_ack_rtt() {
    let mut e = engine();
    e.update_frames_in_flight_from_rtt(Some(10_000));
    let first = e.start(0).expect("first");
    send(&mut e, &first, true, 1_000, 0);
    e.on_datagram(
        &feedback(&Feedback { acked_frame: first.frame, ..Feedback::default() }),
        true,
        50_000,
    );
    // The carrier's current route is a socket: it no longer has a link RTT.
    e.update_frames_in_flight_from_rtt(None);
    for i in 1..=5 {
        let now = 50_000 + i * 20_000;
        let req = e
            .damage(0, Rect { x: 0, y: 0, width: 8, height: 8 }, now)
            .expect("socket ACK RTT opens five slots despite the former short link");
        send(&mut e, &req, false, 1_000, now);
    }
    assert!(e.damage(0, Rect { x: 0, y: 0, width: 8, height: 8 }, 170_000).is_none());
}

#[test]
fn bdp_window_covers_a_fifty_ms_path_at_sixty_fps() {
    // Four frame intervals cover the 50 ms RTT; the helper adds one frame
    // that is being encoded while the earlier frames await acknowledgement.
    assert_eq!(cmux_rd_engine::frames_in_flight_for(50_000, 60), 5);
    assert_eq!(cmux_rd_engine::frames_in_flight_for(50_000, 30), 3);
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
        .encoded(
            &first,
            Some(Encoded { access_unit: au(300_000), idr: true, t_capture_us: 0, ltr_token: None }),
            0,
        )
        .expect("ok");
    assert!(out.datagrams.is_empty());
    assert!(out.halve_bitrate);
    let next =
        e.damage(0, Rect { x: 0, y: 0, width: 1, height: 1 }, 20_000).expect("gate open again");
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

#[test]
fn with_input_frame_now_an_injected_input_lifts_the_frame_rate_cap() {
    for on in [false, true] {
        let mut e = MediaEngine::new(
            EngineConfig {
                width: 640,
                height: 480,
                max_fps: 60,
                frames_in_flight: 4,
                input_frame_now: on,
                ..EngineConfig::default()
            },
            0,
        );
        let r = Rect { x: 0, y: 0, width: 8, height: 8 };
        assert!(e.damage(0, r, 0).is_some());
        let packet =
            InputPacket { first_seq: 1, events: vec![InputEvent::Key { usage: 4, down: true }] };
        assert_eq!(e.on_datagram(&input(&packet), true, 1_000).inject, packet.events);
        // 5 ms after the last frame: inside the 60 fps interval, so only the input lets it go.
        assert_eq!(e.damage(0, r, 5_000).is_some(), on, "input_frame_now {on}");
    }
}

#[test]
fn a_frame_lost_whole_is_resent_then_recovered_from_a_keyframe() {
    use cmux_rd_engine::{TAIL_PROBE_US, TAIL_PROBES};
    let mut e = engine();
    let first = e.start(0).expect("first");
    send(&mut e, &first, true, 1_000, 0);
    e.on_datagram(
        &feedback(&Feedback { acked_frame: first.frame, ..Feedback::default() }),
        true,
        10_000,
    );
    // A small P-frame of one datagram, which the path loses: the viewer sees nothing of it.
    let small = Rect { x: 1, y: 1, width: 10, height: 10 };
    let p = e.damage(0, small, 20_000).expect("second frame");
    let lost = send(&mut e, &p, false, 100, 20_000);
    assert_eq!(lost.len(), 1);
    assert!(
        e.tick(true, 20_000 + TAIL_PROBE_US - 1).datagrams.is_empty(),
        "no probe before its time"
    );
    assert_eq!(e.next_deadline_us(), Some(20_000 + TAIL_PROBE_US));
    let mut now = 20_000;
    for _ in 0..TAIL_PROBES {
        now += TAIL_PROBE_US;
        let out = e.tick(true, now);
        assert_eq!(out.datagrams, lost, "the unacknowledged frame is resent");
        assert!(out.encode.is_none());
    }
    // Every probe lost too: the gate opens for a keyframe instead of waiting forever.
    now += TAIL_PROBE_US;
    let out = e.tick(true, now);
    let idr = out.encode.expect("a recovery frame");
    assert!(idr.force_idr);
    send(&mut e, &idr, true, 1_000, now);
    e.on_datagram(
        &feedback(&Feedback { acked_frame: idr.frame, ..Feedback::default() }),
        true,
        now + 10_000,
    );
    assert!(
        e.tick(true, now + 10 * TAIL_PROBE_US).datagrams.is_empty(),
        "an acknowledged stream never probes"
    );
}

#[test]
fn repaired_shard_delay_does_not_collapse_the_media_bitrate() {
    use cmux_rd_proto::Arrival;
    for tail_probe in [false, true] {
        let mut e = engine();
        let first = e.start(0).expect("first");
        let sent = send(&mut e, &first, true, 6_000, 0);
        let last = sent.len() - 1;
        let arrivals = sent[..last]
            .iter()
            .map(|d| Arrival {
                transport_seq: DatagramHeader::decode(d).expect("header").0.transport_seq,
                arrival_us: 25_000,
            })
            .collect();
        let nacks = if tail_probe {
            vec![]
        } else {
            vec![Nack { frame: first.frame, indexes: vec![last as u16] }]
        };
        let requested = e.on_datagram(
            &feedback(&Feedback { arrivals, nacks, ..Feedback::default() }),
            false,
            50_000,
        );
        let initial_bps = e.stats().target_bps;
        let (resent, received) = if tail_probe {
            (e.tick(false, 250_000).datagrams, 275_000)
        } else {
            (requested.datagrams, 75_000)
        };
        assert!(resent.iter().any(|d| d == &sent[last]));
        let transport_seq = DatagramHeader::decode(&sent[last]).expect("header").0.transport_seq;
        e.on_datagram(
            &feedback(&Feedback {
                acked_frame: first.frame,
                arrivals: vec![Arrival { transport_seq, arrival_us: received }],
                ..Feedback::default()
            }),
            false,
            u64::from(received) + 25_000,
        );
        assert_eq!(
            e.stats().target_bps,
            initial_bps,
            "repair keeps a 25 ms path: tail_probe={tail_probe}"
        );
    }
}

#[test]
fn a_small_feedback_batch_does_not_turn_two_percent_loss_into_congestion() {
    use cmux_rd_proto::Arrival;
    let mut e = engine();
    let first = e.start(0).expect("first");
    let sent = send(&mut e, &first, true, 100_000, 0);
    let start = e.stats().target_bps;
    let arrivals: Vec<_> = sent
        .iter()
        .enumerate()
        .filter(|(i, _)| *i != 2 && *i != 50)
        .map(|(_, d)| Arrival {
            transport_seq: DatagramHeader::decode(d).expect("header").0.transport_seq,
            arrival_us: 25_000,
        })
        .collect();
    // This first receipt has one missing shard out of four. Across the whole
    // frame there are only two losses; feedback batching must not change capacity.
    e.on_datagram(
        &feedback(&Feedback { arrivals: arrivals[..3].to_vec(), ..Feedback::default() }),
        false,
        50_000,
    );
    assert_eq!(e.stats().target_bps, start, "three arrivals cannot establish sustained heavy loss");
    e.on_datagram(
        &feedback(&Feedback { arrivals: arrivals[3..].to_vec(), ..Feedback::default() }),
        false,
        60_000,
    );
    // Settle both receipt batches, then consume a complete congestion window.
    e.on_datagram(&feedback(&Feedback::default()), false, 160_000);
    e.on_datagram(&feedback(&Feedback::default()), false, 660_000);
    assert!(e.stats().target_bps >= start, "two percent loss stays below the congestion threshold");
}

#[test]
fn the_host_holds_the_viewers_newest_ltr_set_and_drops_it_after_a_reset() {
    let mut e = MediaEngine::new(
        EngineConfig { width: 640, height: 480, ltr_enabled: true, ..EngineConfig::default() },
        0,
    );
    let first = e.start(0).expect("first");
    let encoded =
        Encoded { access_unit: au(1_000), idr: true, t_capture_us: 0, ltr_token: Some(1) };
    e.encoded(&first, Some(encoded), 0).expect("first packet");
    // Two feedbacks: the viewer's set after 16 LTR frames, then after 4 more (it keeps its newest 16).
    let older: Vec<u64> = (1..=16).collect();
    let newer: Vec<u64> = (5..=20).collect();
    for (at, tokens) in [(10_000, older), (20_000, newer.clone())] {
        let fb =
            Feedback { acked_frame: first.frame, acked_ltr_tokens: tokens, ..Feedback::default() };
        e.on_datagram(&feedback(&fb), true, at);
    }
    let fb = Feedback { acked_frame: first.frame, need_recovery: true, ..newer_fb(&newer) };
    let recovery = e.on_datagram(&feedback(&fb), true, 30_000).encode.expect("recovery");
    assert_eq!(recovery.acknowledged_ltr_tokens, newer, "the newest 16, not the oldest");
    // The viewer's decoder reset: acked frame 0 and no tokens. No later refresh may name old ones.
    let reset = Feedback { need_recovery: true, ..Feedback::default() };
    let out = e.on_datagram(&feedback(&reset), true, 2_000_000);
    let keyframe = out.encode.expect("a reset asks for a keyframe");
    assert!(keyframe.acknowledged_ltr_tokens.is_empty(), "{:?}", keyframe.acknowledged_ltr_tokens);
    assert!(!keyframe.force_ltr_refresh);
}

fn newer_fb(tokens: &[u64]) -> Feedback {
    Feedback { acked_ltr_tokens: tokens.to_vec(), ..Feedback::default() }
}

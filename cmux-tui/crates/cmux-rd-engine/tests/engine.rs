//! The media engine every rd source shares (rd change C7 step 2): requests
//! encodes from damage under the one-frame-in-flight gate, packetizes with
//! FEC, resends NACKed shards from a bounded history, recovers on request
//! (rate-limited), and applies input exactly once with acks.

use cmux_rd_core::flow::Rect;
use cmux_rd_engine::{EncodeProfile, EncodeRequest, Encoded, EngineConfig, MediaEngine};
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

/// A source encodes asynchronously: a recovery request can arrive while an
/// older P-frame request is still in its encoder. That P-frame must not
/// answer the recovery; the next request is the keyframe.
#[test]
fn a_recovery_that_arrives_while_a_p_frame_is_encoding_still_gets_its_keyframe() {
    let mut e = engine();
    let first = e.start(0).expect("first");
    send(&mut e, &first, true, 500, 0);
    let ack = feedback(&Feedback { acked_frame: first.frame, ..Feedback::default() });
    e.on_datagram(&ack, true, 20_000);
    let p =
        e.damage(0, Rect { x: 0, y: 0, width: 8, height: 8 }, 300_000).expect("a P-frame request");
    assert!(!p.force_idr);
    // The viewer asks for recovery while that P-frame is in the encoder.
    let ask = feedback(&Feedback {
        acked_frame: first.frame,
        need_recovery: true,
        ..Feedback::default()
    });
    // The frame-rate cap holds the keyframe for a moment.
    assert!(e.on_datagram(&ask, true, 301_000).encode.is_none());
    send(&mut e, &p, false, 500, 302_000);
    let next =
        e.damage(0, Rect { x: 0, y: 0, width: 8, height: 8 }, 340_000).expect("the next request");
    assert!(next.force_idr, "the recovery was answered by a P-frame requested before it");
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
    // A small P-frame of one datagram and, on this idle link, its copy, which the path
    // loses both of: the viewer sees nothing of it.
    let small = Rect { x: 1, y: 1, width: 10, height: 10 };
    let p = e.damage(0, small, 20_000).expect("second frame");
    let lost = send(&mut e, &p, false, 100, 20_000);
    assert_eq!(lost.len(), 2);
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

/// A typing-sized frame on a nearly idle link goes out twice (its one data shard
/// and a parity copy), so losing either copy costs no tail-probe wait: the
/// viewer rebuilds the frame from the one that arrived. On a Mac pair over a
/// clean LAN, 11 of 300 key presses lost such a frame's only copy, and each
/// waited the whole probe interval.
#[test]
fn a_small_frame_on_an_idle_link_goes_out_twice_and_survives_losing_a_copy() {
    use cmux_rd_core::reassembly::Reassembler;
    let mut e = engine();
    let mut viewer = Reassembler::new(500_000);
    let first = e.start(0).expect("first");
    for d in send(&mut e, &first, true, 1_000, 0) {
        let (h, payload) = DatagramHeader::decode(&d).expect("header");
        viewer.push(&h, payload, 1_000);
    }
    assert_eq!(viewer.last_released(), first.frame);
    e.on_datagram(
        &feedback(&Feedback { acked_frame: first.frame, ..Feedback::default() }),
        true,
        10_000,
    );
    let small = Rect { x: 1, y: 1, width: 10, height: 10 };
    let p = e.damage(0, small, 20_000).expect("second frame");
    let sent = send(&mut e, &p, false, 100, 20_000);
    assert_eq!(sent.len(), 2, "a small frame on an idle link is sent twice");
    // The data datagram is lost; the copy alone gives the viewer the frame.
    let copy = sent.last().expect("copy");
    let (h, payload) = DatagramHeader::decode(copy).expect("header");
    assert_eq!(h.kind, DatagramKind::Fec);
    let released = viewer.push(&h, payload, 21_000);
    assert_eq!(released.iter().map(|f| f.frame).collect::<Vec<_>>(), vec![p.frame]);
}

/// The copy is spent only while the link is nearly idle: while the last
/// second's sends pass 1 % of the target, a small frame goes out once.
#[test]
fn a_small_frame_on_a_busy_link_goes_out_once() {
    let mut e = engine();
    let first = e.start(0).expect("first");
    // 40 KB in the last second is far over 1 % of the 8 Mbps starting target.
    send(&mut e, &first, true, 40_000, 0);
    e.on_datagram(
        &feedback(&Feedback { acked_frame: first.frame, ..Feedback::default() }),
        true,
        10_000,
    );
    let small = Rect { x: 1, y: 1, width: 10, height: 10 };
    let p = e.damage(0, small, 20_000).expect("second frame");
    assert_eq!(send(&mut e, &p, false, 100, 20_000).len(), 1);
    e.on_datagram(
        &feedback(&Feedback { acked_frame: p.frame, ..Feedback::default() }),
        true,
        30_000,
    );
    // A second later the keyframe has left the window: the link is idle again.
    let q = e.damage(0, small, 1_100_000).expect("third frame");
    assert_eq!(send(&mut e, &q, false, 100, 1_100_000).len(), 2);
}

#[test]
fn a_frame_the_encoder_dropped_is_encoded_again_with_no_new_damage() {
    // A dropped frame's change has to reach the viewer even when nothing else moves on
    // screen; before, it stayed unsent until other damage came, a stuck region.
    let mut e = engine();
    let first = e.start(0).expect("first");
    let out = e.encoded(&first, None, 0).expect("ok");
    assert!(out.datagrams.is_empty());
    let due = e.next_deadline_us().expect("the dropped frame waits for its slot");
    let again = e.poll(due.max(20_000)).expect("the dropped frame's damage is encoded again");
    assert_eq!(again.damage, first.damage, "the same change, with no new damage");
    assert!(again.force_idr, "the dropped keyframe is still a keyframe");
}

#[test]
fn a_recovery_request_with_damage_pending_hands_out_one_keyframe() {
    // Damage waits in the gate (here: a frame the encoder dropped) when the viewer asks for
    // recovery. The ack used to hand that damage a frame number and the keyframe's own poll
    // then answered Wait over it, so the frame was never encoded and no keyframe went out.
    let mut e = engine();
    let first = e.start(0).expect("first");
    let _ = e.encoded(&first, None, 0).expect("ok");
    let fb = Feedback { need_recovery: true, ..Feedback::default() };
    let out = e.on_datagram(&feedback(&fb), true, 40_000);
    let recovery = out.encode.expect("the recovery keyframe is requested");
    assert!(recovery.force_idr);
    assert_eq!(recovery.damage, first.damage, "the whole surface");
    assert!(e.poll(80_000).is_none(), "one frame, not a second one for the same damage");
}

#[test]
fn an_outage_end_holds_the_rate_and_stops_waiting_for_stale_acks() {
    use cmux_rd_proto::Arrival;
    let mut e = engine();
    let arrived = |sent: &[Vec<u8>], at: u32| -> Vec<Arrival> {
        sent.iter()
            .map(|d| Arrival {
                transport_seq: DatagramHeader::decode(d).expect("header").0.transport_seq,
                arrival_us: at,
            })
            .collect()
    };
    // The path works: the first frame is answered in 10 ms.
    let first = e.start(0).expect("first");
    let sent = send(&mut e, &first, true, 6_000, 0);
    let arrivals = arrived(&sent, 5_000);
    let out = e.on_datagram(
        &feedback(&Feedback { acked_frame: first.frame, arrivals, ..Feedback::default() }),
        false,
        10_000,
    );
    assert!(out.outage_ended.is_none(), "a prompt first feedback is not an outage");
    let small = Rect { x: 1, y: 1, width: 10, height: 10 };
    let second = e.damage(0, small, 20_000).expect("second");
    let sent = send(&mut e, &second, false, 6_000, 20_000);
    let start = e.stats().target_bps;
    // Then the radio was away for 400 ms; everything arrives at once when it is back.
    let arrivals = arrived(&sent, 420_000);
    let out =
        e.on_datagram(&feedback(&Feedback { arrivals, ..Feedback::default() }), false, 424_000);
    let end = out.outage_ended.expect("the host learns the outage ended");
    assert!(end.silent_us > 100_000, "{end:?}");
    assert_eq!(e.stats().target_bps, start, "an outage is not congestion");
    assert!(e.damage(0, small, 425_000).is_some(), "the gate no longer waits for the stale frame");
}

/// D12 drop: an engine whose path worked (a keyframe of `keyframe` bytes answered in
/// 10 ms) and that then sent a P-frame of `started` bytes whose first 8 datagrams left
/// before the radio went away, and a P-frame of `unstarted` bytes that never left.
/// Returns the output that ends the outage, both frames' requests and datagrams.
#[allow(clippy::type_complexity)]
fn outage_with_queue(
    keyframe: usize,
    started: usize,
    unstarted: usize,
) -> (MediaEngine, cmux_rd_engine::Output, [(EncodeRequest, Vec<Vec<u8>>); 2]) {
    let mut e = MediaEngine::new(
        EngineConfig {
            width: 640,
            height: 480,
            max_fps: 60,
            frames_in_flight: 3,
            ..EngineConfig::default()
        },
        0,
    );
    let start = e.start(0).expect("start");
    let sent = send(&mut e, &start, true, keyframe, 0);
    let arrivals = arrived(&sent, 5_000);
    e.on_datagram(
        &feedback(&Feedback { acked_frame: start.frame, arrivals, ..Feedback::default() }),
        false,
        10_000,
    );
    let small = Rect { x: 1, y: 1, width: 10, height: 10 };
    let a = e.damage(0, small, 20_000).expect("frame a");
    let sent_a = send(&mut e, &a, false, started, 20_000);
    let b = e.damage(0, small, 40_000).or_else(|| e.poll(40_000)).expect("frame b");
    let sent_b = send(&mut e, &b, false, unstarted, 40_000);
    let out = e.on_datagram(
        &feedback(&Feedback { arrivals: arrived(&sent_a[..8], 420_000), ..Feedback::default() }),
        false,
        424_000,
    );
    assert!(out.outage_ended.is_some());
    (e, out, [(a, sent_a), (b, sent_b)])
}

fn arrived(sent: &[Vec<u8>], at: u32) -> Vec<cmux_rd_proto::Arrival> {
    sent.iter()
        .map(|d| cmux_rd_proto::Arrival {
            transport_seq: DatagramHeader::decode(d).expect("header").0.transport_seq,
            arrival_us: at,
        })
        .collect()
}

#[test]
fn an_outage_end_drops_unstarted_frames_larger_than_a_keyframe_and_not_a_started_one() {
    let (mut e, mut out, [(a, sent_a), (b, sent_b)]) = outage_with_queue(2_000, 30_000, 30_000);
    let queue: Vec<&[u8]> = sent_a[8..].iter().chain(&sent_b).map(Vec::as_slice).collect();
    let plan = e.outage_drop_plan(queue, &out);
    assert_eq!(
        plan.into_iter().collect::<Vec<_>>(),
        vec![(0, b.frame)],
        "only the unstarted frame"
    );
    e.retire_unsent(&sent_b, &mut out, 424_000);
    let next = out.encode.clone().expect("the newest picture is asked for at once");
    assert!(next.force_idr, "the next frame would predict from the dropped one: {next:?}");
    // The viewer asks for the dropped frame's shards: nothing is resent.
    let nack = Nack { frame: b.frame, indexes: (0..8).collect() };
    let resent = e.on_datagram(
        &feedback(&Feedback { nacks: vec![nack], ..Feedback::default() }),
        false,
        430_000,
    );
    assert!(resent.datagrams.is_empty(), "resent shards of a dropped frame");
    // The started frame finishes and the keyframe follows; the dropped datagrams settle
    // as nothing.
    let fresh = send(&mut e, &next, true, 2_000, 440_000);
    let rest: Vec<Vec<u8>> = sent_a[8..].iter().chain(&fresh).cloned().collect();
    e.on_datagram(
        &feedback(&Feedback {
            acked_frame: a.frame,
            arrivals: arrived(&rest, 440_000),
            ..Feedback::default()
        }),
        false,
        445_000,
    );
    e.on_datagram(&feedback(&Feedback::default()), false, 620_000);
    assert_eq!(e.stats().loss, 0.0, "datagrams that never left read as loss");
}

#[test]
fn an_outage_end_keeps_unstarted_frames_smaller_than_a_keyframe() {
    let (e, out, [(_, sent_a), (_, sent_b)]) = outage_with_queue(60_000, 12_000, 3_000);
    let queue: Vec<&[u8]> = sent_a[8..].iter().chain(&sent_b).map(Vec::as_slice).collect();
    assert!(e.outage_drop_plan(queue, &out).is_empty(), "a keyframe costs more than the queue");
    assert!(out.encode.is_none_or(|r| !r.force_idr), "no keyframe without a drop");
}

/// D12 + D6: while the path is away (the window after a hold until a datagram sent
/// after it arrives) only the newest frame is repaired: an older frame's resend would
/// land in the hold's burst, but the newest frame (a key press's echo) is what the viewer
/// waits on. Once the path is up, older frames are repaired too.
#[test]
fn only_the_newest_frame_is_repaired_while_the_path_is_away() {
    use cmux_rd_proto::Arrival;
    let mut e = engine();
    let arrived = |sent: &[Vec<u8>], at: u32| -> Vec<Arrival> {
        sent.iter()
            .map(|d| Arrival {
                transport_seq: DatagramHeader::decode(d).expect("header").0.transport_seq,
                arrival_us: at,
            })
            .collect()
    };
    let first = e.start(0).expect("first");
    let sent_first = send(&mut e, &first, true, 6_000, 0);
    e.on_datagram(
        &feedback(&Feedback {
            acked_frame: first.frame,
            arrivals: arrived(&sent_first, 5_000),
            ..Feedback::default()
        }),
        false,
        10_000,
    );
    let small = Rect { x: 1, y: 1, width: 10, height: 10 };
    let second = e.damage(0, small, 20_000).expect("second");
    let sent = send(&mut e, &second, false, 6_000, 20_000);
    // The radio was away for 400 ms; the head of the newest frame arrives at once and
    // the viewer asks for its rest, and for a shard of the older frame.
    let older = Nack { frame: first.frame, indexes: vec![1] };
    let newest = Nack { frame: second.frame, indexes: vec![2, 3] };
    let out = e.on_datagram(
        &feedback(&Feedback {
            arrivals: arrived(&sent[..2], 420_000),
            nacks: vec![older.clone(), newest],
            ..Feedback::default()
        }),
        false,
        424_000,
    );
    assert!(out.outage_ended.is_some());
    let resent: Vec<u32> =
        out.datagrams.iter().map(|d| DatagramHeader::decode(d).expect("header").0.frame).collect();
    assert_eq!(resent, vec![second.frame, second.frame], "only the newest frame, at once");
    // A datagram sent after the outage arrives: the path is up, older frames are repaired.
    let third = e.damage(0, small, 430_000).expect("third");
    let fresh = send(&mut e, &third, false, 500, 430_000);
    let out = e.on_datagram(
        &feedback(&Feedback {
            arrivals: arrived(&fresh, 435_000),
            nacks: vec![older],
            ..Feedback::default()
        }),
        false,
        440_000,
    );
    assert_eq!(out.datagrams.len(), 1, "the older frame is repaired once the path is back");
}

/// D12: a recovery ask during the hold's first feedback waits for the path (the viewer
/// keeps asking); it is answered with a keyframe once the path is up.
#[test]
fn no_recovery_keyframe_while_the_path_is_away() {
    use cmux_rd_proto::Arrival;
    let mut e = engine();
    let arrived = |sent: &[Vec<u8>], at: u32| -> Vec<Arrival> {
        sent.iter()
            .map(|d| Arrival {
                transport_seq: DatagramHeader::decode(d).expect("header").0.transport_seq,
                arrival_us: at,
            })
            .collect()
    };
    let first = e.start(0).expect("first");
    let sent = send(&mut e, &first, true, 1_000, 0);
    e.on_datagram(
        &feedback(&Feedback {
            acked_frame: first.frame,
            arrivals: arrived(&sent, 5_000),
            ..Feedback::default()
        }),
        false,
        10_000,
    );
    let small = Rect { x: 1, y: 1, width: 10, height: 10 };
    let second = e.damage(0, small, 20_000).expect("second");
    let sent = send(&mut e, &second, false, 6_000, 20_000);
    let out = e.on_datagram(
        &feedback(&Feedback {
            arrivals: arrived(&sent[..2], 420_000),
            need_recovery: true,
            ..Feedback::default()
        }),
        false,
        424_000,
    );
    assert!(out.outage_ended.is_some());
    assert!(out.encode.as_ref().is_none_or(|r| !r.force_idr), "a keyframe into the hold: {out:?}");
    // A frame sent after the outage (the one the outage end asked for, or new damage).
    let next =
        out.encode.or_else(|| e.damage(0, small, 430_000)).expect("a frame after the outage");
    let fresh = send(&mut e, &next, false, 500, 430_000);
    let newest = DatagramHeader::decode(&fresh[0]).expect("header").0.frame;
    let out = e.on_datagram(
        &feedback(&Feedback {
            arrivals: arrived(&fresh, 435_000),
            acked_frame: newest,
            need_recovery: true,
            ..Feedback::default()
        }),
        false,
        450_000,
    );
    let req = out.encode.expect("the recovery ask is answered once the path is back");
    assert!(req.force_idr);
}

fn ack(e: &mut MediaEngine, frame: u32, now: u64) -> Option<EncodeRequest> {
    e.on_datagram(&feedback(&Feedback { acked_frame: frame, ..Feedback::default() }), true, now)
        .encode
}

#[test]
fn standard_never_refines_and_carries_its_profile() {
    let mut e = engine();
    assert_eq!(e.profile(), EncodeProfile::Standard, "standard is the default");
    let first = e.start(0).expect("first");
    assert_eq!(first.profile, EncodeProfile::Standard);
    assert!(!first.refine);
    send(&mut e, &first, true, 1_000, 0);
    assert!(ack(&mut e, first.frame, 5_000).is_none());
    assert!(e.poll(1_000_000).is_none(), "a still screen sends nothing on standard");
    assert_eq!(e.next_deadline_us(), None, "and needs no wakeup");
}

#[test]
fn ultra_refines_a_still_screen_within_two_frames() {
    let mut e = engine();
    e.set_profile(EncodeProfile::Ultra);
    let first = e.start(0).expect("first");
    assert_eq!(first.profile, EncodeProfile::Ultra);
    assert!(!first.refine, "the keyframe is not a refinement");
    send(&mut e, &first, true, 1_000, 0);
    assert!(ack(&mut e, first.frame, 4_000).is_none());
    let small = Rect { x: 1, y: 1, width: 10, height: 10 };
    let typed = e.damage(0, small, 20_000).expect("damage frame");
    assert!(!typed.refine);
    send(&mut e, &typed, false, 500, 20_000);
    assert!(ack(&mut e, typed.frame, 24_000).is_none());
    // One frame interval (60 fps) after the last damage frame went out.
    let due = e.next_deadline_us().expect("a refinement is scheduled");
    assert_eq!(due, 20_000 + 16_666);
    assert!(e.poll(due - 1).is_none(), "not before it is due");
    let refine = e.poll(due).expect("the refinement frame");
    assert!(refine.refine && !refine.force_idr);
    assert_eq!(refine.frame, typed.frame + 1, "the next frame after the damage");
    assert_eq!(refine.damage, Rect { x: 0, y: 0, width: 640, height: 480 }, "the whole surface");
    send(&mut e, &refine, false, 4_000, due);
    assert!(ack(&mut e, refine.frame, due + 4_000).is_none());
    assert_eq!(e.next_deadline_us(), None, "one refinement, then quiet until new damage");
    assert!(e.poll(due + 1_000_000).is_none());
}

#[test]
fn new_damage_cancels_a_refinement_and_reschedules_it() {
    let mut e = engine();
    e.set_profile(EncodeProfile::Ultra);
    let first = e.start(0).expect("first");
    send(&mut e, &first, true, 1_000, 0);
    // Not acknowledged yet: the refinement waits on the in-flight bound, then damage joins.
    assert!(e.poll(16_666).is_none(), "the in-flight bound holds the refinement");
    let small = Rect { x: 1, y: 1, width: 10, height: 10 };
    assert!(e.damage(0, small, 18_000).is_none());
    let next = ack(&mut e, first.frame, 20_000).expect("ack releases the frame");
    assert!(!next.refine, "damage that joined a held refinement makes it an ordinary frame");
    send(&mut e, &next, false, 500, 20_000);
    let refine = ack(&mut e, next.frame, 21_000);
    assert!(refine.is_none(), "the refinement is not due yet");
    assert_eq!(e.next_deadline_us(), Some(20_000 + 16_666));
}

#[test]
fn leaving_ultra_drops_a_due_refinement() {
    let mut e = engine();
    e.set_profile(EncodeProfile::Ultra);
    let first = e.start(0).expect("first");
    send(&mut e, &first, true, 1_000, 0);
    assert!(ack(&mut e, first.frame, 4_000).is_none());
    assert!(e.next_deadline_us().is_some());
    e.set_profile(EncodeProfile::Standard);
    assert_eq!(e.next_deadline_us(), None);
    assert!(e.poll(1_000_000).is_none());
}

//! Reference frame invalidation (screen share P3): with LTR on, every path that starts a
//! stream over (the viewer's recovery ask, tail-probe exhaustion, an outage drop) sends a
//! refresh P-frame from a reference the viewer acknowledged as decoded instead of a
//! keyframe, and falls back to a keyframe when nothing is acknowledged, LTR is off, or the
//! refresh itself was lost.

use cmux_rd_core::flow::Rect;
use cmux_rd_engine::{
    EncodeRequest, Encoded, EngineConfig, IdrReason, MediaEngine, TAIL_PROBE_US, TAIL_PROBES,
};
use cmux_rd_proto::{Arrival, DatagramHeader, DatagramKind, Feedback, FrameBody, flags};

const SMALL: Rect = Rect { x: 1, y: 1, width: 10, height: 10 };

fn engine(ltr_enabled: bool, frames_in_flight: u32) -> MediaEngine {
    MediaEngine::new(
        EngineConfig {
            width: 640,
            height: 480,
            max_fps: 60,
            frames_in_flight,
            ltr_enabled,
            ..EngineConfig::default()
        },
        0,
    )
}

fn feedback(fb: &Feedback) -> Vec<u8> {
    let mut d = DatagramHeader {
        flags: 0,
        kind: DatagramKind::Feedback,
        stream: 0,
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

fn send(
    e: &mut MediaEngine,
    req: &EncodeRequest,
    idr: bool,
    len: usize,
    token: Option<u64>,
    now: u64,
) -> Vec<Vec<u8>> {
    let access_unit = (0..len).map(|i| i as u8).collect();
    e.encoded(req, Some(Encoded { access_unit, idr, t_capture_us: now, ltr_token: token }), now)
        .expect("encoded")
        .datagrams
}

fn arrived(sent: &[Vec<u8>], at: u32) -> Vec<Arrival> {
    sent.iter()
        .map(|d| Arrival {
            transport_seq: DatagramHeader::decode(d).expect("header").0.transport_seq,
            arrival_us: at,
        })
        .collect()
}

/// An engine whose first keyframe (LTR token 7) the viewer decoded and acknowledged at
/// 10 ms, with the token when `tokens`. Returns the engine and the keyframe's request.
fn acked_start(ltr_enabled: bool, tokens: bool) -> (MediaEngine, EncodeRequest) {
    let mut e = engine(ltr_enabled, 1);
    let start = e.start(0).expect("start");
    let sent = send(&mut e, &start, true, 1_000, Some(7), 0);
    let fb = Feedback {
        acked_frame: start.frame,
        acked_ltr_tokens: if tokens { vec![7] } else { Vec::new() },
        arrivals: arrived(&sent, 5_000),
        ..Feedback::default()
    };
    e.on_datagram(&feedback(&fb), true, 10_000);
    (e, start)
}

fn ask(acked_frame: u32, tokens: &[u64]) -> Feedback {
    Feedback {
        acked_frame,
        acked_ltr_tokens: tokens.to_vec(),
        need_recovery: true,
        ..Feedback::default()
    }
}

#[test]
fn recovery_with_acknowledged_tokens_is_a_refresh_not_a_keyframe() {
    let (mut e, start) = acked_start(true, true);
    let p = e.damage(0, SMALL, 20_000).expect("p");
    send(&mut e, &p, false, 200, None, 20_000);
    let req = e.on_datagram(&feedback(&ask(start.frame, &[7])), true, 40_000).encode;
    let req = req.expect("the ask is answered");
    assert!(req.force_ltr_refresh, "{req:?}");
    assert!(!req.force_idr && req.idr_reason.is_none(), "{req:?}");
    assert_eq!(req.acknowledged_ltr_tokens, vec![7]);
    let sent = send(&mut e, &req, false, 300, Some(8), 40_000);
    let (h, payload) = DatagramHeader::decode(&sent[0]).expect("header");
    assert_ne!(h.flags & flags::RECOVERY, 0);
    assert_eq!(h.flags & flags::KEYFRAME, 0);
    assert_eq!(FrameBody::decode(payload).expect("body").ref_frame, start.frame);
    assert_eq!(e.stats().keyframes, 1, "only the start keyframe");
    // The viewer decoded the refresh: a later loss is answered with a refresh again.
    let decoded = Feedback {
        acked_frame: req.frame,
        acked_ltr_tokens: vec![7, 8],
        arrivals: arrived(&sent, 45_000),
        ..Feedback::default()
    };
    assert!(e.on_datagram(&feedback(&decoded), true, 50_000).outage_ended.is_none());
    let fb = Feedback { acked_frame: req.frame, acked_ltr_tokens: vec![7, 8], ..ask(0, &[]) };
    let again = e.on_datagram(&feedback(&fb), true, 400_000).encode.expect("second ask");
    assert!(again.force_ltr_refresh && !again.force_idr, "{again:?}");
}

#[test]
fn recovery_without_tokens_or_with_ltr_off_is_a_keyframe() {
    for (ltr_enabled, tokens) in [(true, false), (false, true), (false, false)] {
        let (mut e, start) = acked_start(ltr_enabled, tokens);
        let acked: &[u64] = if tokens { &[7] } else { &[] };
        let req = e.on_datagram(&feedback(&ask(start.frame, acked)), true, 40_000).encode;
        let req = req.expect("the ask is answered");
        assert!(req.force_idr, "ltr {ltr_enabled} tokens {tokens}: {req:?}");
        assert_eq!(req.idr_reason, Some(IdrReason::Recovery));
        assert!(!req.force_ltr_refresh, "ltr {ltr_enabled} tokens {tokens}");
    }
    // A viewer that reset its decoder acknowledges frame 0: its old tokens are no reference.
    let (mut e, _) = acked_start(true, true);
    let req = e.on_datagram(&feedback(&ask(0, &[7])), true, 40_000).encode.expect("ask");
    assert!(req.force_idr && !req.force_ltr_refresh, "{req:?}");
}

#[test]
fn a_lost_refresh_falls_back_to_a_keyframe() {
    let (mut e, start) = acked_start(true, true);
    let refresh = e.on_datagram(&feedback(&ask(start.frame, &[7])), true, 40_000).encode;
    let refresh = refresh.expect("refresh");
    assert!(refresh.force_ltr_refresh);
    send(&mut e, &refresh, false, 300, Some(8), 40_000);
    // The viewer keeps asking while the refresh is on its way (within one round trip, and
    // within the forced-frame interval): nothing new.
    let early = e.on_datagram(&feedback(&ask(start.frame, &[7])), true, 45_000).encode;
    assert!(early.as_ref().is_none_or(|r| !r.force_idr && !r.force_ltr_refresh), "{early:?}");
    // One recovery interval on, it still has not decoded the refresh: it was lost.
    let late = e.on_datagram(&feedback(&ask(start.frame, &[7])), true, 300_000).encode;
    let late = late.expect("the second ask is answered");
    assert!(late.force_idr, "{late:?}");
    assert!(!late.force_ltr_refresh, "{late:?}");
    assert_eq!(late.idr_reason, Some(IdrReason::Recovery));
    let sent = send(&mut e, &late, true, 1_000, Some(9), 300_000);
    // After the keyframe is decoded, a new loss may be refreshed again.
    let decoded = Feedback {
        acked_frame: late.frame,
        acked_ltr_tokens: vec![9],
        arrivals: arrived(&sent, 305_000),
        ..Feedback::default()
    };
    e.on_datagram(&feedback(&decoded), true, 310_000);
    let fb = ask(late.frame, &[9]);
    let next = e.on_datagram(&feedback(&fb), true, 600_000).encode.expect("next ask");
    assert!(next.force_ltr_refresh && !next.force_idr, "{next:?}");
}

#[test]
fn tail_probe_exhaustion_with_tokens_is_a_refresh_and_a_lost_one_a_keyframe() {
    let (mut e, _) = acked_start(true, true);
    let p = e.damage(0, SMALL, 20_000).expect("p");
    send(&mut e, &p, false, 100, None, 20_000);
    let mut now = 20_000;
    for _ in 0..TAIL_PROBES {
        now += TAIL_PROBE_US;
        assert!(e.tick(true, now).encode.is_none());
    }
    now += TAIL_PROBE_US;
    let refresh = e.tick(true, now).encode.expect("a recovery frame");
    assert!(refresh.force_ltr_refresh, "{refresh:?}");
    assert!(!refresh.force_idr, "{refresh:?}");
    // The refresh is lost whole as well: after its probes the stream starts from a keyframe.
    send(&mut e, &refresh, false, 100, None, now);
    for _ in 0..TAIL_PROBES {
        now += TAIL_PROBE_US;
        assert!(e.tick(true, now).encode.is_none());
    }
    now += TAIL_PROBE_US;
    let idr = e.tick(true, now).encode.expect("a keyframe");
    assert!(idr.force_idr && !idr.force_ltr_refresh, "{idr:?}");
    assert_eq!(idr.idr_reason, Some(IdrReason::TailProbe));
}

#[test]
fn tail_probe_exhaustion_with_ltr_off_is_a_keyframe() {
    let (mut e, _) = acked_start(false, true);
    let p = e.damage(0, SMALL, 20_000).expect("p");
    send(&mut e, &p, false, 100, None, 20_000);
    let now = 20_000 + u64::from(TAIL_PROBES + 1) * TAIL_PROBE_US;
    let mut req = None;
    let mut t = 20_000;
    while t < now {
        t += TAIL_PROBE_US;
        req = e.tick(true, t).encode.or(req);
    }
    let req = req.expect("a keyframe");
    assert!(req.force_idr && !req.force_ltr_refresh, "{req:?}");
}

/// D12 with LTR: the unstarted frame is dropped (a refresh costs about one frame, so the
/// stale queue is never worth keeping) and the restart is a refresh, not a keyframe.
#[test]
fn an_outage_drop_restarts_from_a_refresh_when_the_viewer_acknowledged_a_reference() {
    for ltr_enabled in [true, false] {
        let mut e = engine(ltr_enabled, 3);
        let start = e.start(0).expect("start");
        // A big keyframe: without LTR, the small queue is kept rather than paying for one.
        let sent = send(&mut e, &start, true, 60_000, Some(7), 0);
        let fb = Feedback {
            acked_frame: start.frame,
            acked_ltr_tokens: vec![7],
            arrivals: arrived(&sent, 5_000),
            ..Feedback::default()
        };
        e.on_datagram(&feedback(&fb), false, 10_000);
        let a = e.damage(0, SMALL, 20_000).expect("frame a");
        let sent_a = send(&mut e, &a, false, 12_000, None, 20_000);
        let b = e.damage(0, SMALL, 40_000).or_else(|| e.poll(40_000)).expect("frame b");
        let sent_b = send(&mut e, &b, false, 3_000, None, 40_000);
        let fb = Feedback {
            acked_ltr_tokens: vec![7],
            arrivals: arrived(&sent_a[..8], 420_000),
            ..Feedback::default()
        };
        let mut out = e.on_datagram(&feedback(&fb), false, 424_000);
        assert!(out.outage_ended.is_some());
        let queue: Vec<&[u8]> = sent_a[8..].iter().chain(&sent_b).map(Vec::as_slice).collect();
        let plan = e.outage_drop_plan(queue, &out);
        if !ltr_enabled {
            assert!(plan.is_empty(), "a keyframe costs more than the queue");
            continue;
        }
        assert_eq!(plan.into_iter().collect::<Vec<_>>(), vec![(0, b.frame)]);
        e.retire_unsent(&sent_b, &mut out, 424_000);
        let next = out.encode.expect("the newest picture is asked for at once");
        assert!(next.force_ltr_refresh, "{next:?}");
        assert!(!next.force_idr, "{next:?}");
        assert_eq!(next.acknowledged_ltr_tokens, vec![7]);
    }
}

#[test]
fn an_outage_drop_without_tokens_is_a_keyframe() {
    let mut e = engine(true, 3);
    let start = e.start(0).expect("start");
    let sent = send(&mut e, &start, true, 2_000, None, 0);
    let fb = Feedback {
        acked_frame: start.frame,
        arrivals: arrived(&sent, 5_000),
        ..Feedback::default()
    };
    e.on_datagram(&feedback(&fb), false, 10_000);
    let a = e.damage(0, SMALL, 20_000).expect("frame a");
    let sent_a = send(&mut e, &a, false, 30_000, None, 20_000);
    let b = e.damage(0, SMALL, 40_000).or_else(|| e.poll(40_000)).expect("frame b");
    let sent_b = send(&mut e, &b, false, 30_000, None, 40_000);
    let fb = Feedback { arrivals: arrived(&sent_a[..8], 420_000), ..Feedback::default() };
    let mut out = e.on_datagram(&feedback(&fb), false, 424_000);
    e.retire_unsent(&sent_b, &mut out, 424_000);
    let next = out.encode.expect("restart");
    assert!(next.force_idr && !next.force_ltr_refresh, "{next:?}");
    assert_eq!(next.idr_reason, Some(IdrReason::Outage));
}

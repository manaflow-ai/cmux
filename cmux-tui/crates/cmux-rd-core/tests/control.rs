//! Flow control, input delivery, congestion control and the quality ladder.

use cmux_rd_core::cc::{CcConfig, CongestionController, PathKind, Usage};
use cmux_rd_core::flow::{FlowAction, FrameGate, Rect};
use cmux_rd_core::input::{InputApplier, InputSender, MAX_SENDS};
use cmux_rd_core::ladder::{ContentClass, LadderInput, choose};
use cmux_rd_proto::{Arrival, InputEvent};
use proptest::prelude::*;

const R: Rect = Rect { x: 0, y: 0, width: 10, height: 10 };

#[test]
fn gate_holds_one_frame_in_flight_and_coalesces_damage() {
    let mut g = FrameGate::new(1, 60);
    assert_eq!(g.damage(R, 0), FlowAction::Encode { damage: R, frame: 1 });
    // While frame 1 is unacknowledged, damage accumulates.
    assert_eq!(g.damage(Rect { x: 50, y: 50, width: 5, height: 5 }, 20_000), FlowAction::Wait);
    assert_eq!(g.damage(Rect { x: 5, y: 5, width: 5, height: 5 }, 21_000), FlowAction::Wait);
    assert_eq!(g.next_deadline_us(), None);
    assert_eq!(
        g.ack(1, 30_000),
        FlowAction::Encode { damage: Rect { x: 5, y: 5, width: 50, height: 50 }, frame: 2 }
    );
}

#[test]
fn gate_respects_the_frame_rate_cap_with_a_deadline() {
    let mut g = FrameGate::new(1, 10);
    assert!(matches!(g.damage(R, 0), FlowAction::Encode { .. }));
    assert_eq!(g.ack(1, 1_000), FlowAction::Wait);
    assert_eq!(g.damage(R, 2_000), FlowAction::Wait);
    assert_eq!(g.next_deadline_us(), Some(100_000));
    assert_eq!(g.poll(99_999), FlowAction::Wait);
    assert!(matches!(g.poll(100_000), FlowAction::Encode { frame: 2, .. }));
}

#[test]
fn no_damage_means_no_frame() {
    let mut g = FrameGate::new(1, 60);
    assert_eq!(g.poll(1_000_000), FlowAction::Wait);
    assert_eq!(g.next_deadline_us(), None);
}

proptest! {
    /// Under any duplication and loss pattern (each event lost in fewer than
    /// MAX_SENDS packets), the host applies every event exactly once, in order.
    #[test]
    fn input_is_applied_exactly_once_in_order(
        n in 1usize..60,
        losses in proptest::collection::vec(any::<bool>(), 0..400),
        dup in proptest::collection::vec(any::<bool>(), 0..400),
    ) {
        let mut sender = InputSender::new();
        let mut applier = InputApplier::new(1_000_000);
        let mut applied = Vec::new();
        let mut step = 0usize;
        let mut sent_events = 0usize;
        let mut now = 0u64;
        while applied.len() < n && step < 2_000 {
            if sent_events < n {
                sender.push(InputEvent::Key { usage: sent_events as u32, down: true });
                sent_events += 1;
            }
            let Some(packet) = sender.packet() else { break };
            let lose = losses.get(step).copied().unwrap_or(false) && !step.is_multiple_of(usize::from(MAX_SENDS));
            if !lose {
                applied.extend(applier.accept(&packet, now));
                if dup.get(step).copied().unwrap_or(false) {
                    applied.extend(applier.accept(&packet, now));
                }
                sender.ack(applier.applied());
            }
            step += 1;
            now += 1_000;
        }
        let usages: Vec<u32> = applied
            .iter()
            .map(|e| match e { InputEvent::Key { usage, .. } => *usage, _ => u32::MAX })
            .collect();
        let expected: Vec<u32> = (0..usages.len() as u32).collect();
        prop_assert_eq!(usages, expected);
    }
}

#[test]
fn applier_skips_a_gap_after_the_timeout() {
    let mut a = InputApplier::new(200_000);
    let later = cmux_rd_proto::InputPacket {
        first_seq: 3,
        events: vec![InputEvent::Pointer { x: 1, y: 1 }],
    };
    assert!(a.accept(&later, 0).is_empty());
    assert!(a.tick(199_999).is_empty());
    assert_eq!(a.tick(200_000), vec![InputEvent::Pointer { x: 1, y: 1 }]);
    assert_eq!(a.applied(), 3);
}

fn feed(
    cc: &mut CongestionController,
    seq: &mut u16,
    now: &mut u64,
    queue_growth_us: u64,
    n: usize,
) {
    for _ in 0..n {
        let mut arrivals = Vec::new();
        for i in 0..10u64 {
            cc.on_sent(*seq, *now + i * 100);
            let delay = 5_000 + queue_growth_us;
            arrivals
                .push(Arrival { transport_seq: *seq, arrival_us: (*now + i * 100 + delay) as u32 });
            *seq = seq.wrapping_add(1);
        }
        *now += 16_667;
        cc.on_feedback(&arrivals, 0.0);
    }
}

#[test]
fn rising_delay_lowers_the_target_and_flat_delay_raises_it() {
    let mut cc = CongestionController::new(CcConfig::default(), PathKind::DirectLan);
    let start = cc.target_bps();
    let (mut seq, mut now) = (0u16, 0u64);
    feed(&mut cc, &mut seq, &mut now, 0, 10);
    assert!(cc.target_bps() > start);
    let high = cc.target_bps();
    // Every feedback, each packet waits 1 ms longer than the one before.
    for k in 0..10u64 {
        let mut arrivals = Vec::new();
        for i in 0..10u64 {
            cc.on_sent(seq, now + i * 100);
            arrivals.push(Arrival {
                transport_seq: seq,
                arrival_us: (now + i * 100 + 5_000 + (k * 10 + i) * 1_000) as u32,
            });
            seq = seq.wrapping_add(1);
        }
        now += 16_667;
        cc.on_feedback(&arrivals, 0.0);
    }
    assert_eq!(cc.usage(), Usage::Overuse);
    assert!(cc.target_bps() < high);
}

#[test]
fn relay_path_caps_the_target_at_once() {
    let mut cc = CongestionController::new(CcConfig::default(), PathKind::DirectWan);
    assert!(cc.target_bps() > 4_000_000);
    cc.on_path_changed(PathKind::DoRelay);
    assert!(cc.target_bps() <= 4_000_000);
}

#[test]
fn heavy_loss_cuts_the_target() {
    let mut cc = CongestionController::new(CcConfig::default(), PathKind::DirectWan);
    let before = cc.target_bps();
    cc.on_feedback(&[], 0.4);
    assert!(cc.target_bps() < before);
}

#[test]
fn ladder_keeps_text_sharp_and_motion_smooth() {
    let base = LadderInput {
        target_bps: 2_000_000,
        content: ContentClass::Text,
        path: PathKind::DirectWan,
        display_fps: 60,
        relay_max_fps: 15,
        encode_us: 0,
        min_bits_per_pixel: 0.02,
        pixels: 1920 * 1080,
    };
    let text = choose(base);
    assert_eq!(text.scale, 1.0);
    assert!(text.fps < 60);
    let motion = choose(LadderInput { content: ContentClass::Motion, ..base });
    assert!(motion.scale < 1.0);
    let relay = choose(LadderInput { path: PathKind::DoRelay, target_bps: 100_000_000, ..base });
    assert!(relay.fps <= 15);
    let slow_encoder = choose(LadderInput { encode_us: 40_000, target_bps: 100_000_000, ..base });
    assert!(slow_encoder.fps <= 25);
}

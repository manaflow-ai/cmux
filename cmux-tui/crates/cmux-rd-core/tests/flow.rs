//! The frame gate's rate cap keeps a schedule while frames flow: a frame that comes a little
//! early on the display's cadence goes at once, and the frames never outnumber the cap's.

use cmux_rd_core::flow::{FlowAction, FrameGate, Rect};

const R: Rect = Rect { x: 0, y: 0, width: 10, height: 10 };
/// 60 fps.
const I: u64 = 1_000_000 / 60;
/// How early on the schedule a frame may go (`flow::CAP_EARLY_US`).
const CAP_EARLY_US: u64 = 4_000;

fn sent(action: FlowAction) -> bool {
    matches!(action, FlowAction::Encode { .. })
}

#[test]
fn a_frame_early_against_a_late_previous_send_is_not_held() {
    // Display-rate frames at 0, I and 2I; the second was picked up 3 ms late. Spaced from that
    // send, the third waited 3 ms (rounded up to the next millisecond by the timer); on the
    // schedule it goes when it arrives.
    let mut g = FrameGate::new(4, 60);
    assert!(sent(g.damage(R, 0)));
    assert!(sent(g.damage(R, I + 3_000)));
    assert!(sent(g.damage(R, 2 * I)), "the third frame goes when it arrives");
}

#[test]
fn display_rate_frames_with_jitter_all_go_when_they_arrive() {
    // A 60 Hz capture whose pickups jitter by up to 2 ms either way, for 10 s.
    let jitter = [-2_000i64, 1_500, -1_000, 2_000, -2_000, 500, 0, -1_500, 2_000, -500];
    let mut g = FrameGate::new(4, 60);
    for (k, j) in jitter.iter().cycle().take(600).enumerate() {
        let now = (10 * I + k as u64 * I).checked_add_signed(*j).expect("time");
        assert!(sent(g.damage(R, now)), "frame {k} at {now} was held");
        g.ack(k as u32 + 1, now);
    }
}

#[test]
fn an_unbounded_source_still_gets_at_most_the_cap() {
    // Damage every millisecond for 10 s (X damage has no display rate).
    let mut g = FrameGate::new(4, 60);
    let mut frames = 0u32;
    let mut last_sent: Option<u64> = None;
    for ms in 0..10_000u64 {
        let now = ms * 1_000;
        if sent(g.damage(R, now)) {
            frames += 1;
            if let Some(last) = last_sent {
                assert!(now - last >= I - CAP_EARLY_US, "frames at {last} and {now} too close");
            }
            last_sent = Some(now);
            g.ack(frames, now);
        }
    }
    assert!((599..=601).contains(&frames), "{frames} frames in 10 s at a 60 fps cap");
}

#[test]
fn after_an_idle_gap_the_next_frame_waits_a_whole_interval() {
    let mut g = FrameGate::new(4, 60);
    assert!(sent(g.damage(R, 0)));
    assert!(sent(g.damage(R, 1_000_000)), "after a second idle the frame goes at once");
    // The idle second is not owed: no burst, and no early allowance off the schedule.
    assert_eq!(g.damage(R, 1_000_000 + I - 1), FlowAction::Wait);
    assert_eq!(g.next_deadline_us(), Some(1_000_000 + I));
}

#[test]
fn a_fast_cap_allows_at_most_half_an_interval_early() {
    // At 240 fps the interval is 4.2 ms: a frame may go 2.1 ms early, not CAP_EARLY_US.
    let i = 1_000_000 / 240;
    let mut g = FrameGate::new(4, 240);
    assert!(sent(g.damage(R, 0)));
    assert!(sent(g.damage(R, i)));
    assert_eq!(g.damage(R, 2 * i - i / 2 - 1), FlowAction::Wait);
    assert_eq!(g.next_deadline_us(), Some(2 * i - i / 2));
}

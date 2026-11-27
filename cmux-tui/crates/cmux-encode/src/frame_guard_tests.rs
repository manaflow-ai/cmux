use super::*;

#[test]
fn a_keyframe_floor_follows_the_last_keyframes_size() {
    let max = keyframe_max_bytes(1920 * 1080);
    assert_eq!(max, 972_000);
    // The sweep's 1.44 MB noise keyframe at QP 30: up by ceil(6 * log2(1.48)) = 4.
    assert_eq!(next_keyframe_floor(30, 1_435_625, max, 30), 34);
    // Within the bound: hold; well under it: back down, never under the minimum.
    assert_eq!(next_keyframe_floor(34, 600_000, max, 30), 34);
    assert_eq!(next_keyframe_floor(34, 100_000, max, 30), 30);
    assert_eq!(next_keyframe_floor(48, 100_000_000, max, 30), MAX_QP);
}

const PX: u64 = 512 * 256;
/// One frame interval's share of 2 Mbps at 30 fps.
const BUDGET: usize = 8_333;
const TEXT_K: f64 = 2.0;
const NOISE_K: f64 = 11.0;

/// Sends one changed frame of content `k` (bytes per changed pixel at QP 0) through the
/// guard as the model sizes it, and returns its bytes.
fn send(guard: &mut FrameGuard, changed: u64, budget: usize, k: f64) -> usize {
    let floor = guard.before(changed, budget);
    let qp = if floor > 0 { floor } else { UNBOUND_QP };
    let bytes = (changed as f64 * k * 2f64.powf(-f64::from(qp) / 6.0)).round() as usize;
    guard.after(changed, bytes.max(1));
    bytes
}

/// A screen still for a while: frames with no damage.
fn still(guard: &mut FrameGuard) {
    for _ in 0..30 {
        assert_eq!(guard.before(0, BUDGET), 0);
        guard.after(0, 20);
    }
}

#[test]
fn the_sessions_first_changed_frame_starts_from_the_noise_figure() {
    let mut guard = FrameGuard::default();
    // 131k px of unknown content against 8.3 KB: 11 B/px at QP 0 asks for QP 47.
    assert_eq!(guard.before(PX, BUDGET), 47);
    // Full-screen noise at that floor fits the budget.
    let mut guard = FrameGuard::default();
    assert!(send(&mut guard, PX, BUDGET, NOISE_K) <= BUDGET);
    // A tiny change needs no floor.
    let mut guard = FrameGuard::default();
    assert_eq!(guard.before(16 * 16, BUDGET), 0);
    assert_eq!(guard.before(0, BUDGET), 0);
}

#[test]
fn text_frames_learn_a_text_k_and_noise_frames_a_noise_k() {
    for k in [TEXT_K, NOISE_K] {
        let mut guard = FrameGuard::default();
        for _ in 0..3 {
            send(&mut guard, PX, BUDGET, k);
        }
        assert!((guard.k() - k).abs() < 0.05 * k, "{k}: k {}", guard.k());
        assert!((guard.peak() - k).abs() < 0.05 * k, "{k}: peak {}", guard.peak());
    }
}

#[test]
fn the_high_side_decays_per_changed_frame() {
    let mut guard = FrameGuard::default();
    for _ in 0..3 {
        send(&mut guard, PX, BUDGET, NOISE_K);
    }
    // One text frame: the running k follows it at once, the high side keeps 0.7 of noise.
    send(&mut guard, PX, BUDGET, TEXT_K);
    assert!(guard.k() < 4.0, "{}", guard.k());
    assert!((guard.peak() - NOISE_K * PEAK_DECAY).abs() < 0.2, "{}", guard.peak());
    // Within five text frames the high side is text's again.
    for _ in 0..4 {
        send(&mut guard, PX, BUDGET, TEXT_K);
    }
    assert!((guard.peak() - TEXT_K).abs() < 0.1, "{}", guard.peak());
    // A noise frame raises it at once.
    send(&mut guard, PX, BUDGET, NOISE_K);
    assert!(guard.peak() >= NOISE_K * 0.95, "{}", guard.peak());
}

#[test]
fn a_still_screen_teaches_nothing() {
    let mut guard = FrameGuard::default();
    for _ in 0..3 {
        send(&mut guard, PX, BUDGET, NOISE_K);
    }
    let (k, peak) = (guard.k(), guard.peak());
    still(&mut guard);
    assert_eq!((guard.k(), guard.peak()), (k, peak));
}

#[test]
fn after_a_still_screen_a_change_is_sized_from_what_the_session_sent() {
    let mut floors = Vec::new();
    for k in [0.15, TEXT_K, NOISE_K] {
        let mut guard = FrameGuard::default();
        // The session's first transition (its first changed frame is the exemption).
        still(&mut guard);
        for _ in 0..3 {
            send(&mut guard, PX, BUDGET, k);
        }
        // The second: frame 1 under 2 budgets, frames 2-3 under 1.5.
        still(&mut guard);
        floors.push(guard.clone().before(PX, BUDGET));
        let sizes: Vec<usize> = (0..3).map(|_| send(&mut guard, PX, BUDGET, k)).collect();
        assert!(sizes[0] <= BUDGET * 2, "{k}: {sizes:?}");
        assert!(sizes[1..].iter().all(|&s| s <= BUDGET * 3 / 2), "{k}: {sizes:?}");
    }
    // Text stays sharp: its floor after a still screen is far under noise's.
    assert!(floors[1] + 10 <= floors[2], "{floors:?}");
    assert!(floors[0] < floors[1], "{floors:?}");
}

#[test]
fn noise_in_motion_raises_the_next_floor_and_text_drops_it_within_two_frames() {
    let mut guard = FrameGuard::default();
    for _ in 0..3 {
        send(&mut guard, PX, BUDGET, TEXT_K);
    }
    let text = guard.before(PX, BUDGET);
    // A noise frame at text's floor comes out about 5x over: the next floor rises.
    send(&mut guard, PX, BUDGET, NOISE_K);
    let second = guard.before(PX, BUDGET);
    assert!(second >= text + 10, "{text} -> {second}");
    assert!(second <= MAX_QP);
    // Then text again: the running k falls in one or two frames, not 2 QP at a time.
    send(&mut guard, PX, BUDGET, TEXT_K);
    let third = guard.before(PX, BUDGET);
    send(&mut guard, PX, BUDGET, TEXT_K);
    let fourth = guard.before(PX, BUDGET);
    assert!(third < second - 5, "{second} -> {third}");
    assert!(fourth <= third && fourth <= text + 2, "{text}: {third} -> {fourth}");
}

#[test]
fn a_generous_budget_sets_at_most_a_near_lossless_floor() {
    let mut guard = FrameGuard::default();
    // 1080p at 150 Mbps and 120 fps: a 156 KB budget. Text measured at about 0.28 B/px at
    // QP 0 gets at most a near-lossless floor.
    guard.after(1920 * 1080, 36_000);
    assert_eq!(guard.floor(), 0);
    assert!(guard.k() < 0.3, "{}", guard.k());
    assert!(guard.before(1920 * 1080, 156_250) <= 16);
}

#[test]
fn standards_scroll_budgets_get_a_floor_and_a_small_change_none() {
    const P1080: u64 = 1920 * 1080;
    // Standard's one-frame budgets at 1080p60 (the bench's 400-2000 kbps): 833 to 4166 B.
    // Scrolled text over the whole screen needs a floor at either end of that range.
    let mut guard = FrameGuard::default();
    guard.after(P1080, 36_000);
    let low = guard.before(P1080, 833);
    let high = guard.before(P1080, 4_166);
    assert!(high >= MIN_FLOOR && high < low && low <= MAX_QP, "{low} {high}");
    // The predicted frame at that floor fits the budget.
    let predicted = |qp: i32| P1080 as f64 * guard.k() * 2f64.powf(-f64::from(qp) / 6.0);
    assert!(predicted(high) <= 4_166.0, "{}", predicted(high));
    // A small change (a cursor line) at the same rate needs none.
    assert_eq!(guard.before(64 * 16, 4_166), 0);
}

#[test]
fn a_low_floor_holds_instead_of_flapping_and_a_high_one_still_falls() {
    let mut guard = FrameGuard::default();
    // Content that wants a near-lossless floor over the whole picture.
    guard.after(PX, 1_900);
    let low = guard.before(PX, BUDGET);
    assert!((MIN_FLOOR..=HOLD_FLOOR_MAX).contains(&low), "{low}");
    // A tiny change wants none, and a still screen none: the floor holds, so the encoder's
    // MinQP is not changed again.
    assert_eq!(guard.before(16 * 16, BUDGET), low);
    assert_eq!(guard.before(0, BUDGET), low);
    // It still rises at once for a frame that needs more.
    guard.after(PX, 200_000);
    let high = guard.before(PX, BUDGET);
    assert!(high > HOLD_FLOOR_MAX, "{high}");
    // And a high floor falls as before.
    assert_eq!(guard.before(16 * 16, BUDGET), 0);
    assert_eq!(guard.before(0, BUDGET), 0);
}

#[test]
fn the_floor_never_passes_51() {
    let mut guard = FrameGuard::default();
    guard.after(PX, 10_000_000);
    assert_eq!(guard.before(PX, 1), MAX_QP);
}

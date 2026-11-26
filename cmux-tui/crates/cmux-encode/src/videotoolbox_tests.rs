use super::*;

#[test]
fn a_frame_budget_is_one_frame_intervals_share_of_the_rate() {
    assert_eq!(frame_budget(8_000, 60), (16_666, 1.0 / 60.0));
    assert_eq!(frame_budget(1_000, 30).0, 4_166);
    assert_eq!(frame_budget(100, 0), (12_500, 1.0), "fps 0 counts as 1");
    assert!(frame_budget(u32::MAX, 1).0 > 0, "clamped, never negative");
}

#[test]
fn the_ladders_budget_is_twice_the_rate_over_one_second() {
    assert_eq!(loose_budget(8_000), (2_000_000, 1.0));
    assert!(loose_budget(8_000).0 > frame_budget(8_000, 60).0 * 60, "looser than a frame's");
    assert!(loose_budget(u32::MAX).0 > 0, "clamped, never negative");
}

#[test]
fn ultra_holds_frame_rate_first_within_a_per_pixel_ceiling() {
    const P1080: usize = 1920 * 1080;
    // 150 Mbps at 120 fps: one frame interval's share, as standard.
    assert_eq!(ultra_frame_budget(150_000, 120, P1080, 1), frame_budget(150_000, 120));
    assert_eq!(ultra_frame_budget(150_000, 120, P1080, 1).0, 156_250);
    // An uncapped target (the sweep's 770 Mbps) stops at 3 bits per pixel: under 1 MB.
    assert_eq!(ultra_frame_budget(770_000, 120, P1080, 1), (777_600, 1.0 / 120.0));
    assert_eq!(ultra_frame_budget(u32::MAX, 1, P1080, 1).0, 777_600);
    // The refinement gets four budgets, still within the ceiling.
    assert_eq!(ultra_frame_budget(150_000, 120, P1080, 4).0, 625_000);
    assert_eq!(ultra_frame_budget(400_000, 120, P1080, 4).0, 777_600);
    assert!(ultra_frame_budget(100, 120, 0, 1).0 > 0, "never zero");
}

#[test]
fn a_qp_floor_never_passes_the_ladders_ceiling() {
    // The guard's 51 on a 2 KB budget under the ladder's 40: 40, not a -12902 frame.
    assert_eq!(floor_under_ceiling(51, Some(40)), 40);
    assert_eq!(floor_under_ceiling(30, Some(40)), 30);
    assert_eq!(floor_under_ceiling(0, Some(40)), 0, "no floor stays none");
    assert_eq!(floor_under_ceiling(51, None), 51, "no ceiling, no clamp");
}

#[test]
fn the_frame_guard_is_on_unless_a_sweep_says_off() {
    assert!(guard_enabled(None));
    assert!(guard_enabled(Some("on")));
    assert!(guard_enabled(Some("")));
    assert!(!guard_enabled(Some("off")));
    assert!(!guard_enabled(Some(" off\n")));
}

#[test]
fn ultras_qp_floor_defaults_and_overrides() {
    assert_eq!(ultra_min_qp(None), NO_MIN_QP, "no floor by default");
    assert_eq!(ultra_min_qp(Some("20")), 20);
    assert_eq!(ultra_min_qp(Some(" 22 ")), 22);
    assert_eq!(ultra_min_qp(Some("0")), NO_MIN_QP, "0 is out of range");
    assert_eq!(ultra_min_qp(Some("52")), NO_MIN_QP, "past H.264's range");
    assert_eq!(ultra_min_qp(Some("x")), NO_MIN_QP);
}

#[test]
fn the_name_says_which_rate_control_runs() {
    assert_eq!(
        session_name(false, false),
        "videotoolbox h264 high low-latency-rc realtime no-reordering gop=inf"
    );
    assert_eq!(
        session_name(true, true),
        "videotoolbox h264 constrained-baseline frame-budget-rc realtime no-reordering gop=inf ultra"
    );
}

#[test]
fn a_bitrate_cut_applies_at_once_and_a_small_rise_waits() {
    assert!(bitrate_change_applies(10_000, 9_900), "a 1% cut");
    assert!(bitrate_change_applies(10_000, 5_000));
    assert!(!bitrate_change_applies(10_000, 10_400), "a 4% rise");
    assert!(bitrate_change_applies(10_000, 10_500), "a 5% rise");
    assert!(!bitrate_change_applies(10_000, 10_000));
}

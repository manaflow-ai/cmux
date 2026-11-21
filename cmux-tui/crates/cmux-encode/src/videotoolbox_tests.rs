use super::*;

#[test]
fn a_frame_budget_is_one_frame_intervals_share_of_the_rate() {
    assert_eq!(frame_budget(8_000, 60), (16_666, 1.0 / 60.0));
    assert_eq!(frame_budget(1_000, 30).0, 4_166);
    assert_eq!(frame_budget(100, 0), (12_500, 1.0), "fps 0 counts as 1");
    assert!(frame_budget(u32::MAX, 1).0 > 0, "clamped, never negative");
}

#[test]
fn a_bitrate_cut_applies_at_once_and_a_small_rise_waits() {
    assert!(bitrate_change_applies(10_000, 9_900), "a 1% cut");
    assert!(bitrate_change_applies(10_000, 5_000));
    assert!(!bitrate_change_applies(10_000, 10_400), "a 4% rise");
    assert!(bitrate_change_applies(10_000, 10_500), "a 5% rise");
    assert!(!bitrate_change_applies(10_000, 10_000));
}

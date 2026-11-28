use super::*;

const W: u32 = 1920;
const H: u32 = 1080;

fn ladder() -> ResolutionLadder {
    ResolutionLadder::new(LadderConfig::default(), W, H, 60)
}

#[test]
fn a_rate_with_room_keeps_the_full_picture_and_the_ceiling() {
    let mut l = ladder();
    // 1080p60 needs 6.2 Mbps for the floor.
    assert_eq!(l.update(20_000_000, 0), None);
    let p = l.picture();
    assert_eq!((p.width, p.height, p.eighths, p.fps), (W, H, 8, 60));
    assert_eq!(p.max_qp, Some(DEFAULT_MAX_QP));
}

#[test]
fn the_floor_holds_at_every_rate() {
    for kbps in [100, 250, 400, 1_000, 2_000, 4_000, 8_000, 15_000, 40_000, 150_000] {
        let mut l = ladder();
        l.update(kbps * 1000, 0);
        let bpp = l.bits_per_pixel(kbps * 1000);
        let p = l.picture();
        // Only the frame-rate floor may leave a very low rate under it.
        if p.fps > MIN_FPS {
            assert!(bpp >= MIN_BITS_PER_PIXEL, "{kbps} kbps: {bpp} bpp at {p:?}");
        }
        assert!(p.width.is_multiple_of(2) && p.height.is_multiple_of(2), "{p:?}");
    }
}

#[test]
fn a_low_rate_steps_down_at_once_and_back_up_only_after_the_hold() {
    let mut l = ladder();
    let p = l.update(1_000_000, 0).expect("1 Mbps resizes");
    // 1 Mbps at 1080p60 is 0.008 bpp; 3/8 gives 0.057.
    assert_eq!(p.eighths, 3);
    assert_eq!((p.width, p.height), (720, 404));
    // Room for full size comes back: nothing moves before the hold.
    assert_eq!(l.update(20_000_000, 1_000_000), None);
    assert_eq!(l.update(20_000_000, 2_999_999), None);
    // One rung per hold.
    assert_eq!(l.update(20_000_000, 3_000_000).map(|p| p.eighths), Some(4));
    assert_eq!(l.update(20_000_000, 4_000_000), None);
    assert_eq!(l.update(20_000_000, 6_000_000).map(|p| p.eighths), Some(6));
    assert_eq!(l.update(20_000_000, 7_000_000), None);
    assert_eq!(l.update(20_000_000, 9_000_000).map(|p| p.eighths), Some(8));
}

#[test]
fn a_wobble_at_a_rungs_edge_does_not_step_up() {
    let mut l = ladder();
    l.update(3_000_000, 0);
    let start = l.picture().eighths;
    // Clears the larger rung by the margin, then not, every half second.
    let up_needs = MIN_BITS_PER_PIXEL * UP_MARGIN * f64::from(W * H) * 60.0;
    let edge = (up_needs * f64::from(RUNGS[0] * RUNGS[0]) / 64.0) as u64;
    for i in 0..20u64 {
        let bps = if i.is_multiple_of(2) { edge * 2 } else { 3_000_000 };
        l.update(bps, i * 500_000);
    }
    assert_eq!(l.picture().eighths, start);
}

#[test]
fn under_the_smallest_rung_the_frame_rate_comes_down_instead() {
    let mut l = ladder();
    let p = l.update(200_000, 0).expect("resizes");
    assert_eq!(p.eighths, 2);
    assert!(p.fps < 60 && p.fps >= MIN_FPS, "{p:?}");
    assert!(l.bits_per_pixel(200_000) >= MIN_BITS_PER_PIXEL);
}

#[test]
fn an_encoder_drop_steps_down_and_holds_off_the_step_up() {
    let mut l = ladder();
    l.update(20_000_000, 0);
    assert_eq!(l.encoder_dropped(20_000_000, 100).map(|p| p.eighths), Some(6));
    // The rate still clears full size, but not before the hold after the drop.
    assert_eq!(l.update(20_000_000, 1_000_000), None);
    assert_eq!(l.update(20_000_000, UP_HOLD_US + 100), None);
    assert_eq!(l.update(20_000_000, 2 * UP_HOLD_US + 100).map(|p| p.eighths), Some(8));
}

#[test]
fn a_drop_at_the_smallest_rung_lifts_the_ceiling_until_a_step_up() {
    let mut l = ladder();
    l.update(300_000, 0);
    assert_eq!(l.picture().eighths, 2);
    let p = l.encoder_dropped(300_000, 0).expect("ceiling lifts");
    assert_eq!((p.eighths, p.max_qp), (2, None));
    assert_eq!(l.encoder_dropped(300_000, 10), None);
    l.update(2_000_000, 3 * UP_HOLD_US);
    let p = l.update(2_000_000, 5 * UP_HOLD_US).expect("steps up");
    assert_eq!((p.eighths, p.max_qp), (3, Some(DEFAULT_MAX_QP)));
}

#[test]
fn a_small_stream_never_goes_under_the_smallest_side() {
    let mut l = ResolutionLadder::new(LadderConfig::default(), 100, 80, 60);
    l.update(1_000, 0);
    let p = l.picture();
    assert!(p.width >= 64 && p.height >= 64, "{p:?}");
}

//! The resolution ladder in the engine (screen-share design D5): below the bits-per-pixel
//! floor the main stream's picture gets smaller, not blurrier; a size change is a keyframe;
//! an encoder drop steps down instead of cutting the rate or asking for a keyframe.

use cmux_rd_core::resolution::{LadderConfig, MIN_BITS_PER_PIXEL};
use cmux_rd_engine::{EngineConfig, IdrReason, MediaEngine};

fn engine(start_bps: u64, ladder: bool) -> MediaEngine {
    MediaEngine::new(
        EngineConfig {
            width: 1920,
            height: 1080,
            max_fps: 60,
            start_bps,
            resolution_ladder: ladder.then(LadderConfig::default),
            ..EngineConfig::default()
        },
        0,
    )
}

#[test]
fn without_a_ladder_requests_carry_no_picture() {
    let mut e = engine(1_000_000, false);
    let req = e.start(0).expect("first frame");
    assert_eq!(req.picture, None);
    assert_eq!(e.picture(0), None);
}

#[test]
fn a_low_rate_encodes_a_smaller_picture_that_clears_the_floor() {
    let mut e = engine(1_000_000, true);
    let req = e.start(0).expect("first frame");
    let picture = req.picture.expect("ladder picture");
    // 1 Mbps at 1080p60 is 0.008 bits per pixel; 3/8 size gives 0.057.
    assert_eq!((picture.width, picture.height, picture.eighths), (720, 404, 3));
    let bpp = f64::from(req.target_kbps) * 1000.0
        / (f64::from(picture.width) * f64::from(picture.height) * f64::from(picture.fps));
    assert!(bpp >= MIN_BITS_PER_PIXEL, "{bpp}");
    // The first frame is a keyframe anyway; its reason stays the start.
    assert_eq!(req.idr_reason, Some(IdrReason::Start));
}

#[test]
fn an_encoder_drop_steps_down_without_a_rate_cut() {
    let mut e = engine(20_000_000, true);
    let req = e.start(0).expect("first frame");
    assert_eq!(req.picture.map(|p| p.eighths), Some(8));
    let before = e.target_bps();
    let out = e.encoded(&req, None, 1_000).expect("drop");
    assert!(!out.halve_bitrate);
    assert!(out.datagrams.is_empty());
    assert_eq!(e.target_bps(), before, "a drop is not congestion");
    let next = e.poll(100_000).expect("the dropped change goes out again");
    assert_eq!(next.picture.map(|p| p.eighths), Some(6));
    assert_eq!(next.damage, req.damage, "the dropped damage is requeued");
    // The new size is a keyframe; a start that never went out stays the reason.
    assert!(next.force_idr);
}

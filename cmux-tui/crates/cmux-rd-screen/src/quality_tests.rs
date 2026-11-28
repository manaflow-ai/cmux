//! Parity with FrameRateTests.swift (the frame rate and encoding cases).
use super::*;

const ADAPTIVE: [Quality; 2] = [Quality::Auto, Quality::Smooth];
const FIXED: [Quality; 3] = [Quality::Low, Quality::Medium, Quality::High];

fn at(quality: Quality, width: i64, height: i64, fps: i64) -> Encoding {
    encoding(quality, width, height, fps)
}

/// Auto and Smooth Motion run at the lower of the two displays' rates, at most 120.
#[test]
fn adaptive_presets_follow_both_displays() {
    for q in ADAPTIVE {
        assert_eq!(frame_rate(q, Some(120), Some(120)), 120);
        assert_eq!(frame_rate(q, Some(120), Some(60)), 60);
        assert_eq!(frame_rate(q, Some(60), Some(120)), 60);
        assert_eq!(frame_rate(q, Some(144), Some(144)), 120, "capped at 120");
        assert_eq!(frame_rate(q, Some(120), Some(90)), 90);
        assert_eq!(frame_rate(q, Some(100), Some(120)), 100);
    }
}

/// A peer that does not report a rate (an older viewer, the Screen Sharing source, a display
/// that says 0) leaves the stream at 60, as before.
#[test]
fn an_unreported_rate_keeps_sixty() {
    for q in ADAPTIVE {
        assert_eq!(frame_rate(q, Some(120), None), 60);
        assert_eq!(frame_rate(q, None, Some(120)), 60);
        assert_eq!(frame_rate(q, None, None), 60);
        assert_eq!(frame_rate(q, Some(0), Some(120)), 60);
        // Never below 60, even on a slower display.
        assert_eq!(frame_rate(q, Some(50), Some(120)), 60);
        assert_eq!(frame_rate(q, Some(120), Some(30)), 60);
    }
}

/// The fixed presets keep their own rate whatever the displays can do.
#[test]
fn fixed_presets_ignore_the_displays() {
    for (host, viewer) in [(Some(120), Some(120)), (Some(60), Some(60)), (None, None)] {
        assert_eq!(frame_rate(Quality::Low, host, viewer), 30);
        assert_eq!(frame_rate(Quality::Medium, host, viewer), 30);
        assert_eq!(frame_rate(Quality::High, host, viewer), 60);
    }
}

/// At 120 fps Auto and Smooth Motion may use twice the bitrate, so each frame keeps the same
/// budget (200 kbit); at 60 nothing changes.
#[test]
fn adaptive_bitrate_scales_with_the_frame_rate() {
    for q in ADAPTIVE {
        let sixty = at(q, 0, 1800, 60);
        assert_eq!(sixty.max_framerate, 60);
        assert_eq!(sixty.max_bitrate, 12_000_000);
        let one_twenty = at(q, 0, 1800, 120);
        assert_eq!(one_twenty.max_framerate, 120);
        assert_eq!(one_twenty.max_bitrate, 24_000_000);
        assert_eq!(one_twenty.degradation, sixty.degradation);
        assert_eq!(one_twenty.scale_down, sixty.scale_down);
        let ninety = at(q, 0, 1800, 90);
        assert_eq!((ninety.max_framerate, ninety.max_bitrate), (90, 18_000_000));
    }
}

/// A known picture's ceiling is 0.18 bits per encoded pixel per frame (Petal's rule), at least
/// 4 Mbps and at most 16 Mbps, or 200 kbit a frame above 80 fps, so 120 fps keeps its 24 Mbps.
#[test]
fn adaptive_bitrate_follows_the_encoded_pixels() {
    for q in ADAPTIVE {
        // A 16" MacBook Pro's display: the most at 60, and 120 as before.
        assert_eq!(at(q, 3456, 2234, 60).max_bitrate, 16_000_000);
        assert_eq!(at(q, 3456, 2234, 120).max_bitrate, 24_000_000);
        assert_eq!(at(q, 3456, 2234, 90).max_bitrate, 18_000_000);
        // A small picture gets what its pixels need.
        assert_eq!(at(q, 1280, 800, 60).max_bitrate, 11_059_200);
        assert_eq!(at(q, 960, 600, 60).max_bitrate, 6_220_800);
        // Never under the floor.
        assert_eq!(at(q, 640, 400, 60).max_bitrate, 4_000_000);
        // 1080p60 wants 22 Mbps, held at 16.
        let scaled = at(q, 1920, 1080, 60);
        assert_eq!((scaled.scale_down, scaled.max_bitrate), (1.0, 16_000_000));
    }
}

/// Above 60 fps Auto and Smooth Motion scale the picture down just enough for the hardware H.264
/// encoder to keep up (measured: an M1 Max encodes a 3456×2234 display at 55 fps, an M4 Pro at
/// 66; both hold 2160×1396 at 120). At 60 fps and for a display that already fits, nothing changes.
#[test]
fn above_sixty_the_picture_fits_the_encoder() {
    let budget = MAXIMUM_ENCODED_PIXEL_RATE as f64;
    for q in ADAPTIVE {
        for (w, h, fps) in
            [(3456, 2234, 120), (3024, 1964, 120), (3456, 2234, 90), (5120, 2880, 120)]
        {
            let e = at(q, w, h, fps);
            let rate = w as f64 / e.scale_down * (h as f64 / e.scale_down) * fps as f64;
            assert!(
                rate <= budget * 1.001,
                "{w}x{h} at {fps} fps asks for {} Mpixel/s",
                (rate / 1e6) as i64
            );
            assert!(rate >= budget * 0.99, "{w}x{h} at {fps} fps is scaled no more than it needs");
            assert_eq!(e.max_framerate, fps);
            assert_eq!(e.degradation, at(q, 0, h, 60).degradation);
        }
        assert_eq!(at(q, 3456, 2234, 60).scale_down, 1.0, "60 fps keeps the full size");
        assert_eq!(at(q, 1920, 1080, 120).scale_down, 1.0, "1080p fits at 120");
        assert_eq!(at(q, 0, 2234, 120).scale_down, 1.0, "an unknown size is not scaled");
    }
}

/// The fixed presets' encoding does not depend on the frame rate or the width.
#[test]
fn fixed_presets_scale_as_before_at_any_rate() {
    for q in FIXED {
        assert_eq!(at(q, 3456, 2234, 120), at(q, 0, 2234, 60));
        assert_eq!(at(q, 0, 2160, 120), at(q, 0, 2160, 60));
    }
    assert_eq!(at(Quality::High, 0, 2160, 60).max_framerate, 60);
    assert_eq!(at(Quality::Low, 0, 2160, 60).max_framerate, 30);
}

/// Each fixed preset's bounds, scale and degradation.
#[test]
fn fixed_presets_hold_their_bitrate() {
    let low = at(Quality::Low, 0, 1440, 60);
    assert_eq!(
        (low.max_bitrate, low.min_bitrate, low.scale_down),
        (1_500_000, Some(1_500_000), 2.0)
    );
    let medium = at(Quality::Medium, 0, 2160, 60);
    assert_eq!(
        (medium.max_bitrate, medium.min_bitrate, medium.scale_down),
        (4_000_000, Some(4_000_000), 2.0)
    );
    let high = at(Quality::High, 0, 2160, 60);
    assert_eq!(
        (high.max_bitrate, high.min_bitrate, high.scale_down),
        (10_000_000, Some(10_000_000), 1.0)
    );
    assert_eq!(
        at(Quality::Low, 0, 600, 60).scale_down,
        1.0,
        "a display under 720 is not scaled up"
    );
    for q in FIXED {
        assert_eq!(at(q, 0, 1080, 60).degradation, Degradation::Disabled);
    }
    assert_eq!(at(Quality::Auto, 0, 0, 60).min_bitrate, None);
    assert_eq!(at(Quality::Auto, 0, 0, 60).degradation, Degradation::MaintainResolution);
    assert_eq!(at(Quality::Smooth, 0, 0, 60).degradation, Degradation::MaintainFramerate);
}

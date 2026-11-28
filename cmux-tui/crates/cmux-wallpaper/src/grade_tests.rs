use super::*;
use crate::frame::{FrameInput, pack_frame};

const INK: [f32; 3] = [0.9, 0.88, 0.85];
const PAPER: [f32; 3] = [0.01, 0.012, 0.015];
const ACCENT: [f32; 3] = [0.05, 0.2, 1.0];

fn frame(grade: f32, ink: [f32; 3], paper: [f32; 3]) -> [f32; FRAME_FLOATS] {
    pack_frame(&FrameInput { grade, ink, paper, accent: ACCENT, ..Default::default() })
}

fn close(a: [f32; 3], b: [f32; 3]) -> bool {
    a.iter().zip(b).all(|(x, y)| (x - y).abs() < 1e-5)
}

#[test]
fn at_zero_a_pixel_is_unchanged() {
    let f = frame(0.0, INK, PAPER);
    for px in [[0.0; 3], [0.3, 0.6, 0.1], [1.0; 3], [2.0, -0.5, 0.25]] {
        assert_eq!(grade(&f, px), px);
    }
    // A negative or NaN amount packs as 0: off.
    assert_eq!(grade(&frame(f32::NAN, INK, PAPER), [0.3, 0.6, 0.1]), [0.3, 0.6, 0.1]);
    assert_eq!(grade(&frame(-1.0, INK, PAPER), [0.3, 0.6, 0.1]), [0.3, 0.6, 0.1]);
}

/// The gray half way, in lightness, between the shadow's and the highlight's.
fn mid_gray(shadow: [f32; 3], highlight: [f32; 3]) -> [f32; 3] {
    let l = (luma(shadow).sqrt() + luma(highlight).sqrt()) / 2.0;
    [l * l; 3]
}

#[test]
fn black_mid_and_white_take_the_three_tones() {
    let f = frame(1.0, INK, PAPER);
    assert!(close(grade(&f, [0.0; 3]), PAPER));
    assert!(close(grade(&f, mid_gray(PAPER, INK)), ACCENT));
    assert!(close(grade(&f, [1.0; 3]), INK));
    // Brighter than white clamps to the highlight.
    assert!(close(grade(&f, [4.0; 3]), INK));
}

#[test]
fn the_themes_paper_and_ink_keep_their_color() {
    let f = frame(1.0, INK, PAPER);
    assert!(close(grade(&f, PAPER), PAPER));
    assert!(close(grade(&f, INK), INK));
}

#[test]
fn paper_the_same_as_ink_does_not_divide_by_zero() {
    let f = frame(1.0, PAPER, PAPER);
    assert!(grade(&f, [0.5; 3]).iter().all(|v| v.is_finite()));
}

#[test]
fn a_light_theme_keeps_dark_as_dark() {
    // Light: paper is the light one, ink the dark one; black still goes to the darker.
    let f = frame(1.0, PAPER, INK);
    assert!(close(grade(&f, [0.0; 3]), PAPER));
    assert!(close(grade(&f, INK), INK));
    assert!(close(grade(&f, [1.0; 3]), INK));
}

#[test]
fn the_amount_mixes_toward_the_tone() {
    let f = frame(0.5, INK, PAPER);
    let out = grade(&f, [1.0; 3]);
    assert!(close(out, mix([1.0; 3], INK, 0.5)), "{out:?}");
}

#[test]
fn the_ramp_is_monotone_in_lightness() {
    // Gray steps from black to white map to steps whose luminance never falls.
    let f = frame(1.0, INK, PAPER);
    let mut last = -1.0;
    for i in 0..=64u8 {
        let v = f32::from(i) / 64.0;
        let l = luma(grade(&f, [v; 3]));
        assert!(l >= last - 1e-6, "{v}: {l} < {last}");
        last = l;
    }
}

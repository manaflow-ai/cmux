//! The tritone grade (`Frame.grade`, `appearance.liveWallpaperGrade`): the host's color grade
//! over every live wallpaper. `epilogue.wgsl`'s `fs_main` runs it on whatever `wallpaper()`
//! returns, so a first-party or third-party program gets it with no code of its own.
//!
//! Shadow and highlight are the theme's paper and ink, the darker of the two as the shadow, so a
//! light theme's image is not turned inside out. The pixel's lightness (the square root of its
//! linear luminance, near perceptual) is measured from the shadow's lightness (0) to the
//! highlight's (1) and picks a color on a three-stop ramp: the shadow, the theme's accent half
//! way, the highlight. Black and anything darker than the shadow take the shadow; white and
//! anything lighter than the highlight take the highlight; a pixel in the theme's own paper or ink
//! keeps it, so a wallpaper's ground stays the window's ground. The
//! amount (0..1) mixes the toned color over the program's own; at 0 the shader skips the grade
//! on a uniform branch, so an ungraded wallpaper costs one compare per pixel.
//!
//! [`grade`] is the shader's arithmetic in Rust, on the packed Frame the GPU reads: the tests pin
//! the ramp here, and `cmux_tritone` in `epilogue.wgsl` is the same steps line for line.

use crate::frame::{FRAME_FLOATS, GRADE_START};

/// Rec. 709 luminance weights, for linear RGB.
pub const LUMA: [f32; 3] = [0.2126, 0.7152, 0.0722];

/// Linear luminance of `c`.
pub fn luma(c: [f32; 3]) -> f32 {
    let ([r, g, b], [lr, lg, lb]) = (c, LUMA);
    r * lr + g * lg + b * lb
}

/// The ramp's three stops, from a packed Frame: shadow, midtone and highlight, linear RGB.
pub fn tones(frame: &[f32; FRAME_FLOATS]) -> [[f32; 3]; 3] {
    let rgb = |start: usize| -> [f32; 3] {
        match frame.get(start..start + 3) {
            Some(&[r, g, b]) => [r, g, b],
            _ => [0.0; 3],
        }
    };
    let (ink, paper, accent) = (rgb(16), rgb(20), rgb(24));
    if luma(ink) >= luma(paper) { [paper, accent, ink] } else { [ink, accent, paper] }
}

fn mix(a: [f32; 3], b: [f32; 3], t: f32) -> [f32; 3] {
    let [ar, ag, ab] = a;
    let [br, bg, bb] = b;
    [ar * (1.0 - t) + br * t, ag * (1.0 - t) + bg * t, ab * (1.0 - t) + bb * t]
}

/// `rgb` (linear, straight alpha) through the grade `frame` asks for. An amount of 0 returns
/// `rgb` as it is.
pub fn grade(frame: &[f32; FRAME_FLOATS], rgb: [f32; 3]) -> [f32; 3] {
    let amount = frame.get(GRADE_START).copied().unwrap_or(0.0);
    if amount <= 0.0 {
        return rgb;
    }
    let [shadow, mid, highlight] = tones(frame);
    let lightness = |c: [f32; 3]| luma(c).clamp(0.0, 1.0).sqrt();
    let lo = lightness(shadow);
    let span = (lightness(highlight) - lo).max(1.0e-4);
    let t = ((lightness(rgb) - lo) / span).clamp(0.0, 1.0);
    let toned = if t < 0.5 {
        mix(shadow, mid, (t * 2.0).min(1.0))
    } else {
        mix(mid, highlight, (t * 2.0 - 1.0).max(0.0))
    };
    mix(rgb, toned, amount)
}

#[cfg(test)]
mod tests {
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
}

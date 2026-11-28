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
#[path = "grade_tests.rs"]
mod tests;

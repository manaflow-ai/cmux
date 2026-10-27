//! Color blends for the color transition (`appearance.colorTransition`):
//! two RGBA colors mixed in OKLab (perceptual: lightness moves evenly, no
//! muddy middle between two hues) or in plain sRGB channels.

/// Where two colors blend.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum ColorSpace {
    Oklab = 0,
    Srgb = 1,
}

/// `from` mixed `t` of the way to `to`. Inputs and output are straight
/// (unpremultiplied) sRGB RGBA, each 0..=1. The mix runs in premultiplied
/// space, as CSS Color 4 does, and unpremultiplies the result; a result with
/// alpha 0 is `[0, 0, 0, 0]`. `t` is clamped to 0..=1 (NaN takes 1), and
/// components are clamped to 0..=1 on the way out.
pub fn mix_rgba(from: [f64; 4], to: [f64; 4], t: f64, space: ColorSpace) -> [f64; 4] {
    let t = if t.is_nan() { 1. } else { t.clamp(0., 1.) };
    if t == 0. {
        return from;
    }
    if t == 1. {
        return to;
    }
    let [.., from_alpha] = from;
    let [.., to_alpha] = to;
    let alpha = from_alpha + (to_alpha - from_alpha) * t;
    if alpha <= 0. {
        return [0., 0., 0., 0.];
    }
    let a = components(from, space);
    let b = components(to, space);
    let mut mixed = [0.; 3];
    for ((mixed, a), b) in mixed.iter_mut().zip(a).zip(b) {
        *mixed = (a * from_alpha + (b * to_alpha - a * from_alpha) * t) / alpha;
    }
    let [r, g, bl] = color(mixed, space);
    [r, g, bl, alpha.clamp(0., 1.)]
}

fn linear(c: f64) -> f64 {
    if c <= 0.04045 { c / 12.92 } else { ((c + 0.055) / 1.055).powf(2.4) }
}

fn gamma(c: f64) -> f64 {
    if c <= 0.003_130_8 { c * 12.92 } else { 1.055 * c.powf(1. / 2.4) - 0.055 }
}

fn components(c: [f64; 4], space: ColorSpace) -> [f64; 3] {
    match space {
        ColorSpace::Srgb => [c[0], c[1], c[2]],
        ColorSpace::Oklab => {
            let (r, g, b) = (linear(c[0]), linear(c[1]), linear(c[2]));
            let l = (0.412_221_470_8 * r + 0.536_332_536_3 * g + 0.051_445_992_9 * b).cbrt();
            let m = (0.211_903_498_2 * r + 0.680_699_545_1 * g + 0.107_396_956_6 * b).cbrt();
            let s = (0.088_302_461_9 * r + 0.281_718_837_6 * g + 0.629_978_700_5 * b).cbrt();
            [
                0.210_454_255_3 * l + 0.793_617_785 * m - 0.004_072_046_8 * s,
                1.977_998_495_1 * l - 2.428_592_205 * m + 0.450_593_709_9 * s,
                0.025_904_037_1 * l + 0.782_771_766_2 * m - 0.808_675_766 * s,
            ]
        }
    }
}

fn color(c: [f64; 3], space: ColorSpace) -> [f64; 3] {
    match space {
        ColorSpace::Srgb => [c[0].clamp(0., 1.), c[1].clamp(0., 1.), c[2].clamp(0., 1.)],
        ColorSpace::Oklab => {
            let [lightness, a, b] = c;
            let l = (lightness + 0.396_337_777_4 * a + 0.215_803_757_3 * b).powi(3);
            let m = (lightness - 0.105_561_345_8 * a - 0.063_854_172_8 * b).powi(3);
            let s = (lightness - 0.089_484_177_5 * a - 1.291_485_548 * b).powi(3);
            let channel = |v: f64| gamma(v.clamp(0., 1.)).clamp(0., 1.);
            [
                channel(4.076_741_662_1 * l - 3.307_711_591_3 * m + 0.230_969_929_2 * s),
                channel(-1.268_438_004_6 * l + 2.609_757_401_1 * m - 0.341_319_396_5 * s),
                channel(-0.004_196_086_3 * l - 0.703_418_614_7 * m + 1.707_614_701 * s),
            ]
        }
    }
}

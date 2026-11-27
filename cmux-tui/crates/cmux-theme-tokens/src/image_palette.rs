//! A terminal scheme from a background image (extensibility design 12.4,
//! step 13): the image's colors by median cut over a downsampled grid, then
//! a background, foreground, accent and ANSI 0...15 picked from them and
//! held to `ThemeTokens::derive`'s contrast floors (the spec's
//! `minimumTextContrast` for text, `minimumMarkContrast` for the accent and
//! the ANSI colors), so text stays readable whatever the image.
//!
//! The crate decodes no image format but binary PPM (`P6`, what
//! `pnmtools`, ImageMagick and ffmpeg write): the caller decodes and passes
//! the pixels ([`Pixels`]), so the crate keeps no dependencies. Everything
//! is deterministic: no random seeds, and ties break by color value.

use crate::spec::spec;
use crate::{Appearance, Rgb, Scheme, ThemeTokens, readable};

/// Decoded pixels: `width * height` pixels of `channels` bytes each (3 RGB
/// or 4 RGBA, 8-bit sRGB), row by row.
#[derive(Clone, Copy, Debug)]
pub struct Pixels<'a> {
    pub width: u32,
    pub height: u32,
    pub channels: u8,
    pub data: &'a [u8],
}

/// What an image gives.
#[derive(Clone, Debug, PartialEq)]
pub struct ImagePalette {
    /// The terminal scheme (its `accent` is the chrome accent).
    pub scheme: Scheme,
    /// Dark or light, from the image's average lightness unless asked.
    pub appearance: Appearance,
    /// The chrome accent, at least `minimumMarkContrast` on the background.
    pub accent: Rgb,
    /// The window's glass tint, as `ThemeTokens::derive` makes it from the scheme.
    pub glass_tint: Rgb,
    /// The image's colors, most of the image first, with their share (0...1).
    pub swatches: Vec<(Rgb, f64)>,
}

/// Most pixels sampled (a grid over the image); more adds time, not colors.
pub const MAX_SAMPLES: usize = 64 * 64;
/// Colors the median cut splits the image into.
pub const SWATCHES: usize = 8;

/// Why an image gives no palette.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ImageError(pub String);

impl std::fmt::Display for ImageError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for ImageError {}

/// Reads a binary PPM (`P6`, maxval 255) into RGB pixels: (width, height, data).
pub fn decode_ppm(bytes: &[u8]) -> Result<(u32, u32, Vec<u8>), ImageError> {
    let bad = |what: &str| ImageError(format!("not a binary PPM (P6): {what}"));
    let mut fields: Vec<u32> = Vec::with_capacity(3);
    let mut at = 2usize;
    if bytes.get(..2) != Some(b"P6") {
        return Err(bad("no P6 header"));
    }
    while fields.len() < 3 {
        // Whitespace and `#` comments between the header fields.
        loop {
            match bytes.get(at) {
                Some(b) if b.is_ascii_whitespace() => at = at.saturating_add(1),
                Some(b'#') => {
                    while bytes.get(at).is_some_and(|b| *b != b'\n') {
                        at = at.saturating_add(1);
                    }
                }
                _ => break,
            }
        }
        let start = at;
        while bytes.get(at).is_some_and(u8::is_ascii_digit) {
            at = at.saturating_add(1);
        }
        let digits = bytes.get(start..at).ok_or_else(|| bad("truncated header"))?;
        let value = std::str::from_utf8(digits)
            .ok()
            .and_then(|s| s.parse::<u32>().ok())
            .ok_or_else(|| bad("bad header number"))?;
        fields.push(value);
    }
    let (width, height, maxval) = match fields.as_slice() {
        [w, h, m] => (*w, *h, *m),
        _ => return Err(bad("bad header")),
    };
    if maxval != 255 {
        return Err(bad("only maxval 255 is read"));
    }
    // One whitespace byte ends the header.
    at = at.saturating_add(1);
    let len = usize::try_from(width)
        .ok()
        .and_then(|w| w.checked_mul(usize::try_from(height).ok()?))
        .and_then(|n| n.checked_mul(3))
        .ok_or_else(|| bad("too large"))?;
    let data = bytes.get(at..at.saturating_add(len)).ok_or_else(|| bad("truncated pixels"))?;
    Ok((width, height, data.to_vec()))
}

/// The colors of up to [`MAX_SAMPLES`] pixels on an even grid (fully
/// transparent pixels skipped).
fn samples(pixels: &Pixels<'_>) -> Result<Vec<[u8; 3]>, ImageError> {
    let channels = usize::from(pixels.channels);
    if channels != 3 && channels != 4 {
        return Err(ImageError(format!("{channels} channels; 3 (RGB) or 4 (RGBA) are read")));
    }
    let width = usize::try_from(pixels.width).map_err(|_| ImageError("too wide".into()))?;
    let height = usize::try_from(pixels.height).map_err(|_| ImageError("too tall".into()))?;
    let count = width.checked_mul(height).ok_or_else(|| ImageError("too large".into()))?;
    if count == 0 {
        return Err(ImageError("the image has no pixels".into()));
    }
    let needed = count.checked_mul(channels).ok_or_else(|| ImageError("too large".into()))?;
    if pixels.data.len() < needed {
        return Err(ImageError(format!(
            "{} bytes for {width}x{height} pixels of {channels} channels ({needed} needed)",
            pixels.data.len()
        )));
    }
    // An n x n grid, n = sqrt(MAX_SAMPLES), clamped to the image.
    let side = 64usize;
    let (cols, rows) = (width.min(side), height.min(side));
    let mut out = Vec::with_capacity(cols.saturating_mul(rows));
    for row in 0..rows {
        // The center of each grid cell.
        let y = row
            .saturating_mul(2)
            .saturating_add(1)
            .saturating_mul(height)
            .checked_div(rows.saturating_mul(2))
            .unwrap_or(0);
        for col in 0..cols {
            let x = col
                .saturating_mul(2)
                .saturating_add(1)
                .saturating_mul(width)
                .checked_div(cols.saturating_mul(2))
                .unwrap_or(0);
            let index = y.saturating_mul(width).saturating_add(x).saturating_mul(channels);
            let Some(px) = pixels.data.get(index..index.saturating_add(channels)) else { continue };
            match px {
                [r, g, b] => out.push([*r, *g, *b]),
                [_, _, _, 0] => {}
                [r, g, b, _] => out.push([*r, *g, *b]),
                _ => {}
            }
        }
    }
    if out.is_empty() {
        return Err(ImageError("every pixel is transparent".into()));
    }
    Ok(out)
}

/// Median cut: splits the samples into up to `k` boxes, the box with the
/// widest channel range (weighted by its size) first, at that channel's
/// median. Returns each box's mean color and share, largest share first.
fn median_cut(mut colors: Vec<[u8; 3]>, k: usize) -> Vec<(Rgb, f64)> {
    let total = colors.len();
    colors.sort_unstable();
    let mut boxes: Vec<Vec<[u8; 3]>> = vec![colors];
    while boxes.len() < k {
        // The channel range of a box and its widest channel.
        let widest = |b: &[[u8; 3]]| -> (u8, usize) {
            (0..3usize)
                .map(|c| {
                    let lo = b.iter().filter_map(|p| p.get(c).copied()).min().unwrap_or(0);
                    let hi = b.iter().filter_map(|p| p.get(c).copied()).max().unwrap_or(0);
                    (hi.saturating_sub(lo), c)
                })
                .max_by_key(|(range, c)| (*range, usize::MAX.saturating_sub(*c)))
                .unwrap_or((0, 0))
        };
        let pick = boxes
            .iter()
            .enumerate()
            .filter(|(_, b)| b.len() > 1 && widest(b.as_slice()).0 > 0)
            .max_by(|(ia, a), (ib, b)| {
                let score = |b: &[[u8; 3]]| f64::from(widest(b).0) * (b.len() as f64).sqrt();
                score(a.as_slice()).total_cmp(&score(b.as_slice())).then(ib.cmp(ia))
            })
            .map(|(i, _)| i);
        let Some(index) = pick else { break };
        let mut taken = boxes.swap_remove(index);
        let channel = widest(taken.as_slice()).1;
        taken.sort_unstable_by_key(|p| (p.get(channel).copied().unwrap_or(0), *p));
        // Split where the channel's value changes nearest the median, so
        // one color never lands in two boxes (and is never averaged away).
        let value = |i: usize| taken.get(i).and_then(|p| p.get(channel)).copied();
        let half = taken.len().checked_div(2).unwrap_or(0);
        let changes = |i: &usize| *i > 0 && value(*i) != value(i.saturating_sub(1));
        let above = (half..taken.len()).find(changes);
        let below = (1..=half).rev().find(changes);
        let at = match (below, above) {
            (Some(b), Some(a)) => {
                if half.saturating_sub(b) <= a.saturating_sub(half) {
                    b
                } else {
                    a
                }
            }
            (Some(b), None) => b,
            (None, Some(a)) => a,
            (None, None) => break,
        };
        let upper = taken.split_off(at);
        boxes.push(taken);
        boxes.push(upper);
    }
    let mut out: Vec<(Rgb, f64)> = boxes
        .iter()
        .filter(|b| !b.is_empty())
        .map(|b| {
            let n = b.len() as f64;
            let sum =
                |c: usize| b.iter().map(|p| f64::from(p.get(c).copied().unwrap_or(0))).sum::<f64>();
            let color = Rgb::new(sum(0) / n / 255.0, sum(1) / n / 255.0, sum(2) / n / 255.0, 1.0);
            (Rgb::hex(color.to_hex()), n / total as f64)
        })
        .collect();
    // Boxes that average to the same 8-bit color are one swatch.
    out.sort_by_key(|(c, _)| c.to_hex());
    out.dedup_by(|later, kept| {
        let same = later.0.to_hex() == kept.0.to_hex();
        if same {
            kept.1 += later.1;
        }
        same
    });
    out.sort_by(|a, b| b.1.total_cmp(&a.1).then(a.0.to_hex().cmp(&b.0.to_hex())));
    out
}

/// Hue (0...360), saturation and lightness (0...1).
fn hsl(c: Rgb) -> (f64, f64, f64) {
    let max = c.r.max(c.g).max(c.b);
    let min = c.r.min(c.g).min(c.b);
    let l = (max + min) / 2.0;
    let d = max - min;
    if d <= f64::EPSILON {
        return (0.0, 0.0, l);
    }
    let s = d / (1.0 - (2.0 * l - 1.0).abs());
    let h = if (max - c.r).abs() <= f64::EPSILON {
        60.0 * ((c.g - c.b) / d).rem_euclid(6.0)
    } else if (max - c.g).abs() <= f64::EPSILON {
        60.0 * ((c.b - c.r) / d + 2.0)
    } else {
        60.0 * ((c.r - c.g) / d + 4.0)
    };
    (h.rem_euclid(360.0), s.clamp(0.0, 1.0), l)
}

fn from_hsl(h: f64, s: f64, l: f64) -> Rgb {
    let c = (1.0 - (2.0 * l - 1.0).abs()) * s;
    let hp = h.rem_euclid(360.0) / 60.0;
    let x = c * (1.0 - (hp.rem_euclid(2.0) - 1.0).abs());
    let (r, g, b) = match hp {
        h if h < 1.0 => (c, x, 0.0),
        h if h < 2.0 => (x, c, 0.0),
        h if h < 3.0 => (0.0, c, x),
        h if h < 4.0 => (0.0, x, c),
        h if h < 5.0 => (x, 0.0, c),
        _ => (c, 0.0, x),
    };
    let m = l - c / 2.0;
    Rgb::hex(Rgb::new(r + m, g + m, b + m, 1.0).to_hex())
}

/// Chroma (max - min channel), 0...1: how colorful, independent of lightness.
fn chroma(c: Rgb) -> f64 {
    c.r.max(c.g).max(c.b) - c.r.min(c.g).min(c.b)
}

fn hue_distance(a: f64, b: f64) -> f64 {
    let d = (a - b).rem_euclid(360.0);
    d.min(360.0 - d)
}

/// Pushes `color` toward `pole` until `done` holds (at most all the way).
fn toward(color: Rgb, pole: Rgb, done: impl Fn(Rgb) -> bool) -> Rgb {
    let mut t = 0.0;
    let mut out = color;
    while t < 1.0 && !done(out) {
        t += 0.02;
        out = color.mixed(pole, t);
    }
    Rgb::hex(out.to_hex())
}

/// ANSI 1...6's hues: red, green, yellow, blue, magenta, cyan.
const ANSI_HUES: [f64; 6] = [0.0, 120.0, 55.0, 220.0, 300.0, 185.0];

/// The scheme for an image's pixels. `appearance` `None` picks dark or
/// light from the image's average lightness.
pub fn palette_from_image(
    pixels: &Pixels<'_>,
    appearance: Option<Appearance>,
) -> Result<ImagePalette, ImageError> {
    let swatches = median_cut(samples(pixels)?, SWATCHES);
    let spec = spec();
    let (text_minimum, mark_minimum) = (spec.minimum_text_contrast, spec.minimum_mark_contrast);
    let mean_lightness: f64 =
        swatches.iter().map(|(c, share)| c.relative_luminance() * share).sum();
    let appearance = appearance.unwrap_or(if mean_lightness < 0.35 {
        Appearance::Dark
    } else {
        Appearance::Light
    });
    let dark = appearance == Appearance::Dark;
    let dominant = swatches.first().map_or(Rgb::BLACK, |(c, _)| *c);

    // Background: the darkest (lightest) color of the image, pushed toward
    // black (white) until it is as dark (light) as a terminal page.
    let by_lightness = |a: &&(Rgb, f64), b: &&(Rgb, f64)| {
        a.0.relative_luminance()
            .total_cmp(&b.0.relative_luminance())
            .then(a.0.to_hex().cmp(&b.0.to_hex()))
    };
    let base = if dark {
        swatches.iter().min_by(by_lightness)
    } else {
        swatches.iter().max_by(by_lightness)
    }
    .map_or(dominant, |(c, _)| *c);
    let background = if dark {
        toward(base, Rgb::BLACK, |c| c.relative_luminance() <= 0.02)
    } else {
        toward(base, Rgb::WHITE, |c| c.relative_luminance() >= 0.82)
    };
    let pole = if dark { Rgb::WHITE } else { Rgb::BLACK };
    let foreground =
        Rgb::hex(readable(pole.mixed(dominant, 0.12), background, text_minimum).to_hex());

    // Accent: the most colorful color that covers a fair part of the image.
    let colorful = swatches
        .iter()
        .filter(|(c, _)| chroma(*c) >= 0.12)
        .max_by(|a, b| {
            let score = |(c, share): &(Rgb, f64)| chroma(*c) * share.sqrt();
            score(a).total_cmp(&score(b)).then(b.0.to_hex().cmp(&a.0.to_hex()))
        })
        .map(|(c, _)| *c);
    let mean_saturation =
        swatches.iter().map(|(c, share)| hsl(*c).1 * share).sum::<f64>().clamp(0.45, 0.75);

    // ANSI 1...6: each hue from the image's nearest colorful swatch within
    // 30 degrees, else the standard hue at the image's saturation.
    let (normal_l, bright_l) = if dark { (0.62, 0.72) } else { (0.40, 0.32) };
    let hued = |target: f64, lightness: f64| -> Rgb {
        let near = swatches
            .iter()
            .filter(|(c, _)| chroma(*c) >= 0.12 && hue_distance(hsl(*c).0, target) <= 30.0)
            .max_by(|a, b| a.1.total_cmp(&b.1).then(b.0.to_hex().cmp(&a.0.to_hex())));
        let (h, s) = near.map_or((target, mean_saturation), |(c, _)| {
            let (h, s, _) = hsl(*c);
            (h, s.clamp(0.45, 0.85))
        });
        Rgb::hex(readable(from_hsl(h, s, lightness), background, mark_minimum).to_hex())
    };
    let mut palette = [Rgb::BLACK; 16];
    for (i, hue) in ANSI_HUES.iter().enumerate() {
        let index = i.saturating_add(1);
        if let Some(slot) = palette.get_mut(index) {
            *slot = hued(*hue, normal_l);
        }
        if let Some(slot) = palette.get_mut(index.saturating_add(8)) {
            *slot = hued(*hue, bright_l);
        }
    }
    let quantized = |c: Rgb| Rgb::hex(c.to_hex());
    if let Some(slot) = palette.get_mut(0) {
        *slot = quantized(background.mixed(foreground, 0.12));
    }
    if let Some(slot) = palette.get_mut(7) {
        *slot = quantized(readable(foreground.mixed(background, 0.15), background, text_minimum));
    }
    if let Some(slot) = palette.get_mut(8) {
        *slot = quantized(readable(background.mixed(foreground, 0.45), background, mark_minimum));
    }
    if let Some(slot) = palette.get_mut(15) {
        *slot = foreground;
    }

    let accent_seed = colorful.unwrap_or_else(|| palette.get(4).copied().unwrap_or(foreground));
    let accent = quantized(readable(accent_seed, background, mark_minimum));
    let scheme = Scheme {
        name: None,
        author: None,
        background,
        foreground,
        cursor: Some(accent),
        cursor_text: None,
        selection_background: None,
        selection_foreground: None,
        palette,
        accent: Some(accent),
        base16: None,
    };
    let glass_tint = ThemeTokens::derive(&scheme.theme_input()).glass_tint;
    Ok(ImagePalette { scheme, appearance, accent, glass_tint, swatches })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hsl_round_trips_the_primaries() {
        for hex in [0xFF0000, 0x00FF00, 0x0000FF, 0xFFFF00, 0x00FFFF, 0xFF00FF, 0x808080] {
            let c = Rgb::hex(hex);
            let (h, s, l) = hsl(c);
            assert_eq!(from_hsl(h, s, l).to_hex(), hex, "{hex:06x}");
        }
    }

    #[test]
    fn median_cut_splits_two_tones_by_share() {
        let mut colors = vec![[10u8, 20, 40]; 70];
        colors.extend(vec![[220u8, 110, 30]; 30]);
        let swatches = median_cut(colors, 8);
        assert_eq!(swatches.len(), 2, "{swatches:?}");
        assert_eq!(swatches[0].0.to_hex(), 0x0A1428);
        assert!((swatches[0].1 - 0.7).abs() < 1e-9);
    }
}

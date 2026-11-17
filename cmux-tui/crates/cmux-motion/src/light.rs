//! Wallpaper lighting (`appearance.wallpaperLighting`): the wallpaper read as
//! a light source for the glass in front of it. [`light_field`] reads a small
//! decode of the picture once per picture (never per frame) and finds its key
//! light (the brightest region: where, what color, how strong, how wide), its
//! ambient color and its dominant colors. From those it derives the three
//! colors the glass draws: a rim light, a bloom and a tint.
//! [`light_point`] places the key light on the container the picture fills,
//! and [`light_rim`] gives a rectangle's radial rim gradient toward it.
//!
//! All color math runs in linear light: pixels are decoded with the sRGB
//! curve (IEC 61966-2-1), averaged, weighed and scaled linearly, luminance is
//! Rec. 709 Y of the linear channels, clusters are compared in OKLab, and each
//! output is encoded back to sRGB once. Pure: no globals, no allocation past
//! the pixel copy, and no panic on any input.

use crate::color::{gamma, linear};

/// How many dominant colors [`light_field`] keeps.
pub const LIGHT_DOMINANT_COUNT: usize = 4;
/// The most pixels [`light_field`] reads; a bigger picture is rejected (the
/// host decodes small: 64 px on the long side is 4096).
pub const LIGHT_MAX_PIXELS: usize = 128 * 128;

/// The rim light's luminance (linear Y): bright enough to read on dark glass
/// whatever the picture's own brightness, never white-hot.
const RIM_LUMINANCE: f64 = 0.62;
/// The bloom's luminance: a glow, not a lamp.
const BLOOM_LUMINANCE: f64 = 0.30;
/// The share of pixels at or above the key light's threshold (the top 8%).
const KEY_QUANTILE: f64 = 0.92;
/// The k-means rounds; 4096 pixels settle well before this.
const CLUSTER_ROUNDS: usize = 12;

/// What a wallpaper shines on the glass. Colors are straight sRGB, 0..=1.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LightField {
    /// The picture's mean color (averaged in linear light).
    pub ambient: [f64; 3],
    /// The picture's mean luminance, linear Y 0..=1.
    pub ambient_luminance: f64,
    /// The key light's color: the brightest region's mean, at its own brightness.
    pub key: [f64; 3],
    /// The key light's center in the picture, 0..=1 from the left and the top.
    pub key_x: f64,
    pub key_y: f64,
    /// How much the key light stands out from the rest of the picture, 0..=1:
    /// 0 for an even picture (no rim), 1 for a sun on a night sky.
    pub key_strength: f64,
    /// How wide the bright region is, 0..=1 of the picture's diagonal: a soft
    /// sky is wide, a lamp is narrow. The rim's falloff follows it.
    pub key_spread: f64,
    /// The dominant colors, the most-covering first; `dominant_count` are set.
    pub dominant: [[f64; 3]; LIGHT_DOMINANT_COUNT],
    /// Each dominant color's share of the picture, 0..=1, summing to 1.
    pub dominant_weight: [f64; LIGHT_DOMINANT_COUNT],
    pub dominant_count: usize,
    /// The rim light: the key light's hue at [`RIM_LUMINANCE`].
    pub rim: [f64; 3],
    /// The bloom: the most colorful dominant color that covers enough of the
    /// picture, at [`BLOOM_LUMINANCE`].
    pub bloom: [f64; 3],
    /// The glass tint: the ambient hue at the ambient brightness, chroma kept.
    pub tint: [f64; 3],
}

/// The light field of an RGBA8 picture with premultiplied alpha (what a
/// `CGContext` with `premultipliedLast` writes), rows top first,
/// `bytes_per_row` apart. None for an empty picture, one larger than
/// [`LIGHT_MAX_PIXELS`], a buffer too short for its size, or a fully
/// transparent one.
pub fn light_field(
    pixels: &[u8],
    width: usize,
    height: usize,
    bytes_per_row: usize,
) -> Option<LightField> {
    let count = width.checked_mul(height)?;
    if count == 0 || count > LIGHT_MAX_PIXELS || bytes_per_row < width.checked_mul(4)? {
        return None;
    }
    let needed =
        bytes_per_row.checked_mul(height.checked_sub(1)?)?.checked_add(width.checked_mul(4)?)?;
    if pixels.len() < needed {
        return None;
    }

    // Linear RGB per pixel, alpha as a weight (transparent pixels count for nothing), rows top first.
    let samples: Vec<Sample> = pixels
        .chunks(bytes_per_row)
        .take(height)
        .flat_map(|row| row.chunks_exact(4).take(width))
        .map(|px| match *px {
            [r, g, b, a] if a > 0 => {
                let alpha = f64::from(a) / 255.0;
                let straight = |v: u8| linear((f64::from(v) / 255.0 / alpha).clamp(0.0, 1.0));
                let rgb = [straight(r), straight(g), straight(b)];
                Sample { rgb, weight: alpha, luma: luminance(rgb) }
            }
            _ => Sample { rgb: [0.0; 3], weight: 0.0, luma: 0.0 },
        })
        .collect();
    let total: f64 = samples.iter().map(|s| s.weight).sum();
    if total <= 0.0 {
        return None;
    }

    let mut mean = [0.0; 3];
    for s in &samples {
        for (m, v) in mean.iter_mut().zip(s.rgb) {
            *m += v * s.weight;
        }
    }
    let mean = mean.map(|v| v / total);
    let ambient_luminance = luminance(mean);

    let key = key_light(&samples, width, height);
    let (dominant, dominant_weight, dominant_count) = dominant_colors(&samples);

    // The bloom: chroma times the square root of coverage, so a small vivid
    // accent beats a wide grey, and a speck never wins.
    let score = |(color, share): &([f64; 3], f64)| chroma(*color) * share.sqrt();
    let bloom_source = dominant
        .iter()
        .copied()
        .zip(dominant_weight)
        .take(dominant_count)
        .filter(|(_, share)| *share >= 0.03)
        .max_by(|a, b| score(a).total_cmp(&score(b)))
        .map_or(mean, |(color, _)| color);

    let encode = |c: [f64; 3]| c.map(|v| gamma(v.clamp(0.0, 1.0)).clamp(0.0, 1.0));
    Some(LightField {
        ambient: encode(mean),
        ambient_luminance,
        key: encode(key.color),
        key_x: key.x,
        key_y: key.y,
        key_strength: key.strength,
        key_spread: key.spread,
        dominant: dominant.map(encode),
        dominant_weight,
        dominant_count,
        rim: encode(at_luminance(key.color, RIM_LUMINANCE)),
        bloom: encode(at_luminance(bloom_source, BLOOM_LUMINANCE)),
        tint: encode(mean),
    })
}

/// Where the key light falls on a container of `width` by `height` that the
/// picture fills (aspect fill, centered: what macOS does with a desktop
/// picture and the window does with its art), in the container's points from
/// its top left. A light cropped off the container lies outside it.
pub fn light_point(field: &LightField, picture_aspect: f64, width: f64, height: f64) -> (f64, f64) {
    if !(picture_aspect.is_finite() && picture_aspect > 0.0 && width > 0.0 && height > 0.0) {
        return (field.key_x * width.max(0.0), field.key_y * height.max(0.0));
    }
    // The drawn picture's size: as wide as the container or as tall, whichever covers it.
    let (drawn_w, drawn_h) = if width / height > picture_aspect {
        (width, width / picture_aspect)
    } else {
        (height * picture_aspect, height)
    };
    let x = (width - drawn_w) / 2.0 + field.key_x * drawn_w;
    let y = (height - drawn_h) / 2.0 + field.key_y * drawn_h;
    (x, y)
}

/// A rectangle's rim light: a radial gradient centered on the light, in the
/// rectangle's unit space (0..=1 across it; a light outside it is outside
/// 0..=1), the shape a `CAGradientLayer` of type radial and a CSS
/// `radial-gradient` both take, and the rim's peak opacity.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LightRim {
    /// The gradient's center, the light, in the rectangle's unit space.
    pub center_x: f64,
    pub center_y: f64,
    /// The gradient's radii in the rectangle's unit space (one container
    /// radius in points, divided by the rectangle's width and height).
    pub radius_x: f64,
    pub radius_y: f64,
    /// The rim's opacity where it is nearest the light, 0..=1.
    pub alpha: f64,
}

/// The rim light on the rectangle `x, y, width, height` of a container whose
/// key light sits at `light_x, light_y` (both in the container's points; see
/// [`light_point`]), for a container `diagonal` points across. The reach
/// grows with the key light's spread; the opacity follows its strength and
/// falls off with the rectangle's distance from the light, so the pane nearest
/// the bright region glows most. None for a degenerate rectangle.
#[allow(clippy::too_many_arguments)]
pub fn light_rim(
    field: &LightField,
    light_x: f64,
    light_y: f64,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    diagonal: f64,
) -> Option<LightRim> {
    let valid = width > 0.0
        && height > 0.0
        && diagonal > 0.0
        && [light_x, light_y, x, y].iter().all(|v| v.is_finite());
    if !valid {
        return None;
    }
    // A narrow light reaches half the container; a sky reaches all of it.
    let reach = diagonal * (0.5 + 0.7 * field.key_spread.clamp(0.0, 1.0));
    // The rectangle's nearest point to the light.
    let near_x = light_x.clamp(x, x + width);
    let near_y = light_y.clamp(y, y + height);
    let distance = ((near_x - light_x).powi(2) + (near_y - light_y).powi(2)).sqrt();
    let falloff = (1.0 - distance / reach).clamp(0.0, 1.0);
    // A floor keeps a far pane faintly lit on its facing edge.
    let alpha = field.key_strength.clamp(0.0, 1.0) * (0.25 + 0.75 * falloff * falloff);
    Some(LightRim {
        center_x: (light_x - x) / width,
        center_y: (light_y - y) / height,
        radius_x: (distance + reach) / width,
        radius_y: (distance + reach) / height,
        alpha,
    })
}

/// What a page's glass draws from the light (`webviews` glass.css WALLPAPER
/// LIGHTING): the direction toward the light, and the strength of the rim,
/// the bloom and the tint.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LightStyle {
    /// The unit direction from the rectangle's center toward the key light,
    /// y down; straight up for a light at the center.
    pub dx: f64,
    pub dy: f64,
    /// The rim's opacity ([`light_rim`]'s), 0..=1.
    pub rim_alpha: f64,
    /// The bloom's opacity, 0..=1: more on a dark picture, where a glow
    /// reads, than on a bright one, where it would only grey the glass.
    pub bloom_alpha: f64,
    /// How far the glass surface leans toward the picture's mean color, 0..=1.
    pub tint_share: f64,
}

/// The light style of the rectangle `x, y, width, height` (a window, in the
/// container's points), with the same inputs as [`light_rim`]. None for a
/// degenerate rectangle.
#[allow(clippy::too_many_arguments)]
pub fn light_style(
    field: &LightField,
    light_x: f64,
    light_y: f64,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    diagonal: f64,
) -> Option<LightStyle> {
    let rim = light_rim(field, light_x, light_y, x, y, width, height, diagonal)?;
    let (vx, vy) = (light_x - (x + width / 2.0), light_y - (y + height / 2.0));
    let length = (vx * vx + vy * vy).sqrt();
    let (dx, dy) = if length > 1e-6 { (vx / length, vy / length) } else { (0.0, -1.0) };
    let dark = 1.0 - field.ambient_luminance.clamp(0.0, 1.0).sqrt();
    Some(LightStyle {
        dx,
        dy,
        rim_alpha: rim.alpha,
        bloom_alpha: (0.12 + 0.38 * dark) * (0.6 + 0.4 * field.key_strength.clamp(0.0, 1.0)),
        tint_share: 0.08 + 0.10 * dark,
    })
}

fn luminance(c: [f64; 3]) -> f64 {
    0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
}

/// A linear color's distance from the grey of its own luminance.
fn chroma(c: [f64; 3]) -> f64 {
    let y = luminance(c);
    ((c[0] - y).powi(2) + (c[1] - y).powi(2) + (c[2] - y).powi(2)).sqrt()
}

/// `c` (linear) scaled to luminance `target`, hue kept; a channel that would
/// pass 1 is pulled toward white at the same luminance, so a saturated blue
/// brightened stays blue rather than clipping to cyan. A black `c` gives grey.
fn at_luminance(c: [f64; 3], target: f64) -> [f64; 3] {
    let y = luminance(c);
    if y <= 1e-6 {
        return [target; 3];
    }
    let scaled = c.map(|v| v * target / y);
    let peak = scaled.iter().cloned().fold(0.0, f64::max);
    if peak <= 1.0 {
        return scaled;
    }
    // Mix toward grey `target` until the peak channel is 1.
    let t = (peak - 1.0) / (peak - target);
    scaled.map(|v| v + (target - v) * t)
}

struct KeyLight {
    color: [f64; 3],
    x: f64,
    y: f64,
    strength: f64,
    spread: f64,
}

/// One pixel, decoded: linear RGB, its alpha as a weight, and its luminance.
#[derive(Clone, Copy)]
struct Sample {
    rgb: [f64; 3],
    weight: f64,
    luma: f64,
}

/// The brightest region: the peak of the luminance blurred over a ninth of
/// the picture, then the luminance-weighted center and color of the bright
/// pixels around that peak (pixels past the top [`KEY_QUANTILE`] within the
/// blur's reach twice over), so two separate highlights never average into
/// the dark between them.
fn key_light(samples: &[Sample], width: usize, height: usize) -> KeyLight {
    let radius = (width.max(height) / 9).max(1);
    let blurred = box_blur(samples, width, height, radius);
    let (peak, peak_value) = blurred
        .iter()
        .enumerate()
        .fold((0, f64::MIN), |best, (i, &v)| if v > best.1 { (i, v) } else { best });
    let (peak_x, peak_y) = (peak % width, peak / width);

    let mut sorted: Vec<f64> = samples.iter().filter(|s| s.weight > 0.0).map(|s| s.luma).collect();
    sorted.sort_by(f64::total_cmp);
    let last = sorted.len().saturating_sub(1);
    let quantile = |q: f64| sorted.get((last as f64 * q) as usize).copied().unwrap_or(0.0);
    let threshold = quantile(KEY_QUANTILE);
    let median = quantile(0.5);

    let reach = radius.saturating_mul(2);
    let mut sum = (0.0, 0.0, 0.0, [0.0; 3]);
    let mut bright = 0usize;
    for (i, s) in samples.iter().enumerate() {
        if s.weight <= 0.0 || s.luma < threshold {
            continue;
        }
        bright += 1;
        let (x, y) = (i % width, i / width);
        if x.abs_diff(peak_x) > reach || y.abs_diff(peak_y) > reach {
            continue;
        }
        let w = (s.luma - threshold + 1e-4) * s.weight;
        sum.0 += w;
        sum.1 += w * (x as f64 + 0.5);
        sum.2 += w * (y as f64 + 0.5);
        for (acc, v) in sum.3.iter_mut().zip(s.rgb) {
            *acc += w * v;
        }
    }
    let (cx, cy, color) = if sum.0 > 0.0 {
        (sum.1 / sum.0 / width as f64, sum.2 / sum.0 / height as f64, sum.3.map(|v| v / sum.0))
    } else {
        let peak_color = samples.get(peak).map_or([0.0; 3], |s| s.rgb);
        ((peak_x as f64 + 0.5) / width as f64, (peak_y as f64 + 0.5) / height as f64, peak_color)
    };
    // Contrast of the blurred peak over the median, as a Weber fraction squashed to 0..=1.
    let contrast = (peak_value - median).max(0.0) / (median + 0.05);
    let strength = (contrast / (contrast + 0.75)).clamp(0.0, 1.0);
    let spread = (bright as f64 / samples.len() as f64 / (1.0 - KEY_QUANTILE)).clamp(0.0, 1.0)
        * (1.0 - strength * 0.5);
    KeyLight { color, x: cx, y: cy, strength, spread }
}

/// The alpha-weighted mean luminance over a square of `radius` around each
/// pixel, through summed-area tables (one row and one column of zeros first).
fn box_blur(samples: &[Sample], width: usize, height: usize, radius: usize) -> Vec<f64> {
    let stride = width + 1;
    let cells = stride * (height + 1);
    let mut sum_v: Vec<f64> = Vec::with_capacity(cells);
    let mut sum_w: Vec<f64> = Vec::with_capacity(cells);
    sum_v.resize(stride, 0.0);
    sum_w.resize(stride, 0.0);
    // `table[at]` (0 off the table) for a table being filled: its left, upper and upper-left neighbors.
    let get =
        |table: &[f64], at: Option<usize>| at.and_then(|at| table.get(at)).copied().unwrap_or(0.0);
    let next = |table: &[f64], value: f64| {
        let at = table.len();
        value + get(table, at.checked_sub(1)) + get(table, at.checked_sub(stride))
            - get(table, at.checked_sub(stride + 1))
    };
    for row in samples.chunks(width).take(height) {
        sum_v.push(0.0);
        sum_w.push(0.0);
        for s in row {
            let v = next(&sum_v, s.luma * s.weight);
            let w = next(&sum_w, s.weight);
            sum_v.push(v);
            sum_w.push(w);
        }
    }
    let area = |table: &[f64], x0: usize, y0: usize, x1: usize, y1: usize| {
        get(table, Some(y1 * stride + x1))
            - get(table, Some(y0 * stride + x1))
            - get(table, Some(y1 * stride + x0))
            + get(table, Some(y0 * stride + x0))
    };
    let mut out = Vec::with_capacity(width * height);
    for y in 0..height {
        for x in 0..width {
            let (x0, y0) = (x.saturating_sub(radius), y.saturating_sub(radius));
            let (x1, y1) = ((x + radius + 1).min(width), (y + radius + 1).min(height));
            let w = area(&sum_w, x0, y0, x1, y1);
            out.push(if w > 0.0 { area(&sum_v, x0, y0, x1, y1) / w } else { 0.0 });
        }
    }
    out
}

fn oklab(c: [f64; 3]) -> [f64; 3] {
    let l = (0.412_221_470_8 * c[0] + 0.536_332_536_3 * c[1] + 0.051_445_992_9 * c[2]).cbrt();
    let m = (0.211_903_498_2 * c[0] + 0.680_699_545_1 * c[1] + 0.107_396_956_6 * c[2]).cbrt();
    let s = (0.088_302_461_9 * c[0] + 0.281_718_837_6 * c[1] + 0.629_978_700_5 * c[2]).cbrt();
    [
        0.210_454_255_3 * l + 0.793_617_785 * m - 0.004_072_046_8 * s,
        1.977_998_495_1 * l - 2.428_592_205 * m + 0.450_593_709_9 * s,
        0.025_904_037_1 * l + 0.782_771_766_2 * m - 0.808_675_766 * s,
    ]
}

fn distance2(a: [f64; 3], b: [f64; 3]) -> f64 {
    (a[0] - b[0]).powi(2) + (a[1] - b[1]).powi(2) + (a[2] - b[2]).powi(2)
}

type Dominant = ([[f64; 3]; LIGHT_DOMINANT_COUNT], [f64; LIGHT_DOMINANT_COUNT], usize);

/// A pixel that counts (alpha above zero), with its OKLab color for the
/// assignment and the center it is assigned to.
struct Member {
    rgb: [f64; 3],
    lab: [f64; 3],
    weight: f64,
    center: usize,
}

/// K-means over the pixels: assigned by OKLab distance (perceptual), each
/// center the alpha-weighted mean of its pixels in linear light. Seeded
/// deterministically: the pixel farthest from the mean, then each next
/// farthest from every seed so far, so one picture always gives one answer.
/// Clusters that end empty or nearly identical are dropped; sorted by weight.
fn dominant_colors(samples: &[Sample]) -> Dominant {
    let mut members: Vec<Member> = samples
        .iter()
        .filter(|s| s.weight > 0.0)
        .map(|s| Member { rgb: s.rgb, lab: oklab(s.rgb), weight: s.weight, center: 0 })
        .collect();
    let mut lab_mean = [0.0; 3];
    for m in &members {
        for (acc, v) in lab_mean.iter_mut().zip(m.lab) {
            *acc += v;
        }
    }
    let lab_mean = lab_mean.map(|v| v / members.len().max(1) as f64);
    let mut centers: Vec<[f64; 3]> = Vec::with_capacity(LIGHT_DOMINANT_COUNT);
    let mut nearest: Vec<f64> = members.iter().map(|m| distance2(m.lab, lab_mean)).collect();
    while centers.len() < LIGHT_DOMINANT_COUNT {
        let Some((seed, far)) = members
            .iter()
            .zip(&nearest)
            .max_by(|a, b| a.1.total_cmp(b.1))
            .map(|(m, &far)| (m.lab, far))
        else {
            break;
        };
        // Every pixel already sits on a center: fewer colors than slots.
        if !centers.is_empty() && far < 1e-5 {
            break;
        }
        centers.push(seed);
        for (n, m) in nearest.iter_mut().zip(&members) {
            *n = n.min(distance2(m.lab, seed));
        }
    }

    // Each center's linear mean and weight after the last round.
    let mut clusters: Vec<([f64; 3], f64)> = vec![([0.0; 3], 0.0); centers.len()];
    for _ in 0..CLUSTER_ROUNDS {
        let mut changed = false;
        for m in &mut members {
            let best = centers
                .iter()
                .enumerate()
                .min_by(|a, b| distance2(m.lab, *a.1).total_cmp(&distance2(m.lab, *b.1)))
                .map_or(0, |(i, _)| i);
            changed |= m.center != best;
            m.center = best;
        }
        clusters.iter_mut().for_each(|c| *c = ([0.0; 3], 0.0));
        for m in &members {
            if let Some((sum, weight)) = clusters.get_mut(m.center) {
                *weight += m.weight;
                for (acc, v) in sum.iter_mut().zip(m.rgb) {
                    *acc += v * m.weight;
                }
            }
        }
        for (sum, weight) in &mut clusters {
            if *weight > 0.0 {
                *sum = sum.map(|v| v / *weight);
            }
        }
        for (center, (linear, _)) in centers.iter_mut().zip(&clusters) {
            *center = oklab(*linear);
        }
        if !changed {
            break;
        }
    }

    let total: f64 = clusters.iter().map(|(_, w)| w).sum();
    clusters.retain(|(_, w)| *w > 0.0);
    clusters.sort_by(|a, b| b.1.total_cmp(&a.1));
    let mut colors = [[0.0; 3]; LIGHT_DOMINANT_COUNT];
    let mut shares = [0.0; LIGHT_DOMINANT_COUNT];
    for ((color, share), (linear, weight)) in
        colors.iter_mut().zip(shares.iter_mut()).zip(&clusters)
    {
        *color = *linear;
        *share = if total > 0.0 { weight / total } else { 0.0 };
    }
    (colors, shares, clusters.len().min(LIGHT_DOMINANT_COUNT))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// An opaque `w` by `h` picture painted by `paint(x, y) -> sRGB bytes`.
    fn picture(w: usize, h: usize, paint: impl Fn(usize, usize) -> [u8; 3]) -> Vec<u8> {
        let mut out = Vec::with_capacity(w * h * 4);
        for y in 0..h {
            for x in 0..w {
                let [r, g, b] = paint(x, y);
                out.extend_from_slice(&[r, g, b, 255]);
            }
        }
        out
    }

    #[test]
    fn rejects_bad_input() {
        assert!(light_field(&[], 0, 0, 0).is_none());
        assert!(light_field(&[0; 15], 2, 2, 8).is_none(), "buffer too short");
        assert!(light_field(&[0; 16], 2, 2, 4).is_none(), "row shorter than its pixels");
        assert!(light_field(&[0; 16], 2, 2, 8).is_none(), "fully transparent");
        let big = vec![255u8; 129 * 128 * 4];
        assert!(light_field(&big, 129, 128, 129 * 4).is_none(), "past the pixel cap");
    }

    #[test]
    fn ambient_averages_in_linear_light() {
        // Half black, half white: the linear mean is Y 0.5, which sRGB encodes
        // as ~188, not the gamma-space mean 128.
        let px = picture(8, 8, |x, _| if x < 4 { [0, 0, 0] } else { [255, 255, 255] });
        let field = light_field(&px, 8, 8, 32).unwrap();
        assert!((field.ambient_luminance - 0.5).abs() < 1e-9);
        let encoded = (field.ambient[0] * 255.0).round();
        assert_eq!(encoded, 188.0, "the mean is encoded once, from linear");
    }

    #[test]
    fn finds_the_bright_region_and_its_color() {
        // A dark navy sky with a warm sun at the upper right.
        let px = picture(64, 40, |x, y| {
            let d = ((x as f64 - 50.0).powi(2) + (y as f64 - 8.0).powi(2)).sqrt();
            if d < 5.0 { [255, 200, 120] } else { [12, 18, 40] }
        });
        let field = light_field(&px, 64, 40, 256).unwrap();
        assert!((field.key_x - 50.5 / 64.0).abs() < 0.04, "key_x {}", field.key_x);
        assert!((field.key_y - 8.5 / 40.0).abs() < 0.05, "key_y {}", field.key_y);
        assert!(field.key_strength > 0.8, "a sun on a night sky is strong: {}", field.key_strength);
        // The rim keeps the sun's warm hue: red over green over blue.
        assert!(field.rim[0] > field.rim[1] && field.rim[1] > field.rim[2], "rim {:?}", field.rim);
        let rim_y = luminance(field.rim.map(linear));
        assert!((rim_y - RIM_LUMINANCE).abs() < 0.01, "rim at its luminance: {rim_y}");
        assert!(field.dominant_count >= 2);
        assert!(field.dominant_weight[0] > 0.8, "the sky covers most of it");
    }

    #[test]
    fn two_highlights_never_average_into_the_dark_between() {
        let px = picture(64, 32, |x, y| {
            let left = ((x as f64 - 8.0).powi(2) + (y as f64 - 16.0).powi(2)).sqrt() < 4.0;
            let right = ((x as f64 - 56.0).powi(2) + (y as f64 - 16.0).powi(2)).sqrt() < 3.0;
            if left || right { [250, 250, 250] } else { [20, 20, 20] }
        });
        let field = light_field(&px, 64, 32, 256).unwrap();
        let x = field.key_x * 64.0;
        assert!(!(16.0..48.0).contains(&x), "key light at a highlight, not between: {x}");
    }

    #[test]
    fn an_even_picture_has_no_key_light() {
        let px = picture(32, 32, |_, _| [90, 120, 160]);
        let field = light_field(&px, 32, 32, 128).unwrap();
        assert!(field.key_strength < 0.01, "{}", field.key_strength);
        assert_eq!(field.dominant_count, 1);
        assert!((field.dominant_weight[0] - 1.0).abs() < 1e-9);
    }

    #[test]
    fn same_picture_same_answer() {
        let px = picture(48, 27, |x, y| [(x * 5) as u8, (y * 9) as u8, ((x + y) * 3) as u8]);
        assert_eq!(light_field(&px, 48, 27, 192), light_field(&px, 48, 27, 192));
    }

    #[test]
    fn premultiplied_alpha_is_unpremultiplied() {
        // A half-transparent mid red reads as mid red, not dark red.
        let px: Vec<u8> = (0..16).flat_map(|_| [64u8, 0, 0, 128]).collect();
        let field = light_field(&px, 4, 4, 16).unwrap();
        assert!((field.ambient[0] - 128.0 / 255.0).abs() < 0.01, "{:?}", field.ambient);
    }

    #[test]
    fn bright_saturated_colors_stay_in_gamut_and_hue() {
        let blue = at_luminance([0.0, 0.0, 1.0], RIM_LUMINANCE);
        assert!(blue.iter().all(|v| (0.0..=1.0 + 1e-9).contains(v)), "{blue:?}");
        assert!((luminance(blue) - RIM_LUMINANCE).abs() < 1e-9);
        assert!(blue[2] > blue[0] && blue[2] > blue[1], "still blue: {blue:?}");
        assert_eq!(at_luminance([0.0; 3], 0.3), [0.3; 3]);
    }

    #[test]
    fn light_point_follows_aspect_fill() {
        let field = LightField { key_x: 1.0, key_y: 0.5, ..even_field() };
        // A 2:1 picture on a square container is cropped at the sides: its
        // right edge lies half a width past the container's.
        let (x, y) = light_point(&field, 2.0, 100.0, 100.0);
        assert!((x - 150.0).abs() < 1e-9 && (y - 50.0).abs() < 1e-9, "({x}, {y})");
        // The same aspect as the container maps straight across.
        let (x, y) = light_point(&field, 1.0, 100.0, 100.0);
        assert!((x - 100.0).abs() < 1e-9 && (y - 50.0).abs() < 1e-9);
    }

    #[test]
    fn the_rect_nearest_the_light_glows_most() {
        let field = LightField { key_strength: 1.0, key_spread: 0.2, ..even_field() };
        let near = light_rim(&field, 0.0, 0.0, 10.0, 10.0, 100.0, 100.0, 1000.0).unwrap();
        let far = light_rim(&field, 0.0, 0.0, 800.0, 500.0, 100.0, 100.0, 1000.0).unwrap();
        assert!(near.alpha > far.alpha && far.alpha > 0.0, "{} {}", near.alpha, far.alpha);
        assert!((near.center_x + 0.1).abs() < 1e-9, "light left of the rect in unit space");
        assert!(light_rim(&field, 0.0, 0.0, 0.0, 0.0, 0.0, 10.0, 100.0).is_none());
        assert!(light_rim(&field, f64::NAN, 0.0, 0.0, 0.0, 10.0, 10.0, 100.0).is_none());
    }

    #[test]
    fn style_points_at_the_light_and_glows_more_on_dark_pictures() {
        let dark = LightField {
            key_strength: 0.8,
            key_spread: 0.4,
            ambient_luminance: 0.05,
            ..even_field()
        };
        let bright = LightField { ambient_luminance: 0.7, ..dark };
        // Light at the top right of a window at the origin.
        let style = light_style(&dark, 300.0, 0.0, 0.0, 0.0, 200.0, 200.0, 1000.0).unwrap();
        assert!(style.dx > 0.7 && style.dy < -0.3, "{style:?}");
        assert!(
            ((style.dx * style.dx + style.dy * style.dy) - 1.0).abs() < 1e-9,
            "a unit direction"
        );
        let lit = light_style(&bright, 300.0, 0.0, 0.0, 0.0, 200.0, 200.0, 1000.0).unwrap();
        assert!(style.bloom_alpha > lit.bloom_alpha && style.tint_share > lit.tint_share);
        let centered = light_style(&dark, 100.0, 100.0, 0.0, 0.0, 200.0, 200.0, 1000.0).unwrap();
        assert_eq!(
            (centered.dx, centered.dy),
            (0.0, -1.0),
            "a light at the center lights from above"
        );
    }

    fn even_field() -> LightField {
        LightField {
            ambient: [0.5; 3],
            ambient_luminance: 0.2,
            key: [1.0; 3],
            key_x: 0.5,
            key_y: 0.5,
            key_strength: 0.0,
            key_spread: 0.0,
            dominant: [[0.5; 3]; LIGHT_DOMINANT_COUNT],
            dominant_weight: [1.0, 0.0, 0.0, 0.0],
            dominant_count: 1,
            rim: [1.0; 3],
            bloom: [0.5; 3],
            tint: [0.5; 3],
        }
    }
}

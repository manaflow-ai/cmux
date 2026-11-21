//! `saliency`: a cheap saliency map on a small buffer, cut into a few
//! weighted [`Salient`] regions in source pixels.
//!
//! The picture is area-averaged down to a grid of at most `grid` cells on its
//! long side (64 by default: 64x40 for a 16:10 wallpaper), in an opponent
//! colour space (luma, red-green, yellow-blue; luma only for a grey buffer).
//! Three cues, each scaled to [0, 1]:
//!
//! - global contrast: a cell's distance from the picture's mean colour
//!   (frequency-tuned saliency, Achanta et al. 2009);
//! - centre-surround: a small blur against a wide one at two scales, which
//!   finds a figure against its own neighbourhood;
//! - detail: blurred gradient energy, which tells a painted figure from a
//!   smooth sky, fog or a blurred fill.
//!
//! Their weighted sum gets a mild centre prior, then everything above a
//! threshold between the mean and the peak is cut into 8-connected
//! components. Each component's box (padded by one cell) is a region; its
//! weight is its share of the saliency kept. The heaviest `max_regions` are
//! returned, heaviest first. Same buffer, same regions.
//!
//! Cost: one pass over the source to downsample, then a few passes over at
//! most 64x64 cells. The downsample dominates: about 6 ms for a 1600x1000
//! RGB picture in a release build; hand it a thumbnail to go faster.

// Pure and panic-free on any buffer.
#![cfg_attr(
    not(test),
    deny(
        clippy::unwrap_used,
        clippy::expect_used,
        clippy::panic,
        clippy::indexing_slicing,
        clippy::unreachable,
        clippy::todo,
        clippy::unimplemented
    )
)]

use crate::fit::Salient;

/// Knobs for [`saliency_rgb`] and [`saliency_luma`].
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SaliencyOptions {
    /// Cells on the grid's long side (clamped to 8..=256).
    pub grid: usize,
    /// At most this many regions come back.
    pub max_regions: usize,
    /// Strength of the centre prior: 0 none, 1 the corners count for nothing.
    pub center_prior: f32,
    /// Threshold between the map's mean (0) and its peak (1).
    pub threshold: f32,
    /// Components smaller than this fraction of the grid are dropped.
    pub min_area: f32,
}

impl Default for SaliencyOptions {
    fn default() -> Self {
        Self { grid: 64, max_regions: 4, center_prior: 0.3, threshold: 0.45, min_area: 0.004 }
    }
}

/// A saliency map on the grid: `values` row-major, `w * h` of them in [0, 1].
#[derive(Clone, Debug, Default, PartialEq)]
pub struct SaliencyMap {
    pub w: usize,
    pub h: usize,
    /// Source pixels per cell along x and y.
    pub scale_x: f64,
    pub scale_y: f64,
    pub values: Vec<f32>,
}

/// Regions of an 8-bit RGB buffer (`width * height * 3` bytes, row-major,
/// no padding). A buffer too short for its size, or a zero size, gives none.
pub fn saliency_rgb(rgb: &[u8], width: usize, height: usize) -> Vec<Salient> {
    let options = SaliencyOptions::default();
    regions(&saliency_map(rgb, 3, width, height, options), options)
}

/// Regions of an 8-bit luma buffer (`width * height` bytes).
pub fn saliency_luma(luma: &[u8], width: usize, height: usize) -> Vec<Salient> {
    let options = SaliencyOptions::default();
    regions(&saliency_map(luma, 1, width, height, options), options)
}

/// Regions of a map from [`saliency_map`], with explicit options.
pub fn regions(map: &SaliencyMap, options: SaliencyOptions) -> Vec<Salient> {
    let (w, h) = (map.w, map.h);
    let n = w.saturating_mul(h);
    if n == 0 || map.values.len() < n || options.max_regions == 0 {
        return Vec::new();
    }
    let values = map.values.get(..n).unwrap_or_default();
    let mean = values.iter().sum::<f32>() / n as f32;
    let peak = values.iter().copied().fold(0.0f32, f32::max);
    if peak <= 0.0 || !(peak.is_finite() && mean.is_finite()) {
        return Vec::new();
    }
    let t = options.threshold.clamp(0.0, 1.0);
    let cut = mean + t * (peak - mean);
    let mask: Vec<bool> = values.iter().map(|&v| v >= cut && v > 0.0).collect();

    let mut seen = vec![false; n];
    let mut found: Vec<(f64, usize, usize, usize, usize, usize)> = Vec::new();
    let mut stack = Vec::new();
    for start in 0..n {
        if seen.get(start).copied().unwrap_or(true) || !mask.get(start).copied().unwrap_or(false) {
            continue;
        }
        if let Some(s) = seen.get_mut(start) {
            *s = true;
        }
        stack.push(start);
        let (mut x0, mut y0, mut x1, mut y1) = (w, h, 0usize, 0usize);
        let mut mass = 0.0f64;
        let mut cells = 0usize;
        while let Some(i) = stack.pop() {
            let (x, y) = (i % w, i / w);
            x0 = x0.min(x);
            y0 = y0.min(y);
            x1 = x1.max(x);
            y1 = y1.max(y);
            mass += f64::from(values.get(i).copied().unwrap_or(0.0) - cut * 0.5);
            cells += 1;
            for (dx, dy) in NEIGHBOURS {
                let (Some(nx), Some(ny)) = (x.checked_add_signed(dx), y.checked_add_signed(dy))
                else {
                    continue;
                };
                if nx >= w || ny >= h {
                    continue;
                }
                let j = ny * w + nx;
                if mask.get(j).copied().unwrap_or(false) && !seen.get(j).copied().unwrap_or(true) {
                    if let Some(s) = seen.get_mut(j) {
                        *s = true;
                    }
                    stack.push(j);
                }
            }
        }
        if (cells as f32) < options.min_area.max(0.0) * n as f32 {
            continue;
        }
        found.push((mass, cells, x0, y0, x1, y1));
    }
    // Heaviest first; equal mass keeps scan order (stable), so deterministic.
    found.sort_by(|a, b| b.0.total_cmp(&a.0));
    found.truncate(options.max_regions);
    let total: f64 = found.iter().map(|f| f.0.max(0.0)).sum();
    if total <= 0.0 {
        return Vec::new();
    }
    found
        .into_iter()
        .map(|(mass, _, x0, y0, x1, y1)| {
            // Pad one cell (the threshold trims a figure's soft edge).
            let gx0 = x0.saturating_sub(1) as f64;
            let gy0 = y0.saturating_sub(1) as f64;
            let gx1 = (x1 + 2).min(w) as f64;
            let gy1 = (y1 + 2).min(h) as f64;
            Salient::new(
                gx0 * map.scale_x,
                gy0 * map.scale_y,
                (gx1 - gx0) * map.scale_x,
                (gy1 - gy0) * map.scale_y,
                mass.max(0.0) / total,
            )
        })
        .collect()
}

const NEIGHBOURS: [(isize, isize); 8] =
    [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)];

/// The saliency map of an 8-bit buffer with `channels` bytes per pixel (1:
/// luma; 3 or 4: RGB or RGBA, alpha ignored). Bad sizes give an empty map.
pub fn saliency_map(
    pixels: &[u8],
    channels: usize,
    width: usize,
    height: usize,
    options: SaliencyOptions,
) -> SaliencyMap {
    let Some(planes) = downsample(pixels, channels, width, height, options.grid) else {
        return SaliencyMap::default();
    };
    let (gw, gh) = (planes.w, planes.h);
    let n = gw * gh;

    let mut global = vec![0.0f32; n];
    let mut surround = vec![0.0f32; n];
    let mut detail = vec![0.0f32; n];
    let long = gw.max(gh);
    let (r_s1, r_s2) = ((long / 10).max(2), (long / 5).max(4));
    for plane in &planes.planes {
        let mean = plane.iter().sum::<f32>() / n as f32;
        let fine = box_blur(plane, gw, gh, 1);
        let wide1 = box_blur(plane, gw, gh, r_s1);
        let wide2 = box_blur(plane, gw, gh, r_s2);
        for i in 0..n {
            let f = at(&fine, i);
            add(&mut global, i, (f - mean) * (f - mean));
            add(&mut surround, i, (f - at(&wide1, i)).abs() + (f - at(&wide2, i)).abs());
        }
        // Gradient energy of the raw plane.
        for y in 0..gh {
            for x in 0..gw {
                let i = y * gw + x;
                let right = if x + 1 < gw { i + 1 } else { i };
                let down = if y + 1 < gh { i + gw } else { i };
                let gx = at(plane, right) - at(plane, i);
                let gy = at(plane, down) - at(plane, i);
                add(&mut detail, i, gx * gx + gy * gy);
            }
        }
    }
    for v in &mut global {
        *v = v.sqrt();
    }
    let detail = box_blur(&detail.iter().map(|v| v.sqrt()).collect::<Vec<_>>(), gw, gh, 2);
    normalize(&mut global);
    normalize(&mut surround);
    let mut detail = detail;
    normalize(&mut detail);

    let prior = options.center_prior.clamp(0.0, 1.0);
    let mut values = vec![0.0f32; n];
    for y in 0..gh {
        for x in 0..gw {
            let i = y * gw + x;
            let s = 0.3 * at(&global, i) + 0.4 * at(&surround, i) + 0.3 * at(&detail, i);
            let dx = (x as f32 + 0.5) / gw as f32 - 0.5;
            let dy = (y as f32 + 0.5) / gh as f32 - 0.5;
            let d2 = (dx * dx + dy * dy) / (2.0 * 0.3 * 0.3);
            let c = 1.0 - prior + prior * (-d2).exp();
            if let Some(v) = values.get_mut(i) {
                *v = s * c;
            }
        }
    }
    let mut values = box_blur(&values, gw, gh, 1);
    normalize(&mut values);
    SaliencyMap {
        w: gw,
        h: gh,
        scale_x: width as f64 / gw as f64,
        scale_y: height as f64 / gh as f64,
        values,
    }
}

struct Planes {
    w: usize,
    h: usize,
    planes: Vec<Vec<f32>>,
}

/// Area-average the buffer onto a grid of at most `grid` cells on its long
/// side, as opponent-colour planes in [0, 1]-ish units.
fn downsample(
    pixels: &[u8],
    channels: usize,
    width: usize,
    height: usize,
    grid: usize,
) -> Option<Planes> {
    if !matches!(channels, 1 | 3 | 4) || width == 0 || height == 0 {
        return None;
    }
    let needed = width.checked_mul(height)?.checked_mul(channels)?;
    if pixels.len() < needed {
        return None;
    }
    let grid = grid.clamp(8, 256);
    let (gw, gh) = if width >= height {
        let gh = (grid as f64 * height as f64 / width as f64).round() as usize;
        (grid.min(width), gh.clamp(1, height))
    } else {
        let gw = (grid as f64 * width as f64 / height as f64).round() as usize;
        (gw.clamp(1, width), grid.min(height))
    };
    let n = gw * gh;
    let colour = channels >= 3;
    let mut sums = vec![[0.0f64; 3]; n];
    let mut counts = vec![0u32; n];
    for y in 0..height {
        let gy = (y * gh / height).min(gh - 1);
        let row = pixels.get(y * width * channels..(y + 1) * width * channels)?;
        for (x, px) in row.chunks_exact(channels).enumerate() {
            let gx = (x * gw / width).min(gw - 1);
            let cell = gy * gw + gx;
            let (l, a, b) = if colour {
                let r = f64::from(px.first().copied().unwrap_or(0)) / 255.0;
                let g = f64::from(px.get(1).copied().unwrap_or(0)) / 255.0;
                let bl = f64::from(px.get(2).copied().unwrap_or(0)) / 255.0;
                (0.299 * r + 0.587 * g + 0.114 * bl, r - g, (r + g) / 2.0 - bl)
            } else {
                (f64::from(px.first().copied().unwrap_or(0)) / 255.0, 0.0, 0.0)
            };
            if let Some(s) = sums.get_mut(cell) {
                s[0] += l;
                s[1] += a;
                s[2] += b;
            }
            if let Some(c) = counts.get_mut(cell) {
                *c += 1;
            }
        }
    }
    let plane_count = if colour { 3 } else { 1 };
    let mut planes = vec![vec![0.0f32; n]; plane_count];
    for (cell, (sum, &count)) in sums.iter().zip(&counts).enumerate() {
        let count = f64::from(count.max(1));
        for (p, plane) in planes.iter_mut().enumerate() {
            if let (Some(v), Some(s)) = (plane.get_mut(cell), sum.get(p)) {
                *v = (s / count) as f32;
            }
        }
    }
    Some(Planes { w: gw, h: gh, planes })
}

/// Mean over a (2r+1)² box, clamped at the edges, through a summed-area table.
fn box_blur(src: &[f32], w: usize, h: usize, r: usize) -> Vec<f32> {
    let sw = w + 1;
    let mut sat = vec![0.0f64; sw * (h + 1)];
    for y in 0..h {
        let mut row = 0.0f64;
        for x in 0..w {
            row += f64::from(at(src, y * w + x));
            let above = sat.get(y * sw + x + 1).copied().unwrap_or(0.0);
            if let Some(v) = sat.get_mut((y + 1) * sw + x + 1) {
                *v = above + row;
            }
        }
    }
    let s = |x: usize, y: usize| sat.get(y * sw + x).copied().unwrap_or(0.0);
    let mut out = vec![0.0f32; w * h];
    for y in 0..h {
        let y0 = y.saturating_sub(r);
        let y1 = (y + r + 1).min(h);
        for x in 0..w {
            let x0 = x.saturating_sub(r);
            let x1 = (x + r + 1).min(w);
            let area = ((x1 - x0) * (y1 - y0)).max(1) as f64;
            let sum = s(x1, y1) - s(x0, y1) - s(x1, y0) + s(x0, y0);
            if let Some(v) = out.get_mut(y * w + x) {
                *v = (sum / area) as f32;
            }
        }
    }
    out
}

fn normalize(v: &mut [f32]) {
    let lo = v.iter().copied().fold(f32::INFINITY, f32::min);
    let hi = v.iter().copied().fold(f32::NEG_INFINITY, f32::max);
    let span = hi - lo;
    if !(span.is_finite() && span > 0.0) {
        v.iter_mut().for_each(|x| *x = 0.0);
        return;
    }
    v.iter_mut().for_each(|x| *x = (*x - lo) / span);
}

fn at(v: &[f32], i: usize) -> f32 {
    v.get(i).copied().unwrap_or(0.0)
}

fn add(v: &mut [f32], i: usize, d: f32) {
    if let Some(x) = v.get_mut(i) {
        *x += d;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fit::{Size, fit};

    /// A dark ground with a bright figure (a soft-edged ellipse) at (cx, cy).
    fn figure(w: usize, h: usize, cx: f64, cy: f64, rx: f64, ry: f64) -> Vec<u8> {
        let mut rgb = vec![0u8; w * h * 3];
        for y in 0..h {
            for x in 0..w {
                let dx = (x as f64 - cx) / rx;
                let dy = (y as f64 - cy) / ry;
                let d = (dx * dx + dy * dy).sqrt();
                // A little texture on the ground so it is not perfectly flat.
                let ground = 18.0 + 6.0 * (((x / 7) + (y / 5)) % 2) as f64;
                let v = if d < 1.0 { 235.0 } else { ground };
                let i = (y * w + x) * 3;
                rgb[i] = v as u8;
                rgb[i + 1] = (v * 0.9) as u8;
                rgb[i + 2] = (v * 0.7) as u8;
            }
        }
        rgb
    }

    fn holds(r: &Salient, x: f64, y: f64) -> bool {
        x >= r.x && x <= r.x + r.w && y >= r.y && y <= r.y + r.h
    }

    #[test]
    fn finds_bright_figure_on_dark_ground() {
        let (w, h) = (640, 400);
        let (cx, cy) = (500.0, 150.0);
        let rgb = figure(w, h, cx, cy, 40.0, 80.0);
        let regions = saliency_rgb(&rgb, w, h);
        assert!(!regions.is_empty());
        let top = regions[0];
        assert!(holds(&top, cx, cy), "{regions:?}");
        // Tight-ish: not the whole picture.
        assert!(top.w < w as f64 * 0.4 && top.h < h as f64 * 0.7, "{top:?}");
        let total: f64 = regions.iter().map(|r| r.weight).sum();
        assert!((total - 1.0).abs() < 1e-6);
    }

    #[test]
    fn luma_finds_dark_figure_on_bright_ground() {
        let (w, h) = (300, 500);
        let mut luma = vec![210u8; w * h];
        for y in 60..160 {
            for x in 30..90 {
                luma[y * w + x] = 20;
            }
        }
        let regions = saliency_luma(&luma, w, h);
        assert!(holds(&regions[0], 60.0, 110.0), "{regions:?}");
    }

    #[test]
    fn saliency_then_fit_keeps_figure() {
        let (w, h) = (1600, 1000);
        let (cx, cy) = (1350.0, 420.0);
        let rgb = figure(w, h, cx, cy, 70.0, 180.0);
        let regions = saliency_rgb(&rgb, w, h);
        for aspect in [21.0 / 9.0, 16.0 / 10.0, 9.0 / 19.5, 1.0] {
            let crop = fit(Size::new(w as f64, h as f64), aspect, &regions);
            assert!(crop.x <= cx - 70.0 && crop.x + crop.w >= cx + 70.0, "{aspect}: {crop:?}");
            assert!(crop.y <= cy && crop.y + crop.h >= cy, "{aspect}: {crop:?}");
        }
    }

    #[test]
    fn deterministic() {
        let rgb = figure(320, 200, 80.0, 60.0, 20.0, 30.0);
        assert_eq!(saliency_rgb(&rgb, 320, 200), saliency_rgb(&rgb, 320, 200));
    }

    #[test]
    fn flat_or_bad_buffers_give_nothing_and_never_panic() {
        assert!(saliency_rgb(&[], 0, 0).is_empty());
        assert!(saliency_rgb(&[1, 2, 3], 10, 10).is_empty());
        assert!(saliency_rgb(&[0; 30], 10, 0).is_empty());
        assert!(saliency_rgb(&[0; 30], usize::MAX, usize::MAX).is_empty());
        assert!(saliency_luma(&vec![128u8; 64 * 64], 64, 64).is_empty());
        // Tiny buffers.
        let _ = saliency_rgb(&[255, 0, 0], 1, 1);
        let _ = saliency_luma(&[0, 255], 2, 1);
        let _ = saliency_luma(&[0, 255, 0, 255, 0, 255], 1, 6);
        // Very thin.
        let _ = saliency_luma(&vec![7u8; 5000], 5000, 1);
        let map =
            SaliencyMap { w: 4, h: 4, scale_x: 1.0, scale_y: 1.0, values: vec![f32::NAN; 16] };
        assert!(regions(&map, SaliencyOptions::default()).is_empty());
        let short = SaliencyMap { w: 4, h: 4, scale_x: 1.0, scale_y: 1.0, values: vec![1.0; 3] };
        assert!(regions(&short, SaliencyOptions::default()).is_empty());
    }
}

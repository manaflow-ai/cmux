//! The comparison: per-pixel tolerance, SSIM on luma, ignore masks and per-region thresholds.
//!
//! Deterministic: every sum runs in a fixed row-major order in f64 (Rust never fuses multiply-add on its
//! own), and every float in the verdict is rounded to 6 decimals, so the same two images and spec give the
//! same verdict bytes and the same diff image bytes on every machine.

use crate::image::Rgba;
use serde::{Deserialize, Serialize};

pub const VERDICT_SCHEMA: &str = "cmux-shotdiff.verdict/v1";

/// The defaults match scripts/ci/ios_gate_screen_diff.py (CHANNEL_TOLERANCE 16, CHANGED_RATIO 0.01), so a
/// gate that moves from it to this keeps its outcomes; SSIM then catches structural change the pixel ratio
/// lets through (a moved control, a missing glyph run) and tolerates what it should not count (antialiasing).
pub const DEFAULT_CHANNEL_TOLERANCE: u8 = 16;
pub const DEFAULT_MAX_CHANGED_RATIO: f64 = 0.01;
pub const DEFAULT_MIN_SSIM: f64 = 0.98;

const WINDOW: u32 = 8;
const STRIDE: u32 = 4;
const TILE: u32 = 16;
/// Worst-tile SSIM tile size.
const SSIM_TILE: u32 = 32;
const MAX_BOXES: usize = 64;

/// A rectangle in spec units (pixels times `scale`, see `Spec::scale`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Rect {
    pub x: u32,
    pub y: u32,
    pub w: u32,
    pub h: u32,
}

/// A region nothing is compared in: a caret, a clock, an animation, a live avatar.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Mask {
    pub x: u32,
    pub y: u32,
    pub w: u32,
    pub h: u32,
    /// Why it is ignored; required so a mask never hides a real change without a reason on record.
    pub why: String,
}

/// A named region with its own thresholds (unset fields take the spec's).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Region {
    pub name: String,
    pub x: u32,
    pub y: u32,
    pub w: u32,
    pub h: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub channel_tolerance: Option<u8>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_changed_ratio: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub min_ssim: Option<f64>,
}

/// How two screenshots are judged. A pass needs both the changed-pixel ratio at or under
/// `max_changed_ratio` and SSIM at or over `min_ssim`, globally and in every region. Set
/// `max_changed_ratio` to 1 for SSIM alone (cross-renderer: lavapipe against Metal), or `min_ssim` to 0 for
/// the pixel ratio alone.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, default)]
pub struct Spec {
    /// A pixel changes when any channel moves by more than this (0..255).
    pub channel_tolerance: u8,
    /// Changed pixels over compared (unmasked) pixels, 0..1.
    pub max_changed_ratio: f64,
    /// Mean SSIM of luma over 8x8 windows (stride 4) that touch no mask, 0..1.
    pub min_ssim: f64,
    /// Worst 32x32 tile's mean SSIM, 0..1 (0 = report only). Catches a short label or a nudged button that
    /// moves well under 1% of pixels and barely moves the mean.
    pub min_tile_ssim: f64,
    /// Pixels per spec unit: 2 for rects written in points against a Retina capture.
    pub scale: u32,
    pub ignore: Vec<Mask>,
    pub regions: Vec<Region>,
}

impl Default for Spec {
    fn default() -> Self {
        Spec {
            channel_tolerance: DEFAULT_CHANNEL_TOLERANCE,
            max_changed_ratio: DEFAULT_MAX_CHANGED_RATIO,
            min_ssim: DEFAULT_MIN_SSIM,
            min_tile_ssim: 0.0,
            scale: 1,
            ignore: Vec::new(),
            regions: Vec::new(),
        }
    }
}

impl Spec {
    pub fn validate(&self) -> Result<(), String> {
        if self.scale == 0 {
            return Err("spec: scale must be at least 1".into());
        }
        let ratio_ok = |r: f64| (0.0..=1.0).contains(&r);
        if !ratio_ok(self.max_changed_ratio)
            || !ratio_ok(self.min_ssim)
            || !ratio_ok(self.min_tile_ssim)
        {
            return Err("spec: max_changed_ratio, min_ssim and min_tile_ssim are 0..1".into());
        }
        for m in &self.ignore {
            if m.why.trim().is_empty() {
                return Err(format!("spec: ignore mask at {},{} has no why", m.x, m.y));
            }
        }
        for r in &self.regions {
            if r.max_changed_ratio.is_some_and(|v| !ratio_ok(v))
                || r.min_ssim.is_some_and(|v| !ratio_ok(v))
            {
                return Err(format!("spec: region {} thresholds are 0..1", r.name));
            }
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ImageInfo {
    pub hash: String,
    pub width: u32,
    pub height: u32,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RegionVerdict {
    pub name: String,
    pub pass: bool,
    pub changed_pixels: u64,
    pub compared_pixels: u64,
    pub changed_ratio: f64,
    pub ssim: f64,
    pub reasons: Vec<String>,
}

/// The JSON verdict every caller reads.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Verdict {
    pub schema: String,
    pub pass: bool,
    /// Same pixels exactly (same content hash).
    pub identical: bool,
    pub reasons: Vec<String>,
    pub base: ImageInfo,
    pub head: ImageInfo,
    pub changed_pixels: u64,
    pub compared_pixels: u64,
    pub ignored_pixels: u64,
    pub changed_ratio: f64,
    pub ssim: f64,
    /// The 32x32 tile with the lowest mean SSIM (its windows' centers inside it); None when no tile has a window.
    pub worst_tile: Option<Tile>,
    /// Changed areas, merged on a 16-pixel grid, top to bottom (at most 64).
    pub boxes: Vec<Rect>,
    pub regions: Vec<RegionVerdict>,
    pub spec: Spec,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Tile {
    pub x: u32,
    pub y: u32,
    pub w: u32,
    pub h: u32,
    pub ssim: f64,
}

pub struct Comparison {
    pub verdict: Verdict,
    /// Head dimmed to gray, changed pixels red, ignored areas blue, changed boxes outlined. None when
    /// the sizes differ.
    pub diff_image: Option<Rgba>,
}

fn round6(v: f64) -> f64 {
    (v * 1e6).round() / 1e6
}

fn clip(r: (u32, u32, u32, u32), scale: u32, w: u32, h: u32) -> (u32, u32, u32, u32) {
    let x0 = r.0.saturating_mul(scale).min(w);
    let y0 = r.1.saturating_mul(scale).min(h);
    let x1 = r.0.saturating_add(r.2).saturating_mul(scale).min(w);
    let y1 = r.1.saturating_add(r.3).saturating_mul(scale).min(h);
    (x0, y0, x1, y1)
}

#[inline]
fn luma(p: [u8; 4]) -> f64 {
    // Rec. 601 in integers, then to f64: identical on every machine.
    ((299 * p[0] as u32 + 587 * p[1] as u32 + 114 * p[2] as u32) as f64) / 1000.0
}

fn ssim_window(a: &[f64], b: &[f64]) -> f64 {
    const C1: f64 = (0.01 * 255.0) * (0.01 * 255.0);
    const C2: f64 = (0.03 * 255.0) * (0.03 * 255.0);
    let n = a.len() as f64;
    let (mut sa, mut sb) = (0.0, 0.0);
    for i in 0..a.len() {
        sa += a[i];
        sb += b[i];
    }
    let (ma, mb) = (sa / n, sb / n);
    let (mut va, mut vb, mut cov) = (0.0, 0.0, 0.0);
    for i in 0..a.len() {
        let (da, db) = (a[i] - ma, b[i] - mb);
        va += da * da;
        vb += db * db;
        cov += da * db;
    }
    let denom = if n > 1.0 { n - 1.0 } else { 1.0 };
    let (va, vb, cov) = (va / denom, vb / denom, cov / denom);
    ((2.0 * ma * mb + C1) * (2.0 * cov + C2)) / ((ma * ma + mb * mb + C1) * (va + vb + C2))
}

/// Window origins along one axis: every STRIDE, plus the last full window so the far edge is covered.
fn origins(len: u32, win: u32) -> Vec<u32> {
    if len <= win {
        return vec![0];
    }
    let mut v: Vec<u32> = (0..=len - win).step_by(STRIDE as usize).collect();
    if *v.last().unwrap_or(&0) != len - win {
        v.push(len - win);
    }
    v
}

pub fn compare(base: &Rgba, head: &Rgba, spec: &Spec) -> Comparison {
    let base_info = ImageInfo { hash: base.content_hash(), width: base.width, height: base.height };
    let head_info = ImageInfo { hash: head.content_hash(), width: head.width, height: head.height };
    let identical = base_info.hash == head_info.hash;

    if base.width != head.width || base.height != head.height {
        let verdict = Verdict {
            schema: VERDICT_SCHEMA.into(),
            pass: false,
            identical: false,
            reasons: vec![format!(
                "size: base {}x{}, head {}x{}",
                base.width, base.height, head.width, head.height
            )],
            base: base_info,
            head: head_info,
            changed_pixels: 0,
            compared_pixels: 0,
            ignored_pixels: 0,
            changed_ratio: 1.0,
            ssim: 0.0,
            worst_tile: None,
            boxes: Vec::new(),
            regions: Vec::new(),
            spec: spec.clone(),
        };
        return Comparison { verdict, diff_image: None };
    }

    let (w, h) = (base.width, base.height);
    let n = w as usize * h as usize;
    let idx = |x: u32, y: u32| y as usize * w as usize + x as usize;

    // Ignore mask and per-pixel tolerance (the last region covering a pixel sets its tolerance).
    let mut ignored = vec![false; n];
    for m in &spec.ignore {
        let (x0, y0, x1, y1) = clip((m.x, m.y, m.w, m.h), spec.scale, w, h);
        for y in y0..y1 {
            for x in x0..x1 {
                ignored[idx(x, y)] = true;
            }
        }
    }
    let regions: Vec<(u32, u32, u32, u32)> =
        spec.regions.iter().map(|r| clip((r.x, r.y, r.w, r.h), spec.scale, w, h)).collect();
    let mut tolerance = vec![spec.channel_tolerance; n];
    for (r, rect) in spec.regions.iter().zip(&regions) {
        if let Some(t) = r.channel_tolerance {
            for y in rect.1..rect.3 {
                for x in rect.0..rect.2 {
                    tolerance[idx(x, y)] = t;
                }
            }
        }
    }

    // Pixel pass.
    let mut changed = vec![false; n];
    let (mut changed_count, mut compared, mut ignored_count) = (0u64, 0u64, 0u64);
    let mut reg_changed = vec![0u64; regions.len()];
    let mut reg_compared = vec![0u64; regions.len()];
    for y in 0..h {
        for x in 0..w {
            let i = idx(x, y);
            if ignored[i] {
                ignored_count += 1;
                continue;
            }
            compared += 1;
            let (a, b) = (base.pixel(x, y), head.pixel(x, y));
            let delta = (0..4).map(|c| a[c].abs_diff(b[c])).max().unwrap_or(0);
            let is_changed = delta > tolerance[i];
            if is_changed {
                changed[i] = true;
                changed_count += 1;
            }
            for (k, r) in regions.iter().enumerate() {
                if x >= r.0 && x < r.2 && y >= r.1 && y < r.3 {
                    reg_compared[k] += 1;
                    if is_changed {
                        reg_changed[k] += 1;
                    }
                }
            }
        }
    }

    // SSIM pass over luma windows that touch no mask.
    let la: Vec<f64> = (0..n)
        .map(|i| luma([base.data[i * 4], base.data[i * 4 + 1], base.data[i * 4 + 2], 0]))
        .collect();
    let lb: Vec<f64> = (0..n)
        .map(|i| luma([head.data[i * 4], head.data[i * 4 + 1], head.data[i * 4 + 2], 0]))
        .collect();
    let (ww, wh) = (WINDOW.min(w), WINDOW.min(h));
    let (mut ssim_sum, mut ssim_n) = (0.0f64, 0u64);
    let mut reg_ssim_sum = vec![0.0f64; regions.len()];
    let mut reg_ssim_n = vec![0u64; regions.len()];
    let mut wa = Vec::with_capacity((ww * wh) as usize);
    let mut wb = Vec::with_capacity((ww * wh) as usize);
    let tiles_x = w.div_ceil(SSIM_TILE) as usize;
    let mut tile_sum = vec![0.0f64; tiles_x * h.div_ceil(SSIM_TILE) as usize];
    let mut tile_n = vec![0u64; tile_sum.len()];
    let xs = origins(w, ww);
    for oy in origins(h, wh) {
        'win: for &ox in &xs {
            wa.clear();
            wb.clear();
            for y in oy..oy + wh {
                for x in ox..ox + ww {
                    let i = idx(x, y);
                    if ignored[i] {
                        continue 'win;
                    }
                    wa.push(la[i]);
                    wb.push(lb[i]);
                }
            }
            let s = ssim_window(&wa, &wb);
            ssim_sum += s;
            ssim_n += 1;
            let t = ((oy + wh / 2) / SSIM_TILE) as usize * tiles_x
                + ((ox + ww / 2) / SSIM_TILE) as usize;
            tile_sum[t] += s;
            tile_n[t] += 1;
            for (k, r) in regions.iter().enumerate() {
                // A window counts for a region when its center lies inside it, so small regions still get windows.
                let (cx, cy) = (ox + ww / 2, oy + wh / 2);
                if cx >= r.0 && cx < r.2 && cy >= r.1 && cy < r.3 {
                    reg_ssim_sum[k] += s;
                    reg_ssim_n[k] += 1;
                }
            }
        }
    }
    let mean = |sum: f64, k: u64| if k == 0 { 1.0 } else { sum / k as f64 };
    let ratio = |c: u64, t: u64| if t == 0 { 0.0 } else { c as f64 / t as f64 };

    let ssim = round6(mean(ssim_sum, ssim_n));
    let changed_ratio = round6(ratio(changed_count, compared));
    let mut worst_tile: Option<Tile> = None;
    for (t, (&sum, &k)) in tile_sum.iter().zip(&tile_n).enumerate() {
        if k == 0 {
            continue;
        }
        let ts = round6(sum / k as f64);
        if worst_tile.as_ref().is_none_or(|b| ts < b.ssim) {
            let (x, y) = ((t % tiles_x) as u32 * SSIM_TILE, (t / tiles_x) as u32 * SSIM_TILE);
            worst_tile =
                Some(Tile { x, y, w: SSIM_TILE.min(w - x), h: SSIM_TILE.min(h - y), ssim: ts });
        }
    }
    let mut reasons = Vec::new();
    if changed_ratio > spec.max_changed_ratio {
        reasons.push(format!("changed_ratio {changed_ratio} > {}", spec.max_changed_ratio));
    }
    if ssim < spec.min_ssim {
        reasons.push(format!("ssim {ssim} < {}", spec.min_ssim));
    }
    if let Some(t) = worst_tile.as_ref().filter(|t| t.ssim < spec.min_tile_ssim) {
        reasons.push(format!("tile {},{} ssim {} < {}", t.x, t.y, t.ssim, spec.min_tile_ssim));
    }

    let mut region_verdicts = Vec::new();
    for (k, r) in spec.regions.iter().enumerate() {
        let max_ratio = r.max_changed_ratio.unwrap_or(spec.max_changed_ratio);
        let min_ssim = r.min_ssim.unwrap_or(spec.min_ssim);
        let cr = round6(ratio(reg_changed[k], reg_compared[k]));
        let rs = round6(mean(reg_ssim_sum[k], reg_ssim_n[k]));
        let mut rr = Vec::new();
        if cr > max_ratio {
            rr.push(format!("changed_ratio {cr} > {max_ratio}"));
        }
        if rs < min_ssim {
            rr.push(format!("ssim {rs} < {min_ssim}"));
        }
        for reason in &rr {
            reasons.push(format!("region {}: {reason}", r.name));
        }
        region_verdicts.push(RegionVerdict {
            name: r.name.clone(),
            pass: rr.is_empty(),
            changed_pixels: reg_changed[k],
            compared_pixels: reg_compared[k],
            changed_ratio: cr,
            ssim: rs,
            reasons: rr,
        });
    }

    let boxes = changed_boxes(&changed, w, h);
    let diff_image = Some(render_diff(head, &changed, &ignored, &boxes));
    let verdict = Verdict {
        schema: VERDICT_SCHEMA.into(),
        pass: reasons.is_empty(),
        identical,
        reasons,
        base: base_info,
        head: head_info,
        changed_pixels: changed_count,
        compared_pixels: compared,
        ignored_pixels: ignored_count,
        changed_ratio,
        ssim,
        worst_tile,
        boxes,
        regions: region_verdicts,
        spec: spec.clone(),
    };
    Comparison { verdict, diff_image }
}

/// Connected groups of 16-pixel tiles that hold a changed pixel, as pixel boxes, top to bottom.
fn changed_boxes(changed: &[bool], w: u32, h: u32) -> Vec<Rect> {
    let (tw, th) = (w.div_ceil(TILE), h.div_ceil(TILE));
    let mut tiles = vec![false; (tw * th) as usize];
    for y in 0..h {
        for x in 0..w {
            if changed[(y * w + x) as usize] {
                tiles[((y / TILE) * tw + x / TILE) as usize] = true;
            }
        }
    }
    let mut seen = vec![false; tiles.len()];
    let mut boxes = Vec::new();
    for start in 0..tiles.len() {
        if !tiles[start] || seen[start] {
            continue;
        }
        let (mut x0, mut y0, mut x1, mut y1) = (u32::MAX, u32::MAX, 0u32, 0u32);
        let mut stack = vec![start];
        seen[start] = true;
        while let Some(t) = stack.pop() {
            let (tx, ty) = (t as u32 % tw, t as u32 / tw);
            x0 = x0.min(tx);
            y0 = y0.min(ty);
            x1 = x1.max(tx);
            y1 = y1.max(ty);
            let mut push = |nx: u32, ny: u32| {
                let j = (ny * tw + nx) as usize;
                if tiles[j] && !seen[j] {
                    seen[j] = true;
                    stack.push(j);
                }
            };
            if tx > 0 {
                push(tx - 1, ty);
            }
            if tx + 1 < tw {
                push(tx + 1, ty);
            }
            if ty > 0 {
                push(tx, ty - 1);
            }
            if ty + 1 < th {
                push(tx, ty + 1);
            }
        }
        let px0 = x0 * TILE;
        let py0 = y0 * TILE;
        let px1 = ((x1 + 1) * TILE).min(w);
        let py1 = ((y1 + 1) * TILE).min(h);
        boxes.push(Rect { x: px0, y: py0, w: px1 - px0, h: py1 - py0 });
        if boxes.len() == MAX_BOXES {
            break;
        }
    }
    boxes
}

fn render_diff(head: &Rgba, changed: &[bool], ignored: &[bool], boxes: &[Rect]) -> Rgba {
    let (w, h) = (head.width, head.height);
    let mut out = Rgba::new(w, h, [0, 0, 0, 255]);
    for y in 0..h {
        for x in 0..w {
            let i = (y * w + x) as usize;
            let l = luma(head.pixel(x, y)) as u32;
            let gray = (170 + l / 3) as u8;
            let p = if changed[i] {
                [255, 0, 64, 255]
            } else if ignored[i] {
                [gray / 2, gray / 2 + 40, 255, 255]
            } else {
                [gray, gray, gray, 255]
            };
            out.set(x, y, p);
        }
    }
    let outline = [255, 160, 0, 255];
    for b in boxes {
        let (x1, y1) = (b.x + b.w - 1, b.y + b.h - 1);
        for x in b.x..=x1 {
            out.set(x, b.y, outline);
            out.set(x, y1, outline);
        }
        for y in b.y..=y1 {
            out.set(b.x, y, outline);
            out.set(x1, y, outline);
        }
    }
    out
}
